{ config, lib, pkgs, ... }:

##############################################################################
# Multica (AI コーディングエージェント管理ワークスペース) を自前ホストする。
#
# 何をしているか:
#   公式が配布する docker-compose.selfhost.yml (Next.js フロントエンド +
#   Go バックエンド + PostgreSQL/pgvector) を、Minecraft (ftb-evolution.nix)
#   と同じ podman ベースの構成に置き換えて 3 コンテナで動かします。
#   永続化は公式と同じく podman の named volume (pgdata / uploads) を使い、
#   ホスト上のパスは /var/lib/containers 配下 (rpool/var/lib データセット) に
#   収まるため、modules/replication.nix の日次複製にそのまま乗ります。
#   新しい ZFS データセットは切っていません。
#
# 秘密情報 (POSTGRES_PASSWORD / JWT_SECRET / MULTICA_VCS_SECRET_KEY):
#   agenix で secrets/multica-env.age に暗号化して置いています
#   (modules/discord-bot.nix と同じ方式)。DATABASE_URL は
#   postgres://multica:<password>@multica-postgres:5432/multica?sslmode=disable
#   の形で secret ファイル自体に埋め込み済みです (host 名は下の postgres
#   コンテナの attrname と一致させる必要があります)。
#
# 公開範囲:
#   フロントエンドコンテナが Next.js の SSR プロキシ経由でバックエンド API
#   も中継する (REMOTE_API_URL) ため、外部に公開するのはフロントエンドの
#   1 ポートだけで足ります。modules/reverse-proxy.nix で
#   https://<fqdn>:9444/ にマウントしています (n8n/ComfyUI と同じく別ポートの
#   ルート — 理由はそちらのファイルの routes コメント参照)。
#
# サインアップ制限をかけていません (ALLOW_SIGNUP は既定の true のまま)。
#   tailnet 到達性だけがアクセス制御です。第三者にサインアップされたくない
#   場合は ALLOWED_EMAILS / ALLOWED_EMAIL_DOMAINS を environment に足してください。
#
# イメージタグは latest 固定 (公式の既定と同じ)。FTB modpack のように
# バージョンを厳密に固定していないため、ghcr 側の latest 更新が
# Restart=always の再起動のたびに反映されます。事故を避けたくなったら
# MULTICA_IMAGE_TAG を明示のリリースタグに変えてください。
##############################################################################

let
  m = import ../machine.nix;

  # コンテナ内部の待ち受けポート (公式イメージ固定値、変更不可)。
  backendContainerPort = 8080;
  frontendContainerPort = 3000;

  # ホスト側 (127.0.0.1) に publish するポート。
  # 3000 は Grafana (modules/monitoring.nix) が、8080 は Open WebUI
  # (modules/ollama.nix) が 127.0.0.1 に既に持っているため、frontend は
  # 3001、backend は 8082 にずらす。
  #
  # backend も publish している理由:
  #   ブラウザ (Next.js SSR 経由) だけでなく、multica-cli の daemon/runtime も
  #   backend の API に直接繋ぎに行きます。daemon はブラウザではないため
  #   Next.js の SSR プロキシを経由できず (Content-Type や特有のレスポンス
  #   ヘッダで backend 本体かどうかを見ているらしく、frontend 経由だと
  #   "not reachable" 扱いになることを実機で確認: 2026-08-12)。そのため
  #   backend 用に modules/reverse-proxy.nix で別ポート (9445) も用意しています。
  frontendHostPort = 3001;
  backendHostPort = 8082;

  secretsFile = config.age.secrets.multica-env.path;
  githubAppKeyFile = config.age.secrets.multica-github-app-key.path;
  githubAppKeySecretName = "multica-github-app-key";
in
{
  age.secrets.multica-env = {
    file = ../secrets/multica-env.age;
    mode = "0400";
  };

  # GITHUB_APP_PRIVATE_KEY (複数行の PEM) だけ別の age secret に分離。
  #
  # 理由: multica-env.age の他の変数は environmentFiles (podman の
  # --env-file) 経由で渡していますが、この形式は KEY=VALUE の 1 行区切りで、
  # ダブルクォートで囲んでも複数行の値としては解釈されません
  # (Docker Compose の .env ファイル読み込みとは別実装で multiline 非対応)。
  # 実機で検証した際も、複数行のまま書くと 1 行目だけがクォート文字ごと
  # 値として切り取られ、\n へのエスケープも展開されずに素通りするだけで
  # 壊れた PEM になることを確認しました (2026-08-18)。
  #
  # そのため PEM はここでは agenix の生ファイルのまま持ち、podman secret
  # (下の systemd.services.multica-github-secret) 経由でコンテナに渡します。
  # podman secret は行区切りパーサーを介さず生バイト列をそのまま
  # 環境変数にコピーするため、改行を保持できます。
  age.secrets.multica-github-app-key = {
    file = ../secrets/multica-github-app-key.age;
    mode = "0400";
  };

  # 上の PEM を podman secret として登録する (idempotent: --replace)。
  # multica-backend の起動前に完了している必要があるため before/requires で縛る。
  systemd.services.multica-github-secret = {
    description = "Register Multica GitHub App private key as a podman secret";
    before = [ "podman-multica-backend.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.podman}/bin/podman secret create --replace ${githubAppKeySecretName} ${githubAppKeyFile}";
    };
  };

  systemd.services.podman-multica-backend = {
    after = [ "multica-github-secret.service" ];
    requires = [ "multica-github-secret.service" ];
  };

  virtualisation.oci-containers.containers = {
    multica-postgres = {
      image = "docker.io/pgvector/pgvector:pg17";
      environment = {
        POSTGRES_DB = "multica";
        POSTGRES_USER = "multica";
      };
      environmentFiles = [ secretsFile ]; # POSTGRES_PASSWORD
      volumes = [ "multica-pgdata:/var/lib/postgresql/data" ];
      autoStart = true;
    };

    multica-backend = {
      image = "ghcr.io/multica-ai/multica-backend:latest";
      dependsOn = [ "multica-postgres" ];
      # frontend からは podman のデフォルトネットワーク経由でコンテナ名
      # (multica-backend:8080) で届くので、この publish 自体は
      # multica-cli の daemon/runtime 用 (上のコメント参照)。
      ports = [ "127.0.0.1:${toString backendHostPort}:${toString backendContainerPort}" ];
      volumes = [ "multica-backend-uploads:/app/data/uploads" ];
      environment = {
        PORT = toString backendContainerPort;
        APP_ENV = "production";
        ALLOW_SIGNUP = "true";
        # 自前ホスト限定機能 (Forgejo/Gitea/GitLab 連携)。鍵は secretsFile 側。
        MULTICA_VCS_INTEGRATION_ENABLED = "true";
        # FRONTEND_ORIGIN / CORS_ALLOWED_ORIGINS / MULTICA_APP_URL /
        # MULTICA_PUBLIC_URL は Tailscale Serve の URL に依存するため、
        # ここではなく modules/reverse-proxy.nix の「Multica」節で設定します
        # (Grafana の root_url / n8n の webhookUrl と同じ置き場の方針)。
      };
      # DATABASE_URL / JWT_SECRET / MULTICA_VCS_SECRET_KEY
      # (GITHUB_APP_PRIVATE_KEY は含めない。改行を保持できないため
      # 下の --secret 経由で渡す。理由は multica-github-secret のコメント参照)
      environmentFiles = [ secretsFile ];
      # GITHUB_APP_PRIVATE_KEY を podman secret から環境変数として注入。
      extraOptions = [ "--secret=${githubAppKeySecretName},type=env,target=GITHUB_APP_PRIVATE_KEY" ];
      autoStart = true;
    };

    multica-frontend = {
      image = "ghcr.io/multica-ai/multica-web:latest";
      dependsOn = [ "multica-backend" ];
      # ホスト側だけ 3001。コンテナ内部は 3000 のまま (--set-path 同様、
      # 公開ポートと内部ポートを分けているだけで、コンテナ間通信は内部ポートを使う)。
      ports = [ "127.0.0.1:${toString frontendHostPort}:${toString frontendContainerPort}" ];
      environment = {
        HOSTNAME = "0.0.0.0";
        REMOTE_API_URL = "http://multica-backend:${toString backendContainerPort}";
      };
      autoStart = true;
    };
  };

  ############################################################################
  # 公開範囲: 127.0.0.1 限定 (postgres は待ち受けすら公開していません)。
  # tailnet への公開は modules/reverse-proxy.nix の Serve マウント経由のみ。
  ############################################################################

  ############################################################################
  # multica daemon (ローカルエージェントランタイム)
  #
  # サーバー本体 (上記コンテナ) とは別に、Claude/OpenCode (Ollama) を実際に
  # 実行するのはこのホスト上の `multica daemon` プロセスです。今まで
  # `multica daemon start` を手動で叩いて常駐させていましたが systemd 管理外
  # だったため再起動のたびに止まっていました (2026-08-12 に発覚)。
  #
  # 認証情報 (~/.multica/config.json の token) は `multica setup` /
  # `multica login` で作られる、このリポジトリの管理外のファイルです。
  # 秘密情報を nix 式に書きたくないため、ここでは触らずユーザーのホーム
  # ディレクトリのものをそのまま使います (agenix 化はしていません)。
  #
  # --foreground が必要な理由:
  #   既定 (フォアグラウンドなし) だと multica 自身が二重 fork してバックグラウンド化
  #   するため、systemd がプロセスを見失い再起動管理ができません。
  #   SIGTERM は実行中タスクを待ってから (最大 30s) 正常終了することを実機で確認済み。
  ############################################################################
  systemd.services.multica-daemon = {
    description = "Multica local agent runtime daemon";
    after = [ "network-online.target" "podman-multica-backend.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/${m.userName}";
      # daemon が agent (claude/opencode) の子プロセスに渡す PATH は、
      # multica-cli 自身のバイナリディレクトリ + この unit の PATH。
      # systemd unit の既定 PATH には nix-profile 由来のもの (claude 本体、
      # rtk) も /run/current-system/sw/bin 由来のもの (opencode) も
      # 含まれないため、明示しないと agent 実行環境からどちらも見えない。
      # ~/.nix-profile は imperative インストール (nix profile install) の
      # ため、GC や nix profile remove で claude/rtk が消えると道連れで壊れる。
      PATH = lib.mkForce "/home/${m.userName}/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin";
    };
    serviceConfig = {
      Type = "simple";
      User = m.userName;
      ExecStart = "${pkgs.unstable.multica-cli}/bin/multica daemon start --foreground";
      Restart = "always";
      RestartSec = "10s";
      TimeoutStopSec = "40s";
    };
  };

  ############################################################################
  # 運用メモ
  #
  #   状態確認:
  #     systemctl status podman-multica-postgres podman-multica-backend podman-multica-frontend
  #     journalctl -u podman-multica-backend -f
  #     systemctl status multica-daemon    # ローカルエージェントランタイム
  #     multica daemon status / multica daemon logs -f
  #
  #   アクセス:
  #     https://<fqdn>:9444/  ブラウザ (modules/reverse-proxy.nix)
  #     https://<fqdn>:9445/  multica-cli の --server-url (backend 直結)
  #     直結デバッグしたいときは SSH port-forward 越しに http://127.0.0.1:3001/ (frontend)
  #     や http://127.0.0.1:8082/ (backend)
  #
  #   ログインメールが届かない (未解決の既知の制約):
  #     RESEND_API_KEY / SMTP_HOST のどちらも設定していないため、メール送信の
  #     仕組みがありません。ログイン用の確認コードはバックエンドのログに
  #     出るはずなので journalctl -u podman-multica-backend で拾ってください。
  #     恒常的に使うなら SMTP か Resend の設定を追加する必要があります
  #     (secrets/multica-env.age に SMTP_* または RESEND_API_KEY を足す)。
  #
  #   イメージ更新:
  #     podman pull ghcr.io/multica-ai/multica-backend:latest
  #     podman pull ghcr.io/multica-ai/multica-web:latest
  #     systemctl restart podman-multica-backend podman-multica-frontend
  #
  #   秘密情報の再発行:
  #     nix-shell -p openssl age --run '...' で新しい POSTGRES_PASSWORD /
  #     JWT_SECRET / MULTICA_VCS_SECRET_KEY を作り、secrets/multica-env.age を
  #     age -r <secrets.nix の host 公開鍵> で作り直して switch。
  #     JWT_SECRET を変えると既存セッションは全部無効になります。
  #     POSTGRES_PASSWORD を変えるだけなら DB 側の ALTER USER も必要です
  #     (このコンテナ構成では POSTGRES_PASSWORD は初回起動時にしか効きません)。
  ############################################################################
}
