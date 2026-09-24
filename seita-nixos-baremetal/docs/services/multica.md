# Multica (AI coding-agent management workspace)

Implementation: [`modules/multica.nix`](../../modules/multica.nix)

## What it is

A self-hosted deployment of Multica's official `docker-compose.selfhost.yml`
(Next.js frontend + Go backend + PostgreSQL/pgvector), ported to the same
podman-based pattern as Minecraft (`ftb-evolution.nix`) — 3 containers:
`multica-postgres`, `multica-backend`, `multica-frontend`.

Persistence uses podman named volumes (`multica-pgdata`, `multica-backend-uploads`),
same as upstream. These land under `/var/lib/containers` (on the `rpool/var/lib`
dataset), so they ride along with `modules/replication.nix`'s daily replication
for free — no dedicated ZFS dataset was created.

## Access

| URL | What |
|---|---|
| `https://<fqdn>:9444/` | Browser (frontend, via Tailscale Serve) |
| `https://<fqdn>:9445/` | `multica-cli`'s `--server-url` (backend directly) |
| `http://127.0.0.1:3001/` | Frontend, direct (debug, via SSH port-forward) |
| `http://127.0.0.1:8082/` | Backend, direct (debug, via SSH port-forward) |

Why two Serve ports and what each is for: [`docs/network.md`](../network.md#multica-has-two-serve-ports).

Host-side listen ports were chosen to avoid the fixed ports already used by
Grafana (3000) and Open WebUI (8080): frontend → 3001, backend → 8082.

Only the frontend container needs to be reachable externally — it proxies
backend API calls itself via `REMOTE_API_URL` (Next.js SSR). The backend port
is published anyway because `multica-cli`'s local daemon connects to it
directly (see `docs/network.md`).

## Secrets

`POSTGRES_PASSWORD` / `JWT_SECRET` / `MULTICA_VCS_SECRET_KEY` /
`DATABASE_URL` live in `secrets/multica-env.age` (agenix). See
[`docs/secrets.md`](../secrets.md) for the general agenix setup.

`GITHUB_APP_PRIVATE_KEY` is a separate agenix secret
(`secrets/multica-github-app-key.age`) injected via a **podman secret**
rather than through `environmentFiles`. Rationale:
[2026-08-18 Multica GitHub App key needs a podman secret](../decisions/2026-08-18-multica-github-app-key-podman-secret.md).

`~/.multica/config.json` (the CLI's own login token, used by `multica-daemon`)
is out of scope for this repo — it's created by `multica setup`/`multica login`
and never touched by Nix.

## Local agent runtime (`multica-daemon`)

The server containers above only host the web app and API. The actual
`claude`/`opencode` agent processes are run by `multica daemon`, running as a
systemd service (`multica-daemon.service`) rather than the previously-manual
`multica daemon start` (which died on every reboot — noticed 2026-08-12).

Runs with `--foreground`: without it, `multica` double-forks itself into the
background, and systemd loses track of the process and can't manage restarts.
`SIGTERM` was verified on hardware to wait for in-flight tasks (up to 30s)
before a clean exit.

`PATH` is set explicitly (`~/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin`)
because the systemd unit's default `PATH` includes neither the imperatively
`nix profile install`ed tools (`claude`, `rtk`) nor `/run/current-system/sw/bin`
(`opencode`) — agent subprocesses spawned by the daemon need both on `PATH` to
be visible.

## Known limitation: no outbound email

Neither `RESEND_API_KEY` nor `SMTP_HOST` is configured, so Multica can't send
login confirmation codes by email. Find them in
`journalctl -u podman-multica-backend` instead. To fix permanently, add
SMTP or Resend config to `secrets/multica-env.age`.

## Sign-up is open

`ALLOW_SIGNUP` is left at its default `true`. The only access control is
tailnet reachability. To restrict third-party sign-up, add
`ALLOWED_EMAILS`/`ALLOWED_EMAIL_DOMAINS` to the backend container's
`environment`.

## Image tag

Pinned to `latest` (upstream's own default), unlike the FTB Minecraft modpack
which is pinned to an exact version. Because the containers are
`Restart = "always"`, a `ghcr` `latest` update takes effect on the next
restart. Set `MULTICA_IMAGE_TAG` to an explicit release tag if this becomes a
problem.

## Operations

See [`docs/runbooks/multica.md`](../runbooks/multica.md).
