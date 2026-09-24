# 2026-08-28: add Xid-based GPU failure monitoring

Affects: [`modules/gpu-xid-metrics.nix`](../../modules/gpu-xid-metrics.nix).

## Incident

On 2026-08-28, GPU1 (`0000:06:00.0`) fell off the PCIe bus — NVRM logged
Xid 79 ("GPU has fallen off the bus"), and the driver subsequently raised Xid 154
("Node Reboot Required") for both GPUs.

Consequences that went undetected at the time:

- `nvidia-smi` could no longer enumerate GPU1.
- Ollama silently fell back to CPU inference for anything scheduled on GPU1.
- `nvidia-gpu-exporter`'s scrape target stayed up throughout (it only queries what
  `nvidia-smi` can still see), so no existing `scrape-target-down` alert fired.
- OpenViking's summary/extract tasks failed outright with `APITimeoutError` as a
  downstream effect.

The failure was only noticed the next morning, when the user reported that summary
tasks had been failing "since last night" — several hours of detection lag between
the actual event and discovery.

## Why existing monitoring missed it

`modules/monitoring.nix`'s `nvidia-gpu-exporter` is `nvidia-smi`-based. Neither the
utkuozdemir nor the mindprince exporter (both evaluated) supports Xid reporting —
this is a known gap for consumer/non-datacenter NVIDIA cards, also called out in
`README.md`'s list of what this host's NVIDIA metrics can't show (MIG, Xid, PCIe
throughput, energy counters, per-process breakdown). Xid errors are only ever
written to the kernel log; there is no other detection path.

## Decision

Add a textfile-collector module that reads `journalctl -k -b 0` for `NVRM: Xid`
lines every 2 minutes and exposes:

- `gpu_xid_events_current_boot{pci,xid}` — count of each Xid code seen this boot.
- `gpu_reboot_required{pci}` — 1 if a **fatal** Xid (79 or 154 only) has been seen
  for that PCI address this boot.

Only Xid 79 and 154 are treated as fatal. Other Xid codes (e.g. 13, "Graphics
Engine Exception") can be raised by benign causes such as shader bugs in unrelated
software, so they are deliberately excluded from `gpu_reboot_required` to avoid
false-positive reboot alerts — the list favors avoiding false alarms over catching
every possible Xid.

State is read fresh every run rather than tracked as a monotonic counter with a
cursor: there is no "recovered" state for a fatal Xid short of a reboot, so this is
conceptually the same kind of gauge as `zfs_pool_health`
(see [textfile-metrics.md](../services/textfile-metrics.md#zfs-snapshot-metricsnix--snapshot-and-replication-health)),
and re-reading `journalctl -k -b 0` avoids the failure modes of a cursor file
(corruption, missed lines) while `-b 0` (current boot only) prevents an old
incident from being reported forever after the next reboot.

Polling interval (2 min) is tighter than the ZFS collector's (5 min) because for
this failure mode, time-to-detection directly becomes outage duration.
