#!/usr/bin/env bash
# ComfyPod doctor (also installed as `comfypod-doctor`): one command to
# diagnose a broken pod. Read-only — reports, never repairs.
export SCRIPT_NAME=doctor
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

FAILS=0
WARNS=0
ok()   { printf '[ OK ] %s\n' "$*"; }
wrn()  { printf '[WARN] %s\n' "$*"; WARNS=$((WARNS + 1)); }
bad()  { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }

echo "=== ComfyPod doctor ==="

# --- GPU / torch -----------------------------------------------------------
if command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null 2>&1; then
    ok "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -1)"
else
    bad "no working GPU (nvidia-smi failed) — wrong pod type or driver issue"
fi

if [ -x "$PY" ]; then
    if ! "$PY" -c 'import torch' 2>/dev/null; then
        bad "torch does not import — rebuild env: rm -rf $VENV_DIR && bash $SCRIPT_DIR/start.sh"
    elif ! torch_ok; then
        bad "torch/GPU mismatch: $(torch_check 2>&1 | tail -1)"
        bad "  ($(torch_report)) — a custom node likely downgraded torch; rebuild: rm -rf $VENV_DIR && bash $SCRIPT_DIR/start.sh"
    else
        ok "$(torch_report)"
    fi
    # CUDA 13 wheels need a much newer driver than CUDA 12.8 ones; a mismatch
    # shows up as torch failing at the first CUDA call, not at import.
    drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    cu_major="$("$PY" -c 'import torch; print((torch.version.cuda or "0.0").split(".")[0])' 2>/dev/null)"
    if [ -n "$drv" ] && [ -n "$cu_major" ]; then
        need=525; [ "$cu_major" = "13" ] && need=580
        drv_major="${drv%%.*}"
        if [ "${drv_major:-0}" -lt "$need" ] 2>/dev/null; then
            bad "driver $drv is too old for a CUDA $cu_major build (needs >= $need) — use a cu128 image or a newer host"
        else
            ok "driver $drv supports the installed CUDA $cu_major build"
        fi
    fi
else
    bad "venv missing at $VENV_DIR — run: bash $SCRIPT_DIR/start.sh"
fi

# --- storage ---------------------------------------------------------------
if mountpoint -q "$WORKSPACE" 2>/dev/null; then
    ok "$WORKSPACE is a mounted volume"
else
    bad "$WORKSPACE is NOT a mounted volume — nothing persists; attach a network volume"
fi
free_ws="$(df -BG --output=avail "$WORKSPACE" 2>/dev/null | tail -1 | tr -dc 0-9)"
if [ -n "$free_ws" ]; then
    [ "$free_ws" -lt 20 ] && wrn "only ${free_ws}GB free on $WORKSPACE" || ok "${free_ws}GB free on $WORKSPACE"
fi
free_ct="$(df -BG --output=avail "$(dirname "$VENV_DIR")" 2>/dev/null | tail -1 | tr -dc 0-9)"
[ -n "$free_ct" ] && { [ "$free_ct" -lt 10 ] && wrn "only ${free_ct}GB free on container disk" || ok "${free_ct}GB free on container disk"; }

# --- ComfyUI / services ----------------------------------------------------
if [ -d "$COMFY_DIR/.git" ]; then
    ok "ComfyUI at $(git -C "$COMFY_DIR" describe --tags --always 2>/dev/null)"
else
    bad "ComfyUI not installed at $COMFY_DIR"
fi

ok "ComfyUI code: $COMFY_DIR ($COMFY_CODE_LOCATION), data: $COMFY_DATA_DIR"
if [ "$COMFY_CODE_LOCATION" = "volume" ] && [ -d /opt/ComfyUI ]; then
    wrn "running code from the network volume — restarts and node installs will be slow;"
    wrn "  unset COMFY_CODE_LOCATION (or set it to 'container') to use the image's copy"
fi

for svc in comfyui filebrowser jupyter idle-guard; do
    if service_running "$svc"; then
        ok "service running: $svc"
    elif [ "$svc" = "jupyter" ] && ! port_free "$JUPYTER_PORT"; then
        # The base image ships its own JupyterLab; ComfyPod deliberately does
        # not start a second one on an occupied port.
        ok "jupyter: port $JUPYTER_PORT already served (base image's own instance)"
    else
        wrn "service not running: $svc (log: $LOG_DIR/$svc.log)"
    fi
done

# --- auth surface ----------------------------------------------------------
listen="$(cat "$STATE_DIR/comfy-listen" 2>/dev/null || echo '?')"
body="$TMP_DIR/doctor-auth.$$"
trap 'rm -f "$body"' EXIT
code="$(curl -s -o "$body" -w '%{http_code}' --max-time 10 "http://127.0.0.1:$COMFYUI_PORT/")" || code=000
case "$code" in
    000) wrn "ComfyUI not answering on :$COMFYUI_PORT (starting up? see $LOG_DIR/comfyui.log)" ;;
    200)
        if grep -qiE 'type="password"|comfyui-login' "$body"; then
            ok "ComfyUI login page is intercepting (bound to $listen)"
        elif [ "$listen" = "0.0.0.0" ]; then
            bad "ComfyUI serves WITHOUT auth on a public bind — run: bash $SCRIPT_DIR/start.sh"
        else
            wrn "ComfyUI has no auth but is localhost-only (SSH tunnel required)"
        fi ;;
    *) ok "ComfyUI answers HTTP $code on / (auth in the path)" ;;
esac

[ -f "$COMFY_DIR/login/PASSWORD" ] && ok "ComfyUI-Login password file present" \
    || wrn "ComfyUI-Login password file missing — first visitor will be asked to set one"

# --- ComfyUI-Manager install/update capability -------------------------------
if [ -d "$COMFY_DIR/custom_nodes/ComfyUI-Manager" ]; then
    if ! comfy_has_system_user_api; then
        bad "ComfyUI is too old to expose the System User Protection API — Manager"
        bad "  force-sets security_level=strong and blocks ALL installs. Fix: comfypod-update"
    else
        mcfg="$(manager_config_path)"
        if [ -f "$mcfg" ]; then
            lvl="$(sed -n 's/^[[:space:]]*security_level[[:space:]]*=[[:space:]]*//p' "$mcfg" | tail -1)"
            case "$lvl" in
                weak)
                    ok "Manager security_level=weak — installs work on a 0.0.0.0 bind" ;;
                normal|normal-)
                    wrn "Manager security_level=$lvl — registry nodes install, but unlisted/git-URL"
                    wrn "  nodes are blocked because ComfyUI binds 0.0.0.0. Set MANAGER_SECURITY_LEVEL=weak" ;;
                strong)
                    bad "Manager security_level=strong — all installs blocked; set MANAGER_SECURITY_LEVEL=weak and restart" ;;
                *)
                    wrn "Manager security_level not set in $mcfg (defaults to 'normal')" ;;
            esac
            for flag in allow_git_url_install allow_pip_install; do
                grep -qE "^[[:space:]]*${flag}[[:space:]]*=[[:space:]]*true" "$mcfg" \
                    && ok "Manager $flag=true" \
                    || wrn "Manager $flag is not true — that class of install will be refused"
            done
        else
            wrn "Manager config not written yet ($mcfg) — restart to apply: bash $SCRIPT_DIR/start.sh"
        fi
    fi
fi

# --- secrets hygiene -------------------------------------------------------
chmod_works=0; fs_honours_chmod "$STATE_DIR" && chmod_works=1
for f in "$SECRETS_FILE" "$STATE_DIR/credentials.txt"; do
    if [ -f "$f" ]; then
        perms="$(stat -c %a "$f")"
        if [ "$perms" = "600" ]; then
            ok "$(basename "$f") is 0600"
        elif [ "$chmod_works" -eq 0 ]; then
            # Not actionable: the volume's filesystem discards mode bits, so no
            # amount of chmod will change this. Report it honestly as a caveat.
            wrn "$(basename "$f") is $perms — this volume's filesystem ignores chmod"
        else
            bad "$(basename "$f") is $perms — chmod 600 it"
        fi
    fi
done
[ -n "$HF_TOKEN" ]      && ok "HF token configured"      || wrn "no HF token (gated models will 401): comfypod-secrets set-hf-token"
[ -n "$CIVITAI_TOKEN" ] && ok "Civitai token configured" || wrn "no Civitai token: comfypod-secrets set-civitai-token"

# --- models ----------------------------------------------------------------
incomplete="$(find "$MODELS_DIR" -name '*.aria2' 2>/dev/null)"
if [ -n "$incomplete" ]; then
    wrn "incomplete downloads (resume with comfy-dl preset <name>):"
    echo "$incomplete" | sed 's/^/       /'
else
    ok "no incomplete model downloads"
fi
n_models="$(find "$MODELS_DIR" -type f \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.pth' \) 2>/dev/null | wc -l)"
ok "$n_models model files present (hash check: comfy-dl verify)"

echo "=== $FAILS failure(s), $WARNS warning(s) ==="
[ "$FAILS" -eq 0 ]
