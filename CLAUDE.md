# CLAUDE.md

Personal dotfiles for NixOS + Home Manager (Nix Flakes).

## Critical Commands

```sh
# Apply config (seita-nixos-baremetal, /etc/nixos is a symlink into this repo's nixos/)
cd nixos && sudo nixos-rebuild switch --flake .#seita-nixos-baremetal

# Validate before applying
cd nixos && nix flake check
nix flake show

# Apply user-level dotfiles (separate standalone flake, not wired into nixos/)
cd home-manager && home-manager switch --flake .#seita
```

`nixos/` and `home-manager/` are **separate, independent flakes** — `nixos/flake.nix` does not
import home-manager as a NixOS module. See `nixos/CLAUDE.md` for the full host-specific reference
(services, ZFS/disko layout, GPU assignment, secrets via agenix, known gotchas).

## Key File Locations

| What to change | Where |
|---|---|
| System packages, services (seita-nixos-baremetal) | `nixos/configuration.nix`, `nixos/modules/*.nix` |
| Disk/ZFS layout | `nixos/disko/default.nix`, `nixos/machine.nix` |
| Secrets (agenix) | `nixos/secrets/` |
| User packages, shell, git | `home-manager/home.nix` |
| Hyprland WM | `home-manager/wm/hyprland.nix` |
| Neovim plugins | `nvim/lua/plugins/` |
| Neovim keybinds/LSP | `nvim/lua/keybinds.lua`, `nvim/lua/lsp-configs.lua` |

## Architecture Notes

- `nixos/` — full history-preserving merge of the host's live `/etc/nixos` git repo (see
  `nixos/CLAUDE.md`); `/etc/nixos` is a symlink to this directory, so system config is edited
  directly here and applied with `nixos-rebuild switch`
- `home-manager/` — standalone home-manager flake, applied independently with `home-manager switch`
- Neovim config is **not** managed by Nix — symlinked manually at `~/.config/nvim`
- `herdr/` — same symlink pattern: `~/.config/herdr` points here; runtime state (logs, sockets,
  session.json) is gitignored, only `config.toml` is tracked
- WezTerm is managed via home-manager (`programs.wezterm`)

## Active Services (seita-nixos-baremetal)

See `nixos/CLAUDE.md` for the authoritative, up-to-date list — it covers Ollama, ComfyUI, Open
WebUI, Home Assistant, Grafana/monitoring, Multica, OpenViking, n8n, Discord bot, Tailscale
Serve/Funnel, and more, along with the module responsible for each.

## Git Conventions

- Commit messages must be written in **English only**
- No ticket/issue prefix required
