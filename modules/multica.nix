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
  # コンテナ内部の待ち受けポート (公式イメージ固定値、変更不可)。
  backendContainerPort = 8080;
  frontendContainerPort = 3000;

  # ホスト側 (127.0.0.1) に publish するポート。
  # 3000 は Grafana (modules/monitoring.nix) が、8080 は Open WebUI
  # (modules/ollama.nix) が 127.0.0.1 に既に持っているため、frontend は
  # 3001 にずらす。backend はそもそも host には publish しない (下記)。
  frontendHostPort = 3001;

  secretsFile = config.age.secrets.multica-env.path;
in
{
  age.secrets.multica-env = {
    file = ../secrets/multica-env.age;
    mode = "0400";
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
      # host には publish しない。frontend からは podman のデフォルトネットワーク
      # 経由でコンテナ名 (multica-backend:8080) で届くため、127.0.0.1 に
      # 公開する必要がない (デバッグしたいときは podman exec で入るか
      # `podman port multica-backend` で一時的に確認する)。
      volumes = [ "multica-backend-uploads:/app/data/uploads" ];
      environment = {
        PORT = toString backendContainerPort;
        FRONTEND_ORIGIN = "http://multica-frontend:${toString frontendContainerPort}";
        APP_ENV = "production";
        ALLOW_SIGNUP = "true";
        # 自前ホスト限定機能 (Forgejo/Gitea/GitLab 連携)。鍵は secretsFile 側。
        MULTICA_VCS_INTEGRATION_ENABLED = "true";
      };
      # DATABASE_URL / JWT_SECRET / MULTICA_VCS_SECRET_KEY
      environmentFiles = [ secretsFile ];
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
  # 運用メモ
  #
  #   状態確認:
  #     systemctl status podman-multica-postgres podman-multica-backend podman-multica-frontend
  #     journalctl -u podman-multica-backend -f
  #
  #   アクセス:
  #     https://<fqdn>:9444/  (modules/reverse-proxy.nix)
  #     直結デバッグしたいときは SSH port-forward 越しに http://127.0.0.1:3001/
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
