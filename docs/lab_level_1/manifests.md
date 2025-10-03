Манифест Kubernetes — это обычный текстовый файл в формате YAML, в котором ты описываешь «желательное состояние» объекта: Pod, Deployment, Service и т.д.

  Для static Pod’ов (например, компоненты control plane без kubeadm): файл кладут на саму ноду в папку, которую читает kubelet, обычно 
  /etc/kubernetes/manifests/. 
  Kubelet сам подхватывает/перезапускает такие Pod’ы.

```BASH
#Быстрый генератор скелета:
#(он создаст пример YAML, который ты допиливаешь).
kubectl create deployment web --image=nginx --dry-run=client -o yaml > web.yaml
```

    манифест — это «договор на бумаге» между тобой и кластером: «что должно быть». Для staticPod control plane — кладём файлы на ноду в /etc/kubernetes/manifests/. Для приложений — применяем через kubectl apply.

Проверь, что kubelet читает manifests из стандартной папки:
```BASH
ps aux | grep kubelet | grep -o 'staticPodPath=[^ ]*' || echo "Если пусто — тоже ок"
```
Создай инфраструктуру и каталог данных для etcd:
```BASH
sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/etcd
```
Создай папку в репо для манифестов:
```BASH
mkdir -p /workspaces/my-cs-test/manifests

# 2) Если во вложенной папке уже были YAML — перенесём наверх
sudo sh -lc 'test -d /workspaces/my-cs-test/etc/kubernetes/manifests && cp -a /workspaces/my-cs-test/etc/kubernetes/manifests/*.yaml /workspaces/my-cs-test/manifests/ 2>/dev/null || true'

# 3) Перелинкуем /etc/kubernetes/manifests ровно на один уровень
sudo rm -f /etc/kubernetes/manifests
sudo ln -s /workspaces/my-cs-test/manifests /etc/kubernetes/manifests

# 4) Удалим лишнюю вложенную директорию
rm -rf /workspaces/my-cs-test/etc/kubernetes/manifests

# 5) Проверим, что теперь всё чисто: ссылка — на плоскую папку,
# и внутри НЕТ подкаталогов
ls -l /etc/kubernetes/manifests
find /etc/kubernetes/manifests -maxdepth 1 -type d -not -path /etc/kubernetes/manifests -print
```
