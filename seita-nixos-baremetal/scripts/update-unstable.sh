#!/usr/bin/env bash
#
# Updates only nixpkgs-unstable.
#
# Leaves the stable side (nixpkgs, disko, agenix) flake.lock entries
# untouched, and only updates packages pulled from unstable via
# modules/unstable.nix and modules/ollama.nix (services.ollama.package) —
# ollama-cuda, open-webui, neovim, mcp-grafana, brave, multica-cli, opencode,
# etc.
#
# Usage:
#   scripts/update-unstable.sh          # lock update + eval check only
#   scripts/update-unstable.sh --switch # also runs sudo nixos-rebuild switch
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Updating nixpkgs-unstable"
nix flake lock --update-input nixpkgs-unstable

echo "==> Eval check (disks untouched)"
nix eval --raw .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel.drvPath

if [[ "${1:-}" == "--switch" ]]; then
    echo "==> nixos-rebuild switch"
    sudo nixos-rebuild switch --flake /etc/nixos
else
    echo "==> Eval succeeded. To apply:"
    echo "      sudo nixos-rebuild switch --flake /etc/nixos"
    echo "    or"
    echo "      scripts/update-unstable.sh --switch"
fi
