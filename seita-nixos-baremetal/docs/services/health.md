# seita-health

Implementation: [`modules/health.nix`](../../modules/health.nix)

## What it is

Personal health & meal tracker (Rust/Axum + SQLite), developed at
`~/src/seita-health`. Serves the web UI and the ingest endpoint that n8n
posts step/sleep/weight data to. The CLI and MCP server (`seita-health mcp`)
in the same binary share the DB.

## Wiring

- Package: flake input `seita-health` (`git+file:///home/seita/src/seita-health`,
  its own crane flake), pinned in `flake.lock`. `git+file:` sees committed
  files only. To deploy an app change: commit in `~/src/seita-health`, then
  `nix flake update seita-health` here, rebuild, `switch`, and
  `sudo systemctl restart seita-health` (switch alone may not restart a unit
  whose ExecStart path changed only by store hash — check `systemctl status`).
- Unit `seita-health.service`: `User=seita`, `WorkingDirectory=~/src/seita-health`,
  `serve` on `127.0.0.1:8090` (`SEITA_HEALTH_ADDR`).
- DB: `~/src/seita-health/data/health.db` (`SEITA_HEALTH_DB`), the same file
  the CLI defaults to. Run as `seita` so WAL/SHM files stay owned by one user.
- Exposure: Tailscale Serve `9452 -> 8090`, tailnet only
  (`modules/reverse-proxy.nix`, [network.md](../network.md)):
  `https://seita-nixos-baremetal.tail5426c0.ts.net:9452/`.

## Rollout (2026-10-26, from the interim user unit)

The interim `~/.config/systemd/user/seita-health.service` holds 127.0.0.1:8090,
so the system unit cannot start while it runs. After `switch`:

1. `systemctl --user disable --now seita-health.service` (frees 8090)
2. `sudo systemctl start seita-health.service` (it is also enabled for boot)
3. `rm ~/.config/systemd/user/seita-health.service && systemctl --user daemon-reload`
4. `sudo systemctl restart tailscale-serve` if `tailscale serve status` lacks 9452
5. Check: `curl -s 127.0.0.1:8090/ | head`, and that n8n's next transfer lands.

Steps 1-2 are the only gap in n8n ingest; do them back to back.

## Rollback

Comment out `./modules/health.nix` in `flake.nix` and the 9452 route, rebuild,
and re-create the user unit (`ExecStart=%h/src/seita-health/result/bin/seita-health serve --addr 127.0.0.1:8090`).
