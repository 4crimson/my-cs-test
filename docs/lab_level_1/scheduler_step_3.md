Создай файл в репо (он «подхватится» автоматически):

```bash
tee /workspaces/my-cs-test/manifests/kube-scheduler.yaml >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
  labels:
    component: kube-scheduler
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  containers:
  - name: kube-scheduler
    image: registry.k8s.io/kube-scheduler:v1.30.0
    command:
      - kube-scheduler
      - --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
      - --leader-elect=false
      - --bind-address=0.0.0.0
      - --v=2
    volumeMounts:
      - name: kc
        mountPath: /etc/kubernetes/scheduler.kubeconfig
        readOnly: true
  volumes:
    - name: kc
      hostPath:
        path: /var/lib/kubelet/kubeconfig   # ЭТО ФАЙЛ
        type: File
YAML
```

Проверяем, что стартовал
```bash
kubectl -n kube-system get pods -o wide | egrep 'NAME|kube-(scheduler)' || true
kubectl get --raw='/readyz?verbose'
```
