{ config, lib, pkgs, ... }:

##############################################################################
# FTB Evolution (Minecraft modpack サーバー) を podman コンテナで動かす。
#
# 何をしているか:
#   itzg/minecraft-server イメージを rootful podman で常駐させ、
#   ワールドと mod 一式を rpool (NVMe) 上の /srv/minecraft に置きます。
#   modpack 本体はコンテナ初回起動時に FTB の API から自動ダウンロードされます
#   (TYPE=FTBA + FTB_MODPACK_ID)。手動で ZIP を配置する必要はありません。
#
# データを rpool (SSD) に置く理由:
#   かつては dpool (HDD mirror) に置いていましたが、HDD が SMR のため
#   チャンクの定期オートセーブが write(2) で 60 秒以上返らず、Minecraft の
#   ServerHangWatchdog がサーバーを落とすのを 1 日 7 回起こしました。
#   クラッシュレポートのスレッドダンプはいずれも
#     "Server thread" RUNNABLE
#       at sun.nio.ch.UnixFileDispatcherImpl.write0(Native Method)
#       ... MinecraftServer.saveAllChunks / tickServer
#   で、mod ではなく純粋な I/O 待ちでした。
#   ZFS は blk-cgroup を通らず IOWeight が効かないため
#   (modules/resource-priority.nix 参照)、NVMe に載せる以外に手がありません。
#
#   ワールドは再生成できない唯一のデータですが、rpool は single vdev で
#   冗長性がありません。そこを modules/replication.nix の syncoid が
#   dpool/backup/minecraft への日次複製で埋めています。
#   /srv/minecraft は com.sun:auto-snapshot=true なので、15 分刻みの
#   自動スナップショットも rpool 側に残ります。
#
# 注意:
#   コンテナの状態 (/var/lib/containers) も rpool 側にありますが、
#   イメージは再取得できるので複製対象外で構いません。
##############################################################################

let
  m = import ../machine.nix;

  # FTB API 上の modpack ID。
  #   curl https://api.feed-the-beast.com/v1/modpacks/public/modpack/125
  # で "name": "FTB Evolution" が返ることを確認できます。
  ftbModpackId = "125";

  # 上の modpack のバージョン ID。
  #   curl https://api.feed-the-beast.com/v1/modpacks/public/modpack/125/100442
  # で "name": "1.40.1" / "type": "release" が返ります
  # (MC 1.21.1 + NeoForge 21.1.243 + Java 21 = 下のイメージタグと一致)。
  # 新しい版の ID は modpack/125 のレスポンス中の "versions" から拾えます。
  ftbModpackVersionId = "100442";

  # サーバーに渡すヒープサイズ。
  # machine.nix の arcMaxBytes (ZFS ARC 上限 = 16 GiB) と足して
  # 物理 RAM を超えないこと。超えると OOM killer が ZFS ごと巻き込みます。
  memory = "8G";

  dataDir = "/srv/minecraft";

  port = 25565;

  # LAN 内からのみ接続させる。
  #
  # podman が publish したポートは DNAT + FORWARD を通るため、
  # NixOS の firewall (INPUT チェーン) だけでは絞りきれません。
  # そこで「待ち受けアドレスそのもの」を LAN の静的 IP に限定します。
  # 静的 IP を使っていない (DHCP) 構成では全アドレスで待ち受けます。
  listenAddress =
    if m.staticAddress == null
    then ""
    else "${lib.head (lib.splitString "/" m.staticAddress)}:";
in
{
  ############################################################################
  # podman
  ############################################################################
  virtualisation.podman = {
    enable = true;

    # docker コマンドを podman の別名として生やす。
    # virtualisation.docker.enable = true とは同時に使えません
    # (どちらも /run/docker.sock を握るため)。
    dockerCompat = true;

    # コンテナ同士を名前で解決できるようにする。単体運用では必須ではないが、
    # 後で管理用コンテナを足したときに効いてきます。
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  ############################################################################
  # データディレクトリ
  #   rpool/srv/minecraft (disko/default.nix) が /srv/minecraft にマウントされ、
  #   その中身の所有者をここで整えます。
  #   itzg イメージは既定で uid/gid 1000 として動くのでそれに合わせます。
  ############################################################################
  systemd.tmpfiles.rules = [
    "d ${dataDir}      0750 1000 1000 -"
    "d ${dataDir}/data 0750 1000 1000 -"
  ];

  ############################################################################
  # コンテナ
  ############################################################################
  virtualisation.oci-containers.containers.ftb-evolution = {
    # FTB Evolution は新しい Minecraft (Java 21 要求) なので java21 タグを使う。
    # latest ではなく明示しておくと、イメージ更新で JRE が変わって
    # 起動しなくなる事故を防げます。
    image = "docker.io/itzg/minecraft-server:java21";

    ports = [ "${listenAddress}${toString port}:25565" ];

    volumes = [ "${dataDir}/data:/data" ];

    environment = {
      # Minecraft EULA への同意。これが無いとサーバーは起動しません。
      EULA = "TRUE";

      # FTB App の API から modpack を取得する。
      #
      # VERSION_ID は必ず固定しておくこと。未指定だとコンテナが起動する
      # たびに最新版へ勝手に上がります。このユニットは Restart=always なので、
      # サーバーがクラッシュして再起動した拍子に modpack がメジャー更新され、
      # プレイヤーのクライアント側 mod とバージョンがずれる事故になります。
      TYPE = "FTBA";
      FTB_MODPACK_ID = ftbModpackId;
      FTB_MODPACK_VERSION_ID = ftbModpackVersionId;

      # ヒープ。INIT/MAX を揃えて GC の伸縮によるラグを避ける。
      INIT_MEMORY = memory;
      MAX_MEMORY = memory;

      TZ = "Asia/Tokyo";

      # コンテナ内のプロセスを 1000:1000 で動かす (tmpfiles の所有者と一致させる)
      UID = "1000";
      GID = "1000";
    };

    extraOptions = [
      # 停止時にワールドを保存しきる余裕を持たせる。
      # 既定の 10 秒だと SIGKILL でチャンクが失われることがあります。
      "--stop-timeout=120"

      # cgroup を machine.slice ではなく専用スライスに置く。
      #
      # rootful podman はコンテナを podman-*.service の cgroup の下ではなく
      # machine.slice 直下の libpod-<id>.scope に移します。つまり systemd
      # ユニット側に CPUWeight を書いても JVM には一切効きません
      # (実測: ユニット cpu.weight=1000 / コンテナ cpu.weight=100)。
      # scope 名はコンテナ ID なので nix から名指しできず、代わりに
      # 親スライスを指定して、そのスライスに重みを付けています。
      # 値は modules/resource-priority.nix の minecraft.slice を参照。
      "--cgroup-parent=minecraft.slice"
    ];

    autoStart = true;
  };

  # systemd 側のタイムアウトは oci-containers モジュールが設定済みです
  # (TimeoutStartSec=0 = 無制限、TimeoutStopSec=120)。
  # 初回の modpack ダウンロードで殺されることはありません。

  ############################################################################
  # ファイアウォール
  #
  # 待ち受けを LAN IP に限定したうえで、ホストの INPUT も開けておく。
  # (podman のネットワーク実装によっては INPUT を通るため)
  ############################################################################
  networking.firewall.allowedTCPPorts = [ port ];

  ############################################################################
  # 運用メモ
  #
  #   状態確認  : systemctl status podman-ftb-evolution
  #   ログ      : journalctl -u podman-ftb-evolution -f
  #   コンソール: podman exec -i ftb-evolution rcon-cli
  #   停止      : systemctl stop podman-ftb-evolution
  #   世代確認  : zfs list -t snapshot -r rpool/srv/minecraft
  #   複製確認  : zfs list -t snapshot -r dpool/backup/minecraft
  #
  # バックアップ:
  #   modpack 同梱の FTB Backups 3 は無効化してあります。
  #   1.5 GB の zip を 2 時間ごとに作り、ZFS スナップショットと役割が
  #   完全に重複したうえ、書き込みの大半を占めていたためです。
  #   設定は data/world/serverconfig/ftbbackups3-server.snbt の auto: false。
  #   (config/ 側ではなく world/serverconfig/ 側に置くこと。config/ は
  #    modpack 更新で上書きされます)
  #   復旧は ZFS 側で行います:
  #     zfs list -t snapshot -r rpool/srv/minecraft
  #     zfs rollback rpool/srv/minecraft@<スナップショット名>
  #   SSD ごと失った場合は dpool/backup/minecraft から受信し直します。
  #
  # modpack を更新したいときは上の ftbModpackVersionId を書き換えて
  # nixos-rebuild switch してください。ワールドは /srv/minecraft/data に
  # 残るので引き継がれますが、更新前にスナップショットを取ること:
  #   zfs snapshot dpool/srv/minecraft@before-update
  #
  # コンテナイメージ (itzg) の側は自動更新されません。oci-containers が
  # 生成する ExecStartPre は podman rm -f だけで pull を含まないため、
  # 一度取得したタグは再起動でも rebuild でも据え置きです。上げたいときは:
  #   podman pull docker.io/itzg/minecraft-server:java21
  #   systemctl restart podman-ftb-evolution
  ############################################################################
}
