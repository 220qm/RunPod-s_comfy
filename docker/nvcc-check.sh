#!/usr/bin/env bash
# Does this image's nvcc match the CUDA major torch was built against?
#
# torch.utils.cpp_extension REFUSES to compile when the majors differ — it
# raises RuntimeError, it does not warn — so every source-built CUDA extension
# depends on this being true. SageAttention 2 is the one that matters here:
# with a CUDA 12 toolkit and a cu130 torch the build fails ~20 minutes in and
# silently falls back to the much slower v1 wheel.
#
# Usage: nvcc-check.sh <venv>   — prints a verdict, exits 1 on a mismatch.

set -uo pipefail

VENV="${1:?usage: nvcc-check.sh <venv>}"
PY="$VENV/bin/python"

torch_cuda="$("$PY" -c 'import torch; print(torch.version.cuda or "")' 2> /dev/null)"
if [ -z "$torch_cuda" ]; then
    echo "torch is a CPU-only build — no CUDA extension can be compiled"
    exit 1
fi

nvcc_bin="$(command -v nvcc || true)"
if [ -z "$nvcc_bin" ]; then
    for cand in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
        [ -x "$cand" ] && { nvcc_bin="$cand"; break; }
    done
fi
if [ -z "$nvcc_bin" ]; then
    echo "no nvcc on this image — CUDA extensions cannot be compiled (need a -devel base)"
    exit 1
fi

nvcc_cuda="$("$nvcc_bin" --version 2> /dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
if [ -z "$nvcc_cuda" ]; then
    echo "could not read a version out of $nvcc_bin"
    exit 1
fi

if [ "${nvcc_cuda%%.*}" != "${torch_cuda%%.*}" ]; then
    echo "nvcc $nvcc_cuda vs torch CUDA $torch_cuda — major mismatch; torch refuses to build extensions"
    exit 1
fi

echo "nvcc $nvcc_cuda matches torch CUDA $torch_cuda"
