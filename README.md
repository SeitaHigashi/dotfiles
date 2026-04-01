# dotfiles

[![NixOS Configuration Test](https://github.com/SeitaHigashi/dotfiles/actions/workflows/nixos-test.yml/badge.svg?branch=main)](https://github.com/SeitaHigashi/dotfiles/actions/workflows/nixos-test.yml)

Personal dotfiles managed with NixOS + Home Manager (Nix Flakes).

## Hosts

| Host | OS | DE | Notes |
|---|---|---|---|
| `seita-nixos` | NixOS x86_64 | KDE Plasma 6 | Main desktop, Nvidia GPU, CUDA |
| `seita-mac-nix` | NixOS x86_64 | Hyprland | NixOS on Mac |

## Structure

```
.
├── nixos/                  # NixOS system config (Nix Flakes)
│   ├── flake.nix           # Entry point
│   ├── hosts/              # Per-host configs
│   │   ├── seita-nixos/
│   │   └── seita-mac-nix/
│   └── commons/            # Shared NixOS modules
├── home-manager/           # User environment
│   ├── home.nix            # Packages, shell, tools
│   └── wm/hyprland.nix     # Hyprland compositor
├── nvim/                   # Neovim (Lua + lazy.nvim)
├── wezterm/                # WezTerm terminal
├── waybar/                 # Waybar status bar
├── tmux/                   # Tmux config
└── scripts/                # Utility scripts
```

## Apply

```sh
cd nixos
sudo nixos-rebuild switch --flake .#seita-nixos
```

Home Manager is integrated into NixOS — applied automatically with `nixos-rebuild`.

## Key Features

- **Neovim** — lazy.nvim, LSP (mason), Treesitter, DAP, claudecode.nvim, Codeium
- **Ollama** — local LLM with CUDA, Open WebUI via Podman
- **Hyprland** — Wayland compositor with custom keybindings
- **Tailscale** — mesh VPN
- **Containerized services** — Home Assistant, Stable Diffusion (Podman)
- **Starship + Zoxide + Fzf** — modern shell tooling
