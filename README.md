# Deploying an LLM on Runpod (supervisord + Traefik + vLLM + control plane)

Production-style pod setup. Three supervised services on one pod, one public port:

- **vLLM** — one model loaded at a time, behind Traefik on internal `:18001`.
- **Traefik** — public `:8000`, routes `/v1/* → vLLM`, `/admin/* → control plane`, applies rate-limit + concurrency cap.
- **Control plane** — small FastAPI app on internal `:8002` for listing models, switching the loaded model, viewing status and logs over HTTP.

Same shape as your other pod, with these deltas:
- `uv` for venv setup (much faster than `python -m venv` + `pip`)
- vLLM API key in an env file (consistent with other secrets, no editing `supervisord.conf` to rotate)
- Thin wrapper script (`run_vllm.sh`) instead of a 20-line bash one-liner inside `supervisord.conf` — readable + independently runnable
- `--served-model-name current` so clients don't change their `model` field when you switch models
- HTTP control plane for model management (list/switch/status/logs), gated by **HTTP Basic Auth at Traefik** (browser-friendly login dialog)
- One-shot `switch_model.sh` to change MODEL + restart from the shell (alternative to the HTTP API)

---

## Fresh-pod walkthrough (end-to-end)

The exact sequence from an empty pod to a working endpoint.

### 1. Clone the repo
SSH in (or open the Runpod web terminal):
```bash
cd /workspace
git clone https://github.com/pranavnbapat/deploying_llm_runpod.git
cd deploying_llm_runpod
```

### 2. (Recommended) put HF_TOKEN in `.env`
Anonymous Hugging Face downloads are rate-limited to ~10 MB/s. A free-tier token gets the full CDN speed — a 17 GB model takes ~3 min with a token vs. ~30 min without. Grab one at https://huggingface.co/settings/tokens (read-only is enough), then:
```bash
cp .env.example .env
nano .env                    # set HF_TOKEN=hf_xxx... (and optionally VLLM_API_KEY, MODEL, MAX_LEN)
```
`.env` is gitignored, so secrets never leave the pod. Beyond `HF_TOKEN`, it also accepts `VLLM_API_KEY` (pre-set the inference token instead of letting setup auto-generate one) and `MODEL` / `MAX_LEN` (the first-run model id and its context length). `setup.sh` reads `.env` on every run and bakes these into `/workspace/envs/vllm.env` **the first time that file is created**, so `run_vllm.sh` picks them up. Leave `MODEL` empty to keep the default below. If you'd rather pass values one-off via the shell: `export HF_TOKEN=hf_xxx` before step 3 — shell env wins over `.env`. Skip entirely and you'll just wait ~30 min on the first model download.

### 3. Run setup
```bash
./setup.sh                   # ~3–5 min
```
This installs apt deps, creates the two venvs, pulls Traefik, drops configs into `/workspace`, **auto-generates `VLLM_API_KEY`**, and **auto-generates the `/admin/*` Basic Auth password**. Both are printed once at the end — save them. Then:
```bash
exec bash                    # picks up the supervisorctl alias and HF_HOME from .bashrc
```

Default `MODEL` is `stelterlab/Qwen3-30B-A3B-Instruct-2507-AWQ` (~17 GB, AWQ-quantised MoE, fits A40 with headroom). To use a different first-run model, set `MODEL=` (and optionally `MAX_LEN=`) in `.env` before step 3 — `setup.sh` bakes it into `/workspace/envs/vllm.env` on first creation. (Equivalently, `nano /workspace/envs/vllm.env` before step 4.) On an already-running pod, switch live with `./switch_model.sh` instead.

> **`/workspace` persists across pod terminations** (it's a Runpod network volume). On a redeploy, `setup.sh` will *not* overwrite your existing `vllm.env`, `control_plane.env`, `models.yaml`, or `users.htpasswd` — those keep your previous edits, including the auto-generated keys. To start truly clean: `rm -rf /workspace/envs /workspace/ops /workspace/traefik/users.htpasswd` *before* running `setup.sh`. Keep `/workspace/hf_cache` — that's the expensive download.

### 4. Start everything
```bash
/workspace/bin/bootstrap.sh
supervisorctl status                  # all three RUNNING
supervisorctl tail -f vllm stderr     # Ctrl-C when you see "Application startup complete"
```
First boot downloads the model into `/workspace/hf_cache` — `~3 min` with `HF_TOKEN`, `~30 min` without. Then a few more minutes for weight load + CUDA graph compile.

### 5. In the Runpod console — expose port 8000 ONLY
Pod settings → **Exposed HTTP Ports** → add `8000`. **Do not** expose `18001` (vLLM) or `8002` (control plane) — those are loopback-only by design. Runpod gives you a public URL: `https://<pod-id>-8000.proxy.runpod.net`.

If the pod was already running when you added the port, restart it for the proxy URL to appear.

### 6. From your laptop — smoke test
```bash
URL=https://<pod-id>-8000.proxy.runpod.net

# Inference (Bearer auth)
curl -H "Authorization: Bearer $VLLM_API_KEY" "$URL/v1/models"
curl -H "Authorization: Bearer $VLLM_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model":"current","messages":[{"role":"user","content":"Hello in one sentence."}]}' \
     "$URL/v1/chat/completions"

# Control plane (Basic Auth)
curl -u admin:<basic-pw> "$URL/admin/models/available" | jq

# Browser: visit and enter admin / <basic-pw> at the login dialog
# https://<pod-id>-8000.proxy.runpod.net/admin/docs
```

Note `"model":"current"` — that's the stable alias from `SERVED_MODEL_NAME`. Use it always so model switches don't break clients.

### After a pod restart
The container disk wipes, but `/workspace` (network volume) persists — venvs, configs, model cache, htpasswd file, **and the cloned repo** all survive. Recovery is just:
```bash
/workspace/bin/bootstrap.sh
```
No `setup.sh` re-run needed.

### Updating the deployment later
If you push a new version of this repo:
```bash
cd /workspace/deploying_llm_runpod
git pull
./setup.sh                   # idempotent — re-copies configs, installs any new deps
supervisorctl reread && supervisorctl update
```
Generated state (`vllm.env`, `users.htpasswd`, `models.yaml`, the HF cache) is preserved across `setup.sh` re-runs.

---

## Layout

### In this repo
```
deploying_llm_runpod/
├── README.md
├── setup.sh                       # run once on a fresh pod
├── switch_model.sh                # change model + restart vllm (CLI)
└── files/                         # copied into /workspace by setup.sh
    ├── bin/
    │   ├── bootstrap.sh           # bring supervisord up (after pod restart)
    │   ├── run_vllm.sh            # supervisord calls this
    │   └── run_control_plane.sh   # supervisord calls this
    ├── envs/
    │   ├── vllm.env.example
    │   └── control_plane.env.example
    ├── ops/
    │   ├── supervisord.conf
    │   └── models.yaml.example    # registry shown by /admin/models/available
    ├── services/
    │   └── control_plane/
    │       ├── app.py             # FastAPI control plane
    │       └── requirements.txt
    └── traefik/
        ├── traefik.yml
        └── dynamic/
            ├── vllm.yml           # /v1/* -> 127.0.0.1:18001
            └── control_plane.yml  # /admin/* -> 127.0.0.1:8002
```

### On the pod (after setup)
```
/workspace/
├── bin/
│   ├── bootstrap.sh
│   ├── run_vllm.sh
│   ├── run_control_plane.sh
│   └── traefik                    # binary (downloaded by setup.sh)
├── envs/
│   ├── vllm/                      # uv venv with vLLM installed
│   ├── control_plane/             # uv venv for FastAPI
│   ├── vllm.env                   # MODEL + VLLM_API_KEY + tuning
│   └── control_plane.env          # internal URL + port
├── hf_cache/                      # HF_HOME — all model weights live here
├── logs/                          # supervisord + traefik + control_plane logs
├── ops/
│   ├── supervisord.conf
│   ├── models.yaml                # model registry
│   ├── supervisor.sock
│   └── supervisord.pid
├── services/
│   └── control_plane/
│       ├── app.py
│       └── requirements.txt
├── traefik/
│   ├── traefik.yml
│   ├── users.htpasswd             # bcrypt users for /admin/* basicAuth
│   └── dynamic/
│       ├── vllm.yml
│       └── control_plane.yml
└── vllm/
    ├── .cache/                    # vLLM/torch compile caches
    └── logs/                      # vllm.log, vllm.err.log
```

---

## Managing Basic Auth users

`setup.sh` generates an initial `admin` user with a random password. Manage users with `htpasswd` (Traefik watches the file — changes apply without restart):
```bash
htpasswd -B /workspace/traefik/users.htpasswd admin           # change admin password
htpasswd -B /workspace/traefik/users.htpasswd alice           # add another user
htpasswd -D /workspace/traefik/users.htpasswd alice           # remove a user
```

The `/admin/docs` Swagger UI works in the browser: visiting it triggers the Basic Auth dialog, after which the browser auto-sends credentials on every subsequent request (so "Try It Out" calls in Swagger just work — no extra "Authorize" button to use).

---

## Switching models

Two equivalent ways: HTTP API (control plane) or CLI (`switch_model.sh`). Both edit `/workspace/envs/vllm.env` and `supervisorctl restart vllm`.

Because `SERVED_MODEL_NAME=current` in the env file, **clients always use `"model": "current"`** in their `/v1/*` requests — switching models on the server doesn't break them.

### Via control plane (HTTP)

```bash
ADMIN=https://<pod-id>-8000.proxy.runpod.net/admin
AUTH="-u admin:<your-basic-auth-password>"

# What's available (registry ∪ what's cached on disk)
curl $AUTH "$ADMIN/models/available" | jq

# What's loaded right now (and is vLLM actually serving?)
curl $AUTH "$ADMIN/models/loaded" | jq

# Switch — returns immediately; vLLM reloads in the background (~30-90s)
curl -X POST $AUTH -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen2.5-32B-Instruct-AWQ"}' \
  "$ADMIN/models/switch" | jq

# Poll /models/loaded until vllm_reachable=true and vllm_serving contains your model
```

If the model is in `models.yaml`, its `max_len` and `extra_args` are applied automatically. Override per-request with `{"model": "...", "max_len": 8192, "extra_args": "--quantization awq"}`.

Live OpenAPI docs: `https://<pod-id>-8000.proxy.runpod.net/admin/docs`.

### Via CLI

```bash
cd /workspace/deploying_llm_runpod
./switch_model.sh Qwen/Qwen2.5-32B-Instruct-AWQ 8192
```

For arbitrary flag tweaks, edit `vllm.env` directly:
```bash
nano /workspace/envs/vllm.env
supervisorctl restart vllm
```

Use `VLLM_EXTRA_ARGS` for anything specific to a model (quantisation, dtype, mm limits, trust-remote-code, etc.).
**Quote the value** if it contains spaces — `vllm.env` is sourced by bash, so `VLLM_EXTRA_ARGS=--quantization awq` (no quotes) makes the shell try to *run* `awq` as a command. Write `VLLM_EXTRA_ARGS="--quantization awq"` instead. (The control plane's `/admin/models/switch` already quotes correctly on writeback.)

---

## Day-to-day ops

```bash
# After every pod restart:
/workspace/bin/bootstrap.sh

# Status
supervisorctl status

# Logs (live)
supervisorctl tail -f vllm
supervisorctl tail -f vllm stderr
supervisorctl tail -f control_plane
supervisorctl tail -f traefik

# Logs (last N lines)
supervisorctl tail -200 vllm

# Logs over HTTP (control plane)
curl -u admin:<password> \
  "https://<pod>:8000/admin/logs/vllm?lines=200&stderr=true"

# Restart
supervisorctl restart vllm
supervisorctl restart control_plane
supervisorctl restart traefik

# Stop everything
supervisorctl shutdown

# After editing supervisord.conf
supervisorctl reread
supervisorctl update

# After editing files under /workspace/traefik/dynamic/ — Traefik watches the dir, auto-reloads
```

The `supervisorctl` alias (no `-c` flag needed) is added to `.bashrc` by `setup.sh`.

---

## Traefik middlewares

In `/workspace/traefik/dynamic/vllm.yml`:

| Middleware | Setting | Tweak when |
|------------|---------|------------|
| `vllm-ratelimit` | `average: 2` req/s, `burst: 5` | Tighten if you see abuse, loosen for trusted callers. |
| `vllm-inflight` | `amount: 1` | Keep at 1 for a single GPU. Raise only if you've measured headroom. |

Traefik watches the dynamic dir — saving the file applies changes without restarting Traefik.

---

## Pre-downloading models (so switching is instant)

```bash
source /workspace/envs/vllm/bin/activate
export HF_HOME=/workspace/hf_cache
hf download Qwen/Qwen2.5-7B-Instruct
hf download Qwen/Qwen2.5-32B-Instruct-AWQ
# ... etc.
```

After download, `./switch_model.sh <model>` is just a vLLM cold-start (no network), typically 30–90s depending on model size.

---

## Auth model (summary)

| Surface | Gate | Where it's enforced | How clients send it |
|---------|------|---------------------|----------------------|
| `/v1/*` (inference) | `VLLM_API_KEY` | vLLM itself (`--api-key`) | `Authorization: Bearer <key>` |
| `/admin/*` (management) | HTTP Basic Auth, users in `/workspace/traefik/users.htpasswd` | Traefik `basicAuth` middleware (`removeHeader: true` strips it before forwarding) | Browser login dialog, or `curl -u user:pass` |
| `/docs`, `/metrics`, `/health`, … (vLLM aux) | HTTP Basic Auth (same users file as `/admin/*`) | Traefik `basicAuth` on `vllm-aux-router` | Browser login dialog, or `curl -u user:pass` |
| Loopback `127.0.0.1:18001` (vLLM) | not exposed | — | — |
| Loopback `127.0.0.1:8002` (control plane) | not exposed; trusts Traefik | — | — |

Two separate credentials by design: hand out `VLLM_API_KEY` to inference clients without giving them the ability to change which model is loaded; keep `htpasswd` to operators.

---

## Control plane endpoints (reference)

All under `/admin/*`, all gated by HTTP Basic Auth at Traefik.

| Method | Path | Purpose |
|--------|------|---------|
| GET    | `/admin/health` | Liveness (still behind basicAuth at Traefik). |
| GET    | `/admin/models/available` | Registry entries + cached-on-disk models; each annotated `downloaded`, `loaded`. |
| GET    | `/admin/models/loaded` | Configured model + what vLLM is actually serving (live probe). |
| POST   | `/admin/models/switch` | Body `{"model": "...", "max_len": ?, "extra_args": "?"}`. Edits env file + restarts vLLM. Returns immediately; client polls `/models/loaded`. |
| GET    | `/admin/status` | `supervisorctl status` output. |
| GET    | `/admin/logs/{program}?lines=N&stderr=bool` | Tail logs of `vllm`, `traefik`, or `control_plane`. |
| GET    | `/admin/docs` | Live OpenAPI / Swagger UI. |

Edit `/workspace/ops/models.yaml` to curate the registry (id, label, max_len, extra_args, notes per model). The control plane reads it live — no restart needed.

---

## Adding another service later

To add e.g. a transcription sidecar:

1. Create its venv on `/workspace/envs/<svc>/`.
2. Drop its code in `/workspace/services/<svc>/`.
3. Add a `[program:<svc>]` block to `/workspace/ops/supervisord.conf` pointing at `/workspace/bin/run_<svc>.sh`.
4. Add a route to `/workspace/traefik/dynamic/<svc>.yml` with a distinct prefix (e.g. `PathPrefix(\`/transcribe\`)`).
5. `supervisorctl reread && supervisorctl update`.

The Traefik prefixes `/v1` (vLLM) and `/admin` (control plane) are already taken; pick anything else for new services. Route priority is by rule length, longest first.

---

## Troubleshooting

- **`vllm` keeps restarting** — `supervisorctl tail -200 vllm stderr`. Common: missing `MODEL` / `VLLM_API_KEY` in env file, OOM (lower `MAX_LEN` or `GPU_UTIL`), gated model without `hf auth login`.
- **Public URL returns 502** — Traefik is up but vLLM isn't ready yet. `supervisorctl status` and tail vllm logs; cold start can take a minute.
- **`/v1/models` returns 401** — missing/wrong `Authorization: Bearer <key>` header.
- **Want to wipe vllm install** — `rm -rf /workspace/envs/vllm` then re-run `./setup.sh`. Model cache in `/workspace/hf_cache` is independent — leave it.
- **Want to test the wrapper script outside supervisord** — `/workspace/bin/run_vllm.sh` runs it in the foreground with the same env. Useful for debugging boot errors.
- **Edited `supervisord.conf` and nothing changed** — `supervisorctl reread && supervisorctl update`. Just `restart` doesn't re-read config.
- **`/admin/*` returns 401** — missing/wrong Basic Auth credentials. Try `curl -u admin:<pw> ...`. Reset with `htpasswd -B /workspace/traefik/users.htpasswd admin`.
- **`/admin/models/loaded` shows `vllm_reachable: false`** — vLLM is still booting/swapping; wait, then re-poll. If it stays false, check `supervisorctl tail -200 vllm stderr`.
- **Switched model but `/v1/chat/completions` returns the old model** — the swap takes 30–90s. Poll `/admin/models/loaded` until `vllm_serving` contains your new model id.
- **`/admin/docs` loads but shows "Failed to load API definition"** — `CONTROL_PLANE_ROOT_PATH` in `control_plane.env` doesn't match the Traefik `stripPrefix` value. Both must be `/admin` (or both whatever you've changed it to). After fixing, `supervisorctl restart control_plane`.
- **`supervisorctl: command not found` or "no such file or directory" right after setup.sh** — the alias is in `~/.bashrc` but your current shell didn't load it. Run `exec bash` (or open a new SSH session), or use the long form: `supervisorctl -c /workspace/ops/supervisord.conf <cmd>`.
- **vLLM downloads from HF on every restart** — your `HF_HOME` isn't set or doesn't point to `/workspace/hf_cache`. Check `/workspace/envs/vllm.env` and that `run_vllm.sh` exports it.
