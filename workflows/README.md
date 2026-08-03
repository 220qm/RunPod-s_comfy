# Starter workflows

ComfyPod deliberately ships **no workflow JSON files**. ComfyUI's built-in
template browser carries the official, tested graphs for exactly the models
this stack installs, always matched to the installed frontend version — a
JSON file in this repo would only drift out of date.

**ComfyUI → menu (top left) → Browse Templates**, then:

| What you want | Template | Preset that provides the models |
|---|---|---|
| Text → image | **Krea 2** (Turbo, ~8 steps, CFG 1) | `krea2` |
| Text → image, undistilled | Krea 2 with the RAW checkpoint (~50 steps, CFG ~3.5) | `krea2-raw` |
| Text → video (with audio) | **MiniMax H3** | `minimax-h3` |
| Image → video (with audio) | **MiniMax H3** — same graph, connect an image to `first_frame` | `minimax-h3` |
| Reference-driven video | MiniMax H3 Ref2VA | `minimax-h3-ref` |

## MiniMax H3 notes

- **One checkpoint, both modes.** `FL2VA` handles text-to-video *and*
  first/last-frame conditioning. For image-to-video, feed your image to
  `first_frame` on the **MiniMaxH3ImageToVideo** node; supply `last_frame` too
  and it interpolates between them.
- **Native audio.** H3 generates sound with the video, which is why the preset
  downloads two VAEs (`minimax_h3_video_vae_fp16` and
  `minimax_h3_audio_vae_fp32`). Both are unquantised on purpose — they are
  small and run once per generation, not once per step.
- **Expect an offload pause.** The fp8 diffusion model (~21 GB) plus the
  Qwen3-VL-32B text encoder exceeds 32 GB, so ComfyUI swaps between them.
  The first prompt encode of a session is the slow one.
- **Blackwell vs Ada.** The default preset uses an NVFP4 text encoder, which
  is a Blackwell (RTX 5090 / PRO 4500) format. On a 4090 or RTX 4500 Ada use
  `comfy-dl preset minimax-h3-ada`, which swaps in the int8 encoder.
- **Needs a ComfyUI with the MiniMaxH3 nodes.** Support landed day-0 in
  August 2026; if the nodes are missing, run `comfypod-update` (or rebuild the
  image, which pins the latest release tag at build time).

## Krea 2 notes

- Turbo is the distilled checkpoint: ~8 steps, CFG 1. RAW is undistilled —
  ~50 steps at CFG ~3.5, and the right base for LoRA training looks.
- Pipeline that works well: stills with Krea 2 Turbo → animate the keepers
  with MiniMax H3 image-to-video.

## General

- For a speed boost, add the **Patch Sage Attention** node (KJNodes, already
  installed) with backend `sageattn_qk_int8_pv_fp16_cuda` in front of the
  model. Do not use the global `--use-sage-attention` flag — it has produced
  black output on Qwen-family text encoders, which both models here use.
- Save your own workflows from the UI — they persist under
  `/workspace/ComfyUI/user/` and survive pod termination.
