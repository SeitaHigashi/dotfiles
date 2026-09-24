# scripts/bench-pools.sh reference

Measures `rpool` (SSD) and `dpool` (HDD mirror) throughput/IOPS and evaluates the result
against fixed lower-bound expectations for the hardware class. Also invoked by
[../../scripts/install.sh](../../scripts/install.sh) via `--bench` right after pool
creation — see [install-script.md](install-script.md).

Source: [../../scripts/bench-pools.sh](../../scripts/bench-pools.sh).

## Why not just measure directly

Measuring a ZFS pool as-is mixes in ARC (RAM cache) and compression, so you end up
measuring RAM speed or a zero-fill compression ratio instead of the disk. The script
works around this by creating a dedicated dataset with `compression=off`, and measuring
twice: once with `primarycache=none` (uncached — actual disk performance) and once with
`primarycache=all` (cached — repeat-access experience). Verdicts are only computed for
write and uncached-read; cached-read is reported for reference only.

## Usage

```bash
sudo bash scripts/bench-pools.sh                        # measure and evaluate
sudo bash scripts/bench-pools.sh --out baseline.csv      # save the results
sudo bash scripts/bench-pools.sh --compare baseline.csv  # compare against a past run
sudo bash scripts/bench-pools.sh --pools dpool --seq-only
```

| Option | Behavior |
|---|---|
| `--size <N>` | Test file size (default `4G`) |
| `--pools <list>` | Target pools (default `"rpool dpool"`) |
| `--seq-only` | Sequential only (random on HDD is slow; saves time) |
| `--out <file>` | Save results as CSV (for recording a baseline) |
| `--compare <f>` | Compare against a saved CSV and print the delta |
| `--keep` | Don't delete the measurement dataset afterwards |
| `--yes` | Don't prompt for confirmation |

`fio` and `jq` aren't in `environment.systemPackages`; if missing, the script
re-execs itself under `nix shell nixpkgs#fio nixpkgs#jq`.

**This writes real data to the disks and consumes SSD write-lifetime.** Percentage Used
is printed before and after every run.

## Expected-value table (lower bounds, not spec-sheet peaks)

Pool kind (SSD vs HDD) is auto-detected via `zpool status -P` + `lsblk`'s `ROTA` flag; a
pool with any rotational member is treated as HDD.

| Metric | SSD good / warn | HDD good / warn |
|---|---|---|
| seq-write (MiB/s) | 800 / 300 | 100 / 50 |
| seq-read (MiB/s) | 1000 / 400 | 150 / 80 |
| rand-write (IOPS) | 20000 / 5000 | 300 / 100 |
| rand-read (IOPS) | 30000 / 8000 | 200 / 80 |

Basis: SSD assumes a DRAM-equipped NVMe drive on PCIe 3.0+ (effective ceiling ~3.5 GB/s
for x4, so the bound is set low enough not to trip on an older generation). HDD assumes a
mirror of two 7200rpm-class drives — sequential *read* can reach 1.5-2x a single drive
since a mirror spreads reads across members, but *write* can't be spread, so a single
drive's rate is the ceiling.

## Interpreting a "low" verdict

- `ashift` mismatched against the real physical sector size (cannot be changed after pool
  creation — see [install-script.md](install-script.md#disksenv-fields))
- The HDD is SMR (drops to a few MB/s under sustained writes)
- Fewer PCIe lanes or an older generation than expected (`lspci -vv`)
- A concurrent scrub, resilver, or snapshot deletion
- If cached read isn't much faster than uncached read, the dataset doesn't fit in ARC —
  reduce `--size` or raise `arcMaxBytes`

## NVMe dropout during measurement

The script greps `journalctl -k --since "-30 min"` for `nvme.*(timeout|reset
controller|I/O error)` after the run. If found, this is flagged as **a stability problem,
not a performance one** — do not treat a good throughput number as clearance to put the
hardware into production while this shows up. See
[../decisions/2026-07-30-nvme-dropout-made-system-unbootable.md](../decisions/2026-07-30-nvme-dropout-made-system-unbootable.md)
for the incident this check is guarding against (the script's original comment pointed at
"README's NVMe dropout section", which predates the docs restructure — this is that
content's new home).

## When you change this file

Update this doc in the same commit if the expected-value table, options, or the
uncached/cached measurement method change.
