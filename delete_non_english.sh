#!/bin/bash
set -euo pipefail

LISTFILE="${1:-non_english_files.txt}"
DIR="${2:-.}"
DRY_RUN="${3:-}"

if [[ ! -f "$LISTFILE" ]]; then
    echo "Error: list file '$LISTFILE' not found"
    exit 1
fi

count=0
while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    target="$DIR/$fname"
    if [[ -f "$target" ]]; then
        if [[ "$DRY_RUN" == "dry" ]]; then
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
