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
# Where ComfyUI's *data* lives — always the network volume.
export COMFY_DATA_DIR="${COMFY_DATA_DIR:-$WORKSPACE/ComfyUI}"
export MODELS_DIR="$COMFY_DATA_DIR/models"
export SECRETS_FILE="$STATE_DIR/secrets.env"
export CONSTRAINTS_FILE="$STATE_DIR/constraints.txt"
export LOCK_FILE="$STATE_DIR/requirements.lock"
export NODES_LOCK="$STATE_DIR/nodes.lock"
# One tar per custom node that git cannot bring back — see the node
# persistence section further down.
export NODE_ARCHIVE_DIR="${NODE_ARCHIVE_DIR:-$STATE_DIR/node-archives}"

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
export DOWNLOAD_PRESETS="${DOWNLOAD_PRESETS:-krea2,minimax-h3,upscale}"
export COMFYUI_REF="${COMFYUI_REF:-latest}"
export COMFYUI_FLAGS="${COMFYUI_FLAGS:-}"
export EXTRA_NODES="${EXTRA_NODES:-}"
# Seconds between background sweeps that copy Manager-installed nodes to the
# volume, and the size above which a node is too big to archive (nodes that
# download their own weights into their own folder).
export NODE_SYNC_INTERVAL="${NODE_SYNC_INTERVAL:-120}"
export NODE_ARCHIVE_MAX_MB="${NODE_ARCHIVE_MAX_MB:-512}"
export AUTO_UPDATE="${AUTO_UPDATE:-false}"
export ENABLE_JUPYTER="${ENABLE_JUPYTER:-true}"
# auto: install SageAttention for per-workflow use (KJNodes "Patch Sage
#       Attention") but do NOT enable it globally — the global flag has
#       produced black output on Qwen-family text encoders, which both
#       Krea 2 and MiniMax H3 use.
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
# torch/torchvision/torchaudio all from the same release: torchaudio stops at
# 2.11.0, so 2.11.0 / 0.26.0 / 2.11.0 is the newest fully aligned set. The
# baked image climbs higher (2.13.0 first, see docker/install-torch.sh) because
# it can *verify* each combination before accepting it; this path installs
# blind on a live pod, so it stays on the set that cannot mismatch.
export TORCH_SPEC="${TORCH_SPEC:-torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0}"
# CUDA 13 by default: ComfyUI's NVFP4/INT8 acceleration only exists on a cu130
# build (on cu128 those paths are emulated and slower than fp8), and the
# default MiniMax H3 preset uses an NVFP4 text encoder. Needs driver >= 580;
# hosts below that fall back to the cu128 index automatically.
export TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu130}"
export TORCH_FALLBACK_INDEX="${TORCH_FALLBACK_INDEX:-https://download.pytorch.org/whl/cu128}"
# Minimum NVIDIA driver for each CUDA major, used by preflight and doctor.
export CUDA13_MIN_DRIVER=580
export CUDA12_MIN_DRIVER=525
# The image build's candidate chain lives in docker/install-torch.sh
# (TORCH_CANDIDATES); TORCH_SPEC above is what a non-baked pod installs.

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

# ---------------------------------------------------------------------------
# Where ComfyUI's *code* runs from. This is the single biggest determinant of
# how responsive the pod feels.
#
# Importing ComfyUI plus its custom nodes touches thousands of small files. A
# network volume has high per-operation latency, so running the code from
# there makes every restart and every node install crawl — the same reason the
# venv is not kept on the volume. Code therefore runs from container disk
# (where the image already put it) and only the data directories are symlinked
# to the volume.
#   container : fast local disk, code from the image  (default when baked)
#   volume    : everything on /workspace              (stock-image fallback)
export COMFY_CODE_LOCATION="${COMFY_CODE_LOCATION:-auto}"
if [ "$COMFY_CODE_LOCATION" = "auto" ]; then
    # Container disk whenever the image supplied a copy of ComfyUI there.
    if [ -d "${COMFY_DIR:-/opt/ComfyUI}" ]; then
        COMFY_CODE_LOCATION=container
    else
        COMFY_CODE_LOCATION=volume
    fi
fi
# An explicitly supplied COMFY_DIR always wins; otherwise container mode means
# the image's copy. Falling back to volume mode only when neither exists keeps
# the stock-image path working.
if [ "$COMFY_CODE_LOCATION" = "container" ] && { [ -n "${COMFY_DIR:-}" ] || [ -d /opt/ComfyUI ]; }; then
    export COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
else
    export COMFY_CODE_LOCATION=volume
    export COMFY_DIR="${COMFY_DIR:-$COMFY_DATA_DIR}"
fi
# Directories that must survive the pod: kept on the volume and symlinked into
# the code tree when the code lives on container disk.
export COMFY_DATA_SUBDIRS="models output input user"
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
# MiniMax H3 swaps a 32B text encoder and the diffusion model in and out of
# VRAM; expandable segments avoids the fragmentation OOMs that pattern causes.
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
# Runs a command and logs "<message> (still running, Ns)" every 20s while it
# is alive, so a long silent step never looks like a hang.
#
# The job is waited on with `wait`, and the ticker lives in a separate process
# that is killed afterwards. Polling the job with `kill -0` instead would never
# terminate: a finished child stays a zombie until the shell reaps it, and
# `kill -0` keeps succeeding on a zombie — an infinite loop that would have
# hung every boot right after each wrapped step completed.
run_with_heartbeat() {
    local msg="$1"; shift
    [ "$1" = "--" ] && shift
    "$@" &
    local pid=$!
    (
        local elapsed=0
        while sleep 20; do
            kill -0 "$pid" 2>/dev/null || break
            elapsed=$((elapsed + 20))
            log "$msg (still running, ${elapsed}s elapsed)"
        done
    ) &
    local ticker=$!
    wait "$pid"
    local rc=$?
    kill "$ticker" 2>/dev/null
    wait "$ticker" 2>/dev/null
    return "$rc"
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
    sys.exit("torch has no CUDA support (CPU-only build)")
if tuple(int(x) for x in cu.split(".")[:2]) < (12, 8):
    sys.exit(f"CUDA {cu} is older than 12.8 (Blackwell needs >= 12.8)")

if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU (driver mismatch, or no GPU on this pod)")

major, minor = torch.cuda.get_device_capability()
archs = torch.cuda.get_arch_list()
if not archs:
    sys.exit(0)  # nothing to compare against; the CUDA tag already passed
# Same rules as docker/verify-torch.py: an exact cubin, an older cubin of the
# same major (binary compatible), or same-major PTX all count as support.
for a in archs:
    for prefix in ("sm_", "compute_"):
        if a.startswith(prefix):
            d = a[len(prefix):]
            if d.isdigit() and len(d) >= 2:
                if int(d[:-1]) == major and int(d[-1]) <= minor:
                    sys.exit(0)
sys.exit(f"torch lacks kernels for sm_{major}{minor} (has: {', '.join(archs)})")
PY
}

# Is the host's NVIDIA driver new enough for the CUDA build we installed?
# Prints a verdict; returns 1 when the driver is too old. A cu130 build on a
# pre-580 driver fails at the first CUDA call rather than at import, so this
# has to be checked explicitly.
driver_check() {
    local drv cu_major need
    drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    [ -n "$drv" ] || { echo "no NVIDIA driver visible"; return 0; }
    cu_major="$("$PY" -c 'import torch; print((torch.version.cuda or "0.0").split(".")[0])' 2>/dev/null)"
    [ -n "$cu_major" ] || { echo "driver $drv (torch CUDA version unknown)"; return 0; }
    case "$cu_major" in
        13) need="$CUDA13_MIN_DRIVER" ;;
        12) need="$CUDA12_MIN_DRIVER" ;;
        *)  echo "driver $drv / CUDA $cu_major"; return 0 ;;
    esac
    if [ "${drv%%.*}" -lt "$need" ] 2>/dev/null; then
        echo "driver $drv is too old for this CUDA $cu_major build (needs >= $need)"
        return 1
    fi
    echo "driver $drv supports the installed CUDA $cu_major build"
}

torch_report() {
    # No backslashes inside the f-string expression: they are a syntax error on
    # Python < 3.12, which silently made this print nothing at all.
    "$PY" -c 'import torch
archs = " ".join(torch.cuda.get_arch_list()) or "(unreadable without a GPU)"
print(f"torch {torch.__version__} / CUDA {torch.version.cuda} / archs: {archs}")' 2>/dev/null
}

# ---------------------------------------------------------------------------
# secrets.env is sourced by every script, so values MUST be written quoted:
# an unquoted password containing a space silently truncates, and one
# containing ; or $( ) would execute as code at boot.
# ---------------------------------------------------------------------------
shell_quote() {
    local v="$1"
    printf "'%s'" "${v//\'/\'\\\'\'}"
}

# chmod does not always stick on RunPod's network volume (its filesystem can
# ignore mode bits), which left secrets world-readable. Try the volume first,
# and when the mode refuses to change keep the authoritative copy on container
# disk, where it does.
SECURE_FALLBACK_DIR="${SECURE_FALLBACK_DIR:-/opt/comfypod-private}"
secure_file() {
    local f="$1"
    chmod 600 "$f" 2>/dev/null
    [ "$(stat -c %a "$f" 2>/dev/null)" = "600" ]
}

secrets_put() {
    local key="$1" val="$2" tmp
    umask 077
    touch "$SECRETS_FILE"
    tmp="$SECRETS_FILE.tmp.$$"
    grep -v "^$key=" "$SECRETS_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
    printf '%s=%s\n' "$key" "$(shell_quote "$val")" >> "$tmp"
    mv "$tmp" "$SECRETS_FILE"
    secure_file "$SECRETS_FILE" || true
    umask 022
}

# True when the filesystem holding $1 honours chmod at all.
fs_honours_chmod() {
    local probe="$1/.comfypod-perm-probe.$$" ok=1
    ( umask 077; : > "$probe" ) 2>/dev/null || return 1
    chmod 600 "$probe" 2>/dev/null
    [ "$(stat -c %a "$probe" 2>/dev/null)" = "600" ] && ok=0
    rm -f "$probe"
    return "$ok"
}

# ComfyUI-Manager's config path moved in newer ComfyUI. Manager picks it based
# on whether ComfyUI exposes the System User Protection API — and when that API
# is ABSENT it force-sets security_level=strong, blocking every install no
# matter what the config says (the usual cause of a dead install button).
comfy_has_system_user_api() {
    grep -q "def get_system_user_directory" "$COMFY_DIR/folder_paths.py" 2>/dev/null
}

# MiniMax H3 (the default model preset) landed in ComfyUI v0.30.0. On anything
# older the weights download fine and then fail to load, which looks like a bad
# download rather than an out-of-date ComfyUI.
comfy_supports_minimax() {
    grep -q "class MiniMaxH3" "$COMFY_DIR/comfy/supported_models.py" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Custom node persistence
#
# ComfyUI's code tree lives on container disk (imports from the network volume
# are far too slow), so anything installed from the ComfyUI-Manager UI dies
# with the pod. Two mechanisms bring it back, because Manager has two install
# paths and they leave completely different things on disk:
#
#   * "nightly" / git-URL installs are a git clone -> recorded by remote URL in
#     extra-nodes.txt and re-cloned on the next boot.
#   * registry ("CNR") installs — the DEFAULT button in the UI — are a zip
#     extracted into custom_nodes/<id> with no .git and no remote at all.
#     Nothing about them can be re-derived, so the directory itself is archived
#     to the volume as a single tar (one big sequential write beats thousands
#     of small files) and unpacked into the fresh container next boot.
#
# Both run on a timer, not just at boot: a node installed at 14:00 on a pod
# terminated at 15:00 never sees another boot of that container.
# ---------------------------------------------------------------------------

# Weights inside a node's own folder are re-downloadable; keeping them out of
# the archive is the difference between a 2 MB tar and a 6 GB one.
NODE_ARCHIVE_EXCLUDES=(
    --exclude=__pycache__ --exclude='*.pyc'
    --exclude='*.safetensors' --exclude='*.ckpt' --exclude='*.pth'
    --exclude='*.pt' --exclude='*.bin' --exclude='*.onnx' --exclude='*.gguf'
)

# Pruning archives is only safe once this boot's restore has run — otherwise
# the first sweep on a fresh pod would delete every archive it is meant to
# protect. The flag lives in TMP_DIR, which is per-boot.
node_restore_flag() { printf '%s/nodes-restored' "$TMP_DIR"; }

# Unpack archived nodes into the (fresh) container-disk code tree.
restore_nodes_from_volume() {
    [ "$COMFY_CODE_LOCATION" = "container" ] || return 0
    local archive name restored=0
    mkdir -p "$COMFY_DIR/custom_nodes"
    for archive in "$NODE_ARCHIVE_DIR"/*.tar; do
        [ -f "$archive" ] || continue
        name="$(basename "$archive" .tar)"
        [ -e "$COMFY_DIR/custom_nodes/$name" ] && continue
        if tar -xf "$archive" -C "$COMFY_DIR/custom_nodes" 2> /dev/null; then
            restored=$((restored + 1))
        else
            warn "could not restore node archive: $name"
        fi
    done
    [ "$restored" -gt 0 ] && log "restored $restored node(s) installed from the Manager UI"
    mkdir -p "$TMP_DIR" && : > "$(node_restore_flag)"
    return 0
}

# Archive every node git cannot reproduce, and drop archives of nodes the user
# has since uninstalled.
sync_nodes_to_volume() {
    [ "$COMFY_CODE_LOCATION" = "container" ] || return 0
    [ -d "$COMFY_DIR/custom_nodes" ] || return 0
    mkdir -p "$NODE_ARCHIVE_DIR"
    local dir name archive size synced=0
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        dir="${dir%/}"
        name="$(basename "$dir")"
        case "$name" in __pycache__ | .disabled | *.disabled) continue ;; esac
        # A git checkout is reproducible from its remote; extra-nodes.txt
        # carries it for a fraction of the space.
        [ -d "$dir/.git" ] && continue
        archive="$NODE_ARCHIVE_DIR/$name.tar"
        # Untouched since the last sweep? Nothing to write.
        [ -f "$archive" ] && [ -z "$(find "$dir" -newer "$archive" -print -quit 2> /dev/null)" ] \
            && continue
        size="$(du -sm "${NODE_ARCHIVE_EXCLUDES[@]}" "$dir" 2> /dev/null | cut -f1)"
        if [ "${size:-0}" -gt "$NODE_ARCHIVE_MAX_MB" ] 2> /dev/null; then
            warn "node $name is ${size}MB — above NODE_ARCHIVE_MAX_MB, not archived;"
            warn "  it will need reinstalling on a new pod"
            continue
        fi
        if tar -cf "$archive.tmp" -C "$COMFY_DIR/custom_nodes" \
            "${NODE_ARCHIVE_EXCLUDES[@]}" "$name" 2> /dev/null; then
            mv -f "$archive.tmp" "$archive"
            synced=$((synced + 1))
        else
            rm -f "$archive.tmp"
            warn "could not archive node: $name"
        fi
    done
    if [ -f "$(node_restore_flag)" ]; then
        for archive in "$NODE_ARCHIVE_DIR"/*.tar; do
            [ -f "$archive" ] || continue
            name="$(basename "$archive" .tar)"
            [ -d "$COMFY_DIR/custom_nodes/$name" ] && continue
            rm -f "$archive"
            log "dropped archive for uninstalled node: $name"
        done
    fi
    [ "$synced" -gt 0 ] && log "archived $synced Manager-installed node(s) to the volume"
    return 0
}

# Record the remote of every git-installed node that is not part of the image,
# so the next pod re-clones it.
capture_manager_installed_nodes() {
    [ "$COMFY_CODE_LOCATION" = "container" ] || return 0
    local dir name url known recorded=0
    known="$(cat "$REPO_DIR/config/nodes.txt" "$SCRIPT_DIR/../config/nodes.txt" 2> /dev/null)"
    mkdir -p "$STATE_DIR" && touch "$STATE_DIR/extra-nodes.txt"
    for dir in "$COMFY_DIR"/custom_nodes/*/; do
        dir="${dir%/}"
        [ -d "$dir/.git" ] || continue
        name="$(basename "$dir")"
        url="$(git -C "$dir" config --get remote.origin.url 2> /dev/null)" || continue
        [ -n "$url" ] || continue
        case "$known" in *"$url"*) continue ;; esac                  # shipped in the image
        grep -qF "$url" "$STATE_DIR/extra-nodes.txt" && continue      # already recorded
        printf '%s\n' "$url" >> "$STATE_DIR/extra-nodes.txt"
        log "recorded $name for reinstall on future pods"
        recorded=$((recorded + 1))
    done
    [ "$recorded" -gt 0 ] && log "$recorded Manager-installed node(s) will persist"
    return 0
}

# Everything needed to make the current node set survive this pod.
persist_nodes() {
    capture_manager_installed_nodes
    sync_nodes_to_volume
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
        node-sync)   pkill -f "scripts/node-sync.sh" 2>/dev/null || true ;;
    esac
}

pod_url() {
    if [ -n "${RUNPOD_POD_ID:-}" ]; then
        printf 'https://%s-%s.proxy.runpod.net' "$RUNPOD_POD_ID" "$1"
    else
        printf 'http://localhost:%s' "$1"
    fi
}
