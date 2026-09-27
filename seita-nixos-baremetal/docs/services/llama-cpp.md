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
| `qwen-image` | Qwen-Image-2.1 (stable-diffusion.cpp `sd-server`), DiT Q4_K + Qwen3-VL-8B Q4_K_M + VAE bf16 | 3060 Ti | image generation / editing |

`bonsai`, `bonsai-vision` and `qwen-image` occupy the same 3060 Ti so none of
them coexist (the matrix swaps between them). Every other combination can be
loaded at the same time.

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

### Calling qwen-image

```
POST http://127.0.0.1:8888/v1/images/generations
{"model": "qwen-image", "prompt": "...", "size": "1024x1024"}
```

Loading it evicts `bonsai` (and vice versa); the next `bonsai` request pays
bonsai's full reload. `ttl: 600` unloads it after 10 idle minutes, since it
holds ~9.4 GB of RSS while loaded. `sd-server` also exposes `/sdapi/v1/*`
(A1111-style) and its own web UI; reach those via `/upstream/qwen-image/...`.

Why `--offload-to-cpu`: despite the name it does not move compute to the
CPU. It sets the params backend to RAM, and the residency manager stages each
component into VRAM only for its own stage; the text encoder is explicitly
evicted when conditioning ends (`src/pipeline/image.cpp`,
`ConditionerRunnerEndOnExit`). Without it, the DiT stays resident and VAE
decode OOMs.

Measured 2026-09-25 (3060 Ti alone, sd.cpp master-913, euler 20 steps, cfg 6.0,
`--offload-to-cpu --fa` unless noted):

| run | VRAM peak | text enc. | sampling | VAE | total | max RSS |
|---|---|---|---|---|---|---|
| 1024², cold page cache | 5338 MiB | 24.0 s | 146.3 s | 12.0 s | 186 s | 9.35 GiB |
| 1024², warm | 5338 MiB | 10.9 s | 129.9 s | 10.5 s | 155 s | 9.40 GiB |
| 1024², `--backend te=cpu` | 5330 MiB | 38.2 s | 135.9 s | 10.7 s | 188 s | 9.38 GiB |
| 1024², no offload | 7368 MiB | 10.9 s | 128.6 s | OOM | failed | 5.50 GiB |
| 2048² | 7280 MiB | 4.0 s | 838.1 s (41.4 s/step) | OOM even tiled | failed | 8.72 GiB |

2048² is not usable as configured: sampling finishes, but VAE decode asks for
~10.8 GB even per tile and fails, after 14 minutes of work. Keep requests at
1024² until a smaller `--vae-tile-size` (or similar) is measured.

The peak is the DiT stage (4003 MiB weights + ~970 MiB compute buffer); VAE
decode first tries untiled (needs ~10.8 GB), fails, and retries tiled
automatically. Running the text encoder on the CPU saves no peak VRAM and is
slower, so it is not used.

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
