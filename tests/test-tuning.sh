#!/usr/bin/env bash
# Unit tests for the hardware-aware tuning helpers in setup.sh.
# No root, no services and no system changes are required.
# Usage: bash tests/test-tuning.sh
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/angie"

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Load the helpers without running main().  Source first: setup.sh defines its
# own ok()/warn() logging helpers, so test helpers must be defined afterwards.
export SETUP_TEST_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/setup.sh"
# setup.sh installs an ERR trap for production diagnostics.  These tests
# deliberately exercise failure paths, so drop the trap; set -e still catches
# genuinely unexpected errors.
trap - ERR

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}

# ---------------------------------------------------------------------------
# Small pure helpers
# ---------------------------------------------------------------------------
check "tune_clamp lower bound"  test "$(tune_clamp 5 10 20)" = 10
check "tune_clamp upper bound"  test "$(tune_clamp 50 10 20)" = 20
check "tune_size_value whole GiB" test "$(tune_size_value 2048)" = 2G
check "tune_size_value MiB"       test "$(tune_size_value 1536)" = 1536M
check "mb_to_config whole GiB"    test "$(mb_to_config 4096)" = 4G
check "size_to_mb 2g"             test "$(size_to_mb 2g)" = 2048
check "cache budget rounds to 256 MB" test "$(tune_cache_total_mb 7747 19000)" = 768
check "cache budget is stable across small disk changes" \
  test "$(tune_cache_total_mb 7747 19000)" = "$(tune_cache_total_mb 7747 17700)"
check "Angie-only cache budget uses 50% RAM" \
  test "$(tune_cache_total_mb 7747 59000 50 10)" = 3840
check "Angie+PHP cache budget uses 30% RAM" \
  test "$(tune_cache_total_mb 7747 59000 30 5)" = 2304

# The shared helper must produce the same number the real tuner uses.
OPT_DETECTED=(angie)
check "Angie-only cache budget uses 50% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 1792
OPT_DETECTED=(angie php:8.5)
check "Angie+PHP cache budget uses 30% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 1024
OPT_DETECTED=(angie php:8.5 mariadb valkey elastic)
check "full-stack cache budget uses 25% RAM" \
  test "$(angie_cache_budget_mb 3815 57000)" = 768
OPT_DETECTED=()
check "no detected services uses the shared 25% default" \
  test "$(angie_cache_budget_mb 3815 57000)" = 768

# ---------------------------------------------------------------------------
# SSH/firewall helpers
# ---------------------------------------------------------------------------
check "SSH peer parser uses the client column, not the server address" \
  test "$(printf 'ESTAB 0 0 10.0.0.5:22 203.0.113.9:54321\n' | ssh_peer_from_ss ':22$')" = \
       "203.0.113.9"
# `ss -tnH state established` on Ubuntu 26.04 omits the State column, so the
# same parser must work with four fields as well.
check "SSH peer parser handles ss output without a state column" \
  test "$(printf '0 0 10.0.0.5:22 203.0.113.9:54321\n' | ssh_peer_from_ss ':22$')" = \
       "203.0.113.9"
check "SSH peer parser ignores non-SSH local ports" \
  test -z "$(printf 'ESTAB 0 0 10.0.0.5:443 198.51.100.7:40000\n' | ssh_peer_from_ss ':22$')"
check "SSH peer parser handles bracketed IPv6 peers" \
  test "$(printf 'ESTAB 0 0 [2001:db8::5]:22 [2001:db8::9]:54321\n' | ssh_peer_from_ss ':22$')" = \
       "2001:db8::9"
check "SSH peer parser drops loopback peers" \
  test -z "$(printf 'ESTAB 0 0 10.0.0.5:22 127.0.0.1:5000\n' | ssh_peer_from_ss ':22$')"

ssh_ports_ok() {
  local p n=0
  while IFS= read -r p; do
    [[ $p =~ ^[0-9]+$ ]] || return 1
    n=$((n + 1))
  done < <(sshd_listen_ports)
  (( n > 0 ))
}
check "sshd port discovery always returns at least one numeric port" ssh_ports_ok

# The probe must agree with sysfs; a VM that only offers powersave/schedutil
# must not make --optimize claim it set the performance governor.
gov_dir=/sys/devices/system/cpu/cpu0/cpufreq
if [[ -d $gov_dir ]] && grep -qw performance "$gov_dir/scaling_available_governors" 2>/dev/null; then
  check "CPU governor probe finds the performance governor" \
    cpu_performance_governor_available
elif [[ -d $gov_dir ]]; then
  if cpu_performance_governor_available; then
    t_fail "CPU governor probe ignores an unavailable performance governor"
  else
    t_pass "CPU governor probe ignores an unavailable performance governor"
  fi
else
  if cpu_performance_governor_available; then
    t_fail "CPU governor probe reports performance without a cpufreq interface"
  else
    t_pass "CPU governor probe reports no cpufreq interface"
  fi
fi

# The single-file fallback must stay byte-identical to the canonical profile,
# otherwise a run without configs/ silently writes values we already removed
# (for example the boot-time route.flush errors).
check "embedded sysctl fallback matches configs/system/sysctl.conf" \
  diff -q <(blob_sysctl) "$ROOT/configs/system/sysctl.conf"

# ---------------------------------------------------------------------------
# Optimize OS gate and fd-limit profile
# ---------------------------------------------------------------------------
check "optimize supports Ubuntu 22.04" optimize_os_supported 22.04
check "optimize supports Ubuntu 24.04" optimize_os_supported 24.04
check "optimize supports Ubuntu 26.04" optimize_os_supported 26.04
if optimize_os_supported 20.04; then
  t_fail "optimize rejects Ubuntu 20.04"
else
  t_pass "optimize rejects Ubuntu 20.04"
fi
check "PAM nofile does not exceed the minimum fs.nr_open" \
  bash -c "! grep -q '10485760' '$ROOT/configs/system/limits.conf'"

# ---------------------------------------------------------------------------
# tune_replace / tune_insert_after reporting
# ---------------------------------------------------------------------------
printf 'listen.owner = www-data\n' > "$TMP/pool.conf"
tune_reset_changes
tune_replace "$TMP/pool.conf" 'listen\.owner = www-data' 'listen.owner = nginx' "test replace"
check "tune_replace rewrites a matching directive" \
  grep -qx 'listen.owner = nginx' "$TMP/pool.conf"
check "tune_replace marks configuration dirty" test "$TUNE_DIRTY" -eq 1
check "tune_replace records the change" test "${#TUNE_CHANGES[@]}" -eq 1

tune_reset_changes
tune_replace "$TMP/pool.conf" 'absent_directive = [0-9]+' 'absent_directive = 1' "missing test"
check "tune_replace records a miss instead of failing silently" \
  test "${#TUNE_MISSES[@]}" -eq 1
check "a miss does not mark configuration dirty" test "$TUNE_DIRTY" -eq 0

tune_reset_changes
tune_replace "$TMP/does-not-exist.conf" 'x = 1' 'x = 2' "missing file test"
check "tune_replace records a missing file as a miss" \
  test "${#TUNE_MISSES[@]}" -eq 1

check "tune_first_file prefers the current file name" \
  test "$(mkdir -p "$TMP/pick" && : > "$TMP/pick/fastcgi_cache.conf" && : > "$TMP/pick/fastcgi_cache_conf" && tune_first_file "$TMP/pick" fastcgi_cache.conf fastcgi_cache_conf)" = \
       "$TMP/pick/fastcgi_cache.conf"
rm -f "$TMP/pick/fastcgi_cache.conf"
check "tune_first_file falls back to the legacy _conf layout" \
  test "$(tune_first_file "$TMP/pick" fastcgi_cache.conf fastcgi_cache_conf)" = \
       "$TMP/pick/fastcgi_cache_conf"

# ---------------------------------------------------------------------------
# tune_insert_after anchors on the block opener
# ---------------------------------------------------------------------------
printf 'http2 on;\nhttp {\n}\n' > "$TMP/anchor.conf"
tune_reset_changes
tune_insert_after "$TMP/anchor.conf" '^[[:space:]]*http[[:space:]]*[{]' \
  '  client_body_buffer_size 256k;' "test insert"
check "tune_insert_after inserts after the http block opener" \
  test "$(awk '/^http \{/{getline; print}' "$TMP/anchor.conf")" = \
       '  client_body_buffer_size 256k;'
check "tune_insert_after leaves http2 on intact" \
  grep -qx 'http2 on;' "$TMP/anchor.conf"

# ---------------------------------------------------------------------------
# Error-response cache policy (applies to old installs during --optimize)
# ---------------------------------------------------------------------------
cat > "$TMP/cache-policy.conf" <<'EOF'
fastcgi_cache_valid any 5s;
fastcgi_cache_use_stale error timeout updating http_500 http_503;
EOF
tune_reset_changes
tune_cache_error_policy "$TMP/cache-policy.conf" "test cache"
check "error policy removes http_500 from use_stale" \
  bash -c "! grep -q 'http_500' '$TMP/cache-policy.conf'"
check "error policy keeps http_503 stale handling" \
  grep -q 'http_503' "$TMP/cache-policy.conf"
check "error policy disables caching of 5xx responses" \
  grep -qx 'fastcgi_cache_valid 500 502 503 504 0s;' "$TMP/cache-policy.conf"
check "error policy records the change" test "${#TUNE_CHANGES[@]}" -eq 1

tune_reset_changes
tune_cache_error_policy "$TMP/cache-policy.conf" "test cache"
check "error policy is idempotent" test "${#TUNE_CHANGES[@]}" -eq 0
check "error policy keeps a single 5xx rule" \
  test "$(grep -c 'fastcgi_cache_valid 500' "$TMP/cache-policy.conf")" -eq 1

# ---------------------------------------------------------------------------
# Angie tuning against the repository fixture
# ---------------------------------------------------------------------------
mkdir -p "$TMP/angie"
cp -a "$FIXTURES/." "$TMP/angie/"
OPT_PHP_OK=1
OPT_PHP_SOCKET=/run/php/php-fpm.sock
OPT_DETECTED=(angie php:8.3 mariadb valkey elastic)
tune_reset_changes
tune_angie_configs "$TMP/angie"

check "angie.conf FastCGI upstream moves to the shared socket" \
  grep -q 'server unix:/run/php/php-fpm.sock;' "$TMP/angie/angie.conf"
check "angie.conf keeps exactly one client_body_buffer_size" \
  test "$(grep -c '^[[:space:]]*client_body_buffer_size' "$TMP/angie/angie.conf")" -eq 1
mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
if (( mem_kb < 2048 * 1024 )); then
  exp_body_buffer=64k
elif (( mem_kb < 8192 * 1024 )); then
  exp_body_buffer=128k
else
  exp_body_buffer=256k
fi
check "client_body_buffer_size is inside the http block and sized for RAM" \
  test "$(awk '/^http \{/{getline; print}' "$TMP/angie/angie.conf")" = \
       "  client_body_buffer_size ${exp_body_buffer};"
check "worker_rlimit_nofile is inserted after worker_processes" \
  test "$(awk '/^worker_processes/{getline; print}' "$TMP/angie/angie.conf")" = \
       "$(grep 'worker_rlimit_nofile' "$TMP/angie/angie.conf")"

# Multi-line proxy_cache_path directives must have their max_size rewritten.
if grep -q 'max_size=16g' "$TMP/angie/http.d/proxy_cache.conf"; then
  t_fail "proxy_cache.conf max_size is updated on continuation lines"
else
  t_pass "proxy_cache.conf max_size is updated on continuation lines"
fi
check "proxy_cache.conf keeps both cache paths" \
  test "$(grep -c '^proxy_cache_path' "$TMP/angie/http.d/proxy_cache.conf")" -eq 2
check "fastcgi_cache zone is resized" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/angie/http.d/fastcgi_cache.conf"
check "fastcgi_cache_chev gains a max_size" \
  grep -qE 'keys_zone=fastcgicache_chev:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/angie/http.d/fastcgi_cache_chev.conf"
check "tuning preserves use_temp_path=off on the FastCGI cache" \
  grep -q 'use_temp_path=off' "$TMP/angie/http.d/fastcgi_cache.conf"
check "tuning preserves use_temp_path=off on the XenForo proxy cache" \
  grep -q 'use_temp_path=off' "$TMP/angie/http.d/xf_proxy_cache.conf"
check "PHP fastcgi buffers are tuned" \
  grep -qE '^fastcgi_busy_buffers_size [0-9]+[mk];' "$TMP/angie/h5bp/php.conf"

# A second identical run must not report any changes (idempotency).
tune_reset_changes
tune_angie_configs "$TMP/angie"
check "second tune run is a no-op" test "$TUNE_DIRTY" -eq 0

# A pool that stays on TCP must leave Angie's TCP upstream alone.
mkdir -p "$TMP/angie-tcp"
cp -a "$FIXTURES/." "$TMP/angie-tcp/"
OPT_PHP_SOCKET=""
tune_reset_changes
tune_angie_configs "$TMP/angie-tcp"
check "TCP FastCGI upstream is preserved when PHP stays on TCP" \
  grep -q '^[[:space:]]*server 127.0.0.1:9000;' "$TMP/angie-tcp/angie.conf"

# An active .conf file must win over an inert _conf leftover with the same zone.
mkdir -p "$TMP/active"
cp -a "$FIXTURES/." "$TMP/active/"
cat > "$TMP/active/http.d/fastcgi_cache.conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache levels=1:2 keys_zone=fastcgicache:256m inactive=8h;
EOF
cat > "$TMP/active/http.d/fastcgi_cache_conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache levels=1:2 keys_zone=fastcgicache:256m max_size=16g inactive=1h;
EOF
OPT_PHP_SOCKET=""
tune_reset_changes
tune_angie_configs "$TMP/active"
check "active fastcgi_cache.conf gains a max_size" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+M' \
  "$TMP/active/http.d/fastcgi_cache.conf"
check "inert legacy fastcgi_cache_conf is left untouched" \
  grep -q 'max_size=16g' "$TMP/active/http.d/fastcgi_cache_conf"

# ---------------------------------------------------------------------------
# Legacy underscore layouts (older server-configs-nginx deployments)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/legacy"
cp -a "$FIXTURES/." "$TMP/legacy/"
for name in fastcgi_cache fastcgi_cache_chev xf_proxy_cache proxy_cache limit_req; do
  mv "$TMP/legacy/http.d/${name}.conf" "$TMP/legacy/http.d/${name}_conf"
done
sed -i 's#include http.d/\*\.conf;#include http.d/*_conf;#' "$TMP/legacy/angie.conf"
cat > "$TMP/legacy/http.d/fastcgi_cache_custom_conf" <<'EOF'
fastcgi_cache_path /home/nginx_cache_custom levels=1:2 keys_zone=customcache:5120m inactive=30d;
EOF
cat > "$TMP/legacy/http.d/proxy_cache_extra_conf" <<'EOF'
proxy_cache_path /home/proxy_extra levels=1:2 keys_zone=extracache:128m max_size=512g inactive=30d;
EOF
tune_reset_changes
tune_angie_configs "$TMP/legacy"
check "legacy fastcgi_cache_conf is resized in place" \
  grep -qE 'keys_zone=fastcgicache:[0-9]+m max_size=[0-9]+[MG]' \
  "$TMP/legacy/http.d/fastcgi_cache_conf"
check "legacy limit_req_conf zones are resized in place" \
  grep -qE 'zone=limit_req_post_head:[0-9]+m' "$TMP/legacy/http.d/limit_req_conf"
check "legacy tuning does not create a duplicate .conf file" \
  test ! -e "$TMP/legacy/http.d/fastcgi_cache.conf"
custom_zone=$(grep -oE 'keys_zone=customcache:[0-9]+m' \
  "$TMP/legacy/http.d/fastcgi_cache_custom_conf" | head -n1 | sed 's/.*://; s/m$//')
check "custom 5G cache zone is capped" test "$custom_zone" -le 128
check "custom unbounded cache gains a max_size" \
  grep -qE 'keys_zone=customcache:[0-9]+m .*max_size=[0-9]+M' \
  "$TMP/legacy/http.d/fastcgi_cache_custom_conf"
extra_max=$(grep -oE 'max_size=[0-9]+[mM]' \
  "$TMP/legacy/http.d/proxy_cache_extra_conf" | head -n1 | sed 's/.*=//; s/[mM]$//')
check "custom proxy cache max_size is capped" test "$extra_max" -le 1024
tune_reset_changes
tune_angie_configs "$TMP/legacy"
check "legacy layout second run is a no-op" test "$TUNE_DIRTY" -eq 0

# A host with only one active cache type gets the whole cache budget.
cache_mem_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
cache_disk_mb=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || true)
[[ $cache_disk_mb =~ ^[0-9]+$ ]] || cache_disk_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[[ $cache_disk_mb =~ ^[0-9]+$ ]] || cache_disk_mb=10240
expected_cache_angie=$(tune_cache_total_mb "$cache_mem_mb" "$cache_disk_mb" 50 10)
expected_cache_php=$(tune_cache_total_mb "$cache_mem_mb" "$cache_disk_mb" 30 5)

mkdir -p "$TMP/xfonly"
cp -a "$FIXTURES/." "$TMP/xfonly/"
rm -f "$TMP/xfonly/http.d/fastcgi_cache.conf" \
      "$TMP/xfonly/http.d/fastcgi_cache_chev.conf" \
      "$TMP/xfonly/http.d/proxy_cache.conf" \
      "$TMP/xfonly/http.d/limit_req.conf"
OPT_PHP_SOCKET=""
OPT_DETECTED=(angie)
tune_reset_changes
tune_angie_configs "$TMP/xfonly"
check "proxy-only host gives the whole Angie-only budget to xfproxycache" \
  grep -q "max_size=$(tune_size_value "$expected_cache_angie")" \
  "$TMP/xfonly/http.d/xf_proxy_cache.conf"

mkdir -p "$TMP/fcgionly"
cp -a "$FIXTURES/." "$TMP/fcgionly/"
rm -f "$TMP/fcgionly/http.d/fastcgi_cache_chev.conf" \
      "$TMP/fcgionly/http.d/proxy_cache.conf" \
      "$TMP/fcgionly/http.d/xf_proxy_cache.conf" \
      "$TMP/fcgionly/http.d/limit_req.conf"
OPT_PHP_SOCKET=""
OPT_DETECTED=(angie php:8.3)
tune_reset_changes
tune_angie_configs "$TMP/fcgionly"
check "PHP-only host gives the whole Angie+PHP budget to fastcgicache" \
  grep -q "max_size=$(tune_size_value "$expected_cache_php")" \
  "$TMP/fcgionly/http.d/fastcgi_cache.conf"

# ---------------------------------------------------------------------------
# PHP pool helpers
# ---------------------------------------------------------------------------
cat > "$TMP/www.conf" <<'EOF'
[www]
pm.max_children = 5
rlimit_files = 1024
pm.max_children = 9
EOF
tune_reset_changes
tune_pool_set "$TMP/www.conf" pm.max_children 64 "test pool set"
check "tune_pool_set writes the new value" \
  grep -qx 'pm.max_children = 64' "$TMP/www.conf"
tune_pool_dedupe "$TMP/www.conf" pm.max_children rlimit_files
check "tune_pool_dedupe keeps one pm.max_children" \
  test "$(grep -c '^pm.max_children' "$TMP/www.conf")" -eq 1
check "tune_pool_dedupe keeps the value set by tune_pool_set" \
  grep -qx 'pm.max_children = 64' "$TMP/www.conf"

# ---------------------------------------------------------------------------
# Shared memory budget
# ---------------------------------------------------------------------------
mem_total_mb() { printf '131072'; }
mariadb_data_size_mb() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "PHP budget is at most 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 131072 * 50 / 100 ))
check "service budgets stay under 95% of RAM" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 131072 * 95 / 100 ))
check "all fixed budgets are positive" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0 -a "$OPT_VALKEY_BUDGET_MB" -gt 0 -a "$OPT_ES_BUDGET_MB" -gt 0

# A 64 GB host with a 128-worker PHP pool must keep that capacity; the data
# services are fitted into what remains after the PHP reservation.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
plan_memory_budget
check "PHP budget preserves a 128-worker pool" \
  test "$OPT_PHP_BUDGET_MB" -ge $(( 128 * 96 ))
check "PHP budget is still capped at 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 65536 * 50 / 100 ))
check "Redis enables the shared cache budget" \
  test "$OPT_VALKEY_BUDGET_MB" -gt 0
check "PHP-first plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# The planner must use the same 8-worker floor as tune_php_fpm_version().
php_pool_max_children() { printf '6'; }
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.3 mariadb)
plan_memory_budget
check "PHP budget uses the 8-worker floor" \
  test "$OPT_PHP_BUDGET_MB" -ge 768
check "MariaDB gets the remaining budget after the PHP floor" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0

# Restore the 128-worker context used by the database/index cases below.
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# The buffer pool should hold the live data+index working set when possible.
mariadb_data_size_mb() { printf '20000'; }
plan_memory_budget
check "buffer pool covers a 20 GB database" \
  test "$OPT_MARIADB_BUDGET_MB" -ge 20000
check "database-fit plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# A freshly installed database can be only a few MB.  Do not collapse the
# buffer pool on a large host; keep a 1/16-RAM floor (capped at 8 GB).
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '81'; }
elasticsearch_data_size_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "tiny fresh database keeps the hardware-scaled floor" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 8192
check "tiny database floor stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Restore the 64 GB context for the oversized-database cases below.
mem_total_mb() { printf '65536'; }
mariadb_current_pool_mb() { printf '0'; }
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# A database larger than the remaining budget gets the largest feasible pool.
mariadb_data_size_mb() { printf '40960'; }
plan_memory_budget
check "oversized database gets the budget-limited buffer pool" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 20000 -a "$OPT_MARIADB_BUDGET_MB" -lt 32768
check "oversized database is not falsely reported as fitting" \
  test "$OPT_DB_SIZE_MB" -eq 40960 -a "$OPT_MARIADB_BUDGET_MB" -lt 40960

# On a large host the pool follows the live working set plus 5% headroom.
mem_total_mb() { printf '262144'; }
mariadb_current_pool_mb() { printf '73728'; }
mariadb_data_size_mb() { printf '73599'; }
elasticsearch_data_size_mb() { printf '0'; }
OPT_DETECTED=(angie php:8.4 mariadb valkey)
plan_memory_budget
check "large host sizes the pool to data+5%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278
check "data-sized pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0
check "data-sized pool keeps the plan inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# Tiny statistics drift must not change the planned size on every run.
mariadb_current_pool_mb() { printf '77300'; }
plan_memory_budget
check "small statistics drift keeps the live pool" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77300

# An oversized live pool is reduced to the data-sized target.
mariadb_current_pool_mb() { printf '120000'; }
plan_memory_budget
check "oversized live pool is reduced to data+5%" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278
check "shrunk pool is not marked as preserved" \
  test "$OPT_MARIADB_KEPT_MB" -eq 0

# A pool that would exceed the shared budget is capped.
mariadb_current_pool_mb() { printf '200000'; }
plan_memory_budget
check "pool above the shared budget is capped to the target" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 77278

# A database larger than the shared budget receives the capped pool.
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '300000'; }
plan_memory_budget
check "database larger than the shared budget is capped" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 189235
check "capped data-sized plan still fits the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 262144 * 80 / 100 ))

# A MariaDB-only host reserves no PHP budget; a database larger than 80% of
# RAM can use the whole usable budget, while the data+5% target still applies.
mem_total_mb() { printf '65536'; }
php_pool_max_children() { printf '0'; }
mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '60000'; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only host reserves no PHP budget" \
  test "$OPT_PHP_BUDGET_MB" -eq 0
check "MariaDB-only large database can use the full 80% budget" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 52428

# Unknown data size falls back to the larger MariaDB-only share.
mariadb_data_size_mb() { printf '0'; }
OPT_DETECTED=(mariadb)
plan_memory_budget
check "MariaDB-only unknown data falls back to 80% RAM" \
  test "$OPT_MARIADB_BUDGET_MB" -eq 52428

# Valkey gets a larger share when no database/search tier shares the host.
mariadb_data_size_mb() { printf '0'; }
OPT_DETECTED=(valkey)
plan_memory_budget
check "Valkey-only budget uses 50% of RAM" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 32768
php_pool_max_children() { printf '128'; }
OPT_DETECTED=(angie php:8.3 valkey)
plan_memory_budget
check "Angie+PHP+Valkey budget uses 25% of RAM" \
  test "$OPT_VALKEY_BUDGET_MB" -eq 16384

# Elasticsearch-only fallback when the index size is unknown.
elasticsearch_data_size_mb() { printf '0'; }
elasticsearch_current_heap_mb() { printf '0'; }
OPT_DETECTED=(elastic)
plan_memory_budget
check "Elasticsearch-only unknown index falls back to 50% RAM" \
  test "$OPT_ES_BUDGET_MB" -eq 31744

mariadb_current_pool_mb() { printf '0'; }
mariadb_data_size_mb() { printf '20000'; }
php_pool_max_children() { printf '128'; }
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# Elasticsearch heap follows the live index store size.
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '0'; }
plan_memory_budget
check "small Elasticsearch index uses index+5%" \
  test "$OPT_ES_BUDGET_MB" -eq 4608
check "Elasticsearch index size is recorded" \
  test "$OPT_ES_SIZE_MB" -eq 4096

elasticsearch_data_size_mb() { printf '20000'; }
plan_memory_budget
check "large Elasticsearch index gets index+5% headroom" \
  test "$OPT_ES_BUDGET_MB" -eq 21504
check "Elasticsearch heap fits the 20 GB index" \
  test "$OPT_ES_BUDGET_MB" -ge 20000
check "Elasticsearch plan stays inside the 80% budget" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 65536 * 80 / 100 ))

# A huge index is capped at the 31 GB compressed-oops ceiling.
mem_total_mb() { printf '262144'; }
OPT_DETECTED=(angie php:8.4 elastic)
elasticsearch_data_size_mb() { printf '100000'; }
plan_memory_budget
check "Elasticsearch heap is capped at 31 GB" \
  test "$OPT_ES_BUDGET_MB" -eq 31744
check "Elasticsearch index size is recorded for huge stores" \
  test "$OPT_ES_SIZE_MB" -eq 100000

# An oversized live heap is reduced to the data-sized target.
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
mariadb_data_size_mb() { printf '20000'; }
elasticsearch_data_size_mb() { printf '13000'; }
elasticsearch_current_heap_mb() { printf '20000'; }
plan_memory_budget
check "oversized Elasticsearch heap is reduced to index+5%" \
  test "$OPT_ES_BUDGET_MB" -eq 13824
check "shrunk Elasticsearch heap is not marked as preserved" \
  test "$OPT_ES_KEPT_MB" -eq 0

# Small statistics drift must not change the heap on every run.
elasticsearch_current_heap_mb() { printf '14000'; }
plan_memory_budget
check "Elasticsearch statistics drift keeps the live heap" \
  test "$OPT_ES_BUDGET_MB" -eq 14000

# A heap that would exceed the shared budget is capped.
mem_total_mb() { printf '65536'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)
mariadb_data_size_mb() { printf '40000'; }
elasticsearch_data_size_mb() { printf '4096'; }
elasticsearch_current_heap_mb() { printf '30000'; }
plan_memory_budget
check "Elasticsearch heap above the shared budget is capped" \
  test "$OPT_ES_BUDGET_MB" -eq 4608

elasticsearch_current_heap_mb() { printf '0'; }
elasticsearch_data_size_mb() { printf '0'; }
mariadb_data_size_mb() { printf '20000'; }
OPT_DETECTED=(angie php:8.3 mariadb redis elastic)

# ---------------------------------------------------------------------------
# Single-node Elasticsearch replica detection
# ---------------------------------------------------------------------------
check "single-node yellow replica issue is detected" \
  elasticsearch_single_node_replica_issue \
    '{"status":"yellow","number_of_nodes":1,"unassigned_shards":1,"unassigned_primary_shards":0}'
if elasticsearch_single_node_replica_issue \
     '{"status":"green","number_of_nodes":1,"unassigned_shards":0,"unassigned_primary_shards":0}'; then
  t_fail "green cluster is not treated as a replica issue"
else
  t_pass "green cluster is not treated as a replica issue"
fi
if elasticsearch_single_node_replica_issue \
     '{"status":"yellow","number_of_nodes":2,"unassigned_shards":1,"unassigned_primary_shards":0}'; then
  t_fail "multi-node yellow cluster is not auto-modified"
else
  t_pass "multi-node yellow cluster is not auto-modified"
fi
if elasticsearch_single_node_replica_issue \
     '{"status":"yellow","number_of_nodes":1,"unassigned_shards":1,"unassigned_primary_shards":1}'; then
  t_fail "unassigned primary shard is not treated as a replica issue"
else
  t_pass "unassigned primary shard is not treated as a replica issue"
fi

# ---------------------------------------------------------------------------
# WordPress vhost detection
# ---------------------------------------------------------------------------
mkdir -p "$TMP/wpangie/conf.d" "$TMP/wpangie/h5bp" "$TMP/wpangie/www/site/public"
: > "$TMP/wpangie/www/site/public/wp-config.php"
printf 'server {\n  root %s;\n  include h5bp/php_wp.conf;\n}\n' \
  "$TMP/wpangie/www/site/public" > "$TMP/wpangie/conf.d/site.conf"
check "WordPress vhost detection finds a real installation" \
  test "$(angie_wordpress_vhosts "$TMP/wpangie")" = "$TMP/wpangie/conf.d/site.conf"
rm -f "$TMP/wpangie/www/site/public/wp-config.php"
check "WordPress vhost detection ignores a missing wp-config" \
  test -z "$(angie_wordpress_vhosts "$TMP/wpangie")"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
