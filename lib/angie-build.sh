# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Opt-in compiled Angie (ANGIE_BUILD=clang), 1.21.70
# ---------------------------------------------------------------------------
#   (unset)/package  the Angie package's binary (the default)
#   clang            a lean Angie compiled from upstream sources (versions in
#                    angie-build.conf): clang from apt.llvm.org, -O3
#                    -march=native, Ubuntu's hardening flags, OpenSSL, PCRE2
#                    and zlib static, ThinLTO and BOLT, with only the modules
#                    server-configs-nginx uses.  Measured +2.2 to +12.4 % on
#                    the cached guest pages with BOLT (RESULTS.md).
# The configuration, unit and logs stay the package's; only the binary the
# unit starts changes (tools/angie-build.sh).  Persisted as ANGIE_BUILD in
# /etc/default/setup-tuning; ANGIE_BUILD=package goes back and removes the
# build.

ANGIE_BUILD_ROOT=${ANGIE_BUILD_ROOT:-/usr/local/lib/setup-angie}
ANGIE_BUILD_TOOL="${ANGIE_BUILD_ROOT}/angie-build.sh"
ANGIE_BUILD_COMMON_FILE="${ANGIE_BUILD_ROOT}/build-common.sh"
ANGIE_BUILD_CONF_FILE="${ANGIE_BUILD_ROOT}/angie-build.conf"
ANGIE_BUILD_DROPIN=${ANGIE_BUILD_DROPIN:-/etc/systemd/system/angie.service.d/zz-setup-build.conf}
ANGIE_BUILD_UNIT=${ANGIE_BUILD_UNIT:-/etc/systemd/system/setup-angie-build.service}
ANGIE_BUILD_REFRESH_UNIT=${ANGIE_BUILD_REFRESH_UNIT:-/etc/systemd/system/setup-angie-build-refresh.service}
ANGIE_BUILD_REFRESH_TIMER=${ANGIE_BUILD_REFRESH_TIMER:-/etc/systemd/system/setup-angie-build-refresh.timer}
ANGIE_BUILD_APT_HOOK=${ANGIE_BUILD_APT_HOOK:-/etc/apt/apt.conf.d/99setup-angie-build}

angie_build_mode() {
  case ${ANGIE_BUILD:-} in
    "")                      printf '' ;;
    clang|CLANG)             printf 'clang' ;;
    package|off|none|0)      printf 'package' ;;
    *)                       printf 'invalid' ;;
  esac
}

angie_build_validate() {
  [[ $(angie_build_mode) != invalid ]] || die "ANGIE_BUILD='${ANGIE_BUILD}' is not supported; use package or clang"
  return 0
}

angie_build_persist() {
  (( ${ANGIE_BUILD_PERSIST:-0} )) || return 0
  persist_tuning_var ANGIE_BUILD "$(angie_build_mode)"
  tune_note "Angie: ANGIE_BUILD=$(angie_build_mode) persisted in /etc/default/setup-tuning"
}

angie_build_unit_text() {
  cat <<EOF
[Unit]
Description=Build the compiled Angie (setup.sh ANGIE_BUILD)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${ANGIE_BUILD_TOOL} rebuild
EOF
}

angie_build_refresh_text() {
  cat <<EOF
[Unit]
Description=Check for newer upstream releases of the compiled Angie (setup.sh ANGIE_BUILD)

[Service]
Type=oneshot
ExecStart=${ANGIE_BUILD_TOOL} refresh
EOF
}

angie_build_timer_text() {
  cat <<EOF
[Unit]
Description=Daily upstream release check for the compiled Angie

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

angie_build_apt_hook_text() {
  printf 'DPkg::Post-Invoke { "if [ -x %s ]; then %s apt-hook || true; fi"; };\n' "$ANGIE_BUILD_TOOL" "$ANGIE_BUILD_TOOL"
}

# Write FILE with CONTENT when it differs; status 0 when it changed.
angie_build_write() {
  [[ -f $1 && $(cat "$1") == "$2" ]] && return 1
  printf '%s\n' "$2" > "$1"
}

angie_build_install_support() {
  local src="${SCRIPT_DIR}/tools/angie-build.sh" changed=0
  [[ -f $src && -f ${SCRIPT_DIR}/tools/build-common.sh ]] || { warn "ANGIE_BUILD: tools/angie-build.sh is missing from this checkout"; return 1; }
  install -d -m 755 "$ANGIE_BUILD_ROOT"
  cmp -s "$src" "$ANGIE_BUILD_TOOL" || install -m 755 "$src" "$ANGIE_BUILD_TOOL"
  cmp -s "${SCRIPT_DIR}/tools/build-common.sh" "$ANGIE_BUILD_COMMON_FILE" \
    || install -m 644 "${SCRIPT_DIR}/tools/build-common.sh" "$ANGIE_BUILD_COMMON_FILE"
  if [[ -f ${SCRIPT_DIR}/angie-build.conf ]] && ! cmp -s "${SCRIPT_DIR}/angie-build.conf" "$ANGIE_BUILD_CONF_FILE"; then
    install -m 644 "${SCRIPT_DIR}/angie-build.conf" "$ANGIE_BUILD_CONF_FILE"
  fi
  angie_build_write "$ANGIE_BUILD_UNIT" "$(angie_build_unit_text)" && changed=1
  angie_build_write "$ANGIE_BUILD_REFRESH_UNIT" "$(angie_build_refresh_text)" && changed=1
  angie_build_write "$ANGIE_BUILD_REFRESH_TIMER" "$(angie_build_timer_text)" && changed=1
  angie_build_write "$ANGIE_BUILD_APT_HOOK" "$(angie_build_apt_hook_text)" || true
  (( changed )) && systemctl daemon-reload 2>/dev/null
  systemctl enable --now "${ANGIE_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  return 0
}

# The LLVM toolchain is shared with the other compiled builds
# (setup_build_llvm_release).
angie_build_remove_support() {
  systemctl disable --now "${ANGIE_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  rm -f "$ANGIE_BUILD_APT_HOOK" "$ANGIE_BUILD_UNIT" "$ANGIE_BUILD_REFRESH_UNIT" "$ANGIE_BUILD_REFRESH_TIMER"
  rm -rf "${ANGIE_BUILD_ROOT:?}" "${ANGIE_BUILD_CACHE:-/var/cache/setup-angie-build}"
  setup_build_llvm_release angie
  systemctl daemon-reload 2>/dev/null || true
}

angie_build_bolted() { grep -qx 'bolt=1' "${ANGIE_BUILD_ROOT}/build/build.info" 2>/dev/null; }

# Bring Angie to the chosen binary.  CONTEXT "install" builds only;
# "optimize" also adds BOLT under traffic and makes sure the running build
# still accepts the (just synced) configuration.
angie_build_apply() {
  local context=${1:-optimize} out=${2:-info} mode rc=0 chk="" tag
  mode=$(angie_build_mode)
  angie_build_persist
  case $mode in
    "") return 0 ;;
    package)
      if [[ -f $ANGIE_BUILD_DROPIN || -d ${ANGIE_BUILD_ROOT}/build ]]; then
        if [[ -x $ANGIE_BUILD_TOOL ]] && "$ANGIE_BUILD_TOOL" remove >/dev/null 2>&1; then
          "$out" "- ANGIE_BUILD=package: Angie back on the package binary; build removed"
        else
          rm -f "$ANGIE_BUILD_DROPIN"; systemctl daemon-reload 2>/dev/null || true
          systemctl restart angie 2>/dev/null || true
          "$out" "- ANGIE_BUILD=package: drop-in removed by hand (the tool was missing)"
        fi
      fi
      [[ -d ${ANGIE_BUILD_ROOT} ]] && angie_build_remove_support
      return 0 ;;
  esac
  angie_build_install_support || return 1
  tag="ANGIE_BUILD=clang"
  # A directive of a module the lean build leaves out: a droppable one
  # (sub_filter, ssi, limit_conn, ...) is commented out in its file and
  # reported; anything else sends Angie back to the package before anything
  # else (which restores what was commented out).
  if [[ -f $ANGIE_BUILD_DROPIN ]]; then
    local fit="" line why
    if fit=$("$ANGIE_BUILD_TOOL" fit 2>&1); then
      while IFS= read -r line; do
        [[ $line == *"commented out"* ]] && "$out" "- ${tag}: ${line#*Angie build: }"
      done <<< "$fit"
    else
      why=$(grep -m1 -E 'emerg|error' <<< "$fit" || true)
      "$ANGIE_BUILD_TOOL" deactivate >/dev/null 2>&1 || true
      "$out" "- **${tag}: the configuration needs a module the lean build leaves out; Angie is back on the package binary** (${why:-angie -t failed})"
      return 1
    fi
  fi
  chk=$("$ANGIE_BUILD_TOOL" check 2>&1) || rc=$?
  if [[ ! -f $ANGIE_BUILD_DROPIN ]] || (( rc == 10 )); then
    [[ $rc == 10 ]] && "$out" "- ${tag}: build ${chk}"
    "$out" "- ${tag}: building a lean Angie from upstream sources (about 3 minutes)"
    if "$ANGIE_BUILD_TOOL" build > "${ANGIE_BUILD_ROOT}/build.log" 2>&1; then
      "$out" "- ${tag}: $("$ANGIE_BUILD_TOOL" status)"
    else
      "$out" "- **FAILED** ${tag} build; the package's Angie keeps serving (log: ${ANGIE_BUILD_ROOT}/build.log)"
      tail -n 5 "${ANGIE_BUILD_ROOT}/build.log" >&2 2>/dev/null || true
      return 1
    fi
  else
    "$out" "- ${tag}: build is current ($("$ANGIE_BUILD_TOOL" status))"
  fi
  rc=0
  if [[ $context == optimize ]] && ! angie_build_bolted && [[ ${SETUP_ANGIE_BUILD_BOLT:-1} == 1 ]]; then
    "$ANGIE_BUILD_TOOL" bolt "${SETUP_ANGIE_BUILD_BOLT_SECONDS:-60}" > "${ANGIE_BUILD_ROOT}/bolt.log" 2>&1 || rc=$?
    case $rc in
      0) "$out" "- ${tag}: BOLT applied from live traffic" ;;
      3) "$out" "- ${tag}: BOLT skipped (too little traffic in the sample); the next --optimize under load retries" ;;
      *) "$out" "- ${tag}: BOLT not applied ($(tail -n 1 "${ANGIE_BUILD_ROOT}/bolt.log" 2>/dev/null)); the ThinLTO build keeps serving" ;;
    esac
    rc=0
  fi
  return "$rc"
}

# --purge angie: the package binary is the only safe state after a purge.
angie_build_purge() {
  [[ -f $ANGIE_BUILD_DROPIN ]] && rm -f "$ANGIE_BUILD_DROPIN" && info "Angie: ANGIE_BUILD drop-in removed"
  [[ -d $ANGIE_BUILD_ROOT ]] && angie_build_remove_support
  return 0
}

angie_build_plan() {
  case $(angie_build_mode) in
    clang)   printf 'ANGIE_BUILD=clang: lean Angie compiled from upstream sources (versions in angie-build.conf); BOLT under traffic on --optimize' ;;
    package) printf 'ANGIE_BUILD=package: the package Angie (any compiled build is removed)' ;;
    *)       printf '' ;;
  esac
}
