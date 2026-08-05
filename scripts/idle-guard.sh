#!/usr/bin/env bash
# ComfyPod idle-guard: stops the pod after IDLE_TIMEOUT_MINUTES of genuine
# idleness — the biggest cost lever on rented GPUs. "Idle" requires ALL of:
#   - GPU utilization below 10% (no job rendering)
#   - no established client connection to ComfyUI (no open browser tab —
#     the ComfyUI frontend holds a websocket while open)
#   - no model download in flight
# A running job, an open tab, or an active download always resets the clock.
export SCRIPT_NAME=idle-guard
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

[ "$IDLE_TIMEOUT_MINUTES" -gt 0 ] 2>/dev/null || exit 0
if ! command -v runpodctl > /dev/null || [ -z "${RUNPOD_API_KEY:-}" ] || [ -z "${RUNPOD_POD_ID:-}" ]; then
    log "runpodctl or RUNPOD_API_KEY/RUNPOD_POD_ID unavailable — idle auto-stop disabled"
    exit 0
fi
log "armed: pod stops after $IDLE_TIMEOUT_MINUTES fully idle minutes (IDLE_TIMEOUT_MINUTES=0 disables)"

gpu_busy() {
    local util
    util="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sort -nr | head -1)"
    [ -n "$util" ] && [ "$util" -ge 10 ]
}

clients_connected() {
    ss -Htn state established "( sport = :$COMFYUI_PORT )" 2>/dev/null \
        | awk '$4 !~ /^127\.0\.0\.1/ && $4 != "" { n++ } END { exit n ? 0 : 1 }'
}

downloads_running() {
    pgrep -x aria2c > /dev/null || pgrep -f download-models.sh > /dev/null
}

sleep 900   # grace period after boot (first downloads, first workflow)
idle_min=0
while true; do
    sleep 60
    if gpu_busy || clients_connected || downloads_running; then
        idle_min=0
        continue
    fi
    idle_min=$((idle_min + 1))
    if [ "$idle_min" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
        log "idle for ${idle_min} min — stopping pod $RUNPOD_POD_ID (volume and models persist)"
        # The pod is about to go away with its container disk; make sure any
        # node installed from the UI is on the volume first.
        persist_nodes
        runpodctl stop pod "$RUNPOD_POD_ID" && sleep 300
        idle_min=0
    fi
done
