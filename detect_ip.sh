set -euo pipefail

pick_ip() {
  # 1) Любой global IPv4 на поднятых интерфейсах
  ip -4 -o addr show scope global up | awk '{print $4}' | cut -d/ -f1 | head -n1

  # 2) IP, который используется для выхода в интернет
  ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'

  # 3) hostname -I / -i
  hostname -I 2>/dev/null | awk '{print $1}'
  hostname -i 2>/dev/null | awk '{print $1}'

  # 4) через getent
  getent ahostsv4 "$(hostname)" 2>/dev/null | awk '{print $1}' | head -n1
}

HOST_IP=""
while read -r cand; do
  if [ -n "${cand:-}" ] && [ "$cand" != "127.0.0.1" ] && [ "$cand" != "127.0.1.1" ]; then
    HOST_IP="$cand"; break
  fi
done < <(pick_ip)

# Последняя попытка: взять IP у eth0, если есть
if [ -z "$HOST_IP" ]; then
  HOST_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
fi

# Если совсем ничего — фолбэк (локальная учебная схема)
if [ -z "$HOST_IP" ]; then
  HOST_IP="127.0.0.1"
fi

export HOST_IP
echo "HOST_IP=$HOST_IP"
