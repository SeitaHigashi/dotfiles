# Claude Code telemetry (OTLP direct into VictoriaMetrics / Loki)

Dashboard: [`dashboards/80-claude-code.json`](../../dashboards/80-claude-code.json) (uid `claude-code`).
Decision record: [2026-10-04](../decisions/2026-10-04-claude-code-otlp-direct-ingest.md).
No NixOS module is involved: VictoriaMetrics and Loki already accept OTLP natively
([monitoring.md](monitoring.md)). Only the client (Claude Code) is configured.

## What flows where

| Signal | Endpoint | Store |
|---|---|---|
| Metrics (OTLP http/protobuf) | `http://127.0.0.1:8428/opentelemetry/v1/metrics` | VictoriaMetrics (180d) |
| Logs / events (OTLP http/protobuf) | `http://127.0.0.1:3100/otlp/v1/logs` | Loki (14d), stream label `service_name="claude-code"` |

Measured with Claude Code 2.1.285, VictoriaMetrics 1.130, Loki 3.4.5. Prompt/response content is
redacted by default and stays off.

## Client env block (`~/.claude/settings.json` -> `env`, not managed by Nix)

```json
{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:8428/opentelemetry/v1/metrics",
  "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://127.0.0.1:3100/otlp/v1/logs",
  "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative"
}
```

## Cumulative temporality is mandatory

Claude Code defaults to DELTA temporality for counters. VictoriaMetrics drops delta sums. Measured
without the last variable: journal line
`unsupported delta temporality for claude_code.token.usage ('sum'): skipping it` and the counter
`vm_protoparser_rows_dropped_total{type="opentelemetry",reason="unsupported_sum_aggregation"}`
increasing, with no `claude_code.*` series stored. With `cumulative` the series appear.

## Data shape

- Metrics keep dots in names: `claude_code.token.usage` (`type` = input|output|cacheRead|cacheCreation,
  `model`, `session.id`, `query_source`), `claude_code.cost.usage`, `claude_code.session.count`,
  `claude_code.active_time.total`. Label names also contain dots (`session.id`, `service.name`,
  `user.email`). Select with `{__name__="claude_code.token.usage"}` and quote labels:
  `sum by ("session.id") (...)`. MetricsQL cannot use `\.` (write `[.]`).
- Loki: only `service_name` is a stream label; the rest is structured metadata, queried with
  `| event_name="api_request"` and `| unwrap <field>`.
  - `api_request`: model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
    cost_usd, duration_ms, ttft_ms, query_source, session_id, prompt_id.
  - `hook_execution_complete`: hook_event, hook_name, total_duration_ms, num_hooks.
  - Verified present (2026-10-04): api_request, user_prompt, assistant_response, hook_execution_start,
    hook_execution_complete, hook_registered, plugin_loaded, mcp_server_connection,
    managed_settings_resolved.
  - **Unverified** (listed in the Claude Code docs, count_over_time returned nothing locally):
    tool_result, api_error, skill_activated. The dashboard has no panel that depends on them.

## Finding to track: UserPromptSubmit hook latency

In the first measured run, `total_duration_ms` for `hook_event="UserPromptSubmit"` was 9557 (num_hooks=2;
the OpenViking recall hook is a candidate, not confirmed). SessionStart was 280, Stop 52. The
"Hooks" row of the dashboard plots p50 and max per `hook_event` so this can be followed over time. No
root cause has been established.

## Verify ingestion

```sh
# series exist (should list claude_code.*)
curl -s 'localhost:8428/api/v1/label/__name__/values' | tr ',' '\n' | grep claude_code
# nothing dropped as delta (value must not grow)
curl -s localhost:8428/metrics | grep 'vm_protoparser_rows_dropped_total.*opentelemetry'
journalctl -u victoriametrics --since -10m | grep -i 'delta temporality'
# tokens in the last hour
curl -s localhost:8428/api/v1/query --data-urlencode \
  'query=sum by (type, model) (last_over_time({__name__="claude_code.token.usage"}[1h]))'
# events in Loki
curl -s -G localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (event_name) (count_over_time({service_name="claude-code"}[1h]))'
```

## Caveats

- **Cost is an estimate.** `claude_code.cost.usage` / `cost_usd` are computed from published prices,
  not billing. Raw token counts are the primary measure; the cost row is last on the dashboard.
- **Counters are cumulative per process**, keyed by `session.id`. Never drop `session.id` in a
  relabel/aggregation before the counter is taken, or concurrent sessions merge into one series and the
  counter is corrupted.
- **`increase()` on short-lived series returns 0** (measured: a one-session series over `[6h]` gave 0
  while `last_over_time` gave the real total) because the first sample has no predecessor. The dashboard
  therefore sums `last_over_time(...[$__range])` for totals, which overcounts sessions that started
  before the window start, and uses Loki `api_request` sums for per-interval rates (exact).
- Plain instant selectors go empty quickly after a session ends (staleness); always use a window.
- Retention: Loki 14d, VictoriaMetrics 180d. Per-request log detail disappears after 14d; the metric
  totals stay.
- **PII / cardinality**: labels include `user.email` and account/organization ids, and `session.id` is
  high-cardinality. Data stays on this host (loopback), Loki keeps it 14d. Do not forward these
  endpoints off-host without dropping those labels.
