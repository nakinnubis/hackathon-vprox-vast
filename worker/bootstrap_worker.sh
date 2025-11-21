#!/usr/bin/env bash
set -euo pipefail

# These will come from the serverless template / workergroup env config
PROXY_HOST="${PROXY_HOST:?must be set}"
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_AUTH="${PROXY_AUTH:-proxyuser:proxypass}"

PROXY_USER="${PROXY_AUTH%%:*}"
PROXY_PASS="${PROXY_AUTH#*:}"

PROXY_URL="http://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"

export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export ALL_PROXY="${PROXY_URL}"
export NO_PROXY="127.0.0.1,localhost"

echo "[worker-bootstrap] using proxy ${PROXY_URL}"

# Optional: sanity-check egress IP
EGRESS_IP="$(curl -s https://ifconfig.me || echo unknown)"
echo "[worker-bootstrap] observed public_ip=${EGRESS_IP}"

# Where you placed the worker code inside the container
WORKER_APP_PATH="${WORKER_APP_PATH:-/opt/app/worker_static_ip.py}"
export WORKER_HOST="${WORKER_HOST:-0.0.0.0}"
export WORKER_PORT="${WORKER_PORT:-8080}"

echo "[worker-bootstrap] starting worker_static_ip.py on ${WORKER_HOST}:${WORKER_PORT}"
exec python3 "${WORKER_APP_PATH}"
