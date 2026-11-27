#!/usr/bin/env bash
# Unit tests for the 1.22.5 read-only verification reports (lib/diagnostics.sh)
# and the PHP OPcache opt-ins (lib/web.sh): CPU frequency
# driver, NIC queues/IRQs, LimitNOFILE next to each service's own limit,
# Valkey INFO over its unix socket, the effective FPM OPcache/JIT probe, the
# --optimize "Verify" block, vhost certificate expiry, SETUP_PHP_OPCACHE_*
# persistence, and the Chevereto upload limit.
# No root, no services and no system changes are required: /proc, /sys and
# /etc are fixtures (DIAG_PROC / DIAG_SYS / DIAG_ETC), every client is a stub
# script, and scratch data stays under /tmp.
# Usage: bash tests/unit/t-report.sh
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
SKIP=0
TMP=$(mktemp -d /tmp/setup-test-report.XXXXXX)

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
unset SETUP_PHP_OPCACHE_FILE_OVERRIDE PHP_OPCACHE_FILE_OVERRIDE
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-report.sh,title=Report test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

# ---------------------------------------------------------------------------
# kTLS removed (1.22.5): no tls_stat section, no Verify line
# ---------------------------------------------------------------------------
check "diagnostics: no kTLS / tls_stat section or Verify line left" \
  bash -c '! grep -qiE "ktls|tls_stat" "$1"' _ "$ROOT/lib/diagnostics.sh"

# ---------------------------------------------------------------------------
# CPU frequency driver
# ---------------------------------------------------------------------------
S=$TMP/sys
mkdir -p "$S/devices/system/cpu/cpu0/cpufreq" "$S/devices/system/cpu/amd_pstate" "$S/devices/system/cpu/cpufreq"
echo amd-pstate-epp > "$S/devices/system/cpu/cpu0/cpufreq/scaling_driver"
echo performance > "$S/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"
echo active > "$S/devices/system/cpu/amd_pstate/status"
echo 1 > "$S/devices/system/cpu/cpufreq/boost"
out=$(DIAG_SYS=$S diag_cpufreq)
check "cpufreq: driver read" has "$out" "cpu0/cpufreq/scaling_driver: amd-pstate-epp"
check "cpufreq: EPP read" has "$out" "energy_performance_preference: performance"
check "cpufreq: amd_pstate status read" has "$out" "amd_pstate/status: active"
check "cpufreq: boost read" has "$out" "cpufreq/boost: 1"
check "cpufreq: missing intel_pstate is marked absent" has "$out" "intel_pstate/no_turbo: (absent)"

# ---------------------------------------------------------------------------
# NIC queues and IRQs
# ---------------------------------------------------------------------------
mkdir -p "$S/class/net/eth0/queues/rx-0" "$S/class/net/eth0/queues/rx-1" \
  "$S/class/net/eth0/queues/tx-0" "$S/class/net/eth0/queues/tx-1" "$S/class/net/lo/queues/rx-0"
P=$TMP/procn
mkdir -p "$P/irq/40" "$P/irq/41"
cat > "$P/interrupts" <<'EOF'
           CPU0       CPU1
  0:         10          0   IO-APIC   2-edge      timer
 40:        100        200   PCI-MSI 1-edge      eth0-TxRx-0
 41:          5          7   PCI-MSI 2-edge      eth0-TxRx-1
 42:          1          1   PCI-MSI 3-edge      nvme0q0
EOF
echo 0 > "$P/irq/40/smp_affinity_list"
echo 1 > "$P/irq/41/smp_affinity_list"
systemctl() { [[ $* == *"is-active irqbalance"* ]] && { echo inactive; return 3; }; return 0; }
out=$(DIAG_SYS=$S DIAG_PROC=$P diag_nic_queues)
check "NIC: queue counts per device" has "$out" "--- eth0: 2 rx / 2 tx queues"
check "NIC: lo is skipped" lacks "$out" "--- lo"
check "NIC: per-queue IRQ with total and CPUs" has "$out" "IRQ 40 eth0-TxRx-0: 300 interrupts, CPUs 0"
check "NIC: second queue IRQ" has "$out" "IRQ 41 eth0-TxRx-1: 12 interrupts, CPUs 1"
check "NIC: other devices' IRQs are not listed" lacks "$out" "nvme0q0"
check "NIC: irqbalance state printed" has "$out" "irqbalance: inactive"
unset -f systemctl

# ---------------------------------------------------------------------------
# LimitNOFILE next to each service's internal limit
# ---------------------------------------------------------------------------
E=$TMP/etc
mkdir -p "$E/nginx" "$E/php/8.4/fpm/pool.d" "$E/php/8.5/fpm/pool.d" "$E/valkey"
printf 'user www-data;\nworker_rlimit_nofile 262144; # tuned\nevents { }\n' > "$E/nginx/nginx.conf"
printf '[www]\nrlimit_files = 524288\n' > "$E/php/8.4/fpm/pool.d/www.conf"
printf '[www]\nrlimit_files = 2048000\n' > "$E/php/8.5/fpm/pool.d/www.conf"
printf 'port 0\nmaxclients 10000\n' > "$E/valkey/valkey.conf"
nofile_probe() (
  systemctl() {
    case "$*" in
      "show -p LimitNOFILE --value php8.5-fpm.service") echo 1048576 ;;
      "show -p LimitNOFILE --value "*) echo 524288 ;;
      "cat valkey-server.service") return 0 ;;
      "cat "*) return 1 ;;
    esac
  }
  diag_redis_cli() { return 1; }
  diag_mariadb_installed() { return 0; }
  diag_elasticsearch_installed() { return 0; }
  mariadb() { echo 524288; }
  timeout() { shift; "$@"; }  # the report wraps mariadb in timeout(1), which would exec the real client
  elasticsearch_http_url() { printf 'http://127.0.0.1:9200'; }
  curl() { printf '{"nodes":{"x":{"process":{"max_file_descriptors":65535}}}}'; }
  DIAG_ETC=$E diag_nofile_limits
)
out=$(nofile_probe)
check "nofile: nginx unit limit next to worker_rlimit_nofile" has "$out" "nginx.service: LimitNOFILE=524288, worker_rlimit_nofile=262144"
check "nofile: PHP rlimit_files per series" has "$out" "php8.4-fpm.service: LimitNOFILE=524288, rlimit_files=524288"
check "nofile: internal limit above LimitNOFILE warns" has "$out" "php8.5-fpm.service: LimitNOFILE=1048576, rlimit_files=2048000; WARN"
check "nofile: Valkey maxclients from the config when the server does not answer" has "$out" "valkey-server.service: LimitNOFILE=524288, maxclients=10000"
check "nofile: MariaDB open_files_limit" has "$out" "mariadb.service: LimitNOFILE=524288, open_files_limit=524288"
check "nofile: Elasticsearch max_file_descriptors from loopback _nodes/stats" has "$out" "elasticsearch.service: LimitNOFILE=524288, max_file_descriptors=65535"
out=$(
  systemctl() { [[ $1 == show ]] && echo 65535; [[ $1 == cat ]] && return 1; return 0; }
  diag_mariadb_installed() { return 1; }
  diag_elasticsearch_installed() { return 0; }
  elasticsearch_http_url() { printf 'http://192.0.2.10:9200'; }
  curl() { echo CALLED >&2; printf '{"max_file_descriptors":1}'; }
  DIAG_ETC=$TMP/none diag_nofile_limits 2>&1
)
check "nofile: a non-loopback Elasticsearch is never queried" lacks "$out" "CALLED"
check "nofile: Elasticsearch skipped when not reachable on loopback" has "$out" "max_file_descriptors not read"
check "nofile: --diagnostics runs the section" \
  bash -c 'sed -n "/^run_diagnostics()/,/^}/p" "$1" | grep -q "diag_nofile_limits"' _ "$ROOT/lib/diagnostics.sh"

# ---------------------------------------------------------------------------
# Valkey over its unix socket
# ---------------------------------------------------------------------------
FAKECLI=$TMP/fake-valkey-cli
cat > "$FAKECLI" <<'EOF'
#!/bin/bash
# fake valkey-cli: -s SOCK CMD...
[[ $1 == -s ]] && shift 2
case "$*" in
  "INFO server") printf '# Server\r\nvalkey_version:8.1.4\r\n' ;;
  "INFO "*) printf '# %s\r\nkey:1\r\n' "$2" ;;
  "CONFIG GET io-threads") printf 'io-threads\n4\n' ;;
  "CONFIG GET maxmemory") printf 'maxmemory\n1073741824\n' ;;
  "CONFIG GET maxmemory-policy") printf 'maxmemory-policy\nallkeys-lfu\n' ;;
  "CONFIG GET port") printf 'port\n0\n' ;;
  "CONFIG GET save") printf 'save\n%s\n' "${FAKE_SAVE-300 1}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKECLI"
vk_probe() (
  diag_redis_clis() { printf '%s\n' "$FAKECLI"; }
  diag_valkey_sockets() { printf '/run/valkey/valkey.sock\n'; }
  "$@"
)
out=$(vk_probe verify_valkey_lines)
check "Valkey verify: version, io-threads, maxmemory, policy" has "$out" "Valkey 8.1.4 (/run/valkey/valkey.sock): io-threads 4, maxmemory 1024MB, policy allkeys-lfu"
check "Valkey verify: RDB save schedule" has "$out" "RDB save 300 1"
check "Valkey verify: port 0 reads as socket-only" has "$out" "TCP port 0 (socket-only)"
out=$(FAKE_SAVE='' vk_probe verify_valkey_lines)
check "Valkey verify: empty save reads as off" has "$out" "RDB save off"
out=$(vk_probe diag_valkey_instances)
for sec in server memory persistence clients threads keyspace; do
  check "Valkey diagnostics: INFO ${sec} over the socket" has "$out" "-- INFO ${sec}"
done
check "Valkey diagnostics: CR stripped" lacks "$out" $'\r'
out=$(diag_redis_clis() { :; }; diag_valkey_instances)
check "Valkey diagnostics: no client named" has "$out" "no valkey-cli/redis-cli"
# diag_valkey_sockets needs a real socket file.
mkdir -p "$TMP/run/valkey" "$TMP/etcv/valkey"
if perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or exit 1' \
     "$TMP/run/valkey/valkey.sock" 2>/dev/null && [[ -S $TMP/run/valkey/valkey.sock ]]; then
  printf 'port 0\nunixsocket %s\n' "$TMP/run/valkey/valkey.sock" > "$TMP/etcv/valkey/valkey.conf"
  out=$(DIAG_ETC=$TMP/etcv DIAG_RUN=$TMP/run diag_valkey_sockets)
  check "Valkey sockets: configured socket listed once" test "$out" = "$TMP/run/valkey/valkey.sock"
else
  t_skip "Valkey sockets: perl could not create a unix socket"
fi
out=$(DIAG_ETC=$TMP/none DIAG_RUN=$TMP/none diag_valkey_sockets)
check "Valkey sockets: none without a socket (never assumes TCP 6379)" test -z "$out"
check "Valkey diagnostics: only read-only commands are sent" \
  bash -c '! sed -n "/^diag_valkey_instances()/,/^}/p;/^verify_valkey_lines()/,/^}/p" "$1" | grep -qE "CONFIG (SET|REWRITE)|FLUSH|SHUTDOWN|BGSAVE|DEBUG"' _ "$ROOT/lib/diagnostics.sh"

# ---------------------------------------------------------------------------
# Effective FPM OPcache/JIT
# ---------------------------------------------------------------------------
FAKEPHP=$TMP/fake-php
cat > "$FAKEPHP" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$PHP_INI_SCAN_DIR" "\$*" >> "$TMP/php-args"
for a; do [[ \$a == jit ]] && { printf on; exit 0; }; done
printf 'PHP 8.5.1, OPcache loaded, JIT on (tracing, buffer 64M), validate_timestamps=1\n'
EOF
chmod +x "$FAKEPHP"
op_probe() (
  systemctl() { [[ $* == "is-active --quiet php8.5-fpm" ]]; }
  diag_php_cli_for() { printf '%s' "$FAKEPHP"; }
  DIAG_PHP_ETC=$TMP/etcphp diag_php_effective_opcache "$@"
)
: > "$TMP/php-args"
out=$(op_probe 8.5 short)
check "OPcache probe: short line printed" has "$out" "PHP 8.5.1, OPcache loaded, JIT on"
probe_args=$(cat "$TMP/php-args")
check "OPcache probe: FPM php.ini and conf.d scan dir" has "$probe_args" "$TMP/etcphp/8.5/fpm/conf.d|-c $TMP/etcphp/8.5/fpm/php.ini"
check "OPcache probe: JIT run enables OPcache in the CLI" has "$probe_args" "-d opcache.enable_cli=1"
check "OPcache probe: JIT run never takes huge pages" has "$probe_args" "-d opcache.huge_code_pages=0"
out=$(op_probe 8.4 short)
check "OPcache probe: a stopped series is not started" has "$out" "php8.4-fpm is not running"
check "OPcache probe: --diagnostics runs it per series" \
  bash -c 'grep -q "diag \"PHP \${ver} effective FPM OPcache/JIT\" diag_php_effective_opcache" "$1"' _ "$ROOT/lib/diagnostics.sh"

# ---------------------------------------------------------------------------
# --optimize "Verify" block
# ---------------------------------------------------------------------------
vs_probe() (
  verify_nginx_line() { echo "nginx: 1.29.0; built with OpenSSL 3.5.0"; }
  php_active_version() { echo 8.5; }
  diag_php_effective_opcache() { echo "PHP 8.5.1 JIT on"; }
  verify_valkey_lines() { echo "Valkey 8.1.4"; }
  host_is_vps() { return "${VS_VPS:-1}"; }
  effective_cpus() { echo "${VS_CPUS:-8}"; }
  systemctl() { echo "${VS_IRQ:-inactive}"; }
  verify_summary_lines
)
out=$(vs_probe)
check "Verify: nginx line" has "$out" "nginx: 1.29.0; built with OpenSSL"
check "Verify: no kTLS line" lacks "$out" "kTLS"
check "Verify: PHP JIT line" has "$out" "PHP 8.5.1 JIT on"
check "Verify: Valkey line" has "$out" "Valkey 8.1.4"
check "Verify: irqbalance note on a dedicated 8-CPU host" has "$out" "irqbalance is not active"
out=$(VS_IRQ=active vs_probe)
check "Verify: no irqbalance note when active" lacks "$out" "irqbalance"
out=$(VS_CPUS=2 vs_probe)
check "Verify: no irqbalance note under 4 CPUs" lacks "$out" "irqbalance"
out=$(VS_VPS=0 vs_probe)
check "Verify: no irqbalance note on a VPS" lacks "$out" "irqbalance"
out=$(PHP_OPCACHE_VALIDATE=0 vs_probe)
check "Verify: the removed validate_timestamps=0 option prints no deploy note" lacks "$out" "validate_timestamps=0"
check "Verify: --optimize report calls the block" grep -q "opt_report_verify" "$ROOT/lib/restart.sh"

# ---------------------------------------------------------------------------
# Certificate expiry
# ---------------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  W=$TMP/web
  mkdir -p "$W/conf.d" "$W/certs"
  mkcert() { # NAME DAYS -> self-signed cert
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/certs/$1.key" -out "$W/certs/$1.crt" \
      -days "$2" -subj "/CN=$1.example.com" >/dev/null 2>&1
  }
  # A CA-signed (not self-signed) leaf.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/certs/ca.key" -out "$W/certs/ca.crt" \
    -days 400 -subj "/CN=Test CA" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$W/certs/leaf.key" -out "$W/certs/leaf.csr" \
    -subj "/CN=leaf.example.com" >/dev/null 2>&1
  openssl x509 -req -in "$W/certs/leaf.csr" -CA "$W/certs/ca.crt" -CAkey "$W/certs/ca.key" \
    -CAcreateserial -out "$W/certs/leaf.crt" -days 300 >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$W/certs/soon.key" -out "$W/certs/soon.csr" \
    -subj "/CN=soon.example.com" >/dev/null 2>&1
  openssl x509 -req -in "$W/certs/soon.csr" -CA "$W/certs/ca.crt" -CAkey "$W/certs/ca.key" \
    -CAcreateserial -out "$W/certs/soon.crt" -days 10 >/dev/null 2>&1
  mkcert self 3650
  mkcert cfself 3650
  printf 'server {\n  listen 443 ssl;\n  server_name leaf.example.com;\n  ssl_certificate %s;\n}\n' "$W/certs/leaf.crt" > "$W/conf.d/leaf.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name soon.example.com www.soon.example.com;\n  ssl_certificate %s;\n}\n' "$W/certs/soon.crt" > "$W/conf.d/soon.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name self.example.com;\n  ssl_certificate %s;\n}\n' "$W/certs/self.crt" > "$W/conf.d/self.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name cfself.example.com;\n  ssl_certificate %s;\n  %s\n}\n' "$W/certs/cfself.crt" "$CF_TLS_PROBE_LOCATION" > "$W/conf.d/cfself.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name dnscf.example.com;\n  ssl_certificate %s;\n}\n' "$W/certs/self.crt" > "$W/conf.d/dnscf.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name gone.example.com;\n  ssl_certificate %s;\n}\n' "$W/certs/missing.crt" > "$W/conf.d/gone.conf"
  printf 'server {\n  listen 443 ssl;\n  server_name var.example.com;\n  ssl_certificate /etc/ssl/$ssl_server_name.crt;\n}\n' > "$W/conf.d/var.conf"
  out=$(
    cf_tls_name_behind_cloudflare() { [[ $1 == dnscf.example.com ]]; }
    cert_expiry_lines "$W"
  )
  check "certs: a valid CA-signed cert is listed without a warning" has "$out" "leaf.conf (leaf.example.com): notAfter"
  check "certs: no WARN for the valid cert" lacks "$out" "WARN leaf.conf"
  check "certs: expiry within 21 days warns" has "$out" "WARN soon.conf (soon.example.com www.soon.example.com): ends in"
  check "certs: self-signed off Cloudflare warns" has "$out" "WARN self.conf (self.example.com): self-signed"
  check "certs: self-signed behind the Cloudflare probe does not warn" has "$out" "cfself.conf (cfself.example.com): notAfter"
  check "certs: the probe proof is named" has "$out" "behind Cloudflare (probe)"
  check "certs: DNS-proven Cloudflare vhost does not warn" has "$out" "behind Cloudflare (dns)"
  check "certs: missing certificate warns" has "$out" "WARN gone.conf: certificate"
  check "certs: variable paths are not opened" has "$out" "is a variable path; not checked"
  check "certs: --diagnostics runs the check" grep -q 'diag "vhost certificate expiry" cert_expiry_lines' "$ROOT/lib/diagnostics.sh"
  out=$(
    opt_report() { printf '%s\n' "$*"; }
    verify_summary_lines() { :; }
    diag_web_etc() { printf '%s' "$W"; }
    cf_tls_name_behind_cloudflare() { return 1; }
    OPT_WEB_LEGACY=0 opt_report_verify
  )
  check "certs: --optimize report has a Certificates block" has "$out" "## Certificates"
  check "certs: --optimize report marks warnings" has "$out" "- **WARNING** self.conf"
else
  t_skip "certificate expiry: openssl not installed"
fi

# ---------------------------------------------------------------------------
# SETUP_PHP_OPCACHE_FILE_OVERRIDE (validate_timestamps=0 was removed)
# ---------------------------------------------------------------------------
opc_load() ( # -> "file_override persist"
  php_opcache_opts_load
  printf '%s %s' "$PHP_OPCACHE_FILE_OVERRIDE" "$PHP_OPCACHE_FILE_OVERRIDE_PERSIST"
)
check "opcache opts: default is file_override=1, nothing persisted" test "$(opc_load)" = "1 0"
check "opcache opts: SETUP_PHP_OPCACHE_FILE_OVERRIDE=0 opts out and persists" test "$(SETUP_PHP_OPCACHE_FILE_OVERRIDE=0 opc_load)" = "0 1"
check "opcache opts: the persisted host value is honoured" test "$(PHP_OPCACHE_FILE_OVERRIDE=0 opc_load)" = "0 0"
check "opcache opts: the environment wins over the host file (=1 reverts)" \
  test "$(PHP_OPCACHE_FILE_OVERRIDE=0 SETUP_PHP_OPCACHE_FILE_OVERRIDE=1 opc_load)" = "1 1"
check "opcache opts: garbage means the default" test "$(SETUP_PHP_OPCACHE_FILE_OVERRIDE=yes opc_load)" = "1 1"
check "opcache opts: the removed SETUP_PHP_OPCACHE_VALIDATE is ignored" \
  bash -c '! grep -q "OPCACHE_VALIDATE" "$1"' _ "$ROOT/lib/web.sh"
TF=$TMP/setup-tuning
: > "$TF"
( SETUP_TUNING_FILE=$TF; tune_summary() { :; }; php_opcache_persist_one PHP_OPCACHE_FILE_OVERRIDE 0 1 1 )
check "opcache persist: explicit choice written" grep -qx "PHP_OPCACHE_FILE_OVERRIDE=0" "$TF"
( SETUP_TUNING_FILE=$TF; tune_summary() { :; }; php_opcache_persist_one PHP_OPCACHE_FILE_OVERRIDE 1 1 1 )
check "opcache persist: =1 overwrites the opt-out" grep -qx "PHP_OPCACHE_FILE_OVERRIDE=1" "$TF"
: > "$TF"
( SETUP_TUNING_FILE=$TF; php_opcache_persist_one PHP_OPCACHE_FILE_OVERRIDE 0 0 1 )
check "opcache persist: a host value lost to the profile reset is written back" grep -qx "PHP_OPCACHE_FILE_OVERRIDE=0" "$TF"
: > "$TF"
( SETUP_TUNING_FILE=$TF; php_opcache_persist_one PHP_OPCACHE_FILE_OVERRIDE 1 0 1 )
check "opcache persist: the default is never written implicitly" test ! -s "$TF"
check "opcache persist: persist_php_jit persists file_override" \
  bash -c 'sed -n "/^persist_php_jit()/,/^}/p" "$1" | grep -c php_opcache_persist_one | grep -qx 1' _ "$ROOT/lib/web.sh"
tune_body=$(sed -n '/^tune_php_fpm_version()/,/^}/p' "$ROOT/lib/web.sh")
check "php ini: validate_timestamps is always 1" \
  has "$tune_body" 'opcache.validate_timestamps = 1'
check "php ini: enable_file_override written by default (=0 leaves it out)" \
  has "$tune_body" 'if [[ ${PHP_OPCACHE_FILE_OVERRIDE:-1} == 1 ]]; then'
check "php ini: the managed ini is rewritten whole (unset reverts)" has "$tune_body" 'cat > "$ini" <<EOF'
check "php ini: opcache.file_cache is written explicitly empty (a stray ini cannot enable it)" \
  bash -c 'printf "%s\n" "$1" | grep -qx "opcache.file_cache ="' _ "$tune_body"
check "php ini: the removed file-cache variable and directory code are gone" \
  bash -c '! printf "%s\n" "$1" | grep -qE "opcache_file_cache|/var/cache/php"' _ "$tune_body"
check "php_jit_settings: the buffer is documented as shared, not per worker" \
  bash -c 'sed -n "/^# buffer of an eighth/,/^php_jit_settings()/p" "$1" | grep -q "not per worker" && ! sed -n "/^# buffer of an eighth/,/^php_jit_settings()/p" "$1" | grep -q "reserved per PHP-FPM worker"' _ "$ROOT/lib/web.sh"

# ---------------------------------------------------------------------------
# Chevereto upload limit: nginx's 413 is the effective one
# ---------------------------------------------------------------------------
ini=$ROOT/configs/php/custom_dan.ini
post=$(awk -F'=' '$1 ~ /^post_max_size/ { gsub(/[[:space:]M]/, "", $2); print $2 }' "$ini")
upl=$(awk -F'=' '$1 ~ /^upload_max_filesize/ { gsub(/[[:space:]M]/, "", $2); print $2 }' "$ini")
check "php ini: post_max_size is 102M" test "$post" = 102
check "php ini: upload_max_filesize stays 100M (below post_max_size)" test "$upl" = 100
NT=${NGINX_TREE:-$ROOT/../server-configs-nginx}
if [[ -r $NT/conf.d/templates/sample_sfs.conf ]]; then
  body=$(awk '$1 == "client_max_body_size" { v = $2; sub(/[mM];.*/, "", v); print v; exit }' "$NT/conf.d/templates/sample_sfs.conf")
  check "Chevereto vhost body limit (${body}m) is below post_max_size" test "$body" -lt "$post"
else
  t_skip "Chevereto vhost template not found (NGINX_TREE)"
fi
check "README: Cloudflare Free/Pro 100 MB body cap documented" grep -q "Cloudflare Free or Pro the edge caps a request body at 100 MB" "$ROOT/README.md"

# ---------------------------------------------------------------------------
# F12: the JIT probe fits the managed ini (interned_strings_buffer up to 64)
# ---------------------------------------------------------------------------
check "OPcache probe: JIT run shrinks the interned-strings buffer" has "$probe_args" "-d opcache.interned_strings_buffer=1"
check "OPcache probe: JIT run shrinks the script table" has "$probe_args" "-d opcache.max_accelerated_files=1000"
REALPHP=$(command -v php8.5 || command -v php8.4 || command -v php || true)
if [[ -n $REALPHP ]] && "$REALPHP" -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);' 2>/dev/null; then
  PE=$TMP/etcphp-real/8.5/fpm
  mkdir -p "$PE/conf.d"
  : > "$PE/php.ini"
  cat > "$PE/conf.d/zz-setup-optimize.ini" <<'EOF'
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 512
opcache.interned_strings_buffer = 64
opcache.jit = tracing
opcache.jit_buffer_size = 64M
opcache.huge_code_pages = 0
opcache.max_accelerated_files = 130987
EOF
  out=$(
    systemctl() { [[ $* == "is-active --quiet php8.5-fpm" ]]; }
    diag_php_cli_for() { printf '%s' "$REALPHP"; }
    DIAG_PHP_ETC=$TMP/etcphp-real diag_php_effective_opcache 8.5 short
  )
  if has "$out" "JIT on" || has "$out" "JIT off"; then
    t_pass "OPcache probe: real CLI with interned_strings_buffer=64 reads JIT on/off"
  else
    t_fail "OPcache probe: real CLI with interned_strings_buffer=64 reads JIT on/off (got: $out)"
  fi
  check "OPcache probe: never unknown with the managed ini" lacks "$out" "JIT unknown"
else
  t_skip "OPcache probe: no PHP CLI with OPcache on this host"
fi

# ---------------------------------------------------------------------------
# F26: maxclients fallback on a Redis-only host (no valkey.conf)
# ---------------------------------------------------------------------------
ER=$TMP/etc-redis
mkdir -p "$ER/redis"
printf 'port 6379\nmaxclients 4321\n' > "$ER/redis/redis.conf"
out=$(
  systemctl() {
    case "$*" in
      "show -p LimitNOFILE --value "*) echo 65535 ;;
      "cat redis-server.service") return 0 ;;
      "cat "*) return 1 ;;
    esac
  }
  diag_redis_cli() { return 1; }
  diag_mariadb_installed() { return 1; }
  diag_elasticsearch_installed() { return 1; }
  DIAG_ETC=$ER diag_nofile_limits 2>&1
)
check "nofile: Redis-only host reads maxclients from redis.conf" has "$out" "redis-server.service: LimitNOFILE=65535, maxclients=4321"

# ---------------------------------------------------------------------------
# F25: expiry decided by openssl -checkend, not by date(1) parsing
# ---------------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  W2=$TMP/web2
  mkdir -p "$W2/conf.d" "$W2/certs"
  leaf2() { # NAME OPENSSL-X509-ARGS... -> CA-signed leaf
    local n=$1; shift
    openssl req -newkey rsa:2048 -nodes -keyout "$W2/certs/$n.key" -out "$W2/certs/$n.csr" \
      -subj "/CN=$n.example.com" >/dev/null 2>&1
    openssl x509 -req -in "$W2/certs/$n.csr" -CA "$W/certs/ca.crt" -CAkey "$W/certs/ca.key" \
      -CAcreateserial -out "$W2/certs/$n.crt" "$@" >/dev/null 2>&1
    printf 'server {\n  listen 443 ssl;\n  server_name %s.example.com;\n  ssl_certificate %s;\n}\n' \
      "$n" "$W2/certs/$n.crt" > "$W2/conf.d/$n.conf"
  }
  leaf2 day1 -days 1
  leaf2 long -days 300
  out=$(cf_tls_name_behind_cloudflare() { return 1; }; cert_expiry_lines "$W2")
  check "certs: a 1-day cert warns (ends in 0 or 1 days)" \
    bash -c '[[ $1 =~ "WARN day1.conf (day1.example.com): ends in "[01]" days" ]]' _ "$out"
  check "certs: a 300-day cert does not warn" lacks "$out" "WARN long.conf"
  # date(1) that cannot parse any date (uutils on 26.04 was the concern):
  # openssl still decides, and the unparsed date itself is a warning.
  out=$(
    cf_tls_name_behind_cloudflare() { return 1; }
    date() { [[ $1 == +%s ]] && { command date +%s; return; }; return 1; }
    cert_expiry_lines "$W2"
  )
  check "certs: unparseable date still warns a 1-day cert via -checkend" has "$out" "WARN day1.conf (day1.example.com): ends in ? days, expiry date not parsed"
  check "certs: unparseable date on a valid CA cert warns 'expiry date not parsed'" has "$out" "WARN long.conf (long.example.com): expiry date not parsed"
  # An already-expired certificate (needs -not_before/-not_after, OpenSSL 3.4+).
  if leaf2 old -not_before 20200101000000Z -not_after 20200102000000Z && [[ -s $W2/certs/old.crt ]]; then
    out=$(cf_tls_name_behind_cloudflare() { return 1; }; cert_expiry_lines "$W2")
    check "certs: an expired cert reads expired" has "$out" "WARN old.conf (old.example.com): expired"
    check "certs: the ISO date gives the day count of an expired cert" \
      bash -c '[[ $1 =~ "old.conf (old.example.com): expired, notAfter " ]] && [[ $1 != *"expiry date not parsed"* ]]' _ "$out"
  else
    rm -f "$W2/conf.d/old.conf"
    t_skip "certs: this openssl cannot back-date a certificate (-not_after)"
  fi
  check "certs: expiry is decided by openssl -checkend" \
    bash -c 'sed -n "/^cert_expiry_lines()/,/^}/p" "$1" | grep -q -- "-checkend 0"' _ "$ROOT/lib/diagnostics.sh"
else
  t_skip "certificate expiry (-checkend): openssl not installed"
fi

# ---------------------------------------------------------------------------
# MariaDB collations (report only)
# ---------------------------------------------------------------------------
# MDB_MAP / MDB_COLS drive the stubbed server answers.
mdb_probe() (
  diag_mariadb_installed() { return "${MDB_INSTALLED:-0}"; }
  mariadb() { :; }
  diag_mariadb_query() {
    [[ ${MDB_DOWN:-0} == 1 ]] && return 1
    printf '%s\n' "$1" >> "$TMP/mdb-queries"
    case $1 in
      'SELECT @@version') echo 11.8.3-MariaDB-ubu2604 ;;
      'SELECT @@character_set_collations') printf '%s\n' "${MDB_MAP-utf8mb3=utf8mb3_uca1400_ai_ci,ucs2=ucs2_uca1400_ai_ci,utf8mb4=utf8mb4_uca1400_ai_ci,utf16=utf16_uca1400_ai_ci}" ;;
      'SELECT @@collation_server') echo utf8mb4_general_ci ;;
      'SELECT @@collation_connection') echo utf8mb4_uca1400_ai_ci ;;
      *information_schema.columns*) printf '%b' "${MDB_COLS-}" ;;
      *) return 1 ;;
    esac
  }
  diag_mariadb_collations "$@"
)
: > "$TMP/mdb-queries"
out=$(MDB_COLS='xf\tutf8mb4_general_ci\t900\nwp\tutf8mb4_unicode_520_ci\t300\n' mdb_probe full)
check "collations: @@version printed" has "$out" "@@version: 11.8.3-MariaDB"
check "collations: character_set_collations printed" has "$out" "@@character_set_collations: utf8mb3=utf8mb3_uca1400_ai_ci"
check "collations: collation_server and collation_connection printed" \
  bash -c '[[ $1 == *"@@collation_server: utf8mb4_general_ci"* && $1 == *"@@collation_connection: utf8mb4_uca1400_ai_ci"* ]]' _ "$out"
check "collations: per-schema column counts printed" has "$out" $'xf\tutf8mb4_general_ci\t900'
check "collations: uca1400 default vs app collations warns" has "$out" "WARN character_set_collations maps utf8mb4 to utf8mb4_uca1400_ai_ci but app columns use utf8mb4_general_ci, utf8mb4_unicode_520_ci"
check "collations: one collation per schema is not a mix" lacks "$out" "mixes utf8mb4 collations"
check "collations: only read-only SELECTs are sent" bash -c '! grep -qvE "^SELECT " "$1"' _ "$TMP/mdb-queries"
out=$(MDB_COLS='xf\tutf8mb4_general_ci\t900\nxf\tutf8mb4_unicode_ci\t12\nxf\tlatin1_swedish_ci\t3\n' mdb_probe full)
check "collations: a schema mixing utf8mb4 collations warns" has "$out" "WARN schema xf mixes utf8mb4 collations (utf8mb4_general_ci 900, utf8mb4_unicode_ci 12)"
out=$(MDB_COLS='img\tutf8mb4_uca1400_ai_ci\t105\nimg\tutf8mb4_bin\t3\n' mdb_probe full)
check "collations: deliberate _bin columns are neither a mix nor a default clash" lacks "$out" "WARN"
out=$(MDB_MAP='' MDB_COLS='xf\tutf8mb4_general_ci\t900\n' mdb_probe full)
check "collations: before 11.2 (no map) one collation is ok" has "$out" "collations: ok"
check "collations: before 11.2 the map is named as absent" has "$out" "not supported before 11.2"
out=$(MDB_COLS='xf\tutf8mb4_uca1400_ai_ci\t900\n' mdb_probe full)
check "collations: app tables already on the uca1400 default do not warn" lacks "$out" "WARN"
out=$(MDB_COLS='xf\tutf8mb4_general_ci\t900\nwp\tutf8mb4_general_ci\t100\n' mdb_probe short)
check "collations: Verify line is one WARN line" bash -c '[[ $(printf "%s\n" "$1" | wc -l) -eq 1 && $1 == "WARN MariaDB 11.8.3-MariaDB-ubu2604: utf8mb4 default utf8mb4_uca1400_ai_ci, collation_server utf8mb4_general_ci, app column collations utf8mb4_general_ci 1000; character_set_collations maps"* ]]' _ "$out"
out=$(MDB_DOWN=1 mdb_probe full)
check "collations: unreachable server is skipped cleanly" has "$out" "server not reachable; collation check skipped"
out=$(MDB_INSTALLED=1 mdb_probe full)
check "collations: no MariaDB is skipped cleanly" has "$out" "not installed; collation check skipped"
out=$(MDB_INSTALLED=1 mdb_probe short)
check "collations: no Verify line without MariaDB" test -z "$out"
check "collations: --diagnostics runs the section" grep -q 'diag "MariaDB collations" diag_mariadb_collations full' "$ROOT/lib/diagnostics.sh"
out=$(
  opt_report() { printf '%s\n' "$*"; }
  verify_summary_lines() { echo "WARN MariaDB 11.8: x"; echo "nginx: ok"; }
  diag_web_etc() { printf '%s' "$TMP/none"; }
  OPT_WEB_LEGACY=0 opt_report_verify
)
check "collations: --optimize Verify marks a WARN line" has "$out" "- **WARNING** MariaDB 11.8: x"
check "collations: --optimize Verify keeps plain lines" has "$out" "- nginx: ok"
out=$(
  verify_nginx_line() { :; }; verify_valkey_lines() { :; }
  php_active_version() { :; }; php_fpm_versions() { :; }; host_is_vps() { return 0; }
  diag_mariadb_installed() { return 0; }
  diag_mariadb_collations() { echo "MDBLINE $1"; }
  verify_summary_lines
)
check "collations: Verify block has the short MariaDB line" has "$out" "MDBLINE short"

printf '\nTOTAL pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
