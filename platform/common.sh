#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _common_dir="$(cd "$(dirname "$0")" && pwd)"
fi

export SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "${_common_dir}/.." && pwd)}"

if [[ -f "${SANDBOX_ROOT}/.env" ]]; then
  # .env often sets SANDBOX_ROOT to the host clone path (patch_env_root / Makefile).
  # When scripts run inside the API container, SANDBOX_ROOT must stay /sandbox (the mount).
  # Preserve the effective root across sourcing so paths stay inside the container filesystem.
  _sandbox_root_effective="${SANDBOX_ROOT}"
  set -a
  # shellcheck disable=SC1090
  source "${SANDBOX_ROOT}/.env"
  set +a
  export SANDBOX_ROOT="${_sandbox_root_effective}"
fi

: "${NGINX_CONTAINER_NAME:=sandbox-nginx}"
: "${NGINX_HTTP_PORT:=80}"
: "${DEMO_IMAGE:=sandbox-demo-app:latest}"
: "${API_CONTAINER_NAME:=sandbox-api}"

export SANDBOX_ROOT NGINX_CONTAINER_NAME NGINX_HTTP_PORT DEMO_IMAGE API_CONTAINER_NAME

sandbox_ts_log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >> "${SANDBOX_ROOT}/logs/cleanup.log"
}

sandbox_atomic_write_json() {
  local target="$1"
  local payload="$2"
  python3 - <<'PY' "$target" "$payload"
import json, os, sys, tempfile

path = sys.argv[1]
data = json.loads(sys.argv[2])
directory = os.path.dirname(path)
os.makedirs(directory, exist_ok=True)

fd, tmp_path = tempfile.mkstemp(prefix=".tmp_", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, path)
    # world-readable so the host-side health poller (non-root) can read state files
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass
finally:
    if os.path.exists(tmp_path):
        try:
            os.remove(tmp_path)
        except OSError:
            pass
PY
}
