#!/usr/bin/env bash
# ComfyPod updater (also installed as `comfypod-update`). Explicit updates
# only — normal boots never touch working versions unless AUTO_UPDATE=true.
#
#   comfypod-update                update repo + ComfyUI + all custom nodes, restart
#   comfypod-update --comfyui-only used internally by start.sh for AUTO_UPDATE

export SCRIPT_NAME=update
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

update_comfyui() {
    [ -d "$COMFY_DIR/.git" ] || { warn "ComfyUI not installed yet"; return 1; }
    log "updating ComfyUI"
    git -C "$COMFY_DIR" fetch --quiet --tags origin || { warn "fetch failed"; return 1; }
    local ref="$COMFYUI_REF"
    if [ "$ref" = "latest" ]; then
        ref="$(git -C "$COMFY_DIR" tag -l 'v*' --sort=-version:refname | head -n1)"
    fi
    git -C "$COMFY_DIR" checkout --quiet "$ref" || { warn "checkout $ref failed"; return 1; }
    log "ComfyUI now at $(git -C "$COMFY_DIR" describe --tags --always)"
    local req_hash
    req_hash="$(md5sum "$COMFY_DIR/requirements.txt" | cut -d' ' -f1)"
    if ! marker_ok "comfy-reqs-$req_hash"; then
        "$PIP" install -q -r "$COMFY_DIR/requirements.txt" && marker_set "comfy-reqs-$req_hash"
    fi
}

if [ "${1:-}" = "--comfyui-only" ]; then
    update_comfyui
    exit $?
fi

log "updating ComfyPod repo"
git -C "$REPO_DIR" pull --ff-only --quiet || warn "repo update failed"

update_comfyui || true

log "updating custom nodes"
for dir in "$COMFY_DIR"/custom_nodes/*/; do
    [ -d "$dir/.git" ] || continue
    name="$(basename "$dir")"
    if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        log "updated $name"
        marker_rm "node-deps-$name"   # re-run its requirements on restart
    else
        warn "could not update $name (local changes?)"
    fi
done

log "restarting services"
"$SCRIPT_DIR/stop.sh"
exec bash "$SCRIPT_DIR/start.sh"
