{ config, lib, pkgs, ... }:

##############################################################################
# host-notify: one generic notification channel (n8n webhook -> Discord).
#
#   host-notify SOURCE LEVEL TITLE [MESSAGE]      log text on stdin (optional)
#
# Docs: docs/services/notify.md   payload, levels, how to add a client
#
# When you change this file, update the doc above in the same commit.
##############################################################################

let
  # n8n's port, paired with modules/n8n.nix. (26.05 removed
  # services.n8n.settings, which used to carry it for readers like this.)
  port = 5678;

  # Path matches the n8n workflow "Host notify to Discord" (docs/services/notify.md).
  url = "http://127.0.0.1:${toString port}/webhook/notify";

  hostNotify = pkgs.writeShellApplication {
    name = "host-notify";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      # Always exits 0: a notification problem must never fail its caller.
      if [ "$#" -lt 3 ]; then
        echo "usage: host-notify SOURCE LEVEL TITLE [MESSAGE]  (log on stdin)" >&2
        exit 0
      fi
      log=""
      if [ ! -t 0 ]; then log=$(tail -c 8000); fi
      jq -cn --arg source "$1" --arg level "$2" --arg title "$3" \
          --arg message "''${4:-}" --arg log "$log" \
          '{source: $source, level: $level, title: $title, message: $message, log: $log}' \
        | curl -fsS -o /dev/null --max-time 10 -H 'Content-Type: application/json' \
            --data @- ${lib.escapeShellArg url} \
        || echo "host-notify: POST failed" >&2
      exit 0
    '';
  };
  # n8n comes up after the host does; wait for it so the boot report is not lost.
  healthUrl = "http://127.0.0.1:${toString port}/healthz";

  # One report per boot. ExecStop drops a marker at clean shutdown; a boot that
  # finds no marker follows a crash / power loss (or is the first boot after this
  # unit was deployed, which reports one false crash).
  bootNotify = pkgs.writeShellApplication {
    name = "host-boot-notify";
    runtimeInputs = [ hostNotify pkgs.curl pkgs.coreutils config.systemd.package ];
    text = ''
      marker=/var/lib/host-boot/clean
      for _ in $(seq 60); do
        curl -fsS -o /dev/null --max-time 2 ${lib.escapeShellArg healthUrl} && break
        sleep 2
      done
      if [ -e "$marker" ]; then
        rm -f "$marker"
        host-notify host-boot info "booted" "previous shutdown was clean"
      else
        journalctl -b -1 -n 40 -o short-iso --no-pager 2>/dev/null \
          | host-notify host-boot warning "booted after a crash" \
              "previous shutdown was not clean (crash or power loss); tail of the previous boot's journal attached"
      fi
    '';
  };

  # Failure of any service -> last 40 journal lines of that unit.
  failureNotify = pkgs.writeShellApplication {
    name = "notify-failure";
    runtimeInputs = [ hostNotify config.systemd.package ];
    text = ''
      journalctl -u "$1" -n 40 -o cat --no-pager 2>/dev/null \
        | host-notify systemd warning "$1 failed" "journal tail attached"
    '';
  };
in
{
  options.local.notify.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = hostNotify;
    description = "The host-notify wrapper, for other modules' runtimeInputs.";
  };

  config = {
    environment.systemPackages = [ hostNotify ]; # for testing by hand

    systemd.services.host-boot-notify = {
      description = "Report the boot (and whether the previous shutdown was clean)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "n8n.service" "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "host-boot";
        ExecStart = lib.getExe bootNotify;
        ExecStop = "${pkgs.coreutils}/bin/touch /var/lib/host-boot/clean";
      };
    };

    # OnFailure= for every service via a top-level drop-in. The template's own
    # drop-in (same filename, more specific) clears it so a failing notifier
    # cannot loop. To revert: remove these two units entries and the template.
    systemd.units."service.d/10-notify-failure.conf".text = ''
      [Unit]
      OnFailure=notify-failure@%n.service
    '';
    systemd.units."notify-failure@.service.d/10-notify-failure.conf".text = ''
      [Unit]
      OnFailure=
    '';
    systemd.services."notify-failure@" = {
      description = "Report failure of %i";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe failureNotify} %i";
      };
    };
  };
}
