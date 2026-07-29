#!/usr/bin/env bash
# ComfyPod model downloader (also installed as `comfy-dl`).
#
#   comfy-dl preset <names>          download preset(s), comma-separated or "all"
#   comfy-dl url <url> [folder] [filename]
#   comfy-dl civitai <version-id> [folder]
#   comfy-dl list                    show presets and their contents
#
# Auth is injected automatically: HF_TOKEN as a Bearer header for
# huggingface.co, CIVITAI_TOKEN as ?token= for civitai.* URLs. Downloads are
# resumable (aria2c -c) and skipped when the file already exists.

export SCRIPT_NAME=download
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

PRESET_DIR="$REPO_DIR/config/presets"
[ -d "$PRESET_DIR" ] || PRESET_DIR="$SCRIPT_DIR/../config/presets"
FAILED=0

with_civitai_token() {
    local url="$1"
    if [ -n "$CIVITAI_TOKEN" ]; then
        case "$url" in
            *\?*) printf '%s&token=%s' "$url" "$CIVITAI_TOKEN" ;;
            *)    printf '%s?token=%s' "$url" "$CIVITAI_TOKEN" ;;
        esac
    else
        printf '%s' "$url"
    fi
}

# dl_file <folder-relative-to-models> <filename> <url>
dl_file() {
    local folder="$1" filename="$2" url="$3"
    local dest_dir="$MODELS_DIR/$folder" dest="$MODELS_DIR/$folder/$filename"
    mkdir -p "$dest_dir"

    if [ -s "$dest" ] && [ ! -f "$dest.aria2" ]; then
        log "exists, skipping: $folder/$filename"
        return 0
    fi

    local args=(-x16 -s16 -k1M -c --auto-file-renaming=false --allow-overwrite=true
                --console-log-level=warn --summary-interval=30 --file-allocation=none
                -d "$dest_dir" -o "$filename")
    case "$url" in
        *huggingface.co*)
            [ -n "$HF_TOKEN" ] && args+=("--header=Authorization: Bearer $HF_TOKEN") ;;
        *civitai.*)
            url="$(with_civitai_token "$url")" ;;
    esac

    log "downloading: $folder/$filename"
    if aria2c "${args[@]}" "$url"; then
        log "done: $folder/$filename"
    else
        warn "FAILED: $folder/$filename ($url)"
        warn "  If this is a gated/private model, set HF_TOKEN / CIVITAI_TOKEN."
        FAILED=$((FAILED + 1))
        return 1
    fi
}

run_manifest() {
    local file="$1" line folder filename url
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r folder filename url <<< "$line"
        dl_file "$folder" "$filename" "$url" || true
    done < "$file"
}

cmd_preset() {
    local names="$1" name file
    if [ "$names" = "all" ]; then
        names="$(cd "$PRESET_DIR" && ls -- *.txt | sed 's/\.txt$//' | paste -sd, -)"
    fi
    for name in ${names//,/ }; do
        file="$PRESET_DIR/$name.txt"
        if [ ! -f "$file" ]; then
            warn "unknown preset: $name (see: comfy-dl list)"
            FAILED=$((FAILED + 1))
            continue
        fi
        log "--- preset: $name ---"
        run_manifest "$file"
    done
}

cmd_url() {
    local url="$1" folder="${2:-checkpoints}" filename="${3:-}"
    if [ -z "$filename" ]; then
        filename="$(basename "${url%%\?*}")"
        # Civitai API URLs have no usable basename — let curl honor the
        # server-provided filename instead of aria2 (which cannot).
        case "$url" in
            *civitai.*/api/*)
                url="$(with_civitai_token "$url")"
                mkdir -p "$MODELS_DIR/$folder"
                log "downloading via curl into $folder/ (server-side filename)"
                (cd "$MODELS_DIR/$folder" && curl -fJLO --retry 3 "$url") || { warn "download failed"; exit 1; }
                return 0 ;;
        esac
    fi
    dl_file "$folder" "$filename" "$url"
}

cmd_civitai() {
    local version_id="$1" folder="${2:-loras}"
    cmd_url "https://civitai.com/api/download/models/$version_id" "$folder"
}

cmd_list() {
    local f
    for f in "$PRESET_DIR"/*.txt; do
        echo "== $(basename "$f" .txt) =="
        grep -E '^#\s*size:' "$f" || true
        grep -vE '^\s*(#|$)' "$f" | awk -F'|' '{printf "   %s/%s\n", $1, $2}'
    done
}

case "${1:-}" in
    preset)  shift; cmd_preset "${1:?usage: comfy-dl preset <names|all>}" ;;
    url)     shift; cmd_url "${1:?usage: comfy-dl url <url> [folder] [filename]}" "${2:-}" "${3:-}" ;;
    civitai) shift; cmd_civitai "${1:?usage: comfy-dl civitai <version-id> [folder]}" "${2:-}" ;;
    list)    cmd_list ;;
    *)       sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

if [ "$FAILED" -gt 0 ]; then
    warn "$FAILED download(s) failed"
    exit 1
fi
log "all downloads complete"
