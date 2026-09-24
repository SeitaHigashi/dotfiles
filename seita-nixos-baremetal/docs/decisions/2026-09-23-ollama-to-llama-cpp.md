# ollama から llama.cpp への移行

- 期間: 2026-09-21 〜 2026-09-23
- 対象: `modules/llama-cpp.nix`、`modules/ollama.nix`、`modules/alerting.nix`、`modules/resource-priority.nix`、
  `modules/openviking.nix`、Open WebUI の管理画面 (git 管理外)

## 常時起動への切り替え (2026-09-23)

`llama-cpp.service` は以前 `wantedBy = [ ]` の手動起動でした。理由は ollama との VRAM 競合で、VRAM が 2 枚合計
13.6 GiB しかないところに ollama が OpenViking 用に約 4.7 GiB を常駐させると、Bonsai は 4K context しか載らなかった
ためです。両方を「定義」はできても「同時に動かす」意味はない、というのが移行作業側 (bonsai-workspaces) の実測結論でした。

2026-09-21 に `modules/ollama.nix` が `enable = false` になり `ollama.service` 自体が生成されなくなったので、
競合は解消し、2026-09-23 に `wantedBy = [ "multi-user.target" ]` へ切り替えました。

## 一緒に反転させたもの

- [済] `modules/llama-cpp.nix` の `wantedBy = [ ]` → `[ "multi-user.target" ]` (2026-09-23)
- [済] `modules/ollama.nix` の `services.ollama.enable` → false (2026-09-21)
- [済] `modules/alerting.nix` の service-inactive ルールの `name=~` (llama-cpp.service を足して ollama.service を外す)
- [済] `modules/resource-priority.nix` の ollama の `MemoryHigh 12G` を llama-cpp 側の予算に回す
  (2026-09-21 に ollama 側をコメントアウト)
- [済] OpenViking (`modules/openviking.nix`) を llama.cpp の `bonsai` / `embedding` へ移行

## Open WebUI の ollama 依存 (3 本)

3 本とも移さないと、一部だけ静かに壊れます (エラーにならず「動いているように見える」)。

1. **`OLLAMA_BASE_URL`** (`modules/ollama.nix`) — 下記 PersistentConfig のため、環境変数ではなく
   Admin Panel → Settings → Connections で切り替える。
2. **`RAG_EMBEDDING_ENGINE` / `RAG_EMBEDDING_MODEL`** — 2026-09-23 に `[embedding]`
   (Qwen3-Embedding-4B, 2560 次元) へ向け直し済み。これも PersistentConfig なので、実際に RAG を使うときは
   Admin Panel → Settings → Documents で同じ値に変更すること。
3. **Open WebUI の Pipe 関数** (Admin Panel → Functions) — **リポジトリから配備できません。** Web UI で手編集された
   もので、どの diff にも現れません。`__task__` 呼び出し (title_generation / follow_up_generation) が
   `http://127.0.0.1:11434/api/chat` を直接叩いており、model は `gemma4:12b`、独自 Valve の `task_num_ctx = 163840`。
   gemma4 は 2026-09-22 に削除済みで、移行先は `bonsai` (80K 固定、`task_num_ctx` は行き場が無いので捨てる)。
   n8n の固定パイプラインと OpenViking は既に bonsai に移っており (`~/seita-n8n-workflows/docs/workflows.md:216`)、
   Pipe だけが取り残されています。詳細は `~/seita-n8n-workflows/docs/integrations.md:599-621`、
   背景は同 `docs/gotchas.md:535-543`。ペイロードの書き換え方は
   [services/llama-cpp.md の呼び出し側の注意](../services/llama-cpp.md#呼び出し側の注意)。

### PersistentConfig: 環境変数を書き換えるだけでは (1) と (2) は効かない

実機の Open WebUI 0.11.3 で確認:

- `config.py:3237` `ENABLE_PERSISTENT_CONFIG` は既定 True
- `config.py:2833-` `DEFAULT_CONFIG` に `ollama.base_urls` / `openai.api_base_urls` / `rag.embedding_engine` がある

ここに載っている設定は「初回起動時に環境変数を DB に取り込み、以降は DB 側が勝つ」挙動です。

**`modules/ollama.nix` の `OLLAMA_BASE_URL` はこのホストでは既に無効です。** DB が出来た後なので seed として残っている
だけで、実際の接続先は Admin Panel の値です。「設定されているのだから効いている」と読まないこと。ここを書き換えても
接続先は変わりません。承知のうえで残してあるので、"修正" しないこと。

2026-09-21 の決定: 切り替えは Admin Panel で手作業で行い、`ENABLE_PERSISTENT_CONFIG = "False"` は足さない
(Open WebUI の接続設定は DB / UI 側の持ち物のままにする)。つまり **Open WebUI の接続先は git の管理外** です。
迷ったら UI を見てください。

OpenAI 互換で繋ぐときは `OLLAMA_BASE_URL` ではなく
`OPENAI_API_BASE_URL = "http://127.0.0.1:8888/v1"` と `OPENAI_API_KEY` (何か非空のダミー文字列) を使います
(`config.py:317-345` に両方あることを実機で確認済み)。ollama 側を完全に止めるなら `ENABLE_OLLAMA_API = "False"` も。

## [embedding-nomic] の削除 (2026-09-23)

768 次元の nomic-embed-text v1.5 を、Open WebUI の RAG が作った既存インデックスを壊さないために残していましたが、
前提が 2 つとも崩れていたため削除しました。どちらも 2026-09-23 に実機で確認:

1. **呼ぶ経路が存在しなかった。** `RAG_EMBEDDING_ENGINE = "ollama"` のまま ollama.service を 2026-09-21 に止めたので、
   RAG は死んだ 11434 を指したままで埋め込みを一度も作れていなかった (`ss` で 11434 の待ち受けなしを確認)。
   `[embedding-nomic]` は一度もロードされたことがない死にコードでした。
2. **守るべき既存インデックスが無かった。** Knowledge のドキュメントは 0 件 (ユーザー確認)。
   次元が 768 → 2560 に変わりますが、再インデックスのコストはゼロです。

1660 SUPER の VRAM をこれ以上の常駐で埋めないための削除でもあります ([GPU と VRAM の予算](../gpu-vram-budget.md))。

## gemma4 / gemma4-32k の削除 (2026-09-22)

2 枚とも要るモデルで、`bonsai` を追い出す set が必要でした。削除により set は 1 本になり、`bonsai` が追い出される
経路が無くなりました ([llama-swap の判断記録](2026-09-22-llama-swap-matrix.md))。
