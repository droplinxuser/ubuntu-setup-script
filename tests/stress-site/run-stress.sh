#!/usr/bin/env bash
# Repeatable local stress suite for the full-stack test site.
# Usage: sudo bash tests/stress-site/run-stress.sh [report.md]
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v wrk >/dev/null || { echo "wrk is required (apt install wrk)" >&2; exit 1; }

DOMAIN=${DOMAIN:-stress.test}
REPORT=${1:-/tmp/stress-report.md}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl_nginx() { curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}$1"; }
sql() { mariadb -N -B -e "$1"; }

run_wrk() {
  local name=$1 url=$2 threads=$3 conns=$4 duration=$5
  local out="${TMP}/${name}.out"
  echo "  ${name}: ${threads}t/${conns}c ${duration}" >&2
  wrk -t"${threads}" -c"${conns}" -d"${duration}" --latency "$url" >"$out" 2>&1 || true
  local rps p50 p90 p99 errors
  rps=$(awk '/Requests\/sec:/{print $2}' "$out")
  p50=$(awk '/^     50%/{print $2}' "$out")
  p90=$(awk '/^     90%/{print $2}' "$out")
  p99=$(awk '/^     99%/{print $2}' "$out")
  errors=$(grep 'Socket errors:' "$out" | sed 's/^[[:space:]]*//' || true)
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$name" "${rps:-n/a}" "${p50:-n/a}" "${p90:-n/a}" "${p99:-n/a}" "${errors:-none}" >>"$TMP/table.md"
}

curl_nginx /hello.php >/dev/null
curl_nginx /cached.php >/dev/null

echo "Collecting pre-test state..." >&2
FREE_BEFORE=$(free -m | awk '/^Mem:/{printf "%s/%s MB used", $3, $2}')
LOAD_BEFORE=$(awk '{print $1}' /proc/loadavg)
FPM_BEFORE=$(curl_nginx /fpm-status | tr '\n' ';')
VK_BEFORE=$(valkey-cli INFO stats | grep -E 'instantaneous_ops_per_sec|total_commands_processed|evicted_keys|rejected_connections' | tr '\n' ';')
DB_BEFORE=$(sql "SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Threads_connected','Threads_running','Max_used_connections','Slow_queries','Aborted_connects')" | tr '\n' ';')
ES_BEFORE=$(curl -fsS 'http://127.0.0.1:9200/_nodes/stats/jvm,indices?filter_path=nodes.*.jvm.mem.heap_used_in_bytes,nodes.*.jvm.gc.collectors.young.collection_count,nodes.*.indices.search.query_total' | jq -c .)

{
  echo "# Full-stack local stress report"
  echo
  echo "- Generated: $(date -Is)"
  echo "- Host: $(hostname), $(nproc) vCPU, $(awk '/^MemTotal:/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo) RAM"
  echo "- Angie: $(/usr/sbin/angie -v 2>&1 | head -1)"
  if command -v php >/dev/null 2>&1; then
    echo "- PHP: $(php -v | head -1)"
  else
    echo "- PHP: $(php-fpm8.5 -v 2>&1 | head -1)"
  fi
  echo "- MariaDB: $(mariadb -N -B -e 'SELECT VERSION()')"
  echo "- Valkey: $(valkey-server -v)"
  echo "- Elasticsearch: $(curl -fsS http://127.0.0.1:9200 | jq -r .version.number)"
  echo "- Node.js: $(node -v)"
  echo "- GifSicle: $(gifsicle --version | head -1)"
  echo
  echo "## Results"
  echo
  echo "| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |"
  echo "|---|---:|---:|---:|---:|---|"
} >"$REPORT"

run_wrk "static"            "https://${DOMAIN}/static.html" 4 100 5s
run_wrk "php-hello"         "https://${DOMAIN}/hello.php"   4 100 5s
run_wrk "mariadb-json"      "https://${DOMAIN}/db.php"      4 100 5s
run_wrk "valkey-json"       "https://${DOMAIN}/cache.php"   4 100 5s
run_wrk "elasticsearch"     "https://${DOMAIN}/search.php"  4 50 5s
run_wrk "node-proxy"        "https://${DOMAIN}/node/"       4 100 5s
run_wrk "full-uncached-200" "https://${DOMAIN}/"            8 200 10s
run_wrk "full-cached-200"   "https://${DOMAIN}/cached.php"  8 200 10s
run_wrk "slow-1s-200"       "https://${DOMAIN}/slow.php?ms=1000" 8 200 10s

cat "$TMP/table.md" >>"$REPORT"

FREE_AFTER=$(free -m | awk '/^Mem:/{printf "%s/%s MB used", $3, $2}')
LOAD_AFTER=$(awk '{print $1}' /proc/loadavg)
FPM_AFTER=$(curl_nginx /fpm-status | tr '\n' ';')
VK_AFTER=$(valkey-cli INFO stats | grep -E 'instantaneous_ops_per_sec|total_commands_processed|evicted_keys|rejected_connections' | tr '\n' ';')
DB_AFTER=$(sql "SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Threads_connected','Threads_running','Max_used_connections','Slow_queries','Aborted_connects')" | tr '\n' ';')
ES_AFTER=$(curl -fsS 'http://127.0.0.1:9200/_nodes/stats/jvm,indices?filter_path=nodes.*.jvm.mem.heap_used_in_bytes,nodes.*.jvm.gc.collectors.young.collection_count,nodes.*.indices.search.query_total' | jq -c .)

{
  echo
  echo "## State after the suite"
  echo
  echo "- Load average: ${LOAD_BEFORE} -> ${LOAD_AFTER}"
  echo "- Memory: ${FREE_BEFORE} -> ${FREE_AFTER}"
  echo "- PHP-FPM before: ${FPM_BEFORE}"
  echo "- PHP-FPM after: ${FPM_AFTER}"
  echo "- MariaDB before: ${DB_BEFORE}"
  echo "- MariaDB after: ${DB_AFTER}"
  echo "- Valkey before: ${VK_BEFORE}"
  echo "- Valkey after: ${VK_AFTER}"
  echo "- Elasticsearch: ${ES_BEFORE} -> ${ES_AFTER}"
  echo
  echo "## Notes"
  echo
  echo "- The cached page demonstrates the main large-site optimisation: guest"
  echo "  page caching removes almost all PHP/DB/ES/Node work per request."
  echo "- The uncached page is intentionally heavy (MariaDB + Valkey + ES + Node"
  echo "  on every request). It is limited by PHP worker occupancy and CPU."
  echo "- Client socket timeouts under the slow-1s scenario mean the PHP-FPM"
  echo "  listen queue is full; add workers or cache the endpoint."
  echo "- Check /var/www/logs/angie/${DOMAIN}.error.log and"
  echo "  /var/www/logs/php/php-fpm-slow.log for server-side warnings."
} >>"$REPORT"

echo >&2
echo "Report written to ${REPORT}" >&2
grep -E '^\|' "$REPORT" >&2 || true
