# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).
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

# MariaDB is optional.  Detect the server before live probes so a host
# without it reports "not installed" instead of "command not found".
diag_mariadb_installed() {
  command -v mariadbd >/dev/null 2>&1 && return 0
  systemctl cat mariadb.service >/dev/null 2>&1 && return 0
  [[ -x /usr/sbin/mariadbd ]] && return 0
  return 1
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

# Elasticsearch is optional.  Detect the package/unit before probing HTTP so a
# host without it reports "not installed" instead of five curl failures.
diag_elasticsearch_installed() {
  systemctl cat elasticsearch.service >/dev/null 2>&1 && return 0
  command -v elasticsearch >/dev/null 2>&1 && return 0
  [[ -x /usr/share/elasticsearch/bin/elasticsearch ]] && return 0
  return 1
}

# `_cluster/allocation/explain` returns HTTP 400 when every shard is already
# assigned.  Treat that as healthy instead of reporting a diagnostic error.
diag_elasticsearch_allocation() {  local es_url=$1 health status unassigned
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
  give_to_invoking_user "$out"
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
  diag_sh "PHP-FPM versions" 'for d in /etc/php/*/fpm; do [ -d "$d" ] || continue; v=${d%/fpm}; v=${v##*/}; echo "--- PHP $v"; if command -v "php-fpm$v" >/dev/null 2>&1; then "php-fpm$v" -v; elif [ -x "/usr/sbin/php-fpm$v" ]; then "/usr/sbin/php-fpm$v" -v 2>&1; else echo "no php-fpm${v} binary (stale configuration directory)"; fi; done'
  while IFS= read -r ver; do
    [[ -n $ver ]] || continue
    fpm_bin=$(php_fpm_binary "$ver" || printf '/usr/sbin/php-fpm%s' "$ver")
    diag "PHP ${ver} FPM version" "$fpm_bin" -v
    diag "PHP ${ver} FPM test" "$fpm_bin" -t
    diag "PHP ${ver} pool" cat "/etc/php/${ver}/fpm/pool.d/www.conf"
    diag "PHP ${ver} global config" cat "/etc/php/${ver}/fpm/php-fpm.conf"
    diag_sh "PHP ${ver} conf.d" "find /etc/php/${ver}/fpm/conf.d -maxdepth 1 -type f -print -exec sh -c 'echo --- \$1; cat \"\$1\"' _ {} \\;"
    diag_sh "PHP ${ver} processes" "ps -eo pid,ppid,user,%cpu,%mem,rss,etime,cmd | grep -E '[p]hp-fpm' | head -60"
    diag_sh "PHP ${ver} listeners" "ss -lxp | grep -E 'php${ver}|php-fpm' || true"
    diag "PHP ${ver} status" diag_php_fpm_status "$ver"
  done < <(php_fpm_versions)

  if diag_mariadb_installed; then
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
  elif command -v mariadb >/dev/null 2>&1; then
    diag "MariaDB client version" mariadb --version
    diag_sh "MariaDB" 'printf "%s\n" "MariaDB server is not installed (client only)."'
    diag "MariaDB resolved log files" diag_mariadb_log_files
  else
    diag_sh "MariaDB" 'printf "%s\n" "MariaDB is not installed."'
  fi
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

  if ! diag_elasticsearch_installed; then
    diag_sh "Elasticsearch" 'printf "%s\n" "Elasticsearch is not installed."'
  else
    es_url=$(elasticsearch_http_url)
    if systemctl is-active --quiet elasticsearch 2>/dev/null; then
      diag "Elasticsearch root" curl -fsS --max-time 5 "$es_url"
      diag "Elasticsearch health" curl -fsS --max-time 5 "${es_url}/_cluster/health?pretty"
      diag "Elasticsearch nodes" curl -fsS --max-time 5 "${es_url}/_cat/nodes?v"
      diag "Elasticsearch indices" curl -fsS --max-time 5 "${es_url}/_cat/indices?v&s=store.size:desc"
      diag_sh "Elasticsearch node stats" "curl -fsS --max-time 10 '${es_url}/_nodes/stats/jvm,os,indices,thread_pool?pretty' | head -n 500"
      diag "Elasticsearch allocation" diag_elasticsearch_allocation "$es_url"
    else
      diag "Elasticsearch status" systemctl status elasticsearch --no-pager -l
      diag_sh "Elasticsearch" 'printf "%s\n" "Elasticsearch is installed but not running; live probes skipped."'
    fi
    diag_sh "Elasticsearch YAML" 'if [ -f /etc/elasticsearch/elasticsearch.yml ]; then cat /etc/elasticsearch/elasticsearch.yml; else echo "Elasticsearch is not installed"; fi'
    diag_sh "Elasticsearch JVM options" 'find /etc/elasticsearch/jvm.options.d -maxdepth 1 -type f -print -exec sh -c "echo --- \$1; cat \"\$1\"" _ {} \; 2>/dev/null || true'
    diag_sh "Elasticsearch systemd limits" 'if [ -f /etc/systemd/system/elasticsearch.service.d/limits.conf ]; then cat /etc/systemd/system/elasticsearch.service.d/limits.conf; else echo "systemd drop-in is not installed"; fi'
    diag_sh "Elasticsearch log size" 'du -sh /var/www/logs/elasticsearch /var/log/elasticsearch 2>/dev/null || true'
    diag "Elasticsearch resolved log files" diag_es_log_files
  fi

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
  diag_sh "cache and data sizes" 'du -sh /var/lib/mysql /var/lib/mariadb /var/lib/elasticsearch /var/cache/angie /home/nginx_cache* /var/cache/php/opcache 2>/dev/null | sort -h || true'

  redact_diagnostics "$DIAG_FILE"

  {
    printf '\n\n===== diagnostics complete =====\n'
    printf 'Finished: %s\n' "$(date -Is 2>/dev/null || date)"
    printf 'Size: %s\n' "$(du -h "$DIAG_FILE" 2>/dev/null | awk '{print $1}')"
  } >> "$DIAG_FILE"

  chmod 600 "$DIAG_FILE"
  printf '%s\n' "$DIAG_FILE"
}

