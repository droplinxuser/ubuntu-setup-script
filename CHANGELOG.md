# Changelog

Historical release notes for ubuntu-setup-script. Current behavior is documented in README.md.

## What's new in 1.10.0

- **`--domain` provisions the whole site.** `db=NAME` creates the MariaDB
  database, `user=U pass=P` creates an account with `ALL PRIVILEGES` on that
  database only (localhost, 127.0.0.1 and ::1; the statements go in over
  stdin and the password is redacted in the run log), and `sql=FILE` imports
  a `.sql`, `.sql.gz`, `.xz`, `.zst` or `.bz2` dump into the still-empty
  database in bulk-load mode. Nothing is created unless it is declared: the
  automatic `<domain_with_underscores>` database is gone, and MariaDB is only
  required when `db=` is used. After an import the shared memory plan is
  rebuilt from the live data+index size and the MariaDB profile is rewritten
  and applied (online buffer-pool resize, or a restart with the web tiers
  paused), so a restored site is tuned for its data without waiting for the
  next `--optimize`.
- **Every vhost is a full template from `server-configs-nginx`
  `conf.d/templates`.** Without `app=` the basic `example.com.conf` template
  is rendered (static root, `h5bp/basic.conf`, TLS, plus the port-80
  redirect) instead of an empty file; `blank` is now an alias of `basic`.
  New apps `flarum`, `shlink` and `sfs`. All templates share one token-based
  substitution (`domain_render_vhost`), which also fixes a domain that
  contains a placeholder (`blog.example.com` used to be substituted twice).
  A self-signed certificate is generated for every domain.
- **Removed:** `--harden-ssh`, `--cloudflare-only` and the fail2ban `sshd`
  jail (and its install). The audit still reports SSH password
  authentication and public 80/443; brute-force protection and origin-only
  firewalling are the operator's or the provider's.
- Tests: `--domain` database/user/dump cases and the removed flags in the
  dry-run matrix; `normalize_app` checks replace the Cloudflare parser tests.

## What's new in 1.9.0

Install/optimize parity, shared sizing helpers and hardware-adaptive tuning,
validated on the dev-host development host (16 threads / 27 GiB / NVMe, Ubuntu
26.04.1): a fresh `--basic --angie --php --mariadb --valkey --elastic
--others all` install followed by `--optimize` now produces byte-identical
service configuration (the only pre-1.9.0 difference was the MariaDB buffer
pool, which the installer sized from stale log files in the data directory).

- **One memory plan for both paths.** `record_explicit_options` stores
  `--php children=`, `--mariadb size=`, `--valkey ram=` and `--elastic ram=`
  *before* the install plan is built, and the plan reserves explicit sizes
  verbatim (they are never scaled down), so the first `--optimize` no longer
  re-splits RAM. The install plan starts from the services already on the
  host, so adding `--php --mariadb` to an Angie host sizes the Angie cache
  like `--optimize` will. A service that is not installed yet is no longer
  measured from a previous installation's data directory, and the directory
  fallback excludes redo/undo logs and temp tablespaces.
- **Shared helpers replace copy-pasted blocks:** `service_mem_mb` (the one
  fallback formula per service), `valkey_apply_config` (base + tuning
  directives; `--optimize` now also turns off RDB saves/AOF and sets the
  managed bind/log path on an adopted Valkey or Redis), `valkey_runtime_settings`
  (the `CONFIG SET` list is derived from the file writer),
  `write_service_limits_dropin` with per-service wrappers for MariaDB, PHP-FPM
  and Valkey, `ensure_es_max_map_count`, `elasticsearch_write_managed_yaml`,
  `php_children_ceiling`/`php_children_floor`, `angie_worker_limits`,
  `mariadb_write_base_block`, `wait_for_cmd`, `dir_size_mb`. Dead code removed:
  `valkey_mb_from_config`, `es_jvm_options_is_heap_only`,
  `elasticsearch_rollback`, six inline RAM reads and two PHP unit loops.
- **Parity fixes:** `--optimize` converges the MariaDB base block
  (`skip_name_resolve`, `local_infile=0`, charset, `secure_file_priv`) on
  adopted hosts; the installer refreshes the managed crontab *after* the
  WordPress hardening so a fresh install gets the wp-cron entry; a `--php`
  only run keeps the host timezone in `custom_dan.ini`; Valkey `io_threads`
  is clamped to 1..8 on both paths; the planned Elasticsearch heap is no
  longer rounded a second time; the dry run prints the same Angie and PHP-FPM
  values the real run writes; PHP `listen.backlog`, MariaDB `back_log` and
  Valkey `tcp-backlog` are derived from the CPU formula instead of the live
  `somaxconn`, so they no longer depend on run order.
- **Hardware-adaptive rules.** RAM detection honours a cgroup memory limit
  (`mem_total_mb`), like the existing CPU quota detection. MariaDB:
  `innodb_io_capacity` by disk class *and* host type (NVMe dedicated
  10000/20000, NVMe VPS 3000/6000, SSD 4000/8000 or 1000/2000, HDD 400/800;
  `SETUP_MARIADB_IO_CAPACITY="r w"` pins a host), probed on the MariaDB data
  directory; `innodb_flush_neighbors=1` and 4 I/O threads on rotational disks,
  otherwise `clamp(cpus/2, 4, 16)` threads; `innodb_lru_scan_depth` follows
  io_capacity; `thread_cache_size = clamp(cpus*8, 32, 256)`;
  `tmp_table_size`/`max_heap_table_size = clamp(RAM/256, 32, 256) MB` capped
  at pool/8; `max_connections` follows the PHP pool (`workers*1.25+50`) with
  the CPU formula as the no-PHP fallback. PHP-FPM: 16 workers per core on
  dedicated hardware, 8 on a VPS; the 8-worker floor is reduced on hosts
  under 1.5 GB; `opcache.interned_strings_buffer` scales with the OPcache
  size. Elasticsearch: the heap is a quarter of the index store (rounded up to
  512 MB, capped at 25% of RAM and 31 GB) instead of store+20%, because the
  page cache, not the heap, serves the index; search/write thread pools no
  longer reserve 4/2 threads on a 1-2 vCPU host. Valkey: `maxclients`
  follows the PHP pool (10000 minimum). Kernel: `vm.dirty_background_bytes`
  and `vm.dirty_bytes` replace the 30%/5% ratios (64 MB..512 MB and
  256 MB..2 GB, tighter on HDD), TCP buffer maxima drop to 16 MB under 4 GB
  of RAM, a VPS gets smaller
  conntrack/backlog ceilings, and the base profile's `net.nf_conntrack_max`
  alias is removed so one key owns the value. Swap is capped at 8 GiB
  (4 GiB on a VPS) with a 1 GiB floor. The CPU governor step is skipped on a
  virtual host. New `configure_io_tuning` (install and optimize): transparent
  huge pages set to `madvise` through a oneshot unit, `fstrim.timer` enabled
  on SSD/NVMe, and a udev rule that sets the I/O scheduler and readahead per
  device class; `--purge` restores all of it. Angie: `worker_processes` is
  written from the effective CPU count (cgroup-aware) and `open_file_cache`
  scales with RAM.
- **Remote load tests no longer measure the rate limiter.** Angie's per-IP
  limit answered more than 99% of a LAN benchmark with 429 and wrote 266 MB
  of per-rejection warnings in two minutes. `limit_req_log_level` is now
  `info` (below the `warn` error_log level) and
  `SETUP_LIMIT_REQ_EXEMPT="ip,cidr,..."` adds managed geo-whitelist entries
  for a load generator or monitor and is persisted in `/etc/default/setup-tuning`
  (`LIMIT_REQ_EXEMPT`), so a later plain `--optimize` keeps it. `tests/stress-site/run-stress-remote.sh`
  drives `oha` (a single static binary) from a workstation and reports the
  status-code distribution; `tests/stress-site/collect-metrics.sh` samples
  CPU, sockets, PHP-FPM, MariaDB, Valkey, Elasticsearch and log growth on the
  server during a run.
- **XenForo guest cache key varies on encoding.** A normalised
  `$setup_cache_enc` map (gzip or plain) is appended to the XenForo FastCGI
  cache key, so a gzip-capable client primes a gzip entry that Angie serves
  without re-compressing (the identity body was Brotli-compressed on every
  hit: 41% of 16 cores at 8k req/s), and an identity client never receives
  gzip bytes. Measured XenForo guest/member results are in
  `tests/stress-site/RESULTS.md`; for a CPU-bound XenForo host a
  `--php children=3 x cores` pool halves page latency at equal throughput.
- `--mariadb size=` now defaults to `auto` (the shared plan), and
  `SETUP_STATE_DIR` overrides `/var/lib/setup.sh` so the unit tests never
  read the live host's recorded options (21 planner tests silently depended
  on it).
- The Elasticsearch loopback audit accepted only an unquoted `localhost`; the
  installer's quoted value and `::1`/`_local_` no longer trigger a false
  warning.
- Tests: 58 new tuning checks (worker ceilings/floors, VPS limits, swap caps,
  io_capacity tiers, MariaDB profile values, explicit-size pinning,
  `record_explicit_options`, `valkey_apply_config` idempotency, limits
  drop-ins, rate-limit exemptions, `dir_size_mb`, `wait_for_cmd`).

## What's new in 1.8.59

- **`--cloudflare-only` now allows the full Cloudflare ranges.** The range
  parser dropped the prefix length (`173.245.48.0/20` became the single host
  `173.245.48.0`), so the firewall admitted one address per range and blocked
  almost every Cloudflare edge. Ranges are read with their prefix by the new
  `cloudflare_ranges_from_conf` helper, which is unit-tested.
- **fail2ban cannot ban the operator running the deploy.** The managed sshd
  jail sets `ignoreip` to loopback plus the detected SSH client address, the
  jail is reloaded when fail2ban was already running, and the report only
  claims "enabled" when the service is active.
- **Secrets no longer appear in the process list.** The MariaDB admin
  password is sent to `mariadb` over stdin and written into the backup
  credentials file through the environment (`write_mysqlbkup_credentials`,
  verbatim, no sed metacharacters); the scoped WordPress database password
  reaches the wp-config helper through `WP_CFG_VALUE`.
- **The Angie APT key is scoped to the Angie repository** with `signed-by`
  (`/usr/share/keyrings/angie-signing.gpg`) instead of the global
  `trusted.gpg.d`, like the Sury, Elastic and NodeSource keys. A legacy
  globally trusted copy that is byte-identical to the embedded key is retired
  to `/tmp`.
- **The Angie tree deployer follows the file-safety policy.** Legacy files
  and macOS AppleDouble entries are moved to `/tmp` by `retire_paths` instead
  of being deleted; a test asserts the deployer contains no `rm`.
- The WordPress database split and audit only interpolate plain
  `DB_NAME`/`$table_prefix` identifiers into SQL; anything else is reported
  and skipped (wp-config.php is writable by the web user).
- `custom_dan.ini` no longer references `E_STRICT` (unused since PHP 8.0,
  deprecated constant in 8.4); the effective error level is unchanged.
- The PHP pool version rewrite handles any `phpN.N` string, not only `php8.x`,
  and the WordPress config finder uses the same depth as the managed wp-cron
  entry and the XenForo finder.
- The embedded mysqlbackup payload was re-packed without macOS AppleDouble
  entries, so installs no longer log `tar: Ignoring unknown extended header
  keyword` or extract `._*` files into `/root/tools`.
- Tooling: `tools/diff_configs.sh` skips files that are not on the host,
  keeps going after a failed download and compares every installed PHP
  version; ShellCheck is clean again at the CI warning level (`fd_limit`,
  SC2206) and the CI job now also checks the stress-site scripts.
- Tests: 21 new tuning checks (Cloudflare range parser, `retire_paths`,
  backup credentials, signed-by keyring, stdin/environment secret handling).

## What's new in 1.8.58

- **A security pass now runs on every `--basic` install and every
  `--optimize`.** It is idempotent and also works on existing WordPress trees.
  - `wp-config.php` -> `root:www-data 640`; the nightly `chown` cron no longer
    resets it to `www-data`.
  - Adds `DISALLOW_FILE_EDIT`, `DISALLOW_FILE_MODS`
    (`SETUP_WP_ALLOW_FILE_MODS=1` skips it), `DISABLE_WP_CRON`,
    `WP_DEBUG_DISPLAY=false`, `FORCE_SSL_ADMIN`; replaces placeholder salts.
  - Adds the managed `*/5` `wp-cron.php` crontab entry before disabling
    WP-Cron, so scheduled work still runs.
  - Replaces a WordPress database user that has global privileges with a
    per-site `wp_<db>` account limited to its own database. The connection is
    tested and the original credentials are restored automatically on failure
    (`SETUP_WP_DB_SPLIT=0` skips this step).
  - Quarantines known WordPress webshells (`wp-vcd.php`, `wp-tmp.php`,
    `wp-feed.php`, WP2SHELL markers and hex-named plugin directories) to
    `/var/lib/setup-quarantine/` and reports suspicious administrators,
    high-risk plugins, world-writable files and oversized archives.
    `SETUP_PURGE_MALWARE=1` deletes instead of quarantining.
  - Installs and enables `unattended-upgrades` and a fail2ban `sshd` jail from
    `--basic`; `--optimize` only enables them when they are already installed.
    MariaDB dumps are kept for 30 days and `/etc/mysqlbkup.cnf` is `root:root
    600` so the PHP user cannot read the admin password.
  - Reports SSH password authentication, public 80/443 rules and a
    non-loopback Elasticsearch before they are exploited.
  - New opt-in flags: `--harden-ssh` (keys-only; refuses without
    `/root/.ssh/authorized_keys`) and `--cloudflare-only` (80/443 allowed only
    from the published Cloudflare ranges).
- Requires the Angie configuration repository at 1.6.18 for the matching web
  server rules: dotfile/sensitive-file denies, no PHP in uploads/backups and
  `Permissions-Policy`. Access logging remains **off** by default for
  performance; `error_log` is still written.

## What's new in 1.8.57

- **No RAM is overcommitted to a data service beyond its live working set.**
  MariaDB, Valkey and Elasticsearch are now sized from measured live data with
  at most **20% headroom**:
  - MariaDB: `information_schema` data+index (or the data-directory size when
    SQL is unavailable) ×1.20, minimum 128 MB.
  - Valkey/Redis: live `used_memory` (or the RDB size when stopped) ×1.20,
    minimum 128 MB.
  - Elasticsearch: `_cluster/stats` index store (or the data-directory size)
    ×1.20, minimum 512 MB, 31 GB ceiling.
  The former `RAM/16` floors, 10/25/50% cache plans and 25/40/80% unmeasured
  fallbacks are gone; an empty service gets only its operational minimum.
  Any remaining memory stays with PHP (CPU-capped) and the OS page cache.
- Targets are still reserved before PHP and scaled proportionally if they
  cannot all fit, trimmed Elasticsearch → Valkey → MariaDB, so headroom is a
  maximum rather than a guarantee.
- On the 16-thread / 27.8 GB host with a 54 MB database, 1 MB cache and empty
  index: `PHP=9216 MariaDB=128 Cache=128 Elasticsearch=512 MB`; all services
  stay active and the forum keeps serving 200s.
- Tests: 372 tuning checks (20% targets, minima, proportional caps, and all
  seven supported service combinations) and 86 dry-run cases.

## What's new in 1.8.56

- **Live data services are funded first, then the remainder goes to the
  request tier and the OS.** `plan_memory_budget()` now builds targets in this
  order and scales them together when they cannot all fit:
  1. MariaDB: live `information_schema` data+index +5%, with the existing
     hardware floor for an empty/tiny database;
  2. Valkey/Redis: live `used_memory` +10% (or the growth percentage when the
     cache is empty);
  3. Elasticsearch: live `_cluster/stats` index store +5%, with a small floor
     for an empty index.
  PHP-FPM is sized **after** those targets from what remains (CPU-capped,
  8-worker floor), and any unallocated memory is left to the OS page cache.
  If the three targets exceed the budget, they are scaled proportionally and
  trimmed Elasticsearch first, then Valkey, then MariaDB; the report states
  when a store does not fully fit. This replaces the 1.8.55 "keep an oversized
  live pool/heap" rule: a pool/heap grossly above data+5% is reduced so the
  freed RAM can serve PHP/OS, while a value within 2% of the target is kept to
  avoid restart churn.
- The planner adapts to the installed set: MariaDB-only, MariaDB+Valkey,
  MariaDB+Elasticsearch, cache-only, search-only and full-stack hosts each
  reserve only the services that exist. Fresh install and `--optimize` use
  the same target rules, so parity is preserved.
- On the 16-thread / 27.8 GB host this produces
  `PHP=9216 MariaDB=1738 Cache=2781 Elasticsearch=2048 MB` from the live
  54 MB database, 1 MB cache and empty index; all services remain active and
  the forum keeps serving 200s.
- Tests: 358 tuning checks (priority allocation, proportional caps, floors,
  live targets, MariaDB+Valkey-only and full-stack cases) and 86 dry-run
  cases.

## What's new in 1.8.55

- **Live working sets are budgeted and never shrunk unnecessarily.**
  `--optimize` now treats a running service's current allocation as a floor
  when it already covers the live data and still fits its share of the 80%
  RAM budget:
  - MariaDB: `information_schema` data+index size +5% is the target; a live
    buffer pool at or above that target is kept while it stays under
    `db_cap`, instead of being reduced to the target and forcing a restart and
    a cold buffer pool.
  - Elasticsearch: `_cluster/stats` store size +5% is the target; a live heap
    at or above it is kept under `es_cap` for the same reason.
  - Valkey/Redis: `used_memory` is read from the live server and
    `used_memory * 1.1` becomes a floor in the planner *before* MariaDB and
    Elasticsearch are sized, so the protection in `optimize_valkey()` cannot
    overcommit the shared budget. The report prints the live working set.
  - Sizing still respects the total RAM cap: if the data does not fit, the
    pool/heap is capped at its budget share and the report says so.
- The spare-RAM top-up no longer overrides a kept live allocation.
- On the test host this keeps MariaDB at 6776 MB (54 MB live data),
  Elasticsearch at 3072 MB (0.3 MB index) and Valkey at 2781 MB (1 MB used),
  with every service reporting "configuration already optimized".
- Tests: 352 tuning checks (live pool/heap kept, Valkey floor, budget caps)
  and the existing 86 dry-run cases.

## What's new in 1.8.54

- **The `--sync-angie` CLI option is removed.** Angie synchronization is
  always part of `--optimize` (fetch -> deploy -> hardware and guest-cache
  profile), so the deprecated alias is gone: `--sync-angie` now fails with
  `Unknown argument` like any other retired flag. Internal helpers keep their
  names (`sync_angie_repo_configs()`, called by install and `--optimize`);
  only the user-facing command and its `SYNC_ANGIE` state are purged.
- Help text, README, changelog references and tests were updated. The dry-run
  matrix asserts that `--sync-angie` is rejected, and the tuning suite asserts
  that the option no longer exists in the script.

## What's new in 1.8.53

- **`--optimize` enables guest caching for WordPress _and_ XenForo.** It now
  calls a shared `ensure_fastcgi_cache_zone()` and a new
  `ensure_xf_guest_cache()` in addition to the existing WordPress cache
  repair. Detected XenForo vhosts (`h5bp/php_xf.conf`/`xf2.conf` include plus
  `src/XF.php`) get a complete FastCGI cache block when missing, and a partial
  block is completed line by line: shared `fastcgicache` zone and
  `$nocacheuri` map, GET/HEAD, style + variation + language cache key,
  session-cookie bypass, `cache_lock`, background update,
  `ignore_headers Cache-Control Expires Set-Cookie`, `200 5m` plus error
  policy, and no caching of 5xx. The cookie bypass is a managed
  `map $http_cookie $setup_xf_guest_bypass` file (session, admin, user and
  TFA-trust cookies) consumed by `fastcgi_no_cache`/`fastcgi_cache_bypass`;
  no `if` is used in any Angie location block, and a legacy direct-cookie
  bypass is converted to the map. The repair is idempotent and runs from both
  the installer and `--optimize`, so older hosts converge on the fresh
  `app=xf` behavior. WordPress now installs the zone through the same helper
  (`zz-setup-fastcgi-cache.conf`) and only creates `/home/nginx_cache` when a
  zone actually needs installing.
- **`--sync-angie` is merged into `--optimize`.** Angie synchronization was
  already part of `optimize_angie()`; the separate mode, its Angie-installed
  precondition and its usage section are gone. `--optimize` always runs
  fetch -> deploy -> hardware profile, and `--sync-angie` remains only as a
  deprecated alias that prints a warning and takes the identical path.
- Tests cover the XenForo map-based bypass, injection/idempotency, the shared
  zone helper, the installer/optimizer call sites and the deprecated alias
  (350 tuning checks, 85 dry-run cases).

## What's new in 1.8.52

- **Install and `--optimize` now leave byte-identical managed configuration.**
  On a clean Ubuntu 26.04 host (16 threads, 27.8 GB RAM, NVMe) a full-stack
  install followed by `--optimize` produced an empty diff across `/etc/angie`,
  `/etc/php`, `/etc/mysql`, `/etc/valkey`, `/etc/elasticsearch`, systemd
  drop-ins, sysctl, limits, cron and logrotate, and every service reported
  "configuration already optimized". MariaDB performance and logging
  directives now have one owner: `write_mariadb_tuning_dropin()` writes
  `99-setup-optimize.cnf` from both paths instead of the installer embedding a
  second block in `50-server.cnf`.
- **The first `--optimize` no longer shrinks a fresh MariaDB.** A newly
  initialised database reports a few MB of system tables; the planner treated
  that as a populated working set and dropped the pool from the installer's
  6776 MB to its 1738 MB floor on the test host. A database whose working set
  already fits inside the hardware floor is now treated like an empty one and
  may grow into the spare budget (up to RAM/4).
- **Explicit operator sizes survive tuning.** `--php children=`,
  `--php max_requests=`, `--mariadb size=`, `--valkey ram=` and
  `--elastic ram=` are recorded in `/var/lib/setup.sh/explicit-options.conf`
  and honoured by later `--optimize` runs. Previously the first tune replaced
  a requested 2 GB Valkey with the planner's 2.7 GB and re-derived
  `pm.max_requests`.
- **CPU and disk sizing follow the real host.** New `effective_cpus()` honours
  the cgroup v2/v1 CPU quota (a 2-vCPU container no longer receives 144 PHP
  workers and 16 MariaDB I/O threads), and `storage_backing_class()` resolves
  the device that actually backs `/var/www` instead of classifying any NVMe
  device on the host. NVMe now keeps the 4000/8000 IOPS profile; a SATA boot
  disk with an NVMe scratch disk no longer inherits it.
- **Angie's PHP upstream keepalive scales with the FPM pool.** It was
  `nproc*2` (32 on the 16-thread host) against 144 workers; it is now
  `max_children/2` (72), capped at 16..512.
- **Elasticsearch thread pools scale with the host.** Managed
  `thread_pool.search.size` (CPU/2, 4..16) and `thread_pool.write.size`
  (CPU/4, 2..8) bound the bursts that reached ten cores on a single
  match query. Throughput was unchanged (9.5k -> 9.7k req/s) while CPU
  spreading and co-tenancy improved. The base YAML block, single-node replica
  repair and index template are now applied at install time as well as by
  `--optimize`, `vm.max_map_count` is always persisted, and the Valkey
  `ReadWritePaths` drop-in is shared by both paths.
- **A live MariaDB ceiling above 2000 connections is preserved.** The 2000
  cap now applies only to the computed value, not to a kept live ceiling.
- **Swap creation checks free disk.** A 50%-of-RAM target on a small VPS no
  longer fills `/`; at least 256 MiB must remain free.
- **XenForo static assets get immutable caching.** `tune_xf_static_assets()`
  adds one idempotent 30-day `Cache-Control: public, immutable` location for
  `/js`, `/styles` and `/data`, re-applied after each Angie repository sync.
- **Install order matches `--optimize` for the WordPress cache**, and
  `purge_php_installations()` no longer trips the ERR trap when no PHP package
  is installed (the `sort -u` SIGPIPE).
- **Measured on the test host** (loopback, 8 s per scenario): static 201k
  req/s, PHP hello 122k, MariaDB 27.8k, Valkey 30.5k, Elasticsearch 9.7k,
  Node.js 30.7k, full four-service page 7.1k, guest FastCGI cache 117-121k.
  XenForo 2.3.13 with 200 threads: guest forum list 17k (compressed HTML),
  guest thread 15.5k, authenticated forum list 1.36k (+25% after disabling the
  Featured/Trending/Members-online widgets), authenticated thread 1.11k.
  Valkey-backed XF sessions/registry measured 2% slower than MariaDB on this
  single host, so DB sessions remain the default and page/session caching stay
  documented rather than enabled.

## What's new in 1.8.51

- **The Angie tree deployer is part of setup.sh and `--sync-angie` is a
  sub-command.** Sync, legacy-file cleanup, permissions, the per-host default
  certificate, `angie -t` and the reload now live in `deploy_angie_tree()`
  instead of `server-configs-nginx/scripts/nginx_conf.sh`, so a fresh install,
  `--optimize` and the new `--sync-angie` share one implementation. The
  configuration repository no longer ships an executable deployer.
- **Install and `--optimize` now reserve the same PHP budget.** A fresh
  install used to reserve 96 MB per worker and cap the pool at `threads × 16`,
  while `--optimize` measured the running workers and reserved the 64 MB
  floor. On the 16-thread / 27.8 GB test host that was 13906 MB versus
  9216 MB, so MariaDB and Elasticsearch were sized from different numbers the
  first time `--optimize` ran. The install planner now derives the worker
  count exactly like the tuner (CPU×16, 50%-of-RAM ceiling, 512 cap) and
  reserves the 64 MB measured floor; `tune_php_fpm_version()` uses that count
  directly instead of re-dividing the budget by 96. The dry-run plan reports
  the same count.
- **The search heap is rounded once, in the planner.** `--optimize` rounded
  `-Xmx` down to a 512 MB boundary but the installer did not, so the same
  budget produced 3476 MB and 3072 MB on the two paths. A kept live heap is
  still left untouched, so no restart is forced just to align it.
- **Measured on the 16-thread / 27.8 GB dev-host host** (XenForo 2.3.13 with 40
  threads and 360 replies): PHP JIT `tracing` versus `off` changed
  authenticated throughput by less than run-to-run noise (~910 vs ~900 req/s),
  MariaDB `thread_pool_size` 8/16/32/64 stayed within 3%, and
  `innodb_io_capacity` 4000 → 10000 made no difference for the read-heavy
  authenticated page. Angie's cache-hit path served ~103k req/s on loopback
  with the current 32k `worker_connections`, `ssl_buffer_size 1400` and
  Brotli level 5, and Valkey did ~118k SET/s and ~117k GET/s with
  `io-threads 1`. The existing defaults were kept because each alternative was
  equal or worse.

## What's new in 1.8.50

- **PHP worker memory is measured instead of assumed.** The shared planner
  reserved a fixed 96 MB for every PHP-FPM worker. On the 16-thread / 27.8 GB
  test host the live XenForo pool averaged 28 MB per worker (peak 51 MB), so
  `--optimize` reserved 13.9 GB for a pool that used 4 GB at full load. The
  planner now samples the running pool, adds 50% headroom to the average
  worker RSS, clamps the allowance to 64-192 MB and reserves
  `max_children × allowance`. A fresh install with no pool still uses 96 MB.
  Worker *capacity* is unchanged: `--optimize` keeps a live pool's
  `max_children` instead of deriving it from the reservation, so a heavier
  measurement cannot shrink the pool.
- **A fresh Elasticsearch index is no longer pinned to a 512 MB heap.** The
  512 MB empty-index floor was correct for a tiny VPS but under-provisioned a
  27.8 GB host that also runs MariaDB and PHP. An empty index now starts from
  `RAM/16` clamped to 512 MB-4 GB, and the spare shared budget is spent on
  Elasticsearch (up to RAM/8 on a shared host, the standard 50% heap when it
  is the only service) before MariaDB (up to RAM/4, or 50% on a DB-only host).
  Populated stores keep their data-sized targets, so the spare stays with the
  application/page cache instead of inflating a pool that already fits. On
  the 27.8 GB host the search heap moved from 512 MB to 3 GB.
- **XenForo's guest cache varies on style and language.** XenForo's own page
  cache keys on `style_id`, `style_variation`, `language_id` and cookie
  consent (`src/XF/PageCache.php`). The deployed Angie vhost keyed only on
  the style variation, so a guest who picked a non-default style or language
  could receive another guest's cached HTML. `--angie` and `--optimize` now
  add `$cookie_xf_style_id` and `$cookie_xf_language_id` to the FastCGI cache
  key and enable `fastcgi_cache_background_update`, so an expiring entry is
  refreshed in the background while `cache_lock` still collapses the
  stampede. The repair is idempotent and also covers `php_xf_proxy.conf`.
- The tuning suite grew to 319 checks, including the XenForo cache key and
  the new memory-plan floors.

## What's new in 1.8.49

- **Fresh installs no longer starve MariaDB to give Elasticsearch a
  speculative 25% of RAM.** When Elasticsearch is installed in the same run
  as MariaDB, the shared planner now treats the not-yet-created empty index as
  measured-empty (512 MB floor) instead of using the 25%-of-RAM fallback. On a
  fresh MariaDB+PHP/cache/search host, MariaDB also starts from the same
  1/16-RAM empty-database floor that `--optimize` uses, instead of the
  40%-of-RAM unmeasured fallback. A measured 27.8 GB host that previously
  planned `PHP=13906 / MariaDB=256 / Cache=2781 / Elasticsearch=5306 MB` now
  plans `PHP=13906 / MariaDB=1738 / Cache=2781 / Elasticsearch=512 MB`, so the
  first install and a later `--optimize` agree. Database-only (and
  database+cache) hosts keep the larger fallback because the database is the
  primary consumer.
- **Run logs are unique per process.** `setup_<timestamp>.log` now includes the
  PID. Two invocations started in the same second (`--version`, `--help`, a CI
  dry-run) no longer append to one file and interleave their headers.
- **A closed output pipe no longer writes a false `[ERR]` line.** `setup.sh
  --help | head` makes `tee` exit with SIGPIPE (141); the ERR trap now ignores
  that status instead of logging `command failed (exit 141)`.
- **`--restart-all --dry-run` lists the cache service once.** `valkey` is an
  alias of `valkey-server`; the plan now reports only the first active name
  instead of both.
- Tests cover the fresh-install memory floors, the database-only fallback, the
  Valkey alias de-duplication, the PID-suffixed run log and the SIGPIPE guard.

## What's new in 1.8.48

- **`--optimize` synchronizes `/etc/angie` with `server-configs-nginx` before
  tuning it.** The canonical tree is fetched from
  `https://github.com/droplinxuser/server-configs-nginx` (or
  `CONFIG_SOURCE_DIR`) and deployed with the repository's `nginx_conf.sh`.
  The hardware-aware Angie profile then runs against the freshly deployed
  files. A failed download/validation restores the previous `/etc/angie`
  tree and reports the synchronization as a failed optimize step.
- **WordPress and XenForo configs under `/var/www` are audited for persistent
  connections.** `--optimize` locates `wp-config.php` and XenForo's
  `src/config.php`, then reports whether the MariaDB host uses a persistent
  `p:` connection and whether Valkey/Redis uses the local Unix socket.
  Recommended `DB_HOST`/`WP_REDIS_PATH`/`WP_REDIS_PERSISTENT` and XenForo
  `$config['db']['host']`/`$config['cache']['config']` values are printed in
  the optimization report. The audit is read-only; the admin applies the
  changes.

## What's new in 1.8.47

- **`sysctl` no longer logs `net.ipv4.ipfrag_high_thresh: Invalid argument`.**
  The kernel rejects a new high threshold while the current low threshold is
  still above it. The tuning block writes the low mark first (with a runtime
  pre-adjustment when the live pair is inverted), so 64 GB hosts no longer
  fail that key or print the generic "One or more sysctl values could not be
  applied" warning.
- **MariaDB 11.8 no longer warns about `--log-slow-admin-statements`.** The
  deprecated alias is no longer written; MariaDB's default `log_slow_filter`
  already includes `admin`, so admin statements stay in the slow log.
  `--optimize` also strips the legacy key from an existing `50-server.cnf`.
- **The TCP-to-Unix PHP-FPM migration is mandatory.** `--optimize` always
  migrates a live TCP pool used through the shared `local_php` upstream and
  repoints Angie to the socket. The graceful reload is tried first; if the
  build does not open the new listener on SIGUSR2 (PHP 8.5 was observed),
  PHP-FPM is restarted to complete the cutover. The socket primary keeps `max_fails=1 fail_timeout=2s` so Angie
  can use the TCP backup during the reload attempt (with `max_fails=0` the
  backup was never selected). A failed migration is reported as a failed
  optimize step instead of silently leaving TCP in place.
- **Changing the Valkey/Redis socket no longer restarts PHP-FPM.** Workers
  only need a restart when `www-data` was just added to the service group;
  the socket path itself does not change their supplementary groups. This
  removes a brief `/run/php/php-fpm.sock` gap (502s) during `--optimize`.
- **Run-log headers show failed-unit names.** systemd prefixes each failed
  unit with `●`; the header now prints `logrotate.service` instead of `●`.
- **Diagnostics report an absent MariaDB as "not installed".** A host with no
  MariaDB server no longer writes `mariadb: command not found` for every live
  probe; a client-only host reports its client version and that the server is
  missing. A stale `/etc/php/<ver>/fpm` directory without a binary is reported
  as such instead of running a missing `/usr/sbin/php-fpm<ver>`.
- **`--restart-all` waits for Elasticsearch's HTTP endpoint.** The unit's
  `Type=simple` start returns before the node is ready; the web tiers are now
  started only after the endpoint answers (up to 300 seconds), so the first
  searches do not hit a recovering cluster.
- **SSH port discovery keeps the port-22 fallback on hosts without an
  `sshd_config`.** `sshd -T` can fail as a non-root user and the empty `grep`
  pipeline exited non-zero under `pipefail`/`set -e`, aborting the process
  substitution before the fallback; UFW could then miss the SSH rule in a
  container or CI environment.

## What's new in 1.8.46

- **Dynamic Brotli compression is installed and enabled by both `--angie` and
  `--optimize`.** Angie does not bundle Brotli; setup.sh installs the official
  `angie-module-brotli` package, loads it from
  `/etc/angie/modules-enabled/50-brotli.conf`, deploys
  `/etc/angie/http.d/brotli.conf` from the repository template, and pins level
  5 with gzip as the fallback. `--optimize` previously only tuned the existing
  tree, so an already-installed host kept gzip-only; it now reaches the same
  profile as a fresh install.
  - Measured on a 16-thread Ubuntu 26.04 host with XenForo 2.3.13: a 149 KB
    logged-in thread page compressed to **10.9 KB with Brotli 5** versus
    **13.7 KB with gzip 5** (-20%), and a 41 KB guest index compressed to
    **8.8 KB versus 9.7 KB** (-9%). Brotli 10/11 reduced size a little further
    but collapsed throughput from ~16k to ~1k/~0.4k responses/s, so level 5 is
    the default; `SETUP_BROTLI_LEVEL` overrides it.
  - Zstandard was evaluated and intentionally not enabled: it was 9-10% larger
    than Brotli on the same pages. Only one extra module is loaded.
  - Static assets are not precompressed. A CDN caches them, so the only origin
    hit is the first one; the meaningful work is per-request dynamic HTML.
- **`--optimize` keeps install/optimize parity for compression.** The two
  small package exceptions are documented: `cpufrequtils` and
  `angie-module-brotli`.
- **Disk-class detection ignores DVDs/loop devices and recognises virtio.**
  `storage_class` used to inspect every block device, so a QEMU DVD-ROM
  (`sr0`, `ROTA=0`) made a spinning disk look like an SSD and loop devices
  could do the same. It now considers whole `disk` devices only and treats
  virtio/pv block devices as SSD, preserving the 2000/4000 InnoDB IOPS profile
  on cloud VMs while keeping real HDDs at 400/800.
- **XenForo Redis cache caution in the optimizer report.** On a single host
  with local MariaDB, XF's Redis registry/session cache measured 0.97k req/s
  versus 1.33k req/s with MariaDB-backed sessions (+37%). The report now tells
  operators to benchmark it and reserve Redis for multi-node or remote-DB
  deployments.

## What's new in 1.8.45

- **`--optimize` repairs `PATH_TRANSLATED` in every PHP location include.**
  1.8.43 covered `php_wp.conf`, `php_polr.conf` and `php.conf`, but hosts
  using the XenForo includes (`php_xf.conf`, `php_xf_proxy.conf`) still kept
  `$document_root$fastcgi_path_info`. The optimizer now processes `php.conf`
  plus all `h5bp/php_*.conf`, so any current or future PHP include is
  normalised to `$document_root$fastcgi_script_name`.

## What's new in 1.8.44

- **Diagnostics report an absent Elasticsearch as “not installed” and skip
  its live probes.** A host without the Elasticsearch package/unit no longer
  prints five `curl: (7) Failed to connect to 127.0.0.1 port 9200` errors.
  The diagnostic checks for an `elasticsearch.service` unit, the CLI binary or
  `/usr/share/elasticsearch/bin/elasticsearch` first. When installed but
  stopped, it shows the unit status and skips the HTTP probes while still
  printing the YAML/JVM/limits/log configuration.

## What's new in 1.8.43

- **Removed the default `cgi.fix_pathinfo=0` that brought “Access denied”
  back.** 1.8.42 refreshed `custom_dan.ini` from the template, which still
  contained `cgi.fix_pathinfo = 0`. With that value PHP-FPM uses
  `PATH_TRANSLATED` instead of `SCRIPT_FILENAME` (PHP bug #68053). The
  deployed WordPress/Polr includes set
  `fastcgi_param PATH_TRANSLATED $document_root$fastcgi_path_info;`, so a
  normal `/index.php` request translated to the document root and PHP-FPM
  rejected it:
  `Access to the script '/var/www/<site>/public' has been denied`.
  `configs/php/custom_dan.ini` no longer sets `cgi.fix_pathinfo`; the opt-in
  hardening block still does, deliberately.
- **`--optimize` repairs `PATH_TRANSLATED` in the deployed PHP includes.**
  `h5bp/php_wp.conf`, `h5bp/php_polr.conf` and `h5bp/php.conf` are changed
  from `$document_root$fastcgi_path_info` to
  `$document_root$fastcgi_script_name`, matching the repository’s PHP
  location. This makes the mapping correct even if an operator later enables
  `cgi.fix_pathinfo=0`, without widening `security.limit_extensions`.
- **Upgrade action:** run `sudo ./setup.sh --optimize`. It refreshes
  `custom_dan.ini` (removing `cgi.fix_pathinfo=0`) and rewrites the
  `PATH_TRANSLATED` line in the deployed includes. No manual PHP edit is
  required.

## What's new in 1.8.42

- **`--optimize` refreshes a stale `custom_dan.ini`.** Old hosts still carry
  `memory_limit = 2048M`, `opcache.jit = off` and a WordPress
  `disable_functions` list containing `curl_exec`, `exec` and
  `shell_exec`. The managed `zz-setup-optimize.ini` overrides the limits but
  not `allow_url_fopen`/`disable_functions`, and removing the managed file
  would expose the stale 2 GB limit. Optimize now installs the current
  `configs/php/custom_dan.ini` over the old copy, preserving the host's
  existing `date.timezone`. The whole `/etc/php/<ver>` tree is backed up to
  `/tmp/setup-optimize.*` first, and the refresh is listed in the report.
- **Diagnostics no longer report absent Valkey/Redis as connection
  failures.** When neither `valkey-server` nor `redis-server` has a service
  unit, the diagnostic prints “Valkey/Redis is not installed”. If the service
  exists but is stopped, or no client can reach it, that state is reported
  once instead of six times.
- **`Elasticsearch allocation` is healthy when nothing is unassigned.**
  `_cluster/allocation/explain` returns HTTP 400 when all shards are assigned.
  The diagnostic now reads `unassigned_shards` first and prints “No
  unassigned shards; allocation explain is not needed” instead of a
  misleading error.

## What's new in 1.8.41

- **PHP session/cgi hardening is opt-in again.** 1.8.39 wrote global
  `session.use_strict_mode`, `use_only_cookies`, `cookie_httponly`,
  `cookie_secure=1`, `cookie_samesite=Lax`, 48-character session IDs and a
  bounded `gc_maxlifetime` into `zz-setup-optimize.ini`. On this mixed
  Joomla/WordPress/Polr host that made applications answer **"Access
  denied."** after `--optimize`. `--optimize` now writes only the
  performance block (limits, OPcache/JIT, realpath cache, MySQL socket
  defaults). Enable the hardening deliberately with:

  ```bash
  sudo SETUP_PHP_SESSION_HARDENING=1 ./setup.sh --optimize
  ```

  `configs/php/custom_dan.ini` no longer carries `session.*` overrides
  either, so a fresh install keeps PHP's session defaults.
- The central PHP `error_log` and `cgi.fix_pathinfo=0`/`expose_php=Off`/
  `display_errors=Off` settings moved into the same opt-in block, matching
  the recovery configuration that restored the sites. When enabling the flag,
  `setup.sh` still creates `/var/www/logs/php/php-error.log` and sets its
  ownership.

## What's new in 1.8.40

- **Pretty URLs no longer fail with PHP-FPM "Access denied".** The shared
  `snippets/fastcgi-php.conf` used
  `fastcgi_split_path_info ^(.+?\.php)(/.*)$;`, which requires a trailing
  `/...` and can leave `$fastcgi_script_name` empty for a bare `/index.php`.
  `try_files` then passed the document root to PHP-FPM, and
  `security.limit_extensions` returned 403 "Access denied" for every SEF URL.
  `--optimize` (and a fresh Angie deploy) now makes the PATH_INFO capture
  optional while keeping the existing `try_files`/`SCRIPT_FILENAME` behavior
  so PATH_INFO applications continue to work.
- **WordPress and Polr includes gain a server-level index.** Older vhosts
  using `location / { try_files ...; }` without an `index` directive resolved
  `/` to the directory instead of `index.php`. The optimizer now prepends
  `index index.php index.html;` to `h5bp/wordpress.conf` and
  `h5bp/php_polr.conf` when it is missing.

## What's new in 1.8.39

- **`--optimize` probes the Elasticsearch endpoint it actually configured.**
  It now resolves the effective HTTP address from `http.host` (when active) or
  `network.host`, honours a custom `http.port`, brackets IPv6 addresses, and
  uses that endpoint for the index-store query, live-heap query, readiness
  probe, verification and single-node replica calls. A node intentionally
  bound to a public IPv4 for a remote XenForo client no longer fails a
  hard-coded `127.0.0.1:9200` probe and rolls back. If the host cannot reach
  its own non-loopback address because of a firewall/NAT, the active unit plus
  the exact listener is reported instead of a false failure; the single-node
  replica check is skipped in that case.
- **`--diagnostics` follows the same endpoint**, so a remote-bound
  Elasticsearch is queried on its configured address instead of loopback.
- **`--optimize` upgrades PHP session/cgi hardening on old hosts.** The
  managed `zz-setup-optimize.ini` now sets strict session mode, cookies-only,
  `HttpOnly`, `Secure`, `SameSite=Lax`, `cgi.fix_pathinfo=0`,
  `display_errors=Off`, `log_errors=On` and the central
  `/var/www/logs/php/php-error.log`. Because the file sorts last, an older
  `custom_dan.ini` can no longer leave unsafe defaults in place; the file is
  created and owned before PHP-FPM is reloaded.
- **`--optimize` removes bare legacy MariaDB performance keys.** Older
  releases wrote optimizer-generated directives (for example
  `innodb_buffer_pool_size`, `innodb_log_file_size`, `tmp_table_size` and
  `max_connections`) directly into `50-server.cnf` without the managed
  markers. The optimizer now strips every optimizer-managed performance and
  logging key from that file (inside or outside the marker block) while
  preserving base settings such as `skip_name_resolve`, `open_files_limit`,
  `secure_file_priv` and `bind-address`, so `99-setup-optimize.cnf` is the
  single owner.

## What's new in 1.8.38

- **`--optimize` no longer aborts on a host with an empty root crontab.** The
  legacy-cron repair declared `backup` without initialising it, so the
  `[[ -n $backup ]]` report line failed under `set -u` with
  `backup: unbound variable` immediately after the managed crontab was
  written. `backup` is now initialised and a regression test covers the
  empty-crontab case.

## What's new in 1.8.37

- **`--optimize` repairs legacy log ownership and cron on old hosts.** It
  replaces the pre-1.8.34 nightly `chown -R www-data:www-data /var/www/`
  entry with the log-safe `find` form that prunes `/var/www/logs`,
  `/var/www/mysql_database` and `*.log`, resets `/var/www/logs` to
  `root:root 755`, restores per-service log ownership (`mysql`,
  `elasticsearch`, `valkey`/`redis`, `www-data`), and resets `/var/www` and
  `/var/www/mysql_database` to root ownership when the old cron left them
  web-owned.
- **`--restart-all` repairs log ownership first.** It runs the same
  `/var/www/logs`, `/var/www` and backup-directory repair before stopping
  services, so a restart cannot fail because a log directory is still owned
  by www-data.
- **MariaDB logging is reconciled by `--optimize`.** The generated
  `99-setup-optimize.cnf` now carries `slow_query_log`, `log_error`,
  `long_query_time=1`, `min_examined_row_limit=100` and
  `log_slow_verbosity=query_plan,explain`; the AppArmor log override is
  refreshed before the restart.
- **Elasticsearch bind and JVM handling are fixed.** Active
  `http.host`/`transport.host` keys are commented so `network.host` controls
  the bind, a non-loopback bind with X-Pack security disabled is reported,
  and a heap-only operator `jvm.options` is moved to `/tmp` so the managed
  `zz-setup-optimize.options` owns the heap. A richer operator file is kept
  and the override is reported.
- **Redis and Valkey get a local Unix socket.** `--optimize` writes
  `unixsocket`/`unixsocketperm 770`, adds `www-data` to the service group,
  restarts PHP-FPM so workers inherit it, and prints XenForo, WordPress and
  Laravel snippets. Application config is never edited.
- **A `--basic`-only run regenerates managed cron entries for installed
  services.** This restores Angie maintenance, MariaDB backups and the
  `mariadb-check` job after `--purge basic` (or after the managed block was
  removed), instead of leaving the host with no scheduled jobs.
- **The stress harness uses a working FPM status path and restores worker
  recycling.** It sets `pm.status_path = /fpm-status.php`, points the vhost
  and harness at that path, saves the original `pm.max_requests` to
  `/var/lib/stress-site/fpm-max-requests`, sets it to `0` for the test, and
  restores it from an EXIT trap in `run-stress.sh`.
- **`--diagnostics` resolves live paths and reports ownership.** It tails
  PHP/Angie/MariaDB/Redis/Elasticsearch logs from their configured paths
  (including vhost certificates and `/var/log/...`), lists Angie `http.d`
  ACTIVE/INACTIVE files, includes MariaDB config files and Redis persistence/
  socket settings, and reports `/var/www`/log/backup ownership. `last`,
  `node`, `npm`, the logrotate drop-in and the Elasticsearch allocation probe
  are guarded.
- **Cron removals report write failures.** `cron_remove_line` and
  `--purge basic` now warn when `crontab` cannot be written instead of
  silently reporting success.

## What's new in 1.8.35

- Removed `fail2ban`, `unattended-upgrades`, Composer and the `security`
  shorthand from `--others`; `--others all` now covers only the supported
  optional tools.
- SSH is rate-limited in UFW with `ufw limit <port>/tcp` for every effective
  `sshd` port, replacing a plain `allow` rule.
- APT, key, purge and tune behavior was prepared for the 1.8.36 diagnostics and
  safety changes.

## What's new in 1.8.34

- **The nightly ownership job no longer breaks service logs.** The managed
  Angie cron entry used `chown -R www-data:www-data /var/www/`, which also
  changed `/var/www/logs/mariadb`, `/var/www/logs/valkey` and
  `/var/www/logs/elasticsearch` to `www-data`. The next service start or
  restart then failed to open or rotate its logs: MariaDB logged
  `File '/var/www/logs/mariadb/slow.log' not found (Errcode: 13 "Permission
  denied")` and disabled slow logging for the process, and Valkey exited with
  status 1 because it could not open `valkey.log`. The job now walks
  `/var/www` with `find` and prunes the `/var/www/logs` tree, so each service
  keeps ownership of its own log directory. A crontab entry written by an
  older release is upgraded in place on the next `--basic` run, and
  `--purge --angie` removes both forms.

## What's new in 1.8.33

- **The run log now reports the parsed selection accurately.** The old header
  printed `Enabled: none` and `Modes: ... 0` because it ran before argument
  parsing. A new `selection` block after validation records the real modes,
  enabled services, domains and explicit MariaDB/PHP/Valkey/Elasticsearch
  options.

## What's new in 1.8.32

- **Restored the embedded signing payloads.** The Angie, Sury, Elastic and
  NodeSource key blobs had been truncated to empty functions, so a fresh server
  failed at `gzip -dc` before installing Angie or PHP (`unexpected end of
  file`). All four blobs are restored and a test now decodes every embedded
  payload so this cannot regress silently.

## What's new in 1.8.31

- **Every run writes a full diagnostic log.** `setup.sh` now mirrors its
  complete stdout/stderr into `setup_<YYYYmmdd-HHMMSS>.log` in the directory
  where it was invoked. The header records the redacted command line, user,
  working directory, OS/kernel/architecture, virtualization, CPU, memory,
  disk, addresses, failed units and enabled modes; the footer records the exit
  status, duration and log path. `--help`, `--dry-run`, install, `--optimize`
  and failed runs all write one. Password arguments are redacted.
- **Duplicate tuning blocks merged.** MariaDB now has one
  `mariadb_compute_profile` / `mariadb_performance_settings` pair used by both
  the installer and `--optimize`; Elasticsearch shares one managed performance
  block and one systemd limits file; Valkey shares one list of tuning
  directives. This removes drift between fresh installs and later tunes while
  preserving the existing zero-downtime/rollback behavior.
- **Only the log is outside `/tmp`.** All scratch/config-test/backup paths
  remain under `/tmp` and are left for the OS to expire; no permanent deletion
  code was added. The test matrix now runs each invocation from `/tmp` so its
  logs do not accumulate in the checkout.
- **Install and `--optimize` parity maintained.** Both paths still call the
  same OS profile and the same 80%-of-RAM plan, and the merged service helpers
  keep the install-time and optimize-time values identical.

## What's new in 1.8.30

- **Every scratch write is staged under `/tmp`.** The shared `tmp_file`/`tmp_dir`
  helpers force `--tmpdir=/tmp` and refuse an absolute caller template, and the
  new `sed_in_place` helper replaces every GNU `sed -i` call. A config rewrite
  no longer creates a `sed*` scratch file beside a live `/etc` file; the staged
  copy lives under `/tmp` and the original inode keeps its mode, owner and hard
  links.
- **Unattended upgrades no longer delete anything.** The optional `unattended`
  profile sets `APT::Periodic::AutocleanInterval "0"` and sets
  `Remove-Unused-Kernel-Packages` / `Remove-Unused-Dependencies` to `false`, so
  a background apt job cannot remove packages, kernels or cached archives on a
  live server.
- **Test and tool scratch data is explicitly under `/tmp`.** The tuning tests,
  the stress runner and `tools/diff_configs.sh` use absolute `/tmp` templates
  instead of relying on an inherited `TMPDIR`. The stress seeder now updates its
  own fixed rows/documents instead of dropping its MariaDB table or deleting
  its Elasticsearch index.
- **Duplicate helpers merged.** `tune_size_value` now delegates to
  `mb_to_config`, and a single `storage_class` helper feeds both the MariaDB
  I/O-capacity and Angie cache tuners, so install and `--optimize` classify the
  disk the same way.
- **Install and `--optimize` parity re-verified.** Both paths still use the same
  CPU governor, swap, sysctl/PAM, Angie, PHP-FPM, MariaDB, Valkey and
  Elasticsearch sizing helpers and the same 80%-of-RAM memory plan; no service
  lost a tuning step in this release.

## What's new in 1.8.29

- **No permanent deletions anywhere.** Package purge/autoremove/clean calls,
  `rm`/`rmdir`/`find -delete`, crontab removal and old-backup pruning were
  removed. `--purge` now stops/disables services and restores recorded originals,
  then leaves packages, databases, configuration, certificates, caches and logs
  in place. A rejected vhost or a legacy generated JVM options file is moved to
  `/tmp`, not deleted.
- **All scratch data lives under `/tmp`.** `mktemp` wrappers force `TMPDIR=/tmp`,
  the run lock moved from `/run` to `/tmp`, and temporary config rewrites no
  longer create `*.new` files beside `/etc` files. Optimize rollback copies now
  live under `/tmp` and expire there instead of being pruned.
- **Install and `--optimize` share one hardware plan.** A fresh install now sizes
  PHP-FPM, MariaDB, Valkey and Elasticsearch from the same 80%-of-RAM budget
  used by `--optimize`, instead of each service claiming its own percentage.
  Both paths call the same CPU governor, swap, sysctl/PAM, Angie, PHP-FPM and
  service tuning helpers.
- **Angie and PHP tuning parity.** The installer now applies the WordPress
  FastCGI guest cache and the same cache/error-policy tuning as `--optimize`.
- **Duplicate helper merged.** `opt_clamp` was merged into the shared
  `tune_clamp`, and the Angie systemd limit logic is one helper used by install
  and optimize.
- **PHP `redis-server` conflict is reported, not fixed by purging.** If Redis is
  already installed, Valkey installation stops with a warning instead of
  removing Redis and its files.

## What's new in 1.8.28

- **Live tuning no longer restarts a cache just to add defaults.** Valkey and
  Redis refuse to change `maxclients` above the process fd limit, and a
  restart discards the whole cache because the installer disables
  persistence. `--optimize` now applies every runtime-settable value with
  `CONFIG SET` and only restarts when a startup-only setting (`io-threads`)
  actually changed or an online set fails. `tcp-backlog` is reported as
  applying on the next restart instead of forcing one.
- **Angie and PHP-FPM are reloaded gracefully, not restarted.** A `reload`
  keeps the listening sockets open and lets in-flight requests finish; the
  previous `restart` dropped them for 1-3 seconds on a busy host. The tuners
  fall back to a restart only when the reload itself fails. Changes that the
  master reads at startup (`process_control_timeout`, systemd fd drop-ins)
  are reported as applying on the next full restart.
- **A live cache is never shrunk below its current size.** The disk cache
  `max_size` is derived from RAM, which is often smaller than an existing
  cache on a media/forum host. Writing that value made Angie evict hot
  objects immediately; the tuner now raises it to the current usage +5%
  and reports why.
- **Stale PHP version directories are ignored.** A leftover
  `/etc/php/<ver>/fpm` with no pool config made `--optimize` create systemd
  drop-ins and per-version reports for a service that was not installed.
  Only versions with a real pool and binary are detected now.
- **An idempotent run never deletes healthy cache entries.** Older releases
  purged the cache after a cutover; since 1.8.29 the run only counts and
  reports objects written during the run. A repeat run with unchanged files
  reports `Cache: left intact`.
- **The pool-level `process_control_timeout` is normalised too.** Older
  `pool.d/www.conf` templates carried a `[global]` block with 60s; because
  pool files are included last, that value overrode the 10s global setting.
  Both the templates and the tuner now use 10s.
- **The stale-5xx fix now covers every guest cache.** `php_chev.conf`,
  `php_flarum.conf` and `php_xf_proxy.conf` still cached/`use_stale` a
  transient 500; the tuner upgrades them like WordPress and XenForo.

## What's new in 1.8.27

- **A PHP-FPM restart can no longer hang in “deactivating”.** With the
  package default `process_control_timeout = 0`, a busy pool waits forever
  for its workers on stop; systemd then holds the unit for its 90 s
  `TimeoutStopSec` while the shared socket is gone — every PHP vhost returns
  502 for the whole window (observed on a saturated 8-core host). The tuner
  and installer now write `process_control_timeout = 10s` in the global
  `php-fpm.conf` and `TimeoutStopSec=15` in the systemd drop-in, so a restart
  completes in seconds.

## What's new in 1.8.26

- **The network profile can be pinned per host.** BBR is a good default on
  long-haul links, but a busy reverse proxy measured **233 req/s with
  `bbr/fq` versus 335 req/s with `cubic/fq_codel`** (plus 65 ms lower median
  latency). `--optimize` now honours `SETUP_TCP_CC` / `SETUP_QDISC`
  (environment) or `/etc/default/setup-tuning` (`TCP_CC="cubic"`,
  `QDISC="fq_codel"`), and writes the matching modules-load list, sysctl.d
  drop-in and oneshot unit. The unit is restarted (not just started) so a
  changed value applies on the same run. Unsafe values fall back to BBR/fq.

## What's new in 1.8.25

- **The MariaDB buffer pool is resized online instead of restarting the
  database.** Restarting a busy host just to grow the pool by a few percent
  empties every application cache at once; on a live XenForo forum that caused
  ~990 simultaneous `INSERT … ON DUPLICATE KEY UPDATE` calls on the same
  `xf_data_registry` row, a lock convoy that took the site down until the
  database was restarted again. When the buffer-pool line is the only change
  to `99-setup-optimize.cnf`, `--optimize` now runs
  `SET GLOBAL innodb_buffer_pool_size` and keeps serving. Other changes still
  restart immediately, and a failed online resize falls back to the restart.
  The report shows the effective size applied.
- **The PHP socket migration no longer fails the run when a build ignores the
  listener change on reload.** PHP 8.4 was observed to keep the old TCP
  listener after `SIGUSR2`; `--optimize` now restores the TCP pool, reports
  `Socket migration skipped …`, and exits successfully. A planned PHP-FPM
  restart completes the move without cutting the site unexpectedly.

## What's new in 1.8.24

- **The PHP-FPM socket migration now works where a reload does not add
  pools.** PHP 8.3's `SIGUSR2` reload applies changes to existing pools but
  does not start a newly added bridge pool, so the former cutover waited ten
  seconds and rolled back to TCP. The migration now gives Angie the socket as
  primary plus the existing TCP listener as backup, moves the existing pool
  on reload, and removes the backup once the socket is live. A request that
  lands exactly in the cutover can fail over to the backup; the post-run cache
  report lists any blank page written in that window (files are not deleted). Failures now report the exact stage instead of only
  "socket migration failed".

## What's new in 1.8.23

- **A restart window can no longer leave a blank guest page cached.** If a
  backend is restarting (MariaDB, PHP-FPM), XenForo/WordPress can emit an
  empty `200` that Angie's FastCGI guest cache stores for its 5-minute 200
  validity. During the live validation on a XenForo host the cutover produced
  exactly that and every guest received a blank homepage. Newer releases
  discover the included `fastcgi_cache_path`/`proxy_cache_path` directories
  and report how many objects were written during the run. Since 1.8.29 they
  are left in place instead of being deleted; invalidate them manually if a
  blank response really was cached.
- **MariaDB is not restarted just to apply a larger fd limit.** When the only
  change is the systemd `LimitNOFILE` drop-in and the running limit is already
  at least 65536 (far above what `max_connections` needs), the drop-in is
  written and applies on the next planned restart instead of interrupting
  in-flight queries. Real `my.cnf` changes still restart immediately.

## What's new in 1.8.22

- **An OS-only `--optimize` run no longer leaves an empty backup tree.** The
  rollback directory is created lazily by the first `opt_backup`, so a host
  with no supported services (only sysctl/PAM/governor tuning) writes the
  report and nothing else. The report shows `Backup directory: none`.

## What's new in 1.8.21

- **Elasticsearch now has one managed heap file.** The installer wrote
  `jvm.options.d/jvm.options` and `--optimize` wrote
  `jvm.options.d/zz-setup-optimize.options`, so a host that had both passed
  two conflicting `-Xms/-Xmx` pairs to the JVM (the last one silently won).
  Both paths now own `zz-setup-optimize.options`; the old generated file is
  moved to `/tmp` when it matches the exact script-generated shape, and an
  operator's own `jvm.options` is preserved.
- **`/etc/sysctl.conf` no longer contains duplicate keys.** The base profile
  and the hardware-aware block set some of the same tunables
  (`somaxconn`, `tcp_max_syn_backlog`, `file-max`, ...), with the last line
  winning. `--optimize` now keeps only the final definition of each key, so
  the effective value is unambiguous, and caps
  `net.ipv4.tcp_challenge_ack_limit` at 1000 (CVE-2019-11479) instead of the
  legacy maximum.
- **Valkey is never shrunk below its live working set.** A restart applies
  `maxmemory` immediately, so a plan below the stored data would mass-evict a
  cache or session store. `--optimize` now gives `used_memory` 10% headroom
  and reports the raised value.
- **Small hosts keep usable service floors.** Proportional scaling could hand
  a 1 GB host a 17 MB Valkey budget; Valkey and Elasticsearch now keep their
  256 MB / 512 MB minimums.
- **Rollback backups are root-only.** `/tmp/setup-optimize-*` is
  created with mode 0700 because it contains copies of
  `/etc/angie/ssl/*/privkey.pem` and `/etc/mysql/debian.cnf`.
- **Legacy Angie files are reported, not silently ignored.** When `http.d`
  still contains pre-rename `*_conf` cache/limit files that `angie.conf`
  never includes, the report lists them and points at the config deploy
  instead of only printing "no active fastcgi_cache_path".
- **Smaller hardening and hygiene fixes.** `angie -t` output uses `mktemp`
  instead of a predictable `/tmp` path written by root; an unchanged Angie
  fd-limit drop-in no longer forces a restart on every run; optimize reports
  keep the twenty newest files; and a missing report file no longer aborts
  the final summary.

## What's new in 1.8.20

- **Real runs are serialised with a `flock` lock.** Two invocations (an
  operator plus cron/CI) can no longer interleave config rewrites and leave a
  half-written service file. Dry-runs never take the lock.
- **`--optimize` always leaves a report, even on a hard failure.** A `die`,
  `set -e` exit, or dropped session now writes the partial
  `/var/log/setup-optimize-*.md` report before exiting, so the remote operator
  can see which step failed. The ERR trap also prints the failing command
  (bounded to one line) instead of only a line number.
- **OS tuning raises sysctl values before writing the PAM nofile limits.** A
  limits value above the kernel's `fs.nr_open` makes PAM fail to raise the
  hard limit on the next login.
- **`--optimize` repairs service log-directory ownership before restarting
  anything.** Hosts upgraded from older releases can have
  `/var/www/logs/valkey` or `/var/www/logs/elasticsearch` owned by
  `www-data`. A restart then fails: Valkey cannot open its logfile and
  Elasticsearch cannot rotate its logs (`Null object returned for RollingFile`
  / `Exec failed, error: 13`). The ownership fix is recursive so rotated
  `.log.1`, `.gz` and audit files are included.
- Temporary config checkouts live under `/tmp` and are left for the operating
  system to expire; older releases removed them on exit.
- **APT downloads retry automatically** (`Acquire::Retries=3`, 30 s HTTP
  timeout) in addition to the existing dpkg lock wait.
- A PHP version directory without `pool.d/www.conf` is reported as a miss
  instead of marking the configuration dirty and forcing an unnecessary
  PHP-FPM restart.

## What's new in 1.8.19

- **`--optimize` automatically migrates old PHP-FPM TCP pools to the shared
  Unix socket.** When the primary pool listens on loopback TCP (for example
  `127.0.0.1:9000`) and the active vhosts use the `local_php` upstream,
  `--optimize` starts a temporary on-demand bridge pool on the next free
  loopback port, points Angie at the bridge with the original TCP listener as
  backup, moves the main pool to `/run/php/php-fpm.sock`, points Angie at the
  socket, and removes the bridge. The old TCP listener stays alive until
  Angie is already using the bridge, so the migration avoids the listener gap
  that caused 502s. Direct `fastcgi_pass` handlers and
  `fastcgi_next_upstream off` are left on TCP (the backup fallback would not
  be safe); standalone PHP hosts without Angie also keep TCP. Any failure
  restores the pool and Angie config and reloads both services back to TCP.
  A few in-flight keepalive requests can still reset during the graceful
  Angie/PHP reloads.

## What's new in 1.8.18

- **PHP-FPM pools with a missing slowlog directory no longer fail
  `--optimize`.** A pool upgraded from an older package can still point
  `slowlog` at a path whose directory was removed (seen on an Ubuntu 24.04
  host: `/var/log/php-fpm/www-slow.log`). The tuner now creates the configured
  `slowlog`, `access.log` and pool `error_log` directories (and the file when
  the name has no runtime variable) before enabling `request_slowlog_timeout`.
  It also prints the real `php-fpm -t` error instead of only reporting a
  generic configuration failure.

## What's new in 1.8.17

- **The dry-run cache estimate matches the applied value.** `--optimize
  --dry-run` now uses the same service-aware budget as the tuner (50% of RAM
  for an Angie-only host, 30% for Angie+PHP, 25% with a data/search tier)
  instead of always printing 25%. Every `h5bp/php*.conf` template is still
  tuned even when no current vhost includes it, so a vhost created later
  inherits the optimized buffers.

## What's new in 1.8.16

- **SSH firewall rules follow the real sshd port.** `--basic` now reads
  `sshd -T` and allows every effective SSH port before enabling UFW instead of
  hard-coding 22. `--purge` protects the same ports, and the fail2ban jail is
  written with the detected port. This removes a lockout risk on hosts that
  moved SSH to a custom port.
- **fail2ban whitelists the operator, not the server.** The fallback that
  reads established sockets assumed a fixed `ss` column, but the state column
  is omitted when `ss -H` is combined with a state filter, so that column is
  the server address in one form and the client in the other. It now reads
  the last two fields (local, peer) and the live sshd ports.
- **The `fq` qdisc survives package upgrades.** A late
  `/etc/sysctl.d/90-setup-network.conf` keeps `net.core.default_qdisc=fq`
  when `systemd-sysctl` re-runs (observed after an upgrade reset it to
  `fq_codel`); BBR itself remains in the oneshot unit that runs after
  `tcp_bbr` loads.
- **The single-file sysctl fallback is back in sync.** The embedded
  `blob_sysctl` no longer writes `net.ipv4.route.flush` / `net.ipv6.route.flush`,
  which made `systemd-sysctl` log a failure at boot. A test now fails if the
  embedded copy drifts from `configs/system/sysctl.conf`.
- **The CPU governor report tells the truth.** Hosts without a performance
  governor (or without cpufreq at all) are reported as skipped instead of
  claiming `governor=performance`. The script no longer removes a provider's
  `tuned` package; it warns instead.
- **APT is more resilient.** `dpkg --configure -a` plus a one-time
  `apt-get -f install` repair a half-configured dpkg state before the upgrade
  is retried, and package operations now disable the dpkg pty and use
  `Acquire::Retries`.

## What's new in 1.8.15

- **The old auto-tune switch is gone.** `--optimize` is the only entry point;
  it already performs the complete OS + service pass. The former alias and
  the separate wrapper script were removed.

## What's new in 1.8.14

- **One command for the whole host: `--optimize`.** The operating-system
  layer (CPU governor, PAM limits, hardware-scaled kernel/network/memory
  sysctls) is now applied by `--optimize` together with Angie, PHP-FPM,
  MariaDB, Valkey/Redis and Elasticsearch. Existing servers get the complete
  treatment with `sudo bash setup.sh --optimize`. The former separate
  auto-tune mode and wrapper were removed; there is one command now.

## What's new in 1.8.13

- **MariaDB keeps a hardware-scaled buffer-pool floor.** A freshly installed
  database with a few MB of data no longer collapses a 128 GB host to a 256 MB
  pool; the floor is 1/16 of RAM, capped at 8 GB, and still bounded by the
  shared 80%-of-RAM budget.
- **`--optimize` now upgrades old installs consistently.** It applies the
  systemd `LimitNOFILE` drop-ins used by the installer (Angie, PHP-FPM,
  MariaDB), raises `vm.max_map_count` for Elasticsearch, preserves an explicit
  Valkey `io_threads` value, and disables caching/stale serving of 5xx
  responses for WordPress and XenForo FastCGI caches.
- **Chevereto-only Imagick is installed on demand.** `--domain ... app=chevereto`
  installs `php<ver>-imagick`; the default XenForo/WordPress PHP profile stays
  lean and does not add Imagick.

## What's new in 1.8.12

- **Per-service budgets now scale with the services actually installed.**
  - Angie cache: 50% of RAM / 10% of free disk on an Angie-only host, 30% /
    5% with Angie+PHP only, and 25% / 5% when a data/search tier is present.
  - Valkey/Redis: 50% of RAM if it is the only service, 25% on a
    web+cache-only host, and the previous 10% (8 GB cap) when MariaDB or
    Elasticsearch is present.
  - MariaDB-only hosts use the full 80%-of-RAM cap; the data+5% target still
    prevents over-allocation when the database is smaller.
  - Elasticsearch-only hosts fall back to 50% of RAM (capped at the 31 GB
    compressed-oops limit) when the index size cannot be measured.

## What's new in 1.8.11

- **The Angie cache budget now follows the cache types actually present.**
  Previously the 25%-of-RAM cache budget was split 50/25/15/5/5 across
  FastCGI, Chevereto, XenForo-proxy, proxy and CDN caches even when only one
  existed. A dedicated proxy with only `xfproxycache` now receives the whole
  budget, as does an Angie+PHP host with only `fastcgicache`; custom-only
  cache paths also use the full budget.

## What's new in 1.8.10

- **Elasticsearch replica cleanup now waits for shard recovery.** After a
  heap change restarts Elasticsearch, the cluster can be red for a few
  seconds while primaries are assigned. `--optimize` now waits up to two
  minutes for primaries to recover before deciding whether to clear
  unassigned replicas, so a single run completes the fix.

## What's new in 1.8.9

- **MariaDB and Elasticsearch are sized from the live data, not RAM.** The
  optimizer now uses `current data size + 5%` for both the InnoDB buffer pool
  and the Elasticsearch heap, capped by the shared budget (and 31 GB for
  Elasticsearch). A 40%-of-RAM / 25%-of-RAM fallback is used only when the
  data size cannot be measured. Oversized live pools/heaps are reduced to the
  data-sized target, so memory is not reserved for data that does not exist.

## What's new in 1.8.8

- **MariaDB is no longer capped at 32 GB.** `--optimize` and
  `--mariadb size=auto` use 40% of RAM as the automatic baseline, bounded
  only by the shared budget left after the cache and search tiers. On a
  256 GB host this allows a ~103 GB buffer pool. Elasticsearch keeps its
  31 GB compressed-oops ceiling.

## What's new in 1.8.7

- **Elasticsearch's heap now follows the live index store.** `--optimize`
  sizes the JVM heap to the measured index store plus 5%, up to the 31 GB
  compressed-oops ceiling, and only when it fits the shared budget after
  PHP, MariaDB and Valkey/Redis reservations. A larger existing heap is
  preserved, and a heap within ±2% of the computed target is kept as-is to
  avoid restart churn.

## What's new in 1.8.6

- **MariaDB's buffer pool now sizes to the live database working set.** When
  the measured data+index size plus 5% headroom fits the shared 80%-of-RAM
  budget after reserving PHP, Valkey/Redis and Elasticsearch, `--optimize`
  uses it. Smaller databases keep the previous conservative target
  (40% of RAM, capped at 32 GB), and an existing larger pool is still
  preserved instead of being shrunk. A live pool within ±2% of the computed
  target is kept as-is so small statistics drift does not cause restarts.

## What's new in 1.8.5

- **`--optimize` no longer shrinks an existing larger MariaDB buffer pool.**
  Automatic sizing still targets at most 32 GB, but when the live pool is
  larger and fits within 50% of RAM and the shared service budget, the
  existing size is kept. This prevents a large-memory host with a
  deliberately sized pool from being reduced on every optimize run.

## What's new in 1.8.4

- **`--optimize` enables a WordPress guest FastCGI cache automatically.** It
  detects vhosts that include `h5bp/php_wp.conf`/`h5bp/wordpress.conf` and have
  a real `wp-config.php`, deploys the Angie repository's cache templates, and
  invokes the cache only for anonymous GET/HEAD requests. Logged-in users,
  POST/PUT/DELETE/PATCH, authorization headers, wp-admin/wp-login/wp-cron/
  wp-json/XML-RPC, feeds, previews, cart/checkout/account pages and shop
  session cookies bypass the cache. Cache state is exposed through
  `X-Cache-Status` for verification.
- **Single-node Elasticsearch yellow health is fixed automatically.** When
  the cluster has one node and only replica shards are unassigned,
  `--optimize` sets `number_of_replicas=0` on existing indices and installs a
  low-priority index template so new indices stay green. Multi-node clusters
  and unassigned primary shards are left untouched.

## What's new in 1.8.3

- **`--optimize` is stable across repeated runs.** The memory planner now
  applies the same 8-worker PHP floor as the pool tuner, so the first run
  cannot change the PHP budget that the second run recalculates. The Angie
  cache budget is rounded down to 256 MB so small disk-free changes from
  backups or logs do not resize cache zones and force a restart.
- **MariaDB/Elasticsearch size-fit reporting** remains in place: a database
  or index larger than the feasible pool/heap is reported as not fully
  fitting instead of silently overcommitting RAM.

## What's new in 1.8.2

- **Hostname changes keep `/etc/hosts` in sync.** `--basic host=...` now
  updates the `127.0.1.1` entry (or adds one) so `sudo` and `hostname -f` do
  not keep resolving the old name. `--purge basic` restores the original
  `/etc/hosts` from the recorded backup.

## What's new in 1.8.1

- **Redis is optimized when Valkey is not installed.** Existing hosts often
  run `redis-server`; `--optimize` now detects `/etc/redis/redis.conf`,
  tunes it with the same cache logic, and raises the Redis unit's
  `LimitNOFILE`. Valkey still takes precedence when both are present.
- **PHP capacity is reserved before data-service sizing.** The previous plan
  split 80% of RAM among MariaDB/Elasticsearch/cache first and gave PHP the
  remainder, which could cut a live 128-worker pool to ~34 workers. The
  planner now reserves the pool's current `max_children` (at 96 MB/worker,
  capped at 50% of RAM) and fits the data services into what remains.
- **Shared hosts cap the Elasticsearch heap at 8 GB** instead of 25% of RAM,
  so the freed memory goes to MariaDB. A dedicated search node still uses the
  larger 25% allowance.
- **Elasticsearch heap follows the live index size.** The planner reads the
  allocated store size from `_cluster/stats`; if the index is larger than the
  base heap it raises the target (up to 16 GB on a shared host, 31 GB on a
  dedicated search node) and reports when the index still exceeds the heap.
- **MariaDB is sized to the live database.** `--optimize` reads the actual
  data+index size from `information_schema` and targets a buffer pool that
  holds it (with 5% headroom) when the RAM budget allows. If the database is
  too large, it receives the largest feasible pool and the report states that
  it does not fully fit.
- **Existing MariaDB connection ceilings are preserved.** If the live server
  already allows more than `threads × 32` connections (up to 2000), the
  generated config keeps that headroom instead of lowering it.
- **PHP listeners are preserved on live hosts.** `--optimize` no longer moves
  a TCP PHP-FPM pool to a Unix socket (which briefly leaves Angie pointing at
  the old port). It keeps the existing listener and repoints Angie only when
  the pool already uses a socket. New installs still use the socket template.
- **Only Angie-included http.d files are tuned.** Discovery follows the actual
  `include` patterns, so inert `_conf` leftovers from older layouts are left
  untouched and the active `*.conf` cache file is the one that gets resized.
- **Clearer budget reporting.** The shared cache allocation is reported as
  `Cache` so the same line is accurate for Valkey and Redis.

## What's new in 1.8.0

- **`--optimize` now supports Ubuntu 22.04.** The optimize path only rewrites
  service configuration and never installs packages, so it is safe on 22.04,
  24.04 and 26.04. This makes the command usable on existing production hosts
  that predate the 26.04 installer requirement.
- **Legacy Angie layouts are tuned too.** Older releases installed
  `http.d/fastcgi_cache_conf` (underscores); current releases use
  `fastcgi_cache.conf` (dots). `--optimize` now resolves both names instead of
  silently skipping cache and request-limit tuning on an older live server.
- **Missing tuning targets are reported.** A missing cache/limit file or a
  directive that no longer exists is recorded as `Not applied: …` instead of
  being ignored.
- **File-descriptor limits match `fs.nr_open`.** The PAM profile now requests
  1,048,576 descriptors, the minimum `fs.nr_open` this script configures, so
  `pam_limits` can always raise the hard limit on a small VPS. Service units
  keep their smaller, explicit `LimitNOFILE` drop-ins.
- **Post-restart verification checks listeners and logs.** Angie must hold a
  real listening socket (from `ss`), PHP must own its socket or TCP port,
  MariaDB/Valkey/Elasticsearch keep their SQL/PING/HTTP probes, and recent
  error-level journal entries are included in the report.

## What's new in 1.7.1

- **`--optimize` tuning is now covered by tests.** New
  `tests/test-tuning.sh` (29 checks) sources the helper functions and
  exercises Angie rewriting, PHP pool editing and the shared memory budget
  against the repository fixtures, including a second-run idempotency check.
- **Fixed multi-line `proxy_cache_path` tuning.** `max_size` for
  `/home/proxy_cache` and `/home/proxy_cdn` sits on a continuation line, so
  the previous one-line `awk` silently left both at `16g`. The rewriter now
  follows the directive across lines.
- **Config drift is visible.** A pattern that no longer matches an existing
  tuning target is recorded as `Not applied: …` in the Markdown report (and
  as a warning during install) instead of failing silently. Informational
  misses do not trigger a restart.
- **Stricter insertion anchors.** `client_body_buffer_size` and
  `worker_connections` are only inserted after the real `http {` / `events {`
  block openers; the loose anchor also matched `http2 on;`.
- **Valkey no longer restarts on a no-op run.** `optimize_valkey` inherited
  the previous service's dirty flag, which forced a restart while the Angie
  and PHP restarts were being skipped.
- **Safer PHP/Angie ordering.** A pool that cannot be identified leaves
  Angie's FastCGI upstream untouched, and a missing socket after restart
  aborts the repoint and rolls the PHP configuration back.
- **Shorter failure detection.** `/var/log/setup-optimize-*` names include
  nanoseconds, so two runs in the same second cannot overwrite each other.
- **Post-run health checks.** `--optimize` ends with `angie -t`, a PHP socket
  and config check, `SELECT 1` for MariaDB, `PING` for Valkey and an HTTP
  probe for Elasticsearch; results land in the report and the exit status.
- `apt-get update` now honours the same 300 s dpkg lock timeout as installs.

## What's new in 1.7.0

- **One shared memory budget for `--optimize`.** MariaDB (40%), PHP workers
  (50%), Valkey (10%) and Elasticsearch (25%) used to size themselves
  independently, so a host running three or four services could commit
  100-125% of RAM before the kernel got a byte. Allocations now come from a
  single 80%-of-RAM budget and are scaled down when needed; an 8-core/12 GB
  server with Angie, PHP, MariaDB and Valkey now plans 37 PHP workers instead
  of 62, leaving headroom for page cache and traffic spikes.
- **Truly idempotent restarts.** A repeat `--optimize` run detects that the
  generated Angie/PHP/MariaDB/Valkey/Elasticsearch files are unchanged and
  skips the restart entirely (verified by PID comparison on the live server).
- **PHP-FPM socket safety.** The shared `/run/php/php-fpm.sock` is only
  assigned when Angie is present and only for the pool Angie uses; a
  standalone PHP host, or a second PHP version serving another application
  over TCP, keeps its existing listener.
- **Backlog values follow the live kernel.** PHP-FPM and Valkey request
  `min(65535, somaxconn)` instead of 65535 unconditionally, so `--optimize`
  does not create a backlog the running kernel will silently clamp.
- Valkey gets a dedicated systemd fd-limit drop-in when its unit still caps
  `LimitNOFILE` below `maxclients`.
- Duplicate managed directives in a PHP-FPM pool are collapsed per section
  (the `[global]` master limit and the `[www]` worker limit are preserved).
- Typographic em/en dashes are normalized, so pasted commands such as
  `setup.sh —optimize` work. Bash 4.0+ is checked explicitly, and APT waits
  up to 300 s for a concurrent dpkg lock instead of failing.
- Rollback backups live under `/tmp/setup-optimize-*`; since 1.8.29 they are
  left for the operating system to expire instead of being pruned.

## What's new in 1.6.12

- Removed the obsolete `legacy/basic_setup.sh` tree and its documentation.
- Repository cleanup only; installation and `--optimize` behavior is unchanged.

## What's new in 1.6.11

- `--optimize` on Ubuntu 24.04 live-server validation: PHP-FPM 8.4 moved from
  `127.0.0.1:9000` to `/run/php/php-fpm.sock`, Angie's `local_php` upstream
  repointed, MariaDB 10.11 tuned through the `[mysqld]` drop-in, Valkey
  resized, and no Elasticsearch was installed or touched.
- Removed `listen.allowed_clients` when switching a PHP-FPM pool to a Unix
  socket; it is meaningless there and was present on older pools.
- The FastCGI rewrite now matches only active `fastcgi_pass` directives, not
  commented examples in `sites-available/` or docs.

## What's new in 1.6.10

- Moved PHP-FPM pool templates (`www_81.conf` … `www_85.conf`),
  `custom_dan.ini` and `php-fpm-limits.conf` from
  `server-configs-nginx/scripts/` to this repository's `configs/php/`.
  PHP-FPM is not Angie configuration, so a PHP-only install no longer fetches
  the Angie repository at all.
- `server-configs-nginx/scripts/nginx_conf.sh` now only syncs the Angie tree;
  it removes stale PHP-FPM files from `/etc/angie/scripts` during upgrades.
- Updated `tools/diff_configs.sh` to compare PHP configs against this
  repository instead of the Angie repository.

## What's new in 1.6.9

- **New `--optimize` command.** It scans only the services already installed
  on Ubuntu 24.04 or 26.04 and tunes them in place: Angie, every installed
  PHP-FPM version, MariaDB, Valkey and Elasticsearch. It never installs,
  purges or starts a service that was not already running.
- PHP-FPM pools are moved to the shared `/run/php/php-fpm.sock`, and Angie
  `fastcgi_pass`/`local_php` directives are repointed when a TCP listener is
  found. The shared socket is used only when Angie is installed; other PHP
  versions keep their existing listener.
- `--optimize` backs up every touched configuration directory under
  `/tmp/setup-optimize-*`, validates each config, restarts only active
  services, rolls back automatically on failure, and writes a Markdown report
  to `/var/log/setup-optimize-*.md` (latest at
  `/var/log/setup-optimize-latest.md`).
- **Hardware-aware Angie/PHP tuning now belongs to `setup.sh`.** The previous
  `server-configs-nginx/scripts/auto_tune.sh` was moved into shared
  `tune_angie_configs` / `tune_php_fpm_version` functions used by both the
  installers and `--optimize`. `nginx_conf.sh` is now only a config deployer.
- `--optimize --dry-run` prints the detected services and planned values
  without changing anything or requiring root.
- MariaDB tuning is version-aware: `[mysqld]` performance drop-in works on
  10.11 (24.04) and 11.8 (26.04); 11.8 gets the new per-file buffering knobs,
  older versions use `innodb_flush_method=O_DIRECT`.

## What's new in 1.6.8

- **Hardware-aware auto-tuning is now applied on every deploy.** The new
  `server-configs-nginx/scripts/auto_tune.sh` derives Angie worker descriptors
  and connections, FastCGI buffers, upstream keepalive, TLS session cache,
  open-file caches, request-limit zones and all HTTP cache sizes from `nproc`,
  `MemTotal`, free disk space and the NVMe/SSD/HDD class. The same repository
  now scales from a 1 GB VPS to a 128 GB dedicated host without edits.
- PHP 8.5 made OPcache mandatory and removed the `php8.5-opcache` package.
  `--php` now detects that case instead of failing the whole PHP step.
- MariaDB now sizes `max_connections` from the CPU count (up to 2000) and sets
  `back_log = 65535`; a 500-connection run previously produced
  `SQLSTATE[HY000] [2002] Resource temporarily unavailable` on the Unix socket.
- `--elastic ram=auto` (25% of RAM, 512 MB..31 GB) and `--valkey ram=auto` are
  supported; `--elastic` no longer requires an explicit heap size.
- PHP request timeouts are 300 s (aligned with Angie's 360 s FastCGI timeout)
  so a first XenForo install/template rebuild is not killed halfway through.
- SSH is protected by a plain UFW `allow` rule instead of `limit`; the previous
  rule rate-limited automation and could lock out an operator after several
  short sessions. fail2ban remains the brute-force layer.
- `--purge` records and restores the live kernel values for every sysctl it
  changes, including keys absent from the original `/etc/sysctl.conf`.
- `--others smartmon` handles Ubuntu's `smartmontools.service` unit name.
- The stress harness persists DB/Valkey/ES credentials for PHP-FPM, so web
  workers no longer fall back to `demo/temp` and fill MariaDB's error log.
- Validated on Ubuntu 26.04 (48 vCPU, 128 GB RAM, NVMe): full install, all
  service flags, idempotent re-run, two full purges, clean reinstall, three
  applications, and aggressive `wrk` runs with zero socket errors at 400
  connections.

## What's new in 1.6.7

- Composer is installed from the official `composer.phar` into
  `/usr/local/bin/composer`, executed with the FPM-matched PHP binary.
  apt's `composer` package could pull unrelated PHP builds from Sury through
  virtual `php-cli`/`php-common` dependencies (observed: `php5.6-common` and
  `php8.5-cli`), which then broke `/usr/bin/php` and survived normal purges.
- `--purge --others` removes the setup-created Composer phar while still
  cleaning up an apt-installed Composer from an older release.
- Installing Composer now restarts the matched PHP-FPM pool. Reconfiguring
  PHP CLI/intl packages could leave running workers with stale
  OPcache/realpath state, which surfaced as `Unable to open primary script
  ... (Operation not permitted)` for existing application files.

## What's new in 1.6.6

- The CLI is now pinned to the same PHP version as FPM with
  `update-alternatives --set php`. Installing a distro package such as
  `composer` could previously pull `php8.5-cli` while the web pool ran 8.4,
  leaving `/usr/bin/php` without the app's `gd`/`xml`/`curl` extensions.
- `--others composer` installs `php<ver>-cli`/`php<ver>-intl` first and
  Composer in a separate apt transaction, so apt satisfies the virtual
  `php-cli` dependency with the FPM version instead of installing another PHP.

## What's new in 1.6.5

- fail2ban's SSH jail now whitelists the deploying operator's SSH client
  address. Because `sudo` strips `SSH_CONNECTION`, the script reads the parent
  process environment and falls back to the established `:22` socket. A
  failed password or automation retry during a long provisioning run can no
  longer lock the operator out for the full one-hour ban. Loopback is still
  ignored; all other sources keep the `maxretry=5`, `findtime=10m`,
  `bantime=1h` policy.

## What's new in 1.6.4

- `--others composer` now installs `php<ver>-intl` alongside the CLI. Composer
  2.x uses Symfony String's `Normalizer`, so it failed with
  `Class "Normalizer" not found` on the XenForo-minimal PHP profile.
- Live VPS validation: full stack install, domain vhosts for every app type,
  and Composer/Lychee dependency installation.

## What's new in 1.6.3

- Fixed `--domain` parsing when `app=TYPE` appears before another domain:
  `--domain a.test app=xf b.test` now gives `a.test` XenForo and `b.test`
  blank instead of applying `xf` to both. A single trailing `app=TYPE` after
  the whole list still applies to every domain, as documented.
- ShellCheck is clean at warning level; the log-directory helpers no longer
  shadow the `group` array used by the argument parser.
- Added `tests/test-dry-run-matrix.sh`, a 65-case validation matrix covering
  every service, domain app, purge mode and representative invalid inputs.
- Verified install, update, PHP 8.4 -> 8.3 switch, selective purge, full
  purge (twice) and clean reinstall in a disposable Ubuntu 26.04 KVM guest.

## What's new in 1.6.2

- Added `php<ver>-opcache` and `php<ver>-cli` back to the XenForo profile.
  OPcache enables the pre-wired OPcache/JIT settings and is strongly
  recommended for XenForo; the CLI is needed for `cmd.php` and Composer.

## What's new in 1.6.1

- Angie no longer writes access logs at all. Only `error_log` is enabled; the
  per-vhost `access_log` directives and the stress-site access log were
  removed. This removes the largest source of disk I/O and log volume.
- The PHP install is now the XenForo-minimal extension set only:
  `fpm`, `mysql`, `gd`, `curl`, `xml`, `zip`, `gmp`, `mbstring`, `redis`.
  `php<ver>-cli` is added only when `--others composer` is selected. The
  optional stress harness installs CLI for its seeder and can be removed
  afterwards.
- `intl`/`imagick`/`bcmath`/`apcu` are intentionally not installed by
  default. OPcache and CLI are included; `custom_dan.ini` OPcache/JIT settings
  take effect immediately. Chevereto deployments (`--domain ... app=chevereto`)
  install `php<ver>-imagick` automatically because Chevereto requires it.

## What's new in 1.6.0

- **Centralised logs.** Every service now writes below `/var/www/logs/`:
  `angie/`, `php/`, `mariadb/`, `valkey/`, `nodejs/`, `gifsicle/` and
  `elasticsearch/`. Collect the whole tree with
  `tar -czf /tmp/logs.tgz -C /var/www logs`. Logrotate rules are installed for
  the tree.
- **FastCGI over a Unix socket.** PHP-FPM listens on
  `/run/php/php-fpm.sock`; Angie's `local_php` upstream uses the same socket.
  This removed the loopback TCP overhead in local tests (about +10% PHP
  throughput and a lower p99).
- **Security fixes.** Config deployments no longer preserve the ownership of a
  local Git checkout in `/etc/angie`; the shared sample TLS key is no longer
  installed (a unique default certificate is generated per host); service
  umasks create group-readable logs; AppArmor is allowed to write the MariaDB
  log tree; limits are written as a drop-in instead of replacing
  `/etc/security/limits.conf`.
- **SSH cannot be locked out by `--purge`.** The SSH rate-limit rule is
  inserted before any pre-existing `allow 22` rule, and purge never removes
  SSH rules. It also adds `allow 22` first if UFW is active without one.
- **Domain fix.** `--domain a.com app=xf b.com app=wordpress` now assigns each
  `app=` to its own domain instead of applying the last app to every domain.
  A single `app=` after a list still applies to the whole group, as documented.
- **Pingvin fix.** Generated Pingvin vhosts use
  `/var/www/<domain>/frontend/public` instead of a doubled `frontend` path.
- **Compatibility fix.** PHP no longer disables `system`/`passthru`, which
  broke Chevereto video processing and some WordPress plugins by default.
- Added MariaDB `O_DIRECT`, buffer-pool dump/load and smaller Angie header and
  gzip buffers for large-site memory efficiency.
- `--others` includes GifSicle and Node.js logging; the stress site creates its
  own database and writes Node/GifSicle output to the central tree.

## What's new in 1.5.0

- Removed the embedded Angie config archive and all duplicated Angie/PHP config patching from `setup.sh`.
- `setup.sh` now downloads `server-configs-nginx` once per run and delegates deployment to its `scripts/nginx_conf.sh`.
- PHP-FPM pool and `php.ini` templates were sourced from `server-configs-nginx/scripts/www_<ver>.conf` and `scripts/custom_dan.ini` in this release (moved back to `configs/php/` in 1.6.10).
- Moved non-Angie/non-PHP-FPM files out of `server-configs-nginx` into this repo: `configs/system/`, `configs/mariadb/`, `tools/diff_configs.sh`.
- Added `CONFIG_SOURCE_DIR` for local/offline testing, plus `CONFIG_REPO_URL` / `CONFIG_REPO_REF` overrides.
- The repo deployer removes old setup.sh override files and pre-refactor config filenames during upgrades.

## What's new in 1.4.0

- Fixed the missing Angie `snippets/fastcgi-php.conf`, `PATH_TRANSLATED`, duplicate directives, template defects and the global 16 MB/s rate cap.
- Angie now enables the safe FastCGI/proxy cache zones and a per-IP rate limiter, with loopback exempt. `worker_connections` is 65k (about 1M total here) instead of 300k, cutting RSS from ~2 GB to ~0.5 GB.
- PHP gains the extensions needed by XenForo/WordPress/Chevereto/Polr/Lychee, auto-sized OPcache/JIT/memory limits, session hardening, OPcache file cache, slow-request logging, Unix-socket MariaDB defaults and `children=`/`max_requests=` overrides.
- MariaDB supports `size=auto` (40% of RAM), scales buffer-pool instances and I/O capacity to the hardware, enables the thread pool, slow query log, `secure_file_priv` and safer timeouts.
- Valkey supports `ram=`, `policy=` and `io_threads=`, defaults to 1 I/O thread, and creates a Unix socket that local PHP can use.
- `--domain` can generate ready vhosts for `xf`, `wordpress`, `pingvin`, `chevereto`, `polr`, `lychee`, `php` and `node`, including a per-domain self-signed certificate, tested with `angie -t`.
- `--others` adds `fail2ban`, `unattended`, `sysstat`, `composer` and a `security` shorthand.
- Purge now tracks every installed PHP-FPM version and removes setup-installed Composer first, so `--purge --php` no longer makes APT install an old PHP/Apache stack.
- Added the `tests/stress-site/` full-stack benchmark site and `run-stress.sh` harness used for the v1.4.0 measurements below.

