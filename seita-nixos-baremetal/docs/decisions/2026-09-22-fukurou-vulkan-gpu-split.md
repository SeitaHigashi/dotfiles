# fukurou: pin whisper.cpp to the 1660 SUPER via Vulkan

- Decided: 2026-09-22
- Module: `modules/fukurou.nix`

## Decision

Set `GGML_VK_VISIBLE_DEVICES=1` (Vulkan index 1 = GTX 1660 SUPER on this host) on
`fukurou-server`, freeing the RTX 3060 Ti for llama.cpp's `bonsai` model exclusively.

## Why CUDA env vars don't apply here

fukurou's whisper.cpp STT path uses Vulkan only — `ldd` shows `libvulkan.so.1` and no
CUDA/cuBLAS linkage (confirmed 2026-09-22). `CUDA_VISIBLE_DEVICES`/`CUDA_DEVICE_ORDER`,
used elsewhere on this host (`modules/ollama.nix`, `modules/llama-cpp.nix`), have zero
effect on this process.

`GGML_VK_VISIBLE_DEVICES` is read by ggml's Vulkan backend (bundled in whisper-rs-sys
0.11.1, `ggml/src/ggml-vulkan.cpp:2117`, "Emulate behavior of CUDA_VISIBLE_DEVICES for
Vulkan") as a comma-separated list of indices; unset, it uses every discrete GPU found.

## Vulkan's index order is its own, and it's reversed from `nvidia-smi` here

Measured via `vulkaninfo --summary` (2026-09-22):

| Vulkan index | Card | `nvidia-smi` index |
|---|---|---|
| 0 | RTX 3060 Ti | 1 |
| 1 | GTX 1660 SUPER | 0 |
| 2 | llvmpipe (Mesa software/CPU) | — |

This happens to coincide with CUDA's `FASTEST_FIRST` ordering, but the two enumeration
systems are unrelated — don't assume "CUDA index 1, so Vulkan index 1" after any GPU
change. Re-measure both independently (see [runbooks/gpu.md](../runbooks/gpu.md)).

## Budget impact

fukurou holds ~478 MiB on the 1660 SUPER while idle (measured 2026-09-22), consistent with
the STT model size (`ggml-small.bin` = 465 MB). The 1660 SUPER's remaining ~5.7 GiB budget
is shared with `embedding` and `laya` (`modules/llama-cpp.nix`) — see
[GPU and VRAM budget](../gpu-vram-budget.md). Whether VOICEVOX core's onnxruntime also
uses GPU memory is unconfirmed as of 2026-09-24; re-check with a per-card `nvidia-smi`
breakdown if the budget stops adding up.
