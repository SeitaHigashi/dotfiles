let
  # Recipient public key, derived from this host's SSH host key:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # Decryption uses a derived age identity (/etc/age/host.key), not the raw
  # SSH private key — see docs/secrets.md.
  host = "age12k54m0g5x0xjpxfa5mg9v8zhp02rnktk94c87mq60fw7udjxaqdsgh6fp4";
in
{
  "discord-bot-env.age".publicKeys = [ host ];
  "multica-env.age".publicKeys = [ host ];
  "multica-github-app-key.age".publicKeys = [ host ];
  "openviking-root-api-key.age".publicKeys = [ host ];
}
