# Installing NixOS on the ZFS layout

Layout/design background: [../storage-zfs.md](../storage-zfs.md).

## Quick start (SSH-automated install)

Assumes you've booted the NixOS installer ISO and are connected as root over SSH.
**All 3 disks will be completely wiped.**

```bash
# On the ISO side, enable SSH if not already (skip if already set up)
#   passwd            # set the root password
#   systemctl start sshd

# From your workstation, transfer the config
scp -r nixos-zfs root@<installer-ip>:/root/

# On the ISO side
cd /root/nixos-zfs
ls -l /dev/disk/by-id/ | grep -v part     # check the disk IDs
vi scripts/disks.env                      # ★ the only file you edit★
bash scripts/install.sh
```

What [scripts/install.sh](../../scripts/install.sh) does:

1. **Preflight checks** — root / UEFI boot / required commands / ZFS module / disks
   exist, no duplicates, capacity difference / `cache.nixos.org` reachability
2. **Auto tmux re-entry** — if this is an SSH session, re-exec itself under
   `tmux new-session -A -s nixos-install` (a disconnect won't kill the install)
3. `disks.env` → generates [machine.nix](../../machine.nix) (hostId from the ISO's
   `/etc/machine-id`, **SSH public key auto-inherited from the ISO's
   `/root/.ssh/authorized_keys`**)
4. `nixos-generate-config --no-filesystems --show-hardware-config` for hardware detection
5. **Dry-run evaluation** — fail on Nix evaluation errors before touching any disk
6. `disko --mode destroy,format,mount`
7. `nixos-install` → deploys the config to `/mnt/etc/nixos`

Main options:

| Option | Behavior |
|---|---|
| `--yes` | no confirmation prompts (fully unattended) |
| `--config-only` | stop after generating `machine.nix` and the dry-run evaluation. **Does not touch any disk** |
| `--format-only` | stop after disko formats/mounts. Does not run `nixos-install` |
| `--skip-format` | skip disko, install directly onto the already-mounted `/mnt` |
| `--no-tmux` | skip auto tmux re-entry |

Logs go to `/tmp/nixos-zfs-install.log`. If disconnected, resume with
`tmux attach -t nixos-install`.

> **[configuration.nix](../../configuration.nix) sets `PasswordAuthentication = false`.**
> Proceeding with neither a public key nor a password hash locks you out of SSH after
> reboot. `install.sh` auto-inherits the ISO's authorized_keys; if neither is available it
> warns and asks for confirmation. To use a password instead, put the output of
> `mkpasswd -m yescrypt` into `USER_PASSWORD_HASH` in `disks.env`.

## Preparation

### Boot the ISO

Boot from a ZFS-capable NixOS minimal ISO (the official minimal ISO works).

```bash
sudo -i
```

### Check the disks' by-id paths

**Always use `/dev/disk/by-id/`.** Building a pool on bus-dependent names like `/dev/sda`
breaks import if the connection order changes.

```bash
ls -l /dev/disk/by-id/ | grep -v part
```

### Check sector size (to decide ashift)

```bash
lsblk -o NAME,PHY-SEC,LOG-SEC,ROTA,MODEL
```

If the physical sector size is 4096 (4Kn/512e), use `ashift=12`. Some 8TB+ HDDs have a
16 KiB physical sector (`ashift=14`). **ashift cannot be changed after pool creation.**
When in doubt, `12` is fine.

## Manual install

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"

# Edit machine.nix with your own values first
vi machine.nix

# Hardware detection (--no-filesystems: disko owns fileSystems/swapDevices, don't generate them)
nixos-generate-config --no-filesystems --show-hardware-config > hardware-configuration.nix

# Evaluate before touching any disk
nix eval --raw .#nixosConfigurations."$(hostname)".config.system.build.toplevel.drvPath

# Partition through mount
nix run github:nix-community/disko/latest -- --mode destroy,format,mount --flake .#"$(grep -oP 'hostName = "\K[^"]+' machine.nix)"

# Verify
zpool status && zpool list -v && findmnt -R /mnt

# Install
nixos-install --root /mnt --flake .#"$(grep -oP 'hostName = "\K[^"]+' machine.nix)"

# Reboot
umount -R /mnt && swapoff -a && zpool export -a && reboot
```

disko's `--mode` values, by use case:

| mode | Behavior |
|---|---|
| `destroy` | destroy existing pools/partitions |
| `format` | partition, create pools and datasets |
| `mount` | mount everything under `/mnt` |
| `destroy,format,mount` | all of the above (fresh install) |
| `mount` alone | rescue: remount an existing pool at `/mnt` |
