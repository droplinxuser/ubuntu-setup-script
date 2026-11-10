# ---------------------------------------------------------------------------
# APT repositories
# ---------------------------------------------------------------------------
# Add every selected third-party repository first, then run one apt-get update
# in prepare_repositories().  The service installers only install packages.
configure_angie_repo() {
  local keyring=/usr/share/keyrings/angie-signing.gpg
  local legacy=/etc/apt/trusted.gpg.d/angie-signing.gpg
  refresh_blob_key "$keyring" blob_angie_key || return 1
  chmod 644 "$keyring"
  # Older releases installed the key into trusted.gpg.d, where it can sign
  # *every* configured repository.  Scope it to the Angie source with
  # signed-by (the other third-party repositories already work this way) and
  # retire the globally trusted copy when it is byte-identical to the embedded
  # key; an operator-supplied key is left alone.
  if [[ -f $legacy ]] && cmp -s "$legacy" "$keyring"; then
    retire_paths "$legacy"
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb [signed-by=%s] https://download.angie.software/angie/%s/%s %s main\n' \
    "$keyring" "$ID" "$VERSION_ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/angie.list
  chmod 644 /etc/apt/sources.list.d/angie.list
}

configure_php_repo() {
  ensure_sury_keyring || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/php.list
  chmod 644 /etc/apt/sources.list.d/php.list
}

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
  local v
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
  if [[ ${ENABLED[angie]:-0} -eq 1 ]]; then
    configure_angie_repo || die "Could not configure the Angie APT repository"
    configured=1
  fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    configure_php_repo || die "Could not configure the Sury APT repository"
    configured=1
  fi
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
    apt_update
  fi
}

install_angie() {
  step "Angie web server"
  local angie_backup=""
  apt_install ca-certificates curl wget unzip rsync openssl

  apt_install angie

  systemctl daemon-reload || true
  systemctl enable --now angie || warn "Angie did not start with the packaged config"

  # Keep a copy of the deployed tree so a failed repo deploy/tune can be
  # rolled back instead of leaving a live host with a broken configuration.
  if [[ -d /etc/angie ]]; then
    angie_backup=$(tmp_dir angie-install.XXXXXX) \
      || die "Could not create an Angie backup directory"
    cp -a /etc/angie "$angie_backup/" \
      || die "Could not back up /etc/angie to ${angie_backup}"
  fi

  if ! deploy_angie_configs; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi
  chmod 755 /etc/angie/scripts/cloudflare.sh 2>/dev/null || true

  systemctl daemon-reload
  if ! /usr/sbin/angie -t; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi
  if ! systemctl restart angie; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi

  if ! /etc/angie/scripts/cloudflare.sh; then
    warn "Cloudflare IP update failed; keeping the existing cloudflare.conf"
    /usr/sbin/angie -t && systemctl reload angie || true
  fi

  systemctl status angie --no-pager -l || true
  systemctl is-active angie >/dev/null
  ok "Angie installed and running"
}

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
# A clean PHP install is required: a stopped but installed second PHP version
# still owns a pool that can later bind /run/php/php-fpm.sock and break the
# selected version.  Remove every PHP package first, keeping the old /etc/php
# tree recoverable under /tmp.
purge_php_installations() {
  local -a pkgs=() units=()
  mapfile -t pkgs < <(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | grep -E '^php([0-9]+\.[0-9]+)?(-|$)' | sort -u || true)
  (( ${#pkgs[@]} > 0 )) || return 0

  mapfile -t units < <(systemctl list-units --all --no-legend --no-pager 'php*-fpm.service' 2>/dev/null \
    | awk '{print $1}' | grep -E '^php.*-fpm\.service$' || true)
  local unit
  for unit in "${units[@]}"; do
    systemctl disable --now "$unit" 2>/dev/null || true
  done

  local backup=""
  if [[ -d /etc/php ]]; then
    backup=$(tmp_dir php-config.XXXXXX) || die "Could not create a PHP config backup directory"
    cp -a /etc/php "$backup/" 2>/dev/null \
      || warn "Could not back up /etc/php to ${backup}"
    info "Backed up the existing /etc/php tree to ${backup}"
  fi

  info "Purging existing PHP packages for a clean installation: ${pkgs[*]}"
  apt-get purge "${APT_OPTS[@]}" "${pkgs[@]}" \
    || die "Could not purge the existing PHP packages"

  # apt purge normally removes the tree; if conffiles survived, keep them in
  # /tmp instead of leaving a stale pool next to the new installation.
  if [[ -e /etc/php ]]; then
    local moved
    moved=$(preserve_to_tmp /etc/php 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved leftover /etc/php to ${moved}"
  fi
  systemctl daemon-reload || true
  systemctl reset-failed 'php*-fpm' 2>/dev/null || true
}

install_php() {
  local ver=${OPT[php.ver]:-}
  # The php.ini timezone follows --basic time=; a --php-only run keeps the
  # host's own timezone (sync_php_ini_template falls back to /etc/timezone),
  # exactly like --optimize does.
  local tz=""
  [[ ${ENABLED[basic]:-0} -eq 1 ]] && tz=${OPT[basic.time]:-Asia/Manila}
  local php_backup="" change
  step "PHP ${ver:-auto}"

  # The requested PHP version must be the only one installed, not merely the
  # only one active.  Purge everything before selecting/installing.
  purge_php_installations

  if [[ -z $ver ]]; then
    ver=$(latest_sury_php)
    [[ -n $ver ]] || die "Could not determine the latest stable PHP version from the Sury repository"
    OPT[php.ver]=$ver
    info "Auto-selected latest stable PHP: ${ver}"
  fi
  # run_service executes installers in a subshell; persist the selected version
  # so the parent shell reports and reuses the same value.
  ensure_state
  printf '%s\n' "$ver" > "${STATE_DIR}/php-selected-version"

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)9000$'; then
    die "Port 9000 is already in use by another process. Only one PHP version can run at a time; free the port first."
  fi
  # A stale socket left by a purged/crashed pool is replaced by PHP-FPM
  # itself when it binds.  setup.sh does not unlink it in case the path is
  # still in use by another process.
  [[ -S /run/php/php-fpm.sock ]] \
    && info "Leaving existing FastCGI socket for PHP-FPM to validate"

  # XenForo-focused extension set: runtime, database, media, HTTP, XML,
  # archives, math, multibyte, Redis, OPcache and the CLI for XenForo cmd.php.
  # Add intl/imagick/bcmath/apcu only if a specific add-on needs them.
  #
  # PHP 8.5 made OPcache a mandatory, always-built-in extension: Sury (and
  # Ubuntu) no longer publish php8.5-opcache.  Installing the separate package
  # unconditionally made the whole PHP step fail on 26.04.  Keep the split
  # package for 8.4 and older, and rely on the bundled extension for 8.5+.
  local -a php_pkgs=(
    "php${ver}-fpm" "php${ver}-cli"
    "php${ver}-mysql" "php${ver}-gd" "php${ver}-curl" "php${ver}-xml"
    "php${ver}-zip" "php${ver}-gmp" "php${ver}-mbstring" "php${ver}-redis"
  )
  if apt-cache show "php${ver}-opcache" >/dev/null 2>&1; then
    php_pkgs+=("php${ver}-opcache")
  else
    info "PHP ${ver} bundles OPcache in the core package; skipping php${ver}-opcache"
  fi
  apt_install "${php_pkgs[@]}"

  # Preserve the package-created configuration so a bad template, tuning pass
  # or failed start can be rolled back.
  if [[ -d "/etc/php/${ver}/fpm" ]]; then
    php_backup=$(tmp_dir php-install.XXXXXX) \
      || die "Could not create a PHP backup directory"
    cp -a "/etc/php/${ver}/fpm" "$php_backup/" \
      || die "Could not back up PHP ${ver} configuration to ${php_backup}"
  fi

  # Keep the CLI on the same version as FPM.  Without this, installing a
  # distro package can add a newer php-cli and make /usr/bin/php point at a
  # binary whose extension set differs from the web pool.
  if command -v update-alternatives >/dev/null 2>&1 \
     && [[ -x "/usr/bin/php${ver}" ]]; then
    update-alternatives --set php "/usr/bin/php${ver}" >/dev/null 2>&1 \
      || warn "Could not pin /usr/bin/php to PHP ${ver}"
  fi

  # PHP-FPM is not an Angie concern: its pool/ini templates live in this
  # repository under configs/php and no longer depend on the Angie config
  # repository being fetched.
  local pool_template="${SCRIPT_DIR}/configs/php/www_${ver//./}.conf"
  local ini_template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $pool_template ]] \
    || die "PHP ${ver} FPM pool template not found: configs/php/www_${ver//./}.conf"
  [[ -f $ini_template ]] \
    || die "PHP php.ini template not found: configs/php/custom_dan.ini"

  install -m 644 "$pool_template" "/etc/php/${ver}/fpm/pool.d/www.conf"
  # Same template writer as --optimize (timezone handling included).
  PHP_INI_TZ="$tz" sync_php_ini_template "$ver" || die "Could not write custom_dan.ini"

  # Hardware-aware pool/ini tuning lives in tune_php_fpm_version, shared with
  # the --optimize command.  It writes the socket listener and the final
  # performance values in conf.d/zz-setup-optimize.ini.
  tune_reset_changes
  PHP_FRESH_INSTALL=1
  if ! tune_php_fpm_version "$ver"; then
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

  php_fpm_write_systemd_limits "$ver" || true
  systemctl daemon-reload

  # Only one PHP-FPM version can own the shared /run/php/php-fpm.sock socket.
  # (The conflict was checked before apt_install; this just clears any
  # previous failed state for the same version.)
  systemctl reset-failed "php${ver}-fpm" 2>/dev/null || true
  if ! systemctl enable --now "php${ver}-fpm" \
     || ! systemctl restart "php${ver}-fpm"; then
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  systemctl status "php${ver}-fpm" --no-pager || true
  "$(php_fpm_binary "$ver")" -v || true
  ok "PHP ${ver} installed"
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

  local localfile=/etc/apparmor.d/local/mariadbd
  local begin='# BEGIN setup.sh mariadb apparmor'
  local end='# END setup.sh mariadb apparmor'
  local tmp

  mkdir -p /etc/apparmor.d/local
  # Always refresh the managed block so new log paths are picked up on
  # upgrades; keep any unrelated operator rules outside the markers.
  if [[ -f $localfile ]]; then
    tmp=$(tmp_file)
    awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$localfile" > "$tmp"
    cat "$tmp" > "$localfile"
  fi
  {
    printf '%s\n' "$begin"
    printf '# Allow mariadb-install-db to bootstrap the server as root.\n'
    printf 'capability dac_override,\n'
    printf 'capability dac_read_search,\n'
    printf 'capability setuid,\n'
    printf 'capability setgid,\n'
    printf '# Central log tree (/var/www/logs).\n'
    printf '/var/www/logs/mariadb/ r,\n'
    printf '/var/www/logs/mariadb/** rw,\n'
    printf '%s\n' "$end"
  } >> "$localfile"

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

  if [[ -f /etc/apparmor.d/mariadbd ]] && command -v apparmor_parser >/dev/null 2>&1; then
    apparmor_parser -r /etc/apparmor.d/mariadbd 2>/dev/null || true
  fi
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
  if ! cmp -s "$cnf" "$tmp"; then
    cat "$tmp" > "$cnf"
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
  local disk_class io_read io_write io_threads lru_depth flush_neighbors tmp_mb thread_cache ram_mb log_cap
  disk_class=$(mariadb_storage_class)
  # Redo log: a quarter of the pool.  2 GB is enough on SSD/HDD; NVMe absorbs
  # the longer checkpoint window, so a pool of 16 GB or more gets up to 4 GB
  # before write bursts stall on checkpoints.
  logsize=$(( size_mb / 4 ))
  (( logsize < 64 )) && logsize=64
  log_cap=2048
  [[ $disk_class == nvme ]] && log_cap=4096
  (( logsize > log_cap )) && logsize=$log_cap
  # Aria serves internal temporary tables, not the InnoDB data: size its
  # page cache from RAM (RAM/128, 16..256 MB) so it stops changing, and
  # forcing a restart, every time the buffer pool is re-planned.
  ram_mb=$(mem_total_mb)
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
  # fixed 64M on large sites; scale with RAM but never above pool/8.
  tmp_mb=$(( ram_mb / 256 ))
  (( tmp_mb < 32 )) && tmp_mb=32
  (( tmp_mb > 256 )) && tmp_mb=256
  (( tmp_mb > size_mb / 8 && size_mb / 8 >= 32 )) && tmp_mb=$(( size_mb / 8 ))
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
  # connections"); keep a very high safety bound instead.
  (( kept_max == 0 && max_conn > 2000 )) && max_conn=2000
  (( max_conn > 100000 )) && max_conn=100000
  (( max_conn < 200 )) && max_conn=200
  # Table caches follow the connection ceiling (every session can hold a
  # handful of open tables), not the buffer pool size.
  open_cache=$(tune_clamp $(( max_conn * 16 )) 4000 32768)

  MARIADB_PROFILE_BUFFER=$(mb_to_config "$size_mb")
  MARIADB_PROFILE_LOG_SIZE=$(mb_to_config "$logsize")
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

innodb_log_buffer_size = 64M
innodb_log_file_size = ${MARIADB_PROFILE_LOG_SIZE}
innodb_buffer_pool_size = ${MARIADB_PROFILE_BUFFER}
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

innodb_snapshot_isolation = 1
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
  apt_install mariadb-server mariadb-client
  systemctl enable --now mariadb
  systemctl status mariadb --no-pager || true

  mariadb_write_systemd_limits || true

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
    return 1
  fi
  if ! systemctl restart mariadb; then
    journalctl -u mariadb -n 80 --no-pager || true
    return 1
  fi
  mariadb_wait_ready 30 || true

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

install_valkey() {
  step "Valkey"
  if pkg_ok redis-server; then
    warn "redis-server is installed; leaving it untouched because setup.sh never removes packages."
    warn "Valkey was not installed. Run --optimize to tune the existing Redis server with the same cache profile."
    # A pre-existing Redis is not a failed install: the requested service was
    # already covered by a compatible cache and --optimize handles it.
    return 0
  fi
  apt_clean
  apt_install valkey-server
  ensure_log_dirs

  local conf=/etc/valkey/valkey.conf
  [[ -f $conf ]] || die "Valkey config ${conf} not found"

  local valkey_mb policy io_threads
  if [[ -n ${OPT[valkey.ram]:-} && ${OPT[valkey.ram],,} != auto ]]; then
    valkey_mb=$(size_to_mb "${OPT[valkey.ram]}")
  else
    valkey_mb=$(service_mem_mb valkey)
  fi
  policy=${OPT[valkey.policy]:-allkeys-lru}
  # For typical web-cache command sizes, extra I/O threads add more CPU
  # contention than throughput.  Benchmarks on a 16-core host showed
  # io-threads=1 at 6.5k full-page req/s vs 5.1k at io-threads=8.
  io_threads=${OPT[valkey.io_threads]:-1}

  # One writer for the base and tuning directives, shared with --optimize.
  valkey_apply_config "$conf" valkey "$valkey_mb" "$policy" "$io_threads" /run/valkey/valkey.sock
  info "Valkey maxmemory: ${valkey_mb} MB (${policy}; shared memory plan)"
  tail -24 "$conf"

  valkey_write_systemd_limits valkey-server valkey || true
  systemctl daemon-reload

  valkey-server -v
  # The package may have auto-started the stock configuration; one restart
  # loads the written file (enable --now followed by restart started it twice).
  systemctl enable valkey-server
  systemctl restart valkey-server
  systemctl status valkey-server -l --no-pager || true

  # Local PHP workers should use the Unix socket instead of opening a fresh
  # TCP connection (and burning an ephemeral port) for every request.  They
  # inherit the valkey group only after a restart.
  if valkey_ensure_www_group valkey; then
    restart_php_workers_for_group valkey
  fi

  wait_for_cmd 20 valkey_pong valkey-cli || true
  valkey-cli ping
  ok "Valkey installed and running"
}

# Base and tuning directives for Valkey/Redis.  Active copies of every
# managed key are removed and the canonical block appended once, so a fresh
# install and --optimize write byte-identical files and an old profile with
# "protected-mode no" or RDB saves is upgraded without contradictory
# duplicates.  Operator directives outside the managed set survive.
valkey_apply_config() {
  local conf=$1 kind=$2 max_mb=$3 policy=$4 io_threads=$5 socket=${6:-}
  [[ -n $socket ]] || socket="/run/${kind}/${kind}.sock"
  io_threads=$(valkey_clamp_io_threads "$io_threads")
  sed_in_place -E '/^[[:space:]]*(bind|protected-mode|save|maxmemory|maxmemory-policy|maxmemory-samples|supervised|io-threads|io-threads-do-reads|tcp-backlog|tcp-keepalive|timeout|maxclients|hz|appendonly|lazyfree-[a-z-]+|unixsocket|unixsocketperm|logfile)[[:space:]]/d' "$conf"
  {
    printf '%s\n' 'supervised systemd' \
      "logfile ${LOG_ROOT}/${kind}/${kind}.log" \
      'save ""' \
      'appendonly no' \
      'bind 127.0.0.1 -::1' \
      'protected-mode yes' \
      "unixsocket ${socket}" \
      'unixsocketperm 770'
    valkey_tuning_lines "$max_mb" "$policy" "$io_threads"
  } >> "$conf"
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

valkey_pong() { "$1" ping 2>/dev/null | grep -q PONG; }

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
  [[ -f $path ]] && before=$(md5sum "$path" | awk '{print $1}')
  printf '%s\n' "$content" > "$path"
  chmod 644 "$path"
  [[ $before != "$(md5sum "$path" | awk '{print $1}')" ]]
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

php_fpm_write_systemd_limits() {
  local ver=$1 src="${SCRIPT_DIR}/configs/php/php-fpm-limits.conf" content
  if [[ -f $src ]]; then
    content=$(<"$src")
  else
    content='[Service]
LimitNOFILE=524288
LimitCORE=0
TimeoutStopSec=15
UMask=0027'
  fi
  write_service_limits_dropin "/etc/systemd/system/php${ver}-fpm.service.d/limits.conf" "$content"
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
  elasticsearch_comment_keys "$file" \
    bootstrap.memory_lock indices.query.bool.max_clause_count \
    indices.memory.index_buffer_size indices.fielddata.cache.size \
    search.max_buckets action.destructive_requires_name \
    http.compression http.max_content_length http.host transport.host \
    thread_pool.search.size thread_pool.write.size node.processors
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
# END setup.sh optimize
EOF
  chmod 644 "$file"
}

# Elasticsearch refuses to start when vm.max_map_count is too low.  Always
# own the managed drop-in so the value survives a reboot, and raise the live
# value only when it is lower (a runtime value raised by hand must not hide a
# missing persistent file).  Shared by install and --optimize.
ensure_es_max_map_count() {
  local f=/etc/sysctl.d/99-elasticsearch.conf rc=0
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
elasticsearch_write_systemd_limits() {
  write_service_limits_dropin /etc/systemd/system/elasticsearch.service.d/limits.conf \
    $'[Service]\nLimitMEMLOCK=infinity\nLimitNOFILE=1048576\nLimitNPROC=4096'
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
        apt_install sysstat
        if [[ -f /etc/default/sysstat ]]; then
          sed_in_place -E 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
        fi
        systemctl enable --now sysstat-collect.timer sysstat-summary.timer 2>/dev/null \
          || systemctl enable --now sysstat 2>/dev/null \
          || warn "sysstat timers could not be enabled"
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
# or /etc/angie/ssl/default certificate paths, the hostname_ssl include), so
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
  src="/etc/angie/conf.d/templates/${tpl}"
  [[ -f $src ]] || die "Missing Angie template ${src} (app=${app})"
  cp "$src" "$vhost"
  tls="include h5bp/tls/ssl_engine.conf;\n    include h5bp/tls/policy_balanced.conf;\n    ssl_certificate     ${certdir}/fullchain.pem;\n    ssl_certificate_key ${certdir}/privkey.pem;"
  sed_in_place \
    -e 's|www\.example\.com|@@WWW@@|g' -e 's|www\.domain\.com|@@WWW@@|g' \
    -e 's|example\.com|@@DOMAIN@@|g' -e 's|domain\.com|@@DOMAIN@@|g' -e 's|sample\.com|@@DOMAIN@@|g' \
    -e "s|@@WWW@@|www.${d}|g" -e "s|@@DOMAIN@@|${d}|g" \
    -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
    -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
    -e "s#/etc/angie/ssl/default/#${certdir}/#g" \
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
      sed_in_place -e "s#/var/www/html/${d}/websocket.log#${LOG_ROOT}/angie/${d}-websocket.log#g" "$vhost"
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
  edb=$(sql_escape "$db")
  mariadb <<<"CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  mariadb -N -B -e "SHOW DATABASES LIKE '${edb}'" | grep -qx "$db" \
    || die "Failed to create MariaDB database '${db}' for ${d}"
  info "${d}: database ${db}"
  if [[ -n $user ]]; then
    mariadb_ensure_local_user "$user" "$pass" "ALL PRIVILEGES ON \`${db//_/\\_}\`.*"
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
  if ! {
       printf 'SET autocommit=0; SET unique_checks=0; SET foreign_key_checks=0; SET SESSION sql_log_bin=0;\n'
       "${reader[@]}" "$sql"
       printf '\nCOMMIT;\n'
     } | mariadb --max-allowed-packet=1G "$db"; then
    die "${d}: import of ${sql} into ${db} failed (the database may be partially loaded)"
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
  info "Memory plan: ${OPT_MEM_BUDGET_MB}MB usable of ${OPT_MEM_TOTAL_MB}MB (PHP=${OPT_PHP_BUDGET_MB}MB MariaDB=${OPT_MARIADB_BUDGET_MB}MB Cache=${OPT_VALKEY_BUDGET_MB}MB Elasticsearch=${OPT_ES_BUDGET_MB}MB)"
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

create_domains() {
  step "Domains"
  (( ${#DOMAINS[@]} > 0 )) || return 0

  [[ -d /etc/angie/conf.d ]] \
    || die "Angie is not installed (/etc/angie/conf.d missing). Install with --angie first."
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

  local dir conf app certdir tmp changed=0 imported=0 pv
  for d in "${DOMAINS[@]}"; do
    app=${DOMAIN_APP[$d]:-basic}
    dir="/var/www/${d}/public"
    conf="/etc/angie/conf.d/${d}.conf"
    certdir="/etc/angie/ssl/${d}"

    # Imagick is required by Chevereto, but it is not part of the
    # XenForo/WordPress default PHP profile.  Install it only when a
    # Chevereto vhost is explicitly requested (including an existing one).
    if [[ $app == chevereto ]] && ! php -m 2>/dev/null | grep -qix imagick; then
      pv=$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)
      if [[ -n $pv ]]; then
        info "Chevereto requires Imagick; installing php${pv}-imagick (Chevereto only)"
        apt_install "php${pv}-imagick" \
          || warn "Could not install php${pv}-imagick; Chevereto may fail its image checks"
        systemctl restart "php${pv}-fpm" 2>/dev/null || true
      else
        warn "Chevereto requires the PHP Imagick extension, but the PHP version could not be detected"
      fi
    fi

    # Only a tree this run creates is chowned recursively.  An existing site
    # keeps its ownership (root:www-data wp-config.php, deploy-owned files);
    # the nightly managed cron applies the log-safe ownership pass.
    if [[ -d "/var/www/${d}" ]]; then
      mkdir -p "$dir" "${LOG_ROOT}/angie"
      chown www-data:www-data "$dir" 2>/dev/null || true
    else
      mkdir -p "$dir" "${LOG_ROOT}/angie"
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
      info "Angie config already exists and is non-empty; keeping ${conf}"
    else
      tmp=$(tmp_file)
      domain_render_vhost "$app" "$d" "$certdir" "$tmp"
      install -m 644 "$tmp" "$conf"
      local domain_test_log
      domain_test_log=$(tmp_file)
      if ! /usr/sbin/angie -t >"$domain_test_log" 2>&1; then
        cat "$domain_test_log" >&2 || true
        # Keep the rejected file out of the live config without deleting it.
        local rejected
        rejected=$(preserve_to_tmp "$conf" || true)
        [[ -n $rejected ]] && warn "Moved rejected vhost to ${rejected}"
        die "Angie rejected the generated vhost for ${d} (app=${app})"
      fi
      # "angie -t" runs from this shell (umask 022) and creates the per-vhost
      # log files before systemd's UMask=0027 applies. Normalise them now.
      find "${LOG_ROOT}/angie" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
      changed=1
      info "Created Angie vhost: ${conf} (app=${app})"
    fi

    if domain_provision_database "$d"; then
      imported=1
    fi
  done

  if (( changed )); then
    systemctl reload angie 2>/dev/null || systemctl restart angie 2>/dev/null \
      || warn "Could not reload Angie after creating vhosts"
  fi
  if (( imported )); then
    reoptimize_mariadb_after_import
  fi
  for d in "${DOMAINS[@]}"; do
    [[ ${DOMAIN_APP[$d]:-basic} == xf ]] || continue
    info "XenForo ${d}: dynamic Brotli is enabled; keep XF's Redis cache off on a single local-MariaDB host (measured slower), and disable the Members online / Trending / Featured widgets if you do not need them (measured +39% authenticated throughput)."
  done
  # A new vhost changes what the tuner plans: the PHP-FPM worker cap, the
  # OPcache file budget, the FastCGI guest cache for the new root, and the
  # managed wp-cron / XenForo job entries.  Running the same pass --optimize
  # runs keeps a domain install byte-identical to "install, then --optimize"
  # instead of leaving the host in a half-tuned state until someone runs the
  # optimizer by hand.  SETUP_DOMAIN_OPTIMIZE=0 skips it for a caller that
  # deploys the application files later and tunes afterwards.
  if [[ ${SETUP_DOMAIN_OPTIMIZE:-1} != 0 ]]; then
    info "Re-tuning installed services for the new vhost(s) (the --optimize pass)"
    local saved_optimize=${OPTIMIZE:-0}
    OPTIMIZE=1
    run_optimize || warn "Post-domain tuning reported an issue (see the report)"
    OPTIMIZE=$saved_optimize
  fi
  ok "Domain setup complete"
}

