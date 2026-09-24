# Minecraft restarting on a 60-second tick

Date: 2026-07-31 (first recorded in commit fb2d84e)

Layout background: [../storage-zfs.md](../storage-zfs.md). Related troubleshooting:
[../runbooks/zfs-troubleshooting.md](../runbooks/zfs-troubleshooting.md).

## Symptom

From a player's perspective, "the connection times out." In reality the server was
crashing and being brought back up by `Restart=always` — 7 times a day.

```
[Server Watchdog/ERROR] A single server tick took 60.00 seconds (should be max 0.05)
[Server Watchdog/ERROR] Considering it to be crashed, server will forcibly shutdown.
systemd[1]: podman-ftb-evolution.service: Main process exited, code=exited, status=1/FAILURE
```

This is not a systemd or podman timeout — it's Minecraft's own ServerHangWatchdog
(`TimeoutStartSec=infinity`, so systemd is not involved here).

## Diagnosis

Check where `"Server thread"` is in the crash report's thread dump.

```bash
journalctl -u podman-ftb-evolution --since "2 days ago" | grep -a -A30 '"Server thread" prio'
```

```
"Server thread" RUNNABLE
  at sun.nio.ch.UnixFileDispatcherImpl.write0(Native Method)   ← stuck in a raw write(2)
  at net.minecraft.nbt.NbtIo.writeCompressed
  at MinecraftServer.saveAllChunks / saveEverything / tickServer
```

Being stuck in `write0` confirms **I/O wait**, not a mod — a mod-caused hang would show
the mod's class name there instead.

## Root cause

The dpool HDD (`ST4000DM004`) is **SMR**. Under sustained random overwrite, once the
internal CMR cache fills up, response times climb into the tens of seconds, and ZFS's
write throttle (`zfs_dirty_data_max`) stalls `write(2)`. Supporting numbers:

```bash
cat /proc/pressure/io     # full avg300=43% — the whole machine was 40% stalled on I/O
zpool status -x           # all pools are healthy — not a disk failure
```

The decisive evidence: the same 1.5 GB backup took 68s → 92s → 109s → **239s**, degrading
monotonically — the textbook signature of SMR cache exhaustion.

## Countermeasure

Moved the world to rpool (NVMe), with syncoid in
[../../modules/replication.nix](../../modules/replication.nix) replicating daily to dpool.
**This cannot be fixed via `modules/resource-priority.nix`** — ZFS doesn't go through
blk-cgroup, so `IOWeight` has no effect; CPU and memory weighting are powerless against
I/O contention.

At the same time, disabled the modpack's bundled FTB Backups 3, which was writing a 1.5 GB
zip to the same pool every 2 hours — completely redundant with ZFS snapshots.

## Effect on SSD lifespan

The 990 PRO 1TB has a 600 TB TBW rating. Measured world write traffic is 4 MB/hour idle
(from hourly snapshot deltas), and host-wide writes are 13 GiB/day — the math works out to
a lifespan on the order of a century. Lifespan is not a reason to hesitate here.
