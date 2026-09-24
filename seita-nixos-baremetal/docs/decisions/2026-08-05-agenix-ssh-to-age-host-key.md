# agenix needs an ssh-to-age-converted host key, not the raw SSH host key

- Date: 2026-08-05
- Scope: `modules/discord-bot.nix` (`age.identityPaths`)

## Background

agenix's built-in SSH-key support fails when pointed directly at
`/etc/ssh/ssh_host_ed25519_key`: it errors with "no identity matched any of
the recipients". Verified on hardware with age 1.2.1 / agenix 0.15.0.

## Decision

Convert the host key to age's native format once with `ssh-to-age
-private-key`, and store the result at `/etc/age/host.key` — provisioned
manually, like the Grafana admin password, rather than checked into git.
`age.identityPaths = [ "/etc/age/host.key" ]` decrypts fine against `.age`
files encrypted for the corresponding `ssh-to-age`-converted public key.

## Recreating `/etc/age/host.key` after a host rebuild

```sh
sudo install -d -m 0700 /etc/age
sudo sh -c 'nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key \
  < /etc/ssh/ssh_host_ed25519_key > /etc/age/host.key'
sudo chmod 600 /etc/age/host.key
```
