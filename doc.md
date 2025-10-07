Status
sudo kubebuilder/bin/kubectl -n kube-system get pods -o wide
sudo kubebuilder/bin/kubectl get nodes -o wide

Logs
sudo kubebuilder/bin/kubectl -n kube-system logs POD_NAME

“пнуть” быстрее kubelet и он перезапустит поды (например если они в CrashLoopBackOff)
sudo touch /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml