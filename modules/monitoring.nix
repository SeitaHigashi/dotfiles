{ config, lib, pkgs, ... }:

##############################################################################
# 監視スタック (VictoriaMetrics + Grafana)。
#
# 何のために入れるか:
#   このホストには Minecraft (podman) が常駐しており、今後 n8n と Ollama が
#   同居します。CPU は Ryzen 3 3300X の 4C/8T しかなく、GPU も世代違いの
#   2 枚差しです。「Minecraft が重い」と感じたときに *誰が犯人か* を
#   切り分けられないと、この同居構成は運用できません。そのための土台です。
#
# なぜ Prometheus ではなく VictoriaMetrics か:
#   - PromQL 互換なので Grafana の Prometheus データソースがそのまま使えます。
#     世に出回っているダッシュボードもほぼ流用できます。
#   - メモリ消費が Prometheus より大幅に小さく、ディスク書き込み量も少ない。
#     ZFS + 毎時スナップショットのこのホストでは書き込み量が直接
#     スナップショット差分の肥大につながるため、ここは効きます。
#   - prometheusConfig を書けば VictoriaMetrics 単体がスクレイプまで行います。
#     Prometheus も vmagent も要らず、常駐ユニットが 1 つ減ります。
#
# 待ち受けの方針:
#   exporter と VictoriaMetrics はすべて 127.0.0.1 のみ。
#   外から見えるのは Grafana だけで、それも tailscale0 インタフェース限定です
#   (下のファイアウォール節を参照)。LAN にも公開していません。
##############################################################################

let
  m = import ../machine.nix;

  ports = {
    victoriametrics = 8428;
    grafana         = 3000;
    node            = 9100;
    smartctl        = 9633;
    nvidia          = 9835;
    cadvisor        = 8081;   # 既定の 8080 は将来の Web アプリと衝突しやすいのでずらす
    minecraft       = 9150;
    n8n             = 5678;   # modules/n8n.nix と対。Web UI と /metrics が同じポート
  };

  # Grafana の admin パスワードを置くファイル。
  #
  # このリポジトリには秘密情報の置き場 (sops-nix / agenix) がまだ無く、
  # .gitignore も実質空です。Nix の式に直接書くと nix store 経由で
  # 全ユーザーから読めてしまううえ、git にも載ります。
  # そこで Grafana 自身の $__file{} 展開を使い、値はファイルに逃がします。
  #
  # 初回のみ手動で用意してください (このファイルは git 管理外です):
  #   head -c 24 /dev/urandom | base64 | sudo tee /var/lib/grafana/admin-password
  #   sudo chown grafana:grafana /var/lib/grafana/admin-password
  #   sudo chmod 0400 /var/lib/grafana/admin-password
  #
  # 所有者を grafana にするのを忘れると、起動時にこう言って落ちます:
  #   got error while expanding security.admin_password with expander 'file':
  #   permission denied
  grafanaPasswordFile = "/var/lib/grafana/admin-password";

  # SMART を読ませるデバイス。
  # machine.nix の by-id パスをそのまま渡します (sda/sdb は起動ごとに入れ替わるため)。
  smartDevices = [ m.ssd m.hdd1 m.hdd2 ];

  # Minecraft の待ち受けアドレス。
  # modules/ftb-evolution.nix と同じ導出をしています (静的 IP なら LAN IP)。
  minecraftHost =
    if m.staticAddress == null
    then "127.0.0.1"
    else lib.head (lib.splitString "/" m.staticAddress);
in
{
  ############################################################################
  # メトリクスの保存先を専用データセットにする
  #
  # 時系列データベースは小さめの書き込みを絶え間なく続けます。
  # ZFS の既定 recordsize 128K のままだと write amplification が出るため、
  # disko/default.nix で rpool/var/lib/private/victoriametrics を recordsize=16K
  # で切っています。マウント先が /var/lib/victoriametrics ではない理由は
  # そちらのコメントを参照 (DynamicUser との兼ね合い)。
  #
  # このデータセットは com.sun:auto-snapshot=false です。メトリクスは
  # 失っても再取得できない類のデータではなく、毎時スナップショットを取ると
  # 書き込みの多さがそのまま差分の肥大につながるためです。
  # syncoid の複製対象からも外れます (rpool/var/lib は recursive = false なので、
  # 子データセットは自動的に対象外になります)。
  ############################################################################
  services.victoriametrics = {
    enable = true;

    listenAddress = "127.0.0.1:${toString ports.victoriametrics}";

    # 約 6 か月。
    # "6m" とは書けません — VictoriaMetrics は月と分の区別が付かないとして
    # 拒否します。日数で指定してください。
    # 1 年に伸ばしても本構成のメトリクス量なら数 GiB 程度の見込みですが、
    # 実際にどれだけ食うか見てから伸ばす方が安全です。
    retentionPeriod = "180d";

    ##########################################################################
    # スクレイプ設定
    #
    # 15 秒ではなく 30 秒にしています。4C/8T の機体で、Minecraft の tick から
    # CPU を奪わないことを優先しました。障害の切り分けには 30 秒粒度で足ります。
    ##########################################################################
    prometheusConfig = {
      global.scrape_interval = "30s";

      scrape_configs = [
        {
          job_name = "node";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.node}" ]; }];
        }
        {
          job_name = "smartctl";
          # SMART の値は分単位でしか動かないので、頻繁に取っても意味がありません。
          # ディスクを起こしてしまう副作用の方が大きい。
          scrape_interval = "5m";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.smartctl}" ]; }];
        }
        {
          job_name = "nvidia";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.nvidia}" ]; }];
        }
        {
          job_name = "cadvisor";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.cadvisor}" ]; }];
        }
        {
          job_name = "minecraft";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.minecraft}" ]; }];
        }

        {
          # modules/n8n.nix で N8N_METRICS=true にしているのが前提。
          # (2.x は settings の JSON ではなく環境変数しか読みません)
          # Web UI と同じポートの /metrics に出ます。
          job_name = "n8n";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.n8n}" ]; }];
        }

        # 将来ここに足すもの (本体を導入したら有効化してください):
        #
        # {
        #   job_name = "ollama";
        #   # Ollama 自体は Prometheus 形式のメトリクスを吐きません。
        #   # GPU 側は上の nvidia ジョブで、プロセス側は cadvisor / node の
        #   # processes コレクタで見る形になります。
        # }
      ];
    };
  };

  ############################################################################
  # exporter 群
  #
  # すべて 127.0.0.1 のみで待ち受けます。VictoriaMetrics も同じホスト上に
  # あるので、これで外部から exporter が叩かれる経路が無くなります。
  ############################################################################
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.node;

    # 既定のコレクタに加えて:
    #   zfs       — ARC のヒット率と使用量。arcMaxBytes (16 GiB) の
    #               チューニングが妥当だったか後から検証できます。
    #   systemd   — ユニットの状態。podman-ftb-evolution が落ちたことに気づける。
    #   processes — プロセス数と状態。Ollama がゾンビを積んでいないか等。
    enabledCollectors = [ "zfs" "systemd" "processes" ];

    # textfile collector の読み取り先。
    # 中身は modules/zfs-snapshot-metrics.nix のタイマーが 5 分ごとに書きます。
    # (textfile collector 自体は既定で有効ですが、ディレクトリを指定しないと
    #  何も読みません。パスは向こうの textfileDir と対になっています)
    extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
  };

  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.smartctl;
    devices = smartDevices;

    # スクレイプ間隔 (5m) より短くしておく。
    # これより長いと同じキャッシュ値を読み続けることになります。
    maxInterval = "2m";
  };

  ##########################################################################
  # NVIDIA GPU
  #
  # services.prometheus.exporters.nvidia-gpu というモジュールも存在しますが、
  # 中身は開発の止まった mindprince 製 (NVML 直叩き) です。ここでは現行の
  # utkuozdemir 製 (nvidia-smi をパースする実装) を素の systemd ユニットで
  # 動かしています。GPU を uuid と name でラベル分けするため、
  # 世代違いの 2 枚を確実に区別できるのが選定理由です。
  #
  # DynamicUser で動かしつつ、GPU デバイスにアクセスするため video グループを
  # 補助グループとして渡しています。
  ##########################################################################
  systemd.services.nvidia-gpu-exporter = {
    description = "NVIDIA GPU Prometheus exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # nvidia-smi は nvidia_x11.bin に入っており、ドライバのバージョンと
    # 一致している必要があるため config から引きます。
    path = [ config.hardware.nvidia.package.bin ];

    serviceConfig = {
      ExecStart = ''
        ${pkgs.prometheus-nvidia-gpu-exporter}/bin/nvidia_gpu_exporter \
          --web.listen-address=127.0.0.1:${toString ports.nvidia}
      '';
      Restart = "always";
      RestartSec = "10s";

      DynamicUser = true;
      SupplementaryGroups = [ "video" ];

      # nvidia-smi はデバイスファイルを読むだけなので、権限は絞れます。
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  ##########################################################################
  # コンテナ
  #
  # cadvisor が podman のコンテナごとの CPU / メモリ / IO を出します。
  # Minecraft コンテナと将来の n8n コンテナを、ホスト全体の負荷と
  # 突き合わせて見られるようにするためです。
  ##########################################################################
  services.cadvisor = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.cadvisor;
  };

  ##########################################################################
  # Minecraft
  #
  # itzg/mc-monitor を server list ping (25565) に対して回します。
  # RCON は使いません。ポートを増やさずに済み、認証情報も要らないためです。
  #
  # 取れるのは「起動しているか」「オンライン人数」「応答レイテンシ」です。
  # TPS は取れません — TPS まで欲しい場合は modpack 側に Forge の
  # メトリクス mod を入れる必要があり、modpack 更新のたびに壊れる箇所が
  # 増えるため、まずはここから始めます。
  # (mc-monitor は nixpkgs に無いので、既存の Minecraft と同じ podman で動かします)
  ##########################################################################
  virtualisation.oci-containers.containers.mc-monitor = {
    image = "docker.io/itzg/mc-monitor:latest";

    # mc-monitor のフラグは Go 標準の flag パッケージなのでハイフン 1 つです。
    # --bind のような GNU 風のオプションは受け付けず、終了コード 2 で落ちます。
    cmd = [
      "export-for-prometheus"
      "-servers" "${minecraftHost}:25565"
      "-port" (toString ports.minecraft)
    ];

    # ホスト側は 127.0.0.1 のみに公開する。
    ports = [ "127.0.0.1:${toString ports.minecraft}:${toString ports.minecraft}" ];

    autoStart = true;
  };

  # Minecraft 本体が上がってから起動させる。
  # 先に起動しても ping に失敗し続けるだけで実害はありませんが、
  # 起動直後のログが無駄に汚れます。
  systemd.services.podman-mc-monitor = {
    after = [ "podman-ftb-evolution.service" ];
    wants = [ "podman-ftb-evolution.service" ];
  };

  ############################################################################
  # Grafana
  #
  # 待ち受けは 0.0.0.0 ですが、ファイアウォールで tailscale0 のインタフェース
  # だけを開けているため、実際に到達できるのは tailnet からのみです。
  # Tailscale の IP はビルド時に決まらないので、http_addr で絞るのではなく
  # インタフェース単位で絞るこの形にしています。
  ############################################################################
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = ports.grafana;
        # 相対 URL の生成に使われるだけなので、ホスト名で十分です。
        domain = m.hostName;
      };

      security = {
        admin_user = "admin";
        # $__file{} は Grafana 自身の機能で、値をファイルから読みます。
        # こう書くことでパスワードが nix store にも git にも載りません。
        admin_password = "$__file{${grafanaPasswordFile}}";
      };

      # 匿名アクセスとサインアップは無効のまま (既定)。
      # tailnet 内であっても、端末を貸したときに素通りされるのは避けます。
      "auth.anonymous".enabled = false;
      users.allow_sign_up = false;

      # 使用状況の外部送信を止める。
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
    };

    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          # VictoriaMetrics は Prometheus 互換 API を持つので、
          # データソースの型は "prometheus" のままで動きます。
          name = "VictoriaMetrics";
          type = "prometheus";
          access = "proxy";

          # UID を固定する。
          # dashboards/ の JSON はこの UID でデータソースを参照しているため、
          # ここを変えるとダッシュボードが軒並み "No data" になります。
          uid = "victoriametrics";

          url = "http://127.0.0.1:${toString ports.victoriametrics}";
          isDefault = true;
          jsonData = {
            # スクレイプ間隔と揃える。グラフの補間がおかしくなるのを防ぎます。
            timeInterval = "30s";
          };
        }
      ];

      ########################################################################
      # ダッシュボード
      #
      # リポジトリの dashboards/ を丸ごと参照します。パスが nix store を
      # 指すので、ダッシュボードの内容は git が唯一の正になります。
      # (JSON 自体は巨大なので、Nix の式に埋め込まずファイルのまま置きます)
      #
      # allowUiUpdates = false なので UI からは読み取り専用です。
      # 編集したいときは:
      #   1. UI で "Save as..." して複製を作り、そちらで試行錯誤する
      #   2. 気に入ったら Export > "Export for sharing externally" を
      #      オフのまま JSON をコピー
      #   3. dashboards/ のファイルを書き換えて nixos-rebuild switch
      #   4. 複製した方は UI から削除する
      #
      # 収録物 (uid はファイル内で固定):
      #   00-overview            自作。Minecraft・CPU・メモリ・ZFS・GPU を 1 画面に
      #   10-node-exporter-full  Grafana.com ID 1860 (空パネルを削除済み。下記)
      #   20-cadvisor            Grafana.com ID 14282 (cgroup 単位に作り替え済み。下記)
      #   30-nvidia-gpu          Grafana.com ID 14574 (空パネルを削除済み。下記)
      #   40-zfs-replication     自作。スナップショットの世代と syncoid の複製遅延
      #                          (メトリクスの出所は modules/zfs-snapshot-metrics.nix)
      #
      # コミュニティ製の 3 つは取り込み時に手を入れてあります:
      #   - __inputs / __requires を削除 (これが残っていると、provisioning
      #     しても「インポートしてください」と言われて表示できません)
      #   - データソース参照を uid "victoriametrics" に固定
      #
      # さらに、この機体では原理的にデータが出ないパネルを外してあります
      # (放置すると "No data" が画面に混ざり、本当の異常が埋もれるため):
      #   10-node      IRQ Detail (interrupts コレクタが無効) /
      #                Power Supply (電源は AC 直結でバッテリが無い) /
      #                Hardware Fan Speed (hwmon にファンのセンサが出ない) /
      #                TCP Stat Persistent・Transient・Socket Queue
      #                (tcpstat コレクタが無効) の 6 枚を削除。
      #                加えて hwmon の crit_alarm / crit_hyst と
      #                node_netstat_Tcp_MaxConn の系列を落とし、
      #                Network Operational Status は operstate ラベルの
      #                絞り込みを外しました (この版の node_exporter は
      #                node_network_up に operstate を付けません)。
      #                CPU パネルの guest 系列は `> 0` で意図的に隠れる
      #                作りなので残してあります。
      #   20-cadvisor  cAdvisor は podman のコンテナ名を取れず name ラベルが
      #                付きません (docker/containerd の API 前提のため)。
      #                キーを name から cgroup パス (id) に置き換え、
      #                ネットワークの 2 枚は削除しました — cAdvisor が
      #                network 系を出すのはルート cgroup "/" だけで、
      #                コンテナ単位には分かれないためです。
      #   30-nvidia    MIG・NVSwitch (fabric)・XID・PCIe スループット・
      #                energy カウンタ・compute app のプロセス一覧を削除。
      #                いずれもデータセンター GPU か、より新しい exporter
      #                (nvidia_gpu_exporter は 1.3.1) の機能で、
      #                GTX 1660 SUPER / RTX 3060 Ti では出ません。
      #                throttle 系と ECC 系は残しています — クエリが
      #                clocks_event_reasons_* / ecc_..._sram_* に
      #                フォールバックする作りで、実データが返るためです。
      ########################################################################
      dashboards.settings.providers = [
        {
          name = "nixos";
          options.path = ../dashboards;

          # UI からの編集と削除を禁じ、git を唯一の正にする。
          allowUiUpdates = false;
          disableDeletion = true;
        }
      ];
    };
  };

  ############################################################################
  # ファイアウォール
  #
  # Grafana 用のポートはここでは開けません。到達経路は
  # modules/reverse-proxy.nix の Tailscale Serve (tailnet の 443) に
  # 一本化してあり、Grafana 自身の 3000 は tailnet からも直接叩けません。
  # LAN にも当然公開していません。
  #
  # 待ち受けアドレス (http_addr = "0.0.0.0") はそのままですが、
  # 443 で終端した tailscaled が 127.0.0.1:3000 へ繋ぐため支障ありません。
  #
  # 直接 3000 番を叩きたくなったら (プロキシの切り分け等)、SSH の
  # ポートフォワードを使ってください:
  #   ssh -L 3000:127.0.0.1:3000 seita-nixos-baremetal
  ############################################################################

  ############################################################################
  # 運用メモ
  #
  #   ターゲットの健全性:
  #     curl -s 'localhost:8428/api/v1/targets' \
  #       | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'
  #
  #   GPU が 2 枚見えているか (2 行返れば正常):
  #     curl -s localhost:9835/metrics | grep '^nvidia_smi_gpu_info'
  #
  #   Grafana へは tailnet から:
  #     tailscale ip -4   # で得た IP に対して http://<ip>:3000
  #
  #   保存容量の確認:
  #     zfs list rpool/var/lib/victoriametrics
  #     du -sh /var/lib/victoriametrics
  ############################################################################
}
