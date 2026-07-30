#!/usr/bin/env bash
# ComfyPod secrets manager (also installed as `comfypod-secrets`). The single
# rotation path for credentials — everything reads from secrets.env (0600).
#
#   comfypod-secrets set-password [value]     rotate the UI password everywhere
#   comfypod-secrets set-hf-token [value]     HuggingFace token
#   comfypod-secrets set-civitai-token [value]
#   comfypod-secrets show                     which secrets are set (masked)
#
# Values can be passed as an argument or entered at a hidden prompt.

export SCRIPT_NAME=secrets
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

# Values are shell-quoted (secrets_put in lib.sh) because secrets.env is
# sourced: an unquoted password containing a space would truncate, and one
# containing ';' or '$(...)' would run as code on the next boot.
upsert() { secrets_put "$1" "$2"; }

read_value() {
    local prompt="$1" val
    if [ -t 0 ]; then
        read -rs -p "$prompt: " val
        echo >&2
    else
        read -r val
    fi
    [ -n "$val" ] || die "empty value"
    printf '%s' "$val"
}

mask() {
    local v="$1"
    if [ -z "$v" ]; then printf '(not set)'
    elif [ "${#v}" -le 6 ]; then printf '****'
    else printf '%s****%s' "${v:0:3}" "${v: -3}"
    fi
}

case "${1:-}" in
    set-password)
        WEB_PASSWORD="${2:-$(read_value 'New password')}"
        export WEB_PASSWORD
        upsert WEB_PASSWORD "$WEB_PASSWORD"
        umask 077
        printf 'username: %s\npassword: %s\n' "$WEB_USER" "$WEB_PASSWORD" > "$STATE_DIR/credentials.txt"
        umask 022
        marker_rm login-pw-sig
        if [ -x "$PY" ]; then
            seed_login_password && log "ComfyUI-Login password updated"
        fi
        if [ -n "$(fb_bin)" ] && [ -f "$STATE_DIR/filebrowser.db" ]; then
            "$(fb_bin)" users update "$WEB_USER" --password "$WEB_PASSWORD" \
                -d "$STATE_DIR/filebrowser.db" > /dev/null 2>&1 && log "FileBrowser password updated"
        fi
        log "done. Restart services so Jupyter picks up the new token:"
        log "  comfypod-stop && bash $REPO_DIR/scripts/start.sh"
        ;;
    set-hf-token)
        upsert HF_TOKEN "${2:-$(read_value 'HuggingFace token')}"
        log "HF token stored — used automatically by comfy-dl from now on"
        ;;
    set-civitai-token)
        upsert CIVITAI_TOKEN "${2:-$(read_value 'Civitai token')}"
        log "Civitai token stored — used automatically by comfy-dl from now on"
        ;;
    show)
        echo "secrets file: $SECRETS_FILE ($(stat -c %a "$SECRETS_FILE" 2>/dev/null || echo missing))"
        echo "WEB_USER:      ${WEB_USER}"
        echo "WEB_PASSWORD:  $(mask "$WEB_PASSWORD")"
        echo "HF_TOKEN:      $(mask "$HF_TOKEN")"
        echo "CIVITAI_TOKEN: $(mask "$CIVITAI_TOKEN")"
        ;;
    *)
        sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
