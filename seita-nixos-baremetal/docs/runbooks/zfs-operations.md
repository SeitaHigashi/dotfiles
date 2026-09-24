# ZFS day-to-day operations

Layout/design background: [../storage-zfs.md](../storage-zfs.md). Troubleshooting:
[zfs-troubleshooting.md](zfs-troubleshooting.md).

## Post-boot checks

```bash
zpool status -v
zpool list -v
zfs list -o name,used,avail,compressratio,mountpoint
arc_summary | head -40
```

Also check disk health at this point. In particular, check NVMe **Percentage Used**
(lifetime wear) periodically — consumer SSDs tend to develop unstable write latency once
this exceeds around 80%:

```bash
sudo smartctl -a /dev/nvme0 | grep -iE "percentage used|temperature|critical|media errors|unsafe"
sudo nvme smart-log /dev/nvme0
```

## Scrub

`services.zfs.autoScrub.enable = true;` runs it monthly automatically. Manual:

```bash
zpool scrub dpool
zpool status dpool
```

## Snapshots

`services.zfs.autoSnapshot` takes frequent/hourly/daily/weekly/monthly snapshots
automatically. `/tmp`, `/var/log`, and `/nix` are excluded.

```bash
zfs list -t snapshot -o name,used,refer -s creation | tail -20
```

Restore:

```bash
# a single file
cp /home/user/.zfs/snapshot/zfs-auto-snap_daily-2026-07-26-0000/foo.txt ~/
# an entire dataset
zfs rollback dpool/home@zfs-auto-snap_daily-2026-07-26-0000
```

### Viewing status in a GUI

Grafana's "ZFS Snapshots and Replication" dashboard (uid `zfs-replication`) has this
consolidated. Alongside per-dataset generation counts and newest/oldest snapshot
timestamps and space used, it shows **replication lag** — the gap between the newest
snapshot timestamp on the source `rpool/X` and the destination `dpool/backup/X`. That
number is exactly "how many hours of data we'd lose if the SSD died right now."

Metrics are supplied by a systemd timer in `modules/zfs-snapshot-metrics.nix` running
`zfs list` every 5 minutes and writing a `.prom` file for node_exporter's textfile
collector (no off-the-shelf exporter for this exists, and none is packaged in nixpkgs).

The syncoid units' run status and timer firing come from node_exporter's systemd
collector — a separate path from the textfile above. **The two are deliberately kept
side by side so that either one failing alone is still noticed** — a unit that exits
successfully while actually transferring nothing can only be caught via replication lag.

```bash
# is collection running?
systemctl list-timers zfs-snapshot-metrics
cat /var/lib/prometheus-node-exporter-text-files/zfs-snapshots.prom
curl -s localhost:9100/metrics | grep -E '^zfs_(snapshot|pool)'
```

### Alerting (so you don't have to go check)

The dashboard above only helps if someone looks at it, so threshold checks are handled by
Grafana alerts (`modules/alerting.nix`). There are 3 replication-related rules: **replication
lag over 36 hours**, **a syncoid unit reaching failed**, and **the textfile collector itself
not updating for 30+ minutes** (without this third one, a stale replication-lag value would
keep reading as "normal"). Beyond that, it watches ZFS pool degradation, disk SMART and
temperature, free space, memory, CPU, and the liveness of resident services.

Notifications are just a POST to an n8n webhook
(`http://127.0.0.1:5678/webhook/grafana-alert-40b2fc68`); everything past that (routing to
Discord, muting overnight, etc.) is the n8n workflow's job. **That webhook workflow must be
built and enabled separately in n8n.** Without it, delivery simply fails silently — alert
state still shows correctly in Grafana's Alerting view.

## Replacing a failed HDD

```bash
zpool status dpool                       # identify the DEGRADED device
zpool offline dpool /dev/disk/by-id/ata-OLD
# after physical replacement
zpool replace dpool /dev/disk/by-id/ata-OLD /dev/disk/by-partlabel/disk-hdd1-zfs
zpool status dpool                       # watch resilver progress
```

After replacing, update `hdd1` / `hdd2` in `machine.nix` to the new by-id (needed the next
time disko runs).

## SSD failure

- **rpool is lost** (single vdev). `/home` and `/srv` stay on dpool and are unaffected.
- dpool's `cache` (if any) just detaches cleanly; data is untouched.
- After replacing the SSD, update `ssd` in `machine.nix` and **reinstall from the same
  flake** to recover. Since you don't want to destroy dpool, don't use
  `--mode destroy,format,mount` — rebuild rpool only.
- **Manage `/etc/nixos` under git separately.** The principle is that everything on rpool
  is reproducible from the flake.

**The one exception is `/srv/minecraft` (the Minecraft world).** It can't be regenerated
from the flake, and I/O problems on the SMR HDD forced it onto rpool. To protect it,
syncoid in `modules/replication.nix` replicates it daily to `dpool/backup/minecraft`. After
rebuilding rpool, restore from the receiving side:

```bash
zfs list -t snapshot -r dpool/backup/minecraft          # find the newest generation
zfs send dpool/backup/minecraft@<latest> | zfs recv -u rpool/srv/minecraft

# recv inherits properties from the parent (rpool), so you must set these back explicitly.
# Forgetting com.sun:auto-snapshot stops future snapshots and replication too.
zfs set mountpoint=legacy rpool/srv/minecraft
zfs set com.sun:auto-snapshot=true rpool/srv/minecraft
zfs set atime=off rpool/srv/minecraft
```

You lose at most the time since the last replication (up to 1 day). To shorten this,
set `services.syncoid.commands."rpool/srv/minecraft".interval` individually (changing
`services.syncoid.interval` globally would also affect `rpool/root` and
`rpool/var/lib`).

## Backup

A ZFS mirror is not a backup (useless against accidental deletion, ransomware, or
whole-chassis failure). Send regularly to external or remote storage with `zfs send -R`.

```bash
zfs snapshot -r dpool@backup-$(date +%F)
zfs send -R -I dpool@backup-PREV dpool@backup-$(date +%F) | ssh backup zfs recv -Fu tank/dpool
```

## Everyday rebuild

```bash
sudo nixos-rebuild switch --flake /etc/nixos
```

## Adding a dataset to a running system

`disko/default.nix` only turns declarations into an actual `zfs create` at install time
(`disko --mode disko`); `nixos-rebuild switch` only generates `fileSystems`/mount units.
Declaring a new dataset and then just running `switch` fails the corresponding
`<mountpoint>.mount` unit ("dataset does not exist"), which cascades through
`local-fs.target` and **drops the system into emergency mode** — this happened for real
when adding the openviking dataset on 2026-08-25.

Steps, in order:

1. Add the dataset to `disko/default.nix` as usual.
2. **Before running `switch`**, manually create the dataset with the same options as the
   `fsDataset` declaration, e.g.:
   ```bash
   sudo zfs create -p -o mountpoint=legacy -o com.sun:auto-snapshot=false dpool/var/lib/openviking
   ```
   (`-p` also creates intermediate datasets like `var`/`var/lib` as needed.)
3. Be aware that **a switch adding a new mount under rpool or dpool restarts that pool's
   import service (`zfs-import-<pool>.service`)**, which unmounts every other mount on the
   same pool along with it. If `/home` is on the affected pool, an active SSH session using
   `/home` gets disconnected as collateral damage (also confirmed on real hardware on
   2026-08-25). Run the switch from a physical console or inside `tmux` when possible.
