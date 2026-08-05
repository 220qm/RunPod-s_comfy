#!/usr/bin/env bash
# ComfyPod custom-node manager (also installed as `comfypod-node`). A
# guaranteed-working install path that does not depend on the Manager UI —
# and unlike Manager, what it installs is recorded on the volume, so it is
# reinstalled automatically on every future pod.
#
#   comfypod-node add <git-url>[@ref]   install a node and remember it
#   comfypod-node remove <name>         uninstall and forget it
#   comfypod-node list                  show installed nodes and their origin
#   comfypod-node fix                   reinstall python deps for every node
#   comfypod-node sync                  persist UI-installed nodes to the volume now
#
# After add/remove, restart ComfyUI to load the change:
#   comfypod-stop && bash <repo>/scripts/start.sh
# (or use ComfyUI's own "Restart" button)

export SCRIPT_NAME=node
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

EXTRA_FILE="$STATE_DIR/extra-nodes.txt"

node_name_from_url() {
    basename "${1%@*}" .git
}

cmd_add() {
    local spec="$1" name dir
    case "$spec" in
        http://*|https://*|git@*) ;;
        *) die "expected a git URL, got: $spec" ;;
    esac
    name="$(node_name_from_url "$spec")"
    dir="$COMFY_DIR/custom_nodes/$name"

    if [ -d "$dir" ]; then
        log "$name is already installed ($dir)"
    else
        local url="${spec%@*}" ref=""
        [ "$spec" != "$url" ] && ref="${spec##*@}"
        log "cloning $name${ref:+ @$ref}"
        if [ -n "$ref" ]; then
            git clone --quiet "$url" "$dir" && git -C "$dir" checkout --quiet "$ref" \
                || die "clone/checkout failed"
        else
            git clone --quiet --depth 1 "$url" "$dir" || die "clone failed"
        fi
    fi

    if [ -f "$dir/requirements.txt" ]; then
        log "installing python deps"
        run_with_heartbeat "installing deps for $name" -- \
            pkg_install -r "$dir/requirements.txt" || warn "some deps failed — check the node's README"
    fi
    if [ -f "$dir/install.py" ]; then
        (cd "$dir" && timeout 600 "$PY" install.py) || warn "install.py failed"
    fi

    touch "$EXTRA_FILE"
    if ! grep -qxF "$spec" "$EXTRA_FILE"; then
        printf '%s\n' "$spec" >> "$EXTRA_FILE"
        log "recorded in $EXTRA_FILE — will be reinstalled on future pods"
    fi
    log "done. Restart ComfyUI to load it (ComfyUI menu -> Restart, or comfypod-stop && start.sh)"
}

cmd_remove() {
    local name="$1" dir="$COMFY_DIR/custom_nodes/$1"
    # Refuse to break the pod's own auth/management surface — checked before
    # anything else, so the answer never depends on current disk state.
    case "$name" in
        ComfyUI-Login|ComfyUI-Manager)
            die "$name is part of ComfyPod's auth/management surface — removing it would lock you out or disable the manager" ;;
    esac
    [ -d "$dir" ] || die "not installed: $name"
    rm -rf "$dir"
    if [ -f "$EXTRA_FILE" ]; then
        grep -v "/$name\(\.git\)\?\(@.*\)\?$" "$EXTRA_FILE" > "$EXTRA_FILE.tmp" 2>/dev/null || : > "$EXTRA_FILE.tmp"
        mv "$EXTRA_FILE.tmp" "$EXTRA_FILE"
    fi
    log "removed $name (python deps left in place — harmless)"
    log "note: if it is listed in config/nodes.txt it returns on the next boot"
}

cmd_list() {
    local dir name origin
    printf '%-38s %-9s %s\n' NODE STATE ORIGIN
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        case "$name" in __pycache__) continue ;; esac
        origin="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || echo '(not a git checkout)')"
        printf '%-38s %-9s %s\n' "$name" \
            "$([ -d "$dir/.git" ] && echo git || echo plain)" "$origin"
    done
    if [ -s "$EXTRA_FILE" ]; then
        echo
        echo "Recorded for reinstall on future pods ($EXTRA_FILE):"
        sed 's/^/  /' "$EXTRA_FILE"
    fi
}

cmd_fix() {
    local dir name count=0
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        case "$name" in __pycache__|*.disabled) continue ;; esac
        [ -f "$dir/requirements.txt" ] || continue
        log "deps: $name"
        pkg_install -r "$dir/requirements.txt" || warn "failed: $name"
        count=$((count + 1))
    done
    log "processed $count node(s). Restart ComfyUI to load them."
}

case "${1:-}" in
    add)    shift; cmd_add "${1:?usage: comfypod-node add <git-url>[@ref]}" ;;
    remove) shift; cmd_remove "${1:?usage: comfypod-node remove <name>}" ;;
    list)   cmd_list ;;
    fix)    cmd_fix ;;
    # The node-sync service does this every couple of minutes; this is the
    # button for "I just installed something and I'm terminating the pod now".
    sync)   persist_nodes; log "custom nodes persisted to $NODE_ARCHIVE_DIR" ;;
    *)      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
