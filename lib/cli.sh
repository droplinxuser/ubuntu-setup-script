# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
declare -A ENABLED=()
declare -A OPT=()
declare -A DOMAIN_APP=()
# Per-domain database provisioning (--domain ... db= user= pass= sql=).
declare -A DOMAIN_DB=()
declare -A DOMAIN_DB_USER=()
declare -A DOMAIN_DB_PASS=()
declare -A DOMAIN_SQL=()
OTHERS=()
DOMAINS=()
PURGE=0
OPTIMIZE=0
DIAGNOSTICS=0
RESTART_ALL=0
DRY_RUN=0
# --upgrade-php=X.Y: replace the installed PHP with another version while
# keeping the extension set and custom configuration.  Empty means off.
UPGRADE_PHP=""
UPGRADE_PHP_SEEN=0
# Optional Anubis bot filter.  Enabled with `--angie anubis=yes` (fresh
# install) or `--optimize anubis=yes` (existing host), disabled again with
# `--optimize anubis=no`.  The choice is persisted as ANUBIS=1/0 in
# /etc/default/setup-tuning, so a later plain --optimize keeps it.
ANUBIS_ENABLED="${ANUBIS:-0}"
[[ $ANUBIS_ENABLED == 1 ]] || ANUBIS_ENABLED=0
# Non-empty when the operator selected a state on this command line; the
# install/optimize paths persist it only after a successful apply.
ANUBIS_SETTING=""
if [[ -n ${SETUP_ANUBIS+x} ]]; then
  case ${SETUP_ANUBIS,,} in
    1|yes|on|true)  ANUBIS_ENABLED=1; ANUBIS_SETTING=1 ;;
    0|no|off|false) ANUBIS_ENABLED=0; ANUBIS_SETTING=0 ;;
    *) die "SETUP_ANUBIS='${SETUP_ANUBIS}' is invalid (use 1 or 0)" ;;
  esac
fi
PURGE_TARGETS=()
PURGE_ORDER=()
SERVICE_ORDER=(basic angie php mariadb valkey elastic others domain)
# Apply order per mode.  main() and run_optimize() used to repeat these lists
# inline; one definition keeps them from drifting.  PHP goes first in
# --optimize because it owns the FastCGI socket Angie points at; --purge has
# its own dependency order in build_purge_order().
INSTALL_ORDER=(angie php mariadb valkey elastic)
OPTIMIZE_ORDER=(php angie mariadb valkey redis elastic)
declare -A SVC_STATUS=()
declare -A SVC_SECONDS=()

usage() {
  cat <<'EOF'
Usage:
  setup.sh --basic [server=dedi|vps] [host=FQDN] [swap=SIZE] [time=REGION/CITY] [SERVICES]
  setup.sh --domain DOMAIN [DOMAIN...]

Basic (always required for an install; all values are optional):
  --basic [server=dedi|vps] [host=custom.host] [swap=8G] [time=Asia/Manila]
          [mitigations=on|off]
    server   auto-detected when omitted (systemd-detect-virt/DMI/cgroup)
    host     auto-generated when omitted: <threads>c-<RAM>g-<storage>
             e.g. 8c-32g-1T (8 threads, 32 GB RAM, 1 TB storage)
    swap     auto when omitted: only adds swap if current swap is 0 or
             below 50% of RAM; target total is 50% of RAM
    time     defaults to Asia/Manila
    mitigations  off = boot with mitigations=off (no PTI/IBRS/MDS clearing:
             faster syscalls and context switches, weaker isolation
             between local processes); on = remove it again.  GRUB only,
             applied at the next reboot, persisted as CPU_MITIGATIONS so
             every --optimize keeps it.  Omitted = never touched.

Services (optional; only the ones listed are installed):
  --angie     [anubis=yes|no]
      anubis=yes  install the Anubis bot filter (v1.28.2, static binary) and
                  put every vhost behind it: Angie TLS terminator -> Anubis ->
                  application vhost, both legs on Unix sockets.  Browsers get
                  a branding-free proof-of-work challenge; search engines and
                  infrastructure routes are allowed, AI crawlers are denied.
                  Only valid with --angie.  The choice is persisted as
                  ANUBIS=1 so later --optimize runs keep it.  anubis=no is
                  accepted for symmetry and leaves the host unchanged.
                  Static assets (CSS/JS/images/fonts/media) are served by a
                  static-only shadow of each vhost instead of the Go proxy:
                  same root and same deny rules, every other URI and every
                  miss still goes through Anubis.  SETUP_ANUBIS_STATIC_BYPASS=0
                  keeps them on the proxy hop (persisted as
                  ANUBIS_STATIC_BYPASS).
  --php       [ver=8.5] [children=auto|N] [max_requests=N]
      ver          PHP version (default: latest stable in Sury)
      children     PHP-FPM worker count (default: auto from RAM/CPU)
      max_requests recycle a worker after N requests (default: threads x 1024)
  --mariadb   user=demo pass=temp [size=4gb|auto] [bind=127.0.0.1[,ADDR...]|IPV4]
      size     auto (default) = live data+index plus 5% from the shared
               memory plan (128 MB minimum; capped at 80% of RAM when
               MariaDB is the only data service, otherwise at RAM/2); a
               larger live pool is shrunk to it online.  A fresh install
               with nothing to measure uses a RAM floor.  The redo log is
               25% of the pool.  Room is left for Elasticsearch, Valkey
               and PHP workers.
      bind     comma-separated IPv4 addresses and/or ::1 (default 127.0.0.1)
               IPV4 auto-detects the server's public IPv4; on NAT it falls
               back to the local outbound IPv4
               e.g. bind=127.0.0.1,2.3.4.5  or  bind=127.0.0.1,IPV4
  --valkey    [ram=2g] [policy=allkeys-lru] [io_threads=1]
      ram        maxmemory (default: live working set +20%, 128 MB minimum,
                 from the shared memory plan)
      policy     maxmemory-policy (default allkeys-lru; use noeviction or
                 volatile-lru when Valkey stores sessions/jobs that must survive)
      io_threads extra socket I/O threads (default 1; raise only after
                 valkey-benchmark shows the main thread is saturated)
  --elastic   [ram=4g|auto] [host=localhost]
      ram        JVM heap (default: auto = index store / 4, clamped to
                 512 MB..25% of RAM (31 GB ceiling); the page cache serves
                 the index)
  --others    smartmon nvme gif nodejs sysstat
              (or: --others all)
      nvme-cli is installed only on a dedicated server with NVMe storage.
      sysstat    sar/iostat performance history

Domain setup (standalone; Angie + MariaDB must already be installed/running):
  --domain DOMAIN [app=TYPE] [db=NAME [user=U pass=P] [sql=FILE]] [DOMAIN ...]
      Creates, per domain:
        /var/www/<domain>/public/
        /etc/angie/ssl/<domain>/          (self-signed; replace with ACME)
        /etc/angie/conf.d/<domain>.conf   (full vhost from the Angie repo's
                                           conf.d/templates; the basic
                                           template when app= is omitted)
      app=TYPE may be given inside a --domain group and applies to every
      domain in that group. TYPE is one of:
        basic (default) xf wordpress flarum pingvin chevereto polr lychee
        shlink sfs php node
      db=NAME            create the MariaDB database (only when declared)
      user=U pass=P      create that user with ALL privileges on db= only
                         (localhost, 127.0.0.1 and ::1); both are required
      sql=FILE           import a dump (.sql, .sql.gz, .xz, .zst, .bz2)
                         into db= when the database is still empty, then
                         re-size the MariaDB profile for the imported data
      db=/user=/pass=/sql= follow the domain they belong to.
      Existing non-empty vhost files and existing databases are preserved.
      Example: --domain forum.example.com app=xf db=xenforodb user=demo \
                 pass=temp sql=/root/backup.sql
      --domain can be repeated and combined with a normal install. There is
      no --purge for domains; remove the files/database manually.

Optimize-only mode (Ubuntu 22.04, 24.04 or 26.04):
  --optimize [anubis=yes|no] [mitigations=on|off] [--dry-run]
      One command for the whole host.  It synchronizes Angie's /etc/angie
      tree from server-configs-nginx (or CONFIG_SOURCE_DIR), applies the
      hardware-aware OS profile (CPU governor, PAM security limits, and
      kernel/network/memory sysctls) and then tunes every installed service
      (Angie, PHP-FPM, MariaDB, Valkey or Redis, Elasticsearch) for the
      current CPU/RAM/disk.  It also enables FastCGI guest caching for
      detected WordPress and XenForo vhosts, including the shared cache
      zone, style/language cache keys and session-cookie bypass.
      It never installs, purges or starts a managed service; the only packages
      it may add are angie-module-brotli and the brotli CLI (asset
      precompression) when Angie is installed (and the Anubis static binary
      when anubis=yes), and the only one it removes is angie-module-zstd left
      by 1.21.58 (unless a configuration still uses it), so install and optimize share
      the same compression/bot-filter profile.  `anubis=yes` enables the bot
      filter for every site on the host and installs it when missing;
      `anubis=no` restores the vhosts to direct TLS and stops it.  A host
      that already has ANUBIS=1 persisted keeps it on a plain --optimize run.
      It also never
      touches the resolver (DNS), the firewall (UFW) or swap: those are
      --basic decisions and stay as the operator left them.  Allocations
      are planned together from one
      80%-of-RAM budget, and a service is reloaded (Angie, PHP-FPM) or tuned
      online (Valkey/Redis) only when its generated configuration actually
      changed.  Startup-only settings are reported and apply on the next full
      restart.  A live TCP PHP-FPM pool used through the shared local_php
      upstream is migrated to the Unix socket, and Angie is repointed to it.
      The graceful reload is tried first; if the build does not open the new
      listener on SIGUSR2, PHP-FPM is restarted to complete the migration
      (a short, explicit cutover).
      A failed Angie sync restores the previous tree and is reported.
      WordPress/XenForo configs under /var/www are audited, and the report
      lists persistent MariaDB and local Valkey socket settings the admin
      still needs to apply.
      Hosts built before 1.8.34 also get the legacy nightly
      `chown -R /var/www/` crontab entry migrated to the log-safe find form,
      and /var/www/logs ownership repaired before any service is restarted.
      Configuration files are backed up under /tmp/setup-optimize-*
      and a Markdown report is written to /var/log/setup-optimize-*.md.
      Existing application vhosts and credentials are preserved.
      --dry-run only prints the planned OS and service values.

  Profile pins and tuning overrides
      --optimize always recomputes the whole profile from the current
      hardware.  Every recorded tuning override is ignored and moved to /tmp
      (never deleted) before the tuners run:
        - /etc/default/setup-tuning keeps only host facts/feature choices
          (ANUBIS, ANUBIS_STATIC_BYPASS, XF_JOB_CRON, NODE_MAJOR,
          NODE_ALLOW_MAJOR_UPGRADE).  TCP_CC, QDISC, STORAGE_CLASS and the
          PHP/compression/rate-limit pins are cleared and go back to the
          current defaults (bbr/fq, etc.);
        - /var/lib/setup.sh/explicit-options.conf is moved to /tmp, dropping
          recorded php_children/max_requests, mariadb/valkey/elastic sizes
          and the dedi/vps pin so the shared memory plan recomputes them;
        - tuning environment variables (SETUP_TCP_CC, SETUP_QDISC,
          SETUP_STORAGE_CLASS, SETUP_PHP_WORKERS_PER_CPU,
          SETUP_PHP_JIT_HOT_*, SETUP_GZIP_LEVEL, SETUP_BROTLI_LEVEL,
          SETUP_ANGIE_COMPRESSION, SETUP_MARIADB_IO_CAPACITY,
          SETUP_LIMIT_REQ_EXEMPT, SETUP_PRECOMPRESS_ASSETS,
          SETUP_PHP_PAGE_GZIP, SETUP_PHP_JIT_WORDPRESS) are ignored with a
          warning, so two servers with the same hardware get the same
          profile.  Feature choices (ANUBIS, Node major, application cache
          and security toggles) and the CONFIG_* source knobs still apply.
      Third-party sysctl files and units are never deleted; the managed
      profile is re-applied after systemd-sysctl at boot by
      setup-sysctl-final.timer (90 s after boot), and the run report plus
      --diagnostics list every file that still defines a managed key.
      Original files are moved to /tmp (the script never unlinks them).

PHP upgrade (standalone):
  --upgrade-php=VERSION        e.g. --upgrade-php=8.6
      Replaces every installed PHP package with VERSION and keeps the host's
      extension set and custom configuration:
        - records every installed PHP package, which extensions were installed
          manually, custom .ini fragments/FPM pools and exact package versions;
        - adds the Sury repository and checks that phpVERSION-fpm is published
          (an explicitly requested pre-release is allowed with a warning);
        - detects WordPress/XenForo/Chevereto below /var/www and refuses,
          before purging, when the target cannot provide an extension they
          need and the current PHP loads (PHP 8.6 publishes no redis,
          igbinary or imagick yet).  Nothing changes on refusal;
          SETUP_PHP_ALLOW_MISSING_EXT=1 accepts the loss explicitly;
        - purges all PHP packages and the dependencies that only PHP kept
          installed.  Pre-existing unrelated autoremove candidates are kept,
          because only the before/after autoremove delta is removed;
        - installs phpVERSION-fpm/cli and the default extension set plus every
          extension the old version had (packages the new version does not
          publish are reported and skipped, not fatal);
        - migrates operator-owned .ini fragments and extra FPM pools, then
          validates them with php-fpm -t;
        - runs the same hardware-aware tuner as install/--optimize (socket,
          static pool, OPcache, tracing JIT, realpath/memory limits) and
          reloads Angie when it is active;
        - verifies the CLI version, FPM service, socket, extension packages
          and JIT, then writes /var/log/setup-php-upgrade-<timestamp>.md.
      The old /etc/php tree and package versions are kept under
      /var/lib/setup.sh/php-upgrade-<timestamp>/ for a rollback.
      On a host with no PHP installed the same command installs VERSION fresh.
      Use --dry-run to print the purge/install plan without changes.  It
      cannot be combined with install flags, --optimize, --purge,
      --diagnostics, --restart-all or --domain.

Security hardening (runs automatically):
  --optimize and --basic always:
      - fix wp-config.php ownership/mode (root:www-data 640)
      - add DISALLOW_FILE_EDIT, DISALLOW_FILE_MODS, DISABLE_WP_CRON,
        WP_DEBUG_DISPLAY=false and FORCE_SSL_ADMIN when missing
      - add the managed wp-cron.php crontab entry before disabling WP-Cron
      - add the managed xf:run-jobs crontab entry (every minute, as www-data)
        for every XenForo root; SETUP_XF_JOB_CRON=0 removes it
      - move a WordPress database user with global privileges to a per-site
        account limited to its own database (SETUP_WP_DB_SPLIT=0 disables)
      - quarantine known webshells/malware and report risky plugins,
        world-writable files and oversized backup archives
      - enable unattended-upgrades when installed (--basic installs it;
        --optimize never installs packages)
      - report SSH, firewall and Elasticsearch exposure

Purge (stop/restore) mode:
  --purge [all|basic|angie|php|mariadb|valkey|elastic|others]
  --purge --angie --php                 stop only the selected services
  --purge                               stop everything this script manages
  --purge --php ver=8.5                 stop one PHP version (note --php)
  --purge php mariadb                   bare names are also accepted
  No file, package, database, certificate or log is deleted.  Configuration
  is restored only by overwriting it with the recorded original.  Leftovers
  under /tmp are allowed to expire on their own.

Configuration source:
  Angie configuration is downloaded from
  https://github.com/droplinxuser/server-configs-nginx at install time.
  PHP-FPM pool and php.ini templates are local to this repository
  (configs/php) because they are not Angie configuration.
  Environment overrides:
    CONFIG_SOURCE_DIR=/path/to/checkout   use a local checkout (testing/offline)
    CONFIG_REPO_URL=https://github.com/... alternate repository
    CONFIG_REPO_REF=main                   branch or tag to download

Testing:
  --dry-run                             parse and validate only; show the plan
                                        without changing the system (works as
                                        a normal user and with --purge)

Diagnostics:
  --diagnostics
      Collects host/hardware details, running services and their status,
      Angie/PHP/MariaDB/Valkey/Redis/Elasticsearch runtime statistics,
      slow-query and slow-request logs, service error logs and kernel/OOM
      reports into diagnostics.log beside setup.sh.  Run as root; this mode
      only reads state and writes that one file.

Restart all:
  --restart-all
      Detects installed/running services, reloads systemd, stops Angie and
      every active PHP-FPM version, restarts active Valkey/Redis,
      Elasticsearch and MariaDB, waits for MariaDB SELECT 1, then starts
      PHP-FPM followed by Angie.  Only services that were active are stopped
      and started again.  Use --dry-run to print the detected plan.

Notes:
  * Every run mirrors its full output to setup_<timestamp>-<pid>.log in the
    directory where setup.sh was started.  Copy that file when reporting an
    issue; it includes the host facts and the exit status.
  * Only one PHP-FPM version can own the shared Unix socket at a time.
    --php is a first installation: on a host that already runs PHP-FPM it
    keeps the installed packages and only re-applies the managed
    configuration, and it refuses another ver=.  Change the version with
    --upgrade-php=8.6 (keeps extensions and custom configuration).

Examples:
  bash setup.sh --basic server=dedi host=custom.host time=Asia/Manila swap=8G \
      --angie --php ver=8.5 --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
      --valkey --elastic host=localhost ram=4g --others smartmon nvme gif nodejs

  bash setup.sh --basic --angie --php

  bash setup.sh --basic --mariadb user=demo pass=temp size=4gb \
      bind=127.0.0.1,IPV4

  bash setup.sh --domain google.com
  bash setup.sh --domain google.com example.org

  bash setup.sh --upgrade-php=8.6
  bash setup.sh --upgrade-php=8.6 --dry-run

  bash setup.sh --purge all
EOF
}

kv_set() {
  local ctx=$1 key=$2 val=$3
  case "${ctx}:${key}" in
    basic:server|basic:host|basic:time|basic:swap|basic:mitigations) ;;
    php:ver|php:children|php:max_requests) ;;
    mariadb:user|mariadb:pass|mariadb:size|mariadb:bind) ;;
    valkey:ram|valkey:policy|valkey:io_threads) ;;
    elastic:host|elastic:ram) ;;
    *) die "--${ctx}: unknown option '${key}'" ;;
  esac
  # An empty ver= (a shell variable that was not set) used to mean "auto" on
  # install and "every installed version" on --purge; both are dangerous
  # surprises.  It is always a mistake.
  if [[ $ctx:$key == php:ver && -z $val ]]; then
    die "--php ver= requires a version, e.g. 8.5 (the value is empty)"
  fi
  OPT["${ctx}.${key}"]=$val
}

# Consume a run of key=value arguments for one service context, stopping at
# the next --flag.  The count is returned in KV_CONSUMED because a function
# cannot shift its caller's positional parameters; parse_args then advances
# with `shift "$KV_CONSUMED"`.  One implementation replaced five near-identical
# loops (--basic, --php, --mariadb, --valkey, --elastic).
KV_CONSUMED=0
kv_consume() {
  local ctx=$1 allow_cont=$2 last_key=""
  shift 2
  KV_CONSUMED=0
  while (( $# )) && [[ $1 != --* ]]; do
    if [[ $1 == *=* ]]; then
      last_key=${1%%=*}
      kv_set "$ctx" "$last_key" "${1#*=}"
    elif [[ $allow_cont == 1 && $last_key == bind ]]; then
      # Allow: bind=127.0.0.1, 2.3.4.5  (the shell splits on the space)
      OPT["${ctx}.bind"]="${OPT[${ctx}.bind]:-},$1"
    else
      die "--${ctx}: expected key=value, got '$1'"
    fi
    KV_CONSUMED=$(( KV_CONSUMED + 1 ))
    shift
  done
}

NORMALIZED_ARGS=()
# People paste commands from documentation into shells that keep typographic
# dashes (em dash U+2014, en dash U+2013). Accept them instead of failing with
# "Unknown argument" and rewrite them to ASCII "--".
# anubis=yes|no (also 1/0, on/off) belongs to --angie and --optimize.
anubis_set() {
  case "${1,,}" in
    yes|1|on|true)  ANUBIS_ENABLED=1; ANUBIS_SETTING=1 ;;
    no|0|off|false) ANUBIS_ENABLED=0; ANUBIS_SETTING=0 ;;
    *) die "anubis= expects yes or no (got '$1')" ;;
  esac
}

# mitigations=on|off belongs to --basic and --optimize (CPU_MITIGATIONS).
# Normalised to on/off; validate_all rejects anything else.
mitigations_set() {
  [[ -n $1 ]] || die "mitigations= requires on or off (the value is empty)"
  CPU_MITIGATIONS_SETTING=$1
}

normalize_cli_args() {
  local arg
  NORMALIZED_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      —*|–*) arg="--${arg#?}" ;;
    esac
    NORMALIZED_ARGS+=("$arg")
  done
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --basic)
        ENABLED[basic]=1; shift
        kv_consume basic 0 "$@"
        shift "$KV_CONSUMED"
        if [[ -n ${OPT[basic.mitigations]+x} ]]; then
          mitigations_set "${OPT[basic.mitigations]}"
        fi
        ;;
      --php)
        ENABLED[php]=1; shift
        kv_consume php 0 "$@"
        shift "$KV_CONSUMED"
        ;;
      --mariadb)
        ENABLED[mariadb]=1; shift
        kv_consume mariadb 1 "$@"
        shift "$KV_CONSUMED"
        ;;
      --elastic)
        ENABLED[elastic]=1; shift
        kv_consume elastic 0 "$@"
        shift "$KV_CONSUMED"
        ;;
      --angie)
        ENABLED[angie]=1; shift
        while (( $# )) && [[ $1 == anubis=* ]]; do
          anubis_set "${1#*=}"
          shift
        done
        ;;
      --valkey)
        ENABLED[valkey]=1; shift
        kv_consume valkey 0 "$@"
        shift "$KV_CONSUMED"
        ;;
      --others)
        ENABLED[others]=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          OTHERS+=("$1"); shift
        done
        ;;
      --domain)
        ENABLED[domain]=1; shift
        local got_domain=0 d app="" key default_app="" last_app=""
        local app_count=0 app_at_end=0
        local -a group=()
        while (( $# )) && [[ $1 != --* ]]; do
          case "$1" in
            app=*)
              app=${1#*=}
              app_count=$(( app_count + 1 ))
              last_app=$app
              app_at_end=1
              if (( ${#group[@]} > 0 )); then
                # app=TYPE belongs to the domain immediately before it.
                key=${group[-1],,}; key=${key%.}
                DOMAIN_APP[$key]=$app
              else
                # app=TYPE before any domain sets the group default.
                default_app=$app
              fi
              shift
              continue
              ;;
            db=*|user=*|pass=*|sql=*)
              # Database options belong to the domain immediately before them.
              (( ${#group[@]} > 0 )) || die "--domain: '${1%%=*}=' must follow a domain name"
              key=${group[-1],,}; key=${key%.}
              case "$1" in
                db=*)   DOMAIN_DB[$key]=${1#*=} ;;
                user=*) DOMAIN_DB_USER[$key]=${1#*=} ;;
                pass=*) DOMAIN_DB_PASS[$key]=${1#*=} ;;
                sql=*)  DOMAIN_SQL[$key]=${1#*=} ;;
              esac
              # A database option follows the app= it belongs to, so that
              # app= is per-domain, not a trailing group default.
              app_at_end=0
              shift
              continue
              ;;
            anubis=*)
              die "anubis= belongs to --angie (install) or --optimize (existing host), not --domain"
              ;;
          esac
          d=${1,,}; d=${d%.}
          group+=("$d"); got_domain=1
          # A domain after app= means that app= was per-domain, not a
          # trailing group default.
          app_at_end=0
          [[ -n $default_app ]] && DOMAIN_APP[$d]=$default_app
          shift
        done
        (( got_domain )) || die "--domain requires at least one domain name"
        for d in "${group[@]}"; do
          DOMAINS+=("$d")
          key=${d,,}; key=${key%.}
          # Preserve the documented single app=TYPE behaviour: one app= after
          # the whole list applies to every domain in this group.
          if (( app_count == 1 && app_at_end == 1 )) && [[ -n $last_app ]]; then
            DOMAIN_APP[$key]=$last_app
          fi
        done
        ;;
      --optimize)
        OPTIMIZE=1; shift
        while (( $# )) && [[ $1 == anubis=* || $1 == mitigations=* ]]; do
          case $1 in
            anubis=*) anubis_set "${1#*=}" ;;
            *)        mitigations_set "${1#*=}" ;;
          esac
          shift
        done
        ;;
      --upgrade-php=*)
        (( UPGRADE_PHP_SEEN == 0 )) || die "--upgrade-php may only be given once"
        UPGRADE_PHP_SEEN=1
        UPGRADE_PHP=${1#*=}
        # An empty value is a mistake (--upgrade-php="$VER" with VER unset),
        # never a request for another mode.  validate_all also branches on
        # UPGRADE_PHP_SEEN, so the remaining flags cannot take over.
        [[ -n $UPGRADE_PHP ]] \
          || die "--upgrade-php requires a version, e.g. --upgrade-php=8.6 (the value is empty)"
        shift ;;
      --upgrade-php)
        (( UPGRADE_PHP_SEEN == 0 )) || die "--upgrade-php may only be given once"
        UPGRADE_PHP_SEEN=1
        (( $# >= 2 )) && [[ $2 != -* && -n $2 ]] \
          || die "--upgrade-php requires a version, e.g. --upgrade-php=8.6"
        UPGRADE_PHP=$2
        shift 2 ;;
      --diagnostics)
        DIAGNOSTICS=1; shift ;;
      --restart-all)
        RESTART_ALL=1; shift ;;
      --purge)
        PURGE=1; shift
        while (( $# )) && [[ $1 != --* ]]; do
          PURGE_TARGETS+=("$1"); shift
        done
        ;;
      --dry-run|--check) DRY_RUN=1; shift ;;
      anubis=*)
        # Accepted here so validate_all can explain that it belongs to
        # --angie/--optimize instead of reporting an unknown argument.
        anubis_set "${1#*=}"
        shift ;;
      mitigations=*)
        # Same for mitigations= after another flag: `--optimize --dry-run
        # mitigations=off` used to die as an unknown argument although the
        # same words in the documented order work.  validate_all checks
        # that --basic or --optimize is present.
        mitigations_set "${1#*=}"
        CPU_MITIGATIONS_LOOSE=1
        shift ;;
      --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: '$1' (use --help)" ;;
    esac
  done
}

