{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland.url = "github:hyprwm/Hyprland";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix.url = "github:ryantm/agenix";
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = inputs @ { nixpkgs, home-manager, hermes-agent, agenix, ... }:
  let
    hm = [
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.seita = import ../home-manager/home.nix;
        home-manager.extraSpecialArgs = { inherit inputs; };
        home-manager.backupFileExtension = "backup";
      }
    ];
  in
  {
    nixosConfigurations = {
#       myNixOS = nixpkgs.lib.nixosSystem {
#         system = builtins.currentSystem;
#         modules = [
#           /etc/nixos/configuration.nix
#         ] ++ hm;
#       };
      seita-nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          agenix.nixosModules.default
          hermes-agent.nixosModules.default
          ./hosts/seita-nixos-configuration.nix
        ] ++ hm;
      };
      seita-mac-nix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; }; # this is the important part
        modules = [
          ./hosts/seita-mac-nix.nix
        ] ++ hm;
      };
#       seita-wsl = nixpkgs.lib.nixosSystem {
#         system = builtins.currentSystem;
#         modules = [
#           ./hosts/seita-wsl.nix
#         ] ++ hm;
#       };
    };
  };
}
