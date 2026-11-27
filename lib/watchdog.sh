#!/bin/bash
# shellcheck shell=bash
# =============================================================================
# Service watchdog (1.22.5): bring nginx, PHP-FPM, Valkey, MariaDB and
# Elasticsearch back when one goes down, or hangs, on its own.
# =============================================================================
# Sourced by setup.sh (the installer side: watchdog_ensure, watchdog_remove,
# watchdog_purge_targets, watchdog_status).  Installed as
# /usr/local/sbin/setup-service-watchdog and run as a script
# (`bash setup-service-watchdog run`) by setup-service-watchdog.service,
# which setup-service-watchdog.timer starts 2 min after boot and then every
# 30 s.  Nothing here is on the request path: the timer costs a handful of
# `systemctl show` calls and one cheap liveness probe per active unit every
# 30 s.
#
# Three layers, all lean (no new packages):
#  1. A systemd drop-in, zz-setup-watchdog.conf, for nginx.service, every
#     phpX.Y-fpm.service, mariadb.service and elasticsearch.service whose
#     unit (file or another drop-in) has no Restart= of its own (the units
#     setup.sh generates have none; MariaDB's packaged unit has
#     Restart=on-abort and keeps it): Restart=on-abnormal, RestartSec=5s,
#     StartLimitIntervalSec=300 / StartLimitBurst=5.  on-abnormal restarts
#     after a crash (signal, core dump, OOM kill, timeout) but never after a
#     clean exit status, so the CPU gate's `exit 1` in ExecStartPre (a CPU
#     change keeps the service down until setup-build-cpu.service rebuilt
#     it) and a refused `nginx -t` do not loop, and `systemctl stop` still
#     stops.  valkey-server.service (ours: Restart=on-abnormal, RestartSec=2)
#     and a packaged redis-server.service (Restart=always) already restart
#     on a crash and get no drop-in.
#  2. The timer script below, for what layer 1 leaves down: a unit that
#     exited with an error status, one that hit its start limit, an enabled
#     unit that never started this boot.  Rule, per enabled managed unit
#     (`systemctl show -p ActiveState,SubState,Result,...`):
#       - active/activating/reloading/deactivating (auto-restart included):
#         up, nothing to do;
#       - ActiveState=failed, or inactive with Result other than success:
#         down;
#       - inactive with Result=success: the operator stopped it on purpose
#         (`systemctl stop`) and it stays down, unless it never left the
#         inactive state since boot (InactiveExitTimestampMonotonic=0: an
#         enabled unit that did not come up with the host), which is down;
#       - not enabled, masked or not loaded: never touched.
#     A unit first seen down is recorded in /run/setup-watchdog/<unit>.down;
#     once it has been down for 60 s it gets `systemctl reset-failed` and
#     `systemctl restart --no-block`, logged with `logger -t setup-watchdog`.
#     At most 3 restarts per unit per rolling hour; then it logs once and
#     leaves the unit alone until the hour has passed.
#     The whole pass is skipped (and every down clock reset) while the host
#     boots or shuts down, while a setup.sh run holds /run/setup.sh.lock,
#     while a build, activation or the 1.22 migration holds
#     /run/setup-build.lock, while a setup-build-*/setup-*-build*/
#     setup-migrate-* unit is active, and while a CPU-change rebuild is
#     pending or has failed this boot (/run/setup-build-cpu.attempts: the
#     operator rule keeps the services down until the native rebuild).
#     activating (an Elasticsearch start takes minutes) is never down.
#  3. Hang detection, in the same timer pass: a unit that is active (not
#     activating/reloading) gets one cheap liveness probe, all units in
#     parallel, each under a hard timeout(1) (10 s answer + 2 s), run as
#     root and never touching application code:
#       - Valkey / adopted Redis: valkey-cli / redis-cli PING over the
#         configured unixsocket (TCP to port at the address ss shows it
#         listening on when there is no socket and port is not 0).  Any reply is alive: PONG, LOADING (an
#         RDB/AOF load), BUSY (a long script), NOAUTH;
#       - MariaDB: mariadb-admin --protocol=socket --connect-timeout=10 ping
#         (root socket auth).  Any answer of the server is alive (mysqld is
#         alive, Too many connections, Access denied, a full listen queue);
#         only "Can't connect", "Lost connection" or no answer at all is a
#         failure (no socket at the client's path is inconclusive);
#       - Elasticsearch: curl to / on its HTTP port (http.port, default
#         9200; https when xpack.security.http.ssl is enabled) at the
#         address it listens on (ss: loopback for a wildcard bind).  Any
#         HTTP status (401, 503) is alive; / is node-local, unlike
#         /_cluster/health, which waits for an elected master;
#       - nginx: curl -k to https://127.0.0.1/ (http on port 80 when
#         nothing listens on 443): the catch-all's 444 (empty reply, curl
#         exit 52) or a refused TLS handshake (exit 35) is alive;
#       - PHP-FPM: one FastCGI request for the pool's ping.path (the tuner
#         adds ping.path = /setup-fpm-ping, which no nginx location can pass:
#         every fastcgi_pass location matches *.php only) sent over the
#         pool's socket by a tiny FastCGI client in the PHP CLI
#         (php -n).  Any FastCGI record back (pong, even a 404) is alive.
#     Only "connection refused" and "no answer within 10 s" count as a
#     failed probe; anything inconclusive (no listener found, no client
#     binary, an unexpected tool error) counts as nothing and resets the
#     count.  A failed probe is not counted either while the unit's cgroup
#     is visibly working (cgroup v2 cpu.stat/io.stat since the previous
#     pass: >= 2% of one core or >= 1 MB/s of disk I/O): a saturated MariaDB
#     or PHP pool is busy, not hung, and a restart would only throw its work
#     away.  The unit is restarted (reset-failed + restart --no-block, the
#     same 3-per-hour limit and skip rules as layer 2) after 3 failed probes
#     in a row (~90 s) for nginx, PHP-FPM and Valkey, 5 (~150 s) for MariaDB
#     and Elasticsearch, and never within 60 s (600 s for MariaDB and
#     Elasticsearch) of the unit's last start.  A failure, a busy period and
#     the recovery are each logged once per state change.
#     SETUP_SERVICE_WATCHDOG_HANG=0 (persisted as SERVICE_WATCHDOG_HANG=0)
#     turns this layer off and keeps the other two.
#
# SETUP_SERVICE_WATCHDOG=0 (persisted as SERVICE_WATCHDOG=0 in
# /etc/default/setup-tuning) removes all layers at the next --basic or
# --optimize run, for operators with their own monitoring; =1 brings them
# back.  --purge removes them with the last managed service (or with basic).

# ------------------------------------------------------------ shared paths
# Test hooks: SETUP_WATCHDOG_* (scratch directories, a fixed clock).
WD_STATE_DIR=${SETUP_WATCHDOG_STATE_DIR:-/run/setup-watchdog}
WD_UNIT_DIRS=${SETUP_WATCHDOG_UNIT_DIRS:-/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system}
WD_DOWN_SECS=${SETUP_WATCHDOG_DOWN_SECS:-60}
WD_MAX_PER_HOUR=${SETUP_WATCHDOG_MAX_PER_HOUR:-3}
WD_BUILD_LOCK=${SETUP_BUILD_LOCK:-/run/setup-build.lock}
WD_RUN_LOCK=${SETUP_RUN_LOCK:-/run/setup.sh.lock}
WD_CPU_ATTEMPTS=${SETUP_BUILD_CPU_ATTEMPTS:-/run/setup-build-cpu.attempts}
WD_TUNING_FILE=${SETUP_TUNING_FILE:-/etc/default/setup-tuning}
WD_TAG=setup-watchdog
# Hang detection (layer 3).
WD_PROBE_SECS=${SETUP_WATCHDOG_PROBE_SECS:-10}
WD_HANG_FAST=${SETUP_WATCHDOG_HANG_FAST:-3}          # nginx, PHP-FPM, Valkey
WD_HANG_SLOW=${SETUP_WATCHDOG_HANG_SLOW:-5}          # MariaDB, Elasticsearch
WD_GRACE_FAST=${SETUP_WATCHDOG_GRACE_FAST:-60}
WD_GRACE_SLOW=${SETUP_WATCHDOG_GRACE_SLOW:-600}
# 2% of one core: a pool whose workers mostly wait (slow database or API)
# still finishes requests and burns a few % of a core; a hung one (all
# workers blocked, SIGSTOP, D state) sits near 0.
WD_BUSY_CPU_PERMILLE=${SETUP_WATCHDOG_BUSY_CPU:-20}
WD_BUSY_IO_KBS=${SETUP_WATCHDOG_BUSY_IO:-1024}       # 1 MB/s
WD_CGROUP_ROOT=${SETUP_WATCHDOG_CGROUP_ROOT:-/sys/fs/cgroup}
WD_PHP_ETC=${SETUP_WATCHDOG_PHP_ETC:-/etc/php}
WD_PHP_ROOT=${SETUP_WATCHDOG_PHP_ROOT:-/usr/local/lib/setup-php}
WD_VALKEY_CONF=${SETUP_WATCHDOG_VALKEY_CONF:-/etc/valkey/valkey.conf}
WD_REDIS_CONF=${SETUP_WATCHDOG_REDIS_CONF:-/etc/redis/redis.conf}
WD_VALKEY_ROOT=${SETUP_WATCHDOG_VALKEY_ROOT:-/usr/local/lib/setup-valkey}
WD_ES_YML=${SETUP_WATCHDOG_ES_YML:-/etc/elasticsearch/elasticsearch.yml}
WD_FPM_PING_PATH=/setup-fpm-ping

# ------------------------------------------------------- the timer script
wd_now() { printf '%s' "${SETUP_WATCHDOG_NOW:-$(date +%s)}"; }

wd_log() { # priority message
  if command -v logger >/dev/null 2>&1; then
    logger -t "$WD_TAG" -p "daemon.$1" -- "$2" 2>/dev/null && return 0
  fi
  printf '%s: %s\n' "$WD_TAG" "$2"
}

# The managed units whose unit file exists: nginx, every phpX.Y-fpm, Valkey
# or an adopted Redis, MariaDB, Elasticsearch.  Enabled or not (the
# classifier decides).
wd_units() {
  local d f
  local -a dirs
  read -r -a dirs <<< "$WD_UNIT_DIRS"
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/nginx.service "$d"/php*-fpm.service "$d"/valkey-server.service "$d"/redis-server.service \
             "$d"/mariadb.service "$d"/elasticsearch.service; do
      if [[ -f $f ]]; then printf '%s\n' "${f##*/}"; fi
    done
  done | sort -u
  return 0
}

# A lock another process holds exclusively.  Probed with a shared,
# non-blocking lock that is dropped at once (build-common.sh
# setup_run_active): an exclusive probe could make a run starting in that
# instant refuse to start.
wd_lock_held() { # file
  [[ -f $1 && ! -L $1 ]] && command -v flock >/dev/null 2>&1 || return 1
  ! ( exec 8<"$1" && flock -n -s 8 ) 2>/dev/null
}

# Prints why the whole pass is skipped (status 0), or nothing (status 1).
wd_global_skip() {
  local st busy n
  st=$(systemctl is-system-running 2>/dev/null || true)
  case $st in
    initializing|starting|stopping) printf 'system is %s' "$st"; return 0 ;;
  esac
  if wd_lock_held "$WD_RUN_LOCK"; then printf 'a setup.sh run is in progress (%s)' "$WD_RUN_LOCK"; return 0; fi
  if wd_lock_held "$WD_BUILD_LOCK"; then printf 'the build lock is held (%s)' "$WD_BUILD_LOCK"; return 0; fi
  n=""
  [[ -f $WD_CPU_ATTEMPTS ]] && n=$(tr -dc '0-9' < "$WD_CPU_ATTEMPTS" 2>/dev/null || true)
  if [[ -n $n ]] && (( 10#$n > 0 )); then
    printf 'a CPU-change rebuild is pending or failed this boot (%s)' "$WD_CPU_ATTEMPTS"; return 0
  fi
  busy=$(systemctl list-units --no-legend --plain --state=active,activating,deactivating \
           'setup-build-*.service' 'setup-*-build*.service' 'setup-migrate-*.service' 2>/dev/null \
         | awk 'NF { printf "%s%s", sep, $1; sep = " " }' || true)
  if [[ -n $busy ]]; then printf 'build/migration unit running: %s' "$busy"; return 0; fi
  return 1
}

# Sets WD_CLS (up | down <state> | skip <why>) and, for the hang layer,
# WD_ACTIVE (ActiveState), WD_CGROUP (ControlGroup) and WD_ENTER_MONO
# (ActiveEnterTimestampMonotonic, microseconds).  One `systemctl show`.
WD_CLS="" WD_ACTIVE="" WD_CGROUP="" WD_ENTER_MONO=""
wd_classify() { # unit
  local k v load="" file="" active="" sub="" result="" exitmono=""
  WD_CLS="" WD_ACTIVE="" WD_CGROUP="" WD_ENTER_MONO=""
  while IFS='=' read -r k v; do
    case $k in
      LoadState) load=$v ;;
      UnitFileState) file=$v ;;
      ActiveState) active=$v ;;
      SubState) sub=$v ;;
      Result) result=$v ;;
      InactiveExitTimestampMonotonic) exitmono=$v ;;
      ActiveEnterTimestampMonotonic) WD_ENTER_MONO=$v ;;
      ControlGroup) WD_CGROUP=$v ;;
    esac
  done < <(systemctl show -p LoadState,UnitFileState,ActiveState,SubState,Result,InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic,ControlGroup -- "$1" 2>/dev/null || true)
  WD_ACTIVE=$active
  [[ $load == loaded ]] || { WD_CLS="skip not loaded (${load:-unknown})"; return 0; }
  [[ $file == enabled ]] || { WD_CLS="skip not enabled (${file:-unknown})"; return 0; }
  case $active in
    active|activating|deactivating|reloading|refreshing) WD_CLS=up; return 0 ;;
    failed) WD_CLS="down ${active}/${sub} result=${result}"; return 0 ;;
    inactive)
      if [[ -n $result && $result != success ]]; then
        WD_CLS="down ${active}/${sub} result=${result}"
      elif [[ ${exitmono:-0} == 0 ]]; then
        WD_CLS="down ${active}/${sub}, never started this boot"
      else
        WD_CLS="skip stopped cleanly (systemctl stop)"
      fi
      return 0 ;;
  esac
  WD_CLS="skip state ${active:-unknown}/${sub:-unknown}"
}

# The rate limit shared by the down and hang layers: WD_KEEP holds the
# restarts of UNIT in the rolling hour before NOW.
WD_KEEP=()
wd_recent_restarts() { # unit now
  local t rfile="$WD_STATE_DIR/$1.restarts"
  WD_KEEP=()
  [[ -f $rfile ]] || return 0
  while IFS= read -r t; do
    [[ $t =~ ^[0-9]+$ ]] && (( $2 - t < 3600 )) && WD_KEEP+=("$t")
  done < "$rfile"
  return 0
}

# Record a restart at NOW (after wd_recent_restarts), then reset-failed and
# restart --no-block.  Status: systemctl restart's.
wd_restart() { # unit now
  WD_KEEP+=("$2")
  printf '%s\n' "${WD_KEEP[@]}" > "$WD_STATE_DIR/$1.restarts"
  systemctl reset-failed -- "$1" >/dev/null 2>&1 || true
  systemctl restart --no-block -- "$1" >/dev/null 2>&1
}

# One unit: start or advance its down clock, restart it after
# WD_DOWN_SECS, at most WD_MAX_PER_HOUR times per rolling hour.  Leaves
# wd_classify's WD_* for the hang layer.
wd_check_unit() { # unit now
  local unit=$1 now=$2 state down gave first n=0
  down="$WD_STATE_DIR/$unit.down" gave="$WD_STATE_DIR/$unit.gaveup"
  wd_classify "$unit"
  if [[ $WD_CLS != down\ * ]]; then
    rm -f -- "$down"
    [[ $WD_CLS == up ]] && rm -f -- "$gave"
    return 0
  fi
  state=${WD_CLS#down }
  if [[ ! -s $down ]]; then
    printf '%s\n' "$now" > "$down"
    wd_log notice "$unit is down ($state); restarting it if it is still down in ${WD_DOWN_SECS} s"
    return 0
  fi
  first=$(tr -dc '0-9' < "$down" || true)
  [[ -n $first ]] || { printf '%s\n' "$now" > "$down"; return 0; }
  (( now - 10#$first >= WD_DOWN_SECS )) || return 0
  wd_recent_restarts "$unit" "$now"
  n=${#WD_KEEP[@]}
  if (( n >= WD_MAX_PER_HOUR )); then
    if [[ ! -f $gave ]]; then
      : > "$gave"
      wd_log err "$unit is still down ($state) after ${n} restarts in the last hour; not restarting it again until the hour has passed (journalctl -u $unit)"
    fi
    return 0
  fi
  rm -f -- "$gave"
  if wd_restart "$unit" "$now"; then
    wd_log warning "$unit was down for $(( now - 10#$first )) s ($state); restart requested ($(( n + 1 ))/${WD_MAX_PER_HOUR} this hour)"
  else
    wd_log err "$unit was down for $(( now - 10#$first )) s ($state); systemctl restart failed ($(( n + 1 ))/${WD_MAX_PER_HOUR} this hour)"
  fi
  # The next attempt waits a full WD_DOWN_SECS again.
  rm -f -- "$down"
  return 0
}

# --------------------------------------------------- hang detection probes
# Each probe prints one line: alive <detail> | fail <detail> | skip <detail>.
# fail is only "refused" or "no answer in time"; anything else the probe
# cannot judge is skip, which never counts toward a restart.

# A hard limit around one probe command (timeout(1) is in coreutils).
wd_to() { # seconds command...
  local s=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$s" "$@"; else "$@"; fi
}

# Probe output as one short log-safe line.
wd_oneline() { tr -s '\r\n\t' '   ' | tr -cd '[:print:]' | cut -c1-160; }

# The address that reaches a local TCP listener on PORT: 127.0.0.1 for a
# wildcard or loopback IPv4 bind, [::1] for an IPv6-only one, else the
# specific address it is bound to.  Nothing when nothing listens there.
wd_listen_host() { # port
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltn 2>/dev/null | awk -v p=":$1" '
    { a = $4; sub(/%[^:]*:/, ":", a)
      if (length(a) <= length(p) || substr(a, length(a) - length(p) + 1) != p) next
      h = substr(a, 1, length(a) - length(p))
      if (h == "0.0.0.0" || h == "127.0.0.1" || h == "*") v4 = 1
      else if (h == "[::]" || h == "[::1]") v6 = 1
      else if (o == "") o = h }
    END { if (v4) print "127.0.0.1"; else if (v6) print "[::1]"; else if (o != "") print o }'
}

# Any HTTP answer, or a server that closes or refuses the TLS handshake,
# is alive.  Only a refused connection or no answer at all fails.
wd_curl_probe() { # url
  local out rc
  command -v curl >/dev/null 2>&1 || { printf 'skip no curl\n'; return 0; }
  out=$(wd_to $(( WD_PROBE_SECS + 2 )) curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' \
          --max-time "$WD_PROBE_SECS" "$1" 2>/dev/null)
  rc=$?
  out=$(printf '%s' "$out" | wd_oneline)
  case $rc in
    0) printf 'alive %s answered HTTP %s\n' "$1" "$out" ;;
    8|16|18|35|52|56|92) printf 'alive %s answered (curl exit %s)\n' "$1" "$rc" ;;
    7) printf 'fail %s refused the connection\n' "$1" ;;
    28|124|137) printf 'fail no answer from %s in %s s\n' "$1" "$WD_PROBE_SECS" ;;
    *) printf 'skip curl exit %s for %s\n' "$rc" "$1" ;;
  esac
}

wd_probe_nginx() {
  local h
  h=$(wd_listen_host 443)
  if [[ -n $h ]]; then wd_curl_probe "https://${h}/"; return 0; fi
  h=$(wd_listen_host 80)
  if [[ -n $h ]]; then wd_curl_probe "http://${h}/"; return 0; fi
  printf 'skip nothing listens on port 443 or 80\n'
}

# The node's HTTP port and scheme from elasticsearch.yml; / is answered
# by the node itself (no master needed), so a cluster without an elected
# master is not taken for a hung node.
wd_probe_es() {
  local port="" scheme=http h
  if [[ -r $WD_ES_YML ]]; then
    port=$(sed -nE "s/^[[:space:]]*http\\.port[[:space:]]*:[[:space:]]*[\"']?([0-9]+).*/\\1/p" "$WD_ES_YML" 2>/dev/null | head -n1 || true)
    # Flat (xpack.security.http.ssl.enabled: true) or the nested block the
    # Elasticsearch 8 package auto-configuration writes
    # (xpack.security.http.ssl:\n  enabled: true).  Plain HTTP to a TLS port
    # would still answer (alive) but logs a warning in the node log each pass.
    if awk '
         { l = tolower($0) }
         l ~ /^[[:space:]]*xpack\.security\.http\.ssl\.enabled[[:space:]]*:[[:space:]]*["\047]?true/ { f = 1; exit }
         l ~ /^xpack\.security\.http\.ssl[[:space:]]*:[[:space:]]*$/ { b = 1; next }
         b && l ~ /^[[:space:]]+enabled[[:space:]]*:[[:space:]]*["\047]?true/ { f = 1; exit }
         b && l !~ /^[[:space:]]/ { b = 0 }
         END { exit !f }' "$WD_ES_YML" 2>/dev/null; then
      scheme=https
    fi
  fi
  if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then port=9200; fi
  port=$(( 10#$port ))
  h=$(wd_listen_host "$port")
  [[ -n $h ]] || { printf 'skip nothing listens on port %s\n' "$port"; return 0; }
  wd_curl_probe "${scheme}://${h}:${port}/"
}

# PING over the configured unixsocket (TCP to port where ss shows it
# listening without one).
# Any reply is alive: PONG, LOADING, BUSY (a long script), NOAUTH.
wd_probe_valkey() { # unit
  local conf=$WD_VALKEY_CONF cli="" c sock="" port="" out rc h
  local -a target=()
  [[ $1 == redis-server.service ]] && conf=$WD_REDIS_CONF
  for c in "$(command -v valkey-cli 2>/dev/null || true)" "$WD_VALKEY_ROOT/bin/valkey-cli" \
           "$(command -v redis-cli 2>/dev/null || true)"; do
    if [[ -n $c && -x $c ]]; then cli=$c; break; fi
  done
  [[ -n $cli ]] || { printf 'skip no valkey-cli or redis-cli\n'; return 0; }
  if [[ -r $conf ]]; then
    sock=$(awk '$1 == "unixsocket" { v = $2 } END { print v }' "$conf" 2>/dev/null || true)
    port=$(awk '$1 == "port" { v = $2 } END { print v }' "$conf" 2>/dev/null || true)
  fi
  sock=${sock//\"/}
  [[ $port =~ ^[0-9]{1,5}$ ]] || port=6379
  if [[ -n $sock && -S $sock ]]; then
    target=(-s "$sock")
  elif (( 10#$port != 0 )); then
    # Where it actually listens (a bind to a private address only would
    # refuse 127.0.0.1 and look dead on every pass); nothing -> inconclusive.
    port=$(( 10#$port ))
    h=$(wd_listen_host "$port")
    [[ -n $h ]] || { printf 'skip nothing listens on port %s\n' "$port"; return 0; }
    h=${h#[}; h=${h%]}
    target=(-h "$h" -p "$port")
  elif [[ -n $sock ]]; then
    printf 'fail socket %s is missing (port 0)\n' "$sock"; return 0
  else
    printf 'skip no unixsocket and port 0 in %s\n' "$conf"; return 0
  fi
  out=$(wd_to $(( WD_PROBE_SECS + 2 )) "$cli" "${target[@]}" PING 2>&1)
  rc=$?
  out=$(printf '%s' "$out" | wd_oneline)
  case $out in
    *PONG*|*LOADING*|*BUSY*|*NOAUTH*|*WRONGPASS*|*NOPERM*|*MASTERDOWN*|*MISCONF*)
      printf 'alive %s\n' "$out"; return 0 ;;
  esac
  if (( rc == 124 || rc == 137 )); then
    printf 'fail no reply to PING on %s in %s s\n' "${target[*]}" "$WD_PROBE_SECS"
  elif [[ $out == *"Could not connect"* || $out == *"Connection refused"* ]]; then
    printf 'fail %s\n' "$out"
  elif (( rc == 0 )) && [[ -n $out ]]; then
    printf 'alive %s\n' "$out"
  else
    printf 'skip %s exit %s: %s\n' "${cli##*/}" "$rc" "$out"
  fi
}

# mariadb-admin ping as root (unix_socket auth).  Any answer of the server
# is alive (mysqld is alive, Too many connections, Access denied).
wd_probe_mariadb() {
  local bin out rc
  bin=$(command -v mariadb-admin 2>/dev/null || command -v mysqladmin 2>/dev/null || true)
  [[ -n $bin ]] || { printf 'skip no mariadb-admin\n'; return 0; }
  # --protocol=socket: the local server, whatever host= or port= a client
  # option file (/root/.my.cnf) names; a TCP setting there could point at
  # another server or at a port this one does not listen on.
  out=$(wd_to $(( WD_PROBE_SECS + 2 )) "$bin" --protocol=socket --connect-timeout="$WD_PROBE_SECS" ping 2>&1)
  rc=$?
  out=$(printf '%s' "$out" | wd_oneline)
  if (( rc == 124 || rc == 137 )); then
    printf 'fail no answer to ping in %s s\n' "$WD_PROBE_SECS"; return 0
  fi
  case $out in
    *"is alive"*) printf 'alive %s\n' "$out" ;;
    # (11) EAGAIN: the socket's listen queue is full, saturated, not hung.
    *"Can't connect"*"(11)"*) printf 'alive listen queue full (saturated): %s\n' "$out" ;;
    # (2) ENOENT: no socket at the client's path; the server's socket may be
    # configured elsewhere, so this cannot tell hung from misconfigured.
    *"Can't connect"*"(2)"*) printf 'skip no MariaDB socket at the client path: %s\n' "$out" ;;
    *"Can't connect"*|*"Lost connection"*) printf 'fail %s\n' "$out" ;;
    *"error: '"*) printf 'alive the server answered: %s\n' "$out" ;;
    *) if (( rc == 0 )); then printf 'alive %s\n' "${out:-ping ok}"; else printf 'skip %s exit %s: %s\n' "${bin##*/}" "$rc" "$out"; fi ;;
  esac
}

# The [www] pool (else the first pool) of PHP VERSION: listen<TAB>ping.path.
wd_php_pool() { # version
  local f
  local -a files=()
  for f in "$WD_PHP_ETC/$1"/fpm/pool.d/*.conf; do
    [[ -f $f ]] && files+=("$f")
  done
  (( ${#files[@]} )) || return 0
  awk '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ { s = $0; gsub(/^[[:space:]]*\[|\].*$/, "", s)
                        if (!(s in seen)) { seen[s] = 1; order[++n] = s }; next }
    /=/ { k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
          v = $0; sub(/^[^=]*=/, "", v); sub(/[[:space:]]+;.*$/, "", v)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^"|"$/, "", v)
          if (k == "listen") L[s] = v; else if (k == "ping.path") P[s] = v }
    END {
      pick = ""
      if (L["www"] != "") pick = "www"
      else for (i = 1; i <= n; i++) if (order[i] != "global" && L[order[i]] != "") { pick = order[i]; break }
      if (pick != "") printf "%s\t%s\n", L[pick], P[pick]
    }' "${files[@]}" 2>/dev/null
}

# A minimal FastCGI client for the PHP CLI (php -n -r): one GET for the
# ping path, then wait for the first record back.  Exit 0: a reply,
# 4: closed by FPM, 7: listen queue full (EAGAIN: saturated, not hung),
# 3: connect failed, 5: no reply in time.
wd_fcgi_client() {
  cat <<'PHP'
[, $target, $secs, $path] = $argv;
$secs = (float)$secs;
$end = microtime(true) + $secs;
$s = @stream_socket_client($target, $en, $es, $secs);
if ($s === false) {
  // EAGAIN (11): the listen queue is full, so the pool is saturated, not hung.
  if ($en == 11) { echo "listen queue full (pool saturated): $es\n"; exit(7); }
  echo "connect to $target failed: $es ($en)\n"; exit(3);
}
$rec = function ($t, $c) { return pack('CCnnCC', 1, $t, 1, strlen($c), 0, 0) . $c; };
$len = function ($n) { return $n < 128 ? chr($n) : pack('N', $n | 0x80000000); };
$p = '';
foreach (['GATEWAY_INTERFACE' => 'FastCGI/1.0', 'REQUEST_METHOD' => 'GET',
          'SCRIPT_NAME' => $path, 'SCRIPT_FILENAME' => $path, 'REQUEST_URI' => $path,
          'DOCUMENT_URI' => $path, 'QUERY_STRING' => '', 'SERVER_PROTOCOL' => 'HTTP/1.1',
          'REMOTE_ADDR' => '127.0.0.1', 'SERVER_ADDR' => '127.0.0.1',
          'SERVER_NAME' => 'localhost', 'CONTENT_LENGTH' => '0'] as $k => $v) {
  $p .= $len(strlen($k)) . $len(strlen($v)) . $k . $v;
}
$req = $rec(1, pack('nCx5', 1, 0)) . $rec(4, $p) . $rec(4, '') . $rec(5, '');
if (@fwrite($s, $req) !== strlen($req)) { echo "closed by FPM while sending\n"; exit(4); }
$buf = '';
while (($left = $end - microtime(true)) > 0) {
  $r = [$s]; $w = null; $e = null;
  $n = @stream_select($r, $w, $e, (int)$left, (int)(($left - (int)$left) * 1000000));
  if ($n === false) { echo "select failed\n"; exit(6); }
  if ($n === 0) { break; }
  $d = @fread($s, 8192);
  if ($d === false || $d === '') {
    if (feof($s)) { echo "closed by FPM without a reply\n"; exit(4); }
    continue;
  }
  $buf .= $d;
  if (strlen($buf) >= 8) { $h = unpack('Cver/Ctype', $buf); echo "FastCGI reply (record type {$h['type']})\n"; exit(0); }
}
echo "no reply in {$secs} s\n";
exit(5);
PHP
}

# One FastCGI request for the pool's ping.path over its socket.  A pool
# without ping.path is not probed (a request for an unknown script would log
# a warning in the pool log every 30 s); --optimize adds it.
wd_probe_php() { # unit
  local ver=${1#php} line listen ping target php="" c out rc
  ver=${ver%-fpm.service}
  line=$(wd_php_pool "$ver")
  listen=${line%%$'\t'*}
  ping=${line#*$'\t'}
  [[ $line == *$'\t'* ]] || ping=""
  [[ -n $listen ]] || { printf 'skip no pool listen in %s/%s/fpm/pool.d\n' "$WD_PHP_ETC" "$ver"; return 0; }
  [[ $listen != *'$'* ]] || { printf 'skip pool listen %s uses a variable\n' "$listen"; return 0; }
  [[ $ping == /* ]] || { printf 'skip the pool has no ping.path (setup.sh --optimize adds %s)\n' "$WD_FPM_PING_PATH"; return 0; }
  case $listen in
    /*) [[ -S $listen ]] || { printf 'fail socket %s is missing\n' "$listen"; return 0; }
        target="unix://${listen}" ;;
    *[!0-9]*) target="tcp://${listen}" ;;
    *) target="tcp://127.0.0.1:${listen}" ;;
  esac
  for c in "$WD_PHP_ROOT/$ver/bin/php" "$(command -v php 2>/dev/null || true)"; do
    if [[ -n $c && -x $c ]]; then php=$c; break; fi
  done
  [[ -n $php ]] || { printf 'skip no PHP CLI for %s\n' "$ver"; return 0; }
  out=$(wd_to $(( WD_PROBE_SECS + 2 )) "$php" -n -d display_errors=0 -r "$(wd_fcgi_client)" -- \
          "$target" "$WD_PROBE_SECS" "$ping" 2>&1)
  rc=$?
  out=$(printf '%s' "$out" | wd_oneline)
  case $rc in
    0|4|7) printf 'alive %s %s: %s\n' "$target" "$ping" "$out" ;;
    3|5) printf 'fail %s %s: %s\n' "$target" "$ping" "$out" ;;
    124|137) printf 'fail %s %s: no reply in %s s\n' "$target" "$ping" "$WD_PROBE_SECS" ;;
    *) printf 'skip php exit %s: %s\n' "$rc" "$out" ;;
  esac
}

wd_probe() { # unit
  case $1 in
    nginx.service) wd_probe_nginx ;;
    php*-fpm.service) wd_probe_php "$1" ;;
    valkey-server.service|redis-server.service) wd_probe_valkey "$1" ;;
    mariadb.service) wd_probe_mariadb ;;
    elasticsearch.service) wd_probe_es ;;
    *) printf 'skip no probe for %s\n' "$1" ;;
  esac
}

# ------------------------------------------------- hang detection decision
wd_slow_unit() { [[ $1 == mariadb.service || $1 == elasticsearch.service ]]; }

wd_mono_now() {
  if [[ -n ${SETUP_WATCHDOG_MONO_NOW:-} ]]; then printf '%s' "$SETUP_WATCHDOG_MONO_NOW"
  else awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || true; fi
}

# The unit started less than its grace period ago.  An unknown start time
# counts as in grace (no probe).
wd_in_grace() { # unit active-enter-usec mono-now-secs
  local g=$WD_GRACE_FAST
  wd_slow_unit "$1" && g=$WD_GRACE_SLOW
  [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || return 0
  (( $2 > 0 )) || return 0
  (( $3 - $2 / 1000000 < g ))
}

# cgroup v2 counters of a unit: "<cpu usage_usec> <io bytes>", - when unknown.
wd_cg_sample() { # control-group
  local d=$WD_CGROUP_ROOT$1 cpu="" io=""
  if [[ -n $1 && -r $d/cpu.stat ]]; then
    cpu=$(awk '$1 == "usage_usec" { print $2; exit }' "$d/cpu.stat" 2>/dev/null || true)
  fi
  if [[ -n $1 && -r $d/io.stat ]]; then
    io=$(awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^[rw]bytes=/) { sub(/^[rw]bytes=/, "", $i); s += $i } }
              END { printf "%.0f", s }' "$d/io.stat" 2>/dev/null || true)
  fi
  [[ $cpu =~ ^[0-9]+$ ]] || cpu=-
  [[ $io =~ ^[0-9]+$ ]] || io=-
  printf '%s %s' "$cpu" "$io"
}

# Prints what the unit was doing since the previous sample when that is
# enough to call it busy (CPU >= WD_BUSY_CPU_PERMILLE of one core, or disk
# I/O >= WD_BUSY_IO_KBS), else nothing.
wd_busy() { # previous-sample("time cpu io") now cpu io
  local pt="" pc="" pi="" dt rate out=""
  read -r pt pc pi <<< "$1"
  [[ $pt =~ ^[0-9]+$ ]] && (( $2 > pt )) || return 0
  dt=$(( $2 - pt ))
  if [[ $pc =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] && (( $3 >= pc )); then
    rate=$(( ($3 - pc) / 1000 / dt ))
    (( rate >= WD_BUSY_CPU_PERMILLE )) && out="CPU $(( rate / 10 ))% of a core"
  fi
  if [[ $pi =~ ^[0-9]+$ && $4 =~ ^[0-9]+$ ]] && (( $4 >= pi )); then
    rate=$(( ($4 - pi) / 1024 / dt ))
    (( rate >= WD_BUSY_IO_KBS )) && out="${out:+${out}, }disk I/O ${rate} KB/s"
  fi
  printf '%s' "$out"
}

wd_hang_reset() { # unit
  rm -f -- "$WD_STATE_DIR/$1.hang" "$WD_STATE_DIR/$1.probe" "$WD_STATE_DIR/$1.cpu" "$WD_STATE_DIR/$1.hanggaveup" "$WD_STATE_DIR/$1.seen"
}

# One probe result: count consecutive failures of an idle unit, restart it
# at the unit's threshold (rate-limited with the down layer), log each state
# change once (<unit>.probe: failing | busy).
wd_hang_check() { # unit now control-group result
  local unit=$1 now=$2 res=$4 verdict detail prev="" last="" sample busy n="" limit=$WD_HANG_FAST
  local hf="$WD_STATE_DIR/$1.hang" pf="$WD_STATE_DIR/$1.probe" sf="$WD_STATE_DIR/$1.cpu" gf="$WD_STATE_DIR/$1.hanggaveup"
  verdict=${res%% *}
  detail=${res#"$verdict"}
  detail=${detail# }
  wd_slow_unit "$unit" && limit=$WD_HANG_SLOW
  [[ -f $pf ]] && prev=$(head -n1 "$pf" 2>/dev/null || true)
  [[ -f $sf ]] && last=$(head -n1 "$sf" 2>/dev/null || true)
  sample=$(wd_cg_sample "$3")
  printf '%s %s\n' "$now" "$sample" > "$sf"
  case $verdict in
    alive)
      [[ -n $prev && $prev != never ]] && wd_log notice "$unit answers its liveness probe again (${detail})"
      rm -f -- "$hf" "$pf" "$gf"
      : > "$WD_STATE_DIR/$unit.seen"
      return 0 ;;
    fail) ;;
    *) rm -f -- "$hf"; return 0 ;;
  esac
  # A probe that has never succeeded on this host (since boot or since the
  # unit last went down) proves nothing: a client or address this host does
  # not match would otherwise restart a healthy service 3 times an hour.
  # Failures only count once the same probe has answered at least once.
  if [[ ! -f $WD_STATE_DIR/$unit.seen ]]; then
    [[ $prev == never ]] || wd_log notice "$unit: liveness probe has not succeeded yet (${detail}); hang restarts wait for a first answer"
    printf 'never\n' > "$pf"
    return 0
  fi
  busy=$(wd_busy "$last" "$now" "${sample% *}" "${sample#* }")
  if [[ -n $busy ]]; then
    rm -f -- "$hf"
    if [[ $prev != busy ]]; then
      printf 'busy\n' > "$pf"
      wd_log notice "$unit did not answer its liveness probe (${detail}) but is working (${busy}); not counted as hung"
    fi
    return 0
  fi
  [[ -f $hf ]] && n=$(tr -dc '0-9' < "$hf" 2>/dev/null || true)
  n=$(( 10#${n:-0} + 1 ))
  printf '%s\n' "$n" > "$hf"
  if [[ $prev != failing ]]; then
    printf 'failing\n' > "$pf"
    wd_log notice "$unit did not answer its liveness probe (${detail}); restarting it after ${limit} failed probes in a row"
  fi
  (( n >= limit )) || return 0
  wd_recent_restarts "$unit" "$now"
  if (( ${#WD_KEEP[@]} >= WD_MAX_PER_HOUR )); then
    if [[ ! -f $gf ]]; then
      : > "$gf"
      wd_log err "$unit is still hung (${detail}) after ${#WD_KEEP[@]} restarts in the last hour; not restarting it again until the hour has passed (journalctl -u $unit)"
    fi
    return 0
  fi
  rm -f -- "$gf"
  if wd_restart "$unit" "$now"; then
    wd_log warning "$unit is active but hung: ${n} liveness probes in a row failed (${detail}); restart requested (${#WD_KEEP[@]}/${WD_MAX_PER_HOUR} this hour)"
  else
    wd_log err "$unit is active but hung: ${n} liveness probes in a row failed (${detail}); systemctl restart failed (${#WD_KEEP[@]}/${WD_MAX_PER_HOUR} this hour)"
  fi
  # The next attempt needs the full count again (after the start grace).
  rm -f -- "$hf" "$sf"
  return 0
}

# All probes at once (DIR/<index> gets unit <index>'s line): a pass takes
# one probe timeout at worst.  Waits for these probes only.
wd_probe_all() { # dir unit...
  local dir=$1 i=0 u
  local -a pids=()
  shift
  for u in "$@"; do
    wd_probe "$u" > "$dir/$i" 2>/dev/null < /dev/null &
    pids+=("$!")
    i=$(( i + 1 ))
  done
  (( ${#pids[@]} )) && wait "${pids[@]}" 2>/dev/null
  return 0
}

wd_run() {
  local now mono why u i res pdir hang=1
  local -a pu=() pcg=()
  if [[ -f $WD_TUNING_FILE ]] && grep -qE '^SERVICE_WATCHDOG=0$' "$WD_TUNING_FILE" 2>/dev/null; then
    return 0
  fi
  if [[ -f $WD_TUNING_FILE ]] && grep -qE '^SERVICE_WATCHDOG_HANG=0$' "$WD_TUNING_FILE" 2>/dev/null; then
    hang=0
  fi
  ( umask 077; mkdir -p -- "$WD_STATE_DIR" ) || return 1
  now=$(wd_now)
  if why=$(wd_global_skip); then
    # Intentional downtime: the clocks and probe counts start again once
    # it is over, so a unit still down afterwards gets the full grace period.
    rm -f -- "$WD_STATE_DIR"/*.down "$WD_STATE_DIR"/*.hang
    [[ -n ${SETUP_WATCHDOG_VERBOSE:-} ]] && printf 'skipped: %s\n' "$why"
    return 0
  fi
  mono=$(wd_mono_now)
  while IFS= read -r u; do
    [[ -n $u ]] || continue
    wd_check_unit "$u" "$now"
    if (( ! hang )); then
      wd_hang_reset "$u"
    elif [[ $WD_CLS != up || $WD_ACTIVE != active ]]; then
      rm -f -- "$WD_STATE_DIR/$u.hang" "$WD_STATE_DIR/$u.cpu"
    elif wd_in_grace "$u" "$WD_ENTER_MONO" "$mono"; then
      rm -f -- "$WD_STATE_DIR/$u.hang"
    else
      pu+=("$u"); pcg+=("$WD_CGROUP")
    fi
  done < <(wd_units)
  (( ${#pu[@]} )) || return 0
  pdir="$WD_STATE_DIR/probe.$$"
  rm -rf -- "$pdir"
  mkdir -p -- "$pdir" || return 0
  wd_probe_all "$pdir" "${pu[@]}"
  for i in "${!pu[@]}"; do
    res=$(head -n1 "$pdir/$i" 2>/dev/null || true)
    wd_hang_check "${pu[i]}" "$now" "${pcg[i]}" "${res:-skip no probe result}"
  done
  rm -rf -- "$pdir"
  return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -uo pipefail
  export LC_ALL=C
  case ${1:-run} in
    run) wd_run; exit $? ;;
    *) printf 'usage: %s run\n' "$0" >&2; exit 2 ;;
  esac
fi

# ------------------------------------------------------------- installer
WATCHDOG_SYSTEMD_DIR=${SETUP_WATCHDOG_SYSTEMD_DIR:-/etc/systemd/system}
WATCHDOG_BIN=${SETUP_WATCHDOG_BIN:-/usr/local/sbin/setup-service-watchdog}
WATCHDOG_SRC=${SETUP_WATCHDOG_SRC:-${BASH_SOURCE[0]}}
WATCHDOG_DROPIN=zz-setup-watchdog.conf
WATCHDOG_SERVICE=setup-service-watchdog.service
WATCHDOG_TIMER=setup-service-watchdog.timer
WATCHDOG_MARK='# Managed by setup.sh (lib/watchdog.sh)'

watchdog_dropin_text() {
  cat <<EOF
${WATCHDOG_MARK}: restart after a crash (signal, core dump,
# OOM kill, timeout).  A clean error exit (the CPU gate, a refused config
# test) is not restarted here; setup-service-watchdog.timer retries those
# after 60 s down, at most 3 times an hour.  SETUP_SERVICE_WATCHDOG=0 removes it.
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Restart=on-abnormal
RestartSec=5s
EOF
}

watchdog_service_text() {
  cat <<EOF
${WATCHDOG_MARK}: restart nginx, PHP-FPM, Valkey,
# MariaDB and Elasticsearch after 60 s down or a hang (rules in ${WATCHDOG_BIN}).
[Unit]
Description=Restart managed services that went down or hung (setup.sh)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${WATCHDOG_BIN} run
TimeoutStartSec=120
Nice=10
# Keeps systemd's Starting/Finished lines (every 30 s) out of the journal;
# the watchdog's own notices and warnings still get through.
LogLevelMax=notice
EOF
}

watchdog_timer_text() {
  cat <<EOF
${WATCHDOG_MARK}
[Unit]
Description=Check managed web services every 30 s (setup.sh)

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
}

# Neither the unit's own file nor another drop-in carries Restart=: only
# then is the crash-restart drop-in added (ours sorts last and would win
# over an operator's choice).  nginx, PHP-FPM, MariaDB (its packaged unit
# has Restart=on-abort: none) and Elasticsearch.
watchdog_wants_dropin() { # unit
  local d f found=0
  local -a dirs
  case $1 in nginx.service|php*-fpm.service|mariadb.service|elasticsearch.service) ;; *) return 1 ;; esac
  read -r -a dirs <<< "$WD_UNIT_DIRS"
  for d in "${dirs[@]}"; do
    f="$d/$1"
    if (( ! found )) && [[ -f $f ]]; then
      found=1
      grep -qE '^[[:space:]]*Restart=' "$f" && return 1
    fi
    for f in "$d/$1.d"/*.conf; do
      [[ -f $f && ${f##*/} != "$WATCHDOG_DROPIN" ]] || continue
      grep -qE '^[[:space:]]*Restart=' "$f" && return 1
    done
  done
  (( found ))
}

# Write CONTENT to PATH when it differs.  Status 0: written, 1: unchanged.
_watchdog_write() { # path mode content
  local path=$1 mode=$2 content=$3
  if [[ -f $path ]] && [[ $(cat -- "$path") == "$content" ]]; then return 1; fi
  mkdir -p -- "${path%/*}"
  printf '%s\n' "$content" > "$path.tmp.$$" && chmod "$mode" "$path.tmp.$$" && mv -f -- "$path.tmp.$$" "$path"
  return 0
}

_watchdog_ours() { [[ -f $1 ]] && grep -qF -- "$WATCHDOG_MARK" "$1" 2>/dev/null; }

_watchdog_rm_dropin() { # unit -> status 0 when one was removed
  local f="$WATCHDOG_SYSTEMD_DIR/$1.d/$WATCHDOG_DROPIN"
  _watchdog_ours "$f" || return 1
  rm -f -- "$f"
  rmdir -- "${f%/*}" 2>/dev/null || true
  return 0
}

watchdog_installed() {
  [[ -f $WATCHDOG_SYSTEMD_DIR/$WATCHDOG_TIMER || -f $WATCHDOG_BIN ]] \
    || compgen -G "$WATCHDOG_SYSTEMD_DIR/*.service.d/$WATCHDOG_DROPIN" >/dev/null 2>&1
}

# SETUP_SERVICE_WATCHDOG (this run) wins over SERVICE_WATCHDOG (the host file
# setup.sh sourced at startup); default on.  An explicit value is persisted;
# an off choice the --optimize profile reset moved out of the file is written
# back, so it survives.  The same for SETUP_SERVICE_WATCHDOG_HANG /
# SERVICE_WATCHDOG_HANG (the hang layer; the timer script reads the file).
# Sets WATCHDOG_ON and WATCHDOG_HANG_ON.
WATCHDOG_ON=1
WATCHDOG_HANG_ON=1
_watchdog_choice_one() { # KEY -> prints 0|1, persists an explicit or off choice
  local key=$1 env="SETUP_$1" v explicit=0 on f=${SETUP_TUNING_FILE:-/etc/default/setup-tuning}
  if [[ -n ${!env+x} ]]; then
    v=${!env}; explicit=1
  else
    v=${!key:-1}
  fi
  if [[ $v == 0 ]]; then on=0; else on=1; fi
  if declare -F persist_tuning_var >/dev/null 2>&1; then
    if (( explicit )); then
      grep -qx "${key}=${on}" "$f" 2>/dev/null || persist_tuning_var "$key" "$on" >/dev/null
    elif (( ! on )) && ! grep -qx "${key}=0" "$f" 2>/dev/null; then
      persist_tuning_var "$key" 0 >/dev/null
    fi
  fi
  printf '%s' "$on"
}
watchdog_choice() {
  WATCHDOG_ON=$(_watchdog_choice_one SERVICE_WATCHDOG)
  WATCHDOG_HANG_ON=$(_watchdog_choice_one SERVICE_WATCHDOG_HANG)
  return 0
}

# Install or refresh both layers for the units present (idempotent: files
# are rewritten and systemd reloaded only when something changed; running
# services are never restarted).  OUT is the reporter (opt_report, info),
# PREFIX its line prefix ("- " for the report).
watchdog_ensure() { # [out] [prefix]
  local out=${1:-info} pre=${2:-} changed=0 u f
  local -a units=() dropins=()
  command -v systemctl >/dev/null 2>&1 || return 0
  [[ -d /run/systemd/system || -n ${SETUP_WATCHDOG_SYSTEMD_DIR:-} ]] || return 0
  watchdog_choice
  if (( ! WATCHDOG_ON )); then
    if watchdog_installed; then
      watchdog_remove
      "$out" "${pre}Service watchdog: removed (SERVICE_WATCHDOG=0; \`SETUP_SERVICE_WATCHDOG=1\` brings it back)"
    else
      "$out" "${pre}Service watchdog: off (SERVICE_WATCHDOG=0)"
    fi
    return 0
  fi
  mapfile -t units < <(wd_units)
  if (( ${#units[@]} == 0 )); then
    watchdog_installed && watchdog_remove
    return 0
  fi
  [[ -r $WATCHDOG_SRC ]] || { "$out" "${pre}Service watchdog: **FAILED** (${WATCHDOG_SRC} missing)"; return 1; }
  if ! cmp -s -- "$WATCHDOG_SRC" "$WATCHDOG_BIN"; then
    mkdir -p -- "${WATCHDOG_BIN%/*}"
    install -m 0755 -- "$WATCHDOG_SRC" "$WATCHDOG_BIN" || { "$out" "${pre}Service watchdog: **FAILED** to install ${WATCHDOG_BIN}"; return 1; }
  fi
  _watchdog_write "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_SERVICE" 0644 "$(watchdog_service_text)" && changed=1
  _watchdog_write "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_TIMER" 0644 "$(watchdog_timer_text)" && changed=1
  for u in "${units[@]}"; do
    if watchdog_wants_dropin "$u"; then
      if _watchdog_write "$WATCHDOG_SYSTEMD_DIR/$u.d/$WATCHDOG_DROPIN" 0644 "$(watchdog_dropin_text)"; then changed=1; fi
      dropins+=("$u")
    elif _watchdog_rm_dropin "$u"; then
      changed=1
    fi
  done
  # A drop-in left for a unit that is gone (an older PHP version).
  for f in "$WATCHDOG_SYSTEMD_DIR"/*.service.d/"$WATCHDOG_DROPIN"; do
    [[ -f $f ]] || continue
    u=${f%/*}; u=${u##*/}; u=${u%.d}
    [[ " ${units[*]} " == *" $u "* ]] && continue
    if _watchdog_rm_dropin "$u"; then changed=1; fi
  done
  if (( changed )); then systemctl daemon-reload >/dev/null 2>&1 || true; fi
  if [[ $(systemctl is-enabled "$WATCHDOG_TIMER" 2>/dev/null) != enabled ]] \
     || ! systemctl is-active -q "$WATCHDOG_TIMER" 2>/dev/null; then
    systemctl enable --now "$WATCHDOG_TIMER" >/dev/null 2>&1 \
      || { "$out" "${pre}Service watchdog: **FAILED** to enable ${WATCHDOG_TIMER}"; return 1; }
  fi
  local hang_txt="hang restart after ${WD_HANG_FAST} failed liveness probes in a row (${WD_HANG_SLOW} for MariaDB/Elasticsearch, never while the unit is busy or within ${WD_GRACE_SLOW} s of their start; \`SETUP_SERVICE_WATCHDOG_HANG=0\` turns it off)"
  (( WATCHDOG_HANG_ON )) || hang_txt="hang restart off (SERVICE_WATCHDOG_HANG=0)"
  "$out" "${pre}Service watchdog: on for ${units[*]} (restart after ${WD_DOWN_SECS} s down, at most ${WD_MAX_PER_HOUR} per unit per hour; ${hang_txt}; crash restart drop-in: ${dropins[*]:-none}; \`SETUP_SERVICE_WATCHDOG=0\` turns it off)"
  return 0
}

# Remove both layers and the /run state.  Idempotent.
watchdog_remove() {
  local f u
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$WATCHDOG_TIMER" >/dev/null 2>&1 || true
    systemctl stop "$WATCHDOG_SERVICE" >/dev/null 2>&1 || true
  fi
  _watchdog_ours "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_TIMER" && rm -f -- "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_TIMER"
  _watchdog_ours "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_SERVICE" && rm -f -- "$WATCHDOG_SYSTEMD_DIR/$WATCHDOG_SERVICE"
  for f in "$WATCHDOG_SYSTEMD_DIR"/*.service.d/"$WATCHDOG_DROPIN"; do
    [[ -f $f ]] || continue
    u=${f%/*}; u=${u##*/}; u=${u%.d}
    _watchdog_rm_dropin "$u" || true
  done
  [[ -f $WATCHDOG_BIN ]] && grep -q 'wd_run' "$WATCHDOG_BIN" 2>/dev/null && rm -f -- "$WATCHDOG_BIN"
  rm -rf -- "${WD_STATE_DIR:?}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$WATCHDOG_SERVICE" >/dev/null 2>&1 || true
  fi
  return 0
}

# --purge: the drop-ins of the purged services go; with basic, or once no
# managed unit is enabled any more, the whole watchdog goes.
watchdog_purge_targets() { # PURGE_ORDER...
  local t f u any=0
  for t in "$@"; do
    [[ $t == basic ]] && { watchdog_remove; info "Service watchdog removed (timer, script, drop-ins)"; return 0; }
  done
  for t in "$@"; do
    case $t in
      nginx) _watchdog_rm_dropin nginx.service || true ;;
      mariadb) _watchdog_rm_dropin mariadb.service || true ;;
      elastic) _watchdog_rm_dropin elasticsearch.service || true ;;
      php)
        for f in "$WATCHDOG_SYSTEMD_DIR"/php*-fpm.service.d/"$WATCHDOG_DROPIN"; do
          [[ -f $f ]] || continue
          u=${f%/*}; u=${u##*/}; u=${u%.d}
          _watchdog_rm_dropin "$u" || true
        done ;;
    esac
  done
  while IFS= read -r u; do
    [[ -n $u ]] || continue
    [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] && { any=1; break; }
  done < <(wd_units)
  if (( any )); then
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif watchdog_installed; then
    watchdog_remove
    info "Service watchdog removed (no managed service is enabled any more)"
  fi
  return 0
}

# Read-only lines for --diagnostics: choices, timer, drop-ins, one liveness
# probe of every active managed unit (as the timer runs it, in parallel),
# the /run state and the last watchdog journal lines.
watchdog_status() {
  local f u i
  local -a pu=()
  printf 'choice: SERVICE_WATCHDOG=%s SERVICE_WATCHDOG_HANG=%s\n' "${SETUP_SERVICE_WATCHDOG:-${SERVICE_WATCHDOG:-1}}" \
    "${SETUP_SERVICE_WATCHDOG_HANG:-${SERVICE_WATCHDOG_HANG:-1}}"
  printf 'timer: %s / %s\n' "$(systemctl is-enabled "$WATCHDOG_TIMER" 2>/dev/null || true)" \
    "$(systemctl is-active "$WATCHDOG_TIMER" 2>/dev/null || true)"
  systemctl list-timers --all --no-pager "$WATCHDOG_TIMER" 2>/dev/null || true
  printf 'script: %s\n' "$( [[ -f $WATCHDOG_BIN ]] && printf '%s' "$WATCHDOG_BIN" || printf 'not installed')"
  for f in "$WATCHDOG_SYSTEMD_DIR"/*.service.d/"$WATCHDOG_DROPIN"; do
    [[ -f $f ]] && printf 'drop-in: %s\n' "$f"
  done
  while IFS= read -r u; do
    [[ -n $u ]] || continue
    wd_classify "$u"
    [[ $WD_CLS == up && $WD_ACTIVE == active ]] && pu+=("$u")
  done < <(wd_units)
  if (( ${#pu[@]} )); then
    f=$(mktemp -d 2>/dev/null) || f=""
    if [[ -n $f ]]; then
      wd_probe_all "$f" "${pu[@]}"
      for i in "${!pu[@]}"; do printf 'probe %s: %s\n' "${pu[i]}" "$(head -n1 "$f/$i" 2>/dev/null || true)"; done
      rm -rf -- "$f"
    fi
  fi
  for f in "$WD_STATE_DIR"/*; do
    [[ -f $f ]] && printf 'state %s: %s\n' "${f##*/}" "$(tr '\n' ' ' < "$f")"
  done
  printf -- '--- last watchdog journal lines\n'
  journalctl -t "$WD_TAG" -n 30 --no-pager 2>&1 || true
  return 0
}
