Status
sudo kubebuilder/bin/kubectl -n kube-system get pods -o wide
sudo kubebuilder/bin/kubectl get nodes -o wide

Logs
sudo kubebuilder/bin/kubectl -n kube-system logs POD_NAME

“пнуть” быстрее kubelet и он перезапустит поды (например если они в CrashLoopBackOff)
sudo touch /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml

Запуск лаб команд
1
sudo bash labs/lab_level_1/setup.sh
chmod +x labs/lab_level_1/deploy_nginx_3replicas.sh
./labs/lab_level_1/deploy_nginx_3replicas.sh

2
sudo bash labs/lab_level_2/setup.sh
chmod +x labs/lab_level_2/deploy_nginx_3replicas.sh
./labs/lab_level_2/deploy_nginx_3replicas.sh
chmod +x labs/lab_level_2/01_debug_pod.sh
./labs/lab_level_2/01_debug_pod.sh
chmod +x labs/lab_level_2/01a_perf_runner.sh
./labs/lab_level_2/01a_perf_runner.sh
chmod +x labs/lab_level_2/02_profile_apiserver.sh
POD=perf-runner ./labs/lab_level_2/02_profile_apiserver.sh
chmod +x labs/lab_level_2/03_flamegraph.sh
POD=perf-runner ./labs/lab_level_2/03_flamegraph.sh
chmod +x labs/lab_level_2/04_fetch_and_commit.sh
POD=perf-runner ./labs/lab_level_2/04_fetch_and_commit.sh

# apiserver
sudo tail -n 200 /var/log/pods/kube-system_kube-apiserver-$(hostname)_*/kube-apiserver/0.log
# controller-manager
sudo tail -n 200 /var/log/pods/kube-system_kube-controller-manager-$(hostname)_*/kube-controller-manager/0.log
# scheduler
sudo tail -n 200 /var/log/pods/kube-system_kube-scheduler-$(hostname)_*/kube-scheduler/0.log
