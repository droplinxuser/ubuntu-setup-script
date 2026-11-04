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
# Angie tuning against the repository fixture
# ---------------------------------------------------------------------------
mkdir -p "$TMP/angie"
cp -a "$FIXTURES/." "$TMP/angie/"
OPT_PHP_OK=1
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
check "PHP fastcgi buffers are tuned" \
  grep -qE '^fastcgi_busy_buffers_size [0-9]+[mk];' "$TMP/angie/h5bp/php.conf"

# A second identical run must not report any changes (idempotency).
tune_reset_changes
tune_angie_configs "$TMP/angie"
check "second tune run is a no-op" test "$TUNE_DIRTY" -eq 0

# ---------------------------------------------------------------------------
# Legacy underscore layouts (older server-configs-nginx deployments)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/legacy"
cp -a "$FIXTURES/." "$TMP/legacy/"
for name in fastcgi_cache fastcgi_cache_chev xf_proxy_cache proxy_cache limit_req; do
  mv "$TMP/legacy/http.d/${name}.conf" "$TMP/legacy/http.d/${name}_conf"
done
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
OPT_DETECTED=(angie php:8.4 mariadb valkey elastic)
plan_memory_budget
check "PHP budget is at most 50% of RAM" \
  test "$OPT_PHP_BUDGET_MB" -le $(( 131072 * 50 / 100 ))
check "service budgets stay under 95% of RAM" \
  test $(( OPT_PHP_BUDGET_MB + OPT_MARIADB_BUDGET_MB + OPT_VALKEY_BUDGET_MB + OPT_ES_BUDGET_MB )) \
       -le $(( 131072 * 95 / 100 ))
check "all fixed budgets are positive" \
  test "$OPT_MARIADB_BUDGET_MB" -gt 0 -a "$OPT_VALKEY_BUDGET_MB" -gt 0 -a "$OPT_ES_BUDGET_MB" -gt 0

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
