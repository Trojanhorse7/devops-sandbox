#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def ttl_remaining(data: dict) -> int:
    created = datetime.fromisoformat(str(data["created_at"]).replace("Z", "+00:00"))
    expires = created + timedelta(seconds=int(data["ttl"]))
    now = datetime.now(timezone.utc)
    return max(0, int((expires - now).total_seconds()))


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    env_dir = root / "envs"
    if not env_dir.exists():
        print("(no envs/ directory yet)")
        return
    rows = sorted(env_dir.glob("*.json"))
    if not rows:
        print("(no active env state files)")
        return

    print(f"{'env_id':<24} {'status':<10} {'ttl_rem_s':>10}  last_health")
    for path in rows:
        data = json.loads(path.read_text(encoding="utf-8"))
        env_id = str(data.get("id", path.stem))
        log_path = root / "logs" / env_id / "health.log"
        last_lines = []
        if log_path.is_file():
            lines = [ln for ln in log_path.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
            last_lines = lines[-3:]
        summary = " | ".join(last_lines) if last_lines else "-"
        print(f"{env_id:<24} {str(data.get('status')):<10} {ttl_remaining(data):>10}  {summary}")


if __name__ == "__main__":
    main()
