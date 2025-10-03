Создаем kube-apiserver

```BASH
tee /workspaces/my-cs-test/manifests/kube-apiserver.yaml >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    tier: control-plane
    component: kube-apiserver
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.30.0
    command:
      - kube-apiserver
      - --etcd-servers=http://127.0.0.1:2379
      - --bind-address=0.0.0.0
      - --secure-port=6443
      - --advertise-address=127.0.0.1
      - --service-cluster-ip-range=10.0.0.0/24
      - --authorization-mode=AlwaysAllow
      - --token-auth-file=/tmp/token.csv
      - --allow-privileged=true
      - --profiling=false
      - --storage-backend=etcd3
      - --storage-media-type=application/json
      - --service-account-issuer=https://kubernetes.default.svc.cluster.local
      - --service-account-key-file=/tmp/sa.pub
      - --service-account-signing-key-file=/tmp/sa.key
      - --v=2
      # ВАЖНО: без --cloud-provider=external (CCM не запускаем)
    volumeMounts:
      - name: host-tmp
        mountPath: /tmp
  volumes:
    - name: host-tmp
      hostPath:
        path: /tmp
        type: Directory
YAML
```

```BASH
# Проверим, что контейнер apiserver появился в containerd
sudo ctr -n k8s.io tasks ls | egrep 'kube-apiserver|etcd' || true
# Или по процессам:
pgrep -fa kube-apiserver || true
```

(Опционально) заранее подтяни образы
```BASH
sudo ctr -n k8s.io images pull registry.k8s.io/etcd:3.5.12-0
sudo ctr -n k8s.io images pull registry.k8s.io/kube-apiserver:v1.30.0
```

Проверь, что контейнеры реально создаются
```BASH
# есть ли задачи containerd?
sudo ctr -n k8s.io tasks ls | egrep 'etcd|kube-apiserver' || true
# слушает ли порт 6443?
ss -lntp | grep 6443 || true
# простая готовность API (без kubectl):
curl -sk https://127.0.0.1:6443/readyz || true
```

Настрой kubectl на локальный API
```BASH
kubectl config set-cluster local --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
kubectl config set-credentials local-admin --token=1234567890
kubectl config set-context local --cluster=local --user=local-admin
kubectl config use-context local
kubectl get --raw='/readyz?verbose'
kubectl get pods -A
```

Настраиваем kubectl на локальный API (с токеном)

Убедимся, что токен есть (он создаётся твоим скриптом в /tmp/token.csv):
```BASH
sudo cat /tmp/token.csv
# Должно быть что-то вроде:
# 1234567890,admin,admin,system:masters
```

Сделаем отдельный контекст local и используем этот токен:
```BASH
kubectl config set-cluster local --server=https://127.0.0.1:6443 --insecure-skip-tls-verify=true
kubectl config set-credentials local-admin --token=$(sudo awk -F, '{print $1}' /tmp/token.csv)
kubectl config set-context local --cluster=local --user=local-admin
kubectl config use-context local
```

Проверка готовности API и базовые списки:
```BASH
kubectl get --raw='/readyz?verbose'
kubectl get pods -A
```
Альтернатива через curl (для контроля):
```BASH
curl -skH "Authorization: Bearer $(sudo awk -F, '
{print $1}' /tmp/token.csv)" https://127.0.0.1:6443/readyz?verbose
```

Почему не «вписать всё в манифест apiserver»?
```
  Флаги apiserver (--token-auth-file, --service-account-*) — серверная сторона. Они говорят «какие токены и как проверять».

  kubectl — клиент, он запускается снаружи и должен знать «куда идти и каким токеном». Эту часть нельзя прописать внутри манифеста сервера — это на твоей машине, в kubeconfig или флагах.

  «Открыть нараспашку» (анонимный доступ, insecure-port 8080) — небезопасно/устарело. Мы этого не делаем.
```

Всё это отлично автоматизируется. Есть три уровня:
```
«Из коробки» — kubeadm/k3s/kind/k3d (быстро поднять кластер).

«Инфра как код» — Kubespray/Ansible/Terraform.

«Ручной контроль, но без рутины» — скрипт/Makefile, который генерит staticPod-манифесты, стартует kubelet, кладёт kubeconfig, деплоит nginx, а по желанию — запускает профилирование.
```
