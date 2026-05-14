#!/usr/bin/env bash
# Switch vLLM to a different model.
# Edits /workspace/envs/vllm.env in-place and restarts the supervisor program.
#
# Usage:
#   ./switch_model.sh <model-id> [max-model-len]
#
# Example:
#   ./switch_model.sh Qwen/Qwen2.5-7B-Instruct 16384
set -euo pipefail

ENV_FILE=/workspace/envs/vllm.env
SUPCONF=/workspace/ops/supervisord.conf

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <model-id> [max-model-len]"
    exit 1
fi

MODEL="$1"
MAX_LEN="${2:-}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE — run ./setup.sh first."
    exit 1
fi

# Escape | for sed (model ids contain /).
sed -i "s|^MODEL=.*|MODEL=$MODEL|" "$ENV_FILE"
if [ -n "$MAX_LEN" ]; then
    sed -i "s|^MAX_LEN=.*|MAX_LEN=$MAX_LEN|" "$ENV_FILE"
fi

echo "Updated $ENV_FILE:"
grep -E '^(MODEL|MAX_LEN|SERVED_MODEL_NAME)=' "$ENV_FILE"
echo

supervisorctl -c "$SUPCONF" restart vllm
supervisorctl -c "$SUPCONF" status vllm

echo
echo "Tail logs with: supervisorctl -c $SUPCONF tail -f vllm"
