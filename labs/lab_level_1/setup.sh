#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Мини-кластер Kubernetes (amd64) на containerd + kubelet
# Control plane как static pods: etcd, kube-apiserver, kcm, ksched
# Авторизация: токен 1234567890 (только для dev!)
# ------------------------------------------------------------

K8S_VER="v1.30.0"
ETCD_IMG="registry.k8s.io/etcd:3.5.12-0"
APISERVER_IMG="registry.k8s.io/kube-apiserver:${K8S_VER}"
KCM_IMG="registry.k8s.io/kube-controller-manager:${K8S_VER}"
SCHED_IMG="registry.k8s.io/kube-scheduler:${K8S_VER}"
PAUSE_IMG="registry.k8s.io/pause:3.10"

ROOT="$(pwd)"
BIN_DIR="${ROOT}/kubebuilder/bin"
CNI_DIR="/opt/cni"
CONTAINERD_BIN="${CNI_DIR}/bin/containerd"
CTR_BIN="${CNI_DIR}/bin/ctr"
RUNC_BIN="${CNI_DIR}/bin/runc"

KUBE_DIR="/etc/kubernetes"
PKI_DIR="${KUBE_DIR}/pki"
MANIFESTS_DIR="${KUBE_DIR}/manifests"
KUBELET_DIR="/var/lib/kubelet"
ETCD_DATA="${ROOT}/etcd"
CONTAINERD_STATE="/run/containerd"
CONTAINERD_CONF="/etc/containerd/config.toml"
CNI_CONF_DIR="/etc/cni/net.d"

DEV_TOKEN="1234567890"

log()  { echo -e "\e[1;32m[mini-k8s]\e[0m $*"; }
warn() { echo -e "\e[1;33m[mini-k8s]\e[0m $*"; }
err()  { echo -e "\e[1;31m[mini-k8s]\e[0m $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Требуется команда: $1"; exit 1; }; }
is_valid_pem() { sudo head -n1 "$1" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; }

detect_host_ip() {
  # В Codespaces надёжнее так, чем hostname -I
  HOST_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1); exit}}' || true)"
  if [[ -z "${HOST_IP:-}" ]]; then HOST_IP="$(hostname -I | awk '{print $1}')"; fi
  export HOST_IP
  log "HOST_IP=${HOST_IP}"
}

tune_sysctls() {
  log "Включаю sysctl для CNI…"
  # ip_forward и bridge-nf вызовы, чтобы pod-to-pod и SNAT работали
  echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
  sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true
}

install_prereqs() {
  log "Создаю каталоги…"
  sudo mkdir -p "${BIN_DIR}" "${KUBE_DIR}" "${PKI_DIR}" "${MANIFESTS_DIR}" \
               "${KUBELET_DIR}/pki" "${KUBELET_DIR}/pods" \
               "${CNI_DIR}/bin" "${CNI_CONF_DIR}" \
               /var/lib/containerd "${CONTAINERD_STATE}" \
               /var/log/kubernetes /var/log
  sudo chmod -R 755 "${CNI_DIR}"
  sudo chmod 711 /var/lib/containerd

  if [ ! -f "${BIN_DIR}/kubectl" ]; then
    log "Скачиваю kubectl ${K8S_VER}…"
    sudo curl -fsSL "https://dl.k8s.io/${K8S_VER}/bin/linux/amd64/kubectl" -o "${BIN_DIR}/kubectl"
    sudo chmod 755 "${BIN_DIR}/kubectl"
  fi
  if [ ! -f "${BIN_DIR}/kubelet" ]; then
    log "Скачиваю kubelet ${K8S_VER}…"
    sudo curl -fsSL "https://dl.k8s.io/${K8S_VER}/bin/linux/amd64/kubelet" -o "${BIN_DIR}/kubelet"
    sudo chmod 755 "${BIN_DIR}/kubelet"
  fi

  if [ ! -x "${CONTAINERD_BIN}" ]; then
    log "Устанавливаю containerd (static) v2.0.5…"
    curl -fsSL https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-static-2.0.5-linux-amd64.tar.gz -o /tmp/containerd.tgz
    sudo tar zxf /tmp/containerd.tgz -C "${CNI_DIR}/bin"
    rm -f /tmp/containerd.tgz
  fi
  if [ ! -x "${RUNC_BIN}" ]; then
    log "Устанавливаю runc v1.2.6…"
    sudo curl -fsSL "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64" -o "${RUNC_BIN}"
    sudo chmod 755 "${RUNC_BIN}"
  fi

  if [ ! -f "${CNI_DIR}/bin/bridge" ]; then
    log "Устанавливаю CNI плагины v1.6.2…"
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -o /tmp/cni.tgz
    sudo tar zxf /tmp/cni.tgz -C "${CNI_DIR}/bin"
    rm -f /tmp/cni.tgz
  fi
}

write_cni_config() {
  log "Пишу CNI конфиг (bridge)…"
  cat <<EOF | sudo tee "${CNI_CONF_DIR}/10-mynet.conf" >/dev/null
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.22.0.0/16",
    "routes": [{ "dst": "0.0.0.0/0" }]
  }
}
EOF
}

write_containerd_config() {
  if [ -f "${CONTAINERD_CONF}" ]; then
    log "containerd config уже есть"
    return
  fi
  log "Пишу containerd config…"
  sudo mkdir -p "$(dirname "${CONTAINERD_CONF}")"
  cat <<EOF | sudo tee "${CONTAINERD_CONF}" >/dev/null
version = 3

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins."io.containerd.cri.v1.runtime"]
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true

[plugins."io.containerd.cri.v1.images"]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true

[plugins."io.containerd.cri.v1.runtime".cni]
  bin_dir  = "${CNI_DIR}/bin"
  conf_dir = "${CNI_CONF_DIR}"

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
}

start_containerd() {
  if pgrep -xf "${CONTAINERD_BIN} -c ${CONTAINERD_CONF}" >/dev/null 2>&1; then
    log "containerd уже запущен"
  else
    log "Стартую containerd…"
    nohup "${CONTAINERD_BIN}" -c "${CONTAINERD_CONF}" >/var/log/containerd.log 2>&1 & disown
    for i in {1..30}; do
      [ -S /run/containerd/containerd.sock ] && break || sleep 1
    done
  fi
}

gen_pki_and_tokens() {
  log "Генерация ключей/сертификатов и токена…"
  # SA ключи
  if [ ! -f "${PKI_DIR}/sa.key" ]; then
    sudo openssl genrsa -out "${PKI_DIR}/sa.key" 2048
    sudo openssl rsa -in "${PKI_DIR}/sa.key" -pubout -out "${PKI_DIR}/sa.pub"
    sudo chmod 600 "${PKI_DIR}/sa.key"
    sudo chmod 644 "${PKI_DIR}/sa.pub"
  fi

  # CA (создаём если нет или файл не валиден)
  if [ ! -f "${PKI_DIR}/ca.crt" ] || ! is_valid_pem "${PKI_DIR}/ca.crt"; then
    warn "Пересоздаю CA (/etc/kubernetes/pki/ca.crt)…"
    sudo openssl genrsa -out "${PKI_DIR}/ca.key" 2048
    sudo openssl req -x509 -new -nodes -key "${PKI_DIR}/ca.key" -subj "/CN=mini-k8s-ca" -days 365 -out "${PKI_DIR}/ca.crt"
    sudo chmod 600 "${PKI_DIR}/ca.key"
    sudo chmod 644 "${PKI_DIR}/ca.crt"
  fi

  # kubelet должен видеть clientCAFile — копии
  sudo mkdir -p "${KUBELET_DIR}/pki"
  sudo install -m 0644 "${PKI_DIR}/ca.crt" "${KUBELET_DIR}/ca.crt"
  sudo install -m 0644 "${PKI_DIR}/ca.crt" "${KUBELET_DIR}/pki/ca.crt"

  # kubelet serving cert (до старта kubelet!)
  if [ ! -f "${KUBELET_DIR}/pki/kubelet.crt" ] || [ ! -f "${KUBELET_DIR}/pki/kubelet.key" ]; then
    log "Генерирую self-signed сертификат для kubelet сервера…"
    sudo openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${KUBELET_DIR}/pki/kubelet.key" \
      -out    "${KUBELET_DIR}/pki/kubelet.crt" \
      -days 365 -subj "/CN=$(hostname)"
    sudo chmod 600 "${KUBELET_DIR}/pki/kubelet.key"
    sudo chmod 644 "${KUBELET_DIR}/pki/kubelet.crt"
  fi

  # dev токен
  echo "${DEV_TOKEN},admin,admin,system:masters" | sudo tee "${KUBE_DIR}/token.csv" >/dev/null
  sudo chmod 600 "${KUBE_DIR}/token.csv"
}

write_kubelet_config() {
  log "Пишу kubelet config…"
  cat <<EOF | sudo tee "${KUBELET_DIR}/config.yaml" >/dev/null
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "${KUBELET_DIR}/ca.crt"
authorization:
  mode: AlwaysAllow
clusterDomain: "cluster.local"
clusterDNS:
  - "10.0.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
failSwapOn: false
seccompDefault: true
serverTLSBootstrap: false
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
staticPodPath: "${MANIFESTS_DIR}"
cgroupDriver: "systemd"
EOF
  sudo chmod 644 "${KUBELET_DIR}/config.yaml"
}

write_shared_kubeconfigs() {
  log "Пишу kubeconfigs (kubectl/kcm/ksched)…"
  sudo mkdir -p /root/.kube
  "${BIN_DIR}/kubectl" config set-cluster mini --server="https://${HOST_IP}:6443" --insecure-skip-tls-verify=true
  "${BIN_DIR}/kubectl" config set-credentials dev --token="${DEV_TOKEN}"
  "${BIN_DIR}/kubectl" config set-context mini --cluster=mini --user=dev --namespace=default
  "${BIN_DIR}/kubectl" config use-context mini

  # kubeconfig для kubelet — должен существовать до запуска
  sudo install -m 0644 -D /root/.kube/config "${KUBELET_DIR}/kubeconfig"

  cat <<EOF | sudo tee "${KUBE_DIR}/controller-manager.kubeconfig" >/dev/null
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://${HOST_IP}:6443
  name: mini
contexts:
- context:
    cluster: mini
    user: dev
  name: mini
current-context: mini
users:
- name: dev
  user:
    token: "${DEV_TOKEN}"
EOF

  sudo cp -f "${KUBE_DIR}/controller-manager.kubeconfig" "${KUBE_DIR}/scheduler.kubeconfig"
}

write_static_pods() {
  local NODE_NAME; NODE_NAME="$(hostname)"
  log "Пишу static pod манифесты…"

  # etcd
  cat <<EOF | sudo tee "${MANIFESTS_DIR}/etcd.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: etcd-${NODE_NAME}
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: etcd
    image: ${ETCD_IMG}
    command:
    - etcd
    - --advertise-client-urls=http://${HOST_IP}:2379
    - --listen-client-urls=http://0.0.0.0:2379
    - --listen-peer-urls=http://0.0.0.0:2380
    - --initial-advertise-peer-urls=http://${HOST_IP}:2380
    - --initial-cluster=default=http://${HOST_IP}:2380
    - --initial-cluster-state=new
    - --initial-cluster-token=mini-token
    - --data-dir=/var/lib/etcd
    volumeMounts:
    - name: data
      mountPath: /var/lib/etcd
  volumes:
  - name: data
    hostPath:
      path: ${ETCD_DATA}
      type: DirectoryOrCreate
EOF

  # kube-apiserver
  cat <<EOF | sudo tee "${MANIFESTS_DIR}/kube-apiserver.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver-${NODE_NAME}
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: ${APISERVER_IMG}
    command:
    - kube-apiserver
    - --etcd-servers=http://127.0.0.1:2379
    - --service-cluster-ip-range=10.0.0.0/24
    - --bind-address=0.0.0.0
    - --secure-port=6443
    - --advertise-address=${HOST_IP}
    - --authorization-mode=AlwaysAllow
    - --allow-privileged=true
    - --enable-priority-and-fairness=false
    - --storage-backend=etcd3
    - --storage-media-type=application/json
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --token-auth-file=/etc/kubernetes/token.csv
    - --v=2
    volumeMounts:
    - name: pki
      mountPath: /etc/kubernetes/pki
      readOnly: true
    - name: tokens
      mountPath: /etc/kubernetes/token.csv
      subPath: token.csv
      readOnly: true
  volumes:
  - name: pki
    hostPath:
      path: ${PKI_DIR}
      type: Directory
  - name: tokens
    hostPath:
      path: ${KUBE_DIR}
      type: Directory
EOF

  # kube-controller-manager
  cat <<EOF | sudo tee "${MANIFESTS_DIR}/kube-controller-manager.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager-${NODE_NAME}
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-controller-manager
    image: ${KCM_IMG}
    command:
    - kube-controller-manager
    - --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig
    - --leader-elect=false
    - --service-cluster-ip-range=10.0.0.0/24
    - --cluster-name=kubernetes
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --use-service-account-credentials=true
    - --v=2
    volumeMounts:
    - name: pki
      mountPath: /etc/kubernetes/pki
      readOnly: true
    - name: kc
      mountPath: /etc/kubernetes/controller-manager.kubeconfig
      subPath: controller-manager.kubeconfig
      readOnly: true
  volumes:
  - name: pki
    hostPath:
      path: ${PKI_DIR}
      type: Directory
  - name: kc
    hostPath:
      path: ${KUBE_DIR}
      type: Directory
EOF

  # kube-scheduler
  cat <<EOF | sudo tee "${MANIFESTS_DIR}/kube-scheduler.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler-${NODE_NAME}
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${SCHED_IMG}
    command:
    - kube-scheduler
    - --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
    - --leader-elect=false
    - --v=2
    volumeMounts:
    - name: kc
      mountPath: /etc/kubernetes/scheduler.kubeconfig
      subPath: scheduler.kubeconfig
      readOnly: true
  volumes:
  - name: kc
    hostPath:
      path: ${KUBE_DIR}
      type: Directory
EOF
}

prepull_images() {
  log "Предзагрузка образов control-plane… (best-effort)"
  "${CTR_BIN}" -n k8s.io images pull "${ETCD_IMG}" || true
  "${CTR_BIN}" -n k8s.io images pull "${APISERVER_IMG}" || true
  "${CTR_BIN}" -n k8s.io images pull "${KCM_IMG}" || true
  "${CTR_BIN}" -n k8s.io images pull "${SCHED_IMG}" || true
  "${CTR_BIN}" -n k8s.io images pull "${PAUSE_IMG}" || true
}

start_kubelet() {
  if pgrep -f "${BIN_DIR}/kubelet .*--config=${KUBELET_DIR}/config.yaml" >/dev/null 2>&1; then
    log "kubelet уже запущен"; return; fi

  [ -f "${KUBELET_DIR}/kubeconfig" ] || sudo install -m 0644 -D /root/.kube/config "${KUBELET_DIR}/kubeconfig"
  [ -f "${KUBELET_DIR}/pki/kubelet.crt" ] || err "нет ${KUBELET_DIR}/pki/kubelet.crt"
  [ -f "${KUBELET_DIR}/pki/kubelet.key" ] || err "нет ${KUBELET_DIR}/pki/kubelet.key"
  is_valid_pem "${KUBELET_DIR}/ca.crt" || { err "некорректный ${KUBELET_DIR}/ca.crt"; exit 1; }

  log "Стартую kubelet…"
  local HOSTNAME; HOSTNAME="$(hostname)"

  sudo env PATH="$PATH:${CNI_DIR}/bin:/usr/sbin" bash -c '
nohup "'"${BIN_DIR}"'/kubelet" \
  --config="'"${KUBELET_DIR}"'/config.yaml" \
  --kubeconfig="'"${KUBELET_DIR}"'/kubeconfig" \
  --root-dir="'"${KUBELET_DIR}"'" \
  --cert-dir="'"${KUBELET_DIR}"'/pki" \
  --tls-cert-file="'"${KUBELET_DIR}"'/pki/kubelet.crt" \
  --tls-private-key-file="'"${KUBELET_DIR}"'/pki/kubelet.key" \
  --hostname-override="'"${HOSTNAME}"'" \
  --pod-infra-container-image="'"${PAUSE_IMG}"'" \
  --node-ip="'"${HOST_IP}"'" \
  --max-pods=20 \
  --v=1 >>/var/log/kubelet.log 2>&1 & disown'
}

wait_apiserver() {
  log "Жду готовности API server…"
  for i in {1..120}; do
    if curl -sk "https://${HOST_IP}:6443/readyz" >/dev/null 2>&1; then
      log "API server готов"; return 0; fi
    sleep 1
  done
  warn "API server не ответил за отведённое время"; return 1
}

status() {
  log "Проверка статуса…"
  "${BIN_DIR}/kubectl" get nodes -o wide || true
  "${BIN_DIR}/kubectl" -n kube-system get pods -o wide || true
  "${BIN_DIR}/kubectl" get --raw='/readyz?verbose' || true
}

start() {
  detect_host_ip
  tune_sysctls
  install_prereqs
  write_cni_config
  write_containerd_config
  start_containerd
  gen_pki_and_tokens
  write_kubelet_config
  write_shared_kubeconfigs
  write_static_pods
  prepull_images
  start_kubelet
  wait_apiserver || true
  status
}

stop() {
  log "Останавливаю kubelet и containerd…"
  sudo pkill -f "${BIN_DIR}/kubelet" || true
  sudo pkill -xf "${CONTAINERD_BIN} -c ${CONTAINERD_CONF}" || true
  sleep 1
  log "Остановлено."
}

cleanup() {
  stop
  log "Чищу данные и размонтирую…"
  for m in $(mount | awk '/containerd|kubelet/ {print $3}' | sort -r | uniq); do
    sudo umount -lf "$m" || true
  done
  sudo rm -rf "${ETCD_DATA}"
  sudo rm -rf "${MANIFESTS_DIR}"/* || true
  sudo rm -rf "${KUBELET_DIR}"/* || true
  sudo rm -f  "${KUBE_DIR}/controller-manager.kubeconfig" \
              "${KUBE_DIR}/scheduler.kubeconfig" \
              "${KUBE_DIR}/token.csv"
  sudo rm -rf "${CONTAINERD_STATE}" || true
  sudo rm -rf /var/run/containerd || true
  log "Готово."
}

case "${1:-}" in
  start)   start   ;;
  stop)    stop    ;;
  cleanup) cleanup ;;
  status)  status  ;;
  *)
    echo "Usage: $0 {start|stop|cleanup|status}"
    exit 1
    ;;
esac

