# Ubuntu Setup Script

A single, idempotent Bash provisioning script for **Ubuntu 26.04 LTS** (and newer LTS releases such as 28.04). It installs and configures a complete web/database stack from one command, embeds all previously manual downloaded files, and can uninstall everything again with a `--purge` mode.

The script is designed for a fresh server but is safe to re-run on an already configured machine. Only the services named on the command line are touched.

---

## Requirements

- Ubuntu 26.04 LTS or newer (the script checks `ID=ubuntu` and `VERSION_ID >= 26.04`).
- Root access (`sudo bash setup.sh ...`).
- Internet access to the Ubuntu, Angie, Sury, Elastic and NodeSource package repositories.
- Enough disk/RAM for the selected services:
  - Elasticsearch: roughly 1.5 GB of disk plus the requested JVM heap.
  - MariaDB: the requested InnoDB buffer pool plus normal database growth.
  - PHP: a few hundred MB, plus one static FPM worker per `pm.max_children` slot.

---

## Quick start

```bash
sudo bash setup.sh \
  --basic server=dedi host=custom.host time=Asia/Manila swap=8G \
  --angie \
  --php ver=8.5 \
  --mariadb user=dan pass=temp size=4gb bind=127.0.0.1 \
  --valkey \
  --elastic host=localhost ram=4g \
  --others smartmon nvme gif nodejs
```

If a service flag is omitted, that service is **not** installed. `--basic` is required for every install run, but its `server`, `host` and `swap` values are optional and auto-detected when omitted. `--domain` is a standalone action and does **not** require `--basic`.

```bash
# Minimal: auto-detect server, hostname and swap
sudo bash setup.sh --basic --angie --php

# Add domains after Angie + MariaDB are installed
sudo bash setup.sh --domain google.com
```

### Dry run / validation

`--dry-run` (alias `--check`) parses and validates the command, then prints the resolved install or purge plan without touching the system. It works as a normal user, which makes it safe for CI and for checking combinations:

```bash
./setup.sh --dry-run --basic server=dedi host=web1 time=Asia/Manila \
  --angie --php --mariadb user=dan pass=temp size=4gb --valkey --elastic ram=4g
./setup.sh --dry-run --purge --angie --php ver=8.5
```

---

## Basic setup (`--basic`)

`--basic` is mandatory for installs, but **all of its values are optional**:

| Option | Required | Description |
|---|---|---|
| `server=dedi\|vps` | no | `dedi` also installs `cpufrequtils` and sets the CPU governor to `performance`. `vps` skips that step. If omitted, the script detects it with `systemd-detect-virt`, DMI product data and cgroup checks. |
| `host=FQDN` | no | Hostname set with `hostnamectl`. If omitted, the script generates one from the hardware: `<threads>c-<RAM_GB>g-<storage>` (for example `8c-32g-1T` for 8 threads, 32 GB RAM and 1 TB of disks). |
| `swap=SIZE` | no | Explicit swap file size, e.g. `8G`, `2G`, `512M`. If omitted, the script only adds swap when the current total is zero **or** below 50% of RAM, and sizes it so the total becomes 50% of RAM. |
| `time=REGION/CITY` | no | Timezone; defaults to `Asia/Manila`. |

Basic performs:

1. Writes its own `/etc/systemd/resolved.conf.d/dns_servers.conf` (`8.8.8.8`, `1.1.1.1`) and restarts `systemd-resolved`. Other resolver drop-ins are left untouched.
2. Purges snapd (if present), updates Ubuntu, upgrades packages, autoremoves and cleans.
3. On a dedicated server: installs `cpufrequtils`, writes `/etc/default/cpufrequtils`, enables the service, and sets the `performance` governor. On a VPS this is skipped.
4. Installs basic tools: `wget unzip nano zip software-properties-common rsync ca-certificates curl gnupg dmidecode`.
5. Generates a hostname if one was not supplied, then sets the hostname and timezone.
6. Handles swap:
   - With `swap=SIZE`: creates/reuses `/swapfile` at exactly that size.
   - Without `swap`: computes current swap and RAM. If current swap is 0 or below 50% of RAM, it creates/resizes `/swapfile` so the **total** swap becomes 50% of RAM. If current swap is already at least 50%, it leaves the existing configuration untouched.
7. Replaces `/etc/sysctl.conf` with the tuned profile and applies it (`/etc/sysctl.d/99-sysctl.conf` symlink is added when needed).
8. Replaces `/etc/security/limits.conf` with the high `nofile` limits.
9. Installs/enables cron and writes a managed crontab block containing only the entries for the selected services:
   - Angie: daily `chown` of `/var/www`, daily `chmod +x` and execution of `/etc/angie/scripts/cloudflare.sh`.
   - MariaDB: daily 03:03 mysql backup and monthly `mariadb-check`.
10. Configures UFW: deny incoming, allow outgoing, limit 22, allow 80 and 443, enable the firewall. The original active state, added rules and default policies are recorded so `--purge basic` can restore them.

Before changing basic settings, the script records the originals under `/var/lib/setup.sh/backup`. `--purge basic` restores them. A swap file is only removed by purge if the script actually created or resized it (`/var/lib/setup.sh/swapfile-managed`).

---

## Services

### Angie (`--angie`)

- Installs the Angie signing key and APT repository.
- Installs `angie` and deploys the embedded `server-configs-nginx` config tree to `/etc/angie`.
- Applies the systemd `LimitNOFILE=524288` drop-in and `/etc/default/angie`.
- Aligns `client_max_body_size` with PHP (100 MB) and adds a managed `open_file_cache` override for static-heavy sites.
- Generates `/etc/angie/http.d/cloudflare.conf` from the current Cloudflare IPv4/IPv6 ranges and reloads Angie.
- Runs `angie -t` before reloading.

### PHP (`--php [ver=8.5]`)

- Adds the Sury APT repository (keyring embedded in the script).
- If `ver=` is omitted, selects the **latest stable PHP** available to APT from the Sury repository (currently 8.5; pre-release packages such as `8.6.0~rc3` are ignored).
- Installs `php<ver>-fpm`, `php<ver>-cli` and the `mysql`, `gd`, `curl`, `xml`, `zip`, `gmp`, `mbstring`, `redis` extensions with `--no-install-recommends`.
- Deploys `www.conf` and `custom_dan.ini`, then computes:
  - `pm.max_children = RAM_MB / 256` (~50% of RAM at 128 MB per worker), capped at `CPU threads × 8`
  - `pm.max_requests = CPU threads × 1024`
- Sets the PHP timezone from `--basic time=`.
- Enables and restarts `php<ver>-fpm` and prints `php -v`.

**PHP version policy:** the pool listens on `127.0.0.1:9000`, and the Angie `local_php` upstream also points to `127.0.0.1:9000`. Therefore **only one PHP-FPM version can be active at a time**. You can install any version Sury provides (`ver=8.3`, `ver=8.4`, `ver=8.5`, ...), but to switch versions you must purge the old one first:

```bash
sudo bash setup.sh --purge --php ver=8.4
sudo bash setup.sh --basic ... --php ver=8.5
```

Installing a second version while the first is active is refused **before any packages are installed**, with a clear message instead of a cryptic “Address already in use”. Running multiple PHP-FPM pools simultaneously would require different `listen` ports and a matching Angie upstream per version; that is not automated.

### MariaDB (`--mariadb user=... pass=... size=... [bind=...]`)

- Installs `mariadb-server` and `mariadb-client`.
- Adds a systemd `LimitNOFILE=524288` drop-in.
- Writes a managed `[mariadbd]` block into `/etc/mysql/mariadb.conf.d/50-server.cnf`:
  - `max_connections = CPU threads × 25` (clamped to 100–500)
  - `innodb_buffer_pool_size = size`
  - `innodb_log_file_size = size / 4`
  - `innodb_log_buffer_size = 64M`
  - `innodb_flush_log_at_trx_commit = 2` (durable across server crash; use `1` if every committed transaction must survive an OS crash)
  - `innodb_snapshot_isolation = 1` (standard MVCC isolation)
  - `innodb_read_io_threads` / `innodb_write_io_threads = CPU threads`
  - 1M join/read buffers, 2M sort buffer, 64M temp tables, 4000 table/open-file caches
  - `bind-address` from `bind=` (default `127.0.0.1`)
- Comments out `expire_logs_days`.
- Creates the requested admin user with `GRANT ALL ... WITH GRANT OPTION` for `localhost`, `127.0.0.1` and `::1` (idempotent `CREATE USER IF NOT EXISTS` + `ALTER USER`). The extra loopback hosts are required because `skip_name_resolve=1` means a TCP connection to `127.0.0.1` does **not** match `'user'@'localhost'`.
- Creates `/var/log/mariadb`, sets ownership, reloads systemd and restarts MariaDB.
- Downloads nothing at runtime: `mysqltuner.pl` and the `mysqlbackup` repository are embedded. It installs `mysqltuner.pl` to `/root/mysqltuner.pl`, installs the backup utility under `/root/tools/mysqlbackup-master`, and writes `/etc/mysqlbkup.cnf` with the requested user/password.
- Verifies `mysqldump` and `mariadb-check` are present.

**Multiple bind addresses / remote access:** `bind=` accepts a comma-separated list of IPv4 addresses, `::1`, and the special token `IPV4`:

```bash
# Listen on loopback and a specific interface
sudo bash setup.sh --basic ... --mariadb user=dan pass=temp size=4gb \
  bind=127.0.0.1,10.0.0.5

# Listen on loopback plus the detected public IPv4
sudo bash setup.sh --basic ... --mariadb user=dan pass=temp size=4gb \
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

### Valkey (`--valkey`)

- Purges any existing `redis-server`, cleans apt, installs `valkey-server`.
- Replaces the managed directives in `/etc/valkey/valkey.conf` (no duplicates):
  - `supervised systemd`
  - `save ""` (cache-only; enable AOF/RDB if you store sessions or queues)
  - `maxmemory <10% of RAM>` (minimum 256 MB, maximum 8 GB)
  - `maxmemory-policy allkeys-lru`
  - `maxmemory-samples 10`
  - `bind 127.0.0.1 -::1`
  - `protected-mode yes`
- Enables/restarts `valkey-server` and verifies `valkey-cli ping` returns `PONG`.

### Elasticsearch (`--elastic [host=localhost] ram=4g`)

- Installs the Elastic 9.x APT repository and signing key (embedded).
- Installs `elasticsearch`.
- Writes a managed block to `/etc/elasticsearch/elasticsearch.yml`:
  - `cluster.name: essearch`
  - `network.host` from `host=` (default `localhost`)
  - `http.port: 9200`
  - `bootstrap.memory_lock: true` (the systemd drop-in sets `LimitMEMLOCK=infinity`)
  - `indices.query.bool.max_clause_count: 4096`
  - `discovery.type: single-node`
  - disables `xpack.security.enabled` and `xpack.security.enrollment.enabled`
  - comments out `cluster.initial_master_nodes`
  - comments out the package’s `http.host`/`transport.host` so `network.host` actually controls the bind address
- Writes `/etc/elasticsearch/jvm.options.d/jvm.options` with `-Xms<ram>`, `-Xmx<ram>` and `-Dlog4j2.formatMsgNoLookups=true`.
- Writes `/etc/systemd/system/elasticsearch.service.d/limits.conf` with `LimitMEMLOCK=infinity` and `LimitNOFILE=65535`.
- Writes `/etc/elasticsearch/scripts/xf-date-weighted.groovy`.
- Sets `vm.max_map_count=1048576` (persisted in `/etc/sysctl.d/99-elasticsearch.conf`).
- Enables/restarts Elasticsearch and waits for the HTTP endpoint to become ready.

With security disabled, keep `host=localhost` unless you really intend to expose port 9200. The script warns when a non-loopback `host=` is used; enable X-Pack security/TLS and a firewall before exposing it. The heap is also checked against 50% of RAM and a warning is printed if it is too large.

### Other packages (`--others ...`)

Available names: `smartmon`, `nvme`, `gif`, `nodejs`, or `all`.

| Name | Installs |
|---|---|
| `smartmon` | `smartmontools` (and tries to enable `smartd`) |
| `nvme` | `nvme-cli` — **only when the server is dedicated and the storage is actually NVMe**; otherwise skipped |
| `gif` | `gifsicle` |
| `nodejs` | NodeSource 26.x repository/key (embedded) and `nodejs` |

The `nvme` item is gated: it installs only when `server=dedi` (or auto-detection says dedicated) **and** an NVMe block device is present (`/sys/block/nvme*` or `lsblk` transport `nvme`). On a VPS/container or non-NVMe server it logs a skip and continues.

### Domains (`--domain DOMAIN [DOMAIN...]`)

A standalone action that does **not** require `--basic`. It requires Angie and MariaDB to be installed and MariaDB to be running. For each domain it creates:

| Artifact | Example for `google.com` |
|---|---|
| Document root | `/var/www/google.com/public/` (owned by `www-data`, mode 755) |
| Angie vhost | `/etc/angie/conf.d/google.com.conf` (empty, mode 644) |
| MariaDB database | `google_com` (`utf8mb4` / `utf8mb4_general_ci`) |

```bash
sudo bash setup.sh --domain google.com
sudo bash setup.sh --domain google.com example.org my-site.example.com
```

- Domain names are lowercased and validated as hostnames. A trailing dot is removed.
- Dots become underscores and hyphens become underscores in the database name: `my-site.example.com` → `my_site_example_com`.
- The database name must be at most 64 characters.
- Re-running is idempotent. An existing Angie config file is **not overwritten** (so your vhost content is preserved); an existing database is left as-is.
- `--domain` can be combined with a normal install, e.g. `--basic ... --angie --mariadb ... --domain google.com`; the domain step runs after Angie and MariaDB.
- There is no domain purge target. Remove the directory, Angie config and database manually if needed.

---

## Idempotency

The script is safe to re-run:

- APT operations are no-ops when packages are already current.
- `/swapfile` is reused if it already has the requested size.
- Auto swap is a no-op once total swap is at least 50% of RAM.
- Managed blocks in `crontab`, `50-server.cnf`, `elasticsearch.yml` and `valkey.conf` are replaced, not duplicated.
- A `--basic`-only re-run keeps the managed cron entries of services that are still installed; stale entries for removed services are dropped.
- Package-origin markers prevent `--purge others` from removing packages that existed before setup.sh, even after a previous purge removed the state directory.
- Package repositories and keys are re-written only when missing.
- Domain directories and databases use idempotent creation; existing Angie domain configs are preserved.
- PHP, MariaDB, Angie, Valkey and Elasticsearch services are restarted after configuration changes so changed parameters take effect.

A second run is normally much faster than the first (typically under a minute for the full stack).

---

## Purge / uninstall

```bash
# Everything this script installed (packages that pre-existed are kept)
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

# Basic settings only (restores hostname/timezone/DNS/sysctl/limits/swap/cron/UFW)
sudo bash setup.sh --purge basic

# No targets = everything
sudo bash setup.sh --purge
```

- `--purge --php ver=8.5` purges one version; `--purge php` purges all installed PHP 8.x versions.
- Bare targets and service flags are combined, so `--purge basic --php` purges both.
- `--purge others` removes `smartmontools`, `nvme-cli`, `gifsicle` and Node.js **only when setup.sh installed them**. Packages and the NodeSource repository/key that already existed are preserved, using `/var/lib/setup.sh/setup-installed-pkg-*` and `preexisting-pkg-*` markers. This makes repeated purges safe even after `--purge basic` removed the rest of the state directory.
- `--purge basic` restores the files recorded in `/var/lib/setup.sh/backup`, removes a `/swapfile` that the script created/resized (and its `/etc/fstab` line), removes the managed cron block while keeping operator-owned cron lines, deletes the UFW rules it added, restores the original UFW default policies, and disables UFW again if it was originally inactive. Pre-existing swap is left untouched if the script did not manage it.
- Service purge removes packages, service units, configuration directories and runtime data created by the service. **MariaDB purge removes `/var/lib/mariadb` (the database data).** Back up your databases first.
- There is no `--purge domain` target. `--purge angie` removes `/etc/angie/` (including domain vhosts), `--purge mariadb` removes the databases, and `/var/www/<domain>/` is left in place. Remove those manually if needed.

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

## Embedded payloads

The following are embedded so the script does not depend on GitHub/vendor file downloads at run time:

- `dns_servers.conf`
- `sysctl.conf`
- `limits.conf`
- A snapshot of `droplinxuser/server-configs-nginx` (commit `5331e5e`, identical to the current local clone), including `angie.conf`, `h5bp/`, `conf.d/`, `http.d/`, `mime.types`, `install_angie.sh`, `nginx_conf.sh`, `www_85.conf`, `custom_dan.ini`, `cloudflare.sh`, `limit_nofile.conf` and `etc_default_nginx`
- `mysqltuner.pl` 2.9.3
- The `mysqlbackup` utility (`install`, `mysqlbkup.sh`, sample config and sample CNF)
- Angie, Elasticsearch and NodeSource signing keys
- The Sury `debsuryorg-archive-keyring` .deb

Cloudflare IP ranges are fetched live from Cloudflare at install time. Package repositories are fetched live by APT.

---

## Tested combinations

The script was tested on Ubuntu 26.04.1 LTS (16 CPU threads, 32 GB installed RAM / 27 GiB usable) with the following real install/re-run/purge cycles:

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
| Domain validation | invalid/traversal domains rejected; `--purge --domain` rejected | PASS |
| Purge modes | `--purge`, `--purge all`, `--purge basic`, per-service, versioned PHP, mixed bare targets + flags | PASS |
| Cron idempotency | repeated full/basic runs keep exactly one managed block; `--purge basic` removes it but keeps operator-owned lines | PASS |
| Pre-existing packages | `--purge others` kept a pre-installed `smartmontools`, removed only script-installed packages; safe after state deletion and repeated purges | PASS |
| MariaDB TCP login | admin user works via socket and TCP `127.0.0.1` with `skip_name_resolve=1` | PASS |
| Valkey hardening | loopback bind, `protected-mode yes`, no duplicate managed directives | PASS |
| Elasticsearch hardening | `bootstrap.memory_lock: true`, `LimitMEMLOCK=infinity`, heap ≤ 50% RAM warning | PASS |

Also checked at CLI level (all using `--dry-run`, no system changes):

- All 128 combinations of the seven optional install flags (`angie`, `php`, `mariadb`, `valkey`, `elastic`, `others`, `domain`) parse and validate.
- All 127 non-empty bare purge target subsets plus implicit/explicit `all`, and all 127 non-empty `--purge --service` flag subsets parse and validate.
- 407 parser/validation checks passed in total, including invalid server type, hostname, timezone, swap size, PHP version, MariaDB size/bind, Elasticsearch RAM/host, unknown `--others`, invalid domains, missing values, invalid combinations, `--help` and `--version`.
- `--dry-run` was verified to make no changes as a normal user.

### Stress test (this machine)

A local site (`stress.test`) exercised Angie → PHP-FPM → MariaDB/Valkey/Elasticsearch. Tests used `wrk`, `sysbench`, `valkey-benchmark`, `ab` and `pidstat`/`vmstat` on 16 CPU threads, 27 GiB RAM, NVMe.

| Target | Concurrency | Result |
|---|---|---|
| Static file (Angie) | 200 | ~360–410k req/s, p99 < 2 ms |
| PHP hello | 200 | ~145–155k req/s |
| MariaDB primary-key read via PHP | 100 | ~27k req/s, p99 ~6–7 ms |
| MariaDB `sysbench oltp_read_only` direct | 16 threads | ~11.9k TPS / ~190k QPS, 95th percentile 1.5 ms |
| Valkey direct `set`/`get` | 100 | ~133k / ~150k ops/s, p50 ~0.65 ms |
| Elasticsearch direct `_search` | 100 | ~77–79k req/s, p99 < 9 ms |
| Full stack via PHP | 100 | ~9–11k req/s (warm ~10.5k), p99 15–40 ms |
| Full stack via PHP | 400 | ~10–10.6k req/s, p99 ~17 ms |

Findings and the adjustments applied:

- The old 54-worker PHP-FPM pool kept throughput but produced ~1 s tail latency at 100 concurrent requests. Increasing the static pool to 108 (the new formula) preserved throughput and reduced p99 to ~15 ms.
- The full stack is CPU-bound (PHP + Elasticsearch + MariaDB + Valkey), not limited by one service. Elasticsearch thread pools reported zero rejections and MariaDB/Valkey reported no connection or eviction errors.
- MariaDB's old 2 GB InnoDB log buffer and 4M/2M/4M per-connection buffers were oversized; they were reduced to 64M and 1M/1M/2M. `innodb_flush_log_at_trx_commit` was changed from unsafe `0` to `2`, and snapshot isolation restored to `1`.
- Valkey now caches ~10% of RAM (2.7 GB here) instead of a fixed 1 GB, stays on loopback with `protected-mode yes`, and no longer accumulates duplicate directives.
- Elasticsearch heap is now memory-locked (4 GB), and Angie gained `open_file_cache` plus a 100 MB body limit aligned with PHP. Static throughput improved about 10%.
- Remaining ceiling is application work per request (DB + cache + search). For higher full-stack throughput, add Angie FastCGI microcaching for cacheable pages, avoid doing all three lookups on every request, and scale CPU cores or split Elasticsearch onto another node.

---

## Security and production checklist (large sites)

The script produces a working, internet-facing baseline. For a large or security-sensitive site, review these items:

**TLS / Angie**
- Replace `h5bp/tls/certificate.pem` and `private.key` with real certificates (ACME/Let's Encrypt or your CA). The default TLS policy is balanced TLS 1.2/1.3; use a stricter policy if your clients allow it.
- `access_log off` is set globally for performance. Enable a buffered access log per vhost (as the stress-test vhost does) if you need forensics, rate-limit tuning or fail2ban integration. Angie's package logrotate handles rotation.
- The embedded tree ships optional rate-limit, Naxsi/WAF and FastCGI-cache configs but does not enable them. For large traffic, enable per-route rate limits, a WAF, and FastCGI microcaching for anonymous/cacheable pages.
- Add HTTP/3 (QUIC) and Brotli if clients support them; the current config enables HTTP/2 and gzip. Keep `client_max_body_size` and PHP upload limits aligned (both 100 MB now).
- Put Cloudflare or another CDN in front of static traffic and keep the daily Cloudflare real-IP refresh enabled.

**PHP**
- `disable_functions` currently blocks `show_source,system,passthru,allow_url_fopen`. Add `exec,shell_exec,proc_open,popen,pcntl_exec` unless the application needs them; test per application.
- Consider `open_basedir` per vhost, `session.cookie_secure=1`, `session.cookie_httponly=1`, and `session.cookie_samesite=Lax`.
- For production, set `opcache.validate_timestamps=0` and reload PHP-FPM on deploy to avoid per-request stat calls. Keep `expose_php=Off`.
- `memory_limit=512M` is generous. Lower it per application where possible; the static pool is sized at roughly 128 MB per worker, and worst-case 512 MB per worker must still fit in RAM.
- Do not run untrusted PHP code as the same `www-data` user across unrelated sites; use separate pools/users per tenant.

**MariaDB**
- The setup admin user gets `GRANT ALL ... WITH GRANT OPTION`. Create per-application users limited to their own database and remove `GRANT OPTION`; never use the admin account in application config.
- `innodb_flush_log_at_trx_commit=2` survives a database crash but can lose the last second of commits on an OS/power failure. Use `1` for financial or otherwise critical data.
- Keep `bind-address=127.0.0.1` unless you really need remote access; if remote, use explicit addresses (or `IPV4`), enable TLS, open 3306 only for trusted source IPs in UFW, and create per-client accounts. `skip_name_resolve=1` is good for latency.
- Test the embedded `mysqlbkup` job and store encrypted, off-site copies. A local backup on the same NVMe is not disaster recovery.
- Run `/root/mysqltuner.pl` after the site has real traffic and review slow queries; add indexes rather than raising buffers blindly. Consider a read replica or separate database host at scale.

**Valkey**
- Loopback bind and `protected-mode yes` are safe for a single host. For remote Valkey, enable ACL users and TLS; do not expose 6379.
- `save ""` makes it a pure cache. If you store sessions, queues or locks, enable AOF and use a no-eviction policy for that data (or a separate instance).
- `allkeys-lru` can evict sessions; use `volatile-lru` with TTLs or a dedicated instance for persistent data. Monitor `evicted_keys` and `used_memory`.

**Elasticsearch**
- X-Pack security is disabled and the default bind is `localhost`. For any non-loopback host, enable `xpack.security.enabled`, TLS, and authentication; never expose 9200/9300 directly to the internet.
- Keep `vm.max_map_count=1048576`, the 4 GB locked heap here, and monitor JVM GC, thread-pool rejections and disk watermark. For large indexes, add replicas/shards and consider a dedicated search node.
- Back up with snapshots to an external repository; Elasticsearch data is not covered by the MariaDB backup.

**Host / operations**
- Use SSH keys only, disable password login, keep UFW limited to 22/80/443, and add fail2ban or equivalent for SSH and web auth endpoints.
- Enable `unattended-upgrades` for security patches and monitor reboot-required. Keep the kernel/firmware updated.
- Ship Angie access/error logs, PHP-FPM slow log, MariaDB slow query log, Elasticsearch and Valkey metrics to a central monitor; alert on 5xx rate, p99 latency, disk, memory and queue depth.
- Load-test after every application or config change. The local `stress.test` site and commands in this README are a starting point; tune `pm.max_children`, MariaDB buffers and Elasticsearch heap from measured RSS/CPU, not guesswork.
- For very large traffic, scale horizontally: CDN for static, multiple Angie/PHP nodes behind a load balancer, MariaDB read replicas, and a separate Elasticsearch cluster. A single 16-core host tops out around the measured full-stack numbers above.

---

## Troubleshooting

### “Port 9000 is already in use”

Another PHP-FPM version is already running. Purge it first:

```bash
sudo bash setup.sh --purge --php ver=8.4
```

Then install the desired version. Only one PHP-FPM version can own `127.0.0.1:9000`.

### “Installation of system tables failed” on MariaDB

This is the Ubuntu 26.04 MariaDB AppArmor profile issue. The script adds the required capabilities to `/etc/apparmor.d/local/mariadbd` before installing and removes a stale loaded profile on re-installs. If you interrupted a previous install, purge MariaDB and run the install again:

```bash
sudo bash setup.sh --purge --mariadb
sudo bash setup.sh --basic ... --mariadb ...
```

### `smartd could not be enabled`

The package is installed, but `smartd` may refuse to start on machines with no SMART-capable disks (common on VMs/desktops). This is a warning, not an installation failure; `smartctl` is still available.

### `--purge others` and pre-existing packages

`--purge others` removes Node.js, `smartmontools`, `nvme-cli` and `gifsicle` only if setup.sh installed them. If they already existed, setup.sh writes a `preexisting-pkg-*` marker and purge leaves them (and the NodeSource repository/key) alone. If the state directory was deleted by an older version, the safe default is also to keep them; remove them manually with APT if desired.

### `--domain` says Angie or MariaDB is missing

`--domain` only creates the directory, vhost file and database. It does not install the stack. Install Angie and MariaDB first, or combine them:

```bash
sudo bash setup.sh --basic ... --angie --mariadb user=dan pass=temp size=4gb --domain google.com
```

### Elasticsearch is reachable only on localhost

By default `--elastic host=localhost` binds to loopback and security is disabled, matching the original instructions. Do not expose port 9200 to the internet without re-enabling X-Pack security and TLS.

---

## Files and state

| Path | Purpose |
|---|---|
| `/var/lib/setup.sh/backup/` | Original basic files saved before `--basic` changes |
| `/var/lib/setup.sh/original-hostname`, `original-timezone` | Values restored by `--purge basic` |
| `/var/lib/setup.sh/ufw-*` | UFW active state, added rules and default policies used by purge |
| `/var/lib/setup.sh/swapfile-managed` | Marker: the script created/resized `/swapfile` |
| `/var/lib/setup.sh/setup-installed-pkg-*`, `preexisting-pkg-*` | Package-origin markers used by `--purge others` |
| `/etc/angie/` | Angie configuration tree |
| `/etc/angie/http.d/99_setup_overrides.conf` | Managed `open_file_cache` override |
| `/etc/angie/conf.d/<domain>.conf` | Blank vhost file created by `--domain` |
| `/var/www/<domain>/public/` | Document root created by `--domain` (owned by `www-data`) |
| MariaDB `<domain_with_underscores>` | Database created by `--domain` |
| `/etc/php/<version>/` | PHP-FPM configuration |
| `/etc/mysql/mariadb.conf.d/50-server.cnf` | MariaDB managed block |
| `/etc/valkey/valkey.conf` | Valkey settings |
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
- `--domain` only creates the directory, blank Angie vhost and database. It does not install Angie or MariaDB and does not purge them.
- `--purge basic` restores the recorded originals, but a reboot is the cleanest way to reset all runtime kernel tunables.
- The script never stores credentials in the repository. MariaDB credentials are written only to `/etc/mysqlbkup.cnf` on the target server (mode 600).
- `--dry-run` / `--check` is safe as a normal user and makes no changes; use it to validate a command before running it.
- Package-origin markers in `/var/lib/setup.sh` let purge avoid removing software that existed before setup.sh. Do not delete that directory if you intend to purge later.
- Package versions follow the upstream repositories at install time; the embedded configuration files are a snapshot, but package repositories are always fetched live.
