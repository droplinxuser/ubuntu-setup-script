#!/usr/bin/env bash
# Server-side sampler for load tests.  Run as root on the host under test while
# a load generator (run-stress.sh or run-stress-remote.sh) is running:
#   sudo bash tests/stress-site/collect-metrics.sh /tmp/metrics.log [interval_s] [count]
# Every sample records CPU/memory/load, socket state, Angie and PHP-FPM status,
# MariaDB/Valkey/Elasticsearch counters and new error-log lines, so a
# bottleneck can be matched to the scenario that produced it.
set -u
OUT=${1:-/tmp/metrics-$(date +%Y%m%d-%H%M%S).log}
INTERVAL=${2:-5}
COUNT=${3:-0}
DOMAIN=${DOMAIN:-stress.invalid}
php_status() {
  local sock
  sock=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1)
  [[ -n $sock ]] || return 0
  SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status QUERY_STRING='' REQUEST_METHOD=GET \
    cgi-fcgi -bind -connect "$sock" 2>/dev/null | grep -E '^(active processes|idle processes|listen queue|max listen queue|slow requests|max children reached|total processes):' | tr '\n' ';' \
    || curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/fpm-status.php" 2>/dev/null | grep -E '^(active processes|idle processes|listen queue|max listen queue|slow requests|max children reached):' | tr '\n' ';'
}
angie_status() { curl -s http://127.0.0.1/status/ 2>/dev/null | tr '\n' ' ' | cut -c1-200; }
db_status() {
  mariadb -N -B -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Questions','Slow_queries','Innodb_buffer_pool_wait_free','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Created_tmp_disk_tables','Table_open_cache_misses','Aborted_connects','Max_used_connections','Threadpool_threads','Threadpool_idle_threads')" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}'
}
vk_status() {
  local cli; cli=$(command -v valkey-cli || command -v redis-cli); [[ -n $cli ]] || return 0
  "$cli" INFO 2>/dev/null | grep -E '^(connected_clients|instantaneous_ops_per_sec|used_memory_human|evicted_keys|rejected_connections|keyspace_hits|keyspace_misses|total_commands_processed):' | tr '\r\n' ' '
}
es_status() { curl -fsS 'http://127.0.0.1:9200/_nodes/stats/jvm,thread_pool,indices?filter_path=nodes.*.jvm.mem.heap_used_percent,nodes.*.thread_pool.search.rejected,nodes.*.thread_pool.search.queue,nodes.*.indices.search.query_total' 2>/dev/null | tr -d ' \n' | cut -c1-240; }
log_sizes() {
  local f
  for f in /var/www/logs/angie/*error.log /var/www/logs/php/php-fpm-slow.log /var/www/logs/php/php-fpm.log /var/www/logs/mariadb/error.log /var/www/logs/mariadb/slow.log; do
    [[ -f $f ]] && printf '%s=%s ' "${f##*/}" "$(wc -l < "$f")"
  done
}
sample() {
  local ts; ts=$(date '+%H:%M:%S')
  local cpu; cpu=$(top -bn1 | awk -F'[, ]+' '/^%Cpu/{for(i=1;i<=NF;i++){if($i=="id")idle=$(i-1); if($i=="st")st=$(i-1)}; printf "busy=%.0f%% steal=%s", 100-idle, st}')
  local mem; mem=$(free -m | awk '/^Mem:/{printf "used=%sM avail=%sM", $3, $7} /^Swap:/{printf " swapused=%sM", $3}')
  local load; load=$(cut -d' ' -f1-3 /proc/loadavg)
  local sock; sock=$(ss -s 2>/dev/null | awk '/^TCP:/{print}' | tr -s ' ' | cut -c1-120)
  local tw; tw=$(ss -tan state time-wait 2>/dev/null | wc -l)
  local conntrack; conntrack=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a)
  local drops; drops=$(awk '/TcpExt:/{a=$0} END{print}' /proc/net/netstat | head -1 >/dev/null; nstat -az TcpExtListenOverflows TcpExtListenDrops TcpExtTCPTimeouts 2>/dev/null | awk 'NR>1{printf "%s=%s ", $1, $2}')
  local top; top=$(ps -eo pcpu,rss,comm --sort=-pcpu | awk 'NR>1 && NR<=6{printf "%s:%.0f%%/%dM ", $3, $1, $2/1024}')
  {
    echo "[$ts] cpu: $cpu | mem: $mem | load: $load | timewait=$tw conntrack=$conntrack | $drops"
    echo "[$ts] top: $top"
    echo "[$ts] sock: $sock"
    echo "[$ts] angie: $(angie_status)"
    echo "[$ts] fpm: $(php_status)"
    echo "[$ts] mariadb: $(db_status)"
    echo "[$ts] valkey: $(vk_status)"
    echo "[$ts] es: $(es_status)"
    echo "[$ts] logs: $(log_sizes)"
    echo "[$ts] journal-errors: $(journalctl -p err --since "-${INTERVAL}s" --no-pager -q 2>/dev/null | wc -l) dmesg-oom: $(dmesg 2>/dev/null | grep -ci 'out of memory')"
  } >> "$OUT"
}
echo "collect-metrics: writing to $OUT every ${INTERVAL}s" >&2
i=0
while :; do
  sample
  i=$((i + 1))
  (( COUNT > 0 && i >= COUNT )) && break
  sleep "$INTERVAL"
done
