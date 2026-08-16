#!/usr/bin/env bash
# ComfyPod updater (also installed as `comfypod-update`).
#
# Boots already update everything when AUTO_UPDATE=true (the default), so this
# is the on-demand version of the same thing: it re-runs the boot with updates
# forced on, which is the only implementation of "bring everything current" —
# ComfyUI to the newest release tag, every git-backed custom node
# fast-forwarded, requirements reinstalled, then the compatibility report.
#
# A snapshot is saved first, so a broken update is one restore away:
#   comfypod-snapshot restore pre-update-<timestamp>
#
#   comfypod-update                update repo + ComfyUI + all custom nodes, restart
#   comfypod-update --comfyui-only update ComfyUI only, without restarting

export SCRIPT_NAME=update
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

update_comfyui() {
    [ -d "$COMFY_DIR/.git" ] || { warn "ComfyUI not installed yet"; return 1; }
    log "updating ComfyUI"
    git -C "$COMFY_DIR" fetch --quiet --tags --force origin || { warn "fetch failed"; return 1; }
    local ref="$COMFYUI_REF"
    if [ "$ref" = "latest" ]; then
        ref="$(git -C "$COMFY_DIR" tag -l 'v*' --sort=-version:refname | head -n1)"
    fi
    git -C "$COMFY_DIR" checkout --quiet --force "$ref" || { warn "checkout $ref failed"; return 1; }
    log "ComfyUI now at $(git -C "$COMFY_DIR" describe --tags --always)"
    pkg_install -r "$COMFY_DIR/requirements.txt" || warn "requirements install failed"
}

if [ "${1:-}" = "--comfyui-only" ]; then
    update_comfyui
    exit $?
fi

"$SCRIPT_DIR/snapshot.sh" save "pre-update-$(date +%Y%m%d-%H%M%S)" \
    || warn "snapshot failed — continuing without a rollback point"

log "updating ComfyPod repo"
git -C "$REPO_DIR" pull --ff-only --quiet || warn "repo update failed"

log "restarting with updates forced on"
"$SCRIPT_DIR/stop.sh"
AUTO_UPDATE=true exec bash "$SCRIPT_DIR/start.sh"
