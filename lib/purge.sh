# ---------------------------------------------------------------------------
# PURGE
# ---------------------------------------------------------------------------
apt_purge_pkgs() {
  # Disabled by design: package purging permanently deletes files and can
  # break a running server.  Keep the packages and say so in the log.
  info "Leaving package(s) installed: $*"
}

apt_purge_pattern() {
  info "Leaving packages matching '$1' installed"
}

purge_service_stop() {
  local unit=$1
  systemctl disable --now "$unit" 2>/dev/null || true
}

# Print the SSH port a recorded `ufw ...` rule line refers to and return 0,
# or return 1 when the rule is not an SSH rule.  Shared by the two purge
# passes over the recorded firewall rules.
ufw_rule_ssh_port() {
  local line=$1 p
  shift
  for p in "$@"; do
    if [[ $line =~ (^|[[:space:]])${p}(/tcp)?([[:space:]]|$) ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

purge_basic() {
  step "Purge basic setup"
  if [[ -f "${STATE_DIR}/swapfile-managed" ]]; then
    # Leave swap active and keep the /etc/fstab entry.  Turning swap off or
    # unlinking the file can leave a busy host without emergency memory.
    info "Leaving managed /swapfile and its /etc/fstab entry in place"
  else
    info "Leaving pre-existing swap configuration unchanged"
  fi

  local cur tmp rc=0
  cur=$(crontab -l 2>/dev/null || true)
  if [[ -n $cur ]]; then
    tmp=$(tmp_file)
    printf '%s\n' "$cur" | cron_strip_managed | cron_strip_legacy_jobs > "$tmp" || true
    if crontab "$tmp"; then
      info "Removed managed and legacy cron entries"
    else
      warn "Could not remove managed/legacy cron entries"
      rc=1
    fi
  fi

  # Last-resort lockout guard: if UFW is active but an SSH rule is missing,
  # add a rate-limited rule for every effective sshd port before touching the
  # remaining rules.  A custom SSH port must be protected exactly like 22.
  local -a ssh_ports=()
  mapfile -t ssh_ports < <(sshd_listen_ports)
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    local p
    for p in "${ssh_ports[@]}"; do
      if ! ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?( \(v6\))?[[:space:]]+(ALLOW|LIMIT)"; then
        ufw limit "${p}/tcp" || ufw allow "${p}/tcp" || true
      fi
    done
  fi

  if [[ -f "${STATE_DIR}/ufw-added" ]]; then
    local line
    local -a rule
    while IFS= read -r line; do
      [[ $line == ufw\ * ]] || continue
      # Never remove an SSH rule during purge.  If the provider image had no
      # SSH allow rule and UFW is active, removing ours is a guaranteed
      # lockout for a remote operator.
      if ufw_rule_ssh_port "$line" "${ssh_ports[@]}" >/dev/null; then
        info "Keeping SSH firewall rule: ${line}"
        continue
      fi
      info "Removing firewall rule: ${line}"
      read -r -a rule <<< "${line#ufw }"
      ufw delete "${rule[@]}" || true
    done < "${STATE_DIR}/ufw-added"
  fi

  # A plain SSH ALLOW rule that existed before setup was replaced by the rate
  # limit in configure_ufw().  Put it back on purge so the original firewall
  # state is restored (the limit rule is kept as the last-resort lockout guard).
  if [[ -f "${STATE_DIR}/ufw-added-before" ]]; then
    local line ssh_p
    local -a rule
    while IFS= read -r line; do
      [[ $line == ufw\ allow* ]] || continue
      ssh_p=$(ufw_rule_ssh_port "$line" "${ssh_ports[@]}") || continue
      ufw show added 2>/dev/null | grep -qxF -- "$line" && continue
      # allow and limit cannot coexist for the same port; remove the transient
      # limit before restoring the operator's original allow rule.
      if [[ -n $ssh_p ]] && ufw show added 2>/dev/null | grep -qxF "ufw limit ${ssh_p}/tcp"; then
        ufw delete limit "${ssh_p}/tcp" >/dev/null 2>&1 || true
      fi
      read -r -a rule <<< "${line#ufw }"
      ufw "${rule[@]}" || true
      info "Restored pre-existing SSH rule: ${line}"
    done < "${STATE_DIR}/ufw-added-before"
  fi
  if [[ -f "${STATE_DIR}/ufw-active-before" ]] && [[ $(<"${STATE_DIR}/ufw-active-before") == inactive ]]; then
    ufw --force disable || true
  elif [[ -f "${STATE_DIR}/ufw-defaults-before" ]]; then
    # Restore the default policies that existed before configure_ufw.
    local defaults orig_in orig_out
    defaults=$(<"${STATE_DIR}/ufw-defaults-before")
    orig_in=$(printf '%s\n' "$defaults" | sed -n 's/.*Default: \([a-z]*\) (incoming).*/\1/p')
    orig_out=$(printf '%s\n' "$defaults" | sed -n 's/.*, \([a-z]*\) (outgoing).*/\1/p')
    [[ -n $orig_in ]] && ufw --force default "$orig_in" incoming || true
    [[ -n $orig_out ]] && ufw --force default "$orig_out" outgoing || true
  fi

  # limits.conf is only restored when it provably still holds our old
  # whole-file copy (pre-drop-in releases); configure_limits applies the same
  # rule, so an operator-edited file is never overwritten with a stale snapshot.
  if [[ -f "${BACKUP_DIR}/limits.conf.recorded" ]] \
     && [[ $(<"${BACKUP_DIR}/limits.conf.recorded") == present ]] \
     && cmp -s /etc/security/limits.conf "${SCRIPT_DIR}/configs/system/limits.conf" 2>/dev/null; then
    restore_original /etc/security/limits.conf limits.conf
  fi
  restore_original /etc/security/limits.d/99-setup.conf limits.d-99-setup.conf
  restore_original /etc/sysctl.conf sysctl.conf
  restore_original /etc/sysctl.d/99-sysctl.conf sysctl.d-99-sysctl.conf
  restore_original /etc/sysctl.d/90-setup-network.conf sysctl.d-90-setup-network.conf
  restore_original /etc/modules-load.d/setup-network.conf modules-load-setup-network.conf
  restore_original /etc/logrotate.d/setup-logs logrotate-setup-logs
  # Disable the oneshots before moving their unit files out of the live
  # location; one daemon-reload after both so systemd forgets them.
  systemctl disable --now setup-network-tuning.service 2>/dev/null || true
  restore_original /etc/systemd/system/setup-network-tuning.service setup-network-tuning.service
  restore_original /etc/systemd/resolved.conf.d/dns_servers.conf dns_servers.conf
  systemctl disable --now setup-io-tuning.service 2>/dev/null || true
  restore_original /etc/systemd/system/setup-io-tuning.service setup-io-tuning.service
  restore_original /etc/udev/rules.d/60-setup-io.rules udev-60-setup-io.rules
  udevadm control --reload-rules 2>/dev/null || true
  systemctl daemon-reload || true
  # unattended-upgrades: put the APT periodic file back and disable the unit
  # only when it was not enabled before setup.sh enabled it.
  restore_original /etc/apt/apt.conf.d/20auto-upgrades apt-20auto-upgrades
  if [[ -f "${STATE_DIR}/unattended-upgrades-enabled" ]]; then
    systemctl disable --now unattended-upgrades 2>/dev/null || true
  fi
  if [[ -f "${STATE_DIR}/fstrim-timer-enabled" ]]; then
    systemctl disable --now fstrim.timer 2>/dev/null || true
  fi
  if [[ -f /etc/sysctl.conf ]]; then
    sysctl -e -p /etc/sysctl.conf || true
  fi
  # Values that were not present in the original sysctl.conf (for example
  # somaxconn) are still live in the kernel; restore the recorded originals.
  restore_sysctl_values || true

  if [[ -f "${STATE_DIR}/original-hostname" ]]; then
    local orig_host
    orig_host=$(<"${STATE_DIR}/original-hostname")
    if [[ -n $orig_host ]]; then hostnamectl set-hostname "$orig_host" || true; fi
  fi
  # configure_hostname only rewrote the 127.0.1.1 line; put that one line
  # back instead of the whole snapshot, which would discard every /etc/hosts
  # entry added since the install (cloud-init, the operator, other tools).
  if [[ -f "${BACKUP_DIR}/hosts.recorded" && -f "${BACKUP_DIR}/hosts" ]]; then
    local orig_line
    orig_line=$(grep -E '^[[:space:]]*127\.0\.1\.1[[:space:]]' "${BACKUP_DIR}/hosts" | head -n1 || true)
    sed_in_place -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
    [[ -n $orig_line ]] && printf '%s\n' "$orig_line" >> /etc/hosts
    info "Restored the 127.0.1.1 line of /etc/hosts (other entries untouched)"
  fi
  if [[ -f "${STATE_DIR}/original-timezone" ]]; then
    local orig_tz
    orig_tz=$(<"${STATE_DIR}/original-timezone")
    if [[ -n $orig_tz ]]; then timedatectl set-timezone "$orig_tz" || true; fi
  fi

  # CPU governor: stop the unit so a reboot cannot re-apply "performance",
  # put the file back, then restore the governor that was active before.
  systemctl disable --now cpufrequtils 2>/dev/null || true
  restore_original /etc/default/cpufrequtils cpufrequtils-default
  if [[ -f "${STATE_DIR}/cpufrequtils-installed" ]]; then
    apt_purge_pkgs cpufrequtils
  fi
  if [[ -s "${STATE_DIR}/original-governor" ]]; then
    local orig_gov gov_file
    orig_gov=$(<"${STATE_DIR}/original-governor")
    for gov_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
      [[ -w $gov_file ]] && printf '%s\n' "$orig_gov" > "$gov_file" 2>/dev/null
    done
    info "CPU governor restored to ${orig_gov}"
  fi

  systemctl restart systemd-resolved 2>/dev/null || true
  info "Leaving setup state in ${STATE_DIR} for a future reinstall or rollback"
  ok "Basic setup purged"
  return "$rc"
}

purge_angie() {
  step "Purge Angie"
  purge_service_stop angie
  apt_purge_pkgs angie
  # Configuration, data, caches and logs are left on disk.  Reinstalling Angie
  # then restores the exact site instead of starting from an empty tree.
  info "Leaving Angie files under /etc/angie, /var/lib/angie, /var/log/angie, /var/cache/angie and ${LOG_ROOT}/angie"
  info "Leaving cache directories and /root installer files in place"
  cron_remove_line '/etc/angie/scripts/cloudflare.sh' || true
  # Match the ownership job only: the managed wp-cron entry also starts with
  # "/usr/bin/find /var/www" and must survive an Angie-only purge (PHP keeps
  # running and DISABLE_WP_CRON stays in wp-config.php).
  cron_remove_line '/usr/bin/find /var/www -mindepth 1' || true
  cron_remove_line "$CRON_WWW_CHOWN_LEGACY" || true
  cron_remove_line "$CRON_WWW_CHOWN" || true
  cron_remove_line "$CRON_PRECOMPRESS" || true
  systemctl daemon-reload || true
  ok "Angie purged (files preserved)"
}

purge_php() {
  step "Purge PHP"
  local ver=${OPT[php.ver]:-} d v

  if [[ -n $ver ]]; then
    purge_service_stop "php${ver}-fpm"
    apt_purge_pattern "php${ver}-*"
  else
    local -a vers=()
    for d in /etc/php/*; do
      [[ -d $d ]] || continue
      v=$(basename "$d")
      [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && vers+=("$v")
    done
    for v in "${vers[@]}"; do
      purge_service_stop "php${v}-fpm"
      apt_purge_pattern "php${v}-*"
    done
  fi
  # The session GC timer is shared by every installed version; stop it only
  # when no php-fpm unit remains enabled.
  if ! systemctl list-unit-files 'php*-fpm.service' --state=enabled --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now phpsessionclean.timer 2>/dev/null || true
  fi
  systemctl daemon-reload || true
  info "Leaving PHP configuration, logs, caches and packages in place"
  ok "PHP purged (files preserved)"
}

purge_mariadb() {
  step "Purge MariaDB"
  purge_service_stop mariadb
  apt_purge_pattern 'mariadb-server*'
  apt_purge_pattern 'mariadb-client*'
  apt_purge_pattern 'mariadb-common'
  apt_purge_pattern 'mariadb-plugin-*'
  apt_purge_pkgs mysql-common
  info "Leaving MariaDB databases, configuration, backups and logs in place"

  # Drop the AppArmor override added for mariadb-install-db, while keeping any
  # operator rules outside the managed markers.
  local aflocal=/etc/apparmor.d/local/mariadbd
  if [[ -f $aflocal ]]; then
    local tmp
    tmp=$(tmp_file)
    awk -v b='# BEGIN setup.sh mariadb apparmor' -v e='# END setup.sh mariadb apparmor' '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$aflocal" > "$tmp"
    cat "$tmp" > "$aflocal"
    if [[ -f /etc/apparmor.d/mariadbd ]] && command -v apparmor_parser >/dev/null 2>&1; then
      apparmor_parser -r /etc/apparmor.d/mariadbd 2>/dev/null || true
    fi
  fi
  if [[ -f "${STATE_DIR}/lz4-installed" ]]; then
    apt_purge_pkgs lz4
  fi
  cron_remove_line '/usr/local/bin/mysqlbkup.sh' || true
  cron_remove_line '/usr/bin/mariadb-check' || true
  systemctl daemon-reload || true
  ok "MariaDB purged (files preserved)"
}

purge_valkey() {
  step "Purge Valkey"
  purge_service_stop valkey-server
  apt_purge_pattern 'valkey-*'
  # Keep the valkey group and www-data's membership.  Removing the account
  # would break a reinstall and is an account change, not an uninstall.
  info "Leaving Valkey data, configuration and logs in place"
  systemctl daemon-reload || true
  ok "Valkey purged (files preserved)"
}

purge_elastic() {
  step "Purge Elasticsearch"
  purge_service_stop elasticsearch
  apt_purge_pkgs elasticsearch
  info "Leaving Elasticsearch data, configuration and logs in place"
  systemctl daemon-reload || true
  ok "Elasticsearch purged (files preserved)"
}

purge_others() {
  step "Purge other packages"
  # Stop and disable the units install_others enabled; like every other purge
  # no package, repository, keyring or Composer file is removed.
  local unit
  for unit in smartmontools smartd sysstat-collect.timer sysstat-summary.timer sysstat; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
      systemctl disable --now "$unit" 2>/dev/null && info "Disabled ${unit}"
    fi
  done
  info "Leaving optional packages, repositories, keyrings and Composer in place"
  ok "Other packages stopped (files preserved)"
}

build_purge_order() {
  local -A wanted=()
  local t

  for t in "${PURGE_TARGETS[@]}"; do
    if [[ $t == all ]]; then
      wanted[all]=1
    else
      wanted[$t]=1
    fi
  done
  for t in angie php mariadb valkey elastic others basic; do
    if [[ ${ENABLED[$t]:-0} -eq 1 ]]; then
      wanted[$t]=1
    fi
  done
  if [[ ${#wanted[@]} -eq 0 ]]; then
    wanted[all]=1
  fi

  PURGE_ORDER=()
  if [[ -n ${wanted[all]:-} ]]; then
    # Stop dependents before the services they use.  No package is removed.
    PURGE_ORDER=(angie others php mariadb valkey elastic basic)
  else
    for t in angie others php mariadb valkey elastic basic; do
      if [[ -n ${wanted[$t]:-} ]]; then
        PURGE_ORDER+=("$t")
      fi
    done
  fi
  return 0
}

run_purge() {
  build_purge_order
  local t
  for t in "${PURGE_ORDER[@]}"; do
    case "$t" in
      basic)   purge_basic ;;
      angie)   purge_angie ;;
      php)     purge_php ;;
      mariadb) purge_mariadb ;;
      valkey)  purge_valkey ;;
      elastic) purge_elastic ;;
      others)  purge_others ;;
    esac
  done

  apt_clean
  info "Purge only stopped services; all configuration, data and log files were preserved"
  printf '\n%sPurge complete (no files were deleted).%s\n' "$C_GREEN" "$C_RESET"
}

