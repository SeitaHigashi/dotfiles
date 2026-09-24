# Ollama

Implementation: [`modules/ollama.nix`](../../modules/ollama.nix)

## Status: disabled since 2026-09-21

`services.ollama.enable = false`. Inference moved to llama.cpp
(`modules/llama-cpp.nix`, `127.0.0.1:8888`) — see
[the migration decision](../decisions/2026-09-23-ollama-to-llama-cpp.md) for why, and for the
three Open WebUI settings that still point at ollama and need manual fixing.

Disabling `services.ollama` also stops, or breaks the backend of:

- OpenViking's `embedding` / `vlm` / `query_planner` (`modules/openviking.nix`) — now points at
  llama.cpp instead.
- Open WebUI's chat and RAG embedding (`RAG_EMBEDDING_ENGINE` below) — the actual connection
  target is Open WebUI's PersistentConfig (DB), not this file; see the migration decision.
- n8n's 4 HTTP workflows and Task Partner Brain (outside this repo).

## How to re-enable

1. Stop `llama-cpp.service` first (VRAM: both cards together have ~13.6 GiB; ollama alone can
   want ~13.3 GiB effective, so the two are not meant to run at once — see
   [GPU VRAM budget](../gpu-vram-budget.md)).
2. Flip `services.ollama.enable` back to `true` in `modules/ollama.nix` (the block below it —
   package, environmentVariables, port, loadModels — was left in place for this).
3. Uncomment the `systemd.services.ollama = { after/wants = [ "nvidia-persistenced.service" ]; }`
   block right below `services.ollama` (it was commented out alongside `enable = false`, since a
   disabled `services.ollama` generates no `ollama.service` unit for that block to attach to).
4. Rebuild.

## Package and acceleration

- `pkgs.unstable.ollama-cuda` — unstable tracks ollama 0.32.4 vs. 25.05's 0.11.10; model support
  is tied directly to the ollama version. This pulls CUDA 12.9, which is why the NVIDIA driver is
  pinned to beta 575 (`modules/gpu.nix`) — revert both together if you revert either.
- `acceleration = "cuda"` is required in addition to `package`: the upstream NixOS ollama module
  rebuilds the package via `cfg.package.override { inherit (cfg) acceleration; }`, and
  `acceleration` defaults to `null`. Without this line, `config.services.ollama.package` reports
  the CUDA build but the unit's actual `ExecStart` resolves to a CPU-only one (missing
  `libggml-cuda.so`), so no GPU is detected — hit on this host before this line was added.

## GPU allocation (2 cards, ~14 GiB combined)

See [GPU VRAM budget](../gpu-vram-budget.md) for the card table and
[GPU topology and allocation](../decisions/2026-08-12-ollama-gpu-topology.md) for why
`CUDA_DEVICE_ORDER` / `CUDA_VISIBLE_DEVICES` / `OLLAMA_SCHED_SPREAD` are set the way they are.

## Model selection

See [model selection benchmark (2026-08-02)](../decisions/2026-08-02-ollama-model-selection.md)
for the sizing rule ("does the total size fit in VRAM", not parameter count) and measured
tok/s numbers behind the `loadModels` list.

## Storage

- `home = "/var/lib/ollama"`. `services.ollama` uses `DynamicUser` (adding a static `user`/`group`
  does not avoid this — the 25.05 module sets `serviceConfig.DynamicUser = true` unconditionally
  whenever `User` is set), so the real state directory is `/var/lib/private/ollama`.
  `/var/lib/ollama` is a symlink to it (same pattern as VictoriaMetrics — see
  `disko/default.nix`).
- Models live on a dedicated ZFS dataset, `rpool/var/lib/ollama` (mounted at
  `/var/lib/private/ollama`, `recordsize=1M`, `compression=off`). Not covered by snapshots or
  syncoid backups — if lost, re-`ollama pull`.
- The upstream `services.ollama.syncModels` option (removes undeclared models) is not in 25.05;
  manually `ollama pull`-ed models are never auto-removed.

## Network

Listens on `0.0.0.0:11434`, but only reachable via the `tailscale0` firewall interface allowlist
— not exposed to the LAN. The API has no authentication, so anyone on the same network could run
or delete models if this were opened further. Unlike Open WebUI, port 11434 is opened directly
(not through Tailscale Serve) because `ollama` CLI clients and `OLLAMA_HOST` can't target a
sub-path base URL.

## Ops notes

```sh
systemctl status ollama open-webui
ollama list          # models on disk
ollama ps            # loaded models and GPU/CPU split
journalctl -u ollama -b | grep "inference compute"   # should show 2 GPU lines
zfs list rpool/var/lib/ollama                         # model storage usage
```

To check whether the 2-card split (`OLLAMA_SCHED_SPREAD`) is actually faster than a single card:

1. Measure as-is:
   ```sh
   curl -s http://127.0.0.1:11434/api/generate \
     -d '{"model":"qwen2.5-coder:7b","prompt":"count from 1 to 50","stream":false}' \
     | grep -o '"eval_count":[0-9]*\|"eval_duration":[0-9]*'
   # tok/s = eval_count / (eval_duration / 1e9)
   ```
2. Remove `OLLAMA_SCHED_SPREAD`, set `CUDA_VISIBLE_DEVICES = "2"`, rebuild, measure again.
3. If the single-card run isn't slower, prefer it — also check the Grafana NVIDIA dashboard for
   whether both cards were actually busy under the split config.
