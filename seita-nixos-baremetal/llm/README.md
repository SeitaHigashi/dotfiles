# Bonsai-27B on the PrismML llama.cpp fork (Nix flake)

Runs **`prism-ml/Ternary-Bonsai-27B` in the PQ2_0 packing** (ternary weights, ~2.13 bpw)
locally on `seita-nixos-baremetal`.

PQ2_0 is *not* supported by mainline llama.cpp — the ternary kernels and Hadamard
rotation logic only exist in `PrismML-Eng/llama.cpp`, branch `prism`. The flake pins
that fork (rev locked in `flake.lock`) into the nixpkgs `llama-cpp` derivation so the
CUDA plumbing, driver runpath fixes and multi-arch CPU backends come for free.

## Layout

| path | what |
|---|---|
| `flake.nix` | fork pinned + built for CUDA (`sm_75` + `sm_86`), CPU, Vulkan |
| `scripts/download-model.sh` | fetch PQ2_0 + mmproj (`--with-drafter` adds DSpark) |
| `scripts/run-cli.sh` | interactive chat |
| `scripts/run-server.sh` | OpenAI-compatible server on `127.0.0.1:8888` |

## Use

```bash
./scripts/download-model.sh      # ~7.3 GB, once

nix run .#bonsai                 # interactive chat, like `ollama run`
nix run .#bonsai-server          # OpenAI API + web UI on http://127.0.0.1:8888

nix develop                      # shell with bonsai / bonsai-server / llama-* on PATH
```

In the chat UI: `/exit`, `/regen`, `/clear`, `/read <file>`, `/glob <pattern>`.
Extra `llama-cli` flags pass straight through: `nix run .#bonsai -- -n 512`.

Env knobs: `BONSAI_MODEL_DIR`, `BONSAI_CTX`, `BONSAI_PORT`, `BONSAI_MMPROJ=0`
(skip the vision projector and save ~600 MB VRAM).

Packages: `.#llama-cpp-prism-cuda` (default), `.#llama-cpp-prism-cpu`,
`.#llama-cpp-prism-vulkan`. Apps: `nix run .#cli` / `.#server` / `.#bench`.

## Measured on this host

GTX 1660 SUPER (6 GB, sm_75) + RTX 3060 Ti (8 GB, sm_86), layers split across both,
with Ollama stopped (~12.8 GB free). `-ngl 99`, PQ2_0, vision projector loaded.

| config | prompt | generation |
|---|---|---|
| `-c 4096`, text-only | 52.8 t/s | **29.1 t/s** |
| `-c 32768`, vision | 46.3 t/s | **27.4 t/s** |
| `-c 32768`, text-only | 46.1 t/s | 27.3 t/s |
| `-c 65536`, vision, KV `q8_0` | 46.0 t/s | 27.2 t/s |
| `-c 32768` via `llama-server` `/v1/chat/completions` | 45.2 t/s | 27.4 t/s |

VRAM at the default `-c 32768` with projector: 4569 MiB on the 1660 SUPER +
7005 MiB on the 3060 Ti — 11.3 GB total, ~2 GB headroom.

Ceilings found:

- `-c 65536` needs `-ctk q8_0 -ctv q8_0`; f16 KV OOMs.
- `-c 131072` OOMs even with q8_0 KV. The model advertises 262K context, so the
  limit here is the 14 GB of VRAM, not the model.
- The model alone is 6.7 GB, so it **does not fit on the 3060 Ti by itself** —
  `CUDA_VISIBLE_DEVICES=<3060Ti>` fails to load. Both GPUs are required.
- With Ollama resident (~4.7 GB for OpenViking) only `-c 4096` text-only fits.
  Stop Ollama before running Bonsai, or cap at 4096 and set `BONSAI_MMPROJ=0`.

`llama-server` reports thinking output in `reasoning_content`, separate from
`content` — budget `max_tokens` accordingly.

## Variants (for reference)

| | Bonsai-27B (1-bit) | **Ternary-Bonsai-27B (in use)** |
|---|---|---|
| weights | {−1, +1}, 1.125 bpw | {−1, 0, +1}, ~1.71 bpw |
| GGUF | `Q1_0`, ~3.9 GB | `PQ2_0`, 6.7 GB (`PTQ1_0` ~5.95 GB) |
| 15-bench avg | 76.11 (~90% of FP16) | 80.49 (~95% of FP16) |
| mainline llama.cpp | works | **fork required** |

## Tool calling

`llama-server` is started with `--jinja`, so the model's own chat template drives
OpenAI-style `tools` / `tool_calls`. Two suites, 3 runs per case, `temperature 0.5`:

```bash
nix shell nixpkgs#python3 --command python3 scripts/test-tools.py       # basics
nix shell nixpkgs#python3 --command python3 scripts/test-tools-hard.py  # nested/traps
```

Measured on Ternary-Bonsai-2-27B PQ2_0, `-c 32768`:

| suite | result |
|---|---|
| basics (single call, selection, enum/int args, negative case, parallel, multi-turn) | **21/21** |
| hard (nested schema, 8-tool distractors, Japanese, traps, forced `tool_choice`, chain) | **27/27** |

No failures. An earlier revision of this file reported 25/27 and blamed a
nested-schema weakness — that was a bad test, not a bad model: the schema left
`location` and its fields optional while the check asserted `room == 301`, so the
two "failures" were schema-valid responses. Corrected and measured, 8 runs each:

| `location.room` | filled |
|---|---|
| not in `required` | **1/8** — `{"building": "Shibuya building"}` |
| in `required` | **8/8** — `{"room": "301", "building": "Shibuya"}` |

**The lesson is a usable rule: if a field matters, put it in `required`.** Bonsai
honours `required` exactly and treats optional as genuinely optional, rather than
filling optional fields opportunistically. Every probe passes, including the
three traps where a tool must *not* fire (no tool fits / destructive tool dangled /
underspecified request — it asked for the missing fields instead of inventing them),
forced `tool_choice` by name, parallel calls, and Japanese prompts with argument
extraction (`「蒸らし」` → `set_timer({"seconds": 180, "label": "蒸らし"})`).

## Router mode — Ollama-style model switching

`llama-server` has a built-in **router mode**: started without `-m`, it becomes a
front process that spawns one child `llama-server` per model, loads them on demand,
and routes each request by the `"model"` field in the body. That is the same shape
as `ollama serve` — no external proxy needed.

```bash
nix run .#bonsai-router      # reads ./models.ini, listens on 127.0.0.1:8888
```

`models.ini` gives each model its own flags, which is what makes coexistence work
here — Bonsai on both GPUs, embeddings on CPU:

```ini
[*]
jinja = true
split-mode = layer

[bonsai]
model  = .../Ternary-Bonsai-2-27B-PQ2_0.gguf
mmproj = .../Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
ngl = 99
c = 32768

[embedding]
model = .../Qwen3-Embedding-4B-Q4_K_M.gguf
embeddings = true
pooling = last
ngl = 0
c = 8192
```

Verified end to end:

| step | result |
|---|---|
| `GET /models` before any request | both listed, `status: unloaded` |
| `POST /v1/chat/completions {"model":"bonsai"}` | autoloaded, 26.5 tok/s |
| `POST /v1/embeddings {"model":"embedding"}` | autoloaded, dim 2560 — **Bonsai stayed loaded** |
| `GET /models` after both | both `loaded`; GPU 4725 + 7812 MiB (embeddings are on CPU) |
| `POST /models/unload {"model":"embedding"}` | `{"success":true}`, status flips to `unloaded` |

Knobs: `BONSAI_PRESET` (INI path), `BONSAI_MAX` (resident models, default 2,
`0` = unlimited), `BONSAI_PORT`. `--no-models-autoload` disables autoloading, and
`?autoload=false` does it per request. `--models-dir` is the zero-config
alternative: it scans a directory and names each model after its file/subdirectory,
but every model then inherits one global flag set — which is exactly what fails
here (a global `-ngl 99` makes the embedding model try the GPU and OOM).

### On `dimensions`

`/v1/embeddings` **ignores** the `dimensions` parameter — Qwen3-Embedding-4B returns
its native 2560 every time, and there is no CLI option for Matryoshka truncation.
Ollama implements that truncation itself. Anything needing 2048-dim vectors (e.g.
OpenViking's bootstrap collection) has to truncate and L2-renormalize client side,
or be reindexed at 2560.

### Other models in the router

Any standard llama.cpp GGUF works — add a section to `models.ini` and it appears in
`GET /models`. **Ollama's own blobs cannot be reused**: they are in Ollama's GGUF
format and depend on the compat layer patched into Ollama's vendored llama.cpp
(`llama_ollama_compat.cpp`, `detected Ollama-format gemma4 GGUF; applying
compatibility fixes`). Pull the upstream GGUF instead, e.g. from `ggml-org`.

Gemma 4 12B added as `[gemma4]` (`ggml-org/gemma-4-12B-it-GGUF`, Q4_0 6.7 GB +
projector 152 MB). With `BONSAI_MAX=1` the router evicts before loading, as intended:

| request | result | wall time |
|---|---|---|
| `{"model":"bonsai"}` cold | 26.5 tok/s | 9.5 s |
| `{"model":"gemma4"}` — evicts Bonsai | 37.6 tok/s | 47.9 s |
| `{"model":"bonsai"}` — evicts Gemma | 26.4 tok/s | 9.4 s |
| `{"model":"bonsai"}` warm | 26.6 tok/s | 1.3 s |

So a model switch costs one reload (~8-47 s here, dominated by reading the GGUF from
disk), and a warm request is ~1.3 s. Set `BONSAI_MAX` higher to keep more resident
when the VRAM allows it.

### GPU device order is reversed here — check it before pinning

`CUDA_VISIBLE_DEVICES` does **not** use nvidia-smi's numbering. CUDA defaults to
"fastest first"; nvidia-smi orders by PCI bus id. On this host they are opposite:

| | nvidia-smi | CUDA |
|---|---|---|
| GTX 1660 SUPER (sm_75, bus 04:00) | 0 | **1** |
| RTX 3060 Ti (sm_86, bus 06:00) | 1 | **0** |

So `CUDA_VISIBLE_DEVICES=1` selects the 1660 SUPER. Set
`CUDA_DEVICE_ORDER=PCI_BUS_ID` to make the two agree, or read the
`ggml_cuda_init: Device N: ...` lines in the server log to confirm what you got.

The gap between the cards is large for batched work — the 1660 SUPER has no tensor
cores, so prompt processing collapses:

| `llama-bench`, Qwen3-Embedding-4B Q4_K_M | pp512 | tg64 |
|---|---|---|
| RTX 3060 Ti | **4462 tok/s** | 130 tok/s |
| GTX 1660 SUPER | 264 tok/s | 84 tok/s |

### Embeddings: GPU or CPU?

The GPU is not required, but it is worth ~2.6x on batched work. Qwen3-Embedding-4B
Q4_K_M, 300-token documents:

| batch | CPU (`ngl=0`) | RTX 3060 Ti (`ngl=99`) |
|---|---|---|
| 1 | 722 tok/s (460 ms/doc) | 1243 tok/s (267 ms/doc) |
| 8 | 1644 tok/s (202 ms/doc) | 3436 tok/s (97 ms/doc) |
| 32 | 2170 tok/s (153 ms/doc) | **5711 tok/s (58 ms/doc)** |

CPU is entirely usable for interactive query embedding (one short text, ~0.1-0.5 s).
Prefer the GPU for bulk reindexing. The `[embedding]` preset ships with `ngl = 0` so
it can stay resident alongside Bonsai; raise it when the VRAM is free.

### Single-GPU (RTX 3060 Ti only) — re-measured

An earlier note here claimed the model does not fit on the 3060 Ti alone. That
measurement was wrong: it used `CUDA_VISIBLE_DEVICES=1`, which is the 1660 SUPER
(see the device-order section above). Corrected, with 7108 MiB free on the card
(fukurou-server + ComfyUI hold ~732 MiB):

| build | KV | vision | max ctx that fits | prompt | generation |
|---|---|---|---|---|---|
| PQ2_0 (6.8 GB) | f16 | no | 1024 | 171 tok/s | **40.7 tok/s** |
| PQ2_0 | q8_0 | no | 2048 | 169 tok/s | 40.3 tok/s |
| PTQ1_0 (5.6 GB) | f16 | no | 16384 | 106 tok/s | 33.8 tok/s |
| PTQ1_0 | q8_0 | no | **32768** | 116 tok/s | 33.6 tok/s |
| PTQ1_0 | q8_0 | **yes** | 8192 | 114 tok/s | 33.5 tok/s |

Both fit. Dropping the 1660 SUPER is a large win — the two-GPU split runs Bonsai at
26.5 tok/s generation and ~46 tok/s prompt, so a single 3060 Ti is **1.3-1.5x faster
at generation and 2.5-3.7x faster at prompt processing**, because no layers land on
the tensor-core-less Turing card.

PQ2_0 is the faster packing (40.7 vs 33.8 tok/s — PTQ1_0 trades unpacking arithmetic
for size, as the model card says) but leaves almost no room for KV: 1 GB less weight
buys PTQ1_0 16x the context. **For this host, `PTQ1_0` on the 3060 Ti alone with
`-ctk q8_0 -ctv q8_0` is the best single-model configuration** — full 32K context at
33.6 tok/s, with the 1660 SUPER left free for something else.

## Current layout (after switching to PTQ1_0)

`models.ini` now pins each model to a card by name (`llama-server --list-devices`),
which avoids the `CUDA_VISIBLE_DEVICES` ordering trap entirely:

| preset | weights | device | ctx | notes |
|---|---|---|---|---|
| `bonsai` | PTQ1_0 | CUDA0 (3060 Ti) | 16384 | default; 33.7 tok/s |
| `bonsai-vision` | PTQ1_0 + mmproj | CUDA0 | 8192 | vision/video |
| `bonsai-fast` | PQ2_0 | CUDA0 | 2048 | 41.7 tok/s, short prompts |
| `embedding` | Qwen3-Embedding-4B | CUDA1 (1660 SUPER) | 8192 | stays resident |
| `gemma4` | gemma-4-12B-it Q4_0 | both | 16384 | evicts Bonsai |

Verified: `bonsai` and `embedding` coexist on separate cards — 3060 Ti 7330 MiB,
1660 SUPER 3931 MiB.

Two things that cost a debugging round and are worth keeping in the presets:

- **`np = 1`.** `llama-server` defaults to 4 parallel slots and allocates the
  recurrent-state cache per slot, so it needs far more VRAM than `llama-cli` for the
  same context. Without this, `bonsai` OOMs at 598 MiB while `llama-cli` runs fine.
- **`c = 16384`, not 32768.** At 32K Bonsai fills the 3060 Ti to 7819/7839 MiB, and
  the next process cannot even create a CUDA context — ggml initializes a context on
  every visible device, so the `embedding` child fails at startup even though it only
  targets CUDA1. 16K leaves ~500 MiB and both fit. Use 32K with `BONSAI_MAX=1`.

## Testing from the CLI

```bash
# 1. one-shot, no server
nix run .#bonsai -- --single-turn -n 128 -p "Explain ternary quantization briefly."

# 2. interactive chat
nix run .#bonsai

# 3. against the router (start it first: nix run .#bonsai-router)
curl -s localhost:8888/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"bonsai","messages":[{"role":"user","content":"hello"}],"max_tokens":200}' \
  | jq -r '.choices[0].message.content, .timings.predicted_per_second'

# 4. tool-calling suites
nix shell nixpkgs#python3 --command python3 scripts/test-tools.py
nix shell nixpkgs#python3 --command python3 scripts/test-tools-hard.py

# 5. raw throughput
nix run .#bench -- -m models/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-PTQ1_0.gguf \
  -p 512 -n 128 -ngl 99 --device CUDA0
```

Overrides for the `bonsai` CLI: `BONSAI_QUANT` (PTQ1_0/PQ2_0), `BONSAI_DEVICE`
(`CUDA0`, `CUDA1`, `CUDA0,CUDA1`), `BONSAI_KV` (q8_0/f16), `BONSAI_CTX`,
`BONSAI_MMPROJ=0`.

### Why the *larger* PQ2_0 is the faster one

Measured at identical settings (CUDA0, `-c 2048`, KV `q8_0`, 128 tokens generated):

| packing | file | reported | prompt | generation |
|---|---|---|---|---|
| PTQ1_0 | 5.53 GiB | 1.75 bpw ternary (group 128) | 130.1 tok/s | 33.6 tok/s |
| PQ2_0 | 6.71 GiB | 2.13 bpw (group 128) | **187.4 tok/s** | **41.7 tok/s** |

So the earlier 40.7-vs-33.7 gap was not a context-length artifact: PQ2_0 is genuinely
+24% on generation and +44% on prompt while being 1.2 GB *bigger*.

Single-batch generation is normally memory-bandwidth-bound, so the smaller file should
win — if bandwidth were the limit, PTQ1_0 would be 6.71/5.53 = **1.21x faster**.
It is instead 0.81x, a factor of ~1.5 in the wrong direction. That gap is the
dequantization cost:

- **PTQ1_0** is a *dense* ternary packing — 5 trits per byte (3^5 = 243 fits in 256),
  giving 8/5 = 1.6 bits/weight plus group scales. Recovering a weight needs
  divide/modulo-by-3 style arithmetic, which is serial and ALU-heavy.
- **PQ2_0** gives each trit its own 2-bit slot, so unpacking is a shift and a mask.
  The model card calls this out directly: PQ2_0 "trades some size for cheaper
  unpacking arithmetic."

In other words this model is **dequant-bound, not bandwidth-bound**, on this GPU.

Practical consequence: PTQ1_0's 1.2 GB saving buys context, not speed. On the 3060 Ti
alone that is still the right trade (16K context at 33.6 tok/s vs 2K at 41.7), but if
a workload fits in ~2K, `bonsai-fast` is free performance.

## Maximum context on both GPUs

13.6 GB total (3060 Ti 7839 + 1660 SUPER 5749), minus ~610 MB held by fukurou-server
and ComfyUI. `--device CUDA0,CUDA1 --split-mode layer`, sweep via
`scripts/ctx-sweep.sh <quant> <kv> <devices> [--mmproj]`.

| packing | KV | vision | max ctx that loads | prompt | generation |
|---|---|---|---|---|---|
| PTQ1_0 | q8_0 | no | **147456 (144K)** | 44.3 tok/s | 20.1 tok/s |
| PTQ1_0 | q8_0 | yes | 131072 (128K) | 43.1 tok/s | 20.5 tok/s |
| PTQ1_0 | f16 | no | 98304 (96K) | 44.6 tok/s | 20.3 tok/s |
| PQ2_0 | q8_0 | no | 98304 (96K) | 57.2 tok/s | 26.4 tok/s |
| PQ2_0 | f16 | no | 65536 (64K) | 57.2 tok/s | 26.5 tok/s |

155648 fails, so the GPU-resident ceiling sits between 144K and 152K.

### Reaching the model's full 262144

The model advertises a 262K trained context, which does not fit in 13.6 GB of VRAM —
but `-nkvo` (`--no-kv-offload`) keeps the KV cache in system RAM and gets there:

| config | ctx | prompt | generation |
|---|---|---|---|
| PTQ1_0, q8_0, `-nkvo` | **262144 (256K)** | 34.2 tok/s | **8.0 tok/s** |

So full context costs 2.5x on generation (20.1 → 8.0 tok/s). Worth it only when the
prompt genuinely needs more than 144K.

### The trade against a single card

| config | ctx | generation |
|---|---|---|
| 3060 Ti alone, PTQ1_0, q8_0 | 32768 | **33.6 tok/s** |
| both cards, PTQ1_0, q8_0 | 147456 | 20.1 tok/s |
| both cards, PTQ1_0, q8_0, `-nkvo` | 262144 | 8.0 tok/s |

Adding the 1660 SUPER buys 4.5x the context for 40% of the generation speed — it has
no tensor cores, so every layer placed on it drags the whole pipeline. Note PQ2_0
stays the faster packing on two cards too (26.4 vs 20.1 tok/s), for 2/3 the context.

### Single-card ceiling (answer: 32768, and the current 16384 is deliberate)

Swept on CUDA0 alone, PTQ1_0 + `q8_0` KV:

| ctx | result |
|---|---|
| 40960 / 36864 | OOM |
| **32768** | OK — 123.9 tok/s prompt, 33.4 tok/s generation |

So 32K is the hard ceiling for one 3060 Ti. The `[bonsai]` preset runs at **16384 on
purpose**, not because 32K fails: at 32K Bonsai fills the card to 7819/7839 MiB and
the `[embedding]` child cannot even create a CUDA context. 16K leaves ~500 MiB so both
stay resident. Use 32K with `BONSAI_MAX=1`.

One card can go further with the KV cache in RAM, though two cards still win on
throughput at long context:

| config | ctx | prompt | generation |
|---|---|---|---|
| CUDA0, GPU KV | 32768 | 123.9 tok/s | 33.4 tok/s |
| CUDA0, `-nkvo` | 131072 | 81.8 tok/s | 16.3 tok/s |
| CUDA0+CUDA1, GPU KV | 147456 | 44.3 tok/s | 20.1 tok/s |
| CUDA0+CUDA1, `-nkvo` | 262144 | 34.2 tok/s | 8.0 tok/s |

Two new presets, both verified through the router:

| preset | ctx | measured |
|---|---|---|
| `bonsai-long` | 147456 | 20.4 tok/s |
| `bonsai-max` | 262144 | 8.2 tok/s |

Both fill the GPUs, so run them with `BONSAI_MAX=1` — `[embedding]` cannot coexist.

## Using llama-cli as a client of the router

`llama-cli --server-base URL` skips loading a model into its own process and talks to
a running server over HTTP instead — so the CLI, the web UI and any API client all
share one loaded model.

```bash
nix run .#bonsai-router          # terminal 1
nix run .#bonsai-chat            # terminal 2 — picker over the router's models
nix run .#bonsai-chat -- bonsai-long --single-turn -p "..."
```

The wrapper exists because **`llama-cli` has no flag to preselect a model**: against a
router with more than one entry it always stops at `Select model by number:` and reads
stdin. (Auto-select only happens when the server exposes exactly one model.) A bare
`llama-cli --server-base ... -p ...` therefore appears to hang — it is waiting at that
prompt. `bonsai-chat` resolves a model *name* to its index and answers the prompt.

Verified through the router: `bonsai` 33.8 tok/s, `bonsai-fast` 41.9 tok/s — the same
numbers as running the model locally, so the HTTP hop costs nothing measurable.

`BONSAI_URL` overrides the endpoint. Everything after the model name is passed to
`llama-cli` unchanged.

## Port

Everything listens on **8888** by default, not 8080: this host already runs Open WebUI
on 8080 (`modules/ollama.nix`, `ports.openWebui`). Override with `BONSAI_PORT`
(server/router) or `BONSAI_URL` (the `bonsai-chat` client).

## JSON-schema constrained output: one form silently does nothing

Reproduced independently by two sessions against the router (`gemma4`, flat schema with
`enum` + `required`, temperature 0.4, `max_tokens` 1200, 3 runs each):

| `response_format` | result |
|---|---|
| `{"type":"json_schema","schema":{…}}` | **schema silently ignored** |
| `{"type":"json_schema","json_schema":{"name":"v","schema":{…}}}` | correct, 3/3 |
| `{"type":"json_object","schema":{…}}` | correct, 3/3 |

The flattened form returns HTTP 200, `finish_reason: "stop"`, and syntactically valid
JSON — with invented keys that differ run to run:

```
A#1 ["status","urgency_level"]          B#1 ["message","urgency"]
A#2 ["status","urgency_score","verdict"] B#2 ["message","urgency"]
A#3 ["reasoning","status","urgency_level"] B#3 ["message","urgency"]
```

That is worse than an error: it passes a smoke test and violates the schema in
production. Note the fork's own `tools/server/README.md:1310` shows the flattened form
as an example — for `type: json_schema` it does not constrain. **Use the full OpenAI
form** (`json_schema: {name, schema}`).

### Porting an Ollama `/api/chat` caller

| Ollama | llama.cpp `/v1/chat/completions` |
|---|---|
| `format: {schema}` | `response_format: {type:"json_schema", json_schema:{name, schema}}` |
| `options.temperature` | top-level `temperature` |
| `options.num_ctx` | no per-request equivalent — fixed per preset (`c` in models.ini) |
| `think: false` | n/a; reasoning always returns separately in `reasoning_content` |
| `model: "gemma4:12b"` | `model: "gemma4"` (preset name) |
| `message.content` | `choices[0].message.content` |

Two failure modes worth guarding: `content` comes back as an **empty string** when
`max_tokens` is consumed by reasoning (`finish_reason: "length"`, `reasoning_content`
populated) — it returns fast and looks like success; and set `max_tokens` explicitly,
since at 300 this model emitted only reasoning while 1200 completed.
