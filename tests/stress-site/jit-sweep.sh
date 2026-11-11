#!/usr/bin/env bash
# JIT A/B sweep from the macOS workstation against the audit host.
# The host-side helper applies one profile and reloads PHP-FPM; bench-one.sh
# then measures throughput and per-service CPU for that profile.
#
# Usage: PATH=<ssh shim>:$PATH bash tests/stress-site/jit-sweep.sh [out.md]
# The remote SSH user must be root or have passwordless sudo (sudo -n).
# Env: TARGET, REMOTE_DIR, URL, COOKIE, CONNS (100), SECS (8), VARIANTS.
set -u
OUT=${1:-/tmp/jit-sweep.md}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export TARGET=${TARGET:-192.0.2.10}
export REMOTE_DIR=${REMOTE_DIR:-/home/rt/work/ubuntu-setup-script}
URL=${URL:-"https://xf.test.local/index.php?threads/benchmark-thread-1-1b9c65.1/"}
COOKIE=${COOKIE:-}
CONNS=${CONNS:-100}
SECS=${SECS:-8}
VARIANTS=${VARIANTS:-"off function tracing32 tracing64 tracing128 aggressive conservative roots256 roots1024 poly4 side128 combined"}

printf '| JIT profile | req/s | p50 ms | p99 ms | status | php ms/req | host cores |\n' > "$OUT"
printf '|---|---:|---:|---:|---|---:|---:|\n' >> "$OUT"

for v in $VARIANTS; do
  if ! ssh "$TARGET" "sudo -n bash ${REMOTE_DIR}/tests/stress-site/set-jit.sh ${v}" >/dev/null 2>&1; then
    printf '| %s | apply failed | | | | | |\n' "$v" >> "$OUT"
    continue
  fi
  sleep 1
  row=$(bash "$ROOT/tests/stress-site/bench-one.sh" "jit-$v" "$URL" "${COOKIE:--}" "$CONNS" "$SECS" 2>/dev/null | tail -1)
  rps=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  p50=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
  p99=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$5); print $5}')
  status=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | cut -c1-40)
  cpu=$(printf '%s' "$row" | awk -F'|' '{print $7}')
  php_ms=$(printf '%s' "$cpu" | tr ';' '\n' | awk '/php-fpm/{for(i=1;i<=NF;i++) if($i ~ /ms\/req/) print $(i-1)}')
  cores=$(printf '%s' "$cpu" | tr ';' '\n' | awk '/php-fpm/{for(i=1;i<=NF;i++) if($i ~ /one core/) print $(i-4)}')
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$v" "$rps" "$p50" "$p99" "$status" "${php_ms:-?}" "${cores:-?}" >> "$OUT"
  tail -1 "$OUT"
done
echo "written to $OUT"
