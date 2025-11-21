#!/usr/bin/env python3
"""
worker_static_ip.py

Simple Vast serverless worker that:
- Uses the process's HTTP(S) proxy configuration (HTTP_PROXY, HTTPS_PROXY).
- On /ip and /invoke, calls https://ifconfig.me to find the egress IP.
- Echoes the request payload so you can see it's alive.

You will pair this with bootstrap_worker.sh, which sets the proxy env vars.
"""

from __future__ import annotations

import json
import os
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict

import requests

IP_CHECK_URL = os.getenv("IP_CHECK_URL", "https://ifconfig.me")
IP_TIMEOUT = float(os.getenv("IP_CHECK_TIMEOUT", "5"))


def get_public_ip() -> str:
    resp = requests.get(IP_CHECK_URL, timeout=IP_TIMEOUT)
    resp.raise_for_status()
    return resp.text.strip()


class StaticIPHandler(BaseHTTPRequestHandler):
    server_version = "StaticIPWorker/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: D401
        # Less noisy logs in Vast console
        msg = fmt % args
        print(f"[worker] {self.address_string()} - {msg}", flush=True)

    def _json_response(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path not in ("/", "/healthz", "/ip"):
            self.send_error(HTTPStatus.NOT_FOUND, "unknown path")
            return

        try:
            ip = get_public_ip()
        except Exception as exc:  # noqa: BLE001
            self._json_response(
                HTTPStatus.BAD_GATEWAY,
                {"status": "error", "error": f"ip_check_failed: {exc!r}", "timestamp": time.time()},
            )
            return

        self._json_response(
            HTTPStatus.OK,
            {"status": "ok", "public_ip": ip, "timestamp": time.time()},
        )

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in ("/invoke", "/"):
            self.send_error(HTTPStatus.NOT_FOUND, "unknown path")
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}

        worker_payload = body.get("payload", {})
        try:
            ip = get_public_ip()
            status = "ok"
            error = None
        except Exception as exc:  # noqa: BLE001
            ip = None
            status = "error"
            error = f"ip_check_failed: {exc!r}"

        response = {
            "status": status,
            "error": error,
            "echo": worker_payload,
            "public_ip": ip,
            "timestamp": time.time(),
        }
        self._json_response(HTTPStatus.OK, response)


def main() -> None:
    host = os.getenv("WORKER_HOST", "0.0.0.0")
    port = int(os.getenv("WORKER_PORT", "8080"))

    server = ThreadingHTTPServer((host, port), StaticIPHandler)
    print(f"[worker] listening on {host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[worker] shutting down", flush=True)
        server.server_close()


if __name__ == "__main__":
    main()
