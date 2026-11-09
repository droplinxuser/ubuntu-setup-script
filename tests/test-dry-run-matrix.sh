#!/usr/bin/env bash
# Dry-run flag matrix for setup.sh. No root and no system changes required.
# Usage: bash tests/test-dry-run-matrix.sh
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Run each invocation from /tmp so the mandatory setup_<timestamp>.log does
# not accumulate in the repository.  The test itself never deletes the files;
# /tmp expires them.
TMP=$(mktemp -d /tmp/setup-test-matrix.XXXXXX)
cd "$TMP" || exit 1
printf 'CREATE TABLE t (id INT);\n' > "$TMP/dump.sql"

PASS=0
FAIL=0

run() {
  local expect=$1
  shift
  local out rc
  out=$(bash "$SCRIPT_DIR/setup.sh" "$@" 2>&1)
  rc=$?
  if [[ $expect == ok && $rc -eq 0 ]] || [[ $expect == fail && $rc -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf 'PASS  rc=%d  %s\n' "$rc" "$*"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  rc=%d expected=%s  %s\n' "$rc" "$expect" "$*"
    printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}

# Same as run, with one VAR=value placed in the environment of the call.
run_env() {
  local expect=$1 var=$2
  shift 2
  local out rc
  out=$(env "$var" bash "$SCRIPT_DIR/setup.sh" "$@" 2>&1)
  rc=$?
  if [[ $expect == ok && $rc -eq 0 ]] || [[ $expect == fail && $rc -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf 'PASS  rc=%d  %s %s\n' "$rc" "$var" "$*"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  rc=%d expected=%s  %s %s\n' "$rc" "$expect" "$var" "$*"
    printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}

# Basic CLI.
run ok   --help
run ok   --version
run fail

# Basic and every install service, individually and together.
run ok   --dry-run --basic
run ok   --dry-run --basic server=dedi
run ok   --dry-run --basic server=vps host=test.example.com swap=4G time=UTC
run ok   --dry-run --basic --angie
run ok   --dry-run --basic --php
run ok   --dry-run --basic --php ver=8.4 children=32 max_requests=4096
run ok   --dry-run --basic --mariadb user=demo pass=temp size=4gb
run ok   --dry-run --basic --mariadb user=demo pass=temp
run ok   --dry-run --basic --mariadb user=demo pass=temp size=auto bind=127.0.0.1,IPV4
run ok   --dry-run --basic --valkey
run ok   --dry-run --basic --valkey ram=2g policy=noeviction io_threads=2
run ok   --dry-run --basic --valkey ram=auto
run ok   --dry-run --basic --elastic ram=4g host=localhost
run ok   --dry-run --basic --elastic
run ok   --dry-run --basic --elastic ram=auto
run ok   --dry-run --basic --others all
run ok   --dry-run --basic --others smartmon gif nodejs sysstat
run fail --dry-run --basic --others fail2ban
run fail --dry-run --basic --others unattended
run fail --dry-run --basic --others composer
run fail --dry-run --basic --others security
run ok   --dry-run --basic --angie --php --mariadb user=u pass=p size=auto \
  --valkey --elastic ram=2g --others all

# Domain app parsing, including trailing group defaults and mixed apps.
run ok   --dry-run --domain example.com
run ok   --dry-run --domain example.com app=wordpress
run ok   --dry-run --domain a.example.com b.example.com app=xf
run ok   --dry-run --domain a.example.com app=xf b.example.com
run ok   --dry-run --domain app=xf a.example.com b.example.com
run ok   --dry-run --domain a.example.com app=wordpress b.example.com app=lychee
run ok   --dry-run --domain a.example.com app=node
run ok   --dry-run --domain a.example.com app=php
run ok   --dry-run --domain a.example.com app=blank
run ok   --dry-run --domain a.example.com app=pingvin
run ok   --dry-run --domain a.example.com app=chevereto
run ok   --dry-run --domain a.example.com app=polr
run ok   --dry-run --domain a.example.com app=lychee
run ok   --dry-run --domain a.example.com app=flarum
run ok   --dry-run --domain a.example.com app=shlink b.example.com app=sfs
run ok   --dry-run --domain a.example.com app=basic
run ok   --dry-run --domain blog.example.com db=blogdb
run ok   --dry-run --domain blog.example.com app=xf db=xenforodb user=demo pass=temp sql=$TMP/dump.sql
run ok   --dry-run --domain a.example.com db=adb user=u pass=p b.example.com app=wordpress db=bdb

# Optimize-only mode.
run ok   --dry-run --optimize
run ok   $'—optimize' --dry-run
run ok   $'–optimize' --dry-run
run ok   --dry-run --diagnostics
run fail --dry-run --diagnostics --basic
run fail --dry-run --diagnostics --optimize
run fail --dry-run --diagnostics --purge
run ok   --dry-run --restart-all
run fail --dry-run --restart-all --basic
run fail --dry-run --restart-all --purge
run fail --dry-run --restart-all --optimize
run fail --dry-run --restart-all --diagnostics
run fail --dry-run --restart-all --domain example.com
run fail --dry-run --restart-all --angie
run fail --dry-run --optimize --basic
run fail --dry-run --optimize --angie
run fail --dry-run --optimize --purge
run fail --dry-run --optimize --domain example.com

# Purge modes and bare names.
run ok   --dry-run --purge
run ok   --dry-run --purge all
run ok   --dry-run --purge basic angie php mariadb valkey elastic others
run ok   --dry-run --purge --angie --php
run ok   --dry-run --purge --php ver=8.4
run ok   --dry-run --purge php mariadb

# Invalid input must fail early.
run fail --dry-run --basic server=cloud
run fail --dry-run --basic host=-bad
run fail --dry-run --basic swap=0
run ok   --dry-run --basic swap=8Gi
run ok   --dry-run --purge others
run fail --dry-run --basic time=Nowhere/Nothing
run fail --dry-run --basic --mariadb user=u size=4gb
run fail --dry-run --basic --mariadb user=u pass=p size=0
run fail --dry-run --basic --mariadb user=u pass=p size=4gb bind=bogus
run fail --dry-run --basic --php ver=8
run fail --dry-run --basic --php children=0
run fail --dry-run --basic --valkey policy=bogus
run fail --dry-run --basic --valkey io_threads=0
run fail --dry-run --basic --valkey ram=0
run fail --dry-run --basic --elastic ram=x
run fail --dry-run --basic --elastic ram=0
run fail --dry-run --basic --others bogus
run fail --dry-run --domain -bad.com
run fail --dry-run --domain example.com app=bogus
run fail --dry-run --domain example.com user=u pass=p
run fail --dry-run --domain example.com db=d user=u
run fail --dry-run --domain example.com db=d sql=$TMP/dump.sql user=u pass=p sql=/nonexistent/dump.sql
run fail --dry-run --domain example.com sql=$TMP/dump.sql
run fail --dry-run --domain example.com db=bad-name
run fail --dry-run --domain db=early example.com
run fail --dry-run --basic --harden-ssh
run fail --dry-run --optimize --cloudflare-only
run fail --dry-run --domain example.com --purge
run fail --dry-run --angie
run fail --dry-run --bogus
run fail --dry-run --sync-angie

# --check is an alias for --dry-run; -h is an alias for --help.
run ok   --check --basic
run ok   -h

# kv flags reject unknown keys and bare tokens.
run fail --dry-run --basic foo=1
run fail --dry-run --basic foo
run fail --dry-run --basic --php foo=1
run fail --dry-run --basic --valkey foo=1
run fail --dry-run --basic --elastic foo=1
run fail --dry-run --basic --mariadb user=a pass=b foo=1

# --mariadb bind= accepts ::1 and IPv4 lists; size= accepts m/mb/g/gb.
run ok   --dry-run --basic --mariadb user=a pass=b bind=::1
run ok   --dry-run --basic --mariadb user=a pass=b bind=127.0.0.1,2.3.4.5
run ok   --dry-run --basic --mariadb user=a pass=b size=512m
run fail --dry-run --basic --mariadb user=a pass=b bind=1.2.3

# --php children=auto, --valkey ram units and every eviction policy,
# --elastic host= as IPv4.
run ok   --dry-run --basic --php children=auto
run ok   --dry-run --basic --valkey ram=2G
run ok   --dry-run --basic --valkey ram=512m
run ok   --dry-run --basic --valkey policy=allkeys-lru
run ok   --dry-run --basic --valkey policy=allkeys-lfu
run ok   --dry-run --basic --valkey policy=volatile-lru
run ok   --dry-run --basic --valkey policy=volatile-lfu
run ok   --dry-run --basic --valkey policy=volatile-ttl
run ok   --dry-run --basic --valkey policy=allkeys-random
run ok   --dry-run --basic --valkey policy=volatile-random
run ok   --dry-run --basic --elastic host=10.0.0.5
run fail --dry-run --basic --elastic host=10.0.0.999

# --others needs a package; duplicates are de-duplicated.
run fail --dry-run --basic --others
run ok   --dry-run --basic --others nvme
run ok   --dry-run --basic --others smartmon smartmon

# --domain app= aliases (normalize_app).
run ok   --dry-run --domain a.example.com app=xenforo
run ok   --dry-run --domain a.example.com app=wp
run ok   --dry-run --domain a.example.com app=chev
run ok   --dry-run --domain a.example.com app=nodejs
run ok   --dry-run --domain a.example.com app=generic
run ok   --dry-run --domain a.example.com app=none
run ok   --dry-run --domain a.example.com app=plain
run ok   --dry-run --domain a.example.com app=static

# --domain names are lower-cased, a trailing dot is stripped, and a repeated
# domain is de-duplicated.
run ok   --dry-run --domain EXAMPLE.COM
run ok   --dry-run --domain example.com.
run ok   --dry-run --domain example.com example.com

# --domain may be combined with a full install, but any service other than
# --domain needs --basic, and --diagnostics is read-only.
run ok   --dry-run --basic --angie --domain x.example.com
run fail --dry-run --domain x.example.com --angie
run fail --dry-run --diagnostics --domain x.example.com

# --purge targets: unknown names and malformed --php ver= fail; flag and
# bare-name forms are both accepted.
run fail --dry-run --purge bogus
run fail --dry-run --purge --php ver=8
run ok   --dry-run --purge --basic
run ok   --dry-run --purge --others
run ok   --dry-run --purge basic

# The single optimize command must include the OS layer.
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --optimize 2>&1)
if [[ $out == *"OS: governor="* && $out == *"limits=1M-nofile"* ]]; then
  PASS=$((PASS + 1))
  printf 'PASS  --optimize includes the OS tuning plan\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  --optimize does not include the OS tuning plan\n'
fi

# --others all must expand to the supported packages only.  fail2ban,
# unattended-upgrades and Composer were deliberately removed.
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --basic --others all 2>&1)
if [[ $out == *"smartmon nvme gif nodejs sysstat"* ]] \
   && [[ $out != *fail2ban* && $out != *unattended* && $out != *composer* ]]; then
  PASS=$((PASS + 1))
  printf 'PASS  --others all expands to the supported packages\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  --others all includes a removed or missing package\n'
fi

# Every run must leave a complete log in the invocation directory.
LOGDIR="$TMP/log-check"
mkdir -p "$LOGDIR"
( cd "$LOGDIR" && bash "$SCRIPT_DIR/setup.sh" --dry-run --basic >/dev/null 2>&1 )
log=$(find "$LOGDIR" -maxdepth 1 -name 'setup_*.log' -type f | head -n1)
if [[ -n $log && -s $log ]] \
   && grep -q 'setup.sh run log' "$log" \
   && grep -q 'Command' "$log" \
   && grep -q 'run finished' "$log"; then
  PASS=$((PASS + 1))
  printf 'PASS  every run writes a complete setup_<timestamp>.log\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  run log is missing or incomplete\n'
fi

# The run log must never record a password argument.
REDACTDIR="$TMP/log-redact"
mkdir -p "$REDACTDIR"
( cd "$REDACTDIR" && bash "$SCRIPT_DIR/setup.sh" --dry-run --basic \
    --mariadb user=demo pass=topsecret size=4gb >/dev/null 2>&1 )
log=$(find "$REDACTDIR" -maxdepth 1 -name 'setup_*.log' -type f | head -n1)
if [[ -n $log ]] && grep -q 'pass=\*\*\*' "$log" && ! grep -q 'topsecret' "$log"; then
  PASS=$((PASS + 1))
  printf 'PASS  run log redacts pass= arguments\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  run log leaks or omits a password argument\n'
fi
# Environment overrides are validated and fall back safely.
run_env ok SETUP_PHP_JIT=tracing --dry-run --optimize
run_env ok SETUP_PHP_JIT=bogus --dry-run --optimize
run_env ok SETUP_PHP_JIT_WORDPRESS=1 --dry-run --optimize
# Network tuning, rate-limit exemptions and asset precompression overrides.
run_env ok SETUP_TCP_CC=cubic --dry-run --optimize
run_env ok SETUP_QDISC=fq_codel --dry-run --optimize
run_env ok SETUP_LIMIT_REQ_EXEMPT=10.0.0.5 --dry-run --optimize
run_env ok SETUP_PRECOMPRESS_ASSETS=1 --dry-run --optimize
# An invalid SETUP_NODE_MAJOR falls back to the default major, never fails.
run_env ok SETUP_NODE_MAJOR=bogus --dry-run --basic --others nodejs
# SETUP_ANGIE_COMPRESSION only tests for 0; any other value keeps Brotli on.
run_env ok SETUP_ANGIE_COMPRESSION=gzip --dry-run --basic --angie
run_env ok SETUP_WP_DB_SPLIT=0 --dry-run --domain a.example.com app=wordpress
run_env ok SETUP_PURGE_MALWARE=0 --dry-run --optimize
# A dry run exits before fetch_server_configs, so CONFIG_SOURCE_DIR is not
# checked and a missing directory does not fail.
run_env ok CONFIG_SOURCE_DIR=/nonexistent --dry-run --basic --angie

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
