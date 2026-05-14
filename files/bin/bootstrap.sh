#!/usr/bin/env bash
# Bring supervisord up after a pod restart (or first time).
# Idempotent — does nothing if supervisord is already running.
set -euo pipefail

SUPCONF=/workspace/ops/supervisord.conf

if pgrep -x supervisord >/dev/null; then
    echo "supervisord already running."
else
    supervisord -c "$SUPCONF"
    echo "supervisord started."
fi

sleep 1
supervisorctl -c "$SUPCONF" status
