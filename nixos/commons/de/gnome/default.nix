{ config, pkgs, lib, ... }:

lib.mkIf config.services.desktopManager.gnome.enable {
  environment.systemPackages = with pkgs; [
    gnomeExtensions.dash-to-dock
    gnomeExtensions.blur-my-shell
    gnomeExtensions.kimpanel
    gnomeExtensions.gsconnect
    gnomeExtensions.appindicator
    gnomeExtensions.tailscale-qs
    gnomeExtensions.media-controls
    gnomeExtensions.home-assistant-extension
    gnomeExtensions.paperwm
  ];

  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
    epiphany # web browser
    geary # email reader.
    cheese
    gnome-music
    evince # document viewer
  ];
}
