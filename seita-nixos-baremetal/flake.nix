{
  description = "NixOS on ZFS — SSD x1 (rpool) + HDD x2 mirror (dpool), managed by disko";

  inputs = {
    # The system base is stable. Kernel, ZFS, systemd, initrd — everything
    # where "broken" means "won't boot" — comes from here. See docs/nixpkgs-channels.md.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Extra input for updating individual tools only — only packages listed
    # in modules/unstable.nix come from here. Never pull kernel modules (ZFS
    # etc.) from this input; see docs/nixpkgs-channels.md.
    #
    # Pinned to a specific revision rather than nixos-unstable — do not
    # switch back. Full incident and required check before bumping:
    # docs/decisions/2026-09-21-pin-nixpkgs-unstable.md
    #
    # nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/20b1ddd1aa5ace70c9468305030aa4f9ef79671b";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # agenix, for keeping secrets (Discord bot token etc.) encrypted at rest
    # in git. Decryption key is derived from this host's own SSH host key —
    # see docs/secrets.md.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pulls the user environment (dotfiles/home-manager/home.nix) in as a
    # NixOS module. Same pattern as nixos/ (mac/wsl) — plain import of
    # ../home-manager/home.nix — while home-manager/ itself stays a
    # standalone flake, still usable separately via
    # `home-manager switch --flake ./home-manager`.
    # Pinned to the release-25.05 branch, matching the system's stable
    # (nixos-25.05) line. Combining home-manager's master (assumes unstable)
    # with stable nixpkgs fails evaluation — home-manager's modules require
    # lib functions not present in the stable release (confirmed on this host
    # 2026-08-29). For an unstable package inside home-manager, go through the
    # same pkgs.unstable overlay as modules/unstable.nix (useGlobalPkgs = true
    # below makes pkgs.unstable.<name> reachable from home.nix directly).
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, agenix, home-manager, ... }@inputs:
  let
    # Configuration name matches the hostname. When --flake omits the
    # attribute name, nixos-rebuild looks up the configuration by the running
    # machine's hostname, which is what lets
    #   sudo nixos-rebuild switch --flake /etc/nixos
    # work without specifying #<name>.
    m = import ./machine.nix;
  in {
    nixosConfigurations.${m.hostName} = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        agenix.nixosModules.default
        disko.nixosModules.disko
        ./disko                        # disk/pool/dataset declarations
        ./hardware-configuration.nix   # output of nixos-generate-config --no-filesystems
        ./configuration.nix
        ./modules/zfs.nix
        ./modules/network.nix          # static IP / DHCP switch
        ./modules/replication.nix      # scheduled rpool -> dpool replication
        ./modules/unstable.nix         # makes pkgs.unstable.* available
        ./modules/ftb-evolution.nix    # Minecraft (FTB Evolution) via podman
        ./modules/gpu.nix              # NVIDIA driver (compute workloads + monitoring)
        ./modules/unfree.nix           # unfree package allowlist (sole definition of allowUnfreePredicate)
        ./modules/desktop.nix          # KDE Plasma (X11) — for projector output
        ./modules/monitoring.nix       # VictoriaMetrics + Grafana
        ./modules/zfs-snapshot-metrics.nix # snapshot / replication status metrics
        ./modules/gpu-xid-metrics.nix  # NVIDIA Xid ("GPU fallen off the bus" etc.) metrics
        ./modules/nix-info.nix         # installed package list / Hydra build status metrics
        ./modules/nix-profile-info.nix # user's nix profile contents / update-availability metrics
        ./modules/alerting.nix         # Grafana alert rules (notifications via n8n webhook)
        ./modules/ollama.nix           # local LLM (Ollama + Open WebUI) — disabled, see modules/ollama.nix
        ./modules/llama-cpp.nix        # local LLM (llama.cpp PrismML fork router) — replaces ollama, auto-starts (systemctl is-enabled llama-cpp: enabled, verified 2026-09-24)
        ./modules/n8n.nix              # workflow automation (tracks unstable)
        ./modules/comfyui.nix          # image generation (ComfyUI, venv via comfy-cli)
        ./modules/multica.nix          # Multica (AI agent management) self-hosted via podman
        ./modules/openviking.nix       # OpenViking (context DB for AI agents) self-hosted via podman
        ./modules/reverse-proxy.nix    # consolidates HTTP services behind Tailscale Serve
        ./modules/resource-priority.nix # cross-service CPU / memory priority
        ./modules/discord-bot.nix      # Discord Gateway bot -> n8n webhook
        ./modules/fukurou.nix          # systemd wiring for fukurou (voice dialogue loop, ~/fukurou)
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.seita = import ../home-manager/home.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.backupFileExtension = "backup";
        }
      ];
    };
  };
}
