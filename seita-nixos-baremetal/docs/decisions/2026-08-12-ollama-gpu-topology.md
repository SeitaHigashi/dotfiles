# Ollama GPU topology and allocation

- Date: 2026-08-12
- Affects: `modules/ollama.nix` (`environmentVariables`)

## CUDA_DEVICE_ORDER (required before CUDA_VISIBLE_DEVICES means anything)

**Without `CUDA_DEVICE_ORDER = "PCI_BUS_ID"`, the `CUDA_VISIBLE_DEVICES` index below points at the
wrong GPU.** The CUDA runtime defaults to `FASTEST_FIRST` ordering (fastest GPU gets index 0), not
PCI bus order. Observed default on this host: index 0 = RTX 3060 Ti, index 1 = GTX 1660 SUPER.
Without pinning to PCI bus order (bus 04/06 = 1660 SUPER/3060 Ti), `CUDA_VISIBLE_DEVICES = "1,0"`
silently selects an unintended pairing and the 1660 SUPER goes unused. Hit on this host when the
GT1030 was added at bus 05 (2026-08-12) — `modules/comfyui.nix` already had this set, ollama did
not.

## CUDA_VISIBLE_DEVICES = "1,0"

Puts the faster 3060 Ti (index 1 after the fix above) first, so it gets priority in ollama's layer
allocation. Also affects the GPU numbering ollama itself reports.

## OLLAMA_SCHED_SPREAD = "1"

Deliberately spreads models that would fit on one card across both.

**This is not automatically a speedup.** The 1660 SUPER is PCIe x4 and a TU116 part with no FP16
tensor cores; layer-splitting is bottlenecked by inter-card transfer and by the slower card's
compute, and can end up slower than running on the 3060 Ti alone for ~7B-class models. If a model
feels slow, remove this line and set `CUDA_VISIBLE_DEVICES = "2"` (3060 Ti only) instead. See
[the ollama service doc](../services/ollama.md#ops-notes) for the measurement procedure.
