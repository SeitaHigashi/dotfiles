{ ... }:

##############################################################################
# xrdp — RDP remote desktop into a separate Plasma (X11) session.
#
# Exposure: tailscale0 only. The daemon itself listens on all interfaces,
# so services.xrdp.openFirewall stays off and the port is opened on the
# tailscale0 firewall interface only — same pattern as modules/ollama.nix
# and modules/fukurou.nix. Never open this to the LAN: login is the
# account password (PAM).
#
# The session is a virtual display (xorgxrdp), separate from the
# projector console session (modules/desktop.nix); the HDMI output and
# its BusID pin are unaffected.
#
# Audio stays off (the module default): it only supports PulseAudio
# sessions, this host runs PipeWire, and driving settings UIs — the
# actual use case — needs no sound.
##############################################################################

{
  services.xrdp = {
    enable = true;
    port = 3389;
    defaultWindowManager = "startplasma-x11";
    openFirewall = false;
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3389 ];
}
