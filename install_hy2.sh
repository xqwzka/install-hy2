#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo $'\u8bf7\u4f7f\u7528 root \u8fd0\u884c\u6b64\u811a\u672c'
  exit 1
fi

echo $'=== HY2 \u4e00\u952e\u5b89\u88c5\u811a\u672c ==='

read -r -p $'\u8bf7\u8f93\u5165 UDP \u7aef\u53e3\uff08\u56de\u8f66=\u968f\u673a 20000-65535\uff09: ' INPUT_PORT

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
    echo $'\u672a\u627e\u5230\u53ef\u7528\u968f\u673a\u7aef\u53e3'
    exit 1
  fi
else
  if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || (( INPUT_PORT < 1 || INPUT_PORT > 65535 )); then
    echo $'\u7aef\u53e3\u65e0\u6548: '"$INPUT_PORT"
    exit 1
  fi
  PORT="$INPUT_PORT"
fi

read -r -p $'\u8bf7\u8f93\u5165\u57df\u540d\uff08\u56de\u8f66=\u4e0d\u4f7f\u7528\u57df\u540d\uff0c\u81ea\u52a8\u81ea\u7b7e\u8bc1\u4e66\uff09: ' DOMAIN
read -r -p $'\u8bf7\u8f93\u5165\u8282\u70b9\u540d\u79f0\uff08\u56de\u8f66=\u4f7f\u7528\u5f53\u5929\u65e5\u671f\uff09: ' PROFILE_NAME
if [[ -z "${PROFILE_NAME}" ]]; then
  PROFILE_NAME="$(date +%F)"
fi
LINK_NAME="${PROFILE_NAME// /_}"

read -r -p $'\u8bf7\u8f93\u5165\u5bc6\u7801\uff08\u56de\u8f66=\u81ea\u52a8\u968f\u673a\uff09: ' PASSWORD
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(openssl rand -hex 12)"
fi

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
if [[ -z "${PUBLIC_IP}" ]]; then
  echo $'\u65e0\u6cd5\u68c0\u6d4b\u670d\u52a1\u5668\u516c\u7f51 IP'
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
  read -r -p $'\u8bf7\u8f93\u5165 ACME \u90ae\u7bb1\uff08\u56de\u8f66=admin@'"${DOMAIN}"$'\uff09: ' ACME_EMAIL
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
  echo $'hysteria-server \u542f\u52a8\u5931\u8d25'
  journalctl -u hysteria-server.service -n 50 --no-pager || true
  exit 1
fi

if [[ -z "${DOMAIN}" ]]; then
  HOST="${PUBLIC_IP}"
  EXTRA_QS="insecure=1"
  TLS_DESC=$'\u81ea\u7b7e\u8bc1\u4e66\uff08\u5ba2\u6237\u7aef\u9700\u5f00\u542f\u4e0d\u9a8c\u8bc1\u8bc1\u4e66\uff09'
else
  HOST="${DOMAIN}"
  EXTRA_QS=""
  TLS_DESC=$'ACME \u8bc1\u4e66'
fi

echo
echo $'================= HY2 \u90e8\u7f72\u5b8c\u6210 ================='
echo $'\u670d\u52a1\u5668IP : '"${PUBLIC_IP}"
echo $'\u8fde\u63a5\u5730\u5740 : '"${HOST}"
echo $'UDP\u7aef\u53e3  : '"${PORT}"
echo $'\u5bc6\u7801      : '"${PASSWORD}"
echo $'\u8282\u70b9\u540d\u79f0  : '"${PROFILE_NAME}"
echo $'\u8bc1\u4e66\u7c7b\u578b  : '"${TLS_DESC}"
echo
if [[ -n "${EXTRA_QS}" ]]; then
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/?${EXTRA_QS}#${LINK_NAME}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}?${EXTRA_QS}#${LINK_NAME}"
else
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/#${LINK_NAME}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}#${LINK_NAME}"
fi
echo $'================================================'
