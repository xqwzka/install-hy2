#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

echo "=== HY2 One-Click Installer ==="

read -r -p "Input UDP port (Enter=random 20000-65535): " INPUT_PORT

pick_random_port() {
  local p
  for _ in $(seq 1 50); do
    p="$(shuf -i 20000-65535 -n 1)"
    if ! ss -H -lun | grep -q ":${p} "; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

if [[ -z "${INPUT_PORT}" ]]; then
  PORT="$(pick_random_port || true)"
  if [[ -z "${PORT:-}" ]]; then
    echo "Failed to find a free random UDP port"
    exit 1
  fi
else
  if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || (( INPUT_PORT < 1 || INPUT_PORT > 65535 )); then
    echo "Invalid port: $INPUT_PORT"
    exit 1
  fi
  PORT="$INPUT_PORT"
fi

read -r -p "Input domain (Enter=use IP + self-signed cert): " DOMAIN
read -r -p "Input password (Enter=random): " PASSWORD
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(openssl rand -hex 12)"
fi

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
if [[ -z "${PUBLIC_IP}" ]]; then
  echo "Cannot detect server IP"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl openssl ca-certificates iproute2 >/dev/null

bash <(curl -fsSL https://get.hy2.sh/) >/dev/null

mkdir -p /etc/hysteria

if [[ -z "${DOMAIN}" ]]; then
  openssl req -x509 -nodes \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=${PUBLIC_IP}" \
    -addext "subjectAltName=IP:${PUBLIC_IP}" >/dev/null 2>&1

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
else
  read -r -p "Input email for ACME (Enter=admin@${DOMAIN}): " ACME_EMAIL
  if [[ -z "${ACME_EMAIL}" ]]; then
    ACME_EMAIL="admin@${DOMAIN}"
  fi

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${ACME_EMAIL}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
fi

if id hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria /etc/hysteria/config.yaml || true
  [[ -f /etc/hysteria/server.crt ]] && chown hysteria:hysteria /etc/hysteria/server.crt || true
  [[ -f /etc/hysteria/server.key ]] && chown hysteria:hysteria /etc/hysteria/server.key || true
fi
[[ -f /etc/hysteria/server.crt ]] && chmod 644 /etc/hysteria/server.crt || true
[[ -f /etc/hysteria/server.key ]] && chmod 600 /etc/hysteria/server.key || true
chmod 644 /etc/hysteria/config.yaml

systemctl daemon-reload
systemctl enable --now hysteria-server.service >/dev/null
systemctl restart hysteria-server.service

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/udp" >/dev/null || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p udp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1 || \
  iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1 || true
fi

sleep 1
if ! systemctl is-active --quiet hysteria-server.service; then
  echo "hysteria-server failed to start"
  journalctl -u hysteria-server.service -n 50 --no-pager || true
  exit 1
fi

if [[ -z "${DOMAIN}" ]]; then
  HOST="${PUBLIC_IP}"
  EXTRA_QS="insecure=1"
else
  HOST="${DOMAIN}"
  EXTRA_QS=""
fi

echo
echo "================= HY2 READY ================="
echo "Server IP : ${PUBLIC_IP}"
echo "Host      : ${HOST}"
echo "UDP Port  : ${PORT}"
echo "Password  : ${PASSWORD}"
if [[ -z "${DOMAIN}" ]]; then
  echo "TLS       : self-signed (insecure=1 required)"
else
  echo "TLS       : ACME domain certificate"
fi
echo
if [[ -n "${EXTRA_QS}" ]]; then
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/?${EXTRA_QS}#hy2-${HOST}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}?${EXTRA_QS}#hy2-${HOST}"
else
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/#hy2-${HOST}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}#hy2-${HOST}"
fi
echo "============================================="