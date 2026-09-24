{ lib, ... }:

##############################################################################
# Declarative disk layout via disko: partitioning, zpool/dataset creation, and
# fileSystems/swapDevices generation all come from this one file.
#
# Docs: docs/storage-zfs.md (layout/design), docs/runbooks/install.md (running
# disko), docs/runbooks/zfs-operations.md (adding a dataset to a live system).
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  # SSD has multiple zfs partitions, so SLOG must be given as a full by-partlabel
  # path (see docs/storage-zfs.md §3.2 for how disko resolves bare member names).
  slogDev  = "/dev/disk/by-partlabel/disk-ssd-slog";

  # ZFS properties shared by every dataset.
  commonRootFsOptions = {
    compression = "zstd";
    acltype = "posixacl";
    xattr = "sa";
    dnodesize = "auto";
    relatime = "on";
    # canmount=off keeps the pool's root dataset unmounted (disko passes -m none
    # to zpool create). Do not also set mountpoint="none" here — that would pass
    # both -m none and -O mountpoint=none. canmount doesn't inherit to children.
    canmount = "off";
    "com.sun:auto-snapshot" = "false";
  };

  # mountpoint=legacy; all actual mounting goes through NixOS's fileSystems
  # (avoids zfs-mount.service fighting the systemd mount unit).
  fsDataset = mountpoint: extraOptions: {
    type = "zfs_fs";
    inherit mountpoint;
    options = { mountpoint = "legacy"; } // extraOptions;
  };

  snapshotted = { "com.sun:auto-snapshot" = "true"; };
  notSnapshotted = { "com.sun:auto-snapshot" = "false"; };

  # /nix skips the non-POSIX properties per the NixOS wiki (docs/storage-zfs.md §3.4).
  nixDataset = fsDataset "/nix" ({ relatime = "on"; } // notSnapshotted);

  onRpool = m.nixPool == "rpool";
in
{
  assertions = [
    {
      assertion = builtins.elem m.nixPool [ "rpool" "dpool" ];
      message = "machine.nix: nixPool must be \"rpool\" or \"dpool\" (currently: ${m.nixPool})";
    }
  ];

  disko.devices = {
    ############################################################################
    # Disks
    ############################################################################
    disk = {
      ssd = {
        type = "disk";
        device = m.ssd;
        content = {
          type = "gpt";
          partitions = {
            # part1 — EFI System Partition
            ESP = {
              priority = 1;
              size = m.efiSize;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            # part2 — swap. A ZFS-backed swapfile can deadlock, so a raw partition
            # is used instead. randomEncryption = fresh random key per boot
            # (no hibernation, which is fine — intentional under ZFS anyway).
            swap = {
              priority = 2;
              size = m.swapSize;
              type = "8200";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };

            # part3 — SLOG. No `content` when useSlog = false: disko skips pool
            # creation if a `pool`-declaring device is missing from the topology
            # (docs/storage-zfs.md §3.1), so it must stay reserved-only when unused.
            slog = {
              priority = 3;
              size = m.slogSize;
              content = lib.mkIf m.useSlog {
                type = "zfs";
                pool = "dpool";
              };
            };

            # part4 — rpool (system pool), the rest of the SSD. Used to be a fixed
            # size with part5 as a read-cache vdev for dpool; that vdev was removed
            # (see the zpool.dpool comment below), so rpool now absorbs the rest.
            rpool = {
              priority = 4;
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };

      # Each HDD is one 100% partition into dpool. Using a partition rather than
      # the raw disk is safer since disko's topology resolves members by-partlabel.
      hdd1 = {
        type = "disk";
        device = m.hdd1;
        content = {
          type = "gpt";
          partitions.zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "dpool";
            };
          };
        };
      };

      hdd2 = {
        type = "disk";
        device = m.hdd2;
        content = {
          type = "gpt";
          partitions.zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "dpool";
            };
          };
        };
      };
    };

    ############################################################################
    # Pools
    ############################################################################
    zpool = {
      #########################################################################
      # rpool — single SSD, the system itself. Single vdev, no redundancy: if it
      # dies the system is gone, but /home and /srv survive on dpool.
      #########################################################################
      rpool = {
        type = "zpool";
        mode = ""; # single vdev, no topology needed
        options = {
          ashift = m.ashift;
          autotrim = "on";
        };
        rootFsOptions = commonRootFsOptions;

        datasets = {
          "root"    = fsDataset "/"        snapshotted;
          "var"     = fsDataset "/var"     snapshotted;
          "var/log" = fsDataset "/var/log" notSnapshotted;
          "var/lib" = fsDataset "/var/lib" snapshotted;

          # Time-series DB (VictoriaMetrics, modules/monitoring.nix). Split off
          # for its own snapshot cadence and to drop out of syncoid's
          # rpool/var/lib replication; recordsize=16K matches its small writes;
          # mounts at /var/lib/private/ (DynamicUser=true — see
          # docs/storage-zfs.md §4 for why). Rationale: docs/storage-zfs.md §4.
          "var/lib/victoriametrics" =
            fsDataset "/var/lib/private/victoriametrics" ({ recordsize = "16K"; } // notSnapshotted);

          # Log store (Loki, modules/monitoring.nix). Same rationale as
          # VictoriaMetrics above, but mounts directly at /var/lib/loki — loki
          # runs under a fixed user, not DynamicUser. docs/storage-zfs.md §4.
          "var/lib/loki" =
            fsDataset "/var/lib/loki" ({ recordsize = "16K"; } // notSnapshotted);

          # LLM model store (modules/ollama.nix). Split off so GGUF churn (each
          # re-fetchable via `ollama pull`) doesn't bloat snapshots/replication;
          # recordsize=1M + compression=off for large, already-compressed reads.
          # Mounts at /var/lib/private/ollama (DynamicUser=true). docs/storage-zfs.md §4.
          "var/lib/ollama" =
            fsDataset "/var/lib/private/ollama" ({ recordsize = "1M"; compression = "off"; } // notSnapshotted);

          # Parent placeholder for rpool/srv/minecraft below; not mounted itself
          # (/srv proper stays on dpool/srv). Declared explicitly because neither
          # disko nor zfs recv auto-creates intermediate datasets.
          "srv" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              "com.sun:auto-snapshot" = "false";
            };
          };

          # Minecraft (FTB Evolution) world + mods; modules/ftb-evolution.nix
          # mounts this as /data. Lives on rpool (NVMe), not dpool, because the
          # dpool HDD is SMR and stalled autosave writes past the server's own
          # watchdog — see decisions/2026-07-31-minecraft-restarting-on-60s-tick.md.
          # Not redundant on its own (rpool is single-vdev): modules/replication.nix
          # syncoid's it to dpool/backup/minecraft daily — do not change one
          # without the other. recordsize left at default 128K (region files are
          # large; shrinking only adds metadata overhead).
          "srv/minecraft" = fsDataset "/srv/minecraft" ({ atime = "off"; } // snapshotted);

          "tmp"     = fsDataset "/tmp"     ({ sync = "disabled"; } // notSnapshotted);
        } // lib.optionalAttrs onRpool { "nix" = nixDataset; };
      };

      #########################################################################
      # dpool — HDD ×2 mirror, for data.
      #
      # **No cache vdev (L2ARC). Read caching is ARC-only. Do not add one back.**
      # A cache vdev on the SSD was removed after it contributed to an unbootable
      # system (NVMe I/O timeout → controller reset → ZFS threads blocked →
      # journald watchdog → forced reset → pool never exported → initrd import
      # fails next boot). See decisions/2026-07-30-nvme-dropout-made-system-unbootable.md
      # and docs/storage-zfs.md §5. If read performance is lacking, raise
      # arcMaxBytes in machine.nix instead of adding a cache vdev.
      #########################################################################
      dpool = {
        type = "zpool";
        mode = {
          topology = {
            type = "topology";
            vdev = [
              {
                mode = "mirror";
                members = [ "hdd1" "hdd2" ];
              }
            ];
            log = lib.optionals m.useSlog [ { members = [ slogDev ]; } ];

            # No special/dedup vdev: unlike cache/log, special becomes part of
            # the pool, so a single-SSD special vdev dying takes the HDD mirror
            # with it. docs/storage-zfs.md §1 "Do not do this".
          };
        };
        options = {
          ashift = m.ashift;
        };
        rootFsOptions = commonRootFsOptions;

        datasets = {
          "home" = fsDataset "/home" snapshotted;
          "srv"  = fsDataset "/srv"  snapshotted;

          # The Minecraft world lives on rpool, not here — see the "srv/minecraft"
          # comment above. dpool's only role for it is as the replication target
          # (backup, below).

          # ComfyUI (modules/comfyui.nix) venv + model store. On dpool (opposite
          # call from ollama's rpool placement): checkpoints run large (tens to
          # 100+ GiB) and rpool has finite capacity; ComfyUI's I/O is bulk/
          # low-frequency/non-realtime, unlike Minecraft's watchdog-sensitive
          # small writes, so the SMR HDD is an acceptable trade (at some cost to
          # checkpoint-load latency vs NVMe). recordsize=1M/compression=off for
          # the same reason as the ollama dataset. Mounts directly at
          # /var/lib/comfyui — fixed user, not DynamicUser (modules/comfyui.nix).
          # Rationale: docs/storage-zfs.md §4.
          "comfyui" =
            fsDataset "/var/lib/comfyui" ({ recordsize = "1M"; compression = "off"; } // notSnapshotted);

          # OpenViking (modules/openviking.nix) workspace/vector DB. On dpool's
          # mirror for redundancy, notSnapshotted like ComfyUI. Writes are async
          # and post-session rather than realtime-watchdog-sensitive like
          # Minecraft, so the SMR HDD is judged acceptable; revisit moving to
          # rpool if writes stall in practice. docs/storage-zfs.md §4.
          "var/lib/openviking" = fsDataset "/var/lib/openviking" notSnapshotted;

          # Replication target for rpool (modules/replication.nix). rpool has no
          # redundancy, so this daily zfs send is what lets a dead SSD be
          # recovered by receiving back from here — including the Minecraft
          # world, the one dataset on rpool that can't be regenerated from the
          # flake. mountpoint="none" so a received dataset can never shadow-mount
          # over the live / or /var.
          "backup" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              "com.sun:auto-snapshot" = "false";
            };
          };
        } // lib.optionalAttrs (!onRpool) { "nix" = nixDataset; };
      };
    };
  };
}
