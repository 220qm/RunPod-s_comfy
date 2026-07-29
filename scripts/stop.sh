#!/usr/bin/env bash
# Stop all ComfyPod services (also installed as `comfypod-stop`).
export SCRIPT_NAME=stop
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

for svc in comfyui caddy filebrowser jupyter; do
    stop_service "$svc"
done
log "all services stopped (restart with: bash $REPO_DIR/scripts/start.sh)"
