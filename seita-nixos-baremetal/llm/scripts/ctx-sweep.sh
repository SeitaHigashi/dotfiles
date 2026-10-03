#!/usr/bin/env bash
# Find the largest context that loads, for a given quant / KV type / device set.
#   ./scripts/ctx-sweep.sh PTQ1_0 q8_0 CUDA0,CUDA1 [--mmproj]
set -uo pipefail
cd "$(dirname "$0")/.."
Q="${1:-PTQ1_0}"; KV="${2:-q8_0}"; DEV="${3:-CUDA0,CUDA1}"; MM="${4:-}"
M=models/Ternary-Bonsai-2-27B-gguf
extra=()
[ "$MM" = "--mmproj" ] && extra=(--mmproj "$M/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf")

for c in 262144 196608 131072 98304 65536 49152 32768; do
  out=$(./result-llama/bin/llama-cli -m "$M/Ternary-Bonsai-2-27B-$Q.gguf" \
        "${extra[@]}" -ngl 99 --device "$DEV" --split-mode layer \
        -c "$c" -ctk "$KV" -ctv "$KV" --single-turn -n 32 \
        -p "Count 1 to 20." 2>&1)
  if perf=$(grep -oE 'Prompt: [0-9.]+ t/s \| Generation: [0-9.]+ t/s' <<<"$out"); then
    printf '%-8s %-5s %-12s %-9s ctx=%-7s OK    %s\n' "$Q" "$KV" "$DEV" "${MM:-text}" "$c" "$perf"
    break
  fi
  printf '%-8s %-5s %-12s %-9s ctx=%-7s OOM\n' "$Q" "$KV" "$DEV" "${MM:-text}" "$c"
done
