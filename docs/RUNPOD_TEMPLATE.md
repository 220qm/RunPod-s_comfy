# Creating the RunPod template

One-time setup, ~10 minutes. Afterwards every pod you spin up boots straight
into your fully configured, password-protected ComfyUI.

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
  presets are ~105 GB, the Python lockfile/caches ~15 GB, and LoRA collecting
  plus video outputs add up fast. 150 GB is a workable minimum if you trim
  `DOWNLOAD_PRESETS`.
- Enable **encryption** if offered — the volume holds your tokens and outputs.
- Standard storage tier is fine to start; upgrade to the high-performance
  tier only if model load times actually bother you.

## 2. Store your secrets

RunPod Console → **Settings → Secrets**. Create:

| Secret name | Value |
|---|---|
| `WEB_PASSWORD` | your login password (or skip — one is generated on first boot and shown once in the pod logs) |
| `HF_TOKEN` | HuggingFace token, `read` scope — [create here](https://huggingface.co/settings/tokens) |
| `CIVITAI_TOKEN` | Civitai API key — Civitai → Account Settings → API Keys |

These seed the pod **once**: on first boot they are written to
`/workspace/.comfypod/secrets.env` (mode 0600) on your volume, which is the
canonical store from then on. You can remove the template env vars after the
first boot if you want; rotate credentials anytime with `comfypod-secrets`.
Avoid pasting tokens as plain-text env values — use the
`{{ RUNPOD_SECRET_… }}` references, which are masked in the console.

## 3. Create the template

RunPod Console → **Templates** → *New Template*:

| Field | Value |
|---|---|
| Type | Pod |
| Container Image | `runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04` |
| Container Start Command | see below |
| Container Disk | 50 GB (the Python env is rebuilt here each boot) |
| Volume | your network volume, mount path `/workspace` |
| Expose HTTP Ports | `8188,8080,8888` |
| Expose TCP Ports | `22` |

**Container Start Command** (public repo):

```bash
bash -c 'B="${COMFYPOD_BRANCH:-main}"; (echo "[comfypod] fetching bootstrap from branch $B"; curl -fsSL "https://raw.githubusercontent.com/220qm/RunPod-s_comfy/$B/bootstrap.sh" -o /tmp/comfypod-bootstrap.sh && bash /tmp/comfypod-bootstrap.sh || echo "[comfypod] !!! BOOTSTRAP FAILED to download or run. Check: branch $B exists on GitHub; repo is public (private needs GITHUB_TOKEN); network reachable.") 2>&1 | tee -a /workspace/comfypod-boot.log & exec /start.sh'
```

Progress and errors appear **in the pod's container log** (and are also saved
to `/workspace/comfypod-boot.log`). If you see no `[comfypod]` lines at all,
the start command itself was never applied — re-check the template field.

> **Branch:** the command uses the `COMFYPOD_BRANCH` env var (default `main`).
> Until the ComfyPod PR is merged into `main`, set
> `COMFYPOD_BRANCH=claude/comfyui-runpod-setup-xpr6x1` in the template's
> environment variables — otherwise the fetch 404s and nothing installs.

If this repo is **private**: add a `GITHUB_TOKEN` secret (fine-grained PAT,
read-only on this repo) and use:

```bash
bash -c 'B="${COMFYPOD_BRANCH:-main}"; (echo "[comfypod] fetching bootstrap from branch $B"; curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "https://raw.githubusercontent.com/220qm/RunPod-s_comfy/$B/bootstrap.sh" -o /tmp/comfypod-bootstrap.sh && bash /tmp/comfypod-bootstrap.sh || echo "[comfypod] !!! BOOTSTRAP FAILED — is GITHUB_TOKEN set and valid for this repo?") 2>&1 | tee -a /workspace/comfypod-boot.log & exec /start.sh'
```

**Environment variables** for the template:

| Variable | Value |
|---|---|
| `WEB_PASSWORD` | `{{ RUNPOD_SECRET_WEB_PASSWORD }}` |
| `HF_TOKEN` | `{{ RUNPOD_SECRET_HF_TOKEN }}` |
| `CIVITAI_TOKEN` | `{{ RUNPOD_SECRET_CIVITAI_TOKEN }}` |
| `GITHUB_TOKEN` | `{{ RUNPOD_SECRET_GITHUB_TOKEN }}` (private repo only) |
| `COMFYPOD_BRANCH` | `claude/comfyui-runpod-setup-xpr6x1` (until the PR is merged; omit once it's on `main`) |
| `DOWNLOAD_PRESETS` | `krea2,wan22-5b,wan22-t2v,wan22-i2v,upscale` (optional, this is the default) |

Any variable from `.env.example` can be added the same way (e.g.
`IDLE_TIMEOUT_MINUTES`, `ADMIN_LOCAL_ONLY`).

## 4. Deploy a pod

**Deploy** → pick a GPU → select your template + network volume → *Deploy*.

- **First boot**: ~5–8 min until ComfyUI is reachable (env build + nodes),
  while ~105 GB of models download in the background (typically 15–30 min on
  datacenter bandwidth). Everything lands on the volume — **this happens once**.
- **Every later boot**: the Python env is restored from the lockfile via the
  volume cache (~1 min); models are already in place.

Open the pod's **Logs** for the connection block (URLs + credentials), or use
**Connect** → the port buttons:

| Port | Service | Login |
|---|---|---|
| 8188 | **ComfyUI** | password (ComfyUI-Login page) |
| 8080 | FileBrowser | username + password |
| 8888 | JupyterLab | token = password |
| 22 | SSH | your RunPod key |

Run `comfypod-doctor` in any pod shell to health-check the whole stack.

## Cost notes (list prices, July 2026 — verify on the pricing page)

- Volume: $0.07/GB-month → 300 GB ≈ **$21/month** standing cost, GPU off.
- GPU (Secure Cloud): 4090 ≈ $0.69/hr · 5090 ≈ $0.99/hr.
- **Idle auto-stop is on by default** (30 min with no job, no open UI tab and
  no download → pod stops; volume persists). Tune with
  `IDLE_TIMEOUT_MINUTES`, disable with `0`. It needs `runpodctl` and a
  `RUNPOD_API_KEY` on the pod (present on official images; otherwise add a
  pod-scoped API key as a secret).

## GPU notes

| GPU | VRAM | Fit |
|---|---|---|
| RTX 5090 | 32 GB | Best choice. Blackwell (sm_120) needs CUDA 12.8 builds — handled (torch cu128, pinned and guarded). Krea 2 fp8 and Wan 2.2 fp8 run fully in VRAM. |
| RTX 4090 | 24 GB | Excellent. Wan 2.2 14B fp8 leans on ComfyUI's automatic offloading for the dual experts — pick a pod with ≥ 60 GB system RAM. |
| RTX PRO 4500 | 32 GB (Blackwell) | Same sm_120 handling as the 5090; less raw compute, cheaper, works fine. |

## Large uploads

The RunPod HTTP proxy closes connections after ~100 s. FileBrowser uploads
are chunked and survive this, but for multi-GB inputs prefer SSH/SFTP
(`scp big.mp4 root@<pod>:/workspace/ComfyUI/input/`) or fetch server-side by
URL (`comfy-dl url <url> input`).

## Optional: baked Docker image

The bootstrap adds ~1 min to a cold container. To shave that off, build and
push the included `Dockerfile` and set it as the template's Container Image
(keep the same env/ports; the start command is baked in, leave it empty).
The image contains no weights and no secrets, so it's safe to push publicly.
