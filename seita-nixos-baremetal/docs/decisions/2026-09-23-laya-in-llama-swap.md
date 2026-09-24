# Colocating Laya in llama-swap

- Date: 2026-09-23
- Scope: `layaServer`, the `[laya]` model, and `systemd.services.laya-setup`
  in `modules/llama-cpp.nix`

Laya (convaiinnovations/laya, multilingual 322M) is the decision model used
for n8n's flow branching. It runs on PyTorch, not llama.cpp.

## Why something that isn't llama.cpp lives in the llama.cpp module

What this module actually manages is llama-swap (the router), not llama.cpp
specifically. llama-swap is a general-purpose process manager + proxy whose
`cmd` can run any command — the project itself lists vllm/ComfyUI as examples.

The one reason Laya lives here is that it lets **the 1660 SUPER's VRAM be
managed in one place, via the matrix's `sets`.** Running it as an independent
systemd service would create a VRAM consumer invisible to the matrix, which
breaks the whole "express which combination fits" design.

## Why it can't be GGUF

Laya is an mmBERT-base backbone with a custom decision head on top
(2 transformer layers + a scorer that reads a `[MASK]` per option + an
act-or-escalate output). GGUF/llama-server has no way to represent this head.
It's neither a generation nor an embedding model, so PyTorch is the only option.

## Why a pip venv (investigated on-host, 2026-09-23)

- No `laya` package exists in nixpkgs.
- `python3Packages.torchWithCuda` failed to build due to a fixed-output hash
  mismatch on `cuda_cupti-12.8.90`.
- nix-ld is disabled on this host (`/lib64` holds NixOS's default stub-ld;
  `programs.nix-ld` is unset).

`modules/comfyui.nix` is the existing precedent for a "pip-venv-managed
service" on this host. Unlike that one, no dedicated user is created here:
`llama-cpp.service` already runs as `User=seita`, and putting the venv under
seita's home keeps permissions consistent automatically.

- torch is the cu121 wheel (from PyTorch's own index — PyPI's torch isn't the
  CUDA build). The CUDA runtime ships inside the wheel, so the only thing
  needed from the system side is the driver's `libcuda.so`
  (`/run/opengl-driver/lib`).
- `LD_LIBRARY_PATH` needs 3 things: `libstdc++.so.6` (stdenv.cc.cc), zlib, and
  `/run/opengl-driver/lib` (confirmed all 3 are required, on-host, 2026-09-23).
- Versions (torch 2.5.1 / laya 0.3.6) are pinned to the combination measured to work.

## HTTP wrapper

The laya package only exposes a Python API, so a minimal HTTP server is
layered on top so llama-swap can start it as a child process. Written with
the standard library only, not FastAPI, since this is low-QPS with no
performance reason to reach for a framework.

## fp16 (the crux of this module)

The laya package puts weights on the GPU in fp32. The `self.dtype` that
`Agent.__init__` sets below sm_80 is the autocast (AMP) compute dtype, not
the weight dtype. Measured (2026-09-23):

| | VRAM | |
|---|---|---|
| fp32 | 1318 MiB | OOMs on the 1660 SUPER, which only has 1337 MiB free |
| fp16 | 748 MiB | Fits. No accuracy loss (probabilities match to 3 decimal places) |

These are right-after-load figures. The fp16 footprint grows with the requests being
handled (1128 MiB observed on 2026-09-24), so 748 MiB is a reference value, not a budget
line ([GPU and VRAM budget](../gpu-vram-budget.md)).

And since it OOMs the moment the fp32 weights touch the GPU, **the order
"load on CPU -> `half()` -> move to GPU" is mandatory**. Calling `half()`
after `load(..., device="cuda")` is already too late.

## Weights are pre-fetched by laya-setup

llama-swap starts `[laya]` on the first request that needs it. Downloading
647 MB at that point would eat up `healthCheckTimeout`, so the download is
done ahead of time by `laya-setup.service`, and runtime is closed off with
`HF_HUB_OFFLINE=1` (if the fetch was missed, this fails immediately instead
of silently waiting out the timeout).

`llama-cpp.service` depends on `laya-setup` via `wants`, not `requires`:
bonsai and embedding should keep working even if Laya's setup fails, so there's
no reason to take the whole router down with it (in that case, only `[laya]`
fails to start).

## evict_costs and concurrency

- `evict_costs` order: bonsai (50) > laya (30) > embedding (1). Laya blocks
  n8n's flow branching synchronously, so eviction is directly felt as
  latency. Kept ahead of embedding, but cheaper than the heavy-to-load bonsai.
- `concurrencyLimit: 1`: the wrapper is a ThreadingHTTPServer, but only one
  model lives on the GPU — calling it concurrently doesn't speed anything up,
  it only raises the VRAM peak. With so little margin, llama-swap serializes it.
