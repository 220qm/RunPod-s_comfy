#!/usr/bin/env bash
# ComfyPod shared helpers. Sourced by every script — keep free of side effects
# beyond exporting paths and defining functions.

# ---------------------------------------------------------------------------
# Canonical paths. Everything that must survive a pod restart lives under
# $STATE_DIR or $COMFY_DIR, both on the /workspace network volume.
# ---------------------------------------------------------------------------
export WORKSPACE="${WORKSPACE:-/workspace}"
export STATE_DIR="${STATE_DIR:-$WORKSPACE/.comfypod}"
export REPO_DIR="${REPO_DIR:-$STATE_DIR/repo}"
export BIN_DIR="$STATE_DIR/bin"
export LOG_DIR="$STATE_DIR/logs"
export MARKER_DIR="$STATE_DIR/markers"
export RUN_DIR="$STATE_DIR/run"
export WWW_DIR="$STATE_DIR/www"
export VENV_DIR="$STATE_DIR/venv"
export COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
export MODELS_DIR="$COMFY_DIR/models"

export PY="$VENV_DIR/bin/python"
export PIP="$VENV_DIR/bin/pip"

# Optional persisted environment (survives template changes). Values set in the
# RunPod template win because the file uses `${VAR:-default}` expansion.
# shellcheck disable=SC1091
[ -f "$STATE_DIR/env" ] && . "$STATE_DIR/env"

# ---------------------------------------------------------------------------
# User-facing settings and their defaults
# ---------------------------------------------------------------------------
export WEB_USER="${WEB_USER:-admin}"
export WEB_PASSWORD="${WEB_PASSWORD:-}"
export HF_TOKEN="${HF_TOKEN:-}"
export CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
export DOWNLOAD_PRESETS="${DOWNLOAD_PRESETS:-krea2,wan22-t2v,wan22-i2v,upscale}"
export COMFYUI_REF="${COMFYUI_REF:-latest}"
export COMFYUI_FLAGS="${COMFYUI_FLAGS:-}"
export EXTRA_NODES="${EXTRA_NODES:-}"
export AUTO_UPDATE="${AUTO_UPDATE:-false}"
export ENABLE_JUPYTER="${ENABLE_JUPYTER:-true}"
export SAGE_ATTENTION="${SAGE_ATTENTION:-auto}"

export COMFYUI_PORT=8188        # localhost only — never exposed directly
export PROXY_PORT=3001          # Caddy basic-auth proxy in front of ComfyUI
export DASHBOARD_PORT=3000
export FILEBROWSER_PORT=8080
export JUPYTER_PORT=8888

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "${SCRIPT_NAME:-comfypod}" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

ensure_dirs() {
    mkdir -p "$BIN_DIR" "$LOG_DIR" "$MARKER_DIR" "$RUN_DIR" "$WWW_DIR"
}

marker_ok()  { [ -f "$MARKER_DIR/$1" ]; }
marker_set() { : > "$MARKER_DIR/$1"; }
marker_rm()  { rm -f "$MARKER_DIR/$1"; }

# True when nothing is listening on the port.
port_free() {
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------------------------------------------------------------------------
# Service supervision. Each service gets a tiny runner script on the volume
# that restarts it on crash; the runner path doubles as the pgrep handle.
# ---------------------------------------------------------------------------
service_running() {
    pgrep -f "\.comfypod/run/$1\.sh" > /dev/null 2>&1
}

start_service() {
    local name="$1" cmd="$2"
    local runner="$RUN_DIR/$name.sh"
    cat > "$runner" <<EOF
#!/usr/bin/env bash
while true; do
    $cmd
    echo "[\$(date '+%F %T')] $name exited (code \$?); restarting in 3s"
    sleep 3
done
EOF
    chmod +x "$runner"
    if service_running "$name"; then
        log "$name already running"
        return 0
    fi
    setsid nohup "$runner" >> "$LOG_DIR/$name.log" 2>&1 &
    log "started $name (log: $LOG_DIR/$name.log)"
}

stop_service() {
    pkill -f "\.comfypod/run/$1\.sh" 2>/dev/null || true
    case "$1" in
        comfyui)     pkill -f "main.py --listen 127.0.0.1 --port $COMFYUI_PORT" 2>/dev/null || true ;;
        caddy)       pkill -f "$BIN_DIR/caddy" 2>/dev/null || true ;;
        filebrowser) pkill -f "$BIN_DIR/filebrowser" 2>/dev/null || true ;;
        jupyter)     pkill -f "jupyter-lab" 2>/dev/null || true ;;
    esac
}

pod_url() {
    if [ -n "${RUNPOD_POD_ID:-}" ]; then
        printf 'https://%s-%s.proxy.runpod.net' "$RUNPOD_POD_ID" "$1"
    else
        printf 'http://localhost:%s' "$1"
    fi
}
