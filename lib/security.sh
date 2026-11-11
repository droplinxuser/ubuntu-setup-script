# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# Security hardening (new installs and --optimize)
# ---------------------------------------------------------------------------
# These helpers are intentionally conservative:
#   * they only edit wp-config.php, the database grants and known-bad paths;
#   * a failed database-credential change is rolled back immediately;
#   * malware is quarantined (not deleted) unless SETUP_PURGE_MALWARE=1;
#   * SSH/firewall changes that can affect reachability need a flag.
# The safe subset runs from both install_basic and run_optimize, so a fresh
# host and an existing host converge on the same state.
WP_HELPER=""

harden_note() {
  if (( ${OPTIMIZE:-0} )); then opt_report "$*"; else info "$*"; fi
}

harden_warn() {
  if (( ${OPTIMIZE:-0} )); then opt_report "- **WARNING** $*"; else warn "$*"; fi
}

write_wp_config_helper() {
  WP_HELPER=$(tmp_file)
  cat > "$WP_HELPER" <<'PHP'
<?php
$mode = $argv[1] ?? '';
$conf = $argv[2] ?? '';
function wp_cfg_read($path) { return is_file($path) ? file_get_contents($path) : false; }
function wp_cfg_get($c, $k) {
  if ($c === false) return '';
  if (preg_match("/define\s*\(\s*(['\"])".preg_quote($k, '/')."\\1\s*,\s*(['\"])(.*?)\\2\s*\)/s", $c, $m)) return $m[3];
  return '';
}
function wp_cfg_write($path, $c) {
  $tmp = $path.'.new';
  if (file_put_contents($tmp, $c) === false) return false;
  chmod($tmp, fileperms($path) & 0777);
  @chown($tmp, fileowner($path));
  @chgrp($tmp, filegroup($path));
  return rename($tmp, $path);
}
switch ($mode) {
  case 'get':
    echo wp_cfg_get(wp_cfg_read($conf), $argv[3] ?? '');
    break;
  case 'prefix':
    $c = wp_cfg_read($conf);
    if ($c !== false && preg_match('/\$table_prefix\s*=\s*[\'"](.*?)[\'"]/', $c, $m)) echo $m[1];
    break;
  case 'set':
    $k = $argv[3] ?? ''; $v = $argv[4] ?? ''; $literal = ($argv[5] ?? '') === 'literal';
    // Secrets arrive through the environment so they never show up in `ps`.
    if (getenv('WP_CFG_VALUE') !== false) $v = getenv('WP_CFG_VALUE');
    $c = wp_cfg_read($conf); if ($c === false) exit(1);
    $val = $literal ? $v : "'".str_replace("'", "\\'", $v)."'";
    $line = "define( '".$k."', ".$val." );";
    $pat = "/define\s*\(\s*(['\"])".preg_quote($k, '/')."\\1\s*,\s*[^;]*?\s*\)\s*;/s";
    if (preg_match($pat, $c)) {
      if (preg_match($pat, $c, $m) && trim($m[0]) === $line) { echo "unchanged"; break; }
      $c = preg_replace($pat, $line, $c, 1);
    } else {
      $marker = "/\/\*\s*That's all, stop editing!/";
      if (preg_match($marker, $c)) {
        $c = preg_replace($marker, $line."\n\n$0", $c, 1);
      } else {
        $c = preg_replace("/(require_once\s+ABSPATH\s*\.\s*'wp-settings\.php'\s*;)/", $line."\n$1", $c, 1);
      }
    }
    if (!wp_cfg_write($conf, $c)) exit(1);
    echo "set";
    break;
  case 'salts':
    $keys = ['AUTH_KEY','SECURE_AUTH_KEY','LOGGED_IN_KEY','NONCE_KEY','AUTH_SALT','SECURE_AUTH_SALT','LOGGED_IN_SALT','NONCE_SALT'];
    $c = wp_cfg_read($conf); if ($c === false) exit(1);
    $need = false;
    foreach ($keys as $k) {
      $v = wp_cfg_get($c, $k);
      if ($v === '' || stripos($v, 'put your unique phrase here') !== false) { $need = true; break; }
    }
    if (!$need) { echo "ok"; break; }
    foreach ($keys as $k) {
      $pat = "/define\s*\(\s*(['\"])".preg_quote($k, '/')."\\1\s*,\s*[^;]*?\s*\)\s*;/s";
      $line = "define( '".$k."', '".bin2hex(random_bytes(32))."' );";
      if (preg_match($pat, $c)) $c = preg_replace($pat, $line, $c, 1);
    }
    if (!wp_cfg_write($conf, $c)) exit(1);
    echo "rotated";
    break;
  case 'testdb':
    $c = wp_cfg_read($conf); if ($c === false) { echo "ERR"; break; }
    $h = explode(':', wp_cfg_get($c, 'DB_HOST'))[0];
    mysqli_report(MYSQLI_REPORT_OFF);
    $m = @new mysqli($h, wp_cfg_get($c, 'DB_USER'), wp_cfg_get($c, 'DB_PASSWORD'), wp_cfg_get($c, 'DB_NAME'));
    echo ($m && !$m->connect_errno) ? "OK" : "ERR";
    if ($m) $m->close();
    break;
}
PHP
  chmod 600 "$WP_HELPER"
}

# Give each WordPress site its own database account.  A shared account with
# GRANT OPTION / global privileges turns one compromised site into access to
# every database on the host.  The original (admin/backup) account is left in
# place; only the credentials in wp-config.php move.
harden_wordpress_db() {
  local conf=$1 helper=$2 db user host grants global newuser newpass bak
  local esc_db esc_user esc_pass
  [[ ${SETUP_WP_DB_SPLIT:-1} == 1 ]] || return 0
  db=$(php "$helper" get "$conf" DB_NAME 2>/dev/null) || return 0
  user=$(php "$helper" get "$conf" DB_USER 2>/dev/null) || return 0
  host=$(php "$helper" get "$conf" DB_HOST 2>/dev/null) || return 0
  host=${host%%:*}
  [[ -n $db && -n $user ]] || return 0
  [[ $host == localhost || $host == 127.0.0.1 ]] || return 0
  # DB_NAME is quoted with backticks below and comes from a file the web user
  # can write; only a plain identifier is interpolated.
  if [[ ! $db =~ ^[A-Za-z0-9_]+$ ]]; then
    harden_warn "  - ${conf}: unusual DB_NAME; database user split skipped"
    return 0
  fi
  command -v mariadb >/dev/null 2>&1 || return 0
  grants=$(mariadb -N -e "SHOW GRANTS FOR '$(sql_escape "$user")'@'$(sql_escape "$host")'" 2>/dev/null) || return 0
  global=$(printf '%s\n' "$grants" | grep -E '^GRANT .* ON \*\.\*' | grep -vE '^GRANT USAGE ON \*\.\*' || true)
  [[ -n $global ]] || return 0
  newuser="wp_$(printf '%s' "$db" | tr -cd 'A-Za-z0-9_' | cut -c1-24)"
  [[ $newuser == wp_* && ${#newuser} -gt 3 ]] || newuser="wp_db"
  newpass=$(openssl rand -hex 24)
  esc_db=$(sql_escape "$db"); esc_user=$(sql_escape "$newuser"); esc_pass=$(sql_escape "$newpass")
  if ! mariadb <<SQL
CREATE USER IF NOT EXISTS '${esc_user}'@'localhost' IDENTIFIED BY '${esc_pass}';
ALTER USER '${esc_user}'@'localhost' IDENTIFIED BY '${esc_pass}';
GRANT ALL PRIVILEGES ON \`${esc_db}\`.* TO '${esc_user}'@'localhost';
SQL
  then
    harden_warn "  - could not create scoped database user ${newuser}"
    return 0
  fi
  if ! MYSQL_PWD="$newpass" mariadb -u "$newuser" "$db" -e 'SELECT 1' >/dev/null 2>&1; then
    harden_warn "  - scoped user ${newuser} cannot connect; ${user} left in place"
    return 0
  fi
  bak=$(tmp_file); cp -p "$conf" "$bak" 2>/dev/null || bak=""
  php "$helper" set "$conf" DB_USER "$newuser" string >/dev/null 2>&1 || true
  WP_CFG_VALUE="$newpass" php "$helper" set "$conf" DB_PASSWORD '' string >/dev/null 2>&1 || true
  if [[ $(php "$helper" testdb "$conf" 2>/dev/null) != OK ]]; then
    [[ -n $bak && -f $bak ]] && cp -p "$bak" "$conf"
    chown root:www-data "$conf" 2>/dev/null || true; chmod 640 "$conf" 2>/dev/null || true
    [[ -n $bak ]] && rm -f "$bak"
    harden_warn "  - ${conf}: scoped-user test failed; original credentials restored"
    return 0
  fi
  [[ -n $bak ]] && rm -f "$bak"
  harden_note "  - database user \`${user}\` (global) -> \`${newuser}\` scoped to \`${db}\`"
  return 0
}

harden_wordpress_audit_db() {
  local conf=$1 helper=$2 db prefix role reg rogue
  command -v mariadb >/dev/null 2>&1 || return 0
  db=$(php "$helper" get "$conf" DB_NAME 2>/dev/null) || return 0
  prefix=$(php "$helper" prefix "$conf" 2>/dev/null) || return 0
  [[ -n $db && -n $prefix ]] || return 0
  # Both values come from a file the web user can write and are interpolated
  # into SQL identifiers; only plain identifiers are accepted.
  if [[ ! $db =~ ^[A-Za-z0-9_]+$ || ! $prefix =~ ^[A-Za-z0-9_]+$ ]]; then
    harden_warn "  - ${conf}: unusual DB_NAME/table_prefix; database audit skipped"
    return 0
  fi
  role=$(mariadb -N -e "SELECT option_value FROM \`${db}\`.\`${prefix}options\` WHERE option_name='default_role' LIMIT 1;" 2>/dev/null)
  reg=$(mariadb -N -e "SELECT option_value FROM \`${db}\`.\`${prefix}options\` WHERE option_name='users_can_register' LIMIT 1;" 2>/dev/null)
  [[ -n $role && $role != subscriber ]] && harden_warn "  - ${db}: default_role=${role} (expected subscriber)"
  [[ $reg == 1 ]] && harden_warn "  - ${db}: users_can_register=1 (verify open registration is intended)"
  rogue=$(mariadb -N -e "SELECT user_login FROM \`${db}\`.\`${prefix}users\` WHERE user_login LIKE 'w2s\\_%' OR user_email LIKE '%wp2shell%';" 2>/dev/null || true)
  [[ -n $rogue ]] && harden_warn "  - ${db}: suspicious administrator login(s): ${rogue//$'\n'/, }"
  return 0
}

harden_wordpress_files() {
  local n=0 f
  [[ -d /var/www ]] || return 0
  while IFS= read -r -d '' f; do
    chmod o-w "$f" 2>/dev/null && n=$((n+1))
  done < <(find /var/www -xdev -type f -perm -0002 -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    chmod o-w "$f" 2>/dev/null && n=$((n+1))
  done < <(find /var/www -xdev -type d -perm -0002 -print0 2>/dev/null)
  (( n > 0 )) && harden_note "  - world-writable entries fixed: ${n}"
  local -a big risky
  mapfile -t big < <(find /var/www -type f \( -name '*.zip' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.lz4' -o -name '*.tar.gz' \) -size +100M ! -path '*/mysql_database/*' ! -path '*/wpvividbackups/*' 2>/dev/null | head -20 || true)
  if (( ${#big[@]} > 0 )); then
    harden_warn "  - large archives inside web-accessible paths:"
    for f in "${big[@]}"; do harden_warn "      ${f}"; done
  fi
  mapfile -t risky < <(find /var/www -maxdepth 5 -type d \( -name 'wp-file-manager' -o -name 'file-manager-advanced' -o -name 'duplicator' -o -name 'wpcoderpro' -o -name 'insert-headers-and-footers' \) 2>/dev/null | head -20 || true)
  if (( ${#risky[@]} > 0 )); then
    harden_warn "  - high-risk code/upload plugins installed (review or remove):"
    for f in "${risky[@]}"; do harden_warn "      ${f}"; done
  fi
  return 0
}

# Known WordPress webshell families and the plugin-name pattern used by the
# WP2SHELL/SEO-spam droppers.  Quarantine by default so a false positive can
# be restored; SETUP_PURGE_MALWARE=1 removes the files instead.
scan_wordpress_malware() {
  local ts q f rel count=0
  local -a hits
  [[ -d /var/www ]] || return 0
  mapfile -t hits < <(
    {
      find /var/www -type f \( -name 'wp-vcd.php' -o -name 'wp-tmp.php' -o -name 'wp-feed.php' -o -name 'wp-cd.php' \) 2>/dev/null || true
      find /var/www -type d -regextype posix-extended -regex '.*/wp-content/plugins/[a-z0-9-]+-[0-9a-f]{10}$' 2>/dev/null || true
      grep -rIl --include='*.php' --exclude-dir=mysql_database --exclude-dir=wpvividbackups --exclude-dir=node_modules --exclude-dir=.git -E 'wputils/v1|w2s_run|WP_V_CD|plimur\.spekt\.pw' /var/www 2>/dev/null || true
    } | sort -u || true
  )
  if (( ${#hits[@]} == 0 )); then
    harden_note "  - malware scan: no known webshell signatures found"
    return 0
  fi
  if [[ ${SETUP_PURGE_MALWARE:-0} == 1 ]]; then
    for f in "${hits[@]}"; do rm -rf -- "$f" && count=$((count+1)); done
    harden_warn "  - malware: deleted ${count} known malicious path(s)"
    return 0
  fi
  ts=$(date +%Y%m%d-%H%M%S); q="/var/lib/setup-quarantine/${ts}"
  mkdir -p "$q"; chmod 700 "$q"
  for f in "${hits[@]}"; do
    rel=${f#/}
    mkdir -p "$q/$(dirname "$rel")"
    if mv -- "$f" "$q/$rel" 2>/dev/null; then
      printf '%s\n' "$f" >> "$q/MANIFEST.txt"
      count=$((count+1))
    fi
  done
  chmod -R 000 "$q" 2>/dev/null || true
  chmod 600 "$q/MANIFEST.txt" 2>/dev/null || true
  harden_warn "  - malware: quarantined ${count} path(s) to ${q} (SETUP_PURGE_MALWARE=1 deletes)"
  return 0
}

harden_wordpress() {
  local conf helper rc=0 kv
  local -a configs
  mapfile -t configs < <(app_find_wordpress_configs)
  if (( ${#configs[@]} == 0 )); then
    harden_note "- WordPress: no wp-config.php found under /var/www"
    harden_wordpress_files || true
    scan_wordpress_malware || true
    return 0
  fi
  if ! command -v php >/dev/null 2>&1; then
    harden_warn "- WordPress: PHP is not installed; skipped wp-config hardening"
    harden_wordpress_files || true
    scan_wordpress_malware || true
    return 0
  fi
  write_wp_config_helper
  helper=$WP_HELPER
  for conf in "${configs[@]}"; do
    case "$conf" in */backup/*|*/mysql_database/*|*/logs/*) continue ;; esac
    harden_note "- WordPress \`${conf}\`"
    if [[ -z $(php "$helper" get "$conf" DB_NAME 2>/dev/null) ]]; then
      harden_note "  - not a WordPress config (no DB_NAME); skipped"
      continue
    fi
    chown root:www-data "$conf" 2>/dev/null || true
    chmod 640 "$conf" 2>/dev/null || true
    for kv in "DISALLOW_FILE_EDIT:true" "DISABLE_WP_CRON:true" "WP_DEBUG_DISPLAY:false" "FORCE_SSL_ADMIN:true"; do
      php "$helper" set "$conf" "${kv%%:*}" "${kv#*:}" literal >/dev/null 2>&1 \
        || { harden_warn "  - could not set ${kv%%:*}"; rc=1; }
    done
    if [[ ${SETUP_WP_ALLOW_FILE_MODS:-0} == 1 ]]; then
      harden_note "  - DISALLOW_FILE_MODS skipped (SETUP_WP_ALLOW_FILE_MODS=1)"
    else
      php "$helper" set "$conf" DISALLOW_FILE_MODS true literal >/dev/null 2>&1 \
        || { harden_warn "  - could not set DISALLOW_FILE_MODS"; rc=1; }
      harden_note "  - plugin/theme installs disabled (update via WP-CLI or the server; SETUP_WP_ALLOW_FILE_MODS=1 to skip)"
    fi
    if [[ $(php "$helper" salts "$conf" 2>/dev/null) == rotated ]]; then
      harden_note "  - placeholder salts replaced"
    fi
    harden_wordpress_db "$conf" "$helper" || rc=1
    harden_wordpress_audit_db "$conf" "$helper" || true
  done
  rm -f "$helper"; WP_HELPER=""
  harden_wordpress_files || rc=1
  scan_wordpress_malware || rc=1
  return "$rc"
}

harden_system() {
  local install=${1:-0} cfgf sshd_t
  if (( install )); then
    apt_install unattended-upgrades || true
  fi
  if pkg_ok unattended-upgrades; then
    # Recorded once so --purge basic can restore the file and the unit state.
    record_original /etc/apt/apt.conf.d/20auto-upgrades apt-20auto-upgrades
    if [[ ! -f "${STATE_DIR}/unattended-upgrades-enabled" && ! -f "${STATE_DIR}/unattended-upgrades-was-enabled" ]]; then
      if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        touch "${STATE_DIR}/unattended-upgrades-was-enabled"
      else
        touch "${STATE_DIR}/unattended-upgrades-enabled"
      fi
    fi
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    harden_note "- OS updates: unattended-upgrades enabled"
  else
    harden_warn "- OS updates: unattended-upgrades is not installed (run --basic or install it)"
  fi
  if [[ -f /etc/mysqlbkup.cnf ]]; then
    # This file holds the MariaDB admin/backup password.  Never make it
    # readable by the PHP user.
    chown root:root /etc/mysqlbkup.cnf 2>/dev/null || true
    chmod 600 /etc/mysqlbkup.cnf 2>/dev/null || true
  fi
  for cfgf in /etc/mysqlbkup.config /root/tools/mysqlbackup-master/mysqlbkup.cnf.sample; do
    [[ -f $cfgf ]] || continue
    local keep
    keep=$(grep -E '^MAX_BACKUPS=' "$cfgf" 2>/dev/null | head -n1 | cut -d= -f2)
    if [[ $keep =~ ^[0-9]+$ ]] && (( keep < 30 )); then
      sed_in_place 's/^MAX_BACKUPS=.*/MAX_BACKUPS=30/' "$cfgf"
    fi
  done
  sshd_t=$(sshd -T 2>/dev/null || true)
  if grep -qi '^passwordauthentication yes' <<<"$sshd_t"; then
    harden_warn "- SSH: password authentication is enabled; switch to keys-only access once key login is confirmed"
  fi
  if ufw status 2>/dev/null | grep -qE '^(80|443)(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere'; then
    harden_warn "- Firewall: 80/443 are open to the internet; restrict them to your CDN/proxy ranges if the origin is not meant to be reached directly"
  fi
  if systemctl is-active --quiet elasticsearch 2>/dev/null; then
    # The installer writes network.host: "localhost" (quoted); ::1 and the
    # _local_ special value are loopback as well.
    if grep -qE '^[[:space:]]*network\.host:' /etc/elasticsearch/elasticsearch.yml 2>/dev/null \
       && ! grep -qE '^[[:space:]]*network\.host:[[:space:]]*["'"'"']?(127\.0\.0\.1|localhost|::1|\[::1\]|_local_)["'"'"']?[[:space:]]*(#.*)?$' /etc/elasticsearch/elasticsearch.yml 2>/dev/null; then
      harden_warn "- Elasticsearch: network.host is not loopback; bind it to 127.0.0.1 or enable xpack security"
    fi
  fi
  return 0
}

audit_app_persistent_connections() {
  local socket_hint conf dbhost redis_path redis_host redis_value
  local xf_dbhost xf_cache_host xf_cache_port found=0 issues=0
  local redis_persistent=0
  APP_CONNECTION_ISSUES=0
  socket_hint=$(app_cache_socket_hint)
  opt_report "## Application connection notices"

  while IFS= read -r conf; do
    [[ -n $conf ]] || continue
    case "$conf" in
      */backup/*|*/mysql_database/*|*/logs/*) continue ;;
    esac
    found=1
    dbhost=$(wp_db_host_from_config "$conf")
    redis_path=$(wp_redis_path_from_config "$conf")
    redis_host=$(wp_redis_host_from_config "$conf")
    redis_persistent=0
    if wp_redis_persistent_from_config "$conf"; then
      redis_persistent=1
    fi
    redis_value=${redis_path:-$redis_host}

    opt_report "- WordPress \`${conf}\`"
    if [[ -z $dbhost ]]; then
      opt_report "  - DB_HOST was not found; verify the MariaDB connection manually."
      issues=$((issues + 1))
    elif [[ $dbhost == p:* ]]; then
      # wpdb::parse_db_host() splits on the first colon, so "p:localhost"
      # becomes host "p" and every page is "Error establishing a database
      # connection" (measured: HTTP 500 on WordPress 7.1).  Core has no
      # persistent-connection switch; only a custom wp-content/db.php can
      # open one.
      opt_report "  - **DB_HOST \`${dbhost}\` breaks WordPress**: core parses it as host \`p\`; set \`define('DB_HOST', '${dbhost#p:}');\`"
      issues=$((issues + 1))
    else
      opt_report "  - MariaDB host \`${dbhost}\` (WordPress core opens one connection per request; it has no persistent-connection option)."
    fi
    if [[ -z $redis_value ]]; then
      opt_report "  - No Valkey/Redis cache is configured (optional)."
    elif app_is_socket_path "$redis_value"; then
      if (( redis_persistent )); then
        opt_report "  - Valkey uses \`${redis_value}\` with persistent connections."
      else
        opt_report "  - Valkey uses \`${redis_value}\`; add \`define('WP_REDIS_PERSISTENT', true);\`"
        issues=$((issues + 1))
      fi
    else
      opt_report "  - Valkey/Redis endpoint \`${redis_value}\` is not the local socket; set \`define('WP_REDIS_PATH', '${socket_hint}');\` and \`define('WP_REDIS_PERSISTENT', true);\`"
      issues=$((issues + 1))
    fi
  done < <(app_find_wordpress_configs)

  while IFS= read -r conf; do
    [[ -n $conf ]] || continue
    case "$conf" in
      */backup/*|*/mysql_database/*|*/logs/*) continue ;;
    esac
    found=1
    xf_dbhost=$(xf_db_host_from_config "$conf")
    xf_cache_host=$(xf_cache_host_from_config "$conf")
    xf_cache_port=$(xf_cache_port_from_config "$conf")
    opt_report "- XenForo \`${conf}\`"
    if [[ -z $xf_dbhost ]]; then
      opt_report "  - Database host was not found; verify the MariaDB connection manually."
      issues=$((issues + 1))
    elif [[ $xf_dbhost == p:* ]]; then
      opt_report "  - MariaDB host is persistent (\`${xf_dbhost}\`)."
    else
      opt_report "  - MariaDB host \`${xf_dbhost}\` is not persistent; set \`\$config['db']['host'] = 'p:localhost';\`"
      issues=$((issues + 1))
    fi
    if [[ -z $xf_cache_host ]]; then
      opt_report "  - No Valkey/Redis cache backend is configured (optional)."
    elif app_is_socket_path "$xf_cache_host" && [[ ${xf_cache_port:-0} == 0 ]]; then
      opt_report "  - Valkey uses the local Unix socket \`${xf_cache_host}\` (port 0)."
    else
      opt_report "  - Valkey is not using the local socket; set \`\$config['cache']['config']['host'] = '${socket_hint}';\` and \`\$config['cache']['config']['port'] = 0;\`"
      issues=$((issues + 1))
    fi
    if (( XF_JOB_CRON )); then
      opt_report "  - Jobs: the managed crontab runs \`cmd.php xf:run-jobs\` every minute as www-data; set *Options > Performance > Job run trigger* to server-based so member page requests stop running the queue (SETUP_XF_JOB_CRON=0 removes the entry)."
    else
      opt_report "  - Jobs: no managed runner (XF_JOB_CRON=0); the queue runs inside page requests."
    fi
  done < <(app_find_xenforo_configs)

  if (( found == 0 )); then
    opt_report "- No WordPress or XenForo configuration was found under /var/www."
  fi
  APP_CONNECTION_ISSUES=$issues
  return 0
}

