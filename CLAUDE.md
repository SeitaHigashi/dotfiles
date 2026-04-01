# CLAUDE.md

Personal dotfiles for NixOS + Home Manager (Nix Flakes).

## Critical Commands

```sh
# Apply config (main desktop)
cd nixos && sudo nixos-rebuild switch --flake .#seita-nixos

# Apply config (Mac)
cd nixos && sudo nixos-rebuild switch --flake .#seita-mac-nix

# Validate before applying
cd nixos && nix flake check
nix flake show
```

Home Manager is **integrated into NixOS** — never use `home-manager switch` standalone.

## Key File Locations

| What to change | Where |
|---|---|
| System packages, services | `nixos/hosts/seita-nixos/seita-nixos-configuration.nix` |
| User packages, shell, git | `home-manager/home.nix` |
| Hyprland WM | `home-manager/wm/hyprland.nix` |
| Shared NixOS modules | `nixos/commons/` |
| Neovim plugins | `nvim/lua/plugins/` |
| Neovim keybinds/LSP | `nvim/lua/keybinds.lua`, `nvim/lua/lsp-configs.lua` |

## Architecture Notes

- `nixos/flake.nix` — single source of truth; imports home-manager as a NixOS module
- `nixos/commons/` — shared between both hosts; `default.nix` imports all modules
- Neovim config is **not** managed by Nix — symlinked manually at `~/.config/nvim`
- WezTerm is managed via home-manager (`programs.wezterm`)

## Active Services (seita-nixos)

- **Ollama** — CUDA-enabled local LLM, port 11434
- **Open WebUI** — Podman container (CUDA), port 3000
- **Home Assistant** — Podman container, network host
- **Tailscale** — mesh VPN with exit node
- **XRDP** — remote desktop via KDE Plasma

## Git Conventions

- Commit messages must be written in **English only**
- No ticket/issue prefix required
