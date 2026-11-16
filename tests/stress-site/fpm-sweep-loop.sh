#!/usr/bin/env bash
# PHP-FPM worker sweep on the audit host (loopback, oha).  Prints one row per
# worker count and tier; restores the shipped pool at the end.
# Usage: PHP_VER=8.4 WORKERS="8 12 16 20 24" bash fpm-sweep-loop.sh
set -u
OHA=${OHA:-/root/work/tools/oha}
CK=${CK:-/root/audit/cookies/cookies.tsv}
SP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONNS=${CONNS:-100}
SECS=${SECS:-8}
[[ -s $CK ]] || { echo "missing $CK: run exercise-apps.sh keep first" >&2; exit 1; }
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$CK"; }
XFT=$(cat /root/audit/cookies/xf-thread.url)
run() { # workers label url cookiekey
  local w=$1 label=$2 url=$3 key=${4:-} host out
  host=$(printf '%s' "$url" | awk -F/ '{print $3}')
  local -a a=(--no-tui --insecure --output-format json -z "${SECS}s" -c "$CONNS"
    --connect-to "$host:443:127.0.0.1:443" -H 'Accept-Encoding: gzip, br')
  [[ -n $key ]] && a+=(-H "Cookie: $(ck "$key")")
  "$OHA" "${a[@]}" "$url" >/dev/null 2>&1 || true
  out=$("$OHA" "${a[@]}" "$url" 2>/dev/null)
  printf '| %s | %s | %s | %s | %s | %s |\n' "$w" "$label" \
    "$(printf '%s' "$out" | jq -r '.summary.requestsPerSec|floor')" \
    "$(printf '%s' "$out" | jq -r '(.latencyPercentiles.p50*1000)|floor')" \
    "$(printf '%s' "$out" | jq -r '(.latencyPercentiles.p99*1000)|floor')" \
    "$(printf '%s' "$out" | jq -r '[.statusCodeDistribution|to_entries[]|select(.key|startswith("2")|not)|.value]|add//0')"
}
echo "| Workers | Tier | req/s | p50 | p99 | non-2xx |"
echo "|---:|---|---:|---:|---:|---:|"
for n in ${WORKERS:-8 12 16 20 24 32 48}; do
  bash "$SP/set-fpm.sh" "$n" >/dev/null 2>&1 || { echo "| $n | apply failed | | | | |"; continue; }
  sleep 1
  run "$n" xf-thread "$XFT" xf-member
  run "$n" wp-home https://wp.test.local/ wp-bench1
done
bash "$SP/set-fpm.sh" restore >/dev/null 2>&1 || true
