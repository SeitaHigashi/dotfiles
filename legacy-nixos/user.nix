{ config, pkgs, ... }:

{
  users.users.seita = {
    isNormalUser = true;
    description = "seita";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [ ];
  };
}
