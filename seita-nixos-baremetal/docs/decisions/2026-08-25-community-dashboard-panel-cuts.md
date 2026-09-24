# Community dashboard imports: what was cut and why

- Date: 2026-08-25 (initial import); updated as panels were removed
- Scope: `dashboards/10-node-exporter-full.json`, `dashboards/20-cadvisor.json`,
  `dashboards/30-nvidia-gpu.json`, provisioned by `modules/monitoring.nix`

## Common changes to all three imports

- `__inputs` / `__requires` removed — Grafana refuses to render a provisioned
  dashboard that still has them and asks to "import" it interactively instead.
- Data source references pinned to uid `victoriametrics` (see
  `docs/services/monitoring.md` for why the uid is fixed).

## `10-node-exporter-full` (Grafana.com ID 1860)

Panels removed because this host cannot produce their data:

- IRQ Detail — the `interrupts` collector is disabled.
- Power Supply — this machine is AC-powered with no battery.
- Hardware Fan Speed — hwmon exposes no fan sensor here.
- TCP Stat Persistent / Transient / Socket Queue (3 panels) — the `tcpstat`
  collector is disabled.

Also adjusted:

- Dropped the `hwmon` `crit_alarm` / `crit_hyst` series and the
  `node_netstat_Tcp_MaxConn` series.
- Removed the `operstate` label filter from "Network Operational Status" — this
  version of node_exporter does not attach `operstate` to `node_network_up`.
- Left the CPU panel's `guest` series alone even though it hides itself via a
  `> 0` filter — that is intentional upstream behaviour, not a data gap.

## `20-cadvisor` (Grafana.com ID 14282)

cAdvisor cannot resolve podman container names (it assumes the docker/containerd
API), so the `name` label never appears. The aggregation key was switched from
`name` to the cgroup path (`id`): Minecraft is `/minecraft.slice`, other podman
containers are under `/machine.slice`, and host-resident services are under
`/system.slice/<unit>`.

The two network panels were removed — cAdvisor only reports network metrics for
the root cgroup (`/`), never per container, so they cannot show anything useful
per contai­ner.

## `30-nvidia-gpu` (Grafana.com ID 14574)

Removed: MIG, NVSwitch/fabric, XID, PCIe throughput, energy counters, and the
compute-process list panels. All of these are either datacenter-GPU-only or
require a newer exporter feature than `nvidia_gpu_exporter` 1.3.1 provides — the
GTX 1660 SUPER and RTX 3060 Ti in this host do not emit them.

Kept: throttle-reason and ECC panels — their queries fall back to
`clocks_event_reasons_*` / `ecc_..._sram_*` series, which do return real data on
this hardware.

## Why bother trimming at all

Leaving "No data" panels in place lets real anomalies get lost in the noise of
expected gaps, so every panel that structurally cannot show data on this host was
removed rather than left blank.
