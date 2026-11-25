# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Opt-in compiled nginx (NGINX_BUILD=clang), 1.21.70
# ---------------------------------------------------------------------------
#   (unset)/package  the nginx package's binary (the default)
#   clang            a lean nginx compiled from upstream sources (versions in
#                    nginx-build.conf): clang from apt.llvm.org, -O3
#                    -march=native, Ubuntu's hardening flags, OpenSSL, PCRE2
#                    and zlib static, ThinLTO and BOLT, with only the modules
#                    server-configs-nginx uses.  Measured +2.2 to +12.4 % on
#                    the cached guest pages with BOLT (RESULTS.md).
# The configuration, unit and logs stay the package's; only the binary the
# unit starts changes (tools/nginx-build.sh).  Persisted as NGINX_BUILD in
# /etc/default/setup-tuning; NGINX_BUILD=package goes back and removes the
# build.

NGINX_BUILD_ROOT=${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx}
NGINX_BUILD_TOOL="${NGINX_BUILD_ROOT}/nginx-build.sh"
NGINX_BUILD_COMMON_FILE="${NGINX_BUILD_ROOT}/build-common.sh"
NGINX_BUILD_CONF_FILE="${NGINX_BUILD_ROOT}/nginx-build.conf"
NGINX_BUILD_DROPIN=${NGINX_BUILD_DROPIN:-/etc/systemd/system/nginx.service.d/zz-setup-build.conf}
NGINX_BUILD_UNIT=${NGINX_BUILD_UNIT:-/etc/systemd/system/setup-nginx-build.service}
NGINX_BUILD_REFRESH_UNIT=${NGINX_BUILD_REFRESH_UNIT:-/etc/systemd/system/setup-nginx-build-refresh.service}
NGINX_BUILD_REFRESH_TIMER=${NGINX_BUILD_REFRESH_TIMER:-/etc/systemd/system/setup-nginx-build-refresh.timer}
NGINX_BUILD_APT_HOOK=${NGINX_BUILD_APT_HOOK:-/etc/apt/apt.conf.d/99setup-nginx-build}

nginx_build_mode() {
  case ${NGINX_BUILD:-} in
    "")                      printf '' ;;
    clang|CLANG)             printf 'clang' ;;
    package|off|none|0)      printf 'package' ;;
    *)                       printf 'invalid' ;;
  esac
}

nginx_build_validate() {
  [[ $(nginx_build_mode) != invalid ]] || die "NGINX_BUILD='${NGINX_BUILD}' is not supported; use package or clang"
  return 0
}

nginx_build_persist() {
  (( ${NGINX_BUILD_PERSIST:-0} )) || return 0
  persist_tuning_var NGINX_BUILD "$(nginx_build_mode)"
  tune_note "nginx: NGINX_BUILD=$(nginx_build_mode) persisted in /etc/default/setup-tuning"
}

nginx_build_unit_text() {
  cat <<EOF
[Unit]
Description=Build the compiled nginx (setup.sh NGINX_BUILD)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${NGINX_BUILD_TOOL} rebuild
EOF
}

nginx_build_refresh_text() {
  cat <<EOF
[Unit]
Description=Check for newer upstream releases of the compiled nginx (setup.sh NGINX_BUILD)

[Service]
Type=oneshot
ExecStart=${NGINX_BUILD_TOOL} refresh
EOF
}

nginx_build_timer_text() {
  cat <<EOF
[Unit]
Description=Daily upstream release check for the compiled nginx

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

nginx_build_apt_hook_text() {
  printf 'DPkg::Post-Invoke { "if [ -x %s ]; then %s apt-hook || true; fi"; };\n' "$NGINX_BUILD_TOOL" "$NGINX_BUILD_TOOL"
}

# Write FILE with CONTENT when it differs; status 0 when it changed.
nginx_build_write() {
  [[ -f $1 && $(cat "$1") == "$2" ]] && return 1
  printf '%s\n' "$2" > "$1"
}

nginx_build_install_support() {
  local src="${SCRIPT_DIR}/tools/nginx-build.sh" changed=0
  [[ -f $src && -f ${SCRIPT_DIR}/tools/build-common.sh ]] || { warn "NGINX_BUILD: tools/nginx-build.sh is missing from this checkout"; return 1; }
  install -d -m 755 "$NGINX_BUILD_ROOT"
  cmp -s "$src" "$NGINX_BUILD_TOOL" || install -m 755 "$src" "$NGINX_BUILD_TOOL"
  cmp -s "${SCRIPT_DIR}/tools/build-common.sh" "$NGINX_BUILD_COMMON_FILE" \
    || install -m 644 "${SCRIPT_DIR}/tools/build-common.sh" "$NGINX_BUILD_COMMON_FILE"
  if [[ -f ${SCRIPT_DIR}/nginx-build.conf ]] && ! cmp -s "${SCRIPT_DIR}/nginx-build.conf" "$NGINX_BUILD_CONF_FILE"; then
    install -m 644 "${SCRIPT_DIR}/nginx-build.conf" "$NGINX_BUILD_CONF_FILE"
  fi
  nginx_build_write "$NGINX_BUILD_UNIT" "$(nginx_build_unit_text)" && changed=1
  nginx_build_write "$NGINX_BUILD_REFRESH_UNIT" "$(nginx_build_refresh_text)" && changed=1
  nginx_build_write "$NGINX_BUILD_REFRESH_TIMER" "$(nginx_build_timer_text)" && changed=1
  nginx_build_write "$NGINX_BUILD_APT_HOOK" "$(nginx_build_apt_hook_text)" || true
  (( changed )) && systemctl daemon-reload 2>/dev/null
  systemctl enable --now "${NGINX_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  return 0
}

# The LLVM toolchain is shared with the other compiled builds
# (setup_build_llvm_release).
nginx_build_remove_support() {
  systemctl disable --now "${NGINX_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  rm -f "$NGINX_BUILD_APT_HOOK" "$NGINX_BUILD_UNIT" "$NGINX_BUILD_REFRESH_UNIT" "$NGINX_BUILD_REFRESH_TIMER"
  rm -rf "${NGINX_BUILD_ROOT:?}" "${NGINX_BUILD_CACHE:-/var/cache/setup-nginx-build}"
  setup_build_llvm_release nginx
  systemctl daemon-reload 2>/dev/null || true
}

nginx_build_bolted() { grep -qx 'bolt=1' "${NGINX_BUILD_ROOT}/build/build.info" 2>/dev/null; }

# Bring nginx to the chosen binary.  CONTEXT "install" builds only;
# "optimize" also adds BOLT under traffic and makes sure the running build
# still accepts the (just synced) configuration.
nginx_build_apply() {
  local context=${1:-optimize} out=${2:-info} mode rc=0 chk="" tag
  mode=$(nginx_build_mode)
  nginx_build_persist
  case $mode in
    "") return 0 ;;
    package)
      if [[ -f $NGINX_BUILD_DROPIN || -d ${NGINX_BUILD_ROOT}/build ]]; then
        if [[ -x $NGINX_BUILD_TOOL ]] && "$NGINX_BUILD_TOOL" remove >/dev/null 2>&1; then
          "$out" "- NGINX_BUILD=package: nginx back on the package binary; build removed"
        else
          rm -f "$NGINX_BUILD_DROPIN"; systemctl daemon-reload 2>/dev/null || true
          systemctl restart nginx 2>/dev/null || true
          "$out" "- NGINX_BUILD=package: drop-in removed by hand (the tool was missing)"
        fi
      fi
      [[ -d ${NGINX_BUILD_ROOT} ]] && nginx_build_remove_support
      return 0 ;;
  esac
  nginx_build_install_support || return 1
  tag="NGINX_BUILD=clang"
  # A directive of a module the lean build leaves out: a droppable one
  # (sub_filter, ssi, limit_conn, ...) is commented out in its file and
  # reported; anything else sends nginx back to the package before anything
  # else (which restores what was commented out).
  if [[ -f $NGINX_BUILD_DROPIN ]]; then
    local fit="" line why
    if fit=$("$NGINX_BUILD_TOOL" fit 2>&1); then
      while IFS= read -r line; do
        [[ $line == *"commented out"* ]] && "$out" "- ${tag}: ${line#*nginx build: }"
      done <<< "$fit"
    else
      why=$(grep -m1 -E 'emerg|error' <<< "$fit" || true)
      "$NGINX_BUILD_TOOL" deactivate >/dev/null 2>&1 || true
      "$out" "- **${tag}: the configuration needs a module the lean build leaves out; nginx is back on the package binary** (${why:-nginx -t failed})"
      return 1
    fi
  fi
  chk=$("$NGINX_BUILD_TOOL" check 2>&1) || rc=$?
  if [[ ! -f $NGINX_BUILD_DROPIN ]] || (( rc == 10 )); then
    [[ $rc == 10 ]] && "$out" "- ${tag}: build ${chk}"
    "$out" "- ${tag}: building a lean nginx from upstream sources (about 3 minutes)"
    if "$NGINX_BUILD_TOOL" build > "${NGINX_BUILD_ROOT}/build.log" 2>&1; then
      "$out" "- ${tag}: $("$NGINX_BUILD_TOOL" status)"
    else
      "$out" "- **FAILED** ${tag} build; the package's nginx keeps serving (log: ${NGINX_BUILD_ROOT}/build.log)"
      tail -n 5 "${NGINX_BUILD_ROOT}/build.log" >&2 2>/dev/null || true
      return 1
    fi
  else
    "$out" "- ${tag}: build is current ($("$NGINX_BUILD_TOOL" status))"
  fi
  rc=0
  if [[ $context == optimize ]] && ! nginx_build_bolted && [[ ${SETUP_NGINX_BUILD_BOLT:-1} == 1 ]]; then
    "$NGINX_BUILD_TOOL" bolt "${SETUP_NGINX_BUILD_BOLT_SECONDS:-60}" > "${NGINX_BUILD_ROOT}/bolt.log" 2>&1 || rc=$?
    case $rc in
      0) "$out" "- ${tag}: BOLT applied from live traffic" ;;
      3) "$out" "- ${tag}: BOLT skipped (too little traffic in the sample); the next --optimize under load retries" ;;
      *) "$out" "- ${tag}: BOLT not applied ($(tail -n 1 "${NGINX_BUILD_ROOT}/bolt.log" 2>/dev/null)); the ThinLTO build keeps serving" ;;
    esac
    rc=0
  fi
  return "$rc"
}

# --purge nginx: the package binary is the only safe state after a purge.
nginx_build_purge() {
  [[ -f $NGINX_BUILD_DROPIN ]] && rm -f "$NGINX_BUILD_DROPIN" && info "nginx: NGINX_BUILD drop-in removed"
  [[ -d $NGINX_BUILD_ROOT ]] && nginx_build_remove_support
  return 0
}

nginx_build_plan() {
  case $(nginx_build_mode) in
    clang)   printf 'NGINX_BUILD=clang: lean nginx compiled from upstream sources (versions in nginx-build.conf); BOLT under traffic on --optimize' ;;
    package) printf 'NGINX_BUILD=package: the package nginx (any compiled build is removed)' ;;
    *)       printf '' ;;
  esac
}
