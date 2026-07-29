# ComfyPod baked image (optional — the curl|bash bootstrap on the official
# RunPod PyTorch image works without building anything).
#
#   docker build -t <you>/comfypod:latest .
#   docker push <you>/comfypod:latest
#
# The devel base ships nvcc (needed to compile SageAttention 2) and matches
# the torch cu128 wheels used in the persistent venv — Blackwell (5090) ready.
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        aria2 ffmpeg rsync libgl1 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY . /opt/comfypod
RUN chmod +x /opt/comfypod/bootstrap.sh /opt/comfypod/scripts/*.sh

# ComfyPod boots in the background; the base image's /start.sh keeps SSH and
# the RunPod plumbing alive as PID 1.
CMD ["bash", "-c", "(/opt/comfypod/bootstrap.sh >> /workspace/comfypod-boot.log 2>&1 &) ; exec /start.sh"]
