# NVMe dropout made the system unbootable

Date: 2026-07-30 (first recorded in commit 2b40fa9)

Layout background: [../storage-zfs.md](../storage-zfs.md). Related troubleshooting:
[../runbooks/zfs-troubleshooting.md](../runbooks/zfs-troubleshooting.md).

## Symptom

The machine stopped responding under a load no heavier than running the Minecraft server,
and after a forced reboot it failed to boot, stuck in stage 1.

## Chain of events

```
nvme nvme0: I/O tag 37 timeout, aborting req_op:WRITE
nvme nvme0: Admin Cmd QID 0 timeout, reset controller
  ↓
INFO: task l2arc_feed:223 blocked for more than 245 seconds.
INFO: task zfs:14576 blocked for more than 245 seconds.
  ↓
systemd-journald.service: Watchdog timeout (limit 3min)!
podman-minecraft.service: Stopping timed out.
NetworkManager.service: State 'stop-sigterm' timed out. Killing.
  ↓
Shutdown could not complete cleanly → forced reset with the pool unexported
  ↓
initrd import fails on next boot
```

## Root cause

The NVMe holding rpool was reset by its controller after I/O timeouts. It was neither a
memory shortage nor heat (ARC actually used 1 GiB out of 46 GiB RAM; the SSD was at 45°C).
The drive was a budget, DRAM-less NVMe (ADATA LEGEND 700), and SMART **Percentage Used had
reached 78%**.

## Contributing factor: this repo's old configuration

The old layout consolidated **rpool + swap + L2ARC** onto a single NVMe, and additionally
raised `l2arc_write_max` / `l2arc_write_boost` to 4-8x their defaults. Writes to L2ARC are
pure wear with almost no payoff when ARC has headroom (measured: 1 GiB actual usage against
a 16 GiB ARC ceiling — L2ARC was never even needed).

## Countermeasures (all applied)

1. **L2ARC removed entirely** — the cache vdev was deleted from
   [../../disko/default.nix](../../disko/default.nix), and the l2arc_* tuning was removed
   from [../../modules/zfs.nix](../../modules/zfs.nix). **Do not bring it back.** On a live
   machine this can be removed with no data loss, immediately:
   ```bash
   sudo zpool remove dpool <the device name shown in the cache row of zpool status>
   ```
2. **NVMe kernel parameters** — added in [../../modules/zfs.nix](../../modules/zfs.nix):
   - `nvme_core.default_ps_max_latency_us=0` (disables APST, avoiding failed resumes from
     low-power states)
   - `nvme_core.io_timeout=255` (default is 30s; prevents a several-tens-of-seconds delay
     from SLC cache exhaustion being misdiagnosed as a controller failure)
3. **Made SMART monitoring effective** — enabled `services.smartd` attribute monitoring
   and installed `nvme-cli`.

## Verification

Apply the same load while watching for `timeout` / `reset controller` in the log; their
absence means the fix held.

```bash
sudo journalctl -f -k | grep -i nvme
```

If it still recurs, that's a hardware limit on the drive itself — **replacement is the
only fix**. rpool is a single vdev with no redundancy, so if this SSD dies the system goes
down with it (`/home` and `/srv` survive on the HDD mirror, dpool).
