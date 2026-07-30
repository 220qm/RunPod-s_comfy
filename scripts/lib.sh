#!/usr/bin/env bash
# ComfyPod shared helpers. Sourced by every script — keep free of side effects
# beyond exporting paths/settings and defining functions.

# ---------------------------------------------------------------------------
# Canonical paths. Everything that must survive a pod restart lives under
# $STATE_DIR or $COMFY_DIR, both on the /workspace network volume. The venv is
# the deliberate exception (see VENV_LOCATION below).
# ---------------------------------------------------------------------------
export WORKSPACE="${WORKSPACE:-/workspace}"
export STATE_DIR="${STATE_DIR:-$WORKSPACE/.comfypod}"
export REPO_DIR="${REPO_DIR:-$STATE_DIR/repo}"
export BIN_DIR="$STATE_DIR/bin"
export LOG_DIR="$STATE_DIR/logs"
export MARKER_DIR="$STATE_DIR/markers"
export RUN_DIR="$STATE_DIR/run"
export CACHE_DIR="$STATE_DIR/cache"
export SNAPSHOT_DIR="$STATE_DIR/snapshots"
export TMP_DIR="$STATE_DIR/tmp"
export COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
export MODELS_DIR="$COMFY_DIR/models"
export SECRETS_FILE="$STATE_DIR/secrets.env"
export CONSTRAINTS_FILE="$STATE_DIR/constraints.txt"
export LOCK_FILE="$STATE_DIR/requirements.lock"
export NODES_LOCK="$STATE_DIR/nodes.lock"

# Optional persisted defaults (legacy, ${VAR:-default} style), then the
# canonical secrets file. secrets.env wins over template env vars so that
# credential rotation via `comfypod-secrets` sticks regardless of what an old
# template still injects.
# shellcheck disable=SC1091
[ -f "$STATE_DIR/env" ] && . "$STATE_DIR/env"
if [ -f "$SECRETS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
fi

# ---------------------------------------------------------------------------
# User-facing settings and their defaults
# ---------------------------------------------------------------------------
export WEB_USER="${WEB_USER:-admin}"
export WEB_PASSWORD="${WEB_PASSWORD:-}"
export HF_TOKEN="${HF_TOKEN:-}"
export CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
export DOWNLOAD_PRESETS="${DOWNLOAD_PRESETS:-krea2,wan22-5b,wan22-t2v,wan22-i2v,upscale}"
export COMFYUI_REF="${COMFYUI_REF:-latest}"
export COMFYUI_FLAGS="${COMFYUI_FLAGS:-}"
export EXTRA_NODES="${EXTRA_NODES:-}"
export AUTO_UPDATE="${AUTO_UPDATE:-false}"
export ENABLE_JUPYTER="${ENABLE_JUPYTER:-true}"
# auto: install SageAttention for per-workflow use (KJNodes "Patch Sage
#       Attention") but do NOT enable it globally — the global flag has
#       produced black output on Wan/Qwen-family models.
# global: also pass --use-sage-attention (at your own risk)
# off: skip entirely
export SAGE_ATTENTION="${SAGE_ATTENTION:-auto}"
# ComfyUI --fast optimizations. fp16_accumulation is the well-tested ~20-30%
# sampling speedup on 40/50-series with negligible quality impact.
#   fp16_accumulation (default) | all (every --fast feature, riskier) | off
export FAST_MODE="${FAST_MODE:-fp16_accumulation}"
# ComfyUI-Manager security level: strong | normal | normal- | weak.
# RunPod's proxy requires ComfyUI to bind 0.0.0.0, which Manager treats as
# "not local mode" — and in that mode installing an unlisted/git-URL node
# needs 'weak'. Everything is still behind the ComfyUI-Login password; this
# trades Manager's own guard-rail for a working install button. Set 'normal'
# to allow only registry nodes.
export MANAGER_SECURITY_LEVEL="${MANAGER_SECURITY_LEVEL:-weak}"
# true: bind FileBrowser/Jupyter to 127.0.0.1 (reach via SSH tunnel only)
export ADMIN_LOCAL_ONLY="${ADMIN_LOCAL_ONLY:-false}"
# Auto-stop the pod after this many fully idle minutes (0 = never)
export IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-30}"
# container: venv on container disk, rebuilt each boot from the lockfile via
#            uv (fast imports; network volumes are slow at many small reads).
# volume:    venv persisted on /workspace (no rebuild, slower imports).
export VENV_LOCATION="${VENV_LOCATION:-container}"
# Newest mutually consistent torch triple: torchaudio caps at 2.11.0, so
# 2.11.0 / 0.26.0 / 2.11.0 is the latest set where all three align (it is also
# what the community Blackwell SageAttention 2.x wheels target). cu128 rather
# than the newer cu130 default: CUDA 13 wheels need a much newer NVIDIA driver
# than parts of RunPod's fleet carry, and 12.8 already covers Blackwell sm_120.
export TORCH_SPEC="${TORCH_SPEC:-torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0}"
export TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
# Fallback chain for the image build: if the pinned triple is not published on
# the chosen index, take the newest that is, then the last known-good set.
export TORCH_SPEC_FALLBACKS="${TORCH_SPEC_FALLBACKS:-torch torchvision torchaudio|torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0}"

# Set by the baked Docker image (ghcr.io/220qm/comfypod): torch, ComfyUI,
# nodes and binaries are pre-installed, so the boot scripts skip every
# download/build step. The baked venv is always at the container path.
export COMFYPOD_BAKED="${COMFYPOD_BAKED:-0}"
[ "$COMFYPOD_BAKED" = "1" ] && VENV_LOCATION=container

if [ "$VENV_LOCATION" = "volume" ]; then
    export VENV_DIR="$STATE_DIR/venv"
else
    export VENV_DIR="/opt/comfypod-venv"
fi
export PY="$VENV_DIR/bin/python"
export PIP="$VENV_DIR/bin/pip"

export COMFYUI_PORT=8188
export FILEBROWSER_PORT=8080
export JUPYTER_PORT=8888

# ---------------------------------------------------------------------------
# Performance / caching environment
# ---------------------------------------------------------------------------
export HF_HOME="${HF_HOME:-$CACHE_DIR/hf}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_DIR/uv}"
# Wan A14B alternates two 14B experts in VRAM; expandable segments avoids the
# fragmentation OOMs that come with that pattern.
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
# Torch pin enforced on EVERY pip in this environment — including pips spawned
# by ComfyUI-Manager — so no custom node can silently downgrade torch.
[ -f "$CONSTRAINTS_FILE" ] && export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

# ---------------------------------------------------------------------------
# Logging with secret redaction. Never log a token/password: anything that
# passes through log()/warn()/die() has known secret values masked.
# ---------------------------------------------------------------------------
redact() {
    local s="$1" v
    for v in "$WEB_PASSWORD" "$HF_TOKEN" "$CIVITAI_TOKEN"; do
        [ -n "$v" ] && s=${s//"$v"/****}
    done
    printf '%s' "$s"
}
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "${SCRIPT_NAME:-comfypod}" "$(redact "$*")"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

ensure_dirs() {
    mkdir -p "$BIN_DIR" "$LOG_DIR" "$MARKER_DIR" "$RUN_DIR" "$CACHE_DIR" \
             "$SNAPSHOT_DIR" "$TMP_DIR"
}

marker_ok()  { [ -f "$MARKER_DIR/$1" ]; }
marker_set() { : > "$MARKER_DIR/$1"; }
marker_rm()  { rm -f "$MARKER_DIR/$1"; }

port_free() {
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------------------------------------------------------------------------
# Python package management: uv when available (fast, lockfile-driven),
# pip as fallback. Both paths enforce the torch constraints.
# ---------------------------------------------------------------------------
uv_bin() {
    if [ -x "$BIN_DIR/uv" ]; then printf '%s' "$BIN_DIR/uv"
    else command -v uv 2>/dev/null || true
    fi
}

# FileBrowser binary: baked into the image at /usr/local/bin, downloaded to
# the volume's bin dir otherwise.
fb_bin() {
    if [ -x "$BIN_DIR/filebrowser" ]; then printf '%s' "$BIN_DIR/filebrowser"
    else command -v filebrowser 2>/dev/null || true
    fi
}

pkg_install() {
    local uv
    uv="$(uv_bin)"
    if [ -n "$uv" ]; then
        # shellcheck disable=SC2086
        "$uv" pip install -q --python "$PY" \
            ${PIP_CONSTRAINT:+--constraint "$PIP_CONSTRAINT"} "$@"
    else
        "$PIP" install -q "$@"
    fi
}

# Same as pkg_install but WITHOUT -q — for the rare installs big enough that
# total silence would look indistinguishable from a hang (torch's cu128
# wheels bundle the CUDA runtime libraries and can be several GB).
pkg_install_loud() {
    local uv
    uv="$(uv_bin)"
    if [ -n "$uv" ]; then
        # shellcheck disable=SC2086
        "$uv" pip install --python "$PY" \
            ${PIP_CONSTRAINT:+--constraint "$PIP_CONSTRAINT"} "$@"
    else
        "$PIP" install "$@"
    fi
}

# run_with_heartbeat <message> -- <command...>
# Runs a command in the background and logs "<message> (still running, Ns)"
# every 20s while it's alive, so a long silent step never looks like a hang.
run_with_heartbeat() {
    local msg="$1"; shift
    [ "$1" = "--" ] && shift
    "$@" &
    local pid=$! elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 20
        elapsed=$((elapsed + 20))
        kill -0 "$pid" 2>/dev/null && log "$msg (still running, ${elapsed}s elapsed)"
    done
    wait "$pid"
}

# Verifies what actually matters instead of a hardcoded version string: a
# CUDA build >= 12.8, and — when a GPU is visible — that this GPU's compute
# capability is among the architectures torch was compiled for. That is the
# direct test for the Blackwell (sm_120) trap; a version check only proxied it.
# torch_check prints the reason on failure; torch_ok is the silent boolean.
torch_ok() { torch_check > /dev/null 2>&1; }

torch_check() {
    "$PY" - <<'PY'
import sys
import torch
cu = torch.version.cuda
if not cu:
    sys.exit("torch has no CUDA support")
if tuple(int(x) for x in cu.split(".")[:2]) < (12, 8):
    sys.exit(f"CUDA {cu} is older than 12.8 (Blackwell needs >= 12.8)")
if torch.cuda.is_available():
    major, minor = torch.cuda.get_device_capability()
    archs = torch.cuda.get_arch_list()
    if not any(a in archs for a in (f"sm_{major}{minor}", f"compute_{major}{minor}")):
        sys.exit(f"torch lacks kernels for sm_{major}{minor} (has: {', '.join(archs)})")
PY
}

torch_report() {
    "$PY" -c 'import torch; print(f"torch {torch.__version__} / CUDA {torch.version.cuda} / archs: {\" \".join(torch.cuda.get_arch_list())}")' 2>/dev/null
}

# ComfyUI-Manager's config path moved in newer ComfyUI. Manager picks it based
# on whether ComfyUI exposes the System User Protection API — and when that API
# is ABSENT it force-sets security_level=strong, blocking every install no
# matter what the config says (the usual cause of a dead install button).
comfy_has_system_user_api() {
    grep -q "def get_system_user_directory" "$COMFY_DIR/folder_paths.py" 2>/dev/null
}

manager_config_path() {
    if comfy_has_system_user_api; then
        printf '%s' "$COMFY_DIR/user/__manager/config.ini"
    else
        printf '%s' "$COMFY_DIR/user/default/ComfyUI-Manager/config.ini"
    fi
}

# Seed ComfyUI-Login's password file from WEB_PASSWORD (bcrypt hash; the hash
# also serves as the API bearer token). Re-seeds when the password changes.
seed_login_password() {
    [ -n "$WEB_PASSWORD" ] || return 1
    local sig hash
    sig="$(printf '%s' "$WEB_PASSWORD" | sha256sum | cut -d' ' -f1)"
    if [ -f "$COMFY_DIR/login/PASSWORD" ] \
        && [ "$(cat "$MARKER_DIR/login-pw-sig" 2>/dev/null)" = "$sig" ]; then
        return 0
    fi
    hash="$("$PY" -c 'import bcrypt, os; print(bcrypt.hashpw(os.environ["WEB_PASSWORD"].encode(), bcrypt.gensalt()).decode())')" \
        || { warn "bcrypt unavailable — ComfyUI-Login will prompt to set a password on first visit"; return 1; }
    mkdir -p "$COMFY_DIR/login"
    umask 077
    printf '%s' "$hash" > "$COMFY_DIR/login/PASSWORD"
    umask 022
    printf '%s' "$sig" > "$MARKER_DIR/login-pw-sig"
}

# ---------------------------------------------------------------------------
# Service supervision. Each service gets a tiny runner script that restarts it
# on crash; the runner path doubles as the pgrep handle.
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
        comfyui)     pkill -f "main.py --listen" 2>/dev/null || true ;;
        filebrowser) pkill -f "filebrowser -d $STATE_DIR" 2>/dev/null || true ;;
        jupyter)     pkill -f "jupyter-lab" 2>/dev/null || true ;;
        idle-guard)  pkill -f "scripts/idle-guard.sh" 2>/dev/null || true ;;
    esac
}

pod_url() {
    if [ -n "${RUNPOD_POD_ID:-}" ]; then
        printf 'https://%s-%s.proxy.runpod.net' "$RUNPOD_POD_ID" "$1"
    else
        printf 'http://localhost:%s' "$1"
    fi
}
