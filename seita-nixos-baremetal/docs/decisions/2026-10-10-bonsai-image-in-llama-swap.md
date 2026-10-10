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
- No VRAM headroom (~380 MiB): nothing may share the card, and 1024x1024 is the measured ceiling.

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
