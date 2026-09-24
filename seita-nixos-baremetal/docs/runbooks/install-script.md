# scripts/install.sh reference

For the overall install flow (ISO boot, quick start, manual step-by-step), see
[install.md](install.md). This page covers what `install.sh` itself does step by step,
its full option list, and every field in `disks.env`.

Source: [../../scripts/install.sh](../../scripts/install.sh) (generates
[../../machine.nix](../../machine.nix) from [../../scripts/disks.env](../../scripts/disks.env)).

## Step-by-step

1. **Argument parsing** — only `--bench-size <N>` takes a value; everything else is a flag.
2. **tmux auto re-entry** — if running over SSH outside tmux/screen and `tmux` is
   available, re-execs itself under `tmux new-session -A -s nixos-install`, so a dropped
   SSH connection doesn't kill the install. Skippable with `--no-tmux`.
3. **Logging** — tees output to `/tmp/nixos-zfs-install.log`, falling back to
   `$HOME/nixos-zfs-install.log`, or no log at all if neither is writable. **The log must
   never live inside the repo directory (`$REPO_DIR`)**: `nix eval`/`nixos-install` hash
   the whole `--flake` source tree as a NAR, and a log growing inside it while the run is
   in progress makes the hash computed at the start mismatch the one read later, failing
   with `NAR hash mismatch`. This has been hit in practice.
4. **Source `disks.env`**, then derive `FLAKE="$REPO_DIR#$HOSTNAME"`. The flake attribute
   name equals the hostname, so `disks.env` must define `HOSTNAME=` explicitly — an ISO's
   default hostname (`nixos`) being silently picked up instead is a real failure mode an
   emptiness check alone can't catch, so `install.sh` greps for the `HOSTNAME=` line itself.
5. **Pre-flight checks** — root, UEFI boot, required commands (`nix`,
   `nixos-generate-config`, `nixos-install`, `zpool`, `zfs`), ZFS kernel module loadable,
   `disks.env`'s `SSD`/`HDD1`/`HDD2` are real distinct block devices (not the
   `XXXXXXX`/`YYYYYYY` template placeholders), `NIX_POOL`/`USE_SLOG` values valid, HDD
   capacities match (warning only), `cache.nixos.org` reachable.
6. **hostid alignment** (see below) — writes `/etc/hostid` on the ISO to match the
   `HOST_ID` that will go into `machine.nix`.
7. **SSH key / password handling** — merges `SSH_AUTHORIZED_KEYS` from `disks.env` with
   the ISO's `/root/.ssh/authorized_keys` and `$HOME/.ssh/authorized_keys` (deduplicated),
   validates `USER_PASSWORD_HASH`/`ROOT_PASSWORD_HASH` look crypt-formatted, and warns if
   no login method at all would be configured.
8. **Generate `machine.nix`** from the `disks.env` values (see field table below).
9. **Hardware detection** — `nixos-generate-config --no-filesystems --show-hardware-config`
   (disko owns `fileSystems`/`swapDevices`, so they must not be generated here).
10. **Dry-run evaluation** — `nix eval` of `config.system.build.toplevel.drvPath` and
    `.diskoScript` before touching any disk.
11. **Final confirmation** — prints a summary and (unless `--yes`/`--skip-format`/`--remount`)
    requires typing `YES` before erasing the disks.
12. **disko** — `destroy,format,mount` (default), `mount` only (`--remount`, keeps the pool),
    or skipped entirely (`--skip-format`, resumes on an already-mounted `/mnt`).
13. **Optional benchmark** (`--bench`) — runs `bench-pools.sh` right after pool creation and
    saves the CSV to `/mnt/root` (survives into the installed system, since `/mnt/root` is
    on `rpool/root`).
14. **`nixos-install --root /mnt --flake $FLAKE`**.
15. **Deploy the repo** — `tar`-copies the whole repo tree (excluding `.git` and `result`)
    into `/mnt/etc/nixos`, then chowns/chmods it. Copying file-by-file was tried before and
    abandoned: forgetting to list a newly added `modules/*.nix` file meant the install
    itself succeeded (`nixos-install` reads the source repo directly) but the *first*
    `nixos-rebuild` after reboot failed with "file not found", since `/etc/nixos` was
    missing it. This has actually happened.
16. **Clean pool export** (unless `--no-export`) — `zpool export -a` after unmounting.

### hostid alignment (step 6)

ZFS stamps the *creating host's* hostid into a pool label at creation time. Without this
step, the ISO's hostid gets stamped in, which will always differ from the installed
system's `networking.hostId`. The first time there's an unclean shutdown (crash, power
loss, kernel panic), the next boot fails at stage 1 with:

```
cannot import 'dpool': pool was previously in use from another system
```

`install.sh` avoids this class of failure entirely by writing `/etc/hostid` on the ISO to
the same value that will become `machine.nix`'s `hostId`, *before* running disko — so the
pool is stamped with the final value from the start. This is a more fundamental defense
than `boot.zfs.forceImportRoot = true` (which only covers a forgotten `zpool export`); the
full defense is three layers: hostid pre-alignment, clean export at the end of install,
and `forceImportRoot = true` as a last resort.

The hostid's actual value is arbitrary (fine for it to differ across ISO boots) — what
matters is only that the value stamped into the pool matches the installed system's
`networking.hostId`, which this step guarantees by construction.

## Options

| Option | Behavior |
|---|---|
| `--yes` / `-y` | Don't prompt for confirmation (fully unattended) |
| `--no-tmux` | Don't auto re-exec into tmux |
| `--config-only` | Stop after generating `machine.nix` and the dry-run eval. Disks untouched |
| `--format-only` | Stop after disko formats/mounts. Doesn't run `nixos-install` |
| `--skip-format` | Don't run disko (assumes `/mnt` is already mounted, for resuming) |
| `--remount` | Mount the existing pools without destroying them, then run `nixos-install`. For redoing the install while keeping the data |
| `--no-export` | Don't `umount`/`zpool export` at the end (normally leave unset — forgetting to export can leave the system unbootable) |
| `--list-disks` | List this machine's disks and by-id paths, then exit |
| `--bench` | Measure a performance baseline right after pool creation, save under `/root` (adds a few minutes) |
| `--bench-size <N>` | Benchmark test size (default `4G`) |

## `disks.env` fields

| Field | Meaning |
|---|---|
| `SSD`, `HDD1`, `HDD2` | by-id device paths. Must be distinct, real block devices |
| `EFI_SIZE`, `SWAP_SIZE`, `SLOG_SIZE` | SSD partition sizes; `rpool` takes the remainder |
| `ASHIFT` | `12` for 4096-byte physical sectors, `14` for 16384-byte (some 8TB+ HDDs). Fixed at pool creation |
| `USE_SLOG` | `1` adds a log vdev to `dpool` (only helps synchronous writes — NFS/DB); `0` reserves the partition but leaves it unused |
| `ARC_MAX_BYTES` | ZFS ARC ceiling in bytes; rule of thumb is 1/4–1/2 of physical RAM |
| `NIX_POOL` | `rpool` (SSD, recommended — fast rebuild/GC) or `dpool` (HDD, saves SSD writes at the cost of build/GC speed) |
| `HOSTNAME`, `USER_NAME`, `USER_DESCRIPTION` | Basic system identity |
| `STATIC_ADDRESS`, `GATEWAY`, `NAMESERVERS`, `NETWORK_INTERFACE` | Static IP config; leave `STATIC_ADDRESS` empty for DHCP + NetworkManager |
| `HOST_ID` | 8-digit hex; auto-derived from the ISO's `/etc/machine-id` if empty |
| `SSH_AUTHORIZED_KEYS` | Newline-separated public keys; falls back to the ISO's `authorized_keys` if empty |
| `ALLOW_PASSWORD_AUTH` | `0` (recommended) = public key only for SSH; `1` = also allow SSH password auth (direct root login is still refused either way) |
| `PROMPT_ROOT_PASSWORD` | `1` (recommended) = ask interactively at the end of `nixos-install`, written straight to `/etc/shadow`, never touches the Nix store |
| `USER_PASSWORD_HASH`, `ROOT_PASSWORD_HASH` | Optional declarative password hashes (`mkpasswd -m yescrypt`). **Must be single-quoted** — `$` in a double-quoted value gets expanded by bash and corrupts the hash. These values end up embedded in the world-readable `/nix/store`, so leave them empty and use `PROMPT_ROOT_PASSWORD=1` + `passwd` unless you specifically need them declarative |

## When you change this file

Update this doc in the same commit if you change `install.sh`'s steps, options, or
`disks.env`'s fields.
