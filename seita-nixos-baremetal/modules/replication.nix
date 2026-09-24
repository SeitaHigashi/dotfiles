{ config, lib, pkgs, ... }:

##############################################################################
# Periodic replication of rpool (SSD) to dpool (HDD mirror) via syncoid, so a
# dead SSD can be recovered by receiving back from dpool/backup instead of
# losing rpool's contents outright (rpool is a single vdev, no redundancy).
#
# This is NOT a backup: same-chassis replication does nothing against fire,
# theft, or whole-enclosure failure. Take real backups to external media or a
# separate host.
#
# Docs: docs/storage-zfs.md §6 (design, what's replicated and why),
# docs/runbooks/zfs-operations.md (recovery procedure).
# When you change this file, update the docs above in the same commit.
##############################################################################

{
  services.syncoid = {
    enable = true;

    # Once daily; rpool's contents are mostly system config and logs, for which
    # this is enough. Use "hourly" etc. for a tighter RPO.
    interval = "daily";

    # Delegate only the needed ZFS permissions to a dedicated syncoid user
    # (without this it would have to run as root).
    localSourceAllow = [ "bookmark" "hold" "send" "snapshot" "destroy" "mount" ];
    localTargetAllow = [ "change-key" "compression" "create" "mount" "mountpoint" "receive" "rollback" "destroy" ];

    commonArgs = [
      # Don't create syncoid's own snapshots; rely on autoSnapshot's instead.
      "--no-sync-snap"
      # Keep the sender's compression as-is (local transfer, so recompressing wastes CPU).
      "--compress=none"
    ];

    commands = {
      # / (the system itself)
      "rpool/root" = {
        target = "dpool/backup/root";
        recursive = false;
      };

      # /var/lib — service state, including podman containers/volumes.
      "rpool/var/lib" = {
        target = "dpool/backup/var-lib";
        recursive = false;
      };

      # /srv/minecraft — world + mods. Unlike root/var-lib (rebuildable from the
      # flake, replication just for speed), the world can't be regenerated at
      # all; this is its only redundancy since it sits on rpool
      # (disko/default.nix). Daily is enough because rpool's own 15-minute
      # autoSnapshot already covers modpack-update mishaps and world rollback —
      # this only matters if the SSD physically dies, at which point up to a
      # day is lost. To shorten that, set interval = "hourly" on this entry
      # specifically rather than raising services.syncoid.interval globally
      # (which would also affect root and var-lib).
      "rpool/srv/minecraft" = {
        target = "dpool/backup/minecraft";
        recursive = false;
      };
    };
  };

  ############################################################################
  # Not replicated
  #
  #   rpool/var/log … logs. Not needed for recovery, high write churn.
  #   rpool/tmp     … sync=disabled, expected to vanish on reboot anyway.
  #   rpool/nix     … nix store, fully reproducible from the flake (present
  #                   when machine.nix's nixPool = "rpool").
  #
  # The nix store especially is large and highly volatile; replicating it
  # would waste HDD space for no recovery benefit — nixos-install is faster
  # and more reliable for recovery.
  #
  # Verify it's working:
  #   systemctl list-timers | grep syncoid
  #   journalctl -u 'syncoid-*' --since today
  #   zfs list -t snapshot -r dpool/backup
  ############################################################################
}
