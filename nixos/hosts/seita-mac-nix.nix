{ inputs, config, pkgs, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ./seita-mac-nix-hardware.nix
      ../user.nix
      ../commons/commons.nix
      ../commons/i18n.nix
      ../commons/applications.nix
      ../commons/de/gnome
      inputs.hyprland.nixosModules.default
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
  services.displayManager.gdm.enable = true;
  # services.desktopManager.gnome.enable = true;
  services.desktopManager.cosmic.enable = true;
  # services.desktopManager.cosmic.xwayland.enable = true;

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
