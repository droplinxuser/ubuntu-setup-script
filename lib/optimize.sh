# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
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
  # The server binary, not the client: a web node with mariadb-client and a
  # remote database is not a local MariaDB host (it was planned a buffer pool,
  # 1.0 PHP workers per core and a systemd drop-in for a unit it lacks).
  if command -v mariadbd >/dev/null 2>&1; then
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
# Why the plan chose the cache size (valkey_guard_maxmemory_mb): plan, live,
# full, raised, capped or explicit.  Read by the report and the dry run.
OPT_VALKEY_GUARD=""
OPT_ES_BUDGET_MB=0
OPT_ES_KEPT_MB=0
# Memory booked inside OPT_MEM_BUDGET_MB that no service setting names.
# OPT_ES_DIRECT_MB: the Elasticsearch direct (off-heap) ceiling, an operator
# -XX:MaxDirectMemorySize or the JVM's own heap/2; OPT_ES_DIRECT_BOOKED_MB:
# the part of it booked in the budget (less than the ceiling only below
# 4 GB, where part sits in the OS headroom); OPT_HUGEPAGES_MB: the OPcache
# huge-page reservation.
OPT_ES_DIRECT_MB=0
OPT_ES_DIRECT_BOOKED_MB=0
OPT_ES_DIRECT_OPERATOR=0
# OPT_ES_CACHE_MB: index store kept in the page cache; OPT_ES_CACHE_FREE_MB:
# RAM left for it after the booked services and the OS floor;
# OPT_ES_PRELOAD=1 when it fits (index.store.preload: ["*"]).
OPT_ES_CACHE_MB=0
OPT_ES_CACHE_FREE_MB=0
OPT_ES_PRELOAD=0

# Preload decision with hysteresis: STORE MB of index, FREE MB of RAM left,
# ON=1 when the managed block preloads already.  Switching on needs 10%
# growth room; staying on only needs the index itself to fit.
es_direct_credit_used_mb() {
  # The part of the sub-4 GB direct-memory credit the ceiling really uses:
  # direct (operator value, else heap/2) minus what is booked, within the
  # credit.  Arguments: heap op_direct booked credit.
  local heap=$1 op=$2 booked=$3 credit=$4 dir used
  if (( op > 0 )); then dir=$op; else dir=$(( (heap + 1) / 2 )); fi
  used=$(( dir - booked ))
  (( used < 0 )) && used=0
  (( used > credit )) && used=$credit
  printf '%s' "$used"
}

es_preload_fits() {
  local store=$1 free=$2 on=${3:-0}
  (( store > 0 )) || return 1
  if (( on )); then
    (( store <= free ))
  else
    (( store + store / 10 <= free ))
  fi
}
OPT_HUGEPAGES_MB=0
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
# shellcheck disable=SC2120  # default argument; callers may pass a path
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

# Current JVM heap in MB.  Prefer the live node stats, then the last -Xmx
# from jvm.options and its drop-ins (the JVM applies them in that order, so
# the managed zz-setup-optimize.options wins).  The planner may still shrink
# a heap that is grossly above the store-derived target.
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
  done
  [[ -n ${mb:-} ]] && printf '%s' "$mb"
  return 0
}

# Major version of the JDK bundled with Elasticsearch (21 when unknown: every
# supported 8.x/9.x release bundles 21 or newer).
elasticsearch_jdk_major() {
  local v
  v=$(sed -nE 's/^JAVA_VERSION="?([0-9]+).*/\1/p' "${1:-/usr/share/elasticsearch/jdk/release}" 2>/dev/null | head -n1 || true)
  [[ $v =~ ^[0-9]+$ ]] || v=21
  printf '%s' "$((10#$v))"
}

# An operator's -XX:MaxDirectMemorySize in MB, or nothing.  Reads the main
# jvm.options, then the jvm.options.d drop-ins, in the order the JVM applies
# them (the last active line wins).  The stock jvm.options never sets the
# flag, so a fresh install (no file yet) and the next --optimize read the
# same nothing.  zz-setup-optimize.options is ours and never sets it.  A JDK
# version prefix ("17:", "17-:", "9-16:") is honoured against the bundled
# JDK, as the JVM options parser does; commented lines are ignored.  Sizes
# are decimal (HotSpot reads "08m" as 8 MB), so bash never sees an octal.
elasticsearch_operator_direct_mb() {
  local dir=${1:-/etc/elasticsearch/jvm.options.d} main=${2:-/etc/elasticsearch/jvm.options}
  local jdk=${3:-} file line pre num unit lo hi mb=""
  [[ -n $jdk ]] || jdk=$(elasticsearch_jdk_major)
  for file in "$main" "$dir"/*.options; do
    [[ -f $file ]] || continue
    [[ ${file##*/} == zz-setup-optimize.options ]] && continue
    while IFS= read -r line; do
      [[ $line =~ ^(([0-9]+)(-([0-9]*))?:)?-XX:MaxDirectMemorySize=([0-9]+)([kKmMgG]?)[[:space:]]*$ ]] || continue
      pre=${BASH_REMATCH[1]}; num=$((10#${BASH_REMATCH[5]})); unit=${BASH_REMATCH[6]}
      if [[ -n $pre ]]; then
        lo=$((10#${BASH_REMATCH[2]}))
        if [[ -z ${BASH_REMATCH[3]} ]]; then hi=$lo          # "N:"   exactly N
        elif [[ -z ${BASH_REMATCH[4]} ]]; then hi=999        # "N-:"  N or newer
        else hi=$((10#${BASH_REMATCH[4]})); fi               # "N-M:" N..M
        (( jdk >= lo && jdk <= hi )) || continue
      fi
      case $unit in
        k|K) mb=$(( (num + 1023) / 1024 )) ;;
        m|M) mb=$num ;;
        g|G) mb=$(( num * 1024 )) ;;
        *)   mb=$(( (num + 1048575) / 1048576 )) ;;
      esac
    done < <(cat "$file"; [[ -z $(tail -c1 "$file") ]] || echo)
  done
  [[ -n $mb ]] && printf '%s' "$mb"
  return 0
}

# Direct memory booked for a heap: the operator value, or the JVM ergonomic
# heap/2 rounded up (an odd 913 MB heap gets 457, never 456), minus the OS
# headroom credit (non-zero only below 4 GB), never below 0.
es_direct_booked_mb() {
  local heap=${1:-0} op=${2:-0} credit=${3:-0} d
  [[ $op =~ ^[0-9]+$ ]] || op=0
  if (( op > 0 )); then d=$op; else d=$(( (heap + 1) / 2 )); fi
  d=$(( d - credit )); (( d < 0 )) && d=0
  printf '%s' "$d"
}

plan_memory_budget() {
  local total usable
  local has_php=0 has_maria=0 has_cache=0 has_es=0
  # A fresh install has no pool to measure.  It plans at the 64 MB floor that
  # php_worker_allowance_mb measures for a freshly started, idle pool, so the
  # first --optimize after the install reserves the same PHP budget.
  local cpu=1 allowance=64 php_capacity=0 php_floor=0 php_budget=0 children=0 php_explicit_children=0
  local maria_target=0 valkey_target=0 es_target=0
  local maria_alloc=0 valkey_alloc=0 es_alloc=0
  local maria_fixed=0 valkey_fixed=0 es_fixed=0
  local data="" current_pool=0 kept_pool=0
  local cache_used="" cache_current=0 cache_evicts=1 cache_cap=0 cache_plan=""
  local es_store="" es_kept=0 current_heap=0
  local remaining data_pool targets_sum alloc_total excess dec
  local explicit=""
  local hp_mb=0 svc_usable=0 es_credit=0 es_op_direct=0 es_book=0
  local es_book_target=0 es_fp_target=0 maria_plan_target=0 over=0 booked=0

  total=$(mem_total_mb)
  (( total > 0 )) || total=1024
  OPT_MEM_TOTAL_MB=$total
  usable=$(( total * 80 / 100 ))
  OPT_MEM_BUDGET_MB=$usable
  OPT_ES_DIRECT_MB=0
  OPT_ES_DIRECT_BOOKED_MB=0
  OPT_ES_DIRECT_OPERATOR=0
  OPT_HUGEPAGES_MB=0
  # Memory pinned outside every service setting.  OPcache huge pages are
  # reserved at boot inside MemTotal, never swapped and not in worker RSS,
  # so they come off the services' share; OPT_MEM_BUDGET_MB, the cache cap
  # and the only-increase rules keep the plain 80% figure.
  hp_mb=$(hugepages_reserved_mb "$total")
  [[ $hp_mb =~ ^[0-9]+$ ]] || hp_mb=0
  OPT_HUGEPAGES_MB=$hp_mb
  svc_usable=$(( usable - hp_mb ))
  (( svc_usable < 0 )) && svc_usable=0
  # Below 4 GB (no huge pages) the Elasticsearch direct ceiling first uses
  # the headroom above a 10% OS floor.  It is a ceiling that a small forum
  # index rarely touches, and booking all of it cut a 2 GB all-in-one's
  # buffer pool by 256 MB.  At 4 GB and above it is booked in full.
  if (( total < 4096 )); then
    es_credit=$(( total - usable - total / 10 ))
    (( es_credit < 0 )) && es_credit=0
  fi
  OPT_PHP_BUDGET_MB=0
  OPT_PHP_CHILDREN=0
  OPT_MARIADB_BUDGET_MB=0
  OPT_MARIADB_KEPT_MB=0
  OPT_VALKEY_BUDGET_MB=0
  OPT_VALKEY_LIVE_MB=0
  OPT_VALKEY_GUARD=""
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
    local php_floor_children
    explicit=$(explicit_option php_children 2>/dev/null || true)
    php_capacity=$(php_children_ceiling "$cpu" "$total" "$live_children" "$explicit")
    php_floor_children=$(php_children_floor "$total" "$cpu")
    # The pool writer always writes an explicit --php children= count; the
    # Elasticsearch page-cache step below must neither shrink it on paper
    # nor count a smaller pool.
    php_explicit_children=0
    [[ $explicit =~ ^[0-9]+$ ]] && (( explicit > 0 )) && php_explicit_children=$explicit
    # An explicit --php children= below the hardware target lowers the floor
    # too; otherwise the plan lifts the pool straight back to the target.
    if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit > 0 && php_capacity < php_floor_children )); then
      php_floor_children=$php_capacity
    fi
    php_floor=$(( php_floor_children * allowance ))
    (( php_floor < 256 )) && php_floor=256
    (( php_floor > svc_usable / 2 )) && php_floor=$(( svc_usable / 2 ))
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
      # A live database is sized from its own data: the current data+index
      # size plus 5% for growth.  The buffer pool is the database's page
      # cache, and a pool smaller than the working set turns random reads
      # into disk I/O; measured on this host with a 935 MB table, a 128 MB
      # pool answered 71 k point queries/s with 92% physical reads, while a
      # pool larger than the table answered 212 k/s with none.  A
      # database-only host may use up to 80% of total RAM (the same ceiling
      # as the shared budget); a host that also runs PHP, Valkey or
      # Elasticsearch caps the pool at half of RAM so those tiers and the
      # page cache keep room.  The scaling below trims it proportionally when
      # the targets do not fit.  A fresh install has no data at all, so it
      # keeps the RAM-proportional operational floor; an existing but empty
      # database gets the 128 MB operational minimum, and the only-increase
      # rule below protects a larger live pool.
      if (( data > 0 )); then
        maria_target=$(( data + data / 20 ))
        local pool_cap
        if (( ! has_php && ! has_cache && ! has_es )); then
          pool_cap=$(( total * 80 / 100 ))
        else
          pool_cap=$(( total / 2 ))
        fi
        (( pool_cap < 256 )) && pool_cap=256
        (( maria_target > pool_cap )) && maria_target=$pool_cap
        (( maria_target < 128 )) && maria_target=128
      elif (( OPT_INSTALL_PLAN )); then
        maria_target=$(mariadb_floor_mb "$total")
      else
        maria_target=128
      fi
    fi
    # The data/floor target before the only-increase rule (kept-pool trim).
    maria_plan_target=$maria_target
    current_pool=$(mariadb_current_pool_mb)
    if [[ $current_pool =~ ^[0-9]+$ ]] && (( current_pool > 0 )); then
      # Only increase: a pool that is already above the target is kept as it
      # is.  Lowering it would restart the server and empty the buffer pool it
      # has spent hours warming, for no memory the run needs.
      if (( current_pool > maria_target )); then
        maria_target=$current_pool
        kept_pool=$current_pool
      fi
    fi
  fi

  # Valkey target: the RAM-proportional floor, or live used_memory plus 20%
  # headroom when the data already stored needs more.  A cache that merely
  # fills its current maxmemory keeps that size (valkey_guard_maxmemory_mb).
  if (( has_cache )); then
    explicit=$(explicit_option valkey_mb 2>/dev/null || true)
    if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit >= 1 )); then
      # An explicit --valkey ram= is the operator's decision: the live-data
      # guard never changes it.
      valkey_target=$explicit
      valkey_fixed=1
      OPT_VALKEY_GUARD=explicit
    else
      # A cache that is not installed yet has nothing to measure.  One that
      # is installed is measured on the install path too, so a re-run of
      # --valkey and the next --optimize write the same maxmemory.
      if (( ! OPT_INSTALL_PLAN )) || [[ -n $(valkey_active_conf) ]]; then
        cache_used=$(valkey_live_used_mb 2>/dev/null || true)
        cache_current=$(valkey_current_maxmemory_mb 2>/dev/null || true)
        cache_evicts=$(valkey_policy_evicts 2>/dev/null || true)
      fi
      [[ $cache_used =~ ^[0-9]+$ ]] || cache_used=$(valkey_data_size_mb)
      [[ $cache_used =~ ^[0-9]+$ ]] || cache_used=0
      [[ $cache_current =~ ^[0-9]+$ ]] || cache_current=0
      [[ $cache_evicts =~ ^[01]$ ]] || cache_evicts=1
      if (( cache_used > 0 )); then
        OPT_VALKEY_LIVE_MB=$cache_used
      fi
      # The most the host can give the cache: the whole usable budget.
      cache_cap=$usable
      (( cache_cap < 256 )) && cache_cap=256
      # A fresh install has no data at all, so the floor is RAM-proportional:
      # it gives the cache room before the operator has to size it.
      local floor_mb
      floor_mb=$(valkey_floor_mb "$total")
      cache_plan=$(valkey_guard_maxmemory_mb "$floor_mb" "$cache_used" "$cache_current" "$cache_cap" "$cache_evicts")
      valkey_target=${cache_plan%% *}
      OPT_VALKEY_GUARD=${cache_plan##* }
      # Above the floor, live + 20% is the ordinary target, not a rescue.
      if [[ $OPT_VALKEY_GUARD == raised ]]; then
        OPT_VALKEY_GUARD=live
      fi
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
    # The page-cache reservation below needs the store size with an explicit
    # heap too.
    if [[ -z $es_store ]] && { (( ! OPT_INSTALL_PLAN )) || pkg_ok elasticsearch; }; then
      es_store=$(elasticsearch_data_size_mb)
      [[ $es_store =~ ^[0-9]+$ ]] || es_store=$(elasticsearch_data_dir_size_mb)
      [[ $es_store =~ ^[0-9]+$ ]] || es_store=0
      OPT_ES_SIZE_MB=$es_store
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
    es_op_direct=$(elasticsearch_operator_direct_mb 2>/dev/null || true)
    [[ $es_op_direct =~ ^[0-9]+$ ]] || es_op_direct=0
    (( es_op_direct > 0 )) && OPT_ES_DIRECT_OPERATOR=1
    # Direct (off-heap) memory: Elasticsearch sets MaxDirectMemorySize to
    # heap/2 when no operator file sets it, so the node can use ~1.5x the
    # heap.  It is booked, not capped: write_es_jvm_options never writes the
    # flag.  Metaspace, code cache and thread stacks (~100-300 MB) are not
    # booked; they stay inside the 20% OS margin.
    es_book_target=$(es_direct_booked_mb "$es_target" "$es_op_direct" "$es_credit")
    es_fp_target=$(( es_target + es_book_target ))
  fi

  # Reserve the live data services first.  PHP keeps only its 8-worker floor
  # during this pass so the data tier can fit; the remainder goes to PHP and
  # finally to the OS page cache.  If all targets cannot fit, scale them
  # proportionally and trim Elasticsearch first, then Valkey, then MariaDB.
  data_pool=$(( svc_usable - php_floor ))
  (( data_pool < 0 )) && data_pool=0
  # Explicit operator sizes are never scaled: the installer writes them
  # verbatim, so the plan reserves them verbatim too; otherwise the next
  # --optimize would shrink what the operator asked for.  An explicit heap
  # still carries its direct share.
  local fixed_sum=0 flex_pool flex_sum
  (( maria_fixed ))  && fixed_sum=$(( fixed_sum + maria_target ))
  (( valkey_fixed )) && fixed_sum=$(( fixed_sum + valkey_target ))
  (( es_fixed ))     && fixed_sum=$(( fixed_sum + es_fp_target ))
  # A kept live pool (only-increase) that no longer fits gives up its
  # surplus over the data target first, and only as much as the plan is
  # over.  Splitting from the kept value instead lands on a pool that the
  # next run keeps and splits again (two or more restarts for one input);
  # this way the result either fits and is kept next time, or equals the
  # data target, which is where the next run splits from too.  It never goes
  # below the 256 MB operational floor the split itself lifts to: a small
  # all-in-one keeps the install's 256 MB pool when an empty database makes
  # the data target 128 MB.
  if (( kept_pool > 0 && ! maria_fixed && maria_plan_target > 0 )); then
    over=$(( maria_target + valkey_target + es_fp_target - data_pool ))
    if (( over > 0 )); then
      local trim_floor=$maria_plan_target
      (( trim_floor < 256 )) && trim_floor=$(( maria_target < 256 ? maria_target : 256 ))
      dec=$(( maria_target - trim_floor )); (( dec > over )) && dec=$over
      (( dec > 0 )) && maria_target=$(( maria_target - dec ))
    fi
  fi
  # Data larger than the budget would take the whole pool in the
  # proportional split and push Elasticsearch and Valkey to their floors.
  (( maria_fixed == 0 && maria_target > data_pool )) && maria_target=$data_pool
  flex_pool=$(( data_pool - fixed_sum ))
  (( flex_pool < 0 )) && flex_pool=0
  targets_sum=$(( maria_target + valkey_target + es_fp_target ))
  if (( targets_sum <= data_pool )); then
    maria_alloc=$maria_target
    valkey_alloc=$valkey_target
    es_alloc=$es_target
    es_book=$es_book_target
  elif (( targets_sum > 0 )); then
    flex_sum=$(( targets_sum - fixed_sum ))
    (( flex_sum > 0 )) || flex_sum=1
    maria_alloc=$maria_target
    valkey_alloc=$valkey_target
    es_alloc=$es_target
    (( maria_fixed ))  || maria_alloc=$(( maria_target * flex_pool / flex_sum ))
    (( valkey_fixed )) || valkey_alloc=$(( valkey_target * flex_pool / flex_sum ))
    (( es_fixed ))     || es_alloc=$(( es_target * flex_pool / flex_sum ))
    # The floors lift a scaled-down share only: they never raise a service
    # above its own target (Valkey's can be 128 MB) or change an explicit size.
    (( has_maria && ! maria_fixed && maria_alloc < 256 && maria_alloc < maria_target )) \
      && maria_alloc=$(( maria_target < 256 ? maria_target : 256 ))
    (( has_cache && ! valkey_fixed && valkey_alloc < 256 && valkey_alloc < valkey_target )) \
      && valkey_alloc=$(( valkey_target < 256 ? valkey_target : 256 ))
    (( has_es && es_alloc < 512 )) && es_alloc=512
    (( has_es )) && es_book=$(es_direct_booked_mb "$es_alloc" "$es_op_direct" "$es_credit")
    alloc_total=$(( maria_alloc + valkey_alloc + es_alloc + es_book ))
    excess=$(( alloc_total - data_pool ))
    while (( excess > 0 )); do
      if (( has_es && ! es_fixed && es_alloc > 512 )); then
        # Each heap MB frees up to 1.5 MB (heap + heap/2 direct); take 2/3
        # of the excess and recompute.  With an operator or credited direct
        # share the next pass takes the rest.  Over-frees at most 1 MB,
        # which goes to PHP.
        dec=$(( (2 * excess + 2) / 3 )); (( dec > es_alloc - 512 )) && dec=$(( es_alloc - 512 ))
        es_alloc=$(( es_alloc - dec ))
        es_book=$(es_direct_booked_mb "$es_alloc" "$es_op_direct" "$es_credit")
        excess=$(( maria_alloc + valkey_alloc + es_alloc + es_book - data_pool ))
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
  # The split may have scaled the cache below the data it already holds.
  # Applying that would mass-evict on the next restart, so the same guard
  # runs again on the scaled share.  PHP cannot absorb what the guard gives
  # back: this branch is only reached when the data tier already fills its
  # pool, so PHP sits at its floor.  The amount is therefore taken from the
  # other flexible data services, in the trim order used above
  # (Elasticsearch, then MariaDB); only what their floors cannot give up is
  # left for the overcommit check below.
  if (( has_cache && ! valkey_fixed && valkey_alloc < valkey_target )); then
    cache_plan=$(valkey_guard_maxmemory_mb "$valkey_alloc" "$cache_used" "$cache_current" "$cache_cap" "$cache_evicts")
    valkey_alloc=${cache_plan%% *}
    OPT_VALKEY_GUARD=${cache_plan##* }
    excess=$(( maria_alloc + valkey_alloc + es_alloc + es_book - data_pool ))
    while (( excess > 0 && has_es && ! es_fixed && es_alloc > 512 )); do
      dec=$(( (2 * excess + 2) / 3 )); (( dec > es_alloc - 512 )) && dec=$(( es_alloc - 512 ))
      es_alloc=$(( es_alloc - dec ))
      es_book=$(es_direct_booked_mb "$es_alloc" "$es_op_direct" "$es_credit")
      excess=$(( maria_alloc + valkey_alloc + es_alloc + es_book - data_pool ))
    done
    if (( excess > 0 && has_maria && ! maria_fixed && maria_alloc > 256 )); then
      dec=$(( maria_alloc - 256 )); (( dec > excess )) && dec=$excess
      maria_alloc=$(( maria_alloc - dec )); excess=$(( excess - dec ))
    fi
  fi
  # A "kept" live value that the split then changed is no longer kept: the
  # heap must be normalised below, or this run writes an odd size (913 MB)
  # and the next run rewrites it (two restarts for the same inputs).
  (( es_kept != 0 && es_alloc != es_kept )) && es_kept=0
  (( kept_pool != 0 && maria_alloc != kept_pool )) && kept_pool=0
  # PHP gets what the data tier did not need, bounded by CPU and the 50%-RAM
  # ceiling.  Eight workers are always kept when PHP is installed.
  remaining=$(( svc_usable - maria_alloc - valkey_alloc - es_alloc - es_book ))
  (( remaining < 0 )) && remaining=0
  # The whole Elasticsearch index should sit in RAM: the heap holds no index
  # data, the OS page cache does, and index.store.preload loads every file
  # into it when the index opens (after each restart and boot).  The 20%
  # outside the service budget is page cache already; above a 10% kernel/OS
  # floor that leaves 10% of RAM.  Only the part of the index (plus 10%
  # growth room) that does not fit there comes off PHP's share, never off the
  # data services, and PHP keeps its worker floor below.
  local es_cache_room es_cache_need
  OPT_ES_CACHE_MB=0
  OPT_ES_CACHE_FREE_MB=0
  OPT_ES_PRELOAD=0
  if (( has_es && OPT_ES_SIZE_MB > 0 )); then
    es_cache_need=$(( OPT_ES_SIZE_MB + OPT_ES_SIZE_MB / 10 ))
    # Below 4 GB part of that 10% is already credited to the direct-memory
    # ceiling (the unbooked part of it); it must not be counted twice.
    es_cache_room=$(( total - usable - total / 10 - $(es_direct_credit_used_mb "$es_alloc" "$es_op_direct" "$es_book" "$es_credit") ))
    (( es_cache_room < 0 )) && es_cache_room=0
    if (( es_cache_need > es_cache_room && php_explicit_children == 0 )); then
      remaining=$(( remaining - (es_cache_need - es_cache_room) ))
      (( remaining < 0 )) && remaining=0
    fi
    OPT_ES_CACHE_MB=$OPT_ES_SIZE_MB
  fi
  if (( has_php )); then
    local floor_children=$php_floor_children
    children=$(( remaining / allowance ))
    (( children > php_capacity )) && children=$php_capacity
    (( children < floor_children )) && children=$floor_children
    (( children > 512 && children > floor_children )) && children=512
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
  # The direct share follows the heap that is written.
  if (( has_es )); then
    if (( es_op_direct > 0 )); then
      OPT_ES_DIRECT_MB=$es_op_direct
    else
      OPT_ES_DIRECT_MB=$(( (es_alloc + 1) / 2 ))
    fi
    es_book=$(es_direct_booked_mb "$es_alloc" "$es_op_direct" "$es_credit")
    OPT_ES_DIRECT_BOOKED_MB=$es_book
  fi

  # The operational floors (256 MB MariaDB/Valkey, 512 MB Elasticsearch, the
  # PHP worker floor) cannot be trimmed; on a 1 GB host running every service
  # they exceed the budget.  Record the overcommit so the plan and the report
  # say so instead of printing allocations that look as if they fit.  The
  # comparison uses the PHP budget that is actually reserved (the earlier
  # php_floor is capped at half the budget for the data-tier split) and
  # includes the booked Elasticsearch direct memory and OPcache huge pages.
  OPT_MEM_OVERCOMMIT_MB=0
  booked=$(( maria_alloc + valkey_alloc + es_alloc + es_book + php_budget + hp_mb ))
  # Preload only when the index (plus 10% growth) fits the RAM left after
  # every booked service and the 10% kernel/OS floor; preloading an index
  # that cannot stay resident would only evict MariaDB's and PHP's pages.
  # Hysteresis: switching preload on needs the 10% growth room, staying on
  # only needs the index itself to fit, so a store hovering at the edge does
  # not flip the static setting (an Elasticsearch restart) on every run.
  # PHP is counted at the 64 MB-per-worker floor here, not at the live
  # allowance: the allowance swings between cold and warm pools (64-192 MB
  # per worker), far more than the 10% band, and page cache is reclaimable,
  # so an optimistic PHP figure costs a few cache misses, not an OOM.
  if (( OPT_ES_CACHE_MB > 0 )); then
    local php_floor_mb=$(( (children > php_explicit_children ? children : php_explicit_children) * 64 ))
    (( php_floor_mb > php_budget )) && php_floor_mb=$php_budget
    OPT_ES_CACHE_FREE_MB=$(( total - (booked - php_budget + php_floor_mb) - total / 10 \
      - $(es_direct_credit_used_mb "$es_alloc" "$es_op_direct" "$es_book" "$es_credit") ))
    (( OPT_ES_CACHE_FREE_MB < 0 )) && OPT_ES_CACHE_FREE_MB=0
    local es_on=0
    elasticsearch_preload_active && es_on=1
    es_preload_fits "$OPT_ES_CACHE_MB" "$OPT_ES_CACHE_FREE_MB" "$es_on" && OPT_ES_PRELOAD=1
  fi
  if (( booked > usable )); then
    OPT_MEM_OVERCOMMIT_MB=$(( booked - usable ))
    warn "Memory plan: service floors and reserved memory (Elasticsearch direct ${es_book} MB, huge pages ${hp_mb} MB) exceed the ${usable} MB budget by ${OPT_MEM_OVERCOMMIT_MB} MB; this host is too small for the selected services"
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

# PHP-FPM worker count for this host.  One formula for the memory plan, the
# pool writer and the dry run so a fresh install, --optimize and the preview
# always agree.  Arguments: cpus, total RAM MB, an optional live pool count
# (accepted for signature compatibility and reported by the pool writer, but
# never used to size the pool) and an explicit --php children= value.
#
#   * target: working threads per logical CPU, in tenths, follows the
#     blocking profile of the host (php_workers_per_cpu_tenths).  A static
#     pool one deep per core is the measured optimum when PHP and a local
#     MariaDB share a flash-backed bare-metal host: the page is CPU-bound,
#     so extra workers only contend for the same cores.  On the 16-thread
#     audit host (XenForo member page, loopback load, c=64):
#       16 workers  834 req/s, 14.38 ms PHP CPU/request, p50 76 ms
#       20 workers  825 req/s, 14.97 ms
#       24 workers  819 req/s, 15.29 ms
#       32 workers  808 req/s, 15.68 ms, p50 79 ms
#     The same direction held on the XenForo thread page (470 vs 446 req/s)
#     and the WordPress member page (298 vs 282 req/s).  A host that can
#     block instead of compute (spinning disk, remote database, shared
#     virtual CPU) keeps headroom at 1.5-2.0 workers per core.
#   * explicit value: `--php children=` wins, clamped to floor..max(512,
#     2 x CPUs) so a typo cannot create a 10 000-process pool.
#   * RAM: at the 96 MB reservation divisor the target still wins, so a
#     small host is not under-provisioned; the reservation is a planning
#     estimate, not a hard limit.
# SETUP_PHP_WORKERS_PER_CPU (e.g. 1.0, 1.5, 2.0) pins the factor for an
# operator or a test that wants the old two-per-core profile.
php_workers_per_cpu_tenths() {
  local disk class pin=${SETUP_PHP_WORKERS_PER_CPU:-}
  if [[ -n $pin ]]; then
    local tenths
    tenths=$(awk -v v="$pin" 'BEGIN{ if (v+0 > 0) printf "%d", (v*10)+0.5 }' 2>/dev/null || true)
    if [[ $tenths =~ ^[0-9]+$ ]] && (( tenths > 0 )); then
      printf '%s' "$tenths"
      return 0
    fi
  fi
  disk=$(storage_class 2>/dev/null || true)
  [[ -n $disk ]] || disk=ssd
  # A spinning disk (or a database on another machine) blocks; the pool needs
  # a slot to switch to while a worker waits.
  [[ $disk == hdd ]] && { printf 20; return 0; }
  host_has_local_db || { printf 15; return 0; }
  class=$(host_server_type 2>/dev/null || true)
  [[ $class == vps ]] && { printf 15; return 0; }
  printf 10
}

# True when a MariaDB instance runs on this host, whether it is already
# installed (--optimize) or is part of this install run.  Both paths must
# answer the same way or a fresh install and the next --optimize would size
# the pool differently.
host_has_local_db() {
  [[ ${ENABLED[mariadb]:-0} -eq 1 ]] && return 0
  [[ " ${OPT_DETECTED[*]:-} " == *" mariadb "* ]] && return 0
  pkg_ok mariadb-server 2>/dev/null && return 0
  return 1
}

# Workers for CPU cores at a tenths-of-a-worker factor.  Pure: the tests pin
# the factor, the tuner derives it from the hardware profile.
php_children_from_tenths() {
  local cpu=$1 tenths=$2 n
  [[ $cpu =~ ^[0-9]+$ ]] && (( cpu > 0 )) || cpu=1
  [[ $tenths =~ ^[0-9]+$ ]] && (( tenths > 0 )) || tenths=10
  n=$(( (cpu * tenths + 9) / 10 ))
  (( n < 2 )) && n=2
  printf '%s' "$n"
}

php_children_ceiling() {
  local cpu=$1 ram_mb=$2 live=${3:-} explicit=${4:-}
  local cap floor max_cap
  (( cpu > 0 )) || cpu=1
  floor=$(php_children_floor "$ram_mb" "$cpu")
  cap=$floor
  if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit > 0 )); then
    cap=$explicit
    max_cap=$(( cpu * 2 ))
    (( max_cap < 512 )) && max_cap=512
    (( cap > max_cap )) && cap=$max_cap
    # An explicit count is the operator's decision in both directions.  It
    # used to be raised to the hardware target while the run log said
    # "max_children overridden to 12" (the pool was written with 24).  Two is
    # the only floor: one worker cannot answer a second request.
    (( cap < 2 )) && cap=2
  fi
  printf '%s' "$cap"
}

# Minimum pool size: the hardware target, never below two workers (a pool of
# one cannot answer a second request while the first is in the database).
php_children_floor() {
  local ram_mb=$1 cpu=${2:-0} tenths
  [[ $cpu =~ ^[0-9]+$ ]] && (( cpu > 0 )) || cpu=$(effective_cpus)
  (( cpu > 0 )) || cpu=1
  tenths=$(php_workers_per_cpu_tenths)
  php_children_from_tenths "$cpu" "$tenths"
}

# One decision tree for the PHP-FPM worker count, shared by the pool writer
# and the dry run: an explicit --php children= wins, otherwise the hardware
# rule above decides.  The live count is accepted so callers keep one call
# shape, but it never overrides the plan (that is what keeps install and
# --optimize byte-identical on a host whose pool was sized by hand).  A
# standalone call without a plan uses the same rule; the PHP budget only
# caps when it is below the hardware value.  `allowance` is the per-worker
# reservation the plan used (php_worker_allowance_mb); dividing the budget by
# the 64 MB install floor instead of it let a host whose workers measure
# 96-192 MB write a pool two to three times the RAM the plan reserved.
php_plan_max_children() {
  local nproc=$1 ram_mb=$2 live=${3:-} explicit=${4:-} php_budget=${5:-0} allowance=${6:-64}
  local cap
  if [[ $explicit =~ ^[0-9]+$ ]] && (( explicit > 0 )); then
    php_children_ceiling "$nproc" "$ram_mb" "" "$explicit"
    return 0
  fi
  cap=$(php_children_ceiling "$nproc" "$ram_mb" "" "")
  if [[ $php_budget =~ ^[0-9]+$ ]] && (( php_budget > 0 )); then
    # The budget can only lower the pool to what its RAM reservation allows,
    # never below the hardware floor.
    [[ $allowance =~ ^[0-9]+$ ]] && (( allowance > 0 )) || allowance=64
    local by_budget floor
    by_budget=$(( php_budget / allowance ))
    floor=$(php_children_floor "$ram_mb" "$nproc")
    (( by_budget < floor )) && by_budget=$floor
    (( by_budget < cap )) && cap=$by_budget
  fi
  printf '%s' "$cap"
}

# Angie worker limits shared by tune_angie_configs and the dry run.
# worker_processes is two thirds of the effective CPU count (Angie's "auto"
# counts the affinity mask, not a cgroup quota; see the measurements below).
angie_worker_limits() {
  local nproc=$1 per_core_conn=2048 per_core_fds=8192
  # Two workers per three CPUs, floor 2.  A worker's only job on a cached
  # guest hit is TLS termination, and every extra worker competes with PHP
  # and MariaDB for the same cores.  Measured on the 12-thread EPYC audit
  # host (16k TLS buffer, 100 connections, gzip guest cache):
  #   6 -> 367-371k, 8 -> 389-390k, 10 -> 369-370k, 12 -> 348-352k req/s,
  # with the member/thread tiers flat (764-767 / 840-843 req/s).  Eight
  # workers on twelve CPUs is the optimum; `auto` (= nproc) cost ~11% of
  # cached throughput.
  ANGIE_WORKER_PROCESSES=$(( nproc * 2 / 3 ))
  (( ANGIE_WORKER_PROCESSES < 2 )) && ANGIE_WORKER_PROCESSES=2
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
  # next request) and the cache is per Angie worker.  On the dev host that produced
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
    # gzip is the fallback for the few clients without Brotli; measured on
    # the same 8 vCPU origin: level 5 = 3.1 ms, level 3 = 1.9 ms per 130 KB
    # page (25 vs 29 KB).  Level 4 matches the Brotli choice.
    level=4
    (( $(effective_cpus) <= 2 )) && level=3
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

# Disk basis of the cache budget in MB: the size of the cache filesystem,
# capped at 10x its free space (so a 5% share never exceeds half of what is
# free).  Free space alone moved with the install itself: Angie is tuned
# before PHP, MariaDB and Elasticsearch take ~2 GB, so on a small disk the
# first --optimize rewrote every max_size/keys_zone and broke
# install/optimize parity.
angie_disk_free_mb() {
  local mb
  # The cache zones live under /home (angie_cache_dirs), which can be its
  # own filesystem; measure that one, not the web root.
  local dir=/home
  [[ -d $dir ]] || dir=/var/www
  local basis='NR==2{s=$2; f=$4*10; print (f < s ? f : s)}'
  mb=$(df -Pm "$dir" 2>/dev/null | awk "$basis" || true)
  [[ $mb =~ ^[0-9]+$ ]] || mb=$(df -Pm / 2>/dev/null | awk "$basis" || true)
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
      # Stand-alone fallback (no plan): use the planner's own floor so a
      # helper call cannot size the pool differently from an install.
      (( mb > 0 )) || mb=$(mariadb_floor_mb "$ram") ;;
    valkey|redis)
      mb=${OPT_VALKEY_BUDGET_MB:-0}
      (( mb > 0 )) || mb=$(valkey_floor_mb "$ram") ;;
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
  info "$(memory_plan_summary)"
}

# The one-line memory-plan summary used by the installer, --optimize and the
# report.  Four copies of this string used to drift whenever a field was
# added; the label stays a parameter ("Memory plan" vs "Memory budget").
# shellcheck disable=SC2120
memory_plan_summary() {
  local label=${1:-Memory plan}
  printf '%s: %sMB usable of %sMB (PHP=%sMB MariaDB=%sMB Cache=%sMB Elasticsearch=%sMB' \
    "$label" \
    "${OPT_MEM_BUDGET_MB:-0}" "${OPT_MEM_TOTAL_MB:-0}" \
    "${OPT_PHP_BUDGET_MB:-0}" "${OPT_MARIADB_BUDGET_MB:-0}" \
    "${OPT_VALKEY_BUDGET_MB:-0}" "${OPT_ES_BUDGET_MB:-0}"
  # Booked memory no service setting names; a host without either prints
  # the old string byte for byte.
  if (( ${OPT_ES_DIRECT_MB:-0} > 0 )); then
    printf ' ES-direct=%sMB' "$OPT_ES_DIRECT_MB"
    if (( ${OPT_ES_DIRECT_BOOKED_MB:-0} != OPT_ES_DIRECT_MB )); then
      printf ' (%sMB booked)' "${OPT_ES_DIRECT_BOOKED_MB:-0}"
    fi
  fi
  if (( ${OPT_HUGEPAGES_MB:-0} > 0 )); then
    printf ' HugePages=%sMB' "$OPT_HUGEPAGES_MB"
  fi
  printf ')'
  return 0
}

php_fpm_versions() {  local d ver
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
# RAM for it in the shared plan.  When a pool is already running, measure it
# (1.5x the average RSS) clamped to a conservative 64-192 MB range; real
# workers are commonly 20-50 MB.  When nothing can be measured (PHP-FPM is
# stopped, or only the master is visible) the answer is the same 64 MB a
# fresh install plans with (plan_memory_budget), which is also what an idle
# new pool measures.  It used to be 96 MB here, so --optimize on a host with
# PHP-FPM stopped planned a smaller buffer pool than the install had written.
php_worker_allowance_mb() {
  local ver=${1:-} out avg=0 n=0 allowance=64
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
    if [[ -n $root && -f "${root}/wp-config.php" ]]; then printf '%s\n' "$file"; fi
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
    if [[ -n $root && -f "${root}/src/XF.php" ]]; then printf '%s\n' "$file"; fi
  done
}

# Rewrite one `include h5bp/<from>;` of a vhost file, but only at the given
# nesting level: "server" (directly inside a server block) or "nested"
# (inside a location).  Brace depth is counted outside comments; a quoted
# regex quantifier such as "{3}" opens and closes on the same line, so it
# does not move the depth.  Prints nothing; returns 0 when the file changed.
angie_rewrite_include_at_level() {
  local file=$1 from=$2 to=$3 level=$4 tmp
  [[ -f $file ]] || return 1
  grep -qE "include[[:space:]]+h5bp/${from//./\\.};" "$file" || return 1
  tmp=$(tmp_file) || return 1
  awk -v from="$from" -v to="$to" -v level="$level" '
    {
      line = $0
      code = line
      sub(/#.*/, "", code)
      if (code ~ ("include[[:space:]]+h5bp/" from ";")) {
        # depth 1 = server block, 2+ = inside a location.  A one-line
        # `location /x/ { include ...; }` is still nested even though the
        # brace counter has not entered the block yet, so an include that
        # follows an opening brace on the same line counts as nested too.
        incl = index(code, "include")
        brace = index(code, "{")
        nested = (depth >= 2) || (brace > 0 && brace < incl)
        if ((level == "server" && depth == 1 && !nested) \
            || (level == "nested" && nested)) {
          sub("h5bp/" from ";", "h5bp/" to ";", line)
        }
      }
      print line
      n = split(code, ch, "")
      for (i = 1; i <= n; i++) {
        if (ch[i] == "{") depth++
        else if (ch[i] == "}") depth--
      }
    }
  ' "$file" > "$tmp" || return 1
  commit_if_changed "$file" "$tmp"
}

# One value from a Chevereto app/env.php (`'KEY' => 'value'`).
chevereto_env_value() {
  sed -nE "s/.*['\"]$2['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | tail -n1 || true
}

# Whether a Chevereto site lets guests upload: prints 1, 0, or nothing when
# it cannot be determined (no env.php, environment-only configuration, or
# MariaDB not reachable as root).  Read-only: one SELECT on the settings table.
chevereto_guest_uploads() {
  local root=$1 env db prefix value
  env="${root}/app/env.php"
  [[ -f $env ]] || return 0
  db=$(chevereto_env_value "$env" CHEVERETO_DB_NAME)
  prefix=$(chevereto_env_value "$env" CHEVERETO_DB_TABLE_PREFIX)
  [[ -n $prefix ]] || prefix=chv_
  [[ $db =~ ^[A-Za-z0-9_]+$ && $prefix =~ ^[A-Za-z0-9_]+$ ]] || return 0
  command -v mariadb >/dev/null 2>&1 || return 0
  value=$(mariadb -N -B -e "SELECT setting_value FROM \`${db}\`.\`${prefix}settings\` WHERE setting_name = 'guest_uploads'" 2>/dev/null || true)
  [[ $value == 0 || $value == 1 ]] && printf '%s' "$value"
  return 0
}

# The guest caches for XenForo and Chevereto live in a named location, which
# Angie only accepts at the server level, once per server:
#   * Chevereto: h5bp/php_chev.conf is now the plain (never cached) PHP
#     location and may stay nested; the server-level include moves to
#     h5bp/php_chev_cache.conf.  A vhost that is not migrated keeps working,
#     it just serves guests uncached.
#     Chevereto embeds the session's auth_token in every page and cannot
#     refresh it from the browser, so a cookie-less guest on a cached page
#     has no valid token: with guest uploads enabled the first upload from
#     such a page is rejected until the page is reloaded (measured).  A site
#     that allows guest uploads therefore keeps the uncached include;
#     SETUP_CHEV_GUEST_CACHE=1 forces the cache on, =0 forces it off.
#   * XenForo: h5bp/php_xf.conf carries the named location itself, so a copy
#     nested inside a location (never in the template, but possible in a
#     hand-written vhost) is pointed at the generic h5bp/php.conf.
# Deployed vhosts are otherwise left alone.
angie_migrate_guest_cache_includes() {
  local target=${1:-/etc/angie} vhost rel root guest want
  [[ -d "${target}/conf.d" ]] || return 0
  for vhost in "$target"/conf.d/*.conf; do
    [[ -f $vhost ]] || continue
    rel=${vhost#"${target}"/}
    if [[ -f "${target}/h5bp/php_chev_cache.conf" ]] \
       && grep -qE '^[[:space:]]*include[[:space:]]+h5bp/php_chev(_cache)?\.conf;' "$vhost"; then
      want=cache
      case "${SETUP_CHEV_GUEST_CACHE:-}" in
        0) want=plain ;;
        1) want=cache ;;
        *)
          # A vhost without a root directive makes the helper's pipeline fail.
          root=$(angie_vhost_root "$vhost" || true)
          guest=""
          if [[ -n $root ]]; then guest=$(chevereto_guest_uploads "$root" || true); fi
          if [[ $guest == 1 ]]; then want=plain; fi
          ;;
      esac
      if [[ $want == cache ]]; then
        if angie_rewrite_include_at_level "$vhost" php_chev.conf php_chev_cache.conf server; then
          tune_note "${rel}: Chevereto guest cache include is h5bp/php_chev_cache.conf (cookie-safe)"
        fi
      elif angie_rewrite_include_at_level "$vhost" php_chev_cache.conf php_chev.conf server; then
        tune_note "${rel}: Chevereto guest cache turned off (guest uploads are enabled or SETUP_CHEV_GUEST_CACHE=0)"
      elif [[ ${SETUP_CHEV_GUEST_CACHE:-} != 0 ]]; then
        opt_report "- Chevereto: \`${rel}\` allows guest uploads, so guest pages are not cached (a cached page cannot carry the visitor's upload token; SETUP_CHEV_GUEST_CACHE=1 overrides)"
      fi
    fi
    if grep -qE '^[[:space:]]*location[[:space:]]+@xf_guest_cache' "${target}/h5bp/php_xf.conf" 2>/dev/null \
       && angie_rewrite_include_at_level "$vhost" php_xf.conf php.conf nested; then
      tune_note "${rel}: nested h5bp/php_xf.conf include replaced by h5bp/php.conf (the guest cache is server-level only)"
    fi
    # server-configs-nginx 1.6.48: php_wp.conf has exact `= /index.php` and
    # `= /wp-cron.php` locations, which Angie refuses inside another
    # location ("/index.php is outside location /blog/").  A subdirectory
    # install that nested it gets the generic, nestable php.conf, which
    # keeps its own deny rules.
    if grep -qE '^[[:space:]]*location[[:space:]]+=[[:space:]]*/index\.php' "${target}/h5bp/php_wp.conf" 2>/dev/null \
       && angie_rewrite_include_at_level "$vhost" php_wp.conf php.conf nested; then
      tune_note "${rel}: nested h5bp/php_wp.conf include replaced by h5bp/php.conf (php_wp.conf is server-level only)"
    fi
  done
  return 0
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
  # in the server block.  A vhost without it gets the include added by default
  # (inserted before the php_wp include so the cache directives precede the PHP
  # location); SETUP_WP_GUEST_CACHE=0 keeps it off and reports the vhost.
  # The shared php_wp.conf include, when present, already covers every vhost.
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
     && { (( ${#wp_optout[@]} == 0 )) || [[ ${SETUP_WP_GUEST_CACHE:-1} != 1 ]]; }; then
    opt_report "- WordPress: FastCGI guest cache already enabled for ${#wp_enabled[@]} vhost(s)"
    for vhost in "${wp_optout[@]}"; do
      opt_report "- WordPress: \`${vhost#"${target}"/}\` has no wordpress_cache include (guest cache disabled by SETUP_WP_GUEST_CACHE=0)"
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
  # Per-vhost include, on by default: inserted in the server block right
  # before the php_wp include so the cache directives precede the PHP
  # location, exactly where the template puts them.  SETUP_WP_GUEST_CACHE=0
  # leaves the vhost uncached and reports it.  A vhost with no php_wp include
  # (a fully hand-written PHP location) has no safe anchor: the insertion is
  # skipped and reported separately, instead of claiming the operator
  # disabled the cache.
  local -a wp_failed=()
  if [[ ${SETUP_WP_GUEST_CACHE:-1} == 1 ]]; then
    for vhost in "${wp_optout[@]}"; do
      if tune_insert_before "$vhost" '^[[:space:]]*include[[:space:]]+h5bp/php_wp\.conf;' \
           '    include h5bp/wordpress_cache.conf; # added by setup.sh (SETUP_WP_GUEST_CACHE=0 disables)' \
           "${vhost#"${target}"/}: wordpress_cache include added"; then
        wp_enabled+=("$vhost")
        changed=1
      else
        wp_failed+=("$vhost")
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
    opt_report "- WordPress: \`${vhost#"${target}"/}\` has no wordpress_cache include (guest cache disabled by SETUP_WP_GUEST_CACHE=0)"
  done
  for vhost in "${wp_failed[@]}"; do
    opt_report "- WordPress: \`${vhost#"${target}"/}\` has no h5bp/php_wp.conf include to anchor the guest cache; add one (or include h5bp/wordpress_cache.conf by hand)"
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
     || ! grep -qE 'map[[:space:]]+\$http_accept_encoding[[:space:]]+\$setup_cache_enc' "$file" \
     || ! grep -qE 'map[[:space:]]+\$cookie_xf_language_id[[:space:]]+\$setup_xf_key_language' "$file"; then
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
# Cache-key tokens: the style, style-variation and language cookies are
# visitor-controlled, so only a well-formed value enters the key.
map $cookie_xf_style_variation $setup_xf_key_variation {
    default "";
    "~^[A-Za-z0-9_-]{1,32}$" $cookie_xf_style_variation;
}
map $cookie_xf_style_id $setup_xf_key_style {
    default "";
    "~^[0-9]{1,6}$" $cookie_xf_style_id;
}
map $cookie_xf_language_id $setup_xf_key_language {
    default "";
    "~^[0-9]{1,6}$" $cookie_xf_language_id;
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
  local file=$1 tmp
  [[ -f $file ]] || return 0
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
  commit_if_changed "$file" "$tmp" \
    && tune_note "XenForo: cookie bypass moved to a map"
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
  # One cache-status header name everywhere: the old include reported
  # X-5m-Cache while WordPress used X-Cache-Status.  Rename the legacy line
  # before the repair so the file cannot carry two different status headers.
  if grep -qE '^[[:space:]]*add_header[[:space:]]+X-5m-Cache[[:space:]]' "$file"; then
    sed_in_place -E 's/^([[:space:]]*add_header[[:space:]]+)X-5m-Cache([[:space:]])/\1X-Cache-Status\2/' "$file"
    tune_note "XenForo: cache status header renamed to X-Cache-Status"
  fi
  # The proxy include (css.php, proxy.php, sitemap.php) is repaired on both
  # paths below; php_xf.conf gets its headers with the injected block or
  # from the repair at the end.
  tune_xf_location_security_headers "$target" "${target}/h5bp/php_xf_proxy.conf"

  local lock='$setup_xf_guest_bypass $nocacheuri'
  # The repository include serves cacheable guests from the named location
  # @xf_guest_cache, where Set-Cookie is hidden, so the cache may ignore it.
  # An older or hand-written include has one location for guests and members:
  # hiding the header there would break logins, and ignoring it would replay
  # the first visitor's cookies to every guest.  Such a file must not store
  # a response that sets a cookie at all.
  local split=0 ignore='fastcgi_ignore_headers Cache-Control Expires;'
  if grep -qE '^[[:space:]]*location[[:space:]]+@xf_guest_cache' "$file"; then
    split=1
    ignore='fastcgi_ignore_headers Cache-Control Expires Set-Cookie;'
  fi
  # One source of truth for the guest-cache block: "match-pattern<TAB>line".
  # A fresh include gets the whole block injected; an existing one is
  # repaired line by line from the same list, so the two paths cannot drift
  # (the repair list used to lack the 301/302/any TTLs, the status header and
  # background_update, and wrote a shorter cache key).
  local -a directives=(
    $'fastcgi_cache_methods[[:space:]]\tfastcgi_cache_methods GET HEAD;'
    "fastcgi_cache_key[[:space:]]"$'\t'"fastcgi_cache_key ${XF_CACHE_KEY};"
    $'fastcgi_cache_lock[[:space:]]+on;\tfastcgi_cache_lock on;'
    $'fastcgi_cache_background_update[[:space:]]\tfastcgi_cache_background_update on;'
    $'fastcgi_cache_use_stale[[:space:]]\tfastcgi_cache_use_stale error timeout invalid_header updating http_503;'
    "fastcgi_ignore_headers[[:space:]]"$'\t'"${ignore}"
    $'fastcgi_cache[[:space:]]+fastcgicache;\tfastcgi_cache fastcgicache;'
    "fastcgi_no_cache[[:space:]]"$'\t'"fastcgi_no_cache ${lock};"
    "fastcgi_cache_bypass[[:space:]]"$'\t'"fastcgi_cache_bypass ${lock};"
    $'fastcgi_cache_valid[[:space:]]+200[[:space:]]\tfastcgi_cache_valid 200 5m;'
    $'fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;\tfastcgi_cache_valid 500 502 503 504 0s;'
    $'fastcgi_cache_valid[[:space:]]+(301[[:space:]]+)?302[[:space:]]\tfastcgi_cache_valid 302 1h;'
    $'fastcgi_cache_valid[[:space:]]+301[[:space:]]\tfastcgi_cache_valid 301 1h;'
    $'fastcgi_cache_valid[[:space:]]+([0-9]+[[:space:]]+)*404[[:space:]]\tfastcgi_cache_valid 404 1m;'
    $'fastcgi_cache_valid[[:space:]]+any[[:space:]]\tfastcgi_cache_valid any 5s;'
    $'add_header[[:space:]]+X-Cache-Status[[:space:]]\tadd_header X-Cache-Status $upstream_cache_status always;'
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
  if (( split )); then
    tune_ensure_in_location "$file" '^[[:space:]]*fastcgi_hide_header[[:space:]]+Set-Cookie;' \
      'fastcgi_hide_header Set-Cookie;' \
      "XenForo: cached guest pages no longer replay Set-Cookie"
  elif grep -qE '^[[:space:]]*fastcgi_ignore_headers[[:space:]].*Set-Cookie' "$file"; then
    sed_in_place -E '/^[[:space:]]*fastcgi_ignore_headers[[:space:]]/ s/[[:space:]]+Set-Cookie//' "$file"
    tune_note "XenForo: single-location include no longer caches responses that set a cookie"
  fi
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

# XenForo's config.php is plain PHP assignments, so the LAST assignment of a
# key is the live one (a site-specific override appended below the installer's
# block is common).  WordPress define() is the opposite: the first one wins.
xf_db_host_from_config() {
  sed -nE "s/^[[:space:]]*\\\$config\[['\"]db['\"]\]\[['\"]host['\"]\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | tail -n1 || true
}

# The array-literal form from the XenForo manual, joined onto one line:
#   $config['cache']['config'] = [
#       'host' => '/run/valkey/valkey.sock',
#       'port' => 0,
#   ];
# Prints the last such statement, or nothing.
xf_cache_config_literal() {
  awk '
    /^[[:space:]]*\$config\[[\047"]cache[\047"]\]\[[\047"]config[\047"]\][[:space:]]*=[[:space:]]*(\[|array[[:space:]]*\()/ { buf = ""; on = 1 }
    on { buf = buf " " $0; if ($0 ~ /;[[:space:]]*((\/\/|#).*)?$/) { on = 0; last = buf } }
    END { if (last != "") print last }
  ' "$1" 2>/dev/null || true
}

xf_cache_host_from_config() {
  local value
  value=$(sed -nE "s/^[[:space:]]*\\\$config\[['\"]cache['\"]\]\[['\"]config['\"]\]\[['\"]host['\"]\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | tail -n1 || true)
  if [[ -z $value ]]; then
    value=$(xf_cache_config_literal "$1" \
      | sed -nE "s/.*['\"]host['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" || true)
  fi
  printf '%s' "$value"
}

xf_cache_port_from_config() {
  local value
  value=$(sed -nE "s/^[[:space:]]*\\\$config\[['\"]cache['\"]\]\[['\"]config['\"]\]\[['\"]port['\"]\][[:space:]]*=[[:space:]]*['\"]?([0-9]+).*/\1/p" "$1" 2>/dev/null | tail -n1 || true)
  if [[ -z $value ]]; then
    value=$(xf_cache_config_literal "$1" \
      | sed -nE "s/.*['\"]port['\"][[:space:]]*=>[[:space:]]*['\"]?([0-9]+).*/\1/p" || true)
  fi
  printf '%s' "$value"
}

# One /var/www walk per --optimize run.  Every finder used to walk to depth
# 6 on its own, and XenForo attachment trees sit at depth 5-6: on a forum
# with 3.7M entries at that depth each walk took 4-5 s and a run made about
# eight of them, a silent ~45 s pause between the sysctl and cron steps.
# app_config_scan_prime records both lists once in the main shell; the
# finders, usually called inside a process substitution, read the copy.
# Only --optimize primes it (it never creates or removes a site); the dry
# run makes no such walk, and the install path keeps walking live, since it
# adds sites as it runs.
APP_CONFIG_SCAN_PRIMED=0
APP_CONFIG_SCAN_LIST=""
app_config_scan_walk() {
  find "${SETUP_WWW_ROOT:-/var/www}" -maxdepth 6 -type f \( -name wp-config.php -o -path '*/src/config.php' \) \
    2>/dev/null | sort -u || true
}
app_config_scan_prime() {
  APP_CONFIG_SCAN_LIST=$(app_config_scan_walk)
  APP_CONFIG_SCAN_PRIMED=1
}
app_config_scan_reset() {
  APP_CONFIG_SCAN_LIST=""
  APP_CONFIG_SCAN_PRIMED=0
}
app_config_scan() {
  if (( APP_CONFIG_SCAN_PRIMED )); then
    [[ -z $APP_CONFIG_SCAN_LIST ]] || printf '%s\n' "$APP_CONFIG_SCAN_LIST"
  else
    app_config_scan_walk
  fi
}

# Same depth as the managed wp-cron entry and the XenForo finder, so a site
# that is hardened here is also the site whose wp-cron.php the cron runs.
app_find_wordpress_configs() {
  app_config_scan | grep -E '(^|/)wp-config\.php$' || true
}

app_find_xenforo_configs() {
  local conf
  while IFS= read -r conf; do
    if [[ -f "${conf%/config.php}/XF.php" ]]; then
      printf '%s\n' "$conf"
    fi
  done < <(app_config_scan | grep -E '/src/config\.php$' || true)
}


