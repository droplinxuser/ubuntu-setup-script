# shellcheck shell=bash
# ---------------------------------------------------------------------------
# nginx compiled from source (1.22.0): the setup.sh side of tools/nginx-build.sh
# ---------------------------------------------------------------------------
# Every host's web server is the nginx.org mainline compiled by
# tools/nginx-build.sh (lean module set, static Brotli, branding stripped,
# clang -O3 -march=native, ThinLTO, BOLT under traffic).  There is no package
# and no package fallback: a failed build on a fresh host stops the install
# with the build log's path; on a running host the running binary keeps
# serving.  This file writes what the tool does not own: our own
# /etc/systemd/system/nginx.service (the binary under ROOT, never a /usr
# path), tmpfiles.d/setup-nginx.conf (/var/cache/nginx/*_temp and the log
# directory, created before any `nginx -t`), the build units and the daily
# refresh timer shared with the PHP and Valkey builds.
#
# Interfaces (design 1.22.0, REVISION 3):
#   nginx_build_ensure MODE CONTEXT OUT  MODE build-only|activate|full,
#                                        CONTEXT install|optimize|migrate; 1 on failure
#   nginx_build_fit OUT [BIN [CONF]]     comment out directives of left-out modules (reported;
#                                        OUT a FILE: "path:line directive" lines)
#   nginx_build_plan                     one dry-run line
#   nginx_build_purge                    --purge nginx
#   nginx_build_status                   read-only lines for diagnostics
#   nginx_unit_text, nginx_tmpfiles_text, nginx_build_unit_text,
#   setup_build_cpu_unit_text, setup_build_refresh_unit_text, setup_build_refresh_timer_text
#   setup_build_install_shared_units, setup_build_remove_shared_units_if_last [COMPONENT]
#   NGINX_BUILD_STAGING, NGINX_BUILD_DROPPABLE_RE, NGINX_BUILD_UNBUILT_RE (for lib/migrate.sh)
#   NGINX_ROOT, NGINX_BIN (the binary every caller runs), NGINX_LINK (operators' shell link)

NGINX_ROOT=${NGINX_ROOT:-${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx}}
NGINX_BUILD_ROOT=$NGINX_ROOT   # 1.21 name, still read by setup_build_llvm_release
NGINX_BIN=${NGINX_BIN:-${NGINX_ROOT}/sbin/nginx}
NGINX_LINK=${NGINX_LINK:-/usr/local/sbin/nginx}
NGINX_BUILD_TOOL="${NGINX_ROOT}/nginx-build.sh"
NGINX_BUILD_COMMON_FILE="${NGINX_ROOT}/build-common.sh"
NGINX_BUILD_CONF_FILE="${NGINX_ROOT}/nginx-build.conf"
NGINX_BUILD_CACHE=${NGINX_BUILD_CACHE:-/var/cache/setup-nginx-build}
# Where `build` / build-only leaves the verified candidate (lib/migrate.sh
# reads it for its step-7 test and fit).
NGINX_BUILD_STAGING=${NGINX_BUILD_STAGING:-${NGINX_ROOT}/staging}
# The fit's record of what it commented out in /etc/nginx, and the part of
# it already shown in a setup.sh report (the refresh timer and nginx's
# ExecStartPre comment out too, but only the journal sees those runs; R88).
NGINX_DISABLED_LIST="${NGINX_ROOT}/build/disabled.list"
NGINX_DISABLED_SEEN="${NGINX_ROOT}/build/disabled.reported"
NGINX_PIDFILE=/run/nginx.pid
NGINX_SYSTEMD_DIR=${NGINX_SYSTEMD_DIR:-/etc/systemd/system}
NGINX_UNIT_FILE=${NGINX_UNIT_FILE:-${NGINX_SYSTEMD_DIR}/nginx.service}
NGINX_TMPFILES=${NGINX_TMPFILES:-/etc/tmpfiles.d/setup-nginx.conf}
NGINX_BUILD_UNIT=${NGINX_BUILD_UNIT:-${NGINX_SYSTEMD_DIR}/setup-nginx-build.service}
SETUP_BUILD_CPU_UNIT=${SETUP_BUILD_CPU_UNIT:-${NGINX_SYSTEMD_DIR}/setup-build-cpu.service}
SETUP_BUILD_REFRESH_UNIT=${SETUP_BUILD_REFRESH_UNIT:-${NGINX_SYSTEMD_DIR}/setup-build-refresh.service}
SETUP_BUILD_REFRESH_TIMER=${SETUP_BUILD_REFRESH_TIMER:-${NGINX_SYSTEMD_DIR}/setup-build-refresh.timer}
SETUP_BUILD_LOCK_FILE=${SETUP_BUILD_LOCK:-/run/setup-build.lock}
# Where each component's copy of build-common.sh lives; the shared units run
# whichever exists (a host can lose nginx's build and keep PHP's).
SETUP_BUILD_COMMON_COPIES="${NGINX_ROOT}/build-common.sh /usr/local/lib/setup-php/build-common.sh /usr/local/lib/setup-valkey/build-common.sh"
SETUP_BUILD_PHP_ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
SETUP_BUILD_VALKEY_ROOT=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}

# The directive classes of the lean configure line, for lib/migrate.sh's
# pre-flight scan (droppable: commented out with a report; unbuilt: a
# blocker).  Read from the tool itself (DROPPABLE_RE / UNBUILT_RE), so the
# scan and the fit can never disagree; an exported value wins (tests).
_nginx_build_directive_res() {
  local src="${SCRIPT_DIR:-}/tools/nginx-build.sh" v
  [[ -f $src ]] || src=$NGINX_BUILD_TOOL
  [[ -f $src ]] || return 0
  if [[ -z ${NGINX_BUILD_DROPPABLE_RE:-} ]]; then
    v=$(sed -n "s/^DROPPABLE_RE='\(.*\)'\$/\1/p" "$src" 2>/dev/null | sed -n 1p)
    [[ -n $v ]] && export NGINX_BUILD_DROPPABLE_RE=$v
  fi
  if [[ -z ${NGINX_BUILD_UNBUILT_RE:-} ]]; then
    v=$(sed -n "s/^UNBUILT_RE='\(.*\)'\$/\1/p" "$src" 2>/dev/null | sed -n 1p)
    [[ -n $v ]] && export NGINX_BUILD_UNBUILT_RE=$v
  fi
  return 0
}
_nginx_build_directive_res

# ------------------------------------------------------------------ texts
# PIDFile, --pid-path and server-configs-nginx's `pid` are all /run/nginx.pid.
# ExecStartPre is the CPU gate + `nginx -t` (tools/nginx-build.sh pre); a
# CPU change keeps nginx down until setup-build-cpu.service rebuilt it.
# LimitNOFILE and UMask are the former limits drop-in, now in the unit.
# No Restart=: a failed gate must not loop.
nginx_unit_text() {
  cat <<EOF
# Managed by setup.sh (lib/nginx-build.sh): nginx compiled from nginx.org mainline.
[Unit]
Description=nginx web server (compiled by setup.sh)
Documentation=https://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${NGINX_PIDFILE}
ExecStartPre=${NGINX_BUILD_TOOL} pre
ExecStart=${NGINX_ROOT}/sbin/nginx
ExecReload=${NGINX_ROOT}/sbin/nginx -t -q
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
TimeoutStopSec=30
LimitNOFILE=524288
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
}

nginx_tmpfiles_text() {
  cat <<'EOF'
# Managed by setup.sh (lib/nginx-build.sh): the compiled nginx's temp paths
# (nginx creates only the last path component) and its log directory, which
# must exist before any `nginx -t`.
d /var/cache/nginx 0700 www-data www-data -
d /var/cache/nginx/client_temp 0700 www-data www-data -
d /var/cache/nginx/fastcgi_temp 0700 www-data www-data -
d /var/cache/nginx/proxy_temp 0700 www-data www-data -
d /var/cache/nginx/scgi_temp 0700 www-data www-data -
d /var/cache/nginx/uwsgi_temp 0700 www-data www-data -
d /var/www/logs/nginx 0750 www-data www-data -
EOF
}

# Build units: low priority, and the kernel's OOM victim before mysqld or a
# web server (R66).  The interactive builds lower themselves the same way
# (build_deprioritize in build-common.sh).
_setup_build_service_props() {
  printf 'Type=oneshot\nNice=10\nIOSchedulingClass=idle\nOOMScoreAdjust=900\n'
}

# Rebuild nginx now, in the background: build, in-place upgrade, BOLT.
nginx_build_unit_text() {
  cat <<EOF
# Managed by setup.sh (lib/nginx-build.sh).
[Unit]
Description=Rebuild the compiled nginx (setup.sh: build, in-place upgrade, BOLT)
After=network-online.target
Wants=network-online.target

[Service]
$(_setup_build_service_props)
TimeoutStartSec=2h
ExecStart=${NGINX_BUILD_TOOL} rebuild
EOF
}

# The chain command of the shared units: the first build-common.sh copy that
# exists ($$ is a literal $ for systemd).
_setup_build_chain_exec() { # cpu|refresh
  local c list=""
  for c in $SETUP_BUILD_COMMON_COPIES; do list+="$c "; done
  printf "/bin/sh -c 'for c in %s; do [ -f \"\$\$c\" ] && exec /bin/bash \"\$\$c\" chain %s; done; echo \"setup-build: no build tool installed\"'" "${list% }" "$1"
}

# After a CPU change every gate (nginx, PHP, Valkey ExecStartPre) only starts
# this unit; it rebuilds nginx, the active PHP and Valkey in that order from
# their recorded versions, offline, and starts each enabled service.
# TimeoutStartSec is only a backstop above the chain's own bounds, so systemd
# never kills the last stage (Valkey) and leaves it down (R33): the lock
# wait (SETUP_BUILD_LOCK_TIMEOUT, 6 h) + nginx 1 h + PHP 2 h per enabled
# version + Valkey 1 h (build-common.sh BUILD_CHAIN_T_*), each with 60 s
# kill-after and up to 300 s for its start: about 13.5 h with two PHP
# versions.
setup_build_cpu_unit_text() {
  cat <<EOF
# Managed by setup.sh (lib/nginx-build.sh).
[Unit]
Description=Rebuild the compiled nginx, PHP and Valkey for this CPU (setup.sh; they stay down until rebuilt)
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
$(_setup_build_service_props)
TimeoutStartSec=16h
ExecStart=$(_setup_build_chain_exec cpu)
EOF
}

setup_build_refresh_unit_text() {
  cat <<EOF
# Managed by setup.sh (lib/nginx-build.sh).
[Unit]
Description=Rebuild the compiled nginx, PHP and Valkey when upstream publishes newer releases (setup.sh)
After=network-online.target
Wants=network-online.target

[Service]
$(_setup_build_service_props)
TimeoutStartSec=6h
ExecStart=$(_setup_build_chain_exec refresh)
EOF
}

setup_build_refresh_timer_text() {
  cat <<'EOF'
# Managed by setup.sh (lib/nginx-build.sh).
[Unit]
Description=Daily upstream release check for the compiled nginx, PHP and Valkey (setup.sh)

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# ------------------------------------------------------------------ files
# Write FILE with CONTENT when it differs; status 0 when it changed.
setup_build_write() {
  [[ -f $1 && $(cat "$1") == "$2" ]] && return 1
  install -d -m 755 "$(dirname "$1")"
  printf '%s\n' "$2" > "$1.new" && mv -f "$1.new" "$1"
}

# The CPU chain and the refresh timer, shared by every compiled component.
# Status 0; NGINX_BUILD_UNITS_CHANGED=1 when a file changed.
setup_build_install_shared_units() {
  local changed=0
  setup_build_write "$SETUP_BUILD_CPU_UNIT" "$(setup_build_cpu_unit_text)" && changed=1
  setup_build_write "$SETUP_BUILD_REFRESH_UNIT" "$(setup_build_refresh_unit_text)" && changed=1
  setup_build_write "$SETUP_BUILD_REFRESH_TIMER" "$(setup_build_refresh_timer_text)" && changed=1
  (( changed )) && systemctl daemon-reload 2>/dev/null
  systemctl enable --now "${SETUP_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  return 0
}

# Is any compiled build left, other than component EXCEPT (nginx|php|valkey,
# the one being purged)?  Each root is tested on its own: one find over
# several roots exits 1 when any root is missing, even after it printed a
# match, and under setup.sh's pipefail that read as "nothing left" (R81).
_setup_build_left() { # [except]
  local except=${1:-} d hit
  if [[ $except != nginx && -f ${NGINX_ROOT}/build/build.info ]]; then return 0; fi
  for d in php:"$SETUP_BUILD_PHP_ROOT" valkey:"$SETUP_BUILD_VALKEY_ROOT"; do
    [[ ${d%%:*} == "$except" ]] && continue
    d=${d#*:}
    [[ -d $d ]] || continue
    hit=$(find "$d" -maxdepth 3 -name build.info -not -path '*/staging/*' -print -quit 2>/dev/null || true)
    [[ -n $hit ]] && return 0
  done
  return 1
}

# Last-consumer rule (R81): the CPU chain, the refresh timer and the lock go
# with the last remaining build.  Every component's purge calls it after
# removing its own root, naming itself (nginx_build_purge: nginx; PHP's and
# Valkey's purges: php / valkey).  Without an argument it removes the shared
# units only when no build at all is left.
setup_build_remove_shared_units_if_last() { # [component being purged]
  _setup_build_left "${1:-}" && return 0
  systemctl disable --now "${SETUP_BUILD_REFRESH_TIMER##*/}" >/dev/null 2>&1 || true
  systemctl stop "${SETUP_BUILD_CPU_UNIT##*/}" "${SETUP_BUILD_REFRESH_UNIT##*/}" >/dev/null 2>&1 || true
  rm -f "$SETUP_BUILD_CPU_UNIT" "$SETUP_BUILD_REFRESH_UNIT" "$SETUP_BUILD_REFRESH_TIMER" "$SETUP_BUILD_LOCK_FILE"
  return 0
}

# The tool, build-common and the version file into ROOT.  A changed tool
# clears the record of a version the branding patch was refused for (a new
# tool may patch it).
nginx_build_install_tools() {
  local src="${SCRIPT_DIR}/tools/nginx-build.sh"
  if [[ ! -f $src || ! -f ${SCRIPT_DIR}/tools/build-common.sh || ! -f ${SCRIPT_DIR}/nginx-build.conf ]]; then
    warn "nginx: tools/nginx-build.sh, tools/build-common.sh or nginx-build.conf is missing: 1.22 builds nginx from source and needs the full checkout"
    return 1
  fi
  install -d -m 755 "$NGINX_ROOT"
  if ! cmp -s "$src" "$NGINX_BUILD_TOOL"; then
    install -m 755 "$src" "$NGINX_BUILD_TOOL.new" && mv -f "$NGINX_BUILD_TOOL.new" "$NGINX_BUILD_TOOL"
    rm -f "${NGINX_ROOT}/patch-skip"
  fi
  cmp -s "${SCRIPT_DIR}/tools/build-common.sh" "$NGINX_BUILD_COMMON_FILE" \
    || install -m 644 "${SCRIPT_DIR}/tools/build-common.sh" "$NGINX_BUILD_COMMON_FILE"
  cmp -s "${SCRIPT_DIR}/nginx-build.conf" "$NGINX_BUILD_CONF_FILE" \
    || install -m 644 "${SCRIPT_DIR}/nginx-build.conf" "$NGINX_BUILD_CONF_FILE"
  nginx_build_tmpfiles_apply
  return 0
}

# tmpfiles.d/setup-nginx.conf written and applied (before any nginx -t).
nginx_build_tmpfiles_apply() {
  setup_build_write "$NGINX_TMPFILES" "$(nginx_tmpfiles_text)" || true
  systemd-tmpfiles --create "$NGINX_TMPFILES" >/dev/null 2>&1 || {
    install -d -m 0700 -o www-data -g www-data /var/cache/nginx 2>/dev/null || true
    install -d -m 0750 -o www-data -g www-data /var/www/logs/nginx 2>/dev/null || true
  }
  return 0
}

# nginx.service, the rebuild unit and the shared units.  Writing the unit
# never enables it: nginx_build_ensure enables nginx.service only once it is
# actually running (_nginx_build_enable_if_running), so a host where Angie or
# a distro nginx still holds :80/:443 does not get two servers racing for the
# ports at the next boot.  The migration's cutover enables it there.  Sets
# NGINX_UNIT_RESTART=1 when a running nginx needs a restart to pick up a
# changed limit or type.  CONTEXT is kept for the callers' signature.
NGINX_UNIT_RESTART=0
nginx_build_install_units() { # context
  local old="" new changed=0
  NGINX_UNIT_RESTART=0
  new=$(nginx_unit_text)
  [[ -f $NGINX_UNIT_FILE ]] && old=$(cat "$NGINX_UNIT_FILE")
  if setup_build_write "$NGINX_UNIT_FILE" "$new"; then
    changed=1
    # Exec*/Description apply at the next start or reload; process limits,
    # umask, type and pid file only to a newly started master.
    if [[ -n $old ]] && diff <(grep -E '^(Type|PIDFile|Limit[A-Z]+|UMask|ExecStart)=' <<<"$old") \
                              <(grep -E '^(Type|PIDFile|Limit[A-Z]+|UMask|ExecStart)=' <<<"$new") >/dev/null 2>&1; then :
    elif [[ -n $old ]]; then NGINX_UNIT_RESTART=1
    fi
  fi
  setup_build_write "$NGINX_BUILD_UNIT" "$(nginx_build_unit_text)" && changed=1
  (( changed )) && systemctl daemon-reload 2>/dev/null
  setup_build_install_shared_units
  return 0
}

# Enable nginx.service once our nginx serves (never in the migration, whose
# cutover owns that step).  A unit that is not running stays as it is.
_nginx_build_enable_if_running() { # context
  [[ ${1:-optimize} == migrate ]] && return 0
  systemctl is-active -q nginx.service 2>/dev/null || return 0
  [[ $(systemctl is-enabled nginx.service 2>/dev/null || true) == enabled ]] && return 0
  systemctl enable nginx.service >/dev/null 2>&1 || true
  return 0
}

# Report what the fit commented out in /etc/nginx outside a setup.sh run
# (nginx's ExecStartPre `pre`, the refresh timer's activate, the CPU chain):
# those runs only reach the journal, and a removed limit_conn must reach the
# operator's report (R88).  Lines already shown are remembered.
_nginx_build_report_disabled() { # out
  local out=$1 l d where
  [[ -s $NGINX_DISABLED_LIST ]] || { rm -f "$NGINX_DISABLED_SEEN"; return 0; }
  while IFS= read -r l; do
    [[ -n $l ]] || continue
    grep -qxF -- "$l" "$NGINX_DISABLED_SEEN" 2>/dev/null && continue
    d=${l##* }; where=${l% *}
    if [[ $d == limit_conn* ]]; then
      "$out" "- **nginx: commented out $d in $where: security control removed (operator rule 1.21.71: limit_conn is not compiled in); done by nginx's start check or the daily refresh**"
    else
      "$out" "- nginx: commented out $d in $where (module not compiled in; done by nginx's start check or the daily refresh; \`${NGINX_BUILD_TOOL} restore\` puts it back)"
    fi
  done < "$NGINX_DISABLED_LIST"
  _nginx_build_disabled_seen
}
# Everything in the list has been reported (by this run's notes or above).
_nginx_build_disabled_seen() {
  if [[ -s $NGINX_DISABLED_LIST ]]; then cp -f "$NGINX_DISABLED_LIST" "$NGINX_DISABLED_SEEN" 2>/dev/null || true
  else rm -f "$NGINX_DISABLED_SEEN"
  fi
  return 0
}

# OUT may be a report function (info, opt_report, ...) or, as lib/migrate.sh
# passes it, an absolute path to a file that collects the report lines.
# Sets NGINX_BUILD_OUT to the function to call.
NGINX_BUILD_OUT=info
NGINX_BUILD_OUT_FILE=""
_nginx_build_out_file() { printf '%s\n' "$*" >> "$NGINX_BUILD_OUT_FILE"; }
_nginx_build_resolve_out() { # out
  NGINX_BUILD_OUT=${1:-info}
  if [[ $NGINX_BUILD_OUT == /* ]] && ! declare -F -- "$NGINX_BUILD_OUT" >/dev/null; then
    NGINX_BUILD_OUT_FILE=$NGINX_BUILD_OUT
    NGINX_BUILD_OUT=_nginx_build_out_file
  fi
}

# ------------------------------------------------------------------ running
NGINX_BUILD_LAST_OUT=""
# Run the tool with CONTEXT; its messages (stderr) are kept in
# ROOT/logs/setup-<action>.out and in NGINX_BUILD_LAST_OUT.  Status of the tool.
nginx_build_run_tool() { # context action [args...]
  local context=$1 action=$2 rc=0 f; shift 2
  install -d -m 755 "${NGINX_ROOT}/logs"
  f="${NGINX_ROOT}/logs/setup-${action}.out"
  NGINX_BUILD_CONTEXT=$context "$NGINX_BUILD_TOOL" "$action" "$@" > "$f" 2>&1 || rc=$?
  NGINX_BUILD_LAST_OUT=$(cat "$f" 2>/dev/null || true)
  return "$rc"
}

# The persistent build log the tool named ("(log: PATH)").
_nginx_build_log_path() {
  grep -oE '\(log: [^)]+\)' <<<"$NGINX_BUILD_LAST_OUT" | tail -n 1 | sed -E 's/^\(log: //; s/\)$//'
}

# Report the fallback / fit lines the tool printed.
_nginx_build_report_notes() { # out
  local out=$1 line
  while IFS= read -r line; do
    case $line in
      *"building the known-good"*|*"branding patch does not apply"*)
        "$out" "- **nginx: ${line#*nginx }** (NGINX_FALLBACK in ${NGINX_BUILD_CONF_FILE})" ;;
      *"commented out limit_conn"*|*"security control removed"*)
        "$out" "- **nginx: ${line#*nginx build: }**" ;;
      *"commented out"*)
        "$out" "- nginx: ${line#*nginx build: }" ;;
      *"does not pass with this build yet"*)
        "$out" "- nginx: ${line#*nginx build: }" ;;
    esac
  done <<<"$NGINX_BUILD_LAST_OUT"
}

nginx_build_bolted() { grep -qx 'bolt=1' "${NGINX_ROOT}/build/build.info" 2>/dev/null; }

# Hold /run/setup-build.lock in THIS shell for the whole ensure (report
# functions must keep writing the caller's state, so no subshell).  A caller
# that already holds it (migration controller: SETUP_BUILD_LOCK_HELD=1)
# passes straight through; the tool calls inherit the fd and the flag.
NGINX_BUILD_LOCK_FD=""
_nginx_build_lock() {
  [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]] && return 0
  exec {NGINX_BUILD_LOCK_FD}>>"$SETUP_BUILD_LOCK_FILE" || return 1
  if ! flock -n "$NGINX_BUILD_LOCK_FD"; then
    info "nginx: waiting for another build to finish ($SETUP_BUILD_LOCK_FILE)"
    flock -w "${SETUP_BUILD_LOCK_TIMEOUT:-21600}" "$NGINX_BUILD_LOCK_FD" || { exec {NGINX_BUILD_LOCK_FD}>&-; NGINX_BUILD_LOCK_FD=""; return 1; }
  fi
  export SETUP_BUILD_LOCK_HELD=1
}
_nginx_build_unlock() {
  [[ -n $NGINX_BUILD_LOCK_FD ]] || return 0
  exec {NGINX_BUILD_LOCK_FD}>&-
  NGINX_BUILD_LOCK_FD=""
  unset SETUP_BUILD_LOCK_HELD
}

# build-only: build + verify into ROOT/staging (nothing that serves changes).
_nginx_build_stage() { # context out
  local context=$1 out=$2 log
  "$out" "- nginx: building nginx.org mainline from source (a few minutes; versions in ${NGINX_BUILD_CONF_FILE})"
  if nginx_build_run_tool "$context" build; then
    _nginx_build_report_notes "$out"
    "$out" "- nginx: built and verified $(awk -F= '$1 == "nginx" { print $2 }' "${NGINX_ROOT}/staging/build.info" 2>/dev/null) (staged; branding check passed)"
    return 0
  fi
  log=$(_nginx_build_log_path)
  _nginx_build_report_notes "$out"
  "$out" "- **FAILED: nginx build** ($(grep -m1 'ERROR:' <<<"$NGINX_BUILD_LAST_OUT" | sed 's/^ERROR: //' || true)); log: ${log:-${NGINX_ROOT}/logs}"
  tail -n 5 <<<"$NGINX_BUILD_LAST_OUT" >&2 || true
  return 1
}

# activate: swap the staged build in (in-place upgrade when nginx runs, a
# start on a fresh host, nothing started while Angie holds the ports).
_nginx_build_activate() { # context out
  local context=$1 out=$2
  if nginx_build_run_tool "$context" activate; then
    _nginx_build_report_notes "$out"
    if grep -q 'not started' <<<"$NGINX_BUILD_LAST_OUT"; then
      "$out" "- nginx: $(grep -m1 'not started' <<<"$NGINX_BUILD_LAST_OUT" | sed 's/^nginx: //')"
    else
      "$out" "- nginx: $("$NGINX_BUILD_TOOL" status 2>/dev/null | sed -n 1p | sed 's/^nginx: //')"
    fi
    return 0
  fi
  _nginx_build_report_notes "$out"
  "$out" "- **FAILED: nginx activation** ($(grep -m1 'ERROR:' <<<"$NGINX_BUILD_LAST_OUT" | sed 's/^ERROR: //' || true)); the previous nginx keeps serving"
  return 1
}

# The interface F and E call (REVISION 3):
#   MODE    build-only  build + verify into staging; no unit enabled, nothing
#                       started, no BOLT (migration step 4)
#           activate    write the units, swap the staged build in
#           full        build when there is none or `check` says stale, then
#                       activate; on a current build make sure nginx runs;
#                       CONTEXT optimize adds BOLT under traffic
#   CONTEXT install | optimize | migrate (migrate never starts or enables nginx,
#           never tests /etc/nginx: the migration renders and tests it later)
#   OUT     report function (info, opt_report, ...), or an absolute file path
#           that collects the report lines
#   nginx.service is enabled only once it runs (never in migrate context).
nginx_build_ensure() {
  local mode=${1:-full} context=${2:-optimize} out rc=0 chk="" need=0 st
  _nginx_build_resolve_out "${3:-info}"; out=$NGINX_BUILD_OUT
  case $mode in build-only|activate|full) ;; *) "$out" "- **nginx: unknown build mode '$mode'**"; return 1 ;; esac
  case $context in install|optimize|migrate) ;; *) context=optimize ;; esac
  nginx_build_install_tools || { "$out" "- **FAILED: nginx: the build tool is missing from this checkout**"; return 1; }
  _nginx_build_lock || { "$out" "- **FAILED: nginx: timed out waiting for the build lock ($SETUP_BUILD_LOCK_FILE)**"; return 1; }
  [[ $context == migrate ]] || _nginx_build_report_disabled "$out"
  case $mode in
    build-only)
      _nginx_build_stage "$context" "$out" || rc=1 ;;
    activate)
      if [[ ! -f ${NGINX_ROOT}/staging/build.info ]]; then
        if [[ -x $NGINX_BIN ]]; then
          nginx_build_install_units "$context"
          "$out" "- nginx: nothing staged; the installed build stays ($("$NGINX_BUILD_TOOL" status 2>/dev/null | sed -n 1p | sed 's/^nginx: //'))"
        else
          "$out" "- **FAILED: nginx: no build to activate (run the build first)**"; rc=1
        fi
      else
        nginx_build_install_units "$context"
        _nginx_build_activate "$context" "$out" || rc=1
      fi ;;
    full)
      if [[ ! -x $NGINX_BIN || ! -f ${NGINX_ROOT}/build/build.info ]]; then
        need=1
      else
        chk=$("$NGINX_BUILD_TOOL" check 2>/dev/null) || rc=$?
        if (( rc == 10 )); then need=1; "$out" "- nginx: build ${chk}"; fi
        rc=0
      fi
      nginx_build_install_units "$context"
      # A staging left behind (an aborted migration's build-only, a failed
      # earlier activate) is swapped in only when `check` finds it current:
      # same recipe, this CPU, the versions wanted now.  Anything else could
      # be a downgrade or a binary for another CPU, so it is discarded.
      if (( ! need )) && [[ -f ${NGINX_ROOT}/staging/build.info ]]; then
        if ! st=$("$NGINX_BUILD_TOOL" check "${NGINX_ROOT}/staging/build.info" 2>/dev/null); then
          "$out" "- nginx: discarded a leftover staged build ($(awk -F= '$1 == "nginx" { print $2 }' "${NGINX_ROOT}/staging/build.info" 2>/dev/null): ${st:-not verifiable})"
          rm -rf "${NGINX_ROOT:?}/staging"
        fi
      fi
      if (( need )); then
        if _nginx_build_stage "$context" "$out" && _nginx_build_activate "$context" "$out"; then :; else rc=1; fi
      elif [[ -f ${NGINX_ROOT}/staging/build.info ]]; then
        _nginx_build_activate "$context" "$out" || rc=1
      else
        "$out" "- nginx: build is current ($("$NGINX_BUILD_TOOL" status 2>/dev/null | sed -n 1p | sed 's/^nginx: //'))"
        _nginx_build_ensure_running "$context" "$out" || rc=1
      fi
      if (( rc == 0 )) && [[ $context == optimize ]]; then
        _nginx_build_bolt "$out"
      fi ;;
  esac
  if (( rc == 0 )) && [[ $mode != build-only ]]; then _nginx_build_enable_if_running "$context"; fi
  _nginx_build_disabled_seen
  _nginx_build_unlock
  return "$rc"
}

# A current build whose nginx is down (or whose unit changed a process limit).
_nginx_build_ensure_running() { # context out
  local context=$1 out=$2
  [[ $context == migrate ]] && return 0
  if systemctl is-active -q nginx.service; then
    if (( NGINX_UNIT_RESTART )); then
      if systemctl restart nginx.service; then "$out" "- nginx: restarted for the changed unit limits"
      else "$out" "- **FAILED: nginx did not restart after the unit change** (systemctl status nginx)"; return 1
      fi
    fi
    return 0
  fi
  if systemctl is-active -q angie.service 2>/dev/null; then
    "$out" "- nginx: not started: angie.service still serves (the migration's cutover starts nginx)"
    return 0
  fi
  if systemctl start nginx.service; then "$out" "- nginx: started"; return 0; fi
  "$out" "- **FAILED: nginx did not start** (systemctl status nginx; journalctl -u nginx)"
  return 1
}

# BOLT under live traffic (--optimize only): failures never fail the run.
_nginx_build_bolt() { # out
  local out=$1 rc=0
  nginx_build_bolted && return 0
  [[ ${SETUP_NGINX_BUILD_BOLT:-1} == 1 ]] || return 0
  systemctl is-active -q nginx.service || return 0
  nginx_build_run_tool optimize bolt "${SETUP_NGINX_BUILD_BOLT_SECONDS:-60}" || rc=$?
  case $rc in
    0) "$out" "- nginx: BOLT applied from live traffic (in-place upgrade)" ;;
    3) "$out" "- nginx: BOLT skipped ($(grep -m1 -E 'skipped|too little' <<<"$NGINX_BUILD_LAST_OUT" | sed 's/^nginx: //')); the refresh timer retries under load" ;;
    *) "$out" "- nginx: BOLT not applied ($(grep -m1 'ERROR:' <<<"$NGINX_BUILD_LAST_OUT" | sed 's/^ERROR: //')); the ThinLTO build keeps serving" ;;
  esac
  return 0
}

# Directives of modules the lean build leaves out: the droppable ones are
# commented out (marker '# setup-nginx-build-off: ') and reported (limit_conn
# prominently, as a removed security control: operator rule 1.21.71);
# anything else is a blocker reported with nginx's error.  Status 1 on a
# blocker.
#   OUT   report function, or an absolute FILE path: then exactly one line
#         'path:line directive' per commented directive is appended to FILE
#         and nothing else is reported (lib/migrate.sh step 7 reads them)
#   BIN   the binary to test with (default: the active $NGINX_BIN; with none
#         installed and no BIN there is nothing to fit, status 0).  The
#         migration passes the staged candidate.
#   CONF  the main file of the tree to fit (default /etc/nginx/nginx.conf);
#         only files under its directory are ever edited.
nginx_build_fit() { # out [bin [conf]]
  local out=${1:-info} bin=${2:-} conf=${3:-} file="" why dir line rc=0 ctx=optimize
  local re='nginx build: commented out ([a-z0-9_]+) in ([^[:space:]]+):([0-9]+) '
  if [[ $out == /* ]] && ! declare -F -- "$out" >/dev/null; then file=$out; fi
  NGINX_BUILD_LAST_OUT=""
  if [[ -z $bin ]]; then
    [[ -x $NGINX_BIN ]] || return 0
    bin=$NGINX_BIN
  fi
  conf=${conf:-${NGINX_BUILD_NGINX_CONF:-/etc/nginx/nginx.conf}}
  dir=$(dirname "$conf")
  if [[ ! -x $bin ]]; then
    why="no nginx binary at $bin"
  elif [[ ! -x $NGINX_BUILD_TOOL ]] && ! nginx_build_install_tools; then
    why="the build tool is missing from this checkout"
  else
    # A candidate other than the active binary is the migration's (step 7):
    # its fit lines are reported by the caller, not recorded for --optimize.
    if [[ $bin != "$NGINX_BIN" ]]; then ctx=migrate; fi
    nginx_build_run_tool "$ctx" fit "$conf" "$bin" || rc=$?
    (( rc == 0 )) || why=$(grep -m1 -E 'emerg|error' <<<"$NGINX_BUILD_LAST_OUT" || true)
  fi
  [[ -n ${why:-} ]] && rc=1
  if [[ -n $file ]]; then
    while IFS= read -r line; do
      [[ $line =~ $re ]] && printf '%s/%s:%s %s\n' "$dir" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" >> "$file"
    done <<<"$NGINX_BUILD_LAST_OUT"
    (( rc == 0 )) || printf 'nginx: fit of %s failed: %s\n' "$conf" "${why:-nginx -t failed}" >&2
  else
    _nginx_build_report_notes "$out"
    (( rc == 0 )) || "$out" "- **nginx: the configuration needs a module the lean build leaves out** (${why:-nginx -t failed}); nginx keeps its current configuration"
  fi
  # The caller reported these; the next ensure must not repeat them.
  _nginx_build_disabled_seen
  return "$rc"
}

nginx_build_plan() {
  local v=""
  [[ -f ${NGINX_ROOT}/build/build.info ]] && v=$(awk -F= '$1 == "nginx" { print $2 }' "${NGINX_ROOT}/build/build.info")
  if [[ -n $v ]]; then
    printf 'nginx %s compiled from source (nginx.org mainline; rebuilt when nginx-build.conf resolves newer versions; in-place upgrade; BOLT under traffic)' "$v"
  else
    printf 'nginx compiled from nginx.org mainline source (clang -O3 -march=native, ThinLTO, static Brotli, branding stripped; own nginx.service; BOLT under traffic on --optimize)'
  fi
}

# Read-only lines for diagnostics (R80): build.info, CPU gate state, timers,
# the newest build log.  Starts nothing and builds nothing.
nginx_build_status() {
  local info=${NGINX_ROOT}/build/build.info log
  if [[ ! -f $info ]]; then printf 'nginx build: none in %s\n' "$NGINX_ROOT"; return 0; fi
  [[ -x $NGINX_BUILD_TOOL ]] && "$NGINX_BUILD_TOOL" status 2>/dev/null
  printf 'nginx build.info: %s\n' "$(grep -E '^(nginx|openssl|pcre2|zlib-ng|brotli|ngx-brotli|llvm|recipe|bolt|built|patched_ok|fallback_from)=' "$info" | tr '\n' ' ')"
  printf 'setup-build-cpu.service: %s; setup-build-refresh.timer: %s\n' \
    "$(systemctl is-active setup-build-cpu.service 2>/dev/null || true)" "$(systemctl is-active setup-build-refresh.timer 2>/dev/null || true)"
  log=$(find "${NGINX_ROOT}/logs" -maxdepth 1 -name 'nginx-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed -n '1s/^[^ ]* //p')
  [[ -n $log ]] && printf 'nginx newest build log: %s\n' "$log"
  return 0
}

# --purge nginx: our unit, the build, its tool root, links, tmpfiles and
# build units go; /etc/nginx, /var/www/logs/nginx, /var/backups/setup-1.22
# and any cache a vhost keeps under /var/cache/nginx stay.  The shared
# CPU/refresh units and LLVM go only with the last build.
nginx_build_purge() {
  local t
  systemctl disable --now nginx.service >/dev/null 2>&1 || true
  systemctl stop "${NGINX_BUILD_UNIT##*/}" >/dev/null 2>&1 || true
  rm -f "$NGINX_UNIT_FILE" "$NGINX_BUILD_UNIT"
  if [[ -L $NGINX_LINK && $(readlink "$NGINX_LINK") == "${NGINX_ROOT}"/* ]]; then rm -f "$NGINX_LINK"; fi
  if [[ -x $NGINX_BUILD_TOOL ]]; then "$NGINX_BUILD_TOOL" restore >/dev/null 2>&1 || true; fi
  rm -rf "${NGINX_ROOT:?}" "${NGINX_BUILD_CACHE:?}"
  rm -f "$NGINX_TMPFILES"
  # Only the build's own *_temp directories: a proxy_cache_path or
  # fastcgi_cache_path a vhost keeps under /var/cache/nginx is cache data,
  # which setup.sh never deletes.  The directory goes only when it is empty.
  for t in client fastcgi proxy scgi uwsgi; do rm -rf "/var/cache/nginx/${t}_temp"; done
  rmdir /var/cache/nginx 2>/dev/null || true
  setup_build_remove_shared_units_if_last nginx
  if declare -F setup_build_llvm_release >/dev/null; then setup_build_llvm_release nginx; fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed >/dev/null 2>&1 || true
  info "nginx: compiled nginx, its unit and build files removed (/etc/nginx and the logs are kept)"
  return 0
}
