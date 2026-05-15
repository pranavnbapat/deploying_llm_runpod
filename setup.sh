#!/usr/bin/env bash
# Bootstrap a fresh Runpod pod for serving vLLM behind Traefik via supervisord.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES="$REPO_DIR/files"

# Operator secrets (HF_TOKEN, VLLM_API_KEY) can come from either:
#   - the shell environment (export HF_TOKEN=... before running setup.sh), or
#   - a gitignored .env file next to setup.sh (cp .env.example .env; nano .env)
# Shell environment wins; .env only fills in vars that aren't already set.
if [ -f "$REPO_DIR/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key// /}"
    [ -z "$key" ] && continue
    # Only set if currently unset/empty in the shell env (shell wins).
    if [ -z "${!key:-}" ]; then
      # Strip one pair of surrounding quotes if present.
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
      export "$key=$val"
    fi
  done < "$REPO_DIR/.env"
fi

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
# uv installs into ~/.local/bin. Older installers wrote a `~/.local/bin/env`
# script to source; newer ones don't. Just put the dir on PATH directly.
export PATH="$HOME/.local/bin:$PATH"
uv --version

echo "==> vllm venv"
if [ ! -d "$VENV" ]; then
  uv venv --python 3.11 "$VENV"
fi
uv pip install --python "$VENV/bin/python" --upgrade vllm huggingface_hub

# Reinstall torch from the cu128 wheel index. vLLM's default install pulls a
# torch built against a newer CUDA (12.9+) than Runpod's stock driver supports
# (typically 570.x → CUDA 12.8). cu128 wheels work with any driver ≥525.60.13,
# which covers every modern Runpod template.
echo "==> torch (cu128 wheel — for Runpod driver 570/CUDA 12.8 compatibility)"
uv pip install --python "$VENV/bin/python" --reinstall \
  torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128

# Sanity-check: torch.cuda must initialize against the live driver before we
# hand control to supervisord, otherwise vllm will crash-loop on engine start.
"$VENV/bin/python" -c "import torch; assert torch.cuda.is_available(), 'CUDA not available — driver/torch mismatch'; print(f'    torch={torch.__version__} cuda={torch.version.cuda} gpus={torch.cuda.device_count()}')"

echo "==> control_plane venv"
if [ ! -d "$CP_VENV" ]; then
  uv venv --python 3.11 "$CP_VENV"
fi
uv pip install --python "$CP_VENV/bin/python" --upgrade \
  -r "$FILES/services/control_plane/requirements.txt"

echo "==> traefik binary"
if [ ! -x "$TRAEFIK_BIN" ]; then
  cd "$WORKSPACE/bin"
  TAG="${TRAEFIK_TAG:-}"
  if [ -z "$TAG" ]; then
    # Use python for JSON parsing — grep/sed hacks misparse when GitHub
    # returns the response as a single line.
    TAG=$(python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
req = urllib.request.Request(
    "https://api.github.com/repos/traefik/traefik/releases/latest",
    headers={"User-Agent": "deploying_llm_runpod-setup"},
)
print(json.load(urllib.request.urlopen(req, timeout=15))["tag_name"])
PY
)
  fi
  if [ -z "$TAG" ]; then
    echo "ERROR: Could not determine Traefik version from GitHub API." >&2
    echo "       Override manually: TRAEFIK_TAG=v3.5.0 ./setup.sh" >&2
    exit 1
  fi
  echo "    fetching traefik $TAG"
  curl -fL -o traefik.tar.gz \
    "https://github.com/traefik/traefik/releases/download/${TAG}/traefik_${TAG}_linux_amd64.tar.gz"
  # --no-same-owner: as root, tar would otherwise try to chown to the archive's
  # original uid/gid (1001:1001), which the network volume's filesystem rejects.
  tar --no-same-owner -xzf traefik.tar.gz traefik
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
  # Auto-fill VLLM_API_KEY (random 32-byte hex) so the live env never ships
  # with the CHANGE_ME placeholder. Override via env var if you have one.
  KEY="${VLLM_API_KEY:-$(openssl rand -hex 32)}"
  sed -i "s|^VLLM_API_KEY=.*|VLLM_API_KEY=$KEY|" "$ENV_FILE"
  GENERATED_VLLM_KEY="$KEY"
  # Optional: bake in HF_TOKEN if the operator passed it via env. Massively
  # speeds up the model download (anonymous requests are rate-limited).
  if [ -n "${HF_TOKEN:-}" ]; then
    echo "HF_TOKEN=$HF_TOKEN" >> "$ENV_FILE"
  fi
  echo "Created $ENV_FILE (VLLM_API_KEY auto-generated; HF_TOKEN $([ -n "${HF_TOKEN:-}" ] && echo set || echo unset))."
fi
if [ ! -f "$CP_ENV_FILE" ]; then
  install -m 0600 "$FILES/envs/control_plane.env.example" "$CP_ENV_FILE"
  echo "Created $CP_ENV_FILE (defaults are fine; edit only if you change ports/prefix)."
fi
if [ ! -f "$MODELS_YAML" ]; then
  install -m 0644 "$FILES/ops/models.yaml.example" "$MODELS_YAML"
  echo "Created $MODELS_YAML — edit to curate the model registry."
fi

GENERATED_VLLM_KEY="${GENERATED_VLLM_KEY:-}"

USERS_FILE=$WORKSPACE/traefik/users.htpasswd
GENERATED_PW=""
if [ ! -f "$USERS_FILE" ]; then
  GENERATED_PW=$(openssl rand -base64 18)
  htpasswd -B -b -c "$USERS_FILE" admin "$GENERATED_PW" >/dev/null
  chmod 600 "$USERS_FILE"
fi

echo "==> bashrc convenience"
add_line() { grep -qxF "$1" ~/.bashrc || echo "$1" >> ~/.bashrc; }
add_line 'export PATH="$HOME/.local/bin:$PATH"'
add_line "alias supervisorctl='supervisorctl -c $WORKSPACE/ops/supervisord.conf'"
add_line "export HF_HOME=$HF_CACHE"

echo
echo "Setup complete."
echo

if [ -n "$GENERATED_PW" ] || [ -n "$GENERATED_VLLM_KEY" ]; then
  echo "============================================================"
  echo "  SAVE THESE NOW — they will not be shown again."
  echo
  if [ -n "$GENERATED_PW" ]; then
    echo "  /admin/* Basic Auth (Traefik):"
    echo "    Username: admin"
    echo "    Password: $GENERATED_PW"
    echo "  Change later: htpasswd -B $USERS_FILE admin"
    echo
  fi
  if [ -n "$GENERATED_VLLM_KEY" ]; then
    echo "  /v1/* Bearer token (for OpenAI-style API calls):"
    echo "    VLLM_API_KEY=$GENERATED_VLLM_KEY"
    echo "  Stored in: $ENV_FILE"
    echo
  fi
  echo "============================================================"
  echo
fi

echo "Next:"
if ! grep -q '^HF_TOKEN=' "$ENV_FILE" 2>/dev/null; then
  echo "  1. (recommended) echo HF_TOKEN=hf_xxx >> $ENV_FILE"
  echo "     — Anonymous HF downloads are rate-limited to ~10 MB/s. With a token,"
  echo "       a 17 GB model takes ~3 min instead of ~30 min."
  echo "  2. $WORKSPACE/bin/bootstrap.sh   # start everything"
  echo "  3. supervisorctl status          # vllm + control_plane + traefik all RUNNING"
else
  echo "  1. $WORKSPACE/bin/bootstrap.sh   # start everything"
  echo "  2. supervisorctl status          # vllm + control_plane + traefik all RUNNING"
fi
