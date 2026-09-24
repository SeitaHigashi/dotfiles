{ config, lib, pkgs, ... }:

##############################################################################
# Exposes ZFS snapshot and syncoid replication status to Grafana.
#
# Docs: docs/services/textfile-metrics.md#zfs-snapshot-metricsnix--snapshot-and-replication-health
#       docs/runbooks/textfile-metrics.md
#
# Update the docs above in the same commit when you change this file.
##############################################################################

let
  # Directory read by node_exporter's textfile collector. Paired with
  # modules/monitoring.nix's extraFlags.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  collector = pkgs.writeShellApplication {
    name = "zfs-snapshot-metrics";
    runtimeInputs = [ config.boot.zfs.package pkgs.gawk pkgs.coreutils ];
    text = ''
      out="${textfileDir}/zfs-snapshots.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # Gather three kinds of information separately, then merge with one
      # awk. Could be done with fewer zfs invocations, but piping outputs of
      # different shapes through a single pipeline gets unreadable.
      #
      # -p forces raw seconds/bytes instead of human units ("1.5G").
      zfs list -H -o name                        > "$work/datasets"
      zfs get -Hp -o name,value usedbysnapshots  > "$work/usedby"
      zfs list -t snapshot -H -p -o name,creation > "$work/snapshots"

      gawk -F'\t' '
        FILENAME ~ /datasets$/  { seen[$1] = 1; next }
        FILENAME ~ /usedby$/    { usedby[$1] = $2; next }

        # A snapshot name is "dataset@label"; bucket by the part before @.
        {
          at = index($1, "@")
          ds = substr($1, 1, at - 1)
          count[ds]++
          t = $2 + 0
          if (!(ds in newest) || t > newest[ds]) newest[ds] = t
          if (!(ds in oldest) || t < oldest[ds]) oldest[ds] = t
        }

        END {
          print "# HELP zfs_snapshot_count Number of snapshots this dataset has"
          print "# TYPE zfs_snapshot_count gauge"
          print "# HELP zfs_snapshot_latest_creation_seconds Creation time of the newest snapshot (unix seconds)"
          print "# TYPE zfs_snapshot_latest_creation_seconds gauge"
          print "# HELP zfs_snapshot_oldest_creation_seconds Creation time of the oldest snapshot (unix seconds)"
          print "# TYPE zfs_snapshot_oldest_creation_seconds gauge"
          print "# HELP zfs_dataset_usedbysnapshots_bytes Space referenced only by snapshots"
          print "# TYPE zfs_dataset_usedbysnapshots_bytes gauge"

          for (ds in seen) {
            # Report 0 even for a dataset with no snapshots at all. Without
            # this, "never collected" and "stopped being collected" are
            # indistinguishable on a dashboard where a missing series just
            # disappears.
            n = (ds in count) ? count[ds] : 0
            printf "zfs_snapshot_count{dataset=\"%s\"} %d\n", ds, n

            if (ds in newest) {
              printf "zfs_snapshot_latest_creation_seconds{dataset=\"%s\"} %d\n", ds, newest[ds]
              printf "zfs_snapshot_oldest_creation_seconds{dataset=\"%s\"} %d\n", ds, oldest[ds]
            }

            if (ds in usedby) {
              printf "zfs_dataset_usedbysnapshots_bytes{dataset=\"%s\"} %d\n", ds, usedby[ds]
            }
          }
        }
      ' "$work/datasets" "$work/usedby" "$work/snapshots" > "$work/out"

      # Pool health. See docs/services/textfile-metrics.md for why this is
      # piggybacked on this unit instead of getting its own.
      {
        echo "# HELP zfs_pool_health 1 if the pool is anything other than ONLINE (check zpool status)"
        echo "# TYPE zfs_pool_health gauge"
        zpool list -H -o name,health | while IFS=$'\t' read -r pool health; do
          if [ "$health" = "ONLINE" ]; then bad=0; else bad=1; fi
          echo "zfs_pool_health{pool=\"$pool\"} $bad"
        done
      } >> "$work/out"

      # Liveness of the collection itself. If this value is stale, none of
      # the numbers above can be trusted (timer stopped / zfs command
      # failing).
      {
        echo "# HELP zfs_snapshot_metrics_last_run_seconds When this collection last succeeded (unix seconds)"
        echo "# TYPE zfs_snapshot_metrics_last_run_seconds gauge"
        echo "zfs_snapshot_metrics_last_run_seconds $(date +%s)"
      } >> "$work/out"

      # Build on the same filesystem as textfileDir before mv (so mv is an
      # atomic rename(2)), preventing node_exporter from reading a partial
      # file. mktemp -d under /tmp would be a different filesystem, so the
      # work is moved into textfileDir first.
      staging=$(mktemp "${textfileDir}/.zfs-snapshots.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  # node_exporter runs as User=node-exporter under ProtectSystem=strict, which
  # is enough to read this directory; only the root unit below writes to it.
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];

  systemd.services.zfs-snapshot-metrics = {
    description = "Export ZFS snapshot status as a node_exporter textfile";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;

      # zfs list is read-only but needs to open /dev/zfs, which requires a
      # `zfs allow` delegation for non-root -- not scalable as datasets are
      # added. Runs as a short-lived read-only root unit instead, with write
      # access narrowed to the textfile directory.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.zfs-snapshot-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # autoSnapshot's shortest interval is 15 minutes, so 5 minutes tracks it
      # comfortably; polling faster surfaces no new information.
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      # Stagger slightly so this doesn't overlap other services right at boot.
      RandomizedDelaySec = "30s";
      Persistent = true;
    };
  };

  # Manual verification: docs/runbooks/textfile-metrics.md
}
