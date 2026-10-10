# Open WebUI

Implementation: [`modules/ollama.nix`](../../modules/ollama.nix) (`services.open-webui`)

## What it is

Browser chat UI and account management in front of the local LLM backend. Ollama itself has no
authentication, so all end-user access is meant to go through here instead.

## Package

`pkgs.unstable.open-webui` (unstable is 0.11.0 vs. 25.05's 0.6.9). Tracking unstable keeps it in
step with the ollama version and its API surface. No overlay is needed — `services.open-webui`
exposes a `package` option directly.

- 0.11.0 is non-free (Open WebUI License, changed from 0.6.x's MIT). Allowed via
  `nixpkgs.config.allowUnfreePredicate` in `modules/unfree.nix` (the only place that predicate can
  be defined).
- The 25.05 NixOS module is still used — only the package is swapped. The unstable module moves
  `DATA_DIR` from `"."` to `"${stateDir}/data"` with a migration `preStart`; that migration does
  **not** run here, so data stays directly under `StateDirectory` as it always has. Don't
  partially imitate the unstable module's layout.
- Upgrading from 0.6.9 runs alembic migrations 16 → 55 automatically on first start, with no
  downgrade path. Reverting the package alone won't roll the schema back — that needs restoring
  the `rpool/var/lib` ZFS snapshot.

## Required absolute paths (`STATIC_DIR`, `DATA_DIR`, `HF_HOME`, `SENTENCE_TRANSFORMERS_HOME`)

**Without these, 0.11.0 fails to start.** The 25.05 module passes these four as relative (`"."`),
which open-webui has been unable to handle correctly since 0.6.18. Symptom actually seen on this
host: `sqlite3.OperationalError: no such table: config` at startup — all 55 alembic migrations
succeed, but the app opens a different, empty DB (with existing data present, this instead
presents as "please create an account"; same as nixpkgs issue #430433).

nixpkgs PR #431395 fixed this upstream by making the module use absolute paths, but that fix isn't
in 25.05. Overriding here works because `cfg.environment` is applied with `// cfg.environment`
(caller wins), so the module doesn't need patching. Values match the unstable module.

`stateDir` is `/var/lib/open-webui`; because of `DynamicUser`, the real storage is
`/var/lib/private/open-webui` (resolved via symlink — same pattern as VictoriaMetrics, see
`disko/default.nix`).

## Ollama / RAG connection settings — mostly not effective here

`OLLAMA_BASE_URL` and `RAG_EMBEDDING_ENGINE`/`RAG_EMBEDDING_MODEL` in this file are
**PersistentConfig seeds only** — Open WebUI copies environment variables into its DB on first
boot, and the DB (edited via Admin Panel) wins from then on. On this host the DB already exists,
so these values are **not** the live configuration; check Admin Panel → Settings →
Connections/Documents instead. Full detail, including why `RAG_EMBEDDING_ENGINE` pointed at a
dead ollama for two days without erroring, is in
[the ollama → llama.cpp migration decision](../decisions/2026-09-23-ollama-to-llama-cpp.md).

There is also a hand-edited Open WebUI Admin Panel → Functions "Pipe" that calls ollama directly
and is not deployable from this repo at all — see the same decision doc.

## MiniMax-H3 video pipe

Open WebUI has no video generation engine (0.11.3 knows openai / gemini / comfyui /
automatic1111 for images only). Video comes from a Pipe function whose source is tracked in
`scripts/open-webui-minimax-h3-pipe.py`; like the Pipe above it lives in Open WebUI's DB, so
**after editing the file, paste it again** into Admin Panel → Functions (the `+` button, or the
existing function's editor) and keep the function enabled. Its name becomes the model name in
the model picker.

- Calls llama-swap's blocking `POST /upstream/minimax-h3/sync/vid_gen`
  ([llama-cpp.md](llama-cpp.md#calling-minimax-h3)); 6-11 min per clip, bonsai requests queue
  meanwhile.
- Resolution (landscape, Shorts/Reels 9:16, 4:5, 1:1, 4:3, 3:4), fps and frame count are per-user
  dropdowns under Chat Controls → Valves. Every preset stays within the measured 864x480 x 56
  frames; add larger ones only after measuring VRAM.
- The WebM is stored as an Open WebUI file and returned as a block-level `<video>` whose text is
  the file URL — the only form 0.11.3's `HTMLToken.svelte` renders (its own
  `{{VIDEO_FILE_ID_<id>}}` placeholder expands to `<video src=…>` and shows up as raw text).
- Title/tag/follow-up tasks routed to this model return an empty string instead of starting a
  job.

## Bonsai Image pipe

Text-to-image through llama-swap's `bonsai-image` ([llama-cpp.md](llama-cpp.md#calling-bonsai-image)),
as a Pipe function whose source is tracked in `scripts/open-webui-bonsai-image-pipe.py`. Same
deployment as the video pipe: **paste the file into** Admin Panel → Functions (`+`) and keep the
function enabled; **after editing the file, paste it again**. Its title (`Bonsai Image`) becomes the
model name in the model picker.

- Calls `POST http://127.0.0.1:8888/v1/images/generations` with `"model": "bonsai-image"`. The
  `Content-Type: application/json` header matters: without it llama-swap answers
  `no model id could be identified`.
- Resolution (1:1, 16:9, 3:2, 4:3 and their portrait forms; sides ≤ 1024, multiples of 32) and `seed`
  (-1 = random) are per-user under Chat Controls → Valves. Only 1024x1024 was measured on the card
  (7812 MiB of 8192); the other presets have fewer pixels. Add larger ones only after measuring.
- The PNG is stored as an Open WebUI file and returned as a markdown image with the file URL,
  plus the size and the seed that was used (so a random result can be reproduced).
- Title/tag/follow-up tasks routed to this model return an empty string, so they never load the
  image model (which would evict bonsai).
- Time: ~10 s warm; after a swap ~95-115 s (weights load + Triton compile). A new resolution pays
  a Triton compile once (512x512 took 14 s on the first request, measured 2026-10-10 against the
  real endpoint with `open_webui.*` stubbed; a real in-chat run is not yet verified).
- Not needed for the same job: Open WebUI's built-in image generation (Admin Panel → Settings →
  Images, engine OpenAI, base URL `http://127.0.0.1:8888/v1`, model `bonsai-image`) also fits this
  endpoint, but it has no per-user seed or resolution presets and no guard against the 1024 ceiling.

## Auth and telemetry

- `WEBUI_AUTH = "True"` — without it, anyone on the tailnet gets in with no login.
- `ANONYMIZED_TELEMETRY` / `DO_NOT_TRACK` / `SCARF_NO_ANALYTICS` all disabled — closed host, no
  reason to phone home.

## Network

Listens on `0.0.0.0:8080`, opened only via Tailscale Serve
(`modules/reverse-proxy.nix`) — not opened directly in this module's firewall block (that block
only opens ollama's 11434). Open WebUI must be served at the Serve root, not a sub-path: 0.6.9's
`open_webui/main.py` FastAPI app has no `root_path` support.

## Ops notes

- `systemctl status open-webui`
- State: `/var/lib/open-webui` → `/var/lib/private/open-webui` (DynamicUser). Contains chat
  history and the user DB, so unlike ollama's model storage, this **is** covered by the
  `rpool/var/lib` ZFS snapshot/syncoid backup schedule (`modules/replication.nix`).
