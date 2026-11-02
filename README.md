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

1. Writes `/etc/systemd/resolved.conf.d/dns_servers.conf` (`8.8.8.8`, `1.1.1.1`) and restarts `systemd-resolved`.
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
10. Configures UFW: deny incoming, allow outgoing, limit 22, allow 80 and 443, enable the firewall.

Before changing basic settings, the script records the originals under `/var/lib/setup.sh/backup`. `--purge basic` restores them. A swap file is only removed by purge if the script actually created or resized it (`/var/lib/setup.sh/swapfile-managed`).

---

## Services

### Angie (`--angie`)

- Installs the Angie signing key and APT repository.
- Installs `angie` and deploys the embedded `server-configs-nginx` config tree to `/etc/angie`.
- Applies the systemd `LimitNOFILE=524288` drop-in and `/etc/default/angie`.
- Generates `/etc/angie/http.d/cloudflare.conf` from the current Cloudflare IPv4/IPv6 ranges and reloads Angie.
- Runs `angie -t` before reloading.

### PHP (`--php [ver=8.5]`)

- Adds the Sury APT repository (keyring embedded in the script).
- If `ver=` is omitted, selects the **latest stable PHP** available to APT from the Sury repository (currently 8.5; pre-release packages such as `8.6.0~rc3` are ignored).
- Installs `php<ver>-fpm`, `php<ver>-cli` and the `mysql`, `gd`, `curl`, `xml`, `zip`, `gmp`, `mbstring`, `redis` extensions with `--no-install-recommends`.
- Deploys `www.conf` and `custom_dan.ini`, then computes:
  - `pm.max_children = (25% of RAM in GB × 1024) / 128`
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
  - `max_connections = CPU threads × 50`
  - `innodb_buffer_pool_size = size`
  - `innodb_log_file_size = size / 4`
  - `innodb_read_io_threads` / `innodb_write_io_threads = CPU threads`
  - the documented buffer, cache, flush and charset settings
  - `bind-address` from `bind=` (default `127.0.0.1`)
- Comments out `expire_logs_days`.
- Creates the requested admin user with `GRANT ALL ... WITH GRANT OPTION` (idempotent `CREATE USER IF NOT EXISTS` + `ALTER USER`).
- Creates `/var/log/mariadb`, sets ownership, reloads systemd and restarts MariaDB.
- Downloads nothing at runtime: `mysqltuner.pl` and the `mysqlbackup` repository are embedded. It installs `mysqltuner.pl` to `/root/mysqltuner.pl`, installs the backup utility under `/root/tools/mysqlbackup-master`, and writes `/etc/mysqlbkup.cnf` with the requested user/password.
- Verifies `mysqldump` and `mariadb-check` are present.

The MariaDB backup cron entry is added only when MariaDB is selected.

**Ubuntu 26.04 AppArmor note:** the packaged `mariadbd` AppArmor profile omits `dac_override`/`setuid`/`setgid`, which breaks `mariadb-install-db` on re-installs. The script adds a managed capability override to `/etc/apparmor.d/local/mariadbd` and removes a stale loaded profile before reinstalling. `--purge mariadb` removes the override.

### Valkey (`--valkey`)

- Purges any existing `redis-server`, cleans apt, installs `valkey-server`.
- Appends (idempotently) to `/etc/valkey/valkey.conf`:
  - `supervised systemd`
  - `save ""`
  - `maxmemory 1024mb`
  - `maxmemory-policy allkeys-lru`
  - `maxmemory-samples 10`
  - `protected-mode no`
- Enables/restarts `valkey-server` and verifies `valkey-cli ping` returns `PONG`.

### Elasticsearch (`--elastic [host=localhost] ram=4g`)

- Installs the Elastic 9.x APT repository and signing key (embedded).
- Installs `elasticsearch`.
- Writes a managed block to `/etc/elasticsearch/elasticsearch.yml`:
  - `cluster.name: essearch`
  - `network.host` from `host=` (default `localhost`)
  - `http.port: 9200`
  - `indices.query.bool.max_clause_count: 4096`
  - `discovery.type: single-node`
  - disables `xpack.security.enabled` and `xpack.security.enrollment.enabled`
  - comments out `cluster.initial_master_nodes`
  - comments out the package’s `http.host`/`transport.host` so `network.host` actually controls the bind address
- Writes `/etc/elasticsearch/jvm.options.d/jvm.options` with `-Xms<ram>`, `-Xmx<ram>` and `-Dlog4j2.formatMsgNoLookups=true`.
- Writes `/etc/elasticsearch/scripts/xf-date-weighted.groovy`.
- Sets `vm.max_map_count=1048576` (persisted in `/etc/sysctl.d/99-elasticsearch.conf`).
- Enables/restarts Elasticsearch and waits for the HTTP endpoint to become ready.

With security disabled, keep `host=localhost` unless you really intend to expose port 9200.

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
- Package repositories and keys are re-written only when missing.
- Domain directories and databases use idempotent creation; existing Angie domain configs are preserved.
- PHP, MariaDB, Angie, Valkey and Elasticsearch services are restarted after configuration changes so changed parameters take effect.

A second run is normally much faster than the first (typically under a minute for the full stack).

---

## Purge / uninstall

```bash
# Everything this script manages (including Node.js — see the warning below)
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
- `--purge others` removes `smartmontools`, `nvme-cli`, `gifsicle` **and Node.js**. It prints a warning because Node.js may have existed before the script ran. If you want to keep Node.js, purge other services separately.
- `--purge basic` restores the files recorded in `/var/lib/setup.sh/backup`, removes a `/swapfile` that the script created/resized (and its `/etc/fstab` line), removes the managed cron block, deletes the UFW rules it added, and disables UFW again if it was originally inactive. Pre-existing swap is left untouched if the script did not manage it.
- Service purge removes packages, service units, configuration directories and runtime data created by the service. **MariaDB purge removes `/var/lib/mariadb` (the database data).** Back up your databases first.
- Domains are not purged automatically; remove `/var/www/<domain>/`, `/etc/angie/conf.d/<domain>.conf` and the database manually.

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
| Basic auto | `--basic` with no `server=`, `host=` or `swap=` (dedi + `testhost` + swap to 50% RAM) | PASS |
| Angie + PHP 8.5 | `--basic ... --angie --php ver=8.5` | PASS |
| PHP default | `--php` with no `ver=` (auto-selected latest stable, 8.5) | PASS |
| MariaDB only | `--basic ... --mariadb user=tester pass='t3st&p\|w' size=2gb bind=127.0.0.1` | PASS |
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

Also checked at CLI level:

- All 128 combinations of the seven optional install flags (`angie`, `php`, `mariadb`, `valkey`, `elastic`, `others`, `domain`) parse and validate.
- All 128 combinations of purge targets parse and validate.
- 293 parser/validation checks in total, including invalid server type, hostname, timezone, swap size, PHP version, MariaDB size/bind, Elasticsearch RAM/host, unknown `--others`, invalid domains, missing values, non-root execution, `--help` and `--version`.

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

### `--purge others` removes Node.js

This is intentional. The script prints a warning. If Node.js existed before setup, reinstall it or avoid purging `others`.

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
| `/var/lib/setup.sh/ufw-*` | UFW state used by purge |
| `/var/lib/setup.sh/swapfile-managed` | Marker: the script created/resized `/swapfile` |
| `/etc/angie/` | Angie configuration tree |
| `/etc/angie/conf.d/<domain>.conf` | Blank vhost file created by `--domain` |
| `/var/www/<domain>/public/` | Document root created by `--domain` (owned by `www-data`) |
| MariaDB `<domain_with_underscores>` | Database created by `--domain` |
| `/etc/php/<version>/` | PHP-FPM configuration |
| `/etc/mysql/mariadb.conf.d/50-server.cnf` | MariaDB managed block |
| `/etc/valkey/valkey.conf` | Valkey settings |
| `/etc/elasticsearch/` | Elasticsearch configuration, JVM options and scripts |
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
- Package versions follow the upstream repositories at install time; the embedded configuration files are a snapshot, but package repositories are always fetched live.
