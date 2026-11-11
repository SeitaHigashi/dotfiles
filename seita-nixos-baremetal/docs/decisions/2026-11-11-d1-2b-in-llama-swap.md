# Add d1-2B (LFM3 decision model) to llama-swap

- Date: 2026-11-11
- Scope: model `d1-2b`, `evict_costs`, matrix sets in `modules/llama-cpp.nix`

## Why

d1-2B (Liquid AI, LFM3 family) is a decision model like `laya` and `jeff`: typed answers
with calibrated probabilities in one forward pass. Liquid ships official GGUFs
(`LiquidAI/d1-2B-GGUF`) and llama.cpp >= b11960 serves them on `/v1/systemone`, so the
upstream build already used for `lfm3-audio` runs it with no PyTorch venv or wrapper.

## Measurements (standalone llama-server v0.9.0, 30 Jeff test cases, route question)

Run 2026-11-11, results in `~/share/out/d1-2b-cpu/20261111-211024/`. The machine was
loaded (load average 2-6), so CPU numbers carry noise.

| setup | median | correct | 1660 SUPER VRAM added |
|---|---|---|---|
| GPU Q4_K_M, `-ub 2048` | 169 ms | 28/30 | +1382 MiB |
| GPU Q8_0, `-ub 2048` | 173 ms | 27/30 | +2094 MiB |
| GPU Q4_K_M, `-ub 8192` | 170 ms | 28/30 | +2356 MiB |
| GPU Q8_0, `-ub 8192` | OOM (1232 MiB compute buffer) | - | - |
| CPU Q4_K_M, 4 / 2 threads | 850 / 1597 ms | 28/30 | - |
| CPU Q8_0, 4 / 2 threads | 1128 / 2130 ms | 27/30 | - |
| PyTorch fp32 CPU, 4 threads (HF weights) | 1657 ms | 27/30 | 7.7 GB RAM |

PyTorch fp32 with 8 threads took 6705 ms and bf16 8383 ms (Zen 2, no AVX512-bf16); the
cause of the 8-thread slowdown was not confirmed (suspected SMT / other load).

## Decision

- Q4_K_M, `-ngl 99`, `-b/-ub 2048`, `-c 8192`, `ttl: 600`, `CUDA_VISIBLE_DEVICES=0`.
  Q8_0 is no faster or better here and costs ~700 MiB more.
- 4th alternative `(laya | jeff-qwen3.5-0.8b | lfm3-audio | d1-2b)` in all three sets,
  `evict_costs` 30 like the others.
- No alias: `decision` / `jeff` stay with `jeff-qwen3.5-0.8b`. Moving the role is a
  separate decision (changes n8n's call shape).

## Open points

- Not measured through llama-swap (`/upstream/d1-2b/v1/systemone`); remeasure after switch.
- Co-residency with `embedding` was measured standalone only (free 2662 MiB vs +1382 MiB).
- `-np` left at the default (4 slots) as measured; lowering it would save VRAM, unmeasured.
- State + question above 2048 tokens will fail (`-b/-ub`).
- GGUF must be placed by hand: `/var/lib/llm-models/d1-2B-GGUF/d1-2B-Q4_K_M.gguf`
  (copy of `~/data/d1-2B-GGUF/`; source `LiquidAI/d1-2B-GGUF`).
- `switch` restarts `llama-cpp.service` (config is in the store), which drops bonsai once.
