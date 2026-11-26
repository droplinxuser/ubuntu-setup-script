#!/usr/bin/env bash
# Unit tests for the 1.22.0 PHP source build: lib/php-build.sh and the pure
# parts of tools/php-build.sh.
#   - per-app extension sets (wordpress, xenforo, chevereto, generic PHP),
#     add-only detection, the union guard against
#     php_upgrade_app_required_extensions, --php ext= (names, -NAME, none),
#     PHP_EXT_EXTRA persistence, SQLite and XenForo Redis detection on
#     fixture roots;
#   - the tool's per-SAPI verify lists (pcntl CLI-only, cgi-fcgi FPM-only),
#     OPcache before and from 8.5, the version policy (released only, never
#     an RC) and `check` reporting a changed set as stale;
#   - php_build_layout (php-fpm.conf, the managed php.ini, www.conf from the
#     master template, conf.d with only our files, Sury entries moved or
#     commented under the marker), php_fpm_test's arguments (a stub binary
#     records argv and PHP_INI_SCAN_DIR), the unit and tmpfiles text,
#     per-pool-user session directories and the link rules.
# No root, no services and no system changes are required: every path of
# lib/php-build.sh points below a scratch directory in /tmp, systemctl, dpkg,
# update-alternatives and systemd-tmpfiles are shell functions that record
# their arguments, and the PHP binaries are small fake scripts.
# Usage: bash tests/unit/t-php-build.sh
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
TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-test-php-build.XXXXXX")
# The tests do not remove TMP: a failed run stays inspectable and /tmp
# expires it.

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
export SETUP_TUNING_FILE="$TMP/setup-tuning"
export SETUP_MIGRATE_STATE_FILE="$TMP/state/migrate-1.22"
# Every path lib/php-build.sh reads at source time, below TMP.
export PHP_BUILD_ROOT="$TMP/root" PHP_BUILD_CACHE="$TMP/cache" PHP_BUILD_UNIT_DIR="$TMP/units" \
  PHP_BUILD_ETC="$TMP/etc/php" PHP_BUILD_TMPFILES="$TMP/tmpfiles/setup-php.conf" \
  PHP_BUILD_TMPFILES_POOLS="$TMP/tmpfiles/setup-php-pools.conf" \
  PHP_BUILD_LINK_BIN="$TMP/usr/local/bin" PHP_BUILD_LINK_SBIN="$TMP/usr/local/sbin" \
  PHP_BUILD_USR_BIN="$TMP/usr/bin" PHP_BUILD_BACKUP_DIR="$TMP/backups" \
  PHP_BUILD_ALT_LINK="$TMP/alternatives/php" PHP_BUILD_SCAN_CACHE="$TMP/scan-cache" \
  PHP_BUILD_NGINX="$TMP/nginx-empty" PHP_BUILD_WWW="$TMP/www-empty" PHP_BUILD_ANGIE_ETC="$TMP/angie"
# Set and empty: no extra web tree (the host's /etc/angie never counts).
export PHP_BUILD_EXTRA_WEB_TREES=""
# A stale operator export must not change what the sourced helpers see.
unset PHP_EXT_EXTRA PHP_BUILD_EXT_RESET PHP_BUILD_APPS PHP_EXT_DETECT_TREE PHP_BUILD_DETECT_ROOTS \
  SETUP_PHP_ALLOW_MISSING_EXT SETUP_MEM_TOTAL_MB PHP_INI_SCAN_DIR FAKE_LOG
mkdir -p "$TMP/state" "$TMP/nginx-empty/conf.d" "$TMP/www-empty"
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
# setup.sh installs an ERR trap for production diagnostics; these tests
# exercise failure paths on purpose.
trap - ERR
# lib/php-upgrade.sh hard-codes the marker; nothing here may touch /etc/php.
PHP_UPGRADE_ACTIVE_MARKER=$PHP_ACTIVE_FILE

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-php-build.sh,title=PHP build test failed::%s\n' "$*"
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
csv_has() { [[ ,$1, == *,"$2",* ]]; }
csv_lacks() { [[ ,$1, != *,"$2",* ]]; }
csv_has_all() { local s=$1 n; shift; for n in "$@"; do csv_has "$s" "$n" || return 1; done; }
csv_lacks_all() { local s=$1 n; shift; for n in "$@"; do csv_lacks "$s" "$n" || return 1; done; }
csv_sorted() { [[ -n $1 && $1 == "$(tr ',' '\n' <<<"$1" | sort -u | paste -sd, -)" ]]; }
file_has() { [[ -f $1 ]] && grep -qF -- "$2" "$1"; }
file_lacks() { [[ ! -f $1 ]] || ! grep -qF -- "$2" "$1"; }
file_line() { [[ -f $1 ]] && grep -qxF -- "$2" "$1"; }
first_line_has() { [[ -f $1 ]] && [[ $(head -n 1 "$1") == *"$2"* ]]; }
link_to() { [[ -L $1 && $(readlink "$1") == "$2" ]]; }
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# A fake php / php-fpm: answers -v (FILE.version), -m (FILE.mods; "opcache"
# is printed as "Zend OPcache" under [Zend Modules], FILE.warn is printed
# first), -i (Debian's compiled-in defaults), -t (fails when FILE.tfail
# exists) and a phar run.  With FAKE_LOG set every call appends
# "path|scan=PHP_INI_SCAN_DIR|argv".
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
  *" -i "*)
    printf 'include_path => .:/usr/share/php => .:/usr/share/php\n'
    printf 'mysqli.default_socket => /run/mysqld/mysqld.sock => /run/mysqld/mysqld.sock\n'
    printf 'pdo_mysql.default_socket => /run/mysqld/mysqld.sock => /run/mysqld/mysqld.sock\n'
    exit 0 ;;
esac
case $args in *.phar*) printf 'phar-ok' ;; esac
exit 0
EOF
  chmod 755 "$f"
  if (( $# )); then printf '%s\n' "$@" > "$f.mods"; else : > "$f.mods"; fi
}

# A fake 1.22 build of VER under PHP_BUILD_ROOT: both binaries, build.info
# with EXTS, php.ini-production and, before 8.5, the shared opcache.so.
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
  printf '[PHP]\nmemory_limit = 128M\nsession.gc_probability = 1\nsession.gc_divisor = 1000\n' > "$d/share/php.ini-production"
  printf 'version=%s.3\nrecipe=5\nexts=%s\n' "$v" "$exts" > "$d/build.info"
  if ! _pb_ver_ge "$v" 8.5; then : > "$d/lib/opcache.so"; fi
}

mk_wp() { mkdir -p "$1/wp-includes" "$1/wp-content"; : > "$1/wp-config.php"; printf '<?php $wp_version = "6.8";\n' > "$1/wp-includes/version.php"; }
mk_xf() { mkdir -p "$1/src"; : > "$1/src/XF.php"; printf '<?php\n$config = [];\n%s\n' "${2:-}" > "$1/src/config.php"; }
mk_chev() { mkdir -p "$1/app"; printf '<?php return [];\n' > "$1/app/env.php"; }
mk_generic() { mkdir -p "$1"; printf '<?php echo "hello";\n' > "$1/index.php"; }
mk_vhost() { # tree name root
  mkdir -p "$1/conf.d"
  printf 'server {\n    listen 80;\n    server_name %s.test;\n    root %s;\n}\n' "$2" "$3" > "$1/conf.d/$2.conf"
}

# Point every path of lib/php-build.sh below DIR.  Call inside a subshell.
sandbox() { # DIR
  local d=$1
  mkdir -p "$d/www" "$d/nginx/conf.d" "$d/etc"
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

# Host commands as recording functions.  STUB_ACTIVE / STUB_ENABLED list the
# units (without .service) systemctl reports as active / enabled;
# STUB_DPKG_OWNED lists the paths dpkg -S claims; ALT_LIST is the "php"
# alternatives group (one path per line; removing the last entry deletes the
# group link, as update-alternatives does).
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
  update-alternatives() {
    printf 'update-alternatives %s\n' "$*" >> "$STUB_LOG"
    case $1 in
      --list) [[ -s $ALT_LIST ]] && cat "$ALT_LIST" ;;
      --remove)
        { grep -vxF -- "$3" "$ALT_LIST" || true; } > "$ALT_LIST.new"
        mv -f "$ALT_LIST.new" "$ALT_LIST"
        [[ -s $ALT_LIST ]] || rm -f "$PHP_BUILD_ALT_LINK" ;;
    esac
    return 0
  }
  systemd-tmpfiles() { printf 'systemd-tmpfiles %s\n' "$*" >> "$STUB_LOG"; return 0; }
  ensure_log_dirs() { :; }
  sync_php_ini_template() { printf 'sync_php_ini_template %s\n' "$*" >> "$STUB_LOG"; return 0; }
  setup_build_llvm_release() { printf 'llvm_release %s\n' "$*" >> "$STUB_LOG"; }
  setup_build_remove_shared_units_if_last() { printf 'shared_units_if_last %s\n' "$*" >> "$STUB_LOG"; }
}

# The effective set with VAR=VALUE assignments first, then the arguments of
# php_build_effective_exts.  stdout only.
effp() (
  local kv
  while (( $# )) && [[ $1 == [A-Z]*=* ]]; do
    kv=$1
    shift
    printf -v "${kv%%=*}" '%s' "${kv#*=}"
  done
  php_build_effective_exts "$@" 2>/dev/null
)

APPS=$TMP/apps
mk_wp "$APPS/wp"
mk_xf "$APPS/xf"
mk_xf "$APPS/xf-redis" "\$config['cache']['provider'] = 'Redis';"
mk_chev "$APPS/chev"
mk_generic "$APPS/generic"
mk_vhost "$TMP/t-wp" wp "$APPS/wp"
mk_vhost "$TMP/t-xf" xf "$APPS/xf"
mk_vhost "$TMP/t-xf-redis" xfr "$APPS/xf-redis"
mk_vhost "$TMP/t-chev" chev "$APPS/chev"
mk_vhost "$TMP/t-generic" generic "$APPS/generic"
mkdir -p "$TMP/t-none/conf.d"
NOROOT=$TMP/root-none

# ---------------------------------------------------------------------------
# The requirement tables
# ---------------------------------------------------------------------------
table_probe() ( # APP: the fallback table (php-upgrade.sh not loaded) vs the single table
  local a b
  a=$(php_upgrade_app_requirements "$1" | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd, -)
  unset -f php_upgrade_app_requirements
  b=$(php_build_app_exts "$1" | sort -u | paste -sd, -)
  [[ -n $a && $a == "$b" ]]
)
for app in wordpress xenforo chevereto; do
  check "the standalone table of ${app} matches php_upgrade_app_requirements" table_probe "$app"
done
all_buildable() {
  local n
  for n in "${PHP_BASE_EXTS[@]}" "${PHP_GENERIC_EXTS[@]}" $(php_build_app_exts wordpress) \
           $(php_build_app_exts xenforo) $(php_build_app_exts chevereto) gmp redis igbinary; do
    php_build_ext_buildable "$n" || return 1
  done
}
check "every base, generic and app extension is buildable" all_buildable
check "the base set carries the CLI tools' extensions" \
  csv_has_all "$(printf '%s,' "${PHP_BASE_EXTS[@]}")" opcache pcntl phar posix tokenizer session
check "the generic set has no intl (ICU only by --php ext=intl)" \
  csv_lacks "$(printf '%s,' "${PHP_GENERIC_EXTS[@]}")" intl
check "the core modules are not buildable names" not php_build_ext_buildable core
check "php_build_ext_buildable is case-insensitive" php_build_ext_buildable GMP
check "an unknown extension is not buildable" not php_build_ext_buildable oci8

# ---------------------------------------------------------------------------
# Effective sets per application
# ---------------------------------------------------------------------------
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-wp") || true
check "wordpress: its table, base and dependencies are in the set" \
  csv_has_all "$out" mysqli gd curl mbstring exif zip xml sodium mysqlnd libxml opcache pcntl phar
check "wordpress: no pdo_mysql, redis, sqlite or intl without a reason" \
  csv_lacks_all "$out" pdo_mysql redis igbinary sqlite3 pdo_sqlite intl gmp
check "wordpress: the core modules are never listed" csv_lacks_all "$out" core date standard spl random cgi-fcgi
check "the set is a sorted comma list without duplicates" csv_sorted "$out"
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-xf") || true
check "xenforo: mysqli, xml, zip and exif" csv_has_all "$out" mysqli xml zip exif gd curl mbstring
check "xenforo: no sodium, redis or pdo_mysql without a reason" csv_lacks_all "$out" sodium redis igbinary pdo_mysql
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-xf-redis") || true
check "xenforo with the Redis cache provider: redis and igbinary" csv_has_all "$out" redis igbinary mysqli
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-chev") || true
check "chevereto: PDO, mysqli, redis, igbinary, xmlwriter, fileinfo, zip" \
  csv_has_all "$out" pdo_mysql pdo mysqli mysqlnd redis igbinary xmlwriter fileinfo zip exif
check "chevereto: no sodium" csv_lacks "$out" sodium
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-generic") || true
check "a generic PHP root gets the generic set" csv_has_all "$out" mysqli pdo_mysql pdo tokenizer bcmath sqlite3 pdo_sqlite xml xmlwriter zip
check "the generic set leaves out intl and redis" csv_lacks_all "$out" intl redis
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none") || true
check "a bare --php host gets the union of the three applications" csv_has_all "$out" sodium redis igbinary pdo_mysql mysqli zip xmlwriter
check "the bare union adds no SQLite or intl" csv_lacks_all "$out" sqlite3 intl
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_EXT_EXTRA=intl) || true
check "PHP_EXT_EXTRA alone: intl in the set" csv_has "$out" intl
check "PHP_EXT_EXTRA alone: no application union" csv_lacks_all "$out" sodium redis pdo_mysql
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_BUILD_APPS=xf) || true
check "--domain app=xf adds the xenforo set" csv_has_all "$out" mysqli xml zip exif
check "--domain app=xf adds nothing of the other applications" csv_lacks_all "$out" sodium redis
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_BUILD_APPS=shlink) || true
check "--domain app=shlink adds gmp to the generic set" csv_has_all "$out" gmp sqlite3 bcmath
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_BUILD_APPS=flarum) || true
check "--domain app=flarum gets the generic set" csv_has_all "$out" pdo_mysql sqlite3 tokenizer
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_BUILD_WWW="$APPS") || true
check "the /var/www walk finds the applications too" csv_has_all "$out" sodium redis pdo_mysql
eff_err() ( PHP_BUILD_ROOT=$NOROOT; PHP_BUILD_NGINX=$TMP/t-wp; PHP_EXT_EXTRA=$1; { php_build_effective_exts >/dev/null; } 2>&1 )
out=$(eff_err oci8) && st=0 || st=$?
check "an unbuildable PHP_EXT_EXTRA name fails the set" test "$st" = 1
check "the failure names the extension" has "$out" "no source build path for: oci8"
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-wp" PHP_EXT_EXTRA=oci8 SETUP_PHP_ALLOW_MISSING_EXT=1) || true
check "SETUP_PHP_ALLOW_MISSING_EXT=1 drops the unbuildable name" csv_lacks "$out" oci8
check "SETUP_PHP_ALLOW_MISSING_EXT=1 keeps the rest of the set" csv_has "$out" mysqli
# Series ceilings of PECL extensions (1.22.3): redis 6.3.0 builds up to 8.5.
check "series ceiling: redis is buildable for PHP 8.5" php_build_ext_buildable_for 8.5 redis
check "series ceiling: redis is not buildable for PHP 8.6" not php_build_ext_buildable_for 8.6 redis
check "series ceiling: an extension without a ceiling builds on 8.6" php_build_ext_buildable_for 8.6 igbinary
check "series ceiling: no version means no ceiling" php_build_ext_buildable_for "" redis
out=$( ( PHP_BUILD_ROOT=$NOROOT; PHP_BUILD_NGINX=$TMP/t-none; PHP_BUILD_APPS=chevereto; php_build_effective_exts 8.6 >/dev/null ) 2>&1 ) && st=0 || st=$?
check "series ceiling: Chevereto on PHP 8.6 fails the set (it needs redis)" test "$st" = 1
check "series ceiling: the failure names the ceiling" has "$out" "redis builds up to PHP 8.5"
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-none" PHP_BUILD_APPS=chevereto 8.5) || true
check "series ceiling: Chevereto on PHP 8.5 keeps redis" csv_has "$out" redis
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-wp" PHP_EXT_EXTRA=redis 8.6) && st=0 || st=$?
check "series ceiling: redis kept only by PHP_EXT_EXTRA is left out on 8.6, the set still resolves" test "$st" = 0
check "series ceiling: ... and redis is not in it" csv_lacks "$out" redis
check "series ceiling: ... the rest of the set stays" csv_has "$out" mysqli
# Purging our build takes the migration's CLI diversion back (1.22.3).
undivert_case() ( # with-sury-copy(yes|no) -> "link-gone renamed-back calls"
  d=$(mktemp -d "$TMP/udv.XXXXXX"); PHP_BUILD_USR_BIN=$d; PHP_BUILD_ROOT=$d/root
  mkdir -p "$PHP_BUILD_ROOT/8.5/bin"; : > "$PHP_BUILD_ROOT/8.5/bin/php"
  ln -s "$PHP_BUILD_ROOT/8.5/bin/php" "$d/php8.5"
  [[ $1 == yes ]] && printf 'sury\n' > "$d/php8.5.sury"
  dpkg-divert() {
    printf '%s\n' "$*" >> "$d/calls"
    case " $* " in
      *" --list "*) printf 'local diversion of %s to %s.sury\n' "$d/php8.5" "$d/php8.5" ;;
      *" --remove "*) [[ -e $d/php8.5.sury ]] && mv "$d/php8.5.sury" "$d/php8.5"; return 0 ;;
    esac
  }
  _pb_undivert_cli 8.5
  printf '%s %s %s' "$([[ -L $d/php8.5 ]] && echo link || echo nolink)" \
    "$(cat "$d/php8.5" 2>/dev/null || echo none)" "$(grep -c -- '--remove' "$d/calls")"
)
check "purge: our link goes and Sury's diverted CLI is renamed back" test "$(undivert_case yes)" = "nolink sury 1"
check "purge: without a Sury copy the diversion record still goes" test "$(undivert_case no)" = "nolink none 1"
check "purge: php_build_purge takes the diversion back before unlinking /usr/bin/phpX.Y" \
  bash -c 'sed -n "/^php_build_purge()/,/^}/p" "$1" | grep -B1 "_pb_unlink_ours \"\${PHP_BUILD_USR_BIN}/php\${v}\"" | grep -q "_pb_undivert_cli"' _ "$ROOT/lib/php-build.sh"

# ---------------------------------------------------------------------------
# Add-only detection (R11)
# ---------------------------------------------------------------------------
ADD=$TMP/add
( sandbox "$ADD"; mk_build 8.4 ctype,gmp,soap; php_active_set 8.4; mk_build 8.3 ctype,shmop )
add_eff() { effp PHP_BUILD_ROOT="$ADD/root" PHP_ACTIVE_FILE="$ADD/etc/setup-active" PHP_BUILD_NGINX="$TMP/t-wp" "$@"; }
out=$(add_eff 8.4) || true
check "add-only: the current build's gmp and soap stay in the set" csv_has_all "$out" gmp soap
check "add-only: soap pulls libxml" csv_has "$out" libxml
check "add-only: the detected application is still added" csv_has_all "$out" sodium mysqli
out=$(add_eff PHP_BUILD_EXT_RESET=1 8.4) || true
check "PHP_BUILD_EXT_RESET=1 lets the set shrink to what is detected" csv_lacks_all "$out" gmp soap
check "PHP_BUILD_EXT_RESET=1 keeps the detected application" csv_has "$out" sodium
out=$(add_eff 8.5) || true
check "a new series carries the active build's set" csv_has_all "$out" gmp soap
out=$(add_eff 8.3) || true
check "a kept older series keeps its own set" csv_has "$out" shmop
check "a kept older series also gets the active build's set" csv_has_all "$out" gmp soap
out=$(add_eff) || true
check "without a version the active version's record counts" csv_has "$out" gmp
printf 'calendar\n' > "$ADD/root/8.4/exts.want"
out=$(add_eff 8.4) || true
check "exts.want is the current record when present" csv_has "$out" calendar
check "exts.want replaces build.info as the record" csv_lacks_all "$out" gmp soap
rm -f "$ADD/root/8.4/exts.want"

# An uncertain SQLite scan (status 2, timeout or unreadable) keeps what the
# current build has, and reports it.
mk_wp "$APPS/wp-uncertain"
mk_vhost "$TMP/t-wp-uncertain" wpu "$APPS/wp-uncertain"
printf '%s\t2\t%s\n' "$(date +%s)" "$APPS/wp-uncertain" > "$TMP/scan-uncertain"
( sandbox "$TMP/unc-a"; mk_build 8.4 ctype,sqlite3,pdo_sqlite; php_active_set 8.4 )
( sandbox "$TMP/unc-b"; mk_build 8.4 ctype; php_active_set 8.4 )
unc() ( # SANDBOX -> set, then the stderr
  PHP_BUILD_ROOT=$1/root; PHP_ACTIVE_FILE=$1/etc/setup-active
  PHP_BUILD_NGINX=$TMP/t-wp-uncertain; PHP_BUILD_SCAN_CACHE=$TMP/scan-uncertain
  php_build_effective_exts 8.4 2>"$1/err"
)
out=$(unc "$TMP/unc-a") || true
check "an uncertain SQLite scan keeps the current build's sqlite3/pdo_sqlite" csv_has_all "$out" sqlite3 pdo_sqlite
check "an uncertain SQLite scan is reported" file_has "$TMP/unc-a/err" "SQLite scan of $APPS/wp-uncertain"
out=$(unc "$TMP/unc-b") || true
check "an uncertain SQLite scan adds nothing the build did not have" csv_lacks "$out" sqlite3

# ---------------------------------------------------------------------------
# Union guard (R8): the set must hold php_upgrade_app_required_extensions
# ---------------------------------------------------------------------------
mk_wp "$APPS/wp-redis"
printf '<?php\n$r = new Redis();\n$r->connect("127.0.0.1");\n' > "$APPS/wp-redis/wp-content/object-cache.php"
mk_vhost "$TMP/t-wp-redis" wpr "$APPS/wp-redis"
reqmiss() ( PHP_BUILD_ROOT=$NOROOT; PHP_BUILD_NGINX=$1; php_build_requirements_missing "$2" )
union_ok() { # TREE APP ROOT: every install-mode requirement is in the effective set
  local s n
  s=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$1") || return 1
  for n in $(php_upgrade_app_required_extensions "$2" "$3" install); do
    csv_has "$s" "${n,,}" || return 1
  done
}
check "union guard: wordpress requirements are in its set" union_ok "$TMP/t-wp" wordpress "$APPS/wp"
check "union guard: wordpress with a phpredis drop-in" union_ok "$TMP/t-wp-redis" wordpress "$APPS/wp-redis"
check "union guard: xenforo requirements are in its set" union_ok "$TMP/t-xf" xenforo "$APPS/xf"
check "union guard: xenforo with Redis" union_ok "$TMP/t-xf-redis" xenforo "$APPS/xf-redis"
check "union guard: chevereto requirements are in its set" union_ok "$TMP/t-chev" chevereto "$APPS/chev"
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-wp-redis") || true
check "a phpredis object-cache drop-in adds redis and igbinary" csv_has_all "$out" redis igbinary
check "the build guard passes the computed set" reqmiss "$TMP/t-wp-redis" "$out"
lean=$(tr ',' '\n' <<<"$out" | grep -vxE 'redis|igbinary' | paste -sd, -) || true
out=$(reqmiss "$TMP/t-wp-redis" "$lean") && st=0 || st=$?
check "the build guard refuses a set without the drop-in's redis" test "$st" = 1
check "the refusal names app, root and extension" has "$out" "wordpress|$APPS/wp-redis|redis"
allow_waive() ( SETUP_PHP_ALLOW_MISSING_EXT=1; reqmiss "$TMP/t-wp-redis" "$lean" >/dev/null )
check "SETUP_PHP_ALLOW_MISSING_EXT=1 waives the build guard" allow_waive

# ---------------------------------------------------------------------------
# --php ext= (php_build_ext_option) and PHP_EXT_EXTRA persistence
# ---------------------------------------------------------------------------
extopt() ( # TUNING-FILE START LIST -> rc=, extra=, reset=, exported=
  SETUP_TUNING_FILE=$1
  PHP_EXT_EXTRA=$2
  unset PHP_BUILD_EXT_RESET
  local rc=0
  php_build_ext_option "$3" 2>/dev/null || rc=$?
  printf 'rc=%s extra=%s reset=%s exported=%s\n' "$rc" "$PHP_EXT_EXTRA" "${PHP_BUILD_EXT_RESET:-unset}" \
    "$(bash -c 'printf %s "${PHP_EXT_EXTRA-unset}"')"
)
tf=$TMP/tuning-ext
out=$(extopt "$tf" "" "intl,GMP") || true
check "ext=intl,GMP adds both, sorted and lower-case" has "$out" "rc=0 extra=gmp,intl "
check "adding names does not allow the set to shrink" has "$out" "reset=unset"
check "PHP_EXT_EXTRA is exported to the build tool" has "$out" "exported=gmp,intl"
# The file is written shell-quoted (%q; bash escapes the comma) and sourced
# by the host: compare the value it yields.
# shellcheck disable=SC1090
tuning_value() ( unset "$2"; source "$1"; printf "%s" "${!2-unset}" ) # FILE KEY
check "PHP_EXT_EXTRA is persisted in the tuning file" test "$(tuning_value "$tf" PHP_EXT_EXTRA)" = "gmp,intl"
out=$(extopt "$tf" "gmp,intl" "-intl") || true
check "ext=-intl drops one name" has "$out" "rc=0 extra=gmp "
check "ext=-NAME allows the next build to shrink" has "$out" "reset=1"
check "the tuning file is rewritten, not appended" test "$(grep -c '^PHP_EXT_EXTRA=' "$tf")" = 1
check "the tuning file holds the trimmed list" file_line "$tf" "PHP_EXT_EXTRA=gmp"
out=$(extopt "$tf" "gmp,intl" "soap,-gmp") || true
check "names and -NAME combine in one list" has "$out" "extra=intl,soap "
out=$(extopt "$tf" "gmp,intl" "none") || true
check "ext=none clears the list" has "$out" "rc=0 extra= reset=1"
check "ext=none persists an empty list" file_line "$tf" "PHP_EXT_EXTRA=''"
out=$(extopt "$tf" "" "intl,intl") || true
check "a repeated name is recorded once" has "$out" "extra=intl "
tf2=$TMP/tuning-ext-refused
out=$(extopt "$tf2" "gmp" "intl,oci8") || true
check "an unbuildable name refuses the whole list" has "$out" "rc=1 extra=gmp "
check "a refused list writes nothing" test ! -e "$tf2"
plus_rc=0; q php_ext_validate +intl || plus_rc=1
out=$(extopt "$TMP/tuning-plus" "" "+intl") || true
opt_plus=1; has "$out" "rc=0" && opt_plus=0
check "ext=+NAME: the validator and php_build_ext_option agree" test "$plus_rc" = "$opt_plus"
check "ext=-NAME passes the validator" q php_ext_validate -intl
persisted() ( # the tuning file as the host sources it, then the set
  # shellcheck disable=SC1090
  source "$1"
  PHP_BUILD_ROOT=$NOROOT
  PHP_BUILD_NGINX=$TMP/t-wp
  php_build_effective_exts 2>/dev/null
)
extopt "$TMP/tuning-src" "" "gmp,intl" >/dev/null || true
out=$(persisted "$TMP/tuning-src") || true
check "a persisted PHP_EXT_EXTRA reaches the next run's set" csv_has_all "$out" gmp intl

# ---------------------------------------------------------------------------
# SQLite detection on fixture roots
# ---------------------------------------------------------------------------
sq() ( # ROOT [CACHE] -> 0 present, 1 absent, 2 unknown
  local rc=0
  PHP_BUILD_SCAN_CACHE=${2:-$(mktemp "$TMP/sqcache.XXXXXX")}
  _pb_sqlite_scan "$1" || rc=$?
  printf '%s' "$rc"
)
S=$TMP/sqlite
mkdir -p "$S/magic/data" "$S/magic3" "$S/dsn1" "$S/dsn2" "$S/class" "$S/nomagic" "$S/withvendor/vendor/lib" \
  "$S/deep/a/b/c/d" "$S/depth4/a/b/c" "$S/none"
printf 'SQLite format 3\000\020\000\001\001' > "$S/magic/data/site.db"
printf 'SQLite format 3\000\020\000' > "$S/magic3/store.sqlite3"
printf '<?php\n$pdo = new PDO('"'"'sqlite:'"'"' . __DIR__ . "/app.db");\n' > "$S/dsn1/db.php"
printf '<?php\n$pdo = new PDO("sqlite:/var/lib/app/app.db");\n' > "$S/dsn2/db.php"
printf '<?php\n$db = new \\SQLite3(__DIR__ . "/x");\n' > "$S/class/db.php"
printf 'not a database' > "$S/nomagic/cache.db"
printf '<?php\n$pdo = new PDO("sqlite::memory:");\n' > "$S/withvendor/vendor/lib/x.php"
printf '<?php echo 1;\n' > "$S/withvendor/index.php"
printf 'SQLite format 3\000' > "$S/deep/a/b/c/d/e.db"
printf 'SQLite format 3\000' > "$S/depth4/a/b/c/d.db"
printf '<?php echo "no database";\n' > "$S/none/index.php"
check "sqlite: a *.db file with the SQLite magic" test "$(sq "$S/magic")" = 0
check "sqlite: a *.sqlite3 file with the SQLite magic" test "$(sq "$S/magic3")" = 0
check "sqlite: a single-quoted PDO sqlite: DSN" test "$(sq "$S/dsn1")" = 0
check "sqlite: a double-quoted PDO sqlite: DSN" test "$(sq "$S/dsn2")" = 0
check "sqlite: new \\SQLite3(" test "$(sq "$S/class")" = 0
check "sqlite: a *.db file without the magic is no SQLite use" test "$(sq "$S/nomagic")" = 1
check "sqlite: vendor/ is not scanned" test "$(sq "$S/withvendor")" = 1
check "sqlite: a database at depth 4 is found" test "$(sq "$S/depth4")" = 0
check "sqlite: deeper than 4 levels is not scanned" test "$(sq "$S/deep")" = 1
check "sqlite: a plain PHP root is no SQLite use" test "$(sq "$S/none")" = 1
check "sqlite: a missing root is unknown" test "$(sq "$S/missing")" = 2
sqcache=$TMP/sq-cache-reuse
mkdir -p "$S/cached"
printf 'SQLite format 3\000' > "$S/cached/a.db"
first=$(sq "$S/cached" "$sqcache") || true
rm -f "$S/cached/a.db"
second=$(sq "$S/cached" "$sqcache") || true
check "sqlite: a scan result is reused within 10 minutes" test "$first:$second" = "0:0"
mk_wp "$APPS/wp-sqlite"
mkdir -p "$APPS/wp-sqlite/wp-content/database"
printf 'SQLite format 3\000' > "$APPS/wp-sqlite/wp-content/database/.ht.sqlite"
mk_vhost "$TMP/t-wp-sqlite" wps "$APPS/wp-sqlite"
out=$(effp PHP_BUILD_ROOT="$NOROOT" PHP_BUILD_NGINX="$TMP/t-wp-sqlite") || true
check "a WordPress root with a SQLite database gets sqlite3, pdo_sqlite and pdo" csv_has_all "$out" sqlite3 pdo_sqlite pdo

# ---------------------------------------------------------------------------
# Redis detection (XenForo config, WordPress drop-ins)
# ---------------------------------------------------------------------------
rn() ( local rc=0; _pb_redis_needed "$1" "$2" || rc=$?; printf '%s' "$rc" )
R=$TMP/redis
mk_xf "$R/xf-on" "\$config['cache']['provider'] = 'Redis';"
mk_xf "$R/xf-lower" "\$config['cache']['provider'] = \"redis\";"
mk_xf "$R/xf-doctrine" "\$config['cache']['provider'] = 'Doctrine\\Common\\Cache\\RedisCache';"
mk_xf "$R/xf-slash" "// \$config['cache']['provider'] = 'Redis';"
mk_xf "$R/xf-hash" "# \$config['cache']['provider'] = 'Redis';"
mk_xf "$R/xf-memcached" "\$config['cache']['provider'] = 'Memcached';"
mk_xf "$R/xf-plain"
check "xenforo: provider 'Redis' needs redis" test "$(rn xenforo "$R/xf-on")" = 0
check "xenforo: the provider name is matched case-insensitively" test "$(rn xenforo "$R/xf-lower")" = 0
check "xenforo: Doctrine's RedisCache class needs redis" test "$(rn xenforo "$R/xf-doctrine")" = 0
check "xenforo: a // commented example does not count" test "$(rn xenforo "$R/xf-slash")" = 1
check "xenforo: a # commented example does not count" test "$(rn xenforo "$R/xf-hash")" = 1
check "xenforo: the Memcached provider needs no redis" test "$(rn xenforo "$R/xf-memcached")" = 1
check "xenforo: a config without a cache provider needs no redis" test "$(rn xenforo "$R/xf-plain")" = 1
agree() { # ROOT: _pb_redis_needed and the single table (install mode) agree
  local a=1 b=1
  [[ $(rn xenforo "$1") == 0 ]] && a=0
  php_upgrade_app_required_extensions xenforo "$1" install | grep -qx redis && b=0
  [[ $a == "$b" ]]
}
for x in xf-on xf-lower xf-doctrine xf-slash xf-hash xf-memcached xf-plain; do
  check "xenforo ${x}: the build and the requirement table agree on redis" agree "$R/$x"
done
mk_wp "$R/wp-phpredis"
printf '<?php\n$this->redis = new \\Redis();\n' > "$R/wp-phpredis/wp-content/object-cache.php"
mk_wp "$R/wp-predis"
printf '<?php\n// Redis Object Cache\nuse Predis\\Client;\n$c = new Redis();\n' > "$R/wp-predis/wp-content/object-cache.php"
mk_wp "$R/wp-ocp"
printf '<?php\n// Object Cache Pro\nclass RedisCachePro {}\n' > "$R/wp-ocp/wp-content/object-cache.php"
mk_wp "$R/wp-none"
check "wordpress: a drop-in that creates \\Redis needs redis" test "$(rn wordpress "$R/wp-phpredis")" = 0
check "wordpress: a Predis drop-in needs no redis" test "$(rn wordpress "$R/wp-predis")" = 1
check "wordpress: Object Cache Pro needs redis" test "$(rn wordpress "$R/wp-ocp")" = 0
check "wordpress: no drop-in needs no redis" test "$(rn wordpress "$R/wp-none")" = 1
check "chevereto's redis comes from its table, not the drop-in rule" test "$(rn chevereto "$APPS/chev")" = 1

# ---------------------------------------------------------------------------
# tools/php-build.sh: per-SAPI verify lists, OPcache, version policy, check
# ---------------------------------------------------------------------------
cat > "$TMP/tool-stubs.sh" <<'EOF'
# Network and logging stubs for tools/php-build.sh in tests.
logger() { :; }
http_get() { [[ -n ${FAKE_JSON:-} ]] || return 1; printf '%s' "$FAKE_JSON"; }
git() { local t; for t in ${FAKE_TAGS:-}; do printf 'deadbeef\trefs/tags/%s\n' "$t"; done; }
resolve_all() { :; }
EOF
tool_run() { # CODE: bash with tools/php-build.sh sourced (no main) and the stubs
  PHP_BUILD_SOURCE_ONLY=1 bash -c 'source "$1"; source "$2"; eval "$3"' _ \
    "$ROOT/tools/php-build.sh" "$TMP/tool-stubs.sh" "$1" 2>&1
}
vc() { # VER "FPM-MODULES" "CLI-MODULES" "SET" [REPORTED-VERSION] -> output, status=N
  local d oc="" rc=0 o
  local -a fm=() cm=()
  d=$(mktemp -d "$TMP/vc.XXXXXX")
  read -ra fm <<<"$2"
  read -ra cm <<<"$3"
  mk_fake_php "$d/fpm" "${fm[@]}"
  mk_fake_php "$d/cli" "${cm[@]}"
  printf '%s\n' "${5:-$1.3}" > "$d/fpm.version"
  printf '%s\n' "${5:-$1.3}" > "$d/cli.version"
  [[ -n ${VC_WARN:-} ]] && printf '%s\n' "$VC_WARN" > "$d/fpm.warn"
  if ! _pb_ver_ge "$1" 8.5; then oc=$d/opcache.so; : > "$oc"; fi
  mkdir -p "$d/work"
  o=$(tool_run "verify_candidates '$1' '$d/fpm' '$d/cli' '$oc' '$4' '$d/work'") || rc=$?
  printf '%s\nstatus=%s\n' "$o" "$rc"
}
C84="core date hash json pcre reflection spl standard random opcache"
C81="core date hash json pcre reflection spl standard opcache"
SET="curl opcache pcntl phar"
out=$(vc 8.4 "$C84 cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: FPM without pcntl and the CLI with it pass" has "$out" "status=0"
check "verify: the JIT result is printed" has "$out" $'1\nstatus=0'
out=$(vc 8.4 "$C84 cgi-fcgi curl phar" "$C84 curl phar" "$SET") || true
check "verify: a CLI without pcntl is refused" has "$out" "cli candidate lacks the pcntl module"
out=$(vc 8.4 "$C84 cgi-fcgi curl phar pcntl" "$C84 curl phar pcntl" "$SET") || true
check "verify: pcntl in FPM too is harmless" has "$out" "status=0"
out=$(vc 8.4 "$C84 cgi-fcgi curl phar" "$C84 curl phar pcntl cgi-fcgi" "$SET") || true
check "verify: cgi-fcgi is allowed in FPM only" has "$out" "cli candidate has modules outside the set: cgi-fcgi"
out=$(vc 8.4 "$C84 curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: FPM does not need to list cgi-fcgi" has "$out" "status=0"
out=$(vc 8.4 "$C84 cgi-fcgi curl phar intl" "$C84 curl phar pcntl" "$SET") || true
check "verify: a module outside the set is refused" has "$out" "fpm candidate has modules outside the set: intl"
out=$(vc 8.4 "${C84/ opcache/} cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: a candidate without OPcache is refused" has "$out" "fpm candidate lacks the opcache module"
out=$(vc 8.4 "${C84/ random/} cgi-fcgi curl phar" "${C84/ random/} curl phar pcntl" "$SET") || true
check "verify: 8.4 requires random" has "$out" "lacks the random module"
out=$(vc 8.1 "$C81 cgi-fcgi curl phar" "$C81 curl phar pcntl" "$SET") || true
check "verify: 8.1 has no random" has "$out" "status=0"
out=$(vc 8.5 "$C84 lexbor uri cgi-fcgi curl phar" "$C84 lexbor uri curl phar pcntl" "$SET") || true
check "verify: 8.5 allows lexbor and uri" has "$out" "status=0"
out=$(vc 8.5 "$C84 cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: 8.5 does not require lexbor and uri" has "$out" "status=0"
out=$(vc 8.4 "$C84 lexbor cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: lexbor before 8.5 is outside the set" has "$out" "outside the set: lexbor"
out=$(vc 8.4 "$C84 cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET" 8.3.9) || true
check "verify: a candidate of another series is refused" has "$out" "not a PHP 8.4 release"
out=$(VC_WARN='PHP Warning:  Module "curl" is already loaded in Unknown on line 0' \
  vc 8.4 "$C84 cgi-fcgi curl phar" "$C84 curl phar pcntl" "$SET") || true
check "verify: a start-up warning is refused" has "$out" "fpm candidate starts with warnings"
out=$(tool_run 'printf "%s" "$CLI_ONLY_EXTS"') || true
check "the tool's CLI-only list is pcntl" test "$out" = pcntl
out=$(tool_run 'core_required 8.1 | paste -sd, -; core_required 8.2 | paste -sd, -; core_allowed 8.5 fpm | paste -sd, -') || true
check "core of 8.1 has no random" has "$out" $'core,date,hash,json,pcre,reflection,spl,standard\n'
check "core of 8.2 adds random" has "$out" "standard,random"
check "8.5 FPM allows lexbor, uri and cgi-fcgi" has "$out" "lexbor,uri,cgi-fcgi"
out=$(tool_run 'core_allowed 8.4 cli; core_allowed 8.4 fpm') || true
check "8.4 allows only cgi-fcgi, in FPM" test "$out" = cgi-fcgi

out=$(tool_run 'opcache_shared 8.4 && echo shared-8.4; opcache_shared 8.5 || echo builtin-8.5; opcache_shared 9.0 || echo builtin-9.0; echo "[$(ext_flags 8.4 opcache /x)][$(ext_flags 8.5 opcache /x)]"') || true
check "OPcache is a shared module before 8.5" has "$out" "shared-8.4"
check "OPcache is compiled in from 8.5" has "$out" "builtin-8.5"
check "OPcache stays compiled in after 8.5" has "$out" "builtin-9.0"
check "8.4 configures --enable-opcache, 8.5 has no option" has "$out" "[--enable-opcache][]"
out=$(tool_run 'ext_flags 8.4 "curl oci8" /x') && st=0 || st=$?
check "the tool refuses an extension outside its recipe" test "$st" = 1
check "the refusal names it" has "$out" "extension 'oci8' is not part of the build recipe"
out=$(tool_run 'ext_flags 8.4 "redis igbinary" /x | paste -sd" " -') || true
check "redis links igbinary when both are in the set" has "$out" "--enable-redis --enable-redis-igbinary"

out=$(tool_run 'for v in 8.0 8.1 8.5 9.0 8.5.1 8; do if ver_supported "$v"; then printf "%s:y " "$v"; else printf "%s:n " "$v"; fi; done') || true
check "the tool supports 8.1 and newer series only" test "$out" = "8.0:n 8.1:y 8.5:y 9.0:y 8.5.1:n 8:n "
sup() { local v r=""; for v in 8.0 8.1 9.0 8.5.1 8.5RC1; do if php_series_supported "$v"; then r+="$v:y "; else r+="$v:n "; fi; done; printf '%s' "$r"; }
check "setup.sh agrees on the supported series" test "$(sup)" = "8.0:n 8.1:y 9.0:y 8.5.1:n 8.5RC1:n "
rel() ( export FAKE_JSON=$1 FAKE_TAGS=$2; tool_run "main $3" )
# php.net's JSON is read with perl's core JSON::PP (build-common json_eval);
# a host without it falls back to the php-src tags, checked below.
HAVE_JSON_PP=0
perl -MJSON::PP -e 1 >/dev/null 2>&1 && HAVE_JSON_PP=1
if (( HAVE_JSON_PP )); then
  out=$(rel '{"version":"8.5.3"}' "" "release 8.5") || true
  check "release: php.net's newest 8.5.Z" test "$out" = 8.5.3
  out=$(rel '{"8":{"version":"8.5.3"},"7":{"version":"7.4.33"}}' "" series) || true
  check "series: the newest released series from php.net" test "$out" = 8.5
else
  printf 'SKIP  php.net JSON checks (perl JSON::PP missing)\n'
fi
out=$(rel '{"version":"8.6.0RC1"}' "" "release 8.6") || true
check "release: an RC from php.net is never a release" test -z "$out"
out=$(rel "" "php-8.5.2 php-8.5.10 php-8.5.11RC1 php-8.6.0alpha1" "release 8.5") || true
check "release: php-src tags without a suffix only, newest by version" test "$out" = 8.5.10
out=$(rel "" "php-8.6.0RC1 php-8.6.0beta3" "release 8.6") || true
check "release: a series with only pre-releases has none" test -z "$out"
out=$(rel '{"8":{"version":"8.6.0RC1"}}' "php-8.5.3 php-8.6.0RC1 php-8.6.0alpha2" series) || true
check "series: an RC series is skipped (php-src fallback)" test "$out" = 8.5
out=$(rel "" "" "release 8.5.1") && st=0 || st=$?
check "release refuses X.Y.Z as the series argument" test "$st" = 1

chk() ( # EXTS.WANT -> cmd_check output, then rc=N
  export CHK_ROOT=$TMP/chk-$RANDOM CHK_WANT=$1
  mkdir -p "$CHK_ROOT/8.4/sbin"
  printf '%s\n' "$CHK_WANT" > "$CHK_ROOT/8.4/exts.want"
  tool_run 'ROOT=$CHK_ROOT
    printf "recipe=%s\ncpu=%s\nexts=ctype,curl\n" "$BUILD_RECIPE" "$(cpu_fingerprint)" > "$ROOT/8.4/build.info"
    rc=0; cmd_check 8.4 || rc=$?; echo "rc=$rc"'
)
out=$(chk ctype,curl,gmp) || true
check "check: a changed extension set is stale" has "$out" "rc=10"
check "check: the stale reason names old and new set" has "$out" "extensions ctype,curl -> ctype,curl,gmp"
out=$(chk curl,ctype) || true
check "check: the same set in another order is current" has "$out" "rc=0"
check "check: the same set reports no extension change" lacks "$out" "extensions"

# ---------------------------------------------------------------------------
# php_build_layout
# ---------------------------------------------------------------------------
L=$TMP/lay
lay() ( # SANDBOX [layout args...] after the setup in LAY_PRE (a function name)
  local d=$1 rc=0
  shift
  sandbox "$d"
  stub_host
  if [[ -n ${LAY_PRE:-} ]]; then "$LAY_PRE"; fi
  php_build_layout "$@" 2>>"$d/err" || rc=$?
  printf 'rc=%s\n' "$rc"
)
pre_84() { [[ -d $PHP_BUILD_ROOT/8.4 ]] || mk_build 8.4; php_active_set 8.4; }
out=$(LAY_PRE=pre_84 lay "$L" 8.4) || true
E=$L/etc/8.4
check "layout 8.4: succeeds" has "$out" "rc=0"
check "php-fpm.conf: first line is the marker" first_line_has "$E/fpm/php-fpm.conf" "$PHP_BUILD_MARK"
check "php-fpm.conf: per-version pid" file_line "$E/fpm/php-fpm.conf" "pid = /run/php/php8.4-fpm.pid"
check "php-fpm.conf: includes this tree's pool.d" file_line "$E/fpm/php-fpm.conf" "include = $L/etc/8.4/fpm/pool.d/*.conf"
check "php-fpm.conf: process_control_timeout 10s" file_line "$E/fpm/php-fpm.conf" "process_control_timeout = 10s"
check "php-fpm.conf: rlimit_files" file_line "$E/fpm/php-fpm.conf" "rlimit_files = 524288"
check "fpm php.ini: first line is the marker" first_line_has "$E/fpm/php.ini" "$PHP_BUILD_MARK"
check "fpm php.ini: carries the version's php.ini-production" file_line "$E/fpm/php.ini" "memory_limit = 128M"
check "fpm php.ini: PHP's own session GC is kept" file_line "$E/fpm/php.ini" "session.gc_probability = 1"
check "fpm php.ini: the shared sessions directory" file_line "$E/fpm/php.ini" "session.save_path = \"/var/lib/php/sessions\""
check "fpm php.ini: no CLI memory_limit" file_lacks "$E/fpm/php.ini" "memory_limit = -1"
check "cli php.ini: memory_limit = -1 as Debian's CLI" file_line "$E/cli/php.ini" "memory_limit = -1"
check "8.4: 00-setup-opcache.ini loads the build's opcache.so (fpm)" \
  file_line "$E/fpm/conf.d/00-setup-opcache.ini" "zend_extension=$L/root/8.4/lib/opcache.so"
check "8.4: 00-setup-opcache.ini loads the build's opcache.so (cli)" \
  file_line "$E/cli/conf.d/00-setup-opcache.ini" "zend_extension=$L/root/8.4/lib/opcache.so"
check "www.conf: written from the master template" cmp -s "$ROOT/configs/php/www.conf" "$E/fpm/pool.d/www.conf"
check "conf.d holds only our files" test "$(find "$E/fpm/conf.d" "$E/cli/conf.d" -type f | wc -l | tr -d ' ')" = 2
check "the unit is written" first_line_has "$L/units/php8.4-fpm.service" "$PHP_BUILD_UNIT_MARK"
check "tmpfiles: setup-php.conf written" file_line "$L/tmpfiles/setup-php.conf" "d /var/lib/php/sessions 0700 www-data www-data -"
check "links: /usr/local/bin/php points at the active CLI" link_to "$L/lbin/php" "$L/root/8.4/bin/php"
check "golden copy of the managed files" test -f "$L/root/8.4/etc-golden/fpm/php-fpm.conf"
check "the ini template sync runs for the live tree" file_has "$L/stub.log" "sync_php_ini_template 8.4"
check "layout reloads systemd but starts nothing" bash -c 'grep -q "daemon-reload" "$1" && ! grep -qE "systemctl (start|restart|enable)" "$1"' _ "$L/stub.log"

# www.conf ours: rewritten from the template, the tuner's/operator's keys kept.
sed -i -e 's|^pm.max_children = .*|pm.max_children = 37|' -e 's|^listen = .*|listen = /run/php/custom.sock|' \
  -e 's|^listen.backlog = .*|listen.backlog = 100|' -e 's|^request_terminate_timeout = .*|request_terminate_timeout = 30s|' \
  "$E/fpm/pool.d/www.conf"
printf 'php_admin_value[open_basedir] = /var/www/site:/tmp\n' >> "$E/fpm/pool.d/www.conf"
out=$(LAY_PRE=pre_84 lay "$L" 8.4) || true
check "re-layout: succeeds" has "$out" "rc=0"
check "www.conf merge: the tuner's pm.max_children is kept" file_line "$E/fpm/pool.d/www.conf" "pm.max_children = 37"
check "www.conf merge: the operator's listen is kept" file_line "$E/fpm/pool.d/www.conf" "listen = /run/php/custom.sock"
check "www.conf merge: listen.* keys are the operator's" file_line "$E/fpm/pool.d/www.conf" "listen.backlog = 100"
check "www.conf merge: a template key comes from the template" file_line "$E/fpm/pool.d/www.conf" "request_terminate_timeout = 300s"
check "www.conf merge: a directive the template lacks is kept" file_line "$E/fpm/pool.d/www.conf" "php_admin_value[open_basedir] = /var/www/site:/tmp"
check "www.conf merge: kept directives are labelled" file_has "$E/fpm/pool.d/www.conf" "; Kept from the previous www.conf"
check "www.conf merge: still ours" first_line_has "$E/fpm/pool.d/www.conf" "$PHP_BUILD_MARK"

# A www.conf without the marker (operator, Sury, 1.21) is adopted as it is.
L2=$TMP/lay-adopt
pre_adopt() {
  pre_84
  mkdir -p "$PHP_BUILD_ETC/8.4/fpm/pool.d"
  printf '[www]\nuser = www-data\ngroup = www-data\nlisten = 127.0.0.1:9000\npm = dynamic\n' > "$PHP_BUILD_ETC/8.4/fpm/pool.d/www.conf"
  cp "$PHP_BUILD_ETC/8.4/fpm/pool.d/www.conf" "$PHP_BUILD_ETC/www.conf.orig"
}
out=$(LAY_PRE=pre_adopt lay "$L2" 8.4) || true
check "adopt: succeeds" has "$out" "rc=0"
check "adopt: an operator www.conf is left untouched" cmp -s "$L2/etc/www.conf.orig" "$L2/etc/8.4/fpm/pool.d/www.conf"

# conf.d: Sury entries moved to the backups, operator .so lines commented
# under the marker, our opcache file kept; [global] in an adopted pool off.
L3=$TMP/lay-sury
pre_sury() {
  pre_84
  local e=$PHP_BUILD_ETC/8.4
  mkdir -p "$e/mods-available" "$e/fpm/conf.d" "$e/cli/conf.d" "$e/fpm/pool.d" "$L3/op-src"
  printf 'extension=intl.so\n' > "$e/mods-available/intl.ini"
  ln -s ../../mods-available/intl.ini "$e/fpm/conf.d/20-intl.ini"
  ln -s /nonexistent/setup-test/gone.ini "$e/fpm/conf.d/20-gone.ini"
  printf 'zend_extension=opcache.so\n' > "$e/cli/conf.d/10-opcache.ini"
  printf 'extension=redis.so\n  zend_extension = xdebug.so\nmemory_limit = 1G\n' > "$e/fpm/conf.d/30-operator.ini"
  printf 'extension=apcu.so\n' > "$L3/op-src/40-linked.ini"
  ln -s "$L3/op-src/40-linked.ini" "$e/fpm/conf.d/40-linked.ini"
  printf 'redis\n' > "$e/fpm/setup-disabled-modules"
  printf '[global]\npid = /run/php/legacy.pid\n\n[legacy]\nuser = www-data\nlisten = /run/php/legacy.sock\n' > "$e/fpm/pool.d/legacy.conf"
  STUB_DPKG_OWNED="$e/cli/conf.d/10-opcache.ini"
}
out=$(LAY_PRE=pre_sury lay "$L3" 8.4) || true
E3=$L3/etc/8.4
bk=$(find "$L3/backups" -maxdepth 1 -type d -name 'php-8.4-confd-*' 2>/dev/null | head -n 1) || true
check "sury: layout succeeds" has "$out" "rc=0"
check "sury: a mods-available symlink leaves conf.d" test ! -e "$E3/fpm/conf.d/20-intl.ini" -a ! -L "$E3/fpm/conf.d/20-intl.ini"
check "sury: the symlink is in the backups" test -L "$bk/fpm/20-intl.ini"
check "sury: a dangling symlink is moved too" test -L "$bk/fpm/20-gone.ini"
check "sury: a dpkg-owned conf.d file is moved" test -f "$bk/cli/10-opcache.ini"
check "sury: 1.21's setup-disabled-modules is moved" test -f "$bk/fpm/setup-disabled-modules"
check "sury: an operator extension= line is commented under the marker" \
  file_line "$E3/fpm/conf.d/30-operator.ini" "${PHP_BUILD_OFF_MARK}extension=redis.so"
check "sury: an operator zend_extension= line is commented under the marker" \
  file_line "$E3/fpm/conf.d/30-operator.ini" "${PHP_BUILD_OFF_MARK}  zend_extension = xdebug.so"
check "sury: the operator's settings stay" file_line "$E3/fpm/conf.d/30-operator.ini" "memory_limit = 1G"
check "sury: an operator symlink becomes a regular copy" test -f "$E3/fpm/conf.d/40-linked.ini" -a ! -L "$E3/fpm/conf.d/40-linked.ini"
check "sury: the copy is commented" file_line "$E3/fpm/conf.d/40-linked.ini" "${PHP_BUILD_OFF_MARK}extension=apcu.so"
check "sury: the operator's linked source is never written through" file_line "$L3/op-src/40-linked.ini" "extension=apcu.so"
check "sury: our opcache file keeps its extension line" file_line "$E3/fpm/conf.d/00-setup-opcache.ini" "zend_extension=$L3/root/8.4/lib/opcache.so"
check "sury: an adopted pool's [global] settings are commented" file_line "$E3/fpm/pool.d/legacy.conf" "${PHP_BUILD_OFF_MARK}pid = /run/php/legacy.pid"
check "sury: the pool section itself stays" file_line "$E3/fpm/pool.d/legacy.conf" "listen = /run/php/legacy.sock"
check "sury: the pool file was backed up first" bash -c 'compgen -G "$1/php-8.4-pool-global-*/legacy.conf" >/dev/null' _ "$L3/backups"
out=$(LAY_PRE=pre_84 lay "$L3" 8.4) || true
check "sury: a second layout comments nothing twice" test "$(count_of "$E3/fpm/conf.d/30-operator.ini" "$PHP_BUILD_OFF_MARK")" = 2
check "sury: the marker never stacks" file_lacks "$E3/fpm/conf.d/30-operator.ini" "${PHP_BUILD_OFF_MARK}${PHP_BUILD_OFF_MARK}"

# 8.5: OPcache is compiled in; a leftover 00-setup-opcache.ini goes.
L4=$TMP/lay-85
pre_85() {
  mk_build 8.5
  php_active_set 8.5
  mkdir -p "$PHP_BUILD_ETC/8.5/fpm/conf.d" "$PHP_BUILD_ETC/8.5/cli/conf.d"
  printf 'zend_extension=/old/opcache.so\n' > "$PHP_BUILD_ETC/8.5/fpm/conf.d/00-setup-opcache.ini"
}
out=$(LAY_PRE=pre_85 lay "$L4" 8.5) || true
check "8.5: layout succeeds" has "$out" "rc=0"
check "8.5: no opcache.so is installed" test ! -e "$L4/root/8.5/lib/opcache.so"
check "8.5: a leftover 00-setup-opcache.ini is removed (fpm)" test ! -e "$L4/etc/8.5/fpm/conf.d/00-setup-opcache.ini"
check "8.5: none is written for the CLI" test ! -e "$L4/etc/8.5/cli/conf.d/00-setup-opcache.ini"

# A staged tree (the migration's test before cutover): staged opcache.so,
# no unit, no links.
L5=$TMP/lay-staged
pre_staged() { mk_build 8.4; mkdir -p "$PHP_BUILD_ROOT/8.4/staging/lib"; : > "$PHP_BUILD_ROOT/8.4/staging/lib/opcache.so"; }
out=$(LAY_PRE=pre_staged lay "$L5" 8.4 auto "$L5/staging-etc") || true
check "staged: layout succeeds" has "$out" "rc=0"
check "staged: OPcache comes from the staged build" \
  file_line "$L5/staging-etc/8.4/fpm/conf.d/00-setup-opcache.ini" "zend_extension=$L5/root/8.4/staging/lib/opcache.so"
check "staged: php-fpm.conf includes the staged pool.d" file_line "$L5/staging-etc/8.4/fpm/php-fpm.conf" "include = $L5/staging-etc/8.4/fpm/pool.d/*.conf"
check "staged: no unit is written" test ! -e "$L5/units/php8.4-fpm.service"
check "staged: no link is written" test ! -e "$L5/lbin/php8.4"
check "staged: the live tree is not touched" test ! -e "$L5/etc/8.4"

# Refusals: a package php-fpm still serving, no build.
L6=$TMP/lay-refuse
pre_pkg() { mk_build 8.4; STUB_ACTIVE="php8.4-fpm"; }
out=$(LAY_PRE=pre_pkg lay "$L6" 8.4) || true
check "a running package php8.4-fpm refuses the layout" has "$out" "rc=1"
check "the refusal writes nothing under /etc/php/8.4" test ! -e "$L6/etc/8.4/fpm/php.ini"
check "the refusal says why" file_has "$L6/err" "the package php8.4-fpm still serves"
out=$(lay "$TMP/lay-nobuild" 8.4) || true
check "no build refuses the layout" has "$out" "rc=1"
out=$(lay "$TMP/lay-badver" 8.4.1) || true
check "a bad version refuses the layout" has "$out" "rc=1"

# ---------------------------------------------------------------------------
# php_fpm_test arguments (stub binary records argv and PHP_INI_SCAN_DIR)
# ---------------------------------------------------------------------------
F=$TMP/fpmt
( sandbox "$F"; mk_build 8.4 )
fpmt() ( # [ETC_ROOT] -> output, rc=N; argv in $F/argv.log
  sandbox "$F"
  export FAKE_LOG=$F/argv.log PHP_INI_SCAN_DIR=/operator/cli/scan
  rm -f "$FAKE_LOG"
  local rc=0
  php_fpm_test 8.4 "$@" || rc=$?
  printf 'rc=%s\n' "$rc"
)
out=$(fpmt) || true
check "php_fpm_test: a clean tree passes" has "$out" "rc=0"
check "php_fpm_test: -t with -y php-fpm.conf and -c php.ini" \
  file_line "$F/argv.log" "$F/root/8.4/sbin/php-fpm|scan=$F/etc/8.4/fpm/conf.d|-t -y $F/etc/8.4/fpm/php-fpm.conf -c $F/etc/8.4/fpm/php.ini"
check "php_fpm_test: the module list with FPM's php.ini" \
  file_line "$F/argv.log" "$F/root/8.4/sbin/php-fpm|scan=$F/etc/8.4/fpm/conf.d|-c $F/etc/8.4/fpm/php.ini -m"
check "php_fpm_test: an exported CLI scan dir never reaches FPM" file_lacks "$F/argv.log" "/operator/cli/scan"
printf 'PHP Warning:  Module "redis" is already loaded in Unknown on line 0\n' > "$F/root/8.4/sbin/php-fpm.warn"
out=$(fpmt) || true
check "php_fpm_test: an 'already loaded' warning fails" has "$out" "rc=1"
rm -f "$F/root/8.4/sbin/php-fpm.warn"
printf 'core\ndate\nstandard\n' > "$F/root/8.4/sbin/php-fpm.mods.new"
cp "$F/root/8.4/sbin/php-fpm.mods" "$F/root/8.4/sbin/php-fpm.mods.keep"
mv -f "$F/root/8.4/sbin/php-fpm.mods.new" "$F/root/8.4/sbin/php-fpm.mods"
out=$(fpmt) || true
check "php_fpm_test: missing OPcache fails" has "$out" "rc=1"
check "php_fpm_test: and says so" has "$out" "OPcache is not loaded"
mv -f "$F/root/8.4/sbin/php-fpm.mods.keep" "$F/root/8.4/sbin/php-fpm.mods"
: > "$F/root/8.4/sbin/php-fpm.tfail"
out=$(fpmt) || true
check "php_fpm_test: a failing -t fails" has "$out" "rc=1"
rm -f "$F/root/8.4/sbin/php-fpm.tfail"
( sandbox "$F"; mk_fake_php "$PHP_BUILD_ROOT/8.4/staging/sbin/php-fpm" core date opcache )
out=$(fpmt "$F/stg") || true
check "php_fpm_test: a staged tree tests the staged candidate" \
  file_line "$F/argv.log" "$F/root/8.4/staging/sbin/php-fpm|scan=$F/stg/8.4/fpm/conf.d|-t -y $F/stg/8.4/fpm/php-fpm.conf -c $F/stg/8.4/fpm/php.ini"
out=$(fpmt "$F/etc") || true
check "php_fpm_test: the live tree never tests the staged binary" file_has "$F/argv.log" "$F/root/8.4/sbin/php-fpm|"
check "php_fpm_test: the live tree with the staged binary present" file_lacks "$F/argv.log" "staging"
out=$( ( sandbox "$TMP/fpmt-none"; php_fpm_test 8.4 ) ) && st=0 || st=$?
check "php_fpm_test: no binary fails" test "$st" = 1
check "php_fpm_test: and names the missing binary" has "$out" "no compiled php-fpm for PHP 8.4"

# ---------------------------------------------------------------------------
# Unit text, wrapper, tmpfiles, sessions per pool user
# ---------------------------------------------------------------------------
U=$TMP/unit
unit_txt=$( sandbox "$U"; php_build_unit_text 8.4 ) || true
check "unit: Type=notify" has "$unit_txt" $'\nType=notify\n'
check "unit: ExecStart runs our php-fpm with the FPM tree" \
  has "$unit_txt" $'\n'"ExecStart=$U/root/8.4/sbin/php-fpm --nodaemonize --fpm-config $U/etc/8.4/fpm/php-fpm.conf -c $U/etc/8.4/fpm/php.ini"$'\n'
check "unit: FPM's conf.d through PHP_INI_SCAN_DIR" has "$unit_txt" $'\n'"Environment=PHP_INI_SCAN_DIR=$U/etc/8.4/fpm/conf.d"$'\n'
check "unit: the CPU gate and -t run before the start" has "$unit_txt" $'\n'"ExecStartPre=$U/root/php-build.sh pre 8.4"$'\n'
check "unit: graceful reload" has "$unit_txt" $'\nExecReload=/bin/kill -USR2 $MAINPID\n'
check "unit: the shared /run/php survives restarts" has "$unit_txt" $'\nRuntimeDirectory=php\nRuntimeDirectoryPreserve=yes\n'
check "unit: limits" has "$unit_txt" $'\nLimitNOFILE=524288\nLimitCORE=0\n'
check "unit: SIGQUIT and a 15 s stop timeout" has "$unit_txt" $'\nKillSignal=SIGQUIT\n'
check "unit: TimeoutStopSec=15" has "$unit_txt" $'\nTimeoutStopSec=15\n'
check "unit: UMask=0027" has "$unit_txt" $'\nUMask=0027\n'
check "unit: per-version PID file" has "$unit_txt" $'\nPIDFile=/run/php/php8.4-fpm.pid\n'
check "unit: enabled from multi-user.target" has "$unit_txt" $'\nWantedBy=multi-user.target'
check "unit: never runs a package binary" lacks "$unit_txt" "/usr/sbin/php-fpm"
mkdir -p "$U/units"
printf '%s\n' "$unit_txt" > "$U/units/php8.4-fpm.service"
out=$( export PHP_BUILD_ROOT=$U/root PHP_BUILD_UNIT_DIR=$U/units; tool_run 'if unit_is_ours 8.4; then echo ours; else echo foreign; fi' ) || true
check "the tool recognises the unit the lib writes as its own" test "$out" = ours
out=$( export PHP_BUILD_ROOT=$U/other PHP_BUILD_UNIT_DIR=$U/units; tool_run 'if unit_is_ours 8.4; then echo ours; else echo foreign; fi' ) || true
check "the tool does not claim a unit of another root" test "$out" = foreign
rb=$( sandbox "$U"; php_build_rebuild_unit_text ) || true
check "rebuild unit: runs the installed tool" has "$rb" $'\n'"ExecStart=$U/root/php-build.sh rebuild %i"$'\n'
check "rebuild unit: low priority and OOM-first" has "$rb" $'\nNice=10\nIOSchedulingClass=idle\nOOMScoreAdjust=900\n'
( sandbox "$U"; mk_build 8.4; mkdir -p "$PHP_BUILD_LINK_SBIN"; php_build_fpm_wrapper_text 8.4 > "$PHP_BUILD_LINK_SBIN/php-fpm8.4"; chmod 755 "$PHP_BUILD_LINK_SBIN/php-fpm8.4" )
wrap() ( export FAKE_LOG=$U/wrap.log PHP_INI_SCAN_DIR=/operator/scan; rm -f "$FAKE_LOG"; "$U/lsbin/php-fpm8.4" "$@" >/dev/null 2>&1; cat "$FAKE_LOG" )
out=$(wrap -t) || true
check "wrapper: adds the unit's -y and -c" test "$out" = "$U/root/8.4/sbin/php-fpm|scan=$U/etc/8.4/fpm/conf.d|-y $U/etc/8.4/fpm/php-fpm.conf -c $U/etc/8.4/fpm/php.ini -t"
out=$(wrap -n -m) || true
check "wrapper: an explicit -n is not overridden" test "$out" = "$U/root/8.4/sbin/php-fpm|scan=$U/etc/8.4/fpm/conf.d|-y $U/etc/8.4/fpm/php-fpm.conf -n -m"
tmpf=$( sandbox "$U"; php_build_tmpfiles_text ) || true
check "tmpfiles: /run/php root 0755 (RuntimeDirectory owner)" has "$tmpf" $'\nd /run/php 0755 root root -'
check "tmpfiles: /var/lib/php root 0755" has "$tmpf" $'\nd /var/lib/php 0755 root root -'
check "tmpfiles: sessions www-data 0700" has "$tmpf" $'\nd /var/lib/php/sessions 0700 www-data www-data -'
check "tmpfiles: first line is a comment" test "${tmpf:0:1}" = "#"

P=$TMP/pools
pre_pools() {
  local p=$PHP_BUILD_ETC/8.4/fpm/pool.d
  mk_build 8.4
  mkdir -p "$p"
  printf '[shop]\nuser = setuptestshop\ngroup = setuptestshop\nlisten = /run/php/shop.sock\nphp_admin_value[open_basedir] = "/var/www/shop:/tmp"\n' > "$p/shop.conf"
  printf '[api]\nuser = setuptestapi\nlisten = /run/php/api.sock\nphp_admin_value[session.save_path] = /srv/api-sessions\n' > "$p/api.conf"
  printf '[cache]\nuser = setuptestcache\nlisten = /run/php/cache.sock\nphp_value[session.save_handler] = redis\n' > "$p/cache.conf"
  printf '[www]\nuser = www-data\nlisten = /run/php/php-fpm.sock\n' > "$p/www.conf"
  printf '[tmpl]\nuser = $pool\nlisten = /run/php/tmpl.sock\n' > "$p/tmpl.conf"
}
pools() ( sandbox "$P"; stub_host; [[ -n ${POOLS_PRE:-} ]] && "$POOLS_PRE"; php_build_session_pools 8.4 )
POOLS_PRE=pre_pools pools 2>/dev/null || true
PD=$P/etc/8.4/fpm/pool.d
check "sessions: a pool of another user gets its own save_path" \
  file_line "$PD/shop.conf" "php_admin_value[session.save_path] = /var/lib/php/sessions-setuptestshop"
check "sessions: its open_basedir gets the directory" \
  file_line "$PD/shop.conf" "php_admin_value[open_basedir] = \"/var/www/shop:/tmp:/var/lib/php/sessions-setuptestshop\""
check "sessions: tmpfiles creates it 0700 for that user" \
  file_line "$P/tmpfiles/setup-php-pools.conf" "d /var/lib/php/sessions-setuptestshop 0700 setuptestshop setuptestshop -"
check "sessions: a pool with its own save_path is untouched" file_lacks "$PD/api.conf" "sessions-setuptestapi"
check "sessions: a pool on another save_handler is untouched" file_lacks "$PD/cache.conf" "sessions-setuptestcache"
check "sessions: the www-data pool keeps the shared directory" file_lacks "$PD/www.conf" "session.save_path"
check "sessions: a templated user (\$pool) is skipped" file_lacks "$PD/tmpl.conf" "session.save_path"
check "sessions: only that one pool is in tmpfiles" test "$(grep -c '^d ' "$P/tmpfiles/setup-php-pools.conf")" = 1
pools 2>/dev/null || true
check "sessions: a second run adds no second save_path" test "$(count_of "$PD/shop.conf" "session.save_path")" = 1
check "sessions: a second run appends the directory once" test "$(count_of "$PD/shop.conf" "sessions-setuptestshop\"")" = 1
rm -f "$PD/shop.conf"
pools 2>/dev/null || true
check "sessions: tmpfiles drops the directory of a removed pool" test ! -e "$P/tmpfiles/setup-php-pools.conf"

# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------
links() ( # SANDBOX VER, after LINK_PRE
  sandbox "$1"
  stub_host
  [[ -n ${LINK_PRE:-} ]] && "$LINK_PRE"
  local rc=0
  php_build_links "$2" 2>/dev/null || rc=$?
  printf 'rc=%s\n' "$rc"
)
lk_base() { [[ -d $PHP_BUILD_ROOT/8.4 ]] || mk_build 8.4; php_active_set 8.4; }
lk_owned() { lk_base; STUB_DPKG_OWNED="$PHP_BUILD_USR_BIN/php $PHP_BUILD_USR_BIN/php8.4"; }
K=$TMP/lk-owned
out=$(LINK_PRE=lk_owned links "$K" 8.4) || true
check "links: succeed while dpkg owns /usr/bin/php" has "$out" "rc=0"
check "links: /usr/local/bin/php8.4" link_to "$K/lbin/php8.4" "$K/root/8.4/bin/php"
check "links: /usr/local/bin/php (active)" link_to "$K/lbin/php" "$K/root/8.4/bin/php"
check "links: /usr/local/sbin/php-fpm8.4 is our wrapper" first_line_has "$K/lsbin/php-fpm8.4" "#!/bin/sh"
check "links: the wrapper carries the marker" file_has "$K/lsbin/php-fpm8.4" "$PHP_BUILD_UNIT_MARK"
check "links: /usr/bin/php is left to dpkg" test ! -e "$K/usrbin/php" -a ! -L "$K/usrbin/php"
check "links: /usr/bin/php8.4 is left to dpkg" test ! -e "$K/usrbin/php8.4" -a ! -L "$K/usrbin/php8.4"
K=$TMP/lk-free
out=$(LINK_PRE=lk_base links "$K" 8.4) || true
check "links: /usr/bin/php once dpkg no longer owns it" link_to "$K/usrbin/php" "$K/root/8.4/bin/php"
check "links: /usr/bin/php8.4 once dpkg no longer owns it" link_to "$K/usrbin/php8.4" "$K/root/8.4/bin/php"
K=$TMP/lk-file
lk_file() { lk_base; mkdir -p "$PHP_BUILD_USR_BIN"; printf '#!/bin/sh\necho operator\n' > "$PHP_BUILD_USR_BIN/php"; }
out=$(LINK_PRE=lk_file links "$K" 8.4) || true
check "links: a regular /usr/bin/php is never replaced" bash -c '[[ -f $1 && ! -L $1 ]] && grep -q operator "$1"' _ "$K/usrbin/php"
K=$TMP/lk-inactive
lk_two() { lk_base; mk_build 8.3; }
out=$(LINK_PRE=lk_two links "$K" 8.4) || true
out=$(LINK_PRE=lk_two links "$K" 8.3) || true
check "links: an inactive version gets its own php8.3" link_to "$K/lbin/php8.3" "$K/root/8.3/bin/php"
check "links: an inactive version never takes /usr/local/bin/php" link_to "$K/lbin/php" "$K/root/8.4/bin/php"
check "links: an inactive version never takes /usr/bin/php" link_to "$K/usrbin/php" "$K/root/8.4/bin/php"
K=$TMP/lk-alt-pkg
lk_alt_pkg() {
  lk_base
  mkdir -p "${PHP_BUILD_ALT_LINK%/*}"
  ln -s /usr/bin/php8.3 "$PHP_BUILD_ALT_LINK"
  printf '/usr/bin/php8.3\n' > "$ALT_LIST"
}
out=$(LINK_PRE=lk_alt_pkg links "$K" 8.4) || true
check "alternatives: a package's selection is left alone" not file_has "$K/stub.log" "update-alternatives --set"
check "alternatives: no plain /usr/bin/php while the group exists" test ! -e "$K/usrbin/php" -a ! -L "$K/usrbin/php"
K=$TMP/lk-alt-ours
lk_alt_ours() {
  lk_base
  mkdir -p "${PHP_BUILD_ALT_LINK%/*}"
  ln -s "$PHP_BUILD_ROOT/8.4/bin/php" "$PHP_BUILD_ALT_LINK"
  printf '%s\n' "$PHP_BUILD_ROOT/8.2/bin/php" "$PHP_BUILD_ROOT/8.4/bin/php" > "$ALT_LIST"
}
out=$(LINK_PRE=lk_alt_ours links "$K" 8.4) || true
check "alternatives: our entry of a removed version is dropped" file_has "$K/stub.log" "update-alternatives --remove php $K/root/8.2/bin/php"
check "alternatives: a group of only our entries is removed" file_has "$K/stub.log" "update-alternatives --remove php $K/root/8.4/bin/php"
check "alternatives: then /usr/bin/php is a plain symlink" link_to "$K/usrbin/php" "$K/root/8.4/bin/php"
K=$TMP/lk-alt-move
lk_alt_move() {
  lk_base
  mk_build 8.3
  mkdir -p "${PHP_BUILD_ALT_LINK%/*}"
  ln -s "$PHP_BUILD_ROOT/8.3/bin/php" "$PHP_BUILD_ALT_LINK"
  printf '%s\n' /usr/bin/php8.3 "$PHP_BUILD_ROOT/8.3/bin/php" > "$ALT_LIST"
}
out=$(LINK_PRE=lk_alt_move links "$K" 8.4) || true
check "alternatives: our selected entry follows the active CLI (install)" \
  file_has "$K/stub.log" "update-alternatives --install $K/usrbin/php php $K/root/8.4/bin/php 1000"
check "alternatives: our selected entry follows the active CLI (set)" \
  file_has "$K/stub.log" "update-alternatives --set php $K/root/8.4/bin/php"
check "alternatives: the package entry stays registered" not file_has "$K/stub.log" "--remove php /usr/bin/php8.3"

unl() ( # PATH -> gone|kept
  sandbox "$TMP/unl"
  _pb_unlink_ours "$1"
  if [[ -e $1 || -L $1 ]]; then printf kept; else printf gone; fi
)
mkdir -p "$TMP/unl/x"
ln -sfn "$TMP/unl/root/8.4/bin/php" "$TMP/unl/x/ours"
ln -sfn /opt/operator/php "$TMP/unl/x/theirs"
printf '#!/bin/sh\n%s\n' "$PHP_BUILD_UNIT_MARK" > "$TMP/unl/x/wrapper"
printf '#!/bin/sh\necho operator\n' > "$TMP/unl/x/script"
check "unlink: a link into our root goes" test "$(unl "$TMP/unl/x/ours")" = gone
check "unlink: an operator's link stays" test "$(unl "$TMP/unl/x/theirs")" = kept
check "unlink: our wrapper file goes" test "$(unl "$TMP/unl/x/wrapper")" = gone
check "unlink: an operator's file stays" test "$(unl "$TMP/unl/x/script")" = kept

PG=$TMP/purge
purge() ( sandbox "$PG"; stub_host; [[ -n ${PURGE_PRE:-} ]] && "$PURGE_PRE"; php_build_purge "$@" 2>/dev/null )
pg_pre() { mk_build 8.3; mk_build 8.4; php_active_set 8.4; php_build_links 8.3; php_build_links 8.4; }
PURGE_PRE=pg_pre purge 8.3 || true
check "purge ver=8.3: its link goes" test ! -L "$PG/lbin/php8.3"
check "purge ver=8.3: its build goes" test ! -d "$PG/root/8.3"
check "purge ver=8.3: the active version keeps /usr/local/bin/php" link_to "$PG/lbin/php" "$PG/root/8.4/bin/php"
check "purge ver=8.3: the shared units stay (a build remains)" file_lacks "$PG/stub.log" "shared_units_if_last"
purge 8.4 || true
check "purge of the last version: /usr/local/bin/php goes" test ! -L "$PG/lbin/php"
check "purge of the last version: the active marker goes" test ! -e "$PG/etc/setup-active"
check "purge of the last version: LLVM release is asked" file_has "$PG/stub.log" "llvm_release php"
check "purge of the last version: last-consumer rule for the shared units" file_has "$PG/stub.log" "shared_units_if_last php"

# ---------------------------------------------------------------------------
# Versions and the active version
# ---------------------------------------------------------------------------
V=$TMP/vers
vers() ( sandbox "$V"; [[ -n ${VERS_PRE:-} ]] && "$VERS_PRE"; printf '%s|%s' "$(php_build_installed_versions | paste -sd' ' -)" "$(php_active_version)" )
v_pre() {
  mk_build 8.10; mk_build 8.4; mk_build 8.9
  mkdir -p "$PHP_BUILD_ROOT/8.2"; printf 'mode=clang\n' > "$PHP_BUILD_ROOT/8.2/build.info"
  mk_fake_php "$PHP_BUILD_ROOT/8.2/sbin/php-fpm"; mk_fake_php "$PHP_BUILD_ROOT/8.2/bin/php"
  mkdir -p "$PHP_BUILD_ROOT/8.7/sbin"
}
out=$(VERS_PRE=v_pre vers) || true
check "installed versions: version-sorted, 1.21 and incomplete builds left out" test "${out%|*}" = "8.4 8.9 8.10"
check "active version: none chosen among several without a marker" test "${out#*|}" = ""
lone() ( sandbox "$TMP/lone"; mk_build 8.4; php_active_version )
check "active version: the only build when there is no marker" test "$(lone)" = 8.4
stale_marker() ( sandbox "$TMP/stale"; mk_build 8.4; mk_build 8.5; printf '8.3\n' > "$PHP_ACTIVE_FILE"; php_active_version )
check "active version: a marker without a build does not count" test -z "$(stale_marker)"

# Every PHP link uses lld (libtool drops -fuse-ld=lld on some links): the
# driver adds it to linking calls only, and passes compile-only calls as is.
mkdir -p "$TMP/lld-case"
printf '#!/bin/sh\necho "$*"\n' > "$TMP/lld-case/fake-cc"; chmod 755 "$TMP/lld-case/fake-cc"
# shellcheck disable=SC2016  # expanded by tool_run's bash
lld_out=$(D=$TMP/lld-case tool_run 'lld_driver "$D/drv" "$D/fake-cc" "$D/fake-cc"
  printf "%s|%s|%s|%s" "$("$D/drv/clang" -shared -o x.so a.o)" "$("$D/drv/clang++" -o php a.o)" \
    "$("$D/drv/clang" -O2 -c a.c -o a.o)" "$("$D/drv/clang" -E conftest.c)"')
check "lld driver: links get -fuse-ld=lld, compiles do not" \
  test "$lld_out" = "-fuse-ld=lld -shared -o x.so a.o|-fuse-ld=lld -o php a.o|-O2 -c a.c -o a.o|-E conftest.c"
ossl_case() { FAKE_TAGS="openssl-3.5.4 openssl-3.6.1 openssl-4.1.0 openssl-4.2.0-alpha1" tool_run "latest_of openssl $1"; }
check "OpenSSL: PHP 8.1 gets the newest 3.x, 8.2 and newer the newest release" \
  test "$(ossl_case 8.1)|$(ossl_case 8.2)|$(ossl_case 8.5)" = "3.6.1|4.1.0|4.1.0"
check "the PHP configure uses the lld drivers" \
  file_has "$ROOT/tools/php-build.sh" 'CC="$work/lld-cc/clang" CXX="$work/lld-cc/clang++"'

# PHP 8.6 PECL compatibility (1.22.3): the zval_dtor alias and igbinary's
# zend_string callback name, for 8.6 and later only.
p86_case() { # VER [hash-has-bin2hex] -> "aliases igb-macro igb-uses" counts after two runs
  local d; d=$(mktemp -d "$TMP/p86.XXXXXX")
  mkdir -p "$d/Zend" "$d/ext/igbinary/src/php7" "$d/ext/hash"
  printf '#ifndef ZEND_PORTABILITY_H\n#define ZEND_PORTABILITY_H\n#endif\n' > "$d/Zend/zend_portability.h"
  if [[ -n ${2:-} ]]; then printf 'static inline void php_hash_bin2hex(char *o, const unsigned char *i, size_t n) {}\n' > "$d/ext/hash/php_hash.h"; else : > "$d/ext/hash/php_hash.h"; fi
  printf '#include "php.h"\n#include "igbinary.h"\nuser_func_name = PG(unserialize_callback_func);\nzend_error(E_WARNING, "%%s", PG(unserialize_callback_func));\n' \
    > "$d/ext/igbinary/src/php7/igbinary.c"
  tool_run "php86_pecl_compat '$1' '$d'; php86_pecl_compat '$1' '$d'" >/dev/null
  printf '%s %s %s' "$(grep -cE 'define (zval_dtor|XtOffsetOf|php_hash_bin2hex)\(' "$d/Zend/zend_portability.h")" \
    "$(grep -c '^#define IGB_UCF()' "$d/ext/igbinary/src/php7/igbinary.c")" \
    "$(grep -c 'IGB_UCF();\|"%s", IGB_UCF())' "$d/ext/igbinary/src/php7/igbinary.c")"
}
check "PHP 8.6 compat: the zval_dtor alias and the igbinary callback macro are added once" test "$(p86_case 8.6)" = "3 1 2"
check "PHP 8.6 compat: an alias the tree still defines is not added" test "$(p86_case 8.6 hash)" = "2 1 2"
check "PHP 8.6 compat: INI_STR and WRONG_PARAM_COUNT get their 8.5 definitions"   bash -c 'd=$(mktemp -d "$1/p86i.XXXXXX"); mkdir -p "$d/Zend"; : > "$d/Zend/zend_portability.h"
    PHP_BUILD_SOURCE_ONLY=1 bash -c "source \"\$1\"; source \"\$2\"; php86_pecl_compat 8.6 \"\$3\"" _ "$2" "$1/tool-stubs.sh" "$d" >/dev/null 2>&1
    grep -qxF "# define INI_STR(name) zend_ini_string_literal(name)" "$d/Zend/zend_portability.h" && grep -qxF "# define WRONG_PARAM_COUNT ZEND_WRONG_PARAM_COUNT()" "$d/Zend/zend_portability.h"' _ "$TMP" "$ROOT/tools/php-build.sh"
check "PHP 8.6 compat: nothing changes below 8.6" test "$(p86_case 8.5)" = "0 0 0"
check "PHP 8.6 compat: the macro follows the igbinary.h include" \
  bash -c 'd=$(mktemp -d "$1/p86o.XXXXXX"); mkdir -p "$d/Zend" "$d/ext/igbinary/src/php7"; : > "$d/Zend/zend_portability.h"
    printf "#include \"igbinary.h\"\nx = PG(unserialize_callback_func);\n" > "$d/ext/igbinary/src/php7/igbinary.c"
    PHP_BUILD_SOURCE_ONLY=1 bash -c "source \"\$1\"; source \"\$2\"; php86_pecl_compat 8.6 \"\$3\"" _ "$2" "$1/tool-stubs.sh" "$d" >/dev/null 2>&1
    sed -n 2p "$d/ext/igbinary/src/php7/igbinary.c" | grep -q "PHP 8.6 keeps the callback name"' _ "$TMP" "$ROOT/tools/php-build.sh"
# The daily refresh retries a missed BOLT pass on a current build, as nginx's
# does (1.22.4: the post-migration pass and a concurrent --optimize each
# found the other holding the build lock, and PHP stayed un-BOLTed).
check "refresh: a current build with bolt=0 and the unit on our build gets a BOLT pass" \
  bash -c 'sed -n "/^cmd_refresh()/,/^}/p" "$1" | grep -q "elif (( rc == 0 )) && \[\[ \$(info_get \"\$ver\" bolt) != 1 \]\] && unit_runs_build \"\$ver\"; then" && sed -n "/^cmd_refresh()/,/^}/p" "$1" | grep -qF "bash \"\$SELF\" bolt \"\$ver\" 60"' _ "$ROOT/tools/php-build.sh"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
