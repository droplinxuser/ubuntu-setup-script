# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Opt-in compiled php-fpm (PHP_BUILD=clang or PHP_BUILD=lean)
# ---------------------------------------------------------------------------
# Three choices for the php-fpm binary the unit starts:
#   (unset)/package  the Sury package's php-fpm (the default)
#   clang            the package's PHP version and compiled-in core rebuilt
#                    with clang (apt.llvm.org), -O3 -march=native, ThinLTO
#                    and BOLT; Sury's shared extensions load unchanged
#   lean             WordPress, XenForo, Chevereto: the newest PHP, redis/igbinary and every
#                    linked library from upstream sources (versions in
#                    php-build.conf), statically linked, ThinLTO and BOLT,
#                    with only the modules the three applications use
# php.ini, pools, the unit and the package CLI stay the package's in every
# mode.  tools/php-fpm-build.sh does the work and goes back to the package
# binary when an APT update changes the package; a daily timer rebuilds when
# a newer upstream release appears.  Measured (1.21.68, Xeon E-2236): see
# tests/stress-site/RESULTS.md.
#
# The choice is persisted in /etc/default/setup-tuning like PHP_JIT_WORDPRESS,
# so the install, a later --optimize and --upgrade-php reach the same state.
# PHP_BUILD=package (or sury) goes back to the package binary and removes
# the build.

PHP_BUILD_ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
PHP_BUILD_TOOL="${PHP_BUILD_ROOT}/php-fpm-build.sh"
PHP_BUILD_APT_HOOK=${PHP_BUILD_APT_HOOK:-/etc/apt/apt.conf.d/99setup-php-fpm-build}
PHP_BUILD_UNIT=${PHP_BUILD_UNIT:-/etc/systemd/system/setup-php-fpm-build@.service}
PHP_BUILD_REFRESH_UNIT=${PHP_BUILD_REFRESH_UNIT:-/etc/systemd/system/setup-php-fpm-build-refresh.service}
PHP_BUILD_REFRESH_TIMER=${PHP_BUILD_REFRESH_TIMER:-/etc/systemd/system/setup-php-fpm-build-refresh.timer}
PHP_BUILD_CONF_FILE="${PHP_BUILD_ROOT}/php-build.conf"
# apt.llvm.org source the tool adds (removed with the last build).
PHP_BUILD_LLVM_FILES=(/etc/apt/sources.list.d/setup-llvm.sources /etc/apt/preferences.d/setup-llvm.pref /etc/apt/keyrings/setup-llvm.asc)

# "clang", "lean", "package", or "" (never chosen on this host: nothing to do).
php_build_mode() {
  local v=${PHP_BUILD:-}
  case ${v,,} in
    "")                      printf '' ;;
    clang)                   printf 'clang' ;;
    lean|upstream)           printf 'lean' ;;
    package|sury|off|none|0) printf 'package' ;;
    *)                       printf 'invalid' ;;
  esac
}

# Refuse an unknown value before anything changes (setup.sh sets PHP_BUILD
# and PHP_BUILD_PERSIST from SETUP_PHP_BUILD or the host file).
php_build_validate() {
  if [[ $(php_build_mode) == invalid ]]; then
    die "PHP_BUILD='${PHP_BUILD}' is not supported; use package, clang or lean"
  fi
  return 0
}

php_build_persist() {
  (( PHP_BUILD_PERSIST )) || return 0
  persist_tuning_var PHP_BUILD "$(php_build_mode)"
  tune_note "PHP: PHP_BUILD=$(php_build_mode) persisted in /etc/default/setup-tuning"
}

# Install (or refresh) the tool, the background rebuild unit and the APT hook.
php_build_install_support() {
  local src="${SCRIPT_DIR}/tools/php-fpm-build.sh" unit hook
  [[ -f $src ]] || { warn "PHP_BUILD: ${src} is missing from this checkout"; return 1; }
  install -d -m 755 "$PHP_BUILD_ROOT"
  if ! cmp -s "$src" "$PHP_BUILD_TOOL"; then
    install -m 755 "$src" "$PHP_BUILD_TOOL"
  fi
  unit=$(php_build_unit_text)
  if [[ ! -f $PHP_BUILD_UNIT ]] || [[ $(cat "$PHP_BUILD_UNIT") != "$unit" ]]; then
    printf '%s\n' "$unit" > "$PHP_BUILD_UNIT"
    systemctl daemon-reload 2>/dev/null || true
  fi
  hook=$(php_build_apt_hook_text)
  if [[ ! -f $PHP_BUILD_APT_HOOK ]] || [[ $(cat "$PHP_BUILD_APT_HOOK") != "$hook" ]]; then
    printf '%s\n' "$hook" > "$PHP_BUILD_APT_HOOK"
  fi
  # The versions file beside setup.sh is the source of truth; the installed
  # copy is what the APT hook and the daily timer build from.
  if [[ -f ${SCRIPT_DIR}/php-build.conf ]] && ! cmp -s "${SCRIPT_DIR}/php-build.conf" "$PHP_BUILD_CONF_FILE"; then
    install -m 644 "${SCRIPT_DIR}/php-build.conf" "$PHP_BUILD_CONF_FILE"
  fi
  local refresh timer changed=0
  refresh=$(php_build_refresh_unit_text); timer=$(php_build_refresh_timer_text)
  if [[ ! -f $PHP_BUILD_REFRESH_UNIT ]] || [[ $(cat "$PHP_BUILD_REFRESH_UNIT") != "$refresh" ]]; then
    printf '%s\n' "$refresh" > "$PHP_BUILD_REFRESH_UNIT"; changed=1
  fi
  if [[ ! -f $PHP_BUILD_REFRESH_TIMER ]] || [[ $(cat "$PHP_BUILD_REFRESH_TIMER") != "$timer" ]]; then
    printf '%s\n' "$timer" > "$PHP_BUILD_REFRESH_TIMER"; changed=1
  fi
  if (( changed )); then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "${PHP_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  fi
  return 0
}

php_build_refresh_unit_text() {
  cat <<EOF
# Managed by setup.sh (PHP_BUILD=clang/lean): rebuild php-fpm when php.net, PECL,
# LLVM or a linked library published a release php-build.conf asks for.
[Unit]
Description=Check for newer upstream releases of the compiled php-fpm (setup.sh PHP_BUILD)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PHP_BUILD_TOOL} refresh
Nice=19
IOSchedulingClass=idle
EOF
}

php_build_refresh_timer_text() {
  cat <<EOF
# Managed by setup.sh (PHP_BUILD=clang/lean)
[Unit]
Description=Daily upstream release check for the compiled php-fpm

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

php_build_unit_text() {
  cat <<EOF
# Managed by setup.sh (PHP_BUILD=clang/lean): rebuild php-fpm for PHP %i (started by
# the APT hook after a package update, or by the daily upstream check).
[Unit]
Description=Rebuild the compiled php-fpm for PHP %i (setup.sh PHP_BUILD)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PHP_BUILD_TOOL} rebuild %i
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
}

php_build_apt_hook_text() {
  cat <<EOF
// Managed by setup.sh (PHP_BUILD=clang/lean): after any dpkg run, a PHP version
// whose package changed goes back to the package's php-fpm at once and is
// rebuilt in the background (setup-php-fpm-build@X.Y.service).
DPkg::Post-Invoke { "if [ -x ${PHP_BUILD_TOOL} ]; then ${PHP_BUILD_TOOL} apt-hook || true; fi"; };
EOF
}

php_build_remove_support() {
  local d
  for d in "$PHP_BUILD_ROOT"/*/; do
    [[ -d $d ]] && return 0   # another version still uses it
  done
  systemctl disable --now "${PHP_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  rm -f "$PHP_BUILD_APT_HOOK" "$PHP_BUILD_UNIT" "$PHP_BUILD_TOOL" "$PHP_BUILD_CONF_FILE" \
    "$PHP_BUILD_REFRESH_UNIT" "$PHP_BUILD_REFRESH_TIMER" "${PHP_BUILD_LLVM_FILES[@]}"
  rm -rf /var/cache/setup-php-build /run/setup-php-build
  rmdir "$PHP_BUILD_ROOT" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

# The build of VER is current: started by the unit, of MODE, and carrying
# every version php-build.conf resolves to (the tool's `check`).  When a
# version cannot be looked up (offline), the running build counts as current.
PHP_BUILD_CHECK_OUT=""
php_build_current() {
  local ver=$1 mode=$2 rc=0
  PHP_BUILD_CHECK_OUT=""
  [[ -f ${PHP_BUILD_ROOT}/${ver}/build.info && -f /etc/systemd/system/php${ver}-fpm.service.d/zz-setup-build.conf ]] || return 1
  PHP_BUILD_CHECK_OUT=$("$PHP_BUILD_TOOL" check "$ver" "$mode" 2>&1) || rc=$?
  (( rc != 10 ))
}

php_build_bolted() {
  grep -qx 'bolt=1' "${PHP_BUILD_ROOT}/${1}/build.info" 2>/dev/null
}

# Bring PHP VER to the chosen build.  CONTEXT is "install" (no traffic yet:
# build only) or "optimize" (also BOLT when the site serves traffic).
# Prints report lines through the given function (opt_report or info).
php_build_apply() {
  local ver=$1 context=${2:-optimize} out=${3:-info} mode rc=0
  mode=$(php_build_mode)
  case $mode in
    "") return 0 ;;
    package)
      if [[ -f /etc/systemd/system/php${ver}-fpm.service.d/zz-setup-build.conf || -d ${PHP_BUILD_ROOT}/${ver} ]]; then
        if [[ -x $PHP_BUILD_TOOL ]] && "$PHP_BUILD_TOOL" remove "$ver" >/dev/null 2>&1; then
          "$out" "- PHP_BUILD=package: PHP ${ver} back on the package's php-fpm; build removed"
        else
          rm -f "/etc/systemd/system/php${ver}-fpm.service.d/zz-setup-build.conf"
          rm -rf "${PHP_BUILD_ROOT:?}/${ver}"
          systemctl daemon-reload 2>/dev/null || true
          systemctl restart "php${ver}-fpm" 2>/dev/null || true
          "$out" "- PHP_BUILD=package: PHP ${ver} drop-in removed by hand (the tool was missing)"
        fi
      fi
      php_build_remove_support
      return 0
      ;;
  esac
  php_build_install_support || return 1
  local tag="PHP_BUILD=${mode}" what
  what="the package's PHP version with clang and Sury's extensions (3-6 minutes)"
  [[ $mode == lean ]] && what="a lean php-fpm for WordPress, XenForo and Chevereto from upstream sources (15-25 minutes with the libraries, 3-6 when only PHP changed)"
  if ! php_build_current "$ver" "$mode"; then
    [[ -n $PHP_BUILD_CHECK_OUT ]] && "$out" "- ${tag}: PHP ${ver} build ${PHP_BUILD_CHECK_OUT}"
    "$out" "- ${tag}: building ${what}"
    if "$PHP_BUILD_TOOL" build "$ver" "$mode" > "${PHP_BUILD_ROOT}/build-${ver}.log" 2>&1; then
      "$out" "- ${tag}: PHP ${ver} now runs the compiled php-fpm ($("$PHP_BUILD_TOOL" status "$ver"))"
    else
      "$out" "- **FAILED** ${tag} build for PHP ${ver}; the previous php-fpm keeps serving (log: ${PHP_BUILD_ROOT}/build-${ver}.log)"
      tail -n 5 "${PHP_BUILD_ROOT}/build-${ver}.log" >&2 2>/dev/null || true
      return 1
    fi
  else
    "$out" "- ${tag}: PHP ${ver} build is current ($("$PHP_BUILD_TOOL" status "$ver"))"
  fi
  if [[ $context == optimize ]] && ! php_build_bolted "$ver" \
     && [[ ${SETUP_PHP_BUILD_BOLT:-1} == 1 ]]; then
    "$PHP_BUILD_TOOL" bolt "$ver" "${SETUP_PHP_BUILD_BOLT_SECONDS:-60}" > "${PHP_BUILD_ROOT}/bolt-${ver}.log" 2>&1 || rc=$?
    case $rc in
      0) "$out" "- ${tag}: BOLT applied to PHP ${ver} from live traffic" ;;
      3) "$out" "- ${tag}: BOLT skipped for PHP ${ver} (too little traffic in the sample); the next --optimize under load retries" ;;
      *) "$out" "- ${tag}: BOLT not applied for PHP ${ver} ($(tail -n 1 "${PHP_BUILD_ROOT}/bolt-${ver}.log" 2>/dev/null)); the ThinLTO build keeps serving" ;;
    esac
    rc=0
  fi
  return "$rc"
}

# --purge php [ver=X.Y]: back to the package binary for that version (all
# versions without ver=); the tool, unit and APT hook go with the last build.
php_build_purge() {
  local only=${1:-} d ver
  for d in /etc/systemd/system/php*-fpm.service.d/zz-setup-build.conf; do
    [[ -f $d ]] || continue
    ver=${d#/etc/systemd/system/php}; ver=${ver%%-fpm.service.d/*}
    [[ -n $only && $only != "$ver" ]] && continue
    rm -f "$d"
    rm -rf "${PHP_BUILD_ROOT:?}/${ver}"
    info "PHP ${ver}: PHP_BUILD drop-in removed (the package's php-fpm starts again)"
  done
  [[ -z $only ]] && rm -rf "${PHP_BUILD_ROOT:?}"/[0-9]*
  php_build_remove_support
  systemctl daemon-reload 2>/dev/null || true
}

php_build_plan() { # dry-run line
  case $(php_build_mode) in
    clang)   printf 'PHP_BUILD=clang: the package PHP version rebuilt with clang ThinLTO (Sury extensions) for each installed version; BOLT under traffic on --optimize' ;;
    lean)    printf 'PHP_BUILD=lean: lean XenForo php-fpm compiled from upstream sources (versions in php-build.conf) for each installed version; BOLT under traffic on --optimize' ;;
    package) printf 'PHP_BUILD=package: the package php-fpm (any compiled build is removed)' ;;
    *)       printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# PHP-FPM modules: only what the applications need (1.21.68)
# ---------------------------------------------------------------------------
# php-fpm loads only the shared extensions WordPress, XenForo and Chevereto
# need between them (setup.sh's php_upgrade_app_requirements, Chevereto's
# integrity check, WordPress Site Health).  Sury enables every installed
# module for every SAPI; the rest (calendar, ffi, ftp, gettext, phar, posix,
# readline, shmop, sockets, sysv*, tokenizer, xsl, imagick, ...) is disabled
# for php-fpm only with phpdismod, which marks it "disabled by admin" so
# package updates keep it off.  The CLI keeps everything.  A host that serves
# another PHP application (any .php at a vhost root that is none of the
# three) is left alone, and SETUP_PHP_FPM_MODULES=all (persisted as
# PHP_FPM_MODULES) turns the trim off; both re-enable what setup.sh
# disabled, recorded in /etc/php/X.Y/fpm/setup-disabled-modules.
PHP_FPM_APP_MODS=(ctype curl dom exif fileinfo gd gmp iconv igbinary intl json mbstring mysqli
  mysqlnd opcache pdo pdo_mysql redis simplexml sodium xml xmlreader xmlwriter zip)
PHP_FPM_ETC=${PHP_FPM_ETC:-/etc/php}

# "apps" (the default) or "all".
php_fpm_modules_mode() {
  case ${PHP_FPM_MODULES:-apps} in
    all|ALL) printf 'all' ;;
    *)       printf 'apps' ;;
  esac
}

# Vhost document roots that serve PHP but are none of the three applications.
php_fpm_foreign_php_sites() {
  local target=${1:-${PHP_FPM_ANGIE:-/etc/angie}} file root
  local -A seen=()
  [[ -d $target/conf.d ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    root=$(angie_vhost_root "$file")
    [[ -n $root && -d $root && -z ${seen[$root]:-} ]] || continue
    seen[$root]=1
    [[ -n $(app_type_at_root "$root") ]] && continue
    compgen -G "$root/*.php" >/dev/null && printf '%s\n' "$root"
  done
  return 0
}

# Module names enabled for php-fpm VER (conf.d/NN-name.ini with extension=).
php_fpm_enabled_modules() {
  local ini name
  for ini in "$PHP_FPM_ETC/$1/fpm/conf.d"/*.ini; do
    [[ -f $ini ]] || continue
    grep -qE '^[[:space:]]*(zend_)?extension[[:space:]]*=' "$ini" || continue
    name=${ini##*/}; name=${name%.ini}; name=${name#[0-9][0-9]-}
    printf '%s\n' "$name"
  done
}

# Apply the module policy to php-fpm VER.  Prints report lines through OUTFN;
# status 0 when something changed (php-fpm must reload), 1 when not.
php_fpm_modules_apply() {
  local ver=$1 out=${2:-info} state mod foreign changed=1
  local -a off=() on=()
  state="$PHP_FPM_ETC/$ver/fpm/setup-disabled-modules"
  command -v phpdismod >/dev/null 2>&1 || return 1
  foreign=$(php_fpm_foreign_php_sites | tr '\n' ' ')
  if [[ $(php_fpm_modules_mode) == all || -n $foreign ]]; then
    if [[ -s $state ]]; then
      while IFS= read -r mod; do
        [[ -n $mod ]] && phpenmod -v "$ver" -s fpm "$mod" 2>/dev/null && on+=("$mod")
      done < "$state"
      rm -f "$state"
      changed=0
    fi
    if [[ -n $foreign ]]; then
      "$out" "- PHP modules: all installed extensions stay loaded (another PHP application at ${foreign% })${on[*]:+; re-enabled ${on[*]}}"
    elif (( ${#on[@]} )); then
      "$out" "- PHP modules: PHP_FPM_MODULES=all, re-enabled ${on[*]}"
    fi
    return "$changed"
  fi
  while IFS= read -r mod; do
    [[ -n $mod ]] || continue
    [[ " ${PHP_FPM_APP_MODS[*]} " == *" $mod "* ]] && continue
    phpdismod -v "$ver" -s fpm "$mod" 2>/dev/null || continue
    off+=("$mod")
    grep -qxF "$mod" "$state" 2>/dev/null || printf '%s\n' "$mod" >> "$state"
  done < <(php_fpm_enabled_modules "$ver")
  if (( ${#off[@]} )); then
    "$out" "- PHP modules: php-fpm no longer loads ${off[*]} (not needed by WordPress, XenForo or Chevereto; the CLI keeps them; SETUP_PHP_FPM_MODULES=all restores)"
    return 0
  fi
  return 1
}

php_fpm_modules_persist() {
  (( ${PHP_FPM_MODULES_PERSIST:-0} )) || return 0
  persist_tuning_var PHP_FPM_MODULES "$(php_fpm_modules_mode)"
  tune_note "PHP: PHP_FPM_MODULES=$(php_fpm_modules_mode) persisted in /etc/default/setup-tuning"
}
