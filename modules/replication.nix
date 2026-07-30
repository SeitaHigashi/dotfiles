{ config, lib, pkgs, ... }:

##############################################################################
# rpool (SSD) を dpool (HDD mirror) へ定期複製する。
#
# なぜ必要か:
#   disko/default.nix のとおり rpool は single vdev で、冗長性がありません。
#   SSD が死ぬとシステムが丸ごと消えます (/home と /srv は dpool に残る)。
#   HDD 側は mirror なので、そこへ複製しておけば
#     新しい SSD を挿す -> disko で作り直す -> dpool から受信し直す
#   という手順で復旧できます。
#
# 何をしているか:
#   services.zfs.autoSnapshot が作るスナップショットを、syncoid が
#   dpool/backup 配下へ差分転送します。両方ローカルなのでネットワークは
#   介しません。--no-sync-snap を付けて、syncoid が独自のスナップショットを
#   増やさないようにしています (autoSnapshot の世代管理に一本化するため)。
#
# これはバックアップではありません:
#   同一筐体内の複製なので、火災・盗難・筐体ごとの故障には無力です。
#   「SSD が死んだときに素早く戻せる」ためのものです。本当のバックアップは
#   外部媒体か別ホストへ取ってください。
##############################################################################

{
  services.syncoid = {
    enable = true;

    # 毎日 1 回。もっと頻繁にしたい場合は "hourly" など。
    # rpool の中身はシステム設定とログが主なので、日次で十分です。
    interval = "daily";

    # syncoid 専用ユーザーに、必要な ZFS 権限だけを委譲する。
    # これが無いと root で動かすことになります。
    localSourceAllow = [ "bookmark" "hold" "send" "snapshot" "destroy" "mount" ];
    localTargetAllow = [ "change-key" "compression" "create" "mount" "mountpoint" "receive" "rollback" "destroy" ];

    commonArgs = [
      # 自前のスナップショットを作らない。autoSnapshot のものを使う。
      "--no-sync-snap"
      # 送信側の圧縮をそのまま使う (ローカル転送なので追加圧縮は無駄)
      "--compress=none"
    ];

    commands = {
      # / (システム本体)
      "rpool/root" = {
        target = "dpool/backup/root";
        recursive = false;
      };

      # /var/lib — サービスの状態。podman のコンテナ・ボリュームもここ。
      "rpool/var/lib" = {
        target = "dpool/backup/var-lib";
        recursive = false;
      };
    };
  };

  ############################################################################
  # 複製しないもの
  #
  #   rpool/var/log … ログ。復旧に不要で、書き込みが多く差分が大きい。
  #   rpool/tmp     … 一時ファイル。sync=disabled で再起動時に消える前提。
  #   rpool/nix     … nix store。flake から完全に再現できるので複製不要。
  #                   (machine.nix の nixPool = "rpool" のとき存在する)
  #
  # 特に nix store は容量が大きく差分も激しいため、複製すると HDD を
  # 無駄に消費します。復旧時は nixos-install で作り直す方が速くて確実です。
  #
  # 動作確認:
  #   systemctl list-timers | grep syncoid
  #   journalctl -u 'syncoid-*' --since today
  #   zfs list -t snapshot -r dpool/backup
  ############################################################################
}
