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
    "http://127.0.0.1:${toString config.services.n8n.settings.port}/healthz"
  ];

  nixAutoUpdate = pkgs.writeShellApplication {
    name = "nix-auto-update";
    runtimeInputs = [
      config.nix.package.out
      config.system.build.nixos-rebuild
      pkgs.gitMinimal
      pkgs.util-linux # runuser
      pkgs.getent
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
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
        echo "skip: working tree is dirty"
        exit 0
      fi
      head_system=$(as_owner nix eval --raw "$flake#nixosConfigurations.$host.config.system.build.toplevel.outPath")
      if [ "$head_system" != "$(readlink -f /run/current-system)" ]; then
        echo "skip: HEAD ($head_system) is not the running system — switch it by hand first"
        exit 0
      fi

      as_owner nix flake update ${lib.escapeShellArgs autoInputs}
      if as_owner git diff --quiet -- flake.lock; then
        echo "nothing to update"
        exit 0
      fi

      healthy() {
        local url
        for url in ${lib.escapeShellArgs healthUrls}; do
          # up to ~5 min per service (first start after an upgrade runs migrations)
          curl -fsS -o /dev/null --max-time 5 --retry 30 --retry-delay 10 --retry-all-errors "$url" || return 1
        done
      }

      if nixos-rebuild switch --flake "$flake#$host" && healthy; then
        as_owner git commit --quiet -m "chore(flake): auto-update ${lib.concatStringsSep " " autoInputs}" -- flake.lock
        echo "updated: $(readlink -f /run/current-system)"
      else
        # Back to the last good lock. Binaries only: a DB migrated by the new
        # version is NOT rolled back (docs/services/auto-update.md).
        echo "update failed; restoring flake.lock and switching back" >&2
        as_owner git checkout -- flake.lock
        nixos-rebuild switch --flake "$flake#$host"
        exit 1
      fi
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

  config = {
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
  };
}
