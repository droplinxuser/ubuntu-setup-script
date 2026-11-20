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
# The paired server-configs-nginx checkout.  A few checks assert what the
# shipped Angie tree contains; they need a real tree, not the fixtures.  CI
# checks the pair out inside the workspace and sets ANGIE_TREE; a developer
# keeps it next to this repository.  Without a tree those checks are skipped
# and counted, never passed: a negated grep over a missing directory used to
# pass, and a plain one failed every CI run.
ANGIE_TREE=${ANGIE_TREE:-$ROOT/../server-configs-nginx}

PASS=0
FAIL=0
SKIP=0
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
# Same for an operator pin in the calling shell: SETUP_STORAGE_CLASS would
# override every stubbed lsblk classification below.  (setup.sh skips
# /etc/default/setup-tuning itself in source-only mode.)
unset SETUP_STORAGE_CLASS STORAGE_CLASS
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
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
# check_tree DESC CMD...: run a check against ANGIE_TREE, or skip it when the
# paired tree is not checked out.
check_tree() {
  local desc=$1
  shift
  if [[ -d $ANGIE_TREE/h5bp && -d $ANGIE_TREE/conf.d ]]; then check "$desc" "$@"
  else t_skip "$desc (no server-configs-nginx tree at $ANGIE_TREE; set ANGIE_TREE)"; fi
}
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  # GitHub Actions turns this into a check annotation, so a CI-only failure
  # names the broken check without requiring the job log.
  printf '::error file=tests/test-tuning.sh,title=Tuning test failed::%s\n' "$*"
}
# Negate a shell function or command inside check (a new bash -c would not
# see the sourced functions and "! missing-command" would pass).
not() { ! "$@"; }

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

# The kernel needs low <= high after every single write.  systemd-sysctl
# starts from the kernel defaults (3 MB / 4 MB) and the profile never goes
# below them, so the high mark goes first; low-first failed
# systemd-sysctl.service on every boot of a 128 GB host (6178656 > 4194304).
ipfrag_block=$(ipfrag_sysctl_lines 8238208 6178656)
check "ipfrag tuning writes the high mark first" \
  test "$(printf '%s\n' "$ipfrag_block" | head -n1)" = "net.ipv4.ipfrag_high_thresh = 8238208"
check "ipfrag tuning writes the low mark second" \
  test "$(printf '%s\n' "$ipfrag_block" | tail -n1)" = "net.ipv4.ipfrag_low_thresh = 6178656"
# Boot simulation: kernel defaults, then the block in file order, for RAM
# sizes from the 4 MB clamp to the 16 MB cap.  Every write must be valid.
ipfrag_boot_ok() {
  local ram high low line key val cur_low=3145728 cur_high=4194304
  for ram in 2048 32768 65536 128722 262144 1048576; do
    high=$(( ram * 64 )); (( high < 4194304 )) && high=4194304; (( high > 16777216 )) && high=16777216
    low=$(( high * 3 / 4 ))
    cur_low=3145728; cur_high=4194304
    while IFS= read -r line; do
      key=${line%% =*}; val=${line##*= }
      case $key in
        *high_thresh) (( val >= cur_low )) || return 1; cur_high=$val ;;
        *low_thresh)  (( val <= cur_high )) || return 1; cur_low=$val ;;
      esac
    done < <(ipfrag_sysctl_lines "$high" "$low")
  done
}
check "ipfrag block applies cleanly from the kernel defaults at boot (2 GB-1 TB RAM)" ipfrag_boot_ok

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

# Backup credentials never pass through a sed replacement or a command
# line, and are written as quoted option-file values ("#" would otherwise
# start a comment and "\" an escape).
printf '[mysql]\nuser=dba\npassword=dba_passwd\n\n[mysqldump]\nuser=dba\npassword=dba_passwd\n' \
  > "$TMP/mysqlbkup.cnf.sample"
write_mysqlbkup_credentials "$TMP/mysqlbkup.cnf.sample" 'demo_user' 'p&ss|w/o\rd$1'
check "mysqlbkup credentials: user replaced in both sections" \
  test "$(grep -c '^user="demo_user"$' "$TMP/mysqlbkup.cnf.sample")" -eq 2
check "mysqlbkup credentials: special characters written quoted and escaped" \
  test "$(grep -cxF 'password="p&ss|w/o\\rd$1"' "$TMP/mysqlbkup.cnf.sample")" -eq 2
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
# XenForo 2.3 does not retry MariaDB error 1020; snapshot isolation must stay
# off so REPEATABLE READ keeps MySQL's behaviour (MariaDB 11.6.2+ defaults it
# on, which produced xf_forum/xf_user write failures on a live board).
check "MariaDB reference config disables snapshot isolation" \
  grep -qx 'innodb_snapshot_isolation = 0' "$ROOT/configs/mariadb/mariadb_server.cnf"
mariadb_base_body=$(sed -n '/^mariadb_write_base_block()/,/^}/p' "$ALL_SRC")
check "MariaDB base block writes snapshot isolation off" \
  grep -qx 'innodb_snapshot_isolation = 0' <<<"$mariadb_base_body"
no_slow_admin_alias() { ! mariadb_logging_settings | grep -q '^log_slow_admin_statements[[:space:]]*='; }
check "MariaDB logging helper omits the deprecated slow-admin alias" \
  no_slow_admin_alias

# The host's recorded pins must not reach the unit tests: STORAGE_CLASS= in
# /etc/default/setup-tuning on a provisioned host overrode every stubbed
# lsblk classification below.
check "source-only test mode does not read /etc/default/setup-tuning" \
  grep -qF 'if [[ ${SETUP_TEST_SOURCE_ONLY:-0} != 1 && -r /etc/default/setup-tuning ]]; then' "$ROOT/setup.sh"
check "a pin in the environment is cleared for the tests" \
  test -z "${SETUP_STORAGE_CLASS:-}${STORAGE_CLASS:-}"

# Disk classification must follow the device that actually backs /var/www.
findmnt() { printf '%s\n' "${FINDMNT_SRC:-/dev/null}"; }
lsblk() { printf '%s\n' "${LSBLK_OUT:-}"; }
# Real `lsblk -l` output: flat names, no tree glyphs.
LSBLK_OUT=$'nvme0n1p4 part\nnvme0n1   disk'
check "storage class follows the mounted NVMe parent" \
  test "$(storage_backing_class /var/www)" = nvme
LSBLK_OUT=$'sdzz1 part\nsdzz  disk'
check "storage class reports hdd for a spinning parent" \
  test "$(storage_backing_class /var/www)" = hdd
# md RAID: every member is classified, not only the last line of the tree.
LSBLK_OUT=$'md3       raid0\nnvme0n1p3 part\nnvme0n1   disk\nsdzz3     part\nsdzz      disk'
check "storage class sees every md member (NVMe listed first)" \
  test "$(storage_backing_class /var/www)" = nvme
check "storage_backing_class asks lsblk for list output" \
  grep -q 'lsblk -s -n -l -o NAME,TYPE' "$ROOT/lib/validate.sh"
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
check "managed XF cron redirects the whole loop, not just true" \
  cron_contains "$(cat "$CRON_OUT")" "${CRON_XF_JOBS} >/dev/null 2>&1 || true"
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
check "managed WordPress cron redirects the whole loop" \
  grep -q 'CRON_WP_CRON} >/dev/null 2>&1 || true' "$ALL_SRC"
check "managed XF cron redirects the whole loop (source)" \
  grep -q 'CRON_XF_JOBS} >/dev/null 2>&1 || true' "$ALL_SRC"
check "CRON_XF_JOBS no longer ends with its own || true" \
  bash -c '[[ $0 != *"done || true" ]]' "$CRON_XF_JOBS"

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
# must not make --optimize claim it set the performance governor.  Fixture
# trees, not the live /sys: a CI VM without cpufreq only ever ran the "no
# interface" branch and a bare-metal host only the "found" one.
gov=$TMP/cpufreq
mkdir -p "$gov/perf" "$gov/noperf"
echo "performance powersave" > "$gov/perf/scaling_available_governors"
echo "powersave schedutil" > "$gov/noperf/scaling_available_governors"
gov_probe() { SETUP_SYS_CPUFREQ=$1 cpu_performance_governor_available; }
check "CPU governor probe finds the performance governor" gov_probe "$gov/perf"
check "CPU governor probe ignores an unavailable performance governor" \
  not gov_probe "$gov/noperf"
check "CPU governor probe reports no cpufreq interface" not gov_probe "$gov/missing"

# /etc/hosts: the 127.0.1.1 line is replaced where it stands, so --basic
# followed by --purge basic gives back the provider's file byte for byte (the
# old delete-and-append moved it to the end; found on the OVH audit host).
hf=$TMP/hosts
printf '127.0.0.1\tlocalhost\n127.0.1.1\torig orig\n\n::1\tip6-localhost\n' > "$hf"
cp "$hf" "$TMP/hosts.orig"
hosts_set_loopback_line "$hf" "$(printf '127.0.1.1\tnew-host')"
check "hosts: the 127.0.1.1 line is replaced in place" \
  test "$(sed -n 2p "$hf")" = "$(printf '127.0.1.1\tnew-host')"
hosts_set_loopback_line "$hf" "$(printf '127.0.1.1\torig orig')"
check "hosts: setting the original line back restores the file byte for byte" \
  cmp -s "$hf" "$TMP/hosts.orig"
printf '127.0.0.1\tlocalhost\n' > "$hf"
hosts_set_loopback_line "$hf" "$(printf '127.0.1.1\tnew-host')"
check "hosts: a file without the line gets it appended" \
  test "$(tail -n 1 "$hf")" = "$(printf '127.0.1.1\tnew-host')"
printf '127.0.1.1\ta\n127.0.0.1\tlocalhost\n 127.0.1.1\tb\n' > "$hf"
hosts_set_loopback_line "$hf" "$(printf '127.0.1.1\tc')"
check "hosts: duplicate 127.0.1.1 lines collapse into the first position" \
  test "$(cat "$hf")" = "$(printf '127.0.1.1\tc\n127.0.0.1\tlocalhost')"
hosts_set_loopback_line "$hf" ""
check "hosts: an empty line removes the entry (the original had none)" \
  not grep -q '127\.0\.1\.1' "$hf"

# PHP purge (--upgrade-php, --purge php): dpkg warned "directory not empty"
# for every conf.d holding our own fragments and for mods-available when
# apt removed phpX.Y-common before the extensions.
pp_body=$(sed -n '/^purge_php_installations() {/,/^}/p' "$ALL_SRC")
check "PHP purge removes unowned conf.d fragments only after the /etc/php backup" \
  bash -c 'b=$(grep -n "cp -a /etc/php" <<<"$1" | cut -d: -f1); r=$(grep -n "php_unowned_confd_files" <<<"$1" | cut -d: -f1); [[ -n $b && -n $r && $b -lt $r ]]' _ "$pp_body"
check "PHP purge removes the -common packages in a second, last transaction" \
  bash -c 'grep -qF "^php([0-9]+\.[0-9]+)?-common\$ ]]; then last+=" <<<"$1" && grep -qF "apt-get purge \"\${APT_OPTS[@]}\" \"\${last[@]}\"" <<<"$1"' _ "$pp_body"
check "a failed PHP purge puts the removed conf.d fragments back" \
  bash -c 'grep -qF "cp -a -- \"\$backup/php/\${f#/etc/php/}\" \"\$f\"" <<<"$1"' _ "$pp_body"
pt=$TMP/phpconf; mkdir -p "$pt/8.5/fpm/conf.d" "$pt/8.5/cli/conf.d"
: > "$pt/8.5/fpm/conf.d/zz-setup-optimize.ini"; : > "$pt/8.5/fpm/conf.d/10-opcache.ini"
ln -s ../../mods-available/redis.ini "$pt/8.5/cli/conf.d/20-redis.ini"
check "unowned conf.d fragments: regular files dpkg does not own, never the phpenmod links" \
  test "$(
    dpkg-query() { [[ $2 == */10-opcache.ini ]]; }
    php_unowned_confd_files_t() { local f; for f in "$pt"/*/*/conf.d/*; do [[ -f $f && ! -L $f ]] || continue; dpkg-query -S "$f" >/dev/null 2>&1 && continue; printf '%s\n' "${f##*/}"; done; }
    php_unowned_confd_files_t
  )" = zz-setup-optimize.ini
check "unowned conf.d scan uses the same rules as the test above" \
  bash -c 'sed -n "/^php_unowned_confd_files() {/,/^}/p" "$1" | grep -qF "[[ -f \$f && ! -L \$f ]] || continue"' _ "$ALL_SRC"

# Web-root hygiene: one walk of the tree (a 7.7M-file XenForo host spent
# ~95 s in five separate walks plus a WordPress-only malware scan).
hw=$TMP/hygiene; mkdir -p "$hw/site/public/data" "$hw/site/mysql_database" "$hw/opendir"
: > "$hw/site/public/ww.txt"; chmod 666 "$hw/site/public/ww.txt"; chmod 777 "$hw/opendir"
truncate -s 101M "$hw/site/public/dump.sql"
truncate -s 101M "$hw/site/public/data/ww-backup.zip"; chmod 666 "$hw/site/public/data/ww-backup.zip"
truncate -s 101M "$hw/site/mysql_database/db.sql"
hw_run() {
  (
    SETUP_WWW_ROOT=$hw
    # Never the host's /etc/angie: on a machine with Angie installed the
    # served-root filter turned the WARNINGs below into notes.
    HARDEN_ANGIE_DIR=${HARDEN_ANGIE_DIR:-$hw/no-angie}
    : > "$TMP/hygiene.calls"; : > "$TMP/hygiene.report"
    find() { printf 'x' >> "$TMP/hygiene.calls"; command find "$@"; }
    harden_note() { printf 'NOTE %s\n' "$*" >> "$TMP/hygiene.report"; }
    harden_warn() { printf 'WARN %s\n' "$*" >> "$TMP/hygiene.report"; }
    harden_wordpress_files
  ) >/dev/null 2>&1
}
hw_run
check "hygiene walks the web root once (plus the depth-limited plugin check)" \
  test "$(wc -c < "$TMP/hygiene.calls")" -eq 2
check "hygiene fixes world-writable files and directories" \
  bash -c '! find "$1" -perm -0002 \( -type f -o -type d \) | grep -q .' _ "$hw"
check "hygiene counts every world-writable entry (file, dir, archive)" \
  grep -q 'NOTE .*world-writable entries fixed: 3' "$TMP/hygiene.report"
check "hygiene reports large archives, including a world-writable one" \
  bash -c 'grep -q "WARN .*public/dump.sql" "$1" && grep -q "WARN .*ww-backup.zip" "$1"' _ "$TMP/hygiene.report"
check "hygiene keeps mysql_database out of the archive report" \
  not grep -q 'mysql_database/db.sql' "$TMP/hygiene.report"
# With an Angie configuration only archives below a served root/alias are
# web-accessible (Pingvin's pingvin_data/uploads/shares/*/archive.zip was a
# false WARNING on a live host).
mkdir -p "$hw/angie/conf.d" "$hw/app_data/shares/a1"
truncate -s 101M "$hw/app_data/shares/a1/archive.zip"
printf 'server {\n  root %s/site/public;\n  location /x/ { alias %s/static/; }\n  # root %s/app_data;\n}\n' "$hw" "$hw" "$hw" > "$hw/angie/conf.d/site.conf"
hw_run_angie() { HARDEN_ANGIE_DIR=$hw/angie hw_run; }
hw_run_angie
check "hygiene: served roots come from root and alias, comments ignored" \
  test "$(HARDEN_ANGIE_DIR=$hw/angie harden_served_roots | paste -sd' ' -)" = "$hw/site/public $hw/static"
check "hygiene: an archive below a served root is still a WARNING" \
  grep -q "WARN .*$hw/site/public/dump.sql" "$TMP/hygiene.report"
check "hygiene: an archive outside every served root is a note, not a WARNING" \
  bash -c '! grep -q "WARN .*app_data" "$1" && grep -q "NOTE .*outside every served root (not web-accessible): 1" "$1"' _ "$TMP/hygiene.report"
check "hygiene: the served-root filter adds no tree walk" \
  test "$(wc -c < "$TMP/hygiene.calls")" -eq 2

# The webshell signatures are WordPress dropper families: no WordPress, no
# walk; with WordPress, only its roots (never a XenForo tree beside it).
mw=$TMP/mal; mkdir -p "$mw/wp/public/wp-content/plugins/seo-tools-0a1b2c3d4e" "$mw/xf/public/data"
: > "$mw/wp/public/wp-config.php"; : > "$mw/wp/public/wp-vcd.php"; : > "$mw/xf/public/data/wp-vcd.php"
mw_run() { # configs... -> report
  (
    SETUP_WWW_ROOT=$mw SETUP_PURGE_MALWARE=1
    local -a cfgs=("$@")
    app_find_wordpress_configs() { printf '%s\n' "${cfgs[@]}"; }
    harden_note() { printf 'NOTE %s\n' "$*"; }
    harden_warn() { printf 'WARN %s\n' "$*"; }
    scan_wordpress_malware
  ) 2>/dev/null
}
check "malware scan is skipped on a host without WordPress" \
  bash -c 'grep -q "malware scan: skipped (no WordPress install" <<<"$1"' _ "$(mw_run)"
check "malware scan without WordPress leaves every file alone" \
  bash -c 'test -f "$1/wp/public/wp-vcd.php" && test -f "$1/xf/public/data/wp-vcd.php"' _ "$mw"
mw_report=$(mw_run "$mw/wp/public/wp-config.php")
check "malware scan removes the dropper and the hex-suffixed plugin inside the WordPress root" \
  bash -c 'test ! -e "$1/wp/public/wp-vcd.php" && test ! -e "$1/wp/public/wp-content/plugins/seo-tools-0a1b2c3d4e" && grep -q "deleted 2" <<<"$2"' _ "$mw" "$mw_report"
check "malware scan never touches a same-named file outside the WordPress roots" \
  test -f "$mw/xf/public/data/wp-vcd.php"

# Foreign sysctl sources (Ubuntu 24.04 keeps 10-*.conf in /etc/sysctl.d): the
# run log lists only keys whose value differs from the profile this run
# wrote.  The old warning ran before the profile was written and listed
# equal keys too, so it fired on every --optimize of a 24.04 host.
fs=$TMP/foreign-sysctl; mkdir -p "$fs"
printf 'kernel.sysrq = 176\nkernel.kptr_restrict = 1\n' > "$fs/10-mixed.conf"
printf 'kernel.yama.ptrace_scope = 1\n' > "$fs/10-same.conf"
fs_run() {
  (
    tuning_managed_keys() { printf '%s\n' kernel.sysrq kernel.kptr_restrict kernel.yama.ptrace_scope; }
    tuning_ours_value() { case $1 in kernel.sysrq) printf 0 ;; *) printf 1 ;; esac; }
    SETUP_SYSCTL_SCAN_DIRS=$fs tuning_override_sources "$@"
  )
}
check "foreign sysctl report: conflicts mode lists only the differing key" \
  test "$(fs_run conflicts)" = "$fs/10-mixed.conf: kernel.sysrq(file=176 ours=0)"
check "foreign sysctl report: the full listing still shows equal keys" \
  test "$(fs_run | grep -c same)" -eq 2
check "foreign sysctl report runs after the profile is written" \
  bash -c 'grep -A1 "^  run_os_tuning$" "$1" | grep -qx "  report_foreign_sysctl_sources"' _ "$ROOT/lib/restart.sh"
check "the profile reset no longer warns about foreign sysctl sources" \
  not grep -q 'Still-defined foreign sysctl sources' "$ROOT/lib/overrides.sh"
# The dry run previews against the template it would install, not the
# current /etc/sysctl.conf (live host: rp_filter previewed as ours=1).
printf 'net.ipv4.conf.all.rp_filter = 2\n' > "$fs/profile.conf"
check "dry-run preview reads ours from the profile it would write" \
  test "$(TUNING_OURS_PROFILE=$fs/profile.conf tuning_ours_value net.ipv4.conf.all.rp_filter)" = 2
check "the shipped profile sets rp_filter 2 (Ubuntu's own value)" \
  test "$(sysctl_file_value "$ROOT/configs/system/sysctl.conf" net.ipv4.conf.all.rp_filter)" = 2

# Stale active http.d/letsencrypt.conf (shipped for a few hours on
# 2026-07-22): retired when it is the shipped file and no vhost uses it.
acme_case() { # setup -> "kept" or "retired"
  local t=$TMP/acme-$1
  rm -rf "$t"; mkdir -p "$t/http.d" "$t/conf.d" "$t/snippets"
  printf 'acme_client letsencrypt https://acme-v02.api.letsencrypt.org/directory;\n' > "$t/http.d/letsencrypt_conf"
  cp "$t/http.d/letsencrypt_conf" "$t/http.d/letsencrypt.conf"
  printf 'server {\n    server_name a.test;\n}\n' > "$t/conf.d/a.test.conf"
  case $1 in
    used)   printf 'server {\n    acme letsencrypt;\n}\n' > "$t/conf.d/b.test.conf" ;;
    edited) printf '# operator\n' >> "$t/http.d/letsencrypt.conf" ;;
  esac
  ( tune_reset_changes; tune_retire_unused_acme_client "$t" ) >/dev/null 2>&1
  [[ -f $t/http.d/letsencrypt.conf ]] && echo kept || echo retired
}
check "ACME: an unused, as-shipped letsencrypt.conf is retired" test "$(acme_case unused)" = retired
check "ACME: a vhost with 'acme letsencrypt' keeps it" test "$(acme_case used)" = kept
check "ACME: an operator-edited file is kept" test "$(acme_case edited)" = kept
check "ACME: the inactive letsencrypt_conf template stays" \
  test -f "$TMP/acme-unused/http.d/letsencrypt_conf"
# The sync tests the tree before the tuner runs; the retirement must come
# first or the run that retires it still prints the warning (live host).
acme_before_test() {
  sed -n '/^deploy_angie_tree()/,/^}/p' "$ROOT/lib/web.sh" \
    | grep -nE 'tune_retire_unused_acme_client|/usr/sbin/angie -t' | head -n 1 \
    | grep -q tune_retire_unused_acme_client
}
check "ACME: the sync retires the stale file before its first angie -t" acme_before_test

# Superseded legacy zz-setup-*_conf files (live host: zz-setup-wordpress-
# cache_conf redefined keys_zone=fastcgicache and map $nocacheuri).
ls_t=$TMP/legacy-zz; mkdir -p "$ls_t/http.d"
printf 'http {\n  include http.d/*.conf;\n}\n' > "$ls_t/angie.conf"
printf 'map $request_uri $nocacheuri {\n  default 0;\n}\nfastcgi_cache_path /home/c levels=1:2 keys_zone=fastcgicache:512m max_size=1G;\n' > "$ls_t/http.d/fastcgi_cache.conf"
printf 'map $request_uri $nocacheuri {\n  default 0;\n}\n\nfastcgi_cache_path /home/c levels=1:2 keys_zone=fastcgicache:512m max_size=2G;\n' > "$ls_t/http.d/zz-setup-wordpress-cache_conf"
printf 'fastcgi_cache_path /home/o levels=1:2 keys_zone=onlyhere:16m;\n' > "$ls_t/http.d/zz-setup-unique_conf"
printf 'fastcgi_cache_path /home/c levels=1:2 keys_zone=fastcgicache:16m;\n' > "$ls_t/http.d/operator_conf"
( tune_reset_changes; tune_retire_superseded_setup_files "$ls_t" ) >/dev/null 2>&1
check "legacy zz-setup file whose zones/maps are all loaded elsewhere is retired" \
  test ! -e "$ls_t/http.d/zz-setup-wordpress-cache_conf"
check "legacy zz-setup file with a zone nothing else defines is kept" test -f "$ls_t/http.d/zz-setup-unique_conf"
check "an inactive file without the zz-setup- prefix (operator's) is kept" test -f "$ls_t/http.d/operator_conf"
check "loaded files are never touched by the legacy retirement" test -f "$ls_t/http.d/fastcgi_cache.conf"
legacy_before_test() {
  sed -n '/^deploy_angie_tree()/,/^}/p' "$ROOT/lib/web.sh" \
    | grep -nE 'tune_retire_superseded_setup_files|/usr/sbin/angie -t' | head -n 1 \
    | grep -q tune_retire_superseded_setup_files
}
check "the sync retires superseded legacy files before its first angie -t" legacy_before_test

# Elasticsearch exposure through UFW (live host: network.host = public IP,
# X-Pack off, UFW admitting only the forum server).  The warning fired twice
# on that correctly firewalled host.
ufw_sample_restricted=$'Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing), disabled (routed)\nNew profiles: skip\n\nTo                         Action      From\n--                         ------      ----\n22                         LIMIT IN    Anywhere\n80                         ALLOW IN    Anywhere\n443                        ALLOW IN    Anywhere\nAnywhere                   ALLOW IN    198.51.100.36\n22 (v6)                    LIMIT IN    Anywhere (v6)\n80 (v6)                    ALLOW IN    Anywhere (v6)'
check "ufw parser: 9200 admitted only from the remote client" \
  test "$(ufw_status_port_sources 9200 <<<"$ufw_sample_restricted")" = "198.51.100.36"
# "Anywhere ALLOW 198.51.100.36" admits that host on every port, 443 too.
check "ufw parser: 443 admitted from anywhere (and the all-ports host)" \
  test "$(ufw_status_port_sources 443 <<<"$ufw_sample_restricted" | paste -sd' ' -)" = "Anywhere 198.51.100.36"
check "ufw parser: a port range and comma list are honoured" \
  test "$(printf 'To                         Action      From\n--                         ------      ----\n9000:9400/tcp              ALLOW IN    10.0.0.5\n80,9300/tcp                ALLOW IN    Anywhere\n' | ufw_status_port_sources 9300 | paste -sd' ' -)" = "10.0.0.5 Anywhere"
es_exp() { ( ufw() { printf '%s\n' "$UFW_OUT"; }; es_ufw_exposure ); }
check "ES exposure: restricted to the remote client" \
  test "$(UFW_OUT=$ufw_sample_restricted es_exp)" = "restricted:198.51.100.36"
check "ES exposure: a rule opening 9200 to anywhere is open" \
  test "$(UFW_OUT="${ufw_sample_restricted}"$'\n9200/tcp                   ALLOW IN    Anywhere' es_exp)" = "open"
check "ES exposure: inactive UFW is unknown (warning stays)" \
  test "$(UFW_OUT='Status: inactive' es_exp)" = "unknown"
check "ES exposure: an allow-all default is unknown (warning stays)" \
  test "$(UFW_OUT="${ufw_sample_restricted/deny (incoming)/allow (incoming)}" es_exp)" = "unknown"
check "the Elasticsearch section no longer prints its own WARNING" \
  not grep -q 'WARNING\*\*: Elasticsearch network.host' "$ROOT/lib/service-optimizers.sh"

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
fastcgi_cache fastcgicache;
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
  grep -q '|\$setup_xf_key_style|' "$TMP/xf-cache.conf"
check "XF cache key includes the language id" \
  grep -q '|\$setup_xf_key_language|' "$TMP/xf-cache.conf"
check "XF cache key keeps the style variation" \
  grep -q '|\$setup_xf_key_variation|' "$TMP/xf-cache.conf"
check "XF cache key varies on the normalised Accept-Encoding" \
  grep -q '|\$setup_cache_enc";' "$TMP/xf-cache.conf"
check "XF cache key carries no raw cookie value" \
  bash -c '! grep -q "cookie_xf_" "$1"' _ "$TMP/xf-cache.conf"
check "XF cache key separates the URI from the tokens" \
  grep -q '\$request_uri|' "$TMP/xf-cache.conf"
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
  grep -q 'public, max-age=2592000, immutable' "$TMP/xf2.conf"
check "XF static assets send one Cache-Control header and HSTS" \
  bash -c 'grep -q "expires off;" "$1" && grep -q "strict-transport-security.conf" "$1"' _ "$TMP/xf2.conf"
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
# SIGTERM killed workers mid-connection: one MariaDB "Aborted connection"
# warning per persistent connection on every restart.
check "PHP-FPM unit drop-in stops gracefully (KillSignal=SIGQUIT)" \
  grep -qx 'KillSignal=SIGQUIT' "$ROOT/configs/php/php-fpm-limits.conf"
check "PHP-FPM unit drop-in fallback matches the shipped file's directives" \
  bash -c 'diff <(grep -v "^#" "$1") <(sed -n "/^php_fpm_write_systemd_limits() {/,/^}/p" "$2" | sed -n "/content=.\[Service\]/,/UMask=0027./p" | sed -E "s/^ *content=.//; s/^(UMask=0027).$/\1/")' _ "$ROOT/configs/php/php-fpm-limits.conf" "$ROOT/lib/services.sh"
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
check "a huge-page reservation covers OPcache plus the JIT buffer" \
  php_hugepages_ok 479 512 64
check "an exact huge-page reservation is accepted" php_hugepages_ok 288 512 64
check "a partial huge-page reservation does not enable huge_code_pages" \
  not php_hugepages_ok 87 512 64
check "a non-numeric huge-page count is refused" not php_hugepages_ok bogus 512 64
check "huge pages: 12 GB PHP host covers OPcache plus JIT" \
  test "$(sysctl_hugepages_target 11955 1)" = 296
check "huge pages: 4 GB PHP host gets a smaller reservation" \
  test "$(sysctl_hugepages_target 4096 1)" = 152
check "huge pages: no reservation on a host without PHP" \
  test "$(sysctl_hugepages_target 31775 0)" = 0
check "huge pages: none below 4 GB" test "$(sysctl_hugepages_target 3910 1)" = 0
check "huge pages: capped for a 128 GB host" \
  test "$(sysctl_hugepages_target 131072 1)" = 296
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

# Guest-cache page compression and Chevereto session GC ([PATH=] sections).
mkdir -p "$TMP/jit-angie/h5bp" "$TMP/jit-chev/public/app"
: > "$TMP/jit-chev/public/app/env.php"
printf 'server {\n    root %s/jit-wp/public;\n    include h5bp/wordpress_cache.conf;\n    include h5bp/php_wp.conf;\n}\n' "$TMP" > "$TMP/jit-angie/conf.d/wp.conf"
printf 'server {\n    root %s/jit-chev/public;\n    include h5bp/php_chev_cache.conf;\n}\n' "$TMP" > "$TMP/jit-angie/conf.d/chev.conf"
printf 'fastcgi_cache_key "$scheme$request_method$host$request_uri";\n' > "$TMP/jit-angie/h5bp/wordpress_cache.conf"
printf 'fastcgi_cache_key "$request_method$scheme$host$request_uri";\n' > "$TMP/jit-angie/h5bp/php_chev_cache.conf"
PHP_PAGE_GZIP=1
check "a cache key without the encoding token gets no page compression" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c '^zlib\.output_compression = On$')" -eq 0
check "a Chevereto root always gets PHP session GC" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -A3 "^\[PATH=$TMP/jit-chev/public\]" | grep -c '^session\.gc_probability = 1$')" -eq 1
printf 'fastcgi_cache_key "$scheme$request_method$host$request_uri|$guest_cache_enc";\n' > "$TMP/jit-angie/h5bp/wordpress_cache.conf"
printf 'fastcgi_cache_key "$request_method$scheme$host$request_uri|$guest_cache_enc";\n' > "$TMP/jit-angie/h5bp/php_chev_cache.conf"
check "WordPress and Chevereto roots behind an encoding-aware cache compress in PHP" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c '^zlib\.output_compression = On$')" -eq 2
check "each document root gets exactly one [PATH=] section" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c '^\[PATH=')" -eq 2
check "XenForo roots get no page compression (XenForo compresses itself)" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c 'jit-xf')" -eq 0
PHP_JIT_WORDPRESS=0
check "JIT exemption and page compression share one WordPress section" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -A6 "^\[PATH=$TMP/jit-wp/public\]" | grep -cE '^(opcache\.jit = off|zlib\.output_compression = On)$')" -eq 2
PHP_JIT_WORDPRESS=1
PHP_PAGE_GZIP=0
check "SETUP_PHP_PAGE_GZIP=0 writes no compression section" \
  test "$(php_jit_path_sections "$TMP/jit-angie" | grep -c '^zlib\.output_compression')" -eq 0
PHP_PAGE_GZIP=1
rm -f "$TMP/jit-angie/conf.d/chev.conf" "$TMP/jit-angie/h5bp/wordpress_cache.conf"
printf 'server {\n    root %s/jit-wp/public;\n    include h5bp/php_wp.conf;\n}\n' "$TMP" > "$TMP/jit-angie/conf.d/wp.conf"

# A systemd drop-in with unchanged content is not rewritten (no mtime bump,
# so systemd does not ask for a daemon-reload).
mkdir -p "$TMP/dropin"
check "a new drop-in is reported as changed" \
  write_service_limits_dropin "$TMP/dropin/limits.conf" $'[Service]\nLimitNOFILE=1'
touch -d '2001-01-01 00:00:00' "$TMP/dropin/limits.conf"
# Compare epochs, not a calendar year: the same instant renders as 2000 or
# 2001 depending on the host timezone (the audit host was used in UTC+8 and
# restored to UTC-8, which made this check fail without any code change).
dropin_mtime=$(stat -c %Y "$TMP/dropin/limits.conf")
check "an identical drop-in is reported as unchanged" \
  not write_service_limits_dropin "$TMP/dropin/limits.conf" $'[Service]\nLimitNOFILE=1'
check "an identical drop-in keeps its mtime" \
  test "$(stat -c %Y "$TMP/dropin/limits.conf")" = "$dropin_mtime"
check "a changed drop-in is rewritten" \
  write_service_limits_dropin "$TMP/dropin/limits.conf" $'[Service]\nLimitNOFILE=2'

# Extensions a previous --upgrade-php could not install stay wanted.
PHP_UPGRADE_SKIPPED=("imagick (php8.5-imagick: php8.6-imagick is not published)" "redis (php8.5-redis: php8.6-redis is not published yet)")
PHP_UPGRADE_PENDING_FILE="$TMP/pending/php-pending-extensions"
php_upgrade_record_pending
check "skipped extensions are recorded for the next upgrade" \
  test "$(tr '\n' ' ' < "$PHP_UPGRADE_PENDING_FILE")" = "imagick redis "
PHP_UPGRADE_SKIPPED=()
php_upgrade_record_pending
check "the pending list is removed once nothing is missing" \
  test ! -e "$PHP_UPGRADE_PENDING_FILE"


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
# Same basis as tune_angie_configs: mem_total_mb is capped by a cgroup
# memory limit, which raw MemTotal is not (docker --memory=4g on a big host).
mem_kb=$(( $(mem_total_mb) * 1024 ))
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
# The current server-configs-nginx tree already ships `off`: a second pass
# has nothing to rewrite and must not report six "tune not applied" warnings
# on every fresh install.
tune_reset_changes
angie_disable_php_keep_conn "$TMP/angie"
check "fastcgi_keep_conn already off is not a missed tune" \
  test "${#TUNE_MISSES[@]}" -eq 0
check "fastcgi_keep_conn already off is not reported as a change" \
  test "${#TUNE_CHANGES[@]}" -eq 0
check "the Elasticsearch drop-in creates logs 0640 (UMask=0027)" \
  grep -q 'UMask=0027' <(declare -f elasticsearch_write_systemd_limits)
check "the CPU governor uses a native unit, not the SysV cpufrequtils package" \
  test "$(declare -f configure_cpu_governor | grep -c 'apt_install cpufrequtils')" -eq 0
check "the CPU governor unit escapes the shell variable for systemd" \
  grep -qF '"$$f"' <(declare -f configure_cpu_governor)
# ufw reloads its own sysctl file on every start; it must agree with the
# managed profile or install, --optimize and a reboot end with different
# log_martians values.
printf 'net/ipv4/icmp_echo_ignore_all=0\nnet/ipv4/conf/all/log_martians=0\nnet/ipv4/conf/default/log_martians=0\n' > "$TMP/ufw-sysctl.conf"
printf 'net.ipv4.conf.all.log_martians = 1\nnet.ipv4.conf.default.log_martians = 1\n' > "$TMP/profile-sysctl.conf"
ufw_align_sysctl "$TMP/ufw-sysctl.conf" "$TMP/profile-sysctl.conf" >/dev/null
check "ufw sysctl file follows the managed log_martians value" \
  test "$(grep -c 'log_martians=1$' "$TMP/ufw-sysctl.conf")" -eq 2
check "ufw sysctl alignment leaves unrelated keys alone" \
  grep -qx 'net/ipv4/icmp_echo_ignore_all=0' "$TMP/ufw-sysctl.conf"
cp "$TMP/ufw-sysctl.conf" "$TMP/ufw-sysctl.before"
ufw_align_sysctl "$TMP/ufw-sysctl.conf" "$TMP/profile-sysctl.conf" >/dev/null
check "ufw sysctl alignment is idempotent" \
  cmp -s "$TMP/ufw-sysctl.conf" "$TMP/ufw-sysctl.before"
printf '# no martian keys\n' > "$TMP/profile-empty.conf"
ufw_align_sysctl "$TMP/ufw-sysctl.conf" "$TMP/profile-empty.conf" >/dev/null
check "ufw sysctl alignment does nothing without a managed value" \
  cmp -s "$TMP/ufw-sysctl.conf" "$TMP/ufw-sysctl.before"
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

# The deploy path validates the synced tree before angie_apply_profile runs,
# so it must apply the nested-include migration first (a hand-written vhost
# may include php_xf.conf inside a location; the named location is
# server-level only and angie -t fails otherwise).
deploy_body=$(declare -f deploy_angie_tree)
check "the Angie deploy test migrates nested XF includes first" \
  bash -c 'a=$(grep -n "angie_migrate_guest_cache_includes" <<<"$1" | head -1 | cut -d: -f1); b=$(grep -n "angie -t" <<<"$1" | head -1 | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]' _ "$deploy_body"

# A PHP include that only holds locations has no FastCGI buffers of its own:
# h5bp/php_wp.conf now includes h5bp/php_wp_handler.conf for the handler, so
# the buffer tuner must skip it instead of reporting three misses per install.
mkdir -p "$TMP/angie-include"
cp -a "$FIXTURES/." "$TMP/angie-include/"
printf 'location ~ \\.php$ { include h5bp/php_wp_handler.conf; }\n' \
  > "$TMP/angie-include/h5bp/php_wp.conf"
printf 'fastcgi_pass local_php;\nfastcgi_buffer_size 1k;\nfastcgi_buffers 8 8k;\nfastcgi_busy_buffers_size 16k;\n' \
  > "$TMP/angie-include/h5bp/php_wp_handler.conf"
tune_reset_changes
tune_angie_configs "$TMP/angie-include"
check "an include without fastcgi_pass is not a missed buffer tune" \
  test -z "$(printf '%s\n' "${TUNE_MISSES[@]}" | grep 'php_wp.conf' || true)"
check "the shared PHP handler fragment is still tuned" \
  not grep -q 'fastcgi_buffer_size 1k;' "$TMP/angie-include/h5bp/php_wp_handler.conf"

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
# mb_to_config writes a whole GiB as G (a 4096 MB budget gives max_size=2G).
check "active fastcgi_cache.conf gains a max_size" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+[MG]' \
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
cache_mem_mb=$(mem_total_mb)
# Same RAM (cgroup-capped) and disk basis as the tuner (cache filesystem size,
# capped at 10x its free space).  The test used plain free space on /var/www: equal to the tuner's
# number only while RAM is the binding cap, so a CI runner with a small,
# fuller disk failed this check on every push.
cache_disk_mb=$(angie_disk_free_mb)
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
# Memory booked outside the service settings: ES direct memory, huge pages
# ---------------------------------------------------------------------------
esd=$TMP/esd; mkdir -p "$esd"
check "no jvm.options.d drop-in: no operator direct memory" \
  test -z "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)"
printf '%s\n' '-XX:MaxDirectMemorySize=768m' > "$esd/a.options"
printf '%s\n' '-XX:MaxDirectMemorySize=1g' > "$esd/b.options"
check "operator direct memory: the last drop-in wins (1g = 1024 MB)" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 1024
rm -f "$esd"/*.options
printf '%s\n' '17-:-XX:MaxDirectMemorySize=1048576k' > "$esd/a.options"
check "operator direct memory accepts a version prefix and k units" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 1024
printf '%s\n' '-XX:MaxDirectMemorySize=536870912' > "$esd/a.options"
check "operator direct memory in bytes is converted to MB" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 512
printf '%s\n' '# -XX:MaxDirectMemorySize=2g' > "$esd/a.options"
check "a commented MaxDirectMemorySize is ignored" \
  test -z "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)"
rm -f "$esd"/*.options
printf '%s\n' '-XX:MaxDirectMemorySize=4g' > "$esd/zz-setup-optimize.options"
check "the managed zz-setup-optimize.options is never an operator input" \
  test -z "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)"
rm -f "$esd"/*.options
printf '%s\n' '-XX:MaxDirectMemorySize=08m' > "$esd/a.options"
check "a leading zero is decimal (08m = 8 MB), never an octal or an abort" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 8
printf '%s\n' '-XX:MaxDirectMemorySize=1g' '9-16:-XX:MaxDirectMemorySize=4g' '8:-XX:MaxDirectMemorySize=6g' > "$esd/a.options"
check "a JDK-version line for another JDK is skipped (JDK 21: 1 GB stays)" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 1024
printf '%s\n' '17-:-XX:MaxDirectMemorySize=2g' >> "$esd/a.options"
check "an open JDK range that includes the running JDK applies (17-:)" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/no-main" 21)" = 2048
rm -f "$esd"/*.options
printf '%s\n' '-Xms2g' '-XX:MaxDirectMemorySize=4g' > "$esd/main.jvm"
check "the main jvm.options is read (an ES 7-era host keeps its ceiling there)" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/main.jvm" 21)" = 4096
printf '%s' '-XX:MaxDirectMemorySize=512m' > "$esd/b.options"
check "a drop-in overrides the main file, even without a final newline" \
  test "$(elasticsearch_operator_direct_mb "$esd" "$esd/main.jvm" 21)" = 512
rm -f "$esd"/*.options "$esd/main.jvm"
printf 'JAVA_VERSION="23.0.2"\n' > "$esd/release"
check "the bundled JDK major is read from its release file" \
  test "$(elasticsearch_jdk_major "$esd/release")" = 23
check "an unknown JDK counts as 21" test "$(elasticsearch_jdk_major "$esd/none")" = 21
for args in '512 0 0:256' '913 0 0:457' '1000 0 0:500' '512 0 206:50' '512 0 300:0' '2048 1024 0:1024'; do
  # shellcheck disable=SC2086
  check "es_direct_booked_mb ${args%%:*} = ${args##*:}" \
    test "$(es_direct_booked_mb ${args%%:*})" = "${args##*:}"
done
hp_case() { # ram predicate container -> MB
  (
    hp_php=$2 hp_ct=$3
    hugepages_php_present() { (( hp_php )); }
    host_is_container() { (( hp_ct )); }
    hugepages_reserved_mb "$1"
  ) 2>/dev/null
}
check "huge pages booked on a 128 GB host with PHP: 592 MB" test "$(hp_case 131072 1 0)" = 592
check "huge pages booked on a 62 GB host with PHP: 592 MB" test "$(hp_case 63488 1 0)" = 592
check "huge pages booked on a 4 GB host with PHP: 304 MB" test "$(hp_case 4096 1 0)" = 304
check "no huge pages below 4 GB" test "$(hp_case 3910 1 0)" = 0
check "no huge pages without PHP" test "$(hp_case 131072 0 0)" = 0
check "no huge pages booked in a container" test "$(hp_case 131072 1 1)" = 0
check "the booking is the sysctl reservation (pages x 2 MB)" \
  test "$(hp_case 27812 1 0)" -eq $(( $(sysctl_hugepages_target 27812 1) * 2 ))
check "configure_sysctl and the plan share one PHP predicate" \
  bash -c 'b=$(sed -n "/^configure_sysctl()/,/^}/p" "$1"); grep -q hugepages_php_present <<<"$b" && ! grep -qF -- "-d /etc/php" <<<"$b"' _ "$ROOT/lib/os.sh"
check "the plan books from the helpers, never the live HugePages count" \
  bash -c 'b=$(sed -n "/^plan_memory_budget()/,/^}/p" "$1"); grep -q hugepages_reserved_mb <<<"$b" && grep -q es_direct_booked_mb <<<"$b" && ! grep -qE "nr_hugepages|HugePages_Total" <<<"$b"' _ "$ROOT/lib/optimize.sh"
check "write_es_jvm_options never writes MaxDirectMemorySize (booked, not capped)" \
  bash -c '! sed -n "/^write_es_jvm_options()/,/^}/p" "$1" | grep -q MaxDirectMemorySize' _ "$ROOT/lib/service-optimizers.sh"

# ---------------------------------------------------------------------------
# Shared memory budget
# ---------------------------------------------------------------------------
# Keep these tests independent of any PHP-FPM pool that happens to run on the
# machine executing the suite; the real helper measures the live pool, and a
# fixed 96 MB keeps the arithmetic asserted below stable.
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
# No current maxmemory and no installed cache by default: the planner then
# never probes the machine running the suite (the cache-guard tests below
# set these explicitly).
valkey_current_maxmemory_mb() { printf '0'; }
valkey_policy_evicts() { printf '1'; }
valkey_active_conf() { :; }
elasticsearch_data_dir_size_mb() { printf '0'; }
valkey_data_size_mb() { printf '0'; }
# The suite runs on servers that have /etc/php and Elasticsearch drop-ins:
# no huge pages and no operator direct memory unless a case sets them.
hugepages_php_present() { return 1; }
host_is_container() { return 1; }
elasticsearch_operator_direct_mb() { :; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "PHP budget is at most 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 131072 * 50 / 100 ))
check "service budgets stay under 95% of RAM" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
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
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
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

# The buffer pool is sized from the live data+index size plus 5% for growth
# (a working-set cache, not a mirror of the database).  A mixed host caps it
# at half of RAM; a database-only host may use 80% of RAM.
# A 20 GB database therefore gets 21 GB (the cap is not reached on 64 GB).
mariadb_data_size_mb() { printf '20000'; }
plan_memory_budget
check "live pool is data+5% for a 20 GB database" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 21000
check "database-fit plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le $(( 65536 * 80 / 100 ))

# Measured regression guard: a pool smaller than the working set turns random
# reads into disk I/O.  On the audit host a 935 MB table answered 71 k point
# queries/s with a 128 MB pool and 92% physical reads, 212 k/s with a pool
# that held the table (1.7 GB) and none.  A 935 MB database must therefore
# get a pool of at least its own size.
mem_total_mb() { printf '25600'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '935'; }
OPT_DETECTED=(angie php:8.5 mariadb)
plan_memory_budget
check "a 935 MB database is not under-sized" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 981

# An empty database cannot be sized from data; the RAM-proportional floor
# gives the pool room before the next --optimize.  A live database with only
# a few MB of rows gets the 128 MB operational minimum instead.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '81'; }
elasticsearch_data_size_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "tiny live database uses the 128 MB minimum" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 128
check "tiny database stays far below RAM/4" \
  test "$OPT_MARIADB_BUDGET_MB" -le $(( 262144 / 4 ))
check "tiny database floor stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
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
check "live pool for a 40 GB database is capped at half of RAM" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 32768
check "40 GB database pool stays proportional, not data-sized" \
  test "$OPT_DB_SIZE_MB" -eq 40960 -a "$OPT_MARIADB_BUDGET_MB" -eq 32768

# A pool far above the data+5% target is shrunk to it (online, no restart):
# the RAM it held beyond the data was booked for nothing.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '100000'; }
mariadb_data_size_mb() { printf '73599'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey)
plan_memory_budget
check "a live pool far above data+5% shrinks to it (73599 MB + 5% = 77278 MB)" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278
check "a shrunk pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0
check "data-sized pool keeps the plan inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le $(( 262144 * 80 / 100 ))

# A pool within one 5% step plus one 128 MB chunk of the target is kept, so
# a few MB of data growth does not resize the pool on every run.
mariadb_current_pool_mb() { printf '81000'; }
plan_memory_budget
check "a live pool inside the keep band (81000 <= 77278 + 3863 + 128) is kept" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 81000:81000
mariadb_current_pool_mb() { printf '81300'; }
plan_memory_budget
check "a live pool just above the keep band shrinks to data+5%" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 77278:0
mariadb_current_chunk_mb() { printf '1024'; }
plan_memory_budget
check "a 1 GB live chunk widens the keep band (81300 MB is kept, no resize every run)" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 81300:81300
mariadb_current_chunk_mb() { printf '0'; }

# A live pool far above the plan is reduced (here by the data+5% rule; the
# 80%-of-RAM plan stays the hard ceiling either way).
mariadb_current_pool_mb() { printf '250000'; }
plan_memory_budget
check "pool above the shared budget is capped" \
  test "$OPT_MARIADB_BUDGET_MB" -lt 209715
check "capped pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0

# A database larger than the shared budget receives the capped pool.
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '300000'; }
plan_memory_budget
check "a database larger than the shared budget is capped at half of RAM" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 131072
check "capped data-sized plan still fits the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le $(( 262144 * 80 / 100 ))

# A MariaDB-only host reserves no PHP budget; the database pool is funded first.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '60000'; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only host reserves no PHP budget" \
  test "$OPT_PHP_BUDGET_MB" -eq 0
# 60 GB + 5% = 63 GB, above the 80%-of-64-GB cap (52 428 MB).
check "MariaDB-only host caps a 60 GB database at 80% of RAM" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 52428

# Unknown data size (query failed) on a live service is treated like an empty
# database: the 128 MB minimum, never a RAM-sized guess.
mariadb_data_size_mb() { printf ''; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only unknown data uses the 128 MB minimum" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 128

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
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
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

# ENABLED is "declare -A" in lib/cli.sh (sourced at run time): the keys are
# strings, not arithmetic variables (ShellCheck 0.11 reads them as such).
# shellcheck disable=SC2154
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

# Red health names the indices whose primary is unassigned (a live host's
# red came from two 2024 system data streams, every application index fine).
esred_shards='site_f_example                                  0 r UNASSIGNED
.ds-ilm-history-7-2024.12.03-000002           0 p UNASSIGNED
site_b_net                                  0 p STARTED
.ds-.logs-deprecation.elasticsearch-default-2024.11.26-000001 0 p UNASSIGNED
.ds-ilm-history-7-2024.12.03-000002           1 p UNASSIGNED'
check "unassigned primaries: only primaries, de-duplicated, sorted" \
  test "$(awk '{print $1, $3, $4}' <<<"$esred_shards" | elasticsearch_unassigned_primary_indices | tr '\n' ' ')" \
       = ".ds-.logs-deprecation.elasticsearch-default-2024.11.26-000001 .ds-ilm-history-7-2024.12.03-000002 "
esred_run() {
  (
    ESRED_SHARDS=$1
    elasticsearch_http_url() { printf 'http://127.0.0.1:9200'; }
    elasticsearch_wait_primaries() { :; }
    curl() {
      case "$*" in
        *_cluster/health*) printf '%s' '{"status":"red","number_of_nodes":1,"unassigned_shards":6,"unassigned_primary_shards":2}' ;;
        *_cat/shards*) printf '%s\n' "$ESRED_SHARDS" ;;
        *) return 22 ;;
      esac
    }
    OPT_REPORT=()
    elasticsearch_fix_single_node_replicas
    printf '%s\n' "${OPT_REPORT[@]}"
  )
}
out=$(esred_run "$(awk '{print $1, $3, $4}' <<<"$esred_shards")")
check "red health report names the indices with an unassigned primary" \
  grep -qF 'Cluster health: red; unassigned primary shard(s) in: .ds-.logs-deprecation.elasticsearch-default-2024.11.26-000001, .ds-ilm-history-7-2024.12.03-000002.' <<<"$out"
check "red health report leaves the cluster unchanged and points at allocation/explain" \
  bash -c 'grep -q "_cluster/allocation/explain" <<<"$1" && grep -q "(left unchanged)" <<<"$1"' _ "$out"
out=$(esred_run "$(for i in 1 2 3 4 5 6 7; do printf 'idx%s p UNASSIGNED\n' "$i"; done)")
check "red health report caps the list at five and counts the rest" \
  grep -qF 'idx1, idx2, idx3, idx4, idx5 (+2 more).' <<<"$out"
out=$(esred_run "")
check "red health without a shard list keeps the generic line" \
  grep -qF 'Cluster health: red (not a single-node replica issue; left unchanged)' <<<"$out"

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
network.host: 2001:db8:221:1be1::2
EOF
check "Elasticsearch HTTP URL brackets an IPv6 host" \
  test "$(elasticsearch_http_url "$TMP/es-http-ipv6.yml")" = "http://[2001:db8:221:1be1::2]:9200"

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
# The installer block followed by an operator override: PHP keeps the last
# assignment, and the cache block uses the manual's array-literal form.
cat > "$TMP/xf-config-override.php" <<'EOF'
<?php
$config['db']['host'] = 'localhost';
$config['db']['port'] = 3306;
$config["db"]["host"] = "p:localhost";
$config['cache']['enabled'] = true;
$config['cache']['provider'] = 'Redis';
$config['cache']['config'] = [
    'host' => '/run/valkey/valkey.sock',
    'port' => 0,
    'database' => 1,
];
EOF
check "XenForo DB host parser keeps the last assignment" \
  test "$(xf_db_host_from_config "$TMP/xf-config-override.php")" = p:localhost
check "XenForo cache host parser reads the array-literal form" \
  test "$(xf_cache_host_from_config "$TMP/xf-config-override.php")" = /run/valkey/valkey.sock
check "XenForo cache port parser reads the array-literal form" \
  test "$(xf_cache_port_from_config "$TMP/xf-config-override.php")" = 0
printf '<?php\n$config["cache"]["config"] = array("host" => "127.0.0.1", "port" => "6379");\n' > "$TMP/xf-config-tcp.php"
check "XenForo cache parser reads a one-line array() with a TCP endpoint" \
  test "$(xf_cache_host_from_config "$TMP/xf-config-tcp.php"):$(xf_cache_port_from_config "$TMP/xf-config-tcp.php")" = 127.0.0.1:6379
printf '<?php\n$config["db"]["host"] = "localhost";\n' > "$TMP/xf-config-nocache.php"
cat > "$TMP/xf-config-sv.php" <<'EOF'
<?php
$config['cache']['provider']  = 'SV\RedisCache\Redis';
$config['cache']['config']    = [
    'host'     => '/run/valkey/valkey.sock',
    'port'     => 0,
    'database' => 1
];
EOF
check "XenForo cache parser reads the SV RedisCache array form" \
  test "$(xf_cache_host_from_config "$TMP/xf-config-sv.php"):$(xf_cache_port_from_config "$TMP/xf-config-sv.php")" = /run/valkey/valkey.sock:0
check "XenForo cache parser reports no backend when none is configured" \
  test -z "$(xf_cache_host_from_config "$TMP/xf-config-nocache.php")"
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

# The WordPress guest cache is enabled by default: a vhost without the
# include gets it added before the php_wp include; SETUP_WP_GUEST_CACHE=0
# keeps it off and reports the vhost.
mkdir -p "$TMP/wpguest/conf.d" "$TMP/wpguest/h5bp" "$TMP/wpguest/http.d" \
         "$TMP/wpguest-root"
printf 'include http.d/*.conf;\n' > "$TMP/wpguest/angie.conf"
printf 'fastcgi_cache_path /home/nginx_cache levels=1:2 keys_zone=fastcgicache:64m max_size=1g inactive=1h use_temp_path=off;\n' \
  > "$TMP/wpguest/http.d/fastcgi_cache.conf"
printf 'map $request_uri $skip_cache { default 0; }\n' \
  > "$TMP/wpguest/http.d/wordpress_cache_map.conf"
printf '# wordpress guest cache\n' > "$TMP/wpguest/h5bp/wordpress_cache.conf"
printf 'location ~ [^/]\\.php(/|$) { fastcgi_pass local_php; }\n' \
  > "$TMP/wpguest/h5bp/php_wp.conf"
printf '<?php\n' > "$TMP/wpguest-root/wp-config.php"
printf 'server {\n    root %s;\n    include h5bp/php_wp.conf;\n}\n' \
  "$TMP/wpguest-root" > "$TMP/wpguest/conf.d/blog.test.conf"
CONFIG_SOURCE_DIR="$TMP/wpguest"
tune_reset_changes
OPT_REPORT=()
optimize_wordpress_cache "$TMP/wpguest"
check "WordPress guest cache is added by default" \
  grep -q '^    include h5bp/wordpress_cache.conf;' "$TMP/wpguest/conf.d/blog.test.conf"
check "the default WordPress cache add is reported as a change" \
  test "${#TUNE_CHANGES[@]}" -gt 0
sed -i '/include h5bp\/wordpress_cache.conf;/d' "$TMP/wpguest/conf.d/blog.test.conf"
export SETUP_WP_GUEST_CACHE=0
tune_reset_changes
OPT_REPORT=()
optimize_wordpress_cache "$TMP/wpguest"
check "SETUP_WP_GUEST_CACHE=0 keeps the include off" \
  bash -c '! grep -q "include h5bp/wordpress_cache.conf" "$1"' _ "$TMP/wpguest/conf.d/blog.test.conf"
check "the WordPress cache opt-out is reported" \
  grep -q 'SETUP_WP_GUEST_CACHE=0' <<<"${OPT_REPORT[*]}"

# A hand-written vhost that includes only h5bp/wordpress.conf (its own PHP
# location, no php_wp include) has no safe anchor.  It must be reported as
# unanchored, not as an operator opt-out.
printf '# wordpress static rules\n' > "$TMP/wpguest/h5bp/wordpress.conf"
printf 'server {\n    root %s;\n    include h5bp/wordpress.conf;\n    location ~ [^/]\\.php(/|$) { fastcgi_pass local_php; }\n}\n' \
  "$TMP/wpguest-root" > "$TMP/wpguest/conf.d/manual.test.conf"
unset SETUP_WP_GUEST_CACHE
tune_reset_changes
OPT_REPORT=()
optimize_wordpress_cache "$TMP/wpguest"
check "an unanchorable WordPress vhost is not called an opt-out" \
  bash -c '! grep -q "SETUP_WP_GUEST_CACHE=0" <<<"$1"' _ "${OPT_REPORT[*]}"
check "an unanchorable WordPress vhost is reported" \
  grep -q 'no h5bp/php_wp.conf include' <<<"${OPT_REPORT[*]}"
check "the cache include is not inserted into an unanchorable vhost" \
  bash -c '! grep -q "include h5bp/wordpress_cache.conf" "$1"' _ "$TMP/wpguest/conf.d/manual.test.conf"
rm -f "$TMP/wpguest/conf.d/manual.test.conf" "$TMP/wpguest/h5bp/wordpress.conf"
unset SETUP_WP_GUEST_CACHE CONFIG_SOURCE_DIR

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
  bash -c 'grep -q "setup_xf_key_style" "$1" && grep -q "setup_xf_key_language" "$1" && ! grep -q "cookie_xf_" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
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
printf 'location ~ [^/]\\.php(/|$) {\n    fastcgi_pass local_php;\n    add_header X-Cache-Status $upstream_cache_status;\n}\n' > "$TMP/xfguest/h5bp/php_xf_proxy.conf"
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
check "the XenForo status header uses the shared X-Cache-Status name" \
  grep -q '^add_header X-Cache-Status \$upstream_cache_status always;$' "$TMP/xfguest/h5bp/php_xf.conf"
# Older includes used X-5m-Cache; the tuner renames it so every application
# reports the same header.
sed -i 's/add_header X-Cache-Status/add_header X-5m-Cache/' "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "a legacy X-5m-Cache header is renamed to X-Cache-Status" \
  bash -c '! grep -q "X-5m-Cache" "$1" && grep -q "add_header X-Cache-Status" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
check "HSTS is re-included inside the cached PHP location" \
  grep -q '^include h5bp/security/strict-transport-security.conf;' "$TMP/xfguest/h5bp/php_xf.conf"
check "Referrer-Policy is re-included inside the proxy PHP location" \
  grep -q '^include h5bp/security/referrer-policy.conf;' "$TMP/xfguest/h5bp/php_xf_proxy.conf"
check "the proxy include keeps its closing brace last" \
  test "$(tail -n1 "$TMP/xfguest/h5bp/php_xf_proxy.conf")" = '}'
# Cookie safety.  A single-location include serves guests and members from
# the same block, so it must never store a response that sets a cookie
# (ignoring Set-Cookie there replayed the first visitor's xf_csrf to every
# guest); hiding the header is only possible in the split include.
check "single-location XenForo cache does not ignore Set-Cookie" \
  bash -c 'grep -q "^fastcgi_ignore_headers Cache-Control Expires;" "$1" && ! grep -q "fastcgi_hide_header" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
printf 'location ~ [^/]\\.php(/|$) {\nfastcgi_cache fastcgicache;\nfastcgi_ignore_headers  Cache-Control Expires Set-Cookie;\n}\n' > "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "legacy single-location include stops ignoring Set-Cookie" \
  bash -c 'grep -q "^fastcgi_ignore_headers  Cache-Control Expires;" "$1" && ! grep -q "Set-Cookie" "$1"' _ "$TMP/xfguest/h5bp/php_xf.conf"
# The repository include: uncached PHP location plus @xf_guest_cache.
cat > "$TMP/xfguest/h5bp/php_xf.conf" <<'EOF'
error_page 418 = @xf_guest_cache;
location ~ [^/]\.php(/|$) {
if ($xf_guest_cacheable) { return 418; }
fastcgi_pass local_php;
}
location @xf_guest_cache {
fastcgi_pass local_php;
fastcgi_ignore_headers  Cache-Control Expires Set-Cookie;
fastcgi_cache           fastcgicache;
}
EOF
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "split XenForo include keeps ignoring Set-Cookie for the cache" \
  grep -q '^fastcgi_ignore_headers  Cache-Control Expires Set-Cookie;' "$TMP/xfguest/h5bp/php_xf.conf"
check "split XenForo include hides Set-Cookie on cached guest pages" \
  test "$(grep -c '^fastcgi_hide_header Set-Cookie;' "$TMP/xfguest/h5bp/php_xf.conf")" -eq 1
check "the repaired cache directives land in @xf_guest_cache, not the member location" \
  test "$(awk '/^location @xf_guest_cache/{f=1} f && /^fastcgi_(hide_header|cache_key|no_cache|cache_valid)/{n++} !f && /^fastcgi_(hide_header|cache_key|no_cache|cache_valid|cache )/{bad++} END{print (n >= 4 && bad == 0) ? "ok" : "bad"}' "$TMP/xfguest/h5bp/php_xf.conf")" = ok
check "the member location still hands guests to the named location" \
  grep -q '^if (\$xf_guest_cacheable) { return 418; }' "$TMP/xfguest/h5bp/php_xf.conf"
tune_reset_changes
ensure_xf_guest_cache "$TMP/xfguest"
check "split XenForo include repair is idempotent" \
  test "${#TUNE_CHANGES[@]}" -eq 0

# Vhost include migration: the Chevereto server-level include moves to the
# cookie-safe cache variant, a nested one stays; a nested php_xf.conf include
# becomes php.conf (a named location is server-level only).
mkdir -p "$TMP/gcm/conf.d" "$TMP/gcm/h5bp"
: > "$TMP/gcm/h5bp/php_chev_cache.conf"
printf 'location @xf_guest_cache {\n}\n' > "$TMP/gcm/h5bp/php_xf.conf"
cat > "$TMP/gcm/conf.d/chev.conf" <<'EOF'
server {
    listen 80;
    return 301 https://chev.example$request_uri;
}
server {
    root /var/www/chev.example/public;
    location ~* \.(gif|jpg)$ { expires 365d; }
    location ~ "^/a{2}" { return 403; }
    location ~ ^/(dashboard|update) {
        include h5bp/php_chev.conf;
    }
    # include h5bp/php_chev.conf;
    include h5bp/php_chev.conf;
    include h5bp/basic.conf;
}
EOF
cat > "$TMP/gcm/conf.d/xf.conf" <<'EOF'
server {
    location ~ ^/(admin.php|install) {
        include h5bp/php_xf.conf;
    }
    include h5bp/php_xf.conf;
}
EOF
cp "$TMP/gcm/conf.d/chev.conf" "$TMP/gcm/chev.before"
tune_reset_changes
angie_migrate_guest_cache_includes "$TMP/gcm"
check "Chevereto server-level include moves to php_chev_cache.conf" \
  grep -qx '    include h5bp/php_chev_cache.conf;' "$TMP/gcm/conf.d/chev.conf"
check "Chevereto nested include stays on the uncached php_chev.conf" \
  grep -qx '        include h5bp/php_chev.conf;' "$TMP/gcm/conf.d/chev.conf"
check "a commented-out include is left alone" \
  grep -qx '    # include h5bp/php_chev.conf;' "$TMP/gcm/conf.d/chev.conf"
check "the Chevereto migration changes exactly one line" \
  test "$(diff "$TMP/gcm/chev.before" "$TMP/gcm/conf.d/chev.conf" | grep -c '^>')" -eq 1
check "a nested php_xf.conf include becomes php.conf" \
  grep -qx '        include h5bp/php.conf;' "$TMP/gcm/conf.d/xf.conf"
check "the server-level php_xf.conf include is kept" \
  grep -qx '    include h5bp/php_xf.conf;' "$TMP/gcm/conf.d/xf.conf"
check "the include migration reports both vhosts" \
  test "${#TUNE_CHANGES[@]}" -eq 2
tune_reset_changes
angie_migrate_guest_cache_includes "$TMP/gcm"
check "the include migration is idempotent" \
  test "${#TUNE_CHANGES[@]}" -eq 0

# A one-line `location /x/ { include ...; }` is nested too.  Without this the
# canonical php_xf.conf (server-level named location) makes `angie -t` fail
# and the whole tree is rolled back.
cat > "$TMP/gcm/conf.d/xf1line.conf" <<'EOF'
server {
    location /legacy/ { include h5bp/php_xf.conf; }
    include h5bp/php_xf.conf;
}
EOF
tune_reset_changes
angie_migrate_guest_cache_includes "$TMP/gcm"
check "a one-line nested php_xf.conf include becomes php.conf" \
  grep -q 'location /legacy/ { include h5bp/php.conf; }' "$TMP/gcm/conf.d/xf1line.conf"
check "the server-level include beside a one-line location is kept" \
  grep -qx '    include h5bp/php_xf.conf;' "$TMP/gcm/conf.d/xf1line.conf"
rm -f "$TMP/gcm/conf.d/xf1line.conf"
# A Chevereto site with guest uploads enabled keeps (or returns to) the
# uncached include: a cached page cannot carry the visitor's upload token.
cp "$TMP/gcm/chev.before" "$TMP/gcm/conf.d/chev.conf"
rm -f "$TMP/gcm/conf.d/xf.conf"
chevereto_guest_uploads() { printf 1; }
tune_reset_changes; OPT_REPORT=()
angie_migrate_guest_cache_includes "$TMP/gcm"
check "guest uploads enabled: the Chevereto vhost stays uncached" \
  cmp -s "$TMP/gcm/chev.before" "$TMP/gcm/conf.d/chev.conf"
check "guest uploads enabled: the report explains why" \
  grep -q 'allows guest uploads' <<<"${OPT_REPORT[*]}"
SETUP_CHEV_GUEST_CACHE=1 angie_migrate_guest_cache_includes "$TMP/gcm"
check "SETUP_CHEV_GUEST_CACHE=1 forces the Chevereto guest cache on" \
  grep -qx '    include h5bp/php_chev_cache.conf;' "$TMP/gcm/conf.d/chev.conf"
angie_migrate_guest_cache_includes "$TMP/gcm"
check "guest uploads enabled later: the cache include is turned back off" \
  cmp -s "$TMP/gcm/chev.before" "$TMP/gcm/conf.d/chev.conf"
chevereto_guest_uploads() { printf 0; }
SETUP_CHEV_GUEST_CACHE=0 angie_migrate_guest_cache_includes "$TMP/gcm"
check "SETUP_CHEV_GUEST_CACHE=0 keeps the Chevereto guest cache off" \
  cmp -s "$TMP/gcm/chev.before" "$TMP/gcm/conf.d/chev.conf"
chevereto_guest_uploads() { :; }
angie_migrate_guest_cache_includes "$TMP/gcm"
check "unknown guest-upload setting: the cookie-safe cache is used" \
  grep -qx '    include h5bp/php_chev_cache.conf;' "$TMP/gcm/conf.d/chev.conf"
printf "<?php\nreturn [\n    'CHEVERETO_DB_NAME' => 'chevdb', 'CHEVERETO_DB_TABLE_PREFIX' => 'c1_',\n];\n" > "$TMP/chev-env.php"
check "Chevereto env.php parser reads the database name and prefix" \
  test "$(chevereto_env_value "$TMP/chev-env.php" CHEVERETO_DB_NAME):$(chevereto_env_value "$TMP/chev-env.php" CHEVERETO_DB_TABLE_PREFIX)" = chevdb:c1_
# Without the cache variant in the tree (an older config repository) nothing
# is rewritten: the vhost would otherwise point at a missing file.
mkdir -p "$TMP/gcm-old/conf.d" "$TMP/gcm-old/h5bp"
cp "$TMP/gcm/chev.before" "$TMP/gcm-old/conf.d/chev.conf"
angie_migrate_guest_cache_includes "$TMP/gcm-old"
check "no migration without h5bp/php_chev_cache.conf" \
  cmp -s "$TMP/gcm/chev.before" "$TMP/gcm-old/conf.d/chev.conf"
# An include that does not cache has no error policy to repair.
printf 'location ~ [^/]\\.php(/|$) {\nfastcgi_pass local_php;\n}\n' > "$TMP/nocache.conf"
cp "$TMP/nocache.conf" "$TMP/nocache.before"
tune_cache_error_policy "$TMP/nocache.conf" "no cache"
check "cache error policy leaves a non-caching include untouched" \
  cmp -s "$TMP/nocache.conf" "$TMP/nocache.before"
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
cache_removed=$(count_optimize_cache_entries "$now" "$TMP/cachetree")
check "cache report counts objects written during the run" test "$cache_removed" -eq 1
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
check "small host keeps the cache at its 128 MB target, not above" test "$OPT_VALKEY_BUDGET_MB" -eq 128
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
check "MariaDB redo log is 25% of the pool" \
  test "$MARIADB_PROFILE_LOG_SIZE" = 512M
lb_2g=$MARIADB_PROFILE_LOG_BUFFER
check "MariaDB log buffer is RAM-sized (16..64 MB)" \
  bash -c "(( $(size_to_mb "$lb_2g") >= 16 && $(size_to_mb "$lb_2g") <= 64 ))"
# innodb_log_buffer_size is not dynamic: an online pool resize (300 MB -> 600
# MB) must not change it, or --optimize falls back to a full restart.
mariadb_compute_profile 512; lb_512=$MARIADB_PROFILE_LOG_BUFFER
mariadb_compute_profile 1024
check "the log buffer does not follow a 512 MB -> 1 GB pool resize" \
  test "$lb_512" = "$MARIADB_PROFILE_LOG_BUFFER"
# innodb_log_file_size must be at least innodb_log_buffer_size.  A small pool
# (128 MB, the data+5% minimum) lifts its redo log to the buffer instead of
# capping the buffer, so shrinking a 4 GB pool to 128 MB keeps the
# non-dynamic buffer and stays an online resize.
# A 64 GB host (64 MB buffer) is where the old cap bit: 128 MB / 4 = 32 MB
# redo log would have cut the buffer to 32 MB and forced a restart.
mem_total_mb() { printf '65536'; }
mariadb_compute_profile 4096; lb_4g=$MARIADB_PROFILE_LOG_BUFFER
mariadb_compute_profile 128
check "64 GB host: the 64 MB log buffer does not follow a 4 GB -> 128 MB shrink" \
  test "$lb_4g:$MARIADB_PROFILE_LOG_BUFFER" = 64M:64M
check "64 GB host: a 128 MB pool's redo log is lifted to the 64 MB buffer" \
  test "$MARIADB_PROFILE_LOG_SIZE" = 64M
mem_total_mb() { printf '1024'; }
mariadb_compute_profile 128
check "1 GB host: a 128 MB pool keeps its 25% (32 MB) redo log" \
  test "$MARIADB_PROFILE_LOG_SIZE" = 32M
# The online ceiling: 80% of RAM, written as loose- (older 10.11 lacks it),
# and ignored when deciding whether a restart is needed.
check "innodb_buffer_pool_size_max is 80% of RAM, never below the pool" \
  test "$(size_to_mb "$MARIADB_PROFILE_BUFFER_MAX")" -eq "$(( $(mem_total_mb) * 80 / 100 > 128 ? $(mem_total_mb) * 80 / 100 : 128 ))"
check "the pool ceiling is written as a loose- option" \
  grep -q '^loose-innodb_buffer_pool_size_max = ' "$ROOT/lib/services.sh"
cnf_a=$(mktemp); cnf_b=$(mktemp)
printf 'innodb_buffer_pool_size = 4011M\nthread_pool_size = 8\n' > "$cnf_a"
printf 'innodb_buffer_pool_size = 128M\nloose-innodb_buffer_pool_size_max = 51349M\nthread_pool_size = 8\n' > "$cnf_b"
check "adding the pool ceiling alone does not force a restart" cnf_only_pool_changed "$cnf_a" "$cnf_b"
printf 'innodb_buffer_pool_size = 128M\nloose-innodb_buffer_pool_size_max = 51349M\nthread_pool_size = 9\ninnodb_log_buffer_size = 32M\n' > "$cnf_b"
check "a non-dynamic key still forces the restart path" not cnf_only_pool_changed "$cnf_a" "$cnf_b"
rm -f "$cnf_a" "$cnf_b"
check "redo log is never smaller than the log buffer" \
  test "$(size_to_mb "$MARIADB_PROFILE_LOG_SIZE")" -ge "$(size_to_mb "$MARIADB_PROFILE_LOG_BUFFER")"
mariadb_compute_profile 2048
# mysqltuner's 25% ratio has no upper cap: a 16 GB pool gets a 4 GB log on
# every disk class, instead of being silently reduced to 12.5%.
mariadb_compute_profile 16384
check "a 16 GB pool gets a 4 GB redo log (25%, uncapped)" \
  test "$MARIADB_PROFILE_LOG_SIZE" = 4G
check "a 16 GB pool keeps the same RAM-sized log buffer" \
  test "$MARIADB_PROFILE_LOG_BUFFER" = "$lb_2g"
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
eval "$(declare -f pkg_ok | sed '1s/^pkg_ok/pkg_ok_saved/')"
pkg_ok() { return 1; }
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
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le $(( 27812 * 80 / 100 ))
# An installer re-run on a host where MariaDB is installed measures the
# (empty) database like --optimize does: both plan 128 MB, so neither path
# reverses the other (RAM/16 vs 128 MB on every alternate run).
pkg_ok() { [[ $1 == mariadb-server ]]; }
mariadb_data_size_mb() { printf '0'; }
OPT_INSTALL_PLAN=1
plan_memory_budget
OPT_INSTALL_PLAN=0
check "installer re-run on an installed empty database plans 128 MB, like --optimize" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 128
plan_memory_budget
check "--optimize on the same empty database plans the same 128 MB" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 128
# From here on the planner must not depend on whether the machine running
# the suite has MariaDB installed: report it absent, delegate the rest.
pkg_ok() { [[ $1 == mariadb-server ]] && return 1; pkg_ok_saved "$@"; }
mariadb_data_size_mb() { return 0; }

# A database that has just been initialised reports a few MB of system data.
# data+5% is below the operational minimum, so a live database with no
# real rows gets 128 MB.
mariadb_data_size_mb() { printf '4'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "measured-empty live database uses the 128 MB minimum" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 128

# ---------------------------------------------------------------------------
# Live-data protection
# ---------------------------------------------------------------------------
# A live MariaDB pool far above the data+5% target is shrunk to it (online),
# and an Elasticsearch heap above store/4 is reduced to free RAM.
valkey_live_used_mb() { return 0; }
mariadb_data_size_mb() { printf '2048'; }
mariadb_current_pool_mb() { printf '4096'; }
elasticsearch_data_size_mb() { printf '512'; }
elasticsearch_current_heap_mb() { printf '4096'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "live MariaDB pool far above the data+5% target is shrunk" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0 -a "$OPT_MARIADB_BUDGET_MB" -le 2150
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
  test "$OPT_MARIADB_BUDGET_MB" -eq 5250
check "MariaDB+Valkey plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le $(( 27812 * 80 / 100 ))

# Full stack: the data targets are reserved and PHP receives the remainder.
mariadb_data_size_mb() { printf '8000'; }
elasticsearch_data_size_mb() { printf '1000'; }
valkey_live_used_mb() { printf '1000'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
plan_memory_budget
check "full stack reserves MariaDB, Valkey and Elasticsearch first" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 8400 \
       -a "$OPT_VALKEY_BUDGET_MB" -ge 1100 \
       -a "$OPT_ES_BUDGET_MB" -ge 512
check "full stack still gets a viable PHP pool" \
  test "$OPT_PHP_BUDGET_MB" -ge 512 -a "$OPT_PHP_CHILDREN" -ge 8
check "full stack priority plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
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
  local total=$(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB ))
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

# A stock Ubuntu image ships wget but not curl; --optimize must be able to
# fetch its Angie tree without installing a package.
fetch_body=$(declare -f fetch_server_configs)
check "config fetch falls back to wget when curl is absent" \
  grep -q 'wget -q --https-only' <<<"$fetch_body"
check "config fetch still prefers curl" \
  bash -c 'a=$(grep -n "curl -fsSL" <<<"$1" | cut -d: -f1); b=$(grep -n "wget -q" <<<"$1" | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]' _ "$fetch_body"


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
check "php_children_ceiling: explicit value below the hardware target is kept" \
  test "$(php_children_ceiling 8 65536 '' 4)" -eq 4

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
# A 128 MB pool is smaller than the RAM/256 figure (256 MB on this 64 GB
# stub); the cap must still win, with 32 MB as the legal floor.
mariadb_compute_profile 128
check "MariaDB profile: tmp_table_size never exceeds a tiny pool" \
  test "$MARIADB_PROFILE_TMP_MB" -eq 32
mariadb_compute_profile 1024
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
# 512 children (4048 clients) stays under the 10000 floor, so the old
# "-eq 4048 -o -eq 10000" assertion could not see the growth it named.
php_pool_max_children() { printf '3000'; }
check "valkey_maxclients grows with the PHP pool (3000 x 4 + 2000)" \
  test "$(valkey_maxclients)" -eq 14000
php_pool_max_children() { printf '30000'; }
check "valkey_maxclients is capped at 100000" \
  test "$(valkey_maxclients)" -eq 100000
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
# 20000 + 4096 + the 512 MB heap and its 256 MB direct share no longer fit
# beside the PHP floor: the plan says so (stderr) instead of hiding it.
plan_memory_budget 2>/dev/null
check "explicit sizes that crowd out the ES direct share report an overcommit" test "$OPT_MEM_OVERCOMMIT_MB" -gt 0
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
keeps_maxmemory() { valkey_runtime_settings 512 allkeys-lru 1 | grep -qx 'maxmemory 512mb'; }
# The assertion used to sit outside check() (`check ... bash -c "true" && ...`),
# so the check always passed and a failure only tripped set -e.
check "valkey_runtime_settings keeps maxmemory" keeps_maxmemory

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
hostname_valid() {
  validate_hostname web1 && validate_hostname web1.example.com && validate_hostname 16c-32g-1T
}
hostname_invalid() {
  ! validate_hostname a..b && ! validate_hostname a-.b && ! validate_hostname .a \
    && ! validate_hostname "$(printf 'a%.0s' {1..65})"
}
check "hostname validation accepts normal host and FQDN names" hostname_valid
check "hostname validation rejects empty labels, bad labels and >64 chars" hostname_invalid
exempt_valid() {
  tune_valid_exempt_entry 192.0.2.50 && tune_valid_exempt_entry 10.0.0.0/8 \
    && tune_valid_exempt_entry 2001:db8::1 && tune_valid_exempt_entry 2001:db8::/32 \
    && tune_valid_exempt_entry ::1
}
exempt_invalid() {
  ! tune_valid_exempt_entry 10.0.0.256 && ! tune_valid_exempt_entry 10.0.0.5/99 \
    && ! tune_valid_exempt_entry 1.2.3 && ! tune_valid_exempt_entry cafe \
    && ! tune_valid_exempt_entry 1:2:3 && ! tune_valid_exempt_entry ::: \
    && ! tune_valid_exempt_entry 2001:db8::/129
}
check "rate-limit exemption: valid IPv4, IPv6 and CIDR are accepted" exempt_valid
check "rate-limit exemption: malformed addresses/masks are rejected" exempt_invalid
LIMIT_REQ_EXEMPT='10.0.0.256,10.0.0.5/99,cafe,2001:db8::/129,192.0.2.50' tune_limit_req_exemptions "$TMP/limit_req.conf" limit_req.conf
check "tune_limit_req_exemptions writes only the valid subset" \
  bash -c "grep -qx '    192.0.2.50 1; # setup.sh exempt' '$TMP/limit_req.conf' && [ \$(grep -c 'setup.sh exempt' '$TMP/limit_req.conf') -eq 1 ]"
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
# ENABLED is "declare -A" in lib/cli.sh (sourced at run time): the keys are
# strings, not arithmetic variables (ShellCheck 0.11 reads them as such).
# shellcheck disable=SC2154
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

# MariaDB profile: table caches follow max_connections, the redo log is 25%
# of the pool on every disk class (no cap).
php_pool_max_children() { printf 1000; }
mariadb_storage_class() { printf nvme; }
mariadb_io_capacity() { printf '10000 20000'; }
mariadb_compute_profile 32768
check "table_open_cache follows max_connections (1000 workers -> 1300 -> 20800)" \
  test "$MARIADB_PROFILE_OPEN_CACHE" -eq 20800
check "redo log is 8 GB for a 32 GB pool on NVMe (25%)" \
  test "$(size_to_mb "$MARIADB_PROFILE_LOG_SIZE")" -eq 8192
mariadb_storage_class() { printf ssd; }
mariadb_compute_profile 32768
check "redo log stays at 25% on SSD (8 GB, no disk-class cap)" \
  test "$(size_to_mb "$MARIADB_PROFILE_LOG_SIZE")" -eq 8192
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
  bash -c "[[ \$(grep -c 'ENV{DEVTYPE}==\"disk\"' <<<\"\$0\") -eq 4 ]]" "$io_body"
check "md/dm arrays on flash get a readahead-only rule" \
  bash -c 'grep -q "KERNEL==\"md\*|dm-\*\", ATTR{bdi/read_ahead_kb}=\"128\"$" <<<"$1" && ! grep "KERNEL==\"md\*|dm-\*\"" <<<"$1" | grep -q scheduler' _ "$io_body"
check "the md/dm readahead rule is written only for nvme/ssd hosts" \
  bash -c 'grep -B4 "md\\*|dm-" <<<"$1" | grep -q "nvme|ssd)"' _ "$io_body"
check "udev re-trigger skips empty devices (BMC virtual floppies)" \
  grep -q -- "--attr-nomatch=size=0" <<<"$io_body"
check "udev re-trigger is limited to whole disks of the matched names" \
  bash -c 'grep -q -- "--property-match=DEVTYPE=disk" <<<"$1" && ! grep -q "udevadm trigger --subsystem-match=block --action=change" <<<"$1"' _ "$io_body"
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
# A generated vhost (the Anubis TLS terminator, a redirect-only block) has no
# root directive.  The lookup must print nothing and return 0: under
# `set -e` + inherit_errexit the old grep pipeline returned 1 and the
# --upgrade-php preflight (which walks every conf.d file) printed false
# "[ERR] command failed" lines.
printf 'server {\n    listen 443 ssl;\n    server_name term.test;\n}\n' \
  > "$TMP/capsite/conf.d/terminator.conf"
rootless_vhost_ok() { [[ -z $(angie_vhost_root "$TMP/capsite/conf.d/terminator.conf") ]]; }
check "angie_vhost_root returns success with no root directive" rootless_vhost_ok
missing_file_ok() { [[ -z $(angie_vhost_root "$TMP/capsite/conf.d/does-not-exist.conf") ]]; }
check "angie_vhost_root returns success for a missing file" missing_file_ok

# One app detector for the --upgrade-php preflight and the tuners.
mkdir -p "$TMP/apptypes/wp/wp-includes" "$TMP/apptypes/xf/src" \
         "$TMP/apptypes/ch/app" "$TMP/apptypes/plain"
: > "$TMP/apptypes/wp/wp-config.php"; : > "$TMP/apptypes/wp/wp-includes/version.php"
: > "$TMP/apptypes/xf/src/XF.php"; : > "$TMP/apptypes/xf/src/config.php"
: > "$TMP/apptypes/ch/app/env.php"
check "app_type_at_root: wordpress" test "$(app_type_at_root "$TMP/apptypes/wp")" = wordpress
check "app_type_at_root: xenforo"  test "$(app_type_at_root "$TMP/apptypes/xf")" = xenforo
check "app_type_at_root: chevereto" test "$(app_type_at_root "$TMP/apptypes/ch")" = chevereto
check "app_type_at_root: unrelated tree is empty" test -z "$(app_type_at_root "$TMP/apptypes/plain")"
check "app_type_at_root: missing root is empty" test -z "$(app_type_at_root "$TMP/apptypes/nope")"

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
for k in vm.dirty_background_bytes:0 vm.dirty_bytes:0 vm.dirty_background_ratio:10 vm.dirty_ratio:20 net.ipv4.ipfrag_low_thresh:3145728 net.ipv4.ipfrag_high_thresh:4194304 net.ipv6.ip6frag_low_thresh:3145728 net.ipv6.ip6frag_high_thresh:4194304; do
  printf '%s\n' "${k#*:}" > "$SETUP_STATE_DIR/sysctl-orig-${k%%:*}"
done
: > "$TMP/sysctl-order"
sysctl() { [[ $1 == -w ]] && printf '%s\n' "${2%%=*}" >> "$TMP/sysctl-order"; return 0; }
restore_sysctl_values
unset -f sysctl
order_ok() {
  local o; o=$(tr '\n' ' ' < "$TMP/sysctl-order")
  [[ $o == *"vm.dirty_ratio "*"vm.dirty_background_ratio "* && $o != *"vm.dirty_bytes "* && $o != *"vm.dirty_background_bytes "* \
     && $o == *"net.ipv4.ipfrag_high_thresh "*"net.ipv4.ipfrag_low_thresh "* \
     && $o == *"net.ipv6.ip6frag_high_thresh "*"net.ipv6.ip6frag_low_thresh "* ]]
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
check "world-writable fix uses a batched chmod (xargs -0 from the single walk)" \
  grep -q -- 'xargs -0 -r chmod o-w --' <<<"$harden_files_body"
check "world-writable fix does not fork chmod per path" \
  bash -c '! grep -q "chmod o-w \"\$f\"" <<< "$1"' _ "$harden_files_body"
ww_count_before_fix() {
  local n x
  n=$(grep -nF 'world-writable entries: ${count}' <<<"$harden_files_body" | head -n 1 | cut -d: -f1)
  x=$(grep -nF 'xargs -0 -r chmod o-w' <<<"$harden_files_body" | head -n 1 | cut -d: -f1)
  [[ -n $n && -n $x ]] && (( n < x ))
}
check "world-writable fix reports the count before fixing" ww_count_before_fix


# A custom http.d limit file can duplicate an http-context directive that the
# canonical limit_req.conf owns; angie -t refuses to load until one copy is
# commented.  Keep the canonical file and mark the operator copy.
mkdir -p "$TMP/dedupe/http.d"
printf 'limit_req_status 429;\nlimit_req_log_level warn;\n' > "$TMP/dedupe/http.d/limit_req.conf"
printf 'limit_req_status 429;\nlimit_conn_status 429;\nlimit_req_log_level info;\n' > "$TMP/dedupe/http.d/zz-custom.conf"
tune_reset_changes
tune_angie_dedupe_http "$TMP/dedupe"
check "duplicate http directive keeps the canonical file" \
  grep -qx 'limit_req_status 429;' "$TMP/dedupe/http.d/limit_req.conf"
check "duplicate http directive comments the operator copy" \
  grep -qx '# setup.sh: duplicate limit_req_status 429; (kept in http.d/limit_req.conf)' "$TMP/dedupe/http.d/zz-custom.conf"
check "duplicate http directive leaves a unique directive active" \
  grep -qx 'limit_conn_status 429;' "$TMP/dedupe/http.d/zz-custom.conf"
check "duplicate http log level is commented in the operator copy" \
  grep -qx '# setup.sh: duplicate limit_req_log_level info; (kept in http.d/limit_req.conf)' "$TMP/dedupe/http.d/zz-custom.conf"

# ---------------------------------------------------------------------------
# 1.21.0: cache error policy order, validated XenForo key, virtual disks
# ---------------------------------------------------------------------------
cat > "$TMP/cache-order.conf" <<'EOF'
location @c {
fastcgi_cache fastcgicache;
fastcgi_cache_valid 200 5m;
fastcgi_cache_valid any 5s;
fastcgi_cache_valid 500 502 503 504 0s;
}
EOF
tune_reset_changes
tune_cache_error_policy "$TMP/cache-order.conf" "order"
check "5xx rule is moved in front of the any rule" \
  test "$(grep -n 'fastcgi_cache_valid 500' "$TMP/cache-order.conf" | cut -d: -f1)" -lt "$(grep -n 'fastcgi_cache_valid any' "$TMP/cache-order.conf" | cut -d: -f1)"
check "moving the 5xx rule keeps a single copy" \
  test "$(grep -c 'fastcgi_cache_valid 500' "$TMP/cache-order.conf")" -eq 1
check "moving the 5xx rule keeps it inside the location" \
  test "$(tail -n1 "$TMP/cache-order.conf")" = "}"
tune_reset_changes
tune_cache_error_policy "$TMP/cache-order.conf" "order"
check "5xx rule order repair is idempotent" test "${#TUNE_CHANGES[@]}" -eq 0

cat > "$TMP/xf-key-old.conf" <<'EOF'
    fastcgi_cache_key "$request_method$scheme$host$request_uri$cookie_xf_style_variation$cookie_xf_style_id$cookie_xf_language_id$setup_cache_enc";
EOF
tune_xf_cache_vary "$TMP/xf-key-old.conf"
check "a deployed raw-cookie XF key is replaced" \
  bash -c '! grep -q "cookie_xf_" "$1" && grep -q "setup_xf_key_language" "$1"' _ "$TMP/xf-key-old.conf"
check "the replaced XF key keeps its indentation" \
  grep -q '^    fastcgi_cache_key "' "$TMP/xf-key-old.conf"
cat > "$TMP/xf-key-repo.conf" <<'EOF'
fastcgi_cache_key       "$request_method|$scheme|$host|$request_uri|$xf_key_variation|$xf_key_style|$xf_key_language|$xf_key_enc";
EOF
before_key=$(file_md5 "$TMP/xf-key-repo.conf")
tune_xf_cache_vary "$TMP/xf-key-repo.conf"
check "the repository's validated XF key is left alone" \
  test "$(file_md5 "$TMP/xf-key-repo.conf")" = "$before_key"

mkdir -p "$TMP/sysblock/sda/device" "$TMP/sysblock/sdb/device"
printf 'QEMU    \n' > "$TMP/sysblock/sda/device/vendor"
printf 'QEMU HARDDISK\n' > "$TMP/sysblock/sda/device/model"
printf 'ATA     \n' > "$TMP/sysblock/sdb/device/vendor"
printf 'ST4000NM0035\n' > "$TMP/sysblock/sdb/device/model"
SETUP_SYS_BLOCK="$TMP/sysblock"
check "a QEMU SCSI disk is recognised as virtual" block_device_is_virtual sda
check "a physical SATA disk is not virtual" not block_device_is_virtual sdb
unset SETUP_SYS_BLOCK
check "SETUP_STORAGE_CLASS pins the storage class" \
  test "$(SETUP_STORAGE_CLASS=hdd storage_class)" = hdd
check "SETUP_STORAGE_CLASS pins the data-path class too" \
  test "$(SETUP_STORAGE_CLASS=ssd storage_backing_class /var/www)" = ssd
check "an invalid SETUP_STORAGE_CLASS is ignored" \
  test "$(SETUP_STORAGE_CLASS=floppy storage_class)" != floppy

# An explicit --php children= is honoured below the hardware target as well.
check "an explicit worker count below the hardware target is kept" \
  test "$(php_children_ceiling 16 32768 "" 4)" = 4
check "an explicit worker count of one is raised to two" \
  test "$(php_children_ceiling 16 32768 "" 1)" = 2
check "the plan helper returns the explicit worker count" \
  test "$(php_plan_max_children 16 32768 "" 4 0)" = 4


# ---------------------------------------------------------------------------
# Valkey maxmemory: a full cache keeps its size, the guard never ratchets
# ---------------------------------------------------------------------------
# Arguments: planned, used, current maxmemory, hard cap, evicting policy
# (allkeys-*), optional keep band.
check "cache guard: the plan stands when live data has its 20% headroom" \
  test "$(valkey_guard_maxmemory_mb 434 100 434 22249 1)" = "434 plan"
check "cache guard: a full evicting cache keeps its current maxmemory" \
  test "$(valkey_guard_maxmemory_mb 434 512 512 22249 1)" = "512 full"
check "cache guard: used_memory slightly above maxmemory still counts as full" \
  test "$(valkey_guard_maxmemory_mb 434 520 512 22249 1)" = "512 full"
check "cache guard: a full cache below the plan takes the plan, not used+20%" \
  test "$(valkey_guard_maxmemory_mb 434 400 400 22249 1)" = "434 plan"
check "cache guard: a full noeviction cache follows its data (keys cannot be evicted)" \
  test "$(valkey_guard_maxmemory_mb 434 512 512 22249 0)" = "614 raised"
check "cache guard: noeviction data above maxmemory still gets headroom" \
  test "$(valkey_guard_maxmemory_mb 434 600 512 22249 0)" = "720 raised"
check "cache guard: data above the current maxmemory is given headroom" \
  test "$(valkey_guard_maxmemory_mb 434 600 512 22249 1)" = "720 raised"
check "cache guard: an unlimited or unknown maxmemory follows live data" \
  test "$(valkey_guard_maxmemory_mb 434 3000 0 22249 1)" = "3600 raised"
check "cache guard: a half-empty cache is sized to live data, not kept" \
  test "$(valkey_guard_maxmemory_mb 434 1000 2000 22249 1)" = "1200 raised"
check "cache guard: live data beyond the host is capped" \
  test "$(valkey_guard_maxmemory_mb 434 30000 0 22249 0)" = "22249 capped"
check "cache guard: a maxmemory above the hard cap is not kept" \
  test "$(valkey_guard_maxmemory_mb 434 30000 30000 22249 1)" = "22249 capped"
check "cache guard: a scaled-down share never evicts a full cache" \
  test "$(valkey_guard_maxmemory_mb 300 1000 1000 1638 1)" = "1000 full"
check "cache guard: a maxmemory up to 10% above data+20% is kept (no drift rewrite)" \
  test "$(valkey_guard_maxmemory_mb 128 500 640 22249 1)" = "640 raised"
check "cache guard: a maxmemory up to 10% above the 128 MB minimum is kept" \
  test "$(valkey_guard_maxmemory_mb 128 10 140 22249 1)" = "140 plan"
check "cache guard: just above the keep band shrinks to data+20%" \
  test "$(valkey_guard_maxmemory_mb 128 500 661 22249 1)" = "600 raised"
check "cache guard: the scaled second pass (band off) never keeps a larger current" \
  test "$(valkey_guard_maxmemory_mb 128 500 640 22249 1 0)" = "600 raised"
check "cache guard: an evicting cache at 83%+ of maxmemory is full: kept, never raised" \
  test "$(valkey_guard_maxmemory_mb 128 115 128 22249 1)" = "128 full"
check "cache guard: noeviction growth past data+10% headroom is raised to data+20%" \
  test "$(valkey_guard_maxmemory_mb 128 120 128 22249 0)" = "144 raised"
check "cache guard: noeviction drift with 10%+ headroom left is not rewritten" \
  test "$(valkey_guard_maxmemory_mb 128 540 600 22249 0)" = "600 raised"
check "cache guard: an evicting cache sampled at 90% is not ratcheted up" \
  test "$(valkey_guard_maxmemory_mb 128 460 512 22249 1)" = "512 full"
check "cache guard: a cache at 98% of maxmemory is full" \
  test "$(valkey_guard_maxmemory_mb 128 490 500 22249 1)" = "500 full"
# Feeding the result back in must not move it: that is the "second run
# changes nothing" property (the old code grew 512 -> 614 -> 737 ...).
guard_stable() {
  local first second
  first=$(valkey_guard_maxmemory_mb "$@")
  second=$(valkey_guard_maxmemory_mb "${first%% *}" "$2" "${first%% *}" "$4" "$5")
  [[ ${second%% *} == "${first%% *}" ]]
}
check "cache guard: a second pass keeps a full cache's size" guard_stable 434 512 512 22249 1
check "cache guard: a second pass keeps a noeviction cache's data+20%" guard_stable 434 512 512 22249 0
check "cache guard: a second pass keeps a raised size" guard_stable 434 3000 0 22249 1
check "cache guard: a second pass keeps a capped size" guard_stable 434 30000 0 22249 0

# The real valkey_policy_evicts (the suite stubs it globally above), with the
# configuration and INFO stats stubbed: a volatile-* cache that has evicted
# TTL keys is an LRU-like cache and must not ratchet 512 -> 614 -> 736 ...
policy_evicts_case() {
  local stub_policy=$1 stub_evicted=$2
  (
    eval "$(sed -n '/^valkey_policy_evicts() {/,/^}/p' "$ROOT/lib/service-optimizers.sh")"
    valkey_active_conf() { printf '/stub/valkey.conf'; }
    valkey_conf_get() { printf "%s" "$stub_policy"; }
    valkey_live_cli() { [[ $stub_evicted == none ]] && return 1; printf "evicted_keys:%s\r\n" "$stub_evicted"; }
    valkey_policy_evicts
  )
}
check "cache policy: allkeys-lru evicts" test "$(policy_evicts_case allkeys-lru 0)" = 1
check "cache policy: noeviction does not evict" test "$(policy_evicts_case noeviction 5)" = 0
check "cache policy: volatile-lru that evicted keys counts as evicting" \
  test "$(policy_evicts_case volatile-lru 1234)" = 1
check "cache policy: volatile-lru with no evictions follows its data" \
  test "$(policy_evicts_case volatile-lru 0)" = 0
check "cache policy: volatile-ttl on a cache that does not answer follows its data" \
  test "$(policy_evicts_case volatile-ttl none)" = 0
check "cache guard: a full volatile cache that evicts keeps its size on a second pass" \
  guard_stable 434 512 512 22249 "$(policy_evicts_case volatile-lru 99)"

check "valkey_size_to_mb reads the writer's own unit" test "$(valkey_size_to_mb 512mb)" -eq 512
check "valkey_size_to_mb reads gigabytes" test "$(valkey_size_to_mb 2GB)" -eq 2048
check "valkey_size_to_mb reads plain bytes" test "$(valkey_size_to_mb 536870912)" -eq 512
check "valkey_size_to_mb treats no limit and garbage as 0" \
  test "$(valkey_size_to_mb 0)" -eq 0 -a "$(valkey_size_to_mb '')" -eq 0 -a "$(valkey_size_to_mb 5tb)" -eq 0

# The plan owns the decision, so the install path, --optimize and the dry run
# all read the same OPT_VALKEY_BUDGET_MB.
rm -f "$SETUP_STATE_DIR/explicit-options.conf"
effective_cpus() { printf '16'; }
mem_total_mb() { printf '27812'; }
php_primary_version() { printf '8.4'; }
php_worker_allowance_mb() { printf '64'; }
php_pool_max_children() { printf '16'; }
mariadb_data_size_mb() { printf '2000'; }
mariadb_data_dir_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_data_dir_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
valkey_data_size_mb() { printf '0'; }
valkey_live_used_mb() { printf '512'; }
valkey_current_maxmemory_mb() { printf '512'; }
valkey_live_uptime_s() { printf '86400'; }
valkey_live_peak_mb() { printf '0'; }
valkey_policy_evicts() { printf '1'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
OPT_INSTALL_PLAN=0
plan_memory_budget
check "plan: a full 512 MB cache keeps 512 MB instead of growing to 614" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 512 -a "$OPT_VALKEY_GUARD" = full
plan_memory_budget
check "plan: a second run changes nothing" test "$OPT_VALKEY_BUDGET_MB" -eq 512

valkey_policy_evicts() { printf '0'; }
plan_memory_budget
check "plan: a full noeviction cache follows its data (512 -> 614 MB)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 614
valkey_policy_evicts() { printf '1'; }

valkey_live_used_mb() { printf '100'; }
plan_memory_budget
check "plan: a mostly empty cache shrinks to data+20% (128 MB minimum), not the RAM floor" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 128 -a "$OPT_VALKEY_GUARD" = shrunk
valkey_live_used_mb() { printf '400'; }
valkey_current_maxmemory_mb() { printf '900'; }
plan_memory_budget
check "plan: a half-empty 900 MB cache shrinks to 400 MB + 20% = 480 MB" \
  test "$OPT_VALKEY_BUDGET_MB:$OPT_VALKEY_GUARD:$OPT_VALKEY_PREV_MB" = 480:shrunk:900
valkey_live_uptime_s() { printf '600'; }
plan_memory_budget
check "plan: a cache restarted 10 minutes ago keeps its 900 MB (cold, not small)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 900
check "plan: the kept size of a young cache is reported as young, not as data+20%" \
  test "$OPT_VALKEY_GUARD" = young
valkey_live_uptime_s() { printf '86400'; }
valkey_live_used_mb() { return 1; }
plan_memory_budget
check "plan: a stopped cache keeps its configured 900 MB (no RAM-floor flip)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 900
check "plan: the kept size of an unmeasurable cache is reported as unmeasured" \
  test "$OPT_VALKEY_GUARD" = unmeasured
valkey_data_size_mb() { printf '1000'; }
plan_memory_budget
check "plan: a stopped cache whose snapshot needs more is raised (1000 MB + 20%)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 1200
valkey_data_size_mb() { printf '0'; }
# After a shrink to data+20%, a noeviction cache follows its growth; an
# evicting one fills its size and is kept (no ratchet).
valkey_live_used_mb() { printf '460'; }
valkey_current_maxmemory_mb() { printf '480'; }
plan_memory_budget
check "plan: an evicting cache refilled to 96% keeps its 480 MB" \
  test "$OPT_VALKEY_BUDGET_MB:$OPT_VALKEY_GUARD" = 480:full
valkey_policy_evicts() { printf '0'; }
plan_memory_budget
check "plan: a noeviction cache sized to data+20% follows growth (460 MB -> 552 MB)" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 552
valkey_policy_evicts() { printf '1'; }
# The peak since start is the data: a quiet-hour sample does not cut a cache
# below its busy-hour need.
valkey_live_used_mb() { printf '100'; }
valkey_live_peak_mb() { printf '400'; }
valkey_current_maxmemory_mb() { printf '900'; }
plan_memory_budget
check "plan: data is the peak (400 MB), so 900 MB shrinks to 480 MB, not 128" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 480
valkey_live_peak_mb() { printf '0'; }
valkey_live_used_mb() { printf '400'; }
valkey_current_maxmemory_mb() { printf '520'; }
plan_memory_budget
check "plan: 520 MB is inside the keep band (480 + 10%) and stays" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 520
valkey_live_used_mb() { printf '0'; }
valkey_current_maxmemory_mb() { printf '0'; }
plan_memory_budget
check "plan: a running but empty cache gets the 128 MB minimum" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 128
valkey_live_uptime_s() { printf '600'; }
plan_memory_budget
check "plan: a just-restarted cache with no maxmemory gets the RAM floor, not 128 MB" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 434
valkey_live_uptime_s() { printf '86400'; }
valkey_live_used_mb() { return 1; }
plan_memory_budget
check "plan: a cache with nothing to measure keeps the RAM floor" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 434

# An explicit --valkey ram= is never touched by the live-data guard.
valkey_live_used_mb() { printf '5000'; }
valkey_current_maxmemory_mb() { printf '5000'; }
printf 'valkey_mb=512\n' > "$SETUP_STATE_DIR/explicit-options.conf"
plan_memory_budget
check "plan: an explicit cache size ignores live data" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 512 -a "$OPT_VALKEY_GUARD" = explicit
rm -f "$SETUP_STATE_DIR/explicit-options.conf"

# A re-run of the installer on a host that already has the cache measures it
# like --optimize; a cache that is not installed yet is not probed at all.
valkey_live_used_mb() { printf '512'; }
valkey_current_maxmemory_mb() { printf '512'; }
valkey_active_conf() { printf '/etc/valkey/valkey.conf'; }
OPT_INSTALL_PLAN=1
plan_memory_budget
check "install plan on an installed cache matches --optimize" test "$OPT_VALKEY_BUDGET_MB" -eq 512
valkey_active_conf() { :; }
plan_memory_budget
check "install plan for a new cache uses the RAM floor without probing" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 434 -a "$OPT_VALKEY_LIVE_MB" -eq 0
OPT_INSTALL_PLAN=0

# A plan that cannot fit every target scales the cache share down; the guard
# then keeps a full cache at its current size instead of evicting it.
mem_total_mb() { printf '2048'; }
effective_cpus() { printf '2'; }
mariadb_data_size_mb() { printf '5000'; }
valkey_live_used_mb() { printf '1000'; }
valkey_current_maxmemory_mb() { printf '1000'; }
plan_memory_budget 2>/dev/null
check "a squeezed plan never shrinks a full cache below its data" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 1000 -a "$OPT_VALKEY_GUARD" = full
# A database larger than RAM fills the data pool, so PHP is at its floor and
# cannot pay for what the guard gives back to the cache (400 MB used -> 480);
# MariaDB gives it up instead and the healthy host plans without overcommit.
mem_total_mb() { printf '27812'; }
effective_cpus() { printf '16'; }
mariadb_data_size_mb() { printf '40000'; }
valkey_live_used_mb() { printf '400'; }
valkey_current_maxmemory_mb() { printf '1024'; }
plan_memory_budget
check "a squeezed plan keeps live cache data +20% without overcommit" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 480 -a "$OPT_MEM_OVERCOMMIT_MB" -eq 0
check "a squeezed plan with a re-raised cache still fits the budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) \
       -le 22249
valkey_live_used_mb() { return 0; }
valkey_current_maxmemory_mb() { printf '0'; }
effective_cpus() { printf '16'; }
mem_total_mb() { printf '27812'; }
mariadb_data_size_mb() { printf '0'; }

valkey_opt_body=$(sed -n '/^optimize_valkey()/,/^}/p' "$ALL_SRC")
check "optimize_valkey writes the planned size without re-deriving it" \
  bash -c '! grep -qE "needed_mb|hard_cap" <<< "$1"' _ "$valkey_opt_body"
check "optimize_valkey reports a full cache and how to grow it" \
  grep -q 'Cache is full.*--valkey ram=' <<<"$valkey_opt_body"
check "the dry run prints the same planned cache size" \
  grep -q 'max_mb=\$OPT_VALKEY_BUDGET_MB' <<<"$(sed -n '/^optimize_plan()/,/^}/p' "$ALL_SRC")"

# ---------------------------------------------------------------------------
# Overcommit uses the PHP budget that is really reserved
# ---------------------------------------------------------------------------
# 1 GB host with PHP and MariaDB: eight floor workers at 96 MB need 768 MB,
# but php_floor is capped at half the 819 MB budget (409 MB) for the
# data-tier split.  256 + 409 looked as if it fitted; 256 + 768 does not.
mem_total_mb() { printf '1024'; }
php_worker_allowance_mb() { printf '96'; }
php_children_floor() { printf '8'; }
OPT_DETECTED=(angie php:8.4 mariadb)
plan_memory_budget 2>/dev/null
check "overcommit is measured against the real PHP reservation" \
  test "$OPT_PHP_BUDGET_MB" -eq 768 \
       -a "$OPT_MEM_OVERCOMMIT_MB" -eq $(( OPT_MARIADB_BUDGET_MB + 768 - 819 ))
mem_total_mb() { printf '27812'; }
plan_memory_budget 2>/dev/null
check "the 27 GB reference host still reports no overcommit" test "$OPT_MEM_OVERCOMMIT_MB" -eq 0
# The suite stubs php_children_floor above; put the real one back.
eval "$(sed -n '/^php_children_floor()/,/^}/p' "$ALL_SRC")"

# ---------------------------------------------------------------------------
# PHP worker allowance: the unmeasurable fallback equals the install value
# ---------------------------------------------------------------------------
# The suite stubs php_worker_allowance_mb, so load the real body in a subshell
# and feed it a fake `ps` (RSS in kB, one line per process).
real_worker_allowance() {
  (
    eval "$(sed -n '/^php_worker_allowance_mb()/,/^}/p' "$ALL_SRC")"
    ps() { printf '%s' "$FAKE_PS"; }
    php_worker_allowance_mb 8.4
  )
}
FAKE_PS=""
check "a stopped PHP-FPM plans at the install value (64 MB)" test "$(real_worker_allowance)" -eq 64
FAKE_PS=$'40960\n'
check "a lone master process plans at the install value (64 MB)" test "$(real_worker_allowance)" -eq 64
FAKE_PS=$'81920\n81920\n81920\n'
check "a running pool is measured (1.5x the 80 MB average)" test "$(real_worker_allowance)" -eq 120
FAKE_PS=$'20480\n20480\n'
check "a light pool keeps the 64 MB floor" test "$(real_worker_allowance)" -eq 64

# ---------------------------------------------------------------------------
# MariaDB: an online buffer-pool resize that the server clamped
# ---------------------------------------------------------------------------
check "a pool clamped at 1744 MB of 4096 MB is short" mariadb_pool_resize_short 1744 4096
check "a pool at the target is not short" not mariadb_pool_resize_short 4096 4096
check "chunk rounding within 2% is not short" not mariadb_pool_resize_short 4032 4096
check "a pool above the target is not short" not mariadb_pool_resize_short 4160 4096
check "an unreadable pool size is not treated as clamped" not mariadb_pool_resize_short "" 4096
maria_opt_body=$(sed -n '/^optimize_mariadb()/,/^}/p' "$ALL_SRC")
check "optimize_mariadb reads the pool back before reporting an online resize" \
  grep -q 'mariadb_pool_resize_short "\$online_mb" "\$size_mb"' <<<"$maria_opt_body"
check "the tuning drop-in never sets innodb_buffer_pool_size_max" \
  bash -c '! grep -qE "^[[:space:]]*innodb_buffer_pool_size_max[[:space:]]*=" "$1"' _ "$ALL_SRC"

# ---------------------------------------------------------------------------
# Writeback thresholds on small hosts
# ---------------------------------------------------------------------------
check "dirty thresholds: 512 MB host is capped at RAM/20 and RAM/5" \
  test "$(sysctl_dirty_thresholds_mb 512 ssd)" = "25 102"
check "dirty thresholds: 1 GB host is capped at RAM/20 and RAM/5" \
  test "$(sysctl_dirty_thresholds_mb 1024 ssd)" = "51 204"
check "dirty thresholds: tiny host keeps 8 MB and twice the background mark" \
  test "$(sysctl_dirty_thresholds_mb 64 ssd)" = "8 16"
check "dirty thresholds: 2 GB host keeps the 64/256 MB floors" \
  test "$(sysctl_dirty_thresholds_mb 2048 ssd)" = "64 256"
check "dirty thresholds: 27 GB NVMe reference host is unchanged (278/1112)" \
  test "$(sysctl_dirty_thresholds_mb 27812 nvme)" = "278 1112"
check "dirty thresholds: large flash host keeps the 512 MB/2 GB caps" \
  test "$(sysctl_dirty_thresholds_mb 131072 nvme)" = "512 2048"
check "dirty thresholds: rotational disks keep the tighter caps" \
  test "$(sysctl_dirty_thresholds_mb 131072 hdd)" = "256 1024"
check "configure_sysctl takes both thresholds from the helper" \
  grep -q 'sysctl_dirty_thresholds_mb "\$ram_mb" "\$disk_class"' <<<"$sysctl_body"

# ---------------------------------------------------------------------------
# udev readahead follows the storage class
# ---------------------------------------------------------------------------
check "rotational readahead stays 1024 kB on an hdd-class host" \
  test "$(io_rotational_read_ahead_kb hdd)" -eq 1024
check "rotational readahead is the flash value on an ssd-class host" \
  test "$(io_rotational_read_ahead_kb ssd)" -eq 128
check "rotational readahead is the flash value on an nvme-class host" \
  test "$(io_rotational_read_ahead_kb nvme)" -eq 128
check "the rotational udev rule takes its readahead from the storage class" \
  grep -q 'ATTR{queue/rotational}=="1".*ATTR{bdi/read_ahead_kb}="\${rot_ra_kb}"' <<<"$io_body"
check "no udev rule hard-codes the 1024 kB readahead" \
  bash -c '! grep -q "read_ahead_kb}=\"1024\"" <<< "$1"' _ "$io_body"

# ---------------------------------------------------------------------------
# setup-network-tuning.service survives a container
# ---------------------------------------------------------------------------
net_unit=$(QDISC=fq TCP_CC=bbr network_tuning_unit_text nf_conntrack sch_fq tcp_bbr)
check "network unit: every ExecStart tolerates failure" \
  bash -c '! grep -qE "^ExecStart=[^-]" <<< "$1"' _ "$net_unit"
check "network unit: one modprobe line per module" \
  test "$(grep -c '^ExecStart=-/sbin/modprobe ' <<<"$net_unit")" -eq 3
check "network unit: the qdisc has its own sysctl line" \
  grep -qx 'ExecStart=-/sbin/sysctl -w net.core.default_qdisc=fq' <<<"$net_unit"
check "network unit: the congestion control has its own sysctl line" \
  grep -qx 'ExecStart=-/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbr' <<<"$net_unit"
check "network unit: still a oneshot that stays active" \
  bash -c 'grep -qx "Type=oneshot" <<< "$1" && grep -qx "RemainAfterExit=yes" <<< "$1"' _ "$net_unit"
check "network unit: rewritten and reloaded only when its content changes" \
  grep -q 'if commit_if_changed "\$net_unit" "\$net_unit_tmp"; then' <<<"$sysctl_body"
check "network unit: re-applies the managed profile after systemd-sysctl" \
  grep -qx 'ExecStart=-/sbin/sysctl -e -p /etc/sysctl.conf' <<<"$net_unit"
check "network unit: ordered after systemd-sysctl" \
  grep -q 'After=.*systemd-sysctl.service' <<<"$net_unit"

# Late enforcement pass against old hand fixes that write a managed key
# after systemd-sysctl (tcp-bbr.service, rc.local, provider agents).
final_unit=$(QDISC=fq TCP_CC=bbr sysctl_final_unit_text tcp_bbr sch_fq)
check "late sysctl unit: runs after multi-user services" \
  grep -qx 'After=multi-user.target' <<<"$final_unit"
check "late sysctl unit: re-applies the full profile" \
  grep -qx 'ExecStart=-/sbin/sysctl -e -p /etc/sysctl.conf' <<<"$final_unit"
check "late sysctl unit: keeps the selected congestion control" \
  grep -qx 'ExecStart=-/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbr' <<<"$final_unit"
final_timer=$(sysctl_final_timer_text)
check "late sysctl timer: fires 90 s after boot" \
  grep -qx 'OnBootSec=90s' <<<"$final_timer"
check "late sysctl timer: triggers the oneshot" \
  grep -qx 'Unit=setup-sysctl-final.service' <<<"$final_timer"
check "the managed sysctl.conf is not reported as a foreign source" \
  tuning_is_own_sysctl_file /etc/sysctl.conf
check "an unrelated sysctl drop-in is reported as foreign" \
  not tuning_is_own_sysctl_file /etc/sysctl.d/50-custom-performance.conf
check "reset keeps the Anubis and Node pins" \
  test "$(printf '%s\n' "${RESET_KEEP_PINS[@]}" | grep -cE '^(ANUBIS|NODE_MAJOR)$')" -eq 2

# --optimize always recomputes the profile: recorded pins/sizes are cleared
# and tuning environment variables are ignored, while feature choices stay.
reset_body=$(sed -n '/^reset_operator_overrides()/,/^}/p' "$ALL_SRC")
check "the profile reset sets bbr without honouring SETUP_TCP_CC" \
  bash -c '! grep -q "SETUP_TCP_CC+x" <<< "$1"' _ "$reset_body"
check "the profile reset sets fq without honouring SETUP_QDISC" \
  bash -c '! grep -q "SETUP_QDISC+x" <<< "$1"' _ "$reset_body"
ignored_env=$( (
  export SETUP_TCP_CC=cubic SETUP_PHP_WORKERS_PER_CPU=2.0 SETUP_LIMIT_REQ_EXEMPT=10.0.0.1 \
         SETUP_ANUBIS=1 SETUP_XF_JOB_CRON=0 SETUP_PHP_JIT_WORDPRESS=0
  optimize_ignore_tuning_env >/dev/null 2>&1
  printf '%s;%s;%s;%s;%s;%s;%s\n' \
    "${SETUP_TCP_CC-none}" "${SETUP_PHP_WORKERS_PER_CPU-none}" \
    "${SETUP_LIMIT_REQ_EXEMPT-none}" "${SETUP_ANUBIS-none}" \
    "${SETUP_XF_JOB_CRON-none}" "${SETUP_PHP_JIT_WORDPRESS-none}" \
    "${OPTIMIZE_IGNORED_ENV[*]}"
) )
check "optimize ignores tuning environment overrides but keeps feature choices" \
  test "$ignored_env" = "none;none;none;1;0;none;SETUP_TCP_CC=cubic SETUP_PHP_WORKERS_PER_CPU=2.0 SETUP_PHP_JIT_WORDPRESS=0 SETUP_LIMIT_REQ_EXEMPT=10.0.0.1"
optimize_body=$(sed -n '/^run_optimize()/,/^}/p' "$ALL_SRC")
check "run_optimize always resets recorded overrides" \
  grep -q '^  reset_operator_overrides$' <<<"$optimize_body"
check "run_optimize always ignores tuning environment overrides" \
  grep -q '^  optimize_ignore_tuning_env$' <<<"$optimize_body"
check "the dry run previews the profile reset" \
  grep -q 'reset_operator_overrides 2' "$ALL_SRC"

# ---------------------------------------------------------------------------
# Swap file: containers and btrfs/ZFS must not abort --basic
# ---------------------------------------------------------------------------
swap_body=$(sed -n '/^create_swap_file()/,/^}/p' "$ALL_SRC")
check "a refused mkswap/swapon is handled, not fatal" \
  grep -q 'if ! mkswap "\$new" >/dev/null 2>&1 || ! swapon "\$new" 2>/dev/null; then' <<<"$swap_body"
check "the unusable swap file is removed" grep -q 'rm -f "\$new"' <<<"$swap_body"
check "a refused swap file is reported at INFO level" \
  grep -q 'info "Swap file not enabled' <<<"$swap_body"
check "no caller truncates the swap file after a failed swapoff" \
  bash -c '! grep -q "swapoff /swapfile 2>/dev/null || true" "$1"' _ "$ALL_SRC"
# The replacement is built and activated beside the live file, then moved into
# place: a failed download/fallocate can no longer leave the host without swap.
check "the new swap file is built beside the live one" \
  grep -q 'new=/swapfile.new' <<<"$swap_body"
check "the live swap file is never truncated in place" \
  not bash -c 'grep -qE "^[[:space:]]*: > /swapfile" "$1"' _ <(printf '%s\n' "$swap_body")
check "the new swap file is live before the old one is released" \
  test "$(grep -n 'swapon "\$new"' <<<"$swap_body" | cut -d: -f1)" \
     -lt "$(grep -n 'swapoff /swapfile' <<<"$swap_body" | cut -d: -f1)"
# release_swap_file with stubbed swapon/swapoff (functions shadow the tools).
release_quiet() { release_swap_file 2>/dev/null; }
swapoff_called=0
swapon() { printf '/swapfile\n'; }
swapoff() { return 1; }
check "an active swap file that cannot be released stops the re-create" not release_quiet
swapoff() { return 0; }
check "a released swap file may be re-created" release_swap_file
swapon() { :; }
swapoff() { swapoff_called=2; return 1; }
check "an inactive swap file needs no swapoff" release_swap_file
check "swapoff is not attempted on an inactive file" test "$swapoff_called" -ne 2
unset -f swapon swapoff

# ---------------------------------------------------------------------------
# 1.21.3: log files in service-owned directories are never followed as links
# ---------------------------------------------------------------------------
mkdir -p "$TMP/seclog"
printf 'root-owned\n' > "$TMP/seclog/target"
chmod 600 "$TMP/seclog/target"
ln -s "$TMP/seclog/target" "$TMP/seclog/php-error.log"
secure_log_file "$TMP/seclog/php-error.log" "$(id -un)" "$(id -gn)" >/dev/null 2>&1
check "a symlinked log file keeps its target's mode" \
  test "$(stat -c %a "$TMP/seclog/target")" = 600
check "a symlinked log file is reported" \
  bash -c 'grep -q "symbolic link" <<<"$1"' _ "$(secure_log_file "$TMP/seclog/php-error.log" root root 2>&1)"
secure_log_file "$TMP/seclog/new.log" "$(id -un)" "$(id -gn)"
check "a missing log file is created 0640" \
  test "$(stat -c %a "$TMP/seclog/new.log")" = 640
ln -s "$TMP/seclog/absent-target" "$TMP/seclog/dangling.log"
secure_log_file "$TMP/seclog/dangling.log" "$(id -un)" "$(id -gn)" >/dev/null 2>&1
check "a dangling link is not created through" test ! -e "$TMP/seclog/absent-target"
check "log_file goes through the symlink-safe helper" \
  bash -c 'sed -n "/^log_file()/,/^}/p" "$1" | grep -q secure_log_file' _ "$ALL_SRC"
check "no log path is chowned without -h" \
  bash -c '! grep -nE "chown (www-data:www-data|\"\\\$(owner|user):\\\$(grp|group)\") \"\\\$(log_dir/error.log|file|path)\"" "$1"' _ "$ALL_SRC"

# ---------------------------------------------------------------------------
# 1.21.3: backup credentials survive "#", quotes and backslashes
# ---------------------------------------------------------------------------
printf '[mysql]\nuser=dba\npassword=dba_passwd\n' > "$TMP/mysqlbkup.cnf"
write_mysqlbkup_credentials "$TMP/mysqlbkup.cnf" admin 'Ab#9x"Q\z'
check "backup password with # is written quoted" \
  grep -qxF 'password="Ab#9x\"Q\\z"' "$TMP/mysqlbkup.cnf"
check "backup user is written quoted" grep -qxF 'user="admin"' "$TMP/mysqlbkup.cnf"

# ---------------------------------------------------------------------------
# 1.21.3: an adopted cache keeps AOF persistence and a non-loopback bind
# ---------------------------------------------------------------------------
vk_adopt="$TMP/redis-adopt.conf"
printf 'bind 10.0.0.5 127.0.0.1\nappendonly yes\nsave 900 1\nmaxmemory 1gb\n' > "$vk_adopt"
valkey_apply_config "$vk_adopt" redis 512 allkeys-lru 1 /run/redis/redis.sock adopt
check "adopted cache: appendonly yes is kept" grep -qx 'appendonly yes' "$vk_adopt"
check "adopted cache: the save schedule is kept" grep -qx 'save 900 1' "$vk_adopt"
check "adopted cache: persistence is not switched off" not grep -qx 'appendonly no' "$vk_adopt"
check "adopted cache: the private bind address is kept" grep -qx 'bind 10.0.0.5 127.0.0.1' "$vk_adopt"
cp "$vk_adopt" "$vk_adopt.first"
valkey_apply_config "$vk_adopt" redis 512 allkeys-lru 1 /run/redis/redis.sock adopt
check "adopted cache: the second run writes the same file" cmp -s "$vk_adopt" "$vk_adopt.first"
vk_plain="$TMP/redis-plain.conf"
printf 'bind 127.0.0.1 -::1\nappendonly no\n' > "$vk_plain"
valkey_apply_config "$vk_plain" redis 512 allkeys-lru 1 /run/redis/redis.sock adopt
check "a default cache still gets persistence off" grep -qx 'save ""' "$vk_plain"
check "a default cache keeps the loopback bind" grep -qx 'bind 127.0.0.1 -::1' "$vk_plain"
vk_inst="$TMP/valkey-install.conf"
printf 'bind 10.0.0.5\nappendonly yes\n' > "$vk_inst"
valkey_apply_config "$vk_inst" valkey 512 allkeys-lru 1 /run/valkey/valkey.sock
check "a fresh --valkey install writes the cache profile" \
  bash -c 'grep -qx "appendonly no" "$1" && grep -qx "bind 127.0.0.1 -::1" "$1"' _ "$vk_inst"

# ---------------------------------------------------------------------------
# 1.21.3: --valkey without policy=/io_threads= keeps the previous values
# ---------------------------------------------------------------------------
validate_body=$(sed -n '/^validate_all()/,/^}/p' "$ALL_SRC")
check "validation does not write a default policy back" \
  bash -c '! grep -q "valkey.policy\]:-allkeys-lru" <<<"$1"' _ "$validate_body"
check "validation does not write a default io_threads back" \
  bash -c '! grep -q "valkey.io_threads\]:-1" <<<"$1"' _ "$validate_body"

# ---------------------------------------------------------------------------
# 1.21.3: generated vhosts get anchored route locations
# ---------------------------------------------------------------------------
va="$TMP/anchor"; mkdir -p "$va/conf.d" "$va/h5bp/location"
: > "$va/h5bp/location/security_leftover_files.conf"
printf 'server {\n    location ~ ^/(admin.php|install) {\n        include h5bp/php.conf;\n    }\n}\n' > "$va/conf.d/xf.conf"
printf 'server {\n    location ~ ^/(dashboard|update) {\n        include h5bp/php_chev.conf;\n    }\n}\n' > "$va/conf.d/chev.conf"
printf 'server {\n    location / { }\n}\n' > "$va/conf.d/other.conf"
cp "$va/conf.d/other.conf" "$va/other.orig"
tune_vhost_route_anchors "$va" >/dev/null 2>&1
check "XenForo admin/install location is anchored" \
  grep -qF 'location ~ ^/(?:admin\.php$|install(?:/|$)) {' "$va/conf.d/xf.conf"
check "Chevereto dashboard/update location is anchored" \
  grep -qF 'location ~ ^/(?:dashboard|update)(?:/|$) {' "$va/conf.d/chev.conf"
check "the leftover-file rule is included once" \
  test "$(grep -c security_leftover_files "$va/conf.d/xf.conf")" -eq 1
cp "$va/conf.d/xf.conf" "$va/xf.first"
tune_vhost_route_anchors "$va" >/dev/null 2>&1
check "anchoring is idempotent" cmp -s "$va/conf.d/xf.conf" "$va/xf.first"
check "an unrelated vhost is untouched" cmp -s "$va/conf.d/other.conf" "$va/other.orig"

# ---------------------------------------------------------------------------
# 1.21.3: interrupted runs, pool listeners, report mode, repeat --basic
# ---------------------------------------------------------------------------
check "a dropped SSH session unwinds through on_exit" grep -q "trap 'exit 129' HUP" "$ALL_SRC"
check "on_exit resumes a paused web tier" \
  bash -c 'sed -n "/^on_exit()/,/^}/p" "$1" | grep -q opt_resume_web_frontends' _ "$ALL_SRC"
check "--upgrade-php keeps the listener of a migrated pool" \
  grep -qF '/^[[:space:]]*listen[[:space:]]*=/! s/php${old//./\\.}/php${new}/g' "$ALL_SRC"
check "the optimize report is not world-readable" \
  bash -c 'sed -n "/^write_optimize_report()/,/^}/p" "$1" | grep -q "chmod 640 \"\$file\""' _ "$ALL_SRC"
mkdir -p "$SETUP_STATE_DIR"
: > "$SETUP_STATE_DIR/applied-hostname"
check "a first --basic has no applied hostname to keep" not basic_applied_value hostname
printf 'web1\n' > "$SETUP_STATE_DIR/applied-hostname"
hostnamectl() { printf 'web1-live\n'; }
check "a repeat --basic keeps the live hostname" test "$(basic_applied_value hostname)" = web1-live
unset -f hostnamectl
: > "$SETUP_STATE_DIR/applied-hostname"
check "the malware rule needs a hex letter in the plugin suffix" \
  grep -qF -- "-regex '.*-[0-9]*[a-f][0-9a-f]*\$'" "$ALL_SRC"
swap_auto_body=$(sed -n '/^configure_swap_auto()/,/^}/p' "$ALL_SRC")
check "automatic swap is sized to the free disk before the old file is released" \
  bash -c 'a=$(grep -n "Automatic swap skipped" <<<"$1" | cut -d: -f1); b=$(grep -n "release_swap_file" <<<"$1" | head -1 | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]' _ "$swap_auto_body"
check "--php re-enables the session GC timer after a purge" \
  bash -c 'sed -n "/^install_php()/,/^}/p" "$1" | grep -q "systemctl enable --now phpsessionclean.timer"' _ "$ALL_SRC"
check "--others sysstat re-enables the units a purge disabled" \
  grep -q 'systemctl enable sysstat.service sysstat-rotate.timer' "$ALL_SRC"

# ---------------------------------------------------------------------------
# 1.21.4: application-aware PHP extension preflight and extension accounting
# ---------------------------------------------------------------------------
mkdir -p "$TMP/apps/wp/public/wp-includes" "$TMP/apps/xf/public/src" \
         "$TMP/apps/chev/public/app/bin" "$TMP/apps/plain"
: > "$TMP/apps/wp/public/wp-config.php"
: > "$TMP/apps/wp/public/wp-includes/version.php"
: > "$TMP/apps/xf/public/src/XF.php"
: > "$TMP/apps/xf/public/src/config.php"
: > "$TMP/apps/chev/public/app/env.php"
: > "$TMP/apps/chev/public/app/bin/legacy"
app_roots=$(php_upgrade_app_roots "$TMP/apps")
has_ext() { "$@" | grep -qx redis; }
lacks_ext() { ! "$@" | grep -qx redis; }
check "app detection finds WordPress" grep -qx $'wordpress\t'"$TMP/apps/wp/public" <<<"$app_roots"
check "app detection finds XenForo" grep -qx $'xenforo\t'"$TMP/apps/xf/public" <<<"$app_roots"
check "app detection finds Chevereto" grep -qx $'chevereto\t'"$TMP/apps/chev/public" <<<"$app_roots"
check "app detection lists each document root once" test "$(wc -l <<<"$app_roots" | tr -d ' ')" = 3
check "app detection ignores an unrelated directory" not grep -q plain <<<"$app_roots"
rm -f "$TMP/apps/chev/public/app/bin/legacy"
app_roots=$(php_upgrade_app_roots "$TMP/apps")
check "Chevereto needs only app/env.php, like the --optimize detector" \
  grep -qx $'chevereto\t'"$TMP/apps/chev/public" <<<"$app_roots"
: > "$TMP/apps/chev/public/app/bin/legacy"
check "Chevereto requirements include imagick" \
  php_upgrade_app_required_extensions chevereto "$TMP/apps/chev/public" | grep -qx imagick
check "Chevereto requirements include redis" \
  has_ext php_upgrade_app_required_extensions chevereto "$TMP/apps/chev/public"
check "WordPress requirements skip redis without an object-cache drop-in" \
  lacks_ext php_upgrade_app_required_extensions wordpress "$TMP/apps/wp/public"
mkdir -p "$TMP/apps/wp/public/wp-content"
: > "$TMP/apps/wp/public/wp-content/object-cache.php"
check "WordPress requirements add redis with an object-cache drop-in" \
  has_ext php_upgrade_app_required_extensions wordpress "$TMP/apps/wp/public"
printf "// \$config['cache']['provider'] = 'Redis';\n" > "$TMP/apps/xf/public/src/config.php"
check "XenForo ignores a commented Redis example" \
  lacks_ext php_upgrade_app_required_extensions xenforo "$TMP/apps/xf/public"
printf "\$config['cache']['provider'] = 'Redis';\n" > "$TMP/apps/xf/public/src/config.php"
check "XenForo detects a configured Redis cache" \
  has_ext php_upgrade_app_required_extensions xenforo "$TMP/apps/xf/public"
check "a core extension needs no package lookup" php_upgrade_extension_available 9.9 gd
check "an unpublished extension is reported unavailable" not php_upgrade_extension_available 9.9 redis
php_upgrade_preflight_apps 9.9 "$TMP/apps"
check "the preflight blocks a target without redis" \
  test "$(printf '%s\n' "${PHP_UPGRADE_BLOCKERS[@]}" | grep -c '|redis$')" -eq 3
php_upgrade_preflight_apps 9.9 "$TMP/apps/plain"
check "the preflight is empty without an application" test "${#PHP_UPGRADE_BLOCKERS[@]}" -eq 0
blocker_desc=$(php_upgrade_describe_blocker "chevereto|/var/www/chev|redis")
check "the blocker names the site and the missing package" \
  grep -qF 'chevereto at /var/www/chev requires the redis extension' <<<"$blocker_desc"

mkdir -p "$TMP/php-manifest"
printf 'common\t0\tphp-common\ncommon\t0\tphp8.5-common\nredis\t1\tphp8.5-redis\n' \
  > "$TMP/php-manifest/extensions.txt"
PHP_UPGRADE_MANIFEST_DIR="$TMP/php-manifest"
php_upgrade_plan_extensions 9.9
check "carried extensions are de-duplicated" test "$PHP_UPGRADE_CARRIED_COUNT" -eq 1
check "an unpublished extension still counts as skipped" \
  test "${#PHP_UPGRADE_SKIPPED[@]}" -eq 1
# One extension is often installed twice (php-imagick and php8.5-imagick);
# the skipped list must name it once, like the carried list and the dry run.
printf 'imagick\t1\tphp8.5-imagick\nimagick\t0\tphp-imagick\n' \
  > "$TMP/php-manifest/extensions.txt"
php_upgrade_plan_extensions 9.9
check "a duplicated skipped extension is reported once" \
  test "${#PHP_UPGRADE_SKIPPED[@]}" -eq 1
check "the OpenSSH application profile counts as an SSH rule for port 22" \
  test "$(ufw_rule_ssh_port 'ufw allow OpenSSH' 22)" = 22
check "the OpenSSH application profile is not matched for another port" \
  not ufw_rule_ssh_port 'ufw allow OpenSSH' 2222

# ---------------------------------------------------------------------------
# Anubis vhost migration
# ---------------------------------------------------------------------------
mkdir -p "$TMP/anubis/conf.d" "$TMP/anubis/state"
cat > "$TMP/anubis/conf.d/site.test.conf" <<'EOF'
server {
    listen      80;
    server_name site.test www.site.test;
    return 301 https://site.test$request_uri;
}

server {
    listen      443 ssl;
    listen [::]:443 ssl;
    server_name site.test;
    http2 on;

    include h5bp/tls/ssl_engine.conf;
    ssl_certificate     /etc/angie/ssl/site.test/fullchain.pem;
    ssl_certificate_key /etc/angie/ssl/site.test/privkey.pem;

    root /var/www/site.test/public;
    include h5bp/php_wp.conf;
}
EOF
cat > "$TMP/anubis/conf.d/default.conf" <<'EOF'
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/angie/ssl/default/fullchain.pem;
    ssl_certificate_key /etc/angie/ssl/default/privkey.pem;
    return 444;
}
EOF
cp "$TMP/anubis/conf.d/site.test.conf" "$TMP/anubis/site.before"
ANUBIS_STATE="$TMP/anubis/state"
ANUBIS_BACKEND_SOCKET="/run/angie/anubis-test.sock"
tune_reset_changes
anubis_integrate_vhost "$TMP/anubis/conf.d/site.test.conf"
check "Anubis moves the 443 listener to the backend socket" \
  grep -qx '    listen unix:/run/angie/anubis-test.sock;' "$TMP/anubis/conf.d/site.test.conf"
check "Anubis drops the IPv6 443 listener" \
  bash -c '! grep -q "listen \[::\]:443" "$1"' _ "$TMP/anubis/conf.d/site.test.conf"
check "Anubis removes http2 from the backend block" \
  bash -c '! grep -q "http2 on;" "$1"' _ "$TMP/anubis/conf.d/site.test.conf"
check "Anubis trusts the Unix peer for the real client address" \
  grep -qx '    set_real_ip_from unix:;' "$TMP/anubis/conf.d/site.test.conf"
check "Anubis reads X-Real-IP" \
  grep -qx '    real_ip_header X-Real-IP;' "$TMP/anubis/conf.d/site.test.conf"
check "the port 80 server keeps its public listener" \
  grep -qx '    listen      80;' "$TMP/anubis/conf.d/site.test.conf"
check "the pre-integration vhost is backed up" \
  test -f "$TMP/anubis/state/vhosts/site.test.conf.orig"
check "the backup is byte-identical to the original" \
  cmp -s "$TMP/anubis/site.before" "$TMP/anubis/state/vhosts/site.test.conf.orig"
after_first=$(md5sum < "$TMP/anubis/conf.d/site.test.conf")
tune_reset_changes
anubis_integrate_vhost "$TMP/anubis/conf.d/site.test.conf"
check "the vhost migration is idempotent" \
  test "${#TUNE_CHANGES[@]}" -eq 0
check "the migrated vhost is unchanged on the second pass" \
  test "$after_first" = "$(md5sum < "$TMP/anubis/conf.d/site.test.conf")"

# A non-443 TLS port must not be treated as the public HTTPS listener.
cat > "$TMP/anubis/conf.d/alt.test.conf" <<'EOF'
server {
    listen 8443 ssl;
    server_name alt.test;
}
EOF
check "Anubis leaves an 8443 SSL listener alone" \
  bash -c '! anubis_vhost_needs_migration "$1"' _ "$TMP/anubis/conf.d/alt.test.conf"
# IPv6-only TLS blocks used to lose their only listener and fall back to :80.
cat > "$TMP/anubis/conf.d/v6.test.conf" <<'EOF'
server {
    listen [::]:443 ssl;
    server_name v6.test;
}
EOF
anubis_integrate_vhost "$TMP/anubis/conf.d/v6.test.conf"
check "Anubis migrates an IPv6-only TLS listener" \
  grep -qx '    listen unix:/run/angie/anubis-test.sock;' "$TMP/anubis/conf.d/v6.test.conf"

# Losing the state directory (it also holds the marker) used to make
# `anubis=no` a silent no-op: the vhosts stayed on the backend socket and,
# once the filter was stopped, every site answered 502.  The integrated form
# is reversible, so the disable rebuilds the public listener instead.
mkdir -p "$TMP/anubis2/conf.d"
cp "$TMP/anubis/conf.d/site.test.conf" "$TMP/anubis2/conf.d/site.test.conf"
check "the copied vhost is still integrated" \
  anubis_vhost_integrated "$TMP/anubis2/conf.d/site.test.conf"
check "no pre-integration copy exists for it" \
  not test -e "$TMP/anubis2/state/vhosts/site.test.conf.orig"
# The marker lives in the state directory, so the artifacts must speak for it.
ANUBIS_TERMINATORS="$TMP/anubis2/none.conf"
ANUBIS_COMMON="$TMP/anubis2/none-common.conf"
ANUBIS_LOCATION="$TMP/anubis2/none-location.conf"
ANUBIS_STATIC_BLOCKS="$TMP/anubis2/none-static.conf"
check "a missing marker is detected from an integrated vhost" \
  anubis_artifacts_present "$TMP/anubis2/conf.d"
check "restore without a backup succeeds" \
  anubis_restore_vhosts "$TMP/anubis2/conf.d" "$TMP/anubis2/state"
check "the rebuilt vhost listens on 443 again" \
  grep -qx '    listen 443 ssl;' "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost listens on IPv6 443 again" \
  grep -qx '    listen \[::\]:443 ssl;' "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost carries http2 again" \
  grep -qx '    http2 on;' "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost no longer trusts the Unix peer" \
  bash -c '! grep -q "set_real_ip_from unix:;" "$1"' _ "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost no longer reads the proxy's X-Real-IP" \
  bash -c '! grep -q "real_ip_header X-Real-IP;" "$1"' _ "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost keeps its port 80 redirect" \
  grep -qx '    listen      80;' "$TMP/anubis2/conf.d/site.test.conf"
check "the rebuilt vhost keeps its TLS certificate" \
  grep -qE 'ssl_certificate_key[[:space:]]+/etc/angie/ssl/site.test/privkey.pem;' \
  "$TMP/anubis2/conf.d/site.test.conf"
check "de-integration is idempotent" \
  bash -c '! grep -q "listen unix:/run/angie/anubis-test.sock;" "$1"' _ \
  "$TMP/anubis2/conf.d/site.test.conf"
tune_reset_changes
anubis_deintegrate_vhost "$TMP/anubis2/conf.d/site.test.conf"
check "de-integrating an already public vhost changes nothing" \
  test "${#TUNE_CHANGES[@]}" -eq 0

# Terminators are generated from the integrated blocks only; the catch-all
# (server_name _) must never become a public terminator.
anubis_render_terminators "$TMP/anubis/conf.d" "$TMP/anubis/terminators.conf"
check "the terminator carries the site's server_name" \
  grep -qx '    server_name site.test;' "$TMP/anubis/terminators.conf"
check "the terminator reuses the vhost certificate" \
  grep -q 'ssl_certificate     /etc/angie/ssl/site.test/fullchain.pem;' "$TMP/anubis/terminators.conf"
check "the terminator includes the Anubis location" \
  grep -q 'include snippets/anubis-location.conf;' "$TMP/anubis/terminators.conf"
check "a vhost without a /socket/ location gets no socket route" \
  bash -c '! grep -q "/socket/" "$1"' _ "$TMP/anubis/terminators.conf"
# A XenForo vhost with push: only the WebSocket upgrade skips the filter, and
# the route sets each proxy header once (h5bp/proxy_ws.conf repeated Host,
# which made the backend answer 400 to every handshake).
mkdir -p "$TMP/anubis/ws"
sed 's|^    root /var/www/site.test/public;|&\n    location /socket/ { proxy_pass http://xf_websocket; }|' \
  "$TMP/anubis/conf.d/site.test.conf" > "$TMP/anubis/ws/xf.test.conf"
anubis_render_terminators "$TMP/anubis/ws" "$TMP/anubis/ws-terminators.conf"
check "the XenForo socket route passes only WebSocket upgrades to the backend" \
  bash -c 'grep -qF "location ^~ /socket/ {" "$1" && grep -qF "if (\$http_upgrade !~* ^websocket\$) { return 418; }" "$1" && grep -qF "proxy_pass http://anubis_backend;" "$1"' \
  _ "$TMP/anubis/ws-terminators.conf"
check "the socket route sets Host once (no h5bp/proxy_ws.conf include)" \
  bash -c '! grep -q "proxy_ws.conf" "$1" && test "$(sed -n "/location ^~ \/socket\//,/^    }/p" "$1" | grep -c "proxy_set_header Host ")" = 1' \
  _ "$TMP/anubis/ws-terminators.conf"
check "the catch-all vhost gets no terminator" \
  bash -c '! grep -q "server_name _;" "$1"' _ "$TMP/anubis/terminators.conf"
terminator_md5=$(md5sum < "$TMP/anubis/terminators.conf")
anubis_render_terminators "$TMP/anubis/conf.d" "$TMP/anubis/terminators.conf"
check "the terminator render is idempotent" \
  test "$terminator_md5" = "$(md5sum < "$TMP/anubis/terminators.conf")"

# The static-asset fast path: a static-only shadow of the application block on
# its own socket.  It must keep the application's root and rules, drop the
# public TLS listener, and refuse anything that is not an existing static file.
ANUBIS_STATIC_SOCKET="$TMP/anubis/static.sock"
ANUBIS_STATIC_BLOCKS="$TMP/anubis/static.conf"
ANUBIS_STATIC_BYPASS=1
ANUBIS_STATIC_ACTIVE=0
anubis_render_static_blocks "$TMP/anubis/conf.d" "$TMP/anubis/static.conf"
check "the static shadow listens on its own socket" \
  grep -qx "    listen unix:${ANUBIS_STATIC_SOCKET};" "$TMP/anubis/static.conf"
check "the static shadow keeps the application root" \
  grep -qx '    root /var/www/site.test/public;' "$TMP/anubis/static.conf"
check "the static shadow keeps the application rules" \
  grep -qx '    include h5bp/php_wp.conf;' "$TMP/anubis/static.conf"
check "the static shadow refuses a non-static URI" \
  grep -q 'if (\$uri !~\* ".*css|js' "$TMP/anubis/static.conf"
check "the static shadow refuses a missing file" \
  grep -qx '    if (!-f $request_filename) { return 404; }' "$TMP/anubis/static.conf"
check "the static shadow drops the public TLS listener" \
  bash -c '! grep -qE "listen +443|ssl_certificate|http2 on;" "$1"' _ "$TMP/anubis/static.conf"
check "the static shadow has a 404 default server for an unknown Host" \
  grep -qx "    listen unix:${ANUBIS_STATIC_SOCKET} default_server backlog=$(effective_backlog);" "$TMP/anubis/static.conf"
check "the catch-all block itself is not copied" \
  bash -c '! grep -q "^# shadow of .*default.conf" "$1"' _ "$TMP/anubis/static.conf"
check "the static shadow sets the active flag" test "$ANUBIS_STATIC_ACTIVE" = 1
anubis_render_terminators "$TMP/anubis/conf.d" "$TMP/anubis/terminators.conf"
check "the terminator proxies assets to the static shadow" \
  grep -q 'proxy_pass http://anubis_static;' "$TMP/anubis/terminators.conf"
check "an asset miss falls back to Anubis" \
  grep -qx '        error_page 404 = @anubis_static_miss;' "$TMP/anubis/terminators.conf"
static_md5=$(md5sum < "$TMP/anubis/static.conf")
anubis_render_static_blocks "$TMP/anubis/conf.d" "$TMP/anubis/static.conf"
check "the static shadow render is idempotent" \
  test "$static_md5" = "$(md5sum < "$TMP/anubis/static.conf")"
# A server-level redirect cannot be pushed through the proxy again.
cat > "$TMP/anubis/conf.d/redirect.test.conf" <<'EOF'
server {
    listen 443 ssl;
    server_name redirect.test;
    root /var/www/redirect.test/public;
    return 301 https://redirect.test$request_uri;
}
EOF
sed -i "s|listen 443 ssl;|listen unix:${ANUBIS_BACKEND_SOCKET};|" "$TMP/anubis/conf.d/redirect.test.conf"
anubis_render_static_blocks "$TMP/anubis/conf.d" "$TMP/anubis/static.conf"
check "a redirecting block gets no static shadow" \
  bash -c '! grep -q "server_name redirect.test;" "$1"' _ "$TMP/anubis/static.conf"
rm -f "$TMP/anubis/conf.d/redirect.test.conf"
# The operator switch turns the fast path off completely.
ANUBIS_STATIC_BYPASS=0
ANUBIS_STATIC_ACTIVE=0
anubis_render_static_blocks "$TMP/anubis/conf.d" "$TMP/anubis/static.conf" >/dev/null 2>&1 || true
check "disabling the fast path removes the static shadow" test ! -e "$TMP/anubis/static.conf"
check "disabling the fast path clears the active flag" test "$ANUBIS_STATIC_ACTIVE" = 0
ANUBIS_STATIC_BYPASS=1
anubis_render_terminators "$TMP/anubis/conf.d" "$TMP/anubis/terminators.conf"
check "no static location without the shadow" \
  bash -c '! grep -q "proxy_pass http://anubis_static;" "$1"' _ "$TMP/anubis/terminators.conf"


anubis_restore_vhosts "$TMP/anubis/conf.d" "$TMP/anubis/state/vhosts"
check "disabling Anubis restores the vhost byte-for-byte" \
  cmp -s "$TMP/anubis/site.before" "$TMP/anubis/conf.d/site.test.conf"
check "the restored vhost terminates TLS again" \
  grep -q 'listen      443 ssl;' "$TMP/anubis/conf.d/site.test.conf"

# A vhost that already carried a real-IP configuration must not keep reading
# a client-supplied X-Forwarded-For: the backend peer is the Anubis socket.
cat > "$TMP/anubis/conf.d/realip.test.conf" <<'EOF'
server {
    listen 443 ssl;
    server_name realip.test;
    real_ip_header X-Forwarded-For;
    set_real_ip_from 10.0.0.0/8;
}
EOF
anubis_integrate_vhost "$TMP/anubis/conf.d/realip.test.conf"
check "the migration drops a pre-existing real_ip_header" \
  bash -c '! grep -q "real_ip_header X-Forwarded-For" "$1"' _ "$TMP/anubis/conf.d/realip.test.conf"
check "the migrated block reads X-Real-IP only" \
  test "$(grep -c '^    real_ip_header X-Real-IP;' "$TMP/anubis/conf.d/realip.test.conf")" -eq 1
check "the migration keeps an operator's other trusted ranges" \
  grep -q 'set_real_ip_from 10.0.0.0/8;' "$TMP/anubis/conf.d/realip.test.conf"
anubis_restore_vhosts "$TMP/anubis/conf.d" "$TMP/anubis/state/vhosts"

# The generated terminator snippet: uploads are bounded by the backend vhost,
# not by the http-level 11m, and the client's X-Forwarded-For is replaced.
ANUBIS_LOCATION="$TMP/anubis/anubis-location.conf"
anubis_write_location
check "the terminator does not cap uploads at the http-level body size" \
  grep -qx 'client_max_body_size 0;' "$TMP/anubis/anubis-location.conf"
check "the terminator replaces X-Forwarded-For" \
  grep -qx 'proxy_set_header X-Forwarded-For \$remote_addr;' "$TMP/anubis/anubis-location.conf"
check "the terminator passes the client Accept-Encoding through" \
  grep -qx 'proxy_set_header Accept-Encoding \$http_accept_encoding;' "$TMP/anubis/anubis-location.conf"
check "the terminator no longer rewrites responses with sub_filter" \
  bash -c '! grep -q "^sub_filter" "$1"' _ "$TMP/anubis/anubis-location.conf"
ANUBIS_LOCATION=/etc/angie/snippets/anubis-location.conf

# No response-rewrite maps remain in the shared file.
ANUBIS_COMMON="$TMP/anubis/anubis-common.conf"
anubis_write_common
check "the Anubis common file has no encoding-strip map" \
  bash -c '! grep -q "anubis_strip_encoding\|anubis_upstream_accept_encoding" "$1"' _ "$TMP/anubis/anubis-common.conf"
check "the backend socket catch-all carries the somaxconn backlog" \
  grep -qx "    listen unix:${ANUBIS_BACKEND_SOCKET} default_server backlog=$(effective_backlog);" "$TMP/anubis/anubis-common.conf"
check "the backend socket catch-all drops an unknown Host" \
  bash -c 'grep -A3 "default_server backlog=" "$1" | grep -qx "    return 444;"' _ "$TMP/anubis/anubis-common.conf"
check "the terminator never spools a response to proxy_temp" \
  grep -qx 'proxy_max_temp_file_size 0;' "$TMP/anubis/anubis-location.conf"
check "the static shadow default server carries the backlog" \
  grep -q 'listen unix:${ANUBIS_STATIC_SOCKET} default_server backlog=$(effective_backlog);' "$ROOT/lib/anubis.sh"
# Edge route: what the policy allows without a cookie skips the Go hop, and
# the route is built from the same User-Agent patterns as the policy.
check "the terminator proxies to the edge route, not always to Anubis" \
  grep -qx 'proxy_pass http://\$anubis_route;' "$TMP/anubis/anubis-location.conf"
check "the edge route sends allowed crawlers straight to the backend" \
  grep -qxF "    \"~*(?:${ANUBIS_GOOD_UA_RE})\" anubis_backend;" "$TMP/anubis/anubis-common.conf"
check "the edge route leaves AI crawlers to Anubis (DENY)" \
  grep -qxF "    \"~*(?:${ANUBIS_AI_UA_RE})\"   anubis;" "$TMP/anubis/anubis-common.conf"
check "the edge route leaves browsers and an empty User-Agent to Anubis" \
  bash -c 'grep -qxF "    \"~Mozilla\"                   anubis;" "$1" && grep -qxF "    \"\"                           anubis;" "$1"' _ "$TMP/anubis/anubis-common.conf"
check "the edge route keeps the default-allow of the policy" \
  grep -qxF '    default                      anubis_backend;' "$TMP/anubis/anubis-common.conf"
check "Anubis endpoints always reach Anubis" \
  grep -qxF '    "~^/\.within\.website/"    anubis;' "$TMP/anubis/anubis-common.conf"
check "the good-crawler rule precedes the AI rule in the edge route (policy order)" \
  test "$(grep -n 'anubis_backend;$' "$TMP/anubis/anubis-common.conf" | sed -n 2p | cut -d: -f1)" -lt \
       "$(grep -n '~\*(?:GPTBot' "$TMP/anubis/anubis-common.conf" | cut -d: -f1)"
ANUBIS_POLICY="$TMP/anubis/botPolicies.yaml"
anubis_write_policy >/dev/null 2>&1 || true
check "the policy uses the same crawler patterns as the edge route" \
  bash -c 'grep -qxF "    user_agent_regex: (?i)($2)" "$1" && grep -qxF "    user_agent_regex: (?i)($3)" "$1"' \
  _ "$TMP/anubis/botPolicies.yaml" "$ANUBIS_GOOD_UA_RE" "$ANUBIS_AI_UA_RE"
check "the policy still ends with the browser challenge" \
  bash -c 'tail -n 3 "$1" | grep -qx "    user_agent_regex: Mozilla"' _ "$TMP/anubis/botPolicies.yaml"
ANUBIS_POLICY=/etc/anubis/botPolicies.yaml
ANUBIS_COMMON=/etc/angie/conf.d/00-anubis-common.conf

# The backend socket is created 0777, so the directory is the access control.
ANUBIS_TMPFILES="$TMP/anubis/tmpfiles.conf"
anubis_write_tmpfiles
check "the backend socket directory is private to root and anubis" \
  grep -qx 'd /run/angie 0750 root anubis -' "$TMP/anubis/tmpfiles.conf"
ANUBIS_TMPFILES=/etc/tmpfiles.d/angie-anubis.conf

# A vhost whose certificate comes from an http-level include has no
# ssl_certificate line; the terminator must fall back to the default
# certificate instead of leaving the site without a public listener.
cat > "$TMP/anubis/conf.d/nocert.test.conf" <<'EOF'
server {
    listen 443 ssl;
    server_name nocert.test;
}
EOF
anubis_integrate_vhost "$TMP/anubis/conf.d/nocert.test.conf"
anubis_render_terminators "$TMP/anubis/conf.d" "$TMP/anubis/terminators2.conf"
check "a vhost without a local certificate uses the default one" \
  grep -q 'ssl_certificate     /etc/angie/ssl/default/fullchain.pem;' "$TMP/anubis/terminators2.conf"
check "the default-certificate fallback is reported" \
  grep -q 'no ssl_certificate in the vhost, using the default certificate' "$TMP/anubis/terminators2.conf"

# ---------------------------------------------------------------------------
# Anubis runtime profile is hardware-derived
# ---------------------------------------------------------------------------
# The proxy must not carry values sized for one machine: GOMAXPROCS follows
# the core count (capped at the measured plateau), GOGC/GOMEMLIMIT follow RAM,
# and the fd ceiling follows cores.
check "Anubis GOMAXPROCS on 1 CPU" test "$(anubis_gomaxprocs 1)" = 1
check "Anubis GOMAXPROCS on 2 CPUs" test "$(anubis_gomaxprocs 2)" = 2
check "Anubis GOMAXPROCS on 4 CPUs" test "$(anubis_gomaxprocs 4)" = 4
check "Anubis GOMAXPROCS on 8 CPUs" test "$(anubis_gomaxprocs 8)" = 8
check "Anubis GOMAXPROCS caps at 8 on 16 CPUs" test "$(anubis_gomaxprocs 16)" = 8
check "Anubis GOMAXPROCS caps at 8 on 32 CPUs" test "$(anubis_gomaxprocs 32)" = 8
check "Anubis GOMAXPROCS caps at 8 on 64 CPUs" test "$(anubis_gomaxprocs 64)" = 8
check "Anubis GOGC keeps the default on 2 GB" test "$(anubis_gogc 2048)" = 100
check "Anubis GOGC on 4 GB" test "$(anubis_gogc 4096)" = 200
check "Anubis GOGC on 8 GB" test "$(anubis_gogc 8192)" = 300
check "Anubis GOGC on 16 GB" test "$(anubis_gogc 16384)" = off
check "Anubis GOGC on 64 GB" test "$(anubis_gogc 65536)" = off
check "Anubis GOMEMLIMIT floors at 256 MiB on 1 GB" test "$(anubis_memlimit_mb 1024)" = 256
check "Anubis GOMEMLIMIT on 4 GB" test "$(anubis_memlimit_mb 4096)" = 512
check "Anubis GOMEMLIMIT on 8 GB" test "$(anubis_memlimit_mb 8192)" = 1024
check "Anubis GOMEMLIMIT on 16 GB" test "$(anubis_memlimit_mb 16384)" = 2048
check "Anubis GOMEMLIMIT caps at 2 GiB on 64 GB" test "$(anubis_memlimit_mb 65536)" = 2048
check "Anubis LimitNOFILE floors on 1 CPU" test "$(anubis_nofile 1)" = 16384
check "Anubis LimitNOFILE on 8 CPUs" test "$(anubis_nofile 8)" = 32768
check "Anubis LimitNOFILE on 16 CPUs" test "$(anubis_nofile 16)" = 65536
check "Anubis LimitNOFILE caps on 64 CPUs" test "$(anubis_nofile 64)" = 131072
check "Anubis rejects a non-numeric CPU count" test "$(anubis_gomaxprocs bogus)" = 1
check "Anubis rejects a non-numeric RAM value" test "$(anubis_gogc bogus)" = 100

# The generated unit must carry the same values for a simulated host.  Run in
# a subshell so the stubs do not leak into other checks.
unit_profile=$( (
  ANUBIS_UNIT="$TMP/anubis-generated.service"
  effective_cpus() { printf '32'; }
  mem_total_mb() { printf '65536'; }
  # Earlier checks leave a systemctl stub that expects arguments; the writer
  # only needs a no-op here.
  systemctl() { :; }
  anubis_write_unit >/dev/null 2>&1 || true
  grep -hE '^(Environment=(GOGC|GOMEMLIMIT|GOMAXPROCS)|LimitNOFILE)=' "$ANUBIS_UNIT" 2>/dev/null | paste -sd' ' -
) )
check "the generated Anubis unit carries the 32 CPU / 64 GB profile" \
  test "$unit_profile" = "LimitNOFILE=131072 Environment=GOGC=off Environment=GOMEMLIMIT=2048MiB Environment=GOMAXPROCS=8"

unit_profile_small=$( (
  ANUBIS_UNIT="$TMP/anubis-generated-small.service"
  effective_cpus() { printf '2'; }
  mem_total_mb() { printf '2048'; }
  systemctl() { :; }
  anubis_write_unit >/dev/null 2>&1 || true
  grep -hE '^(Environment=(GOGC|GOMEMLIMIT|GOMAXPROCS)|LimitNOFILE)=' "$ANUBIS_UNIT" 2>/dev/null | paste -sd' ' -
) )
check "the generated Anubis unit carries the 2 CPU / 2 GB profile" \
  test "$unit_profile_small" = "LimitNOFILE=16384 Environment=GOGC=100 Environment=GOMEMLIMIT=256MiB Environment=GOMAXPROCS=2"

check "the Anubis unit keeps the filter in its own group with a 0750 runtime dir" \
  grep -qx 'Group=anubis' "$TMP/anubis-generated.service" \
  && grep -qx 'RuntimeDirectoryMode=0750' "$TMP/anubis-generated.service"

# ---------------------------------------------------------------------------
# Anubis own-page language (Thai catalogue panics -> 502)
# ---------------------------------------------------------------------------
unset SETUP_ANUBIS_LANGUAGE
check "Anubis forces English when no language is requested" \
  test "$(anubis_forced_language)" = en
check "Anubis accepts a complete locale override" \
  test "$(SETUP_ANUBIS_LANGUAGE=pt-BR anubis_forced_language)" = pt-BR
check "Anubis rejects an invalid language override" \
  test "$(SETUP_ANUBIS_LANGUAGE='th;rm -rf /' anubis_forced_language)" = en
en_body=$(sed -n '/^anubis_write_env()/,/^}/p' "$ALL_SRC")
check "the managed Anubis env pins FORCED_LANGUAGE" \
  grep -q '^FORCED_LANGUAGE=$(anubis_forced_language)$' <<<"$en_body"

# An outer-perimeter guard cannot pass over the Anubis socket: disable it.
guard_vhost="$TMP/vhost-guard.conf"
cat > "$guard_vhost" <<'EOF'
server {
    listen unix:/run/angie/anubis-backend.sock;
    set_real_ip_from unix:;
    real_ip_header X-Real-IP;
    server_name site-e.example;
    root /var/www/site-e.example/public;
    set_real_ip_from 203.0.113.23;
    real_ip_recursive on;
    if ($realip_remote_addr != "203.0.113.23") { return 444; }
    location / { index index.php; }
}
EOF
anubis_disable_realip_guards "$guard_vhost" >/dev/null 2>&1
check "an outer realip 444 guard is commented out" \
  grep -q '^#    if ($realip_remote_addr' "$guard_vhost"
check "the rest of the vhost is preserved" \
  grep -q '^    root /var/www/site-e.example/public;' "$guard_vhost"
check "a commented guard is not re-commented" \
  test "$(grep -c 'realip_remote_addr' "$guard_vhost")" -eq 1

multiline_vhost="$TMP/vhost-guard-multi.conf"
cat > "$multiline_vhost" <<'EOF'
server {
    server_name site-f.example;
    if ($realip_remote_addr != "203.0.113.23") {
        return 444;
    }
    location / { return 200; }
}
EOF
anubis_disable_realip_guards "$multiline_vhost" >/dev/null 2>&1
check "a multi-line realip guard is disabled as a block" \
  bash -c '! grep -qE "^(if|[[:space:]]*return 444)" "$1"' _ "$multiline_vhost"
check "the directive after a multi-line guard survives" \
  grep -q 'location / { return 200; }' "$multiline_vhost"

# ---------------------------------------------------------------------------
# --basic upgrade: needrestart runs after the upgrade, not from its APT hook
# ---------------------------------------------------------------------------
check "apt upgrade suspends the needrestart hook" \
  bash -c '[[ $(grep -c "NEEDRESTART_SUSPEND=1 apt-get upgrade" "$1") -eq 2 ]]' _ "$ROOT/lib/os.sh"
check "update_system restarts outdated services after the upgrade" \
  bash -c 'sed -n "/^update_system()/,/^}/p" "$1" | grep -q "^  restart_outdated_services$"' _ "$ROOT/lib/os.sh"
nr_log="$TMP/needrestart.calls"
: > "$nr_log"
(
  systemctl() { echo "systemctl $*" >> "$nr_log"; return 0; }
  needrestart() { echo "needrestart $*" >> "$nr_log"; return 0; }
  restart_outdated_services
)
check "restart pass waits for systemd then runs needrestart in auto mode" \
  bash -c 'head -n1 "$1" | grep -q "^systemctl show -p Version" && grep -q "^needrestart -r a -q$" "$1"' _ "$nr_log"
: > "$nr_log"
(
  systemctl() { return 1; }
  sleep() { :; }
  needrestart() { echo "needrestart $*" >> "$nr_log"; }
  warn() { echo "warn $*" >> "$nr_log"; }
  restart_outdated_services
)
check "restart pass is skipped with a warning while systemd is unreachable" \
  bash -c 'grep -q "^warn systemd did not answer" "$1" && ! grep -q "^needrestart" "$1"' _ "$nr_log"

# ---------------------------------------------------------------------------
# OPcache script table: written as the prime PHP rounds the value up to
# ---------------------------------------------------------------------------
check "OPcache table: the 16384 floor is written as 32531" test "$(php_opcache_table_size 16384)" = 32531
check "OPcache table: 19512 and 19518 files*1.5 give the same text" \
  test "$(php_opcache_table_size 19512)" = "$(php_opcache_table_size 19518)"
check "OPcache table: an exact prime is kept" test "$(php_opcache_table_size 65407)" = 65407
check "OPcache table: the 128256 ceiling is written as 130987" test "$(php_opcache_table_size 128256)" = 130987

# ---------------------------------------------------------------------------
# Flarum guest-cache gate migration (server-configs-nginx 1.6.43-1.6.45)
# ---------------------------------------------------------------------------
fl="$TMP/flarum-tree"
mkdir -p "$fl/h5bp" "$fl/http.d"
cat > "$fl/h5bp/php_flarum.conf" <<'EOF'
location ~ [^/]\.php(/|$) {
if ($flarum_guest_cacheable$req_encoded_path) { return 418; }
}
location @flarum_guest_cache {
fastcgi_cache_lock      on;
}
EOF
cat > "$fl/http.d/fastcgi_cache_flarum.conf" <<'EOF'
map "$guest_cache_method:$flarum_guest_cookie:$flarum_nocache_uri:$http_authorization" $flarum_guest_cacheable {
    default 0;
    "1:0:0:" 1;
}
EOF
tune_flarum_cache_gate "$fl"
check "Flarum gate: the if tests one variable" \
  grep -qx 'if ($flarum_guest_cacheable) { return 418; }' "$fl/h5bp/php_flarum.conf"
check "Flarum gate: the map carries the encoded-path flag" \
  grep -qF ':$flarum_nocache_uri:$req_encoded_path:$http_authorization" $flarum_guest_cacheable {' "$fl/http.d/fastcgi_cache_flarum.conf"
check "Flarum gate: the cacheable key gains the extra 0" \
  grep -qx '    "1:0:0:0:" 1;' "$fl/http.d/fastcgi_cache_flarum.conf"
check "Flarum gate: background cache update is added after the lock" \
  bash -c 'grep -A1 "fastcgi_cache_lock      on;" "$1" | grep -qx "fastcgi_cache_background_update on;"' _ "$fl/h5bp/php_flarum.conf"
fl_sum=$(cat "$fl/h5bp/php_flarum.conf" "$fl/http.d/fastcgi_cache_flarum.conf" | cksum)
tune_flarum_cache_gate "$fl"
check "Flarum gate: a second pass changes nothing" \
  test "$fl_sum" = "$(cat "$fl/h5bp/php_flarum.conf" "$fl/http.d/fastcgi_cache_flarum.conf" | cksum)"
printf 'map "$x" $flarum_guest_cacheable {\n    default 0;\n}\n' > "$fl/http.d/fastcgi_cache_flarum.conf"
printf 'if ($flarum_guest_cacheable$req_encoded_path) { return 418; }\n' > "$fl/h5bp/php_flarum.conf"
tune_flarum_cache_gate "$fl"
check "Flarum gate: an operator-edited map leaves the include untouched" \
  grep -qF 'if ($flarum_guest_cacheable$req_encoded_path)' "$fl/h5bp/php_flarum.conf"
check_tree "Flarum gate: the shipped tree has no joined-variable if" \
  bash -c '! grep -rqF "\$flarum_guest_cacheable\$req_encoded_path" "$1/h5bp" "$1/http.d"' _ "$ANGIE_TREE"

# Catch-all 443: unknown/missing SNI is refused before a certificate is sent.
tl="$TMP/tls-tree"
mkdir -p "$tl/conf.d"
cat > "$tl/conf.d/1.https.default.conf" <<'EOF'
server {
  listen      443 ssl default_server deferred backlog=16383 reuseport fastopen=256;
  server_name _;
  include h5bp/default_ssl.conf;
  return 444;
}
EOF
tune_default_tls_reject "$tl"
check "default TLS server: reject handshake inserted before the cert include" \
  bash -c 'grep -B1 "include h5bp/default_ssl.conf;" "$1" | grep -qx "  ssl_reject_handshake on;"' _ "$tl/conf.d/1.https.default.conf"
tl_sum=$(cksum < "$tl/conf.d/1.https.default.conf")
tune_default_tls_reject "$tl"
check "default TLS server: a second pass changes nothing" test "$tl_sum" = "$(cksum < "$tl/conf.d/1.https.default.conf")"
check_tree "default TLS server: the shipped tree already rejects" \
  grep -qx '  ssl_reject_handshake on;' "$ANGIE_TREE/conf.d/1.https.default.conf"

# A reverse proxy outside Cloudflare that connects without the site's SNI
# had every handshake refused (site-d.example 502 behind 203.0.113.23).
mkdir -p "$tl/http.d"
printf 'set_real_ip_from 173.245.48.0/20;\nset_real_ip_from 2400:cb00::/32;\nreal_ip_header CF-Connecting-IP;\n' \
  > "$tl/http.d/cloudflare.conf"
printf 'server {\n  server_name cf.example;\n  set_real_ip_from 173.245.48.10;\n  set_real_ip_from 2400:cb00::1;\n  set_real_ip_from unix:;\n  # set_real_ip_from 9.9.9.9;\n}\n' \
  > "$tl/conf.d/cf.example.conf"
frag_high_first() {
  local fam=$1 hi lo
  hi=$(grep -nE "^net\.${fam}_high_thresh" "$ROOT/configs/system/sysctl.conf" | cut -d: -f1)
  lo=$(grep -nE "^net\.${fam}_low_thresh" "$ROOT/configs/system/sysctl.conf" | cut -d: -f1)
  [[ -n $hi && -n $lo ]] && (( hi < lo ))
}
check "sysctl template: IPv4 fragment high mark precedes the low mark (boot raises them)" \
  frag_high_first ipv4.ipfrag
check "sysctl template: IPv6 fragment high mark precedes the low mark (boot raises them)" \
  frag_high_first ipv6.ip6frag
check "TLS reject guard: Cloudflare sources, unix: and comments are not proxies" \
  test -z "$(tls_reject_front_proxies "$tl")"
tl_sum=$(cksum < "$tl/conf.d/1.https.default.conf")
tune_default_tls_reject "$tl"
check "TLS reject guard: a Cloudflare-only host keeps the rejection" \
  test "$tl_sum" = "$(cksum < "$tl/conf.d/1.https.default.conf")"
printf 'server {\n  server_name site-d.example;\n  set_real_ip_from 203.0.113.23;\n  real_ip_header X-Forwarded-For;\n}\n' \
  > "$tl/conf.d/site-d.example.conf"
check "TLS reject guard: a vhost trusting a non-Cloudflare proxy is found" \
  test "$(tls_reject_front_proxies "$tl")" = "site-d.example.conf:203.0.113.23"
TUNE_CHANGES=(); TUNE_DIRTY=0
tune_default_tls_reject "$tl"
check "TLS reject guard: behind such a proxy the rejection is commented out" \
  bash -c '! grep -qE "^[[:space:]]*ssl_reject_handshake[[:space:]]+on" "$1" && grep -qF "# ssl_reject_handshake on;  # setup.sh: off" "$1"' _ "$tl/conf.d/1.https.default.conf"
check "TLS reject guard: the report names the proxy and the override" \
  bash -c 'printf "%s\n" "${@}" | grep -q "203.0.113.23.*SSL_REJECT_UNKNOWN_SNI=1"' _ "${TUNE_CHANGES[@]}"
tl_sum=$(cksum < "$tl/conf.d/1.https.default.conf")
TUNE_DIRTY=0
tune_default_tls_reject "$tl"
check "TLS reject guard: a second pass changes nothing and is not dirty" \
  bash -c '[[ $1 == "$2" && $3 == 0 ]]' _ "$tl_sum" "$(cksum < "$tl/conf.d/1.https.default.conf")" "$TUNE_DIRTY"
SSL_REJECT_UNKNOWN_SNI=1 tune_default_tls_reject "$tl"
check "TLS reject guard: SSL_REJECT_UNKNOWN_SNI=1 restores the directive" \
  grep -qx '  ssl_reject_handshake on;' "$tl/conf.d/1.https.default.conf"
rm -f "$tl/conf.d/site-d.example.conf"
SSL_REJECT_UNKNOWN_SNI=0 tune_default_tls_reject "$tl"
check "TLS reject guard: SSL_REJECT_UNKNOWN_SNI=0 turns it off without a proxy" \
  grep -qF "# ssl_reject_handshake on;  # setup.sh: off" "$tl/conf.d/1.https.default.conf"
tune_default_tls_reject "$tl"
check "TLS reject guard: back on automatically once the proxy is gone" \
  grep -qx '  ssl_reject_handshake on;' "$tl/conf.d/1.https.default.conf"
rm -f "$tl/http.d/cloudflare.conf"
printf 'server {\n  set_real_ip_from 173.245.48.10;\n}\n' > "$tl/conf.d/cf.example.conf"
check "TLS reject guard: without the ranges file every source counts (fail safe)" \
  test -n "$(tls_reject_front_proxies "$tl")"
# Every other way a vhost names the proxy in front (review of 1.21.52).
tp="$TMP/tls-proxy-forms"
mkdir -p "$tp/conf.d" "$tp/http.d" "$tp/snippets" "$tp/custom.d"
printf 'set_real_ip_from 173.245.48.0/20;\nset_real_ip_from 2400:cb00::/32;\n' > "$tp/http.d/cloudflare.conf"
tls_proxies_for() { printf '%s\n' "$1" > "$tp/conf.d/site.conf"; tls_reject_front_proxies "$tp" | sort -u | paste -sd' ' -; }
check "TLS reject guard: allow ADDR (origin locked to the proxy) counts" \
  test "$(tls_proxies_for 'server { allow 203.0.113.23; deny all; }')" = "site.conf:203.0.113.23"
check "TLS reject guard: the Pingvin-style realip 444 gate counts" \
  test "$(tls_proxies_for 'server { if ($realip_remote_addr != "203.0.113.23") { return 444; } }')" = "site.conf:203.0.113.23"
check "TLS reject guard: set_real_ip_from after another directive on one line counts" \
  test "$(tls_proxies_for 'server { real_ip_header X-Forwarded-For; set_real_ip_from 10.0.0.5; }')" = "site.conf:10.0.0.5"
printf 'set_real_ip_from 198.51.100.7;\n' > "$tp/snippets/front-proxy.conf"
check "TLS reject guard: set_real_ip_from in an included snippet counts" \
  test "$(tls_proxies_for 'server { include snippets/front-*.conf; }')" = "front-proxy.conf:198.51.100.7"
rm -f "$tp/snippets/front-proxy.conf"
printf '"203.0.113.9:https" on;\n' > "$tp/custom.d/https_trusted_peers.map"
check "TLS reject guard: a trusted HTTPS peer in custom.d counts" \
  test "$(tls_proxies_for 'map "$realip_remote_addr:$http_x_forwarded_proto" $app_https { default ""; include custom.d/https_trusted_peers[.]map; }')" = "https_trusted_peers.map:203.0.113.9"
rm -f "$tp/custom.d/https_trusted_peers.map"
check "TLS reject guard: the shipped https_map key is not an address comparison" \
  test -z "$(tls_proxies_for 'map "$realip_remote_addr:$http_x_forwarded_proto" $app_https { default ""; }')"
printf 'geo $limit_req_whitelist {\n  default 0;\n  127.0.0.1 1;\n  203.0.113.23 1; # setup.sh exempt\n}\n' > "$tp/http.d/limit_req.conf"
check "TLS reject guard: a rate-limit exemption (LIMIT_REQ_EXEMPT) counts, loopback does not" \
  test "$(tls_proxies_for 'server { }')" = "limit_req.conf:203.0.113.23"
rm -f "$tp/http.d/limit_req.conf"
check "TLS reject guard: loopback and allow all are not proxies" \
  test -z "$(tls_proxies_for 'server { allow 127.0.0.1; allow ::1; set_real_ip_from 127.0.0.1; allow all; }')"
check "TLS reject guard: a CIDR wider than the Cloudflare range it starts in counts" \
  test "$(tls_proxies_for 'server { set_real_ip_from 173.245.48.0/16; }')" = "site.conf:173.245.48.0/16"
check "TLS reject guard: a CIDR inside a Cloudflare range does not count" \
  test -z "$(tls_proxies_for 'server { set_real_ip_from 173.245.49.0/24; set_real_ip_from 2400:cb00:1::/48; }')"
# The sync re-copies the shipped (uncommented) catch-all before every run:
# the guard must land on the same file each time.
tlr="$TMP/tls-resync"
mkdir -p "$tlr/conf.d" "$tlr/http.d"
printf 'server {\n  listen 443 ssl default_server;\n  server_name _;\n  ssl_reject_handshake on;\n  include h5bp/default_ssl.conf;\n  return 444;\n}\n' > "$tlr/shipped.conf"
printf 'server { set_real_ip_from 203.0.113.23; }\n' > "$tlr/conf.d/site.conf"
cp "$tlr/shipped.conf" "$tlr/conf.d/1.https.default.conf"; tune_default_tls_reject "$tlr"
tl_sum=$(cksum < "$tlr/conf.d/1.https.default.conf")
cp "$tlr/shipped.conf" "$tlr/conf.d/1.https.default.conf"; tune_default_tls_reject "$tlr"
check "TLS reject guard: a re-synced catch-all ends identical to the first run" \
  test "$tl_sum" = "$(cksum < "$tlr/conf.d/1.https.default.conf")"
printf 'server {\n  listen 443 ssl default_server;\n  ssl_reject_handshake on;\n  return 403;\n}\n' > "$tlr/conf.d/1.https.default.conf"
SSL_REJECT_UNKNOWN_SNI=0 tune_default_tls_reject "$tlr"
check "TLS reject guard: an operator-edited catch-all is still switched off" \
  grep -qF "# ssl_reject_handshake on;  # setup.sh: off" "$tlr/conf.d/1.https.default.conf"
check_tree "TLS reject guard: the shipped tree names no front proxy (every plain host keeps the rejection)" \
  bash -c 'test -z "$1"' _ "$(tls_reject_front_proxies "$ANGIE_TREE")"
check "SSL_REJECT_UNKNOWN_SNI survives a profile reset" \
  grep -qE '^  CPU_MITIGATIONS .*SSL_REJECT_UNKNOWN_SNI' "$ROOT/lib/overrides.sh"

# PHP optional extensions: one transaction first (one php-fpm restart),
# per-package fallback with the systemd start limit cleared.
php_install_body=$(sed -n '/^install_php()/,/^}/p' "$ALL_SRC")
check "optional PHP extensions are installed in one transaction first" \
  grep -qF 'apt_install "${optional_ok[@]}"' <<<"$php_install_body"
check "the per-package fallback clears the php-fpm start limit" \
  bash -c 'grep -A4 "for pkg in \"\${optional_ok\[@\]}\"" <<<"$1" | grep -q "reset-failed"' _ "$php_install_body"

# --purge others leaves units that were enabled before setup.sh touched them.
unit_state_dir=$STATE_DIR
mkdir -p "$unit_state_dir"
rm -f "$unit_state_dir"/preenabled-unit-* "$unit_state_dir"/unit-state-recorded-*
(
  ensure_state() { :; }
  systemctl() { [[ $1 == is-enabled && $3 == sysstat-collect.timer ]]; }
  unit_record_preenabled sysstat-collect.timer smartd
  # a later run (after setup.sh enabled smartd) must not rewrite the record
  systemctl() { [[ $1 == is-enabled ]]; }
  unit_record_preenabled smartd
)
check "a unit enabled before setup.sh is recorded as the operator's" \
  test -f "$unit_state_dir/preenabled-unit-sysstat-collect.timer"
check "a unit setup.sh enabled is not recorded as pre-enabled on a re-run" \
  test ! -f "$unit_state_dir/preenabled-unit-smartd"
check "purge_others skips pre-enabled units" \
  bash -c 'sed -n "/^purge_others()/,/^}/p" "$1" | grep -q "unit_preenabled"' _ "$ROOT/lib/purge.sh"

check "MariaDB AppArmor block allows the sysfs dev reads (NVMe paths too)" \
  bash -c 'sed -n "/^configure_mariadb_apparmor()/,/^}/p" "$1" | grep -qF "/sys/devices/**/dev r,"' _ "$ROOT/lib/services.sh"

aa_tmp=$(mktemp)
printf "%s\n" "# operator rule" "/srv/x r," "# BEGIN setup.sh who nameservice" "include <abstractions/nameservice-strict>" "# END setup.sh who nameservice" > "$aa_tmp"
check "apparmor_local_strip drops only the managed block" \
  test "$(apparmor_local_strip "$aa_tmp" "who nameservice")" = "$(printf "%s\n" "# operator rule" "/srv/x r,")"
rm -f "$aa_tmp"
check "who(1) AppArmor override is written by --basic and --optimize and removed by --purge basic" \
  bash -c 'sed -n "/^install_basic()/,/^}/p" "$1" | grep -q configure_who_apparmor \
    && sed -n "/^run_os_tuning()/,/^}/p" "$2" | grep -q configure_who_apparmor \
    && sed -n "/^purge_basic()/,/^}/p" "$3" | grep -qF "apparmor_local_clear who"' \
  _ "$ROOT/lib/os.sh" "$ROOT/lib/restart.sh" "$ROOT/lib/purge.sh"

check "IPv4 fragment reassembly never goes below the kernel default (4 MB)" \
  bash -c 'grep -qF "(( ipfrag_high < 4194304 )) && ipfrag_high=4194304" "$1" && grep -qE "^net\.ipv6\.ip6frag_high_thresh = 4194304$" "$2"' \
  _ "$ROOT/lib/os.sh" "$ROOT/configs/system/sysctl.conf"

# ---------------------------------------------------------------------------
# Memory plan books Elasticsearch direct memory and OPcache huge pages
# ---------------------------------------------------------------------------
mem_plan_reset() {
  php_primary_version() { printf '8.4'; }
  php_worker_allowance_mb() { printf '64'; }
  mariadb_data_size_mb() { printf '0'; }
  mariadb_current_pool_mb() { printf '0'; }
  mariadb_data_dir_size_mb() { printf '0'; }
  elasticsearch_data_size_mb() { printf '0'; }
  elasticsearch_data_dir_size_mb() { printf '0'; }
  elasticsearch_current_heap_mb() { printf '0'; }
  valkey_live_used_mb() { return 0; }
  valkey_current_maxmemory_mb() { printf '0'; }
  valkey_policy_evicts() { printf '1'; }
  valkey_active_conf() { :; }
  valkey_data_size_mb() { printf '0'; }
  hugepages_php_present() { return 1; }
  host_is_container() { return 1; }
  elasticsearch_operator_direct_mb() { :; }
  rm -f "$SETUP_STATE_DIR/explicit-options.conf"
  OPT_INSTALL_PLAN=0
}
plan_snapshot() {
  printf '%s ' "$OPT_PHP_CHILDREN" "$OPT_PHP_BUDGET_MB" "$OPT_MARIADB_BUDGET_MB" \
    "$OPT_VALKEY_BUDGET_MB" "$OPT_ES_BUDGET_MB" "$OPT_ES_DIRECT_MB" \
    "$OPT_ES_DIRECT_BOOKED_MB" "$OPT_HUGEPAGES_MB" "$OPT_MEM_OVERCOMMIT_MB"
}

# (a) Huge pages come off the services' share; on a roomy host nothing moves.
mem_plan_reset
mem_total_mb() { printf '131072'; }
effective_cpus() { printf '16'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
hp_off=$(printf '%s ' "$OPT_PHP_CHILDREN" "$OPT_MARIADB_BUDGET_MB" "$OPT_VALKEY_BUDGET_MB" "$OPT_ES_BUDGET_MB")
hugepages_php_present() { return 0; }
plan_memory_budget
check "a 128 GB PHP host books 592 MB of OPcache huge pages" test "$OPT_HUGEPAGES_MB" -eq 592
check "booking the huge pages leaves a roomy host's allocations unchanged" \
  test "$(printf '%s ' "$OPT_PHP_CHILDREN" "$OPT_MARIADB_BUDGET_MB" "$OPT_VALKEY_BUDGET_MB" "$OPT_ES_BUDGET_MB")" = "$hp_off"
check "the 512 MB heap books its 256 MB direct ceiling" \
  test "$OPT_ES_DIRECT_MB:$OPT_ES_DIRECT_BOOKED_MB" = 256:256
check "the summary names ES direct memory and huge pages" \
  bash -c '[[ $1 == *" ES-direct=256MB HugePages=592MB)" ]]' _ "$(memory_plan_summary)"
OPT_DETECTED=(angie php:8.4 mariadb valkey)
hugepages_php_present() { return 1; }
plan_memory_budget
check "without ES or huge pages the summary keeps its old form" \
  bash -c '[[ $1 == *" Elasticsearch=0MB)" && $1 != *ES-direct* && $1 != *HugePages* ]]' _ "$(memory_plan_summary)"

# (b) Direct memory follows the heap that is written, or the operator value.
mem_plan_reset
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
elasticsearch_data_size_mb() { printf '4096'; }
plan_memory_budget
check "a 1 GB heap books a 512 MB direct ceiling" \
  test "$OPT_ES_BUDGET_MB:$OPT_ES_DIRECT_MB:$OPT_ES_DIRECT_BOOKED_MB" = 1024:512:512
elasticsearch_operator_direct_mb() { printf '1024'; }
plan_memory_budget
check "an operator MaxDirectMemorySize is booked verbatim" \
  test "$OPT_ES_DIRECT_MB:$OPT_ES_DIRECT_BOOKED_MB:$OPT_ES_DIRECT_OPERATOR" = 1024:1024:1
elasticsearch_operator_direct_mb() { :; }
mkdir -p "$SETUP_STATE_DIR"
printf 'elastic_mb=1000\n' > "$SETUP_STATE_DIR/explicit-options.conf"
plan_memory_budget
check "an explicit heap books half of the heap that is written" \
  test "$OPT_ES_DIRECT_MB" -eq $(( (OPT_ES_BUDGET_MB + 1) / 2 ))
rm -f "$SETUP_STATE_DIR/explicit-options.conf"
# A tight host with an explicit heap: heap + heap/2 must fit beside MariaDB,
# so MariaDB gets 3225 MB (it got 4096 when the direct share was not booked
# at all).  The reservation (fixed_sum) or the trim pass may take the share;
# either way the plan must fit.
mem_total_mb() { printf '8192'; }
effective_cpus() { printf '2'; }
OPT_DETECTED=(angie php:8.4 mariadb elastic)
mariadb_data_size_mb() { printf '8000'; }
elasticsearch_data_size_mb() { printf '0'; }
printf 'elastic_mb=2048\n' > "$SETUP_STATE_DIR/explicit-options.conf"
plan_memory_budget
check "explicit 2 GB heap on 8 GB: 1 GB direct booked beside it" \
  test "$OPT_ES_BUDGET_MB:$OPT_ES_DIRECT_BOOKED_MB" = 2048:1024
check "explicit 2 GB heap on 8 GB: MariaDB leaves room for the direct share (3225)" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 3225
check "explicit 2 GB heap on 8 GB: everything booked fits, no overcommit" \
  test "$OPT_MEM_OVERCOMMIT_MB" -eq 0
rm -f "$SETUP_STATE_DIR/explicit-options.conf"

# (c) Below 4 GB the direct ceiling first uses the OS headroom above 10%.
#     2 GB all-in-one with a 1 GB database: usable 1638, credit 206, so a
#     512 MB heap books 50 MB; MariaDB 692 (742 before, 486 without credit).
mem_plan_reset
mem_total_mb() { printf '2048'; }
effective_cpus() { printf '2'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
mariadb_data_size_mb() { printf '1000'; }
plan_memory_budget
small_first=$(plan_snapshot)
check "2 GB host: the 512 MB heap books 50 of its 256 MB direct ceiling" \
  test "$OPT_ES_DIRECT_MB:$OPT_ES_DIRECT_BOOKED_MB" = 256:50
check "2 GB host: MariaDB gives up 50 MB to the booked direct memory (692)" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 692
check "2 GB host: the plan still fits (no overcommit)" test "$OPT_MEM_OVERCOMMIT_MB" -eq 0
mariadb_current_pool_mb() { printf '692'; }
plan_memory_budget
check "2 GB host: the next --optimize writes the same plan" test "$(plan_snapshot)" = "$small_first"
mem_plan_reset
mem_total_mb() { printf '1536'; }
plan_memory_budget 2>/dev/null
check "1.5 GB all-in-one does not newly report an overcommit" test "$OPT_MEM_OVERCOMMIT_MB" -eq 0
# The install writes the 256 MB RAM-floor pool; the first --optimize sees an
# empty database (target 128) and keeps that pool.  The kept-pool trim must
# not go below the split's 256 MB floor, or 1-1.5 GB all-in-ones would drop
# to 231/128 MB and restart MariaDB right after the install.
for small in 1024 1536; do
  mem_plan_reset
  # shellcheck disable=SC2329  # stub called by plan_memory_budget
  mem_total_mb() { printf '%s' "$small"; }
  effective_cpus() { printf '2'; }
  OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
  OPT_INSTALL_PLAN=1
  plan_memory_budget 2>/dev/null
  small_install=$(plan_snapshot)
  small_pool=$OPT_MARIADB_BUDGET_MB
  OPT_INSTALL_PLAN=0
  # shellcheck disable=SC2329  # stub called by plan_memory_budget
  mariadb_current_pool_mb() { printf '%s' "$small_pool"; }
  plan_memory_budget 2>/dev/null
  check "${small} MB all-in-one: install and --optimize write the same plan (pool ${small_pool} MB)" \
    test "$(plan_snapshot)" = "$small_install"
done
mem_plan_reset

# (d) 8 GB host where the booking changes values: PHP + MariaDB (4 GB of
#     data) + Elasticsearch (8 GB index), 592 MB of huge pages.  Before:
#     MariaDB 4096 + heap 2048, a true footprint of ~7.9 GB against 6.5 GB.
mem_plan_reset
mem_total_mb() { printf '8192'; }
effective_cpus() { printf '2'; }
hugepages_php_present() { return 0; }
OPT_DETECTED=(angie php:8.4 mariadb elastic)
mariadb_data_size_mb() { printf '4000'; }
elasticsearch_data_size_mb() { printf '8000'; }
plan_memory_budget
mid_first=$(plan_snapshot)
check "8 GB host: MariaDB is scaled to 3260 MB" test "$OPT_MARIADB_BUDGET_MB" -eq 3260
check "8 GB host: the heap is 1536 MB with 768 MB direct" \
  test "$OPT_ES_BUDGET_MB:$OPT_ES_DIRECT_MB:$OPT_ES_DIRECT_BOOKED_MB" = 1536:768:768
check "8 GB host: huge pages booked, no overcommit" \
  test "$OPT_HUGEPAGES_MB:$OPT_MEM_OVERCOMMIT_MB" = 592:0
check "8 GB host: everything booked stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_ES_BUDGET_MB + OPT_ES_DIRECT_BOOKED_MB + OPT_HUGEPAGES_MB )) -le $(( 8192 * 80 / 100 ))
mariadb_current_pool_mb() { printf '3260'; }
elasticsearch_current_heap_mb() { printf '1536'; }
plan_memory_budget
check "8 GB host: the next --optimize writes the same plan" test "$(plan_snapshot)" = "$mid_first"

# (e) A pool far above its data target is shrunk to the target and then
#     scaled with the others in one run (5000 -> 3260, not via 3533).
mariadb_current_pool_mb() { printf '5000'; }
elasticsearch_current_heap_mb() { printf '0'; }
plan_memory_budget
check "a 5000 MB pool settles at 3260 MB in one run" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 3260:0
elasticsearch_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '5500'; }
plan_memory_budget
check "a 5500 MB pool for 4000 MB of data shrinks to its target (data+5%, capped at half of RAM: 4096 MB)" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 4096:0
mariadb_current_pool_mb() { printf '4300'; }
plan_memory_budget
check "a 4300 MB pool above the 4096 MB RAM cap is not kept by the band" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 4096:0
mariadb_data_size_mb() { printf '3000'; }
mariadb_current_pool_mb() { printf '3400'; }
plan_memory_budget
check "a 3400 MB pool inside the keep band (3150 + 157 + 128) is kept" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 3400:3400
plan_memory_budget
check "the kept pool is kept by the next run" \
  test "$OPT_MARIADB_BUDGET_MB:$OPT_MARIADB_KEPT_MB" = 3400:3400
mariadb_data_size_mb() { printf '4000'; }

# (f) Install/--optimize parity: the install plan sees PHP through ENABLED,
#     --optimize through /etc/php; both book the same pages and direct share.
mem_plan_reset
mem_total_mb() { printf '27812'; }
effective_cpus() { printf '16'; }
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
ENABLED[php]=1
hugepages_php_present() { (( ${ENABLED[php]:-0} == 1 )); }
OPT_INSTALL_PLAN=1
plan_memory_budget
install_view="$OPT_HUGEPAGES_MB $OPT_ES_DIRECT_MB $OPT_ES_BUDGET_MB $OPT_PHP_CHILDREN"
unset 'ENABLED[php]'
OPT_INSTALL_PLAN=0
hugepages_php_present() { return 0; }
plan_memory_budget
check "install and --optimize book the same huge pages, direct share, heap and pool" \
  test "$OPT_HUGEPAGES_MB $OPT_ES_DIRECT_MB $OPT_ES_BUDGET_MB $OPT_PHP_CHILDREN" = "$install_view"
check "the parity host books 592 MB of huge pages and 256 MB direct" \
  test "$OPT_HUGEPAGES_MB:$OPT_ES_DIRECT_MB" = 592:256
mem_plan_reset
OPT_DETECTED=()


# ---------------------------------------------------------------------------
# CPU mitigations switch (GRUB drop-in)
# ---------------------------------------------------------------------------
check "the mitigations drop-in keeps the provider's kernel options" \
  bash -c 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"; eval "$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" <<<"$1")"; [[ $GRUB_CMDLINE_LINUX_DEFAULT == "quiet splash mitigations=off" ]]' \
  _ "$(cpu_mitigations_dropin_text)"
check "the mitigations drop-in works on an empty default line" \
  bash -c 'GRUB_CMDLINE_LINUX_DEFAULT=""; eval "$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" <<<"$1")"; [[ $GRUB_CMDLINE_LINUX_DEFAULT == "mitigations=off" ]]' \
  _ "$(cpu_mitigations_dropin_text)"
mit_run() { # want -> "<file present 0/1> <update-grub calls>"
  (
    CPU_MITIGATIONS_DROPIN=$TMP/mit/grub.d/zz-setup-mitigations.cfg
    CPU_MITIGATIONS_LEGACY_DROPIN=$TMP/mit/grub.d/99-setup-mitigations.cfg
    CPU_MITIGATIONS=$1 CPU_MITIGATIONS_SETTING=""
    host_is_container() { return 1; }
    harden_note() { printf 'NOTE %s\n' "$*" >> "$TMP/mit/report"; }
    info() { printf 'INFO %s\n' "$*" >> "$TMP/mit/report"; }
    CPU_MITIGATIONS_GRUBCFG=$TMP/mit/grub.cfg
    # A fake update-grub: count the calls and write the boot menu the drop-in
    # would produce (MIT_GRUB_FAIL=1 simulates a failing regeneration,
    # MIT_OVERRIDE=1 a provider drop-in that erases the option).
    update-grub() {
      printf x >> "$TMP/mit/calls"
      [[ ${MIT_GRUB_FAIL:-0} == 1 ]] && return 1
      if [[ -f $CPU_MITIGATIONS_DROPIN && ${MIT_OVERRIDE:-0} != 1 ]]; then
        echo "	linux /vmlinuz root=x ro mitigations=off" > "$CPU_MITIGATIONS_GRUBCFG"
      else
        echo "	linux /vmlinuz root=x ro" > "$CPU_MITIGATIONS_GRUBCFG"
      fi
    }
    harden_warn() { printf 'WARN %s\n' "$*" >> "$TMP/mit/report"; }
    [[ -f /etc/default/grub ]] || exit 3
    configure_cpu_mitigations >/dev/null 2>&1
    printf '%s %s' "$([[ -f $CPU_MITIGATIONS_DROPIN ]] && echo 1 || echo 0)" "$(wc -c < "$TMP/mit/calls")"
  )
}
if [[ -f /etc/default/grub ]]; then
  mkdir -p "$TMP/mit"; : > "$TMP/mit/calls"
  check "mitigations=off writes the drop-in and runs update-grub once" test "$(mit_run off)" = "1 1"
  check "a second mitigations=off changes nothing (no update-grub)" test "$(mit_run off)" = "1 1"
  check "mitigations=on removes the drop-in and runs update-grub" test "$(mit_run on)" = "0 2"
  check "an unset choice never touches the boot loader" test "$(mit_run '')" = "0 2"
  # The drop-in is present but the boot menu lacks mitigations=off (an earlier
  # update-grub failed): the next run regenerates it.
  mit_run off >/dev/null; echo "	linux /vmlinuz root=x ro" > "$TMP/mit/grub.cfg"
  : > "$TMP/mit/calls"
  check "a boot menu without mitigations=off is regenerated on the next run" test "$(mit_run off)" = "1 1"
  rm -f "$TMP/mit/grub.d/zz-setup-mitigations.cfg"; : > "$TMP/mit/calls"
  check "a failing update-grub never fails the run" test "$(MIT_GRUB_FAIL=1 mit_run off)" = "1 1"
  # Pre-1.21.44 name: retired, the new drop-in written, the menu regenerated.
  rm -f "$TMP/mit/grub.d/"*; echo 'GRUB_CMDLINE_LINUX_DEFAULT="x mitigations=off"' > "$TMP/mit/grub.d/99-setup-mitigations.cfg"
  : > "$TMP/mit/calls"
  mit_legacy_out=$(mit_run off)
  check "the old 99-setup-mitigations.cfg is replaced by zz-setup-mitigations.cfg" \
    bash -c 'test "$1" = "1 1" && test ! -e "$2/99-setup-mitigations.cfg" && test -f "$2/zz-setup-mitigations.cfg"' _ "$mit_legacy_out" "$TMP/mit/grub.d"
  # A provider drop-in sorted after ours erases the option: the run warns
  # and names it instead of reporting "off at the next reboot" (Hetzner).
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0"\n' > "$TMP/mit/grub.d/zzz-provider.cfg"
  # The menu update-grub generated with that provider file lacks the option.
  echo "	linux /vmlinuz root=x ro consoleblank=0" > "$TMP/mit/grub.cfg"
  : > "$TMP/mit/report"
  MIT_OVERRIDE=1 mit_run off >/dev/null
  check "an overridden boot menu is reported, naming the overriding drop-in" \
    grep -q "^WARN .*no mitigations=off.*zzz-provider.cfg" "$TMP/mit/report"
  check "an overridden boot menu is never reported as 'off at the next reboot'" \
    not grep -q "at the next reboot" "$TMP/mit/report"
  rm -f "$TMP/mit/grub.d/zzz-provider.cfg"
fi
# Drop-in order is what grub-mkconfig's glob gives: ours must come after the
# provider names seen on live hosts, in the C and the UTF-8 collation.
mit_sorts_last() {
  local loc first
  for loc in C C.UTF-8 en_US.UTF-8; do
    first=$(printf '%s\n' zz-setup-mitigations.cfg hetzner.cfg init-select.cfg 50-cloudimg-settings.cfg 99-setup-mitigations.cfg \
            | LC_ALL=$loc sort 2>/dev/null | tail -n 1)
    [[ $first == zz-setup-mitigations.cfg ]] || return 1
  done
}
check "the mitigations drop-in sorts after hetzner.cfg, init-select.cfg and 50-cloudimg-settings.cfg" mit_sorts_last
check "the drop-in path is zz-setup-mitigations.cfg" test "${CPU_MITIGATIONS_DROPIN##*/}" = zz-setup-mitigations.cfg
mo=$TMP/mit-over/grub.d; mkdir -p "$mo"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0"\n' > "$mo/hetzner.cfg"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} quiet"\n' > "$mo/zzz-extends.cfg"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="nosplash"\n' > "$mo/zzzz-assigns.cfg"
check "overrider scan: only plain assignments sorted after ours are listed" \
  test "$(CPU_MITIGATIONS_DROPIN=$mo/zz-setup-mitigations.cfg cpu_mitigations_overriders)" = "$mo/zzzz-assigns.cfg"
check "CPU_MITIGATIONS and XF_MEMBER_GZIP survive the --optimize pin reset" \
  bash -c 'printf "%s\n" "${@}" | grep -qx CPU_MITIGATIONS && printf "%s\n" "${@}" | grep -qx XF_MEMBER_GZIP' _ "${RESET_KEEP_PINS[@]}"
check "--purge basic removes the mitigations drop-in" \
  bash -c 'sed -n "/^purge_basic()/,/^}/p" "$1" | grep -qF "CPU_MITIGATIONS_DROPIN"' _ "$ROOT/lib/purge.sh"
check "--basic and --optimize both apply the mitigations choice" \
  bash -c 'sed -n "/^install_basic()/,/^}/p" "$1" | grep -q configure_cpu_mitigations && sed -n "/^run_os_tuning()/,/^}/p" "$2" | grep -q configure_cpu_mitigations' \
  _ "$ROOT/lib/os.sh" "$ROOT/lib/restart.sh"

# ---------------------------------------------------------------------------
# XenForo gzip handover (src/config.php managed block)
# ---------------------------------------------------------------------------
if command -v php >/dev/null 2>&1; then
  xfg=$TMP/xfgzip/src; mkdir -p "$xfg"; : > "$xfg/XF.php"
  printf '%s\n' '<?php' "\$config['db']['host'] = 'localhost';" "\$config['enableGzip'] = true;" > "$xfg/config.php"
  cp "$xfg/config.php" "$TMP/xfgzip/orig.php"
  xfg_run() { # mode -> md5 of config.php
    (
      XF_MEMBER_GZIP=$1 XF_MEMBER_GZIP_PERSIST=0
      app_find_xenforo_configs() { printf '%s\n' "$xfg/config.php"; }
      harden_note() { :; }
      harden_warn() { printf 'WARN %s\n' "$*" >&2; }
      tune_xenforo_gzip
    ) 2>/dev/null
    md5sum < "$xfg/config.php" | cut -d' ' -f1
  }
  first=$(xfg_run angie)
  check "XenForo gzip: the managed block is appended and the operator's line commented out" \
    bash -c 'tail -n1 "$1" | grep -qF "// END setup.sh enableGzip" && grep -qF "$2" "$1" && grep -qxF "$3" "$1"' \
    _ "$xfg/config.php" "\$config['enableGzip'] = !isset(\$_COOKIE[" "${XF_GZIP_SUPERSEDED}\$config['enableGzip'] = true;"
  check "XenForo gzip: the result parses" php -l "$xfg/config.php"
  check "XenForo gzip: a second run changes nothing" test "$(xfg_run angie)" = "$first"
  check "XenForo gzip: a guest renders with XenForo gzip on" \
    test "$(php -r '$config=[]; include $argv[1]; echo $config["enableGzip"] ? 1 : 0;' "$xfg/config.php")" = 1
  check "XenForo gzip: a session cookie turns XenForo gzip off" \
    test "$(php -r '$_COOKIE=["xf_session"=>"x"]; $config=[]; include $argv[1]; echo $config["enableGzip"] ? 1 : 0;' "$xfg/config.php")" = 0
  check "XenForo gzip: a custom cookie prefix is honoured" \
    test "$(php -r '$_COOKIE=["forum_session"=>"x"]; $config=["cookie"=>["prefix"=>"forum_"]]; include $argv[1]; echo $config["enableGzip"] ? 1 : 0;' "$xfg/config.php")" = 0
  xfg_run xenforo >/dev/null
  check "XenForo gzip: XF_MEMBER_GZIP=xenforo restores the file byte for byte" \
    cmp -s "$xfg/config.php" "$TMP/xfgzip/orig.php"
  # Older installs: `$config['enableGzip'] = false;` (often with a comment,
  # sometimes indented).  A line holding a second statement is left alone.
  printf '%s\n' '<?php' "\$config['enableGzip'] = false; // off for the CDN" \
    "  \$config [ \"enableGzip\" ]=0;" "\$config['debug'] = false; \$config['enableGzip'] = false;" > "$xfg/config.php"
  cp "$xfg/config.php" "$TMP/xfgzip/old.php"
  xfg_run angie >/dev/null
  check "XenForo gzip: an old enableGzip = false line is commented out" \
    grep -qxF "${XF_GZIP_SUPERSEDED}\$config['enableGzip'] = false; // off for the CDN" "$xfg/config.php"
  check "XenForo gzip: an indented, double-quoted line is commented out too" \
    grep -qxF "${XF_GZIP_SUPERSEDED}  \$config [ \"enableGzip\" ]=0;" "$xfg/config.php"
  check "XenForo gzip: a line with a second statement is left as it is" \
    grep -qxF "\$config['debug'] = false; \$config['enableGzip'] = false;" "$xfg/config.php"
  check "XenForo gzip: with the old lines commented out a guest still gets gzip" \
    test "$(php -r '$config=[]; include $argv[1]; echo $config["enableGzip"] ? 1 : 0;' "$xfg/config.php")" = 1
  old_sum=$(xfg_run angie)
  check "XenForo gzip: commenting out is idempotent" test "$(xfg_run angie)" = "$old_sum"
  xfg_run xenforo >/dev/null
  check "XenForo gzip: XF_MEMBER_GZIP=xenforo un-comments the old lines byte for byte" \
    cmp -s "$xfg/config.php" "$TMP/xfgzip/old.php"
  printf '%s\n' '<?php' "\$config['db']['host'] = 'localhost';" '?>' '' > "$xfg/config.php"
  xfg_run angie >/dev/null
  check "XenForo gzip: a closing ?> is removed so the block stays PHP" \
    bash -c '! grep -q "^?>" "$1" && php -l "$1" >/dev/null' _ "$xfg/config.php"
  printf '%s\n' '<?php' '$config = [' > "$xfg/config.php"
  cp "$xfg/config.php" "$TMP/xfgzip/broken.php"
  xfg_run angie >/dev/null
  check "XenForo gzip: a config.php that would not parse is left untouched" \
    cmp -s "$xfg/config.php" "$TMP/xfgzip/broken.php"
fi


# ---------------------------------------------------------------------------
# Lean deny chain: vhost migration (server-configs-nginx 1.6.48)
# ---------------------------------------------------------------------------
lv=$TMP/leanvhost; mkdir -p "$lv/conf.d" "$lv/h5bp/location"
: > "$lv/h5bp/location/security_xf.conf"; : > "$lv/h5bp/basic_headers.conf"
cat > "$lv/conf.d/xf.conf" <<'EOF'
server {
    listen 443 ssl;
    server_name xf.test;
    include h5bp/xf2.conf;

    location ~ ^/(?:admin\.php$|install(?:/|$)) {
        #auth_basic "Private";
        #auth_basic_user_file htpasswd/xfadmin;
        include              h5bp/location/security_root_archives.conf;
        include              h5bp/location/security_leftover_files.conf;
        include              h5bp/php.conf;
    }

    include h5bp/php_xf.conf;
    include h5bp/basic_xf.conf;
}
EOF
cat > "$lv/conf.d/xfauth.conf" <<'EOF'
server {
    server_name xfauth.test;
    location ~ ^/(?:admin\.php$|install(?:/|$)) {
        auth_basic "Private";
        auth_basic_user_file htpasswd/xfadmin;
        include              h5bp/php.conf;
    }
    include h5bp/php_xf.conf;
    include h5bp/basic_xf.conf;
}
EOF
cat > "$lv/conf.d/nested.conf" <<'EOF'
server {
    server_name nested.test;
    location /forum/ {
        include h5bp/php.conf;
    }
    include h5bp/basic_xf.conf;
}
EOF
cat > "$lv/conf.d/chev.conf" <<'EOF'
server {
    server_name chev.test;
    # app/ and importing/ are "Require all denied" upstream (.htaccess).
    location ~ /(?:app|importing)/ { internal; }
    location ~* /(app|content|lib)/.*\.(po|php|lock|sql)$  { internal; }
    location ~* /(?:composer\.(?:json|lock)|\.gitignore)$ { internal; }

    location ^~ /images/ {
        # Nested deny: ^~ skips the server-level regex locations, so a file
        # such as /images/.env or /images/x.sql would otherwise be served.
        location ~* /\.(?!well-known/) { deny all; }
        location ~* \.(?:env|bak|old|orig|sql|sql\.gz|log|ini|conf|sh|php|phtml|phar)$ { deny all; }
        location ~* \.(gif|jpg|jpe|jpeg|png|ico|webp|avif|avifs|jxl|heic|heif|apng|bmp|svg|mov|mp4|webm|mkv|m4v|avi|mp3|ogg|oga|opus|m4a|wav)$ {
        break;
        }
    return 403;
    }
    location ~ ^/(?:dashboard|update)(?:/|$) {
        try_files $uri $uri/ /index.php$is_args$query_string;
        include h5bp/location/security_leftover_files.conf;
        #auth_basic "Private";
        include h5bp/php_chev.conf;
    }
    location /app/CHEVERETO_LICENSE_KEY {
      internal;
    }
    include h5bp/php_chev_cache.conf;
    include h5bp/basic.conf;
}
EOF
sed -e 's/chev.test/chevedit.test/' -e 's|location ~\* /\\.(?!well-known/) { deny all; }|location ~* /\\.(?!well-known/) { return 404; }|' "$lv/conf.d/chev.conf" > "$lv/conf.d/chevedit.conf"
TUNE_MISSES=()
tune_vhost_lean_locations "$lv" >/dev/null 2>&1
check "lean chain: a template XenForo vhost switches to basic_xf_headers.conf" \
  grep -qx '    include h5bp/basic_xf_headers.conf;' "$lv/conf.d/xf.conf"
check "lean chain: the template admin.php|install block is folded" \
  bash -c '! grep -q "admin\\\\.php" "$1"' _ "$lv/conf.d/xf.conf"
check "lean chain: an active auth_basic admin block is kept" \
  grep -q 'auth_basic "Private";' "$lv/conf.d/xfauth.conf"
check "lean chain: a vhost without a server-level app PHP include keeps basic_xf.conf" \
  grep -qx '    include h5bp/basic_xf.conf;' "$lv/conf.d/nested.conf"
check "lean chain: the kept vhost is reported" \
  bash -c 'printf "%s\n" "$@" | grep -q "nested.conf: deny rules kept server-wide"' _ "${TUNE_MISSES[@]}"
check "lean chain: Chevereto switches to basic_headers.conf and folds its template rules" \
  bash -c 'grep -qx "    include h5bp/basic_headers.conf;" "$1" && ! grep -qE "app\|importing|CHEVERETO_LICENSE_KEY|dashboard\|update" "$1"' _ "$lv/conf.d/chev.conf"
check "lean chain: Chevereto /images/ becomes one allowlist that refuses dot paths" \
  bash -c 'grep -qF "location ~* \"(?s)^(?!.*/\\.).*\\.(?:gif|" "$1" && ! grep -q "deny all; }" "$1"' _ "$lv/conf.d/chev.conf"
check "lean chain: an edited /images/ block keeps its nested denies" \
  bash -c 'grep -qF "{ return 404; }" "$1" && grep -qF "|sh|php|phtml|phar)\$ { deny all; }" "$1"' _ "$lv/conf.d/chevedit.conf"
lv_md5=$(cat "$lv"/conf.d/*.conf | md5sum)
tune_vhost_lean_locations "$lv" >/dev/null 2>&1
check "lean chain: a second run changes nothing" test "$(cat "$lv"/conf.d/*.conf | md5sum)" = "$lv_md5"


# Review findings: one-line blocks, the /images/ scope, non-app vhosts.
cat > "$lv/conf.d/oneline.conf" <<'EOF'
server {
    server_name oneline.test;
    location ~ ^/(?:admin\.php$|install(?:/|$)) { auth_basic "Private"; auth_basic_user_file htpasswd/xfadmin; include h5bp/php.conf; }
    client_max_body_size 20m;
    include h5bp/php_xf.conf;
    include h5bp/basic_xf.conf;
}
EOF
cat > "$lv/conf.d/chevone.conf" <<'EOF'
server {
    server_name chevone.test;
    location /app/CHEVERETO_LICENSE_KEY { internal; }
    include h5bp/php_chev_cache.conf;
    location ^~ /content/ {
        location ~* /\.(?!well-known/) { deny all; }
        location ~* \.(?:env|bak|old|orig|sql|sql\.gz|log|ini|conf|sh|php|phtml|phar)$ { deny all; }
    }
    location ^~ /images/ {
        location ~* /\.(?!well-known/) { deny all; }
        location ~* \.(?:env|bak|old|orig|sql|sql\.gz|log|ini|conf|sh|php|phtml|phar)$ { deny all; }
        location ~* \.(gif|jpg|jpe|jpeg|png|ico|webp|avif|avifs|jxl|heic|heif|apng|bmp|svg|mov|mp4|webm|mkv|m4v|avi|mp3|ogg|oga|opus|m4a|wav)$ {
        break;
        }
        location ~* \.pdf$ { break; }
    return 403;
    }
    include h5bp/basic.conf;
}
EOF
cat > "$lv/conf.d/plain.conf" <<'EOF'
server {
    server_name plain.test;
    location / { proxy_pass http://127.0.0.1:3000; }
    include h5bp/basic.conf;
}
EOF
TUNE_MISSES=()
tune_vhost_lean_locations "$lv" >/dev/null 2>&1
check "lean chain: a one-line admin block with auth_basic is kept" \
  grep -qF 'auth_basic "Private"; auth_basic_user_file' "$lv/conf.d/oneline.conf"
check "lean chain: the line after a one-line block is never dropped" \
  bash -c 'grep -qx "    client_max_body_size 20m;" "$1" && grep -qx "    include h5bp/php_chev_cache.conf;" "$2"' _ "$lv/conf.d/oneline.conf" "$lv/conf.d/chevone.conf"
check "lean chain: a one-line CHEVERETO_LICENSE_KEY block is folded" \
  bash -c '! grep -q CHEVERETO_LICENSE_KEY "$1"' _ "$lv/conf.d/chevone.conf"
check "lean chain: nested denies outside ^~ /images/ are never touched" \
  test "$(sed -n '/location ^~ \/content\//,/^    }/p' "$lv/conf.d/chevone.conf" | grep -c 'deny all; }')" = 2
check "lean chain: an /images/ block with an extra nested location is not folded" \
  test "$(sed -n '/location ^~ \/images\//,/^    }/p' "$lv/conf.d/chevone.conf" | grep -c 'deny all; }')" = 2
check "lean chain: a vhost without an application PHP include is not reported" \
  bash -c '! printf "%s\n" "$@" | grep -q "plain.conf"' _ "${TUNE_MISSES[@]}"
check "lean chain: a plain vhost keeps basic.conf" grep -qx '    include h5bp/basic.conf;' "$lv/conf.d/plain.conf"
check "a nested php_wp.conf is rewritten before the tree test (exact locations cannot nest)" \
  bash -c 'sed -n "/^angie_migrate_guest_cache_includes()/,/^}/p" "$1" | grep -qF "angie_rewrite_include_at_level \"\$vhost\" php_wp.conf php.conf nested"' _ "$ROOT/lib/optimize.sh"
if command -v php >/dev/null 2>&1; then
  printf '%s\n' '<?php' "\$config['cookie']['prefix'] = 'forum_'; ?>" > "$xfg/config.php"
  xfg_run angie >/dev/null
  check "XenForo gzip: a ?> after code on the last line is removed (no text output)" \
    bash -c '! grep -q "?>" "$1" && [[ -z $(php -r "ob_start(); \$config=[]; include \$argv[1]; echo ob_get_clean();" "$1") ]]' _ "$xfg/config.php"
  printf '%s\n' '<?php' '// BEGIN setup.sh enableGzip (edited)' "\$config['db']['host'] = 'x';" > "$xfg/config.php"
  cp "$xfg/config.php" "$TMP/xfgzip/nobegin.php"
  xfg_run angie >/dev/null
  check "XenForo gzip: a block without its END marker is left untouched" \
    cmp -s "$xfg/config.php" "$TMP/xfgzip/nobegin.php"
fi

# --- One /var/www walk per --optimize run (app_config_scan) ---
# Each WordPress/XenForo finder used to walk /var/www to depth 6 itself; a
# 3.7M-entry forum tree paid 4-5 s per walk, about eight times per run.
# Earlier sections stub the finders, so the real ones run in a subshell.
aw="$TMP/appscan"
mkdir -p "$aw/www/wp.test/public" "$aw/www/xf.test/public/src" "$aw/www/nox.test/src"
: > "$aw/www/wp.test/public/wp-config.php"
: > "$aw/www/xf.test/public/src/config.php"
: > "$aw/www/xf.test/public/src/XF.php"
: > "$aw/www/nox.test/src/config.php"
appscan_run() {
  (
    eval "$(sed -n '/^app_config_scan_walk()/,/^}/p;/^app_config_scan_prime()/,/^}/p;/^app_config_scan_reset()/,/^}/p;/^app_config_scan()/,/^}/p;/^app_find_wordpress_configs()/,/^}/p;/^app_find_xenforo_configs()/,/^}/p' "$ROOT/lib/optimize.sh")"
    eval "$(declare -f app_config_scan_walk | sed '1s/app_config_scan_walk/appscan_real_walk/')"
    app_config_scan_walk() { printf 'x\n' >> "$aw/walks"; appscan_real_walk; }
    SETUP_WWW_ROOT="$aw/www"; APP_CONFIG_SCAN_PRIMED=0; APP_CONFIG_SCAN_LIST=""
    rm -f "$aw/walks"
    "$@"
  )
}
appscan_primed() {
  app_config_scan_prime
  app_find_wordpress_configs; app_find_xenforo_configs
  mapfile -t _ < <(app_find_wordpress_configs)
  while IFS= read -r _; do :; done < <(app_find_xenforo_configs)
  printf 'walks=%s\n' "$(wc -l < "$aw/walks")"
}
appscan_unprimed() {
  app_find_wordpress_configs >/dev/null; app_find_xenforo_configs >/dev/null
  printf 'walks=%s\n' "$(wc -l < "$aw/walks")"
}
appscan_reset() {
  app_config_scan_prime
  mkdir -p "$aw/www/wp2.test"; : > "$aw/www/wp2.test/wp-config.php"
  printf 'before=%s\n' "$(app_find_wordpress_configs | wc -l)"
  app_config_scan_reset
  printf 'after=%s\n' "$(app_find_wordpress_configs | wc -l)"
  rm -rf "$aw/www/wp2.test"
}
appscan_empty() {
  SETUP_WWW_ROOT="$aw/none"; app_config_scan_prime
  printf 'wp=[%s] xf=[%s] walks=%s\n' "$(app_find_wordpress_configs)" "$(app_find_xenforo_configs)" "$(wc -l < "$aw/walks")"
}
out=$(appscan_run appscan_primed)
check "app scan: a primed run walks /var/www once for every finder call" grep -qx 'walks=1' <<<"$out"
check "app scan: the WordPress finder returns only wp-config.php" \
  grep -qx "$aw/www/wp.test/public/wp-config.php" <<<"$out"
check "app scan: the XenForo finder returns a src/config.php with XF.php beside it" \
  grep -qx "$aw/www/xf.test/public/src/config.php" <<<"$out"
check "app scan: a src/config.php without XF.php is not XenForo" \
  bash -c '! grep -q nox.test <<<"$1"' _ "$out"
check "app scan: the WordPress list holds no XenForo config (and back)" \
  test "$(grep -c '/' <<<"$out")" = 2
out=$(appscan_run appscan_unprimed)
check "app scan: unprimed (install path) still walks live on every call" grep -qx 'walks=2' <<<"$out"
out=$(appscan_run appscan_reset)
check "app scan: reset drops the primed list so a new site is found" \
  bash -c 'grep -qx before=1 <<<"$1" && grep -qx after=2 <<<"$1"' _ "$out"
out=$(appscan_run appscan_empty)
check "app scan: a missing web root primes an empty list (no blank entries)" \
  grep -qx 'wp=\[\] xf=\[\] walks=1' <<<"$out"
check "app scan: --optimize primes the scan right after service detection" \
  bash -c 'grep -A3 "^  detect_installed_services$" "$1" | grep -q app_config_scan_prime' _ "$ROOT/lib/restart.sh"
# The dry run makes no depth-6 finder call (measured: 0 walks), so a prime
# there would add a walk; the install path adds sites while it runs.
check "app scan: neither the dry run nor the install path primes it" \
  bash -c '! grep -q app_config_scan_prime "$@"' _ "$ROOT/lib/service-optimizers.sh" "$ROOT/lib/services.sh" "$ROOT/lib/web.sh" "$ROOT/lib/runner.sh" "$ROOT/setup.sh"


# --- Cloudflare-proxied vhosts: self-signed origin instead of certbot ---
not() { ! "$@"; }
check "ipv4_in_cidr: inside a /20" ipv4_in_cidr 173.245.63.1 173.245.48.0/20
check "ipv4_in_cidr: just outside a /20" not ipv4_in_cidr 173.245.64.1 173.245.48.0/20
check "ipv4_in_cidr: malformed address is not inside" not ipv4_in_cidr 1.2.3 1.2.0.0/16
check "ipv4_in_cidr: leading zeros are decimal, not octal" ipv4_in_cidr 104.016.0.9 104.16.0.0/13
check "ipv6_expand: :: in the middle" \
  test "$(ipv6_expand 2606:4700::6810:84e5)" = 260647000000000000000000681084e5
check "ipv6_expand: full form" \
  test "$(ipv6_expand 2001:db8:2a:27e1:0:0:0:2)" = 20010db8002a27e10000000000000002
check "ipv6_expand: uppercase is accepted" \
  test "$(ipv6_expand 2606:4700::ABCD)" = 2606470000000000000000000000abcd
check "ipv6_expand: rejects two ::" not ipv6_expand 1::2::3
check "ipv6_expand: rejects a group over four digits" not ipv6_expand 2606:47000::1
check "ipv6_expand: rejects a zone id" not ipv6_expand fe80::1%eth0
check "ipv6_in_cidr: inside a /32" ipv6_in_cidr 2606:4700:3030::ac43:85bb 2606:4700::/32
check "ipv6_in_cidr: /29 bit boundary inside" ipv6_in_cidr 2a06:98c7::1 2a06:98c0::/29
check "ipv6_in_cidr: /29 bit boundary outside" not ipv6_in_cidr 2a06:98c8::1 2a06:98c0::/29
check "ipv6_in_cidr: other provider is outside" not ipv6_in_cidr 2001:db8:2a:27e1::2 2606:4700::/32

cft="$TMP/cftls"
mkdir -p "$cft/angie/conf.d" "$cft/angie/http.d" "$cft/angie/ssl/default" "$cft/le/renewal" \
  "$cft/le/renewal-hooks/deploy" "$cft/etc/postfix" "$cft/www/app"
printf 'cert\n' > "$cft/angie/ssl/default/fullchain.pem"
printf 'key\n'  > "$cft/angie/ssl/default/privkey.pem"
cat > "$cft/angie/http.d/cloudflare.conf" <<'EOF'
# Generated by scripts/cloudflare.sh - do not edit by hand.
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 2606:4700::/32;
real_ip_header CF-Connecting-IP;
EOF
# A certbot block behind Cloudflare, a direct one and a port-80 block.
cat > "$cft/site.conf.in" <<'EOF'
server {
    listen 443 ssl;
    server_name cf.test
                www.cf.test;
    include h5bp/tls/ssl_engine.conf;
    ssl_certificate /etc/letsencrypt/live/cf.test/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/cf.test/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
    ssl_trusted_certificate /etc/letsencrypt/live/cf.test/chain.pem; proxy_ssl_trusted_certificate /etc/letsencrypt/live/up/chain.pem;
    location /api { proxy_pass https://up; proxy_ssl_certificate /etc/letsencrypt/live/cf.test/fullchain.pem; }
}
server {
    listen 443 ssl;
    server_name direct.test;
    ssl_certificate     /etc/letsencrypt/live/direct.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/direct.test/privkey.pem;
}
server {
    listen 80;
    server_name cf.test www.cf.test;
    return 301 https://$host$request_uri;
}
EOF
cp "$cft/site.conf.in" "$cft/angie/conf.d/site.conf"
cat > "$cft/cfonly.orig" <<'EOF'
server {
    listen 443 ssl;
    server_name only.test;
    ssl_certificate /etc/letsencrypt/live/only.test/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/only.test/privkey.pem;
}
EOF
cp "$cft/cfonly.orig" "$cft/angie/conf.d/cfonly.conf"
# Blocks that must never move although one exact name is behind Cloudflare.
cat > "$cft/never.conf.in" <<'EOF'
server {
    listen 443 ssl;
    server_name only.test *.only.test;
    ssl_certificate     /etc/letsencrypt/live/only.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/only.test/privkey.pem;
}
server {
    listen 443 ssl;
    server_name only.test ~^(?<sub>.+)\.grey\.test$;
    ssl_certificate     /etc/letsencrypt/live/only.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/only.test/privkey.pem;
}
server {
    listen 443 ssl;
    server_name .only.test;
    ssl_certificate     /etc/letsencrypt/live/only.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/only.test/privkey.pem;
}
server {
    listen 443 ssl;
    server_name only.test;
    ssl_certificate     /etc/letsencrypt/live/only.test/fullchain.pem;
    include snippets/ssl-key.conf;
}
server {
    listen 443 ssl;
    server_name only.test;
    ssl_certificate     /etc/letsencrypt/live/only.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/only.test/privkey.pem;
    ssl_certificate     /etc/angie/ssl/rsa/fullchain.pem;
    ssl_certificate_key /etc/angie/ssl/rsa/privkey.pem;
}
EOF
cp "$cft/never.conf.in" "$cft/angie/conf.d/never.conf"
out=$(cf_tls_server_blocks "$cft/angie/conf.d/site.conf")
check "server blocks: three top-level blocks, eligibility and names" \
  test "$out" = "$(printf '1\t1\tcf.test www.cf.test\n2\t1\tdirect.test\n3\t0\tcf.test www.cf.test')"
out=$(cf_tls_server_blocks "$cft/angie/conf.d/never.conf" | cut -f2 | tr -d '\n')
check "server blocks: a cert without its key here, or a second pair, is not eligible" \
  test "$out" = 11100
printf 'server { listen 443 ssl; ssl_certificate /etc/letsencrypt/live/a/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/a/privkey.pem;\n    server_name only.test;\n}\nserver {\n    location ~ x { } # setup-cf-tls probe\n    server_name only.test;\n    ssl_certificate /etc/letsencrypt/live/a/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/a/privkey.pem;\n}\n' > "$TMP/cf-open.conf"
out=$(cf_tls_server_blocks "$TMP/cf-open.conf" | cut -f2 | tr -d '\n')
check "server blocks: directives on the server { line, or an existing probe, make it ineligible" \
  test "$out" = 00

cf_tls_resolve() {
  case $1 in
    cf.test)       printf '104.21.5.113\n2606:4700:3030::6815:571\n' ;;
    www.cf.test)   printf '172.67.133.91\n' ;;
    only.test)     printf '104.21.37.14\n' ;;
    direct.test)   printf '203.0.113.24\n' ;;
    *) : ;;
  esac
}
# The real probe against a stubbed curl: only the origin's echo of this
# request's own nonce is proof.
probe_real() (
  sleep() { :; }
  curl() {
    local url=${*: -1} nonce
    nonce=${url##*-}
    case $CURL_MODE in
      echo)      printf 'HTTP/2 204\r\ncf-ray: 1-MNL\r\nx-setup-cf-probe: %s\r\n\r\n' "$nonce" ;;
      stale)     printf 'HTTP/2 204\r\ncf-ray: 1-MNL\r\nx-setup-cf-probe: 12345\r\n\r\n' ;;
      challenge) printf 'HTTP/2 403\r\ncf-ray: 1-MNL\r\ncf-mitigated: challenge\r\n\r\n' ;;
      strict)    printf 'HTTP/2 526\r\ncf-ray: 1-MNL\r\n\r\n' ;;
      down)      return 7 ;;
    esac
  }
  CURL_MODE=$1 cf_tls_probe cf.test
)
check "probe: the origin echo of this nonce is proof" probe_real echo
check "probe: an echo of another nonce (old worker, cache) is not" not probe_real stale
check "probe: a Cloudflare challenge with cf-ray is not" not probe_real challenge
check "probe: a 526 is not" not probe_real strict
check "probe: no answer is not" not probe_real down
check "probe: the last status is printed for the report" test "$(probe_real strict || true)" = 526
cf_tls_probe() {
  printf '%s' "${CF_TEST_CODE:-200}"
  [[ ${CF_TEST_CODE:-200} != 52? && ${CF_TEST_CODE:-200} != 000 ]]
}
check "behind Cloudflare: v4 and v6 addresses all in ranges" \
  cf_tls_name_behind_cloudflare cf.test "$cft/angie/http.d/cloudflare.conf"
check "behind Cloudflare: a direct address is not" \
  not cf_tls_name_behind_cloudflare direct.test "$cft/angie/http.d/cloudflare.conf"
check "behind Cloudflare: a name that does not resolve is not" \
  not cf_tls_name_behind_cloudflare nxdomain.test "$cft/angie/http.d/cloudflare.conf"

out=$(cloudflare_tls_migrate "$cft/angie" 1)
check "dry run: lists both migratable files" \
  bash -c 'grep -q "would point conf.d/site.conf (cf.test www.cf.test)" <<<"$1" && grep -q "would point conf.d/cfonly.conf (only.test)" <<<"$1"' _ "$out"
check "dry run: changes nothing" cmp -s "$cft/angie/conf.d/site.conf" "$cft/site.conf.in"
check "dry run: never lists the direct site or a wildcard/regex/.suffix block" \
  not grep -qE 'direct.test|never.conf' <<<"$out"

OPT_REPORT=()
cloudflare_tls_migrate "$cft/angie" 0
check "migrate: records the two eligible files" test "${#CF_TLS_FILES[@]}" = 2
check "migrate: Cloudflare block uses the self-signed pair" \
  bash -c 'grep -qx "    ssl_certificate /etc/angie/ssl/default/fullchain.pem;" "$1" && grep -qx "    ssl_certificate_key /etc/angie/ssl/default/privkey.pem;" "$1"' _ "$cft/angie/conf.d/site.conf"
check "migrate: certbot options include and dhparam are dropped" \
  not grep -qE 'options-ssl-nginx|ssl-dhparams|managed by Certbot' "$cft/angie/conf.d/site.conf"
check "migrate: proxy_ssl_certificate is not an ssl_certificate" \
  grep -qF 'proxy_ssl_certificate /etc/letsencrypt/live/cf.test/fullchain.pem;' "$cft/angie/conf.d/site.conf"
check "migrate: proxy_ssl_trusted_certificate on the same line as a removed directive survives" \
  grep -qxF '     proxy_ssl_trusted_certificate /etc/letsencrypt/live/up/chain.pem;' "$cft/angie/conf.d/site.conf"
check "migrate: the probe location is the first line of each migrated block only" \
  bash -c 'awk "/^server \\{/{getline n; print n}" "$1" | grep -c "setup-cf-tls probe" | grep -qx 1 && [[ $(grep -c "setup-cf-tls probe" "$1") == 1 ]] && [[ $(sed -n 2p "$1") == "    $2" ]]' _ "$cft/angie/conf.d/site.conf" "$CF_TLS_PROBE_LOCATION"
check "migrate: the probe echoes digits only, from a named capture" \
  bash -c '[[ $1 == *"(?<setup_cf_probe>[0-9]{1,40})"* && $1 == *"add_header X-Setup-CF-Probe \$setup_cf_probe always; return 204;"* ]]' _ "$CF_TLS_PROBE_LOCATION"
check "migrate: the direct block keeps its certbot certificate" \
  bash -c 'grep -q "/etc/letsencrypt/live/direct.test/fullchain.pem" "$1" && grep -q "/etc/letsencrypt/live/direct.test/privkey.pem" "$1"' _ "$cft/angie/conf.d/site.conf"
check "migrate: the TLS policy include and other lines are kept byte for byte" \
  bash -c 'diff <(grep -vE "ssl_certificate|letsencrypt|setup-cf-tls probe" "$1") <(grep -vE "ssl_certificate|letsencrypt" "$2") >/dev/null' _ "$cft/angie/conf.d/site.conf" "$cft/site.conf.in"
check "migrate: a one-line cert + key pair is rewritten together" \
  grep -qxF '    ssl_certificate /etc/angie/ssl/default/fullchain.pem; ssl_certificate_key /etc/angie/ssl/default/privkey.pem;' "$cft/angie/conf.d/cfonly.conf"
check "migrate: wildcard, regex, .suffix and half-pair blocks are never touched" \
  cmp -s "$cft/angie/conf.d/never.conf" "$cft/never.conf.in"

# Through-Cloudflare proof: anything but a clean answer puts the file back
# with the keep marker, and later runs skip it.
ANGIE_BIN=true
systemctl() { :; }
dpkg-query() { return 1; }
CF_TEST_CODE=526
OPT_REPORT=()
cloudflare_tls_finish 0
check "finish: a 526 restores the vhost byte for byte below the keep marker" \
  bash -c 'head -n1 "$1" | grep -q "^# setup-cf-tls: keep" && cmp -s <(tail -n +2 "$1") "$2"' _ "$cft/angie/conf.d/cfonly.conf" "$cft/cfonly.orig"
check "finish: the report names Full (strict)" \
  bash -c 'printf "%s\n" "$@" | grep -q "Full (strict)"' _ "${OPT_REPORT[@]}"
CF_TEST_CODE=200
cp "$cft/site.conf.in" "$cft/angie/conf.d/site.conf"
OPT_REPORT=()
cloudflare_tls_migrate "$cft/angie" 0
check "migrate: a file with the keep marker is skipped on later runs" \
  bash -c 'head -n1 "$1" | grep -q "^# setup-cf-tls: keep" && [[ ${#@} -ge 2 ]] && printf "%s\n" "${@:2}" | grep -q "keep marker"' _ "$cft/angie/conf.d/cfonly.conf" "${OPT_REPORT[@]}"
CF_TEST_CODE=000
OPT_REPORT=()
cloudflare_tls_finish 0
check "finish: no answer through Cloudflare (000) also puts the file back" \
  bash -c 'head -n1 "$1" | grep -q "^# setup-cf-tls: keep"' _ "$cft/angie/conf.d/site.conf"
CF_TEST_CODE=200
cp "$cft/site.conf.in" "$cft/angie/conf.d/site.conf"
cp "$cft/cfonly.orig" "$cft/angie/conf.d/cfonly.conf"

# With Anubis in place the whole step is skipped; its generated
# terminators are never migrated on their own either.
anubis_managed() { return 0; }
out=$(cloudflare_tls_migrate "$cft/angie" 1)
check "Anubis managed: the migration is skipped" \
  bash -c 'grep -q "skipped (the Anubis integration" <<<"$1" && ! grep -q "would point" <<<"$1"' _ "$out"
unset -f anubis_managed
anubis_managed() { return 1; }
cp "$cft/cfonly.orig" "$cft/angie/conf.d/00-anubis-terminators.conf"
out=$(cloudflare_tls_migrate "$cft/angie" 1)
check "00-anubis-* files are never migrated" not grep -q '00-anubis' <<<"$out"
rm -f "$cft/angie/conf.d/00-anubis-terminators.conf"
unset -f anubis_managed

# CF_SELF_SIGNED=0 leaves every file alone.
CF_SELF_SIGNED=0 cloudflare_tls_migrate "$cft/angie" 0
check "CF_SELF_SIGNED=0: no vhost is rewritten" cmp -s "$cft/angie/conf.d/cfonly.conf" "$cft/cfonly.orig"
# No Cloudflare ranges file: skipped with a note.
mv "$cft/angie/http.d/cloudflare.conf" "$cft/cf.ranges"
out=$(cloudflare_tls_migrate "$cft/angie" 1)
check "no ranges file: skipped with the refresh hint" grep -q 'no Cloudflare ranges' <<<"$out"
mv "$cft/cf.ranges" "$cft/angie/http.d/cloudflare.conf"

# certbot retirement.  Only fixture roots are scanned.
cf_tls_docker() { :; }   # never the host's Docker daemon
apt_calls="$cft/apt.calls"
apt-get() { printf '%s\n' "$*" >> "$apt_calls"; }
dpkg-query() {
  [[ $* == *python3-certbot-nginx* ]] && return 1
  printf 'certbot install ok installed\npython3-certbot install ok installed\npython3-certbot-dns-x deinstall ok config-files\n'
}
printf 'authenticator = nginx\n' > "$cft/le/renewal/direct.test.conf"
CERTBOT_DIR="$cft/le"; CERTBOT_ETC="$cft/etc"; CERTBOT_EXTRA_ROOTS=""; CERTBOT_WWW="$cft/www"
CERTBOT_BACKUP_ROOT="$cft/backups"; mkdir -p "$CERTBOT_BACKUP_ROOT"
angie_dump() { printf '# configuration file %s:\n' "$cft/angie/conf.d/site.conf"; cat "$cft/angie/conf.d/site.conf"; }
ANGIE_BIN=angie_dump
certbot_users_contains() { local o; o=$(certbot_letsencrypt_users) && grep -qF -- "$1" <<<"$o"; }
OPT_REPORT=(); rm -f "$apt_calls"
certbot_retire_if_unused 0
check "certbot: kept while a loaded vhost still uses it" \
  bash -c '[[ ! -e $1 ]] && printf "%s\n" "${@:2}" | grep -q "certbot: kept; .* is still used by .*site.conf"' _ "$apt_calls" "${OPT_REPORT[@]}"
check "certbot: a renewal on the missing nginx plugin is a warning" \
  bash -c 'printf "%s\n" "$@" | grep -q "direct.test. renews with the nginx plugin"' _ "${OPT_REPORT[@]}"
angie_fail() { return 1; }
ANGIE_BIN=angie_fail
OPT_REPORT=(); rm -f "$apt_calls"
certbot_retire_if_unused 0
check "certbot: kept when angie -T fails (fail closed)" \
  bash -c '[[ ! -e $1 ]] && printf "%s\n" "${@:2}" | grep -q "angie -T failed"' _ "$apt_calls" "${OPT_REPORT[@]}"
angie_dump() { printf '# configuration file /etc/angie/angie.conf:\nhttp {}\n'; }
ANGIE_BIN=angie_dump
printf 'ssl_dh = </etc/letsencrypt/ssl-dhparams.pem\n' > "$cft/etc/postfix/dovecot.conf"
check "certbot users: a dhparam-only reference counts" certbot_users_contains postfix/dovecot.conf
rm -f "$cft/etc/postfix/dovecot.conf"
printf '# was /etc/letsencrypt/live/x/fullchain.pem\n' > "$cft/etc/postfix/old.cf"
check "certbot users: a commented reference does not count" not certbot_users_contains postfix/old.cf
ln -s "$cft/le/live" "$cft/etc/postfix/certs"
check "certbot users: a symlink into the tree counts" certbot_users_contains postfix/certs
rm -f "$cft/etc/postfix/certs"
printf '#!/bin/sh\ncp x y\n' > "$cft/le/renewal-hooks/deploy/haproxy.sh"
check "certbot users: a renewal hook counts" certbot_users_contains renewal-hooks/deploy/haproxy.sh
rm -f "$cft/le/renewal-hooks/deploy/haproxy.sh"
printf 'SSL_CERT=/etc/letsencrypt/live/app/fullchain.pem\n' > "$cft/www/app/.env"
check "certbot users: an application .env under the web root counts" certbot_users_contains www/app/.env
rm -f "$cft/www/app/.env"
mkdir -p "$cft/etc/apparmor.d/abstractions"
printf '  /etc/letsencrypt/archive/*/cert*.pem r,\n' > "$cft/etc/apparmor.d/abstractions/ssl_certs"
check "certbot users: AppArmor read rules are not consumers" not certbot_users_contains apparmor.d
mkdir -p "$cft/etc/node_modules/x"
printf 'key: /etc/letsencrypt/live/a/privkey.pem\n' > "$cft/etc/node_modules/x/c.yml"
check "certbot users: node_modules is skipped" not certbot_users_contains node_modules
rm -rf "$cft/etc/node_modules"
docker() { :; }
cf_tls_docker() {
  case $1 in
    ps) printf 'c1\n' ;;
    inspect) printf '/proxy %s/live /srv/data\n' "$cft/le" ;;
  esac
}
check "certbot users: a container mounting the tree counts" certbot_users_contains docker:/proxy
cf_tls_docker() { return 124; }
systemctl() { [[ $* == "is-active --quiet docker" ]]; }
check "certbot users: a running docker that does not answer keeps certbot" certbot_users_contains docker:unreachable
systemctl() { return 3; }
check "certbot users: docker installed but stopped is not a consumer" not certbot_users_contains docker:
systemctl() { :; }
# The rest never asks the host's own Docker (CI runners have one): no containers.
unset -f docker
cf_tls_docker() { :; }
printf 'services:\n  mail:\n    volumes:\n      - /etc/letsencrypt:/etc/letsencrypt:ro\n' > "$cft/etc/postfix/compose.yml"
check "certbot users: a bind mount of the bare tree counts" certbot_users_contains postfix/compose.yml
printf 'LE_DIR=/etc/letsencrypt\n' > "$cft/etc/postfix/compose.yml"
check "certbot users: a bare LE_DIR=/etc/letsencrypt counts" certbot_users_contains postfix/compose.yml
printf 'old=/etc/letsencrypt-old/x\n' > "$cft/etc/postfix/compose.yml"
check "certbot users: /etc/letsencrypt-old is a different path" not certbot_users_contains postfix/compose.yml
rm -f "$cft/etc/postfix/compose.yml"
mkdir -p "$cft/state/anubis/vhosts"
printf 'ssl_certificate /etc/letsencrypt/live/a/fullchain.pem;\n' > "$cft/state/anubis/vhosts/a.conf.orig"
CERTBOT_EXTRA_ROOTS="$cft/state"
check "certbot users: an Anubis vhost backup in the state tree counts" \
  certbot_users_contains anubis/vhosts/a.conf.orig
CERTBOT_EXTRA_ROOTS=""
check "certbot users: the setup.sh state tree is a default root" \
  grep -qF '"${STATE_DIR:-/var/lib/setup.sh}")' "$ROOT/lib/web.sh"
# fleet-update.sh keeps the checkout (and a dated previous one) and its run
# logs in /root: lib/web.sh, the changelog and the report lines all quote
# /etc/letsencrypt, and counting them kept certbot on every fleet host.
mkdir -p "$cft/home/ubuntu-setup-script/lib" "$cft/home/ubuntu-setup-script.20261120-1200/lib"
for d in "$cft/home/ubuntu-setup-script" "$cft/home/ubuntu-setup-script.20261120-1200"; do
  printf '#!/bin/bash\n' > "$d/setup.sh"
  printf 'le=/etc/letsencrypt/live\n' > "$d/lib/web.sh"
  printf 'certbot uses /etc/letsencrypt/renewal\n' > "$d/CHANGELOG.md"
done
printf 'certbot: kept; /etc/letsencrypt is still used by x\n' > "$cft/home/setup-optimize-20261120.log"
mkdir -p "$cft/home/server-configs-nginx/conf.d/templates"
printf 'events {}\n' > "$cft/home/server-configs-nginx/angie.conf"
printf 'ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;\n' \
  > "$cft/home/server-configs-nginx/conf.d/templates/sample_php.conf"
CERTBOT_EXTRA_ROOTS="$cft/home"
check "certbot users: project checkouts, Angie template trees and run logs are not consumers" \
  test -z "$(certbot_letsencrypt_users)"
# Only a directory with both setup.sh and lib/web.sh is a project copy.
mkdir -p "$cft/home/app/lib"
printf 'cert=/etc/letsencrypt/live/a/fullchain.pem\n' > "$cft/home/app/lib/web.sh"
check "certbot users: a lib/web.sh outside a project copy still counts" \
  certbot_users_contains app/lib/web.sh
CERTBOT_EXTRA_ROOTS=""
rm -rf "${cft:?}/home"
rm -rf "$cft/state"
out=$(CF_TLS_DRY_FULL=(); certbot_retire_if_unused 1)
check "certbot dry run: would purge and changes nothing" \
  bash -c 'grep -q "would be purged (certbot python3-certbot)" <<<"$1" && [[ -d $2 && ! -e $3 ]]' _ "$out" "$cft/le" "$apt_calls"
OPT_REPORT=(); rm -f "$apt_calls"
certbot_retire_if_unused 0
check "certbot: purges only the installed certbot packages" \
  test "$(cat "$apt_calls")" = "purge -y certbot python3-certbot"
moved_le=$(printf '%s\n' "${OPT_REPORT[@]}" | sed -nE 's/.*is kept in `([^`]*)`.*/\1/p')
check "certbot: the tree is kept under the backup root (not /tmp, which boot empties)" \
  bash -c '[[ ! -e $1 && $2 == "$3"/setup-letsencrypt-*-*/le && -f $2/renewal/direct.test.conf ]]' _ "$cft/le" "$moved_le" "$cft/backups"
check "certbot: the backup directory is private (0700)" \
  test "$(stat -c %a "$(dirname "$moved_le")")" = 700
apt-get() { printf '%s\n' "$*" >> "$apt_calls"; return 100; }
mkdir -p "$cft/le/renewal"
OPT_REPORT=(); rm -f "$apt_calls"
certbot_retire_if_unused 0
check "certbot: a failed purge puts the tree back" \
  bash -c '[[ -d $1/renewal ]] && printf "%s\n" "${@:2}" | grep -q "FAILED.. certbot purge"' _ "$cft/le" "${OPT_REPORT[@]}"
dpkg-query() { return 1; }
OPT_REPORT=()
certbot_retire_if_unused 0
check "certbot: not installed means nothing to report" test "${#OPT_REPORT[@]}" = 0
# The dry run counts a file as freed only when the simulated rewrite leaves
# no /etc/letsencrypt reference in it (site.conf keeps the direct block).
dpkg-query() {
  [[ $* == *python3-certbot-nginx* ]] && return 1
  printf 'certbot install ok installed\n'
}
angie_dump() { printf '# configuration file %s:\n' "$cft/angie/conf.d/site.conf"; cat "$cft/angie/conf.d/site.conf"; }
out=$(cloudflare_tls_migrate "$cft/angie" 1; certbot_retire_if_unused 1)
check "dry run: a file that keeps a certbot block still keeps certbot" \
  grep -q 'certbot: kept; .*site.conf' <<<"$out"
unset -f apt-get dpkg-query systemctl angie_dump angie_fail cf_tls_resolve cf_tls_probe certbot_users_contains cf_tls_docker
unset ANGIE_BIN CERTBOT_DIR CERTBOT_ETC CERTBOT_EXTRA_ROOTS CERTBOT_WWW CERTBOT_BACKUP_ROOT CF_TEST_CODE
check "CF_SELF_SIGNED survives the --optimize pin reset" \
  bash -c 'printf "%s\n" "$@" | grep -qx CF_SELF_SIGNED' _ "${RESET_KEEP_PINS[@]}"
check "the migration runs only when Angie is active and the run is healthy" \
  bash -c 'grep -B1 "cloudflare_tls_migrate /etc/angie 0" "$1" | grep -qF "if (( rc == 0 && active )); then"' _ "$ROOT/lib/service-optimizers.sh"

# --- Elasticsearch: the whole index in RAM (page cache + preload) ---
esram_plan() {
  (
    ESRAM_TOTAL=$1 ESRAM_STORE=$2 ESRAM_DB=${3:-62}
    mem_total_mb() { printf '%s' "$ESRAM_TOTAL"; }
    elasticsearch_data_size_mb() { printf '%s' "$ESRAM_STORE"; }
    elasticsearch_current_heap_mb() { printf '0'; }
    elasticsearch_operator_direct_mb() { printf '0'; }
    mariadb_data_size_mb() { printf '%s' "$ESRAM_DB"; }
    mariadb_current_pool_mb() { printf '0'; }
    OPT_DETECTED=(angie php:8.5 mariadb elastic)
    plan_memory_budget >/dev/null 2>&1
    printf 'preload=%s cache=%s free=%s php=%s maria=%s es=%s\n' \
      "$OPT_ES_PRELOAD" "$OPT_ES_CACHE_MB" "$OPT_ES_CACHE_FREE_MB" "$OPT_PHP_BUDGET_MB" \
      "$OPT_MARIADB_BUDGET_MB" "$OPT_ES_BUDGET_MB"
  )
}
ES_YML="$TMP/es-none.yml"
out=$(esram_plan 64187 7166)
check "ES in RAM: a 7 GB index on 64 GB is preloaded" grep -q '^preload=1 cache=7166 ' <<<"$out"
out=$(esram_plan 64187 60000)
check "ES in RAM: a 60 GB index on 64 GB is not preloaded" grep -q '^preload=0 cache=60000 ' <<<"$out"
base=$(esram_plan 16384 0 2000); with=$(esram_plan 16384 5000 2000)
check "ES in RAM: the index comes off PHP's share, never MariaDB's" \
  test "$(sed -E 's/.* maria=([0-9]+).*/\1/' <<<"$base")" = "$(sed -E 's/.* maria=([0-9]+).*/\1/' <<<"$with")"
check "ES in RAM: no index means no reservation" grep -q '^preload=0 cache=0 ' <<<"$base"
esram_explicit() (
  explicit_option() { [[ $1 == php_children ]] && printf '40'; }
  esram_plan "$@"
)
base=$(esram_explicit 16384 0 2000); with=$(esram_explicit 16384 9000 2000)
check "ES in RAM: an explicit --php children= pool is never shrunk for the index" \
  test "$(sed -E 's/.* php=([0-9]+).*/\1/' <<<"$base")" = "$(sed -E 's/.* php=([0-9]+).*/\1/' <<<"$with")"
check "ES credit: only the unbooked direct share is counted (heap 512, credit 400)" \
  test "$(es_direct_credit_used_mb 512 0 0 400)" = 256
check "ES credit: never more than the credit" test "$(es_direct_credit_used_mb 2048 0 0 400)" = 400
check "ES credit: fully booked direct uses none of it" test "$(es_direct_credit_used_mb 2048 0 1024 400)" = 0
# Hysteresis: 5% growth room to switch on, the index alone to stay on.
check "ES preload: off, 9600 of 10000 free is not switched on (needs +5%)" not es_preload_fits 9600 10000 0
check "ES preload: off, 9500 of 10000 free is switched on (+5% fits)" es_preload_fits 9500 10000 0
check "ES preload: on, 9500 of 10000 free stays on (no restart flip)" es_preload_fits 9500 10000 1
check "ES preload: off, 9000 of 10000 free is switched on" es_preload_fits 9000 10000 0
check "ES preload: on, 10001 of 10000 free is switched off" not es_preload_fits 10001 10000 1
check "ES preload: an empty index is never preloaded" not es_preload_fits 0 10000 1
printf '# BEGIN setup.sh optimize\nindex.store.preload: ["*"]\n# END setup.sh optimize\n' > "$TMP/es-on.yml"
check "ES preload: the live managed block is read for the hysteresis" \
  env ES_YML="$TMP/es-on.yml" bash -c "$(declare -f elasticsearch_preload_active); elasticsearch_preload_active"
printf 'index.store.preload: ["*"]\n# BEGIN setup.sh optimize\n#index.store.preload: ["*"]\n# END setup.sh optimize\n' > "$TMP/es-off.yml"
check "ES preload: a commented or unmanaged preload line does not count" \
  env ES_YML="$TMP/es-off.yml" bash -c "$(declare -f elasticsearch_preload_active); elasticsearch_preload_active; [[ \$? -ne 0 ]]"
unset ES_YML
esyml="$TMP/es-preload.yml"
printf 'cluster.name: x\nindex.store.preload: ["nvd"]\n' > "$esyml"
OPT_ES_PRELOAD=0 elasticsearch_write_performance_block "$esyml"
check "ES yml: an operator preload line is left alone when ours is not written" \
  grep -qxF 'index.store.preload: ["nvd"]' "$esyml"
elasticsearch_strip_managed "$esyml"
OPT_ES_PRELOAD=1 elasticsearch_write_performance_block "$esyml"
check "ES yml: preload [\"*\"] is written in the managed block" \
  bash -c 'sed -n "/# BEGIN setup.sh optimize/,/# END setup.sh optimize/p" "$1" | grep -qxF "index.store.preload: [\"*\"]"' _ "$esyml"
check "ES yml: the operator preload line is commented out when ours replaces it" \
  grep -qxF '#index.store.preload: ["nvd"]' "$esyml"


# ---------------------------------------------------------------------------
# Post-Angie PHP refresh: a clean pass reports nothing (the max_children
# summary used to repeat under the Elasticsearch section of a live report)
# ---------------------------------------------------------------------------
refresh_case() {
  local stub_dirty=$1
  (
    eval "$(sed -n '/^php_refresh_after_angie() {/,/^}/p' "$ROOT/lib/service-optimizers.sh")"
    REPORT_LINES=()
    opt_report() { REPORT_LINES+=("$*"); }
    warn() { :; }
    php_fpm_versions() { printf '8.5\n'; }
    tune_reset_changes() { TUNE_CHANGES=(); TUNE_DIRTY=0; }
    tune_php_fpm_version() {
      TUNE_CHANGES+=("PHP 8.5: max_children=8 (hardware target)")
      if (( stub_dirty )); then TUNE_CHANGES+=("PHP 8.5: ini [PATH=] section rewritten"); TUNE_DIRTY=1; fi
      return 0
    }
    systemctl() { return 0; }
    OPT_PHP_OK=1
    php_refresh_after_angie opt_report "- " 2>&1
    printf '%s\n' "${REPORT_LINES[@]}"
  )
}
check "post-Angie refresh: a clean pass prints nothing and reloads nothing" \
  test -z "$(refresh_case 0 | sed '/^$/d')"
out=$(refresh_case 1)
check "post-Angie refresh: a changing pass reports under its own PHP heading and reloads" \
  bash -c 'grep -qx "## PHP 8.5 (post-Angie refresh)" <<<"$1" && grep -q "section rewritten (post-Angie refresh)" <<<"$1" && grep -q "PHP 8.5: reloaded after the post-Angie ini refresh" <<<"$1"' _ "$out"

printf '\nTOTAL pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
