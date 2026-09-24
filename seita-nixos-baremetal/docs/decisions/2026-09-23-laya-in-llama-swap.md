# Laya を llama-swap に同居させる

- 日付: 2026-09-23
- 対象: `modules/llama-cpp.nix` の `layaServer`、`[laya]` モデル、`systemd.services.laya-setup`

Laya (convaiinnovations/laya, multilingual 322M) は n8n のフロー分岐用の決定モデルです。
llama.cpp ではなく PyTorch で動きます。

## なぜ llama.cpp のモジュールに llama.cpp ではないものが居るのか

このモジュールが管理しているのは llama-swap (ルーター) であって、llama.cpp 専用ではありません。
llama-swap は `cmd` に任意のコマンドを書ける汎用のプロセス管理 + プロキシで、公式も vllm / ComfyUI 等を挙げています。

Laya をここに置く理由は 1 つで、**1660 SUPER の VRAM を matrix の `sets` で一元管理したい**からです。
独立した systemd サービスとして置くと、matrix から見えない VRAM 消費者が生まれ、「どの組み合わせなら載るか」を
設定で表現する設計が崩れます。

## GGUF にはできない

Laya は mmBERT-base バックボーンに独自の決定ヘッド (transformer 2 層 + option ごとの `[MASK]` を読むスコアラ +
act-or-escalate 出力) が乗った構造で、このヘッドを表現する手段が GGUF / llama-server にありません。
生成でも埋め込みでもないため、PyTorch で動かす以外の選択肢がありません。

## なぜ pip venv か (2026-09-23 の実機調査)

- nixpkgs に laya パッケージが存在しない。
- `python3Packages.torchWithCuda` は `cuda_cupti-12.8.90` の fixed-output hash mismatch でビルドできなかった。
- nix-ld はこのホストで無効 (`/lib64` にあるのは NixOS 既定の stub-ld で、`programs.nix-ld` は未設定)。

`modules/comfyui.nix` が同じ「pip venv 管理サービス」パターンの前例です。あちらと違って専用ユーザーは作りません。
`llama-cpp.service` が `User=seita` で動いており、venv も seita のホーム配下に置くため、権限の整合が自動で取れます。

- torch は cu121 wheel (PyTorch 公式インデックス。PyPI の torch は CUDA 版ではない)。CUDA ランタイムは wheel が
  同梱するので、システム側から要るのはドライバの `libcuda.so` (`/run/opengl-driver/lib`) だけ。
- `LD_LIBRARY_PATH` には `libstdc++.so.6` (stdenv.cc.cc)、zlib、`/run/opengl-driver/lib` の 3 つが要る
  (2026-09-23 に実機で 3 つとも必要だと確認)。
- バージョン (torch 2.5.1 / laya 0.3.6) は実測で動いた組み合わせに固定。

## HTTP ラッパー

laya パッケージは Python API しか持たないので、llama-swap から子プロセスとして起動できるよう最小の HTTP サーバを
被せています。低 QPS 用途で性能上の理由が無いため、FastAPI ではなく標準ライブラリだけで書いています。

## fp16 化 (このモジュールの肝)

laya パッケージは重みを fp32 のまま GPU に置きます。`Agent.__init__` が sm_80 未満で設定している `self.dtype` は
autocast (AMP) の計算 dtype であって、重みの dtype ではありません。実測 (2026-09-23):

| | VRAM | |
|---|---|---|
| fp32 | 1318 MiB | 空き 1337 MiB の 1660 SUPER では OOM |
| fp16 | 748 MiB | 収まる。精度劣化なし (確率が小数第 3 位まで一致) |

しかも fp32 のまま GPU に載せる段階で OOM するので、**「CPU でロード → `half()` → GPU へ移動」の順序でなければなりません**。
`device="cuda"` で load してから `half()` を呼んでも手遅れです。

## 重みの取得は laya-setup で事前に

llama-swap は `[laya]` を最初のリクエストが来たときに起動します。その場で 647 MB を落とすと `healthCheckTimeout` を
食い潰すので、ダウンロードは `laya-setup.service` で済ませ、実行時は `HF_HUB_OFFLINE=1` で閉じます
(取り損ねていれば即座に失敗するので、タイムアウトまで黙って待つより原因が分かる)。

`llama-cpp.service` から `laya-setup` へは `requires` ではなく `wants`。Laya の準備が失敗しても bonsai と embedding は
動くべきで、ルーター全体を道連れにする理由がないためです (その場合 `[laya]` だけが起動に失敗します)。

## evict_costs と同時実行

- `evict_costs` は bonsai (50) > laya (30) > embedding (1)。Laya は n8n のフロー分岐を同期で待たせるため、
  追い出されるとそのまま体感の遅延になります。埋め込みより残したいが、ロードの重い bonsai よりは安い、という序列。
- `concurrencyLimit: 1`: ラッパーは ThreadingHTTPServer ですが GPU 上のモデルは 1 つで、同時に叩いても速くならず
  VRAM の山だけが高くなります。マージンが薄いので llama-swap 側で直列化します。
