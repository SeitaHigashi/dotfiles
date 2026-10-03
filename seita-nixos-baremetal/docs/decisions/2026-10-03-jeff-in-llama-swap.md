# Jeff in llama-swap, and role-name aliases

2026-10-03. Context: Laya was the decision model for n8n's flow branching; Jeff (firelex/jeff, a
Jev-compatible model, article: https://gigazine.net/news/20260929-jeff/) was evaluated as an alternative.

## Decision

- Run `jeff-qwen3.5-0.8b` (Jeff v1.2) under llama-swap as a PyTorch child process on the 1660 SUPER,
  next to `laya`, which stays. They are alternatives (`|`) in the matrix sets.
- Use llama-swap `aliases` for role names: `chat` -> `bonsai`, `vision` -> `bonsai-vision`,
  `decision` / `jeff` -> `jeff-qwen3.5-0.8b`. `jev` is not used as a name: Jev is a closed model; Jeff
  merely speaks a Jev-compatible API.

## Measurements (30 Japanese 4-way routing cases, the same script and cases as Laya's accuracy test)

| setup | accuracy | median latency | VRAM / RAM |
|---|---|---|---|
| CPU fp32 | 26/30 (86.7%) | 808 ms (about 4.5 ms per input token) | 3.9 GB RAM |
| GPU int8 (bitsandbytes), vision kept | 25/30 | 127 ms | 1266-1334 MiB, **OOMs on some inputs** |
| GPU fp16, text-only, embeddings on CPU | 26/30 | 385 ms | 1022-1116 MiB |
| **GPU fp16 weights + fp32 matmul (adopted)** | **26/30** | **113 ms** | **1022-1116 MiB** |

- Jeff is English-only by its own statement (HF tag `en`), yet it handled these Japanese cases. 30 cases
  cannot rank it against Laya; Laya's 19/30 is from its old log (model and config not pinned down).
- Vision tower (192 MiB) is deleted; embeddings (491 MiB) stay on the CPU (lookup 0.2-1.2 ms). With the
  embeddings on the GPU the load OOMs (312 MiB free after the layers).
- fp16 GEMM on this GPU is ~10x slower than fp32 (0.36 vs 3.48 TFLOPS on a 153x1024x6144 matmul; the card
  has no tensor cores). Hence weights stay fp16 in VRAM and each Linear expands to fp32 per call.
  Profile: 93% of the 382 ms was fp16 `aten::mm`.
- Through llama-swap the results were identical (26/30, 0 label flips vs fp32, probabilities within
  0.0014), and a request to `laya` evicted Jeff as the matrix says.

## Constraints and risks

- Free VRAM on the 1660 SUPER is ~220 MiB with Jeff loaded (Laya: ~590 MiB). See
  [gpu-vram-budget.md](../gpu-vram-budget.md).
- torch is 2.11.0+cu128, not Jeff's pin 2.14.0: 2.14 is cu130-only and the driver (575, CUDA 12.9)
  cannot run it. Jeff's source is pinned to commit `d0173b4`, the checkpoint to HF commit `f0a2b52`
  (tag v1.2; the v1.3 long-term-support base was announced and needs a re-measurement).
- Jeff's stock `jeff-serve` is untouched; the llama-swap wrapper (`jeffServer` in
  `modules/llama-cpp.nix`) monkeypatches the model loading. A Jeff update can break it.
- `nixos-rebuild switch` starts `jeff-setup.service`, which downloads ~3 GB of wheels and the 1.6 GB
  checkpoint (`journalctl -u jeff-setup -f`). `llama-cpp.service` does not require it.
- Not measured: Gemma4-E2B (9.3 GB, would not fit this card), Jeff's adapters, n8n's real branching inputs.
