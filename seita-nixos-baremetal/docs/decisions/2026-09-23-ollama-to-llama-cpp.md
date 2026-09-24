# Migration from ollama to llama.cpp

- Period: 2026-09-21 to 2026-09-23
- Scope: `modules/llama-cpp.nix`, `modules/ollama.nix`, `modules/alerting.nix`,
  `modules/resource-priority.nix`, `modules/openviking.nix`, the Open WebUI
  admin panel (outside git)

## Switching to always-on (2026-09-23)

`llama-cpp.service` was previously `wantedBy = [ ]` (manual start). The reason
was VRAM contention with ollama: with only 13.6 GiB of VRAM across the 2
cards, ollama resident with ~4.7 GiB for OpenViking left Bonsai only enough
room for 4K context. The migration side (bonsai-workspaces) measured and
concluded that both could be "defined," but there was no point running them
at the same time.

`modules/ollama.nix` set `enable = false` on 2026-09-21, so `ollama.service`
stopped being generated and the contention went away; `wantedBy` was switched
to `[ "multi-user.target" ]` on 2026-09-23.

## What flipped along with it

- [done] `modules/llama-cpp.nix`'s `wantedBy = [ ]` -> `[ "multi-user.target" ]` (2026-09-23)
- [done] `modules/ollama.nix`'s `services.ollama.enable` -> false (2026-09-21)
- [done] `modules/alerting.nix`'s service-inactive rule's `name=~` (added
  llama-cpp.service, removed ollama.service)
- [done] `modules/resource-priority.nix`: ollama's `MemoryHigh 12G` folded
  into llama-cpp's budget (ollama's side commented out on 2026-09-21)
- [done] OpenViking (`modules/openviking.nix`) migrated to llama.cpp's `bonsai`/`embedding`

## Open WebUI's ollama dependencies (3 of them)

All 3 need to move or something breaks quietly (no error, just looks like it's working).

1. **`OLLAMA_BASE_URL`** (`modules/ollama.nix`) — because of PersistentConfig
   below, switch this via Admin Panel -> Settings -> Connections, not the env var.
2. **`RAG_EMBEDDING_ENGINE`/`RAG_EMBEDDING_MODEL`** — repointed to `[embedding]`
   (Qwen3-Embedding-4B, 2560 dims) on 2026-09-23. Also PersistentConfig, so
   when RAG is actually used, set the same value under Admin Panel -> Settings -> Documents.
3. **Open WebUI's Pipe function** (Admin Panel -> Functions) — **cannot be
   deployed from the repo.** Hand-edited in the Web UI, doesn't show up in
   any diff. The `__task__` calls (title_generation/follow_up_generation)
   hit `http://127.0.0.1:11434/api/chat` directly, with model `gemma4:12b`
   and a custom Valve `task_num_ctx = 163840`. gemma4 was removed on
   2026-09-22; the migration target is `bonsai` (fixed at 80K,
   `task_num_ctx` has nowhere to go so it's dropped). n8n's fixed pipeline and
   OpenViking have already moved to bonsai
   (`~/seita-n8n-workflows/docs/workflows.md:216`) — only the Pipe is left
   behind. Details: `~/seita-n8n-workflows/docs/integrations.md:599-621`,
   background: same repo's `docs/gotchas.md:535-543`. How to rewrite the
   payload:
   [caller-facing notes in services/llama-cpp.md](../services/llama-cpp.md#caller-facing-notes).

### PersistentConfig: rewriting env vars alone doesn't fix (1) and (2)

Confirmed on-host, Open WebUI 0.11.3:

- `config.py:3237` `ENABLE_PERSISTENT_CONFIG` defaults to True
- `config.py:2833-` `DEFAULT_CONFIG` has `ollama.base_urls`/`openai.api_base_urls`/`rag.embedding_engine`

Settings under this behave as "env vars seed the DB on first boot, then the DB wins."

**`modules/ollama.nix`'s `OLLAMA_BASE_URL` is already inert on this host.**
The DB was already populated, so this only remains as a seed value — the
actual connection target is whatever's in the Admin Panel. Don't read "it's
set" as "it's in effect." Editing it here changes nothing about where
connections go.

Decision on 2026-09-21: switch it manually via the Admin Panel and don't add
`ENABLE_PERSISTENT_CONFIG = "False"` (keep Open WebUI's connection settings as
DB/UI-owned). In other words, **Open WebUI's connection target is outside git's control.**
Check the UI when in doubt.

To connect over OpenAI-compatible, use
`OPENAI_API_BASE_URL = "http://127.0.0.1:8888/v1"` and `OPENAI_API_KEY`
(any non-empty dummy string) instead of `OLLAMA_BASE_URL` (confirmed both
exist at `config.py:317-345`, on-host). To fully stop using the ollama side,
also set `ENABLE_OLLAMA_API = "False"`.

## Removal of `[embedding-nomic]` (2026-09-23)

The 768-dim nomic-embed-text v1.5 was kept around to avoid breaking Open
WebUI RAG's existing index, but both premises had already collapsed, so it
was removed. Both confirmed on-host, 2026-09-23:

1. **The call path didn't exist.** `RAG_EMBEDDING_ENGINE = "ollama"` was still
   set while ollama.service had been stopped since 2026-09-21, so RAG kept
   pointing at a dead 11434 and had never actually produced an embedding
   (confirmed no listener on 11434 via `ss`). `[embedding-nomic]` was dead
   code that had never been loaded even once.
2. **There was no existing index to protect.** Knowledge had 0 documents
   (confirmed by the user). Dimensions change 768 -> 2560, but re-indexing costs nothing.

Also a removal aimed at not filling the 1660 SUPER's VRAM with more
residents ([GPU and VRAM budget](../gpu-vram-budget.md)).

## Removal of gemma4/gemma4-32k (2026-09-22)

This model needed both cards, requiring a set that evicted `bonsai`. Removing
it collapsed the sets down to one, and the path that evicts `bonsai` no longer
exists ([llama-swap decision record](2026-09-22-llama-swap-matrix.md)).
