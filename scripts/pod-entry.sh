#!/usr/bin/env bash
# ComfyPod pod entry point — the thing a RunPod template's "Container Start
# Command" should point at:
#
#     bash /workspace/.comfypod/repo/scripts/pod-entry.sh
#
# No quotes, no pipes, no && — RunPod's start-command field mangles nested
# quoting, and a mangled command fails silently, leaving a pod that boots with
# only the base image's services. This form cannot be mangled, needs no
# network access and no GitHub token (the repo is already on the volume), and
# prints everything to the container log.
#
# It starts ComfyPod in the background, then hands PID 1 to the base image's
# /start.sh so SSH and the RunPod plumbing come up normally.

set -u
WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BOOT_LOG="$WORKSPACE/comfypod-boot.log"

echo "[comfypod] pod-entry: starting bootstrap from $SCRIPT_DIR"

if [ ! -f "$SCRIPT_DIR/../bootstrap.sh" ]; then
    echo "[comfypod] !!! bootstrap.sh not found next to $SCRIPT_DIR — is the volume attached at $WORKSPACE?"
else
    # tee, not >: boot progress and failures must be visible in the pod's
    # container log, not buried in a file nobody thinks to open.
    ( bash "$SCRIPT_DIR/../bootstrap.sh" 2>&1 | tee -a "$BOOT_LOG" ) &
fi

if [ -x /start.sh ]; then
    echo "[comfypod] handing off to the base image /start.sh (SSH, proxy)"
    exec /start.sh
fi

echo "[comfypod] no /start.sh in this image — holding the container open"
tail -f /dev/null
