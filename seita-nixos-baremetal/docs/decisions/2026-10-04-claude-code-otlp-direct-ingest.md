# Claude Code OTLP straight into VictoriaMetrics / Loki

- Date: 2026-10-04
- Scope: Claude Code client env, `dashboards/80-claude-code.json` (no module change)

## Decision

Claude Code pushes OTLP http/protobuf directly to VictoriaMetrics (`:8428/opentelemetry/v1/metrics`)
and Loki (`:3100/otlp/v1/logs`). Details: [claude-code-telemetry.md](../services/claude-code-telemetry.md).

## Why

Both stores already accept OTLP natively, so an OpenTelemetry Collector + Prometheus stack (as in
ColeMurray/claude-code-otel) would add permanent units and a second metrics store for nothing.

## Delta vs cumulative

Claude Code defaults to delta temporality; VictoriaMetrics drops it
(`unsupported delta temporality ... skipping it`,
`vm_protoparser_rows_dropped_total{reason="unsupported_sum_aggregation"}`).
`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` fixes it and is mandatory.

## Rejected

- **OTel Collector + Prometheus (ColeMurray stack)**: extra services; not needed, see above.
- **Prometheus exporter on :9464**: every Claude Code process would try to bind the same port, so
  concurrent sessions collide.
- **Collector converting delta to cumulative**: needs the collector anyway, and per-process counters
  keyed by `session.id` already work with cumulative push.

## Consequences

- Cost series are an estimate, not billing; tokens are the primary measure.
- `increase()` is unreliable on short-lived session series; the dashboard uses `last_over_time`
  over `$__range` and Loki sums.
- Client settings live in `~/.claude/settings.json`, outside Nix; the docs are the only record.
