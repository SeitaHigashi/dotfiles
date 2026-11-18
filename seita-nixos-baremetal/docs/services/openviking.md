# OpenViking

Implementation: [`modules/openviking.nix`](../../modules/openviking.nix)

## What it is

[OpenViking](https://github.com/volcengine/openviking) (ByteDance/Volcengine) is a self-evolving
context database for AI agents — combines agent memory, knowledge RAG, and skills management. Run
from the official OCI image (`ghcr.io/volcengine/openviking:latest`) via podman, the same pattern
used for Multica (`modules/multica.nix`) and FTB Evolution (`modules/ftb-evolution.nix`). Not
packaged in nixpkgs — as with Multica's backend/frontend, pulling the upstream `latest` image
directly was judged simpler than packaging it.

## Inference backend

Uses the local llama.cpp router (`modules/llama-cpp.nix`, `127.0.0.1:8888`, OpenAI-compatible) for
both embedding and generation — no external API key. Previously used `services.ollama`
(`modules/ollama.nix`, now disabled); see
[the ollama → llama.cpp migration](../decisions/2026-09-23-ollama-to-llama-cpp.md) and
[the OpenViking-specific part of that migration](../decisions/2026-09-21-openviking-llama-cpp-migration.md).

- `embedding`: llama-swap's `embedding` preset (Qwen3-Embedding-4B), truncated client-side to 2048
  dimensions to match the bootstrap collection shipped in the image (which expects 2048; a 768-dim
  model produces a `Dense vector dimension mismatch` at startup). See the migration decision above
  for why truncation from the model's native 2560 dimensions is safe, and why
  `allow_metadata_override = true` is required.
- `vlm` (despite the name, the general-purpose LLM used for memory extraction, query expansion,
  and summarization — not just image understanding) and `query_planner` both use llama-swap's
  `bonsai` preset (Ternary-Bonsai-2-27B), chosen after moondream and gemma4:12b both failed
  reliability testing — see
  [vlm selection](../decisions/2026-09-08-openviking-vlm-selection.md) and
  [model consolidation](../decisions/2026-09-06-openviking-model-consolidation.md) history (from
  the ollama era; the reasoning behind sharing one model between `vlm` and `query_planner`, and
  the minimum-model-size rule, still applies).
- Both `vlm` and `query_planner` set `extra_request_body = { reasoning_effort = "none"; }` to
  suppress reasoning tokens on JSON-only extraction/expansion calls — see the migration decision
  for the mechanism (llama.cpp always splits reasoning into `reasoning_content`; "none" makes it
  empty).
- `vlm` additionally sets `max_tokens = 6144` (2026-10-31). Memory extraction (~32K-token prompt,
  temperature 0) was running away to ~10K generated tokens and hitting the 600 s client timeout,
  repeating for hours (retry ×3 × ×3) while holding bonsai's single slot (`-np 1`) and blocking
  image generation. Healthy extractions generate ~100–2,000 tokens. 6144 fits the timeout:
  ~117 s prefill + 6144 / 17 t/s ≈ 480 s. Revert by dropping `max_tokens`. Unverified: how
  OpenViking handles `finish_reason=length`; check `eval time` token counts in bonsai's log after switch.
- `vlm` also sets `max_concurrent = 1` (2026-11-09). Measured on llama-swap (7 days, `AsyncOpenAI`
  chat calls): 237×200 / 420×502, 398 of the 502s at exactly 600 s (client timeout; llama-swap logs a
  cancelled client as 502). `max_tokens = 6144` was already live (`/slots` showed `n_predict 6144`,
  ~15.5 t/s decode), so the 600 s was mostly queue wait, not generation: bonsai has one slot
  (`-np 1`), OpenViking's `vlm.max_concurrent` defaults to 32, and on 2026-11-09 00:00–05:30
  ~5.5 requests (max 8) were in flight at each request start. n8n also posts to bonsai (5 of the 6
  successes that night were n8n, 450–563 s), so some contention remains. Raising `vlm.timeout`
  (default 600 s, valid key in `vlm_config.py`) was rejected: it lengthens the queue wait without
  adding capacity. Revert by dropping `max_concurrent`. Verify after switch + `podman-openviking`
  restart: 502 count at 600 s in `journalctl -u llama-cpp` should fall. Unverified: that the
  container image (`:latest`) honours `vlm.max_concurrent` as the host's 0.4.17 install does.
  Other 2026-11 anomaly not investigated: 367 × HTTP 500 in <120 s on 2026-11-05.
- `vlm.model = "orfree/overflow"` (2026-11-15, SEI-279; was `bonsai`). Measured from llama-swap
  `/api/metrics/activity` 17:17–19:31 (start = end − duration, bonsai is `-np 1`): 25 of 41 OV
  calls arrived while bonsai was busy (so `max_concurrent = 1` does not serialize OV in practice),
  queue wait p50 60 s / p75 184 s, service p50 135 s; 3 of 4 600 s timeouts were mostly wait
  (414 / 224 / 353 s). All 41 were memory extraction (45K–169K chars, 12K–57K prompt tokens);
  `query_planner` had 0 calls, so it stays on `bonsai`. The shim sends to OpenRouter :free only
  while bonsai is busy; otherwise local. Free cap measured 50 requests/day (`/api/v1/key`, no
  credits); past the cap everything is local again (old behaviour). nemotron passed OV's own
  `intent_analysis` and `ov_wm_v2_update` tool-call prompts 6/6 each (synthetic input,
  `~/lab/2026-11-ov-orfree/`). Not tested: the multi-turn `ExtractLoop`, and one loop mixing
  bonsai and nemotron turns. Revert: `model = "bonsai"` in `modules/openviking.nix`.
- `embedding.max_input_tokens = 2500` (2026-11-09; OpenViking default 4096). Since `7543de5`
  (2026-11-08, `embedding -c 8192 → 4096`) 18 embeddings failed with HTTP 400 `exceed_context_size`
  (4,503–5,865 real tokens vs `n_ctx` 4096; CRITICAL `Failed to generate embedding`, the document
  gets no vector). OpenViking's estimate undercounts Qwen3 tokens ≈1.43–1.45× (5,865 / 4096), so
  2500 estimated ≈ 3,600 real < 4096. `-c 4096` is a VRAM figure for lfm3 coexistence and stays;
  the input is shrunk instead. Cost: input longer than ~2,500 estimated tokens is cut, so only the
  head of a long document is searchable (it previously got no vector at all; before 7543de5 up to
  ~5.9K tokens were embedded in full). Recall impact not measured. Revert by dropping the key
  (or raise `-c` to 8192 to embed in full). Unverified: that every code path honours it (the field
  is documented as the raw-text-fallback limit); recount `Failed to generate embedding` after restart.
  The separate bonsai overflow (long-term extraction prompts of 83K–159K tokens vs `-c 81920`,
  15 × `Phase 2 step long_term failed` since 2026-11-05) has no OpenViking knob and is not fixed.

## Secrets

A `0.0.0.0`-listening OpenViking server refuses to start without `root_api_key` set. Since
`ov.conf` mixes secret and non-secret fields in one file, this isn't injected via a `--secret` flag
(unlike Multica) — instead, the `openviking-conf` oneshot service (`before =
["podman-openviking.service"]`) merges the static JSON template with `root_api_key` (read from
agenix) using `jq`, before the container starts.

## Network

`--network=host`, bound to `0.0.0.0:1933`, restricted to the `tailscale0` firewall interface — not
exposed to the LAN. Not routed through `modules/reverse-proxy.nix` (Tailscale Serve), for the same
reason as ollama's 11434: API clients can't target a sub-path base URL. Host networking (rather
than podman's rootful bridge/NAT) was chosen because bridge networking made reachability to the
host's ollama/llama.cpp endpoint and the firewall's interface filtering behavior unreliable (FTB
Evolution works around a similar issue differently, by binding to a LAN-only address — see
`modules/ftb-evolution.nix`).

## Data

`/var/lib/openviking` (on `dpool`, the HDD mirror — see `disko/default.nix`), bind-mounted into
the container at `/app/.openviking`.

## Ops notes

```sh
systemctl status openviking-conf podman-openviking
journalctl -u podman-openviking -f

# reachability from elsewhere on the tailnet (LAN and 127.0.0.1 are firewalled off)
curl http://<tailscale-ip>:1933/...

zfs list dpool/var/lib/openviking   # storage usage
```

Procedures (image update, secret rotation) are in
[the OpenViking runbook](../runbooks/openviking.md).
