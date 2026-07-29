#!/usr/bin/env bash
# ComfyPod node snapshots (also installed as `comfypod-snapshot`): pin and
# restore the exact commit of every custom node. A broken node update is one
# command away from being undone. "baseline" is saved automatically after the
# first successful install.
#
#   comfypod-snapshot save [name]      default name: timestamp
#   comfypod-snapshot restore <name>   e.g. restore baseline
#   comfypod-snapshot list

export SCRIPT_NAME=snapshot
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

cmd_save() {
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"
    local out="$SNAPSHOT_DIR/$name.lock" dir
    : > "$out.tmp"
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        [ -d "$dir/.git" ] || continue
        printf '%s|%s|%s\n' "$(basename "$dir")" \
            "$(git -C "$dir" config --get remote.origin.url)" \
            "$(git -C "$dir" rev-parse HEAD)" >> "$out.tmp"
    done
    mv "$out.tmp" "$out"
    [ -f "$LOCK_FILE" ] && cp "$LOCK_FILE" "$SNAPSHOT_DIR/$name.requirements.lock"
    log "saved snapshot '$name' ($(wc -l < "$out") nodes)"
}

cmd_restore() {
    local name="${1:?usage: comfypod-snapshot restore <name>}"
    local lock="$SNAPSHOT_DIR/$name.lock"
    [ -f "$lock" ] || die "no snapshot named '$name' (see: comfypod-snapshot list)"
    local nname url sha dir
    while IFS='|' read -r nname url sha; do
        dir="$COMFY_DIR/custom_nodes/$nname"
        if [ ! -d "$dir/.git" ]; then
            log "cloning $nname"
            git clone --quiet "$url" "$dir" || { warn "clone failed: $nname"; continue; }
        fi
        if [ "$(git -C "$dir" rev-parse HEAD)" != "$sha" ]; then
            log "pinning $nname -> ${sha:0:12}"
            git -C "$dir" fetch --quiet origin || warn "fetch failed: $nname"
            git -C "$dir" checkout --quiet "$sha" || warn "checkout failed: $nname"
        fi
        [ -f "$dir/requirements.txt" ] && pkg_install -r "$dir/requirements.txt"
    done < "$lock"
    if [ -f "$SNAPSHOT_DIR/$name.requirements.lock" ]; then
        cp "$SNAPSHOT_DIR/$name.requirements.lock" "$LOCK_FILE"
        log "python lockfile restored (applies fully on next boot)"
    fi
    log "snapshot '$name' restored — restart to apply: comfypod-stop && bash $SCRIPT_DIR/start.sh"
}

cmd_list() {
    local f
    for f in "$SNAPSHOT_DIR"/*.lock; do
        [ -e "$f" ] || { echo "(no snapshots yet)"; return 0; }
        case "$f" in *.requirements.lock) continue ;; esac
        printf '%-28s %s nodes\n' "$(basename "$f" .lock)" "$(wc -l < "$f")"
    done
}

case "${1:-}" in
    save)    shift; cmd_save "${1:-}" ;;
    restore) shift; cmd_restore "${1:-}" ;;
    list)    cmd_list ;;
    *)       sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
