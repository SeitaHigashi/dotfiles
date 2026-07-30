{ config, lib, pkgs, ... }:

##############################################################################
# FTB Evolution (Minecraft modpack サーバー) を podman コンテナで動かす。
#
# 何をしているか:
#   itzg/minecraft-server イメージを rootful podman で常駐させ、
#   ワールドと mod 一式を dpool (HDD mirror) 上の /srv/minecraft に置きます。
#   modpack 本体はコンテナ初回起動時に FTB の API から自動ダウンロードされます
#   (TYPE=FTBA + FTB_MODPACK_ID)。手動で ZIP を配置する必要はありません。
#
# データを dpool に置く理由:
#   ワールドは再生成できない唯一のデータです。rpool は single vdev で
#   冗長性が無いため (disko/default.nix 参照)、SSD が死ぬと消えます。
#   dpool は HDD ×2 の mirror なので片方が死んでも生き残ります。
#   /srv 配下は com.sun:auto-snapshot=true なので自動スナップショットも効きます。
#
# 注意:
#   コンテナの状態 (/var/lib/containers) は rpool 側に残りますが、
#   イメージは再取得できるので複製対象外で構いません。
##############################################################################

let
  m = import ../machine.nix;

  # FTB API 上の modpack ID。
  #   curl https://api.feed-the-beast.com/v1/modpacks/public/modpack/125
  # で "name": "FTB Evolution" が返ることを確認できます。
  ftbModpackId = "125";

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
  #   dpool/srv/minecraft (disko/default.nix) が /srv/minecraft にマウントされ、
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
      # FTB_MODPACK_VERSION_ID を指定しなければ最新版が入ります。
      # バージョンを固定したい場合は下のコメントを外して ID を書いてください。
      TYPE = "FTBA";
      FTB_MODPACK_ID = ftbModpackId;
      # FTB_MODPACK_VERSION_ID = "";

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
    ];

    autoStart = true;
  };

  # 初回起動は modpack のダウンロードとワールド生成で十数分かかります。
  # 既定のタイムアウトだと systemd が起動失敗と見なして殺すので伸ばします。
  systemd.services.podman-ftb-evolution.serviceConfig = {
    TimeoutStartSec = "30min";
    TimeoutStopSec = "180";
  };

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
  #   世代確認  : zfs list -t snapshot -r dpool/srv/minecraft
  #
  # modpack を更新したいときは上の FTB_MODPACK_VERSION_ID を書き換えて
  # nixos-rebuild switch してください。ワールドは /srv/minecraft/data に
  # 残るので引き継がれますが、更新前にスナップショットを取ることを推奨します:
  #   zfs snapshot dpool/srv/minecraft@before-update
  ############################################################################
}
