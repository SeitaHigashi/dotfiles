# GPU と VRAM の予算

このホストの GPU 2 枚に、どのサービスがどれだけ載っているか。複数のモジュール
(`modules/llama-cpp.nix`、`modules/fukurou.nix`、`modules/comfyui.nix`、`modules/openviking.nix`)
にまたがる話なので、ここを唯一の置き場にします。

**このカードに何かを足すとき・プリセットの数値を変えるときは、必ず先に実測すること。**
数値はすべて実測値で、推定で動かしてよいものはありません。

## カードの対応表

`CUDA_DEVICE_ORDER=PCI_BUS_ID` での番号 (`nvidia-smi --query-gpu=pci.bus_id` で実測):

| index | カード | PCI | VRAM | SM |
|---|---|---|---|---|
| 0 | GTX 1660 SUPER | 00000000:04:00.0 | 6144 MiB (実効 約 5745 MiB) | sm_75、テンソルコア無し |
| 1 | RTX 3060 Ti | 00000000:06:00.0 | 8192 MiB | sm_86 |

llama.cpp のモデルは `CUDA_VISIBLE_DEVICES` でカードごと見せる/見せないを決めています:

- `"1"` = 3060 Ti のみ (bonsai 系)
- `"0"` = 1660 SUPER のみ (embedding と laya)
- `"0,1"` (2 枚とも) や `""` (CUDA を初期化しない) も有効。前者は削除した gemma4 が、
  後者は CPU 実行時代の埋め込みが使っていました。

**GPU を載せ替えたら**、この表を実測し直し、あわせて `modules/llama-cpp.nix` の
`CMAKE_CUDA_ARCHITECTURES` (`75;86`) も更新すること。合わない SM の GPU では起動時に CUDA エラーになります。

`-ngl` や `--device` での指定では足りない理由: ggml は見えているデバイスすべてに CUDA コンテキスト
(数百 MiB) を作るため、`bonsai` が 410 MiB しか残していない 3060 Ti を、CPU 実行のはずのプロセスでも
踏みます。カードそのものを見せないのが確実で、これはモデルごとに別プロセスの llama-swap だから
できることです ([経緯](decisions/2026-09-22-llama-swap-matrix.md))。

## RTX 3060 Ti (index 1)

| 常駐 | 量 | 出所 |
|---|---|---|
| ComfyUI (`modules/comfyui.nix`、`gpuIndex = "1"`) | 130 MiB | 2026-09-21 実測 |
| `bonsai` (80K ctx, KV q4_0) | 残りほぼすべて (ロード後の空き 約 410 MiB) | 2026-09-22 実測 |

fukurou-server (478 MiB) は 2026-09-21 時点ではこのカードに居ましたが、2026-09-22 に
`GGML_VK_VISIBLE_DEVICES` で 1660 SUPER へ寄せています (`modules/fukurou.nix`)。
投影用 HDMI もこのカードに繋がっているため、投影中は Xorg の VRAM 消費も乗ります (`modules/comfyui.nix` の冒頭)。

### bonsai の context 上限

3060 Ti 単体、`ctk = ctv = q4_0`、`np = 1`、`ngl = 99` (2026-09-22、カードを空にした状態):

| context | 結果 | 使用量 |
|---|---|---|
| 32768 | OK | 6674 MiB |
| 65536 | OK | 7410 MiB |
| 81920 | OK | 7778 MiB |
| 90112 | NG | |
| 98304 | NG | |

NG 側は OOM ではなく `llama_init_from_model: failed to initialize the context: failed to allocate compute pp buffers`
(計算バッファが取れない)。**81920 は実測上限なので、他の常駐が減っても上げないこと。**

- 生成速度: 32.75 tok/s (80K、200 トークン生成)。q8_0 / 32768 の 33.4-33.8 tok/s からほぼ落ちない
  (KV 量子化は生成の律速ではない)。代償は KV の精度 (q8_0 → q4_0) だけ。
- 1660 SUPER に 1 層も載せないことが、生成で 1.3-1.5 倍、プロンプト処理で 2.5-3.7 倍に効きます
  (1660 SUPER にテンソルコアが無いため)。
- `bonsai-vision` は mmproj の +600 MB のぶん context が 8192 に落ちます。
- **`-np 1` は消さないこと。** `llama-server` の既定は並列スロット 4 で、再帰状態のキャッシュを
  スロットごとに確保するため、同じ context でも VRAM 消費が数倍になり 27B は OOM します。
  埋め込みモデルはスロットごとに増える状態が無いので既定の 4 のままです。

### 空き 410 MiB で問題ない理由

3060 Ti を踏みうる他のプロセスが居ないからです。`embedding` / `laya` は `CUDA_VISIBLE_DEVICES=0` で
このカードを物理的に触れず、3060 Ti を使う他のモデル (`bonsai-vision`) は matrix が必ず `bonsai` を
降ろしてから起動します。

### fukurou / ComfyUI の常駐は「見落とされた目減り」ではない (2026-09-21 時点の検証)

移行作業側の実測値 (33.6 tok/s、32768 OK / 36864 OOM といった当時の上限) は、すべて
この 2 つが常駐した状態のカードで取られたものです。2026-09-21 に fukurou / ComfyUI を載せたまま
`bonsai` をロードし直し、33.8 tok/s を再現しています (ロード後 7330/8192 MiB)。

したがってプリセットの数値をこの 2 つのために割り引く必要はありません。逆に、fukurou や ComfyUI を
止めても余裕が増えるだけで、**プリセットを上げる理由にはなりません**。

## GTX 1660 SUPER (index 0)

2026-09-23 実測。nvidia-smi の総容量は 6144 MiB ですが、ドライバ予約を引いた実効容量は約 5745 MiB
(PyTorch が "total capacity of 5.61 GiB" と報告する値)。

| 常駐 | 量 |
|---|---|
| fukurou (whisper.cpp、`modules/fukurou.nix` がピン留め) | 479 MiB |
| `embedding` (Qwen3-Embedding-4B Q4_K_M, `-c 8192`) | 3926 MiB |
| `laya` (Laya multilingual 322M, fp16) | 748 MiB |
| **合計** | **5153 MiB** |
| 空き | 約 590 MiB |

- **未調査の食い違い (2026-09-24)**: `nvidia-smi --query-compute-apps` で `laya` の python が
  **1128 MiB** を使っているのを観測しました (上の表の 748 MiB と合わない)。この値だと空きは約 210 MiB です。
  リクエスト処理後に PyTorch のキャッシュアロケータが確保したまま、という可能性がありますが確認していません。
- 残り 590 MiB は薄いので、このカードに何かを足すときは必ず先に実測すること。
- 起動しなくなったら、まず `embedding` の `ngl` を下げるか、`CUDA_VISIBLE_DEVICES=""` + `-ngl 0` の
  CPU 実行に戻すこと。CPU 実行でも 66 ms/リクエストで実用範囲でした。
- `laya` は fp32 だと 1318 MiB で、ここには載りません。fp16 化の事情は
  [Laya の判断記録](decisions/2026-09-23-laya-in-llama-swap.md)。
