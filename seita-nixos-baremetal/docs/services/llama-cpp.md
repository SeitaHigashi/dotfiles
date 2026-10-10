# llama.cpp (llama-swap + PrismML fork)

Implementation: [`modules/llama-cpp.nix`](../../modules/llama-cpp.nix)

## What it is

Turns the Bonsai-2 27B (ternary-quantized) model, validated in
`llm/` (formerly `~/bonsai-workspaces`), into a resident service. Puts
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
- Units: `llama-cpp.service` (the router itself), `laya-setup.service` and
  `jeff-setup.service` (prepare `[laya]`'s / `[jeff-qwen3.5-0.8b]`'s venv and weights, oneshot).

Design decision records:

- [PrismML fork build method](../decisions/2026-09-21-llama-cpp-prism-build.md)
- [Why llama-swap (matrix) sits in front](../decisions/2026-09-22-llama-swap-matrix.md)
- [Why Laya is colocated in llama-swap](../decisions/2026-09-23-laya-in-llama-swap.md)
- [Jeff in llama-swap (measurements, why the wrapper is shaped this way)](../decisions/2026-10-03-jeff-in-llama-swap.md)
- [Migration from ollama](../decisions/2026-09-23-ollama-to-llama-cpp.md)

GPU/VRAM allocation and measurements are collected in
[GPU and VRAM budget](../gpu-vram-budget.md).

## Models

| ID (aliases) | contents | GPU | use |
|---|---|---|---|
| `bonsai` (`chat`) | Ternary-Bonsai-2-27B PTQ1_0, 80K ctx, KV q4_0 | 3060 Ti | general generation (n8n, OpenViking's VLM) |
| `bonsai-vision` (`vision`) | same weights + mmproj (+600 MB), 8K ctx, KV q8_0 | 3060 Ti | image input |
| `embedding` | Qwen3-Embedding-4B Q4_K_M, 2560 dims | 1660 SUPER | OpenViking, Open WebUI's RAG |
| `laya` | Laya multilingual 322M (PyTorch, fp16) | 1660 SUPER | decision model for n8n's flow branching |
| `jeff-qwen3.5-0.8b` (`decision`, `jeff`) | Jeff v1.2 Qwen3.5 0.8B (PyTorch, text-only, fp16 weights / fp32 matmul) | 1660 SUPER | Jev-compatible decision model; alternative to `laya` (mutually exclusive in the matrix) |
| `qwen-image` | Qwen-Image-2.1 (stable-diffusion.cpp `sd-server`), DiT Q4_K + Qwen3-VL-8B Q4_K_M + VAE bf16 | 3060 Ti | image generation / editing |
| `bonsai-image` (`image`) | Bonsai Image Ternary 4B (FLUX.2 Klein 4B, gemlite INT2; PyTorch + diffusers + Triton, own HTTP wrapper) | 3060 Ti | image generation; alternative to `qwen-image` (mutually exclusive in the matrix) |
| `minimax-h3` | MiniMax-H3 (`sd-server`), pruned FL2VA DiT Q4_K_M + Qwen3-VL-32B Q2_K_M + video VAE fp16 + audio VAE fp32 | 3060 Ti | video + stereo audio generation |

**Aliases** (`aliases:` in the llama-swap config) are role names for callers: they work in the
`"model"` field and in `/upstream/<alias>/...` (verified on llama-swap 249, 2026-10-03), resolve to the
same process as the real ID, and show up in `/v1/models` only under `meta.llamaswap.aliases`.
The matrix and `evict_costs` use the **real ID**. IDs and aliases must not contain `/`
(`/upstream/a/b/` is a 404). `laya` and `jeff-qwen3.5-0.8b` are alternatives (`|`) in every matrix
set: they do not fit the 1660 SUPER together.
`image` is the role name for `bonsai-image` (like `chat` for `bonsai`); `qwen-image` has no alias,
so `"model": "image"` always means bonsai-image. The matrix set that is also called `image`
is a separate namespace and does not conflict (loaded and listed by llama-swap 249, 2026-10-10).

`bonsai`, `bonsai-vision`, `qwen-image`, `bonsai-image` and `minimax-h3` occupy the same 3060 Ti so none of
them coexist (the matrix swaps between them). `qwen-image` and `bonsai-image` are alternatives (`|`)
in the `image` set. Every other combination can be
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

### Calling Jeff

Jeff's API is not OpenAI-shaped either; use `/upstream/`. The alias `decision` can be swapped to
another decision model later without touching callers (the request shape is still Jeff's own, and
differs from Laya's: endpoint `/v1/systemone`, `"model"` is required, `noul` instead of yes/no).

```
POST http://127.0.0.1:8888/upstream/decision/v1/systemone
{"model": "jeff-latest", "state": "...", "questions": {"route": {"type": "choice",
  "instructions": "...", "criteria": {"A": "...", "B": "..."}}}}
```

The response has `answers.<name>.probabilities`, `choice` and `confidence`. Put the unchanging
parts of a request first and the changing field last (Jeff reuses the prepared prefix); never use
bare numbers as `criteria` keys.

Measured through llama-swap (2026-10-03, 1660 SUPER, 30 Japanese cases): 26/30 correct (Laya's
log on the same cases: 19/30, model/config not pinned down), 114 ms median warm, ~7 s for the
first request after a swap. Results are identical to fp32-on-CPU (0 label flips, probabilities
within 0.0014). Details: [decision record](../decisions/2026-10-03-jeff-in-llama-swap.md).

Jeff has `ttl: 600` (2026-10-10): it is unloaded after 10 idle minutes, freeing ~1 GiB on the
1660 SUPER, and the next request pays the cold load (~7 s measured above). Laya has no `ttl`.
To keep Jeff resident again, remove the `ttl` line from its entry in `modules/llama-cpp.nix`.

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

### Calling bonsai-image

```
POST http://127.0.0.1:8888/v1/images/generations
{"model": "bonsai-image", "prompt": "...", "size": "1024x1024", "seed": 42}   # alias "image" is also registered (listed by llama-swap; not yet exercised end to end)
```

The answer is `{"data": [{"b64_json": "<PNG>", "seed": 42}]}` (always `b64_json`, never a URL).
`n` must be 1, each side a multiple of 32 and at most 1024; `seed` is optional (random by default).
Steps (4) and guidance (1.0) are fixed: the sampler is distilled for exactly 4 steps.
The wrapper is `bonsaiImageServer` in `modules/llama-cpp.nix`; upstream's own FastAPI server only has
`/generate` behind a bearer token, so it is not used. Decision record and measurements:
[2026-10-10-bonsai-image-in-llama-swap.md](../decisions/2026-10-10-bonsai-image-in-llama-swap.md).

Loading it evicts `bonsai` (and `qwen-image`), and the next `bonsai` request pays bonsai's full reload.
`ttl: 600` unloads it after 10 idle minutes.

Measured 2026-10-10 on the 3060 Ti alone, 1024x1024, 4 steps:

| | |
|---|---|
| weights load (lazy, on the first request) | ~60 s |
| first image after a load (Triton compile, cold cache) | 113 s in total (load included), ~53 s of it compile |
| warm image | 9.5-9.7 s |
| torch peak | 6833 MiB (first image), 6447 MiB (warm) |
| `nvidia-smi` peak (incl. CUDA context) | 7812 MiB of 8192 |

** There is no VRAM headroom (~380 MiB), so nothing else may share the card and the size must not be
raised without measuring. ** The Triton cache (`TRITON_CACHE_DIR`) lives under
`/var/lib/llm-models/bonsai-image/triton-cache` (9.4 MB after the first request).

Measured through llama-swap on the running unit (2026-10-10, after `switch`): 93.7 s for the first
request (weights load + Triton compile, cold cache), 9.3 s warm. A resolution not seen before pays a
compile once (512x512: 14 s). Send `Content-Type: application/json`, or llama-swap answers
`no model id could be identified`.

The venv and weights come from `bonsai-image-setup.service` (like `jeff-setup`). Pins:
torch 2.11.0+cu128, gemlite **0.5.1.post1**, diffusers 0.38.0, transformers 5.8.1 (upstream's
`uv.lock`, except torch). To move gemlite to 0.6.x, `backend_gpu`'s `gl.W_q = ...` assignments have to
change first.

### Calling minimax-h3

Video is not on llama-swap's `/v1/*` routes (`/v1/vid_gen` is a 404). sd-server
only has an async job API, so the llama-swap command runs it behind a small
wrapper (`sdSyncWrapper` in `modules/llama-cpp.nix`) that adds one blocking
endpoint:

```
POST http://127.0.0.1:8888/upstream/minimax-h3/sync/vid_gen
{"prompt": "...", "width": 864, "height": 480, "video_frames": 56, "fps": 24}
-> (after the whole job, ~6-11 min) {"status": "completed", "result": {"b64_json": "...",
    "mime_type": "video/webm", "fps": 24, "frame_count": 56}}
```

Use this, not the raw async `POST /upstream/minimax-h3/sdcpp/v1/vid_gen`.
llama-swap only refuses to evict a model while one of its HTTP requests is in
flight (`internal/router/scheduler/fifo.go`, rule 5). The async API answers 202
at once, so the next `bonsai` request evicted sd-server and killed the job
(measured 2026-09-29: killed 13 s after submit). With the blocking call,
`bonsai` requests **queue for up to the job's length** instead — callers with a
short timeout (OpenViking's client, n8n) will see that as latency or a timeout.
Set the caller's HTTP timeout above the job length (the video itself takes
6-11 min).

Verified 2026-09-29 through llama-swap (22 frames, `MemoryHigh=40G`): the sync
call returned the WebM after 356 s; a `bonsai` request sent at t=150 s queued
and answered after 233 s (bonsai reload included) without interrupting the
job. `memory.events` high did not move; host MemAvailable bottomed at ~4.5 GB;
Minecraft's status response time and "Can't keep up" count were unchanged.

`upstream.ignorePaths` includes `^/sdcpp/v1/jobs/`, so polling a job never
loads the model. Without it, polling a vanished job reloaded minimax-h3 every
5 s and kept evicting bonsai (2026-09-29).

The wrapper also exits when sd-server logs `failed to initialize CUDA`: that
happened once right after a service restart, and sd-server then silently ran
on the CPU, which looks like a hang (22 W, no progress).

The result is a base64 WebM with the audio track included. Server defaults
(`GET /sdcpp/v1/capabilities`) are 512x512, 1 frame, fps 16 — always pass the
shape. Weights live in `models/MiniMax-H3/` (downloaded by hand from
`leejet/MiniMax-H3-GGUF` and `Comfy-Org/MiniMax-H3`, ~29 GB); while loaded
sd-server holds all 29,031 MB of params in RAM and 0 MB in VRAM until a job runs.
Like qwen-image it evicts `bonsai`, and `ttl: 600` unloads it when idle.

Measured 2026-09-28 with `sd-cli -M vid_gen` (3060 Ti alone, sd.cpp
master-913, 864x480, 56 frames = 2.3 s @ 24 fps, cfg 1.0,
`--offload-to-cpu --diffusion-fa --rng cpu`):

| stage | time |
|---|---|
| text encoder (Qwen3-VL-32B Q2_K_M) | 76.1 s |
| sampling | 496.7 s |
| video VAE decode | 68.4 s |
| audio VAE decode | 3.4 s |
| **total** | **644.8 s** |

The same shape through sd-server's `/sdcpp/v1/vid_gen` (weights already
loaded): 637 s from submit to `completed`, VRAM peak 7320 MiB.

VRAM peak 7322 MiB of 8192, max RSS 29.2 GB. Only ~800 MiB of VRAM headroom
is left, so larger shapes (resolution / frame count) are unmeasured and
likely OOM at VAE decode. The RSS is why nothing large can share the host
with it: with bonsai loaded only ~14 GB of RAM was free.

Trap met while measuring: without `CUDA_DEVICE_ORDER=PCI_BUS_ID`,
`CUDA_VISIBLE_DEVICES=1` selects the **1660 SUPER** (CUDA's default is
fastest-first). The service sets it, so this only bites manual runs. The same
job on the 1660 SUPER took 4908 s (VAE decode 545 s).

## Where models live

`/var/lib/llm-models` (`rpool/var/lib/llm-models`, NVMe; ~67 GiB as of 2026-10-03),
declared in `disko/default.nix` and referenced as `modelsDir` in `modules/llama-cpp.nix`.
Moved from `~/bonsai-workspaces/models` (`dpool/home`, HDD mirror). The same
dataset also holds Laya's and Jeff's regenerable state (`laya/`, `jeff/`: venvs,
HF cache, checkpoint; moved 2026-10-03), which keeps venvs off the HDD and out of
the git tree. Venvs are not relocatable, so they are rebuilt by `laya-setup` /
`jeff-setup` rather than moved.

1. **Load time.** llama-swap reloads a model from disk on every switch. The HDD
   mirror measured ~176-220 MB/s sequential read (`zpool iostat` during the
   copy), i.e. ~5 min for 64 GiB; NVMe cuts that to seconds.
2. **No redundancy needed.** GGUFs are re-downloadable, so the single-SSD
   `rpool` is acceptable.
3. **No snapshots/replication.** `recordsize=1M` / `compression=off` /
   `auto-snapshot=false`, same as the retired `var/lib/ollama` dataset.
4. Runs as `User=seita`, so no DynamicUser `/var/lib/private` problem; the
   directory is owned by `seita:users`.

The dataset was created by hand before the switch (CLAUDE.md, disko section):
`zfs create -o mountpoint=legacy -o recordsize=1M -o compression=off
-o com.sun:auto-snapshot=false rpool/var/lib/llm-models`, then `rsync`.
`llm/scripts/_config.sh` and the `llm/` devShell default `BONSAI_MODEL_DIR` to it.

Fetching models is not declarative (putting tens of GiB in the nix store isn't an
option). Done manually via `llm/scripts/download-model.sh` (defaults to `/var/lib/llm-models`).

## Using it interactively

The package is not in `environment.systemPackages` — it ships a binary named
`llama`, generic enough to collide on PATH. Interactively, use the
`llm/` flake instead:

```sh
cd ~/.dotfiles/seita-nixos-baremetal/llm && nix develop        # llama-cli / llama-bench etc.
nix run ~/.dotfiles/seita-nixos-baremetal/llm#bench -- ...
```

Operational procedures: [runbooks/llama-cpp.md](../runbooks/llama-cpp.md).
