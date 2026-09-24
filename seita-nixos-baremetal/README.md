# seita-nixos-baremetal

単一ベアメタルサーバー (`seita-nixos-baremetal`) の NixOS 構成。SSD×1 + HDD×2 mirror の ZFS 上で動き、
ディスクレイアウトは [disko](https://github.com/nix-community/disko) で宣言的に管理しています。

このファイルは目次です。中身は `docs/` にあります。Claude Code 向けの作業ルールは [CLAUDE.md](CLAUDE.md)。

## docs の置き方

| 置き場 | 書くもの |
|---|---|
| `.nix` のコメント | その行の制約だけ (「この値は実測上限、上げない」「8080 は使用中」など)。1〜数行 + docs へのポインタ |
| [`docs/services/`](docs/services/) | サービスごとの概要、使い方、呼び出し側の注意 |
| [`docs/runbooks/`](docs/runbooks/) | 手順 (更新、載せ替え、障害時の対応) |
| [`docs/decisions/`](docs/decisions/) | 設計判断とその経緯。`YYYY-MM-DD-<題>.md`。採らなかった案と理由も書く |
| `docs/*.md` (直下) | 複数モジュールにまたがる話 (VRAM の予算など) |

## インストールとストレージ

- [ストレージ (ZFS / disko) とインストール・運用](docs/storage-zfs.md) — クイックスタート、構成の全体像、
  disko レイアウトの読み方、スクラブ・スナップショット・ディスク交換、トラブルシューティングと障害事例

## まだ docs に移していないモジュール

以下は経緯や実測値がまだ `.nix` のコメントにあります。順次移します。

`modules/ollama.nix`、`modules/monitoring.nix`、`modules/reverse-proxy.nix`、`modules/openviking.nix`、
`modules/comfyui.nix`、`disko/default.nix`、`modules/nix-info.nix`、`modules/resource-priority.nix`、
`modules/alerting.nix`、`modules/gpu.nix`、ほか
