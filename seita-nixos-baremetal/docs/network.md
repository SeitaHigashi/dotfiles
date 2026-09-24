# Network boundary

Implementation: [`modules/network.nix`](../modules/network.nix), [`modules/reverse-proxy.nix`](../modules/reverse-proxy.nix)

## Shape

- `exporter`s and VictoriaMetrics bind `127.0.0.1` only — never exposed.
- HTTP services are consolidated behind one Tailscale Serve/Funnel entry point
  (`modules/reverse-proxy.nix`). TLS termination is `tailscaled`, certificates
  are fetched automatically for the MagicDNS name.
- Minecraft (25565) and n8n (5678) are the only services opened to the LAN.

## Why Tailscale Serve, not nginx + ACME

This repo has no secrets store for TLS certificates. `nginx` + ACME would need either:

- HTTP-01, which requires opening 80/tcp to the WAN (breaks the tailnet-only posture), or
- DNS-01, which requires an API token (a second secret to manage).

Tailscale Serve lets `tailscaled` obtain and renew Let's Encrypt certificates
for the MagicDNS name itself, with zero secrets and no extra resident unit.

The `Serve` configuration lives only in `/var/lib/tailscale` state (not git,
not the Nix store) by design of the tool, which conflicts with this repo's
"config lives in git" rule. `modules/reverse-proxy.nix` works around this by
wrapping `tailscale serve reset` + one `tailscale serve`/`funnel` command per
route in a oneshot systemd unit (`tailscale-serve.service`), so the `routes`
list in that file is the single source of truth — remove a line there and the
mount disappears from the live host on the next `switch`.

**Caveat**: `RemainAfterExit = true` means the unit re-runs when its *own*
content changes (e.g. a route added/removed), but the FQDN itself never
appears in `ExecStart` (only `--set-path` and port numbers do — the FQDN is
only used in comments and `root_url`). So renaming the host or changing the
tailnet does **not** trigger a restart automatically; run
`sudo systemctl restart tailscale-serve` by hand after such a rename (hit
during the 2026-08-01 `seita-nix-baremetal` → `seita-nixos-baremetal` rename).

## The `--set-path` prefix-stripping trap

Tailscale Serve strips the mount prefix before forwarding to the backend: a
request to `/grafana/login` arrives at the backend as `/login`. An app placed
under a subpath therefore needs the asymmetric setting "listen at `/`, but
generate URLs with the subpath prefix" — this is why each app below needs its
own follow-up config. Apps that can't do this at all get their own port at
the Serve root instead.

| App | Placement | Why |
|---|---|---|
| Open WebUI | `443` root | No `root_path`/subpath support at all — checked source (open-webui 0.6.9's `open_webui/main.py`, no `root_path` in the whole codebase). Static assets and API calls break under any subpath. |
| Grafana | `/grafana` under `443` | `root_url` absolute + `serve_from_sub_path = false` makes Grafana listen at `/` but generate `/grafana/...` URLs — matches the prefix-stripping proxy. Setting `serve_from_sub_path = true` causes an infinite redirect loop (verified: `curl -L` hits `--max-redirs`). |
| n8n | `8443` root (separate port) | `N8N_PATH` only rewrites the frontend's `window.BASE_PATH`; the backend keeps listening at `/`. Under a prefix-stripping proxy that alone works, but it breaks the LAN's direct `http://<LAN IP>:5678/` access — the HTML references `/n8n/assets/*.js` but the backend serves its catch-all HTML there instead (verified on hardware: white screen). Since n8n must stay open on the LAN too, it gets its own port with no `N8N_PATH` set. |
| ComfyUI | `9443` root (separate port) | Frontend calls the API via absolute paths; no reverse-proxy subpath support. `443`/`8443` are taken. |
| Multica (frontend) | `9444` root (separate port) | Next.js frontend assumes `window.origin`-relative absolute paths (`/api`, `/ws`); incompatible with prefix stripping. |
| Multica (backend) | `9445` root (separate port) | See "Multica has two Serve ports" below. |
| fukurou-webui | `9446` root (separate port) | Single dev test page, `index.html` embedded in the binary — no subpath awareness. |
| fukurou-server (wss) | `9447` root (separate port) | See "fukurou-server wss" below. |
| llama.cpp | `9448` root (separate port), 2026-09-21 | OpenAI-compatible clients can't always put a path in their base URL, same reasoning as Open WebUI. `443`/`8443` taken. **No auth** — tailnet-reachable but any tailnet member can use the model; deliberately not put on Funnel. |
| Ollama | not on Serve at all | See below. |

## Ollama bypasses Serve entirely

Ollama listens on `tailscale0:11434` directly (`modules/ollama.nix`), not
through `modules/reverse-proxy.nix`. Two reasons:

1. The `ollama` CLI and `OLLAMA_HOST`-based clients can't put a path in their
   base URL, so a `/ollama`-prefixed mount wouldn't help them anyway.
2. **Mounting Ollama at `/ollama` breaks Open WebUI.** Open WebUI (on the
   `443` root) proxies `/ollama/*` to Ollama itself, authenticated. Serve's
   longest-prefix-wins routing would steal that path out from under Open
   WebUI. Symptom: Settings → Connections spins forever in the admin UI, with
   `GET https://<fqdn>/ollama/config` returning 404 in devtools (Ollama has no
   `/config` endpoint — that 404 is Ollama answering, not Open WebUI's
   normal 401). Confirmed on hardware 2026-08-04:
   `127.0.0.1:8080/ollama/config` → 401 (exists, needs auth);
   `127.0.0.1:11434/config` → 404 (route doesn't exist). Removed the mount
   the same day.

As of 2026-09-21, `modules/ollama.nix` has `enable = false` (superseded by
llama.cpp — see [2026-09-23 ollama → llama.cpp](decisions/2026-09-23-ollama-to-llama-cpp.md)),
so nothing currently listens on 11434.

## Multica has two Serve ports

- `9444` → `multica-frontend` (Next.js SSR). This is what browsers use.
- `9445` → `multica-backend` directly. `multica-cli`'s local daemon/runtime
  isn't a browser and can't go through the Next.js SSR proxy — it appears to
  distinguish "is this the backend itself" by content-type/response headers,
  and treats the frontend's HTML response as "not reachable" (verified on
  hardware 2026-08-12). So `--server-url` for `multica-cli` must point at the
  `9445` backend URL, not the `9444` frontend URL. See
  [`docs/services/multica.md`](services/multica.md).

## Multica GitHub webhook: Funnel through a local nginx

GitHub's webhook delivery servers are outside the tailnet, so tailnet-only
Serve can't reach them — this needs `tailscale funnel`, which is **port-level
on/off**, with no path-level restriction.

`443` (Open WebUI) and `8443` (n8n) can't be funneled without exposing every
path on those ports to the public internet, so the webhook gets a dedicated
port. Tailscale Funnel only works on ports `443`/`8443`/`10000` (a hard
platform limit) — with the first two ruled out, `10000` is the only option
left.

Port `10000` doesn't mount `multica-backend` (8082) directly: that would
expose every authenticated `multica-cli` API alongside the webhook endpoint.
Instead it mounts a local nginx (`127.0.0.1:8083`, defined in
`modules/reverse-proxy.nix`) that allows only `= /api/webhooks/github` and
404s everything else, before forwarding to the backend. This nginx does
**not** terminate TLS (Funnel does that, then forwards plaintext HTTP to
`127.0.0.1`), so it doesn't reintroduce the "nginx needs a certificate secret"
problem that ruled out nginx as the general reverse proxy.

## fukurou: two ports, one wss-only

- `9446` → `fukurou-webui` (dev test page, HTTPS via Serve).
- `9447` → `fukurou-server`, but only for the `wss://` path used by
  `fukurou-webui`. `fukurou-server` itself is plain WebSocket with no TLS
  (already reachable directly at `tailscale0:7878`, see `modules/fukurou.nix`)
  — but once `fukurou-webui` is served over HTTPS, browsers block a
  `wss://` page from opening a plaintext `ws://` connection as mixed content.
  Confirmed on hardware 2026-08-30 (`ws://` connection failures from the
  HTTPS-served page). The `ws://:7878` direct route stays, for non-browser
  clients.

## Firewall / port list

Evaluated from `config.networking.firewall` on 2026-09-24.

Open on `tailscale0` (`networking.firewall.interfaces."tailscale0".allowedTCPPorts`):

| Port | Service | Opened by |
|---|---|---|
| 443 | Open WebUI (`/`), Grafana (`/grafana/`) via Serve | `modules/reverse-proxy.nix` (`routes`) |
| 8443 | n8n via Serve | `modules/reverse-proxy.nix` |
| 9443 | ComfyUI via Serve | `modules/reverse-proxy.nix` |
| 9444 | Multica frontend via Serve | `modules/reverse-proxy.nix` |
| 9445 | Multica backend via Serve | `modules/reverse-proxy.nix` |
| 9446 | fukurou-webui via Serve | `modules/reverse-proxy.nix` |
| 9447 | fukurou-server (wss) via Serve | `modules/reverse-proxy.nix` |
| 9448 | llama.cpp via Serve | `modules/reverse-proxy.nix` |
| 10000 | Multica GitHub webhook (Funnel, public internet) | `modules/reverse-proxy.nix` |
| 1933 | OpenViking (direct) | `modules/openviking.nix` |
| 7878 | fukurou-server (direct WebSocket) | `modules/fukurou.nix` |
| 8188 | ComfyUI (direct) | `modules/comfyui.nix` |
| 11434 | Ollama (direct) — **no listener** while Ollama is disabled | `modules/ollama.nix` |

**Grafana `3000` and Open WebUI `8080` are not open on tailscale0** — use Serve, or `ssh -L`
for troubleshooting.

Open on all interfaces (`networking.firewall.allowedTCPPorts`): SSH `22`, n8n `5678`, Minecraft `25565`.

Listening addresses (separate question from firewall exposure above):
VictoriaMetrics `8428` / Grafana `3000` / node exporter `9100` / smartctl
exporter `9633` / nvidia-gpu exporter `9835` / cadvisor `8081` /
minecraft-exporter `9150` / n8n `5678` (Web UI and `/metrics` share the port).

LAN-open ports (not tailnet-gated): Minecraft `25565` (publish goes through
podman DNAT, which the NixOS firewall can't filter — the listen address
itself is pinned to the LAN static IP instead) and n8n `5678` (plaintext
HTTP; never expose past the LAN).

## Secrets

Agenix secrets referenced by the services in this doc (Multica's Postgres
password, JWT secret, GitHub App key; discord-bot's Discord token) are
documented in [`docs/secrets.md`](secrets.md).
