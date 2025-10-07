#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kube-system}"
POD="${POD:-debug-perf}"
DUR="${DUR:-60}"
FREQ="${FREQ:-99}"
OUT="${OUT:-/tmp/apiserver.perf.data}"

KUBECTL="${KUBECTL:-kubebuilder/bin/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL="kubectl"

echo "[02] Ensure perf (prefer host perf) + find kube-apiserver PID + record..."

"$KUBECTL" -n "$NS" exec -i "$POD" -- sh -s -- "$DUR" "$FREQ" "$OUT" <<'EOS'
set -e

DUR="$1"; FREQ="$2"; OUT="$3"

echo "[sysctl] lowering restrictions"
sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true
sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || true

# Выбираем perf: 1) свой в контейнере, 2) из /hostusrbin или /hostbin
choose_perf() {
  if command -v perf >/dev/null 2>&1; then
    echo "/usr/bin/env perf"; return
  fi
  for p in /hostusrbin/perf /hostbin/perf; do
    if [ -x "$p" ]; then echo "$p"; return; fi
  done
  echo "[perf] not found (container or host). Please install 'perf' on host or in image." >&2
  exit 127
}

PERF_BIN="$(choose_perf)"
echo "[perf] using: ${PERF_BIN}"

# Находим PID kube-apiserver
APIPID="$(pgrep -f '[k]ube-apiserver' | head -n1 || true)"
if [ -z "$APIPID" ]; then
  APIPID="$(grep -l '^kube-apiserver$' /proc/*/comm 2>/dev/null | sed 's#/proc/\([0-9]\+\)/comm#\1#' | head -n1 || true)"
fi
[ -n "$APIPID" ] || { echo "ERROR: kube-apiserver PID not found"; exit 1; }

echo "[perf] PID=${APIPID}, duration=${DUR}s, freq=${FREQ}Hz -> ${OUT}"
"${PERF_BIN}" record -F "${FREQ}" -g -p "${APIPID}" -- sleep "${DUR}" -o "${OUT}"

echo "[perf] file:"
ls -lh "${OUT}" || true
EOS

echo "[02] Done."
