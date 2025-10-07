Status
sudo kubebuilder/bin/kubectl -n kube-system get pods -o wide
sudo kubebuilder/bin/kubectl get nodes -o wide

Logs
sudo kubebuilder/bin/kubectl -n kube-system logs POD_NAME

“пнуть” быстрее kubelet и он перезапустит поды (например если они в CrashLoopBackOff)
sudo touch /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml

Запуск лаб команд
chmod +x deploy_nginx_3replicas.sh
./deploy_nginx_3replicas.sh

# apiserver
sudo tail -n 200 /var/log/pods/kube-system_kube-apiserver-$(hostname)_*/kube-apiserver/0.log
# controller-manager
sudo tail -n 200 /var/log/pods/kube-system_kube-controller-manager-$(hostname)_*/kube-controller-manager/0.log
# scheduler
sudo tail -n 200 /var/log/pods/kube-system_kube-scheduler-$(hostname)_*/kube-scheduler/0.log
