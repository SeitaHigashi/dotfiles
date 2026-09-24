{ config, lib, pkgs, ... }:

##############################################################################
# Network config: static IP (systemd-networkd) or DHCP (NetworkManager),
# switched by machine.nix's staticAddress, plus Tailscale and the firewall.
#
# Docs:
#   docs/network.md   network boundary, Tailscale Serve, firewall, port list
#
# When you change this file, update docs/network.md in the same commit.
##############################################################################

let
  m = import ../machine.nix;
  static = m.staticAddress != null;
in
{
  # When static, networkd owns the interface, so NixOS-wide DHCP must be off
  # (otherwise it races with the static config on every interface).
  networking.useDHCP = lib.mkDefault (!static);

  networking.networkmanager.enable = !static;

  ############################################################################
  # Static IP
  ############################################################################
  systemd.network = lib.mkIf static {
    enable = true;

    # With a single wired NIC, waiting for any interface is enough; avoids
    # boot hanging on a second NIC that's intentionally unplugged.
    wait-online.anyInterface = true;

    networks."10-lan" = {
      matchConfig.Name = m.networkInterface;

      address = [ m.staticAddress ];
      gateway = [ m.gateway ];
      dns = m.nameservers;

      networkConfig.IPv6AcceptRA = true; # accept router advertisements

      # What systemd waits for before considering the network up.
      # "routable" = a route exists. Without this, services that need the
      # network can fail right after boot.
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # Upstream DNS. Actually resolved by systemd-resolved (nixpkgs enables it
  # by default once systemd.network.enable = true), so /etc/resolv.conf
  # points at resolved's stub (127.0.0.53) and this value becomes resolved's
  # Global DNS (check with `resolvectl status`). Keep resolved enabled:
  # tailscaled's MagicDNS split-DNS registration (tail*.ts.net -> 100.100.100.100)
  # depends on it — disabling it breaks lookups of the FQDN used in
  # modules/reverse-proxy.nix.
  networking.nameservers = lib.mkIf static m.nameservers;

  ############################################################################
  # Firewall. services.openssh.enable = true opens 22/tcp automatically.
  # Add other ports (e.g. Minecraft's 25565) here as needed:
  #   networking.firewall.allowedTCPPorts = [ 25565 ];
  ############################################################################
  networking.firewall.enable = lib.mkDefault true;

  ############################################################################
  # Tailscale. Gives remote access to admin UIs (Grafana etc., see
  # docs/network.md) without opening any port to the WAN, and is the intended
  # eventual path for SSH too (password auth is still on — machine.nix's
  # allowPasswordAuth — pending moving fully to tailnet-only access).
  #
  # Unrelated to Minecraft's 25565, which stays open to the LAN regardless.
  #
  # First-time setup needs an interactive browser login:
  #   sudo tailscale up
  #   tailscale ip -4
  ############################################################################
  services.tailscale = {
    enable = true;

    # Registers tailscale0 as a trusted firewall interface and opens the UDP
    # direct-connection ports automatically. Without this, NAT traversal
    # fails and traffic falls back to slower DERP relaying.
    openFirewall = true;
  };
}
