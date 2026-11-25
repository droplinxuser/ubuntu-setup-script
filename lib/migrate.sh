# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Globals defined here are read
# by other modules (optimize, diagnostics, restart, purge), so SC2034 is not
# meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# One-time migration to the 1.22 source-only stack (--optimize)
# ---------------------------------------------------------------------------
# A host provisioned by 1.21.x serves through Angie (download.angie.software),
# Sury PHP-FPM packages and the valkey-server package, optionally with the
# 1.21 compiled binaries started through zz-setup-build.conf drop-ins.  1.22
# serves through nginx, PHP and Valkey built from source.  This module moves
# a live host from the first to the second without a window where nothing
# serves, and keeps every step resumable:
#
#   0  controller: a transient unit (setup-migrate-1.22) runs the migration
#      with its output in /var/log/setup-migrate-1.22.log; the SSH session
#      only follows the log, so a dropped connection cannot kill a cutover.
#   1  scrub the 1.21 build knobs from /etc/default/setup-tuning
#   2  retire the 1.21 build TRIGGERS (timers, APT hooks, jobs, unit files)
#   3  read-only pre-flight: Angie-only and unbuilt directives, purge
#      collateral, disk, memory class, PHP extension union, pool listeners
#   4  build everything (build-only: nothing is activated), then a trial
#      nginx -t of a private copy of /etc/angie with the candidate, so real
#      blockers stop the nginx part before anything is purged or rendered
#   5  distro nginx packages away, /etc/nginx rendered from SCN + /etc/angie
#   6  Angie ACME -> the host self-signed pair (with a warning block)
#   7  nginx -t with the candidate, then the hardware profile
#   8  cutover Angie -> nginx (rollback to Angie on any failed probe)
#   9  PHP per active version (same-name unit handover, rollback to Sury)
#  10  Valkey (stop the package server first, then snapshot, rollback)
#  11  guarded removals under a policy-rc.d that denies only our unit names,
#      then the single re-lay / enable / assert / re-verify pass
#  12  report
#
# State: $STATE_DIR/migrate-1.22 (KEY=VALUE lines, rewritten atomically).
# Backups: /var/backups/setup-1.22 (0700 root, never deleted by setup.sh).
# The file-safety policy holds here too: nothing is unlinked; replaced or
# retired files are moved into the backups tree.

MIGRATE_STATE_FILE=${SETUP_MIGRATE_STATE_FILE:-${STATE_DIR:-/var/lib/setup.sh}/migrate-1.22}
MIGRATE_BACKUP_ROOT=${SETUP_MIGRATE_BACKUP_ROOT:-/var/backups/setup-1.22}
MIGRATE_LOG=${SETUP_MIGRATE_LOG:-/var/log/setup-migrate-1.22.log}
MIGRATE_UNIT=setup-migrate-1.22
MIGRATE_UNIT_DIR=${SETUP_MIGRATE_UNIT_DIR:-/etc/systemd/system}
MIGRATE_POLICY_RC=${SETUP_MIGRATE_POLICY_RC:-/usr/sbin/policy-rc.d}
MIGRATE_POLICY_MARK='# setup.sh-1.22 migrate policy-rc.d'
MIGRATE_ANGIE_ETC=${SETUP_MIGRATE_ANGIE_ETC:-/etc/angie}
# deploy_nginx_tree renders into /etc/nginx; the migration renders there too.
MIGRATE_NGINX_ETC=/etc/nginx
MIGRATE_PHP_ETC=${SETUP_MIGRATE_PHP_ETC:-/etc/php}
MIGRATE_VALKEY_ETC=${SETUP_MIGRATE_VALKEY_ETC:-/etc/valkey}
MIGRATE_VALKEY_DATA=${SETUP_MIGRATE_VALKEY_DATA:-/var/lib/valkey}
MIGRATE_LEGACY_TOOLS=${SETUP_MIGRATE_LEGACY_TOOLS:-/usr/local/lib/setup-1.21-legacy}
MIGRATE_BUILD_LOCK=${SETUP_BUILD_LOCK:-/run/setup-build.lock}
MIGRATE_APT_PIN=/etc/apt/preferences.d/setup-source-builds
# Marker for operator .ini lines the PHP cutover disables (R7).
MIGRATE_INI_OFF='; setup-1.22-off: '
# Marker for directives the ACME rewrite disables in /etc/nginx.
MIGRATE_ACME_OFF='# setup-1.22 acme->self-signed: '
# The 1.21 compiled-Angie fit marker; restored in the COPY only (R88/R94).
MIGRATE_ANGIE_FIT_MARK='# setup-angie-build-off: '

# The 1.21 build machinery, by its real (pre-rename) names.  The 1.22 units
# are setup-nginx-build.service, setup-php-build@X.Y.service,
# setup-valkey-build.service, setup-build-refresh.{service,timer} and
# setup-build-cpu.service.  setup-valkey-build.service is the one name both
# releases use, so it is retired only when its text is the 1.21 one.
MIGRATE_OLD_TIMERS=(setup-angie-build-refresh.timer setup-php-fpm-build-refresh.timer
                    setup-valkey-build-refresh.timer)
MIGRATE_OLD_UNITS=(setup-angie-build.service setup-angie-build-refresh.service
                   setup-php-fpm-build@.service setup-php-fpm-build-refresh.service
                   setup-valkey-build-refresh.service)
MIGRATE_OLD_VALKEY_UNIT_MARK='(setup.sh VALKEY_BUILD)'
MIGRATE_OLD_HOOKS=(/etc/apt/apt.conf.d/99setup-php-fpm-build /etc/apt/apt.conf.d/99setup-angie-build
                   /etc/apt/apt.conf.d/99setup-valkey-build)

# Directive classes for the pre-flight scan of /etc/angie (R26, R76, R88).
# A's lib may export NGINX_BUILD_DROPPABLE_RE / NGINX_BUILD_UNBUILT_RE; these
# defaults mirror the 1.22.1 configure line (tools/nginx-build.sh).
MIGRATE_NGINX_DROPPABLE_RE='^(gzip_static|brotli_static|sub_filter(_once|_types|_last_modified)?|ssi(_[a-z_]+)?|addition_types|add_before_body|add_after_body|limit_conn(_zone|_status|_log_level|_dry_run)?|userid(_[a-z_]+)?|autoindex(_[a-z_]+)?|random_index|gunzip(_buffers)?|mp4(_[a-z_]+)?|flv)$'
MIGRATE_NGINX_UNBUILT_RE='^(valid_referers|referer_hash_(max|bucket)_size|auth_request(_set)?|secure_link(_md5|_secret)?|slice|dav_(methods|access)|create_full_put_path|min_delete_depth|uwsgi_[a-z_]+|scgi_[a-z_]+|grpc_[a-z_]+|memcached_[a-z_]+|empty_gif|mirror(_request_body)?|split_clients|image_filter(_[a-z_]+)?|xslt_[a-z_]+|perl(_[a-z_]+)?|geoip_[a-z_]+|ancient_browser(_value)?|modern_browser(_value)?)$'
# Angie-only features nginx does not have.  `zone` in an upstream is NOT one
# (stock nginx has it; SCN's own local_php uses it, R76); acme/acme_client
# are not either: step 6 migrates them.
MIGRATE_NGINX_ANGIE_ONLY_RE='^(js_[a-z_]+|status_zone|api|sticky(_[a-z_]+)?|prometheus(_template)?|docker_endpoint|ntlm|least_time|queue|feedback|zone_sync[a-z_]*|acme_hook)$'

# PHP modules that are part of every build (base + always-on core), so the
# extension union never lists them (R2.8, R2.9, REVISION 3).
MIGRATE_PHP_BASE_EXTS=" core date hash json pcre random reflection spl standard lexbor uri cgi-fcgi
  ctype curl dom fileinfo filter gd iconv libxml mbstring mysqlnd openssl session simplexml zlib
  opcache zend_opcache phar posix pcntl tokenizer "
# Fallback when B's php_build_buildable_exts is not defined: extensions the
# source build can compile statically (bundled or in the recipe).
MIGRATE_PHP_BUILDABLE_FALLBACK=" mysqli pdo pdo_mysql exif zip xml xmlwriter xmlreader sodium redis
  igbinary gmp sqlite3 pdo_sqlite bcmath intl soap calendar ftp shmop sockets sysvmsg sysvsem
  sysvshm gettext ffi "

MIGRATE_REPORT=()
MIGRATE_IN_FLIGHT=""
MIGRATE_POLICY_OURS=0
MIGRATE_LOCK_FD=""
MIGRATE_RUN_DIR=""        # this run's snapshot directory under the backups root
MIGRATE_PREV_EXIT_TRAP=""
MIGRATE_FAILED=0
# Filled by the pre-flight.
MIGRATE_DO_NGINX=0
MIGRATE_DO_VALKEY=0
MIGRATE_PHP_TODO=()
MIGRATE_SIM_COLLATERAL=()
MIGRATE_SIM_REMOVED=()

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
migrate_report() { MIGRATE_REPORT+=("$*"); }
migrate_note() { info "migrate: $*"; migrate_report "- $*"; }
migrate_warn() { warn "migrate: $*"; migrate_report "- **WARNING** $*"; }
migrate_fail() { warn "migrate: $*"; migrate_report "- **FAILED** $*"; MIGRATE_FAILED=1; }
migrate_stamp() { date -u +%Y%m%dT%H%M%SZ; }
# The OUT reporter handed to nginx_build_ensure, php_build_ensure and
# valkey_build_ensure: they call "$out" "- line" (a function, never a file).
# The line goes to the migration report and to the unit's log.
migrate_out() {
  local l="$*"
  [[ -n $l ]] || return 0
  [[ $l == -* || $l == '#'* || $l == '    '* ]] || l="- ${l}"
  printf '%s\n' "$l"
  migrate_report "$l"
}

migrate_nginx_root()  { printf '%s' "${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx}"; }
migrate_php_root()    { printf '%s' "${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}"; }
migrate_valkey_root() { printf '%s' "${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}"; }

migrate_unit_file() { printf '%s/%s.service' "$MIGRATE_UNIT_DIR" "$1"; }

# 0 when PATH is a file some dpkg package owns.
migrate_dpkg_owned() { dpkg-query -S "$1" >/dev/null 2>&1; }

# Absolute path of the newest candidate of a component: the build-only
# staging tree first (step 4), the activated tree second.
migrate_nginx_bin() {
  local r b
  r=$(migrate_nginx_root)
  for b in "${NGINX_BUILD_STAGING:-$r/staging}/sbin/nginx" "$r/sbin/nginx"; do
    [[ -x $b ]] && { printf '%s' "$b"; return 0; }
  done
  return 1
}
migrate_php_active_bin() { printf '%s/%s/sbin/php-fpm' "$(migrate_php_root)" "$1"; }
migrate_php_cli_bin()    { printf '%s/%s/bin/php' "$(migrate_php_root)" "$1"; }
migrate_valkey_cli()     { printf '%s/bin/valkey-cli' "$(migrate_valkey_root)"; }

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
migrate_state_get() {
  [[ -f $MIGRATE_STATE_FILE ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' \
    "$MIGRATE_STATE_FILE"
}

migrate_state_set() {
  local key=$1 value=${2:-} f=$MIGRATE_STATE_FILE tmp
  # Recording a part's scan digest also records the code that judged it.
  [[ $key == *.scan ]] && [[ ${MIGRATE_STATE_CODE_REC:-0} != 1 ]] \
    && MIGRATE_STATE_CODE_REC=1 migrate_state_set "${key%.scan}.code" "$(migrate_code_digest)"
  mkdir -p "$(dirname "$f")"
  tmp="${f}.new.$$"
  {
    [[ -f $f ]] && awk -v k="$key" 'index($0, k "=") != 1' "$f"
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" || return 1
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
  # The history is for the operator and the next run's resume decisions.
  printf '%s %s=%s\n' "$(migrate_stamp)" "$key" "$value" >> "${f}.history" 2>/dev/null || true
}

# The code that recorded a part's blocked/rolled-back state.  Stored next to
# every <part>.scan, so a new release (a fixed migration) retries the part even
# when the host's configuration did not change (1.22.0 migration test: two
# fixes to the nginx pre-flight were never retried on an unchanged tree).
MIGRATE_SELF=${BASH_SOURCE[0]}
migrate_code_digest() {
  { printf '%s\n' "${SCRIPT_VERSION:-}"; cat -- "$MIGRATE_SELF" 2>/dev/null; } | md5sum | awk '{ print $1 }'
}

migrate_state_del() {
  local key=$1 f=$MIGRATE_STATE_FILE tmp
  [[ -f $f ]] || return 0
  grep -q "^${key}=" "$f" 2>/dev/null || return 0
  tmp="${f}.new.$$"
  awk -v k="$key" 'index($0, k "=") != 1' "$f" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# complete=0|1 (R65).  The refresh timer and the CPU chain (build-common's
# migration_pending) skip while the file exists without the finish marker.
# Besides complete=1 a bare 'complete' line is written, so a reader that
# matches the line `complete` (or `done`) and one that matches `complete=1`
# both see the same answer; the bare line is removed whenever complete=0.
migrate_complete_set() {
  local value=$1 f=$MIGRATE_STATE_FILE tmp
  mkdir -p "$(dirname "$f")"
  tmp="${f}.new.$$"
  {
    [[ -f $f ]] && awk '$0 != "complete" && $0 != "done" && index($0, "complete=") != 1' "$f"
    printf 'complete=%s\n' "$value"
    if [[ $value == 1 ]]; then printf 'complete\n'; fi
  } > "$tmp" || return 1
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
  printf '%s complete=%s\n' "$(migrate_stamp)" "$value" >> "${f}.history" 2>/dev/null || true
}

# Parts and their status, for diagnostics (R80).  Read-only.
migrate_status() {
  if [[ ! -f $MIGRATE_STATE_FILE ]]; then
    printf 'migration 1.22: not started (no %s)\n' "$MIGRATE_STATE_FILE"
    return 0
  fi
  printf 'migration 1.22 state (%s):\n' "$MIGRATE_STATE_FILE"
  sed 's/^/  /' "$MIGRATE_STATE_FILE"
  printf 'web server: %s\n' "$(web_server_state)"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$MIGRATE_UNIT" 2>/dev/null; then
    printf 'running now as %s (log %s)\n' "$MIGRATE_UNIT" "$MIGRATE_LOG"
  fi
  printf 'backups: %s\n' "$MIGRATE_BACKUP_ROOT"
}

# ---------------------------------------------------------------------------
# Backups (R37): one 0700 root tree, snapshot directories made with mktemp
# ---------------------------------------------------------------------------
migrate_backup_root_ensure() {
  install -d -m 700 -o root -g root "$MIGRATE_BACKUP_ROOT" 2>/dev/null \
    || mkdir -p "$MIGRATE_BACKUP_ROOT" || return 1
  # Forced on every run: an older directory may carry a wider mode.
  chown root:root "$MIGRATE_BACKUP_ROOT" 2>/dev/null || true
  chmod 700 "$MIGRATE_BACKUP_ROOT"
}

# New snapshot directory NAME-<stamp>-XXXX under the backups root.
migrate_snapshot_dir() {
  migrate_backup_root_ensure || return 1
  mktemp -d "${MIGRATE_BACKUP_ROOT}/${1}-$(migrate_stamp)-XXXX"
}

# This run's working directory (baselines, moved files).  Created once per
# process by migrate_run_dir_init: migrate_run_dir is usually called in a
# command substitution, where an assignment would not reach this shell.
migrate_run_dir_init() {
  if [[ -z $MIGRATE_RUN_DIR || ! -d $MIGRATE_RUN_DIR ]]; then
    MIGRATE_RUN_DIR=$(migrate_snapshot_dir run) || return 1
  fi
}
migrate_run_dir() {
  if [[ -z $MIGRATE_RUN_DIR || ! -d $MIGRATE_RUN_DIR ]]; then
    migrate_snapshot_dir run
    return
  fi
  printf '%s' "$MIGRATE_RUN_DIR"
}

# Move PATH into DEST, keeping its absolute path below DEST (so a restore is
# a plain cp -a back).  Missing paths are ignored.
migrate_stash() {
  local path=$1 dest=$2
  [[ -e $path || -L $path ]] || return 0
  mkdir -p "${dest}$(dirname "$path")" || return 1
  mv -- "$path" "${dest}${path}"
}

# Copy a tree into DEST keeping owner/mode/symlinks; ".absent" when missing.
migrate_copy_tree() {
  local src=$1 dest=$2
  if [[ -e $src || -L $src ]]; then
    mkdir -p "$(dirname "$dest")" && cp -a -- "$src" "$dest"
  else
    mkdir -p "$(dirname "$dest")" && : > "${dest}.absent"
  fi
}

# Exact restore: the live path becomes a byte copy of the snapshot (R15).
# The live tree is moved aside into the snapshot, never deleted.
migrate_restore_exact() {
  local snap=$1 live=$2 aside=${3:-}
  [[ -n $aside ]] || aside="${snap}.replaced-$(migrate_stamp)"
  if [[ -e $live || -L $live ]]; then
    mkdir -p "$(dirname "$aside")" && mv -- "$live" "$aside" || return 1
  fi
  if [[ -e $snap || -L $snap ]]; then
    cp -a -- "$snap" "$live" || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Disk (R31): free space per mount for builds and snapshots
# ---------------------------------------------------------------------------
migrate_mount_of() { df -P -- "$1" 2>/dev/null | awk 'NR == 2 { print $6 }'; }
migrate_free_mb() { df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }'; }
migrate_size_mb() {
  local p total=0 s
  for p in "$@"; do
    [[ -e $p ]] || continue
    s=$(du -sxk -- "$p" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }')
    total=$(( total + ${s:-0} ))
  done
  printf '%s' "$total"
}
# Usage ceiling in percent: 90 %, or 1 point under Elasticsearch's
# flood-stage watermark when ES is installed (an index going read-only is a
# worse outcome than postponing a migration part).
migrate_disk_ceiling_pct() {
  local flood=95 conf=/etc/elasticsearch/elasticsearch.yml v
  if [[ -r $conf ]]; then
    v=$(sed -nE 's/^[[:space:]]*cluster\.routing\.allocation\.disk\.watermark\.flood_stage:[[:space:]]*"?([0-9]+)%.*/\1/p' "$conf" | tail -n1)
    [[ $v =~ ^[0-9]+$ ]] && flood=$v
  fi
  if (( flood - 1 < 90 )); then printf '%s' $(( flood - 1 )); else printf '90'; fi
}

# 0 when NEED_MB fits on DIR's mount without crossing the ceiling.  Prints
# "mount free=..MB need=..MB" for the report either way.
migrate_disk_fits() {
  local dir=$1 need=$2 mount size_mb free ceiling headroom
  while [[ ! -e $dir && $dir != / ]]; do dir=$(dirname "$dir"); done
  mount=$(migrate_mount_of "$dir")
  free=$(migrate_free_mb "$dir")
  size_mb=$(df -Pk -- "$dir" 2>/dev/null | awk 'NR == 2 { printf "%d", $2 / 1024 }')
  ceiling=$(migrate_disk_ceiling_pct)
  [[ $free =~ ^[0-9]+$ && $size_mb =~ ^[0-9]+$ ]] || { printf '%s free=unknown need=%sMB' "${mount:-?}" "$need"; return 0; }
  # Space that may be used before the mount crosses the ceiling.
  headroom=$(( free - size_mb * (100 - ceiling) / 100 ))
  printf '%s free=%sMB need=%sMB (ceiling %s%%)' "$mount" "$free" "$need" "$ceiling"
  (( headroom >= need ))
}

# Measured on the Xeon test host (1.21.71 builds): LLVM from apt.llvm.org
# ~2.2 GB installed, an nginx tree ~0.9 GB, each PHP X.Y (FPM+CLI, static
# libs) ~2.4 GB, Valkey ~0.6 GB.  Build trees are deleted per component, but
# the peak is the sum while the caches are kept.
MIGRATE_DISK_LLVM_MB=2300
MIGRATE_DISK_NGINX_MB=1000
MIGRATE_DISK_PHP_MB=2500
MIGRATE_DISK_VALKEY_MB=700

# ---------------------------------------------------------------------------
# Memory class (section 7): F's mem_gate_allows when present
# ---------------------------------------------------------------------------
migrate_mem_allows() {
  local service=$1 kb
  if declare -F mem_gate_allows >/dev/null 2>&1; then
    mem_gate_allows "$service"
    return
  fi
  [[ $service == nginx ]] && return 0
  kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)
  [[ $kb =~ ^[0-9]+$ ]] || return 0
  (( kb / 1024 >= 3500 ))
}

# ---------------------------------------------------------------------------
# Package inventory and the collateral guard (R2.7, R9, R17, R30)
# ---------------------------------------------------------------------------
# Installed or config-files ("rc") packages, names without :arch.
migrate_dpkg_names() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 2>/dev/null \
    | awk -F'\t' '$1 ~ /^(ii|rc|hi|iU|iF|iH|hU|hF)/ { n = $2; sub(/:.*/, "", n); print n }' | sort -u || true
}
migrate_pkg_installed() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -qE '^(ii|hi|iU|iF|hU|hF)'; }

# Exact package list of one kind (never a glob handed to apt).
#   angie   angie and angie-module-*
#   sury    php, php-*, phpX.Y and phpX.Y-* plus debsuryorg-archive-keyring;
#           libapache2-mod-php* is NOT part of it, so the guard reports it
#           as collateral (Apache may serve through it, R17)
#   valkey  valkey-server valkey-tools
#   distro-nginx  nginx, nginx-common/core/full/light/extras, libnginx-mod-*,
#           python3-certbot-nginx (R30, R71)
migrate_pkg_list() {
  case $1 in
    angie)  migrate_dpkg_names | grep -E '^angie(-module-[a-z0-9.+-]+)?$' || true ;;
    sury)   migrate_dpkg_names | grep -E '^(php([0-9]+\.[0-9]+)?(-[a-z0-9.+-]+)?|debsuryorg-archive-keyring)$' || true ;;
    valkey) migrate_dpkg_names | grep -xE 'valkey-server|valkey-tools' || true ;;
    distro-nginx)
            migrate_dpkg_names | grep -xE 'nginx|nginx-(common|core|full|light|extras)|libnginx-mod-[a-z0-9.+-]+|python3-certbot-nginx' || true ;;
  esac
}

# Simulate ACTION (purge|remove) of PKGS.  Fills MIGRATE_SIM_REMOVED and
# MIGRATE_SIM_COLLATERAL (removed packages outside the list).  Returns 2
# when apt refuses (held package, broken dependency), 0 otherwise.
migrate_purge_sim() {
  local action=$1 sim rc=0 p
  shift
  MIGRATE_SIM_REMOVED=(); MIGRATE_SIM_COLLATERAL=()
  (( $# > 0 )) || return 0
  local -a opts=()
  declare -p APT_OPTS >/dev/null 2>&1 && opts=("${APT_OPTS[@]}")
  # Only packages this migration held itself (sury-held) may be simulated
  # through their hold; an operator's hold still makes apt refuse.
  [[ ${MIGRATE_SIM_ALLOW_HELD:-0} == 1 ]] && opts+=(--allow-change-held-packages)
  sim=$(apt-get -s "$action" "${opts[@]}" "$@" 2>&1) || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$sim" | tail -n 5 >&2 || true
    return 2
  fi
  mapfile -t MIGRATE_SIM_REMOVED < <(printf '%s\n' "$sim" | awk '/^(Remv|Purg) / { n = $2; sub(/:.*/, "", n); print n }' | sort -u)
  local -A want=()
  for p in "$@"; do want[$p]=1; done
  for p in "${MIGRATE_SIM_REMOVED[@]}"; do
    [[ -n ${want[$p]:-} ]] || MIGRATE_SIM_COLLATERAL+=("$p")
  done
  return 0
}

# The Sury purge pre-check (was php_purge_preflight in lib/services.sh).
# Fills MIGRATE_SURY_PKGS with the exact list and returns 0 when the purge
# may run; returns 1 with MIGRATE_SIM_COLLATERAL set when it may not.  Call
# it directly (not in $(...)): the globals must reach the caller.
# SETUP_PHP_ALLOW_COLLATERAL=1 accepts the collateral (the operator
# re-homes those applications).
MIGRATE_SURY_PKGS=()
migrate_sury_purge_preflight() {
  local allow=0 p held
  MIGRATE_SURY_PKGS=()
  MIGRATE_SIM_COLLATERAL=()
  mapfile -t MIGRATE_SURY_PKGS < <(migrate_pkg_list sury)
  (( ${#MIGRATE_SURY_PKGS[@]} > 0 )) || return 0
  # A deferred purge held the Sury packages (migrate_sury_defer).  Those
  # holds are ours and must not make the simulation fail; a hold the
  # operator set on any of them still does.
  held=" $(migrate_state_get sury-held) "
  if [[ $held != "  " ]]; then
    allow=1
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      [[ " ${MIGRATE_SURY_PKGS[*]} " == *" $p "* && $held != *" $p "* ]] && { allow=0; break; }
    done < <(apt-mark showhold 2>/dev/null | sed 's/:.*//' || true)
  fi
  MIGRATE_SIM_ALLOW_HELD=$allow migrate_purge_sim purge "${MIGRATE_SURY_PKGS[@]}" \
    || { MIGRATE_SIM_COLLATERAL=("(apt refused the simulation)"); return 1; }
  if (( ${#MIGRATE_SIM_COLLATERAL[@]} > 0 )) && [[ ${SETUP_PHP_ALLOW_COLLATERAL:-0} != 1 ]]; then
    return 1
  fi
  return 0
}

# 0 when a deferred removal of KIND (angie|valkey) could run now.
migrate_removal_possible() {
  local kind=$1 action=purge
  local -a pkgs=()
  [[ $kind == valkey ]] && action=remove
  mapfile -t pkgs < <(migrate_pkg_list "$kind")
  (( ${#pkgs[@]} > 0 )) || return 1
  migrate_purge_sim "$action" "${pkgs[@]}" && (( ${#MIGRATE_SIM_COLLATERAL[@]} == 0 ))
}

# 0 when a part in a failure state may be retried: never failed, its scan
# digest changed since, or the operator asks (SETUP_MIGRATE_RETRY=1).
# Interrupted and postponed parts always retry.
migrate_part_retry_ok() {
  local part=$1 digest=$2 st
  st=$(migrate_state_get "$part")
  case $st in
    blocked:*|rolled-back:*|failed:*|refused:*)
      [[ ${SETUP_MIGRATE_RETRY:-0} == 1 ]] && return 0
      [[ $(migrate_state_get "${part}.code") != "$(migrate_code_digest)" ]] && return 0
      [[ $(migrate_state_get "${part}.scan") != "$digest" ]] ;;
    *) return 0 ;;
  esac
}

# Save the installed .debs of PKGS (exact installed versions) into DIR while
# the repositories are still configured (R18).  Best effort; the manifest
# lists name=version either way.
migrate_save_debs() {
  local dir=$1 p ver deb found
  shift
  mkdir -p "$dir" || return 0
  for p in "$@"; do
    migrate_pkg_installed "$p" || continue
    ver=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) || continue
    printf '%s=%s\n' "$p" "$ver" >> "$dir/manifest"
    found=0
    for deb in /var/cache/apt/archives/"${p}_${ver//:/%3a}"_*.deb; do
      [[ -f $deb ]] || continue
      cp -p -- "$deb" "$dir/" && found=1
    done
    (( found )) && continue
    ( cd "$dir" && timeout 120 apt-get download -o APT::Sandbox::User=root -q "${p}=${ver}" >/dev/null 2>&1 ) \
      || printf '%s=%s (not downloadable)\n' "$p" "$ver" >> "$dir/manifest.missing"
  done
  return 0
}

# Real purge/remove of PKGS (already simulated).  Returns non-zero when apt
# fails.  Checks what dpkg really removed against the simulation (R17.7).
migrate_apt_remove() {
  local action=$1 before after p rc=0
  shift
  (( $# > 0 )) || return 0
  local -a opts=() extra=()
  declare -p APT_OPTS >/dev/null 2>&1 && opts=("${APT_OPTS[@]}")
  migrate_purge_sim "$action" "$@" || return 1
  local -a predicted=("${MIGRATE_SIM_REMOVED[@]}")
  before=$(migrate_dpkg_names | tr '\n' ' ')
  apt-get "$action" "${opts[@]}" "$@" || rc=$?
  after=$(migrate_dpkg_names | tr '\n' ' ')
  for p in $before; do
    [[ " $after " == *" $p "* ]] && continue
    [[ " ${predicted[*]} " == *" $p "* ]] && continue
    # rc packages purged by name show up here too; only real surprises count.
    extra+=("$p")
  done
  (( ${#extra[@]} == 0 )) || migrate_warn "apt ${action} also removed packages outside the simulation: ${extra[*]}"
  return "$rc"
}

# ---------------------------------------------------------------------------
# policy-rc.d (R21, R34): denies only the units this migration owns
# ---------------------------------------------------------------------------
migrate_policy_install() {
  local tmp
  if [[ -e $MIGRATE_POLICY_RC ]]; then
    grep -qF -- "$MIGRATE_POLICY_MARK" "$MIGRATE_POLICY_RC" 2>/dev/null && { MIGRATE_POLICY_OURS=1; return 0; }
    # An operator or image policy stays as it is; the single enable/assert
    # pass after the removals repairs what maintainer scripts touch (R2.2).
    migrate_note "kept the existing ${MIGRATE_POLICY_RC} (not ours); unit enablement is re-asserted after the removals"
    return 0
  fi
  tmp="${MIGRATE_POLICY_RC}.setup-new.$$"
  cat > "$tmp" <<EOF
#!/bin/sh
${MIGRATE_POLICY_MARK} $(migrate_stamp)
# Written by setup.sh for the duration of the 1.22 package removals so that
# maintainer scripts cannot stop or start the units setup.sh owns.  Every
# other service keeps its normal restart behaviour.  setup.sh removes this
# file when the removals end, and every later run removes it if a crash left
# it behind.
case "\$1" in
  nginx|nginx.service|angie|angie.service|php*-fpm|php*-fpm.service|valkey-server|valkey-server.service|valkey|valkey.service) exit 101 ;;
  *) exit 0 ;;
esac
EOF
  chmod 755 "$tmp" && mv -f "$tmp" "$MIGRATE_POLICY_RC" || return 1
  MIGRATE_POLICY_OURS=1
  migrate_state_set policy-rc "$MIGRATE_POLICY_RC"
}

# Remove our policy-rc.d (marker required).  Called by the EXIT trap, after
# the removals and at the start of every run (resume).
migrate_policy_remove() {
  [[ -f $MIGRATE_POLICY_RC ]] || { migrate_state_del policy-rc; return 0; }
  grep -qF -- "$MIGRATE_POLICY_MARK" "$MIGRATE_POLICY_RC" 2>/dev/null || return 0
  local dest
  dest=$(migrate_snapshot_dir policy-rc 2>/dev/null) || dest=""
  if [[ -n $dest ]]; then
    migrate_stash "$MIGRATE_POLICY_RC" "$dest" || true
  else
    mv -f -- "$MIGRATE_POLICY_RC" "$(tmp_dir)/" 2>/dev/null || true
  fi
  MIGRATE_POLICY_OURS=0
  migrate_state_del policy-rc
}

# ---------------------------------------------------------------------------
# Systemd helpers (R2.2)
# ---------------------------------------------------------------------------
migrate_fragment_path() { systemctl show -p FragmentPath --value "$1" 2>/dev/null || true; }

# Deb-systemd-helper bookkeeping for UNIT: a later purge or reinstall of a
# stray package would otherwise remove our links again.
migrate_clear_dsh_state() {
  local unit=$1 dest f
  dest=$(migrate_run_dir) || return 0
  while IFS= read -r -d '' f; do
    migrate_stash "$f" "$dest/deb-systemd-helper" || true
  done < <(find /var/lib/systemd/deb-systemd-helper-enabled /var/lib/systemd/deb-systemd-helper-masked \
             -name "*${unit}*" -print0 2>/dev/null || true)
}

# Enabled == "enabled", not masked, wants link resolves to our file (R2, R34).
migrate_assert_enabled() {
  local unit=$1 st link want
  want=$(migrate_unit_file "$unit")
  st=$(systemctl is-enabled "${unit}.service" 2>/dev/null || true)
  [[ $st == enabled ]] || { printf '%s is-enabled=%s' "$unit" "${st:-unknown}"; return 1; }
  link="${MIGRATE_UNIT_DIR}/multi-user.target.wants/${unit}.service"
  if [[ -L $link ]] && [[ $(readlink -f "$link") != "$want" ]]; then
    printf '%s wants link -> %s' "$unit" "$(readlink -f "$link")"; return 1
  fi
  [[ -f $want ]] || { printf '%s unit file missing' "$unit"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Config inventory
# ---------------------------------------------------------------------------
# Every file reachable from MAIN through include (globs expanded), MAIN first.
migrate_conf_closure() {
  local root=$1 main=$2 f inc m
  local -a queue=("$main")
  local -A seen=()
  while (( ${#queue[@]} > 0 )); do
    f=${queue[0]}; queue=("${queue[@]:1}")
    [[ -f $f && -z ${seen[$f]:-} ]] || continue
    seen[$f]=1
    printf '%s\n' "$f"
    while IFS= read -r inc; do
      [[ -n $inc ]] || continue
      [[ $inc == /* ]] || inc="$root/$inc"
      while IFS= read -r m; do
        [[ -n $m ]] && queue+=("$m")
      done < <(compgen -G "$inc" 2>/dev/null | sort || true)
    done < <(awk '{
        s = $0; sub(/#.*/, "", s)
        while (match(s, /(^|[;{} \t])include[ \t]+[^;]+;/)) {
          v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^[;{} \t]*include[ \t]+/, "", v); sub(/[ \t]*;$/, "", v); gsub(/["\047]/, "", v)
          print v
        }
      }' "$f" 2>/dev/null)
  done
}

# Server blocks of the vhost files under TREE/conf.d, one line each:
#   name TAB scheme TAB file TAB root TAB php(0|1) TAB auth-prefixes(,)
# Only blocks with an exact host name are listed (a wildcard or regex name
# cannot be probed).  scheme is https when the block listens on 443/ssl.
migrate_vhosts() {
  local tree=$1 f
  for f in "$tree"/conf.d/*.conf; do
    [[ -f $f ]] || continue
    awk -v file="$f" '
      function code(s) { sub(/#.*/, "", s); return s }
      {
        c = code($0)
        if (depth == 0 && c ~ /^[ \t]*server[ \t]*\{/) { inb = 1; name = ""; https = 0; root = ""; php = 0; auth = ""; loc = "" }
        if (inb) {
          if (name == "" && c ~ /(^|[ \t;{])server_name[ \t]/) {
            s = c; sub(/.*server_name[ \t]+/, "", s); sub(/;.*/, "", s)
            n = split(s, p, /[ \t]+/)
            for (i = 1; i <= n; i++) if (p[i] ~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/ && p[i] !~ /^[0-9.]+$/) { name = tolower(p[i]); break }
          }
          if (c ~ /(^|[ \t;{])listen[ \t]+[^;]*(443|ssl|quic)/) https = 1
          if (depth == 1 && root == "" && c ~ /(^|[ \t;{])root[ \t]+/) { s = c; sub(/.*root[ \t]+/, "", s); sub(/;.*/, "", s); gsub(/"/, "", s); root = s }
          if (c ~ /fastcgi_pass|php/) php = 1
          if (depth == 1 && c ~ /^[ \t]*location[ \t]+(=[ \t]+)?\/[^ \t{]*[ \t]*\{/) {
            loc = c; sub(/^[ \t]*location[ \t]+(=[ \t]+)?/, "", loc); sub(/[ \t]*\{.*/, "", loc)
          }
          if (loc != "" && c ~ /(^|[ \t;{])auth_basic[ \t]+/ && c !~ /auth_basic[ \t]+off/) { auth = auth (auth == "" ? "" : ",") loc; loc = "" }
        }
        o = gsub(/\{/, "{", c); cl = gsub(/\}/, "}", c); depth += o - cl
        if (inb && depth == 1 && cl > 0) loc = ""
        if (inb && depth == 0 && (o > 0 || cl > 0)) {
          if (name != "") printf "%s\t%s\t%s\t%s\t%d\t%s\n", name, (https ? "https" : "http"), file, root, php, auth
          inb = 0
        }
      }' "$f" 2>/dev/null || true
  done
}

# Status code of SCHEME://NAME/PATH answered by the local web server.  A
# cache-bypass cookie and header keep fastcgi/proxy caches out of it.
migrate_http_code() {
  local scheme=$1 name=$2 path=${3:-/} port=80 code
  [[ $scheme == https ]] && port=443
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -k \
           --resolve "${name}:${port}:127.0.0.1" -H 'Cache-Control: no-cache' \
           -b 'setup_probe=1; wordpress_logged_in_setupprobe=1' \
           "${scheme}://${name}${path}" 2>/dev/null) || true
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

# Record the status of every vhost (and every auth_basic prefix) into FILE.
migrate_baseline() {
  local tree=$1 out=$2 name scheme file root php auth a
  : > "$out"
  command -v curl >/dev/null 2>&1 || return 1
  # The catch-all answers too (often 444, which curl shows as 000).  Kind
  # "catchall": under Angie the PACKAGE's http.d/default.conf answered
  # Host: localhost with its welcome page (200); that file is never copied,
  # so under nginx the SCN catch-all closes it (444).  Compared leniently.
  printf 'localhost\thttp\t/\t%s\tcatchall\n' "$(migrate_http_code http localhost /)" >> "$out"
  while IFS=$'\t' read -r name scheme file root php auth; do
    [[ -n $name ]] || continue
    printf '%s\t%s\t/\t%s\t%s\n' "$name" "$scheme" "$(migrate_http_code "$scheme" "$name" /)" "$php" >> "$out"
    [[ -n $auth ]] || continue
    local -a prefixes=()
    IFS=, read -ra prefixes <<<"$auth"
    for a in "${prefixes[@]}"; do
      printf '%s\t%s\t%s\t%s\tauth\n' "$name" "$scheme" "$a" "$(migrate_http_code "$scheme" "$name" "$a")" >> "$out"
    done
  done < <(migrate_vhosts "$tree")
  return 0
}

# Compare the live answers with a baseline (R23, R87): the same status for
# every request, never 000 or 5xx, and 401 where it was 401.  Three tries
# per request ride out a cold cache.  Prints one line per mismatch.
migrate_compare_baseline() {
  local base=$1 name scheme path code kind now try bad=0
  while IFS=$'\t' read -r name scheme path code kind; do
    [[ -n $name ]] || continue
    for try in 1 2 3; do
      now=$(migrate_http_code "$scheme" "$name" "$path")
      [[ $now == "$code" ]] && break
      (( try < 3 )) && sleep 1
    done
    if [[ $now != "$code" ]]; then
      # The catch-all may close (000) or refuse (4xx) where the package
      # welcome page used to answer; it must still never 5xx.
      if [[ $kind == catchall ]] && [[ $now == 000 || $now == 4* ]]; then
        continue
      fi
      # A baseline that was itself 000/5xx cannot be held against the new
      # server, but the new one must not be worse than that.
      if [[ $code == 000 || $code == 5* ]] && [[ $now != 000 && $now != 5* ]]; then
        continue
      fi
      printf '%s://%s%s was %s, now %s\n' "$scheme" "$name" "$path" "$code" "$now"
      bad=1
    fi
  done < "$base"
  return "$bad"
}

# Byte offsets of the logs a PHP cutover watches (R58).
migrate_log_offsets() {
  local f
  for f in "${LOG_ROOT:-/var/www/logs}"/php/*.log "${LOG_ROOT:-/var/www/logs}"/nginx/error.log \
           "${LOG_ROOT:-/var/www/logs}"/angie/error.log; do
    [[ -f $f ]] || continue
    printf '%s\t%s\n' "$f" "$(stat -c %s -- "$f" 2>/dev/null || echo 0)"
  done
}
# Fatal lines written since the offsets in FILE.
migrate_log_fatals() {
  local offs=$1 f off
  while IFS=$'\t' read -r f off; do
    [[ -f $f ]] || continue
    tail -c "+$(( off + 1 ))" -- "$f" 2>/dev/null \
      | grep -E 'PHP Fatal|Class "?[A-Za-z0-9_\\]+"? not found|[Uu]ndefined function|Unable to load dynamic library' \
      | head -n 5 || true
  done < "$offs"
}

# ---------------------------------------------------------------------------
# web_server_state (R19, R51): nginx | angie-legacy | none
# ---------------------------------------------------------------------------
migrate_angie_present() {
  migrate_pkg_installed angie && return 0
  [[ -f $MIGRATE_ANGIE_ETC/angie.conf ]] \
    && { [[ -f /lib/systemd/system/angie.service || -f /usr/lib/systemd/system/angie.service ]]; }
}

web_server_state() {
  local st
  st=$(migrate_state_get nginx)
  case $st in
    done|cutover) printf 'nginx'; return 0 ;;
  esac
  if migrate_angie_present; then
    printf 'angie-legacy'; return 0
  fi
  if [[ -x "$(migrate_nginx_root)/sbin/nginx" && -f $MIGRATE_NGINX_ETC/nginx.conf ]]; then
    printf 'nginx'; return 0
  fi
  printf 'none'
}

# 0 while the migration unit runs (another run must only attach).
migrate_running() {
  [[ ${SETUP_MIGRATE_IN_UNIT:-0} == 1 ]] && return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$MIGRATE_UNIT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Parts present on this host
# ---------------------------------------------------------------------------
# Versions with a Sury (or Ubuntu) phpX.Y-fpm package installed.
migrate_sury_versions() {
  migrate_dpkg_names | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm$/\1/p' | while IFS= read -r v; do
    migrate_pkg_installed "php${v}-fpm" && printf '%s\n' "$v"
  done | sort -V || true
}
# The installed versions whose unit is running: the ones to migrate.
migrate_sury_active_versions() {
  local v
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && printf '%s\n' "$v"
  done < <(migrate_sury_versions)
  return 0
}
migrate_valkey_pkg_present() { migrate_pkg_installed valkey-server; }

# Where live vhosts are read from (R58): /etc/angie while Angie serves.
migrate_web_tree() {
  if [[ $(web_server_state) == angie-legacy ]]; then printf '%s' "$MIGRATE_ANGIE_ETC"; else printf '%s' "$MIGRATE_NGINX_ETC"; fi
}

# 0 when any 1.21 trigger, unit or APT hook is still on disk (R3).
migrate_old_triggers_present() {
  local u h
  for u in "${MIGRATE_OLD_TIMERS[@]}" "${MIGRATE_OLD_UNITS[@]}"; do
    [[ -e $MIGRATE_UNIT_DIR/$u ]] && return 0
  done
  compgen -G "${MIGRATE_UNIT_DIR}/setup-php-fpm-build@*.service" >/dev/null 2>&1 && return 0
  for h in "${MIGRATE_OLD_HOOKS[@]}"; do [[ -e $h ]] && return 0; done
  grep -qF -- "$MIGRATE_OLD_VALKEY_UNIT_MARK" "$MIGRATE_UNIT_DIR/setup-valkey-build.service" 2>/dev/null && return 0
  return 1
}

# The scan result digest of the nginx part, so a blocked part is retried only
# when the operator changed something (R19).
migrate_nginx_scan_digest() {
  [[ -f $MIGRATE_ANGIE_ETC/angie.conf ]] || { printf 'none'; return 0; }
  migrate_nginx_scan "$MIGRATE_ANGIE_ETC" "$MIGRATE_ANGIE_ETC/angie.conf" 2>/dev/null | md5sum | awk '{ print $1 }'
}

# migrate_needed [PART]: 0 when a part is pending, when a blocked part's
# cause may have changed, when a deferred purge can now run, or when 1.21
# triggers remain.  Terminal states (done, refused-mem with the same RAM
# class, blocked with the same scan) do not re-enter the migration.
# PART (nginx|php|valkey) limits the answer to that part's own states: the
# --upgrade-php gate asks `migrate_needed php` and must not be held up by a
# blocked nginx part, a deferred Angie purge or a Valkey postponed:disk (R19).
migrate_needed() {
  local part=${1:-all} st v
  case $part in nginx|php|valkey|all) ;; *) part=all ;; esac
  if [[ $part == all ]]; then
    migrate_old_triggers_present && return 0
    [[ -f $MIGRATE_POLICY_RC ]] && grep -qF -- "$MIGRATE_POLICY_MARK" "$MIGRATE_POLICY_RC" 2>/dev/null && return 0
    [[ -n $(migrate_state_get inflight) ]] && return 0
    case $(migrate_state_get removals) in
      started|pending|post-purge-failed) return 0 ;;
    esac
  else
    # A switch of this part in flight, or an interrupted Sury purge for PHP.
    case $(migrate_state_get inflight) in
      "$part"|"$part"-*) return 0 ;;
      purge) [[ $part == php && $(migrate_state_get sury-purge) == started ]] && return 0 ;;
    esac
  fi
  if [[ $part == all || $part == nginx ]] && migrate_angie_present; then
    st=$(migrate_state_get nginx)
    case $st in
      done)
        if [[ $part == all ]]; then
          case $(migrate_state_get angie-purge) in
            done) ;;
            deferred:*) migrate_removal_possible angie && return 0 ;;
            *) return 0 ;;
          esac
        fi ;;
      cutover) return 0 ;;  # finished forward by the next run (cron handover)
      blocked:*|rolled-back:*) migrate_part_retry_ok nginx "$(migrate_nginx_scan_digest)" && return 0 ;;
      *) return 0 ;;
    esac
  fi
  if [[ $part == all || $part == php ]]; then
    local php_done=0
    while IFS= read -r v; do
      [[ -n $v ]] || continue
      st=$(migrate_state_get "php-${v}")
      case $st in
        done) php_done=1 ;;
        refused-mem) migrate_mem_allows php && return 0 ;;
        refused:*|failed:*) migrate_part_retry_ok "php-${v}" "$(migrate_php_scan_digest "$v")" && return 0 ;;
        *) return 0 ;;
      esac
    done < <(migrate_sury_active_versions)
    if (( php_done )) && [[ -n $(migrate_pkg_list sury) ]]; then
      case $(migrate_state_get sury-purge) in
        done) ;;
        deferred:*) migrate_sury_purge_preflight >/dev/null 2>&1 && return 0 ;;
        post-purge-failed|failed:*|started) return 0 ;;
        *) [[ $part == all ]] && return 0 ;;
      esac
    fi
  fi
  if [[ $part == all || $part == valkey ]] && migrate_valkey_pkg_present; then
    st=$(migrate_state_get valkey)
    case $st in
      done)
        if [[ $part == all ]]; then
          case $(migrate_state_get valkey-remove) in
            done) ;;
            deferred:*) migrate_removal_possible valkey && return 0 ;;
            *) return 0 ;;
          esac
        fi ;;
      refused-mem) migrate_mem_allows valkey && return 0 ;;
      failed:*) migrate_part_retry_ok valkey "$(migrate_valkey_scan_digest)" && return 0 ;;
      *) return 0 ;;
    esac
  fi
  # Distro nginx on a host already migrated (or a leftover after a deferred
  # purge) is finished by the next run.
  if [[ $part == all ]] && [[ $(migrate_state_get nginx) == "done" ]] && [[ -n $(migrate_pkg_list distro-nginx) ]]; then
    return 0
  fi
  return 1
}

# 0 only while the PHP side of the migration is pending or in flight: the
# unit runs, a PHP switch or the Sury purge is in flight, a running Sury
# phpX.Y-fpm is not on our build yet (any state but done, including the
# refused ones: it is still a package unit), or a PHP part is done and the
# Sury purge has neither run nor been deferred.  A deferred purge
# (collateral the operator must clear) is not pending: nothing of it is
# half-done.  Unlike migrate_needed php it ignores retry digests, the
# nginx and Valkey parts and the Angie/distro-nginx leftovers.  Gate for
# --upgrade-php (C's php_upgrade_migration_pending).
migrate_php_pending() {
  local v st php_done=0
  migrate_running && return 0
  case $(migrate_state_get inflight) in
    php-*|purge) return 0 ;;
  esac
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    [[ $(migrate_state_get "php-${v}") == "done" ]] || return 0
  done < <(migrate_sury_active_versions)
  [[ -f $MIGRATE_STATE_FILE ]] && grep -qE '^php-[0-9]+\.[0-9]+=done$' "$MIGRATE_STATE_FILE" 2>/dev/null && php_done=1
  if (( php_done )) && [[ -n $(migrate_pkg_list sury) ]]; then
    st=$(migrate_state_get sury-purge)
    case $st in
      done|deferred:*) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

# ---------------------------------------------------------------------------
# migrate_resume_safe: first thing on every run (R21, R34, R50, R73)
# ---------------------------------------------------------------------------
# A crash, OOM kill or reboot cannot run traps.  Before anything else this
# removes our policy-rc.d, finishes an interrupted dpkg run and brings back
# the side of an interrupted switch that can serve.
migrate_resume_safe() {
  # A running migration owns the host; only the unit itself may resume.
  migrate_running && return 0
  [[ ${EUID:-0} -eq 0 ]] || return 0
  migrate_policy_remove || true
  # Leftovers of a run that died between writing and removing them.
  migrate_php_probe_cleanup
  migrate_nginx_test_shim_off
  local phase
  phase=$(migrate_state_get inflight)
  [[ -n $phase ]] || return 0
  migrate_run_dir_init || true
  warn "migrate: an earlier run stopped during '${phase}'; restoring a serving state first"
  case $phase in
    nginx|php-*|valkey)
      # A switch that was never verified is rolled back whole (the old
      # service, its configuration and data come back from the snapshot);
      # the part is retried by this or the next run.
      MIGRATE_IN_FLIGHT=$phase
      migrate_inflight_rollback || true
      ;;
    purge)
      # dpkg may hold a half-configured state; finish it, then the removal
      # phase runs forward again (re-lay, links, enable, verify).
      local i
      for i in $(seq 1 60); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        sleep 5
      done
      dpkg --configure -a || warn "dpkg --configure -a reported a problem"
      migrate_state_set removals pending
      ;;
  esac
  migrate_state_del inflight
  return 0
}

# Our own EXIT/INT/TERM handling while the migration runs.  The run ignores
# HUP and PIPE (R20, R50); a real termination rolls back the switch that was
# in flight, removes policy-rc.d and releases the build lock.
migrate_exit_hook() {
  local rc=$?
  trap '' HUP PIPE INT TERM
  if [[ -n $MIGRATE_IN_FLIGHT ]]; then
    warn "migrate: stopped during '${MIGRATE_IN_FLIGHT}' (exit ${rc}); rolling it back"
    migrate_inflight_rollback || true
  fi
  (( MIGRATE_POLICY_OURS )) && { migrate_policy_remove || true; }
  migrate_php_probe_cleanup
  migrate_nginx_test_shim_off
  migrate_lock_release
  if [[ -n $MIGRATE_PREV_EXIT_TRAP ]]; then
    eval "$MIGRATE_PREV_EXIT_TRAP"
    # Run the caller's handler as well (on_exit writes the run log footer).
    local prev
    prev=$(sed -E "s/^trap -- '(.*)' EXIT$/\1/" <<<"$MIGRATE_PREV_EXIT_TRAP")
    [[ -n $prev && $prev != "$MIGRATE_PREV_EXIT_TRAP" ]] && eval "$prev"
  fi
  return "$rc"
}

migrate_inflight_rollback() {
  local phase=${MIGRATE_IN_FLIGHT:-$(migrate_state_get inflight)}
  # An interruption is not a verdict on the part: it is retried (postponed),
  # unlike a failed verification, which waits for a changed scan.
  case $phase in
    nginx)  migrate_nginx_rollback "interrupted" || true; migrate_state_set nginx "postponed:interrupted" ;;
    php-*)  migrate_php_rollback "${phase#php-}" "interrupted" || true; migrate_state_set "$phase" "postponed:interrupted" ;;
    valkey) migrate_valkey_rollback "interrupted" || true; migrate_state_set valkey "postponed:interrupted" ;;
    purge)  : ;;  # forward on the next run (migrate_resume_safe)
  esac
  MIGRATE_IN_FLIGHT=""
  migrate_state_del inflight
}

migrate_inflight_set() {
  MIGRATE_IN_FLIGHT=$1
  migrate_state_set inflight "$1"
}
migrate_inflight_clear() {
  MIGRATE_IN_FLIGHT=""
  migrate_state_del inflight
}

# ---------------------------------------------------------------------------
# Build lock (R2.4, R65): held from step 4 to step 12.  The fd is inherited
# by our build tools; SETUP_BUILD_LOCK_HELD=1 tells build_lock_run and the
# tools not to take it again (they would deadlock on a second open).
# ---------------------------------------------------------------------------
migrate_lock_acquire() {
  [[ -n $MIGRATE_LOCK_FD ]] && return 0
  command -v flock >/dev/null 2>&1 || return 0
  [[ -L $MIGRATE_BUILD_LOCK ]] && { warn "Refusing symlinked build lock ${MIGRATE_BUILD_LOCK}"; return 1; }
  exec {MIGRATE_LOCK_FD}>>"$MIGRATE_BUILD_LOCK" || { MIGRATE_LOCK_FD=""; return 1; }
  if ! flock -w "${SETUP_MIGRATE_LOCK_WAIT:-3600}" "$MIGRATE_LOCK_FD"; then
    exec {MIGRATE_LOCK_FD}>&-
    MIGRATE_LOCK_FD=""
    return 1
  fi
  export SETUP_BUILD_LOCK_HELD=1
}
migrate_lock_release() {
  [[ -n $MIGRATE_LOCK_FD ]] || return 0
  flock -u "$MIGRATE_LOCK_FD" 2>/dev/null || true
  exec {MIGRATE_LOCK_FD}>&-
  MIGRATE_LOCK_FD=""
  unset SETUP_BUILD_LOCK_HELD
}

# ---------------------------------------------------------------------------
# Step 1: scrub persisted 1.21 knobs
# ---------------------------------------------------------------------------
migrate_scrub_knobs() {
  local f=${SETUP_TUNING_FILE:-/etc/default/setup-tuning} snap old
  [[ $(migrate_state_get knobs) == "done" ]] && return 0
  if [[ -f $f ]]; then
    # PHP_FPM_MODULES is recorded before it goes: it says whether 1.21 kept
    # every module in FPM (R25).
    old=$(sed -nE 's/^PHP_FPM_MODULES=//p' "$f" | tail -n1)
    [[ -n $old ]] && migrate_state_set php-fpm-modules-121 "$old"
    if grep -qE '^(PHP_BUILD|ANGIE_BUILD|VALKEY_BUILD|PHP_FPM_MODULES|NGINX_BUILD)=|^XF_MEMBER_GZIP=.?angie' "$f"; then
      snap=$(migrate_snapshot_dir tuning) || return 1
      cp -a -- "$f" "$snap/"
      sed_in_place -E -e '/^(PHP_BUILD|ANGIE_BUILD|VALKEY_BUILD|PHP_FPM_MODULES|NGINX_BUILD)=/d' \
        -e "s/^XF_MEMBER_GZIP=(['\"]?)angie(['\"]?)\$/XF_MEMBER_GZIP=\\1nginx\\2/" "$f"
      migrate_note "1.21 build knobs removed from ${f} (copy in ${snap})"
    fi
  fi
  migrate_state_set knobs "done"
}

# ---------------------------------------------------------------------------
# Step 2: retire the 1.21 build triggers (R3, R10, REVISION 3 step 2)
# ---------------------------------------------------------------------------
# Triggers (timers, APT hooks, rebuild/refresh units, running jobs and the
# transient fallback units) go first and for good.  The tools a 1.21
# zz-setup-build.conf drop-in still calls on every start/reload (php-fpm
# `conf` mirrors conf.d, the valkey/angie `pre` gate) cannot simply be
# deleted while that drop-in serves: a reload in the build window would then
# fail and take PHP down.  They move to /usr/local/lib/setup-1.21-legacy and
# the drop-in is pointed there, which also frees the shared roots for the new
# tools (same file names: build-common.sh, php-build.conf, valkey-build.sh).
# The drop-in and the old binary layout leave at that service's cutover.
migrate_retire_triggers() {
  local u t h dest changed=0 unit_list
  dest=$(migrate_snapshot_dir retired-1.21) || return 1
  # (a) triggers
  for t in "${MIGRATE_OLD_TIMERS[@]}"; do
    [[ -e $MIGRATE_UNIT_DIR/$t ]] || continue
    systemctl disable --now "$t" >/dev/null 2>&1 || true
    changed=1
  done
  for h in "${MIGRATE_OLD_HOOKS[@]}"; do
    [[ -e $h ]] || continue
    migrate_stash "$h" "$dest" && changed=1
  done
  # (b) running jobs, including the transient fallback units
  unit_list=$(systemctl list-units --all --plain --no-legend \
      'setup-php-fpm-build@*' 'setup-php-fpm-build-refresh*' 'setup-angie-build*' \
      'setup-valkey-build-refresh*' 'setup-angie-fallback-*' 'setup-php-fpm-fallback-*' \
      'setup-valkey-fallback-*' 2>/dev/null | awk '{ print $1 }' || true)
  if grep -qF -- "$MIGRATE_OLD_VALKEY_UNIT_MARK" "$MIGRATE_UNIT_DIR/setup-valkey-build.service" 2>/dev/null; then
    unit_list+=$'\n'setup-valkey-build.service
  fi
  while IFS= read -r u; do
    [[ -n $u ]] || continue
    timeout 180 systemctl stop "$u" >/dev/null 2>&1 \
      || systemctl kill -s KILL "$u" >/dev/null 2>&1 || true
    changed=1
  done <<<"$unit_list"
  # (c) unit files
  for u in "${MIGRATE_OLD_TIMERS[@]}" "${MIGRATE_OLD_UNITS[@]}"; do
    [[ -e $MIGRATE_UNIT_DIR/$u ]] || continue
    migrate_stash "$MIGRATE_UNIT_DIR/$u" "$dest" && changed=1
  done
  for u in "$MIGRATE_UNIT_DIR"/setup-php-fpm-build@*.service; do
    [[ -e $u ]] && migrate_stash "$u" "$dest" && changed=1
  done
  if grep -qF -- "$MIGRATE_OLD_VALKEY_UNIT_MARK" "$MIGRATE_UNIT_DIR/setup-valkey-build.service" 2>/dev/null; then
    migrate_stash "$MIGRATE_UNIT_DIR/setup-valkey-build.service" "$dest" && changed=1
  fi
  # (d) old tools: relocated while a drop-in calls them, retired otherwise
  migrate_relocate_legacy_tool php "$(migrate_php_root)" php-fpm-build.sh php-build.conf PHP_BUILD_CONF "$dest" && changed=1
  migrate_relocate_legacy_tool valkey "$(migrate_valkey_root)" valkey-build.sh valkey-build.conf VALKEY_BUILD_CONF "$dest" && changed=1
  # D's own sweep of the 1.21 Valkey triggers (hook, refresh units, fallback
  # units); after the moves above it usually finds nothing left.
  if declare -F valkey_build_retire_legacy >/dev/null 2>&1; then
    valkey_build_retire_legacy >/dev/null 2>&1 || true
  fi
  if (( changed )); then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    migrate_note "1.21 build triggers retired (timers, APT hooks, rebuild units; copies in ${dest})"
  else
    rmdir "$dest" 2>/dev/null || true
  fi
  migrate_state_set triggers retired
  if migrate_old_triggers_present; then
    migrate_fail "a 1.21 build trigger is still present after retirement; the cutovers are refused until it is gone"
    return 1
  fi
  return 0
}

# KIND ROOT TOOL CONF CONFVAR DEST: returns 0 when something moved.
migrate_relocate_legacy_tool() {
  local kind=$1 root=$2 tool=$3 conf=$4 confvar=$5 dest=$6 legacy d f moved=1
  [[ -f $root/$tool ]] || return 1
  # The 1.22 valkey tool has the same name: only the 1.21 one is relocated.
  grep -qE 'SETUP_(PHP|VALKEY)_BUILD=clang' "$root/$tool" 2>/dev/null || return 1
  legacy="${MIGRATE_LEGACY_TOOLS}/${kind}"
  local -a dropins=()
  for d in "$MIGRATE_UNIT_DIR"/*.service.d/zz-setup-build.conf; do
    [[ -f $d ]] && grep -qF -- "$root/$tool" "$d" && dropins+=("$d")
  done
  if (( ${#dropins[@]} == 0 )); then
    for f in "$tool" build-common.sh "$conf"; do
      [[ -e $root/$f ]] && migrate_stash "$root/$f" "$dest" && moved=0
    done
    return "$moved"
  fi
  install -d -m 755 "$legacy" || return 1
  for f in "$tool" build-common.sh "$conf"; do
    [[ -e $root/$f ]] || continue
    cp -a -- "$root/$f" "$legacy/$f" && migrate_stash "$root/$f" "$dest"
  done
  for d in "${dropins[@]}"; do
    cp -a -- "$d" "$dest/$(basename "$(dirname "$d")").zz-setup-build.conf.orig" 2>/dev/null || true
    sed_in_place -e "s#${root}/${tool}#${legacy}/${tool}#g" "$d"
    grep -q "^Environment=${confvar}=" "$d" || printf 'Environment=%s=%s/%s\n' "$confvar" "$legacy" "$conf" >> "$d"
  done
  migrate_state_set "legacy-${kind}" "$legacy"
  migrate_note "1.21 ${kind} build tool kept for the running drop-in(s) only, at ${legacy} (leaves at that service's cutover)"
  return 0
}

# Before each cutover and after the removals (R3(f)).
migrate_assert_no_old_triggers() {
  if migrate_old_triggers_present; then
    migrate_fail "1.21 build triggers reappeared (unit, timer or APT hook); this part is refused"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Step 3: pre-flight (read-only)
# ---------------------------------------------------------------------------
# Directive scan of the configuration reachable from MAIN.  One line each:
#   kind TAB file:line TAB directive
# kind: angie-only | unbuilt | droppable | security | acme | load_module | stream
migrate_nginx_scan() {
  local tree=$1 main=$2 f
  local drop=${NGINX_BUILD_DROPPABLE_RE:-$MIGRATE_NGINX_DROPPABLE_RE}
  local unbuilt=${NGINX_BUILD_UNBUILT_RE:-$MIGRATE_NGINX_UNBUILT_RE}
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    case $f in
      */mime.types|*/fastcgi.conf|*/fastcgi_params|*/scgi_params|*/uwsgi_params) continue ;;
    esac
    # Files never copied to /etc/nginx (the Angie package's own
    # http.d/default.conf with its `api` status location, modules-enabled,
    # ...) cannot block the migration: the 1.22.0 migration test stopped on
    # that `api` line although the file is left behind with /etc/angie.
    # angie.conf itself is still scanned although it is never copied: a
    # load_module there names a module the operator relies on, which nginx
    # will not have.
    [[ $f == "$tree"/* && $f != "$tree"/angie.conf ]] && migrate_angie_skip "${f#"$tree"/}" && continue
    awk -v file="$f" -v drop="$drop" -v unbuilt="$unbuilt" -v angie="$MIGRATE_NGINX_ANGIE_ONLY_RE" '
      function emit(kind, d) { printf "%s\t%s:%d\t%s\n", kind, file, NR, d }
      {
        c = $0; sub(/#.*/, "", c)
        if (c ~ /\$angie_/) emit("angie-only", "$angie_*")
        n = split(c, seg, /[;{}]/)
        for (i = 1; i <= n; i++) {
          s = seg[i]; sub(/^[ \t]+/, "", s)
          if (s == "") continue
          if (i == 1 && cont) continue
          split(s, w, /[ \t]+/); d = w[1]
          if (d ~ angie) emit("angie-only", d)
          else if (d == "load_module") { if (s !~ /brotli/) emit("load_module", s) }
          else if (d == "acme" || d == "acme_client") emit("acme", d)
          else if ((d == "stream" || d == "mail") && i < n) emit("stream", d)
          else if (d ~ /^limit_conn/ && d ~ drop) emit("security", d)
          else if (d ~ drop) emit("droppable", d)
          else if (d ~ unbuilt) emit("unbuilt", d)
          else if (s ~ /\$acme_cert/) emit("acme", "$acme_cert_*")
        }
        t = c; sub(/[ \t]+$/, "", t)
        cont = (t != "" && t !~ /[;{}]$/)
      }' "$f" 2>/dev/null || true
  done < <(migrate_conf_closure "$tree" "$main")
}

# Blocker summary of a scan (empty = none).
migrate_nginx_blockers() {
  awk -F'\t' '$1 == "angie-only" || $1 == "unbuilt" || $1 == "load_module" || $1 == "stream" { printf "%s %s (%s)\n", $1, $3, $2 }' "$1" | head -n 40
}

# References to Angie outside the tree that break after the purge (R83).
migrate_leftover_refs() {
  local -a roots=(/etc/cron.d /etc/crontab /var/spool/cron/crontabs /etc/logrotate.d /etc/fail2ban
                  /etc/letsencrypt/renewal /etc/letsencrypt/renewal-hooks /usr/local/bin /opt /root /home
                  "$MIGRATE_UNIT_DIR")
  local r
  for r in "${roots[@]}"; do
    [[ -e $r ]] || continue
    timeout 30 grep -rIlsE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      '/etc/angie|angie\.service|/var/www/logs/angie|systemctl[[:space:]]+(reload|restart)[[:space:]]+angie' "$r" 2>/dev/null \
      | grep -vE "^${MIGRATE_UNIT_DIR}/angie\.service(\.d/.*)?$|/logrotate\.d/angie$" | head -n 40 || true
  done
}

# Crontab lines that call bare php or /usr/bin/php (R6): after the purge they
# run our build through the /usr/bin/php link.
migrate_php_cron_callers() {
  local u f
  for u in root www-data; do
    crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*#' \
      | grep -E '(^|[^A-Za-z0-9_./-])php([0-9]+\.[0-9]+)?([[:space:]]|$)|/usr/bin/php' \
      | sed "s/^/${u}: /" || true
  done
  for f in /etc/crontab /etc/cron.d/*; do
    [[ -f $f ]] || continue
    grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
      | grep -E '(^|[^A-Za-z0-9_./-])php([0-9]+\.[0-9]+)?([[:space:]]|$)|/usr/bin/php' \
      | sed "s|^|${f}: |" || true
  done
}

# Pool listeners of version V, one per line.
migrate_php_listeners() {
  local f
  for f in "$MIGRATE_PHP_ETC/$1"/fpm/pool.d/*.conf; do
    [[ -f $f ]] || continue
    awk -F= '/^[[:space:]]*listen[[:space:]]*=/ { v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v }' "$f"
  done
}

# Modules the package PHP X.Y loads today, FPM and CLI (each with its own
# ini tree), lower-cased (R2.9, R25, R58).  This is the project's one Sury
# module probe: lib/php-build.sh has none, the Sury paths are this
# module's.  `php-fpmX.Y -m` must run; the CLI adds what only it loads
# when present.  Status 1 when the FPM binary is missing or fails: the set
# is then unknown, which is not the same as "nothing loaded".
MIGRATE_SURY_SBIN=${SETUP_MIGRATE_SURY_SBIN:-/usr/sbin}
MIGRATE_SURY_BIN=${SETUP_MIGRATE_SURY_BIN:-/usr/bin}
migrate_sury_loaded_exts() { # X.Y
  local fpm="$MIGRATE_SURY_SBIN/php-fpm$1" cli="$MIGRATE_SURY_BIN/php$1" out
  [[ -x $fpm ]] || return 1
  out=$("$fpm" -m 2>/dev/null) || return 1
  if [[ -x $cli ]]; then out+=$'\n'$("$cli" -m 2>/dev/null || true); fi
  printf '%s\n' "$out" | grep -v '^\[' | tr '[:upper:]' '[:lower:]' || true
}

# The probe's output as plain module names ("Zend OPcache" becomes
# zend_opcache; a startup warning printed on stdout is dropped).  Status 1
# when the probe failed.
migrate_sury_modules() {
  local out
  out=$(migrate_sury_loaded_exts "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr ' ' '_' \
    | grep -E '^[a-z0-9_]+$' | sort -u || true
}

# The extra web tree B's extension detection must walk during the PHP
# part (PHP_EXT_DETECT_TREE): /etc/angie while Angie is still installed,
# so its vhosts' application extension sets are in the build.  Empty once
# Angie is gone: only this module names Angie paths, and php-build.sh
# does not scan /etc/angie by itself.
migrate_php_detect_tree() {
  if [[ -d $MIGRATE_ANGIE_ETC ]] && migrate_angie_present; then printf '%s' "$MIGRATE_ANGIE_ETC"; fi
  return 0
}

migrate_php_buildable() {
  local e=$1
  if declare -F php_build_buildable_exts >/dev/null 2>&1; then
    php_build_buildable_exts | tr ', ' '\n\n' | grep -qxF -- "$e"
    return
  fi
  [[ $MIGRATE_PHP_BUILDABLE_FALLBACK == *" $e "* || $MIGRATE_PHP_BASE_EXTS == *" $e "* ]]
}

# Extension union for version V (R2.9, R25, R41, R58).  Prints lines:
#   keep NAME | unbuildable NAME
# The probe returns the FPM and CLI modules as one set, and the source
# build ships one extension set to both SAPIs, so a module only the CLI
# loaded today is kept (or counted as unbuildable) like an FPM module.
migrate_php_ext_union() {
  local v=$1 e
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    [[ $MIGRATE_PHP_BASE_EXTS == *" $e "* ]] && continue
    if migrate_php_buildable "$e"; then printf 'keep %s\n' "$e"; else printf 'unbuildable %s\n' "$e"; fi
  done < <(migrate_sury_modules "$v") | sort
}

migrate_php_scan_digest() {
  { migrate_php_ext_union "$1"; migrate_php_listeners "$1"; } 2>/dev/null | md5sum | awk '{ print $1 }'
}

# Lower-case module names some detected application requires (C's lists,
# over the live vhost roots and the /var/www roots), one per line.  Status 1
# when C's functions are not loaded: the caller cannot rule anything out.
migrate_php_app_required_exts() {
  local tree app root
  declare -F php_upgrade_app_required_extensions >/dev/null 2>&1 || return 1
  tree=$(migrate_web_tree)
  {
    declare -F php_upgrade_vhost_roots >/dev/null 2>&1 && php_upgrade_vhost_roots "$tree"
    declare -F php_upgrade_app_roots >/dev/null 2>&1 && php_upgrade_app_roots
  } 2>/dev/null | sort -u | while IFS=$'\t' read -r app root; do
    [[ -n $app && -n $root ]] || continue
    php_upgrade_app_required_extensions "$app" "$root" preflight 2>/dev/null || true
  done | tr ' ,\t' '\n\n\n' | tr '[:upper:]' '[:lower:]' | sed -e '/^$/d' -e 's/^zend_opcache$/opcache/' | sort -u
  return 0
}

# Merge NAMES into PHP_EXT_EXTRA (persisted, comma list) so the effective
# set keeps them; the operator trims later with --php ext= (R2.9).
migrate_php_persist_exts() {
  local cur=${PHP_EXT_EXTRA:-} e merged
  local -A have=()
  local -a out=()
  for e in ${cur//,/ } "$@"; do
    [[ -n $e && -z ${have[$e]:-} ]] || continue
    have[$e]=1; out+=("$e")
  done
  merged=$(printf '%s\n' "${out[@]}" | sort -u | paste -sd, -)
  [[ $merged == "$cur" ]] && return 0
  PHP_EXT_EXTRA=$merged
  export PHP_EXT_EXTRA
  persist_tuning_var PHP_EXT_EXTRA "$merged"
}

# The pre-flight.  DRY=1 only prints (migrate_plan); otherwise it records
# refused/blocked parts in the state file and fills MIGRATE_DO_* and
# MIGRATE_PHP_TODO.
migrate_preflight() {
  local dry=${1:-0} scan st v line blockers e digest
  local -a php_active=()
  MIGRATE_DO_NGINX=0; MIGRATE_DO_VALKEY=0; MIGRATE_PHP_TODO=()
  scan=$(tmp_file) || return 1

  # --- nginx part
  st=$(migrate_state_get nginx)
  if migrate_angie_present && [[ $st != "done" && $st != cutover ]]; then
    migrate_nginx_scan "$MIGRATE_ANGIE_ETC" "$MIGRATE_ANGIE_ETC/angie.conf" > "$scan"
    digest=$(md5sum < "$scan" | awk '{ print $1 }')
    blockers=$(migrate_nginx_blockers "$scan")
    if ! migrate_part_retry_ok nginx "$digest"; then
      if (( dry )); then printf '  nginx: %s (unchanged since; SETUP_MIGRATE_RETRY=1 retries)\n' "$st"
      else migrate_note "nginx part stays on Angie: ${st} (nothing changed since; SETUP_MIGRATE_RETRY=1 retries)"; fi
    elif [[ -n $blockers ]]; then
      if (( dry )); then
        printf '  nginx: BLOCKED (Angie keeps serving):\n'; printf '%s\n' "$blockers" | sed 's/^/    /'
      else
        migrate_state_set nginx "blocked:$(printf '%s' "$blockers" | head -n1)"
        migrate_state_set nginx.scan "$digest"
        migrate_fail "nginx part blocked before any build; Angie keeps serving.  Fix these (file:line) and re-run --optimize:"
        while IFS= read -r line; do migrate_report "    - ${line}"; done <<<"$blockers"
      fi
    elif migrate_distro_nginx_blocks "$dry"; then
      :
    else
      MIGRATE_DO_NGINX=1
      (( dry )) && printf '  nginx: Angie -> nginx (build, render /etc/nginx, ACME -> self-signed, cutover)\n'
    fi
    # Directives the build leaves out are commented (with a report); a
    # limit_conn is a security control and is reported prominently (R88).
    while IFS=$'\t' read -r e line v; do
      [[ -n $e ]] || continue
      (( dry || MIGRATE_DO_NGINX )) || break
      if (( dry )); then
        printf '    %s: %s (%s)\n' "$([[ $e == security ]] && echo 'SECURITY CONTROL REMOVED (operator rule 1.21.71)' || echo 'will be commented')" "$v" "$line"
      elif [[ $e == security ]]; then
        migrate_warn "${v} at ${line} will be commented: security control removed (operator rule 1.21.71)"
      else
        migrate_note "${v} at ${line} will be commented (module not built)"
      fi
    done < <(awk -F'\t' '$1 == "droppable" || $1 == "security"' "$scan")
    if (( dry )); then
      migrate_acme_plan
    fi
  elif [[ $st == "done" || $st == cutover ]]; then
    (( dry )) && printf '  nginx: migrated (%s)\n' "$st"
  fi
  # Leftover references are reported even when no purge runs (R83).
  if migrate_angie_present; then
    local refs
    refs=$(migrate_leftover_refs)
    if [[ -n $refs ]]; then
      if (( dry )); then printf '  references to Angie outside /etc/angie (fix after the purge):\n'; printf '%s\n' "$refs" | sed 's/^/    /'
      else migrate_warn "files outside /etc/angie still reference Angie (they break after the purge): $(printf '%s' "$refs" | paste -sd' ' -)"; fi
    fi
  fi

  # --- PHP parts
  mapfile -t php_active < <(migrate_sury_active_versions)
  # Every listener of every running version first (R24): two versions on
  # one address cannot both move to our units.
  local -A listen_owner=()
  local l conflict
  for v in "${php_active[@]}"; do
    while IFS= read -r l; do
      [[ -n $l ]] || continue
      if [[ -n ${listen_owner[$l]:-} && ${listen_owner[$l]} != "$v" ]]; then listen_owner[$l]+=" $v"; else listen_owner[$l]=$v; fi
    done < <(migrate_php_listeners "$v")
  done
  # One active version (R61, /etc/php/setup-active): B's php_build_start on
  # the next --optimize disables every version but the active one, so a
  # second running version moved onto our units would go down with it.  Only
  # the primary moves; the others stay on Sury (and keep the Sury purge
  # deferred) until the operator consolidates them.
  local primary
  primary=$(migrate_primary_version)
  for v in "${php_active[@]}"; do
    st=$(migrate_state_get "php-${v}")
    [[ $st == "done" ]] && { (( dry )) && printf '  PHP %s: migrated\n' "$v"; continue; }
    if ! migrate_part_retry_ok "php-${v}" "$(migrate_php_scan_digest "$v")"; then
      if (( dry )); then printf '  PHP %s: %s (unchanged since; SETUP_MIGRATE_RETRY=1 retries)\n' "$v" "$st"
      else migrate_note "PHP ${v} stays on Sury: ${st} (nothing changed since; SETUP_MIGRATE_RETRY=1 retries)"; fi
      continue
    fi
    if ! migrate_mem_allows php; then
      if (( dry )); then printf '  PHP %s: refused (host below the 4 GB class); Sury keeps serving\n' "$v"
      else migrate_state_set "php-${v}" refused-mem; migrate_warn "PHP ${v}: host below the 4 GB class; left on the Sury package (nothing is purged)"; fi
      continue
    fi
    conflict=""
    while IFS= read -r l; do
      [[ -n $l && ${listen_owner[$l]:-} == *" "* ]] && conflict="$l (PHP ${listen_owner[$l]})"
    done < <(migrate_php_listeners "$v")
    if [[ -n $conflict ]]; then
      if (( dry )); then printf '  PHP %s: refused, listener %s\n' "$v" "$conflict"
      else migrate_state_set "php-${v}" "refused:listener ${conflict}"; migrate_state_set "php-${v}.scan" "$(migrate_php_scan_digest "$v")"
           migrate_fail "PHP ${v}: two versions bind ${conflict}; this version stays on Sury"; fi
      continue
    fi
    if [[ -n $primary && $v != "$primary" ]]; then
      if (( dry )); then printf '  PHP %s: refused, only the active version %s moves to the source build (one active version); Sury keeps serving %s and is not purged\n' "$v" "$primary" "$v"
      else migrate_state_set "php-${v}" "refused:secondary (active ${primary})"; migrate_state_set "php-${v}.scan" "$(migrate_php_scan_digest "$v")"
           migrate_warn "PHP ${v}: stays on the Sury package; only the active version ${primary} moves to the source build (the next --optimize would stop a second version).  Move its sites to PHP ${primary}, stop php${v}-fpm and re-run --optimize; the Sury purge waits until then"; fi
      continue
    fi
    local -a keep=() unb_fpm=() unb_req=()
    # The project's one module probe (migrate_sury_modules).  When it fails
    # the modules Sury loads are unknown, and moving the version could drop
    # extensions without a word: refuse instead (retried when the scan
    # digest changes).
    if ! migrate_sury_modules "$v" >/dev/null 2>&1; then
      if (( dry )); then printf '  PHP %s: refused, the loaded-module probe (php-fpm%s -m) failed\n' "$v" "$v"
      else migrate_state_set "php-${v}" "refused:no module probe"; migrate_state_set "php-${v}.scan" "$(migrate_php_scan_digest "$v")"
           migrate_fail "PHP ${v}: php-fpm${v} -m failed, so the modules Sury loads cannot be read; Sury keeps serving and is not purged"; fi
      continue
    fi
    while read -r e line; do
      case $e in
        keep) keep+=("$line") ;;
        unbuildable) unb_fpm+=("$line") ;;
      esac
    done < <(migrate_php_ext_union "$v")
    # Rev3 step 3 (R41, R58): a module the build cannot provide refuses the
    # version only when a detected application requires it; otherwise it is
    # dropped with a warning (imagick under the GD rule, ffi from php-common).
    # Without C's requirement lists nothing can be ruled out: all count.
    if (( ${#unb_fpm[@]} )); then
      local req=""
      if req=$(migrate_php_app_required_exts); then
        for e in "${unb_fpm[@]}"; do grep -qxF -- "$e" <<<"$req" && unb_req+=("$e"); done
      else
        unb_req=("${unb_fpm[@]}")
      fi
    fi
    if (( dry )); then
      printf '  PHP %s: Sury -> source build; modules kept (FPM and CLI): %s\n' "$v" "${keep[*]:-none}"
      (( ${#unb_fpm[@]} )) && printf '    modules that cannot be built: %s\n' "${unb_fpm[*]}"
      (( ${#unb_req[@]} )) && printf '    required by an application and unbuildable: %s%s\n' "${unb_req[*]}" \
        "$([[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} == 1 ]] && echo ' (dropped: SETUP_PHP_ALLOW_MISSING_EXT=1)' || echo ' -> this version is REFUSED')"
      if declare -F php_build_effective_exts >/dev/null 2>&1; then
        printf '    effective set after the union: %s\n' "$(PHP_EXT_DETECT_TREE=$(migrate_php_detect_tree) php_build_effective_exts 2>/dev/null || true)"
      fi
      continue
    fi
    if (( ${#unb_req[@]} > 0 )) && [[ ${SETUP_PHP_ALLOW_MISSING_EXT:-0} != 1 ]]; then
      migrate_state_set "php-${v}" "refused:unbuildable ${unb_req[*]}"
      migrate_state_set "php-${v}.scan" "$(migrate_php_scan_digest "$v")"
      migrate_fail "PHP ${v}: an application needs modules the source build cannot provide (${unb_req[*]}); Sury keeps serving and is not purged (SETUP_PHP_ALLOW_MISSING_EXT=1 drops them)"
      continue
    fi
    (( ${#unb_fpm[@]} )) && migrate_warn "PHP ${v}: modules the source build cannot provide are dropped (no detected application requires them): ${unb_fpm[*]}"
    migrate_php_persist_exts "${keep[@]}"
    migrate_note "PHP ${v}: extensions loaded today kept in PHP_EXT_EXTRA: ${keep[*]:-none}"
    MIGRATE_PHP_TODO+=("$v")
  done
  # Installed but stopped versions go with the Sury purge (their /etc/php
  # tree stays in the backups).
  local inactive
  inactive=$(comm -23 <(migrate_sury_versions | sort) <(printf "%s\n" "${php_active[@]}" | sort) 2>/dev/null | paste -sd' ' - || true)
  if [[ -n $inactive ]]; then
    if (( dry )); then printf '  PHP %s: installed but not running; removed with the Sury purge (config kept in backups)\n' "$inactive"
    else migrate_note "PHP ${inactive}: installed but not running; removed with the Sury purge, /etc/php kept in the backups"; fi
  fi

  # --- Valkey part
  if migrate_valkey_pkg_present; then
    st=$(migrate_state_get valkey)
    if [[ $st == "done" ]]; then
      (( dry )) && printf '  Valkey: migrated\n'
    elif ! migrate_part_retry_ok valkey "$(migrate_valkey_scan_digest)"; then
      if (( dry )); then printf '  Valkey: %s (unchanged since; SETUP_MIGRATE_RETRY=1 retries)\n' "$st"
      else migrate_note "Valkey stays on the package: ${st} (SETUP_MIGRATE_RETRY=1 retries)"; fi
    elif ! migrate_mem_allows valkey; then
      if (( dry )); then printf '  Valkey: refused (host below the 4 GB class)\n'
      else migrate_state_set valkey refused-mem; migrate_warn "Valkey: host below the 4 GB class; left on the package"; fi
    else
      MIGRATE_DO_VALKEY=1
      (( dry )) && printf '  Valkey: package -> source build (%s)\n' "$(migrate_valkey_persists && echo 'persistence on: dataset snapshot after a clean stop' || echo 'cache only')"
    fi
  fi

  # --- Collateral of every removal list, rc packages included (R9)
  migrate_preflight_collateral "$dry"
  # --- Disk (R31)
  migrate_preflight_disk "$dry"
  rm -f -- "$scan"
  return 0
}

# Distro nginx (R2.1, R42): returns 0 when it blocks the nginx part.
migrate_distro_nginx_blocks() {
  local dry=$1
  local -a pkgs=()
  mapfile -t pkgs < <(migrate_pkg_list distro-nginx)
  (( ${#pkgs[@]} > 0 )) || return 1
  if systemctl is-active --quiet nginx 2>/dev/null && ! migrate_angie_present; then
    if (( dry )); then printf '  nginx: refused, the distro nginx package is serving (purging it first would take the sites down)\n'
    else migrate_state_set nginx "blocked:distro nginx active"; migrate_fail "nginx part refused: the distro nginx package serves this host; stop relying on it (or remove it) and re-run"; fi
    return 0
  fi
  if ! migrate_purge_sim purge "${pkgs[@]}" || (( ${#MIGRATE_SIM_COLLATERAL[@]} > 0 )); then
    if (( dry )); then printf '  nginx: refused, removing the distro nginx packages would also remove: %s\n' "${MIGRATE_SIM_COLLATERAL[*]:-apt refused}"
    else migrate_state_set nginx "blocked:distro nginx collateral"; migrate_state_set nginx.scan "$(migrate_nginx_scan_digest)"
         migrate_fail "nginx part refused: purging the distro nginx packages would also remove ${MIGRATE_SIM_COLLATERAL[*]:-(apt refused the simulation)}"; fi
    return 0
  fi
  (( dry )) && printf '  distro nginx packages to purge before the render: %s\n' "${pkgs[*]}"
  return 1
}

migrate_preflight_collateral() {
  local dry=$1 kind
  local -a pkgs=()
  for kind in angie valkey; do
    mapfile -t pkgs < <(migrate_pkg_list "$kind")
    (( ${#pkgs[@]} > 0 )) || continue
    local action=purge
    [[ $kind == valkey ]] && action=remove
    if ! migrate_purge_sim "$action" "${pkgs[@]}"; then
      if (( dry )); then printf '  %s %s: apt refuses the simulation (held or broken package); kept installed\n' "$action" "$kind"
      else migrate_warn "${action} ${kind}: apt refuses the simulation; the packages will stay installed"; fi
    elif (( ${#MIGRATE_SIM_COLLATERAL[@]} > 0 )); then
      if (( dry )); then printf '  %s %s would also remove %s: skipped, kept installed\n' "$action" "$kind" "${MIGRATE_SIM_COLLATERAL[*]}"
      else migrate_warn "${action} ${kind} would also remove ${MIGRATE_SIM_COLLATERAL[*]}; that removal will be skipped"; fi
    elif (( dry )); then
      printf '  %s after cutover: %s\n' "$action" "${pkgs[*]}"
    fi
  done
  mapfile -t pkgs < <(migrate_pkg_list sury)
  if (( ${#pkgs[@]} > 0 )); then
    if migrate_sury_purge_preflight >/dev/null; then
      (( dry )) && printf '  purge Sury PHP after cutover: %s package(s)%s\n' "${#pkgs[@]}" \
        "$([[ ${SETUP_PHP_ALLOW_COLLATERAL:-0} == 1 && ${#MIGRATE_SIM_COLLATERAL[@]} -gt 0 ]] && echo " (also removes ${MIGRATE_SIM_COLLATERAL[*]}: SETUP_PHP_ALLOW_COLLATERAL=1)")"
    else
      if (( dry )); then printf '  Sury purge would also remove %s: DEFERRED (packages held; SETUP_PHP_ALLOW_COLLATERAL=1 overrides)\n' "${MIGRATE_SIM_COLLATERAL[*]}"
      else migrate_warn "the Sury purge would also remove ${MIGRATE_SIM_COLLATERAL[*]}; it will be deferred (PHP still moves to the source build)"; fi
    fi
  fi
}

migrate_preflight_disk() {
  local dry=$1 cache_need=0 backup_need=0 v msg llvm=0
  ls -d /usr/lib/llvm-[0-9]* /opt/setup-llvm/[0-9]* >/dev/null 2>&1 || llvm=$MIGRATE_DISK_LLVM_MB
  cache_need=$llvm
  (( MIGRATE_DO_NGINX )) && { cache_need=$(( cache_need + MIGRATE_DISK_NGINX_MB )); backup_need=$(( backup_need + $(migrate_size_mb "$MIGRATE_ANGIE_ETC" /var/lib/angie) )); }
  for v in "${MIGRATE_PHP_TODO[@]}"; do
    cache_need=$(( cache_need + MIGRATE_DISK_PHP_MB ))
  done
  (( ${#MIGRATE_PHP_TODO[@]} )) && backup_need=$(( backup_need + $(migrate_size_mb "$MIGRATE_PHP_ETC" /var/lib/php/sessions) ))
  (( MIGRATE_DO_VALKEY )) && { cache_need=$(( cache_need + MIGRATE_DISK_VALKEY_MB )); backup_need=$(( backup_need + $(migrate_size_mb "$MIGRATE_VALKEY_ETC" "$MIGRATE_VALKEY_DATA") )); }
  (( cache_need + backup_need > 0 )) || return 0
  # Builds: the cache filesystem never below 6 GB free, / never below 2 GB.
  (( cache_need < 6144 )) && (( cache_need > 0 )) && cache_need=6144
  local same=0
  [[ $(migrate_mount_of /var/cache) == "$(migrate_mount_of "$(dirname "$MIGRATE_BACKUP_ROOT")")" ]] && same=1
  local ok_cache=0 ok_backup=0
  if (( same )); then
    msg=$(migrate_disk_fits /var/cache $(( cache_need + backup_need ))) && { ok_cache=1; ok_backup=1; }
  else
    msg=$(migrate_disk_fits /var/cache "$cache_need") && ok_cache=1
    local m2
    m2=$(migrate_disk_fits "$MIGRATE_BACKUP_ROOT" "$backup_need") && ok_backup=1
    msg+="; backups ${m2}"
  fi
  local root_ok=1 rmsg
  rmsg=$(migrate_disk_fits / 2048) || root_ok=0
  if (( dry )); then
    printf '  disk: builds+snapshots %s; / %s\n' "$msg" "$rmsg"
    (( ok_cache && ok_backup && root_ok )) || printf '  disk: NOT ENOUGH; the parts that do not fit are postponed\n'
    return 0
  fi
  if (( ! ok_cache || ! root_ok )); then
    migrate_fail "not enough disk for the builds (${msg}; / ${rmsg}); every part postponed, the current services keep serving"
    (( MIGRATE_DO_NGINX )) && migrate_state_set nginx "postponed:disk"
    for v in "${MIGRATE_PHP_TODO[@]}"; do migrate_state_set "php-${v}" "postponed:disk"; done
    (( MIGRATE_DO_VALKEY )) && migrate_state_set valkey "postponed:disk"
    MIGRATE_DO_NGINX=0; MIGRATE_PHP_TODO=(); MIGRATE_DO_VALKEY=0
  elif (( ! ok_backup )); then
    # The dataset snapshot is the biggest one: Valkey goes first.
    if (( MIGRATE_DO_VALKEY )); then
      migrate_fail "not enough disk for the Valkey dataset snapshot (${msg}); Valkey postponed"
      migrate_state_set valkey "postponed:disk"; MIGRATE_DO_VALKEY=0
    else
      migrate_fail "not enough disk for the configuration snapshots (${msg}); every part postponed"
      MIGRATE_DO_NGINX=0; MIGRATE_PHP_TODO=()
    fi
  fi
}

# Plan lines for the Angie ACME vhosts (dry run; R27, R35).
migrate_acme_plan() {
  local f names hsts cf name n=0
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    names=$(awk '{ c = $0; sub(/#.*/, "", c) } c ~ /server_name[ \t]/ { s = c; sub(/.*server_name[ \t]+/, "", s); sub(/;.*/, "", s); printf "%s ", s }' "$f")
    hsts=0
    grep -qi 'strict-transport-security' "$f" 2>/dev/null && hsts=1
    cf=""
    for name in $names; do
      [[ $name == _ || $name == *'*'* || $name == '~'* ]] && continue
      cf_tls_name_behind_cloudflare "$name" "$MIGRATE_ANGIE_ETC/http.d/cloudflare.conf" 2>/dev/null || cf+="${name} "
    done
    printf '  ACME -> self-signed: %s (%s)%s%s\n' "${f#"$MIGRATE_ANGIE_ETC"/}" "${names% }" \
      "${cf:+ WARNING not behind Cloudflare: ${cf% } -> visitors get a certificate error}" \
      "$( (( hsts )) && echo ' WARNING sends HSTS: unreachable if not behind Cloudflare')"
    n=$(( n + 1 ))
  done < <(grep -rlsE '^[^#]*(\$acme_cert_|(^|[[:space:];{])acme[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;)' "$MIGRATE_ANGIE_ETC/conf.d" "$MIGRATE_ANGIE_ETC/snippets" "$MIGRATE_ANGIE_ETC/custom.d" 2>/dev/null || true)
  return 0
}

# ---------------------------------------------------------------------------
# Step 4: builds (build-only; nothing is activated)
# ---------------------------------------------------------------------------
migrate_build_all() {
  local v st
  st=$(migrate_state_get nginx)
  if (( MIGRATE_DO_NGINX )) && { [[ $st != built && $st != rendered ]] || ! migrate_nginx_bin >/dev/null; }; then
    if nginx_build_ensure build-only migrate migrate_out; then
      migrate_state_set nginx built
    else
      migrate_state_set nginx "postponed:build failed"
      migrate_fail "nginx build failed; Angie keeps serving (retried by the next --optimize)"
      MIGRATE_DO_NGINX=0
    fi
  fi
  local -a todo=()
  local detect
  detect=$(migrate_php_detect_tree)
  for v in "${MIGRATE_PHP_TODO[@]}"; do
    if PHP_EXT_DETECT_TREE=$detect php_build_ensure "$v" build-only migrate migrate_out; then
      migrate_state_set "php-${v}" built
      todo+=("$v")
    else
      migrate_state_set "php-${v}" "postponed:build failed"
      migrate_fail "PHP ${v} build failed; Sury keeps serving (retried by the next --optimize)"
    fi
  done
  MIGRATE_PHP_TODO=("${todo[@]}")
  if (( MIGRATE_DO_VALKEY )); then
    if valkey_build_ensure build-only migrate migrate_out; then
      migrate_state_set valkey built
    else
      migrate_state_set valkey "postponed:build failed"
      migrate_fail "Valkey build failed; the package keeps serving (retried by the next --optimize)"
      MIGRATE_DO_VALKEY=0
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Steps 5-7: render /etc/nginx
# ---------------------------------------------------------------------------
# Distro nginx goes first (R30, R42, R71): /etc/nginx aside, guarded purge
# under policy-rc.d, daemon-reload, and only then the render, so nginx-common's
# conffile purge can never delete files of the new tree.
migrate_distro_nginx_purge() {
  local -a pkgs=()
  local snap
  mapfile -t pkgs < <(migrate_pkg_list distro-nginx)
  snap=$(migrate_snapshot_dir nginx-legacy) || return 1
  if [[ -e $MIGRATE_NGINX_ETC ]]; then
    migrate_stash "$MIGRATE_NGINX_ETC" "$snap" || return 1
    migrate_note "previous /etc/nginx moved to ${snap}/etc/nginx"
  fi
  (( ${#pkgs[@]} > 0 )) || return 0
  migrate_save_debs "$snap/debs" "${pkgs[@]}"
  migrate_policy_install || return 1
  migrate_inflight_set purge
  if ! migrate_apt_remove purge "${pkgs[@]}"; then
    migrate_inflight_clear
    migrate_policy_remove
    migrate_fail "purging the distro nginx packages failed; nginx part aborted (Angie keeps serving)"
    return 1
  fi
  migrate_inflight_clear
  migrate_policy_remove
  [[ -e /etc/logrotate.d/nginx ]] && migrate_stash /etc/logrotate.d/nginx "$snap"
  systemctl unmask nginx.service >/dev/null 2>&1 || true
  migrate_clear_dsh_state nginx
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  migrate_state_set distro-nginx "purged:${snap}"
  migrate_note "distro nginx packages purged (${pkgs[*]}); .debs and the old tree in ${snap}"
}

# Files of /etc/angie that are package or Angie-specific and never copied.
migrate_angie_skip() {
  case $1 in
    angie.conf|mime.types|fastcgi.conf|fastcgi_params|scgi_params|uwsgi_params|koi-utf|koi-win|win-utf) return 0 ;;
    http.d/default.conf|modules-enabled/*|modules-available/*|modules/*|stream.d/*|*.dpkg-*|*.ucf-*) return 0 ;;
    scripts/cloudflare.sh) return 0 ;;
  esac
  return 1
}

# Paths that always come from the Angie tree, even when the SCN render
# created a file of that name: the host's certificates and keys, the
# generated Cloudflare real-IP list, preserved upstreams and password files.
migrate_angie_always() {
  case $1 in
    ssl/*|http.d/cloudflare.conf|http.d/zz-setup-preserved-upstreams.conf|htpasswd/*|basic_auth/*|*_auth) return 0 ;;
  esac
  return 1
}

# The Angie -> nginx path map (R94), applied to copied files only.
migrate_path_map() {
  local f=$1
  sed_in_place -E \
    -e "s/^([[:space:]]*)${MIGRATE_ANGIE_FIT_MARK}/\\1/" \
    -e 's#/etc/angie/#/etc/nginx/#g' \
    -e 's#/etc/angie([;"'"'"'[:space:]]|$)#/etc/nginx\1#g' \
    -e 's#/var/www/logs/angie#/var/www/logs/nginx#g' \
    -e 's#/var/cache/angie#/var/cache/nginx#g' \
    -e "s#/usr/share/angie/html#$(migrate_nginx_root)/html#g" \
    -e 's#/run/angie\.pid#/run/nginx.pid#g' \
    -e 's#^([[:space:]]*user[[:space:]]+)angie([[:space:]]*;|[[:space:]]+angie[[:space:]]*;)#\1www-data;#' \
    "$f"
}

# Copy the operator's files from /etc/angie into the rendered /etc/nginx.
migrate_copy_operator_files() {
  local src=$MIGRATE_ANGIE_ETC dst=$MIGRATE_NGINX_ETC f rel target n=0
  local -a copied=()
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    migrate_angie_skip "$rel" && continue
    if [[ -e $dst/$rel || -L $dst/$rel ]] && ! migrate_angie_always "$rel"; then
      continue
    fi
    mkdir -p "$(dirname "$dst/$rel")"
    if [[ -L $f ]]; then
      target=$(readlink "$f")
      [[ $target == "$src"/* ]] && target="$dst/${target#"$src"/}"
      ln -sfn -- "$target" "$dst/$rel"
    else
      # Owner and mode preserved: htpasswd files and keys stay as tight as
      # they were (R87); nginx_secure_auth_files re-applies the policy.
      cp -a -- "$f" "$dst/$rel" || return 1
      case $rel in ssl/*) ;; *) migrate_path_map "$dst/$rel" ;; esac
    fi
    copied+=("$rel"); n=$(( n + 1 ))
  done < <(find "$src" \( -type f -o -type l \) -print0 2>/dev/null)
  migrate_note "operator files copied from /etc/angie: ${n}$( (( n )) && printf ' (%s)' "$(printf '%s\n' "${copied[@]}" | head -n 15 | paste -sd' ' -)")"
  return 0
}

# Pin `upstream local_php` to the listener that serves now (R23).
# The address Angie's `upstream local_php` sends PHP to (socket path or
# host:port), empty when there is none.
migrate_angie_local_php_listener() {
  local listen
  listen=$(awk '/^[[:space:]]*upstream[[:space:]]+local_php[[:space:]]*\{/ { f = 1 }
                f && /^[[:space:]]*server[[:space:]]/ { s = $2; sub(/;.*/, "", s); print s; exit }' \
             "$MIGRATE_ANGIE_ETC/angie.conf" 2>/dev/null || true)
  printf '%s' "${listen#unix:}"
}

migrate_pin_local_php() {
  local listen="" v
  listen=$(migrate_angie_local_php_listener)
  if [[ -z $listen ]] && declare -F php_primary_version >/dev/null 2>&1; then
    v=$(php_primary_version 2>/dev/null || true)
    [[ -n $v ]] && listen=$(migrate_php_listeners "$v" | head -n1)
  fi
  [[ -n $listen ]] || return 0
  if ! migrate_listener_up "$listen"; then
    migrate_warn "the live local_php listener ${listen} does not accept connections; PHP vhosts are verified at cutover"
  fi
  nginx_local_php_follow_pool "$MIGRATE_NGINX_ETC/nginx.conf" "$listen"
}

# 0 when something accepts connections on LISTEN (socket path or [host:]port).
# curl's exit 7 is "could not connect"; any other answer (FastCGI does not
# speak HTTP, so 52/56 are normal) proves a listener.
migrate_listener_up() {
  local l=$1 rc=0 url
  if [[ $l == /* ]]; then
    [[ -S $l ]] || return 1
    curl -s -o /dev/null --max-time 3 --unix-socket "$l" http://localhost/ 2>/dev/null || rc=$?
  else
    [[ $l =~ ^[0-9]+$ ]] && l="127.0.0.1:${l}"
    [[ $l == 0.0.0.0:* ]] && l="127.0.0.1:${l#0.0.0.0:}"
    url="http://${l}/"
    curl -s -o /dev/null --max-time 3 "$url" 2>/dev/null || rc=$?
  fi
  (( rc != 7 && rc != 6 ))
}

# Step 6: Angie ACME -> the host self-signed pair, in every file of the
# rendered tree (R2.14, R27, R35).  Prints one "file TAB names" line per
# changed server block into REPORT.
migrate_acme_rewrite_file() {
  local file=$1 rep=$2 out
  out=$(tmp_file) || return 1
  awk -v crt="$CF_TLS_DEFAULT_CERT" -v key="$CF_TLS_DEFAULT_KEY" -v off="$MIGRATE_ACME_OFF" \
      -v rep="$rep" -v fname="$file" '
    function code(s) { sub(/#.*/, "", s); return s }
    function emit(s) { if (inb) buf[++nb] = s; else print s }
    function flush(   i, l) {
      for (i = 1; i <= nb; i++) {
        l = buf[i]
        if (acme && code(l) ~ /(^|[ \t;{])include[ \t]+[^;]*ocsp_stapling[^;]*;/) { l = off l; changed = 1 }
        print l
      }
      if (acme) printf "%s\t%s\n", fname, names >> rep
      nb = 0; inb = 0; acme = 0; names = ""
    }
    {
      line = $0; c = code(line)
      if (skip) { emit(off line); changed = 1; if (c ~ /;/) skip = 0; next }
      if (!inb && depth == 0 && c ~ /^[ \t]*server[ \t]*\{/) { inb = 1; nb = 0; acme = 0; names = "" }
      if (inb && c ~ /(^|[ \t;{])server_name[ \t]/) { s = c; sub(/.*server_name[ \t]+/, "", s); sub(/;.*/, "", s); names = names (names == "" ? "" : " ") s }
      if (c ~ /^[ \t]*acme_client([ \t]|$)/) {
        changed = 1; if (c !~ /;/) skip = 1; emit(off line)
      } else if (c ~ /^[ \t]*acme[ \t]+[^;]*/) {
        changed = 1; acme = 1; if (c !~ /;/) skip = 1; emit(off line)
      } else {
        if (c ~ /ssl_certificate_key[ \t]+"?\$acme_cert_key_/) {
          sub(/ssl_certificate_key[ \t]+"?\$acme_cert_key_[A-Za-z0-9_]+"?/, "ssl_certificate_key " key, line); changed = 1; acme = 1
        }
        if (code(line) ~ /ssl_certificate[ \t]+"?\$acme_cert_/) {
          sub(/ssl_certificate[ \t]+"?\$acme_cert_[A-Za-z0-9_]+"?/, "ssl_certificate " crt, line); changed = 1; acme = 1
        }
        emit(line)
      }
      o = gsub(/\{/, "{", c); cl = gsub(/\}/, "}", c); depth += o - cl
      if (inb && depth == 0 && (o > 0 || cl > 0)) flush()
    }
    END { if (inb) flush(); exit (changed ? 0 : 3) }' "$file" > "$out"
  local rc=$?
  if (( rc == 0 )); then
    cat -- "$out" > "$file"
  fi
  rm -f -- "$out"
  (( rc == 0 || rc == 3 ))
}

migrate_acme_to_self_signed() {
  local rep snap f name names hsts cf n=0
  rep=$(tmp_file) || return 1
  snap=$(migrate_run_dir)/acme
  mkdir -p "$snap"
  while IFS= read -r -d '' f; do
    grep -qE '^[^#]*(acme|\$acme_cert)' "$f" 2>/dev/null || continue
    cp -a -- "$f" "$snap/$(printf '%s' "${f#"$MIGRATE_NGINX_ETC"/}" | tr '/' '_')"
    migrate_acme_rewrite_file "$f" "$rep" || { migrate_fail "ACME rewrite failed in ${f}"; return 1; }
  done < <(find "$MIGRATE_NGINX_ETC" -path "$MIGRATE_NGINX_ETC/ssl" -prune -o -type f -name '*.conf' -print0 2>/dev/null)
  if grep -rqsE '^[^#]*\$acme_cert' "$MIGRATE_NGINX_ETC" 2>/dev/null; then
    migrate_fail "an \$acme_cert_* variable is used outside ssl_certificate(_key); nginx part aborted: $(grep -rlsE '^[^#]*\$acme_cert' "$MIGRATE_NGINX_ETC" | head -n3 | paste -sd' ' -)"
    return 1
  fi
  # Angie's issued certificates and account keys go to the backups, owned by
  # root (the angie UID may be freed by the purge, R37).
  if [[ -d /var/lib/angie/acme ]] && [[ -z $(migrate_state_get angie-acme-copy) ]]; then
    local acme_snap
    acme_snap=$(migrate_snapshot_dir angie-acme) || return 1
    cp -a /var/lib/angie/acme "$acme_snap/" && chown -R root:root "$acme_snap" && chmod 700 "$acme_snap"
    migrate_state_set angie-acme-copy "$acme_snap"
  fi
  local warned=0
  while IFS=$'\t' read -r f names; do
    [[ -n $f ]] || continue
    n=$(( n + 1 ))
    hsts=0
    # The vhost or one of the files it includes.  (xargs -r over an empty
    # include list exits 0 without running grep: a vhost with no includes
    # was once reported as sending HSTS.)
    local -a incs=()
    mapfile -t incs < <(migrate_conf_closure "$MIGRATE_NGINX_ETC" "$f" 2>/dev/null | tail -n +2)
    if grep -qiE '^[^#]*strict-transport-security' "$f" 2>/dev/null \
       || { (( ${#incs[@]} > 0 )) && grep -qiE '^[^#]*strict-transport-security' "${incs[@]}" 2>/dev/null; }; then
      hsts=1
    fi
    cf=""
    for name in $names; do
      [[ $name == _ || $name == *'*'* || $name == '~'* || $name == .* ]] && { cf+="${name} "; continue; }
      cf_tls_name_behind_cloudflare "$name" "$MIGRATE_NGINX_ETC/http.d/cloudflare.conf" || cf+="${name} "
    done
    if [[ -n $cf || $hsts == 1 ]]; then
      (( warned )) || migrate_report "- **WARNING: ACME vhosts moved to the self-signed certificate that may not be behind Cloudflare** (operator rule: no ACME after 1.22; Angie's issued certificates are in $(migrate_state_get angie-acme-copy))"
      warned=1
      migrate_report "    - ${f#"$MIGRATE_NGINX_ETC"/} (${names}):${cf:+ not proved behind Cloudflare: ${cf% };} $( (( hsts )) && echo 'sends HSTS, so visitors cannot click through a certificate error')"
    else
      migrate_note "ACME -> self-signed: ${f#"$MIGRATE_NGINX_ETC"/} (${names}; behind Cloudflare)"
    fi
  done < "$rep"
  rm -f -- "$rep"
  return 0
}

# The marker A's fit writes in /etc/nginx (`nginx-build.sh restore` undoes
# it).  The 1.21 Angie marker is restored in the copy first (migrate_path_map)
# so every directive is fitted again against the nginx candidate (R88, R94).
MIGRATE_NGINX_FIT_MARK='# setup-nginx-build-off: '

# Make CAND accept CONF by commenting out droppable directives it does not
# know, one nginx -t at a time: A's tool (`nginx-build.sh fit CONF BIN`, which
# takes an explicit tree and binary) when it is installed, else the same loop
# here.  Prints "file:line directive" for each commented directive; status 1
# with the nginx error on stderr when a directive cannot be commented.
migrate_nginx_fit() {
  local conf=$1 cand=$2 tool out rc=0
  tool=${NGINX_BUILD_TOOL:-$(migrate_nginx_root)/nginx-build.sh}
  if [[ -x $tool ]]; then
    out=$(NGINX_BUILD_CONTEXT=migrate "$tool" fit "$conf" "$cand" 2>&1) || rc=$?
    sed -nE 's/.*nginx build: commented out ([^ ]+) in ([^ ]+) .*/\2 \1/p' <<<"$out"
    if (( rc != 0 )); then
      grep -m3 -E 'emerg|error|unknown' <<<"$out" >&2 || sed -n 1p <<<"$out" >&2
    fi
    return "$rc"
  fi
  migrate_nginx_self_fit "$conf" "$cand"
}

migrate_nginx_self_fit() {
  local conf=$1 cand=$2 dir out d f n i start drop
  drop=${NGINX_BUILD_DROPPABLE_RE:-$MIGRATE_NGINX_DROPPABLE_RE}
  dir=$(dirname "$conf")
  for (( i = 0; i < 100; i++ )); do
    out=$("$cand" -t -q -c "$conf" 2>&1) && return 0
    if [[ $out =~ unknown\ directive\ \"([a-z0-9_]+)\"\ in\ ([^[:space:]]+):([0-9]+) ]]; then
      d=${BASH_REMATCH[1]}; f=${BASH_REMATCH[2]}; n=${BASH_REMATCH[3]}
      if [[ $d =~ $drop && $f == "$dir"/* && -f $f && ! -L $f ]]; then
        # nginx names the line a directive ends on; comment from its start.
        start=$(awk -v n="$n" -v d="$d" 'NR <= n && ($1 == d || index($1, d ";") == 1) { s = NR } END { print s + 0 }' "$f")
        if (( start > 0 )); then
          sed_in_place -E "${start},${n}s/^([[:space:]]*)/\\1${MIGRATE_NGINX_FIT_MARK}/" "$f"
          printf '%s:%s %s\n' "${f#"$dir"/}" "$n" "$d"
          continue
        fi
      fi
    fi
    grep -m1 -E 'emerg|error' <<<"$out" >&2 || sed -n 1p <<<"$out" >&2
    return 1
  done
  return 1
}

# Report the "file:line directive" lines of a fit (limit_conn prominently).
migrate_nginx_fit_report() {
  local l
  while IFS= read -r l; do
    [[ -n $l ]] || continue
    if [[ $l == *limit_conn* ]]; then migrate_warn "commented ${l}: security control removed (operator rule 1.21.71)"
    else migrate_note "commented ${l} (module not built)"; fi
  done <<<"$1"
}

# Rev3 step 3: a trial of the operator's tree under the candidate BEFORE the
# distro nginx purge or any change to /etc/nginx.  /etc/angie is copied into
# a private temp dir, path-mapped onto that dir, the 1.21 fit marker undone,
# the ACME directives switched as in step 6, and the fit run on the copy with
# the candidate.  An unknown directive the fit cannot comment out is a real
# blocker (printed, status 1).  Any other failure, such as a certificate that
# exists only after the render, is left to the real test of step 7.
migrate_nginx_trial() {
  local cand=$1 t f rep err rc=0
  [[ -f $MIGRATE_ANGIE_ETC/angie.conf ]] || return 0
  t=$(tmp_dir nginx-trial.XXXXXX) || return 0
  if ! cp -a -- "$MIGRATE_ANGIE_ETC/." "$t/" 2>/dev/null; then
    rm -rf -- "$t"; return 0
  fi
  while IFS= read -r -d '' f; do
    sed_in_place -E \
      -e "s/^([[:space:]]*)${MIGRATE_ANGIE_FIT_MARK}/\\1/" \
      -e "s#${MIGRATE_ANGIE_ETC}/#${t}/#g" \
      -e 's#/var/www/logs/angie#/var/www/logs/nginx#g' \
      -e 's#/var/cache/angie#/var/cache/nginx#g' \
      -e 's#/run/angie\.pid#/run/nginx.pid#g' \
      -e 's#^([[:space:]]*user[[:space:]]+)angie([[:space:]]*;|[[:space:]]+angie[[:space:]]*;)#\1www-data;#' \
      "$f" 2>/dev/null || true
  done < <(find "$t" -path "$t/ssl" -prune -o -type f -print0 2>/dev/null)
  rep=$(tmp_file) || rep=/dev/null
  while IFS= read -r -d '' f; do
    grep -qE '^[^#]*(acme|\$acme_cert)' "$f" 2>/dev/null && migrate_acme_rewrite_file "$f" "$rep" >/dev/null 2>&1
  done < <(find "$t" -path "$t/ssl" -prune -o -type f -print0 2>/dev/null)
  [[ $rep == /dev/null ]] || rm -f -- "$rep"
  err=$(migrate_nginx_fit "$t/angie.conf" "$cand" 2>&1 >/dev/null) || rc=$?
  rm -rf -- "$t"
  (( rc == 0 )) && return 0
  err=${err//"$t"\//}
  if [[ $err == *'unknown directive'* ]]; then
    printf '%s' "$(printf '%s' "$err" | head -n 3 | paste -sd' ' -)"
    return 1
  fi
  migrate_note "the trial nginx -t of the Angie tree was inconclusive ($(printf '%s' "$err" | head -n 1)); the rendered tree is tested at step 7"
  return 0
}

# F's deploy_nginx_tree and the tuner's compression step test with
# /usr/sbin/nginx unless they honour NGINX_TEST_BIN.  An Angie host has no
# /usr/sbin/nginx (and the distro one was just purged), so the render would
# fail.  While a loaded function still names /usr/sbin/nginx and nothing is
# at that path, a temporary symlink to the candidate stands in; it is
# recorded in the state and moved into the backups right after the render,
# by the EXIT hook and by the next run's resume.
migrate_nginx_test_shim_on() {
  local cand=$1 shim=/usr/sbin/nginx
  declare -f deploy_nginx_tree nginx_apply_profile ensure_nginx_compression tune_nginx_configs 2>/dev/null \
    | grep -qF '/usr/sbin/nginx' || return 0
  [[ -e $shim || -L $shim ]] && return 0
  migrate_dpkg_owned "$shim" && return 0
  ln -s -- "$cand" "$shim" 2>/dev/null || return 0
  migrate_state_set nginx-test-shim "$shim"
}
migrate_nginx_test_shim_off() {
  local shim d
  shim=$(migrate_state_get nginx-test-shim)
  [[ -n $shim ]] || return 0
  if [[ -L $shim && $(readlink "$shim") == "$(migrate_nginx_root)/"* ]]; then
    d=$(migrate_run_dir 2>/dev/null) || d=""
    if [[ -n $d ]]; then migrate_stash "$shim" "$d/test-shim" || true
    else mv -f -- "$shim" "$(tmp_dir)/" 2>/dev/null || true; fi
  fi
  migrate_state_del nginx-test-shim
}

# Steps 5-7 for the nginx part.  Returns 1 with the part's state recorded
# when it cannot go on (Angie keeps serving).
migrate_nginx_prepare() {
  local cand err fit st blk
  st=$(migrate_state_get nginx)
  [[ $st == rendered ]] && migrate_nginx_bin >/dev/null && return 0
  cand=$(migrate_nginx_bin) || { migrate_nginx_abort "no nginx candidate binary after the build"; return 1; }
  # 3 (trial) real nginx -t blockers before anything is purged or rendered
  if ! blk=$(migrate_nginx_trial "$cand"); then
    migrate_nginx_abort "the Angie tree fails nginx -t with the new build: ${blk}" blocked keep
    return 1
  fi
  # 5a distro nginx
  if [[ -n $(migrate_pkg_list distro-nginx) ]]; then
    migrate_distro_nginx_purge || { migrate_nginx_abort "distro nginx purge failed"; return 1; }
  elif [[ -e $MIGRATE_NGINX_ETC ]]; then
    local legacy
    legacy=$(migrate_snapshot_dir nginx-legacy) || return 1
    migrate_stash "$MIGRATE_NGINX_ETC" "$legacy" || return 1
    migrate_note "leftover /etc/nginx moved to ${legacy}/etc/nginx"
  fi
  # 5b the SCN tree, then the operator files of /etc/angie
  if ! fetch_server_configs; then
    migrate_nginx_abort "could not download server-configs-nginx (${CONFIG_REPO_REF:-?})" postponed
    return 1
  fi
  local upsnap
  upsnap=$(tmp_dir nginx-upstreams.XXXXXX) || return 1
  nginx_snapshot_upstreams "$MIGRATE_ANGIE_ETC" "$upsnap"
  # The temp/log directories nginx -t opens (A's tmpfiles.d) before any test.
  declare -F nginx_build_tmpfiles_apply >/dev/null 2>&1 && nginx_build_tmpfiles_apply
  # deploy_nginx_tree tests with NGINX_TEST_BIN (the candidate) and does not
  # reload anything (NGINX_SYNC_RELOAD=0): nothing serves from /etc/nginx yet.
  migrate_nginx_test_shim_on "$cand"
  if ! NGINX_TEST_BIN=$cand NGINX_SYNC_RELOAD=0 deploy_nginx_tree; then
    migrate_nginx_abort "rendering the server-configs-nginx tree failed"
    return 1
  fi
  install -m 755 -d "$MIGRATE_NGINX_ETC/scripts"
  [[ -f $MIGRATE_NGINX_ETC/scripts/cloudflare.sh ]] && chmod 755 "$MIGRATE_NGINX_ETC/scripts/cloudflare.sh"
  migrate_copy_operator_files || { migrate_nginx_abort "copying the operator files from /etc/angie failed"; return 1; }
  nginx_restore_upstreams "$MIGRATE_NGINX_ETC" "$upsnap"
  tune_nginx_dedupe_http "$MIGRATE_NGINX_ETC" || true
  nginx_secure_auth_files "$MIGRATE_NGINX_ETC"
  # 6 ACME
  migrate_acme_to_self_signed || { migrate_nginx_abort "ACME migration failed"; return 1; }
  # Residual Angie tokens are blockers before the first test (R94).
  local residual
  residual=$(migrate_conf_closure "$MIGRATE_NGINX_ETC" "$MIGRATE_NGINX_ETC/nginx.conf" \
      | xargs -r -d '\n' grep -nsE '^[^#]*(/angie|angie\.(pid|conf|service)|\$angie_|user[[:space:]]+angie)' 2>/dev/null | head -n 5 || true)
  if [[ -n $residual ]]; then
    migrate_nginx_abort "the rendered tree still names Angie: $(printf '%s' "$residual" | paste -sd' ' -)"
    return 1
  fi
  # 7 nginx -t with the candidate.  The directives the 1.21 fit had commented
  # are live again in the copy, so the fit runs on the rendered tree with the
  # candidate: droppable directives are commented with the nginx marker (each
  # reported), anything else aborts (R26, R88).
  if ! err=$("$cand" -t -q -c "$MIGRATE_NGINX_ETC/nginx.conf" 2>&1); then
    if fit=$(migrate_nginx_fit "$MIGRATE_NGINX_ETC/nginx.conf" "$cand" 2>/dev/null) \
       && err=$("$cand" -t -q -c "$MIGRATE_NGINX_ETC/nginx.conf" 2>&1); then
      migrate_nginx_fit_report "$fit"
    else
      migrate_nginx_abort "nginx -t of the rendered tree failed: $(printf '%s' "$err" | grep -m3 -E 'emerg|error' | paste -sd' ' -)"
      return 1
    fi
  fi
  # The hardware profile before the first start (R23): local_php follows
  # the listener that serves now; caches, compression and limits are tuned.
  migrate_pin_local_php
  tune_reset_changes
  if ! NGINX_TEST_BIN=$cand nginx_apply_profile "$MIGRATE_NGINX_ETC"; then
    migrate_nginx_abort "the nginx tuner failed on the rendered tree"
    return 1
  fi
  migrate_nginx_test_shim_off
  local change
  for change in "${TUNE_CHANGES[@]}"; do migrate_report "    - tune: ${change}"; done
  if ! err=$("$cand" -t -q -c "$MIGRATE_NGINX_ETC/nginx.conf" 2>&1); then
    migrate_nginx_abort "nginx -t after tuning failed: $(printf '%s' "$err" | grep -m3 -E 'emerg|error' | paste -sd' ' -)"
    return 1
  fi
  migrate_state_set nginx rendered
  return 0
}

# Abort the nginx part before cutover: the rendered tree leaves /etc/nginx
# (so no code path takes it for a live tree) and Angie keeps serving.  KEEP
# (third argument) leaves /etc/nginx alone: the abort came before the render.
migrate_nginx_abort() {
  local why=$1 kind=${2:-blocked} keep_etc=${3:-} snap=""
  migrate_nginx_test_shim_off
  if [[ -z $keep_etc && -d $MIGRATE_NGINX_ETC ]]; then
    snap=$(migrate_snapshot_dir nginx-failed 2>/dev/null) && migrate_stash "$MIGRATE_NGINX_ETC" "$snap"
  fi
  migrate_state_set nginx "${kind}:${why}"
  migrate_state_set nginx.scan "$(migrate_nginx_scan_digest)"
  migrate_fail "nginx part ${kind}: ${why}; Angie keeps serving${snap:+ (rendered tree kept in ${snap})}"
  MIGRATE_DO_NGINX=0
}

# ---------------------------------------------------------------------------
# Step 8: cutover Angie -> nginx
# ---------------------------------------------------------------------------
migrate_nginx_cutover() {
  local base bad out angie_enabled
  migrate_assert_no_old_triggers || { migrate_nginx_abort "1.21 triggers present"; return 1; }
  command -v curl >/dev/null 2>&1 || { migrate_nginx_abort "curl is missing (the cutover cannot be verified)"; return 1; }
  base="$(migrate_run_dir)/nginx-baseline.tsv"
  migrate_baseline "$MIGRATE_ANGIE_ETC" "$base"
  migrate_state_set nginx.baseline "$base"
  angie_enabled=$(systemctl is-enabled angie.service 2>/dev/null || true)
  migrate_state_set nginx.angie-enabled "${angie_enabled:-enabled}"

  migrate_inflight_set nginx
  systemctl stop angie.service || true
  systemctl mask angie.service >/dev/null 2>&1 || true
  if ! nginx_build_ensure activate migrate migrate_out; then
    migrate_nginx_rollback "activating the nginx build failed"
    return 1
  fi
  systemctl daemon-reload || true
  migrate_clear_dsh_state nginx
  systemctl enable nginx.service >/dev/null 2>&1 || true
  if ! systemctl start nginx.service; then
    migrate_nginx_rollback "nginx did not start"
    return 1
  fi
  sleep 1
  if ! bad=$(migrate_compare_baseline "$base"); then
    migrate_nginx_rollback "vhosts answer differently than under Angie: $(printf '%s' "$bad" | head -n 5 | paste -sd'; ' -)"
    return 1
  fi
  # Verified: the part is done before the cron handover, so a run that dies
  # during write_cron or cloudflare.sh does not leave 'cutover' behind (the
  # removals, the post-assert and the apt pin all wait for 'done').  The
  # handover reports its own problems.
  migrate_state_set nginx "done"
  migrate_inflight_clear
  migrate_note "nginx serves every vhost as Angie did ($(wc -l < "$base") requests compared); Angie stopped and masked until the purge"
  migrate_cron_handover
  return 0
}

# A 1.22 draft run could die between 'cutover' and 'done'.  The switch was
# verified, so it is finished forward: the cron handover, then 'done'.
migrate_nginx_finish_cutover() {
  [[ $(migrate_state_get nginx) == cutover ]] || return 0
  systemctl is-active --quiet nginx.service 2>/dev/null || systemctl start nginx.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx.service 2>/dev/null; then
    migrate_state_set nginx "done"
    migrate_note "nginx cutover of an earlier run finished (cron handover)"
    migrate_cron_handover
  else
    # Angie is masked, not purged (the purge waits for 'done'): it serves again.
    migrate_nginx_rollback "nginx was not running after an earlier cutover"
  fi
}

migrate_nginx_rollback() {
  local why=$1 snap en
  warn "migrate: nginx cutover failed (${why}); back to Angie"
  systemctl stop nginx.service >/dev/null 2>&1 || true
  systemctl disable nginx.service >/dev/null 2>&1 || true
  systemctl unmask angie.service >/dev/null 2>&1 || true
  en=$(migrate_state_get nginx.angie-enabled)
  [[ $en == enabled ]] && systemctl enable angie.service >/dev/null 2>&1
  systemctl reset-failed angie.service >/dev/null 2>&1 || true
  systemctl start angie.service >/dev/null 2>&1 || warn "migrate: Angie did not start again; check 'systemctl status angie'"
  if [[ -d $MIGRATE_NGINX_ETC ]]; then
    snap=$(migrate_snapshot_dir nginx-failed 2>/dev/null) && migrate_stash "$MIGRATE_NGINX_ETC" "$snap"
  fi
  migrate_state_set nginx "rolled-back:${why}"
  migrate_state_set nginx.scan "$(migrate_nginx_scan_digest)"
  MIGRATE_IN_FLIGHT=""
  migrate_state_del inflight
  migrate_fail "nginx cutover rolled back to Angie: ${why}${snap:+ (tree kept in ${snap})}"
  MIGRATE_DO_NGINX=0
  return 0
}

# Cron handover (R22, R40, R43, R75): the managed block is regenerated for
# /etc/nginx, then the Cloudflare real-IP script runs once.
migrate_cron_handover() {
  local managed cand
  if declare -F write_cron >/dev/null 2>&1; then
    write_cron || migrate_warn "write_cron failed after the nginx cutover"
  fi
  managed=$(crontab -l 2>/dev/null | cron_extract_managed 2>/dev/null || true)
  if [[ -x $MIGRATE_NGINX_ETC/scripts/cloudflare.sh ]] && [[ $managed != *"/etc/nginx/scripts/cloudflare.sh"* ]]; then
    migrate_warn "the managed crontab has no /etc/nginx/scripts/cloudflare.sh job after the cutover (Cloudflare real-IP ranges would go stale)"
  fi
  [[ $managed == *"${CRON_WWW_CHOWN:-/usr/bin/find /var/www}"* ]] \
    || migrate_warn "the managed crontab has no www-data ownership job after the cutover"
  if [[ $managed == *'/etc/angie/'* ]]; then
    migrate_warn "the managed crontab still names /etc/angie"
  fi
  if [[ -x $MIGRATE_NGINX_ETC/scripts/cloudflare.sh ]]; then
    timeout 120 "$MIGRATE_NGINX_ETC/scripts/cloudflare.sh" >/dev/null 2>&1 \
      || migrate_warn "/etc/nginx/scripts/cloudflare.sh failed once after the cutover"
  fi
  cand=$(migrate_nginx_bin) || cand=${NGINX_BIN:-}
  if [[ -n $cand ]] && ! "$cand" -t -q -c "$MIGRATE_NGINX_ETC/nginx.conf" >/dev/null 2>&1; then
    migrate_warn "nginx -t fails after the Cloudflare refresh; the running configuration is unchanged"
  fi
}

# ---------------------------------------------------------------------------
# Step 9: PHP per active version (R1, R2.2, R7, R15, R24, R55, R58, R89, R92)
# ---------------------------------------------------------------------------
# PHP vhosts (name, scheme, root) of the live tree.
migrate_php_vhosts() {
  local tree name scheme file root php auth
  tree=$(migrate_web_tree)
  while IFS=$'\t' read -r name scheme file root php auth; do
    [[ $php == 1 && -n $root && -d $root ]] || continue
    printf '%s\t%s\t%s\n' "$name" "$scheme" "$root"
  done < <(migrate_vhosts "$tree")
}

# Move Sury's conf.d entries out of fpm/ and cli/ (R7, R55): mods-available
# symlinks and dpkg-owned files go to the snapshot; operator .ini files stay
# with their extension= / zend_extension= lines commented out.
migrate_php_convert_confd() {
  local v=$1 snap=$2 sapi d f target
  for sapi in fpm cli; do
    d="$MIGRATE_PHP_ETC/$v/$sapi/conf.d"
    [[ -d $d ]] || continue
    for f in "$d"/*; do
      [[ -e $f || -L $f ]] || continue
      if [[ -L $f ]]; then
        target=$(readlink "$f")
        if [[ $target == *mods-available* || ! -e $f ]]; then
          migrate_stash "$f" "$snap/confd-moved"
        fi
      elif [[ -f $f ]]; then
        if migrate_dpkg_owned "$f"; then
          migrate_stash "$f" "$snap/confd-moved"
        elif grep -qE '^[[:space:]]*(zend_)?extension[[:space:]]*=' "$f"; then
          sed_in_place -E "s/^([[:space:]]*(zend_)?extension[[:space:]]*=)/${MIGRATE_INI_OFF}\\1/" "$f"
          migrate_note "PHP ${v}: ${f}: extension lines commented (${MIGRATE_INI_OFF% }; the source build has them built in)"
        fi
      fi
    done
  done
}

# Write a temporary probe into the first PHP root that answers it through the
# web server; prints "ok <name>" or the reason.  The probe prints the PHP
# version, whether OPcache is active, a session id, the session handler and
# save path, and the user PHP runs as (R92, R89).  A static probe file is
# used rather than index.php?setup_probe because only a file of our own can
# report OPcache and the session result.  Its path is recorded in the state
# before it is written, so the EXIT hook and the next run's resume remove it
# if the run dies in between.
migrate_php_probe_cleanup() {
  local p
  p=$(migrate_state_get php-probe)
  [[ -n $p ]] || return 0
  [[ $p == */setup-probe-*.php && -f $p ]] && rm -f -- "$p"
  migrate_state_del php-probe
}

migrate_php_probe() {
  local v=$1 name scheme root rnd probe body code sid handler spath user out=""
  rnd="setup-probe-${RANDOM}${RANDOM}$$"
  while IFS=$'\t' read -r name scheme root; do
    probe="$root/${rnd}.php"
    migrate_state_set php-probe "$probe"
    cat > "$probe" <<'PHP' || { migrate_php_probe_cleanup; continue; }
<?php
header('Cache-Control: no-store');
$o = function_exists('opcache_get_status') && is_array($s = @opcache_get_status(false)) && !empty($s['opcache_enabled']);
@session_start();
$id = session_id();
@session_write_close();
$u = function_exists('posix_geteuid') && function_exists('posix_getpwuid') ? (posix_getpwuid(posix_geteuid())['name'] ?? '?') : '?';
$p = (string) ini_get('session.save_path');
if (strpos($p, ';') !== false) { $p = substr($p, strrpos($p, ';') + 1); }
echo 'setup-probe ', PHP_MAJOR_VERSION, '.', PHP_MINOR_VERSION, ' ', $o ? 'opcache' : 'no-opcache', ' ',
  $id !== '' ? $id : 'no-session', ' ', ini_get('session.save_handler') ?: '?', ' ', $u, ' ', $p !== '' ? $p : '-', "\n";
PHP
    chmod 644 "$probe"
    body=$(curl -s --max-time 15 -k --resolve "${name}:$([[ $scheme == https ]] && echo 443 || echo 80):127.0.0.1" \
             -H 'Cache-Control: no-cache' -b 'setup_probe=1' -w '\n%{http_code}' \
             "${scheme}://${name}/${rnd}.php" 2>/dev/null) || body=""
    migrate_php_probe_cleanup
    code=${body##*$'\n'}
    body=${body%$'\n'*}
    if [[ $code == 200 && $body == "setup-probe ${v} "* ]]; then
      read -r _ _ _ sid handler user spath <<<"$body"
      if [[ $body != *" opcache "* ]]; then printf 'opcache inactive on %s' "$name"; return 1; fi
      if [[ $sid == no-session ]]; then printf 'session_start failed on %s' "$name"; return 1; fi
      if [[ $handler == files ]]; then
        # R89: the files handler must have written sess_<id>, owned by the
        # user the pool runs as (a broken session directory fails here).
        local sf="" cand owner
        for cand in "${spath%/}/sess_${sid}" /var/lib/php/sessions/sess_"$sid" /var/lib/php/sessions-*/sess_"$sid"; do
          [[ $cand == -/* ]] && continue
          [[ -f $cand ]] && { sf=$cand; break; }
        done
        [[ -n $sf ]] || { printf 'no session file sess_%s in %s on %s' "$sid" "$spath" "$name"; return 1; }
        owner=$(stat -c %U -- "$sf" 2>/dev/null || true)
        rm -f -- "$sf"
        if [[ $user != '?' && $owner != "$user" ]]; then
          printf 'session file of %s is owned by %s, not the pool user %s' "$name" "${owner:-?}" "$user"; return 1
        fi
        printf 'ok %s' "$name"
        return 0
      fi
      # Another save handler (redis) keeps no file; the id is enough.
      printf 'ok %s (session handler %s)' "$name" "$handler"
      return 0
    fi
    out+="${name}=${code} "
  done < <(migrate_php_vhosts)
  printf 'denied %s' "${out:-no PHP vhost}"
  return 2
}

migrate_php_cutover() {
  local v=$1 snap base offs out en l bad pid exe msg rc
  migrate_assert_no_old_triggers || { migrate_state_set "php-${v}" "failed:1.21 triggers present"; return 1; }
  # (0) snapshot: /etc/php/X.Y, the unit's drop-in directory, enablement
  snap=$(migrate_state_get "php-${v}.snap")
  if [[ -z $snap || ! -d $snap ]]; then
    snap=$(migrate_snapshot_dir "php-${v}") || return 1
    migrate_copy_tree "$MIGRATE_PHP_ETC/$v" "$snap/etc"
    migrate_copy_tree "$MIGRATE_UNIT_DIR/php${v}-fpm.service.d" "$snap/dropins"
    systemctl is-enabled "php${v}-fpm" > "$snap/enabled" 2>/dev/null || true
    migrate_php_listeners "$v" > "$snap/listeners"
    migrate_state_set "php-${v}.snap" "$snap"
  fi
  en=$(cat "$snap/enabled" 2>/dev/null || true)
  base="$snap/baseline.tsv"
  migrate_baseline "$(migrate_web_tree)" "$base"
  offs="$snap/log-offsets"
  migrate_log_offsets > "$offs"

  migrate_inflight_set "php-${v}"
  # (1) stop while the package definition is loaded (its ExecStopPost runs)
  systemctl stop "php${v}-fpm" || true
  [[ -L /run/php/php-fpm.sock ]] && migrate_stash /run/php/php-fpm.sock "$snap/runtime"
  # The 1.21 drop-in would override our ExecStart (it is in the snapshot).
  [[ -e $MIGRATE_UNIT_DIR/php${v}-fpm.service.d/zz-setup-build.conf ]] \
    && migrate_stash "$MIGRATE_UNIT_DIR/php${v}-fpm.service.d/zz-setup-build.conf" "$snap/live"
  # (1b) Sury conf.d entries out, before any managed file is written
  migrate_php_convert_confd "$v" "$snap"
  # (2) our binary, unit and layout (tmpfiles applied inside, R89)
  if ! PHP_EXT_DETECT_TREE=$(migrate_php_detect_tree) php_build_ensure "$v" activate migrate migrate_out; then
    migrate_php_rollback "$v" "activating the PHP ${v} build failed"; return 1
  fi
  if ! php_build_layout "$v" adopt; then
    migrate_php_rollback "$v" "writing the /etc/php/${v} layout failed"; return 1
  fi
  systemctl daemon-reload || true
  migrate_clear_dsh_state "php${v}-fpm"
  # (3) reenable re-points the wants link at our file
  systemctl reenable "php${v}-fpm" >/dev/null 2>&1 || true
  [[ $en == enabled ]] || [[ -z $en ]] || systemctl disable "php${v}-fpm" >/dev/null 2>&1 || true
  # (4) start and verify
  if ! systemctl start "php${v}-fpm"; then
    migrate_php_rollback "$v" "php${v}-fpm did not start on the source build"; return 1
  fi
  if ! msg=$(php_fpm_test "$v" 2>&1) || grep -qiE 'Unable to load|already loaded' <<<"$msg"; then
    migrate_php_rollback "$v" "php-fpm -t: $(printf '%s' "$msg" | grep -m2 -iE 'error|unable|already' | paste -sd' ' -)"; return 1
  fi
  msg=$("$(migrate_php_cli_bin "$v")" -v 2>&1 || true)
  if grep -qiE 'Unable to load|already loaded' <<<"$msg"; then
    migrate_php_rollback "$v" "the CLI prints load warnings: $(head -n1 <<<"$msg")"; return 1
  fi
  if ! "$(migrate_php_cli_bin "$v")" -r 'exit(function_exists("opcache_get_status") ? 0 : 1);' >/dev/null 2>&1; then
    migrate_php_rollback "$v" "OPcache is not loaded in the CLI"; return 1
  fi
  pid=$(systemctl show -p MainPID --value "php${v}-fpm" 2>/dev/null || true)
  exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
  if [[ $exe != "$(migrate_php_root)/${v}/"* ]]; then
    migrate_php_rollback "$v" "the running master is ${exe:-unknown}, not the source build"; return 1
  fi
  sleep 1
  while IFS= read -r l; do
    [[ -n $l ]] || continue
    migrate_listener_up "$l" || { migrate_php_rollback "$v" "listener ${l} does not accept connections"; return 1; }
  done < "$snap/listeners"
  rc=0; msg=$(migrate_php_probe "$v") || rc=$?
  if (( rc == 1 )); then
    migrate_php_rollback "$v" "probe: ${msg}"; return 1
  elif (( rc == 2 )); then
    migrate_warn "PHP ${v}: the probe script was refused by every PHP vhost (${msg}); verified by the vhost answers, the master binary and the logs"
  fi
  if ! bad=$(migrate_compare_baseline "$base"); then
    migrate_php_rollback "$v" "vhosts answer differently: $(printf '%s' "$bad" | head -n 5 | paste -sd'; ' -)"; return 1
  fi
  bad=$(migrate_log_fatals "$offs")
  if [[ -n $bad ]]; then
    migrate_php_rollback "$v" "new fatal errors in the logs: $(printf '%s' "$bad" | head -n 3 | paste -sd' ' -)"; return 1
  fi
  # Verified.  No update-alternatives entry for our CLI (R2.1: /usr/bin/php
  # is a plain symlink, never an alternative): an entry would keep
  # /etc/alternatives/php alive after the Sury purge, B's php_build_links
  # would then never re-point /usr/bin/php on an --upgrade-php switch, and
  # cron would run a retired series.  Until the purge frees /usr/bin/php,
  # the managed cron lines reach a working CLI through php_cli_path (the
  # package CLI at /usr/bin/php, else /usr/local/bin/php); the post-purge
  # assertions link /usr/bin/php to our build.  An entry an earlier 1.22
  # draft registered is removed here.
  migrate_php_alt_cleanup
  # Our generated /etc/php, for the post-purge re-lay of pool.d (R24).
  local conv
  conv=$(migrate_snapshot_dir "php-${v}-converted") || conv=""
  [[ -n $conv ]] && migrate_copy_tree "$MIGRATE_PHP_ETC/$v" "$conv/etc" && migrate_state_set "php-${v}.converted" "$conv"
  migrate_php_retire_old_layout "$v" "$snap"
  # The active-version marker at the cutover (R61), not only after the
  # removals: B's php_build_start on the next --optimize and the links key
  # off it, and a deferred Sury purge may hold the post-assert back for days.
  if [[ $v == "$(migrate_primary_version)" || ! -s $MIGRATE_PHP_ETC/setup-active ]]; then
    migrate_php_set_active "$v"
  fi
  migrate_state_set "php-${v}" "done"
  migrate_inflight_clear
  migrate_note "PHP ${v} serves from the source build (${msg#ok }); Sury unit replaced, configuration snapshot ${snap}"
  return 0
}

# The active version (one owns the shared socket, R61): the recorded
# /etc/php/setup-active when that version still has a tree, else the running
# version whose pool owns Angie's local_php listener (what serves PHP now),
# else F's php_primary_version, else the newest running Sury version.
migrate_primary_version() {
  local v l listen
  v=$(tr -d '[:space:]' < "$MIGRATE_PHP_ETC/setup-active" 2>/dev/null || true)
  # A marker counts only for a version that runs or has our build.
  if [[ $v =~ ^[0-9]+\.[0-9]+$ && -d $MIGRATE_PHP_ETC/$v ]] \
     && { [[ -x $(migrate_php_active_bin "$v") ]] || migrate_sury_active_versions | grep -qxF -- "$v"; }; then
    printf '%s' "$v"; return 0
  fi
  listen=$(migrate_angie_local_php_listener)
  if [[ -n $listen ]]; then
    while IFS= read -r v; do
      [[ -n $v ]] || continue
      while IFS= read -r l; do
        [[ ${l#unix:} == "$listen" ]] && { printf '%s' "$v"; return 0; }
      done < <(migrate_php_listeners "$v")
    done < <(migrate_sury_active_versions)
  fi
  if declare -F php_primary_version >/dev/null 2>&1; then
    v=$(php_primary_version 2>/dev/null || true)
    [[ -n $v ]] && { printf '%s' "$v"; return 0; }
  fi
  migrate_sury_active_versions | tail -n1
}

# /etc/php/setup-active (B's php_active_set when loaded) plus PHP_ACTIVE.
migrate_php_set_active() {
  local v=$1
  if declare -F php_active_set >/dev/null 2>&1; then
    php_active_set "$v" || return 1
  else
    printf '%s\n' "$v" > "$MIGRATE_PHP_ETC/setup-active.new" \
      && chmod 644 "$MIGRATE_PHP_ETC/setup-active.new" \
      && mv -f "$MIGRATE_PHP_ETC/setup-active.new" "$MIGRATE_PHP_ETC/setup-active" || return 1
  fi
  declare -F persist_tuning_var >/dev/null 2>&1 && persist_tuning_var PHP_ACTIVE "$v"
  return 0
}

# 1.21 compiled layout and tool of a version leave after its cutover (R3).
migrate_php_retire_old_layout() {
  local v=$1 snap=$2 root f
  root=$(migrate_php_root)
  for f in "$root/$v/php-fpm" "$root/$v/php-fpm.lto" "$root/$v/php-fpm.new" /run/setup-php-build/"$v"; do
    [[ -e $f ]] && migrate_stash "$f" "$snap/old-layout"
  done
  # The relocated tool goes when no drop-in calls it any more.
  local legacy
  legacy=$(migrate_state_get legacy-php)
  if [[ -n $legacy && -d $legacy ]] && ! grep -qsF -- "$legacy/" "$MIGRATE_UNIT_DIR"/*.service.d/zz-setup-build.conf; then
    migrate_stash "$legacy" "$snap/old-layout" && migrate_state_del legacy-php
  fi
}

migrate_php_rollback() {
  local v=$1 why=$2 snap frag en
  warn "migrate: PHP ${v} cutover failed (${why}); back to the package"
  snap=$(migrate_state_get "php-${v}.snap")
  systemctl stop "php${v}-fpm" >/dev/null 2>&1 || systemctl kill -s KILL "php${v}-fpm" >/dev/null 2>&1 || true
  if [[ -n $snap && -d $snap ]]; then
    [[ -e $(migrate_unit_file "php${v}-fpm") ]] && migrate_stash "$(migrate_unit_file "php${v}-fpm")" "$snap/ours"
    # The 1.21 drop-in is NOT restored: its tool is retired; the package
    # binary serves the rollback (Sury's own configuration comes back).
    if [[ -d $snap/dropins ]]; then
      migrate_restore_exact "$snap/dropins" "$MIGRATE_UNIT_DIR/php${v}-fpm.service.d" "$snap/ours/dropins-$(migrate_stamp)" || true
      [[ -e $MIGRATE_UNIT_DIR/php${v}-fpm.service.d/zz-setup-build.conf ]] \
        && migrate_stash "$MIGRATE_UNIT_DIR/php${v}-fpm.service.d/zz-setup-build.conf" "$snap/ours/legacy-dropin"
    elif [[ -e $snap/dropins.absent && -e $MIGRATE_UNIT_DIR/php${v}-fpm.service.d ]]; then
      mkdir -p "$snap/ours" && mv -- "$MIGRATE_UNIT_DIR/php${v}-fpm.service.d" "$snap/ours/dropins-$(migrate_stamp)"
    fi
    if [[ -d $snap/etc ]]; then
      migrate_restore_exact "$snap/etc" "$MIGRATE_PHP_ETC/$v" "$snap/ours/etc-$(migrate_stamp)" \
        || warn "migrate: could not restore /etc/php/${v} from ${snap}/etc"
    fi
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "php${v}-fpm" >/dev/null 2>&1 || true
  systemctl reenable "php${v}-fpm" >/dev/null 2>&1 || true
  en=$(cat "$snap/enabled" 2>/dev/null || true)
  [[ $en == enabled ]] || systemctl disable "php${v}-fpm" >/dev/null 2>&1 || true
  systemctl start "php${v}-fpm" >/dev/null 2>&1 || warn "migrate: php${v}-fpm did not start on the package either; check 'systemctl status php${v}-fpm'"
  frag=$(migrate_fragment_path "php${v}-fpm")
  [[ $frag == /lib/* || $frag == /usr/lib/* ]] || warn "migrate: php${v}-fpm FragmentPath is ${frag:-unknown} after the rollback"
  migrate_state_set "php-${v}" "failed:${why}"
  migrate_state_set "php-${v}.scan" "$(migrate_php_scan_digest "$v")"
  MIGRATE_IN_FLIGHT=""
  migrate_state_del inflight
  migrate_fail "PHP ${v} rolled back to the Sury package: ${why} (it is not purged)"
  return 0
}

# ---------------------------------------------------------------------------
# Step 10: Valkey (R28, R29, R49, R86, R90)
# ---------------------------------------------------------------------------
migrate_valkey_scan_digest() {
  { cat "$MIGRATE_VALKEY_ETC/valkey.conf" 2>/dev/null; dpkg-query -W -f='${Version}' valkey-server 2>/dev/null; } \
    | md5sum | awk '{ print $1 }'
}

# 0 when the dataset is persisted (R28, R49).  The running server is asked
# first (CONFIG GET save / appendonly).  When it cannot answer (stopped,
# CONFIG renamed), the file decides: with no `save` line at all Valkey's
# built-in RDB schedule is ON (Debian's valkey.conf only has the save lines
# commented out), so only an explicit `save ""` with appendonly no is off.
migrate_valkey_persists() {
  local c=$MIGRATE_VALKEY_ETC/valkey.conf save aof live cli
  cli=${1:-$(command -v valkey-cli || command -v redis-cli || true)}
  if [[ -n $cli ]]; then
    live=$(migrate_valkey_cmd "$cli" CONFIG GET save | sed -n 2p || true)
    aof=$(migrate_valkey_cmd "$cli" CONFIG GET appendonly | sed -n 2p || true)
    if [[ ${aof,,} == yes || ${aof,,} == no ]]; then
      [[ ${aof,,} == yes || -n ${live//[[:space:]\"]/} ]]
      return
    fi
  fi
  [[ -f $c ]] || return 0
  save=$(awk '$1 == "save" { n++; $1 = ""; v = $0 } END { if (n == 0) print "default"; else { gsub(/^ +|"/, "", v); print v } }' "$c")
  aof=$(awk '$1 == "appendonly" { v = $2 } END { print v }' "$c")
  [[ -n $save || ${aof,,} == yes ]]
}

# valkey-cli CLI ARGS... against the configured socket/port; the password
# goes through the environment, never the command line.
migrate_valkey_cmd() {
  local vcli=$1 c=$MIGRATE_VALKEY_ETC/valkey.conf sock port pass
  shift
  [[ -x $vcli ]] || return 1
  sock=$(awk '$1 == "unixsocket" { v = $2 } END { print v }' "$c" 2>/dev/null)
  port=$(awk '$1 == "port" { v = $2 } END { print v }' "$c" 2>/dev/null)
  pass=$(awk '$1 == "requirepass" { $1 = ""; sub(/^ +/, ""); gsub(/^"|"$/, ""); v = $0 } END { print v }' "$c" 2>/dev/null)
  local -a target=()
  if [[ -n $sock && -S $sock ]]; then target=(-s "$sock"); else target=(-h 127.0.0.1 -p "${port:-6379}"); fi
  REDISCLI_AUTH=$pass VALKEYCLI_AUTH=$pass timeout 10 "$vcli" "${target[@]}" "$@" 2>/dev/null
}

migrate_valkey_cutover() {
  local snap out en before="" after pid exe pkgcli
  migrate_assert_no_old_triggers || { migrate_state_set valkey "failed:1.21 triggers present"; return 1; }
  snap=$(migrate_snapshot_dir valkey) || return 1
  migrate_state_set valkey.snap "$snap"
  pkgcli=$(command -v valkey-cli || command -v redis-cli || true)
  # Asked while the package server still runs (it knows its real settings).
  migrate_valkey_persists "$pkgcli" && echo 1 > "$snap/persists"
  [[ -n $pkgcli ]] && before=$(migrate_valkey_cmd "$pkgcli" DBSIZE | tr -dc '0-9')
  printf '%s' "$before" > "$snap/dbsize"
  systemctl is-enabled valkey-server > "$snap/enabled" 2>/dev/null || true
  en=$(cat "$snap/enabled")

  migrate_inflight_set valkey
  # (1) stop the package server first: with persistence on it writes its
  # RDB/AOF now, so the snapshot below is consistent (R28).
  systemctl stop valkey-server || true
  # (0) snapshot while nothing runs; disk checked against the current size.
  local need msg
  need=$(( $(migrate_size_mb "$MIGRATE_VALKEY_DATA" "$MIGRATE_VALKEY_ETC") + 64 ))
  if ! msg=$(migrate_disk_fits "$MIGRATE_BACKUP_ROOT" "$need"); then
    systemctl start valkey-server >/dev/null 2>&1 || true
    migrate_inflight_clear
    migrate_state_set valkey "postponed:disk"
    migrate_fail "Valkey postponed: no room for the dataset snapshot (${msg}); the package serves again"
    return 1
  fi
  migrate_copy_tree "$MIGRATE_VALKEY_ETC" "$snap/etc"
  migrate_copy_tree "$MIGRATE_VALKEY_DATA" "$snap/data"
  migrate_copy_tree "$MIGRATE_UNIT_DIR/valkey-server.service.d" "$snap/dropins"
  [[ -L $MIGRATE_UNIT_DIR/valkey.service ]] && cp -a "$MIGRATE_UNIT_DIR/valkey.service" "$snap/valkey.service.alias"
  id -u valkey > "$snap/uid" 2>/dev/null || true
  id -g valkey > "$snap/gid" 2>/dev/null || true
  [[ -e $MIGRATE_UNIT_DIR/valkey-server.service.d/zz-setup-build.conf ]] \
    && migrate_stash "$MIGRATE_UNIT_DIR/valkey-server.service.d/zz-setup-build.conf" "$snap/live"
  if ! valkey_build_ensure activate migrate migrate_out; then
    migrate_valkey_rollback "activating the Valkey build failed"; return 1
  fi
  # The package's alias points at /lib; reenable re-points it at our unit.
  if [[ -L $MIGRATE_UNIT_DIR/valkey.service ]] && [[ $(readlink -f "$MIGRATE_UNIT_DIR/valkey.service") != "$(migrate_unit_file valkey-server)" ]]; then
    migrate_stash "$MIGRATE_UNIT_DIR/valkey.service" "$snap/ours"
  fi
  systemctl daemon-reload || true
  migrate_clear_dsh_state valkey-server
  systemctl reenable valkey-server >/dev/null 2>&1 || true
  [[ $en == enabled || -z $en ]] || systemctl disable valkey-server >/dev/null 2>&1 || true
  if ! systemctl start valkey-server; then
    migrate_valkey_rollback "valkey-server did not start on the source build"; return 1
  fi
  pid=$(systemctl show -p MainPID --value valkey-server 2>/dev/null || true)
  exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
  if [[ $exe != "$(migrate_valkey_root)/"* ]]; then
    migrate_valkey_rollback "the running server is ${exe:-unknown}, not the source build"; return 1
  fi
  local try pong=""
  for try in 1 2 3 4 5 6 7 8 9 10; do
    pong=$(migrate_valkey_cmd "$(migrate_valkey_cli)" PING || true)
    [[ $pong == PONG ]] && break
    sleep 1
  done
  [[ $pong == PONG ]] || { migrate_valkey_rollback "PING through $(migrate_valkey_cli) failed"; return 1; }
  if [[ -s $snap/persists && $before =~ ^[0-9]+$ ]] && (( before > 0 )); then
    after=$(migrate_valkey_cmd "$(migrate_valkey_cli)" DBSIZE | tr -dc '0-9')
    if [[ ! $after =~ ^[0-9]+$ ]] || (( after * 100 < before * 95 )); then
      migrate_valkey_rollback "the dataset did not load (${before} keys before, ${after:-?} after)"; return 1
    fi
  fi
  [[ -d $(migrate_valkey_root)/build ]] && migrate_stash "$(migrate_valkey_root)/build" "$snap/old-layout"
  local legacy
  legacy=$(migrate_state_get legacy-valkey)
  [[ -n $legacy && -d $legacy ]] && migrate_stash "$legacy" "$snap/old-layout" && migrate_state_del legacy-valkey
  migrate_state_set valkey "done"
  migrate_inflight_clear
  migrate_note "Valkey serves from the source build$( [[ -s $snap/persists ]] && printf ' (dataset %s keys)' "${before:-?}"); snapshot ${snap}"
  return 0
}

migrate_valkey_rollback() {
  local why=$1 snap uid
  warn "migrate: Valkey cutover failed (${why}); back to the package"
  snap=$(migrate_state_get valkey.snap)
  # Ours stops WITHOUT saving: a newer RDB/AOF would not load in the
  # package's older server (R28, R49).
  migrate_valkey_cmd "$(migrate_valkey_cli)" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
  systemctl kill -s KILL valkey-server >/dev/null 2>&1 || true
  systemctl stop valkey-server >/dev/null 2>&1 || true
  if [[ -n $snap && -d $snap ]]; then
    [[ -e $(migrate_unit_file valkey-server) ]] && migrate_stash "$(migrate_unit_file valkey-server)" "$snap/ours"
    [[ -L $MIGRATE_UNIT_DIR/valkey.service ]] && migrate_stash "$MIGRATE_UNIT_DIR/valkey.service" "$snap/ours/alias"
    if [[ -d $snap/dropins ]]; then
      migrate_restore_exact "$snap/dropins" "$MIGRATE_UNIT_DIR/valkey-server.service.d" "$snap/ours/dropins" || true
      # The 1.21 drop-in's tool is retired: the package binary serves.
      [[ -e $MIGRATE_UNIT_DIR/valkey-server.service.d/zz-setup-build.conf ]] \
        && migrate_stash "$MIGRATE_UNIT_DIR/valkey-server.service.d/zz-setup-build.conf" "$snap/ours/legacy-dropin"
    elif [[ -e $snap/dropins.absent && -e $MIGRATE_UNIT_DIR/valkey-server.service.d ]]; then
      mkdir -p "$snap/ours" && mv -- "$MIGRATE_UNIT_DIR/valkey-server.service.d" "$snap/ours/dropins"
    fi
    if [[ -e $snap/valkey.service.alias || -L $snap/valkey.service.alias ]]; then
      cp -a "$snap/valkey.service.alias" "$MIGRATE_UNIT_DIR/valkey.service" 2>/dev/null || true
    fi
    [[ -d $snap/etc ]] && migrate_restore_exact "$snap/etc" "$MIGRATE_VALKEY_ETC" "$snap/ours/etc" || true
    if [[ -s $snap/persists && -d $snap/data ]]; then
      migrate_restore_exact "$snap/data" "$MIGRATE_VALKEY_DATA" "$snap/ours/data" || true
      chown -R valkey:valkey "$MIGRATE_VALKEY_DATA" 2>/dev/null || true
    fi
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed valkey-server >/dev/null 2>&1 || true
  systemctl enable --now valkey-server >/dev/null 2>&1 || systemctl start valkey-server >/dev/null 2>&1 \
    || warn "migrate: valkey-server did not start on the package either"
  uid=$(migrate_fragment_path valkey-server)
  [[ $uid == /lib/* || $uid == /usr/lib/* ]] || warn "migrate: valkey-server FragmentPath is ${uid:-unknown} after the rollback"
  migrate_state_set valkey "failed:${why}"
  migrate_state_set valkey.scan "$(migrate_valkey_scan_digest)"
  MIGRATE_IN_FLIGHT=""
  migrate_state_del inflight
  migrate_fail "Valkey rolled back to the package: ${why}"
  return 0
}

# ---------------------------------------------------------------------------
# Step 11: removals, then one re-lay / enable / assert / verify pass
# ---------------------------------------------------------------------------
migrate_removals() {
  local debs angie_ok=0 sury_ok=0 valkey_ok=0 v st resume=0
  local -a done_php=()
  # Versions on our build: the running ones and any migrated earlier.
  sury_ok=1
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    if [[ $(migrate_state_get "php-${v}") == "done" ]]; then done_php+=("$v"); else sury_ok=0; fi
  done < <(migrate_sury_active_versions)
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    [[ " ${done_php[*]} " == *" $v "* ]] || done_php+=("$v")
  done < <(sed -nE 's/^php-([0-9]+\.[0-9]+)=done$/\1/p' "$MIGRATE_STATE_FILE" 2>/dev/null)
  # Sury goes only when every running version is on our build.
  (( ${#done_php[@]} > 0 )) || sury_ok=0
  [[ -n $(migrate_pkg_list sury) ]] || sury_ok=0
  case $(migrate_state_get sury-purge) in done) sury_ok=0 ;; esac
  [[ $(migrate_state_get nginx) == "done" && -n $(migrate_pkg_list angie) ]] && angie_ok=1
  case $(migrate_state_get angie-purge) in
    done) angie_ok=0 ;;
    deferred:*) migrate_removal_possible angie || angie_ok=0 ;;
  esac
  [[ $(migrate_state_get valkey) == "done" ]] && migrate_valkey_pkg_present && valkey_ok=1
  case $(migrate_state_get valkey-remove) in
    done|removed) valkey_ok=0 ;;
    deferred:*) migrate_removal_possible valkey || valkey_ok=0 ;;
  esac
  case $(migrate_state_get removals) in started|pending|post-purge-failed) resume=1 ;; esac

  if (( ! angie_ok && ! sury_ok && ! valkey_ok )); then
    # Nothing to remove this run.  An interrupted or failed removal phase is
    # finished forward: re-lay, links, enable, verify, then the clean-up.
    (( resume )) || return 0
    migrate_policy_remove
    migrate_removals_verify "${done_php[@]}" || return 1
    migrate_removals_finalize "$(migrate_state_get debs)"
    return 0
  fi

  migrate_assert_no_old_triggers || return 1
  debs=$(migrate_snapshot_dir debs) || return 1
  migrate_state_set debs "$debs"
  # Package lists and their .debs while the repositories still exist (R18).
  local -a angie_pkgs=() sury_pkgs=() valkey_pkgs=()
  (( angie_ok )) && mapfile -t angie_pkgs < <(migrate_pkg_list angie)
  if (( sury_ok )); then
    if migrate_sury_purge_preflight && (( ${#MIGRATE_SURY_PKGS[@]} > 0 )); then
      sury_pkgs=("${MIGRATE_SURY_PKGS[@]}")
      (( ${#MIGRATE_SIM_COLLATERAL[@]} )) && migrate_warn "the Sury purge also removes ${MIGRATE_SIM_COLLATERAL[*]} (SETUP_PHP_ALLOW_COLLATERAL=1)"
      # The holds of an earlier deferral go now, or apt refuses the purge
      # ("Held packages were changed and -y was used").
      migrate_sury_unhold
    else
      (( ${#MIGRATE_SIM_COLLATERAL[@]} > 0 )) && migrate_sury_defer
      sury_ok=0
    fi
  fi
  (( valkey_ok )) && mapfile -t valkey_pkgs < <(migrate_pkg_list valkey)
  migrate_save_debs "$debs" "${angie_pkgs[@]}" "${sury_pkgs[@]}" "${valkey_pkgs[@]}"
  local f
  for f in /etc/apt/sources.list.d/*; do
    [[ -f $f ]] && grep -qsE 'download\.angie\.software|packages\.sury\.org|ondrej/php|ondrej/nginx|nginx\.org/packages' "$f" \
      && cp -a -- "$f" "$debs/"
  done
  (( angie_ok || sury_ok || valkey_ok )) || { migrate_removals_verify "${done_php[@]}"; return $?; }

  # The post-removal pass compares against the vhost answers of NOW, not the
  # cutover baseline: a deferred removal may run weeks after the cutover,
  # and vhosts the operator changed since are not the removal's doing.
  local rbase
  rbase="$(migrate_run_dir)/removals-baseline.tsv"
  if migrate_baseline "$(migrate_web_tree)" "$rbase"; then
    migrate_state_set removals.baseline "$rbase"
  else
    migrate_state_del removals.baseline
  fi

  migrate_policy_install || return 1
  migrate_inflight_set purge
  migrate_state_set removals started

  # Angie: /etc/angie and every Angie state file into the backups FIRST
  # (R74, R82), then the guarded purge.
  if (( angie_ok )); then
    if migrate_purge_sim purge "${angie_pkgs[@]}" && (( ${#MIGRATE_SIM_COLLATERAL[@]} == 0 )); then
      if migrate_angie_move_aside && migrate_apt_remove purge "${angie_pkgs[@]}"; then
        migrate_state_set angie-purge purged
      else
        migrate_state_set angie-purge "deferred:apt failed"
        migrate_warn "the Angie purge failed; Angie stays installed and masked"
      fi
    else
      migrate_state_set angie-purge "deferred:collateral ${MIGRATE_SIM_COLLATERAL[*]}"
      migrate_warn "the Angie purge would also remove ${MIGRATE_SIM_COLLATERAL[*]:-?}; Angie stays installed and masked"
    fi
  fi
  # Sury: session files and the whole /etc/php aside (R52), then the purge
  # (the conffiles go with it; the verify pass re-lays ours).
  if (( sury_ok )); then
    local sess allphp
    # Snapshotted once: a run resuming an interrupted purge finds a session
    # directory the purge may already have emptied, and must not replace
    # the good copy with it (same rule as angie-moved, R74).
    sess=$(migrate_state_get php-sessions)
    if [[ -z $sess || ! -d $sess ]]; then
      sess=$(migrate_snapshot_dir php-sessions) || sess=""
      [[ -n $sess && -d /var/lib/php/sessions ]] && cp -a /var/lib/php/sessions "$sess/" 2>/dev/null
      migrate_state_set php-sessions "$sess"
    fi
    allphp=$(migrate_state_get php-etc-prepurge)
    if [[ -z $allphp || ! -d $allphp ]]; then
      allphp=$(migrate_snapshot_dir php-etc-prepurge) && migrate_copy_tree "$MIGRATE_PHP_ETC" "$allphp/etc-php" \
        && migrate_state_set php-etc-prepurge "$allphp"
    fi
    migrate_state_set sury-purge started
    if migrate_apt_remove purge "${sury_pkgs[@]}"; then
      migrate_state_set sury-purge purged
    else
      migrate_state_set sury-purge "failed:apt"
      migrate_warn "the Sury purge failed part-way; the verify pass below restores our files"
    fi
  fi
  # Valkey: remove, never purge (its postrm purge can delete /var/lib/valkey
  # and the valkey user, R2, R86, R90).  The rc state is a known leftover.
  if (( valkey_ok )); then
    local vsnap
    vsnap=$(migrate_state_get valkey.snap)
    if migrate_purge_sim remove "${valkey_pkgs[@]}" && (( ${#MIGRATE_SIM_COLLATERAL[@]} == 0 )); then
      if migrate_apt_remove remove "${valkey_pkgs[@]}"; then
        migrate_state_set valkey-remove removed
      else
        migrate_state_set valkey-remove "deferred:apt failed"
      fi
      # Our valkey.conf must survive (it is the package's conffile).
      if [[ -n $vsnap && -f $vsnap/etc/valkey.conf ]] && ! [[ -f $MIGRATE_VALKEY_ETC/valkey.conf ]]; then
        cp -a "$vsnap/etc/valkey.conf" "$MIGRATE_VALKEY_ETC/valkey.conf"
      fi
      migrate_valkey_user_ensure "$vsnap"
    else
      migrate_state_set valkey-remove "deferred:collateral ${MIGRATE_SIM_COLLATERAL[*]}"
      migrate_warn "removing valkey-server would also remove ${MIGRATE_SIM_COLLATERAL[*]:-?}; the package stays installed"
    fi
  fi
  migrate_policy_remove
  migrate_removals_verify "${done_php[@]}" || return 1
  migrate_removals_finalize "$debs"
  return 0
}

# Re-lay, links, tmpfiles, enable, assert, restart, verify; one repair
# attempt; then "post-purge-failed" with the manual rollback (R18).
migrate_removals_verify() {
  local debs
  debs=$(migrate_state_get debs)
  MIGRATE_PA_ERRORS=()
  if ! migrate_post_assert "$@"; then
    warn "migrate: post-removal verification failed; one repair attempt"
    MIGRATE_PA_ERRORS=()
    if ! migrate_post_assert "$@"; then
      local e
      for e in "${MIGRATE_PA_ERRORS[@]}"; do migrate_fail "$e"; done
      [[ $(migrate_state_get sury-purge) == purged ]] && migrate_state_set sury-purge post-purge-failed
      migrate_state_set removals post-purge-failed
      migrate_inflight_clear
      migrate_fail "services do not verify after the package removals.  Manual rollback: dpkg -i ${debs:-${MIGRATE_BACKUP_ROOT}/debs-*}/*.deb (the repository files are still configured; copies next to the .debs), restore the /etc trees from ${MIGRATE_BACKUP_ROOT} (php-*/etc, valkey-*/etc and data, angie-*), then systemctl daemon-reload and restart the units"
      return 1
    fi
  fi
  migrate_inflight_clear
  migrate_state_set removals "done"
  migrate_state_del removals.baseline
  return 0
}

# After a verified removal phase: sources and keyrings (only now, R18),
# Angie leftovers, the apt pin.
migrate_removals_finalize() {
  local debs=${1:-} angie=0 sury=0 valkey=0
  [[ -n $debs && -d $debs ]] || debs=$(migrate_snapshot_dir debs) || return 0
  [[ $(migrate_state_get angie-purge) == purged ]] && angie=1
  [[ $(migrate_state_get sury-purge) == purged || $(migrate_state_get sury-purge) == post-purge-failed ]] && sury=1
  [[ $(migrate_state_get valkey-remove) == removed ]] && valkey=1
  migrate_retire_sources "$debs" "$angie" "$sury"
  (( angie )) && migrate_angie_after_purge
  (( sury )) && migrate_state_set sury-purge "done"
  (( valkey )) && migrate_state_set valkey-remove "done"
  migrate_write_apt_pin "$angie" "$sury" "$valkey"
  (( angie || sury || valkey )) && migrate_note "package removals verified; .debs and repository files for a manual rollback in ${debs}"
  return 0
}

# Collateral on the Sury purge: deferred, the remaining Sury PHP packages
# held so an upgrade cannot rewrite our conf.d or restart our unit (R9, R17).
migrate_sury_defer() {
  local -a pkgs=()
  mapfile -t pkgs < <(migrate_pkg_list sury | while IFS= read -r p; do migrate_pkg_installed "$p" && printf '%s\n' "$p"; done)
  migrate_state_set sury-purge "deferred:${MIGRATE_SIM_COLLATERAL[*]}"
  if (( ${#pkgs[@]} )); then
    # Only packages that were not held already are ours to unhold later; an
    # operator's own hold stays the operator's.
    local -a ours=()
    local held p
    held=" $(apt-mark showhold 2>/dev/null | sed 's/:.*//' | tr '\n' ' ') $(migrate_state_get sury-held) "
    for p in "${pkgs[@]}"; do
      if [[ $held == *" $p "* ]]; then
        [[ " $(migrate_state_get sury-held) " == *" $p "* ]] && ours+=("$p")
      else
        ours+=("$p")
      fi
    done
    if (( ${#ours[@]} )) && apt-mark hold "${ours[@]}" >/dev/null 2>&1; then
      migrate_state_set sury-held "${ours[*]}"
    fi
  fi
  migrate_warn "Sury purge deferred: it would also remove ${MIGRATE_SIM_COLLATERAL[*]}.  PHP serves from the source build; the Sury packages are held (apt-mark hold).  Re-home those applications, or set SETUP_PHP_ALLOW_COLLATERAL=1, and re-run --optimize"
}

# Undo exactly the holds migrate_sury_defer set (sury-held), right before
# the real purge.  Packages already gone are skipped.
migrate_sury_unhold() {
  local held p
  local -a pkgs=()
  held=$(migrate_state_get sury-held)
  [[ -n $held ]] || return 0
  for p in $held; do
    dpkg-query -W -f='${db:Status-Abbrev}' "$p" >/dev/null 2>&1 && pkgs+=("$p")
  done
  if (( ${#pkgs[@]} )) && ! apt-mark unhold "${pkgs[@]}" >/dev/null 2>&1; then
    migrate_warn "apt-mark unhold failed for ${pkgs[*]}; the Sury purge may be refused"
    return 1
  fi
  migrate_state_del sury-held
  return 0
}

# valkey-server's postrm can delete the valkey user and group; our unit runs
# as valkey and /var/lib/valkey belongs to it.  Re-created with the uid/gid
# recorded in the cutover snapshot (D's valkey_build_layout when loaded).
migrate_valkey_user_ensure() {
  local snap=${1:-} uid="" gid=""
  id -u valkey >/dev/null 2>&1 && return 0
  if declare -F valkey_build_layout >/dev/null 2>&1; then
    valkey_build_layout >/dev/null 2>&1 || true
  fi
  if ! id -u valkey >/dev/null 2>&1; then
    [[ -n $snap ]] && uid=$(tr -dc '0-9' < "$snap/uid" 2>/dev/null || true)
    [[ -n $snap ]] && gid=$(tr -dc '0-9' < "$snap/gid" 2>/dev/null || true)
    getent group valkey >/dev/null 2>&1 \
      || groupadd --system ${gid:+--gid "$gid"} valkey 2>/dev/null || groupadd --system valkey 2>/dev/null || true
    useradd --system --gid valkey --home-dir "$MIGRATE_VALKEY_DATA" --no-create-home --shell /usr/sbin/nologin \
      ${uid:+--uid "$uid"} valkey 2>/dev/null \
      || useradd --system --gid valkey --home-dir "$MIGRATE_VALKEY_DATA" --no-create-home --shell /usr/sbin/nologin valkey 2>/dev/null || true
  fi
  if id -u valkey >/dev/null 2>&1; then
    chown -R valkey:valkey "$MIGRATE_VALKEY_DATA" 2>/dev/null || true
    migrate_note "the valkey user was removed with the package; re-created (uid $(id -u valkey))"
  else
    migrate_warn "the valkey user is missing after the package removal and could not be re-created"
  fi
}

migrate_angie_move_aside() {
  local snap f
  snap=$(migrate_state_get angie-moved)
  if [[ -n $snap && -d $snap ]]; then
    # Never re-snapshot (R74): a resumed run finds the tree already moved.
    [[ -f ${snap}${MIGRATE_ANGIE_ETC}/angie.conf && -d ${snap}${MIGRATE_ANGIE_ETC}/http.d ]] || {
      migrate_fail "the recorded Angie snapshot ${snap} is incomplete; Angie purge refused"
      return 1
    }
    return 0
  fi
  snap=$(migrate_snapshot_dir angie) || return 1
  # State files are copied (the purge removes them, the leftovers move
  # later); the live /etc/angie itself is MOVED before dpkg can delete its
  # conffiles.
  for f in /etc/default/angie /etc/logrotate.d/angie /var/lib/angie \
           /usr/local/lib/setup-angie /etc/needrestart/conf.d/angie.conf; do
    [[ -e $f ]] || continue
    mkdir -p "${snap}$(dirname "$f")" && cp -a -- "$f" "${snap}$(dirname "$f")/" || true
  done
  migrate_stash "$MIGRATE_ANGIE_ETC" "$snap" || { migrate_fail "moving /etc/angie to ${snap} failed; Angie purge refused"; return 1; }
  [[ -f ${snap}${MIGRATE_ANGIE_ETC}/angie.conf ]] || { migrate_fail "${snap} holds no angie.conf; Angie purge refused"; return 1; }
  # Owned by root: the angie UID may be freed by the purge (R37).
  chown -R root:root "$snap" 2>/dev/null || true
  chmod 700 "$snap"
  migrate_state_set angie-moved "$snap"
  return 0
}

# After a verified Angie purge: leftovers into the backups, the angie user
# only when it owns nothing else, and an alias so external
# `systemctl reload angie` callers reach nginx (R37, R83).
migrate_angie_after_purge() {
  local snap f owned
  snap=$(migrate_state_get angie-moved)
  for f in "$MIGRATE_ANGIE_ETC" /etc/default/angie /etc/logrotate.d/angie /var/log/angie /var/cache/angie \
           /var/lib/angie /usr/local/lib/setup-angie /etc/needrestart/conf.d/angie.conf; do
    [[ -e $f ]] && migrate_stash "$f" "${snap:-$(migrate_run_dir)}/leftover"
  done
  if id angie >/dev/null 2>&1; then
    owned=$(timeout 120 find / -xdev -user angie -not -path "${MIGRATE_BACKUP_ROOT}/*" -print -quit 2>/dev/null || true)
    if [[ -z $owned ]]; then
      userdel angie >/dev/null 2>&1 && migrate_note "angie user removed (it owned no file outside the backups)"
    else
      migrate_note "angie user kept: it still owns ${owned}"
    fi
  fi
  # Files of a freed UID/GID in the backups belong to root (R37).
  find "$MIGRATE_BACKUP_ROOT" \( -nouser -o -nogroup \) -exec chown -h root:root {} + 2>/dev/null || true
  systemctl unmask angie.service >/dev/null 2>&1 || true
  if [[ ! -e $MIGRATE_UNIT_DIR/angie.service && -f $(migrate_unit_file nginx) ]]; then
    ln -s "$(migrate_unit_file nginx)" "$MIGRATE_UNIT_DIR/angie.service" \
      && systemctl daemon-reload >/dev/null 2>&1 \
      && migrate_note "angie.service is now an alias of nginx.service (legacy 'systemctl reload angie' callers reach nginx)"
  fi
  migrate_state_set angie-purge "done"
}

# Repository files and keyrings, moved into the .debs directory (R18).
migrate_retire_sources() {
  local dest=$1 angie=$2 sury=$3 f re=""
  (( angie )) && re+='download\.angie\.software|'
  (( sury )) && re+='packages\.sury\.org|ondrej/php|'
  [[ $(migrate_state_get distro-nginx) == purged:* ]] && re+='ondrej/nginx|nginx\.org/packages|'
  re=${re%|}
  [[ -n $re ]] || return 0
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $f ]] && grep -qsE "$re" "$f" && migrate_stash "$f" "$dest/retired-sources"
  done
  if (( angie )); then
    for f in /usr/share/keyrings/angie-signing.gpg /etc/apt/trusted.gpg.d/angie-signing.gpg /etc/apt/keyrings/angie-signing.gpg; do
      [[ -e $f ]] && migrate_stash "$f" "$dest/retired-sources"
    done
  fi
  return 0
}

# Keep apt from bringing the packages back (R71): only for parts removed.
migrate_write_apt_pin() {
  local angie=$1 sury=$2 valkey=$3 tmp
  local -a pats=()
  [[ $(migrate_state_get nginx) == "done" ]] && pats+=("nginx nginx-* libnginx-mod-*")
  (( angie )) && pats+=("angie angie-*")
  # The Sury/Ubuntu PHP families only (R2.7): phpX.Y and phpX.Y-*, php-*
  # (php-common, php-pear, ...) and the Apache module.  Not a bare 'php*',
  # which would also refuse unrelated packages such as phpmyadmin.
  (( sury )) && pats+=("php[0-9]* php-* libapache2-mod-php*")
  (( valkey )) && pats+=("valkey-server valkey-tools")
  if [[ -f $MIGRATE_APT_PIN ]]; then
    local old
    old=$(sed -nE 's/^Package: //p' "$MIGRATE_APT_PIN" | head -n1)
    # An earlier draft wrote the bare 'php*': narrow it on rewrite.
    old=$(printf '%s\n' "$old" | tr ' ' '\n' | grep -vxF 'php*' | paste -sd' ' - || true)
    [[ -n $old ]] && pats+=("$old")
  fi
  (( ${#pats[@]} )) || return 0
  tmp=$(tmp_file) || return 0
  {
    printf '# Managed by setup.sh 1.22: nginx, PHP and Valkey are built from source\n'
    printf '# (/usr/local/lib/setup-*).  These packages would take back paths and\n'
    printf '# unit names the source builds own.  --purge removes this file.\n'
    printf 'Package: %s\nPin: release *\nPin-Priority: -1\n' "$(printf '%s\n' "${pats[@]}" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -)"
  } > "$tmp"
  commit_if_changed "$MIGRATE_APT_PIN" "$tmp" && chmod 644 "$MIGRATE_APT_PIN"
  rm -f -- "$tmp"
}

# 0 when the active-version link path may be (re)created: no package owns it.
migrate_link_bin() {
  local src=$1 dst=$2 tmp
  [[ -x $src ]] || return 1
  migrate_dpkg_owned "$dst" && return 1
  if [[ -e $dst && ! -L $dst ]]; then
    migrate_stash "$dst" "$(migrate_run_dir)/replaced-links" || return 1
  fi
  tmp="${dst}.setup-new.$$"
  ln -sfn -- "$src" "$tmp" && mv -fT -- "$tmp" "$dst"
}

# Remove every 'php' alternatives entry that points into our PHP root (an
# earlier 1.22 draft registered one at the cutover).  The migration never
# registers one: /usr/bin/php is a plain symlink (R2.1), and an entry of
# ours would keep /etc/alternatives/php, which stops B's php_build_links
# from re-pointing /usr/bin/php after an --upgrade-php switch.  Package
# entries (Sury's CLIs) are left to dpkg.  Always returns 0.
migrate_php_alt_cleanup() {
  local root p
  command -v update-alternatives >/dev/null 2>&1 || return 0
  root="$(migrate_php_root)/"
  while IFS= read -r p; do
    [[ -n $p && $p == "$root"* ]] || continue
    if update-alternatives --remove php "$p" >/dev/null 2>&1; then
      migrate_note "removed the update-alternatives entry php -> ${p} (/usr/bin/php is a plain symlink in 1.22)"
    else
      migrate_warn "could not remove the update-alternatives entry php -> ${p}; run: update-alternatives --remove php ${p}"
    fi
  done < <(update-alternatives --list php 2>/dev/null || true)
  return 0
}

# Failures of one post-removal pass: reported only when the repair attempt
# fails too (migrate_removals_verify).
MIGRATE_PA_ERRORS=()
migrate_pa_fail() { warn "migrate: $*"; MIGRATE_PA_ERRORS+=("$*"); }

# The single post-removal pass (R2, R16, R24, R34, R52, R55, R89): re-lay our
# /etc/php, links, tmpfiles, daemon-reload, enable + assert every unit,
# restart PHP, re-verify everything.  Idempotent (also the repair attempt).
migrate_post_assert() {
  local -a vers=("$@")
  local v conv sess u why bad=0 primary msg rc
  primary=$(migrate_primary_version)
  for v in "${vers[@]}"; do
    [[ -n $v ]] || continue
    # pool.d from the converted snapshot, never from a template (R24).
    conv=$(migrate_state_get "php-${v}.converted")
    if [[ -n $conv && -d $conv/etc/fpm/pool.d ]]; then
      mkdir -p "$MIGRATE_PHP_ETC/$v/fpm/pool.d"
      cp -an -- "$conv/etc/fpm/pool.d/." "$MIGRATE_PHP_ETC/$v/fpm/pool.d/" 2>/dev/null || true
    fi
    php_build_layout "$v" adopt || { warn "migrate: php_build_layout ${v} failed"; bad=1; }
  done
  local t
  for t in /etc/tmpfiles.d/setup-php.conf /etc/tmpfiles.d/setup-php-pools.conf /etc/tmpfiles.d/setup-nginx.conf; do
    [[ -f $t ]] && systemd-tmpfiles --create "$t" >/dev/null 2>&1
  done
  # B's own tmpfiles pass also asserts the session directory (www-data 0700).
  if (( ${#vers[@]} )) && declare -F php_build_tmpfiles_apply >/dev/null 2>&1; then
    php_build_tmpfiles_apply || bad=1
  fi
  # Session files back, owned by the pool user, before any restart (R52).
  sess=$(migrate_state_get php-sessions)
  if [[ -n $sess && -d $sess/sessions ]]; then
    cp -an -- "$sess/sessions/." /var/lib/php/sessions/ 2>/dev/null || true
    chown -R www-data:www-data /var/lib/php/sessions 2>/dev/null || true
  fi
  if (( ${#vers[@]} )) && [[ -d /var/lib/php/sessions ]]; then
    [[ $(stat -c '%U:%G %a' /var/lib/php/sessions 2>/dev/null) == 'www-data:www-data 700' ]] \
      || { warn "migrate: /var/lib/php/sessions is $(stat -c '%U:%G %a' /var/lib/php/sessions 2>/dev/null), not www-data:www-data 700"; bad=1; }
  fi
  # /usr/bin/php and /usr/bin/phpX.Y once no package owns them (R6, R15).
  for v in "${vers[@]}"; do
    [[ -n $v ]] || continue
    if ! migrate_dpkg_owned "/usr/bin/php${v}"; then
      migrate_link_bin "$(migrate_php_cli_bin "$v")" "/usr/bin/php${v}" || true
    fi
  done
  # No alternatives entry of ours may survive (R2.1): it would keep
  # /etc/alternatives/php and block B's links from re-pointing /usr/bin/php.
  migrate_php_alt_cleanup
  if [[ -n $primary ]] && [[ " ${vers[*]} " == *" $primary "* ]] && ! migrate_pkg_installed "php${primary}-cli"; then
    migrate_link_bin "$(migrate_php_cli_bin "$primary")" /usr/bin/php || true
  fi
  if [[ -n $primary && " ${vers[*]} " == *" $primary "* ]]; then
    migrate_php_set_active "$primary" || { warn "migrate: could not write ${MIGRATE_PHP_ETC}/setup-active"; bad=1; }
  fi
  # B's links (/usr/local/bin/phpX.Y, the php-fpmX.Y wrapper, /usr/bin/php*
  # where no package owns them), after the alternative above is gone.
  if declare -F php_build_links >/dev/null 2>&1; then
    for v in "${vers[@]}"; do
      [[ -n $v ]] && { php_build_links "$v" || warn "migrate: php_build_links ${v} reported a problem"; }
    done
  fi
  # Units: one enable pass after every removal, then the assertions.
  systemctl daemon-reload || true
  local -a units=()
  [[ $(migrate_state_get nginx) == "done" ]] && units+=(nginx)
  for v in "${vers[@]}"; do [[ -n $v ]] && units+=("php${v}-fpm"); done
  [[ $(migrate_state_get valkey) == "done" ]] && units+=(valkey-server)
  for u in "${units[@]}"; do
    systemctl unmask "${u}.service" >/dev/null 2>&1 || true
    migrate_clear_dsh_state "$u"
    systemctl enable "${u}.service" >/dev/null 2>&1 || true
  done
  if [[ " ${units[*]} " == *" valkey-server "* ]]; then
    if [[ -L $MIGRATE_UNIT_DIR/valkey.service && ! -e $MIGRATE_UNIT_DIR/valkey.service ]]; then
      migrate_stash "$MIGRATE_UNIT_DIR/valkey.service" "$(migrate_run_dir)/dangling"
      systemctl reenable valkey-server >/dev/null 2>&1 || true
    fi
  fi
  systemctl daemon-reload || true
  for u in "${units[@]}"; do
    if ! why=$(migrate_assert_enabled "$u"); then
      migrate_pa_fail "unit assertion: ${why}"; bad=1
    fi
  done
  if [[ " ${units[*]} " == *" valkey-server "* ]] \
     && [[ -e $MIGRATE_UNIT_DIR/valkey.service ]] \
     && [[ $(readlink -f "$MIGRATE_UNIT_DIR/valkey.service") != "$(migrate_unit_file valkey-server)" ]]; then
    migrate_pa_fail "unit assertion: valkey.service does not resolve to our valkey-server.service"; bad=1
  fi
  # With an operator policy-rc.d kept (R2.7) a package prerm/postrm may have
  # stopped our same-name nginx or valkey-server unit: start what is down
  # before verifying it (PHP is restarted below anyway).
  for u in "${units[@]}"; do
    [[ $u == php*-fpm ]] && continue
    systemctl is-active --quiet "${u}.service" 2>/dev/null && continue
    systemctl reset-failed "${u}.service" >/dev/null 2>&1 || true
    systemctl start "${u}.service" >/dev/null 2>&1 || warn "migrate: ${u} did not start after the removals"
  done
  # Restart PHP (full restart: conffiles were rewritten), then verify.
  for v in "${vers[@]}"; do
    [[ -n $v ]] || continue
    if ! msg=$(php_fpm_test "$v" 2>&1) || grep -qiE 'Unable to load|already loaded' <<<"$msg"; then
      migrate_pa_fail "PHP ${v}: php-fpm -t after the removals: $(printf '%s' "$msg" | grep -m2 -iE 'error|unable|already' | paste -sd' ' -)"; bad=1; continue
    fi
    systemctl restart "php${v}-fpm" || { migrate_pa_fail "php${v}-fpm did not restart after the removals"; bad=1; continue; }
    "$(migrate_php_cli_bin "$v")" -r 'exit(function_exists("opcache_get_status") ? 0 : 1);' >/dev/null 2>&1 \
      || { migrate_pa_fail "PHP ${v}: OPcache missing in the CLI after the removals"; bad=1; }
    [[ -n $(find "$MIGRATE_PHP_ETC/$v/fpm/conf.d" "$MIGRATE_PHP_ETC/$v/cli/conf.d" -maxdepth 1 -type l 2>/dev/null) ]] \
      && { migrate_pa_fail "PHP ${v}: symlinks left in conf.d after the re-lay"; bad=1; }
  done
  sleep 1
  if [[ " ${units[*]} " == *" nginx "* ]]; then
    local cand
    cand=$(migrate_nginx_bin) || cand=""
    if [[ -n $cand ]] && ! "$cand" -t -q -c "$MIGRATE_NGINX_ETC/nginx.conf" >/dev/null 2>&1; then
      migrate_pa_fail "nginx -t fails after the removals"; bad=1
    fi
    systemctl is-active --quiet nginx || { migrate_pa_fail "nginx is not active after the removals"; bad=1; }
    nginx_secure_auth_files "$MIGRATE_NGINX_ETC" || true
  fi
  if (( ${#vers[@]} )); then
    local pv=$primary
    [[ " ${vers[*]} " == *" $pv "* ]] || pv=${vers[0]}
    rc=0; msg=$(migrate_php_probe "$pv") || rc=$?
    (( rc == 1 )) && { migrate_pa_fail "PHP probe after the removals: ${msg}"; bad=1; }
  fi
  if [[ " ${units[*]} " == *" valkey-server "* ]]; then
    [[ $(migrate_valkey_cmd "$(migrate_valkey_cli)" PING || true) == PONG ]] \
      || { migrate_pa_fail "Valkey PING failed after the removals"; bad=1; }
    id -nG www-data 2>/dev/null | grep -qw valkey || usermod -aG valkey www-data 2>/dev/null || true
  fi
  # The vhost answers recorded right before this removal phase must still
  # hold.  The cutover baseline is used only within the run that recorded
  # it: a later run's vhosts may differ for reasons of the operator's own.
  local b out
  b=$(migrate_state_get removals.baseline)
  if [[ -z $b || ! -s $b ]]; then
    b=$(migrate_state_get nginx.baseline)
    [[ -n $MIGRATE_RUN_DIR && $b == "$MIGRATE_RUN_DIR"/* ]] || b=""
  fi
  if [[ -n $b && -s $b ]]; then
    out=$(migrate_compare_baseline "$b") || { migrate_pa_fail "vhosts changed after the removals: $(printf '%s' "$out" | head -n 3 | paste -sd'; ' -)"; bad=1; }
  fi
  migrate_assert_no_old_triggers || bad=1
  if (( ! bad )) && [[ $(migrate_state_get nginx) == "done" ]] && declare -F write_cron >/dev/null 2>&1; then
    migrate_cron_handover
  fi
  return "$bad"
}

# ---------------------------------------------------------------------------
# Step 12: report
# ---------------------------------------------------------------------------
# WordPress sites whose saved permalink structure starts with /index.php:
# under Angie SERVER_SOFTWARE did not say nginx, so an admin save may have
# added the prefix (R38).  Best effort through the mariadb client.
migrate_wp_permalink_check() {
  local cfg root db user pass host prefix val defaults
  command -v mariadb >/dev/null 2>&1 || return 0
  declare -F app_find_wordpress_configs >/dev/null 2>&1 || return 0
  while IFS= read -r cfg; do
    [[ -f $cfg ]] || continue
    root=$(dirname "$cfg")
    db=$(sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$cfg" | head -n1)
    user=$(sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]DB_USER['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$cfg" | head -n1)
    pass=$(sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]DB_PASSWORD['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$cfg" | head -n1)
    host=$(sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]DB_HOST['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$cfg" | head -n1)
    prefix=$(sed -nE "s/^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*['\"]([A-Za-z0-9_]*)['\"].*/\1/p" "$cfg" | head -n1)
    [[ -n $db && -n $user && $prefix =~ ^[A-Za-z0-9_]+$ ]] || continue
    defaults=$(tmp_file) || continue
    chmod 600 "$defaults"
    printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$user" "$pass" "${host:-localhost}" > "$defaults"
    val=$(timeout 10 mariadb --defaults-extra-file="$defaults" -N -B "$db" \
            -e "SELECT option_value FROM \`${prefix}options\` WHERE option_name='permalink_structure'" 2>/dev/null || true)
    rm -f -- "$defaults"
    if [[ $val == /index.php* ]]; then
      migrate_warn "WordPress at ${root}: permalinks start with /index.php (saved while Angie did not identify as nginx); re-save Settings > Permalinks"
    fi
  done < <(app_find_wordpress_configs)
}

migrate_final_report() {
  local callers refs
  callers=$(migrate_php_cron_callers)
  if [[ -n $callers ]]; then
    migrate_report "- Crontab lines that run PHP (now the source build through /usr/bin/php):"
    while IFS= read -r l; do migrate_report "    - \`${l}\`"; done <<<"$(printf '%s\n' "$callers" | head -n 20)"
  fi
  refs=$(migrate_leftover_refs)
  if [[ -n $refs ]]; then
    migrate_warn "files still reference Angie paths or angie.service (review them): $(printf '%s' "$refs" | paste -sd' ' -)"
  fi
  migrate_wp_permalink_check
  local s
  for s in nginx angie-purge sury-purge valkey valkey-remove; do
    [[ -n $(migrate_state_get "$s") ]] && migrate_report "    - state ${s}: $(migrate_state_get "$s")"
  done
  while IFS= read -r s; do
    [[ -n $s ]] && migrate_report "    - state php-${s}: $(migrate_state_get "php-${s}")"
  done < <(sed -nE 's/^php-([0-9]+\.[0-9]+)=.*/\1/p' "$MIGRATE_STATE_FILE" 2>/dev/null | sort -u)
  local vk
  vk=$(migrate_state_get valkey-remove)
  [[ $vk == "done" ]] && migrate_report "    - valkey-server/valkey-tools stay in dpkg's config-files (rc) state on purpose: their purge would delete /var/lib/valkey"
}

# Nothing in flight and no removal phase open: the refresh timer and the CPU
# chain may run again (R65).  Cleared at the start of every migration run.
# A part that is blocked, refused, failed or postponed does not hold them:
# nothing of it is half-switched.
migrate_mark_complete() {
  [[ -z $(migrate_state_get inflight) ]] || return 0
  case $(migrate_state_get removals) in started|pending|post-purge-failed) return 0 ;; esac
  migrate_complete_set 1
}

# BOLT after the migration, outside it (R14): non-blocking, rc-tolerant.
migrate_start_bolt() {
  local cmd="" v r
  r=$(migrate_nginx_root)
  [[ $(migrate_state_get nginx) == "done" && -x $r/nginx-build.sh ]] && cmd+="'$r/nginx-build.sh' bolt || true; "
  r=$(migrate_php_root)
  for v in "$@"; do
    [[ -x $r/php-build.sh ]] && cmd+="'$r/php-build.sh' bolt $v || true; "
  done
  r=$(migrate_valkey_root)
  [[ $(migrate_state_get valkey) == "done" && -x $r/valkey-build.sh ]] && cmd+="'$r/valkey-build.sh' bolt || true; "
  [[ -n $cmd ]] || return 0
  command -v systemd-run >/dev/null 2>&1 || return 0
  systemd-run --no-block --collect --quiet --unit=setup-migrate-bolt-1.22 -p Nice=10 -p IOSchedulingClass=idle \
    /bin/bash -c "sleep 300; ${cmd}" >/dev/null 2>&1 \
    && migrate_note "BOLT passes queued in setup-migrate-bolt-1.22 (in 5 min, after traffic warmed the binaries)"
  return 0
}


# ---------------------------------------------------------------------------
# The migration body (inside the unit, or inline when it cannot detach)
# ---------------------------------------------------------------------------
migrate_main() {
  local out=${1:-} rc=0 prev_sig_traps
  MIGRATE_REPORT=(); MIGRATE_FAILED=0; MIGRATE_RUN_DIR=""
  # The caller's own handlers come back at the end (an inherited HUP ignore,
  # which runner.sh and php-upgrade rely on, must survive the inline path).
  prev_sig_traps=$(trap -p HUP PIPE INT TERM)
  # Ignored for the whole run: a dropped session or a closed pipe must not
  # stop a cutover half-way (R20, R50).  Children inherit the ignore.
  trap '' HUP PIPE
  MIGRATE_PREV_EXIT_TRAP=$(trap -p EXIT)
  trap migrate_exit_hook EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # The body runs as an || operand: every step checks its own result and
  # records its part's state; an unexpected failure must not skip the
  # report, the policy-rc.d removal or the lock release below.
  migrate_main_body || rc=$?
  migrate_lock_release
  (( MIGRATE_POLICY_OURS )) && migrate_policy_remove
  migrate_write_out "$out"
  # Back to the caller's handlers: reset ours, then re-install what `trap -p`
  # printed (a signal it did not list had the default disposition).
  trap - HUP PIPE INT TERM
  [[ -n $prev_sig_traps ]] && eval "$prev_sig_traps"
  if [[ -n $MIGRATE_PREV_EXIT_TRAP ]]; then eval "$MIGRATE_PREV_EXIT_TRAP"; else trap - EXIT; fi
  return "$rc"
}

migrate_main_body() {
  local v
  local -a php_done_now=()
  migrate_backup_root_ensure || { warn "migrate: cannot create ${MIGRATE_BACKUP_ROOT}"; return 1; }
  migrate_run_dir_init || return 1
  step "Migration to the source-built stack (1.22)"
  migrate_report "## Migration 1.22 (Angie/Sury/valkey-server -> source builds)"
  migrate_report "- Log: \`${MIGRATE_LOG}\`; backups: \`${MIGRATE_BACKUP_ROOT}\`; state: \`${MIGRATE_STATE_FILE}\`"
  migrate_resume_safe
  migrate_complete_set 0
  migrate_scrub_knobs || true
  migrate_retire_triggers || return 1
  migrate_nginx_finish_cutover
  migrate_preflight 0 || true

  if (( MIGRATE_DO_NGINX || ${#MIGRATE_PHP_TODO[@]} || MIGRATE_DO_VALKEY )); then
    if ! migrate_lock_acquire; then
      migrate_fail "the build lock ${MIGRATE_BUILD_LOCK} stayed busy; everything postponed to the next run"
      return 1
    fi
    migrate_build_all
    if (( MIGRATE_DO_NGINX )); then
      migrate_nginx_prepare && migrate_nginx_cutover
    fi
    for v in "${MIGRATE_PHP_TODO[@]}"; do
      migrate_php_cutover "$v" && php_done_now+=("$v")
    done
    if (( MIGRATE_DO_VALKEY )); then
      migrate_valkey_cutover
    fi
  else
    # Removals and their verification still serialise with the builds.
    migrate_lock_acquire || true
  fi
  migrate_removals
  migrate_final_report
  migrate_lock_release
  migrate_mark_complete
  migrate_start_bolt "${php_done_now[@]}"
  (( MIGRATE_FAILED )) && return 1
  [[ $(web_server_state) == angie-legacy ]] && return 2
  return 0
}

migrate_write_out() {
  local out=${1:-}
  [[ -n $out ]] || return 0
  printf '%s\n' "${MIGRATE_REPORT[@]}" >> "$out" 2>/dev/null || true
}

# Entry for the transient unit: setup.sh --migrate-1.22-unit OUT.  F's entry
# initialises like --optimize does up to plan_memory_budget, then calls this.
migrate_unit_main() {
  local out=${1:-} rc=0
  export SETUP_MIGRATE_IN_UNIT=1
  # The unit takes the run lock the caller released, so no other setup.sh
  # run can start while it works.
  if command -v flock >/dev/null 2>&1 && [[ -n ${LOCK_FILE:-} && ! -L ${LOCK_FILE:-} ]]; then
    { exec 9>>"$LOCK_FILE" && flock -w 120 9; } || warn "migrate: could not take ${LOCK_FILE}; continuing"
  fi
  migrate_main "$out" || rc=$?
  # Atomic, so an attaching run never reads a half-written result.
  { printf '%s\n' "$rc" > "${MIGRATE_STATE_FILE}.rc.new" && mv -f -- "${MIGRATE_STATE_FILE}.rc.new" "${MIGRATE_STATE_FILE}.rc"; } \
    || { printf '%s\n' "$rc" > "${MIGRATE_STATE_FILE}.rc"; } 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------------------
# Controller (step 0, R20, R50, R73)
# ---------------------------------------------------------------------------
# Environment the unit needs from this run.
MIGRATE_PASS_ENV=(CONFIG_SOURCE_DIR CONFIG_REPO_REF CONFIG_REPO_URL SETUP_PHP_ALLOW_COLLATERAL
                  SETUP_PHP_ALLOW_MISSING_EXT SETUP_STATE_DIR SETUP_CF_SELF_SIGNED SETUP_TUNING_FILE
                  SETUP_MIGRATE_LOCK_WAIT SETUP_MIGRATE_RETRY)

migrate_can_detach() {
  [[ ${SETUP_MIGRATE_DETACH:-1} == 1 ]] || return 1
  [[ ${SETUP_MIGRATE_IN_UNIT:-0} == 1 ]] && return 1
  command -v systemd-run >/dev/null 2>&1 || return 1
  [[ -d /run/systemd/system ]] || return 1
  [[ -f ${SCRIPT_DIR:-/nonexistent}/setup.sh ]]
}

# Follow MIGRATE_LOG from byte offset OFF until the unit's main process
# exits (or at once when the unit is not running any more).
migrate_follow() {
  local off=${1:-0} pid=0 i
  for i in $(seq 1 20); do
    pid=$(systemctl show -p MainPID --value "$MIGRATE_UNIT" 2>/dev/null || echo 0)
    [[ $pid =~ ^[0-9]+$ ]] && (( pid > 0 )) && break
    systemctl is-active --quiet "$MIGRATE_UNIT" 2>/dev/null || break
    sleep 0.5
  done
  if [[ $pid =~ ^[0-9]+$ ]] && (( pid > 0 )); then
    tail -c "+$(( off + 1 ))" -F --pid="$pid" -- "$MIGRATE_LOG" 2>/dev/null || true
  else
    tail -c "+$(( off + 1 ))" -- "$MIGRATE_LOG" 2>/dev/null || true
  fi
  return 0
}

# The result the last migration unit recorded in ${MIGRATE_STATE_FILE}.rc:
# its status, 1 when a started unit left none (killed before it could write
# it), 0 when no unit ever ran.
migrate_recorded_rc() {
  local rcfile="${MIGRATE_STATE_FILE}.rc" rc
  [[ -e $rcfile ]] || return 0
  rc=$(tr -dc '0-9' < "$rcfile" 2>/dev/null || true)
  [[ -n $rc ]] || { warn "The migration unit left no result in ${rcfile}; see ${MIGRATE_LOG}"; return 1; }
  return "$rc"
}

# Attach only: never starts anything and never touches the run lock (the
# caller takes it afterwards).  While setup-migrate-1.22 runs, follow its
# log until its main process exits; then return the result it recorded.
# When the unit already ended (for example between the caller's
# migrate_running check and this call), return that recorded result at
# once instead of starting a unit.  restart.sh main() calls this before it
# takes the run lock on a rerun of --optimize.
migrate_attach() {
  local off
  if migrate_running; then
    off=$(stat -c %s -- "$MIGRATE_LOG" 2>/dev/null || echo 0)
    info "The 1.22 migration is already running (${MIGRATE_UNIT}); following ${MIGRATE_LOG}"
    migrate_follow "$off"
  fi
  migrate_recorded_rc
}

# Run CMD... as the transient unit setup-migrate-1.22 (no --pipe: its output
# goes to the log, never to this session's terminal), follow the log until
# the unit ends, and return the result the unit recorded.  While the unit
# runs, or with no CMD, this only attaches (migrate_attach) and never
# starts a unit.  Ends holding the run lock.  F may use this for a whole
# detached --optimize.
migrate_detach_cmd() {
  local rcfile="${MIGRATE_STATE_FILE}.rc" off rc=0 name
  local -a envs=()
  mkdir -p "$(dirname "$MIGRATE_LOG")"
  [[ -e $MIGRATE_LOG ]] || install -m 600 /dev/null "$MIGRATE_LOG"
  if (( $# == 0 )) || migrate_running; then
    migrate_attach || rc=$?
    declare -F acquire_run_lock >/dev/null 2>&1 && acquire_run_lock
    return "$rc"
  fi
  off=$(stat -c %s -- "$MIGRATE_LOG" 2>/dev/null || echo 0)
  mkdir -p "$(dirname "$rcfile")"
  printf '' > "$rcfile"
  for name in "${MIGRATE_PASS_ENV[@]}"; do
    [[ -n ${!name:-} ]] && envs+=("--setenv=${name}=${!name}")
  done
  declare -F release_run_lock >/dev/null 2>&1 && release_run_lock
  if ! systemd-run --unit="$MIGRATE_UNIT" --collect --quiet \
        -p OOMScoreAdjust=-500 -p "StandardOutput=append:${MIGRATE_LOG}" -p "StandardError=append:${MIGRATE_LOG}" \
        --setenv=SETUP_MIGRATE_IN_UNIT=1 "${envs[@]}" "$@"; then
    declare -F acquire_run_lock >/dev/null 2>&1 && acquire_run_lock
    return 125
  fi
  info "Running as ${MIGRATE_UNIT}; output follows from ${MIGRATE_LOG}.  A dropped SSH session does not stop it; re-run the same command to follow it again."
  migrate_follow "$off"
  declare -F acquire_run_lock >/dev/null 2>&1 && acquire_run_lock
  migrate_recorded_rc || rc=$?
  return "$rc"
}

migrate_detach() {
  local out=$1 rc=0
  migrate_detach_cmd /bin/bash "${SCRIPT_DIR}/setup.sh" --migrate-1.22-unit "$out" || rc=$?
  if (( rc == 125 )); then
    warn "Could not start ${MIGRATE_UNIT}; running the migration in this session (keep it open)"
    rc=0
    migrate_main "$out" || rc=$?
  fi
  return "$rc"
}

# The report file the migration body (inline or in the unit) appends to.
# Fixed, root-only, next to the state file: a run that only attaches to a
# running unit reads the same file the unit writes.
MIGRATE_REPORT_FILE=${MIGRATE_STATE_FILE}.report

# Hand the lines of FILE to the caller's OUT: a reporter function (the
# interface contract, e.g. opt_report), or, for older callers, a file path
# the lines are appended to.
migrate_emit() {
  local out=$1 file=$2 line
  [[ -n $out && -s $file ]] || return 0
  if declare -F "$out" >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n $line ]] && "$out" "$line"
    done < "$file"
  else
    cat -- "$file" >> "$out" 2>/dev/null || true
  fi
}

# migrate_run OUT: the --optimize entry.  OUT is a reporter function (called
# as "$out" "- line", like opt_report) that receives the markdown report
# lines; a file path is still accepted and appended to.  Returns 0 (done or
# nothing to do), 1 (a part failed or rolled back: the run must report a
# failure) or 2 (no failure, but the nginx part is not done: the host is in
# legacy-Angie mode and the caller skips every web-tier step).  --dry-run
# prints the plan and changes nothing.
migrate_run() {
  local out=${1:-} why rc=0 rep=$MIGRATE_REPORT_FILE
  if (( ${DRY_RUN:-0} )); then
    migrate_plan
    [[ $(web_server_state) == angie-legacy ]] && return 2
    return 0
  fi
  if migrate_running; then
    # Attach: the unit writes the report file its starter named (the same).
    migrate_detach "$rep" || rc=$?
    migrate_emit "$out" "$rep"
    return "$rc"
  fi
  migrate_resume_safe
  if ! migrate_needed; then
    if [[ $(web_server_state) == angie-legacy ]]; then
      why=$(migrate_state_get nginx)
      if declare -F "$out" >/dev/null 2>&1; then
        "$out" "- Web server: Angie (legacy mode; nginx part ${why:-pending}); web tuning skipped"
      elif [[ -n $out ]]; then
        printf '%s\n' "- Web server: Angie (legacy mode; nginx part ${why:-pending}); web tuning skipped" >> "$out"
      fi
      return 2
    fi
    return 0
  fi
  mkdir -p "$(dirname "$rep")"
  install -m 600 /dev/null "$rep" 2>/dev/null || : > "$rep"
  if migrate_can_detach; then
    migrate_detach "$rep" || rc=$?
  else
    migrate_main "$rep" || rc=$?
  fi
  migrate_emit "$out" "$rep"
  return "$rc"
}

# Dry-run lines (--optimize --dry-run).  Read-only.
migrate_plan() {
  migrate_needed || { printf 'Migration 1.22: nothing to migrate (%s)\n' "$(web_server_state)"; return 0; }
  printf 'Migration 1.22 (runs detached as %s, log %s):\n' "$MIGRATE_UNIT" "$MIGRATE_LOG"
  migrate_old_triggers_present && printf '  retire the 1.21 build timers, APT hooks and rebuild units\n'
  [[ -n $(migrate_state_get inflight) ]] && printf '  an earlier run stopped during %s: rolled back first\n' "$(migrate_state_get inflight)"
  migrate_preflight 1 || true
  printf '  cutover windows: nginx ~1-3 s between the Angie stop and the nginx start; PHP ~1 s per version; Valkey one restart (dataset reload)\n'
  printf '  removals run only after every cutover verified; .debs and configuration are kept in %s\n' "$MIGRATE_BACKUP_ROOT"
  return 0
}
