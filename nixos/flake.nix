{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ { nixpkgs, home-manager, ... }:
  let
    commons = [
      home-manager.nixosModules.home-manager
      {
        home-manager.useUserPackages = true;
        home-manager.users.seita = import ../home-manager/home.nix;
      }
    ];
  in
  {
    nixosConfigurations = {
      myNixOS = nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [
          /etc/nixos/configuration.nix
        ] ++ commons;
      };
      seita-nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./seita-nixos/configuration.nix
        ] ++ commons;
      };
      seita-mac-nix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./seita-mac-nix/configuration.nix
        ] ++ commons;
      };
    };
  };
}
