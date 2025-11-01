{ config, pkgs, ... }:

{
  # Set your time zone.
  time.timeZone = "Asia/Tokyo";

  # Fonts
  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      hackgen-nf-font
    ];
    fontconfig = {
      enable = true;
      defaultFonts = {
        sansSerif = [ "Noto Sans CJK JP" "Noto Sans" ];
        serif = [ "Noto Serif JP" "Noto Serif" ];
      };
      subpixel = { lcdfilter = "light"; };
    };
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;
  services.printing.drivers = [
    pkgs.gutenprint
    pkgs.gutenprintBin
    pkgs.canon-cups-ufr2
    pkgs.canon-capt
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable nix command and flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Nix settings
  nix.settings = {
    download-buffer-size = 67108864 * 2;
    warn-dirty = false;
    max-jobs = 2;
  };

  # Nix store optimisation
  nix.optimise.automatic = true;
  nix.settings.auto-optimise-store = true;
  
  # Nix store garbage collection
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-order-than 7d";
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "yes";
    X11Forwarding = true;
  };

  # FlatPak
  services.flatpak.enable = true;

  # SW settings
  programs.nix-ld.enable = true;

  # Nano
  programs.nano.enable = false;
}
