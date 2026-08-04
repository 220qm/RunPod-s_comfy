#!/usr/bin/env bash
# ComfyPod test suite. Runs the real scripts against fake binaries (git, uv,
# pip, python-with-stub-torch, aria2c) in a throwaway workspace, so behaviour
# is verified here instead of in CI or — worse — on a rented GPU.
#
#   bash tests/run-tests.sh            run everything
#   bash tests/run-tests.sh secrets    run tests whose name matches a pattern
#
# Every bug that reached a pod during development has a regression test here.

set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# Resolved before any fake bin dir is prepended to PATH, and always invoked by
# absolute path: /usr/bin/env fails with "Argument list too long" when the
# ambient environment is large, and a fake python3 on PATH would recurse.
REAL_PY3="$(command -v python3)"
FILTER="${1:-}"
PASS=0 FAIL=0
FAILED_NAMES=()

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

# --- tiny assertion helpers -------------------------------------------------
ok()   { PASS=$((PASS+1)); printf '  %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n     %s\n' "$RED" "$OFF" "$1" "${2:-}"; }

assert_eq() { # <desc> <expected> <actual>
    [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"
}
assert_contains() { # <desc> <needle> <haystack>
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing [$2] in: $(printf '%s' "$3" | head -3 | tr '\n' ' ')" ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) bad "$1" "unexpectedly found [$2]" ;; *) ok "$1" ;; esac
}
assert_rc() { # <desc> <expected-rc> <actual-rc>
    [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected rc=$2, got rc=$3"
}

suite() {
    [ -n "$FILTER" ] && case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
    printf '\n%s== %s%s\n' "$DIM" "$1" "$OFF"
    return 0
}

# --- fake environment -------------------------------------------------------
# A workspace plus fake binaries on PATH. Fakes are deliberately dumb: they
# record what they were asked to do so tests can assert on it.
new_env() {
    WS="$(mktemp -d)"
    BINS="$WS/fakebin"
    mkdir -p "$BINS" "$WS/ws"
    # lib.sh exports its derived paths, so a suite that sourced it would leak
    # COMFY_DIR/STATE_DIR into the next suite's child processes and make them
    # operate on the previous workspace. Clear them for real isolation.
    unset WEB_PASSWORD HF_TOKEN CIVITAI_TOKEN COMFYPOD_BAKED \
          STATE_DIR REPO_DIR BIN_DIR LOG_DIR MARKER_DIR RUN_DIR CACHE_DIR \
          SNAPSHOT_DIR TMP_DIR COMFY_DIR MODELS_DIR SECRETS_FILE \
          CONSTRAINTS_FILE LOCK_FILE NODES_LOCK VENV_DIR PY PIP \
          PIP_CONSTRAINT HF_HOME UV_CACHE_DIR \
          COMFY_DATA_DIR COMFY_CODE_LOCATION COMFY_DATA_SUBDIRS 2>/dev/null || true
    export WORKSPACE="$WS/ws"
    export PATH="$BINS:$PATH"
}
cleanup_env() { [ -n "${WS:-}" ] && rm -rf "$WS"; }

# fake_python <site-dir>  — a python that can import the stub torch in site-dir
fake_python() {
    cat > "$BINS/python3" <<EOF
#!/bin/bash
export PYTHONPATH="${1:-}"
exec "$REAL_PY3" "\$@"
EOF
    chmod +x "$BINS/python3"
}

# stub_torch <dir> <version> <cuda|None> <archs...>
stub_torch() {
    local dir="$1" ver="$2" cuda="$3"; shift 3
    mkdir -p "$dir"
    {
        echo "__version__ = '$ver'"
        if [ "$cuda" = "None" ]; then echo "class version: cuda = None"
        else echo "class version: cuda = '$cuda'"; fi
        echo "class _C:"
        echo "    @staticmethod"
        echo "    def _cuda_getArchFlags(): return '$*'"
        echo "class cuda:"
        echo "    @staticmethod"
        echo "    def is_available(): return ${AVAILABLE:-True}"
        echo "    @staticmethod"
        echo "    def get_device_capability(): return (${CAP:-12}, ${CAPMIN:-0})"
        echo "    @staticmethod"
        echo "    def get_arch_list(): return '''$*'''.split()"
    } > "$dir/torch.py"
}

###############################################################################
if suite "lib: secrets are shell-quoted (a password with spaces or ';' must not break or execute)"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    for pw in 'plain123' 'has spaces' "has'quote" 'semi;colon' 'dollar$(touch /tmp/pwned)' 'back\slash'; do
        secrets_put WEB_PASSWORD "$pw"
        # shellcheck disable=SC1090
        got="$(set -a; . "$SECRETS_FILE"; set +a; printf '%s' "$WEB_PASSWORD")"
        assert_eq "round-trips [$pw]" "$pw" "$got"
    done
    assert_eq "command substitution in a password did not execute" "no" \
        "$([ -e /tmp/pwned ] && echo yes || echo no)"
    assert_eq "secrets.env is 0600" "600" "$(stat -c %a "$SECRETS_FILE")"
    secrets_put HF_TOKEN "hf_aaa"; secrets_put HF_TOKEN "hf_bbb"
    assert_eq "rewriting a key leaves exactly one entry" "1" \
        "$(grep -c '^HF_TOKEN=' "$SECRETS_FILE")"
    # shellcheck disable=SC1090
    assert_eq "rewriting a key keeps the newest value" "hf_bbb" \
        "$(set -a; . "$SECRETS_FILE"; set +a; printf '%s' "$HF_TOKEN")"
    cleanup_env
fi

###############################################################################
if suite "lib: log redaction never leaks a secret"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    WEB_PASSWORD="sup3rsecret"; HF_TOKEN="hf_tokenvalue"; CIVITAI_TOKEN="civ_val"
    out="$(log "pw=$WEB_PASSWORD hf=$HF_TOKEN civ=$CIVITAI_TOKEN" 2>&1)"
    assert_not_contains "password redacted" "sup3rsecret" "$out"
    assert_not_contains "HF token redacted" "hf_tokenvalue" "$out"
    assert_not_contains "Civitai token redacted" "civ_val" "$out"
    assert_contains "redaction marker present" "****" "$out"
    cleanup_env
fi

###############################################################################
if suite "lib: torch_check applies real CUDA compatibility rules"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    PY=python3
    # 5090 (sm_120) on a current cu128 wheel
    CAP=12 CAPMIN=0 stub_torch "$WS/t1" 2.11.0 12.8 "sm_80 sm_86 sm_90 sm_120 compute_120"
    fake_python "$WS/t1"; torch_check >/dev/null 2>&1
    assert_rc "5090 accepted on cu128 wheel" 0 $?
    # 4090 (sm_89) — wheels ship no sm_89, sm_86 must satisfy it
    CAP=8 CAPMIN=9 stub_torch "$WS/t2" 2.11.0 12.8 "sm_80 sm_86 sm_90 sm_120 compute_120"
    fake_python "$WS/t2"; torch_check >/dev/null 2>&1
    assert_rc "4090 accepted via sm_86 binary compatibility" 0 $?
    # pre-Blackwell wheel on a 5090 must fail
    CAP=12 CAPMIN=0 stub_torch "$WS/t3" 2.6.0 12.8 "sm_80 sm_86 sm_90"
    fake_python "$WS/t3"; msg="$(torch_check 2>&1)"; rc=$?
    assert_rc "pre-Blackwell wheel rejected on a 5090" 1 "$rc"
    assert_contains "rejection names the missing arch" "sm_120" "$msg"
    # CPU-only build
    CAP=12 CAPMIN=0 stub_torch "$WS/t4" 2.11.0 None ""
    fake_python "$WS/t4"; msg="$(torch_check 2>&1)"; rc=$?
    assert_rc "CPU-only build rejected" 1 "$rc"
    assert_contains "CPU-only reason is explicit" "CPU-only" "$msg"
    # old CUDA
    CAP=12 CAPMIN=0 stub_torch "$WS/t5" 2.6.0 12.4 "sm_120"
    fake_python "$WS/t5"; msg="$(torch_check 2>&1)"; rc=$?
    assert_rc "CUDA < 12.8 rejected" 1 "$rc"
    assert_contains "old-CUDA reason is explicit" "12.8" "$msg"
    cleanup_env
fi

###############################################################################
if suite "lib: torch_report actually prints (f-string backslash regression)"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    PY=python3
    CAP=12 CAPMIN=0 stub_torch "$WS/tr" 2.11.0 12.8 "sm_90 sm_120"
    fake_python "$WS/tr"
    out="$(torch_report)"
    assert_contains "reports the torch version" "2.11.0" "$out"
    assert_contains "reports the CUDA version" "12.8" "$out"
    cleanup_env
fi

###############################################################################
if suite "lib: manager_config_path follows ComfyUI's own rule"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    mkdir -p "$COMFY_DIR"
    printf 'def get_system_user_directory():\n    pass\n' > "$COMFY_DIR/folder_paths.py"
    assert_contains "new ComfyUI -> user/__manager" "user/__manager/config.ini" "$(manager_config_path)"
    printf '# nothing here\n' > "$COMFY_DIR/folder_paths.py"
    assert_contains "old ComfyUI -> user/default/ComfyUI-Manager" \
        "user/default/ComfyUI-Manager/config.ini" "$(manager_config_path)"
    cleanup_env
fi

###############################################################################
if suite "lib: run_with_heartbeat propagates exit codes and stays quiet when fast"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    out="$(run_with_heartbeat "job" -- bash -c 'exit 7' 2>&1)"; rc=$?
    assert_rc "non-zero exit propagates" 7 "$rc"
    assert_not_contains "no heartbeat for a fast job" "still running" "$out"
    run_with_heartbeat "job" -- true >/dev/null 2>&1
    assert_rc "zero exit propagates" 0 $?
    cleanup_env
fi

###############################################################################
if suite "start: constraints describe what is installed, never a guess"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    eval "$(awk '/^write_constraints\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    # baked image: /opt/constraints.txt is the truth. Simulate via a fake pip
    # freeze, since the test cannot write to /opt.
    cat > "$BINS/python3" <<EOF
#!/bin/bash
if [ "\$1" = "-c" ] && [ "\$2" = "import torch" ]; then exit 0; fi
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ] && [ "\$3" = "freeze" ]; then
    echo "numpy==2.0.0"; echo "torch==2.9.1+cu128"; echo "torchvision==0.24.1+cu128"; exit 0
fi
exec "$REAL_PY3" "\$@"
EOF
    chmod +x "$BINS/python3"
    PY="$BINS/python3"
    write_constraints > /dev/null
    got="$(tr '\n' ' ' < "$CONSTRAINTS_FILE")"
    assert_contains "uses the INSTALLED torch version" "torch==2.9.1+cu128" "$got"
    assert_not_contains "does not use the unrelated pinned guess" "2.11.0" "$got"
    assert_not_contains "only torch packages are constrained" "numpy" "$got"
    # nothing installed yet -> fall back to the pin
    rm -f "$CONSTRAINTS_FILE"
    cat > "$BINS/python3" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-c" ] && exit 1
exit 1
EOF
    chmod +x "$BINS/python3"
    write_constraints > /dev/null
    assert_contains "falls back to TORCH_SPEC on a fresh pod" "torch==2.11.0" \
        "$(tr '\n' ' ' < "$CONSTRAINTS_FILE")"
    cleanup_env
fi

###############################################################################
if suite "start: Manager config enables installs and preserves existing keys"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    PY=python3
    mkdir -p "$COMFY_DIR/custom_nodes/ComfyUI-Manager" "$COMFY_DIR/user/__manager"
    printf 'def get_system_user_directory():\n    pass\n' > "$COMFY_DIR/folder_paths.py"
    printf '[default]\nsecurity_level = normal\nchannel_url = https://keep.me\n' \
        > "$COMFY_DIR/user/__manager/config.ini"
    eval "$(awk '/^configure_manager\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    configure_manager > /dev/null 2>&1
    cfg="$(cat "$COMFY_DIR/user/__manager/config.ini")"
    assert_contains "security_level set to weak" "security_level = weak" "$cfg"
    assert_contains "git-URL installs allowed" "allow_git_url_install = true" "$cfg"
    assert_contains "pip installs allowed" "allow_pip_install = true" "$cfg"
    assert_contains "pre-existing keys preserved" "channel_url = https://keep.me" "$cfg"
    cleanup_env
fi

###############################################################################
if suite "start: heal_node_deps covers Manager-installed nodes, skips junk dirs"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    mkdir -p "$COMFY_DIR/custom_nodes"/{FromManager,__pycache__,Old.disabled,NoReqs}
    echo requests > "$COMFY_DIR/custom_nodes/FromManager/requirements.txt"
    echo requests > "$COMFY_DIR/custom_nodes/Old.disabled/requirements.txt"
    pkg_install() { echo "INSTALL $*"; }
    eval "$(awk '/^heal_node_deps\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    out="$(heal_node_deps 2>&1)"
    assert_contains "installs deps for a Manager-installed node" "custom_nodes/FromManager/requirements.txt" "$out"
    assert_not_contains "skips disabled nodes" "Old.disabled" "$out"
    assert_not_contains "skips __pycache__" "__pycache__" "$out"
    assert_contains "counts exactly one node" "for 1 custom node" "$out"
    cleanup_env
fi

###############################################################################
if suite "download: presets, skip-existing, and hash verification"; then
    new_env
    # shellcheck disable=SC1091
    out="$(bash "$REPO/scripts/download-models.sh" list 2>&1)"
    assert_contains "lists the krea2 preset" "krea2" "$out"
    assert_contains "lists the MiniMax H3 video model" "minimax_h3_fl2va_pruned_fp8_scaled" "$out"
    assert_not_contains "no Wan models remain" "wan2.2" "$out"
    m="$WORKSPACE/ComfyUI/models"
    mkdir -p "$m/diffusion_models" "$m/text_encoders" "$m/vae"
    echo fake > "$m/diffusion_models/krea2_turbo_fp8_scaled.safetensors"
    echo fake > "$m/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
    echo fake > "$m/vae/qwen_image_vae.safetensors"
    printf '#!/bin/sh\necho "aria2c SHOULD NOT RUN"; exit 9\n' > "$BINS/aria2c"; chmod +x "$BINS/aria2c"
    out="$(bash "$REPO/scripts/download-models.sh" preset krea2 2>&1)"; rc=$?
    assert_rc "existing files are skipped without downloading" 0 "$rc"
    assert_not_contains "aria2c was never invoked" "SHOULD NOT RUN" "$out"
    out="$(bash "$REPO/scripts/download-models.sh" verify krea2 2>&1)"; rc=$?
    assert_rc "verify fails when a hash mismatches" 1 "$rc"
    assert_contains "the corrupt file is named" "CORRUPT" "$out"
    cleanup_env
fi

###############################################################################
if suite "download: tokens go in a 0600 file, never argv"; then
    new_env
    cat > "$BINS/aria2c" <<'EOF'
#!/usr/bin/env bash
echo "ARGV: $*"
for a in "$@"; do
  if [ -f "$a" ]; then echo "INPUTPERMS: $(stat -c %a "$a")"; cat "$a"; fi
done
EOF
    chmod +x "$BINS/aria2c"
    export HF_TOKEN="hf_SUPERSECRET"
    out="$(bash "$REPO/scripts/download-models.sh" url \
        "https://huggingface.co/x/y/resolve/main/z.safetensors" loras 2>&1)"
    assert_not_contains "token absent from aria2 argv" "hf_SUPERSECRET" \
        "$(printf '%s' "$out" | grep '^ARGV:')"
    assert_contains "token present in the input file" "Bearer hf_SUPERSECRET" "$out"
    assert_contains "input file is 0600" "INPUTPERMS: 600" "$out"
    unset HF_TOKEN
    cleanup_env
fi

###############################################################################
if suite "node: add records for future pods, remove protects critical nodes"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh" >/dev/null; ensure_dirs
    mkdir -p "$COMFY_DIR/custom_nodes"
    src="$WS/NodeSrc"; mkdir -p "$src"
    ( cd "$src" && git init -q . && git config user.email t@t && git config user.name t \
        && echo x > __init__.py && git add -A && git commit -qm i ) >/dev/null 2>&1
    # git refuses file:// transport in submodule-ish contexts; plain clone is fine
    out="$(bash "$REPO/scripts/node.sh" add "https://example.invalid/x" 2>&1)"; rc=$?
    assert_rc "a URL that cannot be cloned fails loudly" 1 "$rc"
    assert_contains "clone failure is reported" "clone failed" "$out"
    out="$(bash "$REPO/scripts/node.sh" remove ComfyUI-Login 2>&1)"; rc=$?
    assert_rc "refuses to remove the auth node" 1 "$rc"
    assert_contains "explains why" "auth/management surface" "$out"
    out="$(bash "$REPO/scripts/node.sh" remove ComfyUI-Manager 2>&1)"
    assert_contains "refuses to remove the manager" "auth/management surface" "$out"
    cleanup_env
fi

###############################################################################
if suite "verify-torch: classifies wheels correctly without a GPU"; then
    new_env
    # exactly the CI condition: is_available() False, get_arch_list() empty
    d="$WS/vt"; mkdir -p "$d"
    cat > "$d/torch.py" <<'EOF'
__version__ = "2.11.0+cu128"
class version: cuda = "12.8"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_80 sm_86 sm_90 sm_120 compute_120"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
EOF
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "good cu128 wheel accepted on a GPU-less runner" 0 "$rc"
    assert_contains "arch list was actually read" "sm_120" "$out"
    cat > "$d/torch.py" <<'EOF'
__version__ = "2.6.0+cu124"
class version: cuda = "12.8"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_75 sm_80 sm_86 sm_90"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
EOF
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "pre-Blackwell wheel rejected" 1 "$rc"
    cat > "$d/torch.py" <<'EOF'
__version__ = "2.11.0+cpu"
class version: cuda = None
class _C: pass
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
EOF
    PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" >/dev/null 2>&1
    assert_rc "CPU-only wheel rejected" 1 $?
    cleanup_env
fi

###############################################################################
if suite "verify-torch: a companion that cannot load rejects the candidate"; then
    new_env
    d="$WS/vtc"; mkdir -p "$d"
    good_torch() { cat > "$d/torch.py" <<'EOF'
__version__ = "2.13.0+cu130"
class version: cuda = "13.0"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_80 sm_86 sm_90 sm_120 compute_120"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
EOF
    }

    good_torch
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "torch alone, no companions installed, is accepted" 0 "$rc"
    assert_contains "absent companion is reported as skipped" "not installed" "$out"

    # torchvision present but built against a different torch: the real failure
    # is an undefined symbol at import time.
    printf 'raise ImportError("undefined symbol: _ZN3c10")\n' > "$d/torchvision.py"
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "broken torchvision rejects the candidate" 1 "$rc"
    assert_contains "reason names the companion" "torchvision" "$out"
    assert_contains "reason is the import failure" "DOES NOT IMPORT" "$out"

    printf '__version__ = "0.28.0"\n' > "$d/torchvision.py"
    printf 'raise OSError("libtorch_cpu.so: undefined symbol")\n' > "$d/torchaudio.py"
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "broken torchaudio rejects the candidate too" 1 "$rc"
    assert_contains "working companion still reported" "0.28.0" "$out"

    printf '__version__ = "2.11.0"\n' > "$d/torchaudio.py"
    out="$(PYTHONPATH="$d" python3 "$REPO/docker/verify-torch.py" 2>&1)"; rc=$?
    assert_rc "a fully importable trio is accepted" 0 "$rc"
    cleanup_env
fi

###############################################################################
if suite "nvcc-check: the toolkit must match the CUDA major torch was built for"; then
    new_env
    mkdir -p "$WS/venv/bin" "$WS/cu"
    cat > "$WS/venv/bin/python" <<EOF
#!/bin/bash
export PYTHONPATH="$WS/cu"
exec "$REAL_PY3" "\$@"
EOF
    chmod +x "$WS/venv/bin/python"
    mk_torch() {
        rm -rf "$WS/cu/__pycache__"
        if [ "$1" = none ]; then printf 'class version: cuda = None\n' > "$WS/cu/torch.py"
        else printf "class version: cuda = '%s'\n" "$1" > "$WS/cu/torch.py"; fi
    }
    mk_nvcc() {
        printf '#!/bin/bash\necho "Cuda compilation tools, release %s, V%s.0"\n' "$1" "$1" \
            > "$BINS/nvcc"
        chmod +x "$BINS/nvcc"
    }

    mk_torch 13.0; mk_nvcc 13.0
    out="$(bash "$REPO/docker/nvcc-check.sh" "$WS/venv" 2>&1)"; rc=$?
    assert_rc "nvcc 13 accepted for a cu130 torch" 0 "$rc"
    assert_contains "verdict names both versions" "nvcc 13.0 matches torch CUDA 13.0" "$out"

    mk_torch 13.0; mk_nvcc 12.8
    out="$(bash "$REPO/docker/nvcc-check.sh" "$WS/venv" 2>&1)"; rc=$?
    assert_rc "nvcc 12.8 rejected for a cu130 torch" 1 "$rc"
    assert_contains "verdict explains the consequence" "refuses to build extensions" "$out"

    mk_torch 12.8; mk_nvcc 12.8
    bash "$REPO/docker/nvcc-check.sh" "$WS/venv" > /dev/null 2>&1
    assert_rc "a matching CUDA 12 pair is fine too" 0 $?

    mk_torch 13.0; rm -f "$BINS/nvcc"
    out="$(bash "$REPO/docker/nvcc-check.sh" "$WS/venv" 2>&1)"; rc=$?
    assert_rc "no nvcc at all is a failure" 1 "$rc"
    assert_contains "and says why" "no nvcc" "$out"

    mk_torch none; mk_nvcc 13.0
    bash "$REPO/docker/nvcc-check.sh" "$WS/venv" > /dev/null 2>&1
    assert_rc "a CPU-only torch cannot build extensions" 1 $?
    cleanup_env
fi

###############################################################################
if suite "install-torch: rejects an unusable candidate and tries the next"; then
    new_env
    mkdir -p "$WS/venv/bin" "$WS/active"
    cat > "$WS/venv/bin/python" <<EOF
#!/bin/bash
export PYTHONPATH="$WS/active"
exec "$REAL_PY3" "\$@"
EOF
    cat > "$WS/venv/bin/pip" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "index versions") echo "torch (2.11.0+cu128)";;
  freeze*) echo "torch==2.9.1+cu128";;
esac
EOF
    # first candidate installs a wheel with no Blackwell support, second is good
    cat > "$BINS/uv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *2.11.0*) cat > "$WS/active/torch.py" <<'T'
__version__ = "2.11.0+cu128"
class version: cuda = "12.8"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_80 sm_86 sm_90"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
T
  ;;
  *) cat > "$WS/active/torch.py" <<'T'
__version__ = "2.9.1+cu128"
class version: cuda = "12.8"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_80 sm_86 sm_90 sm_120 compute_120"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
T
  ;;
esac
EOF
    chmod +x "$WS/venv/bin/python" "$WS/venv/bin/pip" "$BINS/uv"
    out="$(TORCH_CANDIDATES="torch==2.11.0|torch==2.9.1" \
        bash "$REPO/docker/install-torch.sh" "$WS/venv" "https://fake/cu128" "$WS/c.txt" 2>&1)"; rc=$?
    assert_rc "an unusable first candidate does not fail the build" 0 "$rc"
    assert_contains "moved on from the bad candidate" "trying next" "$out"
    assert_contains "accepted the working candidate" "accepted: torch==2.9.1" "$out"
    assert_contains "froze the accepted version" "torch==2.9.1+cu128" "$(cat "$WS/c.txt")"
    cleanup_env
fi

###############################################################################
if suite "auth-guard: fails closed when ComfyUI serves without a login page"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh" >/dev/null; ensure_dirs
    web="$WS/web"; mkdir -p "$web"
    echo '<html><div id="app">canvas</div></html>' > "$web/index.html"
    ( cd "$web" && exec "$REAL_PY3" -m http.server 8188 --bind 127.0.0.1 >/dev/null 2>&1 ) &
    srv=$!
    # Wait for the port instead of guessing, and bound the guard's own wait so
    # a failure here surfaces as a failed assertion rather than a hung suite.
    for _ in $(seq 40); do
        (exec 3<>/dev/tcp/127.0.0.1/8188) 2>/dev/null && break
        sleep 0.25
    done
    export AUTH_GUARD_TIMEOUT=15
    printf '0.0.0.0' > "$STATE_DIR/comfy-listen"
    bash "$REPO/scripts/auth-guard.sh" >/dev/null 2>&1
    assert_rc "guard reports failure" 1 $?
    assert_eq "bind forced back to localhost" "127.0.0.1" "$(cat "$STATE_DIR/comfy-listen")"
    echo '<html><form><input type="password"></form></html>' > "$web/index.html"
    printf '0.0.0.0' > "$STATE_DIR/comfy-listen"
    bash "$REPO/scripts/auth-guard.sh" >/dev/null 2>&1
    assert_rc "guard passes when the login page intercepts" 0 $?
    assert_eq "public bind retained" "0.0.0.0" "$(cat "$STATE_DIR/comfy-listen")"
    kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
    unset AUTH_GUARD_TIMEOUT
    cleanup_env
fi

###############################################################################
if suite "snapshot: save and restore roll a node back to its pinned commit"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh" >/dev/null; ensure_dirs
    n="$COMFY_DIR/custom_nodes/NodeA"; mkdir -p "$n"
    ( cd "$n" && git init -q . && git config user.email t@t && git config user.name t \
      && echo v1 > f && git add -A && git commit -qm one && git remote add origin "$n" ) >/dev/null 2>&1
    bash "$REPO/scripts/snapshot.sh" save baseline >/dev/null 2>&1
    ( cd "$n" && echo v2 > f && git commit -qam two ) >/dev/null 2>&1
    before="$(git -C "$n" rev-parse HEAD)"
    bash "$REPO/scripts/snapshot.sh" restore baseline >/dev/null 2>&1
    after="$(git -C "$n" rev-parse HEAD)"
    [ "$before" != "$after" ] && ok "restore moved the node back" || bad "restore moved the node back" "still at $after"
    assert_eq "restored to the snapshotted commit" "one" "$(git -C "$n" show -s --format=%s)"
    assert_contains "snapshot is listed" "baseline" "$(bash "$REPO/scripts/snapshot.sh" list 2>&1)"
    cleanup_env
fi

###############################################################################
if suite "doctor: reports problems instead of crashing on a bare pod"; then
    new_env
    out="$(bash "$REPO/scripts/doctor.sh" 2>&1)"; rc=$?
    assert_rc "exits non-zero when things are broken" 1 "$rc"
    assert_contains "flags the missing volume" "NOT a mounted volume" "$out"
    assert_contains "flags the missing venv" "venv missing" "$out"
    assert_contains "flags missing ComfyUI" "ComfyUI not installed" "$out"
    assert_contains "prints a summary line" "failure(s)" "$out"
    cleanup_env
fi

###############################################################################
if suite "config: manifests and node list are well-formed"; then
    for f in "$REPO"/config/presets/*.txt; do
        bad_lines="$(grep -vE '^\s*(#|$)' "$f" | awk -F'|' 'NF < 3 || NF > 4 {print FILENAME": "$0}' FILENAME="$(basename "$f")")"
        [ -z "$bad_lines" ] && ok "$(basename "$f") lines have 3-4 fields" \
            || bad "$(basename "$f") lines have 3-4 fields" "$bad_lines"
        urls="$(grep -vE '^\s*(#|$)' "$f" | cut -d'|' -f3)"
        bad_urls="$(printf '%s\n' "$urls" | grep -vE '^https://' || true)"
        [ -z "$bad_urls" ] && ok "$(basename "$f") URLs are https" || bad "$(basename "$f") URLs are https" "$bad_urls"
    done
    n_bad="$(grep -vE '^\s*(#|$)' "$REPO/config/nodes.txt" | grep -vcE '^https://github\.com/' || true)"
    assert_eq "every default node is an https GitHub URL" "0" "$n_bad"
    for required in ComfyUI-Manager ComfyUI-Login ComfyUI-Model-Manager; do
        assert_contains "$required is installed by default" "$required" "$(cat "$REPO/config/nodes.txt")"
    done
fi


###############################################################################
if suite "layout: code runs from container disk, data stays on the volume"; then
    new_env
    mkdir -p "$WS/opt/ComfyUI/models" "$WS/opt/ComfyUI/custom_nodes"
    echo "shipped" > "$WS/opt/ComfyUI/models/from_image.txt"
    # shellcheck disable=SC1091
    export COMFY_DIR="$WS/opt/ComfyUI" COMFY_CODE_LOCATION=container
    source "$REPO/scripts/lib.sh"
    ensure_dirs
    eval "$(awk '/^link_comfy_data\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    link_comfy_data > /dev/null
    for d in models output input user; do
        [ -L "$COMFY_DIR/$d" ] && ok "$d is a symlink into the volume" \
            || bad "$d is a symlink into the volume" "not a link"
    done
    assert_eq "symlink resolves to the volume" "$COMFY_DATA_DIR/models" \
        "$(readlink "$COMFY_DIR/models")"
    assert_eq "files shipped in the image were merged onto the volume" "shipped" \
        "$(cat "$COMFY_DATA_DIR/models/from_image.txt" 2>/dev/null)"
    echo weights > "$COMFY_DATA_DIR/models/downloaded.safetensors"
    assert_eq "downloads land where ComfyUI reads them" "weights" \
        "$(cat "$COMFY_DIR/models/downloaded.safetensors" 2>/dev/null)"
    assert_eq "MODELS_DIR points at the volume" "$COMFY_DATA_DIR/models" "$MODELS_DIR"
    link_comfy_data > /dev/null   # idempotent
    assert_eq "re-running does not nest links" "$COMFY_DATA_DIR/models" \
        "$(readlink "$COMFY_DIR/models")"
    cleanup_env
fi

###############################################################################
if suite "layout: Manager-installed nodes are recorded so they survive the pod"; then
    new_env
    mkdir -p "$WS/opt/ComfyUI/custom_nodes"
    # shellcheck disable=SC1091
    export COMFY_DIR="$WS/opt/ComfyUI" COMFY_CODE_LOCATION=container
    source "$REPO/scripts/lib.sh"
    ensure_dirs
    for n in ComfyUI-Manager UserAddedNode; do
        d="$COMFY_DIR/custom_nodes/$n"; mkdir -p "$d"
        ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t \
          && echo x > f && git add -A && git commit -qm i \
          && git remote add origin "https://github.com/example/$n" ) >/dev/null 2>&1
    done
    export SCRIPT_DIR="$REPO/scripts"
    eval "$(awk '/^capture_manager_installed_nodes\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    capture_manager_installed_nodes > /dev/null
    rec="$(cat "$STATE_DIR/extra-nodes.txt" 2>/dev/null)"
    assert_contains "a user-installed node is recorded" "example/UserAddedNode" "$rec"
    capture_manager_installed_nodes > /dev/null
    assert_eq "recording is idempotent" "1" \
        "$(grep -c 'UserAddedNode' "$STATE_DIR/extra-nodes.txt")"
    cleanup_env
fi

###############################################################################
if suite "start: node dependencies install in a single resolver pass"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    mkdir -p "$COMFY_DIR/custom_nodes"/{A,B,C}
    for n in A B C; do echo "pkg$n" > "$COMFY_DIR/custom_nodes/$n/requirements.txt"; done
    calls=0
    pkg_install() { calls=$((calls+1)); echo "CALL $*"; }
    eval "$(awk '/^heal_node_deps\(\)/,/^}$/' "$REPO/scripts/start.sh")"
    out="$(heal_node_deps 2>&1)"
    assert_contains "all three requirement files in one call" "A/requirements.txt" "$out"
    assert_contains "second file in the same call" "B/requirements.txt" "$out"
    assert_contains "third file in the same call" "C/requirements.txt" "$out"
    assert_eq "exactly one pkg_install invocation for three nodes" "1" \
        "$(printf '%s' "$out" | grep -c '^CALL')"
    cleanup_env
fi


###############################################################################
if suite "download: an optional entry may 404 without failing the preset"; then
    new_env
    mkdir -p "$WORKSPACE/presets"
    cat > "$WORKSPACE/presets/opt.txt" <<'MANIFEST'
# size: ~0 GB
vae|present.safetensors|https://example.invalid/present.safetensors
optional:vae|maybe.safetensors|https://example.invalid/maybe.safetensors
MANIFEST
    # aria2c that always fails, so both entries hit the failure path
    printf '#!/bin/sh\nexit 1\n' > "$BINS/aria2c"; chmod +x "$BINS/aria2c"
    out="$(PRESET_DIR="$WORKSPACE/presets" bash "$REPO/scripts/download-models.sh" preset opt 2>&1)"; rc=$?
    assert_rc "a required failure still fails the preset" 1 "$rc"
    assert_contains "required file reported as FAILED" "FAILED: vae/present.safetensors" "$out"
    assert_contains "optional file downgraded to a warning" "optional file not available" "$out"
    assert_not_contains "optional file not counted as FAILED" "FAILED: vae/maybe.safetensors" "$out"

    # now only the optional one is missing -> preset must succeed
    cat > "$WORKSPACE/presets/opt.txt" <<'MANIFEST'
optional:vae|maybe.safetensors|https://example.invalid/maybe.safetensors
MANIFEST
    PRESET_DIR="$WORKSPACE/presets" bash "$REPO/scripts/download-models.sh" preset opt >/dev/null 2>&1
    assert_rc "a preset of only-optional misses succeeds" 0 $?

    out="$(PRESET_DIR="$WORKSPACE/presets" bash "$REPO/scripts/download-models.sh" verify opt 2>&1)"; rc=$?
    assert_rc "verify does not fail on a missing optional file" 0 "$rc"
    assert_contains "verify labels it OPTIONAL" "OPTIONAL" "$out"
    cleanup_env
fi


###############################################################################
if suite "cuda: driver floor is enforced per CUDA major"; then
    new_env
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib.sh"; ensure_dirs
    PY=python3
    mk_smi() { printf '#!/bin/bash\necho "%s"\n' "$1" > "$BINS/nvidia-smi"; chmod +x "$BINS/nvidia-smi"; }
    # The __pycache__ purge is not optional: "13.0" and "12.8" are the same
    # length, so a rewrite inside the same second leaves mtime+size unchanged
    # and python happily reuses the previous .pyc.
    mk_torch() {
        mkdir -p "$WS/cu"; rm -rf "$WS/cu/__pycache__"
        printf "class version: cuda = '%s'\n" "$1" > "$WS/cu/torch.py"
        fake_python "$WS/cu"
    }

    mk_torch 13.0; mk_smi "580.159.04"
    out="$(driver_check)"; rc=$?
    assert_rc "driver 580 accepted for a CUDA 13 build" 0 "$rc"
    assert_contains "verdict names the CUDA major" "CUDA 13" "$out"

    mk_torch 13.0; mk_smi "570.86.15"
    out="$(driver_check)"; rc=$?
    assert_rc "driver 570 rejected for a CUDA 13 build" 1 "$rc"
    assert_contains "verdict says what is needed" ">= 580" "$out"

    mk_torch 12.8; mk_smi "570.86.15"
    driver_check > /dev/null; rc=$?
    assert_rc "driver 570 is fine for a CUDA 12.8 build" 0 "$rc"

    mk_torch 12.8; mk_smi "520.61.05"
    driver_check > /dev/null; rc=$?
    assert_rc "driver 520 rejected even for CUDA 12" 1 "$rc"

    rm -f "$BINS/nvidia-smi"
    driver_check > /dev/null; rc=$?
    assert_rc "no driver at all is not treated as a failure" 0 "$rc"
    cleanup_env
fi

###############################################################################
if suite "install-torch: falls back to the next index when one has nothing usable"; then
    new_env
    mkdir -p "$WS/venv/bin" "$WS/active"
    cat > "$WS/venv/bin/python" <<EOF
#!/bin/bash
export PYTHONPATH="$WS/active"
exec "$REAL_PY3" "\$@"
EOF
    printf '#!/bin/bash\ncase "$1 $2" in "index versions") echo "torch (2.11.0)";; freeze*) echo "torch==2.11.0+cu128";; esac\n' \
        > "$WS/venv/bin/pip"
    # cu130 index: only ever yields a CPU-only wheel. cu128: yields a good one.
    cat > "$BINS/uv" <<EOF
#!/bin/bash
case "\$*" in
  *cu130*) cat > "$WS/active/torch.py" <<'T'
__version__ = "2.11.0+cpu"
class version: cuda = None
class _C: pass
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
T
  ;;
  *) cat > "$WS/active/torch.py" <<'T'
__version__ = "2.11.0+cu128"
class version: cuda = "12.8"
class _C:
    @staticmethod
    def _cuda_getArchFlags(): return "sm_80 sm_86 sm_90 sm_120 compute_120"
class cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def get_arch_list(): return []
T
  ;;
esac
EOF
    chmod +x "$WS/venv/bin/python" "$WS/venv/bin/pip" "$BINS/uv"
    out="$(TORCH_CANDIDATES="torch==2.11.0" bash "$REPO/docker/install-torch.sh" "$WS/venv" \
        "https://fake/cu130 https://fake/cu128" "$WS/c.txt" 2>&1)"; rc=$?
    assert_rc "the build succeeds via the fallback index" 0 "$rc"
    assert_contains "the first index was tried" "index: https://fake/cu130" "$out"
    assert_contains "and reported as unusable" "falling back to the next index" "$out"
    assert_contains "the fallback index is the one accepted" "from https://fake/cu128" "$out"
    cleanup_env
fi

###############################################################################
if suite "dockerfile: base image, torch index and build assertions stay in sync"; then
    # A CUDA 12 toolkit under a cu130 torch does not fail loudly — torch simply
    # refuses to compile extensions, SageAttention 2 falls back to the v1 wheel
    # and the image ships quietly slower. Keep the two majors welded together.
    cuda_major_of() { # <string containing cuda<digits> or cu<digits>>
        local d=""
        [[ "$1" =~ cuda:?([0-9]+) ]] && d="${BASH_REMATCH[1]}"
        [ -z "$d" ] && [[ "$1" =~ cu([0-9]{3,4}) ]] && d="${BASH_REMATCH[1]}"
        [ -z "$d" ] && return 1
        if [ "${#d}" -ge 3 ]; then printf '%s' "${d:0:2}"; else printf '%s' "$d"; fi
    }
    from_line="$(grep -m1 '^FROM ' "$REPO/Dockerfile")"
    idx_line="$(grep -m1 '^ENV TORCH_INDEX=' "$REPO/Dockerfile" | tr -d '"')"
    first_index="${idx_line#*=}"; first_index="${first_index%% *}"

    base_major="$(cuda_major_of "$from_line")"
    idx_major="$(cuda_major_of "$first_index")"
    assert_eq "the base image's CUDA major matches the preferred torch index" \
        "$base_major" "$idx_major"
    assert_contains "the base is a devel/CUDA image, not a bare OS" "cuda" "$from_line"

    # Both of these were absent from ComfyUI tags that are only weeks old, and
    # each one silently breaks a headline feature.
    assert_contains "build asserts the Manager-unblocking API" \
        "get_system_user_directory" "$(cat "$REPO/Dockerfile")"
    assert_contains "build asserts MiniMax H3 support" \
        "class MiniMaxH3" "$(cat "$REPO/Dockerfile")"
    assert_contains "sage build is gated on a matching nvcc" \
        "nvcc-check.sh" "$(cat "$REPO/Dockerfile")"
fi

###############################################################################
printf '\n%s────────────────────────────────────────%s\n' "$DIM" "$OFF"
printf ' %s%d passed%s, %s%d failed%s\n' "$GREEN" "$PASS" "$OFF" \
    "$([ "$FAIL" -gt 0 ] && printf '%s' "$RED")" "$FAIL" "$OFF"
if [ "$FAIL" -gt 0 ]; then
    printf ' failing:\n'; printf '   - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
