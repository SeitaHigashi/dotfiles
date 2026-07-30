{ lib, ... }:

##############################################################################
# disko によるディスクレイアウト宣言。
#
#   SSD  : part1 EFI / part2 swap / part3 slog(既定は予約のみ) / part4 rpool(残り全部)
#   HDD×2: 全体を1パーティションにして dpool の mirror
#
# このファイル1枚から
#   - パーティショニング
#   - zpool / データセットの作成
#   - fileSystems / swapDevices の生成
# がすべて行われます。手書きの partition.sh / datasets.sh は不要です。
#
# 実行:
#   disko --mode destroy,format,mount --flake <repo>#<hostName>
##############################################################################

let
  m = import ../machine.nix;

  # disko の topology では、"/" で始まらない member は
  #   /dev/disk/by-partlabel/disk-<disk名>-zfs
  # に解決されます。SSD には zfs パーティションが複数あるため、
  # SLOG はフルパス (by-partlabel) で指定する必要があります。
  slogDev  = "/dev/disk/by-partlabel/disk-ssd-slog";

  # 全データセット共通の ZFS プロパティ
  commonRootFsOptions = {
    compression = "zstd";
    acltype = "posixacl";
    xattr = "sa";
    dnodesize = "auto";
    relatime = "on";
    # canmount=off にするとプールのルートデータセットはマウントされず、
    # disko が zpool create に -m none を付けてくれる。
    # ここで mountpoint="none" も書くと zpool create に -m none と
    # -O mountpoint=none が二重に渡るので書かないこと。
    # (canmount は継承されないプロパティなので子データセットには波及しない)
    canmount = "off";
    "com.sun:auto-snapshot" = "false";
  };

  # mountpoint=legacy を使い、マウントは NixOS の fileSystems に一本化する。
  # (zfs-mount.service と systemd mount unit の競合を避けるため)
  fsDataset = mountpoint: extraOptions: {
    type = "zfs_fs";
    inherit mountpoint;
    options = { mountpoint = "legacy"; } // extraOptions;
  };

  snapshotted = { "com.sun:auto-snapshot" = "true"; };
  notSnapshotted = { "com.sun:auto-snapshot" = "false"; };

  # /nix は NixOS wiki の指示どおり、非 POSIX なプロパティを付けない。
  # (normalization / utf8only / atime=off / snapdir=visible / acltype=nfsv4)
  # atime=off ではなく relatime=on を使う。ストアは再現可能なのでスナップショット不要。
  nixDataset = fsDataset "/nix" ({ relatime = "on"; } // notSnapshotted);

  onRpool = m.nixPool == "rpool";
in
{
  assertions = [
    {
      assertion = builtins.elem m.nixPool [ "rpool" "dpool" ];
      message = "machine.nix: nixPool は \"rpool\" か \"dpool\" にしてください (現在: ${m.nixPool})";
    }
  ];

  disko.devices = {
    ############################################################################
    # ディスク
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

            # part2 — swap
            #   ZFS 上の swapfile はデッドロックするので生パーティションを使う。
            #   randomEncryption = 起動ごとにランダム鍵 (ハイバネート不可。ZFS では意図どおり)。
            swap = {
              priority = 2;
              size = m.swapSize;
              type = "8200";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };

            # part3 — SLOG
            #   useSlog = false のときは content を付けない。
            #   disko は「pool を宣言したのに topology に無いデバイス」があると
            #   プール作成をスキップするため、未使用時は予約だけにする必要がある。
            slog = {
              priority = 3;
              size = m.slogSize;
              content = lib.mkIf m.useSlog {
                type = "zfs";
                pool = "dpool";
              };
            };

            # part4 — rpool (システム用プール)。SSD の残り全部。
            #
            #   かつてここは固定サイズ (rpoolSize) で、残りは part5 の
            #   読み込みキャッシュ用でした。廃止したので rpool が残りを吸収します。
            #   理由は下の zpool.dpool のコメントを参照。
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

      # HDD は 100% を1パーティションにして dpool へ。
      # disko の topology が member を by-partlabel で解決するため、
      # 素のディスクではなくパーティションにしておくのが安全。
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
    # プール
    ############################################################################
    zpool = {
      #########################################################################
      # rpool — SSD 単体。システム本体。
      #   single vdev なので冗長性なし。ここが飛んでも /home は dpool に残る。
      #########################################################################
      rpool = {
        type = "zpool";
        # 単一 vdev なので topology 不要
        mode = "";
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
          "tmp"     = fsDataset "/tmp"     ({ sync = "disabled"; } // notSnapshotted);
        } // lib.optionalAttrs onRpool { "nix" = nixDataset; };
      };

      #########################################################################
      # dpool — HDD ×2 mirror。データ用。
      #
      #   ★ cache vdev (L2ARC) は使いません。読み込みキャッシュは ARC だけで
      #     処理します。この方針は変更しないでください。★
      #
      #   かつては SSD の一部を dpool の cache に充てていましたが、実運用で
      #   次の障害を起こしたため廃止しました:
      #     NVMe の I/O タイムアウト → コントローラリセット → キャッシュ供給と
      #     zfs スレッドが blocked → journald の watchdog タイムアウト →
      #     シャットダウン不能 → 強制リセット → プール未 export →
      #     次回起動時に initrd が import に失敗して起動不能。
      #
      #   cache は常時 SSD へ書き込むため寿命を確実に削る一方、ARC に十分な
      #   RAM がある構成では効果がほぼありません (実機では ARC 上限 16 GiB に
      #   対し実使用 1 GiB 程度で、まったく出番が無かった)。
      #   DRAM レスの廉価 SSD では書き込みレイテンシ悪化の主因にもなります。
      #
      #   読み込み性能が足りないと感じたら、cache を足すのではなく
      #   machine.nix の arcMaxBytes (= RAM) を増やしてください。
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

            # special / dedup vdev は使わない。
            # SSD 1台で special を足すと、その SSD が死んだ時点で
            # HDD ミラーごと全損する (cache/log と違い special はプールの一部)。
          };
        };
        options = {
          ashift = m.ashift;
        };
        rootFsOptions = commonRootFsOptions;

        datasets = {
          "home" = fsDataset "/home" snapshotted;
          "srv"  = fsDataset "/srv"  snapshotted;

          # Minecraft (FTB Evolution) のワールドと mod。
          # modules/ftb-evolution.nix のコンテナがここを /data として使います。
          #
          # 独立したデータセットにしておくと、ワールドだけをスナップショット・
          # ロールバックできます (modpack 更新で壊れたときの巻き戻しが容易)。
          # recordsize は既定の 128K のまま。region ファイルは大きく、
          # 小さくしてもメタデータが増えるだけで得がありません。
          "srv/minecraft" = fsDataset "/srv/minecraft" snapshotted;

          # rpool の複製先 (modules/replication.nix)。
          #
          # rpool は single vdev で冗長性が無いため、SSD が死ぬとシステムが
          # 丸ごと消えます。ここへ定期的に zfs send しておけば、
          # ディスク交換後に受信側から巻き戻すだけで復旧できます。
          #
          # マウントしない (mountpoint = "none")。受信したデータセットが
          # 元の / や /var を上書きマウントしてしまう事故を防ぐためです。
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
