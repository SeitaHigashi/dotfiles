{ config, lib, pkgs, ... }:

##############################################################################
# Grafana のアラート (Unified Alerting)。
#
# 何のためか:
#   modules/monitoring.nix で集めた数値は dashboards/*.json で見えますが、
#   見に行かなければ気づけません。ZFS プールの劣化・ディスクの消耗・
#   複製の停止は、どれも「静かに進行して、必要になった瞬間に手遅れと分かる」
#   種類の故障です。閾値の判定は機械にやらせます。
#
# なぜ monitoring.nix と分けるか:
#   monitoring.nix が既に 400 行を超えており、収集 (exporter とスクレイプ) と
#   判定 (アラート) は変更の理由が別だからです。services.grafana の属性は
#   モジュール間でマージされるので分割に支障はありません
#   (nixpkgs.config.allowUnfreePredicate のような「1 箇所限定」の制約は
#    ここには無い)。
#
# git が唯一の正:
#   provisioning で入れたルールは UI から編集できません。dashboards/*.json を
#   allowUiUpdates = false で読ませているのと同じ方針です。閾値を変えたいときは
#   このファイルを直して rebuild します。
#
# 通知:
#   n8n の Webhook 1 本だけに飛ばします。SMTP を選ばなかったのは、
#   パスワードを置く場所が要るからです (このリポジトリにはまだ sops-nix も
#   agenix もありません)。n8n は同一ホストの 127.0.0.1 なので、
#   秘密情報を一切増やさずに済みます。通知先の振り分け (Discord / メール /
#   夜間は無視、など) は n8n のワークフロー側で育てます。
#
#   Webhook 先のワークフローがまだ無くても、アラートの状態自体は
#   Grafana の Alerting 画面に出ます。通知の配送は失敗しますが、
#   ルールの評価には影響しません。
#
# 経路の検証のしかた:
#   一時的なルール (expr = "vector(1)"、for = "0s") を足して発報させ、
#   確認できたら「閾値だけを変えて Normal に戻す」こと。
#   **ルールごと削除しても復旧通知は出ません** — 評価対象が消えるだけで
#   Alerting -> Normal の遷移が起きないためです (実機で確認)。
##############################################################################

let
  # ディスクの by-id はマシン固有値なので machine.nix から取ります。
  m = import ../machine.nix;

  # データソースの UID。dashboards/*.json と同じ値で、
  # modules/monitoring.nix の provision.datasources で固定しているものです。
  # ここを変えると全ルールが「データソースが見つからない」で Error になります。
  dsUid = "victoriametrics";

  # n8n の待ち受けポート。modules/n8n.nix の port と揃えること。
  n8nPort = 5678;

  # アラートを置くフォルダ。Grafana が provisioning 時に自動で作ります。
  folder = "アラート";

  ##########################################################################
  # ルールを 1 つ組み立てるヘルパー。
  #
  # このリポジトリのアラートはすべて「instant クエリを 1 本投げて、
  # その値を閾値と比べる」形に収まります。Grafana のルールは
  # data (クエリと式のノードの配列) + condition (最終ノードの refId) という
  # 冗長な構造なので、素直に書くと 1 ルール 40 行になり、閾値の一覧性が
  # 失われます。共通部分をここに畳んでおきます。
  #
  # 引数:
  #   uid         ルールの識別子。省略すると再起動のたびに別ルール扱いになり、
  #               サイレンス設定などが失われるため必ず明示します。
  #   expr        PromQL (instant)。異常時に系列が出るように書くのではなく、
  #               常に値が出るように書いて、判定は evaluator に任せます
  #               (系列が消えると NoData になり、閾値の意味が変わるため)。
  #   op/limit    閾値。op は "gt" か "lt"。
  #   pending     この状態が続いたら発報する時間 ("for")。瞬間的な尖りで
  #               鳴らさないためのもの。
  #   severity    ラベル。n8n 側で通知先を分けるために使います。
  #   noData      データが無いときの扱い。既定は "OK" (指標がまだ無い =
  #               異常ではない) ですが、「値が消えること自体が異常」の
  #               ルールでは "Alerting" を渡します。
  ##########################################################################
  mkRule =
    { uid
    , title
    , expr
    , op
    , limit
    , pending
    , severity
    , summary
    , description
    , noData ? "OK"
    }:
    {
      inherit uid title;
      condition = "B";
      for = pending;
      isPaused = false;
      noDataState = noData;
      # クエリが壊れていること自体は知らせてほしいので Error のまま。
      execErrState = "Error";

      data = [
        {
          refId = "A";
          # instant クエリなので窓は評価に使われませんが、
          # Grafana は必須項目として要求します。
          relativeTimeRange = { from = 600; to = 0; };
          datasourceUid = dsUid;
          model = {
            refId = "A";
            datasource = { type = "prometheus"; uid = dsUid; };
            editorMode = "code";
            inherit expr;
            instant = true;
            range = false;
          };
        }
        {
          refId = "B";
          relativeTimeRange = { from = 600; to = 0; };
          # 式ノードは Grafana 内部の疑似データソース。
          datasourceUid = "__expr__";
          model = {
            refId = "B";
            datasource = { type = "__expr__"; uid = "__expr__"; };
            type = "threshold";
            expression = "A";
            conditions = [
              {
                type = "query";
                evaluator = { type = op; params = [ limit ]; };
                operator.type = "and";
                query.params = [ "A" ];
                # A は instant なので既に 1 点。reducer は形式上の指定です。
                reducer = { type = "last"; params = [ ]; };
              }
            ];
          };
        }
      ];

      labels = { inherit severity; };
      annotations = { inherit summary description; };
    };

  # SMART のラベルはディスクの by-id 名 (パス部分を除いたもの) です。
  # machine.nix を唯一の出所にして、ここにディスク名を直書きしないようにします。
  deviceOf = path: baseNameOf path;
in
{
  services.grafana.provision.alerting = {

    ##########################################################################
    # 通知先
    ##########################################################################
    contactPoints.settings = {
      apiVersion = 1;
      contactPoints = [
        {
          orgId = 1;
          name = "n8n-webhook";
          receivers = [
            {
              uid = "n8n-webhook";
              type = "webhook";
              settings = {
                # パスは n8n のワークフロー
                # "Notify Grafana Alert to Discord" (fD6js4TzcXdUF4Wx) の
                # Webhook ノードに合わせています。末尾のランダムな文字列は
                # n8n が付けたもので、こちらで短くはできません
                # (ワークフロー側を直さない限り 404 になります)。
                url = "http://127.0.0.1:${toString n8nPort}/webhook/grafana-alert-40b2fc68";
                httpMethod = "POST";
              };
              # 復旧したことも知らせてほしい (「鳴りっぱなしかどうか」が
              # 分からないと、アラートを見なくなります)。
              disableResolveMessage = false;
            }
          ];
        }
      ];
    };

    ##########################################################################
    # 通知ポリシー
    #
    # 家庭内のサーバーなので、同じ問題で何度も叩き起こされないよう
    # 再通知は控えめ (12 時間) にしています。重大度による分岐は
    # ここではなく n8n 側で行います (nix を触らずに変えられるため)。
    ##########################################################################
    policies.settings = {
      apiVersion = 1;
      policies = [
        {
          orgId = 1;
          receiver = "n8n-webhook";
          group_by = [ "alertname" "grafana_folder" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
        }
      ];
    };

    ##########################################################################
    # ルール
    ##########################################################################
    rules.settings = {
      apiVersion = 1;

      # ルールを消すときは groups から削るだけでは足りません。provisioning から
      # 消えても Grafana の DB には残り続けるため、一時的に
      #   deleteRules = [ { orgId = 1; uid = "<消したい uid>"; } ];
      # をここに書いて 1 回 switch し、消えたのを確認してから
      # deleteRules ごと消します (実機で確認済み)。

      groups = [

        ######################################################################
        # インフラ本体
        ######################################################################
        {
          orgId = 1;
          name = "infra";
          inherit folder;
          interval = "1m";
          rules = [

            (mkRule {
              uid = "zfs-pool-degraded";
              title = "ZFS プールが ONLINE でない";
              # modules/zfs-snapshot-metrics.nix が出している指標。
              # node_exporter の zfs コレクタはプールの健全性を出しません。
              expr = "max by (pool) (zfs_pool_health)";
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "critical";
              summary = "ZFS プール {{ $labels.pool }} が ONLINE ではありません";
              description = "zpool status を確認してください。dpool ならミラーの片肺、rpool なら冗長性が無いため即対応が要ります。";
            })

            (mkRule {
              uid = "filesystem-space-low";
              title = "ファイルシステムの空きが少ない";
              # ZFS のデータセットはプールの空きを共有するため、全マウント
              # ポイントを対象にすると 1 つの事象で何十件も鳴ります。
              # プールごとに代表を 1 つだけ見ます (/ = rpool, /srv = dpool)。
              # /boot だけは独立した vfat なので別枠で含めます。
              expr = ''min by (mountpoint) (node_filesystem_avail_bytes{mountpoint=~"/|/srv|/boot"} / node_filesystem_size_bytes)'';
              op = "lt";
              limit = 0.10;
              pending = "15m";
              severity = "warning";
              summary = "{{ $labels.mountpoint }} の空きが 10% を切りました";
              description = "ZFS は空きが尽きると書き込みだけでなく削除も難しくなります。スナップショットの整理を検討してください。";
            })

            (mkRule {
              uid = "smart-status-failed";
              title = "SMART の総合判定が FAILED";
              # 1 = passed。ディスクが自分で「もう駄目だ」と言っている状態。
              expr = "min by (device) (smartctl_device_smart_status)";
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.device }} の SMART が FAILED です";
              description = "交換を前提に動いてください。rpool 側 (SSD) なら dpool へのバックアップが最新か先に確認します。";
            })

            (mkRule {
              uid = "nvme-wearout";
              title = "NVMe の消耗が進んでいる";
              # NVMe のみが持つ指標 (HDD には出ません)。
              expr = "max by (device) (smartctl_device_percentage_used)";
              op = "gt";
              limit = 80;
              pending = "1h";
              severity = "warning";
              summary = "{{ $labels.device }} の書き込み寿命が 80% を超えました";
              description = "残り 20% を切っています。交換の計画を立ててください。";
            })

            (mkRule {
              uid = "nvme-critical-warning";
              title = "NVMe が critical warning を上げている";
              expr = "max by (device) (smartctl_device_critical_warning)";
              op = "gt";
              limit = 0;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.device }} が critical warning を報告しています";
              description = "温度・予備ブロック・読み取り専用化などのいずれか。smartctl -a で内訳を確認してください。";
            })

            (mkRule {
              uid = "hdd-temperature-high";
              title = "HDD の温度が高い";
              # HDD は 55℃ を超えると寿命が目に見えて縮みます。
              # NVMe は平常時から 50℃ 前後なので別ルールにしています。
              expr = ''max by (device) (smartctl_device_temperature{temperature_type="current",device=~"${deviceOf m.hdd1}|${deviceOf m.hdd2}"})'';
              op = "gt";
              limit = 55;
              pending = "30m";
              severity = "warning";
              summary = "HDD {{ $labels.device }} が 55℃ を超えています";
              description = "筐体のエアフローを確認してください。";
            })

            (mkRule {
              uid = "nvme-temperature-high";
              title = "NVMe の温度が高い";
              # 平常時 50℃ 前後なので 75℃ で拾います
              # (サーマルスロットリングが始まる手前)。
              expr = ''max by (device) (smartctl_device_temperature{temperature_type="current",device="${deviceOf m.ssd}"})'';
              op = "gt";
              limit = 75;
              pending = "15m";
              severity = "warning";
              summary = "NVMe {{ $labels.device }} が 75℃ を超えています";
              description = "スロットリングで I/O が落ちます。ヒートシンクとエアフローを確認してください。";
            })

            (mkRule {
              uid = "memory-low";
              title = "メモリの空きが少ない";
              # ARC は MemAvailable に含まれない (回収可能でも used 扱い) ため、
              # arcMaxBytes を上げすぎたときもここに出ます。
              expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes";
              op = "lt";
              limit = 0.10;
              pending = "15m";
              severity = "warning";
              summary = "利用可能メモリが 10% を切りました";
              description = "Minecraft のヒープ、ollama のモデル、ARC 上限の合計を見直してください。OOM killer が動く前に。";
            })

            (mkRule {
              uid = "cpu-saturated";
              title = "CPU が飽和している";
              expr = ''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))'';
              op = "gt";
              limit = 0.90;
              pending = "30m";
              severity = "warning";
              summary = "CPU 使用率が 30 分以上 90% を超えています";
              description = "LLM の推論やビルド中なら正常です。心当たりが無ければ暴走しているプロセスを探してください。";
            })

            (mkRule {
              uid = "systemd-unit-failed";
              title = "systemd ユニットが failed";
              # どのユニットでも拾う網。個別のサービス死活は services グループ側。
              expr = ''sum by (name) (node_systemd_unit_state{state="failed"})'';
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "warning";
              summary = "{{ $labels.name }} が failed 状態です";
              description = "journalctl -u {{ $labels.name }} を確認してください。";
            })
          ];
        }

        ######################################################################
        # サービスの死活
        ######################################################################
        {
          orgId = 1;
          name = "services";
          inherit folder;
          interval = "1m";
          rules = [

            (mkRule {
              uid = "scrape-target-down";
              title = "スクレイプ対象が落ちている";
              # exporter が死ぬと、その配下のアラートがすべて無言になります。
              # 「監視が見えていないこと」自体を critical で拾います。
              expr = "min by (job, instance) (up)";
              op = "lt";
              limit = 1;
              pending = "5m";
              severity = "critical";
              summary = "{{ $labels.job }} ({{ $labels.instance }}) からスクレイプできません";
              description = "この exporter が担当する指標は現在すべて欠測です。";
            })

            (mkRule {
              uid = "service-inactive";
              title = "常駐サービスが止まっている";
              # いずれも Restart 前提の常駐ユニットなので、
              # active でない = 落ちている、と見なして構いません。
              expr = ''min by (name) (node_systemd_unit_state{state="active",name=~"grafana.service|victoriametrics.service|n8n.service|ollama.service|open-webui.service|tailscaled.service|podman-ftb-evolution.service|podman-mc-monitor.service"})'';
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.name }} が active ではありません";
              description = "systemctl status {{ $labels.name }} を確認してください。";
            })

            (mkRule {
              uid = "minecraft-unhealthy";
              title = "Minecraft サーバーが応答しない";
              # コンテナが動いていてもワールドの読み込みで固まることがあるため、
              # プロセスの死活 (上の service-inactive) とは別に持ちます。
              expr = "min(minecraft_status_healthy)";
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "warning";
              summary = "Minecraft サーバーが status に応答していません";
              description = "modpack の更新直後なら起動待ちの可能性があります。podman logs ftb-evolution を確認してください。";
            })
          ];
        }

        ######################################################################
        # バックアップ (複製とスナップショット)
        #
        # rpool は single vdev で冗長性が無いため、dpool への複製が
        # 唯一の保険です。ここが止まっていることに気づけないのが最悪の状態なので、
        # 「ユニットの失敗」と「実際に届いたデータの古さ」を別々に見張ります
        # (ユニットが成功で終わっていても何も転送していないことがあるため。
        #  README.md の複製の節を参照)。
        ######################################################################
        {
          orgId = 1;
          name = "backup";
          inherit folder;
          interval = "5m";
          rules = [

            (mkRule {
              uid = "replication-lag";
              title = "複製が遅れている";
              # 日次複製なので 24 時間 + 猶予 12 時間 = 36 時間 (129600 秒)。
              expr = ''max by (dataset) (time() - zfs_snapshot_latest_creation_seconds{dataset=~"dpool/backup/.*"})'';
              op = "gt";
              limit = 129600;
              pending = "30m";
              severity = "critical";
              # 系列が消えること自体が異常 (データセットごと失われている)。
              noData = "Alerting";
              summary = "{{ $labels.dataset }} の最新バックアップが 36 時間以上前です";
              description = "syncoid が止まっているか、送信側にスナップショットがありません。今 SSD が死んだらこの時間分のデータを失います。";
            })

            (mkRule {
              uid = "syncoid-failed";
              title = "syncoid が失敗している";
              # `\.` ではなく `[.]` で書いているのは、MetricsQL が
              # 二重引用符の中のバックスラッシュを文字列エスケープとして
              # 先に解釈してしまい構文エラーになるためです (実機で確認)。
              expr = ''sum by (name) (node_systemd_unit_state{state="failed",name=~"syncoid-.*[.]service"})'';
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "critical";
              summary = "{{ $labels.name }} が失敗しました";
              description = "journalctl -u {{ $labels.name }} を確認してください。";
            })

            (mkRule {
              uid = "zfs-snapshot-metrics-stale";
              title = "ZFS メトリクスの収集が止まっている";
              # これが古いと、上の複製ラグの判定そのものが信用できません。
              # 5 分間隔のタイマーなので 30 分で異常と見なします。
              expr = "time() - zfs_snapshot_metrics_last_run_seconds";
              op = "gt";
              limit = 1800;
              pending = "10m";
              severity = "warning";
              noData = "Alerting";
              summary = "zfs-snapshot-metrics の出力が 30 分以上更新されていません";
              description = "複製ラグとスナップショット数の指標が古くなっています。systemctl status zfs-snapshot-metrics.timer を確認してください。";
            })
          ];
        }
      ];
    };
  };

  ############################################################################
  # 動作確認
  #
  #   systemctl status grafana        # provisioning の構文エラーはここに出る
  #                                   # (失敗すると Grafana が起動しない)
  #   ls /etc/grafana/provisioning/alerting/
  #
  #   Web UI: https://<host>/grafana/alerting/list
  #     すべて Normal であること。Error や NoData のルールがあれば
  #     PromQL の書き間違いを疑う。
  #
  # n8n 側:
  #   Webhook ノードのパスを "grafana-alert" (POST) にしたワークフローを
  #   作って有効化しておくこと。無くてもアラートの評価と UI 表示は動きます。
  ############################################################################
}
