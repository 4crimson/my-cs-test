#!/usr/bin/env bash
set -euo pipefail

DEV_TOKEN="1234567890"
ROOT="$(pwd)"
BIN_DIR="${ROOT}/kubebuilder/bin"
KUBECTL="${BIN_DIR}/kubectl"
NS="demo-nginx"
TMP_KCFG="/tmp/kube-mini-$$.conf"
DEV_TOKEN="1234567890"   # тот же, что в /etc/kubernetes/token.csv

log(){ echo -e "\e[1;36m[app]\e[0m $*"; }
cleanup(){ rm -f "$TMP_KCFG"; }
trap cleanup EXIT

detect_host_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1); exit}}' || true)"
  [ -z "$ip" ] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

ensure_kubectl() {
  command -v "$KUBECTL" >/dev/null 2>&1 || { echo "kubectl не найден по пути ${KUBECTL}"; exit 1; }
}

make_temp_kubeconfig() {
  local host_ip="$1"
  cat >"$TMP_KCFG" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: mini
  cluster:
    server: https://${host_ip}:6443
    insecure-skip-tls-verify: true
contexts:
- name: mini
  context:
    cluster: mini
    user: dev
current-context: mini
users:
- name: dev
  user:
    token: "${DEV_TOKEN}"      # <-- ОБЯЗАТЕЛЬНО в кавычках
YAML
  chmod 600 "$TMP_KCFG"
  log "API: https://${host_ip}:6443"
}

apply_ns() {
  log "Создаю/обновляю namespace ${NS}…"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" apply --validate=false -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
YAML
}

apply_workload() {
  log "Деплой deployment+service…"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" apply --validate=false -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
  type: ClusterIP
YAML
}

wait_rollout() {
  log "Жду rollout deployment/web…"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" rollout status deploy/web --timeout=180s
}

show_info() {
  log "Поды:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get pods -o wide
  log "Сервис и эндпойнты:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get svc web
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get endpoints web || true
  log "Пробный HTTP через временный pod:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" run curl --image=curlimages/curl:8.11.1 --restart=Never -it --rm -- \
      sh -lc 'curl -sS http://web.demo-nginx.svc.cluster.local/ | head -n1' || true
}

main() {
  ensure_kubectl
  HOST_IP="$(detect_host_ip)"
  make_temp_kubeconfig "$HOST_IP"
  # sanity check API:
  "$KUBECTL" --kubeconfig="$TMP_KCFG" get --raw='/readyz?verbose' >/dev/null
  apply_ns
  apply_workload
  wait_rollout
  show_info
}

main "$@"
