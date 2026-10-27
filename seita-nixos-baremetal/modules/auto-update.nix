{ config, lib, pkgs, ... }:

##############################################################################
# Unattended updates, two independent halves:
#
#   A. podman containers  — podman's own auto-update (label + timer)
#   B. pkgs.auto.* (the nixpkgs-auto flake input) — nightly
#      `nix flake update nixpkgs-auto` -> switch -> health check -> commit
#
# Docs: docs/services/auto-update.md   scope, guards, failure handling, opt-out
#
# When you change this file, update the doc above in the same commit.
##############################################################################

let
  # Inputs the nightly job may move. Everything else in flake.lock (stable
  # nixpkgs, nixpkgs-unstable = llama.cpp etc.) stays manual.
  autoInputs = [ "nixpkgs-auto" ];

  # Services restarted by an update that have a health endpoint to wait on.
  healthUrls = [
    "http://127.0.0.1:${toString config.services.open-webui.port}/health"
    "http://127.0.0.1:5678/healthz" # n8n's port, paired with modules/n8n.nix (26.05 removed services.n8n.settings)
  ];

  # Results go through host-notify (modules/notify.nix, docs/services/notify.md).
  # It always exits 0, so a notification problem never fails or rolls back an update.
  notifyPkg = config.local.notify.package;

  nixAutoUpdate = pkgs.writeShellApplication {
    name = "nix-auto-update";
    runtimeInputs = [
      config.nix.package.out
      pkgs.gitMinimal
      pkgs.util-linux # runuser
      pkgs.getent
      pkgs.coreutils
      pkgs.curl
      notifyPkg
      config.systemd.package # journalctl
    ];
    text = ''
      # Anything that dies under `set -e` (eval, flake update) leaves status=failed.
      status=failed
      msg="unexpected error"
      report() {
        local level=error log=""
        case "$status" in
          updated) level=info ;;
          unchanged) level=debug ;;
          skipped) level=warning ;;
          *) log=$(journalctl "_SYSTEMD_INVOCATION_ID=''${INVOCATION_ID:-none}" -n 40 -o cat --no-pager 2>/dev/null || true) ;;
        esac
        printf '%s' "$log" | host-notify nix-auto-update "$level" "$status" \
          "$msg (system: $(readlink -f /run/current-system))"
      }
      trap report EXIT

      flake=$(readlink -f /etc/nixos)
      host=${config.networking.hostName}
      owner=$(stat -c %U "$flake")
      owner_home=$(getent passwd "$owner" | cut -d: -f6)
      # git and `nix flake update` run as the repo owner, so flake.lock and
      # .git never end up root-owned and the commit uses the owner's identity.
      as_owner() { runuser -u "$owner" -- env HOME="$owner_home" "$@"; }
      cd "$flake"

      # Never activate work the user has not switched themselves: skip unless
      # the tree is clean AND HEAD evaluates to the running system.
      if [ -n "$(as_owner git status --porcelain)" ]; then
        status=skipped msg="working tree is dirty"
        echo "skip: $msg"
        exit 0
      fi
      head_system=$(as_owner nix eval --raw "$flake#nixosConfigurations.$host.config.system.build.toplevel.outPath")
      if [ "$head_system" != "$(readlink -f /run/current-system)" ]; then
        status=skipped msg="HEAD ($head_system) is not the running system — switch it by hand first"
        echo "skip: $msg"
        exit 0
      fi

      as_owner nix flake update ${lib.escapeShellArgs autoInputs}
      if as_owner git diff --quiet -- flake.lock; then
        status=unchanged msg="nothing to update"
        echo "$msg"
        exit 0
      fi

      healthy() {
        local url
        for url in ${lib.escapeShellArgs healthUrls}; do
          # up to ~5 min per service (first start after an upgrade runs migrations)
          curl -fsS -o /dev/null --max-time 5 --retry 30 --retry-delay 10 --retry-all-errors "$url" || return 1
        done
      }

      # Built as the repo owner, activated as root: root's nix refuses to open a
      # git repo it does not own (plain `nixos-rebuild` only works under sudo).
      activate() {
        local system
        system=$(as_owner nix build --no-link --print-out-paths "$flake#nixosConfigurations.$host.config.system.build.toplevel") || return 1
        nix-env -p /nix/var/nix/profiles/system --set "$system" || return 1
        "$system/bin/switch-to-configuration" switch
      }

      if activate && healthy; then
        as_owner git commit --quiet -m "chore(flake): auto-update ${lib.concatStringsSep " " autoInputs}" -- flake.lock
        status=updated msg="${lib.concatStringsSep " " autoInputs} updated and switched"
        echo "updated: $(readlink -f /run/current-system)"
      else
        msg="build, activation or health check failed; flake.lock restored and switched back"
        # Back to the last good lock. Binaries only: a DB migrated by the new
        # version is NOT rolled back (docs/services/auto-update.md).
        echo "update failed; restoring flake.lock and switching back" >&2
        as_owner git checkout -- flake.lock
        activate
        exit 1
      fi
    '';
  };

  # Wraps `podman auto-update` so its per-container result reaches host-notify.
  # Field names (ContainerName/Container/Unit, Updated) are podman's own and not
  # yet confirmed from a root run: lookups fall back so a rename degrades the
  # message instead of breaking it. The raw JSON always goes along as `log`.
  podmanAutoUpdate = pkgs.writeShellApplication {
    name = "podman-auto-update-notify";
    runtimeInputs = [ config.virtualisation.podman.package pkgs.jq pkgs.gnugrep notifyPkg ];
    text = ''
      rc=0
      out=$(podman auto-update --format json) || rc=$?
      echo "$out"
      # "name: Updated" for every container whose Updated is not "false"
      changed=$(printf '%s' "$out" | jq -r 'if type == "array" then .[] | select((.Updated // "true") != "false")
        | "\(.ContainerName // .Container // .Unit // "?"): \(.Updated // "?")" else empty end' 2>/dev/null || true)
      level=debug title="podman auto-update: nothing to update"
      if [ "$rc" -ne 0 ]; then
        level=error title="podman auto-update failed (exit $rc)"
      elif printf '%s' "$changed" | grep -qE ': (failed|rolled back)$'; then
        level=warning title="podman auto-update: some containers failed or rolled back"
      elif [ -n "$changed" ]; then
        level=info title="podman auto-update: containers updated"
      fi
      printf '%s' "$out" | host-notify podman-auto-update "$level" "$title" "$changed"
      exit "$rc"
    '';
  };
in
{
  ############################################################################
  # A. Every oci-container gets the auto-update label (present and future
  # modules). Opt one out in its own module with
  #   labels."io.containers.autoupdate" = "disabled";
  ############################################################################
  options.virtualisation.oci-containers.containers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      config.labels."io.containers.autoupdate" = lib.mkDefault "registry";
    });
  };

  config = lib.mkMerge [ {
    # Replace the packaged ExecStart ("" clears it) with the notifying wrapper;
    # the packaged ExecStartPost (image prune) stays. To revert: drop this block.
    systemd.services.podman-auto-update.serviceConfig.ExecStart = [ "" (lib.getExe podmanAutoUpdate) ];

    # The timer unit ships with podman but is not enabled by default.
    # To turn A off: wantedBy = [ ];
    systemd.timers.podman-auto-update = {
      wantedBy = [ "timers.target" ];
      # "" clears the packaged `daily` (midnight): 04:00 keeps the Minecraft
      # restart out of playing hours.
      timerConfig.OnCalendar = [ "" "04:00" ];
    };

    ##########################################################################
    # B. Nightly pkgs.auto update. To turn off: startAt = [ ];
    # Failure leaves the unit failed -> the "systemd unit is failed" alert.
    ##########################################################################
    systemd.services.nix-auto-update = {
      description = "Update the nixpkgs-auto flake input and switch";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      startAt = "04:30"; # after podman-auto-update (04:00 + up to 15 min)
      # Same guards as system.autoUpgrade: the switch this unit runs must not
      # restart or stop the unit itself.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      environment = config.nix.envVars // { HOME = "/root"; };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe nixAutoUpdate;
      };
    };
  }
  {
    # podman auto-update stops a container with SIGTERM -> exit 143, which
    # systemd would count as "failed" and fire OnFailure= (false alert, see
    # modules/notify.nix). Treat 143 as success for every container unit.
    # To revert: drop this block.
    systemd.services = lib.mapAttrs'
      (name: _: lib.nameValuePair "${config.virtualisation.oci-containers.backend}-${name}" {
        serviceConfig.SuccessExitStatus = "143";
      })
      config.virtualisation.oci-containers.containers;
  } ];
}
