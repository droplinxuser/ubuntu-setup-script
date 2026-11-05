# Ubuntu Setup Script

A single, idempotent Bash provisioning script for **Ubuntu 26.04 LTS** (and newer LTS releases such as 28.04). It installs and configures a complete web/database stack from one command. `--purge` stops and disables selected services and restores recorded basic settings, but it deliberately leaves packages, configuration, databases and logs on disk.

**File-safety policy:** every transient file is created under `/tmp`, and the script never unlinks, purges or otherwise permanently removes files or directories on the server. Anything left in `/tmp` is allowed to expire through the system's normal `/tmp` cleanup. `--purge` is therefore a stop/disable operation, not a destructive uninstall; remove data manually only after you have verified it is no longer needed.

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
| `server=dedi\|vps` | no | `dedi` also installs `cpufrequtils` and sets the CPU governor to `performance`. `vps` skips that step. If omitted, the script detects it with `systemd-detect-virt`, DMI product data and cgroup checks. |
| `host=FQDN` | no | Hostname set with `hostnamectl`. If omitted, the script generates one from the hardware: `<threads>c-<RAM_GB>g-<storage>` (for example `8c-32g-1T` for 8 threads, 32 GB RAM and 1 TB of disks). |
| `swap=SIZE` | no | Explicit swap file size, e.g. `8G`, `2G`, `512M`. If omitted, the script only adds swap when the current total is zero **or** below 50% of RAM, and sizes it so the total becomes 50% of RAM. |
| `time=REGION/CITY` | no | Timezone; defaults to `Asia/Manila`. |

Basic performs:

1. Writes its own `/etc/systemd/resolved.conf.d/dns_servers.conf` (`8.8.8.8`, `1.1.1.1`) and restarts `systemd-resolved`. Other resolver drop-ins are left untouched.
2. Updates Ubuntu and upgrades packages. Snapd and package caches are left alone.
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

Before changing basic settings, the script records the originals under `/var/lib/setup.sh/backup`. `--purge basic` restores them by overwriting the live files. `/swapfile` and its `/etc/fstab` entry are left enabled (`/var/lib/setup.sh/swapfile-managed`).

---

## Services

### Angie (`--angie`)

- Installs the Angie signing key and APT repository.
- Installs `angie`.
- Downloads [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx) once per run and delegates deployment to its `scripts/nginx_conf.sh`.
- The repository (not `setup.sh`) owns `angie.conf`, `h5bp/`, `conf.d/`, `http.d/`, `snippets/`, the cache/rate-limit settings, template repairs and the Cloudflare helper.
- Uses the repo's `scripts/limit_nofile.conf` and `scripts/etc_default_nginx` for the systemd `LimitNOFILE` drop-in and `/etc/default/angie`.
- The repo deployer creates cache directories, removes obsolete setup.sh/pre-refactor config filenames, runs `angie -t`, and reloads Angie.
- Configuration source overrides: `CONFIG_SOURCE_DIR=/path` (local checkout/testing), `CONFIG_REPO_URL=...`, `CONFIG_REPO_REF=main`.
- Generates `/etc/angie/http.d/cloudflare.conf` via the repo's `scripts/cloudflare.sh` and reloads Angie.

### PHP (`--php [ver=8.5] [children=auto|N] [max_requests=N]`)

- Adds the Sury APT repository (keyring embedded in the script).
- If `ver=` is omitted, selects the **latest stable PHP** available to APT from the Sury repository (currently 8.5; pre-release packages such as `8.6.0~rc3` are ignored).
- Installs the XenForo profile: `php<ver>-fpm`, `php<ver>-cli`, `php<ver>-opcache`, `php<ver>-mysql`, `php<ver>-gd`, `php<ver>-curl`, `php<ver>-xml`, `php<ver>-zip`, `php<ver>-gmp`, `php<ver>-mbstring`, `php<ver>-redis`. It does not install `intl`, `imagick`, `bcmath`, `apcu`, `igbinary`, `msgpack`, `sqlite3` or `bz2` unless you add them yourself.
  - OPcache/JIT settings in `custom_dan.ini` are active because `php<ver>-opcache` is installed. Add `php<ver>-intl` only if an add-on needs it.
- Deploys `www.conf` from `configs/php/www_<ver>.conf` and `custom_dan.ini` from `configs/php/custom_dan.ini`. Add a new `configs/php/www_<ver>.conf` to support a new PHP version. These are local non-Angie configs; no Angie repo fetch is needed for a PHP-only install.
- Fills in the dynamic values from `setup.sh`:
  - `pm.max_children = RAM_MB / 256` (~50% of RAM at 128 MB per worker), capped at `CPU threads × 8`
  - `pm.max_requests = CPU threads × 1024`
  - override either with `children=` / `max_requests=`
- Sizes OPcache, JIT and `memory_limit` from RAM instead of fixed 512 MB values:
  - OPcache 128–512 MB, JIT 64–256 MB, `memory_limit` 256–512 MB, realpath cache 4–16 MB.
- The repo templates provide OPcache file cache under `/var/cache/php/opcache`, `request_slowlog_timeout=5s`, `catch_workers_output=yes`, session hardening, `cgi.fix_pathinfo=0`, MariaDB Unix-socket defaults and `mysqlnd` statistics disabled.
- `setup.sh` creates the log/cache directories and the systemd `LimitNOFILE=524288`, `UMask=0027` drop-in. PHP-FPM and Angie use the Unix socket `/run/php/php-fpm.sock`.
- Sets the PHP timezone from `--basic time=`.
- Enables and restarts `php<ver>-fpm` and prints `php<ver> -v`.

**PHP version policy:** the pool listens on `/run/php/php-fpm.sock`, and the Angie `local_php` upstream points to the same socket. Therefore **only one PHP-FPM version can be active at a time**. You can install any version Sury provides (`ver=8.3`, `ver=8.4`, `ver=8.5`, ...), but to switch versions you must purge the old one first:

```bash
sudo bash setup.sh --purge --php ver=8.4
sudo bash setup.sh --basic ... --php ver=8.5
```

Installing a second version while the first is active is refused **before any packages are installed**, with a clear message instead of a cryptic “Address already in use” or a socket collision. Running multiple PHP-FPM pools simultaneously would require different `listen` ports and a matching Angie upstream per version; that is not automated.

### MariaDB (`--mariadb user=... pass=... size=4gb|auto [bind=...]`)

- Installs `mariadb-server` and `mariadb-client`.
- Adds a systemd `LimitNOFILE=1048576` drop-in and silences the package's unset-environment warning.
- Writes a managed `[mariadbd]` block into `/etc/mysql/mariadb.conf.d/50-server.cnf`:
  - `max_connections = CPU threads × 25` (clamped to 100–500)
  - `innodb_buffer_pool_size = size` (`size=auto` = 40% of RAM, minimum 256 MB)
  - `innodb_buffer_pool_instances` scaled 1–8 with the pool size
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

- If an existing `redis-server` is present, stops with a warning instead of purging it, because setup.sh never removes packages. Remove Redis manually first if you want Valkey; otherwise `valkey-server` is installed.
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

Benchmarks on this host showed that extra I/O threads are counterproductive for small web-cache commands: full-page throughput was 6.5k req/s with `io_threads=1` vs 5.1k with `io_threads=8`, while Valkey CPU rose from 64% to 430%. Raise `io_threads=` only after `valkey-benchmark` shows the main thread saturated.

For local PHP, prefer the Unix socket (`/run/valkey/valkey.sock`) over TCP. In the stress test it raised Valkey endpoint throughput from ~15k to ~29k req/s and removed most of the p99 tail caused by ephemeral-port/TIME_WAIT pressure.

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
- Writes `/etc/elasticsearch/jvm.options.d/jvm.options` with `-Xms<ram>`, `-Xmx<ram>`, G1GC, a 200 ms pause target and heap-dump-on-OOM.
- Writes `/etc/systemd/system/elasticsearch.service.d/limits.conf` with `LimitMEMLOCK=infinity`, `LimitNOFILE=1048576` and `LimitNPROC=4096`.
- Handles IPv6 hosts correctly when probing `http://[::1]:9200`.
- Writes `/etc/elasticsearch/scripts/xf-date-weighted.groovy`.
- Sets `vm.max_map_count=1048576` (persisted in `/etc/sysctl.d/99-elasticsearch.conf`).
- Enables/restarts Elasticsearch and waits for the HTTP endpoint to become ready.

With security disabled, keep `host=localhost` unless you really intend to expose port 9200. The script warns when a non-loopback `host=` is used; enable X-Pack security/TLS and a firewall before exposing it. The heap is also checked against 50% of RAM and a warning is printed if it is too large.

### Other packages (`--others ...`)

Available names: `smartmon`, `nvme`, `gif`, `nodejs`, `fail2ban`, `unattended`, `sysstat`, `composer`, `security`, or `all`.

| Name | Installs |
|---|---|
| `smartmon` | `smartmontools` (and tries to enable `smartd`) |
| `nvme` | `nvme-cli` — **only when the server is dedicated and the storage is actually NVMe**; otherwise skipped |
| `gif` | `gifsicle` |
| `nodejs` | NodeSource 26.x repository/key (embedded) and `nodejs` |
| `fail2ban` | `fail2ban` + `python3-systemd`, an SSH jail using the UFW ban action |
| `unattended` | `unattended-upgrades` plus a managed `/etc/apt/apt.conf.d/52setup-unattended` policy |
| `sysstat` | `sysstat` and its collect/summary timers (`sar`, `iostat`, `pidstat`) |
| `composer` | Composer 2 from the Ubuntu repository |
| `security` | shorthand for `fail2ban unattended` |

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

`--optimize` never installs, purges or starts a managed service. The only
package it may add is the small `cpufrequtils` helper when the CPU exposes
frequency scaling. It applies the OS profile first (CPU governor, PAM limits,
hardware-scaled kernel/network/memory sysctls) and then looks for:

- `angie` + `/etc/angie/angie.conf`
- every `/etc/php/<version>/fpm` tree
- MariaDB + `/etc/mysql`
- Valkey + `/etc/valkey/valkey.conf`, or Redis + `/etc/redis/redis.conf`
- Elasticsearch + `/etc/elasticsearch/elasticsearch.yml`

The OS profile is the same one used by a fresh `--basic` install: performance
CPU governor (when the host exposes cpufreq), the 1M-nofile PAM limits, and
the hardware-scaled sysctl set (socket buffers, backlogs, conntrack, file
descriptors, `vm.min_free_kbytes`, BBR/fq). It is idempotent and safe to run
on a live server.

It then applies the same hardware-aware service values used by a normal
install: Angie
workers/connections/buffers/cache sizes, PHP-FPM `static` pool sizing, MariaDB
buffer pool/connection backlog, Valkey/Redis maxmemory, and Elasticsearch
heap. It also applies the installer's systemd `LimitNOFILE` drop-ins for
Angie/PHP-FPM/MariaDB, raises `vm.max_map_count` for Elasticsearch, preserves
an explicit Valkey `io_threads` value, and disables caching/stale serving of
5xx responses in the WordPress and XenForo FastCGI caches. The Angie cache
budget is shared only across the cache types that are
actually present, so a dedicated proxy with one cache type gets the whole
budget. The share also scales with installed services: Angie-only uses 50%
of RAM / 10% of free disk, Angie+PHP only 30%, Valkey-only 50%, and the
shared profile 25%/10% capped at 8 GB. When PHP is absent, MariaDB receives
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
configuration change. Service allocations
are planned together from one 80%-of-RAM budget, with PHP worker capacity
reserved first, so MariaDB + PHP + cache + Elasticsearch cannot collectively
exhaust memory. Each configuration is
validated and active services are restarted only when their generated files
actually changed; a failure rolls back the affected service from
`/tmp/setup-optimize-*`. The final verification checks each service's
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

## Idempotency

The script is safe to re-run:

- APT operations are no-ops when packages are already current.
- `/swapfile` is reused if it already has the requested size.
- Auto swap is a no-op once total swap is at least 50% of RAM.
- Managed blocks in `crontab`, `50-server.cnf`, `elasticsearch.yml` and `valkey.conf` are replaced, not duplicated.
- A `--basic`-only re-run keeps the managed cron entries of services that are still installed; stale entries for removed services are dropped.
- Package-origin markers are retained for diagnostics, but `--purge` no longer removes any package regardless of origin.
- Package repositories and keys are re-written only when missing.
- Domain directories and databases use idempotent creation; existing Angie domain configs are preserved.
- PHP, MariaDB, Angie, Valkey and Elasticsearch services are restarted after configuration changes so changed parameters take effect. Angie and PHP-FPM use a graceful `reload` when possible, Valkey applies runtime values with `CONFIG SET`, and startup-only changes are deferred; a repeat `--optimize` run with unchanged files restarts nothing.

A second run is normally much faster than the first (typically under a minute for the full stack).

---

## Purge / stop

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

- `--purge --php ver=8.5` stops one version; `--purge php` discovers and stops every installed PHP-FPM version (not just 8.x).
- **Nothing is uninstalled or deleted.** Package purge/autoremove/clean calls were removed. `--purge` stops/disables the selected services, removes the managed cron entries, restores recorded basic settings where the original existed, and leaves packages, repositories, keys, Composer, configuration, certificates, databases, caches and logs on disk.
- `--purge all` runs every stop/restore step in a safe order.
- Bare targets and service flags are combined, so `--purge basic --php` stops both.
- `--purge others` only disables the managed cron/setup entries it knows about; optional packages, Node.js, repository files and Composer are left installed.
- `--purge angie` stops Angie and leaves `/etc/angie` (including domain vhosts and certificates), cache directories under `/home` and logs intact.
- `--purge valkey` stops Valkey and leaves the Unix socket, systemd drop-in, group membership, configuration and data intact.
- `--purge basic` restores files recorded in `/var/lib/setup.sh/backup` by overwriting them (never by unlinking the live path), leaves `/swapfile` and its `/etc/fstab` line enabled, removes only the managed cron block, restores the original UFW default policies, and disables UFW again if it was originally inactive. UFW rules that setup.sh added are still removed, except SSH rules.
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
| Pre-existing packages | `--purge others` kept a pre-installed `smartmontools`, removed only script-installed packages; safe after state deletion and repeated purges | PASS |
| MariaDB TCP login | admin user works via socket and TCP `127.0.0.1` with `skip_name_resolve=1` | PASS |
| Valkey hardening | loopback bind, `protected-mode yes`, no duplicate managed directives | PASS |
| Elasticsearch hardening | `bootstrap.memory_lock: true`, `LimitMEMLOCK=infinity`, heap ≤ 50% RAM warning | PASS |

Also checked at CLI level (all using `--dry-run`, no system changes):

- `tests/test-dry-run-matrix.sh` covers 67 cases: every service flag, every
  domain app type, per-domain and trailing group `app=` forms, every purge
  mode, `--optimize` and representative invalid inputs.

- `tests/test-tuning.sh` covers 29 cases: Angie directive rewriting, the
  multi-line `proxy_cache_path` fix, insertion anchors, miss reporting,
  PHP pool editing/deduplication, the shared memory budget and a second-run
  no-op check.

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
- Add HTTP/3 (QUIC) if clients support it (`listen 443 quic`, `Alt-Svc`, and `ufw allow 443/udp`). The distro Angie build lacks Brotli/zstd modules, so use precompressed gzip (`gzip_static on` is enabled) or install a build with those modules.
- Keep `client_max_body_size` and PHP upload limits aligned (both 100 MB now). Put Cloudflare or another CDN in front of static traffic and keep the daily Cloudflare real-IP refresh enabled.

**PHP**
- `disable_functions` now blocks `show_source,system,passthru,phpinfo`; add `exec,shell_exec,proc_open,popen,pcntl_exec` unless the application needs them. Chevereto video processing and some WordPress plugins may need `exec`/`shell_exec`, so test per application.
- Use `open_basedir` per vhost/pool, especially for multi-tenant hosting. The default pool is shared by every domain.
- Session hardening is enabled (`use_strict_mode`, cookies only, `HttpOnly`, `SameSite=Lax`). Add `session.cookie_secure=1` once every site is HTTPS-only.
- For production, set `opcache.validate_timestamps=0` and reload PHP-FPM on deploy to avoid per-request stat calls. Keep `expose_php=Off`.
- `memory_limit` is auto-sized to 256–512 MB. Lower it per application where possible; the worker count assumes ~128 MB average, and worst-case memory must still fit in RAM.
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
- Use SSH keys only, disable password login, keep UFW limited to 22/80/443, and add fail2ban or equivalent for SSH and web auth endpoints. `--others fail2ban` installs an SSH jail with the UFW ban action; `--others unattended` enables automatic security updates.
- Remove the mDNS (`5353/udp`) and WS-Discovery (`3702/udp`) UFW rules if you do not need them; they were pre-existing on this host, not added by the script.
- Enable `unattended-upgrades` for security patches and monitor reboot-required. Keep the kernel/firmware updated. `libgd3` is currently held back by the apt phasing/upgrade policy; review it before the next PHP/GD upgrade.
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

`--purge others` no longer removes any package, repository, key or Composer file. It only stops the managed optional services and leaves Node.js, `smartmontools`, `nvme-cli`, `gifsicle`, `fail2ban`, `unattended-upgrades`, `sysstat` and `composer` installed. Remove them manually with APT only after confirming nothing needs them.

### `--purge --php` and Composer

PHP purge stops the selected PHP-FPM versions and leaves Composer, its `php-*` library packages and all PHP configuration in place. Re-running `--php` reuses that installation; if you truly want Composer removed, do it manually after the purge.

### Rate limiting returns 429 on a site behind Cloudflare / a proxy

The per-IP limiter keys on the direct client address. If all traffic arrives through a CDN or reverse proxy, enable the real-IP configuration for that proxy first (`/etc/angie/scripts/cloudflare.sh` for Cloudflare) and include `cloudflare.conf` in the vhost. Loopback is always exempt. Tune `limit_req` rates in `/etc/angie/http.d/limit_req.conf` and the bursts in `/etc/angie/h5bp/limit_req/*.conf`.

### PHP-FPM slow log fills with queued requests

`request_slowlog_timeout=5s` measures from accept, so a full listen queue can log requests that are simply waiting for a worker. Check `/fpm-status` (if enabled) for `listen queue`/`max listen queue` and add workers, cache the endpoint, or reduce upstream latency. A slow log entry is not automatically a bug in that script.

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
| `/var/lib/setup.sh/backup/` | Original basic files saved before `--basic` changes |
| `/var/lib/setup.sh/original-hostname`, `original-timezone` | Values restored by `--purge basic` |
| `/var/lib/setup.sh/ufw-*` | UFW active state, added rules and default policies used by purge |
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
| `/etc/fail2ban/jail.d/setup-ssh.local` | Fail2ban SSH jail (when `--others fail2ban`) |
| `/etc/apt/apt.conf.d/52setup-unattended` | Unattended security-update policy (when `--others unattended`) |
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
