# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Valkey compiled from source (1.22.0): the only Valkey setup.sh installs.
# ---------------------------------------------------------------------------
# tools/valkey-build.sh builds the newest Valkey release (versions in
# valkey-build.conf; a host whose valkey.conf runs AOF stays on the series
# of the server that wrote it, and no host goes below that version) with
# clang from apt.llvm.org, -O3 -march=native, Ubuntu's hardening flags,
# LTO and BOLT, bundled jemalloc and Lua, no TLS; it links only glibc.  It
# installs valkey-server, valkey-cli, valkey-benchmark, valkey-check-aof
# and valkey-check-rdb into
# /usr/local/lib/setup-valkey/bin (links in /usr/local/bin), writes our own
# valkey-server.service (Alias valkey.service), creates the valkey user and
# group and seeds /etc/valkey/valkey.conf on a host without one.  The
# managed keys in valkey.conf stay with valkey_apply_config (lib/services.sh).
# There is no package mode and no fallback binary: a failed build stops the
# install with the log path, and a CPU change keeps Valkey down until
# setup-build-cpu.service has rebuilt it.
#
# Interfaces (callers: install_valkey, optimize_valkey, lib/migrate.sh,
# purge, diagnostics, the dry-run plan):
#   valkey_build_ensure MODE CONTEXT OUT   MODE build-only|activate|full|bolt
#   valkey_build_layout                    user, dirs, valkey.conf seed, unit, links
#   valkey_build_plan                      one dry-run line
#   valkey_build_status                    read-only state (diagnostics)
#   valkey_build_purge                     --purge valkey
#   valkey_build_retire_legacy             1.21 triggers (APT hook, timers)
#   valkey_build_retire_legacy_layout OUT  1.21 layout to the backups (after a verified start)
#   VALKEY_CLI_BIN / VALKEY_SERVER_BIN     absolute paths every caller uses

VALKEY_BUILD_ROOT=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}
VALKEY_BUILD_TOOL="${VALKEY_BUILD_ROOT}/valkey-build.sh"
VALKEY_BUILD_COMMON_FILE="${VALKEY_BUILD_ROOT}/build-common.sh"
VALKEY_BUILD_CONF_FILE="${VALKEY_BUILD_ROOT}/valkey-build.conf"
VALKEY_BUILD_INFO="${VALKEY_BUILD_ROOT}/build.info"
VALKEY_BUILD_LOG_DIR="${VALKEY_BUILD_ROOT}/logs"
VALKEY_BUILD_CACHE=${VALKEY_BUILD_CACHE:-/var/cache/setup-valkey-build}
# shellcheck disable=SC2034 # used by services, diagnostics, migrate
VALKEY_SERVER_BIN="${VALKEY_BUILD_ROOT}/bin/valkey-server"
# shellcheck disable=SC2034 # used by services, optimizers, diagnostics, migrate
VALKEY_CLI_BIN="${VALKEY_BUILD_ROOT}/bin/valkey-cli"
VALKEY_BUILD_LINK_DIR=${VALKEY_BUILD_LINK_DIR:-/usr/local/bin}
VALKEY_BUILD_SYSTEMD_DIR=${VALKEY_BUILD_SYSTEMD_DIR:-/etc/systemd/system}
VALKEY_SERVER_UNIT_FILE="${VALKEY_BUILD_SYSTEMD_DIR}/valkey-server.service"
VALKEY_BUILD_UNIT_MARKER='# setup-valkey-unit 1.22'
# On-demand background rebuild (build, activate, BOLT) under the build lock.
VALKEY_BUILD_UNIT=${VALKEY_BUILD_UNIT:-${VALKEY_BUILD_SYSTEMD_DIR}/setup-valkey-build.service}
# What 1.21.71 installed (VALKEY_BUILD=clang): triggers retired on every run,
# the old binary layout and its drop-in only at the cutover.
VALKEY_BUILD_LEGACY_DIR="${VALKEY_BUILD_ROOT}/build"
VALKEY_BUILD_LEGACY_DROPIN=${VALKEY_BUILD_LEGACY_DROPIN:-${VALKEY_BUILD_SYSTEMD_DIR}/valkey-server.service.d/zz-setup-build.conf}
VALKEY_BUILD_LEGACY_APT_HOOK=${VALKEY_BUILD_LEGACY_APT_HOOK:-/etc/apt/apt.conf.d/99setup-valkey-build}
VALKEY_BUILD_LEGACY_REFRESH_UNIT=${VALKEY_BUILD_LEGACY_REFRESH_UNIT:-${VALKEY_BUILD_SYSTEMD_DIR}/setup-valkey-build-refresh.service}
VALKEY_BUILD_LEGACY_REFRESH_TIMER=${VALKEY_BUILD_LEGACY_REFRESH_TIMER:-${VALKEY_BUILD_SYSTEMD_DIR}/setup-valkey-build-refresh.timer}
VALKEY_BUILD_BACKUPS=${VALKEY_BUILD_BACKUPS:-/var/backups/setup-1.22}

# Write FILE only when CONTENT differs; 0 when it changed.
valkey_build_write() {
  [[ -f $1 && $(cat "$1") == "$2" ]] && return 1
  printf '%s\n' "$2" > "$1"
}

# OUT is a report function (info, opt_report).  A caller that collects the
# lines in a file passes its path instead; both work, so no report line (a
# failure reason, a log path) is lost to "Permission denied".
valkey_build_report() { # out message
  local out=${1:-info}
  shift
  if [[ $out == */* ]] && ! declare -F "$out" >/dev/null; then
    printf '%s\n' "$*" >> "$out"
  else
    "$out" "$*"
  fi
}

VALKEY_BUILD_UNIT_MARK='# setup-valkey-build-unit 1.22'
valkey_build_unit_text() {
  cat <<EOF
$VALKEY_BUILD_UNIT_MARK
[Unit]
Description=Rebuild the compiled Valkey (setup.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
OOMScoreAdjust=900
TimeoutStartSec=2h
ExecStart=${VALKEY_BUILD_TOOL} rebuild
EOF
}

valkey_unit_is_ours() { [[ -f $VALKEY_SERVER_UNIT_FILE ]] && grep -qxF "$VALKEY_BUILD_UNIT_MARKER" "$VALKEY_SERVER_UNIT_FILE"; }
valkey_pkg_installed() { dpkg-query -W -f='${Status}' "${1:-valkey-server}" 2>/dev/null | grep -q ' installed$'; }
valkey_build_info_get() { [[ -f $VALKEY_BUILD_INFO ]] && awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$VALKEY_BUILD_INFO"; return 0; }
valkey_build_bolted() { [[ $(valkey_build_info_get bolt) == 1 ]]; }
valkey_build_last_log() { ls -1t "$VALKEY_BUILD_LOG_DIR"/valkey-*.log 2>/dev/null | sed -n 1p; }

# Tool, build-common and the version file into the root (only when they
# changed), plus the on-demand build unit.  No timer here: the shared
# setup-build-refresh.timer calls "valkey-build.sh refresh", and the CPU
# chain (setup-build-cpu.service) "valkey-build.sh rebuild-cpu".
valkey_build_install_support() {
  local src="${SCRIPT_DIR}/tools/valkey-build.sh"
  # A 1.21 job of the same unit name may be running (its APT hook started it
  # with --no-block); it must end before the file and the tool under it are
  # replaced.
  valkey_build_stop_legacy_build_unit
  [[ -f $src && -f ${SCRIPT_DIR}/tools/build-common.sh ]] || { warn "Valkey: tools/valkey-build.sh is missing from this checkout"; return 1; }
  install -d -m 755 "$VALKEY_BUILD_ROOT"
  # build-common.sh before the tool: a new tool needs the new helpers
  # (cpu_fingerprint_matches, 1.22.4) and the new build-common.sh still
  # serves the old tool, so this order has no window where the unit's
  # ExecStartPre misreads a missing helper as a CPU change.
  cmp -s "${SCRIPT_DIR}/tools/build-common.sh" "$VALKEY_BUILD_COMMON_FILE" \
    || install -m 644 "${SCRIPT_DIR}/tools/build-common.sh" "$VALKEY_BUILD_COMMON_FILE"
  cmp -s "$src" "$VALKEY_BUILD_TOOL" || install -m 755 "$src" "$VALKEY_BUILD_TOOL"
  if [[ -f ${SCRIPT_DIR}/valkey-build.conf ]] && ! cmp -s "${SCRIPT_DIR}/valkey-build.conf" "$VALKEY_BUILD_CONF_FILE"; then
    install -m 644 "${SCRIPT_DIR}/valkey-build.conf" "$VALKEY_BUILD_CONF_FILE"
  fi
  if valkey_build_write "$VALKEY_BUILD_UNIT" "$(valkey_build_unit_text)"; then
    systemctl daemon-reload 2>/dev/null || true
  fi
  return 0
}

# 1.21 shipped an on-demand setup-valkey-build.service of the same name
# (ExecStart=ROOT/valkey-build.sh rebuild), which its APT hook could start
# during fleet-update's apt phase.  Such a job runs the 1.21 code outside
# /run/setup-build.lock: it rewrites ROOT/build and the zz-setup-build.conf
# drop-in and restarts valkey-server, possibly in the middle of a 1.22 build
# or the cutover (R3 (b)).  A unit file without our marker is that one: stop
# it (systemctl stop waits for a oneshot), killing it after 3 minutes.
valkey_build_stop_legacy_build_unit() {
  local u=${VALKEY_BUILD_UNIT##*/}
  [[ -f $VALKEY_BUILD_UNIT ]] || return 0
  grep -qxF "$VALKEY_BUILD_UNIT_MARK" "$VALKEY_BUILD_UNIT" 2>/dev/null && return 0
  case $(systemctl show -p ActiveState --value "$u" 2>/dev/null) in
    active|activating|deactivating|reloading) ;;
    *) return 0 ;;
  esac
  warn "Valkey: stopping a running 1.21 ${u} job before its file is replaced"
  timeout 180 systemctl stop "$u" >/dev/null 2>&1 \
    || systemctl kill -s KILL "$u" >/dev/null 2>&1 || true
  return 0
}

# 1.21.71's triggers: the APT hook (it deleted the build when the package
# binary disappeared, so it must be gone before the package is removed), the
# daily refresh timer, and transient fallback units.  The old binary layout
# and its drop-in are left to the cutover: on a 1.21 clang host they still
# serve (a restart in between would otherwise run the package binary).
valkey_build_retire_legacy() {
  local u changed=0
  [[ -f $VALKEY_BUILD_LEGACY_APT_HOOK ]] && rm -f "$VALKEY_BUILD_LEGACY_APT_HOOK"
  valkey_build_stop_legacy_build_unit
  if [[ -f $VALKEY_BUILD_LEGACY_REFRESH_TIMER || -f $VALKEY_BUILD_LEGACY_REFRESH_UNIT ]]; then
    systemctl disable --now "${VALKEY_BUILD_LEGACY_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
    systemctl stop "${VALKEY_BUILD_LEGACY_REFRESH_UNIT##*/}" >/dev/null 2>&1 || true
    rm -f "$VALKEY_BUILD_LEGACY_REFRESH_TIMER" "$VALKEY_BUILD_LEGACY_REFRESH_UNIT"
    changed=1
  fi
  while IFS= read -r u; do
    [[ -n $u ]] && systemctl stop "$u" >/dev/null 2>&1 || true
  done < <(systemctl list-units --all --plain --no-legend 'setup-valkey-fallback-*' 2>/dev/null | awk '{ print $1 }')
  (( changed )) && systemctl daemon-reload 2>/dev/null
  return 0
}

# After a verified cutover: the 1.21 layout goes to the backups (0700 root).
# Never inside the migration's activate: lib/migrate.sh verifies the
# running executable, PING and the dataset first and may still roll back to
# the 1.21 state, so it moves the old layout itself once that passes (or
# calls this then).  install/--optimize call it after their verified start.
valkey_build_retire_legacy_layout() {
  local out=${1:-info} dest
  valkey_unit_is_ours && systemctl is-active --quiet valkey-server 2>/dev/null || return 0
  rm -f "$VALKEY_BUILD_LEGACY_DROPIN"
  [[ -d $VALKEY_BUILD_LEGACY_DIR ]] || return 0
  install -d -m 700 "$VALKEY_BUILD_BACKUPS"
  dest="${VALKEY_BUILD_BACKUPS}/valkey-build-1.21-$(date +%Y%m%d%H%M%S)"
  mv "$VALKEY_BUILD_LEGACY_DIR" "$dest" && valkey_build_report "$out" "- Valkey: the 1.21 build moved to ${dest}"
  return 0
}

# User/group, /var/lib/valkey, the log directory, /etc/valkey (valkey.conf
# seeded only when missing), our unit (enabled, not started) and the
# /usr/local/bin links.  Needs an installed tool; never starts the service.
valkey_build_layout() {
  valkey_build_install_support || return 1
  VALKEY_LIMIT_NOFILE=$(nofile_unit valkey 2>/dev/null || printf 524288) "$VALKEY_BUILD_TOOL" layout >/dev/null
}

# Run one tool command; its output goes to ROOT/logs/ensure-<cmd>.log (the
# compile itself logs to ROOT/logs/valkey-<version>-<stamp>.log).
valkey_build_run() { # out command [args]
  local out=$1 cmd=$2 rc=0 f
  shift 2
  install -d -m 750 "$VALKEY_BUILD_LOG_DIR"
  f="${VALKEY_BUILD_LOG_DIR}/ensure-${cmd}.log"
  env VALKEY_LIMIT_NOFILE="$(nofile_unit valkey 2>/dev/null || printf 524288)" \
    VALKEY_BUILD_CUTOVER="${VALKEY_BUILD_CUTOVER_FLAG:-0}" VALKEY_BUILD_NO_START="${VALKEY_BUILD_CUTOVER_FLAG:-0}" \
    "$VALKEY_BUILD_TOOL" "$cmd" "$@" > "$f" 2>&1 || rc=$?
  if (( rc != 0 )); then
    tail -n 8 "$f" >&2 2>/dev/null || true
    valkey_build_report "$out" "- **FAILED** Valkey ${cmd} (log: $(valkey_build_last_log || true); tool output: ${f})"
  fi
  return "$rc"
}

# MODE   build-only  build and verify into ROOT/staging (nothing serves from
#                    it; migration step 4 while the package still serves)
#        activate    staging (or the current build) into place, unit and
#                    layout, (re)start, PING; never BOLT
#        full        build when stale, activate, BOLT (install, --optimize)
#        bolt        BOLT only (after the migration; never fails)
# CONTEXT install|optimize|migrate|domain|...  migrate allows the activate to
#        replace the valkey-server package's unit (the migration stopped the
#        package server and took its snapshot first); the activate then
#        installs and enables without starting, and leaves the 1.21 layout
#        in place (lib/migrate.sh starts, verifies and moves it).
# OUT    report function (info, opt_report), or a file path to append to.
# Returns 1 when a build or the activation failed.
valkey_build_ensure() {
  local mode=${1:-full} context=${2:-install} out=${3:-info} chk="" rc=0
  case $mode in build-only|activate|full|bolt) ;; *) valkey_build_report "$out" "- Valkey: unknown build mode ${mode}"; return 1 ;; esac
  # Ubuntu's redis-server is replaced only by the 1.22 migration (1.22.17),
  # which stops it and carries its dataset first.  Everywhere else a Redis
  # host keeps Redis (tuned as Redis): also after a rolled-back replacement,
  # whose build stays on disk but must never start beside it.
  if [[ $context != migrate ]] && valkey_pkg_installed redis-server && ! valkey_pkg_installed valkey-server \
     && ! valkey_unit_is_ours; then
    valkey_build_report "$out" "- Valkey: skipped (redis-server serves; the 1.22 migration of --optimize replaces it when it can)"
    return 0
  fi
  valkey_build_retire_legacy
  valkey_build_install_support || return 1

  if [[ $mode == build-only || $mode == full ]]; then
    chk=$("$VALKEY_BUILD_TOOL" check 2>/dev/null) || rc=$?
    case $rc in
      0)  if [[ $chk == staged* ]]; then valkey_build_report "$out" "- Valkey: ${chk}"
          else valkey_build_report "$out" "- Valkey: build is current ($("$VALKEY_BUILD_TOOL" status))"
          fi ;;
      2)  valkey_build_report "$out" "- Valkey: upstream version lookup failed (offline?); the current build stays" ;;
      11) valkey_build_report "$out" "- Valkey: ${chk}; fetching it"
          valkey_build_run "$out" fetch || valkey_build_report "$out" "- Valkey: cache not completed; a CPU change would need the network" ;;
      *)  [[ $chk == stale:* ]] && valkey_build_report "$out" "- Valkey: build ${chk}"
          valkey_build_report "$out" "- Valkey: building from its upstream release (about 2 minutes)"
          valkey_build_run "$out" build || return 1
          valkey_build_report "$out" "- Valkey: $(grep -m1 'built with clang' "${VALKEY_BUILD_LOG_DIR}/ensure-build.log" 2>/dev/null || echo 'build verified and staged')" ;;
    esac
    [[ $mode == build-only ]] && return 0
  fi

  if [[ $mode == activate || $mode == full ]]; then
    if [[ $context != migrate ]] && valkey_pkg_installed valkey-server && ! valkey_unit_is_ours; then
      valkey_build_report "$out" "- Valkey: the valkey-server package still serves; the 1.22 migration switches it to this build"
      return 0
    fi
    # migrate: the cutover may replace the package's unit (the migration
    # stopped the package server and took its snapshot first), and the
    # tool installs without starting: lib/migrate.sh starts the unit and
    # verifies it (executable path, PING, DBSIZE) and owns the rollback.
    local VALKEY_BUILD_CUTOVER_FLAG=0
    [[ $context == migrate ]] && VALKEY_BUILD_CUTOVER_FLAG=1
    valkey_build_run "$out" activate || return 1
    valkey_build_report "$out" "- Valkey: $("$VALKEY_BUILD_TOOL" status)"
    # Local PHP workers reach the socket through the valkey group; they pick
    # up a new membership only on a restart.
    if declare -F valkey_ensure_www_group >/dev/null && valkey_ensure_www_group valkey \
       && declare -F restart_php_workers_for_group >/dev/null; then
      restart_php_workers_for_group valkey
    fi
    # The 1.21 layout leaves only after a verified start; in the migration
    # that verification is lib/migrate.sh's, after this returns.
    [[ $context == migrate ]] || valkey_build_retire_legacy_layout "$out"
    # BOLT never runs inside the migration (a separate pass after it).
    [[ $mode == activate || $context == migrate ]] && return 0
  fi

  if valkey_build_bolted || [[ ${SETUP_VALKEY_BUILD_BOLT:-1} != 1 ]]; then return 0; fi
  if [[ $mode == bolt ]] && ! valkey_unit_is_ours; then return 0; fi
  rc=0
  install -d -m 750 "$VALKEY_BUILD_LOG_DIR"
  "$VALKEY_BUILD_TOOL" bolt > "${VALKEY_BUILD_LOG_DIR}/ensure-bolt.log" 2>&1 || rc=$?
  case $rc in
    0) valkey_build_report "$out" "- Valkey: BOLT applied (profile of a valkey-benchmark run)" ;;
    *) valkey_build_report "$out" "- Valkey: BOLT not applied ($(tail -n 1 "${VALKEY_BUILD_LOG_DIR}/ensure-bolt.log" 2>/dev/null)); the LTO build keeps serving" ;;
  esac
  return 0
}

# Read-only (diagnostics): never runs pre hooks or starts anything.
valkey_build_status() {
  if [[ -x $VALKEY_BUILD_TOOL ]]; then
    "$VALKEY_BUILD_TOOL" status 2>/dev/null || printf 'Valkey: status unavailable\n'
  elif [[ -d $VALKEY_BUILD_LEGACY_DIR ]]; then
    printf 'Valkey: 1.21 build in %s (not yet migrated)\n' "$VALKEY_BUILD_LEGACY_DIR"
  else
    printf 'Valkey: no build\n'
  fi
  if valkey_pkg_installed valkey-server; then
    printf 'Valkey: the valkey-server package is still installed\n'
  elif dpkg-query -W -f='${Status}' valkey-server 2>/dev/null | grep -q 'config-files'; then
    printf 'Valkey: valkey-server is in rc state; do not purge it (its postrm deletes /etc/valkey and /var/lib/valkey)\n'
  fi
  return 0
}

valkey_build_plan() {
  local v
  v=$(valkey_build_info_get valkey)
  if [[ -n $v ]]; then
    printf 'Valkey %s compiled from source (/usr/local/lib/setup-valkey); rebuilt when Valkey (or LLVM) releases a newer version%s' \
      "$v" "$( s=$(valkey_build_info_get series); [[ -n $s ]] && printf ', staying on the %s series (valkey.conf persists data with AOF)' "$s")"
  elif valkey_pkg_installed valkey-server; then
    printf 'Valkey: the valkey-server package is replaced by a source build (newest release, or the package series when valkey.conf persists data with AOF) by the 1.22 migration'
  else
    printf 'Valkey compiled from source (newest release; clang, LTO, BOLT) into /usr/local/lib/setup-valkey, own valkey-server.service'
  fi
}

# --purge valkey: our unit, binaries, links and build cache go; /etc/valkey,
# /var/lib/valkey, the logs and the valkey user stay ("files preserved").
valkey_build_purge() {
  local l
  if valkey_unit_is_ours; then
    systemctl disable --now valkey-server.service >/dev/null 2>&1 || true
    rm -f "$VALKEY_SERVER_UNIT_FILE" "$VALKEY_BUILD_LEGACY_DROPIN"
    rm -f "${VALKEY_BUILD_SYSTEMD_DIR}/valkey-server.service.d/limits.conf"
    rmdir "${VALKEY_BUILD_SYSTEMD_DIR}/valkey-server.service.d" 2>/dev/null || true
    info "Valkey: valkey-server.service removed (configuration and data kept)"
  fi
  # The alias link, when it names our (now removed) unit.
  l="${VALKEY_BUILD_SYSTEMD_DIR}/valkey.service"
  [[ -L $l && ! -e $l ]] && rm -f "$l"
  for l in valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb; do
    [[ -L ${VALKEY_BUILD_LINK_DIR}/$l && $(readlink "${VALKEY_BUILD_LINK_DIR}/$l") == "${VALKEY_BUILD_ROOT}/"* ]] \
      && rm -f "${VALKEY_BUILD_LINK_DIR:?}/$l"
  done
  valkey_build_retire_legacy
  systemctl stop "${VALKEY_BUILD_UNIT##*/}" >/dev/null 2>&1 || true
  rm -f "$VALKEY_BUILD_UNIT"
  if [[ -d $VALKEY_BUILD_ROOT || -d $VALKEY_BUILD_CACHE ]]; then
    rm -rf "${VALKEY_BUILD_ROOT:?}" "${VALKEY_BUILD_CACHE:?}"
    info "Valkey: build removed (${VALKEY_BUILD_ROOT})"
  fi
  declare -F setup_build_llvm_release >/dev/null && setup_build_llvm_release valkey
  valkey_build_release_shared_units
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed valkey-server.service >/dev/null 2>&1 || true
  return 0
}

# Last-consumer rule (R81): the shared setup-build-refresh.{service,timer},
# setup-build-cpu.service and the lock go with the last compiled build.
# "--purge nginx" then "--purge valkey" must not leave the timer and the CPU
# unit enabled with nothing to build.  The rule itself is
# lib/nginx-build.sh's setup_build_remove_shared_units_if_last (one copy for
# every component); the copy below runs only when that file is not sourced
# (unit tests).  Each root is tested on its own (a missing root must not hide
# a build in another one).
valkey_build_release_shared_units() {
  local n=${NGINX_ROOT:-${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx}} p=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
  local d=${VALKEY_BUILD_SYSTEMD_DIR} cpu refresh timer lock had=0 hit
  cpu=${SETUP_BUILD_CPU_UNIT:-$d/setup-build-cpu.service}
  refresh=${SETUP_BUILD_REFRESH_UNIT:-$d/setup-build-refresh.service}
  timer=${SETUP_BUILD_REFRESH_TIMER:-$d/setup-build-refresh.timer}
  [[ -e $cpu || -e $refresh || -e $timer ]] && had=1
  if declare -F setup_build_remove_shared_units_if_last >/dev/null; then
    setup_build_remove_shared_units_if_last valkey
    if (( had )) && [[ ! -e $cpu && ! -e $refresh && ! -e $timer ]]; then
      info "Valkey: last compiled build removed; the shared refresh timer and CPU rebuild unit went with it"
    fi
    return 0
  fi
  [[ -f $n/build/build.info ]] && return 0
  if [[ -d $p ]]; then
    hit=$(find "$p" -maxdepth 3 -name build.info -not -path '*/staging/*' -print -quit 2>/dev/null || true)
    [[ -n $hit ]] && return 0
  fi
  [[ -f $VALKEY_BUILD_INFO ]] && return 0
  (( had )) || return 0
  lock=${SETUP_BUILD_LOCK_FILE:-${SETUP_BUILD_LOCK:-/run/setup-build.lock}}
  systemctl disable --now "${timer##*/}" >/dev/null 2>&1 || true
  systemctl stop "${cpu##*/}" "${refresh##*/}" >/dev/null 2>&1 || true
  rm -f "$cpu" "$refresh" "$timer" "$lock"
  info "Valkey: last compiled build removed; the shared refresh timer and CPU rebuild unit went with it"
}
