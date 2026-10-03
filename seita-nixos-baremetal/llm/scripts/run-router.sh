#!/usr/bin/env bash
# Router mode: one endpoint, many models, loaded on demand — the `ollama serve`
# equivalent. Models and their per-model flags come from models.ini.
#
#   BONSAI_PRESET   path to the preset INI (default ./models.ini)
#   BONSAI_MAX      max models resident at once (default 2; 0 = unlimited)
#   BONSAI_PORT     listen port (default 8888 — 8080 is Open WebUI on this host)
#
# Request routing is by the "model" field, e.g. {"model": "bonsai", ...} or
# {"model": "embedding", ...}. Unknown-but-configured models autoload.
set -euo pipefail

preset="${BONSAI_PRESET:-$PWD/models.ini}"
[ -f "$preset" ] || { echo "missing preset $preset" >&2; exit 1; }

exec llama-server \
  --models-preset "$preset" \
  --models-max "${BONSAI_MAX:-2}" \
  --host 127.0.0.1 --port "${BONSAI_PORT:-8888}" \
  "$@"
