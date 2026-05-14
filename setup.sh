#!/usr/bin/env bash
# Bootstrap a fresh Runpod pod for serving vLLM behind Traefik via supervisord.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES="$REPO_DIR/files"

WORKSPACE=/workspace
VENV=$WORKSPACE/envs/vllm
CP_VENV=$WORKSPACE/envs/control_plane
ENV_FILE=$WORKSPACE/envs/vllm.env
CP_ENV_FILE=$WORKSPACE/envs/control_plane.env
MODELS_YAML=$WORKSPACE/ops/models.yaml
HF_CACHE=$WORKSPACE/hf_cache
TRAEFIK_BIN=$WORKSPACE/bin/traefik

echo "==> apt packages"
apt-get update -qq
apt-get install -y -qq supervisor apache2-utils openssl curl nano git wget htop tmux tar ca-certificates

echo "==> directory layout"
mkdir -p \
  "$WORKSPACE/bin" \
  "$WORKSPACE/envs" \
  "$HF_CACHE" \
  "$WORKSPACE/logs" \
  "$WORKSPACE/ops" \
  "$WORKSPACE/traefik/dynamic" \
  "$WORKSPACE/vllm/.cache" \
  "$WORKSPACE/vllm/logs" \
  "$WORKSPACE/services/control_plane"

echo "==> uv"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
# shellcheck source=/dev/null
source "$HOME/.local/bin/env"
uv --version

echo "==> vllm venv"
if [ ! -d "$VENV" ]; then
  uv venv --python 3.11 "$VENV"
fi
uv pip install --python "$VENV/bin/python" --upgrade vllm "huggingface_hub[cli]"

echo "==> control_plane venv"
if [ ! -d "$CP_VENV" ]; then
  uv venv --python 3.11 "$CP_VENV"
fi
uv pip install --python "$CP_VENV/bin/python" --upgrade \
  -r "$FILES/services/control_plane/requirements.txt"

echo "==> traefik binary"
if [ ! -x "$TRAEFIK_BIN" ]; then
  cd "$WORKSPACE/bin"
  TAG=$(curl -fsSL https://api.github.com/repos/traefik/traefik/releases/latest \
        | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  echo "    fetching traefik $TAG"
  curl -fL -o traefik.tar.gz \
    "https://github.com/traefik/traefik/releases/download/${TAG}/traefik_${TAG}_linux_amd64.tar.gz"
  tar -xzf traefik.tar.gz traefik
  chmod +x traefik
  rm traefik.tar.gz
  cd - >/dev/null
fi
"$TRAEFIK_BIN" version

echo "==> copy configs into /workspace"
install -m 0755 "$FILES/bin/run_vllm.sh"           "$WORKSPACE/bin/run_vllm.sh"
install -m 0755 "$FILES/bin/run_control_plane.sh"  "$WORKSPACE/bin/run_control_plane.sh"
install -m 0755 "$FILES/bin/bootstrap.sh"          "$WORKSPACE/bin/bootstrap.sh"
install -m 0644 "$FILES/ops/supervisord.conf"            "$WORKSPACE/ops/supervisord.conf"
install -m 0644 "$FILES/traefik/traefik.yml"             "$WORKSPACE/traefik/traefik.yml"
install -m 0644 "$FILES/traefik/dynamic/vllm.yml"        "$WORKSPACE/traefik/dynamic/vllm.yml"
install -m 0644 "$FILES/traefik/dynamic/control_plane.yml" "$WORKSPACE/traefik/dynamic/control_plane.yml"
install -m 0644 "$FILES/services/control_plane/app.py"   "$WORKSPACE/services/control_plane/app.py"
install -m 0644 "$FILES/services/control_plane/requirements.txt" \
                                                         "$WORKSPACE/services/control_plane/requirements.txt"

if [ ! -f "$ENV_FILE" ]; then
  install -m 0600 "$FILES/envs/vllm.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE — EDIT IT (MODEL + VLLM_API_KEY)."
fi
if [ ! -f "$CP_ENV_FILE" ]; then
  install -m 0600 "$FILES/envs/control_plane.env.example" "$CP_ENV_FILE"
  echo "Created $CP_ENV_FILE (defaults are fine; edit only if you change ports/prefix)."
fi
if [ ! -f "$MODELS_YAML" ]; then
  install -m 0644 "$FILES/ops/models.yaml.example" "$MODELS_YAML"
  echo "Created $MODELS_YAML — edit to curate the model registry."
fi

USERS_FILE=$WORKSPACE/traefik/users.htpasswd
GENERATED_PW=""
if [ ! -f "$USERS_FILE" ]; then
  GENERATED_PW=$(openssl rand -base64 18)
  htpasswd -B -b -c "$USERS_FILE" admin "$GENERATED_PW" >/dev/null
  chmod 600 "$USERS_FILE"
fi

echo "==> bashrc convenience"
add_line() { grep -qxF "$1" ~/.bashrc || echo "$1" >> ~/.bashrc; }
add_line 'source $HOME/.local/bin/env'
add_line "alias supervisorctl='supervisorctl -c $WORKSPACE/ops/supervisord.conf'"
add_line "export HF_HOME=$HF_CACHE"

echo
echo "Setup complete."
echo

if [ -n "$GENERATED_PW" ]; then
  echo "============================================================"
  echo "  Basic Auth credentials for /admin/* (Traefik)"
  echo "    Username: admin"
  echo "    Password: $GENERATED_PW"
  echo "  SAVE THIS NOW — it will not be shown again."
  echo "  Change later with: htpasswd -B $USERS_FILE admin"
  echo "  Add more users with: htpasswd -B $USERS_FILE <name>"
  echo "============================================================"
  echo
fi

echo "Next:"
echo "  1. nano $ENV_FILE                  # set MODEL + VLLM_API_KEY"
echo "  2. (optional) nano $MODELS_YAML    # curate model registry"
echo "  3. (gated models only) hf auth login"
echo "  4. $WORKSPACE/bin/bootstrap.sh     # start everything"
echo "  5. supervisorctl status"
