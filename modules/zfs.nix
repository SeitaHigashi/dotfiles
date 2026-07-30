{ config, lib, pkgs, ... }:

let
  m = import ../machine.nix;

  # ARC の上限。実 RAM の 1/4〜1/2 を目安に (machine.nix で設定)。
  # 例) 8G=8589934592, 12G=12884901888, 16G=17179869184, 32G=34359738368
  arcMaxBytes = m.arcMaxBytes;
in
{
  ############################################################################
  # ZFS 本体
  ############################################################################
  # nixpkgs 24.05 以降は attrset 形式 (旧: [ "zfs" ] はリスト形式で非推奨)
  boot.supportedFilesystems.zfs = true;

  # ZFS は最新カーネルに追従しないことがあるため LTS を使う。
  # pkgs.linuxPackages は nixpkgs の LTS 系デフォルト。
  #
  # linuxPackages_latest に変えると、ZFS が未対応のカーネルを引いて
  # 起動不能になることがあります。rebuild 時に
  #   error: ... zfs ... is not supported on kernel ...
  # が出たら、カーネルを上げるのではなく nixpkgs 側の追従を待ってください。
  #
  # カーネルと ZFS は必ず同じ nixpkgs (= stable 側) から取ること。
  # modules/unstable.nix の pkgs.unstable.* をここで使ってはいけません。
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;

  # ハイバネートは ZFS と組み合わせるとプール破損の可能性があるため無効のまま。
  boot.zfs.allowHibernation = false;

  # インポート時にスキャンするディレクトリ (NixOS の既定値と同じ)。
  # disko はプールを /dev/disk/by-partlabel/disk-<disk>-<part> で作りますが、
  # ZFS はパスではなくラベルの GUID で照合するため、by-id をスキャンしても
  # 同じパーティションが見つかります。バス依存名 (/dev/sda) だけは避けること。
  # うまくインポートできない場合は "/dev/disk/by-partlabel" を試す。
  boot.zfs.devNodes = "/dev/disk/by-id";

  # NixOS の既定値 (true) のままにしておくこと。
  #
  # false にすると、プールの hostid が現在のシステムと違う場合に initrd が
  # インポートを拒否し、起動不能になります。disko/nixos-install は installer ISO の
  # hostid でプールを作るため、インストール直後は必ず不一致が起きます
  # (クリーンに zpool export していれば問題になりませんが、異常終了や
  #  export し忘れが1度でもあると詰みます)。実際にこれで起動不能になりました。
  #
  # false が意味を持つのは SAN / 共有ストレージのように、他ホストが同じプールを
  # 現に使っている可能性がある構成だけです。ローカルディスク専用機では true が正解。
  boot.zfs.forceImportRoot = true;

  # fileSystems に出てこないプールがある場合だけ列挙する。
  # rpool / dpool は modules/zfs-layout.nix の fileSystems で参照されているため不要。
  # boot.zfs.extraPools = [ ];

  ############################################################################
  # ARC チューニング
  #
  # ★ 読み込みキャッシュは ARC (RAM) だけで処理します。SSD を使う二次キャッシュ
  #   (L2ARC / cache vdev) は廃止しました。復活させないでください。★
  #   理由は disko/default.nix の dpool のコメントを参照。要約すると、SSD を
  #   常時削る一方で ARC に余裕がある構成では効果が無く、実機で NVMe の
  #   I/O タイムアウト → ZFS ハング → 起動不能を招いたためです。
  #
  # 読み込みが遅いと感じたら arcMaxBytes (machine.nix) を上げてください。
  # 現状の確認: arc_summary | head -40
  ############################################################################
  boot.kernelParams = [
    "zfs.zfs_arc_max=${toString arcMaxBytes}"

    ##########################################################################
    # NVMe の脱落対策
    #
    # 廉価 NVMe (DRAM レス / HMB 方式) で実際に起きた障害への対策です。
    #   nvme nvme0: I/O tag NN timeout, aborting req_op:WRITE
    #   nvme nvme0: Admin Cmd QID 0 timeout, reset controller
    # コントローラリセットが起きると、その NVMe 上の rpool が固まり、
    # ZFS スレッドが hung_task になってシャットダウンすら完走できなくなります。
    # 結果としてプールが未 export のまま強制リセットされ、次回起動時に
    # initrd の import が失敗して起動不能になります (README の障害事例を参照)。
    ##########################################################################

    # APST (自動省電力ステート) を無効化。
    # 低電力ステートからの復帰に失敗して脱落する既知の不具合を回避する。
    # 既定は 100000 (us)。0 で APST を使わなくなる。
    #
    # 消費電力がわずかに増えるだけで副作用は無いため、SSD を交換した後も
    # 保険として残しています。
    "nvme_core.default_ps_max_latency_us=0"

    # nvme_core.io_timeout は既定 (30 秒) のままにします。
    #
    # 以前は 255 秒に延長していました。DRAM レス SSD が SLC キャッシュ枯渇で
    # 数十秒応答しなくなるのを「故障」と誤認させないための延命策です。
    # DRAM 搭載 SSD ではその失速が起きないため不要ですし、延ばしたままだと
    # 本物の故障を 4 分間も見逃すことになります。早く顕在化させる方が安全です。
  ];

  ############################################################################
  # 自動メンテナンス
  ############################################################################

  # 毎月スクラブ (既定: 第1日曜)
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
    # pools を省略すると全プールが対象になる
  };

  # SSD (rpool) 向けの定期 TRIM。HDD には無害。
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # 自動スナップショット。除外したいデータセットには
  #   zfs set com.sun:auto-snapshot=false <dataset>
  services.zfs.autoSnapshot = {
    enable = true;
    flags = "-k -p --utc";
    frequent = 4;    # 15分ごと x 4
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 12;
  };

  # プール異常をメールで通知したい場合 (要 MTA 設定)
  # services.zfs.zed.settings = {
  #   ZED_EMAIL_ADDR = [ "root" ];
  #   ZED_NOTIFY_VERBOSE = true;
  # };
  services.zfs.zed.enableMail = false;

  ############################################################################
  # 便利ツール
  ############################################################################
  environment.systemPackages = with pkgs; [
    zfs        # zpool / zfs / arc_summary / zdb
    smartmontools
    nvme-cli   # nvme smart-log / get-feature。NVMe の障害調査に必須
  ];

  ############################################################################
  # ディスクの健康監視
  #
  # smartd を有効にするだけでは通知先が無く、SMART の異常を誰も見ません。
  # 実機では NVMe の Percentage Used (寿命消費率) が 78% に達していたのに
  # 気付けませんでした。ジャーナルに残るようログレベルを上げ、
  # 属性変化を必ず記録させます。
  #   手動確認: sudo smartctl -a /dev/nvme0
  #             sudo nvme smart-log /dev/nvme0
  ############################################################################
  services.smartd = {
    enable = true;
    autodetect = true;

    # -a       全属性を監視
    # -o on    オフライン自己テストを有効化
    # -S on    属性の自動保存を有効化
    # -n standby  スタンバイ中の HDD は起こさない (無駄な spin-up を避ける)
    # -W 4,50,60  温度が 4℃ 変化 / 50℃ 超 / 60℃ 超 で記録・警告
    # メール通知は指定していないので、警告は journal にのみ出ます
    # (MTA 未設定のため。確認: journalctl -u smartd)
    defaults.autodetected = "-a -o on -S on -n standby -W 4,50,60";
  };
}
