{ inputs, config, lib, pkgs, ... }:

##############################################################################
# Pulls selected leaf packages from nixpkgs-unstable while the base stays on
# stable. Full rationale, the unfree/allowlist interaction, and the
# nixpkgs-unstable pin: docs/nixpkgs-channels.md
#
# Do not add: the kernel or kernel modules (linuxPackages*, zfs, the NVIDIA
# driver), systemd, glibc, or anything on the systemd-boot path — all lead
# directly to an unbootable system. This file is for user-facing tools only.
#
# When you change this file, update docs/nixpkgs-channels.md in the same commit.
##############################################################################

let
  # Packages listed here come from nixpkgs-unstable. Reasons for each:
  # docs/nixpkgs-channels.md
  unstablePackages = with pkgs.unstable; [
    neovim
    mcp-grafana # Grafana Labs' official MCP server; launch config lives in ~/.claude.json, see CLAUDE.md
    brave # unfree — see modules/unfree.nix
    multica-cli # server itself is hosted via modules/multica.nix (podman)
    opencode # Multica's runtime protocol for talking to ollama's local models; provider config in ~/.config/opencode/opencode.json (outside this repo)
    nodejs # runs OpenViking's MCP server via npx
  ];
in
{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (final.stdenv.hostPlatform) system;
        # keep unfree allowance etc. consistent with the stable side
        inherit (prev) config;
      };
    })
  ];

  environment.systemPackages = unstablePackages;
}
