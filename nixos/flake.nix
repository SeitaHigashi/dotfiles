{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    hyprland.url = "github:hyprwm/Hyprland";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
  };

  outputs = inputs @ { nixpkgs, home-manager, ... }:
  let
    hm = [
      home-manager.nixosModules.home-manager
      {
        home-manager.useUserPackages = true;
        home-manager.users.seita = import ../home-manager/home.nix;
        home-manager.extraSpecialArgs = { inherit inputs; };
      }
    ];
  in
  {
    nixosConfigurations = {
      myNixOS = nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [
          /etc/nixos/configuration.nix
        ] ++ hm;
      };
      seita-nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
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
      seita-wsl = nixpkgs.lib.nixosSystem {
        system = builtins.currentSystem;
        modules = [
          ./hosts/seita-wsl.nix
        ] ++ hm;
      };
    };
  };
}
