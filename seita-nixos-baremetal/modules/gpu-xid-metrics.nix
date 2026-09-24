{ config, lib, pkgs, ... }:

##############################################################################
# Exposes NVIDIA Xid errors (fatal GPU faults that only ever appear in the
# kernel log) as a node_exporter textfile, so Grafana alerting can catch them.
#
# Docs: docs/services/textfile-metrics.md#gpu-xid-metricsnix--nvidia-xid-fatal-error-detection
#       docs/decisions/2026-08-28-gpu-xid-monitoring.md
#       docs/runbooks/textfile-metrics.md
#
# Update the docs above in the same commit when you change this file.
##############################################################################

let
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Xids treated as fatal (reboot required, or the GPU is effectively
  # unusable). 79 = GPU has fallen off the bus, 154 = GPU recovery action
  # changed to Node Reboot Required (both confirmed on this host,
  # 2026-08-28). Other Xids deliberately excluded — see
  # docs/decisions/2026-08-28-gpu-xid-monitoring.md.
  fatalXids = [ "79" "154" ];

  collector = pkgs.writeShellApplication {
    name = "gpu-xid-metrics";
    runtimeInputs = [ pkgs.systemd pkgs.gawk pkgs.coreutils ];
    text = ''
      out="${textfileDir}/gpu-xid.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # Current boot's kernel log only -- see docs/decisions/2026-08-28-gpu-xid-monitoring.md.
      journalctl -k -b 0 -g 'NVRM: Xid' -o cat > "$work/xid-lines" || true

      gawk -v fatal="${lib.concatStringsSep " " fatalXids}" '
        BEGIN {
          split(fatal, arr, " ")
          for (i in arr) isFatal[arr[i]] = 1
        }
        # e.g. "NVRM: Xid (PCI:0000:06:00): 79, pid=... GPU has fallen off the bus."
        match($0, /Xid \(PCI:([0-9a-fA-F:.]+)\): ([0-9]+)/, m) {
          pci = m[1]
          xid = m[2]
          seen[pci] = 1
          count[pci, xid]++
          if (xid in isFatal) rebootRequired[pci] = 1
        }
        END {
          print "# HELP gpu_xid_events_current_boot Number of Xid events observed in the current boot"
          print "# TYPE gpu_xid_events_current_boot counter"
          for (key in count) {
            split(key, parts, SUBSEP)
            printf "gpu_xid_events_current_boot{pci=\"%s\",xid=\"%s\"} %d\n", parts[1], parts[2], count[key]
          }

          print "# HELP gpu_reboot_required 1 if a fatal Xid (fallen off the bus, etc.) has appeared in the current boot"
          print "# TYPE gpu_reboot_required gauge"
          for (pci in seen) {
            bad = (pci in rebootRequired) ? 1 : 0
            printf "gpu_reboot_required{pci=\"%s\"} %d\n", pci, bad
          }
        }
      ' "$work/xid-lines" > "$work/out"

      {
        echo "# HELP gpu_xid_metrics_last_run_seconds When this collection last succeeded (unix seconds)"
        echo "# TYPE gpu_xid_metrics_last_run_seconds gauge"
        echo "gpu_xid_metrics_last_run_seconds $(date +%s)"
      } >> "$work/out"

      # Atomic replace via mv (same reasoning as zfs-snapshot-metrics.nix).
      staging=$(mktemp "${textfileDir}/.gpu-xid.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];

  systemd.services.gpu-xid-metrics = {
    description = "Export NVIDIA Xid errors as a node_exporter textfile";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;

      # journalctl -k is readable without privilege (no SystemdJournalGatewayd
      # ACL in use), but this runs as the same short-lived root unit pattern
      # as zfs-snapshot-metrics for consistency, with write access narrowed
      # to the textfile directory only.
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.gpu-xid-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Tighter than the ZFS collectors (5min) because for a fatal GPU fault,
      # time-to-detection directly becomes outage duration. journalctl -k -b 0
      # only reads the current boot, so 2-minute polling is negligible load.
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      RandomizedDelaySec = "15s";
      Persistent = true;
    };
  };

  # Manual verification: docs/runbooks/textfile-metrics.md
}
