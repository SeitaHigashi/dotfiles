# OpenViking embedding and vlm on llama.cpp

- Date: 2026-09-21 to 2026-09-22
- Affects: `modules/openviking.nix` (`embedding`, `vlm`, `query_planner`)

For the overall ollama → llama.cpp cutover (service enablement, Open WebUI's three ollama
dependencies), see
[the main migration decision](2026-09-23-ollama-to-llama-cpp.md). This document covers the parts
specific to OpenViking's own config.

## Embedding: dimension truncation is safe, no reindex needed

`embedding.dimension = 2048` stays correct after the switch to llama.cpp's `embedding` preset
(Qwen3-Embedding-4B, native 2560 dimensions), even though llama.cpp's `/v1/embeddings` ignores the
`dimensions` request parameter (unlike ollama) and always returns the full 2560-dim vector.

The reason it still works: OpenViking never sends a `dimensions` parameter in the first place.
`openviking/models/embedder/openai_embedders.py`'s `_should_send_dimensions()` (OpenViking 0.4.21)
returns `False` whenever `provider == "openai"`, and instead truncates client-side via
`_truncate_vector()`. So the resulting 2048-dim vector is produced the same way it was under
ollama.

Measured (2026-09-21): truncating 2560 → 2048 changed the cosine similarity of a paraphrase pair
from 0.9624 to 0.9622 — negligible, since Qwen3-Embedding is Matryoshka-trained for this.

## allow_metadata_override = true — required once, not for the dimension change

OpenViking records `provider`/`model` name (not just dimension) in a collection's metadata.
Renaming the model from `"qwen3-embedding:4b"` to `"embedding"` alone made the recorded metadata
mismatch, and the container refused to start:
`EmbeddingRebuildRequiredError: Existing collection embedding metadata does not match current
configuration.` This flag (introduced for exactly this case — same dimension, provider/model name
changed only — see `openviking/storage/collection_schemas.py:417-437` in OpenViking 0.4.21)
rewrites the stored metadata and keeps existing vectors, logging a warning. It still refuses to
start if the dimension itself actually changed, so leaving it on is safe either way.

**Known risk, accepted 2026-09-21:** the existing vectors were produced by ollama's inference
implementation; going forward they're produced by llama.cpp. Same underlying weights
(Qwen3-Embedding-4B), but pooling/normalization details could differ enough to shift vectors
slightly — this was not cross-checked, because the comparison window closed once ollama was
stopped. User decision at the time: reindex eventually, but not immediately. If search quality
seems to regress, reindex then.

## vlm: bonsai tool-calling benchmark (2026-09-21)

Switching `vlm`/`query_planner` from `qwen3.5:9b` to `bonsai` (Ternary-Bonsai-2-27B, PTQ1_0,
context 81920 with q4_0 KV cache, ~32.75 tok/s on the 3060 Ti alone) was validated against the
same tool-call reliability problem seen with gemma4:12b (see
[vlm selection](2026-09-08-openviking-vlm-selection.md)) — bonsai did not reproduce it.

Test suite results: 21/21 on the basic suite; 25/27 on a harder suite (nested schemas, choosing
among 8 tools, Japanese, forced `tool_choice`, parallel calls, sequential chains, and negative
cases where no tool should be called). The only observed weakness: deep nesting (dropped
`location.room` 2 of 3 times) — worth checking first if `extract_loop`'s schema for a given call is
deeply nested.

## num_ctx and reasoning_effort on llama.cpp

`options.num_ctx` was removed from `vlm`'s `extra_request_body`: llama.cpp has no per-request
context override — context is fixed per preset at server startup. The `[bonsai]` preset was 16384
at the time (later expanded to 81920 on 2026-09-22; current value is authoritative in
`modules/llama-cpp.nix`). Sending it would just be silently ignored, which risks a future reader
assuming it's in effect — hence removed rather than left inert.

`reasoning_effort = "none"` was kept and confirmed to still work under llama.cpp (2026-09-21):
without it, `reasoning_content` came back as 133 characters; with it, 0. The mechanism differs from
ollama — llama.cpp always splits reasoning into a separate `reasoning_content` field rather than
inlining it (so it doesn't break content parsing, but silently still costs reasoning tokens unless
suppressed). Also observed: `"high"` produces empty `content` and empty `reasoning`. Don't use
values other than `"none"`.
