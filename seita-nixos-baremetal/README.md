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

## 横断

- [GPU と VRAM の予算](docs/gpu-vram-budget.md) — カードの対応表、カードごとの常駐と実測値

## サービス

- [llama.cpp (llama-swap + PrismML フォーク)](docs/services/llama-cpp.md) — ローカル LLM、埋め込み、Laya

## 手順

- [llama.cpp の運用](docs/runbooks/llama-cpp.md) — フォーク更新、GPU 載せ替え、Laya のセットアップ

## 設計判断

- [2026-09-21 PrismML フォークのビルド方式](docs/decisions/2026-09-21-llama-cpp-prism-build.md)
- [2026-09-22 フォーク自身のルーターから llama-swap (matrix) へ](docs/decisions/2026-09-22-llama-swap-matrix.md)
- [2026-09-23 Laya を llama-swap に同居させる](docs/decisions/2026-09-23-laya-in-llama-swap.md)
- [2026-09-23 ollama から llama.cpp への移行](docs/decisions/2026-09-23-ollama-to-llama-cpp.md)

## まだ docs に移していないモジュール

以下は経緯や実測値がまだ `.nix` のコメントにあります。順次移します。

`modules/ollama.nix`、`modules/monitoring.nix`、`modules/reverse-proxy.nix`、`modules/openviking.nix`、
`modules/comfyui.nix`、`disko/default.nix`、`modules/nix-info.nix`、`modules/resource-priority.nix`、
`modules/alerting.nix`、`modules/gpu.nix`、ほか
