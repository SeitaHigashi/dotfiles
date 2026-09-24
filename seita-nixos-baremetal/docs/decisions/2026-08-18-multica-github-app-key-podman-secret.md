# Multica GitHub App key needs a podman secret, not environmentFiles

- Date: 2026-08-18
- Scope: `modules/multica.nix`, `secrets/multica-github-app-key.age`

## Background

Multica's other secrets (`POSTGRES_PASSWORD`, `JWT_SECRET`, `MULTICA_VCS_SECRET_KEY`,
`DATABASE_URL`) are passed to the container via `environmentFiles` (podman's
`--env-file`), which is a `KEY=VALUE`, one-line-per-entry format. Wrapping a
value in double quotes does not make it multi-line — that's Docker Compose
`.env` behavior, and podman's env-file reader is a different implementation
that doesn't support it.

`GITHUB_APP_PRIVATE_KEY` is a multi-line PEM. Verified on hardware
(2026-08-18): writing it as-is truncates the value to the first line (quote
characters included), with no `\n` escaping applied — the result is a
corrupted PEM.

## Decision

Keep the PEM as a plain agenix secret file
(`secrets/multica-github-app-key.age`), register it as a **podman secret**
(`podman secret create --replace multica-github-app-key <file>`), and inject
it into the container as an environment variable via
`--secret=multica-github-app-key,type=env,target=GITHUB_APP_PRIVATE_KEY`.
Podman secrets copy raw bytes into the environment variable without going
through a line-oriented parser, so newlines survive.

The registration runs as a oneshot systemd unit
(`multica-github-secret.service`, idempotent via `--replace`) that
`multica-backend`'s container unit depends on (`after`/`requires`).
