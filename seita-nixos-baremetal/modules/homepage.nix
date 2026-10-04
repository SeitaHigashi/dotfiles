{ config, lib, pkgs, ... }:

##############################################################################
# Personal homepage (static site served by static-web-server).
#
# Docs:
#   docs/services/homepage.md   access, how to edit, port allocation
#
# When you change this file, update docs/services/homepage.md in the same commit.
##############################################################################

let
  # Loopback backend; tailnet exposure is the 9451 route in
  # modules/reverse-proxy.nix. 8085 was free when allocated (docs/network.md).
  port = 8085;

  # Site source lives in ../homepage and is copied into the store, so a
  # content change needs a rebuild (nixos-rebuild switch) to go live.
  site = pkgs.runCommand "homepage" { } ''
    mkdir -p $out
    cp -r ${../homepage}/. $out/
  '';
in
{
  services.static-web-server = {
    enable = true;
    listen = "127.0.0.1:${toString port}";
    root = "${site}";
  };
}
