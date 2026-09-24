# llama.cpp (llama-swap + PrismML フォーク)

実装: [`modules/llama-cpp.nix`](../../modules/llama-cpp.nix)

## 何か

`~/bonsai-workspaces` で検証してきた Bonsai-2 27B (三値量子化) を常駐サービスにしたもの。
前段に [llama-swap](https://github.com/mostlygeek/llama-swap) を置き、リクエストの `"model"`
フィールドを見てモデルごとの `llama-server` を子プロセスとして起動・切り替えます (= `ollama serve` 相当)。

- 待ち受け: `127.0.0.1:8888` (8080 は Open WebUI なので使えない)。tailnet / LAN には出していません。
  外から使う段階になったら `modules/reverse-proxy.nix` の `routes` に足します。OpenAI 互換のベース URL は
  パスを含められるので、Ollama ほどサブパス配下で困らないはずです (未検証)。
- API: OpenAI 互換 (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`)。**Ollama 互換ではありません。**
- 自動起動します (2026-09-23〜)。経緯は [ollama からの移行](../decisions/2026-09-23-ollama-to-llama-cpp.md)。
- ユニット: `llama-cpp.service` (本体)、`laya-setup.service` ([laya] の venv と重みの準備、oneshot)。

設計判断の経緯:

- [PrismML フォークのビルド方式](../decisions/2026-09-21-llama-cpp-prism-build.md)
- [llama-swap (matrix) を前段に置く理由](../decisions/2026-09-22-llama-swap-matrix.md)
- [Laya を llama-swap に同居させる理由](../decisions/2026-09-23-laya-in-llama-swap.md)
- [ollama からの移行](../decisions/2026-09-23-ollama-to-llama-cpp.md)

GPU / VRAM の割り当てと実測値は [GPU と VRAM の予算](../gpu-vram-budget.md) にまとめています。

## モデル

| ID | 中身 | GPU | 用途 |
|---|---|---|---|
| `bonsai` | Ternary-Bonsai-2-27B PTQ1_0、80K ctx、KV q4_0 | 3060 Ti | 汎用生成 (n8n、OpenViking の VLM) |
| `bonsai-vision` | 同じ重み + mmproj (+600 MB)、8K ctx、KV q8_0 | 3060 Ti | 画像入力 |
| `embedding` | Qwen3-Embedding-4B Q4_K_M、2560 次元 | 1660 SUPER | OpenViking、Open WebUI の RAG |
| `laya` | Laya multilingual 322M (PyTorch, fp16) | 1660 SUPER | n8n のフロー分岐用の決定モデル |

`bonsai` と `bonsai-vision` は同じ 3060 Ti を占有するので同居しません (matrix が入れ替えます)。
それ以外の組み合わせは同時に載ります。

## 呼び出し側の注意

Ollama 形式から OpenAI 形式に移すとき、移行作業側と n8n 側が実測で詰めた結果:

- **モデル名は llama-swap のモデル ID** (`bonsai` など)。ollama のタグではありません。
- `options.temperature` → トップレベルの `temperature`。
- `options.num_ctx` に相当するものは**ありません**。context はプリセットごとにサーバー起動時に固定です
  (`bonsai` は 80K)。
- `think` は不要。推論部分は常に `reasoning_content` として別に返ります。
- **構造化出力の罠**:
  - `{"type":"json_schema","schema":{...}}` → HTTP 200 で通るが **schema は黙って無視される**
    (3/3 で無関係なキーが返った実測)
  - `{"type":"json_schema","json_schema":{"name":"x","schema":{...}}}` → 正しい形 (3/3 成功)
- **`content` が空文字でも成功に見える**。`max_tokens` を reasoning が食い切ると `content = ""` で
  200 が返ります。呼び出し側で空判定をしてください。

### Laya の呼び出し

Laya の API は OpenAI 形ではないので `/v1/*` ではなく `/upstream/:model_id` (任意パスを upstream に
そのまま流す) を使います:

```
POST http://127.0.0.1:8888/upstream/laya/decide
{"state": "...", "questions": {"route": {"type": "choice",
  "instructions": "...", "criteria": {"A": "...", "B": "..."}}}}
```

`criteria` のキーがそのまま choice として返ります。同時実行は llama-swap 側で 1 に直列化しています
(GPU 上のモデルは 1 つで、並列にしても速くならず VRAM の山が高くなるだけのため)。

実測 (2026-09-23、1660 SUPER, fp16):

| | GPU | CPU |
|---|---|---|
| 短文 (median, 25 回) | 71.06 ms | 111.69 ms |
| 長文 (median, 25 回) | 195.09 ms | 448.35 ms |

日本語 4 択で 5/5 正解。外れかけた 1 件も確信度 0.15 と低く、act-or-escalate が設計通りに効いています。
CUDA が使えないときは CPU で動き続けます (落ちるより遅いほうがよい、という判断)。

## モデルの置き場

`/home/seita/bonsai-workspaces/models` (27 GiB) をそのまま使い、disko にデータセットを足していません。

1. `/home` は既に `dpool/home` (HDD ミラー) 上で、冗長性の観点では新設不要。
2. 稼働中システムへのデータセット追加は手順を誤ると emergency mode に落ちる
   (CLAUDE.md の disko の項、2026-08-25 の openviking の事例)。得るものに対してリスクが見合わない。
3. `User=seita` で動かすので DynamicUser の `/var/lib/private` 問題
   (`disko/default.nix` の EBUSY) がそもそも発生しない。

ただし `dpool/home` は auto-snapshot の対象なので、再ダウンロード可能な 27 GiB の GGUF が
スナップショットに乗っています。専用データセット (`recordsize=1M` / `compression=off` /
`auto-snapshot=false`、`var/lib/ollama` と同じ設定) に移すのは将来の改善候補です。
移すときは switch 前に手で `zfs create` する手順 (CLAUDE.md) を必ず踏むこと。

モデルの取得は宣言しません (27 GiB を nix store に入れる選択肢は無い)。手動で
`~/bonsai-workspaces/scripts/download-model.sh`。

## 対話的に使う

パッケージは `environment.systemPackages` に入れていません。`llama` という一般的すぎる名前の
バイナリを含み、PATH で衝突しうるためです。対話的には bonsai-workspaces の flake を使います:

```sh
cd ~/bonsai-workspaces && nix develop        # llama-cli / llama-bench 等
nix run ~/bonsai-workspaces#bench -- ...
```

運用手順は [runbooks/llama-cpp.md](../runbooks/llama-cpp.md)。
