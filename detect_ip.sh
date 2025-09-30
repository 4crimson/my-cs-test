# detect_ip.sh (без set -euo pipefail)
pick_ip() {
  ip -4 -o addr show scope global up | awk '{print $4}' | cut -d/ -f1 | head -n1
  ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
  hostname -I 2>/dev/null | awk '{print $1}'
  hostname -i 2>/dev/null | awk '{print $1}'
  getent ahostsv4 "$(hostname)" 2>/dev/null | awk '{print $1}' | head -n1
}

HOST_IP=""
while read -r cand; do
  if [ -n "${cand:-}" ] && [ "$cand" != "127.0.0.1" ] && [ "$cand" != "127.0.1.1" ]; then
    HOST_IP="$cand"; break
  fi
done < <(pick_ip)

[ -z "$HOST_IP" ] && HOST_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
[ -z "$HOST_IP" ] && HOST_IP="127.0.0.1"

# ключевая строка:
echo "export HOST_IP=$HOST_IP"
