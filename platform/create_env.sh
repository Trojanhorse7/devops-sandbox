#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $0 <name> [ttl_seconds]" >&2
  exit 2
}

if [[ $# -lt 1 ]]; then
  usage
fi

ENV_NAME="$1"
TTL_SECONDS="${2:-1800}"

if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "TTL must be a positive integer (seconds)." >&2
  exit 2
fi

ENV_ID="env-$(openssl rand -hex 8)"
NETWORK_NAME="sandbox-net-${ENV_ID}"
CONTAINER_NAME="sandbox-app-${ENV_ID}"
NGINX_SNIPPET="${SANDBOX_ROOT}/nginx/conf.d/${ENV_ID}.conf"
STATE_PATH="${SANDBOX_ROOT}/envs/${ENV_ID}.json"
CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${SANDBOX_ROOT}/logs/${ENV_ID}" "${SANDBOX_ROOT}/envs"
# Allow the host-side health poller (non-root) to write health.log / health_tracker.json
chmod a+rwx "${SANDBOX_ROOT}/logs/${ENV_ID}" 2>/dev/null || true

if ! docker image inspect "${DEMO_IMAGE}" >/dev/null 2>&1; then
  docker build -t "${DEMO_IMAGE}" "${SANDBOX_ROOT}/platform/demo"
fi

docker network create "${NETWORK_NAME}"

cleanup_partial() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  rm -f "${NGINX_SNIPPET}" >/dev/null 2>&1 || true
  docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload >/dev/null 2>&1 || true
}

set +e
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  --label "sandbox.env=${ENV_ID}" \
  --label "sandbox.role=workload" \
  -e "SANDBOX_ENV_ID=${ENV_ID}" \
  -e "PORT=8080" \
  "${DEMO_IMAGE}" >/dev/null
run_rc=$?
set -e

if [[ $run_rc -ne 0 ]]; then
  cleanup_partial
  echo "Failed to start workload container for ${ENV_ID}." >&2
  exit 1
fi

cat > "${NGINX_SNIPPET}.tmp" <<EOF
location /env/${ENV_ID}/ {
    proxy_pass http://${CONTAINER_NAME}:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
mv -f "${NGINX_SNIPPET}.tmp" "${NGINX_SNIPPET}"

if ! docker network connect "${NETWORK_NAME}" "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1; then
  cleanup_partial
  echo "Failed to attach edge Nginx to ${NETWORK_NAME} (is '${NGINX_CONTAINER_NAME}' running?)." >&2
  exit 1
fi

if ! docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload >/dev/null 2>&1; then
  cleanup_partial
  echo "Failed to reload Nginx after writing ${NGINX_SNIPPET}." >&2
  exit 1
fi

# nohup: when this script is run via the API (subprocess), bash exits right after and
# would SIGHUP plain background jobs — docker logs would die and app.log stays empty.
nohup docker logs -f "${CONTAINER_NAME}" >> "${SANDBOX_ROOT}/logs/${ENV_ID}/app.log" 2>&1 &
LOG_SHIPPER_PID=$!
disown "${LOG_SHIPPER_PID}" 2>/dev/null || true

PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"name":sys.argv[2],"created_at":sys.argv[3],"ttl":int(sys.argv[4]),"status":"healthy","network":sys.argv[5],"container_name":sys.argv[6],"nginx_snippet":sys.argv[7],"log_shipper_pid":int(sys.argv[8])}))' \
  "${ENV_ID}" "${ENV_NAME}" "${CREATED_AT}" "${TTL_SECONDS}" "${NETWORK_NAME}" "${CONTAINER_NAME}" "${NGINX_SNIPPET}" "${LOG_SHIPPER_PID}")"

sandbox_atomic_write_json "${STATE_PATH}" "${PAYLOAD}"

HOST_LOOPBACK="${PUBLIC_HOST:-127.0.0.1}"
ENV_URL="http://${HOST_LOOPBACK}:${NGINX_HTTP_PORT}/env/${ENV_ID}/"

echo "Created environment '${ENV_NAME}' (${ENV_ID})"
echo "URL: ${ENV_URL}"
echo "TTL: ${TTL_SECONDS}s (cleanup daemon enforces expiry)"
