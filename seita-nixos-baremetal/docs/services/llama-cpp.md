# llama.cpp (llama-swap + PrismML fork)

Implementation: [`modules/llama-cpp.nix`](../../modules/llama-cpp.nix)

## What it is

Turns the Bonsai-2 27B (ternary-quantized) model, validated in
`~/bonsai-workspaces`, into a resident service. Puts
[llama-swap](https://github.com/mostlygeek/llama-swap) in front, which reads
the `"model"` field of a request and starts/switches the matching
`llama-server` as a child process (equivalent to `ollama serve`).

- Listens on `127.0.0.1:8888` (8080 is taken by Open WebUI). Not exposed to
  the tailnet or LAN. When it's time to expose it externally, add it to
  `modules/reverse-proxy.nix`'s `routes`. An OpenAI-compatible base URL can
  include a path, so this shouldn't have the subpath trouble Ollama had
  (unverified).
- API: OpenAI-compatible (`/v1/chat/completions`, `/v1/embeddings`,
  `/v1/models`). **Not Ollama-compatible.**
- Auto-starts (2026-09-23~). Background:
  [migration from ollama](../decisions/2026-09-23-ollama-to-llama-cpp.md).
- Units: `llama-cpp.service` (the router itself), `laya-setup.service`
  (prepares `[laya]`'s venv and weights, oneshot).

Design decision records:

- [PrismML fork build method](../decisions/2026-09-21-llama-cpp-prism-build.md)
- [Why llama-swap (matrix) sits in front](../decisions/2026-09-22-llama-swap-matrix.md)
- [Why Laya is colocated in llama-swap](../decisions/2026-09-23-laya-in-llama-swap.md)
- [Migration from ollama](../decisions/2026-09-23-ollama-to-llama-cpp.md)

GPU/VRAM allocation and measurements are collected in
[GPU and VRAM budget](../gpu-vram-budget.md).

## Models

| ID | contents | GPU | use |
|---|---|---|---|
| `bonsai` | Ternary-Bonsai-2-27B PTQ1_0, 80K ctx, KV q4_0 | 3060 Ti | general generation (n8n, OpenViking's VLM) |
| `bonsai-vision` | same weights + mmproj (+600 MB), 8K ctx, KV q8_0 | 3060 Ti | image input |
| `embedding` | Qwen3-Embedding-4B Q4_K_M, 2560 dims | 1660 SUPER | OpenViking, Open WebUI's RAG |
| `laya` | Laya multilingual 322M (PyTorch, fp16) | 1660 SUPER | decision model for n8n's flow branching |

`bonsai` and `bonsai-vision` occupy the same 3060 Ti so they never coexist
(the matrix swaps between them). Every other combination can be loaded at
the same time.

## Caller-facing notes

Things the migration work and n8n side nailed down by measurement when
moving from the Ollama format to the OpenAI format:

- **The model name is the llama-swap model ID** (e.g. `bonsai`), not an ollama tag.
- `options.temperature` -> top-level `temperature`.
- There is **no** equivalent of `options.num_ctx`. Context is fixed per
  preset at server startup (`bonsai` is 80K).
- `think` is not needed. The reasoning part always comes back separately as `reasoning_content`.
- **Structured-output traps**:
  - `{"type":"json_schema","schema":{...}}` -> returns HTTP 200 but the
    **schema is silently ignored** (measured: unrelated keys returned in 3/3 tries).
  - `{"type":"json_schema","json_schema":{"name":"x","schema":{...}}}` -> the
    correct shape (succeeded 3/3).
- **An empty `content` can still look like a success.** If `max_tokens` is
  entirely consumed by reasoning, `content = ""` still comes back with a 200.
  Callers must check for empty content themselves.

### Calling Laya

Laya's API is not OpenAI-shaped, so use `/upstream/:model_id` (passes any
path straight through to the upstream) instead of `/v1/*`:

```
POST http://127.0.0.1:8888/upstream/laya/decide
{"state": "...", "questions": {"route": {"type": "choice",
  "instructions": "...", "criteria": {"A": "...", "B": "..."}}}}
```

The keys of `criteria` come back as-is as the choice. Concurrent calls are
serialized to 1 on the llama-swap side (only one model lives on that GPU, and
running them in parallel wouldn't speed things up, only raise the VRAM peak).

Measured (2026-09-23, 1660 SUPER, fp16):

| | GPU | CPU |
|---|---|---|
| short input (median, 25 runs) | 71.06 ms | 111.69 ms |
| long input (median, 25 runs) | 195.09 ms | 448.35 ms |

5/5 correct on a Japanese 4-choice test. The one near-miss also had a low
confidence (0.15), so act-or-escalate is working as designed. Keeps serving
on CPU when CUDA is unavailable (a slower answer beats a dead branch).

## Where models live

Uses `/home/seita/bonsai-workspaces/models` (27 GiB) as-is; no disko dataset was added.

1. `/home` is already on `dpool/home` (HDD mirror), so there's no redundancy
   gain from a new dataset.
2. Adding a dataset to a running system risks falling into emergency mode if
   done wrong (see the disko section of CLAUDE.md, and the 2026-08-25
   openviking incident). Not worth the risk for what's gained.
3. Runs as `User=seita`, so the DynamicUser `/var/lib/private` problem
   (the EBUSY case in `disko/default.nix`) doesn't come up in the first place.

That said, `dpool/home` is subject to auto-snapshot, so 27 GiB of
re-downloadable GGUFs are being snapshotted. Moving to a dedicated dataset
(`recordsize=1M` / `compression=off` / `auto-snapshot=false`, same settings as
`var/lib/ollama`) is a future improvement candidate. If you do move it, be
sure to follow the manual `zfs create` procedure before switching (CLAUDE.md).

Fetching models is not declarative (putting 27 GiB in the nix store isn't an
option). Done manually via `~/bonsai-workspaces/scripts/download-model.sh`.

## Using it interactively

The package is not in `environment.systemPackages` — it ships a binary named
`llama`, generic enough to collide on PATH. Interactively, use the
bonsai-workspaces flake instead:

```sh
cd ~/bonsai-workspaces && nix develop        # llama-cli / llama-bench etc.
nix run ~/bonsai-workspaces#bench -- ...
```

Operational procedures: [runbooks/llama-cpp.md](../runbooks/llama-cpp.md).
