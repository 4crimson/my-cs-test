Когда scheduler|controller поднимутся (должны стать Running), ставим nginx:

```bash
mkdir -p /workspaces/my-cs-test/deploys
tee /workspaces/my-cs-test/deploys/web.yaml >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports: [{containerPort: 80}]
YAML

kubectl apply -f /workspaces/my-cs-test/deploys/web.yaml
kubectl rollout status deploy/web --timeout=90s
kubectl get pods -l app=web -o wide
```