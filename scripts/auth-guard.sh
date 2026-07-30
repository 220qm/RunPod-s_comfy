#!/usr/bin/env bash
# ComfyPod auth-guard: verifies that ComfyUI-Login is actually intercepting
# requests before leaving ComfyUI bound to 0.0.0.0. If an unauthenticated
# canvas is ever served, the bind is forced back to 127.0.0.1 (fail closed).
export SCRIPT_NAME=auth-guard
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
set -uo pipefail
ensure_dirs

LISTEN_FILE="$STATE_DIR/comfy-listen"
[ "$(cat "$LISTEN_FILE" 2>/dev/null)" = "0.0.0.0" ] || { log "ComfyUI already local-only; nothing to guard"; exit 0; }

fail_closed() {
    warn "############################################################"
    warn "# ComfyUI answered WITHOUT a login page while bound to"
    warn "# 0.0.0.0 — forcing it back to 127.0.0.1. Check that the"
    warn "# ComfyUI-Login node imports cleanly ($LOG_DIR/comfyui.log),"
    warn "# then re-run start.sh. SSH tunnel: ssh -L 8188:localhost:8188"
    warn "############################################################"
    printf '127.0.0.1' > "$LISTEN_FILE"
    pkill -f "main.py --listen" 2>/dev/null || true   # supervisor restarts it re-bound
}

# First boot can spend minutes installing node deps before the port answers.
# Configurable so tests (and impatient operators) do not wait half an hour.
deadline=$((SECONDS + ${AUTH_GUARD_TIMEOUT:-1800}))
body="$TMP_DIR/auth-check.$$"
trap 'rm -f "$body"' EXIT
while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 10 "http://127.0.0.1:$COMFYUI_PORT/")" || code=000
    case "$code" in
        000) sleep 10; continue ;;                       # not up yet
        401|403|302) log "auth check passed (HTTP $code)"; exit 0 ;;
        200)
            if grep -qiE 'type="password"|comfyui-login' "$body"; then
                log "auth check passed (login page served)"
                exit 0
            fi
            fail_closed
            exit 1 ;;
        *) sleep 10 ;;
    esac
done
warn "ComfyUI did not answer within 30 min — auth state unverified; check $LOG_DIR/comfyui.log"
