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
PURGE_TARGETS=()
PURGE_ORDER=()
SERVICE_ORDER=(basic nginx php mariadb valkey elastic others domain)
# Apply order per mode.  main() and run_optimize() used to repeat these lists
# inline; one definition keeps them from drifting.  PHP goes first in
# --optimize because it owns the FastCGI socket nginx points at; --purge has
# its own dependency order in build_purge_order().
INSTALL_ORDER=(nginx php mariadb valkey elastic)
OPTIMIZE_ORDER=(php nginx mariadb valkey redis elastic)
declare -A SVC_STATUS=()
declare -A SVC_SECONDS=()

usage() {
  cat <<'EOF'
Usage:
  setup.sh --basic [server=dedi|vps] [host=FQDN] [swap=SIZE] [time=REGION/CITY] [SERVICES]
  setup.sh --domain DOMAIN [DOMAIN...]

Basic (always required for an install; all values are optional):
  --basic [server=dedi|vps] [host=custom.host] [swap=8G] [time=Asia/Manila]
          [mitigations=off]
    server   auto-detected when omitted (systemd-detect-virt/DMI/cgroup)
    host     auto-generated when omitted: <threads>c-<RAM>g-<storage>
             e.g. 8c-32g-1T (8 threads, 32 GB RAM, 1 TB storage)
    swap     auto when omitted: only adds swap if current swap is 0 or
             below 50% of RAM; target total is 50% of RAM
    time     defaults to Asia/Manila
    mitigations  always off (the default since 1.22.5): every --basic and
             --optimize boots the host with mitigations=off (no PTI/IBRS/
             MDS clearing: faster syscalls and context switches, no
             protection between local processes; for single-tenant,
             key-only hosts).  GRUB only, applied at the next reboot.
             mitigations=on was removed; --purge basic removes it.

Services (optional; only the ones listed are installed):
  --nginx
      nginx (latest mainline from nginx.org, built from source) and its
      configuration tree (server-configs-nginx layout under /etc/nginx).
      There is no bot filter: put Cloudflare or another CDN/WAF in front of
      the origin.  --angie is still accepted as a deprecated alias.
  --php       [ver=8.5] [ext=LIST] [children=auto|N] [max_requests=N]
      ver          PHP series to build (default: the newest php.net release;
                   any series from 8.1 on)
      ext          extensions to add to the per-application set, comma-
                   separated (e.g. ext=intl,gmp); -NAME drops one you added,
                   none clears the list.  Persisted as PHP_EXT_EXTRA; names
                   the source build cannot compile are refused up front.
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
  --valkey    [ram=2g] [policy=allkeys-lru] [tcp=auto]
      ram        maxmemory (default: live working set +20%, 128 MB minimum,
                 from the shared memory plan); with sessions in Valkey, size
                 it to hold sessions plus cache
      policy     maxmemory-policy (default allkeys-lru; noeviction was
                 removed; an adopted AOF store keeps it).  Sessions survive
                 clean restarts through the RDB snapshot (a crash or power
                 loss starts the cache empty) and may be evicted under
                 memory pressure; never volatile-*, which
                 evicts the TTL-carrying session keys first
      tcp        auto (default): Unix socket only (port 0) unless an app
                 config (WordPress incl. W3TC/LiteSpeed, XenForo, Chevereto,
                 PHP sessions), a client or a recent TCP connection uses TCP,
                 or the clients cannot be listed; on: keep TCP 6379 open
                 (persisted, also for an adopted redis-server; tcp=auto
                 undoes it)
  --elastic   [ram=4g|auto] [host=localhost]
      ram        JVM heap (default: auto = index store / 4, clamped to
                 512 MB..25% of RAM (31 GB ceiling); the page cache serves
                 the index)
  --others    smartmon nvme gif nodejs sysstat
              (or: --others all)
      nvme-cli is installed only on a dedicated server with NVMe storage.
      sysstat    sar/iostat performance history

Source builds (always; there are no package modes):
      nginx, PHP (FPM and CLI) and Valkey are compiled from their upstream
      releases with clang -O3 -march=native, hardening, LTO (ThinLTO for
      nginx and PHP, full LTO for Valkey) and BOLT,
      with only the modules the host's applications need.  Downloads are
      verified (nginx PGP signatures, php.net and valkey-hashes SHA-256).
      A build failure stops the install and names the build log; nothing
      is half-installed.  A daily timer rebuilds in the background when a
      new release or a changed extension set needs it; the running binary
      serves until the new one passes its checks.  After a CPU change the
      services stay down until setup-build-cpu.service has rebuilt them for
      the new CPU (no generic fallback binary).
      --source and SETUP_PHP_BUILD / SETUP_NGINX_BUILD / SETUP_VALKEY_BUILD /
      SETUP_PHP_FPM_MODULES were removed in 1.22.0; they are ignored with a
      warning.  Use --php ext= to add PHP extensions.
      SETUP_PRECOMPRESS_ASSETS was removed in 1.22.1 (nginx has no
      gzip_static or brotli_static; dynamic gzip and Brotli compress every
      response); it is ignored with a warning.

Small hosts (below the 4 GB class, MemTotal under 3500 MB):
      nginx only.  --php, --valkey, --mariadb, --elastic, --upgrade-php and
      --domain apps that need PHP (everything but basic, node and pingvin)
      are refused before anything changes; --optimize tunes nginx and
      leaves an existing PHP or Valkey as it is (reported).

Domain setup (standalone; nginx + MariaDB must already be installed/running):
  --domain DOMAIN [app=TYPE] [db=NAME [user=U pass=P] [sql=FILE]] [DOMAIN ...]
      Creates, per domain:
        /var/www/<domain>/public/
        /etc/nginx/ssl/<domain>/          (self-signed, for Cloudflare Full
                                           mode; replace with your own)
        /etc/nginx/conf.d/<domain>.conf   (full vhost from the nginx repo's
                                           conf.d/templates; the basic
                                           template when app= is omitted)
      app=TYPE inside a --domain group: one app= after the whole list
      applies to every domain in the group; otherwise each app= belongs to
      the domain just before it (one before any domain is the group
      default). TYPE is one of:
        basic (default) xf wordpress flarum pingvin chevereto polr lychee
        shlink sfs php node
      A PHP app adds its extension set to the PHP build; PHP is rebuilt
      first when the set grows.
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
  --optimize [mitigations=off] [ext=LIST] [--dry-run]
      ext=LIST changes the PHP extension set like --php ext= (NAME adds,
      -NAME drops one, none clears the list, minimal keeps only imagick of
      the extras) on 22.04, 24.04 and 26.04;
      the stale build is rebuilt and swapped in by the same run.
      One command for the whole host.  It synchronizes nginx's /etc/nginx
      tree from server-configs-nginx (or CONFIG_SOURCE_DIR), applies the
      hardware-aware OS profile (CPU governor, PAM security limits, and
      kernel/network/memory sysctls) and then tunes every installed service
      (nginx, PHP-FPM, MariaDB, Valkey or Redis, Elasticsearch) for the
      current CPU/RAM/disk.  It also enables FastCGI guest caching for
      detected WordPress and XenForo vhosts, including the shared cache
      zone, style/language cache keys and session-cookie bypass.
      It rebuilds a source build whose release, CPU or extension set is
      stale (then BOLTs it from live traffic), but never installs a new
      service.  Brotli is built into nginx; the only packages it may add are
      the build prerequisites.
      One-time migration (hosts provisioned by 1.21.x): the first --optimize
      builds nginx, every active PHP version and Valkey from source while
      Angie, Sury PHP-FPM and the valkey-server package keep serving, moves
      /etc/angie to /etc/nginx (Angie ACME vhosts go to the self-signed
      pair), switches each service over with a verified cutover and an
      automatic rollback, and only then purges the old packages, repos and
      keys.  It runs as the transient unit setup-migrate-1.22 (log:
      /var/log/setup-migrate-1.22.log), so a dropped SSH session does not
      stop it; re-run the command to follow it again.  Every .deb and
      configuration it replaces is kept in /var/backups/setup-1.22.  A
      blocked part (an Angie-only directive, an extension the build cannot
      provide) is reported and left serving as before; below the 4 GB class
      only nginx is migrated.  PHP is built minimal: only the extensions a
      detected application requires (plus imagick when Sury loaded it, and
      the operator's ext=); every other module Sury loaded is dropped and
      listed (--optimize ext=NAME adds one back).  --dry-run prints the
      migration plan.
      It also never
      touches the resolver (DNS), the firewall (UFW) or swap: those are
      --basic decisions and stay as the operator left them.  Allocations
      are planned together from one
      80%-of-RAM budget, and a service is reloaded (nginx, PHP-FPM) or tuned
      online (Valkey/Redis) only when its generated configuration actually
      changed.  Startup-only settings are reported and apply on the next full
      restart.  A live TCP PHP-FPM pool used through the shared local_php
      upstream is migrated to the Unix socket, and nginx is repointed to it.
      The graceful reload is tried first; if the build does not open the new
      listener on SIGUSR2, PHP-FPM is restarted to complete the migration
      (a short, explicit cutover).
      A failed nginx sync restores the previous tree and is reported.
      WordPress/XenForo configs under /var/www are audited, and the report
      lists persistent MariaDB and local Valkey socket settings the admin
      still needs to apply.
      Hosts built before 1.8.34 also get the legacy nightly
      `chown -R /var/www/` crontab entry migrated to the log-safe find form,
      and /var/www/logs ownership repaired before any service is restarted.
      Configuration files are backed up under /tmp/setup-optimize-*
      and a Markdown report is written to /var/log/setup-optimize-*.md.
      The report ends with a read-only Verify block (nginx/TLS library,
      PHP JIT, Valkey policy/RDB schedule/TCP port, each unit's
      LimitNOFILE against its internal limit and fs.file-max) and a
      Certificates block (expiring or self-signed certificates on vhosts
      not proven behind Cloudflare).
      Existing application vhosts and credentials are preserved.
      --dry-run only prints the planned OS and service values.

  Profile pins and tuning overrides
      --optimize always recomputes the whole profile from the current
      hardware.  Every recorded tuning override is ignored and moved to /tmp
      (never deleted) before the tuners run:
        - /etc/default/setup-tuning keeps only host facts/feature choices
          (XF_JOB_CRON, NODE_MAJOR, NODE_ALLOW_MAJOR_UPGRADE,
          PHP_EXT_EXTRA ...).  TCP_CC,
          QDISC, STORAGE_CLASS and the
          PHP/compression/rate-limit pins are cleared and go back to the
          current defaults (bbr/fq, etc.);
        - /var/lib/setup.sh/explicit-options.conf is moved to /tmp, dropping
          recorded php_children/max_requests, mariadb/valkey/elastic sizes
          and the dedi/vps pin so the shared memory plan recomputes them;
        - tuning environment variables (SETUP_TCP_CC, SETUP_QDISC,
          SETUP_STORAGE_CLASS, SETUP_PHP_WORKERS_PER_CPU,
          SETUP_BROTLI_LEVEL, SETUP_NGINX_COMPRESSION,
          SETUP_MARIADB_IO_CAPACITY, SETUP_LIMIT_REQ_EXEMPT,
          SETUP_PHP_PAGE_GZIP, SETUP_PHP_JIT_WORDPRESS) are ignored with a
          warning, so two servers with the same hardware get the same
          profile.  Feature choices (Node major, application cache
          and security toggles) and the CONFIG_* source knobs still apply.
      Third-party sysctl files and units are never deleted; the managed
      profile is re-applied after systemd-sysctl at boot by
      setup-sysctl-final.timer (90 s after boot), and the run report plus
      --diagnostics list every file that still defines a managed key.
      Original files are moved to /tmp (the script never unlinks them).

PHP upgrade (standalone):
  --upgrade-php=VERSION        e.g. --upgrade-php=8.6
      Switches the host to PHP series VERSION (any series php.net publishes,
      8.1 or newer; the newest X.Y.Z release is built, never an RC) and
      keeps its extension set and custom configuration:
        - builds VERSION (FPM and CLI) from source with the current
          effective extension set while the current version keeps serving;
          WordPress/XenForo/Chevereto below /var/www are checked first, and
          an extension they need that the build cannot provide refuses the
          switch before anything changes (SETUP_PHP_ALLOW_MISSING_EXT=1
          accepts the loss explicitly);
        - generates /etc/php/VERSION from the current version's managed
          files and carries operator .ini fragments and extra FPM pools over,
          validated with php-fpm -t;
        - installs the phpVERSION-fpm unit, stops the old version and starts
          the new one on the shared socket, verifies a PHP page through
          nginx and rolls back automatically on any failure;
        - runs the same hardware-aware tuner as install/--optimize and
          re-points /usr/local/bin/php, then writes
          /var/log/setup-php-upgrade-<timestamp>.md.
      The previous version's build and /etc/php tree are kept for one
      rollback: --upgrade-php=OLD switches back without rebuilding when that
      build is still current.  --upgrade-php=<the active series> only
      rebuilds a stale build (no switch and no re-tune; --optimize tunes).
      Refused while the 1.22 migration of PHP is
      unfinished, while the web tier is still Angie, and below the 4 GB
      class.  Use --dry-run to print the plan without changes.  It cannot
      be combined with install flags, --optimize, --purge, --diagnostics,
      --restart-all or --domain.

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
  --purge [all|basic|nginx|php|mariadb|valkey|elastic|others]
  --purge --nginx --php                 stop only the selected services
  --purge                               stop everything this script manages
  --purge --php ver=8.5                 stop one PHP version (note --php)
  --purge php mariadb                   bare names are also accepted
  No package, database, certificate, configuration or log is deleted.
  Configuration is restored only by overwriting it with the recorded
  original.  Purging nginx, php or valkey also removes that service's
  source build (binaries under /usr/local/lib/setup-*, its unit, links and
  tmpfiles); the shared build timers and the LLVM toolchain go with the
  last build.  /etc/nginx, /etc/php, /etc/valkey and the data stay.
  Leftovers under /tmp are allowed to expire on their own.

Configuration source:
  nginx configuration is downloaded from
  https://github.com/droplinxuser/server-configs-nginx at install time.
  PHP-FPM pool and php.ini templates are local to this repository
  (configs/php) because they are not nginx configuration.
  Environment overrides:
    CONFIG_SOURCE_DIR=/path/to/checkout   use a local checkout (testing/offline)
    CONFIG_REPO_URL=https://github.com/... alternate repository
    CONFIG_REPO_REF=main                   branch or tag to download (hosts
                                           that stay on 1.21.x use
                                           angie-final)

Testing:
  --dry-run                             parse and validate only; show the plan
                                        without changing the system (works as
                                        a normal user and with --purge)

Diagnostics:
  --diagnostics
      Collects host/hardware details, running services and their status,
      nginx/PHP/MariaDB/Valkey/Redis/Elasticsearch runtime statistics,
      slow-query and slow-request logs, service error logs and kernel/OOM
      reports, plus read-only verification (effective FPM OPcache/JIT per
      PHP series, Valkey INFO per socket, CPU frequency
      driver, NIC queues/IRQs, irqbalance, each service's LimitNOFILE
      next to its own limit, vhost certificate expiry)
      into diagnostics.log beside setup.sh.  Run as root; this mode
      only reads state and writes that one file.

Restart all:
  --restart-all
      Detects installed/running services, reloads systemd, stops nginx and
      every active PHP-FPM version, restarts active Valkey/Redis,
      Elasticsearch and MariaDB, waits for MariaDB SELECT 1, then starts
      PHP-FPM followed by nginx.  Only services that were active are stopped
      and started again.  Use --dry-run to print the detected plan.

Notes:
  * Every run mirrors its full output to setup_<timestamp>-<pid>.log in the
    directory where setup.sh was started.  Copy that file when reporting an
    issue; it includes the host facts and the exit status.
  * Only one PHP-FPM version can own the shared Unix socket at a time.
    --php is a first installation: on a host that already runs PHP-FPM it
    keeps the installed build (rebuilding it only when stale or when ext=
    grew the set) and re-applies the managed configuration, and it refuses
    another ver=.  Change the version with --upgrade-php=8.6 (keeps
    extensions and custom configuration).
  * A host still serving through Angie, Sury PHP or the valkey-server
    package must run --optimize first (the one-time migration); --nginx,
    --domain, --php and --valkey refuse on such a host until it has.

Examples:
  bash setup.sh --basic server=dedi host=custom.host time=Asia/Manila swap=8G \
      --nginx --php ver=8.5 --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
      --valkey --elastic host=localhost ram=4g --others smartmon nvme gif nodejs

  bash setup.sh --basic --nginx --php
  bash setup.sh --basic --php ext=intl,gmp

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
    php:ver|php:ext|php:children|php:max_requests) ;;
    mariadb:user|mariadb:pass|mariadb:size|mariadb:bind) ;;
    valkey:ram|valkey:policy|valkey:tcp) ;;
    # Removed in 1.22.5; recognised only so it is ignored with a warning.
    valkey:io_threads) ;;
    elastic:host|elastic:ram) ;;
    *) die "--${ctx}: unknown option '${key}'" ;;
  esac
  # An empty ver= (a shell variable that was not set) used to mean "auto" on
  # install and "every installed version" on --purge; both are dangerous
  # surprises.  It is always a mistake.
  if [[ $ctx:$key == php:ver && -z $val ]]; then
    die "--php ver= requires a version, e.g. 8.5 (the value is empty)"
  fi
  # The same for ext=: clearing the list is the explicit word "none", so an
  # unset shell variable cannot silently drop every extension added earlier.
  if [[ $ctx:$key == php:ext && -z $val ]]; then
    die "--php ext= requires a list (e.g. ext=intl,gmp) or none (the value is empty)"
  fi
  # 1.22.5: noeviction was removed (a full cache failed every write).
  # Sessions survive restarts through the RDB snapshot; size ram= for them.
  if [[ $ctx:$key == valkey:policy && $val == noeviction ]]; then
    die "--valkey policy=noeviction was removed in 1.22.5: a full cache failed every write. Keep the default allkeys-lru and size --valkey ram= to hold sessions plus cache (sessions survive clean restarts and reboots through the RDB snapshot); do not use volatile-*, which evicts the TTL-carrying session keys first"
  fi
  # 1.22.5: io_threads was removed (io-threads 1 -> 4 measured no gain and
  # 8 threads burned 430% CPU for less throughput); io-threads is pinned to
  # 1.  A script or runbook that still passes it is ignored, never refused;
  # validate_all reports it once.
  if [[ $ctx:$key == valkey:io_threads ]]; then
    RETIRED_VALKEY_IO_THREADS="--valkey io_threads=${val}"
    return 0
  fi
  # tcp=on keeps the TCP port open (persisted); auto (default) is socket
  # only unless an application or a connected client needs TCP.
  if [[ $ctx:$key == valkey:tcp ]]; then
    case ${val,,} in
      on|auto) val=${val,,} ;;
      *) die "--valkey tcp='${val}' is invalid (use auto or on)" ;;
    esac
  fi
  OPT["${ctx}.${key}"]=$val
}

# Consume a run of key=value arguments for one service context, stopping at
# the next --flag.  The count is returned in KV_CONSUMED because a function
# cannot shift its caller's positional parameters; parse_args then advances
# with `shift "$KV_CONSUMED"`.  One implementation replaced five near-identical
# loops (--basic, --php, --mariadb, --valkey, --elastic).
KV_CONSUMED=0
# Set by kv_set when the removed --valkey io_threads= is passed (1.22.5).
RETIRED_VALKEY_IO_THREADS=""
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
# Anubis was removed in 1.21.62.  The word is still recognised so a script,
# a runbook or a persisted command that carries `anubis=...` stops with an
# explanation instead of "Unknown argument", and so nobody believes a bot
# filter is protecting the host when it is not.
anubis_gone() {
  die "Anubis support was removed in 1.21.62; put Cloudflare (or another CDN/WAF) in front of the origin instead. On a host that still runs Anubis, run tools/remove-anubis.sh first."
}

# mitigations= belongs to --basic and --optimize.  Only off (the default
# since 1.22.5) is accepted, and it changes nothing; mitigations=on was
# removed and is refused here, the rest by validate_all.
mitigations_set() {
  [[ -n $1 ]] || die "mitigations= accepts only off, the default (the value is empty)"
  case ${1,,} in
    on|yes|1|true|auto)
      die "mitigations=on was removed in 1.22.5: every host setup.sh manages boots with mitigations=off; --purge basic removes it" ;;
  esac
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
      --nginx)
        ENABLED[nginx]=1; shift
        ;;
      --angie)
        # 1.22.0 replaced Angie with nginx built from source.  Runbooks and
        # persisted commands still say --angie; they get nginx and a nudge.
        warn "--angie is deprecated: Angie was replaced by nginx (built from source) in 1.22.0; installing nginx. Use --nginx."
        ENABLED[nginx]=1; shift
        ;;
      --valkey)
        ENABLED[valkey]=1; shift
        kv_consume valkey 0 "$@"
        shift "$KV_CONSUMED"
        ;;
      --source=*|--source)
        # Removed in 1.22.0: nginx, PHP and Valkey are always built from
        # source.  A script or runbook that still passes --source (with its
        # words, `--source nginx php`) keeps working: the option and its
        # values are consumed and ignored with a warning.  `none` asked for
        # packages, which no longer exist, so it is named explicitly.
        local srcwords=""
        if [[ $1 == --source=* ]]; then
          srcwords=${1#--source=}; shift
        else
          shift
          while (( $# )) && [[ $1 != --* ]]; do
            srcwords+="${srcwords:+ }$1"; shift
          done
        fi
        if [[ ,${srcwords// /,}, == *,none,* ]]; then
          warn "--source=none is ignored: package builds were removed in 1.22.0; nginx, PHP and Valkey are always built from source"
        else
          warn "--source${srcwords:+=${srcwords}} is ignored: nginx, PHP and Valkey are always built from source since 1.22.0"
        fi
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
              anubis_gone
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
        while (( $# )) && [[ $1 == anubis=* || $1 == mitigations=* || $1 == ext=* ]]; do
          case $1 in
            anubis=*) anubis_gone ;;
            # 1.22.13: the PHP extension set on any supported release
            # (--php needs 26.04): same NAME, -NAME and none as --php ext=.
            ext=*)    OPT[php.ext]=${1#*=} ;;
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
        # Recognised only to explain that the feature is gone.
        anubis_gone ;;
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
      --migrate-1.22-unit)
        # Internal: main() dispatches it only as the first argument (the
        # setup-migrate-1.22 unit that --optimize starts); anywhere else it
        # is a mistake, not a mode.
        die "--migrate-1.22-unit is internal to the 1.22 migration; run --optimize instead" ;;
      *) die "Unknown argument: '$1' (use --help)" ;;
    esac
  done
}


