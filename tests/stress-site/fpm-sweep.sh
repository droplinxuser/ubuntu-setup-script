#!/usr/bin/env bash
# PHP-FPM worker-count sweep from the macOS workstation against the audit
# host.  For each count it pins pm.max_children, measures the authenticated
# XenForo thread page (the CPU-bound tier with no FastCGI cache), and records
# throughput plus per-service CPU.  The original pool is restored at the end.
#
# Usage: PATH=<ssh shim>:$PATH bash tests/stress-site/fpm-sweep.sh [out.md]
# The remote SSH user must be root or have passwordless sudo (sudo -n).
# Env: TARGET, REMOTE_DIR, URL, COOKIE, CONNS (100), SECS (8),
#      WORKERS ("8 12 16 20 24"), dyn=1 to also test pm=dynamic at 16.
set -u
OUT=${1:-/tmp/fpm-sweep.md}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export TARGET=${TARGET:-192.0.2.10}
export REMOTE_DIR=${REMOTE_DIR:-/home/rt/work/ubuntu-setup-script}
URL=${URL:-"https://xf.test.local/index.php?threads/benchmark-thread-1-1b9c65.1/"}
COOKIE=${COOKIE:-}
CONNS=${CONNS:-100}
SECS=${SECS:-8}
WORKERS=${WORKERS:-"8 12 16 20 24"}

restore() {
  ssh "$TARGET" "sudo -n bash ${REMOTE_DIR}/tests/stress-site/set-fpm.sh restore" >/dev/null 2>&1 || true
}
trap restore EXIT INT TERM

printf '| Workers | req/s | p50 ms | p99 ms | status | php ms/req | php cores |\n' > "$OUT"
printf '|---:|---:|---:|---:|---|---:|---:|\n' >> "$OUT"

for n in $WORKERS; do
  if ! ssh "$TARGET" "sudo -n bash ${REMOTE_DIR}/tests/stress-site/set-fpm.sh ${n}" >/dev/null 2>&1; then
    printf '| %s | apply failed | | | | | |\n' "$n" >> "$OUT"
    continue
  fi
  sleep 1
  row=$(bash "$ROOT/tests/stress-site/bench-one.sh" "fpm-$n" "$URL" "${COOKIE:--}" "$CONNS" "$SECS" 2>/dev/null | tail -1)
  rps=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  p50=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
  p99=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$5); print $5}')
  status=$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | cut -c1-40)
  cpu=$(printf '%s' "$row" | awk -F'|' '{print $7}')
  php_ms=$(printf '%s' "$cpu" | tr ';' '\n' | awk '/php-fpm/{for(i=1;i<=NF;i++) if($i ~ /ms\/req/) print $(i-1)}')
  cores=$(printf '%s' "$cpu" | tr ';' '\n' | awk '/php-fpm/{for(i=1;i<=NF;i++) if($i ~ /one core/) print $(i-4)}')
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$n" "$rps" "$p50" "$p99" "$status" "${php_ms:-?}" "${cores:-?}" >> "$OUT"
  tail -1 "$OUT"
done

if [[ ${dyn:-0} == 1 ]]; then
  # Optional pm=dynamic comparison at the shipped worker ceiling.  The pool
  # state from the last static run is still saved, so restore still works.
  # set-fpm.sh maintains the start/spare keys: switching a static pool to
  # dynamic without them makes php-fpm refuse to start.
  if ssh "$TARGET" "sudo -n bash ${REMOTE_DIR}/tests/stress-site/set-fpm.sh dynamic ${WORKERS##* }" >/dev/null 2>&1; then
    sleep 1
    row=$(bash "$ROOT/tests/stress-site/bench-one.sh" "fpm-dynamic" "$URL" "${COOKIE:--}" "$CONNS" "$SECS" 2>/dev/null | tail -1)
    rps=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
    p50=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
    printf '| dynamic-%s | %s | %s | | | | |\n' "${WORKERS##* }" "$rps" "$p50" >> "$OUT"
  fi
fi

echo "written to $OUT"
