#!/usr/bin/env bash
#set -euo pipefail

NS="${NS:-kube-system}"
POD="${POD:-perf-runner}"           # где лежит /tmp/apiserver.perf.data
IN="${IN:-/tmp/apiserver.perf.data}"
SVG="${SVG:-/tmp/flame.svg}"
WIDTH="${WIDTH:-1600}"
TITLE="${TITLE:-kube-apiserver perf (60s@99Hz)}"
FGDIR="${FGDIR:-/tmp/FlameGraph}"

KUBECTL="${KUBECTL:-kubebuilder/bin/kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || KUBECTL="kubectl"

echo "[03] Build flamegraph ${SVG} from ${IN}"

"$KUBECTL" -n "$NS" exec -i "$POD" -- sh -s -- "$IN" "$SVG" "$WIDTH" "$TITLE" "$FGDIR" <<'EOS'
set -e
IN="$1"; SVG="$2"; WIDTH="$3"; TITLE="$4"; FGDIR="$5"

[ -s "$IN" ] || { echo "[ERR] perf data not found: $IN" >&2; exit 1; }

# ensure perl + curl
if ! command -v perl >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache perl curl >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null || true
    apt-get install -y perl curl >/dev/null
  fi
fi
command -v perl >/dev/null 2>&1 || { echo "[ERR] perl not available"; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "[ERR] curl not available"; exit 127; }

# ensure FlameGraph tools
mkdir -p "$FGDIR"
[ -f "$FGDIR/stackcollapse-perf.pl" ] || curl -fsSLo "$FGDIR/stackcollapse-perf.pl" \
  https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl
[ -f "$FGDIR/flamegraph.pl" ] || curl -fsSLo "$FGDIR/flamegraph.pl" \
  https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl
chmod +x "$FGDIR"/stackcollapse-perf.pl "$FGDIR"/flamegraph.pl

echo "[perf script] -> stackcollapse -> flamegraph"
perf script -i "$IN" \
 | perl "$FGDIR/stackcollapse-perf.pl" \
 | perl "$FGDIR/flamegraph.pl" --width "$WIDTH" --title "$TITLE" \
 > "$SVG"

ls -lh "$SVG"
EOS

echo "[03] Done."
