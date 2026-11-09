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
    # A file the tune created (a drop-in such as 99-setup-optimize.cnf or
    # zz-setup-optimize.options on a host that had none) is not in the
    # snapshot and would win again on the rollback restart; the shared
    # restore moves such files to /tmp like the single-file `.absent` path.
    if [[ -d $src ]]; then
      local line extra
      while IFS= read -r line; do
        [[ $line == moved\ * ]] || continue
        extra=${line#moved }
        moved=${extra##* }
        extra=${extra% *}
        opt_report "ROLLBACK: moved new \`${extra}\` to \`${moved}\` (not deleted)"
      done < <(restore_snapshot_dir "$src" "$path" || opt_report "ROLLBACK: **FAILED** to fully restore \`${path}\`")
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

# Undo a failed service tune: restore its configuration tree and systemd
# drop-in from the optimize backup, reload systemd and start it again on the
# previous files.  Shared by the MariaDB, Valkey/Redis and Elasticsearch paths.
opt_rollback_restart() {
  local unit=$1 conf_dir=$2 conf_name=$3 dropin_name=$4
  opt_restore "$conf_dir" "$conf_name"
  opt_restore "/etc/systemd/system/${unit}.service.d" "$dropin_name"
  systemctl daemon-reload || true
  systemctl restart "$unit" 2>/dev/null || true
}

# Restart UNIT and run PROBE (a command; it may set OPT_RESTART_FAIL_NOTE).
# A failed restart or probe is reported and rolled back to the --optimize
# snapshot (CONF_DIR plus the unit drop-in); the caller only adds its own
# service-specific follow-up.  Shared by the MariaDB, Valkey/Redis and
# Elasticsearch tuners so the three restart paths cannot drift apart.
opt_restart_service() {
  local unit=$1 conf_dir=$2 conf_name=$3 dropin_name=$4
  shift 4
  OPT_RESTART_FAIL_NOTE=""
  if ! systemctl restart "$unit" 2>/dev/null; then
    opt_report "- Restart: **FAILED**; rolling back"
    opt_rollback_restart "$unit" "$conf_dir" "$conf_name" "$dropin_name"
    return 1
  fi
  OPT_CUTOVER=1
  if "$@"; then
    opt_report "- Restart: **OK**${OPT_RESTART_OK_NOTE:+ ${OPT_RESTART_OK_NOTE}}"
    OPT_RESTART_OK_NOTE=""
    return 0
  fi
  opt_report "- Restart: **FAILED**${OPT_RESTART_FAIL_NOTE:+ (${OPT_RESTART_FAIL_NOTE})}; rolling back"
  opt_rollback_restart "$unit" "$conf_dir" "$conf_name" "$dropin_name"
  return 1
}
OPT_RESTART_FAIL_NOTE=""
OPT_RESTART_OK_NOTE=""

mariadb_restart_probe() {
  mariadb_wait_ready 300 && return 0
  OPT_RESTART_FAIL_NOTE="SQL probe"
  return 1
}

valkey_restart_probe() {
  wait_for_cmd 20 valkey_pong "$1" && return 0
  OPT_RESTART_FAIL_NOTE="PING"
  return 1
}

# Wait for the Elasticsearch HTTP endpoint after a (re)start.  Returns 0 when
# it answers 200, 2 when the unit is active and owns the configured listener
# but this host cannot reach it (firewall/NAT or a client-only allow rule),
# 1 otherwise.  ES_WAIT_LAST_CODE keeps the last HTTP code for the report.
elasticsearch_wait_http() {
  local url=$1 attempts=${2:-300} i code=""
  ES_WAIT_LAST_CODE=""
  if ! command -v curl >/dev/null 2>&1; then
    elasticsearch_listener_on "$url" && return 2
    return 1
  fi
  for (( i = 0; i < attempts; i++ )); do
    code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    [[ $code == 200 ]] && return 0
    ES_WAIT_LAST_CODE=$code
    if ! systemctl is-active --quiet elasticsearch; then
      ES_WAIT_LAST_CODE="unit-inactive"
      return 1
    fi
    if [[ $code == 000 || -z $code ]] && elasticsearch_listener_on "$url"; then
      return 2
    fi
    sleep 1
  done
  return 1
}
ES_WAIT_LAST_CODE=""

elasticsearch_restart_probe() {
  local url=$1 rc=0
  elasticsearch_wait_http "$url" 300 || rc=$?
  case $rc in
    0) return 0 ;;
    2)
      # The unit restarted and owns the configured listener, but this host
      # cannot reach that address.  Do not roll back a healthy tune.
      OPT_RESTART_OK_NOTE="(unit active and listening on \`${url#*://}\`; HTTP probe from this host was unavailable — verify from the XenForo client)"
      return 0 ;;
  esac
  OPT_RESTART_FAIL_NOTE="HTTP probe to \`${url}\` returned ${ES_WAIT_LAST_CODE:-no response}"
  return 1
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
OPT_PHP_CHILDREN=0
OPT_MARIADB_BUDGET_MB=0
OPT_MARIADB_KEPT_MB=0
OPT_VALKEY_BUDGET_MB=0
OPT_VALKEY_LIVE_MB=0
OPT_ES_BUDGET_MB=0
OPT_ES_KEPT_MB=0
# Set while plan_install_budget() runs.  A fresh install has no live database
# or index to measure, so the planner must use the same empty-data floors that
# --optimize applies instead of the larger "unmeasured" fallbacks.
OPT_INSTALL_PLAN=0

# RAM available to this host in MB.  Like effective_cpus, honour a cgroup
# memory limit: inside a container or an LXC-class VPS /proc/meminfo reports
# the hypervisor's RAM, which would size PHP workers, the buffer pool and the
# kernel limits for memory this guest cannot use.
mem_total_mb() {
  local mb limit=""
  mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)
  [[ $mb =~ ^[0-9]+$ ]] && (( mb > 0 )) || mb=1024
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    limit=$(< /sys/fs/cgroup/memory.max)
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    limit=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
  fi
  if [[ $limit =~ ^[0-9]+$ ]] && (( limit > 0 )); then
    limit=$(( limit / 1024 / 1024 ))
    (( limit > 0 && limit < mb )) && mb=$limit
  fi
  printf '%s' "$mb"
}

# Directory size in whole MB (0 when missing).  The optional patterns are
# passed to du --exclude so log/undo/temp files are not counted as data.
dir_size_mb() {
  local dir=$1 mb=""
  shift
  [[ -d $dir ]] || { printf '0'; return 0; }
  local -a excl=()
  local pat
  for pat in "$@"; do excl+=("--exclude=${pat}"); done
  mb=$(du -sm "${excl[@]}" "$dir" 2>/dev/null | awk 'NR==1 { print $1 }' || true)
  [[ $mb =~ ^[0-9]+$ ]] || mb=0
  printf '%s' "$mb"
  return 0
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

# Fallback when SQL is unavailable (served stopped): estimate the live store
# from the data directory.  Used only when the exact query cannot run.
mariadb_data_dir_size_mb() {
  local dir
  dir=$(mariadb -N -B -e 'SELECT @@datadir' 2>/dev/null | head -n1 || true)
  if [[ -z $dir || ! -d $dir ]]; then
    for dir in /var/lib/mariadb /var/lib/mysql; do
      [[ -d $dir ]] && break
    done
  fi
  # Redo/undo logs, temp tablespaces and binlogs are not data+index; counting
  # them made the fallback disagree with the information_schema measurement
  # (a fresh install was sized from 300 MB of log files, then shrunk by the
  # first --optimize).
  dir_size_mb "$dir" 'ib_logfile*' 'ibtmp*' 'undo*' 'aria_log*' '*.log' \
    '*-bin.*' 'ddl_recovery*' 'ib_buffer_pool' 'tc.log'
  return 0
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
# First numeric / string value of KEY in a flat Elasticsearch JSON reply (no
# jq dependency; the replies are filter_path-trimmed and small).
es_json_num() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n1
}
es_json_str() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

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
  bytes=$(es_json_num "$resp" size_in_bytes)
  [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
  printf '%s' $(( bytes / 1024 / 1024 ))
}

# Fallback when the HTTP API is unavailable: estimate the index store from
# the Elasticsearch data directory.
elasticsearch_data_dir_size_mb() {
  dir_size_mb /var/lib/elasticsearch 'translog' '*.log'
  return 0
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
  local total usable
  local has_php=0 has_maria=0 has_cache=0 has_es=0
  # A fresh install has no pool to measure.  It plans at the 64 MB floor that
  # php_worker_allowance_mb measures for a freshly started, idle pool, so the
  # first --optimize after the install reserves the same PHP budget.
  local cpu=1 allowance=64 php_capacity=0 php_floor=0 php_budget=0 children=0
  local maria_target=0 valkey_target=0 es_target=0
  local maria_alloc=0 valkey_alloc=0 es_alloc=0
  local maria_fixed=0 valkey_fixed=0 es_fixed=0
  local data="" current_pool=0 kept_pool=0
  local cache_used=""
  local es_store="" es_kept=0 current_heap=0
  local remaining data_pool targets_sum alloc_total excess dec
  local explicit=""

  total=$(mem_total_mb)
  (( total > 0 )) || total=1024
  OPT_MEM_TOTAL_MB=$total
  usable=$(( total * 80 / 100 ))
  OPT_MEM_BUDGET_MB=$usable
  OPT_PHP_BUDGET_MB=0
  OPT_PHP_CHILDREN=0
  OPT_MARIADB_BUDGET_MB=0
  OPT_MARIADB_KEPT_MB=0
  OPT_VALKEY_BUDGET_MB=0
  OPT_VALKEY_LIVE_MB=0
  OPT_ES_BUDGET_MB=0
  OPT_ES_KEPT_MB=0
  OPT_DB_SIZE_MB=0
  OPT_ES_SIZE_MB=0

  [[ " ${OPT_DETECTED[*]} " == *" php:"* ]] && has_php=1
  [[ " ${OPT_DETECTED[*]} " == *" mariadb "* ]] && has_maria=1
  [[ " ${OPT_DETECTED[*]} " == *" valkey "* || " ${OPT_DETECTED[*]} " == *" redis "* ]] && has_cache=1
  [[ " ${OPT_DETECTED[*]} " == *" elastic "* ]] && has_es=1
  cpu=$(effective_cpus)
  (( cpu > 0 )) || cpu=1

  # PHP is sized last, but keep a small floor so a database-heavy host still
  # serves requests.  A live pool's measured worker RSS sets the allowance.
  if (( has_php )); then
    if (( ! OPT_INSTALL_PLAN )); then
      local ver php_allowance
      ver=$(php_primary_version 2>/dev/null || true)
      if [[ -n $ver ]]; then
        php_allowance=$(php_worker_allowance_mb "$ver" 2>/dev/null || true)
        [[ $php_allowance =~ ^[0-9]+$ ]] && allowance=$php_allowance
      fi
    fi
    local live_children=""
    if (( ! OPT_INSTALL_PLAN )); then
      live_children=$(php_pool_max_children)
    fi
    explicit=$(explicit_option php_children 2>/dev/null || true)
    php_capacity=$(php_children_ceiling "$cpu" "$total" "$live_children" "$explicit")
    php_floor=$(( $(php_children_floor "$total") * allowance ))
    (( php_floor < 256 )) && php_floor=256
    (( php_floor > usable / 2 )) && php_floor=$(( usable / 2 ))
  fi

  # MariaDB target: live data+index plus at most 20% headroom.  Nothing is
  # added for an empty database beyond a small operational minimum, so spare
  # RAM is not wasted on an idle buffer pool.
  if (( has_maria )); then
    explicit=$(explicit_option mariadb_size_mb 2>/dev/null || true)
    if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit >= 128 )); then
      maria_target=$explicit
      maria_fixed=1
    else
      data=""
      # A service that is not installed yet has nothing to measure; the
      # directory fallback would count a previous installation's files.
      if (( ! OPT_INSTALL_PLAN )) || pkg_ok mariadb-server; then
        data=$(mariadb_data_size_mb)
        [[ $data =~ ^[0-9]+$ ]] || data=$(mariadb_data_dir_size_mb)
      fi
      [[ $data =~ ^[0-9]+$ ]] || data=0
      OPT_DB_SIZE_MB=$data
      maria_target=$(( data * 120 / 100 ))
      # Live data +20% cannot grow faster than 20% per run and a fresh
      # install (or a site filled through a web installer) measures nothing;
      # a RAM-proportional floor gives the pool room before the next
      # --optimize, like valkey_floor_mb does for the cache.
      local maria_floor
      maria_floor=$(mariadb_floor_mb "$total")
      (( maria_target < maria_floor )) && maria_target=$maria_floor
    fi
    current_pool=$(mariadb_current_pool_mb)
    if [[ $current_pool =~ ^[0-9]+$ ]] && (( current_pool > 0 )); then
      if (( current_pool * 100 <= maria_target * 102 \
            && current_pool * 100 >= maria_target * 98 )); then
        maria_target=$current_pool
        kept_pool=$current_pool
      fi
    fi
  fi

  # Valkey target: live used_memory plus at most 20% headroom.  An empty or
  # stopped cache gets the small operational minimum, not a RAM percentage.
  if (( has_cache )); then
    explicit=$(explicit_option valkey_mb 2>/dev/null || true)
    if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit >= 1 )); then
      valkey_target=$explicit
      valkey_fixed=1
    else
      if (( ! OPT_INSTALL_PLAN )); then
        cache_used=$(valkey_live_used_mb 2>/dev/null || true)
      fi
      [[ $cache_used =~ ^[0-9]+$ ]] || cache_used=$(valkey_data_size_mb)
      [[ $cache_used =~ ^[0-9]+$ ]] || cache_used=0
      if (( cache_used > 0 )); then
        OPT_VALKEY_LIVE_MB=$cache_used
      fi
      valkey_target=$(( cache_used * 120 / 100 ))
      # Live data +20% can only grow 20% per run (allkeys-lru keeps the
      # working set at maxmemory), and a fresh install has no data at all;
      # a RAM-proportional floor gives the cache room to show real demand.
      local floor_mb
      floor_mb=$(valkey_floor_mb "$total")
      (( valkey_target < floor_mb )) && valkey_target=$floor_mb
    fi
    (( valkey_target < 128 )) && valkey_target=128
  fi

  # Elasticsearch target: live index store plus at most 20% headroom, with a
  # 512 MB operational minimum for an empty index; no RAM-percentage fallback.
  if (( has_es )); then
    explicit=$(explicit_option elastic_mb 2>/dev/null || true)
    if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit >= 1 )); then
      es_target=$explicit
      es_fixed=1
    else
      es_store=""
      if (( ! OPT_INSTALL_PLAN )) || pkg_ok elasticsearch; then
        es_store=$(elasticsearch_data_size_mb)
        [[ $es_store =~ ^[0-9]+$ ]] || es_store=$(elasticsearch_data_dir_size_mb)
      fi
      [[ $es_store =~ ^[0-9]+$ ]] || es_store=0
      OPT_ES_SIZE_MB=$es_store
      # The heap does not hold the index: the OS page cache serves the store
      # and the heap holds fielddata, aggregations and request buffers.  A
      # quarter of the store (rounded up to 512 MB) is ample for forum/blog
      # search; sizing the heap to the store took RAM from the page cache
      # and MariaDB.  Capped at 25% of RAM like the stand-alone fallback.
      es_target=$(( es_store / 4 ))
      (( es_target < 512 )) && es_target=512
      local es_cap=$(( total * 25 / 100 ))
      (( es_cap < 512 )) && es_cap=512
      (( es_target > es_cap )) && es_target=$es_cap
    fi
    (( es_target < 512 )) && es_target=512
    (( es_target > 31744 )) && es_target=31744
    # Round the target up once, before the live-heap comparison, so the 2%
    # drift window is measured against the value that will be written.
    es_target=$(( (es_target + 511) / 512 * 512 ))
    (( es_target > 31744 )) && es_target=31744
    current_heap=$(elasticsearch_current_heap_mb)
    if [[ $current_heap =~ ^[0-9]+$ ]] && (( current_heap > 0 )); then
      if (( current_heap * 100 <= es_target * 102 \
            && current_heap * 100 >= es_target * 98 )); then
        es_target=$current_heap
        es_kept=$current_heap
      fi
    fi
  fi

  # Reserve the live data services first.  PHP keeps only its 8-worker floor
  # during this pass so the data tier can fit; the remainder goes to PHP and
  # finally to the OS page cache.  If all targets cannot fit, scale them
  # proportionally and trim Elasticsearch first, then Valkey, then MariaDB.
  data_pool=$(( usable - php_floor ))
  (( data_pool < 0 )) && data_pool=0
  # Explicit operator sizes are never scaled: the installer writes them
  # verbatim, so the plan reserves them verbatim too; otherwise the next
  # --optimize would shrink what the operator asked for.
  local fixed_sum=0 flex_pool flex_sum
  (( maria_fixed ))  && fixed_sum=$(( fixed_sum + maria_target ))
  (( valkey_fixed )) && fixed_sum=$(( fixed_sum + valkey_target ))
  (( es_fixed ))     && fixed_sum=$(( fixed_sum + es_target ))
  flex_pool=$(( data_pool - fixed_sum ))
  (( flex_pool < 0 )) && flex_pool=0
  targets_sum=$(( maria_target + valkey_target + es_target ))
  if (( targets_sum <= data_pool )); then
    maria_alloc=$maria_target
    valkey_alloc=$valkey_target
    es_alloc=$es_target
  elif (( targets_sum > 0 )); then
    flex_sum=$(( targets_sum - fixed_sum ))
    (( flex_sum > 0 )) || flex_sum=1
    maria_alloc=$maria_target
    valkey_alloc=$valkey_target
    es_alloc=$es_target
    (( maria_fixed ))  || maria_alloc=$(( maria_target * flex_pool / flex_sum ))
    (( valkey_fixed )) || valkey_alloc=$(( valkey_target * flex_pool / flex_sum ))
    (( es_fixed ))     || es_alloc=$(( es_target * flex_pool / flex_sum ))
    (( has_maria && maria_alloc < 256 )) && maria_alloc=256
    (( has_cache && valkey_alloc < 256 )) && valkey_alloc=256
    (( has_es && es_alloc < 512 )) && es_alloc=512
    alloc_total=$(( maria_alloc + valkey_alloc + es_alloc ))
    excess=$(( alloc_total - data_pool ))
    while (( excess > 0 )); do
      if (( has_es && ! es_fixed && es_alloc > 512 )); then
        dec=$(( es_alloc - 512 )); (( dec > excess )) && dec=$excess
        es_alloc=$(( es_alloc - dec )); excess=$(( excess - dec ))
      elif (( has_cache && ! valkey_fixed && valkey_alloc > 256 )); then
        dec=$(( valkey_alloc - 256 )); (( dec > excess )) && dec=$excess
        valkey_alloc=$(( valkey_alloc - dec )); excess=$(( excess - dec ))
      elif (( has_maria && ! maria_fixed && maria_alloc > 256 )); then
        dec=$(( maria_alloc - 256 )); (( dec > excess )) && dec=$excess
        maria_alloc=$(( maria_alloc - dec )); excess=$(( excess - dec ))
      else
        break
      fi
    done
  fi
  # The operational floors (256 MB MariaDB/Valkey, 512 MB Elasticsearch, the
  # PHP worker floor) cannot be trimmed; on a 1 GB host running every service
  # they exceed the budget.  Record the overcommit so the plan and the report
  # say so instead of printing allocations that look as if they fit.
  OPT_MEM_OVERCOMMIT_MB=0
  if (( maria_alloc + valkey_alloc + es_alloc + php_floor > usable )); then
    OPT_MEM_OVERCOMMIT_MB=$(( maria_alloc + valkey_alloc + es_alloc + php_floor - usable ))
    warn "Memory plan: service floors exceed the ${usable} MB budget by ${OPT_MEM_OVERCOMMIT_MB} MB; this host is too small for the selected services"
  fi

  # PHP gets what the data tier did not need, bounded by CPU and the 50%-RAM
  # ceiling.  Eight workers are always kept when PHP is installed.
  remaining=$(( usable - maria_alloc - valkey_alloc - es_alloc ))
  (( remaining < 0 )) && remaining=0
  if (( has_php )); then
    local floor_children
    floor_children=$(php_children_floor "$total")
    children=$(( remaining / allowance ))
    (( children > php_capacity )) && children=$php_capacity
    (( children < floor_children )) && children=$floor_children
    (( children > 512 )) && children=512
    php_budget=$(( children * allowance ))
    if (( php_budget > remaining && children > floor_children )); then
      children=$(( remaining / allowance ))
      (( children < floor_children )) && children=$floor_children
      php_budget=$(( children * allowance ))
    fi
  fi

  # Normalise the search heap to a 512 MB boundary unless it is a preserved
  # live value.
  if (( has_es && es_alloc > 0 && es_kept == 0 )); then
    es_alloc=$(( es_alloc / 512 * 512 ))
    (( es_alloc < 512 )) && es_alloc=512
  fi

  OPT_MARIADB_BUDGET_MB=$maria_alloc
  OPT_MARIADB_KEPT_MB=$kept_pool
  OPT_VALKEY_BUDGET_MB=$valkey_alloc
  OPT_ES_BUDGET_MB=$es_alloc
  OPT_ES_KEPT_MB=$es_kept
  OPT_PHP_CHILDREN=$children
  OPT_PHP_BUDGET_MB=$php_budget
  return 0
}

# PHP-FPM worker ceiling for this host.  One formula for the memory plan, the
# pool writer and the dry run so the preview, a fresh install and --optimize
# agree.  Arguments: cpus, total RAM MB, live pool count ("" when none) and an
# explicit --php children= value ("" when none).
#   * per core: 16 workers on dedicated hardware, 8 on a VPS (shared cores and
#     steal time make deep oversubscription counter-productive)
#   * RAM: at most half of RAM at the 96 MB reservation divisor
#   * a live pool keeps its count (it is a memory estimate, not a quota)
#   * an explicit value wins, clamped to the same floor/512 ceiling
php_children_ceiling() {
  local cpu=$1 ram_mb=$2 live=${3:-} explicit=${4:-}
  local per_core=16 cap by_ram floor
  host_is_vps && per_core=8
  cap=$(( cpu * per_core ))
  by_ram=$(( ram_mb * 50 / 100 / 96 ))
  (( by_ram > 0 && cap > by_ram )) && cap=$by_ram
  if [[ $live =~ ^[0-9]+$ ]] && (( live > 0 )); then
    cap=$live
  fi
  # A CPU-bound application host (XenForo/WordPress with a local database)
  # is capped below the generic and live counts; see php_app_worker_cap.
  local app_cap
  if app_cap=$(php_app_worker_cap "$cpu") && [[ $app_cap =~ ^[0-9]+$ ]] && (( cap > app_cap )); then
    cap=$app_cap
  fi
  if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit > 0 )); then
    cap=$explicit
  fi
  floor=$(php_children_floor "$ram_mb")
  (( cap > 512 )) && cap=512
  (( cap < floor )) && cap=$floor
  printf '%s' "$cap"
}

# Minimum pool size.  Eight workers were kept on every host, which on a 1 GB
# VPS reserved 768 MB for PHP alone; keep the floor within half of RAM.
php_children_floor() {
  local ram_mb=$1 floor
  floor=$(( ram_mb * 50 / 100 / 96 ))
  (( floor > 8 )) && floor=8
  (( floor < 2 )) && floor=2
  printf '%s' "$floor"
}

# One decision tree for the PHP-FPM worker count, shared by the pool writer
# and the dry run so the preview and the written pool cannot disagree: a live
# pool keeps its count (the reservation is a memory estimate, not a quota),
# an explicit --php children= wins, otherwise the shared memory plan decides;
# a standalone call without a plan falls back to the 96 MB reservation
# divisor.  Arguments: cpus, RAM MB, live count (""/0 when none), explicit
# value ("" when none), planned PHP budget MB (0 when none).
php_plan_max_children() {
  local nproc=$1 ram_mb=$2 live=${3:-} explicit=${4:-} php_budget=${5:-0}
  if [[ -n $live && $live != 0 ]] || [[ -n $explicit ]]; then
    php_children_ceiling "$nproc" "$ram_mb" "$live" "$explicit"
  elif (( ${OPT_PHP_CHILDREN:-0} > 0 )); then
    printf '%s' "$OPT_PHP_CHILDREN"
  elif [[ $php_budget =~ ^[0-9]+$ ]] && (( php_budget > 0 )); then
    php_children_ceiling "$nproc" "$ram_mb" "$(( php_budget / 96 ))" ""
  else
    php_children_ceiling "$nproc" "$ram_mb" "" ""
  fi
}

# Angie worker limits shared by tune_angie_configs and the dry run.
# worker_processes follows the effective CPU count (Angie's "auto" counts the
# affinity mask, not a cgroup quota).
angie_worker_limits() {
  local nproc=$1 per_core_conn=2048 per_core_fds=8192
  ANGIE_WORKER_PROCESSES=$nproc
  # A VPS shares its NIC queue and hypervisor with neighbours; the kernel
  # backlogs are already halved there (sysctl_target_somaxconn), so the
  # per-worker connection table follows (1024/core, 4096 fds/core).
  if host_is_vps; then
    per_core_conn=1024
    per_core_fds=4096
  fi
  ANGIE_WORKER_RLIMIT=$(tune_clamp $(( nproc * per_core_fds )) 65536 524288)
  ANGIE_WORKER_CONNECTIONS=$(tune_clamp $(( nproc * per_core_conn )) 8192 65535)
  (( ANGIE_WORKER_CONNECTIONS > ANGIE_WORKER_RLIMIT - 1024 )) && ANGIE_WORKER_CONNECTIONS=$(( ANGIE_WORKER_RLIMIT - 1024 ))
  (( ANGIE_WORKER_CONNECTIONS < 1024 )) && ANGIE_WORKER_CONNECTIONS=1024
  # Angie must NOT keep idle FastCGI connections to PHP-FPM.  Every idle
  # keepalive slot pins one FPM worker (FPM waits on the same socket for the
  # next request) and the cache is per Angie worker.  On dev-host that produced
  # 16 idle connections for 16 workers; any request that landed on an Angie
  # worker without a cached connection then waited for the upstream
  # keepalive_timeout (60 s default) for a worker to be freed.  Measured on
  # the live 8 CPU host: 4-7 of every 64 non-cacheable /login requests took
  # 60-112 s; after removing the cache, 3 x 128 requests had p99 33-38 ms and
  # no request above 93 ms, with identical p50 (24-25 ms) and sequential
  # latency (14 ms).  A Unix-socket connect is cheaper than any keepalive
  # benefit here.  ANGIE_PHP_KEEPALIVE is kept as "off" for the report.
  ANGIE_PHP_KEEPALIVE="off"
}
PHP_WRITTEN_CHILDREN=0

# gzip level from the same CPU rule as Brotli (5, 4 on 1-2 CPUs);
# SETUP_GZIP_LEVEL=1..9 pins it.
angie_gzip_level() {
  local level=${SETUP_GZIP_LEVEL:-}
  if ! [[ $level =~ ^[1-9]$ ]]; then
    level=5
    (( $(effective_cpus) <= 2 )) && level=4
  fi
  printf '%s' "$level"
}

# open_file_cache max for a host: RAM-proportional (8 entries per MB,
# 10000..200000) but never more than the descriptors a worker keeps after its
# connections, since every cached entry is an open fd.  Shared by the tuner
# and the dry run.  Arguments: RAM MB, worker_rlimit_nofile, worker_connections.
angie_open_file_cache_max() {
  local mem_mb=$1 rlimit=$2 conns=$3 open_files fd_room
  open_files=$(tune_clamp $(( mem_mb * 8 )) 10000 200000)
  fd_room=$(( rlimit - conns - 1024 ))
  (( fd_room < 1000 )) && fd_room=1000
  (( open_files > fd_room )) && open_files=$fd_room
  printf '%s' "$open_files"
}
ANGIE_WORKER_PROCESSES=""
ANGIE_WORKER_RLIMIT=""
ANGIE_WORKER_CONNECTIONS=""
ANGIE_PHP_KEEPALIVE=""

# Free disk under the web root (fallback /) in MB, for the cache budget.
angie_disk_free_mb() {
  local mb
  mb=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $mb =~ ^[0-9]+$ ]] || mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $mb =~ ^[0-9]+$ ]] || mb=10240
  printf '%s' "$mb"
}

# Record (or clear) the explicit operator sizes of this run before the memory
# plan is built, so the plan reserves them and a later --optimize keeps them.
# The installers used to write these after tuning, which left the first
# install's plan blind to --php children=, --mariadb size=, --valkey ram= and
# --elastic ram= and made the next --optimize re-split RAM.
record_explicit_options() {
  local v mb
  # --basic server=dedi|vps is an operator decision about the host class;
  # without it a later --optimize would re-detect and silently switch every
  # dedi/vps formula (workers per core, backlogs, io_capacity, governor).
  if [[ ${ENABLED[basic]:-0} -eq 1 ]]; then
    case ${OPT[basic.server]:-} in
      dedi|vps) explicit_option_set server_type "${OPT[basic.server]}" ;;
      *) explicit_option_unset server_type ;;
    esac
  fi
  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    v=${OPT[php.children]:-}
    if [[ -n $v && $v != auto ]]; then explicit_option_set php_children "$v"; else explicit_option_unset php_children; fi
    v=${OPT[php.max_requests]:-}
    if [[ -n $v ]]; then explicit_option_set php_max_requests "$v"; else explicit_option_unset php_max_requests; fi
  fi
  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then
    v=${OPT[mariadb.size]:-auto}
    if [[ ${v,,} != auto ]] && mb=$(size_to_mb "$v") && [[ -n $mb ]]; then
      explicit_option_set mariadb_size_mb "$mb"
    else
      explicit_option_unset mariadb_size_mb
    fi
  fi
  if [[ ${ENABLED[valkey]:-0} -eq 1 ]]; then
    v=${OPT[valkey.ram]:-auto}
    if [[ ${v,,} != auto ]] && mb=$(size_to_mb "$v") && [[ -n $mb ]]; then
      explicit_option_set valkey_mb "$mb"
    else
      explicit_option_unset valkey_mb
    fi
  fi
  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    v=${OPT[elastic.ram]:-auto}
    if [[ ${v,,} != auto ]] && mb=$(size_to_mb "$v") && [[ -n $mb ]]; then
      explicit_option_set elastic_mb "$mb"
    else
      explicit_option_unset elastic_mb
    fi
  fi
}

# Planned memory for a data service, or the stand-alone fallback when no plan
# exists (a direct helper call or a unit test).  One owner for the fallback
# formulas so a fresh install and --optimize cannot disagree.
service_mem_mb() {
  local svc=$1 mb ram
  ram=$(mem_total_mb)
  case $svc in
    mariadb)
      mb=${OPT_MARIADB_BUDGET_MB:-0}
      if (( mb <= 0 )); then mb=$(( ram * 40 / 100 )); (( mb < 256 )) && mb=256; fi ;;
    valkey|redis)
      mb=${OPT_VALKEY_BUDGET_MB:-0}
      if (( mb <= 0 )); then mb=$(( ram / 10 )); (( mb < 256 )) && mb=256; (( mb > 8192 )) && mb=8192; fi ;;
    elastic)
      # The plan already normalises its value to a 512 MB step and may keep
      # an operator heap unrounded; never round it again here.
      mb=${OPT_ES_BUDGET_MB:-0}
      if (( mb <= 0 )); then
        mb=$(( ram * 25 / 100 )); (( mb > 31744 )) && mb=31744
        mb=$(( mb / 512 * 512 )); (( mb < 512 )) && mb=512
      fi ;;
    *) return 1 ;;
  esac
  printf '%s' "$mb"
}

# Build the same shared memory plan for a fresh install that --optimize builds
# for an existing host.  Services that are about to be installed are treated as
# present so PHP/MariaDB/Valkey/Elasticsearch are sized against one budget from
# the first write instead of each claiming its own percentage of RAM.
plan_install_budget() {
  # Start from what is already on the host, then add this run's services: a
  # later `--php --mariadb` on an Angie host must size the Angie cache and
  # the data tier exactly like the next --optimize will.
  detect_installed_services
  [[ ${ENABLED[angie]:-0} -eq 1   && " ${OPT_DETECTED[*]} " != *" angie "*   ]] && OPT_DETECTED+=(angie)
  [[ ${ENABLED[php]:-0} -eq 1     && " ${OPT_DETECTED[*]} " != *" php:"*     ]] && OPT_DETECTED+=("php:${OPT[php.ver]:-auto}")
  [[ ${ENABLED[mariadb]:-0} -eq 1 && " ${OPT_DETECTED[*]} " != *" mariadb "* ]] && OPT_DETECTED+=(mariadb)
  [[ ${ENABLED[valkey]:-0} -eq 1  && " ${OPT_DETECTED[*]} " != *" valkey "*  ]] && OPT_DETECTED+=(valkey)
  [[ ${ENABLED[elastic]:-0} -eq 1 && " ${OPT_DETECTED[*]} " != *" elastic "* ]] && OPT_DETECTED+=(elastic)
  # The services do not exist yet, so their size probes cannot return data.
  # Let the planner use the empty-data floors instead of the unmeasured
  # fallbacks; a re-run on an installed host still uses the measured values.
  OPT_INSTALL_PLAN=1
  plan_memory_budget
  OPT_INSTALL_PLAN=0
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

# Value of the first active `key = value` line in an ini-style file (pool,
# php.ini), trimmed; nothing when absent.  One reader for every pool/ini
# directive the tuners inspect.
ini_get() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  awk -F= -v key="$key" '
    index($0, key) && $1 ~ ("^[[:space:]]*" key "[[:space:]]*$") {
      v = $2; sub(/^[^=]*=/, "", $0); v = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit
    }' "$file"
}

php_pool_listen() {
  local ver=$1 pool="/etc/php/${1}/fpm/pool.d/www.conf"
  ini_get "$pool" listen
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

# Per-worker memory allowance used to size the PHP-FPM pool and to reserve
# RAM for it in the shared plan.  A fixed 96 MB is safe for an unknown
# application, but real workers are commonly 20-50 MB; reserving 96 MB each
# leaves several GB that MariaDB and Elasticsearch could use.  When a pool is
# already running, measure it (1.5x the average RSS) clamped to a conservative
# 64-192 MB range.  A fresh install has no pool to measure and plans at the
# 64 MB floor (plan_memory_budget), which is what an idle new pool measures.
php_worker_allowance_mb() {
  local ver=${1:-} out avg=0 n=0 allowance=96
  if [[ -n $ver ]]; then
    out=$(ps -o rss= -C "php-fpm${ver}" 2>/dev/null || true)
  fi
  [[ -n ${out:-} ]] || out=$(ps -o rss= -C php-fpm 2>/dev/null || true)
  if [[ -n ${out:-} ]]; then
    read -r avg n < <(printf '%s\n' "$out" | awk '
      { sum += $1; n++ }
      END { if (n) printf "%d %d\n", int(sum / n / 1024), n }
    ') || true
  fi
  # One process is just the master; it says nothing about worker memory.
  if [[ ${n:-0} =~ ^[0-9]+$ ]] && (( n >= 2 && avg > 0 )); then
    # Average RSS already includes shared pages (OPcache, libraries) that are
    # counted once per worker in a naive sum.  1.5x the average leaves room
    # for a heavier request without turning a transient peak into a permanent
    # multi-GB reservation.
    allowance=$(( avg * 3 / 2 ))
    (( allowance < 64 )) && allowance=64
    (( allowance > 192 )) && allowance=192
  fi
  printf '%s\n' "$allowance"
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
    root=$(angie_vhost_root "$file")
    [[ -n $root && -f "${root}/wp-config.php" ]] && printf '%s\n' "$file"
  done
}

# A XenForo vhost includes h5bp/php_xf.conf (the PHP/cache snippet) or the
# xf2.conf location set, and its document root contains src/XF.php.
angie_xenforo_vhosts() {
  local target=$1 file root
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*include[[:space:]]+h5bp/(php_xf|xf2)\.conf;' "$file" || continue
    root=$(angie_vhost_root "$file")
    [[ -n $root && -f "${root}/src/XF.php" ]] && printf '%s\n' "$file"
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

# Install the shared FastCGI cache zone (and its $nocacheuri map) when no
# active http.d file defines fastcgicache.  WordPress and XenForo both use
# it; a single owner avoids a second, inert cache_path.
ensure_fastcgi_cache_zone() {
  local target=${1:-/etc/angie} suffix file active_zone=0 src="" temp=""
  suffix=$(angie_http_suffix "$target")
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    grep -qE 'fastcgi_cache_path.*keys_zone=fastcgicache:' "$file" && active_zone=1
  done < <(angie_active_http_files "$target")
  (( active_zone )) && return 0

  install -d -m 700 /home/nginx_cache 2>/dev/null || mkdir -p /home/nginx_cache
  chown www-data:www-data /home/nginx_cache 2>/dev/null || true

  if [[ -n ${CONFIG_SOURCE_DIR:-} \
        && -f ${CONFIG_SOURCE_DIR}/http.d/fastcgi_cache.conf ]]; then
    src=$CONFIG_SOURCE_DIR
  else
    temp=$(wordpress_cache_templates) || {
      tune_miss "FastCGI cache: no local template and the repository download failed"
      return 1
    }
    src=$temp
  fi
  install -m 644 "${src}/http.d/fastcgi_cache.conf" \
    "${target}/http.d/zz-setup-fastcgi-cache${suffix}" || return 1
  tune_note "FastCGI cache: zone and no-cache map installed"
  return 0
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

  # Decide per vhost.  The template carries `include h5bp/wordpress_cache.conf;`
  # in the server block and tells the operator to remove it for a site that
  # personalises guest pages; a vhost without it is an opt-out, never silently
  # re-enabled through the shared php_wp.conf (which every WordPress vhost
  # includes).  SETUP_WP_GUEST_CACHE=1 adds the include to such vhosts.
  local -a wp_enabled=() wp_optout=()
  local shared_include=0 vhost
  if (( has_php_wp )) \
     && grep -qE '^[[:space:]]*include[[:space:]]+h5bp/wordpress_cache\.conf;' "${target}/h5bp/php_wp.conf"; then
    shared_include=1
  fi
  for vhost in "${wp_vhosts[@]}"; do
    if (( shared_include )) \
       || grep -qE '^[[:space:]]*include[[:space:]]+h5bp/wordpress_cache\.conf;' "$vhost"; then
      wp_enabled+=("$vhost")
    else
      wp_optout+=("$vhost")
    fi
  done
  local include_ready=0
  (( ${#wp_enabled[@]} > 0 )) && include_ready=1

  if (( active_zone && active_map && include_ready )) \
     && [[ -f "${target}/h5bp/wordpress_cache.conf" ]] \
     && { (( ${#wp_optout[@]} == 0 )) || [[ ${SETUP_WP_GUEST_CACHE:-0} != 1 ]]; }; then
    opt_report "- WordPress: FastCGI guest cache already enabled for ${#wp_enabled[@]} vhost(s)"
    for vhost in "${wp_optout[@]}"; do
      opt_report "- WordPress: \`${vhost#"${target}"/}\` has no wordpress_cache include (operator opt-out; SETUP_WP_GUEST_CACHE=1 adds it)"
    done
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

  local map_file="${target}/http.d/zz-setup-wordpress-cache-map${suffix}"
  if (( active_zone == 0 )); then
    if ensure_fastcgi_cache_zone "$target"; then
      changed=1
    fi
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
  # Per-vhost include, only on request: inserted in the server block right
  # before the php_wp include so the cache directives precede the PHP
  # location, exactly where the template puts them.
  if [[ ${SETUP_WP_GUEST_CACHE:-0} == 1 ]]; then
    for vhost in "${wp_optout[@]}"; do
      if tune_insert_before "$vhost" '^[[:space:]]*include[[:space:]]+h5bp/php_wp\.conf;' \
           '    include h5bp/wordpress_cache.conf; # added by setup.sh (SETUP_WP_GUEST_CACHE=1)' \
           "${vhost#"${target}"/}: wordpress_cache include added"; then
        wp_enabled+=("$vhost")
        changed=1
      fi
    done
    wp_optout=()
  fi

  if (( changed )); then
    tune_note "WordPress: FastCGI guest cache enabled for ${#wp_enabled[@]} vhost(s)"
  else
    opt_report "- WordPress: FastCGI guest cache already enabled for ${#wp_enabled[@]} vhost(s)"
  fi
  for vhost in "${wp_optout[@]}"; do
    opt_report "- WordPress: \`${vhost#"${target}"/}\` has no wordpress_cache include (operator opt-out; SETUP_WP_GUEST_CACHE=1 adds it)"
  done
  return 0
}

# Insert LINE before the first line matching PATTERN (ERE) in FILE; no-op
# when the file has no match or LINE is already present.  Returns 0 only
# when the file changed.
tune_insert_before() {
  local file=$1 pattern=$2 line=$3 note=$4 n tmp
  [[ -f $file ]] || return 1
  grep -qF -- "${line%% #*}" "$file" && return 1
  n=$(grep -nE -- "$pattern" "$file" | head -n1 | cut -d: -f1 || true)
  [[ -n $n ]] || return 1
  tmp=$(tmp_file) || return 1
  {
    head -n "$(( n - 1 ))" "$file"
    printf '%s\n' "$line"
    tail -n "+${n}" "$file"
  } > "$tmp"
  cat -- "$tmp" > "$file"
  tune_note "$note"
  return 0
}

# The cache status add_header inside php_xf.conf / php_xf_proxy.conf replaces
# the server-level add_header set from basic_xf.conf, so PHP responses lost
# HSTS and Referrer-Policy (measured on a fresh vhost).  Re-include the same
# snippets inside the location when the server block carries them.
tune_xf_location_security_headers() {
  local target=$1 file=$2 snippet pattern
  [[ -f $file ]] || return 0
  grep -qE '^[[:space:]]*add_header[[:space:]]' "$file" || return 0
  for snippet in security/strict-transport-security.conf security/referrer-policy.conf; do
    [[ -f "${target}/h5bp/${snippet}" ]] || continue
    grep -qE "^[[:space:]]*include[[:space:]]+h5bp/${snippet//./\\.};" "${target}/h5bp/basic_xf.conf" 2>/dev/null || continue
    pattern="^[[:space:]]*include[[:space:]]+h5bp/${snippet//./\\.};"
    tune_ensure_in_location "$file" "$pattern" "include h5bp/${snippet};" \
      "$(basename "$file"): ${snippet##*/} kept on PHP responses"
  done
  return 0
}

# XenForo guest cache cookie bypass is decided in a map, never with `if`.
# `map` lives in the http context; the result is consumed by
# fastcgi_no_cache/fastcgi_cache_bypass.  Keeping it in its own managed file
# lets --optimize repair old hosts without editing the repository template.
ensure_xf_cookie_bypass_map() {
  local target=${1:-/etc/angie} suffix file
  suffix=$(angie_http_suffix "$target")
  file="${target}/http.d/zz-setup-fastcgi-cache-map${suffix}"
  if [[ ! -f $file ]] || ! grep -qE 'map[[:space:]]+\$http_cookie[[:space:]]+\$setup_xf_guest_bypass' "$file" \
     || ! grep -qE 'map[[:space:]]+\$http_accept_encoding[[:space:]]+\$setup_cache_enc' "$file"; then
    cat > "$file" <<'EOF'
# BEGIN setup.sh XenForo cookie bypass map
# Authenticated/session cookies bypass the guest cache.  This is a map (http
# context) so no `if` is needed inside a location block in Angie.
map $http_cookie $setup_xf_guest_bypass {
    default 0;
    ~*xf_session=       1;
    ~*xf_session_admin= 1;
    ~*xf_user=          1;
    ~*xf_tfa_trust=     1;
}
# XenForo gzips its own output when the client accepts gzip.  The cache key
# must vary on that, otherwise the first visitor's encoding is served to
# everyone for the TTL: an identity body is then Brotli-compressed by Angie on
# every hit (measured 42% of 16 cores at 8k req/s), and a gzip body would
# reach a client that did not ask for it.  Two variants only: gzip or plain.
map $http_accept_encoding $setup_cache_enc {
    default "";
    ~*gzip  gzip;
}
# END setup.sh XenForo cookie bypass map
EOF
    chmod 644 "$file"
    tune_note "XenForo: cookie bypass map installed (${file##*/})"
  fi
  if ! angie_active_http_files "$target" | grep -qx "$file"; then
    tune_miss "XenForo cache: ${file} is not included by angie.conf"
    return 1
  fi
  return 0
}

# Replace the old direct-cookie bypass with the map variable.  The URI map
# ($nocacheuri) remains from the shared fastcgi_cache.conf.
tune_xf_cache_bypass_var() {
  local file=$1 tmp before
  [[ -f $file ]] || return 0
  before=$(md5sum "$file" | awk '{print $1}')
  tmp=$(tmp_file) || return 1
  awk '
    /^[[:space:]]*fastcgi_no_cache[[:space:]]/ {
      print "fastcgi_no_cache $setup_xf_guest_bypass $nocacheuri;"
      next
    }
    /^[[:space:]]*fastcgi_cache_bypass[[:space:]]/ {
      print "fastcgi_cache_bypass $setup_xf_guest_bypass $nocacheuri;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
    tune_note "XenForo: cookie bypass moved to a map"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# XenForo guest cache
# ---------------------------------------------------------------------------
# Fresh app=xf vhosts include h5bp/php_xf.conf, which ships the FastCGI cache
# block.  Older or hand-written hosts may lack the block or one of its
# directives, so --optimize repairs the include in place: zone/map, cache key
# varied on style and language, session-cookie bypass, lock/background update,
# error-response policy and the 5-minute TTL.  Idempotent; a file that already
# has the full block only receives the key/background-update repairs.
ensure_xf_guest_cache() {
  local target=${1:-/etc/angie}
  local -a xf_vhosts=()
  mapfile -t xf_vhosts < <(angie_xenforo_vhosts "$target")
  (( ${#xf_vhosts[@]} > 0 )) || return 0

  local file="${target}/h5bp/php_xf.conf"
  if [[ ! -f $file ]]; then
    tune_miss "XenForo cache: h5bp/php_xf.conf is missing (${#xf_vhosts[@]} vhost(s) cannot be cached)"
    return 0
  fi
  if ! ensure_xf_cookie_bypass_map "$target"; then
    tune_miss "XenForo cache: cookie bypass map unavailable; leaving the include unchanged"
    return 0
  fi
  ensure_fastcgi_cache_zone "$target" || true
  local changes_before=${#TUNE_CHANGES[@]}
  # The proxy include (css.php, proxy.php, sitemap.php) is repaired on both
  # paths below; php_xf.conf gets its headers with the injected block or
  # from the repair at the end.
  tune_xf_location_security_headers "$target" "${target}/h5bp/php_xf_proxy.conf"

  local lock='$setup_xf_guest_bypass $nocacheuri'
  # One source of truth for the guest-cache block: "match-pattern<TAB>line".
  # A fresh include gets the whole block injected; an existing one is
  # repaired line by line from the same list, so the two paths cannot drift
  # (the repair list used to lack the 301/302/any TTLs, the status header and
  # background_update, and wrote a shorter cache key).
  local -a directives=(
    $'fastcgi_cache_methods[[:space:]]\tfastcgi_cache_methods GET HEAD;'
    $'fastcgi_cache_key[[:space:]]\tfastcgi_cache_key "$request_method$scheme$host$request_uri$cookie_xf_style_variation$cookie_xf_style_id$cookie_xf_language_id$setup_cache_enc";'
    $'fastcgi_cache_lock[[:space:]]+on;\tfastcgi_cache_lock on;'
    $'fastcgi_cache_background_update[[:space:]]\tfastcgi_cache_background_update on;'
    $'fastcgi_cache_use_stale[[:space:]]\tfastcgi_cache_use_stale error timeout invalid_header updating http_503;'
    $'fastcgi_ignore_headers[[:space:]]\tfastcgi_ignore_headers Cache-Control Expires Set-Cookie;'
    $'fastcgi_cache[[:space:]]+fastcgicache;\tfastcgi_cache fastcgicache;'
    "fastcgi_no_cache[[:space:]]"$'\t'"fastcgi_no_cache ${lock};"
    "fastcgi_cache_bypass[[:space:]]"$'\t'"fastcgi_cache_bypass ${lock};"
    $'fastcgi_cache_valid[[:space:]]+200[[:space:]]\tfastcgi_cache_valid 200 5m;'
    $'fastcgi_cache_valid[[:space:]]+302[[:space:]]\tfastcgi_cache_valid 302 1h;'
    $'fastcgi_cache_valid[[:space:]]+301[[:space:]]\tfastcgi_cache_valid 301 404 24h;'
    $'fastcgi_cache_valid[[:space:]]+any[[:space:]]\tfastcgi_cache_valid any 5s;'
    $'fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;\tfastcgi_cache_valid 500 502 503 504 0s;'
    $'add_header[[:space:]]+X-5m-Cache[[:space:]]\tadd_header X-5m-Cache $upstream_cache_status always;'
  )
  local entry pattern line
  if ! grep -qE '^[[:space:]]*fastcgi_cache[[:space:]]+fastcgicache;' "$file"; then
    # The block belongs inside the include's `location ~ \.php`; appended
    # after its closing brace it would land in the server context and also
    # cache the admin/login locations that include plain php.conf.
    local block last tmp
    block=$'\n# BEGIN setup.sh XenForo guest cache\n'
    for entry in "${directives[@]}"; do
      block+="${entry#*$'\t'}"$'\n'
    done
    block+=$'# add_header in a location drops the server-level security headers.\n'
    block+=$'include h5bp/security/strict-transport-security.conf;\n'
    block+=$'include h5bp/security/referrer-policy.conf;\n'
    block+='# END setup.sh XenForo guest cache'
    last=$(grep -nE '^[[:space:]]*\}[[:space:]]*$' "$file" | tail -n1 | cut -d: -f1 || true)
    if [[ -n $last ]]; then
      # head/tail rather than awk -v: mawk and BSD awk reject newlines in -v.
      tmp=$(tmp_file) || return 1
      {
        head -n "$(( last - 1 ))" "$file"
        printf '%s\n' "$block"
        tail -n "+${last}" "$file"
      } > "$tmp"
      cat -- "$tmp" > "$file"
    else
      printf '%s\n' "$block" >> "$file"
    fi
    tune_note "XenForo: FastCGI guest cache enabled for ${#xf_vhosts[@]} vhost(s)"
    return 0
  fi

  for entry in "${directives[@]}"; do
    pattern=${entry%%$'\t'*}
    line=${entry#*$'\t'}
    tune_ensure_in_location "$file" "^[[:space:]]*${pattern}" "$line" \
      "XenForo: ${line%% *} added to the guest cache"
  done
  tune_xf_cache_bypass_var "$file"
  # Run the key/background repair last: it needs the lock line above to exist
  # before it can decide whether background_update is missing.
  tune_xf_cache_vary "$file"
  tune_xf_location_security_headers "$target" "$file"
  if (( ${#TUNE_CHANGES[@]} == changes_before )); then
    opt_report "- XenForo: FastCGI guest cache already enabled for ${#xf_vhosts[@]} vhost(s)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# WordPress / XenForo connection audit
# ---------------------------------------------------------------------------
# --optimize reports, but never edits, application config.  The admin owns
# wp-config.php and XenForo's src/config.php, so the report gives the exact
# settings needed for persistent MariaDB connections and the local Valkey
# socket.
app_cache_socket_hint() {
  if [[ -f /etc/valkey/valkey.conf || -S /run/valkey/valkey.sock ]]; then
    printf '/run/valkey/valkey.sock'
  elif [[ -f /etc/redis/redis.conf || -S /run/redis/redis.sock ]]; then
    printf '/run/redis/redis.sock'
  else
    printf '/run/valkey/valkey.sock'
  fi
}

app_is_socket_path() {
  case "$1" in
    */valkey.sock|*/redis.sock|unix://*) return 0 ;;
    *) return 1 ;;
  esac
}

wp_db_host_from_config() {
  sed -nE "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]DB_HOST['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

wp_redis_path_from_config() {
  sed -nE "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_PATH['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

wp_redis_host_from_config() {
  sed -nE "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_HOST['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

wp_redis_persistent_from_config() {
  grep -qE "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]WP_REDIS_PERSISTENT['\"][[:space:]]*,[[:space:]]*(true|TRUE|True|1)[[:space:]]*\)" "$1" 2>/dev/null
}

xf_db_host_from_config() {
  sed -nE "s/^[[:space:]]*\\\$config\[['\"]db['\"]\]\[['\"]host['\"]\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

xf_cache_host_from_config() {
  sed -nE "s/^[[:space:]]*\\\$config\[['\"]cache['\"]\]\[['\"]config['\"]\]\[['\"]host['\"]\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

xf_cache_port_from_config() {
  sed -nE "s/^[[:space:]]*\\\$config\[['\"]cache['\"]\]\[['\"]config['\"]\]\[['\"]port['\"]\][[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

# Same depth as the managed wp-cron entry and the XenForo finder, so a site
# that is hardened here is also the site whose wp-cron.php the cron runs.
app_find_wordpress_configs() {
  find /var/www -maxdepth 6 -type f -name wp-config.php 2>/dev/null | sort -u || true
}

app_find_xenforo_configs() {
  local conf
  while IFS= read -r conf; do
    if [[ -f "${conf%/config.php}/XF.php" ]]; then
      printf '%s\n' "$conf"
    fi
  done < <(find /var/www -maxdepth 6 -type f -path '*/src/config.php' 2>/dev/null | sort -u || true)
}

