# Ollama model selection rule and benchmark

- Date: 2026-08-02
- Affects: `modules/ollama.nix` (`loadModels`)

## Rule

**Selection is driven by whether the total model size fits in VRAM, not by parameter count.**
Whatever spills over falls back to CPU, and prompt processing in particular slows down by an
order of magnitude when it does.

## Measured (2026-08-02, same prompt: Japanese summarization + forced JSON)

| Model | Size | Fits in VRAM? | Prompt tok/s | Generation tok/s |
|---|---|---|---|---|
| gemma4:12b | 7.6 GB | yes | 177.9 | 35.0 |
| qwen3:14b | 9 GB | yes | 130.6 | 35.0 |
| gemma4:26b | 18 GB | no | 18.8 | 26.0 |

`gemma4:26b` is MoE with only ~4B active parameters, but **a small active-parameter count does
not save you if the total size doesn't fit** — for long-input workloads, the prompt-processing gap
alone dominates wall-clock time. (Running fully on CPU flips the ranking back in MoE's favor,
since active-parameter count is what matters there — don't pick a model without first checking
whether the GPU is actually being used.)

## Context

Host: GTX 1660 SUPER (6 GiB, sm_75, PCIe x4) + RTX 3060 Ti (8 GiB, sm_86, PCIe x8, shared with X11
when a projector is attached) — combined 14 GiB nominal, ~13.3 GiB effective as seen by ollama.
CPU: Ryzen 3 3300X (4C/8T); of 46 GiB RAM, 16 GiB is already claimed by the ZFS ARC and 8 GiB by
the Minecraft server heap, leaving roughly 20 GiB of headroom for CPU offload. See
[GPU VRAM budget](../gpu-vram-budget.md) for the current card table.

Note (2026-08-11/12): a GT1030 was briefly added at PCI bus 05 for display duties, which pushed
the 3060 Ti from CUDA index 1 to 2; it was removed the next day (2026-08-12), restoring index 1 =
3060 Ti. The projector's HDMI source moved from the 1660 SUPER to the 3060 Ti on 2026-08-25, which
does not affect CUDA indices.
