{ config, pkgs, inputs, ... }:

##############################################################################
# Discord Gateway ボット -> n8n webhook 転送。
#
# Discordの受け方には「Interactionsエンドポイント (Discord側がHTTPで直接叩く)」と
# 「Gateway (ボット側がアウトバウンドでWebSocket接続する)」の2通りがある。
# 後者を選んでいるので、このホストの外に一切ポートを開ける必要がない
# (Developer Portalの Interactions Endpoint URL は空欄のまま)。
#
# ボット本体はGateway接続を保持するだけの小さなPythonスクリプトで、
# 受け取ったメッセージ/スラッシュコマンドをそのままn8nのwebhookへ
# ループバック転送する (Grafana alert webhookと同じ http://127.0.0.1:5678/... 方式)。
# n8n側の会話ロジック・返信は既存のTask Secretary Chatの仕組みを再利用する。
##############################################################################

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  agenixPkg = inputs.agenix.packages.${pkgs.system}.default;
in
{
  environment.systemPackages = [ agenixPkg ];

  # age の組み込み SSH 秘密鍵サポートは生の /etc/ssh/ssh_host_ed25519_key を
  # 直接渡すと "no identity matched any of the recipients" で失敗する
  # (2026-08-05 に実機で確認: age 1.2.1、agenix 0.15.0)。ssh-to-age -private-key
  # で変換した age ネイティブ形式の鍵なら同じ .age ファイルを問題なく復号できる。
  # そのため /etc/age/host.key (ssh_host_ed25519_key から導出、手動で1回だけ
  # 用意する — Grafana admin password と同じ「gitに置かない手動プロビジョニング」
  # 方式) を復号鍵として明示する。ホスト再構築時の再現手順:
  #   sudo install -d -m 0700 /etc/age
  #   sudo sh -c 'nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key \
  #     < /etc/ssh/ssh_host_ed25519_key > /etc/age/host.key'
  #   sudo chmod 600 /etc/age/host.key
  age.identityPaths = [ "/etc/age/host.key" ];

  age.secrets.discord-bot-env = {
    file = ../secrets/discord-bot-env.age;
    owner = "discord-bot";
    mode = "0400";
  };

  users.users.discord-bot = {
    isSystemUser = true;
    group = "discord-bot";
  };
  users.groups.discord-bot = { };

  systemd.services.discord-bot = {
    description = "Discord Gateway bot -> n8n webhook forwarder";
    after = [ "network-online.target" "n8n.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pythonEnv}/bin/python3 ${./discord-bot/bot.py}";
      EnvironmentFile = config.age.secrets.discord-bot-env.path;
      Restart = "on-failure";
      RestartSec = "10s";
      User = "discord-bot";
      Group = "discord-bot";
    };
  };
}
