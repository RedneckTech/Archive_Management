#!/bin/bash
set -euo pipefail

DIR="${1:-.}"
OUTFILE="${2:-non_english_files.txt}"

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
