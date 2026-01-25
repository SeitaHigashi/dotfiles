{ config, pkgs, lib, ... }:

{
  imports = [
    ./applications.nix
    ./commons.nix  
    ./i18n.nix
    ./de
  ];
}
