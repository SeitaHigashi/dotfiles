{ config, lib, pkgs, ... }:

##############################################################################
# fukurou (local voice-conversation loop, Rust, developed at ~/fukurou):
# fukurou-server (STT -> LLM -> TTS) and fukurou-webui (browser test page).
#
# Docs: docs/services/fukurou.md (what it is, ports, PATH injection, Vulkan
# GPU pinning), docs/runbooks/fukurou.md (rebuild/restart, troubleshooting),
# docs/decisions/2026-09-22-fukurou-vulkan-gpu-split.md.
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  m = import ../machine.nix;
  fukurouDir = "/home/${m.userName}/fukurou";
  ports = {
    server = 7878; # fukurou-server WebSocket
    webui = 8765;  # fukurou-webui (dev test page)
  };

  # `claude` CLI comes from the imperative `nix profile install` profile, not
  # the default systemd PATH. Added via `path` (additive), not
  # `environment.PATH` (conflicts with the module system's own PATH def).
  userNixProfile = "/home/${m.userName}/.nix-profile";

  # `node`, needed by the claude CLI's SessionEnd hook, comes from
  # home-manager's per-user profile instead — same PATH-injection reasoning.
  userHomeManagerProfile = "/etc/profiles/per-user/${m.userName}";
in
{
  ############################################################################
  # fukurou-server (voice conversation loop, WebSocket 7878)
  ############################################################################
  systemd.services.fukurou-server = {
    description = "fukurou-server (voice conversation loop: STT -> LLM -> TTS)";

    after = [ "network.target" "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ userNixProfile userHomeManagerProfile ];

    # Pins whisper.cpp (STT) to the GTX 1660 SUPER via Vulkan, not CUDA.
    # ★ CUDA_VISIBLE_DEVICES/CUDA_DEVICE_ORDER have no effect on this unit —
    #   this process only touches the GPU through Vulkan.
    # ★ Vulkan's device index is its own enumeration, NOT nvidia-smi's index —
    #   on this host it's reversed (Vulkan 0 = 3060 Ti, Vulkan 1 = 1660 SUPER;
    #   measured via `vulkaninfo --summary`). Re-measure independently of the
    #   CUDA side after any GPU change. Full mapping and rationale:
    #   docs/services/fukurou.md, docs/decisions/2026-09-22-fukurou-vulkan-gpu-split.md.
    environment.GGML_VK_VISIBLE_DEVICES = "1";

    serviceConfig = {
      Type = "simple";
      User = m.userName; # claude CLI auth lives under seita's ~/.claude/
      WorkingDirectory = fukurouDir;
      ExecStart = "${fukurouDir}/target/release/fukurou-server --config config/server.toml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  ############################################################################
  # fukurou-webui (browser test page, 127.0.0.1 only)
  ############################################################################
  systemd.services.fukurou-webui = {
    description = "fukurou-webui (browser test client for fukurou-server)";

    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = m.userName;
      WorkingDirectory = fukurouDir;
      ExecStart = "${fukurouDir}/target/release/fukurou-webui --bind 127.0.0.1:${toString ports.webui}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  ############################################################################
  # Exposure: fukurou-server listens on 0.0.0.0, opened to tailscale0 only
  # (same pattern as ollama), for non-browser WebSocket clients. Also
  # double-published as wss:// on port 9447 via modules/reverse-proxy.nix,
  # since fukurou-webui is served over https and browsers block ws:// from an
  # https page as mixed content. fukurou-webui itself binds 127.0.0.1 and is
  # reached over the tailnet only via modules/reverse-proxy.nix. Details:
  # docs/services/fukurou.md.
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    ports.server
  ];
}
