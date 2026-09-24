{ config, lib, pkgs, ... }:

##############################################################################
# n8n (workflow automation).
#
# Docs:
#   docs/services/n8n.md   what it's for, access, config-is-env-vars gotcha,
#                          the node-on-PATH fix, storage/redundancy
#
# When you change this file, update docs/services/n8n.md in the same commit.
##############################################################################

let
  # n8n's default; checked against other allocations (docs/services/n8n.md).
  port = 5678;
in
{
  ############################################################################
  # Overlay pkgs.n8n itself to nixpkgs-unstable (docs/services/n8n.md for
  # why). Uses modules/unstable.nix's final.unstable; overlay evaluation
  # order doesn't matter since overlays are a fixpoint.
  #
  # n8n is non-free (Sustainable Use License) — allowUnfreePredicate lives in
  # modules/unfree.nix (nixpkgs.config can only be defined in one place).
  ############################################################################
  nixpkgs.overlays = [
    (final: prev: {
      n8n = final.unstable.n8n;
    })
  ];

  services.n8n = {
    enable = true;

    # Firewall is written explicitly below instead, matching other modules
    # (this option would open the port on every interface).
    openFirewall = false;

    # n8n 2.x reads config from env vars only, not the JSON this module
    # writes from `settings` (docs/services/n8n.md). `port` stays here only
    # because the module needs it at eval time to decide openFirewall.
    settings = { inherit port; };
  };

  ############################################################################
  # Actual config (2.x reads env vars, not `settings`; docs/services/n8n.md).
  ############################################################################
  systemd.services.n8n.environment = {
    N8N_PORT = toString port;
    # N8N_LISTEN_ADDRESS defaults to 0.0.0.0; kept, since this is LAN-exposed.

    GENERIC_TIMEZONE = "Asia/Tokyo";
    N8N_METRICS = "true"; # scraped by modules/monitoring.nix

    # Must be false: with plaintext HTTP + non-localhost access, n8n's
    # Secure-flagged cookie gets dropped by browsers and login loops forever.
    # Remove once TLS is put in front of n8n. (docs/services/n8n.md)
    N8N_SECURE_COOKIE = "false";
    N8N_ENABLED_MODULES = "agents";
  };

  # node must be on PATH for n8n 2.x's Code-node task runner (spawn('node', ...)),
  # or it fails silently with "spawn node ENOENT" while the main process still
  # starts. Details: docs/services/n8n.md.
  systemd.services.n8n.path = [ pkgs.unstable.nodejs ];

  # Open to the LAN (like Minecraft), not tailscale0-only. /metrics shares
  # the port (no secrets in it). docs/services/n8n.md.
  networking.firewall.allowedTCPPorts = [ port ];
}
