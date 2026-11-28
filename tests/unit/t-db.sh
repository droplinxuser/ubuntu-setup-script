#!/usr/bin/env bash
# Unit tests for the 1.22.5 MariaDB / Elasticsearch defaults:
#   DB1  MariaDB memory outside the buffer pool booked by the memory plan
#        (fixed buffers + active queries x (session buffers + tmp/2)) from the
#        room PHP leaves, tmp_table_size capped when it does not fit, PHP
#        workers never cut; shown in the --optimize report and the dry run.
#   DB2  the monthly mariadb-check always runs ANALYZE (-a), logs to
#        /var/www/logs/mariadb/check.log; the cron converges.  The OPTIMIZE
#        opt-in (SETUP_MARIADB_MONTHLY_OPTIMIZE, removed in 1.22.5) is
#        ignored, and a persisted MARIADB_MONTHLY_OPTIMIZE is deleted from
#        the host file with one note while the job moves to ANALYZE.
#   DB3  xpack.ml.enabled: false in the managed Elasticsearch block.
# (DB4, the fd ceilings, is covered in tests/unit/t-nofile.sh.)
# No root, no services and no system changes: every probe is a stub, the
# crontab and the host tuning file are fixtures under /tmp.
# Usage: bash tests/unit/t-db.sh
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-db.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
trap 'rm -rf "$TMP"' EXIT
set +e
mkdir -p "$SETUP_STATE_DIR"

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-db.sh,title=db test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
eq() { [[ $1 == "$2" ]]; }
le() { (( $1 <= $2 )); }
ge() { (( $1 >= $2 )); }

# ---------------------------------------------------------------------------
# DB1: helpers
# ---------------------------------------------------------------------------
check "log buffer: RAM/256 within 16..64" eq "$(mariadb_log_buffer_mb 2048):$(mariadb_log_buffer_mb 8192):$(mariadb_log_buffer_mb 65536)" "16:32:64"
check "aria: RAM/128 within 16..256" eq "$(mariadb_aria_mb 1024):$(mariadb_aria_mb 8192):$(mariadb_aria_mb 65536)" "16:64:256"
check "tmp: RAM/256 within 32..256, never above pool/8" \
  eq "$(mariadb_tmp_table_mb 32768 8192):$(mariadb_tmp_table_mb 32768 512):$(mariadb_tmp_table_mb 4096 4096)" "128:64:32"
check "tmp: a plan cap lowers it" eq "$(mariadb_tmp_table_mb 32768 8192 48)" 48
check "tmp: the cap never goes below 16" eq "$(mariadb_tmp_table_mb 32768 8192 8)" 16
check "tmp: a cap above the value changes nothing" eq "$(mariadb_tmp_table_mb 32768 8192 512)" 128
check "tmp: a garbage cap is ignored" eq "$(mariadb_tmp_table_mb 32768 8192 x)" 128
check "fixed non-pool: log buffer + aria + 32 MB key buffer (32 GB)" eq "$(mariadb_fixed_nonpool_mb 32768)" $(( 64 + 256 + 32 ))
# 12 active queries x (2.5 + 128/2) = 30 + 768.
check "non-pool: fixed + threads x (2.5 MB + tmp/2)" eq "$(mariadb_nonpool_mb 32768 12 128)" $(( 352 + 30 + 768 ))
check "non-pool: odd thread count rounds the session share up" eq "$(mariadb_nonpool_mb 4096 3 32)" $(( 16 + 32 + 32 + 8 + 48 ))

# The profile writer uses the same helpers (no second formula).
profile_body=$(declare -f mariadb_compute_profile)
check "compute_profile: log buffer from the helper" has "$profile_body" 'log_buffer=$(mariadb_log_buffer_mb "$ram_mb")'
check "compute_profile: aria from the helper" has "$profile_body" 'aria_mb=$(mariadb_aria_mb "$ram_mb")'
check "compute_profile: tmp from the helper with the plan cap" has "$profile_body" '"${OPT_MARIADB_TMP_CAP_MB:-0}"'

# compute_profile writes the capped tmp_table_size (behaviour).
profile_tmp() { # ram pool cap -> MARIADB_PROFILE_TMP_MB
  (
    stub_ram=$1
    mem_total_mb() { printf '%s' "$stub_ram"; }
    effective_cpus() { printf '12'; }
    mariadb_storage_class() { printf 'nvme'; }
    mariadb_io_capacity() { printf '4000 8000'; }
    php_pool_max_children() { printf '12'; }
    app_persistent_db_configs() { printf '0'; }
    effective_backlog() { printf '4096'; }
    command() { [[ $1 == -v && $2 == mariadb ]] && return 1; builtin command "$@"; }
    OPT_MARIADB_TMP_CAP_MB=$3
    mariadb_compute_profile "$2"
    printf '%s' "$MARIADB_PROFILE_TMP_MB"
  )
}
check "profile: no cap -> 128 MB on 32 GB" eq "$(profile_tmp 32768 8192 0)" 128
check "profile: plan cap 64 -> 64 MB" eq "$(profile_tmp 32768 8192 64)" 64
out=$( OPT_MARIADB_TMP_CAP_MB=48; mem_total_mb() { printf '32768'; }; effective_cpus() { printf '12'; }
       mariadb_storage_class() { printf 'nvme'; }; mariadb_io_capacity() { printf '4000 8000'; }
       php_pool_max_children() { printf '12'; }; app_persistent_db_configs() { printf '0'; }
       effective_backlog() { printf '4096'; }; mariadb_server_version() { printf '11.8.3'; }
       command() { [[ $1 == -v && $2 == mariadb ]] && return 1; builtin command "$@"; }
       mariadb_performance_settings 8192 )
check "drop-in: tmp_table_size follows the cap" has "$out" $'tmp_table_size = 48M\nmax_heap_table_size = 48M'

# ---------------------------------------------------------------------------
# DB1: memory plans on the four host classes, before/after workers
# ---------------------------------------------------------------------------
plan_stubs() {
  php_primary_version() { printf '8.5'; }
  php_worker_allowance_mb() { printf '96'; }
  php_pool_max_children() { printf '0'; }
  php_workers_per_cpu_tenths() { printf '10'; }
  mariadb_current_pool_mb() { printf '0'; }
  mariadb_current_chunk_mb() { printf '128'; }
  mariadb_data_dir_size_mb() { printf '0'; }
  elasticsearch_data_dir_size_mb() { printf '0'; }
  elasticsearch_current_heap_mb() { printf '0'; }
  elasticsearch_operator_direct_mb() { :; }
  elasticsearch_preload_active() { return 1; }
  valkey_live_used_mb() { return 0; }
  valkey_current_maxmemory_mb() { printf '0'; }
  valkey_policy_evicts() { printf '1'; }
  valkey_active_conf() { :; }
  valkey_data_size_mb() { printf '0'; }
  hugepages_reserved_mb() { printf '0'; }
  warn() { :; }
  rm -f "$SETUP_STATE_DIR/explicit-options.conf"
  OPT_INSTALL_PLAN=0
  OPT_DETECTED=(nginx php:8.5 mariadb valkey elastic)
}
# host_plan RAM CPUS DB_MB ES_MB [before] -> "children php_budget maria tmpcap nonpool short overcommit"
# "before" stubs the non-pool helper to 0 (the 1.22.4 plan).
host_plan() {
  (
    plan_stubs
    stub_ram=$1 stub_cpus=$2 stub_db=$3 stub_es=$4
    mem_total_mb() { printf '%s' "$stub_ram"; }
    effective_cpus() { printf '%s' "$stub_cpus"; }
    mariadb_data_size_mb() { printf '%s' "$stub_db"; }
    elasticsearch_data_size_mb() { printf '%s' "$stub_es"; }
    if [[ ${5:-} == before ]]; then mariadb_nonpool_mb() { printf '0'; }; fi
    plan_memory_budget >/dev/null 2>&1
    printf '%s %s %s %s %s %s %s %s' "$OPT_PHP_CHILDREN" "$OPT_PHP_BUDGET_MB" "$OPT_MARIADB_BUDGET_MB" \
      "$OPT_MARIADB_TMP_CAP_MB" "$OPT_MARIADB_NONPOOL_MB" "$OPT_MARIADB_NONPOOL_SHORT_MB" "$OPT_MEM_OVERCOMMIT_MB" \
      "$OPT_VALKEY_BUDGET_MB/$OPT_ES_BUDGET_MB/$OPT_ES_PRELOAD"
  )
}
# name RAM CPUS DB ES
for host in "4GB 3900 2 1000 500" "8GB 7900 4 4000 8000" "32GB-EPYC 31500 12 2000 1000" "62GB-Xeon 63500 12 2000 1000"; do
  read -r hname hram hcpus hdb hes <<<"$host"
  read -r b_kids b_php b_maria _ _ _ b_over b_rest <<<"$(host_plan "$hram" "$hcpus" "$hdb" "$hes" before)"
  read -r a_kids a_php a_maria a_cap a_np a_short a_over a_rest <<<"$(host_plan "$hram" "$hcpus" "$hdb" "$hes")"
  printf 'INFO  %s: workers before=%s after=%s (changed %s); non-pool %s MB, tmp cap %s, short %s\n' \
    "$hname" "$b_kids" "$a_kids" $(( a_kids - b_kids )) "$a_np" "$a_cap" "$a_short"
  check "$hname: PHP workers unchanged ($b_kids -> $a_kids)" eq "$a_kids" "$b_kids"
  check "$hname: PHP budget unchanged" eq "$a_php" "$b_php"
  check "$hname: buffer pool unchanged" eq "$a_maria" "$b_maria"
  check "$hname: cache/heap/preload unchanged" eq "$a_rest" "$b_rest"
  check "$hname: overcommit figure unchanged" eq "$a_over" "$b_over"
  check "$hname: non-pool memory is booked" ge "$a_np" 64
  case $hname in
    32GB-EPYC|62GB-Xeon)
      check "$hname: room for the non-pool memory, tmp_table_size not capped" eq "$a_cap:$a_short" "0:0" ;;
  esac
done
# 8 GB data-bound all-in-one: the data tier fills its share, so the room PHP
# leaves is small; tmp_table_size is capped (and the rest named).
read -r _ _ _ cap8 np8 short8 _ _ <<<"$(host_plan 7900 4 4000 8000)"
check "8GB data-bound: tmp_table_size capped" ge "$cap8" 16
check "8GB data-bound: cap is a 16 MB step" eq $(( cap8 % 16 )) 0
check "8GB data-bound: capped below the uncapped 30 MB value" le "$cap8" 30
# A roomy host: the booked figure equals the helper's formula.
(
  plan_stubs
  mem_total_mb() { printf '31500'; }
  effective_cpus() { printf '12'; }
  mariadb_data_size_mb() { printf '2000'; }
  elasticsearch_data_size_mb() { printf '1000'; }
  plan_memory_budget >/dev/null 2>&1
  want=$(mariadb_nonpool_mb 31500 12 "$(mariadb_tmp_table_mb 31500 "$OPT_MARIADB_BUDGET_MB")")
  check "32GB: booked non-pool equals the formula ($want MB)" eq "$OPT_MARIADB_NONPOOL_MB" "$want"
  check "32GB: active queries = thread_pool_size (CPUs)" eq "$OPT_MARIADB_ACTIVE_THREADS" 12
  line=$(mariadb_nonpool_summary)
  check "summary: names the booked figure" has "$line" "non-pool memory booked ${want}MB"
  check "summary: reports the PHP worker change" has "$line" "PHP workers changed: 0"
  check "summary: no cap note on a roomy host" lacks "$line" "capped"
) > "$TMP/sub.out"
cat "$TMP/sub.out"
PASS=$(( PASS + $(grep -c '^PASS' "$TMP/sub.out") ))
FAIL=$(( FAIL + $(grep -c '^FAIL' "$TMP/sub.out") ))
# Tight host: the summary names the cap and the remainder.
(
  plan_stubs
  mem_total_mb() { printf '7900'; }
  effective_cpus() { printf '4'; }
  mariadb_data_size_mb() { printf '4000'; }
  elasticsearch_data_size_mb() { printf '8000'; }
  plan_memory_budget >/dev/null 2>&1
  line=$(mariadb_nonpool_summary)
  check "summary (8GB): names the tmp_table_size cap" has "$line" "capped at ${OPT_MARIADB_TMP_MB}MB"
  if (( OPT_MARIADB_NONPOOL_SHORT_MB > 0 )); then
    check "summary (8GB): names the part left in the OS margin" has "$line" "stays in the 20% OS margin"
  fi
  # The capped value reaches the drop-in.
  check "8GB: the profile writes the capped tmp_table_size" \
    eq "$(mariadb_tmp_table_mb 7900 "$OPT_MARIADB_BUDGET_MB" "$OPT_MARIADB_TMP_CAP_MB")" "$OPT_MARIADB_TMP_MB"
) > "$TMP/sub2.out"
cat "$TMP/sub2.out"
PASS=$(( PASS + $(grep -c '^PASS' "$TMP/sub2.out") ))
FAIL=$(( FAIL + $(grep -c '^FAIL' "$TMP/sub2.out") ))
# No MariaDB: nothing is booked, no line.
(
  plan_stubs
  OPT_DETECTED=(nginx php:8.5)
  mem_total_mb() { printf '8192'; }
  effective_cpus() { printf '4'; }
  plan_memory_budget >/dev/null 2>&1
  [[ $OPT_MARIADB_NONPOOL_MB == 0 && $OPT_MARIADB_TMP_CAP_MB == 0 && -z $(mariadb_nonpool_summary) ]]
)
check "no MariaDB: nothing booked, no summary line" eq "$?" 0
# Wiring: the --optimize report and the dry run print the line.
so_src=$(cat "$ROOT/lib/service-optimizers.sh")
check "optimize_mariadb reports the non-pool line" has "$(declare -f optimize_mariadb)" 'mariadb_nonpool_summary'
check "the dry run prints the non-pool line" has "$so_src" 'printf "  MariaDB: %s\n" "$nonpool_line"'
check "the plan resets the tmp cap on every run" has "$(declare -f plan_memory_budget)" 'OPT_MARIADB_TMP_CAP_MB=0'

# ---------------------------------------------------------------------------
# DB2: monthly maintenance cron
# ---------------------------------------------------------------------------
CRONF=$TMP/crontab
crontab() {
  if [[ ${1:-} == -l ]]; then [[ -f $CRONF ]] && cat "$CRONF"; return 0; fi
  cp "$1" "$CRONF"
}
cron_web_etc() { return 1; }
cron_mariadb_configured() { return 0; }
app_find_wordpress_configs() { :; }
app_find_xenforo_configs() { :; }
persist_xf_job_cron() { :; }
info() { :; }
tune_note() { :; }
export SETUP_TUNING_FILE=$TMP/setup-tuning
: > "$SETUP_TUNING_FILE"
cat > "$CRONF" <<EOF
MAILTO=""
${CRON_BEGIN}
3 3 * * * /usr/local/bin/mysqlbkup.sh 1>> ${LOG_ROOT}/mariadb/backup.log 2>> ${LOG_ROOT}/mariadb/backup-err.log
4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair > /dev/null 2>&1
${CRON_END}
EOF
unset SETUP_MARIADB_MONTHLY_OPTIMIZE MARIADB_MONTHLY_OPTIMIZE
write_cron
c=$(cat "$CRONF")
check "cron: the 1.22.4 OPTIMIZE line is replaced" lacks "$c" "-Aos"
check "cron: default is ANALYZE, logged to the setup log dir" has "$c" "4 4 4 * * /usr/bin/mariadb-check -Aas >> ${LOG_ROOT}/mariadb/check.log 2>&1"
check "cron: no /dev/null for the check any more" lacks "$(grep mariadb-check "$CRONF")" "/dev/null"
check "cron: exactly one mariadb-check line" eq "$(grep -c mariadb-check "$CRONF")" 1
check "cron: the backup line is kept" has "$c" "/usr/local/bin/mysqlbkup.sh"
check "cron: operator lines outside the block are kept" has "$c" 'MAILTO=""'
check "cron: the check log is covered by the managed logrotate glob" \
  has "$(declare -f configure_logrotate)" '/var/www/logs/*/*.log'
write_cron
check "cron: a re-run converges (unchanged)" eq "$CRON_UPDATED" 0
check "cron: nothing persisted" eq "$(cat "$SETUP_TUNING_FILE")" ""
# The OPTIMIZE opt-in was removed in 1.22.5: the environment knob no longer
# changes the job or the host file (setup.sh drops it with a warning).
SETUP_MARIADB_MONTHLY_OPTIMIZE=1 write_cron
check "cron: SETUP_MARIADB_MONTHLY_OPTIMIZE=1 no longer selects OPTIMIZE" lacks "$(cat "$CRONF")" "-Aos"
check "cron: SETUP_MARIADB_MONTHLY_OPTIMIZE=1 is not persisted" eq "$(cat "$SETUP_TUNING_FILE")" ""
check "the cron line takes no OPTIMIZE form" lacks "$(declare -f mariadb_check_cron_line)" "-Aos"
check "no mariadb_monthly_optimize switch remains" eq "$(declare -F mariadb_monthly_optimize || true)" ""
check "reset no longer keeps MARIADB_MONTHLY_OPTIMIZE" \
  bash -c '! printf "%s\n" "$@" | grep -qx MARIADB_MONTHLY_OPTIMIZE' _ "${RESET_KEEP_PINS[@]}"
# Migration: a host that persisted MARIADB_MONTHLY_OPTIMIZE=1 under 1.22.4
# (-Aos job) has the key deleted from the host file, other keys kept, the job
# rewritten to ANALYZE, and exactly one note, also across a second run.
cat > "$CRONF" <<EOF
${CRON_BEGIN}
3 3 * * * /usr/local/bin/mysqlbkup.sh 1>> ${LOG_ROOT}/mariadb/backup.log 2>> ${LOG_ROOT}/mariadb/backup-err.log
4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair >> ${LOG_ROOT}/mariadb/check.log 2>&1
${CRON_END}
EOF
printf 'XF_JOB_CRON=1\nMARIADB_MONTHLY_OPTIMIZE=1\nNODE_MAJOR=22\n' > "$SETUP_TUNING_FILE"
(
  tune_note() { printf '%s\n' "$*" >> "$TMP/monthly-notes"; }
  MARIADB_MONTHLY_OPTIMIZE=1
  write_cron
  write_cron
)
check "migrate: MARIADB_MONTHLY_OPTIMIZE is deleted from the host file" \
  eq "$(grep -c '^MARIADB_MONTHLY_OPTIMIZE=' "$SETUP_TUNING_FILE")" 0
check "migrate: the other host-file keys are kept" \
  eq "$(cat "$SETUP_TUNING_FILE")" $'XF_JOB_CRON=1\nNODE_MAJOR=22'
check "migrate: the persisted OPTIMIZE job is rewritten to ANALYZE" \
  has "$(cat "$CRONF")" "4 4 4 * * /usr/bin/mariadb-check -Aas >> ${LOG_ROOT}/mariadb/check.log 2>&1"
check "migrate: no OPTIMIZE job is left" lacks "$(cat "$CRONF")" "-Aos"
check "migrate: still one mariadb-check line" eq "$(grep -c mariadb-check "$CRONF")" 1
check "migrate: reported once across two runs" eq "$(grep -c 'MARIADB_MONTHLY_OPTIMIZE removed' "$TMP/monthly-notes")" 1
check "migrate: the note says it was removed in 1.22.5" has "$(cat "$TMP/monthly-notes")" "removed in 1.22.5"
# A host with the key but no MariaDB any more still loses the key.
printf 'MARIADB_MONTHLY_OPTIMIZE=0\n' > "$SETUP_TUNING_FILE"
( cron_mariadb_configured() { return 1; }; write_cron )
check "migrate: the key is dropped even without MariaDB" eq "$(cat "$SETUP_TUNING_FILE")" ""
: > "$SETUP_TUNING_FILE"
unset SETUP_MARIADB_MONTHLY_OPTIMIZE MARIADB_MONTHLY_OPTIMIZE
# --purge still removes the managed line by its path.
check "purge removes the mariadb-check line by path" has "$(declare -f purge_mariadb)" "cron_remove_line '/usr/bin/mariadb-check'"
# A stray bare line outside the block is dropped (legacy strip).
printf '4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair > /dev/null 2>&1\n' >> "$CRONF"
write_cron
check "cron: a bare legacy line outside the block is dropped" eq "$(grep -c mariadb-check "$CRONF")" 1

# ---------------------------------------------------------------------------
# DB3: xpack.ml.enabled: false
# ---------------------------------------------------------------------------
effective_cpus() { printf '12'; }
yml=$TMP/elasticsearch.yml
printf 'cluster.name: x\nxpack.ml.enabled: true\nnode.name: a\n' > "$yml"
OPT_ES_PRELOAD=0
elasticsearch_strip_managed "$yml"
elasticsearch_write_performance_block "$yml"
y=$(cat "$yml")
check "ES: the managed block disables machine learning" \
  has "$(sed -n '/^# BEGIN setup.sh optimize$/,/^# END setup.sh optimize$/p' "$yml")" "xpack.ml.enabled: false"
check "ES: an operator xpack.ml.enabled line is commented out" has "$y" "#xpack.ml.enabled: true"
check "ES: exactly one active xpack.ml.enabled" eq "$(grep -cE '^[[:space:]]*xpack\.ml\.enabled[[:space:]]*:' "$yml")" 1
check "ES: other operator keys stay" has "$y" $'\nnode.name: a\n'
before=$(md5sum < "$yml")
elasticsearch_strip_managed "$yml"
elasticsearch_write_performance_block "$yml"
check "ES: a re-run writes the same bytes (no extra restart)" eq "$(md5sum < "$yml")" "$before"
check "ES: the restart is the existing changed-block path" \
  has "$(declare -f optimize_elastic)" 'opt_restart_service elasticsearch'


# ---------------------------------------------------------------------------
# DB9 (1.22.14): table-locking application tables move to InnoDB
# ---------------------------------------------------------------------------
# The stub answers the candidate query from $TMP/innodb.rows and records
# every ALTER; $TMP/innodb.fail lists "table busy|refused" ALTERs that fail.
ic_run() { # dry -> report/plan lines ; ALTERs in $TMP/innodb.alters
  (
    : > "$TMP/innodb.alters"
    mariadb() {
      local sql=${*: -1}
      case $sql in
        *information_schema.tables*) [[ -f $TMP/innodb.down ]] && return 1; cat "$TMP/innodb.rows" ;;
        *"ALTER TABLE"*)
          printf '%s\n' "$sql" >> "$TMP/innodb.alters"
          local f k; while read -r f k; do
            [[ -n $f && $sql == *"\`${f}\`"* ]] || continue
            case $k in
              busy) echo 'ERROR 1205 (HY000) at line 1: Lock wait timeout exceeded; try restarting transaction' >&2 ;;
              *)    printf -- '--------------\nSET SESSION lock_wait_timeout = 2; ALTER TABLE x\n--------------\n\nERROR 1075 (42000) at line 1: Incorrect table definition; there can be only one auto column and it must be defined as a key\nsecond line\n' >&2 ;;
            esac
            return 1
          done < <(cat "$TMP/innodb.fail" 2>/dev/null)
          return 0 ;;
      esac
    }
    OPT_REPORT=()
    opt_report() { printf 'R %s\n' "$*"; }
    mariadb_innodb_convert "$1"
  )
}
printf 'xf\txf_session_activity\tMEMORY\t33\t0\nxf\txf_search_index\tMyISAM\t900\t1\nwp\twp_big\tMyISAM\t5000\t0\nwp\twp_opts\tAria\t2\t0\nchev\tchv_x\tMyISAM\t1\t0\n' > "$TMP/innodb.rows"
out=$(ic_run 0)
alters=$(cat "$TMP/innodb.alters")
check "innodb: MEMORY, Aria and MyISAM tables are altered to InnoDB" \
  bash -c '[[ $1 == *"\`xf\`.\`xf_session_activity\` ENGINE=InnoDB"* && $1 == *"\`wp\`.\`wp_opts\` ENGINE=InnoDB"* && $1 == *"\`chev\`.\`chv_x\` ENGINE=InnoDB"* ]]' _ "$alters"
check "innodb: each ALTER waits at most 2 s for its table lock" \
  bash -c '[[ $(grep -c "ALTER" <<<"$1") == $(grep -c "lock_wait_timeout = 2;" <<<"$1") ]]' _ "$alters"
check "innodb: a FULLTEXT table is not altered" lacks "$alters" "xf_search_index"
check "innodb: a table over the size cap is not altered" lacks "$alters" "wp_big"
check "innodb: the report names the moved tables" has "$out" "Moved to InnoDB (row locks instead of table locks): xf.xf_session_activity (MEMORY) wp.wp_opts (Aria) chev.chv_x (MyISAM)"
check "innodb: the report names the FULLTEXT table with the by-hand statement" \
  bash -c '[[ $1 == *"FULLTEXT index"*"ALTER TABLE <db>.<table> ENGINE=InnoDB"*"xf.xf_search_index"* ]]' _ "$out"
check "innodb: the report names the big table with its size" has "$out" "wp.wp_big (5000MB)"
out=$(SETUP_MARIADB_INNODB_MAX_MB=10000 ic_run 0)
check "innodb: SETUP_MARIADB_INNODB_MAX_MB raises the cap" has "$(cat "$TMP/innodb.alters")" "\`wp\`.\`wp_big\` ENGINE=InnoDB"
check "innodb: the ALTER drops an inherited row format (ROW_FORMAT=DEFAULT)" \
  bash -c '[[ $(grep -c "ALTER" <<<"$1") == $(grep -c "ENGINE=InnoDB ROW_FORMAT=DEFAULT" <<<"$1") ]]' _ "$alters"
printf 'wp_opts busy\nchv_x refused\n' > "$TMP/innodb.fail"
out=$(ic_run 0); rm -f "$TMP/innodb.fail"
check "innodb: a lock timeout is reported as busy, retried next run" \
  bash -c '[[ $1 == *"Not moved this run (table busy for 2 s; the next --optimize retries): wp.wp_opts"* && $1 != *"WARNING"*"wp.wp_opts"* ]]' _ "$out"
check "innodb: another refusal is a warning with MariaDB's first message line" \
  bash -c '[[ $1 == *"WARNING** MariaDB refused the move to InnoDB"*"chev.chv_x (ERROR 1075 (42000) at line 1: Incorrect table definition"* && $1 != *"second line"* ]]' _ "$out"
check "innodb: the other tables still move" has "$out" "Moved to InnoDB (row locks instead of table locks): xf.xf_session_activity (MEMORY)"
printf 'logs\tl2025\tMyISAM\t1\t0\t1\nlogs\tcache\tMEMORY\t1\t0\t1\n' > "$TMP/innodb.rows"
out=$(ic_run 0)
check "innodb: MyISAM tables of a schema with a MERGE table stay MyISAM" \
  bash -c '[[ $1 == *"MERGE table"*"logs.l2025"* && $(cat "$2") != *l2025* ]]' _ "$out" "$TMP/innodb.alters"
check "innodb: a MEMORY table next to a MERGE table still moves" has "$(cat "$TMP/innodb.alters")" "\`logs\`.\`cache\`"
printf 'xf\txf_session_activity\tMEMORY\t33\t0\t0\nxf\txf_search_index\tMyISAM\t900\t1\t0\nwp\twp_big\tMyISAM\t5000\t0\t0\nwp\twp_opts\tAria\t2\t0\t0\nchev\tchv_x\tMyISAM\t1\t0\t0\n' > "$TMP/innodb.rows"
out=$(ic_run 1)
check "innodb: the dry run lists the plan and alters nothing" \
  bash -c '[[ $1 == *"would move to InnoDB"*"xf.xf_session_activity (MEMORY)"* && ! -s $2 ]]' _ "$out" "$TMP/innodb.alters"
out=$(SETUP_MARIADB_INNODB=0 ic_run 0)
check "innodb: SETUP_MARIADB_INNODB=0 turns it off" \
  bash -c '[[ $1 == *"conversion off"* && ! -s $2 ]]' _ "$out" "$TMP/innodb.alters"
printf 'x`y\tt\tMyISAM\t1\t0\nok\tt;drop\tMyISAM\t1\t0\n' > "$TMP/innodb.rows"
out=$(ic_run 0)
check "innodb: unusual schema or table names are reported, never interpolated" \
  bash -c '[[ ! -s $2 && $1 == *"unusual names"* ]]' _ "$out" "$TMP/innodb.alters"
touch "$TMP/innodb.down"; out=$(ic_run 0); rm -f "$TMP/innodb.down"
check "innodb: a server that does not answer is reported, nothing altered" \
  bash -c '[[ $1 == *"not checked"* && ! -s $2 ]]' _ "$out" "$TMP/innodb.alters"
: > "$TMP/innodb.rows"; out=$(ic_run 0)
check "innodb: nothing to convert prints nothing" eq "$out" ""
ic_def=$(declare -f mariadb_innodb_candidates)
check "innodb: the candidate query skips MariaDB's own schemas" has "$ic_def" "NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')"
check "innodb: the candidate query skips views" has "$ic_def" "t.table_type = 'BASE TABLE'"
om_def=$(declare -f optimize_mariadb)
check "innodb: optimize_mariadb converts only on a running server, before the profile" \
  bash -c '[[ $1 == *"if (( active )); then"*"mariadb_innodb_convert"*"mariadb_compute_profile"* ]]' _ "$om_def"
printf '\nTOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
