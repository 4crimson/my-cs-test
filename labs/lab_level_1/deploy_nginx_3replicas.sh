#!/usr/bin/env bash
set -euo pipefail

# --- параметры / пути ---
ROOT="$(pwd)"
BIN_DIR="${ROOT}/kubebuilder/bin"
KUBECTL="${BIN_DIR}/kubectl"
NS="demo-nginx"
TMP_KCFG="/tmp/kube-mini-$$.conf"
DEV_TOKEN="1234567890"
CTR="/opt/cni/bin/ctr"
NGINX_IMAGE="docker.io/library/nginx:1.25-alpine"

log(){ echo -e "\e[1;36m[app]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[app]\e[0m $*"; }
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
    token: "${DEV_TOKEN}"
YAML
  chmod 600 "$TMP_KCFG"
  log "API: https://${host_ip}:6443"
}

preflight_cluster() {
  log "Preflight: проверяю ноду и таинты…"

  # 1) снять проблемный таинт
  if "$KUBECTL" --kubeconfig="$TMP_KCFG" describe node | grep -q 'node.cloudprovider.kubernetes.io/uninitialized'; then
    log "Снимаю таинт node.cloudprovider.kubernetes.io/uninitialized со всех нод…"
    "$KUBECTL" --kubeconfig="$TMP_KCFG" taint nodes --all node.cloudprovider.kubernetes.io/uninitialized- || true
  fi

  # 2) предзагрузка nginx образа
  if command -v "$CTR" >/dev/null 2>&1; then
    log "Предзагружаю образ ${NGINX_IMAGE} в containerd…"
    sudo "$CTR" -n k8s.io images pull "${NGINX_IMAGE}" || true
  fi
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
      tolerations:
        - key: "node.cloudprovider.kubernetes.io/uninitialized"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: nginx
          image: docker.io/library/nginx:1.25-alpine
          imagePullPolicy: IfNotPresent
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
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" rollout status deploy/web --timeout=300s || warn "rollout timeout"
}

wait_endpoints() {
  log "Жду появления эндпойнтов web…"
  for i in {1..60}; do
    if "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get endpoints web -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -qE '^[0-9]'; then
      log "Эндпойнты появились."
      return 0
    fi
    sleep 1
  done
  warn "Эндпойнты не появились за ожидаемое время."
  return 1
}

diag_net() {
  log "Проверяю DNS и kube-proxy:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n kube-system get svc kube-dns 2>/dev/null || warn "нет kube-dns"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n kube-system get deploy coredns 2>/dev/null || warn "нет coredns"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n kube-system get ds kube-proxy 2>/dev/null || warn "нет kube-proxy (или он не DaemonSet)"
}

svc_cluster_ip() {
  # $1 = namespace, $2 = service name
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "$1" get svc "$2" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

one_endpoint_ip() {
  # $1 = namespace, $2 = service name
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "$1" get endpoints "$2" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}

show_info() {
  log "Поды:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get pods -o wide || true
  log "Сервис:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get svc web || true
  log "Эндпойнты:"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" get endpoints web || true

  log "Пробный HTTP через временный pod (DNS → ClusterIP → PodIP):"
  # 1) DNS путь
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" run curl --image=curlimages/curl:8.11.1 --restart=Never -it --rm -- \
    sh -lc 'echo "== DNS =="; curl -sS http://web.demo-nginx.svc.cluster.local/ | head -n1' \
    && return 0 || true

  # 2) Путь по ClusterIP
  CIP="$(svc_cluster_ip "${NS}" web)"
  if [ -n "$CIP" ] && [ "$CIP" != "None" ]; then
    log "DNS не сработал. Пробую ClusterIP: ${CIP}"
    "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" run curl --image=curlimages/curl:8.11.1 --restart=Never -it --rm -- \
      sh -lc 'echo "== ClusterIP == ("$CIP")"; curl -sS http://'"$CIP"'/ | head -n1' \
      && return 0 || true
  fi

  # 3) Прямо в Pod IP (из Endpoints)
  EPIP="$(one_endpoint_ip "${NS}" web)"
  if [ -n "$EPIP" ]; then
    log "ClusterIP не сработал. Пробую PodIP: ${EPIP}:80"
    "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" run curl --image=curlimages/curl:8.11.1 --restart=Never -it --rm -- \
      sh -lc 'echo "== PodIP == ("$EPIP")"; curl -sS http://'"$EPIP"':80/ | head -n1' \
      && return 0 || true
  fi

  warn "Не удалось получить ответ ни по DNS, ни по ClusterIP, ни по PodIP."
  echo "Подсказка: установи kube-proxy и CoreDNS, либо используй headless-сервис."
}

main() {
  ensure_kubectl
  HOST_IP="$(detect_host_ip)"
  make_temp_kubeconfig "$HOST_IP"
  "$KUBECTL" --kubeconfig="$TMP_KCFG" get --raw='/readyz?verbose' >/dev/null
  preflight_cluster
  apply_ns
  apply_workload
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" scale deploy web --replicas=0
  sleep 2
  "$KUBECTL" --kubeconfig="$TMP_KCFG" -n "${NS}" scale deploy web --replicas=3
  wait_rollout
  wait_endpoints
  diag_net
  show_info
}

main "$@"
