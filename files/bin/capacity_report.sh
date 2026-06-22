#!/usr/bin/env bash
# Report vLLM's ACHIEVED concurrency vs what you asked for.
#
# After the pod boots, vLLM logs a line like:
#   Maximum concurrency for 16384 tokens per request: 7.43x
# That "x" is how many full-context requests actually fit the KV cache on this
# GPU — the real ceiling, regardless of MAX_NUM_SEQS. This compares it to the
# MAX_NUM_SEQS you configured so you know whether the GPU meets your user target.
set -euo pipefail

ENV_FILE=/workspace/envs/vllm.env
LOG=/workspace/vllm/logs/vllm.log
ERRLOG=/workspace/vllm/logs/vllm.err.log

[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE — run setup.sh first." >&2; exit 1; }

req_seqs=$(grep -E '^MAX_NUM_SEQS=' "$ENV_FILE" | head -1 | cut -d= -f2)
max_len=$(grep -E '^MAX_LEN=' "$ENV_FILE" | head -1 | cut -d= -f2)
req_seqs=${req_seqs:-1}
max_len=${max_len:-?}

# vLLM prints the line to stdout or stderr depending on version; check both.
line=$(grep -hoE "Maximum concurrency for [0-9]+ tokens per request: [0-9.]+x" \
  "$LOG" "$ERRLOG" 2>/dev/null | tail -1 || true)

echo "Requested: MAX_NUM_SEQS=$req_seqs at MAX_LEN=$max_len"
if [ -z "$line" ]; then
  echo "Achieved:  not found yet — vLLM may still be loading."
  echo "           Re-run once 'supervisorctl status' shows vllm RUNNING, or check:"
  echo "           tail -f $ERRLOG"
  exit 0
fi

achieved=$(echo "$line" | grep -oE '[0-9.]+x$' | tr -d x)
echo "Achieved:  $line"

# Floor the achieved float for the comparison.
achieved_int=${achieved%.*}
achieved_int=${achieved_int:-0}
if [ "$achieved_int" -ge "$req_seqs" ]; then
  echo "Verdict:   OK — the GPU fits your requested $req_seqs parallel users at $max_len ctx."
else
  echo "Verdict:   UNDER TARGET — GPU fits ~${achieved_int}, you asked for $req_seqs."
  echo "           Options: lower MAX_LEN (frees KV for more users), lower MAX_NUM_SEQS"
  echo "           to match, or add another pod. Past capacity vLLM queues (no errors),"
  echo "           just slower. Edit /workspace/envs/vllm.env then: supervisorctl restart vllm"
fi
