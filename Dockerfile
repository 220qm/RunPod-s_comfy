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

FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        aria2 ffmpeg rsync libgl1 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv (installer) and filebrowser (file manager) as system binaries
RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
    && curl -fsSL --retry 3 \
        https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
        | tar -xz -C /usr/local/bin filebrowser \
    && chmod +x /usr/local/bin/filebrowser

ENV VENV=/opt/comfypod-venv
ENV TORCH_INDEX=https://download.pytorch.org/whl/cu128

# Override to pin a specific combination without editing this file:
#   docker build --build-arg TORCH_CANDIDATES="torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1" .
ARG TORCH_CANDIDATES=""
ENV TORCH_CANDIDATES=${TORCH_CANDIDATES}

# Torch: install the newest candidate that is *verified usable* on every GPU
# we target, then freeze it into /opt/constraints.txt so the "no custom node
# may downgrade torch" guard reflects what is really installed. Each candidate
# is verified before it is accepted, so an unusable build makes the installer
# move to the next candidate instead of failing the whole image.
COPY docker/install-torch.sh docker/verify-torch.py /opt/comfypod-build/
RUN chmod +x /opt/comfypod-build/install-torch.sh \
    && uv venv --seed --python "$(command -v python3)" "$VENV" \
    && /opt/comfypod-build/install-torch.sh "$VENV" "$TORCH_INDEX" /opt/constraints.txt \
    && uv cache clean

# ComfyUI at the latest release tag. Krea 2 needs >= v0.26.0, and the version
# must be new enough to expose the System User Protection API — without it
# ComfyUI-Manager force-sets security_level=strong and every install is
# blocked no matter how it is configured.
RUN git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)" \
    && git describe --tags \
    && grep -q "def get_system_user_directory" folder_paths.py \
        || { echo "FAIL: ComfyUI lacks get_system_user_directory — Manager installs would be blocked"; exit 1; } \
    && uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        -r requirements.txt \
    && uv cache clean

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
    && uv cache clean

# Runtime extras: downloads, auth hashing, terminal.
RUN uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        hf_transfer "huggingface_hub[cli]" opencv-python-headless bcrypt \
        jupyterlab \
    && uv cache clean

# SageAttention 2 compiled here rather than in a background job on the pod:
# ~30% faster sampling, and the build cost is paid once in CI. Arch list is
# explicit because CI has no GPU to query. Falls back to the v1 pip wheel if
# the source build fails, so a SageAttention regression can never break the
# image. Used per-workflow via the KJNodes "Patch Sage Attention" node — the
# global --use-sage-attention flag stays off (black output on Wan/Qwen).
RUN git clone --depth 1 https://github.com/thu-ml/SageAttention /tmp/sage \
    && cd /tmp/sage \
    && { TORCH_CUDA_ARCH_LIST="8.9;12.0" EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=8 \
         uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
             --no-build-isolation . \
         && echo "SageAttention 2 built from source"; } \
    || { echo "WARN: SageAttention 2 build failed, falling back to the v1 wheel"; \
         uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
             sageattention==1.0.6; } \
    && cd / && rm -rf /tmp/sage && uv cache clean \
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

# ComfyPod boots in the background; the base image's /start.sh keeps SSH and
# the RunPod plumbing alive as PID 1. Output is teed so boot progress and
# failures are visible in the pod's container log, not just in a file.
CMD ["bash", "-c", "(/opt/comfypod/bootstrap.sh 2>&1 | tee -a /workspace/comfypod-boot.log &) ; exec /start.sh"]
