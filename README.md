# Archive Management Scripts

Multi-purpose CLI tool for managing large archive/ROM collections. Bash and PowerShell versions with identical functionality.

## Quick Start

```bash
# Bash
./archive_man.sh -h

# PowerShell
.\archive_man.ps1 -h
```

## Modes

| Flag | Mode | Description |
|------|------|-------------|
| `-f` | find | Find non-English files by region/language tags |
| `-d` | delete | Delete files from a previously generated list |
| `-v` | verify | Test archive integrity (zip/7z/rar) |
| `-n` | normalize | Fix comma spacing in filename tags (`En,Ja` → `En, Ja`) |
| `-s` | sort | Sort files into `A-Z/` and `#/` subdirectories |
| `-1` | 1G1R | Keep best version per game, drop duplicates |
| `-m` | merge | Compare two directories, show differences |
| `-c` | checksum | Generate SHA1 hashes (plain or DAT XML) |
| `-x` | index | Build JSON/TSV catalog with parsed metadata |
| `-z` | recompress | Convert zip→7z with max solid compression |

## Common Options

| Option | Applies to | Description |
|--------|-----------|-------------|
| `-i <dir>` | all | Target directory (default: `.`) |
| `--dry-run` | all | Preview without modifying files |
| `-j <N>` | `-v`, `-c`, `-z` | Parallel workers (default: 1) |

## Mode-Specific Options

| Mode | Option | Description |
|------|--------|-------------|
| `-f` | `-o <file>` | Output file (default: `non_english_files.txt`) |
| `-d` | `-l <file>` | Input list file (default: `non_english_files.txt`) |
| `-v` | `--verbose` | Show all archives, not just failures |
| `-m` | `--with <dir>` | Second directory to compare against |
| `-c` | `--dat` | Output No-Intro DAT XML format |
| `-x` | `--tsv` | Output TSV instead of JSON |
| `-z` | `--keep` | Keep original zip after recompressing |

## Examples

```bash
# Find all non-English ROMs in a directory
./archive_man.sh -f -i ./roms/USA

# Sort thousands of files into letter subdirs (preview first)
./archive_man.sh -s -i ./incoming --dry-run
./archive_man.sh -s -i ./incoming

# 1G1R: keep only the best version of each game (preview first)
./archive_man.sh -1 -i ./roms --dry-run

# Verify all archives using 4 parallel workers
./archive_man.sh -v -i ./roms -j 4 --verbose

# Compare two directories (what's missing on each side)
./archive_man.sh -m -i ./drive1 --with ./drive2

# Generate SHA1 checksums
./archive_man.sh -c -i ./roms -j 4 > checksums.sha1

# Build a searchable JSON index of all ROMs
./archive_man.sh -x -i ./roms > catalog.json

# Recompress all zips to 7z (40-60% typical savings on ROM sets)
./archive_man.sh -z -i ./roms -j 4 --dry-run   # preview first
./archive_man.sh -z -i ./roms -j 4              # do it
```

## 1G1R Scoring

The `-1` mode groups files by game name and scores each version:

- **Region bonus:** USA (100) > Europe (85) > Australia (80) > UK/Canada (78) > Japan (50) > others (25)
- **Rerelease:** +15
- **Demo/Beta/Proto:** -50
- **Alt version:** -10
- **Version number:** higher = better (e.g., v1.12 > v1.02)
- **Date tag:** newer = better (e.g., 2007-08-28 > 2005-01-28)

## Dependencies

| Tool | Required by |
|------|-------------|
| `unzip` | `-v`, `-z` |
| `7z` | `-v` (7z files), `-z` (recompress) |
| `unrar` | `-v` (rar files) |
| `sha1sum` or `shasum` | `-c` (bash only) |
| `python3` | `-x` JSON output (bash only) |

## File Naming Convention

Scripts expect the standard ROM naming pattern:

```
Game Name (Region) (Languages) (Version) (Disc N) (Flags).ext
```

Examples:
```
You Don't Know Jack (USA) (v1.01D) (Rerelease) (Disc 1).zip
Yu-Gi-Oh! Online (Europe) (En,Ja,Fr,De,Es,It) (2005-01-28).zip
```

## License

MIT
