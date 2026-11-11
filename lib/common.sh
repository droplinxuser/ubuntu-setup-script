# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).
# ---------------------------------------------------------------------------
# Logging / small helpers
# ---------------------------------------------------------------------------
# Use UTC for every log line.  configure_timezone changes the host zone in the
# middle of a run, so a local-time log jumps by the offset (the 1.13.1 audit
# log showed 10:14 UTC followed by 18:15 PST and looked like an 8-hour run).
_timestamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
info() { printf '%s %s[INFO]%s %s\n' "$(_timestamp)" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s %s[ OK ]%s %s\n' "$(_timestamp)" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s %s[WARN]%s %s\n' "$(_timestamp)" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { trap - ERR; printf '%s %s[FAIL]%s %s\n' "$(_timestamp)" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# Full run log
# ---------------------------------------------------------------------------
# Every run mirrors its complete stdout/stderr into setup_<timestamp>.log in
# the directory the script was started from.  That log is the one deliberate
# output written outside /tmp: it is meant to be copied to a debugging agent,
# so it is neither temporary nor auto-expired.  Everything else stays in /tmp.
RUN_LOG_FILE=""
RUN_LOG_TEE_PID=""
RUN_LOG_STARTED=0
RUN_LOG_START_EPOCH=0

# Never write a password into the log header.  --mariadb pass=... is the only
# secret accepted on the command line today; keep the pattern broad enough to
# cover future password= options too.
log_safe_args() {
  local arg out=()
  for arg in "$@"; do
    case "$arg" in
      pass=*|password=*|*[Pp]assword=*) arg="${arg%%=*}=***" ;;
    esac
    out+=("$arg")
  done
  printf '%s' "${out[*]}"
}

# systemd marks a failed unit with a leading bullet in --no-legend output
# ("● logrotate.service loaded failed failed ..."), so $1 is the bullet on
# current releases and the unit name on older ones.  Keep the log header
# useful instead of printing "●,●,●".
failed_unit_names() {
  awk '{ gsub(/\033\[[0-9;]*m/, ""); if ($1 == "●" || $1 == "*") print $2; else print $1 }' | paste -sd, -
}

log_environment() {
  local os_name="" os_ver="" virt="" ips="" failed="" mem="" disk=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os_name=$( . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}" )
    os_ver=$( . /etc/os-release; printf '%s' "${VERSION_ID:-unknown}" )
  fi
  command -v systemd-detect-virt >/dev/null 2>&1 \
    && virt=$(systemd-detect-virt 2>/dev/null || true)
  command -v hostname >/dev/null 2>&1 \
    && ips=$(hostname -I 2>/dev/null || true)
  command -v systemctl >/dev/null 2>&1 \
    && failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | failed_unit_names || true)
  command -v free >/dev/null 2>&1 && mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%sMB total, %sMB available", $2, $7}')
  command -v df >/dev/null 2>&1 && disk=$(df -Ph / 2>/dev/null | awk 'NR==2{printf "%s total, %s free on %s", $2, $4, $6}')

  printf '\n--- environment ---\n'
  printf 'Command      : %s %s\n' "$SCRIPT_NAME" "$(log_safe_args "$@")"
  printf 'Invocation   : %s\n' "${SCRIPT_INVOKED_AS:-$0}"
  printf 'Directory    : %s\n' "$PWD"
  printf 'Script dir   : %s\n' "$SCRIPT_DIR"
  printf 'PID / PPID   : %s / %s\n' "$$" "${PPID:-unknown}"
  printf 'User / EUID  : %s / %s\n' "$(id -un 2>/dev/null || printf unknown)" "${EUID:-unknown}"
  printf 'Umask        : %s\n' "$(umask)"
  printf 'Shell        : %s (bash %s)\n' "${SHELL:-unknown}" "$BASH_VERSION"
  printf 'OS           : %s (%s)\n' "$os_name" "$os_ver"
  printf 'Kernel       : %s\n' "$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || printf unknown)"
  printf 'Architecture : %s\n' "$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || printf unknown)"
  printf 'Virtualization: %s\n' "${virt:-none/unknown}"
  printf 'CPU          : %s logical CPUs\n' "$(nproc 2>/dev/null || printf unknown)"
  printf 'Memory       : %s\n' "${mem:-unknown}"
  printf 'Disk         : %s\n' "${disk:-unknown}"
  printf 'Addresses    : %s\n' "${ips:-unknown}"
  printf 'Failed units : %s\n' "${failed:-none}"
  printf 'TMPDIR       : %s\n' "${TMPDIR:-unset}"
  printf 'Log file     : %s\n' "$RUN_LOG_FILE"
  printf '%s\n' '--------------------'
  printf '\n'
}

# Printed after argument parsing so the log reports what the script will
# actually do, not the empty arrays that exist while the header is written.
log_selection() {
  local services="none" domains="none"
  (( ${#ENABLED[@]} > 0 )) && services="${!ENABLED[*]}"
  (( ${#DOMAINS[@]} > 0 )) && domains="${DOMAINS[*]}"
  printf '\n--- selection ---\n'
  printf 'Modes        : dry_run=%s optimize=%s purge=%s diagnostics=%s restart_all=%s\n' \
    "${DRY_RUN:-0}" "${OPTIMIZE:-0}" "${PURGE:-0}" "${DIAGNOSTICS:-0}" "${RESTART_ALL:-0}"
  printf 'Services     : %s\n' "$services"
  printf 'Domains      : %s\n' "$domains"
  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then
    printf 'MariaDB      : user=%s size=%s bind=%s\n' \
      "${OPT[mariadb.user]:-}" "${OPT[mariadb.size]:-}" "${OPT[mariadb.bind]:-}"
  fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    printf 'PHP          : version=%s children=%s max_requests=%s\n' \
      "${OPT[php.ver]:-auto}" "${OPT[php.children]:-auto}" "${OPT[php.max_requests]:-auto}"
  fi
  if [[ ${ENABLED[valkey]:-0} -eq 1 ]]; then
    printf 'Valkey       : ram=%s policy=%s io_threads=%s\n' \
      "${OPT[valkey.ram]:-auto}" "${OPT[valkey.policy]:-allkeys-lru}" "${OPT[valkey.io_threads]:-1}"
  fi
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    printf 'Elasticsearch: host=%s ram=%s\n' \
      "${OPT[elastic.host]:-localhost}" "${OPT[elastic.ram]:-auto}"
  fi
  printf '%s\n' '--------------------'
  printf '\n'
}

# A file created by `sudo bash setup.sh` in the operator's checkout or home
# would otherwise stay root-owned and unreadable to them (mode 600 is kept).
give_to_invoking_user() {
  local f=$1
  [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} && ${SUDO_UID} != 0 ]] || return 0
  [[ -e $f ]] || return 0
  chown "${SUDO_UID}:${SUDO_GID}" "$f" 2>/dev/null || true
}

start_run_log() {
  local stamp
  stamp=$(date -u +%Y%m%d-%H%M%S)
  # Include the PID so two invocations started in the same second (a common
  # occurrence for --help/--version probes and CI dry-runs) never append to
  # the same file and interleave their environment headers.
  RUN_LOG_FILE="${PWD}/setup_${stamp}-$$.log"

  # Refuse to abort a real run just because the invocation directory is not
  # writable; the console output and normal diagnostics still work.
  if ! ( umask 077; : >> "$RUN_LOG_FILE" ) 2>/dev/null; then
    RUN_LOG_FILE=""
    warn "Could not create a run log in ${PWD}; continuing without a file log"
    return 0
  fi
  chmod 600 "$RUN_LOG_FILE" 2>/dev/null || true
  # Deliberately keep the log root-owned for the whole run.  Handing it to the
  # invoking user before tee starts is a real failure on a protected host: with
  # fs.protected_regular=2 (a value this script itself applies) and a run from a
  # sticky world-writable directory such as /tmp, the kernel refuses root's
  # O_CREAT open of a file owned by somebody else, so tee could not open the
  # log and every run in /tmp produced an empty file.  finish_run_log() gives
  # the completed file to SUDO_UID after the last write instead.

  # tee mirrors every line to the terminal and the file.  The PID is saved so
  # finish_run_log() can wait for the final line to reach disk before exit.
  # Drop the inherited ERR trap in the tee subshell: when the reader of a pipe
  # goes away (`setup.sh ... | head`), tee exits non-zero and the trap would
  # print a second, false "[ERR] command failed ... tee" line for a run that
  # already succeeded.
  exec > >(trap - ERR; exec tee -a "$RUN_LOG_FILE") 2>&1
  RUN_LOG_TEE_PID=$!
  RUN_LOG_STARTED=1
  RUN_LOG_START_EPOCH=$(date +%s)

  printf '================================================================\n'
  printf ' setup.sh run log\n'
  printf ' Started: %s\n' "$(_timestamp)"
  printf ' Script : %s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  printf ' Log    : %s\n' "$RUN_LOG_FILE"
  printf '================================================================\n'
  log_environment "$@"
}

finish_run_log() {
  local rc=${1:-0} end duration
  (( RUN_LOG_STARTED )) || return 0
  end=$(date +%s)
  duration=$(( end - RUN_LOG_START_EPOCH ))
  printf '\n--- run finished ---\n'
  printf 'Result    : %s (exit %s)\n' "$([[ $rc -eq 0 ]] && printf SUCCESS || printf FAILURE)" "$rc"
  printf 'Finished  : %s\n' "$(_timestamp)"
  printf 'Duration  : %s\n' "$(format_duration "$duration")"
  printf 'Full log  : %s\n' "$RUN_LOG_FILE"
  printf '%s\n' '--------------------'
  sync 2>/dev/null || true
  # Closing stdout lets tee see EOF.  Wait for it so a wrapper that reads the
  # log immediately after the process exits never sees a truncated file.
  exec 1>&- 2>&-
  [[ -n $RUN_LOG_TEE_PID ]] && wait "$RUN_LOG_TEE_PID" 2>/dev/null || true
  # The terminal wants the colours above; the copied log does not.  tee has
  # finished, so strip the ANSI sequences from the finished file in place.
  if [[ -n $RUN_LOG_FILE && -f $RUN_LOG_FILE ]]; then
    sed_in_place -E $'s/\x1b\\[[0-9;]*m//g' "$RUN_LOG_FILE" 2>/dev/null || true
    # Hand the finished log to the operator who ran sudo.  Done here, not in
    # start_run_log(), so root owns the file while tee still has it open (see
    # the protected_regular note above).
    give_to_invoking_user "$RUN_LOG_FILE"
  fi
  RUN_LOG_STARTED=0
}

# Every transient file and directory must live below /tmp.  These wrappers also
# ignore a caller's TMPDIR so an environment variable cannot move scratch data
# onto a live configuration or data path.  Nothing here removes its leftovers:
# the operating system expires them from /tmp.
readonly TMP_ROOT="/tmp"
# Make child tools that honour TMPDIR use /tmp as well.
export TMPDIR="$TMP_ROOT"

# One implementation for both file and directory creation.  --tmpdir forces the
# result below /tmp even when an inherited TMPDIR points somewhere else, and
# the post-check refuses an absolute caller template instead of writing beside
# a live config.
_tmp_mktemp() {
  local path
  path=$(TMPDIR="$TMP_ROOT" mktemp --tmpdir="$TMP_ROOT" "$@") || return 1
  [[ $path == "${TMP_ROOT}"/* ]] || {
    warn "Refusing scratch path outside ${TMP_ROOT}: ${path}"
    return 1
  }
  printf '%s\n' "$path"
}
# shellcheck disable=SC2120  # optional caller arguments are intentional
tmp_file() { _tmp_mktemp "$@"; }
# shellcheck disable=SC2120
tmp_dir()  { _tmp_mktemp -d "$@"; }

# GNU sed -i creates its scratch file next to the target, which is outside
# /tmp.  Stage the rewrite under /tmp and copy it over the original inode so
# permissions, ownership and hard links are preserved.  The staging file is
# deliberately left for /tmp to expire.
sed_in_place() {
  local file tmp
  (( $# >= 2 )) || return 2
  file=${!#}
  tmp=$(tmp_file) || return 1
  sed "$@" > "$tmp" || return 1
  cmp -s -- "$file" "$tmp" && return 0
  cat -- "$tmp" > "$file"
}

# Move a path that must leave its live location into a fresh /tmp directory.
# The data is preserved (never unlinked) and /tmp expires it automatically.
preserve_to_tmp() {
  local path=$1 dest base
  [[ -e $path || -L $path ]] || return 0
  base=$(basename -- "$path")
  dest=$(tmp_dir) || return 1
  mv -- "$path" "${dest}/${base}"
  printf '%s' "${dest}/${base}"
}

# Retire files or directories that no longer belong in a managed tree.  Each
# existing path is moved to its own /tmp directory (never unlinked), which is
# the file-safety policy documented in README.md; missing paths are ignored,
# so callers can pass fixed lists and unexpanded globs.
retire_paths() {
  local path moved
  for path in "$@"; do
    [[ -e $path || -L $path ]] || continue
    moved=$(preserve_to_tmp "$path" 2>/dev/null || true)
    if [[ -n $moved ]]; then
      info "Retired ${path} -> ${moved} (not deleted)"
    else
      warn "Could not move ${path} out of the live tree; leaving it in place"
    fi
  done
  return 0
}

# Restore a backed-up directory tree over a live path without deleting files
# that are not in the backup.  Used for install-time rollback of Angie/PHP.
# Restore the directory snapshot SRC over the live DST: overwrite in place
# (never unlink the live path first) and move files created after the
# snapshot to /tmp, so a generated file (a drop-in or ini the failed tune
# added) cannot win again after the rollback.  Prints one
# "moved <live-path> <tmp-path>" line per retired file for the caller to
# report; nothing is deleted.  Shared by the install-time rollbacks, the
# --purge restore and the --optimize rollback.
restore_snapshot_dir() {
  local src=$1 dst=$2 extra rel moved
  [[ -n $src && -d $src ]] || return 1
  mkdir -p "$dst" || return 1
  cp -a "${src}/." "$dst/" 2>/dev/null || return 1
  while IFS= read -r -d '' extra; do
    rel=${extra#"$dst"/}
    [[ -e "${src}/${rel}" ]] && continue
    moved=$(preserve_to_tmp "$extra" 2>/dev/null) || continue
    [[ -n $moved ]] && printf 'moved %s %s\n' "$extra" "$moved"
  done < <(find "$dst" -type f -print0 2>/dev/null)
  return 0
}

restore_tree() {
  local source=$1 target=$2 line
  [[ -n $source && -d $source ]] || return 0
  local out rc=0
  out=$(tmp_file) || return 1
  restore_snapshot_dir "$source" "$target" > "$out" || rc=1
  while IFS= read -r line; do
    [[ $line == moved\ * ]] || continue
    warn "Rollback moved generated ${line#moved } (not deleted)"
  done < "$out"
  return "$rc"
}

rollback_angie_tree() {
  local backup=$1
  [[ -n $backup && -d "${backup}/angie" ]] || return 0
  restore_tree "${backup}/angie" /etc/angie \
    || warn "Could not restore the previous /etc/angie tree"
  if /usr/sbin/angie -t >/dev/null 2>&1; then
    systemctl reload angie 2>/dev/null || systemctl restart angie 2>/dev/null || true
    warn "Rolled back Angie configuration from ${backup}"
  else
    warn "Angie rollback restored files but angie -t still fails"
  fi
}

rollback_php_tree() {
  local backup=$1 ver=$2
  [[ -n $backup && -d "${backup}/fpm" ]] || return 0
  restore_tree "${backup}/fpm" "/etc/php/${ver}/fpm" \
    || warn "Could not restore the previous PHP ${ver} tree"
  if "php-fpm${ver}" -t >/dev/null 2>&1; then
    systemctl restart "php${ver}-fpm" 2>/dev/null || true
    warn "Rolled back PHP ${ver} configuration from ${backup}"
  else
    warn "PHP ${ver} rollback restored files but php-fpm${ver} -t still fails; not restarted"
  fi
}

on_error() {
  local rc=$? line=${1:-?} cmd=${BASH_COMMAND:-unknown}
  # A downstream consumer closing the pipe (for example `setup.sh --help |
  # head`) makes tee exit with SIGPIPE (128+13).  That is not a script
  # failure; suppress it so the run log stays free of false [ERR] lines.
  if (( rc == 141 )); then
    return 0
  fi
  # A mode driver that already reported its failure (optimize report,
  # restart-all summary) returns non-zero through handled_return; main()
  # then exits with that status under set -e without a duplicate [ERR] line.
  if (( ${RUN_HANDLED_FAILURE:-0} )); then
    return 0
  fi
  # Keep the failing command on one line and bounded, so a large heredoc or a
  # generated SQL statement does not flood the operator's terminal/log.
  cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-200)
  printf '%s %s[ERR ]%s command failed (exit %s) at line %s: %s\n' \
    "$(_timestamp)" "$C_RED" "$C_RESET" "$rc" "$line" "$cmd" >&2
}
trap 'on_error $LINENO' ERR

# Set by handled_return when a mode driver exits non-zero on purpose.
RUN_HANDLED_FAILURE=0
# Return RC from a driver whose failure is already explained to the operator.
# The drivers are called plainly from main() so set -e and the ERR trap stay
# live inside them (bash suspends both for the whole function body when the
# call is the condition of `if !` or part of a && / || list).
handled_return() {
  local rc=${1:-0}
  if (( rc != 0 )); then
    RUN_HANDLED_FAILURE=1
  fi
  return "$rc"
}

# Serialise real runs.  Two concurrent invocations (an operator plus a cron or
# CI job) can interleave config rewrites and leave a half-written service
# file behind.  The lock lives in /run (root-owned) rather than the
# world-writable /tmp so another local user cannot pre-create a symlink and
# make root truncate an arbitrary file.  Dry-runs do not take the lock.
readonly LOCK_FILE="/run/setup.sh.lock"
LOCK_HELD=0

acquire_run_lock() {
  (( DRY_RUN )) && return 0
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock not available; continuing without a run lock"
    return 0
  fi
  # /run is root-owned; refuse a symlink defensively in case an older install
  # or a compromised account created the path.
  [[ -L $LOCK_FILE ]] && die "Refusing symlinked run lock ${LOCK_FILE}"
  ( umask 077; : >> "$LOCK_FILE" ) 2>/dev/null \
    || die "Could not create the run lock ${LOCK_FILE}"
  exec 9>"$LOCK_FILE" || die "Could not open the run lock ${LOCK_FILE}"
  if ! flock -n 9; then
    exec 9>&-
    die "Another setup.sh run is already in progress (lock: ${LOCK_FILE})"
  fi
  LOCK_HELD=1
}

release_run_lock() {
  (( LOCK_HELD )) || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&-
  LOCK_HELD=0
  return 0
}

format_duration() {
  local s=${1:-0}
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

# Retry a command: retry <attempts> <delay-seconds> <cmd...>
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    warn "Attempt ${n}/${attempts} failed: $* -- retrying in ${delay}s"
    sleep "$delay"
    (( n++ ))
  done
}

apt_update()  { retry 3 5 apt-get -o DPkg::Lock::Timeout=300 \
  -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update -y && APT_LISTS_FRESH=1; }
# Refresh the package lists at most once per run (update_system and the
# repository setup already count); used by the few installs outside them.
APT_LISTS_FRESH=0
apt_update_once() {
  (( APT_LISTS_FRESH )) && return 0
  apt_update || warn "apt-get update failed; continuing with the existing package lists"
  return 0
}
apt_install() {
  # --no-remove aborts instead of letting APT uninstall a conflicting package.
  apt-get install --no-remove "${APT_OPTS[@]}" --no-install-recommends "$@"
}
apt_clean() {
  # Intentionally a no-op.  autoremove/autoclean/clean permanently delete
  # packages and cached archives, which setup.sh must never do on a live host.
  :
}

