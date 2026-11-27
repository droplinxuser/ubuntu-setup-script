#!/usr/bin/env bash
# Unit tests for the 1.22.5 service watchdog (lib/watchdog.sh): the timer
# script's decision rule against fake `systemctl show` output (failed long
# enough -> restart, failed 30 s -> wait, stopped cleanly -> left alone,
# never started this boot -> restart, run/build lock held, CPU rebuild
# pending, build unit active, shutdown -> skip, 3 restarts per hour), the
# hang layer against fake probe commands (Valkey PONG/LOADING/BUSY/timeout/
# refused, MariaDB alive/Too many connections/timeout/Can't connect,
# Elasticsearch 503/no answer/https, nginx empty reply/refused/port 80,
# PHP-FPM FastCGI reply/timeout/missing socket/no ping.path, consecutive
# counting and its reset, the start grace, the busy-cgroup guard, the rate
# limit, logging once per state change, SERVICE_WATCHDOG_HANG=0), the
# crash-restart drop-in and timer texts (MariaDB keeps its own Restart=,
# Elasticsearch gets the drop-in), install/refresh idempotence, the
# SETUP_SERVICE_WATCHDOG=0 / _HANG=0 opt-outs and the --purge paths.
# No root, no services and no system changes are required: systemctl,
# logger, ss, curl, valkey-cli, mariadb-admin and php are fakes (a PATH
# directory for the script run, a shell function for the installer), and
# scratch data stays under /tmp.
# Usage: bash tests/unit/t-watchdog.sh
# The stubs are called indirectly by the functions under test.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

# tests/test-tuning.sh sources every unit file in a subshell after it has
# sourced setup.sh itself; setup.sh cannot be sourced twice, so run this
# file in a fresh shell instead.
if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-watchdog.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT

SD=$TMP/systemd            # unit directory (install target and discovery)
ST=$TMP/run-watchdog       # /run/setup-watchdog
FAKE=$TMP/fake             # the fake systemctl's state
mkdir -p "$SD" "$FAKE/bin" "$FAKE/props" "$TMP/sbin"

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
export SETUP_WATCHDOG_SYSTEMD_DIR=$SD SETUP_WATCHDOG_UNIT_DIRS=$SD SETUP_WATCHDOG_STATE_DIR=$ST
export SETUP_WATCHDOG_BIN=$TMP/sbin/setup-service-watchdog
export SETUP_TUNING_FILE=$TMP/setup-tuning
unset SETUP_SERVICE_WATCHDOG SERVICE_WATCHDOG SETUP_SERVICE_WATCHDOG_HANG SERVICE_WATCHDOG_HANG
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
trap 'rm -rf -- "$TMP"' EXIT
set +e

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-watchdog.sh,title=Watchdog test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
line_in() { grep -qxF -- "$2" "$1"; }
no_line() { ! grep -qxF -- "$2" "$1"; }

ALL_SRC_FILE=$TMP/all-source.sh
cat "$ROOT/setup.sh" "$ROOT"/lib/*.sh > "$ALL_SRC_FILE"

# ---------------------------------------------------------------------------
# The timer script, run as the unit runs it (bash FILE run), against fakes
# ---------------------------------------------------------------------------
cat > "$FAKE/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SD/calls"
case $1 in
  is-system-running) cat "$FAKE_SD/system" 2>/dev/null || echo running ;;
  list-units) cat "$FAKE_SD/busy" 2>/dev/null; exit 0 ;;
  show) u=${*: -1}; cat "$FAKE_SD/props/$u" 2>/dev/null; exit 0 ;;
  restart|reset-failed) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$FAKE/bin/logger" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SD/log"
EOF
# Probe fakes: $FAKE/probe/<name> holds the exit status on its first line
# and the output after it; without that file the command exits 99 (an
# inconclusive probe).  Every call is logged to $FAKE/probe-calls.
for c in ss curl valkey-cli redis-cli mariadb-admin php; do
  cat > "$FAKE/bin/$c" <<'EOF'
#!/bin/bash
n=${0##*/}
printf '%s %s\n' "$n" "$*" >> "$FAKE_SD/probe-calls"
f=$FAKE_SD/probe/$n
[[ -f $f ]] || exit 99
tail -n +2 "$f"
exit "$(head -n1 "$f")"
EOF
  chmod 755 "$FAKE/bin/$c"
done
chmod 755 "$FAKE/bin/systemctl" "$FAKE/bin/logger"
printf '[Service]\nExecStart=/bin/true\n' > "$SD/nginx.service"
printf '[Service]\nExecStart=/bin/true\n' > "$SD/php8.5-fpm.service"
printf '[Service]\nExecStart=/bin/true\nRestart=on-abnormal\nRestartSec=2\n' > "$SD/valkey-server.service"
: > "$TMP/build.lock"; : > "$TMP/run.lock"

props() { # unit active sub result [enabled] [inactive-exit-monotonic]
  printf 'LoadState=loaded\nUnitFileState=%s\nActiveState=%s\nSubState=%s\nResult=%s\nInactiveExitTimestampMonotonic=%s\n' \
    "${5:-enabled}" "$2" "$3" "$4" "${6:-123456}" > "$FAKE/props/$1"
}
# An enabled, active unit with a start time (microseconds since boot) and a
# control group: eligible for a liveness probe.
live() { # unit [active-enter-usec] [enabled]
  props "$1" active running success "${3:-enabled}"
  printf 'ActiveEnterTimestampMonotonic=%s\nControlGroup=/system.slice/%s\n' "${2:-1000000}" "$1" >> "$FAKE/props/$1"
}
probe() { # command exit-status [output-line...]
  mkdir -p "$FAKE/probe"
  { printf '%s\n' "$2"; [[ $# -gt 2 ]] && printf '%s\n' "${@:3}"; } > "$FAKE/probe/$1"
}
cgroup() { # unit cpu-usage-usec [io-bytes]
  mkdir -p "$TMP/cg/system.slice/$1"
  printf 'usage_usec %s\nuser_usec 0\nsystem_usec 0\n' "$2" > "$TMP/cg/system.slice/$1/cpu.stat"
  printf '8:0 rbytes=%s wbytes=0 rios=1 wios=0 dbytes=0 dios=0\n' "${3:-0}" > "$TMP/cg/system.slice/$1/io.stat"
}
reset_fake() {
  rm -rf -- "$ST" "$FAKE/props"/* "$FAKE/calls" "$FAKE/log" "$FAKE/system" "$FAKE/busy" "$TMP/cpu.attempts" "$TMP/wd-tuning" \
    "$FAKE/probe" "$FAKE/probe-calls" "$TMP/cg"
  : > "$FAKE/calls"; : > "$FAKE/log"; : > "$FAKE/probe-calls"
  # Valkey's TCP probe goes where ss shows it listening.
  probe ss 0 'LISTEN 0 511 127.0.0.1:6379 0.0.0.0:*'
  # Every probe below has answered once already (failures only count after a
  # first answer); the "never answered" cases remove these markers.
  mkdir -p "$ST"
  local u
  for u in valkey-server.service redis-server.service mariadb.service elasticsearch.service nginx.service php8.5-fpm.service; do
    : > "$ST/$u.seen"
  done
}
run_wd() { # now
  env PATH="$FAKE/bin:$PATH" FAKE_SD="$FAKE" SETUP_WATCHDOG_STATE_DIR="$ST" SETUP_WATCHDOG_UNIT_DIRS="$SD" \
    SETUP_BUILD_LOCK="$TMP/build.lock" SETUP_RUN_LOCK="$TMP/run.lock" SETUP_BUILD_CPU_ATTEMPTS="$TMP/cpu.attempts" \
    SETUP_TUNING_FILE="$TMP/wd-tuning" SETUP_WATCHDOG_NOW="$1" SETUP_WATCHDOG_MONO_NOW="${MONO:-100000}" \
    SETUP_WATCHDOG_CGROUP_ROOT="$TMP/cg" SETUP_WATCHDOG_PHP_ETC="$TMP/php" SETUP_WATCHDOG_PHP_ROOT="$TMP/no-php-build" \
    SETUP_WATCHDOG_VALKEY_CONF="$TMP/valkey.conf" SETUP_WATCHDOG_REDIS_CONF="$TMP/redis.conf" \
    SETUP_WATCHDOG_VALKEY_ROOT="$TMP/no-valkey-build" SETUP_WATCHDOG_ES_YML="$TMP/es.yml" \
    bash "${WD_FILE:-$ROOT/lib/watchdog.sh}" run
}
runs() { # now... : one pass per time
  local t
  for t in "$@"; do run_wd "$t"; done
}
restarted() { grep -qxF -- "restart --no-block -- $1" "$FAKE/calls"; }
calls_out() { cat "$FAKE/calls"; }

# (a) failed: first seen -> clock starts; 30 s -> waits; 60 s -> restart
reset_fake
props nginx.service failed failed exit-code
run_wd 1000
check "a failed unit starts its down clock" line_in "$ST/nginx.service.down" 1000
check "... and is not restarted at once" not restarted nginx.service
check "... the first sighting is logged" has "$(cat "$FAKE/log")" "nginx.service is down (failed/failed result=exit-code)"
run_wd 1030
check "failed for 30 s: still waiting" not restarted nginx.service
run_wd 1060
check "failed for 60 s: reset-failed + restart --no-block" bash -c 'grep -qxF "reset-failed -- nginx.service" "$1" && grep -qxF "restart --no-block -- nginx.service" "$1"' _ "$FAKE/calls"
check "... logged as a warning with the count" has "$(cat "$FAKE/log")" "nginx.service was down for 60 s (failed/failed result=exit-code); restart requested (1/3 this hour)"
check "... the restart is recorded" line_in "$ST/nginx.service.restarts" 1060
check "... and the next attempt waits a full minute again" not test -e "$ST/nginx.service.down"
check "the timer only reads the other units (no restart of php/valkey without props)" not grep -q "restart --no-block -- php\|restart --no-block -- valkey" "$FAKE/calls"

# (b) back up: the clock is cleared
props nginx.service failed failed exit-code
run_wd 2000
props nginx.service active running success
run_wd 2010
check "a unit that came back clears its down clock" not test -e "$ST/nginx.service.down"

# (c) stopped on purpose stays down
reset_fake
props php8.5-fpm.service inactive dead success enabled 987654
run_wd 1000; run_wd 1100
check "systemctl stop (inactive, Result=success) is left alone" not restarted php8.5-fpm.service
check "... and gets no down clock" not test -e "$ST/php8.5-fpm.service.down"

# (d) inactive with an error result, and never started this boot
reset_fake
props php8.5-fpm.service inactive dead exit-code
run_wd 1000; run_wd 1061
check "inactive with Result=exit-code is down and restarted" restarted php8.5-fpm.service
reset_fake
props valkey-server.service inactive dead success enabled 0
run_wd 1000; run_wd 1061
check "an enabled unit that never started this boot is restarted" restarted valkey-server.service
check "... logged as never started" has "$(cat "$FAKE/log")" "never started this boot"

# (e) not enabled / masked / activating
reset_fake
props nginx.service failed failed exit-code disabled
run_wd 1000; run_wd 1100
check "a disabled unit is never restarted" not restarted nginx.service
props nginx.service failed failed exit-code masked
run_wd 1200; run_wd 1300
check "a masked unit is never restarted" not restarted nginx.service
props valkey-server.service activating auto-restart signal
run_wd 1400; run_wd 1500
check "a unit in systemd's own auto-restart is left to systemd" not restarted valkey-server.service

# (f) global skips: each clears the clocks and restarts nothing
skip_case() { # desc setup-command...
  local desc=$1; shift
  reset_fake
  props nginx.service failed failed exit-code
  run_wd 1000
  "$@"
  run_wd 1100
  check "$desc: no restart" not restarted nginx.service
  check "$desc: the down clock restarts afterwards" not test -e "$ST/nginx.service.down"
}
skip_case "CPU-change rebuild pending" eval 'printf 1 > "$TMP/cpu.attempts"'
skip_case "setup-build-cpu.service running" eval 'printf "setup-build-cpu.service loaded activating start Rebuild\n" > "$FAKE/busy"'
skip_case "the 1.22 migration unit running" eval 'printf "setup-migrate-1.22.service loaded active running x\n" > "$FAKE/busy"'
skip_case "the host shutting down" eval 'echo stopping > "$FAKE/system"'
skip_case "the host still booting" eval 'echo starting > "$FAKE/system"'
reset_fake
props nginx.service failed failed exit-code
run_wd 1000
printf 'SERVICE_WATCHDOG=0\n' > "$TMP/wd-tuning"
run_wd 1100
check "SERVICE_WATCHDOG=0 in the host file: the script does nothing" not restarted nginx.service
rm -f "$TMP/wd-tuning"
echo degraded > "$FAKE/system"
run_wd 1200
check "a degraded system (some other unit failed) is not a skip: restarted" restarted nginx.service

if command -v flock >/dev/null 2>&1; then
  for lk in build run; do
    reset_fake
    props nginx.service failed failed exit-code
    run_wd 1000
    exec 7>>"$TMP/$lk.lock"
    flock -x 7
    run_wd 1100
    check "$lk lock held: no restart" not restarted nginx.service
    check "$lk lock held: the down clock is cleared" not test -e "$ST/nginx.service.down"
    flock -u 7; exec 7>&-
    run_wd 1200; run_wd 1260
    check "$lk lock released: restarted after a fresh 60 s" restarted nginx.service
  done
else
  t_pass "lock checks skipped (no flock on this host)"
fi

# (g) rate limit: at most 3 per rolling hour, one log line when giving up
reset_fake
props nginx.service failed failed exit-code
mkdir -p "$ST"
printf '%s\n' 5000 5500 6000 > "$ST/nginx.service.restarts"
run_wd 6100; run_wd 6200
check "3 restarts in the last hour: no fourth" not restarted nginx.service
check "... the give-up is logged" has "$(cat "$FAKE/log")" "after 3 restarts in the last hour"
check "... and marked" test -e "$ST/nginx.service.gaveup"
run_wd 6300; run_wd 6400
check "... the give-up is logged once" test "$(grep -c 'after 3 restarts in the last hour' "$FAKE/log")" = 1
run_wd 8700
check "once the oldest restart is an hour old, it tries again" restarted nginx.service
check "... and the old entries are pruned" test "$(wc -l < "$ST/nginx.service.restarts" | tr -d ' ')" = 3
check "... the give-up mark is cleared" not test -e "$ST/nginx.service.gaveup"

# ---------------------------------------------------------------------------
# Hang detection (layer 3): fake probes, counting, grace, busy guard
# ---------------------------------------------------------------------------
printf '[Service]\nType=notify\nExecStart=/bin/true\nRestart=on-abort\n' > "$SD/mariadb.service"
printf '[Service]\nType=notify\nExecStart=/bin/true\n' > "$SD/elasticsearch.service"
printf 'bind 127.0.0.1\nport 6379\n' > "$TMP/valkey.conf"
mkdir -p "$TMP/php/8.5/fpm/pool.d"
printf '[www]\nuser = www-data\nlisten = 127.0.0.1:9000\npm = static\nping.path = /setup-fpm-ping\n' > "$TMP/php/8.5/fpm/pool.d/www.conf"
printf 'cluster.name: test\nnetwork.host: "localhost"\nhttp.port: 9200\n' > "$TMP/es.yml"
pcalls() { cat "$FAKE/probe-calls"; }
logc() { grep -c -- "$1" "$FAKE/log"; }
hang_n() { cat "$ST/$1.hang" 2>/dev/null; }
LISTEN_443='LISTEN 0 511 0.0.0.0:443 0.0.0.0:*'
LISTEN_ES='LISTEN 0 4096 127.0.0.1:9200 0.0.0.0:*'

# (h) Valkey: PING over TCP when there is no unixsocket; PONG is alive.
reset_fake
live valkey-server.service
probe valkey-cli 0 PONG
run_wd 1000
check "valkey: PING to 127.0.0.1:6379 (no unixsocket, port 6379)" has "$(pcalls)" "valkey-cli -h 127.0.0.1 -p 6379 PING"
check "valkey: PONG is alive (no count, no log)" bash -c '[[ ! -e $1 && ! -s $2 ]]' _ "$ST/valkey-server.service.hang" "$FAKE/log"
check "valkey: no restart" not restarted valkey-server.service

# (i) no reply 3 times in a row -> restart; logged once, then the restart.
reset_fake
live valkey-server.service
probe valkey-cli 124
run_wd 1000
check "timeout: the first failed probe counts 1" test "$(hang_n valkey-server.service)" = 1
check "... and is logged" has "$(cat "$FAKE/log")" "valkey-server.service did not answer its liveness probe (no reply to PING on -h 127.0.0.1 -p 6379 in 10 s); restarting it after 3 failed probes in a row"
run_wd 1030
check "timeout: 2 in a row, no restart yet" bash -c '[[ $(cat "$1") == 2 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/valkey-server.service.hang" "$FAKE/calls"
check "... the failure is logged once, not every pass" test "$(logc 'did not answer its liveness probe')" = 1
run_wd 1060
check "timeout: 3 in a row -> reset-failed + restart --no-block" bash -c 'grep -qxF "reset-failed -- valkey-server.service" "$1" && grep -qxF "restart --no-block -- valkey-server.service" "$1"' _ "$FAKE/calls"
check "... logged as hung with the rate count" has "$(cat "$FAKE/log")" "valkey-server.service is active but hung: 3 liveness probes in a row failed (no reply to PING on -h 127.0.0.1 -p 6379 in 10 s); restart requested (1/3 this hour)"
check "... recorded in the shared restart list" line_in "$ST/valkey-server.service.restarts" 1060
check "... and the count starts again" not test -e "$ST/valkey-server.service.hang"
probe valkey-cli 0 PONG
run_wd 1090
check "after the restart: the recovery is logged once" bash -c '[[ $(grep -c "answers its liveness probe again" "$1") == 1 ]]' _ "$FAKE/log"
run_wd 1120
check "... and only once" test "$(logc 'answers its liveness probe again')" = 1

# (j) a success resets the count.
reset_fake
live valkey-server.service
probe valkey-cli 124
runs 1000 1030
probe valkey-cli 0 PONG
run_wd 1060
check "a success between failures resets the count" not test -e "$ST/valkey-server.service.hang"
probe valkey-cli 124
runs 1090 1120
check "... so two more failures do not restart" not restarted valkey-server.service
check "... the new failure streak is logged again" test "$(logc 'did not answer its liveness probe')" = 2

# (i2) a probe that has never answered since boot never counts (a probe this
# host does not match must not restart a healthy service 3 times an hour).
reset_fake
rm -f -- "$ST/valkey-server.service.seen"
live valkey-server.service
probe valkey-cli 124
for t in 1000 1030 1060 1090 1120; do run_wd "$t"; done
check "never answered: 5 failures do not restart" not restarted valkey-server.service
check "... nothing is counted" test -z "$(hang_n valkey-server.service)"
check "... logged once that hang restarts wait for a first answer" test "$(logc 'has not succeeded yet')" = 1
probe valkey-cli 0 PONG
run_wd 1150
check "... the first answer arms the hang layer" test -e "$ST/valkey-server.service.seen"
probe valkey-cli 124
for t in 1180 1210 1240; do run_wd "$t"; done
check "... after it, 3 failures in a row restart" restarted valkey-server.service

# (k) LOADING / BUSY / NOAUTH are alive; refused counts; an odd error is inconclusive.
for reply in "LOADING Valkey is loading the dataset in memory" "BUSY Valkey is busy running a script. You can only call SCRIPT KILL or SHUTDOWN NOSAVE." "NOAUTH Authentication required."; do
  reset_fake
  live valkey-server.service
  probe valkey-cli 0 "$reply"
  runs 1000 1030 1060 1090
  check "valkey: '${reply%% *}' is alive" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/valkey-server.service.hang" "$FAKE/calls"
done
reset_fake
live valkey-server.service
probe valkey-cli 1 "Could not connect to Valkey at 127.0.0.1:6379: Connection refused"
run_wd 1000
check "valkey: connection refused counts as a failed probe" test "$(hang_n valkey-server.service)" = 1
probe valkey-cli 1 "Unrecognized option or bad number of args"
run_wd 1030
check "valkey: an unexpected client error is inconclusive and resets the count" not test -e "$ST/valkey-server.service.hang"
reset_fake
live valkey-server.service
probe ss 0 'LISTEN 0 511 10.0.0.5:6379 0.0.0.0:*'
probe valkey-cli 0 PONG
run_wd 1000
check "valkey: a private-address bind is pinged there, not on 127.0.0.1" has "$(pcalls)" "valkey-cli -h 10.0.0.5 -p 6379 PING"
probe ss 0 'LISTEN 0 511 [::1]:6379 [::]:*'
run_wd 1030
check "valkey: an IPv6 loopback bind is pinged on ::1" has "$(pcalls)" "valkey-cli -h ::1 -p 6379 PING"
rm -f "$FAKE/probe/ss"
probe valkey-cli 1 "Could not connect to Valkey at 127.0.0.1:6379: Connection refused"
runs 1060 1090 1120 1150
check "valkey: nothing listening on its port is inconclusive (no PING, no count, no restart)" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2" && [[ $(grep -c "^valkey-cli" "$3") == 2 ]]' _ "$ST/valkey-server.service.hang" "$FAKE/calls" "$FAKE/probe-calls"
if command -v perl >/dev/null 2>&1; then
  reset_fake
  printf 'unixsocket %s\nport 0\n' "$TMP/vk.sock" > "$TMP/valkey.conf"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die' "$TMP/vk.sock"
  live valkey-server.service
  probe valkey-cli 0 PONG
  run_wd 1000
  check "valkey: PING over the configured unixsocket" has "$(pcalls)" "valkey-cli -s $TMP/vk.sock PING"
  rm -f "$TMP/vk.sock"
  run_wd 1030
  check "valkey: a missing socket with port 0 is a failed probe" bash -c '[[ $(cat "$1") == 1 ]] && grep -q "socket .* is missing" "$2"' _ "$ST/valkey-server.service.hang" "$FAKE/log"
  printf 'bind 127.0.0.1\nport 6379\n' > "$TMP/valkey.conf"
else
  t_pass "unix socket checks skipped (no perl on this host)"
fi

# (l) MariaDB: any server answer is alive; 5 failures; the 600 s start grace.
reset_fake
live mariadb.service
probe mariadb-admin 1 "mariadb-admin: connect to server at 'localhost' failed" "error: 'Too many connections'"
runs 1000 1030 1060 1090 1120 1150
check "mariadb: ping over the local socket with a 10 s connect timeout" has "$(pcalls)" "mariadb-admin --protocol=socket --connect-timeout=10 ping"
check "mariadb: 'Too many connections' is alive (the server answered)" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/mariadb.service.hang" "$FAKE/calls"
probe mariadb-admin 1 "mariadb-admin: connect to server at 'localhost' failed" "error: 'Access denied for user 'root'@'localhost''"
run_wd 1180
check "mariadb: 'Access denied' is alive" not test -e "$ST/mariadb.service.hang"
probe mariadb-admin 0 "mysqld is alive"
run_wd 1210
check "mariadb: 'mysqld is alive' is alive" not test -e "$ST/mariadb.service.hang"
reset_fake
live mariadb.service
probe mariadb-admin 124
runs 1000 1030 1060 1090
check "mariadb: 4 timeouts in a row are not enough" bash -c '[[ $(cat "$1") == 4 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/mariadb.service.hang" "$FAKE/calls"
check "... the log names the threshold of 5" has "$(cat "$FAKE/log")" "restarting it after 5 failed probes in a row"
run_wd 1120
check "mariadb: the 5th timeout restarts it" restarted mariadb.service
reset_fake
live mariadb.service
probe mariadb-admin 1 "mariadb-admin: connect to server at 'localhost' failed" "error: 'Can't connect to local server through socket '/run/mysqld/mysqld.sock' (111)'"
run_wd 1000
check "mariadb: Can't connect counts as a failed probe" test "$(hang_n mariadb.service)" = 1
probe mariadb-admin 1 "mariadb-admin: connect to server at 'localhost' failed" "error: 'Can't connect to local server through socket '/run/mysqld/mysqld.sock' (11)'"
run_wd 1030
check "mariadb: Can't connect (11), a full listen queue, is alive (saturated, not hung)" not test -e "$ST/mariadb.service.hang"
probe mariadb-admin 1 "mariadb-admin: connect to server at 'localhost' failed" "error: 'Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)'"
runs 1060 1090 1120 1150 1180 1210
check "mariadb: no socket at the client path (2) is inconclusive: no count, no restart" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/mariadb.service.hang" "$FAKE/calls"
reset_fake
live mariadb.service $(( 700 * 1000000 ))
probe mariadb-admin 124
MONO=1000 runs 1000 1030 1060 1090 1120 1150 1180
check "mariadb: no probe within 600 s of its start" lacks "$(pcalls)" "mariadb-admin"
check "... and no restart" not restarted mariadb.service
MONO=1300 run_wd 1210
check "mariadb: probed once the 600 s have passed" has "$(pcalls)" "mariadb-admin"
reset_fake
live nginx.service $(( 980 * 1000000 ))
probe ss 0 "$LISTEN_443"
probe curl 28 000
MONO=1000 run_wd 1000
check "nginx: no probe within 60 s of its start" lacks "$(pcalls)" "curl"
MONO=1041 run_wd 1030
check "nginx: probed 61 s after its start" has "$(pcalls)" "curl"

# (m) Elasticsearch: any HTTP status is alive; https; no listener is inconclusive.
reset_fake
live elasticsearch.service
probe ss 0 "$LISTEN_ES"
probe curl 0 503
runs 1000 1030 1060 1090 1120 1150
check "es: curl to / on the loopback HTTP port" has "$(pcalls)" "--max-time 10 http://127.0.0.1:9200/"
check "es: HTTP 503 is alive" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/elasticsearch.service.hang" "$FAKE/calls"
probe curl 0 401
run_wd 1180
check "es: HTTP 401 is alive" not test -e "$ST/elasticsearch.service.hang"
reset_fake
live elasticsearch.service
probe ss 0 "$LISTEN_ES"
probe curl 28 000
runs 1000 1030 1060 1090
check "es: 4 unanswered requests are not enough" bash -c '[[ $(cat "$1") == 4 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/elasticsearch.service.hang" "$FAKE/calls"
run_wd 1120
check "es: the 5th restarts it" restarted elasticsearch.service
reset_fake
live elasticsearch.service
printf 'network.host: 0.0.0.0\nhttp.port: 9201\nxpack.security.http.ssl.enabled: true\n' > "$TMP/es.yml"
probe ss 0 'LISTEN 0 4096 *:9201 *:*'
probe curl 0 401
run_wd 1000
check "es: https and http.port from elasticsearch.yml, wildcard bind -> loopback" has "$(pcalls)" "https://127.0.0.1:9201/"
printf 'http.port: 9202\nxpack.security.http.ssl:\n  enabled: true\n  keystore.path: certs/http.p12\n' > "$TMP/es.yml"
probe ss 0 'LISTEN 0 4096 *:9202 *:*'
run_wd 1030
check "es: the nested ES 8 auto-config ssl block means https" has "$(pcalls)" "https://127.0.0.1:9202/"
printf 'http.port: 9202\nxpack.security.http.ssl:\n  enabled: false\nxpack.security.transport.ssl:\n  enabled: true\n' > "$TMP/es.yml"
run_wd 1060
check "es: http ssl off (only transport ssl on) stays http" has "$(pcalls)" "http://127.0.0.1:9202/"
printf 'cluster.name: test\nnetwork.host: "localhost"\nhttp.port: 9200\n' > "$TMP/es.yml"
reset_fake
live elasticsearch.service
probe curl 28 000
runs 1000 1030 1060 1090 1120 1150
check "es: nothing listening on the port -> inconclusive, no curl, no restart" bash -c '! grep -q "^curl" "$1" && [[ ! -e $2 ]] && ! grep -q "restart --no-block" "$3"' _ "$FAKE/probe-calls" "$ST/elasticsearch.service.hang" "$FAKE/calls"

# (n) nginx: the catch-all's empty reply and a refused handshake are alive.
reset_fake
live nginx.service
probe ss 0 "$LISTEN_443"
probe curl 52 000
runs 1000 1030 1060 1090
check "nginx: curl -k to https://127.0.0.1/" has "$(pcalls)" "--max-time 10 https://127.0.0.1/"
check "nginx: the catch-all's empty reply (curl 52) is alive" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/nginx.service.hang" "$FAKE/calls"
probe curl 35 000
run_wd 1120
check "nginx: a refused TLS handshake (curl 35) is alive" not test -e "$ST/nginx.service.hang"
reset_fake
live nginx.service
probe ss 0 "$LISTEN_443"
probe curl 7 000
runs 1000 1030
check "nginx: refused twice, no restart yet" not restarted nginx.service
run_wd 1060
check "nginx: refused 3 times in a row -> restart" restarted nginx.service
reset_fake
live nginx.service
probe ss 0 'LISTEN 0 511 *:80 *:*'
probe curl 52 000
run_wd 1000
check "nginx: port 80 when nothing listens on 443" has "$(pcalls)" "http://127.0.0.1/"
probe ss 0 'LISTEN 0 511 192.0.2.10:443 0.0.0.0:*'
run_wd 1030
check "nginx: a specific bind address is probed there" has "$(pcalls)" "https://192.0.2.10/"
probe ss 0 'LISTEN 0 511 [::]:443 [::]:*'
run_wd 1060
check "nginx: an IPv6-only bind is probed on [::1]" has "$(pcalls)" "https://[::1]/"

# (o) PHP-FPM: a FastCGI request for ping.path through the PHP CLI.
reset_fake
live php8.5-fpm.service
probe php 0 "FastCGI reply (record type 6)"
runs 1000 1030 1060 1090
check "php: the FastCGI client gets the pool target, timeout and ping.path" has "$(pcalls)" "-- tcp://127.0.0.1:9000 10 /setup-fpm-ping"
check "php: run as php -n (no ini, no OPcache/JIT start-up)" has "$(pcalls)" "php -n -d display_errors=0 -r"
check "php: a FastCGI reply is alive" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/php8.5-fpm.service.hang" "$FAKE/calls"
probe php 4 "closed by FPM without a reply"
run_wd 1120
check "php: closed by FPM (it answered the connection) is alive" not test -e "$ST/php8.5-fpm.service.hang"
probe php 7 "listen queue full (pool saturated): Resource temporarily unavailable"
runs 1150 1180 1210
check "php: a full listen queue (EAGAIN) is saturated, not hung: alive" bash -c '[[ ! -e $1 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/php8.5-fpm.service.hang" "$FAKE/calls"
reset_fake
live php8.5-fpm.service
probe php 5 "no reply in 10 s"
runs 1000 1030 1060
check "php: no FastCGI reply 3 times -> restart" restarted php8.5-fpm.service
reset_fake
live php8.5-fpm.service
printf '[www]\nlisten = %s\nping.path = /setup-fpm-ping\n' "$TMP/no-such.sock" > "$TMP/php/8.5/fpm/pool.d/www.conf"
run_wd 1000
check "php: a missing pool socket is a failed probe" bash -c '[[ $(cat "$1") == 1 ]] && grep -q "socket .*no-such.sock is missing" "$2"' _ "$ST/php8.5-fpm.service.hang" "$FAKE/log"
printf '[www]\nlisten = 127.0.0.1:9000\n' > "$TMP/php/8.5/fpm/pool.d/www.conf"
probe php 5 "no reply in 10 s"
runs 1030 1060 1090 1120
check "php: a pool without ping.path is not probed (no log noise)" bash -c '! grep -q "^php" "$1" && [[ ! -e $2 ]]' _ "$FAKE/probe-calls" "$ST/php8.5-fpm.service.hang"
printf '[www]\nuser = www-data\nlisten = 127.0.0.1:9000\npm = static\nping.path = /setup-fpm-ping\n' > "$TMP/php/8.5/fpm/pool.d/www.conf"
PHP_REAL=$(command -v php 2>/dev/null || true)
if [[ -n $PHP_REAL ]]; then
  { printf '<?php\n'; wd_fcgi_client; } > "$TMP/fcgi.php"
  check "the embedded FastCGI client is valid PHP" "$PHP_REAL" -n -l "$TMP/fcgi.php"
else
  t_pass "FastCGI client lint skipped (no php on this host)"
fi

# (p) a busy cgroup is not hung: high CPU or disk I/O since the last pass.
reset_fake
live mariadb.service
probe mariadb-admin 124
cgroup mariadb.service 1000000
run_wd 1000
check "busy guard: no previous sample, the failure counts" test "$(hang_n mariadb.service)" = 1
cgroup mariadb.service 31000000
run_wd 1030
check "busy guard: 30 s of CPU in 30 s -> busy, the count is cleared" not test -e "$ST/mariadb.service.hang"
check "... logged as working, not hung" has "$(cat "$FAKE/log")" "mariadb.service did not answer its liveness probe (no answer to ping in 10 s) but is working (CPU 100% of a core); not counted as hung"
cgroup mariadb.service 61000000
run_wd 1060
check "... logged once while it stays busy" test "$(logc 'but is working')" = 1
cgroup mariadb.service 61000000 $(( 90 * 1024 * 1024 ))
run_wd 1090
check "busy guard: 3 MB/s of disk I/O is busy too" not test -e "$ST/mariadb.service.hang"
runs 1120 1150 1180 1210
check "idle again: failures count from 1 (4 so far, no restart)" bash -c '[[ $(cat "$1") == 4 ]] && ! grep -q "restart --no-block" "$2"' _ "$ST/mariadb.service.hang" "$FAKE/calls"
run_wd 1240
check "idle and unanswered 5 times -> restart" restarted mariadb.service

# (q) the rate limit is shared with the down layer; give-up logged once.
reset_fake
live nginx.service
probe ss 0 "$LISTEN_443"
probe curl 28 000
mkdir -p "$ST"
printf '%s\n' 500 600 700 > "$ST/nginx.service.restarts"
runs 1000 1030 1060 1090 1120
check "hang: 3 restarts in the last hour -> no fourth" not restarted nginx.service
check "... the give-up is logged once" test "$(logc 'is still hung')" = 1
runs 4400 4430 4460
check "... an hour later it restarts again" restarted nginx.service

# (r) opt-out, skips and ineligible units.
reset_fake
printf 'SERVICE_WATCHDOG_HANG=0\n' > "$TMP/wd-tuning"
live nginx.service
probe ss 0 "$LISTEN_443"
probe curl 28 000
props php8.5-fpm.service failed failed exit-code
runs 1000 1030 1060 1090
check "SERVICE_WATCHDOG_HANG=0: no probe at all" not grep -q "^curl" "$FAKE/probe-calls"
check "... no hang restart" not restarted nginx.service
check "... the down layer still restarts a failed unit" restarted php8.5-fpm.service
reset_fake
live nginx.service
probe ss 0 "$LISTEN_443"
probe curl 28 000
runs 1000 1030
printf 1 > "$TMP/cpu.attempts"
run_wd 1060
check "a global skip clears the probe count" not test -e "$ST/nginx.service.hang"
check "... and probes nothing" test "$(grep -c '^curl' "$FAKE/probe-calls")" = 2
reset_fake
props elasticsearch.service activating start ""
props mariadb.service reloading reload success
probe curl 28 000
probe mariadb-admin 124
runs 1000 1030 1060 1090 1120 1150
check "activating/reloading units are never probed or restarted" bash -c '! grep -qE "^(curl|mariadb-admin)" "$1" && ! grep -q "restart --no-block" "$2"' _ "$FAKE/probe-calls" "$FAKE/calls"
reset_fake
live mariadb.service 1000000 disabled
probe mariadb-admin 124
runs 1000 1030 1060 1090 1120 1150
check "a disabled (but running) unit is never probed" not grep -q "^mariadb-admin" "$FAKE/probe-calls"
reset_fake
live nginx.service
live valkey-server.service
probe ss 0 "$LISTEN_443" 'LISTEN 0 511 127.0.0.1:6379 0.0.0.0:*'
probe curl 52 000
probe valkey-cli 0 PONG
run_wd 1000
check "several units are probed in the same pass" bash -c 'grep -q "^curl" "$1" && grep -q "^valkey-cli" "$1"' _ "$FAKE/probe-calls"
check "... the per-pass probe directory is removed" bash -c '! compgen -G "$1/probe.*" >/dev/null' _ "$ST"

# ---------------------------------------------------------------------------
# Installer: drop-in, units, idempotence, opt-out, purge
# ---------------------------------------------------------------------------
SDLOG=$TMP/sd-installer.log
TIMER_ON=$TMP/timer-enabled
mkdir -p "$TMP/en"
systemctl() {
  printf '%s\n' "$*" >> "$SDLOG"
  case $1 in
    is-enabled)
      if [[ $2 == setup-service-watchdog.timer ]]; then [[ -e $TIMER_ON ]] && echo enabled || echo disabled
      else cat "$TMP/en/$2" 2>/dev/null || echo disabled; fi ;;
    is-active) [[ $2 == -q ]] && { [[ -e $TIMER_ON ]]; return; }; [[ -e $TIMER_ON ]] && echo active || echo inactive ;;
    enable) touch "$TIMER_ON" ;;
    disable) rm -f "$TIMER_ON" ;;
    *) return 0 ;;
  esac
}
REPORT=()
rep() { REPORT+=("$*"); }
echo enabled > "$TMP/en/nginx.service"
echo enabled > "$TMP/en/php8.5-fpm.service"
echo enabled > "$TMP/en/valkey-server.service"

: > "$SDLOG"
watchdog_ensure rep "- "
d_ng=$SD/nginx.service.d/zz-setup-watchdog.conf
d_php=$SD/php8.5-fpm.service.d/zz-setup-watchdog.conf
check "install: nginx gets the crash-restart drop-in" test -f "$d_ng"
check "install: PHP-FPM gets it" test -f "$d_php"
check "install: Valkey (own Restart=) gets none" not test -e "$SD/valkey-server.service.d/zz-setup-watchdog.conf"
check "install: MariaDB keeps its packaged Restart=on-abort (no drop-in)" not test -e "$SD/mariadb.service.d/zz-setup-watchdog.conf"
check "install: Elasticsearch (no Restart= in its unit) gets the drop-in" test -f "$SD/elasticsearch.service.d/zz-setup-watchdog.conf"
check "drop-in: Restart=on-abnormal" line_in "$d_ng" "Restart=on-abnormal"
check "drop-in: RestartSec=5s" line_in "$d_ng" "RestartSec=5s"
check "drop-in: a start limit that allows a few attempts" bash -c 'grep -qx "StartLimitIntervalSec=300" "$1" && grep -qx "StartLimitBurst=5" "$1"' _ "$d_ng"
check "drop-in: no Restart=always/on-failure (the CPU gate's exit 1 must not loop)" not grep -qE '^Restart=(always|on-failure)' "$d_ng"
check "drop-in: managed marker" grep -qF "$WATCHDOG_MARK" "$d_ng"
check "timer: OnBootSec=2min" line_in "$SD/setup-service-watchdog.timer" "OnBootSec=2min"
check "timer: OnUnitActiveSec=30s" line_in "$SD/setup-service-watchdog.timer" "OnUnitActiveSec=30s"
check "timer: AccuracySec=5s" line_in "$SD/setup-service-watchdog.timer" "AccuracySec=5s"
check "service: oneshot running the installed script" bash -c 'grep -qx "Type=oneshot" "$1" && grep -qx "ExecStart=/bin/bash $2 run" "$1"' _ "$SD/setup-service-watchdog.service" "$SETUP_WATCHDOG_BIN"
check "service: quiet journal (LogLevelMax=notice)" line_in "$SD/setup-service-watchdog.service" "LogLevelMax=notice"
check "script installed as a copy of lib/watchdog.sh, mode 755" bash -c 'cmp -s "$1" "$2" && [[ -x $2 ]]' _ "$ROOT/lib/watchdog.sh" "$SETUP_WATCHDOG_BIN"
check "install: daemon-reload" line_in "$SDLOG" "daemon-reload"
check "install: timer enabled and started" line_in "$SDLOG" "enable --now setup-service-watchdog.timer"
check "install: one report line" test "${#REPORT[@]}" = 1
check "install: the report names the units" has "${REPORT[0]}" "- Service watchdog: on for elasticsearch.service mariadb.service nginx.service php8.5-fpm.service valkey-server.service"
check "install: the report names the hang layer and its thresholds" has "${REPORT[0]}" "hang restart after 3 failed liveness probes in a row (5 for MariaDB/Elasticsearch"
check "install: the report names the crash drop-ins" has "${REPORT[0]}" "crash restart drop-in: elasticsearch.service nginx.service php8.5-fpm.service;"
check "install: no unit was restarted" not grep -qE '^(restart|stop|start) ' "$SDLOG"

: > "$SDLOG"; REPORT=()
watchdog_ensure rep "- "
check "rerun: idempotent (no daemon-reload, no enable)" not grep -qE '^(daemon-reload|enable)' "$SDLOG"
check "rerun: still one report line" test "${#REPORT[@]}" = 1

# The installed copy runs like the library (bash FILE run).
reset_fake
props nginx.service failed failed exit-code
WD_FILE=$SETUP_WATCHDOG_BIN run_wd 1000
WD_FILE=$SETUP_WATCHDOG_BIN run_wd 1070
check "the installed script restarts a unit down for 60 s" restarted nginx.service

# A unit with its own Restart= loses the drop-in; a gone PHP version's goes.
printf '[Service]\nExecStart=/bin/true\nRestart=always\n' > "$SD/nginx.service"
mkdir -p "$SD/php8.3-fpm.service.d"
watchdog_dropin_text > "$SD/php8.3-fpm.service.d/zz-setup-watchdog.conf"
mkdir -p "$SD/php8.4-fpm.service.d"
printf '[Service]\nRestart=no\n' > "$SD/php8.4-fpm.service.d/zz-setup-watchdog.conf"
: > "$SDLOG"; REPORT=()
watchdog_ensure rep "- "
check "a unit with its own Restart= gets no drop-in" not test -e "$d_ng"
check "a stale drop-in for a removed PHP version is removed" not test -e "$SD/php8.3-fpm.service.d"
check "an operator file with the same name (no marker) is left alone" test -f "$SD/php8.4-fpm.service.d/zz-setup-watchdog.conf"
check "changes reload systemd" line_in "$SDLOG" "daemon-reload"
rm -rf "$SD/php8.4-fpm.service.d"
printf '[Service]\nExecStart=/bin/true\n' > "$SD/nginx.service"
watchdog_ensure rep "- "
# An operator drop-in with Restart= wins: ours (sorting last) would override it.
printf '[Service]\nRestart=always\n' > "$SD/elasticsearch.service.d/override.conf"
watchdog_ensure rep "- "
check "a unit whose other drop-in sets Restart= loses ours" not test -e "$SD/elasticsearch.service.d/zz-setup-watchdog.conf"
check "... the operator's drop-in stays" test -f "$SD/elasticsearch.service.d/override.conf"
rm -f "$SD/elasticsearch.service.d/override.conf"
watchdog_ensure rep "- "
check "... and ours comes back once it is gone" test -f "$SD/elasticsearch.service.d/zz-setup-watchdog.conf"

# Opt-out: SETUP_SERVICE_WATCHDOG=0 removes everything and persists.
mkdir -p "$ST"; : > "$ST/nginx.service.down"
: > "$SDLOG"; REPORT=()
SETUP_SERVICE_WATCHDOG=0 watchdog_ensure rep "- "
check "opt-out: drop-ins removed" bash -c '! compgen -G "$1/*.service.d/zz-setup-watchdog.conf" >/dev/null' _ "$SD"
check "opt-out: timer and service removed" bash -c '[[ ! -e $1/setup-service-watchdog.timer && ! -e $1/setup-service-watchdog.service ]]' _ "$SD"
check "opt-out: script removed" not test -e "$SETUP_WATCHDOG_BIN"
check "opt-out: /run state removed" not test -e "$ST"
check "opt-out: timer disabled" line_in "$SDLOG" "disable --now setup-service-watchdog.timer"
check "opt-out: persisted as SERVICE_WATCHDOG=0" line_in "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG=0"
check "opt-out: report says removed" has "${REPORT[0]}" "Service watchdog: removed (SERVICE_WATCHDOG=0"
REPORT=()
SERVICE_WATCHDOG=0 watchdog_ensure rep "- "
check "persisted off: stays off" has "${REPORT[0]}" "Service watchdog: off (SERVICE_WATCHDOG=0)"
check "persisted off: nothing installed" not test -e "$SD/setup-service-watchdog.timer"
rm -f "$SETUP_TUNING_FILE"
SERVICE_WATCHDOG=0 watchdog_ensure rep "- "
check "an off choice the profile reset moved away is written back" line_in "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG=0"
REPORT=()
SETUP_SERVICE_WATCHDOG=1 watchdog_ensure rep "- "
check "SETUP_SERVICE_WATCHDOG=1 brings it back" test -f "$SD/setup-service-watchdog.timer"
check "... and persists =1" line_in "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG=1"
rm -f "$SETUP_TUNING_FILE"

# Hang opt-out: SETUP_SERVICE_WATCHDOG_HANG=0 persists, keeps the rest.
REPORT=()
SETUP_SERVICE_WATCHDOG_HANG=0 watchdog_ensure rep "- "
check "hang opt-out: persisted as SERVICE_WATCHDOG_HANG=0" line_in "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG_HANG=0"
check "hang opt-out: the report says hang restart off" has "${REPORT[0]}" "hang restart off (SERVICE_WATCHDOG_HANG=0)"
check "hang opt-out: timer and drop-ins stay" bash -c '[[ -f $1/setup-service-watchdog.timer && -f $1/nginx.service.d/zz-setup-watchdog.conf ]]' _ "$SD"
check "hang opt-out: SERVICE_WATCHDOG itself is not written" no_line "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG=0"
rm -f "$SETUP_TUNING_FILE"
REPORT=()
SERVICE_WATCHDOG_HANG=0 watchdog_ensure rep "- "
check "hang opt-out moved away by the profile reset is written back" line_in "$SETUP_TUNING_FILE" "SERVICE_WATCHDOG_HANG=0"
REPORT=()
SETUP_SERVICE_WATCHDOG_HANG=1 watchdog_ensure rep "- "
check "SETUP_SERVICE_WATCHDOG_HANG=1 turns it back on and persists =1" bash -c 'grep -qx "SERVICE_WATCHDOG_HANG=1" "$1" && [[ $2 == *"hang restart after 3 failed"* ]]' _ "$SETUP_TUNING_FILE" "${REPORT[0]}"
check "the profile reset keeps SERVICE_WATCHDOG_HANG (RESET_KEEP_PINS)" has " ${RESET_KEEP_PINS[*]} " " SERVICE_WATCHDOG_HANG "
rm -f "$SETUP_TUNING_FILE"

# No managed unit at all: nothing installed, nothing reported.
mkdir -p "$TMP/empty"
REPORT=()
( WD_UNIT_DIRS=$TMP/empty WATCHDOG_SYSTEMD_DIR=$TMP/empty WATCHDOG_BIN=$TMP/empty/bin watchdog_ensure rep "- "
  [[ ${#REPORT[@]} == 0 && ! -e $TMP/empty/setup-service-watchdog.timer ]] )
check "no nginx/PHP/Valkey unit: nothing installed or reported" test $? = 0

# Purge: nginx only -> its drop-in; PHP still enabled keeps the rest.
watchdog_ensure rep "- " >/dev/null
check "purge setup: nginx drop-in present" test -f "$d_ng"
rm -f "$SD/nginx.service"; rm -f "$TMP/en/nginx.service"
watchdog_purge_targets nginx >/dev/null
check "purge nginx: its drop-in goes" not test -e "$d_ng"
check "purge nginx: PHP's stays" test -f "$d_php"
check "purge nginx: the timer stays while PHP/Valkey are enabled" test -f "$SD/setup-service-watchdog.timer"
# Purge the remaining services -> nothing enabled -> everything goes.
echo disabled > "$TMP/en/php8.5-fpm.service"; echo disabled > "$TMP/en/valkey-server.service"
watchdog_purge_targets php valkey >/dev/null
check "purge of the last services: drop-ins gone" not test -e "$d_php"
check "purge of the last services: timer/service/script gone" bash -c '[[ ! -e $1/setup-service-watchdog.timer && ! -e $1/setup-service-watchdog.service && ! -e $2 ]]' _ "$SD" "$SETUP_WATCHDOG_BIN"
# Purge with basic removes everything at once.
echo enabled > "$TMP/en/php8.5-fpm.service"
printf '[Service]\nExecStart=/bin/true\n' > "$SD/nginx.service"; echo enabled > "$TMP/en/nginx.service"
watchdog_ensure rep "- " >/dev/null
mkdir -p "$ST"; : > "$ST/php8.5-fpm.service.down"
out=$(watchdog_purge_targets nginx php mariadb valkey elastic basic 2>&1)
check "purge basic: drop-ins, timer, service, script and /run state gone" bash -c '! compgen -G "$1/*.service.d/zz-setup-watchdog.conf" >/dev/null && [[ ! -e $1/setup-service-watchdog.timer && ! -e $2 && ! -e $3 ]]' _ "$SD" "$SETUP_WATCHDOG_BIN" "$ST"
check "purge basic: says so" has "$out" "Service watchdog removed"
watchdog_purge_targets basic >/dev/null 2>&1
check "purge is idempotent" test $? = 0
# Purge of MariaDB / Elasticsearch: their drop-ins go, the rest stays.
printf '[Service]\nExecStart=/bin/true\n' > "$SD/mariadb.service"
watchdog_ensure rep "- " >/dev/null
check "purge setup: a MariaDB unit without its own Restart= gets the drop-in" test -f "$SD/mariadb.service.d/zz-setup-watchdog.conf"
watchdog_purge_targets mariadb elastic >/dev/null
check "purge mariadb elastic: their drop-ins go" bash -c '[[ ! -e $1/mariadb.service.d/zz-setup-watchdog.conf && ! -e $1/elasticsearch.service.d/zz-setup-watchdog.conf ]]' _ "$SD"
check "purge mariadb elastic: nginx keeps its drop-in, the timer stays" bash -c '[[ -f $1/nginx.service.d/zz-setup-watchdog.conf && -f $1/setup-service-watchdog.timer ]]' _ "$SD"
watchdog_purge_targets basic >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
check "setup.sh sources lib/watchdog.sh" grep -qF 'source "${SCRIPT_DIR}/lib/watchdog.sh"' "$ROOT/setup.sh"
check "--optimize installs it with one report line" \
  bash -c 'sed -n "/^run_optimize()/,/^}/p" "$1" | grep -qF "watchdog_ensure opt_report \"- \""' _ "$ALL_SRC_FILE"
check "an install run installs it after the managed crontab" \
  bash -c 'sed -n "/^main()/,/^}/p" "$1" | grep -qF "watchdog_ensure info"' _ "$ALL_SRC_FILE"
check "--purge removes it" \
  bash -c 'sed -n "/^run_purge()/,/^}/p" "$1" | grep -qF "watchdog_purge_targets \"\${PURGE_ORDER[@]}\""' _ "$ALL_SRC_FILE"
check "--diagnostics shows it" \
  bash -c 'sed -n "/^run_diagnostics()/,/^}/p" "$1" | grep -qF "watchdog_status"' _ "$ALL_SRC_FILE"
check "the status lists the timer and the watchdog journal" \
  bash -c 'sed -n "/^watchdog_status()/,/^}/p" "$1" | grep -qF "journalctl -t \"\$WD_TAG\""' _ "$ROOT/lib/watchdog.sh"
check "the status runs one probe per active unit and shows the hang choice" \
  bash -c 'sed -n "/^watchdog_status()/,/^}/p" "$1" | grep -qF "wd_probe_all" && sed -n "/^watchdog_status()/,/^}/p" "$1" | grep -qF "SERVICE_WATCHDOG_HANG="' _ "$ROOT/lib/watchdog.sh"
check "the PHP tuner adds ping.path only when the pool has none" \
  bash -c 'sed -n "/^tune_php_fpm_version()/,/^}/p" "$1" | grep -qF "grep -qE '"'"'^[[:space:]]*ping\.path[[:space:]]*='"'"' \"\$pool\"" && sed -n "/^tune_php_fpm_version()/,/^}/p" "$1" | grep -qF "tune_pool_set \"\$pool\" ping.path /setup-fpm-ping"' _ "$ROOT/lib/web.sh"
check "the probe's ping path matches the tuner's" grep -qxF 'WD_FPM_PING_PATH=/setup-fpm-ping' "$ROOT/lib/watchdog.sh"
check "the ping path is set by the tuner only (no shipped config exposes it)" \
  bash -c '! grep -rqF "setup-fpm-ping" "$1/configs" 2>/dev/null' _ "$ROOT"
check "README documents SETUP_SERVICE_WATCHDOG_HANG" grep -qF 'SETUP_SERVICE_WATCHDOG_HANG=0' "$ROOT/README.md"
check "the run-lock path matches lib/common.sh" bash -c 'grep -qF "readonly LOCK_FILE=\"/run/setup.sh.lock\"" "$1/lib/common.sh" && grep -qF "SETUP_RUN_LOCK:-/run/setup.sh.lock" "$1/lib/watchdog.sh"' _ "$ROOT"
check "the build-lock and CPU-attempts paths match tools/build-common.sh" bash -c 'grep -qF "SETUP_BUILD_LOCK:-/run/setup-build.lock" "$1/tools/build-common.sh" && grep -qF "SETUP_BUILD_CPU_ATTEMPTS:-/run/setup-build-cpu.attempts" "$1/tools/build-common.sh" && grep -qF "SETUP_BUILD_LOCK:-/run/setup-build.lock" "$1/lib/watchdog.sh" && grep -qF "SETUP_BUILD_CPU_ATTEMPTS:-/run/setup-build-cpu.attempts" "$1/lib/watchdog.sh"' _ "$ROOT"

# Review fix: wd_units returns 0 even when the last unit file it looks for is
# missing (a non-zero pipeline under set -E fired the ERR trap in the
# process substitution of every caller).
mkdir -p "$TMP/wdu"; : > "$TMP/wdu/nginx.service"
wdu_rc=0; ( set -Eeuo pipefail; WD_UNIT_DIRS=$TMP/wdu; wd_units >/dev/null ) || wdu_rc=$?
check "wd_units returns 0 when elasticsearch.service (the last name) is absent" test "$wdu_rc" = 0
check "wd_units still lists the units that exist" test "$(WD_UNIT_DIRS=$TMP/wdu wd_units)" = "nginx.service"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
