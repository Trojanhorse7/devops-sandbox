#!/usr/bin/env bash
set -euo pipefail
#
# Outage simulation MUST ONLY target workload containers labeled sandbox.role=workload.
# Control-plane containers (Nginx edge + control API) are rejected in guard_container().

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

docker info >/dev/null 2>&1 || {
  echo "Docker daemon is not reachable (is Docker running?)." >&2
  exit 1
}

TARGET_ENV=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      TARGET_ENV="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${TARGET_ENV}" || -z "${MODE}" ]]; then
  echo "Usage: $0 --env <ENV_ID> --mode <crash|pause|network|recover|stress>" >&2
  exit 2
fi

SIM_DIR="${SANDBOX_ROOT}/envs/.sim"
mkdir -p "${SIM_DIR}"
SIM_FILE="${SIM_DIR}/${TARGET_ENV}"

workload_cid() {
  docker ps -q \
    --filter "label=sandbox.env=${TARGET_ENV}" \
    --filter "label=sandbox.role=workload" \
    | head -n1
}

assert_workload_present() {
  local cid
  cid="$(workload_cid || true)"
  if [[ -z "${cid}" ]]; then
    echo "No active workload container found for ${TARGET_ENV}." >&2
    exit 1
  fi
  printf '%s' "${cid}"
}

guard_container() {
  local cid="$1"
  local name
  name="$(docker inspect --format '{{.Name}}' "${cid}" | sed 's#^/##')"

  if [[ "${name}" == "${NGINX_CONTAINER_NAME}" || "${name}" == "${API_CONTAINER_NAME}" ]]; then
    echo "Refusing to simulate outage on platform container (${name})." >&2
    exit 1
  fi

  local plat
  plat="$(docker inspect --format '{{index .Config.Labels "sandbox.platform"}}' "${cid}")"
  if [[ "${plat}" == "control" ]]; then
    echo "Refusing to simulate outage on control-plane container (${name})." >&2
    exit 1
  fi

  local env_label
  env_label="$(docker inspect --format '{{index .Config.Labels "sandbox.env"}}' "${cid}")"
  if [[ "${env_label}" != "${TARGET_ENV}" ]]; then
    echo "Container ${cid} is not labeled for ${TARGET_ENV}." >&2
    exit 1
  fi
}

NETWORK_NAME="sandbox-net-${TARGET_ENV}"

case "${MODE}" in
  crash)
    cid="$(assert_workload_present)"
    guard_container "${cid}"
    echo "crash" > "${SIM_FILE}.tmp"
    mv -f "${SIM_FILE}.tmp" "${SIM_FILE}"
    docker kill "${cid}" >/dev/null
    echo "crash: sent SIGKILL to ${cid}"
    ;;
  pause)
    cid="$(assert_workload_present)"
    guard_container "${cid}"
    echo "pause" > "${SIM_FILE}.tmp"
    mv -f "${SIM_FILE}.tmp" "${SIM_FILE}"
    docker pause "${cid}" >/dev/null
    echo "pause: froze ${cid}"
    ;;
  network)
    cid="$(assert_workload_present)"
    guard_container "${cid}"
    echo "network" > "${SIM_FILE}.tmp"
    mv -f "${SIM_FILE}.tmp" "${SIM_FILE}"
    docker network disconnect -f "${NETWORK_NAME}" "${cid}" >/dev/null
    echo "network: disconnected ${cid} from ${NETWORK_NAME}"
    ;;
  stress)
    cid="$(assert_workload_present)"
    guard_container "${cid}"
    echo "stress" > "${SIM_FILE}.tmp"
    mv -f "${SIM_FILE}.tmp" "${SIM_FILE}"
    # Lightweight hot loop inside the workload container (no extra packages required).
    docker exec -d "${cid}" sh -c 'while true; do :; done'
    echo "stress: started busy loop inside ${cid} (stop with recover)"
    ;;
  recover)
    if [[ ! -f "${SIM_FILE}" ]]; then
      echo "No simulation state recorded for ${TARGET_ENV}; nothing to recover." >&2
      exit 1
    fi
    prev="$(cat "${SIM_FILE}")"
    cid="$(workload_cid || true)"
    if [[ -z "${cid}" ]]; then
      cname="sandbox-app-${TARGET_ENV}"
      if docker inspect "${cname}" >/dev/null 2>&1; then
        cid="${cname}"
      fi
    fi
    if [[ -z "${cid}" ]]; then
      echo "Workload container not found for recover." >&2
      exit 1
    fi
    full_id="$(docker inspect -f '{{.Id}}' "${cid}")"
    guard_container "${full_id}"

    case "${prev}" in
      crash)
        docker start "${cid}" >/dev/null
        echo "recover: started ${cid} after crash"
        # The log shipper (docker logs -f) died when the container was killed.
        # Restart it now and update the stored PID so destroy_env.sh can clean it up.
        APP_LOG="${SANDBOX_ROOT}/logs/${TARGET_ENV}/app.log"
        mkdir -p "$(dirname "${APP_LOG}")"
        chmod a+rwx "$(dirname "${APP_LOG}")" 2>/dev/null || true
        nohup docker logs -f "${cid}" >> "${APP_LOG}" 2>&1 &
        NEW_LOG_PID=$!
        disown "${NEW_LOG_PID}" 2>/dev/null || true
        echo "recover: restarted log shipper (pid=${NEW_LOG_PID})"
        STATE_PATH="${SANDBOX_ROOT}/envs/${TARGET_ENV}.json"
        if [[ -f "${STATE_PATH}" ]]; then
          python3 - "${STATE_PATH}" "${NEW_LOG_PID}" <<'PY'
import json, os, sys, tempfile
path, new_pid = sys.argv[1], int(sys.argv[2])
try:
    data = json.loads(open(path, encoding="utf-8").read())
except Exception:
    sys.exit(0)
data["log_shipper_pid"] = new_pid
directory = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(prefix=".tmp_", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)
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
        fi
        ;;
      pause)
        docker unpause "${cid}" >/dev/null
        echo "recover: unpaused ${cid}"
        ;;
      network)
        docker network connect "${NETWORK_NAME}" "${cid}" >/dev/null
        echo "recover: reattached ${cid} to ${NETWORK_NAME}"
        ;;
      stress)
        docker exec "${cid}" sh -c 'pkill -f "while true" 2>/dev/null || true' >/dev/null 2>&1 || true
        echo "recover: attempted to stop busy-loop workload in ${cid}"
        ;;
      *)
        echo "Unknown recorded mode '${prev}'." >&2
        exit 1
        ;;
    esac
    rm -f "${SIM_FILE}"
    ;;
  *)
    echo "Unsupported mode: ${MODE}" >&2
    exit 2
    ;;
esac
