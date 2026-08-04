#!/usr/bin/env bash
# Stop all ComfyPod services (also installed as `comfypod-stop`).
export SCRIPT_NAME=stop
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

# Last chance to get UI-installed nodes onto the volume before everything that
# would have done it later is killed.
persist_nodes

for svc in comfyui filebrowser jupyter idle-guard node-sync; do
    stop_service "$svc"
done
pkill -f "scripts/auth-guard.sh" 2>/dev/null || true
log "all services stopped (restart with: bash $REPO_DIR/scripts/start.sh)"
