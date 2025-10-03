Создай файл в репо (он «подхватится» автоматически):

```bash
tee /workspaces/my-cs-test/manifests/kube-controller-manager.yaml >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
  labels:
    component: kube-controller-manager
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  containers:
  - name: kube-controller-manager
    image: registry.k8s.io/kube-controller-manager:v1.30.0
    command:
      - kube-controller-manager
      - --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig
      - --leader-elect=false
      - --service-cluster-ip-range=10.0.0.0/24
      - --cluster-name=kubernetes
      - --root-ca-file=/etc/kubernetes/pki/ca.crt
      - --service-account-private-key-file=/tmp/sa.key
      - --use-service-account-credentials=true
      - --v=2
    volumeMounts:
      - name: pki
        mountPath: /etc/kubernetes/pki
        readOnly: true
      - name: kc
        mountPath: /etc/kubernetes/controller-manager.kubeconfig
        readOnly: true
      - name: hosttmp
        mountPath: /tmp
  volumes:
    - name: pki
      hostPath:
        path: /var/lib/kubelet/pki         # ЭТО ДИРЕКТОРИЯ
        type: Directory
    - name: kc
      hostPath:
        path: /var/lib/kubelet/kubeconfig  # ЭТО ФАЙЛ
        type: File
    - name: hosttmp
      hostPath:
        path: /tmp
        type: Directory
YAML
```

kubeconfig мы берём тот же, что setup.sh скопировал в /var/lib/kubelet/kubeconfig, CA — в /var/lib/kubelet/pki/ca.crt, ключ SA — в /tmp/sa.key. Всё это твой скрипт уже подготовил.

Проверяем, что стартовал
```bash
kubectl -n kube-system get pods -o wide | egrep 'NAME|kube-(controller)' || true
kubectl get --raw='/readyz?verbose'
```

Быстрая проверка, что исходные файлы реально существуют
```bash
sudo ls -l /var/lib/kubelet/kubeconfig /var/lib/kubelet/pki/ca.crt /tmp/sa.key
sudo head -n3 /var/lib/kubelet/kubeconfig
```

Смотрим, что поды поднялись
```bash
kubectl -n kube-system get pods -o wide | egrep 'NAME|kube-(controller)' || true
kubectl get --raw='/readyz?verbose'
kubectl get events --sort-by=.lastTimestamp | tail -n 40
```