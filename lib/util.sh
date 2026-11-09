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
  # --optimize points an adopted Redis at ${LOG_ROOT}/redis like Valkey.
  getent passwd redis         >/dev/null 2>&1 && ensure_log_dir redis         redis        redis
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
  getent passwd redis         >/dev/null 2>&1 && log_file redis/redis.log   redis  redis
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
    # Copy over the existing path instead of unlinking it first.  Files the
    # setup generated inside a restored directory are moved to /tmp.
    if [[ -d $src ]]; then
      local line
      while IFS= read -r line; do
        [[ $line == moved\ * ]] && info "Moved generated ${line#moved } (nothing deleted)"
      done < <(restore_snapshot_dir "$src" "$path" || warn "Could not fully restore ${path}")
    else
      cp -a "$src" "$path" || { warn "Could not restore ${path}"; return 0; }
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

# Create or re-key USER for every loopback spelling and grant GRANT_CLAUSE
# (for example 'ALL ON *.*' or 'ALL PRIVILEGES ON `db`.*') with the optional
# trailing SUFFIX ('WITH GRANT OPTION').  skip_name_resolve=1 means
# 127.0.0.1 is not translated to localhost, so an account created only for
# 'user'@'localhost' cannot be used over TCP.  The statements go in over
# stdin: a password inside `mariadb -e "..."` is visible to every local user
# in the process list for as long as it runs.
mariadb_ensure_local_user() {
  local user=$1 pass=$2 grant_clause=$3 suffix=${4:-} eu ep host
  eu=$(sql_escape "$user")
  ep=$(sql_escape "$pass")
  for host in localhost 127.0.0.1 ::1; do
    mariadb <<<"CREATE USER IF NOT EXISTS '${eu}'@'${host}' IDENTIFIED BY '${ep}'; ALTER USER '${eu}'@'${host}' IDENTIFIED BY '${ep}'; GRANT ${grant_clause} TO '${eu}'@'${host}' ${suffix};"
  done
  mariadb <<<'FLUSH PRIVILEGES;'
}

sql_escape() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\'/\'\'}
  printf '%s' "$v"
}

# Fill the mysqlbkup sample with the admin credentials.  The values travel in
# the environment (awk ENVIRON), never on a command line, so they are not
# visible in `ps`; they are written verbatim, so no character in the password
# is interpreted as a regex or a replacement token.  Both the [mysql] and the
# [mysqldump] section carry the placeholders.
write_mysqlbkup_credentials() {
  local file=$1 tmp
  [[ -f $file ]] || return 1
  # The upstream tarball ships this file 0644; it is about to hold the
  # administrative password.
  chmod 600 "$file" 2>/dev/null || true
  tmp=$(tmp_file) || return 1
  MYSQLBKUP_USER=$2 MYSQLBKUP_PASS=$3 awk '
    BEGIN { u = ENVIRON["MYSQLBKUP_USER"]; p = ENVIRON["MYSQLBKUP_PASS"] }
    /^user=dba$/ { print "user=" u; next }
    /^password=dba_passwd$/ { print "password=" p; next }
    { print }
  ' "$file" > "$tmp" || return 1
  cat -- "$tmp" > "$file"
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
  # Derive the value from the same CPU formula configure_sysctl writes, so
  # MariaDB back_log, Valkey tcp-backlog and PHP listen.backlog do not depend
  # on whether the sysctl step already ran in this process (installing a
  # service without --basic used to bake the kernel default 4096 into the
  # service file, and the next --optimize rewrote it).
  local somaxconn live
  somaxconn=$(sysctl_target_somaxconn)
  live=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || printf '')
  # A kernel that cannot be tuned (unprivileged container) caps what a
  # listener may ask for; never exceed it.  Only root can tell: for an
  # unprivileged --dry-run the file is read-only anyway, and clamping there
  # would print a backlog the real run never writes.
  if [[ $live =~ ^[0-9]+$ ]] && (( live < somaxconn )) && (( EUID == 0 )) \
     && [[ ! -w /proc/sys/net/core/somaxconn ]]; then
    somaxconn=$live
  fi
  (( somaxconn > 65535 )) && somaxconn=65535
  (( somaxconn < 1024 )) && somaxconn=1024
  printf '%s' "$somaxconn"
}

# net.core.somaxconn for this host.  One formula shared by configure_sysctl
# and effective_backlog.  A VPS keeps a lower ceiling: provider conntrack and
# hypervisor limits make larger values unreachable and they only pin kernel
# memory.
sysctl_target_somaxconn() {
  local cpu val
  cpu=$(effective_cpus)
  (( cpu > 0 )) || cpu=1
  if host_is_vps; then
    val=$(( cpu * 2048 )); (( val < 4096 )) && val=4096; (( val > 65536 )) && val=65536
  else
    val=$(( cpu * 4096 )); (( val < 4096 )) && val=4096; (( val > 262144 )) && val=262144
  fi
  printf '%s' "$val"
}

# True on a virtual machine or container.  --basic server=dedi|vps wins so an
# operator can pin a host; otherwise systemd-detect-virt/DMI decide.  The
# result is cached because the tuners call it many times per run.
HOST_SERVER_TYPE=""
host_server_type() {
  if [[ -z $HOST_SERVER_TYPE ]]; then
    case ${OPT[basic.server]:-} in
      dedi|vps) HOST_SERVER_TYPE=${OPT[basic.server]} ;;
      *)
        # A pinned class from the install (record_explicit_options) wins over
        # detection so install and --optimize use the same formulas.
        HOST_SERVER_TYPE=$(explicit_option server_type 2>/dev/null || true)
        [[ $HOST_SERVER_TYPE == dedi || $HOST_SERVER_TYPE == vps ]] \
          || HOST_SERVER_TYPE=$(detect_server_type)
        ;;
    esac
    [[ $HOST_SERVER_TYPE == vps ]] || HOST_SERVER_TYPE=dedi
  fi
  printf '%s' "$HOST_SERVER_TYPE"
}
host_is_vps() { [[ $(host_server_type) == vps ]]; }

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
    if ! tar -xzf "$archive" -C "$CONFIG_TEMP_DIR"; then
      warn "Could not extract server configs from ${url}"
      CONFIG_TEMP_DIR=""
      return 1
    fi
  elif command -v git >/dev/null 2>&1 \
       && retry 3 5 git clone --depth 1 --branch "$CONFIG_REPO_REF" \
            "${CONFIG_REPO_URL}.git" "${CONFIG_TEMP_DIR}/repo" 2>/dev/null; then
    src="${CONFIG_TEMP_DIR}/repo"
  else
    # Keep the failed download under /tmp for inspection; it expires on its own.
    warn "Could not download server configs from ${CONFIG_REPO_URL} (${CONFIG_REPO_REF})"
    CONFIG_TEMP_DIR=""
    return 1
  fi

  if [[ -z $src ]]; then
    src=$(find "$CONFIG_TEMP_DIR" -mindepth 1 -maxdepth 1 -type d \
      -name 'server-configs-nginx-*' 2>/dev/null | head -n1 || true)
  fi
  if [[ -z $src || ! -f "${src}/angie.conf" ]]; then
    warn "Downloaded server configs are missing angie.conf"
    CONFIG_TEMP_DIR=""
    return 1
  fi
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

# Explicit operator choices (--php children=, --mariadb size=, --valkey ram=,
# --elastic ram=) are recorded at install time so a later --optimize does not
# silently replace them with the hardware plan.
explicit_option() {
  local key=$1 file
  file="${STATE_DIR}/explicit-options.conf"
  [[ -r $file ]] || return 1
  local value
  value=$(sed -n "s/^${key}=//p" "$file" | tail -n1)
  [[ -n $value ]] || return 1
  printf '%s' "$value"
}

explicit_option_set() {
  local key=$1 value=$2 file
  file="${STATE_DIR}/explicit-options.conf"
  ensure_state
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed_in_place -E "s|^${key}=.*|$(sed_replacement_escape "${key}=${value}")|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Escape a literal value for the replacement side of an `s|...|...|` sed
# expression: `&`, `\` and the `|` delimiter would otherwise be interpreted.
sed_replacement_escape() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

explicit_option_unset() {
  local key=$1 file="${STATE_DIR}/explicit-options.conf"
  [[ -f $file ]] || return 0
  sed_in_place -E "/^${key}=/d" "$file"
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
  local angie_cron=0 mariadb_cron=0 wp_cron=0
  local -a lines=() existing=() preserved=()

  # Regenerate entries for installed services even when this run only selected
  # --basic.  This is what restores the managed block after --purge basic (or
  # after an operator removed it) instead of leaving the host with no backups
  # and no log-ownership repair.  Decide from the installed configuration, not
  # from the command-line selection: install_basic calls write_cron before the
  # service installers run, so a selected-but-failed service must not leave a
  # cron job pointing at a missing binary or log directory.
  if cron_angie_configured; then
    angie_cron=1
    lines+=("0 0 * * * ${CRON_WWW_CHOWN} >/dev/null 2>&1")
    if [[ -x /etc/angie/scripts/cloudflare.sh ]]; then
      lines+=('1 1 * * * /usr/bin/chmod +x /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1')
      lines+=('2 1 * * * /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1')
    fi
  fi
  if cron_mariadb_configured; then
    mariadb_cron=1
    lines+=("3 3 * * * /usr/local/bin/mysqlbkup.sh 1>> ${LOG_ROOT}/mariadb/backup.log 2>> ${LOG_ROOT}/mariadb/backup-err.log")
    lines+=('4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair > /dev/null 2>&1')
  fi
  # WordPress cron: only when the hardening step disabled WP-Cron in at least
  # one wp-config.php.  Running wp-cron.php from the system scheduler is what
  # makes DISABLE_WP_CRON safe.
  local wp_conf
  while IFS= read -r wp_conf; do
    [[ -n $wp_conf ]] || continue
    if grep -q 'DISABLE_WP_CRON' "$wp_conf" 2>/dev/null; then
      wp_cron=1
      break
    fi
  done < <(app_find_wordpress_configs)
  if (( wp_cron )); then
    lines+=("*/5 * * * * ${CRON_WP_CRON} >/dev/null 2>&1")
  fi
  # Precompressed-asset refresh: only while the feature is on and the helper
  # exists (configure_asset_precompression writes it); dropped otherwise.
  if (( PRECOMPRESS_ASSETS )) && [[ -x $CRON_PRECOMPRESS ]]; then
    lines+=("*/5 * * * * /usr/bin/nice -n 19 ${CRON_PRECOMPRESS} >/dev/null 2>&1")
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
    elif [[ $line == *wp-cron.php* ]]; then
      group=wordpress
    elif [[ $line == *"${CRON_PRECOMPRESS}"* ]]; then
      group=precompress
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
      wordpress|precompress)
        # Regenerated above when needed; drop a stale entry otherwise.
        continue
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

  # Debian's crontab -l omits the vixie header, so the body compares directly.
  # Reinstalling an unchanged crontab only rewrites the header timestamp,
  # which made every --optimize report a changed file.
  CRON_UPDATED=0
  if [[ $(< "$tmp") == "$cur" ]]; then
    info "Managed crontab entries unchanged"
    return 0
  fi
  # Install the file even when it is empty instead of deleting the user's
  # crontab; writing an empty crontab keeps the file in place.
  if ! crontab "$tmp"; then
    warn "Could not install the managed crontab"
    return 1
  fi
  CRON_UPDATED=1
  info "Managed crontab entries updated"
}
# 1 when the last write_cron installed a new crontab, 0 when it was unchanged.
CRON_UPDATED=0

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

