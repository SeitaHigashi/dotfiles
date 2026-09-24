# Multica: operations

Implementation: [`modules/multica.nix`](../../modules/multica.nix)

## Status checks

```sh
systemctl status podman-multica-postgres podman-multica-backend podman-multica-frontend
journalctl -u podman-multica-backend -f
systemctl status multica-daemon         # local agent runtime
multica daemon status
multica daemon logs -f
```

## Image update

```sh
podman pull ghcr.io/multica-ai/multica-backend:latest
podman pull ghcr.io/multica-ai/multica-web:latest
systemctl restart podman-multica-backend podman-multica-frontend
```

## Rotating secrets

```sh
nix-shell -p openssl age --run '...'   # generate new POSTGRES_PASSWORD / JWT_SECRET / MULTICA_VCS_SECRET_KEY
```

Re-encrypt `secrets/multica-env.age` with `age -r <host public key from secrets/secrets.nix>`,
then `switch`.

- Changing `JWT_SECRET` invalidates every existing session.
- Changing `POSTGRES_PASSWORD` alone is not enough — this container setup
  only applies `POSTGRES_PASSWORD` on first boot, so it also needs a manual
  `ALTER USER` against the running Postgres.

## Login emails don't arrive

No SMTP/Resend configured (see [`docs/services/multica.md`](../services/multica.md#known-limitation-no-outbound-email)).
Read the confirmation code from `journalctl -u podman-multica-backend` instead.
