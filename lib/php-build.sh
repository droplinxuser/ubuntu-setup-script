# shellcheck shell=bash
# ---------------------------------------------------------------------------
# PHP compiled from source (1.22.0)
# ---------------------------------------------------------------------------
# Every PHP on a setup.sh host is built by tools/php-build.sh (installed as
# /usr/local/lib/setup-php/php-build.sh): php-fpm and the php CLI of one
# X.Y from one tree, static, with exactly this host's extension set.  No
# Sury or Ubuntu PHP package, no APT hook, no package fallback: a build that
# fails stops the install with its log path, and the running build keeps
# serving on --optimize and the daily refresh.  Measured: tests/stress-site/
# RESULTS.md (1.21.69-1.21.71 runs of the same recipe).
#
# This file owns:
#   - the extension set (php_build_effective_exts): base + every application
#     found on the host + PHP_EXT_EXTRA (--php ext=), add-only;
#   - php_build_ensure X.Y MODE CONTEXT OUT (build / activate / both);
#   - the /etc/php/X.Y layout (php_build_layout): php-fpm.conf, the managed
#     php.ini from the version's php.ini-production, conf.d (settings only;
#     00-setup-opcache.ini before 8.5), pool.d/www.conf from ONE master
#     template (configs/php/www.conf), the unit, tmpfiles and the links;
#   - sessions: /var/lib/php/sessions (www-data 0700, PHP's own GC:
#     gc_probability=1/gc_divisor=1000 from php.ini-production) and one
#     /var/lib/php/sessions-<user> per pool that runs as another user;
#   - one active version (/etc/php/setup-active) that owns the shared socket
#     /run/php/php-fpm.sock, /usr/local/bin/php and the CPU-change chain.
#
# It can also be sourced on its own (the tool's daily refresh sources the
# installed copy, ROOT/php-build-lib.sh): helpers that live elsewhere in
# setup.sh (app_type_at_root, nginx_vhost_root, persist_tuning_var, warn,
# php_upgrade_app_required_extensions) are used when present and replaced by
# local equivalents when not.

PHP_BUILD_ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
PHP_BUILD_TOOL="${PHP_BUILD_ROOT}/php-build.sh"
PHP_BUILD_CONF_FILE="${PHP_BUILD_ROOT}/php-build.conf"
PHP_BUILD_COMMON_FILE="${PHP_BUILD_ROOT}/build-common.sh"
PHP_BUILD_LIB_FILE="${PHP_BUILD_ROOT}/php-build-lib.sh"
PHP_BUILD_TEMPLATES="${PHP_BUILD_ROOT}/templates"
PHP_BUILD_LOG_DIR="${PHP_BUILD_ROOT}/logs"
PHP_BUILD_CACHE=${PHP_BUILD_CACHE:-/var/cache/setup-php-build}
PHP_BUILD_UNIT_DIR=${PHP_BUILD_UNIT_DIR:-/etc/systemd/system}
PHP_BUILD_REBUILD_UNIT="${PHP_BUILD_UNIT_DIR}/setup-php-build@.service"
PHP_BUILD_ETC=${PHP_BUILD_ETC:-/etc/php}
PHP_ACTIVE_FILE=${PHP_ACTIVE_FILE:-${PHP_BUILD_ETC}/setup-active}
PHP_BUILD_TMPFILES=${PHP_BUILD_TMPFILES:-/etc/tmpfiles.d/setup-php.conf}
PHP_BUILD_TMPFILES_POOLS=${PHP_BUILD_TMPFILES_POOLS:-/etc/tmpfiles.d/setup-php-pools.conf}
PHP_BUILD_LINK_BIN=${PHP_BUILD_LINK_BIN:-/usr/local/bin}
PHP_BUILD_LINK_SBIN=${PHP_BUILD_LINK_SBIN:-/usr/local/sbin}
PHP_BUILD_USR_BIN=${PHP_BUILD_USR_BIN:-/usr/bin}
PHP_BUILD_BACKUP_DIR=${PHP_BUILD_BACKUP_DIR:-/var/backups/setup-1.22}
PHP_SESSION_DIR=/var/lib/php/sessions
PHP_FPM_SOCKET=/run/php/php-fpm.sock
# Markers of the files this module writes (first line).  A file without one
# is the operator's or a package's.
PHP_BUILD_MARK="; Managed by setup.sh (php_build_layout)"
PHP_BUILD_UNIT_MARK="# Managed by setup.sh (php_build_layout)"
PHP_BUILD_OFF_MARK="; setup-1.22-off: "
# apt.llvm.org source the tools add (removed with the last build).
PHP_BUILD_LLVM_FILES=(/etc/apt/sources.list.d/setup-llvm.sources /etc/apt/preferences.d/setup-llvm.pref /etc/apt/keyrings/setup-llvm.asc)
PHP_BUILD_CHANGED=0

# ---------------------------------------------------------------------------
# Extension sets (REVISION 3)
# ---------------------------------------------------------------------------
# Always built, both SAPIs.  The always-on core of PHP itself (Core date
# hash json pcre Reflection SPL standard, random from 8.2, lexbor/uri from
# 8.5) is not configurable and not listed.  phar/posix/tokenizer/pcntl are
# for the CLI tools (wp-cli and composer are phars); pcntl only builds into
# the CLI (its config.m4), so php-fpm -m never lists it.  phar is in the FPM
# too: Sury's FPM loaded it as well, so it is no regression.  No readline
# (it would link libedit/readline from Ubuntu: php -a is line-mode only).
PHP_BASE_EXTS=(ctype curl dom fileinfo filter gd iconv libxml mbstring mysqlnd openssl opcache
  pcntl phar posix session simplexml tokenizer zlib)
# Unknown --domain app types (flarum, polr, lychee, shlink, sfs, php) and PHP
# roots that are none of the three applications: Laravel/Symfony/Flarum
# need xml/xmlwriter/zip, the SQLite-backed ones sqlite3/pdo_sqlite.  No
# intl: ICU doubles the binary every site shares (only --php ext=intl).
PHP_GENERIC_EXTS=(mysqli pdo_mysql pdo tokenizer bcmath sqlite3 pdo_sqlite xml xmlwriter zip exif)
# Everything tools/php-build.sh can build statically (no library outside
# the build recipe).  --php ext= and the migration's union accept these.
PHP_BUILDABLE_EXTS=(bcmath calendar ctype curl dom exif fileinfo filter ftp gd gettext gmp iconv
  igbinary intl libxml mbstring mysqli mysqlnd opcache openssl pcntl pdo pdo_mysql pdo_sqlite phar
  posix redis session shmop simplexml soap sockets sodium sqlite3 sysvmsg sysvsem sysvshm tokenizer
  xml xmlreader xmlwriter zip zlib)
# Modules every build carries (and SAPI modules): never part of a set.
PHP_CORE_EXTS=(core date hash json pcre random reflection spl standard lexbor uri cgi-fcgi)

_pb_warn() { if declare -F warn >/dev/null; then warn "$*"; else printf 'WARN: %s\n' "$*" >&2; fi; }
_pb_note() { if declare -F tune_note >/dev/null; then tune_note "$*"; fi; }
# OUT of php_build_ensure/php_build_start: a report function (opt_report,
# info) or, as lib/migrate.sh passes it, a file path the line is appended
# to.  Executing a path would lose every line, the failure reasons and log
# paths included.
_pb_report() { # out line
  local out=${1:-info}; shift
  if [[ $out == */* ]] && ! declare -F "$out" >/dev/null; then
    printf '%s\n' "$*" >> "$out" 2>/dev/null || printf '%s\n' "$*" >&2
  elif declare -F "$out" >/dev/null || command -v "$out" >/dev/null 2>&1; then
    "$out" "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}
_pb_valid_ver() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+$ ]]; }
_pb_ver_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$2" ]]; } # $1 >= $2
_pb_norm() { tr ',[:upper:]' ' [:lower:]' <<<"$*" | tr -s ' \t' '\n' | sed '/^$/d' | sort -u; }
_pb_csv() { _pb_norm "$@" | paste -sd, -; }

# The extensions APP needs from a minimal source build.  The single table is
# php_upgrade_app_requirements (lib/php-upgrade.sh); this copy only serves
# when that file is not loaded (the tool's standalone refresh), and the two
# must agree (tests compare them).
php_build_app_exts() { # app
  if declare -F php_upgrade_app_requirements >/dev/null; then
    case $1 in
      chevereto|wordpress|xenforo) php_upgrade_app_requirements "$1" | tr '[:upper:]' '[:lower:]'; return 0 ;;
    esac
  fi
  case $1 in
    chevereto) printf '%s\n' pdo_mysql pdo mysqli redis igbinary gd curl mbstring exif fileinfo xmlwriter zip ;;
    wordpress|wp) printf '%s\n' mysqli gd curl mbstring exif zip xml sodium ;;
    xenforo|xf) printf '%s\n' mysqli gd curl mbstring xml zip exif ;;
    # shlink's ID generator needs gmp (R62).
    shlink) printf '%s\n' "${PHP_GENERIC_EXTS[@]}" gmp ;;
    *) printf '%s\n' "${PHP_GENERIC_EXTS[@]}" ;;
  esac
}

php_build_ext_buildable() { [[ " ${PHP_BUILDABLE_EXTS[*]} " == *" ${1,,} "* ]]; }
php_build_buildable_exts() { printf '%s\n' "${PHP_BUILDABLE_EXTS[@]}"; }

# (The probe of what a Sury PHP loads is lib/migrate.sh's own,
# migrate_sury_modules: the only one, and the only Sury path here.)

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
_pb_app_type() { # root
  if declare -F app_type_at_root >/dev/null; then app_type_at_root "$1"; return 0; fi
  local r=$1
  [[ -n $r && -d $r ]] || return 0
  if [[ -f $r/wp-config.php && -f $r/wp-includes/version.php ]]; then printf 'wordpress'
  elif [[ -f $r/src/XF.php && -f $r/src/config.php ]]; then printf 'xenforo'
  elif [[ -f $r/app/env.php ]]; then printf 'chevereto'
  fi
}

_pb_vhost_root() { # file
  if declare -F nginx_vhost_root >/dev/null; then nginx_vhost_root "$1"; return 0; fi
  local root=""
  [[ -r ${1:-} ]] && root=$(awk '/^[[:space:]]*root[[:space:]]+/ { l = $0; sub(/^[[:space:]]*root[[:space:]]+/, "", l); sub(/;.*/, "", l); gsub(/^[[:space:]]+|[[:space:]]+$/, "", l); print l; exit }' "$1" 2>/dev/null)
  root=${root%\"}; root=${root#\"}
  printf '%s' "${root%/}"
}

# Web trees besides /etc/nginx whose vhosts count.  PHP_BUILD_EXTRA_WEB_TREES
# when set (empty: none).  Otherwise /etc/angie only during the 1.21 -> 1.22
# legacy window: while Angie still serves (web_server_state angie-legacy:
# the migration builds PHP before /etc/nginx exists) or while the migration
# state file has no complete=1.  A leftover /etc/angie after the migration
# (or one an operator kept) never adds its vhosts' sets to later builds;
# lib/migrate.sh owns the Angie paths and passes PHP_EXT_DETECT_TREE itself.
_pb_extra_web_trees() {
  local a=${PHP_BUILD_ANGIE_ETC:-/etc/angie} st=${MIGRATE_STATE_FILE:-}
  if [[ -n ${PHP_BUILD_EXTRA_WEB_TREES+x} ]]; then printf '%s' "$PHP_BUILD_EXTRA_WEB_TREES"; return 0; fi
  [[ -d $a/conf.d ]] || return 0
  if declare -F web_server_state >/dev/null && [[ $(web_server_state 2>/dev/null || true) == angie-legacy ]]; then
    printf '%s' "$a"; return 0
  fi
  if [[ -n $st && -f $st ]] && ! grep -qx 'complete=1' "$st" 2>/dev/null; then printf '%s' "$a"; fi
  return 0
}

# "app<TAB>root" for every PHP document root on the host: the vhosts of the
# live web tree (/etc/nginx, plus /etc/angie during the legacy window, see
# _pb_extra_web_trees), the /var/www walk (php_upgrade_app_roots),
# PHP_EXT_DETECT_TREE (another web tree, e.g. the migration's /etc/angie
# copy) and PHP_BUILD_DETECT_ROOTS (document roots).  A PHP root that is
# none of the three applications is reported as "php".
php_build_detect_apps() {
  local t file root app line extra
  local -A seen=()
  extra=$(_pb_extra_web_trees)
  {
    for t in "${PHP_BUILD_NGINX:-/etc/nginx}" ${PHP_EXT_DETECT_TREE:-} ${extra}; do
      [[ -d $t/conf.d ]] || continue
      for file in "$t"/conf.d/*.conf; do
        [[ -f $file ]] || continue
        root=$(_pb_vhost_root "$file")
        [[ -n $root && -d $root ]] || continue
        app=$(_pb_app_type "$root")
        if [[ -n $app ]]; then printf '%s\t%s\n' "$app" "$root"
        elif compgen -G "$root/*.php" >/dev/null; then printf 'php\t%s\n' "$root"
        fi
      done
    done
    if declare -F php_upgrade_app_roots >/dev/null; then php_upgrade_app_roots "${PHP_BUILD_WWW:-/var/www}" 2>/dev/null || true; fi
    for line in ${PHP_BUILD_DETECT_ROOTS:-}; do
      [[ -d $line ]] || continue
      app=$(_pb_app_type "$line")
      printf '%s\t%s\n' "${app:-php}" "$line"
    done
  } | while IFS=$'\t' read -r app root; do
    [[ -n $root && -z ${seen[$root]:-} ]] || continue
    seen[$root]=1
    printf '%s\t%s\n' "$app" "$root"
  done
}

# redis (+ igbinary) a configured site cannot run without: XenForo's own
# Redis cache provider, a WordPress object-cache drop-in that creates \Redis
# with no Predis fallback, or Object Cache Pro.  Same rules as
# php_upgrade_app_required_extensions' install mode (used when loaded).
_pb_redis_needed() { # app root
  local app=$1 root=$2 oc
  case $app in
    wordpress)
      oc=$root/wp-content/object-cache.php
      [[ -f $oc ]] || return 1
      { grep -qE 'new[[:space:]]+\\?Redis([^A-Za-z0-9_]|$)' "$oc" 2>/dev/null && ! grep -qi 'predis' "$oc" 2>/dev/null; } \
        || grep -qE 'RedisCachePro|Object Cache Pro' "$oc" 2>/dev/null ;;
    xenforo)
      [[ -f $root/src/config.php ]] && awk '!/^[[:space:]]*(#|\/\/|\*)/' "$root/src/config.php" 2>/dev/null \
        | grep -qiE "provider[^;]*(['\"]Redis['\"]|Doctrine[\\\\]+Common[\\\\]+Cache[\\\\]+RedisCache)" ;;
    *) return 1 ;;
  esac
}

# SQLite use under a PHP root: `new SQLite3`, a sqlite: PDO DSN, or a
# database file with the "SQLite format 3" magic, within 4 levels (vendor,
# node_modules, cache and .git skipped) and 20 seconds.  0 present, 1
# absent, 2 unknown (timeout or unreadable: the caller keeps what the
# current build has, R41).
_PB_SQLITE_SCAN=$(cat <<'EOF'
re=$'new[[:space:]]+\\\\?SQLite3[[:space:]]*\\(|["\']sqlite:'
prune=( \( -name vendor -o -name node_modules -o -name cache -o -name .git \) -prune -o )
if find "$1" -maxdepth 4 "${prune[@]}" -type f -name '*.php' -size -8M -print0 2>/dev/null \
     | xargs -0 -r grep -lE -- "$re" 2>/dev/null | head -n 1 | grep -q .; then
  echo hit; exit 0
fi
find "$1" -maxdepth 4 "${prune[@]}" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -print 2>/dev/null \
  | while IFS= read -r f; do
      if [[ $(head -c 15 "$f" 2>/dev/null) == "SQLite format 3" ]]; then echo hit; exit 0; fi
    done
exit 0
EOF
)
# One scan per root every 10 minutes: the set is computed several times per
# run (plan, ensure, --upgrade-php's gate), often in subshells, and a scan
# may take seconds.  The cache lives in /run (gone at boot).
PHP_BUILD_SCAN_CACHE=${PHP_BUILD_SCAN_CACHE:-/run/setup-php-sqlite-scan}
_pb_sqlite_scan() { # root
  local root=$1 rc=0 out now hit
  now=$(date +%s)
  hit=$(awk -F'\t' -v r="$root" -v now="$now" '$3 == r && now - $1 < 600 { c = $2 } END { if (c != "") print c }' "$PHP_BUILD_SCAN_CACHE" 2>/dev/null || true)
  if [[ $hit =~ ^[012]$ ]]; then return "$hit"; fi
  if [[ -r $root && -x $root ]]; then
    out=$(timeout "${PHP_BUILD_SCAN_TIMEOUT:-20}" bash -c "$_PB_SQLITE_SCAN" _ "$root" 2>/dev/null) || rc=$?
    if [[ $out == hit* ]]; then rc=0
    elif (( rc == 124 || rc == 137 )); then rc=2
    else rc=1
    fi
  else
    rc=2
  fi
  printf '%s\t%s\t%s\n' "$now" "$rc" "$root" >> "$PHP_BUILD_SCAN_CACHE" 2>/dev/null || true
  return "$rc"
}

_pb_want_file() { printf '%s/%s/exts.want' "$PHP_BUILD_ROOT" "$1"; }

# The set the current build of X.Y was made for (exts.want, else build.info).
_pb_prev_exts() { # X.Y
  local v=$1 f
  [[ -n $v ]] || return 0
  f=$(_pb_want_file "$v")
  if [[ -s $f ]]; then cat "$f"; return 0; fi
  f=$PHP_BUILD_ROOT/$v/build.info
  [[ -f $f ]] && awk -F= '$1 == "exts" { print substr($0, 6); exit }' "$f"
  return 0
}

# The "current build" input of X.Y's set: its own record, plus, when X.Y is
# not the active version, the active version's record.  --upgrade-php builds
# a new series that has no record yet (or a kept older one whose record
# predates what the active build gained since): the target must get the set
# the serving build has (design section 8), or every add-only membership of
# the current build (an earlier --domain app, the bare --php union, a past
# SQLite or Redis detection) would be dropped and the binding gate on the
# candidate's -m would abort the switch after the build.
_pb_prev_union() { # X.Y
  local v=$1 active
  _pb_prev_exts "$v"
  active=$(php_active_version 2>/dev/null || true)
  if [[ -n $active && $active != "$v" ]]; then printf ','; _pb_prev_exts "$active"; fi
  return 0
}

# The effective extension set of X.Y (the active version when omitted), as
# a sorted comma list on stdout.  Inputs, all unioned:
#   base; every (app, root) the host serves: the app's table row,
#   php_upgrade_app_required_extensions (install mode) and the redis rule,
#   sqlite3/pdo_sqlite when the root uses SQLite; "php" roots: the generic
#   set; PHP_BUILD_APPS (--domain app= types being created); PHP_EXT_EXTRA
#   (--php ext=, and the migration's union of what Sury loaded);
#   and the set the current build has (X.Y's record, and the active
#   version's when X.Y is another one: _pb_prev_union): detection only
#   ADDS (R11), so a transient miss (unmounted volume, unreadable config,
#   scan timeout) never shrinks a live build.  PHP_BUILD_EXT_RESET=1 (an explicit --php ext=none
#   / ext=-NAME, or a removed --domain) drops that last input.
# A host with no application and no previous build (a bare --php) gets the
# union of the three applications' sets, today's lean APP_MODULES list, so a
# site dropped in later does not 500.
# Fails (status 1, reason on stderr) when a name has no build path, unless
# SETUP_PHP_ALLOW_MISSING_EXT=1 (dropped with a warning).
php_build_effective_exts() { # [X.Y]
  local ver=${1:-} app root name prev any=0 rc
  local -A set=() prevset=()
  local -a bad=()
  [[ -n $ver ]] || ver=$(php_active_version 2>/dev/null || true)
  for name in "${PHP_BASE_EXTS[@]}"; do set[$name]=1; done
  prev=$(_pb_prev_union "$ver")
  prev=${prev#,}; prev=${prev%,}
  for name in $(_pb_norm "$prev"); do prevset[$name]=1; done
  while IFS=$'\t' read -r app root; do
    [[ -n $app ]] || continue
    any=1
    for name in $(php_build_app_exts "$app"); do set[${name,,}]=1; done
    if [[ $app != php ]] && declare -F php_upgrade_app_required_extensions >/dev/null; then
      for name in $(php_upgrade_app_required_extensions "$app" "$root" install 2>/dev/null); do set[${name,,}]=1; done
    fi
    if _pb_redis_needed "$app" "$root"; then set[redis]=1; set[igbinary]=1; fi
    if [[ $app != php ]]; then
      rc=0; _pb_sqlite_scan "$root" || rc=$?
      case $rc in
        0) set[sqlite3]=1; set[pdo_sqlite]=1 ;;
        2) [[ -n ${prevset[sqlite3]:-} ]] && { set[sqlite3]=1; set[pdo_sqlite]=1; }
           _pb_warn "PHP: SQLite scan of ${root} timed out or was unreadable; keeping the current build's SQLite modules" ;;
      esac
    fi
  done < <(php_build_detect_apps)
  for app in ${PHP_BUILD_APPS:-}; do
    any=1
    for name in $(php_build_app_exts "$app"); do set[${name,,}]=1; done
  done
  for name in $(_pb_norm "${PHP_EXT_EXTRA:-}"); do set[$name]=1; done
  if [[ ${PHP_BUILD_EXT_RESET:-0} != 1 ]]; then
    for name in "${!prevset[@]}"; do set[$name]=1; done
  fi
  if (( ! any )) && [[ -z $prev && -z ${PHP_EXT_EXTRA:-} ]]; then
    for app in wordpress xenforo chevereto; do
      for name in $(php_build_app_exts "$app"); do set[${name,,}]=1; done
    done
  fi
  # Dependencies the build needs spelled out.
  [[ -n ${set[redis]:-} ]] && set[igbinary]=1
  [[ -n ${set[pdo_mysql]:-} || -n ${set[pdo_sqlite]:-} ]] && set[pdo]=1
  [[ -n ${set[mysqli]:-} || -n ${set[pdo_mysql]:-} ]] && set[mysqlnd]=1
  for name in xml xmlreader xmlwriter simplexml dom soap; do [[ -n ${set[$name]:-} ]] && set[libxml]=1; done
  [[ -n ${set[xmlreader]:-} ]] && set[dom]=1
  for name in "${PHP_CORE_EXTS[@]}"; do unset "set[$name]"; done
  for name in "${!set[@]}"; do
    php_build_ext_buildable "$name" || bad+=("$name")
  done
  if (( ${#bad[@]} )); then
    if [[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} == 1 ]]; then
      _pb_warn "PHP: no source build path for ${bad[*]}; dropped (SETUP_PHP_ALLOW_MISSING_EXT=1)"
      for name in "${bad[@]}"; do unset "set[$name]"; done
    else
      printf 'PHP: no source build path for: %s (buildable: %s)\n' "${bad[*]}" "${PHP_BUILDABLE_EXTS[*]}" >&2
      return 1
    fi
  fi
  printf '%s\n' "${!set[@]}" | sort | paste -sd, -
}

# Build guard (R8): every requirement of every detected (app, root) must be
# in SET.  Prints the missing "app|root|ext" lines; status 1 when any.
php_build_requirements_missing() { # set-csv
  local s=",$1," app root name rc=0
  declare -F php_upgrade_app_required_extensions >/dev/null || return 0
  [[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} == 1 ]] && return 0
  while IFS=$'\t' read -r app root; do
    [[ -n $app && $app != php ]] || continue
    for name in $(php_upgrade_app_required_extensions "$app" "$root" install 2>/dev/null); do
      name=${name,,}
      [[ $s == *",$name,"* ]] && continue
      printf '%s|%s|%s\n' "$app" "$root" "$name"; rc=1
    done
  done < <(php_build_detect_apps)
  return "$rc"
}

# --php ext=LIST: names add to PHP_EXT_EXTRA (persisted), -NAME removes one,
# none clears it.  Removals set PHP_BUILD_EXT_RESET=1 so the next build may
# shrink.  Unknown names are refused before anything changes.
php_build_ext_option() { # list
  local list=${1,,} name cur
  local -A extra=()
  for name in $(_pb_norm "${PHP_EXT_EXTRA:-}"); do extra[$name]=1; done
  if [[ $list == none ]]; then
    extra=(); PHP_BUILD_EXT_RESET=1
  else
    for name in ${list//,/ }; do
      [[ -n $name ]] || continue
      if [[ $name == -* ]]; then
        unset "extra[${name#-}]"; PHP_BUILD_EXT_RESET=1
        continue
      fi
      php_build_ext_buildable "$name" || { printf 'PHP: --php ext=%s is not buildable from source (buildable: %s)\n' "$name" "${PHP_BUILDABLE_EXTS[*]}" >&2; return 1; }
      extra[$name]=1
    done
  fi
  cur=$( (( ${#extra[@]} )) && printf '%s\n' "${!extra[@]}" | sort | paste -sd, - || true)
  PHP_EXT_EXTRA=$cur
  export PHP_EXT_EXTRA PHP_BUILD_EXT_RESET
  if declare -F persist_tuning_var >/dev/null; then
    persist_tuning_var PHP_EXT_EXTRA "$cur"
    _pb_note "PHP: PHP_EXT_EXTRA=${cur:-(none)} persisted in /etc/default/setup-tuning"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Versions, paths, the active version
# ---------------------------------------------------------------------------
php_cli_bin() { printf '%s/%s/bin/php' "$PHP_BUILD_ROOT" "$1"; }
php_fpm_bin() { printf '%s/%s/sbin/php-fpm' "$PHP_BUILD_ROOT" "$1"; }

# Versions with a 1.22 build (binary + build.info; a 1.21 php-fpm-only
# build, mode=clang, does not count).  Never runs a PHP binary (a CLI built
# for the previous CPU would SIGILL during a CPU change, R60).
php_build_installed_versions() {
  local d v
  for d in "$PHP_BUILD_ROOT"/[0-9]*.[0-9]*; do
    v=${d##*/}
    _pb_valid_ver "$v" || continue
    [[ -x $d/sbin/php-fpm && -x $d/bin/php && -f $d/build.info ]] || continue
    grep -qx 'mode=clang' "$d/build.info" && continue
    printf '%s\n' "$v"
  done | sort -V
}

# The one version that serves (/etc/php/setup-active), else the only
# installed one.  Empty when there is none.
php_active_version() {
  local v="" n
  [[ -s $PHP_ACTIVE_FILE ]] && v=$(tr -d '[:space:]' < "$PHP_ACTIVE_FILE")
  if _pb_valid_ver "$v" && [[ -x $(php_fpm_bin "$v") ]]; then printf '%s' "$v"; return 0; fi
  n=$(php_build_installed_versions)
  [[ -n $n && $(wc -l <<<"$n") -eq 1 ]] && printf '%s' "$n"
  return 0
}

php_active_set() { # X.Y
  local tmp
  install -d -m 755 "${PHP_ACTIVE_FILE%/*}"
  tmp="${PHP_ACTIVE_FILE}.tmp.$$"
  printf '%s\n' "$1" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$PHP_ACTIVE_FILE"
}

# Newest released PHP series on php.net ("8.5"), and the newest release of a
# series ("8.5.3"; empty when php.net/GitHub list none).  The checkout's
# tool answers before anything is installed.
_pb_tool() {
  if [[ -n ${SCRIPT_DIR:-} && -f ${SCRIPT_DIR}/tools/php-build.sh ]]; then printf '%s' "${SCRIPT_DIR}/tools/php-build.sh"
  else printf '%s' "$PHP_BUILD_TOOL"; fi
}
php_build_latest_series() { bash "$(_pb_tool)" series 2>/dev/null || true; }
php_build_release() { bash "$(_pb_tool)" release "$1" 2>/dev/null || true; }

# php-fpm -t of the live (or a staged) /etc/php tree, exactly as the unit
# starts it: -y, -c and PHP_INI_SCAN_DIR (replacing any inherited value: the
# compiled scan dir is the CLI's).  Fails on "Unable to load"/"already
# loaded" warnings and when OPcache is missing.  Output on stdout.
# With an ETC_ROOT other than /etc/php (the staged tree tested before a
# cutover), the staged candidate ROOT/X.Y/staging/sbin/php-fpm is tested when
# one exists: that is the binary the cutover activates (after a build-only
# step it is the only new one), and the staged tree's 00-setup-opcache.ini
# points at the staged opcache.so (php_build_layout).
php_fpm_test() { # X.Y [ETC_ROOT]
  local ver=$1 e=${2:-$PHP_BUILD_ETC}/$1/fpm bin out rc=0
  bin=$(php_fpm_bin "$ver")
  if [[ -n ${2:-} && $2 != "$PHP_BUILD_ETC" && -x $PHP_BUILD_ROOT/$ver/staging/sbin/php-fpm ]]; then
    bin=$PHP_BUILD_ROOT/$ver/staging/sbin/php-fpm
  fi
  [[ -x $bin ]] || { printf 'no compiled php-fpm for PHP %s (%s)\n' "$ver" "$bin"; return 1; }
  out=$(PHP_INI_SCAN_DIR=$e/conf.d "$bin" -t -y "$e/php-fpm.conf" -c "$e/php.ini" 2>&1) || rc=$?
  out+=$'\n'$(PHP_INI_SCAN_DIR=$e/conf.d "$bin" -c "$e/php.ini" -m 2>&1 || true)
  printf '%s\n' "$out"
  (( rc == 0 )) || return 1
  if grep -qiE 'unable to load|already loaded|cannot load|PHP (Warning|Fatal)' <<<"$out"; then return 1; fi
  grep -qx 'Zend OPcache' <<<"$out" || { printf 'OPcache is not loaded with %s\n' "$e"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Support files, units, tmpfiles
# ---------------------------------------------------------------------------
_pb_install_if_changed() { # mode src dst
  [[ -f $2 ]] || return 1
  cmp -s "$2" "$3" 2>/dev/null && return 0
  install -m "$1" "$2" "$3.tmp.$$" && mv -f "$3.tmp.$$" "$3"
}

# Write TEXT to FILE (atomic, through a temp file in the same directory, so
# an existing symlink is replaced, never written through).  Status 0 when
# the file changed.
_pb_write() { # file mode text
  local f=$1 mode=$2 text=$3
  if [[ -f $f && ! -L $f ]] && [[ $(cat "$f") == "$text" ]]; then return 1; fi
  install -d -m 755 "${f%/*}"
  printf '%s\n' "$text" > "$f.tmp.$$" && chmod "$mode" "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  PHP_BUILD_CHANGED=1
  return 0
}

php_build_install_support() {
  local unit tmpf
  [[ -f ${SCRIPT_DIR:-}/tools/php-build.sh && -f ${SCRIPT_DIR:-}/tools/build-common.sh ]] \
    || { _pb_warn "PHP build: tools/php-build.sh or tools/build-common.sh is missing from this checkout"; return 1; }
  install -d -m 755 "$PHP_BUILD_ROOT" "$PHP_BUILD_TEMPLATES"
  install -d -m 750 "$PHP_BUILD_LOG_DIR"
  _pb_install_if_changed 755 "${SCRIPT_DIR}/tools/php-build.sh" "$PHP_BUILD_TOOL" || return 1
  _pb_install_if_changed 644 "${SCRIPT_DIR}/tools/build-common.sh" "$PHP_BUILD_COMMON_FILE" || return 1
  _pb_install_if_changed 644 "${SCRIPT_DIR}/lib/php-build.sh" "$PHP_BUILD_LIB_FILE" || return 1
  # The versions file beside setup.sh is the source of truth; the installed
  # copy is what the refresh and the rebuild units build from.
  _pb_install_if_changed 644 "${SCRIPT_DIR}/php-build.conf" "$PHP_BUILD_CONF_FILE" || true
  _pb_install_if_changed 644 "${SCRIPT_DIR}/configs/php/www.conf" "$PHP_BUILD_TEMPLATES/www.conf" || true
  _pb_install_if_changed 644 "${SCRIPT_DIR}/configs/php/custom_dan.ini" "$PHP_BUILD_TEMPLATES/custom_dan.ini" || true
  unit=$(php_build_rebuild_unit_text)
  if _pb_write "$PHP_BUILD_REBUILD_UNIT" 644 "$unit"; then systemctl daemon-reload 2>/dev/null || true; fi
  tmpf=$(php_build_tmpfiles_text)
  _pb_write "$PHP_BUILD_TMPFILES" 644 "$tmpf" || true
  # The CPU-change chain and the daily refresh timer are shared by every
  # compiled component (lib/nginx-build.sh): a host with PHP and no compiled
  # nginx needs them too, or a CPU change leaves PHP down for good.
  if declare -F setup_build_install_shared_units >/dev/null; then setup_build_install_shared_units || true; fi
  return 0
}

php_build_rebuild_unit_text() {
  cat <<EOF
${PHP_BUILD_UNIT_MARK}: rebuild PHP %i from source (the daily
# refresh starts it when a newer release or a changed extension set makes the
# build stale).  The running build serves until the new one passed verify.
[Unit]
Description=Rebuild PHP %i from source (setup.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PHP_BUILD_TOOL} rebuild %i
Nice=10
IOSchedulingClass=idle
OOMScoreAdjust=900
TimeoutStartSec=4h
EOF
}

# /run/php is the unit's RuntimeDirectory (root 0755, kept across restarts
# for the shared socket); tmpfiles re-creates it at boot for nginx's first
# connection attempts.  root, not www-data as design section 3 first said:
# RuntimeDirectory= chowns /run/php to the unit user (root) on every start,
# so a www-data line here would flip the owner at each boot.  The socket
# itself is www-data 0660 (listen.owner/listen.mode), as with Sury.  The sessions directory belongs to the www pool's
# user: PHP's own GC (gc_probability=1) must be able to list it, which
# Debian's root 1733 directory never allowed (Debian used a cron/timer).
php_build_tmpfiles_text() {
  cat <<EOF
${PHP_BUILD_MARK/;/#}: PHP runtime and session directories.
d /run/php 0755 root root -
d /var/lib/php 0755 root root -
d ${PHP_SESSION_DIR} 0700 www-data www-data -
EOF
}

php_build_unit_text() { # X.Y
  local ver=$1 e="${PHP_BUILD_ETC}/$1/fpm"
  cat <<EOF
${PHP_BUILD_UNIT_MARK}: PHP ${ver} FastCGI Process Manager compiled
# from source (${PHP_BUILD_ROOT}/${ver}).  Only the active version
# (${PHP_ACTIVE_FILE}) is enabled: it owns ${PHP_FPM_SOCKET}.
[Unit]
Description=The PHP ${ver} FastCGI Process Manager (compiled by setup.sh)
Documentation=man:php-fpm(8)
After=network.target

[Service]
Type=notify
PIDFile=/run/php/php${ver}-fpm.pid
Environment=PHP_INI_SCAN_DIR=${e}/conf.d
# CPU gate (a CPU change keeps the unit down until setup-build-cpu.service
# rebuilt it), missing managed files restored, php-fpm -t without warnings.
ExecStartPre=${PHP_BUILD_TOOL} pre ${ver}
ExecStart=${PHP_BUILD_ROOT}/${ver}/sbin/php-fpm --nodaemonize --fpm-config ${e}/php-fpm.conf -c ${e}/php.ini
ExecReload=/bin/kill -USR2 \$MAINPID
RuntimeDirectory=php
RuntimeDirectoryPreserve=yes
LimitNOFILE=524288
LimitCORE=0
# Stop gracefully: on SIGQUIT the workers finish their request and close
# their persistent MariaDB connections.  SIGTERM killed them mid-connection
# and MariaDB logged one "Aborted connection" per worker holding one (12 per
# restart for XenForo's p:localhost); same restart time (244 ms measured).
KillSignal=SIGQUIT
# A busy worker must not hold systemd in "deactivating" for 90 s.
TimeoutStopSec=15
# PHP-FPM writes its central logs below /var/www/logs.
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
}

# A bare php-fpmX.Y at a shell behaves like the unit: FPM's php.ini and
# scan dir (an operator's exported PHP_INI_SCAN_DIR for the CLI must not
# change what FPM loads) and its php-fpm.conf.
php_build_fpm_wrapper_text() { # X.Y
  local ver=$1 e="${PHP_BUILD_ETC}/$1/fpm"
  cat <<EOF
#!/bin/sh
${PHP_BUILD_UNIT_MARK}: php-fpm ${ver} with the unit's configuration.
case " \$* " in *" -c "*|*" -n "*|*" --php-ini "*|*" --no-php-ini "*) ;; *) set -- -c ${e}/php.ini "\$@" ;; esac
case " \$* " in *" -y "*|*" --fpm-config "*) ;; *) set -- -y ${e}/php-fpm.conf "\$@" ;; esac
PHP_INI_SCAN_DIR=${e}/conf.d
export PHP_INI_SCAN_DIR
exec ${PHP_BUILD_ROOT}/${ver}/sbin/php-fpm "\$@"
EOF
}

_pb_backup_dir() { # name -> created path
  local d="${PHP_BUILD_BACKUP_DIR}/$1"
  install -d -m 700 "$PHP_BUILD_BACKUP_DIR" "$d"
  printf '%s' "$d"
}

# Our unit file.  1.21's drop-ins go to the backups: zz-setup-build.conf
# (an ExecStart= override that would start the old php-fpm) and limits.conf
# (its settings are part of the unit now).  An operator's own drop-in stays.
php_build_unit_write() { # X.Y
  local ver=$1 f d b
  f="${PHP_BUILD_UNIT_DIR}/php${ver}-fpm.service"
  d="$f.d"
  for b in zz-setup-build.conf limits.conf; do
    [[ -f $d/$b ]] || continue
    mv -f "$d/$b" "$(_pb_backup_dir "php-${ver}-dropins-$(date -u +%Y%m%d-%H%M%S)")/$b"
    PHP_BUILD_CHANGED=1
  done
  rmdir "$d" 2>/dev/null || true
  _pb_write "$f" 644 "$(php_build_unit_text "$ver")" || true
  systemctl daemon-reload 2>/dev/null || true
}

php_build_unit_is_ours() { # X.Y
  grep -qF "$PHP_BUILD_UNIT_MARK" "${PHP_BUILD_UNIT_DIR}/php$1-fpm.service" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Links (R2.1, R6)
# ---------------------------------------------------------------------------
# Atomic symlink DST -> SRC; never replaces a regular file.
_pb_symlink() { # src dst
  local src=$1 dst=$2
  [[ -e $dst && ! -L $dst ]] && return 1
  [[ -L $dst && $(readlink "$dst") == "$src" ]] && return 0
  install -d -m 755 "${dst%/*}"
  ln -sfn "$src" "$dst.tmp.$$" && mv -Tf "$dst.tmp.$$" "$dst"
}

# A path in /usr/bin may be ours only when no package owns it (dpkg -S) and,
# for php, no alternatives link manages it (Sury's php-cli postrm would
# otherwise fight over it).  Until the Sury purge, the /usr/local links serve.
PHP_BUILD_ALT_LINK=${PHP_BUILD_ALT_LINK:-/etc/alternatives/php}
_pb_usr_free() { # path
  local p=$1
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$p" >/dev/null 2>&1; then return 1; fi
  [[ ${p##*/} == php ]] && { [[ -e $PHP_BUILD_ALT_LINK || -L $PHP_BUILD_ALT_LINK ]]; } && return 1
  [[ -e $p && ! -L $p ]] && return 1
  return 0
}

# The "php" alternatives group, when something registered one: a Sury or
# Ubuntu php-cli, or a 1.22 migration draft that registered our CLI (R2.1
# wants /usr/bin/php as a plain symlink, never an alternative).  For the
# active version CLI:
#   - every alternative is ours (no package left in the group): our entries
#     are removed, which deletes the group and its /usr/bin/php link, so the
#     plain symlink below takes over;
#   - the selected alternative is ours (a package is still in the group,
#     e.g. a deferred Sury purge): it is moved to CLI, so cron's
#     /usr/bin/php follows a switch instead of running the old series (and
#     never dangles once php_build_purge retired that series);
#   - a package's alternative is selected (the operator's choice): untouched.
# Our entries for versions without a CLI any more are always dropped.
_pb_alt_php_sync() { # active-cli
  local cli=$1 sel a mine=1 rc=0
  local -a alts=()
  [[ -e $PHP_BUILD_ALT_LINK || -L $PHP_BUILD_ALT_LINK ]] || return 0
  command -v update-alternatives >/dev/null 2>&1 || return 0
  mapfile -t alts < <(update-alternatives --list php 2>/dev/null || true)
  sel=$(readlink "$PHP_BUILD_ALT_LINK" 2>/dev/null || true)
  for a in "${alts[@]}"; do
    [[ -n $a ]] || continue
    if [[ $a == "$PHP_BUILD_ROOT"/* ]]; then
      if [[ ! -x $a ]]; then update-alternatives --remove php "$a" >/dev/null 2>&1 || rc=1; fi
    else
      mine=0
    fi
  done
  if (( mine )); then
    for a in "${alts[@]}"; do
      [[ $a == "$PHP_BUILD_ROOT"/* && -x $a ]] || continue
      update-alternatives --remove php "$a" >/dev/null 2>&1 || rc=1
    done
    return "$rc"
  fi
  if [[ $sel == "$PHP_BUILD_ROOT"/* && $sel != "$cli" ]]; then
    update-alternatives --install "${PHP_BUILD_USR_BIN}/php" php "$cli" 1000 >/dev/null 2>&1 || rc=1
    update-alternatives --set php "$cli" >/dev/null 2>&1 || rc=1
  fi
  return "$rc"
}

# Drop our alternative entry for one version's CLI (php_build_purge).
_pb_alt_php_remove() { # cli
  local list
  command -v update-alternatives >/dev/null 2>&1 || return 0
  list=$(update-alternatives --list php 2>/dev/null || true)
  grep -qxF -- "$1" <<<"$list" || return 0
  update-alternatives --remove php "$1" >/dev/null 2>&1 || true
}

# Links for X.Y: /usr/local/bin/phpX.Y, the /usr/local/sbin/php-fpmX.Y
# wrapper, and for the active version /usr/local/bin/php (always, also while
# dpkg still owns /usr/bin/php: php_cli_path falls back to it).
# /usr/bin/phpX.Y and /usr/bin/php (cron's PATH has no /usr/local/bin) only
# where dpkg no longer owns the path and, for /usr/bin/php, after the "php"
# alternatives group was reconciled (_pb_alt_php_sync).  Plain symlinks: the
# CLI has no CPU gate (accepted risk R60: until the CPU chain finishes after
# a hardware change, a cron run can hit SIGILL; operators never change
# CPUs).  Idempotent; the migration reruns it after the Sury purge, and
# --upgrade-php (php_upgrade_set_active) after every switch.
php_build_links() { # X.Y
  local ver=$1 cli wrap rc=0
  cli=$(php_cli_bin "$ver")
  [[ -x $cli ]] || return 1
  _pb_symlink "$cli" "${PHP_BUILD_LINK_BIN}/php${ver}" || rc=1
  wrap="${PHP_BUILD_LINK_SBIN}/php-fpm${ver}"
  if [[ ! -e $wrap || -L $wrap ]] || grep -qF "$PHP_BUILD_UNIT_MARK" "$wrap" 2>/dev/null; then
    _pb_write "$wrap" 755 "$(php_build_fpm_wrapper_text "$ver")" || true
  fi
  _pb_usr_free "${PHP_BUILD_USR_BIN}/php${ver}" && { _pb_symlink "$cli" "${PHP_BUILD_USR_BIN}/php${ver}" || rc=1; }
  if [[ $(php_active_version) == "$ver" ]]; then
    _pb_symlink "$cli" "${PHP_BUILD_LINK_BIN}/php" || rc=1
    _pb_alt_php_sync "$cli" || _pb_warn "PHP ${ver}: the php alternatives group could not be reconciled (update-alternatives --display php)"
    _pb_usr_free "${PHP_BUILD_USR_BIN}/php" && { _pb_symlink "$cli" "${PHP_BUILD_USR_BIN}/php" || rc=1; }
  fi
  return "$rc"
}

# Remove a link only when it points into our root (never an operator's).
_pb_unlink_ours() { # path
  local p=$1 t
  [[ -L $p ]] || { [[ -f $p ]] && grep -qF "$PHP_BUILD_UNIT_MARK" "$p" 2>/dev/null && rm -f "$p"; return 0; }
  t=$(readlink "$p")
  [[ $t == "$PHP_BUILD_ROOT"/* ]] && rm -f "$p"
  return 0
}

# ---------------------------------------------------------------------------
# /etc/php/X.Y layout
# ---------------------------------------------------------------------------
# php.ini-production of X.Y: installed by the build, or still staged.
_pb_ini_production() { # X.Y
  local f
  for f in "$PHP_BUILD_ROOT/$1/share/php.ini-production" "$PHP_BUILD_ROOT/$1/staging/share/php.ini-production"; do
    [[ -f $f ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

php_build_php_ini_text() { # X.Y fpm|cli
  local ver=$1 sapi=$2 prod
  prod=$(_pb_ini_production "$ver") || return 1
  printf '%s: PHP %s %s php.ini = php.ini-production\n' "$PHP_BUILD_MARK" "$ver" "$sapi"
  printf '; of this release plus the settings at the end.  Local settings belong in\n'
  printf '; conf.d/*.ini (custom_dan.ini, zz-setup-optimize.ini, your own files).\n\n'
  cat "$prod"
  printf '\n; ---- setup.sh ----\n[Session]\n'
  printf '; PHP collects expired sessions itself (gc_probability=1/gc_divisor=1000\n'
  printf '; above); the directory belongs to the www pool user (0700).\n'
  printf 'session.save_path = "%s"\n' "$PHP_SESSION_DIR"
  if [[ $sapi == cli ]]; then
    printf '[PHP]\n; As Debian'"'"'s CLI php.ini: wp-cli, composer and XenForo cmd.php jobs.\nmemory_limit = -1\n'
  fi
}

php_build_fpm_conf_text() { # X.Y [ETC_ROOT]
  local ver=$1 etc=${2:-$PHP_BUILD_ETC}
  cat <<EOF
${PHP_BUILD_MARK}: PHP ${ver} FPM global settings.
; Pools live in pool.d/*.conf ([www] comes from configs/php/www.conf).
[global]
pid = /run/php/php${ver}-fpm.pid
error_log = /var/www/logs/php/php-fpm.log
log_level = error

emergency_restart_threshold = 100
emergency_restart_interval = 1m
process_control_timeout = 10s

rlimit_files = 524288
rlimit_core = 0

include = ${etc}/${ver}/fpm/pool.d/*.conf
EOF
}

php_build_opcache_ini_text() { # X.Y [opcache.so]
  printf '%s: OPcache before PHP 8.5 is a shared module of\n; this build (compiled in from 8.5).  Settings: conf.d/zz-setup-optimize.ini.\nzend_extension=%s\n' \
    "$PHP_BUILD_MARK" "${2:-$PHP_BUILD_ROOT/$1/lib/opcache.so}"
}

# Keys of a managed www.conf that the tuner or the operator owns: kept when
# the file is rewritten from a newer template (listen also carries the
# operator's TCP listener, R24).
PHP_BUILD_POOL_KEEP_RE='^(user|group|listen(\..*)?|pm(\..*)?|slowlog|access\..*)$'

# The [www] pool from TEMPLATE, keeping the KEEP keys of CURRENT and every
# directive CURRENT has that the template does not (the session and
# open_basedir lines, an access log, a status path).
php_build_pool_merge() { # template current
  awk -v keep="$PHP_BUILD_POOL_KEEP_RE" '
    function key(l,   k) { k = l; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); return k }
    function val(l,   v) { v = l; sub(/^[^=]*=/, "", v); return v }
    FNR == NR {
      if ($0 ~ /^[[:space:]]*\[/) { s = $0; gsub(/^[[:space:]]*\[|\].*$/, "", s); next }
      if (s != "www" || $0 ~ /^[[:space:]]*[;#]/ || $0 !~ /=/) next
      k = key($0); if (!(k in cur)) order[++n] = k
      cur[k] = $0; next
    }
    $0 !~ /^[[:space:]]*[;#]/ && $0 ~ /=/ && $0 !~ /^[[:space:]]*\[/ {
      k = key($0); intpl[k] = 1
      if ((k in cur) && k ~ keep) { print cur[k]; next }
    }
    { print }
    END {
      for (i = 1; i <= n; i++) if (!(order[i] in intpl)) { if (!hdr) { print ""; print "; Kept from the previous www.conf"; hdr = 1 } print cur[order[i]] }
    }' "$2" "$1"
}

# Pool files adopted from a package or 1.21 (www_8x.conf) can open with a
# full [global] section.  php-fpm.conf includes pool.d last, so those values
# would silently override php-fpm.conf's: the section is commented out
# (marker "; setup-1.22-off: ", the file backed up once first) so php-fpm.conf
# stays the only source of global settings.
php_build_pool_strip_global() { # X.Y [ETC_ROOT]
  local ver=$1 e=${2:-$PHP_BUILD_ETC}/$1 pool tmp b=""
  for pool in "$e"/fpm/pool.d/*.conf; do
    [[ -f $pool && ! -L $pool ]] || continue
    grep -qiE '^[[:space:]]*\[global\][[:space:]]*([;#].*)?$' "$pool" || continue
    [[ -n $b ]] || b=$(_pb_backup_dir "php-${ver}-pool-global-$(date -u +%Y%m%d-%H%M%S)")
    cp -a "$pool" "$b/"
    tmp="${pool%/*}/.${pool##*/}.tmp.$$"
    if awk -v m="$PHP_BUILD_OFF_MARK" '
        /^[[:space:]]*\[[^]]+\]/ { g = (tolower($0) ~ /^[[:space:]]*\[global\]/) }
        g && $0 !~ /^[[:space:]]*([;#].*)?$/ { print m $0; next }
        { print }' "$pool" > "$tmp"; then
      chmod --reference="$pool" "$tmp" 2>/dev/null || chmod 644 "$tmp"
      mv -f "$tmp" "$pool"
      _pb_warn "PHP ${ver}: ${pool} had a [global] section; commented out (php-fpm.conf holds the global settings; original in ${b})"
      PHP_BUILD_CHANGED=1
    else
      rm -f "$tmp"
    fi
  done
  return 0
}

# A managed file: written when absent, ours, or (once backed up) a package's
# or an earlier hand-made one.  Status 0 when it changed.
_pb_write_managed() { # X.Y file text
  local ver=$1 f=$2 text=$3 b
  if [[ -f $f ]] && ! head -n 1 "$f" | grep -qF "$PHP_BUILD_MARK"; then
    b=$(_pb_backup_dir "php-${ver}-replaced")
    [[ -e $b/${f//\//_} ]] || cp -a "$f" "$b/${f//\//_}"
  fi
  _pb_write "$f" 644 "$text"
}

# conf.d holds settings only.  Package entries go to the backups: symlinks
# into mods-available (or dangling ones), files dpkg owns, 1.21's
# setup-disabled-modules list.  An operator's .ini stays, with its
# extension=/zend_extension= lines commented out under the marker
# "; setup-1.22-off: " (the static build has every extension compiled in; a
# .so line prints "Unable to load" on every start and cron run).  Our
# 00-setup-opcache.ini is the only extension line kept.  Rewrites go through
# a temp file and mv, so a symlink to an operator file becomes a regular
# copy instead of being written through.  Runs on every layout (a deferred
# Sury purge can re-create symlinks); the 1.22 migration calls it at cutover.
_pb_dpkg_owned() { command -v dpkg >/dev/null 2>&1 && dpkg -S "$1" >/dev/null 2>&1; }

php_confd_convert() { # X.Y [ETC_ROOT]
  local ver=$1 e=${2:-$PHP_BUILD_ETC}/$1 sapi d f base b="" stamp tmp move
  stamp=$(date -u +%Y%m%d-%H%M%S)
  for sapi in fpm cli; do
    d=$e/$sapi/conf.d
    [[ -d $d ]] || continue
    for f in "$d"/* "$e/$sapi/setup-disabled-modules"; do
      [[ -e $f || -L $f ]] || continue
      base=${f##*/}
      move=0
      if [[ $base == setup-disabled-modules ]]; then move=1
      elif [[ -L $f ]] && { [[ $(readlink "$f") == *mods-available* ]] || [[ ! -e $f ]]; }; then move=1
      elif [[ -f $f && ! -L $f && $base != 00-setup-opcache.ini ]] && _pb_dpkg_owned "$f"; then move=1
      fi
      if (( move )); then
        [[ -n $b ]] || b=$(_pb_backup_dir "php-${ver}-confd-${stamp}")
        install -d -m 700 "$b/$sapi"
        mv -f "$f" "$b/$sapi/"
        PHP_BUILD_CHANGED=1
        continue
      fi
      [[ -f $f && $base == *.ini && $base != 00-setup-opcache.ini ]] || continue
      grep -qE '^[[:space:]]*(zend_)?extension[[:space:]]*=' "$f" || continue
      tmp="$d/.${base}.tmp.$$"
      if sed -E "s/^([[:space:]]*(zend_)?extension[[:space:]]*=)/${PHP_BUILD_OFF_MARK}\\1/" "$f" > "$tmp"; then
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        mv -f "$tmp" "$f"
        PHP_BUILD_CHANGED=1
      else
        rm -f "$tmp"
      fi
    done
  done
  return 0
}

# Pools that run as another user than www-data and keep sessions in files
# without a save_path of their own get /var/lib/php/sessions-<user> (0700,
# that user) as php_admin_value in the pool; an open_basedir of that pool
# gets the directory appended.  A value the operator set is never touched
# (R85/R93).  setup-php-pools.conf (tmpfiles) is then rebuilt from every
# such directive of every version's pools, so a removed pool loses its line.
php_build_session_pools() { # X.Y
  local ver=$1 pool sect user group sp handler dir tmp v lines="" seen_users=" "
  for pool in "$PHP_BUILD_ETC/$ver"/fpm/pool.d/*.conf; do
    [[ -f $pool ]] || continue
    while IFS='|' read -r sect user group sp handler _; do
      [[ -n $sect && -n $user && $user != www-data && $user != *'$'* ]] || continue
      [[ -z $sp ]] || continue
      [[ -z $handler || $handler == files ]] || continue
      dir="${PHP_SESSION_DIR}-${user}"
      tmp="${pool%/*}/.${pool##*/}.tmp.$$"
      if awk -v sect="$sect" -v dir="$dir" '
          function flush() { if (insec && !added) { print "php_admin_value[session.save_path] = " dir; added = 1 } }
          /^[[:space:]]*\[/ { flush(); t = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*([;#].*)?$/, "", t); insec = (t == sect); if (insec) added = 0 }
          insec && /^[[:space:]]*php(_admin)?_value\[open_basedir\][[:space:]]*=/ && index($0, dir) == 0 {
            if ($0 ~ /"[[:space:]]*$/) sub(/"[[:space:]]*$/, ":" dir "\""); else { sub(/[[:space:]]*$/, ""); $0 = $0 ":" dir } }
          { print }
          END { flush() }' "$pool" > "$tmp"; then
        chmod --reference="$pool" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        mv -f "$tmp" "$pool"
        _pb_note "PHP ${ver}: pool [${sect}] runs as ${user}: its sessions live in ${dir}"
        PHP_BUILD_CHANGED=1
      else
        rm -f "$tmp"
      fi
    done < <(awk '
      function out() { if (sect != "" && sect != "global") print sect "|" user "|" group "|" sp "|" h "|" obd }
      /^[[:space:]]*[;#]/ { next }
      /^[[:space:]]*\[[^]]+\]/ { out(); sect = $0; gsub(/^[[:space:]]*\[|\].*$/, "", sect); user = group = sp = h = obd = ""; next }
      /=/ { k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); v = $0; sub(/^[^=]*=/, "", v); gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", v)
            if (k == "user") user = v; else if (k == "group") group = v
            else if (k ~ /^php(_admin)?_value\[session\.save_path\]$/) sp = v
            else if (k ~ /^php(_admin)?_value\[session\.save_handler\]$/) h = v
            else if (k ~ /^php(_admin)?_value\[open_basedir\]$/) obd = v }
      END { out() }' "$pool")
  done
  for v in $( { php_build_installed_versions; printf '%s\n' "$ver"; } | sort -Vu); do
    for pool in "$PHP_BUILD_ETC/$v"/fpm/pool.d/*.conf; do
      [[ -f $pool ]] || continue
      while IFS= read -r dir; do
        user=${dir#"${PHP_SESSION_DIR}"-}
        [[ -n $user && $seen_users != *" $user "* ]] || continue
        seen_users+="$user "
        group=$(id -gn "$user" 2>/dev/null || printf '%s' "$user")
        lines+="d ${dir} 0700 ${user} ${group} -"$'\n'
      done < <(sed -nE "s|^[[:space:]]*php_admin_value\[session\.save_path\][[:space:]]*=[[:space:]]*(${PHP_SESSION_DIR}-[A-Za-z0-9._-]+)[[:space:]]*$|\1|p" "$pool")
    done
  done
  if [[ -n $lines ]]; then
    _pb_write "$PHP_BUILD_TMPFILES_POOLS" 644 "${PHP_BUILD_MARK/;/#}: session directories of pools that run as other users.
${lines%$'\n'}" || true
  else
    rm -f "$PHP_BUILD_TMPFILES_POOLS"
  fi
  return 0
}

# Apply tmpfiles now (not only at boot) and check the sessions directory.
php_build_tmpfiles_apply() {
  local -a f=("$PHP_BUILD_TMPFILES")
  [[ -f $PHP_BUILD_TMPFILES_POOLS ]] && f+=("$PHP_BUILD_TMPFILES_POOLS")
  systemd-tmpfiles --create "${f[@]}" >/dev/null 2>&1 || true
  if [[ $(stat -c '%U:%G %a' "$PHP_SESSION_DIR" 2>/dev/null) != "www-data:www-data 700" ]]; then
    _pb_warn "PHP: ${PHP_SESSION_DIR} is not www-data:www-data 0700 after systemd-tmpfiles ($(stat -c '%U:%G %a' "$PHP_SESSION_DIR" 2>/dev/null || echo missing))"
    return 1
  fi
  return 0
}

# Managed copy of /etc/php/X.Y for `php-build.sh pre` (R16): a purge or a
# crash between a purge and the re-lay must not leave the unit without
# php-fpm.conf or php.ini.  Regular files only.
php_build_golden_refresh() { # X.Y
  local ver=$1 src="${PHP_BUILD_ETC}/$1" gold="${PHP_BUILD_ROOT}/$1/etc-golden"
  [[ -d $src/fpm && -d ${PHP_BUILD_ROOT}/$ver ]] || return 0
  rm -rf "$gold.new"; install -d -m 700 "$gold.new"
  ( cd "$src" && find fpm cli -type f \( -name '*.ini' -o -name '*.conf' \) -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do install -d -m 755 "$gold.new/${f%/*}"; cp -p "$f" "$gold.new/$f"; done ) || true
  rm -rf "$gold"; mv "$gold.new" "$gold"
}

# Write /etc/php/X.Y for the compiled build:
#   php-fpm.conf (ours), {fpm,cli}/php.ini (php.ini-production of the
#   version + session path; the CLI also memory_limit=-1), conf.d converted
#   (php_confd_convert) plus 00-setup-opcache.ini before 8.5 (removed from
#   8.5: never carried from another version, R56), custom_dan.ini (fpm),
#   pool.d/www.conf when absent or ours (marker line: rewritten from the
#   template keeping the tuner's keys); a pool without the marker, Sury's,
#   1.21's or an operator's, is adopted as it is (the tuner normalises the
#   managed keys); a [global] section in any pool file is commented out,
#   per-user session dirs, tmpfiles, the unit and the links.
# ETC_ROOT renders the same tree elsewhere (the migration tests the build in
# ROOT/X.Y/staging-etc with php_fpm_test X.Y ETC_ROOT before cutover); then
# no unit, link or tmpfiles is touched.
# Refuses while a package php-fpm of X.Y still runs: its reload would load
# the stripped conf.d (R15).  The migration stops it first.
php_build_layout() { # X.Y [fresh|adopt|auto] [ETC_ROOT]
  local ver=$1 how=${2:-auto} etc=${3:-$PHP_BUILD_ETC} real=0 e text tpl sapi frag pool
  _pb_valid_ver "$ver" || { _pb_warn "php_build_layout: bad version '${ver}'"; return 1; }
  [[ $etc == "$PHP_BUILD_ETC" ]] && real=1
  e=$etc/$ver
  if (( real )) && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && ! php_build_unit_is_ours "$ver"; then
    _pb_warn "PHP ${ver}: the package php${ver}-fpm still serves; /etc/php/${ver} is laid out only after it stopped (migration step 9)"
    return 1
  fi
  _pb_ini_production "$ver" >/dev/null || { _pb_warn "PHP ${ver}: no build (php.ini-production missing); build first"; return 1; }
  if [[ $how == auto ]]; then
    how=fresh
    compgen -G "$e/fpm/pool.d/*.conf" >/dev/null && how=adopt
  fi
  install -d -m 755 "$e/fpm/conf.d" "$e/fpm/pool.d" "$e/cli/conf.d"
  php_confd_convert "$ver" "$etc"
  for sapi in fpm cli; do
    text=$(php_build_php_ini_text "$ver" "$sapi") || return 1
    _pb_write_managed "$ver" "$e/$sapi/php.ini" "$text" || true
    frag="$e/$sapi/conf.d/00-setup-opcache.ini"
    if _pb_ver_ge "$ver" 8.5; then
      [[ -e $frag || -L $frag ]] && { rm -f "$frag"; PHP_BUILD_CHANGED=1; }
    elif (( ! real )) && [[ -f $PHP_BUILD_ROOT/$ver/staging/lib/opcache.so ]]; then
      # A staged tree is tested with the staged candidate (php_fpm_test X.Y
      # ETC_ROOT), which needs its own opcache.so, not the active build's.
      _pb_write "$frag" 644 "$(php_build_opcache_ini_text "$ver" "$PHP_BUILD_ROOT/$ver/staging/lib/opcache.so")" || true
    else
      _pb_write "$frag" 644 "$(php_build_opcache_ini_text "$ver")" || true
    fi
  done
  _pb_write_managed "$ver" "$e/fpm/php-fpm.conf" "$(php_build_fpm_conf_text "$ver" "$etc")" || true
  # Adopted pools must not carry their own [global] (see the function).
  php_build_pool_strip_global "$ver" "$etc"
  # www.conf: written when absent; rewritten from the template when it is
  # ours (first line PHP_BUILD_MARK), keeping the tuner's and operator's
  # keys (php_build_pool_merge), so a template change reaches every host.
  # A pool without the marker (an operator's, Sury's, 1.21's) is adopted as
  # it is: the tuner normalises the managed keys.
  pool="$e/fpm/pool.d/www.conf"
  if [[ ! -f $pool ]] || { [[ ! -L $pool ]] && head -n 1 "$pool" | grep -qF "$PHP_BUILD_MARK"; }; then
    tpl=${SCRIPT_DIR:-}/configs/php/www.conf
    [[ -f $tpl ]] || tpl=$PHP_BUILD_TEMPLATES/www.conf
    [[ -f $tpl ]] || { _pb_warn "PHP ${ver}: pool template configs/php/www.conf not found"; return 1; }
    if [[ -f $pool ]]; then
      text=$(php_build_pool_merge "$tpl" "$pool") || { _pb_warn "PHP ${ver}: could not merge ${pool} with the template; left as it is"; text=""; }
      [[ -z $text ]] || _pb_write "$pool" 644 "$text" || true
    else
      _pb_write "$pool" 644 "$(cat "$tpl")" || true
    fi
  fi
  if (( real )) && declare -F sync_php_ini_template >/dev/null; then
    sync_php_ini_template "$ver" || true
  elif [[ ! -f $e/fpm/conf.d/custom_dan.ini ]]; then
    if [[ -f $PHP_BUILD_ETC/$ver/fpm/conf.d/custom_dan.ini ]]; then cp -p "$PHP_BUILD_ETC/$ver/fpm/conf.d/custom_dan.ini" "$e/fpm/conf.d/"
    elif [[ -f ${SCRIPT_DIR:-}/configs/php/custom_dan.ini ]]; then install -m 644 "${SCRIPT_DIR}/configs/php/custom_dan.ini" "$e/fpm/conf.d/custom_dan.ini"
    elif [[ -f $PHP_BUILD_TEMPLATES/custom_dan.ini ]]; then install -m 644 "$PHP_BUILD_TEMPLATES/custom_dan.ini" "$e/fpm/conf.d/custom_dan.ini"
    fi
  fi
  (( real )) || return 0
  # php-fpm.conf and www.conf log below /var/www/logs/php: FPM refuses to
  # start when the directory is missing.
  if declare -F ensure_log_dirs >/dev/null; then ensure_log_dirs; else install -d -m 755 /var/www/logs/php; fi
  php_build_session_pools "$ver"
  _pb_write "$PHP_BUILD_TMPFILES" 644 "$(php_build_tmpfiles_text)" || true
  php_build_tmpfiles_apply || true
  php_build_unit_write "$ver"
  php_build_links "$ver" || _pb_warn "PHP ${ver}: some links could not be written (an existing file is in the way)"
  php_build_golden_refresh "$ver"
  _pb_note "PHP ${ver}: /etc/php/${ver} laid out for the compiled build (${how})"
  return 0
}

# ---------------------------------------------------------------------------
# Build / activate
# ---------------------------------------------------------------------------
# The build is current (the tool's `check`).  PHP_BUILD_CHECK_OUT says why
# not.  A version that cannot be looked up (offline) counts as current.
PHP_BUILD_CHECK_OUT=""
php_build_current() { # X.Y
  local ver=$1 rc=0
  PHP_BUILD_CHECK_OUT=""
  [[ -f $PHP_BUILD_ROOT/$ver/build.info && -x $(php_fpm_bin "$ver") ]] || { PHP_BUILD_CHECK_OUT="no build"; return 1; }
  PHP_BUILD_CHECK_OUT=$("$PHP_BUILD_TOOL" check "$ver" 2>&1) || rc=$?
  (( rc != 10 ))
}

php_build_bolted() { grep -qx 'bolt=1' "$PHP_BUILD_ROOT/$1/build.info" 2>/dev/null; }

# Run the tool's build with its log in ROOT/logs (kept on failure, the last
# 5 per version).  The tool lowers its own priority (nice 10, idle IO, OOM
# score 900) and takes the build lock.  Prints the log path.
_pb_run_build() { # X.Y
  local ver=$1 log
  log="${PHP_BUILD_LOG_DIR}/php-${ver}-$(date -u +%Y%m%d-%H%M%S).log"
  printf '%s' "$log"
  # The tool's own messages (and its reason on failure) land in the same log.
  PHP_BUILD_LOG_FILE=$log "$PHP_BUILD_TOOL" build "$ver" >>"$log" 2>&1
}

# Enable and start (or restart, when something changed) the active version;
# disable --now every other version of ours (one version owns the shared
# socket, R61).  Verifies: active, php_fpm_test, socket.
php_build_start() { # X.Y OUT
  local ver=$1 out=${2:-info} v active sock
  active=$(php_active_version)
  for v in $(php_build_installed_versions); do
    [[ $v == "$active" ]] && continue
    php_build_unit_is_ours "$v" || continue
    if systemctl is-enabled --quiet "php${v}-fpm" 2>/dev/null || systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
      systemctl disable --now "php${v}-fpm" >/dev/null 2>&1 || true
      _pb_report "$out" "- PHP ${v}: disabled (PHP ${active} is the active version and owns ${PHP_FPM_SOCKET}; ${v} is kept for --upgrade-php=${v})"
    fi
  done
  [[ $ver == "$active" ]] || return 0
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "php${ver}-fpm" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
    (( PHP_BUILD_CHANGED )) || return 0
    systemctl restart "php${ver}-fpm" || { _pb_report "$out" "- **FAILED** PHP ${ver}: php${ver}-fpm did not restart (systemctl status php${ver}-fpm)"; return 1; }
  else
    systemctl reset-failed "php${ver}-fpm" >/dev/null 2>&1 || true
    systemctl start "php${ver}-fpm" || { _pb_report "$out" "- **FAILED** PHP ${ver}: php${ver}-fpm did not start (systemctl status php${ver}-fpm)"; return 1; }
  fi
  sleep 1
  systemctl is-active --quiet "php${ver}-fpm" || { _pb_report "$out" "- **FAILED** PHP ${ver}: php${ver}-fpm is not running"; return 1; }
  php_fpm_test "$ver" >/dev/null || { _pb_report "$out" "- **FAILED** PHP ${ver}: php-fpm -t reports problems ($(php_fpm_test "$ver" | grep -iE 'error|warning|unable|not loaded' | head -n 1))"; return 1; }
  sock=$(awk -F= '/^[[:space:]]*listen[[:space:]]*=/ { v = $2; gsub(/[[:space:]]/, "", v); print v; exit }' "${PHP_BUILD_ETC}/${ver}/fpm/pool.d/www.conf" 2>/dev/null)
  if [[ $sock == /* ]] && [[ ! -S $sock ]]; then
    _pb_report "$out" "- **FAILED** PHP ${ver}: ${sock} does not exist after the start"; return 1
  fi
  return 0
}

# Bring PHP X.Y to its build.
#   MODE     build-only  build into staging when stale (the running build,
#                        or Sury during the migration, keeps serving)
#            activate    swap a staged build in (restarts our running unit),
#                        write the unit; install/optimize also lay out
#                        /etc/php/X.Y and start the active version
#            full        both (default)
#   CONTEXT  install | optimize (also BOLT under traffic) | upgrade |
#            migrate (activate after the package unit stopped; layout,
#            enable and start are the caller's) | refresh
#   OUT      report function (opt_report, info)
# Returns 1 on any failure, with the reason and log path reported.
php_build_ensure() { # X.Y MODE CONTEXT OUT
  local ver=$1 mode=${2:-full} context=${3:-optimize} out=${4:-info} exts log rc=0 missing
  _pb_valid_ver "$ver" || { _pb_report "$out" "- **FAILED** PHP: bad version '${ver}'"; return 1; }
  case $mode in build-only|activate|full) ;; *) _pb_report "$out" "- **FAILED** PHP ${ver}: unknown mode ${mode}"; return 1 ;; esac
  if declare -F mem_gate_allows >/dev/null && ! mem_gate_allows php; then
    _pb_report "$out" "- PHP ${ver}: refused on this host (under the 4 GB class: nginx only)"
    return 1
  fi
  php_build_install_support || { _pb_report "$out" "- **FAILED** PHP ${ver}: build support files missing from this checkout"; return 1; }
  PHP_BUILD_CHANGED=0
  if [[ $mode != activate ]]; then
    # --php ext=LIST of this run (lib/validate.sh php_ext_request_apply:
    # records PHP_EXT_EXTRA and PHP_BUILD_EXT_RESET; idempotent, a no-op in
    # a dry run or without ext=).  Applied here, in the shell that computes
    # the set, so the request takes effect whichever step builds first
    # (install_php runs this in run_service's subshell, --upgrade-php in an
    # async subshell): a caller that already applied it changes nothing.
    # The migration's union goes through PHP_EXT_EXTRA itself.
    if [[ $context != migrate ]] && declare -F php_ext_request_apply >/dev/null; then
      php_ext_request_apply
    fi
    exts=$(php_build_effective_exts "$ver" 2>"${PHP_BUILD_LOG_DIR}/exts-${ver}.err") \
      || { _pb_report "$out" "- **FAILED** PHP ${ver}: $(cat "${PHP_BUILD_LOG_DIR}/exts-${ver}.err" 2>/dev/null)"; return 1; }
    # Warnings of a set that was computed (an uncertain SQLite scan, a
    # dropped unbuildable name) reach the report: R11/R41 say keep AND
    # report, and the file is deleted next.
    # (setup.sh's warn adds a timestamp and colours: stripped.)
    local wline
    while IFS= read -r wline; do
      [[ -n $wline ]] && _pb_report "$out" "- PHP ${ver}: ${wline}"
    done < <(sed -E 's/\x1b\[[0-9;]*m//g; s/^.*\[WARN\][[:space:]]*//; s/^WARN: //' "${PHP_BUILD_LOG_DIR}/exts-${ver}.err" 2>/dev/null || true)
    rm -f "${PHP_BUILD_LOG_DIR}/exts-${ver}.err"
    if missing=$(php_build_requirements_missing "$exts"); then :; else
      _pb_report "$out" "- **FAILED** PHP ${ver}: the extension set lacks application requirements: $(tr '\n' ' ' <<<"$missing")"
      return 1
    fi
    install -d -m 755 "$PHP_BUILD_ROOT/$ver"
    printf '%s\n' "$exts" > "$(_pb_want_file "$ver").tmp" && mv -f "$(_pb_want_file "$ver").tmp" "$(_pb_want_file "$ver")"
    _pb_report "$out" "- PHP ${ver}: extension set ${exts//,/ }"
    [[ ,$exts, == *,intl,* ]] && _pb_report "$out" "- PHP ${ver}: intl is in the set: every site on PHP ${ver} shares the ICU-enlarged binary (measured: ~2x size, 4.5x data-TLB misses, slower XenForo pages)"
    if ! php_build_current "$ver"; then
      [[ -n $PHP_BUILD_CHECK_OUT ]] && _pb_report "$out" "- PHP ${ver}: build ${PHP_BUILD_CHECK_OUT}"
      _pb_report "$out" "- PHP ${ver}: building FPM + CLI from upstream sources (about 5-8 minutes with the libraries, 3-4 when only PHP changed)"
      if log=$(_pb_run_build "$ver"); then
        _pb_report "$out" "- PHP ${ver}: built and verified (log: ${log})"
      else
        _pb_report "$out" "- **FAILED** PHP ${ver} build; nothing was changed (log: ${log})"
        tail -n 8 "$log" >&2 2>/dev/null || true
        return 1
      fi
    else
      _pb_report "$out" "- PHP ${ver}: build is current ($("$PHP_BUILD_TOOL" status "$ver" 2>/dev/null | sed -n 1p))"
    fi
  fi
  [[ $mode == build-only ]] && return 0
  if [[ -d $PHP_BUILD_ROOT/$ver/staging ]]; then
    if ! "$PHP_BUILD_TOOL" activate "$ver" >>"${PHP_BUILD_LOG_DIR}/activate-${ver}.log" 2>&1; then
      _pb_report "$out" "- **FAILED** PHP ${ver}: activation ($(tail -n 1 "${PHP_BUILD_LOG_DIR}/activate-${ver}.log" 2>/dev/null))"
      return 1
    fi
    PHP_BUILD_CHANGED=1
    _pb_report "$out" "- PHP ${ver}: $("$PHP_BUILD_TOOL" status "$ver" 2>/dev/null | sed -n 1p)"
  fi
  [[ -x $(php_fpm_bin "$ver") ]] || { _pb_report "$out" "- **FAILED** PHP ${ver}: no compiled build to activate"; return 1; }
  php_build_unit_write "$ver"
  case $context in
    install|optimize|refresh)
      # --php makes its version the active one; --optimize only fills a
      # missing marker (switching is --upgrade-php's job).
      if [[ $context == install || -z $(php_active_version) ]]; then php_active_set "$ver"; fi
      php_build_layout "$ver" || { _pb_report "$out" "- **FAILED** PHP ${ver}: /etc/php/${ver} layout"; return 1; }
      php_build_start "$ver" "$out" || return 1
      ;;
    *) return 0 ;;
  esac
  # Never inside an --upgrade-php switch (PHP_UPGRADE_IN_FLIGHT=1: its
  # closing tuner pass runs this with the build lock held): the 60 s sample,
  # the binary swap and the restart would land before the switch is
  # verified, and a BOLT problem would trigger the rollback (R2.5/R14).  The
  # next --optimize or the refresh rebuild BOLTs the new version.
  if [[ $context == optimize && $mode == full && ${PHP_UPGRADE_IN_FLIGHT:-0} == 1 ]] && ! php_build_bolted "$ver"; then
    _pb_report "$out" "- PHP ${ver}: BOLT deferred to the next --optimize (not during the --upgrade-php switch)"
  elif [[ $context == optimize && $mode == full && $(php_active_version) == "$ver" ]] && ! php_build_bolted "$ver" \
     && [[ ${SETUP_PHP_BUILD_BOLT:-1} == 1 ]]; then
    "$PHP_BUILD_TOOL" bolt "$ver" "${SETUP_PHP_BUILD_BOLT_SECONDS:-60}" > "${PHP_BUILD_LOG_DIR}/bolt-${ver}.log" 2>&1 || rc=$?
    case $rc in
      0) _pb_report "$out" "- PHP ${ver}: BOLT applied to php-fpm from live traffic" ;;
      3) _pb_report "$out" "- PHP ${ver}: BOLT skipped (too little traffic in the sample, or another build held the lock); the next --optimize under load retries" ;;
      *) _pb_report "$out" "- PHP ${ver}: BOLT not applied ($(tail -n 1 "${PHP_BUILD_LOG_DIR}/bolt-${ver}.log" 2>/dev/null)); the ThinLTO build keeps serving" ;;
    esac
    rc=0
  fi
  php_build_golden_refresh "$ver"
  return "$rc"
}

# Dry-run line(s).
php_build_plan() { # [X.Y]
  local ver=${1:-} exts
  [[ -n $ver ]] || ver=$(php_active_version)
  exts=$(php_build_effective_exts "$ver" 2>/dev/null || true)
  printf 'PHP %s FPM + CLI compiled from upstream sources (versions in php-build.conf); extensions: %s; BOLT under traffic on --optimize' \
    "${ver:-<newest php.net release>}" "${exts:-<computed at run time>}"
}

# --purge php [ver=X.Y]: stop, disable and remove our unit, the build and
# its links for that version (every version without ver=).  /etc/php, logs
# and session data stay (R81).  /usr/local/bin/php and the active marker
# move to the newest remaining version.  The tool, template unit, tmpfiles
# and caches go with the last version; LLVM with the last build of any kind.
php_build_purge() { # [X.Y]
  local only=${1:-} v f left marked=""
  for f in "$PHP_BUILD_ROOT"/[0-9]*.[0-9]* "$PHP_BUILD_UNIT_DIR"/php*-fpm.service; do
    [[ -e $f ]] || continue
    v=${f##*/}; v=${v#php}; v=${v%-fpm.service}
    _pb_valid_ver "$v" || continue
    [[ -n $only && $only != "$v" ]] && continue
    if php_build_unit_is_ours "$v"; then
      systemctl disable --now "php${v}-fpm" >/dev/null 2>&1 || true
      rm -f "$PHP_BUILD_UNIT_DIR/php${v}-fpm.service"
    fi
    systemctl stop "setup-php-build@${v}.service" >/dev/null 2>&1 || true
    _pb_alt_php_remove "$(php_cli_bin "$v")"
    _pb_unlink_ours "${PHP_BUILD_LINK_BIN}/php${v}"
    _pb_unlink_ours "${PHP_BUILD_LINK_SBIN}/php-fpm${v}"
    _pb_unlink_ours "${PHP_BUILD_USR_BIN}/php${v}"
    rm -rf "${PHP_BUILD_ROOT:?}/${v}"
  done
  left=$(php_build_installed_versions | tail -n 1)
  if [[ -n $left ]]; then
    [[ -s $PHP_ACTIVE_FILE ]] && marked=$(tr -d '[:space:]' < "$PHP_ACTIVE_FILE")
    if [[ -z $marked || ! -x $(php_fpm_bin "$marked") ]]; then
      php_active_set "$left"
    fi
    php_build_links "$(php_active_version)" || true
  else
    _pb_unlink_ours "${PHP_BUILD_LINK_BIN}/php"
    _pb_unlink_ours "${PHP_BUILD_USR_BIN}/php"
    rm -f "$PHP_ACTIVE_FILE"
    rm -f "$PHP_BUILD_REBUILD_UNIT" "$PHP_BUILD_TOOL" "$PHP_BUILD_CONF_FILE" "$PHP_BUILD_COMMON_FILE" "$PHP_BUILD_LIB_FILE" \
      "$PHP_BUILD_TMPFILES" "$PHP_BUILD_TMPFILES_POOLS"
    rm -rf "$PHP_BUILD_TEMPLATES" "${PHP_BUILD_CACHE:?}"
    setup_build_llvm_release php
    # Last-consumer rule (R81): the CPU chain, the refresh timer and the
    # build lock go with the last remaining build of any kind.  Their
    # ExecStart names a build-common.sh copy; on a PHP-only host (or after
    # '--purge nginx,valkey') this purge removes the last one.
    if declare -F setup_build_remove_shared_units_if_last >/dev/null; then
      setup_build_remove_shared_units_if_last php
    fi
    # Logs stay (operator evidence); the root goes when only they are left.
    rmdir "$PHP_BUILD_ROOT" 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 'php*-fpm.service' >/dev/null 2>&1 || true
  return 0
}

# The LLVM toolchain (apt.llvm.org source, /opt/setup-llvm) is shared by every
# compiled build (nginx, PHP, Valkey): only the last one removed takes it.
setup_build_llvm_release() { # php|nginx|valkey: the build being removed
  local me=$1 n=${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx} k=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}
  if [[ $me != php ]] && compgen -G "${PHP_BUILD_ROOT}/[0-9]*/build.info" >/dev/null; then return 0; fi
  # Each component's own record: nginx keeps build.info in ROOT/build/,
  # Valkey in ROOT/build.info (lib/valkey-build.sh VALKEY_BUILD_INFO); the
  # binary counts too (a build whose record was lost still needs LLVM to
  # rebuild).  A leftover cache or work directory does not.
  if [[ $me != nginx ]] && [[ -f $n/build/build.info || -f $n/build.info || -x $n/sbin/nginx ]]; then return 0; fi
  if [[ $me != valkey ]] && [[ -f $k/build.info || -x $k/bin/valkey-server ]]; then return 0; fi
  _pb_llvm_packages_purge
  rm -f "${PHP_BUILD_LLVM_FILES[@]}"; rm -rf /opt/setup-llvm
}

# The clang-N/lld-N/llvm-N/bolt-N packages the tools installed from
# apt.llvm.org go with the source: left behind, they would stay installed
# with no update source (R81).  Only packages whose installed version is an
# apt.llvm.org build ("~++" in the version: Ubuntu's own clang-N never has
# it, and an operator's Ubuntu toolchain stays), and only when apt's dry run
# removes nothing else (the collateral guard: another package depending on
# LLVM keeps it).  Best effort: a refusal is reported, never fatal.
_pb_llvm_packages_purge() {
  local d n p v sim
  local -a pkgs=() collateral=()
  command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 || return 0
  for d in /usr/lib/llvm-[0-9]*; do
    [[ -d $d ]] || continue
    n=${d##*/llvm-}
    [[ $n =~ ^[0-9]+$ ]] || continue
    for p in "clang-$n" "lld-$n" "llvm-$n" "bolt-$n"; do
      v=$(dpkg-query -W -f='${Status} ${Version}' "$p" 2>/dev/null || true)
      [[ $v == "install ok installed "* && $v == *'~++'* ]] && pkgs+=("$p")
    done
  done
  (( ${#pkgs[@]} )) || return 0
  sim=$(apt-get -s purge "${pkgs[@]}" 2>&1) || { _pb_warn "LLVM: apt cannot purge ${pkgs[*]}; left installed"; return 0; }
  mapfile -t collateral < <(printf '%s\n' "$sim" | awk '/^(Remv|Purg) / { sub(/:.*/, "", $2); print $2 }' \
    | grep -vxF -f <(printf '%s\n' "${pkgs[@]}") | sort -u || true)
  if (( ${#collateral[@]} )); then
    _pb_warn "LLVM: purging ${pkgs[*]} would also remove ${collateral[*]}; the LLVM packages stay installed (remove them by hand once nothing needs them)"
    return 0
  fi
  apt-get -o DPkg::Lock::Timeout=900 purge -y "${pkgs[@]}" >/dev/null 2>&1 \
    || _pb_warn "LLVM: apt-get purge ${pkgs[*]} failed; left installed"
  return 0
}
