#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-kube-system}"
POD="${POD:-perf-runner}"   # используем perf-runner с Alpine+perf
DUR="${DUR:-60}"
FREQ="${FREQ:-99}"
OUT="${OUT:-/tmp/apiserver.perf.data}"
LOG="${LOG:-/tmp/perf-apiserver.log}"

KUBECTL="${KUBECTL:-kubebuilder/bin/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL="kubectl"

echo "[02] Using pod: ${NS}/${POD}"
"$KUBECTL" -n "$NS" exec -i "$POD" -- sh -s -- "$DUR" "$FREQ" "$OUT" "$LOG" <<'EOS'
set -e
DUR="$1"; FREQ="$2"; OUT="$3"; LOG="$4"

note(){ printf '[perf] %s\n' "$*"; }
fail(){ printf '[perf][ERR] %s\n' "$*" >&2; exit 1; }

# ---- sanity & env ----
SYS_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo NA)"
SYS_KPTR="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo NA)"
note "perf_event_paranoid=${SYS_PARANOID}, kptr_restrict=${SYS_KPTR}"

# максимально ослабим (если разрешено)
sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true
sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || true

# perf бинарь
command -v perf >/dev/null 2>&1 || fail "perf not found in $PATH (используй 01a_perf_runner.sh)"

# тест минимальный: вообще можем ли открыть perf_event?
if ! perf stat -e cycles -a -- sleep 0.1 >/dev/null 2>&1; then
  fail "perf_event_open is blocked by host (seccomp/capabilities/perf_event_paranoid). Нужен хост с разрешённым perf."
fi

# PID apiserver
APIPID="$(pgrep -f '[k]ube-apiserver' | head -n1 || true)"
if [ -z "$APIPID" ]; then
  APIPID="$(grep -l '^kube-apiserver$' /proc/*/comm 2>/dev/null | sed 's#/proc/\([0-9]\+\)/comm#\1#' | head -n1 || true)"
fi
[ -n "$APIPID" ] || fail "kube-apiserver PID not found"

note "PID=${APIPID}, DUR=${DUR}s, FREQ=${FREQ}Hz"
rm -f "$OUT" "$LOG"

# последовательность попыток (самая информативная сверху)
try_record() {
  local mode="$1"; shift
  note "record: mode=${mode}  -> ${OUT} (log: ${LOG})"
  # без TTY; весь вывод в лог, чтобы бинарь не лился в терминал
  if perf record "$@" --output "$OUT" -p "$APIPID" -- sleep "$DUR" >>"$LOG" 2>&1; then
    # проверим, что файл не пуст
    if [ -s "$OUT" ]; then
      note "OK: ${mode}"; return 0
    else
      echo "[warn] ${mode}: perf.data пустой" >>"$LOG"
      return 1
    fi
  else
    echo "[warn] ${mode}: perf record failed" >>"$LOG"
    return 1
  fi
}

# 1) user+kernel, стек через fp (без DWARF — надёжнее в контейнерах)
try_record "u+k, callgraph=fp" -F "$FREQ" -g --call-graph fp \
|| # 2) только userspace, часто помогает при блоке kernel sampling
try_record "user-only, callgraph=fp" -F "$FREQ" -g --call-graph fp -e cycles:u \
|| # 3) kernel-only (диагностика)
try_record "kernel-only" -F "$FREQ" -g -e cycles:k \
|| fail "не удалось собрать сэмплы; смотри лог ${LOG}"

ls -lh "$OUT" || true
note "done"
EOS

echo "[02] Done. Если ошибся, глянь лог в pod: kubectl -n $NS exec $POD -- tail -n +1 /tmp/perf-apiserver.log"
