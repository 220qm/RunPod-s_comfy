#!/usr/bin/env bash
# ComfyPod one-time installer — run this once, by hand, in a pod terminal
# (JupyterLab → Terminal, RunPod Web Terminal, or SSH):
#
#   curl -fsSL https://raw.githubusercontent.com/220qm/RunPod-s_comfy/main/install.sh | bash
#
# Private repo? export GITHUB_TOKEN=ghp_... first.
# Different branch? export COMFYPOD_BRANCH=my-branch first.
#
# It clones the repo onto the network volume and provisions everything. When
# it finishes, it prints the one-line Container Start Command to paste into
# your RunPod template so every future pod boots automatically without any
# network fetch or token.

set -uo pipefail
WORKSPACE="${WORKSPACE:-/workspace}"
STATE_DIR="${STATE_DIR:-$WORKSPACE/.comfypod}"
REPO_DIR="${REPO_DIR:-$STATE_DIR/repo}"
COMFYPOD_REPO="${COMFYPOD_REPO:-https://github.com/220qm/RunPod-s_comfy.git}"
COMFYPOD_BRANCH="${COMFYPOD_BRANCH:-main}"

say() { printf '\n[comfypod] %s\n' "$*"; }

say "installing ComfyPod (branch: $COMFYPOD_BRANCH)"

if [ ! -d "$WORKSPACE" ]; then
    say "ERROR: $WORKSPACE does not exist — attach a network volume mounted at $WORKSPACE"
    exit 1
fi
if ! mountpoint -q "$WORKSPACE" 2>/dev/null; then
    say "WARNING: $WORKSPACE is not a mounted volume — everything will be lost when this pod is terminated"
fi

clone_url() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf '%s' "${COMFYPOD_REPO/https:\/\/github.com\//https://x-access-token:${GITHUB_TOKEN}@github.com/}"
    else
        printf '%s' "$COMFYPOD_REPO"
    fi
}

mkdir -p "$STATE_DIR"
if [ -d "$REPO_DIR/.git" ]; then
    say "updating existing checkout at $REPO_DIR"
    git -C "$REPO_DIR" fetch --quiet origin "$COMFYPOD_BRANCH" \
        && git -C "$REPO_DIR" reset --hard --quiet "origin/$COMFYPOD_BRANCH" \
        || say "WARNING: update failed, using the existing checkout"
else
    say "cloning into $REPO_DIR"
    if ! git clone --quiet --branch "$COMFYPOD_BRANCH" "$(clone_url)" "$REPO_DIR"; then
        say "ERROR: clone failed."
        say "  - private repo?  export GITHUB_TOKEN=ghp_... and re-run"
        say "  - wrong branch?  export COMFYPOD_BRANCH=<branch> and re-run"
        exit 1
    fi
fi

chmod +x "$REPO_DIR"/scripts/*.sh "$REPO_DIR/bootstrap.sh" 2>/dev/null

say "provisioning (first run takes a few minutes; models download in the background)"
bash "$REPO_DIR/scripts/start.sh"
rc=$?

cat <<EOF

==================================================================
 Next step — make this automatic for every future pod
==================================================================
 In your RunPod template, set the Container Start Command to
 exactly this line (no quotes, nothing else):

   bash $REPO_DIR/scripts/pod-entry.sh

 It reads from the network volume, so it needs no GitHub access and
 no token, and RunPod's start-command field cannot mangle it.
==================================================================
EOF
exit $rc
