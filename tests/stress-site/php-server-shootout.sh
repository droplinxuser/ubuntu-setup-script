#!/usr/bin/env bash
# PHP runtime shootout on the audit host.
#
# One workload, every PHP execution model, the same nginx in front of the
# HTTP backends.  Two modes:
#
#   runtime   an application-shaped page (60-file bootstrap, 2 MariaDB
#             statements, a Valkey GET, a 30 KB render, hashing/JSON) served
#             by PHP-FPM, PHP-CGI, FrankenPHP (classic and worker), RoadRunner,
#             Swoole, OpenSwoole, Workerman, ReactPHP, AMPHP and PHP's built-in
#             server.  Classic SAPIs pay the bootstrap per request; workers pay
#             it once.
#
#   apps      the real WordPress, XenForo and Chevereto document roots for the
#             runtimes that can serve them unmodified (PHP-FPM, PHP-CGI,
#             FrankenPHP, OpenLiteSpeed/LSAPI), with no page cache, because a
#             cache would hide the PHP path being measured.
#
# Nothing here is part of a production install.  Binaries and Composer
# packages live under $BASE and are removed with the audit tree.
#
# Usage:
#   php-server-shootout.sh setup              generate workload and configs
#   php-server-shootout.sh list
#   php-server-shootout.sh runtime [NAME...]  measure the runtime matrix
#   php-server-shootout.sh apps [NAME...]     measure the three applications
#   php-server-shootout.sh stop               stop every benchmark unit
#
# Environment:
#   C=64 D=8 WARM=2 RUNS=3   wrk connections, seconds, warm-up, rounds
#   BASE=/home/ubuntu/bench  scratch tree
#   PORT=8090                nginx benchmark listener
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE=${BASE:-/home/ubuntu/bench}
APPSIM=$BASE/appsim
PHP=${PHP:-/usr/bin/php8.5}
PHP_CGI=${PHP_CGI:-/usr/bin/php-cgi8.5}
FRANKENPHP=${FRANKENPHP:-$BASE/bin/frankenphp}
COMPOSER=${COMPOSER:-$BASE/bin/composer.phar}
SOCK=${SOCK:-/run/php/php-fpm.sock}
C=${C:-64}; D=${D:-8}; WARM=${WARM:-2}; RUNS=${RUNS:-3}
PORT=${PORT:-8090}
WP=${WP:-wp.test.local}; XF=${XF:-xf.test.local}; CH=${CH:-chev.test.local}
CERTDIR=${CERTDIR:-/etc/nginx/ssl}
CK=${CK:-/root/audit/cookies/cookies.tsv}
MODE=${1:-run}; shift 2>/dev/null || true

RUNTIMES=(fpm cgi frankenphp-classic frankenphp-worker roadrunner swoole openswoole workerman reactphp amphp phpserver)
APP_RUNTIMES=(fpm cgi frankenphp openlitespeed)
declare -A PORT_OF=(
  [cgi]=9100 [frankenphp-classic]=8081 [frankenphp-worker]=8082 [roadrunner]=8083
  [swoole]=8084 [openswoole]=8085 [workerman]=8086 [reactphp]=8087 [amphp]=8088
  [phpserver]=8089 [frankenphp]=8443 [openlitespeed]=8080
)
declare -A PREFIX=(
  [cgi]=cgi [frankenphp-classic]=fc [frankenphp-worker]=fw [roadrunner]=rr
  [swoole]=sw [openswoole]=osw [workerman]=wm [reactphp]=rx [amphp]=amp
  [phpserver]=ps
)

say() { printf '%s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- workload -----------------------------------------------------------------

setup_workload() {
  [[ -d $APPSIM/lib ]] || "$PHP" "$HERE/php-appsim/gen.php" "$APPSIM"
  local f
  for f in lib.php index.php router.php frankenphp-worker.php rr-worker.php swoole.php workerman.php react.php amphp.php; do
    install -m 644 "$HERE/php-appsim/$f" "$APPSIM/$f"
  done
  if [[ ! -f $APPSIM/vendor/autoload.php ]]; then
    say "installing Composer packages under $APPSIM"
    ( cd "$APPSIM" && "$PHP" "$COMPOSER" require --no-interaction --quiet \
        spiral/roadrunner-worker:^3 spiral/roadrunner-http:^3 nyholm/psr7 \
        workerman/workerman react/http amphp/http-server >/dev/null 2>&1 ) || return 1
  fi
  # RoadRunner's PHP packages do not ship the Go server binary.
  if [[ ! -x $BASE/bin/rr ]]; then
    local rr_tar=$BASE/bin/rr.tar.gz
    curl -fsSL -o "$rr_tar" \
      "https://github.com/roadrunner-server/roadrunner/releases/download/v3.0.1/roadrunner-3.0.1-linux-amd64.tar.gz" || return 1
    tar -xzf "$rr_tar" -C "$BASE/bin" --strip-components=1 roadrunner-3.0.1-linux-amd64/rr || return 1
    chmod +x "$BASE/bin/rr"
  fi
  # A common php.ini for the embedded and CLI runtimes: the same OPcache and
  # tracing JIT the production pool uses.
  cat > "$BASE/php.ini" <<'INI'
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=512
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=130987
opcache.validate_timestamps=0
opcache.jit=tracing
opcache.jit_buffer_size=64M
memory_limit=512M
pdo_mysql.default_socket=/run/mysqld/mysqld.sock
mysqli.default_socket=/run/mysqld/mysqld.sock
INI
  cat > "$APPSIM/rr.yaml" <<EOF
version: "3"
rpc:
  listen: tcp://127.0.0.1:6001
server:
  command: "$PHP $APPSIM/rr-worker.php"
  relay: pipes
http:
  address: 127.0.0.1:${PORT_OF[roadrunner]}
  pool:
    num_workers: 12
    allocate_timeout: 60s
logs:
  mode: production
  level: error
EOF
  # Caddyfiles for FrankenPHP: classic mode and worker mode are separate
  # processes because the worker directive is global to the server.
  cat > "$BASE/Caddyfile-classic" <<EOF
{
  admin off
  auto_https off
  grace_period 1s
}
:$((PORT_OF[frankenphp-classic])) {
  root * $APPSIM
  php_server
}
EOF
  cat > "$BASE/Caddyfile-worker" <<EOF
{
  admin off
  auto_https off
  grace_period 1s
  frankenphp {
    worker {
      file $APPSIM/frankenphp-worker.php
      num 12
    }
  }
}
:$((PORT_OF[frankenphp-worker])) {
  root * $APPSIM
  rewrite * /frankenphp-worker.php
  php_server
}
EOF
  chmod -R a+rX "$BASE"
  say "workload ready under $APPSIM"
}

# --- nginx in front of every backend ------------------------------------------

write_nginx() {
  local conf=$BASE/nginx-bench.conf prefix port
  {
    cat <<EOF
user www-data;
daemon off;
worker_processes auto;
worker_cpu_affinity auto;
pid $BASE/bench-web.pid;
error_log $BASE/bench-web-error.log warn;
events { worker_connections 65535; multi_accept on; use epoll; }
http {
  # fastcgi_params passes \$fastcgi_server_software (server-configs-nginx 1.7.5
  # defines it in http.d/server_software.conf, which this http block does not load).
  map \$uri \$fastcgi_server_software { default nginx; }
  access_log off;
  server_tokens off;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 30s;
  keepalive_requests 65536;
  gzip off;
  client_body_temp_path $BASE/tmp-client;
  proxy_temp_path $BASE/tmp-proxy;
  fastcgi_temp_path $BASE/tmp-fastcgi;
  server {
    listen 127.0.0.1:$PORT;
    server_name _;
    location = /ping { return 200 "pong\n"; }
    location = /fpm/appsim.php {
      include /etc/nginx/fastcgi_params;
      fastcgi_param SCRIPT_FILENAME $APPSIM/index.php;
      fastcgi_pass unix:$SOCK;
    }
EOF
    cat <<EOF
    location = /cgi/appsim.php {
      include /etc/nginx/fastcgi_params;
      fastcgi_param SCRIPT_FILENAME $APPSIM/index.php;
      fastcgi_pass 127.0.0.1:${PORT_OF[cgi]};
    }
EOF
    for prefix in fc fw rr sw osw wm rx amp ps; do
      case $prefix in
        fc) port=${PORT_OF[frankenphp-classic]} ;; fw) port=${PORT_OF[frankenphp-worker]} ;;
        rr) port=${PORT_OF[roadrunner]} ;; sw) port=${PORT_OF[swoole]} ;;
        osw) port=${PORT_OF[openswoole]} ;; wm) port=${PORT_OF[workerman]} ;;
        rx) port=${PORT_OF[reactphp]} ;; amp) port=${PORT_OF[amphp]} ;;
        ps) port=${PORT_OF[phpserver]} ;;
      esac
      cat <<EOF
    location /$prefix/ {
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Proto http;
      proxy_pass http://127.0.0.1:$port/;
    }
EOF
    done
    echo "  }"
    echo "}"
  } > "$conf"
  mkdir -p "$BASE/tmp-client" "$BASE/tmp-proxy" "$BASE/tmp-fastcgi"
  chown -R www-data:www-data "$BASE/tmp-client" "$BASE/tmp-proxy" "$BASE/tmp-fastcgi" 2>/dev/null || true
}

start_web() {
  systemctl stop bench-web 2>/dev/null || true
  systemctl reset-failed bench-web 2>/dev/null || true
  systemd-run --unit=bench-web --collect --quiet --service-type=simple \
    --property=LimitNOFILE=520000 --property=Restart=no \
    -- /usr/sbin/nginx -c "$BASE/nginx-bench.conf" >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 40); do
    if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/ping"; then return 0; fi
    sleep 0.25
  done
  say "bench nginx did not answer on 127.0.0.1:$PORT"
  journalctl -u bench-web -n 8 --no-pager >&2 2>/dev/null || true
  return 1
}

stop_unit() {
  systemctl stop "bench-app-$1" 2>/dev/null || true
  systemctl reset-failed "bench-app-$1" 2>/dev/null || true
}

start_unit() { # name command...
  local name=$1; shift
  stop_unit "$name"
  sleep 0.5
  systemd-run --unit="bench-app-$name" --collect --quiet --service-type=simple \
    --property=LimitNOFILE=520000 --property=Restart=no -- "$@" >/dev/null 2>&1
}

tcp_port() {
  local port=$1 i
  for i in $(seq 1 80); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3<&- 3>&-; return 0; }
    sleep 0.25
  done
  return 1
}

wait_port_free() {
  local port=$1 i
  for i in $(seq 1 40); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || return 0
    sleep 0.25
  done
  return 1
}

wait_port() {
  local port=$1 i
  for i in $(seq 1 80); do
    if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$port/" 2>/dev/null; then return 0; fi
    sleep 0.25
  done
  return 1
}

free_port() {
  local port=$1 pids
  pids=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
  [[ -n $pids ]] || return 0
  # shellcheck disable=SC2086
  kill -9 $pids 2>/dev/null || true
  sleep 0.3
}

# Swoole/php-cgi fork workers that can outlive the unit's main process while
# keeping the inherited listening socket, and ss then names a dead pid.  The
# harness owns these process command lines, so match them explicitly (the
# bracket keeps pkill from matching its own command line).
kill_leftovers() {
  local name=$1
  case $name in
    cgi) pkill -9 -f '[p]hp-cgi8.5' 2>/dev/null || true ;;
    swoole) pkill -9 -f '[a]ppsim/swoole.php' 2>/dev/null || true ;;
    openswoole) pkill -9 -f '[a]ppsim/swoole.php' 2>/dev/null || true ;;
    frankenphp-classic) pkill -9 -f '[f]rankenphp php-server --listen 127.0.0.1:8081' 2>/dev/null || true ;;
    frankenphp-worker) pkill -9 -f '[f]rankenphp run --config .*Caddyfile-worker' 2>/dev/null || true ;;
    roadrunner) pkill -9 -f '[a]ppsim/rr-worker.php' 2>/dev/null || true ; pkill -9 -f '[b]in/rr serve' 2>/dev/null || true ;;
    workerman) pkill -9 -f '[a]ppsim/workerman.php' 2>/dev/null || true ;;
    reactphp) pkill -9 -f '[a]ppsim/react.php' 2>/dev/null || true ;;
    amphp) pkill -9 -f '[a]ppsim/amphp.php' 2>/dev/null || true ;;
    phpserver) pkill -9 -f '[p]hp8.5 -S 127.0.0.1:8089' 2>/dev/null || true ;;
  esac
  return 0
}

start_backend() {
  local name=$1
  kill_leftovers "$name"
  [[ -n ${PORT_OF[$name]:-} ]] && { free_port "${PORT_OF[$name]}"; wait_port_free "${PORT_OF[$name]}" || true; }
  case $name in
    fpm) : ;;
    cgi)
      start_unit cgi /usr/bin/spawn-fcgi -n -p "${PORT_OF[cgi]}" -C 12 -u www-data -g www-data -- "$PHP_CGI" -c "$BASE/php.ini"
      tcp_port "${PORT_OF[cgi]}" || return 1 ;;
    frankenphp-classic)
      start_unit frankenphp-classic env PHPRC="$BASE/php.ini" "$FRANKENPHP" php-server --listen "127.0.0.1:${PORT_OF[frankenphp-classic]}" --root "$APPSIM" --no-compress
      wait_port "${PORT_OF[frankenphp-classic]}" || return 1 ;;
    frankenphp-worker)
      start_unit frankenphp-worker env PHPRC="$BASE/php.ini" "$FRANKENPHP" run --config "$BASE/Caddyfile-worker"
      wait_port "${PORT_OF[frankenphp-worker]}" || return 1 ;;
    roadrunner)
      start_unit roadrunner env PHPRC="$BASE/php.ini" "$BASE/bin/rr" serve -c "$APPSIM/rr.yaml"
      wait_port "${PORT_OF[roadrunner]}" || return 1 ;;
    swoole)
      start_unit swoole env PHPRC="$BASE/php.ini" "$PHP" "$APPSIM/swoole.php" "${PORT_OF[swoole]}" 'Swoole\Http\Server' 12
      wait_port "${PORT_OF[swoole]}" || return 1 ;;
    openswoole)
      start_unit openswoole env PHPRC="$BASE/php.ini" "$PHP" "$APPSIM/swoole.php" "${PORT_OF[openswoole]}" 'OpenSwoole\Http\Server' 12
      wait_port "${PORT_OF[openswoole]}" || return 1 ;;
    workerman)
      start_unit workerman env PHPRC="$BASE/php.ini" WM_PORT="${PORT_OF[workerman]}" WM_COUNT=12 "$PHP" "$APPSIM/workerman.php" start
      wait_port "${PORT_OF[workerman]}" || return 1 ;;
    reactphp)
      # One event loop per process, twelve processes sharing the port
      # through SO_REUSEPORT: ReactPHP's realistic deployment shape.
      local i
      for i in $(seq 1 12); do
        stop_unit "reactphp-$i"
        systemd-run --unit="bench-app-reactphp-$i" --collect --quiet --service-type=simple \
          --property=Restart=no -- env PHPRC="$BASE/php.ini" "$PHP" "$APPSIM/react.php" "${PORT_OF[reactphp]}" >/dev/null 2>&1
      done
      sleep 1
      wait_port "${PORT_OF[reactphp]}" || return 1 ;;
    amphp)
      local i
      for i in $(seq 1 12); do
        stop_unit "amphp-$i"
        systemd-run --unit="bench-app-amphp-$i" --collect --quiet --service-type=simple \
          --property=Restart=no -- env PHPRC="$BASE/php.ini" "$PHP" "$APPSIM/amphp.php" "${PORT_OF[amphp]}" >/dev/null 2>&1
      done
      sleep 1
      wait_port "${PORT_OF[amphp]}" || return 1 ;;
    phpserver)
      start_unit phpserver env PHPRC="$BASE/php.ini" PHP_CLI_SERVER_WORKERS=12 "$PHP" -S "127.0.0.1:${PORT_OF[phpserver]}" -t "$APPSIM" "$APPSIM/router.php"
      wait_port "${PORT_OF[phpserver]}" || return 1 ;;
    *) say "unknown runtime $name"; return 1 ;;
  esac
}

stop_backend() {
  local name=$1 i
  case $name in
    reactphp|amphp)
      for i in $(seq 1 12); do
        systemctl stop "bench-app-$name-$i" 2>/dev/null || true
        systemctl reset-failed "bench-app-$name-$i" 2>/dev/null || true
      done ;;
    fpm) : ;;
    *) stop_unit "$name" ;;
  esac
  [[ -n ${PORT_OF[$name]:-} ]] && free_port "${PORT_OF[$name]}"
  kill_leftovers "$name"
  return 0
}

stop_all() {
  local n i
  for n in "${RUNTIMES[@]}" cgi-app frankenphp-app openlitespeed; do stop_unit "$n"; done
  for i in $(seq 1 12); do
    stop_unit "reactphp-$i"; stop_unit "amphp-$i"
  done
  systemctl stop bench-web 2>/dev/null || true
  systemctl reset-failed bench-web 2>/dev/null || true
}

# --- measurement --------------------------------------------------------------

cpu_usec() { # runtime name
  local name=$1 f i total=0 n
  case $name in
    fpm) f=/sys/fs/cgroup/system.slice/php8.5-fpm.service/cpu.stat ;;
    reactphp|amphp)
      n=12
      for i in $(seq 1 $n); do
        total=$(( total + $(awk '/^usage_usec/{print $2}' "/sys/fs/cgroup/system.slice/bench-app-$name-$i.service/cpu.stat" 2>/dev/null || echo 0) ))
      done
      echo "$total"; return ;;
    *)   f=/sys/fs/cgroup/system.slice/bench-app-$name.service/cpu.stat ;;
  esac
  awk '/^usage_usec/{print $2}' "$f" 2>/dev/null || echo 0
}

web_cpu_usec() { awk '/^usage_usec/{print $2}' /sys/fs/cgroup/system.slice/bench-web.service/cpu.stat 2>/dev/null || echo 0; }

unit_rss_kb() {
  local name=$1 f pids=() i sum=0 n
  case $name in
    fpm) f=/sys/fs/cgroup/system.slice/php8.5-fpm.service/cgroup.procs ;;
    reactphp|amphp)
      n=12
      for i in $(seq 1 $n); do
        f=/sys/fs/cgroup/system.slice/bench-app-$name-$i.service/cgroup.procs
        pids=()
        mapfile -t pids < "$f" 2>/dev/null || true
        (( ${#pids[@]} )) && sum=$(( sum + $(ps -o rss= -p "${pids[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%d", s}') ))
      done
      echo "$sum"; return ;;
    *) f=/sys/fs/cgroup/system.slice/bench-app-$name.service/cgroup.procs ;;
  esac
  [[ -r $f ]] || { echo 0; return; }
  mapfile -t pids < "$f" 2>/dev/null || { echo 0; return; }
  (( ${#pids[@]} )) || { echo 0; return; }
  ps -o rss= -p "${pids[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%d", s}'
}

url_for() {
  local name=$1
  case $name in
    fpm) echo "http://127.0.0.1:$PORT/fpm/appsim.php?n=7" ;;
    cgi) echo "http://127.0.0.1:$PORT/cgi/appsim.php?n=7" ;;
    *) echo "http://127.0.0.1:$PORT/${PREFIX[$name]}/appsim.php?n=7" ;;
  esac
}

check_url() {
  local url=$1 out code bytes
  out=$(curl -sS -o /tmp/bench-body.$$ -w '%{http_code} %{size_download}' --max-time 5 "$url" 2>&1) || { say "request failed: $out"; return 1; }
  read -r code bytes <<<"$out"
  if [[ $code != 200 || ${bytes:-0} -lt 12000 ]]; then
    say "unexpected response: $out ($url)"; head -c 300 /tmp/bench-body.$$ >&2; echo >&2; return 1
  fi
  rm -f /tmp/bench-body.$$
}

run_one() { # name round
  local name=$1 round=$2 url out rps p50 p99 n non2 a0 a1 w0 w1 rss
  url=$(url_for "$name")
  check_url "$url" || return 1
  wrk -t4 -c"$C" -d"${WARM}s" "$url" >/dev/null 2>&1 || true
  a0=$(cpu_usec "$name"); w0=$(web_cpu_usec)
  out=$(wrk -t4 -c"$C" -d"${D}s" --latency "$url" 2>&1) || true
  a1=$(cpu_usec "$name"); w1=$(web_cpu_usec)
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out")
  p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  n=$(awk '/requests in/{print $1}' <<<"$out"); [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) || n=1
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
  rss=$(unit_rss_kb "$name")
  awk -v name="$name" -v round="$round" -v rps="${rps:-0}" -v p50="$p50" -v p99="$p99" \
      -v non2="${non2:-0}" -v a="$((a1 - a0))" -v w="$((w1 - w0))" -v n="$n" -v rss="$rss" \
      'BEGIN{printf "%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%.3f\t%d\n", name, round, rps, p50, p99, non2, a/1000/n, w/1000/n, rss/1024}'
}

summarize() { # tsv file
  local f=$1
  echo
  echo "| Runtime | req/s (median) | spread | p50 | p99 | PHP CPU ms/req | nginx CPU ms/req | RSS MB |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|"
  awk -F'\t' '
    { key=$1; rps[key]=rps[key] " " $3; p50[key]=$4; p99[key]=$5; a[key]=a[key] " " $7; w[key]=w[key] " " $8; rss[key]=$9; if (!(key in seen)) { seen[key]=1; order[++k]=key } }
    function median(arr,   n,i,x,j,t){ n=split(arr,x," "); for(i=2;i<=n;i++){t=x[i];for(j=i-1;j>=1&&x[j]>t;j--)x[j+1]=x[j];x[j+1]=t} if(n%2)return x[(n+1)/2]; return (x[n/2]+x[n/2+1])/2 }
    END{
      for(i=1;i<=k;i++){ key=order[i]; n=split(rps[key],v," ");
        m=median(rps[key]); lo=v[1]; hi=v[1]; for(j=2;j<=n;j++){if(v[j]<lo)lo=v[j];if(v[j]>hi)hi=v[j]}
        sp=(m>0)?(hi-lo)*100/m:0;
        if(m>=10000) rs=sprintf("%d",m); else rs=sprintf("%.0f",m);
        printf "| %s | %s | %.1f%% | %s | %s | %.3f | %.3f | %.0f |\n", key, rs, sp, p50[key], p99[key], median(a[key]), median(w[key]), rss[key]
      }
    }' "$f"
}

run_runtime() {
  local -a names=("$@"); (( ${#names[@]} )) || names=("${RUNTIMES[@]}")
  local tsv=$BASE/results-runtime.tsv; : > "$tsv"
  local round name i
  local -a ok=() order=() rev=()
  # Start every backend once, on its own port, and keep it up for all rounds.
  # Starting one per measurement raced the previous listener's shutdown and
  # made a candidate fail with EADDRINUSE; an idle backend costs no CPU.
  for name in "${names[@]}"; do
    say "  start $name"
    if start_backend "$name"; then
      ok+=("$name")
    else
      say "  $name did not start; skipping"
      stop_backend "$name"
    fi
  done
  (( ${#ok[@]} )) || { say "no runtime started"; return 1; }
  for round in $(seq 1 "$RUNS"); do
    say "round $round/$RUNS"
    order=("${ok[@]}")
    if (( round % 2 == 0 )); then
      rev=()
      for (( i = ${#order[@]} - 1; i >= 0; i-- )); do rev+=("${order[i]}"); done
      order=("${rev[@]}")
    fi
    for name in "${order[@]}"; do
      say "  $name"
      run_one "$name" "$round" >> "$tsv" || say "  $name failed its request check"
    done
  done
  for name in "${ok[@]}"; do stop_backend "$name"; done
  summarize "$tsv"
  echo
  echo "raw: $tsv"
}

# --- real applications --------------------------------------------------------

write_app_nginx() { # name fastcgi-target
  local name=$1 target=$2
  local conf=$BASE/nginx-apps-$name.conf d root try
  {
    cat <<EOF
user www-data;
daemon off;
worker_processes auto;
worker_cpu_affinity auto;
pid $BASE/bench-web.pid;
error_log $BASE/bench-web-error.log warn;
events { worker_connections 65535; multi_accept on; use epoll; }
http {
  # fastcgi_params passes \$fastcgi_server_software (server-configs-nginx 1.7.5
  # defines it in http.d/server_software.conf, which this http block does not load).
  map \$uri \$fastcgi_server_software { default nginx; }
  access_log off;
  server_tokens off;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 30s;
  keepalive_requests 65536;
  gzip off;
  client_body_temp_path $BASE/tmp-client;
  proxy_temp_path $BASE/tmp-proxy;
  fastcgi_temp_path $BASE/tmp-fastcgi;
  index index.php index.html;
EOF
    for d in "$WP" "$XF" "$CH"; do
      root=/var/www/$d/public
      case $d in
        "$WP") try='try_files $uri $uri/ /index.php?$args;' ;;
        "$XF") try='try_files $uri $uri/ /index.php?$uri&$args;' ;;
        *)     try='try_files $uri $uri/ /index.php$is_args$query_string;' ;;
      esac
      cat <<EOF
  server {
    listen 443 ssl;
    http2 on;
    server_name $d;
    ssl_certificate $CERTDIR/$d/fullchain.pem;
    ssl_certificate_key $CERTDIR/$d/privkey.pem;
    root $root;
    location / { $try }
    location ~ \.php\$ {
      include /etc/nginx/fastcgi_params;
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
      fastcgi_param HTTPS on;
      fastcgi_param HTTP_PROXY "";
      fastcgi_pass $target;
      fastcgi_read_timeout 120s;
    }
  }
EOF
    done
    echo "}"
  } > "$conf"
}

start_app_server() { # name
  local name=$1
  systemctl stop nginx bench-app-apps 2>/dev/null || true
  wait_port_free 443 || true
  sleep 1
  case $name in
    fpm)
      write_app_nginx fpm "unix:$SOCK"
      start_web_conf "$BASE/nginx-apps-fpm.conf" || return 1 ;;
    cgi)
      write_app_nginx cgi "127.0.0.1:${PORT_OF[cgi]}"
      start_unit cgi-app /usr/bin/spawn-fcgi -n -p "${PORT_OF[cgi]}" -C 12 -u www-data -g www-data -- "$PHP_CGI" -c "$BASE/php.ini"
      tcp_port "${PORT_OF[cgi]}" || return 1
      start_web_conf "$BASE/nginx-apps-cgi.conf" || return 1 ;;
    frankenphp)
      start_unit frankenphp-app env PHPRC="$BASE/php.ini" "$FRANKENPHP" run --config "$BASE/Caddyfile-apps"
      wait_app_https || return 1 ;;
    openlitespeed)
      start_unit openlitespeed /usr/local/lsws/bin/openlitespeed -d
      wait_app_https || return 1 ;;
    *) say "unknown application server $name"; return 1 ;;
  esac
}

start_web_conf() {
  local conf=$1 i try
  for try in 1 2 3; do
    systemctl stop bench-web 2>/dev/null || true
    systemctl reset-failed bench-web 2>/dev/null || true
    wait_port_free 443 || true
    systemd-run --unit=bench-web --collect --quiet --service-type=simple \
      --property=LimitNOFILE=520000 --property=Restart=no \
      -- /usr/sbin/nginx -c "$conf" >/dev/null 2>&1 || { sleep 1; continue; }
    for i in $(seq 1 40); do
      curl -fsk -o /dev/null --max-time 1 --resolve "$WP:443:127.0.0.1" "https://$WP/" 2>/dev/null && return 0
      systemctl is-active --quiet bench-web || break
      sleep 0.25
    done
    sleep 1
  done
  say "bench nginx did not answer on :443 with $conf"
  journalctl -u bench-web -n 10 --no-pager >&2 2>/dev/null || true
  return 1
}

wait_app_https() {
  local i d ok
  for i in $(seq 1 80); do
    ok=1
    for d in "$WP" "$XF" "$CH"; do
      curl -fsk -o /dev/null --max-time 1 --resolve "$d:443:127.0.0.1" "https://$d/" || { ok=0; break; }
    done
    (( ok )) && return 0
    sleep 0.25
  done
  return 1
}

write_apps_caddy() {
  local d root
  cat > "$BASE/Caddyfile-apps" <<EOF
{
  admin off
  auto_https off
  grace_period 1s
}
EOF
  for d in "$WP" "$XF" "$CH"; do
    root=/var/www/$d/public
    if [[ $d == "$XF" ]]; then
      cat >> "$BASE/Caddyfile-apps" <<EOF
https://$d:443 {
  tls $CERTDIR/$d/fullchain.pem $CERTDIR/$d/privkey.pem
  root * $root
  encode gzip
  @xf not path /js/* /styles/* /data/* /favicon.ico /robots.txt
  rewrite @xf /index.php?{path}&{query}
  php_server
}
EOF
    else
      cat >> "$BASE/Caddyfile-apps" <<EOF
https://$d:443 {
  tls $CERTDIR/$d/fullchain.pem $CERTDIR/$d/privkey.pem
  root * $root
  encode gzip
  php_server
}
EOF
    fi
  done
}

app_tiers() {
  local wpp xft
  wpp=$(cat /root/audit/cookies/wp-post.url 2>/dev/null || echo "https://$WP/")
  xft=$(cat /root/audit/cookies/xf-thread.url 2>/dev/null || echo "https://$XF/")
  cat <<EOF
wp-guest-post|$wpp|
xf-guest-thread|$xft|
chev-guest-home|https://$CH/|
wp-member|$wpp|wp-bench1
xf-member|$xft|xf-member
EOF
}

app_cpu_usec() {
  local name=$1 f
  case $name in
    fpm) f=/sys/fs/cgroup/system.slice/php8.5-fpm.service/cpu.stat ;;
    cgi) f=/sys/fs/cgroup/system.slice/bench-app-cgi-app.service/cpu.stat ;;
    frankenphp) f=/sys/fs/cgroup/system.slice/bench-app-frankenphp-app.service/cpu.stat ;;
    openlitespeed) f=/sys/fs/cgroup/system.slice/bench-app-openlitespeed.service/cpu.stat ;;
    *) return 1 ;;
  esac
  awk '/^usage_usec/{print $2}' "$f" 2>/dev/null || echo 0
}

app_rss_kb() {
  local name=$1 f pids=()
  case $name in
    fpm) f=/sys/fs/cgroup/system.slice/php8.5-fpm.service/cgroup.procs ;;
    cgi) f=/sys/fs/cgroup/system.slice/bench-app-cgi-app.service/cgroup.procs ;;
    frankenphp) f=/sys/fs/cgroup/system.slice/bench-app-frankenphp-app.service/cgroup.procs ;;
    openlitespeed) f=/sys/fs/cgroup/system.slice/bench-app-openlitespeed.service/cgroup.procs ;;
    *) echo 0; return ;;
  esac
  mapfile -t pids < "$f" 2>/dev/null || { echo 0; return; }
  (( ${#pids[@]} )) || { echo 0; return; }
  ps -o rss= -p "${pids[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%d", s}'
}

run_apps() {
  local -a names=("$@"); (( ${#names[@]} )) || names=("${APP_RUNTIMES[@]}")
  local tsv=$BASE/results-apps.tsv; : > "$tsv"
  local round name label url key cookie out rps p50 p99 n non2 c0 c1 rss
  for round in $(seq 1 "$RUNS"); do
    say "round $round/$RUNS"
    for name in "${names[@]}"; do
      say "  $name"
      if ! start_app_server "$name"; then say "  $name did not start; skipping"; stop_all; continue; fi
      while IFS='|' read -r label url key; do
        cookie=""
        [[ -n $key ]] && cookie=$(awk -F'\t' -v k="$key" '$1==k{print $2}' "$CK" 2>/dev/null)
        local -a h=(-H 'Accept-Encoding: gzip' -H 'User-Agent: php-shootout/1.0')
        [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
        wrk -t4 -c"$C" -d2s "${h[@]}" "$url" >/dev/null 2>&1 || true
        c0=$(app_cpu_usec "$name" || echo 0)
        out=$(wrk -t4 -c"$C" -d"${D}s" --latency "${h[@]}" "$url" 2>&1) || true
        c1=$(app_cpu_usec "$name" || echo 0)
        rss=$(app_rss_kb "$name")
        rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
        p50=$(awk '$1=="50%"{print $2}' <<<"$out")
        p99=$(awk '$1=="99%"{print $2}' <<<"$out")
        n=$(awk '/requests in/{print $1}' <<<"$out"); [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) || n=1
        non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
        awk -v name="$name" -v label="$label" -v round="$round" -v rps="${rps:-0}" -v p50="$p50" -v p99="$p99" \
            -v non2="${non2:-0}" -v c="$((c1 - c0))" -v n="$n" -v rss="$rss" \
            'BEGIN{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%d\n", name, label, round, rps, p50, p99, non2, c/1000/n, rss/1024}' >> "$tsv"
      done < <(app_tiers)
      stop_all
    done
  done
  echo
  echo "| Server | Tier | req/s (median) | spread | p50 | p99 | non-2xx | PHP CPU ms/req | RSS MB |"
  echo "|---|---|---:|---:|---:|---:|---:|---:|---:|"
  awk -F'\t' '
    { k=$1"|"$2; v[k]=v[k]" "$4; p50[k]=$5; p99[k]=$6; n2[k]+=$7; cpu[k]=cpu[k]" "$8; rss[k]=$9; if (!(k in seen)) { seen[k]=1; order[++n]=k } }
    function median(arr,   n,i,x,j,t){ n=split(arr,x," "); for(i=2;i<=n;i++){t=x[i];for(j=i-1;j>=1&&x[j]>t;j--)x[j+1]=x[j];x[j+1]=t} if(n%2)return x[(n+1)/2]; return (x[n/2]+x[n/2+1])/2 }
    END{ for(i=1;i<=n;i++){k=order[i]; split(k,a,"|"); m=median(v[k]); c=split(v[k],x," ");
      lo=x[1]; hi=x[1]; for(j=2;j<=c;j++){if(x[j]<lo)lo=x[j];if(x[j]>hi)hi=x[j]}
      sp=(m>0)?(hi-lo)*100/m:0; printf "| %s | %s | %.0f | %.1f%% | %s | %s | %d | %.3f | %.0f |\n", a[1], a[2], m, sp, p50[k], p99[k], n2[k], median(cpu[k]), rss[k] }}' "$tsv"
  echo
  echo "raw: $tsv"
  # Put the production TLS terminator back.
  systemctl start nginx 2>/dev/null || true
}

case $MODE in
  setup) setup_workload && write_nginx && write_apps_caddy ;;
  list) printf '%s\n' "${RUNTIMES[@]}" ;;
  runtime) setup_workload >/dev/null; write_nginx >/dev/null; start_web || exit 1; run_runtime "$@" ;;
  apps) setup_workload >/dev/null; write_apps_caddy; run_apps "$@" ;;
  stop) stop_all ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
