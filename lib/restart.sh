# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# --restart-all: restart the whole installed stack in dependency order
# ---------------------------------------------------------------------------
list_active_php_units() {
  systemctl list-units --type=service --state=active --no-legend --no-pager \
    'php*-fpm.service' 2>/dev/null \
    | awk '{print $1}' | grep -E '^php.*-fpm\.service$' || true
}

# The active cache unit name, or nothing.  valkey and valkey-server are
# aliases for the same unit, so only the first active name is printed and the
# cache is never listed (or restarted) twice.  Shared by the restart-all plan
# and the restart itself.
active_cache_unit() {
  local unit
  for unit in valkey-server valkey redis-server; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      printf '%s' "$unit"
      return 0
    fi
  done
  return 0
}

restart_all_plan() {
  local unit cache_unit=""
  local -a active=() php_units=()
  detect_installed_services
  mapfile -t php_units < <(list_active_php_units)
  systemctl is-active --quiet angie 2>/dev/null && active+=(angie)
  systemctl is-active --quiet mariadb 2>/dev/null && active+=(mariadb)
  cache_unit=$(active_cache_unit)
  [[ -n $cache_unit ]] && active+=("$cache_unit")
  systemctl is-active --quiet elasticsearch 2>/dev/null && active+=(elasticsearch)
  active+=("${php_units[@]}")
  printf '\n%sDRY RUN%s - restart-all scan only, no changes will be made.\n' "$C_BOLD" "$C_RESET"
  printf 'Detected installed: %s\n' "${OPT_DETECTED[*]:-none}"
  printf 'Active services:     %s\n' "${active[*]:-none}"
  printf 'Order:\n'
  printf '  daemon-reload\n'
  printf '  stop angie (if active)\n'
  printf '  stop active php*-fpm.service\n'
  printf '  restart active Valkey/Redis service\n'
  printf '  restart active Elasticsearch\n'
  printf '  wait for the Elasticsearch HTTP endpoint (up to 300s)\n'
  printf '  restart active MariaDB\n'
  printf '  wait for SELECT 1 (up to 300s)\n'
  printf '  start the PHP-FPM versions that were stopped\n'
  printf '  start angie if it was stopped\n'
  if (( ${#active[@]} == 0 )); then
    printf 'No active supported services detected.\n'
  fi
}

run_restart_all() {
  local unit rc=0
  local angie_active=0 mariadb_active=0
  local elastic_active=0 es_url="" es_ok=0
  local -a php_units=() cache_units=() failures=()

  step "Restarting all detected services"
  detect_installed_services
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    info "Detected installed services: ${OPT_DETECTED[*]}"
  else
    warn "No supported installed services were detected from configuration paths"
  fi

  # Repair old /var/www/logs ownership before touching any service.  A
  # MariaDB/Valkey/Elasticsearch restart can otherwise fail when the previous
  # release left its log directory owned by www-data.
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    repair_log_ownership 1 || warn "Log ownership repair reported failures"
  fi

  systemctl daemon-reload || warn "systemctl daemon-reload failed"
  systemctl is-active --quiet angie 2>/dev/null && angie_active=1
  mapfile -t php_units < <(list_active_php_units)
  unit=$(active_cache_unit)
  [[ -n $unit ]] && cache_units+=("$unit")
  systemctl is-active --quiet elasticsearch 2>/dev/null && elastic_active=1
  systemctl is-active --quiet mariadb 2>/dev/null && mariadb_active=1

  # Report installed-but-inactive units without starting them.
  for unit in angie mariadb valkey-server redis-server elasticsearch; do
    if ! systemctl is-active --quiet "$unit" 2>/dev/null \
       && systemctl cat "$unit" >/dev/null 2>&1; then
      info "Skipping ${unit}: installed but inactive"
    fi
  done

  # 1. Stop the request tiers, Angie first, then all active PHP versions
  #    (the same pause the MariaDB tuner uses before its restart).
  opt_pause_web_frontends "the restart"
  if (( angie_active && OPT_WEB_PAUSED_ANGIE == 0 )); then
    failures+=("stop angie")
    rc=1
  fi
  if (( ${#OPT_WEB_PAUSED_PHP[@]} < ${#php_units[@]} )); then
    failures+=("stop php-fpm")
    rc=1
  fi

  # 2. Restart cache/search before MariaDB.
  for unit in "${cache_units[@]}"; do
    if systemctl restart "$unit" 2>/dev/null; then
      info "Restarted ${unit}"
    else
      warn "Could not restart ${unit}"
      failures+=("restart ${unit}")
      rc=1
    fi
  done
  if (( elastic_active )); then
    if systemctl restart elasticsearch 2>/dev/null; then
      info "Restarted elasticsearch"
      # Type=simple returns before the node is ready.  Wait for the HTTP
      # endpoint before the PHP/Angie tiers are started so the first search
      # requests do not hit a recovering cluster.  A remote-bound node can be
      # healthy while the host cannot reach its own public address through
      # firewall/NAT; the listener is enough (rc 2).
      es_url=$(elasticsearch_http_url 2>/dev/null || true)
      if [[ -n $es_url ]]; then
        elasticsearch_wait_http "$es_url" 300 || es_ok=$?
        case $es_ok in
          0) info "Elasticsearch is answering HTTP" ;;
          2) info "Elasticsearch is listening on the configured endpoint" ;;
          *)
            warn "Elasticsearch did not answer HTTP within 300s (${ES_WAIT_LAST_CODE:-no response})"
            failures+=("elasticsearch HTTP probe")
            rc=1 ;;
        esac
      else
        info "Elasticsearch HTTP endpoint is unavailable; skipping readiness probe"
      fi
    else
      warn "Could not restart elasticsearch"
      failures+=("restart elasticsearch")
      rc=1
    fi
  fi

  # 3. Restart MariaDB and wait for SQL before letting web traffic back in.
  if (( mariadb_active )); then
    if systemctl restart mariadb 2>/dev/null; then
      info "Restarted mariadb; waiting for SELECT 1"
      if ! command -v mariadb >/dev/null 2>&1; then
        warn "MariaDB was restarted but could not be probed (client missing)"
        failures+=("mariadb SQL probe")
        rc=1
      elif mariadb_wait_ready 300; then
        info "MariaDB is accepting SQL"
      else
        warn "MariaDB did not answer SELECT 1 within 300s"
        failures+=("mariadb SQL probe")
        rc=1
      fi
    else
      warn "Could not restart mariadb"
      failures+=("restart mariadb")
      rc=1
    fi
  fi

  # 4. Start PHP-FPM first, then Angie, regardless of a MariaDB probe failure:
  #    restore the services that were active before the restart and report it.
  if ! opt_resume_web_frontends "the restart"; then
    failures+=("start php-fpm/angie")
    rc=1
  fi

  if (( rc == 0 )); then
    ok "All detected services restarted successfully"
  else
    warn "Restart completed with failures: ${failures[*]}"
  fi
  handled_return "$rc"
}

run_os_tuning() {
  step "OS auto-tuning (CPU, memory, networking)"
  ensure_state
  # Reuse the install-time tuners so an existing server receives exactly the
  # same hardware-aware profile as a fresh build.  Each tuner is idempotent
  # and records the original files for a later --purge.
  configure_cpu_governor
  # Swap is deliberately not touched by --optimize.  Resizing a live swap
  # file can swapoff/rewrite under memory pressure, and creating a 50%-of-RAM
  # file on a large host is a destructive disk change rather than tuning.
  # Use --basic swap=SIZE (or manage swap separately) when a host needs it.
  # Raise fs.nr_open/file-max before writing the 1M-nofile PAM limits: a
  # limits value above the kernel's fs.nr_open makes PAM fail to raise the
  # hard limit for the next login.
  configure_sysctl
  configure_limits
  configure_io_tuning
}

# Repair legacy cron jobs written by older releases.  It is deliberately a
# text migration, not a purge: the ownership job's intent (keep web content
# owned by www-data) is preserved, but it no longer touches the per-service
# log tree or the database backup directory, and the old nginx/mysqlcheck
# paths are replaced by the managed block.
repair_optimize_legacy_cron() {
  local cur backup="" had_legacy=0 had_cloudflare=0 had_mysqlcheck=0
  if ! command -v crontab >/dev/null 2>&1; then
    opt_report "- Cron: skipped (crontab is not installed)"
    return 0
  fi
  cur=$(crontab -l 2>/dev/null || true)
  if [[ -n $cur ]] \
     && printf '%s\n' "$cur" | grep -qE 'chown[[:space:]]+www-data:www-data[[:space:]]+(-R|--recursive)[[:space:]]+/var/www|chown[[:space:]]+(-R|--recursive)[[:space:]]+www-data:www-data[[:space:]]+/var/www'; then
    had_legacy=1
  fi
  if printf '%s\n' "$cur" | grep -qF -- '/etc/nginx/scripts/cloudflare.sh'; then
    had_cloudflare=1
  fi
  if printf '%s\n' "$cur" | grep -qF -- '/usr/bin/mysqlcheck'; then
    had_mysqlcheck=1
  fi
  if [[ -n $cur ]]; then
    backup=$(tmp_file)
    printf '%s\n' "$cur" > "$backup"
  fi
  # Let write_cron own the managed block.  It strips bare legacy/safe chown
  # lines and the old nginx/mysqlcheck paths, then regenerates entries for
  # installed services, so a host whose block was removed by --purge basic
  # also gets its backups and log-owner repair back.
  if write_cron; then
    if (( had_legacy )); then
      opt_report "- Cron: migrated the legacy 'chown -R /var/www' entry"
    fi
    if (( had_cloudflare )); then
      opt_report "- Cron: removed the legacy /etc/nginx/scripts/cloudflare.sh path"
    fi
    if (( had_mysqlcheck )); then
      opt_report "- Cron: removed the legacy /usr/bin/mysqlcheck path"
    fi
    if (( had_legacy == 0 && had_cloudflare == 0 && had_mysqlcheck == 0 )); then
      if (( CRON_UPDATED )); then
        opt_report "- Cron: managed block updated for installed services"
      else
        opt_report "- Cron: managed block already current (not rewritten)"
      fi
    fi
    # The backup only matters when the crontab was actually replaced.
    if [[ -n $backup ]] && (( CRON_UPDATED )); then
      opt_report "- Cron: previous crontab saved to \`${backup}\`"
    fi
    return 0
  fi
  opt_report "- Cron: **FAILED** to update the crontab"
  return 1
}

# Older releases created every /var/www/logs/<service> directory as www-data.
# A service that writes its own log (MariaDB, Redis/Valkey, Elasticsearch) then
# fails to reopen or rotate it, sometimes only after the next restart.  Fix the
# ownership that this run can prove is wrong, and repair the two paths the old
# blanket cron also flattened (/var/www and /var/www/mysql_database).  The
# quiet mode uses info() (for --restart-all); the default writes the optimize
# report.
repair_log_ownership() {
  local quiet=${1:-0} svc owner grp dir rc=0
  ensure_log_dirs
  repair_note() {
    if (( quiet )); then info "$*"; else opt_report "$*"; fi
  }
  if ! chown root:root /var/www/logs 2>/dev/null; then
    warn "Could not set /var/www/logs owner to root:root"
    repair_note "- Logs: **FAILED** to reset /var/www/logs to root:root"
    rc=1
  else
    chmod 755 /var/www/logs 2>/dev/null || true
    repair_note "- Logs: /var/www/logs -> root:root (755)"
  fi
  while read -r svc owner grp; do
    [[ -n $svc ]] || continue
    dir="/var/www/logs/$svc"
    [[ -d $dir ]] || continue
    if ! getent passwd "$owner" >/dev/null 2>&1; then
      repair_note "- Logs: skipped ${dir} (user ${owner} not found)"
      continue
    fi
    if chown -R "$owner:$grp" "$dir" 2>/dev/null \
       && chmod 750 "$dir" 2>/dev/null; then
      find "$dir" -type f -exec chmod 640 {} + 2>/dev/null || true
      repair_note "- Logs: ${dir} -> ${owner}:${grp} (750/640)"
    else
      warn "Could not repair ${dir} ownership"
      repair_note "- Logs: **FAILED** to repair ${dir} -> ${owner}:${grp}"
      rc=1
    fi
  done <<'EOF'
angie www-data www-data
php www-data www-data
nodejs www-data www-data
gifsicle www-data www-data
mariadb mysql mysql
elasticsearch elasticsearch elasticsearch
valkey valkey valkey
redis redis redis
EOF

  # The legacy cron also flattened the web root and the database backup
  # directory to www-data.  Both are security-sensitive: /var/www should be
  # root-owned, and dumps must not be readable by the web user.  Change them
  # only when the owner is still www-data, so an operator's deliberate layout
  # is left alone.
  if [[ -d /var/www ]] \
     && [[ $(stat -c '%U' /var/www 2>/dev/null || true) == www-data ]]; then
    if chown root:root /var/www 2>/dev/null && chmod 755 /var/www 2>/dev/null; then
      repair_note "- Web root: /var/www -> root:root (755)"
    else
      warn "Could not reset /var/www ownership"
      repair_note "- Web root: **FAILED** to reset /var/www"
      rc=1
    fi
  fi
  if [[ -d /var/www/mysql_database ]] \
     && [[ $(stat -c '%U' /var/www/mysql_database 2>/dev/null || true) == www-data ]]; then
    if chown -R root:root /var/www/mysql_database 2>/dev/null \
       && chmod 700 /var/www/mysql_database 2>/dev/null; then
      repair_note "- Backups: /var/www/mysql_database -> root:root (700)"
    else
      warn "Could not reset /var/www/mysql_database ownership"
      repair_note "- Backups: **FAILED** to reset /var/www/mysql_database"
      rc=1
    fi
  fi
  return "$rc"
}

run_optimize() {
  local rc=0 service
  OPT_REPORT_STARTED=1
  OPT_START_TS=$(date -Is)
  OPT_START_EPOCH=$(date +%s)
  OPT_BACKUP_DIR=""
  # The directory is created lazily by opt_backup() so a host with no
  # supported services (OS tuning only) does not leave an empty backup tree.
  # Rollback copies live under /tmp and are allowed to expire there; older
  # releases pruned them, which permanently deleted operator-recoverable data.
  OPT_REPORT=()
  detect_installed_services
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    OPT_BACKUP_DIR=$(tmp_dir setup-optimize.XXXXXX) \
      || die "Could not create an optimize backup directory"
  fi
  plan_memory_budget
  run_os_tuning
  # Security first: fix wp-config.php, scoped database users, malware and the
  # OS-level controls before the cron/managed blocks are regenerated.  The
  # WordPress step runs before write_cron so the managed wp-cron entry is
  # present in the same run that disables DISABLE_WP_CRON.
  opt_report "## Security hardening"
  harden_wordpress || rc=1
  harden_system 0 || rc=1
  # Old hosts can still carry the pre-1.8.34 nightly chown that flattened the
  # log tree to www-data.  Migrate that cron entry and repair the resulting
  # ownership before any service is restarted; otherwise MariaDB/Valkey/
  # Elasticsearch may fail to reopen or rotate their logs later.
  opt_report "## Legacy host repair"
  repair_optimize_legacy_cron || rc=1
  repair_log_ownership 0 || rc=1
  if command -v logrotate >/dev/null 2>&1; then
    configure_logrotate 0
    opt_report "- Log rotation: \`/etc/logrotate.d/setup-logs\` ensured"
  else
    opt_report "- Log rotation: logrotate is not installed; central logs may grow"
  fi
  opt_report "## Operating system"
  opt_report "- CPU governor, PAM limits and kernel/network/memory sysctls tuned for ${OPT_MEM_TOTAL_MB}MB RAM / $(effective_cpus) CPUs"
  step "Optimizing installed services"
  if (( ${#OPT_DETECTED[@]} == 0 )); then
    info "No supported installed services detected (Angie, PHP-FPM, MariaDB, Valkey/Redis, Elasticsearch)"
    opt_report "No supported installed services detected."
    # No service configuration was touched, so there is nothing to roll back.
    OPT_BACKUP_DIR=""
    local report
    report=$(write_optimize_report)
    # write_optimize_report runs in a command substitution (subshell), so its
    # OPT_REPORT_WRITTEN flag does not reach this shell.  Set it here so the
    # EXIT trap does not write a duplicate partial report.
    OPT_REPORT_WRITTEN=1
    info "Report: ${report}"
    if (( rc == 0 )); then
      ok "OS tuning and legacy repair completed"
    else
      warn "OS tuning or legacy repair reported failures; check the report"
    fi
    handled_return "$rc"
    return
  fi
  info "Detected: ${OPT_DETECTED[*]}"
  info "Backups: ${OPT_BACKUP_DIR}"
  info "$(memory_plan_summary 'Memory budget')"
  opt_report "- $(memory_plan_summary 'Memory budget')"

  # PHP first: it owns the FastCGI socket Angie may point at.
  OPT_PHP_OK=0
  OPT_PHP_SOCKET=""
  if [[ ${OPT_DETECTED[*]} == *php:* ]]; then
    OPT_PHP_OK=1
    optimize_php_services || { rc=1; OPT_PHP_OK=0; }
  fi
  for service in angie mariadb valkey redis elastic; do
    [[ " ${OPT_DETECTED[*]} " == *" ${service} "* ]] || continue
    case "$service" in
      angie)   optimize_angie   || rc=1 ;;
      mariadb) optimize_mariadb || rc=1 ;;
      valkey)  optimize_valkey valkey || rc=1 ;;
      redis)   optimize_valkey redis  || rc=1 ;;
      elastic) optimize_elastic || rc=1 ;;
    esac
  done

  verify_optimized_services || rc=1
  # Detect WordPress/XenForo configs under /var/www and report the exact
  # persistent MariaDB/Valkey settings the admin still needs to apply.
  audit_app_persistent_connections
  if (( ${APP_CONNECTION_ISSUES:-0} > 0 )); then
    warn "Application connection notices: ${APP_CONNECTION_ISSUES} item(s) need attention (see the report)"
  fi

  if (( OPT_CUTOVER )); then
    local cached
    cached=$(count_optimize_cache_entries "${OPT_START_EPOCH:-0}")
    if [[ $cached =~ ^[0-9]+$ ]] && (( cached > 0 )); then
      opt_report "- Found ${cached} cache object(s) written during this run; left in place (setup.sh does not delete cache files)"
    else
      opt_report "- Cache: no objects were written during the cutover window"
    fi
  else
    opt_report "- Cache: left intact (no service was reloaded or restarted)"
  fi

  local report
  report=$(write_optimize_report)
  OPT_REPORT_WRITTEN=1
  printf '\n%sOptimization report: %s%s\n' "$C_BOLD" "$report" "$C_RESET"
  printf '%s\n' "--- report ---"
  [[ -n $report && -r $report ]] && cat "$report"
  if (( rc == 0 )); then
    ok "All detected services are optimized and running"
  else
    warn "One or more services failed to optimize; check the report and backups"
  fi
  handled_return "$rc"
}

on_exit() {
  local rc=$?
  # A hard failure mid-run (set -e, a die, or a provider console reset) would
  # otherwise leave no diagnostic report.  Write what was collected so far.
  if (( ${OPTIMIZE:-0} )) && (( ${OPT_REPORT_STARTED:-0} )) \
     && (( ! ${OPT_REPORT_WRITTEN:-0} )); then
    write_optimize_report >/dev/null 2>&1 || true
  fi
  cleanup_configs
  release_run_lock
  finish_run_log "$rc"
  return "$rc"
}

main() {
  normalize_cli_args "$@"
  set -- "${NORMALIZED_ARGS[@]}"

  # Mirror every run (including --help, --dry-run and failures) to a full log
  # in the invocation directory before anything can fail or print output.
  start_run_log "$@"
  trap on_exit EXIT
  # A Ctrl-C or service-manager stop must unwind through on_exit so the run
  # log is closed and the optimize report is written.  Without these traps a
  # signal can leave the terminal/log in an inconsistent state.
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # --help/--version are safe without root.
  local a
  for a in "$@"; do
    case "$a" in
      --help|-h) usage; exit 0 ;;
      --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
    esac
  done

  # Parse and validate before the root/OS checks so --dry-run works for a
  # normal user and invalid arguments get an accurate error message.
  parse_args "$@"
  validate_all
  log_selection

  if (( DRY_RUN )); then
    if (( DIAGNOSTICS )); then
      printf 'DRY RUN - would write diagnostics to %s\n' "${SCRIPT_DIR}/diagnostics.log"
      exit 0
    fi
    if (( RESTART_ALL )); then
      restart_all_plan
      exit 0
    fi
    if (( OPTIMIZE )); then
      optimize_plan
      exit 0
    fi
    if [[ -n ${UPGRADE_PHP:-} ]]; then
      php_upgrade_plan
      exit 0
    fi
    [[ ${ENABLED[basic]:-0} -eq 1 ]] && resolve_basic_defaults
    print_plan
    exit 0
  fi

  [[ ${EUID} -eq 0 ]] || die "This script must be run as root (use: sudo bash ${SCRIPT_NAME} ...)"

  if (( DIAGNOSTICS )); then
    run_diagnostics
    exit 0
  fi

  acquire_run_lock

  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die "This script only supports Ubuntu (found: ${ID:-unknown})"
  if (( OPTIMIZE || RESTART_ALL )) || [[ -n ${UPGRADE_PHP:-} ]]; then
    if ! optimize_os_supported "${VERSION_ID:-}"; then
      die "--optimize/--restart-all/--upgrade-php supports Ubuntu 22.04, 24.04 or 26.04 (found ${VERSION_ID:-unknown})"
    fi
  elif (( ${VERSION_ID%%.*} < 26 )); then
    die "This script requires Ubuntu 26.04 or newer (found ${VERSION_ID})"
  fi

  # Size every service against one shared RAM budget on a fresh install, just
  # as --optimize does on an existing host.  --upgrade-php plans from the live
  # PHP worker measurement instead (the upgrade driver calls the planner).
  if (( ! OPTIMIZE && ! PURGE && ! RESTART_ALL )) && [[ -z ${UPGRADE_PHP:-} ]]; then
    record_explicit_options
    plan_install_budget
  fi

  if [[ -n ${UPGRADE_PHP:-} ]]; then
    printf '%s%sUbuntu %s PHP upgrade%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    run_php_upgrade
    exit 0
  fi

  if (( RESTART_ALL )); then
    printf '%s%sUbuntu %s service restart%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    # Plain calls: `if ! run_x` would suspend set -e and the ERR trap for the
    # whole run, so a failed write inside a tuner was skipped silently while
    # the same functions abort a --basic install.  A handled failure returns
    # through handled_return and exits with that status here.
    run_restart_all
    exit 0
  fi

  if (( OPTIMIZE )); then
    printf '%s%sUbuntu %s optimization (Angie sync + hardware profile)%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    run_optimize
    exit 0
  fi

  if [[ ${PURGE} -eq 1 ]]; then
    run_purge
    exit 0
  fi

  if [[ ${ENABLED[basic]:-0} -eq 1 ]]; then
    resolve_basic_defaults
    printf '%s%sUbuntu %s server setup%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    printf 'Host: %s  Server type: %s  Timezone: %s  Swap: %s\n' \
      "${OPT[basic.host]:-auto}" "${OPT[basic.server]:-auto}" \
      "${OPT[basic.time]:-Asia/Manila}" "${OPT[basic.swap]:-auto (50% of RAM)}"
  else
    printf '%s%sUbuntu %s domain setup%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
  fi
  if [[ ${#DOMAINS[@]} -gt 0 ]]; then
    printf 'Domains: %s\n' "${DOMAINS[*]}"
  fi

  if [[ ${ENABLED[basic]:-0} -eq 1 ]];   then run_service basic   install_basic; fi

  # Add all selected third-party repositories first, then update APT once.
  # Service installers only install packages; this avoids one apt-get update
  # (and its lock/retry overhead) per service.
  local need_repos=0 item
  (( ${ENABLED[angie]:-0} || ${ENABLED[php]:-0} || ${ENABLED[elastic]:-0} )) && need_repos=1
  for item in "${OTHERS[@]}"; do
    [[ $item == nodejs ]] && need_repos=1
  done
  if (( need_repos )); then
    prepare_repositories
  fi

  # The external repository now owns Angie config only. PHP-FPM templates are
  # local to this repository (configs/php), so a PHP-only install needs no
  # network fetch.
  if [[ ${ENABLED[angie]:-0} -eq 1 ]]; then
    fetch_server_configs || die "Could not prepare the Angie configuration repository"
  fi

  if [[ ${ENABLED[angie]:-0} -eq 1 ]];   then run_service angie   install_angie; fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]];     then run_service php     install_php; fi
  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then run_service mariadb install_mariadb; fi
  if [[ ${ENABLED[valkey]:-0} -eq 1 ]];  then run_service valkey  install_valkey; fi
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then run_service elastic install_elastic; fi
  if [[ ${ENABLED[others]:-0} -eq 1 ]];  then run_service others  install_others; fi
  if [[ ${ENABLED[domain]:-0} -eq 1 ]];  then run_service domain  create_domains; fi

  # Run the security pass last: PHP/MariaDB must exist before wp-config.php
  # and the database grants can be inspected.  --basic installs the OS
  # security packages and hardens any WordPress tree already present;
  # --domain applies the safe subset without installing anything.
  if [[ ${ENABLED[basic]:-0} -eq 1 ]]; then
    harden_system 1 || warn "Security hardening reported an issue (see the run log)"
    harden_wordpress || warn "WordPress hardening reported an issue (see the run log)"
  elif [[ ${ENABLED[domain]:-0} -eq 1 ]]; then
    harden_system 0 || true
    harden_wordpress || warn "WordPress hardening reported an issue (see the run log)"
  fi
  # The managed crontab depends on what the security pass found (the wp-cron
  # entry is added only once DISABLE_WP_CRON exists), so regenerate it after
  # hardening, in the same order --optimize uses.  write_cron is idempotent
  # and runs after every install, so a later --angie or --mariadb-only run
  # gets its entries (cloudflare sync, backups, checks) at once instead of at
  # the next --optimize.
  local svc_any=0 svc
  for svc in basic angie php mariadb valkey elastic others domain; do
    [[ ${ENABLED[$svc]:-0} -eq 1 ]] && svc_any=1
  done
  if (( svc_any )); then
    write_cron || warn "Could not refresh the managed crontab"
  fi

  cleanup_configs
  if print_summary; then
    printf '\n%sAll installations completed successfully.%s\n' "$C_GREEN" "$C_RESET"
    exit 0
  else
    printf '\n%sOne or more installations failed. See the log above.%s\n' "$C_RED" "$C_RESET" >&2
    exit 1
  fi
}

