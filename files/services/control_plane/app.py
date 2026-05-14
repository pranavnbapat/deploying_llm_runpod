"""
vLLM control plane: list models, switch loaded model, view status/logs.
Runs on 127.0.0.1:8002 behind Traefik at /admin/* (prefix stripped by Traefik).

Auth is enforced at the Traefik layer (basicAuth middleware on the /admin/*
router). This process trusts requests that reach it. NEVER expose port 8002
publicly without re-adding an auth check here.
"""
from __future__ import annotations

import os
import subprocess
from enum import Enum
from pathlib import Path
from typing import Optional

import httpx
import yaml
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

WORKSPACE = Path("/workspace")
ENV_FILE = WORKSPACE / "envs/vllm.env"
MODELS_YAML = WORKSPACE / "ops/models.yaml"
HF_HUB_CACHE = WORKSPACE / "hf_cache/hub"
SUPERVISORD_CONF = WORKSPACE / "ops/supervisord.conf"
VLLM_URL = os.environ.get("VLLM_INTERNAL_URL", "http://127.0.0.1:8001")

KNOWN_PROGRAMS = {"vllm", "traefik", "control_plane"}

app = FastAPI(title="vLLM Control Plane", docs_url="/docs", redoc_url=None)


def parse_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def write_env_keys(path: Path, updates: dict[str, str]) -> None:
    """Rewrite env file preserving comments and ordering; append unknown keys."""
    lines = path.read_text().splitlines() if path.exists() else []
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            out.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}")
    path.write_text("\n".join(out) + "\n")


def load_registry() -> list[dict]:
    if not MODELS_YAML.exists():
        return []
    data = yaml.safe_load(MODELS_YAML.read_text()) or {}
    return list(data.get("models", []))


def scan_hf_cache() -> set[str]:
    """Return model ids present in the HF hub cache directory."""
    if not HF_HUB_CACHE.exists():
        return set()
    found: set[str] = set()
    for entry in HF_HUB_CACHE.iterdir():
        if not entry.is_dir() or not entry.name.startswith("models--"):
            continue
        parts = entry.name.removeprefix("models--").split("--", 1)
        if len(parts) == 2:
            found.add(f"{parts[0]}/{parts[1]}")
    return found


def supervisorctl(*args: str, timeout: int = 30) -> str:
    res = subprocess.run(
        ["supervisorctl", "-c", str(SUPERVISORD_CONF), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return (res.stdout + res.stderr).rstrip()


def _build_model_choices() -> type[Enum]:
    """Build a string-valued Enum from the registry so Swagger UI renders
    /models/switch with a dropdown. The enum is built once at app startup;
    `supervisorctl restart control_plane` after editing models.yaml to
    refresh the dropdown.
    """
    registry = load_registry()
    if not registry:
        return Enum("AvailableModel", {"_none": "__no_models_registered__"}, type=str)
    members = {f"m{i}": m["id"] for i, m in enumerate(registry)}
    return Enum("AvailableModel", members, type=str)


AvailableModel = _build_model_choices()


class SwitchRequest(BaseModel):
    model: AvailableModel = Field(
        ...,
        description=(
            "Pick a model from the registry (/workspace/ops/models.yaml). "
            "Edit that file + `supervisorctl restart control_plane` to add or "
            "remove choices."
        ),
    )
    max_len: Optional[int] = Field(
        None,
        description="Override MAX_LEN. Omit to use the registry preset for this model.",
    )
    extra_args: Optional[str] = Field(
        None,
        description="Override VLLM_EXTRA_ARGS. Omit to use the registry preset.",
    )


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/models/available")
def list_available() -> list[dict]:
    registry = load_registry()
    cached = scan_hf_cache()
    env = parse_env_file(ENV_FILE)
    loaded_id = env.get("MODEL")

    seen: set[str] = set()
    items: list[dict] = []
    for m in registry:
        mid = m["id"]
        seen.add(mid)
        items.append({
            "id": mid,
            "label": m.get("label", mid),
            "max_len": m.get("max_len"),
            "extra_args": m.get("extra_args", ""),
            "notes": m.get("notes", ""),
            "registered": True,
            "downloaded": mid in cached,
            "loaded": mid == loaded_id,
        })
    for mid in sorted(cached - seen):
        items.append({
            "id": mid,
            "label": mid,
            "max_len": None,
            "extra_args": "",
            "notes": "Found in HF cache; not in registry.",
            "registered": False,
            "downloaded": True,
            "loaded": mid == loaded_id,
        })
    return items


@app.get("/models/loaded")
async def loaded() -> dict:
    env = parse_env_file(ENV_FILE)
    configured = env.get("MODEL")
    served_name = env.get("SERVED_MODEL_NAME", "current")

    serving: Optional[list[str]] = None
    error: Optional[str] = None
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(f"{VLLM_URL}/v1/models")
            if r.status_code == 200:
                serving = [m["id"] for m in r.json().get("data", [])]
            else:
                error = f"HTTP {r.status_code}"
    except Exception as exc:
        error = str(exc)

    return {
        "configured_model": configured,
        "served_model_name": served_name,
        "vllm_reachable": error is None,
        "vllm_error": error,
        "vllm_serving": serving,
    }


@app.post("/models/switch")
def switch(req: SwitchRequest) -> dict:
    model_id = req.model.value  # enum member -> HF id string
    registry = {m["id"]: m for m in load_registry()}
    updates: dict[str, str] = {"MODEL": model_id}

    if req.max_len is not None:
        updates["MAX_LEN"] = str(req.max_len)
    elif model_id in registry and registry[model_id].get("max_len") is not None:
        updates["MAX_LEN"] = str(registry[model_id]["max_len"])

    if req.extra_args is not None:
        updates["VLLM_EXTRA_ARGS"] = req.extra_args
    elif model_id in registry:
        updates["VLLM_EXTRA_ARGS"] = registry[model_id].get("extra_args", "")

    write_env_keys(ENV_FILE, updates)
    result = supervisorctl("restart", "vllm")
    return {
        "updated": updates,
        "supervisorctl": result,
        "hint": "Poll /admin/models/loaded — vLLM typically takes 30-90s to warm up.",
    }


@app.get("/status")
def status() -> dict:
    return {"supervisor": supervisorctl("status")}


@app.get("/logs/{program}")
def logs(program: str, lines: int = 200, stderr: bool = False) -> dict:
    if program not in KNOWN_PROGRAMS:
        raise HTTPException(404, f"Unknown program. Known: {sorted(KNOWN_PROGRAMS)}")
    args = ["tail", f"-{lines}", program]
    if stderr:
        args.append("stderr")
    return {"program": program, "stderr": stderr, "output": supervisorctl(*args)}
