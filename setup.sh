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
#   * nginx configuration is owned by
#     https://github.com/droplinxuser/server-configs-nginx (branch main)
#     and downloaded at install time.  PHP-FPM pool/php.ini templates
#     are non-nginx config and live locally in configs/php.  Do not add nginx
#     config content to this script; update the nginx repo.
#     Other vendor payloads that must be reproducible offline are embedded in
#     the "EMBEDDED PAYLOADS" section at the bottom.
#   * nginx, PHP (FPM + CLI) and Valkey are always built from upstream source
#     (tools/*-build.sh, lib/*-build.sh); there are no package modes.  Hosts
#     below the 4 GB class run nginx only (mem_gate_allows).
#   * Each service is timed; a summary is printed at the end.
#   * Every run mirrors its complete output to setup_<timestamp>.log in the
#     invocation directory so the log can be handed to a debugging agent.
#   * `--purge` stops/disables selected services and restores recorded basic
#     settings; it never removes packages, data, configuration or log files
#     (a purged source build loses its binaries, unit and links only).
#   * The one-time 1.22 migration (lib/migrate.sh, run by --optimize) is the
#     only path that removes packages: Angie, Sury PHP and valkey-server go
#     only after the source builds serve and verify, with every .deb and
#     configuration kept in /var/backups/setup-1.22.
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
readonly SCRIPT_VERSION="1.22.8"
# Congestion control and qdisc for the OS profile.  BBR is a good default on
# lossy long-haul links, but it can regress a busy reverse proxy badly (a
# 40% throughput drop was measured on one host).  Operators can pin a host
# with SETUP_TCP_CC / SETUP_QDISC or /etc/default/setup-tuning:
#   TCP_CC="cubic"
#   QDISC="fq_codel"
TCP_CC=bbr
QDISC=fq
# Unit tests (SETUP_TEST_SOURCE_ONLY=1) never read the host's pins: a
# provisioned test host with STORAGE_CLASS=, TCP_CC= ... recorded made the
# stubbed classification checks report the pin instead of the stub.
if [[ ${SETUP_TEST_SOURCE_ONLY:-0} != 1 && -r /etc/default/setup-tuning ]]; then
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
# Rate-limit exemptions went away with the generic GET/POST limits
# (server-configs-nginx 1.6.61): the only limit left is the credential zone,
# which never honoured them.  A LIMIT_REQ_EXEMPT an older release persisted in
# the host file is still read, and only as a hint for the TLS catch-all guard
# (an exempt address was usually a reverse proxy in front);
# SETUP_LIMIT_REQ_EXEMPT itself is ignored with a warning.
LIMIT_REQ_EXEMPT="${LIMIT_REQ_EXEMPT:-}"
LIMIT_REQ_EXEMPT_IGNORED=0
[[ -n ${SETUP_LIMIT_REQ_EXEMPT+x} ]] && LIMIT_REQ_EXEMPT_IGNORED=1
# Static-asset precompression (.br/.gz siblings for brotli_static and
# gzip_static, 1.21.58-1.22.0) was removed in 1.22.1 together with those two
# modules: nginx compresses with dynamic gzip and Brotli only.  An exported
# SETUP_PRECOMPRESS_ASSETS is remembered for the warning validate_all prints
# and dropped from the environment; a PRECOMPRESS_ASSETS line an older
# release persisted in the host file is dropped from memory here.
RETIRED_PRECOMPRESS_ENV=""
if [[ -n ${SETUP_PRECOMPRESS_ASSETS+x} ]]; then
  RETIRED_PRECOMPRESS_ENV="SETUP_PRECOMPRESS_ASSETS=${SETUP_PRECOMPRESS_ASSETS}"
  unset SETUP_PRECOMPRESS_ASSETS
fi
unset PRECOMPRESS_ASSETS
# The opt-in PHP session/cgi hardening (SETUP_PHP_SESSION_HARDENING=1, 1.6.10)
# was removed in 1.22.5 (operator decision).  An exported value is reported
# by validate_all and ignored; a PHP_SESSION_HARDENING line in the host file
# is dropped from memory here and from the file by persist_php_jit, and the
# next PHP tune rewrites zz-setup-optimize.ini without the block.
RETIRED_SESSION_HARDENING_ENV=""
if [[ -n ${SETUP_PHP_SESSION_HARDENING+x} ]]; then
  RETIRED_SESSION_HARDENING_ENV="SETUP_PHP_SESSION_HARDENING=${SETUP_PHP_SESSION_HARDENING}"
  unset SETUP_PHP_SESSION_HARDENING
fi
unset PHP_SESSION_HARDENING
# Performance knobs removed in 1.22.5 because no value measured faster than
# the hardware-derived default: the tracing-JIT hotness overrides
# SETUP_PHP_JIT_HOT_{LOOP,FUNC,RETURN,SIDE_EXIT} and the SETUP_GZIP_LEVEL
# pin.  An exported value is remembered for the warning validate_all prints
# and dropped from the environment, never fatal.
RETIRED_PERF_ENV=()
for _retired in SETUP_PHP_JIT_HOT_LOOP SETUP_PHP_JIT_HOT_FUNC SETUP_PHP_JIT_HOT_RETURN \
                SETUP_PHP_JIT_HOT_SIDE_EXIT SETUP_GZIP_LEVEL; do
  if [[ -n ${!_retired+x} ]]; then
    RETIRED_PERF_ENV+=("${_retired}=${!_retired}")
    unset "$_retired"
  fi
done
unset _retired
# The opt-in monthly OPTIMIZE rebuild (SETUP_MARIADB_MONTHLY_OPTIMIZE=1,
# persisted as MARIADB_MONTHLY_OPTIMIZE) was removed in 1.22.5: the monthly
# mariadb-check always runs ANALYZE.  An exported value is reported by
# validate_all and ignored; a persisted line is dropped from memory here and
# from the host file by write_cron (mariadb_monthly_optimize_retire).
RETIRED_MONTHLY_OPTIMIZE_ENV=""
if [[ -n ${SETUP_MARIADB_MONTHLY_OPTIMIZE+x} ]]; then
  RETIRED_MONTHLY_OPTIMIZE_ENV="SETUP_MARIADB_MONTHLY_OPTIMIZE=${SETUP_MARIADB_MONTHLY_OPTIMIZE}"
  unset SETUP_MARIADB_MONTHLY_OPTIMIZE
fi
unset MARIADB_MONTHLY_OPTIMIZE
# OPcache JIT: the tracing JIT is always on for the pool (buffer OPcache/8,
# 32..128 MB, with tuned hotness thresholds (64/127/16/64) on 3+ CPU hosts and a
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
# Guest-cache page compression: PHP gzips the output of WordPress and
# Chevereto document roots that sit behind the FastCGI guest cache, so the
# cache stores the compressed page instead of nginx compressing every hit
# (see php_page_gzip_roots).  SETUP_PHP_PAGE_GZIP=0 turns it off and is
# persisted in the same host file (PHP_PAGE_GZIP).
PHP_PAGE_GZIP="${PHP_PAGE_GZIP:-1}"
PHP_PAGE_GZIP_PERSIST=0
if [[ -n ${SETUP_PHP_PAGE_GZIP+x} ]]; then
  PHP_PAGE_GZIP=$SETUP_PHP_PAGE_GZIP
  PHP_PAGE_GZIP_PERSIST=1
fi
[[ $PHP_PAGE_GZIP == 0 ]] || PHP_PAGE_GZIP=1
# Build-mode knobs retired in 1.22.0.  nginx, PHP and Valkey are always built
# from upstream source, and the PHP extension set follows the applications
# the host serves (lib/php-build.sh; --php ext=LIST adds to it, persisted as
# PHP_EXT_EXTRA).  A 1.21.x host file still carries PHP_BUILD, ANGIE_BUILD,
# NGINX_BUILD, VALKEY_BUILD or PHP_FPM_MODULES: they are dropped from memory
# here so no code path can act on them, and the 1.22 migration removes them
# from the file (keeping a copy; it records PHP_FPM_MODULES first, because
# =all said 1.21 kept every module in FPM).  An exported SETUP_* knob is
# remembered for the warning validate_all prints (the run log is not open
# yet) and then dropped from the environment, so no child tool sees it.
RETIRED_BUILD_ENV=()
for _retired in SETUP_PHP_BUILD SETUP_ANGIE_BUILD SETUP_NGINX_BUILD SETUP_VALKEY_BUILD SETUP_PHP_FPM_MODULES; do
  if [[ -n ${!_retired+x} ]]; then
    RETIRED_BUILD_ENV+=("${_retired}=${!_retired}")
    unset "$_retired"
  fi
done
unset _retired PHP_BUILD ANGIE_BUILD NGINX_BUILD VALKEY_BUILD PHP_FPM_MODULES
# SETUP_ANGIE_COMPRESSION was renamed SETUP_NGINX_COMPRESSION; an operator
# environment that still exports the old name keeps working (the new name
# wins when both are set), and --optimize ignores it under the new name.
if [[ -n ${SETUP_ANGIE_COMPRESSION+x} ]]; then
  [[ -n ${SETUP_NGINX_COMPRESSION+x} ]] || export SETUP_NGINX_COMPRESSION=$SETUP_ANGIE_COMPRESSION
  unset SETUP_ANGIE_COMPRESSION
fi
# XenForo job runner.  XenForo runs its job queue (cron tasks, search
# indexing, XFMG video transcoding) inside member page requests by default
# ("Job run trigger: activity-based").  With the admin option switched to
# server-based, a scheduler has to run `cmd.php xf:run-jobs` instead, so
# setup.sh installs one managed crontab entry that runs the queue of every
# XenForo root under /var/www once a minute as the PHP user.  Running it as
# www-data also stops the root-owned data directories a root CLI run leaves
# behind (nginx then returns 403 for every file below them; 16% of the
# requests on one audited host).  SETUP_XF_JOB_CRON=0 drops the entry and is
# persisted in the same host file (XF_JOB_CRON).
XF_JOB_CRON="${XF_JOB_CRON:-1}"
XF_JOB_CRON_PERSIST=0
if [[ -n ${SETUP_XF_JOB_CRON+x} ]]; then
  XF_JOB_CRON=$SETUP_XF_JOB_CRON
  XF_JOB_CRON_PERSIST=1
fi
[[ $XF_JOB_CRON == 0 ]] || XF_JOB_CRON=1
# Cloudflare-proxied sites (DNS only at Cloudflare, SSL mode "Full") use the
# host's self-signed certificate; --optimize moves their vhosts off certbot,
# checks them through Cloudflare and purges certbot when nothing else uses
# it (lib/web.sh, cloudflare_tls_migrate).  SETUP_CF_SELF_SIGNED=0 or
# CF_SELF_SIGNED=0 in /etc/default/setup-tuning leaves certbot certificates
# alone.  It does not stop the 1.22 migration from moving Angie ACME vhosts
# (acme / acme_client / $acme_cert_*) to the self-signed pair: nginx cannot
# parse those directives, so that rewrite is mandatory (lib/migrate.sh).
CF_SELF_SIGNED_PERSIST=0
if [[ -n ${SETUP_CF_SELF_SIGNED+x} ]]; then
  CF_SELF_SIGNED_PERSIST=1
fi
CF_SELF_SIGNED="${SETUP_CF_SELF_SIGNED:-${CF_SELF_SIGNED:-1}}"
[[ $CF_SELF_SIGNED == 0 ]] || CF_SELF_SIGNED=1
# Unknown-SNI rejection on the catch-all HTTPS server (lib/web.sh,
# tune_default_tls_reject): auto (default) skips it when a vhost trusts a
# reverse proxy outside Cloudflare, 1 forces it on, 0 off.
SSL_REJECT_UNKNOWN_SNI="${SETUP_SSL_REJECT_UNKNOWN_SNI:-${SSL_REJECT_UNKNOWN_SNI:-auto}}"
[[ $SSL_REJECT_UNKNOWN_SNI =~ ^(auto|0|1)$ ]] || SSL_REJECT_UNKNOWN_SNI=auto
# XenForo page compression.  XenForo gzips every page itself at level 9
# (15% of member-page PHP CPU on the audit host).  With XF_MEMBER_GZIP=nginx
# (default) a managed block at the end of each XenForo src/config.php keeps
# XenForo's gzip for guests -- the FastCGI guest cache stores that compressed
# body, so a hit costs no compression -- and turns it off for visitors with a
# session cookie, whose pages nginx compresses (Brotli level 1, gzip level 4).
# SETUP_XF_MEMBER_GZIP=xenforo removes the block; the choice is persisted in
# /etc/default/setup-tuning.  Since server-configs-nginx 1.6.56 the uncached
# nginx handler withholds Accept-Encoding from PHP, so uncached pages are
# compressed by nginx whatever the block says (new installs included); the
# block remains a second guard for hosts on an older tree.  A 1.21.x host
# file says XF_MEMBER_GZIP=angie: anything but xenforo means the web server
# compresses, so it reads as nginx (the migration rewrites the file).
XF_MEMBER_GZIP="${XF_MEMBER_GZIP:-nginx}"
XF_MEMBER_GZIP_PERSIST=0
if [[ -n ${SETUP_XF_MEMBER_GZIP+x} ]]; then
  XF_MEMBER_GZIP=$SETUP_XF_MEMBER_GZIP
  XF_MEMBER_GZIP_PERSIST=1
fi
[[ $XF_MEMBER_GZIP == xenforo ]] || XF_MEMBER_GZIP=nginx
# CPU vulnerability mitigations (Spectre/Meltdown/MDS/Retbleed...).  Since
# 1.22.5 every --basic and --optimize adds `mitigations=off` to the kernel
# command line through a managed GRUB drop-in (effective after the next
# reboot; lib/os.sh configure_cpu_mitigations).  mitigations=on and
# SETUP_CPU_MITIGATIONS=on were removed (validate_all refuses them); a
# persisted CPU_MITIGATIONS=on moves to off.  --purge basic removes it.
# Measured on the Xeon E-2236 (PTI + IBRS): see tests/stress-site/RESULTS.md.
CPU_MITIGATIONS="${CPU_MITIGATIONS:-}"
CPU_MITIGATIONS_SETTING=""
if [[ -n ${SETUP_CPU_MITIGATIONS+x} ]]; then
  CPU_MITIGATIONS_SETTING=$SETUP_CPU_MITIGATIONS
fi
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
# nginx configuration is owned by this repository, not by setup.sh.
# Override the ref or point CONFIG_SOURCE_DIR at a local checkout for testing.
# The nginx tree is the repository's only branch, main.  Tags: nginx (the
# frozen 1.7.1 tree that setup.sh 1.22.0/1.22.1 download) and angie-final
# (the last Angie tree, for hosts kept on 1.21.x).
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
# WordPress ships its own pseudo-cron.  When the hardening step disables it
# (DISABLE_WP_CRON), this managed entry runs every site's wp-cron.php as the
# PHP user so scheduled posts, updates and plugin jobs still fire.
# /usr/bin/php stays the path: cron's PATH has no /usr/local/bin, and the
# source build links /usr/bin/php to the active CLI wherever dpkg no longer
# owns it (php_build_links; the migration does it after the Sury purge).
# Keeping the string also keeps every managed crontab byte-identical.
readonly CRON_WP_CRON='/usr/bin/find /var/www -maxdepth 6 -type f -name wp-config.php ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do [ -f "$d/wp-cron.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$d/wp-cron.php"; done'
# XenForo job runner (XF_JOB_CRON): every XenForo root under /var/www runs its
# queue once a minute as the PHP user.  --max-execution-time keeps one run
# inside the minute; XenForo's own job lock prevents overlapping runners.
# No "%" may appear here: crontab treats it as a newline.
readonly CRON_XF_JOBS='/usr/bin/find /var/www -maxdepth 6 -type f -path "*/src/config.php" ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do r=$(/usr/bin/dirname "$d"); [ -f "$r/cmd.php" ] && [ -f "$d/XF.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$r/cmd.php" xf:run-jobs --max-execution-time=50 >/dev/null 2>&1; done'
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

# shellcheck source=lib/overrides.sh
source "${SCRIPT_DIR}/lib/overrides.sh"

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

# shellcheck source=lib/service-optimizers.sh
source "${SCRIPT_DIR}/lib/service-optimizers.sh"

# shellcheck source=lib/diagnostics.sh
source "${SCRIPT_DIR}/lib/diagnostics.sh"

# shellcheck source=lib/restart.sh
source "${SCRIPT_DIR}/lib/restart.sh"

# shellcheck source=lib/payloads.sh
source "${SCRIPT_DIR}/lib/payloads.sh"

# shellcheck source=lib/php-upgrade.sh
source "${SCRIPT_DIR}/lib/php-upgrade.sh"

# shellcheck source=lib/php-build.sh
source "${SCRIPT_DIR}/lib/php-build.sh"

# shellcheck source=lib/nginx-build.sh
source "${SCRIPT_DIR}/lib/nginx-build.sh"
# shellcheck source=lib/valkey-build.sh
source "${SCRIPT_DIR}/lib/valkey-build.sh"
# shellcheck source=lib/watchdog.sh
source "${SCRIPT_DIR}/lib/watchdog.sh"

# Last: its top-level defaults read what the build libs export
# (NGINX_BUILD_DROPPABLE_RE / NGINX_BUILD_UNBUILT_RE, the build lock path).
# shellcheck source=lib/migrate.sh
source "${SCRIPT_DIR}/lib/migrate.sh"


# Tests source this file with SETUP_TEST_SOURCE_ONLY=1 to exercise the pure
# helper functions without running an installation.
if [[ ${SETUP_TEST_SOURCE_ONLY:-0} != 1 ]]; then
  # main() also dispatches the hidden `--migrate-1.22-unit REPORT_FILE` mode
  # that the setup-migrate-1.22 unit runs (run_migrate_unit, lib/restart.sh).
  main "$@"
fi
