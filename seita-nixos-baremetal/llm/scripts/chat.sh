#!/usr/bin/env bash
# Interactive chat against a running router (nix run .#bonsai-router), instead of
# loading a model into this process. `llama-cli --server-base` is a thin HTTP client.
#
#   ./scripts/chat.sh                # shows the router's model picker
#   ./scripts/chat.sh bonsai-long    # preselects that model
#
# llama-cli has no flag to preselect a model — with more than one model it always
# asks "Select model by number". This resolves the name to its index and answers
# that prompt for you.
set -euo pipefail

url="${BONSAI_URL:-http://127.0.0.1:8888}"
want=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  want="$1"
  shift
fi

curl -sf "$url/v1/models" >/dev/null 2>&1 || {
  echo "no router at $url — start it with: nix run .#bonsai-router" >&2
  exit 1
}

if [ -z "$want" ]; then
  exec llama-cli --server-base "$url" "$@"
fi

idx=$(curl -s "$url/v1/models" \
      | tr '{' '\n' | grep -o '"id":"[^"]*"' | sed 's/.*:"//;s/"$//' \
      | grep -nxF "$want" | cut -d: -f1) || true

if [ -z "${idx:-}" ]; then
  echo "unknown model: $want" >&2
  echo "available:" >&2
  curl -s "$url/v1/models" | tr '{' '\n' | grep -o '"id":"[^"]*"' \
    | sed 's/.*:"//;s/"$//;s/^/  /' >&2
  exit 1
fi

printf '%s\n' "$idx" | llama-cli --server-base "$url" "$@"
