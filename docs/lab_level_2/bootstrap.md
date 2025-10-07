Сохраняем bootstrap

sudo rm -f /tmp/containerd.log /tmp/kubelet.log
sudo /usr/bin/env -i HOME="$HOME" PATH="$PATH" TERM="$TERM" SHELL=/bin/bash \
/bin/bash --noprofile --norc /tmp/bootstrap_cp_v2.sh

```bash
cat >/tmp/bootstrap_cp_v2.sh <<'BASH'
#!/usr/bin/env bash
set -euxo pipefail

CRI_ENDPOINT="unix:///run/containerd/containerd.sock"
MANIFESTS_DIR="/etc/kubernetes/manifests"
PKI_DIR="/etc/kubernetes/pki"
NODE_IP="$(hostname -I | awk '{print $1}')"

# --- containerd: install + cgroupfs + snapshotter=native ---
if ! command -v containerd >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y containerd runc
fi
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ]; then
  containerd config default | tee /etc/containerd/config.toml >/dev/null
fi
# Codespaces: без systemd → cgroupfs
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/g' /etc/containerd/config.toml || true
# Overlay внутри overlay ломается → используем native snapshotter
sed -i 's/snapshotter = "overlayfs"/snapshotter = "native"/g' /etc/containerd/config.toml || true

pkill containerd || true
nohup containerd >/tmp/containerd.log 2>&1 &
# ждём сокет
for i in {1..40}; do [ -S /run/containerd/containerd.sock ] && break; sleep 0.5; done
[ -S /run/containerd/containerd.sock ]

# --- базовые директории ---
mkdir -p "$MANIFESTS_DIR" "$PKI_DIR" /var/lib/kubelet /var/lib/kubelet/pods /var/lib/etcd /var/lib/cni /etc/cni/net.d

# --- PKI для apiserver (SA keys + self-signed serving cert) ---
if [ ! -s "$PKI_DIR/sa.key" ]; then
  openssl genrsa -out "$PKI_DIR/sa.key" 2048
  openssl rsa -in "$PKI_DIR/sa.key" -pubout -out "$PKI_DIR/sa.pub"
fi

if [ ! -s "$PKI_DIR/apiserver.key" ] || [ ! -s "$PKI_DIR/apiserver.crt" ]; then
  cat <<EOF > "$PKI_DIR/apiserver-openssl.cnf"
[ req ]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[ dn ]
CN = kube-apiserver
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
IP.1 = 127.0.0.1
IP.2 = ${NODE_IP}
EOF
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$PKI_DIR/apiserver.key" \
    -out "$PKI_DIR/apiserver.crt" \
    -config "$PKI_DIR/apiserver-openssl.cnf"
fi

# --- staticPod: etcd (hostNetwork) ---
cat > "$MANIFESTS_DIR/etcd.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: kube-system
  labels: {tier: control-plane, component: etcd}
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
  - name: etcd
    image: registry.k8s.io/etcd:3.5.12-0
    command: ["etcd",
      "--name=etcd-standalone",
      "--data-dir=/var/lib/etcd",
      "--advertise-client-urls=http://127.0.0.1:2379",
      "--listen-client-urls=http://127.0.0.1:2379",
      "--listen-peer-urls=http://127.0.0.1:2380",
      "--initial-advertise-peer-urls=http://127.0.0.1:2380",
      "--listen-metrics-urls=http://127.0.0.1:2381"]
    volumeMounts:
      - { name: etcd-data, mountPath: /var/lib/etcd }
  volumes:
    - name: etcd-data
      hostPath: { path: /var/lib/etcd, type: DirectoryOrCreate }
YAML

# --- staticPod: kube-apiserver (hostNetwork, AlwaysAllow + anonymous для локалки) ---
cat > "$MANIFESTS_DIR/kube-apiserver.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels: {tier: control-plane, component: kube-apiserver}
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.30.0
    command:
      - kube-apiserver
      - --advertise-address=${NODE_IP}
      - --secure-port=6443
      - --etcd-servers=http://127.0.0.1:2379
      - --service-cluster-ip-range=10.0.0.0/24
      - --allow-privileged=true
      - --authorization-mode=AlwaysAllow
      - --anonymous-auth=true
      - --service-account-issuer=https://kubernetes.default.svc.cluster.local
      - --service-account-key-file=/etc/kubernetes/pki/sa.pub
      - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
      - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
      - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    volumeMounts:
      - { name: pki, mountPath: /etc/kubernetes/pki, readOnly: true }
  volumes:
    - name: pki
      hostPath: { path: /etc/kubernetes/pki, type: Directory }
YAML

# --- kubelet (из kubebuilder/bin) с cgroupfs, без регистрации ноды на первом этапе ---
cd /workspaces/my-cs-test
pkill kubelet || true
nohup ./kubebuilder/bin/kubelet \
  --container-runtime-endpoint="${CRI_ENDPOINT}" \
  --pod-manifest-path="${MANIFESTS_DIR}" \
  --register-node=false \
  --fail-swap-on=false \
  --cgroup-driver=cgroupfs \
  --authentication-token-webhook=false \
  --authorization-mode=AlwaysAllow \
  --cluster-domain=cluster.local \
  --cluster-dns=10.96.0.10 \
  --node-ip="${NODE_IP}" \
  --v=2 >/tmp/kubelet.log 2>&1 &

# --- ждём API:6443 ---
for i in {1..90}; do
  if ss -lnt | grep -q ':6443'; then break; fi
  sleep 1
done
ss -lnt | grep ':6443' >/dev/null

# --- kubectl context (локально, без валидации серта) ---
kubectl config set-cluster local --server=https://127.0.0.1:6443 --insecure-skip-tls-verify=true
kubectl config set-context local --cluster=local
kubectl config use-context local
kubectl get --raw /healthz || true
BASH
chmod +x /tmp/bootstrap_cp_v2.sh
sudo /tmp/bootstrap_cp_v2.sh
```