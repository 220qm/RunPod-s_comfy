# Creating the RunPod template

One-time setup, ~5 minutes. Afterwards every pod you spin up boots straight
into your fully configured, password-protected ComfyUI.

## 1. Create a network volume

RunPod Console → **Storage** → *New Network Volume*.

- Pick the **datacenter where the GPUs you want live** (check 4090/5090/RTX 4500
  availability first — the volume binds you to that datacenter).
- Size: **200 GB** recommended for the default presets
  (Krea 2 ≈ 18 GB, Wan 2.2 T2V+I2V ≈ 69 GB, venv/ComfyUI ≈ 15 GB, plus room
  for outputs and extra LoRAs). 100 GB works if you trim `DOWNLOAD_PRESETS`.

## 2. Store your secrets

RunPod Console → **Settings → Secrets**. Create:

| Secret name | Value |
|---|---|
| `WEB_PASSWORD` | your login password (or skip — one is generated and shown in the pod logs) |
| `HF_TOKEN` | HuggingFace token, `read` scope — [create here](https://huggingface.co/settings/tokens) |
| `CIVITAI_TOKEN` | Civitai API key — Civitai → Account Settings → API Keys |

Secrets never appear in the template or pod config in plaintext.

## 3. Create the template

RunPod Console → **Templates** → *New Template*:

| Field | Value |
|---|---|
| Type | Pod |
| Container Image | `runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04` |
| Container Start Command | see below |
| Container Disk | 30 GB |
| Volume Disk | your network volume, mount path `/workspace` |
| Expose HTTP Ports | `3000,3001,8080,8888` |
| Expose TCP Ports | `22` |

**Container Start Command** (public repo):

```bash
bash -c '(curl -fsSL https://raw.githubusercontent.com/220qm/RunPod-s_comfy/main/bootstrap.sh | bash) >> /workspace/comfypod-boot.log 2>&1 & exec /start.sh'
```

> **Using a branch other than `main`?** Swap the branch in the raw URL *and*
> add a `COMFYPOD_BRANCH` env var with the branch name so the on-volume clone
> tracks the same branch.

If this repo is **private**: add a `GITHUB_TOKEN` secret (fine-grained PAT,
read-only on this repo) and use:

```bash
bash -c '(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/220qm/RunPod-s_comfy/main/bootstrap.sh | bash) >> /workspace/comfypod-boot.log 2>&1 & exec /start.sh'
```

**Environment variables** for the template:

| Variable | Value |
|---|---|
| `WEB_PASSWORD` | `{{ RUNPOD_SECRET_WEB_PASSWORD }}` |
| `HF_TOKEN` | `{{ RUNPOD_SECRET_HF_TOKEN }}` |
| `CIVITAI_TOKEN` | `{{ RUNPOD_SECRET_CIVITAI_TOKEN }}` |
| `GITHUB_TOKEN` | `{{ RUNPOD_SECRET_GITHUB_TOKEN }}` (private repo only) |
| `DOWNLOAD_PRESETS` | `krea2,wan22-t2v,wan22-i2v,upscale` (optional, this is the default) |

Any variable from `.env.example` can be added the same way.

## 4. Deploy a pod

**Deploy** → pick a GPU → select your template + network volume → *Deploy*.

- **First boot**: ~5–8 min until ComfyUI is reachable (venv + nodes install),
  while ~85 GB of models download in the background (typically 10–20 min on
  datacenter bandwidth). Everything lands on the volume — **this happens once**.
- **Every later boot**: ComfyUI is up in ~30–60 s, models already in place.

Open the pod's **Logs** to see the connection info block (URLs + credentials),
or use **Connect** → the HTTP port buttons:

| Port | Service |
|---|---|
| 3000 | Dashboard (links to everything) |
| 3001 | **ComfyUI** (basic-auth login) |
| 8080 | FileBrowser (same username/password) |
| 8888 | JupyterLab (token = your password) |

## GPU notes

| GPU | VRAM | Fit |
|---|---|---|
| RTX 5090 | 32 GB | Best choice. Blackwell needs CUDA 12.8 builds — already handled (torch cu128). Krea 2 fp8 and Wan 2.2 fp8 run fully in VRAM. |
| RTX 4090 | 24 GB | Excellent. Wan 2.2 14B fp8 uses ComfyUI's automatic offloading for the dual experts — pick a pod with ≥ 60 GB system RAM. |
| RTX 4500 Ada | 24 GB | Same VRAM as 4090, ~40% less raw compute — cheaper, slower, works fine. |

## Optional: baked Docker image

The bootstrap adds ~1 min to a cold container. To shave that off, build and
push the included `Dockerfile` and set it as the template's Container Image
(keep the same env/ports; the start command is baked in, leave it empty).
