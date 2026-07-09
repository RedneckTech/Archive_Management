# Software Design Document — archive_man

## Overview

`archive_man` is a dual-implementation (bash + PowerShell) CLI tool for managing multi-TB archive collections. It handles ROM sets, software archives, documentation, disk/tape images, and magazine collections across diverse naming conventions.

**Repository:** `git@github.com:RedneckTech/Archive_Management.git`  
**Target scale:** 10+ TB, 800K+ files, directory depths up to 16 levels  
**Platforms:** Linux (bash), Windows (PowerShell)

---

## 1. Target Data Landscape

The tool operates across six distinct archive sections:

| Section | Size | Files | Naming Convention | Primary Types |
|---------|------|-------|-------------------|---------------|
| Redump | 3.8 TB | 5,525 | `Title (Region) (Lang) (Disc N).zip` | CD/DVD game ISOs in zip |
| RetroAchievements | 2.7 TB | 15,690 | `Title (Region).zip` / `.chd` / `.rvz` | Cartridge ROMs, CHD disc images |
| Bitsavers | 1.8 TB | 186,967 | `Descriptive_Title.ext` | PDFs, tape/disk images, source, magazines |
| tosec-pix | 1.2 TB | 16,648 | `Title (YYYY)(Publisher)(Region).zip` | Scanned box art, manuals, magazines |
| TOSEC | 637 GB | 647,687 | `Title (YYYY)(Publisher)[flags].zip` | ROMs in platform/format subdirs |
| Miscellaneous | 65 GB | 2,005 | `Nintendo Power Issue NNN.cbr` | Magazine archives |

Key differences from ROM-only tools:
- TOSEC uses square brackets `[flags]` instead of parenthetical tags
- Bitsavers has no standardized metadata in filenames — mostly free-form descriptive names
- CHD/RVZ formats are opaque to zip-based tools
- Directory nesting ranges from 1 level (Redump/No-Intro) to 16 levels (Bitsavers source trees)

---

## 2. Current Feature Set (v2.0.0)

All modes support `--dry-run` and `--verbose` unless otherwise noted.

### Mode Reference

| Flag | Mode | Description |
|------|------|-------------|
| `-f` | find | Scan for non-English files by region/language tags in `(...)` paren groups |
| `-d` | delete | Remove files listed in a previously generated text file |
| `-v` | verify | Test archive integrity via `unzip -t`, `7z t`, `unrar t` |
| `-n` | normalize | Fix comma spacing in language tags: `En,Ja` → `En, Ja` |
| `-s` | sort | Move files into `A-Z/` and `#/` subdirectories by first character |
| `-1` | 1G1R | Score all versions of each game, keep best, flag/drop rest |
| `-m` | merge | Symmetric diff of two directories — show files unique to each |
| `-c` | checksum | Generate SHA1 hashes (plain or No-Intro DAT XML) |
| `-x` | index | Build JSON or TSV catalog with parsed metadata |
| `-z` | recompress | Convert zip → 7z with `-mx=9 -ms=on -mmt=on` |

### Shared Options

| Option | Applies To | Description |
|--------|-----------|-------------|
| `-i <dir>` | all | Target directory (default: `.`) |
| `--dry-run` | all | Preview without side effects |
| `-j <N>` | `-v`, `-c`, `-z` | Parallel workers via `xargs -P` / runspace pool |
| `--verbose` | `-v` | Show passing archives, not just failures |

### Mode-Specific Options

| Mode | Option | Description |
|------|--------|-------------|
| `-f` | `-o <file>` | Output file path |
| `-d` | `-l <file>` | Input list file path |
| `-m` | `--with <dir>` | Second directory to compare |
| `-c` | `--dat` | Output DAT XML instead of plain SHA1 |
| `-x` | `--tsv` | Output TSV instead of JSON |
| `-z` | `--keep` | Retain original zip after recompression |

### 1G1R Scoring Algorithm

Each file is scored against siblings sharing the same game name (text before first `(`):

```
base = region_score(region)
     + rerelease_bonus (15)
     - demo_penalty (50)
     - alt_penalty (10)
     + version_score (numeric parse)
     + date_score (YYYYMMDD as integer)
```

Region scores: USA=100, Europe=85, Australia=80, UK/Canada=78, Japan=50, World=60, others=25  
Version score: `v1.12` = 10012, `v2.0` = 20000 — higher is better  
Date score: `2007-08-28` = 100000 + 20070828 = 120070828

The highest-scoring file is kept; all others are flagged for removal (or removed if not `--dry-run`).

### Metadata Parsing (`-x` index)

Parses these fields from `(tag)` groups in filenames:

| Field | Detection | Example |
|-------|-----------|---------|
| name | Text before first `(` | `You Don't Know Jack` |
| region | First matching country/continent tag | `(USA)`, `(Europe)` |
| languages | Language code list | `(En,Ja,Fr)` |
| version | `v` + dotted numbers | `(v1.01D)`, `(v1.12)` |
| year | ISO date pattern | `(2005-11-07)` |
| disc | `Disc N` or `disc N` | `(Disc 2)` |
| demo | `Demo`, `Sample`, `Trial`, `Beta`, `Proto` | `(Demo)` |
| alt | `Alt` or `Alt N` | `(Alt)`, `(Alt 2)` |
| rerelease | `Rerelease` | `(Rerelease)` |
| ext | File extension | `zip`, `chd`, `rvz` |
| size | File size in bytes | `496983441` |

---

## 3. Architecture

### Entry Point
```
parse_args() → MODE, DIR, JOBS, DRY_RUN, ...

case MODE in
  find       → find_mode()
  delete     → delete_mode()
  verify     → verify_mode()
  normalize  → normalize_mode()
  sort       → sort_mode()
  onegame    → onegame_mode()
  merge      → merge_mode()
  checksum   → checksum_mode()
  index      → index_mode()
  recompress → recompress_mode()
esac
```

### Parallel Dispatch
Modes `-v`, `-c`, `-z` use a shared parallel pattern:

```
collect_file_list() → temp file

if JOBS > 1:
    xargs -0 -P $JOBS -I {} bash -c 'worker_function "$@"' _ {} < temp
else:
    while read file; do worker_function "$file"; done < temp
```

### Utility Functions
| Function | Purpose |
|----------|---------|
| `gname()` | Extract game name (before first `(`) |
| `region_score()` | Map region name to numeric priority |
| `ver_score()` | Parse version number or date to comparable integer |
| `has_english()` | Check if filename contains En or English-speaking region |
| `normalize_name()` | Fix comma spacing inside paren groups |

---

## 4. Proposed Features (SDD Addendum)

### 4.1 Recursive Scanning (`-r`)

**Problem:** All modes hardcode `-maxdepth 1`. This is a fatal limitation for real-world use:

| Data Section | Depth | Files at top level | Files nested | Use Case |
|-------------|-------|--------------------|-------------|----------|
| Redump | 2 | 5,525 (all in `Letter/` subdirs) | 0 | `-r` to scan `Redump/` root and pick up all letters |
| TOSEC | 3-5 | 0 | 647,687 | Must recurse: `Commodore/Amiga/Games/[ADF]/file.zip` |
| Bitsavers | 3-16 | 0 | 186,967 | Must recurse: `bits/DEC/pdp11/dectape/file` |
| RetroAchievements | 2-5 | ~12,000 | ~3,600 (multi-disc subdirs) | `-r` to reach `Final Fantasy VII (USA)/` subdir |
| tosec-pix | 3-6 | 0 | 16,648 | Nested: `commodore/Amiga/Magazines/01 For Amiga/file.zip` |
| No-Intro | 2 | 1,720 (in `Platform/` subdirs) | 0 | `-r` to scan across all platforms |

**Design:**

New global flag: `-r` (recurse). Default remains `maxdepth 1` for safety — accidentally running a destructive mode on `-i /media/DataCore` without `-r` limits blast radius to one directory.

```bash
RECURSE=0
# ... in arg parsing:
-r) RECURSE=1; shift ;;
```

A shared helper function replaces ad-hoc `find` calls in every mode:

```bash
collect_files() {
    local dir="$1"
    if [[ $RECURSE -eq 1 ]]; then
        find "$dir" -type f -print0 2>/dev/null
    else
        find "$dir" -maxdepth 1 -type f -print0 2>/dev/null
    fi
}
```

**Mode-specific behavior:**

| Mode | With `-r` | Without `-r` (default) |
|------|-----------|----------------------|
| `-f` find | Walk full tree, output relative paths from `-i` | Flat scan only |
| `-d` delete | File list must contain paths relative to `-i` | Flat names only |
| `-v` verify | Verify all archives recursively | Top-level only |
| `-n` normalize | Rename files in-place wherever found | Top-level only |
| `-s` sort | **Sort each directory independently** — see below | Top-level only |
| `-1` 1G1R | Group games across all subdirs, keep best location | Top-level only |
| `-m` merge | Diff full trees, show paths relative to each root | Top-level only |
| `-c` checksum | Hash all files, path includes subdirs | Top-level only |
| `-x` index | Catalog full tree with relative paths | Top-level only |
| `-z` recompress | Recompress in-place, output wherever source was found | Top-level only |

**Sort mode with `-r` — special design:**

When `-s -r` is used, each directory in the tree gets its own A-Z sort independently. This is because:
- TOSEC already groups by platform/category: `Commodore/C64/Games/` shouldn't merge with `Commodore/Amiga/Games/`
- Each subdirectory is a logical bucket; sorting within buckets preserves the existing organization
- Sorting across buckets would destroy the TOSEC category structure

Algorithm:
```bash
# Collect all directories containing files
while IFS= read -r -d '' file; do
    dir=$(dirname "$file")
    dirs["$dir"]=1
done < <(collect_files "$DIR")

# Sort each directory independently
for d in "${!dirs[@]}"; do
    sort_files_in "$d"  # same logic as flat sort mode
done
```

Files already in sorted subdirs (like `A/`, `Y/`, `#/`) are skipped to avoid double-nesting.

### 4.2 Extension Filter (`-e`)

**Problem:** Without extension filtering, every mode processes all files regardless of type. Concrete issues:

1. **Verify on Bitsavers** — 68K PDFs each trip `unzip -t` → "unsupported" skip message. 4,500 `.bin` firmware files, 3,800 `.txt` indexes, 1,300 `.tif` scans all produce skip noise. Only 3,034 zips are actually verifiable.
2. **Checksum on Bitsavers** — Computing SHA1 on 1.8 TB of PDFs when you only want ROM hashes wastes hours.
3. **Recompress on mixed dir** — Tries to recompress `.tap.gz` and `.dsk` files which aren't zips. The `find -name '*.zip'` in the current code pre-filters, but that's hardcoded — no user control.
4. **Sort on Bitsavers PDFs** — Moving thousands of PDFs into A-Z subdirs destroys the existing `pdf/dec/`, `pdf/ibm/` organizational structure.

**Design:**

New option: `-e <pattern>` where pattern is a comma-separated list of extensions (without dots). Stored as a lookup string.

```bash
EXT_FILTER=""          # empty = all extensions pass
EXT_FILTER_LOOKUP=""   # ",zip,7z,chd," for O(1) check

# In arg parsing:
-e) EXT_FILTER="$2"
    EXT_FILTER_LOOKUP=",$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's/, */,/g'),"
    shift 2 ;;
```

A shared filter function used in every file loop:

```bash
passes_filter() {
    local fname="$1"
    [[ -z "$EXT_FILTER" ]] && return 0
    local ext="${fname##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    [[ "$EXT_FILTER_LOOKUP" == *",$ext,"* ]] && return 0
    return 1
}
```

**Which modes support `-e`:**

| Mode | `-e` supported? | Typical usage |
|------|----------------|---------------|
| `-f` find | Yes | `-e zip -r -i TOSEC` — only check ROMs, skip format subdir placeholders |
| `-d` delete | N/A | Follows whatever list file was generated |
| `-v` verify | Yes | `-e zip,7z,chd,rvz` — verify executable archives only |
| `-n` normalize | Yes | `-e zip` — only rename ROMs, leave PDFs alone |
| `-s` sort | Conditional | `-e zip` when sorting ROMs; no filter when sorting PDF libraries |
| `-1` 1G1R | Yes | `-e zip` — only game ROMs, not documentation |
| `-m` merge | Yes | `-e zip,chd,rvz` — compare ROM collections, not sidecar files |
| `-c` checksum | Yes | `-e zip` — DAT generation for ROM sets only |
| `-x` index | Yes | `-e pdf` — catalog Bitsavers docs only; `-e zip` — catalog ROM set only |
| `-z` recompress | Yes | `-e zip` — already the default, explicit override |

**Interaction with `-r`:**

`-e` and `-r` compose naturally. A filter runs per-file after the file list is collected. The combination `-r -e zip -v -i /media/DataCore/TOSEC` would walk the full TOSEC tree but only verify zip files — skipping any stray `.txt`, `.nfo`, `.png` files that might exist alongside ROMs.

**Interaction with verify mode:**

`-e` pre-filters before `verify_one()` even sees the file. This means extraneous skip messages are eliminated at the source rather than inside the verify worker. The `--verbose` flag in verify mode then only shows skip messages for files the user WANTED to check (e.g., `-e zip,7z` but file is `.rar` — useful "you asked for these but they're the wrong type" feedback).

### 4.3 Multi-Disc 1G1R

**Problem:** Current 1G1R selects one file per game group. Multi-disc games are treated as independent files — Disc 2 of the winning variant is dropped because Disc 1 scored marginally higher (larger file? tie-break?). Real-world failures:

```
[game] 007 - Nightfire
  KEEP  007 - Nightfire (USA) (Disc 2).zip     ← wins by tie-break
  DROP  007 - Nightfire (USA) (Disc 1).zip     ← needed for playback!
  DROP  007 - Nightfire (Europe) (Disc 1).zip
  DROP  007 - Nightfire (Japan) (Ja).zip
```

```
[game] Yinyi Shashou
  KEEP  Yinyi Shashou (China) (En,Zh) (Disc 2) (Rerelease).zip
  DROP  Yinyi Shashou (China) (En,Zh) (Disc 1).zip          ← also needed!
  DROP  Yinyi Shashou (China) (En,Zh) (Disc 1) (Rerelease).zip
```

**Design — sub-grouping by variant:**

Instead of one flat pool per game name, files are sub-grouped by _variant signature_:

```
variant_signature = game_name + "|" + region + "|" + languages + "|" + version + "|" + year
```

Algorithm:

```
Phase 1: Parse and group
  For each file:
    1. Extract game_name (text before first '(')
    2. Build variant key: game_name|region|langs|version|year
    3. Append file to game_groups[game_name]
    4. Append file to variant_groups[variant_key]

Phase 2: Score variants
  For each variant_key:
    Score = compute_score(any file in the variant)
    All files in this variant share the same score
    variant_scores[variant_key] = score

Phase 3: Select winners
  For each game_name:
    Find the variant_key with highest variant_scores[]
    That's the winning variant
    KEEP all files belonging to the winning variant
    DROP all files belonging to other variants
```

**Variant key examples:**

| File | Variant Key |
|------|-------------|
| `007 Nightfire (USA) (Disc 1).zip` | `007 Nightfire\|USA\|\|\|` |
| `007 Nightfire (USA) (Disc 2).zip` | `007 Nightfire\|USA\|\|\|` ← same key! |
| `007 Nightfire (Europe) (Disc 1).zip` | `007 Nightfire\|Europe\|\|\|` |
| `Yinyi Shashou (China) (En,Zh) (Disc 1) (Rerelease).zip` | `Yinyi Shashou\|China\|En,Zh\|\|` |
| `Yinyi Shashou (China) (En,Zh) (Disc 2) (Rerelease).zip` | `Yinyi Shashou\|China\|En,Zh\|\|` ← same key! |
| `Final Fantasy VII (USA) (Disc 1).zip` | `Final Fantasy VII\|USA\|\|\|` |
| `Final Fantasy VII (USA) (Disc 2).zip` | `Final Fantasy VII\|USA\|\|\|` ← same key! |
| `Final Fantasy VII (USA) (Disc 3).zip` | `Final Fantasy VII\|USA\|\|\|` ← same key! |

**Expected output after fix:**

```
[game] 007 - Nightfire
    KEEP  007 - Nightfire (USA) (Disc 1).zip
    KEEP  007 - Nightfire (USA) (Disc 2).zip
    DROP  007 - Nightfire (Europe) (Disc 1).zip
    DROP  007 - Nightfire (Japan) (Ja).zip
  Var: USA  |  Europe  |  Japan

[game] Yinyi Shashou
    KEEP  Yinyi Shashou (China) (En,Zh) (Disc 1) (Rerelease).zip
    KEEP  Yinyi Shashou (China) (En,Zh) (Disc 2) (Rerelease).zip
    DROP  Yinyi Shashou (China) (En,Zh) (Disc 1).zip
  Var: China+En,Zh+Rerelease  |  China+En,Zh

[game] Final Fantasy VII
    KEEP  Final Fantasy VII (USA) (Disc 1).zip
    KEEP  Final Fantasy VII (USA) (Disc 2).zip
    KEEP  Final Fantasy VII (USA) (Disc 3).zip
    DROP  Final Fantasy VII (Japan) (Ja) (Disc 1).zip
    DROP  Final Fantasy VII (Japan) (Ja) (Disc 2).zip
    DROP  Final Fantasy VII (Japan) (Ja) (Disc 3).zip
    DROP  Final Fantasy VII (Europe) (Disc 1).zip
    DROP  Final Fantasy VII (Europe) (Disc 2).zip
  Var: USA  |  Japan+Ja  |  Europe
```

**Edge cases:**

1. **Single-disc games** — Variant key has only one file. No behavior change from current.
2. **Multi-disc with inconsistent tags** — `(Disc 1)` has `(Rerelease)` but `(Disc 2)` doesn't. Solution: the variant key includes Rerelease flag. If Disc 1 says `Rerelease` and Disc 2 doesn't, they get _different_ variant keys and compete separately. This is correct — an inconsistent set is likely a mismatched collection.
3. **Games with no region tag** — Region is empty string in the key: `GameName\|\|\|\|`. All files with no region share this key.
4. **Multi-disc + multi-language** — `Euro Truck Simulator (Europe) (En,De) (Disc 1)` and `(Europe) (En,Fr) (Disc 2)` — different languages, different variant keys, split correctly. Won't merge.
5. **Games named with parens in title** — `You Don't Know Jack` is fine because `gname()` stops at first `(`. But a hypothetical `Foo (Bar) (USA).zip` would parse game name as `Foo` — the `(Bar)` is lost. Rare in practice; acceptable limitation.
6. **TOSEC multi-part** — `[Z64 Part 1-4]` is not extracted by current parser. These would compete independently under 1G1R until §4.5 (TOSEC bracket parsing) is implemented.

**Scoring a variant (not a single file):**

When scoring a variant that contains multiple files:
```bash
variant_score() {
    local best=0
    for file in variant_files; do
        local s=$(score_file "$file")
        [[ $s -gt $best ]] && best=$s
    done
    echo $best
}
```

The variant's score is the MAX of its members, not the SUM. This prevents a 3-disc game from outscoring a 1-disc game simply because it has more files.

### 4.4 CHD Verification

**Problem:** 3,257 `.chd` files in RetroAchievements are skipped by `-v`. CHD is the standard format for CD-based console games (PS1, Saturn, Dreamcast).

**Design:**
- Add `chdman verify` as a verification backend (part of MAME tools)
- New case in `verify_one()`:
```bash
chd)
    if chdman verify -i "$file" &>/dev/null; then
        echo "OK:$fname"
    else
        echo "BAD:$fname"
    fi
    ;;
```
- Also add to dependency docs: `chdman` (from MAME) required for CHD verification
- CHD files that aren't archives per se — they're compressed disc images — so they don't need recompress support

### 4.5 TOSEC Bracket Parsing

**Problem:** TOSEC uses `[cr remember]`, `[h Italian Language]`, `[t +4 Laxity]`, `[b]`, `[f AGA]`, `[Z64 Part 1-4]` square-bracket flags. Current parser only reads `(...)` paren groups.

**Design:**
- Extend `parse_meta()` and `has_english()` to also inspect `[...]` groups
- Map common TOSEC flags to metadata fields:

| TOSEC Flag | Maps To | Example |
|-----------|---------|---------|
| `[cr ...]` | crack group | `[cr remember]` |
| `[h ...]` | hack/translation | `[h Italian Language]` → region hint |
| `[t ...]` | trainer | `[t +4 Laxity]` |
| `[b]` | bad dump | flag: bad=true |
| `[f ...]` | fixed/modified | `[f AGA]` |
| `[m ...]` | modified | `[m 4 players]` |
| `[... Part N-M]` | multi-part | part extraction |

- For `-f` (find non-English): treat `[h Italian]`, `[h German]` etc. as non-English indicators
- For `-x` (index): add `bracket_flags` field as a string array of all `[...]` tags
- For `-n` (normalize): don't touch bracket content — TOSEC flags have their own standard spacing

### 4.6 Progress Reporting

**Problem:** Verifying 650K TOSEC files or checksumming 3.8 TB of Redump takes hours. Currently no indication of progress or ETA.

**Design:**
- Show `[processed/total] filename` for long-running modes (`-v`, `-c`, `-z`)
- Modes that pre-collect a file list can count total before starting
- Update in-place using carriage return to avoid flooding output:
```bash
printf "\r[%d/%d] %s" "$done" "$total" "$fname" >&2
```
- Final line overwrites with summary
- Add `--progress` flag — default off to preserve clean output for piping
- When `--verbose` is set, suppress progress (they conflict)

### 4.7 Resume Capability

**Problem:** A 6-hour checksum run on 3.8 TB that dies at hour 5 due to a network mount hiccup must restart from zero.

**Design:**
- Add `--resume <file>` to `-v`, `-c`, `-z`
- Write a checkpoint file after each processed file (just the filename, one per line)
- On resume, read the checkpoint file and skip already-processed files
- Checkpoint file is a simple sorted list of completed basenames:
```
007 - Nightfire (USA) (Disc 1).zip
007 - Nightfire (USA) (Disc 2).zip
...
```
- Use associative array for O(1) lookup on resume:
```bash
declare -A completed
while IFS= read -r line; do
    completed["$line"]=1
done < "$resume_file"
```

- Append completed filename to checkpoint after each successful operation (flush after each write for crash safety)
- Mode output appends to previous output so you can `>>` to the same file
- Clean up checkpoint file on successful completion

### 4.8 Content Hash Deduplication

**Problem:** The same ROM may exist in multiple collections under different names. For example, the same game might be in both Redump and RetroAchievements, or have been renamed between TOSEC versions.

**Design:**
- New mode: `-D` (deduplicate)
- Compute SHA1 of every file (respecting `-e` filter and `-r` recurse)
- Group files by hash, not by name
- For each hash group with N > 1:
  - List all paths
  - Mark one as KEEP (prefer: shorter path, Redump naming over TOSEC, parent dir over nested)
  - Flag others for deletion or hardlink/symlink
- Output options: `--link` (replace duplicates with hardlinks), `--symlink`, `--delete`, `--report`
- This is distinct from 1G1R — 1G1R groups by game name and applies scoring; dedup groups by actual content identity
- At TB scale, computing SHA1 of every file is the bottleneck — use `-j N` for parallelism

**Report format:**
```
Hash: a1b2c3d4... (3 copies, 1.2 GB wasted)
  KEEP  Redump/E/Example Game (USA).zip
  DROP  TOSEC/Commodore/Amiga/Games/[ADF]/Example Game (19xx)(Pub).zip
  DROP  RetroAchievements/RA - Amiga/Example Game (USA).zip
```

---

## 5. Implementation Order

| Priority | Feature | Effort | Impact | Risk |
|----------|---------|--------|--------|------|
| 1 | Recursive scanning (`-r`) | Low | High — unlocks all modes for nested archives | Low |
| 2 | Extension filter (`-e`) | Low | High — prevents useless operations | Low |
| 3 | Progress reporting | Low | Medium — UX, not functional | Low |
| 4 | Multi-disc 1G1R | Medium | Medium — correctness for CD games | Low |
| 5 | Resume capability | Medium | Medium — reliability for TB-scale ops | Low |
| 6 | TOSEC bracket parsing | Medium | Medium — broader format support | Medium (naming ambiguity) |
| 7 | CHD verification | Low | Medium — covers 3,257 files | Medium (chdman dependency) |
| 8 | Content hash dedup | High | High — major space savings | Medium (SHA1 on TB is slow) |

---

## 6. Dependencies (Current + Proposed)

| Tool | Required By | Availability |
|------|-------------|-------------|
| `unzip` | `-v` (zip), `-z` | Universal |
| `7z` | `-v` (7z), `-z` | `apt install p7zip-full` |
| `unrar` | `-v` (rar) | `apt install unrar` |
| `sha1sum` / `shasum` | `-c` (bash) | Universal / macOS |
| `python3` | `-x` JSON (bash) | Universal |
| `chdman` | `-v` (chd, proposed) | MAME tools package |

---

## 7. Known Limitations

1. **TOSEC find mode** — Flags all TOSEC files as non-English because region/language is in bracket flags, not paren tags. Will be addressed by §4.5.
2. **Bitsavers find mode not applicable** — Documentation archives don't use region/language tags. `-f` is ROM-specific by design.
3. **`broken_archive.zip` not detected** — 0-byte garbage files pass `unzip -tq` because there's no zip structure to validate. Real corruption is caught, but empty files slip through.
4. **1G1R drops sibling discs** — Multi-disc games lose discs 2-N when a variant is selected. Addressed by §4.3.
5. **`-j` with xargs loses exit code tracking** — The `xargs | while read` pipeline runs in a subshell. Counter variables in the pipeline don't propagate back. Current workaround: use sequential mode for accurate counts.
6. **No memory limits on large directories** — Associative arrays for merge mode load all filenames into memory. At 650K TOSEC files this is ~50MB, which is fine. Only a problem if scanning the entire DataCore at once.
