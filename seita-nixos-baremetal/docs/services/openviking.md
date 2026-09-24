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
