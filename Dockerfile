# ComfyPod baked image — the one-click deployment path.
#
# Everything that used to happen at pod boot (torch download, venv build,
# ComfyUI clone, node installs, binary downloads, SageAttention compile)
# happens HERE, once, in CI. A pod booting from this image only seeds the
# volume and starts services — no network fetch on the critical path, so the
# whole class of "silent boot failure" disappears.
#
# Built and pushed automatically by .github/workflows/build-image.yml to
#   ghcr.io/220qm/comfypod:latest
# No weights, no secrets in the image — ever.

# runpod/base (not runpod/pytorch): we build our own venv, so the ~4 GB of
# system-python torch in the pytorch image is dead weight. What we do need
# from RunPod's base is here — /start.sh (SSH + proxy plumbing), nginx,
# jupyterlab, uv and filebrowser — on top of nvidia/cuda:13.0.0-cudnn-DEVEL,
# which is what gives us an nvcc that matches the cu130 torch below.
FROM runpod/base:1.1.0-cuda1300-ubuntu2404
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The base points pip/uv at /workspace/.cache, which is correct at run time
# (the network volume, so wheels survive a pod swap) but wrong during the
# build, where /workspace is an ordinary directory and every cached wheel
# would be baked into a layer. Build into /tmp; the runtime values are
# restored at the end of this file.
ENV PIP_CACHE_DIR=/tmp/pip-cache UV_CACHE_DIR=/tmp/uv-cache

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        aria2 ffmpeg rsync libgl1 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv and filebrowser ship with runpod/base (uv at /bin/uv, filebrowser
# SHA-256-verified at /usr/local/bin). Only fetch them if a future base drops
# them — an unnecessary `curl | sh` is a supply-chain risk for nothing.
RUN set -e; \
    command -v uv > /dev/null \
    || curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh; \
    command -v filebrowser > /dev/null \
    || { curl -fsSL --retry 3 \
            https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
            | tar -xz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser; }; \
    uv --version && filebrowser version

ENV VENV=/opt/comfypod-venv
# CUDA 13 first, CUDA 12.8 as an automatic fallback.
#
# cu130 is not cosmetic here: ComfyUI only gets hardware NVFP4/INT8
# acceleration on a CUDA 13 build. On cu128 those paths are emulated and are
# markedly slower than fp8 — and the default MiniMax H3 preset ships an NVFP4
# text encoder, so the CUDA version decides whether that model runs fast or
# crawls. The startup banner is the tell: it must read "+cu130".
#
# The cost is a stricter driver floor: CUDA 13 needs NVIDIA driver >= 580,
# where CUDA 12.8 runs on 525+. Pods that land on an older host are detected
# at boot (preflight) and by comfypod-doctor, which tells you to switch the
# template to a cu128 build rather than leaving you with a dead pod.
ENV TORCH_INDEX="https://download.pytorch.org/whl/cu130 https://download.pytorch.org/whl/cu128"

# Override to pin a specific combination without editing this file:
#   docker build --build-arg TORCH_CANDIDATES="torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0" .
ARG TORCH_CANDIDATES=""
ENV TORCH_CANDIDATES=${TORCH_CANDIDATES}

# Torch: install the newest candidate that is *verified usable* on every GPU
# we target, then freeze it into /opt/constraints.txt so the "no custom node
# may downgrade torch" guard reflects what is really installed. Each candidate
# is verified before it is accepted, so an unusable build makes the installer
# move to the next candidate instead of failing the whole image.
COPY docker/install-torch.sh docker/verify-torch.py docker/nvcc-check.sh /opt/comfypod-build/
RUN chmod +x /opt/comfypod-build/*.sh \
    && python3 -c "import sys; assert sys.version_info >= (3, 11), sys.version; print('python', sys.version.split()[0])" \
    && uv venv --seed --python "$(command -v python3)" "$VENV" \
    && /opt/comfypod-build/install-torch.sh "$VENV" "$TORCH_INDEX" /opt/constraints.txt \
    && uv cache clean && rm -rf /tmp/pip-cache /tmp/uv-cache

# ComfyUI at the latest release tag, with the two capabilities this image
# promises asserted rather than assumed — "latest tag" is a moving target and
# both of these were missing from tags that are only weeks old:
#   * get_system_user_directory — without it ComfyUI-Manager force-sets
#     security_level=strong and every node install is blocked.
#   * MiniMaxH3 — the default model preset. v0.29.x cannot load it at all,
#     so an image without it would download 21 GB of weights for nothing.
RUN git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)" \
    && git describe --tags \
    && { grep -q "def get_system_user_directory" folder_paths.py \
        || { echo "FAIL: ComfyUI lacks get_system_user_directory — Manager installs would be blocked"; exit 1; }; } \
    && { grep -q "class MiniMaxH3" comfy/supported_models.py \
        || { echo "FAIL: ComfyUI lacks MiniMax H3 support — the default preset would not load"; exit 1; }; } \
    && uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        -r requirements.txt \
    && uv cache clean && rm -rf /tmp/pip-cache /tmp/uv-cache

COPY . /opt/comfypod
RUN chmod +x /opt/comfypod/bootstrap.sh /opt/comfypod/install.sh /opt/comfypod/scripts/*.sh

# Curated custom nodes (config/nodes.txt, url[@ref]) + their python deps
RUN set -e; \
    grep -vE '^\s*(#|$)' /opt/comfypod/config/nodes.txt | while read -r spec; do \
        url="${spec%@*}"; ref=""; [ "$spec" != "$url" ] && ref="${spec##*@}"; \
        name="$(basename "$url" .git)"; \
        dir="/opt/ComfyUI/custom_nodes/$name"; \
        echo "== node: $name ${ref:+@$ref}"; \
        if [ -n "$ref" ]; then \
            git clone "$url" "$dir" && git -C "$dir" checkout "$ref"; \
        else \
            git clone --depth 1 "$url" "$dir"; \
        fi; \
        if [ -f "$dir/requirements.txt" ]; then \
            uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
                -r "$dir/requirements.txt"; \
        fi; \
    done \
    && uv cache clean && rm -rf /tmp/pip-cache /tmp/uv-cache

# Runtime extras: downloads, auth hashing, terminal.
RUN uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        hf_transfer "huggingface_hub[cli]" opencv-python-headless bcrypt \
        jupyterlab \
    && uv cache clean && rm -rf /tmp/pip-cache /tmp/uv-cache

# SageAttention 2 compiled here rather than in a background job on the pod:
# ~30% faster sampling, and the build cost is paid once in CI. Arch list is
# explicit because CI has no GPU to query. The nvcc check comes first: if the
# toolkit and torch disagree on the CUDA major, torch refuses to compile any
# extension, and this build would burn ~20 minutes to reach that conclusion.
# Either way there is a fallback to the v1 pip wheel, so a SageAttention
# regression can never break the image. Used per-workflow via the KJNodes
# "Patch Sage Attention" node — the global --use-sage-attention flag stays off
# (it produces black output on Wan/Qwen-family models).
RUN if /opt/comfypod-build/nvcc-check.sh "$VENV"; then \
        git clone --depth 1 https://github.com/thu-ml/SageAttention /tmp/sage \
        && cd /tmp/sage \
        && { TORCH_CUDA_ARCH_LIST="8.9;12.0" EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=8 \
             uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
                 --no-build-isolation . \
             && echo "SageAttention 2 built from source"; } \
        || { echo "WARN: SageAttention 2 build failed, falling back to the v1 wheel"; \
             uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
                 sageattention==1.0.6; }; \
    else \
        echo "WARN: skipping the SageAttention 2 source build, falling back to the v1 wheel"; \
        uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
            sageattention==1.0.6; \
    fi \
    && cd / && rm -rf /tmp/sage \
    && uv cache clean && rm -rf /tmp/pip-cache /tmp/uv-cache \
    && "$VENV/bin/python" -c "import sageattention; print('sageattention import OK')"

# Final gate: torch must still be usable after every node and extra has been
# installed. This is the downgrade trap the runtime also guards against — here
# it fails the CI build rather than a pod. Unlike the per-candidate check, a
# failure here is fatal: something actively broke a known-good install.
RUN "$VENV/bin/python" /opt/comfypod-build/verify-torch.py \
    || { echo "FAIL: a node or extra downgraded torch during the build"; \
         echo "Expected (frozen after torch install):"; cat /opt/constraints.txt; \
         echo "Actually installed now:"; \
         "$VENV/bin/pip" freeze | grep -iE '^(torch|torchvision|torchaudio)=='; \
         exit 1; }

# Tells the runtime scripts to skip everything that is already baked.
ENV COMFYPOD_BAKED=1

# Back to the base's runtime cache locations: on a pod /workspace is the
# network volume, so wheels pulled by a Manager install survive a pod swap.
ENV PIP_CACHE_DIR=/workspace/.cache/pip UV_CACHE_DIR=/workspace/.cache/uv

# ComfyPod boots in the background; the base image's /start.sh keeps SSH and
# the RunPod plumbing alive as PID 1. Output is teed so boot progress and
# failures are visible in the pod's container log, not just in a file.
CMD ["bash", "-c", "(/opt/comfypod/bootstrap.sh 2>&1 | tee -a /workspace/comfypod-boot.log &) ; exec /start.sh"]
