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
./setup.sh                   # first vLLM install can take several minutes
```
This installs apt deps, creates the two venvs, pulls Traefik, drops configs into `/workspace`, **auto-generates `VLLM_API_KEY`**, and **auto-generates the `/admin/*` Basic Auth password**. On CUDA 13 hosts, the vLLM step downloads/prepares several GB of CUDA wheels (`torch`, `cudnn`, `cublas`, `flashinfer`, etc.), so uv can appear quiet or stuck for a while. If the install is interrupted, just re-run `./setup.sh`; uv reuses completed downloads from its cache. On an interactive run, setup first asks whether to install with **uv** (faster, default) or **pip** (slower but reliable on hosts where uv stalls — see Troubleshooting). Just press Enter for uv. To skip the prompt (e.g. automation), set `USE_PIP=0` or `USE_PIP=1` explicitly; the env var always wins. Both generated credentials are printed once at the end — save them. Then:
```bash
exec bash                    # picks up the supervisorctl alias and HF_HOME from .bashrc
```

Default `MODEL` is `stelterlab/Qwen3-30B-A3B-Instruct-2507-AWQ` (~17 GB, AWQ-quantised MoE, fits A40 with headroom). To use a different first-run model, set `MODEL=` (and optionally `MAX_LEN=`) in `.env` before step 3 — `setup.sh` bakes it into `/workspace/envs/vllm.env` on first creation. (Equivalently, `nano /workspace/envs/vllm.env` before step 4.) On an already-running pod, switch live with `./switch_model.sh` instead.

> **`/workspace` persists across pod terminations** (it's a Runpod network volume). On a redeploy, `setup.sh` will *not* overwrite your existing `vllm.env`, `control_plane.env`, `models.yaml`, or `users.htpasswd` — those keep your previous edits, including the auto-generated keys. To start truly clean: `rm -rf /workspace/envs /workspace/ops /workspace/traefik/users.htpasswd` *before* running `setup.sh`. Keep `/workspace/hf_cache` — that's the expensive download.

> **Slow `/workspace`? Build the venvs on local disk.** Some pods back `/workspace` with a network filesystem (check `df -h /workspace` — a `mfs#...` mount is RunPod's MooseFS). Building a venv there is pathologically slow: `torch`/`vllm` unpack into hundreds of thousands of small files and every write is a network round-trip, so `setup.sh` can appear frozen at `Preparing packages...` for tens of minutes even though the network download itself is fast. Fix it by putting the venvs on the pod's local disk: `VENV_ROOT=/opt/envs ./setup.sh`. The build then runs at local-disk speed (uv also co-locates its cache there so installs hardlink instead of copying). The trade-off: local disk is wiped on a cold pod restart, so you must re-run `VENV_ROOT=/opt/envs ./setup.sh` after one (it's quick — downloads are cached, writes are local). The resolved venv path is persisted into `vllm.env`/`control_plane.env`, so the runners always find it. Default (`VENV_ROOT` unset) keeps the venvs on `/workspace` as before.

### 4. Start everything
```bash
/workspace/bin/bootstrap.sh
supervisorctl status                  # all three RUNNING
supervisorctl tail -f vllm stderr     # Ctrl-C when you see "Application startup complete"
```
First boot downloads the model into `/workspace/hf_cache` — `~3 min` with `HF_TOKEN`, `~30 min` without. Then a few more minutes for weight load + CUDA graph compile.

When the log shows `Application startup complete`, confirm vLLM is actually serving — still on the pod, over loopback. vLLM enforces the API key even on `127.0.0.1`, so pass the token from `vllm.env`:
```bash
KEY=$(grep ^VLLM_API_KEY= /workspace/envs/vllm.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:18001/v1/models
```
A JSON body listing the id `current` means it's healthy and ready to expose. `Connection refused` means it's still warming up — re-check `supervisorctl status` and `supervisorctl tail -200 vllm stderr`.

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
No `setup.sh` re-run needed — **unless** you built the venvs on local disk with `VENV_ROOT` (see "Slow `/workspace`?" above). Those live on the container disk and are wiped on restart, so first re-run `VENV_ROOT=/opt/envs ./setup.sh`, then `bootstrap.sh`.

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

## Verifying & accessing the endpoint

Check in order — **local first, then public**. Each step gates the next.

### 1. On the pod — is it serving?
```bash
supervisorctl status                                  # vllm, control_plane, traefik all RUNNING
supervisorctl tail -200 vllm | grep "Application startup complete"

# Loopback inference (vLLM enforces the API key even on 127.0.0.1)
KEY=$(grep ^VLLM_API_KEY= /workspace/envs/vllm.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:18001/v1/models
```
JSON listing the id `current` = healthy. Only then bother exposing the port.

### 2. Expose port 8000
Runpod console → **Exposed HTTP Ports** → add `8000` **only** (never `18001` or `8002`). You get `https://<pod-id>-8000.proxy.runpod.net`. `<pod-id>` comes from the Runpod **dashboard** — *not* the container hostname in your shell prompt (e.g. `root@fd5cda677826`).

### 3. Credentials (printed once by `setup.sh`)
| Surface | Credential | Recover it |
|---------|-----------|-----------|
| `/v1/*` (inference) | `VLLM_API_KEY` → `Authorization: Bearer <key>` | `grep ^VLLM_API_KEY= /workspace/envs/vllm.env` |
| everything else | Basic Auth `admin:<password>` | reset: `htpasswd -B /workspace/traefik/users.htpasswd admin` |

### 4. From your laptop — what to hit
All paths below are appended to the public base `https://<pod-id>-8000.proxy.runpod.net`:

| Path | Auth | Purpose |
|------|------|---------|
| `POST /v1/chat/completions` | Bearer | Chat inference (the main one) |
| `POST /v1/completions` | Bearer | Text completion |
| `GET /v1/models` | Bearer | Confirms the alias `current` is served |
| `GET /admin/docs` | Basic | **Control-plane Swagger UI — clickable in a browser** |
| `GET /admin/models/loaded` | Basic | What vLLM is actually serving (live probe) |
| `GET /admin/models/available` | Basic | Registry + models cached on disk |
| `POST /admin/models/switch` | Basic | Swap the loaded model |
| `GET /admin/status` | Basic | `supervisorctl status` over HTTP |
| `GET /admin/logs/{vllm\|traefik\|control_plane}?lines=200&stderr=true` | Basic | Tail logs over HTTP |
| `GET /docs`, `/health`, `/metrics`, `/version` | Basic | vLLM's own pages (full `/admin` list under *Control plane endpoints* below) |

```bash
URL=https://<pod-id>-8000.proxy.runpod.net

# Inference — always "model":"current" (the SERVED_MODEL_NAME alias; survives model switches)
curl -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
     -d '{"model":"current","messages":[{"role":"user","content":"Hello in one sentence."}]}' \
     "$URL/v1/chat/completions"

# Control plane
curl -u admin:<password> "$URL/admin/models/loaded" | jq
```
Easiest browser entry point: open `…/admin/docs`, enter `admin` / `<password>` at the login dialog, then **Try it out** works for every `/admin` endpoint.

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
| `vllm-ratelimit` | `average: 30` req/s, `burst: 60` | Sized for a multi-user Arena session. The source is the calling service (not the end user), so this bucket is effectively global; per-user limiting lives in the frontend. Lower it if this pod has a single trusted caller. |
| `vllm-inflight` | `amount: 32` | **Must sit ABOVE your peak concurrent users** — `inFlightReq` returns 429 above `amount`, it does NOT queue. Keep vLLM's `MAX_NUM_SEQS` (in `vllm.env`) as the real GPU-capacity limiter; vLLM queues gracefully past it. Setting this to 1 serialises everything and 429s concurrent callers. |

Traefik watches the dynamic dir — saving the file applies changes without restarting Traefik.

> **Concurrency note:** for N simultaneous users with no errors, set `MAX_NUM_SEQS` (vLLM, in `.env`/`vllm.env`) to the GPU's batch capacity and `vllm-inflight amount` *above* N. vLLM batches up to `MAX_NUM_SEQS` and queues the rest; Traefik must not reject before requests reach it.

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

- **`./setup.sh` looks stuck at `Preparing packages...`** — this is the vLLM wheel install, not the model download. On CUDA 13 hosts it's several GB of dependencies. Check activity with `htop`, `df -h /workspace /root`, or `du -sh ~/.cache/uv /workspace/envs/vllm 2>/dev/null`; if you Ctrl-C'd, re-run `./setup.sh` and it resumes from cached downloads. **If the byte counts sit unchanged for many minutes**, first confirm the link is actually fine with `pip download --no-deps -d /tmp/dl triton` (should hit 100+ MB/s). It's then one of two things:
    - **Slow network `/workspace`** (`df -h /workspace` shows a `mfs#...` MooseFS mount) — the venv is being built on a network filesystem. Rebuild on local disk: `VENV_ROOT=/opt/envs ./setup.sh` (see "Slow `/workspace`?" in setup).
    - **uv stalling on large wheels** — on some RunPod hosts uv's downloader hangs on the big CUDA wheels (torch ~500 MB, flashinfer) even though the raw link is fast and the disk is local; plain pip streams the identical files fine. Re-run and choose **pip** at the installer prompt, or force it non-interactively with `USE_PIP=1 ./setup.sh` (combine with `VENV_ROOT` if also on MooseFS: `USE_PIP=1 VENV_ROOT=/opt/envs ./setup.sh`). uv reuses anything already cached and pip handles the rest.
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
