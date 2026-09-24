# OpenViking model consolidation (query_planner merged into vlm)

- Date: 2026-09-06
- Affects: `modules/ollama.nix` (`OLLAMA_MAX_LOADED_MODELS`, `loadModels`),
  `modules/openviking.nix` (`query_planner`)

## Problem

`query_planner` was originally assigned a dedicated lightweight model,
`guoxuter/ov_intent_analysis_sft:v7_q8` (~0.8B). With `embedding` (qwen3-embedding:4b, ~4 GB) and
`vlm` (qwen3.5:9b, ~5.4 GB) already resident, the 8 GB 3060 Ti could not also hold a third model at
once. Combined with `OLLAMA_MAX_LOADED_MODELS=2`, every request triggered an evict/reload cycle —
confirmed on this host via `journalctl -u ollama` showing `"loading model via llama-server"` and
`"cudaMalloc failed: out of memory"` every few minutes. Reload latency regularly exceeded
OpenViking's own HTTP timeout, so both memory extraction (`extract_loop`) and query expansion
failed periodically.

## Resolution

`query_planner` was pointed at the same model as `vlm` (`qwen3.5:9b`), cutting the resident set
back to two models (`embedding` + `vlm`), which fits the `OLLAMA_MAX_LOADED_MODELS=2` cap without
thrashing.

`guoxuter/ov_intent_analysis_sft:v7_q8` was rejected as a `vlm` substitute too: OpenViking's own
setup wizard (`openviking_cli/setup_wizard.py`) documents a hard minimum of ~4B parameters for
memory extraction to work reliably, and guoxuter (~0.8B) is well below it.

The model was later manually removed from the host (`ollama rm
guoxuter/ov_intent_analysis_sft:v7_q8`) — pulled models are not auto-removed just by deleting
them from `loadModels` (25.05 lacks `services.ollama.syncModels`).

## Why OLLAMA_MAX_LOADED_MODELS = 2

OpenViking alternates between `embedding` (qwen3-embedding:4b, ~4.5-4.7 GB resident) and `vlm`
(qwen3.5:9b, ~6.6 GB) on nearly every call. A cap of 1 would force a load/unload round trip per
request, which produced the same "slow call" symptom independently observed as 5000-16000 ms
request durations. The combined ~11.1 GB is expected to fit the ~13.3 GiB effective VRAM, but
`vlm`'s `num_ctx` (see the vlm config in `modules/openviking.nix`) adds further KV-cache overhead
on top, so this should be re-checked against `ollama ps` / GPU usage if either model's config
changes. Large `num_ctx` values (e.g. 163840) reliably cause `cudaMalloc` OOM under simultaneous
load — confirmed on this host with `gemma4:12b-163k`. Since `query_planner` now shares `vlm`'s
model, only two models ever need to be resident, so this cap is sufficient.
