# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

このリポジトリのコメント・ドキュメントは日本語で書かれています。追記するコメントも日本語で揃えてください。

## 何のリポジトリか

単一ベアメタルサーバー (`seita-nixos-baremetal`) の NixOS 構成。SSD×1 + HDD×2 mirror の ZFS 上で動き、
ディスクレイアウトは disko で宣言的に管理されます。ホームサーバー用途として Minecraft サーバー、
監視スタック、ローカル LLM が同居しています。詳細な設計意図と障害事例は [README.md](README.md) にあります。

## コマンド

```bash
# 日常のリビルド (実機上)
sudo nixos-rebuild switch --flake /etc/nixos

# ディスクを触らない構文/評価チェック — 変更後は必ずこれを通す
nix eval --raw .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel.drvPath

# ビルドだけして切り替えない (result シンボリックリンクができる)
nixos-rebuild build --flake /etc/nixos

# flake input の更新 (nixpkgs を上げると ZFS 対応カーネルの確認が要る)
nix flake update
```

構成名 = ホスト名なので、`--flake /etc/nixos` は `#<名前>` を省略できます。

新規インストールは `scripts/install.sh` (ISO 上で実行)。`scripts/disks.env` が唯一ユーザーが書き換える
ファイルで、そこから `machine.nix` が生成されます。テストスイートはありません。

## 構造の要点

- **`machine.nix` がマシン固有値の唯一の置き場**。`install.sh` が生成し、他のモジュールは
  `import ../machine.nix` で読みます (module 引数経由ではない)。ディスクの by-id、hostId、
  ユーザー、静的 IP、`nixPool`、`arcMaxBytes` など。ホスト固有の値を他のファイルに直書きしないこと。
- `flake.nix` の `modules` リストがモジュールの唯一の入り口。新しいモジュールを足したらここに追記が必要。
- **stable/unstable の分離**: 土台は `nixos-25.05`。`modules/unstable.nix` のリストに書いた
  「葉のパッケージ」だけが `nixpkgs-unstable` から来ます (`pkgs.unstable.*` で参照可)。
  カーネル・カーネルモジュール (ZFS, NVIDIA)・systemd・glibc をここから引くと起動不能になります。
- `disko/default.nix` がパーティション・zpool・データセット・`fileSystems` をすべて生成するため、
  `hardware-configuration.nix` は `--no-filesystems` で生成されており `fileSystems` を持ちません。

### モジュールと責務

| モジュール | 内容 |
|---|---|
| `modules/zfs.nix` | ARC 上限、autoScrub/trim/autoSnapshot、smartd、`forceImportRoot` |
| `modules/network.nix` | `m.staticAddress` が非 null なら systemd-networkd + 静的 IP、null なら NetworkManager + DHCP |
| `modules/replication.nix` | syncoid で `rpool/root`・`rpool/var/lib` → `dpool/backup/*` へ日次複製 (rpool は single vdev で冗長性が無いため) |
| `modules/ftb-evolution.nix` | podman で FTB Evolution サーバー。データは `/srv/minecraft` (HDD mirror) |
| `modules/gpu.nix` | NVIDIA プロプライエタリドライバ。`allowUnfreePredicate` の唯一の定義場所 (NVIDIA/CUDA + n8n + open-webui) |
| `modules/monitoring.nix` | VictoriaMetrics + Grafana + exporter 群 |
| `modules/ollama.nix` | `services.ollama` (ollama-cuda) + open-webui。どちらも unstable 追従 (open-webui は `package` オプションで指定、overlay 不要) |
| `modules/n8n.nix` | ワークフロー自動化。SQLite (`/var/lib/private/n8n`)。overlay で `pkgs.n8n` を unstable に差し替え |
| `modules/reverse-proxy.nix` | Tailscale Serve で HTTP サービスを 1 つの HTTPS 入口に集約。振り分け表 (`routes`) と、前段プロキシに追随させる各サービスの URL 設定をここに集約 |
| `modules/resource-priority.nix` | サービス間の CPU / メモリ優先度 (cgroup v2)。重みは相対値なのでここに集約 |

### ネットワーク境界

exporter と VictoriaMetrics は `127.0.0.1` のみ。

HTTP のサービスへの到達経路は `modules/reverse-proxy.nix` の Tailscale Serve に
一本化してあります (TLS 終端は tailscaled、証明書は MagicDNS 名に対して自動取得)。
nginx + ACME を採らないのは、証明書の秘密情報を置く仕組みがまだ無いためです。
tailscale0 で開いているのは **443 / 8443 / 11434 の 3 つだけ**で、Grafana の 3000 と
Open WebUI の 8080 は tailnet からも直接叩けません (切り分けには `ssh -L` を使う)。

Ollama の 11434 だけ直接開けてあります — ollama CLI や `OLLAMA_HOST` を使う
クライアントはベース URL にパスを含められず `/ollama/` では繋がらないためです。

**`--set-path` は prefix を剥がしてからバックエンドへ渡します。** サブパスに置くアプリには
「ルートで待ち受けつつ、生成する URL にだけ prefix を付ける」設定が要ります
(Grafana なら `root_url` を絶対 URL にしたうえで `serve_from_sub_path = false`。
ここを true にすると無限リダイレクトになります)。この非対称が原因で:

- **Open WebUI は必ずルート** — サブパス非対応 (0.6.9 の `open_webui/main.py` の
  `FastAPI(...)` に `root_path` が無い)。
- **n8n は別ポート (8443) のルート、`N8N_PATH` は設定しない** — `N8N_PATH` は
  フロントの `window.BASE_PATH` を書き換えるだけでバックエンドの待ち受けを動かさず、
  LAN からの直接アクセス (`http://<LAN IP>:5678/`) が白画面になります。

LAN に開いているのは Minecraft (25565) と n8n (5678) だけです。Minecraft は podman の
publish が DNAT を通って NixOS firewall で絞りきれないため、待ち受けアドレス自体を
LAN の静的 IP に固定しています。n8n は平文 HTTP なので LAN の外へは出さないこと。

ポート (待ち受け側。ファイアウォールで開いているかは上記のとおり別問題):
VictoriaMetrics 8428 / Grafana 3000 / node 9100 / smartctl 9633 / nvidia-gpu 9835 /
cadvisor 8081 / minecraft-exporter 9150 / n8n 5678 (Web UI と `/metrics` が同じポート) /
ollama・open-webui は `modules/ollama.nix` の `ports` 参照。
Tailscale Serve の待ち受けは 443 (Open WebUI `/`、Grafana `/grafana/`、Ollama `/ollama/`)
と 8443 (n8n `/`)。

### Grafana ダッシュボード

`dashboards/*.json` を provisioning でそのまま読み込みます (`allowUiUpdates = false` = UI からは読み取り専用)。
JSON は git が唯一の正。編集手順は UI で "Save as..." → JSON をエクスポート → `dashboards/` に反映 → rebuild。
エクスポートした JSON からは `__inputs` / `__requires` を削除すること。
データソース UID は `victoriametrics` に固定されており、変えると全ダッシュボードが "No data" になります。

## 触るときの注意

- **`special` vdev を SSD 1台で dpool に足さない** — SSD が死ぬと HDD ミラーごと全損します。
- `networking.hostId` はインストール後に変更しないこと (ZFS のプール識別に使われます)。
- `system.stateVersion = "25.05"` は上げない。
- `nixpkgs.config.cudaSupport = true` は設定しない (nixpkgs 全体が再ビルドになりバイナリキャッシュが効かなくなる)。
  CUDA が要るものだけ `pkgs.ollama-cuda` のように名指しで使います。
- FTB modpack は `FTB_MODPACK_VERSION_ID` で必ず固定 (`Restart=always` なので未指定だと再起動時に勝手に更新されます)。
- Minecraft のヒープ (`memory`) と `arcMaxBytes` の合計が物理 RAM を超えないこと。
- **podman コンテナに `systemd.services.podman-*.serviceConfig` で資源制御を書いても効きません** —
  conmon がコンテナを `machine.slice` 直下の `libpod-<id>.scope` へ移すためです。
  `--cgroup-parent` で専用スライスを与え、`modules/resource-priority.nix` の
  `systemd.slices` 側に重みを書きます。`IOWeight` は ZFS が blk-cgroup を通らないため無効です。
- **`nixpkgs.config.allowUnfreePredicate` は `modules/gpu.nix` の 1 箇所だけ**。関数なのでモジュール間で
  マージできず、2 箇所で定義すると衝突します。非フリーなパッケージ (n8n, open-webui) を足すときは
  gpu.nix のリストに追記してください。**stable では free でも unstable で非フリーに変わることがあります**
  (open-webui は 0.6.x の MIT から独自の Open WebUI License に変更)。
- NVIDIA ドライバのバージョンを変えたら再起動が必要。switch だけだと
  `Failed to initialize NVML: Driver/library version mismatch` になります。
- 秘密情報の仕組み (sops-nix / agenix) はまだありません。Grafana の admin パスワードは
  `/var/lib/grafana/admin-password` を Grafana の `$__file{}` で読む形で nix store と git の外に置いています。
  新しい秘密情報も nix 式に直書きしないこと。
