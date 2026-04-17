let
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINe9O3SwTFU1jS5/1Mj6N7WQb75/2gKMr9SuqX04+TR9 root@nixos";
in
{
  "hermes-env.age".publicKeys = [ hostKey ];
}
