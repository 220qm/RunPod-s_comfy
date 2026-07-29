#!/usr/bin/env bash
# ComfyPod entrypoint. Idempotent: runs on every pod start, does the heavy
# lifting only once (state persisted on the /workspace network volume) and
# boots in seconds afterwards. Never exits non-zero for optional failures —
# a degraded boot that still gives you SSH + logs beats a dead pod.

export SCRIPT_NAME=start
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail

COMFYUI_GIT="https://github.com/comfyanonymous/ComfyUI.git"
TORCH_SPEC="${TORCH_SPEC:-torch==2.8.0 torchvision torchaudio}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"

# ---------------------------------------------------------------------------
# Credentials: env var wins, else reuse the persisted password, else generate.
# ---------------------------------------------------------------------------
setup_credentials() {
    local cred_file="$STATE_DIR/credentials.txt"
    PASSWORD_SOURCE="env"
    if [ -z "$WEB_PASSWORD" ]; then
        if [ -f "$cred_file" ]; then
            WEB_PASSWORD="$(awk -F': ' '/^password/{print $2}' "$cred_file")"
            PASSWORD_SOURCE="persisted"
        fi
    fi
    if [ -z "$WEB_PASSWORD" ]; then
        WEB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | head -c 20)"
        PASSWORD_SOURCE="generated"
    fi
    export WEB_PASSWORD
    umask 077
    printf 'username: %s\npassword: %s\n' "$WEB_USER" "$WEB_PASSWORD" > "$cred_file"
    umask 022
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

# Caddy (auth proxy) and FileBrowser static binaries, cached on the volume.
fetch_binaries() {
    if [ ! -x "$BIN_DIR/caddy" ]; then
        log "downloading caddy"
        curl -fsSL -o "$BIN_DIR/caddy" "https://caddyserver.com/api/download?os=linux&arch=amd64" \
            && chmod +x "$BIN_DIR/caddy" || warn "caddy download failed"
    fi
    if [ ! -x "$BIN_DIR/filebrowser" ]; then
        log "downloading filebrowser"
        curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
            | tar -xz -C "$BIN_DIR" filebrowser 2>/dev/null \
            && chmod +x "$BIN_DIR/filebrowser" || warn "filebrowser download failed"
    fi
}

# ---------------------------------------------------------------------------
# Python venv on the volume: torch pinned to cu128 (works on 4090, RTX 4500
# and the Blackwell 5090). First boot ~4 min, afterwards instant.
# ---------------------------------------------------------------------------
setup_venv() {
    if [ ! -x "$PY" ]; then
        log "creating venv at $VENV_DIR"
        python3 -m venv "$VENV_DIR" || die "venv creation failed"
        "$PIP" install -q --upgrade pip wheel setuptools
    fi
    if ! "$PY" -c 'import torch; assert torch.version.cuda and torch.version.cuda.startswith("12.8")' 2>/dev/null; then
        log "installing torch (cu128) — one-time, a few minutes"
        # shellcheck disable=SC2086
        "$PIP" install -q $TORCH_SPEC --index-url "$TORCH_INDEX" || die "torch install failed"
    fi
    if ! marker_ok venv-extras; then
        log "installing python extras"
        "$PIP" install -q hf_transfer "huggingface_hub[cli]" opencv-python-headless \
            && marker_set venv-extras
    fi
    if [ "$ENABLE_JUPYTER" = "true" ] && [ ! -x "$VENV_DIR/bin/jupyter" ]; then
        log "installing jupyterlab"
        "$PIP" install -q jupyterlab || warn "jupyterlab install failed"
    fi
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
        log "ComfyUI at $(git -C "$COMFY_DIR" describe --tags --always)"
    elif [ "$AUTO_UPDATE" = "true" ]; then
        "$SCRIPT_DIR/update.sh" --comfyui-only || warn "ComfyUI auto-update failed"
    fi
    local req_hash
    req_hash="$(md5sum "$COMFY_DIR/requirements.txt" | cut -d' ' -f1)"
    if ! marker_ok "comfy-reqs-$req_hash"; then
        log "installing ComfyUI requirements"
        "$PIP" install -q -r "$COMFY_DIR/requirements.txt" && marker_set "comfy-reqs-$req_hash"
    fi
}

install_node() {
    local url="$1" name dir
    name="$(basename "$url" .git)"
    dir="$COMFY_DIR/custom_nodes/$name"
    if [ ! -d "$dir/.git" ]; then
        log "installing node: $name"
        git clone --quiet --depth 1 "$url" "$dir" || { warn "clone failed: $name"; return 1; }
        marker_rm "node-deps-$name"
    fi
    if ! marker_ok "node-deps-$name"; then
        if [ -f "$dir/requirements.txt" ]; then
            "$PIP" install -q -r "$dir/requirements.txt" || warn "requirements failed: $name"
        fi
        if [ -f "$dir/install.py" ]; then
            (cd "$dir" && timeout 600 "$PY" install.py) || warn "install.py failed: $name"
        fi
        marker_set "node-deps-$name"
    fi
}

setup_custom_nodes() {
    mkdir -p "$COMFY_DIR/custom_nodes"
    local nodes_file="$REPO_DIR/config/nodes.txt" url
    [ -f "$nodes_file" ] || nodes_file="$SCRIPT_DIR/../config/nodes.txt"
    while IFS= read -r url; do
        case "$url" in ''|'#'*) continue ;; esac
        install_node "$url"
    done < "$nodes_file"
    if [ -n "$EXTRA_NODES" ]; then
        for url in ${EXTRA_NODES//,/ }; do
            install_node "$url"
        done
    fi
}

# SageAttention: v1 (pip, seconds) gives an immediate speedup; v2 is compiled
# from source in the background and takes effect on the next restart.
setup_sage_attention() {
    [ "$SAGE_ATTENTION" = "off" ] && return 0
    command -v nvidia-smi > /dev/null || { log "no GPU visible, skipping SageAttention"; return 0; }
    if ! "$PY" -c 'import sageattention' 2>/dev/null; then
        log "installing sageattention v1"
        "$PIP" install -q sageattention==1.0.6 || warn "sageattention v1 install failed"
    fi
    if ! marker_ok sage2 && command -v nvcc > /dev/null && [ "$SAGE_ATTENTION" != "1" ]; then
        log "compiling SageAttention 2 in background (log: $LOG_DIR/sage2-build.log)"
        nohup bash -c "
            set -e
            arch=\$('$PY' -c 'import torch; c=torch.cuda.get_device_capability(); print(f\"{c[0]}.{c[1]}\")')
            rm -rf '$STATE_DIR/build/SageAttention'
            git clone --quiet --depth 1 https://github.com/thu-ml/SageAttention '$STATE_DIR/build/SageAttention'
            cd '$STATE_DIR/build/SageAttention'
            TORCH_CUDA_ARCH_LIST=\"\$arch\" EXT_PARALLEL=4 NVCC_APPEND_FLAGS='--threads 8' MAX_JOBS=8 '$PIP' install -q --no-build-isolation .
            touch '$MARKER_DIR/sage2'
            echo 'SageAttention 2 installed — active after the next ComfyUI restart'
        " > "$LOG_DIR/sage2-build.log" 2>&1 &
    fi
}

write_caddyfile() {
    local hash
    hash="$("$BIN_DIR/caddy" hash-password --plaintext "$WEB_PASSWORD")" || return 1
    cat > "$STATE_DIR/Caddyfile" <<EOF
{
    admin off
    auto_https off
}

:$PROXY_PORT {
    basic_auth {
        $WEB_USER $hash
    }
    reverse_proxy 127.0.0.1:$COMFYUI_PORT
}

:$DASHBOARD_PORT {
    basic_auth {
        $WEB_USER $hash
    }
    root * $WWW_DIR
    file_server
}
EOF
}

write_dashboard() {
    cat > "$WWW_DIR/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ComfyPod</title><style>
body{font-family:system-ui,sans-serif;background:#101418;color:#e6e6e6;max-width:720px;margin:3rem auto;padding:0 1rem}
a{color:#7ab8ff;text-decoration:none}a:hover{text-decoration:underline}
.card{background:#1a2027;border:1px solid #2a323c;border-radius:10px;padding:1rem 1.25rem;margin:.75rem 0}
h1{font-size:1.4rem}code{background:#232b34;padding:.1rem .35rem;border-radius:4px}
small{color:#9aa5b1}</style></head><body>
<h1>ComfyPod &mdash; private ComfyUI on RunPod</h1>
<div class="card"><b><a href="$(pod_url "$PROXY_PORT")">ComfyUI</a></b><br>
<small>Image &amp; video generation. Login with your ComfyPod username/password.</small></div>
<div class="card"><b><a href="$(pod_url "$FILEBROWSER_PORT")">FileBrowser</a></b><br>
<small>Full /workspace filesystem: upload/download models, LoRAs, outputs.</small></div>
<div class="card"><b><a href="$(pod_url "$JUPYTER_PORT")">JupyterLab</a></b><br>
<small>Terminal &amp; notebooks — install packages, run scripts. Token = your password.</small></div>
<div class="card"><b>Model downloads</b><br>
<small>Presets download in the background on first boot. Progress:
<code>tail -f /workspace/.comfypod/logs/downloads.log</code> &middot; add more anytime with
<code>comfy-dl &lt;url&gt; [folder]</code> or via ComfyUI-Manager.</small></div>
<div class="card"><b>Credentials</b><br>
<small>Stored at <code>/workspace/.comfypod/credentials.txt</code></small></div>
</body></html>
EOF
}

start_services() {
    # ComfyUI binds to localhost only; the internet-facing side is Caddy with
    # basic auth. If Caddy is missing nothing is exposed — fail closed.
    local flags="--listen 127.0.0.1 --port $COMFYUI_PORT --preview-method auto"
    if "$PY" -c 'import sageattention' 2>/dev/null; then
        flags="$flags --use-sage-attention"
    fi
    start_service comfyui "cd '$COMFY_DIR' && '$PY' main.py $flags $COMFYUI_FLAGS"

    if [ -x "$BIN_DIR/caddy" ] && write_caddyfile; then
        start_service caddy "'$BIN_DIR/caddy' run --config '$STATE_DIR/Caddyfile' --adapter caddyfile"
    else
        warn "Caddy unavailable — ComfyUI is only reachable via SSH tunnel (ssh -L 8188:localhost:8188)"
    fi

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
        start_service filebrowser "'$BIN_DIR/filebrowser' -d '$fb_db' -r '$WORKSPACE' -a 0.0.0.0 -p $FILEBROWSER_PORT"
    fi

    if [ "$ENABLE_JUPYTER" = "true" ] && [ -x "$VENV_DIR/bin/jupyter" ]; then
        if port_free "$JUPYTER_PORT"; then
            # \$WEB_PASSWORD expands inside the runner at start time — the
            # password never lands verbatim in a script on disk.
            start_service jupyter "'$VENV_DIR/bin/jupyter' lab --allow-root --no-browser --ip 0.0.0.0 --port $JUPYTER_PORT --ServerApp.token=\"\$WEB_PASSWORD\" --ServerApp.root_dir='$WORKSPACE'"
        else
            log "port $JUPYTER_PORT busy (base image Jupyter?) — not starting a second instance"
        fi
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
}

print_connection_info() {
    local info="$STATE_DIR/CONNECTION_INFO.txt"
    local shown="(set via WEB_PASSWORD env)"
    [ "$PASSWORD_SOURCE" != "env" ] && shown="$WEB_PASSWORD"
    {
        echo "=================================================================="
        echo " ComfyPod is up"
        echo "=================================================================="
        echo " ComfyUI:      $(pod_url "$PROXY_PORT")"
        echo " Dashboard:    $(pod_url "$DASHBOARD_PORT")"
        echo " FileBrowser:  $(pod_url "$FILEBROWSER_PORT")"
        echo " JupyterLab:   $(pod_url "$JUPYTER_PORT")   (token = password)"
        echo ""
        echo " Username: $WEB_USER"
        echo " Password: $shown"
        echo " (also stored in $STATE_DIR/credentials.txt)"
        echo ""
        echo " Model downloads: tail -f $LOG_DIR/downloads.log"
        echo "=================================================================="
    } | tee "$info"
}

main() {
    log "=== ComfyPod boot ==="
    ensure_dirs
    setup_credentials
    install_apt_deps || warn "apt install failed — continuing"
    fetch_binaries
    setup_venv
    setup_comfyui
    setup_custom_nodes
    setup_sage_attention
    write_dashboard
    install_cli_shims
    start_services
    start_downloads
    print_connection_info
    log "boot finished"
}

main "$@"
