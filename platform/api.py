from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

ROOT = Path(os.environ.get("SANDBOX_ROOT", Path(__file__).resolve().parents[1]))


def _run_script(rel: str, *args: str, timeout: int = 600) -> str:
    script = ROOT / "platform" / rel
    result = subprocess.run(
        ["bash", str(script), *[str(a) for a in args]],
        cwd=str(ROOT),
        env={**os.environ, "SANDBOX_ROOT": str(ROOT)},
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() or f"exit {result.returncode}"
        raise HTTPException(status_code=500, detail=detail)
    return (result.stdout or "").strip()


def _state_path(env_id: str) -> Path:
    return ROOT / "envs" / f"{env_id}.json"


def _load_state(env_id: str) -> dict[str, Any]:
    path = _state_path(env_id)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="environment not found")
    return json.loads(path.read_text(encoding="utf-8"))


def _atomic_write_state(data: dict[str, Any]) -> None:
    path = ROOT / "envs" / f"{data['id']}.json"
    tmp = path.with_suffix(".json.tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)
    try:
        path.chmod(0o644)
    except OSError:
        pass


def _ttl_remaining_seconds(data: dict[str, Any]) -> int:
    created = datetime.fromisoformat(str(data["created_at"]).replace("Z", "+00:00"))
    expires = created + timedelta(seconds=int(data["ttl"]))
    now = datetime.now(timezone.utc)
    return max(0, int((expires - now).total_seconds()))


class CreateEnvBody(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    ttl: int | None = Field(default=1800, ge=60, le=86400)


class OutageBody(BaseModel):
    mode: str = Field(min_length=1, max_length=32)


app = FastAPI(title="devops-sandbox control", version="1.0.0")


@app.post("/envs")
def create_env(body: CreateEnvBody) -> dict[str, Any]:
    ttl = body.ttl if body.ttl is not None else 1800
    output = _run_script("create_env.sh", body.name, str(ttl))
    env_id = None
    url = None
    for line in output.splitlines():
        if line.startswith("URL:"):
            url = line.split(":", 1)[1].strip()
        elif line.strip().startswith("Created environment"):
            try:
                env_id = line.split("(", 1)[1].split(")", 1)[0].strip()
            except IndexError:
                env_id = None
    if not env_id:
        raise HTTPException(status_code=500, detail="could not parse env id from create output")
    state = _load_state(env_id)
    return {**state, "url": url}


@app.get("/envs")
def list_envs() -> dict[str, Any]:
    envs: list[dict[str, Any]] = []
    env_dir = ROOT / "envs"
    if not env_dir.exists():
        return {"envs": []}
    for path in sorted(env_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if "id" not in data:
            continue
        envs.append(
            {
                "id": data["id"],
                "name": data.get("name"),
                "status": data.get("status"),
                "ttl_remaining_seconds": _ttl_remaining_seconds(data),
                "created_at": data.get("created_at"),
                "ttl": data.get("ttl"),
            }
        )
    return {"envs": envs}


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str) -> dict[str, str]:
    _ = _load_state(env_id)
    out = _run_script("destroy_env.sh", env_id)
    return {"id": env_id, "message": out}


@app.get("/envs/{env_id}/logs")
def env_logs(env_id: str) -> dict[str, Any]:
    _ = _load_state(env_id)
    log_path = ROOT / "logs" / env_id / "app.log"
    if not log_path.is_file():
        return {"id": env_id, "lines": []}
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    return {"id": env_id, "lines": lines[-100:]}


@app.get("/envs/{env_id}/health")
def env_health(env_id: str) -> dict[str, Any]:
    _ = _load_state(env_id)
    health_path = ROOT / "logs" / env_id / "health.log"
    if not health_path.is_file():
        return {"id": env_id, "checks": []}
    checks: list[dict[str, Any]] = []
    for line in health_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
            checks.append(payload)
        except json.JSONDecodeError:
            checks.append({"raw": line})
    return {"id": env_id, "checks": checks[-10:]}


@app.post("/envs/{env_id}/outage")
def trigger_outage(env_id: str, body: OutageBody) -> dict[str, Any]:
    _ = _load_state(env_id)
    mode = body.mode.strip().lower()
    out = _run_script("simulate_outage.sh", "--env", env_id, "--mode", mode)
    return {"id": env_id, "mode": mode, "message": out}
