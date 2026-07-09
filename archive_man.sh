#!/bin/bash
set -euo pipefail

# ============================================================
# archive_man.sh — multi-purpose archive/ROM management tool
# ============================================================

VERSION="2.0.0"
ENG_REGIONS='USA|Europe|Australia|UK|Canada'

usage() {
    cat <<EOF
archive_man.sh v$VERSION — archive/ROM management tool

Usage: $0 MODE [options]

MODES:
  -f         Find non-English files
  -d         Delete non-English files from list
  -v         Verify archive integrity (zip/7z/rar)
  -n         Normalize filenames (comma spacing, whitespace)
  -s         Sort files into A-Z/# subdirectories
  -1         1G1R: keep best version per game, flag duplicates
  -m         Merge/compare two directories
  -c         Generate SHA1 checksums
  -x         Build file index catalog (JSON)
  -z         Recompress archives (zip -> 7z)
  -h         Show this help

COMMON OPTIONS:
  -i <dir>     Target directory (default: .)
  --dry-run    Preview changes without executing
  -j <N>       Parallel jobs for -v, -c, -z (default: 1)

MODE-SPECIFIC:
  -f:  -o <file>    Output file (default: non_english_files.txt)
  -d:  -l <file>    Input list file (default: non_english_files.txt)
  -m:  --with <dir> Second directory to compare against
  -v:  --verbose    Show every archive, not just failures
  -c:  --dat        Output No-Intro DAT XML format instead of plain SHA1
  -x:  --tsv        Output TSV instead of JSON
  -z:  --keep       Keep original after recompressing
EOF
    exit 0
}

# ---------- argument parsing ----------
MODE=""
DIR="."
OUTFILE="non_english_files.txt"
LISTFILE="non_english_files.txt"
DRY_RUN=0
VERBOSE=0
JOBS=1
WITH_DIR=""
DAT_OUT=0
TSV_OUT=0
KEEP_ORIG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) MODE="find"; shift ;;
        -d) MODE="delete"; shift ;;
        -v) MODE="verify"; shift ;;
        -n) MODE="normalize"; shift ;;
        -s) MODE="sort"; shift ;;
        -1) MODE="onegame"; shift ;;
        -m) MODE="merge"; shift ;;
        -c) MODE="checksum"; shift ;;
        -x) MODE="index"; shift ;;
        -z) MODE="recompress"; shift ;;
        -h|--help) usage ;;
        -i) DIR="$2"; shift 2 ;;
        -o) OUTFILE="$2"; shift 2 ;;
        -l) LISTFILE="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --with) WITH_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --dat) DAT_OUT=1; shift ;;
        --tsv) TSV_OUT=1; shift ;;
        --keep) KEEP_ORIG=1; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Error: must specify a mode (-f -d -v -n -s -1 -m -c -x -z)"
    usage
fi

[[ ! "$JOBS" =~ ^[0-9]+$ ]] && { echo "Error: -j must be a positive integer"; exit 1; }
[[ $JOBS -lt 1 ]] && JOBS=1

# ---------- utility functions ----------
gname() {
    local name="$1"
    name="${name%.*}"
    if [[ "$name" == *"("* ]]; then
        echo "$name" | sed 's/(.*//' | sed 's/[[:space:]]*$//'
    else
        echo "$name" | sed 's/[[:space:]]*$//'
    fi
}

region_score() {
    case "$1" in
        USA)       echo 100 ;;
        Europe)    echo 85 ;;
        Australia) echo 80 ;;
        UK|Canada) echo 78 ;;
        World)     echo 60 ;;
        Japan)     echo 50 ;;
        *)         echo 25 ;;
    esac
}

ver_score() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${v//-/}"
        echo "$((100000 + d))"
    elif [[ "$v" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
        local major=$(echo "$v" | sed 's/^v//' | cut -d. -f1)
        local minor=$(echo "$v" | sed 's/^v//' | cut -d. -f2- | tr -d '.')
        printf "%d%04d" "$major" "${minor:-0}"
    else
        echo "0"
    fi
}

# ============================================================
# MODE: find
# ============================================================
if [[ "$MODE" == "find" ]]; then
    has_english() {
        local fname="$1"
        local found_tags=0
        while IFS= read -r group; do
            found_tags=1
            if echo "$group" | grep -qP '\bEn\b'; then return 0; fi
            if echo "$group" | grep -qP "\b(${ENG_REGIONS})\b"; then return 0; fi
        done < <(echo "$fname" | grep -oP '\([^)]+\)')
        [[ $found_tags -eq 0 ]] && return 0
        return 1
    }
    count=0; total_files=0
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

# ============================================================
# MODE: delete
# ============================================================
elif [[ "$MODE" == "delete" ]]; then
    [[ ! -f "$LISTFILE" ]] && { echo "Error: list file '$LISTFILE' not found"; exit 1; }
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

# ============================================================
# MODE: verify
# ============================================================
elif [[ "$MODE" == "verify" ]]; then
    verify_one() {
        local file="$1"
        local fname ext ext_lower
        fname=$(basename "$file")
        ext="${fname##*.}"
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        case "$ext_lower" in
            zip) unzip -tq "$file" &>/dev/null && echo "OK:$fname" || echo "BAD:$fname" ;;
            7z)  7z t "$file" &>/dev/null && echo "OK:$fname" || echo "BAD:$fname" ;;
            rar) unrar t "$file" &>/dev/null && echo "OK:$fname" || echo "BAD:$fname" ;;
            *)   echo "SKIP:$fname" ;;
        esac
    }
    export -f verify_one

    tmp=$(mktemp)
    trap "rm -f $tmp" EXIT
    find "$DIR" -maxdepth 1 -type f -print0 > "$tmp"

    ok=0; bad=0; skip=0
    if [[ $JOBS -gt 1 ]]; then
        xargs -0 -P "$JOBS" -I {} bash -c 'verify_one "$@"' _ {} < "$tmp" | while IFS=: read status fname; do
            case "$status" in
                OK)   ok=$((ok+1));   [[ $VERBOSE -eq 1 ]] && echo "  [OK]   $fname" ;;
                BAD)  bad=$((bad+1));  echo "  [BAD]  $fname" ;;
                SKIP) skip=$((skip+1)); [[ $VERBOSE -eq 1 ]] && echo "  [SKIP] $fname" ;;
            esac
        done
    else
        while IFS= read -r -d '' file; do
            result=$(verify_one "$file")
            status="${result%%:*}"
            fname="${result#*:}"
            case "$status" in
                OK)   ok=$((ok+1));     [[ $VERBOSE -eq 1 ]] && echo "  [OK]   $fname" ;;
                BAD)  bad=$((bad+1));    echo "  [BAD]  $fname" ;;
                SKIP) skip=$((skip+1));  [[ $VERBOSE -eq 1 ]] && echo "  [SKIP] $fname" ;;
            esac
        done < "$tmp"
    fi
    echo ""
    echo "OK: $ok  BAD: $bad  Skipped: $skip"

# ============================================================
# MODE: normalize
# ============================================================
elif [[ "$MODE" == "normalize" ]]; then
    normalize_name() {
        local name="$1"
        local new="$name"
        while IFS= read -r group; do
            local fixed="$group"
            fixed=$(echo "$fixed" | sed 's/,\(\w\)/, \1/g')
            fixed=$(echo "$fixed" | sed 's/  \+/ /g')
            new="${new//"$group"/$fixed}"
        done < <(echo "$name" | grep -oP '\([^)]+\)')
        new=$(echo "$new" | sed 's/  \+/ /g')
        new=$(echo "$new" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        echo "$new"
    }

    count=0; total_files=0
    while IFS= read -r -d '' file; do
        total_files=$((total_files + 1))
        fname=$(basename "$file")
        newname=$(normalize_name "$fname")
        if [[ "$fname" != "$newname" ]]; then
            if [[ -e "$DIR/$newname" ]]; then
                echo "  [conflict] $fname -> $newname (target exists)"
                continue
            fi
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "  [dry] mv $fname -> $newname"
            else
                mv "$file" "$DIR/$newname"
                echo "  mv $fname -> $newname"
            fi
            count=$((count + 1))
        fi
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    echo ""
    echo "Renamed: $count  /  Total: $total_files"

# ============================================================
# MODE: sort
# ============================================================
elif [[ "$MODE" == "sort" ]]; then
    count=0; total_files=0
    while IFS= read -r -d '' file; do
        total_files=$((total_files + 1))
        fname=$(basename "$file")
        first=$(echo "${fname:0:1}" | tr '[:lower:]' '[:upper:]')
        if [[ "$first" =~ [A-Z] ]]; then
            subdir="$first"
        else
            subdir="#"
        fi

        if [[ "$(dirname "$file")" != "$DIR" ]]; then
            [[ $VERBOSE -eq 1 ]] && echo "  [skip] $fname (already nested)"
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  [dry] mv $fname -> $subdir/$fname"
        else
            mkdir -p "$DIR/$subdir"
            mv "$file" "$DIR/$subdir/"
            echo "  mv $fname -> $subdir/$fname"
        fi
        count=$((count + 1))
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    echo ""
    echo "Sorted: $count  /  Total: $total_files"

# ============================================================
# MODE: 1G1R — keep best version per game
# ============================================================
elif [[ "$MODE" == "onegame" ]]; then
    declare -A seen_groups seen_files seen_scores
    games=()

    while IFS= read -r -d '' file; do
        fname=$(basename "$file")
        game=$(gname "$fname")
        seen_files["$game"]+="$fname"$'\n'

        readarray -t parens < <(echo "$fname" | grep -oP '\([^)]+\)' || true)
        region=""; version=""; is_demo=0; is_alt=0; is_rerelease=0; year_tag=""
        for p in "${parens[@]}"; do
            inner="${p:1:-1}"
            lower=$(echo "$inner" | tr '[:upper:]' '[:lower:]')
            if [[ "$lower" =~ ^(usa|europe|australia|uk|canada|japan|china|taiwan|thailand|spain|korea|world|brazil|italy|france|germany|netherlands|sweden|norway|denmark|finland|russia) && -z "$region" ]]; then
                region="$inner"
            elif [[ "$lower" =~ ^(demo|sample|trial|beta|proto) ]]; then
                is_demo=1
            elif [[ "$lower" == "alt" || "$lower" =~ ^alt\ [0-9]+$ ]]; then
                is_alt=1
            elif [[ "$lower" == "rerelease" ]]; then
                is_rerelease=1
            elif [[ "$lower" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                year_tag="$inner"
            elif [[ "$lower" =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; then
                version="$inner"
            fi
        done

        score=$(region_score "${region:-Unknown}")
        [[ $is_rerelease -eq 1 ]] && score=$((score + 15))
        [[ $is_demo -eq 1 ]]      && score=$((score - 50))
        [[ $is_alt -eq 1 ]]       && score=$((score - 10))
        if [[ -n "$year_tag" ]]; then
            vs=$(ver_score "$year_tag")
            score=$((score + vs))
        fi
        if [[ -n "$version" ]]; then
            vs=$(ver_score "$version")
            score=$((score + vs))
        fi
        seen_scores["$fname"]=$score

        if [[ ! " ${games[*]:-} " =~ " $game " ]]; then
            games+=("$game")
        fi
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    kept=0; removed=0
    for game in "${games[@]}"; do
        IFS=$'\n' read -d '' -ra candidates <<< "${seen_files[$game]:-}" || true
        if [[ ${#candidates[@]} -le 1 ]]; then
            [[ $VERBOSE -eq 1 ]] && echo "  [only] ${candidates[0]:-}"
            kept=$((kept + 1))
            continue
        fi

        best=""; best_score=-999999
        for c in "${candidates[@]}"; do
            [[ -z "$c" ]] && continue
            sc="${seen_scores[$c]:-0}"
            if [[ $sc -gt $best_score ]]; then
                best_score=$sc
                best="$c"
            fi
        done

        echo "  [game] $game"
        for c in "${candidates[@]}"; do
            [[ -z "$c" ]] && continue
            if [[ "$c" == "$best" ]]; then
                echo "    KEEP  $c"
                kept=$((kept + 1))
            else
                echo "    DROP  $c"
                if [[ $DRY_RUN -ne 1 ]]; then
                    rm -f "$DIR/$c"
                fi
                removed=$((removed + 1))
            fi
        done
    done
    [[ $DRY_RUN -eq 1 ]] && echo ""
    [[ $DRY_RUN -eq 1 ]] && echo "[dry-run] would remove $removed, keep $kept" || echo ""
    echo "Kept: $kept  Dropped: $removed"

# ============================================================
# MODE: merge
# ============================================================
elif [[ "$MODE" == "merge" ]]; then
    [[ -z "$WITH_DIR" ]] && { echo "Error: --with <dir> required for merge mode"; exit 1; }
    [[ ! -d "$WITH_DIR" ]] && { echo "Error: --with '$WITH_DIR' not found or not a directory"; exit 1; }
    echo "Merging: $DIR  <->  $WITH_DIR"
    echo ""

    declare -A d1 d2
    while IFS= read -r -d '' file; do
        d1["$(basename "$file")"]=1
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    while IFS= read -r -d '' file; do
        d2["$(basename "$file")"]=1
    done < <(find "$WITH_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    only1=0; only2=0; both=0
    for f in "${!d1[@]}"; do
        if [[ -n "${d2[$f]:-}" ]]; then
            both=$((both + 1))
        else
            echo "  < $f  (only in $DIR)"
            only1=$((only1 + 1))
        fi
    done
    for f in "${!d2[@]}"; do
        if [[ -z "${d1[$f]:-}" ]]; then
            echo "  > $f  (only in $WITH_DIR)"
            only2=$((only2 + 1))
        fi
    done
    echo ""
    echo "Only in $DIR:        $only1"
    echo "Only in $WITH_DIR:  $only2"
    echo "In both:             $both"

# ============================================================
# MODE: checksum
# ============================================================
elif [[ "$MODE" == "checksum" ]]; then
    checksum_one() {
        local file="$1"
        local sha
        if command -v sha1sum &>/dev/null; then
            sha=$(sha1sum "$file" | awk '{print $1}')
        elif command -v shasum &>/dev/null; then
            sha=$(shasum -a 1 "$file" | awk '{print $1}')
        else
            echo "ERROR:no sha1 tool:$file"
            return 1
        fi
        local fname=$(basename "$file")
        if [[ $DAT_OUT -eq 1 ]]; then
            printf '    <game name="%s">\n      <rom name="%s" size="%d" sha1="%s"/>\n    </game>\n' \
                "$fname" "$fname" "$(stat -c%s "$file")" "$sha"
        else
            echo "$sha  $fname"
        fi
    }
    export -f checksum_one
    export DAT_OUT

    if [[ $DAT_OUT -eq 1 ]]; then
        echo '<?xml version="1.0"?>'
        echo '<datafile>'
    fi

    tmp=$(mktemp)
    trap "rm -f $tmp" EXIT
    find "$DIR" -maxdepth 1 -type f -print0 > "$tmp"

    if [[ $JOBS -gt 1 ]]; then
        xargs -0 -P "$JOBS" -I {} bash -c 'checksum_one "$@"' _ {} < "$tmp"
    else
        while IFS= read -r -d '' file; do
            checksum_one "$file"
        done < "$tmp"
    fi

    if [[ $DAT_OUT -eq 1 ]]; then
        echo '</datafile>'
    fi

# ============================================================
# MODE: index
# ============================================================
elif [[ "$MODE" == "index" ]]; then
    parse_meta() {
        local fname="$1"
        local name="$fname"
        local game region ext lang_str version year disc demo alt rerelease
        game=$(gname "$fname")
        ext="${fname##*.}"
        region=""; version=""; year=""; disc=""; demo="false"; alt="false"; rerelease="false"
        lang_str=""

        while IFS= read -r p; do
            inner="${p:1:-1}"
            lower=$(echo "$inner" | tr '[:upper:]' '[:lower:]')
            if [[ "$lower" =~ ^(usa|europe|australia|uk|canada|japan|china|taiwan|thailand|spain|korea|world|brazil|italy|france|germany|netherlands|sweden|norway|denmark|finland|russia) && -z "$region" ]]; then
                region="$inner"
            elif [[ "$lower" =~ ^en(,.*)?$ || "$lower" =~ ^.*,en$ || "$lower" == "en" ]]; then
                lang_str="$inner"
            elif [[ "$lower" =~ ^(demo|sample|trial|beta|proto) ]]; then
                demo="true"
            elif [[ "$lower" == "alt" || "$lower" =~ ^alt\ [0-9]+$ ]]; then
                alt="true"
            elif [[ "$lower" == "rerelease" ]]; then
                rerelease="true"
            elif [[ "$lower" =~ ^disc?\ [0-9]+$ ]]; then
                disc="${lower#* }"
            elif [[ "$lower" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                year="$inner"
            elif [[ "$lower" =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; then
                version="$inner"
            elif [[ -z "$lang_str" && "$lower" =~ ^([a-z]{2},?\ ?)+$ ]]; then
                lang_str="$inner"
            fi
        done < <(echo "$fname" | grep -oP '\([^)]+\)' || true)

        size=$(stat -c%s "$DIR/$fname" 2>/dev/null || echo 0)

        if [[ $TSV_OUT -eq 1 ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$game" "$region" "${lang_str//,/ }" "$version" "$year" "$disc" "$demo" "$alt" "$rerelease" "$ext" "$size"
        else
            local j="{"
            j+="\"name\":$(echo "$game" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$game\""),"
            j+="\"region\":$(echo "${region:-null}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"${region:-null}\""),"
            j+="\"languages\":\"${lang_str:-}\","
            j+="\"version\":$(echo "${version:-null}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"${version:-null}\""),"
            j+="\"year\":$(echo "${year:-null}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"${year:-null}\""),"
            j+="\"disc\":${disc:-null},"
            j+="\"demo\":$demo,"
            j+="\"alt\":$alt,"
            j+="\"rerelease\":$rerelease,"
            j+="\"ext\":\"$ext\","
            j+="\"size\":$size"
            j+="}"
            echo "$j"
        fi
    }

    if [[ $TSV_OUT -eq 1 ]]; then
        printf 'game\tregion\tlanguages\tversion\tyear\tdisc\tdemo\talt\trerelease\text\tsize\n'
    else
        echo '['
    fi

    first=1
    while IFS= read -r -d '' file; do
        fname=$(basename "$file")
        if [[ $TSV_OUT -eq 0 ]]; then
            [[ $first -eq 1 ]] && first=0 || echo ','
        fi
        parse_meta "$fname"
    done < <(find "$DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    if [[ $TSV_OUT -eq 0 ]]; then
        echo ''
        echo ']'
    fi

# ============================================================
# MODE: recompress
# ============================================================
elif [[ "$MODE" == "recompress" ]]; then
    if ! command -v 7z &>/dev/null; then
        echo "Error: 7z not found — required for recompress mode"
        exit 1
    fi

    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    rc_one() {
        local file="$1"
        local fname workdir outname
        fname=$(basename "$file")
        workdir=$(mktemp -d)
        outname="${fname%.zip}.7z"

        if [[ -e "$DIR/$outname" ]]; then
            echo "  [skip] $fname (target $outname exists)"
            rm -rf "$workdir"
            return 0
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  [dry] 7z  $fname -> $outname"
            rm -rf "$workdir"
            return 0
        fi

        if ! unzip -o "$file" -d "$workdir" &>/dev/null; then
            echo "  [FAIL] $fname (extraction failed)"
            rm -rf "$workdir"
            return 1
        fi

        if 7z a -mx=9 -ms=on -mmt=on "$DIR/$outname" "$workdir/"* &>/dev/null; then
            local orig_size new_size
            orig_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            new_size=$(stat -c%s "$DIR/$outname" 2>/dev/null || echo 0)
            local pct=0
            [[ $orig_size -gt 0 ]] && pct=$((100 - (new_size * 100 / orig_size)))
            echo "  [OK] $fname -> $outname  (${pct}% smaller)"

            if [[ $KEEP_ORIG -eq 0 ]]; then
                rm -f "$file"
            fi
        else
            echo "  [FAIL] $fname (7z compression failed)"
            rm -f "$DIR/$outname"
        fi
        rm -rf "$workdir"
    }
    export -f rc_one
    export DIR KEEP_ORIG DRY_RUN

    tmp=$(mktemp)
    trap "rm -rf $tmpdir $tmp" EXIT
    find "$DIR" -maxdepth 1 -type f -name '*.zip' -print0 > "$tmp"

    ok=0; fail=0; skipped=0
    if [[ $JOBS -gt 1 ]]; then
        xargs -0 -P "$JOBS" -I {} bash -c 'rc_one "$@"' _ {} < "$tmp" | while IFS= read -r line; do
            echo "$line"
            case "$line" in
                *\[OK\]*)   ok=$((ok+1)) ;;
                *\[FAIL\]*) fail=$((fail+1)) ;;
                *\[skip\]*) skipped=$((skipped+1)) ;;
            esac
        done
    else
        while IFS= read -r -d '' file; do
            rc_one "$file"
            case $? in
                0) ok=$((ok+1)) ;;
                1) fail=$((fail+1)) ;;
            esac
        done < "$tmp"
    fi
    echo ""
    echo "Recompressed: $ok  Failed: $fail"

fi
