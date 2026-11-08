#!/usr/bin/env bash
# Unit tests for the hardware-aware tuning helpers in setup.sh.
# No root, no services and no system changes are required.
# Usage: bash tests/test-tuning.sh
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/angie"

PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-tuning.XXXXXX)
# Scratch data stays under /tmp and is allowed to expire there; the tests do
# not remove it, so a failed run remains inspectable.

# Load the helpers without running main().  Source first: setup.sh defines its
# own ok()/warn() logging helpers, so test helpers must be defined afterwards.
export SETUP_TEST_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/setup.sh"
# setup.sh installs an ERR trap for production diagnostics.  These tests
# deliberately exercise failure paths, so drop the trap; set -e still catches
# genuinely unexpected errors.
trap - ERR

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  # GitHub Actions turns this into a check annotation, so a CI-only failure
  # names the broken check without requiring the job log.
  printf '::error file=tests/test-tuning.sh,title=Tuning test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
cron_contains()     { [[ $1 == *"$2"* ]]; }
cron_not_contains() { [[ $1 != *"$2"* ]]; }

# Scratch helpers must never place data outside /tmp, and sed_in_place must not
# leave a sibling scratch file next to the live target.
check_tmp_path() { case "$1" in /tmp/*) return 0 ;; *) return 1 ;; esac; }
check "tmp_file creates under /tmp" check_tmp_path "$(tmp_file)"
check "tmp_dir creates under /tmp" check_tmp_path "$(tmp_dir)"
mkdir -p "$TMP/sed-in-place"
printf 'key = old\n' > "$TMP/sed-in-place/file.conf"
sed_in_place -E 's/^key = old$/key = new/' "$TMP/sed-in-place/file.conf"
check "sed_in_place rewrites the file" grep -qx 'key = new' "$TMP/sed-in-place/file.conf"
check "sed_in_place leaves no sibling scratch file" \
  test "$(find "$TMP/sed-in-place" -mindepth 1 ! -name file.conf | wc -l)" -eq 0

# ---------------------------------------------------------------------------
# Small pure helpers
# ---------------------------------------------------------------------------
check "tune_clamp lower bound"  test "$(tune_clamp 5 10 20)" = 10
check "tune_clamp upper bound"  test "$(tune_clamp 50 10 20)" = 20
check "tune_size_value whole GiB" test "$(tune_size_value 2048)" = 2G
check "tune_size_value MiB"       test "$(tune_size_value 1536)" = 1536M
check "mb_to_config whole GiB"    test "$(mb_to_config 4096)" = 4G
check "size_to_mb 2g"             test "$(size_to_mb 2g)" = 2048
check "cache budget rounds to 256 MB" test "$(tune_cache_total_mb 7747 19000)" = 768
check "cache budget is stable across small disk changes" \
  test "$(tune_cache_total_mb 7747 19000)" = "$(tune_cache_total_mb 7747 17700)"
check "Valkey size parser handles MB" test "$(valkey_mb_from_config 8192mb)" = 8192
check "Valkey size parser handles GB" test "$(valkey_mb_from_config 8gb)" = 8192
check "Valkey size parser handles raw bytes" test "$(valkey_mb_from_config 1048576)" = 1
check "Valkey size parser rejects an unknown unit" test "$(valkey_mb_from_config 1xb)" = 0

# systemd prints "● unit.service ..." in --failed output; the run-log header
# must contain the unit names, not a list of bullets.
check "failed unit parser strips the systemd bullet" \
  test "$(printf '● logrotate.service loaded failed failed Rotate log files\n' | failed_unit_names)" = "logrotate.service"
check "failed unit parser keeps older output without a bullet" \
  test "$(printf 'nginx.service loaded failed failed A high performance web server\n' | failed_unit_names)" = "nginx.service"
check "failed unit parser strips ANSI colour" \
  test "$(printf '\033[1;31m●\033[0m logrotate.service loaded failed failed Rotate log files\n' | failed_unit_names)" = "logrotate.service"

# A lower ipfrag high mark is rejected while the old low mark is above it.
# The generated block must write the low mark first.
ipfrag_block=$(ipfrag_sysctl_lines 2047616 1535712)
check "ipfrag tuning writes the low mark first" \
  test "$(printf '%s\n' "$ipfrag_block" | head -n1)" = "net.ipv4.ipfrag_low_thresh = 1535712"
check "ipfrag tuning writes the high mark second" \
  test "$(printf '%s\n' "$ipfrag_block" | tail -n1)" = "net.ipv4.ipfrag_high_thresh = 2047616"

# The live TCP pool is always migrated; there is no opt-out switch.
php_body=$(sed -n '/^optimize_php_services()/,/^}/p' "$ROOT/setup.sh")
check "optimize always calls the PHP socket migration" \
  grep -qF 'migrate_php_pool_to_socket "$ver" "$listen_path"' <<<"$php_body"
check "PHP socket migration has no opt-out environment guard" \
  bash -c '! grep -q "SETUP_OPTIMIZE_MIGRATE_PHP_SOCKET" "$1"' _ "$ROOT/setup.sh"
migrate_body=$(sed -n '/^migrate_php_pool_to_socket()/,/^}/p' "$ROOT/setup.sh")
check "socket migration restarts PHP when reload cannot apply it" \
  grep -qF 'systemctl restart "php${ver}-fpm"' <<<"$migrate_body"
check "failed socket migration is not silently downgraded" \
  bash -c '! grep -q "return 2" <<< "$1"' _ "$migrate_body"

# Cron ownership repair.  Releases before 1.8.34 wrote a nightly
# `chown -R /var/www/` that also flattened the shared log tree; the managed
# block must replace it without touching unrelated operator entries.
check "safe cron chown excludes backups and log files" \
  cron_contains "$CRON_WWW_CHOWN" '/var/www/mysql_database'
check "safe cron chown excludes log files" \
  cron_contains "$CRON_WWW_CHOWN" '*.log'
stripped_cron=$(printf '%s\n' \
  '0 0 * * * /usr/bin/mysqlcheck -Aos --auto-repair' \
  '1 1 * * * /etc/nginx/scripts/cloudflare.sh' \
  '2 2 * * * /bin/true' | cron_strip_legacy_jobs)
check "legacy mysqlcheck cron is stripped" \
  cron_not_contains "$stripped_cron" '/usr/bin/mysqlcheck'
check "legacy nginx cloudflare cron is stripped" \
  cron_not_contains "$stripped_cron" '/etc/nginx/scripts/cloudflare.sh'
check "cron strip preserves unrelated entries" \
  cron_contains "$stripped_cron" '/bin/true'

# MariaDB logging must be part of both the installer block and the optimize
# drop-in, otherwise old hosts keep slow logging off forever.
check "MariaDB logging helper enables the slow log" \
  test "$(mariadb_logging_settings | grep -c '^slow_query_log = 1$')" -eq 1
check "MariaDB logging helper sets the central slow log" \
  test "$(mariadb_logging_settings | grep -c '^slow_query_log_file = /var/www/logs/mariadb/slow.log$')" -eq 1
check "MariaDB logging helper sets log_error" \
  test "$(mariadb_logging_settings | grep -c '^log_error = /var/www/logs/mariadb/error.log$')" -eq 1
no_slow_admin_alias() { ! mariadb_logging_settings | grep -q '^log_slow_admin_statements[[:space:]]*='; }
check "MariaDB logging helper omits the deprecated slow-admin alias" \
  no_slow_admin_alias

# Disk classification must follow the device that actually backs /var/www.
findmnt() { printf '%s\n' "${FINDMNT_SRC:-/dev/null}"; }
lsblk() { printf '%s\n' "${LSBLK_OUT:-}"; }
LSBLK_OUT=$'nvme0n1p4 part\n└─nvme0n1 disk'
check "storage class follows the mounted NVMe parent" \
  test "$(storage_backing_class /var/www)" = nvme
LSBLK_OUT=$'sda1 part\n└─sda disk'
check "storage class reports hdd for a spinning parent" \
  test "$(storage_backing_class /var/www)" = hdd
unset -f findmnt lsblk

# Older releases wrote performance directives bare in 50-server.cnf, without
# the managed markers.  Once the 99- drop-in exists, all of them must leave
# 50-server.cnf while base settings remain.
cat > "$TMP/50-server.cnf" <<'EOF'
[mysqld]
max_connections = 1500
innodb_log_buffer_size = 2047M
innodb_log_file_size = 5120M
innodb_buffer_pool_size = 20480M
tmp_table_size = 256M
skip_name_resolve = 1
# BEGIN setup.sh managed mariadb
[mariadbd]
innodb_io_capacity = 3000
log_slow_admin_statements = 1
bind-address = 127.0.0.1
# END setup.sh managed mariadb
EOF
mariadb_strip_install_block 16351 1500 "$TMP/50-server.cnf" >/dev/null 2>&1
check "legacy bare max_connections is removed from 50-server" \
  bash -c "! grep -q '^max_connections[[:space:]]*=' '$TMP/50-server.cnf'"
check "legacy bare InnoDB sizes are removed from 50-server" \
  bash -c "! grep -qE '^(innodb_log_buffer_size|innodb_log_file_size|innodb_buffer_pool_size|innodb_io_capacity)[[:space:]]*=' '$TMP/50-server.cnf'"
check "legacy bare tmp_table_size is removed from 50-server" \
  bash -c "! grep -q '^tmp_table_size[[:space:]]*=' '$TMP/50-server.cnf'"
check "deprecated log_slow_admin_statements is removed from 50-server" \
  bash -c "! grep -q '^log_slow_admin_statements[[:space:]]*=' '$TMP/50-server.cnf'"
check "base MariaDB settings stay in 50-server" \
  grep -qx 'skip_name_resolve = 1' "$TMP/50-server.cnf"
check "managed base MariaDB settings stay in 50-server" \
  grep -qx 'bind-address = 127.0.0.1' "$TMP/50-server.cnf"
check "managed MariaDB markers are preserved" \
  grep -qx '# BEGIN setup.sh managed mariadb' "$TMP/50-server.cnf"
mariadb_hash=$(md5sum "$TMP/50-server.cnf" | awk '{print $1}')
mariadb_strip_install_block 16351 1500 "$TMP/50-server.cnf" >/dev/null 2>&1
check "MariaDB legacy-key cleanup is idempotent" \
  test "$mariadb_hash" = "$(md5sum "$TMP/50-server.cnf" | awk '{print $1}')"

# A heap-only operator JVM file is safe to replace with the managed file; a
# richer file must be preserved (with a warning from write_es_jvm_options).
printf -- '-Xms4g\n-Xmx4g\n' > "$TMP/heap-only.options"
printf -- '-Xms4g\n-Xmx4g\n-XX:MaxDirectMemorySize=1g\n' > "$TMP/custom.options"
check "heap-only JVM options are detected" \
  es_jvm_options_is_heap_only "$TMP/heap-only.options"
not_heap_only() { ! es_jvm_options_is_heap_only "$1"; }
check "custom JVM options are not treated as heap-only" \
  not_heap_only "$TMP/custom.options"

# A --basic-only run must regenerate installed service entries even when the
# managed block is gone (for example after --purge basic).  Fake crontab and
# package checks keep the test off the real host state.
CRON_IN="$TMP/cron-in"
CRON_OUT="$TMP/cron-out"
fake_crontab() {
  if [[ ${1:-} == -l ]]; then
    cat "$CRON_IN" 2>/dev/null || true
  else
    cat "$1" > "$CRON_OUT"
  fi
}
: > "$CRON_IN"
(
  cron_angie_configured() { return 0; }
  cron_mariadb_configured() { return 0; }
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "basic-only cron run restores installed service entries" \
  grep -q 'mysqlbkup' "$CRON_OUT"
check "basic-only cron run restores the log-safe chown" \
  grep -qF -- "$CRON_WWW_CHOWN" "$CRON_OUT"

cat > "$CRON_IN" <<'EOF'
0 0 * * * /usr/bin/chown www-data:www-data -R /var/www/ >/dev/null 2>&1
1 1 * * * /etc/nginx/scripts/cloudflare.sh
4 4 4 * * /usr/bin/mysqlcheck -Aos --auto-repair
1 1 * * * /bin/true
EOF
(
  cron_angie_configured() { return 0; }
  cron_mariadb_configured() { return 1; }
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "bare legacy chown is removed" \
  cron_not_contains "$(cat "$CRON_OUT")" 'chown www-data:www-data -R /var/www'
check "bare legacy cloudflare path is removed" \
  cron_not_contains "$(cat "$CRON_OUT")" '/etc/nginx/scripts/cloudflare.sh'
check "bare legacy mysqlcheck path is removed" \
  cron_not_contains "$(cat "$CRON_OUT")" '/usr/bin/mysqlcheck'
check "bare legacy chown is replaced by the safe managed line" \
  cron_contains "$(cat "$CRON_OUT")" "$CRON_WWW_CHOWN"
check "unrelated cron entry is preserved" \
  cron_contains "$(cat "$CRON_OUT")" '/bin/true'

cat > "$CRON_IN" <<'EOF'
# BEGIN setup.sh managed cron
0 0 * * * /etc/angie/scripts/cloudflare.sh
3 3 * * * /usr/local/bin/mysqlbkup.sh
# END setup.sh managed cron
EOF
(
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 0; }
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "stale Angie cron entry is dropped" \
  cron_not_contains "$(cat "$CRON_OUT")" '/etc/angie/'
check "MariaDB cron entry is kept" \
  cron_contains "$(cat "$CRON_OUT")" 'mysqlbkup'

# A host with no root crontab at all is the common fresh-install case.  The
# legacy-cron repair must not read an unset `backup` under `set -u`; that
# aborted --optimize before any service was tuned.
: > "$CRON_IN"
empty_cron_repair_ok() {
  (
    cron_angie_configured() { return 0; }
    cron_mariadb_configured() { return 1; }
    crontab() { fake_crontab "$@"; }
    repair_optimize_legacy_cron
  ) >/dev/null 2>&1
}
check "optimize cron repair handles an empty crontab" empty_cron_repair_ok
check "empty-crontab repair still writes the managed block" \
  grep -qF "$CRON_BEGIN" "$CRON_OUT"

# Network profile selection (BBR can regress some proxy hosts).
check "network profile honours SETUP_TCP_CC/SETUP_QDISC" \
  test "$(SETUP_TCP_CC=cubic SETUP_QDISC=fq_codel bash -c 'source "$1"; printf "%s/%s" "$TCP_CC" "$QDISC"' _ "$ROOT/setup.sh")" = "cubic/fq_codel"
check "network profile falls back for unsafe values" \
  test "$(SETUP_TCP_CC='x;y' SETUP_QDISC='a/b' bash -c 'source "$1"; printf "%s/%s" "$TCP_CC" "$QDISC"' _ "$ROOT/setup.sh")" = "bbr/fq"

# MariaDB config diff: only the buffer-pool line may be applied online.
cat > "$TMP/cnf-a" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 1000M
max_connections = 500
EOF
cat > "$TMP/cnf-b" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2000M
max_connections = 500
EOF
cat > "$TMP/cnf-c" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2000M
max_connections = 600
EOF
check "cnf_only_pool_changed accepts a pool-only change" \
  cnf_only_pool_changed "$TMP/cnf-a" "$TMP/cnf-b"
cnf_other_changed() { ! cnf_only_pool_changed "$1" "$2"; }
check "cnf_only_pool_changed rejects other setting changes" \
  cnf_other_changed "$TMP/cnf-a" "$TMP/cnf-c"
check "Angie-only cache budget uses 50% RAM" \
  test "$(tune_cache_total_mb 7747 59000 50 10)" = 3840
check "Angie+PHP cache budget uses 30% RAM" \
  test "$(tune_cache_total_mb 7747 59000 30 5)" = 2304

# The shared helper must produce the same number the real tuner uses.
OPT_DETECTED=(angie)
check "Angie-only cache budget uses 50% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 1792
OPT_DETECTED=(angie php:8.5)
check "Angie+PHP cache budget uses 30% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 1024
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
check "full-stack cache budget uses 25% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 768
OPT_DETECTED=()
check "no detected services uses the shared 25% default" \
  test "$(angie_cache_budget_mb 3815 57000)" = 768

# ---------------------------------------------------------------------------
# PHP-FPM pool log paths
# ---------------------------------------------------------------------------
ensure_fpm_log_path "$TMP/fpm/logs/www-slow.log" www-data www-data
check "ensure_fpm_log_path creates the missing parent directory" \
  test -d "$TMP/fpm/logs"
check "ensure_fpm_log_path creates the slowlog file" \
  test -f "$TMP/fpm/logs/www-slow.log"
ensure_fpm_log_path "$TMP/fpm/logs/\$pool.access.log" www-data www-data
check "ensure_fpm_log_path does not create a literal runtime-variable file" \
  test ! -e "$TMP/fpm/logs/\$pool.access.log"

# ---------------------------------------------------------------------------
# PHP-FPM TCP -> socket migration preconditions
# ---------------------------------------------------------------------------
mkdir -p "$TMP/socket-ok/conf.d" "$TMP/socket-direct/conf.d" "$TMP/socket-off/conf.d"
printf 'fastcgi_pass local_php;\n' > "$TMP/socket-ok/conf.d/site.conf"
printf 'server 127.0.0.1:9000;\n' > "$TMP/socket-ok/angie.conf"
check "socket migration allowed for the local_php upstream" \
  angie_uses_local_php_upstream "$TMP/socket-ok"
printf 'fastcgi_pass 127.0.0.1:9000;\n' > "$TMP/socket-direct/conf.d/site.conf"
printf 'fastcgi_pass local_php;\n' > "$TMP/socket-direct/conf.d/other.conf"
socket_migration_refused() { ! angie_uses_local_php_upstream "$1"; }
check "socket migration refused for a direct fastcgi_pass" \
  socket_migration_refused "$TMP/socket-direct"
printf 'fastcgi_pass local_php;\nfastcgi_next_upstream off;\n' > "$TMP/socket-off/conf.d/site.conf"
check "socket migration refused when next_upstream is off" \
  socket_migration_refused "$TMP/socket-off"

# ---------------------------------------------------------------------------
# SSH/firewall helpers
# ---------------------------------------------------------------------------
check "SSH peer parser uses the client column, not the server address" \
  test "$(printf 'ESTAB 0 0 10.0.0.5:22 203.0.113.9:54321\n' | ssh_peer_from_ss ':22$')" = \
       "203.0.113.9"
# `ss -tnH state established` on Ubuntu 26.04 omits the State column, so the
# same parser must work with four fields as well.
check "SSH peer parser handles ss output without a state column" \
  test "$(printf '0 0 10.0.0.5:22 203.0.113.9:54321\n' | ssh_peer_from_ss ':22$')" = \
       "203.0.113.9"
check "SSH peer parser ignores non-SSH local ports" \
  test -z "$(printf 'ESTAB 0 0 10.0.0.5:443 198.51.100.7:40000\n' | ssh_peer_from_ss ':22$')"
check "SSH peer parser handles bracketed IPv6 peers" \
  test "$(printf 'ESTAB 0 0 [2001:db8::5]:22 [2001:db8::9]:54321\n' | ssh_peer_from_ss ':22$')" = \
       "2001:db8::9"
check "SSH peer parser drops loopback peers" \
  test -z "$(printf 'ESTAB 0 0 10.0.0.5:22 127.0.0.1:5000\n' | ssh_peer_from_ss ':22$')"

ssh_ports_ok() {
  local p n=0
  while IFS= read -r p; do
    [[ $p =~ ^[0-9]+$ ]] || return 1
    n=$((n + 1))
  done < <(sshd_listen_ports)
  (( n > 0 ))
}
check "sshd port discovery always returns at least one numeric port" ssh_ports_ok

# SSH must be rate-limited by UFW, and an older plain ALLOW rule must be
# removed so it cannot shadow the LIMIT rule.
ufw_body=$(sed -n '/^configure_ufw()/,/^}/p' "$ROOT/setup.sh")
check "UFW inserts a rate-limited SSH rule" \
  grep -q 'insert 1 limit' <<<"$ufw_body"
check "UFW removes a plain SSH allow rule" \
  grep -q 'delete allow' <<<"$ufw_body"

# The probe must agree with sysfs; a VM that only offers powersave/schedutil
# must not make --optimize claim it set the performance governor.
gov_dir=/sys/devices/system/cpu/cpu0/cpufreq
if [[ -d $gov_dir ]] && grep -qw performance "$gov_dir/scaling_available_governors" 2>/dev/null; then
  check "CPU governor probe finds the performance governor" \
    cpu_performance_governor_available
elif [[ -d $gov_dir ]]; then
  if cpu_performance_governor_available; then
    t_fail "CPU governor probe ignores an unavailable performance governor"
  else
    t_pass "CPU governor probe ignores an unavailable performance governor"
  fi
else
  if cpu_performance_governor_available; then
    t_fail "CPU governor probe reports performance without a cpufreq interface"
  else
    t_pass "CPU governor probe reports no cpufreq interface"
  fi
fi

# The single-file fallback must stay byte-identical to the canonical profile,
# otherwise a run without configs/ silently writes values we already removed
# (for example the boot-time route.flush errors).
check "embedded sysctl fallback matches configs/system/sysctl.conf" \
  diff -q <(blob_sysctl) "$ROOT/configs/system/sysctl.conf"

# ---------------------------------------------------------------------------
# Optimize OS gate and fd-limit profile
# ---------------------------------------------------------------------------
check "optimize supports Ubuntu 22.04" optimize_os_supported 22.04
check "optimize supports Ubuntu 24.04" optimize_os_supported 24.04
check "optimize supports Ubuntu 26.04" optimize_os_supported 26.04
if optimize_os_supported 20.04; then
  t_fail "optimize rejects Ubuntu 20.04"
else
  t_pass "optimize rejects Ubuntu 20.04"
fi
check "PAM nofile does not exceed the minimum fs.nr_open" \
  bash -c "! grep -q '10485760' '$ROOT/configs/system/limits.conf'"

# ---------------------------------------------------------------------------
# tune_replace / tune_insert_after reporting
# ---------------------------------------------------------------------------
printf 'listen.owner = www-data\n' > "$TMP/pool.conf"
tune_reset_changes
tune_replace "$TMP/pool.conf" 'listen\.owner = www-data' 'listen.owner = nginx' "test replace"
check "tune_replace rewrites a matching directive" \
  grep -qx 'listen.owner = nginx' "$TMP/pool.conf"
check "tune_replace marks configuration dirty" test "$TUNE_DIRTY" -eq 1
check "tune_replace records the change" test "${#TUNE_CHANGES[@]}" -eq 1

tune_reset_changes
tune_replace "$TMP/pool.conf" 'absent_directive = [0-9]+' 'absent_directive = 1' "missing test"
check "tune_replace records a miss instead of failing silently" \
  test "${#TUNE_MISSES[@]}" -eq 1
check "a miss does not mark configuration dirty" test "$TUNE_DIRTY" -eq 0

tune_reset_changes
tune_replace "$TMP/does-not-exist.conf" 'x = 1' 'x = 2' "missing file test"
check "tune_replace records a missing file as a miss" \
  test "${#TUNE_MISSES[@]}" -eq 1

check "tune_first_file prefers the current file name" \
  test "$(mkdir -p "$TMP/pick" && : > "$TMP/pick/fastcgi_cache.conf" && : > "$TMP/pick/fastcgi_cache_conf" && tune_first_file "$TMP/pick" fastcgi_cache.conf fastcgi_cache_conf)" = \
       "$TMP/pick/fastcgi_cache.conf"
mv "$TMP/pick/fastcgi_cache.conf" "$TMP/pick/fastcgi_cache.conf.hidden"
check "tune_first_file falls back to the legacy _conf layout" \
  test "$(tune_first_file "$TMP/pick" fastcgi_cache.conf fastcgi_cache_conf)" = \
       "$TMP/pick/fastcgi_cache_conf"

# ---------------------------------------------------------------------------
# tune_insert_after anchors on the block opener
# ---------------------------------------------------------------------------
printf 'http2 on;\nhttp {\n}\n' > "$TMP/anchor.conf"
tune_reset_changes
tune_insert_after "$TMP/anchor.conf" '^[[:space:]]*http[[:space:]]*[{]' \
  '  client_body_buffer_size 256k;' "test insert"
check "tune_insert_after inserts after the http block opener" \
  test "$(awk '/^http \{/{getline; print}' "$TMP/anchor.conf")" = \
       '  client_body_buffer_size 256k;'
check "tune_insert_after leaves http2 on intact" \
  grep -qx 'http2 on;' "$TMP/anchor.conf"

# ---------------------------------------------------------------------------
# Error-response cache policy (applies to old installs during --optimize)
# ---------------------------------------------------------------------------
cat > "$TMP/cache-policy.conf" <<'EOF'
fastcgi_cache_valid any 5s;
fastcgi_cache_use_stale error timeout updating http_500 http_503;
EOF
tune_reset_changes
tune_cache_error_policy "$TMP/cache-policy.conf" "test cache"
check "error policy removes http_500 from use_stale" \
  bash -c "! grep -q 'http_500' '$TMP/cache-policy.conf'"
check "error policy keeps http_503 stale handling" \
  grep -q 'http_503' "$TMP/cache-policy.conf"
check "error policy disables caching of 5xx responses" \
  grep -qx 'fastcgi_cache_valid 500 502 503 504 0s;' "$TMP/cache-policy.conf"
check "error policy records the change" test "${#TUNE_CHANGES[@]}" -eq 1

tune_reset_changes
tune_cache_error_policy "$TMP/cache-policy.conf" "test cache"
check "error policy is idempotent" test "${#TUNE_CHANGES[@]}" -eq 0
check "error policy keeps a single 5xx rule" \
  test "$(grep -c 'fastcgi_cache_valid 500' "$TMP/cache-policy.conf")" -eq 1

# ---------------------------------------------------------------------------
# XenForo guest-cache key (style and language variation)
# ---------------------------------------------------------------------------
cat > "$TMP/xf-cache.conf" <<'EOF'
fastcgi_cache_key       "$request_method$scheme$host$request_uri$cookie_xf_style_variation";
fastcgi_cache_lock      on;
fastcgi_cache_use_stale error timeout invalid_header updating http_503;
EOF
tune_reset_changes
tune_xf_cache_vary "$TMP/xf-cache.conf"
check "XF cache key includes the style id" \
  grep -q '\$cookie_xf_style_id' "$TMP/xf-cache.conf"
check "XF cache key includes the language id" \
  grep -q '\$cookie_xf_language_id' "$TMP/xf-cache.conf"
check "XF cache key keeps the style variation" \
  grep -q '\$cookie_xf_style_variation' "$TMP/xf-cache.conf"
check "XF cache refreshes in the background" \
  grep -qx 'fastcgi_cache_background_update on;' "$TMP/xf-cache.conf"
check "XF cache repair is idempotent" \
  test "$(grep -c 'fastcgi_cache_key' "$TMP/xf-cache.conf")" -eq 1

tune_reset_changes
tune_xf_cache_vary "$TMP/xf-cache.conf"
check "XF cache repair records no second change" test "${#TUNE_CHANGES[@]}" -eq 0

# Static assets get one immutable, 30-day location block.
printf '    ### End Xenforo\n' > "$TMP/xf2.conf"
tune_reset_changes
tune_xf_static_assets "$TMP/xf2.conf"
check "XF static assets get a 30-day immutable cache" \
  grep -q 'public, immutable' "$TMP/xf2.conf"
check "XF static asset repair is idempotent" \
  test "$(grep -c 'static asset cache' "$TMP/xf2.conf")" -eq 1
tune_reset_changes
tune_xf_static_assets "$TMP/xf2.conf"
check "XF static asset repair records no second change" test "${#TUNE_CHANGES[@]}" -eq 0

# ---------------------------------------------------------------------------
# FastCGI snippet and server-level index repair (pretty URLs)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/fcgi-repair"
cat > "$TMP/fcgi-repair/fastcgi-php.conf" <<'EOF'
fastcgi_split_path_info ^(.+?\.php)(/.*)$;
try_files $fastcgi_script_name =404;
EOF
tune_reset_changes
tune_fastcgi_snippet "$TMP/fcgi-repair/fastcgi-php.conf"
check "FastCGI snippet makes PATH_INFO optional" \
  grep -qF 'fastcgi_split_path_info ^(.+?\.php)(/.*)?$;' "$TMP/fcgi-repair/fastcgi-php.conf"
check "FastCGI snippet keeps the try_files test" \
  grep -qF 'try_files $fastcgi_script_name =404;' "$TMP/fcgi-repair/fastcgi-php.conf"
check "FastCGI snippet repair marks configuration dirty" \
  test "$TUNE_DIRTY" -eq 1
tune_reset_changes
tune_fastcgi_snippet "$TMP/fcgi-repair/fastcgi-php.conf"
check "FastCGI snippet repair is idempotent" test "$TUNE_DIRTY" -eq 0

mkdir -p "$TMP/index-repair"
cat > "$TMP/index-repair/wordpress.conf" <<'EOF'
location / {
  try_files $uri $uri/ /index.php?$args;
}
EOF
tune_reset_changes
tune_ensure_index "$TMP/index-repair/wordpress.conf"
check "WordPress include gains a server-level index" \
  test "$(head -n1 "$TMP/index-repair/wordpress.conf")" = 'index index.php index.html;'
check "index repair marks configuration dirty" test "$TUNE_DIRTY" -eq 1
tune_reset_changes
tune_ensure_index "$TMP/index-repair/wordpress.conf"
check "index repair is idempotent" test "$TUNE_DIRTY" -eq 0

printf 'index index.php index.html;\nlocation / {}\n' > "$TMP/index-repair/polr.conf"
tune_reset_changes
tune_ensure_index "$TMP/index-repair/polr.conf"
check "existing index is left untouched" test "$TUNE_DIRTY" -eq 0

# ---------------------------------------------------------------------------
# Angie tuning against the repository fixture
# ---------------------------------------------------------------------------
mkdir -p "$TMP/angie"
cp -a "$FIXTURES/." "$TMP/angie/"
OPT_PHP_OK=1
OPT_PHP_SOCKET=/run/php/php-fpm.sock
OPT_DETECTED=(angie php:8.3 mariadb valkey elastic)
tune_reset_changes
tune_angie_configs "$TMP/angie"

check "angie.conf FastCGI upstream moves to the shared socket" \
  grep -q 'server unix:/run/php/php-fpm.sock;' "$TMP/angie/angie.conf"
check "angie.conf keeps exactly one client_body_buffer_size" \
  test "$(grep -c '^[[:space:]]*client_body_buffer_size' "$TMP/angie/angie.conf")" -eq 1
mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
if (( mem_kb < 2048 * 1024 )); then
  exp_body_buffer=64k
elif (( mem_kb < 8192 * 1024 )); then
  exp_body_buffer=128k
else
  exp_body_buffer=256k
fi
check "client_body_buffer_size is inside the http block and sized for RAM" \
  test "$(awk '/^http \{/{getline; print}' "$TMP/angie/angie.conf")" = \
       "  client_body_buffer_size ${exp_body_buffer};"
check "worker_rlimit_nofile is inserted after worker_processes" \
  test "$(awk '/^worker_processes/{getline; print}' "$TMP/angie/angie.conf")" = \
       "$(grep 'worker_rlimit_nofile' "$TMP/angie/angie.conf")"

# Multi-line proxy_cache_path directives must have their max_size rewritten.
if grep -q 'max_size=16g' "$TMP/angie/http.d/proxy_cache.conf"; then
  t_fail "proxy_cache.conf max_size is updated on continuation lines"
else
  t_pass "proxy_cache.conf max_size is updated on continuation lines"
fi
check "proxy_cache.conf keeps both cache paths" \
  test "$(grep -c '^proxy_cache_path' "$TMP/angie/http.d/proxy_cache.conf")" -eq 2
check "fastcgi_cache zone is resized" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/angie/http.d/fastcgi_cache.conf"
check "fastcgi_cache_chev gains a max_size" \
  grep -qE 'keys_zone=fastcgicache_chev:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/angie/http.d/fastcgi_cache_chev.conf"
check "tuning preserves use_temp_path=off on the FastCGI cache" \
  grep -q 'use_temp_path=off' "$TMP/angie/http.d/fastcgi_cache.conf"
check "tuning preserves use_temp_path=off on the XenForo proxy cache" \
  grep -q 'use_temp_path=off' "$TMP/angie/http.d/xf_proxy_cache.conf"
check "PHP fastcgi buffers are tuned" \
  grep -qE '^fastcgi_busy_buffers_size [0-9]+[mk];' "$TMP/angie/h5bp/php.conf"

# A second identical run must not report any changes (idempotency).
tune_reset_changes
tune_angie_configs "$TMP/angie"
check "second tune run is a no-op" test "$TUNE_DIRTY" -eq 0

# A pool that stays on TCP must leave Angie's TCP upstream alone.
mkdir -p "$TMP/angie-tcp"
cp -a "$FIXTURES/." "$TMP/angie-tcp/"
OPT_PHP_SOCKET=""
tune_reset_changes
tune_angie_configs "$TMP/angie-tcp"
check "TCP FastCGI upstream is preserved when PHP stays on TCP" \
  grep -q '^[[:space:]]*server 127.0.0.1:9000;' "$TMP/angie-tcp/angie.conf"

# An active .conf file must win over an inert _conf leftover with the same zone.
mkdir -p "$TMP/active"
cp -a "$FIXTURES/." "$TMP/active/"
cat > "$TMP/active/http.d/fastcgi_cache.conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache_test levels=1:2 keys_zone=fastcgicache:256m inactive=8h;
EOF
cat > "$TMP/active/http.d/fastcgi_cache_conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache_test levels=1:2 keys_zone=fastcgicache:256m max_size=16g inactive=1h;
EOF
OPT_PHP_SOCKET=""
tune_reset_changes
tune_angie_configs "$TMP/active"
check "active fastcgi_cache.conf gains a max_size" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+M' \
  "$TMP/active/http.d/fastcgi_cache.conf"
check "inert legacy fastcgi_cache_conf is left untouched" \
  grep -q 'max_size=16g' "$TMP/active/http.d/fastcgi_cache_conf"

# ---------------------------------------------------------------------------
# Legacy underscore layouts (older server-configs-nginx deployments)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/legacy"
cp -a "$FIXTURES/." "$TMP/legacy/"
for name in fastcgi_cache fastcgi_cache_chev xf_proxy_cache proxy_cache limit_req; do
  mv "$TMP/legacy/http.d/${name}.conf" "$TMP/legacy/http.d/${name}_conf"
done
sed_in_place 's#include http.d/\*\.conf;#include http.d/*_conf;#' "$TMP/legacy/angie.conf"
cat > "$TMP/legacy/http.d/fastcgi_cache_custom_conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache_custom levels=1:2 keys_zone=customcache:5120m inactive=30d;
EOF
cat > "$TMP/legacy/http.d/proxy_cache_extra_conf" <<'EOF'
proxy_cache_path /home/proxy_extra levels=1:2 keys_zone=extracache:128m max_size=512g inactive=30d;
EOF
tune_reset_changes
tune_angie_configs "$TMP/legacy"
check "legacy fastcgi_cache_conf is resized in place" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/legacy/http.d/fastcgi_cache_conf"
check "legacy limit_req_conf zones are resized in place" \
  grep -qE 'zone=limit_req_post_head:[0-9]+m' "$TMP/legacy/http.d/limit_req_conf"
check "legacy tuning does not create a duplicate .conf file" \
  test ! -e "$TMP/legacy/http.d/fastcgi_cache.conf"
custom_zone=$(grep -oE 'keys_zone=customcache:[0-9]+m' \
  "$TMP/legacy/http.d/fastcgi_cache_custom_conf" | head -n1 | sed 's/.*://; s/m$//')
check "custom 5G cache zone is capped" test "$custom_zone" -le 128
check "custom unbounded cache gains a max_size" \
  grep -qE 'keys_zone=customcache:[0-9]+m .*max_size=[0-9]+M' \
  "$TMP/legacy/http.d/fastcgi_cache_custom_conf"
extra_max=$(grep -oE 'max_size=[0-9]+[mM]' \
  "$TMP/legacy/http.d/proxy_cache_extra_conf" | head -n1 | sed 's/.*=//; s/[mM]$//')
check "custom proxy cache max_size is capped" test "$extra_max" -le 1024
tune_reset_changes
tune_angie_configs "$TMP/legacy"
check "legacy layout second run is a no-op" test "$TUNE_DIRTY" -eq 0

# A host with only one active cache type gets the whole cache budget.
cache_mem_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
cache_disk_mb=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || true)
[[ $cache_disk_mb =~ ^[0-9]+$ ]] || cache_disk_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[[ $cache_disk_mb =~ ^[0-9]+$ ]] || cache_disk_mb=10240
expected_cache_angie=$(tune_cache_total_mb "$cache_mem_mb" "$cache_disk_mb" 50 10)
expected_cache_php=$(tune_cache_total_mb "$cache_mem_mb" "$cache_disk_mb" 30 5)

mkdir -p "$TMP/xfonly/disabled"
cp -a "$FIXTURES/." "$TMP/xfonly/"
mv "$TMP/xfonly/http.d/fastcgi_cache.conf" \
   "$TMP/xfonly/http.d/fastcgi_cache_chev.conf" \
   "$TMP/xfonly/http.d/proxy_cache.conf" \
   "$TMP/xfonly/http.d/limit_req.conf" "$TMP/xfonly/disabled/"
OPT_PHP_SOCKET=""
OPT_DETECTED=(angie)
tune_reset_changes
tune_angie_configs "$TMP/xfonly"
check "proxy-only host gives the whole Angie-only budget to xfproxycache" \
  grep -q "max_size=$(tune_size_value "$expected_cache_angie")" \
  "$TMP/xfonly/http.d/xf_proxy_cache.conf"

mkdir -p "$TMP/fcgionly/disabled"
cp -a "$FIXTURES/." "$TMP/fcgionly/"
mv "$TMP/fcgionly/http.d/fastcgi_cache_chev.conf" \
   "$TMP/fcgionly/http.d/proxy_cache.conf" \
   "$TMP/fcgionly/http.d/xf_proxy_cache.conf" \
   "$TMP/fcgionly/http.d/limit_req.conf" "$TMP/fcgionly/disabled/"
OPT_PHP_SOCKET=""
OPT_DETECTED=(angie php:8.3)
tune_reset_changes
tune_angie_configs "$TMP/fcgionly"
check "PHP-only host gives the whole Angie+PHP budget to fastcgicache" \
  grep -q "max_size=$(tune_size_value "$expected_cache_php")" \
  "$TMP/fcgionly/http.d/fastcgi_cache.conf"

# ---------------------------------------------------------------------------
# PHP pool helpers
# ---------------------------------------------------------------------------
cat > "$TMP/www.conf" <<'EOF'
[www]
pm.max_children = 5
rlimit_files = 1024
pm.max_children = 9
EOF
tune_reset_changes
tune_pool_set "$TMP/www.conf" pm.max_children 64 "test pool set"
check "tune_pool_set writes the new value" \
  grep -qx 'pm.max_children = 64' "$TMP/www.conf"
tune_pool_dedupe "$TMP/www.conf" pm.max_children rlimit_files
check "tune_pool_dedupe keeps one pm.max_children" \
  test "$(grep -c '^pm.max_children' "$TMP/www.conf")" -eq 1
check "tune_pool_dedupe keeps the value set by tune_pool_set" \
  grep -qx 'pm.max_children = 64' "$TMP/www.conf"

# --optimize must keep the managed ini performance-only by default.  The
# 1.8.39 global session hardening broke Joomla/Polr logins, so session and
# cgi hardening is behind an explicit opt-in flag.
php_tune_body=$(sed -n '/^tune_php_fpm_version()/,/^}/p' "$ROOT/setup.sh")
php_tune_default=$(awk '/SETUP_PHP_SESSION_HARDENING:-0} == 1/{exit} {print}' <<<"$php_tune_body")
php_tune_hardening=$(awk '/SETUP_PHP_SESSION_HARDENING:-0} == 1/{f=1} f' <<<"$php_tune_body")

check "PHP optimize keeps the performance block" \
  grep -q '^memory_limit = ${memory_mb}M$' <<<"$php_tune_body"
check "default PHP tuning writes no session overrides" \
  test -z "$(grep '^session\.' <<<"$php_tune_default")"
check "default PHP tuning writes no cgi/expose hardening" \
  test -z "$(grep -E '^(cgi\.fix_pathinfo|expose_php|display_errors|log_errors) ' <<<"$php_tune_default")"
check "session hardening is gated behind the opt-in flag" \
  grep -qF 'SETUP_PHP_SESSION_HARDENING:-0} == 1' <<<"$php_tune_body"
check "the shipped PHP template has no global session overrides" \
  test -z "$(grep '^session\.' "$ROOT/configs/php/custom_dan.ini")"

# --optimize refreshes a stale managed php.ini from the repo template while
# keeping the host's existing timezone.
mkdir -p "$TMP/php-ini"
cat > "$TMP/php-ini/template.ini" <<'EOF'
memory_limit = 512M
allow_url_fopen = Off
date.timezone = Asia/Manila
EOF
cat > "$TMP/php-ini/custom_dan.ini" <<'EOF'
memory_limit = 2048M
allow_url_fopen = Off
disable_functions = php_uname,curl_exec
date.timezone = Africa/Dar_es_Salaam
EOF
tune_reset_changes
sync_php_ini_template 8.3 "$TMP/php-ini/custom_dan.ini" "$TMP/php-ini/template.ini"
check "PHP optimize refreshes a stale custom_dan.ini" \
  grep -q '^memory_limit = 512M$' "$TMP/php-ini/custom_dan.ini"
check "PHP optimize removes stale disable_functions" \
  test -z "$(grep '^disable_functions' "$TMP/php-ini/custom_dan.ini")"
check "PHP optimize preserves the host timezone" \
  grep -qx 'date.timezone = Africa/Dar_es_Salaam' "$TMP/php-ini/custom_dan.ini"
check "custom_dan refresh marks configuration dirty" test "$TUNE_DIRTY" -eq 1
tune_reset_changes
sync_php_ini_template 8.3 "$TMP/php-ini/custom_dan.ini" "$TMP/php-ini/template.ini"
check "custom_dan refresh is idempotent" test "$TUNE_DIRTY" -eq 0

# An old template that still carries cgi.fix_pathinfo=0 must not be installed
# when the opt-in hardening is disabled.
cat > "$TMP/php-ini/cgi-template.ini" <<'EOF'
memory_limit = 512M
cgi.fix_pathinfo = 0
date.timezone = Asia/Manila
EOF
cat > "$TMP/php-ini/cgi-custom.ini" <<'EOF'
memory_limit = 2048M
cgi.fix_pathinfo = 0
date.timezone = Africa/Dar_es_Salaam
EOF
tune_reset_changes
sync_php_ini_template 8.3 "$TMP/php-ini/cgi-custom.ini" "$TMP/php-ini/cgi-template.ini"
check "custom_dan refresh drops global cgi.fix_pathinfo" \
  test -z "$(grep '^cgi\.fix_pathinfo' "$TMP/php-ini/cgi-custom.ini")"
check "custom_dan refresh keeps the performance block" \
  grep -qx 'memory_limit = 512M' "$TMP/php-ini/cgi-custom.ini"

check "--optimize calls the custom_dan refresh" \
  grep -q 'sync_php_ini_template "$ver"' \
  <<<"$(sed -n '/^optimize_php_services()/,/^}/p' "$ROOT/setup.sh")"

check "default PHP template leaves cgi.fix_pathinfo unset" \
  test -z "$(grep '^cgi\.fix_pathinfo' "$ROOT/configs/php/custom_dan.ini")"

# cgi.fix_pathinfo=0 makes PHP-FPM prefer PATH_TRANSLATED.  The deployed
# includes must point it at the script, not at the empty path_info.
mkdir -p "$TMP/path-translated"
cat > "$TMP/path-translated/php_wp.conf" <<'EOF'
location ~ [^/]\.php(/|$) {
fastcgi_param HTTP_PROXY "";
fastcgi_param PATH_TRANSLATED $document_root$fastcgi_path_info;
}
EOF
tune_reset_changes
tune_fastcgi_path_translated "$TMP/path-translated/php_wp.conf"
check "PATH_TRANSLATED points at the PHP script" \
  grep -qF 'fastcgi_param PATH_TRANSLATED $document_root$fastcgi_script_name;' \
  "$TMP/path-translated/php_wp.conf"
check "PATH_TRANSLATED repair marks configuration dirty" \
  test "$TUNE_DIRTY" -eq 1
tune_reset_changes
tune_fastcgi_path_translated "$TMP/path-translated/php_wp.conf"
check "PATH_TRANSLATED repair is idempotent" test "$TUNE_DIRTY" -eq 0

check "--optimize repairs PATH_TRANSLATED in the PHP includes" \
  grep -q 'tune_fastcgi_path_translated_all "$target"' \
  <<<"$(sed -n '/^tune_angie_configs()/,/^}/p' "$ROOT/setup.sh")"

# Every php*.conf include is covered, including XenForo and future variants.
mkdir -p "$TMP/path-translated-all/h5bp"
for f in php.conf php_xf.conf php_xf_proxy.conf php_wp.conf php_future.conf; do
  printf 'fastcgi_param PATH_TRANSLATED $document_root$fastcgi_path_info;\n' \
    > "$TMP/path-translated-all/h5bp/$f"
done
printf '# no PHP location here\n' > "$TMP/path-translated-all/h5bp/notes.conf"
tune_reset_changes
tune_fastcgi_path_translated_all "$TMP/path-translated-all"
for f in php.conf php_xf.conf php_xf_proxy.conf php_wp.conf php_future.conf; do
  check "PATH_TRANSLATED repaired in ${f}" \
    grep -qF 'fastcgi_param PATH_TRANSLATED $document_root$fastcgi_script_name;' \
    "$TMP/path-translated-all/h5bp/$f"
done
check "PATH_TRANSLATED repair ignores unrelated includes" \
  grep -qF '# no PHP location here' "$TMP/path-translated-all/h5bp/notes.conf"
check "PATH_TRANSLATED repair covers all PHP includes" \
  test "${#TUNE_CHANGES[@]}" -eq 5
tune_reset_changes
tune_fastcgi_path_translated_all "$TMP/path-translated-all"
check "all-include PATH_TRANSLATED repair is idempotent" test "$TUNE_DIRTY" -eq 0

check "opt-in hardening disables cgi.fix_pathinfo" \
  grep -q '^cgi.fix_pathinfo = 0$' <<<"$php_tune_hardening"
check "opt-in hardening disables expose_php" \
  grep -q '^expose_php = Off$' <<<"$php_tune_hardening"
check "opt-in hardening disables display_errors" \
  grep -q '^display_errors = Off$' <<<"$php_tune_hardening"
check "opt-in hardening enables error logging" \
  grep -q '^log_errors = On$' <<<"$php_tune_hardening"
check "opt-in hardening points error_log at the central tree" \
  grep -qF 'error_log = ${php_error_log}' <<<"$php_tune_hardening"
check "opt-in hardening enables strict sessions" \
  grep -q '^session.use_strict_mode = 1$' <<<"$php_tune_hardening"
check "opt-in hardening restricts sessions to cookies" \
  grep -q '^session.use_only_cookies = 1$' <<<"$php_tune_hardening"
check "opt-in hardening marks cookies HttpOnly" \
  grep -q '^session.cookie_httponly = 1$' <<<"$php_tune_hardening"
check "opt-in hardening marks cookies Secure" \
  grep -q '^session.cookie_secure = 1$' <<<"$php_tune_hardening"
check "opt-in hardening sets SameSite=Lax" \
  grep -q '^session.cookie_samesite = Lax$' <<<"$php_tune_hardening"
check "opt-in hardening sets a bounded session lifetime" \
  grep -q '^session.gc_maxlifetime = 14400$' <<<"$php_tune_hardening"
check "opt-in hardening lengthens session IDs" \
  grep -q '^session.sid_length = 48$' <<<"$php_tune_hardening"
check "opt-in hardening uses six bits per session character" \
  grep -q '^session.sid_bits_per_character = 6$' <<<"$php_tune_hardening"
check "opt-in hardening creates the central PHP error log" \
  grep -qF 'ensure_fpm_log_path "$php_error_log"' <<<"$php_tune_hardening"

# ---------------------------------------------------------------------------
# Shared memory budget
# ---------------------------------------------------------------------------
# Keep these tests independent of any PHP-FPM pool that happens to run on the
# machine executing the suite; the real helper measures the live pool and the
# 96 MB default is the fresh-install path asserted below.
php_primary_version() { printf '8.4'; }
php_worker_allowance_mb() { printf '96'; }
mem_total_mb() { printf '131072'; }
mariadb_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "PHP budget is at most 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 131072 * 50 / 100 ))
check "service budgets stay under 95% of RAM" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 131072 * 95 / 100 ))
check "all fixed budgets are positive" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0 -a "$OPT_VALKEY_BUDGET_MB" -gt 0 -a "$OPT_ES_BUDGET_MB" -gt 0

# A 64 GB host with a 128-worker PHP pool must keep that capacity; the data
# services are fitted into what remains after the PHP reservation.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
plan_memory_budget
check "PHP budget preserves a 128-worker pool" \
  test "$OPT_PHP_BUDGET_MB" -ge $(( 128 * 96 ))
check "PHP budget is still capped at 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 65536 * 50 / 100 ))
check "Redis enables the shared cache budget" \
  test "$OPT_VALKEY_BUDGET_MB" -gt 0
check "PHP-first plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# The planner must use the same 8-worker floor as tune_php_fpm_version().
php_pool_max_children() { printf '6'; }
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.3 mariadb)
plan_memory_budget
check "PHP budget uses the 8-worker floor" \
  test "$OPT_PHP_BUDGET_MB" -eq 768
check "MariaDB gets the remaining budget after the PHP floor" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0

# Restore the 128-worker context used by the database/index cases below.
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# The buffer pool should hold the live data+index working set when possible.
mariadb_data_size_mb() { printf '20000'; }
plan_memory_budget
check "buffer pool covers a 20 GB database" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 20000
check "database-fit plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# A freshly installed database can be only a few MB.  Keep the 1/16-RAM floor
# (capped at 8 GB) and let the empty database grow into spare budget up to
# RAM/4, exactly like the fresh-install plan, so the first --optimize cannot
# shrink what the installer sized.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '81'; }
elasticsearch_data_size_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "tiny fresh database keeps the hardware-scaled floor" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 8192
check "tiny fresh database may use spare budget up to RAM/4" \
  test "$OPT_MARIADB_BUDGET_MB" -le $(( 262144 / 4 ))
check "tiny database floor stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Restore the 64 GB context for the oversized-database cases below.
mem_total_mb() { printf '65536'; }
mariadb_current_pool_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# A database larger than the remaining budget gets the largest feasible pool.
mariadb_data_size_mb() { printf '40960'; }
plan_memory_budget
check "oversized database gets the budget-limited buffer pool" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 20000 -a "$OPT_MARIADB_BUDGET_MB" -lt 34000
check "oversized database is not falsely reported as fitting" \
  test "$OPT_DB_SIZE_MB" -eq 40960 -a "$OPT_MARIADB_BUDGET_MB" -lt 40960

# On a large host the pool follows the live working set plus 5% headroom.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '73728'; }
mariadb_data_size_mb() { printf '73599'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey)
plan_memory_budget
check "large host sizes the pool to data+5%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278
check "data-sized pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0
check "data-sized pool keeps the plan inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Tiny statistics drift must not change the planned size on every run.
mariadb_current_pool_mb() { printf '77300'; }
plan_memory_budget
check "small statistics drift keeps the live pool" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77300

# An oversized live pool is reduced to the data-sized target.
mariadb_current_pool_mb() { printf '120000'; }
plan_memory_budget
check "oversized live pool is reduced to data+5%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278
check "shrunk pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0

# A pool that would exceed the shared budget is capped.
mariadb_current_pool_mb() { printf '200000'; }
plan_memory_budget
check "pool above the shared budget is capped to the target" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278

# A database larger than the shared budget receives the capped pool.
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '300000'; }
plan_memory_budget
check "database larger than the shared budget is capped" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 189235
check "capped data-sized plan still fits the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# A MariaDB-only host reserves no PHP budget; a database larger than 80% of
# RAM can use the whole usable budget, while the data+5% target still applies.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '60000'; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only host reserves no PHP budget" \
  test "$OPT_PHP_BUDGET_MB" -eq 0
check "MariaDB-only large database can use the full 80% budget" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 52428

# Unknown data size (query failed) falls back to the larger MariaDB-only share.
mariadb_data_size_mb() { printf ''; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only unknown data falls back to 80% RAM" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 52428

# Valkey gets a larger share when no database/search tier shares the host.
mariadb_data_size_mb() { printf '0'; }
OPT_DETECTED=(valkey)
plan_memory_budget
check "Valkey-only budget uses 50% of RAM" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 32768
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 valkey)
plan_memory_budget
check "Angie+PHP+Valkey budget uses 25% of RAM" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 16384

# Elasticsearch-only fallback when the index size cannot be measured.
elasticsearch_data_size_mb() { printf ''; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(elastic)
plan_memory_budget
check "Elasticsearch-only unknown index falls back to 50% RAM" \
  test "$OPT_ES_BUDGET_MB" -eq 31744

# A reachable but empty cluster is a measurement, not a failure: start from a
# RAM-scaled floor (total/16, 512 MB..4 GB) and give the spare budget to the
# only consumer.  This host is 64 GB, so the 50% heap cap applies.
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(elastic)
plan_memory_budget
check "measured empty Elasticsearch-only host keeps the 50% heap" \
  test "$OPT_ES_BUDGET_MB" -eq 31744

mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '20000'; }
php_pool_max_children() { printf '128'; }
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# Elasticsearch heap follows the live index store size.
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '0'; }
plan_memory_budget
check "small Elasticsearch index uses index+5%" \
  test "$OPT_ES_BUDGET_MB" -eq 4608
check "Elasticsearch index size is recorded" \
  test "$OPT_ES_SIZE_MB" -eq 4096

elasticsearch_data_size_mb() { printf '20000'; }
plan_memory_budget
check "large Elasticsearch index gets index+5% headroom" \
  test "$OPT_ES_BUDGET_MB" -eq 21504
check "Elasticsearch heap fits the 20 GB index" \
  test "$OPT_ES_BUDGET_MB" -ge 20000
check "Elasticsearch plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# A huge index is capped at the 31 GB compressed-oops ceiling.
mem_total_mb() { printf '262144'; }
OPT_DETECTED=(angie php:8.4 elastic)
elasticsearch_data_size_mb() { printf '100000'; }
plan_memory_budget
check "Elasticsearch heap is capped at 31 GB" \
  test "$OPT_ES_BUDGET_MB" -eq 31744
check "Elasticsearch index size is recorded for huge stores" \
  test "$OPT_ES_SIZE_MB" -eq 100000

# An oversized live heap is reduced to the data-sized target.
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '13000'; }
elasticsearch_current_heap_mb() { printf '20000'; }
plan_memory_budget
check "oversized Elasticsearch heap is reduced to index+5%" \
  test "$OPT_ES_BUDGET_MB" -eq 13824
check "shrunk Elasticsearch heap is not marked as preserved" \
  test "$OPT_ES_KEPT_MB" -eq 0

# Small statistics drift must not change the heap on every run.
elasticsearch_current_heap_mb() { printf '14000'; }
plan_memory_budget
check "Elasticsearch statistics drift keeps the live heap" \
  test "$OPT_ES_BUDGET_MB" -eq 14000

# A heap that would exceed the shared budget is capped.
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
mariadb_data_size_mb() { printf '40000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '30000'; }
plan_memory_budget
check "Elasticsearch heap above the shared budget is capped" \
  test "$OPT_ES_BUDGET_MB" -eq 4608

elasticsearch_current_heap_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
mariadb_data_size_mb() { printf '20000'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# ---------------------------------------------------------------------------
# Install / --optimize parity
# ---------------------------------------------------------------------------
# A fresh install must reserve the same PHP budget as --optimize does on the
# host it just built; otherwise the database/search tiers are sized from two
# different numbers (and the heap changes on the first --optimize run).
nproc() { printf '16'; }
mem_total_mb() { printf '27812'; }
php_pool_max_children() { printf '144'; }
php_worker_allowance_mb() { printf '64'; }
php_primary_version() { printf '8.5'; }
mariadb_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }

ENABLED=([angie]=1 [php]=1 [mariadb]=1 [valkey]=1 [elastic]=1)
plan_install_budget
install_php_budget=$OPT_PHP_BUDGET_MB
install_children=$OPT_PHP_CHILDREN
install_es_budget=$OPT_ES_BUDGET_MB
check "install plan derives the same worker count as the tuner" \
  test "$install_children" -eq 144
check "install plan reserves 64 MB per fresh worker, not 96 MB" \
  test "$install_php_budget" -eq $(( 144 * 64 ))

# The same host, now sized by --optimize after the install ran (live pool of
# 144 workers measured at the 64 MB floor).
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget
check "install and --optimize reserve the same PHP budget" \
  test "$OPT_PHP_BUDGET_MB" -eq "$install_php_budget"
check "install and --optimize use the same worker count" \
  test "$OPT_PHP_CHILDREN" -eq "$install_children"
check "install and --optimize round the heap the same way" \
  test "$OPT_ES_BUDGET_MB" -eq "$install_es_budget"
check "Elasticsearch heap is a 512 MB multiple" \
  test $(( install_es_budget % 512 )) -eq 0

# ---------------------------------------------------------------------------
# Single-node Elasticsearch replica detection
# ---------------------------------------------------------------------------
check "single-node yellow replica issue is detected" \
  elasticsearch_single_node_replica_issue \
    '{"status":"yellow","number_of_nodes":1,"unassigned_shards":1,"unassigned_primary_shards":0}'
if elasticsearch_single_node_replica_issue \
     '{"status":"green","number_of_nodes":1,"unassigned_shards":0,"unassigned_primary_shards":0}'; then
  t_fail "green cluster is not treated as a replica issue"
else
  t_pass "green cluster is not treated as a replica issue"
fi
if elasticsearch_single_node_replica_issue \
     '{"status":"yellow","number_of_nodes":2,"unassigned_shards":1,"unassigned_primary_shards":0}'; then
  t_fail "multi-node yellow cluster is not auto-modified"
else
  t_pass "multi-node yellow cluster is not auto-modified"
fi
if elasticsearch_single_node_replica_issue \
     '{"status":"yellow","number_of_nodes":1,"unassigned_shards":1,"unassigned_primary_shards":1}'; then
  t_fail "unassigned primary shard is not treated as a replica issue"
else
  t_pass "unassigned primary shard is not treated as a replica issue"
fi

# ---------------------------------------------------------------------------
# Elasticsearch HTTP endpoint resolution
# ---------------------------------------------------------------------------
# A node intentionally bound to a public IPv4 for a remote XenForo client must
# be probed on that address, not 127.0.0.1.
cat > "$TMP/es-http-public.yml" <<'EOF'
network.host: 192.0.2.10
http.port: 9200
EOF
check "Elasticsearch HTTP URL uses a public IPv4 network.host" \
  test "$(elasticsearch_http_url "$TMP/es-http-public.yml")" = "http://192.0.2.10:9200"

cat > "$TMP/es-http-quoted.yml" <<'EOF'
network.host: "192.0.2.10" # remote client
http.port: "9201"
EOF
check "Elasticsearch HTTP URL strips quotes, comments and honours http.port" \
  test "$(elasticsearch_http_url "$TMP/es-http-quoted.yml")" = "http://192.0.2.10:9201"

cat > "$TMP/es-http-explicit.yml" <<'EOF'
http.host: 127.0.0.1
network.host: 192.0.2.10
EOF
check "Elasticsearch HTTP URL prefers an explicit http.host" \
  test "$(elasticsearch_http_url "$TMP/es-http-explicit.yml")" = "http://127.0.0.1:9200"

cat > "$TMP/es-http-commented.yml" <<'EOF'
# http.host: 127.0.0.1
network.host: 192.0.2.10
EOF
check "Elasticsearch HTTP URL ignores a commented http.host" \
  test "$(elasticsearch_http_url "$TMP/es-http-commented.yml")" = "http://192.0.2.10:9200"

cat > "$TMP/es-http-wildcard.yml" <<'EOF'
http.host: 0.0.0.0
network.host: 192.0.2.10
EOF
check "Elasticsearch wildcard HTTP bind probes loopback" \
  test "$(elasticsearch_http_url "$TMP/es-http-wildcard.yml")" = "http://127.0.0.1:9200"

cat > "$TMP/es-http-ipv6.yml" <<'EOF'
network.host: 2a01:4f8:221:1be1::2
EOF
check "Elasticsearch HTTP URL brackets an IPv6 host" \
  test "$(elasticsearch_http_url "$TMP/es-http-ipv6.yml")" = "http://[2a01:4f8:221:1be1::2]:9200"

# ---------------------------------------------------------------------------
# WordPress vhost detection
# ---------------------------------------------------------------------------
mkdir -p "$TMP/wpangie/conf.d" "$TMP/wpangie/h5bp" "$TMP/wpangie/www/site/public"
: > "$TMP/wpangie/www/site/public/wp-config.php"
printf 'server {\n  root %s;\n  include h5bp/php_wp.conf;\n}\n' \
  "$TMP/wpangie/www/site/public" > "$TMP/wpangie/conf.d/site.conf"
check "WordPress vhost detection finds a real installation" \
  test "$(angie_wordpress_vhosts "$TMP/wpangie")" = "$TMP/wpangie/conf.d/site.conf"
mv "$TMP/wpangie/www/site/public/wp-config.php" \
   "$TMP/wpangie/www/site/public/wp-config.php.hidden"
check "WordPress vhost detection ignores a missing wp-config" \
  test -z "$(angie_wordpress_vhosts "$TMP/wpangie")"

# ---------------------------------------------------------------------------
# WordPress / XenForo persistent-connection audit
# ---------------------------------------------------------------------------
cat > "$TMP/wp-config.php" <<'EOF'
<?php
define( 'DB_HOST', 'localhost' );
define( 'WP_REDIS_PATH', '/run/valkey/valkey.sock' );
define( 'WP_REDIS_PERSISTENT', true );
EOF
cat > "$TMP/xf-config.php" <<'EOF'
<?php
$config['db']['host'] = 'p:localhost';
$config['cache']['config']['host'] = '/run/valkey/valkey.sock';
$config['cache']['config']['port'] = 0;
EOF
check "WordPress DB host parser" \
  test "$(wp_db_host_from_config "$TMP/wp-config.php")" = localhost
check "WordPress Valkey path parser" \
  test "$(wp_redis_path_from_config "$TMP/wp-config.php")" = /run/valkey/valkey.sock
check "WordPress persistent flag parser" wp_redis_persistent_from_config "$TMP/wp-config.php"
check "XenForo DB host parser" \
  test "$(xf_db_host_from_config "$TMP/xf-config.php")" = p:localhost
check "XenForo cache host parser" \
  test "$(xf_cache_host_from_config "$TMP/xf-config.php")" = /run/valkey/valkey.sock
check "XenForo cache port parser" \
  test "$(xf_cache_port_from_config "$TMP/xf-config.php")" = 0
check "Unix socket detector accepts a Valkey socket" \
  app_is_socket_path /run/valkey/valkey.sock
tcp_not_socket() { ! app_is_socket_path 127.0.0.1; }
check "Unix socket detector rejects TCP" tcp_not_socket

app_find_wordpress_configs() { printf '%s\n' "$TMP/wp-config.php"; }
app_find_xenforo_configs() { :; }
app_cache_socket_hint() { printf '/run/valkey/valkey.sock'; }
OPT_REPORT=()
audit_app_persistent_connections
check "audit reports a non-persistent MariaDB host" \
  grep -q 'is not persistent' <<<"${OPT_REPORT[*]}"
check "audit recognizes a persistent Valkey socket" \
  grep -q 'with persistent connections' <<<"${OPT_REPORT[*]}"
check "audit counts the MariaDB notice" \
  test "$APP_CONNECTION_ISSUES" -eq 1

opt_body=$(sed -n '/^optimize_angie()/,/^}/p' "$ROOT/setup.sh")
check "optimize_angie synchronizes the Angie repository" \
  grep -q 'sync_angie_repo_configs' <<<"$opt_body"
sync_body=$(sed -n '/^sync_angie_repo_configs()/,/^}/p' "$ROOT/setup.sh")
check "Angie sync deploys the tree itself (deployer merged into setup.sh)" \
  grep -q 'deploy_angie_tree' <<<"$sync_body"
check "setup.sh no longer shells out to the repository nginx_conf.sh" \
  bash -c '! grep -q "nginx_conf.sh" "$1"' _ "$ROOT/setup.sh"
check "--sync-angie runs the same optimize pipeline as --optimize" \
  bash -c 'sed -n "/--sync-angie)/,/;;/p" "$1" | grep -q "OPTIMIZE=1"' _ "$ROOT/setup.sh"
run_body=$(sed -n '/^run_optimize()/,/^}/p' "$ROOT/setup.sh")
check "run_optimize calls the application connection audit" \
  grep -q 'audit_app_persistent_connections' <<<"$run_body"
audit_line=$(printf '%s\n' "$run_body" | grep -n 'audit_app_persistent_connections' | head -n1 | cut -d: -f1)
report_line=$(printf '%s\n' "$run_body" | grep -n 'write_optimize_report' | tail -n1 | cut -d: -f1)
check "application notices are added before the report is written" \
  test -n "$audit_line" -a -n "$report_line" -a "$audit_line" -lt "$report_line"

# ---------------------------------------------------------------------------
# Managed Elasticsearch heap file
# ---------------------------------------------------------------------------
cat > "$TMP/es-managed.options" <<'EOF'
-Xms8192m
-Xmx8192m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+HeapDumpOnOutOfMemoryError
-Dlog4j2.formatMsgNoLookups=true
EOF
check "es_jvm_options_is_managed accepts the generated heap file" \
  es_jvm_options_is_managed "$TMP/es-managed.options"
printf -- '-Xms1g\n-Xmx1g\n' > "$TMP/es-operator.options"
es_operator_refused() { ! es_jvm_options_is_managed "$1"; }
check "es_jvm_options_is_managed ignores a minimal operator file" \
  es_operator_refused "$TMP/es-operator.options"
{ cat "$TMP/es-managed.options"; printf -- '-Xmn1g\n'; } > "$TMP/es-mixed.options"
check "es_jvm_options_is_managed ignores a file with extra JVM flags" \
  es_operator_refused "$TMP/es-mixed.options"

mkdir -p "$TMP/esopt"
cp "$TMP/es-managed.options" "$TMP/esopt/jvm.options"
write_es_jvm_options 2048 "$TMP/esopt"
check "write_es_jvm_options writes the managed heap file" \
  grep -qx -- '-Xmx2048m' "$TMP/esopt/zz-setup-optimize.options"
check "write_es_jvm_options moves the legacy managed heap file out of the config directory" \
  test ! -e "$TMP/esopt/jvm.options"
printf -- '-Xms1g\n-Xmx1g\n' > "$TMP/esopt/jvm.options"
write_es_jvm_options 2048 "$TMP/esopt"
check "write_es_jvm_options preserves an operator heap file" \
  test -f "$TMP/esopt/jvm.options"

# ---------------------------------------------------------------------------
# sysctl duplicate keys
# ---------------------------------------------------------------------------
cat > "$TMP/sysctl.conf" <<'EOF'
# managed base profile
net.core.somaxconn = 524280
vm.swappiness = 10
net.core.somaxconn = 12288
# security
net.ipv4.tcp_challenge_ack_limit = 1000
vm.swappiness = 10
EOF
sysctl_dedupe_keys "$TMP/sysctl.conf"
check "sysctl dedupe keeps the last value" \
  grep -qx 'net.core.somaxconn = 12288' "$TMP/sysctl.conf"
check "sysctl dedupe keeps one definition per key" \
  test "$(grep -c '^net.core.somaxconn' "$TMP/sysctl.conf")" -eq 1
check "sysctl dedupe preserves comments" grep -qx '# security' "$TMP/sysctl.conf"
before_hash=$(md5sum "$TMP/sysctl.conf" | awk '{print $1}')
sysctl_dedupe_keys "$TMP/sysctl.conf"
check "sysctl dedupe is idempotent" \
  test "$before_hash" = "$(md5sum "$TMP/sysctl.conf" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Inert cache/limit files under http.d
# ---------------------------------------------------------------------------
mkdir -p "$TMP/inert/http.d"
printf 'include http.d/*.conf;\n' > "$TMP/inert/angie.conf"
printf 'fastcgi_cache_path /tmp levels=1:2 keys_zone=live:1m;\n' \
  > "$TMP/inert/http.d/fastcgi_cache.conf"
printf 'fastcgi_cache_path /tmp levels=1:2 keys_zone=legacy:1m;\n' \
  > "$TMP/inert/http.d/fastcgi_cache_conf"
printf 'limit_req_zone $binary_remote_addr zone=legacy:1m rate=1r/s;\n' \
  > "$TMP/inert/http.d/limit_req_conf"
printf 'map $http_user_agent $x { default 0; }\n' > "$TMP/inert/http.d/map.conf"
check "inert detection reports only non-included cache/limit files" \
  test "$(angie_inert_cache_files "$TMP/inert" | sort | paste -sd, -)" = \
       "$TMP/inert/http.d/fastcgi_cache_conf,$TMP/inert/http.d/limit_req_conf"

# ---------------------------------------------------------------------------
# Cache objects written during a restart window
# ---------------------------------------------------------------------------
mkdir -p "$TMP/cachetree/http.d" "$TMP/cache/sub"
printf 'include http.d/*.conf;\n' > "$TMP/cachetree/angie.conf"
printf 'fastcgi_cache_path %s levels=1:2 keys_zone=live:1m;\n' "$TMP/cache" \
  > "$TMP/cachetree/http.d/fastcgi_cache.conf"
printf 'proxy_cache_path %s/proxy levels=1:2 keys_zone=px:1m;\n' "$TMP/cache" \
  > "$TMP/cachetree/http.d/proxy_cache.conf"
check "angie_cache_dirs returns the included cache paths" \
  test "$(angie_cache_dirs "$TMP/cachetree" | sort | paste -sd, -)" = \
       "$TMP/cache,$TMP/cache/proxy"
: > "$TMP/cache/old"
touch -d '1 hour ago' "$TMP/cache/old"
now=$(date +%s)
sleep 1
: > "$TMP/cache/sub/new"
removed=$(count_optimize_cache_entries "$now" "$TMP/cachetree")
check "cache report counts objects written during the run" test "$removed" -eq 1
check "cache report leaves the new object in place" test -f "$TMP/cache/sub/new"
check "cache report keeps older objects" test -f "$TMP/cache/old"

# ---------------------------------------------------------------------------
# Live disk-cache safety: never shrink max_size below current usage
# ---------------------------------------------------------------------------
mkdir -p "$TMP/cache-keep/objects"
dd if=/dev/zero of="$TMP/cache-keep/objects/obj" bs=1M count=5 status=none
cat > "$TMP/cache-keep/fastcgi_cache.conf" <<EOF
fastcgi_cache_path $TMP/cache-keep/objects levels=1:2 keys_zone=fastcgicache:16m inactive=1h;
EOF
angie_cache_keep_mb "$TMP/cache-keep/fastcgi_cache.conf" 2
check "cache max_size is raised above live usage" test "$ANGIE_CACHE_MB" = 256
check "cache keep records an explanatory note" test -n "$ANGIE_CACHE_NOTE"
angie_cache_keep_mb "$TMP/cache-keep/fastcgi_cache.conf" 512
check "cache max_size keeps a larger plan" test "$ANGIE_CACHE_MB" = 512
check "cache keep is silent when the plan is larger" test -z "$ANGIE_CACHE_NOTE"
cat > "$TMP/cache-keep/fastcgi_cache.conf" <<EOF
fastcgi_cache_path $TMP/cache-keep/objects levels=1:2 keys_zone=fastcgicache:16m max_size=1g inactive=1h;
EOF
angie_cache_keep_mb "$TMP/cache-keep/fastcgi_cache.conf" 2
check "cache max_size keeps a configured value above live usage" test "$ANGIE_CACHE_MB" = 1024
angie_cache_keep_mb "$TMP/cache-keep/missing.conf" 128
check "cache keep tolerates a missing config" test "$ANGIE_CACHE_MB" = 128

# ---------------------------------------------------------------------------
# Small-host budget floors
# ---------------------------------------------------------------------------
mem_total_mb() { printf '1024'; }
php_pool_max_children() { printf '8'; }
mariadb_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.3 mariadb valkey elastic)
plan_memory_budget
check "small host keeps the 256 MB cache floor" test "$OPT_VALKEY_BUDGET_MB" -ge 256
check "small host keeps the 512 MB search floor" test "$OPT_ES_BUDGET_MB" -ge 512
OPT_DETECTED=(angie)
plan_memory_budget
check "a host without cache/search keeps a zero budget" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 0 -a "$OPT_ES_BUDGET_MB" -eq 0

# ---------------------------------------------------------------------------
# Failure diagnostics and OS-tuning order
# ---------------------------------------------------------------------------
err_out=$(bash -c 'set -E; source "$1"; trap - ERR; trap "on_error $LINENO" ERR; false' _ "$ROOT/setup.sh" 2>&1 || true)
check "ERR trap reports the failing command" grep -q 'false' <<<"$err_out"
check "ERR trap reports the failing line" grep -qE 'line [0-9]+' <<<"$err_out"

tuning_body=$(sed -n '/^run_os_tuning()/,/^}/p' "$ROOT/setup.sh")
sysctl_line=$(printf '%s\n' "$tuning_body" | grep -n 'configure_sysctl' | head -n1 | cut -d: -f1)
limits_line=$(printf '%s\n' "$tuning_body" | grep -n 'configure_limits' | head -n1 | cut -d: -f1)
check "OS tuning applies sysctl before the PAM nofile limits" \
  test -n "$sysctl_line" -a -n "$limits_line" -a "$sysctl_line" -lt "$limits_line"

# MariaDB restart must pause the request tiers first, and apply unit changes
# before stopping them.
mariadb_body=$(sed -n '/^optimize_mariadb()/,/^}/p' "$ROOT/setup.sh")
pause_line=$(printf '%s\n' "$mariadb_body" | grep -n 'opt_pause_web_frontends' | head -n1 | cut -d: -f1)
resume_line=$(printf '%s\n' "$mariadb_body" | grep -n 'opt_resume_web_frontends' | head -n1 | cut -d: -f1)
restart_line=$(printf '%s\n' "$mariadb_body" | grep -n 'systemctl restart mariadb' | head -n1 | cut -d: -f1)
daemon_line=$(printf '%s\n' "$mariadb_body" | grep -n 'systemctl daemon-reload' | head -n1 | cut -d: -f1)
check "MariaDB restart pauses web frontends first" \
  test -n "$pause_line" -a -n "$restart_line" -a "$pause_line" -lt "$restart_line"
check "MariaDB restart resumes web frontends afterwards" \
  test -n "$resume_line" -a -n "$restart_line" -a "$restart_line" -lt "$resume_line"
check "MariaDB restart reloads systemd units before pausing web" \
  test -n "$daemon_line" -a -n "$pause_line" -a "$daemon_line" -lt "$pause_line"

# --restart-all must preserve the dependency order: stop Angie/PHP, restart
# cache/search, restart MariaDB, wait for SQL, then start PHP and Angie.
restart_body=$(sed -n '/^run_restart_all()/,/^}/p' "$ROOT/setup.sh")
ra_daemon=$(printf '%s\n' "$restart_body" | grep -n 'systemctl daemon-reload' | head -n1 | cut -d: -f1)
ra_stop_angie=$(printf '%s\n' "$restart_body" | grep -n 'systemctl stop angie' | head -n1 | cut -d: -f1)
ra_stop_php=$(printf '%s\n' "$restart_body" | grep -n 'systemctl stop "\$unit"' | head -n1 | cut -d: -f1)
ra_restart_cache=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart "\$unit"' | head -n1 | cut -d: -f1)
ra_restart_es=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart elasticsearch' | head -n1 | cut -d: -f1)
ra_restart_db=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart mariadb' | head -n1 | cut -d: -f1)
ra_wait_db=$(printf '%s\n' "$restart_body" | grep -n "mariadb -e 'SELECT 1'" | head -n1 | cut -d: -f1)
ra_start_php=$(printf '%s\n' "$restart_body" | grep -n 'systemctl start "\$unit"' | head -n1 | cut -d: -f1)
ra_start_angie=$(printf '%s\n' "$restart_body" | grep -n 'systemctl start angie' | head -n1 | cut -d: -f1)
ra_wait_es=$(printf '%s\n' "$restart_body" | grep -n 'Elasticsearch did not answer HTTP' | head -n1 | cut -d: -f1)
check "restart-all reloads systemd before stopping Angie" \
  test -n "$ra_daemon" -a -n "$ra_stop_angie" -a "$ra_daemon" -lt "$ra_stop_angie"
check "restart-all stops Angie before PHP-FPM" \
  test -n "$ra_stop_angie" -a -n "$ra_stop_php" -a "$ra_stop_angie" -lt "$ra_stop_php"
check "restart-all restarts cache/search before MariaDB" \
  test -n "$ra_restart_cache" -a -n "$ra_restart_es" -a -n "$ra_restart_db" \
       -a "$ra_restart_cache" -lt "$ra_restart_db" -a "$ra_restart_es" -lt "$ra_restart_db"
check "restart-all waits for Elasticsearch before MariaDB" \
  test -n "$ra_restart_es" -a -n "$ra_wait_es" -a -n "$ra_restart_db" \
       -a "$ra_restart_es" -lt "$ra_wait_es" -a "$ra_wait_es" -lt "$ra_restart_db"
check "restart-all waits for MariaDB before starting PHP" \
  test -n "$ra_restart_db" -a -n "$ra_wait_db" -a -n "$ra_start_php" \
       -a "$ra_restart_db" -lt "$ra_wait_db" -a "$ra_wait_db" -lt "$ra_start_php"
check "restart-all starts PHP before Angie" \
  test -n "$ra_start_php" -a -n "$ra_start_angie" -a "$ra_start_php" -lt "$ra_start_angie"

# ---------------------------------------------------------------------------
# Embedded payload integrity
# ---------------------------------------------------------------------------
for blob in blob_sysctl blob_mysqltuner blob_mysqlbackup \
            blob_angie_key blob_elastic_key blob_sury_deb blob_nodesource_key; do
  check "embedded ${blob} decodes" \
    bash -c 'source "$1"; "$2" >/dev/null' _ "$ROOT/setup.sh" "$blob"
done

# ---------------------------------------------------------------------------
# Shared install/--optimize tuning helpers
# ---------------------------------------------------------------------------
mariadb_compute_profile 2048
check "MariaDB shared profile sizes a 2G buffer pool" \
  test "$MARIADB_PROFILE_BUFFER" = 2G
check "MariaDB shared profile caps the log at 512M" \
  test "$MARIADB_PROFILE_LOG_SIZE" = 512M
check "MariaDB shared profile keeps a usable connection ceiling" \
  bash -c "(( $MARIADB_PROFILE_MAX_CONN >= 200 && $MARIADB_PROFILE_MAX_CONN <= 2000 ))"

valkey_lines=$(valkey_tuning_lines 512 allkeys-lru 2)
check "Valkey shared lines keep maxmemory and policy" \
  grep -qx 'maxmemory 512mb' <<<"$valkey_lines"
check "Valkey shared lines keep the io-threads override" \
  grep -qx 'io-threads 2' <<<"$valkey_lines"

printf '# BEGIN setup.sh optimize\nbootstrap.memory_lock: true\n# END setup.sh optimize\ncluster.name: keep\n' \
  > "$TMP/es-strip.yml"
elasticsearch_strip_managed "$TMP/es-strip.yml"
check "Elasticsearch strip removes only the optimize block" \
  grep -qx 'cluster.name: keep' "$TMP/es-strip.yml"
check "Elasticsearch strip removes the old performance key" \
  bash -c "! grep -q '^bootstrap.memory_lock' '$TMP/es-strip.yml'"

# --optimize must not create/resize swap, and Valkey must take precedence over
# Redis so one cache budget is not applied twice.
check "optimize leaves swap untouched" \
  bash -c '! grep -q "configure_swap_auto" <<< "$1"' _ "$tuning_body"
detect_body=$(sed -n '/^detect_installed_services()/,/^}/p' "$ROOT/setup.sh")
check "Valkey takes precedence over Redis in service detection" \
  grep -q '! -f /etc/valkey/valkey.conf' <<<"$detect_body"

# Diagnostics must not present absent services as connection failures.
diag_body=$(sed -n '/^run_diagnostics()/,/^}/p' "$ROOT/setup.sh")
check "diagnostics reports absent Valkey/Redis as not installed" \
  grep -q 'Valkey/Redis is not installed' <<<"$diag_body"
check "diagnostics does not call the Redis client when none is reachable" \
  grep -q 'diag_redis_cli' <<<"$diag_body"
check "diagnostics skips allocation explain when no shards are unassigned" \
  grep -q 'No unassigned shards; allocation explain is not needed' "$ROOT/setup.sh"
check "diagnostics reports absent Elasticsearch as not installed" \
  grep -q 'Elasticsearch is not installed' <<<"$diag_body"
check "diagnostics gates Elasticsearch probes on installation" \
  grep -q 'diag_elasticsearch_installed' <<<"$diag_body"
check "diagnostics gates MariaDB probes on installation" \
  grep -q 'diag_mariadb_installed' <<<"$diag_body"
check "diagnostics reports absent MariaDB as not installed" \
  grep -q 'MariaDB is not installed' <<<"$diag_body"

# ---------------------------------------------------------------------------
# Fresh-install memory plan
# ---------------------------------------------------------------------------
# A fresh full-stack install cannot measure an empty database or index.  The
# planner must use the same empty-data floors as --optimize, otherwise
# Elasticsearch reserves 25% of RAM and MariaDB is left on its 256 MB floor.
mem_total_mb() { printf '27812'; }
nproc() { printf '16'; }
php_pool_max_children() { printf '144'; }
mariadb_data_size_mb() { return 0; }
mariadb_current_pool_mb() { return 0; }
elasticsearch_data_size_mb() { return 0; }
elasticsearch_current_heap_mb() { return 0; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
OPT_INSTALL_PLAN=1
plan_memory_budget
OPT_INSTALL_PLAN=0
check "fresh install keeps MariaDB above the 256 MB floor" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 1738
check "fresh install uses the RAM-scaled empty-index ES floor plus spare" \
  test "$OPT_ES_BUDGET_MB" -eq 3072
check "fresh install spends spare RAM on the empty database" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 1738
check "fresh install full-stack plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 27812 * 80 / 100 ))

# A database that has just been initialised reports a few MB of system data.
# The first --optimize must not mistake that for a populated working set and
# shrink the installer's spare-RAM buffer pool back to the 1/16-RAM floor.
mariadb_data_size_mb() { printf '4'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "measured-empty database keeps the spare-RAM growth budget" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 1738

# An existing server may already allow more than the computed thread*32
# ceiling.  A tune must preserve it instead of rewriting it to 2000.
systemctl() { return 0; }
mariadb() { printf '5000\n'; }
mariadb_compute_profile 4096
check "existing max_connections above 2000 is preserved" \
  test "$MARIADB_PROFILE_MAX_CONN" -eq 5000
unset -f mariadb systemctl

# A database-only host has no competing service, so it must keep the larger
# 80%-of-usable fallback instead of the shared-host floor.
mariadb_data_size_mb() { return 0; }
OPT_DETECTED=(mariadb)
OPT_INSTALL_PLAN=1
plan_memory_budget
OPT_INSTALL_PLAN=0
check "database-only fresh install keeps the large fallback" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 20000

# ---------------------------------------------------------------------------
# --restart-all plan de-duplicates the Valkey unit alias
# ---------------------------------------------------------------------------
systemctl() {
  case "$1 $2 $3" in
    "is-active --quiet valkey-server") return 0 ;;
    "is-active --quiet valkey") return 0 ;;
    *) return 1 ;;
  esac
}
detect_installed_services() { OPT_DETECTED=(angie mariadb valkey); }
list_active_php_units() { return 0; }
plan_out=$(restart_all_plan 2>&1)
active_line=$(sed -n 's/^Active services: *//p' <<<"$plan_out")
check "restart-all plan lists the Valkey alias only once" \
  test "$(grep -o 'valkey' <<<"$active_line" | wc -l | tr -d ' ')" -eq 1

# ---------------------------------------------------------------------------
# Run-log robustness
# ---------------------------------------------------------------------------
run_log_body=$(sed -n '/^start_run_log()/,/^}/p' "$ROOT/setup.sh")
check "run log name is unique per process" \
  grep -Fq 'setup_${stamp}-$$.log' <<<"$run_log_body"
on_error_body=$(sed -n '/^on_error()/,/^}/p' "$ROOT/setup.sh")
check "on_error ignores SIGPIPE from a closed pipe" \
  grep -q 'rc == 141' <<<"$on_error_body"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
