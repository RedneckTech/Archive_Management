#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 -f | -d | -h

  -f               Find non-English files
     -i <dir>        Directory to scan (default: .)
     -o <file>       Output file path (default: non_english_files.txt)

  -d               Delete non-English files listed in output file
     -l <file>       List file from -f run (default: non_english_files.txt)
     -i <dir>        Directory containing the files (default: .)
     --dry-run       Show what would be deleted without deleting

  -h               Show this help
EOF
    exit 0
}

MODE=""
DIR="."
OUTFILE="non_english_files.txt"
LISTFILE="non_english_files.txt"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) MODE="find"; shift ;;
        -d) MODE="delete"; shift ;;
        -h) usage ;;
        -i) DIR="$2"; shift 2 ;;
        -o) OUTFILE="$2"; shift 2 ;;
        -l) LISTFILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Error: must specify -f or -d"
    usage
fi

# -------------------------------------------------------
# MODE: find
# -------------------------------------------------------
if [[ "$MODE" == "find" ]]; then
    ENG_REGIONS='USA|Europe|Australia|UK|Canada'

    has_english() {
        local fname="$1"
        local found_tags=0

        while IFS= read -r group; do
            found_tags=1
            if echo "$group" | grep -qP '\bEn\b'; then
                return 0
            fi
            if echo "$group" | grep -qP "\b(${ENG_REGIONS})\b"; then
                return 0
            fi
        done < <(echo "$fname" | grep -oP '\([^)]+\)')

        if [[ $found_tags -eq 0 ]]; then
            return 0
        fi
        return 1
    }

    count=0
    total_files=0
    > "$OUTFILE"

    while IFS= read -r -d '' file; do
        total_files=$((total_files + 1))
        fname=$(basename "$file")
        if ! has_english "$fname"; then
            echo "$fname" >> "$OUTFILE"
            count=$((count + 1))
        fi
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "Non-English: $count  /  Total: $total_files  ->  $OUTFILE"

# -------------------------------------------------------
# MODE: delete
# -------------------------------------------------------
elif [[ "$MODE" == "delete" ]]; then
    if [[ ! -f "$LISTFILE" ]]; then
        echo "Error: list file '$LISTFILE' not found"
        exit 1
    fi

    count=0
    while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue
        target="$DIR/$fname"
        if [[ -f "$target" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "  [dry] rm -f $target"
            else
                rm -f "$target"
                echo "  rm -f $target"
            fi
            count=$((count + 1))
        else
            echo "  [missing] $target"
        fi
    done < "$LISTFILE"

    echo ""
    echo "Removed: $count"
fi
