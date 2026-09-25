# AutoMuteUs

Among Us auto-mute Discord bot. Official `automuteus/deploy` compose file ported to
podman in `modules/automuteus.nix` (added 2026-09-25, images pinned to `9.2.1`).

## Containers

| Container | Image | Host port | Role |
|---|---|---|---|
| `automuteus` | `automuteus/automuteus` | — | Discord bot |
| `automuteus-galactus` | `automuteus/galactus` | `127.0.0.1:8123` | broker AmongUsCapture connects to |
| `automuteus-api` | `automuteus/api` | `127.0.0.1:8084` | API used by capture links |
| `automuteus-redis` | `redis:alpine` | — | state |
| `automuteus-postgres` | `postgres:18-alpine` | — | stats DB (volume `automuteus-pgdata`) |

Containers reach each other by name over podman's default network.

## Access (tailnet only)

Exposed through Tailscale Serve (`modules/reverse-proxy.nix`), not Funnel:

- galactus: `https://seita-nixos-baremetal.tail5426c0.ts.net:9449` (bot `HOST`)
- API: `https://seita-nixos-baremetal.tail5426c0.ts.net:9450` (bot `API_SERVER_URL`)

The PC running AmongUsCapture must be on the tailnet. Discord players who don't run
capture need nothing.

## Secret

`secrets/automuteus-env.age` (agenix, KEY=VALUE):

```
DISCORD_BOT_TOKEN=...
POSTGRES_PASS=<random>
POSTGRES_PASSWORD=<same as POSTGRES_PASS>
```

Create/edit: `cd secrets && agenix -e automuteus-env.age -i /etc/age/host.key` (sudo for the key).
Changing the postgres password after first start does not change the existing DB user.

## Discord bot setup

Developer Portal → Bot: enable **Server Members Intent**; invite with scopes `bot` +
`applications.commands` and permissions to manage voice (Mute/Deafen Members, Move
Members), read/send messages, embed links, add reactions, use external emojis.
In Discord: `/new` in a text channel while in voice → click the capture link.

## Operations

```
systemctl status podman-automuteus podman-automuteus-galactus podman-automuteus-api
journalctl -u podman-automuteus -f
```

Update: bump `tag` in `modules/automuteus.nix` (bot/galactus/api share a version).
