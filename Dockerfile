# ComfyPod baked image (optional — the curl|bash bootstrap on the official
# RunPod PyTorch image works without building anything).
#
#   docker build -t <you>/comfypod:latest .
#   docker push <you>/comfypod:latest
#
# The devel base ships nvcc (needed to compile SageAttention 2) and matches
# the torch cu128 pin used in the venv — Blackwell (5090 / RTX PRO 4500)
# ready. No weights, no secrets in the image — ever.
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        aria2 ffmpeg rsync libgl1 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv baked in shaves the download off first boot; the bootstrap still installs
# it to the volume when running on a stock image.
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

COPY . /opt/comfypod
RUN chmod +x /opt/comfypod/bootstrap.sh /opt/comfypod/scripts/*.sh

# ComfyPod boots in the background; the base image's /start.sh keeps SSH and
# the RunPod plumbing alive as PID 1. Output is teed so boot progress and
# failures are visible in the pod's container log, not just in a file.
CMD ["bash", "-c", "(/opt/comfypod/bootstrap.sh 2>&1 | tee -a /workspace/comfypod-boot.log &) ; exec /start.sh"]
