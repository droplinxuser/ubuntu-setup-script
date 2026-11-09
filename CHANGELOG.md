# Changelog

Release notes for ubuntu-setup-script. Current behaviour is documented in
README.md; measurements in tests/stress-site/RESULTS.md.

## 1.13.1 (2026-11-09)

- **PHP-FPM is always `pm = static`** (the 1.13.0 `ondemand` rule for small
  hosts is gone) and **the OPcache tracing JIT is always on** for the pool
  (buffer OPcache/4, 32-256 MB). `SETUP_PHP_JIT` and a persisted `PHP_JIT`
  no longer select a mode (a non-`tracing` value prints a notice and is
  ignored). WordPress roots use the JIT too; `SETUP_PHP_JIT_WORDPRESS=0`
  restores the per-root `[PATH=]` exemption (`opcache.jit = off`) for a site
  that misbehaves. `opcache.file_cache` stays empty, as scripts restored
  from it are never JIT-compiled. The dry run prints `pm=static` and the JIT
  buffer.

## 1.13.0 (2026-11-09)

Audit session on the dev-host development host (16 threads / 27 GiB / NVMe,
Ubuntu 26.04.1) from the 557-package baseline: fresh full-stack install with
XenForo 2.3.13 and WordPress 7.1.4 vhosts, `--optimize` parity, three
independent code reviews of `setup.sh` (PHP/Angie, MariaDB/Valkey/
Elasticsearch, OS/CLI/purge) and before/after load tests from a workstation.
Everything below was re-tested on that host (see tests/stress-site/RESULTS.md).

- **`set -e` was off for the whole `--optimize`/`--restart-all` run.** The
  drivers were called as `if ! run_optimize`, which makes bash suspend
  errexit and the ERR trap for the entire function, so a failed write inside
  a tuner was skipped while the same functions abort a `--basic` install.
  They are now called plainly; a handled failure returns through
  `handled_return` so the report still explains it without a duplicate
  `[ERR]` line. `--purge` keeps going past a file it cannot restore.
- **Adopted hosts keep their routing and IPv6.** The base sysctl template
  disables forwarding and IPv6 autoconfiguration; those lines are dropped on
  a host that already forwards (bridge, Docker/LXD, WireGuard/Tailscale) or
  whose address/default route comes from router advertisements. Every key
  the profile writes (the template's own included) is recorded once and
  restored by `--purge basic`; `ip_local_reserved_ports` protects 3306,
  6379, 9200, 9300 and the sshd ports inside the widened ephemeral range.
- **Hardware rules added:** `tcp_rmem`/`tcp_wmem` default by RAM,
  `vm.swappiness` 1 on flash, `kernel.shmmax = min(1 GiB, RAM/4)`,
  `netdev_budget` on dedicated 8+ CPU hosts; PHP-FPM `pm = ondemand` under
  2 GB or on a small VPS and `opcache.max_accelerated_files` from the real
  PHP file count; Angie `directio 16m` on flash, gzip level from the CPU
  rule, VPS worker-connection factor, `worker_cpu_affinity` dropped under a
  cgroup quota, upstream keepalive from the pool size actually written;
  MariaDB buffer-pool floor `clamp(RAM/16, 256 MB, 4 GB)` for an empty or
  unmeasured database and Aria page cache from RAM; Elasticsearch
  `node.processors` (two dead keys removed); udev I/O rules for every whole
  disk by rotational flag.
- **Fewer restarts.** The redo log, `tmp_table_size` and
  `max_heap_table_size` join the buffer pool in the online `SET GLOBAL`
  path; an unchanged managed crontab is no longer reinstalled (every
  `--optimize` had rewritten its header timestamp); the proxy/CDN caches
  follow the "never shrink a populated cache" rule.
- **Rollbacks.** PHP and Angie `--optimize` failures restore the unit
  drop-ins and `/etc/default/angie` too; install-time rollbacks use the same
  snapshot restore as `--optimize` (files added after the snapshot are moved
  out of the tree, `php-fpm -t` before the restart); one
  `opt_restart_service` helper for the MariaDB/Valkey/Elasticsearch restart,
  probe and rollback; `--restart-all` reuses the pause/resume and readiness
  helpers.
- **Purge and provisioning.** `--purge basic` restores the previous CPU
  governor (recorded; the unit is disabled), the `unattended-upgrades` file
  and unit state, and only the `127.0.1.1` line of `/etc/hosts`;
  `limits.conf` is restored only when it provably holds our old copy; one
  `daemon-reload` after both oneshot units. `--domain sql=` refuses a dump
  that switches to another schema and re-plans Valkey/Elasticsearch after
  the import; an existing site tree is no longer re-chowned on every run.
  WordPress guest cache is decided per vhost (a removed include is an
  opt-out; `SETUP_WP_GUEST_CACHE=1` adds it) instead of being re-enabled
  through the shared `php_wp.conf`.
- **CLI/state.** `--mariadb size=`/`--valkey ram=` under 128 MB and
  `io_threads` above 8 are clamped with a warning; run logs and
  `diagnostics.log` are handed to the `sudo` user; `persist_tuning_var`/
  `explicit_option_set` escape sed metacharacters; `--optimize` refreshes the
  APT lists once before its single `cpufrequtils` install; the sample
  `mysqlbkup.cnf` is mode 600 before it holds the password.
- **Measured and fixed:** `max_connections` allows one extra connection per PHP worker for every XenForo config on a persistent (`p:`) host (144 workers with XenForo on `p:localhost` plus WordPress exhausted the 230 ceiling and WordPress answered "Too many connections"); the optimize report no longer tells WordPress operators to set `DB_HOST` to `p:localhost` (core parses it as host `p` and the site returns 500) and flags such a value as broken instead.
- **Shared helpers:** `mariadb_ensure_local_user`, `restore_snapshot_dir`,
  `opt_restart_service`, `elasticsearch_wait_http`, `es_json_num/str`,
  `php_ini_profile`, `classify_block_device`, `sysctl_file_keys`,
  `cnf_key_bytes`, `angie_restore_live`, `tune_insert_before`; the XenForo
  guest-cache block is rendered and repaired from one directive list. The
  dry-run matrix grows from 106 to 159 cases and the tuning suite covers the
  new helpers.

## 1.12.0 (2026-11-09)

Validated on the dev-host development host (16 threads / 27 GiB / NVMe, Ubuntu
26.04.1) from a wiped 557-package baseline: a fresh full-stack install with
XenForo and WordPress vhosts followed by `--optimize` produced byte-identical
configuration trees (308 files), every mode ran on the host, five independent
code reviews of `setup.sh` fed the fixes below, and the guest/member tiers of
seeded XenForo 2.3.13 and WordPress 7.1.4 sites were load-tested from a
workstation before and after the changes.

- **OPcache JIT, per application.** `SETUP_PHP_JIT=tracing|function|off`
  sets the pool-wide mode (buffer OPcache/4, 32-256 MB; persisted as
  `PHP_JIT`). While on, every WordPress document root keeps `opcache.jit =
  off` through a `[PATH=<root>]` section of `zz-setup-optimize.ini`
  (applied per request by php-fpm, unlike a FastCGI `PHP_ADMIN_VALUE`,
  which sticks to the worker); `SETUP_PHP_JIT_WORDPRESS=1` lifts it. Scripts
  restored from `opcache.file_cache` are never JIT-compiled, so the file
  cache is left empty while the JIT is on. Benchmark: the Sury PHP 8.5.12
  build compiles nothing in any mode; on PHP 8.4 `tracing` gained 3-5% on
  every CPU-bound tier and `function` was equal or slower. The default stays
  off (the tracing JIT crashed php-fpm 8.3 on a live WordPress site). The dry
  run prints the JIT the run would write.
- **Rollback really rolls back.** `opt_restore` of a directory snapshot moves
  files created after the backup (a `99-setup-optimize.cnf` or
  `zz-setup-optimize.options` written on a host that had none) to `/tmp`
  instead of leaving them to win again on the rollback restart.
- **Valkey.** `io-threads-do-reads` (immutable on Redis 7, unknown to `CONFIG
  SET` on Valkey 9) is no longer sent online, so a tuning run no longer
  forces a cache-wiping restart; `maxmemory` gets a RAM floor (`RAM/64`,
  128 MB..1 GB; 434 MB on the test host instead of 128 MB); no double start
  on install.
- **Angie.** The repository sync no longer reloads before the tuner (every
  `--optimize` briefly served the repository defaults and reloaded twice);
  one reload per run, none when the tree digest is unchanged, so "Restart:
  skipped" is reachable. Install and optimize share `angie_apply_profile`.
  `open_file_cache` is bounded by `worker_rlimit_nofile - worker_connections`.
  XenForo guest-cache repairs land inside the location (not the server
  context) and re-include HSTS/Referrer-Policy, which a location-level
  `add_header` had dropped from every XenForo PHP response (templates fixed
  in server-configs-nginx 1.6.19).
- **Purge and CLI.** `--purge --angie` no longer removes the wp-cron entry;
  `--purge others` stops the `smartmontools`/`sysstat` units; `--purge --php
  ver=X` keeps `phpsessionclean.timer` for other versions; `swap=8Gi` parses
  and sizes under 64 MB are rejected; a non-root `--dry-run` prints the same
  backlog as the real run; an OS-only `--optimize` report keeps its content;
  `--dry-run --basic` lists the host-wide side effects; the bash gate is 4.4.
- **MariaDB.** `--optimize` leaves a commented-out `bind-address` alone
  (listen on every interface on purpose) and the installer validates the
  generated files with `mariadbd --help --verbose` before the restart.
- **PHP.** The pool version rewrite skips the `listen =` line; the report
  says when the systemd drop-in still needs a full restart; the
  "max_children capped" note no longer dirties the pool on every run.
- **Shared helpers:** `persist_tuning_var`, `ini_get`, `file_md5`,
  `active_cache_unit`, `ufw_rule_ssh_port`, `config_tree_digest`; dead
  Groovy script and Elasticsearch guard removed. Tests cover all of the above;
  the remote harness gains uncached-guest and member scenarios.
- Patches between 1.11.0 and 1.12.0: `--others nodejs` no longer switches an
  installed Node.js major (`SETUP_NODE_MAJOR`, `SETUP_NODE_ALLOW_MAJOR_UPGRADE`;
  a new major changed the native-addon ABI and killed soketi); per-request
  `open_basedir` params are commented out (PHP-FPM caches them per worker and
  one vhost restricted every other); OPcache JIT shipped disabled after the
  php-fpm 8.3 segfault.

## 1.11.0 (2026-11-09)

Audit of install/optimize parity, hardware rules and duplicated code (two
code reviews plus a repeated-block scan), validated on dev-host: identical
configuration trees after install and `--optimize` (241 files), every mode
clean on the host, remote `oha` suite matching 1.9.0.

- **Application-aware PHP-FPM worker cap:** 4 workers per core (3 on a VPS)
  when every PHP vhost is XenForo/WordPress with a local database; 144 and
  48 workers served the same ~950 member req/s while p50 fell from 107 ms to
  51 ms. `--php children=` wins.
- **Opt-in precompressed static assets** (`SETUP_PRECOMPRESS_ASSETS=1`,
  persisted): `.br`/`.gz` siblings for scripts, styles, fonts and SVGs under
  every XenForo/WordPress root, served by `brotli_static`/`gzip_static` and
  kept fresh by a cron helper; serving `core-compiled.js` compressed per
  request cost 50-89% CPU at 1.8k req/s, with siblings 2-5%.
- **Parity:** `--basic server=` is recorded and honoured by `--optimize`; the
  crontab is refreshed after every install; `secure_file_priv`'s directory
  is created on both paths; an adopted Redis gets its log directory; the
  installer prints the Elasticsearch heap/replica lines.
- **Hardware rules:** a cgroup quota below one core counts as one;
  `vm.min_free_kbytes` 1% of RAM with a 16 MB floor under 4 GB; PHP
  `memory_limit` 128M under 2 GB; redo log capped at 4 GB on NVMe; table
  caches follow `max_connections x 16`; Brotli 4 on 1-2 CPUs; the planner
  warns when the service floors exceed the budget; udev I/O rule on whole
  disks only.
- **Shared helpers:** `php_plan_max_children`, `php_fpm_binary`,
  `php_pool_set_listener`, `mariadb_wait_ready`, `opt_rollback_restart`,
  `angie_vhost_root`; dead code removed.

## Earlier releases (1.4.0 - 1.10.0)

Condensed from the per-release notes; each bullet describes the behaviour as it stood at 1.10.0.

### Memory plan and sizing
- Install and `--optimize` share one `plan_memory_budget()` and one set of hardware helpers, so a fresh install followed by `--optimize` leaves byte-identical managed configuration and every service reports "configuration already optimized" (1.8.29, 1.8.52, 1.9.0).
- Data services are sized from their live working set with at most 20% headroom: MariaDB `information_schema` data+index x1.2 (min 128 MB), Valkey/Redis `used_memory` x1.2 (min 128 MB); Elasticsearch gets a quarter of the index store, rounded up to 512 MB and capped at 25% of RAM and 31 GB, because the page cache, not the heap, serves the index (1.8.57, 1.9.0). The old RAM-percentage plans and RAM/16 floors are gone; an empty service gets only its minimum.
- Targets are reserved before PHP; if they cannot all fit they are scaled proportionally and trimmed Elasticsearch, then Valkey, then MariaDB, and the report says when a store does not fully fit. PHP-FPM is sized from the remainder (CPU-capped) and anything left stays with the OS page cache (1.8.56). A live value within 2% of its target is kept to avoid restart churn.
- Explicit `--php children=`/`max_requests=`, `--mariadb size=`, `--valkey ram=` and `--elastic ram=` are recorded in `/var/lib/setup.sh/explicit-options.conf` before the plan is built, reserved verbatim and never scaled down by later runs (1.8.52, 1.9.0). `--mariadb size=` defaults to `auto`; `SETUP_STATE_DIR` relocates the state directory so tests never read the live host.
- Sizing follows the real host: `effective_cpus()` honours cgroup CPU quotas, `mem_total_mb` honours a cgroup memory limit, `storage_backing_class()` classifies the device that backs `/var/www` (whole disks only, virtio counts as SSD), and VPS vs dedicated hardware changes several ceilings (1.8.46, 1.8.52, 1.9.0).
- PHP worker memory is measured from the live pool (average RSS +50%, clamped 64-192 MB; a fresh install reserves the 64 MB floor) and `--optimize` keeps a live pool's `max_children` instead of deriving it from the reservation (1.8.50, 1.8.51).

### Angie, guest caches and vhosts
- `--optimize` always syncs `/etc/angie` from `server-configs-nginx` (`CONFIG_REPO_URL`/`CONFIG_REPO_REF`, or `CONFIG_SOURCE_DIR` offline) through `deploy_angie_tree()` in setup.sh and then applies the hardware profile; a failed download restores the previous tree, legacy files are retired to `/tmp`, and only files Angie actually includes are tuned while legacy `*_conf` leftovers are reported (1.8.1, 1.8.21, 1.8.48, 1.8.51, 1.8.59).
- Dynamic Brotli at level 5 with gzip fallback is installed from `angie-module-brotli` on both paths (`SETUP_BROTLI_LEVEL` overrides); levels 10/11 collapsed throughput from ~16k to ~1k responses/s and Zstandard was 9-10% larger, so neither is used (1.8.46).
- Access logging is off; only `error_log` is written (1.6.1). `limit_req_log_level info` keeps per-IP rate-limit rejections out of the log, and `SETUP_LIMIT_REQ_EXEMPT="ip,cidr"` whitelists a load generator or monitor, persisted in `/etc/default/setup-tuning` (1.9.0).
- Guest FastCGI caching is enabled for WordPress and XenForo from the installer and `--optimize` through shared `ensure_fastcgi_cache_zone()` and `ensure_xf_guest_cache()` (1.8.4, 1.8.53). The XenForo key varies on `style_id`, `style_variation`, `language_id` and the normalised encoding, the cookie bypass is a `map` (no `if` in any location), expiring entries refresh in the background under `cache_lock`, and 5xx responses are never cached or served stale (1.8.13, 1.8.28, 1.8.50, 1.9.0). WordPress exposes `X-Cache-Status`.
- XenForo `/js`, `/styles` and `/data` get a 30-day `immutable` Cache-Control location (1.8.52). The PHP upstream keepalive is `max_children/2` clamped to 16..512, `worker_processes` follows the effective CPU count and `open_file_cache` scales with RAM (1.8.52, 1.9.0).
- The disk cache budget is 50% of RAM / 10% of free disk on an Angie-only host, 30% / 5% with PHP and 25% / 5% with a data tier, goes to the cache types actually present, is rounded down to 256 MB, and a live cache is never shrunk below current usage +5% (1.8.3, 1.8.11, 1.8.12, 1.8.28). Objects written during a run are counted and reported, never deleted.
- PHP includes are normalised: `PATH_TRANSLATED` is `$document_root$fastcgi_script_name` in every `h5bp/php*.conf`, the `snippets/fastcgi-php.conf` PATH_INFO capture is optional, and the WordPress/Polr includes carry `index index.php index.html;` (1.8.40, 1.8.45).
- `--domain` renders a full template from `conf.d/templates`: `basic` by default (`blank` is an alias) or `app=` xf, wordpress, pingvin, chevereto, polr, lychee, php, node, flarum, shlink, sfs; each domain takes its own `app=`, a self-signed certificate and `angie -t`; `db=NAME user=U pass=P sql=FILE` create a scoped MariaDB database/account and bulk-import a dump, after which the memory plan is rebuilt and applied (1.6.3, 1.10.0).
- The Angie APT key is scoped with `signed-by` like the Sury, Elastic and NodeSource keys (1.8.59). Angie and PHP-FPM are reloaded, not restarted, when files change (1.8.28).

### PHP-FPM
- PHP-FPM listens on `/run/php/php-fpm.sock` and Angie's `local_php` upstream uses it (1.6.0). `--optimize` migrates a live TCP pool to the socket: socket primary with the TCP listener as backup, graceful reload first, PHP-FPM restart if the build does not open the listener on SIGUSR2; direct `fastcgi_pass` handlers and hosts without Angie keep TCP (1.8.19, 1.8.47).
- Workers are 16 per core on dedicated hardware and 8 on a VPS, capped by 50% of RAM and 512, with an 8-worker floor (reduced under 1.5 GB); `listen.backlog` follows the CPU formula and `opcache.interned_strings_buffer` scales with the OPcache size (1.8.51, 1.9.0).
- `process_control_timeout = 10s` globally and in pools plus `TimeoutStopSec=15`, so a restart cannot hang in "deactivating" (1.8.27, 1.8.28). Request timeouts are 300 s to match Angie's FastCGI timeout (1.6.8).
- The extension set is XenForo-minimal (`fpm mysql gd curl xml zip gmp mbstring redis` plus OPcache and CLI); the CLI is pinned to the FPM version with `update-alternatives` (1.6.0-1.6.6).
- `configs/php/custom_dan.ini` ships in this repository and `--optimize` refreshes a stale copy while preserving `date.timezone` (1.6.10, 1.8.42). Session/cgi hardening is opt-in via `SETUP_PHP_SESSION_HARDENING=1` because the global overrides produced "Access denied" on Joomla/WordPress/Polr hosts (1.8.41, 1.8.43).
- Slowlog/access/error-log directories are created before `request_slowlog_timeout` is enabled; stale `/etc/php/<ver>` trees without a pool and binary are ignored (1.6.8, 1.8.18, 1.8.28).

### MariaDB
- `99-setup-optimize.cnf`, written by `write_mariadb_tuning_dropin()` from both paths, is the single owner of performance and logging keys; legacy optimizer keys are stripped from `50-server.cnf` and the base block (`skip_name_resolve`, `local_infile=0`, charset, `secure_file_priv`) is converged on adopted hosts (1.8.39, 1.8.52, 1.9.0). The drop-in is version-aware for 10.11 and 11.8 (1.6.9).
- A buffer-pool-only change is applied online with `SET GLOBAL innodb_buffer_pool_size`; a fd-limit-only change waits for the next planned restart (1.8.23, 1.8.25). There is no 32 GB cap (1.8.8).
- Hardware rules (1.9.0): `innodb_io_capacity` by disk class and host type (NVMe dedicated 10000/20000, NVMe VPS 3000/6000, SSD 4000/8000 or 1000/2000, HDD 400/800; `SETUP_MARIADB_IO_CAPACITY="r w"` pins it), `innodb_flush_neighbors=1` with 4 I/O threads on rotational disks else `clamp(cpus/2,4,16)`, `thread_cache_size = clamp(cpus*8,32,256)`, `tmp_table_size`/`max_heap_table_size = clamp(RAM/256,32,256) MB` capped at pool/8, `max_connections = workers*1.25+50` (CPU formula without PHP; a larger live ceiling is kept), `back_log` from the CPU formula, thread pool enabled.
- Logging: `slow_query_log`, `long_query_time=1`, `min_examined_row_limit=100`, `log_slow_verbosity=query_plan,explain` and `log_error` under `/var/www/logs/mariadb` with the AppArmor override (1.8.37, 1.8.47).
- The admin password reaches `mariadb` over stdin and `/etc/mysqlbkup.cnf` (`root:root 600`) through the environment; dumps are kept for 30 days (1.8.58, 1.8.59).

### Valkey / Redis
- Redis is tuned with the same logic when Valkey is absent (Valkey wins when both exist); if Redis is already installed, a Valkey install stops with a warning instead of removing it (1.8.1, 1.8.29).
- `valkey_apply_config` writes base + tuning on both paths: `io-threads` defaults to 1 (~118k SET/s and ~117k GET/s measured; higher values were no better) and is clamped 1..8, `maxclients` follows the PHP pool (10000 minimum), `tcp-backlog` comes from the CPU formula, RDB/AOF are off; `--optimize` applies runtime values with `CONFIG SET` and restarts only for startup-only keys (1.4.0, 1.8.28, 1.9.0).
- A local Unix socket (`unixsocketperm 770`) is created, `www-data` joins the service group and PHP-FPM is restarted only when that membership is new; application config is never edited, XenForo/WordPress/Laravel snippets are printed (1.8.37, 1.8.47).
- The optimizer report advises benchmarking XenForo's Redis session/registry cache: on a single host with local MariaDB it measured slower than DB-backed sessions (1.8.46, 1.8.52).

### Elasticsearch
- One managed heap file, `jvm.options.d/zz-setup-optimize.options`, is owned by both paths; a heap-only operator file is moved to `/tmp`, a richer one is kept and reported; `vm.max_map_count` is always persisted (1.8.21, 1.8.37, 1.8.52).
- `thread_pool.search.size` is CPU/2 and `thread_pool.write.size` CPU/4; the base YAML block, single-node `number_of_replicas=0` repair and index template are applied at install and by `--optimize` (1.8.4, 1.8.10, 1.8.52, 1.9.0).
- The effective HTTP endpoint is resolved from `http.host`/`network.host`/`http.port` (IPv6 bracketed) for every probe; active `http.host`/`transport.host` keys are commented so `network.host` controls the bind; a non-loopback bind is reported (1.8.37, 1.8.39, 1.9.0). `--restart-all` waits up to 300 s for the endpoint before starting the web tiers (1.8.47).

### OS, firewall, cron and purge
- `--optimize` applies the OS layer (CPU governor, skipped on virtual hosts; PAM nofile 1,048,576 matching `fs.nr_open`, written after sysctl; hardware-scaled sysctls) on 22.04, 24.04 and 26.04 (1.8.0, 1.8.14, 1.8.20, 1.9.0). `/etc/sysctl.conf` keeps one definition per key, writes `ipfrag_low_thresh` before the high mark, and uses `vm.dirty_background_bytes`/`vm.dirty_bytes` instead of ratios (1.8.21, 1.8.47, 1.9.0).
- TCP congestion control and qdisc default to BBR/fq, pinned per host with `SETUP_TCP_CC`/`SETUP_QDISC` or `/etc/default/setup-tuning`; `90-setup-network.conf` keeps the qdisc across package upgrades (1.8.16, 1.8.26).
- Swap is capped at 8 GiB (4 GiB on a VPS) with a 1 GiB floor (1.8.52, 1.9.0). `configure_io_tuning` sets THP to `madvise`, enables `fstrim.timer` on SSD/NVMe and installs a udev I/O-scheduler/readahead rule; `--purge` restores all of it (1.9.0).
- UFW rate-limits every effective `sshd -T` port with `ufw limit`; `--purge` never removes SSH rules (1.6.0, 1.8.16, 1.8.35, 1.8.47).
- Logs are centralised under `/var/www/logs/<service>/` with logrotate (1.6.0). The nightly ownership cron walks `/var/www` with `find` and prunes the logs tree; `--optimize`, `--restart-all` and `--basic` repair legacy ownership and regenerate managed cron entries, including the `*/5` wp-cron job (1.8.34, 1.8.37, 1.8.58).
- A security pass runs on every `--basic` and `--optimize`: `wp-config.php` `root:www-data 640`, `DISALLOW_FILE_EDIT`/`DISALLOW_FILE_MODS`, `DISABLE_WP_CRON`, `FORCE_SSL_ADMIN`, real salts, a per-site `wp_<db>` database user, webshell quarantine to `/var/lib/setup-quarantine/`, `unattended-upgrades` from `--basic`, and an audit of SSH password auth, public 80/443 and non-loopback Elasticsearch (1.8.30, 1.8.58).
- Nothing is permanently deleted: `--purge` stops and disables services and restores recorded originals but leaves packages, data, certificates and logs; rejected files are moved to `/tmp` by `retire_paths`; all scratch, the run lock and the 0700 `/tmp/setup-optimize-*` rollback copies live under `/tmp` (1.8.2, 1.8.21, 1.8.29, 1.8.30, 1.8.59).
- APT retries downloads, waits 300 s for the dpkg lock and repairs a half-configured dpkg state first (1.7.0, 1.8.16, 1.8.20).

### CLI, logging and tests
- `--optimize` is the single tuning entry point: it tunes only installed services, never installs or starts anything, backs up every touched directory, validates, reloads/restarts only active services, rolls back on failure, ends with health checks, and always writes `/var/log/setup-optimize-*.md` (1.6.9, 1.7.1, 1.8.14, 1.8.20). `--dry-run` needs no root and prints the values the real run writes (1.9.0).
- Real runs are serialised with a `flock` lock; every run mirrors stdout/stderr to `setup_<timestamp>-<pid>.log` with a redacted command line, host facts and the exit status (1.8.20, 1.8.31, 1.8.33, 1.8.49). Secrets never appear in the process list (1.8.59).
- `--diagnostics` reports absent MariaDB/Valkey/Elasticsearch as "not installed", resolves live log paths and ownership, and probes the configured Elasticsearch endpoint (1.8.37-1.8.47). `--optimize` audits `wp-config.php` and XenForo `src/config.php` for persistent DB connections and the Valkey socket, read-only (1.8.48).
- Missing tuning targets are recorded as `Not applied: ...`; em/en dashes in flags are normalised (1.7.0, 1.7.1, 1.8.0).
- Tests: `tests/test-tuning.sh` (with a second-run idempotency check), `tests/test-dry-run-matrix.sh`, embedded payload decoding, and the `tests/stress-site/` harness; `tools/diff_configs.sh` compares host configs against the repository; ShellCheck is clean at warning level in CI (1.4.0, 1.6.3, 1.7.1, 1.8.32, 1.9.0).

### Removed features
- `--harden-ssh`, `--cloudflare-only` and the fail2ban `sshd` jail (1.10.0); `--sync-angie` (1.8.54); the separate auto-tune mode, `auto_tune.sh` and the `nginx_conf.sh` deployer (1.6.9, 1.8.15, 1.8.51); `fail2ban`, `unattended-upgrades`, Composer and the `security` shorthand from `--others` (1.8.35); `legacy/basic_setup.sh` (1.6.12); the embedded Angie config archive (1.5.0); the automatic `<domain>` database (1.10.0); globally trusted APT keys (1.8.59).
- Defaults dropped: `cgi.fix_pathinfo=0` and global PHP session hardening (1.8.41, 1.8.43), `listen.allowed_clients` on socket pools (1.6.11), `--log-slow-admin-statements` (1.8.47), Angie access logs (1.6.1), the MariaDB 32 GB cap (1.8.8), RAM-percentage data-service plans and RAM/16 floors (1.8.57).
