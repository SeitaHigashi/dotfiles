# Resource priority (cgroup v2)

All cross-service CPU/memory weighting lives in one file,
`modules/resource-priority.nix`, rather than scattered across each service module.

## Why one file

`CPUWeight` is not an absolute value — it's a ratio between siblings in the same
cgroup slice. Every unit listed in `modules/resource-priority.nix` is a direct
sibling under `system.slice`, so the numbers only mean something when compared
against each other. Splitting them across modules risks editing one value and
silently throwing off the intended ratio.

## Podman containers don't inherit their unit's cgroup

Rootful podman does **not** keep a container under its `podman-*.service` cgroup.
`conmon` moves it to `libpod-<id>.scope` directly under `machine.slice`. Measured on
this host:

```
podman-ftb-evolution.service/cpu.weight    = 1000   (podman itself only)
machine.slice/libpod-<id>.scope/cpu.weight = 100    (the JVM is here)
```

So `CPUWeight`/`Nice=` written on `podman-ftb-evolution.service` has **zero** effect
on the Minecraft JVM inside it. The scope name is the container ID, which Nix can't
name directly, so the fix is `--cgroup-parent` on the container
(`modules/ftb-evolution.nix`) pointing at a dedicated `systemd.slices` entry, which
is where the weight is actually set. `Nice=` is skipped entirely for the same
reason — it only affects the podman client process.

`services.ollama` runs under `DynamicUser` but its unit itself sits directly under
`system.slice`, so it's handled the same way as any other service unit (no
cgroup-parent workaround needed).

## tailscaled is prioritized above Minecraft

Two reasons:
1. If tailscaled dies, Grafana and the local-LLM stack become unreachable (both are
   published on `tailscale0` only — see `modules/network.nix`). It's the recovery
   path into the host, so starving it means "can't get in to fix the thing that's
   overloaded."
2. Tailscale runs WireGuard encryption in userspace (`tailscaled`), not the kernel,
   so pushing real traffic over the tailnet (llama.cpp/Grafana responses) actually
   costs CPU.

It's not a constantly-running process, so a high weight barely touches Minecraft's
share in practice — `CPUWeight` is a ratio applied only when there's contention, not
a reservation. Its `MemoryLow` (256M) is a small daemon's safety margin, not a real
budget.

## What doesn't work here

- **`IOWeight`**: ZFS doesn't go through blk-cgroup, so I/O priority control is a
  dead end on this host. Only CPU and memory are tunable.
- **ZFS ARC**: allocated by the kernel, not charged to any cgroup. `arcMaxBytes`
  (`machine.nix`, currently 16 GiB) plus the sum of every `MemoryHigh` below must be
  kept under physical RAM (46 GiB) by hand — nothing enforces this automatically.

## Per-service weights and budgets (current)

| Unit | CPUWeight | MemoryHigh/Low | Notes |
|---|---|---|---|
| `tailscaled` | 2000 | Low 256M | see above |
| `llama-cpp.service` | 20 | High 20G | see below |
| `open-webui.service` | 20 | High 4G | mostly idle except RAG embedding |
| `n8n.service` | 20 | High 2G | Node process spikes during workflow runs |
| `comfyui.service` | (20) | (High 8G) | commented out while ComfyUI is disabled (2026-09-24); see below |
| `comfyui-setup.service` | (20) | — | same |
| `cadvisor.service` | 20 | — | periodically heavy scanning all containers |
| `syncoid-*` (per `services.syncoid.commands`) | 20 | — | nightly bulk transfer, delays are harmless |
| `minecraft.slice` (podman `--cgroup-parent`) | 1000 | Low 10G | `MemoryLow` not `MemoryMax` — a hard cap makes the JVM fail to allocate heap and crash |
| `machine.slice` | 20 | — | catch-all for other podman containers (e.g. `podman-mc-monitor`) |
| `system.slice` | 1000 | — | raised from the default 100 so `tailscaled` isn't capped out at the root level when Minecraft is at 1000 |

`ollama.serviceConfig` is commented out (see `modules/resource-priority.nix`) — kept
in place, not deleted, matching `services.ollama.enable = false` in
`modules/ollama.nix`. See
[2026-09-23 ollama to llama.cpp migration](decisions/2026-09-23-ollama-to-llama-cpp.md)
for why, and [decisions/2026-09-21-ollama-serviceconfig-broken-unit.md](decisions/2026-09-21-ollama-serviceconfig-broken-unit.md)
for why the block must stay commented rather than removed.

### llama-cpp.service budget

`llama-cpp.service`'s `MemoryHigh` (20G) predates the current preset set: it was
sized in 2026-09-21 for the now-deleted `bonsai-max` preset (262144 ctx,
`--no-kv-offload`, which put the KV cache in system RAM rather than GPU VRAM).
Measured RSS under that preset:

| State | RSS |
|---|---|
| loaded, KV cache empty | 10.2 GiB |
| after a 4060-token prompt | 11.0 GiB |

11.0 GiB is **not** a ceiling — it reflects only ~4K of 262144 ctx tokens filled; RSS
keeps growing as context fills, and the 20G budget was headroom for that growth.
`bonsai-max` was removed 2026-09-22; every remaining preset keeps its KV cache on
GPU VRAM, so real RAM demand is now well under this figure. 20G is a soft ceiling
(`MemoryHigh` applies reclaim pressure, doesn't kill), so there's no immediate harm
in leaving it oversized, but there's room to lower it. If `systemd-cgtop` shows
frequent `memory.high` pressure in normal use, revisit this number — watch the sum
against `arcMaxBytes` (16 GiB) and physical RAM (46 GiB). See
[docs/gpu-vram-budget.md](gpu-vram-budget.md) for the VRAM side of this; ollama and
llama-cpp are not expected to run concurrently under load (VRAM runs out first), so
their `MemoryHigh` budgets aren't meant to be summed while ollama is enabled.

### comfyui.service budget

Commented out in `modules/resource-priority.nix` since 2026-09-24 because ComfyUI is disabled;
keeping them active would generate comfyui units with no `ExecStart`. Restore them together with
`enable = true` in `modules/comfyui.nix`.

2026-08-08: raised 6G → 8G. Measured RSS for `main.py` reached 8.1 GiB during image
generation; at 6G the unit was hitting `MemoryHigh` continuously, and
`/proc/pressure/memory`'s "full" average degraded to 45-50% throughout generation
(real, observed harm — not theoretical). The budget was raised to match measured
RSS. `modules/zfs.nix` also sets `zfs_arc_sys_free` so ARC shrinks earlier under
system-wide memory pressure — since ARC isn't charged to any cgroup (see above),
that setting addresses actual memory pressure, while this `MemoryHigh` change only
fixes the reclaim-thrashing symptom for ComfyUI itself.

Self-reported budget total: `arcMaxBytes` (16G) + `ollama` (12G, when enabled) +
`open-webui` (4G) + `n8n` (2G) + `comfyui` (8G) = 42G against 46G physical RAM,
before adding Minecraft's heap (8G, `modules/ftb-evolution.nix`) — already over
physical RAM on paper. `MemoryHigh` is a soft reclaim threshold, not a hard cap, so
this doesn't crash anything by itself, but if ComfyUI and ollama both run heavy
workloads at once and the host is still under pressure, reconsider ollama's 12G
first.
