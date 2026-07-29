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
| Text/image → video, fast drafts | **Wan 2.2 5B** (TI2V) | `wan22-5b` |
| Text → video, best quality | **Wan 2.2 T2V** (14B, high+low noise) | `wan22-t2v` |
| Image → video, best quality | **Wan 2.2 I2V** (14B) | `wan22-i2v` |

Notes that save time:

- The Wan 14B templates come pre-wired with the **Lightning 4-step LoRAs**
  (downloaded by the presets). Leave them on for speed; bypass the LoRA
  nodes and raise steps to ~20 for maximum motion fidelity.
- The 14B models pair with the **Wan 2.1 VAE**; the 5B model uses the
  **Wan 2.2 VAE**. Both are in the presets — if you build a graph by hand and
  the output is garbage noise, the VAE mismatch is the first thing to check.
- For a speed boost on Wan, add the **Patch Sage Attention** node (KJNodes,
  installed) with backend `sageattn_qk_int8_pv_fp16_cuda` in front of the
  model. Do not use the global `--use-sage-attention` flag — it has produced
  black output on Wan/Qwen-family models.
- Typical pipeline: stills with Krea 2 Turbo → animate keepers with
  Wan 2.2 I2V.

Save your own workflows from the UI — they persist under
`/workspace/ComfyUI/user/` and survive pod termination.
