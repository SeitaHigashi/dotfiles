let
  # 公開鍵(暗号化先)はこのホストの SSH ホスト鍵から導出したもの。
  # 確認方法: ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # 復号側は生の SSH 秘密鍵ではなく /etc/age/host.key を使う
  # (理由は modules/discord-bot.nix の age.identityPaths のコメント参照)。
  host = "age12k54m0g5x0xjpxfa5mg9v8zhp02rnktk94c87mq60fw7udjxaqdsgh6fp4";
in
{
  "discord-bot-env.age".publicKeys = [ host ];
  "multica-env.age".publicKeys = [ host ];
  "multica-github-app-key.age".publicKeys = [ host ];
}
