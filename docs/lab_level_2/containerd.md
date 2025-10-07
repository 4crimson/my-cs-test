Да, прошлый раз мы действительно «ручками» запускали kube-apiserver (у тебя в логе была длинная команда с флагами --cloud-provider=external, --service-account-issuer=... и т.п.). То есть:

Тогда: аписервер шёл как отдельный процесс, без kubelet и без container runtime. Он слушал 127.0.0.1:6443, kubectl к нему подключался — всё работало, пока процесс жив. Перезапустил Codespaces → процесс исчез.

Сейчас: хотим «правильно», как ты и планировал в задании: kubelet + static Pods. Тогда kubelet сам поднимет etcd, kube-apiserver, kube-scheduler, kube-controller-manager из твоих манифестов в /etc/kubernetes/manifests и будет их поддерживать при рестартах.

Поставить crictl (из релиза)
Зачем: удобно смотреть контейнеры через CRI. Если не хочешь — можно пропустить и использовать ctr.
```bash
# выбери версию (подойдёт v1.30.0)
CRICTL_VERSION=v1.30.0
ARCH=$(dpkg --print-architecture)   # обычно amd64

curl -L -o /tmp/crictl.tgz \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
sudo tar -C /usr/local/bin -xzvf /tmp/crictl.tgz crictl
crictl --version
```

Почему ставим containerd: kubelet создаёт контейнеры не сам, а через CRI. Нужен container runtime (containerd). Без него kubelet не сможет поднять staticPod’ы.

```bash
# Установим/обновим рантайм и crictl (если не ставил)
sudo apt-get update -y
sudo apt-get install -y containerd runc

# Сгенерим конфиг и переключим на cgroupfs (SystemdCgroup=false)
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = false/' /etc/containerd/config.toml  # на всякий случай

# Перезапуск containerd без systemd
sudo pkill containerd || true
sudo nohup containerd >/tmp/containerd.log 2>&1 &

# Проверка сокета CRI
sleep 1
test -S /run/containerd/containerd.sock && echo "containerd socket ok" || echo "containerd socket MISSING"

# Быстрый тест CRI (может вывести пусто — это ок)
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps || true
```

Шаг 2 (продолжение) — запустим kubelet в Codespaces без systemd

Зачем: чтобы kubelet прочитал твои staticPod-манифесты и поднял control plane.

Выполним:
```bash
export CRI_ENDPOINT=unix:///run/containerd/containerd.sock
export MANIFESTS_DIR=/etc/kubernetes/manifests
export NODE_IP=$(hostname -I | awk '{print $1}')

sudo pkill kubelet || true
sudo nohup ./kubebuilder/bin/kubelet \
  --container-runtime-endpoint=${CRI_ENDPOINT} \
  --pod-manifest-path=${MANIFESTS_DIR} \
  --register-node=false \
  --fail-swap-on=false \
  --cgroup-driver=systemd \
  --authentication-token-webhook=false \
  --authorization-mode=AlwaysAllow \
  --cluster-domain=cluster.local \
  --cluster-dns=10.96.0.10 \
  --node-ip=${NODE_IP} \
  --v=2 > /tmp/kubelet.log 2>&1 &
```

Коротко про флаги (понятно и без воды):
```bash
--pod-manifest-path — главное: тут лежат твои манифесты staticPods.

--container-runtime-endpoint — говорим kubelet, где containerd.

--register-node=false — пока аписервер не поднялся, kubelet не будет пытаться зарегистрироваться.

--authorization-mode=AlwaysAllow / --authentication-token-webhook=false — упрощаем, чтобы kubelet не зависел от API на старте.

--node-ip — чтобы apiserver, если у тебя не hostNetwork: true, знал корректный адрес (у control-plane обычно hostNetwork: true, но не мешает).

--cgroup-driver=systemd — совпадает с конфигом containerd, который мы только что включили.
```

Проверка, что control plane поднялся
```bash
# через crictl (если поставил)
sudo crictl --runtime-endpoint ${CRI_ENDPOINT} ps | egrep 'etcd|kube-apiserver|kube-controller-manager|kube-scheduler' || echo "control-plane not visible yet"

# альтернатива через ctr (если crictl нет)
sudo ctr -n k8s.io containers ls | egrep 'etcd|kube-apiserver|kube-controller-manager|kube-scheduler' || true
sudo ctr -n k8s.io tasks ls | egrep 'etcd|kube-apiserver|kube-controller-manager|kube-scheduler' || true

# слушает ли аписервер 6443?
ss -lntp | grep ':6443' || echo "6443 still not listening"
```