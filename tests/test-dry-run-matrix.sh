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

# run_msg TEXT ARGS...: the call must fail AND print TEXT, so a row cannot
# pass because an unrelated, earlier check refused it.  It runs with a
# dpkg-query that reports no packages: on a host that already has PHP, --php
# ver=X stops at "already installed" before the version-specific checks.
NOPKG="$TMP/nopkg"
mkdir -p "$NOPKG"
printf '#!/bin/sh\nexit 1\n' > "$NOPKG/dpkg-query"
chmod +x "$NOPKG/dpkg-query"
run_msg() {
  local text=$1
  shift
  local out rc
  out=$(PATH="$NOPKG:$PATH" bash "$SCRIPT_DIR/setup.sh" "$@" 2>&1)
  rc=$?
  if (( rc != 0 )) && grep -qF -- "$text" <<<"$out"; then
    PASS=$((PASS + 1))
    printf 'PASS  rc=%d  %s  [%s]\n' "$rc" "$*" "$text"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  rc=%d expected failure with "%s"  %s\n' "$rc" "$text" "$*"
    printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}

# run_warn TEXT ARGS...: the call must succeed AND print TEXT (a removed
# option or alias that is accepted with a warning, never silently).
run_warn() {
  local text=$1
  shift
  local out rc
  out=$(bash "$SCRIPT_DIR/setup.sh" "$@" 2>&1)
  rc=$?
  if (( rc == 0 )) && grep -qF -- "$text" <<<"$out"; then
    PASS=$((PASS + 1))
    printf 'PASS  rc=%d  %s  [%s]\n' "$rc" "$*" "$text"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  rc=%d expected success with "%s"  %s\n' "$rc" "$text" "$*"
    printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}

# run_env_msg ok|fail VAR=value TEXT ARGS...: run_env that also asserts TEXT
# in the output, so a row cannot pass on an unrelated message.
run_env_msg() {
  local expect=$1 var=$2 text=$3
  shift 3
  local out rc
  out=$(env "$var" bash "$SCRIPT_DIR/setup.sh" "$@" 2>&1)
  rc=$?
  if { [[ $expect == ok && $rc -eq 0 ]] || [[ $expect == fail && $rc -ne 0 ]]; } \
     && grep -qF -- "$text" <<<"$out"; then
    PASS=$((PASS + 1))
    printf 'PASS  rc=%d  %s %s  [%s]\n' "$rc" "$var" "$*" "$text"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  rc=%d expected=%s with "%s"  %s %s\n' "$rc" "$expect" "$text" "$var" "$*"
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
run ok   --dry-run --basic --nginx
run ok   --dry-run --basic --php
# --php is a first installation: on a host that already runs PHP-FPM only the
# installed version is accepted (--upgrade-php changes it), so the explicit
# ver= below follows the host.  The plan of a bare --php names that version.
PHP_HOST_VER=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --basic --php 2>&1 \
  | sed -nE 's/.*[[:space:]]version=([0-9]+\.[0-9]+)[[:space:]].*/\1/p' | head -n1)
run ok   --dry-run --basic --php ver="${PHP_HOST_VER:-8.4}" children=32 max_requests=4096
run fail --dry-run --basic --php ver=
run fail --dry-run --upgrade-php --dry-run
if [[ -n $PHP_HOST_VER ]]; then
  PHP_OTHER_VER=8.4
  [[ $PHP_HOST_VER == 8.4 ]] && PHP_OTHER_VER=8.5
  run fail --dry-run --basic --php ver="$PHP_OTHER_VER"
fi
run ok   --dry-run --basic --mariadb user=demo pass=temp size=4gb
run ok   --dry-run --basic --mariadb user=demo pass=temp
run ok   --dry-run --basic --mariadb user=demo pass=temp size=auto bind=127.0.0.1,IPV4
run ok   --dry-run --basic --valkey
run ok   --dry-run --basic --valkey ram=2g policy=allkeys-lfu
# 1.22.5: io_threads= was removed (io-threads is always 1); a passed value,
# even one the old validator refused, is ignored with a warning, never fatal.
run_warn 'Ignored (removed in 1.22.5; io-threads above 1' --dry-run --basic --valkey ram=2g policy=allkeys-lfu io_threads=2
run_warn 'Ignored (removed in 1.22.5; io-threads above 1' --dry-run --basic --valkey io_threads=0
# 1.22.5: noeviction was removed; tcp= takes auto or on (never off).
run fail --dry-run --basic --valkey policy=noeviction
run ok   --dry-run --basic --valkey tcp=on
run ok   --dry-run --basic --valkey tcp=auto
run fail --dry-run --basic --valkey tcp=off
run ok   --dry-run --basic --valkey ram=auto
run ok   --dry-run --basic --elastic ram=4g host=localhost
run fail --dry-run --basic --elastic host=localhost:9200
run fail --dry-run --basic --elastic host=not_a_host
run ok   --dry-run --basic --elastic
run ok   --dry-run --basic --elastic ram=auto
run ok   --dry-run --basic --others all
run ok   --dry-run --basic --others smartmon gif nodejs sysstat
run fail --dry-run --basic --others fail2ban
run fail --dry-run --basic --others unattended
run fail --dry-run --basic --others composer
run fail --dry-run --basic --others security
run ok   --dry-run --basic --nginx --php --mariadb user=u pass=p size=auto \
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
# app= belongs to the domain before it and a following db= must not turn it
# into a trailing group default (a.example.com kept WordPress before).
DOMAIN_PLAN=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --domain a.example.com db=adb user=u pass=p \
  b.example.com app=wordpress db=bdb 2>&1)
if grep -qE 'a\.example\.com app=basic' <<<"$DOMAIN_PLAN" \
   && grep -qE 'b\.example\.com app=wordpress' <<<"$DOMAIN_PLAN"; then
  PASS=$((PASS + 1)); printf 'PASS  per-domain app= survives a following db=\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  per-domain app= leaked to the whole --domain group\n'
  printf '%s\n' "$DOMAIN_PLAN" | grep -E 'domain +[ab]\.example' | sed 's/^/      /'
fi

# Optimize-only mode.
run ok   --dry-run --optimize
run ok   $'—optimize' --dry-run
run ok   $'–optimize' --dry-run
run fail --dry-run --optimize anubis=yes
run fail --reset-overrides
run fail --dry-run --optimize --reset-overrides
run fail --dry-run --basic --reset-overrides
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
run fail --dry-run --restart-all --nginx
run fail --dry-run --optimize --basic
run fail --dry-run --optimize --nginx
run fail --dry-run --optimize --purge
run fail --dry-run --optimize --domain example.com

# Purge modes and bare names.
run ok   --dry-run --purge
run ok   --dry-run --purge all
run ok   --dry-run --purge basic nginx php mariadb valkey elastic others
run ok   --dry-run --purge --nginx --php
run ok   --dry-run --purge --php ver=8.4
run ok   --dry-run --purge php mariadb

# Invalid input must fail early.
run fail --dry-run --basic server=cloud
run fail --dry-run --basic host=-bad
run fail --dry-run --basic swap=0
run_msg "too small" --dry-run --basic swap=1M
run ok   --dry-run --basic swap=64M
run ok   --dry-run --basic swap=8Gi
run ok   --dry-run --purge others
run fail --dry-run --basic time=Nowhere/Nothing
run fail --dry-run --basic --mariadb user=u size=4gb
run fail --dry-run --basic --mariadb user=u pass=p size=0
run fail --dry-run --basic --mariadb user=u pass=p size=4gb bind=bogus
run fail --dry-run --basic --php ver=8
# The source build supports PHP 8.1 and newer; an older series is rejected
# before anything is installed.  The message is asserted: on a host with
# PHP installed the plain `run fail` row passed on "already installed".
run_msg 'the source build supports PHP 8.1 and newer' --dry-run --basic --php ver=8.0
# Reserved MariaDB accounts and system schemas, in any letter case.
run fail --dry-run --basic --mariadb user=root pass=x
run fail --dry-run --basic --mariadb user=ROOT pass=x
run fail --dry-run --basic --mariadb user=mysql pass=x
run fail --dry-run --basic --mariadb user=mariadb pass=x
run ok   --dry-run --basic --mariadb user=rooter pass=x
run fail --dry-run --domain example.com db=mysql
run fail --dry-run --domain example.com db=MySQL
run fail --dry-run --domain example.com db=sys
run fail --dry-run --domain example.com db=information_schema
run fail --dry-run --domain example.com db=performance_schema
run fail --dry-run --domain example.com db=appdb user=root pass=x
run fail --dry-run --domain example.com db=appdb user=Mysql pass=x
run ok   --dry-run --domain example.com db=mysql_app user=sysop pass=x
run fail --dry-run --basic --php children=0
run fail --dry-run --basic --valkey policy=bogus
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
run fail --dry-run --nginx
run fail --dry-run --bogus
run fail --dry-run --sync-nginx

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
run ok   --dry-run --basic --nginx --domain x.example.com
run fail --dry-run --domain x.example.com --nginx
run fail --dry-run --diagnostics --domain x.example.com

# --purge targets: unknown names and malformed --php ver= fail; flag and
# bare-name forms are both accepted.
run fail --dry-run --purge bogus
run fail --dry-run --purge --php ver=8
run ok   --dry-run --purge --basic
run ok   --dry-run --purge --others
run ok   --dry-run --purge basic

# --upgrade-php: standalone PHP version replacement.  The dry run works on a
# host with or without PHP installed and must reject malformed or conflicting
# invocations before anything is purged.
run ok   --dry-run --upgrade-php=8.6
run ok   --dry-run --upgrade-php 8.6
run fail --dry-run --upgrade-php
run fail --dry-run --upgrade-php=abc
# An empty value must fail, not fall through into the mode the other flags
# select (--upgrade-php= --purge used to run a full purge).
run fail --dry-run --upgrade-php=
run fail --dry-run --upgrade-php= --purge
run fail --dry-run --upgrade-php= --basic
run fail --dry-run --upgrade-php ''
run fail --dry-run --upgrade-php --purge
run fail --dry-run --upgrade-php=7.4
run fail --dry-run --upgrade-php=8.6 --basic
run fail --dry-run --upgrade-php=8.6 --optimize
run fail --dry-run --upgrade-php=8.6 --purge
run fail --dry-run --upgrade-php=8.6 --diagnostics
run fail --dry-run --upgrade-php=8.6 --restart-all
run fail --dry-run --upgrade-php=8.6 --domain example.com
run fail --dry-run --upgrade-php=8.6 --upgrade-php=8.5

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
# Network tuning and rate-limit exemption overrides.
run_env ok SETUP_TCP_CC=cubic --dry-run --optimize
run_env ok SETUP_QDISC=fq_codel --dry-run --optimize
# SETUP_LIMIT_REQ_EXEMPT lost its generic limits: accepted, with a warning.
run_env_msg ok 'SETUP_LIMIT_REQ_EXEMPT=10.0.0.5' 'SETUP_LIMIT_REQ_EXEMPT is ignored' --dry-run --optimize
# --source and the SETUP_*_BUILD knobs were removed in 1.22.0 (nginx, PHP and
# Valkey are always built from source).  A runbook that still passes them
# keeps working: each spelling is consumed and ignored with a warning.
run_warn 'is ignored'                --dry-run --optimize --source=all
run_warn '--source=nginx php is ignored' --dry-run --optimize --source nginx php
run_warn '--source=none is ignored'  --dry-run --optimize --source=none
run_warn 'is ignored'                --dry-run --basic --nginx --php --valkey --source=valkey
run_warn 'is ignored'                --dry-run --optimize --source=nginx
run_warn '--source is ignored'       --dry-run --optimize --source
run_env_msg ok 'SETUP_VALKEY_BUILD=clang' 'Ignored (removed in 1.22.0' --dry-run --optimize
run_env_msg ok 'SETUP_VALKEY_BUILD=gcc'   'Ignored (removed in 1.22.0' --dry-run --optimize
run_env_msg ok 'SETUP_PHP_BUILD=package'  'Ignored (removed in 1.22.0' --dry-run --basic --php
run_env_msg ok 'SETUP_NGINX_BUILD=clang'  'Ignored (removed in 1.22.0' --dry-run --basic --nginx
run_env_msg ok 'SETUP_ANGIE_BUILD=package' 'Ignored (removed in 1.22.0' --dry-run --basic --nginx
run_env_msg ok 'SETUP_PHP_FPM_MODULES=all' 'Ignored (removed in 1.22.0' --dry-run --basic --php
# The old compression name still works under the new one.
run_env ok SETUP_ANGIE_COMPRESSION=gzip --dry-run --basic --nginx
# Asset precompression was removed in 1.22.1 (no gzip_static/brotli_static):
# the knob is accepted and ignored with a warning, on every path.
run_env_msg ok 'SETUP_PRECOMPRESS_ASSETS=1' 'Ignored (removed in 1.22.1' --dry-run --optimize
run_env_msg ok 'SETUP_PRECOMPRESS_ASSETS=0' 'Ignored (removed in 1.22.1' --dry-run --basic --nginx
# An invalid SETUP_NODE_MAJOR falls back to the default major, never fails.
run_env ok SETUP_NODE_MAJOR=bogus --dry-run --basic --others nodejs
# SETUP_NGINX_COMPRESSION only tests for 0; any other value keeps Brotli on.
run_env ok SETUP_NGINX_COMPRESSION=gzip --dry-run --basic --nginx
run_env ok SETUP_WP_DB_SPLIT=0 --dry-run --domain a.example.com app=wordpress
run_env ok SETUP_PURGE_MALWARE=0 --dry-run --optimize
# A dry run exits before fetch_server_configs, so CONFIG_SOURCE_DIR is not
# checked and a missing directory does not fail.
run_env ok CONFIG_SOURCE_DIR=/nonexistent --dry-run --basic --nginx

# Anubis support was removed in 1.21.62: every spelling must fail the parse
# with an explanation, and so must a leftover SETUP_ANUBIS in the environment.
run fail --dry-run --basic --nginx anubis=yes
run fail --dry-run --basic --nginx anubis=no
run fail --dry-run --optimize anubis=yes
run fail --dry-run --optimize anubis=no
# CPU mitigations: off is the default since 1.22.5 and mitigations=on was
# removed (refused with an explanation; off stays accepted as a no-op).
run ok   --dry-run --basic mitigations=off
run_msg "mitigations=on was removed" --dry-run --basic mitigations=on
run_msg "mitigations=on was removed" --dry-run --optimize mitigations=on
run_msg "mitigations=on was removed" --dry-run --optimize mitigations=ON
run_warn "CPU mitigations:" --dry-run --basic
run ok   --dry-run --optimize mitigations=off
run fail --dry-run --optimize anubis=yes mitigations=off
run fail --dry-run --basic mitigations=maybe
run fail --dry-run --optimize mitigations=
# Any order: mitigations= after --dry-run used to be an unknown argument.
run ok   --optimize --dry-run mitigations=off
run_msg "mitigations=on was removed" --basic --dry-run mitigations=on
run fail --optimize --dry-run mitigations=sometimes
run fail --dry-run --php mitigations=off
run fail --dry-run mitigations=off
run_env ok   SETUP_CPU_MITIGATIONS=off --dry-run --optimize
run_env fail SETUP_CPU_MITIGATIONS=sometimes --dry-run --optimize
run_env_msg fail SETUP_CPU_MITIGATIONS=on "mitigations=on (SETUP_CPU_MITIGATIONS=on) was removed" --dry-run --optimize
run_env_msg fail SETUP_CPU_MITIGATIONS=1 "was removed in 1.22.5" --dry-run --basic
run fail --dry-run --optimize anubis=1
# 1.22.13: --optimize ext=LIST changes the PHP extension set on any release.
run ok   --dry-run --optimize ext=-calendar,-gettext,-shmop,-ftp,-pdo,-pdo_mysql,-xmlreader
run ok   --dry-run --optimize mitigations=off ext=imagick
run ok   --dry-run --optimize ext=none
run ok   --dry-run --optimize ext=minimal
run ok   --dry-run --optimize ext=minimal,intl
run_msg "cannot compile this extension" --dry-run --optimize ext=xsl
run_msg "is not an extension name" --dry-run --optimize 'ext=bad;name'
run_msg "requires a list" --dry-run --optimize ext=
run_msg "cannot be combined with other names" --dry-run --optimize ext=none,intl
run fail --dry-run --optimize anubis=yes ext=imagick
run fail --dry-run --basic anubis=yes
run fail --dry-run --basic --nginx anubis=maybe
run fail --dry-run --basic --php anubis=yes
run_env fail SETUP_ANUBIS=1 --dry-run --basic --nginx
run_env fail SETUP_ANUBIS=bogus --dry-run --basic --nginx

# ---------------------------------------------------------------------------
# 1.22.0: nginx built from source, --angie alias, --php ext=, memory gate,
# the migration plan of --optimize.
# ---------------------------------------------------------------------------
# --nginx installs the compiled nginx; --angie is a deprecated alias that
# still installs nginx, with a warning naming --nginx.
run ok   --dry-run --basic --nginx
run_warn '--angie is deprecated' --dry-run --basic --angie
run_warn 'Use --nginx' --dry-run --basic --angie --php
run fail --dry-run --angie
run fail --dry-run --optimize --angie
run fail --dry-run --restart-all --angie
run_warn '--purge angie is deprecated' --dry-run --purge angie
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --purge angie 2>&1)
if grep -qE '^Purge order: nginx$' <<<"$out"; then
  PASS=$((PASS + 1)); printf 'PASS  --purge angie purges nginx\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --purge angie does not map to the nginx target\n'
  grep -E '^Purge order' <<<"$out" | sed 's/^/      /'
fi
run_warn '--angie is deprecated' --dry-run --basic --nginx --angie
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --basic --angie 2>&1)
if grep -qE '^Services +:.*(^|[[:space:]:])nginx([[:space:]]|$)' <<<"$out" \
   && ! grep -qE '^Services +:.*angie' <<<"$out"; then
  PASS=$((PASS + 1)); printf 'PASS  --angie selects the nginx service\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --angie does not select the nginx service\n'
  grep -E '^Services' <<<"$out" | sed 's/^/      /'
fi
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --basic --nginx 2>&1)
if [[ $out != *deprecated* ]]; then
  PASS=$((PASS + 1)); printf 'PASS  --nginx prints no deprecation warning\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --nginx printed a deprecation warning\n'
fi

# --php ext=LIST: names, -NAME, none; refused before --basic changes anything.
run ok   --dry-run --basic --php ext=intl,gmp
run ok   --dry-run --basic --php ext=INTL
run ok   --dry-run --basic --php ext=-intl
run ok   --dry-run --basic --php ext=none
run ok   --dry-run --basic --php ext=redis,igbinary children=8
run_msg 'requires a list'          --dry-run --basic --php ext=
run_msg 'cannot be combined'       --dry-run --basic --php ext=none,intl
run_msg 'is not an extension name' --dry-run --basic --php ext=intl.so
run_msg 'is not an extension name' --dry-run --basic --php 'ext=intl;id'
run_msg 'cannot compile this extension' --dry-run --basic --php ext=oci8
run_msg 'not a purge option'       --dry-run --purge --php ext=intl
run fail --dry-run --php ext=intl
run fail --dry-run --basic --valkey ext=intl
run fail --dry-run --basic --nginx ext=intl
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --basic --php ext=intl,gmp 2>&1)
if grep -qE '^PHP +:.* ext=intl,gmp( |$)' <<<"$out"; then
  PASS=$((PASS + 1)); printf 'PASS  the plan shows the requested ext= list\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  the plan does not show the requested ext= list\n'
  grep -E '^PHP' <<<"$out" | sed 's/^/      /'
fi

# Memory gate (section 7): SETUP_MEM_TOTAL_MB stands in for the host's RAM in
# a dry run.  Below the 4 GB class (3500 MB) only nginx (and --basic,
# --others, static/Node sites) is allowed; refusals come before any change.
GATE='below the 4 GB class'
run_env_msg ok   SETUP_MEM_TOTAL_MB=2048 'Memory class : 2048 MB (below the 4 GB class' --dry-run --basic --nginx
run_env_msg ok   SETUP_MEM_TOTAL_MB=3499 'Memory class : 3499 MB' --dry-run --basic --nginx --others sysstat
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --php
run_env_msg fail SETUP_MEM_TOTAL_MB=3499 "$GATE" --dry-run --basic --php
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --valkey
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --mariadb user=u pass=p
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --elastic
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --nginx --php
run_env_msg ok   SETUP_MEM_TOTAL_MB=3500 'Memory class : 3500 MB (4 GB class' --dry-run --basic --php
run_env_msg ok   SETUP_MEM_TOTAL_MB=8192 'Memory class : 8192 MB (4 GB class' --dry-run --basic --nginx --php --valkey
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 'needs PHP' --dry-run --domain a.example.com app=wordpress
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 'needs PHP' --dry-run --domain a.example.com app=basic b.example.com app=xf
run_env ok   SETUP_MEM_TOTAL_MB=2048 --dry-run --domain a.example.com app=basic
run_env ok   SETUP_MEM_TOTAL_MB=2048 --dry-run --domain a.example.com app=node
run_env ok   SETUP_MEM_TOTAL_MB=2048 --dry-run --domain a.example.com app=pingvin
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --upgrade-php=8.6
run_env ok   SETUP_MEM_TOTAL_MB=8192 --dry-run --upgrade-php=8.6
run_env ok   SETUP_MEM_TOTAL_MB=2048 --dry-run --optimize
# A malformed value is ignored (the host's RAM decides), never a failure.
run_env ok   SETUP_MEM_TOTAL_MB=2g --dry-run --basic --nginx
# The gate is checked before ext= is recorded: a small host is refused even
# with a valid list.
run_env_msg fail SETUP_MEM_TOTAL_MB=2048 "$GATE" --dry-run --basic --php ext=intl
run_env_msg ok   SETUP_MEM_TOTAL_MB=2048 'Migration 1.22' --dry-run --optimize
# Outside --dry-run SETUP_MEM_TOTAL_MB is ignored with a warning (R39): an
# exported value must not let a 1-2 GB host build PHP, nor refuse a large
# one.  validate_all runs before the root check, so an unprivileged call
# prints the warning and then stops at "must be run as root" without
# changing anything.  Never run as root: the call would be a real install.
MEM_HOST_MB=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
if (( ${EUID:-$(id -u)} != 0 )); then
  run_env_msg fail SETUP_MEM_TOTAL_MB=2048 'SETUP_MEM_TOTAL_MB is ignored outside --dry-run' --basic --valkey
  if [[ ${MEM_HOST_MB:-0} =~ ^[0-9]+$ ]] && (( MEM_HOST_MB >= 4096 )); then
    out=$(env SETUP_MEM_TOTAL_MB=2048 bash "$SCRIPT_DIR/setup.sh" --basic --valkey 2>&1)
    if [[ $out != *"$GATE"* && $out == *"must be run as root"* ]]; then
      PASS=$((PASS + 1)); printf 'PASS  a real run ignores SETUP_MEM_TOTAL_MB (no gate refusal on a %s MB host)\n' "$MEM_HOST_MB"
    else
      FAIL=$((FAIL + 1)); printf 'FAIL  a real run honoured SETUP_MEM_TOTAL_MB\n'
      printf '%s\n' "$out" | grep -E 'GB class|root' | sed 's/^/      /'
    fi
  fi
fi

# --optimize --dry-run prints the 1.22 migration plan (or "nothing to
# migrate") from migrate_plan; a --domain run never plans or starts it.
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --optimize 2>&1)
if grep -qE '^Migration 1\.22(: nothing to migrate \((nginx|angie-legacy|none)\)| \(runs detached as setup-migrate-1\.22, log )' <<<"$out"; then
  PASS=$((PASS + 1)); printf 'PASS  --optimize --dry-run prints the migrate_plan lines\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --optimize --dry-run prints no migrate_plan line\n'
  grep -E 'Migration' <<<"$out" | sed 's/^/      /'
fi
# A pending migration is planned, never started, by a dry run: the detached
# unit's plan names the cutover windows and the kept backups.
if grep -q '^Migration 1\.22 (runs detached' <<<"$out"; then
  if [[ $out == *"cutover windows:"* && $out == *"removals run only after every cutover verified"* ]]; then
    PASS=$((PASS + 1)); printf 'PASS  the migration plan names the cutover windows and removals\n'
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  the migration plan is incomplete\n'
  fi
fi
out=$(bash "$SCRIPT_DIR/setup.sh" --dry-run --domain a.example.com 2>&1)
if [[ $out != *"Migration 1.22"* && $out != *setup-migrate-1.22* ]]; then
  PASS=$((PASS + 1)); printf 'PASS  --domain --dry-run never plans the migration\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --domain --dry-run mentions the migration\n'
fi
# The migration unit's hidden mode is not a command-line option.
run fail --dry-run --optimize --migrate-1.22-unit /tmp/report

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
