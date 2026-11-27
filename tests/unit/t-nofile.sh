#!/usr/bin/env bash
# Unit tests for the 1.22.5 file-descriptor plan (nofile_plan in
# lib/optimize.sh): every managed service's systemd LimitNOFILE sized in one
# place from its own need, never below the 1.22.4 values, never above
# fs.nr_open, each internal limit (worker_rlimit_nofile, rlimit_files,
# maxclients, open_files_limit, Elasticsearch's 65535) <= its unit's value,
# and the sum of the unit limits within fs.file-max.  Also checks that the
# unit writers (nginx, PHP-FPM, the Valkey tool and drop-in, MariaDB,
# Elasticsearch) take their value from the plan, and the --optimize report.
# No root, no services and no system changes: unit directories, nr_open and
# file-max are fixtures, the drop-in writer is a stub.
# Usage: bash tests/unit/t-nofile.sh
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-nofile.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
trap 'rm -rf "$TMP"' EXIT

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-nofile.sh,title=nofile test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
eq() { [[ $1 == "$2" ]]; }
le() { (( $1 <= $2 )); }
ge() { (( $1 >= $2 )); }
is_pow2() { (( $1 > 0 && ($1 & ($1 - 1)) == 0 )); }

# The 1.22.4 values: no service may get less.
TODAY_NGINX=524288 TODAY_PHP=524288 TODAY_VALKEY=524288 TODAY_MARIADB=1048576 TODAY_ELASTIC=1048576

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check "pow2: 0 -> 1024" eq "$(nofile_pow2 0)" 1024
check "pow2: 1025 -> 2048" eq "$(nofile_pow2 1025)" 2048
check "pow2: 65535 -> 65536" eq "$(nofile_pow2 65535)" 65536
check "pow2: 524288 stays" eq "$(nofile_pow2 524288)" 524288
check "pow2: 600032 -> 1048576" eq "$(nofile_pow2 600032)" 1048576
check "pow2: garbage -> 1024" eq "$(nofile_pow2 abc)" 1024
check "unit value: need below floor keeps the floor" eq "$(nofile_unit_value 524288 70000 "")" 524288
check "unit value: need above floor rounds up" eq "$(nofile_unit_value 524288 600000 "")" 1048576
check "unit value: capped at nr_open when the cap is >= floor" eq "$(nofile_unit_value 524288 1500000 1048576)" 1048576
check "unit value: a cap below the floor never lowers the floor" eq "$(nofile_unit_value 1048576 70000 524288)" 1048576
check "nr_open hook" eq "$(NOFILE_NR_OPEN=2097152 nofile_nr_open)" 2097152
check "nr_open hook: garbage reads as unknown" eq "$(NOFILE_NR_OPEN=x nofile_nr_open)" ""

# ---------------------------------------------------------------------------
# Plans for three host classes
# ---------------------------------------------------------------------------
# plan_case NAME TYPE CPUS RAM_MB MAXCLIENTS MAX_CONN OPEN_CACHE
plan_case() {
  local name=$1 type=$2 cpus=$3 ram=$4 maxc=$5 conn=$6 cache=$7 nr fmax sum s u i
  HOST_SERVER_TYPE=$type
  NOFILE_CPUS=$cpus NOFILE_RAM_MB=$ram NOFILE_VALKEY_MAXCLIENTS=$maxc
  MARIADB_PROFILE_MAX_CONN=$conn MARIADB_PROFILE_OPEN_CACHE=$cache
  fmax=$(sysctl_file_max_target "$ram" 2>/dev/null)
  NOFILE_NR_OPEN=$fmax
  nofile_plan
  check "$name: nginx unit = 1.22.4 value" eq "$NOFILE_PLAN_NGINX_UNIT" "$TODAY_NGINX"
  check "$name: php unit = 1.22.4 value" eq "$NOFILE_PLAN_PHP_UNIT" "$TODAY_PHP"
  check "$name: valkey unit = 1.22.4 value" eq "$NOFILE_PLAN_VALKEY_UNIT" "$TODAY_VALKEY"
  check "$name: mariadb unit = 1.22.4 value" eq "$NOFILE_PLAN_MARIADB_UNIT" "$TODAY_MARIADB"
  check "$name: elasticsearch unit = 1.22.4 value" eq "$NOFILE_PLAN_ELASTIC_UNIT" "$TODAY_ELASTIC"
  check "$name: mariadb open_files_limit = 1.22.4 value" eq "$NOFILE_PLAN_MARIADB_INTERNAL" 524288
  check "$name: php rlimit_files = 1.22.4 value" eq "$NOFILE_PLAN_PHP_INTERNAL" 524288
  check "$name: nginx worker_rlimit_nofile <= unit" le "$NOFILE_PLAN_NGINX_INTERNAL" "$NOFILE_PLAN_NGINX_UNIT"
  check "$name: nginx per-worker need <= unit" le "$NOFILE_PLAN_NGINX_NEED" "$NOFILE_PLAN_NGINX_UNIT"
  check "$name: nginx worst case (2 sockets per connection + open_file_cache + 1024) fits worker_rlimit_nofile" le "$NOFILE_PLAN_NGINX_NEED" "$NOFILE_PLAN_NGINX_INTERNAL"
  check "$name: php rlimit_files <= unit" le "$NOFILE_PLAN_PHP_INTERNAL" "$NOFILE_PLAN_PHP_UNIT"
  check "$name: valkey maxclients + 32 <= unit" le $(( NOFILE_PLAN_VALKEY_INTERNAL + 32 )) "$NOFILE_PLAN_VALKEY_UNIT"
  check "$name: mariadb open_files_limit <= unit" le "$NOFILE_PLAN_MARIADB_INTERNAL" "$NOFILE_PLAN_MARIADB_UNIT"
  check "$name: mariadb open_files_limit >= what mariadbd computes" ge "$NOFILE_PLAN_MARIADB_INTERNAL" "$NOFILE_PLAN_MARIADB_NEED"
  check "$name: elasticsearch 65535 <= unit" le 65535 "$NOFILE_PLAN_ELASTIC_UNIT"
  for u in "$NOFILE_PLAN_NGINX_UNIT" "$NOFILE_PLAN_PHP_UNIT" "$NOFILE_PLAN_VALKEY_UNIT" "$NOFILE_PLAN_MARIADB_UNIT" "$NOFILE_PLAN_ELASTIC_UNIT"; do
    check "$name: unit $u is a power of two" is_pow2 "$u"
    check "$name: unit $u <= fs.nr_open $fmax" le "$u" "$fmax"
  done
  sum=$(NOFILE_PRESENT="nginx php valkey mariadb elastic" nofile_plan_sum)
  fmax=$(NOFILE_PRESENT="nginx php valkey mariadb elastic" sysctl_file_max_target "$ram" 2>/dev/null)
  check "$name: sum of unit limits ($sum) <= fs.file-max ($fmax)" le "$sum" "$fmax"
  check "$name: fs.file-max stays within the 10M ceiling" le "$fmax" 10485760
  unset NOFILE_CPUS NOFILE_RAM_MB NOFILE_VALKEY_MAXCLIENTS NOFILE_NR_OPEN
  MARIADB_PROFILE_MAX_CONN="" MARIADB_PROFILE_OPEN_CACHE=""
}
# 4 GB VPS, 2 vCPU: 24 PHP children -> maxclients floor 10000; MariaDB 200.
plan_case "4 GB VPS" vps 2 3900 10000 200 4000
check "4 GB VPS: nginx rlimit is the 65536 floor" eq "$(NOFILE_CPUS=2 NOFILE_RAM_MB=3900 nofile_internal nginx)" 65536
# 32 GB dedicated, 12 threads: 160 children -> 10000; max_connections 2000.
plan_case "32 GB 12-thread dedicated" dedi 12 32000 10000 2000 32000
# 64 GB dedicated, 16 threads, extreme inputs: maxclients 100000 (its cap),
# max_connections 100000 (the bound for a kept live value).
plan_case "64 GB 16-thread dedicated" dedi 16 64000 100000 100000 32768
# Unknown MariaDB inputs take their caps and still fit.
HOST_SERVER_TYPE=dedi NOFILE_CPUS=8 NOFILE_RAM_MB=16000 nofile_plan
check "unknown MariaDB profile: open_files_limit 524288" eq "$NOFILE_PLAN_MARIADB_INTERNAL" 524288
check "unknown MariaDB profile: need is 5 x 100000" eq "$NOFILE_PLAN_MARIADB_NEED" 500000

# A grid of CPU counts and RAM: invariants hold everywhere.
grid_ok=1
for HOST_SERVER_TYPE in vps dedi; do
  for c in 1 2 4 8 12 16 32 64 128 256; do
    for r in 1024 3900 8000 32000 128000 512000; do
      NOFILE_CPUS=$c NOFILE_RAM_MB=$r nofile_plan
      (( NOFILE_PLAN_NGINX_INTERNAL <= NOFILE_PLAN_NGINX_UNIT )) || grid_ok=0
      (( NOFILE_PLAN_NGINX_NEED <= NOFILE_PLAN_NGINX_UNIT )) || grid_ok=0
      (( NOFILE_PLAN_NGINX_UNIT >= TODAY_NGINX )) || grid_ok=0
      (( NOFILE_PLAN_VALKEY_INTERNAL + 32 <= NOFILE_PLAN_VALKEY_UNIT )) || grid_ok=0
      (( NOFILE_PLAN_MARIADB_INTERNAL <= NOFILE_PLAN_MARIADB_UNIT )) || grid_ok=0
    done
  done
done
unset NOFILE_CPUS NOFILE_RAM_MB
check "grid 1..256 CPUs x 1..512 GB: internal <= unit, never below 1.22.4" eq "$grid_ok" 1

# nofile_plan restores the nginx globals the tuner set.
NGINX_WORKER_PROCESSES=7 NGINX_WORKER_RLIMIT=111 NGINX_WORKER_CONNECTIONS=99 NGINX_PHP_KEEPALIVE=zz
NOFILE_CPUS=32 nofile_plan
check "plan leaves NGINX_WORKER_* untouched" eq "$NGINX_WORKER_PROCESSES/$NGINX_WORKER_RLIMIT/$NGINX_WORKER_CONNECTIONS/$NGINX_PHP_KEEPALIVE" "7/111/99/zz"
NGINX_WORKER_PROCESSES="" NGINX_WORKER_RLIMIT="" NGINX_WORKER_CONNECTIONS="" NGINX_PHP_KEEPALIVE=""
unset NOFILE_CPUS

# A need above a floor raises that unit (and only that unit), capped at nr_open.
NOFILE_VALKEY_MAXCLIENTS=600000 nofile_plan
check "need above floor: valkey unit rounds up to 1048576" eq "$NOFILE_PLAN_VALKEY_UNIT" 1048576
check "need above floor: nginx unit unchanged" eq "$NOFILE_PLAN_NGINX_UNIT" 524288
MARIADB_PROFILE_MAX_CONN=200000 MARIADB_PROFILE_OPEN_CACHE=32768 nofile_plan
check "need above floor: mariadb open_files_limit 1048576" eq "$NOFILE_PLAN_MARIADB_INTERNAL" 1048576
check "need above floor: mariadb internal <= unit" le "$NOFILE_PLAN_MARIADB_INTERNAL" "$NOFILE_PLAN_MARIADB_UNIT"
MARIADB_PROFILE_MAX_CONN=400000 MARIADB_PROFILE_OPEN_CACHE=32768 NOFILE_NR_OPEN=1048576 nofile_plan
check "nr_open cap: mariadb unit stays at nr_open" eq "$NOFILE_PLAN_MARIADB_UNIT" 1048576
check "nr_open cap: mariadb open_files_limit clamped to the unit" eq "$NOFILE_PLAN_MARIADB_INTERNAL" 1048576
MARIADB_PROFILE_MAX_CONN="" MARIADB_PROFILE_OPEN_CACHE=""

# Getters and their fallback.
check "nofile_unit mariadb" eq "$(nofile_unit mariadb)" 1048576
check "nofile_unit elastic" eq "$(nofile_unit elastic)" 1048576
check "nofile_internal php" eq "$(nofile_internal php)" 524288
check "nofile_internal elastic" eq "$(nofile_internal elastic)" 65535
check "nofile_unit rejects an unknown service" eq "$(nofile_unit nosuch || printf rc=$?)" "rc=1"
out=$( nofile_plan() { return 1; }; NOFILE_PLAN_NGINX_UNIT=""; nofile_unit nginx )
check "nofile_unit falls back to the 1.22.4 value when the plan fails" eq "$out" 524288

# ---------------------------------------------------------------------------
# fs.file-max
# ---------------------------------------------------------------------------
check "file-max: nginx-only 2 GB host keeps the RAM value" eq "$(NOFILE_PRESENT="nginx" sysctl_file_max_target 2048 2>/dev/null)" 2097152
check "file-max: 1 GB floor" eq "$(NOFILE_PRESENT="" sysctl_file_max_target 512 2>/dev/null)" 1048576
check "file-max: 10M ceiling" eq "$(NOFILE_PRESENT="" sysctl_file_max_target 64000 2>/dev/null)" 10485760
out=$(NOFILE_PRESENT="nginx php php valkey mariadb elastic" sysctl_file_max_target 3500 2>/dev/null)
check "file-max: raised to the sum when the units need more (two PHP series, all services, 3.5 GB)" eq "$out" 4194304
err=$(NOFILE_PRESENT="nginx php php valkey mariadb elastic" sysctl_file_max_target 3500 2>&1 >/dev/null)
check "file-max: the raise is logged" has "$err" "LimitNOFILE values add up to 4194304"
check "file-max: never above 10M even for a huge sum" eq "$(NOFILE_PRESENT="mariadb mariadb mariadb mariadb mariadb mariadb mariadb mariadb mariadb mariadb mariadb" sysctl_file_max_target 4000 2>/dev/null)" 10485760
out=$( unset -f nofile_plan_sum; sysctl_file_max_target 4096 2>/dev/null )
check "file-max: works without the plan (os.sh alone)" eq "$out" 4194304
check "configure_sysctl uses sysctl_file_max_target" has "$(declare -f configure_sysctl)" 'file_max_target=$(sysctl_file_max_target "$ram_mb")'
check "fs.nr_open target derives from the file-max target" has "$(declare -f configure_sysctl)" 'nr_open_target=$(sysctl_nr_open_target "$file_max_target")'

# ---------------------------------------------------------------------------
# DB4 (1.22.5): fs.nr_open / fs.file-max never below the system's own value,
# nr_open >= 2 x the largest unit limit.  /proc values are fixtures.
# ---------------------------------------------------------------------------
check "nr_open target: 2 x the largest unit (1048576) above a 1M file-max" eq "$(sysctl_nr_open_target 1048576)" 2097152
check "nr_open target: the 10M file-max when larger" eq "$(sysctl_nr_open_target 10485760)" 10485760
out=$(NOFILE_VALKEY_MAXCLIENTS=1500000 sysctl_nr_open_target 1048576)
check "nr_open target: follows a raised unit (valkey 2097152 -> 4194304)" eq "$out" 4194304
nr_t=$(sysctl_nr_open_target 1048576)
for u in "$TODAY_NGINX" "$TODAY_PHP" "$TODAY_VALKEY" "$TODAY_MARIADB" "$TODAY_ELASTIC" 1048576; do
  check "nr_open target $nr_t >= 2 x LimitNOFILE $u" ge "$nr_t" $(( u * 2 ))
done
mkdir -p "$SETUP_STATE_DIR"
# Stock Ubuntu: systemd raised both at boot; nothing is written.
check "fd ceiling: live nr_open 1073741816 >= target -> key not written" \
  eq "$(SYSCTL_LIVE_NR_OPEN=1073741816 sysctl_fd_ceiling_value fs.nr_open 10485760 '')" ""
check "fd ceiling: live file-max LONG_MAX >= target -> key not written" \
  eq "$(SYSCTL_LIVE_FILE_MAX=9223372036854775807 sysctl_fd_ceiling_value fs.file-max 10485760 '')" ""
check "fd ceiling: live equal to the target -> key not written" \
  eq "$(SYSCTL_LIVE_NR_OPEN=2097152 sysctl_fd_ceiling_value fs.nr_open 2097152 '')" ""
# Kernel default below the target: the target is written.
check "fd ceiling: live nr_open 1048576 < target -> target written" \
  eq "$(SYSCTL_LIVE_NR_OPEN=1048576 sysctl_fd_ceiling_value fs.nr_open 2097152 '')" 2097152
check "fd ceiling: live file-max 400000 < target -> target written" \
  eq "$(SYSCTL_LIVE_FILE_MAX=400000 sysctl_fd_ceiling_value fs.file-max 4194304 '')" 4194304
# A 1.22.4 host: our old 10M line lowered systemd's value; the value recorded
# before the first run is the system's, so the line goes.
printf '1073741816\n' > "$SETUP_STATE_DIR/sysctl-orig-fs.nr_open"
check "fd ceiling: live equal to our old line -> the recorded original decides (dropped)" \
  eq "$(SYSCTL_LIVE_NR_OPEN=10485760 sysctl_fd_ceiling_value fs.nr_open 10485760 10485760)" ""
check "fd ceiling: system value is the recorded original" \
  eq "$(SYSCTL_LIVE_NR_OPEN=10485760 sysctl_fd_system_value fs.nr_open 10485760)" 1073741816
# A kernel without the boot raise: our own line is kept on every run (no
# write / drop flip-flop across reboots).
printf '1048576\n' > "$SETUP_STATE_DIR/sysctl-orig-fs.nr_open"
check "fd ceiling: our own value with a lower original is kept" \
  eq "$(SYSCTL_LIVE_NR_OPEN=2097152 sysctl_fd_ceiling_value fs.nr_open 2097152 2097152)" 2097152
rm -f "$SETUP_STATE_DIR/sysctl-orig-fs.nr_open"
check "fd ceiling: our own value and no recorded original -> written" \
  eq "$(SYSCTL_LIVE_NR_OPEN=2097152 sysctl_fd_ceiling_value fs.nr_open 2097152 2097152)" 2097152
# sysctl_fd_ceiling_apply drops the base template's lines for a key left to
# the kernel and raises a live value our old line had lowered.
printf 'fs.nr_open    = 10485760\nfs.file-max = 10485760\nvm.swappiness = 10\n' > "$TMP/sysctl.conf"
printf '1073741816\n' > "$SETUP_STATE_DIR/sysctl-orig-fs.nr_open"
sysctl_log="$TMP/sysctl-w.log"; : > "$sysctl_log"
out=$(
  sysctl() { if [[ $1 == -n ]]; then printf '10485760\n'; else printf '%s\n' "$*" >> "$sysctl_log"; fi; }
  info() { :; }
  SYSCTL_LIVE_NR_OPEN=10485760 sysctl_fd_ceiling_apply "$TMP/sysctl.conf" 10485760 "" 10485760 10485760
  cat "$TMP/sysctl.conf"
)
check "fd apply: the nr_open line is removed" lacks "$out" "fs.nr_open"
check "fd apply: a written key stays" has "$out" "fs.file-max = 10485760"
check "fd apply: other keys stay" has "$out" "vm.swappiness = 10"
check "fd apply: the live value is raised to the system's" has "$(cat "$sysctl_log")" "fs.nr_open=1073741816"
rm -f "$SETUP_STATE_DIR/sysctl-orig-fs.nr_open"
check "configure_sysctl writes the fd lines only through the ceiling helper" \
  lacks "$(declare -f configure_sysctl)" 'fs.nr_open = ${file_max}'
check "configure_sysctl finishes the fd ceilings after the dedupe" \
  has "$(declare -f configure_sysctl)" 'sysctl_fd_ceiling_apply /etc/sysctl.conf'

# ---------------------------------------------------------------------------
# Present services
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u1" "$TMP/u2"
for f in nginx.service php8.4-fpm.service php8.5-fpm.service valkey-server.service; do : > "$TMP/u1/$f"; done
ln -s valkey-server.service "$TMP/u1/valkey.service"
for f in mariadb.service elasticsearch.service redis-server.service nginx.service; do : > "$TMP/u2/$f"; done
ln -s mariadb.service "$TMP/u2/mysql.service"
out=$(NOFILE_UNIT_DIRS="$TMP/u1 $TMP/u2" nofile_present_services | tr '\n' ' ')
check "present: nginx once, php per series, valkey once, mariadb, elastic" eq "$out" "elastic mariadb nginx php php valkey "
out=$(NOFILE_UNIT_DIRS="$TMP/nonexistent" nofile_present_services | tr '\n' ' ')
check "present: nothing installed" eq "$out" ""
check "sum of the fixture: 3 x 524288 + 524288 + 2 x 1048576" eq "$(NOFILE_UNIT_DIRS="$TMP/u1 $TMP/u2" nofile_plan_sum)" $(( 4 * 524288 + 2 * 1048576 ))

# ---------------------------------------------------------------------------
# --optimize report
# ---------------------------------------------------------------------------
out=$(NOFILE_UNIT_DIRS="$TMP/u1 $TMP/u2" NOFILE_FILE_MAX=10485760 NOFILE_CPUS=12 NOFILE_RAM_MB=32000 nofile_plan_report_lines)
check "report: nginx line" has "$out" "LimitNOFILE nginx: unit 524288 / worker_rlimit_nofile"
check "report: php line counts both series" has "$out" "LimitNOFILE php-fpm (2 units): unit 524288 / rlimit_files 524288"
check "report: valkey line" has "$out" "LimitNOFILE valkey: unit 524288 / maxclients"
check "report: mariadb line" has "$out" "LimitNOFILE mariadb: unit 1048576 / open_files_limit 524288"
check "report: elasticsearch line" has "$out" "LimitNOFILE elasticsearch: unit 1048576 / bootstrap minimum 65535"
check "report: file-max covers the sum" has "$out" "fs.file-max 10485760 covers the sum of the unit limits 4194304"
out=$(NOFILE_PRESENT="nginx mariadb" NOFILE_FILE_MAX=1048576 nofile_plan_report_lines)
check "report: WARN when file-max is below the sum" has "$out" "WARN fs.file-max 1048576 is below the sum of the unit limits 1572864"
check "report: absent services have no line" lacks "$out" "valkey"
out=$(NOFILE_PRESENT="" nofile_plan_report_lines)
check "report: no services, no lines" eq "$out" ""
out=$(
  opt_report() { printf '%s\n' "$*"; }
  verify_summary_lines() { printf 'nginx: test\n'; }
  OPT_WEB_LEGACY=1 NOFILE_PRESENT="nginx mariadb" NOFILE_FILE_MAX=1048576 opt_report_verify
)
check "Verify block carries the plan lines" has "$out" "- LimitNOFILE mariadb: unit 1048576"
check "Verify block shows the WARN as **WARNING**" has "$out" "- **WARNING** fs.file-max 1048576 is below"

# ---------------------------------------------------------------------------
# Unit writers take the plan's value
# ---------------------------------------------------------------------------
check "nginx unit text: LimitNOFILE from the plan" has "$(nginx_unit_text)" $'\nLimitNOFILE=524288\n'
check "nginx unit source calls nofile_unit" has "$(declare -f nginx_unit_text)" 'nofile_unit nginx'
check "php unit text: LimitNOFILE from the plan" has "$(php_build_unit_text 8.5)" $'\nLimitNOFILE=524288\n'
check "php unit source calls nofile_unit" has "$(declare -f php_build_unit_text)" 'nofile_unit php'
check "php-fpm.conf rlimit_files from the plan constant" has "$(php_build_fpm_conf_text 8.5)" $'\nrlimit_files = 524288\n'
check "pool rlimit_files from the plan constant" has "$(declare -f tune_php_fpm_version)" 'NOFILE_PHP_RLIMIT_FILES'
check "mariadb base block open_files_limit from the plan" has "$(declare -f mariadb_write_base_block)" 'nofile_internal mariadb'
cnf="$TMP/50-server.cnf"
printf '[mysqld]\nbind-address = 127.0.0.1\n' > "$cnf"
( mkdir() { :; }; chown() { :; }; chmod() { :; }; mariadb_write_base_block "$cnf" 127.0.0.1 ) >/dev/null 2>&1 || true
check "mariadb base block writes open_files_limit = 524288" has "$(cat "$cnf")" $'\nopen_files_limit = 524288\n'

# Drop-ins: capture what the writer is given.
write_service_limits_dropin() { printf '%s\n--\n%s\n' "$1" "$2" > "$TMP/dropin"; return 0; }
mariadb_write_systemd_limits
out=$(cat "$TMP/dropin")
check "mariadb drop-in: LimitNOFILE from the plan" has "$out" $'\nLimitNOFILE=1048576\n'
check "mariadb drop-in: rest of configs/mariadb/limit_nofile.conf kept" has "$out" "Environment=_WSREP_NEW_CLUSTER="
MARIADB_PROFILE_MAX_CONN=400000 MARIADB_PROFILE_OPEN_CACHE=32768 NOFILE_NR_OPEN=4194304 mariadb_write_systemd_limits
check "mariadb drop-in: a larger plan value is written" has "$(cat "$TMP/dropin")" $'\nLimitNOFILE=2097152\n'
MARIADB_PROFILE_MAX_CONN="" MARIADB_PROFILE_OPEN_CACHE=""
elasticsearch_write_systemd_limits
out=$(cat "$TMP/dropin")
check "elasticsearch drop-in: LimitNOFILE from the plan" has "$out" $'\nLimitNOFILE=1048576\n'
check "elasticsearch drop-in: same other lines as 1.22.4" has "$out" $'[Service]\nLimitMEMLOCK=infinity\nLimitNOFILE=1048576\nLimitNPROC=4096\nUMask=0027'
valkey_write_systemd_limits redis-server redis
check "redis drop-in: LimitNOFILE from the plan" has "$(cat "$TMP/dropin")" $'\nLimitNOFILE=524288\n'
NOFILE_VALKEY_MAXCLIENTS=600000 valkey_write_systemd_limits redis-server redis
check "redis drop-in: a larger plan value is written" has "$(cat "$TMP/dropin")" $'\nLimitNOFILE=1048576\n'
check "valkey layout passes the plan to the tool" has "$(declare -f valkey_build_layout)" 'VALKEY_LIMIT_NOFILE=$(nofile_unit valkey'
check "valkey tool runs get the plan" has "$(declare -f valkey_build_run)" 'VALKEY_LIMIT_NOFILE="$(nofile_unit valkey'

# The Valkey tool's own unit.
vk() { env -u VALKEY_LIMIT_NOFILE VALKEY_BUILD_UNIT_DIR="$TMP/vkunit" VALKEY_BUILD_ROOT="$TMP/vkroot" "$@" bash "$ROOT/tools/valkey-build.sh" unit-text 2>/dev/null; }
mkdir -p "$TMP/vkunit"
check "valkey tool: default 524288" has "$(vk)" $'\nLimitNOFILE=524288\n'
check "valkey tool: VALKEY_LIMIT_NOFILE from setup.sh" has "$(vk VALKEY_LIMIT_NOFILE=1048576)" $'\nLimitNOFILE=1048576\n'
check "valkey tool: never below 524288" has "$(vk VALKEY_LIMIT_NOFILE=1024)" $'\nLimitNOFILE=524288\n'
printf '[Service]\nLimitNOFILE=1048576\n' > "$TMP/vkunit/valkey-server.service"
check "valkey tool: a timer run keeps the higher value of the current unit" has "$(vk)" $'\nLimitNOFILE=1048576\n'
printf '[Service]\nLimitNOFILE=1024\n' > "$TMP/vkunit/valkey-server.service"
check "valkey tool: a lower current value is not kept" has "$(vk)" $'\nLimitNOFILE=524288\n'

# Report strings follow the plan.
check "mariadb optimizer reports the plan value" has "$(grep -h 'systemd LimitNOFILE=' "$ROOT/lib/service-optimizers.sh")" 'nofile_unit mariadb'
check "valkey optimizer reports the plan value" has "$(grep -h 'systemd limits: LimitNOFILE=' "$ROOT/lib/service-optimizers.sh")" 'nofile_unit valkey'
check "no literal LimitNOFILE left in the lib unit writers" eq "$(cat "$ROOT/lib/nginx-build.sh" "$ROOT/lib/php-build.sh" | grep -cE '^LimitNOFILE=[0-9]+$' || true)" 0

# nginx_worker_rlimit_fit: raised to a power of two only when the worst case
# does not fit; never lowered; capped at the 524288 unit floor.
check "rlimit_fit: fits -> unchanged" eq "$(nginx_worker_rlimit_fit 98304 8192 50000)" 98304
check "rlimit_fit: EPYC 12-thread case -> 131072" eq "$(nginx_worker_rlimit_fit 98304 24576 71680)" 131072
check "rlimit_fit: never lowered" eq "$(nginx_worker_rlimit_fit 524288 65535 200000)" 524288
check "rlimit_fit: capped at 524288" eq "$(nginx_worker_rlimit_fit 65536 65535 900000)" 524288

printf '\nTOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
