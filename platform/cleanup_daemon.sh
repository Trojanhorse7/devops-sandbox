#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

mkdir -p "${SANDBOX_ROOT}/logs"

while true; do
  sandbox_ts_log "cleanup_daemon tick"

  shopt -s nullglob
  for state_file in "${SANDBOX_ROOT}"/envs/*.json; do
    [[ -e "${state_file}" ]] || continue
    ENV_ID="$(basename "${state_file}" .json)"

    should_destroy="$(python3 - "${state_file}" <<'PY'
import datetime
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError:
    print("true")
    sys.exit(0)

created = datetime.datetime.fromisoformat(data["created_at"].replace("Z", "+00:00"))
ttl = int(data["ttl"])
expires = created + datetime.timedelta(seconds=ttl)
now = datetime.datetime.now(datetime.timezone.utc)
print("true" if now > expires else "false")
PY
)"

    if [[ "${should_destroy}" == "true" ]]; then
      sandbox_ts_log "destroying ${ENV_ID} (past ttl)"
      set +e
      bash "${SCRIPT_DIR}/destroy_env.sh" "${ENV_ID}"
      rc=$?
      set -e
      sandbox_ts_log "destroy_env ${ENV_ID} exit=${rc}"
    fi
  done
  shopt -u nullglob

  sleep 60
done
