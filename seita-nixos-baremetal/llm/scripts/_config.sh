# Shared model configuration, sourced by the other scripts.
#
# Bonsai 2 is the default: its PTQ1_0 / PQ2_0 packings are exactly the ones that
# mainline llama.cpp cannot decode, so they require the PrismML fork this flake pins.
#
#   BONSAI_MODEL=Ternary-Bonsai-2-27B   (default) | Ternary-Bonsai-27B | Bonsai-27B
#   BONSAI_QUANT=PTQ1_0                 (default) | PQ2_0 | Q1_0
#   BONSAI_MMPROJ=1                     (default) | 0 to skip the vision projector
#   BONSAI_DEVICE=CUDA0                 (default) 3060 Ti; CUDA1 is the 1660 SUPER,
#                                       "CUDA0,CUDA1" splits across both
#   BONSAI_KV=q8_0                      (default) | f16
#   BONSAI_CTX=32768                    (default) — drops to 8192 if MMPROJ=1
BONSAI_MODEL="${BONSAI_MODEL:-Ternary-Bonsai-2-27B}"
BONSAI_QUANT="${BONSAI_QUANT:-PTQ1_0}"
BONSAI_REPO="${BONSAI_REPO:-prism-ml/${BONSAI_MODEL}-gguf}"

model_dir="${BONSAI_MODEL_DIR:-/var/lib/llm-models}/${BONSAI_MODEL}-gguf"
model_file="${BONSAI_MODEL}-${BONSAI_QUANT}.gguf"
mmproj_file="${BONSAI_MODEL}-mmproj-Q8_0.gguf"

# The projector costs ~600 MB, which on a single 3060 Ti trades away context.
if [ "${BONSAI_MMPROJ:-1}" = "1" ]; then
  default_ctx=8192
else
  default_ctx=32768
fi
