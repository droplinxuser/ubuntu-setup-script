# ---------------------------------------------------------------------------
# Runner / summary
# ---------------------------------------------------------------------------
run_service() {
  local name=$1
  shift
  local start end rc
  step "Installing ${name}"
  start=$(date +%s)
  set +e
  ( set -Eeuo pipefail; "$@" )
  rc=$?
  set -e
  end=$(date +%s)
  SVC_SECONDS[$name]=$(( end - start ))
  if [[ $name == php && -s "${STATE_DIR}/php-selected-version" ]]; then
    OPT[php.ver]=$(<"${STATE_DIR}/php-selected-version")
  fi
  if (( rc == 0 )); then
    SVC_STATUS[$name]="OK"
    ok "${name} completed in $(format_duration "${SVC_SECONDS[$name]}")"
  else
    SVC_STATUS[$name]="FAILED"
    warn "${name} FAILED after $(format_duration "${SVC_SECONDS[$name]}")"
  fi
}

print_summary() {
  local total=0 s
  printf '\n%s%sInstallation summary%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%-10s %-8s %s\n' 'SERVICE' 'STATUS' 'TIME (HH:MM:SS)'
  printf '%-10s %-8s %s\n' '-------' '------' '--------------'
  for s in "${SERVICE_ORDER[@]}"; do
    [[ -n ${SVC_STATUS[$s]:-} ]] || continue
    printf '%-10s %-8s %s\n' "$s" "${SVC_STATUS[$s]}" "$(format_duration "${SVC_SECONDS[$s]}")"
    total=$(( total + SVC_SECONDS[$s] ))
  done
  printf '%-10s %-8s %s\n' 'TOTAL' '' "$(format_duration "$total")"

  local failed=0
  for s in "${SERVICE_ORDER[@]}"; do
    [[ ${SVC_STATUS[$s]:-} == FAILED ]] && failed=1
  done
  return "$failed"
}

resolve_basic_defaults() {
  if [[ -z ${OPT[basic.server]:-} ]]; then
    OPT[basic.server]=$(detect_server_type)
    info "Auto-detected server type: ${OPT[basic.server]}"
  fi
}

print_plan() {
  local s bind_display dd
  printf '\n%sDRY RUN%s - validation only, no changes will be made.\n' "$C_BOLD" "$C_RESET"

  if [[ ${PURGE} -eq 1 ]]; then
    build_purge_order
    printf 'Purge order: %s\n' "${PURGE_ORDER[*]}"
    printf 'Notes: services are stopped/disabled; packages, data, configuration and logs are preserved.\n'
    printf '       Packages that existed before setup.sh are preserved for --others.\n'
    return 0
  fi

  printf 'Install plan:\n'
  for s in "${SERVICE_ORDER[@]}"; do
    [[ ${ENABLED[$s]:-0} -eq 1 ]] || continue
    case "$s" in
      basic)
        printf '  %-10s server=%s host=%s time=%s swap=%s\n' "$s" \
          "${OPT[basic.server]:-auto}" "${OPT[basic.host]:-auto-generated}" \
          "${OPT[basic.time]:-Asia/Manila}" "${OPT[basic.swap]:-auto (50% of RAM)}"
        # The host-wide side effects the real run performs, so the preview is
        # not only the tunables.
        printf '  %-10s apt update/upgrade, cron/logrotate installed, automatic security updates enabled\n' ""
        printf '  %-10s DNS resolvers 8.8.8.8/1.1.1.1, UFW default deny with SSH/80/443 allowed\n' ""
        printf '  %-10s OS profile (sysctl, PAM limits, governor, udev I/O rules) and the managed root crontab\n' ""
        ;;
      php)
        printf '  %-10s version=%s children=%s max_requests=%s\n' "$s" \
          "${OPT[php.ver]:-auto (latest stable in Sury)}" \
          "${OPT[php.children]:-auto}" "${OPT[php.max_requests]:-auto}"
        ;;
      mariadb)
        bind_display=${OPT[mariadb.bind]:-127.0.0.1}
        [[ $bind_display == *IPV4* ]] && bind_display+=" (IPV4 resolved at install)"
        printf '  %-10s user=%s size=%s bind=%s\n' "$s" \
          "${OPT[mariadb.user]:-}" "${OPT[mariadb.size]:-}" "$bind_display"
        ;;
      valkey)
        printf '  %-10s ram=%s policy=%s io_threads=%s\n' "$s" \
          "${OPT[valkey.ram]:-auto (memory plan)}" \
          "${OPT[valkey.policy]:-allkeys-lru}" \
          "${OPT[valkey.io_threads]:-1}"
        ;;
      elastic)
        printf '  %-10s host=%s ram=%s\n' "$s" \
          "${OPT[elastic.host]:-localhost}" "${OPT[elastic.ram]:-auto (memory plan)}"
        ;;
      others)
        printf '  %-10s %s\n' "$s" "${OTHERS[*]:-}"
        ;;
      domain)
        for dd in "${DOMAINS[@]}"; do
          printf '  %-10s %s app=%s' "$s" "$dd" "${DOMAIN_APP[$dd]:-basic}"
          if [[ -n ${DOMAIN_DB[$dd]:-} ]]; then
            printf ' db=%s' "${DOMAIN_DB[$dd]}"
            [[ -n ${DOMAIN_DB_USER[$dd]:-} ]] && printf ' user=%s pass=***' "${DOMAIN_DB_USER[$dd]}"
            [[ -n ${DOMAIN_SQL[$dd]:-} ]] && printf ' sql=%s' "${DOMAIN_SQL[$dd]}"
          else
            printf ' (no database)'
          fi
          printf '\n'
        done
        ;;
      *)
        printf '  %-10s install\n' "$s"
        ;;
    esac
  done
}

