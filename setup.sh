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
# Where the Python venvs live. Default is the persistent /workspace volume so
# they survive pod restarts. But on pods whose /workspace is a slow network
# filesystem (e.g. RunPod's MooseFS, `mfs#...` in `df -h /workspace`), building
# a venv there is pathologically slow — torch/vllm unpack into hundreds of
# thousands of small files and every write is a network round-trip. On those
# hosts, point VENV_ROOT at local disk (e.g. VENV_ROOT=/opt/envs ./setup.sh):
# the build runs at local-disk speed, at the cost of being wiped on a cold pod
# restart — so re-run setup.sh after a cold start to rebuild the venvs.
VENV_ROOT="${VENV_ROOT:-$WORKSPACE/envs}"
VENV=$VENV_ROOT/vllm
CP_VENV=$VENV_ROOT/control_plane
ENV_FILE=$WORKSPACE/envs/vllm.env
CP_ENV_FILE=$WORKSPACE/envs/control_plane.env
MODELS_YAML=$WORKSPACE/ops/models.yaml
HF_CACHE=$WORKSPACE/hf_cache
TRAEFIK_BIN=$WORKSPACE/bin/traefik
# Used when neither TRAEFIK_TAG is set nor the GitHub API lookup succeeds.
TRAEFIK_FALLBACK_TAG="${TRAEFIK_FALLBACK_TAG:-v3.7.5}"

echo "==> driver / CUDA preflight"
# vLLM's PyPI wheel ships its own precompiled CUDA extension. Picking the wrong
# wheel for the host driver's max CUDA results in `libcudart.so.N: cannot open
# shared object file` at vllm import. Detect the driver's CUDA and pick a
# compatible vllm pin.
#
# IMPORTANT: this reads the *host driver* CUDA from nvidia-smi, which is what
# the kernel module supports — not the toolkit CUDA from the container image.
# Runpod's "CUDA 13" templates only change the container image; the host
# driver is whatever physical machine Runpod assigned (often still 570.x).
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — this script requires a GPU pod." >&2
  exit 1
fi
DRIVER_CUDA=$(nvidia-smi 2>/dev/null | awk -F'CUDA Version: *' '/CUDA Version/ {print $2}' | awk '{print $1}' | head -1)
if [ -z "$DRIVER_CUDA" ]; then
  echo "ERROR: Could not parse 'CUDA Version' from nvidia-smi output." >&2
  exit 1
fi
DRIVER_CUDA_MAJOR=${DRIVER_CUDA%%.*}
DRIVER_CUDA_MINOR=${DRIVER_CUDA#*.}

# Map host-driver CUDA -> vllm version constraint.
# These boundaries are based on what vllm's PyPI wheel was built against in
# each release line. Override with VLLM_PIN env var if you need a specific
# version (e.g. VLLM_PIN='==0.19.1' ./setup.sh).
if [ -n "${VLLM_PIN:-}" ]; then
  echo "    driver CUDA $DRIVER_CUDA — user override VLLM_PIN=$VLLM_PIN"
elif [ "$DRIVER_CUDA_MAJOR" -ge 13 ]; then
  VLLM_PIN=""
  echo "    driver CUDA $DRIVER_CUDA — installing latest vLLM"
elif [ "$DRIVER_CUDA_MAJOR" -eq 12 ] && [ "$DRIVER_CUDA_MINOR" -ge 4 ]; then
  VLLM_PIN="<0.20"
  echo "    driver CUDA $DRIVER_CUDA — pinning vLLM <0.20 (last CUDA-12 release line)"
else
  cat >&2 <<EOF
ERROR: NVIDIA driver supports only CUDA $DRIVER_CUDA — too old for any recent
       vLLM release. You need driver >= 525 (CUDA >= 12.4).
EOF
  exit 1
fi

echo "==> apt packages"
apt-get update -qq
apt-get install -y -qq supervisor apache2-utils openssl curl nano git wget htop tmux tar ca-certificates

echo "==> directory layout"
mkdir -p \
  "$WORKSPACE/bin" \
  "$WORKSPACE/envs" \
  "$VENV_ROOT" \
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
# Big CUDA wheels (torch, cudnn, cublas, nvshmem, flashinfer) are several GB
# each and routinely blow past uv's stingy 30s default on RunPod's link, dying
# with "network timeout". Give downloads room and let uv retry transient drops.
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-600}"
export UV_CONCURRENT_DOWNLOADS="${UV_CONCURRENT_DOWNLOADS:-4}"
# Keep uv's cache on the SAME filesystem as the venvs. uv installs by hardlinking
# from the cache into the venv; if they're on different filesystems it silently
# falls back to copying every file, which is exactly the slow path on a network
# /workspace. Co-locating them means a local VENV_ROOT gets fast local hardlinks.
export UV_CACHE_DIR="${UV_CACHE_DIR:-$VENV_ROOT/.uv-cache}"
uv --version

echo "==> vllm venv"
if [ ! -d "$VENV" ]; then
  uv venv --python 3.11 "$VENV"
fi
# VLLM_PIN was set by the preflight block above (empty for CUDA-13 drivers,
# '<0.20' for CUDA-12 drivers, or whatever the operator overrode).
cat <<EOF
    Installing vLLM can look stuck while uv downloads/prepares large CUDA wheels.
    On CUDA 13 hosts this is commonly several GB (torch, cudnn, cublas, flashinfer).
    If interrupted, re-run ./setup.sh; uv will reuse any completed downloads.
EOF
uv pip install --python "$VENV/bin/python" --upgrade "vllm${VLLM_PIN}" huggingface_hub

# Sanity-check: both torch.cuda allocation AND vllm._C must work. Lazy init
# only fires when we touch a CUDA op — `is_available()` lies on its own.
# This catches driver/torch and CUDA-toolkit/vllm-extension mismatches
# before supervisord starts vllm and crash-loops in the background.
"$VENV/bin/python" - <<'PY'
import torch
try:
    torch.zeros(1, device='cuda')
except Exception as e:
    raise SystemExit(f"CUDA allocation failed (driver too old for torch's CUDA?): {e}")
try:
    import vllm  # noqa: F401
except Exception as e:
    raise SystemExit(f"vllm import failed (likely libcudart.so mismatch): {e}")
print(f"    torch={torch.__version__} cuda={torch.version.cuda} gpus={torch.cuda.device_count()}")
import vllm
print(f"    vllm={vllm.__version__}")
PY

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
    # GitHub's API lookup commonly fails on fresh pods (unauthenticated rate
    # limit is per-IP, and Runpod's shared NAT IPs are often exhausted). Fall
    # back to a known-good tag rather than aborting the whole bootstrap.
    TAG="$TRAEFIK_FALLBACK_TAG"
    echo "    GitHub API lookup failed; falling back to $TAG" >&2
    echo "    (override with TRAEFIK_TAG=vX.Y.Z ./setup.sh if you need another)" >&2
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
install -m 0755 "$FILES/bin/capacity_report.sh"    "$WORKSPACE/bin/capacity_report.sh"
install -m 0755 "$FILES/bin/estimate_capacity.py"  "$WORKSPACE/bin/estimate_capacity.py"
install -m 0644 "$FILES/ops/supervisord.conf"            "$WORKSPACE/ops/supervisord.conf"
install -m 0644 "$FILES/traefik/traefik.yml"             "$WORKSPACE/traefik/traefik.yml"
install -m 0644 "$FILES/traefik/dynamic/vllm.yml"        "$WORKSPACE/traefik/dynamic/vllm.yml"
install -m 0644 "$FILES/traefik/dynamic/control_plane.yml" "$WORKSPACE/traefik/dynamic/control_plane.yml"
install -m 0644 "$FILES/services/control_plane/app.py"   "$WORKSPACE/services/control_plane/app.py"
install -m 0644 "$FILES/services/control_plane/requirements.txt" \
                                                         "$WORKSPACE/services/control_plane/requirements.txt"

# --- Concurrency planning -----------------------------------------------------
# MAX_NUM_SEQS is "how many users vLLM serves in parallel"; MAX_LEN is the
# per-request context. They trade against the same KV-cache pool. On first setup,
# if these weren't supplied via .env / env vars and we're on a terminal, show a
# rough capacity estimate and prompt. In automation (no TTY) the .env values are
# used as-is and nothing is prompted.
if [ ! -f "$ENV_FILE" ] && [ -t 0 ] && { [ -z "${MAX_LEN:-}" ] || [ -z "${MAX_NUM_SEQS:-}" ]; }; then
  MODEL_FOR_EST="${MODEL:-stelterlab/Qwen3-30B-A3B-Instruct-2507-AWQ}"
  echo "==> concurrency planning for $MODEL_FOR_EST"
  "$VENV/bin/python" "$FILES/bin/estimate_capacity.py" \
    --model "$MODEL_FOR_EST" --gpu-util "${GPU_UTIL:-0.90}" || true
  if [ -z "${MAX_LEN:-}" ]; then
    read -r -p "    Max context length per request [16384]: " _ans
    export MAX_LEN="${_ans:-16384}"
  fi
  if [ -z "${MAX_NUM_SEQS:-}" ]; then
    read -r -p "    Concurrent users to serve in parallel [8]: " _ans
    export MAX_NUM_SEQS="${_ans:-8}"
  fi
fi

if [ ! -f "$ENV_FILE" ]; then
  install -m 0600 "$FILES/envs/vllm.env.example" "$ENV_FILE"
  # Auto-fill VLLM_API_KEY (random 32-byte hex) so the live env never ships
  # with the CHANGE_ME placeholder. Override via env var if you have one.
  KEY="${VLLM_API_KEY:-$(openssl rand -hex 32)}"
  sed -i "s|^VLLM_API_KEY=.*|VLLM_API_KEY=$KEY|" "$ENV_FILE"
  GENERATED_VLLM_KEY="$KEY"
  # Optional: override the model (and its context length) from .env / env var.
  # When unset, the default baked into vllm.env.example is kept. Use | as the
  # sed delimiter — model ids contain /. Only applies on first creation; switch
  # a live pod with ./switch_model.sh instead.
  if [ -n "${MODEL:-}" ]; then
    sed -i "s|^MODEL=.*|MODEL=$MODEL|" "$ENV_FILE"
  fi
  if [ -n "${MAX_LEN:-}" ]; then
    sed -i "s|^MAX_LEN=.*|MAX_LEN=$MAX_LEN|" "$ENV_FILE"
  fi
  # Concurrency: how many sequences vLLM batches at once. Size it against the
  # KV-cache budget (MAX_NUM_SEQS × MAX_LEN must fit free VRAM after weights).
  if [ -n "${MAX_NUM_SEQS:-}" ]; then
    sed -i "s|^MAX_NUM_SEQS=.*|MAX_NUM_SEQS=$MAX_NUM_SEQS|" "$ENV_FILE"
  fi
  # Optional: bake in HF_TOKEN if the operator passed it via env. Massively
  # speeds up the model download (anonymous requests are rate-limited).
  if [ -n "${HF_TOKEN:-}" ]; then
    echo "HF_TOKEN=$HF_TOKEN" >> "$ENV_FILE"
  fi
  MODEL_SET=$(grep -E '^MODEL=' "$ENV_FILE" | head -1 | cut -d= -f2-)
  echo "Created $ENV_FILE (model=$MODEL_SET; VLLM_API_KEY auto-generated; HF_TOKEN $([ -n "${HF_TOKEN:-}" ] && echo set || echo unset))."
fi

# Persist the resolved venv path so run_vllm.sh (launched by supervisord, which
# never sees setup.sh's VENV_ROOT) activates the right one — including a local,
# non-/workspace venv. Idempotent: rewrite the line if present, else append.
if grep -q '^VLLM_VENV=' "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^VLLM_VENV=.*|VLLM_VENV=$VENV|" "$ENV_FILE"
else
  echo "VLLM_VENV=$VENV" >> "$ENV_FILE"
fi

# Keep Traefik's proxy caps in sync with vLLM's batch size. inFlightReq REJECTS
# (429) above `amount` — it does NOT queue — so it must sit ABOVE MAX_NUM_SEQS,
# letting vLLM (which queues past its batch, no error) be the real limiter.
# Re-derived on every run so the proxy can never silently throttle below the GPU.
VLLM_YML="$WORKSPACE/traefik/dynamic/vllm.yml"
EFFECTIVE_SEQS=$(grep -E '^MAX_NUM_SEQS=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2)
EFFECTIVE_SEQS=${EFFECTIVE_SEQS:-1}
INFLIGHT=$(( EFFECTIVE_SEQS * 2 + 4 ))
RL_AVG=$(( EFFECTIVE_SEQS * 2 )); [ "$RL_AVG" -lt 10 ] && RL_AVG=10
RL_BURST=$(( RL_AVG * 2 ))
sed -i \
  -e "s|^\([[:space:]]*amount:\).*|\1 $INFLIGHT|" \
  -e "s|^\([[:space:]]*average:\).*|\1 $RL_AVG|" \
  -e "s|^\([[:space:]]*burst:\).*|\1 $RL_BURST|" \
  "$VLLM_YML"
echo "==> Traefik proxy caps synced to MAX_NUM_SEQS=$EFFECTIVE_SEQS (inflight=$INFLIGHT, rate=${RL_AVG}/${RL_BURST} req/s)"

if [ ! -f "$CP_ENV_FILE" ]; then
  install -m 0600 "$FILES/envs/control_plane.env.example" "$CP_ENV_FILE"
  echo "Created $CP_ENV_FILE (defaults are fine; edit only if you change ports/prefix)."
fi
# Persist the resolved control_plane venv path (see VLLM_VENV note above).
if grep -q '^CONTROL_PLANE_VENV=' "$CP_ENV_FILE" 2>/dev/null; then
  sed -i "s|^CONTROL_PLANE_VENV=.*|CONTROL_PLANE_VENV=$CP_VENV|" "$CP_ENV_FILE"
else
  echo "CONTROL_PLANE_VENV=$CP_VENV" >> "$CP_ENV_FILE"
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
case "$VENV_ROOT" in
  "$WORKSPACE"/*) ;;
  *)
    echo
    echo "NOTE: venvs are at $VENV_ROOT (off the persistent /workspace volume)."
    echo "      They are wiped on a cold pod restart — re-run ./setup.sh after one"
    echo "      (it's fast: downloads are cached and writes are local)."
    ;;
esac
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
  echo "  3. supervisorctl -c $WORKSPACE/ops/supervisord.conf status   # vllm + control_plane + traefik all RUNNING"
  echo "  4. $WORKSPACE/bin/capacity_report.sh  # confirm achieved vs requested concurrency"
else
  echo "  1. $WORKSPACE/bin/bootstrap.sh   # start everything"
  echo "  2. supervisorctl -c $WORKSPACE/ops/supervisord.conf status   # vllm + control_plane + traefik all RUNNING"
  echo "  3. $WORKSPACE/bin/capacity_report.sh  # confirm achieved vs requested concurrency"
fi
