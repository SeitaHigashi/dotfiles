# OpenViking vlm model selection (moondream -> gemma4:12b -> qwen3.5:9b)

- Date: 2026-09-06 to 2026-09-08
- Affects: `modules/openviking.nix` (`vlm`, `query_planner`)

## Background

`vlm` is misleadingly named — despite the name, it's the general-purpose LLM used for almost all
of OpenViking's generation work (memory extraction / `extract_loop`, query expansion, L0/L1
summarization), called via `config.vlm.get_completion_async()` (confirmed in
`openviking/session/memory/extract_loop.py` on this host). It also happens to be the image parser
backend (`ImageConfig.enable_vlm`) when vision is needed.

## Attempt 1: moondream (1.7B, vision-specialized) — rejected

Memory extraction failed consistently with `"LLM returned neither tool calls nor operations"`.
OpenViking's own `openviking_cli/setup_wizard.py` documents that a VLM under 4B fails memory
extraction (it duplicates few-shot examples as if they were real memories) — moondream is well
under that floor.

## Attempt 2: gemma4:12b — rejected

12B, matching model family with the embedding model is not required per OpenViking's own presets
(32-64 GB tier presets combine qwen3-embedding with gemma4). Despite explicit `num_ctx`/`think`
settings, under `extract_loop`'s `tool_choice="auto"`, gemma4:12b would sometimes return a plain
natural-language summary instead of a tool call (`"Failed to parse memory operations ... Expected
dict after parsing"`, confirmed on this host). Retries usually recovered within 3 attempts, but at
real cost: ~70s average per record, 625s for 9 records in one observed run. Retained for Open
WebUI's own chat use (separate from OpenViking) — see `modules/ollama.nix` `loadModels`.

`setup_wizard.py`'s VLM presets are Qwen-family-first (qwen3.5:4b/9b/27b/35b/122b); Gemma only
appears as an alternate in the 32-64 GB tier.

## Resolution: qwen3.5:9b

Matches the 16-32 GB tier preset, confirmed via `ollama show` to have tool-calling capability.
Switching from moondream also changes image-parsing behavior (`ImageConfig.enable_vlm` uses the
same model) — noted as a known trade-off, not evaluated further.

## num_ctx / think: nested vs. top-level (ollama's OpenAI-compatible endpoint)

Both `vlm` and `query_planner` use `provider = "openai"`, which bypasses litellm's `"ollama/"`
prefix detection (`litellm_vlm.py`) and therefore its automatic `num_ctx=16384` / `think` default
injection.

- **`num_ctx`**: a top-level `extra_request_body.num_ctx` was silently ignored — confirmed via
  `journalctl -u ollama` showing `n_ctx_slot = 4096` (ollama's default) regardless
  (2026-09-07). Ollama's `/v1/chat/completions` only honors `options.num_ctx` (nested). Switching
  the model tag to a large-context variant (`gemma4:12b-163k`) was tried instead and rejected: the
  larger KV cache caused `cudaMalloc failed: out of memory` when loaded alongside
  `embedding` (qwen3-embedding:4b) — confirmed on this host.
- **`think`**: setting `think=false` has no effect even nested — ollama's OpenAI-compatible
  endpoint doesn't support the native `think` field at all when reached via `provider="openai"`;
  it instead reads `reasoning_effort` (`"none"/"low"/"medium"/"high"`). An initial attempt used
  `reasoning = "none"` (wrong field name) and got a 400 error: `json: cannot unmarshal string into
  Go struct field ChatCompletionRequest.reasoning of type openai.Reasoning` — `reasoning` is an
  object field, not a string; `reasoning_effort` is correct. Left at the default (`think=false`,
  silently ignored), qwen3.5:9b (which has a thinking capability) generated reasoning tokens on
  every call, adding minutes of latency to JSON-only extraction/expansion calls that don't need
  it. This is believed to be the main cause of `openai.APITimeoutError` (httpx `ReadTimeout`)
  errors seen repeatedly in `journalctl -u podman-openviking` before the fix (2026-09-07) — the
  affected requests topped out around 2050 input tokens, well under the 4096 default `num_ctx`, so
  context truncation was not the cause.

These `num_ctx`/`reasoning_effort` mechanics were specific to ollama's OpenAI-compatible endpoint.
For the current llama.cpp-era configuration (context fixed per preset, `reasoning_effort` still
required), see
[OpenViking embedding and vlm on llama.cpp](2026-09-21-openviking-llama-cpp-migration.md).
