# ComfyPod — private, persistent ComfyUI on RunPod

One template, one boot script. Spin up any GPU pod and get a **password-protected
ComfyUI** with **Krea 2** (image) and **MiniMax H3** (video + native audio) pre-provisioned, plus a
file manager, JupyterLab, a token-aware model downloader and a health-check
doctor — everything durable stored on your **network volume**, so models,
nodes, settings and credentials are set up **once** and every later pod is
generating again in a couple of minutes.

## What you get

| | |
|---|---|
| 🎨 **Models** | Krea 2 Turbo (fp8) for images, MiniMax H3 FL2VA (fp8) for text-to-video **and** image-to-video with native audio, upscalers |
| 🔒 **Private by default** | ComfyUI behind **ComfyUI-Login** (cookie/session auth that also guards the API and survives the WebSocket handshake, unlike basic auth). An auth-guard verifies the login page actually intercepts before ComfyUI stays on a public bind — otherwise it's forced back to localhost (fail closed). FileBrowser has its own login; Jupyter is token-protected. |
| 🔑 **API keys** | HF/Civitai tokens sent as `Authorization: Bearer` headers from 0600 files — never in URLs, process listings or logs (all logging is secret-redacted) |
| 💾 **Persistent** | Models, nodes, workflows, outputs, credentials, package lockfile and caches on `/workspace`; the Python env rebuilds on fast container disk each boot via **uv** (~1 min warm) |
| 🛡️ **Stable** | torch pinned via constraints on **every** install path — no custom node can silently downgrade torch and brick a 5090 (sm_120). The image build *verifies* each candidate: `sm_120`/`sm_89` kernel coverage, torchvision and torchaudio actually importing against it, and an nvcc whose CUDA major matches — rejecting the combination in CI instead of on your pod. Versions stay pinned until `comfypod-update`; `comfypod-snapshot restore baseline` undoes a broken update. |
| ⚡ **Tuned** | **CUDA 13** torch — the only build where MiniMax H3's NVFP4/INT8 weights hit the hardware path instead of an emulated one (roughly 3× on reported timings). SageAttention 2 compiled into the image against a matching nvcc, `--fast fp16_accumulation` on by default, `expandable_segments` to survive the text-encoder/diffusion offload churn. Needs driver ≥ 580; older hosts are detected at boot, not left to fail. |
| 🧩 **Managers** | ComfyUI-Manager (nodes) + ComfyUI-Model-Manager (in-UI model browser with HF/Civitai tokens) + 7 more curated nodes |
| 📁 **Filesystem** | FileBrowser (upload/download anything) + JupyterLab (terminal, pip) + SSH; `ADMIN_LOCAL_ONLY=true` locks both behind an SSH tunnel |
| 💸 **Cost-aware** | Idle auto-stop (default 30 min: no job, no open tab, no download → pod stops, volume persists) |

## Quickstart

Everything is **baked into a Docker image** built by GitHub Actions
(`ghcr.io/220qm/comfypod:latest`) — pods install nothing at boot, so there is
nothing on the critical path left to fail.

1. **One-time** — follow [docs/RUNPOD_TEMPLATE.md](docs/RUNPOD_TEMPLATE.md):
   pick region → create volume → click *Run workflow* on the **build-image**
   Action (then set the package public) → add secrets → create the template
   pointing at the image, start command empty.
2. **Every time after that**: Deploy → pick GPU → pick template → done.
3. Open the pod **logs** — a connection block prints your URLs (password
   shown once only if it was auto-generated). The very first boot copies
   ComfyUI to the volume (~2 min) and downloads ~56 GB of models in the
   background; every later boot is up in well under a minute.

(No baked image handy? The stack also runs on the stock RunPod PyTorch image
via a one-time `install.sh` — see the fallback section in the template docs.)

| Port | Service | Login |
|---|---|---|
| 8188 | **ComfyUI** | password (login page) |
| 8080 | FileBrowser — full `/workspace` | username + password |
| 8888 | JupyterLab — terminal, notebooks | token = password |
| 22 | SSH | RunPod key |

CLI helpers in any pod shell: `comfy-dl`, `comfypod-node`, `comfypod-doctor`,
`comfypod-secrets`, `comfypod-snapshot`, `comfypod-update`, `comfypod-stop`.

## Installing custom nodes

Two paths, both persistent:

- **ComfyUI-Manager UI** — works out of the box. Because RunPod's proxy forces
  ComfyUI to bind `0.0.0.0`, Manager considers the session "not local" and by
  default refuses unlisted/git-URL installs, so ComfyPod sets
  `security_level = weak` plus `allow_git_url_install` / `allow_pip_install`
  in Manager's own config. That deliberately trades Manager's guard-rail for a
  working install button — everything is still behind the login password. Set
  `MANAGER_SECURITY_LEVEL=normal` for registry-only installs.
- **`comfypod-node add <git-url>`** — a path that never depends on the UI, and
  unlike Manager it *records* the node in `/workspace/.comfypod/extra-nodes.txt`
  so future pods reinstall it automatically. Also `list`, `remove`, `fix`.

Every boot re-asserts the Python dependencies of **every** node on the volume
(including ones added through Manager). That matters because the venv ships
inside the image and is therefore ephemeral — without it, a Manager-installed
node would come back next pod with its dependencies missing.

## Generating

Use ComfyUI's built-in **Browse Templates** — official, tested graphs for
exactly these models. [workflows/README.md](workflows/README.md) maps each
model preset to its template and lists the gotchas (first/last-frame wiring,
the offload pause, Blackwell-vs-Ada quantisation, per-workflow SageAttention).

- **Krea 2 Turbo**: ~8 steps, CFG 1. ~12.5 GB VRAM in fp8.
  License: Krea 2 Community License (free commercial use under 50 seats — not
  Apache/MIT).
- **MiniMax H3 (FL2VA)**: one checkpoint covers both modes — prompt only for
  text-to-video, or drive `first_frame` / `last_frame` on the
  **MiniMaxH3ImageToVideo** node for image-to-video. It generates **native
  audio** alongside the video, which is why the preset pulls two VAEs.
- **VRAM reality check**: the fp8 diffusion model (~21 GB) plus the Qwen3-VL-32B
  text encoder does not fit in 32 GB at once, so ComfyUI offloads between the
  two. Expect a pause the first time a prompt is encoded. On a 4090/Ada use the
  `minimax-h3-ada` preset — NVFP4 is Blackwell-only.

## Getting more models

All token-aware, tokens injected automatically:

1. **ComfyUI-Model-Manager** — browse/download HF & Civitai from inside the UI.
2. **Presets**: `comfy-dl preset minimax-h3-ref` (see `comfy-dl list`):
   `krea2` ~18 GB · `krea2-raw` ~18 GB · `minimax-h3` ~38 GB ·
   `minimax-h3-ref` ~21 GB · `minimax-h3-ada` ~55 GB · `upscale` ~0.2 GB
3. **Any URL**: `comfy-dl url <huggingface-or-civitai-url> [folder]`, or
   `comfy-dl civitai <version-id> [folder]`.
4. **Upload** via FileBrowser into `ComfyUI/models/<folder>` (multi-GB files:
   prefer SFTP — the RunPod proxy caps connections at ~100 s; FileBrowser's
   chunked uploads survive it, single big PUTs don't).

Verify integrity anytime: `comfy-dl verify` (flags incomplete/corrupt files).
Add permanent presets as `config/presets/*.txt`
(format: `folder|filename|url[|sha256]`).

## Configuration

Non-secret knobs via template env vars or `/workspace/.comfypod/env`
(see [.env.example](.env.example)); secrets via `comfypod-secrets` or RunPod
Secrets (seeded to the volume on first boot):

| Variable | Default | Purpose |
|---|---|---|
| `WEB_USER` / `WEB_PASSWORD` | `admin` / auto-generated | login for all services |
| `HF_TOKEN` / `CIVITAI_TOKEN` | — | download auth (Bearer headers) |
| `DOWNLOAD_PRESETS` | `krea2,minimax-h3,upscale` | models fetched on boot (`all`/`none`) |
| `IDLE_TIMEOUT_MINUTES` | `30` | auto-stop after fully idle minutes (`0` = never) |
| `ADMIN_LOCAL_ONLY` | `false` | `true` = FileBrowser/Jupyter only via SSH tunnel |
| `SAGE_ATTENTION` | `auto` | installed for per-workflow patching; `global` opts into the risky launch flag; `off` |
| `FAST_MODE` | `fp16_accumulation` | ComfyUI `--fast` optimizations; `all` for every one (riskier), `off` for stock |
| `MANAGER_SECURITY_LEVEL` | `weak` | what ComfyUI-Manager may install (see below); `normal` = registry nodes only |
| `VENV_LOCATION` | `container` | `volume` = persist the venv instead of rebuilding |
| `EXTRA_NODES` | — | comma-separated git URLs (`url@commit` to pin) |
| `COMFYUI_FLAGS` | — | extra ComfyUI args (`--fast`, `--highvram`, …) |
| `AUTO_UPDATE` | `false` | stay pinned until `comfypod-update` |
| `ENABLE_JUPYTER` | `true` | JupyterLab on 8888 |

## Security model

- RunPod proxy URLs are **public** — every exposed port requires credentials:
  ComfyUI-Login (bcrypt; cookie for the UI, bearer token for the API),
  FileBrowser accounts, Jupyter token.
- **Fail closed, twice**: ComfyUI binds publicly only when ComfyUI-Login is
  installed, and the auth-guard then verifies the login page really
  intercepts — if not, ComfyUI is forced back to `127.0.0.1` (SSH tunnel).
- **No token ever rides in a URL, argv or log.** Auth headers come from 0600
  temp files; the log helpers redact all known secret values.
- Secrets live in `/workspace/.comfypod/secrets.env` (0600), seeded once from
  RunPod Secrets; rotate with `comfypod-secrets set-password` /
  `set-hf-token` / `set-civitai-token`.
- Torch pin enforced globally via `PIP_CONSTRAINT` — covers ComfyUI-Manager's
  installs too. Note: Manager can install arbitrary code by design; stick to
  known nodes, and `comfypod-snapshot restore baseline` if one misbehaves.
- Recommended: encrypted network volume (see template docs). Nothing here
  phones home.

## Layout on the volume

```
/workspace/
├── ComfyUI/                  # app, custom_nodes, models/, output/, user/
│   └── login/PASSWORD        # bcrypt hash for ComfyUI-Login (seeded)
└── .comfypod/
    ├── repo/                 # this repository
    ├── secrets.env           # tokens + password (0600) — canonical store
    ├── constraints.txt       # the torch pin every installer must obey
    ├── requirements.lock     # full Python env, restored each boot via uv
    ├── nodes.lock            # exact commit of every custom node
    ├── extra-nodes.txt       # git remotes of nodes you added, re-cloned each pod
    ├── node-archives/        # one tar per registry-installed node (no git remote)
    ├── snapshots/            # rollback points (baseline + pre-update-*)
    ├── cache/                # uv wheel cache + HF cache
    └── logs/                 # comfyui.log, downloads.log, auth-guard.log …
```

The Python env lives on **container disk** (`/opt/comfypod-venv`) — network
volumes are fast at streaming 14 GB weights and slow at the thousands of
small reads Python imports need. With the baked image it ships pre-built and
costs zero boot time; on the stock-image fallback it's rebuilt each boot from
the lockfile via uv (~1 min warm; `VENV_LOCATION=volume` persists it instead).

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Pod boots but no ComfyUI on 8188 / no FileBrowser on 8080** | ComfyPod never started. Check the container log for `[comfypod]` lines — none means the template isn't using the baked image (or, on the fallback path, the start command was never applied). With the baked image, verify the template's Container Image is `ghcr.io/220qm/comfypod:latest` and the package is public. Recover on any running pod: `curl -fsSL https://raw.githubusercontent.com/220qm/RunPod-s_comfy/main/install.sh \| bash` |
| Image pull fails when deploying | The GHCR package is still private — repo → Packages → comfypod → Package settings → Change visibility → Public (or add GHCR credentials in RunPod's Container Registry Auth settings) |
| Anything feels off | `comfypod-doctor` first — it checks GPU, torch, auth, disks, models |
| "Which URL/password?" | Pod logs → connection block, or `cat /workspace/.comfypod/credentials.txt` |
| Locked out of ComfyUI | `comfypod-secrets set-password`, or delete `/workspace/ComfyUI/login/PASSWORD` and set a new one on next visit |
| ComfyUI 502 right after boot | Still starting — `tail -f /workspace/.comfypod/logs/comfyui.log` |
| Model missing in a workflow | Downloads still running: `tail -f /workspace/.comfypod/logs/downloads.log`, then refresh (`R`) |
| Gated model 401/403 | `comfypod-secrets set-hf-token` (and accept the license on the HF model page once) |
| Black video frames | You enabled global SageAttention — set `SAGE_ATTENTION=auto` and use the Patch Sage Attention node instead |
| Node update broke the graph | `comfypod-snapshot restore baseline` (or the auto-saved `pre-update-*`) |
| **Manager can't install/update nodes** | `comfypod-doctor` names the cause. Most often ComfyUI is too old to expose the System User Protection API, in which case Manager force-sets `security_level=strong` and blocks everything regardless of config → `comfypod-update`. Otherwise set `MANAGER_SECURITY_LEVEL=weak` and restart. Guaranteed fallback: `comfypod-node add <git-url>` |
| A node imports fine but its Python deps are missing | `comfypod-node fix` (reinstalls requirements for every node), then restart |
| **A node I installed is gone on a new pod** | ComfyUI's code runs from container disk (imports from the volume are far too slow), so the `node-sync` service copies UI-installed nodes to the volume every 2 min and `start.sh` puts them back. `comfypod-doctor` shows the counts and whether node-sync is running. A node bigger than `NODE_ARCHIVE_MAX_MB` (512 by default — nodes that download weights into their own folder) is skipped with a warning; raise the limit or install it via `comfypod-node add <git-url>`, which persists by URL at any size |
| Wonky Python state | `rm -rf /opt/comfypod-venv` → next boot rebuilds from the lockfile; `rm /workspace/.comfypod/requirements.lock` too for a from-scratch resolve |

## First-run validation checklist

On the first real pod, confirm: fresh volume → generating (time it) · pod
terminate → new pod → nothing re-downloads · Krea 2 image, MiniMax H3
text-to-video clip and image-to-video clip all render · every exposed port rejects unauthenticated requests
(`comfypod-doctor` checks ComfyUI's) · an interrupted download resumes ·
idle-stop triggers on an idle pod but not during a long job.

## Why these choices?

- **Krea 2 Turbo (fp8_scaled)** — Krea's open-weights 12B DiT (June 2026),
  top-10 on the Artificial Analysis T2I leaderboard; Turbo is the 8-step
  distilled variant for interactive use, RAW one preset away.
- **MiniMax H3 FL2VA (pruned fp8_scaled)** — open-weights omni-modal video with
  native audio (Aug 2026, day-0 ComfyUI support). One checkpoint serves both
  text-to-video and first/last-frame image-to-video, so there is no separate
  T2V/I2V download. The pruned variants are what fit a single GPU — bf16 is
  66 GB. Its text encoder has no fp8 build, so the preset pairs it with the
  NVFP4 AWQ Qwen3-VL-32B (Blackwell-only; `minimax-h3-ada` covers 4090/Ada).
  That choice is what forces CUDA 13: NVFP4 has a hardware path only on a
  cu130 torch, and the emulated fallback is slower than fp8 would have been —
  so the quant and the CUDA version are one decision, not two.
- **ComfyUI-Login over basic-auth proxy** — browsers don't reliably attach
  `Authorization` headers to WebSocket upgrades, and ComfyUI's progress
  channel is a WebSocket; cookie auth survives it on every browser.
- **uv + lockfile + constraints** — reproducible env, fast boots, and the
  torch downgrade trap (the classic Blackwell killer) structurally closed.
