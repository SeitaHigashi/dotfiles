# n8n (workflow automation)

Implementation: [`modules/n8n.nix`](../../modules/n8n.nix)

## What it is

The catch-all for "hit an HTTP endpoint, transform the result, notify
someone" chores, instead of growing a pile of cron + shell scripts. Can call
the local LLM router (`modules/llama-cpp.nix`, `http://127.0.0.1:8888`) for
anything that needs a model in the loop. Also receives Grafana alert webhooks
(`modules/alerting.nix`) and Discord Gateway events
(`modules/discord-bot.nix`).

## Access

- LAN: `http://<LAN IP>:5678/` (plaintext HTTP — never expose past the LAN).
- Tailnet: `https://<fqdn>:8443/` via Tailscale Serve, root of its own port
  (not a subpath — see [`docs/network.md`](../network.md) for why n8n can't
  share the `443` root the way Grafana does).
- `/metrics` shares the same port as the Web UI (Prometheus format, scraped
  by `modules/monitoring.nix`). No secrets in it, so LAN visibility is fine.

Auth is n8n's own owner-account login; there's no separate gate in front of it.

## Version: tracks nixpkgs-unstable

25.05's n8n is 1.91.3, too old for current node compatibility and upstream
API changes. 25.05's `services.n8n` module has no `package` option (its
`ExecStart` hardcodes `"${pkgs.n8n}/bin/n8n"`), so `modules/n8n.nix` overlays
`pkgs.n8n` itself to `pkgs.unstable.n8n` instead. Safe to do because n8n is a
pure Node application — it doesn't touch the kernel, kernel modules, systemd,
or glibc (see `modules/unstable.nix`'s "leaf packages only" rule).

n8n is non-free (Sustainable Use License); the `allowUnfreePredicate` entry
lives in `modules/unfree.nix` (the only place that option can be defined).

## Configuration is environment variables, not the NixOS module's `settings`

The `services.n8n` NixOS module serializes its `settings` attrset to JSON and
points `N8N_CONFIG_FILES` at it, but **n8n 2.x reads almost everything from
environment variables only**. Verified on hardware: the new settings class
(`@n8n/config`) uses `@Env` decorators that only look at env vars —
`endpoints.metrics.enable` in the JSON file had no effect and `/metrics`
stayed 404. n8n also logs a deprecation warning at startup pointing away from
`N8N_CONFIG_FILES`. So actual configuration lives in
`systemd.services.n8n.environment`; `services.n8n.settings` only keeps `port`,
because the module needs that value at eval time to decide `openFirewall`.

Key environment variables set there:

| Variable | Why |
|---|---|
| `GENERIC_TIMEZONE = "Asia/Tokyo"` | Execution history / schedule-node timestamps |
| `N8N_METRICS = "true"` | Exposes `/metrics` for `modules/monitoring.nix` |
| `N8N_SECURE_COOKIE = "false"` | Without this, n8n issues `Secure`-flagged cookies on any non-localhost plaintext HTTP request; browsers won't store them, so LAN access via `http://<IP>:5678` loops back to the login screen forever. Remove this once TLS is in front of n8n. Kept `false` because the LAN plaintext HTTP path is intentional — flipping it also breaks login from the LAN. |
| `N8N_ENABLED_MODULES = "agents"` | Enables the agents module (needed by workflows built on it) |
| `N8N_PROXY_HOPS = "1"` | Set by `modules/reverse-proxy.nix`. Without it, n8n treats the TCP peer (`tailscaled`, i.e. itself) as the client IP, making rate-limit/audit-log addresses meaningless. |
| `N8N_EDITOR_BASE_URL` / `webhookUrl` | Set by `modules/reverse-proxy.nix` to the tailnet URL, otherwise the UI shows `http://<internal IP>:5678/...` webhook URLs that external services can't reach. |

**`N8N_PATH` is deliberately not set** — see
[`docs/network.md`](../network.md#the---set-path-prefix-stripping-trap) for why.

## `node` on `PATH`

n8n 2.x runs Code nodes in a separate "task runner" process, spawned via
`spawn('node', ...)` (`packages/cli/dist/task-runners/task-runner-process-js.js`)
— a `PATH`-dependent call. The systemd unit's default `PATH` has no `node`,
so without `systemd.services.n8n.path = [ pkgs.unstable.nodejs ]` the log
shows `spawn node ENOENT` and the JS task runner never starts. This is easy
to miss because n8n's own binary launches fine (its shebang points at an
absolute `node` path) — only Code-node execution is affected.
`pkgs.unstable.nodejs` matches the version n8n itself bundles (24.18.0).

The Python task runner ("Python 3 is missing from this system") is a
separate, unaddressed gap — not enabled here. If Python Code nodes are
needed, look at n8n's recommended "external mode" instead.

## Port

`5678` (n8n's default). Existing allocations checked for collisions:
VictoriaMetrics 8428, Grafana 3000, Open WebUI 8080, cadvisor 8081, node
exporter 9100, smartctl exporter 9633, nvidia exporter 9835, minecraft
exporter 9150 — none clash.

## Storage

Default SQLite. Because `services.n8n` runs under `DynamicUser`, the actual
files are at `/var/lib/private/n8n` (`/var/lib/n8n` is a symlink to it). No
dedicated ZFS dataset — it's part of `rpool/var/lib`, gets hourly snapshots,
and rides `modules/replication.nix`'s daily `rpool/var/lib` →
`dpool/backup/var-lib` replication automatically. Unlike VictoriaMetrics or
Ollama's data (high write volume, re-fetchable), this data cannot be
recovered if lost.
