#!/usr/bin/env bash
# Download a Bonsai GGUF weight set into $BONSAI_MODEL_DIR (default ./models).
# See scripts/_config.sh for the BONSAI_MODEL / BONSAI_QUANT knobs.
#
# Plain curl with resume (-C -): the repos are public, so no HF auth or CLI is needed.
set -euo pipefail
. "$(dirname "$0")/_config.sh"

files=("$model_file")
if [ "${BONSAI_MMPROJ:-1}" = "1" ]; then files+=("$mmproj_file"); fi

mkdir -p "$model_dir"
for f in "${files[@]}"; do
  echo ">>> $BONSAI_REPO / $f"
  curl -fL -C - --progress-bar --retry 5 --retry-delay 5 \
    -o "$model_dir/$f" \
    "https://huggingface.co/$BONSAI_REPO/resolve/main/$f?download=true"
done

echo
ls -lh "$model_dir"
