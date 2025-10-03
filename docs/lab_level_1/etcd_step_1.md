etcd как staticPod

Добавляем etcd.yaml в папку манифестов.
Зачем: etcd — «база данных» Kubernetes. 
Туда API-серверу надо писать состояние кластера 

```BASH
# создадим etcd.yaml в репо (kubelet его подхватит сам)
tee /workspaces/my-cs-test/manifests/etcd.yaml >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: etcd
    image: registry.k8s.io/etcd:3.5.12-0
    command:
      - etcd
      - --name=etcd0
      - --data-dir=/var/lib/etcd
      - --advertise-client-urls=http://127.0.0.1:2379
      - --listen-client-urls=http://0.0.0.0:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://127.0.0.1:2380
      - --initial-cluster=etcd0=http://127.0.0.1:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=etcd-cluster
    volumeMounts:
    - name: etcd-data
      mountPath: /var/lib/etcd
  volumes:
  - name: etcd-data
    hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
YAML

# даём kubelet несколько секунд и смотрим:
kubectl -n kube-system get pods -o wide | egrep 'NAME|etcd' || true
```