# Secrets (agenix)

## Where secrets live

Secrets are encrypted at rest with [agenix](https://github.com/ryantm/agenix) and
committed to git as `secrets/*.age`. The decryption key is derived from this host's
own SSH host key, not carried around separately:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub   # -> public key, used to encrypt
```

The recipient public key lives in `secrets/secrets.nix` (`host = "age1..."`). Every
`.age` file listed there is encrypted for that one key.

Decryption on the host does **not** use the raw SSH private key directly. It uses a
derived age identity file, `/etc/age/host.key`, referenced via
`age.identityPaths = [ "/etc/age/host.key" ]` (see `modules/discord-bot.nix`).
Rebuild/recovery procedure for that file:

```sh
sudo install -d -m 0700 /etc/age
sudo sh -c 'nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key \
  < /etc/ssh/ssh_host_ed25519_key > /etc/age/host.key'
sudo chmod 600 /etc/age/host.key
```

## Adding a new secret

1. Encrypt the new file as `secrets/<name>.age` (agenix CLI, using the host public
   key above).
2. Add `"<name>.age".publicKeys = [ host ];` to `secrets/secrets.nix` — this is the
   only place recipients are declared; forgetting this entry means the file can't be
   re-encrypted for this host on the next `agenix -e`.
3. Reference it from the owning module with `age.secrets.<name> = { file = ...; owner = ...; mode = "0400"; };`.

Currently tracked secrets (`secrets/secrets.nix`):

| File | Consumer |
|---|---|
| `discord-bot-env.age` | `modules/discord-bot.nix` |
| `multica-env.age` | `modules/multica.nix` |
| `multica-github-app-key.age` | `modules/multica.nix` |
| `openviking-root-api-key.age` | `modules/openviking.nix` |

## The Grafana admin-password exception

Grafana's admin password is **not** in agenix. It predates the agenix setup on this
host and was never migrated, so it stays as a manual, out-of-repo file:
`/var/lib/grafana/admin-password`, read via Grafana's `$__file{}` mechanism. It lives
outside both the Nix store and git — placed by hand on the host, not declared here.

Whatever the mechanism, the underlying rule is the same: never write a secret value
directly into a `.nix` expression.
