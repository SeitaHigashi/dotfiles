# Auto-update

Unattended updates, configured in `modules/auto-update.nix` (added 2026-10-11). Two independent halves.

## A. podman containers — `podman auto-update`

- Every `virtualisation.oci-containers` container gets the label `io.containers.autoupdate=registry`
  (set once as a submodule default, so new container modules are covered automatically).
- `podman-auto-update.timer` (ships with podman, not enabled by default) runs at **04:00** (+ up to 15 min).
  It pulls each container's image tag; if the digest changed it restarts the `podman-*.service` unit, and
  rolls back to the previous image if the restart fails.
- It follows the **tag** in the module. `:latest` containers (multica backend/web, openviking, mc-monitor)
  move to whatever upstream publishes; pinned tags (`pg17`, `postgres:18-alpine`, `java21`, the AutoMuteUs
  `tag`) only get rebuilds of that tag.
- **Minecraft (`ftb-evolution`) is excluded** (`labels."io.containers.autoupdate" = "disabled"` in
  `modules/ftb-evolution.nix`, 2026-10-11): an image rebuild must not restart the server. Update it by hand
  ([minecraft.md](minecraft.md)). `mc-monitor` is still auto-updated.
- Opt one container out: `labels."io.containers.autoupdate" = "disabled";` in its module.
  Turn the whole half off: `systemd.timers.podman-auto-update.wantedBy = [ ];`.
- Check: `podman auto-update --dry-run`, `journalctl -u podman-auto-update`.

## B. Nix packages — the `nixpkgs-auto` input

`flake.nix` has two inputs on the `nixos-unstable` branch:

| Input | Overlay | Moved by | Used for |
|---|---|---|---|
| `nixpkgs-unstable` | `pkgs.unstable.*` | hand (`nix flake update nixpkgs-unstable`) | llama.cpp, llama-swap, stable-diffusion.cpp, multica-cli, opencode, mcp-grafana, nodejs |
| `nixpkgs-auto` | `pkgs.auto.*` | `nix-auto-update.timer`, nightly | Open WebUI, n8n (+ its nodejs), neovim + vimPlugins, herdr, rtk, brave |

To move a package in or out of auto-update, change `pkgs.auto.<name>` ⇄ `pkgs.unstable.<name>` at its use site.
The `nix-lazy-nvim` and `nvim-*` source inputs are **not** auto-updated (add them to `autoInputs` to change that).

`nix-auto-update.service` runs at **04:30**:

1. **Skip** (exit 0, logged) if the git tree is dirty, or if HEAD does not evaluate to `/run/current-system`.
   The job must never activate work the user has not switched. Consequence: updates silently pause while
   uncommitted or unswitched changes exist.
2. `nix flake update nixpkgs-auto` (as the repo owner). No lock change → done.
3. Build (as the repo owner — root's nix refuses a git repo it does not own) and activate the result as root
   (`switch-to-configuration switch`), then wait for the Open WebUI `/health` and n8n `/healthz` endpoints (up to ~5 min each).
4. Success → commits `flake.lock` locally (`chore(flake): auto-update nixpkgs-auto`). **Not pushed.**
5. Failure (build, activation or health) → restores `flake.lock`, switches back, exits 1. The unit stays
   failed, which fires the existing "systemd unit is failed" alert ([alerting.md](alerting.md)).

### What a rollback does not undo

Step 5 restores binaries only. Open WebUI's alembic migrations and n8n's DB migrations are one-way: if the new
version migrated the DB before failing, the old binary may not start on it. State is under `rpool/var/lib`,
which `services.zfs.autoSnapshot` snapshots every 15 minutes — restore from the last snapshot before 04:30
([zfs-operations.md](../runbooks/zfs-operations.md)).

A regression that still answers the health check gets through (e.g. the 0.11.4 scheduler breakage would have).
Pin by pointing that package back at `pkgs.unstable.<name>`.

### Operating it

```bash
systemctl list-timers nix-auto-update podman-auto-update
journalctl -u nix-auto-update -e
sudo systemctl start nix-auto-update     # run now (tree must be clean and switched)
git log --oneline -- flake.lock          # what it has bumped
```

Turn the half off: `systemd.services.nix-auto-update.startAt = [ ];`.
