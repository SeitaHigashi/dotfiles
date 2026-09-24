# Monitoring (VictoriaMetrics + Loki + Grafana)

Implementation: [`modules/monitoring.nix`](../../modules/monitoring.nix)

## What this is

Metrics (VictoriaMetrics, scraped by itself every 30s) and logs (Loki + Promtail,
tailing journald) feeding a single Grafana. Design rationale — why this stack exists
at all and why VictoriaMetrics over Prometheus — is in
[the VictoriaMetrics decision record](../decisions/2026-08-25-victoriametrics-over-prometheus.md).

Scrape interval is 30s, not 15s, to avoid taking CPU away from the Minecraft server
tick on this 4C/8T host; 30s granularity is enough for triage.

## Ports (all bind to `127.0.0.1` unless noted)

| Service | Port |
|---|---|
| VictoriaMetrics | 8428 |
| Loki | 3100 |
| Promtail (self health/metrics) | 9080 (default 80 fails to bind unprivileged) |
| Grafana | 3000 (binds `0.0.0.0`, reachable only via `tailscale0` — see Firewall below) |
| node_exporter | 9100 |
| smartctl_exporter | 9633 |
| nvidia_gpu_exporter | 9835 |
| cadvisor | 8081 (8080 avoided as a likely future web-app port) |
| mc-monitor (Minecraft) | 9150 |
| n8n `/metrics` | 5678 (same port as the n8n Web UI) |

## Storage

- VictoriaMetrics data lives on its own ZFS dataset, `recordsize=16K` (see
  `disko/default.nix`), `com.sun:auto-snapshot=false`, and is excluded from syncoid
  replication (`rpool/var/lib` is non-recursive). Metrics are not irreplaceable, and
  their write rate would otherwise inflate hourly snapshot diffs.
- Retention is `180d`. VictoriaMetrics rejects `"6m"` (ambiguous month vs. minute) —
  retention must be given in days.
- Loki keeps 14 days (`336h`), filesystem storage, single binary/instance — enough
  for incident lookback at this scale, and there is spare SSD space.
- `services.loki.ring.kvstore.instance_addr` is pinned to `127.0.0.1`. Left at its
  default, Loki picks the host's LAN static IP as its self-address for the ring and
  dials its own gRPC (9095) out over the LAN; a LAN blip then makes it fail with
  "network is unreachable" repeatedly (confirmed in the journal, 2026-09-02).
- `loki.service` runs as a fixed user (`loki`), not `DynamicUser`, so VictoriaMetrics'
  automatic chown doesn't apply. ZFS creates mountpoints `root:root 0755` by default,
  which blocks Loki from creating `chunks`/`rules`/`compactor`
  (`mkdir /var/lib/loki/rules: permission denied`, confirmed on hardware) — a
  `systemd.tmpfiles.rules` entry chowns it on every boot so a reinstalled dataset
  doesn't need a manual fix.

## Exporters

- node_exporter: default collectors plus `zfs` (ARC hit rate/usage), `systemd` (unit
  state), `processes`. The textfile collector directory
  (`/var/lib/prometheus-node-exporter-text-files`) is fed by
  `modules/zfs-snapshot-metrics.nix`'s timer.
- smartctl_exporter: devices from `machine.nix` (`m.ssd`, `m.hdd1`, `m.hdd2`, by-id
  paths since `/dev/sdX` numbering isn't stable across boots). `maxInterval = "2m"`,
  shorter than the 5-minute scrape interval, so the cache never serves a stale value.
- nvidia_gpu_exporter (utkuozdemir's, parses `nvidia-smi`, not the abandoned
  `mindprince` NVML-based module): runs as a plain systemd unit (`DynamicUser`, `video`
  supplementary group). Chosen because it labels each GPU by uuid/name, distinguishing
  the two different-generation cards reliably.
  - **Limits**: no MIG, XID, PCIe throughput, energy counters, or per-process listing.
    These require either a datacenter GPU or a newer exporter than 1.3.1. Throttle
    reasons and ECC counters do work (their queries fall back to
    `clocks_event_reasons_*` / `ecc_..._sram_*`, which this hardware does emit).
    GPU Xid errors are covered separately by `modules/gpu-xid-metrics.nix`
    (node_exporter textfile collector), because this exporter doesn't surface Xids.
- cadvisor: per-container CPU/mem/IO for podman containers (Minecraft today, future
  n8n container).
  - **Limit**: cadvisor cannot resolve podman container names (it assumes the
    docker/containerd API). There is no `name` label; the aggregation key is the
    cgroup path (`id`) instead — Minecraft is `/minecraft.slice`, other podman
    containers are under `/machine.slice`, host-resident services under
    `/system.slice/<unit>`.
- mc-monitor (itzg/mc-monitor, `export-for-prometheus`): server-list-ping only, no
  RCON (no extra port, no credentials needed). Reports up/down, online player count,
  ping latency — **not TPS**; TPS would need a Forge metrics mod in the modpack,
  which would need re-fixing on every modpack update. Runs as a podman container
  (not in nixpkgs), started after `podman-ftb-evolution.service` so its early pings
  don't just fail and clutter the log.

## Grafana

- Listens on `0.0.0.0:3000`, but only reachable through the `tailscale0` firewall
  interface (see Firewall below) — not the LAN. Interface-based filtering is used
  instead of `http_addr` because the Tailscale IP isn't known at build time.
- `admin_password` is read from a file (`$__file{/var/lib/grafana/admin-password}`,
  Grafana's own file-expansion feature) because this repo has no secret store
  (sops-nix/agenix) — see `docs/secrets.md` for the exception this creates.
  First-time setup (the file is not tracked in git):
  ```sh
  head -c 24 /dev/urandom | base64 | sudo tee /var/lib/grafana/admin-password
  sudo chown grafana:grafana /var/lib/grafana/admin-password
  sudo chmod 0400 /var/lib/grafana/admin-password
  ```
  Forgetting the `chown` fails the service at startup with
  `got error while expanding security.admin_password with expander 'file': permission denied`.
- Anonymous access and sign-up are both disabled — even inside the tailnet, a
  borrowed device should not get free access.
- Analytics reporting/update-checks are disabled (no external phone-home).

### Data sources

- `victoriametrics` — type `prometheus` (VictoriaMetrics speaks the Prometheus
  HTTP API), `uid` pinned to `"victoriametrics"`. **Every dashboard JSON in
  `dashboards/` references this uid by value; changing it breaks all dashboards
  with "No data".** `jsonData.timeInterval` matches the 30s scrape interval so
  graph interpolation doesn't misbehave.
- `loki` — `uid = "loki"`, not default.

### Dashboards

`dashboards/*.json` is loaded as-is via provisioning
(`allowUiUpdates = false` — read-only from the UI; `dashboards.settings.providers`
points `options.path` at the repo's `dashboards/` directory, embedded as a nix-store
path). **The JSON files in git are the single source of truth.**

Edit workflow:
1. In the UI, "Save as..." to make an editable copy and iterate there.
2. Once satisfied, Export → "Export for sharing externally" left **off** — copy the
   JSON.
3. Overwrite the file under `dashboards/` and `nixos-rebuild switch`.
4. Delete the temporary UI copy.
See [runbooks/monitoring.md](../runbooks/monitoring.md) for the exact steps.

Inventory (uids are fixed inside each file):

| File | Source | Content |
|---|---|---|
| `00-overview.json` | own | Minecraft, CPU, memory, ZFS, GPU on one screen |
| `10-node-exporter-full.json` | Grafana.com ID 1860 | host metrics (panels trimmed, see below) |
| `20-cadvisor.json` | Grafana.com ID 14282 | per-container metrics, reworked to key on cgroup path |
| `30-nvidia-gpu.json` | Grafana.com ID 14574 | GPU metrics (panels trimmed, see below) |
| `40-zfs-replication.json` | own | snapshot generations and syncoid replication lag (`modules/zfs-snapshot-metrics.nix`) |
| `70-nix-info.json` | own | installed packages, per-package update status vs. tracked nixpkgs, Hydra build status (`modules/nix-info.nix`) |
| `71-nix-profile-info.json` | own | imperative `nix profile` packages, generations, update status vs. tracked nixpkgs (`modules/nix-profile-info.nix`) |

The three community dashboards were edited on import: `__inputs`/`__requires`
stripped (Grafana refuses to provision a dashboard that still has them) and the data
source pinned to `victoriametrics`. Beyond that, several panels were removed because
this host structurally cannot produce their data (leaving them in just adds "No
data" noise that can hide a real anomaly) — full per-dashboard list and reasoning in
[the community-dashboard-cuts decision record](../decisions/2026-08-25-community-dashboard-panel-cuts.md).
Summary:
- **cadvisor**: no `name` label (see the cadvisor exporter note above); network
  panels removed (cAdvisor only reports network for the root cgroup).
- **nvidia-gpu**: no MIG/XID/PCIe-throughput/energy-counter/process-list panels
  (datacenter-GPU or newer-exporter features this hardware/exporter doesn't have).

## Grafana MCP

`mcp-grafana` (Grafana Labs' own, from `nixpkgs-unstable`) is installed so Claude
Code can read Grafana directly. The package lives in `modules/unstable.nix`; the
*client* configuration is **not** managed by Nix — it's in `~/.claude.json`, which is
MCP client config, not NixOS system config:

- Connects to `http://127.0.0.1:3000` directly, bypassing Tailscale Serve's
  `/grafana/` path — same host, so there's no reason to pay for TLS or sub-path
  prefix stripping, and no risk of `root_url` redirect issues.
- Auth is a Viewer-role service account (`claude-mcp`) token, read from
  `~/.config/grafana-mcp-token` via `GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE` — outside
  the nix store and git, same treatment as the admin password.
  **This file cannot live under `/var/lib/grafana/`** — that directory is
  `0700 grafana:grafana`, and the user running the MCP server (`seita`) cannot
  traverse it (confirmed on hardware: `Permission denied`).
- Started with `--disable-write`. Dashboards remain sourced from `dashboards/*.json`
  in git; MCP cannot write them. `allowUiUpdates = false` means the Grafana API
  can't update provisioned dashboards either way.

## Firewall

Grafana's port is not opened here. Reachability goes exclusively through
`modules/reverse-proxy.nix`'s Tailscale Serve (tailnet port 443); Grafana's own 3000
is not reachable directly, even from the tailnet, and obviously not from the LAN.
`http_addr = "0.0.0.0"` stays as-is — harmless, because `tailscaled` terminates 443
and connects to `127.0.0.1:3000` locally.

To hit port 3000 directly (e.g. to isolate a reverse-proxy problem), use an SSH
tunnel:
```sh
ssh -L 3000:127.0.0.1:3000 seita-nixos-baremetal
```

## Operational checks

```sh
# Scrape target health
curl -s 'localhost:8428/api/v1/targets' | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'

# Both GPUs visible (expect 2 lines)
curl -s localhost:9835/metrics | grep '^nvidia_smi_gpu_info'

# Grafana, from the tailnet
tailscale ip -4   # then http://<that ip>:3000

# Storage usage
zfs list rpool/var/lib/victoriametrics
du -sh /var/lib/victoriametrics

# Loki alive
curl -s localhost:3100/ready

# Labels present (logcli ships with the loki package)
logcli --addr=http://127.0.0.1:3100 labels

# Promtail reading journald
journalctl -u promtail --no-pager -n 50
```
