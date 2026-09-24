# Textfile-collector metrics

Implementations:
[`modules/nix-info.nix`](../../modules/nix-info.nix),
[`modules/nix-profile-info.nix`](../../modules/nix-profile-info.nix),
[`modules/zfs-snapshot-metrics.nix`](../../modules/zfs-snapshot-metrics.nix),
[`modules/gpu-xid-metrics.nix`](../../modules/gpu-xid-metrics.nix)

These four modules all follow the same shape: no dedicated exporter exists (or the
existing exporter is missing the metric), so a `oneshot` systemd service shells out,
writes a `.prom` file into node_exporter's textfile-collector directory, and a timer
re-runs it periodically. See [monitoring](monitoring.md) for how VictoriaMetrics/
Grafana pick these metrics up.

Shared conventions across all four:

- Textfile directory: `/var/lib/prometheus-node-exporter-text-files` (same constant
  in every module, must match `modules/monitoring.nix`'s node_exporter `extraFlags`).
- **Atomic write**: build the full output under `$work` (a `mktemp -d`), then
  `mktemp` a staging file *inside* the textfile directory, `cat` the output into it,
  `chmod 0444`, then `mv -f` into place. The staging file must be created on the same
  filesystem as the final path so the `mv` is a `rename(2)` — a `mktemp -d` under
  `/tmp` would be a different filesystem and turn the final move into a non-atomic
  copy, letting node_exporter read a half-written file mid-scrape.
- Each collector emits a `..._last_run_seconds` gauge so a stalled timer/failed run
  is visible in Grafana even though the rest of the metrics still look plausible.
- Collectors run as short-lived root oneshot units with `ProtectSystem = "strict"` and
  `ReadWritePaths = [ textfileDir ]` — the writer is a narrowly-scoped root unit,
  not the node_exporter process itself (which stays an unprivileged reader).
- When a collector is retired or its output filename changes, the old `.prom` file
  must be deleted via `systemd.tmpfiles.rules` (`"r <path> - - - -"`). Nothing else
  will delete it — the textfile collector reads every `*.prom` file it finds, so an
  orphaned file from a retired collector keeps being scraped forever. This bit twice:
  `repology-package-status.prom` (nix-info.nix) and `nix-profile-repology-status.prom`
  (nix-profile-info.nix), both after the Repology→direct-eval switch — see
  [2026-09-23 Repology to direct nix eval](../decisions/2026-09-23-repology-to-direct-nix-eval.md).

Verification commands for all four: [runbooks/textfile-metrics.md](../runbooks/textfile-metrics.md).

## nix-info.nix — installed packages, upstream diff, Hydra status

Three independent concerns bundled into one module:

1. **`nixos-package-metrics`** — one line per entry in `environment.systemPackages`
   (`nixos_installed_package_info{name,version}`), plus a total count. Computed
   entirely in the Nix expression at eval time (not shelled out), so the generated
   `.prom` file's *content* changes whenever `systemPackages` changes, and a plain
   `nixos-rebuild switch` re-triggers the oneshot unit automatically (systemd detects
   the changed store path). No timer needed for this one.

   Duplicate package names with different versions (e.g. `fuse` 2.9.9 and 3.16.2 both
   installed) are collapsed to first-seen — Prometheus rejects a metric emitted twice
   with the same label set (confirmed in the journal, 2026-09-06: node_exporter logged
   `collected metric ... was collected before with the same name and label values`
   every 30s until this was fixed).

2. **`nixos-package-upstream-metrics`** (timer: 10 min after boot, then daily) —
   per-package "is a newer version available upstream" check, resolved by evaluating
   the tracked nixpkgs channel directly rather than querying Repology (see the
   decision record below for why). Metrics:
   `nixos_package_upstream_attr_resolved{name}`, `nixos_package_upstream_known{name}`,
   `nixos_package_upstream_version_info{name,version}`, `nixos_package_outdated{name}`,
   `nixos_channel_resolve_ok{channel}`, `nixos_channel_revision_info{channel,rev}`.
   `attr_resolved=0` means the package's nixpkgs attribute path could not be
   identified by drvPath matching (see below) — no `known`/`outdated` is emitted for
   it, since there is nothing to guess from.

3. **`hydra-build-metrics`** (timer: 2 min after boot, then every 6h) — queries
   `hydra.nixos.org`'s public JSON API for the two channels this host tracks
   (`nixos/release-25.05-small` for the stable branch named in `flake.lock`,
   `nixpkgs/unstable` for `nixos-unstable`), and reports whether the pinned revision
   has appeared in Hydra's recent evaluations plus the timestamp of the latest
   evaluation. Metrics: `hydra_channel_last_eval_timestamp_seconds{channel}`,
   `hydra_pinned_revision_evaluated{channel}`, `hydra_fetch_ok{channel}`.

### attrPath resolution (systemPackages side)

`environment.systemPackages` entries only carry a `pname`/`version`/`drvPath` — not
the nixpkgs attribute path. Measured 2026-09-23: of 216 installed packages, only 92
are found directly at the top level of `pkgs`. The rest are mostly KDE Plasma
components under `kdePackages.*` (dolphin, kwin, kio, konsole, baloo, breeze, …) and
glibc's multi-output derivations (`getconf-glibc-*`, `getent-glibc-*`,
`glibc-locales`).

Resolution tries each candidate scope (top level, `kdePackages`, `libsForQt5`,
`plasma5Packages`, `python3Packages`, `nodePackages`) under each candidate base
(`pkgs`, `pkgs.unstable`), and accepts the first `<base>.<scope>.<pname>` whose
`drvPath` exactly matches the installed derivation's `drvPath`. Every lookup goes
through `builtins.tryEval` because removed aliases (e.g. `libsForQt5.kio-admin`)
still exist as attributes but `throw` the moment they're referenced. Whichever base
matches also tells you the tracked channel for that package (`pkgs.unstable` →
`nixos-unstable`, `pkgs` → the stable ref from `flake.lock`) — this subsumed a
previous separate `isFromUnstable` flag, now removed. Packages with no matching
candidate are reported as unresolved (`attr_resolved=0`); the code never guesses
from the name alone.

Once resolved, all attrPaths for a channel are evaluated in a **single** bulk
`nix eval --json <channel>#legacyPackages.x86_64-linux --apply <fn>` call rather than
one `nix eval` per package — measured ~0.6s for 216 attributes with a warm
evaluation cache, versus per-package process-startup and cache-rebuild overhead
compounding badly at that scale. attrPath components are pre-split into
`["scope" "pname"]` lists on the Nix side and passed as-is; no string splitting
happens in shell or inside the `--apply` expression, keeping the splitting logic in
one place.

## nix-profile-info.nix — `nix profile` (imperative installs)

Same idea as nix-info.nix's package list, but for `nix profile install`-managed
packages (e.g. `claude-code`, `rtk`, `ccusage`, `llmfit` — measured 4 elements as of
2026-09-23) rather than `environment.systemPackages`. The key difference: profile
contents are **not known at Nix evaluation time** — `nix profile install` doesn't go
through `nixos-rebuild switch` and can change the profile generation at any moment.
So unlike nix-info.nix's package-list collector, this one can't rely on "the eval
output changed, switch re-triggers the unit" — it needs a periodic timer instead
(every 15 min).

Source of truth: `~/.local/state/nix/profiles/profile/manifest.json` for the
monitored user(s) (`profileUsers = [ "seita" ]` — add more users there to have both
collectors follow them). This is read directly as JSON via `jq`, rather than calling
`nix profile list --json`, because the latter round-trips through the nix daemon's
evaluator (heavier) and reading another user's profile that way needs `HOME`/
`XDG_STATE_HOME` impersonation.

Two collectors:

1. **`nix-profile-metrics`** (timer: 3 min after boot, then every 15 min) — one line
   per profile element (`nix_profile_package_info{user,name,version,channel}`), a
   per-user count, the active generation number, and the generation's real creation
   time. `nix_profile_collector_ok{user}` distinguishes "manifest unreadable" (e.g.
   user has never run `nix profile install`) from "zero packages" — the metric count
   is intentionally omitted in the unreadable case rather than reported as `0`.

   The generation's timestamp is **not** `manifest.json`'s mtime — that file lives
   in `/nix/store` and its mtime is always normalized to 1 (epoch+1), confirmed by
   `stat` on the live host, 2026-09-23. The real timestamp comes from `lstat` on the
   generation symlink itself (`profile-N-link`).

2. **`nix-profile-upstream-metrics`** (timer: 12 min after boot, then daily) — same
   "is a newer version available" idea as nix-info.nix's upstream collector, but
   simpler: each manifest element already records its own `originalUrl` and
   `attrPath`, so no drvPath-matching search is needed — one `nix eval --raw` per
   package resolves the upstream version directly (measured ~0.3s per lookup, warm
   store). Elements without `attrPath`/`originalUrl` (old-format installs, direct
   store-path installs) are reported as `nix_profile_package_upstream_known=0` since
   there is nothing to look up. Metrics:
   `nix_profile_package_upstream_known{user,name}`,
   `nix_profile_package_upstream_version_info{user,name,version}`,
   `nix_profile_package_outdated{user,name}`,
   `nix_profile_channel_resolve_ok{channel}`,
   `nix_profile_channel_revision_info{channel,rev}`.

Both collectors use a shared `jq` filter (`manifestToTsv`, embedded as a `.jq` file)
to turn a manifest element into a `name/version/ref/attrPath/originalUrl` TSV row, so
version-string parsing (stripping the 32-character store-path hash and the package
name prefix from the basename) isn't duplicated between the two collectors.

Both `nix flake metadata` calls (here and in nix-info.nix) pass `--refresh` —
without it, the channel tarball's 1-hour TTL cache can return a stale evaluation and
silently under-report available updates.

### systemd sandboxing notes (both nix-info.nix and nix-profile-info.nix upstream collectors)

Calling `nix` from inside a systemd unit needs three things that an interactive
shell gets for free:

- `HOME` — nix caches flake evaluations under `~/.cache/nix`; without it each run
  either re-evaluates from scratch or fails outright. Given via `StateDirectory` +
  an explicit `HOME=/var/lib/<unit>` environment variable.
- `NIX_REMOTE=daemon` explicit — under `ProtectSystem = "strict"`, `/nix` is
  read-only, so store writes must go through the daemon rather than directly.
- Network access — fetching the channel's tarball. Reflected in
  `RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]` (`AF_UNIX` for the
  nix daemon socket, `AF_INET`/`AF_INET6` for the channel fetch).

`nix-profile-info.nix`'s collectors additionally need `ProtectHome = "read-only"`
rather than `true` (nix-info.nix's setting) — they read into the monitored user's
home directory, so it can't be hidden entirely, but is kept read-only to prevent
accidental writes into the profile.

## zfs-snapshot-metrics.nix — snapshot and replication health

Why this exists: snapshots and replication (via `syncoid`, see
[`modules/replication.nix`](../../modules/replication.nix)) are the kind of thing
that fails silently. If `autoSnapshot` stops or `syncoid` stops actually sending
data, nothing observable happens day-to-day — the failure only becomes visible when
someone tries to restore, by which point it's too late. This collector turns
`zfs list` into numbers so `dashboards/40-zfs-replication.json` shows the state at a
glance.

No off-the-shelf ZFS snapshot exporter exists in nixpkgs; node_exporter's own zfs
collector reports ARC and pool I/O stats but not snapshot ages or counts.

Measured: `zfs list -t snapshot` over 285 snapshots takes ~0.26s — negligible at the
5-minute polling interval (`OnBootSec = "2min"`, `OnUnitActiveSec = "5min"`; 5 min
is also the practical floor since `autoSnapshot`'s shortest interval is 15 min, so
polling faster than that surfaces no new information).

The headline metric is **replication lag**: the gap between `dpool/backup/X`'s
newest snapshot and the source `rpool/X`'s newest snapshot is directly "how much
would be lost if the SSD died right now." This is more trustworthy than the
`syncoid` unit's own exit code, which can report success even when nothing was
actually transferred (e.g. the source has no snapshot to send) — `syncoid-rpool-*`
unit state itself is already covered by node_exporter's systemd collector
(`node_systemd_unit_state`), so this module doesn't duplicate that.

Metrics: `zfs_snapshot_count{dataset}`, `zfs_snapshot_latest_creation_seconds{dataset}`,
`zfs_snapshot_oldest_creation_seconds{dataset}`,
`zfs_dataset_usedbysnapshots_bytes{dataset}`. Datasets with zero snapshots still get
a `zfs_snapshot_count=0` row rather than being omitted — omitting them would make
"never had a snapshot" indistinguishable from "collector stopped reporting this
dataset" on a Grafana panel where a missing series just silently disappears.

Also emits **pool health** (`zfs_pool_health{pool}`, 1 = not `ONLINE`, needs
`zpool status` to diagnose) — a different concern from snapshots, piggybacked here
because node_exporter doesn't report it and there's no reason to run a second
root-privileged `zfs`-calling unit just for this. The health string itself
(`DEGRADED` vs `FAULTED`, etc.) is deliberately collapsed to a 0/1 gauge rather than
kept as a label — the operator response is "go look at `zpool status`" either way,
and a label would grow a new series every time the string changes.

Runs as a short-lived root oneshot (reading `/dev/zfs` needs root or a `zfs allow`
delegation per dataset, which doesn't scale as datasets are added) with write access
narrowed to the textfile directory only.

## gpu-xid-metrics.nix — NVIDIA Xid fatal-error detection

Why this exists — incident, 2026-08-28: GPU1 (`0000:06:00.0`) fell off the PCIe bus
(Xid 79, "GPU has fallen off the bus"), and the driver raised Xid 154 ("Node Reboot
Required") on both GPUs. `nvidia-smi` could no longer enumerate GPU1; Ollama fell
back to CPU inference (the `nvidia-gpu-exporter` scrape target itself stayed up, so
no `scrape-target-down` alert fired); OpenViking's summary/extract tasks failed
outright with `APITimeoutError`. The failure wasn't noticed until the next morning,
when the user reported "summary tasks have all been failing since last night" — a
detection lag of several hours.

`modules/monitoring.nix`'s `nvidia-gpu-exporter` (nvidia_smi-based) does not surface
Xid at all — neither the utkuozdemir nor mindprince exporter supports it (also noted
in `README.md`'s NVIDIA-limitations list). Xid only appears in the kernel log, so
`journalctl` is the only way to see it.

Same textfile-collector rationale as zfs-snapshot-metrics.nix: no dedicated exporter
exists, and reading `journalctl -k -b 0` every 2 minutes is cheap enough to not
matter.

**State, not a counter**: Xid 79/154 are fatal conditions with no self-recovery —
the only remediation the driver itself calls for is a reboot. That makes this
conceptually the same as `zfs_pool_health`: a point-in-time state read fresh every
run (`journalctl -k -b 0`, current boot only), not a monotonic counter needing a
cursor. Re-reading from scratch each time avoids cursor-file corruption/gaps, and
`-b 0` means a past incident can't keep being misreported after the next reboot.

Metrics: `gpu_xid_events_current_boot{pci,xid}` (counter, count of times each Xid
code has appeared in the current boot's log), `gpu_reboot_required{pci}` (1 if a
fatal Xid — 79 or 154 — has appeared for that PCI address in the current boot).
Only Xid 79 and 154 are treated as fatal; other Xids (e.g. 13, "Graphics Engine
Exception") can be raised by benign causes such as shader bugs, so they're tracked
neither for alerting nor for `gpu_reboot_required` — the list is deliberately
conservative to avoid false "reboot required" alerts.

Timer: 1 min after boot, then every 2 minutes — tighter than the ZFS collector's
5 minutes, because for this failure mode, detection lag directly becomes outage
duration.
