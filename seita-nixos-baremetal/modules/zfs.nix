{ config, lib, pkgs, ... }:

# ZFS core: ARC, autoScrub/trim/autoSnapshot, smartd, NVMe workarounds.
# Docs: docs/storage-zfs.md §5 (ARC/NVMe tuning rationale, measurements),
# docs/runbooks/zfs-operations.md (scrub/snapshot/backup procedures),
# decisions/2026-07-30-nvme-dropout-made-system-unbootable.md.
# When you change this file, update the docs above in the same commit.

let
  m = import ../machine.nix;

  # ARC ceiling, roughly 1/4-1/2 of physical RAM (set in machine.nix).
  # e.g. 8G=8589934592, 12G=12884901888, 16G=17179869184, 32G=34359738368
  arcMaxBytes = m.arcMaxBytes;

  # zfs_arc_sys_free: computed as arcMaxBytes/4 here rather than added as its own
  # machine.nix field, to avoid an install.sh/disks.env schema change.
  # Rationale: docs/storage-zfs.md §5.
  arcSysFreeBytes = arcMaxBytes / 4;
in
{
  ############################################################################
  # ZFS core
  ############################################################################
  # attrset form (nixpkgs 24.05+); the old [ "zfs" ] list form is deprecated.
  boot.supportedFilesystems.zfs = true;

  # ZFS doesn't always track the newest kernel, so stick to LTS
  # (pkgs.linuxPackages is nixpkgs's default LTS series).
  #
  # Switching to linuxPackages_latest can pull in a kernel ZFS doesn't support
  # yet, making the system unbootable. If rebuild prints
  #   error: ... zfs ... is not supported on kernel ...
  # wait for nixpkgs to catch up rather than bumping the kernel.
  #
  # Kernel and ZFS must always come from the same nixpkgs (stable). Do not use
  # modules/unstable.nix's pkgs.unstable.* here.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;

  # Hibernation can corrupt a ZFS pool, so it stays disabled.
  boot.zfs.allowHibernation = false;

  # Directory scanned at import time (same as the NixOS default). disko creates
  # pools under /dev/disk/by-partlabel/disk-<disk>-<part>, but ZFS matches on the
  # label GUID rather than the path, so scanning by-id still finds the same
  # partitions. Just avoid bus-dependent names (/dev/sda). If import fails, try
  # "/dev/disk/by-partlabel" instead.
  boot.zfs.devNodes = "/dev/disk/by-id";

  # Keep at the NixOS default (true).
  #
  # Setting this to false makes initrd refuse to import a pool whose hostid
  # doesn't match the running system, leaving it unbootable. disko/nixos-install
  # create pools under the installer ISO's hostid, so a mismatch is guaranteed
  # right after install unless zpool export ran cleanly — one crash or missed
  # export and you're stuck. This has actually happened; see
  # decisions/2026-07-30-nvme-dropout-made-system-unbootable.md and
  # docs/runbooks/zfs-troubleshooting.md.
  #
  # false only makes sense for SAN/shared-storage setups where another host may
  # genuinely be using the same pool. true is correct for a local-disks-only box.
  boot.zfs.forceImportRoot = true;

  # Only list pools here if they don't otherwise appear in fileSystems.
  # rpool/dpool are referenced via disko's fileSystems, so this stays empty.
  # boot.zfs.extraPools = [ ];

  ############################################################################
  # ARC tuning — rationale and measurements: docs/storage-zfs.md §5
  ############################################################################
  boot.kernelParams = [
    "zfs.zfs_arc_max=${toString arcMaxBytes}"
    "zfs.zfs_arc_sys_free=${toString arcSysFreeBytes}"

    ##########################################################################
    # NVMe dropout workarounds — see decisions/2026-07-30-nvme-dropout-made-system-unbootable.md
    ##########################################################################

    # Disable APST (automatic power-saving states); kept permanently as cheap
    # insurance even after replacing the failing drive. docs/storage-zfs.md §5.
    "nvme_core.default_ps_max_latency_us=0"

    # nvme_core.io_timeout is left at its 30s default — do not re-extend it.
    # docs/storage-zfs.md §5 has the history of why it was raised and reverted.
  ];

  ############################################################################
  # Automatic maintenance
  ############################################################################

  # Monthly scrub (default: first Sunday)
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
    # omitting `pools` targets every pool
  };

  # Periodic TRIM for the SSD (rpool); harmless for the HDDs.
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # Automatic snapshots. To exclude a dataset:
  #   zfs set com.sun:auto-snapshot=false <dataset>
  services.zfs.autoSnapshot = {
    enable = true;
    flags = "-k -p --utc";
    frequent = 4;    # every 15 min, x4
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 12;
  };

  # To email on pool problems (requires MTA setup):
  # services.zfs.zed.settings = {
  #   ZED_EMAIL_ADDR = [ "root" ];
  #   ZED_NOTIFY_VERBOSE = true;
  # };
  services.zfs.zed.enableMail = false;

  ############################################################################
  # Convenience tools
  ############################################################################
  environment.systemPackages = with pkgs; [
    zfs        # zpool / zfs / arc_summary / zdb
    smartmontools
    nvme-cli   # nvme smart-log / get-feature — needed for NVMe failure diagnosis
  ];

  ############################################################################
  # Disk health monitoring — rationale: docs/storage-zfs.md §5
  # Manual check: sudo smartctl -a /dev/nvme0 ; sudo nvme smart-log /dev/nvme0
  ############################################################################
  services.smartd = {
    enable = true;
    autodetect = true;

    # -a          monitor all attributes
    # -o on       enable offline self-test
    # -S on       enable attribute autosave
    # -n standby  don't wake idle HDDs (avoid needless spin-up)
    # -W 4,50,60  log/warn on a 4C jump, or crossing 50C/60C
    # No mail transport configured, so warnings only reach the journal
    # (journalctl -u smartd).
    defaults.autodetected = "-a -o on -S on -n standby -W 4,50,60";
  };
}
