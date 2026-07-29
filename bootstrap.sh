#!/usr/bin/env bash
# ComfyPod bootstrap — the single entry point for every launch mode:
#
#   1. curl | bash        (RunPod template start command, public repo)
#   2. baked Docker image (repo copied to /opt/comfypod at build time)
#   3. already on volume  (/workspace/.comfypod/repo/bootstrap.sh)
#
# It puts/refreshes the repo at /workspace/.comfypod/repo and hands off to
# scripts/start.sh. Safe to run on every pod start.

set -uo pipefail
WORKSPACE="${WORKSPACE:-/workspace}"
STATE_DIR="${STATE_DIR:-$WORKSPACE/.comfypod}"
REPO_DIR="${REPO_DIR:-$STATE_DIR/repo}"
COMFYPOD_REPO="${COMFYPOD_REPO:-https://github.com/220qm/RunPod-s_comfy.git}"
COMFYPOD_BRANCH="${COMFYPOD_BRANCH:-main}"

log() { printf '%s [bootstrap] %s\n' "$(date '+%F %T')" "$*"; }

[ -d "$WORKSPACE" ] || { log "ERROR: $WORKSPACE not found — attach a volume"; exit 1; }
mkdir -p "$STATE_DIR"

# Private repos: export GITHUB_TOKEN (e.g. a fine-grained read-only PAT).
clone_url() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf '%s' "${COMFYPOD_REPO/https:\/\/github.com\//https://x-access-token:${GITHUB_TOKEN}@github.com/}"
    else
        printf '%s' "$COMFYPOD_REPO"
    fi
}

# Where is this script running from?
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ "$SELF_DIR" = "$REPO_DIR" ]; then
    # Already on the volume — optionally fast-forward.
    if [ "${AUTO_UPDATE:-false}" = "true" ] && [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull --ff-only --quiet || log "WARN: repo update failed, using current version"
    fi
elif [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/scripts/start.sh" ]; then
    # Running from a local copy (baked image) — sync it onto the volume so the
    # whole stack self-contains on /workspace.
    log "syncing repo from $SELF_DIR to $REPO_DIR"
    if command -v rsync > /dev/null; then
        mkdir -p "$REPO_DIR"
        rsync -a --delete "$SELF_DIR/" "$REPO_DIR/"
    else
        rm -rf "$REPO_DIR"
        mkdir -p "$REPO_DIR"
        cp -a "$SELF_DIR/." "$REPO_DIR/"
    fi
else
    # curl | bash — clone or update from GitHub.
    if [ -d "$REPO_DIR/.git" ]; then
        log "updating repo at $REPO_DIR"
        git -C "$REPO_DIR" fetch --quiet origin "$COMFYPOD_BRANCH" \
            && git -C "$REPO_DIR" reset --hard --quiet "origin/$COMFYPOD_BRANCH" \
            || log "WARN: repo update failed, using current version"
    else
        log "cloning $COMFYPOD_REPO ($COMFYPOD_BRANCH)"
        git clone --quiet --branch "$COMFYPOD_BRANCH" "$(clone_url)" "$REPO_DIR" \
            || { log "ERROR: clone failed (private repo? set GITHUB_TOKEN)"; exit 1; }
    fi
fi

chmod +x "$REPO_DIR"/scripts/*.sh "$REPO_DIR/bootstrap.sh" 2>/dev/null
exec bash "$REPO_DIR/scripts/start.sh"
