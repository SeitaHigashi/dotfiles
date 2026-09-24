# ZFS troubleshooting

Layout/design background: [../storage-zfs.md](../storage-zfs.md). Day-to-day operations:
[zfs-operations.md](zfs-operations.md). Incident write-ups:
[../decisions/2026-07-30-nvme-dropout-made-system-unbootable.md](../decisions/2026-07-30-nvme-dropout-made-system-unbootable.md),
[../decisions/2026-07-31-minecraft-restarting-on-60s-tick.md](../decisions/2026-07-31-minecraft-restarting-on-60s-tick.md).

## Boot hangs with `pool was previously in use from another system`

```
cannot import 'dpool': pool was previously in use from another system.
Last accessed by nixos (hostid=8425e349)
The pool can be imported, use 'zpool import -f' to import the pool.
...
An error occurred in stage 1 of the boot process
```

**Cause**: ZFS stamps the label with the hostid of the host that created the pool. If that
matches the running system's hostid, import succeeds even after an unclean shutdown.
If they don't match, ZFS refuses as soon as there has been so much as one crash or power
loss, deciding the pool is "in use by another system."

The old `install.sh` ran disko while the ISO's hostid was still in effect, so this
mismatch was guaranteed (this actually caused an unbootable system in production). It now
aligns the ISO's `/etc/hostid` to the final `hostId` before running disko, closing off this
failure path.

**Recovery**: boot the installer ISO, re-import, then export cleanly.

```bash
sudo zpool import -f rpool
sudo zpool import -f dpool
sudo zpool export rpool
sudo zpool export dpool
sudo reboot
```

Reinstalling is not necessary.

**Prevention**: three layers of defense:

1. `scripts/install.sh` aligns the ISO's `/etc/hostid` to the `hostId` that ends up in
   `machine.nix` **before running disko** (the root-cause fix)
2. `scripts/install.sh` automatically runs `umount -R /mnt && swapoff -a && zpool export -a`
   at the end
3. `boot.zfs.forceImportRoot = true` in `modules/zfs.nix` (the NixOS default)

Do not set `forceImportRoot` to `false`. `false` only makes sense for configurations like
SAN or shared storage where another host might genuinely be using the same pool right now.
On a local-disks-only machine it **only causes unbootability on every hostid mismatch**.

## Investigating the cause after a crash

Check these two first — what's in the previous boot's log largely determines the
diagnosis.

```bash
free -h                                          # out of memory?
grep -E "^(size|c_max) " /proc/spl/kstat/zfs/arcstats   # ARC ceiling and actual usage
sudo journalctl --list-boots | tail -5
sudo journalctl -b -1 -p warning --no-pager | tail -60
```

| What shows in the log | Cause |
|---|---|
| `Out of memory: Killed process` | out of memory. Lower `arcMaxBytes` |
| `nvme ... timeout, reset controller` | the NVMe-dropout incident above |
| `INFO: task ... blocked for more than N seconds` | I/O stall. The real cause is in the preceding lines |
| `Machine Check Exception` | CPU/memory hardware fault. Run memtest86+ |
| `thermal` / `Critical temperature` | insufficient cooling |
| Nothing left in the log | instant death from power loss or heat. Suspect hardware |

**Checking hostid** (used to diagnose import refusals):

```bash
hostid                              # the running system
sudo zdb -C dpool | grep -i hostid  # the pool's (printed in decimal)
cat /etc/hostid | xxd               # the value baked into initrd (little-endian)
```

If all three match, import succeeds even after an unclean shutdown. Note that `zdb`
without `sudo` prints Permission denied followed by an ASSERT and backtrace — this is a
known cleanup quirk, not pool corruption.

## `NAR hash mismatch in input 'path:...'`

```
error: NAR hash mismatch in input 'path:/home/nixos/nixos-zfs?lastModified=...',
expected 'sha256-...' but got 'sha256-...'
```

**Cause**: the contents of the directory passed to `--flake` changed during evaluation.
Nix hashes the whole directory as a NAR for its input, so continuously writing things like
log files inside the flake tree triggers this.

**Fix**: don't put generated artifacts inside the flake directory.

```bash
rm -f ~/nixos-zfs/install.log
```

`install.sh` writes its log to `/tmp` (falling back to `$HOME` if unwritable), and never
writes inside the flake tree.

## `not all disks accounted for, skipping creating zpool`

A message from disko. Some partition declaring `pool = "..."` is missing from the
topology. See [storage-zfs.md §3.1](../storage-zfs.md#31-topology-and-reserved-partitions).

## Pool went `DEGRADED`

```bash
zpool status -v            # which device dropped
smartctl -a /dev/sdX       # physical health
```

For an HDD, see [zfs-operations.md — replacing a failed HDD](zfs-operations.md#replacing-a-failed-hdd).
The SSD side (rpool) is a single vdev so it never goes DEGRADED — if it breaks, it's a
total loss outright.
