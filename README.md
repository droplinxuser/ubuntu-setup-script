# Ubuntu Setup Script

A single, idempotent Bash provisioning script for **Ubuntu 26.04 LTS** (and newer LTS releases such as 28.04). It installs and configures a complete web/database stack from one command. `--purge` stops and disables selected services and restores recorded basic settings, but it deliberately leaves packages, configuration, databases and logs on disk. Angie configuration is downloaded from `server-configs-nginx`; PHP-FPM templates are local under `configs/php/`, so a PHP install needs a repository checkout (or that directory packaged beside `setup.sh`).

**File-safety policy:** every transient file is created under `/tmp`, and the script never unlinks, purges or otherwise permanently removes files or directories on the server. Anything left in `/tmp` is allowed to expire through the system's normal `/tmp` cleanup. The one intentional file written outside `/tmp` is the requested run log: every invocation creates `setup_<timestamp>.log` in the directory it was started from, so it can be pulled for debugging. `--purge` is therefore a stop/disable operation, not a destructive uninstall; remove data manually only after you have verified it is no longer needed.

Angie configuration is **not** hard-coded in this script. It is downloaded at install time from [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx), which is the single source of truth for Angie/Nginx configs. PHP-FPM pool and `php.ini` templates are **non-Angie** configuration and live locally under `configs/php/` in this repository.

The script is designed for a fresh server but is safe to re-run on an already configured machine. Only the services named on the command line are touched.

## Repository layout

| Path | Contents |
|---|---|
| `setup.sh` | Installer/provisioner (packages, services, domains, purge) |
| `configs/system/` | DNS, CPU governor, sysctl and limits profiles |
| `configs/mariadb/` | MariaDB reference profile and systemd limits |
| `configs/php/` | PHP-FPM pool templates, `custom_dan.ini` and systemd limits |
| `tests/stress-site/` | Full-stack test site and stress harness |
| `tests/test-dry-run-matrix.sh` | CLI/dry-run validation matrix |
| `tests/test-tuning.sh` | Unit tests for the hardware-aware tuning helpers |
| `/var/www/logs/` (live) | One directory tree for Angie, PHP, MariaDB, Valkey, Node.js, GifSicle and Elasticsearch logs |
| `tools/diff_configs.sh` | Compare canonical configs (both repos) with live `/etc` |

Angie/Nginx configuration lives only in
[`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx).
All non-Angie configuration, including PHP-FPM, MariaDB, Valkey and
Elasticsearch, lives here.

`setup.sh` prefers the local files under `configs/` when it is run from this
checkout. System/MariaDB/systemd blobs still have embedded fallbacks, but the
PHP-FPM pool/ini templates are intentionally local files under `configs/php/`;
run the install from a repository checkout (or package that directory
alongside `setup.sh`).

---

## Requirements

- Ubuntu 26.04 LTS or newer for installation (`--optimize` also supports 22.04 and 24.04); the script checks `ID=ubuntu` and the version.
- Bash 4.0 or newer (associative arrays); Ubuntu ships Bash 5.x.
- Root access (`sudo bash setup.sh ...`).
- Internet access to the Ubuntu, Angie, Sury, Elastic and NodeSource package repositories, plus GitHub for the Angie/PHP configuration repository. For offline/testing use, set `CONFIG_SOURCE_DIR` to a local checkout.
- Enough disk/RAM for the selected services:
  - Elasticsearch: roughly 1.5 GB of disk plus the requested JVM heap.
  - MariaDB: the requested InnoDB buffer pool plus normal database growth.
  - PHP: a few hundred MB, plus one static FPM worker per `pm.max_children` slot.

---

## Quick start

The commands below are complete and copy-paste ready for a brand new Ubuntu 26.04 server. Only the services named on a command are installed. `--basic` is required for every install profile; its values are auto-detected when omitted.

> Replace `pass=temp` with a strong password before running any MariaDB command. The password is also written to the local backup configuration.

### Full stack (all services)

```bash
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
  --valkey \
  --elastic host=localhost ram=4g \
  --others all
```

### Large-site starting profile

`size=auto` sizes InnoDB to 40% of RAM; PHP, OPcache/JIT, memory/realpath settings and Valkey are sized from RAM automatically. Add `children=` only after measuring worker RSS.

```bash
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey ram=4g policy=allkeys-lru io_threads=1 \
  --elastic host=localhost ram=4g \
  --others all
```

### Basic-only and minimal profiles

```bash
# Basic hardening only; auto-detect server type, hostname and swap
sudo bash setup.sh --basic

# Minimal Angie + PHP, with all basic values auto-detected
sudo bash setup.sh --basic --angie --php

# Basic with explicit dedicated-server values
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G

# Basic on a VPS; the CPU governor step is skipped automatically
sudo bash setup.sh --basic server=vps host=web-vps.example.com time=UTC swap=2G

# Angie only
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --angie

# PHP-FPM only, using the latest stable PHP in Sury
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --php

# Angie + PHP
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --angie --php ver=8.5

# Valkey only
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --valkey

# Elasticsearch only
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --elastic host=localhost ram=4g

# Other utilities only
sudo bash setup.sh --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G --others all
```

### MariaDB profiles

```bash
# Local-only MariaDB (recommended default)
sudo bash setup.sh \
  --basic server=dedi host=db1.example.com time=Asia/Manila swap=8G \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1

# Local MariaDB plus the detected public IPv4 (use for remote clients)
sudo bash setup.sh \
  --basic server=dedi host=db1.example.com time=Asia/Manila swap=8G \
  --mariadb user=demo pass=temp size=8gb bind=127.0.0.1,IPV4

# Local MariaDB plus explicit interfaces
sudo bash setup.sh \
  --basic server=dedi host=db1.example.com time=Asia/Manila swap=8G \
  --mariadb user=demo pass=temp size=8gb bind=127.0.0.1,10.0.0.5

# Local MariaDB plus IPv6 loopback
sudo bash setup.sh \
  --basic server=dedi host=db1.example.com time=Asia/Manila swap=8G \
  --mariadb user=demo pass=temp size=8gb bind=127.0.0.1,::1
```

### Common web stacks

```bash
# Web app without search: Angie + PHP + MariaDB + Valkey
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
  --valkey

# Web app with search: Angie + PHP + MariaDB + Valkey + Elasticsearch
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
  --valkey \
  --elastic host=localhost ram=4g

# Web app with search and all utilities
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
  --valkey \
  --elastic host=localhost ram=4g \
  --others smartmon nvme gif nodejs
```

### Domains

`--domain` is standalone: Angie and MariaDB must already be installed and MariaDB must be running. It creates the document root, a blank Angie vhost and the database. Existing vhost files are preserved.

```bash
# One domain
sudo bash setup.sh --domain google.com

# Multiple domains
sudo bash setup.sh --domain google.com example.org my-site.example.com

# Full install and domain creation in one command
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=demo pass=temp size=4gb bind=127.0.0.1 \
  --valkey \
  --elastic host=localhost ram=4g \
  --others all \
  --domain google.com example.org
```

If a service flag is omitted, that service is **not** installed. `--basic` values are optional and auto-detected when omitted. `--domain` does **not** require `--basic` when used by itself.

### Dry run / validation

`--dry-run` (alias `--check`) parses and validates the command, then prints the resolved install or purge plan without touching the system. It works as a normal user, which makes it safe for CI and for checking combinations:

```bash
./setup.sh --dry-run --basic server=dedi host=web1.example.com time=Asia/Manila \
  --angie --php --mariadb user=demo pass=temp size=4gb --valkey --elastic ram=4g
./setup.sh --dry-run --purge --angie --php ver=8.5
```

---

## Basic setup (`--basic`)

`--basic` is mandatory for installs, but **all of its values are optional**:

| Option | Required | Description |
|---|---|---|
| `server=dedi\|vps` | no | `dedi` also installs `cpufrequtils` and sets the CPU governor to `performance` when the CPU exposes that governor. `vps` skips that step. If omitted, the script detects it with `systemd-detect-virt`, DMI product data and cgroup checks. |
| `host=FQDN` | no | Hostname set with `hostnamectl`. If omitted, the script generates one from the hardware: `<threads>c-<RAM_GB>g-<storage>` (for example `8c-32g-1T` for 8 threads, 32 GB RAM and 1 TB of disks). |
| `swap=SIZE` | no | Explicit swap file size, e.g. `8G`, `2G`, `512M`. If omitted, the script only adds swap when the current total is zero **or** below 50% of RAM, and sizes it so the total becomes 50% of RAM. |
| `time=REGION/CITY` | no | Timezone; defaults to `Asia/Manila`. |

Basic performs:

1. Writes its own `/etc/systemd/resolved.conf.d/dns_servers.conf` (`8.8.8.8`, `1.1.1.1`) and restarts `systemd-resolved`. Other resolver drop-ins are left untouched.
2. Updates Ubuntu and upgrades packages. Snapd and package caches are left alone.
3. On a dedicated server, when the CPU exposes the performance governor: installs `cpufrequtils`, writes `/etc/default/cpufrequtils`, enables the service, and sets the `performance` governor. On a VPS or a host without that governor the step is skipped.
4. Installs basic tools: `wget unzip nano zip software-properties-common rsync ca-certificates curl gnupg dmidecode git`. `openssl` and `logrotate` are installed by the domain/logrotate steps when needed.
5. Generates a hostname if one was not supplied, then sets the hostname and timezone.
6. Handles swap:
   - With `swap=SIZE`: creates/reuses `/swapfile` at exactly that size.
   - Without `swap`: computes current swap and RAM. If current swap is 0 or below 50% of RAM, it creates/resizes `/swapfile` so the **total** swap becomes 50% of RAM. If current swap is already at least 50%, it leaves the existing configuration untouched.
7. Replaces `/etc/sysctl.conf` with the tuned profile and applies it (`/etc/sysctl.d/99-sysctl.conf` symlink is added when needed).
8. Writes the high `nofile` limits to `/etc/security/limits.d/99-setup.conf`; a distribution `/etc/security/limits.conf` is restored if an older release replaced it.
9. Installs/enables cron and writes a managed crontab block for the selected services and for services already installed and configured by this script:
   - Angie: daily ownership repair of `/var/www` that skips the shared log tree (`/var/www/logs`, owned per service), `/var/www/mysql_database` and `*.log` files, daily `chmod +x` and execution of `/etc/angie/scripts/cloudflare.sh`.
   - MariaDB: daily 03:03 mysql backup and monthly `mariadb-check`.
10. Configures UFW: deny incoming, allow outgoing, rate-limit every effective SSH port with `ufw limit`, allow 80 and 443, enable the firewall. The original active state, added rules and default policies are recorded so `--purge basic` can restore them.

Before changing basic settings, the script records the originals under `/var/lib/setup.sh/backup`. `--purge basic` restores them by overwriting the live files and moves generated drop-ins that did not exist before to `/tmp` instead of leaving them active. `/swapfile` and its `/etc/fstab` entry are left enabled (`/var/lib/setup.sh/swapfile-managed`). Swap is never created or resized by `--optimize`.

---

## Services

### Angie (`--angie`)

- Installs the Angie signing key and APT repository.
- Installs `angie`.
- Installs the official `angie-module-brotli` dynamic module and enables dynamic Brotli at level 5 with gzip as the compatibility fallback. On a 149 KB XenForo thread page this produced 10.9 KB on the wire versus 13.7 KB for gzip (20% smaller); guest pages were 79-93% smaller than identity. `--optimize` installs and enables the same module, so both paths stay in parity. Static assets are deliberately left to the CDN (`brotli_static off`): precompressing thousands of files only helps the first origin miss and adds deployment churn. Set `SETUP_BROTLI_LEVEL=1..11` to override the level or `SETUP_ANGIE_COMPRESSION=0` to disable it.
- Downloads [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx) once per run and delegates deployment to its `scripts/nginx_conf.sh`.
- The repository (not `setup.sh`) owns `angie.conf`, `h5bp/`, `conf.d/`, `http.d/`, `snippets/`, the cache/rate-limit settings, template repairs and the Cloudflare helper.
- Uses the repo's `scripts/limit_nofile.conf` and `scripts/etc_default_nginx` for the systemd `LimitNOFILE` drop-in and `/etc/default/angie`.
- The repo deployer creates cache directories, removes obsolete setup.sh/pre-refactor config filenames, runs `angie -t`, and reloads Angie.
- Configuration source overrides: `CONFIG_SOURCE_DIR=/path` (local checkout/testing), `CONFIG_REPO_URL=...`, `CONFIG_REPO_REF=main`.
- Generates `/etc/angie/http.d/cloudflare.conf` via the repo's `scripts/cloudflare.sh` and reloads Angie.

### PHP (`--php [ver=8.5] [children=auto|N] [max_requests=N]`)

- Adds the Sury APT repository (keyring embedded in the script and verified against the payload on every run).
- If `ver=` is omitted, selects the **latest stable PHP** available to APT from the Sury repository (currently 8.5; pre-release packages such as `8.6.0~rc3` are ignored).
- **Purges previous PHP packages before installing.** All packages matching `php*` (versions, CLI, common, FPM, extensions) are removed first and the old `/etc/php` tree is copied to `/tmp`, so a stopped second PHP version cannot later take over the shared socket. This is intentionally destructive for PHP only; MariaDB/Redis data is not touched.
- Installs the XenForo profile: `php<ver>-fpm`, `php<ver>-cli`, `php<ver>-opcache`, `php<ver>-mysql`, `php<ver>-gd`, `php<ver>-curl`, `php<ver>-xml`, `php<ver>-zip`, `php<ver>-gmp`, `php<ver>-mbstring`, `php<ver>-redis`. It does not install `intl`, `imagick`, `bcmath`, `apcu`, `igbinary`, `msgpack`, `sqlite3` or `bz2` unless you add them yourself.
  - OPcache/JIT settings in `custom_dan.ini` are active because `php<ver>-opcache` is installed. Add `php<ver>-intl` only if an add-on needs it.
- Deploys `www.conf` from `configs/php/www_<ver>.conf` and `custom_dan.ini` from `configs/php/custom_dan.ini`. Add a new `configs/php/www_<ver>.conf` to support a new PHP version. These are local non-Angie configs; no Angie repo fetch is needed for a PHP-only install.
- Fills in the dynamic values from `setup.sh`:
  - `pm.max_children = RAM_budget / 96 MB` (the shared 80%-of-RAM plan; capped at `CPU threads × 16`, 512, and at least 8)
  - `pm.max_requests = CPU threads × 1024`
  - override either with `children=` / `max_requests=`
- Sizes OPcache, JIT and `memory_limit` from RAM instead of fixed 512 MB values:
  - OPcache 128–512 MB, JIT 32–128 MB, `memory_limit` 256–512 MB, realpath cache 4–16 MB.
- The repo templates provide OPcache file cache under `/var/cache/php/opcache`, `request_slowlog_timeout=10s`, `catch_workers_output=yes`, MariaDB Unix-socket defaults and `mysqlnd` statistics disabled. PHP session settings are left at their defaults, and `cgi.fix_pathinfo` keeps PHP's runtime default.
- `--optimize` writes the performance tuning into `/etc/php/<ver>/fpm/conf.d/zz-setup-optimize.ini` and leaves PHP sessions alone. It also refreshes a stale `conf.d/custom_dan.ini` from `configs/php/custom_dan.ini`, preserving the host's existing `date.timezone`; this removes old 2 GB `memory_limit`, JIT-off and `curl_exec`/`exec` `disable_functions` values. The optimizer also changes `fastcgi_param PATH_TRANSLATED $document_root$fastcgi_path_info;` to `$document_root$fastcgi_script_name;` in every deployed `h5bp/php*.conf` include, so `cgi.fix_pathinfo=0` cannot make PHP-FPM execute the document root. Global session overrides broke Joomla/Polr logins, so `session.*` hardening (strict mode, cookies-only, `HttpOnly`, `Secure`, `SameSite=Lax`, long IDs), `cgi.fix_pathinfo=0`, `display_errors=Off` and the central `error_log` are **opt-in**: run `sudo SETUP_PHP_SESSION_HARDENING=1 ./setup.sh --optimize`. Test every application before enabling it.
- `setup.sh` creates the log/cache directories and the systemd `LimitNOFILE=524288`, `UMask=0027` drop-in. PHP-FPM and Angie use the Unix socket `/run/php/php-fpm.sock`.
- Sets the PHP timezone from `--basic time=`.
- Enables and restarts `php<ver>-fpm` and prints `php<ver> -v`. If the template/tuning/start fails, the previous PHP configuration is restored from `/tmp`.

**PHP version policy:** the pool listens on `/run/php/php-fpm.sock`, and the Angie `local_php` upstream points to the same socket. Therefore **only one PHP-FPM version can be active at a time**. A new `--php` run purges all existing PHP packages first and performs a clean installation of the requested version.

### XenForo tuning (`--domain ... app=xf`)

The generated `app=xf` vhost serves guest pages from Angie's FastCGI cache
for 5 minutes and bypasses it for `xf_session`, `xf_user`, admin and login
cookies. The stack-level defaults (PHP-FPM static workers, Unix sockets,
MariaDB thread pool, Brotli, HTTP/2 keepalive) are tuned for XenForo. Measured
on the 16-thread test host (Ubuntu 26.04, XenForo 2.3.13, 50 authenticated
users):

| Change | Authenticated index | Notes |
|---|---:|---|
| Default stack + Brotli 5 | ~1.0k req/s | 51 KB HTML -> 9.8 KB Brotli |
| Disable "Members online" widget | ~1.2k req/s | 13% smaller HTML |
| Disable members-online + trending + featured widgets | **~1.43k req/s** | +39%, ACP > Widgets |
| XenForo Redis registry/session cache | ~0.97k req/s | slower than local MariaDB on one host |
| MariaDB-backed registry/sessions (no XF cache) | **~1.33k req/s** | recommended for a single host |

Recommended application settings:

- Keep `xf_session_activity` optimization enabled (XenForo default); it skips
  repeat activity writes within one second.
- Do **not** enable XF's Redis cache on a single host with local MariaDB just
  because Valkey is installed. It measured 27% slower than MariaDB sessions.
  Use it for multi-node installations or a remote/slow database.
- If you use persistent DB connections, set `$config['db']['host'] =
  'p:localhost'` and keep the socket path. The synthetic DB endpoint improved
  from 23k to 38k req/s (+62%); XF itself is mostly CPU-bound.
- Disable the "Members online", "Trending content" and "Featured content"
  forum-list widgets when they are not required; they issue several queries
  and add 13% HTML per authenticated page.
- Set `opcache.validate_timestamps=0` and reload PHP-FPM on deploy if the
  application files are stable; it removes per-request stat calls. Measure
  first: the template-heavy XF workload showed little difference on this host.
- Guest traffic stays on Angie's FastCGI cache. Do not cache authenticated
  pages; the vhost's cookie bypass is intentional.

### MariaDB (`--mariadb user=... pass=... size=4gb|auto [bind=...]`)

- Installs `mariadb-server` and `mariadb-client`.
- Adds a systemd `LimitNOFILE=1048576` drop-in and silences the package's unset-environment warning.
- Writes a managed `[mariadbd]` block into `/etc/mysql/mariadb.conf.d/50-server.cnf`:
  - `max_connections = CPU threads × 32` (clamped to 200–2000, never below a live larger ceiling)
  - `innodb_buffer_pool_size = size` (`size=auto` = shared 80%-of-RAM plan, minimum 256 MB)
  - `innodb_log_file_size = size / 4` (clamped 64 MB–2 GB), `innodb_log_buffer_size = 64M`
  - `innodb_flush_log_at_trx_commit = 2` (durable across server crash; use `1` if every committed transaction must survive an OS crash)
  - `innodb_snapshot_isolation = 1` (standard MVCC isolation)
  - `innodb_read_io_threads` / `innodb_write_io_threads = CPU threads` (capped 64)
  - `thread_handling = pool-of-threads` / `thread_pool_size = CPU threads` — on this host this cut p99 for short web queries from ~745 ms to ~9 ms by removing connection-thread churn
  - `innodb_io_capacity` chosen for NVMe (4000/8000), SSD (2000/4000) or HDD (400/800)
  - 512k join/read buffers, 1M sort buffer, 64M temp tables, 8k table/open-file caches on ≥4 GB pools
  - `secure_file_priv=/var/lib/mysql-files`, `local_infile=0`, `wait_timeout=600`, `max_allowed_packet=64M`
  - Slow query log at `/var/www/logs/mariadb/slow.log` (`long_query_time=1`, `min_examined_row_limit=100`, query plan + explain)
  - `bind-address` from `bind=` (default `127.0.0.1`)
- `--optimize` writes performance settings to `/etc/mysql/mariadb.conf.d/99-setup-optimize.cnf` and removes the performance/logging keys from `50-server.cnf`, not only from the marker block: older releases wrote these keys bare, so this is what makes the 99- drop-in the single owner. Base settings (charset, `skip_name_resolve`, `open_files_limit`, `secure_file_priv`, `bind-address`) remain in 50. The optimizer leaves a `/tmp` copy and does not delete the file.
- Comments out `expire_logs_days`.
- Creates the requested admin user with `GRANT ALL ... WITH GRANT OPTION` for `localhost`, `127.0.0.1` and `::1` (idempotent `CREATE USER IF NOT EXISTS` + `ALTER USER`). The extra loopback hosts are required because `skip_name_resolve=1` means a TCP connection to `127.0.0.1` does **not** match `'user'@'localhost'`.
- Creates `/var/www/logs/mariadb`, sets ownership, reloads systemd and restarts MariaDB.
- Does not download MariaDB tools at runtime: `mysqltuner.pl` and the `mysqlbackup` repository are embedded. It installs `mysqltuner.pl` to `/root/mysqltuner.pl`, installs the backup utility under `/root/tools/mysqlbackup-master`, and writes `/etc/mysqlbkup.cnf` with the requested user/password.
- Verifies `mysqldump` and `mariadb-check` are present.

**Multiple bind addresses / remote access:** `bind=` accepts a comma-separated list of IPv4 addresses, `::1`, and the special token `IPV4`:

```bash
# Listen on loopback and a specific interface
sudo bash setup.sh --basic ... --mariadb user=demo pass=temp size=4gb \
  bind=127.0.0.1,10.0.0.5

# Listen on loopback plus the detected public IPv4
sudo bash setup.sh --basic ... --mariadb user=demo pass=temp size=4gb \
  bind=127.0.0.1,IPV4
```

`IPV4` first asks an external service for the public address. If that address is not assigned to a local interface (typical behind NAT), it warns and falls back to the local outbound IPv4 instead of writing an unusable bind. Whitespace and duplicate addresses are removed.

The script does **not** open TCP 3306 in UFW and does not create `'user'@'%'` accounts. For remote clients, allow only trusted source addresses and create a matching account:

```bash
sudo ufw allow from 203.0.113.10 to any port 3306 proto tcp
sudo mariadb -e "CREATE USER 'app'@'203.0.113.10' IDENTIFIED BY 'strong-password'; \
  GRANT SELECT,INSERT,UPDATE,DELETE ON appdb.* TO 'app'@'203.0.113.10';"
```

Use TLS (`require_secure_transport=ON`) if traffic crosses an untrusted network.

The MariaDB backup cron entry is added only when MariaDB is selected.

**Ubuntu 26.04 AppArmor note:** the packaged `mariadbd` AppArmor profile omits `dac_override`/`setuid`/`setgid`, which breaks `mariadb-install-db` on re-installs. The script adds a managed capability override to `/etc/apparmor.d/local/mariadbd` and removes a stale loaded profile before reinstalling. `--purge mariadb` removes the override.

### Valkey (`--valkey [ram=2g] [policy=allkeys-lru] [io_threads=1]`)

- If an existing `redis-server` is present, Valkey installation is skipped with a warning instead of failing the run or purging Redis. Run `--optimize` to tune the existing Redis server with the same cache profile (maxmemory, policy, backlog, maxclients, lazy-free, systemd fd limits, `CONFIG SET` before restart).
- Replaces the managed directives in `/etc/valkey/valkey.conf` (no duplicates):
  - `supervised systemd`
  - `save ""` (cache-only; enable AOF/RDB if you store sessions or queues)
  - `maxmemory` from `ram=` or 10% of RAM (minimum 256 MB, maximum 8 GB)
  - `maxmemory-policy` from `policy=` (default `allkeys-lru`)
  - `maxmemory-samples 10`
  - `bind 127.0.0.1 -::1`, `protected-mode yes`
  - `unixsocket /run/valkey/valkey.sock`, `unixsocketperm 770`; `www-data` is added to the `valkey` group so local PHP can use the socket
  - `io-threads 1` by default, `tcp-backlog 65535`, `maxclients 20000`, `hz 10`, lazy-free settings
- Enables/restarts `valkey-server`, refreshes PHP-FPM so workers inherit the `valkey` group, and verifies `valkey-cli ping` returns `PONG`.

If both Valkey and Redis are installed, `--optimize` tunes Valkey only, because applying the same shared cache budget twice would overcommit RAM.

Benchmarks on this host showed that extra I/O threads are counterproductive for small web-cache commands: full-page throughput was 6.5k req/s with `io_threads=1` vs 5.1k with `io_threads=8`, while Valkey CPU rose from 64% to 430%. Raise `io_threads=` only after `valkey-benchmark` shows the main thread saturated.

For local PHP, prefer the Unix socket (`/run/valkey/valkey.sock`) over TCP. In the stress test it raised Valkey endpoint throughput from ~15k to ~29k req/s and removed most of the p99 tail caused by ephemeral-port/TIME_WAIT pressure.

**XenForo caution:** a local Redis/Valkey cache is not automatically faster
than a local MariaDB. On a single 16-thread host, XenForo's registry/session
cache over the Unix socket measured **0.97k req/s** on authenticated pages,
while MariaDB-backed sessions/registry measured **1.33k req/s** (+37%). Enable
XF's Redis cache for multi-node installations, a remote/slow database, or a
large shared registry; benchmark it first on a single host. `--optimize` prints
this warning next to the XenForo snippet.

### Elasticsearch (`--elastic [host=localhost] ram=4g`)

- Installs the Elastic 9.x APT repository and signing key (embedded).
- Installs `elasticsearch`.
- Writes a managed block to `/etc/elasticsearch/elasticsearch.yml`:
  - `cluster.name: essearch`
  - `network.host` from `host=` (default `localhost`)
  - `http.port: 9200`
  - `bootstrap.memory_lock: true` (the systemd drop-in sets `LimitMEMLOCK=infinity`)
  - `indices.query.bool.max_clause_count: 4096`, `search.max_buckets: 65536`
  - `indices.memory.index_buffer_size: 20%`, `indices.fielddata.cache.size: 20%`
  - `action.destructive_requires_name: true`, `http.compression: true`, `http.max_content_length: 200mb`
  - `discovery.type: single-node`
  - disables `xpack.security.enabled` and `xpack.security.enrollment.enabled`
  - comments out `cluster.initial_master_nodes`
  - comments out the package’s `http.host`/`transport.host` so `network.host` actually controls the bind address
- Writes `/etc/elasticsearch/jvm.options.d/zz-setup-optimize.options` with `-Xms<ram>`, `-Xmx<ram>`, G1GC, a 200 ms pause target and heap-dump-on-OOM. An operator-owned `jvm.options` is preserved; only the legacy script-generated file is moved to `/tmp`.
- Writes `/etc/systemd/system/elasticsearch.service.d/limits.conf` with `LimitMEMLOCK=infinity`, `LimitNOFILE=1048576` and `LimitNPROC=4096`.
- Handles IPv6 hosts correctly when probing `http://[::1]:9200`.
- Writes `/etc/elasticsearch/scripts/xf-date-weighted.groovy`.
- Sets `vm.max_map_count=1048576` (persisted in `/etc/sysctl.d/99-elasticsearch.conf`, rewritten on every install/optimize so an older lower value cannot survive a reboot).
- Enables/restarts Elasticsearch and waits for the HTTP endpoint to become ready.
- `--optimize` resolves the effective HTTP endpoint from `http.host` (when set) or `network.host`, honours a custom `http.port`, and uses it for the index/heap/readiness/replica calls. A node intentionally bound to a local IPv4 for a remote XenForo client is therefore probed on that address instead of `127.0.0.1`; if the host itself cannot reach the endpoint (firewall/NAT), the active unit plus the exact listener is reported instead of rolling back a healthy tune.

With security disabled, keep `host=localhost` unless you really intend to expose port 9200. The script warns when a non-loopback `host=` is used; enable X-Pack security/TLS and a firewall before exposing it. For a remote Elasticsearch client, allow TCP 9200 only from the XenForo server and prefer a private network or X-Pack security/TLS. The heap is also checked against 50% of RAM and a warning is printed if it is too large.

### Other packages (`--others ...`)

Available names: `smartmon`, `nvme`, `gif`, `nodejs`, `sysstat`, or `all`.

| Name | Installs |
|---|---|
| `smartmon` | `smartmontools` (and tries to enable `smartd`) |
| `nvme` | `nvme-cli` — **only when the server is dedicated and the storage is actually NVMe**; otherwise skipped |
| `gif` | `gifsicle` |
| `nodejs` | NodeSource 26.x repository/key (embedded) and `nodejs` |
| `sysstat` | `sysstat` and its collect/summary timers (`sar`, `iostat`, `pidstat`) |

`--others all` expands to `smartmon nvme gif nodejs sysstat` (subject to the NVMe gate).

The `nvme` item is gated: it installs only when `server=dedi` (or auto-detection says dedicated) **and** an NVMe block device is present (`/sys/block/nvme*` or `lsblk` transport `nvme`). On a VPS/container or non-NVMe server it logs a skip and continues.

### Domains (`--domain DOMAIN [DOMAIN...] [app=TYPE]`)

A standalone action that does **not** require `--basic`. It requires Angie and MariaDB to be installed and MariaDB to be running. For each domain it creates:

| Artifact | Example for `google.com` |
|---|---|
| Document root | `/var/www/google.com/public/` (owned by `www-data`, mode 755) |
| Angie vhost | `/etc/angie/conf.d/google.com.conf` (mode 644) |
| MariaDB database | `google_com` (`utf8mb4` / `utf8mb4_general_ci`) |
| Self-signed certificate | `/etc/angie/ssl/google.com/{fullchain.pem,privkey.pem}` when `app=` is not `blank` |

```bash
# Blank vhost + database (original behaviour)
sudo bash setup.sh --domain google.com
sudo bash setup.sh --domain google.com example.org my-site.example.com

# Ready-to-use application vhosts
sudo bash setup.sh --domain forum.example.com app=xf
sudo bash setup.sh --domain blog.example.com app=wordpress
sudo bash setup.sh --domain files.example.com app=pingvin
sudo bash setup.sh --domain images.example.com app=chevereto
sudo bash setup.sh --domain go.example.com app=polr
sudo bash setup.sh --domain photos.example.com app=lychee
sudo bash setup.sh --domain app.example.com app=php
sudo bash setup.sh --domain node.example.com app=node
```

`app=TYPE` applies to every domain in that `--domain` group; use separate `--domain ... app=...` groups for different apps. Supported values: `blank` (default), `xf`, `wordpress`, `pingvin`, `chevereto`, `polr`, `lychee`, `php`, `node`.

- `xf`, `wordpress`, `pingvin`, `chevereto` and `polr` use the templates from `server-configs-nginx` (the repo is the single source of truth). `lychee` and `php` use a Laravel/front-controller vhost. `node` proxies to `127.0.0.1:3000` and adds a WebSocket location.
- The vhost is tested with `angie -t` before it is kept; a broken generated config is moved to `/tmp` (never deleted) and the script fails loudly.
- The certificate is self-signed and valid for the domain and `www.` name. Replace it with ACME/Let's Encrypt (Angie has `http_acme` built in) for production.
- App code is **not** downloaded. The script provisions the vhost, certificate, document root and database; install the application itself (Composer, WP-CLI, Node, etc.) on top.
- Domain names are lowercased and validated as hostnames. A trailing dot is removed.
- Dots become underscores and hyphens become underscores in the database name: `my-site.example.com` → `my_site_example_com`.
- The database name must be at most 64 characters.
- Re-running is idempotent. An existing non-empty Angie config file is **not overwritten** (so your vhost content is preserved); an empty placeholder is upgraded. An existing database is left as-is.
- `--domain` can be combined with a normal install, e.g. `--basic ... --angie --mariadb ... --domain google.com app=wordpress`; the domain step runs after Angie and MariaDB.
- There is no domain purge target. Remove the directory, Angie config/certificate and database manually if needed.

---

## Optimize an existing server (Ubuntu 22.04, 24.04 or 26.04)

```bash
# Tune the OS and every installed service in place
sudo bash setup.sh --optimize

# Show what would be detected and changed, without touching anything
bash setup.sh --optimize --dry-run
```

`--optimize` never installs, purges or starts a managed service, and it never
creates, resizes or disables swap. The only packages it may add are the small
`cpufrequtils` helper when the CPU exposes frequency scaling and
`angie-module-brotli` when Angie is installed, so the compression profile
matches a fresh `--angie` install. On hosts built
by releases before 1.8.34 it also repairs the legacy log permissions and cron
paths: the nightly blanket `chown -R /var/www/`, the old
`/etc/nginx/scripts/cloudflare.sh` path and the old `/usr/bin/mysqlcheck`
entry are replaced by the managed, log-safe block, and `/var/www/logs` is
restored to `root:root 755` with per-service ownership. `/var/www` and
`/var/www/mysql_database` are reset to root ownership when the legacy cron
left them web-owned.

It also reconciles the logging and connection profile on old hosts:

- MariaDB gets `slow_query_log=1`, `long_query_time=1`,
  `min_examined_row_limit=100`, `log_slow_verbosity=query_plan,explain` and a
  managed `log_error` under `/var/www/logs/mariadb/` (with a restart when the
  drop-in changes).
- Elasticsearch’s `http.host`/`transport.host` are commented so `network.host`
  controls the bind, and a non-loopback bind with X-Pack security disabled is
  reported. The endpoint used for data/heap/readiness/replica probes follows
  the effective `http.host`/`network.host` and `http.port`, so a public IPv4
  intentionally used by a remote client is supported. If only that remote
  address is reachable (the host itself is blocked by firewall/NAT), the
  active unit and listener are reported instead of a false rollback.
- The shared `snippets/fastcgi-php.conf` is repaired so PATH_INFO capture is
  optional. Without that, a bare `/index.php` can leave
  `$fastcgi_script_name` empty, pass the document root to PHP-FPM, and make
  every pretty URL return PHP-FPM’s “Access denied” (403). The WordPress and
  Polr includes also gain `index index.php index.html;` when an old vhost
  lacked it.
- Redis and Valkey get a local Unix socket (`/run/redis/redis.sock` or
  `/run/valkey/valkey.sock`), `unixsocketperm 770`, `www-data` in the service
  group, and printed XenForo/WordPress/Laravel snippets. Application config is
  not edited.
- A heap-only operator `jvm.options` is moved to `/tmp` so the managed
  `zz-setup-optimize.options` owns the heap; a richer operator file is kept and
  the override is reported.

It applies the OS profile first (CPU governor, PAM limits, hardware-scaled
kernel/network/memory sysctls) and then looks for:

- `angie` + `/etc/angie/angie.conf`
- every `/etc/php/<version>/fpm` tree
- MariaDB + `/etc/mysql`
- Valkey + `/etc/valkey/valkey.conf`, or Redis + `/etc/redis/redis.conf` when Valkey is absent
- Elasticsearch + `/etc/elasticsearch/elasticsearch.yml`

The OS profile is the same one used by a fresh `--basic` install: performance
CPU governor (when the host exposes cpufreq), the 1M-nofile PAM limits, and
the hardware-scaled sysctl set (socket buffers, backlogs, conntrack, file
descriptors, `vm.min_free_kbytes`, BBR/fq). It is idempotent and safe to run
on a live server. Swap remains exactly as the operator configured it.

It then applies the same hardware-aware service values used by a normal
install: Angie
workers/connections/buffers/cache sizes, PHP-FPM `static` pool sizing, MariaDB
buffer pool/connection backlog, Valkey/Redis maxmemory, and Elasticsearch
heap. Redis receives the same cache profile when Valkey is absent. A live
cache is never shrunk below its working set, and a raised `maxmemory` is capped
at 80% of RAM with an explicit report when the data does not fit. It also applies the installer's systemd `LimitNOFILE` drop-ins for
Angie/PHP-FPM/MariaDB, raises `vm.max_map_count` for Elasticsearch, preserves
an explicit Valkey `io_threads` value, and disables caching/stale serving of
5xx responses in the WordPress and XenForo FastCGI caches. The Angie cache
budget is shared only across the cache types that are
actually present, so a dedicated proxy with one cache type gets the whole
budget. The share also scales with installed services: Angie-only uses 50%
of RAM / 10% of free disk, Angie+PHP only 30%, Valkey-only 50%, and the
shared profile 25%/5% capped at 64 GB. When PHP is absent, MariaDB receives
the full fixed budget (no PHP worker reservation), though its data+5% target
still prevents over-allocation. MariaDB's pool and Elasticsearch's heap are sized to the live
data/index store plus 5%, bounded by the shared budget after reserving the
other services; MariaDB additionally keeps a 1/16-RAM floor (capped at 8 GB)
so a freshly installed database cannot collapse a large host to a 256 MB
pool. A 40%-of-RAM (MariaDB) or 25%-of-RAM (Elasticsearch)
fallback is used only when the data size cannot be measured. Oversized live
allocations are reduced to the data-sized target. Elasticsearch keeps its
31 GB compressed-oops ceiling. PHP listeners are preserved: Angie is
repointed only when the pool
already owns a Unix socket, so a live TCP pool is never broken by a
configuration change. The in-place TCP-to-Unix migration is opt-in with
`SETUP_OPTIMIZE_MIGRATE_PHP_SOCKET=1`; the default is off because some
PHP-FPM builds (PHP 8.5 was observed) do not open the new listener on reload
and can leave Angie without a live upstream during the cutover. Service allocations
are planned together from one 80%-of-RAM budget, with PHP worker capacity
reserved first, so MariaDB + PHP + cache + Elasticsearch cannot collectively
exhaust memory. Each configuration is
validated and active services are restarted only when their generated files
actually changed; a failure rolls back the affected service from
`/tmp/setup-optimize.*`. Before a MariaDB restart, `--optimize` stops Angie
and every active PHP-FPM version, runs `systemctl daemon-reload`, restarts
MariaDB, waits for `SELECT 1`, then starts PHP-FPM first and Angie last. This
prevents a reconnect storm while InnoDB preloads a larger buffer pool. The
pause/resume is skipped when the buffer pool is resized online or the restart
is deferred. The final verification checks each service's
real listener (Angie via `ss`, PHP socket/TCP) plus SQL/PING/HTTP probes and
lists recent error-level journal entries. The Markdown report is written to
`/var/log/setup-optimize-<timestamp>.md` and copied to
`/var/log/setup-optimize-latest.md`.

Older Angie installs whose `http.d` files use underscore names
(`fastcgi_cache_conf`, `limit_req_conf`, …) are tuned in place as well.

When WordPress vhosts are detected, `--optimize` deploys the Angie
repository's guest FastCGI cache templates and includes them in
`h5bp/php_wp.conf`. Only anonymous GET/HEAD responses are cached; logged-in,
POST/PUT/DELETE/PATCH, authorization, admin/login/REST/XML-RPC, feeds,
previews, cart/checkout/account and shop-session requests bypass the cache.
The report and the `X-Cache-Status` header show cache behavior.

On a single-node Elasticsearch cluster, yellow health caused solely by
unassigned replicas is corrected automatically: replicas are set to zero on
existing indices and a low-priority template keeps new indices green.
Multi-node clusters and unassigned primary shards are left unchanged.

---

## Diagnostics (`--diagnostics`)

```bash
sudo bash setup.sh --diagnostics
# writes ./diagnostics.log beside setup.sh
```

`--diagnostics` is read-only and requires root for service logs. It writes one
mode-600 file. Common credential forms (`pass=`, `--dbpass=`,
`IDENTIFIED BY '...'`, `MYSQL_PWD`, `REDISCLI_AUTH`) are redacted before the
file is written. It covers:

- hardware, CPU topology, memory, disks, filesystems, mounts, swap and limits
- network addresses, routes, sockets, DNS, qdisc and `ethtool` statistics
- kernel sysctls, sysctl/limits/modules-load drop-ins
- systemd units, failed units, timers, unit files and service limits
- Angie version/config test/loaded config/vhosts/certificate dates, including
  vhost certificates outside `/etc/angie/ssl`, and `http.d` ACTIVE/INACTIVE
  include status
- every PHP-FPM version, pool/ini files, processes and listeners, and the
  slow/error log paths actually configured in the pool
- MariaDB variables/status/processlist/InnoDB status/database sizes, resolved
  `log_error`/slow-log paths, and `mariadb.conf.d` files
- Valkey and Redis INFO/CONFIG/CLIENT LIST/SLOWLOG/MEMORY/LATENCY, selected
  persistence/socket/bind settings, and the configured logfile; a host with
  neither service reports “not installed” instead of connection errors
- Elasticsearch health, nodes, indices, JVM/OS/thread-pool stats, allocation
  explain (only when shards are unassigned) and resolved log files; a host
  without Elasticsearch reports “not installed” and skips the live probes
- Node.js version, processes, listeners and units
- journal warnings, per-service logs, kernel OOM/hung-task reports, dmesg
- PHP-FPM slow log, MariaDB slow log, Angie/PHP/Valkey/ES/Node logs, including
  paths outside `/var/www/logs`
- `/var/www`, `/var/www/logs`, `/var/www/logs/*` and
  `/var/www/mysql_database` ownership and permissions
- UFW, SSH effective config, cron, upgradable packages and setup state

Use `--diagnostics --dry-run` to print the destination without writing.

---

## Restart all (`--restart-all`)

```bash
sudo bash setup.sh --restart-all
sudo bash setup.sh --restart-all --dry-run
```

This is a controlled whole-stack restart, not a configuration change. It
detects installed services from their configuration paths and active units,
repairs legacy `/var/www/logs`, `/var/www` and `/var/www/mysql_database`
ownership first (so a service cannot fail to reopen its logs), then:

1. `systemctl daemon-reload`
2. stop Angie if active
3. stop every active `php*-fpm.service`
4. restart active Valkey/Redis (`valkey-server`, `valkey` or `redis-server`)
5. restart active Elasticsearch and wait for its HTTP endpoint, up to 300 seconds
6. restart active MariaDB
7. wait for `SELECT 1`, up to 300 seconds
8. start the PHP-FPM versions that were stopped
9. start Angie again if it was stopped

Only services that were **active** are stopped and restarted. Installed but
inactive units are reported and skipped. If MariaDB or a dependency fails, the
script still restores the previously active web tiers where possible and exits
non-zero with the failure list. `--dry-run` prints the detected/active units
and the planned order without changing anything.

---

## Idempotency

The script is safe to re-run:

- APT operations are no-ops when packages are already current.
- `/swapfile` is reused if it already has the requested size.
- Auto swap is a no-op once total swap is at least 50% of RAM.
- Managed blocks in `crontab`, `50-server.cnf`, `elasticsearch.yml` and `valkey.conf` are replaced, not duplicated.
- A `--basic`-only re-run regenerates the managed cron entries for services that are still installed and configured by this script, even when the managed block was removed (for example by `--purge basic`); stale entries for removed services are dropped.
- Package-origin markers are retained for diagnostics, but `--purge` no longer removes any package regardless of origin.
- Package repositories and embedded keys are verified against their payloads and refreshed when they differ.
- Domain directories and databases use idempotent creation; existing Angie domain configs are preserved.
- PHP, MariaDB, Angie, Valkey and Elasticsearch services are restarted after configuration changes so changed parameters take effect. Angie and PHP-FPM use a graceful `reload` when possible, Valkey applies runtime values with `CONFIG SET`, and startup-only changes are deferred; a repeat `--optimize` run with unchanged files restarts nothing.

A second run is normally much faster than the first (typically under a minute for the full stack).

---

## Purge / stop

```bash
# Everything this script manages (no packages are removed)
sudo bash setup.sh --purge all

# Selected services only
sudo bash setup.sh --purge --angie
sudo bash setup.sh --purge --mariadb
sudo bash setup.sh --purge --valkey
sudo bash setup.sh --purge --elastic
sudo bash setup.sh --purge --others
sudo bash setup.sh --purge --php ver=8.5
sudo bash setup.sh --purge --angie --php ver=8.5
sudo bash setup.sh --purge php mariadb      # bare service names also work

# Basic settings only (restores hostname/timezone/DNS/sysctl/limits/cron/UFW;
# swap is intentionally left enabled)
sudo bash setup.sh --purge basic

# No targets = everything
sudo bash setup.sh --purge
```

- `--purge --php ver=8.5` stops one version; `--purge php` discovers and stops every installed PHP-FPM version (not just 8.x).
- **Nothing is uninstalled or deleted.** Package purge/autoremove/clean calls were removed. `--purge` stops/disables the selected services, removes the managed and legacy cron entries, restores recorded basic settings where the original existed, and leaves packages, repositories, keys, configuration, certificates, databases, caches and logs on disk.
- `--purge all` runs every stop/restore step in a safe order.
- Bare targets and service flags are combined, so `--purge basic --php` stops both.
- `--purge others` only disables the managed cron/setup entries it knows about; optional packages, Node.js and repository files are left installed. Composer, fail2ban and unattended-upgrades are no longer installed by this script; if present from an older release, remove them manually.
- `--purge angie` stops Angie and leaves `/etc/angie` (including domain vhosts and certificates), cache directories under `/home` and logs intact.
- `--purge valkey` stops Valkey and leaves the Unix socket, systemd drop-in, group membership, configuration and data intact.
- `--purge basic` restores files recorded in `/var/lib/setup.sh/backup` by overwriting them (never by unlinking the live path), moves generated drop-ins that did not exist before to `/tmp` (DNS, PAM limits, sysctl, modules-load, logrotate, network oneshot), leaves `/swapfile` and its `/etc/fstab` line enabled, removes the managed and legacy cron entries, restores the original UFW default policies and pre-existing SSH allow rules, and disables UFW again if it was originally inactive. If no original SSH rule existed, the limit rule is kept as a lockout guard.
- **MariaDB data is never removed.** Database files under `/var/lib/mysql` and `/var/lib/mariadb`, configuration and backups stay in place after `--purge mariadb`.
- There is no `--purge domain` target. Domain vhosts, certificates, `/var/www/<domain>/` and databases stay in place under this policy; remove them manually only after verifying they are unused.

---

## Timing summary

At the end of every install run the script prints:

```
Installation summary
SERVICE    STATUS   TIME (HH:MM:SS)
-------    ------   --------------
basic      OK       00:00:19
angie      OK       00:00:13
php        OK       00:00:30
mariadb    OK       00:00:16
valkey     OK       00:00:08
elastic    OK       00:01:00
others     OK       00:00:22
domain     OK       00:00:00
TOTAL               00:02:48

All installations completed successfully.
```

If any service fails, it is marked `FAILED`, the remaining services still run, and the script exits 1 after printing the summary.

---

## Embedded and downloaded payloads

Embedded in `setup.sh` for offline/reproducible installation:

- `dns_servers.conf`
- `sysctl.conf`
- `limits.conf`
- `mysqltuner.pl` 2.9.3
- The `mysqlbackup` utility (`install`, `mysqlbkup.sh`, sample config and sample CNF)
- Angie, Elasticsearch and NodeSource signing keys
- The Sury `debsuryorg-archive-keyring` .deb

The large payloads remain embedded to preserve a single-file, offline-capable
installer. They are verified by the test suite; a future split can move them
under `payloads/` without changing the runtime interface.

Downloaded at install time (single source of truth):

- Angie configuration from [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx): `angie.conf`, `h5bp/`, `conf.d/`, `http.d/`, `snippets/`, `scripts/cloudflare.sh`, `scripts/limit_nofile.conf`, `scripts/etc_default_nginx`, and `scripts/nginx_conf.sh`.
- Cloudflare IP ranges from Cloudflare.
- Package repositories via APT.

PHP-FPM pool and `php.ini` templates are **not** downloaded from the Angie
repository; they live in `configs/php/` here. To change Angie behavior, update
`server-configs-nginx` and re-run the install. Use
`CONFIG_SOURCE_DIR=/path/to/checkout` to test a local Angie checkout before
pushing.

---

## Tested combinations

The script was tested on Ubuntu 26.04.1 LTS (16 CPU threads, 32 GB installed RAM / 27 GiB usable) with the following real install/re-run/purge cycles (v1.5.0):

| Case | Configuration | Result |
|---|---|---|
| Basic only (VPS) | `--basic server=vps host=test-vps time=UTC swap=512M` | PASS |
| Basic auto | `--basic` with no `server=`, `host=` or `swap=` (dedi + `16c-32g-1T` + swap to 50% RAM) | PASS |
| Angie + PHP 8.5 | `--basic ... --angie --php ver=8.5` | PASS |
| PHP default | `--php` with no `ver=` (auto-selected latest stable, 8.5) | PASS |
| MariaDB only | `--basic ... --mariadb user=tester pass='t3st&p\|w' size=2gb bind=127.0.0.1` | PASS |
| MariaDB multi-bind | `bind=127.0.0.1,127.0.0.2` (and whitespace/duplicates) writes and listens on both addresses | PASS |
| MariaDB `IPV4` bind | `bind=127.0.0.1,IPV4` resolves the public address (or warns/falls back to the local outbound IPv4 on NAT) | PASS |
| PHP 8.4 only | `--basic ... --php ver=8.4` | PASS |
| PHP 8.4 → 8.5 switch | second version rejected before packages are installed; purge 8.4, then install 8.5 | PASS |
| Everything except Elasticsearch | basic + Angie + PHP 8.5 + MariaDB + Valkey + all others | PASS |
| Elasticsearch only | `--basic ... --elastic host=localhost ram=2g` | PASS |
| Everything except PHP | basic + Angie + MariaDB + Valkey + Elasticsearch + gif | PASS |
| Everything | all service groups | PASS |
| NVMe gating | `--others nvme` installs on dedi + NVMe; skipped on vps or non-NVMe | PASS |
| Domain only | `--domain google.com` creates `/var/www/google.com/public/`, blank `/etc/angie/conf.d/google.com.conf`, database `google_com` | PASS |
| Multiple domains | `--domain google.com example.org my-site.test.com` → `google_com`, `example_org`, `my_site_test_com` | PASS |
| Domain idempotency | re-run preserves existing vhost config; database creation is idempotent | PASS |
| Domain app vhosts | `app=blank,xf,wordpress,pingvin,chevereto,polr,lychee,php,node` created; every generated vhost passed `angie -t` | PASS |
| Domain validation | invalid/traversal domains rejected; `--purge --domain` rejected | PASS |
| App templates | all 16 repository templates pass `angie -t` after the repair pass | PASS |
| Auto MariaDB size | `size=auto` → 11.1 GB buffer pool on this host (40% of RAM) | PASS |
| Valkey options | `ram=`, `policy=`, `io_threads=` accepted and written without duplicates | PASS |
| PHP overrides | `children=` / `max_requests=` accepted and applied | PASS |
| Purge modes | `--purge`, `--purge all`, `--purge basic`, per-service, versioned PHP, mixed bare targets + flags | PASS |
| Purge PHP + Composer | `--purge --php` does not pull old PHP/Apache providers; Composer is removed first | PASS |
| Full purge + fresh install | `--purge all` followed by a complete reinstall from scratch | PASS |
| Cron idempotency | repeated full/basic runs keep exactly one managed block; `--purge basic` removes it but keeps operator-owned lines | PASS |
| Pre-existing packages | `--purge others` leaves every optional package installed (nothing is removed); safe after state deletion and repeated purges | PASS (current behavior) |
| MariaDB TCP login | admin user works via socket and TCP `127.0.0.1` with `skip_name_resolve=1` | PASS |
| Valkey hardening | loopback bind, `protected-mode yes`, no duplicate managed directives | PASS |
| Elasticsearch hardening | `bootstrap.memory_lock: true`, `LimitMEMLOCK=infinity`, heap ≤ 50% RAM warning | PASS |

### Brotli results (XenForo 2.3.13, 16-thread host)

| Page | Identity | gzip 5 | Brotli 5 | Brotli vs gzip |
|---|---:|---:|---:|---:|
| Guest forum index | 41,657 B | 9,658 B | **8,768 B** | -9.2% |
| Logged-in index | 51,463 B | 10,589 B | **9,787 B** | -7.6% |
| Logged-in thread (20 posts) | 210,507 B | 18,825 B | **15,911 B** | -15.5% |

On a fixed 34 KB page, Brotli level 4 served 19.4k responses/s (8.49 KiB),
level 5 16.4k/s (7.81 KiB), level 9 13.4k/s (7.73 KiB), and levels 10/11
collapsed to ~1k/~0.4k responses/s. Level 5 is the default: the logged-in
origin is PHP-bound (~1k req/s), so the smaller payload is worth more than the
compression CPU. Static asset precompression is intentionally omitted because
a CDN serves those after the first origin request.

Also checked at CLI level (all using `--dry-run`, no system changes):

- `tests/test-dry-run-matrix.sh` covers 85 cases: every service flag, every
  domain app type, per-domain and trailing group `app=` forms, every purge
  mode, `--optimize` and representative invalid inputs.

- `tests/test-tuning.sh` covers 276 checks: Angie directive rewriting, the
  multi-line `proxy_cache_path` fix, insertion anchors, miss reporting,
  PHP pool editing/deduplication, the shared memory budget, UFW SSH
  rate-limiting, and a second-run no-op check.

- All 64 combinations of the six install service flags (`angie`, `php`, `mariadb`, `valkey`, `elastic`, `others`) plus `--basic` parse and validate.
- All 128 bare purge target subsets (including empty/implicit/explicit `all`) parse and validate.
- 237 parser/validation checks passed in total, including invalid server type, hostname, timezone, swap size, PHP version/children, MariaDB size/bind, Valkey RAM/policy/io_threads, Elasticsearch RAM/host, unknown `--others`, invalid domains/apps, missing values, invalid combinations, `--help` and `--version`.
- `--dry-run` was verified to make no changes as a normal user.

### Stress test (this machine)

A local site (`stress.invalid`) exercises Angie → PHP-FPM → MariaDB + Valkey + Elasticsearch + Node.js + GifSicle. The repeatable harness is in `tests/stress-site/`; it used `wrk`, `valkey-benchmark`, `pidstat` and the Angie/PHP-FPM status endpoints on 16 CPU threads, 27 GiB RAM, NVMe.

| Target | Concurrency | Result (v1.5.0) |
|---|---|---|
| Static file (Angie) | 100 | ~255k req/s, p99 3.4 ms |
| PHP hello (OPcache) | 100 | ~116k req/s |
| MariaDB primary-key read via PHP | 100 | ~27k req/s, p99 ~7.5 ms |
| Valkey endpoint (Unix socket) | 100 | ~29k req/s, p99 ~4 ms typical |
| Valkey direct `set`/`get`/`incr` | 100 | ~300k ops/s, p50 ~0.15 ms |
| Elasticsearch search via PHP | 50 | ~15.8k req/s, p99 6.3 ms |
| Node.js proxy (4 workers) | 100 | ~27k req/s |
| Full stack, uncached | 200 | ~6.6–7.1k req/s, p50 ~15 ms |
| Full stack, FastCGI-cached 5 s | 200 | ~180k req/s, p99 3.2 ms |
| Deliberate 1 s PHP sleep | 200 | ~99 req/s; the 108-worker pool saturates and queues |

Findings and the adjustments applied:

- **The hidden first bottleneck was rate limiting, not the stack.** `limit_req` applied 30 GET/s per IP to every PHP location. Local load tests (and any site behind a CDN/proxy without `real_ip`) saw connection resets at ~33 req/s. Loopback is now exempt, external limits are 100 GET/s and 30 POST/HEAD/s with larger bursts, and rejects use `429` instead of `444`.
- **PHP worker occupancy sets the uncached ceiling.** The heavy page does four sequential local lookups; 108 workers × ~15 ms ≈ 6–7k req/s. Raising the pool to 160 gave only ~6.6k req/s and more queueing, so the auto formula stays at 108 for this host.
- **Caching is the real large-site fix.** Caching the same page for 5 seconds raised throughput from ~6.8k to ~180k req/s. Angie's FastCGI cache zones are now enabled, and the XenForo/Chevereto templates use them.
- **Valkey I/O threads hurt small web commands.** 8 I/O threads used 430% CPU and reduced full-page throughput; 1 thread used 64% CPU and raised it. The default is now `io_threads=1`.
- **Ephemeral-port/TIME_WAIT pressure caused p99 tails.** At 15k new TCP connections/s the host had 83k TIME_WAIT sockets against a 55k port range. MariaDB and Valkey now use Unix sockets (PHP defaults to them), raising MariaDB to ~27k req/s and Valkey to ~29k req/s with much lower p99.
- **MariaDB thread pool fixed connection-churn tails.** `thread_handling=pool-of-threads` cut short-query p99 from ~745 ms to ~9 ms without reducing throughput.
- **Angie memory was oversized.** 300k connections/worker cost ~2 GB RSS. 65k/worker keeps ~1M total connection capacity at ~0.5 GB RSS.
- **Template and snippet fixes.** Angie does not ship `snippets/fastcgi-php.conf`; without it every PHP vhost failed `angie -t`. `PATH_TRANSLATED` also had to point at the script, not the document root. All 18 repository templates now pass.
- Remaining ceiling is application work per request (DB + cache + search). For higher full-stack throughput, add FastCGI microcaching, avoid doing all lookups on every request, use persistent/Unix-socket connections, and scale horizontally (CDN, multiple Angie/PHP nodes, separate ES/DB hosts).

---

## Security and production checklist (large sites)

The script produces a working, internet-facing baseline. For a large or security-sensitive site, review these items:

**TLS / Angie**
- Replace the self-signed per-domain certificates under `/etc/angie/ssl/<domain>/` (or the embedded default certificate) with real certificates (Angie ACME/Let's Encrypt or your CA). The default TLS policy is balanced TLS 1.2/1.3; use a stricter policy if your clients allow it.
- `access_log off` is set globally and no vhost writes access logs by default. If you need forensics, rate-limit tuning or fail2ban web jails, add a buffered per-vhost log (`access_log ... buffer=64k flush=5s;`); use logrotate/shipping so it cannot fill the disk.
- Rate limiting and FastCGI cache zones are now enabled, with loopback exempt. For a site behind Cloudflare or another proxy, configure `real_ip` (`/etc/angie/scripts/cloudflare.sh`) first, otherwise every visitor shares the proxy IP and the per-IP limiter will throttle them.
- Add HTTP/3 (QUIC) if clients support it (`listen 443 quic`, `Alt-Svc`, and `ufw allow 443/udp`). Dynamic Brotli is installed and enabled by `--angie`/`--optimize`; gzip remains the fallback. Static assets are best cached at the CDN rather than precompressed on the origin.
- Keep `client_max_body_size` and PHP upload limits aligned (both 100 MB now). Put Cloudflare or another CDN in front of static traffic and keep the daily Cloudflare real-IP refresh enabled.

**PHP**
- `disable_functions` blocks `show_source,phpinfo` by default. For applications that do not need process execution, add `system,passthru,exec,shell_exec,proc_open,popen,pcntl_exec`. Chevereto video processing and some WordPress plugins may need `exec`/`shell_exec`, so test per application.
- Use `open_basedir` per vhost/pool, especially for multi-tenant hosting. The default pool is shared by every domain.
- Session hardening is opt-in (`sudo SETUP_PHP_SESSION_HARDENING=1 ./setup.sh --optimize`) and off by default. The global overrides (`use_strict_mode`, cookies only, `HttpOnly`, `SameSite=Lax`, `cookie_secure=1`, 48-character IDs) broke Joomla/Polr logins on mixed hosts. Enable it only after testing every application, and set `session.cookie_secure=0` for an HTTP-only test vhost.
- For production, set `opcache.validate_timestamps=0` and reload PHP-FPM on deploy to avoid per-request stat calls. Keep `expose_php=Off`.
- `memory_limit` is auto-sized to 256–512 MB. Lower it per application where possible; the worker count assumes ~96 MB average, and worst-case memory must still fit in RAM.
- Do not run untrusted PHP code as the same `www-data` user across unrelated sites; use separate pools/users per tenant.
- Prefer Unix sockets for local MariaDB/Valkey and keep them on loopback. The script sets the PHP socket defaults and adds `www-data` to the `valkey` group.

**MariaDB**
- The setup admin user gets `GRANT ALL ... WITH GRANT OPTION`. Create per-application users limited to their own database and remove `GRANT OPTION`; never use the admin account in application config.
- `innodb_flush_log_at_trx_commit=2` survives a database crash but can lose the last second of commits on an OS/power failure. Use `1` for financial or otherwise critical data.
- Keep `bind-address=127.0.0.1` unless you really need remote access; if remote, use explicit addresses (or `IPV4`), enable TLS, open 3306 only for trusted source IPs in UFW, and create per-client accounts. `skip_name_resolve=1` is good for latency.
- The thread pool (`thread_handling=pool-of-threads`) is tuned for many short web queries. If you run long analytical queries, test or use a separate reporting replica.
- `secure_file_priv` and `local_infile=0` limit file import/export paths. Use the slow query log (enabled at 1 s) to find missing indexes; `log_slow_verbosity` includes query plans.
- Test the embedded `mysqlbkup` job and store encrypted, off-site copies. A local backup on the same NVMe is not disaster recovery. Enable binary logs if you need point-in-time recovery (adds I/O).
- Run `/root/mysqltuner.pl` after the site has real traffic and review slow queries; add indexes rather than raising buffers blindly. Consider a read replica or separate database host at scale.

**Valkey**
- Loopback bind, `protected-mode yes` and the Unix socket are safe for a single host. For remote Valkey, enable ACL users and TLS; do not expose 6379.
- `save ""` makes it a pure cache. If you store sessions, queues or locks, enable AOF and use a no-eviction policy for that data (or a separate instance).
- `allkeys-lru` can evict sessions; use `volatile-lru` with TTLs or a dedicated instance for persistent data. Monitor `evicted_keys` and `used_memory`.
- Keep `io_threads=1` for ordinary small commands; benchmark before raising it. Use the Unix socket from PHP to avoid TIME_WAIT/port pressure.
- Valkey 9 supports ACLs; create a restricted user for each app instead of sharing the default user if multiple apps use the same instance.

**Elasticsearch**
- X-Pack security is disabled and the default bind is `localhost`. For any non-loopback host, enable `xpack.security.enabled`, TLS, and authentication; never expose 9200/9300 directly to the internet.
- Keep `vm.max_map_count=1048576`, the 4 GB locked heap here, and monitor JVM GC, thread-pool rejections and disk watermark. For large indexes, add replicas/shards and consider a dedicated search node.
- Back up with snapshots to an external repository; Elasticsearch data is not covered by the MariaDB backup.

**Host / operations**
- Use SSH keys only, disable password login, keep UFW limited to 22/80/443, and use a brute-force tool of your choice for SSH and web auth endpoints. `--basic` rate-limits every effective SSH port with `ufw limit`; `fail2ban` is not installed by this script.
- Remove the mDNS (`5353/udp`) and WS-Discovery (`3702/udp`) UFW rules if you do not need them; they were pre-existing on this host, not added by the script.
- Enable `unattended-upgrades` manually if you want automatic security patches, and monitor reboot-required. Keep the kernel/firmware updated. `libgd3` is currently held back by the apt phasing/upgrade policy; review it before the next PHP/GD upgrade.
- Ship Angie access/error logs, PHP-FPM slow log, MariaDB slow query log, Elasticsearch and Valkey metrics to a central monitor; alert on 5xx rate, p99 latency, disk, memory and queue depth. `--others sysstat` provides `sar`/`iostat`/`pidstat` history.
- Load-test after every application or config change. The local `tests/stress-site/` harness is a starting point; tune `pm.max_children`, MariaDB buffers and Elasticsearch heap from measured RSS/CPU, not guesswork.
- For very large traffic, scale horizontally: CDN for static, multiple Angie/PHP nodes behind a load balancer, MariaDB read replicas, and a separate Elasticsearch cluster. A single 16-core host tops out around the measured full-stack numbers above.
- Keep the `stress.invalid` site and its `/etc/hosts` entry only on test machines; remove it from production.

---

## Troubleshooting

### “Another PHP-FPM version is active”

Another PHP-FPM version is already running. Purge it first:

```bash
sudo bash setup.sh --purge --php ver=8.4
```

Then install the desired version. Only one PHP-FPM version can own `/run/php/php-fpm.sock`.

### “Installation of system tables failed” on MariaDB

This is the Ubuntu 26.04 MariaDB AppArmor profile issue. The script adds the required capabilities to `/etc/apparmor.d/local/mariadbd` before installing and removes a stale loaded profile on re-installs. If you interrupted a previous install, purge MariaDB and run the install again:

```bash
sudo bash setup.sh --purge --mariadb
sudo bash setup.sh --basic ... --mariadb ...
```

### `smartd could not be enabled`

The package is installed, but `smartd` may refuse to start on machines with no SMART-capable disks (common on VMs/desktops). This is a warning, not an installation failure; `smartctl` is still available.

### `--purge others` and pre-existing packages

`--purge others` no longer removes any package, repository or key. It only stops the managed optional services and leaves Node.js, `smartmontools`, `nvme-cli`, `gifsicle` and `sysstat` installed. Remove them manually with APT only after confirming nothing needs them. If a host still has fail2ban, unattended-upgrades or Composer from an older release, remove them manually; this script no longer manages them.

### `--purge --php`

PHP purge stops the selected PHP-FPM versions and leaves their packages and configuration in place. Re-running `--php` reuses that installation. If Composer was installed manually or by an older release, it is left in place too; remove it manually if it is no longer needed.

### Rate limiting returns 429 on a site behind Cloudflare / a proxy

The per-IP limiter keys on the direct client address. If all traffic arrives through a CDN or reverse proxy, enable the real-IP configuration for that proxy first (`/etc/angie/scripts/cloudflare.sh` for Cloudflare) and include `cloudflare.conf` in the vhost. Loopback is always exempt. Tune `limit_req` rates in `/etc/angie/http.d/limit_req.conf` and the bursts in `/etc/angie/h5bp/limit_req/*.conf`.

### PHP-FPM slow log fills with queued requests

`request_slowlog_timeout=10s` measures from accept, so a full listen queue can log requests that are simply waiting for a worker. Check `/fpm-status.php` (if enabled) for `listen queue`/`max listen queue` and add workers, cache the endpoint, or reduce upstream latency. A slow log entry is not automatically a bug in that script. The status path must end in `.php` when the pool sets `security.limit_extensions = .php`.

### Angie logs “upstream prematurely closed connection” during a load test

PHP-FPM worker recycling at `pm.max_requests` closes FastCGI keepalive connections, and Angie logs this when a worker exits between requests. A PHP-FPM reload or restart during traffic produces a burst of the same message. For a benchmark, set `pm.max_requests = 0` (or a much higher value) and reload FPM; for production, keep a finite limit and treat occasional entries as expected. The stress harness sets `pm.max_requests = 0` automatically.

### `--domain` says Angie or MariaDB is missing

`--domain` only creates the directory, vhost file and database. It does not install the stack. Install Angie and MariaDB first, or combine them:

```bash
sudo bash setup.sh --basic ... --angie --mariadb user=demo pass=temp size=4gb --domain google.com
```

### Elasticsearch is reachable only on localhost

By default `--elastic host=localhost` binds to loopback and security is disabled, matching the original instructions. Do not expose port 9200 to the internet without re-enabling X-Pack security and TLS.

---

## Files and state

| Path | Purpose |
|---|---|
| `diagnostics.log` | Generated by `--diagnostics` beside `setup.sh` |
| `CHANGELOG.md` | Historical release notes |
| `/run/setup.sh.lock` | Real-run serialization lock |
| `/tmp/setup-optimize.*` | `--optimize` rollback backups |
| `/var/lib/setup.sh/backup/` | Original basic files saved before `--basic` changes |
| `/var/lib/setup.sh/original-hostname`, `original-timezone` | Values restored by `--purge basic` |
| `/var/lib/setup.sh/ufw-*` | UFW active state, added rules, pre-existing rules and default policies used by purge |
| `/var/lib/setup.sh/swapfile-managed` | Marker: the script created/resized `/swapfile` |
| `/var/lib/setup.sh/setup-installed-pkg-*`, `preexisting-pkg-*` | Package-origin markers used by `--purge others` |
| `/etc/angie/` | Angie configuration tree |
| `/etc/angie/http.d/*.conf` | Repo-managed cache zones, rate limiting, WebSocket/proxy and referer maps (deployed from `server-configs-nginx`) |
| `/etc/angie/http.d/limit_req*.conf` | Per-IP limiter zones and loopback exemption |
| `/etc/angie/snippets/fastcgi-php.conf` | Repo-provided Ubuntu-compatible FastCGI snippet (not shipped by Angie) |
| `/etc/angie/conf.d/<domain>.conf` | Blank or app vhost created by `--domain` |
| `/etc/angie/ssl/<domain>/` | Per-domain self-signed certificate (replace with ACME/Let's Encrypt) |
| `/var/www/<domain>/public/` | Document root created by `--domain` (owned by `www-data`) |
| MariaDB `<domain_with_underscores>` | Database created by `--domain` |
| `/home/nginx_cache*`, `/home/xf_proxy_cache`, `/home/proxy_cache*` | Angie FastCGI/proxy cache directories (owned by `www-data`) |
| `/etc/php/<version>/` | PHP-FPM configuration |
| `/var/cache/php/opcache` | OPcache file cache (owned by `www-data`) |
| `/var/www/logs/php/php-fpm-slow.log` | PHP-FPM slow-request log |
| `/etc/systemd/system/php<ver>-fpm.service.d/limits.conf` | PHP-FPM nofile drop-in |
| `/etc/mysql/mariadb.conf.d/50-server.cnf` | MariaDB managed block |
| `/etc/valkey/valkey.conf`, `/run/valkey/valkey.sock` | Valkey settings and local Unix socket |
| `/etc/systemd/system/valkey-server.service.d/limits.conf` | Valkey nofile drop-in |
| `/etc/elasticsearch/` | Elasticsearch configuration, JVM options and scripts |
| `/etc/systemd/system/elasticsearch.service.d/limits.conf` | Elasticsearch memlock/nofile drop-in |
| `/root/mysqltuner.pl` | Embedded MySQL Tuner |
| `/root/tools/mysqlbackup-master/` | Embedded mysqlbackup utility |
| `/usr/local/bin/mysqlbkup.sh` | Installed backup script |
| `/etc/mysqlbkup.cnf`, `/etc/mysqlbkup.config` | Backup credentials/config (mode 600) |

---

## Notes

- The script is intentionally server-oriented. Running `--basic` changes the hostname, DNS resolver, kernel sysctls, security limits, firewall and timezone. Test it on a disposable server or VM first.
- An auto-generated hostname uses logical CPU threads, nominal installed RAM (DMI when available) and the sum of physical disks: `8c-32g-1T` = 8 threads, 32 GB RAM, 1 TB. Supply `host=` to override it.
- Auto swap only acts when the current total swap is zero or below 50% of RAM; it sizes `/swapfile` so the total reaches 50% of RAM. Supply `swap=` for an exact size.
- `--domain` creates the directory, Angie vhost (blank or `app=TYPE`), certificate and database. It does not install the application code, Angie or MariaDB, and does not purge them.
- `--purge basic` restores the recorded originals by overwriting them, but a reboot is the cleanest way to reset all runtime kernel tunables. No file is deleted.
- The script never stores credentials in the repository. MariaDB credentials are written only to `/etc/mysqlbkup.cnf` on the target server (mode 600).
- `--dry-run` / `--check` is safe as a normal user and makes no changes; use it to validate a command before running it.
- Package-origin markers in `/var/lib/setup.sh` are kept for diagnostics. Purge no longer removes software regardless of origin, so deleting that directory does not change file-safety behavior.
- Package versions follow the upstream repositories at install time. Angie/PHP configuration follows the current `server-configs-nginx` branch at install time; other embedded payloads are fixed snapshots.
- Set `CONFIG_SOURCE_DIR=/path/to/server-configs-nginx` to use a local checkout (for testing or offline installs), `CONFIG_REPO_REF=<branch|tag>` to choose a branch/tag, or `CONFIG_REPO_URL=<url>` for a fork.
