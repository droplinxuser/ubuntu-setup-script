#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Ubuntu 26.04 server provisioning
# =============================================================================
#  Usage is documented in usage() below and in the project notes.
#
#  Design notes:
#   * Runs as root only.
#   * Idempotent: every step can be re-run on an already configured machine.
#   * Only the services named on the command line are touched.
#   * Angie configuration is owned by
#     https://github.com/droplinxuser/server-configs-nginx and downloaded at
#     install time.  PHP-FPM pool/php.ini templates are non-Angie config and
#     live locally in configs/php.  Do not add Angie config content to this
#     script; update the Angie repo.
#     Other vendor payloads that must be reproducible offline are embedded in
#     the "EMBEDDED PAYLOADS" section at the bottom.
#   * Each service is timed; a summary is printed at the end.
#   * Every run mirrors its complete output to setup_<timestamp>.log in the
#     invocation directory so the log can be handed to a debugging agent.
#   * `--purge` stops/disables selected services and restores recorded basic
#     settings; it never removes packages, data, configuration or log files.
# =============================================================================

set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s: bash 4.0 or newer is required (found %s)\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 1
fi
shopt -s inherit_errexit 2>/dev/null || true
umask 022
# Providers often ship an ungenerated locale (e.g. en_PH.UTF-8), which makes
# apt/perl print noisy warnings. C.UTF-8 always exists on Ubuntu.
export LC_ALL=C.UTF-8

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.8.43"
# Congestion control and qdisc for the OS profile.  BBR is a good default on
# lossy long-haul links, but it can regress a busy reverse proxy badly (a
# 40% throughput drop was measured on one host).  Operators can pin a host
# with SETUP_TCP_CC / SETUP_QDISC or /etc/default/setup-tuning:
#   TCP_CC="cubic"
#   QDISC="fq_codel"
TCP_CC=bbr
QDISC=fq
if [[ -r /etc/default/setup-tuning ]]; then
  # shellcheck disable=SC1091
  . /etc/default/setup-tuning
  TCP_CC="${TCP_CC:-bbr}"
  QDISC="${QDISC:-fq}"
fi
# The environment wins over the host file so a one-off run can be tested.
TCP_CC="${SETUP_TCP_CC:-$TCP_CC}"
QDISC="${SETUP_QDISC:-$QDISC}"
[[ $TCP_CC =~ ^[a-z0-9_]+$ ]] || TCP_CC=bbr
[[ $QDISC =~ ^[a-z0-9_]+$ ]] || QDISC=fq
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly STATE_DIR="/var/lib/setup.sh"
readonly BACKUP_DIR="${STATE_DIR}/backup"
# Every service writes its logs below this single directory so an operator can
# collect one tree (tar -czf /tmp/logs.tgz -C /var/www logs) for inspection.
readonly LOG_ROOT="/var/www/logs"
# Angie and PHP configuration is owned by this repository, not by setup.sh.
# Override the ref or point CONFIG_SOURCE_DIR at a local checkout for testing.
readonly CONFIG_REPO_URL="${CONFIG_REPO_URL:-https://github.com/droplinxuser/server-configs-nginx}"
readonly CONFIG_REPO_REF="${CONFIG_REPO_REF:-main}"
CONFIG_SOURCE_DIR="${CONFIG_SOURCE_DIR:-}"
CONFIG_TEMP_DIR=""
readonly CRON_BEGIN="# BEGIN setup.sh managed cron"
readonly CRON_END="# END setup.sh managed cron"
# Keep web content owned by www-data without touching the shared log tree.
# MariaDB, Valkey and Elasticsearch own subdirectories below /var/www/logs; a
# blanket recursive chown changes their owner to www-data and their next start
# or restart fails to open/rotate logs ("Permission denied", errno 13).
readonly CRON_WWW_CHOWN='/usr/bin/find /var/www -mindepth 1 \( -path /var/www/logs -o -path /var/www/mysql_database -o -name "*.log" \) -prune -o -exec /usr/bin/chown -h www-data:www-data {} +'
# The form written by releases up to 1.8.33, kept so a re-run upgrades it.
readonly CRON_WWW_CHOWN_LEGACY='/usr/bin/chown www-data:www-data -R /var/www/'
readonly MARIADB_BEGIN="# BEGIN setup.sh managed mariadb"
readonly MARIADB_END="# END setup.sh managed mariadb"
readonly ES_BEGIN="# BEGIN setup.sh managed elasticsearch"
readonly ES_END="# END setup.sh managed elasticsearch"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
# Wait for a concurrent apt/dpkg run instead of failing outright (package
# management tools often hold the lock briefly).
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
          -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0
          -o Acquire::Retries=3 -o Acquire::http::Timeout=30)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# ---------------------------------------------------------------------------
# Logging / small helpers
# ---------------------------------------------------------------------------
_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
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
    && failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | paste -sd, - || true)
  command -v free >/dev/null 2>&1 && mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%sMB total, %sMB available", $2, $7}')
  command -v df >/dev/null 2>&1 && disk=$(df -Ph / 2>/dev/null | awk 'NR==2{printf "%s total, %s free on %s", $2, $4, $6}')

  printf '\n--- environment ---\n'
  printf 'Command      : %s %s\n' "$SCRIPT_NAME" "$(log_safe_args "$@")"
  printf 'Invocation   : %s\n' "${BASH_SOURCE[0]}"
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

start_run_log() {
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  RUN_LOG_FILE="${PWD}/setup_${stamp}.log"

  # Refuse to abort a real run just because the invocation directory is not
  # writable; the console output and normal diagnostics still work.
  if ! ( umask 077; : >> "$RUN_LOG_FILE" ) 2>/dev/null; then
    RUN_LOG_FILE=""
    warn "Could not create a run log in ${PWD}; continuing without a file log"
    return 0
  fi
  chmod 600 "$RUN_LOG_FILE" 2>/dev/null || true

  # tee mirrors every line to the terminal and the file.  The PID is saved so
  # finish_run_log() can wait for the final line to reach disk before exit.
  exec > >(tee -a "$RUN_LOG_FILE") 2>&1
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
tmp_file() { _tmp_mktemp "$@"; }
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

# Restore a backed-up directory tree over a live path without deleting files
# that are not in the backup.  Used for install-time rollback of Angie/PHP.
restore_tree() {
  local source=$1 target=$2
  [[ -n $source && -d $source ]] || return 0
  mkdir -p "$target" || return 1
  cp -a "${source}/." "$target/" 2>/dev/null || return 1
  return 0
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
  systemctl restart "php${ver}-fpm" 2>/dev/null || true
  warn "Rolled back PHP ${ver} configuration from ${backup}"
}

on_error() {
  local rc=$? line=${1:-?} cmd=${BASH_COMMAND:-unknown}
  # Keep the failing command on one line and bounded, so a large heredoc or a
  # generated SQL statement does not flood the operator's terminal/log.
  cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-200)
  printf '%s %s[ERR ]%s command failed (exit %s) at line %s: %s\n' \
    "$(_timestamp)" "$C_RED" "$C_RESET" "$rc" "$line" "$cmd" >&2
}
trap 'on_error $LINENO' ERR

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
  -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update -y; }
apt_install() {
  # --no-remove aborts instead of letting APT uninstall a conflicting package.
  apt-get install --no-remove "${APT_OPTS[@]}" --no-install-recommends "$@"
}
apt_clean() {
  # Intentionally a no-op.  autoremove/autoclean/clean permanently delete
  # packages and cached archives, which setup.sh must never do on a live host.
  :
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
declare -A ENABLED=()
declare -A OPT=()
declare -A DOMAIN_APP=()
OTHERS=()
DOMAINS=()
PURGE=0
OPTIMIZE=0
DIAGNOSTICS=0
RESTART_ALL=0
DRY_RUN=0
PURGE_TARGETS=()
PURGE_ORDER=()
SERVICE_ORDER=(basic angie php mariadb valkey elastic others domain)
declare -A SVC_STATUS=()
declare -A SVC_SECONDS=()

usage() {
  cat <<'EOF'
Usage:
  setup.sh --basic [server=dedi|vps] [host=FQDN] [swap=SIZE] [time=REGION/CITY] [SERVICES]
  setup.sh --domain DOMAIN [DOMAIN...]

Basic (always required for an install; all values are optional):
  --basic [server=dedi|vps] [host=custom.host] [swap=8G] [time=Asia/Manila]
    server   auto-detected when omitted (systemd-detect-virt/DMI/cgroup)
    host     auto-generated when omitted: <threads>c-<RAM>g-<storage>
             e.g. 8c-32g-1T (8 threads, 32 GB RAM, 1 TB storage)
    swap     auto when omitted: only adds swap if current swap is 0 or
             below 50% of RAM; target total is 50% of RAM
    time     defaults to Asia/Manila

Services (optional; only the ones listed are installed):
  --angie
  --php       [ver=8.5] [children=auto|N] [max_requests=N]
      ver          PHP version (default: latest stable in Sury)
      children     PHP-FPM worker count (default: auto from RAM/CPU)
      max_requests recycle a worker after N requests (default: threads x 1024)
  --mariadb   user=demo pass=temp size=4gb|auto [bind=127.0.0.1[,ADDR...]|IPV4]
      size     auto = 40% of RAM (minimum 256 MB), sized to leave room for
               Elasticsearch, Valkey and PHP workers.
      bind     comma-separated IPv4 addresses and/or ::1 (default 127.0.0.1)
               IPV4 auto-detects the server's public IPv4; on NAT it falls
               back to the local outbound IPv4
               e.g. bind=127.0.0.1,2.3.4.5  or  bind=127.0.0.1,IPV4
  --valkey    [ram=2g] [policy=allkeys-lru] [io_threads=1]
      ram        maxmemory (default: 10% of RAM, clamped to 256 MB..8 GB)
      policy     maxmemory-policy (default allkeys-lru; use noeviction or
                 volatile-lru when Valkey stores sessions/jobs that must survive)
      io_threads extra socket I/O threads (default 1; raise only after
                 valkey-benchmark shows the main thread is saturated)
  --elastic   [ram=4g|auto] [host=localhost]
      ram        JVM heap (default: auto = 25% of RAM, clamped to
                 512 MB..31 GB, leaving room for MariaDB/Valkey/PHP)
  --others    smartmon nvme gif nodejs sysstat
              (or: --others all)
      nvme-cli is installed only on a dedicated server with NVMe storage.
      sysstat    sar/iostat performance history

Domain setup (standalone; Angie + MariaDB must already be installed/running):
  --domain DOMAIN [DOMAIN...] [app=TYPE]
      Creates:
        /var/www/<domain>/public/
        /etc/angie/conf.d/<domain>.conf   (ready vhost, or empty when app=blank)
        MariaDB database <domain with dots replaced by underscores>
      app=TYPE may be given inside a --domain group and applies to every
      domain in that group. TYPE is one of:
        blank (default) xf wordpress pingvin chevereto polr lychee php node
      Existing non-empty vhost files are preserved. A self-signed certificate
      is generated under /etc/angie/ssl/<domain>/; replace it with an ACME /
      Let's Encrypt certificate for production.
      Example: --domain forum.example.com app=xf
        -> /var/www/forum.example.com/public/
        -> /etc/angie/conf.d/forum.example.com.conf  (XenForo vhost)
        -> database forum_example_com
      --domain can be repeated and combined with a normal install. There is
      no --purge for domains; remove the files/database manually.

Optimize-only mode (Ubuntu 22.04, 24.04 or 26.04):
  --optimize [--dry-run]
      One command for the whole host.  It applies the hardware-aware OS
      profile (CPU governor, swap headroom, PAM security limits, and
      kernel/network/memory sysctls) and then tunes every installed service (Angie, PHP-FPM,
      MariaDB, Valkey or Redis, Elasticsearch) for the current CPU/RAM/disk.
      It never installs, purges or starts a managed service; the only package
      it may add is the small cpufrequtils helper when the CPU exposes
      frequency scaling.  Allocations are planned together from one
      80%-of-RAM budget, and a service is reloaded (Angie, PHP-FPM) or tuned
      online (Valkey/Redis) only when its generated configuration actually
      changed.  Startup-only settings are reported and apply on the next full
      restart.  Existing PHP-FPM listeners are kept;
      when a pool already listens on a Unix socket, Angie's fastcgi_pass is
      repointed to it.  TCP pools stay on TCP so a live site is never left
      pointing at a missing socket.
      Hosts built before 1.8.34 also get the legacy nightly
      `chown -R /var/www/` crontab entry migrated to the log-safe find form,
      and /var/www/logs ownership repaired before any service is restarted.
      Configuration files are backed up under /tmp/setup-optimize-*
      and a Markdown report is written to /var/log/setup-optimize-*.md.
      Existing application vhosts and credentials are preserved.
      --dry-run only prints the planned OS and service values.

Purge (stop/restore) mode:
  --purge [all|basic|angie|php|mariadb|valkey|elastic|others]
  --purge --angie --php                 stop only the selected services
  --purge                               stop everything this script manages
  --purge --php ver=8.5                 stop one PHP version (note --php)
  --purge php mariadb                   bare names are also accepted
  No file, package, database, certificate or log is deleted.  Configuration
  is restored only by overwriting it with the recorded original.  Leftovers
  under /tmp are allowed to expire on their own.

Configuration source:
  Angie configuration is downloaded from
  https://github.com/droplinxuser/server-configs-nginx at install time.
  PHP-FPM pool and php.ini templates are local to this repository
  (configs/php) because they are not Angie configuration.
  Environment overrides:
    CONFIG_SOURCE_DIR=/path/to/checkout   use a local checkout (testing/offline)
    CONFIG_REPO_URL=https://github.com/... alternate repository
    CONFIG_REPO_REF=main                   branch or tag to download

Testing:
  --dry-run                             parse and validate only; show the plan
                                        without changing the system (works as
                                        a normal user and with --purge)

Diagnostics:
  --diagnostics
      Collects host/hardware details, running services and their status,
      Angie/PHP/MariaDB/Valkey/Redis/Elasticsearch runtime statistics,
      slow-query and slow-request logs, service error logs and kernel/OOM
      reports into diagnostics.log beside setup.sh.  Run as root; this mode
      only reads state and writes that one file.

Restart all:
  --restart-all
      Detects installed/running services, reloads systemd, stops Angie and
      every active PHP-FPM version, restarts active Valkey/Redis,
      Elasticsearch and MariaDB, waits for MariaDB SELECT 1, then starts
      PHP-FPM followed by Angie.  Only services that were active are stopped
      and started again.  Use --dry-run to print the detected plan.

Notes:
  * Every run mirrors its full output to setup_<timestamp>.log in the
    directory where setup.sh was started.  Copy that file when reporting an
    issue; it includes the host facts and the exit status.
  * Only one PHP-FPM version can own the shared Unix socket at a time.
    Switch versions by purging the old one first:
      --purge --php ver=8.4   then   --basic ... --php ver=8.5

Examples:
  bash setup.sh --basic server=dedi host=custom.host time=Asia/Manila swap=8G \
      --angie --php ver=8.5 --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
      --valkey --elastic host=localhost ram=4g --others smartmon nvme gif nodejs

  bash setup.sh --basic --angie --php

  bash setup.sh --basic --mariadb user=demo pass=temp size=4gb \
      bind=127.0.0.1,IPV4

  bash setup.sh --domain google.com
  bash setup.sh --domain google.com example.org

  bash setup.sh --purge all
EOF
}

kv_set() {
  local ctx=$1 key=$2 val=$3
  case "${ctx}:${key}" in
    basic:server|basic:host|basic:time|basic:swap) ;;
    php:ver|php:children|php:max_requests) ;;
    mariadb:user|mariadb:pass|mariadb:size|mariadb:bind) ;;
    valkey:ram|valkey:policy|valkey:io_threads) ;;
    elastic:host|elastic:ram) ;;
    *) die "--${ctx}: unknown option '${key}'" ;;
  esac
  OPT["${ctx}.${key}"]=$val
}

NORMALIZED_ARGS=()
# People paste commands from documentation into shells that keep typographic
# dashes (em dash U+2014, en dash U+2013). Accept them instead of failing with
# "Unknown argument" and rewrite them to ASCII "--".
normalize_cli_args() {
  local arg
  NORMALIZED_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      —*|–*) arg="--${arg#?}" ;;
    esac
    NORMALIZED_ARGS+=("$arg")
  done
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --basic)
        ENABLED[basic]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          [[ $1 == *=* ]] || die "--basic: expected key=value, got '$1'"
          kv_set basic "${1%%=*}" "${1#*=}"; shift
        done
        ;;
      --php)
        ENABLED[php]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          [[ $1 == *=* ]] || die "--php: expected key=value, got '$1'"
          kv_set php "${1%%=*}" "${1#*=}"; shift
        done
        ;;
      --mariadb)
        ENABLED[mariadb]=1; shift
        local last_key=""
        while (( $# )) && [[ $1 != --* ]]; do
          if [[ $1 == *=* ]]; then
            last_key=${1%%=*}
            kv_set mariadb "$last_key" "${1#*=}"
          elif [[ $last_key == bind ]]; then
            # Allow: bind=127.0.0.1, 2.3.4.5  (the shell splits on the space)
            OPT[mariadb.bind]="${OPT[mariadb.bind]:-},$1"
          else
            die "--mariadb: expected key=value, got '$1'"
          fi
          shift
        done
        ;;
      --elastic)
        ENABLED[elastic]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          [[ $1 == *=* ]] || die "--elastic: expected key=value, got '$1'"
          kv_set elastic "${1%%=*}" "${1#*=}"; shift
        done
        ;;
      --angie) ENABLED[angie]=1; shift ;;
      --valkey)
        ENABLED[valkey]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          [[ $1 == *=* ]] || die "--valkey: expected key=value, got '$1'"
          kv_set valkey "${1%%=*}" "${1#*=}"; shift
        done
        ;;
      --others)
        ENABLED[others]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          OTHERS+=("$1"); shift
        done
        ;;
      --domain)
        ENABLED[domain]=1; shift
        local got_domain=0 d app="" key default_app="" last_app=""
        local app_count=0 app_at_end=0
        local -a group=()
        while (( $# )) && [[ $1 != --* ]]; do
          case "$1" in
            app=*)
              app=${1#*=}
              app_count=$(( app_count + 1 ))
              last_app=$app
              app_at_end=1
              if (( ${#group[@]} > 0 )); then
                # app=TYPE belongs to the domain immediately before it.
                key=${group[-1],,}; key=${key%.}
                DOMAIN_APP[$key]=$app
              else
                # app=TYPE before any domain sets the group default.
                default_app=$app
              fi
              shift
              continue
              ;;
          esac
          d=${1,,}; d=${d%.}
          group+=("$d"); got_domain=1
          # A domain after app= means that app= was per-domain, not a
          # trailing group default.
          app_at_end=0
          [[ -n $default_app ]] && DOMAIN_APP[$d]=$default_app
          shift
        done
        (( got_domain )) || die "--domain requires at least one domain name"
        for d in "${group[@]}"; do
          DOMAINS+=("$d")
          key=${d,,}; key=${key%.}
          # Preserve the documented single app=TYPE behaviour: one app= after
          # the whole list applies to every domain in this group.
          if (( app_count == 1 && app_at_end == 1 )) && [[ -n $last_app ]]; then
            DOMAIN_APP[$key]=$last_app
          fi
        done
        ;;
      --optimize)
        OPTIMIZE=1; shift ;;
      --diagnostics)
        DIAGNOSTICS=1; shift ;;
      --restart-all)
        RESTART_ALL=1; shift ;;
      --purge)
        PURGE=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          PURGE_TARGETS+=("$1"); shift
        done
        ;;
      --dry-run|--check) DRY_RUN=1; shift ;;
      --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: '$1' (use --help)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# --optimize touches only service configuration, so it is safe on every LTS
# that still supports the installed packages.  Ubuntu 22.04 shares the same
# Angie/PHP/MariaDB/Valkey service layout and is supported until 2027.
optimize_os_supported() {
  case "${1%%.*}" in
    22|24|26) return 0 ;;
    *) return 1 ;;
  esac
}

validate_timezone() {
  local tz=$1
  [[ $tz =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -e "/usr/share/zoneinfo/${tz}" ]]
}

validate_hostname() {
  local h=$1
  (( ${#h} >= 1 && ${#h} <= 253 )) || return 1
  [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  for o in $ip; do
    [[ -n $o ]] || return 1
    if (( 10#$o > 255 )); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# MariaDB bind-address helpers
# ---------------------------------------------------------------------------
detect_local_ipv4() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }}' || true)
    if [[ -z $ip ]]; then
      ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]; exit}' || true)
    fi
  fi
  if [[ -z $ip ]]; then
    ip=$(hostname -I 2>/dev/null \
      | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  fi
  if [[ -n $ip ]] && validate_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

detect_public_ipv4() {
  command -v curl >/dev/null 2>&1 || return 1
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --connect-timeout 2 --max-time 4 "$url" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if validate_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

is_local_ipv4() {
  local ip=$1
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null \
      | awk -v ip="$ip" '{split($4, a, "/"); if (a[1] == ip) found = 1} END {exit !found}'
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF -- "$ip"
  fi
}

# Effective sshd TCP ports, one per line.  `sshd -T` respects Include files,
# drop-ins and package defaults; the sshd_config scan is a fallback for a
# non-root caller.  Always returns at least port 22.
sshd_listen_ports() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    ports=$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" {print $2}')
  fi
  if [[ -z $ports && -r /etc/ssh/sshd_config ]]; then
    ports=$(awk 'tolower($1) == "port" {print $2}' /etc/ssh/sshd_config)
  fi
  ports=$(printf '%s\n' "$ports" | grep -E '^[0-9]+$' | sort -nu)
  [[ -n $ports ]] || ports=22
  printf '%s\n' "$ports"
}

# Peer address from `ss -t` output.  The last two fields are always
# Local Address:Port and Peer Address:Port; the State column is present or
# absent depending on the ss version and flags (with -H + a state filter this
# host emits four fields).  Reading a fixed column is therefore unsafe:
# field 4 is the server address in the five-field form and the client address
# in the four-field form.  An optional local-port regex keeps ordinary web
# connections out of the result.
ssh_peer_from_ss() {
  local port_re=${1:-}
  awk -v re="$port_re" '
    NF >= 4 {
      local_addr = $(NF - 1)
      peer = $NF
      if (re != "" && local_addr !~ re) next
      print peer
    }' \
    | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//' \
    | grep -vE '^(127\.|::1$|0\.0\.0\.0$|::$)' \
    | head -n1
}

# Best-effort detection of the SSH client address that started this run.
# sudo normally strips SSH_CONNECTION from the child environment, so also walk
# the parent process chain and, as a last resort, inspect established sshd
# sockets.
detect_ssh_client_ip() {
  local ip="${SSH_CONNECTION:-}" pid=$PPID i env
  ip=${ip%% *}
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] && { printf '%s' "$ip"; return 0; }
  for ((i = 0; i < 6; i++)); do
    [[ -r "/proc/${pid}/environ" ]] || break
    env=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null || true)
    ip=$(printf '%s\n' "$env" \
      | awk -F= '/^SSH_CONNECTION=/{print $2; exit}' | awk '{print $1}')
    [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] && { printf '%s' "$ip"; return 0; }
    pid=$(awk '{print $4}' "/proc/${pid}/stat" 2>/dev/null || true)
    [[ -n $pid && $pid != 0 ]] || break
  done
  local ssh_ports_re
  ssh_ports_re=$(sshd_listen_ports | paste -sd'|' -)
  ip=$(ss -tnH state established 2>/dev/null \
    | ssh_peer_from_ss ":(${ssh_ports_re})$" || true)
  [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] && printf '%s' "$ip"
  return 0
}

# Resolve the IPV4 keyword to a usable local address.  Sets REPLY.
resolve_ipv4_token() {
  local public localip
  if [[ -n ${RESOLVED_IPV4_TOKEN:-} ]]; then
    REPLY=$RESOLVED_IPV4_TOKEN
    return 0
  fi

  public=$(detect_public_ipv4 || true)
  if [[ -n $public ]]; then
    if is_local_ipv4 "$public"; then
      REPLY=$public
      RESOLVED_IPV4_TOKEN=$public
      return 0
    fi
    warn "Public IPv4 ${public} is not assigned to this host (NAT/proxy?)"
    localip=$(detect_local_ipv4 || true)
    if [[ -n $localip ]]; then
      warn "bind=IPV4 will use the local outbound IPv4 ${localip}"
      REPLY=$localip
      RESOLVED_IPV4_TOKEN=$localip
      return 0
    fi
    return 1
  fi

  localip=$(detect_local_ipv4 || true)
  if [[ -n $localip ]]; then
    warn "Could not detect the public IPv4; bind=IPV4 will use local IPv4 ${localip}"
    REPLY=$localip
    RESOLVED_IPV4_TOKEN=$localip
    return 0
  fi
  return 1
}

# Validate and normalise a comma-separated bind list.  IPV4 is kept as a token
# here and resolved later, after --basic has installed curl.  Sets REPLY.
normalize_mariadb_bind() {
  local raw token normalized="" seen=" "
  local -a tokens
  BIND_BAD_TOKEN=""
  raw=$(printf '%s' "$1" | tr -d '[:space:]')
  [[ -n $raw ]] || { BIND_BAD_TOKEN="empty address"; return 1; }

  IFS=',' read -r -a tokens <<< "$raw"
  for token in "${tokens[@]}"; do
    [[ -n $token ]] || continue
    if [[ ${token^^} == IPV4 ]]; then
      token=IPV4
    elif [[ $token == "::1" ]]; then
      :
    elif ! validate_ipv4 "$token"; then
      BIND_BAD_TOKEN=$token
      return 1
    fi
    [[ $seen == *" ${token} "* ]] && continue
    seen+="${token} "
    normalized+="${normalized:+,}${token}"
  done

  [[ -n $normalized ]] || { BIND_BAD_TOKEN="empty address"; return 1; }
  REPLY=$normalized
  return 0
}

# Replace every IPV4 token with the detected address.  Sets REPLY.
resolve_mariadb_bind() {
  local token normalized="" seen=" "
  local -a tokens
  BIND_BAD_TOKEN=""
  IFS=',' read -r -a tokens <<< "$1"
  for token in "${tokens[@]}"; do
    if [[ ${token^^} == IPV4 ]]; then
      if ! resolve_ipv4_token; then
        BIND_BAD_TOKEN="could not detect an IPv4 address for IPV4"
        return 1
      fi
      token=$REPLY
    fi
    [[ $seen == *" ${token} "* ]] && continue
    seen+="${token} "
    normalized+="${normalized:+,}${token}"
  done
  [[ -n $normalized ]] || { BIND_BAD_TOKEN="empty address"; return 1; }
  REPLY=$normalized
  return 0
}

validate_domain() {
  local d=${1,,}
  d=${d%.}
  (( ${#d} >= 3 && ${#d} <= 253 )) || return 1
  [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

domain_to_db() {
  local d=${1,,}
  d=${d//./_}
  printf '%s' "$d" | sed 's/[^a-z0-9_]/_/g'
}

normalize_app() {
  local a=${1,,}
  case "$a" in
    ""|blank|none|plain) printf 'blank' ;;
    xf|xenforo)          printf 'xf' ;;
    wp|wordpress)        printf 'wordpress' ;;
    pingvin)             printf 'pingvin' ;;
    chev|chevereto)      printf 'chevereto' ;;
    polr)                printf 'polr' ;;
    lychee)              printf 'lychee' ;;
    node|nodejs)         printf 'node' ;;
    php|generic)         printf 'php' ;;
    *) return 1 ;;
  esac
}

detect_server_type() {
  # Prefer systemd's virtualization probe: exit 0 means a VM/container.
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --quiet; then
      printf 'vps'
    else
      printf 'dedi'
    fi
    return 0
  fi

  local dmi=""
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    dmi=$(< /sys/class/dmi/id/product_name)
    case "${dmi,,}" in
      *kvm*|*vmware*|*virtualbox*|*qemu*|*xen*|*hyper-v*|*amazon*|*google*|*digitalocean*|*openstack*|*bochs*|*parallels*)
        printf 'vps'; return 0 ;;
    esac
  fi
  if grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
    printf 'vps'; return 0
  fi
  printf 'dedi'
}

detect_ram_gb() {
  local total_kb=0
  if command -v dmidecode >/dev/null 2>&1; then
    total_kb=$(dmidecode -t memory 2>/dev/null | awk '
      /^[[:space:]]*Size:/ && $2 ~ /^[0-9]+$/ {
        if ($3 == "GB") sum += $2 * 1024 * 1024;
        else if ($3 == "MB") sum += $2 * 1024;
        else if ($3 == "TB") sum += $2 * 1024 * 1024 * 1024;
      }
      END { print sum + 0 }')
  fi
  if (( total_kb <= 0 )); then
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  fi
  awk -v kb="$total_kb" 'BEGIN { printf "%.0f", kb / 1024 / 1024 }'
}

detect_storage() {
  local total=0
  total=$(lsblk -b -d -n -o SIZE,TYPE 2>/dev/null | awk '$2=="disk"{sum+=$1} END{print sum+0}')
  if (( total <= 0 )); then
    total=$(df -B1 --output=size / 2>/dev/null | awk 'NR==2{print $1}')
  fi
  if (( total >= 1000000000000 )); then
    printf '%dT' $(( total / 1000000000000 ))
  elif (( total >= 1000000000 )); then
    printf '%dG' $(( total / 1000000000 ))
  else
    printf '%dM' $(( total / 1000000 ))
  fi
}

generate_hostname() {
  printf '%sc-%sg-%s' "$(nproc)" "$(detect_ram_gb)" "$(detect_storage)"
}

is_nvme_storage() {
  local dev
  for dev in /sys/block/nvme*; do
    [[ -e $dev ]] || continue
    return 0
  done
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o TRAN 2>/dev/null | grep -qx nvme && return 0
  fi
  return 1
}

# Storage class shared by the MariaDB I/O-capacity and Angie cache tuners so
# install and --optimize classify the same disk the same way.
storage_class() {
  if is_nvme_storage; then
    printf 'nvme'
  elif command -v lsblk >/dev/null 2>&1 \
       && lsblk -d -n -o ROTA 2>/dev/null | grep -q '^0'; then
    printf 'ssd'
  else
    printf 'hdd'
  fi
}

latest_sury_php() {
  local pkg ver cand upstream best=""
  while read -r pkg; do
    ver=${pkg#php}
    ver=${ver%-fpm}
    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/^[[:space:]]*Candidate:/{print $2}')
    cand=${cand%%$'\n'*}
    [[ -n $cand && $cand != "(none)" ]] || continue
    upstream=${cand#*:}
    upstream=${upstream%%-*}
    # Ignore alpha/beta/RC/dev packages: their upstream version has a suffix.
    [[ $upstream =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z $best ]] || [[ $(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -n1) == "$ver" ]]; then
      best=$ver
    fi
  done < <(apt-cache pkgnames 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-fpm$' | sort -u)
  printf '%s' "$best"
}

validate_all() {
  local svc

  if (( OPTIMIZE )); then
    (( DIAGNOSTICS )) && die "--optimize cannot be combined with --diagnostics"
    (( RESTART_ALL )) && die "--optimize cannot be combined with --restart-all"
    (( PURGE )) && die "--optimize cannot be combined with --purge"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--optimize cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--optimize scans installed services and cannot be combined with install flags"
    return 0
  fi

  if (( DIAGNOSTICS )); then
    (( PURGE )) && die "--diagnostics cannot be combined with --purge"
    (( RESTART_ALL )) && die "--diagnostics cannot be combined with --restart-all"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--diagnostics cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--diagnostics only reads the host and cannot be combined with install flags"
    return 0
  fi

  if (( RESTART_ALL )); then
    (( PURGE )) && die "--restart-all cannot be combined with --purge"
    (( OPTIMIZE )) && die "--restart-all cannot be combined with --optimize"
    (( DIAGNOSTICS )) && die "--restart-all cannot be combined with --diagnostics"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--restart-all cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--restart-all only restarts installed services and cannot be combined with install flags"
    return 0
  fi

  for svc in "${!ENABLED[@]}"; do
    case "$svc" in
      basic|angie|php|mariadb|valkey|elastic|others|domain) ;;
      *) die "Internal error: bad service '${svc}'" ;;
    esac
  done

  if [[ ${PURGE} -eq 1 ]]; then
    if [[ ${#DOMAINS[@]} -gt 0 ]]; then
      die "--domain cannot be combined with --purge (remove domain files/database manually)"
    fi
    local t
    for t in "${PURGE_TARGETS[@]}"; do
      case "$t" in
        all|basic|angie|php|mariadb|valkey|elastic|others) ;;
        *) die "--purge: unknown target '${t}'" ;;
      esac
    done
    if [[ ${#PURGE_TARGETS[@]} -eq 0 ]] && [[ ${#ENABLED[@]} -eq 0 ]]; then
      PURGE_TARGETS=(all)
    fi
    if [[ -n ${OPT[php.ver]:-} ]]; then
      [[ ${OPT[php.ver]} =~ ^[0-9]+\.[0-9]+$ ]] \
        || die "--purge --php ver='${OPT[php.ver]}' is invalid (use e.g. 8.5)"
    fi
    return 0
  fi

  if [[ ${ENABLED[basic]:-0} -ne 1 ]]; then
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
      die "--basic is required (see --help)"
    fi
    local s other=0
    for s in angie php mariadb valkey elastic others; do
      [[ ${ENABLED[$s]:-0} -eq 1 ]] && other=1
    done
    (( other == 0 )) || die "--basic is required when installing services other than --domain"
  fi

  if [[ -n ${OPT[basic.server]:-} ]]; then
    [[ ${OPT[basic.server]} == dedi || ${OPT[basic.server]} == vps ]] \
      || die "--basic server= must be 'dedi' or 'vps'"
  fi
  if [[ -n ${OPT[basic.host]:-} ]]; then
    validate_hostname "${OPT[basic.host]}" \
      || die "--basic host='${OPT[basic.host]}' is not a valid hostname"
  fi
  if [[ -n ${OPT[basic.swap]:-} ]]; then
    local swap=${OPT[basic.swap]^^}
    [[ $swap =~ ^[1-9][0-9]*([KMGTP]i?)?$ ]] \
      || die "--basic swap='${OPT[basic.swap]}' is invalid (use e.g. 8G)"
    OPT[basic.swap]=$swap
  fi
  local tz=${OPT[basic.time]:-Asia/Manila}
  validate_timezone "$tz" || die "--basic time='${tz}' is not a valid timezone"
  OPT[basic.time]=$tz

  if [[ ${#DOMAINS[@]} -gt 0 ]]; then
    local d db app seen=" "
    local -a dedup=()
    for d in "${DOMAINS[@]}"; do
      d=${d,,}
      d=${d%.}
      validate_domain "$d" || die "--domain '${d}' is not a valid domain name"
      db=$(domain_to_db "$d")
      (( ${#db} <= 64 )) || die "Database name '${db}' for '${d}' exceeds 64 characters"
      app=${DOMAIN_APP[$d]:-blank}
      app=$(normalize_app "$app") \
        || die "--domain '${d}': unknown app='${app}' (use blank, xf, wordpress, pingvin, chevereto, polr, lychee, php or node)"
      DOMAIN_APP[$d]=$app
      [[ $seen == *" $d "* ]] && continue
      seen+="${d} "
      dedup+=("$d")
    done
    DOMAINS=("${dedup[@]}")
  fi

  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    if [[ -n ${OPT[php.ver]:-} ]]; then
      [[ ${OPT[php.ver]} =~ ^[0-9]+\.[0-9]+$ ]] \
        || die "--php ver='${OPT[php.ver]}' is invalid (use e.g. 8.5)"
    fi
    if [[ -n ${OPT[php.children]:-} ]]; then
      [[ ${OPT[php.children]} == auto || ${OPT[php.children]} =~ ^[1-9][0-9]*$ ]] \
        || die "--php children='${OPT[php.children]}' is invalid (use auto or a positive integer)"
    fi
    if [[ -n ${OPT[php.max_requests]:-} ]]; then
      [[ ${OPT[php.max_requests]} =~ ^[1-9][0-9]*$ ]] \
        || die "--php max_requests='${OPT[php.max_requests]}' is invalid (use a positive integer)"
    fi
  fi

  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then
    [[ -n ${OPT[mariadb.user]:-} ]] || die "--mariadb user= is required"
    [[ -n ${OPT[mariadb.pass]:-} ]] || die "--mariadb pass= is required"
    [[ -n ${OPT[mariadb.size]:-} ]] || die "--mariadb size= is required (for example size=4gb)"
    [[ ${OPT[mariadb.user]} =~ ^[A-Za-z0-9_]+$ ]] \
      || die "--mariadb user= may only contain letters, digits and underscore"
    [[ ${OPT[mariadb.pass]} != *$'\n'* ]] || die "--mariadb pass= must not contain a newline"
    [[ ${OPT[mariadb.size]} == auto || ${OPT[mariadb.size]} =~ ^[1-9][0-9]*([mM][bB]?|[gG][bB]?)$ ]] \
      || die "--mariadb size='${OPT[mariadb.size]}' is invalid (use auto, 4gb, 512m, ...)"
    local bind=${OPT[mariadb.bind]:-127.0.0.1}
    if ! normalize_mariadb_bind "$bind"; then
      die "--mariadb bind='${bind}' contains an invalid address '${BIND_BAD_TOKEN}'. Use comma-separated IPv4 addresses, ::1, and/or IPV4."
    fi
    OPT[mariadb.bind]=$REPLY
  fi

  if [[ ${ENABLED[valkey]:-0} -eq 1 ]]; then
    if [[ -n ${OPT[valkey.ram]:-} ]]; then
      [[ ${OPT[valkey.ram],,} == auto || ${OPT[valkey.ram]} =~ ^[1-9][0-9]*[gGmM]$ ]] \
        || die "--valkey ram='${OPT[valkey.ram]}' is invalid (use auto, 2g, 512m, ...)"
      OPT[valkey.ram]=${OPT[valkey.ram],,}
    fi
    local vpol=${OPT[valkey.policy]:-allkeys-lru}
    case "$vpol" in
      allkeys-lru|allkeys-lfu|volatile-lru|volatile-lfu|volatile-ttl|allkeys-random|volatile-random|noeviction) ;;
      *) die "--valkey policy='${vpol}' is invalid" ;;
    esac
    OPT[valkey.policy]=$vpol
    local vio=${OPT[valkey.io_threads]:-1}
    [[ $vio =~ ^[1-9][0-9]*$ ]] && (( vio <= 64 )) \
      || die "--valkey io_threads='${vio}' is invalid (use 1..64)"
    OPT[valkey.io_threads]=$vio
  fi

  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    local eram=${OPT[elastic.ram]:-auto}
    [[ ${eram,,} == auto || ${eram} =~ ^[1-9][0-9]*[gGmM]$ ]] \
      || die "--elastic ram='${eram}' is invalid (use auto, 4g, 512m, ...)"
    OPT[elastic.ram]=${eram,,}
    local ehost=${OPT[elastic.host]:-localhost}
    [[ $ehost =~ ^[A-Za-z0-9._:-]+$ ]] \
      || die "--elastic host='${ehost}' is invalid"
    if [[ $ehost =~ ^[0-9.]+$ ]]; then
      validate_ipv4 "$ehost" || die "--elastic host='${ehost}' is not a valid IPv4 address"
    fi
    OPT[elastic.host]=$ehost
  fi

  if [[ ${ENABLED[others]:-0} -eq 1 ]]; then
    [[ ${#OTHERS[@]} -gt 0 ]] || die "--others requires at least one of: smartmon nvme gif nodejs sysstat"
    local item expanded=()
    for item in "${OTHERS[@]}"; do
      case "$item" in
        all) expanded+=(smartmon nvme gif nodejs sysstat) ;;
        smartmon|nvme|gif|nodejs|sysstat) expanded+=("$item") ;;
        *) die "--others: unknown package '${item}'" ;;
      esac
    done
    # de-duplicate while keeping order
    local seen=" "
    OTHERS=()
    for item in "${expanded[@]}"; do
      [[ $seen == *" ${item} "* ]] && continue
      seen+="${item} "
      OTHERS+=("$item")
    done
  fi
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
ensure_state() { mkdir -p "$BACKUP_DIR"; }

# ---------------------------------------------------------------------------
# Centralised logs (/var/www/logs/<service>/)
# ---------------------------------------------------------------------------
ensure_log_dir() {
  local svc=$1 owner=$2 grp=$3
  local dir="${LOG_ROOT}/${svc}"
  mkdir -p "$dir"
  chmod 750 "$dir"
  if getent passwd "$owner" >/dev/null 2>&1; then
    # Recursive: logrotate leaves rotated files (app.log.1, *.gz, audit json)
    # behind.  A service restart (Valkey, Elasticsearch) fails when it cannot
    # reopen or rotate files still owned by the previous account.
    chown -R "$owner:$grp" "$dir" 2>/dev/null || true
  else
    chown root:root "$dir" 2>/dev/null || true
  fi
}

log_file() {
  local owner=$2 grp=$3
  local file="${LOG_ROOT}/$1"
  mkdir -p "$(dirname "$file")"
  [[ -e $file ]] || : > "$file"
  chmod 640 "$file"
  if getent passwd "$owner" >/dev/null 2>&1; then
    chown "$owner:$grp" "$file" 2>/dev/null || true
  else
    chown root:root "$file" 2>/dev/null || true
  fi
}

ensure_log_dirs() {
  mkdir -p "$LOG_ROOT"
  chmod 755 "$LOG_ROOT"
  ensure_log_dir angie         www-data     www-data
  ensure_log_dir php           www-data     www-data
  ensure_log_dir nodejs        www-data     www-data
  ensure_log_dir gifsicle      www-data     www-data
  getent passwd mysql         >/dev/null 2>&1 && ensure_log_dir mariadb       mysql        mysql
  getent passwd valkey        >/dev/null 2>&1 && ensure_log_dir valkey        valkey       valkey
  getent passwd elasticsearch >/dev/null 2>&1 && ensure_log_dir elasticsearch elasticsearch elasticsearch

  log_file angie/error.log        www-data www-data
  log_file php/php-fpm.log        www-data www-data
  log_file php/php-fpm-slow.log   www-data www-data
  log_file php/php-error.log      www-data www-data
  log_file nodejs/nodejs.log      www-data www-data
  log_file gifsicle/gifsicle.log  www-data www-data
  getent passwd mysql         >/dev/null 2>&1 && log_file mariadb/error.log mysql mysql
  getent passwd mysql         >/dev/null 2>&1 && log_file mariadb/slow.log  mysql mysql
  getent passwd mysql         >/dev/null 2>&1 && log_file mariadb/backup.log mysql mysql
  getent passwd mysql         >/dev/null 2>&1 && log_file mariadb/backup-err.log mysql mysql
  getent passwd valkey        >/dev/null 2>&1 && log_file valkey/valkey.log valkey valkey
  getent passwd elasticsearch >/dev/null 2>&1 && log_file elasticsearch/essearch.log elasticsearch elasticsearch
  # getent returns 2 when a service user is not installed yet; a chain ending
  # in that test must not fail the whole basic step.
  return 0
}

configure_logrotate() {
  local install_pkg=${1:-1}
  step "Log rotation (/var/www/logs)"
  if (( install_pkg )); then
    apt_install logrotate
  fi
  if ! command -v logrotate >/dev/null 2>&1; then
    warn "logrotate is not installed; /var/www/logs will not be rotated"
    return 0
  fi
  record_original /etc/logrotate.d/setup-logs logrotate-setup-logs
  cat > /etc/logrotate.d/setup-logs <<'EOF'
# Managed by setup.sh: central service logs and vhost error/access logs.
# copytruncate is used so services do not need a reopen signal. Rotation runs
# as root; per-service `su` lines would fail on a basic-only install where the
# valkey/elasticsearch users do not exist yet.
/var/www/logs/*/*.log /var/www/logs/elasticsearch/*.json /var/www/*/error.log /var/www/*/access.log {
    daily
    maxsize 1G
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  chmod 644 /etc/logrotate.d/setup-logs
  # Debug mode exits non-zero when a glob has no matches on a fresh install,
  # which is not an error. Surface only real syntax problems.
  local lr_out
  lr_out=$(logrotate -d /etc/logrotate.d/setup-logs 2>&1 || true)
  # Only real diagnostics start with "error:". Filenames such as error.log and
  # the word "considering" must not trigger the warning.
  if grep -qiE '^error:' <<<"$lr_out"; then
    warn "logrotate reported an issue: $(grep -iE '^error:' <<<"$lr_out" | head -n1)"
  fi
  ok "Log rotation configured"
}

record_original() {
  local path=$1 name=$2
  ensure_state
  [[ -f "${BACKUP_DIR}/${name}.recorded" ]] && return 0
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a "$path" "${BACKUP_DIR}/${name}"
    printf 'present\n' > "${BACKUP_DIR}/${name}.recorded"
  else
    printf 'absent\n' > "${BACKUP_DIR}/${name}.recorded"
  fi
}

restore_original() {
  local path=$1 name=$2
  local src="${BACKUP_DIR}/${name}"
  [[ -f "${BACKUP_DIR}/${name}.recorded" ]] || return 0
  if [[ $(<"${BACKUP_DIR}/${name}.recorded") == present && -e $src ]]; then
    # Copy over the existing path instead of unlinking it first.  Any extra
    # files that are not part of the backup are intentionally left in place.
    if [[ -d $src ]]; then
      mkdir -p "$path"
      cp -a "${src}/." "$path/"
    else
      cp -a "$src" "$path"
    fi
    info "Restored ${path} (existing files overwritten; nothing deleted)"
  elif [[ -e $path || -L $path ]]; then
    # The path did not exist before setup.  Move the generated file out of the
    # live location instead of leaving a stale DNS/PAM/sysctl/unit override
    # behind after --purge.  /tmp owns its expiry, so this is not a deletion.
    local moved
    moved=$(preserve_to_tmp "$path" 2>/dev/null || true)
    if [[ -n $moved ]]; then
      info "Moved generated ${path} to ${moved} (nothing deleted)"
    else
      warn "Could not move generated ${path}; leaving it in place"
    fi
  else
    info "Leaving ${path} in place (setup.sh never deletes server files)"
  fi
}

sql_escape() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\'/\'\'}
  printf '%s' "$v"
}

sed_escape_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

size_to_mb() {
  local s=$1 num unit
  num=${s%%[mMgGbB]*}
  unit=${s#"$num"}
  unit=${unit,,}
  case "$unit" in
    g|gb) printf '%s' "$(( num * 1024 ))" ;;
    m|mb|"") printf '%s' "$num" ;;
    *) return 1 ;;
  esac
}

# Render an integer number of MB as a MariaDB size (prefer G when exact).
mb_to_config() {
  local mb=$1
  if (( mb >= 1024 && mb % 1024 == 0 )); then
    printf '%sG' "$(( mb / 1024 ))"
  else
    printf '%sM' "$mb"
  fi
}

# Largest listen backlog the kernel will honour.  somaxconn is owned by
# configure_sysctl on install, but --optimize must respect whatever the live
# kernel already allows instead of asking for 65535 unconditionally.
effective_backlog() {
  local somaxconn
  somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || printf '4096')
  [[ $somaxconn =~ ^[0-9]+$ ]] || somaxconn=4096
  (( somaxconn > 65535 )) && somaxconn=65535
  (( somaxconn < 1024 )) && somaxconn=1024
  printf '%s' "$somaxconn"
}

# ---------------------------------------------------------------------------
# Server configuration repository
# ---------------------------------------------------------------------------
cleanup_configs() {
  # Downloaded configuration scratch data lives under /tmp.  It is deliberately
  # not removed: the operating system expires it, and setup.sh never deletes
  # files it did not just create in /tmp.
  :
}

# Download/extract server-configs-nginx once for the whole run.  Only the
# Angie installer consumes this tree; PHP-FPM templates are local configs/php.
fetch_server_configs() {
  if [[ -n ${CONFIG_SOURCE_DIR:-} && -d ${CONFIG_SOURCE_DIR} ]]; then
    info "Using server configs from ${CONFIG_SOURCE_DIR}"
    return 0
  fi
  if [[ -n ${CONFIG_TEMP_DIR:-} && -d ${CONFIG_TEMP_DIR} ]]; then
    return 0
  fi

  CONFIG_TEMP_DIR=$(tmp_dir)
  local archive="${CONFIG_TEMP_DIR}/configs.tar.gz"
  local url="${CONFIG_REPO_URL}/archive/${CONFIG_REPO_REF}.tar.gz"
  local src=""

  info "Downloading server configs: ${url}"
  if retry 3 5 curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$archive" 2>/dev/null; then
    tar -xzf "$archive" -C "$CONFIG_TEMP_DIR" \
      || die "Could not extract server configs from ${url}"
  elif command -v git >/dev/null 2>&1 \
       && retry 3 5 git clone --depth 1 --branch "$CONFIG_REPO_REF" \
            "${CONFIG_REPO_URL}.git" "${CONFIG_TEMP_DIR}/repo" 2>/dev/null; then
    src="${CONFIG_TEMP_DIR}/repo"
  else
    # Keep the failed download under /tmp for inspection; it expires on its own.
    CONFIG_TEMP_DIR=""
    die "Could not download server configs from ${CONFIG_REPO_URL} (${CONFIG_REPO_REF})"
  fi

  if [[ -z $src ]]; then
    src=$(find "$CONFIG_TEMP_DIR" -mindepth 1 -maxdepth 1 -type d \
      -name 'server-configs-nginx-*' 2>/dev/null | head -n1)
  fi
  [[ -n $src && -f "${src}/scripts/nginx_conf.sh" ]] \
    || die "Downloaded server configs are missing scripts/nginx_conf.sh"
  CONFIG_SOURCE_DIR=$src
  info "Server configs ready: ${CONFIG_SOURCE_DIR}"
}

# ---------------------------------------------------------------------------
# Cron management
# ---------------------------------------------------------------------------
pkg_ok() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

# Remember whether a package was already present before setup.sh installed it.
# The marker is inventory only: --purge never removes a package, so a
# pre-existing package and a setup-installed one are both left in place.
pkg_record_origin() {
  local pkg=$1
  ensure_state
  # Never rewrite an existing marker: a package installed by setup.sh on an
  # earlier run must not become "pre-existing" on a re-run.
  pkg_installed_by_setup "$pkg" && return 0
  pkg_preexisting "$pkg" && return 0
  if pkg_ok "$pkg"; then
    touch "${STATE_DIR}/preexisting-pkg-${pkg}"
  else
    touch "${STATE_DIR}/setup-installed-pkg-${pkg}"
  fi
}

pkg_preexisting() {
  [[ -f "${STATE_DIR}/preexisting-pkg-${1}" ]]
}

pkg_installed_by_setup() {
  [[ -f "${STATE_DIR}/setup-installed-pkg-${1}" ]]
}

# Drop the whole managed block, preserving all unmanaged lines.
cron_strip_managed() {
  awk -v b="$CRON_BEGIN" -v e="$CRON_END" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    !inblock { print }
  '
}

# Print only the lines inside the managed block.
cron_extract_managed() {
  awk -v b="$CRON_BEGIN" -v e="$CRON_END" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { print }
  '
}

# Keep non-empty managed blocks, drop empty begin/end pairs.
cron_compact_managed() {
  awk -v b="$CRON_BEGIN" -v e="$CRON_END" '
    $0 == b { inblock = 1; buf = ""; next }
    $0 == e {
      inblock = 0
      if (buf != "") printf "%s\n%s%s\n", b, buf, e
      next
    }
    inblock { buf = buf $0 "\n"; next }
    { print }
    END {
      if (inblock && buf != "") printf "%s\n%s%s\n", b, buf, e
    }
  '
}

# Drop bare ownership/maintenance jobs that no longer belong outside the
# managed block: the pre-1.8.34 blanket chown, an earlier log-safe find, and
# the old nginx/mysqlcheck paths.  write_cron() and purge_basic() both use
# this so a host cannot keep two competing jobs (one of them broken).
cron_strip_legacy_jobs() {
  awk '
    /chown[[:space:]]+www-data:www-data[[:space:]]+(-R|--recursive)[[:space:]]+\/var\/www([[:space:]]|\/|$)/ { next }
    /chown[[:space:]]+(-R|--recursive)[[:space:]]+www-data:www-data[[:space:]]+\/var\/www([[:space:]]|\/|$)/ { next }
    /\/usr\/bin\/find[[:space:]]+\/var\/www([[:space:]]|\/|$)/ && /chown/ { next }
    /\/etc\/nginx\/scripts\/cloudflare\.sh/ { next }
    /\/etc\/angie\/scripts\/cloudflare\.sh/ { next }
    /\/usr\/bin\/mysqlcheck/ { next }
    /\/usr\/bin\/mariadb-check/ { next }
    /\/usr\/local\/bin\/mysqlbkup\.sh/ { next }
    { print }
  '
}

cron_angie_configured() {
  pkg_ok angie && [[ -f /etc/angie/angie.conf ]]
}

cron_mariadb_configured() {
  pkg_ok mariadb-server && [[ -x /usr/local/bin/mysqlbkup.sh ]] \
    && { [[ -f /etc/mysqlbkup.cnf ]] || [[ -f /etc/mysqlbkup.config ]]; }
}

write_cron() {
  local cur tmp line group seen=" "
  local angie_cron=0 mariadb_cron=0
  local -a lines=() existing=() preserved=()

  # Regenerate entries for installed services even when this run only selected
  # --basic.  This is what restores the managed block after --purge basic (or
  # after an operator removed it) instead of leaving the host with no backups
  # and no log-ownership repair.  Require the installer's own files as well as
  # the package, so a provider-installed Angie/MariaDB without the managed
  # configuration does not get a cron job that cannot run.
  if [[ ${ENABLED[angie]:-0} -eq 1 ]] || cron_angie_configured; then
    angie_cron=1
    lines+=("0 0 * * * ${CRON_WWW_CHOWN} >/dev/null 2>&1")
    if [[ ${ENABLED[angie]:-0} -eq 1 ]] || [[ -x /etc/angie/scripts/cloudflare.sh ]]; then
      lines+=('1 1 * * * /usr/bin/chmod +x /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1')
      lines+=('2 1 * * * /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1')
    fi
  fi
  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]] || cron_mariadb_configured; then
    mariadb_cron=1
    lines+=("3 3 * * * /usr/local/bin/mysqlbkup.sh 1>> ${LOG_ROOT}/mariadb/backup.log 2>> ${LOG_ROOT}/mariadb/backup-err.log")
    lines+=('4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair > /dev/null 2>&1')
  fi

  cur=$(crontab -l 2>/dev/null || true)
  if [[ -n $cur ]]; then
    mapfile -t existing < <(printf '%s\n' "$cur" | cron_extract_managed)
  fi

  # A run that only touches --basic must not silently remove cron entries that
  # belong to services installed earlier.  Regenerate entries for selected
  # services, keep entries for other services that are still installed, and
  # drop stale entries for services that are no longer present.
  for line in "${existing[@]}"; do
    [[ -n $line ]] || continue
    if [[ $line == *mysqlbkup* || $line == *mariadb-check* ]]; then
      group=mariadb
    elif [[ $line == *'/etc/angie/'* || $line == *'/usr/bin/find /var/www'* || $line == *"${CRON_WWW_CHOWN_LEGACY}"* ]]; then
      group=angie
    else
      group=unknown
    fi
    case "$group" in
      angie)
        (( angie_cron )) && continue
        cron_angie_configured || continue
        ;;
      mariadb)
        (( mariadb_cron )) && continue
        cron_mariadb_configured || continue
        ;;
    esac
    # A preserved entry from an older release is rewritten in place so the
    # destructive blanket chown cannot survive a --basic run that does not
    # select --angie again.  The earlier log-safe find (which did not exclude
    # the backup directory or *.log files) is upgraded to the current form.
    if [[ $line == *"${CRON_WWW_CHOWN_LEGACY}"* ]]; then
      line="0 0 * * * ${CRON_WWW_CHOWN} >/dev/null 2>&1"
    elif [[ $line == *'/usr/bin/find /var/www'* ]] && [[ $line != *"${CRON_WWW_CHOWN}"* ]]; then
      line="0 0 * * * ${CRON_WWW_CHOWN} >/dev/null 2>&1"
    fi
    [[ $seen == *" ${line} "* ]] && continue
    seen+="${line} "
    preserved+=("$line")
  done

  lines=("${preserved[@]}" "${lines[@]}")
  tmp=$(tmp_file)
  {
    if [[ -n $cur ]]; then
      printf '%s\n' "$cur" | cron_strip_managed | cron_strip_legacy_jobs || true
    fi
    if (( ${#lines[@]} > 0 )); then
      printf '%s\n' "$CRON_BEGIN"
      printf '%s\n' "${lines[@]}"
      printf '%s\n' "$CRON_END"
    fi
  } > "$tmp"

  # Install the file even when it is empty instead of deleting the user's
  # crontab; writing an empty crontab keeps the file in place.
  if ! crontab "$tmp"; then
    warn "Could not install the managed crontab"
    return 1
  fi
  info "Managed crontab entries updated"
}

cron_remove_line() {
  local needle=$1 cur tmp
  cur=$(crontab -l 2>/dev/null || true)
  [[ -n $cur ]] || return 0
  tmp=$(tmp_file)
  printf '%s\n' "$cur" | grep -vF -- "$needle" | cron_compact_managed > "$tmp" || true
  if ! crontab "$tmp"; then
    warn "Could not update crontab after removing ${needle}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# BASIC
# ---------------------------------------------------------------------------
configure_dns() {
  step "DNS"
  # Track the drop-in itself, not the whole directory: other resolver drop-ins
  # may belong to the operator and must survive a purge.
  record_original /etc/systemd/resolved.conf.d/dns_servers.conf dns_servers.conf
  mkdir -p /etc/systemd/resolved.conf.d
  # Only manage our own drop-in; do not delete unrelated resolver configs.
  local dns_src="${SCRIPT_DIR}/configs/system/dns_servers.conf"
  if [[ -f $dns_src ]]; then
    install -m 644 "$dns_src" /etc/systemd/resolved.conf.d/dns_servers.conf
  else
    cat > /etc/systemd/resolved.conf.d/dns_servers.conf <<'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
EOF
  fi
  chmod 644 /etc/systemd/resolved.conf.d/dns_servers.conf
  retry 3 3 systemctl restart systemd-resolved || warn "systemd-resolved restart failed"
  resolvectl status || true
}

update_system() {
  step "Ubuntu update"
  apt_update
  # A failed upgrade can leave dpkg half-configured (for example when a
  # postinst is interrupted by a full disk or a provider console reset).
  # Repair the package state once and retry, instead of continuing a
  # provisioning run on top of a broken dpkg database.
  if ! apt-get upgrade "${APT_OPTS[@]}"; then
    warn "apt upgrade failed; repairing dpkg state and retrying once"
    dpkg --configure -a || warn "dpkg --configure -a reported an issue"
    apt-get -f install --no-remove "${APT_OPTS[@]}" || warn "apt-get -f install reported an issue"
    apt-get upgrade "${APT_OPTS[@]}" \
      || warn "apt upgrade still failing; continuing with a partially upgraded system"
  fi
}

# True when this CPU exposes frequency scaling and actually offers the
# performance governor.  Some VMs expose a cpufreq directory but only list
# powersave/schedutil; claiming "governor=performance" there is misleading.
cpu_performance_governor_available() {
  local dir=/sys/devices/system/cpu/cpu0/cpufreq
  [[ -d $dir ]] || return 1
  if [[ -r $dir/scaling_available_governors ]]; then
    grep -qw performance "$dir/scaling_available_governors" || return 1
  fi
  return 0
}

configure_cpu_governor() {
  step "CPU governor (dedicated server)"
  # Many dedicated hosts, and every VM, expose no cpufreq interface.  Treat
  # that as an informational skip instead of a failed service/warning.
  if ! cpu_performance_governor_available; then
    info "No performance CPU governor on this host; skipping governor setup"
    return 0
  fi
  # Removing a provider's tuned profile is a destructive change outside this
  # script's ownership.  Warn instead; the operator can disable it if the
  # governor does not stick.
  if pkg_ok tuned; then
    warn "tuned is installed and may override the performance governor; leaving it in place"
  fi
  ensure_state
  if ! dpkg-query -W -f='${Status}' cpufrequtils 2>/dev/null | grep -q 'ok installed'; then
    touch "${STATE_DIR}/cpufrequtils-installed"
  fi
  record_original /etc/default/cpufrequtils cpufrequtils-default
  apt_install cpufrequtils
  local cpu_src="${SCRIPT_DIR}/configs/system/cpufrequtils"
  if [[ -f $cpu_src ]]; then
    install -m 644 "$cpu_src" /etc/default/cpufrequtils
  else
    printf 'GOVERNOR="performance"\n' > /etc/default/cpufrequtils
  fi
  cat /etc/default/cpufrequtils

  systemctl daemon-reload || true
  systemctl enable cpufrequtils || warn "Could not enable cpufrequtils"
  systemctl restart cpufrequtils || warn "Could not start cpufrequtils"

  if command -v cpufreq-set >/dev/null 2>&1; then
    cpufreq-set -g performance || warn "cpufreq-set could not set the performance governor"
    cpufreq-info || true
  fi
}

configure_hostname() {
  local host=$1
  step "Hostname"
  ensure_state
  if [[ ! -f "${STATE_DIR}/original-hostname" ]]; then
    hostnamectl hostname > "${STATE_DIR}/original-hostname" 2>/dev/null || cat /etc/hostname > "${STATE_DIR}/original-hostname"
  fi
  record_original /etc/hosts hosts
  hostnamectl set-hostname "$host"
  # Keep the local 127.0.1.1 entry in sync; otherwise sudo and hostname -f
  # keep resolving the old name from /etc/hosts after the rename.
  sed_in_place -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
  printf '127.0.1.1\t%s\n' "$host" >> /etc/hosts
  hostnamectl status || true
}

install_basic_tools() {
  step "Basic tools"
  apt_install wget unzip nano zip software-properties-common rsync ca-certificates curl gnupg dmidecode git
}

configure_timezone() {
  local tz=$1
  step "Timezone"
  ensure_state
  if [[ ! -f "${STATE_DIR}/original-timezone" ]]; then
    timedatectl show -p Timezone --value > "${STATE_DIR}/original-timezone" 2>/dev/null || true
  fi
  timedatectl set-timezone "$tz"
  timedatectl status || true
}

swap_total_bytes() {
  awk 'NR>1 {sum += $3} END {printf "%d", sum * 1024}' /proc/swaps
}

ram_total_bytes() {
  awk '/^MemTotal:/{printf "%d", $2 * 1024}' /proc/meminfo
}

mark_swap_managed() {
  ensure_state
  touch "${STATE_DIR}/swapfile-managed"
}

ensure_swap_fstab() {
  if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile swap swap defaults 0 0\n' >> /etc/fstab
  fi
}

create_swap_file() {
  local bytes=$1
  # Reuse the path in place.  Unlinking a valid /swapfile is unnecessary and
  # would make a failed re-create leave the host with no swap at all.
  : > /swapfile
  if ! fallocate -l "$bytes" /swapfile 2>/dev/null; then
    warn "fallocate failed; falling back to dd"
    local count=$(( (bytes + 1048575) / 1048576 ))
    dd if=/dev/zero of=/swapfile bs=1M count="$count" status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  ensure_swap_fstab
  mark_swap_managed
}

configure_swap() {
  local size=$1
  local desired existing
  step "Swap (${size})"

  desired=$(numfmt --from=iec "${size^^}") \
    || die "Could not parse swap size '${size}'"

  if [[ -f /swapfile ]]; then
    existing=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    if [[ $existing -eq $desired ]] && swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      info "Swap file already present with the requested size"
      ensure_swap_fstab
      mark_swap_managed
      swapon --show
      return 0
    fi
    swapoff /swapfile 2>/dev/null || true
  fi

  create_swap_file "$desired"
  swapon --show
}

configure_swap_auto() {
  local ram current target needed old_size new_size
  step "Swap (auto: 50% of RAM)"

  ram=$(ram_total_bytes)
  current=$(swap_total_bytes)
  target=$(( ram / 2 ))
  info "RAM: $(numfmt --to=iec "$ram"); current swap: $(numfmt --to=iec "$current"); target swap: $(numfmt --to=iec "$target")"

  if (( current >= target )); then
    info "Current swap is already at least 50% of RAM; leaving it unchanged"
    return 0
  fi

  needed=$(( target - current ))
  if (( needed < 1048576 )); then
    info "Additional swap needed is below 1 MiB; skipping"
    return 0
  fi

  if [[ -f /swapfile ]]; then
    old_size=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      swapoff /swapfile 2>/dev/null || true
      # The old file was counted in "current", so add the difference to it.
      new_size=$(( old_size + needed ))
    else
      new_size=$needed
    fi
  else
    new_size=$needed
  fi

  info "Adding $(numfmt --to=iec "$new_size") to /swapfile to reach 50% of RAM"
  create_swap_file "$new_size"
  swapon --show
}

# Keys whose live kernel values are changed by setup.sh but may not exist in
# the original /etc/sysctl.conf.  Record them so --purge can put the kernel
# back without waiting for a reboot.
SYSCTL_MANAGED_KEYS=(
  net.core.somaxconn net.core.netdev_max_backlog net.core.optmem_max
  net.core.rmem_max net.core.wmem_max
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets
  net.ipv4.tcp_max_orphans net.ipv4.ip_local_port_range
  net.ipv4.tcp_keepalive_time
  net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2
  net.ipv4.neigh.default.gc_thresh3
  net.ipv4.ipfrag_low_thresh net.ipv4.ipfrag_high_thresh
  net.netfilter.nf_conntrack_max
  fs.file-max fs.nr_open fs.inotify.max_user_watches
  vm.min_free_kbytes kernel.shmmax kernel.shmall
)

record_sysctl_values() {
  ensure_state
  local key file
  for key in "${SYSCTL_MANAGED_KEYS[@]}"; do
    file="${STATE_DIR}/sysctl-orig-${key//\//_}"
    [[ -f $file ]] && continue
    sysctl -n "$key" > "$file" 2>/dev/null || true
  done
}

restore_sysctl_values() {
  local key file value
  for key in "${SYSCTL_MANAGED_KEYS[@]}"; do
    file="${STATE_DIR}/sysctl-orig-${key//\//_}"
    [[ -s $file ]] || continue
    value=$(<"$file")
    sysctl -w "${key}=${value}" >/dev/null 2>&1 \
      || warn "Could not restore ${key}=${value}"
  done
}

# Keep only the last definition of each sysctl key so an overlapping base
# profile and hardware block cannot silently contradict each other.
sysctl_dedupe_keys() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk '
    {
      lines[NR] = $0
      if (match($0, /^[[:space:]]*[A-Za-z0-9_.\/-]+[[:space:]]*=/)) {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]]*=.*/, "", key)
        last[key] = NR
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (match(line, /^[[:space:]]*[A-Za-z0-9_.\/-]+[[:space:]]*=/)) {
          key = line
          sub(/^[[:space:]]*/, "", key)
          sub(/[[:space:]]*=.*/, "", key)
          if (last[key] != i) continue
        }
        print line
      }
    }
  ' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
  fi
  return 0
}

configure_sysctl() {
  step "sysctl tweaks"
  record_sysctl_values
  record_original /etc/sysctl.conf sysctl.conf
  record_original /etc/sysctl.d/99-sysctl.conf sysctl.d-99-sysctl.conf

  local sysctl_src="${SCRIPT_DIR}/configs/system/sysctl.conf"
  if [[ -f $sysctl_src ]]; then
    install -m 644 "$sysctl_src" /etc/sysctl.conf
  else
    blob_sysctl > /etc/sysctl.conf
  fi

  # Layered, hardware-aware overrides on top of the base profile.  These
  # matter on busy web/database hosts: larger socket buffers, more orphan
  # sockets, a 1 GiB SysV shared-memory segment and a small security baseline.
  local cpu ram_mb min_free shmall
  local somaxconn syn_backlog netdev_backlog tw_buckets max_orphans
  local file_max inotify_watches conntrack_max ipfrag_high ipfrag_low
  local arp_thresh3 arp_thresh2
  cpu=$(nproc)
  (( cpu > 0 )) || cpu=1
  ram_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  (( ram_mb > 0 )) || ram_mb=1024
  min_free=$(( ram_mb * 1024 / 100 ))       # 1% of RAM, in kB
  (( min_free < 67584 ))  && min_free=67584
  (( min_free > 262144 )) && min_free=262144
  shmall=$(( 1073741824 / 4096 ))
  # Scale listener/connection limits with CPU count and RAM.  The clamps keep
  # a 1 GB VPS conservative and stop a 256-core host from reserving absurd
  # amounts of unswappable kernel memory.
  somaxconn=$(( cpu * 4096 ));          (( somaxconn < 4096 )) && somaxconn=4096;             (( somaxconn > 262144 )) && somaxconn=262144
  syn_backlog=$(( cpu * 4096 ));        (( syn_backlog < 1024 )) && syn_backlog=1024;          (( syn_backlog > 262144 )) && syn_backlog=262144
  netdev_backlog=$(( cpu * 2048 ));     (( netdev_backlog < 4096 )) && netdev_backlog=4096;    (( netdev_backlog > 65536 )) && netdev_backlog=65536
  tw_buckets=$(( ram_mb * 16 ));        (( tw_buckets < 65536 )) && tw_buckets=65536;          (( tw_buckets > 2621440 )) && tw_buckets=2621440
  max_orphans=$(( ram_mb * 2 ));        (( max_orphans < 16384 )) && max_orphans=16384;        (( max_orphans > 262144 )) && max_orphans=262144
  file_max=$(( ram_mb * 1024 ));        (( file_max < 1048576 )) && file_max=1048576;          (( file_max > 10485760 )) && file_max=10485760
  inotify_watches=$(( ram_mb * 4096 )); (( inotify_watches < 524288 )) && inotify_watches=524288; (( inotify_watches > 2097152 )) && inotify_watches=2097152
  conntrack_max=$(( ram_mb * 16 ));     (( conntrack_max < 65536 )) && conntrack_max=65536;    (( conntrack_max > 4194304 )) && conntrack_max=4194304
  ipfrag_high=$(( ram_mb * 32 ));       (( ipfrag_high < 262144 )) && ipfrag_high=262144;      (( ipfrag_high > 4194304 )) && ipfrag_high=4194304
  ipfrag_low=$(( ipfrag_high * 3 / 4 ))
  arp_thresh3=$(( cpu * 1024 ));        (( arp_thresh3 < 2048 )) && arp_thresh3=2048;          (( arp_thresh3 > 262144 )) && arp_thresh3=262144
  arp_thresh2=$(( arp_thresh3 / 2 ))
  cat >> /etc/sysctl.conf <<EOF

# BEGIN setup.sh tuning
# Larger socket buffers and connection headroom for high-request-rate sites.
net.core.optmem_max = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 8192 262144 33554432
net.ipv4.tcp_wmem = 8192 262144 33554432
net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${netdev_backlog}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_max_orphans = ${max_orphans}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 120
net.ipv4.neigh.default.gc_thresh1 = 32
net.ipv4.neigh.default.gc_thresh2 = ${arp_thresh2}
net.ipv4.neigh.default.gc_thresh3 = ${arp_thresh3}
# ipfrag_low_thresh must not exceed the current high threshold, so set the
# high water mark first and the low mark second.
net.ipv4.ipfrag_high_thresh = ${ipfrag_high}
net.ipv4.ipfrag_low_thresh = ${ipfrag_low}
net.netfilter.nf_conntrack_max = ${conntrack_max}
fs.file-max = ${file_max}
fs.nr_open = ${file_max}
fs.inotify.max_user_watches = ${inotify_watches}
vm.min_free_kbytes = ${min_free}
kernel.shmmax = 1073741824
kernel.shmall = ${shmall}

# Security hardening.
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# CVE-2019-11479: cap the TCP challenge-ACK rate.  The upstream profile left
# the legacy maximum (1073741823), which is the vulnerable setting.
net.ipv4.tcp_challenge_ack_limit = 1000
# END setup.sh tuning
EOF
  chmod 644 /etc/sysctl.conf

  # The base profile above and the hardware-aware block both define some of
  # the same keys (somaxconn, tcp_max_syn_backlog, file-max, ...).  Whichever
  # line comes last wins, so the file works, but it is ambiguous to audit and
  # one edit can silently undo the other.  Keep only the final definition of
  # each key; order and comments for distinct keys are preserved.
  sysctl_dedupe_keys /etc/sysctl.conf
  if [[ -d /etc/sysctl.d ]] && [[ ! -e /etc/sysctl.d/99-sysctl.conf && ! -L /etc/sysctl.d/99-sysctl.conf ]]; then
    ln -s ../sysctl.conf /etc/sysctl.d/99-sysctl.conf
  fi

  # Load the modules that own the sysctls below before systemd-sysctl runs at
  # boot; otherwise every boot logs "No such file or directory" for bbr/fq/
  # conntrack even though the values are applied later.
  mkdir -p /etc/modules-load.d
  record_original /etc/modules-load.d/setup-network.conf modules-load-setup-network.conf
  local -a net_mods=(nf_conntrack)
  [[ $QDISC == fq ]] && net_mods+=(sch_fq)
  [[ $TCP_CC == bbr ]] && net_mods+=(tcp_bbr)
  printf '%s\n' "${net_mods[@]}" > /etc/modules-load.d/setup-network.conf
  chmod 644 /etc/modules-load.d/setup-network.conf
  local mod
  for mod in "${net_mods[@]}"; do
    modprobe "$mod" || warn "Could not load ${mod} (kernel may not provide it)"
  done

  # Keep the selected qdisc even when systemd-sysctl runs again (a package
  # upgrade restarts it, and /usr/lib/sysctl.d/55-bufferbloat.conf would
  # otherwise put fq_codel back).  This drop-in has no dependency on a
  # congestion-control module, so it is safe to apply before modules-load.
  # The congestion control stays in the oneshot unit below, which runs after
  # the modules are available.
  record_original /etc/sysctl.d/90-setup-network.conf sysctl.d-90-setup-network.conf
  cat > /etc/sysctl.d/90-setup-network.conf <<EOF
# Managed by setup.sh: keep the ${QDISC} qdisc after systemd-sysctl re-runs.
# tcp_congestion_control=${TCP_CC} is applied by setup-network-tuning.service
# once the required modules are loaded.
net.core.default_qdisc = ${QDISC}
EOF
  chmod 644 /etc/sysctl.d/90-setup-network.conf
  sysctl -w "net.core.default_qdisc=${QDISC}" >/dev/null 2>&1 \
    || warn "Could not set net.core.default_qdisc=${QDISC}"

  sysctl -e -p /etc/sysctl.conf || warn "One or more sysctl values could not be applied"

  # The congestion-control module and qdisc are module-owned and
  # systemd-sysctl runs before modules-load on Ubuntu, which logs "No such
  # file or directory" on every boot. Apply them from a small oneshot unit
  # after the modules are available instead.
  record_original /etc/systemd/system/setup-network-tuning.service setup-network-tuning.service
  {
    cat <<'EOF'
[Unit]
Description=Apply network qdisc/congestion-control tuning after kernel modules load
After=systemd-modules-load.service
[Service]
Type=oneshot
EOF
    for mod in "${net_mods[@]}"; do
      printf 'ExecStart=/sbin/modprobe %s\n' "$mod"
    done
    printf 'ExecStart=/sbin/sysctl -w net.core.default_qdisc=%s net.ipv4.tcp_congestion_control=%s\n' \
      "$QDISC" "$TCP_CC"
    cat <<'EOF'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  } > /etc/systemd/system/setup-network-tuning.service
  chmod 644 /etc/systemd/system/setup-network-tuning.service
  systemctl daemon-reload || true
  systemctl enable setup-network-tuning.service >/dev/null 2>&1 || true
  # restart (not start): the oneshot stays "active" from a previous run, and a
  # start would not re-apply a changed qdisc/congestion-control value.
  systemctl restart setup-network-tuning.service \
    || warn "Could not apply ${TCP_CC}/${QDISC} tuning"
}

configure_limits() {
  step "Security limits"
  local limits_src="${SCRIPT_DIR}/configs/system/limits.conf"
  local dropin=/etc/security/limits.d/99-setup.conf
  mkdir -p /etc/security/limits.d
  # Record the original files so --purge can put the machine back.
  record_original /etc/security/limits.conf limits.conf
  record_original "$dropin" limits.d-99-setup.conf
  if [[ -f $limits_src ]]; then
    install -m 644 "$limits_src" "$dropin"
  else
    cat > "$dropin" <<'EOF'
elasticsearch soft nofile 1048576
elasticsearch hard nofile 1048576
mysql         soft nofile 1048576
mysql         hard nofile 1048576
valkey        soft nofile 1048576
valkey        hard nofile 1048576
root          soft nofile 1048576
root          hard nofile 1048576
tinyproxy     soft nofile 1048576
tinyproxy     hard nofile 1048576
www-data      soft nofile 1048576
www-data      hard nofile 1048576
angie         soft nofile 1048576
angie         hard nofile 1048576
*             soft nofile 1048576
*             hard nofile 1048576
EOF
  fi
  chmod 644 "$dropin"
  # Older setup.sh releases replaced /etc/security/limits.conf wholesale.
  # Put the distribution file back when we can prove it is our old copy.
  if [[ -f "${BACKUP_DIR}/limits.conf.recorded" ]] \
     && [[ $(<"${BACKUP_DIR}/limits.conf.recorded") == present ]] \
     && [[ -f "${BACKUP_DIR}/limits.conf" ]] \
     && cmp -s /etc/security/limits.conf "$limits_src"; then
    cp -a "${BACKUP_DIR}/limits.conf" /etc/security/limits.conf
    info "Restored original /etc/security/limits.conf; limits now use the drop-in"
  fi
  cat "$dropin"
}

configure_ufw() {
  step "UFW firewall"
  ensure_state
  if [[ ! -f "${STATE_DIR}/ufw-active-before" ]]; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
      printf 'active\n' > "${STATE_DIR}/ufw-active-before"
    else
      printf 'inactive\n' > "${STATE_DIR}/ufw-active-before"
    fi
  fi
  if [[ ! -f "${STATE_DIR}/ufw-added-before" ]]; then
    ufw show added 2>/dev/null | sort -u > "${STATE_DIR}/ufw-added-before" || true
  fi
  if [[ ! -f "${STATE_DIR}/ufw-defaults-before" ]]; then
    ufw status verbose 2>/dev/null | awk '/^Default:/{print}' \
      > "${STATE_DIR}/ufw-defaults-before" || true
  fi

  ufw --force default deny incoming
  ufw --force default allow outgoing
  # SSH must be rate-limited, not wide open.  A plain `allow` rule lets an
  # unauthenticated client open as many connections as it likes; `ufw limit`
  # blocks an address that opens more than six connections in 30 seconds.
  # Insert the LIMIT at the top so an older plain ALLOW rule (written by this
  # script before 1.8.35 or by a provider image) cannot take precedence, then
  # remove that ALLOW rule.  Allow every effective sshd port, not just 22: a
  # host moved to a custom port would otherwise lose remote access the moment
  # UFW is enabled.
  local ssh_port ssh_limited had_allow
  while IFS= read -r ssh_port; do
    [[ $ssh_port =~ ^[0-9]+$ ]] || continue
    ssh_limited=0
    had_allow=0
    if ufw show added 2>/dev/null | grep -qE "^ufw allow ${ssh_port}/tcp($| )|^ufw allow ${ssh_port}($| )"; then
      had_allow=1
    fi

    if ufw show added 2>/dev/null | grep -qE "^ufw limit ${ssh_port}/tcp($| )|^ufw limit ${ssh_port}($| )"; then
      ssh_limited=1
    else
      # ufw treats allow and limit for the same port as the same rule: it
      # refuses to insert a limit while a plain allow exists, and a later
      # `delete allow` would remove the limit too.  Remove the plain allow
      # first, then insert the limit; if that fails, restore the allow so a
      # remote operator cannot be locked out.
      if (( had_allow )); then
        if ufw show added 2>/dev/null | grep -qxF "ufw allow ${ssh_port}/tcp"; then
          ufw delete allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
        fi
        if ufw show added 2>/dev/null | grep -qxF "ufw allow ${ssh_port}"; then
          ufw delete allow "${ssh_port}" >/dev/null 2>&1 || true
        fi
      fi
      if ufw insert 1 limit "${ssh_port}/tcp" 2>/dev/null \
         || ufw limit "${ssh_port}/tcp" 2>/dev/null; then
        ssh_limited=1
        info "UFW: rate-limited SSH port ${ssh_port}/tcp (ufw limit)"
      fi
    fi

    if (( ! ssh_limited )); then
      # Never leave the host without an SSH rule.
      warn "Could not rate-limit SSH port ${ssh_port}/tcp; restoring a plain ALLOW rule to avoid lockout"
      ufw status 2>/dev/null | grep -qE "^${ssh_port}(/tcp)?( \(v6\))?[[:space:]]+ALLOW" \
        || ufw insert 1 allow "${ssh_port}/tcp" 2>/dev/null \
        || ufw allow "${ssh_port}/tcp" 2>/dev/null || true
    fi
  done < <(sshd_listen_ports)
  ufw allow 80 || true
  ufw allow 443 || true
  ufw --force enable
  ufw status verbose || true

  ufw show added 2>/dev/null | sort -u > "${STATE_DIR}/ufw-added-after" || true
  comm -13 "${STATE_DIR}/ufw-added-before" "${STATE_DIR}/ufw-added-after" \
    > "${STATE_DIR}/ufw-added" 2>/dev/null || true
}

install_basic() {
  local server=${OPT[basic.server]:-}
  local host=${OPT[basic.host]:-}
  local tz=${OPT[basic.time]:-Asia/Manila}
  local swap=${OPT[basic.swap]:-}

  if [[ -z $server ]]; then
    server=$(detect_server_type)
    OPT[basic.server]=$server
    info "Auto-detected server type: ${server}"
  fi

  configure_dns
  update_system

  # Let the tuner decide from the actual cpufreq interface.  --optimize calls
  # the same function, so a host with a usable performance governor gets it
  # from either command.
  configure_cpu_governor

  # dmidecode (installed here) gives the nominal installed RAM for the
  # generated hostname, even when the kernel reserves some of it.
  install_basic_tools

  if [[ -z $host ]]; then
    host=$(generate_hostname)
    [[ -n $host ]] || die "Could not auto-generate a hostname"
    validate_hostname "$host" || die "Generated hostname '${host}' is invalid"
    OPT[basic.host]=$host
    info "Auto-generated hostname: ${host}"
  fi

  configure_hostname "$host"
  configure_timezone "$tz"

  if [[ -n $swap ]]; then
    configure_swap "$swap"
  else
    configure_swap_auto
  fi

  configure_sysctl
  configure_limits
  ensure_log_dirs
  configure_logrotate

  apt_install cron
  systemctl enable --now cron || warn "Could not enable/start cron"
  systemctl status cron --no-pager || true
  write_cron

  apt_install ufw
  configure_ufw

  apt_clean
  ok "Basic server setup complete"
}

# ---------------------------------------------------------------------------
# ANGIE
# ---------------------------------------------------------------------------
# =============================================================================
# HARDWARE-AWARE LIVE TUNING
# -----------------------------------------------------------------------------
# These helpers are used both by the installers and by `--optimize`.  They
# only rewrite live configuration; they never install packages.
# =============================================================================
TUNE_CHANGES=()
TUNE_MISSES=()
TUNE_DIRTY=0
# Only repoint Angie's FastCGI upstream when the optimized PHP pool already
# owns a Unix socket.  --optimize preserves an existing TCP listener so a live
# site is never pointed at a socket that does not exist.
OPT_PHP_OK=0
OPT_PHP_SOCKET=""
tune_reset_changes() { TUNE_CHANGES=(); TUNE_MISSES=(); TUNE_DIRTY=0; }
tune_note() { TUNE_CHANGES+=("$*"); TUNE_DIRTY=1; }
# Informational line that must not count as a configuration change (and must
# not trigger a service restart on an otherwise unchanged run).
tune_summary() { TUNE_CHANGES+=("$*"); }
# A directive that was expected in an existing file but could not be found.
# Recorded instead of silently doing nothing, so config drift is visible in
# the report without forcing a restart.
tune_miss() { TUNE_MISSES+=("$*"); }

tune_clamp() {
  local value=$1 min=$2 max=$3
  (( value < min )) && value=$min
  (( value > max )) && value=$max
  printf '%s' "$value"
}

# Tuner-facing name for mb_to_config(); one implementation keeps the installer
# and --optimize reporting identical.
tune_size_value() { mb_to_config "$1"; }

# Cache budget in MB: 25% of RAM, capped at 5% of free disk, then rounded
# down to 256 MB.  The rounding keeps small free-space changes between runs
# (backups, logs) from resizing every cache zone and forcing a restart.
tune_cache_total_mb() {
  local ram_mb=$1 disk_free_mb=$2 ram_pct=${3:-25} disk_pct=${4:-5} total
  total=$(( ram_mb * ram_pct / 100 ))
  (( total > 65536 )) && total=65536
  (( total > disk_free_mb * disk_pct / 100 )) && total=$(( disk_free_mb * disk_pct / 100 ))
  (( total < 256 )) && total=256
  total=$(( total / 256 * 256 ))
  (( total < 256 )) && total=256
  printf '%s' "$total"
}

# Angie cache budget for the current service set.  A dedicated Angie proxy
# gets 50% of RAM (10% of free disk); Angie+PHP gets 30%; a host with a data
# or search tier gets 25% (5% of free disk).  Callers pass the live RAM and
# free disk so --dry-run and the real tuner report the same number.
angie_cache_budget_mb() {
  local ram_mb=$1 disk_free_mb=$2 pct=25 disk_pct=5 svc
  local has_php=0 has_maria=0 has_cache=0 has_es=0
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    for svc in "${OPT_DETECTED[@]}"; do
      case $svc in
        php:*) has_php=1 ;;
        mariadb) has_maria=1 ;;
        valkey|redis) has_cache=1 ;;
        elastic) has_es=1 ;;
      esac
    done
    if (( !has_php && !has_maria && !has_cache && !has_es )); then
      pct=50
      disk_pct=10
    elif (( has_php && !has_maria && !has_cache && !has_es )); then
      pct=30
    fi
  fi
  tune_cache_total_mb "$ram_mb" "$disk_free_mb" "$pct" "$disk_pct"
}

# Pick the first existing file from a list.  Older server-configs-nginx
# releases installed http.d files with underscore names (fastcgi_cache_conf);
# current releases use dots (fastcgi_cache.conf).  --optimize must tune a live
# server regardless of which layout it was installed with.
tune_first_file() {
  local dir=$1 name
  shift
  for name in "$@"; do
    [[ -f "${dir}/${name}" ]] && { printf '%s' "${dir}/${name}"; return 0; }
  done
  return 1
}

# Files under http.d that Angie actually includes.  Hosts upgraded from older
# layouts often keep inert *_conf leftovers next to the active *.conf files;
# tuning those leftovers changes nothing and hides the real cache/limit files.
TUNE_ACTIVE_HTTP=()
angie_active_http_files() {
  local target=$1 conf="${1}/angie.conf" pattern path
  [[ -f $conf ]] || return 0
  while IFS= read -r pattern; do
    pattern=${pattern#*include}
    pattern=${pattern%%;*}
    pattern=$(printf '%s' "$pattern" | tr -d '"' | awk '{print $1}')
    [[ -n $pattern ]] || continue
    [[ $pattern == /* ]] || pattern="${target}/${pattern}"
    while IFS= read -r path; do
      [[ -n $path && -f $path ]] || continue
      case "$path" in
        "${target}/http.d/"*) printf '%s\n' "$path" ;;
      esac
    done < <(compgen -G "$pattern" 2>/dev/null | sort || true)
  done < <(grep -hE '^[[:space:]]*include[[:space:]]+' "$conf" 2>/dev/null || true)
}

tune_active_file() {
  local pattern=$1 file
  for file in "${TUNE_ACTIVE_HTTP[@]}"; do
    [[ -f $file ]] || continue
    grep -qE "$pattern" "$file" && { printf '%s' "$file"; return 0; }
  done
  return 1
}

# Cache or limiter files under http.d that angie.conf never includes.  Older
# deployments kept the *_conf names after the repository renamed them to
# *.conf; those files look active but silently change nothing, which is why
# --optimize reports "no active fastcgi_cache_path" on such a host.
angie_inert_cache_files() {
  local target=$1 file active is_active
  local -a active_files=()
  mapfile -t active_files < <(angie_active_http_files "$target")
  for file in "$target"/http.d/*; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*(fastcgi_cache_path|proxy_cache_path|limit_req_zone)[[:space:]]' "$file" || continue
    is_active=0
    for active in "${active_files[@]}"; do
      [[ $file == "$active" ]] && { is_active=1; break; }
    done
    (( is_active )) || printf '%s\n' "$file"
  done
  return 0
}

# Directories backing the cache paths Angie actually includes.  Used after a
# service restart to drop objects written while a backend was unavailable.
angie_cache_dirs() {
  local target=${1:-/etc/angie} file
  local -a files=()
  mapfile -t files < <(angie_active_http_files "$target")
  files+=("${target}/angie.conf")
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    awk '
      {
        for (i = 1; i < NF; i++) {
          if ($i ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/) {
            print $(i + 1)
            break
          }
        }
      }
    ' "$file"
  done | tr -d ';' | grep -E '^/' | sort -u
  return 0
}

# Disk-cache max_size is planned from RAM, but a live cache can already hold
# more than that plan (and may be configured larger by the operator).  Writing
# a smaller value makes Angie's cache manager evict hot objects immediately,
# and chasing usage every run would ratchet the value upward forever.  Rule:
# never shrink below the existing max_size or the live usage (+5% headroom).
# Sets ANGIE_CACHE_MB (size to write) and ANGIE_CACHE_NOTE (report line, if
# the planned value was raised).  A global result is used instead of command
# substitution so the note reaches the caller's TUNE_CHANGES array.
angie_cache_keep_mb() {
  local file=$1 planned=$2 dir usage existing=0 candidate val
  ANGIE_CACHE_MB=$planned
  ANGIE_CACHE_NOTE=""
  [[ -f $file ]] || return 0
  dir=$(awk '
    $1 ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/ { print $2; exit }
  ' "$file" | tr -d ';')
  # Existing max_size in MB (k/m/g suffix); 0 when the directive has none.
  val=$(grep -m1 -oE 'max_size=[0-9]+[kKmMgG]' "$file" 2>/dev/null || true)
  val=${val#max_size=}
  if [[ $val =~ ^([0-9]+)([kKmMgG])$ ]]; then
    case ${BASH_REMATCH[2]} in
      k|K) existing=$(( BASH_REMATCH[1] / 1024 )) ;;
      m|M) existing=${BASH_REMATCH[1]} ;;
      g|G) existing=$(( BASH_REMATCH[1] * 1024 )) ;;
    esac
  fi
  candidate=$planned
  usage=$(du -sm -- "$dir" 2>/dev/null | awk '{print $1}' || true)
  [[ $usage =~ ^[0-9]+$ ]] || usage=0
  if (( usage > planned )); then
    if (( existing > 0 && existing >= usage )); then
      # The configured cache already covers its live objects: keep it rather
      # than writing a value that would evict them.
      candidate=$existing
    else
      candidate=$(( usage * 105 / 100 ))
    fi
  fi
  (( candidate > planned )) || return 0
  candidate=$(( (candidate + 255) / 256 * 256 ))
  ANGIE_CACHE_MB=$candidate
  ANGIE_CACHE_NOTE="kept cache max_size=${candidate}M for ${dir:-cache} (live ${usage}MB; RAM plan was ${planned}M)"
  return 0
}

# A backend that restarts during --optimize can send a truncated/empty 200
# while connections are cut over, and the guest cache stores 200 responses
# for minutes: every visitor then receives a blank page.  Older releases
# deleted objects written during the run.  setup.sh now only reports them: a
# cache file is still a file, and deleting the wrong entry is not recoverable.
count_optimize_cache_entries() {
  local epoch=${1:-0} target=${2:-/etc/angie} dir count total=0
  [[ $epoch =~ ^[0-9]+$ ]] && (( epoch > 0 )) || { printf '0'; return 0; }
  while IFS= read -r dir; do
    [[ -n $dir && $dir == /* && $dir != / && -d $dir ]] || continue
    count=$(find "$dir" -type f -newermt "@$epoch" 2>/dev/null | wc -l)
    total=$(( total + count ))
  done < <(angie_cache_dirs "$target")
  printf '%s' "$total"
}

tune_replace() {
  local file=$1 pattern=$2 replacement=$3 desc=$4 tmp
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$pattern" "$file"; then
    tune_miss "no match for ${desc}"
    return 0
  fi
  tmp=$(tmp_file) || return 1
  # Use a delimiter that does not collide with regex alternation (`|`) or
  # common path characters in these directives.
  sed -E "s#${pattern}#${replacement}#" "$file" > "$tmp" || return 1
  if cmp -s "$file" "$tmp"; then
    return 0
  fi
  cat -- "$tmp" > "$file"
  tune_note "$desc"
  return 0
}

tune_insert_after() {
  local file=$1 anchor=$2 line=$3 desc=$4
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$anchor" "$file"; then
    tune_miss "no insertion anchor for ${desc}"
    return 0
  fi
  local tmp
  tmp=$(tmp_file)
  awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !done { print; print line; done=1; next }
    { print }
  ' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
    tune_note "$desc"
  fi
}

# A cached 500 (or a stale 500 served by fastcgi_cache_use_stale) hides a
# recovered application and makes the error look permanent.  Older installs
# carry the original policy; --optimize upgrades them in place so an existing
# server gets the fix without a full reinstall.
tune_cache_error_policy() {
  local file=$1 label=$2 before after tmp
  [[ -f $file ]] || return 0
  before=$(md5sum "$file" | awk '{print $1}')
  sed_in_place -E '/^[[:space:]]*fastcgi_cache_use_stale/ s/[[:space:]]+http_500([[:space:]]|;)/\1/g' "$file"
  if ! grep -qE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;' "$file"; then
    tmp=$(tmp_file)
    if grep -qE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+any[[:space:]]' "$file"; then
      awk '
        /^[[:space:]]*fastcgi_cache_valid[[:space:]]+any[[:space:]]/ && !done {
          print
          print "fastcgi_cache_valid 500 502 503 504 0s;"
          done = 1
          next
        }
        { print }
      ' "$file" > "$tmp"
    else
      cat "$file" > "$tmp"
      printf '\nfastcgi_cache_valid 500 502 503 504 0s;\n' >> "$tmp"
    fi
    cat "$tmp" > "$file"
  fi
  after=$(md5sum "$file" | awk '{print $1}')
  [[ $before != "$after" ]] \
    && tune_note "${label}: never cache error responses; stale 500 disabled"
  return 0
}

# The shared FastCGI snippet historically captured PATH_INFO with
# ^(.+?\.php)(/.*)$; that requires a trailing "/..." and can leave
# $fastcgi_script_name empty for a bare /index.php.  try_files then sees the
# document root, passes it to PHP-FPM, and security.limit_extensions returns
# "Access denied" for every pretty URL.  Make PATH_INFO optional; the
# try_files test and SCRIPT_FILENAME stay unchanged so PATH_INFO apps keep
# working.
tune_fastcgi_snippet() {
  local file=$1 tmp
  [[ -f $file ]] || { tune_miss "FastCGI snippet missing: ${file}"; return 0; }
  grep -qE '^[[:space:]]*fastcgi_split_path_info[[:space:]]+' "$file" || {
    tune_miss "FastCGI snippet has no fastcgi_split_path_info: ${file}"
    return 0
  }
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_split_path_info[[:space:]]+/ {
      print lead($0) "fastcgi_split_path_info ^(.+?\\.php)(/.*)?$;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
    tune_note "snippets/fastcgi-php.conf: PATH_INFO capture is optional"
  fi
  return 0
}

# PHP-FPM uses PATH_TRANSLATED instead of SCRIPT_FILENAME when
# cgi.fix_pathinfo=0. The shared WordPress/Polr includes used to set it to
# $document_root$fastcgi_path_info, which is the document root for a normal
# /index.php request. Point it at the script so enabling fix_pathinfo later
# cannot turn the document root into an attempted PHP script.
tune_fastcgi_path_translated() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  grep -qE '^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;' "$file" || return 0
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;/ {
      print lead($0) "fastcgi_param PATH_TRANSLATED $document_root$fastcgi_script_name;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
    tune_note "${file##*/}: PATH_TRANSLATED uses the PHP script"
  fi
  return 0
}

# A bare `location / { try_files ... }` with no index directive resolves "/"
# to the directory instead of index.php on older vhosts.  Add a server-level
# index to the shared WordPress and Polr includes when they lack one.
tune_ensure_index() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  if grep -qE '^[[:space:]]*index[[:space:]]' "$file"; then
    return 0
  fi
  tmp=$(tmp_file) || return 1
  {
    printf 'index index.php index.html;\n'
    cat "$file"
  } > "$tmp"
  cat "$tmp" > "$file"
  tune_note "${file##*/}: index index.php index.html"
  return 0
}

# ---------------------------------------------------------------------------
# Angie
# ---------------------------------------------------------------------------
tune_angie_configs() {
  local target=${1:-/etc/angie}
  local nginx_conf="${target}/angie.conf"
  [[ -f $nginx_conf ]] || return 1

  # Repair the shared PHP include and the two server-level includes that old
  # deployments left without an index.  Also normalise PATH_TRANSLATED so
  # cgi.fix_pathinfo=0 cannot make PHP-FPM execute the document root.
  tune_fastcgi_snippet "${target}/snippets/fastcgi-php.conf"
  tune_ensure_index "${target}/h5bp/wordpress.conf"
  tune_ensure_index "${target}/h5bp/php_polr.conf"
  tune_fastcgi_path_translated "${target}/h5bp/php_wp.conf"
  tune_fastcgi_path_translated "${target}/h5bp/php_polr.conf"
  tune_fastcgi_path_translated "${target}/h5bp/php.conf"

  local nproc mem_mb disk_free_mb disk_class
  local worker_rlimit worker_connections php_keepalive open_files
  local fastcgi_buffers fastcgi_busy body_buffer ssl_cache_mb
  local cache_total_mb fcgi_mb chev_mb xf_mb proxy_mb cdn_mb
  local fcgi_zone chev_zone xf_zone proxy_zone cdn_zone
  local fcgi_size chev_size xf_size proxy_size cdn_size
  local limit_post limit_get

  nproc=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  (( nproc > 0 )) || nproc=1
  mem_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
  (( mem_mb > 0 )) || mem_mb=1024

  disk_class=$(storage_class)

  disk_free_mb=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $disk_free_mb =~ ^[0-9]+$ ]] || disk_free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $disk_free_mb =~ ^[0-9]+$ ]] || disk_free_mb=10240

  worker_rlimit=$(tune_clamp $(( nproc * 8192 )) 65536 524288)
  worker_connections=$(tune_clamp $(( nproc * 2048 )) 8192 65535)
  (( worker_connections > worker_rlimit - 1024 )) && worker_connections=$(( worker_rlimit - 1024 ))
  (( worker_connections < 1024 )) && worker_connections=1024
  php_keepalive=$(tune_clamp $(( nproc * 2 )) 16 128)
  open_files=$(tune_clamp $(( nproc * 2048 )) 10000 200000)

  if (( mem_mb < 2048 )); then
    fastcgi_buffers='32 16k'; fastcgi_busy='256k'; body_buffer='64k'
  elif (( mem_mb < 8192 )); then
    fastcgi_buffers='64 32k'; fastcgi_busy='1m'; body_buffer='128k'
  else
    fastcgi_buffers='128 32k'; fastcgi_busy='2m'; body_buffer='256k'
  fi

  ssl_cache_mb=$(tune_clamp $(( mem_mb / 512 )) 10 256)

  # Scale the disk-cache budget with the services actually present.  A
  # dedicated Angie proxy has no PHP/DB/search tier to share RAM with, and an
  # Angie+PHP host has no database/search tier.  The helper is shared with
  # --dry-run so the plan and the applied value match.
  cache_total_mb=$(angie_cache_budget_mb "$mem_mb" "$disk_free_mb")

  # Resolve the cache files Angie actually includes before sizing them, so a
  # host that only runs one cache type can use the whole cache budget instead
  # of leaving most of it assigned to caches that do not exist.
  local f_fcgi f_chev f_xf f_proxy f_limit
  TUNE_ACTIVE_HTTP=()
  mapfile -t TUNE_ACTIVE_HTTP < <(angie_active_http_files "$target")
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    f_fcgi=$(tune_active_file 'keys_zone=fastcgicache:') || f_fcgi=""
    f_chev=$(tune_active_file 'keys_zone=fastcgicache_chev:') || f_chev=""
    f_xf=$(tune_active_file 'keys_zone=xfproxycache:') || f_xf=""
    f_proxy=$(tune_active_file 'keys_zone=(proxy_cache|proxy_cdn|cdn_proxy):') || f_proxy=""
    f_limit=$(tune_active_file 'limit_req_zone') || f_limit=""
  else
    f_fcgi=$(tune_first_file "$target/http.d" fastcgi_cache.conf fastcgi_cache_conf) || f_fcgi=""
    f_chev=$(tune_first_file "$target/http.d" fastcgi_cache_chev.conf fastcgi_cache_chev_conf) || f_chev=""
    f_xf=$(tune_first_file "$target/http.d" xf_proxy_cache.conf xf_proxy_cache_conf) || f_xf=""
    f_proxy=$(tune_first_file "$target/http.d" proxy_cache.conf proxy_cache_conf) || f_proxy=""
    f_limit=$(tune_first_file "$target/http.d" limit_req.conf limit_req_conf) || f_limit=""
  fi

  local have_fcgi=0 have_chev=0 have_xf=0 have_proxy=0 have_cdn=0 active_weight=0
  [[ -n $f_fcgi ]] && have_fcgi=1
  [[ -n $f_chev ]] && have_chev=1
  [[ -n $f_xf ]] && have_xf=1
  if [[ -n $f_proxy ]]; then
    grep -qE 'keys_zone=proxy_cache:' "$f_proxy" && have_proxy=1
    grep -qE 'keys_zone=(proxy_cdn|cdn_proxy):' "$f_proxy" && have_cdn=1
  fi
  (( have_fcgi )) && active_weight=$(( active_weight + 50 ))
  (( have_chev )) && active_weight=$(( active_weight + 25 ))
  (( have_xf )) && active_weight=$(( active_weight + 15 ))
  (( have_proxy )) && active_weight=$(( active_weight + 5 ))
  (( have_cdn )) && active_weight=$(( active_weight + 5 ))

  fcgi_mb=0; chev_mb=0; xf_mb=0; proxy_mb=0; cdn_mb=0
  if (( active_weight > 0 )); then
    (( have_fcgi )) && fcgi_mb=$(( cache_total_mb * 50 / active_weight ))
    (( have_chev )) && chev_mb=$(( cache_total_mb * 25 / active_weight ))
    (( have_xf )) && xf_mb=$(( cache_total_mb * 15 / active_weight ))
    (( have_proxy )) && proxy_mb=$(( cache_total_mb * 5 / active_weight ))
    (( have_cdn )) && cdn_mb=$(( cache_total_mb * 5 / active_weight ))
    # A proxy file containing only one of the standard paths must not rewrite
    # the other path to max_size=0.
    (( have_proxy && !have_cdn )) && cdn_mb=$proxy_mb
    (( have_cdn && !have_proxy )) && proxy_mb=$cdn_mb
  fi
  (( have_fcgi && fcgi_mb < 64 )) && fcgi_mb=64
  (( have_chev && chev_mb < 32 )) && chev_mb=32
  (( have_xf && xf_mb < 32 )) && xf_mb=32
  (( have_proxy && proxy_mb < 16 )) && proxy_mb=16
  (( have_cdn && cdn_mb < 16 )) && cdn_mb=16

  # Do not force the cache manager to evict a cache that is already larger
  # than the RAM-derived plan (live usage wins on an existing server).
  if [[ -n $f_fcgi ]]; then
    angie_cache_keep_mb "$f_fcgi" "$fcgi_mb"
    fcgi_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_fcgi#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  if [[ -n $f_chev ]]; then
    angie_cache_keep_mb "$f_chev" "$chev_mb"
    chev_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_chev#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi
  if [[ -n $f_xf ]]; then
    angie_cache_keep_mb "$f_xf" "$xf_mb"
    xf_mb=$ANGIE_CACHE_MB
    [[ -n $ANGIE_CACHE_NOTE ]] && tune_summary "${f_xf#"${target}"/}: ${ANGIE_CACHE_NOTE}"
  fi

  fcgi_zone=$(tune_clamp $(( cache_total_mb / 4 )) 16 512)
  chev_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 512)
  xf_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 256)
  proxy_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  cdn_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)

  fcgi_size=$(tune_size_value "$fcgi_mb")
  chev_size=$(tune_size_value "$chev_mb")
  xf_size=$(tune_size_value "$xf_mb")
  proxy_size=$(tune_size_value "$proxy_mb")
  cdn_size=$(tune_size_value "$cdn_mb")

  tune_replace "$nginx_conf" '^([[:space:]]*worker_rlimit_nofile[[:space:]]+)[0-9]+;' "\\1${worker_rlimit};" "angie.conf: worker_rlimit_nofile=${worker_rlimit}"
  tune_replace "$nginx_conf" '^([[:space:]]*worker_connections[[:space:]]+)[0-9]+;' "\\1${worker_connections};" "angie.conf: worker_connections=${worker_connections}"
  tune_replace "$nginx_conf" '^([[:space:]]*client_body_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "angie.conf: client_body_buffer_size=${body_buffer}"
  tune_replace "$nginx_conf" '^([[:space:]]*keepalive[[:space:]]+)[0-9]+;' "\\1${php_keepalive};" "angie.conf: PHP upstream keepalive=${php_keepalive}"

  if ! grep -qE '^[[:space:]]*worker_rlimit_nofile[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*worker_processes[[:space:]]' \
      "worker_rlimit_nofile ${worker_rlimit};" "angie.conf: inserted worker_rlimit_nofile=${worker_rlimit}"
  fi
  if ! grep -qE '^[[:space:]]*worker_connections[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*events[[:space:]]*[{]' \
      "  worker_connections ${worker_connections};" "angie.conf: inserted worker_connections=${worker_connections}"
  fi
  if ! grep -qE '^[[:space:]]*client_body_buffer_size[[:space:]]' "$nginx_conf"; then
    # Anchor on the real block opener: a bare `http[[:space:]]*` also matches
    # directives such as `http2 on;` and would insert inside a server block.
    tune_insert_after "$nginx_conf" '^[[:space:]]*http[[:space:]]*[{]' \
      "  client_body_buffer_size ${body_buffer};" "angie.conf: inserted client_body_buffer_size=${body_buffer}"
  fi

  # Point any remaining TCP FastCGI handlers at the pool's Unix socket, but
  # only when optimize_php_services found an existing socket listener.  A pool
  # kept on TCP (the usual live-server case) must keep Angie on TCP as well.
  if [[ -n ${OPT_PHP_SOCKET:-} ]]; then
    local file php_socket=${OPT_PHP_SOCKET}
    while IFS= read -r file; do
      [[ -n $file ]] || continue
      local before after
      before=$(md5sum "$file" | awk '{print $1}')
      sed_in_place -E "s#^([[:space:]]*fastcgi_pass[[:space:]]+)(127\.0\.0\.1|localhost):9000;#\\1unix:${php_socket};#g" "$file"
      after=$(md5sum "$file" | awk '{print $1}')
      [[ $before != "$after" ]] && tune_note "${file#"${target}"/}: fastcgi_pass -> unix:${php_socket}"
    done < <(grep -rlE '^[[:space:]]*fastcgi_pass[[:space:]]+(127\.0\.0\.1|localhost):9000;' "$target" 2>/dev/null || true)

    if grep -qE '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' "$nginx_conf"; then
      tune_replace "$nginx_conf" \
        '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' \
        "\\1unix:${php_socket};" "angie.conf: local_php upstream -> Unix socket"
    fi
  fi

  if [[ -n $f_fcgi ]]; then
    tune_replace "$f_fcgi" \
      '^(.*keys_zone=fastcgicache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${fcgi_zone}m max_size=${fcgi_size}\\3" \
      "${f_fcgi#"${target}"/}: ${fcgi_zone}m zone / ${fcgi_size} max"
  else
    tune_miss "http.d: no active fastcgi_cache_path"
  fi
  if [[ -n $f_chev ]]; then
    tune_replace "$f_chev" \
      '^(.*keys_zone=fastcgicache_chev:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${chev_zone}m max_size=${chev_size}\\3" \
      "${f_chev#"${target}"/}: ${chev_zone}m zone / ${chev_size} max"
  else
    tune_miss "http.d: no active fastcgicache_chev cache_path"
  fi
  if [[ -n $f_xf ]]; then
    tune_replace "$f_xf" \
      '^(.*keys_zone=xfproxycache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${xf_zone}m max_size=${xf_size}\\3" \
      "${f_xf#"${target}"/}: ${xf_zone}m zone / ${xf_size} max"
  else
    tune_miss "http.d: no active xfproxycache cache_path"
  fi
  if [[ -n $f_proxy ]]; then
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cache:[0-9]+m' "keys_zone=proxy_cache:${proxy_zone}m" \
      "${f_proxy#"${target}"/}: proxy zone=${proxy_zone}m"
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cdn:[0-9]+m' "keys_zone=proxy_cdn:${cdn_zone}m" \
      "${f_proxy#"${target}"/}: cdn zone=${cdn_zone}m"

    local before tmp
    before=$(md5sum "$f_proxy" | awk '{print $1}')
    tmp=$(tmp_file)
    # proxy_cache_path directives commonly wrap onto a second line, so track
    # the active cache path and rewrite the first max_size seen afterwards
    # instead of only looking at the line that starts the directive.
    awk -v a="$proxy_size" -v b="$cdn_size" '
      {
        if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cache:/) cache = a
        else if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cdn:/) cache = b
        if (cache != "" && $0 ~ /max_size=[0-9]+[mgMG]/) {
          sub(/max_size=[0-9]+[mgMG]/, "max_size=" cache)
          cache = ""
        }
        print
        if ($0 ~ /;[[:space:]]*$/) cache = ""
      }
    ' "$f_proxy" > "$tmp"
    cat "$tmp" > "$f_proxy"
    [[ $(md5sum "$f_proxy" | awk '{print $1}') != "$before" ]] \
      && tune_note "${f_proxy#"${target}"/}: proxy=${proxy_size} cdn=${cdn_size}"
  else
    tune_miss "http.d: no active proxy_cache_path"
  fi

  limit_post=$(tune_clamp $(( mem_mb / 4096 )) 8 32)
  limit_get=$(tune_clamp $(( mem_mb / 2048 )) 16 64)
  if [[ -n $f_limit ]]; then
    tune_replace "$f_limit" \
      'zone=limit_req_post_head:[0-9]+m' "zone=limit_req_post_head:${limit_post}m" \
      "${f_limit#"${target}"/}: POST zone=${limit_post}m"
    tune_replace "$f_limit" \
      'zone=limit_req_get_perip:[0-9]+m' "zone=limit_req_get_perip:${limit_get}m" \
      "${f_limit#"${target}"/}: GET zone=${limit_get}m"
  else
    tune_miss "http.d: no active limit_req_zone"
  fi

  # Bound custom cache paths that are not part of the standard set.  Scan
  # only files Angie includes, so inert legacy leftovers are left untouched.
  local extra_zone extra_max file tmp
  local -a cache_files=()
  extra_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  if (( active_weight == 0 )); then
    # No standard cache type is present: the whole budget is available to
    # whatever custom cache path the host actually uses.
    extra_max=$cache_total_mb
    (( extra_max < 64 )) && extra_max=64
  else
    extra_max=$(tune_clamp $(( cache_total_mb / 8 )) 64 1024)
  fi
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    cache_files=("${TUNE_ACTIVE_HTTP[@]}")
  else
    mapfile -t cache_files < <(grep -rlE '^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]' \
      "$target/http.d" 2>/dev/null || true)
  fi
  for file in "${cache_files[@]}"; do
    [[ -n $file ]] || continue
    if [[ $file == "${f_fcgi:-}" || $file == "${f_chev:-}" || \
          $file == "${f_xf:-}" || $file == "${f_proxy:-}" ]]; then
      continue
    fi
    tmp=$(tmp_file)
    awk -v zcap="$extra_zone" -v mcap="$extra_max" '
      function cap_zone(line,    s, n, unit, mb, repl) {
        if (!match(line, /keys_zone=[A-Za-z0-9_]+:[0-9]+[mMgG]/)) return line
        s = substr(line, RSTART, RLENGTH)
        n = s; sub(/^.*:/, "", n)
        unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
        mb = (unit == "g" || unit == "G") ? n * 1024 : n
        if (mb + 0 <= zcap) return line
        repl = s; sub(/:[0-9]+[mMgG]$/, ":" zcap "m", repl)
        return substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
      }
      {
        line = cap_zone($0)
        if (match(line, /max_size=[0-9]+[mMgG]/)) {
          s = substr(line, RSTART, RLENGTH)
          n = s; sub(/^max_size=/, "", n)
          unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
          mb = (unit == "g" || unit == "G") ? n * 1024 : n
          if (mb + 0 > mcap) {
            repl = "max_size=" mcap "M"
            line = substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
          }
        } else if (line ~ /^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]/ \
                   && line ~ /;[[:space:]]*$/) {
          sub(/;[[:space:]]*$/, " max_size=" mcap "M;", line)
        }
        print line
      }
    ' "$file" > "$tmp"
    if ! cmp -s "$file" "$tmp"; then
      cat "$tmp" > "$file"
      tune_note "${file#"${target}"/}: custom cache capped at ${extra_zone}m zone / ${extra_max}M max"
    fi
  done

  tune_replace "$target/h5bp/tls/ssl_engine.conf" \
    '^([[:space:]]*ssl_session_cache[[:space:]]+shared:SSL:)[0-9]+m;' \
    "\\1${ssl_cache_mb}m;" "h5bp/tls/ssl_engine.conf: SSL cache=${ssl_cache_mb}m"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_file_cache max=[0-9]+' "open_file_cache max=${open_files}" \
    "h5bp/web_performance/cache-file-descriptors.conf: max=${open_files}"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_log_file_cache max=[0-9]+' "open_log_file_cache max=$(( open_files / 4 ))" \
    "h5bp/web_performance/cache-file-descriptors.conf: log max=$(( open_files / 4 ))"

  local php_conf
  for php_conf in "$target"/h5bp/php*.conf; do
    [[ -f $php_conf ]] || continue
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "${php_conf#"${target}"/}: fastcgi_buffer_size=${body_buffer}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffers[[:space:]]+).*;' "\\1${fastcgi_buffers};" "${php_conf#"${target}"/}: fastcgi_buffers=${fastcgi_buffers}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_busy_buffers_size[[:space:]]+).*;' "\\1${fastcgi_busy};" "${php_conf#"${target}"/}: fastcgi_busy_buffers_size=${fastcgi_busy}"
  done

  tune_cache_error_policy "$target/h5bp/wordpress_cache.conf" "h5bp/wordpress_cache.conf"
  tune_cache_error_policy "$target/h5bp/php_xf.conf" "h5bp/php_xf.conf"
  tune_cache_error_policy "$target/h5bp/php_xf_proxy.conf" "h5bp/php_xf_proxy.conf"
  tune_cache_error_policy "$target/h5bp/php_chev.conf" "h5bp/php_chev.conf"
  tune_cache_error_policy "$target/h5bp/php_flarum.conf" "h5bp/php_flarum.conf"

  tune_summary "angie summary: ${nproc} CPU / ${mem_mb}MB RAM / ${disk_class} / cache_budget=${cache_total_mb}MB"
  return 0
}

# ---------------------------------------------------------------------------
# PHP-FPM
# ---------------------------------------------------------------------------
tune_pool_set() {
  local file=$1 key=$2 value=$3 desc=$4 tmp
  local escaped=${key//./\\.}
  tmp=$(tmp_file) || return 1
  if grep -qE "^[[:space:]]*${escaped}[[:space:]]*=" "$file"; then
    sed -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*|${key} = ${value}|" "$file" > "$tmp" \
      || return 1
  else
    cat -- "$file" > "$tmp" || return 1
    printf '%s = %s\n' "$key" "$value" >> "$tmp"
  fi
  if cmp -s "$file" "$tmp"; then
    return 0
  fi
  cat -- "$tmp" > "$file"
  tune_note "$desc"
  return 0
}

# Collapse duplicate directives for keys this script owns, keeping the last
# occurrence (php-fpm's own precedence), without reordering unrelated lines.
tune_pool_dedupe() {
  local file=$1
  shift
  local keys="$*" tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk -v keys="$keys" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) managed[k[i]] = 1 }
    {
      # Directives are only duplicates inside the same [section]; rlimit_files
      # is valid both globally (master) and in a pool (workers).
      if (match($0, /^[ \t]*\[[^]]+\]/)) {
        section = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", section)
      }
      key = ""
      if (match($0, /^[ \t]*[^ \t=]+/)) {
        key = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
      }
      if (key in managed) last[section SUBSEP key] = NR
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (match(lines[i], /^[ \t]*\[[^]]+\]/)) {
          section = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", section)
        }
        key = ""
        if (match(lines[i], /^[ \t]*[^ \t=]+/)) {
          key = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", key)
        }
        if ((key in managed) && last[section SUBSEP key] != i) continue
        print lines[i]
      }
    }' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
    tune_note "$(basename "$file"): removed duplicate managed directives"
  fi
  return 0
}

# PHP-FPM opens the pool slowlog/access log when the master starts.  A pool
# upgraded from an older package can still point at a directory that no
# longer exists; enabling request_slowlog_timeout then makes `php-fpm -t`
# fail.  Create the configured parent directory first and, for a fixed path,
# the file itself.  Paths containing a runtime variable (for example
# "$pool.access.log") only get their directory created.
ensure_fpm_log_path() {
  local path=$1 user=${2:-www-data} group=${3:-www-data} dir created=0
  [[ $path == /* ]] || return 0
  dir=$(dirname -- "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  if [[ ${path##*/} != *'$'* ]]; then
    if [[ ! -e $path ]]; then
      : > "$path" 2>/dev/null || true
      created=1
    fi
    chmod 640 "$path" 2>/dev/null || true
    if (( created )) && getent passwd "$user" >/dev/null 2>&1; then
      chown "$user:$group" "$path" 2>/dev/null || true
    fi
  fi
  return 0
}

# The php-fpm master waits forever for workers when process_control_timeout is
# 0 (the package default).  On a busy pool a stop/restart then sits in
# systemd's "deactivating" state until TimeoutStopSec, and the shared socket
# is gone for the whole window (all PHP vhosts return 502).  Bound it.
ensure_fpm_global_timeout() {
  local ver=$1
  local conf="/etc/php/${ver}/fpm/php-fpm.conf"
  [[ -f $conf ]] || return 0
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$conf"; then
    grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s' "$conf" \
      && return 0
    sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$conf"
  elif grep -qE '^[[:space:]]*include[[:space:]]*=' "$conf"; then
    # Everything after the pool include is parsed inside the last included
    # pool section, so a global directive must go *before* it.
    sed_in_place -E '/^[[:space:]]*include[[:space:]]*=/i\
; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\
process_control_timeout = 10s' "$conf"
  else
    printf '\n; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\nprocess_control_timeout = 10s\n' >> "$conf"
  fi
  tune_note "PHP ${ver}: process_control_timeout=10s"
  return 0
}

# Old hosts can still carry a pre-1.8.41 custom_dan.ini (2 GB memory_limit,
# OPcache JIT off, curl_exec/exec disabled).  The managed
# zz-setup-optimize.ini overrides some values, but not allow_url_fopen or
# disable_functions, and removing the managed file would expose the stale
# limits.  --optimize refreshes the managed template while keeping the
# host's existing date.timezone.
sync_php_ini_template() {
  local ver=$1 target=${2:-} template=${3:-}
  if [[ -z $target ]]; then
    [[ -d /etc/php/${ver}/fpm ]] || return 0
    target="/etc/php/${ver}/fpm/conf.d/custom_dan.ini"
  fi
  [[ -n $template ]] || template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $template ]] || { tune_miss "PHP ${ver}: custom_dan.ini template not found"; return 0; }

  local tz=""
  if [[ -f $target ]]; then
    tz=$(awk -F= '/^[[:space:]]*date\.timezone[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit}' "$target")
  fi
  if [[ -z $tz && -r /etc/timezone ]]; then
    tz=$(head -n1 /etc/timezone | tr -d '[:space:]')
  fi

  local tmp
  tmp=$(tmp_file) || return 1
  if [[ -n $tz ]]; then
    awk -v tz="$tz" '
      /^[[:space:]]*date\.timezone[[:space:]]*=/ {
        print "date.timezone = " tz
        done = 1
        next
      }
      { print }
      END { if (!done) print "date.timezone = " tz }
    ' "$template" > "$tmp"
  else
    cat "$template" > "$tmp"
  fi

  # Never leave a global cgi.fix_pathinfo override in the default template.
  # With fix_pathinfo=0 PHP-FPM prefers PATH_TRANSLATED; the deployed PHP
  # includes used to map that to the document root, so every pretty URL was
  # denied.  The opt-in hardening block writes the value deliberately after
  # PATH_TRANSLATED is repaired.
  if [[ ${SETUP_PHP_SESSION_HARDENING:-0} != 1 ]] \
     && grep -qE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp"; then
    local cleaned
    cleaned=$(tmp_file) || return 1
    grep -vE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp" > "$cleaned" || true
    cat "$cleaned" > "$tmp"
  fi

  if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cat "$tmp" > "$target"
  chmod 644 "$target"
  tune_note "PHP ${ver}: custom_dan.ini refreshed from template"
  return 0
}

tune_php_fpm_version() {
  local ver=$1
  local socket=${2:-}
  local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
  local ini_dir="/etc/php/${ver}/fpm/conf.d"
  local ini="${ini_dir}/zz-setup-optimize.ini"
  [[ -d /etc/php/${ver}/fpm ]] || return 0
  [[ -f $pool ]] || { tune_miss "PHP ${ver}: no pool.d/www.conf, skipped"; return 0; }  # With no explicit socket request, keep whatever the pool already listens on
  # (TCP for a standalone PHP host, Unix socket for an Angie deployment).
  if [[ -z $socket ]]; then
    socket=$(php_pool_listen "$ver")
    [[ -n $socket ]] || socket=/run/php/php-fpm.sock
  fi

  local nproc ram_mb max_children max_requests max_by_cpu php_budget backlog
  local opcache_mb jit_mb memory_mb realpath_kb
  nproc=$(nproc)
  (( nproc > 0 )) || nproc=1
  ram_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  backlog=$(effective_backlog)

  php_budget=${OPT_PHP_BUDGET_MB:-0}
  if (( php_budget > 0 )); then
    # Shared --optimize budget, already sized against MariaDB/Valkey/ES.
    max_children=$(( php_budget / 96 ))
  else
    max_children=$(( ram_mb * 50 / 100 / 96 ))
  fi
  max_by_cpu=$(( nproc * 16 ))
  (( max_children > max_by_cpu )) && max_children=$max_by_cpu
  (( max_children > 512 )) && max_children=512
  (( max_children < 8 )) && max_children=8
  max_requests=$(( nproc * 1024 ))

  opcache_mb=$(( ram_mb / 16 )); (( opcache_mb < 128 )) && opcache_mb=128; (( opcache_mb > 512 )) && opcache_mb=512
  jit_mb=$(( ram_mb / 128 )); (( jit_mb < 32 )) && jit_mb=32; (( jit_mb > 128 )) && jit_mb=128
  memory_mb=$(( ram_mb / 8 )); (( memory_mb < 256 )) && memory_mb=256; (( memory_mb > 512 )) && memory_mb=512
  realpath_kb=$(( ram_mb * 2 )); (( realpath_kb < 4096 )) && realpath_kb=4096; (( realpath_kb > 16384 )) && realpath_kb=16384

  mkdir -p /run/php
  chown www-data:www-data /run/php 2>/dev/null || true
  chmod 755 /run/php

  tune_pool_set "$pool" pm static "PHP ${ver}: pm=static"
  tune_pool_set "$pool" pm.max_children "$max_children" "PHP ${ver}: max_children=${max_children}"
  tune_pool_set "$pool" pm.max_requests "$max_requests" "PHP ${ver}: max_requests=${max_requests}"
  tune_pool_set "$pool" listen "$socket" "PHP ${ver}: listen=${socket}"
  # listen.allowed_clients is meaningless (and noisy) for a Unix socket.
  if [[ $socket == /* ]] && grep -qE '^[[:space:]]*listen\.allowed_clients[[:space:]]*=' "$pool"; then
    sed_in_place -E '/^[[:space:]]*listen\.allowed_clients[[:space:]]*=/d' "$pool"
    tune_note "PHP ${ver}: removed listen.allowed_clients (Unix socket)"
  fi
  tune_pool_set "$pool" listen.backlog "$backlog" "PHP ${ver}: listen.backlog=${backlog}"
  tune_pool_set "$pool" listen.owner www-data "PHP ${ver}: listen.owner=www-data"
  tune_pool_set "$pool" listen.group www-data "PHP ${ver}: listen.group=www-data"
  tune_pool_set "$pool" listen.mode 0660 "PHP ${ver}: listen.mode=0660"
  # Ensure the pool's log destinations exist before enabling slow logging.  A
  # pool upgraded from an older package may still point slowlog at a
  # directory that no longer exists (seen on Ubuntu 24.04); php-fpm -t then
  # fails as soon as request_slowlog_timeout is set.
  local fpm_user fpm_group slowlog accesslog poollog
  fpm_user=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool")
  fpm_group=$(awk -F= '/^[[:space:]]*group[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool")
  slowlog=$(awk -F= '/^[[:space:]]*slowlog[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool")
  accesslog=$(awk -F= '/^[[:space:]]*access\.log[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool")
  poollog=$(awk -F= '/^[[:space:]]*error_log[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool")
  if [[ -z $slowlog ]]; then
    slowlog=/var/www/logs/php/php-fpm-slow.log
    tune_pool_set "$pool" slowlog "$slowlog" "PHP ${ver}: slowlog=${slowlog}"
  fi
  ensure_fpm_log_path "$slowlog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$accesslog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$poollog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  tune_pool_set "$pool" request_terminate_timeout 300s "PHP ${ver}: request_terminate_timeout=300s"
  tune_pool_set "$pool" request_slowlog_timeout 10s "PHP ${ver}: request_slowlog_timeout=10s"
  tune_pool_set "$pool" catch_workers_output yes "PHP ${ver}: catch_workers_output=yes"
  tune_pool_set "$pool" security.limit_extensions .php "PHP ${ver}: security.limit_extensions=.php"
  tune_pool_set "$pool" rlimit_files 524288 "PHP ${ver}: rlimit_files=524288"
  tune_pool_set "$pool" rlimit_core 0 "PHP ${ver}: rlimit_core=0"
  # Bound master/worker shutdown; see ensure_fpm_global_timeout().
  ensure_fpm_global_timeout "$ver"
  # Older pool templates carried a [global] block inside pool.d/www.conf.
  # pool.d is included after the global settings, so that copy wins over the
  # 10s written above.  Normalise it in place so a restart cannot reintroduce
  # the 60s shutdown wait.
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$pool"; then
    if ! grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s[[:space:]]*(;.*)?$' "$pool"; then
      sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$pool"
      tune_note "PHP ${ver}: pool-level process_control_timeout=10s"
    fi
  fi

  # Older releases appended the same directive more than once (the live
  # 8.3 pool carried two rlimit_files/rlimit_core pairs).  php-fpm lets the
  # last value win, but duplicates make the file confusing and hide drift.
  tune_pool_dedupe "$pool" \
    user group listen listen.allowed_clients listen.backlog listen.owner \
    listen.group listen.mode pm pm.max_children pm.max_requests \
    request_terminate_timeout catch_workers_output security.limit_extensions \
    rlimit_files rlimit_core process_control_timeout

  mkdir -p "$ini_dir" /var/cache/php/opcache
  chown -R www-data:www-data /var/cache/php 2>/dev/null || true
  chmod 750 /var/cache/php /var/cache/php/opcache 2>/dev/null || true
  sed_in_place -E "s|php8\.[0-9]|php${ver}|g" "$pool"
  local ini_before=""
  [[ -f $ini ]] && ini_before=$(md5sum "$ini" | awk '{print $1}')
  cat > "$ini" <<EOF
; Managed by setup.sh --optimize (hardware-aware PHP tuning).
; This file sorts last in conf.d so it wins over earlier defaults.
memory_limit = ${memory_mb}M
max_execution_time = 300
max_input_time = 300
realpath_cache_size = ${realpath_kb}k
realpath_cache_ttl = 43200
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${opcache_mb}
opcache.interned_strings_buffer = 32
opcache.jit_buffer_size = ${jit_mb}M
opcache.jit = tracing
opcache.max_accelerated_files = 128256
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.file_cache = /var/cache/php/opcache
opcache.file_cache_only = 0
mysqlnd.net_cmd_buffer_size = 524288
mysqli.default_socket = /run/mysqld/mysqld.sock
pdo_mysql.default_socket = /run/mysqld/mysqld.sock
EOF
  if [[ ${SETUP_PHP_SESSION_HARDENING:-0} == 1 ]]; then
    local php_error_log=/var/www/logs/php/php-error.log
    ensure_fpm_log_path "$php_error_log" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
    cat >> "$ini" <<EOF

; Optional session/cgi hardening, enabled with SETUP_PHP_SESSION_HARDENING=1.
; Not written by default: strict session IDs and Secure cookies can break
; Joomla/Polr sites and applications that validate PHP session identifiers.
cgi.fix_pathinfo = 0
expose_php = Off
display_errors = Off
log_errors = On
error_log = ${php_error_log}
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = Lax
session.gc_maxlifetime = 14400
session.sid_length = 48
session.sid_bits_per_character = 6
EOF
  fi
  chmod 644 "$ini"
  local ini_after
  ini_after=$(md5sum "$ini" | awk '{print $1}')
  if [[ $ini_before != "$ini_after" ]]; then
    tune_note "PHP ${ver}: memory_limit=${memory_mb}M opcache=${opcache_mb}M jit=${jit_mb}M"
    if [[ ${SETUP_PHP_SESSION_HARDENING:-0} == 1 ]]; then
      tune_note "PHP ${ver}: optional session/cgi hardening"
    fi
  fi

  local fpm_bin="" fpm_test
  if command -v "php-fpm${ver}" >/dev/null 2>&1; then
    fpm_bin=$(command -v "php-fpm${ver}")
  elif [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
    fpm_bin="/usr/sbin/php-fpm${ver}"
  fi
  if [[ -n $fpm_bin ]]; then
    fpm_test=$(tmp_file)
    if ! "$fpm_bin" -t >"$fpm_test" 2>&1; then
      printf 'PHP %s: php-fpm -t failed:\n' "$ver" >&2
      sed 's/^/  /' "$fpm_test" >&2 || true
      return 1
    fi
  fi
  return 0
}

deploy_angie_configs() {
  step "Angie configuration (server-configs-nginx)"
  fetch_server_configs

  mkdir -p /etc/systemd/system/angie.service.d
  install -m 644 "${CONFIG_SOURCE_DIR}/scripts/limit_nofile.conf" \
    /etc/systemd/system/angie.service.d/limits.conf
  install -m 644 "${CONFIG_SOURCE_DIR}/scripts/etc_default_nginx" \
    /etc/default/angie

  # Load the new drop-in before nginx_conf.sh reloads the unit; otherwise
  # systemctl prints "unit file changed on disk" and may use stale limits.
  systemctl daemon-reload || true

  # The repository owns the config tree, cache-directory creation, removal of
  # old setup.sh overrides, the angie -t check and the reload.
  export CONFIG_SOURCE_DIR
  if ! bash "${CONFIG_SOURCE_DIR}/scripts/nginx_conf.sh"; then
    warn "Angie config deployment failed"
    return 1
  fi

  # Hardware-aware Angie tuning is owned by setup.sh so the same code runs
  # during install and during `--optimize`.
  tune_reset_changes
  if ! tune_angie_configs /etc/angie; then
    warn "Angie tuning failed"
    return 1
  fi
  # Enable the same WordPress FastCGI guest cache that --optimize installs.
  optimize_wordpress_cache /etc/angie || warn "WordPress cache setup was skipped"
  local change
  for change in "${TUNE_CHANGES[@]}"; do info "tune: ${change}"; done
  for change in "${TUNE_MISSES[@]}"; do warn "tune not applied: ${change}"; done
}

# Ensure an embedded key file is present and byte-identical to the payload.
# A truncated file from an interrupted write, or an outdated key, otherwise
# makes every later apt operation fail until an operator removes it manually.
refresh_blob_key() {
  local target=$1 blob=$2 tmp
  tmp=$(tmp_file) || return 1
  "$blob" > "$tmp" 2>/dev/null || { warn "Could not decode ${blob}"; return 1; }
  [[ -s $tmp ]] || { warn "Embedded ${blob} decoded to an empty file"; return 1; }
  if [[ -s $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  install -m 644 "$tmp" "$target" || return 1
  info "Refreshed embedded key: ${target}"
}

refresh_blob_key_dearmor() {
  local target=$1 blob=$2 tmp
  tmp=$(tmp_file) || return 1
  "$blob" 2>/dev/null | gpg --dearmor --yes -o "$tmp" 2>/dev/null \
    || { warn "Could not decode/dearmor ${blob}"; return 1; }
  [[ -s $tmp ]] || { warn "Embedded ${blob} decoded to an empty key"; return 1; }
  if [[ -s $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  install -m 644 "$tmp" "$target" || return 1
  info "Refreshed embedded key: ${target}"
}

ensure_sury_keyring() {
  local keyring=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
  local deb extract embedded
  deb=$(tmp_file --suffix=.deb) || return 1
  blob_sury_deb > "$deb" 2>/dev/null || { warn "Could not decode Sury keyring payload"; return 1; }
  extract=$(tmp_dir) || return 1
  dpkg-deb -x "$deb" "$extract" 2>/dev/null || true
  embedded=$(find "$extract" -type f -name '*.gpg' 2>/dev/null | head -n1)
  if [[ -s $keyring && -n $embedded ]] && cmp -s "$keyring" "$embedded"; then
    return 0
  fi
  dpkg -i "$deb" || { warn "Could not install the Sury keyring package"; return 1; }
  info "Refreshed embedded key: ${keyring}"
}

# ---------------------------------------------------------------------------
# APT repositories
# ---------------------------------------------------------------------------
# Add every selected third-party repository first, then run one apt-get update
# in prepare_repositories().  The service installers only install packages.
configure_angie_repo() {
  refresh_blob_key /etc/apt/trusted.gpg.d/angie-signing.gpg blob_angie_key \
    || return 1
  chmod 644 /etc/apt/trusted.gpg.d/angie-signing.gpg
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb https://download.angie.software/angie/%s/%s %s main\n' \
    "$ID" "$VERSION_ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/angie.list
  chmod 644 /etc/apt/sources.list.d/angie.list
}

configure_php_repo() {
  ensure_sury_keyring || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/php.list
  chmod 644 /etc/apt/sources.list.d/php.list
}

configure_elastic_repo() {
  refresh_blob_key_dearmor /usr/share/keyrings/elasticsearch-keyring.gpg blob_elastic_key \
    || return 1
  chmod 644 /usr/share/keyrings/elasticsearch-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main\n' \
    > /etc/apt/sources.list.d/elastic-9.x.list
  chmod 644 /etc/apt/sources.list.d/elastic-9.x.list
}

configure_nodesource_repo() {
  refresh_blob_key_dearmor /usr/share/keyrings/nodesource.gpg blob_nodesource_key \
    || return 1
  chmod 644 /usr/share/keyrings/nodesource.gpg
  cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_26.x
Suites: nodistro
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
  chmod 644 /etc/apt/sources.list.d/nodesource.sources
}

prepare_repositories() {
  local configured=0 item
  apt_install ca-certificates curl gnupg lsb-release apt-transport-https
  if [[ ${ENABLED[angie]:-0} -eq 1 ]]; then
    configure_angie_repo || die "Could not configure the Angie APT repository"
    configured=1
  fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    configure_php_repo || die "Could not configure the Sury APT repository"
    configured=1
  fi
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    configure_elastic_repo || die "Could not configure the Elastic APT repository"
    configured=1
  fi
  if [[ ${ENABLED[others]:-0} -eq 1 ]]; then
    for item in "${OTHERS[@]}"; do
      if [[ $item == nodejs ]]; then
        configure_nodesource_repo || die "Could not configure the NodeSource APT repository"
        configured=1
        break
      fi
    done
  fi
  if (( configured )); then
    apt_update
  fi
}

install_angie() {
  step "Angie web server"
  local angie_backup=""
  apt_install ca-certificates curl wget unzip rsync openssl

  apt_install angie

  systemctl daemon-reload || true
  systemctl enable --now angie || warn "Angie did not start with the packaged config"

  # Keep a copy of the deployed tree so a failed repo deploy/tune can be
  # rolled back instead of leaving a live host with a broken configuration.
  if [[ -d /etc/angie ]]; then
    angie_backup=$(tmp_dir angie-install.XXXXXX) \
      || die "Could not create an Angie backup directory"
    cp -a /etc/angie "$angie_backup/" \
      || die "Could not back up /etc/angie to ${angie_backup}"
  fi

  if ! deploy_angie_configs; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi
  chmod 755 /etc/angie/scripts/cloudflare.sh 2>/dev/null || true

  systemctl daemon-reload
  if ! /usr/sbin/angie -t; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi
  if ! systemctl restart angie; then
    rollback_angie_tree "$angie_backup"
    return 1
  fi

  if ! /etc/angie/scripts/cloudflare.sh; then
    warn "Cloudflare IP update failed; keeping the existing cloudflare.conf"
    /usr/sbin/angie -t && systemctl reload angie || true
  fi

  systemctl status angie --no-pager -l || true
  systemctl is-active angie >/dev/null
  ok "Angie installed and running"
}

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
# A clean PHP install is required: a stopped but installed second PHP version
# still owns a pool that can later bind /run/php/php-fpm.sock and break the
# selected version.  Remove every PHP package first, keeping the old /etc/php
# tree recoverable under /tmp.
purge_php_installations() {
  local -a pkgs=() units=()
  mapfile -t pkgs < <(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | grep -E '^php([0-9]+\.[0-9]+)?(-|$)' | sort -u)
  (( ${#pkgs[@]} > 0 )) || return 0

  mapfile -t units < <(systemctl list-units --all --no-legend --no-pager 'php*-fpm.service' 2>/dev/null \
    | awk '{print $1}' | grep -E '^php.*-fpm\.service$' || true)
  local unit
  for unit in "${units[@]}"; do
    systemctl disable --now "$unit" 2>/dev/null || true
  done

  local backup=""
  if [[ -d /etc/php ]]; then
    backup=$(tmp_dir php-config.XXXXXX) || die "Could not create a PHP config backup directory"
    cp -a /etc/php "$backup/" 2>/dev/null \
      || warn "Could not back up /etc/php to ${backup}"
    info "Backed up the existing /etc/php tree to ${backup}"
  fi

  info "Purging existing PHP packages for a clean installation: ${pkgs[*]}"
  apt-get purge "${APT_OPTS[@]}" "${pkgs[@]}" \
    || die "Could not purge the existing PHP packages"

  # apt purge normally removes the tree; if conffiles survived, keep them in
  # /tmp instead of leaving a stale pool next to the new installation.
  if [[ -e /etc/php ]]; then
    local moved
    moved=$(preserve_to_tmp /etc/php 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved leftover /etc/php to ${moved}"
  fi
  systemctl daemon-reload || true
  systemctl reset-failed 'php*-fpm' 2>/dev/null || true
}

install_php() {
  local ver=${OPT[php.ver]:-}
  local tz=${OPT[basic.time]:-Asia/Manila}
  local php_backup=""
  step "PHP ${ver:-auto}"

  # The requested PHP version must be the only one installed, not merely the
  # only one active.  Purge everything before selecting/installing.
  purge_php_installations

  if [[ -z $ver ]]; then
    ver=$(latest_sury_php)
    [[ -n $ver ]] || die "Could not determine the latest stable PHP version from the Sury repository"
    OPT[php.ver]=$ver
    info "Auto-selected latest stable PHP: ${ver}"
  fi
  # run_service executes installers in a subshell; persist the selected version
  # so the parent shell reports and reuses the same value.
  ensure_state
  printf '%s\n' "$ver" > "${STATE_DIR}/php-selected-version"

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)9000$'; then
    die "Port 9000 is already in use by another process. Only one PHP version can run at a time; free the port first."
  fi
  # A stale socket left by a purged/crashed pool is replaced by PHP-FPM
  # itself when it binds.  setup.sh does not unlink it in case the path is
  # still in use by another process.
  [[ -S /run/php/php-fpm.sock ]] \
    && info "Leaving existing FastCGI socket for PHP-FPM to validate"
  mkdir -p /run/php
  chown www-data:www-data /run/php 2>/dev/null || true
  chmod 755 /run/php

  # XenForo-focused extension set: runtime, database, media, HTTP, XML,
  # archives, math, multibyte, Redis, OPcache and the CLI for XenForo cmd.php.
  # Add intl/imagick/bcmath/apcu only if a specific add-on needs them.
  #
  # PHP 8.5 made OPcache a mandatory, always-built-in extension: Sury (and
  # Ubuntu) no longer publish php8.5-opcache.  Installing the separate package
  # unconditionally made the whole PHP step fail on 26.04.  Keep the split
  # package for 8.4 and older, and rely on the bundled extension for 8.5+.
  local -a php_pkgs=(
    "php${ver}-fpm" "php${ver}-cli"
    "php${ver}-mysql" "php${ver}-gd" "php${ver}-curl" "php${ver}-xml"
    "php${ver}-zip" "php${ver}-gmp" "php${ver}-mbstring" "php${ver}-redis"
  )
  if apt-cache show "php${ver}-opcache" >/dev/null 2>&1; then
    php_pkgs+=("php${ver}-opcache")
  else
    info "PHP ${ver} bundles OPcache in the core package; skipping php${ver}-opcache"
  fi
  apt_install "${php_pkgs[@]}"

  # Preserve the package-created configuration so a bad template, tuning pass
  # or failed start can be rolled back.
  if [[ -d "/etc/php/${ver}/fpm" ]]; then
    php_backup=$(tmp_dir php-install.XXXXXX) \
      || die "Could not create a PHP backup directory"
    cp -a "/etc/php/${ver}/fpm" "$php_backup/" \
      || die "Could not back up PHP ${ver} configuration to ${php_backup}"
  fi

  # Keep the CLI on the same version as FPM.  Without this, installing a
  # distro package can add a newer php-cli and make /usr/bin/php point at a
  # binary whose extension set differs from the web pool.
  if command -v update-alternatives >/dev/null 2>&1 \
     && [[ -x "/usr/bin/php${ver}" ]]; then
    update-alternatives --set php "/usr/bin/php${ver}" >/dev/null 2>&1 \
      || warn "Could not pin /usr/bin/php to PHP ${ver}"
  fi

  # PHP-FPM is not an Angie concern: its pool/ini templates live in this
  # repository under configs/php and no longer depend on the Angie config
  # repository being fetched.
  local pool_template="${SCRIPT_DIR}/configs/php/www_${ver//./}.conf"
  local ini_template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $pool_template ]] \
    || die "PHP ${ver} FPM pool template not found: configs/php/www_${ver//./}.conf"
  [[ -f $ini_template ]] \
    || die "PHP php.ini template not found: configs/php/custom_dan.ini"

  install -m 644 "$pool_template" "/etc/php/${ver}/fpm/pool.d/www.conf"
  install -m 644 "$ini_template" "/etc/php/${ver}/fpm/conf.d/custom_dan.ini"

  # Hardware-aware pool/ini tuning lives in tune_php_fpm_version, shared with
  # the --optimize command.  It writes the socket listener and the final
  # performance values in conf.d/zz-setup-optimize.ini.
  tune_reset_changes
  if ! tune_php_fpm_version "$ver"; then
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  if [[ -n ${OPT[php.children]:-} && ${OPT[php.children]} != auto ]]; then
    tune_pool_set "/etc/php/${ver}/fpm/pool.d/www.conf" pm.max_children \
      "${OPT[php.children]}" "PHP ${ver}: max_children override=${OPT[php.children]}"
    info "PHP max_children overridden to ${OPT[php.children]}"
  fi
  if [[ -n ${OPT[php.max_requests]:-} ]]; then
    tune_pool_set "/etc/php/${ver}/fpm/pool.d/www.conf" pm.max_requests \
      "${OPT[php.max_requests]}" "PHP ${ver}: max_requests override=${OPT[php.max_requests]}"
  fi
  sed_in_place -E "s|^date\.timezone = .*|date.timezone = ${tz}|" \
    "/etc/php/${ver}/fpm/conf.d/custom_dan.ini"

  mkdir -p /var/cache/php/opcache
  chown -R www-data:www-data /var/cache/php
  chmod 750 /var/cache/php /var/cache/php/opcache
  ensure_log_dirs

  mkdir -p "/etc/systemd/system/php${ver}-fpm.service.d"
  install -m 644 "${SCRIPT_DIR}/configs/php/php-fpm-limits.conf" \
    "/etc/systemd/system/php${ver}-fpm.service.d/limits.conf"
  # Bound worker shutdown so a restart cannot sit in "deactivating".
  ensure_fpm_global_timeout "$ver"
  systemctl daemon-reload

  # Only one PHP-FPM version can own the shared /run/php/php-fpm.sock socket.
  # (The conflict was checked before apt_install; this just clears any
  # previous failed state for the same version.)
  systemctl reset-failed "php${ver}-fpm" 2>/dev/null || true
  if ! systemctl enable --now "php${ver}-fpm" \
     || ! systemctl restart "php${ver}-fpm"; then
    rollback_php_tree "$php_backup" "$ver"
    return 1
  fi
  systemctl status "php${ver}-fpm" --no-pager || true
  if command -v "php-fpm${ver}" >/dev/null 2>&1; then
    "php-fpm${ver}" -v
  else
    "/usr/sbin/php-fpm${ver}" -v
  fi
  ok "PHP ${ver} installed"
}

# ---------------------------------------------------------------------------
# MariaDB
# ---------------------------------------------------------------------------
configure_mariadb_apparmor() {
  # Ubuntu 26.04 ships an enforcing "mariadbd" AppArmor profile that omits
  # dac_override/setuid/setgid.  The package postinst runs mariadb-install-db
  # (a bootstrap mariadbd as root), which needs those capabilities.  Without
  # this override a fresh install that follows a purge fails to create the
  # mysql system tables.
  [[ -d /etc/apparmor.d ]] || return 0

  local localfile=/etc/apparmor.d/local/mariadbd
  local begin='# BEGIN setup.sh mariadb apparmor'
  local end='# END setup.sh mariadb apparmor'
  local tmp

  mkdir -p /etc/apparmor.d/local
  # Always refresh the managed block so new log paths are picked up on
  # upgrades; keep any unrelated operator rules outside the markers.
  if [[ -f $localfile ]]; then
    tmp=$(tmp_file)
    awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$localfile" > "$tmp"
    cat "$tmp" > "$localfile"
  fi
  {
    printf '%s\n' "$begin"
    printf '# Allow mariadb-install-db to bootstrap the server as root.\n'
    printf 'capability dac_override,\n'
    printf 'capability dac_read_search,\n'
    printf 'capability setuid,\n'
    printf 'capability setgid,\n'
    printf '# Central log tree (/var/www/logs).\n'
    printf '/var/www/logs/mariadb/ r,\n'
    printf '/var/www/logs/mariadb/** rw,\n'
    printf '%s\n' "$end"
  } >> "$localfile"

  # If a previous install was purged, the profile file is gone but the old
  # profile can still be loaded in the kernel.  That stale profile is what
  # breaks the next mariadb-install-db.  Remove it before installing again.
  if command -v aa-status >/dev/null 2>&1 \
     && aa-status 2>/dev/null | grep -qE '^[[:space:]]*mariadbd[[:space:]]*$' \
     && [[ ! -f /etc/apparmor.d/mariadbd ]]; then
    local tmp
    tmp=$(tmp_file)
    printf '#include <tunables/global>\nprofile mariadbd /usr/sbin/mariadbd { }\n' > "$tmp"
    apparmor_parser -R "$tmp" 2>/dev/null || true
  fi

  if [[ -f /etc/apparmor.d/mariadbd ]] && command -v apparmor_parser >/dev/null 2>&1; then
    apparmor_parser -r /etc/apparmor.d/mariadbd 2>/dev/null || true
  fi
}

mariadb_io_capacity() {
  case $(storage_class) in
    nvme) printf '4000 8000' ;;
    ssd)  printf '2000 4000' ;;
    *)    printf '400 800' ;;
  esac
}

# One hardware profile for both a fresh install and --optimize.  Keeping the
# arithmetic here means the two paths cannot drift apart again (for example
# one writing a larger log file or a different connection ceiling).
MARIADB_PROFILE_BUFFER=""
MARIADB_PROFILE_LOG_SIZE=""
MARIADB_PROFILE_OPEN_CACHE=""
MARIADB_PROFILE_ARIA_MB=""
MARIADB_PROFILE_THREADS=""
MARIADB_PROFILE_MAX_CONN=""
MARIADB_PROFILE_IO_READ=""
MARIADB_PROFILE_IO_WRITE=""
MARIADB_PROFILE_BACKLOG=""

# Remove the performance/logging directives from 50-server.cnf once the
# optimize drop-in exists.  Older releases wrote these keys bare (without the
# managed markers), so strip them wherever they appear, not only inside the
# marker block; otherwise 50- and 99- carry two competing definitions and the
# old 2 GB/5 GB values return if the drop-in is ever removed.  Base settings
# (charset, bind-address, skip_name_resolve, secure_file_priv, ...) stay in 50.
# The optional third argument is for tests; production uses the live path.
mariadb_strip_install_block() {
  local size_mb=$1 max_conn=$2
  local cnf=${3:-/etc/mysql/mariadb.conf.d/50-server.cnf}
  local tmp keys
  [[ -f $cnf ]] || return 0
  keys=$( { mariadb_performance_settings "$size_mb" "$max_conn"; mariadb_logging_settings; } 2>/dev/null \
    | sed -n 's/^\([a-z0-9_]*\)[[:space:]]*=.*/\1/p' | paste -sd'|' -)
  [[ -n $keys ]] || return 0
  tmp=$(tmp_file) || return 1
  awk -v b="$MARIADB_BEGIN" -v e="$MARIADB_END" -v keys="$keys" '
    $0 == b { print; next }
    $0 == e { print; next }
    $0 ~ ("^[[:space:]]*(" keys ")[[:space:]]*=") { next }
    { print }
  ' "$cnf" > "$tmp"
  if ! cmp -s "$cnf" "$tmp"; then
    cat "$tmp" > "$cnf"
    info "Removed duplicate MariaDB performance keys from ${cnf}; 99-setup-optimize.cnf owns them"
    opt_report "- Removed duplicate performance keys from \`${cnf}\`; \`99-setup-optimize.cnf\` owns them"
  fi
  return 0
}

mariadb_compute_profile() {
  local size_mb=$1 logsize open_cache aria_mb threads max_conn current_max=""
  logsize=$(( size_mb / 4 ))
  (( logsize < 64 )) && logsize=64
  (( logsize > 2048 )) && logsize=2048
  open_cache=4000
  (( size_mb >= 4096 )) && open_cache=8000
  aria_mb=$(( size_mb / 16 ))
  (( aria_mb < 16 )) && aria_mb=16
  (( aria_mb > 256 )) && aria_mb=256
  threads=$(nproc)
  (( threads > 64 )) && threads=64
  # PHP-FPM opens one MariaDB connection per active request.  A 500-connection
  # cap was hit at 500 concurrent requests (observed as "Too many connections"
  # / HTTP 503 during the aggressive run).  Size the server above the FPM pool
  # plus admin/backup headroom; the thread pool makes extra sessions cheap.
  max_conn=$(( threads * 32 ))
  # Never lower an existing, larger ceiling: a busy application may already
  # allow more than threads*32 connections, and a tune must not turn into
  # "Too many connections" during a traffic peak.
  if command -v mariadb >/dev/null 2>&1 \
     && systemctl is-active --quiet mariadb 2>/dev/null; then
    current_max=$(mariadb -N -B -e 'SELECT @@max_connections' 2>/dev/null || true)
  fi
  if [[ $current_max =~ ^[0-9]+$ ]] && (( current_max > max_conn )); then
    max_conn=$current_max
  fi
  (( max_conn > 2000 )) && max_conn=2000
  (( max_conn < 200 )) && max_conn=200

  MARIADB_PROFILE_BUFFER=$(mb_to_config "$size_mb")
  MARIADB_PROFILE_LOG_SIZE=$(mb_to_config "$logsize")
  MARIADB_PROFILE_OPEN_CACHE=$open_cache
  MARIADB_PROFILE_ARIA_MB=$aria_mb
  MARIADB_PROFILE_THREADS=$threads
  MARIADB_PROFILE_MAX_CONN=$max_conn
  read -r MARIADB_PROFILE_IO_READ MARIADB_PROFILE_IO_WRITE <<< "$(mariadb_io_capacity)"
  MARIADB_PROFILE_BACKLOG=$(effective_backlog)
}

# Print the performance directives shared by the install-time 50-server.cnf
# block and the --optimize 99-setup-optimize.cnf drop-in.
# Logging keys are shared by the installer block and the --optimize drop-in.
# Keeping them in one helper prevents an old host from keeping slow logging
# off (or log_error empty) after --optimize.
mariadb_logging_settings() {
  cat <<'EOF'
slow_query_log = 1
slow_query_log_file = /var/www/logs/mariadb/slow.log
long_query_time = 1
min_examined_row_limit = 100
log_slow_verbosity = query_plan,explain
log_slow_admin_statements = 1
log_error = /var/www/logs/mariadb/error.log
EOF
}

mariadb_performance_settings() {
  local size_mb=$1 max_conn=${2:-}
  local ver major minor
  mariadb_compute_profile "$size_mb"
  [[ -n $max_conn ]] || max_conn=$MARIADB_PROFILE_MAX_CONN
  ver=$(mariadb_server_version 2>/dev/null || true)
  major=${ver%%.*}
  minor=${ver#*.}; minor=${minor%%.*}
  if ! [[ $major =~ ^[0-9]+$ ]]; then
    # Fresh install before the server has started: the install target is
    # Ubuntu 26.04 with MariaDB 11.8, which uses the per-file buffering knobs.
    major=11; minor=8
  fi
  [[ $minor =~ ^[0-9]+$ ]] || minor=0

  cat <<EOF
max_connections = ${max_conn}
max_connect_errors = 524288
back_log = ${MARIADB_PROFILE_BACKLOG}
thread_cache_size = 64
thread_handling = pool-of-threads
thread_pool_size = ${MARIADB_PROFILE_THREADS}
max_allowed_packet = 64M
wait_timeout = 600
interactive_timeout = 600
net_read_timeout = 120
net_write_timeout = 120

innodb_log_buffer_size = 64M
innodb_log_file_size = ${MARIADB_PROFILE_LOG_SIZE}
innodb_buffer_pool_size = ${MARIADB_PROFILE_BUFFER}
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON
innodb_buffer_pool_dump_pct = 25
innodb_stats_on_metadata = OFF
innodb_lock_wait_timeout = 100
innodb_flush_neighbors = 0
innodb_stats_persistent = ON
innodb_stats_auto_recalc = ON
innodb_lru_scan_depth = 2048
innodb_io_capacity = ${MARIADB_PROFILE_IO_READ}
innodb_io_capacity_max = ${MARIADB_PROFILE_IO_WRITE}
innodb_read_io_threads = ${MARIADB_PROFILE_THREADS}
innodb_write_io_threads = ${MARIADB_PROFILE_THREADS}
innodb_flush_log_at_trx_commit = 2
EOF
  if (( major > 11 || (major == 11 && minor >= 8) )); then
    cat <<'EOF'
# MariaDB 11.8+ per-file buffering knobs (OFF = O_DIRECT).
innodb_data_file_buffering = OFF
innodb_data_file_write_through = OFF
innodb_log_file_buffering = OFF
innodb_log_file_write_through = OFF
EOF
  else
    cat <<'EOF'
# MariaDB <= 11.7 uses the legacy flush method.
innodb_flush_method = O_DIRECT
EOF
  fi
  cat <<EOF
join_buffer_size = 512K
read_buffer_size = 512K
read_rnd_buffer_size = 512K
sort_buffer_size = 1M
tmp_table_size = 64M
max_heap_table_size = 64M
table_open_cache = ${MARIADB_PROFILE_OPEN_CACHE}
table_definition_cache = ${MARIADB_PROFILE_OPEN_CACHE}
innodb_open_files = ${MARIADB_PROFILE_OPEN_CACHE}
key_buffer_size = 32M
aria_pagecache_buffer_size = ${MARIADB_PROFILE_ARIA_MB}M
EOF
}

configure_mariadb() {
  local size_mb=$1 bind=$2
  local cnf=/etc/mysql/mariadb.conf.d/50-server.cnf
  local optcnf=/etc/mysql/mariadb.conf.d/99-setup-optimize.cnf
  local tmp
  [[ -f $cnf ]] || die "MariaDB config ${cnf} not found"

  # A fresh install writes performance values into 50-server.cnf.  If an
  # earlier --optimize created the 99- drop-in, move it out of the live tree
  # so the newly written 50- block is the single owner again instead of
  # leaving two overlapping definitions.
  if [[ -f $optcnf ]]; then
    local moved
    moved=$(preserve_to_tmp "$optcnf" 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved previous optimize tuning to ${moved}"
  fi

  # Comment out expire_logs_days if it is active.
  sed_in_place -E 's|^([[:space:]]*)expire_logs_days([[:space:]]*=)|\1#expire_logs_days\2|' "$cnf"

  # Configure bind-address in the packaged [mysqld] section if present.
  if grep -qE '^[[:space:]]*bind-address[[:space:]]*=' "$cnf"; then
    sed_in_place -E "s|^[[:space:]]*bind-address[[:space:]]*=.*|bind-address = ${bind}|" "$cnf"
  fi

  # Drop a previous managed block, then append a fresh one.
  tmp=$(tmp_file)
  awk -v b="$MARIADB_BEGIN" -v e="$MARIADB_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$cnf" > "$tmp"
  cat "$tmp" > "$cnf"

  cat >> "$cnf" <<EOF
${MARIADB_BEGIN}
[mariadbd]
collation-server = utf8mb4_general_ci
character-set-server = utf8mb4

innodb_snapshot_isolation = 1
skip_name_resolve = 1
query_cache_size = 0
query_cache_type = 0
open_files_limit = 524288
secure_file_priv = /var/lib/mysql-files
local_infile = 0
innodb_read_only_compressed = OFF

EOF
  mariadb_performance_settings "$size_mb" >> "$cnf"
  mariadb_logging_settings >> "$cnf"
  cat >> "$cnf" <<EOF

bind-address = ${bind}
${MARIADB_END}
EOF
}

install_mariadb() {
  local user=${OPT[mariadb.user]}
  local pass=${OPT[mariadb.pass]}
  local size=${OPT[mariadb.size]}
  local bind
  local size_mb
  step "MariaDB"

  if [[ ${size,,} == auto ]]; then
    local ram_mb
    if (( ${OPT_MARIADB_BUDGET_MB:-0} > 0 )); then
      size_mb=$OPT_MARIADB_BUDGET_MB
      info "MariaDB size=auto resolved to $(mb_to_config "$size_mb") (shared memory plan)"
    else
      ram_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
      size_mb=$(( ram_mb * 40 / 100 ))
      (( size_mb < 256 )) && size_mb=256
      info "MariaDB size=auto resolved to $(mb_to_config "$size_mb") (40% of RAM)"
    fi
  else
    size_mb=$(size_to_mb "$size")
    [[ -n $size_mb ]] || die "Could not parse MariaDB size '${size}'"
  fi

  bind=${OPT[mariadb.bind]:-127.0.0.1}
  if ! resolve_mariadb_bind "$bind"; then
    die "--mariadb bind='${bind}': ${BIND_BAD_TOKEN}"
  fi
  bind=$REPLY
  OPT[mariadb.bind]=$bind
  info "MariaDB bind-address: ${bind}"

  local -a bind_addrs
  local addr
  IFS=',' read -r -a bind_addrs <<< "$bind"
  for addr in "${bind_addrs[@]}"; do
    if [[ $addr != 127.* && $addr != "::1" ]]; then
      warn "MariaDB will also listen on ${addr}."
      warn "UFW does not open 3306 automatically; allow only trusted clients, e.g.: ufw allow from <client-ip> to any port 3306"
      warn "Remote clients also need a matching account, e.g.: CREATE USER 'app'@'<client-ip>' IDENTIFIED BY '...';"
      [[ $addr == 0.0.0.0 ]] && warn "0.0.0.0 exposes MariaDB on every interface; prefer explicit addresses."
      if ! is_local_ipv4 "$addr" && [[ $addr != 0.0.0.0 ]]; then
        warn "${addr} is not assigned to this host; MariaDB may fail to bind unless it is added to an interface first."
      fi
      break
    fi
  done

  configure_mariadb_apparmor
  apt_install mariadb-server mariadb-client
  systemctl enable --now mariadb
  systemctl status mariadb --no-pager || true

  mkdir -p /etc/systemd/system/mariadb.service.d
  local mariadb_limits_src="${SCRIPT_DIR}/configs/mariadb/limit_nofile.conf"
  if [[ -f $mariadb_limits_src ]]; then
    install -m 644 "$mariadb_limits_src" \
      /etc/systemd/system/mariadb.service.d/limits.conf
  else
    cat > /etc/systemd/system/mariadb.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitCORE=0
# Silence the package unit's "unset environment variable" journal warning.
Environment=MYSQLD_OPTS=
Environment=_WSREP_NEW_CLUSTER=
EOF
  fi

  configure_mariadb "$size_mb" "$bind"

  mkdir -p /var/lib/mysql-files
  chown -R mysql:mysql /var/lib/mysql-files
  chmod 750 /var/lib/mysql-files
  ensure_log_dirs
  systemctl daemon-reload

  local i
  for i in {1..30}; do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done

  if ! systemctl restart mariadb; then
    journalctl -u mariadb -n 80 --no-pager || true
    return 1
  fi
  for i in {1..30}; do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done

  local eu ep sql host
  eu=$(sql_escape "$user")
  ep=$(sql_escape "$pass")
  # skip_name_resolve=1 means 127.0.0.1 is not translated to localhost, so an
  # account created only for 'user'@'localhost' cannot be used over TCP.
  # Create the same account for every loopback spelling.
  for host in localhost 127.0.0.1 ::1; do
    sql="CREATE USER IF NOT EXISTS '${eu}'@'${host}' IDENTIFIED BY '${ep}'; ALTER USER '${eu}'@'${host}' IDENTIFIED BY '${ep}'; GRANT ALL ON *.* TO '${eu}'@'${host}' WITH GRANT OPTION;"
    mariadb -e "$sql"
  done
  mariadb -e 'FLUSH PRIVILEGES;'

  # MySQL Tuner (embedded)
  blob_mysqltuner > /root/mysqltuner.pl
  chmod +x /root/mysqltuner.pl

  # MariaDB backup utility (embedded repository snapshot)
  ensure_state
  if ! dpkg-query -W -f='${Status}' lz4 2>/dev/null | grep -q 'ok installed'; then
    touch "${STATE_DIR}/lz4-installed"
  fi
  apt_install lz4
  mkdir -p /root/tools/mysqlbackup-master /var/www
  blob_mysqlbackup | tar -xzf - -C /root/tools/mysqlbackup-master
  chmod +x /root/tools/mysqlbackup-master/install /root/tools/mysqlbackup-master/mysqlbkup.sh
  # The upstream installer uses "mkdir" without -p; make it idempotent.
  sed_in_place 's|^mkdir "\$BACKUP_DIR"|mkdir -p "$BACKUP_DIR"|' \
    /root/tools/mysqlbackup-master/install

  local esc_user esc_pass
  esc_user=$(sed_escape_replacement "$user")
  esc_pass=$(sed_escape_replacement "$pass")
  sed_in_place "s|user=dba|user=${esc_user}|g; s|password=dba_passwd|password=${esc_pass}|g" \
    /root/tools/mysqlbackup-master/mysqlbkup.cnf.sample

  ( cd /root/tools/mysqlbackup-master && ./install ) || warn "mysqlbkup installer reported an issue"
  mkdir -p /var/www/mysql_database
  chmod 700 /var/www/mysql_database
  info "MariaDB Backup Installed"

  command -v mysqldump >/dev/null || die "mysqldump is missing; backups would fail"
  command -v mariadb-check >/dev/null || warn "mariadb-check is missing; the check cron will fail"

  systemctl status mariadb --no-pager || true
  mariadb-admin --version || true
  ok "MariaDB installed and configured"
}

# ---------------------------------------------------------------------------
# Valkey
# ---------------------------------------------------------------------------
# The live-tuning keys are shared so a fresh install and --optimize cannot
# disagree about maxmemory, backlog, lazy-free or I/O settings.
valkey_tuning_lines() {
  local max_mb=$1 policy=$2 io_threads=$3
  cat <<EOF
maxmemory ${max_mb}mb
maxmemory-policy ${policy}
maxmemory-samples 10
maxclients 20000
tcp-backlog $(effective_backlog)
timeout 0
tcp-keepalive 300
hz 10
io-threads ${io_threads}
io-threads-do-reads yes
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes
EOF
}

install_valkey() {
  step "Valkey"
  if pkg_ok redis-server; then
    warn "redis-server is installed; leaving it untouched because setup.sh never removes packages."
    warn "Valkey was not installed. Run --optimize to tune the existing Redis server with the same cache profile."
    # A pre-existing Redis is not a failed install: the requested service was
    # already covered by a compatible cache and --optimize handles it.
    return 0
  fi
  apt_clean
  apt_install valkey-server
  ensure_log_dirs

  local conf=/etc/valkey/valkey.conf
  [[ -f $conf ]] || die "Valkey config ${conf} not found"

  local line ram_mb valkey_mb policy io_threads
  ram_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  if [[ -n ${OPT[valkey.ram]:-} && ${OPT[valkey.ram],,} != auto ]]; then
    valkey_mb=$(size_to_mb "${OPT[valkey.ram]}")
  elif (( ${OPT_VALKEY_BUDGET_MB:-0} > 0 )); then
    valkey_mb=$OPT_VALKEY_BUDGET_MB
  else
    valkey_mb=$(( ram_mb / 10 ))          # ~10% of RAM for cache
    (( valkey_mb < 256 )) && valkey_mb=256
    (( valkey_mb > 8192 )) && valkey_mb=8192
  fi
  policy=${OPT[valkey.policy]:-allkeys-lru}
  # For typical web-cache command sizes, extra I/O threads add more CPU
  # contention than throughput.  Benchmarks on a 16-core host showed
  # io-threads=1 at 6.5k full-page req/s vs 5.1k at io-threads=8.
  io_threads=${OPT[valkey.io_threads]:-1}

  # Normalise the directives this script owns: remove active copies, then
  # append the canonical values once.  This also upgrades old profiles that
  # had "protected-mode no" without leaving contradictory duplicates.
  sed_in_place -E '/^[[:space:]]*(bind|protected-mode|save|maxmemory|maxmemory-policy|maxmemory-samples|supervised|io-threads|io-threads-do-reads|tcp-backlog|tcp-keepalive|timeout|maxclients|hz|appendonly|lazyfree-[a-z-]+|unixsocket|unixsocketperm|logfile)[[:space:]]/d' "$conf"
  local -a vlines=(
    'supervised systemd'
    "logfile ${LOG_ROOT}/valkey/valkey.log"
    'save ""'
    'appendonly no'
    'bind 127.0.0.1 -::1'
    'protected-mode yes'
    'unixsocket /run/valkey/valkey.sock'
    'unixsocketperm 770'
  )
  for line in "${vlines[@]}"; do
    printf '%s\n' "$line" >> "$conf"
  done
  valkey_tuning_lines "$valkey_mb" "$policy" "$io_threads" >> "$conf"
  info "Valkey maxmemory: ${valkey_mb} MB ($(printf '%s' "$policy"); ~10% of RAM by default)"
  tail -20 "$conf"

  mkdir -p /etc/systemd/system/valkey-server.service.d
  cat > /etc/systemd/system/valkey-server.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=524288
LimitCORE=0
# The packaged unit uses ProtectSystem=strict; allow the central log tree.
ReadWritePaths=${LOG_ROOT}/valkey
EOF
  systemctl daemon-reload

  # Local PHP workers should use the Unix socket instead of opening a fresh
  # TCP connection (and burning an ephemeral port) for every request.
  if getent group valkey >/dev/null 2>&1; then
    if ! id -nG www-data 2>/dev/null | grep -qw valkey; then
      usermod -aG valkey www-data || warn "Could not add www-data to the valkey group"
    fi
  fi

  valkey-server -v
  systemctl enable --now valkey-server
  systemctl restart valkey-server
  systemctl status valkey-server -l --no-pager || true

  # Refresh PHP-FPM workers so they inherit the valkey supplementary group.
  local unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    systemctl restart "$unit" 2>/dev/null || true
  done < <(systemctl list-units --type=service --state=active --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}')

  local i
  for i in {1..20}; do
    valkey-cli ping 2>/dev/null | grep -q PONG && break
    sleep 1
  done
  valkey-cli ping
  ok "Valkey installed and running"
}

# ---------------------------------------------------------------------------
# Elasticsearch
# ---------------------------------------------------------------------------
# Install and --optimize share one copy of the managed YAML block and one
# systemd drop-in.  Previously each path wrote its own file name and key list,
# so an optimize after install left two competing definitions.
elasticsearch_strip_managed() {
  local file=$1 include_base=${2:-0} tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk -v b="$ES_BEGIN" -v e="$ES_END" -v ib="$include_base" '
    $0 == "# BEGIN setup.sh optimize" { skip = 1; next }
    $0 == "# END setup.sh optimize" { skip = 0; next }
    $0 == b && ib == 1 { skip = 1; next }
    $0 == e && ib == 1 { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
}

elasticsearch_comment_keys() {
  local file=$1 key
  shift
  for key in "$@"; do
    sed_in_place -E "s|^[[:space:]]*${key//./\\.}[[:space:]]*:.*|#&|" "$file"
  done
}

elasticsearch_write_performance_block() {
  local file=$1
  elasticsearch_comment_keys "$file" \
    bootstrap.memory_lock indices.query.bool.max_clause_count \
    indices.memory.index_buffer_size indices.fielddata.cache.size \
    search.max_buckets action.destructive_requires_name \
    http.compression http.max_content_length http.host transport.host
  cat >> "$file" <<'EOF'
# BEGIN setup.sh optimize
bootstrap.memory_lock: true
indices.query.bool.max_clause_count: 4096
indices.memory.index_buffer_size: 20%
indices.fielddata.cache.size: 20%
search.max_buckets: 65536
action.destructive_requires_name: true
http.compression: true
http.max_content_length: 200mb
# END setup.sh optimize
EOF
  chmod 644 "$file"
}

elasticsearch_write_systemd_limits() {
  local dir=/etc/systemd/system/elasticsearch.service.d
  mkdir -p "$dir"
  cat > "${dir}/limits.conf" <<'EOF'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitNPROC=4096
EOF
  chmod 644 "${dir}/limits.conf"
}

install_elastic() {
  local host=${OPT[elastic.host]:-localhost}
  local ram=${OPT[elastic.ram]:-auto}
  local ram_lc=${ram,,}
  local ram_mb ram_total_mb
  step "Elasticsearch"

  ram_total_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  if [[ $ram_lc == auto ]]; then
    if (( ${OPT_ES_BUDGET_MB:-0} > 0 )); then
      ram_mb=$OPT_ES_BUDGET_MB
      info "Elasticsearch heap auto-resolved to ${ram_mb} MB (shared memory plan)"
    else
      # 25% of RAM leaves room for MariaDB's buffer pool, Valkey, PHP-FPM and
      # the kernel page cache.  Round down to a 512 MB boundary for predictable
      # JVM heap ergonomics and honour Elasticsearch's practical 31 GB ceiling.
      ram_mb=$(( ram_total_mb * 25 / 100 ))
      (( ram_mb > 31744 )) && ram_mb=31744
      (( ram_mb < 512 )) && ram_mb=512
      ram_mb=$(( ram_mb / 512 * 512 ))
      (( ram_mb < 512 )) && ram_mb=512
      info "Elasticsearch heap auto-resolved to ${ram_mb} MB (25% of RAM)"
    fi
    ram_lc="${ram_mb}m"
  elif [[ $ram_lc == *g ]]; then
    ram_mb=$(( ${ram_lc%g} * 1024 ))
  else
    ram_mb=${ram_lc%m}
  fi
  if (( ram_mb > ram_total_mb / 2 )); then
    warn "Elasticsearch heap (${ram_lc}) exceeds 50% of RAM; the kernel may OOM-kill it."
  fi

  case "$host" in
    localhost|127.0.0.1|::1) ;;
    *)
      warn "Elasticsearch is configured with xpack.security disabled on host '${host}'."
      warn "Do not expose port 9200 to untrusted networks; put it behind a firewall or enable X-Pack security/TLS."
      ;;
  esac

  apt_install elasticsearch
  ensure_log_dirs

  # Elasticsearch's bootstrap check needs a large vm.max_map_count.  Always
  # rewrite the managed file: an older/lower value must not survive a reboot.
  printf 'vm.max_map_count = 1048576\n' > /etc/sysctl.d/99-elasticsearch.conf
  chmod 644 /etc/sysctl.d/99-elasticsearch.conf
  sysctl -w vm.max_map_count=1048576 >/dev/null || warn "Could not set vm.max_map_count"

  local yml=/etc/elasticsearch/elasticsearch.yml es_url
  [[ -f $yml ]] || die "Elasticsearch config ${yml} not found"
  if [[ $host == *:* ]]; then
    es_url="http://[${host}]:9200"
  else
    es_url="http://${host}:9200"
  fi

  # Drop previous managed blocks, including the one written by
  # `setup.sh --optimize`; otherwise a reinstall leaves duplicate keys and
  # Elasticsearch refuses to start.
  elasticsearch_strip_managed "$yml" 1

  # Comment out base keys that we are about to set (keeps YAML free of
  # duplicates).  Performance keys are handled by the shared block helper.
  elasticsearch_comment_keys "$yml" \
    cluster.name network.host http.host transport.host http.port \
    path.logs path.data discovery.type \
    xpack.security.enabled xpack.security.enrollment.enabled \
    cluster.initial_master_nodes

  cat >> "$yml" <<EOF
${ES_BEGIN}
cluster.name: essearch
network.host: "${host}"
http.port: 9200
path.data: /var/lib/elasticsearch
path.logs: ${LOG_ROOT}/elasticsearch
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
#cluster.initial_master_nodes: [""]
${ES_END}
EOF
  elasticsearch_write_performance_block "$yml"

  elasticsearch_write_systemd_limits

  mkdir -p /etc/elasticsearch/jvm.options.d
  write_es_jvm_options "$ram_mb"

  mkdir -p /etc/elasticsearch/scripts
  cat > /etc/elasticsearch/scripts/xf-date-weighted.groovy <<'EOF'
_score / pow(2.0F, min(10.0F * halflife, abs(now - doc['date'].value)) / halflife)
EOF
  chmod 644 /etc/elasticsearch/scripts/xf-date-weighted.groovy
  chown root:elasticsearch /etc/elasticsearch/scripts/xf-date-weighted.groovy 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable elasticsearch.service
  systemctl restart elasticsearch.service

  local i
  for i in {1..180}; do
    if curl -fsS "$es_url" >/dev/null 2>&1; then
      break
    fi
    if (( i >= 180 )); then
      break
    fi
    sleep 1
  done

  if ! curl -fsS "$es_url" >/dev/null 2>&1; then
    journalctl -u elasticsearch -n 80 --no-pager || true
    die "Elasticsearch did not become ready on ${host}:9200"
  fi

  curl -fsS "$es_url" || true
  echo
  ok "Elasticsearch installed and running"
}

# ---------------------------------------------------------------------------
# Others
# ---------------------------------------------------------------------------
install_others() {
  step "Other packages"
  local item
  for item in "${OTHERS[@]}"; do
    case "$item" in
      smartmon)
        info "Installing smartmontools"
        pkg_record_origin smartmontools
        apt_install smartmontools
        # Ubuntu ships the unit as smartmontools.service; smartd.service is
        # only an alias on some releases.  Try both before reporting a real
        # failure (a host with no SMART-capable disk still has a valid unit).
        if systemctl enable --now smartmontools 2>/dev/null; then
          :
        elif systemctl enable --now smartd 2>/dev/null; then
          :
        else
          warn "smartmontools could not be enabled (no SMART-capable devices?)"
        fi
        smartctl --version | head -n 1 || true
        ;;
      nvme)
        local stype=${OPT[basic.server]:-$(detect_server_type)}
        if [[ $stype == dedi ]] && is_nvme_storage; then
          info "Installing nvme-cli (dedicated server with NVMe storage)"
          pkg_record_origin nvme-cli
          apt_install nvme-cli
          nvme version || true
        else
          info "Skipping nvme-cli: requires a dedicated server with NVMe storage (server=${stype})"
        fi
        ;;
      gif)
        info "Installing gifsicle"
        pkg_record_origin gifsicle
        apt_install gifsicle
        gifsicle --version | head -n 1 || true
        ;;
      nodejs)
        info "Installing Node.js from the prepared NodeSource 26.x repository"
        pkg_record_origin nodejs
        apt_install nodejs
        node -v
        ;;
      sysstat)
        info "Installing sysstat (sar/iostat history)"
        pkg_record_origin sysstat
        apt_install sysstat
        if [[ -f /etc/default/sysstat ]]; then
          sed_in_place -E 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
        fi
        systemctl enable --now sysstat-collect.timer sysstat-summary.timer 2>/dev/null \
          || systemctl enable --now sysstat 2>/dev/null \
          || warn "sysstat timers could not be enabled"
        ;;
    esac
  done
  ok "Other packages installed"
}

# ---------------------------------------------------------------------------
# Domains
# ---------------------------------------------------------------------------
create_domains() {
  step "Domains"
  (( ${#DOMAINS[@]} > 0 )) || return 0

  [[ -d /etc/angie/conf.d ]] \
    || die "Angie is not installed (/etc/angie/conf.d missing). Install with --angie first."
  command -v mariadb >/dev/null 2>&1 \
    || die "MariaDB client not found. Install MariaDB with --mariadb first."
  systemctl is-active --quiet mariadb \
    || die "MariaDB is not running. Install/start it with --mariadb first."
  command -v openssl >/dev/null 2>&1 || apt_install openssl
  ensure_log_dirs

  local d db dir conf app certdir src tmp changed=0 pv
  for d in "${DOMAINS[@]}"; do
    app=${DOMAIN_APP[$d]:-blank}
    db=$(domain_to_db "$d")
    dir="/var/www/${d}/public"
    conf="/etc/angie/conf.d/${d}.conf"
    certdir="/etc/angie/ssl/${d}"

    # Imagick is required by Chevereto, but it is not part of the
    # XenForo/WordPress default PHP profile.  Install it only when a
    # Chevereto vhost is explicitly requested (including an existing one).
    if [[ $app == chevereto ]] && ! php -m 2>/dev/null | grep -qix imagick; then
      pv=$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)
      if [[ -n $pv ]]; then
        info "Chevereto requires Imagick; installing php${pv}-imagick (Chevereto only)"
        apt_install "php${pv}-imagick" \
          || warn "Could not install php${pv}-imagick; Chevereto may fail its image checks"
        systemctl restart "php${pv}-fpm" 2>/dev/null || true
      else
        warn "Chevereto requires the PHP Imagick extension, but the PHP version could not be detected"
      fi
    fi

    mkdir -p "$dir" "${LOG_ROOT}/angie"
    chown -R www-data:www-data "/var/www/${d}"
    chmod 755 "/var/www/${d}" "$dir"
    info "Directory: ${dir}"

    if [[ $app != blank ]]; then
      mkdir -p "$certdir"
      chmod 700 "$certdir"
      if [[ ! -s "${certdir}/fullchain.pem" || ! -s "${certdir}/privkey.pem" ]]; then
        info "Generating a self-signed certificate for ${d}"
        openssl req -x509 -nodes -newkey rsa:2048 -days 397 \
          -subj "/CN=${d}" \
          -addext "subjectAltName=DNS:${d},DNS:www.${d}" \
          -keyout "${certdir}/privkey.pem" \
          -out "${certdir}/fullchain.pem" >/dev/null 2>&1 \
          || die "Could not generate a certificate for ${d}"
        chmod 600 "${certdir}/privkey.pem"
        chmod 644 "${certdir}/fullchain.pem"
      fi
    fi

    # Never overwrite an existing non-empty vhost; the operator may have
    # customised it.  Empty placeholder files are upgraded.
    if [[ -e $conf && -s $conf ]]; then
      info "Angie config already exists and is non-empty; keeping ${conf}"
    else
      tmp=$(tmp_file)
      case "$app" in
        blank)
          : > "$tmp"
          ;;
        xf)
          src=/etc/angie/conf.d/templates/sample_xf.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" -e "s|sample\.com|${d}|g" \
            -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
            -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
            -e "s#/var/www/html/${d}/websocket.log#${LOG_ROOT}/angie/${d}-websocket.log#g" \
            "$tmp"
          ;;
        wordpress)
          src=/etc/angie/conf.d/templates/sample_wordpress.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" -e "s|sample\.com|${d}|g" \
            -e "s|include h5bp/hostname_ssl.conf;|include h5bp/tls/ssl_engine.conf;\n    include h5bp/tls/policy_balanced.conf;\n    ssl_certificate     ${certdir}/fullchain.pem;\n    ssl_certificate_key ${certdir}/privkey.pem;|g" \
            "$tmp"
          ;;
        pingvin)
          src=/etc/angie/conf.d/templates/sample_pingvin.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          mkdir -p "/var/www/${d}/data" "/var/www/${d}/frontend"
          sed_in_place -e "s|domain\.com|${d}|g" -e "s|sample\.com|${d}|g" \
            -e "s#/var/www/pingvin_source#/var/www/${d}#g" \
            -e "s#/var/www/pingvin_data#/var/www/${d}/data#g" \
            -e '/set_real_ip_from 1\.2\.3\.4;/d' \
            -e '/real_ip_header X-Forwarded-For;/d' \
            -e '/real_ip_recursive on;/d' \
            -e '/realip_remote_addr/d' \
            -e "s|include h5bp/hostname_ssl.conf;|include h5bp/tls/ssl_engine.conf;\n    include h5bp/tls/policy_balanced.conf;\n    ssl_certificate     ${certdir}/fullchain.pem;\n    ssl_certificate_key ${certdir}/privkey.pem;|g" \
            "$tmp"
          ;;
        chevereto)
          src=/etc/angie/conf.d/templates/sample_chev.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" -e "s|sample\.com|${d}|g" \
            -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
            -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
            "$tmp"
          ;;
        polr)
          src=/etc/angie/conf.d/templates/sample_polr.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" -e "s|sample\.com|${d}|g" \
            -e "s|include h5bp/hostname_ssl.conf;|include h5bp/tls/ssl_engine.conf;\n    include h5bp/tls/policy_balanced.conf;\n    ssl_certificate     ${certdir}/fullchain.pem;\n    ssl_certificate_key ${certdir}/privkey.pem;|g" \
            "$tmp"
          ;;
        php|lychee)
          src=/etc/angie/conf.d/templates/sample_php.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" \
            -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
            -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
            "$tmp"
          ;;
        node)
          src=/etc/angie/conf.d/templates/sample_node.conf
          [[ -f $src ]] || die "Missing Angie template ${src}"
          cp "$src" "$tmp"
          sed_in_place -e "s|domain\.com|${d}|g" \
            -e "s#/etc/letsencrypt/live/${d}/fullchain.pem#${certdir}/fullchain.pem#g" \
            -e "s#/etc/letsencrypt/live/${d}/privkey.pem#${certdir}/privkey.pem#g" \
            "$tmp"
          ;;
        *)
          die "Internal error: unhandled app '${app}' for ${d}"
          ;;
      esac

      install -m 644 "$tmp" "$conf"
      local domain_test_log
      domain_test_log=$(tmp_file)
      if ! /usr/sbin/angie -t >"$domain_test_log" 2>&1; then
        cat "$domain_test_log" >&2 || true
        # Keep the rejected file out of the live config without deleting it.
        local rejected
        rejected=$(preserve_to_tmp "$conf" || true)
        [[ -n $rejected ]] && warn "Moved rejected vhost to ${rejected}"
        die "Angie rejected the generated vhost for ${d} (app=${app})"
      fi
      # "angie -t" runs from this shell (umask 022) and creates the per-vhost
      # log files before systemd's UMask=0027 applies. Normalise them now.
      find "${LOG_ROOT}/angie" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
      changed=1
      info "Created Angie vhost: ${conf} (app=${app})"
    fi

    mariadb -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    if ! mariadb -N -B -e "SHOW DATABASES LIKE '${db}'" | grep -qx "$db"; then
      die "Failed to create MariaDB database '${db}' for ${d}"
    fi
    info "Database: ${db}"
  done

  if (( changed )); then
    systemctl reload angie 2>/dev/null || systemctl restart angie 2>/dev/null \
      || warn "Could not reload Angie after creating vhosts"
  fi
  ok "Domain setup complete"
}

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
    local line is_ssh
    local -a rule
    while IFS= read -r line; do
      [[ $line == ufw\ * ]] || continue
      # Never remove an SSH rule during purge.  If the provider image had no
      # SSH allow rule and UFW is active, removing ours is a guaranteed
      # lockout for a remote operator.
      is_ssh=0
      for p in "${ssh_ports[@]}"; do
        if [[ $line =~ (^|[[:space:]])${p}(/tcp)?([[:space:]]|$) ]]; then
          is_ssh=1
          break
        fi
      done
      if (( is_ssh )); then
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
    local line is_ssh ssh_p
    local -a rule
    while IFS= read -r line; do
      [[ $line == ufw\ allow* ]] || continue
      is_ssh=0 ssh_p=""
      for p in "${ssh_ports[@]}"; do
        if [[ $line =~ (^|[[:space:]])${p}(/tcp)?([[:space:]]|$) ]]; then
          is_ssh=1
          ssh_p=$p
          break
        fi
      done
      (( is_ssh )) || continue
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

  restore_original /etc/security/limits.conf limits.conf
  restore_original /etc/security/limits.d/99-setup.conf limits.d-99-setup.conf
  restore_original /etc/sysctl.conf sysctl.conf
  restore_original /etc/sysctl.d/99-sysctl.conf sysctl.d-99-sysctl.conf
  restore_original /etc/sysctl.d/90-setup-network.conf sysctl.d-90-setup-network.conf
  restore_original /etc/modules-load.d/setup-network.conf modules-load-setup-network.conf
  restore_original /etc/logrotate.d/setup-logs logrotate-setup-logs
  # Disable the oneshot before moving its unit file out of the live location.
  systemctl disable --now setup-network-tuning.service 2>/dev/null || true
  restore_original /etc/systemd/system/setup-network-tuning.service setup-network-tuning.service
  systemctl daemon-reload || true
  restore_original /etc/systemd/resolved.conf.d/dns_servers.conf dns_servers.conf
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
  restore_original /etc/hosts hosts
  if [[ -f "${STATE_DIR}/original-timezone" ]]; then
    local orig_tz
    orig_tz=$(<"${STATE_DIR}/original-timezone")
    if [[ -n $orig_tz ]]; then timedatectl set-timezone "$orig_tz" || true; fi
  fi

  if [[ -f "${STATE_DIR}/cpufrequtils-installed" ]]; then
    cpufreq-set -g powersave 2>/dev/null || true
    apt_purge_pkgs cpufrequtils
    info "Leaving /etc/default/cpufrequtils in place"
  else
    restore_original /etc/default/cpufrequtils cpufrequtils-default
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
  cron_remove_line '/usr/bin/find /var/www' || true
  cron_remove_line "$CRON_WWW_CHOWN_LEGACY" || true
  cron_remove_line "$CRON_WWW_CHOWN" || true
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
  systemctl disable --now phpsessionclean.timer 2>/dev/null || true
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
  # No package, repository, keyring or Composer file is removed.  Operators can
  # remove anything they no longer want once they are sure it is unused.
  info "Leaving optional packages, repositories, keyrings and Composer in place"
  ok "Other packages left installed"
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
          "${OPT[valkey.ram]:-auto (10% of RAM)}" \
          "${OPT[valkey.policy]:-allkeys-lru}" \
          "${OPT[valkey.io_threads]:-1}"
        ;;
      elastic)
        printf '  %-10s host=%s ram=%s\n' "$s" \
          "${OPT[elastic.host]:-localhost}" "${OPT[elastic.ram]:-auto (25% of RAM)}"
        ;;
      others)
        printf '  %-10s %s\n' "$s" "${OTHERS[*]:-}"
        ;;
      domain)
        for dd in "${DOMAINS[@]}"; do
          printf '  %-10s %s app=%s\n' "$s" "$dd" "${DOMAIN_APP[$dd]:-blank}"
        done
        ;;
      *)
        printf '  %-10s install\n' "$s"
        ;;
    esac
  done
}

# =============================================================================
# --optimize: scan installed services and tune their live configuration
# =============================================================================
OPT_BACKUP_DIR=""
OPT_REPORT=()
OPT_DETECTED=()
OPT_START_TS=""
OPT_REPORT_STARTED=0
OPT_REPORT_WRITTEN=0
# Set when any service actually reloaded/restarted during this run.  Cache
# objects written during a cutover window are only counted and reported; they
# are never deleted, and an idempotent run does not touch the live cache.
OPT_CUTOVER=0
# Web frontends paused while MariaDB restarts.  Stopping Angie and PHP-FPM
# first prevents a thundering herd of reconnects while InnoDB preloads a new
# buffer pool.
OPT_WEB_PAUSED_ANGIE=0
OPT_WEB_PAUSED_PHP=()

opt_report() { OPT_REPORT+=("$*"); }

opt_backup() {
  local path=$1 name=$2
  [[ -n $OPT_BACKUP_DIR ]] || OPT_BACKUP_DIR=$(tmp_dir setup-optimize.XXXXXX)
  [[ -n $OPT_BACKUP_DIR ]] || die "Could not create an optimize backup directory"
  # Copies include /etc/angie/ssl/*/privkey.pem and /etc/mysql/debian.cnf.
  # 0700 keeps the rollback tree (and its filenames) private to root.
  install -d -m 700 "$OPT_BACKUP_DIR"
  [[ -e "$OPT_BACKUP_DIR/${name}" || -e "$OPT_BACKUP_DIR/${name}.absent" ]] && return 0
  if [[ -e $path ]]; then
    cp -a "$path" "$OPT_BACKUP_DIR/${name}"
    opt_report "Backup: \`${path}\` -> \`${OPT_BACKUP_DIR}/${name}\`"
  else
    : > "$OPT_BACKUP_DIR/${name}.absent"
  fi
}

opt_restore() {
  local path=$1 name=$2
  local src="${OPT_BACKUP_DIR}/${name}" moved
  [[ -n $OPT_BACKUP_DIR ]] || return 1
  if [[ -e $src ]]; then
    # Overwrite in place; never unlink the live path before restoring it.
    if [[ -d $src ]]; then
      mkdir -p "$path"
      cp -a "${src}/." "$path/"
    else
      cp -a "$src" "$path"
    fi
    opt_report "ROLLBACK: restored \`${path}\` from backup"
  elif [[ -e "${OPT_BACKUP_DIR}/${name}.absent" ]]; then
    # The file did not exist before tuning.  Move the generated file to /tmp
    # instead of deleting it, so the original state is restored without loss.
    moved=$(preserve_to_tmp "$path") || return 1
    [[ -n $moved ]] && opt_report "ROLLBACK: moved \`${path}\` to \`${moved}\` (not deleted)"
  fi
}

detect_installed_services() {
  OPT_DETECTED=()
  [[ -x /usr/sbin/angie && -f /etc/angie/angie.conf ]] && OPT_DETECTED+=(angie)
  local ver
  # A stale /etc/php/<ver>/fpm directory survives a purge on some hosts.  Only
  # treat a version as installed when it still has a pool config; otherwise
  # --optimize would create systemd drop-ins for a service that does not exist.
  while IFS= read -r ver; do
    OPT_DETECTED+=("php:${ver}")
  done < <(php_fpm_versions)
  if command -v mariadbd >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    [[ -d /etc/mysql ]] && OPT_DETECTED+=(mariadb)
  fi
  [[ -f /etc/valkey/valkey.conf ]] && OPT_DETECTED+=(valkey)
  # Valkey takes precedence.  Tuning both would apply the same shared cache
  # budget twice and could overcommit RAM; Redis-only hosts still get the
  # complete Valkey tuning profile.
  if [[ ! -f /etc/valkey/valkey.conf && -f /etc/redis/redis.conf ]]; then
    OPT_DETECTED+=(redis)
  fi
  [[ -f /etc/elasticsearch/elasticsearch.yml ]] && OPT_DETECTED+=(elastic)
  return 0
}

# ---------------------------------------------------------------------------
# Shared memory budget
# ---------------------------------------------------------------------------
# Each service used to choose its own slice of RAM (MariaDB 40%, PHP workers
# 50%, Valkey 10%, Elasticsearch 25%).  With three or four services installed
# that adds up to 100-125% before the kernel, Angie and page cache get a byte,
# so the first traffic spike ends in the OOM killer.  Allocate once, from a
# single budget, and leave 20% of RAM for the OS and the web server.
OPT_MEM_TOTAL_MB=0
OPT_DB_SIZE_MB=0
OPT_ES_SIZE_MB=0
OPT_MEM_BUDGET_MB=0
OPT_PHP_BUDGET_MB=0
OPT_MARIADB_BUDGET_MB=0
OPT_MARIADB_KEPT_MB=0
OPT_VALKEY_BUDGET_MB=0
OPT_ES_BUDGET_MB=0
OPT_ES_KEPT_MB=0

mem_total_mb() {
  awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '1024'
}

# Data + index bytes for user schemas as whole MB.  The InnoDB buffer pool
# should be able to hold this working set when the RAM budget permits.
mariadb_data_size_mb() {
  local bytes
  command -v mariadb >/dev/null 2>&1 || return 0
  bytes=$(mariadb -N -B -e "
    SELECT COALESCE(SUM(data_length + index_length), 0)
    FROM information_schema.tables
    WHERE table_schema NOT IN
      ('mysql','information_schema','performance_schema','sys');" 2>/dev/null || true)
  [[ $bytes =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( bytes / 1024 / 1024 ))
}

# The live buffer pool, in MB.  Used to avoid shrinking a pool an operator
# already sized for this host.
mariadb_current_pool_mb() {
  local bytes
  command -v mariadb >/dev/null 2>&1 || return 0
  bytes=$(mariadb -N -B -e 'SELECT @@innodb_buffer_pool_size' 2>/dev/null || true)
  [[ $bytes =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( bytes / 1024 / 1024 ))
}

# Elasticsearch may intentionally listen on a non-loopback address (for
# example an IPv4 address used by a XenForo instance on another host).
# Resolve the endpoint the node is configured to use instead of assuming
# 127.0.0.1:9200.  http.host wins over network.host, matching Elasticsearch.
elasticsearch_http_url() {
  local yml=${1:-/etc/elasticsearch/elasticsearch.yml}
  local raw host="" port=""

  if [[ -r $yml ]]; then
    raw=$(sed -nE 's/^[[:space:]]*http\.host[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null | head -n1)
    host=$(printf '%s' "$raw" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
    host=$(printf '%s' "$host" | sed -E "s/^['\"]//; s/['\"]$//")
    host=${host%%,*}
    if [[ -z $host ]]; then
      raw=$(sed -nE 's/^[[:space:]]*network\.host[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null | head -n1)
      host=$(printf '%s' "$raw" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
      host=$(printf '%s' "$host" | sed -E "s/^['\"]//; s/['\"]$//")
      host=${host%%,*}
    fi
    raw=$(sed -nE 's/^[[:space:]]*http\.port[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null | head -n1)
    port=$(printf '%s' "$raw" | tr -dc '0-9')
  fi

  if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    port=9200
  fi

  case $host in
    ""|0.0.0.0|localhost|127.0.0.1) host=127.0.0.1 ;;
    "::"|"[::]"|"::1"|"[::1]") host="[::1]" ;;
    _local_) host=127.0.0.1 ;;
    _site_|_global_)
      host=$(detect_local_ipv4 2>/dev/null || true)
      [[ -n $host ]] || host=127.0.0.1
      ;;
  esac

  host=${host#\[}
  host=${host%\]}
  [[ $host == *:* ]] && host="[${host}]"
  printf 'http://%s:%s' "$host" "$port"
}

# True when the exact HTTP endpoint appears in the kernel listener table.
# Used as a fallback when a firewall or NAT prevents the host from probing
# its own non-loopback address, so a healthy restart is not rolled back.
elasticsearch_listener_on() {
  local url=$1 hostport port
  hostport=${url#*://}
  port=${hostport##*:}
  command -v ss >/dev/null 2>&1 || return 0
  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qxF -- "$hostport"; then
    return 0
  fi
  # A wildcard bind is reachable on every local address, including a specific
  # non-loopback address; ss prints it as 0.0.0.0, [::] or *.
  ss -H -ltn 2>/dev/null | awk '{print $4}' \
    | grep -qE "^(0\\.0\\.0\\.0|\\[::\\]|\\*):${port}$"
}

# Allocated index store size (primary + replicas) in whole MB.
elasticsearch_data_size_mb() {
  local bytes resp url
  command -v curl >/dev/null 2>&1 || return 0
  for url in "$(elasticsearch_http_url)" "http://127.0.0.1:9200"; do
    resp=$(curl -fsS --max-time 3 \
      "${url}/_cluster/stats?filter_path=indices.store.size_in_bytes" \
      2>/dev/null || true)
    [[ -n $resp ]] && break
  done
  [[ -n $resp ]] || return 0
  bytes=$(printf '%s\n' "$resp" \
    | sed -n 's/.*"size_in_bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | head -n1 || true)
  [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
  printf '%s' $(( bytes / 1024 / 1024 ))
}

# Current JVM heap in MB.  Prefer the live node stats, then the -Xmx value
# from jvm.options.d, so an operator-sized heap is not shrunk.
elasticsearch_current_heap_mb() {
  local bytes val file mb url
  if command -v curl >/dev/null 2>&1; then
    for url in "$(elasticsearch_http_url)" "http://127.0.0.1:9200"; do
      bytes=$(curl -fsS --max-time 3 \
        "${url}/_nodes/stats/jvm?filter_path=nodes.*.jvm.mem.heap_max_in_bytes" \
        2>/dev/null \
        | sed -n 's/.*"heap_max_in_bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        | sort -n | tail -n1 || true)
      if [[ $bytes =~ ^[0-9]+$ ]]; then
        printf '%s' $(( bytes / 1024 / 1024 ))
        return 0
      fi
    done
  fi
  for file in /etc/elasticsearch/jvm.options /etc/elasticsearch/jvm.options.d/*.options; do
    [[ -f $file ]] || continue
    val=$(sed -n 's/^-Xmx\([0-9][0-9]*[kKmMgG]\)$/\1/p' "$file" | tail -n1)
    [[ -n $val ]] || continue
    case ${val: -1} in
      k|K) mb=$(( ${val%?} / 1024 )) ;;
      m|M) mb=${val%?} ;;
      g|G) mb=$(( ${val%?} * 1024 )) ;;
      *) continue ;;
    esac
    printf '%s' "$mb"
    return 0
  done
}

plan_memory_budget() {
  local total usable has_php=0 has_angie=0 has_maria=0 has_cache=0 has_es=0
  local fixed_available children php_cap
  local es_base_cap=31744 es_hard_cap=31744 es_size_mb=0 es_base=0 es_measured=0
  local es_cap=0 current_heap=0 current_pool=0 db_measured=0
  total=$(mem_total_mb)
  (( total > 0 )) || total=1024
  OPT_MEM_TOTAL_MB=$total
  usable=$(( total * 80 / 100 ))
  OPT_MEM_BUDGET_MB=$usable
  OPT_PHP_BUDGET_MB=0
  OPT_MARIADB_BUDGET_MB=0
  OPT_MARIADB_KEPT_MB=0
  OPT_VALKEY_BUDGET_MB=0
  OPT_ES_BUDGET_MB=0
  OPT_ES_KEPT_MB=0

  [[ " ${OPT_DETECTED[*]} " == *" php:"* ]] && has_php=1
  [[ " ${OPT_DETECTED[*]} " == *" angie "* ]] && has_angie=1
  [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]] && has_maria=1
  [[ " ${OPT_DETECTED[*]} " == *" valkey "* || " ${OPT_DETECTED[*]} " == *" redis "* ]] && has_cache=1
  [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]] && has_es=1

  # Reserve PHP workers before sizing the data services.  PHP is the
  # request-serving tier: starving it to give Elasticsearch a larger heap
  # turns a memory win into a throughput regression.  Use the pool's current
  # max_children when available, with a 96 MB/worker allowance (the same
  # divisor tune_php_fpm_version uses), capped at 50% of RAM.
  if (( has_php )); then
    children=$(php_pool_max_children)
    (( children > 0 )) || children=$(( $(nproc) * 16 ))
    # tune_php_fpm_version() never goes below 8 workers; use the same floor
    # here so a first run and a second run calculate the same PHP budget.
    (( children < 8 )) && children=8
    OPT_PHP_BUDGET_MB=$(( children * 96 ))
    (( OPT_PHP_BUDGET_MB < 512 )) && OPT_PHP_BUDGET_MB=512
    php_cap=$(( total * 50 / 100 ))
    (( OPT_PHP_BUDGET_MB > php_cap )) && OPT_PHP_BUDGET_MB=$php_cap
    fixed_available=$(( usable - OPT_PHP_BUDGET_MB ))
    (( fixed_available < 0 )) && fixed_available=0
  else
    fixed_available=$usable
  fi

  if (( has_cache )); then
    local cache_pct=10 cache_cap=8192
    if (( !has_maria && !has_es )); then
      if (( has_angie || has_php )); then
        # Web/cache-only host: give the in-memory cache a larger share.
        cache_pct=25
        cache_cap=32768
      else
        # Cache-only host.
        cache_pct=50
        cache_cap=65536
      fi
    fi
    OPT_VALKEY_BUDGET_MB=$(tune_clamp $(( total * cache_pct / 100 )) 256 "$cache_cap")
  fi

  # The heap follows the live index store (+5%) up to the 31 GB
  # compressed-oops ceiling; 25%-of-RAM (8 GB on shared hosts) is used only
  # when the store size cannot be measured.  The shared budget caps it below
  # so the other services keep their memory.
  if [[ " ${OPT_DETECTED[*]} " == *" php:"* || " ${OPT_DETECTED[*]} " == *" mariadb "* ]]; then
    es_base_cap=8192
  fi
  es_hard_cap=31744
  OPT_ES_SIZE_MB=0
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]]; then
    es_size_mb=$(elasticsearch_data_size_mb)
    if [[ -n $es_size_mb ]]; then
      es_measured=1
    else
      es_size_mb=0
    fi
    OPT_ES_SIZE_MB=$es_size_mb
    if (( es_measured )); then
      # A measured empty index is not a missing measurement: give the JVM the
      # 512 MB floor, not 25% of RAM.
      if (( es_size_mb > 0 )); then
        es_base=$(( es_size_mb * 105 / 100 ))
      else
        es_base=512
      fi
    else
      local es_fallback_pct=25
      if (( !has_angie && !has_php && !has_maria && !has_cache )); then
        es_fallback_pct=50
      fi
      es_base=$(tune_clamp $(( total * es_fallback_pct / 100 )) 512 "$es_base_cap")
    fi
    (( es_base < 512 )) && es_base=512
    (( es_base > es_hard_cap )) && es_base=$es_hard_cap
    es_base=$(( (es_base + 511) / 512 * 512 ))
    OPT_ES_BUDGET_MB=$es_base
  fi
  local db_size_mb=0 db_cap=0 remaining=0 others=0
  OPT_DB_SIZE_MB=0
  if [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]]; then
    # Prefer a buffer pool that holds the live data+index working set.  The
    # 5% headroom covers InnoDB metadata and adaptive hash structures.
    db_size_mb=$(mariadb_data_size_mb)
    if [[ -n $db_size_mb ]]; then
      db_measured=1
    else
      db_size_mb=0
    fi
    OPT_DB_SIZE_MB=$db_size_mb

    # Reserve the full cache and search budgets before sizing MariaDB, so a
    # large database cannot crowd them out.
    db_cap=$(( fixed_available - OPT_VALKEY_BUDGET_MB - OPT_ES_BUDGET_MB ))
    (( db_cap < 256 )) && db_cap=256

    # Size to the live working set plus 5% headroom.  Fall back to 40% of
    # RAM only when the data size cannot be measured (for example a stopped
    # server).  Keep a hardware-scaled floor as well: a freshly installed
    # database can be only a few MB, but collapsing a 128 GB host to a 256 MB
    # buffer pool makes the next traffic spike hit disk for every page.  The
    # floor is 1/16 of RAM, capped at 8 GB, so small hosts stay conservative.
    local db_floor
    db_floor=$(( total / 16 ))
    (( db_floor > 8192 )) && db_floor=8192
    (( db_floor < 256 )) && db_floor=256
    (( db_floor > db_cap )) && db_floor=$db_cap
    if (( db_measured )); then
      if (( db_size_mb > 0 )); then
        OPT_MARIADB_BUDGET_MB=$(( db_size_mb * 105 / 100 ))
      else
        # A measured empty database keeps the hardware-scaled floor.
        OPT_MARIADB_BUDGET_MB=$db_floor
      fi
      (( OPT_MARIADB_BUDGET_MB < db_floor )) && OPT_MARIADB_BUDGET_MB=$db_floor
    else
      local db_fallback_pct=40
      if (( !has_php && !has_cache && !has_es )); then
        db_fallback_pct=80
      fi
      OPT_MARIADB_BUDGET_MB=$(tune_clamp $(( total * db_fallback_pct / 100 )) 256 "$db_cap")
    fi
    (( OPT_MARIADB_BUDGET_MB < 256 )) && OPT_MARIADB_BUDGET_MB=256
    (( OPT_MARIADB_BUDGET_MB > db_cap )) && OPT_MARIADB_BUDGET_MB=$db_cap

    # Keep a live pool within 2% of the target so small statistics drift does
    # not cause a restart on every run.  Larger pools are reduced to the
    # data-sized target.
    current_pool=$(mariadb_current_pool_mb)
    if [[ $current_pool =~ ^[0-9]+$ ]] && (( current_pool > 0 && current_pool <= db_cap )); then
      if (( current_pool * 100 >= OPT_MARIADB_BUDGET_MB * 98 \
            && current_pool * 100 <= OPT_MARIADB_BUDGET_MB * 102 )); then
        OPT_MARIADB_BUDGET_MB=$current_pool
        OPT_MARIADB_KEPT_MB=$current_pool
      fi
    fi
  fi

  # Elasticsearch gets what remains after MariaDB and the cache tier, so a
  # larger heap cannot crowd the database out.  Keep a live heap within 2%
  # of the target (or larger, if it still fits) to avoid restart churn.
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]]; then
    es_cap=$(( fixed_available - OPT_MARIADB_BUDGET_MB - OPT_VALKEY_BUDGET_MB ))
    (( es_cap < 512 )) && es_cap=512
    (( OPT_ES_BUDGET_MB > es_cap )) && OPT_ES_BUDGET_MB=$es_cap
    current_heap=$(elasticsearch_current_heap_mb)
    if [[ $current_heap =~ ^[0-9]+$ ]] && (( current_heap > 0 && current_heap <= es_cap )); then
      if (( current_heap * 100 >= OPT_ES_BUDGET_MB * 98 \
            && current_heap * 100 <= OPT_ES_BUDGET_MB * 102 )); then
        OPT_ES_BUDGET_MB=$current_heap
        OPT_ES_KEPT_MB=$current_heap
      fi
    fi
  fi

  # Scale the remaining data services into what MariaDB did not consume.
  remaining=$(( fixed_available - OPT_MARIADB_BUDGET_MB ))
  (( remaining < 0 )) && remaining=0
  others=$(( OPT_ES_BUDGET_MB + OPT_VALKEY_BUDGET_MB ))
  if (( others > remaining )); then
    if (( others > 0 )); then
      OPT_ES_BUDGET_MB=$(( OPT_ES_BUDGET_MB * remaining / others ))
      OPT_VALKEY_BUDGET_MB=$(( OPT_VALKEY_BUDGET_MB * remaining / others ))
    fi
  fi
  # Proportional scaling must not hand a small host an unusable slice (a
  # 1 GB host used to end up with a 17 MB cache).  Apply the same floors the
  # per-service tuners use; the small overcommit is bounded and safer than a
  # cache that evicts everything immediately.
  if (( has_cache )); then
    (( OPT_VALKEY_BUDGET_MB < 256 )) && OPT_VALKEY_BUDGET_MB=256
  fi
  if (( has_es )); then
    (( OPT_ES_BUDGET_MB < 512 )) && OPT_ES_BUDGET_MB=512
  fi
  return 0
}

# Build the same shared memory plan for a fresh install that --optimize builds
# for an existing host.  Services that are about to be installed are treated as
# present so PHP/MariaDB/Valkey/Elasticsearch are sized against one budget from
# the first write instead of each claiming its own percentage of RAM.
plan_install_budget() {
  OPT_DETECTED=()
  [[ ${ENABLED[angie]:-0} -eq 1 ]]   && OPT_DETECTED+=(angie)
  [[ ${ENABLED[php]:-0} -eq 1 ]]     && OPT_DETECTED+=("php:${OPT[php.ver]:-auto}")
  [[ ${ENABLED[mariadb]:-0} -eq 1 ]] && OPT_DETECTED+=(mariadb)
  [[ ${ENABLED[valkey]:-0} -eq 1 ]]  && OPT_DETECTED+=(valkey)
  [[ ${ENABLED[elastic]:-0} -eq 1 ]] && OPT_DETECTED+=(elastic)
  plan_memory_budget
  info "Memory plan: ${OPT_MEM_BUDGET_MB}MB usable of ${OPT_MEM_TOTAL_MB}MB (PHP=${OPT_PHP_BUDGET_MB}MB MariaDB=${OPT_MARIADB_BUDGET_MB}MB Cache=${OPT_VALKEY_BUDGET_MB}MB Elasticsearch=${OPT_ES_BUDGET_MB}MB)"
}

php_fpm_versions() {
  local d ver
  for d in /etc/php/*/fpm; do
    [[ -d $d ]] || continue
    ver=$(basename "$(dirname "$d")")
    [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || continue
    # Require a real pool and the matching binary.  A leftover directory with
    # no pool (common after `--purge --php ver=X`) is not an installed service.
    compgen -G "${d}/pool.d/*.conf" >/dev/null 2>&1 || continue
    [[ -x "/usr/sbin/php-fpm${ver}" ]] || command -v "php-fpm${ver}" >/dev/null 2>&1 || continue
    printf '%s\n' "$ver"
  done | sort -V
}

php_pool_listen() {
  local ver=$1 pool="/etc/php/${1}/fpm/pool.d/www.conf"
  [[ -f $pool ]] || return 0
  awk -F= '/^[[:space:]]*listen[[:space:]]*=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}' "$pool"
}

php_pool_max_children() {
  local ver pool cur max=0
  while IFS= read -r ver; do
    pool="/etc/php/${ver}/fpm/pool.d/www.conf"
    [[ -f $pool ]] || continue
    cur=$(awk -F= '/^[[:space:]]*pm\.max_children[[:space:]]*=/{v=$2; gsub(/[^0-9]/,"",v); print v; exit}' "$pool")
    [[ $cur =~ ^[0-9]+$ ]] || continue
    (( cur > max )) && max=$cur
  done < <(php_fpm_versions)
  printf '%s' "$max"
}

php_primary_version() {
  local ver listen angie_socket=""
  # Prefer the pool that already owns the socket Angie talks to.
  if [[ -f /etc/angie/angie.conf ]]; then
    angie_socket=$(awk '/^[[:space:]]*server[[:space:]]+unix:/{
        sub(/^[[:space:]]*server[[:space:]]+unix:/, ""); sub(/;.*/, ""); print; exit
      }' /etc/angie/angie.conf)
  fi
  while IFS= read -r ver; do
    listen=$(php_pool_listen "$ver")
    if [[ -n $angie_socket && $listen == "$angie_socket" ]]; then
      printf '%s' "$ver"; return 0
    fi
    if [[ $listen == /run/php/php-fpm.sock ]]; then
      printf '%s' "$ver"; return 0
    fi
  done < <(php_fpm_versions)

  # Otherwise use the newest active version (not the oldest, which is what a
  # plain ascending scan used to select when several were installed).
  local newest=""
  while IFS= read -r ver; do
    systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && newest=$ver
  done < <(php_fpm_versions)
  [[ -n $newest ]] && { printf '%s' "$newest"; return 0; }
  php_fpm_versions | tail -n1
}

# WordPress guest-cache support: the Angie repository owns the templates.
angie_wordpress_vhosts() {
  local target=$1 file root
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*include[[:space:]]+h5bp/(php_wp|wordpress)\.conf;' "$file" || continue
    root=$(grep -m1 -E '^[[:space:]]*root[[:space:]]+' "$file" 2>/dev/null \
      | sed -E 's/^[[:space:]]*root[[:space:]]+//; s/;.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
    root=${root%\"}; root=${root#\"}
    [[ -n $root && -f "${root%/}/wp-config.php" ]] && printf '%s\n' "$file"
  done
}

# Download the cache templates from the Angie config repository.  Kept
# separate from the installer fetch path so a failed download is a reported
# miss instead of aborting --optimize.
wordpress_cache_templates() {
  local base=${CONFIG_REPO_URL%.git} repo raw temp file
  case "$base" in
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  repo=${base#https://github.com/}
  raw="https://raw.githubusercontent.com/${repo}/${CONFIG_REPO_REF}"
  command -v curl >/dev/null 2>&1 || return 1
  temp=$(tmp_dir) || return 1
  for file in h5bp/wordpress_cache.conf \
              http.d/wordpress_cache_map.conf \
              http.d/fastcgi_cache.conf; do
    mkdir -p "${temp}/$(dirname "$file")"
    if ! retry 3 2 curl -fsSL --proto '=https' --tlsv1.2 \
         "${raw}/${file}" -o "${temp}/${file}" 2>/dev/null; then
      # Leave the partial download in /tmp; it expires on its own.
      return 1
    fi
  done
  printf '%s' "$temp"
}

optimize_wordpress_cache() {
  local target=${1:-/etc/angie}
  local -a wp_vhosts=()
  mapfile -t wp_vhosts < <(angie_wordpress_vhosts "$target")
  (( ${#wp_vhosts[@]} > 0 )) || return 0

  local -a wp_active=()
  mapfile -t wp_active < <(angie_active_http_files "$target")
  if (( ${#wp_active[@]} == 0 )); then
    tune_miss "WordPress cache: no active http.d include pattern"
    return 0
  fi

  local has_php_wp=0
  [[ -f "${target}/h5bp/php_wp.conf" ]] && has_php_wp=1
  if (( has_php_wp == 0 )) \
     && ! grep -qRE 'include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/conf.d" 2>/dev/null; then
    tune_miss "WordPress cache: no h5bp/php_wp.conf or server-level cache include"
    return 0
  fi

  local suffix=".conf" file active_zone=0 active_map=0
  for file in "${wp_active[@]}"; do
    case "$file" in *_conf) suffix="_conf"; break ;; esac
  done
  for file in "${wp_active[@]}"; do
    grep -qE 'fastcgi_cache_path.*keys_zone=fastcgicache:' "$file" && active_zone=1
    grep -qE 'map[[:space:]].*\$skip_cache' "$file" && active_map=1
  done

  local include_ready=0
  if (( has_php_wp )) \
     && grep -qE 'include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/h5bp/php_wp.conf"; then
    include_ready=1
  elif grep -qRE 'include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/conf.d" 2>/dev/null; then
    include_ready=1
  fi

  if (( active_zone && active_map && include_ready )) \
     && [[ -f "${target}/h5bp/wordpress_cache.conf" ]]; then
    opt_report "- WordPress: FastCGI guest cache already enabled for ${#wp_vhosts[@]} vhost(s)"
    return 0
  fi

  local src="" temp="" changed=0
  if [[ -n ${CONFIG_SOURCE_DIR:-} \
        && -f ${CONFIG_SOURCE_DIR}/h5bp/wordpress_cache.conf \
        && -f ${CONFIG_SOURCE_DIR}/http.d/wordpress_cache_map.conf \
        && -f ${CONFIG_SOURCE_DIR}/http.d/fastcgi_cache.conf ]]; then
    src=$CONFIG_SOURCE_DIR
  else
    temp=$(wordpress_cache_templates) || {
      tune_miss "WordPress cache templates could not be downloaded"
      return 0
    }
    src=$temp
  fi

  local cache_file="${target}/http.d/zz-setup-wordpress-cache${suffix}"
  local map_file="${target}/http.d/zz-setup-wordpress-cache-map${suffix}"
  if (( active_zone == 0 )); then
    install -m 644 "${src}/http.d/fastcgi_cache.conf" "$cache_file"
    changed=1
  fi
  if (( active_map == 0 )); then
    install -m 644 "${src}/http.d/wordpress_cache_map.conf" "$map_file"
    changed=1
  fi
  if ! cmp -s "${src}/h5bp/wordpress_cache.conf" \
       "${target}/h5bp/wordpress_cache.conf" 2>/dev/null; then
    install -m 644 "${src}/h5bp/wordpress_cache.conf" \
      "${target}/h5bp/wordpress_cache.conf"
    changed=1
  fi
  if (( has_php_wp )) \
     && ! grep -qE 'include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/h5bp/php_wp.conf" \
     && ! grep -qRE 'include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/conf.d" 2>/dev/null; then
    printf '\n# BEGIN setup.sh WordPress FastCGI cache\ninclude h5bp/wordpress_cache.conf;\n# END setup.sh WordPress FastCGI cache\n' \
      >> "${target}/h5bp/php_wp.conf"
    changed=1
  fi
  if (( active_zone == 0 )); then
    install -d -m 700 /home/nginx_cache 2>/dev/null || mkdir -p /home/nginx_cache
    chown www-data:www-data /home/nginx_cache 2>/dev/null || true
  fi

  if (( changed )); then
    tune_note "WordPress: FastCGI guest cache enabled for ${#wp_vhosts[@]} vhost(s)"
  else
    opt_report "- WordPress: FastCGI guest cache already enabled for ${#wp_vhosts[@]} vhost(s)"
  fi
  return 0
}

# Match the installer's systemd fd limit on an existing server too.  Only the
# fd limit is checked: Angie daemonises with umask(0), so a UMask= drop-in
# does not change the modes of the files its workers create.  Rewriting an
# unchanged file would force a needless restart, so compare first.
ANGIE_UNIT_CHANGED=0
ensure_angie_limits() {
  local angie_limit angie_dropin=/etc/systemd/system/angie.service.d/limits.conf
  local angie_before="" changed=0
  ANGIE_UNIT_CHANGED=0
  angie_limit=$(systemctl show -p LimitNOFILE --value angie 2>/dev/null || true)
  [[ -f $angie_dropin ]] && angie_before=$(md5sum "$angie_dropin" | awk '{print $1}')
  if [[ $angie_limit != infinity ]] \
     && { ! [[ $angie_limit =~ ^[0-9]+$ ]] || (( angie_limit < 524288 )); }; then
    mkdir -p /etc/systemd/system/angie.service.d
    printf '[Service]\nLimitNOFILE=524288\nUMask=0027\n' > "$angie_dropin"
    chmod 644 "$angie_dropin"
    if [[ $angie_before != "$(md5sum "$angie_dropin" | awk '{print $1}')" ]]; then
      systemctl daemon-reload || true
      changed=1
      ANGIE_UNIT_CHANGED=1
      tune_summary "Angie: systemd LimitNOFILE=524288 (applies on next restart)"
    fi
  fi
  return "$changed"
}

optimize_angie() {
  local active=0 change version
  systemctl is-active --quiet angie 2>/dev/null && active=1
  version=$(/usr/sbin/angie -v 2>&1 | head -n1 || true)
  opt_report "## Angie"
  opt_report "- Version: \`${version:-unknown}\`; active: ${active}"
  opt_backup /etc/angie angie
  tune_reset_changes
  ensure_angie_limits || true
  local unit_changed=$ANGIE_UNIT_CHANGED
  optimize_wordpress_cache /etc/angie || true
  if ! tune_angie_configs /etc/angie; then
    opt_restore /etc/angie angie
    opt_report "- **FAILED** tuning returned an error; configuration rolled back"
    return 1
  fi
  local angie_test_log
  angie_test_log=$(tmp_file)
  if ! /usr/sbin/angie -t >"$angie_test_log" 2>&1; then
    opt_report "- **FAILED** \`angie -t\`:"
    while IFS= read -r change; do opt_report "  \`${change}\`"; done < "$angie_test_log"
    opt_restore /etc/angie angie
    /usr/sbin/angie -t >/dev/null 2>&1 \
      && { systemctl reload angie 2>/dev/null || systemctl restart angie 2>/dev/null; } || true
    return 1
  fi
  for change in "${TUNE_CHANGES[@]}"; do opt_report "- ${change}"; done
  for change in "${TUNE_MISSES[@]}"; do opt_report "- Not applied: ${change}"; done
  local -a inert=()
  mapfile -t inert < <(angie_inert_cache_files /etc/angie)
  if (( ${#inert[@]} > 0 )); then
    local inert_file
    opt_report "- Warning: ${#inert[@]} cache/limit file(s) under http.d are not included by angie.conf:"
    for inert_file in "${inert[@]}"; do opt_report "  \`${inert_file}\`"; done
    opt_report "  Re-run the Angie config deployment (install or scripts/nginx_conf.sh) to activate the current file names."
  fi
  if (( active )); then
    if (( TUNE_DIRTY == 0 )); then
      if (( unit_changed )); then
        opt_report "- Restart: deferred (systemd LimitNOFILE drop-in applies on the next restart)"
      else
        opt_report "- Restart: skipped (configuration already optimized)"
      fi
    elif systemctl reload angie 2>/dev/null && systemctl is-active --quiet angie; then
      OPT_CUTOVER=1
      opt_report "- Reload: **OK** (graceful; in-flight requests keep running)"
      if (( unit_changed )); then
        opt_report "- Note: systemd LimitNOFILE drop-in applies on the next full restart"
      fi
    elif systemctl restart angie 2>/dev/null && systemctl is-active --quiet angie; then
      OPT_CUTOVER=1
      opt_report "- Reload failed; Restart: **OK**"
    else
      opt_report "- Reload/Restart: **FAILED**; rolling back"
      opt_restore /etc/angie angie
      systemctl reload angie 2>/dev/null || systemctl restart angie 2>/dev/null || true
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  return 0
}

# True when active PHP vhosts use the shared local_php upstream, so the
# temporary socket-primary/TCP-backup cutover is safe.  A direct fastcgi_pass
# or fastcgi_next_upstream off cannot fall back to the TCP listener.
angie_uses_local_php_upstream() {
  local target=${1:-/etc/angie}
  grep -rqE '^[[:space:]]*fastcgi_pass[[:space:]]+local_php;' \
    "$target/angie.conf" "$target"/conf.d "$target"/h5bp 2>/dev/null || return 1
  if grep -rqE '^[[:space:]]*fastcgi_pass[[:space:]]+(127\.0\.0\.1|localhost):[0-9]+;' \
       "$target/angie.conf" "$target"/conf.d "$target"/h5bp 2>/dev/null; then
    return 1
  fi
  if grep -rqE '^[[:space:]]*fastcgi_next_upstream[[:space:]]+off;' \
       "$target" 2>/dev/null; then
    return 1
  fi
  return 0
}

# Move the primary PHP-FPM pool from a loopback TCP listener to the shared
# Unix socket without dropping requests.  A temporary bridge pool cannot be
# used: PHP-FPM's SIGUSR2 reload applies changes to existing pools but does
# not start a newly added pool (verified on PHP 8.3), so the bridge never
# listened.  Instead Angie gets the socket as primary and the TCP listener as
# backup, the existing pool is switched and reloaded, and the backup is
# retired once the socket is live.  A request that lands exactly while the
# old TCP listener closes and the socket opens can fail over to the backup;
# if both are unavailable for a moment Angie returns 502.  Cache objects
# written in that window are reported, never deleted.  On failure both files
# are restored and the services reload the original configuration.
MIGRATE_REASON=""

migrate_php_pool_to_socket() {
  local ver=$1 tcp=$2
  local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
  local angie_conf=/etc/angie/angie.conf
  local socket=/run/php/php-fpm.sock
  local bakdir bak="${OPT_BACKUP_DIR:-}/php-socket"
  local fpm_bin="" tcp_re port i ok=0
  MIGRATE_REASON=""
  if [[ -z ${OPT_BACKUP_DIR:-} ]]; then
    bakdir=$(tmp_dir setup-php-socket.XXXXXX) || { MIGRATE_REASON="could not create a backup directory"; return 1; }
    bak="${bakdir}/php-socket"
  fi

  [[ -f $pool && -f $angie_conf ]] || { MIGRATE_REASON="pool or angie.conf is missing"; return 1; }
  systemctl is-active --quiet angie || { MIGRATE_REASON="Angie is not active"; return 1; }
  if command -v "php-fpm${ver}" >/dev/null 2>&1; then
    fpm_bin=$(command -v "php-fpm${ver}")
  elif [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
    fpm_bin="/usr/sbin/php-fpm${ver}"
  else
    MIGRATE_REASON="php-fpm${ver} binary not found"
    return 1
  fi
  angie_uses_local_php_upstream /etc/angie \
    || { MIGRATE_REASON="vhosts use a direct fastcgi_pass or fastcgi_next_upstream off"; return 1; }
  tcp_re=${tcp//./\\.}
  port=${tcp##*:}
  grep -qE "^[[:space:]]*server[[:space:]]+${tcp_re};" "$angie_conf" \
    || { MIGRATE_REASON="upstream does not contain ${tcp}"; return 1; }

  if ss -lx 2>/dev/null | grep -qF "$socket"; then
    MIGRATE_REASON="${socket} is already owned by another pool"
    return 1
  fi

  mkdir -p "$bak"
  cp -a "$pool" "$bak/www.conf"
  cp -a "$angie_conf" "$bak/angie.conf"

  # 1. Angie: socket primary, current TCP listener as backup.  angie -t
  #    accepts a unix: server whose socket does not exist yet; the connect
  #    fails fast and the backup serves traffic until PHP creates the socket.
  sed_in_place -E \
    "s|^([[:space:]]*)server[[:space:]]+${tcp_re};|\1server unix:${socket} max_fails=0;\n\1server ${tcp} backup;|" \
    "$angie_conf"
  if ! grep -qF "server unix:${socket} max_fails=0;" "$angie_conf" \
     || ! /usr/sbin/angie -t >/dev/null 2>&1 \
     || ! systemctl reload angie 2>/dev/null; then
    cp -a "$bak/angie.conf" "$angie_conf"
    /usr/sbin/angie -t >/dev/null 2>&1 && systemctl reload angie 2>/dev/null || true
    MIGRATE_REASON="Angie rejected the socket+backup upstream"
    return 1
  fi
  cp -a "$angie_conf" "$bak/angie-backup.conf"

  # 2. Move the existing pool to the socket.  The reload is graceful: old
  #    workers finish in-flight TCP requests while the master opens the socket.
  tune_pool_set "$pool" listen "$socket" "PHP ${ver}: listen=${socket}"
  sed_in_place -E '/^[[:space:]]*listen\.allowed_clients[[:space:]]*=/d' "$pool"
  tune_pool_set "$pool" listen.owner www-data "PHP ${ver}: listen.owner=www-data"
  tune_pool_set "$pool" listen.group www-data "PHP ${ver}: listen.group=www-data"
  tune_pool_set "$pool" listen.mode 0660 "PHP ${ver}: listen.mode=0660"
  if ! "$fpm_bin" -t >/dev/null 2>&1 \
     || ! systemctl reload "php${ver}-fpm" 2>/dev/null; then
    cp -a "$bak/www.conf" "$pool"
    "$fpm_bin" -t >/dev/null 2>&1 && systemctl reload "php${ver}-fpm" 2>/dev/null || true
    cp -a "$bak/angie.conf" "$angie_conf"
    /usr/sbin/angie -t >/dev/null 2>&1 && systemctl reload angie 2>/dev/null || true
    MIGRATE_REASON="PHP rejected the socket pool or the reload failed"
    return 1
  fi
  for i in {1..50}; do
    if systemctl is-active --quiet "php${ver}-fpm" \
       && ss -lx 2>/dev/null | grep -qF "$socket"; then
      ok=1
      break
    fi
    sleep 0.2
  done
  if (( ok == 0 )); then
    cp -a "$bak/www.conf" "$pool"
    cp -a "$bak/angie.conf" "$angie_conf"
    "$fpm_bin" -t >/dev/null 2>&1 && systemctl reload "php${ver}-fpm" 2>/dev/null || true
    /usr/sbin/angie -t >/dev/null 2>&1 && systemctl reload angie 2>/dev/null || true
    # Not every PHP-FPM build applies a listener change on SIGUSR2 (PHP 8.4
    # kept the old TCP listener in validation).  Forcing a restart here would
    # cut a live site for a marginal gain, so leave the working TCP pool and
    # let an operator complete the move during a maintenance restart.
    MIGRATE_REASON="this PHP-FPM build did not open the socket on reload; kept TCP (a PHP-FPM restart applies it)"
    return 2
  fi

  # 3. Drop the TCP backup; the socket is proven live.
  sed_in_place -E "/^[[:space:]]*server[[:space:]]+${tcp_re}[[:space:]]+backup;/d" "$angie_conf"
  sed_in_place -E "s|server unix:${socket} max_fails=0;|server unix:${socket};|" "$angie_conf"
  if ! /usr/sbin/angie -t >/dev/null 2>&1 \
     || ! systemctl reload angie 2>/dev/null; then
    # Keep the working socket+backup config rather than risking the site.
    cp -a "$bak/angie-backup.conf" "$angie_conf"
    /usr/sbin/angie -t >/dev/null 2>&1 && systemctl reload angie 2>/dev/null || true
    MIGRATE_REASON="Angie could not drop the TCP backup (socket is live; backup kept)"
    return 1
  fi
  return 0
}
optimize_php_services() {


  local primary ver active listen_path rc=0
  primary=$(php_primary_version)
  if [[ -z $primary ]]; then
    # No pool we can safely identify: leave Angie's FastCGI upstream alone
    # rather than pointing it at a socket that was never created.
    OPT_PHP_OK=0
    opt_report "- No PHP-FPM pool with a usable www.conf; Angie upstream left unchanged"
    return 0
  fi
  while IFS= read -r ver; do
    active=0
    systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && active=1
    # Preserve the pool's existing listener.  Migrating a live TCP pool to a
    # Unix socket creates a window where Angie still points at port 9000 and
    # every request returns 502.  Installations still use the socket template.
    listen_path=$(php_pool_listen "$ver")
    opt_report "## PHP ${ver}"
    opt_report "- Active: ${active}; listen kept: \`${listen_path:-unknown}\`"
    opt_backup "/etc/php/${ver}" "php-${ver}"
    tune_reset_changes
    # Replace a stale managed php.ini copy before tuning.  Keep the live
    # timezone; everything else follows configs/php/custom_dan.ini.
    sync_php_ini_template "$ver"
    # Keep the systemd fd/core limits in sync with the installer; an old
    # server may still be capped at the package default (1024 fds) while the
    # pool asks for 524288.
    local limits_src="${SCRIPT_DIR}/configs/php/php-fpm-limits.conf"
    local limits_dst="/etc/systemd/system/php${ver}-fpm.service.d/limits.conf"
    local limits_before=""
    [[ -f $limits_dst ]] && limits_before=$(md5sum "$limits_dst" | awk '{print $1}')
    mkdir -p "$(dirname "$limits_dst")"
    if [[ -f $limits_src ]]; then
      install -m 644 "$limits_src" "$limits_dst"
    else
      printf '[Service]\nLimitNOFILE=524288\nLimitCORE=0\nTimeoutStopSec=15\nUMask=0027\n' > "$limits_dst"
      chmod 644 "$limits_dst"
    fi
    if [[ $limits_before != "$(md5sum "$limits_dst" | awk '{print $1}')" ]]; then
      systemctl daemon-reload || true
      tune_note "PHP ${ver}: systemd LimitNOFILE=524288"
    fi
    if ! tune_php_fpm_version "$ver"; then
      opt_restore "/etc/php/${ver}" "php-${ver}"
      opt_report "- **FAILED** PHP-FPM configuration test; rolled back"
      rc=1
      OPT_PHP_OK=0
      continue
    fi
    local change
    for change in "${TUNE_CHANGES[@]}"; do opt_report "- ${change}"; done
    for change in "${TUNE_MISSES[@]}"; do opt_report "- Not applied: ${change}"; done
    local migrated=0 migration_failed=0 migration_rc=0
    if (( active )) && [[ $ver == "$primary" ]] \
       && [[ $listen_path =~ ^(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
      if systemctl is-active --quiet angie \
         && angie_uses_local_php_upstream /etc/angie; then
        if migrate_php_pool_to_socket "$ver" "$listen_path"; then
          OPT_PHP_SOCKET=/run/php/php-fpm.sock
          OPT_CUTOVER=1
          migrated=1
          opt_report "- Migrated listener: ${listen_path} -> unix:${OPT_PHP_SOCKET}"
        else
          migration_rc=$?
          if (( migration_rc == 2 )); then
            # The pool is healthy on TCP; only the optional socket move was
            # skipped.  Do not fail the whole optimize run for that.
            opt_report "- Socket migration skipped: ${MIGRATE_REASON:-the listener did not move}"
          else
            opt_report "- **FAILED** socket migration; kept ${listen_path} (${MIGRATE_REASON:-no reason recorded})"
            rc=1
            OPT_PHP_OK=0
            migration_failed=1
          fi
        fi
      else
        opt_report "- Socket migration skipped: Angie inactive or vhosts use a direct fastcgi_pass/next_upstream off"
      fi
    fi
    if (( active )); then
      if (( migrated || migration_failed )); then
        : # migration already reloaded PHP (success or rollback)
      elif (( TUNE_DIRTY == 0 )); then
        opt_report "- Restart: skipped (configuration already optimized)"
      elif systemctl reload "php${ver}-fpm" 2>/dev/null \
         && systemctl is-active --quiet "php${ver}-fpm" \
         && { [[ $listen_path != /* ]] || [[ -S $listen_path ]]; }; then
        # SIGUSR2 reloads the pool without closing the listening socket: old
        # workers finish in-flight requests and new workers pick up the tuned
        # values.  This is the difference between a zero-downtime tune and a
        # 1-3 second 502 window on a busy site.
        OPT_CUTOVER=1
        opt_report "- Reload: **OK** (graceful; no request was dropped)"
        if [[ -f "/etc/php/${ver}/fpm/php-fpm.conf" ]] \
           && grep -q 'process_control_timeout' "/etc/php/${ver}/fpm/php-fpm.conf"; then
          opt_report "- Note: master-level process_control_timeout applies on the next full restart"
        fi
      elif systemctl restart "php${ver}-fpm" 2>/dev/null \
         && systemctl is-active --quiet "php${ver}-fpm"; then
        OPT_CUTOVER=1
        # Type=notify only returns once the master is ready.  A pool that
        # already used a Unix socket must have re-created it.
        if [[ $listen_path == /* && ! -S $listen_path ]]; then
          opt_report "- **FAILED** ${listen_path} was not created; rolling back"
          opt_restore "/etc/php/${ver}" "php-${ver}"
          systemctl restart "php${ver}-fpm" 2>/dev/null || true
          rc=1
          OPT_PHP_OK=0
        else
          opt_report "- Reload failed; Restart: **OK**"
        fi
      else
        opt_report "- Reload/Restart: **FAILED**; rolling back"
        opt_restore "/etc/php/${ver}" "php-${ver}"
        systemctl restart "php${ver}-fpm" 2>/dev/null || true
        rc=1
        OPT_PHP_OK=0
      fi
    else
      opt_report "- Restart: skipped (service was not active)"
    fi
  done < <(php_fpm_versions)

  # Only hand a socket path to Angie when that pool is active and the socket
  # actually exists.  TCP pools deliberately leave OPT_PHP_SOCKET empty.
  if (( rc == 0 )); then
    listen_path=$(php_pool_listen "$primary")
    if [[ $listen_path == /* ]] \
       && systemctl is-active --quiet "php${primary}-fpm" \
       && [[ -S $listen_path ]]; then
      OPT_PHP_SOCKET=$listen_path
    fi
  fi
  return "$rc"
}

mariadb_server_version() {
  local v
  v=$(mariadbd --version 2>/dev/null | awk '{print $3}' || true)
  [[ -n $v ]] || v=$(mariadb --version 2>/dev/null | awk '{print $5}' || true)
  printf '%s' "${v%%-*}"
}

# True when two generated MariaDB configs differ only in the buffer-pool size,
# so the value can be applied online without a restart.
cnf_only_pool_changed() {
  local old=$1 new=$2
  [[ -f $old && -f $new ]] || return 1
  diff -q \
    <(grep -vE '^[[:space:]]*innodb_buffer_pool_size[[:space:]]*=' "$old") \
    <(grep -vE '^[[:space:]]*innodb_buffer_pool_size[[:space:]]*=' "$new") \
    >/dev/null 2>&1
}

# Stop the request-serving tiers before a MariaDB restart, then bring them
# back in dependency order (PHP first, Angie last).  Only services that were
# active are touched; an OS-only or DB-only host is unaffected.
opt_pause_web_frontends() {
  OPT_WEB_PAUSED_ANGIE=0
  OPT_WEB_PAUSED_PHP=()
  local unit
  if systemctl is-active --quiet angie 2>/dev/null; then
    if systemctl stop angie 2>/dev/null; then
      OPT_WEB_PAUSED_ANGIE=1
      info "Paused Angie before the MariaDB restart"
    else
      warn "Could not stop Angie before the MariaDB restart"
    fi
  fi
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    systemctl is-active --quiet "$unit" 2>/dev/null || continue
    if systemctl stop "$unit" 2>/dev/null; then
      OPT_WEB_PAUSED_PHP+=("$unit")
      info "Paused ${unit} before the MariaDB restart"
    else
      warn "Could not stop ${unit} before the MariaDB restart"
    fi
  done < <(systemctl list-units --type=service --state=active --no-legend --no-pager \
             'php*-fpm.service' 2>/dev/null | awk '{print $1}')
}

opt_resume_web_frontends() {
  local unit rc=0
  for unit in "${OPT_WEB_PAUSED_PHP[@]}"; do
    if ! systemctl start "$unit" 2>/dev/null; then
      warn "Could not start ${unit} after the MariaDB restart"
      rc=1
    fi
  done
  if (( OPT_WEB_PAUSED_ANGIE )); then
    if ! systemctl start angie 2>/dev/null; then
      warn "Could not start Angie after the MariaDB restart"
      rc=1
    fi
  fi
  if (( ${#OPT_WEB_PAUSED_PHP[@]} > 0 || OPT_WEB_PAUSED_ANGIE )); then
    info "Resumed web frontends after the MariaDB restart"
  fi
  OPT_WEB_PAUSED_ANGIE=0
  OPT_WEB_PAUSED_PHP=()
  return "$rc"
}

optimize_mariadb() {
  local active=0 ver size_mb buffer logsize open_cache aria_mb
  local threads max_conn io_read io_write cnf_dir cnf backlog cnf_before cnf_after
  local unit_changed=0 limit_before="" i live_slow="" live_err=""
  systemctl is-active --quiet mariadb 2>/dev/null && active=1
  ver=$(mariadb_server_version)
  opt_report "## MariaDB"
  opt_report "- Version: \`${ver:-unknown}\`; active: ${active}"
  opt_backup /etc/mysql mysql
  opt_backup /etc/systemd/system/mariadb.service.d mariadb-systemd

  if [[ ${OPT_MARIADB_BUDGET_MB:-0} -gt 0 ]]; then
    size_mb=$OPT_MARIADB_BUDGET_MB
  else
    size_mb=$(mem_total_mb)
    size_mb=$(( size_mb * 40 / 100 ))
    (( size_mb < 256 )) && size_mb=256
  fi
  if (( ${OPT_DB_SIZE_MB:-0} == 0 )); then
    OPT_DB_SIZE_MB=$(mariadb_data_size_mb)
    [[ ${OPT_DB_SIZE_MB:-} =~ ^[0-9]+$ ]] || OPT_DB_SIZE_MB=0
  fi
  if (( OPT_DB_SIZE_MB > 0 )); then
    if (( size_mb >= OPT_DB_SIZE_MB )); then
      opt_report "- Database data+index=${OPT_DB_SIZE_MB}MB; buffer pool=${size_mb}MB (fits)"
    elif (( ${OPT_MARIADB_KEPT_MB:-0} > 0 )); then
      opt_report "- Database data+index=${OPT_DB_SIZE_MB}MB; buffer pool=${size_mb}MB (kept existing pool)"
    else
      opt_report "- Database data+index=${OPT_DB_SIZE_MB}MB; buffer pool=${size_mb}MB (does not fully fit; largest feasible pool)"
    fi
  fi
  mariadb_compute_profile "$size_mb"
  buffer=$MARIADB_PROFILE_BUFFER
  logsize=$MARIADB_PROFILE_LOG_SIZE
  open_cache=$MARIADB_PROFILE_OPEN_CACHE
  aria_mb=$MARIADB_PROFILE_ARIA_MB
  threads=$MARIADB_PROFILE_THREADS
  max_conn=$MARIADB_PROFILE_MAX_CONN
  io_read=$MARIADB_PROFILE_IO_READ
  io_write=$MARIADB_PROFILE_IO_WRITE
  backlog=$MARIADB_PROFILE_BACKLOG

  cnf_dir=/etc/mysql/mariadb.conf.d
  mkdir -p "$cnf_dir"
  # Enabling slow/error logging under /var/www/logs needs the AppArmor override
  # on Ubuntu 24.04/26.04 as well; the installer already writes it, but an old
  # host tuned in place may not have it.
  configure_mariadb_apparmor

  # An existing server may still carry the package's default 1024-fd limit.
  # Keep the same systemd drop-in the installer uses.
  local limits_src="${SCRIPT_DIR}/configs/mariadb/limit_nofile.conf"
  local limits_dst=/etc/systemd/system/mariadb.service.d/limits.conf
  local limits_before=""
  [[ -f $limits_dst ]] && limits_before=$(md5sum "$limits_dst" | awk '{print $1}')
  limit_before=$(systemctl show -p LimitNOFILE --value mariadb 2>/dev/null || true)
  mkdir -p "$(dirname "$limits_dst")"
  if [[ -f $limits_src ]]; then
    install -m 644 "$limits_src" "$limits_dst"
  else
    printf '[Service]\nLimitNOFILE=1048576\nLimitCORE=0\nEnvironment=MYSQLD_OPTS=\nEnvironment=_WSREP_NEW_CLUSTER=\n' > "$limits_dst"
    chmod 644 "$limits_dst"
  fi
  if [[ $limits_before != "$(md5sum "$limits_dst" | awk '{print $1}')" ]]; then
    systemctl daemon-reload || true
    unit_changed=1
    opt_report "- systemd LimitNOFILE=1048576"
  fi
  cnf="${cnf_dir}/99-setup-optimize.cnf"

  cnf_before=""
  [[ -f $cnf ]] && cnf_before=$(md5sum "$cnf" | awk '{print $1}')
  local cnf_old=""
  if [[ -f $cnf ]]; then
    cnf_old=$(tmp_file)
    cp -a "$cnf" "$cnf_old"
  fi

  {
    cat <<'EOF'
# BEGIN setup.sh optimize
# Hardware-aware MariaDB tuning; generated by setup.sh --optimize.
# [mysqld] is understood by MariaDB 10.11 (Ubuntu 24.04) and 11.8 (26.04).
[mysqld]
EOF
    mariadb_performance_settings "$size_mb" "$max_conn"
    mariadb_logging_settings
    printf '%s\n' '# END setup.sh optimize'
  } > "$cnf"
  chmod 644 "$cnf"
  cnf_after=$(md5sum "$cnf" | awk '{print $1}')
  opt_report "- Wrote \`${cnf}\` (buffer=${buffer}, max_connections=${max_conn}, back_log=${backlog})"
  opt_report "- Slow/error logging: /var/www/logs/mariadb/slow.log and error.log"
  opt_report "- innodb_io_capacity=${io_read}/${io_write}, thread_pool_size=${threads}"
  # One owner for the performance values: remove the installer-managed block
  # from 50-server.cnf now that the 99- drop-in is authoritative.
  mariadb_strip_install_block "$size_mb" "$max_conn" \
    || warn "Could not remove old performance keys from 50-server.cnf"

  # A running server can resize the buffer pool online.  Restarting a busy
  # database just to grow it by a few percent empties every application cache
  # at once; on XenForo that produced a thousand-request lock convoy on the
  # same registry row.  Only fall back to a restart when the pool is not the
  # only change (or the resize fails).
  local online_mb=""
  if [[ -n $cnf_old ]] && (( active )) && [[ $cnf_before != "$cnf_after" ]] \
     && cnf_only_pool_changed "$cnf_old" "$cnf"; then
    if mariadb -e "SET GLOBAL innodb_buffer_pool_size = $(( size_mb * 1024 * 1024 ))" 2>/dev/null; then
      online_mb=$(mariadb -N -B -e 'SELECT @@innodb_buffer_pool_size' 2>/dev/null \
        | awk '{printf "%d", $1 / 1024 / 1024}')
      opt_report "- Applied buffer pool online: ${online_mb:-$size_mb}MB (no restart)"
      if (( unit_changed == 0 )); then
        return 0
      fi
      if [[ $limit_before =~ ^[0-9]+$ ]] && (( limit_before >= 65536 )); then
        opt_report "- Restart: deferred (LimitNOFILE=${limit_before} is already sufficient; the drop-in applies on the next restart)"
        return 0
      fi
      # The fd drop-in still needs a restart; fall through to apply it.
    else
      opt_report "- Online buffer-pool resize failed; falling back to a restart"
    fi
  fi
  if [[ -n $cnf_before && $cnf_before == "$cnf_after" ]]; then
    if (( unit_changed == 0 )); then
      opt_report "- Restart: skipped (configuration already optimized)"
      return 0
    fi
    # Only the systemd fd drop-in changed.  Restarting a live database cuts
    # in-flight queries (a site can cache blank error pages during the gap),
    # and the current limit already exceeds what max_connections needs, so
    # let the drop-in apply on the next planned restart.
    if [[ $limit_before =~ ^[0-9]+$ ]] && (( limit_before >= 65536 )); then
      opt_report "- Restart: deferred (LimitNOFILE=${limit_before} is already sufficient; the drop-in applies on the next restart)"
      return 0
    fi
  fi

  if command -v mariadbd >/dev/null 2>&1; then
    if ! mariadbd --defaults-file=/etc/mysql/my.cnf --help --verbose >/dev/null 2>&1; then
      opt_report "- **FAILED** MariaDB rejected the generated configuration; rolled back"
      opt_restore /etc/mysql mysql
      opt_restore /etc/systemd/system/mariadb.service.d mariadb-systemd
      systemctl daemon-reload || true
      return 1
    fi
  fi

  if (( active )); then
    # Apply any service-unit drop-in before restarting, then stop the request
    # tiers.  A busy PHP pool reconnecting while InnoDB preloads can otherwise
    # overwhelm a freshly started database.
    systemctl daemon-reload || true
    opt_pause_web_frontends
    if (( OPT_WEB_PAUSED_ANGIE || ${#OPT_WEB_PAUSED_PHP[@]} > 0 )); then
      opt_report "- Paused web frontends before the MariaDB restart (PHP, then Angie)"
    fi

    if systemctl restart mariadb 2>/dev/null; then
      OPT_CUTOVER=1
      # A large buffer pool may need to preload at startup; allow up to five
      # minutes before declaring the restart failed.
      for i in {1..300}; do
        mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
        sleep 1
      done
      if mariadb -e 'SELECT 1' >/dev/null 2>&1; then
        opt_report "- Restart: **OK**"
        live_slow=$(mariadb -N -B -e 'SELECT @@slow_query_log' 2>/dev/null || true)
        live_err=$(mariadb -N -B -e 'SELECT @@log_error' 2>/dev/null || true)
        opt_report "- Live slow_query_log=${live_slow:-unknown}, log_error=${live_err:-unknown}"
        if [[ $live_slow != 1 ]]; then
          opt_report "- **WARNING**: slow_query_log is ${live_slow:-unknown} after restart; check AppArmor/log permissions"
        fi
        if ! opt_resume_web_frontends; then
          opt_report "- Web frontends: **FAILED** to resume; check Angie/PHP-FPM"
          return 1
        fi
        opt_report "- Web frontends resumed after the MariaDB restart"
      else
        opt_report "- Restart: **FAILED** (SQL probe); rolling back"
        opt_restore /etc/mysql mysql
        opt_restore /etc/systemd/system/mariadb.service.d mariadb-systemd
        systemctl daemon-reload || true
        systemctl restart mariadb 2>/dev/null || true
        for i in {1..30}; do
          mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
          sleep 1
        done
        opt_resume_web_frontends || true
        return 1
      fi
    else
      opt_report "- Restart: **FAILED**; rolling back"
      opt_restore /etc/mysql mysql
      opt_restore /etc/systemd/system/mariadb.service.d mariadb-systemd
      systemctl daemon-reload || true
      systemctl restart mariadb 2>/dev/null || true
      for i in {1..30}; do
        mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
        sleep 1
      done
      opt_resume_web_frontends || true
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  return 0
}

# Valkey/Redis size values may be written as 8192mb, 8gb, 512kb or raw bytes.
# Return whole MB so the memory plan and the live config agree.
valkey_mb_from_config() {
  local value=${1,,} n unit
  [[ $value =~ ^([0-9]+)([a-z]*)$ ]] || { printf '0'; return 0; }
  n=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  case $unit in
    gb|g) printf '%s' $(( n * 1024 )) ;;
    mb|m) printf '%s' "$n" ;;
    kb|k) printf '%s' $(( n / 1024 )) ;;
    ""|b) printf '%s' $(( n / 1024 / 1024 )) ;;
    *) printf '0' ;;
  esac
}

restart_php_workers_for_group() {
  local group=$1 unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    if ! systemctl restart "$unit" 2>/dev/null; then
      warn "Could not restart ${unit} to inherit the ${group} group"
    fi
  done < <(list_active_php_units)
}

optimize_valkey() {
  local kind=${1:-valkey}
  local label=Valkey conf=/etc/valkey/valkey.conf conf_dir=/etc/valkey
  local unit=valkey-server cli=valkey-cli
  if [[ $kind == redis ]]; then
    label=Redis conf=/etc/redis/redis.conf conf_dir=/etc/redis
    unit=redis-server cli=redis-cli
  fi
  local active=0 ram_mb max_mb policy backlog io_threads i
  local conf_before conf_after fd_limit dropin unit_changed=0
  local online_ok=0 live_io="" live_backlog="" setting k v
  local socket_path group socket_before socket_after perm_before perm_after socket_changed=0 group_changed=0
  [[ -f $conf ]] || return 0
  systemctl is-active --quiet "$unit" 2>/dev/null && active=1
  opt_report "## ${label}"
  opt_report "- Active: ${active}; config: \`${conf}\`"
  opt_backup "$conf_dir" "$kind"
  # Reset the shared change tracker so a previous service's restart does not
  # force an unnecessary cache restart on an otherwise unchanged run.
  tune_reset_changes
  if [[ ${OPT_VALKEY_BUDGET_MB:-0} -gt 0 ]]; then
    max_mb=$OPT_VALKEY_BUDGET_MB
  else
    ram_mb=$(mem_total_mb)
    max_mb=$(( ram_mb / 10 ))
    (( max_mb < 256 )) && max_mb=256
    (( max_mb > 8192 )) && max_mb=8192
  fi
  backlog=$(effective_backlog)
  # A restart applies maxmemory immediately.  Lowering it below the data that
  # is already stored mass-evicts the cache (and any sessions/jobs using it),
  # so give the live working set 10% of headroom instead of following the
  # hardware plan blindly.
  local used_mb=0 needed_mb
  if (( active )); then
    used_mb=$("$cli" info memory 2>/dev/null \
      | awk -F: '/^used_memory:/{gsub(/\r/, "", $2); print int($2 / 1048576)}')
    [[ $used_mb =~ ^[0-9]+$ ]] || used_mb=0
    needed_mb=$(( used_mb * 110 / 100 ))
    if (( needed_mb > max_mb )); then
      local hard_cap
      hard_cap=$(( ${OPT_MEM_TOTAL_MB:-$(mem_total_mb)} * 80 / 100 ))
      (( hard_cap < 256 )) && hard_cap=256
      if (( needed_mb > hard_cap )); then
        opt_report "- maxmemory capped at ${hard_cap}mb (live data needs ${needed_mb}mb; add RAM or reduce the working set)"
        max_mb=$hard_cap
      else
        opt_report "- maxmemory raised to ${needed_mb}mb (in use=${used_mb}mb; refusing to evict live data)"
        max_mb=$needed_mb
      fi
    fi
  fi
  policy=$(awk '/^[[:space:]]*maxmemory-policy[[:space:]]/{print $2; exit}' "$conf")
  [[ -n $policy ]] || policy=allkeys-lru
  # Preserve an explicit install-time io-threads value (the installer defaults
  # to 1); forcing 1 here would silently undo `--valkey io_threads=N`.
  io_threads=$(awk '/^[[:space:]]*io-threads[[:space:]]/{print $2; exit}' "$conf")
  [[ $io_threads =~ ^[0-9]+$ ]] || io_threads=1
  (( io_threads < 1 )) && io_threads=1
  (( io_threads > 8 )) && io_threads=8
  conf_before=$(md5sum "$conf" | awk '{print $1}')

  conf_set() {
    local key=$1 value=$2
    if grep -qE "^[[:space:]]*${key}[[:space:]]" "$conf"; then
      sed_in_place -E "s|^[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$conf"
    else
      printf '%s %s\n' "$key" "$value" >> "$conf"
    fi
  }
  while read -r key value; do
    [[ -n $key ]] || continue
    conf_set "$key" "$value"
  done < <(valkey_tuning_lines "$max_mb" "$policy" "$io_threads")

  # Local PHP should use the Unix socket: it avoids ephemeral-port/TIME_WAIT
  # pressure and was measurably faster for small cache commands.  This is
  # startup-only, so it is applied here and the cache is restarted below.
  if [[ $kind == redis ]]; then
    socket_path=/run/redis/redis.sock
    group=redis
  else
    socket_path=/run/valkey/valkey.sock
    group=valkey
  fi
  socket_before=$(awk '/^[[:space:]]*unixsocket[[:space:]]/{print $2; exit}' "$conf")
  perm_before=$(awk '/^[[:space:]]*unixsocketperm[[:space:]]/{print $2; exit}' "$conf")
  # Keep an operator's existing custom socket path; only add the default when
  # the service has no socket configured.
  if [[ -n $socket_before && $socket_before == /* ]]; then
    socket_path=$socket_before
  fi
  conf_set unixsocket "$socket_path"
  conf_set unixsocketperm 770
  socket_after=$(awk '/^[[:space:]]*unixsocket[[:space:]]/{print $2; exit}' "$conf")
  perm_after=$(awk '/^[[:space:]]*unixsocketperm[[:space:]]/{print $2; exit}' "$conf")
  if [[ $socket_before != "$socket_path" || $perm_before != "$perm_after" || $perm_after != 770 ]]; then
    socket_changed=1
  fi
  # A configured socket that is not live (or still has the old permissions)
  # needs a restart.
  if [[ -S $socket_path ]]; then
    [[ $(stat -c '%a' "$socket_path" 2>/dev/null || true) == 770 ]] || socket_changed=1
  else
    socket_changed=1
  fi
  if getent group "$group" >/dev/null 2>&1; then
    if ! id -nG www-data 2>/dev/null | grep -qw "$group"; then
      if usermod -aG "$group" www-data 2>/dev/null; then
        group_changed=1
      else
        warn "Could not add www-data to the ${group} group"
      fi
    fi
  else
    warn "Service group ${group} does not exist; ${socket_path} will not be accessible to www-data"
  fi
  opt_report "- Local socket: \`${socket_path}\` (unixsocketperm 770)"
  opt_report "- Application config (not edited automatically):"
  opt_report "  XenForo: \`\$config['cache']['config']['host'] = '${socket_path}'; \$config['cache']['config']['port'] = 0;\`"
  opt_report "  WordPress: \`define('WP_REDIS_PATH', '${socket_path}');\`"
  opt_report "  Laravel/phpredis: \`'host' => '${socket_path}', 'port' => 0\`"
  opt_report "  Test: \`${cli} -s ${socket_path} ping\`"

  conf_after=$(md5sum "$conf" | awk '{print $1}')
  opt_report "- maxmemory=${max_mb}mb, policy=${policy}, maxclients=20000, tcp-backlog=${backlog}"

  # maxclients=20000 is unusable if systemd still caps the unit at 1024 fds.
  # Keep this in a dedicated drop-in so a package/admin file is never edited.
  dropin="/etc/systemd/system/${unit}.service.d/zz-setup-optimize.conf"
  fd_limit=$(systemctl show -p LimitNOFILE --value "$unit" 2>/dev/null || true)
  if [[ $fd_limit =~ ^[0-9]+$ ]] && (( fd_limit < 524288 )); then
    opt_backup "$(dirname "$dropin")" "${kind}-systemd"
    mkdir -p "$(dirname "$dropin")"
    printf '[Service]\nLimitNOFILE=524288\nLimitCORE=0\n' > "$dropin"
    chmod 644 "$dropin"
    unit_changed=1
    systemctl daemon-reload || true
    opt_report "- systemd LimitNOFILE: ${fd_limit} -> 524288"
  fi

  if (( active )) && (( TUNE_DIRTY == 0 )) \
     && [[ $conf_before == "$conf_after" ]] && (( unit_changed == 0 )) \
     && (( socket_changed == 0 )); then
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group"
    fi
    opt_report "- Restart: skipped (configuration already optimized)"
    return 0
  fi

  # Apply the runtime-settable values to the live process.  A restart throws
  # away the whole cache when persistence is disabled (the installer writes
  # `save ""` and `appendonly no`), so a tuning run must not restart a busy
  # cache just to add timeout/hz/lazyfree defaults.
  if (( active )); then
    online_ok=1
    local -a runtime_sets=(
      "maxmemory ${max_mb}mb"
      "maxmemory-policy ${policy}"
      "maxmemory-samples 10"
      "maxclients 20000"
      "timeout 0"
      "tcp-keepalive 300"
      "hz 10"
      "io-threads-do-reads yes"
      "lazyfree-lazy-eviction yes"
      "lazyfree-lazy-expire yes"
      "lazyfree-lazy-server-del yes"
      "lazyfree-lazy-user-del yes"
      "lazyfree-lazy-user-flush yes"
    )
    for setting in "${runtime_sets[@]}"; do
      read -r k v <<< "$setting"
      if ! "$cli" CONFIG SET "$k" "$v" >/dev/null 2>&1; then
        online_ok=0
        opt_report "- Online \`CONFIG SET ${k} ${v}\` failed; a restart is required"
        break
      fi
    done
    # io-threads is fixed at startup.  A systemd fd drop-in also needs a new
    # process before maxclients can exceed the old limit.
    live_io=$("$cli" CONFIG GET io-threads 2>/dev/null | tail -n1 || true)
    if [[ $live_io =~ ^[0-9]+$ ]] && [[ $live_io != "$io_threads" ]]; then
      online_ok=0
      opt_report "- io-threads=${io_threads} differs from live ${live_io}; a restart is required"
    fi
    if (( unit_changed )); then
      online_ok=0
    fi
    if (( socket_changed )); then
      online_ok=0
      opt_report "- Unix socket change applies on restart (cache may be cold)"
    fi
  fi
  if (( active )) && (( online_ok )); then
    live_backlog=$("$cli" CONFIG GET tcp-backlog 2>/dev/null | tail -n1 || true)
    if [[ $live_backlog =~ ^[0-9]+$ ]] && [[ $live_backlog != "$backlog" ]]; then
      opt_report "- tcp-backlog=${backlog} applies at startup (live ${live_backlog}); restart deferred"
    fi
    if (( group_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group"
    fi
    opt_report "- Applied online via CONFIG SET (no restart; cache retained)"
    return 0
  fi

  if (( active )); then
    if systemctl restart "$unit" 2>/dev/null; then
      OPT_CUTOVER=1
      for i in {1..20}; do
        "$cli" ping 2>/dev/null | grep -q PONG && break
        sleep 1
      done
      if "$cli" ping 2>/dev/null | grep -q PONG; then
        opt_report "- Restart: **OK**"
        if (( group_changed || socket_changed )); then
          restart_php_workers_for_group "$group"
          opt_report "- PHP-FPM restarted to inherit the ${group} group"
        fi
      else
        opt_report "- Restart: **FAILED** (PING); rolling back"
        opt_restore "$conf_dir" "$kind"
        opt_restore "/etc/systemd/system/${unit}.service.d" "${kind}-systemd"
        systemctl daemon-reload || true
        systemctl restart "$unit" 2>/dev/null || true
        return 1
      fi
    else
      opt_report "- Restart: **FAILED**; rolling back"
      opt_restore "$conf_dir" "$kind"
      opt_restore "/etc/systemd/system/${unit}.service.d" "${kind}-systemd"
      systemctl daemon-reload || true
      systemctl restart "$unit" 2>/dev/null || true
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
    if (( group_changed || socket_changed )); then
      restart_php_workers_for_group "$group"
      opt_report "- PHP-FPM restarted to inherit the ${group} group (socket applies at next start)"
    fi
  fi
  return 0
}

# Elasticsearch reads every *.options file in jvm.options.d in lexical order,
# and the JVM keeps the last -Xms/-Xmx.  Older setup.sh releases wrote the heap
# to jvm.options during install and to zz-setup-optimize.options during
# --optimize, leaving two conflicting heap pairs behind (the 31 GB install
# value and the optimized one).  Always own one file and remove the legacy one
# when it is recognisably the file this script generated.
readonly ES_JVM_OPTIONS="/etc/elasticsearch/jvm.options.d/zz-setup-optimize.options"

es_jvm_options_is_managed() {
  local file=$1 line count=0 xs=0 xx=0 other=0
  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    count=$(( count + 1 ))
    case $line in
      -Xms*|-Xmx*)
        [[ $line == -Xms* ]] && xs=$(( xs + 1 )) || xx=$(( xx + 1 ))
        ;;
      -XX:+UseG1GC|-XX:MaxGCPauseMillis=200|-XX:+HeapDumpOnOutOfMemoryError|-Dlog4j2.formatMsgNoLookups=true) ;;
      *) other=$(( other + 1 )) ;;
    esac
  done < "$file"
  (( other == 0 && xs == 1 && xx == 1 && count >= 4 && count <= 6 ))
}

es_jvm_options_is_heap_only() {
  local file=$1 line count=0 xs=0 xx=0 other=0
  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line =~ ^[[:space:]]*# ]]; then
      continue
    fi
    count=$(( count + 1 ))
    case $line in
      -Xms*) xs=$(( xs + 1 )) ;;
      -Xmx*) xx=$(( xx + 1 )) ;;
      -XX:+UseG1GC|-XX:MaxGCPauseMillis=200|-XX:+HeapDumpOnOutOfMemoryError|-Dlog4j2.formatMsgNoLookups=true) ;;
      *) other=$(( other + 1 )) ;;
    esac
  done < "$file"
  (( other == 0 && xs == 1 && xx == 1 && count >= 2 ))
}

write_es_jvm_options() {
  local heap_mb=$1 dir=${2:-/etc/elasticsearch/jvm.options.d}
  local jvm="${dir}/zz-setup-optimize.options"
  local legacy="${dir}/jvm.options"
  cat > "$jvm" <<EOF
-Xms${heap_mb}m
-Xmx${heap_mb}m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+HeapDumpOnOutOfMemoryError
-Dlog4j2.formatMsgNoLookups=true
EOF
  chmod 644 "$jvm"
  chown root:elasticsearch "$jvm" 2>/dev/null || true
  # Never delete an operator's own jvm.options.  A simple heap-only file (the
  # common 4g/4g leftover) is moved to /tmp so zz-setup-optimize.options is the
  # single source of truth.  A richer operator file is preserved, but the
  # silent-override risk is reported explicitly.
  if [[ -f $legacy ]]; then
    if es_jvm_options_is_managed "$legacy" || es_jvm_options_is_heap_only "$legacy"; then
      if preserve_to_tmp "$legacy" >/dev/null; then
        info "Moved heap-only ${legacy} to /tmp; ${jvm} owns the heap"
        if (( ${OPTIMIZE:-0} )); then
          opt_report "- Moved heap-only \`${legacy}\` to /tmp; \`${jvm}\` owns the heap"
        fi
      else
        warn "Could not move ${legacy}; ${jvm} still takes precedence"
        if (( ${OPTIMIZE:-0} )); then
          opt_report "- **WARNING**: could not move \`${legacy}\`; \`${jvm}\` still takes precedence"
        fi
      fi
    elif grep -qE '^[[:space:]]*-Xm[sx]' "$legacy"; then
      warn "Operator ${legacy} also sets -Xms/-Xmx; ${jvm} takes precedence"
      if (( ${OPTIMIZE:-0} )); then
        opt_report "- Warning: operator \`${legacy}\` also sets -Xms/-Xmx; \`${jvm}\` takes precedence"
      fi
    fi
  fi
  return 0
}

elasticsearch_single_node_replica_issue() {
  local json=$1 nodes status unassigned primary
  nodes=$(printf '%s' "$json" | sed -n 's/.*"number_of_nodes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  status=$(printf '%s' "$json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
  unassigned=$(printf '%s' "$json" | sed -n 's/.*"unassigned_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  primary=$(printf '%s' "$json" | sed -n 's/.*"unassigned_primary_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  [[ $nodes =~ ^[0-9]+$ && $nodes -eq 1 ]] || return 1
  [[ $status == yellow ]] || return 1
  [[ $unassigned =~ ^[0-9]+$ && $unassigned -gt 0 ]] || return 1
  [[ $primary =~ ^[0-9]+$ && $primary -eq 0 ]] || return 1
  return 0
}

elasticsearch_ensure_single_node_template() {
  local resp es_url
  es_url=$(elasticsearch_http_url)
  resp=$(curl -fsS --max-time 15 -X PUT -H 'Content-Type: application/json' \
    "${es_url}/_index_template/setup-single-node-zero-replicas" \
    -d '{"index_patterns":["*"],"priority":1,"template":{"settings":{"number_of_replicas":0}}}' \
    2>/dev/null) || resp=""
  if [[ $resp == *'"acknowledged":true'* ]]; then
    opt_report "- Single-node template ensured (priority 1, replicas=0)"
    return 0
  fi
  opt_report "- Single-node template install failed"
  return 1
}

# Wait until a freshly restarted node has assigned its primaries.  The
# cluster can be red for a few seconds while shards recover; deciding before
# then skips the single-node replica fix.
elasticsearch_wait_primaries() {
  local i health status primary es_url code
  es_url=$(elasticsearch_http_url)
  # Return quickly when the endpoint is unreachable from this host (a remote
  # bind + restrictive firewall).  A 503 is still a reachable node and should
  # be waited on.
  code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$es_url" 2>/dev/null || true)
  [[ $code == 000 || -z $code ]] && return 1
  for i in {1..120}; do
    health=$(curl -sS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || true
    status=$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
    primary=$(printf '%s' "$health" | sed -n 's/.*"unassigned_primary_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
    [[ $status == green ]] && return 0
    if [[ $status == yellow && $primary =~ ^[0-9]+$ && $primary -eq 0 ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# A single-node cluster cannot assign replicas.  Yellow health with only
# unassigned replicas is expected there; set replicas=0 on existing indices
# and keep a low-priority template for future indices.
elasticsearch_fix_single_node_replicas() {
  local health status nodes unassigned primary resp i es_url
  command -v curl >/dev/null 2>&1 || return 0
  es_url=$(elasticsearch_http_url)
  elasticsearch_wait_primaries || true
  health=$(curl -fsS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || return 0
  nodes=$(printf '%s' "$health" | sed -n 's/.*"number_of_nodes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  status=$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
  unassigned=$(printf '%s' "$health" | sed -n 's/.*"unassigned_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  primary=$(printf '%s' "$health" | sed -n 's/.*"unassigned_primary_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)

  if [[ ! $nodes =~ ^[0-9]+$ || $nodes -ne 1 ]]; then
    [[ -n $status ]] && opt_report "- Cluster health: ${status} (multi-node; replicas left unchanged)"
    return 0
  fi
  if [[ $status == green ]]; then
    opt_report "- Cluster health: green"
    elasticsearch_ensure_single_node_template || true
    return 0
  fi
  if ! elasticsearch_single_node_replica_issue "$health"; then
    opt_report "- Cluster health: ${status:-unknown} (not a single-node replica issue; left unchanged)"
    return 0
  fi

  resp=$(curl -fsS --max-time 30 -X PUT -H 'Content-Type: application/json' \
    "${es_url}/_all/_settings" \
    -d '{"index":{"number_of_replicas":0}}' 2>/dev/null) || resp=""
  if [[ $resp != *'"acknowledged":true'* ]]; then
    opt_report "- Single-node cluster: **FAILED** to set number_of_replicas=0"
    return 1
  fi
  opt_report "- Single-node cluster: set number_of_replicas=0 on existing indices"
  elasticsearch_ensure_single_node_template || true

  for i in {1..30}; do
    health=$(curl -fsS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || true
    status=$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
    [[ $status == green ]] && break
    sleep 1
  done
  if [[ $status == green ]]; then
    opt_report "- Cluster health: green"
    return 0
  fi
  opt_report "- Cluster health: ${status:-unknown} after replica fix"
  return 1
}

# Restore the pre-run Elasticsearch tree after a failed restart.  opt_restore
# copies the backup over the live tree but does not remove files the failed
# run created; move the managed JVM file out of the live directory when it was
# not in the backup, so the restored heap file is the only owner.  Nothing is
# deleted.
elasticsearch_rollback() {
  local moved
  opt_restore /etc/elasticsearch elasticsearch
  opt_restore /etc/systemd/system/elasticsearch.service.d elasticsearch-systemd
  if [[ -n ${OPT_BACKUP_DIR:-} \
        && ! -e "${OPT_BACKUP_DIR}/elasticsearch/jvm.options.d/zz-setup-optimize.options" \
        && -e $ES_JVM_OPTIONS ]]; then
    moved=$(preserve_to_tmp "$ES_JVM_OPTIONS" 2>/dev/null || true)
    if [[ -n $moved ]]; then
      opt_report "- ROLLBACK: moved \`${ES_JVM_OPTIONS}\` to \`${moved}\` (not deleted)"
    fi
  fi
  systemctl daemon-reload || true
  systemctl restart elasticsearch 2>/dev/null || true
  return 0
}

optimize_elastic() {
  local active=0 yml=/etc/elasticsearch/elasticsearch.yml ram_mb heap_mb
  local jvm=$ES_JVM_OPTIONS
  local legacy=/etc/elasticsearch/jvm.options.d/jvm.options
  local unit=/etc/systemd/system/elasticsearch.service.d/limits.conf
  local es_before jvm_before legacy_before unit_before es_after jvm_after unit_after changed=0 i
  local es_url="" last_code="" code=""
  systemctl is-active --quiet elasticsearch 2>/dev/null && active=1
  opt_report "## Elasticsearch"
  opt_report "- Active: ${active}; config: \`${yml}\`"
  opt_backup /etc/elasticsearch elasticsearch
  opt_backup /etc/systemd/system/elasticsearch.service.d elasticsearch-systemd

  # Elasticsearch refuses to start when vm.max_map_count is too low.  The
  # installer wrote this once; ensure an existing/manually installed server
  # gets the same requirement during --optimize.
  if [[ $(sysctl -n vm.max_map_count 2>/dev/null || echo 0) -lt 1048576 ]]; then
    printf 'vm.max_map_count = 1048576\n' > /etc/sysctl.d/99-elasticsearch.conf
    sysctl -w vm.max_map_count=1048576 >/dev/null 2>&1 || true
    opt_report "- vm.max_map_count raised to 1048576"
  fi

  if [[ ${OPT_ES_BUDGET_MB:-0} -gt 0 ]]; then
    heap_mb=$OPT_ES_BUDGET_MB
  else
    ram_mb=$(mem_total_mb)
    heap_mb=$(( ram_mb * 25 / 100 ))
    (( heap_mb > 31744 )) && heap_mb=31744
    (( heap_mb < 512 )) && heap_mb=512
  fi
  heap_mb=$(( heap_mb / 512 * 512 ))
  (( heap_mb < 512 )) && heap_mb=512

  if (( ${OPT_ES_SIZE_MB:-0} == 0 )); then
    OPT_ES_SIZE_MB=$(elasticsearch_data_size_mb)
    [[ ${OPT_ES_SIZE_MB:-} =~ ^[0-9]+$ ]] || OPT_ES_SIZE_MB=0
  fi
  if (( OPT_ES_SIZE_MB > 0 )); then
    if (( heap_mb >= OPT_ES_SIZE_MB )); then
      opt_report "- Index store=${OPT_ES_SIZE_MB}MB; heap=${heap_mb}MB (fits)"
    elif (( ${OPT_ES_KEPT_MB:-0} > 0 )); then
      opt_report "- Index store=${OPT_ES_SIZE_MB}MB; heap=${heap_mb}MB (kept existing heap)"
    else
      opt_report "- Index store=${OPT_ES_SIZE_MB}MB; heap=${heap_mb}MB (does not fully fit; OS page cache serves the remainder)"
    fi
  fi

  es_before=$([[ -f $yml ]] && md5sum "$yml" | awk '{print $1}' || echo absent)
  jvm_before=$([[ -f $jvm ]] && md5sum "$jvm" | awk '{print $1}' || echo absent)
  legacy_before=$([[ -f $legacy ]] && md5sum "$legacy" | awk '{print $1}' || echo absent)
  unit_before=$([[ -f $unit ]] && md5sum "$unit" | awk '{print $1}' || echo absent)

  write_es_jvm_options "$heap_mb"

  # The installer comments http.host/transport.host so network.host controls
  # the bind; --optimize must do the same or an old 0.0.0.0 value survives.
  local active_bind=0 net_host=""
  if grep -qE '^[[:space:]]*(http\.host|transport\.host)[[:space:]]*:' "$yml"; then
    active_bind=1
  fi
  net_host=$(sed -nE 's/^[[:space:]]*network\.host[[:space:]]*:[[:space:]]*//p' "$yml" 2>/dev/null | head -n1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')

  # Drop a previous managed block so repeated runs stay idempotent, then let
  # the shared helper append the exact same performance block the installer
  # writes.
  elasticsearch_strip_managed "$yml"
  elasticsearch_write_performance_block "$yml"
  # The managed block comments http.host/transport.host, so the effective
  # endpoint is derived after it is written.  A node intentionally bound to a
  # public IPv4 for a remote XenForo client must be probed there, not on
  # 127.0.0.1.
  es_url=$(elasticsearch_http_url "$yml")
  opt_report "- HTTP endpoint: \`${es_url}\`"
  if (( active_bind )); then
    opt_report "- Commented active http.host/transport.host; network.host controls the bind"
  fi
  if [[ -n $net_host && $net_host != localhost && $net_host != 127.0.0.1 \
        && $net_host != "::1" && $net_host != "[::1]" ]] \
     && grep -qE '^[[:space:]]*xpack\.security\.enabled[[:space:]]*:[[:space:]]*false' "$yml" 2>/dev/null; then
    opt_report "- **WARNING**: Elasticsearch network.host=${net_host} with X-Pack security disabled; restrict TCP 9200/9300 to the remote client(s) or enable X-Pack security/TLS"
  fi

  elasticsearch_write_systemd_limits
  systemctl daemon-reload || true

  es_after=$([[ -f $yml ]] && md5sum "$yml" | awk '{print $1}' || echo absent)
  jvm_after=$([[ -f $jvm ]] && md5sum "$jvm" | awk '{print $1}' || echo absent)
  unit_after=$([[ -f $unit ]] && md5sum "$unit" | awk '{print $1}' || echo absent)
  [[ $es_before != "$es_after" || $jvm_before != "$jvm_after" \
     || $unit_before != "$unit_after" ]] && changed=1
  # Moving the legacy jvm.options file changes the effective heap without
  # changing the managed file, so count it as a change too.
  if [[ $legacy_before != "$([[ -f $legacy ]] && md5sum "$legacy" | awk '{print $1}' || echo absent)" ]]; then
    changed=1
    opt_report "- Moved legacy \`${legacy}\` to /tmp (superseded by zz-setup-optimize.options; not deleted)"
  fi
  if (( changed )); then
    opt_report "- Heap=${heap_mb}m; bootstrap.memory_lock=true; performance block written"
  else
    opt_report "- Heap=${heap_mb}m; configuration already optimized"
  fi

  if (( active )); then
    if (( changed == 0 )); then
      opt_report "- Restart: skipped (configuration already optimized)"
      elasticsearch_fix_single_node_replicas || return 1
      return 0
    fi
    if systemctl restart elasticsearch 2>/dev/null; then
      OPT_CUTOVER=1
      # Large heaps and many shards take time to become ready.  Probe the
      # endpoint the node was configured with; a remote-bound node will not
      # answer on loopback.
      local ready=0
      for i in {1..300}; do
        code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$es_url" 2>/dev/null || true)
        if [[ $code == 200 ]]; then
          ready=1
          break
        fi
        last_code=$code
        # Stop waiting early when the unit is gone, or when it is listening
        # on the configured address but this host cannot reach it (firewall
        # or NAT).  The latter is reported below, not rolled back.
        if ! systemctl is-active --quiet elasticsearch; then
          last_code="unit-inactive"
          break
        fi
        if [[ $code == 000 || -z $code ]] \
           && elasticsearch_listener_on "$es_url"; then
          break
        fi
        sleep 1
      done
      if (( ready )); then
        opt_report "- Restart: **OK**"
        elasticsearch_fix_single_node_replicas || return 1
      elif [[ $last_code == 000 || -z $last_code ]] \
           && systemctl is-active --quiet elasticsearch \
           && elasticsearch_listener_on "$es_url"; then
        # The unit restarted and owns the configured listener, but this host
        # cannot reach that address (firewall/NAT or a client-only allow
        # rule).  Do not roll back a healthy tune; report it instead.
        opt_report "- Restart: **OK** (unit active and listening on \`${es_url#*://}\`; HTTP probe from this host was unavailable — verify from the XenForo client)"
        opt_report "- Single-node replica check skipped: the HTTP endpoint was not reachable from this host"
      else
        opt_report "- Restart: **FAILED** (HTTP probe to \`${es_url}\` returned ${last_code:-no response}); rolling back"
        opt_restore /etc/elasticsearch elasticsearch
        opt_restore /etc/systemd/system/elasticsearch.service.d elasticsearch-systemd
        systemctl daemon-reload || true
        systemctl restart elasticsearch 2>/dev/null || true
        return 1
      fi
    else
      opt_report "- Restart: **FAILED**; rolling back"
      opt_restore /etc/elasticsearch elasticsearch
      opt_restore /etc/systemd/system/elasticsearch.service.d elasticsearch-systemd
      systemctl daemon-reload || true
      systemctl restart elasticsearch 2>/dev/null || true
      return 1
    fi
  else
    opt_report "- Restart: skipped (service was not active)"
  fi
  return 0
}

# Ports actually held by a process name, e.g. "80,443".  A systemd unit can
# be active while its worker processes never bound a socket (a stale master
# or a config-test-only reload), so check the kernel's listener table too.
opt_listen_ports() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltnp 2>/dev/null \
    | grep -F "(\"${1}\"" \
    | awk '{print $4}' | awk -F: '{print $NF}' \
    | grep -E '^[0-9]+$' | sort -nu | paste -sd, - || true
}

opt_listener_ok() {
  local listen=$1 port
  [[ -z $listen ]] && return 0
  if [[ $listen == /* ]]; then
    [[ -S $listen ]]
    return
  fi
  command -v ss >/dev/null 2>&1 || return 0
  port=${listen##*:}
  [[ $port =~ ^[0-9]+$ ]] || return 0
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

# Report (but do not fail on) error-level journal entries written after the
# optimize run started.  Probes below decide success; logs add context for
# warnings that do not take a service down.
opt_log_errors() {
  local unit=$1 label=$2 out line
  command -v journalctl >/dev/null 2>&1 || return 0
  [[ -n ${OPT_START_TS:-} ]] || return 0
  out=$(journalctl -u "$unit" --since "$OPT_START_TS" -p err -q --no-pager 2>/dev/null \
    | tail -n 3 || true)
  if [[ -n $out ]]; then
    opt_report "- ${label}: error-level journal entries since start (review):"
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | tr '`' "'")
      opt_report "  \`${line}\`"
    done <<< "$out"
  else
    opt_report "- ${label}: no error-level journal entries since start"
  fi
}

verify_optimized_services() {
  local rc=0 ver sock es_url code
  opt_report "## Verification"

  if [[ -x /usr/sbin/angie ]] && systemctl is-active --quiet angie; then
    if /usr/sbin/angie -t >/dev/null 2>&1; then
      local ports
      ports=$(opt_listen_ports angie)
      if [[ -n $ports ]]; then
        opt_report "- Angie: configuration valid; listening on \`${ports}\`"
      else
        opt_report "- Angie: **FAILED** active but no listening socket found"
        rc=1
      fi
    else
      opt_report "- Angie: **FAILED** configuration test while active"
      rc=1
    fi
    opt_log_errors angie Angie
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" php:"* ]]; then
    (( ${OPT_PHP_OK:-0} )) || opt_report "- PHP: no primary pool was optimized; Angie upstream left unchanged"
    local fpm_bin
    while IFS= read -r ver; do
      systemctl is-active --quiet "php${ver}-fpm" || continue
      sock=$(php_pool_listen "$ver")
      fpm_bin="/usr/sbin/php-fpm${ver}"
      if [[ -x $fpm_bin ]] && ! "$fpm_bin" -t >/dev/null 2>&1; then
        opt_report "- PHP ${ver}: **FAILED** configuration test"
        rc=1
      elif ! opt_listener_ok "$sock"; then
        opt_report "- PHP ${ver}: **FAILED** active but listener \`${sock:-unknown}\` is missing"
        rc=1
      else
        opt_report "- PHP ${ver}: active, listener \`${sock:-unknown}\`"
      fi
      opt_log_errors "php${ver}-fpm" "PHP ${ver}"
    done < <(php_fpm_versions)
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]] && systemctl is-active --quiet mariadb; then
    if mariadb -e 'SELECT 1' >/dev/null 2>&1; then
      opt_report "- MariaDB: active and accepting SQL"
    else
      opt_report "- MariaDB: **FAILED** active but SQL probe failed"
      rc=1
    fi
    opt_log_errors mariadb MariaDB
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" valkey "* ]] && systemctl is-active --quiet valkey-server; then
    if valkey-cli ping 2>/dev/null | grep -qx 'PONG'; then
      opt_report "- Valkey: active and responding to PING"
    else
      opt_report "- Valkey: **FAILED** active but PING failed"
      rc=1
    fi
    opt_log_errors valkey-server Valkey
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" redis "* ]] && systemctl is-active --quiet redis-server; then
    if redis-cli ping 2>/dev/null | grep -qx 'PONG'; then
      opt_report "- Redis: active and responding to PING"
    else
      opt_report "- Redis: **FAILED** active but PING failed"
      rc=1
    fi
    opt_log_errors redis-server Redis
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]] && systemctl is-active --quiet elasticsearch; then
    es_url=$(elasticsearch_http_url)
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$es_url" 2>/dev/null || true)
    if [[ $code == 200 ]]; then
      opt_report "- Elasticsearch: active and answering HTTP on \`${es_url}\`"
    elif [[ $code == 000 || -z $code ]] && elasticsearch_listener_on "$es_url"; then
      opt_report "- Elasticsearch: active and listening on \`${es_url#*://}\` (HTTP probe from this host unavailable; verify from the client)"
    else
      opt_report "- Elasticsearch: **FAILED** active but HTTP probe to \`${es_url}\` returned ${code:-no response}"
      rc=1
    fi
    opt_log_errors elasticsearch Elasticsearch
  fi
  (( rc == 0 )) || opt_report "- Result: **one or more health checks failed**"
  return "$rc"
}

write_optimize_report() {
  local file line
  # Nanoseconds keep two runs in the same second from overwriting each other.
  file="/var/log/setup-optimize-$(date +%Y%m%d-%H%M%S-%N).md"
  {
    echo "# setup.sh --optimize report"
    echo
    echo "- Generated: $(date -Is)"
    echo "- Host: $(hostname 2>/dev/null || echo unknown)"
    echo "- OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "- CPU: $(nproc) threads"
    echo "- RAM: $(awk '/^MemTotal:/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)"
    echo "- Disk: $(df -h / | awk 'NR==2{print $4 " free of " $2}')"
    echo "- Backup directory: \`${OPT_BACKUP_DIR:-none}\`"
    echo
    if (( ${#OPT_DETECTED[@]} == 0 )); then
      echo "No supported installed services were detected."
    else
      echo "Detected: ${OPT_DETECTED[*]}"
      echo
      for line in "${OPT_REPORT[@]}"; do
        printf '%s\n' "$line"
      done
    fi
  } > "$file"
  cp -f "$file" /var/log/setup-optimize-latest.md
  OPT_REPORT_WRITTEN=1
  printf '%s\n' "$file"
}

optimize_plan() {
  local nproc ram_mb size_mb max_children max_mb heap_mb backlog max_conn db_fit db_size_mb es_fit es_size_mb
  local governor_desc=performance disk_free_mb cache_mb
  nproc=$(nproc)
  ram_mb=$(mem_total_mb)
  backlog=$(effective_backlog)
  detect_installed_services
  plan_memory_budget
  cpu_performance_governor_available || governor_desc="skipped (no performance governor)"
  disk_free_mb=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $disk_free_mb =~ ^[0-9]+$ ]] || disk_free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
  [[ $disk_free_mb =~ ^[0-9]+$ ]] || disk_free_mb=10240
  cache_mb=$(angie_cache_budget_mb "$ram_mb" "$disk_free_mb")
  printf '\n%sDRY RUN%s - optimize scan only, no changes will be made.\n' "$C_BOLD" "$C_RESET"
  printf 'Host: %s  %s CPU  %s MB RAM  %s\n' "$(hostname 2>/dev/null || echo unknown)" \
    "$nproc" "$ram_mb" "$(df -h / | awk 'NR==2{print $4 " free"}')"
  printf '  OS: governor=%s limits=1M-nofile sysctl=hardware-scaled (%s CPUs / %sMB RAM)\n' \
    "$governor_desc" "$nproc" "$ram_mb"
  printf '  Legacy repair: nightly cron chown and /var/www/logs ownership\n'
  if (( ${#OPT_DETECTED[@]} == 0 )); then
    printf 'No supported installed services detected.\n'
    return 0
  fi
  printf 'Detected: %s\n' "${OPT_DETECTED[*]}"
  printf '  Memory: %sMB usable of %sMB (PHP=%sMB MariaDB=%sMB Cache=%sMB Elasticsearch=%sMB)\n' \
    "$OPT_MEM_BUDGET_MB" "$OPT_MEM_TOTAL_MB" "$OPT_PHP_BUDGET_MB" \
    "$OPT_MARIADB_BUDGET_MB" "$OPT_VALKEY_BUDGET_MB" "$OPT_ES_BUDGET_MB"
  if [[ " ${OPT_DETECTED[*]} " == *" angie "* ]]; then
    printf '  Angie: workers=auto connections=%s rlimit=%s keepalive=%s cache_budget=%sMB\n' \
      "$(tune_clamp $(( nproc * 2048 )) 8192 65535)" \
      "$(tune_clamp $(( nproc * 8192 )) 65536 524288)" \
      "$(tune_clamp $(( nproc * 2 )) 16 128)" \
      "$cache_mb"
  fi
  if [[ ${OPT_DETECTED[*]} == *php:* ]]; then
    if (( OPT_PHP_BUDGET_MB > 0 )); then
      max_children=$(( OPT_PHP_BUDGET_MB / 96 ))
    else
      max_children=$(( ram_mb * 50 / 100 / 96 ))
    fi
    (( max_children > nproc * 16 )) && max_children=$(( nproc * 16 ))
    (( max_children > 512 )) && max_children=512
    (( max_children < 8 )) && max_children=8
    printf '  PHP-FPM:  max_children=%s max_requests=%s backlog=%s\n' \
      "$max_children" "$(( nproc * 1024 ))" "$backlog"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]]; then
    size_mb=$OPT_MARIADB_BUDGET_MB
    mariadb_compute_profile "$size_mb"
    max_conn=$MARIADB_PROFILE_MAX_CONN
    db_size_mb=${OPT_DB_SIZE_MB:-0}
    db_fit=""
    if (( db_size_mb > 0 )); then
      if (( size_mb >= db_size_mb )); then
        db_fit=", database=${db_size_mb}MB (fits)"
      else
        db_fit=", database=${db_size_mb}MB (does not fully fit)"
      fi
    fi
    printf '  MariaDB: buffer_pool=%sMB max_connections=%s back_log=%s%s\n' \
      "$size_mb" "$max_conn" "$backlog" "$db_fit"
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" valkey "* || " ${OPT_DETECTED[*]} " == *" redis "* ]]; then
    max_mb=$OPT_VALKEY_BUDGET_MB
    if [[ " ${OPT_DETECTED[*]} " == *" redis "* ]]; then
      printf '  Redis: maxmemory=%sMB backlog=%s\n' "$max_mb" "$backlog"
    else
      printf '  Valkey: maxmemory=%sMB backlog=%s\n' "$max_mb" "$backlog"
    fi
  fi
  if [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]]; then
    heap_mb=$OPT_ES_BUDGET_MB
    (( heap_mb < 512 )) && heap_mb=512
    heap_mb=$(( heap_mb / 512 * 512 ))
    es_size_mb=${OPT_ES_SIZE_MB:-0}
    es_fit=""
    if (( es_size_mb > 0 )); then
      if (( heap_mb >= es_size_mb )); then
        es_fit=", index=${es_size_mb}MB (fits)"
      else
        es_fit=", index=${es_size_mb}MB (does not fully fit)"
      fi
    fi
    printf '  Elasticsearch: heap=%sMB%s\n' "$heap_mb" "$es_fit"
  fi
}

# ---------------------------------------------------------------------------
# Diagnostics: one read-only report for an OpenCode/analysis session
# ---------------------------------------------------------------------------
DIAG_FILE=""

diag_section() {
  printf '\n\n===== %s =====\n' "$*" >> "$DIAG_FILE"
}

# Run a command (or builtin) and append one titled section.  Every failure is
# recorded in the report instead of aborting the diagnostics run.
diag() {
  local title=$1
  shift
  diag_section "$title"
  "$@" >> "$DIAG_FILE" 2>&1 || true
}

# Same as diag(), for compound commands and pipelines.
diag_sh() {
  local title=$1 cmd=$2
  diag_section "$title"
  bash -c "$cmd" >> "$DIAG_FILE" 2>&1 || true
}

diag_tail_file() {
  local logfile=$1 nlines=${2:-300}
  [[ -f $logfile ]] || return 0
  diag_section "tail ${nlines}: ${logfile}"
  tail -n "$nlines" -- "$logfile" >> "$DIAG_FILE" 2>&1 || true
}

# Query PHP-FPM's pm.status_path over the FastCGI socket.  curl cannot speak
# FastCGI; the old probe sent HTTP to the socket and always ended with
# "Recv failure: Connection reset by peer".  cgi-fcgi is used when available,
# and a status path without .php is reported instead of being rejected by
# security.limit_extensions.
diag_php_fpm_status() {
  local pool="/etc/php/${1}/fpm/pool.d/www.conf" status=""
  if [[ ! -S /run/php/php-fpm.sock ]]; then
    printf 'FPM socket /run/php/php-fpm.sock is missing\n'
    return 0
  fi
  if ! command -v cgi-fcgi >/dev/null 2>&1; then
    printf 'cgi-fcgi is not installed; cannot query pm.status_path\n'
    return 0
  fi
  if [[ -r $pool ]]; then
    status=$(awk -F= '/^[[:space:]]*pm\.status_path[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pool")
  fi
  if [[ -z $status ]]; then
    printf 'pm.status_path is not configured in %s\n' "$pool"
    return 0
  fi
  if [[ $status != *.php ]] \
     && grep -qE '^[[:space:]]*security\.limit_extensions[[:space:]]*=[[:space:]]*\.php([[:space:]]|$)' "$pool" 2>/dev/null; then
    printf 'pm.status_path %s has no .php extension and security.limit_extensions=.php rejects it\n' "$status"
    return 0
  fi
  SCRIPT_FILENAME="$status" SCRIPT_NAME="$status" REQUEST_METHOD=GET \
    cgi-fcgi -bind -connect /run/php/php-fpm.sock 2>&1 || true
}

diag_tail_files() {
  local nlines=$1 f
  shift
  for f in "$@"; do
    diag_tail_file "$f" "$nlines"
  done
}

diag_angie_log_files() {
  {
    if [[ -x /usr/sbin/angie ]]; then
      /usr/sbin/angie -T 2>/dev/null | awk '
        $1 == "error_log" || $1 == "access_log" {
          path = $2
          sub(/;$/, "", path)
          if (path != "off" && path != "stderr") print path
        }
      ' || true
    fi
    printf '%s\n' /var/log/angie/error.log /var/log/angie/access.log
  } | awk '{ if ($0 !~ /^\//) $0 = "/etc/angie/" $0; print }' | sort -u
}

diag_angie_certificates() {
  local f
  {
    if [[ -x /usr/sbin/angie ]]; then
      /usr/sbin/angie -T 2>/dev/null | awk '
        $1 == "ssl_certificate" {
          path = $2
          sub(/;$/, "", path)
          print path
        }
      ' || true
    fi
    find /etc/angie/ssl -type f -name 'fullchain.pem' 2>/dev/null || true
  } | awk '{ if ($0 !~ /^\//) $0 = "/etc/angie/" $0; print }' | sort -u | while IFS= read -r f; do
    [[ -f $f ]] || continue
    printf -- '--- %s\n' "$f"
    if command -v openssl >/dev/null 2>&1; then
      openssl x509 -in "$f" -noout -subject -issuer -dates 2>&1
    else
      printf 'openssl is not installed\n'
    fi
  done
}

diag_php_log_files() {
  local ver=$1 pool="/etc/php/${1}/fpm/pool.d/www.conf" global="/etc/php/${1}/fpm/php-fpm.conf" f
  {
    for f in "$pool" "$global"; do
      [[ -r $f ]] || continue
      awk -F= '
        /^[[:space:]]*(slowlog|error_log|access\.log)[[:space:]]*=/ {
          value = $2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          sub(/[[:space:]]*;.*/, "", value)
          if (value != "" && value != "off" && value != "stderr") print value
        }
      ' "$f"
    done
    printf '%s\n' \
      /var/www/logs/php/php-fpm.log \
      /var/www/logs/php/php-fpm-slow.log \
      /var/www/logs/php/php-error.log \
      /var/log/php-fpm/www-slow.log \
      "/var/log/php${ver}-fpm.log"
  } | awk -v prefix="/etc/php/${ver}/fpm/" '
    { if ($0 !~ /^\//) $0 = prefix $0; print }
  ' | sort -u
}

diag_mariadb_log_files() {
  local logerr="" slow="" datadir=""
  if command -v mariadb >/dev/null 2>&1; then
    logerr=$(mariadb -N -B -e 'SELECT @@log_error' 2>/dev/null || true)
    slow=$(mariadb -N -B -e 'SELECT @@slow_query_log_file' 2>/dev/null || true)
    datadir=$(mariadb -N -B -e 'SELECT @@datadir' 2>/dev/null || true)
  fi
  {
    if [[ -n $logerr ]]; then
      if [[ $logerr == /* ]]; then
        printf '%s\n' "$logerr"
      else
        printf '%s\n' "${datadir%/}/$logerr"
      fi
    fi
    if [[ -n $slow ]]; then
      if [[ $slow == /* ]]; then
        printf '%s\n' "$slow"
      else
        printf '%s\n' "${datadir%/}/$slow"
      fi
    fi
    printf '%s\n' \
      /var/www/logs/mariadb/error.log \
      /var/www/logs/mariadb/slow.log \
      /var/log/mysql/error.log
  } | sort -u
}

diag_redis_log_files() {
  local cli value
  {
    for cli in valkey-cli redis-cli; do
      command -v "$cli" >/dev/null 2>&1 || continue
      value=$("$cli" CONFIG GET logfile 2>/dev/null | tail -n1 || true)
      if [[ -n $value ]]; then
        printf '%s\n' "$value"
      fi
    done
    printf '%s\n' /var/www/logs/valkey/valkey.log /var/log/redis/redis-server.log
  } | sort -u
}

diag_es_log_files() {
  find /var/log/elasticsearch /var/www/logs/elasticsearch \
    -maxdepth 1 -type f \( -name '*.log' -o -name '*.json' \) 2>/dev/null | sort -u || true
}

diag_redis_config() {
  local cli=$1 key
  command -v "$cli" >/dev/null 2>&1 || return 0
  if ! "$cli" ping >/dev/null 2>&1; then
    printf '%s is not responding\n' "$cli"
    return 0
  fi
  for key in save appendonly unixsocket unixsocketperm bind protected-mode maxmemory maxmemory-policy logfile dir; do
    printf -- '--- %s\n' "$key"
    "$cli" CONFIG GET "$key" 2>/dev/null || true
  done
}

# Return the installed Valkey/Redis service unit, if any.  A host can have the
# client package without a server, so the unit file is the authoritative
# "installed" signal for the diagnostics.
diag_redis_unit() {
  local u
  for u in valkey-server.service redis-server.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      printf '%s' "$u"
      return 0
    fi
  done
  return 1
}

# Return the server binary when a package is installed without a unit file.
diag_redis_server_bin() {
  local bin
  for bin in valkey-server redis-server; do
    command -v "$bin" >/dev/null 2>&1 && { printf '%s' "$bin"; return 0; }
  done
  return 1
}

# Return a client that can actually reach the running cache.  This avoids
# printing a connection-refused error for every Valkey/Redis section when the
# service is installed but stopped or protected by authentication.
diag_redis_cli() {
  local cli
  for cli in valkey-cli redis-cli; do
    command -v "$cli" >/dev/null 2>&1 || continue
    "$cli" ping >/dev/null 2>&1 && { printf '%s' "$cli"; return 0; }
  done
  return 1
}

# `_cluster/allocation/explain` returns HTTP 400 when every shard is already
# assigned.  Treat that as healthy instead of reporting a diagnostic error.
diag_elasticsearch_allocation() {
  local es_url=$1 health status unassigned
  health=$(curl -fsS --max-time 5 "${es_url}/_cluster/health" 2>/dev/null) || {
    printf 'Could not query %s/_cluster/health\n' "$es_url"
    return 0
  }
  status=$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
  unassigned=$(printf '%s' "$health" | sed -n 's/.*"unassigned_shards"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
  if [[ ${unassigned:-0} =~ ^[0-9]+$ ]] && (( unassigned == 0 )); then
    printf 'Cluster status: %s\n' "${status:-unknown}"
    printf 'No unassigned shards; allocation explain is not needed.\n'
    return 0
  fi
  curl -sS --max-time 5 -w '\nHTTP %{http_code}\n' \
    "${es_url}/_cluster/allocation/explain?pretty" | head -n 200
}

diag_angie_include_status() {
  local included f
  if [[ ! -x /usr/sbin/angie ]]; then
    printf 'Angie is not installed\n'
    return 0
  fi
  included=$(/usr/sbin/angie -T 2>/dev/null \
    | sed -n 's|^# configuration file /etc/angie/http\.d/\(.*\):$|\1|p' | sort -u)
  find /etc/angie/http.d -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | while IFS= read -r f; do
    if printf '%s\n' "$included" | grep -qxF -- "$f"; then
      printf 'ACTIVE   %s\n' "$f"
    else
      printf 'INACTIVE %s\n' "$f"
    fi
  done || true
}

# Diagnostics read journald, sudo records and service logs.  Redact common
# credential forms before the file is handed to an analysis agent.
redact_diagnostics() {
  local file=$1
  [[ -f $file ]] || return 0
  sed_in_place -E \
    -e 's/([A-Za-z_]*(pass|PASS|Pass|password|PASSWORD|Password)=)[^[:space:];]+/\1***/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|passwd|pwd)([[:space:]]*=[[:space:]]*)[^[:space:];]+/\1\2***/g' \
    -e 's/(MYSQL_PWD=)[^[:space:];]+/\1***/g' \
    -e 's/(REDISCLI_AUTH=)[^[:space:];]+/\1***/g' \
    -e "s/(IDENTIFIED BY ')[^']*(')/\1***\2/g" \
    -e 's/(IDENTIFIED BY ")[^"]*(")/\1***\2/g' \
    "$file" || true
}

run_diagnostics() {
  local out="${SCRIPT_DIR}/diagnostics.log"
  local u ver fpm_bin f es_url redis_unit redis_bin redis_cli redis_label
  local -a units=(angie mariadb valkey-server redis-server elasticsearch)

  umask 077
  if ! : > "$out" 2>/dev/null; then
    die "Could not write ${out}; run diagnostics from a writable checkout"
  fi
  chmod 600 "$out"
  DIAG_FILE=$out

  {
    printf '================================================================\n'
    printf ' setup.sh diagnostics\n'
    printf ' Script: %s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf ' Host  : %s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf ' Date  : %s\n' "$(date -Is 2>/dev/null || date)"
    printf '================================================================\n'
  } >> "$DIAG_FILE"

  # ---------------------------------------------------------------------------
  # Host, hardware and OS
  # ---------------------------------------------------------------------------
  diag "date" date -Is
  diag "hostname" hostname -f
  diag "uname" uname -a
  diag "uptime" uptime
  diag "os-release" cat /etc/os-release
  diag "virtualization" systemd-detect-virt
  diag "cpu" lscpu
  diag_sh "cpu model and flags" 'grep -m1 -E "^(model name|flags)" /proc/cpuinfo; grep -m1 "cpu cores" /proc/cpuinfo'
  diag "memory" free -m
  diag "meminfo" cat /proc/meminfo
  diag "block devices" lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,MOUNTPOINT
  diag "filesystems" df -hT
  diag "inodes" df -i
  diag "swap" swapon --show
  diag "mounts" mount
  diag "ulimits" bash -c 'ulimit -a'
  diag "boot parameters" cat /proc/cmdline
  diag "kernel modules" lsmod
  diag "thermal" bash -c 'command -v sensors >/dev/null && sensors || true'
  diag "load" cat /proc/loadavg
  diag "vmstat" vmstat 1 5
  diag_sh "I/O statistics" 'if command -v iostat >/dev/null; then iostat -xz 1 3; else echo "iostat not installed"; fi'
  diag_sh "per-CPU statistics" 'if command -v mpstat >/dev/null; then mpstat -P ALL 1 3; else echo "mpstat not installed"; fi'
  diag_sh "process I/O" 'if command -v pidstat >/dev/null; then pidstat -u -r -d 1 3; else echo "pidstat not installed"; fi'
  diag "top by CPU" bash -c 'ps -eo pid,ppid,user,%cpu,%mem,rss,etime,cmd --sort=-%cpu | head -40'
  diag "top by memory" bash -c 'ps -eo pid,ppid,user,%cpu,%mem,rss,etime,cmd --sort=-%mem | head -40'
  diag "top snapshot" bash -c 'top -b -n1 | head -60'

  # ---------------------------------------------------------------------------
  # Network and kernel tuning
  # ---------------------------------------------------------------------------
  diag "addresses" ip -br address
  diag "routes" ip route show table all
  diag "link statistics" ip -s link
  diag "socket summary" ss -s
  diag "listeners" ss -lntup
  diag "unix sockets" ss -lxnp
  diag "DNS" resolvectl status
  diag "qdisc" tc qdisc show
  diag_sh "ethtool statistics" 'for i in $(ls /sys/class/net); do [ "$i" = lo ] && continue; echo "--- $i"; ethtool -S "$i" 2>/dev/null | head -40; done'
  diag "sysctl all" sysctl -a
  diag "sysctl.conf" cat /etc/sysctl.conf
  diag_sh "sysctl drop-ins" 'find /etc/sysctl.d -maxdepth 1 -type f -print -exec sh -c "echo --- \$1; sed -n \"1,300p\" \"\$1\"" _ {} \;'
  diag "PAM limits" cat /etc/security/limits.conf
  diag_sh "PAM limit drop-ins" 'find /etc/security/limits.d -maxdepth 1 -type f -print -exec sh -c "echo --- \$1; cat \"\$1\"" _ {} \;'
  diag "modules-load" bash -c 'find /etc/modules-load.d -maxdepth 1 -type f -print -exec cat {} \;'

  # ---------------------------------------------------------------------------
  # Services, units and versions
  # ---------------------------------------------------------------------------
  diag "failed units" systemctl --failed --no-pager -l
  diag "all units" systemctl list-units --all --no-pager
  diag "unit files" systemctl list-unit-files --no-pager
  diag "timers" systemctl list-timers --all --no-pager
  diag "systemd blame" bash -c 'systemd-analyze blame | head -40'
  diag "systemd critical chain" systemd-analyze critical-chain

  while IFS= read -r u; do
    [[ -n $u ]] || continue
    units+=("$u")
  done < <(systemctl list-units --all --no-legend --no-pager 'php*-fpm.service' 2>/dev/null \
             | awk '{print $1}' | grep -E '^php.*-fpm\.service$' || true)

  for u in "${units[@]}"; do
    diag "systemctl status ${u}" systemctl status "$u" --no-pager -l
    diag "systemctl show ${u}" systemctl show "$u" \
      -p Id,Description,LoadState,ActiveState,SubState,MainPID,ExecMainPID,MemoryCurrent,CPUUsageNSec,TasksCurrent,TasksMax,LimitNOFILE,LimitMEMLOCK,LimitNPROC,Restart,RestartUSec
    diag "systemctl cat ${u}" systemctl cat "$u"
  done

  diag_sh "Angie version" 'if [ -x /usr/sbin/angie ]; then /usr/sbin/angie -V; else echo "Angie is not installed"; fi'
  diag_sh "Angie config test" 'if [ -x /usr/sbin/angie ]; then /usr/sbin/angie -t; else echo "Angie is not installed"; fi'
  diag_sh "Angie loaded configuration" 'if [ -x /usr/sbin/angie ]; then /usr/sbin/angie -T 2>&1 | head -n 3000; else echo "Angie is not installed"; fi'
  diag_sh "Angie vhosts" 'find /etc/angie/conf.d -maxdepth 1 -type f -name "*.conf" -printf "%f\n" 2>/dev/null | sort'
  diag "Angie certificates" diag_angie_certificates
  diag "Angie http.d include status" diag_angie_include_status
  diag_sh "Angie error/access log sizes" 'du -sh /var/www/logs/angie /var/log/angie 2>/dev/null || true'

  diag_sh "PHP CLI version" 'if command -v php >/dev/null 2>&1; then php -v; else echo "php CLI is not installed"; fi'
  diag_sh "PHP CLI modules" 'if command -v php >/dev/null 2>&1; then php -m; else echo "php CLI is not installed"; fi'
  diag_sh "PHP CLI ini" 'if command -v php >/dev/null 2>&1; then php --ini; else echo "php CLI is not installed"; fi'
  diag_sh "PHP-FPM versions" 'for d in /etc/php/*/fpm; do [ -d "$d" ] || continue; v=${d%/fpm}; v=${v##*/}; echo "--- PHP $v"; command -v "php-fpm$v" >/dev/null && "php-fpm$v" -v || /usr/sbin/php-fpm"$v" -v 2>&1; done'
  while IFS= read -r ver; do
    [[ -n $ver ]] || continue
    if command -v "php-fpm${ver}" >/dev/null 2>&1; then
      fpm_bin=$(command -v "php-fpm${ver}")
    else
      fpm_bin="/usr/sbin/php-fpm${ver}"
    fi
    diag "PHP ${ver} FPM version" "$fpm_bin" -v
    diag "PHP ${ver} FPM test" "$fpm_bin" -t
    diag "PHP ${ver} pool" cat "/etc/php/${ver}/fpm/pool.d/www.conf"
    diag "PHP ${ver} global config" cat "/etc/php/${ver}/fpm/php-fpm.conf"
    diag_sh "PHP ${ver} conf.d" "find /etc/php/${ver}/fpm/conf.d -maxdepth 1 -type f -print -exec sh -c 'echo --- \$1; cat \"\$1\"' _ {} \\;"
    diag_sh "PHP ${ver} processes" "ps -eo pid,ppid,user,%cpu,%mem,rss,etime,cmd | grep -E '[p]hp-fpm' | head -60"
    diag_sh "PHP ${ver} listeners" "ss -lxp | grep -E 'php${ver}|php-fpm' || true"
    diag "PHP ${ver} status" diag_php_fpm_status "$ver"
  done < <(php_fpm_versions)

  diag "MariaDB version" mariadb --version
  diag "MariaDB server version" mariadbd --version
  diag "MariaDB ping" mariadb-admin ping
  diag "MariaDB variables" mariadb -N -B -e 'SHOW GLOBAL VARIABLES'
  diag "MariaDB status" mariadb -N -B -e 'SHOW GLOBAL STATUS'
  diag "MariaDB processlist" mariadb -e 'SHOW FULL PROCESSLIST'
  diag "MariaDB InnoDB status" mariadb -e 'SHOW ENGINE INNODB STATUS\G'
  diag_sh "MariaDB database sizes" "mariadb -N -B -e \"SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS mb, COUNT(*) AS tables FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema ORDER BY mb DESC;\""
  diag_sh "MariaDB replication" "mariadb -e 'SHOW REPLICA STATUS\\G' 2>&1 || mariadb -e 'SHOW SLAVE STATUS\\G' 2>&1 || true"
  diag_sh "MariaDB extended status" 'mariadb-admin ext 2>&1 | head -300'
  diag_sh "MariaDB error log size" 'du -sh /var/www/logs/mariadb /var/log/mysql 2>/dev/null || true'
  diag "MariaDB resolved log files" diag_mariadb_log_files
  diag_sh "MariaDB config files" 'find /etc/mysql -maxdepth 3 -type f ! -name "debian.cnf" ! -name "*.pem" ! -name "*.key" ! -name "*.crt" -print -exec sh -c "echo --- \$1; sed -n \"1,200p\" \"\$1\"" _ {} \; 2>/dev/null | head -n 800'

  redis_unit=$(diag_redis_unit || true)
  redis_bin=$(diag_redis_server_bin || true)
  redis_cli=$(diag_redis_cli || true)
  if [[ -z $redis_unit && -z $redis_bin ]]; then
    diag_sh "Valkey/Redis" 'printf "%s\n" "Valkey/Redis is not installed (no valkey-server or redis-server service unit)."'
  elif [[ -z $redis_unit ]]; then
    diag_sh "Valkey/Redis" "printf 'Valkey/Redis is installed (%s) but has no systemd service unit.\\n' '${redis_bin}'"
  elif ! systemctl is-active --quiet "$redis_unit"; then
    diag "Valkey/Redis status" systemctl status "$redis_unit" --no-pager -l
    diag_sh "Valkey/Redis" "printf 'Valkey/Redis is installed (%s) but not running.\\n' '${redis_unit}'"
  elif [[ -z $redis_cli ]]; then
    diag "Valkey/Redis status" systemctl status "$redis_unit" --no-pager -l
    diag_sh "Valkey/Redis" "printf 'Valkey/Redis is running (%s) but no client can reach it.\\n' '${redis_unit}'"
  else
    redis_label=Valkey
    [[ $redis_cli == redis-cli ]] && redis_label=Redis
    diag "${redis_label} info" "$redis_cli" INFO all
    diag "${redis_label} config" "$redis_cli" CONFIG GET maxmemory
    diag "${redis_label} selected config" diag_redis_config "$redis_cli"
    diag "${redis_label} clients" "$redis_cli" CLIENT LIST
    diag "${redis_label} slowlog" "$redis_cli" SLOWLOG GET 100
    diag "${redis_label} memory stats" "$redis_cli" MEMORY STATS
    diag "${redis_label} latency" "$redis_cli" LATENCY LATEST
  fi
  diag "Valkey/Redis resolved log files" diag_redis_log_files

  es_url=$(elasticsearch_http_url)
  diag "Elasticsearch root" curl -fsS --max-time 5 "$es_url"
  diag "Elasticsearch health" curl -fsS --max-time 5 "${es_url}/_cluster/health?pretty"
  diag "Elasticsearch nodes" curl -fsS --max-time 5 "${es_url}/_cat/nodes?v"
  diag "Elasticsearch indices" curl -fsS --max-time 5 "${es_url}/_cat/indices?v&s=store.size:desc"
  diag_sh "Elasticsearch node stats" "curl -fsS --max-time 10 '${es_url}/_nodes/stats/jvm,os,indices,thread_pool?pretty' | head -n 500"
  diag "Elasticsearch allocation" diag_elasticsearch_allocation "$es_url"
  diag_sh "Elasticsearch YAML" 'if [ -f /etc/elasticsearch/elasticsearch.yml ]; then cat /etc/elasticsearch/elasticsearch.yml; else echo "Elasticsearch is not installed"; fi'
  diag_sh "Elasticsearch JVM options" 'find /etc/elasticsearch/jvm.options.d -maxdepth 1 -type f -print -exec sh -c "echo --- \$1; cat \"\$1\"" _ {} \; 2>/dev/null || true'
  diag_sh "Elasticsearch systemd limits" 'if [ -f /etc/systemd/system/elasticsearch.service.d/limits.conf ]; then cat /etc/systemd/system/elasticsearch.service.d/limits.conf; else echo "systemd drop-in is not installed"; fi'
  diag_sh "Elasticsearch log size" 'du -sh /var/www/logs/elasticsearch /var/log/elasticsearch 2>/dev/null || true'
  diag "Elasticsearch resolved log files" diag_es_log_files

  diag_sh "Node version" 'if command -v node >/dev/null 2>&1; then node -v; else echo "Node.js is not installed"; fi'
  diag_sh "npm version" 'if command -v npm >/dev/null 2>&1; then npm -v; else echo "npm is not installed"; fi'
  diag_sh "Node processes" 'ps -eo pid,ppid,user,%cpu,%mem,rss,etime,cmd | grep -E "[n]ode" | head -60'
  diag_sh "Node listeners" 'ss -lntp | grep -i node || true'
  diag_sh "Node service units" 'systemctl list-units --all --no-legend --no-pager "*node*.service" 2>/dev/null || true'

  # ---------------------------------------------------------------------------
  # Logs, slow logs and failed requests
  # ---------------------------------------------------------------------------
  diag "journal disk usage" journalctl --disk-usage
  diag_sh "recent journal warnings" 'journalctl --since "24 hours ago" -p warning --no-pager | tail -n 1200'
  for u in "${units[@]}"; do
    diag_sh "journal ${u} (24h)" "journalctl -u '${u}' --since '24 hours ago' -n 600 --no-pager 2>&1"
  done
  diag_sh "kernel OOM/hung tasks" 'journalctl -k --since "7 days ago" --no-pager 2>&1 | grep -iE "out of memory|oom|killed process|hung task|blocked for more|call trace" | tail -n 300'
  diag "dmesg" dmesg -T
  diag "syslog" tail -n 800 /var/log/syslog
  diag "kern.log" tail -n 500 /var/log/kern.log
  diag "auth.log" tail -n 300 /var/log/auth.log

  # Slow logs first: these matter most for application tuning.  Resolve the
  # live paths instead of assuming the /var/www/logs layout: old hosts still
  # write PHP-FPM to /var/log/php-fpm, Angie vhosts to their document root,
  # MariaDB to its datadir, and Elasticsearch to /var/log/elasticsearch.
  local -a log_files=()
  while IFS= read -r ver; do
    [[ -n $ver ]] || continue
    mapfile -t log_files < <(diag_php_log_files "$ver")
    diag_tail_files 800 "${log_files[@]}"
  done < <(php_fpm_versions)
  mapfile -t log_files < <(diag_mariadb_log_files)
  diag_tail_files 800 "${log_files[@]}"
  mapfile -t log_files < <(diag_angie_log_files)
  diag_tail_files 500 "${log_files[@]}"
  mapfile -t log_files < <(diag_redis_log_files)
  diag_tail_files 500 "${log_files[@]}"
  mapfile -t log_files < <(diag_es_log_files)
  diag_tail_files 500 "${log_files[@]}"
  diag_tail_file /var/www/logs/nodejs/nodejs.log 500
  diag_tail_file /var/www/logs/gifsicle/gifsicle.log 200

  while IFS= read -r f; do
    [[ -n $f ]] || continue
    diag_tail_file "$f" 200
  done < <(find /var/www/logs -type f \( -name '*.log' -o -name '*.json' \) 2>/dev/null | sort | head -n 120)

  diag_sh "log sizes" 'du -sh /var/www/logs/* /var/log/angie /var/log/php* /var/log/mysql /var/log/redis* /var/www/*/error.log /var/www/*/access.log 2>/dev/null | sort -h || true'
  diag_sh "web root ownership" 'ls -ld /var/www /var/www/logs /var/www/logs/* /var/www/mysql_database 2>/dev/null || true'
  diag_sh "log tree ownership" 'find /var/www/logs -maxdepth 2 -printf "%M %u:%g %p\n" 2>/dev/null | sort || true'
  diag_sh "logrotate debug" 'if command -v logrotate >/dev/null 2>&1 && [ -f /etc/logrotate.d/setup-logs ]; then logrotate -d /etc/logrotate.d/setup-logs; else echo "logrotate or /etc/logrotate.d/setup-logs is not installed"; fi'
  diag "cron" crontab -l
  diag "UFW status" ufw status verbose
  diag "UFW added rules" ufw show added
  diag "SSH effective config" sshd -T
  diag_sh "last logins" 'if command -v last >/dev/null 2>&1; then last -n 30; else echo "last is not installed"; fi'
  diag "who" who
  diag "apt upgradable" bash -c 'apt list --upgradable 2>/dev/null | head -100'
  diag_sh "installed service packages" 'dpkg -l | awk "\$1==\"ii\" && (\$2 ~ /^(angie|php|mariadb|valkey|redis|elasticsearch|nodejs|nginx)/){print \$2, \$3}"'
  diag_sh "setup state" 'find /var/lib/setup.sh -maxdepth 2 -type f -printf "%p %s bytes\n" 2>/dev/null | sort'
  diag_sh "cache and data sizes" 'du -sh /var/lib/mysql /var/lib/elasticsearch /var/cache/angie /home/nginx_cache* /var/cache/php/opcache 2>/dev/null | sort -h || true'

  redact_diagnostics "$DIAG_FILE"

  {
    printf '\n\n===== diagnostics complete =====\n'
    printf 'Finished: %s\n' "$(date -Is 2>/dev/null || date)"
    printf 'Size: %s\n' "$(du -h "$DIAG_FILE" 2>/dev/null | awk '{print $1}')"
  } >> "$DIAG_FILE"

  chmod 600 "$DIAG_FILE"
  printf '%s\n' "$DIAG_FILE"
}

# ---------------------------------------------------------------------------
# --restart-all: restart the whole installed stack in dependency order
# ---------------------------------------------------------------------------
list_active_php_units() {
  systemctl list-units --type=service --state=active --no-legend --no-pager \
    'php*-fpm.service' 2>/dev/null \
    | awk '{print $1}' | grep -E '^php.*-fpm\.service$' || true
}

restart_all_plan() {
  local unit
  local -a active=() php_units=()
  detect_installed_services
  mapfile -t php_units < <(list_active_php_units)
  for unit in angie mariadb valkey-server valkey redis-server elasticsearch; do
    systemctl is-active --quiet "$unit" 2>/dev/null && active+=("$unit")
  done
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
  local angie_active=0 angie_stopped=0 mariadb_active=0 mariadb_ok=0
  local elastic_active=0
  local -a php_units=() stopped_php=() cache_units=() failures=()
  local i

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
  for unit in valkey-server valkey redis-server; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      cache_units+=("$unit")
      break
    fi
  done
  systemctl is-active --quiet elasticsearch 2>/dev/null && elastic_active=1
  systemctl is-active --quiet mariadb 2>/dev/null && mariadb_active=1

  # Report installed-but-inactive units without starting them.
  for unit in angie mariadb valkey-server redis-server elasticsearch; do
    if ! systemctl is-active --quiet "$unit" 2>/dev/null \
       && systemctl cat "$unit" >/dev/null 2>&1; then
      info "Skipping ${unit}: installed but inactive"
    fi
  done

  # 1. Stop the request tiers, Angie first, then all active PHP versions.
  if (( angie_active )); then
    if systemctl stop angie 2>/dev/null; then
      angie_stopped=1
      info "Stopped Angie"
    else
      warn "Could not stop Angie"
      failures+=("stop angie")
      rc=1
    fi
  fi
  for unit in "${php_units[@]}"; do
    if systemctl stop "$unit" 2>/dev/null; then
      stopped_php+=("$unit")
      info "Stopped ${unit}"
    else
      warn "Could not stop ${unit}"
      failures+=("stop ${unit}")
      rc=1
    fi
  done

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
      if command -v mariadb >/dev/null 2>&1; then
        for i in {1..300}; do
          mariadb -e 'SELECT 1' >/dev/null 2>&1 && { mariadb_ok=1; break; }
          sleep 1
        done
      else
        warn "mariadb client not found; cannot verify SELECT 1"
      fi
      if (( mariadb_ok )); then
        info "MariaDB is accepting SQL"
      else
        if command -v mariadb >/dev/null 2>&1; then
          warn "MariaDB did not answer SELECT 1 within 300s"
        else
          warn "MariaDB was restarted but could not be probed (client missing)"
        fi
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
  for unit in "${stopped_php[@]}"; do
    if systemctl start "$unit" 2>/dev/null; then
      info "Started ${unit}"
    else
      warn "Could not start ${unit}"
      failures+=("start ${unit}")
      rc=1
    fi
  done
  if (( angie_stopped )); then
    if systemctl start angie 2>/dev/null; then
      info "Started Angie"
    else
      warn "Could not start Angie"
      failures+=("start angie")
      rc=1
    fi
  fi

  if (( rc == 0 )); then
    ok "All detected services restarted successfully"
  else
    warn "Restart completed with failures: ${failures[*]}"
  fi
  return "$rc"
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
      opt_report "- Cron: managed block ensured for installed services"
    fi
    if [[ -n $backup ]]; then
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
  opt_report "- CPU governor, PAM limits and kernel/network/memory sysctls tuned for ${OPT_MEM_TOTAL_MB}MB RAM / $(nproc) CPUs"
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
    return "$rc"
  fi
  info "Detected: ${OPT_DETECTED[*]}"
  info "Backups: ${OPT_BACKUP_DIR}"
  info "Memory budget: ${OPT_MEM_BUDGET_MB}MB usable of ${OPT_MEM_TOTAL_MB}MB (PHP=${OPT_PHP_BUDGET_MB}MB MariaDB=${OPT_MARIADB_BUDGET_MB}MB Cache=${OPT_VALKEY_BUDGET_MB}MB Elasticsearch=${OPT_ES_BUDGET_MB}MB)"
  opt_report "- Memory budget: ${OPT_MEM_BUDGET_MB}MB usable of ${OPT_MEM_TOTAL_MB}MB (PHP=${OPT_PHP_BUDGET_MB}MB MariaDB=${OPT_MARIADB_BUDGET_MB}MB Cache=${OPT_VALKEY_BUDGET_MB}MB Elasticsearch=${OPT_ES_BUDGET_MB}MB)"

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
  return "$rc"
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
  if (( OPTIMIZE || RESTART_ALL )); then
    if ! optimize_os_supported "${VERSION_ID:-}"; then
      die "--optimize/--restart-all supports Ubuntu 22.04, 24.04 or 26.04 (found ${VERSION_ID:-unknown})"
    fi
  elif (( ${VERSION_ID%%.*} < 26 )); then
    die "This script requires Ubuntu 26.04 or newer (found ${VERSION_ID})"
  fi

  # Size every service against one shared RAM budget on a fresh install, just
  # as --optimize does on an existing host.
  if (( ! OPTIMIZE && ! PURGE && ! RESTART_ALL )); then
    plan_install_budget
  fi

  if (( RESTART_ALL )); then
    printf '%s%sUbuntu %s service restart%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    if ! run_restart_all; then
      trap - ERR
      exit 1
    fi
    exit 0
  fi

  if (( OPTIMIZE )); then
    printf '%s%sUbuntu %s optimization%s\n' "$C_BOLD" "$C_BLUE" "${VERSION_ID}" "$C_RESET"
    if ! run_optimize; then
      # The report already explains the failure; suppress a duplicate ERR
      # trap message from this intentional non-zero exit.
      trap - ERR
      exit 1
    fi
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
    fetch_server_configs
  fi

  if [[ ${ENABLED[angie]:-0} -eq 1 ]];   then run_service angie   install_angie; fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]];     then run_service php     install_php; fi
  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then run_service mariadb install_mariadb; fi
  if [[ ${ENABLED[valkey]:-0} -eq 1 ]];  then run_service valkey  install_valkey; fi
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then run_service elastic install_elastic; fi
  if [[ ${ENABLED[others]:-0} -eq 1 ]];  then run_service others  install_others; fi
  if [[ ${ENABLED[domain]:-0} -eq 1 ]];  then run_service domain  create_domains; fi

  cleanup_configs
  if print_summary; then
    printf '\n%sAll installations completed successfully.%s\n' "$C_GREEN" "$C_RESET"
    exit 0
  else
    printf '\n%sOne or more installations failed. See the log above.%s\n' "$C_RED" "$C_RESET" >&2
    exit 1
  fi
}

# =============================================================================
# EMBEDDED PAYLOADS
# -----------------------------------------------------------------------------
# The data below was captured from the upstream files so that this script does
# not need to download them.  They are gzip-compressed and base64-encoded.
# =============================================================================

blob_sysctl() {
  base64 -d <<'B64' | gzip -dc
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
FXz7sZkSDjcq/nXi/z3CegAYHQAA
B64
}

blob_mysqltuner() {
  base64 -d <<'B64' | gzip -dc
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
B64
}

blob_mysqlbackup() {
  base64 -d <<'B64' | gzip -dc
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
B64
}

blob_angie_key() {
  base64 -d <<'B64' | gzip -dc
H4sIAAAAAAAC/42VZVQUCrtGhxlgSOkYQLoRpBkGhpAUEBAQJEe6u2tICZHu7pYUkFZQauiQ7m5p
pOQ755511vfv3vv3Xe/+96y904H46KY684FohIBDVZIjMKAiRwJTLvj5fOkh9wIgxf2Ef9Cck7fD
gHw60lQbW6uL3BLalMdyWJq5UR8z5Z2DlsXvMdEtleX+yam4+AdhSKNi4bqn6rvp8t6Axc1dP3lS
QwP8YFjt1SJKkDy68vb+fUvSiAI6QIyBL3TlPeDAMUMEUnXnYclWQkkbyPCO9MCk05deC593OWw7
HjqWX7wLeqIOFZmcTpTd7IRzHzc9WAOezE68rtLf/waaWVdnqj4ytuGrSODOesxfxhpAP0pkah9f
vqUpqOtOuhAfa1QlZLmuSJVW5FVk7MX6QB6j0ZyfQyH2ZBihgfsuKkLqlTp/thTtBFyEAzVyRHJi
F6qnZde/A0Ya44xJmiwxsUHNanIeYYQvB5u2+c+k84Z4Rvjnn5capg85mGhZyKBaJWU9uDHsjL/0
GvfHNBwNgdXZQ5SR5VPhQYR9UTQdlF1JrePNxtzYoNsu+MPne1erUZmM3TQMkVEO722qccM8+Au0
ZTm6XmZLshwY5Qq3XovAHuyPQMhjksQnOzDagoDHetaczNSO0FtxzSNSMquo8osl3QjmPaMIxQY1
2TPeAnL/q8b3IqKu2jLZO6fHoCj7NvQt5pCidObBTOzMToZfiahfK1xrr0MhNalNJq3qK0VPwTfS
g5SOTqz8cyi0T6GPnx8qUuBFW/jhekRhGrvcACI0AFoDp7SDpbU5PbumtaWDtYMlvbK5Nwe9uJm5
h6OTq5SbuakVj6eJq4sHj4u7RCRQFZ0EDQcAJWdAP4ipgaue1h2eK5oXGPu0eA2GZnhgAP9eFpAa
hIGLjQUGYpLhYGPhAtHJgSA0IC0akCIQgINN+O9ztCghoEgdMNkcJ7k5LThRBcOv1v0pB3OwVPHC
lCvQ48gj6T7KzqekC7LT/h0ZXuGmlzYvLsqKe8GP287jkUTMahI24AzML97JmN+AqeUHGcOYPgZi
Jh6gIX0mv6PZJ01jNHblDpDyelv53CY/slCa4UbJOLMFU8TLs0uivpJU3gH9sB1D/Z9+4ZHHpO+2
6goKJLBv3RGHgQ1++ih+BH94LN1ociz31D7bjB6oX458k4uZqc323IZ1bzgGlAgtIxbLySDzpdFt
0iod1T+VBevmLs639PVYzfZzt7iMY/4SdFJB6VU8d5FgCq42wckEmpZ8TJZcEUYAduFRiSU1aePK
unI1PQ07PyOam50sC2IyIY37P8Uz07nITn0CA14QbhF8nTz/cBBFsTI5j/q9GdEYeacp8l0j8s3F
868H1JsKH+4pvh+92lEoLFA6G0GWvWvLsQ3bcbOz4Dap8apFSA2CX/R3mJvsSBbnJrGzMW0IaLGX
OYjXcgoyTknLDBOLf9tnScNyvMZwmcJ0dhz7uRBAzSPAWLHNCe/6FOIItmWJS57haWJr3Wl9j757
xbm/kSG/WJDu8zG1UyO16APV0wCiJXWDrPdiQt4QuxkiDhIETMhDAu8SvaV4/xdieiRZt6dfL+7g
ji4ilvP21ce8lVJqe7nMijZUoOoq5AdAfnWfoyzgNa1pQMt/ZbTnfA/SWWg2aalWfVW5Z18h7/6B
nvuLQqrwjCTt8yQ333T9gQziTPI/i6s7wNVgpbe4LniPfsUVewLS3Qxmb8emT85BldKkwy9XBqoG
hEkqcwoxs133UfIPxYgJlshpI4GPK2KV+o16YDWfzRAMm+DzlsG55JBOPitzIfgKRjKC7el5D5qP
cyZZpP4TsZ4A60bwqa932aPXnCINH/bC6JsWdKrL+/M1o9xFxnkjBtIGQ7+uslPdGWYQRV7AGLvc
zmyoemHCbqZ+9E1QIbFDLSdWV6ZZj5JbW8/Fl60of7jQVOLxgMjyYPPWCVOZ2V09M/Oa/3GrlTqp
sacL0WytIEZFcsVaxoYQbGUnqb88V2LEdPtkMD02xXC7qnZdWbPPhjpnTWT8mKO5csHhSHGa2JW9
QC6en0ON8zWQvtf+ZSpt/V8bdELn8kRCUUpUu4sJZj1Ca0yQ4Rq0Xng2Zf07UvWAbS4gEuhTu4ah
xiT4ZtIW8+lsR+NHFhzSoc4AL5Qqfo1BDqNiCqC3sL5zi1ByuAVDpa6licN8tLMivckrzTxRskhG
GCbguG2rQRo/D1EXxpmkO9KuSzWFIEeLCRMR1KpDbW18Bp4nbVjYnYjg2Gkqm6EbiYTraJPZ3M63
NLsR/e+E+rw5SPoO8OICDIe7fzugzYynUNzOx0EaW/68VnP8HxlFotuhU/4lGPr/QzBAoNR/RdLl
Ro8O+Qt6+heU//3sE6VTlsXFndsNG008ucUAc90/0N/q+feiMErw6KoeqHAOdzsYQJgQiAnPnBuv
YnG0QykiIrE5levWpNbite9fTAS1SaGrKtxVCvOknl/wG6nO0lKr+Xu8HG6I1CSUdsQryF6/1Pyg
1Osmn4vqtZTQnCMBmdLQzr504Mw37c2AJye0ndvWHo0p9GdBjSTaeDJJq4s/3M4ExKDS5NqfnWB0
wfUVhILrNfVbV0abfoORnvv7MvdP3yVjPQXL3SqORYmscvEU4hLvJHSb4U7FXCdMfeqOum5JWKq9
D6t0fyJpn5oMBiIdWpUdlSInOF1PjfdFc2YFS6SOr24xsSNVzfaF0Nj3WYLxBvHL9tkFYYUArNuL
LGwbSHVEwJ8bjks+J72tz17fcxyK4aa2yF5MmHovFdvY6enHGwqoqhmg/Lr71WLvJ8UDzg3fwD4u
WNe9gLa3u3WyrttvIkmnA3jylh/yPTTyJ7zfP63J8kgwh/0+9Vgqo16wNysyp/24uKdvwSSyfONm
lx7+au65XCuXEiO/fryYRRVtJx31dEx1gOi0WqVSOd4mVzgrsqcwFK/9hQJ1tiMBIh5Sclo4OHsn
VpqgmTr3VKjACInMQVpizUz49BWHbFBtzx43YUs82j/bTys7SaNdV6SU6hpscTnWzcZzmj8rroNc
nvfE7Inuj88NPbXIXORgfxQ1HQYyrgatu3fGMFNXjl+/8ZWe4mV7JHjU2x6YNImwk35h6u369at5
ImeP0GaYXLuahkp7OQHveGj/D5bbF4ypapddF3o2DymGz5u14qlfRT+ax1uJU39FwsPqBMMmFAwo
Him6NPC8FPOqyG4dfPQDuopsg6aS5KuIftFdpstb8A+mUFCdoKvgSFrEHq6rsbz9JjykcmQJP46V
fnCWl9jvrslLm8rXWpeWsIJBN3E9JjjD+3htqTxZmd8ycsUkOJ3QNhKCQbJd0JZc5aqk51xQqqpG
An+xP5HJiSLvbbJuw3kHanpvKHGbDObw7W8he+4zkAc/4/kQ/ctYmePf2RSbzjqgNjL17Ar0YdOv
2hg58lRKRF88UtAjeovizkCewQBjiX4SOO0ouz35Ppch7U0gbs/1aAuNIMnAO235H1OdiH5LvdNv
1gDyggZqYytZY10V3UVRXZfsjWA/ErK4Zk7LC7fW0Kwmopg9riF/bg9rX+eQrsjYxcxmPwA5IfO1
SqCpzn6yD8iDjxl06epYIUcSoCl+1KydREu7LSb6y6S91CjfWLu7v5i41Q32FtwAFSVwqk4OLUX5
tNNUSrpF9xYlQF39MucE5JpOSvqauBK2YblpzsinlXpV9uy9+hyvKdfmQRzfsRyrowQcYozUT+4/
2vvyWZSbf7oKxJkhkjuPYYALejf+GlsfQ9DpP1EuprcGBMidzNsWUP6TnwXMv/JT5/la7jcbi4Kg
/Z1O76mKXgsRd7jst56pBAGRau+5mZ28bRddG8hSg0ogp2GwNEJyyqXEQucyhWB+s43uPPHPnacQ
mb/0I471yRobWeeGzF7/LxULRk6x9lfjsoyirdIXD2h1wxrrivR4P1f7BAOp1L85USPO2MOfieBt
xfuoh9DfldZpFTvsTgfq6YiSE/Gu6Ns8Q3vLVBjIh2MhyPGdK+TcJx2wTHdPqZD8fkFPDoUn2biW
ODtYix2r+Soq1UvP0KQ/AqTabYYDHa/5KFogs3EbGcrD+gKTmiTupb6M1+u+9yhOWJJuzuHajQHk
oZMCQ7gdX6c57wo2afjjKj4eUS5G2zrNsLHDwDaO/i4rKya7uOfQqGskun5648qP4VKIyYu1sc7T
GXp2tC5xGcgLT8iSatLBTXVOfTuiWD8XR+DnMODNq/2lESaMUaw+IOGsM3YIniWUH2YdCg4tXkuC
kuRt/vgtTXQ/jrz70QkZ7VsF4rW0FnQIvMmXSR7W7OW4YmB9NvEyybtG2ewVs3uoJZ+98kXXCLoX
W8oIO93klGh335HOCbsZkTf1ekmQkhLwGjviI7LMyylOfSZkGe7Ows+i1n44/mXYp1CWOccITQXF
T3pQigY+9z6TuUJ6K8XAXA7UgG9JqDSCtjXcKsF2Jz/U+zSkcnUjL5L7/NL1r77+v/OzgPm/5Gdq
xfB6qSWSEj/LhXB65Ed/k1Fo6D/Q3/n599LvTwgIqw56sQQ89avDsd385oY6Swxm2ObqUFH4/jaH
XDOwvOOrd9UHZjJpBusGfqQw0PmA22FdJrgSxFf1zDAp0TW8jl0QQaJLtYKfM8/8uyvX866kqy5k
0oBRy6tT9cJijl75ev1pg4d8TD7XJwkZVZhFkq0sXkKPBBWkUfT11CxVjZ1lwGZR+iU7xTI4Q2nL
MIO/jtrXuLz/2O1k5NpjqKTd7/toqxwDZ5kxntsLjHHFNS4z32DAdi80evExR8HRyPPndltGqTL0
i7uxjW9r+Miz97a4PcYxd4Ry0egd0Toeps4fIHW/PS6pfCwEHbUayHxIpcWZyvqnwUL11Wl+SorL
4ZIutwqgM0Ku5sLHFE8347NQb5s7QqNtJQmigRGjlGA3dJsJuv53KaouFN49EQGr4W8wq2SooBSa
U5DnjzSUQbGJa7UH0ih2CL7HF/GQ2zUiY+Y9QiqCB2lkGvjw1+qu+sdPhnIgqqn1gVerqO+zBFcX
MUV4IkvqslETxA8ORh9q2Jdv/wxXELDDqruo4cEWY7U5SzCtLtIfN6qvQXCpeeuHzA7d3yquymMs
g/alXAuh/XYsjzwiHHPho8SkM7Won3OINpivHder4entWzvhiZMI5SyRre68F9N7zbGmDMwLW0Tk
BBF1uk8OxqA2P2PQBlSWOcM+59FDSfq49U97IZOi+gSPakZFZzzRwv7c2qfrzUlf9H02mhI8IY2B
ob0NONYytKYCmOQdopZqLgl91YNVfaOQErMiUja7Xo4bvwTJPz1nomI/DPwqWFKlWMWrGb2dVmun
x4REdmoQP5fC3hR5PvcUlCsAzy1ogsSxkvn64u/6H64d5Wwt0ZsdrbjqyW+Ld0ng5IShj7OonND7
L6VoWnvKrLKHcYZtlXlX/oekWzZQVRRpAyvGsPvk0thouXx234H7ZkHW0tfqjrnhsPGvzcV0BnTO
iLuXfFwIZNgPuTjyXGaLdbdfh9mbneLlX8OP5JmpD+qnc6QowhO9uYhFgUTh2HkIokNEFWa6xf1R
VOPkrtRCoI6+gGzsFdukVBWny+dvHT+/PWnH2sKHZ1DbulQTTC+mBYGJlE1rx72kED3+vn6redwr
STF72O485QQKh9pKQ+zPn0VN1Azv2UgFDR/Hy8hzVMQ2IB86lJdU68S+9YF4A+0aImNXR2o/CyJa
ikI5zG8nEZVTVk5kk/7kwh/E1ERKECQqnADG+iotOi6mlPdW8LgMuhfH0zHpZEo3rlrm7tHA+3rS
vg3b0aKla93mcz5hNFJq5LGuVvCF1cFWkEjJngGCmC9qAtMca9yOSFnaapMkgtbG396669mAZvKK
bEWZUfReoRZrPgtsiFKpm+YqrXymNluCHlWyqD+7QfMf2Wb7YosRAAA=
B64
}

blob_elastic_key() {
  base64 -d <<'B64' | gzip -dc
H4sIAAAAAAAC/43VOc+rWBIG4JxfcXN0BRgwEHTAYd/35ZCxYzCYzYD96/vrTkbTLY2mwqp6s3pU
v3//FJAUzf7lKu4vNwKmJvwyJPgLmI5g/DX9jSCjJ9lA1kh1ewGBF1NxL2x9ugp3AcQh2ruwLV1N
cYcMt8zmNCfbsrSdmVztu7ugAxHh0UKRnfPTFRWT7yTde33Cn4RDlg3cDH6UPyi/kqYqWENMvrJt
1nkh1FphPafhUWIcIkTPh1eTN2o5nCK6ef7uUvIT/yZlU2ABG8Fvkiaa/NYX65A4K/chUZwROL6v
JT9MJUN6MpCJwHXQENDeqg6rp4JtTFG9yu8VBZ87i+134bDO1rOf6/OrOVwSotC+fwN0W9QKIaCB
5ZBeupdpdzOnYOrVlUEsDObCBsHeE1lGBFz/Bu4rjYkssYtLtpXT6TAbKs9KRG7DCBoStsJSm181
7zZemg9+ZEOQMx6X3AiBPXggAZ5XcD+KN5jaeJ7Y3yyRP/DWtogh/bsZ3Z5TMT7f2QeYWTrMmngN
WZo1BQm+nvLf+8hP4F2Q+uS+BhC2Xsh7Le/wWsGfWtoC2AEJ6sn2kQO53ZRHni2VzmXjF/aDgQNP
HxDuWDPgbbrAlyLwI0PwWhP4UOBPiec7Sub5ly7Z/wnh3UtFT5hmRhsXZHIgFM9jaEhofMPU1dnm
/UqzhfRZqu2OUcf9nYGpjvIl76LFSltT9lO6AsHKB0xxSFh/ISgA3oWus6xcwXnIdevXh0R8eSXe
53aQvRT3Z780gnHY3mUArsfgY5U7cWmlB1Kcs8jhlhtBxOhNoveFNCWXoL66SVmDbngyHutPOopG
wwyY6CZjGqDzdP1wUVJZ4XTa054iw/P2EPP4AWXKEu5XGNyot3na4i3Ycf3od/RSpLOoQHzMaJRh
g3LXlAFadJ0o7vs1YIioHn1UnWHzcbiCvpRimWhZJ6MfHwCbnEBOVYtdN9UPsTvTqqX2ZKG8BF46
a8PAiSRSCRA1HnWCv2ua93Ap6sv600oa7wSxXpKi/G5IcxujRpmjcRKWVzQyd2lZRvb6TLKkINlc
fkOhG07e9/dyKJsc25SDZO492g94iXsMER2kNVmmq8joSRbzm23Mh1snWDntDYGw7+wuXvqh8tgr
z7J77PZnpAR1/Kke7p41IdzK2mHF60m2c3Cf1IxTtqlZsaFUOYwgECFnSBXsoxJrg6MRY2ZYBW87
bFmfEHswjXsF3ZsBuF+Q/RXbSvR++GXjP/IX3iYXHiGZMh9vdX7uzPMlp7ey2FSZn7lk66FUBK+u
wCBuUPbwkTuTvVlNUW7SuaVu54dyqycnslHH/JZbbJDl53Titu3GLtHbumkLmwUsaXYJnhnulj9/
nvYU8ZL3c+JwAHbrwb/cINoPHPH/QMMdm/pPF12yqQjGr8Y+ETfVIlGK+MIXtzjUGq4PBtVg2AcA
08XQeW9Zm5kVpgozcXkvKtBu0nsl/f1CosBKDMKUavDd+lMMuU9c1rAeViAtUfzxrSCGPRrVmXHb
KLNIR66g+iuN9/xxjIPFI/3+naZqFZlhHNl8QKMtm5/Nff5xGHBhxnX9+bLGk35ZeXAPs8EMKQMq
Sf35qnoQgRSBjwHej20TvTcV6DgzEg2lfllCJznPKdXnRGu0Ghqs32FxJJeXPSktR97xlqbPZH7I
SB2FtfV5pbOzN80j6h7OXvhwGwMo4CIlV/RHnxxyIuZziuN4sxifF263taR7TDzZykcUTf0hXsKk
TkOYMEddnwYdbH8gfzR7gCN//y/JFv/Hc/sTTbIWDwIHAAA=
B64
}

blob_sury_deb() {
  base64 -d <<'B64' | gzip -dc
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
qF4MHAAA
B64
}

blob_nodesource_key() {
  base64 -d <<'B64' | gzip -dc
H4sIAAAAAAAC/32Vuc6j2haEc56ic9QygwETdLCBDWY0o8FkzJMxZjPz9Oc/rasr3eQuqaKqqLQ+
1e/fPydARbV+2Yr9yw4EQxV/6fD1SzAeov6v+xvDegdagpxLFgkEEUiJlV9UuqXnz5XIC8eqTq4W
KGv18emICra7xn3ewOxRCquMOu8mYLXlsdzM08V8n3Z4cJAYtym+01SqJ6c5FvwpbUNCJ0+1R0db
s95d5N/mHFKcZt/lwsQ81M38q7+TobmFmftgC+/FC7T9Tc5xqT9rmvS9sQRDG7nq3kloOFh5uwZ6
H1iei2gK42F741p3cEmBujCcXn6p1xVfZUU5vbWmgex8hfvIkONk3YERsPjNbo1SnXHGt9ckdDFf
wDsQf5y4S1THpD6I/NBDyyYd5QL/dcG71mjOSg7PCpapiNLpGNlbMLwY2RY+yzXGIN1I8TdRx01H
xFQEItcAcjeZ4t4w3XyQg8DdgQAFABRC7Rg/pfZvLIJb+rHWVHl3mBHmW0wIS0q574ziyay33kb/
Y/qsBoIrhBvUgVSJymaK9wqK8hWEquOuWRm8dbEWMG5G1yB11jCNmH5fqxkEYhKWymcLDNGp7qB6
PcWqU8VNhXKlSsABuuiC/+ax2SBE4UL4/oJYeol8Ox1xTXCgz7Yf+EwkZPXfu3o5KddcWpKlq/7g
xVncFIIlMtxXsfHsz7edZKnfKRkjMsRcRFRfTzijqXNd1maTuqxUHcRZeM9lnflQo30rFL5DyMCz
SzCS8wAdrXwANY8qDjfngFFyvqKA9iYp+O4CIXqzqaZGNTlx967huq16oq+19xc4HhH2QCfce6Ki
grbKu/QTo49/xKbARrfyVsb2QDiZcNirURSUNHd6AXEvfsvRsX7EM9sIjL/qV2Z9hx3M3bNvmhAo
XLWc8RG/lEx8MHDQaCOweWKsUe8E5ZTO2VkMMCS5H7Um5g61MdyE8Xm8MlIE8jswVMkqPDppvsv/
gCaOBFUtcz9NbNtI1MIQaw5cbKe1h5Lz1IxCt+TGO38xfX+Y3vUQXIwmqhNI7AwedPriphlaxPmY
PxTFpmjdJELIH5ijfF83MgZ768uLHnxVqUf3DKkXi48MZOg7yXchnOdJtS3tUa37TRsKt3hEVG20
WSpjZX/eClYida6I8bo1y4exS/x1Lmtne816Wm4loW2782TU2XHRkeMR7meA/hyrHDbaDXuePOWX
ZKNwMR4lU5LEcklp0rIPTZx48YtbE5pnxLcIzaOTJzdVtko6BFZGOLtfggCbXuCKXk/OXXr1EeTh
pwqPsD2fxyXTvRB44bVVGSCEEw7KwvXHPp5ZnBW4Qa1qJJA89h/SNODeoAKgCEAng/ff5n8A2sAP
B45B9iQeT+nVcO2zKnnZL21A5JRFcyM2LUyy0ukr1vCN/a6hTCc6FecHX+SfWhRK2+rrVXAtto/C
Zh8IadHh4Jjt89tFRI1GTODlHT430Y55/aItWnWa7mPkfJxzaZStuG+b+dbdUKuahdtsVC0bW4o0
Yrus3IXefMyE3korZZQuPlEvsMh1LjXKUTGruR/NQrS6QeXcklYe1A6Q4rBxRiE/vxo8LjH3u4ep
Nmz2TY49XCrSjPtW9DARqR7BaTTnZl6HTHw/wGJ/oq94EFf75/GJwEds/MwbFNYa9hhvHvKg62wj
1K62eT/SRtK300NsnwmBiwpa4cjFB1+uvkiqZ/jf8mkmeSawxWCECLtcS2EsWhBWf/5gf7aa6bC/
kwMt6f/s0T+9nREXtQYAAA==
B64
}

# Tests source this file with SETUP_TEST_SOURCE_ONLY=1 to exercise the pure
# helper functions without running an installation.
if [[ ${SETUP_TEST_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
