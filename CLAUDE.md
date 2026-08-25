# CLAUDE.md

Personal dotfiles for NixOS + Home Manager (Nix Flakes).

## Critical Commands

```sh
# Apply config (seita-nixos-baremetal; /etc/nixos is a symlink into this repo's seita-nixos-baremetal/)
cd seita-nixos-baremetal && sudo nixos-rebuild switch --flake .#seita-nixos-baremetal

# Validate before applying
cd seita-nixos-baremetal && nix flake check
nix flake show

# Apply config (Mac / WSL — older multi-host flake, /etc/nixos symlinks here on those hosts)
cd nixos && sudo nixos-rebuild switch --flake .#seita-mac-nix   # or .#seita-wsl

# Apply user-level dotfiles (separate standalone flake, not wired into either nixos config above)
cd home-manager && home-manager switch --flake .#seita
```

`seita-nixos-baremetal/`, `nixos/`, and `home-manager/` are **separate, independent flakes** — none
of them import each other. See `seita-nixos-baremetal/CLAUDE.md` for the full baremetal host
reference (services, ZFS/disko layout, GPU assignment, secrets via agenix, known gotchas).

## Key File Locations

| What to change | Where |
|---|---|
| System packages, services (seita-nixos-baremetal) | `seita-nixos-baremetal/configuration.nix`, `seita-nixos-baremetal/modules/*.nix` |
| Disk/ZFS layout (seita-nixos-baremetal) | `seita-nixos-baremetal/disko/default.nix`, `seita-nixos-baremetal/machine.nix` |
| Secrets (agenix, seita-nixos-baremetal) | `seita-nixos-baremetal/secrets/` |
| System config (seita-mac-nix / seita-wsl) | `nixos/hosts/*.nix`, `nixos/commons/` |
| User packages, shell, git | `home-manager/home.nix` |
| Hyprland WM | `home-manager/wm/hyprland.nix` |
| Neovim plugins | `nvim/lua/plugins/` |
| Neovim keybinds/LSP | `nvim/lua/keybinds.lua`, `nvim/lua/lsp-configs.lua` |

## Architecture Notes

- `seita-nixos-baremetal/` — full history-preserving merge of this host's live `/etc/nixos` git
  repo (see `seita-nixos-baremetal/CLAUDE.md`); `/etc/nixos` on this host is a symlink to this
  directory, so system config is edited directly here and applied with `nixos-rebuild switch`
- `nixos/` — older multi-host flake (`seita-mac-nix`, `seita-wsl`) with home-manager imported as a
  NixOS module; `/etc/nixos` on those hosts symlinks here — kept as-is, not touched by the
  baremetal-host rework above
- `home-manager/` — standalone home-manager flake, applied independently with `home-manager switch`
- Neovim config is **not** managed by Nix — symlinked manually at `~/.config/nvim`
- `herdr/` — same symlink pattern: `~/.config/herdr` points here; runtime state (logs, sockets,
  session.json) is gitignored, only `config.toml` is tracked
- WezTerm is managed via home-manager (`programs.wezterm`)

## Active Services (seita-nixos-baremetal)

See `seita-nixos-baremetal/CLAUDE.md` for the authoritative, up-to-date list — it covers Ollama,
ComfyUI, Open WebUI, Home Assistant, Grafana/monitoring, Multica, OpenViking, n8n, Discord bot,
Tailscale Serve/Funnel, and more, along with the module responsible for each.

## Git Conventions

- Commit messages must be written in **English only**
- No ticket/issue prefix required
