# Setting up ComfyPod on RunPod

One-time setup. Afterwards deploying a pod is: pick GPU → pick template →
Deploy. Nothing to type, nothing to fetch at boot.

## 0. Pick the region FIRST

The network volume is **region-pinned** — pods must run in the same region,
and this cannot be changed later. Before creating anything, check GPU
availability (Deploy page) in the candidate regions for the GPUs you want
(4090 / 5090 / RTX PRO 4500):

- **EU regions (NL/FR/NO)**: lower latency from Germany, generated data stays
  in the EU.
- **US regions**: often better 5090 availability and pricing.

## 1. Create the network volume

RunPod Console → **Storage** → *New Network Volume*, in the region you chose.

- **Size: 300 GB recommended** (~$21/month at $0.07/GB-month). The default
  presets are ~105 GB, ComfyUI + caches ~10 GB, and LoRA collecting plus
  video outputs add up fast. 150 GB works if you trim `DOWNLOAD_PRESETS`.
- Enable **encryption** if offered — the volume holds your tokens and outputs.
- Standard storage tier is fine; upgrade to high-performance only if model
  load times actually bother you.

## 2. Build the image (one-time, one click)

Everything — torch, ComfyUI, custom nodes, tools — is baked into a Docker
image by GitHub Actions, so pods never install anything at boot.

1. GitHub repo → **Actions** tab → **build-image** → *Run workflow* → `main`.
   (It also rebuilds automatically whenever `main` changes.) First build
   takes ~30–45 min.
2. After it finishes, make the image pullable by RunPod: repo main page →
   **Packages** (right sidebar) → **comfypod** → *Package settings* →
   **Change visibility → Public**. The image contains no secrets and no
   weights, so public is safe. (Alternative: keep it private and add GHCR
   credentials under RunPod → Settings → Container Registry Auth.)

## 3. Store your secrets

RunPod Console → **Settings → Secrets**. Create:

| Secret name | Value |
|---|---|
| `WEB_PASSWORD` | your login password (or skip — one is generated on first boot and shown once in the pod logs) |
| `HF_TOKEN` | HuggingFace token, `read` scope — [create here](https://huggingface.co/settings/tokens) |
| `CIVITAI_TOKEN` | Civitai API key — Civitai → Account Settings → API Keys |

These seed the pod **once**: on first boot they are written to
`/workspace/.comfypod/secrets.env` (0600) on your volume, the canonical store
from then on. Rotate anytime with `comfypod-secrets`.

## 4. Create the template

RunPod Console → **Templates** → *New Template*:

| Field | Value |
|---|---|
| Type | Pod |
| Container Image | `ghcr.io/220qm/comfypod:latest` |
| Container Start Command | **leave empty** (baked into the image) |
| Container Disk | 50 GB |
| Volume | your network volume, mount path `/workspace` |
| Expose HTTP Ports | `8188,8080,8888` |
| Expose TCP Ports | `22` |

**Environment variables:**

| Variable | Value |
|---|---|
| `WEB_PASSWORD` | `{{ RUNPOD_SECRET_WEB_PASSWORD }}` |
| `HF_TOKEN` | `{{ RUNPOD_SECRET_HF_TOKEN }}` |
| `CIVITAI_TOKEN` | `{{ RUNPOD_SECRET_CIVITAI_TOKEN }}` |
| `DOWNLOAD_PRESETS` | `krea2,wan22-5b,wan22-t2v,wan22-i2v,upscale` (optional, this is the default) |

Any variable from `.env.example` can be added the same way (e.g.
`IDLE_TIMEOUT_MINUTES`, `ADMIN_LOCAL_ONLY`).

## 5. Deploy

**Deploy** → pick a GPU → select your template + network volume → *Deploy*.
That's the whole routine, every time.

- The container log shows `[comfypod]` lines within seconds of the container
  starting — if they're missing, the image/template isn't applied.
- **First boot ever**: ComfyUI is copied to the volume (~2 min) and ~105 GB
  of models download in the background (15–30 min on datacenter bandwidth) —
  the UI is usable while they download. **This happens once per volume.**
- **Every later boot**: services up in well under a minute; models in place.

Connection info (URLs + credentials) prints at the end of the boot log. Ports:

| Port | Service | Login |
|---|---|---|
| 8188 | **ComfyUI** | password (ComfyUI-Login page) |
| 8080 | FileBrowser | username + password |
| 8888 | JupyterLab | token = password |
| 22 | SSH | your RunPod key |

Run `comfypod-doctor` in any pod terminal to health-check the whole stack.

## Fallback: no baked image

The stack also runs on the stock `runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04`
image (first boot then installs torch etc., ~10 min slower):

1. Deploy a pod from the stock image with the same volume/ports/env, leaving
   the start command empty. In a pod terminal:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/220qm/RunPod-s_comfy/main/install.sh | bash
   ```
   (private repo: `export GITHUB_TOKEN=ghp_...` first, and add
   `-H "Authorization: Bearer $GITHUB_TOKEN"` to the curl)
2. Set the template's start command to the line the installer prints:
   `bash /workspace/.comfypod/repo/scripts/pod-entry.sh`

## Cost notes (list prices, July 2026 — verify on the pricing page)

- Volume: $0.07/GB-month → 300 GB ≈ **$21/month** standing cost, GPU off.
- GPU (Secure Cloud): 4090 ≈ $0.69/hr · 5090 ≈ $0.99/hr.
- **Idle auto-stop is on by default** (30 min with no job, no open UI tab and
  no download → pod stops; volume persists). Tune with
  `IDLE_TIMEOUT_MINUTES`, disable with `0`. Needs `runpodctl` and a
  `RUNPOD_API_KEY` on the pod.

## GPU notes

| GPU | VRAM | Fit |
|---|---|---|
| RTX 5090 | 32 GB | Best choice. Blackwell (sm_120) needs CUDA 12.8 builds — baked in (torch cu128, pinned and guarded). Krea 2 fp8 and Wan 2.2 fp8 run fully in VRAM. |
| RTX 4090 | 24 GB | Excellent. Wan 2.2 14B fp8 leans on ComfyUI's automatic offloading for the dual experts — pick a pod with ≥ 60 GB system RAM. |
| RTX PRO 4500 | 32 GB (Blackwell) | Same sm_120 handling as the 5090; less raw compute, cheaper, works fine. |

## Large uploads

The RunPod HTTP proxy closes connections after ~100 s. FileBrowser uploads
are chunked and survive this, but for multi-GB inputs prefer SSH/SFTP
(`scp big.mp4 root@<pod>:/workspace/ComfyUI/input/`) or fetch server-side by
URL (`comfy-dl url <url> input`).
