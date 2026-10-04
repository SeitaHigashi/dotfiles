# Homepage

Personal static site, served by `static-web-server` (Rust) and exposed to the tailnet only.

- Module: `modules/homepage.nix`; site source: `homepage/` (plain HTML for now).
- Access: `https://<host>.<tailnet>.ts.net:9451/` via Tailscale Serve (`modules/reverse-proxy.nix`, `funnel` unset = tailnet only).
- Backend: `127.0.0.1:8085`, loopback only. Ports are listed in `docs/network.md`.
- Port history: `9449`/`9450` were already taken by AutoMuteUs, so `9451` was used.

## Editing
Edit files under `homepage/`, then `sudo nixos-rebuild switch --flake .#seita-nixos-baremetal`.
The site is copied into the Nix store, so content changes need a rebuild. `static-web-server.service`
restarts on switch because its `root` store path changes.

## Later
If content churn grows, move `homepage/` to its own repo as a non-flake flake input
(`inputs.homepage = { url = ...; flake = false; }`) and keep this module here.
