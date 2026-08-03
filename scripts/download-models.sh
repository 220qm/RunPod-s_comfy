#!/usr/bin/env bash
# ComfyPod model downloader (also installed as `comfy-dl`).
#
#   comfy-dl preset <names>          download preset(s), comma-separated or "all"
#   comfy-dl url <url> [folder] [filename]
#   comfy-dl civitai <version-id> [folder]
#   comfy-dl verify [presets]        check present files against manifest hashes
#   comfy-dl list                    show presets and their contents
#
# Auth (HF_TOKEN for huggingface.co, CIVITAI_TOKEN for civitai.*) is sent as
# an Authorization: Bearer header written to a 0600 temp file — tokens never
# appear in URLs, process listings, or logs. Downloads are resumable and
# skipped when the file already exists.
#
# Manifest line format: folder|filename|url[|sha256]
# Prefix the folder with "optional:" for a file whose absence is acceptable
# (a companion asset, or one whose exact name upstream is not confirmed): it
# is fetched like any other, but a failure is a warning instead of an error.

export SCRIPT_NAME=download
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

# Overridable so you can keep your own manifests outside the repo.
if [ -z "${PRESET_DIR:-}" ]; then
    PRESET_DIR="$REPO_DIR/config/presets"
    [ -d "$PRESET_DIR" ] || PRESET_DIR="$SCRIPT_DIR/../config/presets"
fi
FAILED=0

token_for_url() {
    case "$1" in
        *huggingface.co*) printf '%s' "$HF_TOKEN" ;;
        *civitai.*)       printf '%s' "$CIVITAI_TOKEN" ;;
    esac
}

# dl_file <folder-relative-to-models> <filename> <url> [sha256]
dl_file() {
    local folder="$1" filename="$2" url="$3" sha="${4:-}" optional=0
    case "$folder" in
        optional:*) optional=1; folder="${folder#optional:}" ;;
    esac
    local dest_dir="$MODELS_DIR/$folder" dest="$MODELS_DIR/$folder/$filename"
    mkdir -p "$dest_dir"

    if [ -s "$dest" ] && [ ! -f "$dest.aria2" ]; then
        log "exists, skipping: $folder/$filename"
        return 0
    fi

    local token input
    token="$(token_for_url "$url")"
    input="$(umask 077 && mktemp "$TMP_DIR/dl.XXXXXX")"
    {
        printf '%s\n' "$url"
        printf ' dir=%s\n' "$dest_dir"
        printf ' out=%s\n' "$filename"
        [ -n "$token" ] && printf ' header=Authorization: Bearer %s\n' "$token"
        [ -n "$sha" ]   && printf ' checksum=sha-256=%s\n' "$sha"
    } > "$input"

    log "downloading: $folder/$filename"
    if aria2c -x16 -s16 -k1M -c --auto-file-renaming=false --allow-overwrite=true \
              --console-log-level=warn --summary-interval=30 --file-allocation=none \
              -i "$input"; then
        rm -f "$input"
        log "done: $folder/$filename"
    elif [ "$optional" -eq 1 ]; then
        rm -f "$input"
        warn "optional file not available, continuing without it: $folder/$filename"
        return 0
    else
        rm -f "$input"
        warn "FAILED: $folder/$filename"
        warn "  Gated/private model? Set the matching token: comfypod-secrets set-hf-token / set-civitai-token"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

run_manifest() {
    local file="$1" line folder filename url sha
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r folder filename url sha <<< "$line"
        dl_file "$folder" "$filename" "$url" "$sha" || true
    done < "$file"
}

resolve_presets() {
    if [ "$1" = "all" ]; then
        (cd "$PRESET_DIR" && ls -- *.txt | sed 's/\.txt$//' | paste -sd, -)
    else
        printf '%s' "$1"
    fi
}

cmd_preset() {
    local names name file
    names="$(resolve_presets "$1")"
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
                local hdr token
                token="$(token_for_url "$url")"
                hdr="$(umask 077 && mktemp "$TMP_DIR/hdr.XXXXXX")"
                [ -n "$token" ] && printf 'Authorization: Bearer %s\n' "$token" > "$hdr"
                mkdir -p "$MODELS_DIR/$folder"
                log "downloading via curl into $folder/ (server-side filename)"
                (cd "$MODELS_DIR/$folder" && curl -fJLO --retry 3 -H @"$hdr" "$url")
                local rc=$?
                rm -f "$hdr"
                [ "$rc" -ne 0 ] && { warn "download failed"; exit 1; }
                return 0 ;;
        esac
    fi
    dl_file "$folder" "$filename" "$url"
}

cmd_civitai() {
    local version_id="$1" folder="${2:-loras}"
    cmd_url "https://civitai.com/api/download/models/$version_id" "$folder"
}

cmd_verify() {
    local names name file line folder filename url sha actual bad=0
    names="$(resolve_presets "${1:-all}")"
    for name in ${names//,/ }; do
        file="$PRESET_DIR/$name.txt"
        [ -f "$file" ] || continue
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            IFS='|' read -r folder filename url sha <<< "$line"
            local optional=0
            case "$folder" in
                optional:*) optional=1; folder="${folder#optional:}" ;;
            esac
            local dest="$MODELS_DIR/$folder/$filename"
            if [ ! -s "$dest" ]; then
                if [ "$optional" -eq 1 ]; then
                    echo "OPTIONAL    $folder/$filename (not present; not required)"
                else
                    echo "MISSING     $folder/$filename"
                fi
                continue
            fi
            if [ -f "$dest.aria2" ]; then
                echo "INCOMPLETE  $folder/$filename (resume with: comfy-dl preset $name)"
                bad=$((bad + 1))
                continue
            fi
            if [ -n "$sha" ]; then
                actual="$(sha256sum "$dest" | cut -d' ' -f1)"
                if [ "$actual" = "$sha" ]; then
                    echo "OK          $folder/$filename"
                else
                    echo "CORRUPT     $folder/$filename (delete it and re-run the preset)"
                    bad=$((bad + 1))
                fi
            else
                echo "PRESENT     $folder/$filename (no hash in manifest)"
            fi
        done < "$file"
    done
    [ "$bad" -gt 0 ] && exit 1
    exit 0
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
    verify)  shift; cmd_verify "${1:-all}" ;;
    list)    cmd_list ;;
    *)       sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

if [ "$FAILED" -gt 0 ]; then
    warn "$FAILED download(s) failed"
    exit 1
fi
log "all downloads complete"
