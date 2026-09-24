# PrismML フォークの llama.cpp をどうビルドするか

- 日付: 2026-09-21
- 対象: `modules/llama-cpp.nix` の `prismSrc` / `llamaCppPrism`

## なぜ PrismML フォークか

Bonsai-2 の PTQ1_0 / PQ2_0 という三値/1bit パッキングを復号できるのは PrismML のフォーク
(`github:PrismML-Eng/llama.cpp`, branch `prism`) だけで、本家 llama.cpp にも ollama にもカーネルがありません。
ollama のモデル blob も独自形式なので相互に使い回せません。

## 決定

フォークの「ソースの取得」だけをこのモジュールに持ち込み、派生は nixpkgs (unstable) の `llama-cpp` を
override して組み立てる。

- rev / hash は `~/bonsai-workspaces/flake.lock` に固定されているものと同一 (**正は向こう側**)。
  hash は lock の `narHash` をそのまま使えます (`type = "github"` の narHash は展開後ツリーの NAR ハッシュで、
  `fetchFromGitHub` のものと一致)。
- `patches = [ ]`: nixpkgs 側のパッチは本家の行番号前提でフォークには当たらない (bonsai-workspaces 側と同じ判断)。
- `cudaSupport` は nixpkgs 全体ではなく `llama-cpp` の override で名指し (CLAUDE.md の
  「`nixpkgs.config.cudaSupport = true` は設定しない」に従う)。CUDA ランタイムの unfree 許可は
  `modules/unfree.nix` の `cuda` / `libcu` 接頭辞で既に通っている (確認済み)。
- `CMAKE_CUDA_ARCHITECTURES` をこのホストの 2 枚 (`75` = 1660 SUPER, `86` = 3060 Ti) に絞る。
  nixpkgs の既定は `75;80;86;89;90;100;103;120;121` の 9 つ (実機で確認)。CUDA のコード生成はビルドの大半を
  占め、4C/8T の Ryzen 3 3300X ではそのまま初回 switch の待ち時間になります。2 つに絞った
  `libggml-cuda.so` は約 98 MB、9 つだとその数倍。`nixpkgs.config.cudaCapabilities` は nixpkgs の再 import が
  要るので使わず、cmakeFlags の差し替えで済ませています。

## 採らなかった案

### flake input にする

素直には `inputs.bonsai.url = "path:/home/seita/bonsai-workspaces";` ですが採れません。
`~/bonsai-workspaces` は git リポジトリではなく、`path:` の flake input はディレクトリツリーを丸ごと
nix store にコピーします。`models/` に GGUF が 27 GiB あるため、eval のたびに store が 27 GiB ずつ太ります
(git リポジトリなら追跡ファイルだけが対象になるので事情が変わります)。

### ビルド済みバイナリを ExecStart に直接書く

`modules/fukurou.nix` / `modules/comfyui.nix` と同じ「Nix はプロセス起動だけ面倒を見る」方式で、
`~/bonsai-workspaces/result-llama/bin/llama-server` を直接指す。ビルド時間はゼロですが、システム構成が
git 管理外の手動 `nix build` の結果に依存し、result シンボリックリンクを消すと GC でサービスが壊れます。
常駐させる以上は宣言的な今の形を選びました。

## 代償

CUDA 付きのソースビルドで、バイナリキャッシュは効きません (フォークなので hydra に無い)。
bonsai-workspaces で `nix build` 済みのものとも nixpkgs ピンが違うので store パスは一致しません。
更新手順は [runbooks/llama-cpp.md](../runbooks/llama-cpp.md)。
