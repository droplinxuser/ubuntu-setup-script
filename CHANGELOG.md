# Changelog

Release notes for ubuntu-setup-script. Current behaviour is documented in
README.md; measurements in tests/stress-site/RESULTS.md.

## 1.20.5 (2026-11-11)

Fix `--optimize` failing on Angie when an operator `http.d` file duplicates a
single-instance directive that the canonical tree also sets.

- **Symptom.**  On a live host, a custom `http.d/zz-pixvid-ratelimit.conf`
  carried `limit_req_status 429` and `limit_req_log_level info`, while the
  synced `http.d/limit_req.conf` defines the same http-context directives.
  `angie -t` returned
  `[emerg] "limit_req_status" directive is duplicate in .../zz-pixvid-ratelimit.conf:20`;
  the repository sync rolled the whole `/etc/angie` tree back and the run
  exited 1.
- **Fix.**  `tune_angie_dedupe_http()` scans the active `http.d/*.conf` files
  for the single-instance directives (`limit_req_status`, `limit_conn_status`,
  `limit_req_log_level`, `limit_conn_log_level`, `limit_req_dry_run`,
  `limit_conn_dry_run`).  When a directive appears more than once it keeps the
  canonical `limit_req.conf` occurrence (otherwise the first file in include
  order) and comments the other copies with
  `# setup.sh: duplicate <directive> (kept in <file>)`.  It runs both after the
  repository sync (before the deployer's `angie -t`) and at the end of the
  hardware tuner, because the tuner can add `limit_req_log_level` itself.
- A unique directive in the operator file is left untouched; only real
  duplicates are commented, and the tree is already snapshotted for rollback.
- Existing hosts get the repair on the next `--optimize` / `--angie` run.
  **627/627 tuning checks and 173/173 CLI/dry-run checks pass.**

## 1.20.4 (2026-11-11)

Fix the managed cron redirection for the WordPress and XenForo job runners.

- **Before:** `write_cron()` generated
  `… done || true >/dev/null 2>&1`.  Shell precedence applies the redirect to
  `true`, not to the `find | while` pipeline, so `find`/`dirname` errors still
  went to cron mail (the per-run PHP command had its own redirect).
- **After:** the redirect precedes the fallback:
  `… done >/dev/null 2>&1 || true`, so the whole pipeline is quiet while a
  failed lookup still leaves the job successful.
- Existing hosts get the corrected line on the next `--basic` or
  `--optimize` (the managed block is regenerated); `--purge basic` removes it.
- New tuning checks cover the generated XF line and the WordPress/XF source
  form; **623/623 tuning checks and 173/173 CLI/dry-run checks pass**.

## 1.20.3 (2026-11-11)

Fix the hardening step looking hung on hosts with a large `0666` file tree.

- **Symptom.**  `setup.sh --optimize` on a 12-thread / 64 GiB XenForo host
  (1 642 020 files under `/var/www`, 598 757 of them world-writable) spent
  ~9 minutes with no output, then finished successfully.  The run was not
  deadlocked: `find … -print0` and the `while read` loop were progressing
  (the pipe write counter rose, the remaining match count fell from 47 635 to
  27 273 to 0), but the loop forked one `chmod` process per path.
- **Fix.**  `harden_wordpress_files()` now counts the matches without
  forking (`-print0 | tr -cd '\0' | wc -c`), fixes them with
  `find … -exec chmod o-w {} +` (one process per ARG_MAX chunk instead of
  one per file), logs the count before the batch, and keeps the same
  "world-writable entries fixed: N" report line.  On the audit host the
  598 757 chmod forks become a few hundred.
- **Why the files were 0666.**  The attachment tree was restored/uploaded
  with an open umask; the hardening pass is the intended repair.  Nothing
  else in the step changed.
- New tuning checks assert the batched form and the pre-fix count line;
  **619/619 tuning checks and 173/173 CLI/dry-run checks pass**.

## 1.20.2 (2026-11-11)

Fix a `--optimize` failure on hosts whose vhost still uses an upstream name
that the canonical Angie tree renamed or dropped.

- **Symptom.**  `setup.sh --optimize` synced `/etc/angie` from
  `server-configs-nginx`, then `angie -t` failed with
  `[emerg] host not found in upstream "soketi_websocket"` and the run rolled
  the whole tree back (exit 1) — on a live host (Angie 1.12.4, Ubuntu 22.04,
  3 vCPU) whose custom `soketi.example.com.conf` proxies to
  `http://soketi_websocket`.  The repository's `http.d/xf_websocket.conf` now
  defines `xf_websocket` and `xf_websocket_so`, so the rsync overwrote the
  operator-edited file that used to define the old name.
- **Fix.**  `deploy_angie_tree()` snapshots every `upstream NAME { ... }`
  block before rsync, compares the names still referenced by deployed vhosts
  with the names the new tree defines, and writes the missing blocks to one
  managed include, `http.d/zz-setup-preserved-upstreams.conf` (zone names
  stripped so a zone cannot collide).  The include is regenerated on every
  install/`--optimize`, left byte-identical when nothing changed, and moved
  out of the tree once the canonical tree defines the name again.
- **Scope.**  Only bare upstream names are considered (`proxy_pass`,
  `grpc(s)_pass`, `uwsgi_pass`, `scgi_pass`, `fastcgi_pass`); `host:port`,
  `unix:` paths and `$variables` are ignored.  A fresh install has no
  previous tree to preserve from and behaves exactly as before.
- New tuning checks cover the snapshot, restore, idempotence and removal
  paths; **616/616 tuning checks and 173/173 CLI/dry-run checks pass**.

## 1.20.1 (2026-11-11)

Refactor and validation release. **No configuration value changed**: a fresh
install and `--optimize` still produce a byte-identical tree and identical
effective values (375 managed files / 942 values, zero diff), and a second
`--optimize` changes nothing. **609/609 tuning checks and 173/173 CLI/dry-run
checks pass**; ShellCheck is clean at `-S warning`.

- **One compare/commit helper.**  `commit_if_changed()` in `lib/common.sh`
  replaces eleven copies of the stage-under-/tmp, `cmp`, `cat > live`,
  `tune_note` block (`tune_replace`, `tune_insert_after`, `tune_ensure_line`,
  `tune_pool_set`, `tune_pool_dedupe`, the rate-limit, cache, keepalive,
  static-asset, precompress and MariaDB duplicate-key writers).  Every writer
  still keeps the live inode and every tuner still reports a change only when
  the bytes differ, so service reloads are unchanged.
- **One PHP extension classifier.**  `--upgrade-php` maps the installed
  extension set in the real plan and in `--dry-run` through
  `php_upgrade_classify_package()`; the dry run no longer carries its own
  copy of the core-extension table.  The duplicated table had drifted:
  OPcache was reported missing on a 9.x target even though it is bundled
  from 8.5 on.
- **One apply order.**  `INSTALL_ORDER` and `OPTIMIZE_ORDER` in `lib/cli.sh`
  drive the installer and `run_optimize()` loops; `--purge` keeps its own
  dependency order.  The two inline lists could (and did) drift.
- **Module split.**  The per-service optimize/verify/profile code moved out
  of `lib/security.sh` (88 KB of two unrelated responsibilities) into
  `lib/service-optimizers.sh` (Angie, PHP-FPM, MariaDB, Valkey/Redis,
  Elasticsearch, verification and the Markdown report).  `lib/security.sh`
  now owns hardening only.  Both are sourced by `setup.sh`; no function was
  renamed.
- **Fixed: `--dry-run --upgrade-php` could exit 141 (SIGPIPE).**  The target
  candidate was read with `apt-cache policy ... | awk '...; exit'`; under
  `set -o pipefail`, awk closing the pipe killed apt-cache with SIGPIPE and
  a successful dry run reported FAILURE.  The parser now reads the whole
  policy output.  Caught by `tests/test-dry-run-matrix.sh`.
- **Audit on the 16-thread / 27.8 GiB / NVMe host.**  Full stack plus
  XenForo 2.3.13 and WordPress 7.1.4 from the local archives.  JIT tracing
  is +4.8% over off (606 vs 578 thread req/s); 16 static workers is the
  throughput peak (616 req/s; 20 -> 600, 24 -> 582); `validate_timestamps=0`
  and `catch_workers_output=no` measured neutral; XF-in-Valkey (-7/-11%) and
  the WP Redis object cache (-7%) are slower on a single local-DB host and
  were reverted.  Details: `tests/stress-site/TUNING-20261111-1.20.1.md`.
- **`--upgrade-php` re-tested in both directions** (8.5 -> 8.4 -> 8.5,
  1m10s / 59s) with managed files identical to the pre-upgrade tree after
  version normalisation; see `tests/upgrade-php/RESULTS-20261111-1.20.1.md`.

## 1.20.0 (2026-11-11)

New standalone mode: **`--upgrade-php=X.Y`** replaces the installed PHP with
another version in place, keeping the operator's extension set and custom
configuration, and applies the same hardware profile as install/`--optimize`.
Audited on the 16-thread / 27.8 GiB / NVMe host with PHP 8.4 -> 8.6 (RC) and
8.6 -> 8.5, plus a no-PHP host where the mode performs a fresh install.
**609/609 tuning checks and 173/173 CLI/dry-run checks pass**; ShellCheck is
clean at `-S warning`.

- **New mode and CLI.**  `--upgrade-php=8.6` and
  `--upgrade-php 8.6` are accepted (only once); the version must be 8.1+ and
  the mode is standalone.  `--dry-run` prints the detected packages,
  extension mapping, purge/install steps and target candidate without
  touching the host.  Conflicts with install flags, `--optimize`, `--purge`,
  `--diagnostics`, `--restart-all` and `--domain` fail before any change.
- **Package/extension preservation.**  The run snapshots every installed PHP
  package with its exact version, the extension inventory (and the
  `apt-mark showmanual` flag), operator `.ini` drop-ins, extra FPM pools, the
  PECL list and `/etc/php` under `/var/lib/setup.sh/php-upgrade-<ts>/`, then
  maps each extension to `phpX.Y-<ext>`.  A target that does not publish an
  extension (PHP 8.6.0~rc5 shipped only the 30 in-tree extensions: no
  `redis`, `igbinary` or `apcu`) installs the rest and exits non-zero with
  `ATTENTION` and the exact list, so monitoring catches the gap.
- **Dependency purge is a delta, not a blanket autoremove.**  Every `php*`
  package and `libapache2-mod-php*` is purged, then only packages that became
  newly orphaned (before/after `apt-get -s autoremove`) are removed.
  Pre-existing unrelated autoremove candidates survive, and a core-package
  deny list guards against a parsing accident.
- **Custom configuration is validated before it goes live.**  Operator-owned
  regular `.ini` files in `conf.d` (plus their cross-SAPI symlinks) and extra
  `pool.d/*.conf` files are migrated with version paths rewritten.  `dpkg -S`
  cannot identify Sury's postinst-generated files, so package-owned entries
  are recognised as symlinks instead.  `php-fpm -t` validates the migrated
  set; rejected files are moved out of the live tree with the reason.  FPM is
  reloaded afterwards, which fixes the case where a migrated extra pool
  existed on disk but had never bound its socket (found in the 8.6 -> 8.5
  audit).
- **Timezone continuity and parity fix.**  The upgrade keeps the old tree's
  `date.timezone` instead of re-deriving it from the host, and
  `sync_php_ini_template` now prefers `timedatectl` over the legacy
  `/etc/timezone` (on 26.04 the latter can stay at the image's zone while
  `timedatectl` reports the live one; `--optimize` used to rewrite the zone
  an install had just written).
- **A lagging optional extension no longer breaks a PHP install.**  `redis`
  moved out of the mandatory package set in `install_php`: the core packages
  are installed first, then each optional/extra package is checked with
  `apt-cache show` and skipped with a warning when the target repository has
  not published it.  This also protects a plain `--php ver=<new major>`.
- **Verified parity and rollback.**  On the audit host the upgraded
  `/etc/php/8.5/fpm/pool.d/www.conf`, `conf.d/zz-setup-optimize.ini`,
  `conf.d/custom_dan.ini` and the systemd limits drop-in are byte-identical
  to a fresh `--basic --php ver=8.5` install, and a following `--optimize`
  changed nothing.  A failed 8.6 install on the first attempt (missing
  `php8.6-redis`) rolled back to 8.4 automatically with the old tree and
  packages intact; the rollback also removes a partially installed target
  first.
- **`configs/php/www_86.conf`** added so the 8.6 example resolves the same
  pool template as every other version.

## 1.19.2 (2026-11-11)

Audit on a freshly restored 16-thread / 27.8 GiB / NVMe bare-metal host
(Ubuntu 26.04.1, PHP 8.5.12-FPM, Angie 1.12.4, MariaDB 11.8.6, Valkey 9.0.4,
Elasticsearch 9.5.6, WordPress 7.1.4 and XenForo 2.3.13 from the local
archives).  Fresh install 3 min 23 s (4 min 11 s on the first run, before
the apt cache was warm), `--optimize` 12-13 s.  Tests: **601/601
tuning checks and 161/161 CLI/dry-run checks pass**; ShellCheck is clean at
`-S warning`.

- **Run log no longer empties itself under `sudo` in a sticky directory.**
  A run started from `/tmp` wrote a 0-byte `setup_*.log` and logged a false
  `[ERR] command failed (exit 1) at line 148: tee -a "$RUN_LOG_FILE"` after a
  successful install.  `start_run_log` handed the log to `SUDO_UID` before
  `tee` opened it; with `fs.protected_regular=2` (a value this script itself
  writes) the kernel refuses root's `O_CREAT` open of a file owned by another
  user in a sticky world-writable directory, so `tee` failed and the mirror
  was lost.  The file now stays root-owned for the whole run and is handed to
  the invoking user in `finish_run_log` after the ANSI-strip rewrite.  The
  `tee` subshell clears the inherited ERR trap, so a consumer that closes the
  pipe (`setup.sh --help | head`) no longer emits a second, false error for a
  run that already succeeded.
- **Five duplicated CLI key=value loops collapsed into `kv_consume`.**
  `--basic`, `--php`, `--mariadb`, `--valkey` and `--elastic` shared the same
  validation/shift logic (with `--mariadb bind=` continuation as the only
  special case); one helper now owns it and `parse_args` advances by the
  returned count.  No behaviour change (161/161 matrix checks pass).
- **Every module declares `# shellcheck shell=bash`** and documents the
  cross-module globals that made SC2034 fire.  Six optional-argument helpers
  and the `OPT[php.ver]` associative key are annotated locally.  `shellcheck
  -S warning` on `setup.sh`, `lib/*.sh`, the tests and the stress harness is
  now silent; the test file's `VAR= cmd` forms use an explicit `VAR=''`.
- **Install/optimize parity re-confirmed.**  A 3 812-line snapshot (`/etc`
  digests, units, sysctls, crontab, PHP runtime, MariaDB variables, Valkey
  config, Angie checksums) around the first `--optimize` differed in 144
  lines, every one a volatile counter (`fs.dentry-state`, `fs.inode-*`,
  `fs.quota.*`, `kernel.ns_last_pid`, `nf_conntrack_count`, memory/fd
  numbers).  Re-checked with the final 1.19.2 tree on a second clean install:
  144 lines, same volatile set.  A later `--optimize` after both applications
  were deployed reported "configuration already optimized" for every service.
- **Tracing JIT at PHP's default hotness stays the best configuration**
  (authenticated XenForo thread, 100 connections, 8 s, `oha` from the LAN):
  tracing/64 MB **614 req/s at 22.73 ms PHP CPU/request**, JIT off 580 at
  24.53 (+5.9%), function JIT 569 at 24.88 (+7.9%).  Tracing with 32 MB
  (616), 128 MB (612), aggressive 16/64/8/32 (617), conservative
  128/255/32/128 (619), root traces 256 (607) / 1024 (610), side traces 128
  (609), polymorphic calls 4 (615) and a combined profile (602) are all
  within the ±2% noise; none justifies changing `php_jit_settings` or
  `php_jit_threshold_lines`.
- **PHP-FPM 1.0 worker per logical CPU is confirmed on the CPU-bound tier:**
  8 workers 412 req/s, 12 -> 511, **16 -> 572**, 20 -> 574, 24 -> 548.  PHP-FPM
  consumed ~1 100% of one core (11 of 16 CPUs), MariaDB 135% and Angie 14%:
  the authenticated ceiling is per-request PHP execution, not pool depth, so
  `pm.max_children` stays hardware-sized and extra workers only raise CPU per
  request.
- **Test harness:** `set-jit.sh` gained the multi-tracer limit profiles
  (`roots256`, `roots1024`, `poly4`, `side128`, `combined`); new
  `jit-sweep.sh`, `fpm-sweep.sh` and `set-fpm.sh` make both sweeps
  reproducible, and `set-fpm.sh` restores the pool on exit or interruption.
  `bench-one.sh` no longer needs passwordless sudo for its server-side CPU
  sampler (it only reads cgroup and `/proc`).
- **Guest caching remains the largest lever:** XenForo guest 4 713 req/s vs
  1 084 uncached, WordPress 3 335 vs 273 (12.2x).  No Angie error, PHP-FPM
  slow request, MariaDB slow query, OOM kill and no `max children reached`
  during the final suite.

## 1.19.1 (2026-11-11)

Re-validation on the same 16-thread / 27 GiB / NVMe bare-metal host, this
time with PHP 8.5.12-FPM, Angie 1.12.4, MariaDB 11.8.6, Valkey 9.0.4,
Elasticsearch 9.5.6, WordPress 7.1.4 (400 posts / 100 users) and XenForo
2.3.13 (200 threads / 2,600 posts / 60 users).  Fresh install 2 min 56 s,
`--optimize` 11 s.

- **Install/optimize parity re-confirmed.**  A 3 794-line state snapshot
  (`/etc` digests, unit states, sysctls, PHP runtime, MariaDB variables,
  Valkey config, Angie checksums) taken after install and after the first
  `--optimize` differed only in volatile kernel counters (`fs.dentry-state`,
  `fs.inode-nr`, `fs.quota.*`, `kernel.ns_last_pid`, `kernel.random.uuid`,
  `nf_conntrack_count`).  A later `--optimize` after the applications were
  deployed changed no managed file and reloaded nothing ("configuration
  already optimized" for every service).
- **The 1.0-worker-per-core and tracing/64 MB choices hold on PHP 8.5.12.**
  XenForo member thread at 100 connections: 16 workers 860 req/s at
  16.10 ms PHP CPU/request, 8 workers 578 at 12.78 (six cores idle), 20/24/32
  workers 827/802/808 at 17.0-17.5 ms.  Tracing JIT 64 MB 872 req/s at
  15.81 ms against 821 at 17.11 with JIT off (+8.2% PHP throughput), 787
  with function JIT, and 858-869 for the aggressive/conservative threshold
  sets; 32/128 MB were within noise.  WordPress member: 300 req/s at
  50.0 ms with tracing, 284 at 54.0 with JIT off.
- **Guest caching is still the largest lever.**  Dedicated runs: XenForo
  guest 7 451 req/s (0.10 ms Angie/request) against 901 uncached (9.13 ms
  PHP); WordPress guest 5 308 against 272 uncached (12.6-19x).  Full-suite
  numbers are lower on the shared Wi-Fi link (4.7k/3.3k) and are reported
  as link-bound.
- **Brotli level 3 is the better CPU/bytes point for cached WordPress.**
  Level 4 = 0.921 ms Angie CPU/request and 13 396 bytes, level 3 = 0.603 ms
  and 14 000 bytes (-35% CPU, +4.5% bytes), level 2 = 0.545 ms and 14 399
  bytes.  The shipped default stays 4 (the 1.18.0 measurement was on a
  proxy-fronted origin); `SETUP_BROTLI_LEVEL=3` is the operator override for
  a CPU-bound direct origin.
- **Test harness correctness.**
  `sample-cpu.sh` counted the idle field of `/proc/stat`, so every report
  claimed "host CPU used" equal to all cores regardless of load; it now sums
  user/nice/system/irq/softirq/steal only.  `run-stress-remote.sh` warms the
  cache and OPcache for two seconds before each scenario, runs the 1 s
  `slow` scenario last (its 200-connection backlog used to poison the next
  scenario: p99 1.9 s on the XenForo member thread page), and emits an error
  row instead of silently dropping a scenario when oha's JSON cannot be
  parsed.  `bench-one.sh`, `set-jit.sh`, `deploy-apps.sh`, `seed-xf.php`
  and `seed-wp.php` make the sweep reproducible.
- **Dead assignments removed** in `tune_xf_cache_bypass_var` (`before`) and
  `optimize_mariadb` (`logsize`); no behaviour change.

## 1.19.0 (2026-11-10)

Audit of the 16-thread / 27 GiB / NVMe bare-metal host (`audit-host`,
Ubuntu 26.04.1, PHP 8.4.27-FPM, Angie 1.12.4, MariaDB 11.8, Valkey,
Elasticsearch 9.5) with WordPress 7.1.4 and XenForo 2.3.13 deployed from the
local archives. Load ran from a macOS workstation over TLS and from the host
over loopback; CPU is the host's busy-jiffy delta per successful request.

- **PHP-FPM depth follows what the host can block on, not a flat 2/core.**
  Measured on the XenForo member page (loopback, 64 connections, 20 s):
  16 static workers **834 req/s at 14.38 ms host CPU/request**, 20 workers
  825 at 14.97, 24 workers 819 at 15.29, 32 workers **808 at 15.68**.
  The same direction held for the XenForo thread page (470 vs 446 req/s) and
  the WordPress member page (298 vs 282). The target is now 1.0 worker per
  logical CPU for a local database on flash, 1.5 for a shared/virtual CPU or
  a database on another host, and 2.0 for spinning disks;
  `SETUP_PHP_WORKERS_PER_CPU` pins the factor and `--php children=` still
  wins. Install and `--optimize` share the one helper, so both write 16 on
  the audit host.
- **One owner per php.ini directive.**  `configs/php/custom_dan.ini` set
  `opcache.jit = disable`, `memory_limit`, the OPcache sizes and the mysqlnd
  sockets while the managed `zz-setup-optimize.ini` set different values for
  the same keys; which one a worker used depended on whether the zz file
  existed. The template now keeps only directives the managed profile does
  not own.
- **Duplicated implementations collapsed.**  The 27 inline
  `md5sum … | awk '{print $1}'` copies use `file_md5`; the MariaDB online-key
  ERE is derived from the SET order array instead of being maintained twice;
  the four copies of the memory-plan summary are one helper; Valkey config
  reads go through `valkey_conf_get`; and `service_mem_mb`'s stand-alone
  fallbacks use the planner's own MariaDB/Valkey floors.
- **Re-install now matches `--optimize`.**  `configure_mariadb` strips the
  duplicate performance keys from `50-server.cnf` on install too (previously
  only `--optimize` did), and a re-install preserves an operator's
  `maxmemory-policy`/`io-threads` instead of resetting them to the defaults.
  Swap sizing honours a cgroup memory limit instead of `/proc/meminfo`.
- **FrankenPHP measured, not adopted.**  FrankenPHP 1.13.5 (PHP 8.5.12,
  classic mode, same tree and database, loopback TLS) served the same member
  page at **688 req/s / 21.7 ms** against **852 req/s / 17.4 ms** for
  Angie+PHP-FPM; 32 threads reached 702 req/s. Its worker mode is not
  compatible with XenForo/WordPress request lifecycles. Details in
  `SECURITY-PERFORMANCE.md`.
- **OPcache JIT re-confirmed.**  On this host, tracing/64 MB with PHP's
  default hotness thresholds used 15.56 ms PHP CPU/request against 16.26 ms
  with JIT off (+3.2% throughput); 128 MB was within noise, aggressive
  thresholds were slightly worse, and function JIT lost 7.7%.
- **Validation.**  601 tuning tests and 161 CLI/dry-run checks pass; a fresh
  install followed by `--optimize` produced an identical `/etc`, unit,
  crontab, PHP, MariaDB and Valkey state (only volatile kernel counters
  differ).

## 1.18.0 (2026-11-10)

Audit of a second live XenForo origin (64-thread Xeon, 128 GiB, RAID10,
Ubuntu 24.04, PHP 8.0.30-FPM, Angie 1.12.4, MariaDB 10.11, Valkey 7.2,
sessions in Valkey via the SV/RedisCache add-on, about 230 000 threads and
800 000 posts), focused on the member pages the FastCGI cache cannot serve.
Load ran on the host through loopback; CPU per request is each service's
cgroup `usage_usec` delta.

- **Report the pool right-sizing, with the memory it returns.**  The host ran
  **512** static workers: 51.8 GB resident (~103 MB each) on 64 threads.
  64 workers served the same request rate with **p50 298 -> 70 ms** at 256
  connections and brought the pool's resident memory to **~4 GB**; 128
  workers landed in between (p50 138 ms).  `--optimize` had been writing the
  right number for releases, but the change was silent in the report; it now
  prints `pool right-sized 512 -> 64 workers (~51 GB -> ~6 GB resident at
  103 MB each)` so an operator sees what the reload returns.
- **PHP-FPM: at least 2 workers per logical CPU on every host.**  `pm` stays
  `static` and the count is now the same floor and target for every server -
  a XenForo/WordPress host with a local database included - so a fresh
  install and `--optimize` always write the same value.  A pool sized by hand
  is normalised to the rule (the audited 64-thread board was left on 512
  static workers, 51.8 GB resident; the plan is 128, and the report names the
  before/after and the memory the reload returns).  `--php children=` still
  wins, clamped to floor..max(512, 2 x CPUs).  The application-specific
  1-per-CPU cap and the live-pool override are gone: both could make two
  commands write different pools on the same host.
- **Capacity tuning without a database restart.**  `innodb_io_capacity`,
  `innodb_io_capacity_max`, `table_open_cache`, `max_connections`,
  `thread_pool_size` and `innodb_flush_neighbors` are dynamic in the
  supported MariaDB releases, so they join the online `SET GLOBAL` path
  (each value is read back; a rejection falls back to the restart).  On the
  live 64-thread board that removed the restart the capacity profile would
  otherwise have needed.
- **Install and `--optimize` re-verified end to end.**  A fresh install on a
  clean 16-thread host followed by `--optimize` produced a byte-identical
  1 017-file `/etc` tree, identical unit states, root crontab, PHP runtime,
  MariaDB variables and Valkey settings (no diff line at all).
- **Hermetic test for the MariaDB connection ceiling.**  The
  `max_connections` unit tests read the live `@@max_connections` when a
  MariaDB server happened to be running (a deliberate production rule: never
  lower a live ceiling), so they failed on a host with a busy database.  The
  tests now stub the client and assert the formula on any host.
- **Measured, not adopted: the board index is an add-on problem.**  On this
  board the index page costs **~1.1 s of MariaDB CPU per member view**: two
  third-party statements scan `xf_user` (~67 000 rows, 119 ms) and all
  `xf_thread` rows through a shop add-on's ban table (233 846 rows, 338 ms).
  That is application schema/ACP work, not infrastructure, and setup.sh never
  alters an application schema.  The JIT question was also left alone: on
  PHP 8.0 the tracing JIT measured anywhere from 5 % better to 45 % worse
  than the JIT off under live traffic, which is not enough evidence to change
  the default.

## 1.17.0 (2026-11-10)

Audit of the live **forum.example.com** XenForo origin (8-thread Xeon E3-class,
32 GiB, RAID, Ubuntu 26.04, PHP 8.5.12-FPM, Angie 1.12.4, MariaDB 11.8,
Valkey 9, XenForo 2.3.13 + XFMG 2.3.9, about 48 000 users, about 3 500 threads, about 74 000
media items), focused on the pages the FastCGI cache cannot serve: the gallery
index and thread pages as a member.  CPU per request is each service's
systemd cgroup `usage_usec` delta; the load generator ran on the host through
loopback because the origin is reachable only through its front proxy.

- **XFMG gallery count is the member-side database hotspot (reported, not
  automated).**  The gallery index asks for its pagination total with a
  `COUNT(*)` over `xf_mg_media_item` filtered by `media_state`, an
  `album_state = 'visible' OR IS NULL` pair and every visible `category_id`.
  With the shipped indexes MariaDB chose a full scan: 47.7 ms per view, and
  383 of 391 slow queries during a 6 s gallery load (18.3 of 18.4 slow
  seconds).  A covering `mg_count_cover (media_state, album_state,
  category_id)` turns it into a 55 482-row index-only range scan at 23.4 ms;
  end to end the uncached gallery index went from **62 to 90 req/s (+45 %)**,
  p50 130 -> 88 ms and MariaDB CPU 54.0 -> 30.4 ms per request.  **setup.sh
  does not apply it**: no `ALTER TABLE`, index creation or data change on an
  application schema.  The README lists the exact statement under *Manual
  follow-ups* so the operator can run it in a maintenance window.
- **JIT re-validated on a Xeon.**  Tracing + 64 MB + PHP's default thresholds
  64/127/16/64 is 14 % cheaper per thread page than the JIT off (43.8 vs
  50.1 ms PHP) and 13 % cheaper than the function JIT; 32/128 MB buffers and
  the aggressive/conservative threshold sets stayed within noise.
  `opcache.validate_timestamps=0` measured 2.5 % and is **not** adopted: it
  turns every deploy into a manual OPcache reset.
- **Worker count.**  8, 12 and 16 workers measured within 1 % of each other
  on this 8-thread host (142-144 req/s, 42.6-43.0 ms PHP), so the 1.16.0
  one-worker-per-thread rule is safe here; the database, not the pool, was
  the bottleneck.
- **What did not help (measured, left alone).**  Brotli stays at level 4:
  compression is ~4 ms of Angie CPU per thread page but the front proxy link
  is the binding constraint for bytes.  XFMG `X-Cache` for members, session
  storage in Valkey and `opcache.preload` were not attempted: the first is
  session-specific, XenForo has no session cache backend, and preloading
  third-party framework code on a live board is a startup-fatal risk.

## 1.16.0 (2026-11-10)

Third audit, on a clean Ubuntu 26.04 host (Ryzen 7-class, 8 cores / 16
threads, 27 GiB, NVMe) with a real XenForo 2.3.13 (600 threads, 2 983 posts,
201 members) and WordPress 7.1.4 (401 posts) deployed from the local archives.
CPU per request is the service cgroup's `usage_usec` delta, so the numbers do
not depend on the client link; see `tests/stress-site/RESULTS.md`.

- **PHP-FPM workers: one per hardware thread on application hosts, two per
  thread otherwise.**  16 workers served 1 044 member req/s at 11.20 ms PHP
  per request, 24 gave 1 000/11.87, 32 gave 936/12.27 and 48 gave
  627/20.25 (thread page); 200-connection runs agreed (1 046 vs 996 req/s).
  The old `2 per logical CPU` application cap and the `16/8 per core`
  generic ceiling both oversubscribed the run queue.  WordPress moved the
  same way (51.6 -> 57.6 ms PHP per request at 32 workers).
- **Install and `--optimize` now write the same pool.**  A fresh install
  planned a 64 MB reservation per worker and derived 144 workers on a
  16-thread host; the first `--optimize` measured ~96 MB and wrote 32, so the
  same host had two different pools.  The worker count now comes from
  CPU/RAM/apps only (`php_children_ceiling`): 2 per thread generic, 1 per
  thread for local-database XenForo/WordPress, bounded by RAM/2 at 96 MB and
  an explicit `children=`.
- **`--domain` ends with the `--optimize` pass.**  Creating a vhost changes
  the plan (worker cap, OPcache file budget, guest cache for the new root,
  wp-cron / XenForo job entries), and the old code left those for a later
  run.  `install --domain`, `--domain` on a tuned host and `--domain` then
  `--optimize` now produce byte-identical trees (verified with 1 113-file
  /etc snapshots; the second `--optimize` is a no-op).  `SETUP_DOMAIN_OPTIMIZE=0`
  opts out.
- **PHP OPcache JIT re-validated.**  Tracing (kind 5, opt_level 4) with the
  PHP default thresholds 64/127/16/64 and a 64 MB buffer: 19.40 ms PHP per
  thread-page request against 20.94 ms with the JIT off (7.4%) and 21.57 ms
  with the function JIT (11%).  32 MB and 128 MB buffers were within noise of
  64 MB; only ~0.8 MB of the buffer was in use, so the 32 MB floor is safe on
  small hosts.  The conservative 128/255/32/128 set lost throughput and
  tripled p99.

## 1.15.0 (2026-11-10)

Second live-host audit of a production XenForo origin (XenForo 2.3.10 + XFMG 2.3.9,
8 vCPU, PHP 8.5.12, Angie 1.12.4) focused on the pages the FastCGI cache
cannot serve: member pages, the uncached gallery home and `/login/`.  Every
candidate was measured on the host with a loopback load generator and CPU
time per request split by service (PHP-FPM, Angie, MariaDB, Valkey); see
`tests/stress-site/RESULTS.md`.

- **Dynamic Brotli level 4 (3 on 1-2 CPU hosts), gzip 4 (3).**  Level 5
  cost 5.3 ms of Angie CPU per 130 KB thread page against 2.7 ms at level 4
  and 1.5 ms at level 3, for 21 / 23 / 24 KB on the wire; on `/login/` the
  Angie share fell from 2.7 to 2.3 ms.  Compression was 12% of the total CPU
  of a member page at level 5; level 4 halves it for 10% more bytes.
  `SETUP_BROTLI_LEVEL` / `SETUP_GZIP_LEVEL` still pin a host; the config
  repository ships the same defaults.
- **Managed XenForo job runner.**  `write_cron` adds one entry that runs
  `cmd.php xf:run-jobs --max-execution-time=50` every minute as www-data for
  every XenForo root under /var/www (`SETUP_XF_JOB_CRON=0` removes it,
  persisted as `XF_JOB_CRON`).  The audited host ran its queue, including
  XFMG video transcoding, inside member page requests (`jobRunTrigger =
  activity`) and by hand as root: 183 `data/xfmg/video/*` directories were
  `root 2700`, so Angie answered 403 for every video below them (16% of all
  requests in a 6-minute sample).  The `--optimize` report tells the operator
  to switch *Options > Performance > Job run trigger* to server-based.
- **Documentation:** the JIT buffer is part of the OPcache shared-memory
  segment (one per pool), not a per-worker allocation as 1.14.0 said.

Measured and rejected:

- `opcache.huge_code_pages = 1`: no effect on Ubuntu's PHP 8.5 build (the
  workers mapped no huge pages; PHP CPU per request unchanged within 1%).
- A covering index for XFMG's gallery `COUNT(*)` (74k rows scanned on every
  uncached gallery home view, 36-56 ms, 51 ms of MariaDB CPU per request on
  that page): a `(media_state, album_state, category_id)` index cut the
  statement from 47 to 31 ms on a scratch copy because 55k index entries
  still have to be counted.  Reported to the operator; the fix belongs in
  XFMG (cache the total).

Observed, not changed: 30,429 `Access denied for user <removed>@'localhost'`
MariaDB connection attempts between 19:29 and 20:53 local time (a user that
does not exist; `Aborted_connects` = 99% of all connections), and idle
persistent XenForo links hitting `wait_timeout = 600` (harmless: mysqli
revalidates a pooled link with COM_CHANGE_USER and reconnects).## 1.14.1 (2026-11-09)

Live-host audit of a production XenForo origin (XenForo 2.3.10 + XFMG, 8 vCPU Xeon E3-class,
32 GiB, PHP 8.5, Angie 1.12.4, MariaDB 11.8, Valkey sessions/cache), focused
on non-cacheable pages.

- **Removed the PHP upstream keepalive cache.** `upstream local_php` shipped
  `keepalive 64`, and the tuner rewrote it to `children/2` (16 here).  Every
  idle FastCGI connection occupies one PHP-FPM worker, and the cache is per
  Angie worker, so 16 idle connections pinned all 16 FPM workers.  A request
  that landed on an Angie worker without a cached connection then waited for
  the upstream `keepalive_timeout` (60 s default) until a worker was freed:
  measured 4-7 of every 64 non-cacheable `/login` requests took 60-112 s.
  With the cache removed (and `fastcgi_keep_conn off` in the config repo),
  3 x 128 requests had p99 33-38 ms, max 93 ms, no request over 1 s, and the
  same p50 (24-25 ms) and sequential latency (14 ms) as before.  A Unix-socket
  connect is cheap; the keepalive benefit did not exist on this workload.
  `angie_disable_php_keepalive` removes the directive (and any
  `keepalive_timeout` inside that upstream) from adopted hosts, and
  `angie_disable_php_keep_conn` forces `fastcgi_keep_conn off` in every
  `h5bp/php*.conf`; the dry-run report prints `keepalive=off`.
- **Pool size confirmed:** 8/12/16/24/32 FPM workers all served `/login` at
  the same p50 (24-28 ms) and p99 (31-72 ms) under 8 concurrent clients;
  2 per logical CPU (16) is kept for headroom on job/media bursts.

## 1.14.0 (2026-11-09)

Full-stack audit on the dev host (16 threads / 27.2 GiB / NVMe, Ubuntu 26.04.1) from
the 557-package baseline: fresh `--basic --angie --php --mariadb --valkey
--elastic --others all` install, `--optimize` parity, XenForo 2.3.13 and
WordPress 7.1.4 deployment from the local archives, and JIT/PHP-FPM sweeps
from the workstation (see `tests/stress-site/RESULTS.md`).

- **Modularized:** `setup.sh` is now a 217-line driver; the implementation
  lives in `lib/*.sh` (common, cli, validate, util, os, web, services, purge,
  runner, optimize, security, diagnostics, restart, payloads) sourced in the
  same order the monolithic file used. The split is lossless: head + modules
  + tail reconstruct the previous file byte-for-byte. `tests/test-tuning.sh`
  concatenates the driver and modules for its source-level checks; CI runs
  `bash -n` and shellcheck over every module.
- **PHP-FPM application pool is 2 workers per logical CPU** (was 4). With 100
  concurrent members on 16 threads, 32 workers beat 64 on throughput and
  halved latency: XenForo member 942 vs 914 req/s, p50 33 vs 68 ms, p99 49 vs
  118 ms; XenForo thread p50 62 vs 138 ms; WordPress member p50 130 vs 280 ms.
  16 workers left the CPU at ~50-60% and lost 30%; 40+ only added queueing.
- **OPcache JIT buffer is OPcache/8 (32-128 MB)** and the tracing hotness
  thresholds are written explicitly (PHP defaults on 4+ CPUs, a conservative
  set on 1-2 CPUs, `SETUP_PHP_JIT_HOT_{LOOP,FUNC,RETURN,SIDE_EXIT}` override).
  The buffer is per worker, so 64 MB keeps a 32-worker pool at 2 GiB instead
  of 4 GiB. Measured: 64 MB and 128 MB tied (XenForo 909 vs 906 req/s), 256 MB
  was slower; `function` lost 6-8% with a 554 ms p99; JIT off cost 5% on
  XenForo members.
- **Rate-limit exemptions work with `sudo -E`-less runs:** pass
  `SETUP_LIMIT_REQ_EXEMPT` through `env` (documented); the value is persisted
  in `/etc/default/setup-tuning` and survives a plain `--optimize`.

### Fixes from the 1.13.1 full-stack install-log audit (Ubuntu 26.04.1):

- **Cron:** `write_cron` no longer trusts the command-line service selection.
  `install_basic` calls it before the installers run, so a failed or
  interrupted install could leave Angie/MariaDB jobs pointing at missing
  binaries. It now uses `cron_angie_configured`/`cron_mariadb_configured`
  only; the final post-install pass adds the entries.
- **MariaDB backup:** an existing `/etc/mysqlbkup.config` survives a
  `--mariadb` re-run (including a larger `MAX_BACKUPS`), and the embedded
  installer's competing "Setup cron" suggestion is filtered out.
- **Diagnostics:** `cache and data sizes` includes `/var/lib/mariadb`, the
  MariaDB 11.8 datadir on Ubuntu 26.04.
- **DNS:** the drop-in sets `Domains=~.` so `8.8.8.8`/`1.1.1.1` are the
  default route for every query, not only a fallback behind DHCP DNS.
- **Run log:** timestamps are UTC (the timezone change no longer makes a
  2-minute run look 8 hours long) and ANSI colour sequences are stripped from
  the finished log file.
- **Install log:** the PHP-FPM tuning changes and the MariaDB profile are
  printed, matching the `--optimize` audit trail.
- **Swap:** the auto-swap skip message now says the existing swap meets or
  exceeds the target instead of claiming it is "at least 50% of RAM".

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

Audit session on the development host (16 threads / 27 GiB / NVMe,
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

Validated on the development host (16 threads / 27 GiB / NVMe, Ubuntu
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
code reviews plus a repeated-block scan), validated on the dev host: identical
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
