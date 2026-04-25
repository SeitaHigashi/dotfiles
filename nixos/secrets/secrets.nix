let
  # seita-nixos SSH host public key
  # Source: cat /etc/ssh/ssh_host_ed25519_key.pub
  seita-nixos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINe9O3SwTFU1jS5/1Mj6N7WQb75/2gKMr9SuqX04+TR9";
in
{
  "tailclaude-env.age".publicKeys = [ seita-nixos ];
}
