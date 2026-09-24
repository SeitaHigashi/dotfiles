# フォーク自身のルーターから llama-swap (matrix) へ

- 日付: 2026-09-22
- 対象: `modules/llama-cpp.nix` の `swapConfig`、`systemd.services.llama-cpp`

## 背景

当初は PrismML フォーク自身のルーターモード (`--models-preset` + `--models-max`) を使っていました。
このルーターの追い出しは「枠数ベースの LRU」だけで、VRAM もデバイスも見ていません。そのため:

- CUDA1 が空いていても CUDA0 の `[bonsai]` が追い出される
- CPU 実行の `[embedding]` が LRU で選ばれると、追い出しても VRAM が 1 バイトも空かず、結局 OOM する
  (実測。これが `--models-max 1` まで下げる羽目になった直接の原因)

どちらも「どのモデルとどのモデルが同居できるか」を表現する手段が無いことに起因していて、
パラメータの調整では消せません。

## 決定

[llama-swap](https://github.com/mostlygeek/llama-swap) (Go、OpenAI/Anthropic 互換の前段プロキシ) を前段に置く。
モデルごとに `llama-server` を子プロセスとして起動し、同居の可否を設定として書けます。
フォークのバイナリをそのまま `cmd` に書けるので、PrismML 依存は損ないません。

### routing engine は matrix

group エンジン (swap / exclusive / persistent) でも「embedding は bonsai を追い出さない」までは表現できますが、
このホストの制約は本質的に「どの組み合わせなら VRAM に載るか」であって、グループの階層ではありません。
matrix は載る組み合わせを `sets` に列挙し、`evict_costs` の小さいものから追い出すソルバなので、制約をそのまま書けます。

現在の set は 1 本 (`(bonsai | bonsai-vision) & embedding & laya`) で、`bonsai` が追い出される経路は存在しません。
2026-09-22 に gemma4 / gemma4-32k を削除したためです。gemma4 は 2 枚とも要る (1660 SUPER 単体では 20/49 層しか
載らず、プロンプト処理 14.42 tok/s で実用外。2026-09-22 実測) ので、戻すときは必然的に bonsai を追い出す set を
もう 1 本足すことになります。`evict_costs` はそのときのために bonsai を高くしてあります。

### GPU はモデルごとの CUDA_VISIBLE_DEVICES で割り当てる

以前は `models.ini` の `device = CUDA0 / CUDA1` で指定していましたが、ggml は `--device` で「使わない」と
指定したデバイスにも、見えている限り CUDA コンテキストを作ります (数百 MiB)。`[bonsai]` が CUDA0 を 410 MiB しか
残さない状態では、CPU 実行のはずの埋め込みプロセスですら CUDA0 を踏んで落ちる可能性がありました。
llama-swap はモデルごとに別プロセスなので env でカードそのものを見えなくできます。1 プロセスのルーターには
原理的にできないことです。

### CUDA_DEVICE_ORDER を FASTEST_FIRST から PCI_BUS_ID へ (逆転)

**2026-09-22 以前はこれが FASTEST_FIRST で、「PCI_BUS_ID にしてはいけない」と書いてありました。**
当時は `models.ini` が CUDA0 / CUDA1 という「速い順」前提の名前でカードを指していたため、PCI 順にすると
27B が 1660 SUPER に行って OOM しました。デバイス名で指さなくなった今は逆で、ヒューリスティック
(どちらが「速い」か) に依存しない PCI 順のほうが安定します。対応表は [GPU と VRAM の予算](../gpu-vram-budget.md)。

`modules/ollama.nix` も `CUDA_DEVICE_ORDER = "PCI_BUS_ID"` です。環境変数はユニットごとなので互いに影響しません。

## その他の設定の理由

- `globalTTL: 0`: 自動アンロードしない。「空いたから降ろす」より「必要になったら matrix が追い出す」ほうが素直。
- `--watch-config` を付けない: 設定は nix store 上の読み取り専用ファイルで、変更は必ず rebuild 経由。
  rebuild すると ExecStart の store パスが変わり、systemd が再起動対象と判定します。
- 数値の根拠 (tok/s、context の上限) は移行作業側の実測です。変更するときは
  `~/bonsai-workspaces/models.ini` 側のコメントも見てください。
