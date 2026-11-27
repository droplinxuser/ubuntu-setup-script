#!/usr/bin/env bash
# TLS benchmark: nginx arms built with `tools/nginx-build.sh build-arm DIR`
# (AWS-LC, the only TLS library since 1.22.5: arms differ by AWS_LC_VERSION
# or NGINX_VERSION in their own nginx-build.conf),
# each run standalone from one arm-neutral config on its own ports, never
# touching the live /etc/nginx or nginx.service.
#
# Usage (root):
#   ARMS="aws-lc-a aws-lc-b" ROUNDS=5 tls-arms-bench.sh
#   tls-arms-bench.sh --summary /root/audit/tls-arms/raw-STAMP.tsv
#
# Arms are /opt/nginx-arms/<arm>/sbin/nginx (ARMDIR).  (The 1.22.2 "-ktls"
# arm was removed with kTLS in 1.22.5, the "boringssl" and "openssl-3.5"
# arms with TLS_LIB=boringssl and OPENSSL_VERSION=lts, and the "openssl-4.1"
# arm with TLS_LIB=openssl: build-arm can no longer build them.  An arm binary
# already in ARMDIR still runs, and --summary still reads their raw files;
# columns are found by their header names.)
#
# Only features every library supports are configured: TLS 1.3, no
# stapling, no session cache and no tickets (every handshake tier is a full
# handshake), one certificate per server block.
#   :9443 ECDSA P-256, groups X25519MLKEM768:X25519 (the OpenSSL 3.5+ default)
#   :9444 ECDSA P-256, X25519 only
#   :9445 RSA-2048,    X25519 only
# Tiers (wrk, client on WRK_CPUS, nginx on NGX_CPUS):
#   H-pq    full handshake per request, ECDSA + X25519MLKEM768, 1 KB body
#   H-x25519 full handshake, ECDSA + X25519
#   H-rsa   full handshake, RSA-2048 + X25519
#   K-1k    keep-alive, 1 KB          K-page  keep-alive, XenForo guest page snapshot
#   B-1m    keep-alive, 1 MB          B-16m   keep-alive, 16 MB (incompressible)
# Per row: req/s, p50, p99, MB/s, nginx CPU ms per request (utime+stime of
# the master and workers), non-2xx/socket errors.
# Each round visits the arms forward, then reverse.  Pin the clock first
# (set-clock.sh 3600) or the turbo budget favours whichever arm runs first.
set -Eeuo pipefail
export LC_ALL=C

ARMDIR=${ARMDIR:-/opt/nginx-arms}
ROUNDS=${ROUNDS:-5}
OUT=${OUT:-/root/audit/tls-arms}
W=${W:-/var/lib/tls-arms-bench}
NGX_CPUS=${NGX_CPUS:-0-3,6-9}
WRK_CPUS=${WRK_CPUS:-4,5,10,11}
WORKERS=${WORKERS:-8}
DUR=${DUR:-10}
TIERS=${TIERS:-"H-pq H-x25519 H-rsa K-1k K-page B-1m B-16m"}

summary() { # raw.tsv -> markdown: median and spread per arm and tier
  awk -F'\t' '
    function med(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j+1] = a[j]; a[j+1] = t }
                                    return (n % 2) ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2 }
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["gate"] != "ok" { next }
    { k = $col["arm"] SUBSEP $col["tier"]; n[k]++; v = $col["rps"]; R[k, n[k]] = v
      P50[k, n[k]] = $col["p50_ms"]; P99[k, n[k]] = $col["p99_ms"]; MB[k, n[k]] = $col["MBps"]; C[k, n[k]] = $col["nginx_cpu_ms_req"]
      if (!(k in mn) || v < mn[k]) mn[k] = v; if (!(k in mx) || v > mx[k]) mx[k] = v
      if (!($col["tier"] in seen)) { seen[$col["tier"]] = 1; tiers[++nt] = $col["tier"] }; if (!($col["arm"] in sa)) { sa[$col["arm"]] = 1; arms[++na] = $col["arm"] } }
    END {
      print "| tier | arm | rounds | req/s (median) | spread | p50 ms | p99 ms | MB/s | nginx CPU ms/req |"
      print "|---|---|---|---|---|---|---|---|---|"
      for (t = 1; t <= nt; t++) for (a = 1; a <= na; a++) { k = arms[a] SUBSEP tiers[t]; m = n[k]; if (!m) continue
        for (i = 1; i <= m; i++) { r[i] = R[k, i]; p[i] = P50[k, i]; q[i] = P99[k, i]; b[i] = MB[k, i]; c[i] = C[k, i] }
        mr = med(r, m); printf "| %s | %s | %d | %.0f | %.1f%% | %.2f | %.2f | %.1f | %.4f |\n", tiers[t], arms[a], m, mr,
          (mr ? 100 * (mx[k] - mn[k]) / mr : 0), med(p, m), med(q, m), med(b, m), med(c, m) } }' "$1"
}
[[ ${1:-} == --summary ]] && { summary "${2:?raw tsv}"; exit 0; }
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
command -v wrk >/dev/null || { echo "wrk missing (apt-get install wrk)" >&2; exit 1; }

ms() { # wrk latency token -> milliseconds
  awk -v v="$1" 'BEGIN { u = v; sub(/^[0-9.]+/, "", u); x = v + 0
    if (u == "us") x /= 1000; else if (u == "s") x *= 1000; else if (u == "m") x *= 60000; printf "%.3f", x }'
}
mb() { # wrk Transfer/sec token -> MB/s
  awk -v v="$1" 'BEGIN { u = v; sub(/^[0-9.]+/, "", u); x = v + 0
    if (u == "KB") x /= 1024; else if (u == "GB") x *= 1024; else if (u == "B") x /= 1048576; printf "%.1f", x }'
}
cpu_ticks() { # pid file -> utime+stime of the master and its workers
  local m t=0 p
  m=$(cat "$1" 2>/dev/null) || { echo 0; return; }
  for p in "$m" $(pgrep -P "$m" || true); do
    t=$(( t + $(awk '{ print $14 + $15 }' "/proc/$p/stat" 2>/dev/null || echo 0) ))
  done
  echo "$t"
}

prepare() {
  mkdir -p "$W"/{www,ssl,run,logs,tmp} "$OUT"
  if [[ ! -s $W/ssl/ec.crt ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=tls.test.local \
      -keyout "$W/ssl/ec.key" -out "$W/ssl/ec.crt" 2>/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=tls.test.local \
      -keyout "$W/ssl/rsa.key" -out "$W/ssl/rsa.crt" 2>/dev/null
  fi
  [[ -s $W/www/1k.bin ]] || head -c 1024 /dev/urandom > "$W/www/1k.bin"
  [[ -s $W/www/1m.bin ]] || head -c 1048576 /dev/urandom > "$W/www/1m.bin"
  [[ -s $W/www/16m.bin ]] || head -c 16777216 /dev/urandom > "$W/www/16m.bin"
  if [[ ! -s $W/www/page.html ]]; then
    # The guest home page as served (identity), else a 60 KB stand-in.
    curl -sk --resolve xf.test.local:443:127.0.0.1 -o "$W/www/page.html" https://xf.test.local/ 2>/dev/null || true
    [[ -s $W/www/page.html ]] || head -c 61440 /dev/zero | tr '\0' a > "$W/www/page.html"
  fi
  chmod -R a+rX "$W/www"; chmod 600 "$W"/ssl/*.key
}

write_conf() { # arm -> conf path
  local arm=$1 c="$W/$1.conf"
  cat > "$c" <<EOF
worker_processes $WORKERS;
pid $W/run/$arm.pid;
error_log $W/logs/$arm.error.log warn;
events { worker_connections 8192; }
http {
  access_log off;
  sendfile on; tcp_nopush on; tcp_nodelay on;
  keepalive_requests 1000000; keepalive_timeout 60s;
  client_body_temp_path $W/tmp/body; proxy_temp_path $W/tmp/proxy; fastcgi_temp_path $W/tmp/fastcgi;
  types { text/html html; application/octet-stream bin; }
  ssl_protocols TLSv1.3;
  ssl_session_cache off; ssl_session_tickets off;
  root $W/www;
  server { listen 127.0.0.1:9443 ssl reuseport; ssl_certificate $W/ssl/ec.crt;  ssl_certificate_key $W/ssl/ec.key;  ssl_ecdh_curve X25519MLKEM768:X25519; }
  server { listen 127.0.0.1:9444 ssl reuseport; ssl_certificate $W/ssl/ec.crt;  ssl_certificate_key $W/ssl/ec.key;  ssl_ecdh_curve X25519; }
  server { listen 127.0.0.1:9445 ssl reuseport; ssl_certificate $W/ssl/rsa.crt; ssl_certificate_key $W/ssl/rsa.key; ssl_ecdh_curve X25519; }
}
EOF
  printf '%s' "$c"
}

start_arm() { # arm
  local bin="$ARMDIR/$1/sbin/nginx" c
  [[ -x $bin ]] || { echo "missing $bin" >&2; return 1; }
  if ss -Hltn '( sport = :9443 or sport = :9444 or sport = :9445 )' | grep -q .; then
    echo "$1: ports 9443-9445 already in use (a stale arm?)" >&2; return 1
  fi
  c=$(write_conf "$1")
  "$bin" -t -q -c "$c" -e "$W/logs/$1.error.log" || { echo "$1: nginx -t failed" >&2; return 1; }
  taskset -c "$NGX_CPUS" "$bin" -c "$c" -e "$W/logs/$1.error.log"
  local i; for i in $(seq 1 50); do [[ -s $W/run/$1.pid ]] && break; sleep 0.1; done
  curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/1k.bin | grep -qx 200 \
    || { echo "$1: no 200 on :9443" >&2; stop_arm "$1"; return 1; }
}
stop_arm() {
  local p kids; p=$(cat "$W/run/$1.pid" 2>/dev/null) || return 0
  # Workers outlive a KILLed master (a stalled connection holds a graceful
  # shutdown) and keep accepting on the reuseport sockets: KILL them too.
  kids=$(pgrep -P "$p" 2>/dev/null || true)
  kill -QUIT "$p" 2>/dev/null || true
  local i; for i in $(seq 1 100); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
  # shellcheck disable=SC2086
  [[ -z $kids ]] || kill -KILL $kids 2>/dev/null || true
  rm -f "$W/run/$1.pid"; return 0
}

tier_args() { # tier -> "port path conns closeflag"
  case $1 in
    H-pq) echo "9443 /1k.bin 64 close" ;;  H-x25519) echo "9444 /1k.bin 64 close" ;;  H-rsa) echo "9445 /1k.bin 64 close" ;;
    K-1k) echo "9443 /1k.bin 64 keep" ;;   K-page) echo "9443 /page.html 64 keep" ;;
    B-1m) echo "9443 /1m.bin 16 keep" ;;   B-16m) echo "9443 /16m.bin 8 keep" ;;
    *) echo "unknown tier $1" >&2; return 1 ;;
  esac
}

run_tier() { # arm round tier -> one TSV row
  local arm=$1 rd=$2 t=$3 port path conns mode out c0 c1 reqs rps p50 p99 mbs cpu err gate=ok hz
  read -r port path conns mode < <(tier_args "$t")
  local -a h=(); [[ $mode == close ]] && h=(-H 'Connection: close')
  taskset -c "$WRK_CPUS" wrk -t4 -c"$conns" -d2s "${h[@]}" "https://127.0.0.1:$port$path" >/dev/null 2>&1 || true
  c0=$(cpu_ticks "$W/run/$arm.pid")
  out=$(taskset -c "$WRK_CPUS" wrk -t4 -c"$conns" -d"${DUR}s" --latency "${h[@]}" "https://127.0.0.1:$port$path" 2>&1) || gate="fail: wrk"
  c1=$(cpu_ticks "$W/run/$arm.pid")
  reqs=$(awk '/requests in/ { print $1 }' <<<"$out"); rps=$(awk '/^Requests\/sec/ { print $2 }' <<<"$out")
  p50=$(ms "$(awk '$1 == "50%" { print $2 }' <<<"$out")"); p99=$(ms "$(awk '$1 == "99%" { print $2 }' <<<"$out")")
  mbs=$(mb "$(awk '/^Transfer\/sec/ { print $2 }' <<<"$out")")
  err=$(awk '/Non-2xx|Socket errors/ { sub(/^ +/, ""); printf "%s; ", $0 }' <<<"$out")
  hz=$(getconf CLK_TCK)
  cpu=$(awk -v d=$(( c1 - c0 )) -v r="${reqs:-0}" -v hz="$hz" 'BEGIN { printf "%.4f", r ? d * 1000 / hz / r : 0 }')
  [[ -n $err ]] && gate="fail: $err"
  [[ ${reqs:-0} -gt 0 ]] || gate="fail: no requests"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$rd" "$t" "${rps:-0}" "$p50" "$p99" "$mbs" "$cpu" "$conns" "$gate"
}

read -r -a ARM_LIST <<<"${ARMS:?set ARMS (arm names under $ARMDIR)}"
read -r -a TIER_LIST <<<"$TIERS"
prepare
STAMP=$(date +%Y%m%d-%H%M%S); RAW="$OUT/raw-$STAMP.tsv"
printf 'arm\tround\ttier\trps\tp50_ms\tp99_ms\tMBps\tnginx_cpu_ms_req\tconns\tgate\n' > "$RAW"
for a in "${ARM_LIST[@]}"; do stop_arm "$a"; done
for (( rd = 1; rd <= ROUNDS; rd++ )); do
  order=("${ARM_LIST[@]}")
  if (( rd % 2 == 0 )); then order=(); for (( i = ${#ARM_LIST[@]} - 1; i >= 0; i-- )); do order+=("${ARM_LIST[i]}"); done; fi
  for a in "${order[@]}"; do
    if ! start_arm "$a"; then printf '%s\t%s\tstart\t0\t0\t0\t0\t0\t0\tfail: start\n' "$a" "$rd" >> "$RAW"; continue; fi
    for t in "${TIER_LIST[@]}"; do run_tier "$a" "$rd" "$t" | tee -a "$RAW" >&2; done
    stop_arm "$a"
  done
done
summary "$RAW" | tee "$OUT/summary-$STAMP.md"
echo "raw: $RAW"
