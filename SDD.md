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

## 5. Safety Architecture

### 5.1 Design Principles

1. **Zero data loss by default.** No destructive operation executes without explicit confirmation. A mis-typed flag, wrong directory, or incorrect `-i` path must never cost real data.
2. **Reversible where possible.** If an operation can be undone without complexity (renames, moves within same filesystem), the undo path is recorded.
3. **Verifiable after mutation.** Every destructive mode produces an audit trail so the operator can confirm exactly what happened.
4. **Defense in depth.** Multiple independent safety layers — no single flag, check, or confirmation gate is the sole protection.
5. **Fail closed.** If any pre-flight check cannot be completed (missing tool, ambiguous path, permission error), the operation aborts rather than proceeding blind.

### 5.2 Destructive Mode Classification

Modes are ranked by consequence severity:

| Level | Modes | Consequence | Reversible? |
|-------|-------|-------------|-------------|
| 0 — Read | `-f`, `-v`, `-c`, `-x`, `-m` | None. Read-only. | N/A |
| 1 — Metadata | `-n` | Filename change. Inode unchanged. | Yes — names logged in `audit-YYYYMMDD-HHMMSS.log` |
| 2 — Move | `-s` | Relocation within filesystem. Inode unchanged if same mount. | Yes — source dirs logged, `mv` is atomic |
| 3 — Transform | `-z` | Original file deleted, new file created. New inode. | Only if `--keep` is used |
| 4 — Delete | `-d`, `-1`, `-D` | Irreversible file removal. | No — requires external backup |

Each level inherits all guards from the levels below it, plus additional level-specific protections.

### 5.3 Layer 0: Pre-Flight Checks

Executed once at startup, before any file is touched. If any check fails, the script exits with code 2 and a diagnostic message.

#### 5.3.1 Path Existence and Type

```
CHECK: -i <dir> must exist and be a directory
FAIL:  "Error: /mnt/missing is not a directory"
       exit 2

CHECK: --with <dir> (merge mode) must exist and be a directory
FAIL:  "Error: --with path '/tmp/nonexistent' not found"
       exit 2

CHECK: -i must be an absolute path or explicitly confirmed relative path
       Relative paths are resolved to absolute before use to prevent
       confusion when scripts are run from unexpected CWD.
```

#### 5.3.2 Write Permission

```
CHECK: For levels 1-4, the target directory must be writable.
       test -w "$DIR" || fail
FAIL:  "Error: $DIR is not writable"
       exit 2

CHECK: For -z (recompress), free space >= (largest zip * 3) in $DIR.
       Extraction needs ~2x the zip size for temp data, plus the final 7z.
       df_output=$(df -B1 "$DIR" | tail -1)
       avail=$(echo "$df_output" | awk '{print $4}')
       if [ $avail -lt $required ]; then
           echo "Error: need $(numfmt --to=iec $required) free, have $(numfmt --to=iec $avail)"
           exit 2
       fi
FAIL:  "Error: need 2.1 GB free, have 847 MB"
       exit 2
```

#### 5.3.3 Dependency Verification

```
CHECK: For each mode, required external tools must be in PATH.
       declare -A mode_deps=(
           ["verify"]="unzip"
           ["recompress"]="7z"
           ["checksum"]="sha1sum"
       )
       for dep in ${mode_deps[$MODE]}; do
           command -v "$dep" &>/dev/null || {
               echo "Error: '$dep' not found — required by -$MODE"
               exit 2
           }
       done

       Optional deps produce warnings, not errors:
       command -v unrar  &>/dev/null || echo "Warning: 'unrar' not found — RAR files will be skipped"
       command -v chdman &>/dev/null || echo "Warning: 'chdman' not found — CHD files will be skipped"
```

#### 5.3.4 File Count Guard

```
CHECK: Count files before starting any level 3-4 operation.
       file_count=$(collect_files "$DIR" | wc -l)

CONFIRM: If file_count > 100 and mode is level 3-4, require numeric confirmation.
         "WARNING: This will modify $file_count files in $DIR."
         "Type the file count to confirm: "
         read confirm_count
         if [ "$confirm_count" != "$file_count" ]; then
             echo "Aborted."
             exit 1
         fi

RATIONALE: Typing the exact number forces the operator to read and
          internalize the scale. A y/N prompt is too easy to breeze past.
```

#### 5.3.5 Mode-Specific Pre-Flight

```
-z (recompress):
    CHECK: Verify that 7z can create test archive in $DIR.
           touch "$DIR/.archive_man_test_$$" && rm -f "$DIR/.archive_man_test_$$"
           Fails if filesystem is read-only or quota exceeded.

    CHECK: TMPDIR has space (for extraction temp dirs).
           Default TMPDIR may be on a small root partition — warn if < 10 GB.

-d (delete), -1 (1G1R), -D (dedup):
    CHECK: -i must NOT be "/", "/home", "/media", "/mnt", or any path
           with depth < 2. Protects against catastrophic misconfiguration.
           dir_depth=$(echo "$(realpath "$DIR")" | tr -cd '/' | wc -c)
           if [ $dir_depth -lt 2 ]; then
               echo "ERROR: Refusing to run destructive mode on top-level path: $DIR"
               echo "       Minimum depth is 2 (e.g., /media/DataCore/Redump)"
               exit 2
           fi
```

### 5.4 Layer 1: Dry-Run and Confirmation Gates

#### 5.4.1 Mandatory First-Run Dry-Run

Destructive modes (`-d`, `-1`, `-z`, `-D`) track whether a dry-run was ever performed on the target directory. On first run without `--dry-run`, the script prints the proposed changes and requires explicit re-invocation.

```
STATE FILE:   $DIR/.archive_man_state
FORMAT:       mode:timestamp:dry_run_count:real_run_count

On startup for destructive modes:
    read_state_file
    if dry_run_count == 0 && DRY_RUN == 0:
        echo "This mode requires a dry-run first."
        echo "Running dry-run now..."
        DRY_RUN=1
        # proceed with dry-run, then exit
        # user must re-run without --dry-run to execute

RATIONALE: Forces the operator to see exactly what will happen before it happens.
           The state file is per-directory, so different archives can have
           different dry-run histories.
```

#### 5.4.2 Confirmation Prompt for Level 3-4

```
For -d, -1, -z, -D (non-dry-run):
    Show summary of what will be done:
    
    "========================================="
    "MODE:   1G1R (keep best version per game)"
    "DIR:    /media/DataCore/RetroAchievements"
    "FILES:  15,690 total, 12,340 will be KEPT, 3,350 will be DELETED"
    "SPACE:  847 GB will be freed"
    "========================================="
    "Type 'yes, delete 3350 files' to confirm: "
    
    read confirmation
    expected="yes, delete $files_to_delete files"
    if [ "$confirmation" != "$expected" ]; then
        echo "Confirmation failed — aborted."
        exit 1
    fi

RATIONALE: A typed confirmation string that includes the exact count prevents
          muscle-memory "y" responses. The operator must read, comprehend, and
          accurately type back the scope of destruction.
```

#### 5.4.3 Path Display Before Execution

```
Before any destructive mode starts:
    real=$(realpath "$DIR")
    echo "Target directory: $real"
    echo "Absolute path:    $real"
    sleep 2  # brief pause to let operator CTRL-C
    echo "Starting in 3..."
    sleep 1
    echo "Starting in 2..."
    sleep 1
    echo "Starting in 1..."
    sleep 1

RATIONALE: A 6-second delay with countdown gives the operator one last chance
          to notice they pointed at the wrong directory.
```

### 5.5 Layer 2: Operation-Specific Guards

#### 5.5.1 Delete Mode (`-d`)

```
GUARD: Each filename in the list file is validated before deletion.
       1. Strip any path components (basename only) — prevent ../../etc/passwd
       2. Reject names containing '/' or '\' — path traversal defense
       3. Verify file exists before attempting rm
       4. Verify file is a regular file, not a symlink or directory
          [ -f "$target" ] && rm -f "$target"
          (never follows symlinks to their targets)

GUARD: List file itself is never deletable.
       basename of list file is added to a skip-set before iteration.

GUARD: Maximum batch size warning.
       If list has > 10,000 entries, require additional confirmation.
```

#### 5.5.2 1G1R Mode (`-1`)

```
GUARD: Never delete the only copy of a game.
       If game_groups[$game] has only 1 entry, it's always KEEP regardless of score.
       (Already implemented — the "only" case.)

GUARD: Ambiguous game name groups trigger a warning and skip deletion.
       If two files have the same extracted game_name but wildly different
       filenames (Levenshtein distance > threshold), they may be different games
       with coincidentally similar prefixes. Flag as "ambiguous" and keep both.

GUARD: Size sanity check.
       If a game group contains files where sizes differ by > 5x, warn and skip.
       A 50 MB "Disc 1" and a 3 GB "Disc 1" are probably different games.
       
       "WARNING: 'Star Wars (USA) (Disc 1).zip' (52 MB) differs drastically
                 from 'Star Wars (Japan).zip' (3.1 GB). Keeping both. Review manually."

GUARD: Prevents deleting files that share an inode (hardlinks).
       stat -c '%h' to check link count. If > 1, warn — deleting would
       not free space, and the other link should be cleaned up instead.
```

#### 5.5.3 Recompress Mode (`-z`)

```
GUARD: Atomic replacement.
       The sequence must be:
       1. Extract to temp dir (outside $DIR, in TMPDIR)
       2. Create 7z in temp dir
       3. Verify the 7z is valid (7z t)
       4. MOVE (not copy) the 7z into $DIR
       5. Only then delete the original zip
       
       NEVER: rm original → create 7z  (gap where data doesn't exist)
       NEVER: create 7z alongside original → rm original (crash leaves both)
       
       CORRECT:
       tmpdir=$(mktemp -d -t archive_man.XXXXXX)
       trap "rm -rf $tmpdir" EXIT  # cleanup on any exit
       
       unzip -o "$original" -d "$tmpdir/extract" || { fail; return; }
       7z a -mx=9 "$tmpdir/output.7z" "$tmpdir/extract/"* || { fail; return; }
       7z t "$tmpdir/output.7z" || { fail; return; }
       mv "$tmpdir/output.7z" "$DIR/$outname"      # atomic on same filesystem
       rm -f "$original"                             # only after mv succeeds
       rm -rf "$tmpdir"                              # cleanup

GUARD: Temp directory must be on a different filesystem from $DIR if possible.
       Prevents filling $DIR with temp extraction data during recompress.
       Check: if TMPDIR is on same mount as DIR, warn:
       "Warning: TMPDIR and target are on the same filesystem.
                 Ensure adequate free space (2x largest zip)."

GUARD: Never process the same file twice.
       Track processed originals by inode. If a zip was already recompressed
       (or its output 7z already exists), skip it.

GUARD: Preserve original timestamps.
       touch -r "$original" "$DIR/$outname"
       So the new 7z inherits the original's mtime. Important for
       tools that sort or filter by modification date.

GUARD: Handle interrupted recompress cleanly (SIGINT/SIGTERM).
       trap on EXIT removes temp dir.
       Partial 7z in target dir is removed if script exits abnormally.
       Original zip is never touched until 7z is fully verified.
```

#### 5.5.4 Sort Mode (`-s`)

```
GUARD: Never overwrite an existing file.
       Before moving: if target exists, compare inodes.
       Same inode → already in place, skip.
       Different inode → name collision, warn and skip.
       
       [[ -e "$dest" ]] && {
           if [ "$(stat -c '%i' "$file")" = "$(stat -c '%i' "$dest")" ]; then
               continue  # already there
           else
               echo "  [conflict] $fname (target exists: $dest)"
               continue
           fi
       }

GUARD: Valid destination check.
       Subdir names are always A-Z or # — prevents creating directories
       with special characters from malicious filenames.
       [[ "$subdir" =~ ^[A-Z]|#$ ]] || { echo "BUG: invalid subdir"; continue; }

GUARD: No-op detection.
       If the file is already in the correct subdirectory, skip.
       "$(dirname "$file")" == "$DIR/$subdir" → already sorted.
```

#### 5.5.5 Normalize Mode (`-n`)

```
GUARD: No rename if target name already exists.
       [[ -e "$DIR/$newname" ]] → warn, skip, do not overwrite.

GUARD: Verify rename was successful before reporting.
       If mv fails (permissions, filesystem error), report failure.
       mv "$file" "$DIR/$newname" || echo "  [FAIL] $fname (mv failed: $?)"

GUARD: Don't rename if the name didn't actually change.
       (Already implemented — the "$fname" != "$newname" check.)

GUARD: Filename length check.
       Most filesystems limit filenames to 255 bytes.
       New name with added comma-spaces might exceed this.
       if [ ${#newname} -gt 255 ]; then warn and skip.
```

#### 5.5.6 Dedup Mode (`-D`, proposed §4.8)

```
GUARD: Every file in a duplicate group gets SHA1-verified against the KEEP
       file before any deletion. A byte-for-byte comparison (cmp) on the
       first and last 4096 bytes, plus full SHA1, confirms identity.

GUARD: Never delete a file that is the target of a symlink.
       If a symlink elsewhere in the tree points to this file, warn.

GUARD: --link mode requires same filesystem.
       Hardlinks only work within the same mount. Detect and warn if
       KEEP and DROP are on different filesystems — fall back to copy+verify.

GUARD: --symlink mode uses relative paths.
       Symlinks should be relative (../../Redump/E/file.zip) not absolute,
       so the tree remains portable across mount points.
```

### 5.6 Layer 3: Audit Trail and Reversal

#### 5.6.1 Audit Log

Every destructive mode writes a timestamped audit log:

```
FILE:    $DIR/.archive_man_audit/audit-YYYYMMDD-HHMMSS.log
FORMAT:  TAB-separated: timestamp\tmode\taction\told_path\tnew_path\tsize_bytes\texit_code

Example:
2025-07-09T14:32:01Z	-1	DROP	Redump/Y/Yukon Trail, The (USA).zip			335260146	0
2025-07-09T14:32:01Z	-1	KEEP	Redump/Y/Yukon Trail, The (USA) (Rerelease) (2003-02-20).zip		335320011	0
2025-07-09T14:32:05Z	-z	OK	Redump/Y/Yager (USA).zip	Redump/Y/Yager (USA).7z	4521002343	0
2025-07-09T14:32:05Z	-n	MV	Redump/Y/yager (USA).zip	Redump/Y/Yager (USA).zip	4521002343	0
2025-07-09T14:32:10Z	-s	MV	Redump/incoming/Yager.zip	Redump/Y/Yager.zip	4521002343	0
```

#### 5.6.2 Undo File Generation

For reversible operations (`-n`, `-s`), the audit log doubles as an undo script:

```
GENERATED:  $DIR/.archive_man_audit/undo-YYYYMMDD-HHMMSS.sh
CONTENTS:   #!/bin/bash
            # Undo script for archive_man -n run at 2025-07-09T14:32:05Z
            mv "Redump/Y/Yager (USA).zip" "Redump/Y/yager (USA).zip"
            mv "Redump/Y/Yellow Hippo (USA) (En, Es).zip" "Redump/Y/Yellow Hippo (USA) (En,Es).zip"
            ...
            echo "Undo complete. $(wc -l < undo.sh) files restored."
```

The undo script is:
- Executable (`chmod +x`)
- Idempotent (checks if target exists before moving)
- Validated for correctness (each line is the exact inverse of the audit entry)

#### 5.6.3 Audit Directory Structure

```
$DIR/.archive_man_audit/
├── audit-20250709-143200.log     # full audit trail
├── undo-20250709-143200.sh       # undo script (for -n, -s only)
├── checksums-pre-20250709-150000.sha1  # pre-mutation checksums (-z, -1, -D)
├── checksums-post-20250709-150000.sha1 # post-mutation checksums
└── state.json                     # dry-run counters, last runs
```

### 5.7 Layer 4: Post-Operation Verification

#### 5.7.1 Delete Verification

```
After -d, -1, -D completes:
    Verify that files marked DROP no longer exist.
    Verify that files marked KEEP still exist and are non-zero.
    Report any discrepancies:
        "Post-delete check: 3348/3350 files deleted correctly."
        "2 files could not be deleted (permission denied): ..."
        "All 12340 kept files verified present."
```

#### 5.7.2 Recompress Verification

```
After -z completes:
    1. Verify output 7z is valid (7z t)
    2. Verify original zip no longer exists (unless --keep)
    3. Verify output 7z size > 0
    4. Compute and log compression ratio:
       orig_total=..., new_total=..., saved=...%
    5. If verification fails, leave original intact and report failure
```

#### 5.7.3 Sort Verification

```
After -s completes:
    Verify no files remain at top level (if that was the intent).
    Verify each subdir contains only files starting with the correct letter.
    Verify no files were lost: count(files in subdirs) == count(files pre-sort).
```

#### 5.7.4 Checksum-Based Verification

```
For -z and -D: optional --verify-checksums flag.
    Before mutation: compute SHA1 of all files to be affected → pre.sha1
    After mutation:  for -z, extract new 7z and SHA1 its contents
                     for -D, SHA1 the KEEP file → must match pre.sha1
    Content identity confirmed before old files are deleted.
```

### 5.8 Signal Handling

```
trap 'cleanup_and_exit' EXIT INT TERM HUP

cleanup_and_exit() {
    local exit_code=$?
    
    # Remove any temp directories
    [ -n "${TEMP_DIRS[*]:-}" ] && rm -rf "${TEMP_DIRS[@]}"
    
    # Remove partially-written output files
    [ -n "${PARTIAL_FILE:-}" ] && [ -f "$PARTIAL_FILE" ] && rm -f "$PARTIAL_FILE"
    
    # For -z: any in-progress .7z in target dir is likely corrupt
    # The trap knows the current file being processed
    [ -n "${CURRENT_7Z_OUT:-}" ] && [ -f "$CURRENT_7Z_OUT" ] && {
        echo "Removing incomplete 7z: $CURRENT_7Z_OUT"
        rm -f "$CURRENT_7Z_OUT"
    }
    
    # Write partial audit log entry for interrupted operation
    echo "$(date -Iseconds)\t$MODE\tINTERRUPTED\t${CURRENT_FILE:-unknown}\t\t\t$exit_code" \
        >> "$AUDIT_LOG"
    
    exit $exit_code
}

CRITICAL: The trap must NOT rm the original zip during -z cleanup.
          The original is only deleted in the success path, never in cleanup.
          If the script is killed, the original zip survives.
```

### 5.9 Concurrent Run Protection

```
LOCKFILE:  $DIR/.archive_man.lock

On startup:
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        echo "Error: Another archive_man is already running on $DIR"
        echo "       Lock file: $LOCKFILE"
        echo "       PID: $(cat "$LOCKFILE" 2>/dev/null || echo 'unknown')"
        exit 2
    fi
    echo $$ > "$LOCKFILE"
    # lock is automatically released on exit (flock + exec)

RATIONALE: Two concurrent -z runs on the same directory would:
          1. Both try to extract the same zip to different temp dirs (waste)
          2. Race to delete the original zip (data loss if timing is wrong)
          3. One might try to recompress a .7z the other just created (corruption)
```

### 5.10 Safety Interaction Matrix

How each guard layer applies to each mode:

| Safety Mechanism | `-f` | `-v` | `-c` | `-x` | `-m` | `-n` | `-s` | `-z` | `-1` | `-d` | `-D` |
|-----------------|------|------|------|------|------|------|------|------|------|------|------|
| Path validation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Write permission check | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dependency check | — | ✓ | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| File count confirm (100+) | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Depth guard (min 2) | — | — | — | — | — | — | — | — | ✓ | ✓ | ✓ |
| First-run dry-run mandatory | — | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Typed confirmation string | — | — | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ |
| Countdown delay | — | — | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ |
| Atomic operations | — | — | — | — | — | ✓ | ✓ | ✓ | — | — | — |
| Collision detection | — | — | — | — | — | ✓ | ✓ | ✓ | — | — | ✓ |
| Post-op verification | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Audit log | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Undo script | — | — | — | — | — | ✓ | ✓ | — | — | — | — |
| SIGINT safe cleanup | — | — | — | — | — | — | — | ✓ | — | — | ✓ |
| Concurrent run lock | — | — | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Space pre-check | — | — | — | — | — | — | — | ✓ | — | — | — |
| Free inode check | — | — | — | — | — | — | ✓ | ✓ | — | — | — |
| Hardlink preservation | — | — | — | — | — | — | — | — | ✓ | — | ✓ |

---

## 6. Implementation Order

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

## 7. Dependencies (Current + Proposed)

| Tool | Required By | Availability |
|------|-------------|-------------|
| `unzip` | `-v` (zip), `-z` | Universal |
| `7z` | `-v` (7z), `-z` | `apt install p7zip-full` |
| `unrar` | `-v` (rar) | `apt install unrar` |
| `sha1sum` / `shasum` | `-c` (bash) | Universal / macOS |
| `python3` | `-x` JSON (bash) | Universal |
| `chdman` | `-v` (chd, proposed) | MAME tools package |

---

## 8. Known Limitations

1. **TOSEC find mode** — Flags all TOSEC files as non-English because region/language is in bracket flags, not paren tags. Will be addressed by §4.5.
2. **Bitsavers find mode not applicable** — Documentation archives don't use region/language tags. `-f` is ROM-specific by design.
3. **`broken_archive.zip` not detected** — 0-byte garbage files pass `unzip -tq` because there's no zip structure to validate. Real corruption is caught, but empty files slip through.
4. **1G1R drops sibling discs** — Multi-disc games lose discs 2-N when a variant is selected. Addressed by §4.3.
5. **`-j` with xargs loses exit code tracking** — The `xargs | while read` pipeline runs in a subshell. Counter variables in the pipeline don't propagate back. Current workaround: use sequential mode for accurate counts.
6. **No memory limits on large directories** — Associative arrays for merge mode load all filenames into memory. At 650K TOSEC files this is ~50MB, which is fine. Only a problem if scanning the entire DataCore at once.
