#!/usr/bin/env bash
# ComfyPod entrypoint. Idempotent: runs on every pod start, does the heavy
# lifting only once (state persisted on the /workspace network volume) and
# boots fast afterwards. Never exits non-zero for optional failures — a
# degraded boot that still gives you SSH + logs beats a dead pod.

export SCRIPT_NAME=start
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

COMFYUI_GIT="https://github.com/comfyanonymous/ComfyUI.git"

# ---------------------------------------------------------------------------
# Torch pin, enforced on every install path (see lib.sh PIP_CONSTRAINT).
# ---------------------------------------------------------------------------
# The constraint file is what stops a custom node downgrading torch, so it has
# to describe what is ACTUALLY installed. Writing $TORCH_SPEC blindly was a
# real hazard: if the image build fell back to another version, every later
# pip call would have tried to "restore" the pinned one — re-downloading
# gigabytes on every boot and breaking the baked environment.
write_constraints() {
    if [ "$COMFYPOD_BAKED" = "1" ] && [ -s /opt/constraints.txt ]; then
        cp /opt/constraints.txt "$CONSTRAINTS_FILE"          # frozen at build time
    elif [ -x "$PY" ] && "$PY" -c 'import torch' 2>/dev/null; then
        "$PY" -m pip freeze 2>/dev/null \
            | grep -iE '^(torch|torchvision|torchaudio)==' > "$CONSTRAINTS_FILE"
    fi
    # Nothing installed yet (first boot on a stock image): fall back to the pin.
    if [ ! -s "$CONSTRAINTS_FILE" ]; then
        # shellcheck disable=SC2086
        printf '%s\n' $TORCH_SPEC > "$CONSTRAINTS_FILE"
    fi
    export PIP_CONSTRAINT="$CONSTRAINTS_FILE"
    log "torch constraint: $(tr '\n' ' ' < "$CONSTRAINTS_FILE")"
}

# ---------------------------------------------------------------------------
# Secrets: /workspace/.comfypod/secrets.env (0600) is canonical. Template env
# vars (ideally RunPod Secrets) seed it on first boot; afterwards the pod
# works with no env vars at all, and rotation via `comfypod-secrets` sticks.
# ---------------------------------------------------------------------------
setup_secrets() {
    umask 077
    touch "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    local key val
    for key in WEB_USER WEB_PASSWORD HF_TOKEN CIVITAI_TOKEN; do
        val="${!key}"
        # Values are shell-quoted on write (secrets_put): this file is sourced,
        # so a password containing a space, quote or ';' must not truncate or
        # execute.
        if [ -n "$val" ] && ! grep -q "^$key=" "$SECRETS_FILE"; then
            secrets_put "$key" "$val"
        fi
    done
    PASSWORD_SOURCE="configured"
    if ! grep -q '^WEB_PASSWORD=' "$SECRETS_FILE"; then
        WEB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | head -c 20)"
        secrets_put WEB_PASSWORD "$WEB_PASSWORD"
        PASSWORD_SOURCE="generated"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
    umask 077
    printf 'username: %s\npassword: %s\n' "$WEB_USER" "$WEB_PASSWORD" > "$STATE_DIR/credentials.txt"
    secure_file "$STATE_DIR/credentials.txt" || true
    umask 022
    # RunPod's volume filesystem can ignore chmod, which would leave these
    # world-readable however carefully they are written. Say so once, plainly,
    # instead of pretending they are locked down.
    if ! fs_honours_chmod "$STATE_DIR"; then
        warn "the volume filesystem ignores chmod, so $SECRETS_FILE stays mode $(stat -c %a "$SECRETS_FILE" 2>/dev/null)."
        warn "  Only root runs in this container, so the practical exposure is low, but do"
        warn "  not treat the volume as a private store for anything beyond these tokens."
    fi
}

# ---------------------------------------------------------------------------
# Preflight: catch the classic footguns before they cost an hour of GPU time.
# ---------------------------------------------------------------------------
preflight() {
    if ! mountpoint -q "$WORKSPACE" 2>/dev/null; then
        warn "############################################################"
        warn "# $WORKSPACE is NOT a mounted volume. Models, settings and"
        warn "# outputs will be LOST when this pod is terminated. Attach a"
        warn "# network volume to the pod (mount path $WORKSPACE)."
        warn "############################################################"
    fi
    if command -v nvidia-smi > /dev/null; then
        log "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)"
        # A CUDA 13 build on a pre-580 driver imports fine and then dies at the
        # first CUDA call, so say it here rather than letting a workflow fail.
        if [ -x "$PY" ]; then
            local verdict
            if ! verdict="$(driver_check)"; then
                warn "############################################################"
                warn "# $verdict"
                warn "# Generation will fail on this host. Redeploy elsewhere, or"
                warn "# rebuild the image with"
                warn "#   TORCH_INDEX=https://download.pytorch.org/whl/cu128"
                warn "############################################################"
            else
                log "$verdict"
            fi
        fi
    else
        warn "no GPU visible — services will start, generation will not work"
    fi
    local free_ws free_ct
    free_ws="$(df -BG --output=avail "$WORKSPACE" 2>/dev/null | tail -1 | tr -dc 0-9)"
    free_ct="$(df -BG --output=avail "$(dirname "$VENV_DIR")" 2>/dev/null | tail -1 | tr -dc 0-9)"
    [ -n "$free_ws" ] && [ "$free_ws" -lt 30 ] && warn "only ${free_ws}GB free on $WORKSPACE — model downloads may fail"
    [ "$VENV_LOCATION" = "container" ] && [ -n "$free_ct" ] && [ "$free_ct" -lt 15 ] \
        && warn "only ${free_ct}GB free on container disk — venv build may fail (give the pod >=50GB container disk)"
}

install_apt_deps() {
    local pkgs=()
    command -v aria2c  > /dev/null || pkgs+=(aria2)
    command -v ffmpeg  > /dev/null || pkgs+=(ffmpeg)
    command -v rsync   > /dev/null || pkgs+=(rsync)
    ldconfig -p 2>/dev/null | grep -q libGL.so.1 || pkgs+=(libgl1 libglib2.0-0)
    if [ "${#pkgs[@]}" -gt 0 ]; then
        log "installing apt packages: ${pkgs[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
    fi
}

ensure_uv() {
    [ -n "$(uv_bin)" ] && return 0
    log "installing uv"
    curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR="$BIN_DIR" UV_NO_MODIFY_PATH=1 sh > /dev/null 2>&1 \
        || warn "uv install failed — falling back to pip (slower boots)"
}

fetch_binaries() {
    if [ -z "$(fb_bin)" ]; then
        log "downloading filebrowser"
        local ok=1 attempt
        for attempt in 1 2 3; do
            curl -fsSL --retry 2 --retry-delay 2 \
                "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
                | tar -xz -C "$BIN_DIR" filebrowser 2>/dev/null \
                && chmod +x "$BIN_DIR/filebrowser" && { ok=0; break; }
            warn "filebrowser download attempt $attempt failed"
            sleep 3
        done
        [ "$ok" -eq 0 ] || warn "filebrowser unavailable after 3 attempts — file manager will be skipped this boot; it retries next boot"
    fi
}

# ---------------------------------------------------------------------------
# Python env. Default: venv on container disk, rebuilt each boot from the
# lockfile with uv (cache on the volume, so warm rebuilds are quick and
# imports run at local-disk speed). VENV_LOCATION=volume skips the rebuild at
# the cost of slower imports.
# ---------------------------------------------------------------------------
setup_python_env() {
    if [ "$COMFYPOD_BAKED" = "1" ]; then
        # Everything is pre-installed in the image; only sanity-check it.
        # Deliberately a warning, not a die: a transient driver problem or a
        # CPU-only pod must still boot far enough to reach a shell, the logs
        # and comfypod-doctor.
        if torch_ok; then
            log "baked image: python env ready ($(torch_report))"
        else
            warn "baked image torch check failed: $(torch_check 2>&1 | tail -1)"
            warn "  continuing so the pod stays reachable — run comfypod-doctor for details"
        fi
        return 0
    fi
    local uv
    uv="$(uv_bin)"
    if [ ! -x "$PY" ]; then
        log "creating venv at $VENV_DIR ($VENV_LOCATION)"
        if [ -n "$uv" ]; then
            "$uv" venv -q --seed --python "$(command -v python3)" "$VENV_DIR" || die "venv creation failed"
        else
            python3 -m venv "$VENV_DIR" || die "venv creation failed"
            "$PIP" install -q --upgrade pip wheel setuptools
        fi
    fi
    if [ -f "$LOCK_FILE" ]; then
        log "restoring python env from lockfile (can take a few minutes on a cold cache)"
        if [ -n "$uv" ]; then
            run_with_heartbeat "restoring python env" -- \
                "$uv" pip sync --python "$PY" \
                --index-url https://pypi.org/simple --extra-index-url "$TORCH_INDEX" \
                "$LOCK_FILE" || warn "lock sync failed — rebuilding from scratch"
        else
            run_with_heartbeat "restoring python env" -- \
                "$PIP" install -r "$LOCK_FILE" --extra-index-url "$TORCH_INDEX" \
                || warn "lock restore failed — rebuilding from scratch"
        fi
    fi
    if ! torch_ok; then
        log "installing torch (${TORCH_INDEX##*/}) — the single biggest one-time download in"
        log "this boot (bundles the CUDA runtime, often several GB); cached afterwards."
        log "Progress prints below every 20s so this never looks stuck."
        # shellcheck disable=SC2086
        if ! run_with_heartbeat "installing torch" -- \
            pkg_install_loud $TORCH_SPEC --index-url "$TORCH_INDEX"; then
            # A CUDA 13 index that has no wheel for this pin must not end the
            # boot: fall back the same way the image build does.
            warn "torch install from ${TORCH_INDEX##*/} failed — retrying on ${TORCH_FALLBACK_INDEX##*/}"
            # shellcheck disable=SC2086
            run_with_heartbeat "installing torch (fallback index)" -- \
                pkg_install_loud $TORCH_SPEC --index-url "$TORCH_FALLBACK_INDEX" \
                || die "torch install failed on both $TORCH_INDEX and $TORCH_FALLBACK_INDEX"
        fi
    fi
    pkg_install hf_transfer "huggingface_hub[cli]" opencv-python-headless bcrypt \
        || warn "extras install failed"
    if [ "$ENABLE_JUPYTER" = "true" ] && [ ! -x "$VENV_DIR/bin/jupyter" ]; then
        log "installing jupyterlab"
        pkg_install jupyterlab || warn "jupyterlab install failed"
    fi
}

freeze_lock() {
    # The baked env is immutable state of the image — a lockfile would only
    # fight it on the next boot.
    [ "$COMFYPOD_BAKED" = "1" ] && return 0
    local uv
    uv="$(uv_bin)"
    if [ -n "$uv" ]; then
        "$uv" pip freeze --python "$PY" > "$LOCK_FILE.tmp" 2>/dev/null
    else
        "$PIP" freeze > "$LOCK_FILE.tmp" 2>/dev/null
    fi
    if [ -s "$LOCK_FILE.tmp" ]; then
        grep -v '^-e ' "$LOCK_FILE.tmp" > "$LOCK_FILE"
    fi
    rm -f "$LOCK_FILE.tmp"
}

resolve_latest_tag() {
    git -C "$COMFY_DIR" tag -l 'v*' --sort=-version:refname | head -n1
}

# Point the code tree's data directories at the volume. Only these need to
# survive the pod; keeping the code itself on container disk is what makes
# restarts and node installs fast (see COMFY_CODE_LOCATION in lib.sh).
link_comfy_data() {
    [ "$COMFY_CODE_LOCATION" = "container" ] || return 0
    local d target
    for d in $COMFY_DATA_SUBDIRS; do
        target="$COMFY_DATA_DIR/$d"
        mkdir -p "$target"
        # Anything the image shipped in that slot (e.g. ComfyUI's default model
        # folder skeleton) is merged onto the volume once, then replaced by a
        # symlink so both sides see the same files.
        if [ -d "$COMFY_DIR/$d" ] && [ ! -L "$COMFY_DIR/$d" ]; then
            cp -a "$COMFY_DIR/$d/." "$target/" 2>/dev/null || true
            rm -rf "${COMFY_DIR:?}/$d"
        fi
        [ -L "$COMFY_DIR/$d" ] || ln -s "$target" "$COMFY_DIR/$d"
    done
    log "code on container disk ($COMFY_DIR), data on the volume ($COMFY_DATA_DIR)"
}

setup_comfyui() {
    if [ "$COMFY_CODE_LOCATION" = "container" ]; then
        link_comfy_data
        # A pre-existing volume checkout keeps its models/outputs/workflows via
        # the symlinks above; its custom nodes are carried over by URL.
        if [ -d "$COMFY_DATA_DIR/custom_nodes" ] && ! marker_ok migrated-volume-nodes; then
            local d u
            for d in "$COMFY_DATA_DIR"/custom_nodes/*/; do
                [ -d "${d%/}/.git" ] || continue
                u="$(git -C "${d%/}" config --get remote.origin.url 2>/dev/null)" || continue
                [ -n "$u" ] && grep -qF "$u" "$STATE_DIR/extra-nodes.txt" 2>/dev/null \
                    || printf '%s\n' "$u" >> "$STATE_DIR/extra-nodes.txt"
            done
            marker_set migrated-volume-nodes
            log "migrated custom nodes from the previous volume layout"
        fi
    elif [ ! -d "$COMFY_DIR/.git" ]; then
        log "cloning ComfyUI"
        git clone --quiet "$COMFYUI_GIT" "$COMFY_DIR" || die "ComfyUI clone failed"
        local ref="$COMFYUI_REF"
        [ "$ref" = "latest" ] && ref="$(resolve_latest_tag)"
        [ -n "$ref" ] && git -C "$COMFY_DIR" checkout --quiet "$ref"
    elif [ "$AUTO_UPDATE" = "true" ]; then
        "$SCRIPT_DIR/update.sh" --comfyui-only || warn "ComfyUI auto-update failed"
    fi
    local tag
    tag="$(git -C "$COMFY_DIR" describe --tags --always)"
    log "ComfyUI at $tag"
    # Krea 2 needs the krea2 architecture tag, added in ComfyUI 0.26.0.
    if [ "$(printf 'v0.26.0\n%s\n' "$tag" | sort -V | head -n1)" != "v0.26.0" ]; then
        warn "ComfyUI $tag is older than v0.26.0 — Krea 2 will not load; run comfypod-update"
    fi
    run_with_heartbeat "installing ComfyUI requirements" -- \
        pkg_install -r "$COMFY_DIR/requirements.txt" || warn "ComfyUI requirements install failed"
}

# nodes.txt line format: <git-url>[@commit-or-tag]
install_node() {
    local spec="$1" url ref name dir
    url="${spec%@*}"
    ref=""
    [ "$spec" != "$url" ] && ref="${spec##*@}"
    name="$(basename "$url" .git)"
    dir="$COMFY_DIR/custom_nodes/$name"
    if [ ! -d "$dir/.git" ]; then
        log "installing node: $name${ref:+ @$ref}"
        if [ -n "$ref" ]; then
            git clone --quiet "$url" "$dir" && git -C "$dir" checkout --quiet "$ref" \
                || { warn "clone/checkout failed: $name"; return 1; }
        else
            git clone --quiet --depth 1 "$url" "$dir" || { warn "clone failed: $name"; return 1; }
        fi
    fi
    # requirements.txt is intentionally NOT installed here — heal_node_deps
    # does it once for every node on the volume, so doing it here too would
    # install the same set twice on every boot.
    if [ -f "$dir/install.py" ] && ! marker_ok "node-setup-$name"; then
        (cd "$dir" && timeout 600 "$PY" install.py < /dev/null) || warn "install.py failed: $name"
        marker_set "node-setup-$name"
    fi
}

# Python deps for EVERY node present on the volume — including ones installed
# from the Manager UI. Without this the venv (which is part of the image in
# baked mode, and therefore ephemeral) would come up next boot missing their
# requirements, and the node would silently fail to import.
# One resolver pass for every node instead of one per node: with ~10 nodes
# that is the difference between a single uv call and ten, each paying its own
# resolution and network round-trips.
heal_node_deps() {
    local dir name count=0 args=()
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        dir="${dir%/}"                       # keep paths free of a double slash
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        case "$name" in __pycache__|*.disabled) continue ;; esac
        [ -f "$dir/requirements.txt" ] || continue
        args+=(-r "$dir/requirements.txt")
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        log "no custom node requirements to install"
        return 0
    fi
    if ! pkg_install "${args[@]}"; then
        # One bad requirements file must not take the others down with it.
        warn "combined dependency install failed — retrying node by node"
        for dir in "$COMFY_DIR"/custom_nodes/*/; do
            dir="${dir%/}"
            [ -f "$dir/requirements.txt" ] || continue
            name="$(basename "$dir")"
            case "$name" in __pycache__|*.disabled) continue ;; esac
            pkg_install -r "$dir/requirements.txt" || warn "requirements failed: $name"
        done
    fi
    log "re-asserted python deps for $count custom node(s)"
}

setup_custom_nodes() {
    mkdir -p "$COMFY_DIR/custom_nodes"
    # Before anything is installed: put back what the last pod had. Registry
    # ("CNR") installs from the Manager UI have no git remote, so this archive
    # is the only thing that can bring them back.
    restore_nodes_from_volume
    local nodes_file="$REPO_DIR/config/nodes.txt" spec dir
    [ -f "$nodes_file" ] || nodes_file="$SCRIPT_DIR/../config/nodes.txt"
    # `< /dev/null` on every install: git and pip read stdin, and inside a
    # `while read ... done < file` loop they would otherwise swallow the
    # remaining lines and silently skip nodes.
    while IFS= read -r spec; do
        case "$spec" in ''|'#'*) continue ;; esac
        install_node "$spec" < /dev/null
    done < "$nodes_file"
    if [ -n "$EXTRA_NODES" ]; then
        for spec in ${EXTRA_NODES//,/ }; do
            install_node "$spec" < /dev/null
        done
    fi
    # Nodes added with `comfypod-node add` (persisted on the volume)
    if [ -f "$STATE_DIR/extra-nodes.txt" ]; then
        while IFS= read -r spec; do
            case "$spec" in ''|'#'*) continue ;; esac
            install_node "$spec" < /dev/null
        done < "$STATE_DIR/extra-nodes.txt"
    fi
    persist_nodes
    run_with_heartbeat "checking custom node dependencies" -- heal_node_deps
    # Record the exact commit of every node (the rollback primitive).
    : > "$NODES_LOCK.tmp"
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        [ -d "$dir/.git" ] || continue
        printf '%s|%s|%s\n' "$(basename "$dir")" \
            "$(git -C "$dir" config --get remote.origin.url)" \
            "$(git -C "$dir" rev-parse HEAD)" >> "$NODES_LOCK.tmp"
    done
    mv "$NODES_LOCK.tmp" "$NODES_LOCK"
    [ -f "$SNAPSHOT_DIR/baseline.lock" ] || cp "$NODES_LOCK" "$SNAPSHOT_DIR/baseline.lock"
}

# ComfyUI-Manager: make its install/update buttons actually work behind
# RunPod's proxy. Manager treats a 0.0.0.0 bind as "not local", which blocks
# unlisted/git-URL installs unless security_level is 'weak'; git-URL and pip
# installs need their own flags on top. Existing keys are preserved.
configure_manager() {
    [ -d "$COMFY_DIR/custom_nodes/ComfyUI-Manager" ] || return 0
    local cfg
    cfg="$(manager_config_path)"
    mkdir -p "$(dirname "$cfg")"
    MANAGER_CFG="$cfg" MANAGER_SECURITY_LEVEL="$MANAGER_SECURITY_LEVEL" "$PY" - <<'PY' || { warn "could not write Manager config"; return 1; }
import configparser, os
path = os.environ["MANAGER_CFG"]
cp = configparser.ConfigParser()
cp.read(path)                      # keeps whatever is already configured
if "default" not in cp:
    cp["default"] = {}
cp["default"]["security_level"] = os.environ["MANAGER_SECURITY_LEVEL"]
cp["default"]["allow_git_url_install"] = "true"
cp["default"]["allow_pip_install"] = "true"
with open(path, "w") as fh:
    cp.write(fh)
PY
    log "ComfyUI-Manager: security_level=$MANAGER_SECURITY_LEVEL, git-URL + pip installs enabled ($cfg)"
    if ! comfy_has_system_user_api; then
        warn "############################################################"
        warn "# This ComfyUI is too old to expose the System User"
        warn "# Protection API, so ComfyUI-Manager FORCES security_level"
        warn "# to 'strong' and blocks every install/update regardless of"
        warn "# the config above. Fix with:  comfypod-update"
        warn "############################################################"
    fi
}

# SageAttention: installed for per-workflow use (KJNodes "Patch Sage
# Attention" node). NOT enabled globally by default — the global flag has
# produced black output on Wan/Qwen-family models, which is exactly what runs
# here. v2 is compiled from source in the background for extra speed.
setup_sage_attention() {
    [ "$SAGE_ATTENTION" = "off" ] && return 0
    command -v nvidia-smi > /dev/null || { log "no GPU visible, skipping SageAttention"; return 0; }
    if ! "$PY" -c 'import sageattention' 2>/dev/null; then
        log "installing sageattention v1"
        pkg_install sageattention==1.0.6 || warn "sageattention v1 install failed"
    fi
    # Baked mode: v1 ships in the image; a background-compiled v2 would land
    # in the ephemeral image venv and vanish on the next pod, so skip it.
    [ "$COMFYPOD_BAKED" = "1" ] && return 0
    if ! marker_ok sage2 && command -v nvcc > /dev/null; then
        log "compiling SageAttention 2 in background (log: $LOG_DIR/sage2-build.log)"
        nohup bash -c "
            set -e
            arch=\$('$PY' -c 'import torch; c=torch.cuda.get_device_capability(); print(f\"{c[0]}.{c[1]}\")')
            rm -rf '$STATE_DIR/build/SageAttention'
            git clone --quiet --depth 1 https://github.com/thu-ml/SageAttention '$STATE_DIR/build/SageAttention'
            cd '$STATE_DIR/build/SageAttention'
            TORCH_CUDA_ARCH_LIST=\"\$arch\" EXT_PARALLEL=4 NVCC_APPEND_FLAGS='--threads 8' MAX_JOBS=8 '$PIP' install -q --no-build-isolation .
            touch '$MARKER_DIR/sage2'
            echo 'SageAttention 2 installed — available to the patch node after the next ComfyUI restart'
        " > "$LOG_DIR/sage2-build.log" 2>&1 &
    fi
}

start_services() {
    # ComfyUI is only bound publicly when ComfyUI-Login is present; the
    # auth-guard verifies the login page actually intercepts and forces the
    # bind back to 127.0.0.1 if it does not (fail closed).
    local listen=127.0.0.1
    [ -d "$COMFY_DIR/custom_nodes/ComfyUI-Login" ] && listen=0.0.0.0
    printf '%s' "$listen" > "$STATE_DIR/comfy-listen"
    [ "$listen" = "127.0.0.1" ] && warn "ComfyUI-Login missing — ComfyUI bound to localhost only (SSH tunnel: ssh -L 8188:localhost:8188)"

    local sage_flag=""
    if [ "$SAGE_ATTENTION" = "global" ] && "$PY" -c 'import sageattention' 2>/dev/null; then
        sage_flag=" --use-sage-attention"
    fi
    # fp16 accumulation: large sampling speedup on 40/50-series, negligible
    # quality cost. "all" enables the riskier --fast features too.
    local fast_flag=""
    case "$FAST_MODE" in
        off|'')            fast_flag="" ;;
        all)               fast_flag=" --fast" ;;
        *)                 fast_flag=" --fast $FAST_MODE" ;;
    esac
    log "performance: FAST_MODE=$FAST_MODE, SAGE_ATTENTION=$SAGE_ATTENTION"
    start_service comfyui "cd '$COMFY_DIR' && LISTEN=\$(cat '$STATE_DIR/comfy-listen' 2>/dev/null || echo 127.0.0.1) && '$PY' main.py --listen \"\$LISTEN\" --port $COMFYUI_PORT --preview-method auto$sage_flag$fast_flag $COMFYUI_FLAGS"

    if ! pgrep -f "scripts/auth-guard.sh" > /dev/null; then
        nohup bash "$SCRIPT_DIR/auth-guard.sh" >> "$LOG_DIR/auth-guard.log" 2>&1 &
    fi

    local admin_addr=0.0.0.0
    [ "$ADMIN_LOCAL_ONLY" = "true" ] && admin_addr=127.0.0.1

    local fb
    fb="$(fb_bin)"
    if [ -n "$fb" ]; then
        local fb_db="$STATE_DIR/filebrowser.db"
        if [ ! -f "$fb_db" ]; then
            "$fb" config init -d "$fb_db" > /dev/null
            "$fb" config set -d "$fb_db" --auth.method=json > /dev/null
            "$fb" users add "$WEB_USER" "$WEB_PASSWORD" --perm.admin -d "$fb_db" > /dev/null \
                || warn "filebrowser user creation failed"
        else
            "$fb" users update "$WEB_USER" --password "$WEB_PASSWORD" -d "$fb_db" > /dev/null 2>&1 \
                || warn "filebrowser password sync failed"
        fi
        start_service filebrowser "'$fb' -d '$fb_db' -r '$WORKSPACE' -a $admin_addr -p $FILEBROWSER_PORT"
    fi

    if [ "$ENABLE_JUPYTER" = "true" ] && [ -x "$VENV_DIR/bin/jupyter" ]; then
        if port_free "$JUPYTER_PORT"; then
            # \$WEB_PASSWORD expands inside the runner at start time — the
            # password never lands verbatim in a script on disk.
            start_service jupyter "'$VENV_DIR/bin/jupyter' lab --allow-root --no-browser --ip $admin_addr --port $JUPYTER_PORT --ServerApp.token=\"\$WEB_PASSWORD\" --ServerApp.root_dir='$WORKSPACE'"
        else
            log "port $JUPYTER_PORT busy (base image Jupyter?) — not starting a second instance"
        fi
    fi

    if [ "$IDLE_TIMEOUT_MINUTES" -gt 0 ] 2>/dev/null; then
        start_service idle-guard "bash '$SCRIPT_DIR/idle-guard.sh'"
    fi

    # Nodes installed from the Manager UI only exist on container disk; this
    # copies them to the volume while the pod is alive.
    start_service node-sync "bash '$SCRIPT_DIR/node-sync.sh'"
}

start_downloads() {
    [ "$DOWNLOAD_PRESETS" = "none" ] && return 0
    log "starting model downloads in background: $DOWNLOAD_PRESETS (log: $LOG_DIR/downloads.log)"
    nohup "$SCRIPT_DIR/download-models.sh" preset "$DOWNLOAD_PRESETS" \
        >> "$LOG_DIR/downloads.log" 2>&1 &
}

install_cli_shims() {
    ln -sf "$SCRIPT_DIR/download-models.sh" /usr/local/bin/comfy-dl 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/update.sh" /usr/local/bin/comfypod-update 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/stop.sh" /usr/local/bin/comfypod-stop 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/doctor.sh" /usr/local/bin/comfypod-doctor 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/secrets.sh" /usr/local/bin/comfypod-secrets 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/snapshot.sh" /usr/local/bin/comfypod-snapshot 2>/dev/null || true
    ln -sf "$SCRIPT_DIR/node.sh" /usr/local/bin/comfypod-node 2>/dev/null || true
}

print_connection_info() {
    local info="$STATE_DIR/CONNECTION_INFO.txt"
    local shown="(the one you configured)"
    [ "$PASSWORD_SOURCE" = "generated" ] && shown="$WEB_PASSWORD"
    {
        echo "=================================================================="
        echo " ComfyPod is up"
        echo "=================================================================="
        echo " ComfyUI:      $(pod_url "$COMFYUI_PORT")   (password login)"
        if [ "$ADMIN_LOCAL_ONLY" = "true" ]; then
        echo " FileBrowser:  ssh tunnel -> http://localhost:$FILEBROWSER_PORT"
        echo " JupyterLab:   ssh tunnel -> http://localhost:$JUPYTER_PORT"
        else
        echo " FileBrowser:  $(pod_url "$FILEBROWSER_PORT")   (user + password)"
        echo " JupyterLab:   $(pod_url "$JUPYTER_PORT")   (token = password)"
        fi
        echo ""
        echo " Username: $WEB_USER (FileBrowser; ComfyUI asks for the password only)"
        echo " Password: $shown"
        echo " (stored in $STATE_DIR/credentials.txt; rotate with comfypod-secrets)"
        echo ""
        echo " Model downloads: tail -f $LOG_DIR/downloads.log"
        echo " Health check:    comfypod-doctor"
        echo "=================================================================="
    } | tee "$info"
}

main() {
    log "=== ComfyPod boot ==="
    ensure_dirs
    write_constraints
    setup_secrets
    preflight
    install_apt_deps || warn "apt install failed — continuing"
    ensure_uv
    fetch_binaries
    setup_python_env
    write_constraints          # re-derive from what actually got installed
    setup_comfyui
    setup_custom_nodes
    configure_manager || true
    seed_login_password || true
    setup_sage_attention
    freeze_lock
    install_cli_shims
    start_services
    start_downloads
    print_connection_info
    log "boot finished"
}

main "$@"
