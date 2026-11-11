#!/usr/bin/env bash
# Unit tests for the hardware-aware tuning helpers in setup.sh.
# No root, no services and no system changes are required.
# Usage: bash tests/test-tuning.sh
# The suites assign globals (ENABLED/OPT/...) that the sourced helpers read;
# ShellCheck cannot follow that across the source boundary.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/angie"

PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-tuning.XXXXXX)
# Scratch data stays under /tmp and is allowed to expire there; the tests do
# not remove it, so a failed run remains inspectable.

# Source-level checks read the whole program: setup.sh is a thin driver and
# the implementation lives in lib/*.sh.  Concatenated so a function body can
# be extracted with sed without knowing which module owns it.
ALL_SRC="$TMP/all-source.sh"
cat "$ROOT/setup.sh" "$ROOT"/lib/*.sh > "$ALL_SRC"

# Load the helpers without running main().  Source first: setup.sh defines its
# own ok()/warn() logging helpers, so test helpers must be defined afterwards.
export SETUP_TEST_SOURCE_ONLY=1
# Never read the live host state (/var/lib/setup.sh): a recorded explicit
# --mariadb size= or --valkey ram= would silently change the planner results.
export SETUP_STATE_DIR="$TMP/state"
# Pin the PHP-FPM pool factor for the sizing arithmetic.  The default is
# hardware-derived (1.0 worker per core on a local-DB flash host); the tests
# that exercise the derivation clear this variable themselves.
export SETUP_PHP_WORKERS_PER_CPU=2
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
check "run-log timestamps use UTC" \
  test "$(_timestamp | awk '{print $NF}')" = UTC
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

# --domain app= names: aliases normalise, the default is the basic template.
check "normalize_app: omitted app is basic" test "$(normalize_app '')" = basic
check "normalize_app: blank is an alias of basic" test "$(normalize_app blank)" = basic
check "normalize_app: new templates are accepted" \
  test "$(normalize_app flarum)$(normalize_app shlink)$(normalize_app sfs)" = flarumshlinksfs
not_app() { ! normalize_app "$1" >/dev/null; }
check "normalize_app: unknown app is rejected" not_app bogus

# The managed-tree cleanup must move files out of the way, never unlink them.
mkdir -p "$TMP/retire"
printf 'stale\n' > "$TMP/retire/old.conf"
retire_out=$(retire_paths "$TMP/retire/old.conf" "$TMP/retire/missing.conf" 2>&1)
retire_dest=$(sed -n 's/.*-> \(\/tmp\/[^ ]*\) (not deleted)$/\1/p' <<<"$retire_out" | head -n1)
check "retire_paths moves the live file away" test ! -e "$TMP/retire/old.conf"
check "retire_paths preserves the content under /tmp" \
  test -n "$retire_dest" -a "$(cat "$retire_dest" 2>/dev/null)" = stale
check "retire_paths ignores a missing path" retire_paths "$TMP/retire/missing.conf"
deploy_body=$(sed -n '/^deploy_angie_tree()/,/^}/p' "$ALL_SRC")
check "Angie tree deployer never deletes files" \
  bash -c '! grep -qE "(^|[[:space:]])rm -|-delete([[:space:]]|$)" <<<"$1"' _ "$deploy_body"

# Backup credentials are written verbatim and never pass through a sed
# replacement or a command line.
printf '[mysql]\nuser=dba\npassword=dba_passwd\n\n[mysqldump]\nuser=dba\npassword=dba_passwd\n' \
  > "$TMP/mysqlbkup.cnf.sample"
write_mysqlbkup_credentials "$TMP/mysqlbkup.cnf.sample" 'demo_user' 'p&ss|w/o\rd$1'
check "mysqlbkup credentials: user replaced in both sections" \
  test "$(grep -c '^user=demo_user$' "$TMP/mysqlbkup.cnf.sample")" -eq 2
check "mysqlbkup credentials: special characters written verbatim" \
  test "$(grep -cxF 'password=p&ss|w/o\rd$1' "$TMP/mysqlbkup.cnf.sample")" -eq 2
check "mysqlbkup credentials: no placeholder remains" \
  bash -c '! grep -q "dba" "$1"' _ "$TMP/mysqlbkup.cnf.sample"
bkup_missing_fails() { ! write_mysqlbkup_credentials "$1" u p; }
check "mysqlbkup credentials: missing file is an error" \
  bkup_missing_fails "$TMP/no-such-sample"

# The embedded backup payload decodes to a plain tar (the installer extracts
# it without -z) that carries the upstream files and no macOS AppleDouble
# entries.
blob_listing=$(blob_mysqlbackup 2>/dev/null | tar -tf - 2>/dev/null || true)
check "mysqlbackup payload decodes to a plain tar with mysqlbkup.sh" \
  grep -qx './mysqlbkup.sh' <<<"$blob_listing"
check "mysqlbackup payload carries the installer and both samples" \
  test "$(grep -cE '^\./(install|mysqlbkup\.cnf\.sample|mysqlbkup\.config\.sample)$' <<<"$blob_listing")" -eq 3
check "mysqlbackup payload has no AppleDouble entries" \
  bash -c '! grep -q "/\\._" <<<"$1"' _ "$blob_listing"
check "mysqlbackup installer extracts the payload without -z" \
  grep -qF 'blob_mysqlbackup | tar -xf - -C' "$ALL_SRC"

# The Angie APT key must be scoped to its repository, not globally trusted.
angie_repo_body=$(sed -n '/^configure_angie_repo()/,/^}/p' "$ALL_SRC")
check "Angie repository uses a signed-by keyring" \
  grep -qF 'signed-by=' <<<"$angie_repo_body"

# Secrets must not be passed on a command line.
mariadb_body=$(sed -n '/^install_mariadb()/,/^}/p' "$ALL_SRC")
check "MariaDB account SQL is fed over stdin" \
  bash -c '! grep -qF "mariadb -e \"\$sql\"" <<<"$1"' _ "$mariadb_body"
wp_db_body=$(sed -n '/^harden_wordpress_db()/,/^}/p' "$ALL_SRC")
check "WordPress database password reaches the helper via the environment" \
  grep -qF 'WP_CFG_VALUE="$newpass"' <<<"$wp_db_body"

# The live TCP pool is always migrated.
php_body=$(sed -n '/^optimize_php_services()/,/^}/p' "$ALL_SRC")
check "optimize always calls the PHP socket migration" \
  grep -qF 'migrate_php_pool_to_socket "$ver" "$listen_path"' <<<"$php_body"
migrate_body=$(sed -n '/^migrate_php_pool_to_socket()/,/^}/p' "$ALL_SRC")
check "socket migration restarts PHP when reload cannot apply it" \
  grep -qF 'systemctl restart "php${ver}-fpm"' <<<"$migrate_body"

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
LSBLK_OUT=$'sdzz1 part\n└─sdzz disk'
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

# A managed JVM file (heap plus the fixed GC flags) is recognised; a richer
# operator file must be preserved (with a warning from write_es_jvm_options).
printf -- '-Xms4g\n-Xmx4g\n-XX:+UseG1GC\n-XX:MaxGCPauseMillis=200\n' > "$TMP/managed.options"
printf -- '-Xms4g\n-Xmx4g\n-XX:MaxDirectMemorySize=1g\n' > "$TMP/custom.options"
check "managed JVM options are detected" \
  es_jvm_options_is_managed "$TMP/managed.options"
not_managed() { ! es_jvm_options_is_managed "$1"; }
check "custom JVM options are not treated as managed" \
  not_managed "$TMP/custom.options"

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

# A service selected on the command line but not installed yet must not get a
# cron entry: install_basic calls write_cron before the installers run.  A
# failed or interrupted install would otherwise leave jobs pointing at
# missing binaries and log directories.
: > "$CRON_IN"
: > "$CRON_OUT"
(
  # Simulated command-line selection; write_cron must ignore it.
  # shellcheck disable=SC2034,SC2154
  ENABLED[angie]=1
  # shellcheck disable=SC2034,SC2154
  ENABLED[mariadb]=1
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 1; }
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "selected-but-uninstalled MariaDB gets no cron entry" \
  cron_not_contains "$(cat "$CRON_OUT")" 'mysqlbkup'
check "selected-but-uninstalled Angie gets no cron entry" \
  cron_not_contains "$(cat "$CRON_OUT")" '/etc/angie/'

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

# XenForo job runner: one managed entry while XF_JOB_CRON=1 and a root exists;
# a stale entry is dropped when the option is off or no root remains.
cat > "$CRON_IN" <<'EOF'
# BEGIN setup.sh managed cron
* * * * * /usr/bin/find /var/www -name stale-entry -exec php cmd.php xf:run-jobs \; >/dev/null 2>&1
# END setup.sh managed cron
EOF
(
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 1; }
  app_find_xenforo_configs() { printf '%s\n' /var/www/xf.example/public/src/config.php; }
  command() { if [[ ${1:-} == -v && ${2:-} == php ]]; then return 0; fi; builtin command "$@"; }
  XF_JOB_CRON=1
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "XenForo root gets the managed xf:run-jobs entry every minute" \
  cron_contains "$(cat "$CRON_OUT")" "* * * * * ${CRON_XF_JOBS}"
check "stale xf:run-jobs entry is replaced, not duplicated" \
  test "$(grep -c 'xf:run-jobs' "$CRON_OUT")" = 1
(
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 1; }
  app_find_xenforo_configs() { printf '%s\n' /var/www/xf.example/public/src/config.php; }
  command() { if [[ ${1:-} == -v && ${2:-} == php ]]; then return 0; fi; builtin command "$@"; }
  XF_JOB_CRON=0
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "XF_JOB_CRON=0 drops the xf:run-jobs entry" \
  cron_not_contains "$(cat "$CRON_OUT")" 'xf:run-jobs'
(
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 1; }
  app_find_xenforo_configs() { :; }
  XF_JOB_CRON=1
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "no XenForo root, no xf:run-jobs entry" \
  cron_not_contains "$(cat "$CRON_OUT")" 'xf:run-jobs'
check "CRON_XF_JOBS runs the queue as www-data with a per-run time limit" \
  bash -c '[[ $0 == *"runuser -u www-data -- /usr/bin/php"*"xf:run-jobs --max-execution-time=50"* ]]' "$CRON_XF_JOBS"
check "CRON_XF_JOBS contains no percent sign (crontab newline)" \
  bash -c '[[ $0 != *%* ]]' "$CRON_XF_JOBS"
check "CRON_XF_JOBS skips database dumps, backups and .old copies" \
  bash -c '[[ $0 == *mysql_database* && $0 == *backup* && $0 == *.old* ]]' "$CRON_XF_JOBS"

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

# A second run with the same installed services must not reinstall an
# unchanged crontab (every reinstall rewrites the vixie header timestamp,
# which showed up as a changed file in every --optimize parity snapshot).
cp "$CRON_OUT" "$CRON_IN"
: > "$CRON_OUT"
(
  cron_angie_configured() { return 1; }
  cron_mariadb_configured() { return 0; }
  crontab() { fake_crontab "$@"; }
  write_cron
) >/dev/null 2>&1
check "unchanged managed crontab is not reinstalled" \
  test ! -s "$CRON_OUT"

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

# MariaDB config diff: only the online-capable lines may be applied online.
cat > "$TMP/cnf-a" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 1000M
max_connections = 500
innodb_flush_method = fsync
EOF
cat > "$TMP/cnf-b" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2000M
max_connections = 500
innodb_flush_method = fsync
EOF
cat > "$TMP/cnf-c" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2000M
max_connections = 600
innodb_flush_method = fsync
EOF
cat > "$TMP/cnf-d" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 1000M
max_connections = 500
innodb_flush_method = O_DIRECT
EOF
check "cnf_only_pool_changed accepts a pool-only change" \
  cnf_only_pool_changed "$TMP/cnf-a" "$TMP/cnf-b"
check "cnf_only_pool_changed accepts max_connections (dynamic)" \
  cnf_only_pool_changed "$TMP/cnf-a" "$TMP/cnf-c"
cnf_other_changed() { ! cnf_only_pool_changed "$1" "$2"; }
check "cnf_only_pool_changed rejects a startup-only setting" \
  cnf_other_changed "$TMP/cnf-a" "$TMP/cnf-d"
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
ufw_body=$(sed -n '/^configure_ufw()/,/^}/p' "$ALL_SRC")
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
check "DNS drop-in routes every query to the global servers" \
  grep -qxF 'Domains=~.' "$ROOT/configs/system/dns_servers.conf"

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
check "XF cache key varies on the normalised Accept-Encoding" \
  grep -q '\$cookie_xf_language_id\$setup_cache_enc";' "$TMP/xf-cache.conf"
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

# ---------------------------------------------------------------------------
# Per-request open_basedir repair
# ---------------------------------------------------------------------------
mkdir -p "$TMP/basedir-repair/h5bp" "$TMP/basedir-repair/conf.d"
cat > "$TMP/basedir-repair/h5bp/php_polr.conf" <<'EOF'
location ~ [^/]\.php(/|$) {
    fastcgi_pass local_php;
    fastcgi_param PHP_ADMIN_VALUE open_basedir=/var/www/example.app/;
}
EOF
cat > "$TMP/basedir-repair/conf.d/site.conf" <<'EOF'
server {
  location ~ \.php$ {
    fastcgi_param PHP_ADMIN_VALUE "open_basedir=/var/www/inline.app/";
  }
}
EOF
cat > "$TMP/basedir-repair/h5bp/php.conf" <<'EOF'
location ~ [^/]\.php(/|$) {
    fastcgi_pass local_php;
    #fastcgi_param PHP_ADMIN_VALUE open_basedir=$document_root/:/tmp/;
}
EOF
tune_reset_changes
tune_strip_php_admin_open_basedir_all "$TMP/basedir-repair"
check "open_basedir param in an h5bp include is commented out" \
  grep -qx '    # fastcgi_param PHP_ADMIN_VALUE open_basedir=/var/www/example.app/;' \
  "$TMP/basedir-repair/h5bp/php_polr.conf"
check "open_basedir param inlined in conf.d is commented out" \
  grep -qx '    # fastcgi_param PHP_ADMIN_VALUE "open_basedir=/var/www/inline.app/";' \
  "$TMP/basedir-repair/conf.d/site.conf"
check "already-commented open_basedir line is left alone" \
  grep -qx '    #fastcgi_param PHP_ADMIN_VALUE open_basedir=$document_root/:/tmp/;' \
  "$TMP/basedir-repair/h5bp/php.conf"
check "open_basedir repair leaves no active param behind" \
  test "$(grep -rE '^[[:space:]]*fastcgi_param[[:space:]]+PHP_ADMIN_VALUE' "$TMP/basedir-repair" | wc -l | tr -d ' ')" -eq 0
check "open_basedir repair marks configuration dirty" test "$TUNE_DIRTY" -eq 1
tune_reset_changes
tune_strip_php_admin_open_basedir_all "$TMP/basedir-repair"
check "open_basedir repair is idempotent" test "$TUNE_DIRTY" -eq 0

# ---------------------------------------------------------------------------
# OPcache JIT: always the tracing JIT; the pool is always static
# ---------------------------------------------------------------------------
check "shipped custom_dan.ini leaves opcache.jit to the managed ini" \
  test "$(grep -cE '^[[:space:]]*opcache\.jit[[:space:]]*=' "$ROOT/configs/php/custom_dan.ini")" -eq 0
check "shipped custom_dan.ini ships no JIT buffer" \
  test "$(grep -cE '^[[:space:]]*opcache\.jit_buffer_size[[:space:]]*=' "$ROOT/configs/php/custom_dan.ini")" -eq 0
check "shipped custom_dan.ini does not duplicate the managed memory_limit" \
  test "$(grep -cE '^[[:space:]]*memory_limit[[:space:]]*=' "$ROOT/configs/php/custom_dan.ini")" -eq 0
check "shipped custom_dan.ini does not duplicate the managed OPcache size" \
  test "$(grep -cE '^[[:space:]]*opcache\.(memory_consumption|interned_strings_buffer)[[:space:]]*=' "$ROOT/configs/php/custom_dan.ini")" -eq 0
check "the optimizer writes the JIT mode from php_jit_settings" \
  test "$(grep -cE '^opcache\.jit = \$\{jit_mode\}$' "$ALL_SRC")" -eq 1
check "the tracing JIT is always on (512M OPcache -> 64M buffer)" \
  test "$(php_jit_settings 512)" = "tracing 64"
check "the JIT buffer never drops below 32M" \
  test "$(php_jit_settings 64)" = "tracing 32"
check "the JIT buffer never exceeds 128M" \
  test "$(php_jit_settings 4096)" = "tracing 128"
check "a garbage OPcache size still yields the tracing JIT" \
  test "$(php_jit_settings garbage)" = "tracing 32"
check "4+ CPU hosts use PHP's default tracing thresholds" \
  test "$(php_jit_threshold_lines 16)" = "opcache.jit_hot_loop = 64
opcache.jit_hot_func = 127
opcache.jit_hot_return = 16
opcache.jit_hot_side_exit = 64"
check "1-2 CPU hosts use conservative tracing thresholds" \
  test "$(php_jit_threshold_lines 2)" = "opcache.jit_hot_loop = 128
opcache.jit_hot_func = 255
opcache.jit_hot_return = 32
opcache.jit_hot_side_exit = 128"
check "SETUP_PHP_JIT_HOT_* overrides one threshold" \
  test "$(SETUP_PHP_JIT_HOT_LOOP=8 php_jit_threshold_lines 16 | head -n1)" = "opcache.jit_hot_loop = 8"
check "the managed ini writes the thresholds" \
  test "$(grep -c '^\$(php_jit_threshold_lines "\$nproc")$' "$ALL_SRC")" -eq 1
check "the pool is always static" \
  test "$(grep -c 'tune_pool_set "\$pool" pm static ' "$ALL_SRC")" -eq 1
check "no ondemand pool mode remains" \
  test "$(grep -c 'pm_mode=ondemand' "$ALL_SRC")" -eq 0
check "the OPcache file cache stays empty (restored scripts are never JIT-compiled)" \
  test "$(grep -c 'local opcache_file_cache=""' "$ALL_SRC")" -eq 1
# [PATH=] sections: only for WordPress roots and only when
# SETUP_PHP_JIT_WORDPRESS=0 exempts WordPress from the always-on JIT.
mkdir -p "$TMP/jit-angie/conf.d" "$TMP/jit-wp/public" "$TMP/jit-xf/public/src"
: > "$TMP/jit-wp/public/wp-config.php"
: > "$TMP/jit-xf/public/src/XF.php"
printf 'server {\n    root %s/jit-wp/public;\n    include h5bp/php_wp.conf;\n}\n' "$TMP" > "$TMP/jit-angie/conf.d/wp.conf"
printf 'server {\n    root %s/jit-xf/public;\n    include h5bp/php_xf.conf;\n}\n' "$TMP" > "$TMP/jit-angie/conf.d/xf.conf"
PHP_JIT_WORDPRESS=0
check "WordPress roots get a [PATH=] section with the JIT off" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c "^\[PATH=$TMP/jit-wp/public\]")" -eq 1
check "the [PATH=] section turns the JIT off, not disabled" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c '^opcache\.jit = off$')" -eq 1
check "XenForo roots get no [PATH=] section" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c 'jit-xf')" -eq 0
PHP_JIT_WORDPRESS=1
check "PHP_JIT_WORDPRESS=1 (the default) writes no [PATH=] section" \
  test -z "$(php_jit_path_sections "$TMP/jit-angie")"

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
# Idle FastCGI upstream connections pin PHP-FPM workers (see the live-origin
# audit): the tuner must remove the cache inside `upstream local_php` and
# leave the http-level keepalive_timeout alone.
check "PHP upstream keepalive cache is removed" \
  test "$(awk '/^upstream[[:space:]]+local_php/{f=1} f&&/^[[:space:]]*}[[:space:]]*$/{f=0} f&&/^[[:space:]]*keepalive([[:space:]]|_timeout)/{n++} END{print n+0}' "$TMP/angie/angie.conf")" -eq 0
check "the report exposes keepalive as off" test "$ANGIE_PHP_KEEPALIVE" = off
check "fastcgi_keep_conn is forced off in every PHP include" \
  test "$(grep -h '^fastcgi_keep_conn on;' "$TMP/angie"/h5bp/php*.conf | wc -l)" -eq 0
check "fastcgi_keep_conn off is present where it was on" \
  grep -q '^fastcgi_keep_conn off;' "$TMP/angie/h5bp/php.conf"
check "http-level keepalive_timeout is preserved" \
  grep -q '^[[:space:]]*keepalive_timeout 30s;' "$TMP/angie/angie.conf"

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
php_tune_body=$(sed -n '/^tune_php_fpm_version()/,/^}/p' "$ALL_SRC")
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
  <<<"$(sed -n '/^optimize_php_services()/,/^}/p' "$ALL_SRC")"

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
  <<<"$(sed -n '/^tune_angie_configs()/,/^}/p' "$ALL_SRC")"

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
effective_cpus() { printf '16'; }
mem_total_mb() { printf '131072'; }
mariadb_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
valkey_live_used_mb() { return 0; }
mariadb_data_dir_size_mb() { printf '0'; }
elasticsearch_data_dir_size_mb() { printf '0'; }
valkey_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "PHP budget is at most 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 131072 * 50 / 100 ))
check "service budgets stay under 95% of RAM" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 131072 * 95 / 100 ))
check "all fixed budgets are positive" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0 -a "$OPT_VALKEY_BUDGET_MB" -gt 0 -a "$OPT_ES_BUDGET_MB" -gt 0

# A live pool no longer overrides the plan: every host gets 2 workers per
# logical CPU, which is what makes the install and --optimize results
# identical on a host whose pool was sized by hand.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
plan_memory_budget
check "PHP budget follows 2 workers per CPU, not the live pool" \
  test "$OPT_PHP_BUDGET_MB" -eq $(( 32 * 96 ))
check "PHP budget is still capped at 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 65536 * 50 / 100 ))
check "Redis enables the shared cache budget" \
  test "$OPT_VALKEY_BUDGET_MB" -gt 0
check "PHP-first plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# The planner uses the same 2-per-CPU floor as tune_php_fpm_version().
php_pool_max_children() { printf '6'; }
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.3 mariadb)
plan_memory_budget
check "PHP budget uses the 2-per-CPU floor" \
  test "$OPT_PHP_BUDGET_MB" -eq $(( 32 * 96 ))
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

# A freshly installed database can be only a few MB.  mariadb_floor_mb gives
# it RAM/16 (256 MB..4 GB) so the pool has room before the next --optimize;
# the fresh-install plan uses the same floor, so the first --optimize cannot
# shrink what the installer sized.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '81'; }
elasticsearch_data_size_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "tiny live database uses the RAM floor (RAM/16 capped at 4 GB)" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 4096
check "tiny live database stays far below RAM/4" \
  test "$OPT_MARIADB_BUDGET_MB" -le $(( 262144 / 4 ))
check "tiny database floor stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Restore the 64 GB context for the oversized-database cases below.
mem_total_mb() { printf '65536'; }
mariadb_current_pool_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
# The database/heap assertions below are about the data tiers, so pin a small
# CPU count: the PHP pool now reserves 2 workers per logical CPU, and a large
# PHP floor would legitimately trim the database share on this 64 GB host.
effective_cpus() { printf '2'; }

# A database larger than the remaining budget gets the largest feasible pool.
mariadb_data_size_mb() { printf '40960'; }
plan_memory_budget
check "oversized database gets data+20%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 49152
check "oversized database covers the data within 20% headroom" \
  test "$OPT_DB_SIZE_MB" -eq 40960 -a "$OPT_MARIADB_BUDGET_MB" -ge 40960 -a "$OPT_MARIADB_BUDGET_MB" -le 49152

# On a large host the pool follows the live working set plus 5% headroom.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '73728'; }
mariadb_data_size_mb() { printf '73599'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey)
plan_memory_budget
check "large host sizes the pool to data+20%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 88318
check "data-sized pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0
check "data-sized pool keeps the plan inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Tiny statistics drift must not change the planned size on every run.
mariadb_current_pool_mb() { printf '88300'; }
plan_memory_budget
check "small statistics drift keeps the live pool" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 88300

# A live pool above the data target is kept while it still fits the budget:
# shrinking would force a restart and a cold buffer pool for no RAM benefit.
mariadb_current_pool_mb() { printf '120000'; }
plan_memory_budget
check "oversized live pool is reduced to data+20%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 88318
check "shrunk pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0

# A pool that would exceed the shared budget is capped.
mariadb_current_pool_mb() { printf '200000'; }
plan_memory_budget
check "pool above the target is capped to data+20%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 88318

# A database larger than the shared budget receives the capped pool.
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '300000'; }
plan_memory_budget
check "database larger than the shared budget is capped" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 200000 -a "$OPT_MARIADB_BUDGET_MB" -lt 209715
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
check "MariaDB-only unknown data uses the RAM floor" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 4096

# Valkey gets a larger share when no database/search tier shares the host.
mariadb_data_size_mb() { printf '0'; }
OPT_DETECTED=(valkey)
plan_memory_budget
check "Valkey-only empty cache uses the RAM floor (RAM/64, 128 MB..1 GB)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq "$(valkey_floor_mb "$(mem_total_mb)")"
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 valkey)
plan_memory_budget
check "Angie+PHP+Valkey empty cache uses the RAM floor" \
  test "$OPT_VALKEY_BUDGET_MB" -eq "$(valkey_floor_mb "$(mem_total_mb)")"

# Elasticsearch-only fallback when the index size cannot be measured.
elasticsearch_data_size_mb() { printf ''; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(elastic)
plan_memory_budget
check "Elasticsearch-only unknown index uses the 512 MB minimum" \
  test "$OPT_ES_BUDGET_MB" -eq 512

# A reachable but empty cluster is a measurement, not a failure: start from a
# RAM-scaled floor (total/16, 512 MB..4 GB) and give the spare budget to the
# only consumer.  This host is 64 GB, so the 50% heap cap applies.
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(elastic)
plan_memory_budget
check "measured empty Elasticsearch-only host uses the 512 MB minimum" \
  test "$OPT_ES_BUDGET_MB" -eq 512

mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '20000'; }
php_pool_max_children() { printf '128'; }
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# Elasticsearch heap follows a quarter of the live index store (the page
# cache serves the index), rounded up to 512 MB, within 25% of RAM.
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '0'; }
plan_memory_budget
check "small Elasticsearch index uses store/4" \
  test "$OPT_ES_BUDGET_MB" -eq 1024
check "Elasticsearch index size is recorded" \
  test "$OPT_ES_SIZE_MB" -eq 4096

elasticsearch_data_size_mb() { printf '20000'; }
plan_memory_budget
check "large Elasticsearch index gets store/4 rounded to 512 MB" \
  test "$OPT_ES_BUDGET_MB" -eq 5120
check "Elasticsearch heap stays within 25% of RAM" \
  test "$OPT_ES_BUDGET_MB" -le $(( 65536 * 25 / 100 ))
check "Elasticsearch plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# A huge index is capped at the 31 GB compressed-oops ceiling.
mem_total_mb() { printf '262144'; }
OPT_DETECTED=(angie php:8.4 elastic)
elasticsearch_data_size_mb() { printf '200000'; }
plan_memory_budget
check "Elasticsearch heap is capped at 31 GB" \
  test "$OPT_ES_BUDGET_MB" -eq 31744
check "Elasticsearch index size is recorded for huge stores" \
  test "$OPT_ES_SIZE_MB" -eq 200000

# The heap is also capped at 25% of RAM on a small host.
mem_total_mb() { printf '8192'; }
elasticsearch_data_size_mb() { printf '40000'; }
plan_memory_budget
check "Elasticsearch heap is capped at 25% of RAM" \
  test "$OPT_ES_BUDGET_MB" -eq 2048

# A live heap grossly above the store target is reduced so the freed RAM can
# serve the other tiers.
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '13000'; }
elasticsearch_current_heap_mb() { printf '20000'; }
plan_memory_budget
check "oversized Elasticsearch heap is reduced to store/4" \
  test "$OPT_ES_BUDGET_MB" -eq 3584
check "shrunk Elasticsearch heap is not marked as preserved" \
  test "$OPT_ES_KEPT_MB" -eq 0

# Small statistics drift must not change the heap on every run.
elasticsearch_current_heap_mb() { printf '3600'; }
plan_memory_budget
check "Elasticsearch statistics drift keeps the live heap" \
  test "$OPT_ES_BUDGET_MB" -eq 3600

# A heap that would exceed the shared budget is capped.
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
mariadb_data_size_mb() { printf '40000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '30000'; }
plan_memory_budget
check "Elasticsearch heap is capped to store/4" \
  test "$OPT_ES_BUDGET_MB" -eq 1024
# Restore the CPU stub for the sections that follow.
effective_cpus() { printf '16'; }

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
php_pool_max_children() { printf '32'; }
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
  test "$install_children" -eq 32
check "install plan reserves 64 MB per fresh worker, not 96 MB" \
  test "$install_php_budget" -eq $(( 32 * 64 ))

# The same host, now sized by --optimize after the install ran (live pool of
# 32 workers measured at the 64 MB floor).
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
check "audit does not flag a plain WordPress DB_HOST (core has no persistent option)" \
  grep -q 'no persistent-connection option' <<<"${OPT_REPORT[*]}"
check "audit recognizes a persistent Valkey socket" \
  grep -q 'with persistent connections' <<<"${OPT_REPORT[*]}"
check "audit counts no WordPress issue for a plain host" \
  test "$APP_CONNECTION_ISSUES" -eq 0
# wpdb::parse_db_host() turns "p:localhost" into host "p": flag it.
sed -i "s/DB_HOST., .localhost/DB_HOST', 'p:localhost/" "$TMP/wp-config.php"
OPT_REPORT=()
audit_app_persistent_connections
check "audit flags a p: WordPress DB_HOST as broken" \
  grep -q 'breaks WordPress' <<<"${OPT_REPORT[*]}"
check "audit counts the broken WordPress host" \
  test "$APP_CONNECTION_ISSUES" -eq 1
sed -i "s/DB_HOST., .p:localhost/DB_HOST', 'localhost/" "$TMP/wp-config.php"

opt_body=$(sed -n '/^optimize_angie()/,/^}/p' "$ALL_SRC")
check "optimize_angie synchronizes the Angie repository" \
  grep -q 'sync_angie_repo_configs' <<<"$opt_body"
profile_body=$(sed -n "/^angie_apply_profile()/,/^}/p" "$ALL_SRC")
check "the shared Angie profile enables the XenForo guest cache" \
  grep -q "ensure_xf_guest_cache" <<<"$profile_body"
check "optimize_angie applies the shared Angie profile" \
  grep -q "angie_apply_profile" <<<"$opt_body"
deploy_body=$(sed -n "/^deploy_angie_configs()/,/^}/p" "$ALL_SRC")
check "the installer applies the same Angie profile" \
  grep -q "angie_apply_profile" <<<"$deploy_body"
check "WordPress and XenForo share one FastCGI cache zone helper" \
  bash -c 'grep -q "ensure_fastcgi_cache_zone" "$1" && grep -q "ensure_fastcgi_cache_zone" <<<"$(sed -n "/^optimize_wordpress_cache()/,/^}/p" "$1")"' _ "$ALL_SRC"

# A legacy XenForo include without any cache block must be completed by
# --optimize, and the second run must be a no-op.
mkdir -p "$TMP/xfguest/conf.d" "$TMP/xfguest/h5bp" "$TMP/xfguest/http.d" \
         "$TMP/xfroot/src"
printf 'include http.d/*.conf;\n' > "$TMP/xfguest/angie.conf"
printf 'fastcgi_cache_path /home/nginx_cache levels=1:2 keys_zone=fastcgicache:512m max_size=1g inactive=1h use_temp_path=off;\nmap $request_uri $nocacheuri { default 0; }\n' \
  > "$TMP/xfguest/http.d/cache.conf"
printf 'server {\n    root %s;\n    include h5bp/php_xf.conf;\n}\n' "$TMP/xfroot" \
  > "$TMP/xfguest/conf.d/forum.test.conf"
printf '<?php\n' > "$TMP/xfroot/src/XF.php"
printf 'fastcgi_pass local_php;\n' > "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
OPT_REPORT=()
ensure_xf_guest_cache "$TMP/xfguest"
check "XenForo guest cache block is injected when missing" \
  grep -q '^fastcgi_cache fastcgicache;' "$TMP/xfguest/h5bp/php_xf.conf"
check "XenForo guest cache key varies on style and language" \
  bash -c 'grep -q "cookie_xf_style_id" "$1" && grep -q "cookie_xf_language_id" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
check "XenForo guest cache bypasses session cookies" \
  grep -q 'fastcgi_cache_bypass.*setup_xf_guest_bypass' "$TMP/xfguest/h5bp/php_xf.conf"
check "XenForo cookie bypass is a map, not an if" \
  bash -c 'grep -q "map \$http_cookie \$setup_xf_guest_bypass" "$1" && ! grep -qE "^[[:space:]]*if[[:space:]]*\(" "$2"' _ "$TMP/xfguest/http.d/zz-setup-fastcgi-cache-map.conf" "$TMP/xfguest/h5bp/php_xf.conf"
check "XenForo map excludes every session cookie" \
  bash -c 'for c in xf_session xf_user xf_session_admin xf_tfa_trust; do grep -q "$c" "$1" || exit 1; done' _ "$TMP/xfguest/http.d/zz-setup-fastcgi-cache-map.conf"
check "XenForo guest cache bounds the 200 TTL" \
  grep -q '^fastcgi_cache_valid 200 5m;' "$TMP/xfguest/h5bp/php_xf.conf"
check "XenForo guest cache repair reports a change" \
  test "${#TUNE_CHANGES[@]}" -gt 0
tune_reset_changes
OPT_REPORT=()
ensure_xf_guest_cache "$TMP/xfguest"
check "XenForo guest cache repair is idempotent" \
  test "${#TUNE_CHANGES[@]}" -eq 0
check "XenForo guest cache repair reports already enabled" \
  grep -q 'already enabled' <<<"${OPT_REPORT[*]}"

# A legacy include with direct cookie variables must be converted to the map.
printf 'fastcgi_cache fastcgicache;\nfastcgi_no_cache $cookie_xf_session $cookie_xf_user $nocacheuri;\nfastcgi_cache_bypass $cookie_xf_session $cookie_xf_user $nocacheuri;\n' \
  > "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "legacy direct-cookie bypass is replaced by the map variable" \
  bash -c '! grep -q "fastcgi_no_cache.*cookie_xf_session" "$1" && grep -q "fastcgi_no_cache \$setup_xf_guest_bypass \$nocacheuri;" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "second XenForo conversion records no change" \
  test "${#TUNE_CHANGES[@]}" -eq 0

# A real include is one `location ~ \.php` block: the injected block must land
# inside the braces (server-context directives would also cache the admin and
# login locations), and the security headers the location-level add_header
# drops are re-included when basic_xf.conf carries them.
mkdir -p "$TMP/xfguest/h5bp/security"
printf 'location ~ [^/]\\.php(/|$) {\n    fastcgi_pass local_php;\n}\n' > "$TMP/xfguest/h5bp/php_xf.conf"
printf 'location ~ [^/]\\.php(/|$) {\n    fastcgi_pass local_php;\n    add_header X-1h-Cache-Status $upstream_cache_status;\n}\n' > "$TMP/xfguest/h5bp/php_xf_proxy.conf"
printf 'include h5bp/security/strict-transport-security.conf;\ninclude h5bp/security/referrer-policy.conf;\n' > "$TMP/xfguest/h5bp/basic_xf.conf"
: > "$TMP/xfguest/h5bp/security/strict-transport-security.conf"
: > "$TMP/xfguest/h5bp/security/referrer-policy.conf"
tune_reset_changes
OPT_REPORT=()
ensure_xf_guest_cache "$TMP/xfguest"
check "injected XenForo cache block stays inside the location" \
  test "$(tail -n1 "$TMP/xfguest/h5bp/php_xf.conf")" = '}'
check "injected XenForo cache block is complete" \
  bash -c 'grep -q "^fastcgi_cache fastcgicache;" "$1" && grep -q "^fastcgi_cache_bypass" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
check "HSTS is re-included inside the cached PHP location" \
  grep -q '^include h5bp/security/strict-transport-security.conf;' "$TMP/xfguest/h5bp/php_xf.conf"
check "Referrer-Policy is re-included inside the proxy PHP location" \
  grep -q '^include h5bp/security/referrer-policy.conf;' "$TMP/xfguest/h5bp/php_xf_proxy.conf"
check "the proxy include keeps its closing brace last" \
  test "$(tail -n1 "$TMP/xfguest/h5bp/php_xf_proxy.conf")" = '}'
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "in-location repair is idempotent" test "${#TUNE_CHANGES[@]}" -eq 0
run_body=$(sed -n '/^run_optimize()/,/^}/p' "$ALL_SRC")
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

tuning_body=$(sed -n '/^run_os_tuning()/,/^}/p' "$ALL_SRC")
sysctl_line=$(printf '%s\n' "$tuning_body" | grep -n 'configure_sysctl' | head -n1 | cut -d: -f1)
limits_line=$(printf '%s\n' "$tuning_body" | grep -n 'configure_limits' | head -n1 | cut -d: -f1)
check "OS tuning applies sysctl before the PAM nofile limits" \
  test -n "$sysctl_line" -a -n "$limits_line" -a "$sysctl_line" -lt "$limits_line"

# MariaDB restart must pause the request tiers first, and apply unit changes
# before stopping them.
mariadb_body=$(sed -n '/^optimize_mariadb()/,/^}/p' "$ALL_SRC")
pause_line=$(printf '%s\n' "$mariadb_body" | grep -n 'opt_pause_web_frontends' | head -n1 | cut -d: -f1)
resume_line=$(printf '%s\n' "$mariadb_body" | grep -n 'opt_resume_web_frontends' | head -n1 | cut -d: -f1)
restart_line=$(printf '%s\n' "$mariadb_body" | grep -n 'opt_restart_service mariadb' | head -n1 | cut -d: -f1)
daemon_line=$(printf '%s\n' "$mariadb_body" | grep -n 'systemctl daemon-reload' | head -n1 | cut -d: -f1)
check "MariaDB restart pauses web frontends first" \
  test -n "$pause_line" -a -n "$restart_line" -a "$pause_line" -lt "$restart_line"
check "MariaDB restart resumes web frontends afterwards" \
  test -n "$resume_line" -a -n "$restart_line" -a "$restart_line" -lt "$resume_line"
check "MariaDB restart reloads systemd units before pausing web" \
  test -n "$daemon_line" -a -n "$pause_line" -a "$daemon_line" -lt "$pause_line"

# --restart-all must preserve the dependency order: stop Angie/PHP, restart
# cache/search, restart MariaDB, wait for SQL, then start PHP and Angie.
restart_body=$(sed -n '/^run_restart_all()/,/^}/p' "$ALL_SRC")
ra_daemon=$(printf '%s\n' "$restart_body" | grep -n 'systemctl daemon-reload' | head -n1 | cut -d: -f1)
ra_pause=$(printf '%s\n' "$restart_body" | grep -n 'opt_pause_web_frontends' | head -n1 | cut -d: -f1)
ra_restart_cache=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart "\$unit"' | head -n1 | cut -d: -f1)
ra_restart_es=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart elasticsearch' | head -n1 | cut -d: -f1)
ra_restart_db=$(printf '%s\n' "$restart_body" | grep -n 'systemctl restart mariadb' | head -n1 | cut -d: -f1)
ra_wait_db=$(printf '%s\n' "$restart_body" | grep -n 'mariadb_wait_ready 300' | head -n1 | cut -d: -f1)
ra_resume=$(printf '%s\n' "$restart_body" | grep -n 'opt_resume_web_frontends' | head -n1 | cut -d: -f1)
ra_wait_es=$(printf '%s\n' "$restart_body" | grep -n 'Elasticsearch did not answer HTTP' | head -n1 | cut -d: -f1)
check "restart-all reloads systemd before pausing the web tiers" \
  test -n "$ra_daemon" -a -n "$ra_pause" -a "$ra_daemon" -lt "$ra_pause"
check "restart-all pauses the web tiers before restarting cache/search" \
  test -n "$ra_pause" -a -n "$ra_restart_cache" -a "$ra_pause" -lt "$ra_restart_cache"
# The shared pause helper stops Angie first, then every PHP-FPM unit; the
# resume helper starts PHP first, then Angie.
pause_body=$(sed -n '/^opt_pause_web_frontends()/,/^}/p' "$ALL_SRC")
check "pause helper stops Angie before PHP-FPM" \
  test "$(printf '%s\n' "$pause_body" | grep -n 'systemctl stop angie' | head -n1 | cut -d: -f1)" -lt \
       "$(printf '%s\n' "$pause_body" | grep -n 'systemctl stop "$unit"' | head -n1 | cut -d: -f1)"
resume_body=$(sed -n '/^opt_resume_web_frontends()/,/^}/p' "$ALL_SRC")
check "resume helper starts PHP-FPM before Angie" \
  test "$(printf '%s\n' "$resume_body" | grep -n 'systemctl start "$unit"' | head -n1 | cut -d: -f1)" -lt \
       "$(printf '%s\n' "$resume_body" | grep -n 'systemctl start angie' | head -n1 | cut -d: -f1)"
check "restart-all restarts cache/search before MariaDB" \
  test -n "$ra_restart_cache" -a -n "$ra_restart_es" -a -n "$ra_restart_db" \
       -a "$ra_restart_cache" -lt "$ra_restart_db" -a "$ra_restart_es" -lt "$ra_restart_db"
check "restart-all waits for Elasticsearch before MariaDB" \
  test -n "$ra_restart_es" -a -n "$ra_wait_es" -a -n "$ra_restart_db" \
       -a "$ra_restart_es" -lt "$ra_wait_es" -a "$ra_wait_es" -lt "$ra_restart_db"
check "restart-all waits for MariaDB before resuming the web tiers" \
  test -n "$ra_restart_db" -a -n "$ra_wait_db" -a -n "$ra_resume" \
       -a "$ra_restart_db" -lt "$ra_wait_db" -a "$ra_wait_db" -lt "$ra_resume"

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

# A XenForo config on a persistent (p:) host keeps one connection per PHP
# worker open for the worker's lifetime; a second site served by the same
# pool needs its own transient connection on top (measured "Too many
# connections" at the old workers*1.25+50 ceiling).
php_pool_max_children() { printf '144'; }
app_persistent_db_configs() { printf '0'; }
# Keep the unit test hermetic: on a host where MariaDB is already running,
# mariadb_compute_profile keeps the live @@max_connections when it is higher
# (a deliberate production rule), which would mask the formula under test.
mariadb() { return 1; }
mariadb_compute_profile 2048
check "max_connections is workers*1.25+50 without persistent applications" \
  test "$MARIADB_PROFILE_MAX_CONN" -eq 230
app_persistent_db_configs() { printf '1'; }
mariadb_compute_profile 2048
check "one persistent application doubles the per-worker connection allowance" \
  test "$MARIADB_PROFILE_MAX_CONN" -eq 410 -a "$MARIADB_PROFILE_PERSISTENT_APPS" -eq 1
unset -f mariadb
app_persistent_db_configs() { printf '0'; }  # keep the stub: unset -f would drop the real function too
php_pool_max_children() { printf '128'; }

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
detect_body=$(sed -n '/^detect_installed_services()/,/^}/p' "$ALL_SRC")
check "Valkey takes precedence over Redis in service detection" \
  grep -q '! -f /etc/valkey/valkey.conf' <<<"$detect_body"

# Diagnostics must not present absent services as connection failures.
diag_body=$(sed -n '/^run_diagnostics()/,/^}/p' "$ALL_SRC")
check "diagnostics reports absent Valkey/Redis as not installed" \
  grep -q 'Valkey/Redis is not installed' <<<"$diag_body"
check "diagnostics does not call the Redis client when none is reachable" \
  grep -q 'diag_redis_cli' <<<"$diag_body"
check "diagnostics skips allocation explain when no shards are unassigned" \
  grep -q 'No unassigned shards; allocation explain is not needed' "$ALL_SRC"
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
check "fresh install sizes MariaDB from the RAM floor (RAM/16)" \
  test "$OPT_MARIADB_BUDGET_MB" -eq "$(mariadb_floor_mb "$(mem_total_mb)")"
check "fresh install uses the empty-index minimum" \
  test "$OPT_ES_BUDGET_MB" -eq 512
check "fresh install keeps the empty-database floor" \
  test "$OPT_MARIADB_BUDGET_MB" -eq "$(mariadb_floor_mb "$(mem_total_mb)")"
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
check "measured-empty live database uses the RAM floor" \
  test "$OPT_MARIADB_BUDGET_MB" -eq "$(mariadb_floor_mb "$(mem_total_mb)")"

# ---------------------------------------------------------------------------
# Live-data protection
# ---------------------------------------------------------------------------
# Live stores are sized to data+5%.  A pool/heap that is grossly above that
# target is reduced so the freed RAM can go to the other services; a value
# within statistics noise is kept to avoid restart churn.
valkey_live_used_mb() { return 0; }
mariadb_data_size_mb() { printf '2048'; }
mariadb_current_pool_mb() { printf '4096'; }
elasticsearch_data_size_mb() { printf '512'; }
elasticsearch_current_heap_mb() { printf '4096'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "live MariaDB pool is reduced to data+20%" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0 -a "$OPT_MARIADB_BUDGET_MB" -eq 2457
check "live Elasticsearch heap is reduced to the store/4 minimum" \
  test "$OPT_ES_KEPT_MB" -eq 0 -a "$OPT_ES_BUDGET_MB" -eq 512

valkey_live_used_mb() { printf '5000'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget
check "live Valkey working set raises the cache budget with headroom" \
  test "$OPT_VALKEY_LIVE_MB" -eq 5000 -a "$OPT_VALKEY_BUDGET_MB" -ge 5500
valkey_live_used_mb() { return 0; }

# Priority allocation adapts to the installed set: MariaDB+Valkey only has no
# PHP or Elasticsearch reservation, and the live targets still fit.
mem_total_mb() { printf '27812'; }
mariadb_data_size_mb() { printf '5000'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { return 0; }
elasticsearch_current_heap_mb() { return 0; }
valkey_live_used_mb() { printf '500'; }
OPT_DETECTED=(mariadb valkey)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "MariaDB+Valkey host reserves no PHP or Elasticsearch budget" \
  test "$OPT_PHP_BUDGET_MB" -eq 0 -a "$OPT_ES_BUDGET_MB" -eq 0
check "MariaDB+Valkey host fits the live database target" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 5000
check "MariaDB+Valkey plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 27812 * 80 / 100 ))

# Full stack: the data targets are reserved and PHP receives the remainder.
mariadb_data_size_mb() { printf '8000'; }
elasticsearch_data_size_mb() { printf '1000'; }
valkey_live_used_mb() { printf '1000'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget
check "full stack reserves MariaDB, Valkey and Elasticsearch first" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 8000 \
       -a "$OPT_VALKEY_BUDGET_MB" -ge 1100 \
       -a "$OPT_ES_BUDGET_MB" -ge 512
check "full stack still gets a viable PHP pool" \
  test "$OPT_PHP_BUDGET_MB" -ge 512 -a "$OPT_PHP_CHILDREN" -ge 8
check "full stack priority plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 27812 * 80 / 100 ))
valkey_live_used_mb() { return 0; }

# ---------------------------------------------------------------------------
# Supported service combinations
# ---------------------------------------------------------------------------
# Every documented host layout must reserve only the services it actually has
# and still stay inside the shared 80% budget.
mem_total_mb() { printf '32768'; }
nproc() { printf '16'; }
php_pool_max_children() { printf '64'; }
php_worker_allowance_mb() { printf '96'; }
mariadb_data_size_mb() { printf '2000'; }
mariadb_data_dir_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '1000'; }
elasticsearch_data_dir_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
valkey_live_used_mb() { printf '500'; }
valkey_data_size_mb() { printf '0'; }

check_combo() {
  local name=$1 spec=$2 want_php=$3 want_maria=$4 want_cache=$5 want_es=$6 ok=1
  read -r -a OPT_DETECTED <<< "$spec"
  OPT_INSTALL_PLAN=0
  plan_memory_budget
  local total=$(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB ))
  if (( want_php )); then (( OPT_PHP_BUDGET_MB > 0 )) || ok=0; else (( OPT_PHP_BUDGET_MB == 0 )) || ok=0; fi
  if (( want_maria )); then (( OPT_MARIADB_BUDGET_MB > 0 )) || ok=0; else (( OPT_MARIADB_BUDGET_MB == 0 )) || ok=0; fi
  if (( want_cache )); then (( OPT_VALKEY_BUDGET_MB > 0 )) || ok=0; else (( OPT_VALKEY_BUDGET_MB == 0 )) || ok=0; fi
  if (( want_es )); then (( OPT_ES_BUDGET_MB > 0 )) || ok=0; else (( OPT_ES_BUDGET_MB == 0 )) || ok=0; fi
  check "${name}: reserves only installed services" test "$ok" -eq 1
  check "${name}: stays inside the 80% budget" test "$total" -le $(( 32768 * 80 / 100 ))
}

check_combo "Angie+PHP+MariaDB+Valkey+Elasticsearch" \
  "angie php:8.5 mariadb valkey elastic" 1 1 1 1
check_combo "Angie+PHP+MariaDB+Elasticsearch" \
  "angie php:8.5 mariadb elastic" 1 1 0 1
check_combo "Angie+PHP+MariaDB+Valkey" \
  "angie php:8.5 mariadb valkey" 1 1 1 0
check_combo "Angie+PHP+Valkey" \
  "angie php:8.5 valkey" 1 0 1 0
check_combo "Angie+PHP" \
  "angie php:8.5" 1 0 0 0
check_combo "MariaDB alone" \
  "mariadb" 0 1 0 0
check_combo "Elasticsearch alone" \
  "elastic" 0 0 0 1
valkey_live_used_mb() { return 0; }

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
check "database-only fresh install uses the RAM floor for an empty database" \
  test "$OPT_MARIADB_BUDGET_MB" -eq "$(mariadb_floor_mb "$(mem_total_mb)")"

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
run_log_body=$(sed -n '/^start_run_log()/,/^}/p' "$ALL_SRC")
check "run log name is unique per process" \
  grep -Fq 'setup_${stamp}-$$.log' <<<"$run_log_body"
on_error_body=$(sed -n '/^on_error()/,/^}/p' "$ALL_SRC")
check "on_error ignores SIGPIPE from a closed pipe" \
  grep -q 'rc == 141' <<<"$on_error_body"


# ---------------------------------------------------------------------------
# 1.9.0: shared sizing helpers (install/optimize parity) and hardware rules
# ---------------------------------------------------------------------------
# The pool factor is hardware-derived; pin it here so the arithmetic below
# is deterministic on any test host.  The adaptive rule itself is covered
# separately at the end of this block.
export SETUP_PHP_WORKERS_PER_CPU=2
HOST_SERVER_TYPE=dedi
check "php_children_ceiling: 2 per core on dedicated hardware" \
  test "$(php_children_ceiling 16 65536 '' '')" -eq 32
HOST_SERVER_TYPE=vps
check "php_children_ceiling: the same 2-per-core floor on a VPS" \
  test "$(php_children_ceiling 16 65536 '' '')" -eq 32
check "php_children_ceiling: the 2-per-CPU floor beats the RAM divisor" \
  test "$(php_children_ceiling 16 2048 '' '')" -eq 32
check "php_children_floor: two workers per logical CPU" \
  test "$(php_children_floor 65536 16)" -eq 32
check "php_children_floor: a 1-2 core VPS keeps 2 per CPU" \
  test "$(php_children_floor 1024 2)" -eq 4
check "php_children_ceiling: a live pool is normalised to the plan" \
  test "$(php_children_ceiling 4 65536 200 '')" -eq 8
check "php_children_ceiling: explicit value wins but is clamped to the floor" \
  test "$(php_children_ceiling 4 65536 200 600)" -eq 512
check "php_children_ceiling: explicit value below the floor is raised" \
  test "$(php_children_ceiling 8 65536 '' 4)" -eq 16

# --- --upgrade-php parsing and extension mapping (1.20.0) ------------------
check "upgrade parse: --upgrade-php=8.6" \
  test "$( UPGRADE_PHP=''; UPGRADE_PHP_SEEN=0; parse_args --upgrade-php=8.6; printf '%s' "$UPGRADE_PHP" )" = 8.6
check "upgrade parse: --upgrade-php 8.6" \
  test "$( UPGRADE_PHP=''; UPGRADE_PHP_SEEN=0; parse_args --upgrade-php 8.6; printf '%s' "$UPGRADE_PHP" )" = 8.6
check "upgrade parse: a second --upgrade-php fails" \
  test "$( UPGRADE_PHP=''; UPGRADE_PHP_SEEN=0; rc=0; ( parse_args --upgrade-php=8.6 --upgrade-php=8.5 ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc" )" -ne 0
check "upgrade extension name: versioned package" \
  test "$(php_upgrade_ext_name php8.5-redis)" = redis
check "upgrade extension name: unversioned package" \
  test "$(php_upgrade_ext_name php-redis)" = redis
check "upgrade extension name: fpm" \
  test "$(php_upgrade_ext_name php8.6-fpm)" = fpm
check "upgrade extension name: Apache module is not an extension" \
  test -z "$(php_upgrade_ext_name libapache2-mod-php8.5)"
check "upgrade extension name: meta package is not an extension" \
  test -z "$(php_upgrade_ext_name php8.5)"

# --- adaptive pool factor (1.19.0) -----------------------------------------
check "php_children_from_tenths: one worker per core" \
  test "$(php_children_from_tenths 16 10)" -eq 16
check "php_children_from_tenths: one and a half per core rounds up" \
  test "$(php_children_from_tenths 15 15)" -eq 23
check "php_children_from_tenths: two per core" \
  test "$(php_children_from_tenths 16 20)" -eq 32
check "php_children_from_tenths: never fewer than two workers" \
  test "$(php_children_from_tenths 1 10)" -eq 2
check "php_children_from_tenths: rejects a zero factor" \
  test "$(php_children_from_tenths 16 0)" -eq 16
check "pool factor: local database on flash bare metal is 1.0/core" \
  test "$( storage_class() { printf nvme; }; host_has_local_db() { return 0; }; host_server_type() { printf dedi; }; SETUP_PHP_WORKERS_PER_CPU='' php_workers_per_cpu_tenths )" -eq 10
check "pool factor: a spinning disk keeps 2.0/core of headroom" \
  test "$( storage_class() { printf hdd; }; host_has_local_db() { return 0; }; host_server_type() { printf dedi; }; SETUP_PHP_WORKERS_PER_CPU='' php_workers_per_cpu_tenths )" -eq 20
check "pool factor: a remote database keeps 1.5/core" \
  test "$( storage_class() { printf nvme; }; host_has_local_db() { return 1; }; host_server_type() { printf dedi; }; SETUP_PHP_WORKERS_PER_CPU='' php_workers_per_cpu_tenths )" -eq 15
check "pool factor: a shared vCPU keeps 1.5/core" \
  test "$( storage_class() { printf ssd; }; host_has_local_db() { return 0; }; host_server_type() { printf vps; }; SETUP_PHP_WORKERS_PER_CPU='' php_workers_per_cpu_tenths )" -eq 15
check "pool factor: SETUP_PHP_WORKERS_PER_CPU pins the factor" \
  test "$(SETUP_PHP_WORKERS_PER_CPU=1.5 php_workers_per_cpu_tenths)" -eq 15
check "pool factor: a local MariaDB in this install run counts as local" \
  test "$( storage_class() { printf nvme; }; OPT_DETECTED=(); ENABLED=([mariadb]=1); host_server_type() { printf dedi; }; SETUP_PHP_WORKERS_PER_CPU='' php_workers_per_cpu_tenths )" -eq 10
HOST_SERVER_TYPE=dedi

check "sysctl_target_somaxconn scales with CPUs on dedicated hardware" \
  test "$(effective_cpus() { printf '16'; }; sysctl_target_somaxconn)" -eq 65536
HOST_SERVER_TYPE=vps
check "sysctl_target_somaxconn is capped on a VPS" \
  test "$(effective_cpus() { printf '64'; }; sysctl_target_somaxconn)" -eq 65536
HOST_SERVER_TYPE=dedi

check "swap target has a 1 GiB floor" \
  test "$(swap_target_bytes $(( 512 * 1024 * 1024 )))" -eq $(( 1024 * 1024 * 1024 ))
check "swap target is capped at 8 GiB on dedicated hardware" \
  test "$(swap_target_bytes $(( 256 * 1024 * 1024 * 1024 )))" -eq $(( 8 * 1024 * 1024 * 1024 ))
HOST_SERVER_TYPE=vps
check "swap target is capped at 4 GiB on a VPS" \
  test "$(swap_target_bytes $(( 64 * 1024 * 1024 * 1024 )))" -eq $(( 4 * 1024 * 1024 * 1024 ))
HOST_SERVER_TYPE=dedi

mariadb_storage_class() { printf 'nvme'; }
check "innodb_io_capacity: NVMe on dedicated hardware" \
  test "$(mariadb_io_capacity)" = '10000 20000'
HOST_SERVER_TYPE=vps
check "innodb_io_capacity: NVMe on a VPS is held back by provider IOPS" \
  test "$(mariadb_io_capacity)" = '3000 6000'
HOST_SERVER_TYPE=dedi
mariadb_storage_class() { printf 'hdd'; }
check "innodb_io_capacity: rotational disk" \
  test "$(mariadb_io_capacity)" = '400 800'
check "innodb_io_capacity: SETUP_MARIADB_IO_CAPACITY pins a host" \
  test "$(SETUP_MARIADB_IO_CAPACITY='1500 3000' mariadb_io_capacity)" = '1500 3000'
mem_total_mb() { printf '65536'; }
effective_cpus() { printf '16'; }
php_pool_max_children() { printf '144'; }
OPT_PHP_CHILDREN=0
mariadb_compute_profile 4096
check "MariaDB profile: HDD flushes neighbours and keeps 4 I/O threads" \
  test "$MARIADB_PROFILE_FLUSH_NEIGHBORS" -eq 1 -a "$MARIADB_PROFILE_IO_THREADS" -eq 4
check "MariaDB profile: max_connections follows the PHP pool" \
  test "$MARIADB_PROFILE_MAX_CONN" -eq 230
check "MariaDB profile: tmp_table_size scales with RAM and stays under pool/8" \
  test "$MARIADB_PROFILE_TMP_MB" -eq 256
mariadb_storage_class() { printf 'nvme'; }
mariadb_compute_profile 1024
check "MariaDB profile: NVMe keeps flush_neighbors=0 and 8 I/O threads" \
  test "$MARIADB_PROFILE_FLUSH_NEIGHBORS" -eq 0 -a "$MARIADB_PROFILE_IO_THREADS" -eq 8
check "MariaDB profile: tmp_table_size is capped at pool/8" \
  test "$MARIADB_PROFILE_TMP_MB" -eq 128
check "MariaDB profile: thread_cache_size scales with CPUs" \
  test "$MARIADB_PROFILE_THREAD_CACHE" -eq 128
check "MariaDB profile: LRU scan depth follows io_capacity" \
  test "$MARIADB_PROFILE_LRU_DEPTH" -eq 2048
php_pool_max_children() { printf '0'; }
mariadb_compute_profile 1024
check "MariaDB profile: no PHP pool falls back to CPU x 32 connections" \
  test "$MARIADB_PROFILE_MAX_CONN" -eq 512

check "valkey_maxclients has a 10000 floor" \
  test "$(valkey_maxclients)" -eq 10000
php_pool_max_children() { printf '512'; }
check "valkey_maxclients grows with the PHP pool" \
  test "$(valkey_maxclients)" -eq 4048 -o "$(valkey_maxclients)" -eq 10000
php_pool_max_children() { printf '0'; }
check "valkey_clamp_io_threads caps at 8 on both paths" \
  test "$(valkey_clamp_io_threads 16)" -eq 8 -a "$(valkey_clamp_io_threads x)" -eq 1

# service_mem_mb: the planned value wins; a stand-alone call uses the same
# floors as the planner so an install and a later --optimize agree.
OPT_MARIADB_BUDGET_MB=0; OPT_VALKEY_BUDGET_MB=0; OPT_ES_BUDGET_MB=0
check "service_mem_mb mariadb fallback is the RAM/16 planner floor" test "$(service_mem_mb mariadb)" -eq 4096
check "service_mem_mb valkey fallback is the RAM/64 planner floor (1 GB cap)" test "$(service_mem_mb valkey)" -eq 1024
check "service_mem_mb elastic fallback is 25% of RAM on a 512 MB step" test "$(service_mem_mb elastic)" -eq 16384
OPT_ES_BUDGET_MB=1000
check "service_mem_mb never re-rounds a planned Elasticsearch heap" test "$(service_mem_mb elastic)" -eq 1000
OPT_ES_BUDGET_MB=0

# Explicit sizes are reserved verbatim by the plan, never scaled.
mkdir -p "$SETUP_STATE_DIR"
printf 'mariadb_size_mb=20000\nvalkey_mb=4096\n' > "$SETUP_STATE_DIR/explicit-options.conf"
mem_total_mb() { printf '32768'; }
mariadb_data_size_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
valkey_live_used_mb() { return 0; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget
check "explicit MariaDB size is reserved verbatim" test "$OPT_MARIADB_BUDGET_MB" -eq 20000
check "explicit Valkey size is reserved verbatim" test "$OPT_VALKEY_BUDGET_MB" -eq 4096
check "the flexible tiers absorb the squeeze" test "$OPT_ES_BUDGET_MB" -eq 512
rm -f "$SETUP_STATE_DIR/explicit-options.conf"

# record_explicit_options writes the sizes the installers used to record.
ENABLED=([mariadb]=1 [valkey]=1 [elastic]=1 [php]=1)
OPT=([mariadb.size]=4gb [valkey.ram]=512m [elastic.ram]=2g [php.children]=64)
record_explicit_options
check "record_explicit_options stores MariaDB size in MB" \
  test "$(explicit_option mariadb_size_mb)" = 4096
check "record_explicit_options stores Valkey and Elasticsearch sizes" \
  test "$(explicit_option valkey_mb)" = 512 -a "$(explicit_option elastic_mb)" = 2048
check "record_explicit_options stores PHP children" \
  test "$(explicit_option php_children)" = 64
OPT=([mariadb.size]=auto)
record_explicit_options
check "record_explicit_options clears a value that is now auto" \
  bash -c "! grep -q '^mariadb_size_mb=' '$SETUP_STATE_DIR/explicit-options.conf'"
rm -f "$SETUP_STATE_DIR/explicit-options.conf"
ENABLED=()
OPT=()

# valkey_apply_config writes the same file from any starting point.
printf 'save 3600 1\nsave 300 100\nprotected-mode no\nmaxmemory 1gb\ndaemonize no\n' > "$TMP/valkey.conf"
valkey_apply_config "$TMP/valkey.conf" valkey 512 allkeys-lru 16 /run/valkey/valkey.sock
check "valkey_apply_config removes RDB saves and protected-mode no" \
  bash -c "! grep -qE '^(save 3600|protected-mode no)' '$TMP/valkey.conf' && grep -qx 'save \"\"' '$TMP/valkey.conf'"
check "valkey_apply_config keeps operator directives" grep -qx 'daemonize no' "$TMP/valkey.conf"
check "valkey_apply_config clamps io-threads to 8" grep -qx 'io-threads 8' "$TMP/valkey.conf"
valkey_hash=$(md5sum "$TMP/valkey.conf" | awk '{print $1}')
valkey_apply_config "$TMP/valkey.conf" valkey 512 allkeys-lru 16 /run/valkey/valkey.sock
check "valkey_apply_config is idempotent" test "$valkey_hash" = "$(md5sum "$TMP/valkey.conf" | awk '{print $1}')"
no_startup_keys() { ! valkey_runtime_settings 512 allkeys-lru 1 | grep -qE '^(tcp-backlog|io-threads) '; }
check "valkey_runtime_settings drops the startup-only keys" no_startup_keys
check "valkey_runtime_settings keeps maxmemory" \
  bash -c "true" && valkey_runtime_settings 512 allkeys-lru 1 | grep -q '^maxmemory 512mb'

check "write_service_limits_dropin reports a change" \
  write_service_limits_dropin "$TMP/dropin/limits.conf" $'[Service]\nLimitNOFILE=1'
not_changed() { ! write_service_limits_dropin "$@"; }
check "write_service_limits_dropin is silent when identical" \
  not_changed "$TMP/dropin/limits.conf" $'[Service]\nLimitNOFILE=1'

# Rate-limit exemptions for a load generator or monitor.
cat > "$TMP/limit_req.conf" <<'EOF'
geo $limit_req_whitelist {
    default 0;
    127.0.0.0/8 1;
    ::1/128     1;
}
limit_req_log_level warn;
EOF
LIMIT_REQ_EXEMPT='192.0.2.50,10.0.0.0/8 bogus' tune_limit_req_exemptions "$TMP/limit_req.conf" limit_req.conf
check "tune_limit_req_exemptions adds managed entries" \
  bash -c "grep -qx '    192.0.2.50 1; # setup.sh exempt' '$TMP/limit_req.conf' && grep -qx '    10.0.0.0/8 1; # setup.sh exempt' '$TMP/limit_req.conf'"
check "tune_limit_req_exemptions ignores invalid entries" \
  bash -c "! grep -q bogus '$TMP/limit_req.conf'"
LIMIT_REQ_EXEMPT='192.0.2.50' tune_limit_req_exemptions "$TMP/limit_req.conf" limit_req.conf
check "tune_limit_req_exemptions replaces the managed set" \
  test "$(grep -c 'setup.sh exempt' "$TMP/limit_req.conf")" -eq 1
LIMIT_REQ_EXEMPT='' tune_limit_req_exemptions "$TMP/limit_req.conf" limit_req.conf
check "tune_limit_req_exemptions removes managed entries when unset" \
  bash -c "! grep -q 'setup.sh exempt' '$TMP/limit_req.conf'"

mkdir -p "$TMP/datadir"
dd if=/dev/zero of="$TMP/datadir/ib_logfile0" bs=1M count=8 status=none
dd if=/dev/zero of="$TMP/datadir/data.ibd" bs=1M count=2 status=none
check "dir_size_mb excludes the given patterns" \
  test "$(dir_size_mb "$TMP/datadir" 'ib_logfile*')" -le 3
check "wait_for_cmd succeeds on the first good probe" wait_for_cmd 3 true
not_wait() { ! wait_for_cmd 1 false; }
check "wait_for_cmd fails after the last attempt" not_wait


# ---------------------------------------------------------------------------
# 1.11.0: shared helpers and hardware rules added by the audit
# ---------------------------------------------------------------------------
check "cgroup_quota_cpus rounds a fractional quota up to one CPU" \
  test "$(cgroup_quota_cpus 50000 100000)" = 1
check "cgroup_quota_cpus rounds 1.5 CPUs up to 2" \
  test "$(cgroup_quota_cpus 150000 100000)" = 2
check "cgroup_quota_cpus returns 0 without a numeric quota" \
  test "$(cgroup_quota_cpus max 100000)" = 0

# php_plan_max_children is the one decision tree for the pool writer and the
# dry run.
host_is_vps() { return 1; }
OPT_PHP_CHILDREN=0
check "php_plan_max_children normalises a live pool to 2 per CPU" \
  test "$(php_plan_max_children 16 27812 100 "")" = 32
check "php_plan_max_children lets an explicit value win over the live pool" \
  test "$(php_plan_max_children 16 27812 100 48)" = 48
OPT_PHP_CHILDREN=72
check "php_plan_max_children ignores the internal plan variable (deterministic)" \
  test "$(php_plan_max_children 16 27812 "" "")" = 32
OPT_PHP_CHILDREN=0
check "php_plan_max_children bounds a standalone budget by the hardware ceiling" \
  test "$(php_plan_max_children 16 27812 0 "" 4800)" = 32
check "php_plan_max_children falls back to the 2-per-CPU rule" \
  test "$(php_plan_max_children 16 27812 "" "" 0)" = 32
check "php_plan_max_children gives a 64-thread host 128 workers" \
  test "$(php_plan_max_children 64 131072 "" "" 0)" = 128
check "php_plan_max_children gives a 2-core box 4 workers" \
  test "$(php_plan_max_children 2 2048 "" "" 0)" = 4

# Brotli level: explicit, else 4, or 3 on a 1-2 CPU host.
effective_cpus() { printf 16; }
check "angie_brotli_level honours SETUP_BROTLI_LEVEL" \
  test "$(SETUP_BROTLI_LEVEL=7 angie_brotli_level)" = 7
check "angie_brotli_level ignores an invalid SETUP_BROTLI_LEVEL" \
  test "$(SETUP_BROTLI_LEVEL=99 angie_brotli_level)" = 4
effective_cpus() { printf 2; }
check "angie_brotli_level drops to 3 on a 2 CPU host" \
  test "$(angie_brotli_level)" = 3
effective_cpus() { printf 16; }

# --basic server= is persisted and honoured by host_server_type.
ENABLED=([basic]=1)
OPT[basic.server]=vps
record_explicit_options
check "record_explicit_options persists --basic server=vps" \
  test "$(explicit_option server_type)" = vps
unset "OPT[basic.server]"
HOST_SERVER_TYPE=""
detect_server_type() { printf dedi; }
check "host_server_type prefers the pinned class over detection" \
  test "$(host_server_type)" = vps
OPT[basic.server]=""
record_explicit_options
HOST_SERVER_TYPE=""
check "record_explicit_options clears the pin when server= is omitted" \
  test "$(host_server_type)" = dedi
unset "OPT[basic.server]"

# MariaDB profile: table caches follow max_connections, the redo cap follows
# the disk class.
php_pool_max_children() { printf 1000; }
mariadb_storage_class() { printf nvme; }
mariadb_io_capacity() { printf '10000 20000'; }
mariadb_compute_profile 32768
check "table_open_cache follows max_connections (1000 workers -> 1300 -> 20800)" \
  test "$MARIADB_PROFILE_OPEN_CACHE" -eq 20800
check "redo log reaches 4 GB on NVMe for a 32 GB pool" \
  test "$(size_to_mb "$MARIADB_PROFILE_LOG_SIZE")" -eq 4096
mariadb_storage_class() { printf ssd; }
mariadb_compute_profile 32768
check "redo log stays at 2 GB on SSD" \
  test "$(size_to_mb "$MARIADB_PROFILE_LOG_SIZE")" -eq 2048
php_pool_max_children() { printf 0; }
effective_cpus() { printf 4; }
mariadb_compute_profile 2048
check "table_open_cache keeps the 4000 floor on a small host (4 CPUs, 200 connections)" \
  test "$MARIADB_PROFILE_OPEN_CACHE" -eq 4000
effective_cpus() { printf 16; }

# Overcommit is reported when the service floors cannot fit.
nproc() { printf 1; }
mem_total_mb() { printf 1024; }
mariadb_data_size_mb() { printf 0; }
mariadb_current_pool_mb() { printf 0; }
elasticsearch_data_size_mb() { printf 0; }
elasticsearch_current_heap_mb() { printf 0; }
valkey_live_used_mb() { printf 0; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget 2>/dev/null
check "a 1 GB host running every service reports an overcommit" \
  test "${OPT_MEM_OVERCOMMIT_MB:-0}" -gt 0
mem_total_mb() { printf 27812; }
nproc() { printf 16; }
plan_memory_budget 2>/dev/null
check "a 27 GB host reports no overcommit" \
  test "${OPT_MEM_OVERCOMMIT_MB:-0}" -eq 0

# Source-level guards for rules that need root or /sys to exercise.
io_body=$(sed -n '/^configure_io_tuning()/,/^}/p' "$ALL_SRC")
check "udev I/O rule matches whole disks only" \
  bash -c "[[ \$(grep -c 'ENV{DEVTYPE}==\"disk\"' <<<\"\$0\") -eq 3 ]]" "$io_body"
check "PHP memory_limit drops to 128M under 2 GB" \
  grep -q '(( ram_mb < 2048 )) && PHP_PROFILE_MEMORY_MB=128' <<<"$(sed -n '/^php_ini_profile()/,/^}/p' "$ALL_SRC")"
sysctl_body=$(sed -n '/^configure_sysctl()/,/^}/p' "$ALL_SRC")
check "min_free_kbytes floor scales below 4 GB" \
  grep -q 'min_free < 16384' <<<"$sysctl_body"

# ---------------------------------------------------------------------------
# App-aware worker cap and asset precompression (1.11.0)
# ---------------------------------------------------------------------------
check "app_db_host_is_local: localhost" app_db_host_is_local localhost
check "app_db_host_is_local: persistent loopback" app_db_host_is_local p:127.0.0.1
check "app_db_host_is_local: socket path" app_db_host_is_local /run/mysqld/mysqld.sock
not_local() { ! app_db_host_is_local db.internal.example; }
check "app_db_host_is_local rejects a remote host" not_local
mkdir -p "$TMP/capsite/conf.d" "$TMP/capsite/xf/src" "$TMP/capsite/wp" "$TMP/capsite/other"
printf 'server {\n    root %s;\n    include h5bp/php_xf.conf;\n}\n' "$TMP/capsite/xf" > "$TMP/capsite/conf.d/xf.conf"
: > "$TMP/capsite/xf/src/XF.php"
printf "<?php\n\$config['db']['host'] = 'localhost';\n" > "$TMP/capsite/xf/src/config.php"
check "angie_vhost_root reads the root directive" \
  test "$(angie_vhost_root "$TMP/capsite/conf.d/xf.conf")" = "$TMP/capsite/xf"

mkdir -p "$TMP/assets/js" "$TMP/assets/internal_data"
head -c 20000 /dev/zero | tr '\0' 'a' > "$TMP/assets/js/app.js"
head -c 20000 /dev/zero | tr '\0' 'b' > "$TMP/assets/internal_data/skip.js"
printf 'x' > "$TMP/assets/js/tiny.js"
precompress_static_assets "$TMP/assets" >/dev/null
check "precompress_static_assets writes a gzip sibling" test -s "$TMP/assets/js/app.js.gz"
check "precompress sibling keeps the source mtime" test ! "$TMP/assets/js/app.js" -nt "$TMP/assets/js/app.js.gz"
no_skip_siblings() { [[ ! -e "$TMP/assets/internal_data/skip.js.gz" && ! -e "$TMP/assets/js/tiny.js.gz" ]]; }
check "precompress_static_assets skips internal_data and tiny files" no_skip_siblings
check "precompress_static_assets is incremental" \
  test "$(precompress_static_assets "$TMP/assets")" = 0
rm "$TMP/assets/js/app.js"
precompress_static_assets "$TMP/assets" >/dev/null
check "precompress_static_assets removes orphaned siblings" test ! -e "$TMP/assets/js/app.js.gz"


# --purge restores paired sysctls in an order the kernel accepts: the
# foreground dirty keys before the background ones, ipfrag low last.
mkdir -p "$SETUP_STATE_DIR"
for k in vm.dirty_background_bytes:0 vm.dirty_bytes:0 vm.dirty_background_ratio:10 vm.dirty_ratio:20 net.ipv4.ipfrag_low_thresh:3145728 net.ipv4.ipfrag_high_thresh:4194304; do
  printf '%s\n' "${k#*:}" > "$SETUP_STATE_DIR/sysctl-orig-${k%%:*}"
done
: > "$TMP/sysctl-order"
sysctl() { [[ $1 == -w ]] && printf '%s\n' "${2%%=*}" >> "$TMP/sysctl-order"; return 0; }
restore_sysctl_values
unset -f sysctl
order_ok() {
  local o; o=$(tr '\n' ' ' < "$TMP/sysctl-order")
  [[ $o == *"vm.dirty_ratio "*"vm.dirty_background_ratio "* && $o != *"vm.dirty_bytes "* && $o != *"vm.dirty_background_bytes "* \
     && $o == *"net.ipv4.ipfrag_high_thresh "*"net.ipv4.ipfrag_low_thresh "* ]]
}
check "restore_sysctl_values writes the non-zero member of each dirty pair, ratios first, ipfrag_low last" order_ok

# ---------------------------------------------------------------------------
# 1.12.0 helpers: Valkey floor, Angie open_file_cache bound, ini reader,
# in-location insertion, ufw SSH rule matcher, tree digest, rollback of files
# created during a tune.
# ---------------------------------------------------------------------------
check "valkey_floor_mb keeps the 128 MB minimum on a small host" test "$(valkey_floor_mb 1024)" -eq 128
check "valkey_floor_mb is 1/64 of RAM (27812 MB -> 434)" test "$(valkey_floor_mb 27812)" -eq 434
check "valkey_floor_mb caps at 1 GB" test "$(valkey_floor_mb 131072)" -eq 1024
check "valkey_floor_mb tolerates garbage" test "$(valkey_floor_mb x)" -eq 128

check "open_file_cache follows RAM when the fd limit allows it" \
  test "$(angie_open_file_cache_max 4096 131072 32768)" -eq 32768
check "open_file_cache is bounded by rlimit minus connections (4 CPU / 32 GB)" \
  test "$(angie_open_file_cache_max 32768 65536 8192)" -eq 56320
check "open_file_cache keeps the 10000 floor on a small host" \
  test "$(angie_open_file_cache_max 1024 65536 8192)" -eq 10000

printf 'user = www-data\n; group = x\ngroup=adm \nlisten = /run/php/php-fpm.sock\naccess.log = /x.log\npm.max_children = 64\n' > "$TMP/pool-ini.conf"
check "ini_get reads a trimmed value" test "$(ini_get "$TMP/pool-ini.conf" group)" = adm
check "ini_get skips commented lines" test "$(ini_get "$TMP/pool-ini.conf" user)" = www-data
check "ini_get handles dotted keys" test "$(ini_get "$TMP/pool-ini.conf" access.log)" = /x.log
check "ini_get does not match a key prefix" test "$(ini_get "$TMP/pool-ini.conf" pm)" = ""
check "ini_get prints nothing for an absent key" test -z "$(ini_get "$TMP/pool-ini.conf" missing)"

printf 'location ~ \\.php$ {\n    fastcgi_pass local_php;\n}\n' > "$TMP/loc.conf"
tune_reset_changes
tune_ensure_in_location "$TMP/loc.conf" '^[[:space:]]*fastcgi_cache[[:space:]]' 'fastcgi_cache fastcgicache;' "cache added"
check "tune_ensure_in_location inserts before the closing brace" \
  test "$(sed -n '3p' "$TMP/loc.conf")" = 'fastcgi_cache fastcgicache;'
check "tune_ensure_in_location keeps the brace last" test "$(tail -n1 "$TMP/loc.conf")" = '}'
tune_reset_changes
tune_ensure_in_location "$TMP/loc.conf" '^[[:space:]]*fastcgi_cache[[:space:]]' 'fastcgi_cache fastcgicache;' "cache added"
check "tune_ensure_in_location is idempotent" test "$TUNE_DIRTY" -eq 0

check "ufw_rule_ssh_port prints the matching SSH port" test "$(ufw_rule_ssh_port 'ufw allow 22/tcp' 22)" = 22
check "ufw_rule_ssh_port matches an alternate port" test "$(ufw_rule_ssh_port 'ufw limit 2222/tcp' 22 2222)" = 2222
not_ssh_rule() { ! ufw_rule_ssh_port "$@" >/dev/null; }
check "ufw_rule_ssh_port rejects a web rule" not_ssh_rule 'ufw allow 80/tcp' 22
check "ufw_rule_ssh_port does not match a port substring" not_ssh_rule 'ufw allow 2200/tcp' 22

mkdir -p "$TMP/digest/a"; printf 'x\n' > "$TMP/digest/a/one.conf"
d1=$(config_tree_digest "$TMP/digest"); d2=$(config_tree_digest "$TMP/digest")
check "config_tree_digest is stable" test "$d1" = "$d2"
printf 'y\n' > "$TMP/digest/a/one.conf"
check "config_tree_digest changes with the content" test "$d1" != "$(config_tree_digest "$TMP/digest")"
check "config_tree_digest reports an absent tree" test "$(config_tree_digest "$TMP/nope")" = absent

OPT_BACKUP_DIR="$TMP/optbk"; mkdir -p "$OPT_BACKUP_DIR" "$TMP/live/etc"
printf 'a\n' > "$TMP/live/etc/a.conf"
opt_backup "$TMP/live/etc" live-etc
printf 'changed\n' > "$TMP/live/etc/a.conf"; printf 'b\n' > "$TMP/live/etc/99-new.cnf"
opt_restore "$TMP/live/etc" live-etc
check "opt_restore puts back the recorded file" test "$(cat "$TMP/live/etc/a.conf")" = a
check "opt_restore moves a file created after the backup out of the tree" test ! -e "$TMP/live/etc/99-new.cnf"
OPT_BACKUP_DIR=""


# ---------------------------------------------------------------------------
# 1.13.0 helpers: MariaDB floor, block-device class, sed escaping, snapshot
# restore, PHP ini profile, gzip level, ES JSON readers, sysctl/cnf parsers,
# multi-zone cache keep.
# ---------------------------------------------------------------------------
check "mariadb_floor_mb keeps the 256 MB minimum on a 1 GB host" test "$(mariadb_floor_mb 1024)" -eq 256
check "mariadb_floor_mb is 1/16 of RAM (16384 MB -> 1024)" test "$(mariadb_floor_mb 16384)" -eq 1024
check "mariadb_floor_mb caps at 4 GB" test "$(mariadb_floor_mb 131072)" -eq 4096
check "mariadb_floor_mb tolerates garbage" test "$(mariadb_floor_mb x)" -eq 256

# The nvme* name wins before any sysfs or lsblk probe; a device without a
# sysfs rotational flag is treated as spinning when the transport is not
# paravirtual.
lsblk() { printf 'sata\n'; }
check "classify_block_device reports nvme from the device name" \
  test "$(classify_block_device nvme0n1)" = nvme
check "classify_block_device falls back to hdd without a sysfs rotational flag" \
  test "$(classify_block_device setup-test-no-such-disk)" = hdd
unset -f lsblk

check "sed_replacement_escape escapes &, | and backslash" \
  test "$(sed_replacement_escape 'a&b|c\d')" = 'a\&b\|c\\d'

# explicit_option_set must round-trip values with sed-special characters and
# keep one line per key.  STATE_DIR is read-only once setup.sh is sourced,
# so the round-trip runs in a fresh shell on its own state directory.
explicit_rt=$(SETUP_STATE_DIR="$TMP/state2" bash -c '
  source "$1" || exit 1
  explicit_option_set demo_key "a&b|c"
  explicit_option_set demo_key "x&y"
  cat "$SETUP_STATE_DIR/explicit-options.conf"' _ "$ROOT/setup.sh" 2>/dev/null || true)
check "explicit_option_set keeps one line per key after a rewrite" \
  test "$(printf '%s\n' "$explicit_rt" | grep -c '^demo_key=')" -eq 1
check "explicit_option_set stores a value containing & and | literally" \
  test "$explicit_rt" = 'demo_key=x&y'

# restore_snapshot_dir copies the snapshot over the live tree and moves
# files that were not in the snapshot out of the way (never unlinks them).
mkdir -p "$TMP/snap-src" "$TMP/snap-dst"
printf 'src-a\n' > "$TMP/snap-src/a"
printf 'src-b\n' > "$TMP/snap-src/b"
printf 'dst-a\n' > "$TMP/snap-dst/a"
printf 'src-b\n' > "$TMP/snap-dst/b"
printf 'extra\n' > "$TMP/snap-dst/c"
snap_out=$(preserve_to_tmp() { mv "$1" "$TMP/moved-$(basename "$1")"; printf '%s' "$TMP/moved-$(basename "$1")"; }
           restore_snapshot_dir "$TMP/snap-src" "$TMP/snap-dst")
check "restore_snapshot_dir restores the snapshot content" \
  test "$(cat "$TMP/snap-dst/a")" = src-a
check "restore_snapshot_dir keeps an unchanged snapshot file" \
  test "$(cat "$TMP/snap-dst/b")" = src-b
check "restore_snapshot_dir moves a file absent from the snapshot out of the tree" \
  test ! -e "$TMP/snap-dst/c"
check "restore_snapshot_dir preserves the moved file" \
  test "$(cat "$TMP/moved-c" 2>/dev/null)" = extra
check "restore_snapshot_dir reports the moved file" \
  grep -qE "^moved $TMP/snap-dst/c " <<<"$snap_out"
snap_missing_fails() { ! restore_snapshot_dir "$TMP/no-such-snapshot" "$TMP/snap-dst"; }
check "restore_snapshot_dir fails on a missing snapshot" snap_missing_fails

# php_ini_profile: OPcache RAM/16 (128..512), memory_limit RAM/8 (256..512,
# 128 under 2 GB), realpath cache RAM*2 KB (4096..16384).
php_ini_profile 1024
check "php_ini_profile 1 GB: 128M OPcache, 128M memory_limit, 4096K realpath" \
  test "$PHP_PROFILE_OPCACHE_MB" -eq 128 -a "$PHP_PROFILE_MEMORY_MB" -eq 128 -a "$PHP_PROFILE_REALPATH_KB" -eq 4096
php_ini_profile 8192
check "php_ini_profile 8 GB: 512M OPcache, 512M memory_limit, 16384K realpath" \
  test "$PHP_PROFILE_OPCACHE_MB" -eq 512 -a "$PHP_PROFILE_MEMORY_MB" -eq 512 -a "$PHP_PROFILE_REALPATH_KB" -eq 16384
php_ini_profile 4096
check "php_ini_profile 4 GB: 256M OPcache, 512M memory_limit, 8192K realpath" \
  test "$PHP_PROFILE_OPCACHE_MB" -eq 256 -a "$PHP_PROFILE_MEMORY_MB" -eq 512 -a "$PHP_PROFILE_REALPATH_KB" -eq 8192
php_ini_profile garbage
check "php_ini_profile falls back to the 1 GB profile on garbage" \
  test "$PHP_PROFILE_OPCACHE_MB" -eq 128 -a "$PHP_PROFILE_MEMORY_MB" -eq 128 -a "$PHP_PROFILE_REALPATH_KB" -eq 4096

# gzip level: explicit, else 4, or 3 on a 1-2 CPU host.
check "angie_gzip_level honours SETUP_GZIP_LEVEL" \
  test "$(SETUP_GZIP_LEVEL=7 angie_gzip_level)" = 7
check "angie_gzip_level ignores an invalid SETUP_GZIP_LEVEL and drops to 3 on 2 CPUs" \
  test "$(effective_cpus() { printf 2; }; SETUP_GZIP_LEVEL=bogus angie_gzip_level)" = 3
check "angie_gzip_level defaults to 4 on 8 CPUs" \
  test "$(effective_cpus() { printf 8; }; SETUP_GZIP_LEVEL='' angie_gzip_level)" = 4

es_json='{"cluster":{"number_of_nodes": 3,"status" : "green","x":{"size_in_bytes":123456}}}'
check "es_json_num reads a spaced numeric field" test "$(es_json_num "$es_json" number_of_nodes)" = 3
check "es_json_str reads a spaced string field" test "$(es_json_str "$es_json" status)" = green
check "es_json_num reads a nested numeric field" test "$(es_json_num "$es_json" size_in_bytes)" = 123456
check "es_json_num prints nothing for a missing key" test -z "$(es_json_num "$es_json" missing_key)"
check "es_json_str prints nothing for a missing key" test -z "$(es_json_str "$es_json" missing_key)"

cat > "$TMP/sysctl-keys.conf" <<'EOF'
# managed base profile
net.core.somaxconn = 1
vm.swappiness=10
net.core.somaxconn = 2
# commented.key = 1
EOF
check "sysctl_file_keys lists each active key once, sorted" \
  test "$(sysctl_file_keys "$TMP/sysctl-keys.conf" | paste -sd, -)" = "net.core.somaxconn,vm.swappiness"

cat > "$TMP/cnf-bytes.cnf" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2G
tmp_table_size=64M
max_heap_table_size = 1024
EOF
check "cnf_key_bytes converts a G suffix" test "$(cnf_key_bytes "$TMP/cnf-bytes.cnf" innodb_buffer_pool_size)" = 2147483648
check "cnf_key_bytes converts an M suffix without spaces" test "$(cnf_key_bytes "$TMP/cnf-bytes.cnf" tmp_table_size)" = 67108864
check "cnf_key_bytes keeps a bare byte count" test "$(cnf_key_bytes "$TMP/cnf-bytes.cnf" max_heap_table_size)" = 1024
check "cnf_key_bytes prints nothing for an absent key" test -z "$(cnf_key_bytes "$TMP/cnf-bytes.cnf" innodb_io_capacity)"

# Online-resizable keys: pool, redo log and the capacity keys may change
# without a restart; a key that the server only reads at startup may not.
printf '[mysqld]\ninnodb_buffer_pool_size = 1G\ninnodb_log_file_size = 256M\ninnodb_io_capacity = 2000\n' > "$TMP/cnf-online-a"
printf '[mysqld]\ninnodb_buffer_pool_size = 2G\ninnodb_log_file_size = 512M\ninnodb_io_capacity = 2000\n' > "$TMP/cnf-online-b"
printf '[mysqld]\ninnodb_buffer_pool_size = 1G\ninnodb_log_file_size = 256M\ninnodb_io_capacity = 4000\n' > "$TMP/cnf-online-c"
printf '[mysqld]\ninnodb_buffer_pool_size = 1G\ninnodb_log_file_size = 256M\ninnodb_flush_method = O_DIRECT\n' > "$TMP/cnf-online-d"
check "cnf_only_pool_changed accepts pool and redo-log changes together" \
  cnf_only_pool_changed "$TMP/cnf-online-a" "$TMP/cnf-online-b"
check "cnf_only_pool_changed accepts an innodb_io_capacity change (dynamic)" \
  cnf_only_pool_changed "$TMP/cnf-online-a" "$TMP/cnf-online-c"
check "cnf_only_pool_changed rejects a startup-only key" \
  cnf_other_changed "$TMP/cnf-online-a" "$TMP/cnf-online-d"

# angie_cache_keep_mb must pick the directive for the named zone when a file
# carries several multi-line *_cache_path directives.
cat > "$TMP/multi-proxy_cache.conf" <<'EOF'
proxy_cache_path /tmp/pc-a levels=1:2 keys_zone=proxy_cache:64m
  max_size=16g inactive=1d;
proxy_cache_path /tmp/pc-b levels=1:2 keys_zone=proxy_cdn:64m
  max_size=8g inactive=1d;
EOF
du() { printf '0\tx\n'; }
angie_cache_keep_mb "$TMP/multi-proxy_cache.conf" 100 proxy_cache
check "cache keep leaves the plan alone for an empty first zone" test "$ANGIE_CACHE_MB" = 100
angie_cache_keep_mb "$TMP/multi-proxy_cache.conf" 100 proxy_cdn
check "cache keep leaves the plan alone for an empty second zone" test "$ANGIE_CACHE_MB" = 100
du() { printf '900\tx\n'; }
angie_cache_keep_mb "$TMP/multi-proxy_cache.conf" 100 proxy_cdn
check "cache keep preserves the configured 8g that covers live usage" test "$ANGIE_CACHE_MB" = 8192
check "cache keep note names the zone's own directory" grep -qF '/tmp/pc-b' <<<"$ANGIE_CACHE_NOTE"
cache_note_not_first_zone() { ! grep -qF '/tmp/pc-a' <<<"$ANGIE_CACHE_NOTE"; }
check "cache keep note does not name the other zone's directory" cache_note_not_first_zone
unset -f du


# Upstream preservation: a repository rename must not break a vhost that an
# operator still points at the old name (the live soketi host hit
# "host not found in upstream" and --optimize rolled back).
mkdir -p "$TMP/up-old/conf.d" "$TMP/up-old/http.d" "$TMP/up-snap"
cat > "$TMP/up-old/conf.d/site.conf" <<'EOF'
server { location / { proxy_pass http://legacy_ws; } }
EOF
cat > "$TMP/up-old/http.d/ws.conf" <<'EOF'
upstream legacy_ws {
    zone legacy_zone 64k;
    server 127.0.0.1:6001;
    keepalive_timeout 1h;
}
EOF
angie_snapshot_upstreams "$TMP/up-old" "$TMP/up-snap"
check "upstream snapshot captures the named block" \
  grep -q '^upstream legacy_ws {' "$TMP/up-snap/legacy_ws.conf"
check "upstream snapshot does not capture host:port directives" \
  test -z "$(angie_referenced_upstreams "$TMP/up-old" | grep -v '^legacy_ws$')"

mkdir -p "$TMP/up-new/conf.d" "$TMP/up-new/http.d"
cp "$TMP/up-old/conf.d/site.conf" "$TMP/up-new/conf.d/"
printf 'upstream new_ws {\n    server 127.0.0.1:6001;\n}\n' > "$TMP/up-new/http.d/ws.conf"
angie_restore_upstreams "$TMP/up-new" "$TMP/up-snap"
check "upstream restore keeps a referenced block the new tree dropped" \
  grep -q '^upstream legacy_ws {' "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf"
check "upstream restore drops the old zone name" \
  test -z "$(grep -E '^[[:space:]]*zone[[:space:]]' "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf")"
check "upstream restore retains the server address" \
  grep -q '127.0.0.1:6001' "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf"
cp "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf" "$TMP/up-first.conf"
angie_restore_upstreams "$TMP/up-new" "$TMP/up-snap"
check "upstream restore is idempotent on the second run" \
  cmp -s "$TMP/up-first.conf" "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf"
printf 'upstream legacy_ws {\n    server 127.0.0.1:6001;\n}\n' >> "$TMP/up-new/http.d/ws.conf"
angie_restore_upstreams "$TMP/up-new" "$TMP/up-snap"
check "upstream restore removes the managed include once the tree defines it" \
  test ! -f "$TMP/up-new/http.d/zz-setup-preserved-upstreams.conf"


# Hardening must not fork one chmod process per world-writable file.  A live
# XenForo host had 598 757 of them and --optimize spent ~9 minutes in this
# loop, which looked like a hang; find now batches paths per chmod.
harden_files_body=$(sed -n '/^harden_wordpress_files()/,/^}/p' "$ALL_SRC")
check "world-writable fix uses a batched chmod" \
  grep -q -- '-exec chmod o-w {} +' <<<"$harden_files_body"
check "world-writable fix does not fork chmod per path" \
  bash -c '! grep -q "chmod o-w \"\$f\"" <<< "$1"' _ "$harden_files_body"
check "world-writable fix reports the count before fixing" \
  grep -q 'world-writable files: ${count}' <<<"$harden_files_body"


printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
