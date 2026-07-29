# ComfyPod — private, persistent ComfyUI on RunPod

One template, one boot script. Spin up any GPU pod and get a **password-protected
ComfyUI** with **Krea 2** (image) and **Wan 2.2** (video) pre-provisioned, plus a
file manager, JupyterLab, and a token-aware model downloader — everything stored
on your **network volume**, so models, nodes, settings and Python packages are
downloaded **once** and every later pod boots in under a minute.

## What you get

| | |
|---|---|
| 🎨 **Models** | Krea 2 Turbo (fp8), Wan 2.2 T2V + I2V 14B (fp8) with Lightning 4-step LoRAs, upscalers — the best open-weights quality that fits 24–32 GB GPUs |
| 🔒 **Private by default** | ComfyUI sits behind a Caddy basic-auth proxy (bcrypt); ComfyUI itself binds to localhost only. FileBrowser has its own login, Jupyter is token-protected. No service is ever exposed without a password. |
| 🔑 **API keys** | `HF_TOKEN` and `CIVITAI_TOKEN` are injected automatically into every download (gated HF repos, Civitai) — via RunPod Secrets, never stored in the template |
| 💾 **Persistent** | venv, ComfyUI, custom nodes, models, outputs, credentials — all on `/workspace` |
| 🧩 **Node/model manager** | ComfyUI-Manager UI + 9 curated nodes (VideoHelperSuite, KJNodes, WanVideoWrapper, GGUF, rgthree, Crystools, …) |
| 📁 **Filesystem access** | FileBrowser (upload/download anything) + JupyterLab (terminal, pip installs) + SSH |
| ⚡ **Speed** | torch 2.8 cu128 (5090/Blackwell-ready), SageAttention (v2 compiled in background), fp8 weights, aria2 16-connection downloads, fast reboots |

## Quickstart

1. **Create a network volume + template** — follow
   [docs/RUNPOD_TEMPLATE.md](docs/RUNPOD_TEMPLATE.md) (one-time, ~5 min).
2. **Deploy a pod** with that template (5090 / 4090 / RTX 4500).
3. Open the pod **logs** — a connection block prints your URLs and password.
   First boot provisions everything; later boots take ~30–60 s.

| Port | Service | Login |
|---|---|---|
| 3001 | **ComfyUI** | username + password (browser prompt) |
| 3000 | Dashboard — links to all services | same |
| 8080 | FileBrowser — full `/workspace` | same |
| 8888 | JupyterLab — terminal, notebooks | token = password |
| 22 | SSH | RunPod key |

Password: set `WEB_PASSWORD` (RunPod Secret), or let ComfyPod generate one —
it's printed in the boot log and saved to `/workspace/.comfypod/credentials.txt`.

## Generating

Workflows: **ComfyUI → menu → Browse Templates** ships current, known-good
graphs for exactly these models — *Krea 2*, *Wan 2.2 T2V*, *Wan 2.2 I2V*.

- **Krea 2 Turbo**: 8 steps, cfg 1.0. Photorealistic aesthetics; fp8 uses
  ~12.5 GB VRAM.
- **Wan 2.2 T2V/I2V**: the Lightning LoRAs (pre-wired in the templates) give
  4-step generation — a 5 s 720p clip in well under a minute on a 5090.
  Disable them and raise steps (~20) for maximum motion fidelity.
- Typical pipeline: generate stills with Krea 2 → animate the keepers with
  Wan 2.2 I2V → RIFE frame interpolation (installed) for extra smoothness.

## Getting more models

Four ways, all token-aware:

1. **ComfyUI-Manager** → *Model Manager* — point-and-click from the UI.
2. **Presets**: `comfy-dl preset krea2-raw` (see `comfy-dl list`):
   `krea2` ~18 GB · `krea2-raw` ~18 GB · `wan22-t2v` ~38 GB · `wan22-i2v` ~38 GB
   · `wan22-5b` ~18 GB · `upscale` ~0.2 GB
3. **Any URL**: `comfy-dl url <huggingface-or-civitai-url> [folder]`, e.g.
   `comfy-dl url https://civitai.com/api/download/models/123456 loras`
   (or `comfy-dl civitai 123456 loras`).
4. **Upload** via FileBrowser into `ComfyUI/models/<folder>`.

Add permanent presets by dropping a `.txt` into `config/presets/`
(format: `folder|filename|url`).

## Configuration

Set via RunPod template env vars (secrets for tokens!) or persist them in
`/workspace/.comfypod/env` (see [.env.example](.env.example)):

| Variable | Default | Purpose |
|---|---|---|
| `WEB_USER` / `WEB_PASSWORD` | `admin` / auto-generated | login for all services |
| `HF_TOKEN` / `CIVITAI_TOKEN` | — | download auth (HF Bearer header / Civitai `?token=`) |
| `DOWNLOAD_PRESETS` | `krea2,wan22-t2v,wan22-i2v,upscale` | models fetched on boot (`all`/`none` work) |
| `EXTRA_NODES` | — | comma-separated git URLs, installed on boot |
| `COMFYUI_FLAGS` | — | extra ComfyUI args (e.g. `--fast`) |
| `AUTO_UPDATE` | `false` | stability first: versions stay pinned until you run `comfypod-update` |
| `SAGE_ATTENTION` | `auto` | `auto` / `1` / `off` |
| `ENABLE_JUPYTER` | `true` | JupyterLab on 8888 |

CLI helpers (available in any pod shell): `comfy-dl`, `comfypod-update`,
`comfypod-stop`.

## Security model

- RunPod proxy URLs are public — so **every** HTTP service here requires auth:
  Caddy basic-auth (bcrypt-hashed, never stored in plaintext config) in front
  of ComfyUI and the dashboard; FileBrowser's own account system; Jupyter token.
- ComfyUI listens on `127.0.0.1` only. If the auth proxy ever fails to start,
  nothing is exposed (fail closed) — you'd still have SSH.
- Tokens live in RunPod **Secrets**, referenced as `{{ RUNPOD_SECRET_… }}`;
  the generated credentials file on the volume is `chmod 600`.
- Nothing here phones home; models come from HuggingFace/Civitai/GitHub only.

## Layout on the volume

```
/workspace/
├── ComfyUI/                  # app, custom_nodes, models/, output/
└── .comfypod/
    ├── repo/                 # this repository (self-updating entry point)
    ├── venv/                 # persistent Python env (torch cu128)
    ├── bin/                  # caddy, filebrowser
    ├── logs/                 # comfyui.log, downloads.log, sage2-build.log …
    ├── credentials.txt       # your login (chmod 600)
    └── env                   # optional persistent settings
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Which URL/password?" | Pod logs → connection block, or `cat /workspace/.comfypod/credentials.txt` |
| ComfyUI 502 right after boot | It's still starting — `tail -f /workspace/.comfypod/logs/comfyui.log` |
| Model missing in a workflow | Downloads may still be running: `tail -f /workspace/.comfypod/logs/downloads.log`; then refresh the browser (R) |
| Gated model 401/403 | Set `HF_TOKEN` / `CIVITAI_TOKEN` secret and accept the model license on the HF page once |
| Update wanted | `comfypod-update` (repo + ComfyUI + nodes, then restarts) |
| Wonky state after experiments | `rm -rf /workspace/.comfypod/venv` → next boot rebuilds the env; models stay |

## Why these models?

- **Krea 2 Turbo (fp8_scaled)** — Krea's open-weights 12.9B DiT (June 2026),
  top-10 on the Artificial Analysis T2I leaderboard; Turbo is the 8-step
  distilled variant, ideal for interactive use. RAW is one preset away for
  fine-tuning looks. (Krea's realtime *video* model has no ComfyUI support
  yet — video is Wan's job here.)
- **Wan 2.2 A14B (fp8_scaled)** — still the strongest open-weights video model
  family (Wan 2.5+ remains API-only). fp8_scaled beats GGUF on quality at this
  VRAM class, and the Lightning LoRAs make 4-step generation practical.
- **fp8 over GGUF** on 24–32 GB: higher fidelity, no dequant overhead; the GGUF
  loader node is installed anyway for experiments with bigger quants.
