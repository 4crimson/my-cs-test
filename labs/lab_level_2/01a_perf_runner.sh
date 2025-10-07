#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kube-system}"
POD="${POD:-perf-runner}"
IMAGE="${IMAGE:-alpine:3.20}"

KUBECTL="${KUBECTL:-kubebuilder/bin/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL="kubectl"

echo "[01a] Recreate ${NS}/${POD} (${IMAGE}) with hostPID+privileged (perf via apk)"
"$KUBECTL" -n "$NS" delete pod "$POD" --ignore-not-found --wait=true

cat <<'YAML' | sed "s#__IMAGE__#${IMAGE}#g" | "$KUBECTL" apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: perf-runner
  namespace: kube-system
spec:
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  containers:
  - name: runner
    image: __IMAGE__
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
    command:
      - /bin/sh
      - -lc
      - |
        set -e
        apk update >/dev/null 2>&1 || true
        apk add --no-cache perf curl >/dev/null 2>&1 || true
        echo "[perf-runner] ready"
        sleep infinity
YAML

echo "[01a] Wait for Ready..."
"$KUBECTL" -n "$NS" wait --for=condition=Ready --timeout=180s pod/"$POD"
"$KUBECTL" -n "$NS" get pod "$POD" -o wide
echo "[01a] Done."
