# dotfiles

Personal dotfiles managed with NixOS and Home Manager.

## Structure

- **nixos/** - NixOS system configurations with flakes
  - `hosts/` - Host-specific configurations (seita-nixos, seita-mac-nix, seita-wsl)
  - `commons/` - Shared NixOS modules
- **home-manager/** - User environment configuration
  - `home.nix` - Main home-manager configuration
  - `wm/hyprland.nix` - Hyprland window manager setup
- **nvim/** - Neovim configuration (Lua-based)
- **wezterm/** - WezTerm terminal emulator config
- **waybar/** - Waybar status bar configuration
- **scripts/** - Utility scripts

## Setup

### NixOS System

```sh
cd nixos
sudo nixos-rebuild switch --flake .#seita-nixos
```

Replace `seita-nixos` with your hostname or configuration name.

Home Manager is integrated into the NixOS configuration and will be applied automatically.

### Manual Configs (Legacy)

For non-NixOS systems, symlink configs manually:

```sh
# Neovim
ln -s ~/.dotfiles/nvim ~/.config/nvim

# WezTerm
ln -s ~/.dotfiles/wezterm ~/.config/wezterm
```

## Hosts

- **seita-nixos** - Main NixOS desktop (x86_64-linux)
- **seita-mac-nix** - NixOS on Mac (x86_64-linux)
- **seita-wsl** - WSL environment

## Features

- Hyprland compositor with custom keybindings
- Neovim with lazy.nvim plugin management
- WezTerm with custom tab bar and font settings
- Declarative package management via Nix flakes
