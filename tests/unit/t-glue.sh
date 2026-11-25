#!/usr/bin/env bash
# Unit tests for the 1.22.0 glue in setup.sh and lib/*.sh: the CLI aliases
# and retired knobs, --php ext= validation, the 4 GB memory gate,
# web_server_state consumers (restart, diagnostics, purge, cron), the cron
# legacy strip, the absolute PHP CLI in cron lines, the apt pin cleanup of
# --purge and the single migration entry point.
# No root, no services and no system changes are required: every function
# that would touch the host runs in a subshell with stubs, and scratch data
# stays under /tmp.
# Usage: bash tests/unit/t-glue.sh
# The suites assign globals (ENABLED/OPT/...) that the sourced helpers read;
# ShellCheck cannot follow that across the source boundary.  The stubs are
# called indirectly by the functions under test.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

# tests/test-tuning.sh sources every unit file in a subshell after it has
# sourced setup.sh itself: setup.sh cannot be sourced twice (its readonly
# SCRIPT_* variables) and the suite's stubs would leak into these checks.
# Run this file in a fresh shell instead; its output and status are what
# the caller collects.
if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-glue.XXXXXX)
# The tests do not remove TMP: a failed run stays inspectable and /tmp
# expires it.

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
# A stale operator export must not change what the sourced helpers see.
unset SETUP_MEM_TOTAL_MB SETUP_PHP_BUILD SETUP_ANGIE_BUILD SETUP_NGINX_BUILD \
  SETUP_VALKEY_BUILD SETUP_PHP_FPM_MODULES SETUP_ANGIE_COMPRESSION
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
# setup.sh installs an ERR trap for production diagnostics; these tests
# exercise failure paths on purpose.
trap - ERR

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-glue.sh,title=Glue test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
# q CMD...: run CMD in a subshell with its output discarded.  A die() inside
# exits that subshell only, never the test.
q() { ( "$@" ) >/dev/null 2>&1; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

# ---------------------------------------------------------------------------
# --nginx, the --angie alias and the retired --source option
# ---------------------------------------------------------------------------
parse_probe() ( # ARGS... -> warnings, then nginx=<0|1>
  ENABLED=()
  OPT=()
  parse_args "$@"
  printf 'nginx=%s\n' "${ENABLED[nginx]:-0}"
)
out=$(parse_probe --basic --nginx 2>&1) || true
check "--nginx enables nginx" has "$out" "nginx=1"
check "--nginx prints no deprecation warning" lacks "$out" "deprecated"
out=$(parse_probe --basic --angie 2>&1) || true
check "--angie still enables nginx" has "$out" "nginx=1"
check "--angie warns that it is a deprecated alias" has "$out" "--angie is deprecated"
check "--angie names --nginx as the replacement" has "$out" "Use --nginx"
out=$(parse_probe --basic --source nginx php --nginx 2>&1) || true
check "--source WORDS is consumed and ignored with a warning" has "$out" "--source=nginx php is ignored"
check "the flag after --source WORDS is still parsed" has "$out" "nginx=1"
out=$(parse_probe --optimize --source=none 2>&1) || true
check "--source=none names the removed package builds" has "$out" "--source=none is ignored"

# ---------------------------------------------------------------------------
# Retired build knobs: dropped at source time and remembered for the warning
# ---------------------------------------------------------------------------
retired_probe() {
  env SETUP_VALKEY_BUILD=gcc SETUP_PHP_FPM_MODULES=all PHP_BUILD=package \
    SETUP_TEST_SOURCE_ONLY=1 SETUP_STATE_DIR="$TMP/state" \
    bash -c 'source "$1" >/dev/null 2>&1
             printf "retired=%s\n" "${RETIRED_BUILD_ENV[*]}"
             printf "valkey_env=%s\n" "${SETUP_VALKEY_BUILD+set}"
             printf "php_build=%s\n" "${PHP_BUILD+set}"' _ "$ROOT/setup.sh"
}
out=$(retired_probe 2>&1) || true
check "SETUP_VALKEY_BUILD is recorded as retired" has "$out" "SETUP_VALKEY_BUILD=gcc"
check "SETUP_PHP_FPM_MODULES is recorded as retired" has "$out" "SETUP_PHP_FPM_MODULES=all"
check "a retired SETUP_* knob is dropped from the environment" has "$out" "valkey_env="$'\n'
check "a host-file PHP_BUILD pin is dropped from memory" has "$out" "php_build="
check "a host-file PHP_BUILD pin is not kept" lacks "$out" "php_build=set"
check "validate_all prints the retired-knob warning" \
  grep -q 'Ignored (removed in 1.22.0' "$ROOT/lib/validate.sh"

# ---------------------------------------------------------------------------
# --php ext=LIST
# ---------------------------------------------------------------------------
check "ext=intl,gmp is accepted" q php_ext_validate intl,gmp
check "ext= names are case-insensitive" q php_ext_validate INTL
check "ext=none clears the list" q php_ext_validate none
check "ext=-intl drops an added extension" q php_ext_validate -intl
check "an empty ext= is refused" not q php_ext_validate ""
check "ext=none cannot be combined with names" not q php_ext_validate none,intl
check "ext= refuses a file name" not q php_ext_validate intl.so
check "ext= refuses shell metacharacters" not q php_ext_validate 'intl;id'
check "ext= refuses an extension the build cannot compile" not q php_ext_validate oci8
out=$( ( php_ext_validate oci8 ) 2>&1 ) || true
check "the refusal names the buildable list" has "$out" "buildable:"
check "kv_set refuses an empty --php ext=" not q kv_set php ext ""
ext_apply_probe() ( # DRY_RUN EXT -> number of php_build_ext_option calls
  local n=0
  php_build_ext_option() { n=$((n + 1)); return 0; }
  DRY_RUN=$1
  OPT=()
  [[ -n $2 ]] && OPT[php.ext]=$2
  PHP_EXT_REQUEST_APPLIED=0
  php_ext_request_apply
  php_ext_request_apply
  printf '%s' "$n"
)
check "php_ext_request_apply records ext= once per run" test "$(ext_apply_probe 0 intl)" = 1
check "php_ext_request_apply records nothing in a dry run" test "$(ext_apply_probe 1 intl)" = 0
check "php_ext_request_apply is a no-op without ext=" test "$(ext_apply_probe 0 '')" = 0
check "install_php applies --php ext= before the build" \
  bash -c 'sed -n "/^install_php()/,/^}/p" "$1" | grep -q php_ext_request_apply' _ "$ROOT/lib/services.sh"

# first_line FILE FUNC REGEX: line (within FUNC's body) of the first code
# line matching REGEX, or 0.  Comment lines are skipped.
first_line() {
  sed -n "/^$2()/,/^}/p" "$1" \
    | awk -v re="$3" '!f && !/^[[:space:]]*#/ && $0 ~ re { print NR; f = 1 } END { if (!f) print 0 }'
}
before() { # FILE FUNC REGEX_A REGEX_B: A is present and comes before B
  local a b
  a=$(first_line "$1" "$2" "$3")
  b=$(first_line "$1" "$2" "$4")
  (( a > 0 && b > 0 && a < b ))
}
check "install_php records ext= before it lists the apps and builds" \
  before "$ROOT/lib/services.sh" install_php '^[[:space:]]+php_ext_request_apply' 'php_build_ensure "[$]ver"'
check "php_build_ensure applies ext= before it computes the extension set" \
  before "$ROOT/lib/php-build.sh" php_build_ensure 'php_ext_request_apply' 'php_build_effective_exts'
check "php_build_ensure never applies ext= in the migrate context" \
  bash -c 'sed -n "/^php_build_ensure()/,/^}/p" "$1" | grep -B2 -E "^[[:space:]]+php_ext_request_apply" \
    | grep -q "context != migrate"' _ "$ROOT/lib/php-build.sh"

# ---------------------------------------------------------------------------
# Memory gate (section 7, R39)
# ---------------------------------------------------------------------------
gate() ( # DRY_RUN SOURCE_ONLY MEM SERVICE -> rc of mem_gate_allows
  DRY_RUN=$1
  SETUP_TEST_SOURCE_ONLY=$2
  SETUP_MEM_TOTAL_MB=$3
  mem_total_mb() { printf '16384'; }
  mem_gate_allows "$4"
)
klass() ( # DRY_RUN SOURCE_ONLY MEM -> mem_class_mb
  DRY_RUN=$1
  SETUP_TEST_SOURCE_ONLY=$2
  SETUP_MEM_TOTAL_MB=$3
  mem_total_mb() { printf '16384'; }
  mem_class_mb
)
check "SETUP_MEM_TOTAL_MB is honoured in a dry run" test "$(klass 1 0 2048)" = 2048
check "SETUP_MEM_TOTAL_MB is honoured in source-only test mode" test "$(klass 0 1 2048)" = 2048
if grep -qE '^MemTotal:[[:space:]]+[1-9]' /proc/meminfo 2>/dev/null; then
  check "SETUP_MEM_TOTAL_MB is ignored in a real run" test "$(klass 0 0 2048)" = 16384
  check "a malformed SETUP_MEM_TOTAL_MB falls back to the host" test "$(klass 1 0 2g)" = 16384
fi
check "mem_override_allowed is false outside dry run and tests" \
  not bash -c 'DRY_RUN=0 SETUP_TEST_SOURCE_ONLY=0; '"$(declare -f mem_override_allowed)"'; mem_override_allowed'
check "nginx is allowed below the 4 GB class" gate 1 0 1024 nginx
check "basic is allowed below the 4 GB class" gate 1 0 1024 basic
check "others is allowed below the 4 GB class" gate 1 0 1024 others
check "a domain is allowed below the 4 GB class" gate 1 0 1024 domain
check "PHP is refused at 3499 MB" not gate 1 0 3499 php
check "Valkey is refused at 3499 MB" not gate 1 0 3499 valkey
check "MariaDB is refused at 3499 MB" not gate 1 0 3499 mariadb
check "Elasticsearch is refused at 3499 MB" not gate 1 0 3499 elastic
check "an unknown service fails safe below the class" not gate 1 0 2048 newthing
check "PHP is allowed at 3500 MB (the 4 GB class)" gate 1 0 3500 php
check "Valkey is allowed at 3500 MB" gate 1 0 3500 valkey
check "an unreadable memory class (0) allows" \
  bash -c "$(declare -f mem_gate_allows); MEM_GATE_MIN_MB=3500; mem_class_mb() { printf 0; }; mem_gate_allows php"
check "basic sites need no PHP" not domain_app_needs_php basic
check "node sites need no PHP" not domain_app_needs_php node
check "pingvin sites need no PHP" not domain_app_needs_php pingvin
check "WordPress sites need PHP" domain_app_needs_php wordpress
check "XenForo sites need PHP" domain_app_needs_php xf
out=$( ( DRY_RUN=1; SETUP_MEM_TOTAL_MB=2048; mem_gate_reason ) 2>&1 ) || true
check "the refusal names the measured class and the rule" has "$out" "2048 MB RAM, below the 4 GB class (3500 MB)"
check "validate_all warns that SETUP_MEM_TOTAL_MB is ignored outside --dry-run" \
  bash -c 'sed -n "/^validate_all()/,/^}/p" "$1" | grep -q "SETUP_MEM_TOTAL_MB is ignored outside --dry-run"' \
  _ "$ROOT/lib/validate.sh"
# One definition of the gate: lib/optimize.sh lost its fallback copies, whose
# allow list and override rule differed from lib/validate.sh.
for fn in mem_class_mb mem_gate_allows mem_override_allowed; do
  n=$(cat "$ROOT/setup.sh" "$ROOT"/lib/*.sh | grep -cE "^[[:space:]]*${fn}\(\)" || true)
  check "${fn} is defined once (lib/validate.sh)" test "$n" = 1
done
check "the 4 GB class is 3500 MB" test "$MEM_GATE_MIN_MB" = 3500

# ---------------------------------------------------------------------------
# web_server_state and its consumers
# ---------------------------------------------------------------------------
WSS_DIR="$TMP/wss"
mkdir -p "$WSS_DIR"
wss() ( # NAME STATE_LINE ANGIE_PKG(0|1)
  MIGRATE_STATE_FILE="$WSS_DIR/state-$1"
  MIGRATE_ANGIE_ETC="$WSS_DIR/no-angie"
  NGINX_BUILD_ROOT="$WSS_DIR/no-nginx"
  [[ -z $2 ]] || printf '%s\n' "$2" > "$MIGRATE_STATE_FILE"
  ANGIE_PKG=$3
  dpkg-query() { [[ $ANGIE_PKG == 1 && ${!#} == angie ]] && printf 'ii '; return 0; }
  web_server_state
)
check "nginx=done reads as nginx" test "$(wss state-done nginx=done 1)" = nginx
check "nginx=cutover reads as nginx" test "$(wss state-cutover nginx=cutover 1)" = nginx
check "an installed Angie without a finished part is angie-legacy" \
  test "$(wss legacy nginx=blocked:disk 1)" = angie-legacy
check "no Angie and no nginx build is none" test "$(wss none '' 0)" = none

# Each consumer with web_server_state stubbed.
with_state() ( # STATE FUNC ARGS...
  WSTATE=$1
  shift
  web_server_state() { printf '%s' "$WSTATE"; }
  "$@"
)
check "restart: nginx state restarts nginx" test "$(with_state nginx restart_web_unit)" = nginx
check "restart: legacy state restarts angie" test "$(with_state angie-legacy restart_web_unit)" = angie
check "restart: none falls back to nginx" test "$(with_state none restart_web_unit)" = nginx
check "diagnostics: legacy reads /etc/angie" test "$(with_state angie-legacy diag_web_etc)" = /etc/angie
check "diagnostics: nginx reads /etc/nginx" test "$(with_state nginx diag_web_etc)" = /etc/nginx
check "diagnostics: legacy mode is detected" with_state angie-legacy diag_angie_legacy
check "diagnostics: nginx is not legacy" not with_state nginx diag_angie_legacy
check "purge: legacy mode is detected" with_state angie-legacy purge_angie_legacy
check "purge: none is not legacy" not with_state none purge_angie_legacy
printf '#!/bin/sh\nexit 0\n' > "$WSS_DIR/nginx"
chmod +x "$WSS_DIR/nginx"
check "diagnostics: the compiled nginx binary is reported" \
  test "$(NGINX_BIN="$WSS_DIR/nginx" with_state nginx diag_web_bin)" = "$WSS_DIR/nginx"
# validate_all: an install step on a host the migration still owns waits for
# --optimize (legacy_stack_refusals reads web_server_state and migrate_needed).
lsr() ( # STATE NEEDED_PARTS SERVICE|domain:APP -> refusal lines
  WSTATE=$1
  NEEDED=" $2 "
  ENABLED=()
  DOMAINS=()
  DOMAIN_APP=()
  case $3 in
    domain:*) DOMAINS=(a.example.com); DOMAIN_APP[a.example.com]=${3#domain:} ;;
    *) ENABLED[$3]=1 ;;
  esac
  web_server_state() { printf '%s' "$WSTATE"; }
  migrate_needed() { [[ $NEEDED == *" ${1:-any} "* ]]; }
  legacy_stack_refusals
)
check "legacy mode refuses --nginx until --optimize" has "$(lsr angie-legacy '' nginx)" "--nginx: this host still serves through Angie"
check "legacy mode refuses --domain until --optimize" has "$(lsr angie-legacy '' domain:basic)" "--domain: this host still serves through Angie"
check "nginx mode does not refuse --nginx" test -z "$(lsr nginx '' nginx)"
check "a pending Sury PHP refuses --php" has "$(lsr nginx php php)" "--php: the Sury PHP packages"
check "a pending Sury PHP refuses a PHP --domain app" has "$(lsr nginx php domain:wordpress)" "needs PHP"
check "a pending Sury PHP does not refuse a static --domain" test -z "$(lsr nginx php domain:basic)"
check "a pending valkey-server refuses --valkey" has "$(lsr nginx valkey valkey)" "--valkey: the valkey-server package"
check "nothing pending refuses nothing" test -z "$(lsr nginx '' php)"
no_state() ( unset -f web_server_state; "$@" )
check "restart without lib/migrate.sh restarts nginx" test "$(no_state restart_web_unit)" = nginx
check "purge without lib/migrate.sh is not legacy" not no_state purge_angie_legacy

# ---------------------------------------------------------------------------
# Cron: gate, legacy strip, absolute PHP CLI
# ---------------------------------------------------------------------------
cwe() ( # STATE CNC(0|1) -> cron_web_etc output, rc as the last line
  WSTATE=$1
  CNC=$2
  web_server_state() { printf '%s' "$WSTATE"; }
  cron_nginx_configured() { (( CNC )); }
  local rc=0
  cron_web_etc || rc=$?
  printf '\nrc=%s' "$rc"
)
check "cron: a configured nginx serves /etc/nginx" test "$(cwe nginx 1)" = $'/etc/nginx\nrc=0'
check "cron: no configured nginx means no web jobs" test "$(cwe nginx 0)" = $'\nrc=1'
if [[ -f /etc/angie/angie.conf ]]; then
  check "cron: legacy mode serves /etc/angie" test "$(cwe angie-legacy 1)" = $'/etc/angie\nrc=0'
else
  check "cron: legacy mode without angie.conf has no web jobs (never /etc/nginx)" \
    test "$(cwe angie-legacy 1)" = $'\nrc=1'
fi
check "cron: cron_nginx_configured asks no package database" \
  bash -c 'sed -n "/^cron_nginx_configured()/,/^}/p" "$1" | grep -qE "pkg_ok|dpkg" && exit 1; exit 0' _ "$ROOT/lib/util.sh"
check "cron: NGINX_BIN missing is not configured" \
  not bash -c "NGINX_BIN=$WSS_DIR/missing; $(declare -f cron_nginx_configured); cron_nginx_configured"

STRIP_IN=$(cat <<'EOF'
2 1 * * * /etc/nginx/scripts/cloudflare.sh >/dev/null 2>&1
2 1 * * * /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1
0 0 * * * chown www-data:www-data -R /var/www/ >/dev/null 2>&1
0 0 * * * /usr/bin/find /var/www -mindepth 1 -exec chown www-data:www-data {} +
4 4 4 * * /usr/bin/mysqlcheck -Aos --auto-repair
15 2 * * * /usr/local/bin/operator-job.sh
EOF
)
STRIP_OUT=$(printf '%s\n' "$STRIP_IN" | cron_strip_legacy_jobs)
check "cron strip keeps /etc/nginx/scripts/cloudflare.sh" has "$STRIP_OUT" "/etc/nginx/scripts/cloudflare.sh"
check "cron strip drops /etc/angie/scripts/cloudflare.sh" lacks "$STRIP_OUT" "/etc/angie/scripts/cloudflare.sh"
check "cron strip drops the blanket chown" lacks "$STRIP_OUT" "chown www-data:www-data -R"
check "cron strip drops the old find chown" lacks "$STRIP_OUT" "/usr/bin/find /var/www"
check "cron strip drops the old mysqlcheck path" lacks "$STRIP_OUT" "mysqlcheck"
check "cron strip keeps an operator job" has "$STRIP_OUT" "/usr/local/bin/operator-job.sh"

cpc() ( # CLI(empty = none) CMD
  CLI=$1
  php_cli_path() { [[ -n $CLI ]] || return 1; printf '%s' "$CLI"; }
  cron_php_command "$2"
)
check "managed wp-cron line names an absolute PHP CLI" has "$CRON_WP_CRON" " -- /usr/bin/php "
check "managed XenForo job line names an absolute PHP CLI" has "$CRON_XF_JOBS" " -- /usr/bin/php "
check "managed cron lines never run a bare php" \
  not grep -qE '(^|[[:space:];|])php[[:space:]]' <<<"${CRON_WP_CRON}"$'\n'"${CRON_XF_JOBS}"
out=$(cpc /usr/local/bin/php "$CRON_WP_CRON")
check "cron PHP falls back to /usr/local/bin/php" has "$out" " -- /usr/local/bin/php "
check "the fallback leaves no /usr/bin/php call" lacks "$out" "/usr/bin/php "
check "cron PHP keeps /usr/bin/php when it exists" test "$(cpc /usr/bin/php "$CRON_XF_JOBS")" = "$CRON_XF_JOBS"
check "cron PHP is unchanged without any CLI" test "$(cpc '' "$CRON_WP_CRON")" = "$CRON_WP_CRON"

# ---------------------------------------------------------------------------
# --purge drops its patterns from the apt pin
# ---------------------------------------------------------------------------
PIN_DIR="$TMP/pin"
mkdir -p "$PIN_DIR/glob" "$PIN_DIR/phproot/8.4/sbin"
# Files that the '*' patterns would match if they were expanded as globs in
# the working directory.
for f in nginx-x php-y php8 angie-z libnginx-mod-a libapache2-mod-php8 valkey-server; do
  : > "$PIN_DIR/glob/$f"
done
PIN="$PIN_DIR/setup-source-builds"
PIN_HEAD='# setup.sh: the compiled nginx, PHP and Valkey own these paths'
write_pin() {
  printf '%s\n' "$PIN_HEAD" "Package: $1" 'Pin: release *' 'Pin-Priority: -1' > "$PIN"
}
pin_pkgs() { sed -nE 's/^Package:[[:space:]]*//p' "$PIN"; }
purge_run() ( # FUNC [PHP_VER]
  cd "$PIN_DIR/glob" || exit 1
  PURGE_APT_PIN=$PIN
  PHP_BUILD_ROOT="$PIN_DIR/phproot"
  OPT=()
  [[ -z ${2:-} ]] || OPT[php.ver]=$2
  step() { :; }
  ok() { :; }
  info() { :; }
  warn() { :; }
  anubis_host_present() { return 1; }
  purge_service_stop() { printf 'stop %s\n' "$1" >> "$PIN_DIR/calls"; }
  nginx_build_purge() { :; }
  valkey_build_purge() { :; }
  php_build_purge() { :; }
  setup_build_remove_shared_units_if_last() { printf 'shared %s\n' "$1" >> "$PIN_DIR/calls"; }
  cron_remove_line() { :; }
  systemctl() { return 1; }
  web_server_state() { printf '%s' "${WSTATE:-nginx}"; }
  "$1"
) >/dev/null 2>&1

write_pin 'angie angie-* libapache2-mod-php* libnginx-mod-* nginx nginx-* php-* php[0-9]* valkey-server valkey-tools'
: > "$PIN_DIR/calls"
purge_run purge_nginx || true
check "purge nginx drops the nginx and Angie patterns" \
  test "$(pin_pkgs)" = 'libapache2-mod-php* php-* php[0-9]* valkey-server valkey-tools'
check "purge keeps the pin header" grep -qxF "$PIN_HEAD" "$PIN"
check "purge keeps the Pin-Priority line" grep -qx 'Pin-Priority: -1' "$PIN"
check "purge nginx stops nginx" grep -qx 'stop nginx' "$PIN_DIR/calls"
check "purge nginx leaves angie alone outside legacy mode" not grep -qx 'stop angie' "$PIN_DIR/calls"
: > "$PIN_DIR/calls"
WSTATE=angie-legacy purge_run purge_nginx || true
check "purge nginx in legacy mode stops angie" grep -qx 'stop angie' "$PIN_DIR/calls"
purge_run purge_valkey || true
check "purge valkey drops valkey-server and valkey-tools" \
  test "$(pin_pkgs)" = 'libapache2-mod-php* php-* php[0-9]*'
: > "$PIN_DIR/phproot/8.4/sbin/php-fpm"
chmod +x "$PIN_DIR/phproot/8.4/sbin/php-fpm"
: > "$PIN_DIR/calls"
purge_run purge_php 8.3 || true
check "purge php keeps the PHP patterns while a compiled php-fpm is left" \
  test "$(pin_pkgs)" = 'libapache2-mod-php* php-* php[0-9]*'
check "purge php keeps the shared units while a PHP build is left" \
  not grep -q '^shared ' "$PIN_DIR/calls"
mv "$PIN_DIR/phproot/8.4" "$PIN_DIR/phproot-gone-8.4"
purge_run purge_php 8.4 || true
check "purge php removes the pin file once no pattern is left" test ! -e "$PIN"
check "purge php releases the shared units with the last build" grep -qx 'shared php' "$PIN_DIR/calls"
write_pin 'php* valkey-server'
purge_run purge_php 8.4 || true
check "purge php also drops an older bare php* pattern" test "$(pin_pkgs)" = 'valkey-server'
check "no pattern was expanded against the working directory" \
  not grep -qE 'nginx-x|php-y|angie-z' "$PIN"

# ---------------------------------------------------------------------------
# Single migration entry point
# ---------------------------------------------------------------------------
MIG_DIR="$TMP/mig"
mkdir -p "$MIG_DIR"
mig_step() ( # DRY SKIP NEEDED RC -> "rc=<step rc> calls=<n> legacy=<0|1> ran=<0|1>"
  DRY_RUN=$1
  OPT_SKIP_MIGRATION=$2
  NEEDED=$3
  MRC=$4
  OPT_WEB_LEGACY=0
  OPT_DETECT_NOTES=()
  : > "$MIG_DIR/calls"
  migrate_run() { printf 'run\n' >> "$MIG_DIR/calls"; return "$MRC"; }
  migrate_running() { return 1; }
  migrate_needed() { (( NEEDED )); }
  detect_installed_services() { :; }
  plan_memory_budget() { :; }
  step() { :; }
  opt_report() { :; }
  local rc=0
  optimize_migration_step || rc=$?
  printf 'rc=%s calls=%s legacy=%s ran=%s' "$rc" "$(wc -l < "$MIG_DIR/calls" | tr -d ' ')" \
    "$OPT_WEB_LEGACY" "$OPT_MIGRATE_RAN"
)
check "optimize runs a pending migration" test "$(mig_step 0 0 1 0)" = 'rc=0 calls=1 legacy=0 ran=1'
check "the pass after --domain never starts the migration" test "$(mig_step 0 1 1 0)" = 'rc=0 calls=0 legacy=0 ran=0'
check "a dry run never starts the migration" test "$(mig_step 1 0 1 0)" = 'rc=0 calls=0 legacy=0 ran=0'
check "nothing pending runs nothing" test "$(mig_step 0 0 0 0)" = 'rc=0 calls=0 legacy=0 ran=0'
check "migrate_run status 2 is legacy mode, not a failure" test "$(mig_step 0 0 1 2)" = 'rc=0 calls=1 legacy=1 ran=1'
check "migrate_run status 1 fails the run" test "$(mig_step 0 0 1 1)" = 'rc=1 calls=1 legacy=0 ran=1'
check "any other migrate_run status fails the run" test "$(mig_step 0 0 1 125)" = 'rc=1 calls=1 legacy=0 ran=1'

post_domain() ( # -> the OPT_SKIP_MIGRATION run_optimize saw, then the value after
  SVC_STATUS=()
  SVC_STATUS[domain]=OK
  ENABLED=()
  unset SETUP_DOMAIN_OPTIMIZE
  info() { :; }
  run_optimize() { printf 'during=%s ' "$OPT_SKIP_MIGRATION"; }
  OPT_SKIP_MIGRATION=0
  run_post_domain_optimize
  printf 'after=%s' "$OPT_SKIP_MIGRATION"
)
check "run_post_domain_optimize skips the migration and resets the flag" \
  test "$(post_domain)" = 'during=1 after=0'

# Source checks: optimize_migration_step is the only caller of migrate_run
# outside lib/migrate.sh, and only run_optimize calls the step.
callers() { # NAME -> file:line of every non-comment call outside lib/migrate.sh
  local f
  for f in "$ROOT/setup.sh" "$ROOT"/lib/*.sh; do
    [[ $f == */lib/migrate.sh ]] && continue
    grep -nE "(^|[^_[:alnum:]-])$1([[:space:];|&)]|$)" "$f" \
      | grep -vE "^[0-9]+:[[:space:]]*#" \
      | grep -vE "declare -F $1" \
      | grep -vE "^[0-9]+:[[:space:]]*$1\(\)" \
      | sed "s|^|${f#"$ROOT"/}:|" || true
  done
}
mr=$(callers migrate_run)
check "migrate_run is called once outside lib/migrate.sh" test "$(printf '%s\n' "$mr" | grep -c .)" = 1
check "that call is in lib/optimize.sh" has "$mr" "lib/optimize.sh:"
check "optimize_migration_step calls migrate_run" \
  bash -c 'sed -n "/^optimize_migration_step()/,/^}/p" "$1" | grep -qE "^[[:space:]]+migrate_run "' _ "$ROOT/lib/optimize.sh"
ms=$(callers optimize_migration_step)
check "only lib/restart.sh calls optimize_migration_step" \
  test "$(printf '%s\n' "$ms" | grep -c .)" = 1
check "run_optimize is that caller" \
  bash -c 'sed -n "/^run_optimize()/,/^}/p" "$1" | grep -q "optimize_migration_step"' _ "$ROOT/lib/restart.sh"
check "create_domains does not touch the migration" \
  bash -c 'grep -l "^create_domains()" "$@" | while read -r f; do sed -n "/^create_domains()/,/^}/p" "$f"; done \
    | grep -qE "migrate_(run|detach|main)|optimize_migration_step" && exit 1; exit 0' _ "$ROOT"/lib/*.sh

check "run_optimize runs the migration step after plan_memory_budget" \
  before "$ROOT/lib/restart.sh" run_optimize '^[[:space:]]+plan_memory_budget' 'optimize_migration_step'
check "run_optimize runs the migration step before run_os_tuning" \
  before "$ROOT/lib/restart.sh" run_optimize 'optimize_migration_step' '^[[:space:]]+run_os_tuning'
check "run_optimize keeps no migrate_run block of its own" \
  bash -c 'sed -n "/^run_optimize()/,/^}/p" "$1" | grep -vE "^[[:space:]]*#" | grep -qE "migrate_(run|detach)" && exit 1; exit 0' \
  _ "$ROOT/lib/restart.sh"
# A rerun of --optimize while the unit works only attaches: main() follows
# the running unit (migrate_attach_running) and never calls migrate_detach_cmd,
# which with no command used to start a unit and report a false status 125.
check "main attaches with migrate_attach_running" \
  bash -c 'sed -n "/^main()/,/^}/p" "$1" | grep -qE "^[[:space:]]+migrate_attach_running"' _ "$ROOT/lib/restart.sh"
md=$(callers migrate_detach_cmd)
check "nothing outside lib/migrate.sh calls migrate_detach_cmd" test -z "$md"
check "migrate_attach_running never starts a unit" \
  bash -c 'sed -n "/^migrate_attach_running()/,/^}/p" "$1" | grep -vE "^[[:space:]]*#" \
    | grep -qE "systemd-run|acquire_run_lock|migrate_detach" && exit 1; exit 0' _ "$ROOT/lib/restart.sh"
attach_rc() ( # RC_FILE_CONTENT(empty = no file) -> status of migrate_attach_running
  MIGRATE_STATE_FILE="$MIG_DIR/attach-state"
  MIGRATE_LOG=""
  rm -f "${MIGRATE_STATE_FILE}.rc"
  [[ -z $1 ]] || printf '%s\n' "$1" > "${MIGRATE_STATE_FILE}.rc"
  systemctl() { printf '0\n'; }
  info() { :; }
  warn() { :; }
  local rc=0
  migrate_attach_running || rc=$?
  printf '%s' "$rc"
)
check "an attach after the unit finished returns its recorded 0" test "$(attach_rc 0)" = 0
check "an attach returns the recorded failure status" test "$(attach_rc 7)" = 7
check "an attach with no recorded result fails, never 125" test "$(attach_rc '')" = 1
# The unit plans as the migration will leave the host, from the reset
# in-memory profile.
check "run_migrate_unit resets the in-memory profile before it detects" \
  before "$ROOT/lib/restart.sh" run_migrate_unit 'reset_operator_overrides 2' 'detect_installed_services migrate'
check "run_migrate_unit detects (migrate) before plan_memory_budget" \
  before "$ROOT/lib/restart.sh" run_migrate_unit 'detect_installed_services migrate' '^[[:space:]]+plan_memory_budget'

# log_excerpt never copies a log into itself (1.22.0 --upgrade-php test: the
# tool's stderr was the log, `tail log >&2` grew it to 1.7 TB).
lx_case() { # self|other -> bytes the excerpt added to the log, lines on stderr
  (
    set +eE; trap - ERR
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/tools/build-common.sh"
    f=$TMP/lx.log; seq 1 100 > "$f"
    if [[ $1 == self ]]; then
      log_excerpt "$f" 30 2>>"$f"
      printf '%s' "$(( $(stat -c %s "$f") - $(seq 1 100 | wc -c) ))"
    else
      printf '%s' "$(log_excerpt "$f" 30 2>&1 >/dev/null | wc -l)"
    fi
  )
}
check "log_excerpt writes nothing when stderr is the log itself (no self-copy loop)" test "$(lx_case self)" = 0
check "log_excerpt prints exactly N lines to another stderr" test "$(lx_case other)" = 30
check "the tools never tail their own log to stderr directly" \
  bash -c '! grep -nE "tail -n [0-9]+ \"\\\$(log|LOG_FILE)\" >&2" "$1"/tools/*.sh' _ "$ROOT"
check "builds cap the size of any file they write (ulimit -f)" \
  bash -c 'sed -n "/^build_deprioritize()/,/^}/p" "$1" | grep -q "ulimit -f"' _ "$ROOT/tools/build-common.sh"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
