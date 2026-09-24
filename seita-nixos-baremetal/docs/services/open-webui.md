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
