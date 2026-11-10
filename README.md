# Ubuntu Setup Script

One idempotent Bash script that provisions and tunes a web/database stack on
**Ubuntu 26.04 LTS** (installs) and tunes existing 22.04/24.04/26.04 hosts
(`--optimize`): Angie, PHP-FPM, MariaDB, Valkey (or an existing Redis),
Elasticsearch, Node.js and helper tools, plus per-domain vhosts.

- **Single source of truth for Angie:** the configuration tree is downloaded at
  run time from [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx)
  (`CONFIG_SOURCE_DIR=/path` uses a local checkout). PHP-FPM templates live
  here under `configs/php/`, so run installs from a repository checkout.
- **File safety:** transient files go under `/tmp`; the script never unlinks
  anything on the server. `--purge` stops/disables services and restores
  recorded settings; it removes no package, data or log. Every run writes
  `setup_<timestamp>-<pid>.log` in the directory it was started from.
- **Install/optimize parity:** every tuned value comes from one helper shared
  by the installer and `--optimize`, so a fresh install followed by
  `--optimize` produces identical configuration (verified byte-for-byte on
  the test host; see `tests/stress-site/RESULTS.md`).

| Path | Contents |
|---|---|
| `setup.sh` | Driver: argument parsing, validation and dispatch; sources `lib/*.sh` |
| `lib/` | Implementation modules sourced in dependency order: `common` (logging, run log, temp/apt helpers), `cli`, `validate`, `util` (state, logs, cron), `os`, `web` (Angie/PHP-FPM tuning), `services` (repos, PHP, MariaDB, Valkey, Elasticsearch, domains), `purge`, `runner`, `optimize`, `security`, `diagnostics`, `restart`, `payloads` |
| `configs/system/`, `configs/mariadb/`, `configs/php/` | DNS/sysctl/limits, MariaDB and PHP-FPM templates |
| `tests/test-tuning.sh`, `tests/test-dry-run-matrix.sh` | Unit tests for the tuning helpers; CLI/dry-run matrix (both run in CI) |
| `tests/stress-site/` | Synthetic full-stack test site, local and remote load harness, results |
| `tools/diff_configs.sh` | Compare the canonical configs of both repos with the live `/etc` |
| `SECURITY-PERFORMANCE.md` | What the script hardens, what it leaves to the operator, and the large-site checklist |

## Requirements

- Ubuntu 26.04 LTS or newer for installs; `--optimize`, `--diagnostics` and
  `--restart-all` also accept 22.04 and 24.04. Bash 4.4+. Root.
- Network access to the Ubuntu, Angie, Sury, Elastic and NodeSource
  repositories and to GitHub (or `CONFIG_SOURCE_DIR`).
- RAM/disk for the selected services (Elasticsearch needs ~1.5 GB of disk plus
  its heap; MariaDB its buffer pool; PHP one static worker per
  `pm.max_children` slot).

## Quick start

`--basic` is required for every install and all of its values are optional.
Only the services named on the command line are touched. Replace `pass=temp`
with a real password (it is also written to `/etc/mysqlbkup.cnf`, mode 600).

```bash
# Full stack
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all

# Minimal web host, everything auto-detected
sudo bash setup.sh --basic --angie --php

# Application vhost with database, scoped user and a dump import
sudo bash setup.sh --domain forum.example.com app=xf db=xenforodb user=demo pass=temp sql=/root/backup.sql

# Tune an existing host (OS profile + every installed service), or preview it
sudo bash setup.sh --optimize
bash setup.sh --optimize --dry-run
```

`--dry-run` (alias `--check`) validates any command and prints the plan as a
normal user without touching the system. Other modes: `--diagnostics`,
`--restart-all [--dry-run]`, `--purge [...]`, `--help`, `--version`.

## `--basic`

| Option | Default | Effect |
|---|---|---|
| `server=dedi\|vps` | auto (`systemd-detect-virt`, DMI, cgroups) | `dedi` sets the `performance` CPU governor; the pin is recorded so `--optimize` keeps the host class |
| `host=FQDN` | `<threads>c-<RAM_GB>g-<storage>` (e.g. `8c-32g-1T`) | hostname via `hostnamectl` |
| `swap=SIZE` | add swap only when total swap is 0 or below 50% of RAM, up to 50% of RAM (1-8 GiB, 4 GiB on a VPS) | `/swapfile` of exactly that size (`8G`, `8Gi`, `512M`) |
| `time=REGION/CITY` | `Asia/Manila` | timezone |

It writes the DNS drop-in (`8.8.8.8`, `1.1.1.1`, with `Domains=~.` so they are
the default route rather than only a fallback), upgrades packages, installs
the basic tools and `cron`/`logrotate`/`unattended-upgrades`, applies the OS
profile (sysctl, PAM limits, governor, THP `madvise`, udev I/O rules, see
[Hardware profile](#hardware-profile)), writes the managed root crontab
(ownership repair of `/var/www` that skips logs and `wp-config.php`,
Cloudflare IP refresh, MariaDB backup at 03:03 and monthly `mariadb-check`,
`wp-cron.php` every 5 minutes, asset precompression when enabled) and
configures UFW (deny in, allow out, `ufw limit` on every effective SSH port,
80/443 open). Originals are recorded under `/var/lib/setup.sh` for
`--purge basic`.

### Security pass (every `--basic` and `--optimize`)

| Area | Action |
|---|---|
| WordPress | `wp-config.php` `root:www-data 640`; `DISALLOW_FILE_EDIT`, `DISALLOW_FILE_MODS` (`SETUP_WP_ALLOW_FILE_MODS=1` keeps plugin installs), `DISABLE_WP_CRON` (+ managed cron entry), `WP_DEBUG_DISPLAY=false`, `FORCE_SSL_ADMIN`; placeholder salts replaced; a `DB_USER` with global privileges is moved to `wp_<db>` scoped to its database (`SETUP_WP_DB_SPLIT=0` disables) |
| Malware | known webshells quarantined under `/var/lib/setup-quarantine/` (`SETUP_PURGE_MALWARE=1` deletes); suspicious admins, risky plugins, world-writable files and oversized archives reported |
| APT | every third-party repository pinned to its own `signed-by` keyring |
| Audit | reports SSH password authentication, public 80/443 and a non-loopback Elasticsearch |

SSH hardening, brute-force protection and origin-only firewalling are left to
the operator. The web-server side (dotfile/`wp-config.php`/`xmlrpc.php`
denies, no PHP from upload directories, security headers) comes from
`server-configs-nginx`. Angie access logging is off by default; only
`error_log` is written.

## Services

### Angie (`--angie`)

Installs `angie` and `angie-module-brotli` (dynamic Brotli level 4, 3 on 1-2 CPU hosts; gzip
fallback; `SETUP_BROTLI_LEVEL=1..11`, `SETUP_ANGIE_COMPRESSION=0`), deploys the
`server-configs-nginx` tree with the built-in deployer, applies the hardware
profile and guest caches (the same `angie_apply_profile` as `--optimize`),
installs the systemd `LimitNOFILE` drop-in and `/etc/default/angie` from the
repository, generates `http.d/cloudflare.conf` and restarts the service.
`SETUP_PRECOMPRESS_ASSETS=1` (persisted as `PRECOMPRESS_ASSETS` in
`/etc/default/setup-tuning`) writes `.br`/`.gz` siblings for the static assets
of every XenForo/WordPress root and keeps them fresh from cron; off by default
because a CDN normally serves assets. Every XenForo root also gets a managed
crontab entry that runs `cmd.php xf:run-jobs` once a minute as www-data
(`SETUP_XF_JOB_CRON=0` removes it, persisted as `XF_JOB_CRON`); switch
*Options > Performance > Job run trigger* to server-based in the admin CP so
member page requests stop running the queue (and never run the queue as root:
the data directories it creates return 403 through Angie).
`CONFIG_REPO_URL`/`CONFIG_REPO_REF` select a fork or branch.

### PHP (`--php [ver=8.5] [children=auto|N] [max_requests=N]`)

- Sury repository (embedded keyring). `ver=` defaults to the latest stable
  release. **Only one PHP-FPM version can be active** (both Angie and the pool
  use `/run/php/php-fpm.sock`): a `--php` run purges every `php*` package
  first and copies the old `/etc/php` to `/tmp`; switch versions with
  `--purge --php ver=8.4` then `--php ver=8.5`.
- Installs the XenForo profile (`fpm cli opcache mysql gd curl xml zip gmp
  mbstring redis`); add `intl`/`imagick`/`bcmath` yourself if an add-on needs
  them.
- Pool: `pm=static`; `pm.max_children` from the shared memory plan (2 per
  core, at most RAM/2 at 96 MB per worker, 512 maximum; 1 per core when every
  PHP vhost is XenForo/WordPress with a local database, because those pages
  are CPU-bound). A live pool keeps its count; `children=` wins.
  `pm.max_requests = threads x 1024`,
  `request_terminate_timeout 300s`, slow log at 10 s, `rlimit_files 524288`,
  systemd `LimitNOFILE=524288`/`UMask=0027`.
- `zz-setup-optimize.ini`: `memory_limit` 256-512M (128M under 2 GB),
  OPcache 128-512 MB with interned strings, realpath cache 4-16 MB, MariaDB
  socket defaults. `custom_dan.ini` is refreshed from `configs/php/` while the
  host timezone is kept. `fastcgi_param PATH_TRANSLATED` is repaired in every
  `h5bp/php*.conf` and any per-request `PHP_ADMIN_VALUE open_basedir` is
  commented out (PHP-FPM caches admin values per worker, so one vhost's
  setting leaked onto every other vhost of the shared pool).
- **OPcache JIT** is always the tracing JIT for the pool, with a buffer of
  OPcache/8 (32-128 MB) and PHP's default hotness thresholds on 4+ CPU hosts
  (a conservative set on 1-2 CPU hosts, each value overridable with
  `SETUP_PHP_JIT_HOT_{LOOP,FUNC,RETURN,SIDE_EXIT}`); there is no mode switch
  (an old `SETUP_PHP_JIT` or persisted `PHP_JIT` value is ignored with a
  notice). The buffer is carved out of the OPcache shared-memory segment,
  one per pool rather than per worker, so it costs 32-128 MB once; larger
  buffers measured slower. WordPress roots use it too;
  `SETUP_PHP_JIT_WORDPRESS=0` (persisted as `PHP_JIT_WORDPRESS`) keeps
  `opcache.jit = off` for every WordPress document root through a
  `[PATH=<root>]` section of the managed ini (applied per request by php-fpm,
  so it cannot leak like a FastCGI param) for a site that misbehaves with the
  JIT. `opcache.file_cache` stays empty, because scripts restored from the
  file cache are never JIT-compiled. Measured on the test host (XenForo
  2.3.13 + WordPress 7.1.4, PHP 8.5.12, 32 workers, 20 s runs, 100 members):
  tracing beat JIT off by 5% on XenForo members (910 vs 864 req/s, p50 69 vs
  73 ms); `function` lost 6-8% and had a 554 ms p99; 64 MB and 128 MB buffers
  were within 0.5%, and 256 MB was slower. The pool is always `pm = static`.
- Session/cgi hardening (`session.*` strict settings, `cgi.fix_pathinfo=0`,
  `display_errors=Off`, central `error_log`) is **opt-in**:
  `SETUP_PHP_SESSION_HARDENING=1`. It broke Joomla/Polr logins on a mixed
  host.

### XenForo (`--domain ... app=xf`)

The vhost serves guest pages from the FastCGI cache for 5 minutes with a
map-based bypass for `xf_session`/`xf_user`/admin/login cookies, a key that
varies on style, style variation, language and `Accept-Encoding`, background
refresh and stampede lock, 404/301 for 24 h, never 5xx, an immutable 30-day
location for `/js`, `/styles` and `/data`, and the server-level security
headers re-included inside the PHP locations (a location-level `add_header`
would otherwise drop HSTS). `--optimize` repairs or completes the same block
on older hosts. Application-side findings from the test host: disable the
"Members online", "Trending" and "Featured" forum-list widgets if unused
(+39% authenticated throughput), keep sessions/registry in MariaDB on a
single host (XF's Redis cache measured 27% slower there) and use
`$config['db']['host'] = 'p:localhost'` for persistent connections.

### MariaDB (`--mariadb user=U pass=P [size=auto|4gb] [bind=127.0.0.1[,ADDR|IPV4|::1]]`)

- Installs `mariadb-server`/`mariadb-client`, the systemd `LimitNOFILE`
  drop-in and the AppArmor capability override Ubuntu 26.04 needs for
  `mariadb-install-db`.
- Base block in `50-server.cnf` (utf8mb4, `skip_name_resolve`,
  `local_infile=0`, `secure_file_priv`, bind address; a commented-out
  `bind-address` is left alone by `--optimize`) and the hardware profile in
  `99-setup-optimize.cnf`: buffer pool from the plan (`size=auto` = live
  data+index +20%, 128 MB minimum; `size=` reserved verbatim), redo log
  pool/4 (64 MB..4 GB on NVMe, 2 GB otherwise), `innodb_io_capacity` by disk
  and host class (NVMe 10000/20000, VPS 3000/6000; SSD 4000/8000, VPS
  1000/2000; HDD 400/800 with `flush_neighbors=1`; `SETUP_MARIADB_IO_CAPACITY="r m"`
  pins it), I/O threads `clamp(threads/2, 4, 16)`, `thread_handling =
  pool-of-threads` sized to the CPUs, `max_connections = PHP workers x 1.25 +
  50` (threads x 32 without PHP, 200..2000, never below a live larger value),
  table caches `clamp(max_connections x 16, 4000, 32768)`, temp tables
  `clamp(RAM/256, 32, 256) MB` capped at pool/8, `flush_log_at_trx_commit=2`,
  slow log (1 s, 100 rows, plan+explain) and `log_error` under
  `/var/www/logs/mariadb/`. The generated files are validated with
  `mariadbd --help --verbose` before any restart.
- Creates the admin user for `localhost`, `127.0.0.1` and `::1` (needed with
  `skip_name_resolve`), installs the embedded `mysqltuner.pl` and
  `mysqlbackup` utility (`/etc/mysqlbkup.cnf`, 30 dumps kept; a re-run keeps
  an existing `/etc/mysqlbkup.config`). TCP 3306 is
  never opened; `bind=IPV4` resolves the public address and falls back to the
  local outbound IPv4 behind NAT.

### Valkey (`--valkey [ram=2g] [policy=allkeys-lru] [io_threads=1]`)

Skipped with a warning when `redis-server` is installed (`--optimize` then
tunes Redis with the same profile; Valkey wins when both exist). Managed
`valkey.conf`: loopback bind, `protected-mode`, `unixsocket
/run/valkey/valkey.sock` mode 770 with `www-data` in the `valkey` group,
`save ""`/`appendonly no` (cache only), `maxmemory` from the plan (live
working set +20% with a floor of RAM/64 clamped to 128 MB..1 GB; `ram=`
verbatim), `maxclients` from the PHP pool (workers x 4 + 2000, min 10000),
`tcp-backlog`, `hz 10`, lazy-free. `io_threads` stays 1: 8 threads cost 430%
CPU and lowered full-page throughput. Runtime values are applied with
`CONFIG SET`; a restart (which empties the cache) happens only for
startup-only keys. On a single host with local MariaDB, XenForo measured
faster without the Redis cache (see above).

### Elasticsearch (`--elastic [host=localhost] [ram=4g|auto]`)

Elastic 9.x repository, managed `elasticsearch.yml` block (`network.host`,
single-node discovery, X-Pack security off, `bootstrap.memory_lock`, bool
clause/bucket limits, index buffer and fielddata 20%, search threads
`clamp(cpus/2, 1, 16)`, write threads `clamp(cpus/4, 1, 8)`, compression,
200 MB content limit), `jvm.options.d/zz-setup-optimize.options` with the
heap (`auto` = index store/4 rounded to 512 MB, 512 MB..25% of RAM..31 GB;
an operator-owned `jvm.options` is kept), systemd `LimitMEMLOCK=infinity`
and `vm.max_map_count`. On a single node, yellow health caused by unassigned
replicas is fixed (replicas 0 plus a low-priority template). Keep
`host=localhost` unless X-Pack security, TLS and a firewall are in place;
the probe endpoint follows `http.host`/`network.host`/`http.port`.

### Other packages (`--others smartmon nvme gif nodejs sysstat | all`)

`smartmontools`; `nvme-cli` (dedicated host with NVMe only); `gifsicle`;
`nodejs` from NodeSource (`SETUP_NODE_MAJOR`, default 26; an installed major
is never switched silently because the native-addon ABI changes: pin it or
set `SETUP_NODE_ALLOW_MAJOR_UPGRADE=1`); `sysstat` with its timers.

### Domains (`--domain DOMAIN [app=TYPE] [db=NAME [user=U pass=P] [sql=FILE]] [DOMAIN ...]`)

Standalone (needs Angie, and MariaDB when `db=` is given). Per domain:
`/var/www/<domain>/public/` (www-data), a self-signed certificate under
`/etc/angie/ssl/<domain>/` (replace with ACME), a vhost rendered from the
repository template (`app=basic xf wordpress flarum pingvin chevereto polr
lychee shlink sfs php node`; `basic` is the default) and tested with
`angie -t`, and only when declared: the database (utf8mb4), a user with
`ALL` on that database for the three loopback hosts, and a dump import
(`.sql`, `.gz`, `.xz`, `.zst`, `.bz2`) into an empty database followed by a
MariaDB re-size (and the Valkey/Elasticsearch shares it was taken from). A
dump that carries its own `CREATE DATABASE`/`USE` for another schema (taken
with `--databases`) is refused before anything is loaded. Existing vhost
files and databases are preserved (an existing tree is not re-chowned);
application code is not installed. Can be combined with an install.

The run ends with the same tuning pass `--optimize` performs, because a new
vhost changes the plan (PHP-FPM worker cap, OPcache file budget, guest cache
for the new root, managed wp-cron / XenForo job entries): a domain install
therefore leaves the host in the state "install, then `--optimize`" produced.
`SETUP_DOMAIN_OPTIMIZE=0` skips that pass for a deployment script that copies
the application files afterwards and tunes separately.

## `--optimize`

Tunes the OS and every installed service in place (Ubuntu 22.04, 24.04,
26.04). It never installs, starts or purges a managed service and never
touches swap, the resolver (DNS) or the firewall (UFW), which stay as
`--basic` or the operator left them; the only packages it may add are
`cpufrequtils` and `angie-module-brotli`. The drivers run with `set -e`
live, so a failed write inside a tuner aborts the run with its line number
instead of being skipped (before 1.13.0 the `if ! run_optimize` call had
suspended errexit for the whole run). Steps:

1. OS profile (governor, PAM limits, sysctls) and the security pass.
2. Angie: `/etc/angie` is synced from `server-configs-nginx`, the WordPress
   and XenForo guest caches are enabled or repaired (shared `fastcgicache`
   zone, `$nocacheuri` and cookie-bypass maps), the hardware profile is
   applied, `angie -t` runs, and the service is reloaded **once, and only
   when the tree digest changed**; a failed sync or test restores the previous
   tree, its unit drop-in and `/etc/default/angie`. Legacy underscore-named
   `http.d` files are tuned in place. A WordPress vhost whose
   `include h5bp/wordpress_cache.conf;` was removed is an opt-out: it is
   reported, never re-enabled through the shared `php_wp.conf`
   (`SETUP_WP_GUEST_CACHE=1` adds the include to such vhosts).
3. PHP-FPM: every `/etc/php/<ver>/fpm` tree; a live TCP pool used through the
   `local_php` upstream is migrated to the Unix socket (graceful reload, or
   a short explicit restart when SIGUSR2 cannot open the listener).
4. MariaDB, Valkey/Redis and Elasticsearch from the shared 80%-of-RAM plan:
   live data is funded first (MariaDB data+index +20%, Valkey working set
   +20% with the RAM floor, Elasticsearch store/4), explicit sizes are
   reserved verbatim, PHP is sized from the remainder, and targets that do not
   fit are trimmed Elasticsearch first, then Valkey, then MariaDB. A value
   within 2% of its target is kept. A MariaDB restart pauses Angie and PHP
   first and resumes them after `SELECT 1`; when only the buffer pool, redo
   log, `tmp_table_size`/`max_heap_table_size` changed they are applied
   online with `SET GLOBAL` and nothing restarts. A `--domain ... sql=`
   import re-plans MariaDB **and** the Valkey/Elasticsearch shares it was
   taken from. Every failed service is rolled back from
   `/tmp/setup-optimize.*` through one shared restart/rollback helper (files
   created during the tune are moved out of the tree so a rejected drop-in
   cannot win again).
5. Audit of WordPress/XenForo configs (persistent `p:` database host, Valkey
   socket) with the exact snippets to apply; application files are never
   edited. Legacy cron and `/var/www` ownership from releases before 1.8.34
   are repaired.
6. Verification of every listener (`ss`, SQL, PING, HTTP) and recent
   error-level journal entries. The Markdown report goes to
   `/var/log/setup-optimize-<timestamp>.md` (`-latest.md` copy).

Explicit values (`--basic server=`, `--php children=`/`max_requests=`,
`--mariadb size=`, `--valkey ram=`, `--elastic ram=`) are recorded in
`/var/lib/setup.sh/explicit-options.conf` and kept by later runs; a
`--mariadb size=`/`--valkey ram=` under the 128 MB planner floor is raised
to 128m with a warning so install and the first `--optimize` agree.

Install and `--optimize` write the same files from the same functions. The
one documented difference is timing: `--domain app=xf|wordpress` creates an
empty document root, so the application-aware PHP worker cap and the
per-root OPcache JIT sections can only apply once the application files
exist, on the first `--optimize` after the upload (or after a `sql=` import).

## Hardware profile

Inputs: effective CPUs and RAM (cgroup-aware), the storage class behind the
data directory (NVMe / SSD / HDD) and the host class (`dedi`/`vps`).

| Area | Rule |
|---|---|
| PHP-FPM | 2 workers per logical CPU, at most RAM/2 at 96 MB each, 512 max, floor `min(8, RAM/2/96)`; **1 per logical CPU on a XenForo/WordPress host with a local database** (measured on a 16-thread Ryzen 7-class: 16 workers served 1044 member req/s at 11.2 ms PHP per request, 32 workers 936 req/s at 12.3 ms, 48 workers 627/20.3 ms on thread pages; the install plan budgets a fresh worker at 64 MB so the same host no longer writes 144 workers on install and 32 on the first `--optimize`); live count kept unless the application cap is lower; `children=` wins. `pm = static` always. `opcache.max_accelerated_files` = PHP files under the vhost roots x 1.5 (16384..128256; the ceiling when no root is found); `memory_limit`, OPcache, JIT buffer and realpath sizes from one RAM profile shared with the dry run |
| MariaDB | see the service section: pool from live data with floor `clamp(RAM/16, 256 MB, 4 GB)` for an empty or unmeasured database, io_capacity by disk x host, thread pool, connections from the PHP pool, table caches from connections, Aria page cache `clamp(RAM/128, 16, 256) MB` |
| Elasticsearch | heap = store/4 (512 MB..25% RAM..31 GB); `node.processors` = effective CPUs; search threads cpus/2 (max 16), write threads cpus/4 (max 8) |
| Valkey / Redis | maxmemory = live +20% with floor `clamp(RAM/64, 128 MB, 1 GB)`; maxclients from the PHP pool; io_threads 1..8 (a larger `io_threads=` is clamped with a warning) |
| Angie | `worker_processes` = CPUs (`worker_cpu_affinity auto` commented out under a cgroup CPU quota), `worker_connections = clamp(cpus x 2048, 8192, 65535)` and `worker_rlimit_nofile = clamp(cpus x 8192, 65536, 524288)` (VPS: 1024 and 4096 per core), **no PHP upstream keepalive cache** (an idle FastCGI connection pins one PHP-FPM worker; see the live-origin.example audit in `tests/stress-site/RESULTS.md`), `open_file_cache max = clamp(RAM_MB x 8, 10000, 200000)` bounded by `rlimit - connections`, FastCGI buffers and cache zones by RAM, cache disk budget by RAM/free disk/installed services (50% RAM Angie-only, 30% Angie+PHP, 25% full stack; a populated FastCGI, proxy or CDN cache is never shrunk below its live size), `directio 16m` on NVMe/SSD (4m on HDD), Brotli and gzip 5 (4 on 1-2 CPUs; `SETUP_BROTLI_LEVEL`, `SETUP_GZIP_LEVEL`) |
| Kernel | `somaxconn`/SYN backlog `cpus x 4096` (VPS x 2048, max 65536), conntrack `RAM_MB x 16` (VPS x 8), `tcp_rmem`/`tcp_wmem` default 85 KB under 4 GB, 128 KB under 16 GB, 256 KB above, `netdev_budget 600/8000 us` on dedicated hosts with 8+ CPUs, `vm.dirty_background_bytes = clamp(RAM/100, 64 MB, 512 MB)` and `vm.dirty_bytes = 4x` (tighter on HDD), `vm.min_free_kbytes` 1% of RAM (16 MB floor under 4 GB, 256 MB cap), `vm.swappiness` 1 on NVMe/SSD (10 on HDD), `kernel.shmmax = min(1 GiB, RAM/4)`, `ip_local_reserved_ports` = 3306, 6379, 9200, 9300 and the sshd ports (the ephemeral range is 1024-65535), BBR + fq (`SETUP_TCP_CC`, `SETUP_QDISC`), 1M-nofile PAM limits. The base profile's `ip_forward`/`forwarding = 0` lines are dropped on a host that already forwards (bridge, Docker/LXD, WireGuard/Tailscale interfaces) and its IPv6 `autoconf`/`accept_ra = 0` lines on a host whose address or default route comes from router advertisements |
| Host | swap RAM/2 clamped 1..8 GiB (VPS 4); governor on dedicated hardware only (the previous governor is recorded for `--purge`); THP `madvise`; `fstrim.timer` on SSD/NVMe; I/O scheduler and readahead per device class for every whole disk by its rotational flag (NVMe `none`, flash `mq-deadline`/128k, rotational `mq-deadline`/1024k; dm/md/loop/zram skipped) |

Environment overrides persisted in `/etc/default/setup-tuning`:
`SETUP_LIMIT_REQ_EXEMPT="ip,cidr,..."` (rate-limit exemptions for a load
generator or monitor; empty clears), `SETUP_PRECOMPRESS_ASSETS=0|1`, `SETUP_XF_JOB_CRON=0|1`,
`SETUP_PHP_JIT_WORDPRESS` (0 exempts WordPress roots from the always-on tracing JIT), `SETUP_NODE_MAJOR`. Others:
`SETUP_MARIADB_IO_CAPACITY`, `SETUP_BROTLI_LEVEL`, `SETUP_GZIP_LEVEL`,
`SETUP_ANGIE_COMPRESSION`, `SETUP_PHP_SESSION_HARDENING`, `SETUP_WP_DB_SPLIT`,
`SETUP_WP_ALLOW_FILE_MODS`, `SETUP_WP_GUEST_CACHE`, `SETUP_PURGE_MALWARE`,
`SETUP_STATE_DIR` (tests and image builds).

## `--diagnostics`, `--restart-all`, `--purge`

- Run logs (`setup_<timestamp>.log`) and `diagnostics.log` created under
  `sudo` are handed to the invoking user (`SUDO_UID`), mode 600.
- `--diagnostics` writes one mode-600 `diagnostics.log` beside `setup.sh`
  (hardware, network, sysctls, units, Angie/PHP/MariaDB/Valkey/Elasticsearch
  configuration and runtime statistics, slow and error logs, ownership, UFW,
  SSH, cron, package state) with credentials redacted. Read-only.
- `--restart-all` repairs `/var/www` log ownership, then stops Angie and
  every active PHP-FPM, restarts Valkey/Redis, Elasticsearch (waits for HTTP)
  and MariaDB (waits for `SELECT 1`), and starts PHP-FPM then Angie, using
  the same pause/resume and readiness helpers as the `--optimize` tuners.
  Only units that were active are touched; `--dry-run` prints the plan.
- `--purge [all|basic|angie|php [ver=X]|mariadb|valkey|elastic|others]`
  (service flags and bare names combine; no target means everything) stops
  and disables the selected services, removes the managed cron entries and,
  for `basic`, restores the recorded hostname (only the `127.0.1.1` line of
  `/etc/hosts`), timezone, DNS, every sysctl key the profile wrote (the base
  template's keys included), limits, the CPU governor that was active before
  the install, the `unattended-upgrades` APT file and unit state, and the
  UFW state (SSH rules are never removed; `/swapfile` stays enabled).
  `--purge` keeps going past a file it cannot restore and reports it.
  `--purge others` disables the `smartmontools`/`sysstat` units; `--purge
  --php ver=X` keeps `phpsessionclean.timer` while another version is
  enabled. Nothing is uninstalled or deleted; there is no domain purge.

## Idempotency

APT steps are no-ops when current; managed blocks (crontab, `50-server.cnf`,
`elasticsearch.yml`, `valkey.conf`, the ini/pool files) are replaced, never
duplicated; a `--basic`-only re-run regenerates the cron entries of installed
services; repositories and embedded keys are verified and refreshed; domain
creation preserves existing vhosts and databases; a repeat `--optimize` with
unchanged files reloads and restarts nothing.

## Embedded payloads

`dns_servers.conf`, `sysctl.conf`, `limits.conf`, `mysqltuner.pl` 2.9.3, the
`mysqlbackup` utility, the Angie/Elastic/NodeSource signing keys and the Sury
keyring package are embedded for offline, single-file use and verified by the
tests. Angie configuration and Cloudflare IP ranges are downloaded.

## Testing

- `bash tests/test-tuning.sh` (no root): unit tests of the tuning helpers,
  memory plan, config repairs and rollback. `bash tests/test-dry-run-matrix.sh`:
  every flag, app type, purge mode and representative invalid input through
  `--dry-run`. CI runs both plus `shellcheck`.
- `tests/stress-site/`: `setup-stress-site.sh` deploys a synthetic site
  (`stress.invalid`) that exercises every tier; `run-stress.sh` drives it
  locally with `wrk`; `run-stress-remote.sh TARGET_IP DOMAIN` drives it (and
  real XenForo/WordPress vhosts, guest and member tiers) from a workstation
  with the static `oha` binary while `collect-metrics.sh` samples the server.
  Run the install or `--optimize` with `SETUP_LIMIT_REQ_EXEMPT=<generator IP>`
  first, or every remote PHP request is answered `429`. Results and findings:
  `tests/stress-site/RESULTS.md`.

## Production checklist

- Replace the self-signed certificates with ACME (Angie has `http_acme`);
  behind Cloudflare, enable the real-IP config first or the per-IP limiter
  throttles everyone; consider HTTP/3 (`listen 443 quic`, `ufw allow 443/udp`).
- PHP: one pool and user per tenant with `open_basedir` in a dedicated pool
  (never via `fastcgi_param`); extend `disable_functions` where no app needs
  process execution; `opcache.validate_timestamps=0` with a reload on deploy.
- MariaDB: per-application users without `GRANT OPTION`; `flush_log_at_trx_commit=1`
  for critical data; TLS, UFW source rules and per-client accounts for remote
  access; off-site encrypted backups and tested restores; binary logs for
  point-in-time recovery; read replicas at scale.
- Valkey: `save ""` makes it a cache; use AOF and `noeviction`/`volatile-lru`
  (or a separate instance) for sessions, queues and locks; ACLs per app.
- Elasticsearch: never expose 9200/9300 without X-Pack security and TLS;
  snapshots to an external repository; a dedicated node once traffic grows.
- Host: keys-only SSH, fail2ban or provider protection, central monitoring and
  log shipping, alerting on 5xx/p99/disk/memory; remove `stress.invalid` and
  test data from production.
- Scale in this order: CDN and edge cache, FastCGI microcache, object cache,
  database tuning and replicas, search cluster, multiple web nodes behind a
  load balancer with shared sessions and storage.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Another PHP-FPM version is active" | only one version can own the socket: `--purge --php ver=X`, then install the new one |
| "Installation of system tables failed" (MariaDB) | Ubuntu 26.04 AppArmor profile; the script adds the override, re-run after `--purge --mariadb` if a previous install was interrupted |
| `smartd could not be enabled` | no SMART-capable disk (VMs); a warning only |
| `429` behind Cloudflare/a proxy | the limiter keys on the direct client address: enable real-IP (`/etc/angie/scripts/cloudflare.sh`, `cloudflare.conf`); tune `http.d/limit_req.conf` and `h5bp/limit_req/*.conf` |
| PHP-FPM slow log full of queued requests | `request_slowlog_timeout` counts from accept; check `listen queue` in `/fpm-status.php`, add workers or cache the endpoint |
| "upstream prematurely closed connection" during a load test | worker recycling at `pm.max_requests` or an FPM reload; set `pm.max_requests = 0` for a benchmark |
| `--domain` says Angie or MariaDB is missing | it only creates the vhost/database; install the stack first or combine the flags |

## Files and state

| Path | Purpose |
|---|---|
| `/run/setup.sh.lock`, `/tmp/setup-optimize.*` | run lock; `--optimize` rollback backups |
| `/var/lib/setup.sh/` | originals for `--purge basic`, UFW/swap state, package-origin markers, `explicit-options.conf` |
| `/etc/default/setup-tuning` | persisted overrides (`TCP_CC`, `QDISC`, `LIMIT_REQ_EXEMPT`, `PRECOMPRESS_ASSETS`, `PHP_JIT_WORDPRESS`, `NODE_MAJOR`) |
| `/etc/angie/` | Angie tree (`conf.d/<domain>.conf`, `ssl/<domain>/`, `http.d/zz-setup-*.conf` managed maps/zones) |
| `/home/nginx_cache*`, `/home/xf_proxy_cache`, `/home/proxy_cache*` | Angie cache directories |
| `/etc/php/<ver>/fpm/conf.d/zz-setup-optimize.ini`, `custom_dan.ini`, `pool.d/www.conf` | PHP tuning |
| `/etc/mysql/mariadb.conf.d/50-server.cnf`, `99-setup-optimize.cnf` | MariaDB base block and hardware profile |
| `/etc/valkey/valkey.conf`, `/run/valkey/valkey.sock` | Valkey |
| `/etc/elasticsearch/elasticsearch.yml`, `jvm.options.d/zz-setup-optimize.options` | Elasticsearch |
| `/etc/systemd/system/<unit>.service.d/limits.conf` | fd/memlock drop-ins for Angie, PHP-FPM, MariaDB, Valkey, Elasticsearch |
| `/etc/sysctl.d/90-setup-network.conf`, `/etc/security/limits.d/99-setup.conf`, `/etc/udev/rules.d/60-setup-io.rules`, `setup-io-tuning.service` | OS profile |
| `/var/www/logs/<service>/` | one log tree for every service (rotated by `/etc/logrotate.d/setup-logs`) |
| `/usr/local/bin/setup-precompress.sh`, `/usr/local/bin/mysqlbkup.sh`, `/etc/mysqlbkup.cnf`, `/root/mysqltuner.pl` | cron helpers and embedded tools |
| `/var/log/setup-optimize-*.md`, `diagnostics.log`, `setup_*.log` | reports and run logs |

Credentials are never stored in the repository; the MariaDB password is written
only to `/etc/mysqlbkup.cnf` on the target host. `--basic` changes hostname,
resolver, sysctls, limits, firewall and timezone: test on a disposable server
first. Release notes: `CHANGELOG.md`.
