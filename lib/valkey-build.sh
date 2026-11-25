# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Opt-in compiled Valkey (VALKEY_BUILD=clang, --source=valkey), 1.21.71
# ---------------------------------------------------------------------------
#   (unset)/package  the Valkey package's binary (the default)
#   clang            Valkey compiled from its newest release (versions in
#                    valkey-build.conf): clang from apt.llvm.org, -O3
#                    -march=native, Ubuntu's hardening flags, LTO and BOLT,
#                    bundled jemalloc and Lua, no TLS; links only glibc.
# The configuration, unit, socket and data stay the package's; only the
# binary the unit starts changes (tools/valkey-build.sh).  Persisted as
# VALKEY_BUILD in /etc/default/setup-tuning; VALKEY_BUILD=package goes back
# and removes the build.  A host whose valkey.conf persists data stays on the
# package's X.Y series (an older server cannot read a newer RDB/AOF).

VALKEY_BUILD_ROOT=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}
VALKEY_BUILD_TOOL="${VALKEY_BUILD_ROOT}/valkey-build.sh"
VALKEY_BUILD_COMMON_FILE="${VALKEY_BUILD_ROOT}/build-common.sh"
VALKEY_BUILD_CONF_FILE="${VALKEY_BUILD_ROOT}/valkey-build.conf"
VALKEY_BUILD_DROPIN=${VALKEY_BUILD_DROPIN:-/etc/systemd/system/valkey-server.service.d/zz-setup-build.conf}
VALKEY_BUILD_UNIT=${VALKEY_BUILD_UNIT:-/etc/systemd/system/setup-valkey-build.service}
VALKEY_BUILD_REFRESH_UNIT=${VALKEY_BUILD_REFRESH_UNIT:-/etc/systemd/system/setup-valkey-build-refresh.service}
VALKEY_BUILD_REFRESH_TIMER=${VALKEY_BUILD_REFRESH_TIMER:-/etc/systemd/system/setup-valkey-build-refresh.timer}
VALKEY_BUILD_APT_HOOK=${VALKEY_BUILD_APT_HOOK:-/etc/apt/apt.conf.d/99setup-valkey-build}

valkey_build_mode() {
  case ${VALKEY_BUILD:-} in
    "")                      printf '' ;;
    clang|CLANG)             printf 'clang' ;;
    package|off|none|0)      printf 'package' ;;
    *)                       printf 'invalid' ;;
  esac
}

valkey_build_validate() {
  [[ $(valkey_build_mode) != invalid ]] || die "VALKEY_BUILD='${VALKEY_BUILD}' is not supported; use package or clang"
  return 0
}

valkey_build_persist() {
  (( ${VALKEY_BUILD_PERSIST:-0} )) || return 0
  persist_tuning_var VALKEY_BUILD "$(valkey_build_mode)"
  tune_note "Valkey: VALKEY_BUILD=$(valkey_build_mode) persisted in /etc/default/setup-tuning"
}

valkey_build_unit_text() {
  cat <<EOF
[Unit]
Description=Build the compiled Valkey (setup.sh VALKEY_BUILD)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${VALKEY_BUILD_TOOL} rebuild
EOF
}

valkey_build_refresh_text() {
  cat <<EOF
[Unit]
Description=Check for newer upstream releases of the compiled Valkey (setup.sh VALKEY_BUILD)

[Service]
Type=oneshot
ExecStart=${VALKEY_BUILD_TOOL} refresh
EOF
}

valkey_build_timer_text() {
  cat <<EOF
[Unit]
Description=Daily upstream release check for the compiled Valkey

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

valkey_build_apt_hook_text() {
  printf 'DPkg::Post-Invoke { "if [ -x %s ]; then %s apt-hook || true; fi"; };\n' "$VALKEY_BUILD_TOOL" "$VALKEY_BUILD_TOOL"
}

valkey_build_install_support() {
  local src="${SCRIPT_DIR}/tools/valkey-build.sh" changed=0
  [[ -f $src && -f ${SCRIPT_DIR}/tools/build-common.sh ]] || { warn "VALKEY_BUILD: tools/valkey-build.sh is missing from this checkout"; return 1; }
  install -d -m 755 "$VALKEY_BUILD_ROOT"
  cmp -s "$src" "$VALKEY_BUILD_TOOL" || install -m 755 "$src" "$VALKEY_BUILD_TOOL"
  cmp -s "${SCRIPT_DIR}/tools/build-common.sh" "$VALKEY_BUILD_COMMON_FILE" \
    || install -m 644 "${SCRIPT_DIR}/tools/build-common.sh" "$VALKEY_BUILD_COMMON_FILE"
  if [[ -f ${SCRIPT_DIR}/valkey-build.conf ]] && ! cmp -s "${SCRIPT_DIR}/valkey-build.conf" "$VALKEY_BUILD_CONF_FILE"; then
    install -m 644 "${SCRIPT_DIR}/valkey-build.conf" "$VALKEY_BUILD_CONF_FILE"
  fi
  angie_build_write "$VALKEY_BUILD_UNIT" "$(valkey_build_unit_text)" && changed=1
  angie_build_write "$VALKEY_BUILD_REFRESH_UNIT" "$(valkey_build_refresh_text)" && changed=1
  angie_build_write "$VALKEY_BUILD_REFRESH_TIMER" "$(valkey_build_timer_text)" && changed=1
  angie_build_write "$VALKEY_BUILD_APT_HOOK" "$(valkey_build_apt_hook_text)" || true
  (( changed )) && systemctl daemon-reload 2>/dev/null
  systemctl enable --now "${VALKEY_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  return 0
}

valkey_build_remove_support() {
  systemctl disable --now "${VALKEY_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  rm -f "$VALKEY_BUILD_APT_HOOK" "$VALKEY_BUILD_UNIT" "$VALKEY_BUILD_REFRESH_UNIT" "$VALKEY_BUILD_REFRESH_TIMER"
  rm -rf "${VALKEY_BUILD_ROOT:?}" "${VALKEY_BUILD_CACHE:-/var/cache/setup-valkey-build}"
  setup_build_llvm_release valkey
  systemctl daemon-reload 2>/dev/null || true
}

valkey_build_bolted() { grep -qx 'bolt=1' "${VALKEY_BUILD_ROOT}/build/build.info" 2>/dev/null; }

# Bring Valkey to the chosen binary (install and --optimize alike: BOLT
# profiles a valkey-benchmark run, so it needs no live traffic).  Never
# touches a Redis server: VALKEY_BUILD is for the valkey-server package.
valkey_build_apply() {
  local out=${1:-info} mode rc=0 chk="" tag="VALKEY_BUILD=clang"
  mode=$(valkey_build_mode)
  valkey_build_persist
  case $mode in
    "") return 0 ;;
    package)
      if [[ -f $VALKEY_BUILD_DROPIN || -d ${VALKEY_BUILD_ROOT}/build ]]; then
        if [[ -x $VALKEY_BUILD_TOOL ]] && "$VALKEY_BUILD_TOOL" remove >/dev/null 2>&1; then
          "$out" "- VALKEY_BUILD=package: Valkey back on the package binary; build removed"
        else
          rm -f "$VALKEY_BUILD_DROPIN"; systemctl daemon-reload 2>/dev/null || true
          systemctl restart valkey-server 2>/dev/null || true
          "$out" "- VALKEY_BUILD=package: drop-in removed by hand (the tool was missing)"
        fi
      fi
      [[ -d ${VALKEY_BUILD_ROOT} ]] && valkey_build_remove_support
      return 0 ;;
  esac
  if [[ ! -x /usr/bin/valkey-server ]]; then
    "$out" "- ${tag}: skipped (no valkey-server package; a Redis server is never replaced)"
    return 0
  fi
  valkey_build_install_support || return 1
  chk=$("$VALKEY_BUILD_TOOL" check 2>&1) || rc=$?
  if [[ ! -f $VALKEY_BUILD_DROPIN ]] || (( rc == 10 )); then
    [[ $rc == 10 ]] && "$out" "- ${tag}: build ${chk}"
    "$out" "- ${tag}: building Valkey from its upstream release (about 2 minutes)"
    if "$VALKEY_BUILD_TOOL" build > "${VALKEY_BUILD_ROOT}/build.log" 2>&1; then
      "$out" "- ${tag}: $("$VALKEY_BUILD_TOOL" status)"
    else
      "$out" "- **FAILED** ${tag} build; the package's Valkey keeps serving (log: ${VALKEY_BUILD_ROOT}/build.log)"
      tail -n 5 "${VALKEY_BUILD_ROOT}/build.log" >&2 2>/dev/null || true
      return 1
    fi
  else
    "$out" "- ${tag}: build is current ($("$VALKEY_BUILD_TOOL" status))"
  fi
  rc=0
  if ! valkey_build_bolted && [[ ${SETUP_VALKEY_BUILD_BOLT:-1} == 1 ]]; then
    "$VALKEY_BUILD_TOOL" bolt > "${VALKEY_BUILD_ROOT}/bolt.log" 2>&1 || rc=$?
    case $rc in
      0) "$out" "- ${tag}: BOLT applied (profile of a valkey-benchmark run)" ;;
      *) "$out" "- ${tag}: BOLT not applied ($(tail -n 1 "${VALKEY_BUILD_ROOT}/bolt.log" 2>/dev/null)); the LTO build keeps serving" ;;
    esac
    rc=0
  fi
  return "$rc"
}

valkey_build_purge() {
  [[ -f $VALKEY_BUILD_DROPIN ]] && rm -f "$VALKEY_BUILD_DROPIN" && info "Valkey: VALKEY_BUILD drop-in removed"
  [[ -d $VALKEY_BUILD_ROOT ]] && valkey_build_remove_support
  return 0
}

valkey_build_plan() {
  case $(valkey_build_mode) in
    clang)   printf 'VALKEY_BUILD=clang: Valkey compiled from its newest release (valkey-build.conf), LTO + BOLT' ;;
    package) printf 'VALKEY_BUILD=package: the package Valkey (any compiled build is removed)' ;;
    *)       printf '' ;;
  esac
}
