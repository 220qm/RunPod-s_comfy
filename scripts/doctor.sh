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
    tv="$("$PY" -c 'import torch; print(torch.__version__, torch.version.cuda)' 2>/dev/null)" || tv=""
    if [ -z "$tv" ]; then
        bad "torch does not import — rebuild env: rm -rf $VENV_DIR && bash $SCRIPT_DIR/start.sh"
    elif ! torch_ok; then
        bad "torch is $tv, expected cu128 — a node likely downgraded it; rebuild env (see above)"
    else
        ok "torch $tv"
        cap="$("$PY" -c 'import torch; c = torch.cuda.get_device_capability(); print(f"sm_{c[0]}{c[1]}")' 2>/dev/null)" \
            && ok "CUDA capability $cap usable from torch" \
            || bad "torch cannot talk to the GPU (capability query failed)"
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

for svc in comfyui filebrowser jupyter idle-guard; do
    if service_running "$svc"; then ok "service running: $svc"
    else wrn "service not running: $svc (log: $LOG_DIR/$svc.log)"
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

# --- secrets hygiene -------------------------------------------------------
for f in "$SECRETS_FILE" "$STATE_DIR/credentials.txt"; do
    if [ -f "$f" ]; then
        perms="$(stat -c %a "$f")"
        [ "$perms" = "600" ] && ok "$(basename "$f") is 0600" || bad "$(basename "$f") is $perms — chmod 600 it"
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
