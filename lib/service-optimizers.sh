# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).
# ---------------------------------------------------------------------------
# Service optimizers shared by --optimize, --upgrade-php and --restart-all.
#
# This module owns the per-service tune/verify/profile code.  It used to live
# at the end of security.sh, which mixed two unrelated responsibilities: the
# WordPress/system hardening pass and the stack optimizers.  Every function
# here is called through lib/optimize.sh (run_optimize) or lib/php-upgrade.sh
# (php_upgrade_optimize), never by the installer directly; the installer and
# --optimize share the lower-level writers in lib/web.sh and lib/services.sh.
#
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------

# The nginx fd limit and UMask live in our nginx.service (lib/nginx-build.sh
# writes LimitNOFILE=524288 and UMask=0027), so --optimize writes no
# nginx.service.d drop-in and no /etc/default/nginx any more (1.21's
# ensure_nginx_limits and the synced scripts/limit_nofile.conf are gone).

# ---------------------------------------------------------------------------
# Shared post-nginx PHP refresh
# ---------------------------------------------------------------------------
# The managed PHP ini carries [PATH=] sections derived from the nginx tree the
# PHP pass saw (the guest-cache encoding token and the WordPress/Chevereto
# document roots).  optimize_nginx / nginx_apply_profile have just synced that
# tree from the repository, so the ini must be rewritten afterwards or the next
# run rewrites sections computed from a tree one version behind (and a newly
# deployed root never gets its section).  Shared by --optimize and
# --upgrade-php: the two copies had already drifted (the upgrade path did not
# mark the cache cutover).
#   $1 reporter function for normal lines (opt_report or info)
#   $2 line prefix ("- " for the Markdown report, "" for the console)
# Returns non-zero when a write or a reload failed; sets OPT_CUTOVER=1 when a
# pool was reloaded.
#
# php_fpm_reload_verified X.Y: reload, then confirm the master survived the
# SIGUSR2 re-exec for ~3 s.  A configuration php-fpm rejects only while it
# starts (1.22.3: PHP 8.6's tracing JIT on a 61 MB buffer) let `systemctl
# reload` return success, was reported "Reload: OK", and left the unit
# failed a moment later: PHP stayed down until someone noticed.
php_fpm_reload_verified() { # X.Y
  local v=$1 i
  systemctl reload "php${v}-fpm" 2>/dev/null || return 1
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    systemctl is-active --quiet "php${v}-fpm" 2>/dev/null || return 1
  done
  return 0
}
# After a restored configuration: a pool a failed reload took down is started
# again from what is on disk now (tested first).
php_fpm_ensure_running() { # X.Y
  local v=$1
  systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && return 0
  if php_fpm_test "$v" >/dev/null 2>&1 && systemctl restart "php${v}-fpm" 2>/dev/null \
     && systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
    opt_report "- PHP ${v}: started again on the restored configuration"
    return 0
  fi
  warn "PHP ${v}: not running after the rollback; check /usr/local/sbin/php-fpm${v} -t and 'systemctl status php${v}-fpm'"
  opt_report "- **FAILED** PHP ${v}: not running after the rollback"
  return 1
}

php_refresh_after_nginx() {
  local reporter=${1:-opt_report} prefix=${2:-- }
  [[ ${OPT_PHP_OK:-0} -eq 1 ]] || return 0
  local v dirty=0 rc=0 snap
  while IFS= read -r v; do
    # tune_php_fpm_version writes the pool and ini before php-fpm -t; a
    # rejected pair left on disk fails the next restart.  Snapshot the tree
    # as the first PHP pass left it (not the pre-run opt_backup copy, which
    # would also undo that pass, its socket listener included) and restore
    # it on failure.  Quiet: a clean refresh must add no report line.
    snap=""
    if [[ -d /etc/php/${v} ]]; then
      snap=$(tmp_dir 2>/dev/null || true)
      if [[ -n $snap ]] && ! cp -a "/etc/php/${v}/." "${snap}/" 2>/dev/null; then
        snap=""
      fi
    fi
    tune_reset_changes
    if tune_php_fpm_version "$v"; then
      # A clean pass only repeats the informational tune_summary lines
      # (max_children ...) already in the PHP section; printing them here put
      # a PHP line under whichever section ran last (Elasticsearch).
      (( TUNE_DIRTY )) || continue
      dirty=1
      [[ $reporter == opt_report ]] && opt_report "## PHP ${v} (post-nginx refresh)"
      for change in "${TUNE_CHANGES[@]}"; do
        "$reporter" "${prefix}${change} (post-nginx refresh)"
      done
    else
      if [[ -n $snap ]] && restore_tree "$snap" "/etc/php/${v}"; then
        warn "PHP ${v}: post-nginx ini refresh failed; restored the configuration the PHP pass wrote"
        opt_report "- **FAILED** PHP ${v}: post-nginx ini refresh; rolled back to the PHP pass result"
        php_fpm_ensure_running "$v"
      else
        # /usr/local/sbin/php-fpmX.Y is the build's wrapper: it passes the
        # same -y, -c and PHP_INI_SCAN_DIR as the unit (php_fpm_test).
        warn "PHP ${v}: post-nginx ini refresh failed and could not be rolled back; check /usr/local/sbin/php-fpm${v} -t before the next restart"
        opt_report "- **FAILED** PHP ${v}: post-nginx ini refresh (no rollback; check \`/usr/local/sbin/php-fpm${v} -t\`)"
      fi
      rc=1
    fi
  done < <(php_fpm_versions)
  (( dirty )) || return "$rc"
  while IFS= read -r v; do
    systemctl is-active --quiet "php${v}-fpm" 2>/dev/null || continue
    if php_fpm_reload_verified "$v"; then
      "$reporter" "${prefix}PHP ${v}: reloaded after the post-nginx ini refresh"
      OPT_CUTOVER=1
    else
      warn "PHP ${v}: reload after the post-nginx ini refresh failed"
      opt_report "- **FAILED** PHP ${v}: reload after the post-nginx ini refresh"
      php_fpm_ensure_running "$v"
      rc=1
    fi
  done < <(php_fpm_versions)
  return "$rc"
}

optimize_nginx() {
  local active=0 change version rc=0
  local nginx_bin
  nginx_bin=$(opt_nginx_bin)
  # Legacy-Angie mode (R19/R51): /etc/nginx is not the live tree and no
  # nginx-tree logic may touch /etc/angie.  detect_installed_services already
  # leaves nginx out; this guards a direct caller.
  if (( ${OPT_WEB_LEGACY:-0} )); then
    opt_report "## nginx"
    opt_report "- Skipped: Angie still serves (legacy mode); the 1.22 migration retries on the next --optimize"
    return 0
  fi
  systemctl is-active --quiet nginx 2>/dev/null && active=1
  version=$("$nginx_bin" -v 2>&1 | head -n1 || true)
  opt_report "## nginx"
  opt_report "- Version: \`${version:-unknown}\`; active: ${active}"
  # The tree is all the sync and the tuner write (the unit's limits are in
  # our nginx.service, not in a drop-in or /etc/default/nginx).
  opt_backup /etc/nginx nginx
  tune_reset_changes

  # Keep /etc/nginx byte-for-byte aligned with the canonical repository before
  # applying the hardware-aware profile.  The repository deployer owns the
  # tree layout and validates it; the reload happens once below, after the
  # tuning, and only when the tree actually changed.
  local digest_before digest_after
  digest_before=$(config_tree_digest /etc/nginx)
  NGINX_SYNC_RELOAD=0
  if sync_nginx_repo_configs; then
    NGINX_SYNC_RELOAD=1
    opt_report "- Repository: synchronized from ${CONFIG_REPO_URL} (${CONFIG_REPO_REF})"
  else
    NGINX_SYNC_RELOAD=1
    rc=1
    opt_report "- **FAILED** nginx repository synchronization; restored the existing /etc/nginx tree"
    nginx_restore_live
  fi
  # Same profile as the installer (nginx_apply_profile): guest caches,
  # the tuner and Brotli (a static module of our build, so
  # only directives are written, never load_module; gzip stays the fallback).
  if ! nginx_apply_profile /etc/nginx; then
    nginx_restore_live
    opt_report "- **FAILED** tuning returned an error; configuration rolled back"
    return 1
  fi
  opt_report "- ${NGINX_COMPRESSION_SUMMARY}"
  # Cloudflare-proxied vhosts move off certbot certificates before the tree
  # digest and the nginx -t below, so a broken rewrite is rolled back with
  # the rest of the tune (cloudflare_tls_finish checks them after the reload).
  # Same condition as the finish step: a rewrite never goes live unchecked.
  if (( rc == 0 && active )); then
    cloudflare_tls_migrate /etc/nginx 0 || true
  fi
  # The sync restores every repository file before the tuner re-applies the
  # same values, so TUNE_DIRTY is set on every run; compare the tree instead
  # so an already-optimized host is not reloaded.
  digest_after=$(config_tree_digest /etc/nginx)
  if [[ $digest_before == "$digest_after" ]]; then
    TUNE_DIRTY=0
  else
    TUNE_DIRTY=1
  fi
  local nginx_test_log
  nginx_test_log=$(tmp_file)
  if ! "$nginx_bin" -t >"$nginx_test_log" 2>&1; then
    opt_report "- **FAILED** \`nginx -t\`:"
    while IFS= read -r change; do opt_report "  \`${change}\`"; done < "$nginx_test_log"
    nginx_restore_live
    return 1
  fi
  for change in "${TUNE_CHANGES[@]}"; do opt_report "- ${change}"; done
  for change in "${TUNE_MISSES[@]}"; do opt_report "- Not applied: ${change}"; done
  local -a inert=()
  mapfile -t inert < <(nginx_inert_cache_files /etc/nginx)
  if (( ${#inert[@]} > 0 )); then
    local inert_file
    opt_report "- Warning: ${#inert[@]} cache/limit file(s) under http.d are not included by nginx.conf:"
    for inert_file in "${inert[@]}"; do opt_report "  \`${inert_file}\`"; done
    opt_report "  They are not loaded (nginx.conf includes only *.conf).  Rename one to .conf only if no loaded file defines its zones or maps already (otherwise nginx -t fails on a duplicate); remove it if it is obsolete."
  fi
  if (( active )); then
    if (( TUNE_DIRTY == 0 )); then
      opt_report "- Restart: skipped (configuration already optimized)"
    elif systemctl reload nginx 2>/dev/null && systemctl is-active --quiet nginx; then
      OPT_CUTOVER=1
      opt_report "- Reload: **OK** (graceful; in-flight requests keep running)"
    elif systemctl restart nginx 2>/dev/null && systemctl is-active --quiet nginx; then
      OPT_CUTOVER=1
      opt_report "- Reload failed; Restart: **OK**"
    else
      opt_report "- Reload/Restart: **FAILED**; rolling back"
      nginx_restore_live
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  # zstd (1.21.58) module: only after the pass committed, so a rollback above
  # never restores a tree that loads a purged module.
  if (( rc == 0 && NGINX_ZSTD_PURGE_PENDING )) && "$nginx_bin" -t >/dev/null 2>&1; then
    nginx_purge_zstd_module /etc/nginx
    [[ -n $NGINX_ZSTD_PURGE_RESULT ]] && opt_report "- ${NGINX_ZSTD_PURGE_RESULT}"
  fi
  NGINX_ZSTD_PURGE_PENDING=0
  # Through-Cloudflare check of the migrated vhosts, then certbot retirement.
  # Both need the reloaded, running nginx; a stopped one keeps certbot.
  if (( rc == 0 && active )); then
    cloudflare_tls_finish 0 || true
  fi
  # The compiled nginx (lib/nginx-build.sh): rebuild when `check` finds the
  # build stale (new mainline or library, CPU, recipe), swap it in with an
  # in-place upgrade, start nginx if it is down, then BOLT from live traffic.
  # It runs after the tune so the build's live-config test sees the tuned
  # tree.  A failed build keeps the running binary serving and marks the run.
  if (( rc == 0 )) && ! nginx_build_ensure full optimize opt_report; then
    rc=1
  fi
  return "$rc"
}

# Roll /etc/nginx back to the --optimize snapshot and put the restored
# configuration live again.
nginx_restore_live() {
  opt_restore /etc/nginx nginx
  if "$(opt_nginx_bin)" -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  fi
  return 0
}

# True when active PHP vhosts use the shared local_php upstream, so the
# temporary socket-primary/TCP-backup cutover is safe.  A direct fastcgi_pass
# or fastcgi_next_upstream off cannot fall back to the TCP listener.
nginx_uses_local_php_upstream() {
  local target=${1:-/etc/nginx}
  grep -rqE '^[[:space:]]*fastcgi_pass[[:space:]]+local_php;' \
    "$target/nginx.conf" "$target"/conf.d "$target"/h5bp 2>/dev/null || return 1
  if grep -rqE '^[[:space:]]*fastcgi_pass[[:space:]]+(127\.0\.0\.1|localhost):[0-9]+;' \
       "$target/nginx.conf" "$target"/conf.d "$target"/h5bp 2>/dev/null; then
    return 1
  fi
  if grep -rqE '^[[:space:]]*fastcgi_next_upstream[[:space:]]+off;' \
       "$target" 2>/dev/null; then
    return 1
  fi
  return 0
}

# Move the primary PHP-FPM pool from a loopback TCP listener to the shared
# Unix socket without dropping requests.  A temporary bridge pool cannot be
# used: PHP-FPM's SIGUSR2 reload applies changes to existing pools but does
# not start a newly added pool (verified on PHP 8.3), so the bridge never
# listened.  Instead nginx gets the socket as primary and the TCP listener as
# backup, the existing pool is switched and reloaded, and the backup is
# retired once the socket is live.  A request that lands exactly while the
# old TCP listener closes and the socket opens can fail over to the backup;
# if both are unavailable for a moment nginx returns 502.  Cache objects
# written in that window are reported, never deleted.  On failure both files
# are restored and the services reload the original configuration.
MIGRATE_REASON=""

migrate_php_pool_to_socket() {
  local ver=$1 tcp=$2
  local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
  local nginx_conf=/etc/nginx/nginx.conf
  local socket=/run/php/php-fpm.sock
  local bakdir bak="${OPT_BACKUP_DIR:-}/php-socket"
  local tcp_re port i ok=0 nginx_bin
  nginx_bin=$(opt_nginx_bin)
  MIGRATE_REASON=""
  if [[ -z ${OPT_BACKUP_DIR:-} ]]; then
    bakdir=$(tmp_dir setup-php-socket.XXXXXX) || { MIGRATE_REASON="could not create a backup directory"; return 1; }
    bak="${bakdir}/php-socket"
  fi

  [[ -f $pool && -f $nginx_conf ]] || { MIGRATE_REASON="pool or nginx.conf is missing"; return 1; }
  systemctl is-active --quiet nginx || { MIGRATE_REASON="nginx is not active"; return 1; }
  # Every config test below is php_fpm_test (the unit's -y, -c and
  # PHP_INI_SCAN_DIR, R2.8); a bare `php-fpm -t` read the CLI scan dir.
  if ! php_fpm_is_ours "$ver"; then
    MIGRATE_REASON="PHP ${ver} is not the compiled build"
    return 1
  fi
  nginx_uses_local_php_upstream /etc/nginx \
    || { MIGRATE_REASON="vhosts use a direct fastcgi_pass or fastcgi_next_upstream off"; return 1; }
  tcp_re=${tcp//./\\.}
  port=${tcp##*:}
  grep -qE "^[[:space:]]*server[[:space:]]+${tcp_re};" "$nginx_conf" \
    || { MIGRATE_REASON="upstream does not contain ${tcp}"; return 1; }

  if ss -lx 2>/dev/null | grep -qF "$socket"; then
    MIGRATE_REASON="${socket} is already owned by another pool"
    return 1
  fi

  mkdir -p "$bak"
  cp -a "$pool" "$bak/www.conf"
  cp -a "$nginx_conf" "$bak/nginx.conf"

  # 1. nginx: socket primary, current TCP listener as backup.  nginx -t
  #    accepts a unix: server whose socket does not exist yet; the connect
  #    fails fast and the backup serves traffic until PHP creates the socket.
  #    max_fails=0 would disable failure accounting and keep the backup
  #    unused, so use a short fail_timeout that retries the socket quickly.
  sed_in_place -E \
    "s|^([[:space:]]*)server[[:space:]]+${tcp_re};|\1server unix:${socket} max_fails=1 fail_timeout=2s;\n\1server ${tcp} backup;|" \
    "$nginx_conf"
  if ! grep -qF "server unix:${socket} max_fails=1 fail_timeout=2s;" "$nginx_conf" \
     || ! "$nginx_bin" -t >/dev/null 2>&1 \
     || ! systemctl reload nginx 2>/dev/null; then
    cp -a "$bak/nginx.conf" "$nginx_conf"
    "$nginx_bin" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    MIGRATE_REASON="nginx rejected the socket+backup upstream"
    return 1
  fi
  cp -a "$nginx_conf" "$bak/nginx-backup.conf"

  # 2. Move the existing pool to the socket.  The reload is graceful: old
  #    workers finish in-flight TCP requests while the master opens the socket.
  php_pool_set_listener "$pool" "$ver" "$socket"
  if ! php_fpm_test "$ver" >/dev/null 2>&1; then
    cp -a "$bak/www.conf" "$pool"
    cp -a "$bak/nginx.conf" "$nginx_conf"
    "$nginx_bin" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    MIGRATE_REASON="PHP rejected the socket pool"
    return 1
  fi
  # Try the graceful reload first.  If it fails, a restart is still required:
  # the migration is mandatory, not an optional optimization.
  if ! systemctl reload "php${ver}-fpm" 2>/dev/null; then
    opt_report "- PHP-FPM reload failed; restarting to apply the socket listener"
    if ! systemctl restart "php${ver}-fpm" 2>/dev/null; then
      cp -a "$bak/www.conf" "$pool"
      cp -a "$bak/nginx.conf" "$nginx_conf"
      php_fpm_test "$ver" >/dev/null 2>&1 && systemctl restart "php${ver}-fpm" 2>/dev/null || true
      "$nginx_bin" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
      MIGRATE_REASON="PHP-FPM reload and restart failed"
      return 1
    fi
  fi
  # Give the master a short window to open the socket.  Some builds do not
  # apply a listener change on SIGUSR2 at all (PHP 8.5 closed the old TCP
  # listener without opening the socket); for those, restart PHP-FPM now.
  for i in {1..15}; do
    if systemctl is-active --quiet "php${ver}-fpm" \
       && ss -lx 2>/dev/null | grep -qF "$socket"; then
      ok=1
      break
    fi
    sleep 0.2
  done
  if (( ok == 0 )); then
    opt_report "- PHP-FPM did not apply the socket on reload; restarting to complete the migration"
    if systemctl restart "php${ver}-fpm" 2>/dev/null; then
      for i in {1..50}; do
        if systemctl is-active --quiet "php${ver}-fpm" \
           && ss -lx 2>/dev/null | grep -qF "$socket"; then
          ok=1
          break
        fi
        sleep 0.2
      done
    fi
    if (( ok == 0 )); then
      cp -a "$bak/www.conf" "$pool"
      cp -a "$bak/nginx.conf" "$nginx_conf"
      php_fpm_test "$ver" >/dev/null 2>&1 && systemctl restart "php${ver}-fpm" 2>/dev/null || true
      "$nginx_bin" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
      MIGRATE_REASON="PHP-FPM did not open ${socket} after reload or restart; restored the TCP listener"
      return 1
    fi
    opt_report "- PHP-FPM restart applied the socket listener"
  fi

  # 3. Drop the TCP backup; the socket is proven live.
  sed_in_place -E "/^[[:space:]]*server[[:space:]]+${tcp_re}[[:space:]]+backup;/d" "$nginx_conf"
  sed_in_place -E "s|server unix:${socket} max_fails=1 fail_timeout=2s;|server unix:${socket};|" "$nginx_conf"
  if ! "$nginx_bin" -t >/dev/null 2>&1 \
     || ! systemctl reload nginx 2>/dev/null; then
    # Keep the working socket+backup config rather than risking the site.
    cp -a "$bak/nginx-backup.conf" "$nginx_conf"
    "$nginx_bin" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    MIGRATE_REASON="nginx could not drop the TCP backup (socket is live; backup kept)"
    return 1
  fi
  return 0
}
optimize_php_services() {
  local primary ver active listen_path rc=0 build_ver="" build_rc=0
  # Legacy-Angie mode: the web tier is left alone (R19/R51); the PHP
  # [PATH=] sections are computed from /etc/nginx, which is not live yet.
  if (( ${OPT_WEB_LEGACY:-0} )); then
    OPT_PHP_OK=0
    opt_report "## PHP"
    opt_report "- Skipped: Angie still serves (legacy mode); PHP-FPM is tuned once the 1.22 migration moved the web tier to nginx"
    return 0
  fi
  primary=$(php_primary_version)
  if [[ -z $primary ]]; then
    # No pool we can safely identify: leave nginx's FastCGI upstream alone
    # rather than pointing it at a socket that was never created.
    OPT_PHP_OK=0
    opt_report "- No PHP-FPM pool with a usable www.conf; nginx upstream left unchanged"
    return 0
  fi
  # Only the active version is built, laid out and started (one version
  # owns the shared socket, R61): /etc/php/setup-active, else the primary
  # pool, which php_build_ensure then records as the active version.  The
  # others stay on disk, disabled, for --upgrade-php=X.Y.
  if declare -F php_active_version >/dev/null 2>&1; then
    build_ver=$(php_active_version 2>/dev/null || true)
  fi
  [[ -n $build_ver ]] || build_ver=$primary
  while IFS= read -r ver; do
    opt_report "## PHP ${ver}"
    # Build first: a stale build (new release, changed extension set, other
    # CPU, recipe) is rebuilt and swapped in, the managed /etc/php/X.Y files
    # are re-laid (www.conf keeps the tuner's pm/listen keys), the unit is
    # started if it is down, and BOLT samples live traffic.  The tune below
    # then applies on top of exactly what serves, and its backup is taken
    # after the layout, so a rollback never pairs the new binary with files
    # an older layout wrote.  A failed build keeps the running one serving:
    # it fails the run (build_rc) but does not stop the tune or the socket
    # handover to nginx below.
    if [[ $ver == "$build_ver" ]] && ! php_build_ensure "$ver" full optimize opt_report; then
      build_rc=1
    fi
    active=0
    systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && active=1
    # Preserve the pool's existing listener.  Migrating a live TCP pool to a
    # Unix socket creates a window where nginx still points at port 9000 and
    # every request returns 502.  Installations still use the socket template.
    listen_path=$(php_pool_listen "$ver")
    opt_report "- Active: ${active}; listen kept: \`${listen_path:-unknown}\`"
    opt_backup "/etc/php/${ver}" "php-${ver}"
    opt_backup "/etc/systemd/system/php${ver}-fpm.service.d" "php-${ver}-systemd"
    tune_reset_changes
    # Replace a stale managed php.ini copy before tuning.  Keep the live
    # timezone; everything else follows configs/php/custom_dan.ini.
    # (The fd/core limits and the graceful stop are part of our unit text,
    # php_build_unit_text: the 1.21 limits drop-in is moved aside by
    # php_build_unit_write and must not be written again here.)
    sync_php_ini_template "$ver"
    if ! tune_php_fpm_version "$ver"; then
      opt_restore "/etc/php/${ver}" "php-${ver}"
      opt_restore "/etc/systemd/system/php${ver}-fpm.service.d" "php-${ver}-systemd"
      systemctl daemon-reload || true
      opt_report "- **FAILED** PHP-FPM configuration test; rolled back"
      rc=1
      OPT_PHP_OK=0
      continue
    fi
    local change
    for change in "${TUNE_CHANGES[@]}"; do opt_report "- ${change}"; done
    for change in "${TUNE_MISSES[@]}"; do opt_report "- Not applied: ${change}"; done
    local migrated=0 migration_failed=0
    if (( active )) && [[ $ver == "$primary" ]] \
       && [[ $listen_path =~ ^(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
      if systemctl is-active --quiet nginx \
         && nginx_uses_local_php_upstream /etc/nginx; then
        if migrate_php_pool_to_socket "$ver" "$listen_path"; then
          OPT_PHP_SOCKET=/run/php/php-fpm.sock
          OPT_CUTOVER=1
          migrated=1
          opt_report "- Migrated listener: ${listen_path} -> unix:${OPT_PHP_SOCKET}"
        else
          opt_report "- **FAILED** socket migration; kept ${listen_path} (${MIGRATE_REASON:-no reason recorded})"
          rc=1
          OPT_PHP_OK=0
          migration_failed=1
        fi
      else
        opt_report "- Socket migration skipped: nginx inactive or vhosts use a direct fastcgi_pass/next_upstream off"
      fi
    fi
    if (( active )); then
      if (( migrated || migration_failed )); then
        : # migration already reloaded PHP (success or rollback)
      elif (( TUNE_DIRTY == 0 )); then
        opt_report "- Restart: skipped (configuration already optimized)"
      elif php_fpm_reload_verified "$ver" \
         && { [[ $listen_path != /* ]] || [[ -S $listen_path ]]; }; then
        # SIGUSR2 reloads the pool without closing the listening socket: old
        # workers finish in-flight requests and new workers pick up the tuned
        # values.  This is the difference between a zero-downtime tune and a
        # 1-3 second 502 window on a busy site.
        OPT_CUTOVER=1
        opt_report "- Reload: **OK** (graceful; no request was dropped)"
        if [[ -f "/etc/php/${ver}/fpm/php-fpm.conf" ]] \
           && grep -q 'process_control_timeout' "/etc/php/${ver}/fpm/php-fpm.conf"; then
          opt_report "- Note: master-level process_control_timeout applies on the next full restart"
        fi
      elif systemctl restart "php${ver}-fpm" 2>/dev/null \
         && systemctl is-active --quiet "php${ver}-fpm"; then
        OPT_CUTOVER=1
        # Type=notify only returns once the master is ready.  A pool that
        # already used a Unix socket must have re-created it.
        if [[ $listen_path == /* && ! -S $listen_path ]]; then
          opt_report "- **FAILED** ${listen_path} was not created; rolling back"
          opt_rollback_restart "php${ver}-fpm" "/etc/php/${ver}" "php-${ver}" "php-${ver}-systemd"
          rc=1
          OPT_PHP_OK=0
        else
          opt_report "- Reload failed; Restart: **OK**"
        fi
      else
        opt_report "- Reload/Restart: **FAILED**; rolling back"
        opt_rollback_restart "php${ver}-fpm" "/etc/php/${ver}" "php-${ver}" "php-${ver}-systemd"
        rc=1
        OPT_PHP_OK=0
      fi
    elif systemctl is-failed --quiet "php${ver}-fpm" 2>/dev/null; then
      # A unit that crashed (not one the operator stopped: that is
      # "inactive") is started again once the tuned configuration passes
      # php-fpm -t (1.22.3: a JIT size PHP 8.6 rejects left php8.6-fpm
      # failed, and the --optimize that wrote a good size skipped it).
      if php_fpm_test "$ver" >/dev/null 2>&1 && systemctl restart "php${ver}-fpm" 2>/dev/null \
         && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
        opt_report "- Start: **OK** (the unit had failed; the tuned configuration passes php-fpm -t)"
        # The build step's "did not start" was this configuration, not the
        # build: with a current build the run is not a failure any more.
        if [[ $ver == "$build_ver" ]] && declare -F php_build_current >/dev/null 2>&1 && php_build_current "$ver"; then
          build_rc=0
        fi
      else
        opt_report "- **FAILED** php${ver}-fpm had failed and does not start on the tuned configuration (systemctl status php${ver}-fpm)"
        rc=1
        OPT_PHP_OK=0
      fi
    else
      opt_report "- Restart: skipped (service was not active)"
    fi
  done < <(php_fpm_versions)

  # Only hand a socket path to nginx when that pool is active and the socket
  # actually exists.  TCP pools deliberately leave OPT_PHP_SOCKET empty.
  if (( rc == 0 )); then
    listen_path=$(php_pool_listen "$primary")
    if [[ $listen_path == /* ]] \
       && systemctl is-active --quiet "php${primary}-fpm" \
       && [[ -S $listen_path ]]; then
      OPT_PHP_SOCKET=$listen_path
    fi
  fi
  (( build_rc )) && rc=1
  return "$rc"
}

mariadb_server_version() {
  local v
  v=$(mariadbd --version 2>/dev/null | awk '{print $3}' || true)
  [[ -n $v ]] || v=$(mariadb --version 2>/dev/null | awk '{print $5}' || true)
  printf '%s' "${v%%-*}"
}

# True when two generated MariaDB configs differ only in the buffer-pool size,
# so the value can be applied online without a restart.
# Keys of the tuning drop-in that a running server accepts through SET
# GLOBAL.  The redo log is resizable online since MariaDB 10.9, and the
# capacity keys (io_capacity, table_open_cache, thread_pool_size,
# max_connections, flush_neighbors) are dynamic in the supported releases;
# each non-pool SET is verified by reading the variable back, so a server that
# refuses one falls back to the restart path.  When only these differ between
# the old and the new file, --optimize applies them online instead of
# restarting a busy database with the web tiers paused.
MARIADB_ONLINE_ORDER=(innodb_buffer_pool_size innodb_log_file_size tmp_table_size
                      max_heap_table_size innodb_io_capacity innodb_io_capacity_max
                      table_open_cache table_definition_cache max_connections
                      thread_pool_size innodb_flush_neighbors)
# One list, two views: the array drives the SET order and the ERE used to
# ignore those keys when deciding whether a restart is needed.  Keeping a
# separate regex string here let the two drift apart.
MARIADB_ONLINE_KEYS=$(IFS='|'; printf '%s' "${MARIADB_ONLINE_ORDER[*]}")
# Keys that only matter at the next start and must not force one now:
# loose-innodb_buffer_pool_size_max is read-only, and the running server
# already has the ceiling it started with.  innodb_open_files follows
# table_open_cache (the profile writes all three from one value) but is
# read-only on the supported releases; without it here every max_connections
# change above 250 forced a full restart with the web tier paused, although
# the two keys it moves with are dynamic.  innodb_log_buffer_size (RAM/256)
# and aria_pagecache_buffer_size (RAM/128) are read-only and follow MemTotal
# without rounding between their clamps, so a kernel update that moved
# MemTotal by a few MB restarted the database (web tier paused) for a 1 MB
# change; the next natural restart applies them.
MARIADB_DEFERRED_KEYS='loose-innodb_buffer_pool_size_max|innodb_open_files|innodb_log_buffer_size|aria_pagecache_buffer_size'
cnf_only_pool_changed() {
  local old=$1 new=$2
  [[ -f $old && -f $new ]] || return 1
  diff -q \
    <(grep -vE "^[[:space:]]*(${MARIADB_ONLINE_KEYS}|${MARIADB_DEFERRED_KEYS})[[:space:]]*=" "$old") \
    <(grep -vE "^[[:space:]]*(${MARIADB_ONLINE_KEYS}|${MARIADB_DEFERRED_KEYS})[[:space:]]*=" "$new") \
    >/dev/null 2>&1
}

# Value of KEY in a my.cnf-style FILE as bytes (K/M/G suffixes), empty when
# the key is absent.
cnf_key_bytes() {
  local file=$1 key=$2 val num unit
  val=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([0-9]+[kKmMgG]?).*/\1/p" "$file" 2>/dev/null | tail -n1)
  [[ -n $val ]] || return 0
  num=${val%%[kKmMgG]*}
  unit=${val#"$num"}
  case ${unit,,} in
    k) printf '%s' $(( num * 1024 )) ;;
    m) printf '%s' $(( num * 1048576 )) ;;
    g) printf '%s' $(( num * 1073741824 )) ;;
    *) printf '%s' "$num" ;;
  esac
}

# Apply the online-capable keys that changed between OLD and NEW with SET
# GLOBAL; the buffer pool first (it bounds tmp_table_size), then the rest.
# Every non-pool key is read back after the SET, and the first rejection or
# mismatch returns 1 so the caller falls back to a restart.
mariadb_apply_online_keys() {
  local old=$1 new=$2 key before after live
  for key in "${MARIADB_ONLINE_ORDER[@]}"; do
    before=$(cnf_key_bytes "$old" "$key")
    after=$(cnf_key_bytes "$new" "$key")
    [[ -n $after && $before != "$after" ]] || continue
    # The caller has already set the pool (and checked what took); a second
    # SET while 10.11/11.4 still resize in the background is rejected and
    # would turn an online resize into a restart.
    [[ $key == innodb_buffer_pool_size ]] && continue
    mariadb -e "SET GLOBAL ${key} = ${after}" 2>/dev/null || return 1
    if [[ $key != innodb_buffer_pool_size ]]; then
      # The pool rounds to its chunk granularity, so it is reported by the
      # caller instead of compared here; everything else must take exactly.
      live=$(mariadb -N -B -e "SELECT @@${key}" 2>/dev/null || true)
      [[ $live =~ ^[0-9]+$ ]] && (( live == after )) || return 1
      opt_report "- Applied ${key}=${after} online"
    fi
  done
  return 0
}

# True when the live pool (LIVE_MB, read back after an online SET) is more
# than 2% below TARGET_MB, i.e. the server clamped the resize.  The pool
# rounds to its chunk granularity, so a small difference is not a failure,
# and an unreadable value is not treated as one either (the SET succeeded).
mariadb_pool_resize_short() {
  local live_mb=${1:-} target_mb=${2:-}
  [[ $live_mb =~ ^[0-9]+$ && $target_mb =~ ^[0-9]+$ ]] || return 1
  (( live_mb * 100 < target_mb * 98 ))
}

# Stop the request-serving tiers before a MariaDB restart, then bring them
# back in dependency order (PHP first, nginx last).  Only services that were
# active are touched; an OS-only or DB-only host is unaffected.
# Stop nginx, then every active PHP-FPM unit; WHY names the reason in the log
# (default: the MariaDB restart; --restart-all passes its own).
# shellcheck disable=SC2120
opt_pause_web_frontends() {
  local why=${1:-the MariaDB restart} unit
  OPT_WEB_PAUSED_NGINX=0
  OPT_WEB_PAUSED_PHP=()
  if systemctl is-active --quiet nginx 2>/dev/null; then
    if systemctl stop nginx 2>/dev/null; then
      OPT_WEB_PAUSED_NGINX=1
      info "Paused nginx before ${why}"
    else
      warn "Could not stop nginx before ${why}"
    fi
  fi
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    systemctl is-active --quiet "$unit" 2>/dev/null || continue
    if systemctl stop "$unit" 2>/dev/null; then
      OPT_WEB_PAUSED_PHP+=("$unit")
      info "Paused ${unit} before ${why}"
    else
      warn "Could not stop ${unit} before ${why}"
    fi
  done < <(list_active_php_units)
}

# Start the paused PHP-FPM units first, then nginx.
# shellcheck disable=SC2120
opt_resume_web_frontends() {
  local why=${1:-the MariaDB restart} unit rc=0
  for unit in "${OPT_WEB_PAUSED_PHP[@]}"; do
    if ! systemctl start "$unit" 2>/dev/null; then
      warn "Could not start ${unit} after ${why}"
      rc=1
    fi
  done
  if (( OPT_WEB_PAUSED_NGINX )); then
    if ! systemctl start nginx 2>/dev/null; then
      warn "Could not start nginx after ${why}"
      rc=1
    fi
  fi
  if (( ${#OPT_WEB_PAUSED_PHP[@]} > 0 || OPT_WEB_PAUSED_NGINX )); then
    info "Resumed web frontends after ${why}"
  fi
  OPT_WEB_PAUSED_NGINX=0
  OPT_WEB_PAUSED_PHP=()
  return "$rc"
}

optimize_mariadb() {
  local active=0 ver size_mb buffer open_cache aria_mb
  local threads max_conn io_read io_write cnf_dir cnf backlog cnf_before cnf_after
  local unit_changed=0 limit_before="" i live_slow="" live_err=""
  systemctl is-active --quiet mariadb 2>/dev/null && active=1
  ver=$(mariadb_server_version)
  opt_report "## MariaDB"
  opt_report "- Version: \`${ver:-unknown}\`; active: ${active}"
  opt_backup /etc/mysql mysql
  opt_backup /etc/systemd/system/mariadb.service.d mariadb-systemd

  local base_changed=0
  size_mb=$(service_mem_mb mariadb)
  if (( ${OPT_DB_SIZE_MB:-0} == 0 )); then
    OPT_DB_SIZE_MB=$(mariadb_data_size_mb)
    [[ ${OPT_DB_SIZE_MB:-} =~ ^[0-9]+$ ]] || OPT_DB_SIZE_MB=0
  fi
  if (( OPT_DB_SIZE_MB > 0 )); then
    local pct_mb=$(( OPT_DB_SIZE_MB + OPT_DB_SIZE_MB / 20 ))
    local raw_mb=$pct_mb pool_cap
    if [[ " ${OPT_DETECTED[*]} " != *" php:"* ]] \
       && [[ " ${OPT_DETECTED[*]} " != *" valkey "* && " ${OPT_DETECTED[*]} " != *" redis "* ]] \
       && [[ " ${OPT_DETECTED[*]} " != *" elastic "* ]]; then
      pool_cap=$(( $(mem_total_mb) * 80 / 100 ))
    else
      pool_cap=$(( $(mem_total_mb) / 2 ))
    fi
    (( pool_cap < 256 )) && pool_cap=256
    (( pct_mb > pool_cap )) && pct_mb=$pool_cap
    (( pct_mb < 128 )) && pct_mb=128
    # pct_mb is the capped target; raw_mb is data+5% before the cap.  The
    # report used to call the capped figure "data+5%", which on a 74 GB
    # database next to PHP read as 64388MB = 73892MB + 5%.
    local target="target ${pct_mb}MB (data+5% = ${raw_mb}MB, 128MB minimum, cap ${pool_cap}MB)"
    if (( ${OPT_MARIADB_KEPT_MB:-0} > 0 )); then
      opt_report "- Database data+index=${OPT_DB_SIZE_MB}MB; buffer pool=${size_mb}MB (kept existing pool; ${target})"
    else
      if (( ${OPT_MARIADB_LIVE_MB:-0} > size_mb )); then
        opt_report "- Buffer pool lowered from ${OPT_MARIADB_LIVE_MB}MB to ${size_mb}MB"
      fi
      opt_report "- Database data+index=${OPT_DB_SIZE_MB}MB; buffer pool=${size_mb}MB; ${target}"
    fi
  fi
  mariadb_compute_profile "$size_mb"
  buffer=$MARIADB_PROFILE_BUFFER
  open_cache=$MARIADB_PROFILE_OPEN_CACHE
  aria_mb=$MARIADB_PROFILE_ARIA_MB
  threads=$MARIADB_PROFILE_THREADS
  max_conn=$MARIADB_PROFILE_MAX_CONN
  io_read=$MARIADB_PROFILE_IO_READ
  io_write=$MARIADB_PROFILE_IO_WRITE
  backlog=$MARIADB_PROFILE_BACKLOG

  cnf_dir=/etc/mysql/mariadb.conf.d
  mkdir -p "$cnf_dir"
  # Enabling slow/error logging under /var/www/logs needs the AppArmor override
  # on Ubuntu 24.04/26.04 as well; the installer already writes it, but an old
  # host tuned in place may not have it.
  configure_mariadb_apparmor

  # An existing server may still carry the package's default 1024-fd limit.
  # Keep the same systemd drop-in the installer uses.
  limit_before=$(systemctl show -p LimitNOFILE --value mariadb 2>/dev/null || true)
  if mariadb_write_systemd_limits; then
    systemctl daemon-reload || true
    unit_changed=1
    opt_report "- systemd LimitNOFILE=1048576"
  fi
  cnf="${cnf_dir}/99-setup-optimize.cnf"

  cnf_before=""
  [[ -f $cnf ]] && cnf_before=$(file_md5 "$cnf")
  local cnf_old=""
  if [[ -f $cnf ]]; then
    cnf_old=$(tmp_file)
    cp -a "$cnf" "$cnf_old"
  fi

  write_mariadb_tuning_dropin "$size_mb" "$max_conn" "$cnf"
  cnf_after=$(file_md5 "$cnf")
  opt_report "- Wrote \`${cnf}\` (buffer=${buffer}, max_connections=${max_conn}, back_log=${backlog})"
  if (( ${MARIADB_PROFILE_PERSISTENT_APPS:-0} > 0 )); then
    opt_report "- max_connections allows one persistent connection per PHP worker for ${MARIADB_PROFILE_PERSISTENT_APPS} application(s) plus a transient one"
  fi
  opt_report "- Slow/error logging: /var/www/logs/mariadb/slow.log and error.log"
  opt_report "- innodb_io_capacity=${io_read}/${io_write}, thread_pool_size=${threads}"
  # One owner for the performance values: remove the installer-managed block
  # from 50-server.cnf now that the 99- drop-in is authoritative.
  mariadb_strip_install_block "$size_mb" "$max_conn" \
    || warn "Could not remove old performance keys from 50-server.cnf"
  # Converge the base block too (charset, skip_name_resolve, local_infile=0,
  # secure_file_priv): a host adopted by --optimize never had it.  The
  # existing bind-address is kept.
  local base_cnf=/etc/mysql/mariadb.conf.d/50-server.cnf base_before="" base_bind=""
  if [[ -f $base_cnf ]]; then
    base_before=$(file_md5 "$base_cnf")
    # Only an active bind-address line is carried into the managed block; a
    # commented-out line means the operator listens on every interface and
    # --optimize leaves that alone (the installer validates its own bind=).
    base_bind=$(sed -nE 's/^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*//p' "$base_cnf" | tail -n1 | tr -d '[:space:]')
    mariadb_write_base_block "$base_cnf" "$base_bind" || true
    if [[ $base_before != "$(file_md5 "$base_cnf")" ]]; then
      base_changed=1
      opt_report "- Base settings converged in 50-server.cnf (charset, skip_name_resolve, local_infile=0, bind-address=${base_bind:-unchanged}); restart required"
    fi
  fi

  # A running server can resize the buffer pool online, both ways (growth
  # with the data, and the shrink to data+5%).  Restarting a busy
  # database just to resize it by a few percent empties every application cache
  # at once; on XenForo that produced a thousand-request lock convoy on the
  # same registry row.  Only fall back to a restart when the pool is not the
  # only change (or the resize fails).
  local online_mb=""
  if [[ -n $cnf_old ]] && (( active )) && [[ $cnf_before != "$cnf_after" ]] \
     && (( base_changed == 0 )) && cnf_only_pool_changed "$cnf_old" "$cnf"; then
    if mariadb -e "SET GLOBAL innodb_buffer_pool_size = $(( size_mb * 1024 * 1024 ))" 2>/dev/null \
       && mariadb_apply_online_keys "$cnf_old" "$cnf"; then
      online_mb=$(mariadb -N -B -e 'SELECT @@innodb_buffer_pool_size' 2>/dev/null \
        | awk '{printf "%d", $1 / 1024 / 1024}' || true)
      # MariaDB 11.8 accepts a SET above @@innodb_buffer_pool_size_max with
      # exit status 0 and silently clamps it (warning 1292), so the statement
      # succeeding proves nothing: compare the pool that is actually live.
      if mariadb_pool_resize_short "$online_mb" "$size_mb"; then
        opt_report "- Online buffer-pool resize was clamped at ${online_mb}MB (target ${size_mb}MB; the running server cannot grow past its startup maximum); falling back to a restart"
      else
        opt_report "- Applied buffer pool online: ${online_mb:-$size_mb}MB (no restart)"
        if (( unit_changed == 0 )); then
          return 0
        fi
        if [[ $limit_before =~ ^[0-9]+$ ]] && (( limit_before >= 65536 )); then
          opt_report "- Restart: deferred (LimitNOFILE=${limit_before} is already sufficient; the drop-in applies on the next restart)"
          return 0
        fi
        # The fd drop-in still needs a restart; fall through to apply it.
      fi
    else
      opt_report "- Online resize of the changed keys failed; falling back to a restart"
    fi
  fi
  if [[ -n $cnf_before && $cnf_before == "$cnf_after" ]] && (( base_changed == 0 )); then
    if (( unit_changed == 0 )); then
      opt_report "- Restart: skipped (configuration already optimized)"
      return 0
    fi
    # Only the systemd fd drop-in changed.  Restarting a live database cuts
    # in-flight queries (a site can cache blank error pages during the gap),
    # and the current limit already exceeds what max_connections needs, so
    # let the drop-in apply on the next planned restart.
    if [[ $limit_before =~ ^[0-9]+$ ]] && (( limit_before >= 65536 )); then
      opt_report "- Restart: deferred (LimitNOFILE=${limit_before} is already sufficient; the drop-in applies on the next restart)"
      return 0
    fi
  fi

  if command -v mariadbd >/dev/null 2>&1; then
    if ! mariadbd --defaults-file=/etc/mysql/my.cnf --help --verbose >/dev/null 2>&1; then
      opt_report "- **FAILED** MariaDB rejected the generated configuration; rolled back"
      opt_restore /etc/mysql mysql
      opt_restore /etc/systemd/system/mariadb.service.d mariadb-systemd
      systemctl daemon-reload || true
      return 1
    fi
  fi

  if (( active )); then
    # Apply any service-unit drop-in before restarting, then stop the request
    # tiers.  A busy PHP pool reconnecting while InnoDB preloads can otherwise
    # overwhelm a freshly started database.
    systemctl daemon-reload || true
    opt_pause_web_frontends
    if (( OPT_WEB_PAUSED_NGINX || ${#OPT_WEB_PAUSED_PHP[@]} > 0 )); then
      opt_report "- Paused web frontends before the MariaDB restart (PHP, then nginx)"
    fi

    # A large buffer pool may need to preload at startup; the probe allows up
    # to five minutes before the restart counts as failed.
    if opt_restart_service mariadb /etc/mysql mysql mariadb-systemd mariadb_restart_probe; then
      live_slow=$(mariadb -N -B -e 'SELECT @@slow_query_log' 2>/dev/null || true)
      live_err=$(mariadb -N -B -e 'SELECT @@log_error' 2>/dev/null || true)
      opt_report "- Live slow_query_log=${live_slow:-unknown}, log_error=${live_err:-unknown}"
      if [[ $live_slow != 1 ]]; then
        opt_report "- **WARNING**: slow_query_log is ${live_slow:-unknown} after restart; check AppArmor/log permissions"
      fi
      if ! opt_resume_web_frontends; then
        opt_report "- Web frontends: **FAILED** to resume; check nginx/PHP-FPM"
        return 1
      fi
      opt_report "- Web frontends resumed after the MariaDB restart"
    else
      mariadb_wait_ready 30 || true
      opt_resume_web_frontends || true
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  return 0
}

# Live cache working set in MB, read from the running Valkey/Redis.  Used by
# the planner so maxmemory can never be sized below data that is already
# stored (or its 20% headroom).  Returns non-zero when no server is reachable.
# Run a command against the local Valkey/Redis, preferring the Unix socket.
# Returns non-zero when no client is installed or the server is unreachable.
valkey_live_cli() {
  local cli="" sock="" conf_sock vcli
  # Our build's valkey-cli by absolute path (a package copy on PATH only
  # while the migration has not replaced the package server yet).
  vcli=$(opt_valkey_cli)
  [[ -x $vcli ]] || vcli=""
  # An operator's custom unixsocket (kept by valkey_apply_config) first, then
  # the default paths, then TCP.
  conf_sock=$(valkey_conf_get /etc/valkey/valkey.conf unixsocket 2>/dev/null || true)
  if [[ -n $conf_sock && -S $conf_sock && -n $vcli ]]; then
    cli=$vcli; sock=$conf_sock
  elif conf_sock=$(valkey_conf_get /etc/redis/redis.conf unixsocket 2>/dev/null || true) \
       && [[ -n $conf_sock && -S $conf_sock ]] && command -v redis-cli >/dev/null 2>&1; then
    cli=redis-cli; sock=$conf_sock
  elif [[ -S /run/valkey/valkey.sock && -n $vcli ]]; then
    cli=$vcli; sock=/run/valkey/valkey.sock
  elif [[ -S /run/redis/redis.sock ]] && command -v redis-cli >/dev/null 2>&1; then
    cli=redis-cli; sock=/run/redis/redis.sock
  elif [[ -n $vcli ]]; then
    cli=$vcli
  elif command -v redis-cli >/dev/null 2>&1; then
    cli=redis-cli
  else
    return 1
  fi
  if [[ -n $sock ]]; then
    "$cli" -s "$sock" "$@" 2>/dev/null
  else
    "$cli" "$@" 2>/dev/null
  fi
}

valkey_live_used_mb() {
  local used
  used=$(valkey_live_cli info memory || true)
  used=$(printf '%s\n' "$used" \
    | awk -F: '/^used_memory:/{gsub(/\r/, "", $2); print int($2 / 1048576); exit}')
  [[ $used =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$used"
}

# used_memory_peak in MB since the cache started; fails when it does not
# answer.
valkey_live_peak_mb() {
  local peak
  peak=$(valkey_live_cli info memory || true)
  peak=$(printf '%s\n' "$peak" \
    | awk -F: '/^used_memory_peak:/{gsub(/\r/, "", $2); print int($2 / 1048576); exit}')
  [[ $peak =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$peak"
}

# Seconds since the running cache started; fails when it does not answer.
valkey_live_uptime_s() {
  local up
  up=$(valkey_live_cli info server || true)
  up=$(printf '%s\n' "$up" \
    | awk -F: '/^uptime_in_seconds:/{gsub(/\r/, "", $2); print int($2); exit}')
  [[ $up =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$up"
}

# The managed cache configuration: Valkey's, else a pre-existing Redis's.
valkey_active_conf() {
  if [[ -f /etc/valkey/valkey.conf ]]; then
    printf '/etc/valkey/valkey.conf'
  elif [[ -f /etc/redis/redis.conf ]]; then
    printf '/etc/redis/redis.conf'
  fi
}

# A maxmemory value as written in valkey.conf ("512mb", "1gb", plain bytes)
# in MB; 0 for anything else, including "0" (no limit).
valkey_size_to_mb() {
  local val=${1,,} num
  num=${val%%[a-z]*}
  [[ $num =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  case ${val#"$num"} in
    # Valkey/Redis units: gb/mb/kb are binary, g/m/k decimal (1g = 10^9).
    gb) printf "%s" $(( num * 1024 )) ;;
    g)  printf "%s" $(( num * 1000000000 / 1048576 )) ;;
    mb) printf "%s" "$num" ;;
    m)  printf "%s" $(( num * 1000000 / 1048576 )) ;;
    kb) printf "%s" $(( num / 1024 )) ;;
    k)  printf "%s" $(( num * 1000 / 1048576 )) ;;
    "")   printf '%s' $(( num / 1048576 )) ;;
    *)    printf '0' ;;
  esac
}

# maxmemory currently in force, in MB: the running server's value, else the
# configuration file's.  0 means "no limit" or "unknown"; both tell the
# planner there is no current size worth keeping.
valkey_current_maxmemory_mb() {
  local out bytes conf
  # CONFIG GET prints the name and the value on separate lines.
  out=$(valkey_live_cli config get maxmemory || true)
  bytes=${out##*$'\n'}
  if [[ $bytes =~ ^[0-9]+$ ]]; then
    printf '%s' $(( bytes / 1048576 ))
    return 0
  fi
  conf=$(valkey_active_conf)
  if [[ -n $conf ]]; then
    valkey_size_to_mb "$(valkey_conf_get "$conf" maxmemory)"
  else
    printf '0'
  fi
}

# 1 when the configured maxmemory-policy can evict any key at the limit
# (allkeys-*), 0 otherwise.  volatile-* evicts only keys with a TTL, so
# sessions or queues stored without one behave as under noeviction: their
# used_memory is real data and a maxmemory below it fails writes.  A config
# without the directive gets allkeys-lru from the shared writer, so it counts
# as evicting.  A volatile-* cache that has already evicted keys since it
# started (INFO stats evicted_keys > 0) is full of TTL keys, not of data it
# cannot drop: it fills any size like an LRU cache, so it counts as evicting
# too.  Otherwise each run would read used == maxmemory and raise it by 20%.
valkey_policy_evicts() {
  local conf policy="" evicted
  conf=$(valkey_active_conf)
  if [[ -n $conf ]]; then
    policy=$(valkey_conf_get "$conf" maxmemory-policy)
  fi
  if [[ -z $policy || $policy == allkeys-* ]]; then
    printf '1'
  elif [[ $policy == volatile-* ]]; then
    evicted=$(valkey_live_cli info stats 2>/dev/null \
      | awk -F: '/^evicted_keys:/{gsub(/\r/, "", $2); print int($2); exit}' || true)
    if [[ $evicted =~ ^[0-9]+$ ]] && (( evicted > 0 )); then
      printf '1'
    else
      printf '0'
    fi
  else
    printf '0'
  fi
}

# The one decision about an automatically sized maxmemory, shared by the
# memory plan (which feeds the install path, --optimize and the dry run), so
# all of them print and write the same number.  Arguments, all in MB:
#   PLANNED   the least the plan writes: the 128 MB minimum for a measured
#             cache, the size in force for a stopped or recently restarted
#             one, the RAM floor with nothing to measure, or a scaled share
#   USED      the cache's data: max(used_memory, used_memory_peak)
#   CURRENT   maxmemory in force now (0 = none/unknown)
#   HARD_CAP  the most the host can give the cache
#   EVICTS    1 when the policy evicts any key (allkeys-*)
#   BAND      0 turns the keep band off (the second pass on a scaled-down
#             share must not hand back what the split took); default 1
# The target is data+20% (needed), never below PLANNED.  Prints "MB REASON":
#   full    an evicting cache whose data reaches 83..102% of CURRENT.  Such a
#           cache fills any size it is given, so its used_memory says how big
#           it is, not how big it needs to be: CURRENT is kept, never raised
#           (512 -> 614 -> 736 ... every run) and never cut;
#           `--valkey ram=` grows it.  Below PLANNED it takes PLANNED.
#   plan    PLANNED already covers data+20%
#   raised  data+20% above PLANNED (a non-evicting cache follows its data
#           both ways, a full one included: its keys cannot be evicted, so
#           at the limit writes fail)
#   capped  data+20% beyond HARD_CAP
# A CURRENT within [max(PLANNED, data+10%), target*1.1] is kept with the
# plan/raised reason, so drift either way does not rewrite maxmemory on
# every run: data may grow until only 10% headroom is left.
valkey_guard_maxmemory_mb() {
  local planned=$1 used=${2:-0} current=${3:-0} hard_cap=${4:-0} evicts=${5:-1} band=${6:-1}
  local needed=$(( used * 120 / 100 )) want reason lo
  if (( evicts && current > 0 && used * 100 >= current * 83 \
        && used * 100 <= current * 102 )); then
    if (( current > hard_cap )); then
      printf '%s capped' "$hard_cap"
    elif (( current < planned )); then
      printf '%s plan' "$planned"
    else
      printf '%s full' "$current"
    fi
    return 0
  fi
  want=$planned reason=plan
  (( needed > want )) && want=$needed reason=raised
  if (( want > hard_cap )); then
    printf '%s capped' "$hard_cap"
    return 0
  fi
  lo=$(( used * 110 / 100 ))
  (( lo < planned )) && lo=$planned
  if (( band && current > 0 && current <= hard_cap \
        && current >= lo && current <= want + want / 10 )); then
    printf '%s %s' "$current" "$reason"
    return 0
  fi
  printf '%s %s' "$want" "$reason"
}

# Fallback working set when the cache is stopped: the RDB snapshot size.
# RAM-proportional minimum for the cache's maxmemory: 1/64 of RAM, 128 MB to
# 1 GB.  Shared by the memory plan (install and --optimize) and the dry run.
valkey_floor_mb() {
  local ram_mb=${1:-0} floor
  [[ $ram_mb =~ ^[0-9]+$ ]] || ram_mb=0
  floor=$(( ram_mb / 64 ))
  (( floor < 128 )) && floor=128
  (( floor > 1024 )) && floor=1024
  printf '%s' "$floor"
}

# InnoDB buffer-pool floor for a database with little or no measured data:
# RAM/16 clamped to 256 MB..4 GB (1 GB on a 16 GB host, 1.7 GB on 27 GB).
# The planner still trims it when the budget is short.
mariadb_floor_mb() {
  local ram_mb=${1:-0} floor
  [[ $ram_mb =~ ^[0-9]+$ ]] || ram_mb=0
  floor=$(( ram_mb / 16 ))
  (( floor < 256 )) && floor=256
  (( floor > 4096 )) && floor=4096
  printf '%s' "$floor"
}

valkey_data_size_mb() {
  local file size
  for file in /var/lib/valkey/dump.rdb /var/lib/redis/dump.rdb; do
    [[ -f $file ]] || continue
    size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    [[ $size =~ ^[0-9]+$ ]] || size=0
    printf '%s' $(( size / 1024 / 1024 ))
    return 0
  done
  printf '0'
  return 0
}

restart_php_workers_for_group() {
  local group=$1 unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    if ! systemctl restart "$unit" 2>/dev/null; then
      warn "Could not restart ${unit} to inherit the ${group} group"
    fi
  done < <(list_active_php_units)
}

# The compiled Valkey (lib/valkey-build.sh) is brought to its build after
# the tuning, only for our Valkey (never an adopted Redis, which is tuned as
# Redis) and only when the tune succeeded: rebuild when `check` finds it
# stale, swap it in (a restart only when a new build was staged), BOLT.
# A failed build keeps the running build serving and fails the run, like
# nginx and PHP.
optimize_valkey() {
  local rc=0
  optimize_valkey_tune "$@" || rc=$?
  if [[ ${1:-valkey} == valkey ]] && (( rc == 0 )) && ! valkey_build_ensure full optimize opt_report; then
    warn "Valkey: the build failed; the running Valkey build keeps serving (see the report for the log)"
    rc=1
  fi
  return "$rc"
}

optimize_valkey_tune() {
  local kind=${1:-valkey}
  local label=Valkey conf=/etc/valkey/valkey.conf conf_dir=/etc/valkey
  # Our build's client by absolute path (R2.1); valkey-cli on PATH may be a
  # leftover package copy or missing (/usr/local/bin is not in every PATH).
  local unit=valkey-server cli
  cli=$(opt_valkey_cli)
  if [[ $kind == redis ]]; then
    label=Redis conf=/etc/redis/redis.conf conf_dir=/etc/redis
    unit=redis-server cli=redis-cli
  fi
  local active=0 max_mb policy backlog io_threads i
  local conf_before conf_after dropin unit_changed=0
  local online_ok=0 live_io="" live_backlog="" k v
  local socket_path group socket_before perm_before perm_after socket_changed=0 group_changed=0
  [[ -f $conf ]] || return 0
  systemctl is-active --quiet "$unit" 2>/dev/null && active=1
  opt_report "## ${label}"
  opt_report "- Active: ${active}; config: \`${conf}\`"
  opt_backup "$conf_dir" "$kind"
  # Reset the shared change tracker so a previous service's restart does not
  # force an unnecessary cache restart on an otherwise unchanged run.
  tune_reset_changes
  max_mb=$(service_mem_mb "$kind")
  backlog=$(effective_backlog)
  # max_mb is final: the memory plan already applied the live-data guard
  # (valkey_guard_maxmemory_mb), so the dry run, the plan summary and this
  # writer cannot disagree.  Only explain the decision here.
  local used_mb=${OPT_VALKEY_LIVE_MB:-0}
  case ${OPT_VALKEY_GUARD:-} in
    full)
      opt_report "- Cache is full (in use=${used_mb}mb of maxmemory=${max_mb}mb, evicting policy): keeping maxmemory=${max_mb}mb; \`--valkey ram=<size>\` grows it"
      ;;
    capped)
      opt_report "- maxmemory capped at ${max_mb}mb (live data needs $(( used_mb * 120 / 100 ))mb; add RAM or reduce the working set)"
      ;;
    raised)
      opt_report "- maxmemory raised to ${max_mb}mb (in use=${used_mb}mb; refusing to evict live data)"
      ;;
    shrunk)
      opt_report "- maxmemory lowered from ${OPT_VALKEY_PREV_MB:-0}mb to ${max_mb}mb (data=${used_mb}mb, the larger of used_memory and its peak; target data+20%, 128 MB minimum, within the memory plan)"
      ;;
    young)
      opt_report "- maxmemory kept at ${max_mb}mb (in use=${used_mb}mb): the cache started less than a day ago, so its peak has not seen a full day; a run after a day sizes it to data+20% (128 MB minimum)"
      ;;
    unmeasured)
      opt_report "- maxmemory kept at ${max_mb}mb: the cache could not be measured (stopped or not answering); a run with it up sizes it to data+20% (128 MB minimum)"
      ;;
    explicit)
      # An operator size is written verbatim; say so when it is below the
      # data already stored, because the eviction policy will trim the cache.
      if (( active )); then
        used_mb=$(valkey_live_used_mb 2>/dev/null || echo 0)
        [[ $used_mb =~ ^[0-9]+$ ]] || used_mb=0
        if (( used_mb > max_mb )); then
          opt_report "- maxmemory=${max_mb}mb is the explicit \`--valkey ram=\` size (in use=${used_mb}mb; the eviction policy trims the cache to fit)"
        fi
      fi
      ;;
    *)
      if (( used_mb > 0 )); then
        opt_report "- Live working set=${used_mb}mb; maxmemory=${max_mb}mb (data+20%, 128 MB minimum; a size up to 10% above that is kept)"
      fi
      ;;
  esac
  policy=$(valkey_conf_get "$conf" maxmemory-policy)
  [[ -n $policy ]] || policy=allkeys-lru
  # Preserve an explicit install-time io-threads value (the installer defaults
  # to 1); forcing 1 here would silently undo `--valkey io_threads=N`.
  io_threads=$(valkey_conf_get "$conf" io-threads)
  io_threads=$(valkey_clamp_io_threads "$io_threads")
  conf_before=$(file_md5 "$conf")

  # Local PHP should use the Unix socket: it avoids ephemeral-port/TIME_WAIT
  # pressure and was measurably faster for small cache commands.  This is
  # startup-only, so it is applied here and the cache is restarted below.
  socket_path="/run/${kind}/${kind}.sock"
  group=$kind
  socket_before=$(valkey_conf_get "$conf" unixsocket)
  perm_before=$(valkey_conf_get "$conf" unixsocketperm)
  # Keep an operator's existing custom socket path; only add the default when
  # the service has no socket configured.
  if [[ -n $socket_before && $socket_before == /* ]]; then
    socket_path=$socket_before
  fi
  # Same writer as the installer: base directives (persistence off, local
  # bind, log path, socket) plus the tuning block.
  valkey_apply_config "$conf" "$kind" "$max_mb" "$policy" "$io_threads" "$socket_path" adopt
  if grep -qx '# setup.sh kept operator persistence' "$conf"; then
    opt_report "- Kept the existing persistence settings (\`appendonly yes\`): this ${kind} holds data that must survive a restart"
  fi
  if grep -qx '# setup.sh kept operator bind' "$conf"; then
    opt_report "- Kept the existing \`bind\` line: this ${kind} serves clients on a non-loopback address"
  fi
  perm_after=$(valkey_conf_get "$conf" unixsocketperm)
  if [[ $socket_before != "$socket_path" || $perm_before != "$perm_after" || $perm_after != 770 ]]; then
    socket_changed=1
  fi
  # A configured socket that is not live (or still has the old permissions)
  # needs a restart.
  if [[ -S $socket_path ]]; then
    [[ $(stat -c '%a' "$socket_path" 2>/dev/null || true) == 770 ]] || socket_changed=1
  else
    socket_changed=1
  fi
  valkey_ensure_www_group "$group" && group_changed=1
  opt_report "- Local socket: \`${socket_path}\` (unixsocketperm 770)"
  opt_report "- Application config (not edited automatically):"
  opt_report "  XenForo: \`\$config['cache']['config']['host'] = '${socket_path}'; \$config['cache']['config']['port'] = 0;\`"
  opt_report "  XenForo note: with php-redis and this local socket the XF registry/session cache measured +7-9% authenticated throughput (1.21.23 audit); without php-redis the add-on's pure-PHP Credis client measured slower than local MariaDB (1.20.x audit). Keep it when \`redis\` is in \`php -m\`, disable it for Credis, and use it on multi-node or remote-DB setups."
  opt_report "  XenForo widgets: disabling Members online, Trending content and Featured content on the forum list measured +39% authenticated throughput and 13% smaller HTML; disable them in ACP > Widgets if they are not required."
  opt_report "  WordPress: \`define('WP_REDIS_PATH', '${socket_path}');\`"
  opt_report "  Laravel/phpredis: \`'host' => '${socket_path}', 'port' => 0\`"
  opt_report "  Test: \`${cli} -s ${socket_path} ping\`"

  conf_after=$(file_md5 "$conf")
  opt_report "- maxmemory=${max_mb}mb, policy=${policy}, maxclients=$(valkey_maxclients), tcp-backlog=${backlog}"

  # A large maxclients is unusable if systemd still caps the unit at 1024
  # fds.  Same drop-in as the installer (name, comment and ReadWritePaths
  # included) so a fresh install and --optimize converge.
  # Our valkey-server.service (lib/valkey-build.sh) already carries
  # LimitNOFILE=524288, LimitCORE=0 and the log tree in ReadWritePaths (with
  # the '-' prefix a missing directory needs), so the drop-in is written
  # only for an adopted redis-server package unit.
  dropin="/etc/systemd/system/${unit}.service.d/limits.conf"
  opt_backup "$(dirname "$dropin")" "${kind}-systemd"
  if { [[ $kind == redis ]] || ! valkey_is_ours; } && valkey_write_systemd_limits "$unit" "$kind"; then
    unit_changed=1
    systemctl daemon-reload || true
    opt_report "- systemd limits: LimitNOFILE=524288, ReadWritePaths=${LOG_ROOT}/${kind}"
  fi

  if (( active )) && (( TUNE_DIRTY == 0 )) \
     && [[ $conf_before == "$conf_after" ]] && (( unit_changed == 0 )) \
     && (( socket_changed == 0 )); then
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group"
    fi
    opt_report "- Restart: skipped (configuration already optimized)"
    return 0
  fi

  # Apply the runtime-settable values to the live process.  A restart throws
  # away the whole cache when persistence is disabled (the installer writes
  # `save ""` and `appendonly no`), so a tuning run must not restart a busy
  # cache just to add timeout/hz/lazyfree defaults.
  # The running server listens where its current config says.  An adopted
  # config may keep an operator bind/port, so the CLI default (127.0.0.1:6379)
  # is not always this server; the installer pings the socket for the same
  # reason.
  local -a live_ep=()
  [[ -n $socket_before && -S $socket_before ]] && live_ep=(-s "$socket_before")
  if (( active )); then
    online_ok=1
    while read -r k v; do
      [[ -n $k ]] || continue
      if ! "$cli" "${live_ep[@]}" CONFIG SET "$k" "$v" >/dev/null 2>&1; then
        online_ok=0
        opt_report "- Online \`CONFIG SET ${k} ${v}\` failed; a restart is required"
        break
      fi
    done < <(valkey_runtime_settings "$max_mb" "$policy" "$io_threads")
    # io-threads is fixed at startup.  A systemd fd drop-in also needs a new
    # process before maxclients can exceed the old limit.
    live_io=$("$cli" "${live_ep[@]}" CONFIG GET io-threads 2>/dev/null | tail -n1 || true)
    if [[ $live_io =~ ^[0-9]+$ ]] && [[ $live_io != "$io_threads" ]]; then
      online_ok=0
      opt_report "- io-threads=${io_threads} differs from live ${live_io}; a restart is required"
    fi
    if (( unit_changed )); then
      online_ok=0
    fi
    if (( socket_changed )); then
      online_ok=0
      opt_report "- Unix socket change applies on restart (cache may be cold)"
    fi
  fi
  if (( active )) && (( online_ok )); then
    live_backlog=$("$cli" "${live_ep[@]}" CONFIG GET tcp-backlog 2>/dev/null | tail -n1 || true)
    if [[ $live_backlog =~ ^[0-9]+$ ]] && [[ $live_backlog != "$backlog" ]]; then
      opt_report "- tcp-backlog=${backlog} applies at startup (live ${live_backlog}); restart deferred"
    fi
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group"
    fi
    opt_report "- Applied online via CONFIG SET (no restart; cache retained)"
    return 0
  fi

  if (( active )); then
    opt_restart_service "$unit" "$conf_dir" "$kind" "${kind}-systemd" valkey_restart_probe "$cli" "$socket_path" \
      || return 1
    # A socket path change does not alter the supplementary groups the PHP
    # workers already have.  Restarting PHP just because the cache moved to
    # a Unix socket briefly removes /run/php/php-fpm.sock and makes nginx
    # return 502s; only a real group change needs it.
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group"
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group (socket applies at next start)"
    fi
  fi
  return 0
}

# Elasticsearch reads every *.options file in jvm.options.d in lexical order,
# and the JVM keeps the last -Xms/-Xmx.  Older setup.sh releases wrote the heap
# to jvm.options during install and to zz-setup-optimize.options during
# --optimize, leaving two conflicting heap pairs behind (the 31 GB install
# value and the optimized one).  Always own one file and remove the legacy one
# when it is recognisably the file this script generated.
readonly ES_JVM_OPTIONS="/etc/elasticsearch/jvm.options.d/zz-setup-optimize.options"

es_jvm_options_is_managed() {
  local file=$1 line count=0 xs=0 xx=0 other=0
  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    count=$(( count + 1 ))
    case $line in
      -Xms*|-Xmx*)
        [[ $line == -Xms* ]] && xs=$(( xs + 1 )) || xx=$(( xx + 1 ))
        ;;
      -XX:+UseG1GC|-XX:MaxGCPauseMillis=200|-XX:+HeapDumpOnOutOfMemoryError|-Dlog4j2.formatMsgNoLookups=true) ;;
      *) other=$(( other + 1 )) ;;
    esac
  done < "$file"
  (( other == 0 && xs == 1 && xx == 1 && count >= 4 && count <= 6 ))
}

write_es_jvm_options() {
  local heap_mb=$1 dir=${2:-/etc/elasticsearch/jvm.options.d}
  local jvm="${dir}/zz-setup-optimize.options"
  local legacy="${dir}/jvm.options"
  cat > "$jvm" <<EOF
-Xms${heap_mb}m
-Xmx${heap_mb}m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+HeapDumpOnOutOfMemoryError
-Dlog4j2.formatMsgNoLookups=true
EOF
  chmod 644 "$jvm"
  chown root:elasticsearch "$jvm" 2>/dev/null || true
  # Never delete or move an operator's own jvm.options.  Only the recognisable
  # file this script generated is moved to /tmp.  A minimal operator heap file
  # is preserved; zz-setup-optimize.options sorts last and owns the effective
  # heap, and the override is reported explicitly.
  if [[ -f $legacy ]]; then
    if es_jvm_options_is_managed "$legacy"; then
      if preserve_to_tmp "$legacy" >/dev/null; then
        info "Moved legacy managed ${legacy} to /tmp; ${jvm} owns the heap"
        if (( ${OPTIMIZE:-0} )); then
          opt_report "- Moved legacy managed \`${legacy}\` to /tmp; \`${jvm}\` owns the heap"
        fi
      else
        warn "Could not move ${legacy}; ${jvm} still takes precedence"
        if (( ${OPTIMIZE:-0} )); then
          opt_report "- **WARNING**: could not move \`${legacy}\`; \`${jvm}\` still takes precedence"
        fi
      fi
    elif grep -qE '^[[:space:]]*-Xm[sx]' "$legacy"; then
      warn "Operator ${legacy} also sets -Xms/-Xmx; ${jvm} takes precedence"
      if (( ${OPTIMIZE:-0} )); then
        opt_report "- Warning: operator \`${legacy}\` also sets -Xms/-Xmx; \`${jvm}\` takes precedence"
      fi
    fi
  fi
  return 0
}

elasticsearch_single_node_replica_issue() {
  local json=$1 nodes status unassigned primary
  nodes=$(es_json_num "$json" number_of_nodes)
  status=$(es_json_str "$json" status)
  unassigned=$(es_json_num "$json" unassigned_shards)
  primary=$(es_json_num "$json" unassigned_primary_shards)
  [[ $nodes =~ ^[0-9]+$ && $nodes -eq 1 ]] || return 1
  [[ $status == yellow ]] || return 1
  [[ $unassigned =~ ^[0-9]+$ && $unassigned -gt 0 ]] || return 1
  [[ $primary =~ ^[0-9]+$ && $primary -eq 0 ]] || return 1
  return 0
}

elasticsearch_ensure_single_node_template() {
  local resp es_url
  es_url=$(elasticsearch_http_url)
  resp=$(curl -fsS --max-time 15 -X PUT -H 'Content-Type: application/json' \
    "${es_url}/_index_template/setup-single-node-zero-replicas" \
    -d '{"index_patterns":["*"],"priority":1,"template":{"settings":{"number_of_replicas":0}}}' \
    2>/dev/null) || resp=""
  if [[ $resp == *'"acknowledged":true'* ]]; then
    opt_report "- Single-node template ensured (priority 1, replicas=0)"
    return 0
  fi
  opt_report "- Single-node template install failed"
  return 1
}

# Wait until a freshly restarted node has assigned its primaries.  The
# cluster can be red for a few seconds while shards recover; deciding before
# then skips the single-node replica fix.
elasticsearch_wait_primaries() {
  local i health status primary es_url code
  es_url=$(elasticsearch_http_url)
  # Return quickly when the endpoint is unreachable from this host (a remote
  # bind + restrictive firewall).  A 503 is still a reachable node and should
  # be waited on.
  code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$es_url" 2>/dev/null || true)
  [[ $code == 000 || -z $code ]] && return 1
  for i in {1..120}; do
    health=$(curl -sS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || true
    status=$(es_json_str "$health" status)
    primary=$(es_json_num "$health" unassigned_primary_shards)
    [[ $status == green ]] && return 0
    if [[ $status == yellow && $primary =~ ^[0-9]+$ && $primary -eq 0 ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# A single-node cluster cannot assign replicas.  Yellow health with only
# unassigned replicas is expected there; set replicas=0 on existing indices
# and keep a low-priority template for future indices.
# Index names with an unassigned primary, from `_cat/shards?h=index,prirep,state`
# on stdin, one per line, sorted and unique.
elasticsearch_unassigned_primary_indices() {
  awk '$2 == "p" && $3 == "UNASSIGNED" { print $1 }' | sort -u
}

elasticsearch_fix_single_node_replicas() {
  local health status nodes unassigned primary resp i es_url
  command -v curl >/dev/null 2>&1 || return 0
  es_url=$(elasticsearch_http_url)
  elasticsearch_wait_primaries || true
  health=$(curl -fsS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || return 0
  nodes=$(es_json_num "$health" number_of_nodes)
  status=$(es_json_str "$health" status)
  unassigned=$(printf '%s' "$health" | sed -n 's/.*"unassigned_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  primary=$(printf '%s' "$health" | sed -n 's/.*"unassigned_primary_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)

  if [[ ! $nodes =~ ^[0-9]+$ || $nodes -ne 1 ]]; then
    [[ -n $status ]] && opt_report "- Cluster health: ${status} (multi-node; replicas left unchanged)"
    return 0
  fi
  if [[ $status == green ]]; then
    opt_report "- Cluster health: green"
    elasticsearch_ensure_single_node_template || true
    return 0
  fi
  if ! elasticsearch_single_node_replica_issue "$health"; then
    # Name the indices whose primary is unassigned: "red ... left unchanged"
    # alone hid that a live host's red came from two 2024 system data
    # streams with no copy left, while every application index was usable.
    local -a lost
    mapfile -t lost < <(curl -fsS --max-time 5 "${es_url}/_cat/shards?h=index,prirep,state" 2>/dev/null \
      | elasticsearch_unassigned_primary_indices)
    if (( ${#lost[@]} > 0 )); then
      local shown
      shown=$(printf '%s, ' "${lost[@]:0:5}"); shown=${shown%, }
      (( ${#lost[@]} > 5 )) && shown+=" (+$(( ${#lost[@]} - 5 )) more)"
      opt_report "- Cluster health: ${status:-unknown}; unassigned primary shard(s) in: ${shown}.\`GET _cluster/allocation/explain\` gives the cause; an index with no copy left must be restored from a snapshot or deleted (left unchanged)"
    else
      opt_report "- Cluster health: ${status:-unknown} (not a single-node replica issue; left unchanged)"
    fi
    return 0
  fi

  resp=$(curl -fsS --max-time 30 -X PUT -H 'Content-Type: application/json' \
    "${es_url}/_all/_settings" \
    -d '{"index":{"number_of_replicas":0}}' 2>/dev/null) || resp=""
  if [[ $resp != *'"acknowledged":true'* ]]; then
    opt_report "- Single-node cluster: **FAILED** to set number_of_replicas=0"
    return 1
  fi
  opt_report "- Single-node cluster: set number_of_replicas=0 on existing indices"
  elasticsearch_ensure_single_node_template || true

  for i in {1..30}; do
    health=$(curl -fsS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || true
    status=$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
    [[ $status == green ]] && break
    sleep 1
  done
  if [[ $status == green ]]; then
    opt_report "- Cluster health: green"
    return 0
  fi
  opt_report "- Cluster health: ${status:-unknown} after replica fix"
  return 1
}

optimize_elastic() {
  local active=0 yml=/etc/elasticsearch/elasticsearch.yml ram_mb heap_mb
  local jvm=$ES_JVM_OPTIONS
  local legacy=/etc/elasticsearch/jvm.options.d/jvm.options
  local unit=/etc/systemd/system/elasticsearch.service.d/limits.conf
  local es_before jvm_before legacy_before unit_before es_after jvm_after unit_after changed=0 i
  local es_url=""
  systemctl is-active --quiet elasticsearch 2>/dev/null && active=1
  opt_report "## Elasticsearch"
  opt_report "- Active: ${active}; config: \`${yml}\`"
  opt_backup /etc/elasticsearch elasticsearch
  opt_backup /etc/systemd/system/elasticsearch.service.d elasticsearch-systemd

  ES_MAP_COUNT_NOTE=""
  ensure_es_max_map_count || opt_report "- **WARNING**: could not raise vm.max_map_count"
  [[ -n $ES_MAP_COUNT_NOTE ]] && opt_report "- ${ES_MAP_COUNT_NOTE}"

  # The plan already rounds the heap (and may keep a live operator heap
  # unrounded); rounding again here used to shrink a kept 1000m heap to 512m.
  heap_mb=$(service_mem_mb elastic)

  if (( ${OPT_ES_SIZE_MB:-0} == 0 )); then
    OPT_ES_SIZE_MB=$(elasticsearch_data_size_mb)
    [[ ${OPT_ES_SIZE_MB:-} =~ ^[0-9]+$ ]] || OPT_ES_SIZE_MB=0
  fi
  if (( OPT_ES_SIZE_MB > 0 )); then
    if (( ${OPT_ES_KEPT_MB:-0} > 0 )); then
      opt_report "- Index store=${OPT_ES_SIZE_MB}MB; heap=${heap_mb}MB (kept existing heap)"
    else
      opt_report "- Index store=${OPT_ES_SIZE_MB}MB; heap=${heap_mb}MB (store/4, 512 MB minimum; the page cache serves the index)"
    fi
    if (( ${OPT_ES_PRELOAD:-0} )) \
       && (( OPT_ES_SIZE_MB + OPT_ES_SIZE_MB / 20 > ${OPT_ES_CACHE_FREE_MB:-0} )); then
      opt_report "- **WARNING** Index in RAM: ${OPT_ES_SIZE_MB}MB still fits the ${OPT_ES_CACHE_FREE_MB}MB left after the services, but the 5% growth room is gone; preload kept on for now (it turns off, with an Elasticsearch restart, once the index outgrows the free RAM)"
    elif (( ${OPT_ES_PRELOAD:-0} )); then
      opt_report "- Index in RAM: ${OPT_ES_SIZE_MB}MB (+5% growth) fits the ${OPT_ES_CACHE_FREE_MB}MB left after the services; index.store.preload: [\"*\"] loads every index file at open (applies at the next Elasticsearch start)"
    elif (( ${OPT_ES_CACHE_MB:-0} > 0 )); then
      opt_report "- **WARNING** Index in RAM: ${OPT_ES_SIZE_MB}MB (+5% growth) does not fit the ${OPT_ES_CACHE_FREE_MB}MB left after the services; preload off, search reads part of the index from disk (add RAM or reduce the other services)"
    fi
  fi

  es_before=$(file_md5 "$yml")
  jvm_before=$(file_md5 "$jvm")
  legacy_before=$(file_md5 "$legacy")
  unit_before=$(file_md5 "$unit")

  write_es_jvm_options "$heap_mb"

  # The installer comments http.host/transport.host so network.host controls
  # the bind; --optimize must do the same or an old 0.0.0.0 value survives.
  local active_bind=0 net_host=""
  if grep -qE '^[[:space:]]*(http\.host|transport\.host)[[:space:]]*:' "$yml"; then
    active_bind=1
  fi
  net_host=$(sed -nE 's/^[[:space:]]*network\.host[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null | head -n1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')

  # Keep a setup-managed node's base block in sync; a hand-managed node is
  # left alone so --optimize never hijacks an operator's cluster name or bind.
  # Same writer as the installer for the base and performance blocks.
  elasticsearch_write_managed_yaml "$yml"
  if [[ -n $ES_MANAGED_HOST ]]; then
    opt_report "- Base config: network.host=${ES_MANAGED_HOST}, single-node discovery, x-pack security off"
  fi
  # The managed block comments http.host/transport.host, so the effective
  # endpoint is derived after it is written.  A node intentionally bound to a
  # public IPv4 for a remote XenForo client must be probed there, not on
  # 127.0.0.1.
  es_url=$(elasticsearch_http_url "$yml")
  opt_report "- HTTP endpoint: \`${es_url}\`"
  if (( active_bind )); then
    opt_report "- Commented active http.host/transport.host; network.host controls the bind"
  fi
  if [[ -n $net_host && $net_host != localhost && $net_host != 127.0.0.1 \
        && $net_host != "::1" && $net_host != "[::1]" ]] \
     && grep -qE '^[[:space:]]*xpack\.security\.enabled[[:space:]]*:[[:space:]]*false' "$yml" 2>/dev/null; then
    # Status only: the security audit raises the single warning when the
    # ports are not restricted (it used to be printed here as well).
    local es_exposure
    es_exposure=$(es_ufw_exposure)
    case $es_exposure in
      restricted:*) opt_report "- Remote bind: network.host=${net_host}, X-Pack security off; UFW admits 9200/9300 only from ${es_exposure#restricted:}" ;;
      *)            opt_report "- Remote bind: network.host=${net_host}, X-Pack security off; 9200/9300 not restricted by UFW (see the security audit)" ;;
    esac
  fi

  elasticsearch_write_systemd_limits || true
  systemctl daemon-reload || true

  es_after=$(file_md5 "$yml")
  jvm_after=$(file_md5 "$jvm")
  unit_after=$(file_md5 "$unit")
  [[ $es_before != "$es_after" || $jvm_before != "$jvm_after" \
     || $unit_before != "$unit_after" ]] && changed=1
  # Moving the legacy jvm.options file changes the effective heap without
  # changing the managed file, so count it as a change too.
  if [[ $legacy_before != "$(file_md5 "$legacy")" ]]; then
    changed=1
    opt_report "- Moved legacy \`${legacy}\` to /tmp (superseded by zz-setup-optimize.options; not deleted)"
  fi
  if (( changed )); then
    opt_report "- Heap=${heap_mb}m; bootstrap.memory_lock=true; performance block written"
  else
    opt_report "- Heap=${heap_mb}m; configuration already optimized"
  fi
  if (( ${OPT_ES_DIRECT_MB:-0} > 0 )); then
    if (( ${OPT_ES_DIRECT_OPERATOR:-0} )); then
      opt_report "- Off-heap: operator MaxDirectMemorySize=${OPT_ES_DIRECT_MB}MB (jvm.options.d), ${OPT_ES_DIRECT_BOOKED_MB}MB booked in the memory plan"
    else
      opt_report "- Off-heap: MaxDirectMemorySize left to JVM ergonomics (heap/2 = ${OPT_ES_DIRECT_MB}MB), ${OPT_ES_DIRECT_BOOKED_MB}MB booked in the memory plan"
    fi
  fi

  if (( active )); then
    if (( changed == 0 )); then
      opt_report "- Restart: skipped (configuration already optimized)"
      elasticsearch_fix_single_node_replicas || return 1
      return 0
    fi
    # Large heaps and many shards take time to become ready.  The probe uses
    # the endpoint the node was configured with; a remote-bound node will
    # not answer on loopback (the probe then accepts the owned listener).
    opt_restart_service elasticsearch /etc/elasticsearch elasticsearch elasticsearch-systemd \
      elasticsearch_restart_probe "$es_url" || return 1
    if elasticsearch_wait_http "$es_url" 1; then
      elasticsearch_fix_single_node_replicas || return 1
    else
      opt_report "- Single-node replica check skipped: the HTTP endpoint was not reachable from this host"
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  return 0
}

# Ports actually held by a process name, e.g. "80,443".  A systemd unit can
# be active while its worker processes never bound a socket (a stale master
# or a config-test-only reload), so check the kernel's listener table too.
opt_listen_ports() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltnp 2>/dev/null \
    | grep -F "(\"${1}\"" \
    | awk '{print $4}' | awk -F: '{print $NF}' \
    | grep -E '^[0-9]+$' | sort -nu | paste -sd, - || true
}

opt_listener_ok() {
  local listen=$1 port
  [[ -z $listen ]] && return 0
  if [[ $listen == /* ]]; then
    [[ -S $listen ]]
    return
  fi
  command -v ss >/dev/null 2>&1 || return 0
  port=${listen##*:}
  [[ $port =~ ^[0-9]+$ ]] || return 0
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

# Report (but do not fail on) error-level journal entries written after the
# optimize run started.  Probes below decide success; logs add context for
# warnings that do not take a service down.
opt_log_errors() {
  local unit=$1 label=$2 out line
  command -v journalctl >/dev/null 2>&1 || return 0
  [[ -n ${OPT_START_TS:-} ]] || return 0
  out=$(journalctl -u "$unit" --since "$OPT_START_TS" -p err -q --no-pager 2>/dev/null \
    | tail -n 3 || true)
  if [[ -n $out ]]; then
    opt_report "- ${label}: error-level journal entries since start (review):"
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | tr '`' "'")
      opt_report "  \`${line}\`"
    done <<< "$out"
  else
    opt_report "- ${label}: no error-level journal entries since start"
  fi
}

verify_optimized_services() {
  local rc=0 ver sock es_url code nginx_bin out
  nginx_bin=$(opt_nginx_bin)
  opt_report "## Verification"

  if (( ${OPT_WEB_LEGACY:-0} )); then
    # Legacy-Angie mode: nothing in the web tier was changed; only say
    # whether the server that still owns :80/:443 is up.
    if systemctl is-active --quiet angie 2>/dev/null; then
      opt_report "- Angie (legacy mode): active; not tuned or verified by --optimize"
    else
      opt_report "- Angie (legacy mode): **not active**; check \`systemctl status angie\`"
    fi
  elif [[ -x $nginx_bin ]] && systemctl is-active --quiet nginx; then
    if "$nginx_bin" -t >/dev/null 2>&1; then
      local ports
      ports=$(opt_listen_ports nginx)
      if [[ -n $ports ]]; then
        opt_report "- nginx: configuration valid; listening on \`${ports}\`"
      else
        opt_report "- nginx: **FAILED** active but no listening socket found"
        rc=1
      fi
    else
      opt_report "- nginx: **FAILED** configuration test while active"
      rc=1
    fi
    opt_log_errors nginx nginx
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" php:"* ]]; then
    (( ${OPT_PHP_OK:-0} )) || opt_report "- PHP: no primary pool was optimized; nginx upstream left unchanged"
    while IFS= read -r ver; do
      systemctl is-active --quiet "php${ver}-fpm" || continue
      sock=$(php_pool_listen "$ver")
      # php_fpm_test: the unit's -y, -c and PHP_INI_SCAN_DIR, and it fails
      # on extension load warnings or a missing OPcache (R2.8).
      if ! out=$(php_fpm_test "$ver" 2>&1); then
        opt_report "- PHP ${ver}: **FAILED** configuration test ($(grep -iE 'error|warning|unable|not loaded|no compiled' <<<"$out" | head -n 1 | tr '`' "'"))"
        rc=1
      elif ! opt_listener_ok "$sock"; then
        opt_report "- PHP ${ver}: **FAILED** active but listener \`${sock:-unknown}\` is missing"
        rc=1
      else
        opt_report "- PHP ${ver}: active, listener \`${sock:-unknown}\`"
      fi
      opt_log_errors "php${ver}-fpm" "PHP ${ver}"
    done < <(php_fpm_versions)
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]] && systemctl is-active --quiet mariadb; then
    if mariadb -e 'SELECT 1' >/dev/null 2>&1; then
      opt_report "- MariaDB: active and accepting SQL"
    else
      opt_report "- MariaDB: **FAILED** active but SQL probe failed"
      rc=1
    fi
    opt_log_errors mariadb MariaDB
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" valkey "* ]] && systemctl is-active --quiet valkey-server; then
    if valkey_endpoint_pong "$(opt_valkey_cli)" "$(valkey_conf_get /etc/valkey/valkey.conf unixsocket)"; then
      opt_report "- Valkey: active and responding to PING"
    else
      opt_report "- Valkey: **FAILED** active but PING failed"
      rc=1
    fi
    opt_log_errors valkey-server Valkey
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" redis "* ]] && systemctl is-active --quiet redis-server; then
    if valkey_endpoint_pong redis-cli "$(valkey_conf_get /etc/redis/redis.conf unixsocket)"; then
      opt_report "- Redis: active and responding to PING"
    else
      opt_report "- Redis: **FAILED** active but PING failed"
      rc=1
    fi
    opt_log_errors redis-server Redis
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]] && systemctl is-active --quiet elasticsearch; then
    es_url=$(elasticsearch_http_url)
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$es_url" 2>/dev/null || true)
    if [[ $code == 200 ]]; then
      opt_report "- Elasticsearch: active and answering HTTP on \`${es_url}\`"
    elif [[ $code == 000 || -z $code ]] && elasticsearch_listener_on "$es_url"; then
      opt_report "- Elasticsearch: active and listening on \`${es_url#*://}\` (HTTP probe from this host unavailable; verify from the client)"
    else
      opt_report "- Elasticsearch: **FAILED** active but HTTP probe to \`${es_url}\` returned ${code:-no response}"
      rc=1
    fi
    opt_log_errors elasticsearch Elasticsearch
  fi
  (( rc == 0 )) || opt_report "- Result: **one or more health checks failed**"
  return "$rc"
}

write_optimize_report() {
  local file line
  # Nanoseconds keep two runs in the same second from overwriting each other.
  file="/var/log/setup-optimize-$(date +%Y%m%d-%H%M%S-%N).md"
  {
    echo "# setup.sh --optimize report"
    echo
    echo "- Generated: $(date -Is)"
    echo "- Host: $(hostname 2>/dev/null || echo unknown)"
    echo "- OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "- CPU: $(nproc) threads"
    echo "- RAM: $(awk '/^MemTotal:/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)"
    echo "- Disk: $(df -h / | awk 'NR==2{print $4 " free of " $2}')"
    echo "- Backup directory: \`${OPT_BACKUP_DIR:-none}\`"
    echo
    if (( ${#OPT_DETECTED[@]} == 0 )); then
      echo "No supported installed services were detected."
    else
      echo "Detected: ${OPT_DETECTED[*]}"
    fi
    echo
    # The OS profile, security hardening and cron results are collected even
    # when no service was detected; an OS-only run must not lose them.
    for line in "${OPT_REPORT[@]}"; do
      printf '%s\n' "$line"
    done
  } > "$file"
  # The report quotes service journals, backup and socket paths: root and
  # its group only, like the PHP upgrade report.
  chmod 640 "$file" 2>/dev/null || true
  cp -f "$file" /var/log/setup-optimize-latest.md
  chmod 640 /var/log/setup-optimize-latest.md 2>/dev/null || true
  OPT_REPORT_WRITTEN=1
  printf '%s\n' "$file"
}

optimize_plan() {
  local nproc ram_mb size_mb max_children max_mb heap_mb backlog max_conn db_fit db_size_mb es_fit es_size_mb
  local governor_desc=performance disk_free_mb cache_mb
  # Always show what the run will drop: the profile is hardware-derived.
  optimize_ignore_tuning_env
  printf '\n%sProfile reset preview%s (no file is moved):\n' "$C_BOLD" "$C_RESET"
  reset_operator_overrides 2
  # The run moves explicit-options.conf away before planning; plan without
  # it here too (the dry run exits after the preview, so it is never reset).
  OPT_PLAN_RESET_PENDING=1
  # host_server_type (util.sh) reads the recorded server_type pin directly
  # and caches its answer for the run.  The real run resolves it only after
  # the pin is moved, so it detects the class; a preview that kept a pinned
  # vps/dedi would show other workers per CPU, backlogs, io_capacity and
  # governor.  Resolve the cache once here through the same function with the
  # pin hidden, so every later caller gets the post-reset class.
  HOST_SERVER_TYPE=$(
    explicit_option() { return 1; }
    HOST_SERVER_TYPE=""
    host_server_type
  )
  if (( ${#OPTIMIZE_IGNORED_ENV[@]} > 0 )); then
    printf '  Ignored tuning environment: %s\n' "${OPTIMIZE_IGNORED_ENV[*]}"
  fi
  local foreign profile="${SCRIPT_DIR}/configs/system/sysctl.conf"
  if [[ ! -r $profile ]]; then
    profile=$(tmp_file) && blob_sysctl > "$profile" || profile=""
  fi
  foreign=$(TUNING_OURS_PROFILE=$profile tuning_override_sources conflicts)
  if [[ -n $foreign ]]; then
    printf '  Foreign sources that the boot profile will override:\n'
    printf '%s\n' "$foreign" | sed 's/^/    /'
  else
    printf '  No foreign sysctl source found.\n'
  fi
  nproc=$(effective_cpus)
  ram_mb=$(mem_total_mb)
  backlog=$(effective_backlog)
  # A pending 1.22 migration runs first in the real run (optimize_migration_step):
  # plan the tuning for the host it leaves behind (nginx instead of Angie,
  # the compiled PHP and Valkey instead of the packages).
  local migrate_pending=0 note
  if declare -F migrate_needed >/dev/null 2>&1 && migrate_needed; then
    migrate_pending=1
    detect_installed_services migrate
  else
    detect_installed_services
  fi
  plan_memory_budget
  # Same decision as configure_cpu_governor: a guest never touches the
  # governor, even when nested virtualisation exposes a cpufreq interface.
  if host_is_vps; then
    governor_desc="skipped (virtual host)"
  elif ! cpu_performance_governor_available; then
    governor_desc="skipped (no performance governor)"
  fi
  disk_free_mb=$(nginx_disk_free_mb)
  cache_mb=$(nginx_cache_budget_mb "$ram_mb" "$disk_free_mb")
  nginx_worker_limits "$nproc"
  printf '\n%sDRY RUN%s - optimize scan only, no changes will be made.\n' "$C_BOLD" "$C_RESET"
  printf 'Host: %s  %s CPU  %s MB RAM  %s\n' "$(hostname 2>/dev/null || echo unknown)" \
    "$nproc" "$ram_mb" "$(df -h / | awk 'NR==2{print $4 " free"}')"
  printf '  OS: governor=%s limits=1M-nofile sysctl=hardware-scaled (%s CPUs / %sMB RAM)\n' \
    "$governor_desc" "$nproc" "$ram_mb"
  printf '  Legacy repair: nightly cron chown and /var/www/logs ownership\n'
  printf '  Security: wp-config 640, scoped DB users, malware quarantine, OS/SSH/firewall audit\n'
  if declare -F migrate_plan >/dev/null 2>&1; then
    migrate_plan || true
  fi
  if (( ${#OPT_DETECT_NOTES[@]} > 0 )); then
    printf '  Not tuned:\n'
    for note in "${OPT_DETECT_NOTES[@]}"; do printf '    %s\n' "$note"; done
  fi
  if (( ${#OPT_DETECTED[@]} == 0 )); then
    printf 'No supported installed services detected.\n'
    return 0
  fi
  if (( migrate_pending )); then
    printf 'Detected (as the migration leaves the host): %s\n' "${OPT_DETECTED[*]}"
  else
    printf 'Detected: %s\n' "${OPT_DETECTED[*]}"
  fi
  printf '  %s\n' "$(memory_plan_summary Memory)"
  if [[ -n ${CPU_MITIGATIONS:-} ]]; then
    printf '  CPU mitigations: %s\n' "$(cpu_mitigations_plan_text)"
  fi
  if (( ${OPT_MEM_OVERCOMMIT_MB:-0} > 0 )); then
    printf '  WARNING: service floors and reserved memory exceed the budget by %sMB; this host is too small for the selected services\n' \
      "$OPT_MEM_OVERCOMMIT_MB"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" nginx "* ]]; then
    printf '  nginx: workers=%s connections=%s rlimit=%s keepalive=%s cache_budget=%sMB\n' \
      "$NGINX_WORKER_PROCESSES" "$NGINX_WORKER_CONNECTIONS" "$NGINX_WORKER_RLIMIT" \
      "$NGINX_PHP_KEEPALIVE" "$cache_mb"
    printf '  nginx compression: Brotli level %s (static module of the compiled nginx), gzip fallback\n' \
      "$(nginx_brotli_level)"
    local nginx_plan
    nginx_plan=$(nginx_build_plan)
    [[ -n $nginx_plan ]] && printf '  nginx: %s\n' "$nginx_plan"
    if pkg_ok nginx-module-zstd 2>/dev/null; then
      printf '  nginx zstd: retired in 1.21.59; managed stanzas moved away and nginx-module-zstd purged unless a configuration still uses it\n'
    fi
    printf '  XenForo jobs: managed xf:run-jobs crontab %s for every XenForo root (SETUP_XF_JOB_CRON)\n' \
      "$( (( XF_JOB_CRON )) && printf on || printf off )"
    printf '  nginx repository: sync %s (%s), then apply the hardware profile\n' \
      "${CONFIG_REPO_URL}" "${CONFIG_REPO_REF}"
    # Same gate as the real run: both steps need a running nginx.
    if systemctl is-active --quiet nginx 2>/dev/null; then
      cloudflare_tls_migrate /etc/nginx 1 || true
      certbot_retire_if_unused 1 || true
    elif [[ ${CF_SELF_SIGNED:-1} != 0 ]]; then
      printf '  Cloudflare TLS / certbot: skipped (nginx is not active)\n'
    fi
  fi
  printf '  Applications: audit WordPress/XenForo persistent MariaDB and Valkey socket settings\n'
  if [[ ${OPT_DETECTED[*]} == *php:* ]]; then
    # Same inputs as tune_php_fpm_version after the profile reset: a live
    # pool keeps its count; the explicit --php children=/max_requests= the
    # run moves away are not read (plan_explicit_option).
    local live_children explicit_children explicit_requests
    live_children=$(php_pool_max_children)
    explicit_children=$(plan_explicit_option php_children 2>/dev/null || true)
    explicit_requests=$(plan_explicit_option php_max_requests 2>/dev/null || true)
    local plan_allowance
    plan_allowance=$(php_worker_allowance_mb "$(php_primary_version 2>/dev/null || true)" 2>/dev/null || true)
    [[ $plan_allowance =~ ^[0-9]+$ ]] && (( plan_allowance > 0 )) || plan_allowance=64
    max_children=$(php_plan_max_children "$nproc" "$ram_mb" "$live_children" "$explicit_children" "${OPT_PHP_BUDGET_MB:-0}" "$plan_allowance")
    # tune_php_fpm_version splits the planned pool across running FPM versions
    # (each runs its own static pool) unless --php children= pins it; preview
    # the per-version share it will write, not the whole pool.
    local plan_active_versions=0 plan_split_note=""
    plan_active_versions=$(php_fpm_active_versions | grep -c . || true)
    if [[ -z $explicit_children ]] && (( plan_active_versions > 1 )) \
       && systemctl is-active --quiet "php$(php_primary_version 2>/dev/null || true)-fpm" 2>/dev/null; then
      max_children=$(php_split_children "$max_children" "$plan_active_versions")
      plan_split_note=" (each of ${plan_active_versions} running PHP-FPM versions)"
    fi
    [[ $explicit_requests =~ ^[0-9]+$ ]] || explicit_requests=$(( nproc * 1024 ))
    printf '  PHP-FPM:  max_children=%s%s max_requests=%s backlog=%s\n' \
      "$max_children" "$plan_split_note" "$explicit_requests" "$backlog"
    # Same helper as the ini writer, so the preview shows the JIT the run
    # would write (opcache.memory_consumption follows RAM/16, 128..512 MB).
    local plan_opcache_mb jit_mode jit_buffer_mb wp_roots
    php_ini_profile "$ram_mb"
    plan_opcache_mb=$PHP_PROFILE_OPCACHE_MB
    printf '  PHP-FPM:  memory_limit=%sM realpath_cache=%sk\n' "$PHP_PROFILE_MEMORY_MB" "$PHP_PROFILE_REALPATH_KB"
    read -r jit_mode jit_buffer_mb < <(php_jit_settings "$plan_opcache_mb")
    wp_roots=$(php_jit_path_sections /etc/nginx | grep -c '^opcache\.jit = off$' || true)
    printf '  PHP-FPM:  pm=static opcache=%sM jit=%s buffer=%sM (WordPress roots kept off: %s)\n' \
      "$plan_opcache_mb" "$jit_mode" "$jit_buffer_mb" "${wp_roots:-0}"
    local build_plan
    build_plan=$(php_build_plan)
    [[ -n $build_plan ]] && printf '  PHP-FPM:  %s\n' "$build_plan"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]]; then
    size_mb=$OPT_MARIADB_BUDGET_MB
    mariadb_compute_profile "$size_mb"
    max_conn=$MARIADB_PROFILE_MAX_CONN
    db_size_mb=${OPT_DB_SIZE_MB:-0}
    db_fit=""
    if (( db_size_mb > 0 )); then
      db_fit=", database=${db_size_mb}MB (data+5% = $(( db_size_mb + db_size_mb / 20 ))MB, 128MB minimum, cap 50% RAM beside PHP/cache/search, 80% on a database-only host"
      (( ${OPT_MARIADB_KEPT_MB:-0} > 0 )) && db_fit+="; existing pool kept"
      db_fit+=")"
    fi
    printf '  MariaDB: buffer_pool=%sMB max_connections=%s back_log=%s%s\n' \
      "$size_mb" "$max_conn" "$backlog" "$db_fit"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" valkey "* || " ${OPT_DETECTED[*]} " == *" redis "* ]]; then
    # The plan's value is final (live-data guard included), so this is the
    # number the run writes.
    max_mb=$OPT_VALKEY_BUDGET_MB
    local cache_label=Valkey cache_note=""
    if [[ " ${OPT_DETECTED[*]} " == *" redis "* ]]; then
      cache_label=Redis
    fi
    case ${OPT_VALKEY_GUARD:-} in
      full)   cache_note=" (cache is full; kept, --valkey ram=<size> grows it)" ;;
      raised) cache_note=" (raised to keep live data)" ;;
      shrunk) cache_note=" (lowered from ${OPT_VALKEY_PREV_MB:-0}MB)" ;;
      capped) cache_note=" (capped; live data needs more)" ;;
      young)  cache_note=" (kept: started less than a day ago)" ;;
      unmeasured) cache_note=" (kept: not measurable)" ;;
    esac
    printf '  %s: maxmemory=%sMB backlog=%s%s\n' "$cache_label" "$max_mb" "$backlog" "$cache_note"
    local valkey_plan
    valkey_plan=$(valkey_build_plan)
    [[ -n $valkey_plan && $cache_label == Valkey ]] && printf '  Valkey: %s\n' "$valkey_plan"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]]; then
    heap_mb=$(service_mem_mb elastic)
    es_size_mb=${OPT_ES_SIZE_MB:-0}
    es_fit=""
    if (( es_size_mb > 0 )); then
      es_fit=", index=${es_size_mb}MB (heap=store/4, page cache serves the index"
      if (( ${OPT_ES_PRELOAD:-0} )); then
        es_fit+="; fits in RAM, ${OPT_ES_CACHE_FREE_MB:-0}MB free: preload on)"
      else
        es_fit+="; does not fit the ${OPT_ES_CACHE_FREE_MB:-0}MB free: preload off)"
      fi
    fi
    printf '  Elasticsearch: heap=%sMB%s\n' "$heap_mb" "$es_fit"
  fi
}

