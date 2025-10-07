#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kube-system}"
POD="${POD:-debug-perf}"
REMOTE_SVG="${REMOTE_SVG:-/tmp/flame.svg}"
OUT_DIR="${OUT_DIR:-.}"
BASENAME="${BASENAME:-flame-$(date +%Y%m%d-%H%M%S).svg}"

LOCAL_PATH="${OUT_DIR%/}/${BASENAME}"

KUBECTL="${KUBECTL:-kubebuilder/bin/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL="kubectl"

echo "[04] kubectl cp ${NS}/${POD}:${REMOTE_SVG} -> ${LOCAL_PATH}"
"$KUBECTL" -n "$NS" cp "${POD}:${REMOTE_SVG}" "${LOCAL_PATH}"

echo "[04] git add/commit/push..."
git add "${LOCAL_PATH}"
git commit -m "perf: kube-apiserver flame graph (${BASENAME})"
# если настроен origin — пушим; если нет, можно пропустить:
git push || echo '[04] git push skipped/failed — configure remote and push manually.'

echo "[04] Done. Saved at: ${LOCAL_PATH}"
