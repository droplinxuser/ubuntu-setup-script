#!/usr/bin/env bash
# Unit tests for the 1.22.5 Valkey/Redis changes: RDB snapshots by default
# (save 300 1) and the version policy that follows from it, socket-only
# Valkey (port 0) with its keep-TCP safety checks, the Redis 6.0 directive
# set, the removal of maxmemory-policy noeviction, the application cache
# audit (custom socket, per-site prefixes, XenForo sessions) and the BOLT
# profile on a private server.
# No root, no services and no system changes are required: every function
# that would touch the host runs with stubs, and scratch data stays under
# /tmp.
# Usage: bash tests/unit/t-valkey.sh
# The suites assign globals the sourced helpers read; ShellCheck cannot
# follow that across the source boundary.  The stubs are called indirectly.
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
TMP=$(mktemp -d /tmp/setup-test-valkey.XXXXXX)

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
set +e

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-valkey.sh,title=Valkey test failed::%s\n' "$*"
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

# Every sourced function body, for the structural checks.
ALL_SRC_FILE=$TMP/all-source.sh
cat "$ROOT/setup.sh" "$ROOT"/lib/*.sh > "$ALL_SRC_FILE"

# Host-independent sizing for the writer.
php_pool_max_children() { printf '64'; }
effective_backlog() { printf '4096'; }
# The live checks never see this host's sockets, PHP or systemd units.
SS_FLOWS="" SS_LISTEN=0 SS_CALLS=$TMP/ss.calls
valkey_ss_flows() { printf 'x\n' >> "$SS_CALLS"; [[ -n $SS_FLOWS ]] && printf '%s\n' "$SS_FLOWS"; return 0; }
valkey_ss_listening() { [[ $SS_LISTEN == 1 ]]; }
export VALKEY_SCAN_PHP_ETC=$TMP/php VALKEY_TCP_SAMPLE_SLEEP=0 VALKEY_SYSTEMD_DIR=$TMP/systemd
mkdir -p "$VALKEY_SCAN_PHP_ETC" "$VALKEY_SYSTEMD_DIR"

# ---------------------------------------------------------------------------
# A2: adopted Redis 6.0 gets only directives it knows
# ---------------------------------------------------------------------------
redis_case() { # version kind -> the writer's output for that redis-server
  (
    RV=$1
    redis-server() { printf 'Redis server v=%s sha=00000000:0 malloc=jemalloc-5.2.1 bits=64 build=0\n' "$RV"; }
    VALKEY_REDIS_VERSION_CACHE=""
    f=$TMP/redis-$1-$2.conf
    printf 'port 6379\n' > "$f"
    valkey_apply_config "$f" "$2" 512 allkeys-lru "/run/$2/$2.sock" adopt socket
    cat "$f"
  ) 2>/dev/null
}
out=$(redis_case 6.0.16 redis)
check "Redis 6.0.16: no lazyfree-lazy-user-flush (added in 6.2)" lacks "$out" "lazyfree-lazy-user-flush"
check "Redis 6.0.16: bind without the '-' optional prefix" has "$out" $'\nbind 127.0.0.1 ::1\n'
check "Redis 6.0.16: lazyfree-lazy-user-del is kept (6.0 has it)" has "$out" "lazyfree-lazy-user-del yes"
check "Redis 6.0.16: the RDB snapshot keys are written (all exist in 6.0)" \
  has "$out" $'save 300 1\nappendonly no\nrdbcompression yes\nrdb-save-incremental-fsync yes\nstop-writes-on-bgsave-error no'
out=$(redis_case 7.2.4 redis)
check "Redis 7.2: lazyfree-lazy-user-flush and the optional ::1 bind" \
  bash -c '[[ $1 == *"lazyfree-lazy-user-flush yes"* && $1 == *"bind 127.0.0.1 -::1"* ]]' _ "$out"
out=$(redis_case 6.2.0 redis)
check "Redis 6.2.0 counts as current" has "$out" "lazyfree-lazy-user-flush yes"
out=$(redis_case 6.0.16 valkey)
check "kind valkey is never treated as old Redis" has "$out" "lazyfree-lazy-user-flush yes"
out=$( ( redis-server() { printf 'Redis server v=6.0.16 sha=0\n'; }; VALKEY_REDIS_VERSION_CACHE=""; valkey_runtime_settings 512 allkeys-lru redis ) )
check "Redis 6.0.16: the online CONFIG SET list has no lazyfree-lazy-user-flush" lacks "$out" "lazyfree-lazy-user-flush"
out=$( ( redis-server() { return 127; }; VALKEY_REDIS_VERSION_CACHE=""; valkey_tuning_lines 512 allkeys-lru redis ) )
check "an unreadable Redis version counts as current" has "$out" "lazyfree-lazy-user-flush yes"

# ---------------------------------------------------------------------------
# V1: RDB snapshots every 5 minutes
# ---------------------------------------------------------------------------
# The rest never depends on a redis-server the test host may have.
VALKEY_REDIS_VERSION_CACHE=none
vf=$TMP/v1.conf
printf 'port 6379\ndir /var/lib/valkey\nsave ""\nappendonly no\ndaemonize no\n' > "$vf"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "V1: save 300 1 replaces save \"\"" line_in "$vf" 'save 300 1'
check "V1: no save \"\" is left" no_line "$vf" 'save ""'
check "V1: appendonly no" line_in "$vf" 'appendonly no'
check "V1: rdbcompression yes" line_in "$vf" 'rdbcompression yes'
check "V1: rdb-save-incremental-fsync yes" line_in "$vf" 'rdb-save-incremental-fsync yes'
check "V1: a failed snapshot never stops writes" line_in "$vf" 'stop-writes-on-bgsave-error no'
check "V1: dump.rdb in the existing persistent dir" \
  bash -c 'grep -qx "dir /var/lib/valkey" "$1" && grep -qx "dbfilename dump.rdb" "$1" && [[ $(grep -c "^dir " "$1") == 1 ]]' _ "$vf"
cp "$vf" "$vf.1"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "V1: the writer is idempotent" cmp -s "$vf" "$vf.1"
vf=$TMP/v1-redis.conf
printf 'dir /srv/redis-data\ndbfilename cache.rdb\nsave 900 1\nsave 300 10\n' > "$vf"
valkey_apply_config "$vf" redis 512 allkeys-lru /run/redis/redis.sock adopt socket
check "V1 adopt: an adopted server keeps its own dir and dbfilename (data kept)" \
  bash -c 'grep -qx "dir /srv/redis-data" "$1" && grep -qx "dbfilename cache.rdb" "$1"' _ "$vf"
check "V1 adopt: an adopted RDB schedule becomes the 5-minute snapshot, not save \"\"" \
  bash -c 'grep -qx "save 300 1" "$1" && ! grep -qE "^save (900|300 10|\"\")" "$1"' _ "$vf"
vf=$TMP/v1-nodir.conf
printf 'port 6379\n' > "$vf"
valkey_apply_config "$vf" redis 512 allkeys-lru /run/redis/redis.sock adopt socket
check "V1: a conf without dir gets /var/lib/KIND" line_in "$vf" 'dir /var/lib/redis'
vf=$TMP/v1-aof.conf
printf 'appendonly yes\nsave 900 1\nstop-writes-on-bgsave-error yes\n' > "$vf"
valkey_apply_config "$vf" redis 512 allkeys-lru /run/redis/redis.sock adopt socket
check "V1: an operator AOF setup is still kept as it is" \
  bash -c 'grep -qx "appendonly yes" "$1" && grep -qx "save 900 1" "$1" && grep -qx "stop-writes-on-bgsave-error yes" "$1" && ! grep -qx "save 300 1" "$1"' _ "$vf"
out=$(valkey_persist_runtime_settings)
check "V1: the online snapshot settings never touch appendonly" lacks "$out" "appendonly"
check "V1: the online snapshot settings carry save 300 1" has "$out" "save 300 1"
live_log=$TMP/live.log
fake_live_cli() { printf '%s\n' "$*" >> "$live_log"; printf 'OK\n'; }
: > "$live_log"
check "V1: valkey_live_persist_on sends every snapshot setting" valkey_live_persist_on fake_live_cli -s /run/x.sock
check "V1: CONFIG SET save carries the schedule as one argument" line_in "$live_log" '-s /run/x.sock CONFIG SET save 300 1'
check "V1: the restart paths set the schedule on the live server first" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "valkey_live_persist_on \"\$cli\" --kind=\"\$kind\" \"\${live_ep\[@\]}\"" && sed -n "/^install_valkey()/,/^}/p" "$1" | grep -q "valkey_live_persist_on"' _ "$ALL_SRC_FILE"
fake_loading_cli() { printf 'LOADING Valkey is loading the dataset in memory\n'; }
check "V1: a server loading its snapshot counts as up for the restart probe" valkey_pong fake_loading_cli -s /run/x.sock
fake_err_cli() { printf 'ERR unknown\n'; }
check "V1: another error does not" not valkey_pong fake_err_cli

# COW headroom is reported, never acted on.
OPT_REPORT=()
OPT_MEM_TOTAL_MB=16000 OPT_VALKEY_COW_ROOM_MB=2000
valkey_cow_report 512
check "V1 COW: a cache that fits the room outside the plan says so" has "${OPT_REPORT[*]}" "copy-on-write 512 MB fits the 2000 MB"
OPT_REPORT=()
OPT_VALKEY_COW_ROOM_MB=100
valkey_cow_report 512
check "V1 COW: a cache larger than the room is reported, not cut" has "${OPT_REPORT[*]}" "maxmemory is not cut"
check "V1 COW: the plan books the room without touching the cache size" \
  bash -c 'grep -q "OPT_VALKEY_COW_ROOM_MB=\$(( total - booked - total / 10 ))" "$1"' _ "$ROOT/lib/optimize.sh"
OPT_REPORT=()

# ---------------------------------------------------------------------------
# A14 + V1(2): persists() and the series pin
# ---------------------------------------------------------------------------
vk_tool() { # conf-text [build.info valkey] -> "persists:series"
  (
    T=$TMP/vkt; rm -rf "$T"; mkdir -p "$T/root" "$T/etc"
    export VALKEY_BUILD_ROOT="$T/root" VALKEY_BUILD_UNIT_DIR="$T/units" VALKEY_BUILD_SOURCE_ONLY=1 \
           VALKEY_BUILD_VALKEY_CONF="$T/etc/valkey.conf" VALKEY_BUILD_CACHE="$T/cache" \
           VALKEY_BUILD_DATA_DIR="$T/data" VALKEY_BUILD_SERVER_LOG_DIR="$T/log" \
           VALKEY_BUILD_LINK_DIR="$T/links" VALKEY_BUILD_LEGACY_APT_HOOK="$T/none"
    # shellcheck disable=SC1090,SC1091
    source "$ROOT/tools/valkey-build.sh"
    set +eE; trap - ERR
    pkg_version() { :; }
    printf 'valkey=%s\n' "${2:-9.0.6}" > "$T/root/build.info"
    printf '%b' "$1" > "$T/etc/valkey.conf"
    printf '%s:%s' "$(persists && echo 1 || echo 0)" "$(series)"
  ) 2>/dev/null
}
check "A14: a conf with no save line persists (Valkey's default RDB schedule)" test "$(vk_tool 'port 6379\n')" = "1:"
check "A14: an explicit save \"\" with appendonly no does not persist" test "$(vk_tool 'save ""\nappendonly no\n')" = "0:"
check "V1: RDB-only (save 300 1) persists but does not pin the series" test "$(vk_tool 'save 300 1\nappendonly no\n')" = "1:"
check "V1: AOF still pins the series of the server that wrote it" test "$(vk_tool 'save 300 1\nappendonly yes\n')" = "1:9.0"
check "V1: with persistence the build never goes below the data writer (downgrade refused)" \
  bash -c 'b=$(sed -n "/^cmd_build()/,/^}/p" "$1"); grep -q "persists && w=\$(data_writer)" <<<"$b" && grep -q "is older than" <<<"$b"' _ "$ROOT/tools/valkey-build.sh"
check "V1: the BOLT private server and verify_binary keep --save ''" \
  bash -c 'grep -q -- "--save \"\" --appendonly no" "$1" && [[ $(grep -c -- "--save \"\"" "$1") -ge 2 ]]' _ "$ROOT/tools/valkey-build.sh"

# ---------------------------------------------------------------------------
# A1: BOLT profiles a private server, never the live instance
# ---------------------------------------------------------------------------
bolt_args() (
  export VALKEY_BUILD_SOURCE_ONLY=1 VALKEY_BUILD_ROOT=$TMP/vb VALKEY_BUILD_UNIT_DIR=$TMP/vb/u
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/tools/valkey-build.sh" >/dev/null 2>&1
  bolt_private_args /w | paste -sd' ' -
)
out=$(bolt_args)
check "A1: the private server has no TCP port, its own socket and no persistence" \
  test "$out" = "--port 0 --unixsocket /w/bolt.sock --unixsocketperm 700 --save  --appendonly no --dir /w --maxmemory 512mb --maxmemory-policy allkeys-lru --daemonize no --logfile /w/server.log"
bolt_body=$(sed -n '/^cmd_bolt()/,/^}/p' "$ROOT/tools/valkey-build.sh")
check "A1: cmd_bolt never flushes or targets the live server" \
  bash -c '! grep -qE "flushdb|live_target|MainPID" <<<"$1"' _ "$bolt_body"
check "A1: perf samples the private server's pid and the benchmark uses its socket" \
  bash -c 'grep -q -- "-p \"\$BOLT_PID\"" <<<"$1" && grep -q "\"\$bench\" -s \"\$sock\"" <<<"$1"' _ "$bolt_body"
check "A1: the EXIT trap kills the private server" \
  bash -c 'grep -q "trap bolt_cleanup EXIT" <<<"$1" && sed -n "/^bolt_cleanup()/,/^}/p" "$2" | grep -q "kill \"\$BOLT_PID\""' _ "$bolt_body" "$ROOT/tools/valkey-build.sh"
check "A1: the private server runs the LTO binary (the build ID perf2bolt maps)" \
  grep -q '"$base" "${args\[@\]}"' <<<"$bolt_body"

# ---------------------------------------------------------------------------
# C23: socket only (port 0) and the keep-TCP conditions
# ---------------------------------------------------------------------------
vf=$TMP/c23.conf
printf 'port 6380\n' > "$vf"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "C23: socket mode writes port 0" bash -c '[[ $(grep -c "^port " "$1") == 1 ]] && grep -qx "port 0" "$1"' _ "$vf"
check "C23: socket mode remembers the TCP port" line_in "$vf" '# setup.sh socket-only: tcp port 6380'
check "C23: the remembered port is read back" test "$(valkey_conf_tcp_port "$vf")" = 6380
check "C23: valkey_conf_socket_only" valkey_conf_socket_only "$vf"
cp "$vf" "$vf.1"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "C23: socket mode is idempotent" cmp -s "$vf" "$vf.1"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt tcp
check "C23: tcp mode restores the remembered port" \
  bash -c 'grep -qx "port 6380" "$1" && ! grep -q "socket-only" "$1"' _ "$vf"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt tcp-on
check "C23: tcp=on is persisted in the file" line_in "$vf" '# setup.sh valkey tcp=on'
vf=$TMP/c23-bind.conf
printf 'bind 10.0.0.5 127.0.0.1\nport 6379\n' > "$vf"
valkey_apply_config "$vf" redis 512 allkeys-lru /run/redis/redis.sock adopt socket
check "C23(3): a kept operator bind always keeps TCP, even when socket mode was asked" \
  bash -c 'grep -qx "port 6379" "$1" && grep -qx "bind 10.0.0.5 127.0.0.1" "$1"' _ "$vf"
vf=$TMP/c23-legacy.conf
printf 'port 6379\n' > "$vf"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock
check "C23: a caller that passes no TCP mode leaves the port line alone" line_in "$vf" 'port 6379'

# The decision.  App configs come from stubs; the live client list from a
# fake CLI on a real (perl-made) Unix socket.
WWW=$TMP/www; mkdir -p "$WWW"
APP_WP=() APP_XF=() APP_CHEV=()
app_find_wordpress_configs() { local c; for c in "${APP_WP[@]}"; do printf '%s\n' "$c"; done; }
app_find_xenforo_configs() { local c; for c in "${APP_XF[@]}"; do printf '%s\n' "$c"; done; }
nginx_chevereto_roots() { local c; for c in "${APP_CHEV[@]}"; do printf '%s\n' "$c"; done; }
mk_wp() { # name define-lines [dropin-text]
  mkdir -p "$WWW/$1/wp-content"
  printf '<?php\n%b\n' "$2" > "$WWW/$1/wp-config.php"
  [[ -n ${3:-} ]] && printf '<?php\n// %s\n' "$3" > "$WWW/$1/wp-content/object-cache.php"
  printf '%s' "$WWW/$1/wp-config.php"
}
mk_xf() { # name config-lines
  mkdir -p "$WWW/$1/src"; : > "$WWW/$1/src/XF.php"
  printf '<?php\n%b\n' "$2" > "$WWW/$1/src/config.php"
  printf '%s' "$WWW/$1/src/config.php"
}
mk_chev() { # name env-body
  mkdir -p "$WWW/$1/app"
  printf "<?php\nreturn [\n%b\n];\n" "$2" > "$WWW/$1/app/env.php"
  printf '%s' "$WWW/$1"
}
SOCK=$TMP/live.sock
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type=>SOCK_STREAM(),Local=>$ARGV[0],Listen=>1) or exit 1' "$SOCK" 2>/dev/null || true
FAKE_CLIENTS=""
fake_cli() { [[ "$*" == "-s $SOCK CLIENT LIST" ]] && printf '%s' "$FAKE_CLIENTS"; return 0; }
dconf=$TMP/decide.conf
decide() { # [tcp-option] -> mode
  VALKEY_TCP_MODE="" VALKEY_TCP_NOTES=()
  valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" "${1:-}"
  printf '%s' "$VALKEY_TCP_MODE"
}
printf 'port 6379\nunixsocket %s\n' "$SOCK" > "$dconf"
check "C23: default with no app and no TCP client is socket only" test "$(decide)" = socket
decide >/dev/null; valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" ""
check "C23: the default says how to keep TCP" has "${VALKEY_TCP_NOTES[*]}" "--valkey tcp=on"
check "C23(4): --valkey tcp=on keeps TCP" test "$(decide on)" = tcp-on
printf '# setup.sh valkey tcp=on\nport 6379\n' > "$dconf"
check "C23(4): a persisted tcp=on keeps TCP" test "$(decide)" = tcp-on
check "C23(4): tcp=auto undoes the persisted tcp=on" test "$(decide auto)" = socket
printf 'bind 192.0.2.10\nport 6379\n' > "$dconf"
check "C23(3): an operator bind keeps TCP" test "$(decide)" = tcp
printf 'port 6379\n' > "$dconf"
APP_WP=("$(mk_wp tcp1 "define('WP_REDIS_HOST', '127.0.0.1');\ndefine('WP_REDIS_PORT', 6379);" 'Redis Object Cache Drop-In')")
check "C23(1): a WordPress config on 127.0.0.1:6379 keeps TCP" test "$(decide)" = tcp
valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" ""
check "C23(1): the report names the config and how to switch" \
  bash -c '[[ $1 == *"tcp1/wp-config.php"* && $1 == *"WP_REDIS_SCHEME"* ]]' _ "${VALKEY_TCP_NOTES[*]}"
APP_WP=("$(mk_wp dflt "define('DB_HOST', 'localhost');" 'Redis Object Cache Drop-In')")
check "C23(1): a Redis drop-in with no endpoint uses the plugin default 127.0.0.1:6379" test "$(decide)" = tcp
APP_WP=("$(mk_wp sock "define('WP_REDIS_SCHEME', 'unix');\ndefine('WP_REDIS_PATH', '/run/valkey/valkey.sock');" 'Redis Object Cache Drop-In')")
check "C23(1): WP_REDIS_SCHEME unix + WP_REDIS_PATH is the socket" test "$(decide)" = socket
APP_WP=("$(mk_wp noscheme "define('WP_REDIS_PATH', '/run/valkey/valkey.sock');" 'Redis Object Cache Drop-In')")
check "C23(1): WP_REDIS_PATH without the unix scheme (Redis Object Cache) is still TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp remote "define('WP_REDIS_HOST', '192.0.2.20');" 'Redis Object Cache Drop-In')")
check "C23(1): a remote Redis host is not this cache's TCP user" test "$(decide)" = socket
APP_WP=("$(mk_wp other "define('WP_REDIS_HOST', 'localhost');\ndefine('WP_REDIS_PORT', 6390);" 'Redis Object Cache Drop-In')")
check "C23(1): loopback on another port is another server" test "$(decide)" = socket
APP_WP=("$(mk_wp ocp "define('WP_REDIS_CONFIG', [\n  'host' => '127.0.0.1',\n  'port' => 6379,\n]);" 'Object Cache Pro redis')")
check "C23(1): Object Cache Pro WP_REDIS_CONFIG on 127.0.0.1 is TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp nocache "define('DB_HOST', 'localhost');")")
check "C23(1): a WordPress without a Redis cache does not count" test "$(decide)" = socket
APP_WP=()
APP_XF=("$(mk_xf xftcp "\$config['cache']['enabled'] = true;\n\$config['cache']['provider'] = 'Redis';\n\$config['cache']['config'] = ['host' => '127.0.0.1', 'port' => 6379];")")
check "C23(1): a XenForo cache on 127.0.0.1:6379 keeps TCP" test "$(decide)" = tcp
APP_XF=("$(mk_xf xfsock "\$config['cache']['enabled'] = true;\n\$config['cache']['provider'] = 'Redis';\n\$config['cache']['config'] = ['host' => '/run/valkey/valkey.sock', 'port' => 0];")")
check "C23(1): a XenForo cache on the socket is fine" test "$(decide)" = socket
APP_XF=("$(mk_xf xfoff "\$config['cache']['enabled'] = false;\n\$config['cache']['provider'] = 'Redis';\n\$config['cache']['config'] = ['host' => '127.0.0.1', 'port' => 6379];")")
check "C23(1): a disabled XenForo cache does not count" test "$(decide)" = socket
APP_XF=()
APP_CHEV=("$(mk_chev chtcp "  'CHEVERETO_CACHE_DRIVER' => 'redis', 'CHEVERETO_CACHE_HOST' => '127.0.0.1', 'CHEVERETO_CACHE_PORT' => '6379',")")
check "C23(1): a Chevereto cache on 127.0.0.1 keeps TCP" test "$(decide)" = tcp
APP_CHEV=("$(mk_chev chsess "  'CHEVERETO_SESSION_SAVE_HANDLER' => 'redis', 'CHEVERETO_SESSION_SAVE_PATH' => 'tcp://127.0.0.1:6379',")")
check "C23(1): Chevereto sessions over tcp://127.0.0.1:6379 keep TCP" test "$(decide)" = tcp
APP_CHEV=("$(mk_chev chsock "  'CHEVERETO_CACHE_DRIVER' => 'redis', 'CHEVERETO_CACHE_HOST' => '/run/valkey/valkey.sock', 'CHEVERETO_CACHE_PORT' => '0',\n  'CHEVERETO_SESSION_SAVE_HANDLER' => 'redis', 'CHEVERETO_SESSION_SAVE_PATH' => 'unix:///run/valkey/valkey.sock',")")
check "C23(1): Chevereto on the socket is fine" test "$(decide)" = socket
APP_CHEV=()
if [[ -S $SOCK ]]; then
  FAKE_CLIENTS=$'id=3 addr=/run/valkey/valkey.sock:0 laddr=/run/valkey/valkey.sock:0 fd=8 name= cmd=get\nid=4 addr=127.0.0.1:52344 laddr=127.0.0.1:6379 fd=9 name=cron cmd=set\n'
  check "C23(2): a connected TCP client keeps TCP" test "$(decide)" = tcp
  valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" ""
  check "C23(2): the report names the client" has "${VALKEY_TCP_NOTES[*]}" "addr=127.0.0.1:52344 name=cron"
  FAKE_CLIENTS=$'id=3 addr=/run/valkey/valkey.sock:0 fd=8 name= cmd=client|list\n'
  check "C23(2): socket clients only (our own CLI included) allow port 0" test "$(decide)" = socket
  # Valkey 9.2 as seen on a real host: bracketed unix address, flags=U.
  FAKE_CLIENTS=$'id=6456 addr=[/run/valkey/valkey.sock:0]:0 laddr=[/run/valkey/valkey.sock:0]:0 fd=12 name= age=0 idle=0 flags=U db=0 cmd=mget\nid=6457 addr=[/run/valkey/valkey.sock:0]:0 fd=13 name= flags=N cmd=get\n'
  check "C23(2): Valkey 9 bracketed socket clients are not TCP" test "$(decide)" = socket
  FAKE_CLIENTS=$'id=7 addr=[::1]:52344 laddr=[::1]:6379 fd=9 name= flags=N cmd=set\n'
  check "C23(2): an IPv6 loopback TCP client keeps TCP" test "$(decide)" = tcp
  FAKE_CLIENTS='NOAUTH Authentication required.'
  check "C23(2): a server that requires AUTH keeps TCP (clients cannot be checked)" test "$(decide)" = tcp
  FAKE_CLIENTS=""
else
  printf 'SKIP  C23(2) client-list cases (no AF_UNIX helper)\n'
fi
tcp_cli() { [[ "$*" == "-h 127.0.0.1 -p 6379 CLIENT LIST" ]] && printf '%s' "$TCP_CLIENTS"; return 0; }
TCP_CLIENTS=$'id=5 addr=127.0.0.1:40000 fd=9 name= cmd=get\nid=6 addr=127.0.0.1:40002 fd=10 name= cmd=client|list\n'
check "C23(2): a server without a live socket is asked over loopback TCP (all its clients are TCP)" \
  test "$(valkey_live_tcp_clients tcp_cli $TMP/no.sock 6379)" = "addr=127.0.0.1:40000 name= cmd=get"
TCP_CLIENTS=$'id=6 addr=127.0.0.1:40002 fd=10 name= cmd=client|list\n'
check "C23(2): ... and our own CLIENT LIST connection does not count" test -z "$(valkey_live_tcp_clients tcp_cli $TMP/no.sock 6379)"
check "C23: install_valkey and optimize_valkey_tune pass the decision to the writer" \
  bash -c 'sed -n "/^install_valkey()/,/^}/p" "$1" | grep -q "adopt \"\$tcp_mode\"" && sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "adopt \"\$VALKEY_TCP_MODE\""' _ "$ALL_SRC_FILE"
check "C23: the online path applies the port with CONFIG SET (no restart on Valkey 7.2+)" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "valkey_online_port \"\$cli\" \"\$conf\""' _ "$ALL_SRC_FILE"
port_log=$TMP/port.log
port_cli() { printf '%s\n' "$*" >> "$port_log"; case "$*" in *"CONFIG GET port") printf 'port\n6379\n' ;; *"CONFIG SET port 0") printf 'OK\n' ;; esac; }
printf 'port 0\n' > "$TMP/port.conf"; : > "$port_log"; OPT_REPORT=()
check "C23: valkey_online_port closes TCP online" valkey_online_port port_cli "$TMP/port.conf" -s /run/x.sock
check "C23: ... with CONFIG SET port 0 on the socket" line_in "$port_log" '-s /run/x.sock CONFIG SET port 0'
port_cli() { case "$*" in *"CONFIG GET port") printf 'port\n6379\n' ;; *) printf 'ERR Unsupported CONFIG parameter: port\n' ;; esac; }
check "C23: a server that refuses CONFIG SET port (Redis 6) needs the restart" not valkey_online_port port_cli "$TMP/port.conf"
OPT_REPORT=()

# Loopback endpoint parsing.
check "endpoint: 127.0.0.1 is loopback" valkey_loopback_endpoint 127.0.0.1 "" 6379
check "endpoint: tcp://localhost:6379 is loopback" valkey_loopback_endpoint tcp://localhost:6379 "" 6379
check "endpoint: [::1]:6379 is loopback" valkey_loopback_endpoint '[::1]:6379' "" 6379
check "endpoint: redis://user:pw@127.0.0.1:6379/0 is loopback" valkey_loopback_endpoint 'redis://user:pw@127.0.0.1:6379/0' "" 6379
check "endpoint: the configured port counts" valkey_loopback_endpoint 127.0.0.1 6380 6380
check "endpoint: another host is not" not valkey_loopback_endpoint 192.0.2.5 "" 6379
check "endpoint: unix:// is a socket" valkey_socket_endpoint unix:///run/valkey/valkey.sock

# ---------------------------------------------------------------------------
# B19: shared-cache audit (report only)
# ---------------------------------------------------------------------------
report_of() { OPT_REPORT=(); VALKEY_APP_SCAN=$(valkey_app_cache_scan 6379); valkey_app_cache_report /run/valkey/valkey.sock; printf '%s\n' "${OPT_REPORT[@]}"; }
APP_WP=("$(mk_wp b1 "define('WP_REDIS_SCHEME', 'unix');\ndefine('WP_REDIS_PATH', '/run/valkey/valkey.sock');" 'Redis Object Cache Drop-In')"
        "$(mk_wp b2 "define('WP_REDIS_SCHEME', 'unix');\ndefine('WP_REDIS_PATH', '/run/valkey/valkey.sock');\ndefine('WP_REDIS_PREFIX', 'b2:');" 'Redis Object Cache Drop-In')")
APP_XF=("$(mk_xf bx "\$config['cache']['enabled'] = true;\n\$config['cache']['provider'] = 'Redis';\n\$config['cache']['config'] = ['host' => '/run/valkey/valkey.sock', 'port' => 0];\n\$config['cache']['sessions'] = true;")")
out=$(report_of)
check "B19(a): a shared cache and a WordPress without a prefix is reported" has "$out" "b1/wp-config.php\`: 3 sites share this cache"
check "B19(a): a WordPress with WP_REDIS_PREFIX is not" lacks "$out" "b2/wp-config.php\`: 3 sites"
check "B19(a): a XenForo without a namespace is reported" has "$out" "has no \`\$config['cache']['namespace']\`"
check "B19(b): XenForo sessions in the cache are reported" has "$out" "['sessions'] = true"
check "B19(b): ... with the RDB snapshot and ram= guidance" \
  bash -c '[[ $1 == *"5-minute RDB snapshot"* && $1 == *"--valkey ram="* ]]' _ "$out"
APP_WP=("${APP_WP[0]}") APP_XF=()
out=$(report_of)
check "B19(a): a single site needs no prefix" lacks "$out" "share this cache"
APP_WP=()
OPT_REPORT=()
chevereto_session_dirs() { :; }
chevereto_session_hint /run/valkey/valkey.sock
check "B19(c): the Chevereto hint carries the RDB + allkeys-lru guidance" \
  bash -c '[[ $1 == *"5-minute RDB snapshot"* && $1 == *"allkeys-lru may evict"* && $1 != *noeviction* && $1 != *"volatile-lru"* ]]' _ "${OPT_REPORT[*]}"
OPT_REPORT=()

# ---------------------------------------------------------------------------
# A9: a custom socket is recognised
# ---------------------------------------------------------------------------
cconf=$TMP/custom.conf
printf 'unixsocket /run/valkey/cache.sock\n' > "$cconf"
check "A9: the socket hint is the configured unixsocket" \
  test "$(APP_CACHE_CONFS=$cconf app_cache_socket_hint)" = /run/valkey/cache.sock
a9_custom() ( APP_CACHE_CONFS=$cconf; app_is_socket_path /run/valkey/cache.sock )
check "A9: the configured socket counts as the local socket" a9_custom
if [[ -S $SOCK ]]; then
  check "A9: any existing socket path counts" app_is_socket_path "$SOCK"
fi
check "A9: a TCP host is still not a socket" not app_is_socket_path 127.0.0.1
check "A9: a missing non-default path is not a socket" not app_is_socket_path /nonexistent/cache.sock

# ---------------------------------------------------------------------------
# V2: noeviction is gone
# ---------------------------------------------------------------------------
kv_probe() ( OPT=(); kv_set valkey "$1" "$2"; printf '%s' "${OPT[valkey.$1]}" )
out=$(kv_probe policy noeviction 2>&1) && rc=0 || rc=$?
check "V2: --valkey policy=noeviction is rejected" test "$rc" -ne 0
check "V2: ... with a message that names the replacement guidance" \
  bash -c '[[ $1 == *"removed in 1.22.5"* && $1 == *"--valkey ram="* && $1 == *"volatile-*"* ]]' _ "$out"
check "V2: other policies keep working" test "$(kv_probe policy allkeys-lfu 2>/dev/null)" = allkeys-lfu
check "V2: volatile-lru is still accepted (not recommended)" test "$(kv_probe policy volatile-lru 2>/dev/null)" = volatile-lru
check "tcp=: on and auto are accepted (lower-cased)" \
  test "$(kv_probe tcp ON 2>/dev/null),$(kv_probe tcp auto 2>/dev/null)" = "on,auto"
out=$(kv_probe tcp off 2>&1) && rc=0 || rc=$?
check "tcp=: anything else is refused (tcp=off was dropped)" test "$rc" -ne 0
check "V2: --optimize migrates a persisted noeviction to allkeys-lru with a report line" \
  bash -c 'b=$(sed -n "/^optimize_valkey_tune()/,/^}/p" "$1"); grep -q "\$policy == noeviction" <<<"$b" && grep -q "migrated to allkeys-lru" <<<"$b"' _ "$ALL_SRC_FILE"
check "V2: --valkey on a host with noeviction moves it to allkeys-lru" \
  bash -c 'sed -n "/^install_valkey()/,/^}/p" "$1" | grep -q "\$policy == noeviction"' _ "$ALL_SRC_FILE"
check "V2: no user-facing text recommends noeviction or volatile-lru for sessions" \
  bash -c '! grep -nE "use .?noeviction|noeviction.?/.?volatile-lru|or volatile-lru when" "$1/README.md" "$1/SECURITY-PERFORMANCE.md" "$1/lib/cli.sh" "$1/lib/service-optimizers.sh"' _ "$ROOT"

# ---------------------------------------------------------------------------
# V3: the io_threads opt-in is gone (1.22.5); io-threads is pinned to 1
# ---------------------------------------------------------------------------
v3_kv() ( OPT=(); RETIRED_VALKEY_IO_THREADS=""; kv_set valkey io_threads "$1"; printf '%s|%s' "${OPT[valkey.io_threads]:-}" "$RETIRED_VALKEY_IO_THREADS" )
out=$(v3_kv 4 2>&1) && rc=0 || rc=$?
check "V3: --valkey io_threads=4 is not fatal" test "$rc" -eq 0
check "V3: ... is not stored and is recorded for the warning" test "$out" = "|--valkey io_threads=4"
out=$(v3_kv 0 2>&1) && rc=0 || rc=$?
check "V3: an out-of-range io_threads=0 is ignored too, never refused" test "$rc,$out" = "0,|--valkey io_threads=0"
check "V3: validate_all warns 'Ignored (removed in 1.22.5; ...)' for it" \
  bash -c 'sed -n "/^validate_all()/,/^}/p" "$1" | grep -q "Ignored (removed in 1.22.5; io-threads above 1 measured no gain.*RETIRED_VALKEY_IO_THREADS"' _ "$ALL_SRC_FILE"
check "V3: the writer always writes io-threads 1" has "$(valkey_tuning_lines 512 allkeys-lru)" $'\nio-threads 1\n'
vf=$TMP/v3.conf
printf '# setup.sh managed valkey\nport 0\nio-threads 4\nio-threads-do-reads yes\n' > "$vf"
check "V3: a managed file from an earlier --valkey io_threads=4 still reads 4" test "$(valkey_conf_get "$vf" io-threads)" = 4
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "V3: the writer migrates io-threads 4 back to 1 (one line)" \
  bash -c 'grep -qx "io-threads 1" "$1" && [[ $(grep -c "^io-threads " "$1") == 1 ]]' _ "$vf"
cp "$vf" "$vf.1"; valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "V3: the migrated file is stable on the next run" cmp -s "$vf" "$vf.1"
check "V3: --optimize reports the reset once (only while the file differs from 1)" \
  bash -c 'b=$(sed -n "/^optimize_valkey_tune()/,/^}/p" "$1"); grep -q "file_io != 1" <<<"$b" && grep -q "reset to 1: the .*io_threads=.* option was removed in 1.22.5" <<<"$b"' _ "$ALL_SRC_FILE"
check "V3: --valkey on a host with io-threads above 1 says so" \
  bash -c 'sed -n "/^install_valkey()/,/^}/p" "$1" | grep -q "reset to 1 (the io_threads option was removed in 1.22.5"' _ "$ALL_SRC_FILE"
check "V3: no io_threads option, clamp or OPT key is left in the program" \
  bash -c '! grep -nE "valkey_clamp_io_threads|OPT\[valkey\.io_threads\]|io_threads extra socket" "$1"' _ "$ALL_SRC_FILE"

# ---------------------------------------------------------------------------
# Port 0 everywhere that talks to Valkey
# ---------------------------------------------------------------------------
mig_case() ( # conf-text -> the target valkey-cli gets
  MIGRATE_VALKEY_ETC=$TMP/mig; mkdir -p "$MIGRATE_VALKEY_ETC"
  printf '%b' "$1" > "$MIGRATE_VALKEY_ETC/valkey.conf"
  vcli=$TMP/vcli; printf '#!/bin/sh\necho "$@"\n' > "$vcli"; chmod +x "$vcli"
  timeout() { shift; "$@"; }
  migrate_valkey_cmd "$vcli" PING
)
check "migrate: a socket-only conf is asked on the default socket" \
  test "$(mig_case 'port 0\n')" = "-s /run/valkey/valkey.sock PING"
check "migrate: a TCP conf keeps the TCP target" \
  test "$(mig_case 'port 6380\n')" = "-h 127.0.0.1 -p 6380 PING"
lt_case() (
  export VALKEY_BUILD_SOURCE_ONLY=1 VALKEY_BUILD_ROOT=$TMP/vl VALKEY_BUILD_UNIT_DIR=$TMP/vl/u VALKEY_BUILD_VALKEY_CONF=$TMP/vl.conf
  printf '%b' "$1" > "$TMP/vl.conf"
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/tools/valkey-build.sh" >/dev/null 2>&1
  live_target | paste -sd' ' -
)
check "valkey-build live_target: port 0 without a socket line asks the default socket" \
  test "$(lt_case 'port 0\n')" = "-s /run/valkey/valkey.sock"
check "valkey-build live_target: a configured socket wins" \
  test "$(lt_case 'port 0\nunixsocket /run/valkey/c.sock\n')" = "-s /run/valkey/c.sock"
check "stress-site and appsim talk to Valkey over the socket" \
  bash -c '! grep -nE "pconnect\(.127\.0\.0\.1., 6379|valkey-cli INFO|cli\" INFO" "$1"/tests/stress-site/php-appsim/lib.php "$1"/tests/stress-site/run-stress.sh "$1"/tests/stress-site/collect-metrics.sh' _ "$ROOT"

# ---------------------------------------------------------------------------
# F2/F17: an adopted store that keeps its AOF persistence keeps noeviction
# ---------------------------------------------------------------------------
pf=$TMP/f2.conf
printf 'appendonly yes\nmaxmemory-policy noeviction\n' > "$pf"
check "F2: an unmanaged appendonly yes store keeps its persistence" valkey_conf_keeps_persist "$pf"
check "F2: ... and its noeviction" test "$(valkey_policy_migrate "$pf" noeviction)" = noeviction
valkey_apply_config "$pf" redis 512 "$(valkey_policy_migrate "$pf" noeviction)" /run/redis/redis.sock adopt socket
check "F2: the writer keeps appendonly yes and noeviction together" \
  bash -c 'grep -qx "appendonly yes" "$1" && grep -qx "maxmemory-policy noeviction" "$1" && grep -qx "# setup.sh kept operator persistence" "$1"' _ "$pf"
check "F2: the next run (managed file with the marker) still keeps noeviction" test "$(valkey_policy_migrate "$pf" noeviction)" = noeviction
printf 'appendonly no\nmaxmemory-policy noeviction\n' > "$pf"
check "F2: a plain cache still migrates noeviction to allkeys-lru" test "$(valkey_policy_migrate "$pf" noeviction)" = allkeys-lru
printf '# setup.sh managed valkey\nappendonly yes\n' > "$pf"
check "F2: a managed file without the marker is not an operator store" not valkey_conf_keeps_persist "$pf"
check "F2: other policies pass through unchanged" test "$(valkey_policy_migrate "$pf" allkeys-lfu)" = allkeys-lfu
check "F2: --optimize and --valkey share the predicate and report the kept policy" \
  bash -c 'o=$(sed -n "/^optimize_valkey_tune()/,/^}/p" "$1"); i=$(sed -n "/^install_valkey()/,/^}/p" "$1"); grep -q "valkey_policy_migrate" <<<"$o" && grep -q "noeviction kept" <<<"$o" && grep -q "valkey_policy_migrate" <<<"$i" && grep -q "valkey_conf_keeps_persist" <<<"$i" && sed -n "/^valkey_apply_config()/,/^}/p" "$1" | grep -q "valkey_conf_keeps_persist"' _ "$ALL_SRC_FILE"

# ---------------------------------------------------------------------------
# F5: finite stop timeout and a shutdown save that never blocks the exit
# ---------------------------------------------------------------------------
check "F5: Valkey gets shutdown-on-sigterm default force" has "$(valkey_persist_lines valkey)" "shutdown-on-sigterm default force"
f5_redis() ( redis-server() { printf 'Redis server v=%s sha=0\n' "$f5_rv"; }; VALKEY_REDIS_VERSION_CACHE=""; valkey_persist_lines redis )
f5_rv=6.0.16; check "F5: Redis 6.0 does not get it (unknown directive)" lacks "$(f5_redis "$f5_rv")" "shutdown-on-sigterm"
f5_rv=7.0.15; check "F5: Redis 7 gets it" has "$(f5_redis "$f5_rv")" "shutdown-on-sigterm default force"
out=$( ( redis-server() { return 127; }; VALKEY_REDIS_VERSION_CACHE=""; valkey_persist_lines redis ) )
check "F5: an unreadable Redis version does not get it" lacks "$out" "shutdown-on-sigterm"
out=$(redis_case 6.0.16 redis)
check "F5: the Redis 6.0 writer output has no shutdown-on-sigterm" lacks "$out" "shutdown-on-sigterm"
out=$(redis_case 7.2.4 redis)
check "F5: the Redis 7.2 writer writes it once" test "$(grep -c '^shutdown-on-sigterm ' <<<"$out")" = 1
: > "$live_log"
valkey_live_persist_on fake_live_cli --kind=valkey -s /run/x.sock
check "F5: the live server gets it with the snapshot settings" line_in "$live_log" '-s /run/x.sock CONFIG SET shutdown-on-sigterm default force'
vf=$TMP/f5.conf
printf 'port 6379\n' > "$vf"
valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
cp "$vf" "$vf.1"; valkey_apply_config "$vf" valkey 512 allkeys-lru /run/valkey/valkey.sock adopt socket
check "F5: the managed line is idempotent" bash -c 'cmp -s "$1" "$2" && [[ $(grep -c "^shutdown-on-sigterm" "$1") == 1 ]]' _ "$vf" "$vf.1"
ut=$( export VALKEY_BUILD_SOURCE_ONLY=1 VALKEY_BUILD_ROOT=$TMP/vu VALKEY_BUILD_UNIT_DIR=$TMP/vu/u VALKEY_BUILD_TOOL_PATH=/T/valkey-build.sh
      # shellcheck disable=SC1090,SC1091
      source "$ROOT/tools/valkey-build.sh" >/dev/null 2>&1; unit_text )
check "F5: the unit stops within 300 s (no TimeoutStopSec=0)" \
  bash -c 'grep -qx "TimeoutStopSec=300" <<<"$1" && ! grep -q "TimeoutStopSec=0" <<<"$1"' _ "$ut"
check "F4: the unit records a clean stop (ExecStopPost=+TOOL post)" grep -qx 'ExecStopPost=+/T/valkey-build.sh post' <<<"$ut"

# ---------------------------------------------------------------------------
# F4: the snapshot loads only after a clean stop (tools/valkey-build.sh)
# ---------------------------------------------------------------------------
G=$TMP/guard; mkdir -p "$G/data" "$G/units" "$G/root"
printf '# setup-valkey-unit 1.22\n' > "$G/units/valkey-server.service"
printf 'dir %s\ndbfilename dump.rdb\nappendonly no\n' "$G/data" > "$G/valkey.conf"
gtool() ( # pre|post [SERVICE_RESULT EXIT_CODE]
  export VALKEY_BUILD_SOURCE_ONLY=1 VALKEY_BUILD_ROOT=$G/root VALKEY_BUILD_UNIT_DIR=$G/units \
         VALKEY_BUILD_VALKEY_CONF=$G/valkey.conf VALKEY_BUILD_DATA_DIR=$G/data
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/tools/valkey-build.sh" >/dev/null 2>&1
  set +eE; trap - ERR
  if [[ $1 == pre ]]; then rdb_guard_pre 2>/dev/null; else SERVICE_RESULT=$2 EXIT_CODE=$3 cmd_post 2>/dev/null; fi
)
unclean_n() { find "$1" -maxdepth 1 -name "${2:-dump.rdb}.unclean-*" | wc -l | tr -d ' '; }
printf 'data' > "$G/data/dump.rdb"
gtool pre
check "F4: the first start under the guard keeps the snapshot (migration, upgrade)" test -f "$G/data/dump.rdb"
check "F4: ... and arms the guard" test -e "$G/data/.setup-started"
touch "$G/data/dump.rdb"
gtool post success exited
check "F4: a clean stop with a fresh shutdown save is recorded" test -e "$G/data/.setup-clean-stop"
gtool pre
check "F4: after a clean stop (normal reboot) the snapshot is loaded" bash -c '[[ -f $1/dump.rdb && ! -e $1/.setup-clean-stop ]]' _ "$G/data"
gtool post signal killed
gtool pre
check "F4: after kill -9 / a crash the snapshot is moved aside (start empty)" \
  bash -c '[[ ! -e $1/dump.rdb && $(find "$1" -name "dump.rdb.unclean-*" | wc -l) -eq 1 ]]' _ "$G/data"
printf 'data' > "$G/data/dump.rdb"
gtool pre
check "F4: a power loss (no post at all) also starts empty" test ! -e "$G/data/dump.rdb"
printf 'old' > "$G/data/dump.rdb"; touch -d '-10 minutes' "$G/data/dump.rdb"
gtool post success exited
check "F4: a clean exit whose shutdown save failed (stale snapshot) is not clean" test ! -e "$G/data/.setup-clean-stop"
for _ in 1 2 3; do printf 'x' > "$G/data/dump.rdb"; gtool pre; sleep 1; done
check "F4: at most the 2 newest unclean snapshots are kept" test "$(unclean_n "$G/data")" -le 2
printf 'appendonly yes\ndir %s\n' "$G/data" > "$G/valkey.conf"
printf 'aof' > "$G/data/dump.rdb"; rm -f "$G/data/.setup-clean-stop"
gtool pre
check "F4: an AOF store (operator persistence) is never touched" test -f "$G/data/dump.rdb"
check "F4: pre runs the guard only after the CPU gate passed" \
  bash -c 'sed -n "/^cmd_pre()/,/^}/p" "$1" | grep -q "if cpu_fingerprint_matches \"\$built\" .*; then rdb_guard_pre"' _ "$ROOT/tools/valkey-build.sh"

# F9 (fc): Valkey records cpu_info= and its gates compare it as a set, like
# nginx/PHP: a flag a newer kernel starts to name keeps the build valid.  cx16 (outside
# the 1.22.4 V1 list) keeps the V1 fallback from matching the no-text case.
VC=$TMP/vcpu; mkdir -p "$VC/root" "$VC/units"
cpuinfo_x86() { printf 'processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 143\nmodel name\t: Test CPU\nstepping\t: 8\nflags\t\t: fpu sse3 avx avx2 %s\n\n' "$1"; }
cpuinfo_x86 "cx16" > "$VC/a"; cpuinfo_x86 "cx16 avx_ifma" > "$VC/b"; cpuinfo_x86 "cx16" | sed 's/ avx2//' > "$VC/c"
vk_status() ( # cpuinfo-at-build cpuinfo-now [no-text]
  export VALKEY_BUILD_SOURCE_ONLY=1 VALKEY_BUILD_ROOT=$VC/root VALKEY_BUILD_UNIT_DIR=$VC/units
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/tools/valkey-build.sh" >/dev/null 2>&1
  set +eE; trap - ERR
  { printf 'cpu=%s\n' "$(SETUP_CPUINFO=$1 cpu_fingerprint)"
    [[ -n ${3:-} ]] || printf 'cpu_info=%s\n' "$(SETUP_CPUINFO=$1 cpu_fingerprint_text)"; } > "$VC/root/build.info"
  SETUP_CPUINFO=$2 cmd_status 2>/dev/null | grep -o 'cpu match=[a-z]*'
)
check "F9 valkey: the build records cpu_info=" grep -qF 'printf '"'"'cpu_info=%s\n'"'"' "$(cpu_fingerprint_text)"' "$ROOT/tools/valkey-build.sh"
check "F9 valkey: same CPU matches" test "$(vk_status "$VC/a" "$VC/a")" = "cpu match=yes"
check "F9 valkey: a flag a newer kernel names still matches (cpu_info)" test "$(vk_status "$VC/a" "$VC/b")" = "cpu match=yes"
check "F9 valkey: ... but not without the recorded text" test "$(vk_status "$VC/a" "$VC/b" notext)" = "cpu match=no"
check "F9 valkey: a flag that disappears is a mismatch" test "$(vk_status "$VC/a" "$VC/c")" = "cpu match=no"
check "F9 valkey: every gate passes cpu_info" \
  test "$(grep -c 'cpu_fingerprint_matches .*cpu_info' "$ROOT/tools/valkey-build.sh")" -eq 4

# The same guard as an adopted redis-server drop-in.
R=$TMP/rguard; mkdir -p "$R/data"
printf 'dir %s\ndbfilename dump.rdb\n' "$R/data" > "$R/redis.conf"
check "F4 redis: the drop-in is written" valkey_write_rdb_guard redis-server "$R/redis.conf" redis
rd=$VALKEY_SYSTEMD_DIR/redis-server.service.d/$VALKEY_RDB_GUARD_DROPIN
check "F4 redis: unchanged on the next run" not valkey_write_rdb_guard redis-server "$R/redis.conf" redis
check "F4/F5 redis: TimeoutStopSec=300 and both hooks (root, failure ignored)" \
  bash -c 'grep -qx "TimeoutStopSec=300" "$1" && grep -q "^ExecStartPre=-+/bin/sh -c " "$1" && grep -q "^ExecStopPost=-+/bin/sh -c " "$1"' _ "$rd"
check "F4 redis: systemd specifiers are escaped (\$\$, %%)" \
  bash -c 'grep -q "\$\$SERVICE_RESULT" "$1" && grep -q "%%Y" "$1" && ! grep -qE "[^$]\\\$[a-zA-Z({]" <(sed "s/\\\$\\\$//g" "$1")' _ "$rd"
rhook() { # Pre|Post -> the shell line systemd runs
  sed -nE "s/^Exec(Start${1}|Stop${1})=-\\+\\/bin\\/sh -c '(.*)'\$/\\2/p" "$rd" | sed -e 's/\$\$/$/g' -e 's/%%/%/g'
}
rpre() { sh -c "$(rhook Pre)" 2>/dev/null; }
rpost() { SERVICE_RESULT=$1 EXIT_CODE=$2 sh -c "$(rhook Post)"; }
printf 'data' > "$R/data/dump.rdb"
rpre
check "F4 redis: the first start keeps the snapshot" test -f "$R/data/dump.rdb"
touch "$R/data/dump.rdb"; rpost success exited; rpre
check "F4 redis: a clean stop keeps the snapshot" test -f "$R/data/dump.rdb"
rpost exit-code exited; rpre
check "F4 redis: an unclean stop moves it aside" bash -c '[[ ! -e $1/dump.rdb && -n $(find "$1" -name "dump.rdb.unclean-*") ]]' _ "$R/data"
printf 'old' > "$R/data/dump.rdb"; touch -d '-10 minutes' "$R/data/dump.rdb"; rpost success exited
check "F4 redis: a stale snapshot after a clean exit is not clean" test ! -e "$R/data/.setup-clean-stop"
for _ in 1 2 3; do printf 'x' > "$R/data/dump.rdb"; rpre; sleep 1; done
check "F4 redis: at most 2 unclean snapshots are kept" test "$(unclean_n "$R/data")" -le 2
check "F4 redis: --optimize writes the drop-in for an adopted redis-server and reports it" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "valkey_write_rdb_guard \"\$unit\" \"\$conf\" redis"' _ "$ALL_SRC_FILE"
check "F4: the report says a crash starts empty" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "Snapshot loaded only after a clean stop"' _ "$ALL_SRC_FILE"

# ---------------------------------------------------------------------------
# F15/F30: --purge valkey restores TCP and names a snapshot a package cannot read
# ---------------------------------------------------------------------------
P=$TMP/purge; mkdir -p "$P/data"
printf 'dir %s\ndbfilename dump.rdb\n# setup.sh socket-only: tcp port 6380\nport 0\n# setup.sh valkey tcp=on\n' "$P/data" > "$P/valkey.conf"
printf 'rdb' > "$P/data/dump.rdb"; : > "$P/data/.setup-started"
out=$(valkey_purge_cache_conf "$P/valkey.conf" valkey 9.0.6 2>&1)
check "F30: the remembered TCP port is restored" \
  bash -c 'grep -qx "port 6380" "$1" && ! grep -q "^port 0" "$1" && ! grep -q "socket-only" "$1"' _ "$P/valkey.conf"
check "F30: the tcp=on marker goes" no_line "$P/valkey.conf" '# setup.sh valkey tcp=on'
check "F15: the kept dump.rdb is named with the build version and how to move it" \
  bash -c '[[ $1 == *"Valkey 9.0.6"* && $1 == *"mv $2/dump.rdb $2/dump.rdb.9.0.6"* ]]' _ "$out" "$P/data"
check "F15: the data stays" test -f "$P/data/dump.rdb"
check "F4: the guard state goes with the purge" test ! -e "$P/data/.setup-started"
out=$(valkey_purge_cache_conf "$P/valkey.conf" valkey "" 2>&1)
check "F15: no warning without a source build" lacks "$out" "cannot load"
printf 'port 6379\n' > "$P/plain.conf"; cp "$P/plain.conf" "$P/plain.1"
valkey_purge_cache_conf "$P/plain.conf" redis >/dev/null 2>&1
check "F30: a conf that was never socket-only is left alone" cmp -s "$P/plain.conf" "$P/plain.1"
check "F4: --purge removes the redis-server guard drop-in" test ! -e "$rd"
check "F15/F30: purge_valkey reads build.info before the build goes and runs this after the stops" \
  bash -c 'b=$(sed -n "/^purge_valkey()/,/^}/p" "$1"); [[ $(grep -n "vk_built=\$(valkey_build_info_get valkey)" <<<"$b" | cut -d: -f1) -lt $(grep -n "^    valkey_build_purge" <<<"$b" | cut -d: -f1) ]] && [[ $(grep -n "Stopped adopted cache service" <<<"$b" | cut -d: -f1) -lt $(grep -n "valkey_purge_cache_conf /etc/valkey" <<<"$b" | cut -d: -f1) ]]' _ "$ROOT/lib/purge.sh"

# ---------------------------------------------------------------------------
# F23: the private BOLT server holds no build lock and dies with the tool
# ---------------------------------------------------------------------------
bolt_body=$(sed -n '/^cmd_bolt()/,/^}/p' "$ROOT/tools/valkey-build.sh")
check "F23: fd 9 is closed for the private server" \
  bash -c '[[ $(grep -c "\"\$base\" \"\${args\[@\]}\" 9>&-" <<<"$1") == 2 ]]' _ "$bolt_body"
check "F23: it dies with the tool (setpriv --pdeathsig KILL)" grep -q 'setpriv --pdeathsig KILL -- "$base"' <<<"$bolt_body"
f23_fd() ( exec 9>"$TMP/f23.lock"; sh -c 'ls /proc/$$/fd' 9>&- | grep -qx 9 && echo held || echo closed )
[[ -d /proc/self/fd ]] && check "F23: '9>&-' leaves the child without the lock fd" test "$(f23_fd)" = closed

# ---------------------------------------------------------------------------
# Socket-only safety (F3/F7/F11/F13/F18/F19/F22/F32)
# ---------------------------------------------------------------------------
printf 'port 6379\n' > "$dconf"
APP_WP=() APP_XF=() APP_CHEV=()
# (a) XenForo
APP_XF=("$(mk_xf xfarr "\$config['cache'] = [\n  'enabled' => true,\n  'provider' => 'Redis',\n  'config' => ['host' => '127.0.0.1', 'port' => 6379],\n];")")
check "XF array form with Redis on 127.0.0.1 keeps TCP" test "$(decide)" = tcp
APP_XF=("$(mk_xf xfctx "\$config['cache']['enabled'] = true;\n\$config['cache']['context']['sessions']['provider'] = 'Redis';")")
check "XF context provider only (no endpoint) keeps TCP" test "$(decide)" = tcp
APP_XF=("$(mk_xf xfctxs "\$config['cache']['context']['sessions'] = [\n  'provider' => 'Redis',\n  'config' => ['host' => '/run/valkey/valkey.sock', 'port' => 0],\n];")")
check "XF context on the socket is fine" test "$(decide)" = socket
APP_XF=("$(mk_xf xfdb "\$config['db']['unix_socket'] = '/run/mysqld/mysqld.sock';\n\$config['cache']['enabled'] = true;\n\$config['cache']['provider'] = 'Redis';\n\$config['cache']['config']['host'] = '127.0.0.1';")")
check "XF: a database socket does not make a TCP cache look like a socket" test "$(decide)" = tcp
APP_XF=("$(mk_xf xfcomm "// \$config['cache']['provider'] = 'Redis';\n\$config['cache']['enabled'] = true;")")
check "XF: a commented-out Redis provider does not count" test "$(decide)" = socket
APP_XF=()
# (b) WordPress
mk_w3() { mkdir -p "$WWW/$1/wp-content/w3tc-config"; printf '<?php\nreturn array(\n%b\n);\n' "$2" > "$WWW/$1/wp-content/w3tc-config/master.php"; }
APP_WP=("$(mk_wp w3tcp "define('DB_HOST', 'localhost');" 'W3 Total Cache Object Cache')")
mk_w3 w3tcp "\t'objectcache.engine' => 'redis',\n\t'objectcache.redis.servers' => array(\n\t\t0 => '127.0.0.1:6379',\n\t),\n\t'memcached.servers' => array(0 => '127.0.0.1:11211'),"
check "W3 Total Cache on Redis 127.0.0.1:6379 keeps TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp w3sock "define('DB_HOST', 'localhost');" 'W3 Total Cache Object Cache')")
mk_w3 w3sock "\t'pgcache.engine' => 'redis',\n\t'pgcache.redis.servers' => array(\n\t\t0 => '/run/valkey/valkey.sock',\n\t),"
check "W3 Total Cache on the socket is fine" test "$(decide)" = socket
APP_WP=("$(mk_wp w3pg "define('DB_HOST', 'localhost');")")
mk_w3 w3pg "\t'pgcache.engine' => 'redis',"
check "W3TC page cache on Redis (no drop-in, default servers) keeps TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp w3file "define('DB_HOST', 'localhost');" 'W3 Total Cache Object Cache')")
mk_w3 w3file "\t'objectcache.engine' => 'file',"
check "W3TC without Redis does not count" test "$(decide)" = socket
# W3TC 0.9.5+ stores master.php as '<?php exit; ?>' + JSON (pretty or one line).
mk_w3j() { mkdir -p "$WWW/$1/wp-content/w3tc-config"; printf '<?php exit; ?>%b' "$2" > "$WWW/$1/wp-content/w3tc-config/master.php"; }
APP_WP=("$(mk_wp w3j "define('DB_HOST', 'localhost');" 'W3 Total Cache Object Cache')")
mk_w3j w3j '{\n    "objectcache.engine": "redis",\n    "objectcache.redis.servers": [\n        "127.0.0.1:6379"\n    ],\n    "memcached.servers": [\n        "127.0.0.1:11211"\n    ]\n}'
check "W3TC JSON config on Redis 127.0.0.1:6379 keeps TCP" test "$(decide)" = tcp
mk_w3j w3j '{"dbcache.engine":"redis","dbcache.redis.servers":["\\/run\\/valkey\\/valkey.sock"],"objectcache.engine":"file","x.path":"\\/tmp\\/a.sock"}'
check "W3TC one-line JSON on the socket is fine" test "$(decide)" = socket
mk_w3j w3j '{"pgcache.engine":"redis","pgcache.redis.servers":["localhost:6379","\\/run\\/valkey\\/valkey.sock"],"z":"\\/tmp\\/b.sock"}'
check "W3TC one-line JSON with a loopback server keeps TCP" test "$(decide)" = tcp
mk_w3j w3j '{"objectcache.engine":"file","pgcache.engine":"disk"}'
check "W3TC JSON without Redis does not count" test "$(decide)" = socket
APP_WP=("$(mk_wp lsc "define('DB_HOST', 'localhost');" 'LiteSpeed Cache object cache')")
printf '{"object":true,"object-kind":true,"object-host":"localhost","object-port":6379}' > "$WWW/lsc/wp-content/.litespeed_conf.dat"
check "LiteSpeed Cache on Redis localhost keeps TCP" test "$(decide)" = tcp
printf '{"object":true,"object-kind":true,"object-host":"\\/run\\/valkey\\/valkey.sock","object-port":0}' > "$WWW/lsc/wp-content/.litespeed_conf.dat"
check "LiteSpeed Cache on the socket is fine" test "$(decide)" = socket
APP_WP=("$(mk_wp unk "define('DB_HOST', 'localhost');" 'Some Object Cache drop-in')")
check "an unknown object-cache.php drop-in counts as TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp bare "define('WP_REDIS_SERVERS', ['127.0.0.1:6379']);" 'Redis Object Cache Drop-In')")
check "WP_REDIS_SERVERS bare host:port keeps TCP" test "$(decide)" = tcp
APP_WP=("$(mk_wp rsrv "define('WP_REDIS_SERVERS', ['tcp://192.0.2.30:6379']);" 'Redis Object Cache Drop-In')")
check "WP_REDIS_SERVERS on another host is not this cache" test "$(decide)" = socket
APP_WP=()
# (c) PHP session handlers
PH=$VALKEY_SCAN_PHP_ETC/8.3; mkdir -p "$PH/fpm/pool.d" "$PH/fpm/conf.d" "$PH/cli"
printf '[www]\nphp_admin_value[session.save_handler] = redis\nphp_admin_value[session.save_path] = "tcp://127.0.0.1:6379?persistent=1"\n' > "$PH/fpm/pool.d/www.conf"
check "PHP pool session handler on tcp://127.0.0.1 keeps TCP" test "$(decide)" = tcp
valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" ""
check "... the report names the pool and the unix:// fix" \
  bash -c '[[ $1 == *"php-sessions \`"*"pool.d/www.conf"* && $1 == *"session.save_path = \"unix://"* ]]' _ "${VALKEY_TCP_NOTES[*]}"
printf '[www]\nphp_value[session.save_handler] = redis\nphp_value[session.save_path] = "unix:///run/valkey/valkey.sock"\n' > "$PH/fpm/pool.d/www.conf"
check "PHP sessions on unix:// are fine" test "$(decide)" = socket
rm -f "$PH/fpm/pool.d/www.conf"
printf '[Session]\nsession.save_handler = redis\nsession.save_path = "127.0.0.1:6379"\n' > "$PH/cli/php.ini"
check "php.ini with a schemeless loopback save_path keeps TCP" test "$(decide)" = tcp
printf '[Session]\n;session.save_handler = redis\nsession.save_handler = files\n' > "$PH/cli/php.ini"
check "a commented-out redis handler does not count" test "$(decide)" = socket
printf 'session.save_handler = redis\nsession.save_path = "tcp://192.0.2.40:6379"\n' > "$PH/fpm/conf.d/20-redis.ini"
check "PHP sessions on another host do not count" test "$(decide)" = socket
rm -rf "${VALKEY_SCAN_PHP_ETC:?}"/*
# (d) recent TCP flows, sampled
SS_FLOWS='tcp TIME-WAIT 127.0.0.1:41000 -> 127.0.0.1:6379'
check "a TIME-WAIT flow on the port keeps TCP" test "$(decide)" = tcp
valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" ""
check "... with a note naming it" has "${VALKEY_TCP_NOTES[*]}" "recent TCP connection on the port (TIME-WAIT 127.0.0.1:41000"
SS_FLOWS=""
if [[ -S $SOCK ]]; then
  : > "$SS_CALLS"; SS_LISTEN=1
  late_cli() { local n; n=$(wc -l < "$SS_CALLS"); [[ "$*" == "-s $SOCK CLIENT LIST" ]] || return 0
    if (( n >= 3 )); then printf 'id=9 addr=127.0.0.1:50000 fd=9 name= cmd=get\n'; else printf 'id=3 addr=%s:0 fd=8 name= cmd=client|list\n' "$SOCK"; fi; }
  VALKEY_TCP_MODE="" ; valkey_tcp_decide "$dconf" valkey late_cli "$SOCK" "" 1
  check "a client seen only in the 3rd sample keeps TCP" test "$VALKEY_TCP_MODE" = tcp
  check "... after 3 samples" test "$(wc -l < "$SS_CALLS" | tr -d ' ')" = 3
  : > "$SS_CALLS"; SS_LISTEN=0
  valkey_tcp_decide "$dconf" valkey late_cli "$SOCK" "" 1
  check "no listener on the port: one sample is enough" bash -c '[[ $1 == socket && $(wc -l < "$2" | tr -d " ") == 1 ]]' _ "$VALKEY_TCP_MODE" "$SS_CALLS"
  # (e) an active server whose clients cannot be listed keeps TCP
  FAKE_CLIENTS='LOADING Valkey is loading the dataset in memory'
  valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" "" 1
  check "an active server still LOADING keeps TCP (UNKNOWN)" test "$VALKEY_TCP_MODE" = tcp
  check "... with the re-check note" has "${VALKEY_TCP_NOTES[*]}" "could not be listed"
  FAKE_CLIENTS='ERR unknown command'
  check "an active server with a renamed CLIENT keeps TCP" test "$(VALKEY_TCP_MODE=""; valkey_tcp_decide "$dconf" valkey fake_cli "$SOCK" "" 1; printf '%s' "$VALKEY_TCP_MODE")" = tcp
  check "an inactive server (fresh install) still defaults to socket" test "$(decide)" = socket
  FAKE_CLIENTS=""
fi
check "an active server without a client binary keeps TCP" \
  test "$(valkey_live_tcp_clients /nonexistent/cli "$SOCK" 6379 1)" = UNKNOWN
check "callers pass the unit's active state" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -q "valkey_tcp_decide \"\$conf\" \"\$kind\" \"\$cli\" \"\$socket_path\" \"\" \"\$active\"" && sed -n "/^install_valkey()/,/^}/p" "$1" | grep -q "\"\${OPT\[valkey.tcp\]:-}\" \"\$vk_active\""' _ "$ALL_SRC_FILE"
# (f) an adopted redis-server: --valkey tcp=on|auto reaches it
rc=$TMP/redis-tcp.conf; printf 'port 0\n# setup.sh socket-only: tcp port 6379\n' > "$rc"
out=$(valkey_redis_record_tcp on "$rc" 2>&1)
check "F18: --valkey tcp=on is recorded in redis.conf" line_in "$rc" '# setup.sh valkey tcp=on'
check "F18: ... and says the next --optimize keeps TCP" has "$out" "next --optimize keeps TCP port 6379"
VALKEY_TCP_MODE=""; valkey_tcp_decide "$rc" redis fake_cli "$SOCK" ""
check "F18: the redis decision honours it" test "$VALKEY_TCP_MODE" = tcp-on
valkey_redis_record_tcp on "$rc" >/dev/null 2>&1
check "F18: recording twice writes one marker" test "$(grep -c 'tcp=on' "$rc")" = 1
valkey_redis_record_tcp auto "$rc" >/dev/null 2>&1
check "F18: tcp=auto removes it" no_line "$rc" '# setup.sh valkey tcp=on'
VALKEY_TCP_MODE=""; valkey_tcp_decide "$rc" redis fake_cli "$SOCK" ""
check "F18: the socket-only note for an adopted Redis says where tcp=on goes" has "${VALKEY_TCP_NOTES[*]}" "recorded in $rc for this adopted Redis"
check "F18: install_valkey's redis-server branch records the option before returning" \
  bash -c 'sed -n "/^install_valkey()/,/^}/p" "$1" | sed -n "/pkg_ok redis-server/,/return 0/p" | grep -q "valkey_redis_record_tcp \"\${OPT\[valkey.tcp\]:-}\" /etc/redis/redis.conf"' _ "$ALL_SRC_FILE"
# (g) online port only on a live socket without a forced restart
check "F22/F32: CONFIG SET port runs only over a live socket and without a forced restart" \
  bash -c 'sed -n "/^optimize_valkey_tune()/,/^}/p" "$1" | grep -B1 "valkey_online_port \"\$cli\" \"\$conf\"" | grep -q "if (( \${#live_ep\[@\]} )) && (( ! socket_changed && ! unit_changed )); then"' _ "$ALL_SRC_FILE"
check "F22: the snapshot settings go first and a refusal is reported" \
  bash -c 'b=$(sed -n "/^optimize_valkey_tune()/,/^}/p" "$1"); p=$(grep -n "! valkey_live_persist_on" <<<"$b" | head -n1 | cut -d: -f1); o=$(grep -n "valkey_online_port \"\$cli\"" <<<"$b" | cut -d: -f1); [[ -n $p && $p -lt $o ]] && [[ $(grep -c "refused the snapshot settings\|did not take the snapshot settings" <<<"$b") == 2 ]] && ! grep -q "valkey_live_persist_on.*|| true" <<<"$b"' _ "$ALL_SRC_FILE"


# ---------------------------------------------------------------------------
# Chevereto sessions check (1.22.5): warn when a site's sessions are not in Valkey
# ---------------------------------------------------------------------------
CS=$TMP/chevsess; mkdir -p "$CS/nginx/conf.d" "$CS/php/8.5/fpm/pool.d" "$CS/a/app" "$CS/b/app" "$CS/c/app" "$CS/d/app"
printf 'unixsocket /run/valkey/valkey.sock\nport 0\n' > "$CS/valkey.conf"
printf "<?php\nreturn [\n  'CHEVERETO_DB_NAME' => 'x',\n];\n" > "$CS/a/app/env.php"
printf "<?php\nreturn [\n  'CHEVERETO_SESSION_SAVE_HANDLER' => 'redis', 'CHEVERETO_SESSION_SAVE_PATH' => 'unix:///run/valkey/valkey.sock?prefix=chv:SESSION:',\n];\n" > "$CS/b/app/env.php"
printf "<?php\nreturn [\n  // 'CHEVERETO_SESSION_SAVE_HANDLER' => 'redis',\n  'CHEVERETO_SESSION_SAVE_HANDLER' => 'files', 'CHEVERETO_SESSION_SAVE_PATH' => '/var/lib/chev-sess',\n];\n" > "$CS/c/app/env.php"
printf "<?php\nreturn [];\n" > "$CS/d/app/env.php"
printf 'server {\n    root %s;\n    fastcgi_param CHEVERETO_SESSION_SAVE_HANDLER redis;\n    fastcgi_param CHEVERETO_SESSION_SAVE_PATH "tcp://127.0.0.1:6379";\n}\n' "$CS/d" > "$CS/nginx/conf.d/d.conf"
cs_run() ( # roots... -> report + warnings
  OPT_REPORT=()
  warn() { printf 'WARN %s\n' "$*"; }
  nginx_vhost_root() { sed -nE 's/^[[:space:]]*root[[:space:]]+([^;]+);.*/\1/p' "$1" | head -n1; }
  APP_CHEV=("$@")
  CHEV_SESSION_CACHE_CONFS=${CS_CONFS-$CS/valkey.conf}
  chevereto_session_check "$CS/nginx" "$CS/php"
  printf '%s\n' "${OPT_REPORT[@]}"
)
out=$(cs_run "$CS/a")
check "Chevereto sessions: default (no handler set) warns: files in /tmp" \
  bash -c '[[ $1 == *"WARN Chevereto"*"/a: PHP sessions are files in /tmp, not Valkey"* && $1 == *"**WARNING**"* ]]' _ "$out"
check "Chevereto sessions: the warning gives the env.php lines with the local socket" \
  has "$out" "'CHEVERETO_SESSION_SAVE_PATH' => 'unix:///run/valkey/valkey.sock'"
out=$(cs_run "$CS/b")
check "Chevereto sessions: redis on the local socket is reported as fine, no warning" \
  bash -c '[[ $1 == *"sessions in Valkey over the local socket"* && $1 != *WARN* ]]' _ "$out"
out=$(cs_run "$CS/c")
check "Chevereto sessions: an explicit files handler warns with its path (commented lines ignored)" \
  bash -c '[[ $1 == *"files in /var/lib/chev-sess"* && $1 == *WARN* ]]' _ "$out"
out=$(cs_run "$CS/d")
check "Chevereto sessions: a vhost fastcgi_param redis counts (TCP noted, no warning)" \
  bash -c '[[ $1 == *"sessions in Valkey/Redis at \`tcp://127.0.0.1:6379\`"* && $1 == *"fastcgi_param"* && $1 != *WARN* ]]' _ "$out"
printf "<?php\nreturn ['CHEVERETO_SESSION_SAVE_HANDLER' => 'files'];\n" > "$CS/d/app/env.php"
out=$(cs_run "$CS/d")
check "Chevereto sessions: env.php files vs fastcgi_param redis is a conflict warning" \
  bash -c '[[ $1 == *"set differently"* && $1 == *WARN* ]]' _ "$out"
printf "<?php\nreturn [];\n" > "$CS/d/app/env.php"; rm -f "$CS/nginx/conf.d/d.conf"
printf '[www]\nenv[CHEVERETO_SESSION_SAVE_HANDLER] = redis\nenv[CHEVERETO_SESSION_SAVE_PATH] = "unix:///run/valkey/valkey.sock"\n' > "$CS/php/8.5/fpm/pool.d/www.conf"
out=$(cs_run "$CS/d")
check "Chevereto sessions: an FPM pool env[] redis counts" \
  bash -c '[[ $1 == *"over the local socket"* && $1 == *"env[]"* && $1 != *WARN* ]]' _ "$out"
rm -f "$CS/php/8.5/fpm/pool.d/www.conf"
out=$(CS_CONFS="$CS/none.conf" cs_run "$CS/a")
check "Chevereto sessions: without Valkey the warning says to install it" has "$out" "setup.sh --valkey"
out=$(cs_run)
check "Chevereto sessions: no Chevereto site, no section" test -z "$out"
out=$(cs_run "$CS/a" "$CS/b")
check "Chevereto sessions: one section, one line per site" \
  bash -c '[[ $(grep -c "^## Chevereto sessions" <<<"$1") -eq 1 && $(grep -c "^- " <<<"$1") -eq 2 ]]' _ "$out"
check "Chevereto sessions: --optimize runs the check whenever nginx is managed" \
  grep -q 'chevereto_session_check /etc/nginx /etc/php' "$ROOT/lib/restart.sh"

# Review fixes: pool scope, single quotes, redis without a path.
mkdir -p "$CS/php/8.4/fpm/pool.d"
printf "<?php\nreturn [];\n" > "$CS/d/app/env.php"
printf '[a]\nchdir = %s\nenv[CHEVERETO_SESSION_SAVE_HANDLER] = redis\nenv[CHEVERETO_SESSION_SAVE_PATH] = "unix:///run/valkey/valkey.sock"\n' "$CS/b" > "$CS/php/8.5/fpm/pool.d/a.conf"
printf '[other]\nchdir = /srv/other\n' > "$CS/php/8.4/fpm/pool.d/other.conf"
out=$(cs_run "$CS/d")
check "Chevereto sessions: another site's pool env[] does not count for this site" \
  bash -c '[[ $1 == *"files in /tmp"* && $1 == *WARN* ]]' _ "$out"
rm -f "$CS/php/8.5/fpm/pool.d/a.conf" "$CS/php/8.4/fpm/pool.d/other.conf"
printf "server {\n    root %s;\n    fastcgi_param CHEVERETO_SESSION_SAVE_HANDLER 'redis';\n    fastcgi_param CHEVERETO_SESSION_SAVE_PATH 'unix:///run/valkey/valkey.sock';\n}\n" "$CS/d" > "$CS/nginx/conf.d/d.conf"
out=$(cs_run "$CS/d")
check "Chevereto sessions: single-quoted fastcgi_param values are understood" \
  bash -c '[[ $1 == *"over the local socket"* && $1 != *WARN* ]]' _ "$out"
printf "server {\n    root %s;\n    fastcgi_param CHEVERETO_SESSION_SAVE_HANDLER redis;\n}\n" "$CS/d" > "$CS/nginx/conf.d/d.conf"
out=$(cs_run "$CS/d")
check "Chevereto sessions: redis with no save path warns instead of 'socket /tmp'" \
  bash -c '[[ $1 == *"no CHEVERETO_SESSION_SAVE_PATH is set"* && $1 == *WARN* && $1 != *"socket \`/tmp\`"* ]]' _ "$out"
rm -f "$CS/nginx/conf.d/d.conf"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
