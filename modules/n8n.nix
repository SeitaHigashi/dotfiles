{ config, lib, pkgs, ... }:

##############################################################################
# n8n (ワークフロー自動化)。
#
# 何のために入れるか:
#   「HTTP を叩いて結果を加工して通知する」類の雑用を、cron + シェルスクリプトで
#   増やし続けずに済ませるための土台です。同居している Ollama を
#   http://127.0.0.1:11434 から呼べるので、ローカル LLM を挟んだ処理も書けます。
#
# データの置き場と冗長性:
#   DB は既定の SQLite で、DynamicUser のため実体は /var/lib/private/n8n です
#   (/var/lib/n8n はそこへのシンボリックリンク)。専用の ZFS データセットは
#   切っていません。rpool/var/lib の一部として毎時スナップショットが取られ、
#   modules/replication.nix の rpool/var/lib -> dpool/backup/var-lib の日次複製に
#   そのまま乗るためです。VictoriaMetrics や Ollama のように「書き込みが多く
#   失っても再取得できる」データとは逆で、ここは消えると復旧できません。
#
# バージョンは unstable 追従:
#   25.05 の n8n は 1.91.3 で、n8n の開発速度からするとかなり古く、
#   ノードの互換性やクラウド側 API の仕様変更に追従できません。
#   ただし 25.05 の services.n8n には package オプションが無く、
#   ExecStart が "${pkgs.n8n}/bin/n8n" と直書きされています。そのため
#   下の overlay で pkgs.n8n 自体を差し替えています。n8n は Node の
#   アプリケーションで、カーネル・カーネルモジュール・systemd・glibc の
#   いずれにも関わらない「葉」なので、この差し替えは安全です。
#
# 公開範囲:
#   Grafana や Ollama とは違い、tailscale0 限定ではなく LAN に開いています
#   (Minecraft と同じ扱い)。認証は n8n の owner アカウント任せです。
#   平文 HTTP なので、tailnet の外・LAN の外には出さないこと。
##############################################################################

let
  # 既存の割り当て: VictoriaMetrics 8428 / Grafana 3000 / Open WebUI 8080 /
  # cadvisor 8081 / node 9100 / smartctl 9633 / nvidia 9835 / minecraft 9150。
  # 5678 は n8n の既定値で、いずれとも衝突しません。
  port = 5678;
in
{
  ############################################################################
  # unstable のパッケージへ差し替える overlay
  #
  # modules/unstable.nix が用意する final.unstable を使います
  # (あちらの overlay が先に評価されている必要はなく、overlay は
  #  fixpoint なので final 経由で参照できます)。
  #
  # ※ n8n は非フリー (Sustainable Use License) です。許可は
  #   modules/gpu.nix の allowUnfreePredicate に書いています。
  #   nixpkgs.config は 1 箇所からしか定義できないため、ここには書けません。
  ############################################################################
  nixpkgs.overlays = [
    (final: prev: {
      n8n = final.unstable.n8n;
    })
  ];

  services.n8n = {
    enable = true;

    # 他のモジュールと揃えて、ファイアウォールは自分で書きます
    # (このオプションは全インタフェースを開けてしまうため)。
    openFirewall = false;

    # NixOS モジュールはこの attrset を JSON にして N8N_CONFIG_FILES で渡しますが、
    # **n8n 2.x では設定のほとんどが環境変数からしか読まれません**。
    # 実機で確認済み: 新しい設定クラス (@n8n/config) は @Env デコレータで
    # 環境変数だけを見ており、endpoints.metrics.enable を JSON に書いても
    # /metrics は 404 のままでした。起動時にも
    #   N8N_CONFIG_FILES -> Please use .env files or *_FILE env vars instead.
    # という非推奨警告が出ます。
    # したがって実際の設定は下の environment 側に書いています。
    # port だけはモジュールが openFirewall の判定に eval 時に使うため残します。
    settings = { inherit port; };
  };

  ############################################################################
  # 実際の設定 (上記のとおり 2.x は環境変数が正)
  ############################################################################
  systemd.services.n8n.environment = {
    N8N_PORT = toString port;
    # N8N_LISTEN_ADDRESS は既定で 0.0.0.0。LAN 公開なのでそのままにしています。

    # 実行履歴やスケジュールノードの時刻表示に効きます。
    GENERIC_TIMEZONE = "Asia/Tokyo";

    # Prometheus 形式のメトリクスを同じポートの /metrics に出す。
    # modules/monitoring.nix の n8n ジョブがこれをスクレイプします。
    N8N_METRICS = "true";

    # これを false にしないと、n8n は localhost 以外からの平文 HTTP アクセスに
    # 対して Secure 属性付きの cookie を発行します。ブラウザはそれを保存しない
    # ため、LAN から http://<IP>:5678 で開くと「ログインしたのに何度も
    # ログイン画面に戻る」状態になります。TLS を前段に置いたら消してください。
    N8N_SECURE_COOKIE = "false";
  };

  ############################################################################
  # node を PATH に置く
  #
  # n8n 2.x は Code ノードを本体プロセスではなく task runner という別プロセスで
  # 実行します。その起動は spawn('node', ...) という PATH 依存の呼び出しで
  # (packages/cli/dist/task-runners/task-runner-process-js.js)、systemd
  # ユニットの PATH には node が無いため、そのままだと起動時のログに
  #   spawn node ENOENT
  # が出て JS の task runner が上がりません。n8n の bin は shebang で
  # node を絶対パス指定しているので本体は動いてしまい、気付きにくい。
  #
  # unstable の nodejs は n8n が使っているものと同一 (24.18.0) です。
  #
  # なお Python の task runner (「Python 3 is missing from this system」) は
  # 別問題で、ここでは有効化していません。Python の Code ノードを使いたく
  # なったら n8n 公式が推奨する external mode を検討してください。
  ############################################################################
  systemd.services.n8n.path = [ pkgs.unstable.nodejs ];

  ############################################################################
  # LAN に公開。
  # tailscale0 限定にしていないのは Minecraft と同じ理由で、
  # 家庭内の端末やブラウザから直接触りたいためです。
  # /metrics も同じポートに出るので LAN からは見えます (秘密は含みません)。
  ############################################################################
  networking.firewall.allowedTCPPorts = [ port ];
}
