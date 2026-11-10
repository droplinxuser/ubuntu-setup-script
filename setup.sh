#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Ubuntu 26.04 server provisioning
# =============================================================================
#  Usage is documented in usage() below and in the project notes.
#
#  Design notes:
#   * Runs as root only.
#   * Idempotent: every step can be re-run on an already configured machine.
#   * Only the services named on the command line are touched.
#   * Angie configuration is owned by
#     https://github.com/droplinxuser/server-configs-nginx and downloaded at
#     install time.  PHP-FPM pool/php.ini templates are non-Angie config and
#     live locally in configs/php.  Do not add Angie config content to this
#     script; update the Angie repo.
#     Other vendor payloads that must be reproducible offline are embedded in
#     the "EMBEDDED PAYLOADS" section at the bottom.
#   * Each service is timed; a summary is printed at the end.
#   * Every run mirrors its complete output to setup_<timestamp>.log in the
#     invocation directory so the log can be handed to a debugging agent.
#   * `--purge` stops/disables selected services and restores recorded basic
#     settings; it never removes packages, data, configuration or log files.
# =============================================================================

set -Eeuo pipefail
# 4.4 is the real floor: empty-array expansion under `set -u` and `wait` on
# a process-substitution PID (the log mirror) both need it.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf '%s: bash 4.4 or newer is required (found %s)\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 1
fi
shopt -s inherit_errexit 2>/dev/null || true
umask 022
# Providers often ship an ungenerated locale (e.g. en_PH.UTF-8), which makes
# apt/perl print noisy warnings. C.UTF-8 always exists on Ubuntu.
export LC_ALL=C.UTF-8

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.19.0"
# Congestion control and qdisc for the OS profile.  BBR is a good default on
# lossy long-haul links, but it can regress a busy reverse proxy badly (a
# 40% throughput drop was measured on one host).  Operators can pin a host
# with SETUP_TCP_CC / SETUP_QDISC or /etc/default/setup-tuning:
#   TCP_CC="cubic"
#   QDISC="fq_codel"
TCP_CC=bbr
QDISC=fq
if [[ -r /etc/default/setup-tuning ]]; then
  # shellcheck disable=SC1091
  . /etc/default/setup-tuning
  TCP_CC="${TCP_CC:-bbr}"
  QDISC="${QDISC:-fq}"
fi
# The environment wins over the host file so a one-off run can be tested.
TCP_CC="${SETUP_TCP_CC:-$TCP_CC}"
QDISC="${SETUP_QDISC:-$QDISC}"
[[ $TCP_CC =~ ^[a-z0-9_]+$ ]] || TCP_CC=bbr
[[ $QDISC =~ ^[a-z0-9_]+$ ]] || QDISC=fq
# Rate-limit exemptions (load generator, monitor, reverse proxy) live in the
# same host file so a plain --optimize keeps them; SETUP_LIMIT_REQ_EXEMPT in
# the environment overrides and is persisted there (an empty value clears).
LIMIT_REQ_EXEMPT="${LIMIT_REQ_EXEMPT:-}"
LIMIT_REQ_EXEMPT_PERSIST=0
if [[ -n ${SETUP_LIMIT_REQ_EXEMPT+x} ]]; then
  LIMIT_REQ_EXEMPT=$SETUP_LIMIT_REQ_EXEMPT
  LIMIT_REQ_EXEMPT_PERSIST=1
fi
# Static-asset precompression (.br/.gz siblings served by brotli_static and
# gzip_static) is off by default: behind a CDN the origin rarely serves
# assets.  SETUP_PRECOMPRESS_ASSETS=1 turns it on for an origin that serves
# its own assets and is persisted in the same host file (0 turns it off).
PRECOMPRESS_ASSETS="${PRECOMPRESS_ASSETS:-0}"
PRECOMPRESS_ASSETS_PERSIST=0
if [[ -n ${SETUP_PRECOMPRESS_ASSETS+x} ]]; then
  PRECOMPRESS_ASSETS=$SETUP_PRECOMPRESS_ASSETS
  PRECOMPRESS_ASSETS_PERSIST=1
fi
# OPcache JIT: the tracing JIT is always on for the pool (buffer OPcache/8,
# 32..128 MB, with PHP's default hotness thresholds on 4+ CPU hosts and a
# conservative set on 1-2 CPU hosts; measured +5% on the CPU-bound XenForo
# member tiers and neutral-to-positive on WordPress, see
# tests/stress-site/RESULTS.md).  There is no mode switch any more; an old
# SETUP_PHP_JIT / persisted PHP_JIT value is ignored.  WordPress roots use
# it too by default; SETUP_PHP_JIT_WORDPRESS=0 (persisted as
# PHP_JIT_WORDPRESS) keeps `opcache.jit = off` for every WordPress document
# root through a [PATH=] section of the managed ini (applied per request by
# php-fpm, unlike a per-vhost fastcgi_param, which sticks to the worker) for
# a site that misbehaves with the JIT.
if [[ -n ${SETUP_PHP_JIT+x} && ${SETUP_PHP_JIT} != tracing ]]; then
  printf 'setup.sh: SETUP_PHP_JIT=%s is ignored; the tracing JIT is always on (SETUP_PHP_JIT_WORDPRESS=0 exempts WordPress roots)\n' "$SETUP_PHP_JIT" >&2
fi
PHP_JIT_WORDPRESS="${PHP_JIT_WORDPRESS:-1}"
PHP_JIT_WORDPRESS_PERSIST=0
if [[ -n ${SETUP_PHP_JIT_WORDPRESS+x} ]]; then
  PHP_JIT_WORDPRESS=$SETUP_PHP_JIT_WORDPRESS
  PHP_JIT_WORDPRESS_PERSIST=1
fi
[[ $PHP_JIT_WORDPRESS == 0 ]] || PHP_JIT_WORDPRESS=1
[[ $PRECOMPRESS_ASSETS == 1 ]] || PRECOMPRESS_ASSETS=0
# XenForo job runner.  XenForo runs its job queue (cron tasks, search
# indexing, XFMG video transcoding) inside member page requests by default
# ("Job run trigger: activity-based").  With the admin option switched to
# server-based, a scheduler has to run `cmd.php xf:run-jobs` instead, so
# setup.sh installs one managed crontab entry that runs the queue of every
# XenForo root under /var/www once a minute as the PHP user.  Running it as
# www-data also stops the root-owned data directories a root CLI run leaves
# behind (Angie then returns 403 for every file below them; 16% of the
# requests on one audited host).  SETUP_XF_JOB_CRON=0 drops the entry and is
# persisted in the same host file (XF_JOB_CRON).
XF_JOB_CRON="${XF_JOB_CRON:-1}"
XF_JOB_CRON_PERSIST=0
if [[ -n ${SETUP_XF_JOB_CRON+x} ]]; then
  XF_JOB_CRON=$SETUP_XF_JOB_CRON
  XF_JOB_CRON_PERSIST=1
fi
[[ $XF_JOB_CRON == 0 ]] || XF_JOB_CRON=1
# Node.js major installed by --others nodejs.  NodeSource publishes one APT
# line per major, so this value decides what `apt-get install nodejs` resolves
# to.  A major change swaps NODE_MODULE_VERSION (the native-addon ABI), so a
# host that already runs another major is left alone unless the switch is
# explicitly allowed: prebuilt addons die otherwise (soketi 1.6.1 bundles a
# uWebSockets.js with Node 14/16/18 binaries only, so upgrading 18 -> 26 broke
# a live websocket service).  Pin a host with SETUP_NODE_MAJOR or
# /etc/default/setup-tuning (NODE_MAJOR=18), and allow a one-off switch with
# SETUP_NODE_ALLOW_MAJOR_UPGRADE=1.
NODE_MAJOR="${SETUP_NODE_MAJOR:-${NODE_MAJOR:-26}}"
[[ $NODE_MAJOR =~ ^[0-9]+$ ]] || NODE_MAJOR=26
NODE_ALLOW_MAJOR_UPGRADE="${SETUP_NODE_ALLOW_MAJOR_UPGRADE:-${NODE_ALLOW_MAJOR_UPGRADE:-0}}"
[[ $NODE_ALLOW_MAJOR_UPGRADE == 1 ]] || NODE_ALLOW_MAJOR_UPGRADE=0
NODE_MAJOR_SWITCH_BLOCKED=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# The path shown in the run log.  Captured here because BASH_SOURCE[0] inside
# a sourced lib/*.sh names the library, not the driver the operator ran.
readonly SCRIPT_INVOKED_AS="${BASH_SOURCE[0]}"
# SETUP_STATE_DIR lets the unit tests (and a chroot/image build) use a private
# state directory instead of the live host state.
readonly STATE_DIR="${SETUP_STATE_DIR:-/var/lib/setup.sh}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
# Every service writes its logs below this single directory so an operator can
# collect one tree (tar -czf /tmp/logs.tgz -C /var/www logs) for inspection.
readonly LOG_ROOT="/var/www/logs"
# Angie and PHP configuration is owned by this repository, not by setup.sh.
# Override the ref or point CONFIG_SOURCE_DIR at a local checkout for testing.
readonly CONFIG_REPO_URL="${CONFIG_REPO_URL:-https://github.com/droplinxuser/server-configs-nginx}"
readonly CONFIG_REPO_REF="${CONFIG_REPO_REF:-main}"
CONFIG_SOURCE_DIR="${CONFIG_SOURCE_DIR:-}"
CONFIG_TEMP_DIR=""
readonly CRON_BEGIN="# BEGIN setup.sh managed cron"
readonly CRON_END="# END setup.sh managed cron"
# Keep web content owned by www-data without touching the shared log tree.
# MariaDB, Valkey and Elasticsearch own subdirectories below /var/www/logs; a
# blanket recursive chown changes their owner to www-data and their next start
# or restart fails to open/rotate logs ("Permission denied", errno 13).
readonly CRON_WWW_CHOWN='/usr/bin/find /var/www -mindepth 1 \( -path /var/www/logs -o -path /var/www/mysql_database -o -name "*.log" -o -name "wp-config.php" \) -prune -o -exec /usr/bin/chown -h www-data:www-data {} +'
# The form written by releases up to 1.8.33, kept so a re-run upgrades it.
readonly CRON_WWW_CHOWN_LEGACY='/usr/bin/chown www-data:www-data -R /var/www/'
# Helper that keeps precompressed static assets fresh (SETUP_PRECOMPRESS_ASSETS=1).
readonly CRON_PRECOMPRESS='/usr/local/bin/setup-precompress.sh'
# WordPress ships its own pseudo-cron.  When the hardening step disables it
# (DISABLE_WP_CRON), this managed entry runs every site's wp-cron.php as the
# PHP user so scheduled posts, updates and plugin jobs still fire.
readonly CRON_WP_CRON='/usr/bin/find /var/www -maxdepth 6 -type f -name wp-config.php ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do [ -f "$d/wp-cron.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$d/wp-cron.php"; done || true'
# XenForo job runner (XF_JOB_CRON): every XenForo root under /var/www runs its
# queue once a minute as the PHP user.  --max-execution-time keeps one run
# inside the minute; XenForo's own job lock prevents overlapping runners.
# No "%" may appear here: crontab treats it as a newline.
readonly CRON_XF_JOBS='/usr/bin/find /var/www -maxdepth 6 -type f -path "*/src/config.php" ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do r=$(/usr/bin/dirname "$d"); [ -f "$r/cmd.php" ] && [ -f "$d/XF.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$r/cmd.php" xf:run-jobs --max-execution-time=50 >/dev/null 2>&1; done || true'
readonly MARIADB_BEGIN="# BEGIN setup.sh managed mariadb"
readonly MARIADB_END="# END setup.sh managed mariadb"
readonly ES_BEGIN="# BEGIN setup.sh managed elasticsearch"
readonly ES_END="# END setup.sh managed elasticsearch"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
# Wait for a concurrent apt/dpkg run instead of failing outright (package
# management tools often hold the lock briefly).
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
          -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0
          -o Acquire::Retries=3 -o Acquire::http::Timeout=30)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi


# ---------------------------------------------------------------------------
# Module layout: the implementation lives in lib/*.sh and is sourced in
# dependency order.  Keep each block in the same order: later modules
# define functions that earlier top-level statements may call at run time.
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# shellcheck source=lib/cli.sh
source "${SCRIPT_DIR}/lib/cli.sh"

# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"

# shellcheck source=lib/util.sh
source "${SCRIPT_DIR}/lib/util.sh"

# shellcheck source=lib/os.sh
source "${SCRIPT_DIR}/lib/os.sh"

# shellcheck source=lib/web.sh
source "${SCRIPT_DIR}/lib/web.sh"

# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"

# shellcheck source=lib/purge.sh
source "${SCRIPT_DIR}/lib/purge.sh"

# shellcheck source=lib/runner.sh
source "${SCRIPT_DIR}/lib/runner.sh"

# shellcheck source=lib/optimize.sh
source "${SCRIPT_DIR}/lib/optimize.sh"

# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# shellcheck source=lib/diagnostics.sh
source "${SCRIPT_DIR}/lib/diagnostics.sh"

# shellcheck source=lib/restart.sh
source "${SCRIPT_DIR}/lib/restart.sh"

# shellcheck source=lib/payloads.sh
source "${SCRIPT_DIR}/lib/payloads.sh"


# Tests source this file with SETUP_TEST_SOURCE_ONLY=1 to exercise the pure
# helper functions without running an installation.
if [[ ${SETUP_TEST_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
