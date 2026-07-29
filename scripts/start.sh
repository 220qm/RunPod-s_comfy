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
write_constraints() {
    printf '%s\n' $TORCH_SPEC > "$CONSTRAINTS_FILE"
    export PIP_CONSTRAINT="$CONSTRAINTS_FILE"
}

# ---------------------------------------------------------------------------
# Secrets: /workspace/.comfypod/secrets.env (0600) is canonical. Template env
# vars (ideally RunPod Secrets) seed it on first boot; afterwards the pod
# works with no env vars at all, and rotation via `comfypod-secrets` sticks.
# ---------------------------------------------------------------------------
setup_secrets() {
    umask 077
    touch "$SECRETS_FILE"
    local key val
    for key in WEB_USER WEB_PASSWORD HF_TOKEN CIVITAI_TOKEN; do
        val="${!key}"
        if [ -n "$val" ] && ! grep -q "^$key=" "$SECRETS_FILE"; then
            printf '%s=%s\n' "$key" "$val" >> "$SECRETS_FILE"
        fi
    done
    PASSWORD_SOURCE="configured"
    if ! grep -q '^WEB_PASSWORD=' "$SECRETS_FILE"; then
        WEB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | head -c 20)"
        printf 'WEB_PASSWORD=%s\n' "$WEB_PASSWORD" >> "$SECRETS_FILE"
        PASSWORD_SOURCE="generated"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
    printf 'username: %s\npassword: %s\n' "$WEB_USER" "$WEB_PASSWORD" > "$STATE_DIR/credentials.txt"
    umask 022
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
        log "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
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
    if [ ! -x "$BIN_DIR/filebrowser" ]; then
        log "downloading filebrowser"
        curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
            | tar -xz -C "$BIN_DIR" filebrowser 2>/dev/null \
            && chmod +x "$BIN_DIR/filebrowser" || warn "filebrowser download failed"
    fi
}

# ---------------------------------------------------------------------------
# Python env. Default: venv on container disk, rebuilt each boot from the
# lockfile with uv (cache on the volume, so warm rebuilds are quick and
# imports run at local-disk speed). VENV_LOCATION=volume skips the rebuild at
# the cost of slower imports.
# ---------------------------------------------------------------------------
setup_python_env() {
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
        log "restoring python env from lockfile"
        if [ -n "$uv" ]; then
            "$uv" pip sync -q --python "$PY" \
                --index-url https://pypi.org/simple --extra-index-url "$TORCH_INDEX" \
                "$LOCK_FILE" || warn "lock sync failed — rebuilding from scratch"
        else
            "$PIP" install -q -r "$LOCK_FILE" --extra-index-url "$TORCH_INDEX" \
                || warn "lock restore failed — rebuilding from scratch"
        fi
    fi
    if ! torch_ok; then
        log "installing torch (cu128) — one-time download, cached afterwards"
        # shellcheck disable=SC2086
        pkg_install $TORCH_SPEC --index-url "$TORCH_INDEX" || die "torch install failed"
    fi
    pkg_install hf_transfer "huggingface_hub[cli]" opencv-python-headless bcrypt \
        || warn "extras install failed"
    if [ "$ENABLE_JUPYTER" = "true" ] && [ ! -x "$VENV_DIR/bin/jupyter" ]; then
        log "installing jupyterlab"
        pkg_install jupyterlab || warn "jupyterlab install failed"
    fi
}

freeze_lock() {
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

setup_comfyui() {
    if [ ! -d "$COMFY_DIR/.git" ]; then
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
    # Re-assert python deps every boot: cheap with uv, and it heals a fresh
    # container venv or a node the Manager updated mid-session.
    if [ -f "$dir/requirements.txt" ]; then
        pkg_install -r "$dir/requirements.txt" || warn "requirements failed: $name"
    fi
    if [ -f "$dir/install.py" ] && ! marker_ok "node-setup-$name"; then
        (cd "$dir" && timeout 600 "$PY" install.py) || warn "install.py failed: $name"
        marker_set "node-setup-$name"
    fi
}

setup_custom_nodes() {
    mkdir -p "$COMFY_DIR/custom_nodes"
    local nodes_file="$REPO_DIR/config/nodes.txt" spec dir
    [ -f "$nodes_file" ] || nodes_file="$SCRIPT_DIR/../config/nodes.txt"
    while IFS= read -r spec; do
        case "$spec" in ''|'#'*) continue ;; esac
        install_node "$spec"
    done < "$nodes_file"
    if [ -n "$EXTRA_NODES" ]; then
        for spec in ${EXTRA_NODES//,/ }; do
            install_node "$spec"
        done
    fi
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
    start_service comfyui "cd '$COMFY_DIR' && LISTEN=\$(cat '$STATE_DIR/comfy-listen' 2>/dev/null || echo 127.0.0.1) && '$PY' main.py --listen \"\$LISTEN\" --port $COMFYUI_PORT --preview-method auto$sage_flag $COMFYUI_FLAGS"

    if ! pgrep -f "scripts/auth-guard.sh" > /dev/null; then
        nohup bash "$SCRIPT_DIR/auth-guard.sh" >> "$LOG_DIR/auth-guard.log" 2>&1 &
    fi

    local admin_addr=0.0.0.0
    [ "$ADMIN_LOCAL_ONLY" = "true" ] && admin_addr=127.0.0.1

    if [ -x "$BIN_DIR/filebrowser" ]; then
        local fb_db="$STATE_DIR/filebrowser.db"
        if [ ! -f "$fb_db" ]; then
            "$BIN_DIR/filebrowser" config init -d "$fb_db" > /dev/null
            "$BIN_DIR/filebrowser" config set -d "$fb_db" --auth.method=json > /dev/null
            "$BIN_DIR/filebrowser" users add "$WEB_USER" "$WEB_PASSWORD" --perm.admin -d "$fb_db" > /dev/null \
                || warn "filebrowser user creation failed"
        else
            "$BIN_DIR/filebrowser" users update "$WEB_USER" --password "$WEB_PASSWORD" -d "$fb_db" > /dev/null 2>&1 \
                || warn "filebrowser password sync failed"
        fi
        start_service filebrowser "'$BIN_DIR/filebrowser' -d '$fb_db' -r '$WORKSPACE' -a $admin_addr -p $FILEBROWSER_PORT"
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
    setup_comfyui
    setup_custom_nodes
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
