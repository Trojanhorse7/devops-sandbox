#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <env_id>" >&2
  exit 2
fi

ENV_ID="$1"
STATE_PATH="${SANDBOX_ROOT}/envs/${ENV_ID}.json"
ARCHIVE_DIR="${SANDBOX_ROOT}/logs/archived/${ENV_ID}"
SIM_STATE_DIR="${SANDBOX_ROOT}/envs/.sim"

if [[ ! -f "${STATE_PATH}" ]]; then
  echo "Unknown environment: ${ENV_ID}" >&2
  exit 1
fi

LOG_PID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); p=d.get("log_shipper_pid"); print("" if p is None else str(p))' "${STATE_PATH}")"

if [[ -n "${LOG_PID}" ]]; then
  kill "${LOG_PID}" 2>/dev/null || true
fi

mapfile -t TARGETS < <(docker ps -aq --filter "label=sandbox.env=${ENV_ID}" || true)
for cid in "${TARGETS[@]:-}"; do
  [[ -z "${cid}" ]] && continue
  docker rm -f "${cid}" >/dev/null 2>&1 || true
done

NETWORK_NAME="sandbox-net-${ENV_ID}"
if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network disconnect -f "${NETWORK_NAME}" "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
fi

NGINX_SNIPPET="${SANDBOX_ROOT}/nginx/conf.d/${ENV_ID}.conf"
if [[ -f "${NGINX_SNIPPET}" ]]; then
  rm -f "${NGINX_SNIPPET}"
fi

docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload >/dev/null 2>&1 || true

mkdir -p "${ARCHIVE_DIR}"
if [[ -d "${SANDBOX_ROOT}/logs/${ENV_ID}" ]]; then
  # shellcheck disable=SC2086
  mv "${SANDBOX_ROOT}/logs/${ENV_ID}"/* "${ARCHIVE_DIR}/" 2>/dev/null || true
  rmdir "${SANDBOX_ROOT}/logs/${ENV_ID}" 2>/dev/null || true
fi

rm -f "${SIM_STATE_DIR}/${ENV_ID}" 2>/dev/null || true
rm -f "${STATE_PATH}"

echo "Destroyed ${ENV_ID} (logs archived under ${ARCHIVE_DIR})"
