#!/usr/bin/env bash
set -euo pipefail

PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_USER="${PROXY_USER:-proxyuser}"
PROXY_PASS="${PROXY_PASS:-proxypass}"

echo "[static-proxy] installing tinyproxy..."
apt-get update -y
apt-get install -y tinyproxy curl

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

# Allow all clients (hackathon only; lock this down later)
Allow 0.0.0.0/0

# Allow CONNECT to HTTPS ports
ConnectPort 443
ConnectPort 563

# Simple username/password auth
BasicAuth ${PROXY_USER} ${PROXY_PASS}
EOF

echo "[static-proxy] restarting tinyproxy..."
service tinyproxy restart || systemctl restart tinyproxy || true

echo "[static-proxy] testing proxy locally..."
curl -v -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT}" https://ifconfig.me || echo "[static-proxy] local proxy test FAILED"

PUBLIC_IP="$(curl -s https://ifconfig.me || echo unknown)"
echo "[static-proxy] public_ip=${PUBLIC_IP} port=${PROXY_PORT} user=${PROXY_USER}"
echo "[static-proxy] allow-list this IP in your upstream API: ${PUBLIC_IP}"
