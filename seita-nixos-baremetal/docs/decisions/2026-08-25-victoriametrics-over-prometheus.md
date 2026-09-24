# VictoriaMetrics instead of Prometheus

- Date: 2026-08-25
- Scope: `modules/monitoring.nix`, `services.victoriametrics`

## Why monitoring exists at all

This host runs Minecraft (podman) permanently, with n8n and Ollama (later llama.cpp)
sharing it. CPU is a Ryzen 3 3300X (4C/8T) and the two GPUs are different generations.
Without a way to tell *who* is responsible when "Minecraft feels slow", this kind of
co-tenancy is not operable. Monitoring is the basis for that triage.

Metrics alone answer "since when is this abnormal" but rarely "why". Logs are pulled
into the same Grafana (Loki + Promtail) for that reason — podman's default log driver
is journald, so collecting journald once covers both systemd services and containers
(including Minecraft).

## Why VictoriaMetrics, not Prometheus

- PromQL-compatible, so Grafana's Prometheus data source works unchanged, and most
  dashboards found online can be reused as-is.
- Substantially lower memory and disk-write footprint than Prometheus. This host takes
  hourly ZFS snapshots, so write volume feeds directly into snapshot-diff bloat —
  this matters here.
- `prometheusConfig` lets a single VictoriaMetrics binary do the scraping itself.
  Neither Prometheus nor vmagent is needed, one fewer permanent unit.

## Listening policy

Exporters and VictoriaMetrics itself all listen on `127.0.0.1` only. Grafana is the
only thing reachable from outside, and only over the `tailscale0` interface (see the
firewall section of `docs/services/monitoring.md`). Not exposed to the LAN.
