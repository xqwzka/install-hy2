#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "璇蜂娇鐢?root 杩愯姝よ剼鏈?
  exit 1
fi

echo "=== HY2 涓€閿畨瑁呰剼鏈?==="

read -r -p "璇疯緭鍏?UDP 绔彛锛堝洖杞?闅忔満 20000-65535锛? " INPUT_PORT

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
    echo "鏈壘鍒板彲鐢ㄩ殢鏈虹鍙?
    exit 1
  fi
else
  if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || (( INPUT_PORT < 1 || INPUT_PORT > 65535 )); then
    echo "绔彛鏃犳晥: $INPUT_PORT"
    exit 1
  fi
  PORT="$INPUT_PORT"
fi

read -r -p "璇疯緭鍏ュ煙鍚嶏紙鍥炶溅=涓嶄娇鐢ㄥ煙鍚嶏紝鑷姩鑷璇佷功锛? " DOMAIN
read -r -p "璇疯緭鍏ヨ妭鐐瑰悕绉帮紙鍥炶溅=浣跨敤褰撳ぉ鏃ユ湡锛? " PROFILE_NAME
if [[ -z "${PROFILE_NAME}" ]]; then
  PROFILE_NAME="$(date +%F)"
fi
LINK_NAME="${PROFILE_NAME// /_}"

read -r -p "璇疯緭鍏ュ瘑鐮侊紙鍥炶溅=鑷姩闅忔満锛? " PASSWORD
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(openssl rand -hex 12)"
fi

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
if [[ -z "${PUBLIC_IP}" ]]; then
  echo "鏃犳硶妫€娴嬫湇鍔″櫒鍏綉 IP"
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
  read -r -p "璇疯緭鍏?ACME 閭锛堝洖杞?admin@${DOMAIN}锛? " ACME_EMAIL
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
  echo "hysteria-server 鍚姩澶辫触"
  journalctl -u hysteria-server.service -n 50 --no-pager || true
  exit 1
fi

if [[ -z "${DOMAIN}" ]]; then
  HOST="${PUBLIC_IP}"
  EXTRA_QS="insecure=1"
  TLS_DESC="鑷璇佷功锛堝鎴风闇€寮€鍚笉楠岃瘉璇佷功锛?
else
  HOST="${DOMAIN}"
  EXTRA_QS=""
  TLS_DESC="ACME 璇佷功"
fi

echo
echo "================= HY2 閮ㄧ讲瀹屾垚 ================="
echo "鏈嶅姟鍣↖P : ${PUBLIC_IP}"
echo "杩炴帴鍦板潃 : ${HOST}"
echo "UDP绔彛  : ${PORT}"
echo "瀵嗙爜      : ${PASSWORD}"
echo "鑺傜偣鍚嶇О  : ${PROFILE_NAME}"
echo "璇佷功绫诲瀷  : ${TLS_DESC}"
echo
if [[ -n "${EXTRA_QS}" ]]; then
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/?${EXTRA_QS}#${LINK_NAME}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}?${EXTRA_QS}#${LINK_NAME}"
else
  echo "hysteria2://${PASSWORD}@${HOST}:${PORT}/#${LINK_NAME}"
  echo "hy2://${PASSWORD}@${HOST}:${PORT}#${LINK_NAME}"
fi
echo "================================================"