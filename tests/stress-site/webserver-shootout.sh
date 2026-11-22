#!/usr/bin/env bash
# Web-server shootout on the audit host.
#
# Compares Angie, nginx, FreeNginx, OpenResty, Tengine, Caddy and
# OpenLiteSpeed against the same PHP-FPM pool, application roots, TLS
# certificates and kernel.  One server owns :443 at a time and runs as a
# transient systemd unit, so its CPU is read from that unit's cgroup.
#
# The servers are installed by hand (see the AUDIT report); this script only
# writes their benchmark configs and measures.  Nothing here is part of a
# production install.
#
# Usage:
#   webserver-shootout.sh config            write configs for installed servers
#   webserver-shootout.sh list              show detected servers
#   webserver-shootout.sh run [SERVER...]   measure (default: all detected)
#
# Environment:
#   C=100 D=8 RUNS=3 WARM=1   wrk connections, seconds, rounds, warm-up
#   BENCH=/root/audit/bench   scratch directory (configs, cache, results)
#   SOCK=/run/php/php-fpm.sock
#   CPREFIX=wp.test.local     domains are $CPREFIX, xf.test.local, chev.test.local
#   TIERS="..."               space-separated tier names (default: all)
#
# Output: Markdown table on stdout and $BENCH/results.tsv for the report.
set -u
BENCH=${BENCH:-/root/audit/bench}
CACHEDIR=${CACHEDIR:-/var/cache/shootout}
SOCK=${SOCK:-/run/php/php-fpm.sock}
C=${C:-100}; D=${D:-8}; RUNS=${RUNS:-3}; WARM=${WARM:-1}
WP=${WP:-wp.test.local}; XF=${XF:-xf.test.local}; CH=${CH:-chev.test.local}
CERTDIR=${CERTDIR:-/etc/angie/ssl}
CK=${CK:-/root/audit/cookies/cookies.tsv}
MODE=${1:-run}; shift 2>/dev/null || true

SERVERS=(angie nginx freenginx openresty tengine caddy openlitespeed)
declare -A BIN=(
  [angie]=/usr/sbin/angie
  [nginx]=/usr/sbin/nginx
  [freenginx]=/opt/freenginx/sbin/nginx
  [openresty]=/usr/local/openresty/nginx/sbin/nginx
  [tengine]=/opt/tengine/sbin/nginx
  [caddy]=/usr/bin/caddy
  [openlitespeed]=/usr/local/lsws/bin/openlitespeed
)
declare -A FAMILY=(
  [angie]=nginx [nginx]=nginx [freenginx]=nginx [openresty]=nginx
  [tengine]=nginx [caddy]=caddy [openlitespeed]=ols
)

have() { [[ -x ${BIN[$1]} ]]; }

# Every nginx-family server gets the same source, with the one syntax
# difference that matters: Tengine 3.1 (nginx 1.24) predates `http2 on`.
nginx_conf() {
  local srv=$1 h2
  if [[ $srv == tengine ]]; then h2="http2"; else h2="";
  fi
  cat <<EOF
user www-data;
worker_processes auto;
worker_cpu_affinity auto;
worker_priority -10;
timer_resolution 100ms;
worker_rlimit_nofile 520000;
worker_shutdown_timeout 30s;
pid $BENCH/$srv.pid;
error_log $BENCH/$srv-error.log warn;
events { worker_connections 65535; multi_accept on; use epoll; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  log_not_found off;
  server_tokens off;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 30s;
  keepalive_requests 65536;
  open_file_cache max=20000 inactive=60s;
  open_file_cache_valid 30s;
  open_file_cache_min_uses 2;
  open_file_cache_errors on;
  gzip on;
  gzip_vary on;
  gzip_comp_level 4;
  gzip_min_length 256;
  gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:SSL:20m;
  ssl_session_timeout 1h;
  fastcgi_cache_path $CACHEDIR/$srv levels=1:2 keys_zone=bench_$srv:256m max_size=4g inactive=1h use_temp_path=off;
  map \$http_cookie \$bench_cookie { "" 0; default 1; }
  map \$request_method \$bench_method { GET 1; HEAD 1; default 0; }
  map "\$bench_cookie\$bench_method" \$bench_skip { "01" 0; default 1; }
  map \$http_accept_encoding \$bench_enc { default ""; "~*gzip" gzip; }
  index index.php index.html;
  server { listen 80 default_server; server_name _; return 444; }
EOF
  local d root try
  for d in "$WP" "$XF" "$CH"; do
    case $d in
      "$WP") root=/var/www/$WP/public; try='try_files $uri $uri/ /index.php?$args;' ;;
      "$XF") root=/var/www/$XF/public; try='try_files $uri $uri/ /index.php?$uri&$args;' ;;
      *)     root=/var/www/$CH/public; try='try_files $uri $uri/ /index.php$is_args$query_string;' ;;
    esac
    cat <<EOF
  server {
    listen 443 ssl${h2:+ $h2};
EOF
    if [[ -z $h2 ]]; then echo "    http2 on;"; fi
    cat <<EOF
    server_name $d;
    ssl_certificate $CERTDIR/$d/fullchain.pem;
    ssl_certificate_key $CERTDIR/$d/privkey.pem;
    root $root;
    location / { $try }
    location ~ \\.php\$ {
      fastcgi_param QUERY_STRING \$query_string;
      fastcgi_param REQUEST_METHOD \$request_method;
      fastcgi_param CONTENT_TYPE \$content_type;
      fastcgi_param CONTENT_LENGTH \$content_length;
      fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
      fastcgi_param REQUEST_URI \$request_uri;
      fastcgi_param DOCUMENT_URI \$document_uri;
      fastcgi_param DOCUMENT_ROOT \$document_root;
      fastcgi_param SERVER_PROTOCOL \$server_protocol;
      fastcgi_param REQUEST_SCHEME \$scheme;
      fastcgi_param HTTPS \$https if_not_empty;
      fastcgi_param GATEWAY_INTERFACE CGI/1.1;
      fastcgi_param SERVER_SOFTWARE nginx/\$nginx_version;
      fastcgi_param REMOTE_ADDR \$remote_addr;
      fastcgi_param REMOTE_PORT \$remote_port;
      fastcgi_param SERVER_ADDR \$server_addr;
      fastcgi_param SERVER_PORT \$server_port;
      fastcgi_param SERVER_NAME \$server_name;
      fastcgi_param REDIRECT_STATUS 200;
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
      fastcgi_param HTTP_ACCEPT_ENCODING \$bench_enc;
      fastcgi_param HTTP_PROXY "";
      fastcgi_pass unix:$SOCK;
      fastcgi_cache bench_$srv;
      fastcgi_cache_key "\$host|\$request_method|\$request_uri|\$bench_enc";
      fastcgi_cache_bypass \$bench_skip;
      fastcgi_no_cache \$bench_skip;
      fastcgi_cache_valid 200 301 302 60s;
      fastcgi_cache_valid 404 0s;
      fastcgi_cache_use_stale error timeout updating http_503;
      fastcgi_cache_background_update on;
      fastcgi_cache_lock on;
      fastcgi_ignore_headers Vary Set-Cookie Expires Cache-Control;
      fastcgi_hide_header Set-Cookie;
      add_header X-Cache-Status \$upstream_cache_status always;
      expires off;
    }
  }
EOF
  done
  echo "}"
}

caddy_conf() {
  cat <<EOF
{
  admin off
  auto_https off
  grace_period 1s
}
EOF
  local d root rewrite
  for d in "$WP" "$XF" "$CH"; do
    root=/var/www/$d/public
    case $d in
      "$WP") rewrite='try_files {path} {path}/ /index.php?{query}' ;;
      "$XF") rewrite='@xf not path /js/* /styles/* /data/* /favicon.ico /robots.txt
  rewrite @xf /index.php?{path}&{query}' ;;
      *)     rewrite='try_files {path} {path}/ /index.php{query}' ;;
    esac
    cat <<EOF
https://$d:443 {
  tls $CERTDIR/$d/fullchain.pem $CERTDIR/$d/privkey.pem
  root * $root
  encode gzip
  @php path *.php
  $rewrite
  php_fastcgi @php unix/$SOCK
  file_server
}
EOF
  done
}

write_configs() {
  mkdir -p "$BENCH"
  local srv
  for srv in "${SERVERS[@]}"; do
    have "$srv" || continue
    case ${FAMILY[$srv]} in
      nginx) nginx_conf "$srv" > "$BENCH/$srv.conf" ;;
      caddy) caddy_conf > "$BENCH/Caddyfile" ;;
    esac
    mkdir -p "$CACHEDIR/$srv"
    chown www-data:www-data "$CACHEDIR/$srv"
  done
  # A trivial PHP endpoint isolates the FastCGI path from application work.
  local d
  for d in "$WP" "$XF" "$CH"; do
    printf '<?php header("Content-Type: text/html"); echo str_repeat("x", 16000);\n' \
      > "/var/www/$d/public/__bench.php"
    chown www-data:www-data "/var/www/$d/public/__bench.php"
  done
  echo "configs written under $BENCH" >&2
}

start_server() {
  local srv=$1
  systemctl stop angie nginx caddy lshttpd openresty tengine freenginx 2>/dev/null || true
  systemd-run --unit="bench-$srv" --collect --quiet --service-type=simple \
    --property=LimitNOFILE=520000 --property=Restart=no \
    -- bash -c "exec ${BIN[$srv]} $STARTARGS" >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 40); do
    if curl -sk -o /dev/null --max-time 1 "https://$WP/" 2>/dev/null; then return 0; fi
    sleep 0.25
  done
  echo "server $srv did not answer on :443" >&2
  journalctl -u "bench-$srv" -n 5 --no-pager >&2 2>/dev/null || true
  return 1
}

stop_server() {
  local srv=$1
  systemctl stop "bench-$srv" 2>/dev/null || true
  systemctl reset-failed "bench-$srv" 2>/dev/null || true
}

cgroup_cpu_usec() {
  local f=/sys/fs/cgroup/system.slice/bench-$1.service/cpu.stat
  awk '/^usage_usec/{print $2}' "$f" 2>/dev/null || echo 0
}

cgroup_rss_kb() {
  local -a pids=()
  mapfile -t pids < "/sys/fs/cgroup/system.slice/bench-$1.service/cgroup.procs" 2>/dev/null || { echo 0; return; }
  (( ${#pids[@]} )) || { echo 0; return; }
  ps -o rss= -p "${pids[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%d", s}'
}

cookie_for() {
  [[ -n ${1:-} ]] || { echo ""; return; }
  # A literal "name=value" is a synthetic bypass cookie, not a jar key.
  if [[ $1 == *=* ]]; then echo "$1"; return; fi
  awk -F'\t' -v k="$1" '$1 == k {print $2}' "$CK" 2>/dev/null
}

# label|url|cookie-key|cached(1/0)
tiers() {
  local wpp xft
  wpp=$(cat /root/audit/cookies/wp-post.url 2>/dev/null || echo "https://$WP/")
  xft=$(cat /root/audit/cookies/xf-thread.url 2>/dev/null || echo "https://$XF/")
  cat <<EOF
static-wp-css|https://$WP/wp-includes/css/dist/block-library/style.min.css||0
static-xf-js|https://$XF/js/xf/core-compiled.js||0
php-micro|https://$WP/__bench.php|bench=1|0
wp-guest-post|$wpp||1
xf-guest-thread|$xft||1
chev-guest|https://$CH/explore||1
chev-uncached|https://$CH/explore|bench=1|0
wp-member|$wpp|wp-bench1|0
xf-member|$xft|xf-member|0
EOF
}

run_tier() {
  local srv=$1 label=$2 url=$3 key=$4 cached=$5 round=$6
  local cookie out p0 p1 n rps p50 p99 non2 am ae=gzip
  # Static and the micro PHP endpoint isolate the server's own path: run
  # them uncompressed so the per-request gzip/Brotli cost does not hide it.
  case $label in static-*|php-micro) ae=identity ;; esac
  cookie=$(cookie_for "$key")
  local -a h=(-H "Accept-Encoding: $ae" -H 'User-Agent: shootout/1.0')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  if [[ $cached == 1 && ${FAMILY[$srv]} == nginx ]]; then
    # Fill the entry, then confirm the server really stores it.
    find "$CACHEDIR/$srv" -mindepth 1 -delete 2>/dev/null || true
    curl -sk -o /dev/null "${h[@]}" "$url" || true
    curl -sk -o /dev/null "${h[@]}" "$url" || true
  fi
  wrk -t4 -c"$C" -d"${WARM}s" "${h[@]}" "$url" >/dev/null 2>&1 || true
  p0=$(cgroup_cpu_usec "$srv")
  out=$(wrk -t4 -c"$C" -d"${D}s" --latency "${h[@]}" "$url" 2>&1) || true
  p1=$(cgroup_cpu_usec "$srv")
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out"); p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  n=$(awk '/requests in/{print $1}' <<<"$out"); [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) || n=1
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
  am=$(awk -v d=$(( p1 - p0 )) -v n="$n" 'BEGIN{printf "%.3f", d / 1000 / n}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$srv" "$label" "$round" "${rps:-0}" "${p50:-0}" "${p99:-0}" "${non2:-0}" "$am" \
    >> "$BENCH/results.tsv"
}

median() { sort -n | awk '{a[NR]=$1} END{ if (NR) print a[int((NR+1)/2)] }'; }

report() {
  local srv label
  echo "| Server | Tier | req/s (median) | spread | p50 | p99 | non-2xx | CPU ms/req | RSS MB |"
  echo "|---|---|---:|---:|---:|---:|---:|---:|---:|"
  for label in $(tiers | cut -d'|' -f1); do
    for srv in "${SERVERS[@]}"; do
      have "$srv" || continue
      local rows rps lo hi mid spread p50 p99 non2 cpu rss
      rows=$(awk -F'\t' -v s="$srv" -v l="$label" '$1==s && $2==l {print $4}' "$BENCH/results.tsv" 2>/dev/null)
      [[ -n $rows ]] || continue
      rps=$(printf '%s\n' "$rows" | median)
      lo=$(printf '%s\n' "$rows" | sort -n | head -n1)
      hi=$(printf '%s\n' "$rows" | sort -n | tail -n1)
      spread=$(awk -v l="$lo" -v h="$hi" -v m="$rps" 'BEGIN{ if (m>0) printf "%.1f%%", (h-l)*100/m; else print "n/a" }')
      mid=$(awk -F'\t' -v s="$srv" -v l="$label" -v m="$rps" '$1==s && $2==l && $4==m {print; exit}' "$BENCH/results.tsv")
      read -r _ _ _ _ p50 p99 non2 cpu <<<"$mid"
      rss=$(awk -v s="$srv" '$1==s {v=$2} END{print v+0}' "$BENCH/rss.tsv" 2>/dev/null)
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$srv" "$label" "$rps" "$spread" "${p50:-?}" "${p99:-?}" "${non2:-0}" "${cpu:-?}" \
        "$(awk -v k="$rss" 'BEGIN{printf "%.0f", k/1024}')"
    done
  done
}

run_all() {
  local list=("$@") srv round i
  (( ${#list[@]} )) || list=("${SERVERS[@]}")
  write_configs
  : > "$BENCH/results.tsv"
  : > "$BENCH/rss.tsv"
  for round in $(seq 1 "$RUNS"); do
    # Rotate the order so the first server of a round does not keep the
    # CPU-boost head start (the same bias seen in the compression cycle).
    local -a order=()
    for (( i = 0; i < ${#list[@]}; i++ )); do
      order+=("${list[$(((i + round - 1) % ${#list[@]}))]}")
    done
    for srv in "${order[@]}"; do
      have "$srv" || continue
      echo "round $round: $srv" >&2
      case ${FAMILY[$srv]} in
        nginx) STARTARGS="-c $BENCH/$srv.conf -g 'daemon off;'" ;;
        caddy) STARTARGS="run --config $BENCH/Caddyfile --adapter caddyfile" ;;
        *) continue ;;
      esac
      start_server "$srv" || { stop_server "$srv"; continue; }
      while IFS='|' read -r label url key cached; do
        [[ -n ${TIERS:-} && " $TIERS " != *" $label "* ]] && continue
        run_tier "$srv" "$label" "$url" "$key" "$cached" "$round"
      done < <(tiers)
      printf '%s\t%s\n' "$srv" "$(cgroup_rss_kb "$srv")" >> "$BENCH/rss.tsv"
      stop_server "$srv"
    done
  done
  report
}

case $MODE in
  list)
    for s in "${SERVERS[@]}"; do have "$s" && echo "$s (${FAMILY[$s]})"; done ;;
  config) write_configs ;;
  run) run_all "$@" ;;
  *) echo "usage: $0 {config|list|run [server...]}" >&2; exit 2 ;;
esac
