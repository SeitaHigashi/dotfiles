# ComfyUI: `--disable-dynamic-vram`

- Decided: 2026-08-08
- Module: `modules/comfyui.nix` (`comfyui.service`'s `ExecStart`)

## Problem

`comfy-aimdo` (ComfyUI's dynamic VRAM offload) was tested against a model too large for
this card's 8 GiB VRAM (a MiniMax H3 text encoder alone needing ~15 GB). Instead of
failing cleanly, it hung completely: 0% GPU usage, no disk I/O, not even reading the HTTP
socket. Confirmed on this host on 2026-08-08. Upstream also tracked hang/crash
regressions from 2026-08-03 onward (Comfy-Org/ComfyUI#15255).

## Decision

Disable the mechanism outright with `--disable-dynamic-vram`.

## Trade-off

Models that don't fit in VRAM now fail with a plain CUDA OOM instead of hanging —
strictly easier to diagnose than an infinite hang, but oversized models simply won't run.
Quantized (GGUF, etc.) or smaller models that fit within VRAM work fine without this flag
being a limitation.
