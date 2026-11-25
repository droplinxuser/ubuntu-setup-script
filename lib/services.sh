# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# APT repositories
# ---------------------------------------------------------------------------
# Add every selected third-party repository first, then run one apt-get update
# in prepare_repositories().  The service installers only install packages.
#
# 1.22.0: nginx, PHP and Valkey are compiled from source (lib/nginx-build.sh,
# lib/php-build.sh, lib/valkey-build.sh), so neither the Angie repository nor
# the Sury repository is configured any more.  Hosts that still have them get
# them retired by the one-time migration in --optimize (lib/migrate.sh), only
# after the compiled builds serve.  Elasticsearch and NodeSource stay apt.
configure_elastic_repo() {
  refresh_blob_key_dearmor /usr/share/keyrings/elasticsearch-keyring.gpg blob_elastic_key \
    || return 1
  chmod 644 /usr/share/keyrings/elasticsearch-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main\n' \
    > /etc/apt/sources.list.d/elastic-9.x.list
  chmod 644 /etc/apt/sources.list.d/elastic-9.x.list
}

# Major version of the Node.js runtime currently on PATH (empty when absent).
node_installed_major() {
  local v=""
  if command -v node >/dev/null 2>&1; then
    v=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) || v=""
  fi
  if [[ -z $v ]]; then
    # node may be installed but not on the caller's PATH; the package version
    # ("26.13.0-1nodesource1") then supplies the same leading major.
    v=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)
    v=${v%%.*}
  fi
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# Refuse to move an existing Node.js install across majors unless the operator
# asked for it.  Returns 0 (warning once) when the switch is blocked, 1 when
# installing NODE_MAJOR is safe.
node_major_switch_blocked() {
  local current
  if (( NODE_MAJOR_SWITCH_BLOCKED )); then
    return 0
  fi
  if (( NODE_ALLOW_MAJOR_UPGRADE == 1 )); then
    return 1
  fi
  current=$(node_installed_major)
  if [[ -z $current || $current == "$NODE_MAJOR" ]]; then
    return 1
  fi
  warn "Node.js ${current}.x is installed; refusing to switch it to ${NODE_MAJOR}.x."
  warn "A new major replaces NODE_MODULE_VERSION and breaks prebuilt native"
  warn "addons (soketi's uWebSockets.js only ships Node 14/16/18 builds)."
  warn "Keep the working runtime:  SETUP_NODE_MAJOR=${current}"
  warn "Allow the switch once:     SETUP_NODE_ALLOW_MAJOR_UPGRADE=1"
  NODE_MAJOR_SWITCH_BLOCKED=1
  return 0
}

# An older run may have left a NodeSource line for another major.  Leaving it
# in place after deciding to keep the installed runtime would let the next
# `apt-get install/upgrade` make the very jump we just refused, so retire it.
node_retire_conflicting_repo() {
  local keep=$1 f=/etc/apt/sources.list.d/nodesource.sources major
  [[ -n $keep && -f $f ]] || return 0
  major=$(sed -n \
    's|^URIs:[[:space:]]*https://deb.nodesource.com/node_\([0-9][0-9]*\)\.x.*|\1|p' \
    "$f" | head -n 1)
  [[ -n $major && $major != "$keep" ]] || return 0
  mv "$f" "${f}.disabled" \
    || { warn "Could not retire ${f}; check it points at ${keep}.x"; return 0; }
  warn "Retired ${f} (it points at ${major}.x) as ${f}.disabled:"
  warn "a later apt install/upgrade could otherwise move the retained ${keep}.x runtime."
}

configure_nodesource_repo() {
  refresh_blob_key_dearmor /usr/share/keyrings/nodesource.gpg blob_nodesource_key \
    || return 1
  chmod 644 /usr/share/keyrings/nodesource.gpg
  cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
  chmod 644 /etc/apt/sources.list.d/nodesource.sources
}

prepare_repositories() {
  local configured=0 item
  apt_install ca-certificates curl gnupg lsb-release apt-transport-https
  # No repository for nginx or PHP: both are built from upstream sources by
  # their install steps (the build tools add apt.llvm.org themselves).
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    configure_elastic_repo || die "Could not configure the Elastic APT repository"
    configured=1
  fi
  if [[ ${ENABLED[others]:-0} -eq 1 ]]; then
    for item in "${OTHERS[@]}"; do
      if [[ $item == nodejs ]]; then
        if node_major_switch_blocked; then
          info "Leaving the installed Node.js runtime unchanged"
          node_retire_conflicting_repo "$(node_installed_major)"
        else
          configure_nodesource_repo || die "Could not configure the NodeSource APT repository"
          configured=1
        fi
        break
      fi
    done
  fi
  if (( configured )); then
    apt_update || die "apt-get update failed after adding the repositories: $(apt_update_failure_hint)"
  fi
}

# ---------------------------------------------------------------------------
# Shared guards of the compiled-service installers (1.22.0)
# ---------------------------------------------------------------------------
# --nginx, --php and --valkey install on a fresh host only.  A host that still
# runs Angie, a Sury/Ubuntu php-fpm package or the valkey-server package is
# moved to the compiled builds once, by the migration that only --optimize
# runs (design REVISION 3, legacy-Angie mode; R19/R51): it builds first,
# switches each service with a verified cutover and rollback, and purges the
# packages last.  An installer that wrote our units next to a serving package
# would race it for the ports and the shared PHP socket, so it refuses
# instead, before anything changes.
#
# services_legacy_block PART: prints why PART (nginx|php|valkey) must not be
# installed here and returns 0; returns 1 (prints nothing) when the install
# may go ahead.
services_legacy_block() {
  local part=$1 u v
  if declare -F migrate_running >/dev/null && migrate_running; then
    printf 'the 1.22 migration is running right now (setup-migrate-1.22.service; follow /var/log/setup-migrate-1.22.log)'
    return 0
  fi
  if declare -F migrate_needed >/dev/null && migrate_needed "$part"; then
    printf 'the one-time 1.22 migration of %s has not finished on this host' "$part"
    return 0
  fi
  case $part in
    nginx)
      # A refused or blocked nginx part leaves Angie serving (migrate_needed
      # then says "nothing to retry"); the ports are still Angie's.
      if declare -F web_server_state >/dev/null; then
        if [[ $(web_server_state) == angie-legacy ]]; then
          printf 'Angie still serves this host (its 1.22 migration is pending or was refused; the --optimize report names the blocker)'
          return 0
        fi
      elif pkg_ok angie; then
        printf 'the Angie package is installed'
        return 0
      fi
      ;;
    php)
      # Any running package php-fpm (Sury, Ubuntu) owns /run/php/php-fpm.sock
      # or a pool of its own; ours would start next to it.
      while IFS= read -r u; do
        [[ $u =~ ^php([0-9]+\.[0-9]+)-fpm\.service$ ]] || continue
        v=${BASH_REMATCH[1]}
        if declare -F php_build_unit_is_ours >/dev/null && php_build_unit_is_ours "$v"; then
          continue
        fi
        printf 'the package unit %s still serves PHP %s' "$u" "$v"
        return 0
      done < <(systemctl list-units --state=active --no-legend --plain 'php*-fpm.service' 2>/dev/null \
                 | awk '{ print $1 }' || true)
      ;;
    valkey)
      if declare -F valkey_pkg_installed >/dev/null; then
        if valkey_pkg_installed valkey-server && ! valkey_unit_is_ours; then
          printf 'the valkey-server package is installed'
          return 0
        fi
      elif pkg_ok valkey-server; then
        printf 'the valkey-server package is installed'
        return 0
      fi
      ;;
  esac
  return 1
}

# The 4 GB class rule (design section 7: hosts under it run nginx only).
# validate_all refuses the request first; this repeats it for a direct
# caller.  Without the gate function (older glue) nothing is refused here.
services_mem_allows() { # php|valkey
  declare -F mem_gate_allows >/dev/null || return 0
  mem_gate_allows "$1"
}

# Keep apt from installing the packages whose paths and unit names the source
# builds own (R71: an unattended upgrade of nginx-core or a php8.x package
# would put its binary and maintainer scripts back under our units).  Same
# file and format as the migration's pin (lib/migrate.sh), merged, so either
# writer keeps the other's families.  Installed packages are not touched by a
# -1 pin; --purge drops a purged component's patterns (and the file when
# none is left: lib/purge.sh purge_apt_pin_remove).
SERVICES_APT_PIN=${MIGRATE_APT_PIN:-/etc/apt/preferences.d/setup-source-builds}
services_apt_pin_add() { # "pattern ..."
  local add=$1 old="" tmp
  [[ -n $add ]] || return 0
  if [[ -f $SERVICES_APT_PIN ]]; then
    old=$(sed -nE 's/^Package: //p' "$SERVICES_APT_PIN" | head -n 1)
  fi
  tmp=$(tmp_file) || return 0
  {
    printf '# Managed by setup.sh 1.22: nginx, PHP and Valkey are built from source\n'
    printf '# (/usr/local/lib/setup-*).  These packages would take back paths and\n'
    printf '# unit names the source builds own.  --purge drops a purged component.\n'
    printf 'Package: %s\nPin: release *\nPin-Priority: -1\n' \
      "$(printf '%s %s\n' "$old" "$add" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -)"
  } > "$tmp"
  install -d -m 755 "${SERVICES_APT_PIN%/*}"
  if commit_if_changed "$SERVICES_APT_PIN" "$tmp"; then
    chmod 644 "$SERVICES_APT_PIN"
    info "apt pin: ${add} kept out of apt (${SERVICES_APT_PIN})"
  fi
  rm -f -- "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# nginx (compiled from nginx.org mainline source)
# ---------------------------------------------------------------------------
# A distro nginx (Ubuntu's nginx-core/-full/..., an ondrej PPA build) owns
# /usr/sbin/nginx, /lib/systemd/system/nginx.service and conffiles at the
# same paths as the server-configs-nginx tree.  Purging it AFTER our tree is
# deployed would let dpkg delete our nginx.conf, mime.types and fastcgi
# files, so the order is (R30/R71): move /etc/nginx aside, purge under the
# collateral guard, daemon-reload, and only then build and deploy.  A distro
# nginx that is serving, or one next to an existing compiled nginx, is left
# alone and the install refuses: taking a running web server down is not
# something --nginx does without being asked.  Uses lib/migrate.sh's exact
# package list and apt simulation (never a glob handed to apt).
services_distro_nginx_clear() {
  local -a pkgs=()
  local dest="" stamp owner
  if declare -F migrate_pkg_list >/dev/null; then
    mapfile -t pkgs < <(migrate_pkg_list distro-nginx)
  elif pkg_ok nginx || pkg_ok nginx-common || pkg_ok nginx-core; then
    die "nginx: a distro nginx package is installed and the package guard (lib/migrate.sh) is not loaded; remove the distro nginx packages first. Nothing was changed"
  fi
  (( ${#pkgs[@]} > 0 )) || return 0
  if systemctl is-active --quiet nginx 2>/dev/null || [[ -x $NGINX_BIN ]]; then
    die "nginx: the distro nginx packages (${pkgs[*]}) are installed on a host that already runs an nginx; --nginx does not replace a serving web server. Stop relying on the distro nginx and purge it (apt-get purge ${pkgs[*]}), then re-run, or run --optimize on a host that the 1.22 migration manages. Nothing was changed"
  fi
  if ! migrate_purge_sim purge "${pkgs[@]}"; then
    die "nginx: apt refuses to purge the distro nginx packages (${pkgs[*]}; see the lines above). Nothing was changed"
  fi
  if (( ${#MIGRATE_SIM_COLLATERAL[@]} > 0 )); then
    die "nginx: purging the distro nginx packages (${pkgs[*]}) would also remove ${MIGRATE_SIM_COLLATERAL[*]}. Re-home or remove those first. Nothing was changed"
  fi
  # Backups live in the 1.22 backup root (R37: 0700 root, trees moved whole).
  if [[ -e /etc/nginx ]]; then
    install -d -m 700 -o root -g root /var/backups/setup-1.22 \
      || die "nginx: could not create /var/backups/setup-1.22"
    chmod 700 /var/backups/setup-1.22
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="/var/backups/setup-1.22/nginx-distro-${stamp}"
    install -d -m 700 "$dest" || die "nginx: could not create ${dest}"
    mv -- /etc/nginx "$dest/nginx" || die "nginx: could not move /etc/nginx to ${dest}"
    info "nginx: the distro /etc/nginx moved to ${dest}/nginx before the package purge"
  fi
  info "nginx: purging the distro nginx packages: ${pkgs[*]}"
  if ! apt-get purge "${APT_OPTS[@]}" "${pkgs[@]}"; then
    if [[ -n $dest && -d $dest/nginx && ! -e /etc/nginx ]]; then
      mv -- "$dest/nginx" /etc/nginx || warn "nginx: could not move ${dest}/nginx back to /etc/nginx"
    fi
    die "nginx: purging the distro nginx packages failed; /etc/nginx was put back. Nothing else was changed"
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed nginx.service >/dev/null 2>&1 || true
  # The unit must never run a dpkg-owned binary again (R71).
  owner=$(dpkg-query -S /usr/sbin/nginx 2>/dev/null || true)
  [[ -z $owner ]] || die "nginx: /usr/sbin/nginx still belongs to a package after the purge (${owner%%:*}); remove it and re-run"
  ok "nginx: distro nginx packages purged (${pkgs[*]})"
}

# --nginx: build nginx from source, deploy the server-configs-nginx tree to
# /etc/nginx, apply the hardware profile, then activate (our own
# nginx.service, binary under /usr/local/lib/setup-nginx).  There is no
# package fallback: a failed build ends the step with the build log's path
# and nothing serves until a re-run succeeds (design section 5).
install_nginx() {
  step "nginx web server (compiled from source)"
  local nginx_backup="" why cand fresh=1
  if why=$(services_legacy_block nginx); then
    die "nginx: ${why}. --nginx installs on a fresh host only; run setup.sh --optimize, which moves this host to the compiled nginx once. Nothing was changed"
  fi
  declare -F nginx_build_ensure >/dev/null \
    || die "nginx: lib/nginx-build.sh is not loaded; 1.22 builds nginx from source and needs the full checkout"
  # Fetch, deploy and TLS helpers (the build tools install their own
  # compiler and library prerequisites).
  apt_install ca-certificates curl wget unzip rsync openssl

  services_distro_nginx_clear
  services_apt_pin_add "nginx nginx-* libnginx-mod-*"

  # A compiled nginx is already here (a re-run of --nginx): keep it serving
  # through the redeploy and let `full` rebuild only when check finds the
  # build stale (in-place binary upgrade, no dropped connection).
  if [[ -x $NGINX_BIN && -f ${NGINX_ROOT}/build/build.info ]]; then
    fresh=0
  fi

  if (( fresh )); then
    # Build and verify into ROOT/staging first: nothing else on the host
    # changes if the build fails.
    if ! nginx_build_ensure build-only install info; then
      warn "nginx: the source build failed (log path above); nothing serves on this host until a re-run of --nginx succeeds"
      return 1
    fi
    cand="${NGINX_BUILD_STAGING}/sbin/nginx"
    [[ -x $cand ]] || { warn "nginx: the build reported success but ${cand} is missing"; return 1; }
  else
    cand=$NGINX_BIN
  fi

  # Keep a copy of the deployed tree so a failed repo deploy/tune can be
  # rolled back instead of leaving a live host with a broken configuration.
  if [[ -d /etc/nginx ]]; then
    nginx_backup=$(tmp_dir nginx-install.XXXXXX) \
      || die "Could not create an nginx backup directory"
    cp -a /etc/nginx "$nginx_backup/" \
      || die "Could not back up /etc/nginx to ${nginx_backup}"
  fi

  # The deployer and the tuner test the tree with NGINX_TEST_BIN: the staged
  # candidate on a fresh host (nothing is installed at NGINX_BIN yet), the
  # installed build on a re-run.  tmpfiles.d/setup-nginx.conf was applied by
  # nginx_build_ensure, so /var/cache/nginx/*_temp exist for `nginx -t`.
  local -x NGINX_TEST_BIN=$cand
  # Fresh host: deploy_nginx_tree fits the rendered tree (operator vhosts
  # included) to the staged candidate before its test, so a directive the
  # lean build leaves out (gzip_static, brotli_static since 1.22.1) is
  # commented out and reported instead of failing --nginx.  activate runs the
  # same fit again against the installed binary (a no-op by then).
  local NGINX_DEPLOY_FIT_BIN=""
  (( fresh )) && NGINX_DEPLOY_FIT_BIN=$cand
  if ! deploy_nginx_configs; then
    rollback_nginx_tree "$nginx_backup"
    return 1
  fi
  chmod 755 /etc/nginx/scripts/cloudflare.sh 2>/dev/null || true

  systemctl daemon-reload
  if ! "$cand" -t; then
    rollback_nginx_tree "$nginx_backup"
    return 1
  fi

  if (( fresh )); then
    # Swap the staged build in, write nginx.service and start it on the
    # deployed tree (the tool comments out directives of modules the lean
    # build leaves out, reported in the run log).
    if ! nginx_build_ensure activate install info; then
      rollback_nginx_tree "$nginx_backup"
      return 1
    fi
  else
    if ! nginx_build_ensure full install info; then
      rollback_nginx_tree "$nginx_backup"
      return 1
    fi
    # The redeployed tree reaches a running master through a graceful reload.
    if systemctl is-active --quiet nginx; then
      systemctl reload nginx || systemctl restart nginx || {
        rollback_nginx_tree "$nginx_backup"
        return 1
      }
    fi
  fi
  if ! systemctl is-active --quiet nginx; then
    warn "nginx did not start (systemctl status nginx; journalctl -u nginx); another server may hold ports 80/443"
    rollback_nginx_tree "$nginx_backup"
    return 1
  fi
  # Angie's module packages (zstd, the dynamic Brotli module) belong to the
  # migration's Angie purge; a fresh compiled nginx has static Brotli and no
  # module package to retire.
  NGINX_ZSTD_PURGE_PENDING=0

  if ! /etc/nginx/scripts/cloudflare.sh; then
    warn "Cloudflare IP update failed; keeping the existing cloudflare.conf"
    "$NGINX_BIN" -t && systemctl reload nginx || true
  fi

  systemctl status nginx --no-pager -l || true
  "$NGINX_BIN" -v || true
  systemctl is-active nginx >/dev/null
  ok "nginx installed and running (compiled; BOLT is added under traffic by --optimize)"
}

# ---------------------------------------------------------------------------
# PHP (compiled from php.net source)
# ---------------------------------------------------------------------------
# The --php app types this run's --domain entries create, in the names
# php_build_effective_exts takes for PHP_BUILD_APPS (none for apps without
# PHP: basic, node, pingvin).  services_php_build_apps prints them space-separated.
services_php_build_app() { # DOMAIN_APP value
  case $1 in
    basic|node|pingvin|'') return 1 ;;
    xf) printf 'xenforo' ;;
    *) printf '%s' "$1" ;;
  esac
}
services_php_build_apps() {
  local d app out=""
  (( ${#DOMAINS[@]} > 0 )) || return 0
  for d in "${DOMAINS[@]}"; do
    app=$(services_php_build_app "${DOMAIN_APP[$d]:-basic}") || continue
    [[ " $out " == *" $app "* ]] || out+=" $app"
  done
  printf '%s' "${out# }"
}

# --php: build PHP X.Y (FPM + CLI, this host's extension set) from source,
# lay out /etc/php/X.Y, write and start our phpX.Y-fpm.service, then size the
# pool for the hardware exactly as --optimize does.  No apt, no Sury.
install_php() {
  local ver=${OPT[php.ver]:-}
  # The php.ini timezone follows --basic time=; a --php-only run keeps the
  # host's own timezone (sync_php_ini_template falls back to /etc/timezone),
  # exactly like --optimize does.
  local tz=""
  [[ ${ENABLED[basic]:-0} -eq 1 ]] && tz=${OPT[basic.time]:-Asia/Manila}
  local php_backup="" change cur="" reapply=0 why rel
  step "PHP ${ver:-auto} (compiled from source)"

  if why=$(services_legacy_block php); then
    die "PHP: ${why}. --php installs on a fresh host only; run setup.sh --optimize, which moves this host to the compiled PHP once. Nothing was changed"
  fi
  services_mem_allows php \
    || die "PHP is not installed on hosts under the 4 GB class (nginx only). Nothing was changed"
  declare -F php_build_ensure >/dev/null \
    || die "PHP: lib/php-build.sh is not loaded; 1.22 builds PHP from source and needs the full checkout"

  # --php is a first installation.  On a host that already runs a compiled
  # PHP it keeps the build (rebuilt only when stale or when the extension set
  # grew), its extra pools and the operator's conf.d files, and re-applies
  # the managed configuration of that version; a different version is
  # --upgrade-php's job (build, verified switch, rollback).
  cur=$(php_active_version 2>/dev/null || true)
  if [[ -n $cur ]]; then
    [[ -n $ver ]] || ver=$cur
    [[ $ver == "$cur" ]] \
      || die "PHP ${cur} is already installed and --php only performs a first installation; change the version with --upgrade-php=${ver}"
    reapply=1
    OPT[php.ver]=$ver
    info "PHP ${ver} is already installed: keeping its build, extra pools and conf.d files, re-applying the managed configuration"
  fi

  if [[ -z $ver ]]; then
    ver=$(php_build_latest_series)
    [[ -n $ver ]] || die "Could not determine the newest PHP release from php.net (offline?); pass --php ver=X.Y"
    OPT[php.ver]=$ver
    info "Auto-selected the newest PHP release series: ${ver}"
  fi
  # The source build supports 8.1 and newer (validate_all checks the same).
  [[ $ver =~ ^[0-9]+\.[0-9]+$ && $(printf '8.1\n%s\n' "$ver" | sort -V | head -n 1) == 8.1 ]] \
    || die "PHP ${ver}: not a series setup.sh builds (X.Y, 8.1 or newer). Nothing was changed"

  # Everything that can refuse the request is checked before anything is
  # built or written.  The pool/ini templates live in this repository under
  # configs/php and do not depend on the nginx config repository.
  local pool_template="${SCRIPT_DIR}/configs/php/www.conf"
  local ini_template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $pool_template ]] \
    || die "PHP FPM pool template not found: configs/php/www.conf"
  [[ -f $ini_template ]] \
    || die "PHP php.ini template not found: configs/php/custom_dan.ini"
  # A first install needs a release to build; a re-run keeps the installed
  # build when the lookup fails (offline), as --optimize does.
  if (( ! reapply )); then
    rel=$(php_build_release "$ver")
    [[ -n $rel ]] \
      || die "PHP ${ver} has no release on php.net or the php-src tags (or the lookup failed); nothing was changed"
    info "PHP ${ver}: newest release ${rel}"
  fi

  # run_service executes installers in a subshell; persist the selected version
  # so the parent shell reports and reuses the same value.
  ensure_state
  printf '%s\n' "$ver" > "${STATE_DIR}/php-selected-version"

  # The extension set (lib/php-build.sh): a base every site needs, plus the
  # set of each application found under the vhost roots and /var/www, plus
  # the apps this run's --domain entries create, plus --php ext= (persisted
  # as PHP_EXT_EXTRA), add-only against the current build.  A host with no
  # application yet gets the union of the WordPress, XenForo and Chevereto
  # sets, so a site dropped in later does not answer 500.
  # --php ext=LIST is recorded here (the run lock is held and every refusal
  # above has passed): php_build_ext_option sets and exports PHP_EXT_EXTRA
  # and PHP_BUILD_EXT_RESET in this shell, the same shell (run_service's
  # subshell) in which php_build_ensure computes php_build_effective_exts,
  # and the exports reach the build tool it starts.
  php_ext_request_apply
  local apps
  apps=$(services_php_build_apps)
  if [[ ${ENABLED[domain]:-0} -eq 1 && -n $apps ]]; then
    export PHP_BUILD_APPS="${PHP_BUILD_APPS:+$PHP_BUILD_APPS }${apps}"
  fi
  # php_build_layout writes custom_dan.ini through sync_php_ini_template,
  # which reads PHP_INI_TZ.
  local -x PHP_INI_TZ="${PHP_INI_TZ:-$tz}"

  # Build (when there is none, or check finds it stale), verify, activate,
  # lay out /etc/php/X.Y (php.ini from this version's php.ini-production,
  # php-fpm.conf, the www pool from configs/php/www.conf, sessions, tmpfiles,
  # the links), mark X.Y active and start it.  A failure is reported with the
  # build log path; the step ends there (no package to fall back to).
  if ! php_build_ensure "$ver" full install info; then
    warn "PHP ${ver}: the source build or its activation failed (reason and log above); no PHP serves on this host until a re-run of --php succeeds"
    return 1
  fi

  # Preserve the laid-out configuration so a failed tuning pass or start can
  # be rolled back.
  if [[ -d "/etc/php/${ver}/fpm" ]]; then
    php_backup=$(tmp_dir php-install.XXXXXX) \
      || die "Could not create a PHP backup directory"
    cp -a "/etc/php/${ver}/fpm" "$php_backup/" \
      || die "Could not back up PHP ${ver} configuration to ${php_backup}"
  fi

  # Hardware-aware pool/ini tuning lives in tune_php_fpm_version, shared with
  # the --optimize command.  It writes the socket listener and the final
  # performance values in conf.d/zz-setup-optimize.ini.  Only a first
  # installation is "fresh" for the tuner (the pool php_build_ensure just
  # started has served nothing, so there is nothing to measure); a re-run
  # sizes the live pool exactly like --optimize.
  tune_reset_changes
  if (( reapply )); then
    PHP_FRESH_INSTALL=0
  else
    PHP_FRESH_INSTALL=1
  fi
  # Empty listener: the tuner keeps what the pool listens on.
  if ! tune_php_fpm_version "$ver" ""; then
    PHP_FRESH_INSTALL=0
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  PHP_FRESH_INSTALL=0
  # A fresh install must leave the same audit trail as --optimize: the run log
  # is the file an operator hands over when the host later misbehaves.
  for change in "${TUNE_CHANGES[@]}"; do
    info "${change}"
  done
  for change in "${TUNE_MISSES[@]}"; do
    warn "Not applied: ${change}"
  done
  # Explicit --php children=/max_requests= were recorded by
  # record_explicit_options before the plan; tune_php_fpm_version applied
  # them, so only report them here.
  if [[ -n ${OPT[php.children]:-} && ${OPT[php.children]} != auto ]]; then
    info "PHP max_children overridden to ${OPT[php.children]}"
  fi
  if [[ -n ${OPT[php.max_requests]:-} ]]; then
    info "PHP max_requests overridden to ${OPT[php.max_requests]}"
  fi
  ensure_log_dirs

  # Our unit already carries the limits, KillSignal and UMask the 1.21
  # limits.conf drop-in added (php_build_unit_text), so no drop-in is written.
  systemctl daemon-reload
  systemctl reset-failed "php${ver}-fpm" 2>/dev/null || true
  if (( reapply )); then
    # A serving pool is reloaded (graceful: the master re-executes and
    # workers finish their requests), not restarted; a stopped one is started.
    if ! systemctl reload-or-restart "php${ver}-fpm"; then
      rollback_php_tree "$php_backup" "$ver"
      return 1
    fi
  elif ! systemctl restart "php${ver}-fpm"; then
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  if ! systemctl is-active --quiet "php${ver}-fpm"; then
    warn "PHP ${ver}: php${ver}-fpm is not running after the tuning pass (systemctl status php${ver}-fpm)"
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  php_fpm_test "$ver" >/dev/null \
    || warn "PHP ${ver}: php-fpm -t reports problems: $(php_fpm_test "$ver" 2>&1 | grep -iE 'error|warning|unable|not loaded' | head -n 1)"
  # The golden copy ExecStartPre restores missing files from must hold the
  # tuned pool and zz-setup-optimize.ini, not the template php_build_ensure
  # captured before the tuner ran.
  php_build_golden_refresh "$ver" || true
  # Sessions use PHP's own GC (gc_probability=1, gc_divisor=1000 in the
  # managed php.ini; design section 3): no phpsessionclean timer.
  systemctl status "php${ver}-fpm" --no-pager || true
  "$(php_fpm_bin "$ver")" -v || true
  if (( reapply )); then
    ok "PHP ${ver} configuration re-applied (compiled build kept)"
  else
    ok "PHP ${ver} installed (compiled; BOLT is added under traffic by --optimize)"
  fi
}

# ---------------------------------------------------------------------------
# MariaDB
# ---------------------------------------------------------------------------
configure_mariadb_apparmor() {
  # Ubuntu 26.04 ships an enforcing "mariadbd" AppArmor profile that omits
  # dac_override/setuid/setgid.  The package postinst runs mariadb-install-db
  # (a bootstrap mariadbd as root), which needs those capabilities.  Without
  # this override a fresh install that follows a purge fails to create the
  # mysql system tables.
  [[ -d /etc/apparmor.d ]] || return 0

  # The managed block is refreshed on every run so new log paths reach
  # upgraded hosts; operator rules outside the markers are kept.
  apparmor_local_set mariadbd 'mariadb apparmor' <<'EOF'
# Allow mariadb-install-db to bootstrap the server as root.
capability dac_override,
capability dac_read_search,
capability setuid,
capability setgid,
# Central log tree (/var/www/logs).
/var/www/logs/mariadb/ r,
/var/www/logs/mariadb/** rw,
# MariaDB 11.8 reads the dev number of each block device at startup (SSD
# detection; NVMe namespaces have no block/ path component); the stock
# profile denies it and logs one DENIED per disk.  dev holds major:minor only.
/sys/devices/**/dev r,
EOF

  # If a previous install was purged, the profile file is gone but the old
  # profile can still be loaded in the kernel.  That stale profile is what
  # breaks the next mariadb-install-db.  Remove it before installing again.
  if command -v aa-status >/dev/null 2>&1 \
     && aa-status 2>/dev/null | grep -qE '^[[:space:]]*mariadbd[[:space:]]*$' \
     && [[ ! -f /etc/apparmor.d/mariadbd ]]; then
    local tmp
    tmp=$(tmp_file)
    printf '#include <tunables/global>\nprofile mariadbd /usr/sbin/mariadbd { }\n' > "$tmp"
    apparmor_parser -R "$tmp" 2>/dev/null || true
  fi

  # The package may have (re)installed the profile after the block was
  # written; loading it again is cheap and makes the override effective.
  apparmor_reload_profile mariadbd
}

# Storage class of the MariaDB data directory (not /var/www: a separate data
# volume must be classified on its own device).
mariadb_storage_class() {
  local dir="" class=""
  if command -v mariadb >/dev/null 2>&1; then
    dir=$(mariadb -N -B -e 'SELECT @@datadir' 2>/dev/null | head -n1 || true)
  fi
  if [[ -z $dir || ! -d $dir ]]; then
    for dir in /var/lib/mariadb /var/lib/mysql; do
      [[ -d $dir ]] && break
    done
  fi
  [[ -d $dir ]] && class=$(storage_backing_class "$dir" 2>/dev/null || true)
  [[ -n $class ]] || class=$(storage_class)
  printf '%s' "$class"
}

# innodb_io_capacity / innodb_io_capacity_max by disk class and host type.
# A VPS keeps lower background-flush targets: provider IOPS caps make the
# dedicated-host values unreachable and InnoDB then flushes too aggressively.
# SETUP_MARIADB_IO_CAPACITY="read max" pins a host.
mariadb_io_capacity() {
  local class virt=dedi
  if [[ ${SETUP_MARIADB_IO_CAPACITY:-} =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s' "$SETUP_MARIADB_IO_CAPACITY"
    return 0
  fi
  class=$(mariadb_storage_class)
  host_is_vps && virt=vps
  case "${class}-${virt}" in
    nvme-dedi) printf '10000 20000' ;;
    nvme-vps)  printf '3000 6000' ;;
    ssd-dedi)  printf '4000 8000' ;;
    ssd-vps)   printf '1000 2000' ;;
    hdd-dedi)  printf '400 800' ;;
    *)         printf '200 400' ;;
  esac
}

# One hardware profile for both a fresh install and --optimize.  Keeping the
# arithmetic here means the two paths cannot drift apart again (for example
# one writing a larger log file or a different connection ceiling).
MARIADB_PROFILE_BUFFER=""
MARIADB_PROFILE_LOG_SIZE=""
MARIADB_PROFILE_LOG_BUFFER=""
MARIADB_PROFILE_BUFFER_MAX=""
MARIADB_PROFILE_OPEN_CACHE=""
MARIADB_PROFILE_ARIA_MB=""
MARIADB_PROFILE_THREADS=""
MARIADB_PROFILE_MAX_CONN=""
MARIADB_PROFILE_IO_READ=""
MARIADB_PROFILE_IO_WRITE=""
MARIADB_PROFILE_IO_THREADS=""
MARIADB_PROFILE_FLUSH_NEIGHBORS=""
MARIADB_PROFILE_LRU_DEPTH=""
MARIADB_PROFILE_THREAD_CACHE=""
MARIADB_PROFILE_TMP_MB=""
MARIADB_PROFILE_BACKLOG=""

# Remove the performance/logging directives from 50-server.cnf once the
# optimize drop-in exists.  Older releases wrote these keys bare (without the
# managed markers), so strip them wherever they appear, not only inside the
# marker block; otherwise 50- and 99- carry two competing definitions and the
# old 2 GB/5 GB values return if the drop-in is ever removed.  Base settings
# (charset, bind-address, skip_name_resolve, secure_file_priv, ...) stay in 50.
# The optional third argument is for tests; production uses the live path.
mariadb_strip_install_block() {
  local size_mb=$1 max_conn=$2
  local cnf=${3:-/etc/mysql/mariadb.conf.d/50-server.cnf}
  local tmp keys
  [[ -f $cnf ]] || return 0
  # log_slow_admin_statements is a deprecated MariaDB 11.8 alias
  # (--log-slow-filter owns it now).  It is no longer generated, but old
  # managed blocks still carry it, so strip it as a legacy key.
  keys=$( { mariadb_performance_settings "$size_mb" "$max_conn"; mariadb_logging_settings; \
            printf 'log_slow_admin_statements = 1\n'; } 2>/dev/null \
    | sed -n 's/^\([a-z0-9_]*\)[[:space:]]*=.*/\1/p' | paste -sd'|' -)
  [[ -n $keys ]] || return 0
  tmp=$(tmp_file) || return 1
  awk -v b="$MARIADB_BEGIN" -v e="$MARIADB_END" -v keys="$keys" '
    $0 == b { print; next }
    $0 == e { print; next }
    $0 ~ ("^[[:space:]]*(" keys ")[[:space:]]*=") { next }
    { print }
  ' "$cnf" > "$tmp"
  if commit_if_changed "$cnf" "$tmp"; then
    info "Removed duplicate MariaDB performance keys from ${cnf}; 99-setup-optimize.cnf owns them"
    opt_report "- Removed duplicate performance keys from \`${cnf}\`; \`99-setup-optimize.cnf\` owns them"
  fi
  return 0
}

# Number of application configs under /var/www whose database host asks for
# a persistent connection (XenForo `p:` host; WordPress core has no such
# option).  Each PHP worker then holds one open connection per such
# application for its whole life.
app_persistent_db_configs() {
  local conf host n=0
  while IFS= read -r conf; do
    [[ -n $conf ]] || continue
    host=$(xf_db_host_from_config "$conf" 2>/dev/null || true)
    [[ $host == p:* ]] && n=$(( n + 1 ))
  done < <(app_find_xenforo_configs 2>/dev/null || true)
  printf '%s' "$n"
}
MARIADB_PROFILE_PERSISTENT_APPS=0

mariadb_compute_profile() {
  local size_mb=$1 logsize open_cache aria_mb threads max_conn current_max="" kept_max=0
  local disk_class io_read io_write io_threads lru_depth flush_neighbors tmp_mb thread_cache ram_mb
  disk_class=$(mariadb_storage_class)
  # Redo log: 25% of the total buffer pool, as mysqltuner recommends.  The
  # ratio is what bounds the checkpoint window: too small and every commit
  # forces a flush, too large and recovery after a crash gets long.  No upper
  # cap: the pool follows the live data (--optimize), so a large ratio
  # stays proportional instead of silently dropping below 25%.
  logsize=$(( size_mb / 4 ))
  (( logsize < 16 )) && logsize=16
  ram_mb=$(mem_total_mb)
  # innodb_log_buffer_size is not dynamic.  Sized from RAM (RAM/256,
  # 16..64 MB) it stays put when --optimize grows the pool online; it used to
  # be pool/16, so every resize of a 256 MB-1 GB pool forced a full restart.
  # innodb_log_file_size must be at least the buffer, so a small pool's
  # redo log is lifted to the buffer instead of the buffer being capped by
  # it: capping made the buffer follow the pool again, and since 1.21.49
  # shrinks pools to data+5%, a 4 GB -> 128 MB shrink would have forced a
  # full restart instead of an online resize.
  local log_buffer=$(( ram_mb / 256 ))
  (( log_buffer < 16 )) && log_buffer=16
  (( log_buffer > 64 )) && log_buffer=64
  (( logsize < log_buffer )) && logsize=$log_buffer
  # Aria serves internal temporary tables, not the InnoDB data: size its
  # page cache from RAM (RAM/128, 16..256 MB) so it stops changing, and
  # forcing a restart, every time the buffer pool is re-planned.
  aria_mb=$(( ram_mb / 128 ))
  (( aria_mb < 16 )) && aria_mb=16
  (( aria_mb > 256 )) && aria_mb=256
  threads=$(effective_cpus)
  (( threads > 64 )) && threads=64
  # PHP-FPM opens one MariaDB connection per active request.  A 500-connection
  # cap was hit at 500 concurrent requests (observed as "Too many connections"
  # / HTTP 503 during the aggressive run).  Size the server from the PHP pool
  # (every worker plus 25% and admin/backup/cron headroom); without a PHP
  # tier fall back to the CPU formula.  The thread pool makes extra sessions
  # cheap, so the ceiling errs on the high side.
  local php_total persistent_apps=0
  php_total=$(php_pool_max_children 2>/dev/null || true)
  [[ $php_total =~ ^[0-9]+$ ]] || php_total=0
  (( ${OPT_PHP_CHILDREN:-0} > php_total )) && php_total=$OPT_PHP_CHILDREN
  if (( php_total > 0 )); then
    # One connection per worker is the whole story only while every
    # application opens and closes its own.  A XenForo config with a
    # persistent (`p:`) host keeps one connection per worker open for the
    # worker's lifetime, so a second site served by the same pool needs its
    # own transient connection on top (measured: 144 workers with XenForo
    # on `p:localhost` plus WordPress hit the 230 cap and WordPress answered
    # "Too many connections" for 80% of its requests).
    persistent_apps=$(app_persistent_db_configs)
    max_conn=$(( php_total * (persistent_apps + 1) * 5 / 4 + 50 ))
  else
    max_conn=$(( threads * 32 ))
  fi
  MARIADB_PROFILE_PERSISTENT_APPS=$persistent_apps
  # Disk-class dependent I/O behaviour.  Flushing neighbour pages only helps
  # rotational disks; I/O threads beyond ~16 add contention, and an HDD
  # cannot keep 16 threads busy.  The LRU scan depth follows io_capacity.
  read -r io_read io_write <<< "$(mariadb_io_capacity)"
  if [[ $disk_class == hdd ]]; then
    io_threads=4
    flush_neighbors=1
  else
    io_threads=$(( threads / 2 ))
    (( io_threads < 4 )) && io_threads=4
    (( io_threads > 16 )) && io_threads=16
    flush_neighbors=0
  fi
  lru_depth=$(( io_read / 2 ))
  (( lru_depth < 256 )) && lru_depth=256
  (( lru_depth > 2048 )) && lru_depth=2048
  thread_cache=$(( threads * 8 ))
  (( thread_cache < 32 )) && thread_cache=32
  (( thread_cache > 256 )) && thread_cache=256
  # In-memory temp tables: forum GROUP BY/ORDER BY queries spill to disk at a
  # fixed 64M on large sites; scale with RAM but never above pool/8 (32M is
  # the floor, so even a 128 MB pool gets a legal, bounded value instead of
  # the RAM/256 figure that could exceed the whole pool on a tiny host).
  tmp_mb=$(( ram_mb / 256 ))
  (( tmp_mb < 32 )) && tmp_mb=32
  (( tmp_mb > 256 )) && tmp_mb=256
  local tmp_cap=$(( size_mb / 8 ))
  (( tmp_cap < 32 )) && tmp_cap=32
  (( tmp_mb > tmp_cap )) && tmp_mb=$tmp_cap
  # Never lower an existing, larger ceiling: a busy application may already
  # allow more than threads*32 connections, and a tune must not turn into
  # "Too many connections" during a traffic peak.
  if command -v mariadb >/dev/null 2>&1 \
     && systemctl is-active --quiet mariadb 2>/dev/null; then
    current_max=$(mariadb -N -B -e 'SELECT @@max_connections' 2>/dev/null || true)
  fi
  if [[ $current_max =~ ^[0-9]+$ ]] && (( current_max > max_conn )); then
    max_conn=$current_max
    kept_max=1
  fi
  # The 2000 cap applies only to our computed value.  Capping a kept live
  # ceiling would lower a genuinely busy server (and reintroduce "Too many
  # connections"); keep a very high safety bound instead.  Nor may the cap
  # drop below what the pool holds open by itself: every worker keeps one
  # connection per persistent application plus one transient one, so three
  # persistent apps on a 600-worker pool need 2400 before any cron or admin
  # session, and a flat 2000 would refuse the last workers.  The 50 is the
  # same admin/backup/cron headroom as the formula above.
  local conn_cap=2000 conn_need=$(( php_total * (persistent_apps + 1) + 50 ))
  (( conn_need > conn_cap )) && conn_cap=$conn_need
  (( kept_max == 0 && max_conn > conn_cap )) && max_conn=$conn_cap
  (( max_conn > 100000 )) && max_conn=100000
  (( max_conn < 200 )) && max_conn=200
  # Table caches follow the connection ceiling (every session can hold a
  # handful of open tables), not the buffer pool size.
  open_cache=$(tune_clamp $(( max_conn * 16 )) 4000 32768)

  MARIADB_PROFILE_BUFFER=$(mb_to_config "$size_mb")
  MARIADB_PROFILE_LOG_SIZE=$(mb_to_config "$logsize")
  MARIADB_PROFILE_LOG_BUFFER=$(mb_to_config "$log_buffer")
  # innodb_buffer_pool_size_max (10.11.12+, 11.4.6+, 11.8): the ceiling an
  # online resize may reach.  It defaults to the pool at startup, so after
  # any restart of a pool sized to data+5% the next growth step was clamped
  # and fell back to a full restart.  80% of RAM (the plan's own ceiling)
  # reserves address space only, not memory.  Written as loose- so a release
  # without the variable ignores it instead of refusing to start.
  local pool_max=$(( ram_mb * 80 / 100 ))
  (( pool_max < size_mb )) && pool_max=$size_mb
  MARIADB_PROFILE_BUFFER_MAX=$(mb_to_config "$pool_max")
  MARIADB_PROFILE_OPEN_CACHE=$open_cache
  MARIADB_PROFILE_ARIA_MB=$aria_mb
  MARIADB_PROFILE_THREADS=$threads
  MARIADB_PROFILE_MAX_CONN=$max_conn
  MARIADB_PROFILE_IO_READ=$io_read
  MARIADB_PROFILE_IO_WRITE=$io_write
  MARIADB_PROFILE_IO_THREADS=$io_threads
  MARIADB_PROFILE_FLUSH_NEIGHBORS=$flush_neighbors
  MARIADB_PROFILE_LRU_DEPTH=$lru_depth
  MARIADB_PROFILE_THREAD_CACHE=$thread_cache
  MARIADB_PROFILE_TMP_MB=$tmp_mb
  MARIADB_PROFILE_BACKLOG=$(effective_backlog)
}

# Print the performance directives shared by the install-time 50-server.cnf
# block and the --optimize 99-setup-optimize.cnf drop-in.
# Logging keys are shared by the installer block and the --optimize drop-in.
# Keeping them in one helper prevents an old host from keeping slow logging
# off (or log_error empty) after --optimize.
mariadb_logging_settings() {
  cat <<'EOF'
slow_query_log = 1
slow_query_log_file = /var/www/logs/mariadb/slow.log
long_query_time = 1
min_examined_row_limit = 100
log_slow_verbosity = query_plan,explain
log_error = /var/www/logs/mariadb/error.log
EOF
}

mariadb_performance_settings() {
  local size_mb=$1 max_conn=${2:-}
  local ver major minor
  mariadb_compute_profile "$size_mb"
  [[ -n $max_conn ]] || max_conn=$MARIADB_PROFILE_MAX_CONN
  ver=$(mariadb_server_version 2>/dev/null || true)
  major=${ver%%.*}
  minor=${ver#*.}; minor=${minor%%.*}
  if ! [[ $major =~ ^[0-9]+$ ]]; then
    # Fresh install before the server has started: the install target is
    # Ubuntu 26.04 with MariaDB 11.8, which uses the per-file buffering knobs.
    major=11; minor=8
  fi
  [[ $minor =~ ^[0-9]+$ ]] || minor=0

  cat <<EOF
max_connections = ${max_conn}
max_connect_errors = 524288
back_log = ${MARIADB_PROFILE_BACKLOG}
thread_cache_size = ${MARIADB_PROFILE_THREAD_CACHE}
thread_handling = pool-of-threads
thread_pool_size = ${MARIADB_PROFILE_THREADS}
max_allowed_packet = 64M
wait_timeout = 600
interactive_timeout = 600
net_read_timeout = 120
net_write_timeout = 120

innodb_log_buffer_size = ${MARIADB_PROFILE_LOG_BUFFER}
innodb_log_file_size = ${MARIADB_PROFILE_LOG_SIZE}
innodb_buffer_pool_size = ${MARIADB_PROFILE_BUFFER}
loose-innodb_buffer_pool_size_max = ${MARIADB_PROFILE_BUFFER_MAX}
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON
innodb_buffer_pool_dump_pct = 25
innodb_stats_on_metadata = OFF
innodb_lock_wait_timeout = 100
innodb_flush_neighbors = ${MARIADB_PROFILE_FLUSH_NEIGHBORS}
innodb_stats_persistent = ON
innodb_stats_auto_recalc = ON
innodb_lru_scan_depth = ${MARIADB_PROFILE_LRU_DEPTH}
innodb_io_capacity = ${MARIADB_PROFILE_IO_READ}
innodb_io_capacity_max = ${MARIADB_PROFILE_IO_WRITE}
innodb_read_io_threads = ${MARIADB_PROFILE_IO_THREADS}
innodb_write_io_threads = ${MARIADB_PROFILE_IO_THREADS}
innodb_flush_log_at_trx_commit = 2
EOF
  if (( major > 11 || (major == 11 && minor >= 8) )); then
    cat <<'EOF'
# MariaDB 11.8+ per-file buffering knobs (OFF = O_DIRECT).
innodb_data_file_buffering = OFF
innodb_data_file_write_through = OFF
innodb_log_file_buffering = OFF
innodb_log_file_write_through = OFF
EOF
  else
    cat <<'EOF'
# MariaDB <= 11.7 uses the legacy flush method.
innodb_flush_method = O_DIRECT
EOF
  fi
  cat <<EOF
join_buffer_size = 512K
read_buffer_size = 512K
read_rnd_buffer_size = 512K
sort_buffer_size = 1M
tmp_table_size = ${MARIADB_PROFILE_TMP_MB}M
max_heap_table_size = ${MARIADB_PROFILE_TMP_MB}M
table_open_cache = ${MARIADB_PROFILE_OPEN_CACHE}
table_definition_cache = ${MARIADB_PROFILE_OPEN_CACHE}
innodb_open_files = ${MARIADB_PROFILE_OPEN_CACHE}
key_buffer_size = 32M
aria_pagecache_buffer_size = ${MARIADB_PROFILE_ARIA_MB}M
EOF
}

# The performance and logging directives have exactly one owner: this drop-in.
# install_mariadb() and optimize_mariadb() both call this helper, so the same
# hardware always produces the same bytes and a later --optimize has nothing
# left to rewrite.
write_mariadb_tuning_dropin() {
  local size_mb=$1
  local max_conn=${2:-}
  local cnf=${3:-/etc/mysql/mariadb.conf.d/99-setup-optimize.cnf}
  mkdir -p "$(dirname "$cnf")"
  {
    cat <<'EOF'
# BEGIN setup.sh optimize
# Hardware-aware MariaDB tuning; generated by setup.sh --optimize.
# [mysqld] is understood by MariaDB 10.11 (Ubuntu 24.04) and 11.8 (26.04).
[mysqld]
EOF
    mariadb_performance_settings "$size_mb" "$max_conn"
    mariadb_logging_settings
    printf '%s\n' '# END setup.sh optimize'
  } > "$cnf"
  chmod 644 "$cnf"
}

# Base (non-performance) settings in 50-server.cnf: charset, name resolution,
# query cache off, secure_file_priv, local_infile=0 and the bind address.
# Shared by the installer and --optimize so a host adopted by --optimize gets
# the same security-relevant defaults as a fresh install.  Performance keys
# live only in the 99-setup-optimize.cnf drop-in (write_mariadb_tuning_dropin).
mariadb_write_base_block() {
  local cnf=$1 bind=$2 tmp
  [[ -f $cnf ]] || return 1

  # secure_file_priv points here on both paths, so both paths create it
  # (an adopted host tuned by --optimize had the directive without the dir).
  mkdir -p /var/lib/mysql-files 2>/dev/null || true
  chown mysql:mysql /var/lib/mysql-files 2>/dev/null || true
  chmod 750 /var/lib/mysql-files 2>/dev/null || true

  # Comment out expire_logs_days if it is active.
  sed_in_place -E 's|^([[:space:]]*)expire_logs_days([[:space:]]*=)|\1#expire_logs_days\2|' "$cnf"

  # Configure bind-address in the packaged [mysqld] section if present.
  if grep -qE '^[[:space:]]*bind-address[[:space:]]*=' "$cnf"; then
    sed_in_place -E "s|^[[:space:]]*bind-address[[:space:]]*=.*|bind-address = ${bind}|" "$cnf"
  fi

  # Drop a previous managed block, then append a fresh one.
  tmp=$(tmp_file)
  awk -v b="$MARIADB_BEGIN" -v e="$MARIADB_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$cnf" > "$tmp"
  cat "$tmp" > "$cnf"

  cat >> "$cnf" <<EOF
${MARIADB_BEGIN}
[mariadbd]
collation-server = utf8mb4_general_ci
character-set-server = utf8mb4

# MySQL-compatible REPEATABLE READ: XenForo 2.3 does not retry MariaDB's
# ER_CHECKREAD (1020, "Record has changed since last read") and MariaDB
# 11.6.2+ enables snapshot isolation by default.  A later .cnf drop-in can
# override this when an application is written for the stricter behaviour.
innodb_snapshot_isolation = 0
skip_name_resolve = 1
query_cache_size = 0
query_cache_type = 0
open_files_limit = 524288
secure_file_priv = /var/lib/mysql-files
local_infile = 0
innodb_read_only_compressed = OFF

EOF
  # An empty bind keeps the operator's choice: a host whose packaged
  # bind-address line is commented out listens on every interface on
  # purpose, and --optimize must not pin it back to loopback.
  if [[ -n $bind ]]; then
    cat >> "$cnf" <<EOF

bind-address = ${bind}
EOF
  fi
  printf '%s\n' "$MARIADB_END" >> "$cnf"
}

# Wait up to N seconds for the server to answer SELECT 1 (install restart,
# --optimize restart and the rollback paths all need the same probe).
mariadb_wait_ready() {
  local attempts=${1:-30} i
  for (( i = 0; i < attempts; i++ )); do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

configure_mariadb() {
  local size_mb=$1 bind=$2
  local cnf=/etc/mysql/mariadb.conf.d/50-server.cnf
  [[ -f $cnf ]] || die "MariaDB config ${cnf} not found"
  mariadb_write_base_block "$cnf" "$bind"
  write_mariadb_tuning_dropin "$size_mb"
  # A re-install on an old host must land in the same state as --optimize:
  # 99-setup-optimize.cnf is the only owner of the performance keys, so any
  # copy the packaged 50-server.cnf (or an old managed block) still carries is
  # removed here too.  Previously only --optimize did this, so a re-install
  # could leave two competing definitions.
  mariadb_strip_install_block "$size_mb" "${MARIADB_PROFILE_MAX_CONN:-0}" "$cnf"
}

install_mariadb() {
  local user=${OPT[mariadb.user]}
  local pass=${OPT[mariadb.pass]}
  local size=${OPT[mariadb.size]}
  local bind
  local size_mb
  step "MariaDB"

  if [[ ${size,,} == auto ]]; then
    size_mb=$(service_mem_mb mariadb)
    info "MariaDB size=auto resolved to $(mb_to_config "$size_mb") (shared memory plan)"
  else
    size_mb=$(size_to_mb "$size")
    [[ -n $size_mb ]] || die "Could not parse MariaDB size '${size}'"
  fi

  bind=${OPT[mariadb.bind]:-127.0.0.1}
  if ! resolve_mariadb_bind "$bind"; then
    die "--mariadb bind='${bind}': ${BIND_BAD_TOKEN}"
  fi
  bind=$REPLY
  OPT[mariadb.bind]=$bind
  info "MariaDB bind-address: ${bind}"

  local -a bind_addrs
  local addr
  IFS=',' read -r -a bind_addrs <<< "$bind"
  for addr in "${bind_addrs[@]}"; do
    if [[ $addr != 127.* && $addr != "::1" ]]; then
      warn "MariaDB will also listen on ${addr}."
      warn "UFW does not open 3306 automatically; allow only trusted clients, e.g.: ufw allow from <client-ip> to any port 3306"
      warn "Remote clients also need a matching account, e.g.: CREATE USER 'app'@'<client-ip>' IDENTIFIED BY '...';"
      [[ $addr == 0.0.0.0 ]] && warn "0.0.0.0 exposes MariaDB on every interface; prefer explicit addresses."
      if ! is_local_ipv4 "$addr" && [[ $addr != 0.0.0.0 ]]; then
        warn "${addr} is not assigned to this host; MariaDB may fail to bind unless it is added to an interface first."
      fi
      break
    fi
  done

  configure_mariadb_apparmor
  # The package starts mariadb.service from its postinst.  Without the
  # drop-in that first start logs "Referenced but unset environment variable
  # ... MYSQLD_OPTS, _WSREP_NEW_CLUSTER" and runs with the stock file limit.
  mariadb_write_systemd_limits || true
  apt_install mariadb-server mariadb-client
  systemctl enable --now mariadb
  systemctl status mariadb --no-pager || true

  mariadb_write_systemd_limits || true

  # configure_mariadb rewrites 50-server.cnf and adds the tuning drop-in.
  # Keep a copy of the directory so a directive this Mariadb build rejects
  # does not leave a host that cannot restart after the next reboot (the
  # --optimize path already rolls back).
  local mdb_bk=""
  mdb_bk=$(tmp_dir mariadb-install.XXXXXX || true)
  [[ -n $mdb_bk ]] && cp -a /etc/mysql/mariadb.conf.d "$mdb_bk/" 2>/dev/null || mdb_bk=""
  configure_mariadb "$size_mb" "$bind"
  # Same audit trail as the optimizer report, so the install log records the
  # values a later --optimize would reproduce.
  info "MariaDB profile: buffer_pool=${MARIADB_PROFILE_BUFFER} redo_log=${MARIADB_PROFILE_LOG_SIZE} max_connections=${MARIADB_PROFILE_MAX_CONN} table_open_cache=${MARIADB_PROFILE_OPEN_CACHE} io_capacity=${MARIADB_PROFILE_IO_READ}/${MARIADB_PROFILE_IO_WRITE} thread_pool=${MARIADB_PROFILE_THREADS}"

  ensure_log_dirs
  systemctl daemon-reload

  mariadb_wait_ready 30 || true

  # Same guard as --optimize: let the server parse the generated files before
  # the restart, so a rejected directive is reported instead of a dead unit.
  if command -v mariadbd >/dev/null 2>&1 \
     && ! mariadbd --defaults-file=/etc/mysql/my.cnf --help --verbose >/dev/null 2>&1; then
    warn "MariaDB rejected the generated configuration:"
    mariadbd --defaults-file=/etc/mysql/my.cnf --help --verbose 2>&1 | grep -iE 'error|unknown' | head -n 5 >&2 || true
    if [[ -n $mdb_bk && -d $mdb_bk/mariadb.conf.d ]]; then
      mv /etc/mysql/mariadb.conf.d "${mdb_bk}/rejected" \
        && mv "$mdb_bk/mariadb.conf.d" /etc/mysql/mariadb.conf.d \
        && warn "restored the previous MariaDB configuration (rejected copy kept in ${mdb_bk}/rejected)"
    fi
    return 1
  fi
  if ! systemctl restart mariadb; then
    journalctl -u mariadb -n 80 --no-pager || true
    # A file can parse and still fail at start (a buffer pool or redo log
    # the host cannot allocate, a socket path that does not exist).  Put the
    # working directory back and bring the server up on it, so the failed
    # install does not leave MariaDB stopped with the generated files live.
    if [[ -n $mdb_bk && -d $mdb_bk/mariadb.conf.d ]]; then
      mv /etc/mysql/mariadb.conf.d "${mdb_bk}/rejected" \
        && mv "$mdb_bk/mariadb.conf.d" /etc/mysql/mariadb.conf.d \
        && warn "MariaDB did not start with the generated configuration; restored the previous one (failed copy kept in ${mdb_bk}/rejected)"
      systemctl restart mariadb \
        || warn "MariaDB does not start on the restored configuration either"
    fi
    return 1
  fi
  # Same wait as mariadb_restart_probe: a large buffer pool on a slow disk
  # needs minutes, and the grants below fail on a server that is not up yet.
  mariadb_wait_ready 300 || true

  local eu ep sql host
  eu=$(sql_escape "$user")
  ep=$(sql_escape "$pass")
  # skip_name_resolve=1 means 127.0.0.1 is not translated to localhost, so an
  # account created only for 'user'@'localhost' cannot be used over TCP.
  # Create the same account for every loopback spelling.
  # The statements go in over stdin: a password inside `mariadb -e "..."` is
  # visible to every local user in the process list for as long as it runs.
  mariadb_ensure_local_user "$user" "$pass" 'ALL ON *.*' 'WITH GRANT OPTION'

  # MySQL Tuner (embedded)
  blob_mysqltuner > /root/mysqltuner.pl
  chmod +x /root/mysqltuner.pl

  # MariaDB backup utility (embedded repository snapshot)
  ensure_state
  if ! dpkg-query -W -f='${Status}' lz4 2>/dev/null | grep -q 'ok installed'; then
    touch "${STATE_DIR}/lz4-installed"
  fi
  apt_install lz4
  mkdir -p /root/tools/mysqlbackup-master /var/www
  # blob_mysqlbackup already gunzips: it emits a plain tar (like every other
  # embedded payload), so extract without -z.  The payload used to be gzipped
  # twice, which is why the old pipeline passed -z here.
  blob_mysqlbackup | tar -xf - -C /root/tools/mysqlbackup-master
  chmod +x /root/tools/mysqlbackup-master/install /root/tools/mysqlbackup-master/mysqlbkup.sh
  # The upstream installer uses "mkdir" without -p; make it idempotent.
  sed_in_place 's|^mkdir "\$BACKUP_DIR"|mkdir -p "$BACKUP_DIR"|' \
    /root/tools/mysqlbackup-master/install

  # The credentials reach the file through the environment, never through a
  # sed command line that every local user could read in `ps`.
  write_mysqlbkup_credentials /root/tools/mysqlbackup-master/mysqlbkup.cnf.sample \
    "$user" "$pass" || die "Could not write the MariaDB backup credentials"

  # The upstream installer unconditionally overwrites /etc/mysqlbkup.config
  # with its sample.  Keep an operator's existing settings (BACKUP_DIR,
  # MAX_BACKUPS, compression) across a re-run; a fresh install still gets the
  # repository defaults.  The credentials file is regenerated from the current
  # admin password either way.
  local bkup_config_backup="" bkup_config_existed=0 bkup_install_output bkup_dir=""
  if [[ -f /etc/mysqlbkup.config ]]; then
    bkup_config_existed=1
    bkup_config_backup=$(tmp_file) || bkup_config_backup=""
    if [[ -n $bkup_config_backup ]]; then
      cp -a /etc/mysqlbkup.config "$bkup_config_backup" || bkup_config_backup=""
    fi
  fi
  bkup_install_output=$( cd /root/tools/mysqlbackup-master && ./install 2>&1 ) \
    || warn "mysqlbkup installer reported an issue"
  # The upstream installer prints a suggested cron line that differs from the
  # managed one and would invite a duplicate 03:03 backup job.  Drop just that
  # suggestion; keep the rest of the installer output in the run log.
  if [[ -n $bkup_install_output ]]; then
    printf '%s\n' "$bkup_install_output" \
      | grep -vE '^(Setup cron to run once a day|3 3 \* \* \* /usr/local/bin/mysqlbkup\.sh)' \
      || true
  fi
  if (( bkup_config_existed )); then
    if [[ -n $bkup_config_backup ]] \
       && cat -- "$bkup_config_backup" > /etc/mysqlbkup.config; then
      info "Preserved the existing /etc/mysqlbkup.config"
    else
      warn "Could not preserve /etc/mysqlbkup.config; keeping the installer default"
    fi
  elif [[ -f /etc/mysqlbkup.config ]] && grep -q '^MAX_BACKUPS=' /etc/mysqlbkup.config; then
    # Fresh install: keep 30 days of dumps (the upstream default is 5).
    sed_in_place 's/^MAX_BACKUPS=.*/MAX_BACKUPS=30/' /etc/mysqlbkup.config \
      || warn "Could not set MAX_BACKUPS=30 in /etc/mysqlbkup.config"
  fi
  # The upstream installer created only its sample BACKUP_DIR.  If an existing
  # config was preserved, make sure the directory it names exists too.
  if [[ -f /etc/mysqlbkup.config ]]; then
    bkup_dir=$(awk -F= '/^[[:space:]]*BACKUP_DIR[[:space:]]*=/{sub(/^[^=]*=/, ""); print; exit}' /etc/mysqlbkup.config) || bkup_dir=""
    bkup_dir=${bkup_dir%$'\r'}
    bkup_dir=${bkup_dir#\"}; bkup_dir=${bkup_dir%\"}
    bkup_dir=${bkup_dir#\'}; bkup_dir=${bkup_dir%\'}
    if [[ -n $bkup_dir ]]; then
      mkdir -p "$bkup_dir" 2>/dev/null || true
    fi
  fi
  if [[ -f /etc/mysqlbkup.cnf ]]; then
    chown root:root /etc/mysqlbkup.cnf 2>/dev/null || true
    chmod 600 /etc/mysqlbkup.cnf 2>/dev/null || true
  fi
  mkdir -p /var/www/mysql_database
  chmod 700 /var/www/mysql_database
  info "MariaDB Backup Installed"

  command -v mysqldump >/dev/null || die "mysqldump is missing; backups would fail"
  command -v mariadb-check >/dev/null || warn "mariadb-check is missing; the check cron will fail"

  systemctl status mariadb --no-pager || true
  mariadb-admin --version || true
  ok "MariaDB installed and configured"
}

# ---------------------------------------------------------------------------
# Valkey
# ---------------------------------------------------------------------------
# The live-tuning keys are shared so a fresh install and --optimize cannot
# disagree about maxmemory, backlog, lazy-free or I/O settings.
valkey_tuning_lines() {
  local max_mb=$1 policy=$2 io_threads=$3
  cat <<EOF
maxmemory ${max_mb}mb
maxmemory-policy ${policy}
maxmemory-samples 10
maxclients $(valkey_maxclients)
tcp-backlog $(effective_backlog)
timeout 0
tcp-keepalive 300
hz 10
io-threads ${io_threads}
io-threads-do-reads yes
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes
EOF
}

# Client ceiling for the cache: every PHP worker can hold a few connections
# (persistent plus a transient one), plus admin/cron headroom.  A fixed 20000
# was far above what a small VPS can serve and below what a 512-worker host
# may open.
valkey_maxclients() {
  local children total
  children=$(php_pool_max_children 2>/dev/null || true)
  [[ $children =~ ^[0-9]+$ ]] || children=0
  (( ${OPT_PHP_CHILDREN:-0} > children )) && children=$OPT_PHP_CHILDREN
  total=$(( children * 4 + 2000 ))
  (( total < 10000 )) && total=10000
  (( total > 100000 )) && total=100000
  printf '%s' "$total"
}

# --valkey: build Valkey from its upstream release (lib/valkey-build.sh:
# hash-checked source, our own valkey-server.service with the package unit's
# hardening, the valkey user and directories, a seeded valkey.conf), then
# write the managed configuration exactly as --optimize does.  No apt.
install_valkey() {
  step "Valkey (compiled from source)"
  local why
  if pkg_ok redis-server; then
    warn "redis-server is installed; leaving it untouched because setup.sh never removes packages."
    warn "Valkey was not installed. Run --optimize to tune the existing Redis server with the same cache profile."
    # A pre-existing Redis is not a failed install: the requested service was
    # already covered by a compatible cache and --optimize handles it.
    return 0
  fi
  if why=$(services_legacy_block valkey); then
    die "Valkey: ${why}. --valkey installs on a fresh host only; run setup.sh --optimize, which moves this host to the compiled Valkey once (dataset kept). Nothing was changed"
  fi
  services_mem_allows valkey \
    || die "Valkey is not installed on hosts under the 4 GB class (nginx only). Nothing was changed"
  declare -F valkey_build_ensure >/dev/null \
    || die "Valkey: lib/valkey-build.sh is not loaded; 1.22 builds Valkey from source and needs the full checkout"
  services_apt_pin_add "valkey-server valkey-tools"

  # Build (when there is none or check finds it stale), verify, install our
  # unit, create the valkey user and /var/lib/valkey, seed
  # /etc/valkey/valkey.conf only when it is missing, enable and start.  It
  # runs before the config writer below: the user must exist before
  # ensure_log_dirs creates /var/www/logs/valkey for it.
  if ! valkey_build_ensure full install info; then
    warn "Valkey: the source build or its activation failed (reason and log above); Valkey does not run on this host until a re-run of --valkey succeeds"
    return 1
  fi
  ensure_log_dirs

  local conf=/etc/valkey/valkey.conf before
  [[ -f $conf ]] || die "Valkey config ${conf} not found after the build's layout step"
  before=$(file_md5 "$conf")

  local valkey_mb policy io_threads
  if [[ -n ${OPT[valkey.ram]:-} && ${OPT[valkey.ram],,} != auto ]]; then
    valkey_mb=$(size_to_mb "${OPT[valkey.ram]}")
  else
    valkey_mb=$(service_mem_mb valkey)
  fi
  # Preserve a policy/io-threads value a previous setup.sh tune wrote, exactly
  # like --optimize does; only a fresh (unmanaged) config falls back to the
  # documented defaults.  Without this a re-install silently reset
  # `--valkey policy=volatile-lru io_threads=4` to allkeys-lru/1.
  policy=${OPT[valkey.policy]:-}
  if [[ -z $policy ]] && valkey_conf_managed "$conf"; then
    policy=$(valkey_conf_get "$conf" maxmemory-policy)
  fi
  [[ -n $policy ]] || policy=allkeys-lru
  # For typical web-cache command sizes, extra I/O threads add more CPU
  # contention than throughput.  Benchmarks on a 16-core host showed
  # io-threads=1 at 6.5k full-page req/s vs 5.1k at io-threads=8.
  io_threads=${OPT[valkey.io_threads]:-}
  if [[ -z $io_threads ]] && valkey_conf_managed "$conf"; then
    io_threads=$(valkey_conf_get "$conf" io-threads)
  fi
  [[ -n $io_threads ]] || io_threads=1

  # Keep a socket path an operator already uses: application configs and
  # remote clients point at it, and the writer below would otherwise rewrite
  # `unixsocket` to the default on every re-install.  The seeded file has
  # the key commented out, so a fresh install still gets the default.
  local socket
  socket=$(valkey_conf_get "$conf" unixsocket)
  [[ -n $socket ]] || socket=/run/valkey/valkey.sock

  # One writer for the base and tuning directives, shared with --optimize.
  # "adopt" is passed on install too: a re-install of an existing host must
  # not wipe AOF persistence or rebind a cache that serves other app servers.
  # The keep logic only fires for an unmanaged file with non-default values or
  # for a marker a previous tune wrote, so a fresh install is unaffected.
  valkey_apply_config "$conf" valkey "$valkey_mb" "$policy" "$io_threads" "$socket" adopt
  info "Valkey maxmemory: ${valkey_mb} MB (${policy}; shared memory plan)"
  tail -24 "$conf"

  # Our unit already carries LimitNOFILE/LimitCORE and the log directory in
  # ReadWritePaths, so no limits drop-in is written for valkey-server (an
  # adopted redis-server still gets one from --optimize).
  "$VALKEY_SERVER_BIN" -v
  # One restart loads the written file.  A re-run that changed nothing does
  # not restart: a restart empties a cache-only Valkey.
  systemctl enable valkey-server >/dev/null 2>&1 || true
  if [[ $(file_md5 "$conf") != "$before" ]] || ! systemctl is-active --quiet valkey-server; then
    systemctl restart valkey-server
  fi
  systemctl status valkey-server -l --no-pager || true

  # Local PHP workers should use the Unix socket instead of opening a fresh
  # TCP connection (and burning an ephemeral port) for every request.  They
  # inherit the valkey group only after a restart.
  if valkey_ensure_www_group valkey; then
    restart_php_workers_for_group valkey
  fi

  # Ask the socket this run just wrote: an adopted configuration may keep an
  # operator bind/port, and then the default 127.0.0.1:6379 is not Valkey.
  # The CLI is the build's own (absolute path; cron and root shells may lack
  # /usr/local/bin).
  wait_for_cmd 20 valkey_pong "$VALKEY_CLI_BIN" -s "$socket" || true
  "$VALKEY_CLI_BIN" -s "$socket" ping \
    || warn "Valkey did not answer PING on ${socket} (a requirepass in the adopted configuration needs AUTH)"
  ok "Valkey installed and running (compiled)"
}

# Base and tuning directives for Valkey/Redis.  Active copies of every
# managed key are removed and the canonical block appended once, so a fresh
# install and --optimize write byte-identical files and an old profile with
# "protected-mode no" or RDB saves is upgraded without contradictory
# duplicates.  Operator directives outside the managed set survive.
#
# ADOPT (7th argument "adopt", passed by --optimize) protects a cache that
# setup.sh did not install: when its configuration has AOF persistence on
# (queues, sessions) or binds an address other than loopback (other app
# servers), those lines are kept and marked, and stay kept on later runs.
# Turning persistence off or rebinding such a service loses data or cuts
# clients off on the restart that follows.
valkey_apply_config() {
  local conf=$1 kind=$2 max_mb=$3 policy=$4 io_threads=$5 socket=${6:-} adopt=${7:-}
  local keep_persist="" keep_bind="" bind_line
  [[ -n $socket ]] || socket="/run/${kind}/${kind}.sock"
  io_threads=$(valkey_clamp_io_threads "$io_threads")
  if [[ $adopt == adopt ]]; then
    if grep -qx '# setup.sh kept operator persistence' "$conf" \
       || { ! valkey_conf_managed "$conf" && [[ $(valkey_conf_get "$conf" appendonly) == yes ]]; }; then
      keep_persist=$(grep -E '^[[:space:]]*(save|appendonly)[[:space:]]' "$conf" || true)
    fi
    bind_line=$(grep -E '^[[:space:]]*bind[[:space:]]' "$conf" | tail -n1 || true)
    if [[ -n $bind_line ]] && { grep -qx '# setup.sh kept operator bind' "$conf" \
       || { ! valkey_conf_managed "$conf" \
            && [[ -n $(printf '%s\n' "$bind_line" | tr -s '[:space:]' '\n' | grep -vxE 'bind|-?127\.0\.0\.1|-?::1|localhost' || true) ]]; }; }; then
      keep_bind=$bind_line
    fi
  fi
  sed_in_place -E '/^# setup\.sh kept operator (persistence|bind)$/d' "$conf"
  sed_in_place -E '/^[[:space:]]*(bind|protected-mode|save|maxmemory|maxmemory-policy|maxmemory-samples|supervised|io-threads|io-threads-do-reads|tcp-backlog|tcp-keepalive|timeout|maxclients|hz|appendonly|lazyfree-[a-z-]+|unixsocket|unixsocketperm|logfile)[[:space:]]/d' "$conf"
  sed_in_place -E '/^# setup\.sh managed valkey$/d' "$conf"
  {
    printf '%s\n' '# setup.sh managed valkey' \
      'supervised systemd' \
      "logfile ${LOG_ROOT}/${kind}/${kind}.log"
    if [[ -n $keep_persist ]]; then
      printf '%s\n' '# setup.sh kept operator persistence' "$keep_persist"
    else
      printf '%s\n' 'save ""' 'appendonly no'
    fi
    if [[ -n $keep_bind ]]; then
      printf '%s\n' '# setup.sh kept operator bind' "$keep_bind"
    else
      printf '%s\n' 'bind 127.0.0.1 -::1'
    fi
    printf '%s\n' 'protected-mode yes' \
      "unixsocket ${socket}" \
      'unixsocketperm 770'
    valkey_tuning_lines "$max_mb" "$policy" "$io_threads"
  } >> "$conf"
}

# True when FILE already carries the block setup.sh wrote, i.e. the values in
# it are this tool's output (and may be preserved) rather than distro defaults.
valkey_conf_managed() {
  [[ -f ${1:-} ]] && grep -qx '# setup.sh managed valkey' "$1"
}

# Value of KEY in a space-delimited Valkey/Redis conf; empty when absent.
# One reader for the installer and --optimize (ini_get cannot parse this
# format: values are separated by whitespace, not '=').
valkey_conf_get() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  awk -v k="$key" '$1 == k { print $2; exit }' "$file"
}

# Valkey's own guidance caps useful I/O threads well below the core count.
# The installer and --optimize clamp identically so an install-time value is
# never silently rewritten by the next tune.
valkey_clamp_io_threads() {
  local n=$1
  [[ $n =~ ^[0-9]+$ ]] || n=1
  (( n < 1 )) && n=1
  (( n > 8 )) && n=8
  printf '%s' "$n"
}

# Runtime-settable subset of valkey_tuning_lines (everything except the
# startup-only keys), derived from the same helper so the live process and
# the file cannot drift apart.
valkey_runtime_settings() {
  # io-threads-do-reads is immutable on Redis 7 and unknown to CONFIG SET on
  # Valkey 8+ (measured: "Unknown option" on 9.0.4); sending it made every
  # online tune fail and forced a cache-wiping restart.
  valkey_tuning_lines "$@" | grep -vE '^(tcp-backlog|io-threads|io-threads-do-reads) '
}

valkey_write_systemd_limits() {
  local unit=$1 kind=$2
  write_service_limits_dropin "/etc/systemd/system/${unit}.service.d/limits.conf" \
"[Service]
LimitNOFILE=524288
LimitCORE=0
# The packaged unit uses ProtectSystem=strict; allow the central log tree.
ReadWritePaths=${LOG_ROOT}/${kind}"
}

# Add www-data to the cache's group for the Unix socket.  Returns 0 only when
# the membership changed (the PHP workers then need a restart to pick it up).
valkey_ensure_www_group() {
  local group=$1
  if ! getent group "$group" >/dev/null 2>&1; then
    warn "Service group ${group} does not exist; the Unix socket will not be accessible to www-data"
    return 1
  fi
  id -nG www-data 2>/dev/null | grep -qw "$group" && return 1
  if usermod -aG "$group" www-data 2>/dev/null; then
    return 0
  fi
  warn "Could not add www-data to the ${group} group"
  return 1
}

# valkey_pong CLI [ARGS...]: e.g. valkey_pong valkey-cli -s /run/valkey/valkey.sock
valkey_pong() { local cli=$1; shift; "$cli" "$@" ping 2>/dev/null | grep -q PONG; }

# Run a probe once per second until it succeeds or N attempts are used up.
wait_for_cmd() {
  local attempts=$1 i
  shift
  for (( i = 1; i < attempts; i++ )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  "$@" >/dev/null 2>&1
}

# Write a systemd drop-in (0644) only when its content changed.  Returns 0
# when the file was created or changed, so the caller reloads/restarts, and 1
# when it was already identical.
write_service_limits_dropin() {
  local path=$1 content=$2 before=""
  mkdir -p "$(dirname "$path")"
  # Leave an identical file alone: rewriting it bumps the mtime, and systemd
  # then reports "unit file ... changed on disk, run daemon-reload" on every
  # later systemctl call although nothing changed (seen after --upgrade-php).
  if [[ -f $path ]] && [[ "$(cat -- "$path")" == "$content" ]]; then
    [[ $(stat -c '%a' "$path" 2>/dev/null) == 644 ]] || chmod 644 "$path"
    return 1
  fi
  printf '%s\n' "$content" > "$path"
  chmod 644 "$path"
  return 0
}

mariadb_write_systemd_limits() {
  local src="${SCRIPT_DIR}/configs/mariadb/limit_nofile.conf" content
  if [[ -f $src ]]; then
    content=$(<"$src")
  else
    content='[Service]
LimitNOFILE=1048576
LimitCORE=0
# Silence the package unit'"'"'s "unset environment variable" journal warning.
Environment=MYSQLD_OPTS=
Environment=_WSREP_NEW_CLUSTER='
  fi
  write_service_limits_dropin /etc/systemd/system/mariadb.service.d/limits.conf "$content"
}

# ---------------------------------------------------------------------------
# Elasticsearch
# ---------------------------------------------------------------------------
# Install and --optimize share one copy of the managed YAML block and one
# systemd drop-in.  Previously each path wrote its own file name and key list,
# so an optimize after install left two competing definitions.
elasticsearch_strip_managed() {
  local file=$1 include_base=${2:-0} tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk -v b="$ES_BEGIN" -v e="$ES_END" -v ib="$include_base" '
    $0 == "# BEGIN setup.sh optimize" { skip = 1; next }
    $0 == "# END setup.sh optimize" { skip = 0; next }
    $0 == b && ib == 1 { skip = 1; next }
    $0 == e && ib == 1 { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
}

elasticsearch_comment_keys() {
  local file=$1 key
  shift
  for key in "$@"; do
    sed_in_place -E "s|^[[:space:]]*${key//./\\.}[[:space:]]*:.*|#&|" "$file"
  done
}

# 0 when the managed block already preloads the whole index (the memory
# plan's hysteresis keeps it on while the index itself still fits).
elasticsearch_preload_active() {
  local yml=${ES_YML:-/etc/elasticsearch/elasticsearch.yml}
  [[ -r $yml ]] || return 1
  sed -n '/^# BEGIN setup.sh optimize$/,/^# END setup.sh optimize$/p' "$yml" 2>/dev/null \
    | grep -qxF 'index.store.preload: ["*"]'
}

elasticsearch_write_performance_block() {
  local file=$1 cpus search_threads write_threads
  cpus=$(effective_cpus 2>/dev/null || echo 1)
  [[ $cpus =~ ^[0-9]+$ ]] && (( cpus > 0 )) || cpus=1
  # Elasticsearch defaults to ~1.5*n CPU search threads and n write threads.
  # On a shared web/database host a simple query was measured bursting to 10
  # cores; scale the pools with the effective CPU count and cap them so the
  # search tier cannot starve PHP and MariaDB.
  # A 1-2 vCPU host must not reserve four search threads that PHP and
  # MariaDB need; Elasticsearch also rejects write.size above processors+1.
  search_threads=$(( cpus / 2 ))
  (( search_threads < 1 )) && search_threads=1
  (( search_threads > 16 )) && search_threads=16
  # cpus/4 is always below the processors+1 ceiling Elasticsearch enforces.
  write_threads=$(( cpus / 4 ))
  (( write_threads < 1 )) && write_threads=1
  (( write_threads > 8 )) && write_threads=8
  # indices.query.bool.max_clause_count has been ignored since 8.0 and
  # search.max_buckets 65536 is the default; both are still commented out of
  # older files so no stale line remains.  node.processors tells every other
  # thread pool (get, management, refresh, flush, merge) about the cgroup
  # quota the two sized pools already follow.
  # Every index file is loaded into the page cache when the index opens, so
  # search never reads the store from disk after a restart or boot.  Only
  # written when the memory plan found room for the whole index
  # (OPT_ES_PRELOAD); a static setting, so it applies at the next start.
  # An operator's own preload line is commented out only when ours replaces
  # it (two keys would stop Elasticsearch); otherwise it is left alone.
  local preload="" has_net=0
  # http.host/transport.host are commented only when network.host will
  # control the bind (the managed base block, or an adopted node that already
  # sets network.host).  A hand-managed node that binds with http.host and
  # has no network.host keeps its listener: commenting it would silently move
  # the node to localhost.
  if grep -qE '^[[:space:]]*network\.host[[:space:]]*:' "$file" 2>/dev/null; then
    has_net=1
  fi
  local -a keys=(bootstrap.memory_lock indices.query.bool.max_clause_count
    indices.memory.index_buffer_size indices.fielddata.cache.size
    search.max_buckets action.destructive_requires_name
    http.compression http.max_content_length
    thread_pool.search.size thread_pool.write.size node.processors)
  if (( has_net )); then keys+=(http.host transport.host); fi
  if (( ${OPT_ES_PRELOAD:-0} )); then
    preload=$'index.store.preload: ["*"]\n'
    keys+=(index.store.preload)
  fi
  elasticsearch_comment_keys "$file" "${keys[@]}"
  cat >> "$file" <<EOF
# BEGIN setup.sh optimize
bootstrap.memory_lock: true
node.processors: ${cpus}
indices.memory.index_buffer_size: 20%
indices.fielddata.cache.size: 20%
action.destructive_requires_name: true
http.compression: true
http.max_content_length: 200mb
thread_pool.search.size: ${search_threads}
thread_pool.write.size: ${write_threads}
${preload}# END setup.sh optimize
EOF
  chmod 644 "$file"
}

# Elasticsearch refuses to start when vm.max_map_count is too low.  Always
# own the managed drop-in so the value survives a reboot, and raise the live
# value only when it is lower (a runtime value raised by hand must not hide a
# missing persistent file).  Shared by install and --optimize.
ensure_es_max_map_count() {
  local f=/etc/sysctl.d/99-elasticsearch.conf rc=0
  ensure_state
  # --purge must be able to remove the file and put the boot value back.
  record_original "$f" sysctl.d-99-elasticsearch.conf
  record_sysctl_values vm.max_map_count
  if [[ $(cat "$f" 2>/dev/null) != 'vm.max_map_count = 1048576' ]]; then
    printf 'vm.max_map_count = 1048576\n' > "$f"
    chmod 644 "$f"
    ES_MAP_COUNT_NOTE="vm.max_map_count ensured in ${f}"
  fi
  if [[ $(sysctl -n vm.max_map_count 2>/dev/null || echo 0) -lt 1048576 ]]; then
    sysctl -w vm.max_map_count=1048576 >/dev/null 2>&1 || rc=1
  fi
  return "$rc"
}
ES_MAP_COUNT_NOTE=""

# The complete managed YAML: base block (cluster name, bind, paths,
# single-node discovery, security flags) followed by the performance block.
# With an empty host the existing network.host is kept (an adopted node keeps
# its bind); the base block is then only rewritten when it is already managed.
elasticsearch_write_managed_yaml() {
  local yml=$1 host=${2:-}
  if [[ -n $host ]]; then
    elasticsearch_write_base_config "$yml" "$host"
  elif grep -qxF "$ES_BEGIN" "$yml"; then
    host=$(sed -nE 's/^[[:space:]]*network\.host[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null \
      | head -n1 | tr -d '"')
    [[ -n $host ]] || host=localhost
    elasticsearch_write_base_config "$yml" "$host"
  fi
  # Drop a previous managed block so repeated runs stay idempotent, then
  # append the performance block.
  elasticsearch_strip_managed "$yml"
  elasticsearch_write_performance_block "$yml"
  ES_MANAGED_HOST=$host
}
ES_MANAGED_HOST=""

# Same writer as the PHP/MariaDB drop-ins; returns 0 when the file changed.
# UMask=0027 makes the JVM create its logs 0640 like every other service in
# /var/www/logs; without it a fresh install left them 0644 until the next
# --optimize tightened them, and every rotation reopened them 0644.
elasticsearch_write_systemd_limits() {
  write_service_limits_dropin /etc/systemd/system/elasticsearch.service.d/limits.conf \
    $'[Service]\nLimitMEMLOCK=infinity\nLimitNOFILE=1048576\nLimitNPROC=4096\nUMask=0027'
}

# Base (non-performance) YAML: cluster name, bind, paths, single-node discovery
# and security flags.  install and --optimize share this helper; previously the
# block existed only after a fresh install, so tuning a host that already had
# Elasticsearch left xpack.security disabled only by luck.
elasticsearch_write_base_config() {
  local yml=$1 host=$2
  # Drop previous managed blocks, including the one written by
  # `setup.sh --optimize`; otherwise duplicates make Elasticsearch refuse to
  # start.
  elasticsearch_strip_managed "$yml" 1
  elasticsearch_comment_keys "$yml" \
    cluster.name network.host http.host transport.host http.port \
    path.logs path.data discovery.type \
    xpack.security.enabled xpack.security.enrollment.enabled \
    cluster.initial_master_nodes
  cat >> "$yml" <<EOF
${ES_BEGIN}
cluster.name: essearch
network.host: "${host}"
http.port: 9200
path.data: /var/lib/elasticsearch
path.logs: ${LOG_ROOT}/elasticsearch
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
#cluster.initial_master_nodes: [""]
${ES_END}
EOF
  chmod 644 "$yml"
}

install_elastic() {
  local host=${OPT[elastic.host]:-localhost}
  local ram=${OPT[elastic.ram]:-auto}
  local ram_lc=${ram,,}
  local ram_mb ram_total_mb
  step "Elasticsearch"

  ram_total_mb=$(mem_total_mb)
  if [[ $ram_lc == auto ]]; then
    ram_mb=$(service_mem_mb elastic)
    info "Elasticsearch heap auto-resolved to ${ram_mb} MB (shared memory plan)"
    ram_lc="${ram_mb}m"
  else
    ram_mb=$(size_to_mb "$ram_lc")
    [[ $ram_mb =~ ^[0-9]+$ ]] || die "Could not parse Elasticsearch heap '${ram}'"
    # The plan normalised the explicit value to the 512 MB step --optimize
    # writes; use that so both paths produce the same -Xmx.
    (( ${OPT_ES_BUDGET_MB:-0} > 0 )) && ram_mb=$OPT_ES_BUDGET_MB
  fi
  if (( ram_mb > ram_total_mb / 2 )); then
    warn "Elasticsearch heap (${ram_lc}) exceeds 50% of RAM; the kernel may OOM-kill it."
  fi

  case "$host" in
    localhost|127.0.0.1|::1) ;;
    *)
      warn "Elasticsearch is configured with xpack.security disabled on host '${host}'."
      warn "Do not expose port 9200 to untrusted networks; put it behind a firewall or enable X-Pack security/TLS."
      ;;
  esac

  apt_install elasticsearch
  ensure_log_dirs

  ensure_es_max_map_count || warn "Could not set vm.max_map_count"

  local yml=/etc/elasticsearch/elasticsearch.yml es_url
  [[ -f $yml ]] || die "Elasticsearch config ${yml} not found"

  elasticsearch_write_managed_yaml "$yml" "$host"
  es_url=$(elasticsearch_http_url "$yml")

  elasticsearch_write_systemd_limits || true

  mkdir -p /etc/elasticsearch/jvm.options.d
  write_es_jvm_options "$ram_mb"

  # (The Groovy date-weighting script older releases wrote here was dead
  # since Elasticsearch 6 removed Groovy scripting; XenForo Enhanced Search
  # uses Painless inline scripts.)
  systemctl daemon-reload
  systemctl enable elasticsearch.service
  systemctl restart elasticsearch.service

  if ! wait_for_cmd 180 curl -fsS "$es_url"; then
    journalctl -u elasticsearch -n 80 --no-pager || true
    die "Elasticsearch did not become ready on ${host}:9200"
  fi

  curl -fsS "$es_url" || true
  echo
  # A single-node cluster starts yellow until replicas are disabled; do it
  # during install too, not only on the next --optimize, and install the
  # template that keeps new indexes green.
  elasticsearch_fix_single_node_replicas || warn "Could not normalise single-node replicas"
  # The shared heap/replica helpers report through opt_report; --optimize
  # writes those lines to its Markdown report, the installer prints them to
  # the run log so a replica or heap problem is not silently dropped.
  local line
  for line in "${OPT_REPORT[@]}"; do
    info "Elasticsearch: ${line#- }"
  done
  OPT_REPORT=()
  ok "Elasticsearch installed and running"
}

# ---------------------------------------------------------------------------
# Others
# ---------------------------------------------------------------------------
install_others() {
  step "Other packages"
  local item
  for item in "${OTHERS[@]}"; do
    case "$item" in
      smartmon)
        info "Installing smartmontools"
        pkg_record_origin smartmontools
        unit_record_preenabled smartmontools smartd
        apt_install smartmontools
        # Ubuntu ships the unit as smartmontools.service; smartd.service is
        # only an alias on some releases.  Try both before reporting a real
        # failure (a host with no SMART-capable disk still has a valid unit).
        if systemctl enable --now smartmontools 2>/dev/null; then
          :
        elif systemctl enable --now smartd 2>/dev/null; then
          :
        else
          warn "smartmontools could not be enabled (no SMART-capable devices?)"
        fi
        smartctl --version | head -n 1 || true
        ;;
      nvme)
        local stype=${OPT[basic.server]:-$(detect_server_type)}
        if [[ $stype == dedi ]] && is_nvme_storage; then
          info "Installing nvme-cli (dedicated server with NVMe storage)"
          pkg_record_origin nvme-cli
          apt_install nvme-cli
          nvme version || true
        else
          info "Skipping nvme-cli: requires a dedicated server with NVMe storage (server=${stype})"
        fi
        ;;
      gif)
        info "Installing gifsicle"
        pkg_record_origin gifsicle
        apt_install gifsicle
        gifsicle --version | head -n 1 || true
        ;;
      nodejs)
        if node_major_switch_blocked; then
          info "Node.js $(node -v 2>/dev/null) is already installed; not replacing it with ${NODE_MAJOR}.x"
        else
          info "Installing Node.js from the prepared NodeSource ${NODE_MAJOR}.x repository"
          pkg_record_origin nodejs
          apt_install nodejs
          node -v
        fi
        ;;
      sysstat)
        info "Installing sysstat (sar/iostat history)"
        pkg_record_origin sysstat
        unit_record_preenabled sysstat sysstat-collect.timer sysstat-summary.timer sysstat-rotate.timer
        apt_install sysstat
        if [[ -f /etc/default/sysstat ]]; then
          sed_in_place -E 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
        fi
        systemctl enable --now sysstat-collect.timer sysstat-summary.timer 2>/dev/null \
          || systemctl enable --now sysstat 2>/dev/null \
          || warn "sysstat timers could not be enabled"
        # The package enables these in its postinst only; --purge disables
        # them and a re-install on the kept package must enable them again.
        systemctl enable sysstat.service sysstat-rotate.timer 2>/dev/null || true
        ;;
    esac
  done
  ok "Other packages installed"
}

# ---------------------------------------------------------------------------
# Domains
# ---------------------------------------------------------------------------
# Render a vhost from a server-configs-nginx template.  Every template uses
# the same placeholders (domain.com / sample.com / example.com, Let's Encrypt
# or /etc/nginx/ssl/default certificate paths, the hostname_ssl include), so
# one token-based substitution pass serves all of them.  Tokens are replaced
# before the real domain is inserted, so a domain that itself contains
# "example.com" (blog.example.com) is never substituted twice.
domain_render_vhost() {
  local app=$1 d=$2 certdir=$3 vhost=$4 src tpl tls
  case "$app" in
    basic)      tpl=example.com.conf ;;
    xf)         tpl=sample_xf.conf ;;
    wordpress)  tpl=sample_wordpress.conf ;;
    flarum)     tpl=sample_flarum.conf ;;
    pingvin)    tpl=sample_pingvin.conf ;;
    chevereto)  tpl=sample_chev.conf ;;
    polr)       tpl=sample_polr.conf ;;
    php|lychee) tpl=sample_php.conf ;;
    shlink)     tpl=sample_shlink.conf ;;
    sfs)        tpl=sample_sfs.conf ;;
    node)       tpl=sample_node.conf ;;
    *) die "Internal error: unhandled app '${app}' for ${d}" ;;
  esac
  src="/etc/nginx/conf.d/templates/${tpl}"
  [[ -f $src ]] || die "Missing nginx template ${src} (app=${app})"
  cp "$src" "$vhost"
  tls="include h5bp/tls/ssl_engine.conf;\n    include h5bp/tls/policy_balanced.conf;\n    ssl_certificate     ${certdir}/fullchain.pem;\n    ssl_certificate_key ${certdir}/privkey.pem;"
  sed_in_place \
    -e 's|www\.example\.com|@@WWW@@|g' -e 's|www\.domain\.com|@@WWW@@|g' \
    -e 's|example\.com|@@DOMAIN@@|g' -e 's|domain\.com|@@DOMAIN@@|g' -e 's|sample\.com|@@DOMAIN@@|g' \
    -e "s|@@WWW@@|www.${d}|g" -e "s|@@DOMAIN@@|${d}|g" \
    -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
    -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
    -e "s#/etc/nginx/ssl/default/#${certdir}/#g" \
    -e "s|include h5bp/hostname_ssl.conf;|${tls}|g" \
    "$vhost"
  case "$app" in
    basic)
      # The basic template has no port-80 listener; add the same redirect
      # every application template carries.
      local tmp
      tmp=$(tmp_file)
      {
        printf 'server {\n    listen      80;\n    listen [::]:80;\n    server_name %s www.%s;\n    return 301 https://%s$request_uri;\n}\n' "$d" "$d" "$d"
        cat "$vhost"
      } > "$tmp"
      cat "$tmp" > "$vhost"
      ;;
    xf)
      sed_in_place -e "s#/var/www/html/${d}/websocket.log#${LOG_ROOT}/nginx/${d}-websocket.log#g" "$vhost"
      ;;
    pingvin)
      mkdir -p "/var/www/${d}/data" "/var/www/${d}/frontend"
      sed_in_place -e "s#/var/www/pingvin_source#/var/www/${d}#g" \
        -e "s#/var/www/pingvin_data#/var/www/${d}/data#g" \
        -e '/set_real_ip_from 1\.2\.3\.4;/d' \
        -e '/real_ip_header X-Forwarded-For;/d' \
        -e '/real_ip_recursive on;/d' \
        -e '/realip_remote_addr/d' \
        "$vhost"
      ;;
  esac
}

# Create the declared database, a user limited to it and import a dump.
# Nothing is created unless db= was given; user=/pass= create (or re-key) the
# account for every loopback spelling, like the --mariadb admin user; sql= is
# imported only into an empty database.  Returns 0 when a dump was imported.
domain_provision_database() {
  local d=$1 db user pass sql host eu ep edb tables size start end
  local -a reader=(cat)
  db=${DOMAIN_DB[$d]:-}
  if [[ -z $db ]]; then
    info "${d}: no db= declared; no database created"
    return 1
  fi
  user=${DOMAIN_DB_USER[$d]:-}
  pass=${DOMAIN_DB_PASS[$d]:-}
  sql=${DOMAIN_SQL[$d]:-}
  # validate_all rejects the system schemas; a grant of ALL on `mysql`.* would
  # hand the grant tables to a site account, so the guard is repeated in front
  # of the statements.
  if mariadb_reserved_db "$db"; then
    die "${d}: db='${db}' is a MariaDB system schema"
  fi
  edb=$(sql_escape "$db")
  # The caller runs this function as an `if` condition, where errexit is off:
  # every step that must not be skipped carries its own `|| die`.
  mariadb <<<"CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
    || die "Failed to create MariaDB database '${db}' for ${d}"
  mariadb -N -B -e "SHOW DATABASES LIKE '${edb}'" | grep -qx "$db" \
    || die "Failed to create MariaDB database '${db}' for ${d}"
  info "${d}: database ${db}"
  if [[ -n $user ]]; then
    mariadb_ensure_local_user "$user" "$pass" "ALL PRIVILEGES ON \`${db//_/\\_}\`.*" \
      || die "${d}: could not create or grant MariaDB user '${user}' on ${db}"
    info "${d}: user ${user} (localhost, 127.0.0.1, ::1) has ALL PRIVILEGES on ${db}; password set from pass="
  fi
  [[ -n $sql ]] || return 1
  tables=$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${edb}'" 2>/dev/null || true)
  if [[ $tables =~ ^[0-9]+$ ]] && (( tables > 0 )); then
    warn "${d}: database ${db} already holds ${tables} table(s); skipping the import of ${sql} (empty it first to re-import)"
    return 1
  fi
  case "$sql" in
    *.gz)  reader=(gzip -dc) ;;
    *.xz)  reader=(xz -dc) ;;
    *.zst) reader=(zstd -dc) ;;
    *.bz2) reader=(bzip2 -dc) ;;
  esac
  command -v "${reader[0]}" >/dev/null 2>&1 || die "${d}: ${reader[0]} is required to read ${sql}"
  # A dump taken with --databases/--all-databases carries its own CREATE
  # DATABASE + USE and would load into that schema, not db=: the empty-db
  # guard, the table count and the user's grant would all miss it.  Refuse
  # such a dump unless the schema it names is db= itself.
  local other_db
  other_db=$("${reader[@]}" "$sql" 2>/dev/null | head -c 262144 \
    | sed -nE 's/^(CREATE DATABASE( \/\*!32312 IF NOT EXISTS\*\/| IF NOT EXISTS)?|USE)[[:space:]]+`?([A-Za-z0-9_$-]+)`?.*/\3/p' \
    | grep -vxF -- "$db" | head -n1 || true)
  if [[ -n $other_db ]]; then
    die "${d}: ${sql} switches to database '${other_db}' (CREATE DATABASE/USE); dump without --databases or pass db=${other_db}"
  fi
  info "${d}: importing ${sql} ($(du -h "$sql" 2>/dev/null | cut -f1)) into ${db}"
  start=$(date +%s)
  # Bulk-load mode for the whole dump: one transaction, no per-row unique or
  # FK checks, no binlog.  The dump's own DROP/CREATE statements still apply.
  #
  # The three writers are chained with && and the group runs under pipefail:
  # as separate statements inside an `if` condition a failing gzip/xz/zstd
  # was ignored, COMMIT was still sent and a truncated archive was reported
  # as a successful import.  Now a reader failure ends the stream without
  # COMMIT (the open transaction is rolled back when the client disconnects)
  # and fails the pipeline.
  if ! {
       printf 'SET autocommit=0; SET unique_checks=0; SET foreign_key_checks=0; SET SESSION sql_log_bin=0; SET SESSION max_allowed_packet=1073741824;\n' \
         && "${reader[@]}" "$sql" \
         && printf '\nCOMMIT;\n'
     } | mariadb --max-allowed-packet=1G "$db"; then
    die "${d}: import of ${sql} into ${db} failed: ${reader[0]} could not read the whole file (truncated or corrupt archive) or MariaDB rejected a statement. No COMMIT was sent for an incomplete stream, but the dump's own DROP/CREATE statements are not transactional, so the database may be partially loaded"
  fi
  end=$(date +%s)
  tables=$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${edb}'" 2>/dev/null || echo '?')
  size=$(mariadb -N -B -e "SELECT ROUND(COALESCE(SUM(data_length + index_length), 0) / 1048576) FROM information_schema.tables WHERE table_schema='${edb}'" 2>/dev/null || echo '?')
  ok "${d}: imported ${tables} table(s), ${size} MB data+index, in $(format_duration $(( end - start )))"
  return 0
}

# After a dump import the live data size is known, so size the buffer pool
# and the rest of the MariaDB profile for it right away instead of waiting
# for the next --optimize.  Reuses the optimize path: shared memory plan,
# drop-in rewrite, then an online buffer-pool resize or a restart with the
# web tiers paused.
reoptimize_mariadb_after_import() {
  step "MariaDB re-optimization for the imported data"
  local line
  OPT_INSTALL_PLAN=0
  detect_installed_services
  plan_memory_budget
  info "$(memory_plan_summary)"
  OPT_REPORT=()
  if optimize_mariadb; then
    ok "MariaDB profile re-sized for the imported data (buffer pool ${OPT_MARIADB_BUDGET_MB}MB, data+index ${OPT_DB_SIZE_MB}MB)"
  else
    warn "MariaDB re-optimization reported a problem (see the lines below)"
  fi
  # The re-plan split the same 80% budget again; a larger buffer pool can
  # only come out of the cache/search shares, so apply those too (both are
  # idempotent and report "Restart: skipped" when nothing changed).
  local svc
  for svc in valkey redis elastic; do
    [[ " ${OPT_DETECTED[*]} " == *" ${svc} "* ]] || continue
    case $svc in
      valkey|redis) optimize_valkey "$svc" || warn "${svc} re-sizing after the import reported a problem" ;;
      elastic) optimize_elastic || warn "Elasticsearch re-sizing after the import reported a problem" ;;
    esac
  done
  for line in "${OPT_REPORT[@]}"; do
    info "  ${line}"
  done
}

# --domain app=X adds that application's extension set to the compiled PHP
# (design section 5): the set is computed with this run's PHP app types in
# PHP_BUILD_APPS (a new site's root is still empty, so detection alone would
# not see it) and compared with the active build's exts=; only a set that
# grew rebuilds.  The rebuild runs in the foreground, but the current build
# keeps serving until the new one passes verify and is swapped in (CONTEXT
# refresh: layout and restart, no BOLT sample, which belongs to --optimize).  The set is add-only, so the next
# --optimize keeps these extensions without PHP_BUILD_APPS.
domain_php_extensions() {
  local apps ver want have rc=0
  apps=$(services_php_build_apps)
  [[ -n $apps ]] || return 0
  if ! declare -F php_build_ensure >/dev/null; then
    warn "PHP sites requested (${apps}) but lib/php-build.sh is not loaded; run --optimize to build their extensions"
    return 0
  fi
  ver=$(php_active_version 2>/dev/null || true)
  if [[ -z $ver ]]; then
    warn "PHP sites requested (${apps}) but this host has no compiled PHP; install it with --php (the vhosts answer 502 until then)"
    return 0
  fi
  if ! want=$(PHP_BUILD_APPS="$apps" php_build_effective_exts "$ver"); then
    warn "PHP ${ver}: the extension set for ${apps} cannot be built from source (see the line above); the sites may fail until --php ext= or SETUP_PHP_ALLOW_MISSING_EXT=1 resolves it"
    return 0
  fi
  have=$(awk -F= '$1 == "exts" { print substr($0, 6); exit }' "${PHP_BUILD_ROOT}/${ver}/build.info" 2>/dev/null || true)
  want=$(tr ',' '\n' <<<"$want" | sed '/^$/d' | sort -u | paste -sd, -)
  have=$(tr ',' '\n' <<<"$have" | sed '/^$/d' | sort -u | paste -sd, -)
  if [[ $want == "$have" ]]; then
    info "PHP ${ver}: the compiled extension set already covers ${apps}"
    return 0
  fi
  info "PHP ${ver}: rebuilding with the extension set for ${apps} (${want//,/ }); the current build serves meanwhile"
  export PHP_BUILD_APPS="$apps"
  # php_upgrade_checked keeps set -e and the ERR trap live inside the build
  # path while still capturing its status (an `if !` or `||` would switch
  # errexit off for everything the build calls).
  if declare -F php_upgrade_checked >/dev/null; then
    php_upgrade_checked php_build_ensure "$ver" full refresh info || rc=$?
  else
    php_build_ensure "$ver" full refresh info || rc=$?
  fi
  if (( rc != 0 )); then
    warn "PHP ${ver}: the rebuild for ${apps} failed (log above); the previous build keeps serving and those sites may fail until a re-run of --domain or --optimize succeeds"
  fi
  return 0
}

create_domains() {
  step "Domains"
  (( ${#DOMAINS[@]} > 0 )) || return 0

  # A host still served by Angie (its 1.22 migration pending or refused) has
  # no live /etc/nginx; a vhost written there would never be served, and
  # /etc/angie is not touched by 1.22 code (legacy-Angie mode).
  if declare -F web_server_state >/dev/null && [[ $(web_server_state) == angie-legacy ]]; then
    die "Angie still serves this host (the 1.22 migration is pending or was refused); run --optimize to finish it before adding domains. Nothing was changed"
  fi
  [[ -d /etc/nginx/conf.d ]] \
    || die "nginx is not installed (/etc/nginx/conf.d missing). Install with --nginx first."
  local d need_db=0
  for d in "${DOMAINS[@]}"; do
    [[ -n ${DOMAIN_DB[$d]:-} ]] && need_db=1
  done
  if (( need_db )); then
    command -v mariadb >/dev/null 2>&1 \
      || die "MariaDB client not found; db= needs MariaDB (install it with --mariadb first)."
    systemctl is-active --quiet mariadb \
      || die "MariaDB is not running; db= needs MariaDB (install/start it with --mariadb first)."
  fi
  command -v openssl >/dev/null 2>&1 || apt_install openssl
  ensure_log_dirs

  local dir conf app certdir tmp changed=0 imported=0
  for d in "${DOMAINS[@]}"; do
    app=${DOMAIN_APP[$d]:-basic}
    dir="/var/www/${d}/public"
    conf="/etc/nginx/conf.d/${d}.conf"
    certdir="/etc/nginx/ssl/${d}"

    # The application's PHP extensions are added once for all domains after
    # this loop (domain_php_extensions): one rebuild, not one per site.

    # Only a tree this run creates is chowned recursively.  An existing site
    # keeps its ownership (root:www-data wp-config.php, deploy-owned files);
    # the nightly managed cron applies the log-safe ownership pass.
    if [[ -d "/var/www/${d}" ]]; then
      mkdir -p "$dir" "${LOG_ROOT}/nginx"
      chown www-data:www-data "$dir" 2>/dev/null || true
    else
      mkdir -p "$dir" "${LOG_ROOT}/nginx"
      chown -R www-data:www-data "/var/www/${d}"
    fi
    chmod 755 "/var/www/${d}" "$dir"
    info "Directory: ${dir}"

    # Every template (the basic one included) terminates TLS; a self-signed
    # certificate makes the vhost valid until ACME/Let's Encrypt replaces it.
    mkdir -p "$certdir"
    chmod 700 "$certdir"
    if [[ ! -s "${certdir}/fullchain.pem" || ! -s "${certdir}/privkey.pem" ]]; then
      info "Generating a self-signed certificate for ${d}"
      openssl req -x509 -nodes -newkey rsa:2048 -days 397 \
        -subj "/CN=${d}" \
        -addext "subjectAltName=DNS:${d},DNS:www.${d}" \
        -keyout "${certdir}/privkey.pem" \
        -out "${certdir}/fullchain.pem" >/dev/null 2>&1 \
        || die "Could not generate a certificate for ${d}"
      chmod 600 "${certdir}/privkey.pem"
      chmod 644 "${certdir}/fullchain.pem"
    fi

    # Never overwrite an existing non-empty vhost; the operator may have
    # customised it.  Empty placeholder files are upgraded.
    if [[ -e $conf && -s $conf ]]; then
      info "nginx config already exists and is non-empty; keeping ${conf}"
    else
      tmp=$(tmp_file)
      domain_render_vhost "$app" "$d" "$certdir" "$tmp"
      install -m 644 "$tmp" "$conf"
      local domain_test_log
      domain_test_log=$(tmp_file)
      if ! "$NGINX_BIN" -t >"$domain_test_log" 2>&1; then
        cat "$domain_test_log" >&2 || true
        # Keep the rejected file out of the live config without deleting it.
        local rejected
        rejected=$(preserve_to_tmp "$conf" || true)
        [[ -n $rejected ]] && warn "Moved rejected vhost to ${rejected}"
        die "nginx rejected the generated vhost for ${d} (app=${app})"
      fi
      # "nginx -t" runs from this shell (umask 022) and creates the per-vhost
      # log files before systemd's UMask=0027 applies. Normalise them now.
      find "${LOG_ROOT}/nginx" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
      changed=1
      info "Created nginx vhost: ${conf} (app=${app})"
    fi

    if domain_provision_database "$d"; then
      imported=1
    fi
  done

  if (( changed )); then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null \
      || warn "Could not reload nginx after creating vhosts"
  fi
  domain_php_extensions
  if (( imported )); then
    reoptimize_mariadb_after_import
  fi
  local xf_php
  xf_php=$(php_active_version 2>/dev/null || true)
  for d in "${DOMAINS[@]}"; do
    [[ ${DOMAIN_APP[$d]:-basic} == xf ]] || continue
    # 1.21.58 audit, XenForo 2.3.13 on PHP 8.6.0 (see php_upgrade_app_cautions).
    if [[ -n $xf_php && $(printf '%s\n8.6\n' "$xf_php" | sort -V | head -n 1) == 8.6 ]]; then
      warn "XenForo ${d}: PHP ${xf_php} runs XenForo 2.3.13's production pages, but debug mode answers 500 on every page and the bundled Braintree (payment profiles) and laminas-mail null transport do not compile; use --upgrade-php=8.5 for a forum until XenForo ships a fix"
    fi
    info "XenForo ${d}: dynamic Brotli compression is enabled; with php-redis + local Valkey keep the XF data cache on (measured +7-9% authenticated throughput; without php-redis the Credis fallback measured slower), and disable the Members online / Trending / Featured widgets if you do not need them (measured +39% authenticated throughput)."
  done
  # The closing --optimize pass for the new vhost(s) runs from main()
  # (run_post_domain_optimize), not here: this function runs in
  # run_service's subshell, where a web tier paused for a MariaDB restart
  # was invisible to the parent's on_exit and set -e was suspended by the
  # `|| warn` around the call.
  ok "Domain setup complete"
}

