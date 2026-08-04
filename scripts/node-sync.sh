#!/usr/bin/env bash
# ComfyPod node-sync: keep custom nodes installed from the ComfyUI-Manager UI
# alive across pods.
#
# The code tree runs from container disk, which is destroyed with the pod, so
# a node installed at 14:00 on a pod terminated at 15:00 would be gone — a
# boot-time capture never gets to see it, because by the next boot the disk it
# lived on no longer exists. This sweeps on a timer instead.
#
# Cheap by construction: a directory listing, and a tar only for nodes whose
# contents changed since the last sweep.
export SCRIPT_NAME=node-sync
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

if [ "$COMFY_CODE_LOCATION" != "container" ]; then
    log "code runs from the volume — nodes already persist, nothing to sync"
    exit 0
fi

log "watching $COMFY_DIR/custom_nodes every ${NODE_SYNC_INTERVAL}s"
while true; do
    persist_nodes
    sleep "$NODE_SYNC_INTERVAL"
done
