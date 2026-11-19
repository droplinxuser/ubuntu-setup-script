# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# Operator override reset and tuning drift audit
# ---------------------------------------------------------------------------
# A server tuned by an older release, or fixed by hand, can keep values that
# stop the current profile from taking effect:
#
#   * pins in /etc/default/setup-tuning (TCP_CC=cubic, QDISC=fq_codel,
#     PHP_JIT_WORDPRESS=0, ...) that a plain --optimize honours by design;
#   * explicit sizes in /var/lib/setup.sh/explicit-options.conf
#     (php_children, mariadb_size_mb, valkey_mb, elastic_mb, server_type);
#   * third-party sysctl drop-ins or units that write the same keys after
#     systemd-sysctl (tcp_congestion_control, default_qdisc, ...).
#
# `--optimize` clears the first two before every run (originals move to /tmp,
# never deleted) and re-applies every tuner; the profile is hardware-derived.
# Third-party files are left in place: configure_sysctl installs
# setup-sysctl-final.timer, which re-applies the managed profile 90 s after
# boot, so they lose at boot without breaking a Docker/cloud-init setting.
# The audit below prints every source that still defines a managed key so an
# operator can see what remains.
RESET_ACTIONS=()
# Pins that describe a host fact or a feature choice, not a performance
# override: a reset must not silently flip them.
RESET_KEEP_PINS=(
  ANUBIS ANUBIS_STATIC_BYPASS XF_JOB_CRON NODE_MAJOR NODE_ALLOW_MAJOR_UPGRADE
  CPU_MITIGATIONS XF_MEMBER_GZIP
)

# Every sysctl key this host's managed profile actually defines.  A key this
# script *may* set only for a service that is not installed (vm.max_map_count
# without Elasticsearch) is not managed here: a provider file that sets it is
# not a conflict, and reporting it with "ours=unset" was noise.
tuning_managed_keys() {
  local file
  {
    for file in /etc/sysctl.conf /etc/sysctl.d/90-setup-network.conf \
                /etc/sysctl.d/99-elasticsearch.conf; do
      [[ -r $file ]] || continue
      sysctl_file_keys "$file" || true
    done
  } | sed '/^$/d' | sort -u
}

# Value the managed profile assigns to KEY, across every file it owns.
tuning_ours_value() {
  local key=$1 file value
  for file in /etc/sysctl.conf /etc/sysctl.d/90-setup-network.conf \
              /etc/sysctl.d/99-elasticsearch.conf; do
    value=$(sysctl_file_value "$file" "$key")
    if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
  done
  return 1
}

tuning_key_is_managed() {
  local key=$1 managed
  while IFS= read -r managed; do
    if [[ $managed == "$key" ]]; then return 0; fi
  done < <(tuning_managed_keys)
  return 1
}

# Files that are written by this script and therefore never reported as a
# foreign source, even though they define managed keys.
tuning_is_own_sysctl_file() {
  case $1 in
    /etc/sysctl.conf|/etc/sysctl.d/99-sysctl.conf|\
    /etc/sysctl.d/90-setup-network.conf|/etc/sysctl.d/99-elasticsearch.conf)
      return 0 ;;
  esac
  return 1
}

# Last value of KEY in a sysctl file, normalized to single spaces.
sysctl_file_value() {
  local file=$1 key=$2 re
  [[ -r $file ]] || return 0
  re=${key//./\\.}
  sed -n -E "s/^[[:space:]]*${re}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null \
    | tail -n1 | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

# First non-managed sysctl file that defines KEY (operator space and vendor
# dirs), or nothing when only the managed profile defines it.
sysctl_foreign_source() {
  local key=$1 file
  for file in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
              /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [[ -f $file ]] || continue
    if tuning_is_own_sysctl_file "$file"; then continue; fi
    if [[ -n $(sysctl_file_value "$file" "$key") ]]; then
      printf '%s' "$file"
      return 0
    fi
  done
  return 1
}

# Print "<file>: <keys>" for every non-managed sysctl file that defines at
# least one key this script owns.  Only the operator-writable directories are
# scanned: a file shipped by a package in /usr/lib/sysctl.d (vm.max_map_count,
# ...) is not an old hand fix, and the managed profile overrides it anyway.
# Each key carries the file's value next to ours so the report answers
# "does this conflict?" without another command.
tuning_override_sources() {
  local dir file key ours theirs
  local -a dirs=(/etc/sysctl.d /run/sysctl.d)
  local -a hits=()
  local managed
  managed=$(tuning_managed_keys)
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*.conf; do
      [[ -f $file ]] || continue
      if tuning_is_own_sysctl_file "$file"; then continue; fi
      hits=()
      while IFS= read -r key; do
        [[ -n $key ]] || continue
        if grep -qxF -- "$key" <<<"$managed"; then
          ours=$(tuning_ours_value "$key" || true)
          theirs=$(sysctl_file_value "$file" "$key")
          if [[ -n $ours && $theirs == "$ours" ]]; then
            hits+=("$key(file=$theirs ours=$ours same)")
          else
            hits+=("$key(file=${theirs:-unset} ours=${ours:-unset})")
          fi
        fi
      done < <(sysctl_file_keys "$file")
      if (( ${#hits[@]} > 0 )); then
        printf '%s: %s\n' "$file" "${hits[*]}"
      fi
    done
  done
  # Units and boot scripts that write a sysctl directly after the oneshot.
  local candidate
  for candidate in /etc/rc.local /etc/systemd/system/*.service; do
    [[ -f $candidate ]] || continue
    case ${candidate##*/} in setup-*) continue ;; esac
    if grep -qE '(sysctl[[:space:]]+-w|tcp_congestion_control|default_qdisc)' "$candidate" 2>/dev/null; then
      printf '%s: writes a sysctl at boot\n' "$candidate"
    fi
  done
}

# Live managed keys whose value differs from the last definition in
# /etc/sysctl.conf.  Read-only; used by --diagnostics and the optimize report.
tuning_drift_lines() {
  local line key want live bytes_key bytes_want src
  local -a managed=()
  mapfile -t managed < <(tuning_managed_keys)
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*([A-Za-z0-9_./-]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    printf '%s\n' "${managed[@]}" | grep -qxF -- "$key" || continue
    want=$(printf '%s' "${BASH_REMATCH[2]}" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//')
    # A ratio knob reads 0 once the matching byte threshold is set (the
    # kernel swaps one for the other); that is the intended profile, not drift.
    case $key in
      vm.dirty_ratio)            bytes_key=vm.dirty_bytes ;;
      vm.dirty_background_ratio) bytes_key=vm.dirty_background_bytes ;;
      *) bytes_key="" ;;
    esac
    if [[ -n $bytes_key ]]; then
      bytes_want=$(sed -n "s/^${bytes_key}[[:space:]]*=[[:space:]]*//p" /etc/sysctl.conf | tail -n1)
      if [[ $bytes_want =~ ^[1-9][0-9]*$ ]]; then continue; fi
    fi
    live=$(sysctl -n "$key" 2>/dev/null) || continue
    live=$(printf '%s' "$live" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//')
    [[ $live == "$want" ]] && continue
    # Huge pages are a best-effort reservation: the kernel allocates what it
    # can find and leaves the sysctl at the allocated count.  A partial count
    # is not a misconfiguration; OPcache falls back when it is too small.
    if [[ $key == vm.nr_hugepages ]]; then
      printf '%s allocated=%s requested=%s (best-effort: the kernel could not reserve every page; OPcache falls back to normal pages when the reservation is too small)\n' \
        "$key" "$live" "$want"
      continue
    fi
    if src=$(sysctl_foreign_source "$key"); then
      printf '%s live=%s want=%s source=%s\n' "$key" "$live" "$want" "$src"
    else
      printf '%s live=%s want=%s source=(no sysctl file; a unit or the kernel set it)\n' \
        "$key" "$live" "$want"
    fi
  done < /etc/sysctl.conf
}

# Full read-only report: pins, explicit sizes, foreign sysctl sources and
# live drift.  Printed by --diagnostics and by a reset dry run.
tuning_overrides_report() {
  local f=/etc/default/setup-tuning ex="${STATE_DIR}/explicit-options.conf"
  printf '== operator pins: %s ==\n' "$f"
  if [[ -r $f ]]; then
    grep -vE '^[[:space:]]*(#|$)' "$f" || printf '(none)\n'
  else
    printf '(file absent)\n'
  fi
  printf '\n== explicit sizes: %s ==\n' "$ex"
  if [[ -r $ex ]]; then
    sed -n 's/^\([^#][^=]*\)=.*/\1/p' "$ex" | sort -u || true
    printf '\n'
    cat "$ex"
  else
    printf '(file absent)\n'
  fi
  printf '\n== non-managed files that define a managed sysctl ==\n'
  local sources
  sources=$(tuning_override_sources)
  if [[ -n $sources ]]; then printf '%s\n' "$sources"; else printf '(none)\n'; fi
  printf '\n== live sysctl values that differ from /etc/sysctl.conf ==\n'
  local drift
  drift=$(tuning_drift_lines | head -n 60)
  if [[ -n $drift ]]; then printf '%s\n' "$drift"; else printf '(none)\n'; fi

  # Operator PHP/Angie fragments are preserved by --optimize, so list
  # the ones that can win over the managed profile instead of silently
  # leaving them out of the report.
  printf '\n== PHP/Angie fragments that can override the managed profile ==\n'
  local pv dir f
  for pv in $(php_fpm_versions 2>/dev/null); do
    dir=/etc/php/$pv/fpm/conf.d
    for f in "$dir"/*.ini; do
      [[ -f $f ]] || continue
      if [[ ${f##*/} > zz-setup-optimize.ini ]]; then
        printf '  %s (sorts after zz-setup-optimize.ini)\n' "$f"
      fi
    done
    for f in /etc/php/"$pv"/fpm/pool.d/*.conf; do
      [[ -f $f ]] || continue
      if [[ ${f##*/} != www.conf ]]; then printf '  %s (extra PHP-FPM pool)\n' "$f"; fi
    done
  done
  for f in /etc/angie/custom.d/*.conf; do
    [[ -f $f ]] || continue
    printf '  %s (Angie custom.d)\n' "$f"
  done
}

# Add the live-vs-profile summary and the remaining foreign sources to the
# optimize report.  Shared by the with-services and OS-only paths.
opt_report_tuning_drift() {
  opt_report "## Tuning drift"
  local drift_lines override_lines line
  drift_lines=$(tuning_drift_lines | head -n 30)
  override_lines=$(tuning_override_sources | head -n 20)
  if [[ -n $drift_lines ]]; then
    opt_report "Live values that differ from \`/etc/sysctl.conf\` (a late unit may write them again):"
    while IFS= read -r line; do opt_report "- \`${line}\`"; done <<<"$drift_lines"
  else
    opt_report "- Every managed sysctl matches \`/etc/sysctl.conf\`"
  fi
  if [[ -n $override_lines ]]; then
    opt_report "Non-managed files that still define a managed sysctl (left in place; the profile wins 90 s after boot):"
    while IFS= read -r line; do opt_report "- \`${line}\`"; done <<<"$override_lines"
  fi
}

# Clear recorded operator overrides for this run.  With dry=1 only prints
# what would happen.  The original files are moved to /tmp, never deleted.
# Clear recorded operator overrides before every --optimize run.  With dry=1
# only prints what would happen; dry=2 previews without moving a file.  The
# original files are moved to /tmp, never deleted.  The profile is always
# hardware-derived: persisted pins/sizes and tuning environment variables do
# not change it.
OPTIMIZE_IGNORED_ENV=()

# Remove tuning overrides from the environment for this run and remember them
# so the report can say what was ignored.  Feature choices (ANUBIS, Node
# major, application cache/security toggles) and CONFIG_* are not listed.
optimize_ignore_tuning_env() {
  local v
  OPTIMIZE_IGNORED_ENV=()
  for v in \
    SETUP_TCP_CC SETUP_QDISC SETUP_STORAGE_CLASS \
    SETUP_PHP_WORKERS_PER_CPU \
    SETUP_PHP_JIT SETUP_PHP_JIT_WORDPRESS \
    SETUP_PHP_JIT_HOT_LOOP SETUP_PHP_JIT_HOT_FUNC \
    SETUP_PHP_JIT_HOT_RETURN SETUP_PHP_JIT_HOT_SIDE_EXIT \
    SETUP_GZIP_LEVEL SETUP_BROTLI_LEVEL SETUP_ANGIE_COMPRESSION \
    SETUP_MARIADB_IO_CAPACITY SETUP_LIMIT_REQ_EXEMPT \
    SETUP_PRECOMPRESS_ASSETS SETUP_PHP_PAGE_GZIP; do
    if [[ -n ${!v+x} ]]; then
      OPTIMIZE_IGNORED_ENV+=("$v=${!v}")
      unset "$v"
    fi
  done
  if (( ${#OPTIMIZE_IGNORED_ENV[@]} > 0 )); then
    warn "Ignoring tuning overrides for --optimize (the profile is hardware-derived): ${OPTIMIZE_IGNORED_ENV[*]}"
  fi
  return 0
}

reset_operator_overrides() {
  local dry=${1:-0}
  local f=/etc/default/setup-tuning ex="${STATE_DIR}/explicit-options.conf"
  local line key moved anubis_marker="${STATE_DIR}/anubis/enabled"
  local -a kept=() removed=()
  RESET_ACTIONS=()

  if [[ -f $f ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      case $line in
        ''|'#'*) continue ;;
        *=*)
          key=${line%%=*}
          if printf '%s\n' "${RESET_KEEP_PINS[@]}" | grep -qxF -- "$key"; then
            kept+=("$line")
          else
            removed+=("$key")
          fi
          ;;
      esac
    done < "$f"
    # A very old release may only have the state marker, not ANUBIS=1 in the
    # pin file.  Keep the filter on rather than disabling it by omission.
    if [[ -f $anubis_marker ]] \
       && ! printf '%s\n' "${kept[@]}" | grep -qE '^ANUBIS='; then
      kept+=("ANUBIS=1")
    fi
    if (( ${#removed[@]} > 0 )); then
      if (( dry )); then
        RESET_ACTIONS+=("would clear /etc/default/setup-tuning: ${removed[*]}")
      else
        moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
        if [[ -n $moved ]]; then
          if (( ${#kept[@]} > 0 )); then
            {
              printf '# Managed by setup.sh: host facts kept by the managed profile reset\n'
              printf '%s\n' "${kept[@]}"
            } > "$f"
            chmod 644 "$f"
          fi
          RESET_ACTIONS+=("cleared pins ${removed[*]} (original: ${moved})")
        else
          warn "Could not move ${f} out of the way; pins may still apply"
        fi
      fi
    fi
  fi

  if [[ ! -f $f && -f $anubis_marker ]] && (( dry == 0 )); then
    printf 'ANUBIS=1\n' > "$f"
    chmod 644 "$f"
    RESET_ACTIONS+=("created ${f} with ANUBIS=1 (state marker present)")
  fi

  if [[ -f $ex ]]; then
    local -a exkeys=()
    mapfile -t exkeys < <(sed -n 's/^\([^#][^=]*\)=.*/\1/p' "$ex" | sort -u)
    local exlist="${exkeys[*]}"
    if (( dry )); then
      RESET_ACTIONS+=("would clear explicit sizes: ${exlist}")
    else
      moved=$(preserve_to_tmp "$ex" 2>/dev/null || true)
      if [[ -n $moved ]]; then
        RESET_ACTIONS+=("cleared explicit sizes ${exlist} (original: ${moved})")
      else
        warn "Could not move ${ex} out of the way; explicit sizes may still apply"
      fi
    fi
  fi

  if (( dry != 1 )); then
    # The setup.sh process sourced /etc/default/setup-tuning before parsing
    # the command line, so the removed pins are still in memory.  Reset them
    # to the profile defaults unconditionally: --optimize must not inherit a
    # per-host tuning pin from the file or the environment.  dry=2 (the
    # --dry-run preview) does the same without moving any file, so the printed
    # memory plan matches the real run.
    TCP_CC=bbr
    QDISC=fq
    PHP_JIT_WORDPRESS=1
    PHP_PAGE_GZIP=1
    PRECOMPRESS_ASSETS=0
    LIMIT_REQ_EXEMPT=""
    unset STORAGE_CLASS 2>/dev/null || true
    if [[ -f $anubis_marker && -z ${ANUBIS_SETTING:-} ]] \
       && ! printf '%s\n' "${kept[@]}" | grep -qE '^ANUBIS=0$'; then
      ANUBIS_ENABLED=1
    fi
    RESET_ACTIONS+=("recomputed network profile: TCP_CC=${TCP_CC} QDISC=${QDISC}")
  fi

  local a
  for a in "${RESET_ACTIONS[@]}"; do
    if (( dry )); then printf '  - %s\n' "$a"; else info "profile reset: $a"; fi
  done
  if (( dry )); then
    if (( dry == 1 )); then
      printf '\nRemaining override sources (read-only audit):\n'
      tuning_overrides_report | sed 's/^/  /'
    fi
    return 0
  fi

  # Report remaining foreign sources in the run log.  They are not removed:
  # setup-sysctl-final.timer re-applies the managed profile after boot.
  local sources
  sources=$(tuning_override_sources)
  if [[ -n $sources ]]; then
    warn "Still-defined foreign sysctl sources (the managed profile wins at boot via setup-sysctl-final.timer):"
    printf '  %s\n' "$sources"
    RESET_ACTIONS+=("foreign sysctl sources kept (managed profile re-applied at boot): ${sources//$'\n'/; }")
  fi
  return 0
}
