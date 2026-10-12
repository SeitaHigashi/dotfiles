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
