{ lib, pkgs, ... }:

##############################################################################
# CPU package energy (RAPL) as a node_exporter textfile counter.
#
# energy_uj is root-only (0400); node_exporter's own rapl collector therefore
# exports nothing. Rather than loosening that permission, this root oneshot
# copies the counter into the textfile directory (same pattern as
# zfs-snapshot-metrics.nix). Feeds dashboards/90-power.json.
#
# Docs: docs/services/monitoring.md#power-90-powerjson
##############################################################################

let
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";
  zone = "/sys/class/powercap/intel-rapl:0";

  collector = pkgs.writeShellApplication {
    name = "rapl-metrics";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
    text = ''
      uj=$(cat ${zone}/energy_uj)
      staging=$(mktemp "${textfileDir}/.rapl.XXXXXX")
      cat > "$staging" <<EOF
      # HELP node_rapl_package_joules_total CPU package energy (RAPL package-0), cumulative joules
      # TYPE node_rapl_package_joules_total counter
      node_rapl_package_joules_total{index="0"} $(echo "$uj" | awk '{printf "%.6f", $1/1e6}')
      EOF
      chmod 0444 "$staging"
      mv -f "$staging" "${textfileDir}/rapl.prom"
    '';
  };
in
{
  systemd.services.rapl-metrics = {
    description = "Export CPU package energy (RAPL) as a node_exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.rapl-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Matches the 30s scrape interval. The counter wraps at
      # max_energy_range_uj (~65 kJ, tens of minutes under load); rate()
      # treats the wrap as a counter reset, losing at most one interval.
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
      AccuracySec = "1s";
    };
  };
}
