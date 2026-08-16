#!/usr/bin/env bash
#
# nixpkgs-unstable だけを更新するスクリプト。
#
# stable 側 (nixpkgs, disko, agenix) の flake.lock は一切触らず、
# modules/unstable.nix 経由・modules/ollama.nix (services.ollama.package) 経由で
# unstable から引いているパッケージ (ollama-cuda, open-webui, neovim,
# mcp-grafana, brave, multica-cli, opencode 等) だけをまとめて最新化する。
#
# 使い方:
#   scripts/update-unstable.sh          # lock 更新 + 評価チェックのみ
#   scripts/update-unstable.sh --switch # 上記に加えて sudo nixos-rebuild switch まで実行
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> nixpkgs-unstable を更新"
nix flake lock --update-input nixpkgs-unstable

echo "==> 評価チェック (ディスクは触らない)"
nix eval --raw .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel.drvPath

if [[ "${1:-}" == "--switch" ]]; then
    echo "==> nixos-rebuild switch"
    sudo nixos-rebuild switch --flake /etc/nixos
else
    echo "==> 評価成功。適用するには:"
    echo "      sudo nixos-rebuild switch --flake /etc/nixos"
    echo "    または"
    echo "      scripts/update-unstable.sh --switch"
fi
