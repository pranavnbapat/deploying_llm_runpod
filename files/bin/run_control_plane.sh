#!/usr/bin/env bash
# Wrapper for the FastAPI control plane, called by supervisord.
set -euo pipefail

ENV_FILE=/workspace/envs/control_plane.env
APP_DIR=/workspace/services/control_plane

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# Venv location is written into control_plane.env by setup.sh (CONTROL_PLANE_VENV);
# it may live on local disk, wiped on a cold restart. Fall back to the legacy default.
VENV="${CONTROL_PLANE_VENV:-/workspace/envs/control_plane}"
if [ ! -d "$VENV" ]; then
    echo "Missing venv at $VENV — run setup.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

cd "$APP_DIR"

exec uvicorn app:app \
    --host 127.0.0.1 \
    --port "${CONTROL_PLANE_PORT:-8002}" \
    --root-path "${CONTROL_PLANE_ROOT_PATH:-/admin}" \
    --no-access-log
