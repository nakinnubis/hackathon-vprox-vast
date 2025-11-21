#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG – EDIT THESE VALUES
########################################

# Vast serverless gateway config
# Set this to your endpoint api_key from `vastai show endpoints` (api_key field)
export VAST_API_KEY="${VAST_API_KEY}"

# Set this to your endpoint_name from `vastai show endpoints` (endpoint_name field)
export VAST_ENDPOINT_NAME="${VAST_ENDPOINT_NAME}"

# Set this to the HTTP path your PyWorker serves on the worker
# For instance: /v1/completions or /v1/chat/completions
export WORKER_PATH="${WORKER_PATH}"
# HTTP gateway bind
export GATEWAY_HOST="0.0.0.0"
export GATEWAY_PORT="8001"

# Tinyproxy auth and port
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_USER="${PROXY_USER:-proxyuser}"
PROXY_PASS="${PROXY_PASS:-proxypass}"

########################################
# 1) Install system packages and Python deps
########################################

echo "[startup] updating apt and installing tinyproxy, curl, python3, pip..."
apt-get update -y
apt-get install -y tinyproxy curl python3 python3-pip

pip3 install --no-cache-dir requests

########################################
# 2) Configure and start Tinyproxy (HTTP proxy on port 3128)
########################################

echo "[startup] configuring tinyproxy on port ${PROXY_PORT}..."

cat >/etc/tinyproxy/tinyproxy.conf <<EOF
User nobody
Group nogroup

Port ${PROXY_PORT}
Listen 0.0.0.0

Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info

MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10

Allow 0.0.0.0/0

ConnectPort 443
ConnectPort 563

BasicAuth ${PROXY_USER} ${PROXY_PASS}
EOF

echo "[startup] restarting tinyproxy..."
service tinyproxy restart || systemctl restart tinyproxy || true

echo "[startup] testing tinyproxy locally..."
curl -sS -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT}" https://ifconfig.me || echo "[startup] local proxy test FAILED"

PUBLIC_IP="$(curl -s https://ifconfig.me || echo unknown)"
echo "[startup] proxy egress public_ip=${PUBLIC_IP} port=${PROXY_PORT} user=${PROXY_USER}"
echo "[startup] allow-list this IP in your upstream API: ${PUBLIC_IP}"

########################################
# 3) Write gateway.py (Serverless HTTP gateway)
########################################

mkdir -p /opt/gateway

cat >/opt/gateway/gateway.py <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict

import requests

ROUTE_URL = "https://run.vast.ai/route/"
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "60.0"))

VAST_API_KEY = os.getenv("VAST_API_KEY")
ENDPOINT_NAME = os.getenv("VAST_ENDPOINT_NAME")
WORKER_PATH = os.getenv("WORKER_PATH", "/")

if not VAST_API_KEY or not ENDPOINT_NAME:
    print("[gateway] ERROR: VAST_API_KEY and VAST_ENDPOINT_NAME must be set", file=sys.stderr)
    sys.exit(1)


def call_route(cost: float = 1.0) -> Dict[str, Any]:
    headers = {
        "Authorization": f"Bearer {VAST_API_KEY}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    body = {"endpoint": ENDPOINT_NAME, "cost": cost}
    resp = requests.post(ROUTE_URL, headers=headers, json=body, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    data = resp.json()
    if "url" not in data or "signature" not in data:
        raise RuntimeError(f"/route/ did not return a worker: {data}")
    return data


def call_worker(route_data: Dict[str, Any], client_payload: Dict[str, Any]) -> requests.Response:
    worker_url = route_data["url"]
    signature = route_data["signature"]
    cost = route_data["cost"]
    endpoint = route_data["endpoint"]
    reqnum = route_data["reqnum"]
    request_idx = route_data.get("request_idx")

    url = worker_url.rstrip("/") + WORKER_PATH

    auth_data = {
        "signature": signature,
        "cost": cost,
        "endpoint": endpoint,
        "reqnum": reqnum,
        "url": worker_url,
    }
    if request_idx is not None:
        auth_data["request_idx"] = request_idx

    body = {
        "auth_data": auth_data,
        "payload": client_payload,
    }

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    return requests.post(url, headers=headers, json=body, timeout=REQUEST_TIMEOUT)


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "VastGateway/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        msg = fmt % args
        print(f"[gateway] {self.address_string()} - {msg}", flush=True)

    def _json_response(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path != "/healthz":
            self.send_error(HTTPStatus.NOT_FOUND, "unknown path")
            return
        self._json_response(HTTPStatus.OK, {"status": "ok"})

    def do_POST(self) -> None:
        if self.path != "/proxy":
            self.send_error(HTTPStatus.NOT_FOUND, "unknown path")
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            client_payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.send_error(HTTPStatus.BAD_REQUEST, "invalid JSON")
            return

        try:
            route_data = call_route(cost=1.0)
        except Exception as exc:
            self._json_response(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": "route_failed", "detail": repr(exc)},
            )
            return

        try:
            worker_resp = call_worker(route_data, client_payload)
        except Exception as exc:
            self._json_response(
                HTTPStatus.BAD_GATEWAY,
                {"error": "worker_request_failed", "detail": repr(exc)},
            )
            return

        body_bytes = worker_resp.content
        content_type = worker_resp.headers.get("Content-Type", "application/json")
        status = worker_resp.status_code

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


def main() -> None:
    host = os.getenv("GATEWAY_HOST", "0.0.0.0")
    port = int(os.getenv("GATEWAY_PORT", "8001"))
    server = ThreadingHTTPServer((host, port), GatewayHandler)
    print(f"[gateway] listening on {host}:{port}, endpoint={ENDPOINT_NAME}, worker_path={WORKER_PATH}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[gateway] shutting down", flush=True)
        server.server_close()


if __name__ == "__main__":
    main()
EOF

chmod +x /opt/gateway/gateway.py

########################################
# 4) Start gateway in background
########################################

echo "[startup] starting gateway on ${GATEWAY_HOST}:${GATEWAY_PORT}..."
nohup python3 /opt/gateway/gateway.py > /var/log/gateway.log 2>&1 &

echo "[startup] gateway started. Logs: /var/log/gateway.log"
