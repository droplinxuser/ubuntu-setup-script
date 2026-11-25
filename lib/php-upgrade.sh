# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# =============================================================================
# PHP version switch (--upgrade-php=X.Y), source builds only (1.22.0)
# =============================================================================
# PHP runs from our own builds (lib/php-build.sh, tools/php-build.sh): one
# tree per series under /usr/local/lib/setup-php/X.Y, config in /etc/php/X.Y,
# unit /etc/systemd/system/phpX.Y-fpm.service.  Exactly one version is active
# (marker /etc/php/setup-active) and owns the shared socket
# /run/php/php-fpm.sock; nothing here uses apt, dpkg or the Sury repository.
#
# Order matters:
#   1. refuse while the 1.22 migration still has a PHP part pending, on an
#      Angie-legacy web tier and below the 4 GB class (nothing is touched);
#   2. application gate: every detected site's hard requirements must be in
#      the extension set the target is built with;
#   3. build X.Y (FPM + CLI) with the current effective extension set while
#      the current version keeps serving (several minutes; no downtime);
#   4. lay out /etc/php/X.Y: the current version's pools (listen lines kept,
#      the adopt rule of R24), operator conf.d fragments and the managed
#      setting files, then php_build_layout writes php.ini, php-fpm.conf,
#      our conf.d files, the unit and tmpfiles; `php-fpm -t` must pass clean
#      before anything stops;
#   5. handover: stop the current unit, start X.Y on the same socket(s) (the
#      only window without PHP, about a second), switch the active marker and
#      the php links, run the shared tuner, reload nginx;
#   6. verify (unit, every pool listener, php-fpm -t without load warnings,
#      OPcache in FPM and CLI, an HTTP probe of every PHP vhost that answered
#      before) and roll back to the previous version on a hard failure;
#   7. on success enable X.Y, disable (not mask) the previous version and keep
#      its build and /etc/php tree for one rollback (`--upgrade-php=OLD`
#      switches back, rebuilding only when its build is stale); versions older
#      than that are retired.
#
# Only PHP (and the services that depend on its socket) is touched: the OS
# profile, MariaDB, Valkey and Elasticsearch are left to --optimize.

PHP_UPGRADE_MANIFEST_DIR=""
# Version the switch started from; on_exit (lib/restart.sh) rolls back to it
# while PHP_UPGRADE_IN_FLIGHT is set.
PHP_UPGRADE_OLD_VERSION=""
# upgrade (CUR -> other series), rebuild (target already active) or
# rollback (target is the kept previous build).
PHP_UPGRADE_MODE=""
# Listener of the old version's www pool, for callers that render a pool from
# the template (tune_php_fpm_version); the switch itself carries the old pool
# file over verbatim, so the socket path never changes under nginx.
PHP_UPGRADE_WWW_LISTEN=""
# Modules the previous version loads that the target build will not carry
# ("ext (reason)"), reported as ATTENTION.
PHP_UPGRADE_SKIPPED=()
# "app|root|ext" requirements the target cannot satisfy (refused unless
# SETUP_PHP_ALLOW_MISSING_EXT=1) and requirements the current PHP does not
# load either (not a loss, reported only).
PHP_UPGRADE_BLOCKERS=()
PHP_UPGRADE_NOT_LOADED=()
PHP_UPGRADE_LOADED_FROM=""
# Pools of another running PHP version that bind a listener the target takes
# over ("version<TAB>pool<TAB>listen").
PHP_UPGRADE_CONFLICTS=()
# Files carried from the old tree (relative to /etc/php/X.Y).
PHP_UPGRADE_CARRIED=()
# Effective extension set of the target build (lower-case, one per line).
PHP_UPGRADE_EXTS=""
# HTTP probe: "host<TAB>root<TAB>status" lines before and after the switch.
PHP_UPGRADE_PROBE_BEFORE=()
PHP_UPGRADE_PROBE_FAILED=()
PHP_UPGRADE_PROBE_OK=0
PHP_UPGRADE_NGINX_ACTIVE=0
PHP_UPGRADE_OPTIMIZE_OK=0
PHP_UPGRADE_VERIFY_OK=0
# 1 when a verify failure is one the switch must roll back for (unit down,
# listener missing, php-fpm -t warnings, a vhost that answered before now
# answers 5xx); soft findings (JIT profile) only mark the run ATTENTION.
PHP_UPGRADE_VERIFY_HARD=0
# The pre-existing /etc/php/<target> tree (a kept previous version), moved into
# the manifest before the new tree is laid out; the rollback puts it back.
PHP_UPGRADE_PRIOR_TREE=""
# 1 once this run started writing /etc/php/<target>: only then do the
# rollback and the abort move that tree away (a kept tree is never touched
# by a failed build).
PHP_UPGRADE_TREE_GENERATED=0
# What PHP_UPGRADE_IN_FLIGHT=1 protects, so php_upgrade_rollback (called by
# on_exit in lib/restart.sh after a die, set -e or signal) undoes exactly
# that: "prepare" (a kept /etc/php/<target> may sit in the manifest and a
# half-generated tree in its place; the current version still serves) or
# "handover" (the current version was stopped; it must be started again).
PHP_UPGRADE_PHASE=""
# fd holding /run/setup-build.lock from the build to the commit (R65(c)(e)):
# the refresh chain (build_lock_try) and BOLT skip, the CPU chain and the
# setup-php-build@ rebuild unit wait, so none of them restarts or rebuilds a
# version in the middle of the handover.
PHP_UPGRADE_LOCK_FD=""
# Handover window output (php_upgrade_window_begin): saved stdout/stderr and
# the previous HUP/PIPE dispositions.
PHP_UPGRADE_WINDOW_TEE=0
PHP_UPGRADE_SAVED_OUT=""
PHP_UPGRADE_SAVED_ERR=""
PHP_UPGRADE_SAVED_TRAPS=""
# Result of php_upgrade_single_unit after the commit (report).
PHP_UPGRADE_UNITS_OK="not checked"

PHP_UPGRADE_ACTIVE_MARKER=/etc/php/setup-active
# Oldest series the build recipe supports (php-build.conf); 8.1 is past
# upstream end of life but still buildable, so it stays reachable for
# applications pinned to it.
PHP_UPGRADE_MIN_SERIES=8.1

php_upgrade_root() { printf '%s' "${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}"; }

# Series with a setup build, oldest first.  Read from the build layout, never
# by running a binary: after a CPU change a stale CLI can SIGILL until the
# CPU chain has rebuilt it (R60).  lib/validate.sh calls this too.
php_upgrade_installed_versions() {
  if declare -F php_build_installed_versions >/dev/null; then
    php_build_installed_versions 2>/dev/null | sed -nE '/^[0-9]+\.[0-9]+$/p' | sort -Vu
    return 0
  fi
  local d root
  root=$(php_upgrade_root)
  for d in "$root"/[0-9]*.[0-9]*; do
    [[ -f $d/build.info && -x $d/sbin/php-fpm ]] && printf '%s\n' "${d##*/}"
  done | sort -Vu
  return 0
}

# True when VER has a setup build.
php_upgrade_fpm_installed() {
  local ver=$1 v
  while IFS= read -r v; do
    [[ $v == "$ver" ]] && return 0
  done < <(php_upgrade_installed_versions)
  return 1
}

# The version that owns the shared socket: the active marker (B's reader),
# else the pool nginx talks to.
php_upgrade_current_version() {
  local v=""
  if declare -F php_active_version >/dev/null; then
    v=$(php_active_version 2>/dev/null || true)
  elif [[ -r $PHP_UPGRADE_ACTIVE_MARKER ]]; then
    v=$(sed -n '1{s/[[:space:]]//g;p;}' "$PHP_UPGRADE_ACTIVE_MARKER" 2>/dev/null || true)
  fi
  [[ $v =~ ^[0-9]+\.[0-9]+$ ]] || v=$(php_primary_version 2>/dev/null || true)
  [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

php_upgrade_fpm_bin() {
  if declare -F php_fpm_bin >/dev/null; then php_fpm_bin "$1"; return; fi
  printf '%s/%s/sbin/php-fpm' "$(php_upgrade_root)" "$1"
}

php_upgrade_cli_bin() {
  if declare -F php_cli_bin >/dev/null; then php_cli_bin "$1"; return; fi
  printf '%s/%s/bin/php' "$(php_upgrade_root)" "$1"
}

# Operator .ini fragments of one version tree (ROOT=/etc/php/X.Y), printed as
# "SAPI/conf.d/name.ini<TAB>other-conf.d-dirs-that-symlink-it".  Regular files
# only: Sury's package entries were symlinks into mods-available (the
# migration moves those away), and the files setup generates are skipped
# because the target writes its own: custom_dan.ini and zz-setup-optimize.ini
# are carried separately as managed settings, and the OPcache loader is never
# carried (it names the version's own opcache.so, R56).  lib/migrate.sh reads
# the same list.
php_upgrade_custom_inis() {
  local root=$1 base d f d2 links
  [[ -d $root ]] || return 0
  for d in fpm/conf.d cli/conf.d; do
    [[ -d "$root/$d" ]] || continue
    for f in "$root/$d"/*.ini; do
      [[ -f $f && ! -L $f ]] || continue
      base=${f##*/}
      case $base in
        custom_dan.ini|zz-setup-optimize.ini|zzz-audit.ini) continue ;;
        00-setup-opcache.ini|10-opcache.ini|*-setup-*.ini) continue ;;
      esac
      links=""
      for d2 in fpm/conf.d cli/conf.d; do
        [[ $d2 == "$d" ]] && continue
        [[ -L "$root/$d2/$base" ]] && links+="${links:+,}$d2"
      done
      printf '%s/%s\t%s\n' "$d" "$base" "$links"
    done
  done
  return 0
}

# Extra FPM pools of one version tree (every pool.d/*.conf except www.conf),
# one file name per line.
php_upgrade_custom_pools() {
  local root=$1
  [[ -d "$root/fpm/pool.d" ]] || return 0
  find "$root/fpm/pool.d" -maxdepth 1 -type f -name '*.conf' ! -name 'www.conf' \
    -printf '%f\n' 2>/dev/null | sort
  return 0
}

# Listener of every pool of VER: "pool<TAB>listen" (ETC defaults to /etc/php).
php_upgrade_pool_listeners() {
  local ver=$1 etc=${2:-/etc/php} f listen
  for f in "$etc/$ver"/fpm/pool.d/*.conf; do
    [[ -f $f ]] || continue
    listen=$(ini_get "$f" listen 2>/dev/null || true)
    [[ -n $listen ]] && printf '%s\t%s\n' "${f##*/}" "$listen"
  done
  return 0
}

# Pools of another RUNNING version that bind a listener the target takes over
# from CUR.  The handover stops only CUR; a second live master on the same
# path would race the target for the socket (FPM unlinks and rebinds), so the
# switch is refused instead.  One active version is the 1.22 rule; --optimize
# reports and fixes a second enabled unit.  Prints
# "version<TAB>pool<TAB>listen".  ETC is an argument for unit tests; ACTIVE
# (space list) replaces the systemctl probe in tests.
php_upgrade_listen_conflicts() {
  local cur=$1 target=$2 etc=${3:-/etc/php} active=${4-__probe__} ver pool listen
  local -A ours=()
  while IFS=$'\t' read -r pool listen; do
    [[ -n $listen ]] && ours[$listen]=1
  done < <(php_upgrade_pool_listeners "$cur" "$etc")
  (( ${#ours[@]} > 0 )) || ours[/run/php/php-fpm.sock]=1
  if [[ $active == __probe__ ]]; then
    local d
    active=""
    # Every tree under /etc/php counts, not only our builds: a leftover
    # package unit still running would race for the socket just the same.
    for d in "$etc"/[0-9]*.[0-9]*; do
      ver=${d##*/}
      [[ -d $d && $ver =~ ^[0-9]+\.[0-9]+$ ]] || continue
      if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then active+=" $ver"; fi
    done
  fi
  local -A seen=()
  for ver in $active; do
    [[ $ver == "$cur" || -n ${seen[$ver]:-} ]] && continue
    seen[$ver]=1
    # The target itself running beside CUR is a separate refusal; its pools
    # are about to be replaced by CUR's anyway.
    [[ $ver == "$target" ]] && continue
    while IFS=$'\t' read -r pool listen; do
      [[ -n ${ours[$listen]:-} ]] && printf '%s\t%s\t%s\n' "$ver" "$pool" "$listen"
    done < <(php_upgrade_pool_listeners "$ver" "$etc")
  done
  return 0
}

# systemd drop-in directories of PHP-FPM versions that no longer exist (no
# setup build and no package binary).  Our unit carries its limits itself;
# a stale phpX.Y-fpm.service.d of a retired version only confuses
# `systemctl cat` and the diagnostics.
php_upgrade_remove_stale_dropins() {
  local dir ver removed=0 root
  root=$(php_upgrade_root)
  for dir in /etc/systemd/system/php*-fpm.service.d; do
    [[ -d $dir ]] || continue
    ver=${dir##*/php}; ver=${ver%-fpm.service.d}
    [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || continue
    [[ -x "$root/$ver/sbin/php-fpm" || -x "/usr/sbin/php-fpm${ver}" ]] && continue
    [[ -f /etc/systemd/system/php${ver}-fpm.service ]] && continue
    rm -f "$dir/limits.conf"
    rmdir "$dir" 2>/dev/null || true
    removed=1
  done
  if (( removed )); then systemctl daemon-reload 2>/dev/null || true; fi
  return 0
}

# ---------------------------------------------------------------------------
# Application requirements (the single table; B's build guard and E's
# migration union call these two functions by name)
# ---------------------------------------------------------------------------
# Print "app<TAB>document-root" for every supported application below BASE
# (default /var/www).  The directory argument makes this unit-testable.
php_upgrade_app_roots() {
  local base=${1:-/var/www} d app
  local -A seen_root=()
  for d in "$base"/* "$base"/*/public; do
    [[ -d $d ]] || continue
    app=$(app_type_at_root "$d")
    [[ -n $app ]] || continue
    [[ -n ${seen_root[$d]:-} ]] && continue
    seen_root[$d]=1
    printf '%s\t%s\n' "$app" "$d"
  done
}

# The same detection for document roots declared in web server vhosts, which
# may live outside /var/www (a mounted or symlinked tree).  TARGET is the tree
# to read: /etc/nginx normally, /etc/angie while the migration runs (R58).
# Both walks call app_type_at_root so a site can never be recognized by one
# path and missed by the other (a Chevereto tree needs only app/env.php).
php_upgrade_vhost_roots() {
  local target=${1:-/etc/nginx} file root app
  local -A seen_root=()
  [[ -d $target/conf.d ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    root=$(nginx_vhost_root "$file")
    [[ -n $root && -d $root ]] || continue
    [[ -n ${seen_root[$root]:-} ]] && continue
    seen_root[$root]=1
    app=$(app_type_at_root "$root")
    [[ -n $app ]] && printf '%s\t%s\n' "$app" "$root"
  done
}

# Everything an application needs from a minimal source build (the static
# build has only what its extension set names, so nothing may be left to
# "the default package set" any more).  One entry per name app_type_at_root
# prints; tests assert each has a row.  Names are PHP's module names as the
# build and `php -m` spell them (compare case-insensitively).
# The oldest PHP X.Y an app's Composer dependencies accept: the highest
# PHP_VERSION_ID floor in its vendor/composer/platform_check.php files, which
# stop every request on an older PHP (Chevereto 4.5 needs 8.2: the 1.22.0
# downgrade test to 8.1 answered 500 on every Chevereto page).  Prints
# nothing when no such file is found.
php_upgrade_app_php_floor() { # ROOT
  local root=$1 f n max=0
  local -a dirs=("$root/vendor" "$root/app/vendor" "$root/src/vendor" "$root"/wp-content/plugins/*/vendor)
  [[ ${root##*/} == public ]] && dirs+=("${root%/*}/vendor")
  for f in "${dirs[@]}"; do
    f=$f/composer/platform_check.php
    [[ -f $f ]] || continue
    n=$(grep -oE 'PHP_VERSION_ID >= [0-9]+' "$f" | grep -oE '[0-9]+$' | sort -n | tail -n 1 || true)
    [[ -n $n ]] && (( n > max )) && max=$n
  done
  (( max > 0 )) && printf '%d.%d' $(( max / 10000 )) $(( max / 100 % 100 ))
  return 0
}

php_upgrade_app_requirements() {
  case $1 in
    # Chevereto 4.5.9 aborts at bootstrap when redis is missing (redis pulls
    # igbinary: the serializer Chevereto's cache layer uses), talks to MariaDB
    # through both PDO and mysqli, and its integrity check wants exif,
    # fileinfo, xmlwriter and zip (APP_MODULES verified in 1.21.68).  Images
    # go through GD: Chevereto picks imagick only when it is loaded and its
    # check accepts GD (PNG GIF JPEG BMP WEBP).
    chevereto) printf '%s\n' pdo_mysql PDO mysqli redis igbinary gd curl mbstring exif fileinfo xmlwriter zip ;;
    # WordPress core plus Site Health's required list (exif for image
    # metadata, zip for updates, xml for feeds/XML-RPC, sodium for core's
    # signature checks); redis only with an object-cache drop-in, below.
    wordpress) printf '%s\n' mysqli gd curl mbstring exif zip xml sodium ;;
    # XenForo 2.3: xml_parser_* in the importers and add-on XML, zip for
    # add-on archives, exif for attachment rotation.
    xenforo)   printf '%s\n' mysqli gd curl mbstring xml zip exif ;;
  esac
}

# Print the required extension list for one app/root pair, adding redis (and
# igbinary, which always goes with it) when the site is configured to use it.
# MODE decides how sure that must be:
#   install    (--domain, the build set): only a certain hard requirement;
#   preflight  (default, --upgrade-php and the migration): anything that may
#              use it.  The preflight still waives an extension the current
#              PHP-FPM does not load, so a broad rule only blocks where redis
#              is actually in use.
php_upgrade_app_required_extensions() {
  local app=$1 root=$2 mode=${3:-preflight} redis=0
  php_upgrade_app_requirements "$app"
  case $app in
    wordpress)
      local oc=$root/wp-content/object-cache.php
      [[ -f $oc ]] || return 0
      if [[ $mode == install ]]; then
        # Certain: a drop-in that creates \Redis itself with no Predis
        # fallback, or Object Cache Pro (phpredis or Relay only).  Redis
        # Object Cache bundles Predis, and the W3 Total Cache, LiteSpeed,
        # Memcached and APCu drop-ins do not use Redis.
        if { grep -qE 'new[[:space:]]+\\?Redis([^A-Za-z0-9_]|$)' "$oc" 2>/dev/null \
               && ! grep -qi 'predis' "$oc" 2>/dev/null; } \
           || grep -qE 'RedisCachePro|Object Cache Pro' "$oc" 2>/dev/null; then
          redis=1
        fi
      elif grep -qi 'redis' "$oc" 2>/dev/null; then
        # May use it (any Redis drop-in, including one that hands off to a
        # plugin class): never take a loaded redis away from under it.
        redis=1
      fi
      ;;
    xenforo)
      # Only XenForo's own Redis cache provider (`'provider' => 'Redis'`,
      # Doctrine's RedisCache on the \Redis class) needs the extension.  The
      # stock config.php ships commented examples, which do not count, and
      # the SV RedisCache add-on talks to Redis or Valkey through its bundled
      # Credis client, which falls back to a pure-PHP connection when the
      # extension is absent (`standalone = !extension_loaded('redis')`).
      if [[ -f $root/src/config.php ]] \
         && awk '!/^[[:space:]]*(#|\/\/|\*)/' "$root/src/config.php" \
            | grep -qiE "provider[^;]*(['\"]Redis['\"]|Doctrine[\\\\]+Common[\\\\]+Cache[\\\\]+RedisCache)"; then
        redis=1
      fi
      ;;
  esac
  if (( redis )); then printf '%s\n' redis igbinary; fi
  return 0
}

# Modules PHP compiles in on every build of series VER, whatever the
# extension set says (R2.8's always-on list; random from 8.2, lexbor and uri
# from 8.5).  OPcache is always built: in the binary on >= 8.5, as the
# version's own opcache.so before.  Lower-case, one per line.
php_upgrade_core_modules() {
  local ver=$1 major minor
  major=${ver%%.*}; minor=${ver#*.}
  printf '%s\n' core date hash json pcre reflection spl standard zend_opcache opcache
  if (( major > 8 || (major == 8 && minor >= 2) )); then printf 'random\n'; fi
  if (( major > 8 || (major == 8 && minor >= 5) )); then printf '%s\n' lexbor uri; fi
  return 0
}

# Effective extension set of the next build of X.Y (B's php_build_effective_exts:
# per-app detection + PHP_EXT_EXTRA + base + the current build's set; for a
# version other than the active one that includes the active build's set),
# lower-case, one per line.  X.Y defaults to the active version.  The
# output format of the helper (comma list or one per line) does not matter.
#
# The helper's status is captured into a variable, never left inside a pipe:
# under `set -Eeuo pipefail` + inherit_errexit a failing first stage would
# end the caller's command substitution through the ERR trap before any
# explained die.  Its stderr is not discarded: on status 1 it names the
# extension that has no source build path, and the caller shows that.
# Returns the helper's status (1 = the set cannot be built as asked).
php_upgrade_effective_exts() { # [X.Y]
  declare -F php_build_effective_exts >/dev/null || return 0
  local raw="" rc=0
  raw=$(php_build_effective_exts "${1:-}") || rc=$?
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | tr ',' '\n' \
    | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u
  return "$rc"
}

# True when EXT will be in the TARGET build: in the effective set or always
# compiled in.  mysqlnd comes with mysqli/pdo_mysql.  EXTS (one per line,
# lower-case) defaults to PHP_UPGRADE_EXTS.
php_upgrade_extension_available() {
  local target=$1 ext exts=${3-$PHP_UPGRADE_EXTS}
  ext=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
  php_upgrade_core_modules "$target" | grep -qxF "$ext" && return 0
  if [[ $ext == mysqlnd ]] && grep -qxE 'mysqli|pdo_mysql' <<<"$exts"; then return 0; fi
  grep -qxF "$ext" <<<"$exts"
}

# 0 while X.Y is still a Sury (package) version on this host, the 1.21 ->
# 1.22 legacy window: a package php-fpmX.Y exists and X.Y is not ours yet
# (php_fpm_legacy_versions when lib/optimize.sh is loaded, else no setup
# build of X.Y), or the migration state has a php-X.Y part that is not done.
php_upgrade_sury_window() { # X.Y
  local ver=$1 st=""
  [[ -x /usr/sbin/php-fpm${ver} ]] || return 1
  if declare -F migrate_state_get >/dev/null; then
    st=$(migrate_state_get "php-${ver}" 2>/dev/null || true)
    [[ -n $st && $st != "done" ]] && return 0
  fi
  if declare -F php_fpm_legacy_versions >/dev/null; then
    st=$(php_fpm_legacy_versions 2>/dev/null || true)
    grep -qxF -- "$ver" <<<"$st"
    return
  fi
  ! php_upgrade_fpm_installed "$ver"
}

# Lower-case names of the modules the PHP-FPM of VERSION loads (the SAPI the
# sites run on), one per line; the CLI list when no FPM binary exists.  The
# binary is BIN when given (the migration passes the Sury php-fpmX.Y), else
# our build; the Sury package binaries only while X.Y is still a package
# version (php_upgrade_sury_window): once X.Y is ours, a missing compiled
# php-fpm shows as "unknown", not as Sury's module list.  FPM reads its ini only through -c and
# PHP_INI_SCAN_DIR (the unit passes them), so both are given here: without
# them a < 8.5 build never shows "Zend OPcache" (shared, loaded by conf.d).
# Empty output means "unknown": the caller then keeps every requirement.
php_upgrade_loaded_modules() {
  local ver=$1 bin=${2:-} out ini="" scan="" b
  [[ -n $ver ]] || return 0
  if [[ -z $bin ]]; then
    local -a cands=("$(php_upgrade_fpm_bin "$ver")" "$(php_upgrade_cli_bin "$ver")")
    if php_upgrade_sury_window "$ver"; then
      cands=("$(php_upgrade_fpm_bin "$ver")" "/usr/sbin/php-fpm${ver}" "$(php_upgrade_cli_bin "$ver")" "/usr/bin/php${ver}")
    fi
    for b in "${cands[@]}"; do
      [[ -x $b ]] && { bin=$b; break; }
    done
  fi
  [[ -n $bin && -x $bin ]] || return 0
  case $bin in
    */php-fpm*) ini=/etc/php/${ver}/fpm/php.ini; scan=/etc/php/${ver}/fpm/conf.d ;;
    *)          ini=/etc/php/${ver}/cli/php.ini; scan=/etc/php/${ver}/cli/conf.d ;;
  esac
  local -a args=(-m)
  [[ -f $ini ]] && args=(-c "$ini" -m)
  # The whole output is read first, and only a successful `-m` counts: a
  # failed one may have printed a partial list, which would waive every
  # extension cut off from it.  (No `sed q` on a live pipe either: SIGPIPE
  # fails a pipeline under pipefail.)
  if [[ -d $scan ]]; then
    out=$(PHP_INI_SCAN_DIR=$scan "$bin" "${args[@]}" 2>/dev/null) || return 0
  else
    out=$("$bin" "${args[@]}" 2>/dev/null) || return 0
  fi
  printf '%s\n' "$out" | sed -nE '/^\[Zend Modules\]/d; /^[A-Za-z]/{s/ /_/g; p;}' \
    | tr '[:upper:]' '[:lower:]' | sort -u
  return 0
}

# Run CMD (a function such as php_build_ensure) with set -e and the ERR trap
# live inside it, and return its status.  `if ! f`, `f || rc=$?` and `f &&`
# suspend errexit for the whole function body, so a failed write inside the
# build path would be skipped silently; a subshell in such a list is
# suspended the same way.  An asynchronous subshell is not: it runs with
# errexit active, and `wait` hands its status back.  The subshell keeps no
# globals, so only callers that need nothing but the status use this.
php_upgrade_checked() {
  local pid rc=0
  ( "$@" ) &
  pid=$!
  wait "$pid" || rc=$?
  return "$rc"
}

# Ensure the build of PHP VER carries the extensions APP (at ROOT) cannot run
# without.  --domain calls this before it writes the vhost; the effective set
# includes the app types of --domain app= (B), so a missing module means the
# running build predates that set: rebuild (the old binary serves until the
# new one passes verify).  Returns 0; a module that still is not there is a
# warning naming the site and the explicit --php ext= remedy.
php_ensure_app_extensions() {
  local app=$1 root=$2 ver=$3 loaded ext
  local -a want=()
  [[ -n $app && -n $ver ]] || return 0
  loaded=$(php_upgrade_loaded_modules "$ver")
  [[ -n $loaded ]] || return 0
  while IFS= read -r ext; do
    [[ -n $ext ]] || continue
    ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    grep -qxF "$ext" <<<"$loaded" && continue
    [[ " ${want[*]} " == *" ${ext} "* ]] || want+=("$ext")
  done < <(php_upgrade_app_required_extensions "$app" "$root" install)
  (( ${#want[@]} > 0 )) || return 0
  if ! declare -F php_build_ensure >/dev/null; then
    warn "${app} at ${root} needs ${want[*]}, which PHP ${ver} does not load; run --optimize to rebuild PHP"
    return 0
  fi
  info "${app} at ${root} needs ${want[*]}; rebuilding PHP ${ver} with the application's extension set (the current build serves meanwhile)"
  # CONTEXT refresh: the same build, layout and restart as optimize, but no
  # 60 s live-traffic BOLT sample, which belongs to --optimize only.  The
  # call goes through php_upgrade_checked so set -e and the ERR trap stay
  # live inside the build path while its status is still captured.
  local rc=0
  php_upgrade_checked php_build_ensure "$ver" full refresh info || rc=$?
  if (( rc != 0 )); then
    warn "PHP ${ver} rebuild failed; ${app} at ${root} may not start until it succeeds (re-run --optimize, or add --php ext=$(IFS=,; printf '%s' "${want[*]}"))"
    return 0
  fi
  loaded=$(php_upgrade_loaded_modules "$ver")
  for ext in "${want[@]}"; do
    if [[ -n $loaded ]] && ! grep -qxF "$ext" <<<"$loaded"; then
      warn "PHP ${ver} still does not load ${ext}; ${app} at ${root} may fail (add it with --php ext=${ext})"
    fi
  done
  return 0
}

# Fill PHP_UPGRADE_BLOCKERS with "app|root|ext" entries when an installed
# application would lose a hard requirement on TARGET (not in the extension
# set its build gets).  An extension the current PHP-FPM does not load
# cannot be lost by the switch, so it never blocks (a forum that works today
# without redis keeps working without it); those entries go to
# PHP_UPGRADE_NOT_LOADED for the report.  The third argument is the module
# list itself (tests); without it the active version's list is read.  The
# target's set comes from PHP_UPGRADE_EXTS (filled by the caller; empty means
# the set could not be computed, and then every requirement blocks).
php_upgrade_preflight_apps() {
  local target=$1 base=${2:-/var/www} app root ext loaded="" cur floor
  PHP_UPGRADE_BLOCKERS=()
  PHP_UPGRADE_NOT_LOADED=()
  if (( $# >= 3 )); then
    loaded=$3
  else
    cur=$(php_upgrade_current_version)
    PHP_UPGRADE_LOADED_FROM=${cur:-}
    if [[ -n $cur ]]; then loaded=$(php_upgrade_loaded_modules "$cur") || loaded=""; fi
  fi
  while IFS=$'\t' read -r app root; do
    [[ -n $app ]] || continue
    while IFS= read -r ext; do
      [[ -n $ext ]] || continue
      php_upgrade_extension_available "$target" "$ext" && continue
      if [[ -n $loaded ]] && ! grep -qixF "$ext" <<<"$loaded"; then
        PHP_UPGRADE_NOT_LOADED+=("${app}|${root}|${ext}")
        continue
      fi
      PHP_UPGRADE_BLOCKERS+=("${app}|${root}|${ext}")
    done < <(php_upgrade_app_required_extensions "$app" "$root")
    floor=$(php_upgrade_app_php_floor "$root")
    if [[ -n $floor && $(printf '%s\n%s\n' "$floor" "$target" | sort -V | head -n 1) != "$floor" ]]; then
      PHP_UPGRADE_BLOCKERS+=("${app}|${root}|php>=${floor}")
    fi
  done < <(
    {
      php_upgrade_app_roots "$base"
      # Only the live tree is scanned for a production run; a unit test that
      # passes a private BASE must stay hermetic.
      [[ $base == /var/www ]] && php_upgrade_vhost_roots
    } | sort -u
  )
  return 0
}

# Modules the current version loads that the target build will not have:
# PHP_UPGRADE_SKIPPED ("ext (reason)").  Both builds come from the same
# effective set, so this is normally empty; it catches a set that shrank
# since the current build (an ext= trimmed, a --domain removed) before the
# switch takes the module away (R25).  The availability list is
# PHP_UPGRADE_EXTS: the planned set in the dry run, the candidate's real
# `-m` in the real run.  Modules of CUR's own series core (lexbor and uri on
# 8.5, when switching down to 8.4) are not a loss.
php_upgrade_dropped_modules() {
  local cur=$1 target=$2 m core
  PHP_UPGRADE_SKIPPED=()
  [[ -n $cur ]] || return 0
  core=$(php_upgrade_core_modules "$cur")
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    case $m in cgi-fcgi|cgi_fcgi|core|pcntl|readline) continue ;; esac
    grep -qxF "$m" <<<"$core" && continue
    php_upgrade_extension_available "$target" "$m" && continue
    PHP_UPGRADE_SKIPPED+=("${m} (loaded by PHP ${cur}, not in the extension set; add it with --php ext=${m})")
  done < <(php_upgrade_loaded_modules "$cur")
  return 0
}

# Known upstream incompatibilities that do not block the upgrade (the
# production pages work) but that the operator must hear about first.
# Measured in the 1.21.58 audit (XenForo 2.3.13, PHP 8.6.0): production mode
# clean, but debug mode answers 500 on every page (XenForo raises the
# "Using null as an array offset" deprecation in src/XF/App.php as an
# exception), and two bundled libraries no longer compile: Braintree's
# Digest.php (payment profiles) and laminas-mail's Transport/Null.php ("Null"
# is a reserved class name).  Fills PHP_UPGRADE_CAUTIONS with app|root.
PHP_UPGRADE_CAUTIONS=()
php_upgrade_app_cautions() {
  local target=$1 base=${2:-/var/www} app root
  PHP_UPGRADE_CAUTIONS=()
  [[ $(printf '%s\n8.6\n' "$target" | sort -V | head -n 1) == 8.6 ]] || return 0
  while IFS=$'\t' read -r app root; do
    [[ $app == xenforo ]] && PHP_UPGRADE_CAUTIONS+=("${app}|${root}")
  done < <(php_upgrade_app_roots "$base" | sort -u)
  return 0
}

php_upgrade_describe_caution() {
  local entry=$1 app root
  IFS='|' read -r app root <<<"$entry"
  printf '%s at %s on PHP %s: production pages work, but debug mode answers 500 on every page and the bundled Braintree (payment profiles) and laminas-mail null transport do not compile; keep 8.5 for this forum until XenForo ships a fix' \
    "$app" "$root" "${UPGRADE_PHP:-8.6}"
}

# Human-readable reason for one blocker: which site needs what, and why the
# target cannot provide it.
php_upgrade_describe_blocker() {
  local entry=$1 app root ext
  IFS='|' read -r app root ext <<<"$entry"
  if [[ $ext == 'php>='* ]]; then
    printf '%s at %s requires PHP %s or newer (its Composer platform check stops every request on an older PHP), so it would fail on PHP %s' \
      "$app" "$root" "${ext#php>=}" "${UPGRADE_PHP}"
    return 0
  fi
  printf '%s at %s requires the %s extension, which is not in the extension set the PHP %s build gets (add it with --php ext=%s)' \
    "$app" "$root" "$ext" "${UPGRADE_PHP}" "$ext"
}

# One line for a requirement the current PHP does not meet either.
php_upgrade_describe_waived() {
  local entry=$1 app root ext
  IFS='|' read -r app root ext <<<"$entry"
  printf '%s at %s: the %s extension is not loaded by the current PHP-FPM (%s) either, so the switch does not take it away' \
    "$app" "$root" "$ext" "${PHP_UPGRADE_LOADED_FROM:-${PHP_UPGRADE_OLD_VERSION:-the current PHP}}"
}

php_upgrade_describe_conflict() {
  local ver pool listen
  IFS=$'\t' read -r ver pool listen <<<"$1"
  printf 'PHP %s is running and its pool %s binds %s, which PHP %s takes over' \
    "$ver" "$pool" "$listen" "${UPGRADE_PHP:-?}"
}

# X.Y syntax and the supported floor.  The newest released X.Y.Z (never an
# RC) is resolved by the build from php.net, so a series php.net does not
# publish fails the build step with the current version still serving.
php_upgrade_validate_target() {
  local target=$1
  [[ $target =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "--upgrade-php expects a PHP series such as 8.5 (got '${target}')"
  [[ $(printf '%s\n%s\n' "$PHP_UPGRADE_MIN_SERIES" "$target" | sort -V | head -n 1) == "$PHP_UPGRADE_MIN_SERIES" ]] \
    || die "PHP ${target} is older than ${PHP_UPGRADE_MIN_SERIES}, the oldest series the source build supports"
  return 0
}

# Reasons the switch may not run at all; one line each on stdout, empty when
# it may.  Shared by the dry run (prints them) and the real run (dies).
# 0 while the 1.22 migration still owns PHP: a PHP switch or the package
# purge is in flight, the migration unit runs, a Sury phpX.Y-fpm unit still
# serves a version whose php-X.Y part is not done, or the Sury purge after a
# done part has not run (it would remove dpkg conffiles under /etc/php).
# Only the PHP parts count (R19): a plain migrate_needed answers for every
# part, so a blocked nginx part, a deferred Angie purge, a postponed Valkey
# part or a leftover distro nginx would lock --upgrade-php out although PHP
# is done; `migrate_needed php` is the scoped form used here.
# A deferred Sury purge (collateral the operator must clear) does not block:
# nothing of it is half-done.  Without lib/migrate.sh nothing is pending.
php_upgrade_migration_pending() {
  local st v php_done=0
  declare -F migrate_state_get >/dev/null || return 1
  # A PHP-scoped query from the migration module wins when it exists:
  # migrate_php_pending, else migrate_needed php (E's PART-scoped answer: a
  # PHP switch or interrupted Sury purge in flight, a part not done, a
  # refused/failed part whose cause changed, a deferred purge that can run
  # now; a blocked nginx part or a postponed Valkey part never count).  The
  # migration unit running owns the host either way.
  if declare -F migrate_php_pending >/dev/null; then
    migrate_php_pending
    return
  fi
  if declare -F migrate_needed >/dev/null; then
    if declare -F migrate_running >/dev/null && migrate_running; then return 0; fi
    migrate_needed php
    return
  fi
  st=$(migrate_state_get inflight 2>/dev/null || true)
  [[ $st == php-* || $st == purge ]] && return 0
  if declare -F migrate_running >/dev/null && migrate_running; then return 0; fi
  if declare -F migrate_sury_active_versions >/dev/null && command -v dpkg-query >/dev/null 2>&1; then
    while IFS= read -r v; do
      [[ -n $v ]] || continue
      [[ $(migrate_state_get "php-${v}" 2>/dev/null || true) == "done" ]] || return 0
    done < <(migrate_sury_active_versions 2>/dev/null || true)
  fi
  if [[ -n ${MIGRATE_STATE_FILE:-} && -f $MIGRATE_STATE_FILE ]] \
     && grep -qE '^php-[0-9]+\.[0-9]+=done$' "$MIGRATE_STATE_FILE" 2>/dev/null; then
    php_done=1
  fi
  if (( php_done )) && declare -F migrate_pkg_list >/dev/null \
     && command -v dpkg-query >/dev/null 2>&1 \
     && [[ -n $(migrate_pkg_list sury 2>/dev/null || true) ]]; then
    case $(migrate_state_get sury-purge 2>/dev/null || true) in
      done|deferred:*) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

php_upgrade_refusals() {
  local state
  # The PHP part of the 1.22 migration (Sury -> our build) must be finished:
  # until then phpX.Y-fpm is a package unit and /etc/php is Sury's.  Only the
  # PHP part counts (R19): a blocked nginx part must not lock PHP out forever.
  if php_upgrade_migration_pending; then
    printf '%s\n' "the 1.22 migration of PHP is not finished; run --optimize first (it builds PHP from source and retires the Sury packages)"
  fi
  if declare -F web_server_state >/dev/null; then
    state=$(web_server_state 2>/dev/null || true)
    if [[ $state == angie-legacy ]]; then
      printf '%s\n' "the web tier is still Angie (nginx migration refused or pending); --optimize retries it and reports the blockers"
    fi
  fi
  if declare -F mem_gate_allows >/dev/null && ! mem_gate_allows php >/dev/null 2>&1; then
    printf '%s\n' "below 4 GB class: PHP is not built on this host (nginx only)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot, configuration carry-over, handover, verify, rollback
# ---------------------------------------------------------------------------
# Snapshot before anything changes: the current tree, its build.info, the
# loaded modules and the operator files, below PHP_UPGRADE_MANIFEST_DIR.  The
# current build itself is the rollback point and is never touched.
php_upgrade_snapshot() {
  local old=$1 dir=$PHP_UPGRADE_MANIFEST_DIR root
  root=$(php_upgrade_root)
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
  PHP_UPGRADE_OLD_VERSION=$old
  PHP_UPGRADE_WWW_LISTEN=$(php_pool_listen "$old" 2>/dev/null || true)
  {
    printf 'generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'mode: %s\n' "$PHP_UPGRADE_MODE"
    printf 'old_version: %s\n' "$old"
    printf 'target_version: %s\n' "${UPGRADE_PHP:-}"
    printf 'nginx_active: %s\n' "$PHP_UPGRADE_NGINX_ACTIVE"
    printf 'exts: %s\n' "$(printf '%s' "$PHP_UPGRADE_EXTS" | paste -sd, -)"
  } > "$dir/manifest.txt"
  cp -p "$root/$old/build.info" "$dir/build-${old}.info" 2>/dev/null || true
  php_upgrade_loaded_modules "$old" > "$dir/modules-${old}.txt" || true
  php_upgrade_custom_inis "/etc/php/$old" > "$dir/custom-inis.txt"
  php_upgrade_custom_pools "/etc/php/$old" > "$dir/custom-pools.txt"
  if [[ -d /etc/php/$old ]]; then
    mkdir -p "$dir/php-config"
    cp -a "/etc/php/$old" "$dir/php-config/$old" 2>/dev/null \
      || warn "Could not copy /etc/php/${old} to ${dir}/php-config"
  fi
  return 0
}

# Rewrite version-specific paths of OLD into NEW in one carried file.  The
# listen line stays verbatim: an operator vhost points at exactly that socket
# (fastcgi_pass unix:/run/php/php8.4-fpm-shop.sock) and renaming it would
# answer 502 while the switch reports success.
php_upgrade_rewrite_file() {
  local old=$1 new=$2 src=$3 dst=$4 root o
  root=$(php_upgrade_root)
  o=${old//./\\.}
  sed -E "/^[[:space:]]*listen[[:space:]]*=/! {
      s#${root//./\\.}/${o}/#${root}/${new}/#g
      s#/etc/php/${o}/#/etc/php/${new}/#g
      s/php${o}([^0-9]|\$)/php${new}\\1/g
    }" "$src" > "$dst"
}

# Lay /etc/php/NEW out from OLD's files, then let php_build_layout write the
# files setup generates.  Carried: every pool (www.conf included, so user,
# env[], php_admin_value[], listen.* and pm.status_path survive; the tuner
# then normalises the managed keys), operator conf.d fragments, and the two
# managed setting files (custom_dan.ini with the operator's timezone,
# zz-setup-optimize.ini) as a bridge until the tuner rewrites them.  Never
# carried: php.ini, php-fpm.conf, the OPcache loader (R56: it names the old
# version's opcache.so) and any extension= line (static build).  ETC is an
# argument for unit tests.
php_upgrade_carry_config() {
  local old=$1 new=$2 etc=${3:-/etc/php} rel links base d f
  PHP_UPGRADE_CARRIED=()
  [[ -d $etc/$old ]] || return 0
  mkdir -p "$etc/$new/fpm/pool.d" "$etc/$new/fpm/conf.d" "$etc/$new/cli/conf.d"
  for f in "$etc/$old"/fpm/pool.d/*.conf; do
    [[ -f $f ]] || continue
    php_upgrade_rewrite_file "$old" "$new" "$f" "$etc/$new/fpm/pool.d/${f##*/}" || return 1
    chmod 644 "$etc/$new/fpm/pool.d/${f##*/}"
    PHP_UPGRADE_CARRIED+=("fpm/pool.d/${f##*/}")
  done
  while IFS=$'\t' read -r rel links; do
    [[ -n $rel ]] || continue
    base=${rel##*/}
    php_upgrade_rewrite_file "$old" "$new" "$etc/$old/$rel" "$etc/$new/$rel" || return 1
    # A static build has no .so to load; an operator line left active would
    # print "Unable to load" on every start (and fail the clean -t check).
    sed -i -E 's/^([[:space:]]*(zend_)?extension[[:space:]]*=)/; setup-1.22-off: \1/' "$etc/$new/$rel"
    PHP_UPGRADE_CARRIED+=("$rel")
    local -a linkdirs=()
    IFS=, read -r -a linkdirs <<< "$links"
    for d in "${linkdirs[@]}"; do
      [[ -n $d && -d "$etc/$new/$d" ]] || continue
      ln -sfn "$etc/$new/$rel" "$etc/$new/$d/$base"
    done
  done < <(php_upgrade_custom_inis "$etc/$old")
  for d in fpm/conf.d cli/conf.d; do
    for base in custom_dan.ini zz-setup-optimize.ini; do
      [[ -f $etc/$old/$d/$base && ! -L $etc/$old/$d/$base ]] || continue
      php_upgrade_rewrite_file "$old" "$new" "$etc/$old/$d/$base" "$etc/$new/$d/$base" || return 1
      sed -i -E 's/^([[:space:]]*(zend_)?extension[[:space:]]*=)/; setup-1.22-off: \1/' "$etc/$new/$d/$base"
      PHP_UPGRADE_CARRIED+=("$d/$base")
    done
  done
  return 0
}

# php-fpm -t of VER through B's helper (-y, -c, PHP_INI_SCAN_DIR), clean only
# when it passes AND prints no load warning: an "Unable to load" or "already
# loaded" line means a module the sites expect is missing or doubled, which
# -t alone reports as success.  Output goes to FILE.
php_upgrade_fpm_test_clean() {
  local ver=$1 file=$2 rc=0
  if declare -F php_fpm_test >/dev/null; then
    php_fpm_test "$ver" > "$file" 2>&1 || rc=$?
  else
    PHP_INI_SCAN_DIR=/etc/php/${ver}/fpm/conf.d "$(php_upgrade_fpm_bin "$ver")" -t \
      -y "/etc/php/${ver}/fpm/php-fpm.conf" -c "/etc/php/${ver}/fpm/php.ini" > "$file" 2>&1 || rc=$?
  fi
  (( rc == 0 )) || return 1
  if grep -qiE 'Unable to load|already loaded' "$file" 2>/dev/null; then return 1; fi
  return 0
}

# PHP vhosts of the nginx tree: "host<TAB>root<TAB>scheme" for every server
# block file whose root holds an index.php.  TARGET is an argument for tests.
php_upgrade_php_vhosts() {
  local target=${1:-/etc/nginx} file root host scheme
  local -A seen=()
  [[ -d $target/conf.d ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    root=$(nginx_vhost_root "$file")
    [[ -n $root && -f $root/index.php ]] || continue
    host=$(awk '/^[[:space:]]*server_name[[:space:]]/ {
        for (i = 2; i <= NF; i++) { n = $i; sub(/;$/, "", n)
          if (n != "" && n != "_" && n !~ /^~/ && n !~ /\*/) { print n; exit } } }' "$file")
    [[ -n $host && -z ${seen[$host]:-} ]] || continue
    seen[$host]=1
    scheme=http
    grep -qE '^[[:space:]]*listen[[:space:]]+([^;]*:)?443([^0-9]|$)' "$file" && scheme=https
    printf '%s\t%s\t%s\n' "$host" "$root" "$scheme"
  done
  return 0
}

# One HTTP probe through the local nginx: GET /?setup_probe=<n> (the home
# page; /index.php answers with nginx's canonical 301 without reaching PHP,
# so the 1.22.0 downgrade test saw "3 OK" while Chevereto answered 500) with
# the vhost's Host (SNI through --resolve, self-signed origin accepted) and
# an unlisted cookie, which every guest cache in the SCN tree treats as a
# bypass ($guest_cookie_unlisted), so the answer comes from PHP-FPM and not
# from a cached copy.  Prints the status code; 000 when nothing answered.
php_upgrade_probe_one() {
  local host=$1 scheme=$2 port=80 body code
  [[ $scheme == https ]] && port=443
  body=$(tmp_file)
  code=$(curl -s -k -o "$body" -w '%{http_code}' --max-time 20 \
    --resolve "${host}:${port}:127.0.0.1" -H 'Cookie: setup_probe=1' \
    "${scheme}://${host}/?setup_probe=${RANDOM}${RANDOM}" 2>/dev/null || true)
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  # A 2xx/4xx with an empty body is a dead upstream dressed as success; a
  # redirect (WordPress canonical) legitimately has none.
  if [[ $code =~ ^[24] && ! -s $body ]]; then code="${code}-empty"; fi
  rm -f "$body"
  printf '%s' "$code"
}

php_upgrade_probe_bad() { [[ $1 == 000 || $1 == *-empty || $1 =~ ^5 ]]; }

# Probe every PHP vhost; fills PHP_UPGRADE_PROBE_BEFORE (phase before) or
# PHP_UPGRADE_PROBE_FAILED/OK (phase after).  After the switch only vhosts
# that answered before count: a site already broken on the old version is
# not the new version's fault and must not trigger a rollback.
php_upgrade_http_probe() {
  local phase=$1 host root scheme code entry prev
  command -v curl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet nginx 2>/dev/null || return 0
  if [[ $phase == before ]]; then
    PHP_UPGRADE_PROBE_BEFORE=()
    while IFS=$'\t' read -r host root scheme; do
      [[ -n $host ]] || continue
      code=$(php_upgrade_probe_one "$host" "$scheme")
      PHP_UPGRADE_PROBE_BEFORE+=("${host}"$'\t'"${scheme}"$'\t'"${code}")
    done < <(php_upgrade_php_vhosts | head -n "${SETUP_PHP_PROBE_MAX:-25}")
    return 0
  fi
  PHP_UPGRADE_PROBE_FAILED=()
  PHP_UPGRADE_PROBE_OK=0
  for entry in "${PHP_UPGRADE_PROBE_BEFORE[@]}"; do
    IFS=$'\t' read -r host scheme prev <<<"$entry"
    php_upgrade_probe_bad "$prev" && continue
    code=$(php_upgrade_probe_one "$host" "$scheme")
    if php_upgrade_probe_bad "$code"; then
      PHP_UPGRADE_PROBE_FAILED+=("${host} (${scheme}): ${code} (was ${prev})")
    else
      PHP_UPGRADE_PROBE_OK=$(( PHP_UPGRADE_PROBE_OK + 1 ))
    fi
  done
  return 0
}

# Make VER the active version: marker first (php_active_version, the tuner,
# the CPU chain and the refresh read it), then the unversioned php links.
# B's php_build_links owns the link rules (/usr/local/bin/php always;
# /usr/bin/php only where dpkg no longer owns it, R6; a "php" alternative
# that points into our root, left by a deferred Sury purge, is moved to the
# new CLI, so cron's /usr/bin/php follows the switch); the fallback applies
# the same rules so a missing helper cannot leave php on the old version.
php_upgrade_set_active() {
  local ver=$1 tmp root cli
  mkdir -p "${PHP_UPGRADE_ACTIVE_MARKER%/*}"
  tmp="${PHP_UPGRADE_ACTIVE_MARKER}.tmp.$$"
  printf '%s\n' "$ver" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$PHP_UPGRADE_ACTIVE_MARKER"
  if declare -F php_build_links >/dev/null; then
    php_build_links "$ver" || warn "Could not point the php links at PHP ${ver}"
    return 0
  fi
  root=$(php_upgrade_root)
  cli="$root/$ver/bin/php"
  [[ -x $cli ]] || return 0
  mkdir -p /usr/local/bin
  ln -sfn "$cli" /usr/local/bin/php
  if [[ ! -e /usr/bin/php || -L /usr/bin/php ]] && ! dpkg -S /usr/bin/php >/dev/null 2>&1; then
    ln -sfn "$cli" /usr/bin/php
  fi
  return 0
}

# Remove a leftover php-fpm.sock symlink (Debian's alternatives socket name
# pointed at phpX.Y-fpm.sock); our pools bind the path itself.  Then make
# sure /run/php and the session directories exist before any start (R89).
php_upgrade_prepare_runtime() {
  [[ -L /run/php/php-fpm.sock ]] && rm -f /run/php/php-fpm.sock
  if [[ -f /etc/tmpfiles.d/setup-php.conf ]]; then
    systemd-tmpfiles --create /etc/tmpfiles.d/setup-php.conf 2>/dev/null || true
  fi
  if [[ -f /etc/tmpfiles.d/setup-php-pools.conf ]]; then
    systemd-tmpfiles --create /etc/tmpfiles.d/setup-php-pools.conf 2>/dev/null || true
  fi
  return 0
}

# True when the pool listener LISTEN is up: a Unix socket path exists as a
# socket; a TCP listener ("127.0.0.1:9000", "[::1]:9000", "9000"), which the
# adopt rule carries verbatim like a socket path (R24), has a listening TCP
# socket on that port.  A form that cannot be parsed, or a host without ss,
# is not judged (true): only a listener known to be missing fails.
php_upgrade_listener_up() {
  local listen=$1 port
  if [[ $listen == /* ]]; then
    [[ -S $listen ]]
    return
  fi
  port=${listen##*:}
  [[ $port =~ ^[0-9]+$ ]] || return 0
  command -v ss >/dev/null 2>&1 || return 0
  ss -Hltn 2>/dev/null | awk -v p=":${port}" '
    { a = $4; if (length(a) > length(p) && substr(a, length(a) - length(p) + 1) == p) f = 1 }
    END { exit !f }'
}

# Start VER and wait for every listener of its pools (Unix socket or TCP).
php_upgrade_start_wait() {
  local ver=$1 pool listen rc=0
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "php${ver}-fpm" 2>/dev/null || true
  # restart, not start: a unit some earlier step left running must re-read
  # the pools laid out since.
  systemctl restart "php${ver}-fpm" 2>/dev/null || return 1
  systemctl is-active --quiet "php${ver}-fpm" || return 1
  while IFS=$'\t' read -r pool listen; do
    [[ -n $listen ]] || continue
    wait_for_cmd 10 php_upgrade_listener_up "$listen" \
      || { warn "PHP ${ver} pool ${pool}: listener ${listen} did not appear"; rc=1; }
  done < <(php_upgrade_pool_listeners "$ver")
  return "$rc"
}

# Run the shared PHP tuner on the new tree (the --optimize path: systemd
# limits, ini template sync, pool normalization, listener migration and
# verification), then align nginx with the socket.
php_upgrade_optimize() {
  local rc=0 change
  # No BOLT inside the switch (R2.5/R14): optimize_php_services runs
  # php_build_ensure TARGET full optimize, whose BOLT step (60 s sample,
  # binary swap, restart) would land before php_upgrade_verify, with the
  # build lock held.  php_build_ensure also skips it while
  # PHP_UPGRADE_IN_FLIGHT=1; the next --optimize BOLTs the new version.
  local -x SETUP_PHP_BUILD_BOLT=0
  detect_installed_services
  plan_memory_budget
  OPT_PHP_SOCKET=""
  tune_reset_changes
  # Same contract as run_optimize(): OPT_PHP_OK is set before the PHP
  # pass and cleared only when it fails.  php_refresh_after_nginx() is gated
  # on it, so leaving it at 0 silently skipped the post-nginx [PATH=] ini
  # refresh on every --upgrade-php.
  OPT_PHP_OK=1
  if optimize_php_services; then
    for change in "${TUNE_CHANGES[@]}"; do info "${change}"; done
    for change in "${TUNE_MISSES[@]}"; do warn "Not applied: ${change}"; done
  else
    warn "PHP optimization reported a failure"
    OPT_PHP_OK=0
    rc=1
  fi
  # When the tuner moved a pool to the socket, apply the shared nginx
  # profile so --upgrade-php reaches the same state as --optimize (guest
  # caches, precompression, compression and the tuner), then refresh the
  # [PATH=] ini sections that derive from the nginx tree.
  if [[ -n ${OPT_PHP_SOCKET:-} && -f /etc/nginx/nginx.conf ]]; then
    tune_reset_changes
    if nginx_apply_profile /etc/nginx; then
      for change in "${TUNE_CHANGES[@]}"; do info "nginx: ${change}"; done
      php_refresh_after_nginx info "" || rc=1
    else
      warn "nginx configuration could not be aligned with the PHP socket"
      rc=1
    fi
  fi
  verify_optimized_services || rc=1
  # The verdict travels in PHP_UPGRADE_OPTIMIZE_OK, not the exit status, so
  # run_php_upgrade can call this plainly: a `php_upgrade_optimize || rc=1`
  # suspended set -e and the ERR trap for every tuner inside (the defect
  # 1.21.67 fixed for --domain's closing pass).  A hard error ends the run
  # while PHP_UPGRADE_IN_FLIGHT is still set, and on_exit rolls back.
  PHP_UPGRADE_OPTIMIZE_OK=$(( rc == 0 ? 1 : 0 ))
  return 0
}

# Reload nginx so its upstream reconnects to the new FPM master.  The socket
# path is unchanged, but a keepalive upstream can hold a dead connection until
# it notices; a graceful reload is cheap and makes the cutover deterministic.
php_upgrade_reload_nginx() {
  local bin=${NGINX_BIN:-/usr/local/sbin/nginx}
  PHP_UPGRADE_NGINX_ACTIVE=0
  systemctl is-active --quiet nginx 2>/dev/null || return 0
  PHP_UPGRADE_NGINX_ACTIVE=1
  if ! "$bin" -t -q >/dev/null 2>&1; then
    warn "nginx configuration test failed; not reloading"
    return 1
  fi
  if systemctl reload nginx 2>/dev/null && systemctl is-active --quiet nginx; then
    ok "nginx reloaded against PHP-FPM"
    return 0
  fi
  warn "nginx did not reload after the PHP switch"
  return 1
}

# Post-conditions.  Hard (PHP_UPGRADE_VERIFY_HARD=1, the caller rolls back):
# unit inactive, a pool listener missing, php-fpm -t failing or warning,
# OPcache missing from FPM, a vhost that answered before now 5xx/dead.  Soft
# (ATTENTION only): the CLI default or OPcache in the CLI, the JIT profile.
php_upgrade_verify() {
  local new=$1 rc=0 hard=0 ver pool listen log cli loaded
  if ! systemctl is-active --quiet "php${new}-fpm"; then
    warn "php${new}-fpm is not active"; hard=1
  fi
  while IFS=$'\t' read -r pool listen; do
    [[ -n $listen ]] || continue
    if ! php_upgrade_listener_up "$listen"; then
      warn "Pool ${pool}: listener ${listen} is not up"; hard=1
    fi
  done < <(php_upgrade_pool_listeners "$new")
  log=$(tmp_file)
  if ! php_upgrade_fpm_test_clean "$new" "$log"; then
    warn "php-fpm -t for PHP ${new} failed or printed load warnings:"
    sed 's/^/  /' "$log" >&2 || true
    hard=1
  fi
  rm -f "$log"
  loaded=$(php_upgrade_loaded_modules "$new")
  if ! grep -qx 'zend_opcache' <<<"$loaded"; then
    warn "PHP ${new} FPM does not load OPcache (every request would recompile)"; hard=1
  fi
  php_upgrade_http_probe after
  if (( ${#PHP_UPGRADE_PROBE_FAILED[@]} > 0 )); then
    local f
    warn "PHP pages that answered before the switch now fail:"
    for f in "${PHP_UPGRADE_PROBE_FAILED[@]}"; do warn "  - ${f}"; done
    hard=1
  fi
  cli=$(php_upgrade_cli_bin "$new")
  ver=$("$cli" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)
  if [[ $ver != "$new" ]]; then
    warn "CLI ${cli} reports PHP ${ver:-unknown}, expected ${new}"; rc=1
  fi
  if [[ -x /usr/local/bin/php ]]; then
    ver=$(/usr/local/bin/php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)
    [[ $ver == "$new" ]] || { warn "/usr/local/bin/php runs PHP ${ver:-unknown}, expected ${new}"; rc=1; }
  fi
  if ! "$cli" -d opcache.enable_cli=1 -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);' >/dev/null 2>&1; then
    warn "The PHP ${new} CLI does not load OPcache; the JIT is not active for cron jobs"; rc=1
  fi
  if [[ -f "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" ]]; then
    grep -q '^opcache.jit = tracing' "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" \
      || { warn "Managed profile does not enable the tracing JIT"; rc=1; }
  fi
  PHP_UPGRADE_VERIFY_HARD=$hard
  (( hard )) && rc=1
  PHP_UPGRADE_VERIFY_OK=$(( rc == 0 ? 1 : 0 ))
  return "$rc"
}

# Put the previous version back: stop and disable the target, move the tree
# this run generated aside (and restore the tree that was there before, for
# a switch back to a kept version), restart the old unit on the socket, and
# point the marker and links at it again.  Nothing is rebuilt or deleted, so
# this is fast and also runs from on_exit after a signal.
#
# During the prepare phase (PHP_UPGRADE_PHASE=prepare: a die or set -e in
# the carry-over, the ini sync or php_build_layout) the current version never
# stopped, so only the trees are put back and nothing is restarted.
php_upgrade_rollback() {
  local old=$PHP_UPGRADE_OLD_VERSION target=${UPGRADE_PHP:-}
  local listen bin=${NGINX_BIN:-/usr/local/sbin/nginx}
  [[ -n $old ]] || { warn "No previous PHP version to roll back to"; return 1; }
  if [[ $PHP_UPGRADE_PHASE == prepare ]]; then
    PHP_UPGRADE_PHASE=""
    [[ -n $target && $target != "$old" ]] && php_upgrade_restore_trees "$target"
    warn "PHP ${old} kept serving; the PHP ${target:-?} configuration was moved aside"
    return 0
  fi
  PHP_UPGRADE_PHASE=""
  warn "Rolling back to PHP ${old}"
  if [[ -n $target && $target != "$old" ]]; then
    systemctl stop "php${target}-fpm" 2>/dev/null || true
    systemctl disable "php${target}-fpm" 2>/dev/null || true
    php_upgrade_restore_trees "$target"
  fi
  php_upgrade_set_active "$old"
  php_upgrade_prepare_runtime
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "php${old}-fpm" 2>/dev/null || true
  # restart, not `enable --now`: a unit that is somehow still running keeps
  # its stale state otherwise, and the shared socket must come from it.
  systemctl restart "php${old}-fpm" 2>/dev/null || true
  listen=$(php_pool_listen "$old" 2>/dev/null || true)
  if systemctl is-active --quiet "php${old}-fpm"; then
    if [[ $listen == /* ]] && ! wait_for_cmd 10 test -S "$listen"; then
      warn "PHP ${old} is running but its pool socket ${listen} is missing; inspect journalctl -u php${old}-fpm"
    else
      ok "PHP ${old} is active again${listen:+ (pool on ${listen})}"
    fi
  else
    warn "PHP ${old} did not start; inspect journalctl -u php${old}-fpm"
  fi
  if systemctl is-active --quiet nginx 2>/dev/null && "$bin" -t -q >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
  fi
  return 0
}

# After a verified switch: keep exactly one previous version (OLD) for
# rollback, disabled; retire every other build, newer or older (unit, tree, links via B's
# php_build_purge; its /etc/php tree moves into the manifest, never deleted).
# A version whose unit is enabled or running is never retired.
php_upgrade_retire_older() {
  local new=$1 old=$2 v dir=$PHP_UPGRADE_MANIFEST_DIR
  while IFS= read -r v; do
    [[ -n $v && $v != "$new" && $v != "$old" ]] || continue
    systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && continue
    systemctl is-enabled --quiet "php${v}-fpm" 2>/dev/null && continue
    if declare -F php_build_purge >/dev/null; then
      php_build_purge "$v" || { warn "Could not retire the PHP ${v} build"; continue; }
    fi
    if [[ -d /etc/php/$v ]]; then
      mkdir -p "$dir/retired"
      mv -- "/etc/php/$v" "$dir/retired/php-${v}" 2>/dev/null || true
    fi
    info "Retired PHP ${v} (only the previous version ${old} is kept for rollback; config in ${dir}/retired)"
  done < <(php_upgrade_installed_versions)
  return 0
}

# Markdown report kept next to the state, plus a copy under /var/log so the
# usual log-collection command picks it up.
php_upgrade_write_report() {
  local new=$1 rc=$2 report ts pool_summary="" jit_summary="" cli_version="" root entry
  root=$(php_upgrade_root)
  ts=$(date -u +%Y%m%d-%H%M%S)
  report="/var/log/setup-php-upgrade-${ts}.md"
  pool_summary=$(
    if [[ -r "/etc/php/${new}/fpm/pool.d/www.conf" ]]; then
      awk -F= '
        /^[[:space:]]*pm[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); pm = $2 }
        /^[[:space:]]*pm\.max_children/ { gsub(/[[:space:]]/, "", $2); mc = $2 }
        /^[[:space:]]*listen\.backlog/ { gsub(/[[:space:]]/, "", $2); bl = $2 }
        END { if (pm != "") printf "pm=%s max_children=%s backlog=%s", pm, mc, bl }
      ' "/etc/php/${new}/fpm/pool.d/www.conf" 2>/dev/null
    fi
  )
  if [[ -r "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" ]]; then
    jit_summary=$(grep -h '^opcache.jit' "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" 2>/dev/null | paste -sd' ' -)
  fi
  cli_version=$("$(php_upgrade_cli_bin "$new")" -v 2>/dev/null | head -n1 || true)
  {
    printf '# PHP upgrade report\n\n'
    printf -- '- Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Mode: %s\n' "$PHP_UPGRADE_MODE"
    printf -- '- From: %s\n' "${PHP_UPGRADE_OLD_VERSION:-none}"
    printf -- '- To: %s\n' "$new"
    printf -- '- Result: %s\n' "$([[ $rc -eq 0 ]] && printf PASS || printf ATTENTION)"
    printf -- '- Snapshot: `%s`\n' "$PHP_UPGRADE_MANIFEST_DIR"
    printf -- '- nginx active/reloaded: %s\n\n' "$PHP_UPGRADE_NGINX_ACTIVE"
    printf '## Build\n\n'
    if [[ -r $root/$new/build.info ]]; then
      printf '```\n'; cat -- "$root/$new/build.info"; printf '```\n'
    else
      printf 'No build.info for PHP %s.\n' "$new"
    fi
    printf '\n## Extension set\n\n`%s`\n' "$(printf '%s' "$PHP_UPGRADE_EXTS" | paste -sd' ' -)"
    if (( ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then
      printf '\n## Modules the previous version loaded that %s does not\n\n' "$new"
      printf -- '- %s\n' "${PHP_UPGRADE_SKIPPED[@]}"
    fi
    printf '\n## Configuration carried from %s\n\n' "${PHP_UPGRADE_OLD_VERSION:-the previous version}"
    if (( ${#PHP_UPGRADE_CARRIED[@]} > 0 )); then
      for entry in "${PHP_UPGRADE_CARRIED[@]}"; do printf -- '- `%s`\n' "$entry"; done
    else
      printf -- '- nothing\n'
    fi
    printf '\n## Verification\n\n'
    printf -- '- CLI: `%s`\n' "${cli_version:-unknown}"
    printf -- '- php-fpm active: %s\n' "$(php_upgrade_unit_state "php${new}-fpm")"
    printf -- '- Single PHP-FPM unit enabled and active: %s\n' "$PHP_UPGRADE_UNITS_OK"
    printf -- '- Socket: `%s`\n' "$(php_pool_listen "$new")"
    printf -- '- Pool: `%s`\n' "${pool_summary:-unavailable}"
    printf -- '- JIT: `%s`\n' "${jit_summary:-unavailable}"
    printf -- '- PHP pages probed OK: %s\n' "$PHP_UPGRADE_PROBE_OK"
    for entry in "${PHP_UPGRADE_PROBE_FAILED[@]}"; do printf -- '- Probe FAILED: %s\n' "$entry"; done
    printf -- '- Optimize pass: %s\n' "$([[ $PHP_UPGRADE_OPTIMIZE_OK == 1 ]] && echo OK || echo reported-a-failure)"
    printf -- '- Verification: %s\n' "$([[ $PHP_UPGRADE_VERIFY_OK == 1 ]] && echo OK || echo reported-a-failure)"
    printf '\n## Rollback\n\n'
    if [[ -n $PHP_UPGRADE_OLD_VERSION && $PHP_UPGRADE_OLD_VERSION != "$new" ]]; then
      printf 'PHP %s stays built and configured (disabled) for one rollback:\n\n' "$PHP_UPGRADE_OLD_VERSION"
      printf '```sh\nbash setup.sh --upgrade-php=%s\n```\n\n' "$PHP_UPGRADE_OLD_VERSION"
      printf 'It rebuilds only when that build is stale (CPU, extension set, recipe).  The pre-switch tree is also at `%s/php-config/%s`.\n' \
        "$PHP_UPGRADE_MANIFEST_DIR" "$PHP_UPGRADE_OLD_VERSION"
    else
      printf 'Same version; nothing to roll back to.\n'
    fi
  } > "$report"
  chmod 640 "$report" 2>/dev/null || true
  if [[ -n ${SUDO_GID:-} ]]; then chown "root:${SUDO_GID}" "$report" 2>/dev/null || true; fi
  printf '%s' "$report"
}

# --dry-run: show the exact plan without touching the host.  Works as a normal
# user (detection that needs root degrades to "unknown").
php_upgrade_plan() {
  local target=$UPGRADE_PHP cur="" reason entry app root found_app=0 exts_rc=0
  local -a refusals=() versions=()
  php_upgrade_validate_target "$target"
  mapfile -t versions < <(php_upgrade_installed_versions)
  cur=$(php_upgrade_current_version)
  # The helper prints its reason (the unbuildable name) on stderr.
  PHP_UPGRADE_EXTS=$(php_upgrade_effective_exts "$target") || exts_rc=$?
  (( exts_rc == 0 )) || PHP_UPGRADE_EXTS=""
  printf '\n%sDRY RUN%s - PHP upgrade plan, no changes will be made.\n' "$C_BOLD" "$C_RESET"
  printf 'Target PHP : %s (newest released %s.x from php.net, built from source)\n' "$target" "$target"
  printf 'Current    : %s (setup builds: %s)\n' "${cur:-none}" "${versions[*]:-none}"
  mapfile -t refusals < <(php_upgrade_refusals)
  if (( exts_rc != 0 )); then
    refusals+=("the extension set cannot be built as configured (php_build_effective_exts named the extension above); fix --php ext= or set SETUP_PHP_ALLOW_MISSING_EXT=1")
  fi
  if (( ${#refusals[@]} > 0 )); then
    printf '\nREFUSED: the real run stops before changing anything:\n'
    for reason in "${refusals[@]}"; do printf '  - %s\n' "$reason"; done
  fi
  if [[ -z $cur ]]; then
    printf '\nNo active PHP build: install PHP with --php ver=%s instead.\n' "$target"
    return 0
  fi
  printf 'Extensions : %s\n' "$(printf '%s' "${PHP_UPGRADE_EXTS:-unknown}" | paste -sd' ' -)"
  if declare -F php_build_plan >/dev/null; then
    printf 'Build      : %s\n' "$(php_build_plan "$target" 2>/dev/null || true)"
  fi
  if [[ $target == "$cur" ]]; then
    printf '\nPHP %s is already active: the run rebuilds it only when the build is stale (CPU, extension set, versions) and keeps it serving.\n' "$target"
    return 0
  fi
  printf '\nApplication requirements:\n'
  while IFS=$'\t' read -r app root; do
    [[ -n $app ]] || continue
    found_app=1
    printf '  %-11s %s\n' "$app" "$root"
  done < <(php_upgrade_app_roots)
  (( found_app )) || printf '  none detected under /var/www\n'
  php_upgrade_preflight_apps "$target"
  for entry in "${PHP_UPGRADE_NOT_LOADED[@]}"; do
    printf '  note: %s\n' "$(php_upgrade_describe_waived "$entry")"
  done
  php_upgrade_app_cautions "$target"
  for entry in "${PHP_UPGRADE_CAUTIONS[@]}"; do
    printf '  caution: %s\n' "$(php_upgrade_describe_caution "$entry")"
  done
  if (( ${#PHP_UPGRADE_BLOCKERS[@]} > 0 )); then
    printf '\nBLOCKED: the switch would break installed application(s):\n'
    for entry in "${PHP_UPGRADE_BLOCKERS[@]}"; do
      printf '  - %s\n' "$(php_upgrade_describe_blocker "$entry")"
    done
    printf '  The real run refuses before building. Override with SETUP_PHP_ALLOW_MISSING_EXT=1.\n'
  fi
  mapfile -t PHP_UPGRADE_CONFLICTS < <(php_upgrade_listen_conflicts "$cur" "$target")
  if (( ${#PHP_UPGRADE_CONFLICTS[@]} > 0 )); then
    printf '\nBLOCKED: another PHP version is running on a listener the target takes over:\n'
    for entry in "${PHP_UPGRADE_CONFLICTS[@]}"; do
      printf '  - %s\n' "$(php_upgrade_describe_conflict "$entry")"
    done
    printf '  Run --optimize first (one active PHP version).\n'
  fi
  php_upgrade_dropped_modules "$cur" "$target"
  for entry in "${PHP_UPGRADE_SKIPPED[@]}"; do printf '  dropped: %s\n' "$entry"; done
  printf '\nSteps:\n'
  if php_upgrade_fpm_installed "$target"; then
    printf '  1. reuse the kept PHP %s build (rebuilt only when stale); %s keeps serving\n' "$target" "$cur"
  else
    printf '  1. build PHP %s (FPM + CLI, several minutes); %s keeps serving\n' "$target" "$cur"
  fi
  printf '  2. lay out /etc/php/%s from %s: pools (listen kept), operator conf.d, managed settings; php-fpm -t\n' "$target" "$cur"
  printf '  3. stop php%s-fpm, start php%s-fpm on the same socket(s), switch /etc/php/setup-active and the php links\n' "$cur" "$target"
  printf '  4. run the shared PHP tuner, reload nginx, verify (php-fpm -t, sockets, OPcache, HTTP probe of every PHP vhost)\n'
  printf '  5. on failure roll back to %s; on success enable %s, disable %s (kept for --upgrade-php=%s)\n' "$cur" "$target" "$cur" "$cur"
  printf '  6. write /var/log/setup-php-upgrade-*.md\n'
  return 0
}

# Move the /etc/php/TARGET tree this run generated into the manifest and put
# back the kept tree it replaced.  Shared by the explicit aborts, the
# prepare-phase rollback (on_exit after a hard error) and the handover
# rollback.  Never touches a tree this run did not generate, and never
# deletes anything.
php_upgrade_restore_trees() {
  local target=$1 dir=$PHP_UPGRADE_MANIFEST_DIR moved
  [[ -n $target && $target != "${PHP_UPGRADE_OLD_VERSION:-}" ]] || return 0
  if (( PHP_UPGRADE_TREE_GENERATED )) && [[ -d /etc/php/$target && -n $dir ]]; then
    mkdir -p "$dir/failed" 2>/dev/null || true
    if mv -- "/etc/php/$target" "$dir/failed/php-${target}" 2>/dev/null; then
      info "Moved the generated PHP ${target} configuration to ${dir}/failed/php-${target}"
    elif moved=$(preserve_to_tmp "/etc/php/$target" 2>/dev/null) && [[ -n $moved ]]; then
      info "Moved the generated PHP ${target} configuration to ${moved}"
    fi
  fi
  PHP_UPGRADE_TREE_GENERATED=0
  if [[ -n $PHP_UPGRADE_PRIOR_TREE && -d $PHP_UPGRADE_PRIOR_TREE && ! -e /etc/php/$target ]]; then
    mv -- "$PHP_UPGRADE_PRIOR_TREE" "/etc/php/$target" 2>/dev/null \
      && info "Restored the previous /etc/php/${target}"
  fi
  return 0
}

# Abort before the handover: the current version kept serving the whole
# time, so only the generated tree is moved away (and a kept tree restored).
# The in-flight flag is cleared first so on_exit does not undo it twice.
php_upgrade_abort_prepare() {
  local target=$1 msg=$2 report
  PHP_UPGRADE_IN_FLIGHT=0
  PHP_UPGRADE_PHASE=""
  php_upgrade_restore_trees "$target"
  warn "${msg}. Nothing changed for the sites: PHP ${PHP_UPGRADE_OLD_VERSION} kept serving."
  report=$(php_upgrade_write_report "$target" 1)
  warn "Report: ${report}"
  php_upgrade_lock_release
  return 0
}

# Take /run/setup-build.lock (blocking, like build_lock_run) in this shell and
# keep it until php_upgrade_lock_release or the end of the run.  build_lock_run
# runs its command in a subshell, which would lose the globals on_exit needs,
# so the fd is opened here; SETUP_BUILD_LOCK_HELD=1 tells the build tool that
# php_build_ensure calls (and that inherits the fd) not to take it again,
# which would deadlock.
php_upgrade_lock_acquire() {
  local lock=${SETUP_BUILD_LOCK:-/run/setup-build.lock}
  [[ -n $PHP_UPGRADE_LOCK_FD || ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]] && return 0
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock not available; the build timers are not held off during the PHP switch"
    return 0
  fi
  # /run is root-owned; refuse a planted symlink as acquire_run_lock does.
  [[ -L $lock ]] && die "Refusing to open the build lock ${lock}: it is a symlink. Nothing was changed."
  exec {PHP_UPGRADE_LOCK_FD}>>"$lock" || die "Cannot open the build lock ${lock}. Nothing was changed."
  if ! flock -n "$PHP_UPGRADE_LOCK_FD"; then
    info "Waiting for another build to finish (${lock})"
    flock -w "${SETUP_BUILD_LOCK_TIMEOUT:-21600}" "$PHP_UPGRADE_LOCK_FD" \
      || die "Timed out waiting for the build lock ${lock}. Nothing was changed."
  fi
  export SETUP_BUILD_LOCK_HELD=1
  return 0
}

php_upgrade_lock_release() {
  [[ -n $PHP_UPGRADE_LOCK_FD ]] || return 0
  exec {PHP_UPGRADE_LOCK_FD}>&-
  PHP_UPGRADE_LOCK_FD=""
  unset SETUP_BUILD_LOCK_HELD
  return 0
}

# Handover window output.  A dropped SSH session HUPs the run-log tee
# (lib/common.sh) or an outer `| tee`: that process inherited the default
# disposition before any trap here, so it dies, and the next write would
# raise SIGPIPE in this shell.  The `exit 141` PIPE trap would then end the
# run, and the rollback in on_exit would die on its own first warn.  So for
# the window this shell ignores HUP and PIPE (the caller sets that), and its
# output goes through a tee that ignores HUP, PIPE and INT and keeps writing
# to MANIFEST/handover.log when the terminal side is gone (tee -p).  The
# previous dispositions and fds come back in php_upgrade_window_end.
php_upgrade_window_begin() {
  PHP_UPGRADE_WINDOW_TEE=0
  [[ -n $PHP_UPGRADE_MANIFEST_DIR && -d $PHP_UPGRADE_MANIFEST_DIR ]] || return 0
  tee -p </dev/null >/dev/null 2>&1 || return 0
  exec {PHP_UPGRADE_SAVED_OUT}>&1 {PHP_UPGRADE_SAVED_ERR}>&2
  exec > >(trap '' HUP PIPE INT; exec tee -p -a "${PHP_UPGRADE_MANIFEST_DIR}/handover.log") 2>&1
  PHP_UPGRADE_WINDOW_TEE=1
  return 0
}

php_upgrade_window_end() {
  if (( PHP_UPGRADE_WINDOW_TEE )); then
    exec 1>&"$PHP_UPGRADE_SAVED_OUT" 2>&"$PHP_UPGRADE_SAVED_ERR"
    exec {PHP_UPGRADE_SAVED_OUT}>&- {PHP_UPGRADE_SAVED_ERR}>&-
    PHP_UPGRADE_SAVED_OUT=""
    PHP_UPGRADE_SAVED_ERR=""
    PHP_UPGRADE_WINDOW_TEE=0
  fi
  trap - HUP PIPE
  if [[ -n $PHP_UPGRADE_SAVED_TRAPS ]]; then eval "$PHP_UPGRADE_SAVED_TRAPS"; fi
  PHP_UPGRADE_SAVED_TRAPS=""
  return 0
}

# Every PHP version this host knows: setup builds, /etc/php trees and
# phpX.Y-fpm unit files (ours or a leftover package unit).
php_upgrade_known_versions() {
  local d v
  {
    php_upgrade_installed_versions
    for d in /etc/php/[0-9]*.[0-9]* /etc/systemd/system/php*-fpm.service \
             /lib/systemd/system/php*-fpm.service /usr/lib/systemd/system/php*-fpm.service; do
      [[ -e $d ]] || continue
      v=${d##*/}; v=${v#php}; v=${v%-fpm.service}
      [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$v"
    done
  } | sort -Vu
  return 0
}

# After the commit exactly one phpX.Y-fpm unit may be enabled and active
# (R32, R61 item 7): every unit binds the shared socket, so a second enabled
# one, even stopped now, races the target for it at boot.  Another enabled
# unit of ours that is not running is disabled (not masked; --upgrade-php
# can still switch to it).  One that is running, or a package unit, is left
# alone and reported.  Returns 1 when more than one stays enabled or active.
php_upgrade_single_unit() {
  local target=$1 v rc=0 ours
  while IFS= read -r v; do
    [[ -n $v && $v != "$target" ]] || continue
    if systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
      warn "php${v}-fpm is still running beside PHP ${target}; only one PHP version may serve (stop and disable it, or run --optimize)"
      rc=1
      continue
    fi
    systemctl is-enabled --quiet "php${v}-fpm" 2>/dev/null || continue
    ours=0
    if declare -F php_build_unit_is_ours >/dev/null; then
      php_build_unit_is_ours "$v" 2>/dev/null && ours=1
    elif grep -qF "$(php_upgrade_root)/${v}/" "/etc/systemd/system/php${v}-fpm.service" 2>/dev/null; then
      ours=1
    fi
    if (( ours )) && systemctl disable "php${v}-fpm" 2>/dev/null; then
      info "Disabled php${v}-fpm (enabled but stopped; it would race PHP ${target} for the socket at boot)"
    else
      warn "php${v}-fpm is enabled beside PHP ${target}; it would race for the socket at boot (systemctl disable php${v}-fpm)"
      rc=1
    fi
  done < <(php_upgrade_known_versions)
  systemctl is-enabled --quiet "php${target}-fpm" 2>/dev/null \
    || { warn "php${target}-fpm is not enabled; PHP would not start at boot"; rc=1; }
  systemctl is-active --quiet "php${target}-fpm" 2>/dev/null \
    || { warn "php${target}-fpm is not active"; rc=1; }
  return "$rc"
}

# Unit state for the report: systemctl prints inactive/failed and exits
# non-zero, so the fallback applies only to empty output.
php_upgrade_unit_state() {
  local st
  st=$(systemctl is-active "$1" 2>/dev/null || true)
  printf '%s' "${st:-unknown}"
}

# The interface named in the design (section 11): php_upgrade_run X.Y.  It
# sets UPGRADE_PHP and runs the driver below (lib/restart.sh still calls
# run_php_upgrade, which reads UPGRADE_PHP from the command line).  Call it
# plainly, like the driver.
php_upgrade_run() {
  [[ -n ${1:-} ]] && UPGRADE_PHP=$1
  run_php_upgrade
}

# Mode driver.  A plain return keeps set -e and the ERR trap live inside the
# helpers; handled_return() marks an explained failure for the EXIT trap.
run_php_upgrade() {
  local target=$UPGRADE_PHP cur start rc=0 report log entry reason
  local -a refusals=()
  start=$(date +%s)
  step "PHP upgrade to ${target}"
  php_upgrade_validate_target "$target"
  mapfile -t refusals < <(php_upgrade_refusals)
  if (( ${#refusals[@]} > 0 )); then
    for reason in "${refusals[@]}"; do warn "  - ${reason}"; done
    die "Refusing --upgrade-php=${target}: ${refusals[0]}. Nothing was changed."
  fi
  cur=$(php_upgrade_current_version)
  [[ -n $cur ]] || die "No active PHP build on this host; install PHP with --php ver=${target}. Nothing was changed."
  php_upgrade_fpm_installed "$cur" \
    || die "PHP ${cur} is not a setup source build; run --optimize first. Nothing was changed."
  # 1.21's apt flow recorded extensions Sury had not published yet; a source
  # build has no such state.
  rm -f "${STATE_DIR}/php-pending-extensions"
  # A --php ext= of this run is recorded before the set is planned, so the
  # plan, the build (php_build_ensure applies it again: idempotent) and the
  # binding gate all see it.
  if declare -F php_ext_request_apply >/dev/null; then php_ext_request_apply; fi
  local exts_rc=0
  # The set of the TARGET build (php_build_effective_exts TARGET), which for
  # a new series includes the current build's set (B's _pb_prev_union): the
  # plan, the build and the binding gate on the candidate's -m agree.
  # php_build_effective_exts prints the unbuildable name on stderr.
  PHP_UPGRADE_EXTS=$(php_upgrade_effective_exts "$target") || exts_rc=$?
  (( exts_rc == 0 )) \
    || die "Could not compute the PHP extension set (php_build_effective_exts: see the reason above; fix --php ext= or set SETUP_PHP_ALLOW_MISSING_EXT=1). Nothing was changed."
  [[ -n $PHP_UPGRADE_EXTS ]] || die "Could not compute the PHP extension set (php_build_effective_exts). Nothing was changed."
  info "Current PHP: ${cur}; extension set: $(printf '%s' "$PHP_UPGRADE_EXTS" | paste -sd' ' -)"

  if [[ $target == "$cur" ]]; then
    # Never take the serving version down to end where it started: rebuild
    # only when stale (B's check), the running binary serves until the new
    # one passes verify.  The upgrade context takes the build lock itself.
    PHP_UPGRADE_MODE=rebuild
    PHP_UPGRADE_OLD_VERSION=$cur
    local ensure_rc=0
    php_upgrade_checked php_build_ensure "$target" full upgrade info || ensure_rc=$?
    if (( ensure_rc == 0 )); then
      ok "PHP ${target} is active and its build is current"
    else
      warn "PHP ${target} rebuild failed; the existing build keeps serving"
      rc=1
    fi
    handled_return "$rc"
    return "$rc"
  fi

  PHP_UPGRADE_MODE=upgrade
  php_upgrade_fpm_installed "$target" && PHP_UPGRADE_MODE=rollback
  PHP_UPGRADE_MANIFEST_DIR="${STATE_DIR}/php-upgrade-$(date -u +%Y%m%d-%H%M%S)"
  PHP_UPGRADE_NGINX_ACTIVE=0
  systemctl is-active --quiet nginx 2>/dev/null && PHP_UPGRADE_NGINX_ACTIVE=1

  # Gate: refuse while nothing has changed yet.
  if systemctl is-active --quiet "php${target}-fpm" 2>/dev/null; then
    die "php${target}-fpm is already running beside PHP ${cur}; only one PHP version may serve (run --optimize to fix). Nothing was changed."
  fi
  php_upgrade_preflight_apps "$target"
  for entry in "${PHP_UPGRADE_NOT_LOADED[@]}"; do info "$(php_upgrade_describe_waived "$entry")"; done
  php_upgrade_app_cautions "$target"
  for entry in "${PHP_UPGRADE_CAUTIONS[@]}"; do warn "$(php_upgrade_describe_caution "$entry")"; done
  if (( ${#PHP_UPGRADE_BLOCKERS[@]} > 0 )); then
    warn "PHP ${target} cannot serve every installed application:"
    for entry in "${PHP_UPGRADE_BLOCKERS[@]}"; do warn "  - $(php_upgrade_describe_blocker "$entry")"; done
    if [[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} == 1 ]]; then
      warn "SETUP_PHP_ALLOW_MISSING_EXT=1: continuing, the affected sites will fail"
    else
      die "Refusing to replace PHP ${cur} with PHP ${target}: the site(s) above would break. Nothing was changed. Choose a PHP version every site supports, add a missing extension with --php ext=, or re-run with SETUP_PHP_ALLOW_MISSING_EXT=1 to accept the breakage."
    fi
  fi
  mapfile -t PHP_UPGRADE_CONFLICTS < <(php_upgrade_listen_conflicts "$cur" "$target")
  if (( ${#PHP_UPGRADE_CONFLICTS[@]} > 0 )); then
    for entry in "${PHP_UPGRADE_CONFLICTS[@]}"; do warn "  - $(php_upgrade_describe_conflict "$entry")"; done
    die "Refusing to switch to PHP ${target}: another PHP version serves a listener it would take over. Nothing was changed. Run --optimize first (one active PHP version)."
  fi
  # Early estimate from the planned set; the binding check runs on the
  # candidate's real module list before the handover.
  php_upgrade_dropped_modules "$cur" "$target"
  for entry in "${PHP_UPGRADE_SKIPPED[@]}"; do warn "Planned set drops: ${entry}"; done

  php_upgrade_snapshot "$cur"
  ok "Snapshot: ${PHP_UPGRADE_MANIFEST_DIR}"
  # Keep the PHP timezone the old tree used: --upgrade-php has no --basic
  # time= to pass, and the host zone can differ from what the sites ran on.
  PHP_INI_TZ=$(ini_get "/etc/php/${cur}/fpm/conf.d/custom_dan.ini" date.timezone)
  [[ -n $PHP_INI_TZ ]] && info "Keeping PHP timezone: ${PHP_INI_TZ}"

  # Build while the current version serves.  The target unit is neither
  # enabled nor active, so activation only installs the build and its unit.
  step "Building PHP ${target} (PHP ${cur} keeps serving)"
  # From here to the commit the build lock is held (R65(c)(e)): the refresh
  # chain, BOLT, the CPU chain and setup-php-build@ cannot rebuild, activate
  # or restart a version while the switch lays out, hands over and verifies.
  php_upgrade_lock_acquire
  local ensure_rc=0
  php_upgrade_checked php_build_ensure "$target" build-only upgrade info || ensure_rc=$?
  if (( ensure_rc == 0 )); then
    php_upgrade_checked php_build_ensure "$target" activate upgrade info || ensure_rc=$?
  fi
  if (( ensure_rc != 0 )); then
    php_upgrade_abort_prepare "$target" "PHP ${target} build failed"
    handled_return 1
    return 1
  fi
  if systemctl is-active --quiet "php${target}-fpm" 2>/dev/null; then
    # Activation must not start a unit that is neither enabled nor active.
    # If it did, the new master unlinked and re-bound the shared socket
    # with an empty tree: stop it and restart the current version so the
    # socket is its own again, then refuse.
    systemctl stop "php${target}-fpm" 2>/dev/null || true
    php_upgrade_prepare_runtime
    systemctl restart "php${cur}-fpm" 2>/dev/null || true
    php_upgrade_abort_prepare "$target" "The build activation started php${target}-fpm on its own; PHP ${cur} was restarted to own the socket again"
    handled_return 1
    return 1
  fi

  step "Laying out /etc/php/${target} from PHP ${cur}"
  # A kept tree from an earlier switch is replaced by the current version's
  # (the newest operator state); it moves into the manifest, never deleted.
  # From the move on, a die or set -e (carry-over, ini sync, layout) ends in
  # on_exit: PHP_UPGRADE_IN_FLIGHT with phase "prepare" makes its
  # php_upgrade_rollback move the half-generated tree aside and put the kept
  # one back, without restarting the version that still serves.  The prior
  # tree and the generated flag are recorded only once each step succeeded,
  # so a failed move can never send the kept tree to failed/.
  PHP_UPGRADE_PRIOR_TREE=""
  PHP_UPGRADE_TREE_GENERATED=0
  PHP_UPGRADE_PHASE=prepare
  PHP_UPGRADE_IN_FLIGHT=1
  if [[ -d /etc/php/$target ]]; then
    mv -- "/etc/php/$target" "${PHP_UPGRADE_MANIFEST_DIR}/prior-php-${target}"
    PHP_UPGRADE_PRIOR_TREE="${PHP_UPGRADE_MANIFEST_DIR}/prior-php-${target}"
  fi
  PHP_UPGRADE_TREE_GENERATED=1
  local carry_rc=0
  php_upgrade_carry_config "$cur" "$target" || carry_rc=$?
  if (( carry_rc != 0 )); then
    php_upgrade_abort_prepare "$target" "Could not copy PHP ${cur}'s configuration to /etc/php/${target}"
    handled_return 1
    return 1
  fi
  if declare -F sync_php_ini_template >/dev/null; then
    PHP_INI_TZ="${PHP_INI_TZ:-}" sync_php_ini_template "$target" || true
  fi
  local layout_rc=0
  php_upgrade_checked php_build_layout "$target" || layout_rc=$?
  if (( layout_rc != 0 )); then
    php_upgrade_abort_prepare "$target" "php_build_layout ${target} failed"
    handled_return 1
    return 1
  fi
  log=$(tmp_file)
  if ! php_upgrade_fpm_test_clean "$target" "$log"; then
    sed 's/^/  /' "$log" >&2 || true
    cp -p "$log" "${PHP_UPGRADE_MANIFEST_DIR}/php-fpm-t-${target}.log" 2>/dev/null || true
    php_upgrade_abort_prepare "$target" "php-fpm -t rejects PHP ${target} with the carried configuration (or prints load warnings)"
    handled_return 1
    return 1
  fi
  rm -f "$log"
  ok "PHP ${target} configuration passes php-fpm -t (${#PHP_UPGRADE_CARRIED[@]} file(s) carried)"

  # Binding gate on what the candidate really loads (its FPM `-m` with the
  # laid-out ini, so a < 8.5 OPcache counts): every application requirement
  # the current PHP meets, and every module the current PHP loads, must be
  # there.  The planned set above is only an estimate of this.
  local newmods planned=$PHP_UPGRADE_EXTS
  newmods=$(php_upgrade_loaded_modules "$target")
  if [[ -z $newmods ]]; then
    php_upgrade_abort_prepare "$target" "Could not list the modules of the PHP ${target} build"
    handled_return 1
    return 1
  fi
  PHP_UPGRADE_EXTS=$newmods
  php_upgrade_preflight_apps "$target"
  php_upgrade_dropped_modules "$cur" "$target"
  PHP_UPGRADE_EXTS=$planned
  printf '%s\n' "$newmods" > "${PHP_UPGRADE_MANIFEST_DIR}/modules-${target}.txt"
  if (( ${#PHP_UPGRADE_BLOCKERS[@]} + ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then
    for entry in "${PHP_UPGRADE_BLOCKERS[@]}"; do warn "  - $(php_upgrade_describe_blocker "$entry")"; done
    for entry in "${PHP_UPGRADE_SKIPPED[@]}"; do warn "  - ${entry}"; done
    if [[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} == 1 ]]; then
      warn "SETUP_PHP_ALLOW_MISSING_EXT=1: switching although the PHP ${target} build lacks the module(s) above"
    else
      php_upgrade_abort_prepare "$target" "The PHP ${target} build lacks module(s) the sites use (re-run with SETUP_PHP_ALLOW_MISSING_EXT=1 to accept)"
      handled_return 1
      return 1
    fi
  fi
  php_upgrade_http_probe before

  # Handover.  From the stop until the target serves, the host has no PHP:
  # on_exit rolls back while PHP_UPGRADE_IN_FLIGHT is set, and HUP and PIPE
  # are ignored (output through the window tee, php_upgrade_window_begin) so
  # a closed SSH session cannot stop the switch, or its rollback, halfway.
  step "Switching PHP ${cur} -> ${target}"
  PHP_UPGRADE_SAVED_TRAPS=$(trap -p HUP PIPE)
  PHP_UPGRADE_PHASE=handover
  PHP_UPGRADE_IN_FLIGHT=1
  trap "" HUP PIPE
  php_upgrade_window_begin
  systemctl stop "php${cur}-fpm" 2>/dev/null || true
  php_upgrade_prepare_runtime
  local start_rc=0
  php_upgrade_start_wait "$target" || start_rc=$?
  if (( start_rc != 0 )); then
    warn "PHP ${target} did not come up on its listeners; rolling back"
    PHP_UPGRADE_IN_FLIGHT=0
    php_upgrade_rollback || warn "Rollback to PHP ${cur} did not complete"
    report=$(php_upgrade_write_report "$target" 1)
    warn "Report: ${report}"
    php_upgrade_lock_release
    php_upgrade_window_end
    handled_return 1
    return 1
  fi
  php_upgrade_set_active "$target"
  ok "PHP ${target} serves on the shared socket"

  step "Applying the shared PHP profile"
  php_upgrade_optimize
  (( PHP_UPGRADE_OPTIMIZE_OK == 1 )) || rc=1
  php_upgrade_reload_nginx || rc=1
  php_upgrade_verify "$target" || rc=1
  if (( PHP_UPGRADE_VERIFY_HARD )); then
    warn "PHP ${target} failed verification; rolling back"
    PHP_UPGRADE_IN_FLIGHT=0
    php_upgrade_rollback || warn "Rollback to PHP ${cur} did not complete"
    report=$(php_upgrade_write_report "$target" 1)
    warn "Report: ${report}"
    php_upgrade_lock_release
    php_upgrade_window_end
    handled_return 1
    return 1
  fi
  # Committed: the target starts at boot, the previous version does not (both
  # bind the shared socket; whichever started last would serve).  Disable,
  # not mask, so --upgrade-php=OLD can switch back.
  systemctl enable "php${target}-fpm" 2>/dev/null || { warn "Could not enable php${target}-fpm"; rc=1; }
  systemctl disable "php${cur}-fpm" 2>/dev/null || { warn "Could not disable php${cur}-fpm"; rc=1; }
  PHP_UPGRADE_IN_FLIGHT=0
  PHP_UPGRADE_PHASE=""

  php_upgrade_retire_older "$target" "$cur"
  # php_build_purge may re-point the links at the newest remaining build.
  php_upgrade_set_active "$target"
  php_upgrade_remove_stale_dropins
  # Exactly one phpX.Y-fpm enabled and active (R32): a third version left
  # enabled would race the target for the shared socket at boot.
  local units_rc=0
  php_upgrade_single_unit "$target" || units_rc=$?
  if (( units_rc == 0 )); then PHP_UPGRADE_UNITS_OK=yes; else PHP_UPGRADE_UNITS_OK=no; rc=1; fi
  if (( ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then rc=1; fi
  php_upgrade_lock_release

  report=$(php_upgrade_write_report "$target" "$rc")
  printf '\n%sPHP upgrade summary%s\n' "$C_BOLD" "$C_RESET"
  printf '%-24s %s\n' 'From' "$cur"
  printf '%-24s %s\n' 'To' "$target"
  printf '%-24s %s\n' 'Mode' "$PHP_UPGRADE_MODE"
  printf '%-24s %s\n' 'Extensions' "$(printf '%s' "$PHP_UPGRADE_EXTS" | wc -l | tr -d ' ')"
  printf '%-24s %s\n' 'Not carried' "${#PHP_UPGRADE_SKIPPED[@]}"
  printf '%-24s %s\n' 'FPM' "$(php_upgrade_unit_state "php${target}-fpm")"
  printf '%-24s %s\n' 'PHP pages probed' "${PHP_UPGRADE_PROBE_OK} OK"
  printf '%-24s %s\n' 'nginx' "$([[ $PHP_UPGRADE_NGINX_ACTIVE == 1 ]] && printf reloaded || printf not-running)"
  printf '%-24s %s\n' 'Rollback' "--upgrade-php=${cur} (kept, disabled)"
  printf '%-24s %s\n' 'Snapshot' "${PHP_UPGRADE_MANIFEST_DIR}"
  printf '%-24s %s\n' 'Report' "$report"
  printf '%-24s %s\n' 'Duration' "$(format_duration $(( $(date +%s) - start )))"
  if (( rc == 0 )); then
    ok "PHP ${target} is built, tuned and serving"
  else
    warn "PHP ${target} is serving, but one or more checks reported a problem; see the report"
  fi
  # The window tee stays until the summary is out, so a session dropped
  # right after the commit still leaves the whole run in handover.log.
  php_upgrade_window_end
  handled_return "$rc"
  return "$rc"
}
