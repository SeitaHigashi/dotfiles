#!/usr/bin/env bash
# OpenAI-compatible server + web UI.
#
# The weights are ~6-7 GB, which does not leave room for the KV cache on the 8 GB
# RTX 3060 Ti alone, so layers are split across both GPUs by default. Override with
# CUDA_VISIBLE_DEVICES.
set -euo pipefail
. "$(dirname "$0")/_config.sh"

mmproj_args=()
if [ "${BONSAI_MMPROJ:-1}" = "1" ]; then mmproj_args=(--mmproj "$model_dir/$mmproj_file"); fi

[ -f "$model_dir/$model_file" ] || {
  echo "missing $model_dir/$model_file — run ./scripts/download-model.sh" >&2; exit 1; }

exec llama-server \
  -m "$model_dir/$model_file" \
  "${mmproj_args[@]}" \
  --jinja \
  -c "${BONSAI_CTX:-$default_ctx}" \
  -ngl 99 \
  --device "${BONSAI_DEVICE:-CUDA0}" \
  -ctk "${BONSAI_KV:-q8_0}" -ctv "${BONSAI_KV:-q8_0}" \
  --temp 0.5 --top-p 0.85 --top-k 20 --min-p 0 \
  --host 127.0.0.1 --port "${BONSAI_PORT:-8888}" \
  "$@"
