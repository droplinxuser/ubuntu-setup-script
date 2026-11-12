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
| `lib/` | Implementation modules sourced in dependency order: `common` (logging, run log, temp/apt helpers), `cli`, `validate`, `util` (state, logs, cron), `os`, `web` (Angie/PHP-FPM tuning), `services` (repos, PHP, MariaDB, Valkey, Elasticsearch, domains), `purge`, `runner`, `optimize`, `security` (hardening), `service-optimizers` (per-service tune/verify, shared by `--optimize`/`--upgrade-php`), `diagnostics`, `restart`, `payloads` |
| `configs/system/`, `configs/mariadb/`, `configs/php/` | DNS/sysctl/limits, MariaDB and PHP-FPM templates |
| `tests/test-tuning.sh`, `tests/test-dry-run-matrix.sh` | Unit tests for the tuning helpers; CLI/dry-run matrix (both run in CI) |
| `tests/stress-site/` | Synthetic full-stack test site, local and remote load harness, results |
| `tools/diff_configs.sh` | Compare the canonical configs of both repos with the live `/etc` |
| `SECURITY-PERFORMANCE.md` | What the script hardens, what it leaves to the operator, and the large-site checklist |

## Requirements

- Ubuntu 26.04 LTS or newer for installs; `--optimize`, `--upgrade-php`,
  `--diagnostics` and `--restart-all` also accept 22.04 and 24.04. Bash 4.4+.
  Root.
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

# Replace the installed PHP with a newer version, keeping extensions/config
sudo bash setup.sh --upgrade-php=8.6
bash setup.sh --upgrade-php=8.6 --dry-run
```

## Command reference

| Command | Purpose | Details |
|---|---|---|
| `--basic [server=] [host=] [swap=] [time=]` | OS baseline; required for every install | [`--basic`](#--basic) |
| `--angie` | Angie web server and its configuration tree | [Angie](#angie---angie) |
| `--php [ver=] [children=] [max_requests=]` | PHP-FPM | [PHP](#php---php) |
| `--mariadb user= pass= [size=] [bind=]` | MariaDB | [MariaDB](#mariadb---mariadb) |
| `--valkey [ram=] [policy=] [io_threads=]` | Valkey cache | [Valkey](#valkey---valkey) |
| `--elastic [host=] [ram=]` | Elasticsearch | [Elasticsearch](#elasticsearch---elastic) |
| `--others ITEM... \| all` | helper packages | [Other packages](#other-packages---others) |
| `--domain DOMAIN [app=] [db=] [user=] [pass=] [sql=]` | vhost, certificate and optional database | [Domains](#domains---domain) |
| `--optimize` | tune the OS and every installed service in place | [`--optimize`](#--optimize) |
| `--upgrade-php=X.Y` | replace the installed PHP version in place | [`--upgrade-php`](#--upgrade-phpxy) |
| `--diagnostics` | write a redacted `diagnostics.log`; read-only | [Maintenance](#--diagnostics---restart-all---purge) |
| `--restart-all` | ordered restart of every active service | [Maintenance](#--diagnostics---restart-all---purge) |
| `--purge [TARGET...]` | stop and disable services, restore recorded settings | [Maintenance](#--diagnostics---restart-all---purge) |
| `--dry-run` (alias `--check`) | validate any command and print the plan as a normal user; nothing is changed | works with every command above |
| `--help`, `--version` | usage text; script version | |

## `--basic`

| Option | Default | Effect |
|---|---|---|
| `server=dedi\|vps` | auto (`systemd-detect-virt`, DMI, cgroups) | `dedi` sets the `performance` CPU governor; the pin is recorded so `--optimize` keeps the host class |
| `host=FQDN` | `<threads>c-<RAM_GB>g-<storage>` (e.g. `8c-32g-1T`) | hostname via `hostnamectl` |
| `swap=SIZE` | add swap only when total swap is 0 or below 50% of RAM, up to 50% of RAM (1-8 GiB, 4 GiB on a VPS) | `/swapfile` of exactly that size (`8G`, `8Gi`, `512M`) |
| `time=REGION/CITY` | `Asia/Manila` | timezone |

What `--basic` does:

| Step | Detail |
|---|---|
| DNS | drop-in with `8.8.8.8`, `1.1.1.1` and `Domains=~.`, so they are the default route rather than only a fallback |
| Packages | upgrades packages; installs the basic tools, `cron`, `logrotate` and `unattended-upgrades` |
| OS profile | sysctl, PAM limits, governor, THP `madvise`, udev I/O rules (see [Hardware profile](#hardware-profile)) |
| Root crontab | ownership repair of `/var/www` that skips logs and `wp-config.php`; Cloudflare IP refresh; MariaDB backup at 03:03 and monthly `mariadb-check`; `wp-cron.php` every 5 minutes; asset precompression when enabled |
| Firewall (UFW) | deny in, allow out, `ufw limit` on every effective SSH port, 80/443 open |
| State | originals are recorded under `/var/lib/setup.sh` for `--purge basic` |

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

`--angie` takes no arguments. What it does:

| Step | Detail |
|---|---|
| Packages | `angie` and `angie-module-brotli` |
| Configuration | deploys the `server-configs-nginx` tree with the built-in deployer |
| Tuning | hardware profile and guest caches (the same `angie_apply_profile` as `--optimize`) |
| Service files | systemd `LimitNOFILE` drop-in and `/etc/default/angie` from the repository |
| Cloudflare | generates `http.d/cloudflare.conf` |
| Finish | restarts the service |

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_BROTLI_LEVEL=1..11` | 4 (3 on 1-2 CPU hosts) | dynamic Brotli level; gzip is the fallback |
| `SETUP_ANGIE_COMPRESSION=0` | on | turns the managed compression profile off |
| `SETUP_PRECOMPRESS_ASSETS=1` | off (a CDN normally serves assets) | writes `.br`/`.gz` siblings for the static assets of every XenForo/WordPress root and keeps them fresh from cron; persisted as `PRECOMPRESS_ASSETS` in `/etc/default/setup-tuning` |
| `SETUP_XF_JOB_CRON=0` | on | removes the managed crontab entry that runs `cmd.php xf:run-jobs` once a minute as www-data for every XenForo root; persisted as `XF_JOB_CRON` |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF` | `droplinxuser/server-configs-nginx`, `main` | select a fork or branch of the configuration tree |
| `CONFIG_SOURCE_DIR=/path` | unset | use a local checkout instead of downloading |

Notes:

- With the XenForo job entry in place, switch *Options > Performance > Job
  run trigger* to server-based in the admin CP so member page requests stop
  running the queue. Never run the queue as root: the data directories it
  creates return 403 through Angie.
- An upstream name that a deployed vhost still references but the canonical
  tree no longer defines (a repository rename, or an operator-edited `http.d`
  file) is preserved in `http.d/zz-setup-preserved-upstreams.conf` instead of
  making `angie -t` fail with *host not found in upstream*. The include is
  regenerated on each install/`--optimize` and retired once the repository
  defines the name again.

### PHP (`--php`)

| Option | Default | Effect |
|---|---|---|
| `ver=X.Y` | latest stable release in the Sury repository | PHP version to install |
| `children=auto\|N` | `auto` (shared memory plan and CPU count) | `pm.max_children`; an explicit value wins over every rule below |
| `max_requests=N` | threads x 1024 | recycle a worker after N requests |

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_PHP_WORKERS_PER_CPU` | by host class (see the pool table) | pins the workers-per-CPU factor |
| `SETUP_PHP_JIT_HOT_LOOP`, `_FUNC`, `_RETURN`, `_SIDE_EXIT` | PHP defaults on 4+ CPU hosts; a conservative set on 1-2 CPUs | JIT hotness thresholds |
| `SETUP_PHP_JIT_WORDPRESS=0` | 1 (WordPress uses the JIT) | keeps `opcache.jit = off` for every WordPress document root through a `[PATH=<root>]` section of the managed ini, for a site that misbehaves with the JIT; persisted as `PHP_JIT_WORDPRESS` |
| `SETUP_PHP_PAGE_GZIP=0` | 1 | by default the managed ini turns `zlib.output_compression` (level 4) on in a `[PATH=<root>]` section for every WordPress and Chevereto document root whose guest cache key carries the encoding token, so the FastCGI cache stores the gzip page (0.12 ms of Angie CPU per hit instead of about 1 ms to compress each hit); Chevereto roots also get PHP session GC (`session.gc_probability = 1`, divisor 1000) because no timer cleans its session directory; persisted as `PHP_PAGE_GZIP` |
| `SETUP_PHP_SESSION_HARDENING=1` | off | opt-in `session.*` strict settings, `cgi.fix_pathinfo=0`, `display_errors=Off` and a central `error_log`; it broke Joomla/Polr logins on a mixed host |

Install behaviour:

| Area | Detail |
|---|---|
| Repository | Sury, with an embedded keyring |
| One version only | both Angie and the pool use `/run/php/php-fpm.sock`, so only one PHP-FPM version can be active; a `--php` run purges every `php*` package first and copies the old `/etc/php` to `/tmp` |
| Changing version | use `--upgrade-php=8.6`, which also carries the extension set and custom configuration; switching manually means `--purge --php ver=8.4` then `--php ver=8.5` |
| Extensions | the XenForo profile: `fpm cli opcache mysql gd curl xml zip gmp mbstring redis`; add `intl`/`imagick`/`bcmath` yourself if an add-on needs them |

Pool (`pool.d/www.conf`):

| Setting | Value |
|---|---|
| `pm` | always `static` |
| `pm.max_children` | logical CPUs x factor, capped by the shared memory plan (at most RAM/2 at 96 MB per worker, 512 maximum) |
| Workers-per-CPU factor | 1.0 with a local MariaDB on flash storage; 1.5 on a shared/virtual CPU or a remote database; 2.0 on spinning disks |
| `pm.max_requests` | threads x 1024 |
| `request_terminate_timeout` | 300s |
| Slow log | 10 s |
| `rlimit_files`, systemd | 524288; `LimitNOFILE=524288`, `UMask=0027` |

Measured on the 16-thread audit host (XenForo member page, loopback, 64
connections): 16 workers 834 req/s at 14.38 ms PHP CPU/request, 32 workers
808 req/s at 15.68 ms. Extra workers only contend for the same cores.

`php.ini` (`zz-setup-optimize.ini`):

| Setting | Value |
|---|---|
| `memory_limit` | 256-512M (128M under 2 GB of RAM) |
| OPcache | 128-512 MB with interned strings |
| Realpath cache | 4-16 MB |
| MariaDB | socket defaults |
| `opcache.jit` | always `tracing`; there is no mode switch (an old `SETUP_PHP_JIT` or persisted `PHP_JIT` value is ignored with a notice) |
| `opcache.jit_buffer_size` | OPcache/8, 32-128 MB; carved out of the OPcache shared-memory segment once per pool, not per worker |
| `opcache.file_cache` | empty, because scripts restored from the file cache are never JIT-compiled |
| `custom_dan.ini` | refreshed from `configs/php/` while the host timezone is kept |

Measured on the test host (XenForo 2.3.13 + WordPress 7.1.4, PHP 8.5.12, 32
workers, 20 s runs, 100 members): tracing beat JIT off by 5% on XenForo
members (910 vs 864 req/s, p50 69 vs 73 ms); `function` lost 6-8% and had a
554 ms p99; 64 MB and 128 MB buffers were within 0.5%, and 256 MB was slower.

Angie-side repairs made by the PHP step: `fastcgi_param PATH_TRANSLATED` is
repaired in every `h5bp/php*.conf`, and any per-request `PHP_ADMIN_VALUE
open_basedir` is commented out (PHP-FPM caches admin values per worker, so
one vhost's setting leaked onto every other vhost of the shared pool).

### XenForo (`--domain ... app=xf`)

Cacheable guest requests are served from a named location
(`@xf_guest_cache`) that never forwards `Set-Cookie`, so one visitor's
`xf_csrf` cookie is not replayed to the next; XenForo's own JavaScript
fetches a fresh token from `/login/keep-alive` when the cookie is missing.
Members, POSTs and no-cache URIs stay in the uncached PHP location.

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

### MariaDB (`--mariadb`)

| Option | Default | Effect |
|---|---|---|
| `user=U` | required | admin user, created for `localhost`, `127.0.0.1` and `::1` (needed with `skip_name_resolve`) |
| `pass=P` | required | its password; also written to `/etc/mysqlbkup.cnf` (mode 600) |
| `size=auto\|4gb` | `auto` | InnoDB buffer pool: `auto` = live data+index +20% from the shared memory plan, 128 MB minimum; an explicit size is reserved verbatim |
| `bind=ADDR[,ADDR...]` | `127.0.0.1` | comma-separated IPv4 addresses and/or `::1`; `IPV4` resolves the public address and falls back to the local outbound IPv4 behind NAT. TCP 3306 is never opened in the firewall |

Environment option:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_MARIADB_IO_CAPACITY="r m"` | by disk and host class | pins `innodb_io_capacity` and `innodb_io_capacity_max` |

Installed:

| Item | Detail |
|---|---|
| Packages | `mariadb-server`, `mariadb-client` |
| Service files | systemd `LimitNOFILE` drop-in; the AppArmor capability override Ubuntu 26.04 needs for `mariadb-install-db` |
| Tools | embedded `mysqltuner.pl` and the `mysqlbackup` utility (`/etc/mysqlbkup.cnf`, 30 dumps kept; a re-run keeps an existing `/etc/mysqlbkup.config`) |
| Validation | the generated files are checked with `mariadbd --help --verbose` before any restart |

Base block (`50-server.cnf`):

| Setting | Value |
|---|---|
| Character set | utf8mb4 |
| `skip_name_resolve` | on |
| `innodb_snapshot_isolation` | 0, so REPEATABLE READ keeps MySQL's behaviour and XenForo does not hit MariaDB error 1020 |
| `local_infile` | 0 |
| `secure_file_priv` | set |
| `bind-address` | from `bind=`; a commented-out `bind-address` is left alone by `--optimize` |

Hardware profile (`99-setup-optimize.cnf`):

| Setting | Rule |
|---|---|
| Buffer pool | from the plan (see `size=`) |
| Redo log | pool/4 (64 MB..4 GB on NVMe, 2 GB otherwise) |
| `innodb_io_capacity` / `_max` | NVMe 10000/20000 (VPS 3000/6000); SSD 4000/8000 (VPS 1000/2000); HDD 400/800 with `flush_neighbors=1` |
| I/O threads | `clamp(threads/2, 4, 16)` |
| `thread_handling` | `pool-of-threads`, sized to the CPUs |
| `max_connections` | PHP workers x 1.25 + 50 (threads x 32 without PHP), 200..2000, never below a live larger value |
| Table caches | `clamp(max_connections x 16, 4000, 32768)` |
| Temp tables | `clamp(RAM/256, 32, 256) MB`, capped at pool/8 |
| `flush_log_at_trx_commit` | 2 |
| Logs | slow log (1 s, 100 rows, plan+explain) and `log_error` under `/var/www/logs/mariadb/` |

### Valkey (`--valkey`)

| Option | Default | Effect |
|---|---|---|
| `ram=SIZE` | live working set +20%, with a floor of RAM/64 clamped to 128 MB..1 GB | `maxmemory`; an explicit value is used verbatim |
| `policy=NAME` | `allkeys-lru` | `maxmemory-policy`; use `noeviction` or `volatile-lru` when Valkey stores sessions or jobs that must survive |
| `io_threads=N` | 1 | extra socket I/O threads; 8 threads cost 430% CPU and lowered full-page throughput, so raise it only after `valkey-benchmark` shows the main thread is saturated |

Managed `valkey.conf`:

| Setting | Value |
|---|---|
| Network | loopback bind, `protected-mode` |
| Socket | `unixsocket /run/valkey/valkey.sock`, mode 770, with `www-data` in the `valkey` group |
| Persistence | `save ""`, `appendonly no` (cache only) |
| `maxclients` | PHP workers x 4 + 2000, minimum 10000 |
| Other | `tcp-backlog`, `hz 10`, lazy-free |

Notes:

- Skipped with a warning when `redis-server` is installed; `--optimize` then
  tunes Redis with the same profile. Valkey wins when both exist.
- Runtime values are applied with `CONFIG SET`; a restart (which empties the
  cache) happens only for startup-only keys.
- On a single host with local MariaDB, XenForo measured faster without the
  Redis cache (see the XenForo section).

### Elasticsearch (`--elastic`)

| Option | Default | Effect |
|---|---|---|
| `host=NAME` | `localhost` | `network.host`; keep `localhost` unless X-Pack security, TLS and a firewall are in place |
| `ram=4g\|auto` | `auto` | JVM heap: `auto` = index store/4 rounded to 512 MB, between 512 MB and 25% of RAM (31 GB ceiling) |

Installed and configured:

| Item | Detail |
|---|---|
| Repository | Elastic 9.x |
| `elasticsearch.yml` managed block | `network.host`, single-node discovery, X-Pack security off, `bootstrap.memory_lock`, bool clause/bucket limits, index buffer and fielddata 20%, compression, 200 MB content limit |
| Thread pools | search `clamp(cpus/2, 1, 16)`, write `clamp(cpus/4, 1, 8)` |
| Heap file | `jvm.options.d/zz-setup-optimize.options`; an operator-owned `jvm.options` is kept |
| System | systemd `LimitMEMLOCK=infinity`, `UMask=0027`, `vm.max_map_count` |
| Single node | yellow health caused by unassigned replicas is fixed (replicas 0 plus a low-priority template) |
| Probe endpoint | follows `http.host`/`network.host`/`http.port` |

### Other packages (`--others`)

Name one or more items, or `all`.

| Item | Installs | Notes |
|---|---|---|
| `smartmon` | `smartmontools` | |
| `nvme` | `nvme-cli` | dedicated host with NVMe storage only |
| `gif` | `gifsicle` | |
| `nodejs` | Node.js from NodeSource | major from `SETUP_NODE_MAJOR` (default 26). An installed major is never switched silently because the native-addon ABI changes: pin it, or set `SETUP_NODE_ALLOW_MAJOR_UPGRADE=1` |
| `sysstat` | `sysstat` with its timers | `sar`/`iostat` performance history |
| `all` | everything above | |

### Domains (`--domain`)

`--domain DOMAIN [app=TYPE] [db=NAME [user=U pass=P] [sql=FILE]] [DOMAIN ...]`

Standalone; needs Angie, and MariaDB when `db=` is given. It can be repeated
and combined with an install. Options follow the domain they belong to.

| Option | Default | Effect |
|---|---|---|
| `DOMAIN` | required | the site's host name |
| `app=TYPE` | `basic` | vhost template: `basic`, `xf`, `wordpress`, `flarum`, `pingvin`, `chevereto`, `polr`, `lychee`, `shlink`, `sfs`, `php`, `node` |
| `db=NAME` | none | create the database (utf8mb4); only when declared |
| `user=U pass=P` | none | create that user with `ALL` on `db=` only, for the three loopback hosts; both are required together |
| `sql=FILE` | none | import a dump (`.sql`, `.gz`, `.xz`, `.zst`, `.bz2`) into `db=` while it is still empty, then re-size MariaDB (and the Valkey/Elasticsearch shares it was taken from) |

Environment option:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_DOMAIN_OPTIMIZE=0` | on | skips the closing tuning pass, for a deployment script that copies the application files afterwards and tunes separately |

Created per domain:

| Path | Content |
|---|---|
| `/var/www/<domain>/public/` | document root owned by www-data |
| `/etc/angie/ssl/<domain>/` | self-signed certificate (replace with ACME) |
| `/etc/angie/conf.d/<domain>.conf` | vhost rendered from the repository template and tested with `angie -t` |

Notes:

- A dump that carries its own `CREATE DATABASE`/`USE` for another schema
  (taken with `--databases`) is refused before anything is loaded.
- Existing vhost files and databases are preserved (an existing tree is not
  re-chowned). Application code is not installed.

The run ends with the same tuning pass `--optimize` performs, because a new
vhost changes the plan (PHP-FPM worker cap, OPcache file budget, guest cache
for the new root, managed wp-cron / XenForo job entries): a domain install
therefore leaves the host in the state "install, then `--optimize`" produced.
`SETUP_DOMAIN_OPTIMIZE=0` skips that pass for a deployment script that copies
the application files afterwards and tunes separately.

## `--optimize`

| Option | Effect |
|---|---|
| `--optimize` | tune the OS and every installed service in place (Ubuntu 22.04, 24.04, 26.04) |
| `--optimize --dry-run` | print the planned OS and service values only; runs as a normal user |

Tunes the OS and every installed service in place. It never installs, starts
or purges a managed service and never
touches swap, the resolver (DNS) or the firewall (UFW), which stay as
`--basic` or the operator left them; the only package it may add is
`angie-module-brotli`. The drivers run with `set -e`
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
   a short explicit restart when SIGUSR2 cannot open the listener).  The pool
   is always `pm = static`, one worker per logical CPU when a local database
   and flash storage share the host, 1.5 on a shared CPU or remote database,
   2.0 on spinning disks (see the hardware table); a pool sized by hand is
   normalised to that rule, and the report names the before/after and the
   resident memory it returns (a 64-thread board left on 512 static workers
   is set to 64).
4. MariaDB, Valkey/Redis and Elasticsearch from the shared 80%-of-RAM plan:
   live data is funded first (MariaDB data+index +20%, Valkey working set
   +20% with the RAM floor, Elasticsearch store/4), explicit sizes are
   reserved verbatim, PHP is sized from the remainder, and targets that do not
   fit are trimmed Elasticsearch first, then Valkey, then MariaDB. A value
   within 2% of its target is kept. A MariaDB restart pauses Angie and PHP
   first and resumes them after `SELECT 1`; when only dynamic variables
   changed (buffer pool, redo log, `tmp_table_size`/`max_heap_table_size`,
   `innodb_io_capacity`(_max), `table_open_cache`, `max_connections`,
   `thread_pool_size`, `innodb_flush_neighbors`) they are applied online with
   `SET GLOBAL`, each read back, and nothing restarts. A startup-only key or
   the managed base block still needs a restart.
   A `--domain ... sql=`
   import re-plans MariaDB **and** the Valkey/Elasticsearch shares it was
   taken from. Every failed service is rolled back from
   `/tmp/setup-optimize.*` through one shared restart/rollback helper (files
   created during the tune are moved out of the tree so a rejected drop-in
   cannot win again).
5. Audit of WordPress/XenForo configs (persistent `p:` database host, Valkey
   socket) with the exact snippets to apply; application files are never
   edited and **application schemas are never altered** (see "Manual
   follow-ups" below for changes worth making by hand). Legacy cron and
   `/var/www` ownership from releases before 1.8.34 are repaired.
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

## `--upgrade-php=X.Y`

Replaces the installed PHP with another version in place instead of purging
and reinstalling the host.

| Option | Effect |
|---|---|
| `--upgrade-php=X.Y` | target version, newer or older than the installed one (e.g. `8.6`); on a host with no PHP installed it performs a fresh install |
| `--dry-run` | prints the upgrade plan and the extension mapping without changing anything |

It is standalone and cannot be combined with install flags, `--optimize`,
`--purge`, `--diagnostics`, `--restart-all` or `--domain`.

| Step | What happens |
|---|---|
| 1. Snapshot | every installed PHP package with its exact version, each extension and whether `apt-mark` calls it manual, operator-owned `.ini` drop-ins in `conf.d`, extra FPM pools, the PECL list and a copy of `/etc/php` under `/var/lib/setup.sh/php-upgrade-<timestamp>/` |
| 2. Target check | adds/refreshes the Sury repository and requires `phpX.Y-fpm` to be published. A pre-release (for example PHP 8.6.0~rc5) is accepted when named explicitly, with a warning |
| 3. Purge | every `php*` package plus `libapache2-mod-php*`, then the dependencies that only PHP kept installed. The dependency set is the before/after `apt-get -s autoremove` delta, so pre-existing unrelated autoremove candidates are never touched |
| 4. Install | `phpX.Y-fpm`/`cli` and the default set, then every old extension mapped to `phpX.Y-<ext>`. An extension the new release does not publish yet is reported and skipped; core PHP still installs. A missing extension makes the run exit non-zero (`ATTENTION`) without undoing the upgrade, so automation notices. The skipped names are kept in `/var/lib/setup.sh/php-pending-extensions` and installed by the next `--upgrade-php` whose target publishes them (an 8.5 -> 8.6 RC -> 8.5 round trip keeps imagick) |
| 5. Migrate | operator `.ini` files and extra pools are copied with the version path rewritten, validated with `php-fpm -t` (rejected files are moved out of the live tree), and FPM is reloaded so the workers actually load them. The PHP `date.timezone` from the old tree is preserved |
| 6. Tune | the same shared tuner as install/`--optimize` writes the pool (`pm=static`, hardware worker count, backlog), `zz-setup-optimize.ini` (memory/realpath/OPcache/tracing JIT), systemd limits and log paths; Angie is reloaded when active; the systemd drop-in of a PHP-FPM version that is no longer installed is removed |
| 7. Verify/report | CLI version, FPM unit, the primary and every extra pool socket, extension packages and the JIT are checked; a Markdown report with the rollback commands is written to `/var/log/setup-php-upgrade-<timestamp>.md` |

The managed files produced by an upgrade are byte-identical to a
`--basic ... --php ver=X.Y` install (verified on the audit host: pool,
`zz-setup-optimize.ini`, `custom_dan.ini` and the systemd drop-in), and a
following `--optimize` changes nothing.

## Manual follow-ups (never automated)

setup.sh does not rewrite application files and **does not alter application
schemas**: no `ALTER TABLE`, no index creation, no data change on a forum or
CMS database. Schema work is an operator decision taken with the vendor's
upgrade path in mind. Two measured items are worth applying by hand:

- **XFMG gallery count (XenForo + XenForo Media Gallery).** The gallery
  index computes its pagination total with `SELECT COUNT(*) FROM
  xf_mg_media_item WHERE (album_state = 'visible' OR album_state IS NULL)
  AND category_id IN (...) AND media_state IN ('visible')`. Without a
  covering index that is a full table scan on every member view. Measured on
  a live board with about 74 000 media rows: 47.7 ms -> 23.4 ms, MariaDB CPU for
  the page 54.0 -> 30.7 ms, uncached gallery index 62 -> 90 req/s (+45 %),
  p50 130 -> 88 ms. Add it yourself during a maintenance window:

  ```sql
  ALTER TABLE xf_mg_media_item
    ADD INDEX mg_count_cover (media_state, album_state, category_id),
    ALGORITHM=INPLACE, LOCK=NONE;
  ```
- **XenForo media widgets and job runner.** Disabling the Members online /
  Trending / Featured widgets on the forum list and switching *Options >
  Performance > Job run trigger* to server-based (paired with the managed
  `xf:run-jobs` crontab entry) were worth +39 % authenticated throughput in
  the same audit. Both are ACP settings, so setup.sh only reports them.
- **A shop add-on that filters the thread list.** On a board with a
  DragonByte-style shop add-on, the index page ran
  `SELECT thread_id FROM xf_thread LEFT JOIN <shop>_thread_ban ...` (one full
  scan of the thread table, 338 ms) plus
  `SELECT xf_user.* WHERE is_banned = 0 AND user_state = 'valid'`
  (119 ms) - about **1.1 s of MariaDB CPU per member view**, the single
  largest member-facing cost measured.  Fix it in the add-on or its ACP
  widget, or add an index on the add-on's ban table by hand; the optimizer
  will never touch that schema.

## Hardware profile

Inputs: effective CPUs and RAM (cgroup-aware), the storage class behind the
data directory (NVMe / SSD / HDD) and the host class (`dedi`/`vps`).

| Area | Rule |
|---|---|
| PHP-FPM | `pm = static`, `pm.max_children` = logical CPUs x the host's blocking factor (1.0 for a local database on flash, 1.5 for a shared/virtual CPU or a remote database, 2.0 for spinning disks), bounded by the RAM plan; a pool sized by hand is normalised to the same count, so a fresh install and `--optimize` write the same value (a 64-thread board left on 512 static workers is set to 64). `SETUP_PHP_WORKERS_PER_CPU` pins the factor; an explicit `--php children=` wins and is clamped to floor..max(512, 2 x CPUs). `pm.max_requests = threads x 1024`, `request_terminate_timeout 300s`, slow log at 10 s, `rlimit_files 524288`, systemd `LimitNOFILE=524288`/`UMask=0027`. `opcache.max_accelerated_files` = PHP files under the vhost roots x 1.5 (16384..128256; the ceiling when no root is found); `memory_limit`, OPcache, JIT buffer and realpath sizes from one RAM profile shared with the dry run |
| MariaDB | see the service section: pool from live data with floor `clamp(RAM/16, 256 MB, 4 GB)` for an empty or unmeasured database, io_capacity by disk x host, thread pool, connections from the PHP pool, table caches from connections, Aria page cache `clamp(RAM/128, 16, 256) MB` |
| Elasticsearch | heap = store/4 (512 MB..25% RAM..31 GB); `node.processors` = effective CPUs; search threads cpus/2 (max 16), write threads cpus/4 (max 8) |
| Valkey / Redis | maxmemory = live +20% with floor `clamp(RAM/64, 128 MB, 1 GB)`; maxclients from the PHP pool; io_threads 1..8 (a larger `io_threads=` is clamped with a warning) |
| Angie | `worker_processes` = CPUs (`worker_cpu_affinity auto` commented out under a cgroup CPU quota), `worker_connections = clamp(cpus x 2048, 8192, 65535)` and `worker_rlimit_nofile = clamp(cpus x 8192, 65536, 524288)` (VPS: 1024 and 4096 per core), **no PHP upstream keepalive cache** (an idle FastCGI connection pins one PHP-FPM worker; see the live-origin.example audit in `tests/stress-site/RESULTS.md`), `open_file_cache max = clamp(RAM_MB x 8, 10000, 200000)` bounded by `rlimit - connections`, FastCGI buffers and cache zones by RAM, cache disk budget by RAM/free disk/installed services (50% RAM Angie-only, 30% Angie+PHP, 25% full stack; a populated FastCGI, proxy or CDN cache is never shrunk below its live size), `directio 16m` on NVMe/SSD (4m on HDD), Brotli and gzip 4 (3 on 1-2 CPUs; `SETUP_BROTLI_LEVEL`, `SETUP_GZIP_LEVEL`) |
| Kernel | `somaxconn`/SYN backlog `cpus x 4096` (VPS x 2048, max 65536), conntrack `RAM_MB x 16` (VPS x 8), `tcp_rmem`/`tcp_wmem` default 85 KB under 4 GB, 128 KB under 16 GB, 256 KB above, `netdev_budget 600/8000 us` on dedicated hosts with 8+ CPUs, `vm.dirty_background_bytes = clamp(RAM/100, 64 MB, 512 MB)` and `vm.dirty_bytes = 4x` (tighter on HDD), `vm.min_free_kbytes` 1% of RAM (16 MB floor under 4 GB, 256 MB cap), `vm.swappiness` 1 on NVMe/SSD (10 on HDD), `kernel.shmmax = min(1 GiB, RAM/4)`, `ip_local_reserved_ports` = 3306, 6379, 9200, 9300 and the sshd ports (the ephemeral range is 1024-65535), BBR + fq (`SETUP_TCP_CC`, `SETUP_QDISC`), 1M-nofile PAM limits. The base profile's `ip_forward`/`forwarding = 0` lines are dropped on a host that already forwards (bridge, Docker/LXD, WireGuard/Tailscale interfaces) and its IPv6 `autoconf`/`accept_ra = 0` lines on a host whose address or default route comes from router advertisements |
| Host | swap RAM/2 clamped 1..8 GiB (VPS 4); governor on dedicated hardware only (the previous governor is recorded for `--purge`); THP `madvise`; `fstrim.timer` on SSD/NVMe; I/O scheduler and readahead per device class for every whole disk by its rotational flag (NVMe `none`, flash `mq-deadline`/128k, rotational `mq-deadline`/1024k; dm/md/loop/zram skipped) |

### Environment overrides

Persisted in `/etc/default/setup-tuning`, so a later plain `--optimize` keeps
them:

| Variable | Values | Effect |
|---|---|---|
| `SETUP_LIMIT_REQ_EXEMPT` | `"ip,cidr,..."` | rate-limit exemptions for a load generator or monitor; an empty value clears them |
| `SETUP_PRECOMPRESS_ASSETS` | `0\|1` | static-asset precompression |
| `SETUP_XF_JOB_CRON` | `0\|1` | managed XenForo job-runner crontab entry |
| `SETUP_PHP_JIT_WORDPRESS` | `0\|1` | 0 exempts WordPress roots from the always-on tracing JIT |
| `SETUP_PHP_PAGE_GZIP` | `0\|1` | 0 stops PHP from gzipping WordPress/Chevereto pages for the guest cache (default 1: the cache stores the compressed page) |
| `SETUP_STORAGE_CLASS` | `nvme\|ssd\|hdd` | pins the storage class when the kernel cannot see the medium (read on each run; persist it as `STORAGE_CLASS=` in `/etc/default/setup-tuning`) |
| `SETUP_NODE_MAJOR` | major number | Node.js major installed by `--others nodejs` |

Read on each run, not persisted:

| Variable | Effect |
|---|---|
| `SETUP_TCP_CC`, `SETUP_QDISC` | congestion control and qdisc for one run (default BBR + fq); to pin a host, set `TCP_CC=`/`QDISC=` in `/etc/default/setup-tuning` |
| `SETUP_MARIADB_IO_CAPACITY` | pins `innodb_io_capacity`/`_max` |
| `SETUP_BROTLI_LEVEL`, `SETUP_GZIP_LEVEL` | dynamic compression levels |
| `SETUP_ANGIE_COMPRESSION` | 0 turns the managed compression profile off |
| `SETUP_PHP_WORKERS_PER_CPU` | pins the PHP-FPM workers-per-CPU factor |
| `SETUP_PHP_JIT_HOT_LOOP`, `_FUNC`, `_RETURN`, `_SIDE_EXIT` | JIT hotness thresholds |
| `SETUP_PHP_SESSION_HARDENING` | 1 enables the opt-in session/cgi hardening |
| `SETUP_WP_DB_SPLIT` | 0 keeps a WordPress `DB_USER` with global privileges as it is |
| `SETUP_WP_ALLOW_FILE_MODS` | 1 keeps WordPress plugin installs enabled |
| `SETUP_WP_GUEST_CACHE` | 1 re-adds the guest-cache include to WordPress vhosts that removed it |
| `SETUP_PURGE_MALWARE` | 1 deletes known webshells instead of quarantining them |
| `SETUP_DOMAIN_OPTIMIZE` | 0 skips the tuning pass at the end of `--domain` |
| `SETUP_CHEV_GUEST_CACHE` | 1 forces the Chevereto guest cache on, 0 off; by default it is on unless the site allows guest uploads |
| `SETUP_NODE_ALLOW_MAJOR_UPGRADE` | 1 allows a one-off Node.js major switch |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF`, `CONFIG_SOURCE_DIR` | source of the Angie configuration tree |
| `SETUP_STATE_DIR` | private state directory for tests and image builds |

## `--diagnostics`, `--restart-all`, `--purge`

| Command | What it does | Notes |
|---|---|---|
| `--diagnostics` | writes one mode-600 `diagnostics.log` beside `setup.sh`: hardware, network, sysctls, units, Angie/PHP/MariaDB/Valkey/Elasticsearch configuration and runtime statistics, slow and error logs, ownership, UFW, SSH, cron, package state | read-only; credentials are redacted |
| `--restart-all [--dry-run]` | repairs `/var/www` log ownership, stops Angie and every active PHP-FPM, restarts Valkey/Redis, Elasticsearch (waits for HTTP) and MariaDB (waits for `SELECT 1`), then starts PHP-FPM and Angie | only units that were active are touched; uses the same pause/resume and readiness helpers as the `--optimize` tuners; `--dry-run` prints the plan |
| `--purge [TARGET...]` | stops and disables the selected services and removes their managed cron entries | nothing is uninstalled or deleted; it keeps going past a file it cannot restore and reports it; there is no domain purge |

Run logs (`setup_<timestamp>.log`) and `diagnostics.log` created under `sudo`
are handed to the invoking user (`SUDO_UID`), mode 600.

`--purge` targets (service flags and bare names combine; no target means
everything):

| Target | Effect |
|---|---|
| `all` or no target | every target below |
| `basic` | restores the recorded hostname (only the `127.0.1.1` line of `/etc/hosts`), timezone, DNS, every sysctl key the profile wrote (the base template's keys included), limits, the CPU governor that was active before the install, the `unattended-upgrades` APT file and unit state, and the UFW state. SSH rules are never removed; `/swapfile` stays enabled |
| `angie` | stops and disables Angie |
| `php [ver=X]` | stops and disables PHP-FPM; with `--php ver=X`, one version only, and `phpsessionclean.timer` is kept while another version is enabled |
| `mariadb` | stops and disables MariaDB |
| `valkey` | stops and disables Valkey |
| `elastic` | stops and disables Elasticsearch |
| `others` | disables the `smartmontools` and `sysstat` units |

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
  `bench-one.sh` measures one tier with per-service CPU attribution,
  `jit-sweep.sh` A/Bs OPcache JIT profiles and `fpm-sweep.sh` (with
  `set-fpm.sh`) sweeps PHP-FPM worker counts; both restore the pool when they
  finish.  `deploy-three-apps.sh` installs WordPress, XenForo and Chevereto
  from local archives on `--domain` vhosts, `exercise-apps.sh` walks their
  guest, member, admin and CLI paths, `compat-php.sh` lints every PHP file
  and re-runs the walk with each application in its strict debug mode (the
  applications hide `E_DEPRECATED` themselves), `loopback-tiers.sh` measures
  the load tiers on the host with `wrk`, and `sweep-php.sh jit|fpm|stock`
  A/Bs JIT profiles, worker counts and the distribution defaults.  Run the install or `--optimize` with
  `SETUP_LIMIT_REQ_EXEMPT=<generator IP>` first, or every remote PHP request
  is answered `429`. Results and findings: `tests/stress-site/RESULTS.md`;
  per-sweep tables: `JIT-SWEEP-*.md`, `FPM-SWEEP-*.md`, `FINAL-*.md`.

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
