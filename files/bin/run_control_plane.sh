#!/usr/bin/env bash
# Wrapper for the FastAPI control plane, called by supervisord.
set -euo pipefail

ENV_FILE=/workspace/envs/control_plane.env
VENV=/workspace/envs/control_plane
APP_DIR=/workspace/services/control_plane

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

cd "$APP_DIR"

exec uvicorn app:app \
    --host 127.0.0.1 \
    --port "${CONTROL_PLANE_PORT:-8002}" \
    --root-path "${CONTROL_PLANE_ROOT_PATH:-/admin}" \
    --no-access-log
