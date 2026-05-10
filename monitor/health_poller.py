from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(os.environ.get("SANDBOX_ROOT", Path(__file__).resolve().parents[1]))


def _load_dotenv() -> None:
    env_file = ROOT / ".env"
    if not env_file.is_file():
        return
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        os.environ.setdefault(key.strip(), val.strip())


def _atomic_write_state(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def poll_once() -> None:
    _load_dotenv()
    port = int(os.environ.get("NGINX_HTTP_PORT", "80"))
    env_dir = ROOT / "envs"
    env_dir.mkdir(parents=True, exist_ok=True)

    for state_path in sorted(env_dir.glob("*.json")):
        try:
            data = json.loads(state_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        env_id = str(data.get("id", ""))
        if not env_id:
            continue

        url = f"http://127.0.0.1:{port}/env/{env_id}/health"
        started = time.perf_counter()
        status: int | None = None
        err: str | None = None
        try:
            request = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(request, timeout=5) as response:
                status = int(response.status)
        except urllib.error.HTTPError as exc:
            status = int(exc.code)
        except Exception as exc:  # noqa: BLE001
            err = f"{type(exc).__name__}: {exc}"
            status = None

        latency_ms = int((time.perf_counter() - started) * 1000)
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "http_status": status,
            "latency_ms": latency_ms,
            "error": err,
        }

        log_dir = ROOT / "logs" / env_id
        log_dir.mkdir(parents=True, exist_ok=True)
        health_log = log_dir / "health.log"
        with health_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

        success = status is not None and 200 <= status < 300
        tracker_path = log_dir / "health_tracker.json"
        if success:
            tracker: dict = {"failures": 0}
            if tracker_path.is_file():
                try:
                    tracker = json.loads(tracker_path.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    tracker = {"failures": 0}
            tracker["failures"] = 0
            tmp_t = tracker_path.with_suffix(".tmp")
            tmp_t.write_text(json.dumps(tracker) + "\n", encoding="utf-8")
            tmp_t.replace(tracker_path)
            if data.get("status") == "degraded":
                data["status"] = "healthy"
                _atomic_write_state(state_path, data)
            continue

        tracker = {"failures": 0}
        if tracker_path.is_file():
            try:
                tracker = json.loads(tracker_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                tracker = {"failures": 0}
        failures = int(tracker.get("failures", 0)) + 1
        tracker["failures"] = failures
        tmp_t = tracker_path.with_suffix(".tmp")
        tmp_t.write_text(json.dumps(tracker) + "\n", encoding="utf-8")
        tmp_t.replace(tracker_path)

        if failures >= 3 and data.get("status") != "degraded":
            data["status"] = "degraded"
            _atomic_write_state(state_path, data)
            warning = f"[{record['ts']}] WARNING env={env_id} degraded after {failures} consecutive health failures"
            print(warning, file=sys.stderr)


def main() -> None:
    while True:
        try:
            poll_once()
        except Exception as exc:  # noqa: BLE001
            print(f"health_poller error: {exc}", file=sys.stderr)
        time.sleep(30)


if __name__ == "__main__":
    main()
