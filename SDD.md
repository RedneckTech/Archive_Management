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

**Problem:** All modes hardcode `-maxdepth 1`. TOSEC has subdirs per format (`[D64]/`, `[TAP]/`). Bitsavers is 16 levels deep. RetroAchievements nests multi-disc games in subdirectories.

**Design:**
- Add `-r` (recurse) flag to all modes
- When set, `find` uses default depth (no `-maxdepth`)
- Default behavior remains `-maxdepth 1` for backward compatibility
- `-s` (sort) needs special handling: sort only at the level requested, not into nested subdirs
- `-z` (recompress): recurse into subdirs but write output to same subdir

**Impact:** Every mode's `find` command line changes from:
```bash
find "$DIR" -maxdepth 1 -type f -print0
```
to:
```bash
if [[ $RECURSE -eq 1 ]]; then
    find "$DIR" -type f -print0
else
    find "$DIR" -maxdepth 1 -type f -print0
fi
```

### 4.2 Extension Filter (`-e`)

**Problem:** Running verify on Bitsavers would attempt `unzip -t` on PDFs, `unrar t` on `.tap.gz` files, etc. Over 180K files, that's thousands of meaningless skip messages.

**Design:**
- Add `-e <ext1,ext2,...>` to `-v`, `-c`, `-z`, `-f`, `-1`, `-n`, `-s`
- Only process files matching the listed extensions
- Comma-separated, case-insensitive
- `-e zip,7z` for ROM-only verify
- `-e pdf` for Bitsavers documentation index
- `-e zip` for TOSEC/Redump recompress

```bash
# Skip non-matching extensions at the file iteration level
ext="${fname##*.}"
ext_lower="${ext,,}"
if [[ "$EXT_FILTER" != "*" ]]; then
    [[ ",${EXT_FILTER}," != *",${ext_lower},"* ]] && continue
fi
```

### 4.3 Multi-Disc 1G1R

**Problem:** Current 1G1R picks the single highest-scoring file from a game group. For multi-disc games, this drops every disc except one.

**Design:**
- After determining the winner, scan the loser pool for sibling discs
- Match by: same game name, same region, same version/date, different disc number
- Promote sibling discs from DROP to KEEP
- Alternatively: group by game+region variant first, then pick best variant, keep all discs of that variant

**Algorithm change:**
```
for each game group:
    1. Sub-group by (game_name + region + version + year)
    2. Score each sub-group as a unit (best score of any disc)
    3. Keep all discs of the winning sub-group
    4. Drop all discs of losing sub-groups
```

This handles: `007 Nightfire (USA) (Disc 1).zip` + `(Disc 2).zip` both kept;  
`007 Nightfire (Europe) (Disc 1).zip` dropped.

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
