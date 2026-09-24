# seita-nixos-baremetal

NixOS configuration for the single bare-metal server `seita-nixos-baremetal`. It runs on ZFS
(SSD×1 + HDD×2 mirror); the disk layout is declared with [disko](https://github.com/nix-community/disko).

This file is the table of contents. The content lives in `docs/`. Working rules for Claude Code
are in [CLAUDE.md](CLAUDE.md).

## Where things go

| Place | What goes there |
|---|---|
| Comments in `.nix` | Line-level constraints only ("measured ceiling, do not raise", "port 8080 is taken"). 1-4 lines plus a pointer into `docs/` |
| [`docs/services/`](docs/services/) | Per-service overview, usage, caller-facing gotchas |
| [`docs/runbooks/`](docs/runbooks/) | Procedures: updating, replacing hardware, recovering |
| [`docs/decisions/`](docs/decisions/) | Design decisions and their history, `YYYY-MM-DD-<slug>.md`, including rejected alternatives |
| `docs/*.md` (top level) | Topics spanning several modules (VRAM budget, network boundary, secrets, …) |

When a `.nix` file changes, the docs it points to are updated in the same commit.

## Cross-cutting

- [Storage layout (ZFS / disko)](docs/storage-zfs.md) — pools, datasets and why each lives where, ARC/NVMe tuning, replication
- [Network boundary](docs/network.md) — Tailscale Serve routing, the `--set-path` prefix trap, open ports
- [GPU driver](docs/gpu-driver.md) — NVIDIA driver, display wiring, two-card caveats
- [GPU and VRAM budget](docs/gpu-vram-budget.md) — card index mapping, per-card residents, measured limits
- [Resource priority (cgroup v2)](docs/resource-priority.md) — CPU/memory weights across services, podman cgroup-parent quirk
- [Secrets (agenix)](docs/secrets.md) — where secrets live, adding one, the Grafana admin-password exception
- [nixpkgs channels](docs/nixpkgs-channels.md) — stable/unstable split, unfree allowlist

## Services

- [llama.cpp](docs/services/llama-cpp.md) — llama-swap + PrismML fork: local LLM, embeddings, Laya
- [Ollama](docs/services/ollama.md) — disabled since 2026-09-21; how to re-enable
- [Open WebUI](docs/services/open-webui.md) — browser chat UI, PersistentConfig gotcha
- [OpenViking](docs/services/openviking.md) — context DB for AI agents
- [ComfyUI](docs/services/comfyui.md) — image generation, **disabled** since 2026-09-24; how to re-enable
- [fukurou](docs/services/fukurou.md) — voice conversation loop (STT → LLM → TTS)
- [Desktop](docs/services/desktop.md) — KDE Plasma (X11) for the projector
- [Monitoring](docs/services/monitoring.md) — VictoriaMetrics, Loki, Grafana, dashboards, Grafana MCP
- [Alerting](docs/services/alerting.md) — Grafana alert rules, conventions, n8n notification
- [Textfile-collector metrics](docs/services/textfile-metrics.md) — nix-info, nix-profile-info, zfs-snapshot, gpu-xid
- [n8n](docs/services/n8n.md) — workflow automation
- [Multica](docs/services/multica.md) — self-hosted AI coding-agent workspace
- [Discord bot](docs/services/discord-bot.md) — Gateway → n8n webhook forwarder
- [Minecraft (FTB Evolution)](docs/services/minecraft.md) — podman-hosted modpack server

## Runbooks

- [Install](docs/runbooks/install.md) — SSH-automated and manual install
- [install.sh reference](docs/runbooks/install-script.md) — what the installer does, options, `disks.env` fields
- [Pool benchmark](docs/runbooks/bench-pools.md) — `bench-pools.sh` method and how to read the results
- [ZFS operations](docs/runbooks/zfs-operations.md) — scrub, snapshots, disk replacement, backup, adding a dataset to a live system
- [ZFS troubleshooting](docs/runbooks/zfs-troubleshooting.md) — import failures, degraded pools, evaluation errors
- [GPU driver](docs/runbooks/gpu.md) — driver bumps, GPU swaps
- [llama.cpp](docs/runbooks/llama-cpp.md) — fork updates, GPU swap, Laya setup, crash loops
- [ComfyUI](docs/runbooks/comfyui.md) — venv/CUDA setup, VRAM guard
- [fukurou](docs/runbooks/fukurou.md) — rebuild/restart, Vulkan GPU troubleshooting
- [OpenViking](docs/runbooks/openviking.md) — image update, secret rotation
- [Multica](docs/runbooks/multica.md) — image update, secret rotation, status checks
- [Monitoring](docs/runbooks/monitoring.md) — edit a dashboard, add an exporter
- [Alerting](docs/runbooks/alerting.md) — add, change or delete a rule; test the notification path
- [Textfile-collector metrics](docs/runbooks/textfile-metrics.md) — manual verification

## Decisions

- 2026-07-30 [NVMe dropout made the system unbootable](docs/decisions/2026-07-30-nvme-dropout-made-system-unbootable.md)
- 2026-07-31 [Minecraft restarting on a 60-second tick](docs/decisions/2026-07-31-minecraft-restarting-on-60s-tick.md)
- 2026-08-02 [Ollama model selection](docs/decisions/2026-08-02-ollama-model-selection.md)
- 2026-08-05 [agenix needs an ssh-to-age host key](docs/decisions/2026-08-05-agenix-ssh-to-age-host-key.md)
- 2026-08-05 [ComfyUI: pip venv, fixed user, dpool dataset](docs/decisions/2026-08-05-comfyui-pip-venv.md)
- 2026-08-08 [ComfyUI: disable dynamic VRAM](docs/decisions/2026-08-08-comfyui-disable-dynamic-vram.md)
- 2026-08-12 [Ollama GPU topology](docs/decisions/2026-08-12-ollama-gpu-topology.md)
- 2026-08-18 [Multica GitHub App key needs a podman secret](docs/decisions/2026-08-18-multica-github-app-key-podman-secret.md)
- 2026-08-25 [VictoriaMetrics instead of Prometheus](docs/decisions/2026-08-25-victoriametrics-over-prometheus.md)
- 2026-08-25 [Community dashboard panel cuts](docs/decisions/2026-08-25-community-dashboard-panel-cuts.md)
- 2026-08-25 [Alerting split from monitoring](docs/decisions/2026-08-25-alerting-split-from-monitoring.md)
- 2026-08-25 [Alert rule shape: instant query + threshold](docs/decisions/2026-08-25-mkrule-instant-query-shape.md)
- 2026-08-25 [Projector HDMI moved to the 3060 Ti](docs/decisions/2026-08-25-projector-hdmi-to-3060ti.md)
- 2026-08-28 [GPU Xid failure monitoring](docs/decisions/2026-08-28-gpu-xid-monitoring.md)
- 2026-09-06 [OpenViking model consolidation](docs/decisions/2026-09-06-openviking-model-consolidation.md)
- 2026-09-08 [OpenViking vlm selection](docs/decisions/2026-09-08-openviking-vlm-selection.md)
- 2026-09-21 [PrismML fork build method](docs/decisions/2026-09-21-llama-cpp-prism-build.md)
- 2026-09-21 [Pin nixpkgs-unstable to a cached revision](docs/decisions/2026-09-21-pin-nixpkgs-unstable.md)
- 2026-09-21 [Keep the ollama resource-priority block commented out](docs/decisions/2026-09-21-ollama-serviceconfig-broken-unit.md)
- 2026-09-21 [OpenViking on llama.cpp](docs/decisions/2026-09-21-openviking-llama-cpp-migration.md)
- 2026-09-22 [From the fork's router to llama-swap (matrix)](docs/decisions/2026-09-22-llama-swap-matrix.md)
- 2026-09-22 [ComfyUI stopped by default](docs/decisions/2026-09-22-comfyui-disabled-by-default.md)
- 2026-09-22 [fukurou: Vulkan GPU split](docs/decisions/2026-09-22-fukurou-vulkan-gpu-split.md)
- 2026-09-23 [Laya colocated in llama-swap](docs/decisions/2026-09-23-laya-in-llama-swap.md)
- 2026-09-23 [Migration from ollama to llama.cpp](docs/decisions/2026-09-23-ollama-to-llama-cpp.md)
- 2026-09-23 [3060 Ti power limit for fan noise](docs/decisions/2026-09-23-3060ti-power-limit.md)
- 2026-09-23 [Repology → direct nix eval](docs/decisions/2026-09-23-repology-to-direct-nix-eval.md)
- 2026-09-24 [ComfyUI disabled](docs/decisions/2026-09-24-comfyui-disabled.md)
