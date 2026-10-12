# bonsai-image in llama-swap

2026-10-10. Context: the user wanted PrismML's Bonsai Image Ternary 4B
(`prism-ml/bonsai-image-ternary-4B-gemlite-2bit`, FLUX.2 Klein 4B with ternary weights packed for gemlite)
next to `qwen-image`, in the same form: a llama-swap model ID called through
`POST /v1/images/generations`, with a `ttl`, exclusive on the 3060 Ti.

## Decision

- Register `bonsai-image` in llama-swap as a PyTorch child process on the 3060 Ti, an **alternative**
  (`|`) to `qwen-image` in the `image` matrix set, `evict_costs` 10, `ttl: 600`.
- Not sd.cpp: the model only runs through PrismML's `backend_gpu` (diffusers + gemlite/Triton), so it has
  its own venv (`bonsai-image-setup.service`, like `jeff-setup`) and a small standard-library HTTP wrapper
  (`bonsaiImageServer`) over `GpuPipeline`. Upstream's FastAPI server only has `/generate` behind a bearer
  token and no `/v1/models`.
- Weights load lazily on the first request (like `sd-server`), so llama-swap's health check passes at once.

## Measurements (3060 Ti alone, 1024x1024, 4 steps, seed 42)

| | |
|---|---|
| weights load | 59-60 s |
| first image, cold Triton cache | 57 s (113 s through the wrapper, which includes the load) |
| warm image | 9.5-9.7 s |
| torch peak | 6833 MiB / 6447 MiB (first / warm) |
| `nvidia-smi` peak | 7812 MiB of 8192 |

- The model card's own numbers (RTX 3060 6 GB laptop 17.5 s, RTX 3080 4.5 s) bracket this.
- Two runs with the same seed differ by at most 1/255 per pixel (mean 0.02): Triton picks different kernels
  on the first (compile) and later runs. Not investigated further; the images look identical.
- No VRAM headroom (~380 MiB): nothing may share the card. (1024x1024 was the ceiling here; raised to
  2560x1440 on 2026-10-12, see the addendum at the end.)

## What did not work first (kept so it is not rediscovered)

1. **Plain `DiffusionPipeline.from_pretrained`** (what a summary of the model card suggested) is not the
   code path: the real one is `backend_gpu.pipeline_gpu.GpuPipeline` from `PrismML-Eng/image-studio`
   (the README's `build_pipeline` does not exist in `server.py`).
2. **gemlite 0.6.0.post2** (latest) fails with `TypeError: cannot assign 'torch.cuda.ByteTensor' as
   parameter 'W_q'`: 0.6 promotes `W_q` to `nn.Parameter`, and `backend_gpu` assigns plain tensors.
   Upstream's `uv.lock` pins gemlite 0.5.1.post1; with it (and diffusers 0.38.0, transformers 5.8.1) it
   loads. Pin all of them.
3. **`Cannot find ptxas`**: the ptxas bundled in the triton wheel is a generic-Linux ELF that cannot
   start on NixOS, so Triton treats it as missing. `TRITON_PTXAS_PATH` points at nixpkgs'
   `cudaPackages.cuda_nvcc` (12.8.93, the generation torch cu128 / triton 3.6 pair with).
4. **Triton also needs** `TRITON_LIBCUDA_PATH=/run/opengl-driver/lib` (otherwise it runs
   `/sbin/ldconfig -p`, which fails here) and `CC=<gcc>` for its launcher stubs.
5. **torch**: upstream pins 2.12.0, which exists only as cu130; the driver (575, CUDA 12.9) runs cu128, so
   2.11.0+cu128 is used (triton 3.6.0 instead of 3.7.0).

## Operational note: measuring on the 3060 Ti

`bonsai` is also called by OpenViking (`vlm`, `query_planner`) with prompts of ~24k tokens that take
minutes, and OpenViking retries on failure. Unloading `bonsai` while one is in flight returns 502 to it, and
its retry reloads `bonsai` within ~5 s, which takes the card back from whatever was starting
(`CUDA error: out of memory` in the wrapper). Unload only when `GET :18900/slots` shows no
`"is_processing": true` for a few seconds in a row.

## How to turn it off

Remove (or comment out, keeping the way back next to it) the `"bonsai-image"` entry, its
`evict_costs` line and the `| bonsai-image` in the `image` set in `modules/llama-cpp.nix`; the
`bonsai-image-setup` unit and `bonsaiImage*` bindings can stay (the unit is idempotent and only
downloads once). State lives in `/var/lib/llm-models/bonsai-image` (venv, model, triton cache) and is
regenerable.

## Addendum 2026-10-12: resolution ceiling raised to 2560x1440

The user asked whether 1920x1080 / 4K is possible. Measured on the 3060 Ti alone (4 steps, seed 42):

- Without VAE tiling, 1792x1024 passes and 1920x1088 OOMs in the VAE decode (1020 MiB allocation).
- With tiling, 1920x1088 (20.1 s) and 2560x1440 (38.7 s, 7748 MiB `nvidia-smi` peak) pass; 3072x1728 and
  4K OOM inside the transformer. 4K does not fit this card with the current code.
- **Decision:** `MAX_SIDE` 2560 plus a `MAX_PIXELS` cap of 2560*1440, and the wrapper calls
  `pipe._vae.enable_tiling()` after `prewarm()`. Sides stay multiples of 32.
- **First left undone, done the same day (below):** relaxing the 32-px check to 16 (the real
  constraint) and cropping, since 1080 is not a multiple of 16.
- **Gotcha kept:** `generate_png(tiled_vae=...)` is ignored upstream (`del tiled_vae`), so passing it does
  nothing; tiling has to be enabled on the VAE object.

Details and the table: [llama-cpp.md](../services/llama-cpp.md#resolution-ceiling-measured-2026-10-12-3060-ti-alone-4-steps-seed-42-vae-tiling-on).

## Addendum 2026-10-12 (later): 16-px alignment and centre-crop

- **16-px verified:** 1024x1008, 1008x1008, 1920x1072 and 1936x1088 (seed 42, tiling on) generate PNGs of
  exactly the requested size with no artefacts and the same time/VRAM as 32-aligned neighbours.
  `ALIGN` is now 16; the wrapper re-execs upstream's `diffusion_klein` with its `% 32` check lowered to
  `% 16` (patched at load time, venv untouched, `assert` guards a backend bump).
- **Any size accepted:** the wrapper generates at the size rounded up to `ALIGN` and centre-crops. The
  excess is split evenly (8 px -> 4 px top + 4 px bottom; an odd pixel comes off the bottom/right).
  `MAX_SIDE` / `MAX_PIXELS` apply to the generated size because that is what uses VRAM.
  1920x1080 = 1920x1088 generated, 4 px off top and bottom. The response carries `generated_size`.
- Checked afterwards: the alias `image` gives byte-identical output to `bonsai-image`; portrait 1440x2560
  generates in a fresh process.
- **Defect found and fixed:** a different-shaped request right after another one OOMed in the
  long-lived wrapper (no `torch.cuda.empty_cache()` between requests; allocator fragmentation).
  **Decision:** the wrapper calls `torch.cuda.empty_cache()` after every request (in a `finally`).
  `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` also worked in one sequence but was not adopted
  (less tested with gemlite/Triton); details and numbers in
  [llama-cpp.md](../services/llama-cpp.md#calling-bonsai-image).
- Not exercised: sizes beyond 2560x1440 (still OOM), the in-chat display of the Open WebUI Pipe.

## 2026-10-12: reference-image editing (`/v1/images/edits`)

- **Rationale:** the user wanted to edit an existing picture with bonsai-image, not only generate from
  text. Upstream's `backend_gpu` had the reference path deleted, so the wrapper adds it back.
- **Decision:** serve `POST /v1/images/edits` (multipart: `image`, `prompt`, `model`, optional `size`,
  `seed`; `n` must be 1) from the same wrapper and the same llama-swap model. Output format is the same
  as generations. Generations are unchanged (same seed-1 request byte-identical before and after).
- **Mechanism:** the wrapper re-execs upstream `backend_gpu/diffusion_klein.py` with extra source rewrites.
  The reference is VAE-encoded, patchified, BN-normalised, packed and concatenated to the latent sequence
  with time-offset ids; the transformer output is sliced back to the output tokens. Each rewrite anchor is
  asserted to occur exactly once, so a backend rev bump fails loudly instead of silently ignoring the
  reference.
- **Reference size:** decoded with PIL (EXIF transposed) and shrunk, keeping aspect, to at most
  `MAX_PIXELS_EDIT` = 1024*1024 px, both sides a multiple of 16. Independent of the output `size`. If
  `size` is omitted, the output is the resized reference size.
- **Output cap:** the generation caps apply unchanged (each side <= 2560, <= 2560x1440 px generated,
  non-multiples of 16 rounded up and centre-cropped). `MAX_PIXELS_EDIT` = 1024*1024 was kept because it was
  measured working at exactly 1024x1024; no separate output cap for edits was needed.
- **llama-swap:** routes by the multipart `model` field and forwards the body unchanged (llama-swap v249,
  rev f94c94ac). `useModelName` is not set for bonsai-image.

### Measurements

On the 3060 Ti alone, 4 steps, through the real wrapper (raw: `~/bonsai-image-measure/20261012-153150/results.json`,
`montage.png`):

| request | HTTP | time | `nvidia-smi` peak |
|---|---|---|---|
| edit 1024x1024 (1024x1024 reference) | 200 | 18.5 s | 7372 MiB |
| edit 1440x810 (generated 1440x816) | 200 | 20.7 s | 7706 MiB |
| edit 1920x1080 (generated 1920x1088) | 200 | 32.1 s | 7772 MiB |
| edit 2560x1440 | 200 | 52.3 s | 7750 MiB |
| edit 1440x2560 | 200 | 52.2 s | 7750 MiB |
| edit 768x512 (3:2 reference, no `size`) | 200 | 15.4 s | 6326 MiB |
| first request after load (generations 1024, includes lazy load) | 200 | 75.0 s | not recorded |

- A reference adds about 9 s at 1024x1024 (18.5 s vs 9.2 s for a plain generation).
- **The reference is honoured:** 1024x1024 reference, prompt "the same tabby cat wearing a red knitted hat,
  sitting on a wooden table, photo", seed 2. Mean absolute pixel difference between the edit and the
  reference is 19.1; a no-reference generation with the same prompt and seed differs from the reference by
  63.4. Earlier 768x768 probe (5 images): 22.5 / 24.9 with a reference vs 70.5 / 48.1 without.

### Limitations

- **HTTP 200 is not a usable picture.** A 1:1 reference with a 9:16 output (1440x2560) produced a duplicated
  subject (two cats stacked under one hat). Keep the output aspect close to the reference, or omit `size`.
  At 1440x810, 1920x1080 and 2560x1440 from a 1:1 reference the subject shrinks and the scene is
  recomposed (still the same cat, hat added).
- **VRAM headroom is small:** peak 7.3-7.8 GiB of 8 GiB at every size measured (about 0.4 GiB). Nothing
  above 2560x1440 was tried.
- **Downscale path not exercised by a non-square image:** the largest reference measured was exactly
  1024x1024; the 3:2 one was 768x512. The shrink path for a reference larger than 1 megapixel is untested
  for non-square input.
- **Not pixel-exact:** an edit is a regeneration conditioned on the reference. Details such as the tail
  position can change (seen in the 768x768 probe).
- **Sample size:** one sample per condition, judged by eye.

Usage and the request/response contract: [llama-cpp.md](../services/llama-cpp.md#editing-post-v1imagesedits).
