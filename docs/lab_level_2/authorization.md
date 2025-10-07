Готовим собственный CA и перевыпускаем сертификат apiserver (подписанный CA)

Зачем: apiserver должен доверять только клиентам с валидным клиентским сертификатом, а мы — проверять его по ca.crt.
```bash
# пути
sudo mkdir -p /etc/kubernetes/pki
cd /etc/kubernetes/pki

# 1.1 Корневой CA (10 лет)
sudo openssl genrsa -out ca.key 4096
sudo openssl req -x509 -new -nodes -key ca.key -subj "/CN=kubernetes" -days 3650 -out ca.crt

# 1.2 Сертификат kube-apiserver, подписанный CA (1 год, с SAN'ами)
NODE_IP=$(hostname -I | awk '{print $1}')
cat <<EOF | sudo tee apiserver-openssl.cnf >/dev/null
[ req ]
distinguished_name = dn
req_extensions = v3_req
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
IP.3 = 10.0.0.1
EOF

sudo openssl genrsa -out apiserver.key 2048
sudo openssl req -new -key apiserver.key -out apiserver.csr -subj "/CN=kube-apiserver" -config apiserver-openssl.cnf
sudo openssl x509 -req -in apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out apiserver.crt -days 365 -extensions v3_req -extfile apiserver-openssl.cnf
```

Примечание: ранее у тебя был self-signed apiserver.crt. Мы его заменили на сертификат, подписанный ca.crt.
Создаём «админский» клиентский сертификат (группа system:masters)
Зачем: это root-доступ через RBAC (cluster-admin), без включения anonymous.

```bash
cd /etc/kubernetes/pki
sudo openssl genrsa -out admin.key 2048
sudo openssl req -new -key admin.key -out admin.csr -subj "/CN=kubernetes-admin/O=system:masters"
sudo openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 365
sudo chmod 600 admin.key
```

Обновляем staticPod манифест kube-apiserver: включаем mTLS + RBAC, выключаем anonymous
Зачем: строгая аутентификация/авторизация.

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
sudo tee /etc/kubernetes/manifests/kube-apiserver.yaml >/dev/null <<YAML
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

      # ВАЖНО: строгая authN/authZ
      - --client-ca-file=/etc/kubernetes/pki/ca.crt
      - --anonymous-auth=false
      - --authorization-mode=Node,RBAC

      # ServiceAccount (подпись и валидация)
      - --service-account-issuer=https://kubernetes.default.svc.cluster.local
      - --service-account-key-file=/etc/kubernetes/pki/sa.pub
      - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key

      # TLS сервера apiserver (подписан нашим CA)
      - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
      - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    volumeMounts:
      - { name: pki, mountPath: /etc/kubernetes/pki, readOnly: true }
  volumes:
    - { name: pki, hostPath: { path: /etc/kubernetes/pki, type: Directory } }
YAML
```

kubelet пересоздаст под автоматически (staticPod). Дай 10–20 сек и проверь, что 6443 снова слушает:
```bash
ss -lnt | grep ':6443'
```

kubeconfig для kubectl с клиентским сертификатом (без insecure-режима)

Зачем: ходим к API строго по CA и с admin-cert.
```bash
# создадим отдельный контекст admin
kubectl config set-cluster local-secure \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true

kubectl config set-credentials kubernetes-admin \
  --client-certificate=/etc/kubernetes/pki/admin.crt \
  --client-key=/etc/kubernetes/pki/admin.key \
  --embed-certs=true

kubectl config set-context admin@local-secure \
  --cluster=local-secure \
  --user=kubernetes-admin

kubectl config use-context admin@local-secure

# Проверка
kubectl get --raw /healthz
kubectl auth can-i '*' '*' --all-namespaces
```

Ожидаем ok/yes. Если нет — покажи вывод kubectl config view --minify.

(Опционально, но правильно) — дать права scheduler/контроллерам

Чтобы запустить kube-scheduler и kube-controller-manager «по правилам», сделаем для них клиентские сертификаты, kubeconfig’и и RBAC-биндинги.

5.1 Серты и kubeconfig’и

```bash
cd /etc/kubernetes/pki

# scheduler
sudo openssl genrsa -out scheduler.key 2048
sudo openssl req -new -key scheduler.key -out scheduler.csr -subj "/CN=system:kube-scheduler"
sudo openssl x509 -req -in scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out scheduler.crt -days 365

# controller-manager
sudo openssl genrsa -out controller-manager.key 2048
sudo openssl req -new -key controller-manager.key -out controller-manager.csr -subj "/CN=system:kube-controller-manager"
sudo openssl x509 -req -in controller-manager.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out controller-manager.crt -days 365

# kubeconfig'и
sudo tee /etc/kubernetes/scheduler.conf >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: local-secure
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority: /etc/kubernetes/pki/ca.crt
users:
- name: system:kube-scheduler
  user:
    client-certificate: /etc/kubernetes/pki/scheduler.crt
    client-key: /etc/kubernetes/pki/scheduler.key
contexts:
- name: system:kube-scheduler@local-secure
  context:
    cluster: local-secure
    user: system:kube-scheduler
current-context: system:kube-scheduler@local-secure
EOF

sudo tee /etc/kubernetes/controller-manager.conf >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: local-secure
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority: /etc/kubernetes/pki/ca.crt
users:
- name: system:kube-controller-manager
  user:
    client-certificate: /etc/kubernetes/pki/controller-manager.crt
    client-key: /etc/kubernetes/pki/controller-manager.key
contexts:
- name: system:kube-controller-manager@local-secure
  context:
    cluster: local-secure
    user: system:kube-controller-manager
current-context: system:kube-controller-manager@local-secure
EOF
```

RBAC биндинги (k8s имеет готовые ClusterRole’ы; создаём только binding’и)
```bash
# запускать от admin-контекста (system:masters)
kubectl create clusterrolebinding kube-scheduler-binding \
  --clusterrole=system:kube-scheduler \
  --user=system:kube-scheduler

kubectl create clusterrolebinding kube-controller-manager-binding \
  --clusterrole=system:kube-controller-manager \
  --user=system:kube-controller-manager
```