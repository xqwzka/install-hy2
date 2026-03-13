#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root" >&2
  exit 1
fi

IP="${1:-}"
PORT="${2:-}"
PASSWORD="${3:-}"

install_hy2() {
  local ip="$IP"
  local port="$PORT"
  local password="$PASSWORD"

  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  fi

  if [[ -z "$ip" ]]; then
    echo "Unable to detect public IPv4. Usage: $0 <SERVER_IP> [PORT] [PASSWORD]" >&2
    exit 1
  fi

  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Invalid IPv4: $ip" >&2
    exit 1
  fi

  if [[ -z "$port" ]]; then
    for _ in $(seq 1 30); do
      local candidate
      candidate="$(shuf -i 20000-65535 -n 1)"
      if ! ss -H -lun | grep -q ":${candidate} "; then
        port="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$port" ]]; then
    echo "Failed to pick a free UDP port" >&2
    exit 1
  fi

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "Invalid port: $port" >&2
    exit 1
  fi

  if [[ -z "$password" ]]; then
    password="$(openssl rand -hex 12)"
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl openssl ca-certificates iproute2 >/dev/null

  bash <(curl -fsSL https://get.hy2.sh/) >/dev/null

  mkdir -p /etc/hysteria

  openssl req -x509 -nodes \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=${ip}" \
    -addext "subjectAltName=IP:${ip}" >/dev/null 2>&1

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${port}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF

  if id hysteria >/dev/null 2>&1; then
    chown hysteria:hysteria /etc/hysteria/config.yaml /etc/hysteria/server.crt /etc/hysteria/server.key
  fi
  chmod 644 /etc/hysteria/config.yaml /etc/hysteria/server.crt
  chmod 600 /etc/hysteria/server.key

  systemctl daemon-reload
  systemctl enable --now hysteria-server.service >/dev/null
  systemctl restart hysteria-server.service

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/udp" >/dev/null || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || \
    iptables -I INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
  fi

  sleep 1
  if ! systemctl is-active --quiet hysteria-server.service; then
    echo "hysteria-server failed to start" >&2
    journalctl -u hysteria-server.service -n 50 --no-pager >&2 || true
    exit 1
  fi

  cat <<EOF
================= HY2 READY =================
Server IP: ${ip}
UDP Port : ${port}
Password : ${password}

Import URL (hysteria2://):
hysteria2://${password}@${ip}:${port}/?insecure=1#hy2-${ip}

Import URL (hy2://):
hy2://${password}@${ip}:${port}?insecure=1#hy2-${ip}
=============================================
EOF
}

install_3xui() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl >/dev/null

  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

  cat <<'EOF'
================ 3X-UI DONE ================
3x-ui installer has finished.
If menu did not auto-open, run: x-ui
============================================
EOF
}

show_menu() {
  cat <<'EOF'
??????????
1) ?? HY2??????????
2) ?? 3x-ui
EOF
  read -r -p "???? [1-2]: " choice
  case "$choice" in
    1) install_hy2 ;;
    2) install_3xui ;;
    *) echo "????: $choice" >&2; exit 1 ;;
  esac
}

show_menu
