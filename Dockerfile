# ComfyPod baked image — the one-click deployment path.
#
# Everything that used to happen at pod boot (torch download, venv build,
# ComfyUI clone, node installs, binary downloads) happens HERE, once, in CI.
# A pod booting from this image only seeds the volume and starts services —
# there is no network fetch on the critical path, so the whole class of
# "silent boot failure" disappears.
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

# The torch pin every install in this image must obey (same trap-protection
# the runtime applies via PIP_CONSTRAINT on the volume).
RUN printf 'torch==2.8.0\ntorchvision==0.23.0\ntorchaudio==2.8.0\n' > /opt/constraints.txt

ENV VENV=/opt/comfypod-venv
RUN uv venv --seed --python "$(command -v python3)" "$VENV" \
    && uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 \
        --index-url https://download.pytorch.org/whl/cu128 \
    && uv cache clean

# ComfyUI at the latest release tag (>= v0.26.0 needed for Krea 2)
RUN git clone https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)" \
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

# Runtime extras: downloads, auth hashing, terminal, SageAttention v1
# (v1 is the pip wheel used by the KJNodes "Patch Sage Attention" node)
RUN uv pip install --python "$VENV/bin/python" --constraint /opt/constraints.txt \
        hf_transfer "huggingface_hub[cli]" opencv-python-headless bcrypt \
        jupyterlab sageattention==1.0.6 \
    && uv cache clean

# Tells the runtime scripts to skip everything that is already baked.
ENV COMFYPOD_BAKED=1

# ComfyPod boots in the background; the base image's /start.sh keeps SSH and
# the RunPod plumbing alive as PID 1. Output is teed so boot progress and
# failures are visible in the pod's container log, not just in a file.
CMD ["bash", "-c", "(/opt/comfypod/bootstrap.sh 2>&1 | tee -a /workspace/comfypod-boot.log &) ; exec /start.sh"]
