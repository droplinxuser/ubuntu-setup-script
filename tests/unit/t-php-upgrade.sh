#!/usr/bin/env bash
# Unit tests for --upgrade-php (lib/php-upgrade.sh, 1.22.0 source builds):
#   - the target's effective extension set is carried from the active
#     version (B's _pb_prev_union), so the planned set, the build and the
#     binding gate agree and nothing the serving build loads is dropped;
#   - the application requirement table (install vs preflight mode), the
#     /var/www and vhost walks and the binding gate on the candidate's
#     modules;
#   - the refusals: the 1.22 migration's PHP part pending (every state the
#     migration can leave), an Angie-legacy web tier, the 4 GB class, and a
#     run that refuses changes nothing;
#   - the rollback leaves the previous version active (marker, links, unit
#     restarted, the target stopped and disabled), the prepare-phase
#     rollback restarts nothing;
#   - after the commit the previous version's unit is disabled (not masked),
#     a package or running unit is reported, older builds are retired and
#     the kept rollback build is not.
# No root, no services and no system changes are required: every path of
# lib/php-build.sh points below a scratch directory in /tmp, systemctl and
# the other host commands are recording shell functions, and the PHP
# binaries are small fake scripts.  Series 9.5-9.8 are used wherever
# lib/php-upgrade.sh still names /etc/php/X.Y itself, so no host tree can
# ever match.
# Usage: bash tests/unit/t-php-upgrade.sh
# The suites assign globals that the sourced helpers read; ShellCheck cannot
# follow that across the source boundary.  The stubs are called indirectly
# by the functions under test.
# shellcheck disable=SC2034,SC2317,SC2329
# tests/test-tuning.sh sources each unit file after it sourced setup.sh,
# whose globals are readonly there: run this file in a fresh bash instead.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  bash "${BASH_SOURCE[0]}"
  return
fi
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-test-php-upgrade.XXXXXX")
# The tests do not remove TMP: a failed run stays inspectable and /tmp
# expires it.

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
export SETUP_TUNING_FILE="$TMP/setup-tuning"
export SETUP_MIGRATE_STATE_FILE="$TMP/state/migrate-1.22"
export PHP_BUILD_ROOT="$TMP/root" PHP_BUILD_CACHE="$TMP/cache" PHP_BUILD_UNIT_DIR="$TMP/units" \
  PHP_BUILD_ETC="$TMP/etc/php" PHP_BUILD_TMPFILES="$TMP/tmpfiles/setup-php.conf" \
  PHP_BUILD_TMPFILES_POOLS="$TMP/tmpfiles/setup-php-pools.conf" \
  PHP_BUILD_LINK_BIN="$TMP/usr/local/bin" PHP_BUILD_LINK_SBIN="$TMP/usr/local/sbin" \
  PHP_BUILD_USR_BIN="$TMP/usr/bin" PHP_BUILD_BACKUP_DIR="$TMP/backups" \
  PHP_BUILD_ALT_LINK="$TMP/alternatives/php" PHP_BUILD_SCAN_CACHE="$TMP/scan-cache" \
  PHP_BUILD_NGINX="$TMP/nginx-empty" PHP_BUILD_WWW="$TMP/www-empty" PHP_BUILD_ANGIE_ETC="$TMP/angie"
export PHP_BUILD_EXTRA_WEB_TREES=""
unset PHP_EXT_EXTRA PHP_BUILD_EXT_RESET PHP_BUILD_APPS PHP_EXT_DETECT_TREE PHP_BUILD_DETECT_ROOTS \
  SETUP_PHP_ALLOW_MISSING_EXT SETUP_MEM_TOTAL_MB PHP_INI_SCAN_DIR FAKE_LOG UPGRADE_PHP
mkdir -p "$TMP/state" "$TMP/nginx-empty/conf.d" "$TMP/www-empty"
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
# lib/php-upgrade.sh hard-codes the marker; nothing here may touch /etc/php.
PHP_UPGRADE_ACTIVE_MARKER=$PHP_ACTIVE_FILE

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-php-upgrade.sh,title=PHP upgrade test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
q() { ( "$@" ) >/dev/null 2>&1; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
line_in() { grep -qxF -- "$2" <<<"$1"; }
line_not_in() { ! grep -qxF -- "$2" <<<"$1"; }
file_has() { [[ -f $1 ]] && grep -qF -- "$2" "$1"; }
file_lacks() { [[ ! -f $1 ]] || ! grep -qF -- "$2" "$1"; }
link_to() { [[ -L $1 && $(readlink "$1") == "$2" ]]; }
# Line number of the first line of FILE containing TEXT (0 when none).
line_no() { local n; n=$(grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1) || true; printf '%s' "${n:-0}"; }

# ---------------------------------------------------------------------------
# Fixtures (the same fakes as tests/unit/t-php-build.sh)
# ---------------------------------------------------------------------------
mk_fake_php() { # path [module...]
  local f=$1
  shift
  mkdir -p "${f%/*}"
  cat > "$f" <<'EOF'
#!/bin/bash
if [[ -n ${FAKE_LOG:-} ]]; then
  printf '%s|scan=%s|%s\n' "$0" "${PHP_INI_SCAN_DIR-unset}" "$*" >> "$FAKE_LOG"
fi
args=" $* "
case $args in
  *" -v "*)
    printf 'PHP %s (cli) (built: Jan  1 2026 00:00:00) (NTS)\n' "$(cat "$0.version" 2>/dev/null || printf '8.4.3')"
    exit 0 ;;
  *" -t "*)
    if [[ -f $0.tfail ]]; then printf 'ERROR: configuration test failed\n' >&2; exit 78; fi
    printf 'NOTICE: configuration file test is successful\n' >&2
    exit 0 ;;
  *" -m "*)
    [[ -f $0.warn ]] && cat "$0.warn"
    printf '[PHP Modules]\n'
    grep -vx 'opcache' "$0.mods" 2>/dev/null
    printf '\n[Zend Modules]\n'
    grep -qx 'opcache' "$0.mods" 2>/dev/null && printf 'Zend OPcache\n'
    printf '\n'
    exit 0 ;;
esac
exit 0
EOF
  chmod 755 "$f"
  if (( $# )); then printf '%s\n' "$@" > "$f.mods"; else : > "$f.mods"; fi
}

mk_build() { # VER [EXTS-CSV]
  local v=$1 exts=${2:-ctype} d
  local -a ex=() core=(core date hash json pcre reflection spl standard random opcache)
  d="$PHP_BUILD_ROOT/$v"
  IFS=, read -ra ex <<<"$exts"
  mk_fake_php "$d/sbin/php-fpm" "${core[@]}" cgi-fcgi "${ex[@]}"
  mk_fake_php "$d/bin/php" "${core[@]}" "${ex[@]}"
  printf '%s.3\n' "$v" > "$d/sbin/php-fpm.version"
  printf '%s.3\n' "$v" > "$d/bin/php.version"
  mkdir -p "$d/share" "$d/lib"
  printf '[PHP]\nmemory_limit = 128M\n' > "$d/share/php.ini-production"
  printf 'version=%s.3\nrecipe=5\nexts=%s\n' "$v" "$exts" > "$d/build.info"
}

mk_wp() { mkdir -p "$1/wp-includes" "$1/wp-content"; : > "$1/wp-config.php"; printf '<?php $wp_version = "6.8";\n' > "$1/wp-includes/version.php"; }
mk_xf() { mkdir -p "$1/src"; : > "$1/src/XF.php"; printf '<?php\n$config = [];\n%s\n' "${2:-}" > "$1/src/config.php"; }
mk_chev() { mkdir -p "$1/app"; printf '<?php return [];\n' > "$1/app/env.php"; }
mk_vhost() { # tree name root
  mkdir -p "$1/conf.d"
  printf 'server {\n    listen 80;\n    server_name %s.test;\n    root %s;\n}\n' "$2" "$3" > "$1/conf.d/$2.conf"
}

sandbox() { # DIR: every path of lib/php-build.sh below DIR (call in a subshell)
  local d=$1
  mkdir -p "$d/www" "$d/nginx/conf.d" "$d/units" "$d/etc"
  PHP_BUILD_ROOT=$d/root
  PHP_BUILD_ETC=$d/etc
  PHP_ACTIVE_FILE=$d/etc/setup-active
  PHP_UPGRADE_ACTIVE_MARKER=$PHP_ACTIVE_FILE
  PHP_BUILD_UNIT_DIR=$d/units
  PHP_BUILD_REBUILD_UNIT=$d/units/setup-php-build@.service
  PHP_BUILD_TOOL=$d/root/php-build.sh
  PHP_BUILD_CONF_FILE=$d/root/php-build.conf
  PHP_BUILD_COMMON_FILE=$d/root/build-common.sh
  PHP_BUILD_LIB_FILE=$d/root/php-build-lib.sh
  PHP_BUILD_TEMPLATES=$d/root/templates
  PHP_BUILD_LOG_DIR=$d/root/logs
  PHP_BUILD_TMPFILES=$d/tmpfiles/setup-php.conf
  PHP_BUILD_TMPFILES_POOLS=$d/tmpfiles/setup-php-pools.conf
  PHP_BUILD_LINK_BIN=$d/lbin
  PHP_BUILD_LINK_SBIN=$d/lsbin
  PHP_BUILD_USR_BIN=$d/usrbin
  PHP_BUILD_BACKUP_DIR=$d/backups
  PHP_BUILD_ALT_LINK=$d/alternatives/php
  PHP_BUILD_SCAN_CACHE=$d/scan-cache
  PHP_BUILD_CACHE=$d/cache
  PHP_BUILD_NGINX=$d/nginx
  PHP_BUILD_WWW=$d/www
  STUB_LOG=$d/stub.log
  ALT_LIST=$d/alt.list
}

stub_host() {
  systemctl() {
    printf 'systemctl %s\n' "$*" >> "$STUB_LOG"
    local unit=${*: -1}
    unit=${unit%.service}
    case $1 in
      is-active) [[ " ${STUB_ACTIVE:-} " == *" $unit "* ]] ;;
      is-enabled) [[ " ${STUB_ENABLED:-} " == *" $unit "* ]] ;;
      *) return 0 ;;
    esac
  }
  dpkg() {
    [[ ${1:-} == -S ]] || return 1
    if [[ " ${STUB_DPKG_OWNED:-} " == *" ${2:-} "* ]]; then printf 'php-cli: %s\n' "$2"; return 0; fi
    return 1
  }
  update-alternatives() { printf 'update-alternatives %s\n' "$*" >> "$STUB_LOG"; return 0; }
  systemd-tmpfiles() { printf 'systemd-tmpfiles %s\n' "$*" >> "$STUB_LOG"; return 0; }
  ensure_log_dirs() { :; }
  sync_php_ini_template() { printf 'sync_php_ini_template %s\n' "$*" >> "$STUB_LOG"; return 0; }
  setup_build_llvm_release() { printf 'llvm_release %s\n' "$*" >> "$STUB_LOG"; }
  setup_build_remove_shared_units_if_last() { printf 'shared_units_if_last %s\n' "$*" >> "$STUB_LOG"; }
  wait_for_cmd() { return 0; }
  web_server_state() { printf '%s' "${STUB_WEB:-nginx}"; }
  mem_total_mb() { printf '16384'; }
}

APPS=$TMP/apps
mk_wp "$APPS/wp"
mk_vhost "$TMP/t-wp" wp "$APPS/wp"

# ---------------------------------------------------------------------------
# Core modules and availability
# ---------------------------------------------------------------------------
core81=$(php_upgrade_core_modules 8.1)
core84=$(php_upgrade_core_modules 8.4)
core85=$(php_upgrade_core_modules 8.5)
check "core 8.1: OPcache is always built" line_in "$core81" opcache
check "core 8.1: no random" line_not_in "$core81" random
check "core 8.4: random" line_in "$core84" random
check "core 8.4: no lexbor" line_not_in "$core84" lexbor
check "core 8.5: lexbor and uri" bash -c 'grep -qx lexbor <<<"$1" && grep -qx uri <<<"$1"' _ "$core85"
check "core 8.5: OPcache is always built" line_in "$core85" zend_opcache
avail() { php_upgrade_extension_available "$1" "$2" "$3"; }
check "mysqlnd comes with mysqli" avail 9.8 mysqlnd $'mysqli\ncurl'
check "mysqlnd comes with pdo_mysql" avail 9.8 mysqlnd $'pdo_mysql'
check "mysqlnd is missing without either" not avail 9.8 mysqlnd $'curl'
check "Zend OPcache is always available" avail 8.4 "Zend OPcache" ""
check "an extension in the set is available" avail 9.8 gmp $'gmp\nmysqli'
check "an extension outside the set is not" not avail 9.8 gmp $'mysqli'
check "names compare case-insensitively" avail 9.8 PDO_MySQL $'pdo_mysql'

# ---------------------------------------------------------------------------
# The target's extension set is carried from the active version
# ---------------------------------------------------------------------------
CS=$TMP/carry
( sandbox "$CS"; mk_build 9.7 "ctype,gmp,soap"; php_active_set 9.7 )
cs() ( # VAR=VALUE... [X.Y] -> php_upgrade_effective_exts, then rc=N
  local kv rc=0
  sandbox "$CS"
  PHP_BUILD_NGINX=$TMP/t-wp
  while (( $# )) && [[ $1 == [A-Z]*=* ]]; do kv=$1; shift; printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
  php_upgrade_effective_exts "$@" 2>"$CS/err" || rc=$?
  printf 'rc=%s\n' "$rc"
)
out=$(cs 9.8) || true
check "upgrade: the target set has the active build's gmp" line_in "$out" gmp
check "upgrade: the target set has the active build's soap" line_in "$out" soap
check "upgrade: the target set has the detected application's set" bash -c 'grep -qx sodium <<<"$1" && grep -qx mysqli <<<"$1"' _ "$out"
check "upgrade: the set is one lower-case name per line" not has "$out" ","
check "upgrade: the status is passed through" line_in "$out" "rc=0"
plan_set=$(cs 9.8 | grep -v '^rc=' | paste -sd, -) || true
build_set=$( sandbox "$CS"; PHP_BUILD_NGINX=$TMP/t-wp; php_build_effective_exts 9.8 2>/dev/null ) || true
check "upgrade: the planned set is the build's set for the target" test "$plan_set" = "$build_set"
out=$(cs) || true
check "upgrade: without a version the active version's set" line_in "$out" gmp
out=$(cs PHP_EXT_EXTRA=intl 9.8) || true
check "upgrade: --php ext= of the run joins the target set" line_in "$out" intl
out=$(cs PHP_EXT_EXTRA=oci8 9.8) || true
check "upgrade: an unbuildable name fails the plan" line_in "$out" "rc=1"
check "upgrade: and the reason names it" file_has "$CS/err" "oci8"
dropped() ( # VAR=VALUE... -> PHP_UPGRADE_SKIPPED, one per line
  local kv
  sandbox "$CS"
  PHP_BUILD_NGINX=$TMP/t-wp
  while (( $# )) && [[ $1 == [A-Z]*=* ]]; do kv=$1; shift; printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
  PHP_UPGRADE_EXTS=$(php_upgrade_effective_exts 9.8 2>/dev/null) || true
  php_upgrade_dropped_modules 9.7 9.8
  (( ${#PHP_UPGRADE_SKIPPED[@]} )) && printf '%s\n' "${PHP_UPGRADE_SKIPPED[@]}"
  return 0
)
out=$(dropped) || true
check "upgrade: nothing the serving build loads is dropped" test -z "$out"
out=$(dropped PHP_BUILD_EXT_RESET=1) || true
check "upgrade: a trimmed set (ext=-NAME) reports gmp as dropped" has "$out" "gmp (loaded by PHP 9.7"
check "upgrade: and soap" has "$out" "soap (loaded by PHP 9.7"
check "upgrade: the remedy is named" has "$out" "--php ext=gmp"
check "upgrade: core and SAPI modules are never dropped" bash -c '! grep -qE "^(core|cgi-fcgi|date|zend_opcache|random) " <<<"$1"' _ "$out"

# ---------------------------------------------------------------------------
# Application requirements and the binding gate
# ---------------------------------------------------------------------------
A=$TMP/req
mk_wp "$A/wp-predis"
printf '<?php\n// Redis Object Cache drop-in\nuse Predis\\Client;\n$c = new Redis();\n' > "$A/wp-predis/wp-content/object-cache.php"
mk_wp "$A/wp-phpredis"
printf '<?php\n$r = new \\Redis();\n' > "$A/wp-phpredis/wp-content/object-cache.php"
mk_xf "$A/xf-redis" "\$config['cache']['provider'] = 'Redis';"
mk_xf "$A/xf-commented" "// \$config['cache']['provider'] = 'Redis';"
mk_chev "$A/chev"
req() { php_upgrade_app_required_extensions "$@" | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd, -; }
check "wordpress Predis drop-in: install mode needs no redis" lacks "$(req wordpress "$A/wp-predis" install)" redis
check "wordpress Predis drop-in: preflight never takes redis away" has "$(req wordpress "$A/wp-predis" preflight)" "igbinary,"
check "wordpress Predis drop-in: preflight is the default mode" has "$(req wordpress "$A/wp-predis")" redis
check "wordpress phpredis drop-in: install mode needs redis" has "$(req wordpress "$A/wp-phpredis" install)" redis
check "xenforo Redis provider: both modes need redis" \
  bash -c '[[ $1 == *redis* && $2 == *redis* ]]' _ "$(req xenforo "$A/xf-redis" install)" "$(req xenforo "$A/xf-redis")"
check "xenforo commented provider: no redis" lacks "$(req xenforo "$A/xf-commented")" redis
check "chevereto: redis and PDO from the table" has "$(req chevereto "$A/chev" install)" "pdo,pdo_mysql,redis"
check "an app outside the three has no table row" test -z "$(req flarum "$A/chev")"
for app in wordpress xenforo chevereto; do
  check "the table has a row for ${app}" test -n "$(php_upgrade_app_requirements "$app")"
done

W=$TMP/walk
mk_wp "$W/www/blog"
mk_xf "$W/www/forum"
mk_chev "$W/www/img/public"
mkdir -p "$W/www/static"
printf '<html></html>\n' > "$W/www/static/index.html"
out=$(php_upgrade_app_roots "$W/www") || true
check "/var/www walk: wordpress" line_in "$out" "wordpress	$W/www/blog"
check "/var/www walk: xenforo" line_in "$out" "xenforo	$W/www/forum"
check "/var/www walk: chevereto under public/" line_in "$out" "chevereto	$W/www/img/public"
check "/var/www walk: a static tree is no application" lacks "$out" "$W/www/static"
mk_vhost "$W/nginx" blog "$W/www/blog"
mkdir -p "$W/nginx/conf.d"
printf 'server {\n    listen 80;\n    return 301 https://$host$request_uri;\n}\n' > "$W/nginx/conf.d/redirect.conf"
out=$(php_upgrade_vhost_roots "$W/nginx") || true
check "vhost walk: the vhost's root is classified" test "$out" = "wordpress	$W/www/blog"

PF=$TMP/preflight
mk_xf "$PF/forum" "\$config['cache']['provider'] = 'Redis';"
gate() ( # EXTS LOADED -> blockers|not-loaded
  PHP_UPGRADE_EXTS=$1
  php_upgrade_preflight_apps 9.8 "$PF" "$2"
  printf 'B:%s\n' "${PHP_UPGRADE_BLOCKERS[@]:-}"
  printf 'N:%s\n' "${PHP_UPGRADE_NOT_LOADED[@]:-}"
)
base_exts=$'mysqli\ngd\ncurl\nmbstring\nxml\nzip\nexif\ngmp\nsodium'
out=$(gate "$base_exts" $'mysqli\nredis\nigbinary\ngd\ncurl\nmbstring\nxml\nzip\nexif') || true
check "gate: a site's loaded redis missing from the target blocks" line_in "$out" "B:xenforo|$PF/forum|redis"
check "gate: igbinary goes with it" line_in "$out" "B:xenforo|$PF/forum|igbinary"
out=$(gate "$base_exts" $'mysqli\ngd\ncurl\nmbstring\nxml\nzip\nexif') || true
check "gate: a requirement the current PHP does not load either is only noted" line_in "$out" "N:xenforo|$PF/forum|redis"
check "gate: and does not block" line_in "$out" "B:"
out=$(gate "$base_exts"$'\nredis\nigbinary' $'mysqli\nredis\nigbinary') || true
check "gate: a target set with redis passes" bash -c 'grep -qx "B:" <<<"$1" && grep -qx "N:" <<<"$1"' _ "$out"

# An app's Composer platform check sets a PHP floor (Chevereto 4.5: 8.2).
FL=$TMP/floor
mk_chev "$FL/img/public"
mkdir -p "$FL/img/public/app/vendor/composer"
printf '<?php\nif (!(PHP_VERSION_ID >= 80200)) {\n    $issues[] = "x";\n}\nif (!(PHP_VERSION_ID >= 80100)) {}\n' \
  > "$FL/img/public/app/vendor/composer/platform_check.php"
check "floor: read from app/vendor/composer/platform_check.php (highest check)" \
  test "$(php_upgrade_app_php_floor "$FL/img/public")" = 8.2
check "floor: none without a platform check" test -z "$(php_upgrade_app_php_floor "$PF/forum")"
floor_gate() ( # TARGET -> blockers
  PHP_UPGRADE_EXTS=$'pdo_mysql\npdo\nmysqli\nredis\nigbinary\ngd\ncurl\nmbstring\nexif\nfileinfo\nxmlwriter\nzip'
  php_upgrade_preflight_apps "$1" "$FL" "$PHP_UPGRADE_EXTS"
  printf 'B:%s\n' "${PHP_UPGRADE_BLOCKERS[@]:-}"
)
check "floor: a target below the app's floor blocks" line_in "$(floor_gate 8.1)" "B:chevereto|$FL/img/public|php>=8.2"
check "floor: the floor itself passes" line_in "$(floor_gate 8.2)" "B:"
check "floor: a newer target passes" line_in "$(floor_gate 8.5)" "B:"
out=$(UPGRADE_PHP=8.1 php_upgrade_describe_blocker "chevereto|/x|php>=8.2")
check "floor: the blocker message names the required PHP" has "$out" "requires PHP 8.2 or newer"
check "probe: the home page is probed (/index.php only reaches nginx's 301)" \
  bash -c 'grep -q "://\${host}/?setup_probe=" "$1" && ! grep -q "/index.php?setup_probe=\\\${RANDOM}" "$1"' _ "$ROOT/lib/php-upgrade.sh"

# ---------------------------------------------------------------------------
# Refusals: migration pending, Angie legacy, memory class
# ---------------------------------------------------------------------------
pend() ( # STATE-FILE-TEXT -> pending|clear
  MIGRATE_STATE_FILE=$(mktemp "$TMP/mstate.XXXXXX")
  printf '%s' "$1" > "$MIGRATE_STATE_FILE"
  migrate_running() { [[ ${STUB_MIGRATE_RUNNING:-0} == 1 ]]; }
  migrate_sury_active_versions() { if [[ -n ${STUB_SURY_ACTIVE:-} ]]; then printf '%s\n' "$STUB_SURY_ACTIVE"; fi; return 0; }
  migrate_pkg_list() { if [[ ${1:-} == sury && -n ${STUB_SURY_PKGS:-} ]]; then printf '%s\n' "$STUB_SURY_PKGS"; fi; return 0; }
  case ${PEND_MODE:-} in
    needed) unset -f migrate_php_pending; migrate_needed() { [[ ${1:-} == php && ${STUB_NEEDED:-1} == 0 ]]; } ;;
    state) unset -f migrate_php_pending migrate_needed ;;
    none) unset -f migrate_php_pending migrate_needed migrate_state_get ;;
  esac
  if php_upgrade_migration_pending; then echo pending; else echo clear; fi
)
check "pending: a fresh host is clear" test "$(pend "")" = clear
check "pending: a PHP switch in flight" test "$(pend $'inflight=php-9.7\n')" = pending
check "pending: the Sury purge in flight" test "$(pend $'inflight=purge\n')" = pending
check "pending: the migration unit runs" test "$(STUB_MIGRATE_RUNNING=1 pend "")" = pending
check "pending: a Sury version serving with its part not done" test "$(STUB_SURY_ACTIVE=9.7 pend "")" = pending
check "pending: a refused part of a serving Sury version" test "$(STUB_SURY_ACTIVE=9.7 pend $'php-9.7=refused:no module probe\n')" = pending
check "pending: a done part with no Sury package left is clear" test "$(pend $'php-9.7=done\n')" = clear
check "pending: a done part with Sury packages and no purge yet" test "$(STUB_SURY_PKGS=php9.7-fpm pend $'php-9.7=done\n')" = pending
check "pending: a deferred Sury purge does not block" \
  test "$(STUB_SURY_PKGS=php9.7-fpm pend $'php-9.7=done\nsury-purge=deferred:collateral\n')" = clear
check "pending: a finished Sury purge is clear" test "$(STUB_SURY_PKGS=php9.7-fpm pend $'php-9.7=done\nsury-purge=done\n')" = clear
check "pending: a blocked nginx part never locks PHP out" test "$(pend $'nginx=refused:status_zone\nphp-9.7=done\n')" = clear
check "pending: migrate_needed php is the fallback (pending)" test "$(PEND_MODE=needed STUB_NEEDED=0 pend "")" = pending
check "pending: migrate_needed php is the fallback (clear)" test "$(PEND_MODE=needed STUB_NEEDED=1 pend "")" = clear
check "pending: the fallback still honours a running unit" test "$(PEND_MODE=needed STUB_MIGRATE_RUNNING=1 pend "")" = pending
check "pending: the state-file fallback sees a switch in flight" test "$(PEND_MODE=state pend $'inflight=php-9.7\n')" = pending
check "pending: the state-file fallback is clear on a fresh host" test "$(PEND_MODE=state pend "")" = clear
check "pending: without lib/migrate.sh nothing is pending" test "$(PEND_MODE=none pend $'inflight=php-9.7\n')" = clear

refusals() ( # -> reasons, one per line
  stub_host
  SETUP_MEM_TOTAL_MB=${STUB_MEM:-16384}
  migrate_php_pending() { [[ ${STUB_PENDING:-0} == 1 ]]; }
  php_upgrade_refusals
)
check "refusals: none on a migrated nginx host" test -z "$(refusals)"
out=$(STUB_PENDING=1 refusals) || true
check "refusals: the pending PHP migration" has "$out" "the 1.22 migration of PHP is not finished; run --optimize first"
out=$(STUB_WEB=angie-legacy refusals) || true
check "refusals: an Angie-legacy web tier" has "$out" "the web tier is still Angie"
out=$(STUB_MEM=2048 refusals) || true
check "refusals: below the 4 GB class" has "$out" "below 4 GB class"
out=$(STUB_PENDING=1 STUB_WEB=angie-legacy refusals) || true
check "refusals: one line per reason" test "$(grep -c . <<<"$out")" = 2

R=$TMP/refuse
upg_refuse() (
  sandbox "$R"
  stub_host
  mk_build 9.7 ctype
  php_active_set 9.7
  migrate_php_pending() { return 0; }
  SETUP_MEM_TOTAL_MB=16384
  UPGRADE_PHP=9.8
  run_php_upgrade
)
out=$(upg_refuse 2>&1) && st=0 || st=$?
check "--upgrade-php refuses while the PHP migration is pending" test "$st" = 1
check "the refusal names the reason" has "$out" "Refusing --upgrade-php=9.8: the 1.22 migration of PHP is not finished"
check "the refusal says nothing changed" has "$out" "Nothing was changed."
check "a refused run keeps the active version" test "$(cat "$R/etc/setup-active")" = 9.7
check "a refused run builds nothing" test ! -e "$R/root/9.8"
check "a refused run stops no unit" file_lacks "$R/stub.log" "systemctl stop"
check "a refused run writes no manifest" bash -c '! compgen -G "$1/php-upgrade-*" >/dev/null' _ "$TMP/state"
vt() ( php_upgrade_validate_target "$1" 2>&1 )
out=$(vt 8.0) && st=0 || st=$?
check "--upgrade-php=8.0 is refused (older than 8.1)" bash -c '[[ $1 == 1 && $2 == *"older than 8.1"* ]]' _ "$st" "$out"
out=$(vt 8.5.1) && st=0 || st=$?
check "--upgrade-php=8.5.1 is refused (a series, not a release)" bash -c '[[ $1 == 1 && $2 == *"expects a PHP series"* ]]' _ "$st" "$out"
check "--upgrade-php=8.5RC1 is refused" not q php_upgrade_validate_target 8.5RC1
check "--upgrade-php=8.1 is accepted" q php_upgrade_validate_target 8.1
check "--upgrade-php=9.0 is accepted" q php_upgrade_validate_target 9.0

# ---------------------------------------------------------------------------
# Rollback leaves the previous version active
# ---------------------------------------------------------------------------
rb() ( # SANDBOX PHASE -> rc= marker= phase=
  local d=$1 rc=0
  sandbox "$d"
  stub_host
  [[ -d $PHP_BUILD_ROOT/9.7 ]] || { mk_build 9.7; mk_build 9.8; }
  printf '%s\n' "${RB_MARKER:-9.8}" > "$PHP_ACTIVE_FILE"
  if [[ ${RB_MARKER:-9.8} == 9.8 ]]; then php_build_links 9.8 >/dev/null 2>&1 || true; fi
  : > "$STUB_LOG"
  php_upgrade_restore_trees() { printf 'restore_trees %s\n' "$*" >> "$STUB_LOG"; }
  php_upgrade_prepare_runtime() { printf 'prepare_runtime\n' >> "$STUB_LOG"; }
  php_pool_listen() { printf '/run/php/php-fpm.sock'; }
  STUB_ACTIVE="php9.7-fpm"
  PHP_UPGRADE_OLD_VERSION=${RB_OLD-9.7}
  UPGRADE_PHP=9.8
  PHP_UPGRADE_PHASE=$2
  php_upgrade_rollback >"$d/out" 2>&1 || rc=$?
  printf 'rc=%s marker=%s phase=%s\n' "$rc" "$(cat "$PHP_ACTIVE_FILE")" "${PHP_UPGRADE_PHASE:-none}"
)
RB=$TMP/rollback
out=$(rb "$RB" handover) || true
check "rollback: succeeds" has "$out" "rc=0"
check "rollback: the previous version is the active one again" has "$out" "marker=9.7"
check "rollback: the phase is cleared" has "$out" "phase=none"
check "rollback: the target is stopped" file_has "$RB/stub.log" "systemctl stop php9.8-fpm"
check "rollback: the target is disabled" file_has "$RB/stub.log" "systemctl disable php9.8-fpm"
check "rollback: the previous unit is enabled" file_has "$RB/stub.log" "systemctl enable php9.7-fpm"
check "rollback: the previous unit is restarted" file_has "$RB/stub.log" "systemctl restart php9.7-fpm"
check "rollback: the target stops before the previous version restarts" \
  bash -c '(( $1 > 0 && $1 < $2 ))' _ "$(line_no "$RB/stub.log" "stop php9.8-fpm")" "$(line_no "$RB/stub.log" "restart php9.7-fpm")"
check "rollback: the generated tree is put aside" file_has "$RB/stub.log" "restore_trees 9.8"
check "rollback: /run/php is prepared before the restart" \
  bash -c '(( $1 > 0 && $1 < $2 ))' _ "$(line_no "$RB/stub.log" "prepare_runtime")" "$(line_no "$RB/stub.log" "restart php9.7-fpm")"
check "rollback: /usr/local/bin/php points at the previous CLI" link_to "$RB/lbin/php" "$RB/root/9.7/bin/php"
check "rollback: the previous version is never disabled" file_lacks "$RB/stub.log" "disable php9.7-fpm"
check "rollback: reports the previous version active" file_has "$RB/out" "PHP 9.7 is active again"
RB2=$TMP/rollback-prepare
out=$(RB_MARKER=9.7 rb "$RB2" prepare) || true
check "prepare-phase rollback: succeeds" has "$out" "rc=0"
check "prepare-phase rollback: the serving version stays active" has "$out" "marker=9.7"
check "prepare-phase rollback: the generated tree is put aside" file_has "$RB2/stub.log" "restore_trees 9.8"
check "prepare-phase rollback: no unit is stopped or restarted" file_lacks "$RB2/stub.log" "systemctl"
out=$(RB_OLD="" rb "$TMP/rollback-none" handover) || true
check "rollback without a previous version fails" has "$out" "rc=1"

# ---------------------------------------------------------------------------
# After the commit: the old unit is disabled, one unit serves
# ---------------------------------------------------------------------------
su() ( # SANDBOX -> rc=, output in SANDBOX/out
  local d=$1 rc=0
  sandbox "$d"
  stub_host
  mk_build 9.7
  mk_build 9.8
  php_build_unit_text 9.8 > "$PHP_BUILD_UNIT_DIR/php9.8-fpm.service"
  if [[ ${SU_FOREIGN:-0} == 1 ]]; then
    printf '[Service]\nExecStart=/usr/sbin/php-fpm9.7 --nodaemonize\n' > "$PHP_BUILD_UNIT_DIR/php9.7-fpm.service"
  else
    php_build_unit_text 9.7 > "$PHP_BUILD_UNIT_DIR/php9.7-fpm.service"
  fi
  php_upgrade_single_unit 9.8 >"$d/out" 2>&1 || rc=$?
  printf 'rc=%s\n' "$rc"
)
SU=$TMP/single
out=$(STUB_ENABLED="php9.7-fpm php9.8-fpm" STUB_ACTIVE="php9.8-fpm" su "$SU") || true
check "commit: an enabled, stopped previous unit of ours is disabled" file_has "$SU/stub.log" "systemctl disable php9.7-fpm"
check "commit: disabled, never masked" file_lacks "$SU/stub.log" "mask"
check "commit: one serving unit passes" has "$out" "rc=0"
check "commit: the disable is reported" file_has "$SU/out" "Disabled php9.7-fpm"
SU2=$TMP/single-foreign
out=$(SU_FOREIGN=1 STUB_ENABLED="php9.7-fpm php9.8-fpm" STUB_ACTIVE="php9.8-fpm" su "$SU2") || true
check "commit: a package unit is never disabled" file_lacks "$SU2/stub.log" "disable php9.7-fpm"
check "commit: a package unit enabled beside the target fails the check" has "$out" "rc=1"
check "commit: and names the remedy" file_has "$SU2/out" "systemctl disable php9.7-fpm"
SU3=$TMP/single-running
out=$(STUB_ENABLED="php9.7-fpm php9.8-fpm" STUB_ACTIVE="php9.7-fpm php9.8-fpm" su "$SU3") || true
check "commit: a still running previous unit fails the check" has "$out" "rc=1"
check "commit: a running unit is not disabled under it" file_lacks "$SU3/stub.log" "disable php9.7-fpm"
check "commit: the running unit is reported" file_has "$SU3/out" "php9.7-fpm is still running beside PHP 9.8"
SU4=$TMP/single-target
out=$(STUB_ENABLED="" STUB_ACTIVE="php9.8-fpm" su "$SU4") || true
check "commit: a target that is not enabled fails the check" has "$out" "rc=1"
check "commit: and says it would not start at boot" file_has "$SU4/out" "php9.8-fpm is not enabled"

bs_report() { printf 'report %s\n' "$*" >> "$STUB_LOG"; }
bs() ( # SANDBOX VER -> rc=
  local d=$1 rc=0
  sandbox "$d"
  stub_host
  mk_build 9.7
  mk_build 9.8
  php_active_set 9.8
  php_build_unit_text 9.7 > "$PHP_BUILD_UNIT_DIR/php9.7-fpm.service"
  php_build_unit_text 9.8 > "$PHP_BUILD_UNIT_DIR/php9.8-fpm.service"
  STUB_ENABLED="php9.7-fpm php9.8-fpm"
  STUB_ACTIVE="php9.8-fpm"
  PHP_BUILD_CHANGED=0
  php_build_start "$2" bs_report >/dev/null 2>&1 || rc=$?
  printf 'rc=%s\n' "$rc"
)
BS=$TMP/start
out=$(bs "$BS" 9.8) || true
check "php_build_start: succeeds for the active version" has "$out" "rc=0"
check "php_build_start: every other version of ours is disabled --now" file_has "$BS/stub.log" "systemctl disable --now php9.7-fpm"
check "php_build_start: the kept version is reported for --upgrade-php" file_has "$BS/stub.log" "kept for --upgrade-php=9.7"
check "php_build_start: the active version is enabled" file_has "$BS/stub.log" "systemctl enable php9.8-fpm"
check "php_build_start: an unchanged running build is not restarted" file_lacks "$BS/stub.log" "restart php9.8-fpm"
BS2=$TMP/start-inactive
out=$(bs "$BS2" 9.7) || true
check "php_build_start: an inactive version is never enabled" file_lacks "$BS2/stub.log" "systemctl enable php9.7-fpm"
check "php_build_start: an inactive version is never started" file_lacks "$BS2/stub.log" "systemctl start php9.7-fpm"

ret() ( # SANDBOX -> stub log lines
  local d=$1
  sandbox "$d"
  stub_host
  mk_build 9.5
  mk_build 9.7
  mk_build 9.8
  php_active_set 9.8
  php_build_purge() { printf 'purge %s\n' "$*" >> "$STUB_LOG"; }
  PHP_UPGRADE_MANIFEST_DIR=$d/manifest
  php_upgrade_retire_older 9.8 9.7 >/dev/null 2>&1
)
RT=$TMP/retire
ret "$RT" || true
check "retire: a build older than the kept one is retired" file_has "$RT/stub.log" "purge 9.5"
check "retire: the kept rollback build stays" file_lacks "$RT/stub.log" "purge 9.7"
check "retire: the new build stays" file_lacks "$RT/stub.log" "purge 9.8"
RT2=$TMP/retire-enabled
STUB_ENABLED="php9.5-fpm" ret "$RT2" || true
check "retire: an enabled older unit is never retired" file_lacks "$RT2/stub.log" "purge 9.5"

# The commit order inside run_php_upgrade: verify (and its rollback) first,
# then enable the target, then disable (never mask) the previous version.
RUN_SRC=$TMP/run_php_upgrade.txt
sed -n '/^run_php_upgrade()/,/^}/p' "$ROOT/lib/php-upgrade.sh" > "$RUN_SRC"
ln_verify=$(line_no "$RUN_SRC" 'php_upgrade_verify "$target"')
ln_hard=$(line_no "$RUN_SRC" 'if (( PHP_UPGRADE_VERIFY_HARD )); then')
ln_enable=$(line_no "$RUN_SRC" 'systemctl enable "php${target}-fpm"')
ln_disable=$(line_no "$RUN_SRC" 'systemctl disable "php${cur}-fpm"')
ln_retire=$(line_no "$RUN_SRC" 'php_upgrade_retire_older "$target" "$cur"')
check "run_php_upgrade: verify, then the rollback decision" bash -c '(( $1 > 0 && $1 < $2 ))' _ "$ln_verify" "$ln_hard"
check "run_php_upgrade: the target is enabled only after the rollback decision" bash -c '(( $1 > 0 && $1 < $2 ))' _ "$ln_hard" "$ln_enable"
check "run_php_upgrade: the previous version is disabled after the target is enabled" bash -c '(( $1 > 0 && $1 < $2 ))' _ "$ln_enable" "$ln_disable"
check "run_php_upgrade: older builds are retired after the commit" bash -c '(( $1 > 0 && $1 < $2 ))' _ "$ln_disable" "$ln_retire"
check "run_php_upgrade: never masks a unit" not file_has "$RUN_SRC" "systemctl mask"
check "run_php_upgrade: the refusals come before any build" \
  bash -c '(( $1 > 0 && $1 < $2 ))' _ "$(line_no "$RUN_SRC" 'mapfile -t refusals < <(php_upgrade_refusals)')" "$(line_no "$RUN_SRC" 'php_build_ensure "$target" build-only upgrade info')"

# php_upgrade_set_active: marker and links through B's php_build_links.
SA=$TMP/set-active
sa() ( sandbox "$SA"; stub_host; mk_build 9.7; mk_build 9.8; php_upgrade_set_active "$1" >/dev/null 2>&1 )
sa 9.8 || true
check "set_active: writes the marker" test "$(cat "$SA/etc/setup-active")" = 9.8
check "set_active: points /usr/local/bin/php at the new CLI" link_to "$SA/lbin/php" "$SA/root/9.8/bin/php"
sa 9.7 || true
check "set_active: switching back re-points the link" link_to "$SA/lbin/php" "$SA/root/9.7/bin/php"
check "set_active: /usr/bin/php follows when dpkg does not own it" link_to "$SA/usrbin/php" "$SA/root/9.7/bin/php"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
