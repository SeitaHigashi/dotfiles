{ config, pkgs, ... }:

{
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ja_JP.UTF-8";
    LC_IDENTIFICATION = "ja_JP.UTF-8";
    LC_MEASUREMENT = "ja_JP.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8";
    LC_NAME = "ja_JP.UTF-8";
    LC_NUMERIC = "ja_JP.UTF-8";
    LC_PAPER = "ja_JP.UTF-8";
    LC_TELEPHONE = "ja_JP.UTF-8";
    LC_TIME = "ja_JP.UTF-8";
  };

  # mozc 2.30 + Qt 6.12: uic rejects leading "::" in .ui class names. Strip it. Drop once nixpkgs/mozc fixes it.
  nixpkgs.overlays = [
    (final: prev: {
      mozc = prev.mozc.overrideAttrs (o: {
        postPatch = o.postPatch + ''
          find src -name '*.ui' -exec sed -i 's|\(class="\)::|\1|; s|<class>::|<class>|' {} +
        '';
      });
    })
  ];

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      fcitx5-mozc
      # fcitx5-mozc-ut  # UT dictionary; mozc 2.30 fails to build with Qt 6.12 (uic rejects "::mozc" class names). Restore once fixed.
      fcitx5-gtk
      fcitx5-tokyonight
    ];
  };
}
