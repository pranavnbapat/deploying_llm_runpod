#!/usr/bin/env bash
# Wrapper for vLLM, called by supervisord.
# Sources /workspace/envs/vllm.env, activates the venv, execs `vllm serve`.
#
# Run standalone for debugging:
#   /workspace/bin/run_vllm.sh
set -euo pipefail

ENV_FILE=/workspace/envs/vllm.env

if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Venv location is written into vllm.env by setup.sh (VLLM_VENV). It may live on
# local disk rather than /workspace — in which case a cold pod restart wipes it
# and setup.sh must be re-run. Fall back to the legacy default for old env files.
VENV="${VLLM_VENV:-/workspace/envs/vllm}"
if [ ! -d "$VENV" ]; then
    echo "Missing venv at $VENV — run setup.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

export HF_HOME="${HF_HOME:-/workspace/hf_cache}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
export VLLM_CACHE_DIR="${VLLM_CACHE_DIR:-/workspace/vllm/.cache}"
export TORCH_HOME="${TORCH_HOME:-/workspace/vllm/.cache/torch}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

: "${MODEL:?MODEL must be set in $ENV_FILE}"
: "${VLLM_API_KEY:?VLLM_API_KEY must be set in $ENV_FILE}"

# shellcheck disable=SC2086  # VLLM_EXTRA_ARGS intentionally word-split
exec vllm serve "$MODEL" \
    --host 127.0.0.1 \
    --port "${VLLM_PORT:-8001}" \
    --served-model-name "${SERVED_MODEL_NAME:-current}" \
    --gpu-memory-utilization "${GPU_UTIL:-0.90}" \
    --max-model-len "${MAX_LEN:-16384}" \
    --max-num-seqs "${MAX_NUM_SEQS:-1}" \
    --api-key "$VLLM_API_KEY" \
    ${VLLM_EXTRA_ARGS:-}
