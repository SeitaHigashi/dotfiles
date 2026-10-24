{ inputs, config, pkgs, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ./seita-mac-nix-hardware.nix
      ../user.nix
      ../commons
      # MacBookPro12,1: Intel-only GPU, brcmfmac suspend/USB-wakeup quirks, SSD trim. Remove this line to go back to the plain hardware scan.
      inputs.nixos-hardware.nixosModules.apple-macbook-pro-12-1
      inputs.hyprland.nixosModules.default
      inputs.dms.nixosModules.dank-material-shell
      # inputs.dms.nixosModules.greeter  # old: removed from dms stable, use dank-greeter (revert by restoring this line + old option below)
      inputs.dank-greeter.nixosModules.default
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  zramSwap = {
    enable = true;
    memoryPercent = 100; # Use 100% of RAM for zram
  };

  networking.hostName = "seita-mac-nix"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.desktopManager.cosmic.enable = true;

  programs.dms-greeter = {  # old name: programs.dank-material-shell.greeter
    enable = true;
    compositor.name = "hyprland";  # Or "hyprland" or "sway"
  };

  nix.settings = {
    substituters = ["https://hyprland.cachix.org"];
    trusted-substituters = ["https://hyprland.cachix.org"];
    trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="];
  };

  programs.hyprland = {
    enable = true;
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    # withUWSM = true;
  };

  # Shell selection: caelestia-shell replaces DMS as the desktop shell (the DMS greeter stays).
  # Revert: set enable = true here and drop the caelestia block below.
  programs.dank-material-shell = {
    enable = false;  # old: true
    systemd = {
      enable = true;             # Systemd service for auto-start
      restartIfChanged = true;   # Auto-restart dms.service when dank-material-shell changes
    };
  };

  home-manager.sharedModules = [
    inputs.caelestia-shell.homeManagerModules.default
    ({ pkgs, ... }:
      let
        sys = pkgs.stdenv.hostPlatform.system;
        shellPkgs = inputs.caelestia-shell.packages.${sys};
        # caelestia-cli sets SETUPTOOLS_SCM_PRETEND_VERSION as a plain attr, which new nixpkgs no longer exports
        # to the build env (structuredAttrs), so hatch-vcs fails without .git. Pass it via env. Drop once upstream fixes it.
        cli = inputs.caelestia-shell.inputs.caelestia-cli.packages.${sys}.default.overrideAttrs (o: {
          preBuild = (o.preBuild or "") + "export SETUPTOOLS_SCM_PRETEND_VERSION=1\n";
        });
      in {
        programs.caelestia = {
          enable = true;
          systemd.enable = true;
          package = shellPkgs.caelestia-shell.override { withCli = true; caelestia-cli = cli; };
          cli = {
            enable = true;
            package = cli;
          };
        };
      })
  ];

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # For wine
    wineWowPackages.stable # support both 32-bit and 64-bit applications
    winetricks # winetricks (all versions)
    wineWowPackages.waylandFull # native wayland support (unstable)
  ];

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };

  # VM-only workaround: khal's man output fails to build on nixpkgs 5adc508 (tests pass, no man produced).
  # Real host unaffected; drop this once nixpkgs fixes khal.
  virtualisation.vmVariant.programs.dank-material-shell.enableCalendarEvents = false;

  # VM-only: wine is not in the binary cache (hours of source build); swap it for empty dirs.
  # Real host unaffected. Remove this block to build wine in the VM too.
  virtualisation.vmVariant.nixpkgs.overlays = [
    (final: prev: {
      wineWowPackages = prev.wineWowPackages // {
        stable = final.emptyDirectory;
        waylandFull = final.emptyDirectory;
      };
      winetricks = final.emptyDirectory;
    })
  ];

  # VM-only sizing for GUI checks (default is 1 GiB / 1 core).
  virtualisation.vmVariant.virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;
  };

  # VM-only login for GUI checks (the VM listens on localhost only; real host has no password here).
  virtualisation.vmVariant.users.users.seita.initialPassword = "vm";

  nix.settings.allowed-users = [ "*" ];

  networking.firewall = {
    enable = true;
    allowedTCPPortRanges = [
      { from = 1714; to = 1746; }
    ];
    allowedUDPPortRanges = [
      { from = 1714; to = 1746; }
    ];
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--accept-routes"
    ];
    extraSetFlags = [
      "--operator=seita"
    ];
  };
  networking.firewall.checkReversePath = "loose";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?

}
