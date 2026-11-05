# Full-stack stress test reports

## setup.sh 1.8.36 - 8 vCPU / 15 GiB validation (2026-11-05)

Host: `stress-vps`, 8 vCPU, 15.1 GiB RAM, Ubuntu 26.04.1, Angie 1.12.4,
PHP 8.5.12 FPM (80 static workers), MariaDB 11.8.6, Valkey 9.0.4,
Elasticsearch 9.5.6, Node.js 26.13.0, Gifsicle 1.96.

The host was installed with `--basic ... --angie --php --mariadb --valkey
--elastic --others all`, then optimized with `--optimize`. The standard suite
was run on the VPS itself so the load generator did not hide CPU saturation;
the local macOS desktop also ran `oha` over HTTPS for an external view.

| Scenario | Requests/sec | p50 | p90 | p99 |
|---|---:|---:|---:|---:|
| static | 156,990 | 482us | 1.19ms | 2.11ms |
| php-hello | 68,619 | 1.20ms | 66.83ms | 464.70ms |
| mariadb-json | 13,300 | 6.06ms | 281.86ms | 1.34s |
| valkey-json | 18,959 | 3.90ms | 599.90ms | 1.49s |
| elasticsearch | 7,697 | 5.77ms | 8.94ms | 17.80ms |
| node-proxy (simple) | 19,701 | 4.93ms | 6.22ms | 7.88ms |
| full-uncached-200 | 3,618 | 21.84ms | 31.15ms | 41.07ms |
| full-cached-200 | 93,116 | 1.94ms | 3.28ms | 5.20ms |
| slow-1s-200 | 71.8 | 1.00s | 1.01s | 1.04s |

Additional full-stack probes:

| Workload | Requests/sec | CPU |
|---|---:|---:|
| WordPress guest page (FastCGI cache) | 9,028 | 100% |
| Node.js all-services app (`mysql2` + `ioredis` + ES) | 4,250 | 99.7% |
| Mixed stress + WordPress + Node, 20s | 768 + 3,732 + 1,128 | 100% (0% idle) |
| Valkey direct Unix-socket benchmark | ~195k SET / ~195k GET ops/s | 38% total CPU; client/loopback bound |

Per-service CPU observations at high concurrency:

- Angie static: 100% CPU, 154k req/s.
- PHP hello: 94% CPU, 60k req/s.
- MariaDB through PHP: 96.5% CPU, 13.4k req/s.
- Elasticsearch through PHP: 91.8% CPU, 8.1k req/s.
- Node all-services: 99.7% CPU, 4.25k req/s.
- Full stack: 97% CPU at 3.7k req/s; the uncached path is CPU-limited,
  not blocked on a single service.

The external macOS `oha` run was limited by the ~70 ms RTT and local uplink
(~1.6k req/s at 500-800 connections, server 34-66% idle), so it is not used
for CPU-ceiling conclusions. The loopback runs above are the ceiling tests.

Optimization notes applied: MariaDB buffer pool 966 MB, PHP 80 workers,
Valkey 1.5 GB, Elasticsearch 512 MB, BBR/fq, 1M nofile, 32k backlog, 80% RAM
budget, WordPress guest cache and single-node ES replica fix.

## Remote stress test - live origin host (2026-11-04)


Origin-direct load test from a separate 48 vCPU dev server
(`198.51.100.20`, Ubuntu 26.04.1, `wrk` 4.1.0). Public DNS for the site is
behind Cloudflare (and returns 403 to non-browser
requests), so the dev server mapped the name directly to the origin and ran
`wrk` over HTTPS/1.1. The origin uses a Cloudflare Origin certificate, so the
load generator does not validate the certificate.

Target stack: Ubuntu 24.04.5, 12 vCPU / 62.4 GiB, Angie 1.12.4, PHP 8.3.36
FPM (128 static workers, TCP 9000), MariaDB 10.11.14 (25.6 GB buffer pool,
1500 connections, thread pool), Redis 7.0.15, Elasticsearch 8.19.23.

| Scenario | Connections | Requests/sec | p50 | p90 | p99 | Client errors/timeouts |
|---|---:|---:|---:|---:|---:|---|
| static JS | 4000 | 29117.53 | 133.60ms | 134.84ms | 136.16ms | none |
| cached forum index | 800 | 4362.82 | 177.12ms | 179.42ms | 284.22ms | none |
| uncached thread | 20 | 72.63 | 193.65ms | 213.96ms | 722.61ms | none |
| uncached thread | 100 | 410.13 | 194.06ms | 371.90ms | 685.46ms | none |
| uncached thread | 400 | 1909.63 | 194.64ms | 201.29ms | 634.79ms | none |
| uncached thread | 800 | 2844.20 | 297.02ms | 325.40ms | 527.29ms | none |
| uncached thread | 1600 | 2971.77 | 476.52ms | 833.96ms | 1.61s | timeout 2 (5s) |
| uncached thread | 1600 (10s timeout) | 2593.74 | 586.74ms | 770.29ms | 1.22s | none |
| uncached thread | 2400 | 2297.59 | 942.84ms | 1.20s | 1.79s | timeout 1 (5s) |
| mixed cached + uncached, 60s | 400 + 400 | 2144.82 + 1632.13 | 180.95ms / 198.88ms | 189.70ms / 447.73ms | 315.62ms / 763.68ms | none |
| login page | 200 | 767.51 | 195.99ms | 200.70ms | 202.98ms | none |
| missing page (expected 404) | 200 | 1230.18 | 150.94ms | 152.52ms | 153.51ms | none (all 404) |

Server-side observations:

- During the 1,600-connection uncached run, `vmstat` showed ~88–89% user,
  11–12% system, 0% idle across 12 cores. Load average peaked at 17.93 during
  the 2,400-connection run; the uncached PHP path is CPU-bound at ~2.6–3.0k
  req/s.
- PHP-FPM stayed at 129 processes (128 workers + master); MariaDB held 129
  connections (`Max_used_connections=130`), with `Aborted_connects=0`,
  `Slow_queries=0`, and `Innodb_buffer_pool_wait_free=0`.
- No Angie, PHP-FPM or MariaDB error-log entries appeared during the test;
  the dev server IP does not appear in any error log. Memory stayed at
  ~26.9 GB used / ~37 GB available, swap unchanged at ~31 MB, no OOM events,
  no failed services from the test.
- Redis reported `rejected_connections=0` and `evicted_keys=0`.
  Elasticsearch heap stayed around 1.2 GB.
- The only client timeouts were 2/59,707 at 1,600 connections and 1/34,695 at
  2,400 connections with a 5-second `wrk` timeout. Re-running 1,600
  connections with a 10-second timeout produced zero timeouts, and there were
  no matching server-side timeout or error entries; these were extreme-
  concurrency client/queue effects, not service failures.
- Pre-existing conditions, not caused by the test: Angie logs an unused ACME
  client warning; Elasticsearch is yellow with 2 unassigned replica shards on
  a single node; `hetrixtools_agent.service` is failed/not-found; and the
  vhost/PHP error logs contain older application exception stacks (line
  counts did not change during the test).

The `/etc/hosts` override, load generator scripts, `wrk` output files,
monitoring CSV and all live-server temp files were removed after the run.

## Final re-validation - setup.sh 1.6.11, 48 vCPU / 128 GiB

Re-run on 2026-11-04 after the `--optimize` command, PHP socket migration and
Angie repository ownership cleanup. Host: 48 vCPU, 125 GiB RAM, Ubuntu 26.04,
Angie 1.12.4, PHP 8.5.12 FPM (512 static workers), MariaDB 11.8.6, Valkey
9.0.4, Elasticsearch 9.5.6, Node 26.13.0. PHP-FPM and Angie both use
`/run/php/php-fpm.sock`.

Standard suite (`tests/stress-site/run-stress.sh`, 8 threads / 200 clients):

| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |
|---|---:|---:|---:|---:|---|
| static | 128738.24 | 377.00us | 0.73ms | 0.94ms | none |
| php-hello | 117206.06 | 688.00us | 0.84ms | 1.46ms | none |
| mariadb-json | 27733.21 | 3.37ms | 5.34ms | 8.40ms | none |
| valkey-json | 14396.78 | 6.86ms | 7.09ms | 7.53ms | none |
| elasticsearch | 3846.13 | 10.87ms | 20.26ms | 34.24ms | none |
| node-proxy | 14625.33 | 6.66ms | 7.45ms | 10.38ms | none |
| full-uncached-200 | 6163.31 | 27.94ms | 52.06ms | 112.94ms | none |
| full-cached-200 | 128810.82 | 1.05ms | 1.67ms | 3.89ms | none |
| slow-1s-200 | 179.72 | 1.00s | 1.00s | 1.00s | none |

Aggressive run (16 threads):

| Scenario | Requests/sec | p50 | p99 | Client socket errors |
|---|---:|---:|---:|---|
| static (1000c) | 279976.75 | 1.75ms | 7.76ms | none |
| php-hello (500c) | 115270.56 | 2.82ms | 180.62ms | none |
| mariadb-json (400c) | 26614.63 | 13.86ms | 45.22ms | none |
| valkey-json (400c) | 12991.22 | 30.90ms | 34.55ms | none |
| full-cached (1000c) | 178597.73 | 3.71ms | 10.32ms | none |
| full-uncached (400c) | 7808.82 | 49.90ms | 102.03ms | none |

Post-test: Angie/PHP error logs empty, MariaDB `Slow_queries=0`,
`Aborted_connects=0`, `Max_used_connections=707` (limit 1536), no failed units,
no OOM or swap use.

## Ubuntu 24.04 live `--optimize` validation

On a live 12 vCPU / 62.7 GiB Ubuntu 24.04.5 host (Angie 1.12.4, PHP 8.4.27,
MariaDB 10.11.14, Valkey 7.2.13, no Elasticsearch):

- PHP-FPM moved from `127.0.0.1:9000` to `/run/php/php-fpm.sock`; 192 workers,
  12,288 max requests, 300 s terminate timeout.
- Angie `local_php` repointed to the socket; `worker_connections` 300000 →
  24576; `worker_rlimit_nofile` 520000 → 98304; keepalive 3 → 24.
- MariaDB 10.11 `[mysqld]` drop-in: 25 GB buffer pool, `max_connections=384`,
  `back_log=65535`, `pool-of-threads`.
- Valkey `maxmemory` 1 GB → 6.4 GB, `maxclients=20000`, backlog 65535.
- Elasticsearch absent → untouched.
- A second `--optimize` run was idempotent. 1,000 concurrent HTTP requests
  returned 200 with zero client errors; live XenForo sites stayed up.
- Certificate path validated separately with Angie built-in ACME: a new
  Let's Encrypt certificate for a multi-name production vhost is valid through
  2027-02-02 and public TLS verification returns 0.

## Live dedicated validation - setup.sh 1.6.8, 48 vCPU / 128 GiB

- Host: 48 vCPU, 125 GiB usable RAM, 2× 894 GB NVMe, Ubuntu 26.04 LTS
- Angie/1.12.4, PHP 8.5.12 FPM (512 static workers), MariaDB 11.8.6,
  Valkey 9.0.4, Elasticsearch 9.5.6, Node.js v26.13.0, Gifsicle 1.96
- Auto-tuned: Angie `worker_rlimit_nofile=393216`,
  `worker_connections=65535`, FastCGI upstream keepalive 96, 32 GiB total
  HTTP cache budget; MariaDB buffer pool 32 GB, `max_connections=1536`,
  `back_log=65535`; Valkey 8 GB; ES heap 31 GB; PHP OPcache 512 MB /
  JIT 128 MB.
- `setup.sh` run from a clean host, then idempotent re-runs, two full purges,
  a clean reinstall and `--purge basic` + `--basic` were exercised.

Standard suite (`tests/stress-site/run-stress.sh`, 8 threads / 200 clients):

| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |
|---|---:|---:|---:|---:|---|
| static | 130949.37 | 374.00us | 0.74ms | 0.88ms | none |
| php-hello | 112497.63 | 681.00us | 0.90ms | 3.20ms | none |
| mariadb-json | 23934.99 | 3.90ms | 6.59ms | 10.18ms | none |
| valkey-json | 15098.41 | 6.63ms | 6.89ms | 7.31ms | none |
| elasticsearch | 3933.37 | 10.56ms | 20.70ms | 36.11ms | none |
| node-proxy | 14531.15 | 6.56ms | 7.91ms | 11.34ms | none |
| full-uncached-200 | 6600.93 | 27.06ms | 46.72ms | 118.33ms | none |
| full-cached-200 | 135207.21 | 1.00ms | 1.58ms | 3.54ms | none |
| slow-1s-200 | 179.68 | 1.00s | 1.00s | 1.00s | none |

Aggressive run (16 threads, 400 clients except static/cached at 1000):

| Scenario | Requests/sec | p50 | p99 | Client socket errors |
|---|---:|---:|---:|---|
| static (1000c) | 279504.58 | 1.78ms | 7.74ms | none |
| php-hello (500c) | 137748.05 | 2.35ms | 90.10ms | none |
| mariadb-json (400c) | 25055.49 | 14.54ms | 53.52ms | none |
| valkey-json (400c) | 12952.82 | 31.18ms | 34.55ms | none |
| elasticsearch (200c) | 14793.68 | 12.32ms | 223.20ms | none |
| node-proxy (500c) | 15274.63 | 32.00ms | 42.29ms | none |
| full-uncached (400c) | 7631.19 | 48.09ms | 183.40ms | none |
| full-cached (1000c) | 178510.27 | 3.76ms | 10.29ms | none |

Three-minute mixed soak (370 clients across static/PHP/DB/Valkey/ES/Node/
cached): zero socket errors and zero non-2xx responses; service RSS growth
was < 20 MB per service, no swap use and no OOM events. A 500-client probe
first exposed the MariaDB 357-entry Unix-socket backlog and 500-connection
cap; those were fixed (`back_log=65535`, `max_connections` scaled to 1536)
before the final runs. The load generator runs on the same 48 cores, so 400
client connections is the sustainable zero-timeout ceiling in this setup.

## Live VPS validation - setup.sh 1.6.7, 16 vCPU / 30 GiB

- Host: `web01`, 16 vCPU, 30 GiB RAM, 281 GiB ext4, Ubuntu 26.04.1
- Angie/1.12.4, PHP 8.4.27 FPM (and a parallel PHP 8.3.36 pool), MariaDB 11.8.6,
  Valkey 9.0.4, Elasticsearch 9.5.6, Node.js v26.13.0, Gifsicle 1.96
- FastCGI: Unix socket `/run/php/php-fpm.sock`; PHP-FPM `static`, 121 workers,
  RSS 25.6 MB/worker; MariaDB buffer pool 12.4 GB; ES heap 4 GB
- Kernel: BBR + fq, `vm.swappiness=10`, `fs.file-max=10485760`

| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |
|---|---:|---:|---:|---:|---|
| static | 181190.01 | 301.00us | 0.91ms | 3.40ms | none |
| php-hello | 124444.66 | 513.00us | 1.62ms | 4.48ms | none |
| mariadb-json | 26120.54 | 3.63ms | 5.72ms | 8.75ms | none |
| valkey-json | 20808.26 | 4.68ms | 5.30ms | 6.36ms | none |
| elasticsearch | 10876.38 | 3.58ms | 8.74ms | 48.99ms | none |
| node-proxy | 22212.86 | 4.31ms | 5.37ms | 7.36ms | none |
| full-uncached-200 | 7398.29 | 15.39ms | 23.69ms | 64.94ms | timeout 20 |
| full-cached-200 | 169601.50 | 614.00us | 3.09ms | 5.88ms | none |
| slow-1s-200 | 108.71 | 1.00s | 1.00s | 1.00s | none |

Sustained soak (no other load):

| Scenario | Duration | Requests/sec | p50 | p90 | p99 | Socket errors |
|---|---:|---:|---:|---:|---:|---|
| FastCGI-cached, 200 clients | 180 s | 165,855 | 658us | 3.01ms | 6.20ms | none |
| Full stack uncached, 50 clients | 120 s | 6,486 | 7.15ms | 10.11ms | 14.50ms | none |

Application and tuning checks:

| Test | Result |
|---|---|
| WordPress guest page cache | 242 req/s uncached -> 9,972 req/s cached; p50 4.44 ms, p99 8.31 ms; logged-in cookie and POST bypass confirmed |
| Node cluster, 4 -> 8 workers | 25,603 -> 29,747 req/s (+16%), p50 7.60 -> 6.05 ms |
| Valkey Unix socket vs TCP | 132.5k/113.3k vs 70.0k/75.6k SET/GET ops/s |
| Valkey io-threads 1 -> 4 | no gain (117k/114k ops/s); kept 1 |
| PHP 8.3 pool | 41,746 req/s, p50 1.13 ms, p99 2.12 ms on a minimal vhost |
| PHP 8.4 pool | 111,930 req/s, p50 0.32 ms, p99 2.53 ms on a minimal vhost |
| MariaDB | Max_used_connections 146/400, Slow_queries 0, Aborted_connects 0 |
| Valkey | rejected_connections 0, evicted_keys 0 |
| Elasticsearch | cluster green, 3 active shards, 0 unassigned |

Operational note: PHP-FPM can return `Unable to open primary script ...
(Operation not permitted)` for a script created after the workers started,
because of the long `realpath_cache_ttl=43200` / OPcache path state. Restarting
`php<ver>-fpm` after deploying new PHP files clears it (observed twice; no
errors after restart). Deploy scripts should always reload/restart FPM after
syncing application files.

## setup.sh 1.6.0 - 8 vCPU VPS

- Generated: 2026-11-03T02:33:00Z
- Host: stress1.test, 8 vCPU, 15.1 GiB RAM, Ubuntu 26.04.1, NVMe
- Angie: Angie/1.12.4
- PHP: PHP 8.5.12 with OPcache/JIT
- MariaDB: 11.8.6
- Valkey: 9.0.4
- Elasticsearch: 9.5.6
- Node.js: v26.13.0
- GifSicle: 1.96
- FastCGI: Unix socket `/run/php/php-fpm.sock`

| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |
|---|---:|---:|---:|---:|---|
| static | 94056.02 | 449.00us | 2.45ms | 5.32ms | none |
| php-hello | 43119.22 | 1.41ms | 481.97ms | 884.25ms | none |
| mariadb-json | 11100.58 | 4.68ms | 9.89ms | 929.62ms | timeouts 37 |
| valkey-json | 15947.22 | 3.70ms | 5.25ms | 1.26s | timeouts 46 |
| elasticsearch | 2349.98 | 17.22ms | 31.55ms | 181.19ms | timeouts 5 |
| node-proxy | 12724.60 | 7.59ms | 9.37ms | 13.19ms | none |
| full-uncached-200 | 2525.37 | 22.26ms | 35.12ms | 67.01ms | timeouts 24 |
| full-cached-200 | 66951.16 | 2.07ms | 3.46ms | 5.92ms | none |
| slow-1s-200 | 53.89 | 1.00s | 1.00s | 1.02s | none |

Interpretation for an 8 vCPU host:

- The server is CPU-bound during uncached PHP work. `wrk` competes for the
  same cores, so its client-side p99 is much worse than Angie's server-side
  `$request_time` (p50 ~4.8 ms, ~0.15% >500 ms for the MariaDB page).
- FastCGI over a Unix socket improved PHP hello throughput from ~39.7k to
  ~43.3k req/s and removed loopback TCP overhead.
- FastCGI page caching is still the largest win: ~2.5k -> ~67k req/s on the
  same full-stack page.
- Logs for this run are in `/var/www/logs/{angie,php,mariadb,valkey,nodejs,gifsicle,elasticsearch}`.

## Soak test (same 8 vCPU VPS)

Run after the final configuration, without other load:

| Scenario | Duration | Requests/sec | p50 | p90 | p99 | Errors |
|---|---:|---:|---:|---:|---:|---|
| Full stack uncached, 50 clients | 15 min | 3,212 | 14.5 ms | 21.5 ms | 29.7 ms | none |
| FastCGI-cached page, 200 clients | 5 min | 67,010 | 1.82 ms | 5.37 ms | 9.97 ms | none |

The 5-minute cache run served 20,107,871 requests (38.7 GB) with zero socket
errors. MariaDB reported no slow queries or aborted connections; Valkey
reported no rejected connections or evictions; Elasticsearch stayed green.
Load average was high during the uncached run (about 55 on 8 vCPU) because the
load generator shares the same cores, but server-side p99 stayed under 30 ms.

Access logs reached 2.6 GB during the soak. For production, the templates now
use `buffer=64k flush=5s` and logrotate caps rotation at 1 GB / 14 days; ship
access logs off-box or disable them for static/cached assets on very large
sites.

## setup.sh 1.4.0 - 16 vCPU reference

This is the measured baseline from `tests/stress-site/run-stress.sh` after all
v1.4.0 fixes (Angie cache/rate-limit fixes, PHP extensions/OPcache, MariaDB
thread pool, Valkey single I/O thread + Unix socket, PHP Unix-socket defaults).

- Generated: 2026-11-03T09:20:41+08:00
- Host: test host, 16 vCPU, 27.2 GiB RAM
- Angie: Angie version: Angie/1.12.4
- PHP: PHP 8.5.12 (cli) (built: Oct 21 2026 08:07:33) (NTS)
- MariaDB: 11.8.6-MariaDB-5ubuntu0.1 from Ubuntu-log
- Valkey: Valkey server v=9.0.4 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=256ea4cb0edac842
- Elasticsearch: 9.5.6
- Node.js: v26.13.0
- GifSicle: LCDF Gifsicle 1.96

## Results

| Scenario | Requests/sec | p50 | p90 | p99 | Client socket errors |
|---|---:|---:|---:|---:|---|
| static | 258490.60 | 229.00us | 1.35ms | 3.39ms | none |
| php-hello | 117403.30 | 584.00us | 7.04ms | 23.10ms | none |
| mariadb-json | 27336.89 | 3.50ms | 5.24ms | 310.22ms | none |
| valkey-json | 29084.73 | 3.35ms | 3.74ms | 218.05ms | none |
| elasticsearch | 15907.78 | 2.92ms | 4.09ms | 5.93ms | none |
| node-proxy | 29884.21 | 3.25ms | 3.86ms | 5.36ms | none |
| full-uncached-200 | 7167.90 | 14.91ms | 17.29ms | 22.10ms | Socket errors: connect 0, read 0, write 0, timeout 45 |
| full-cached-200 | 181987.43 | 0.91ms | 1.87ms | 2.89ms | none |
| slow-1s-200 | 91.92 | 1.00s | 1.00s | 1.00s | none |

Notes on the numbers:

- The p50/p90 columns are the normal steady-state latency. The p99 outliers in
  the MariaDB/Valkey rows are caused by the synthetic 100-connection test
  opening a new loopback connection for every request and by the client-side
  `wrk`/TLS connections exhausting the ephemeral port range during the run;
  server-side error counters stayed at zero (no aborted connects, no rejected
  Valkey connections, no evictions, no MariaDB slow queries).
- MariaDB and Valkey use Unix sockets, which removed the worst of the tails.
  Elasticsearch and Node still use TCP, so a production deployment handling
  much higher rates should keep those connections alive or put a local proxy
  in front of them.
- `full-uncached-200` is intentionally heavy (four sequential local lookups per
  request). `full-cached-200` is the same page served from Angie's FastCGI
  cache for 5 seconds — the recommended production pattern for guest traffic.
- `slow-1s-200` deliberately asks each request to sleep for one second with 200
  clients and only 108 PHP workers, so it saturates the pool and is expected to
  queue.

## State after the suite

- Load average: 1.60 -> 22.36
- Memory: 13461/27806 MB used -> 13530/27806 MB used
- PHP-FPM: pool:                 www;process manager:      static;start time:           03/Nov/2026:09:17:17 +0800;start since:          267;accepted conn:        1534834;listen queue:         18;max listen queue:     194;listen queue len:     65535;idle processes:       3;active processes:     128;total processes:      131;max active processes: 119694;max children reached: 0;slow requests:        0;memory peak:          2097152;
- MariaDB: Aborted_connects	0;Max_used_connections	134;Questions	1655055;Slow_queries	0;Threads_connected	1;Threads_running	1;
- Valkey: total_commands_processed:2770078
;instantaneous_ops_per_sec:0
;rejected_connections:0
;evicted_keys:0
;
- Elasticsearch: {"nodes":{"node":{"indices":{"search":{"query_total":1419939}},"jvm":{"mem":{"heap_used_in_bytes":1401520728},"gc":{"collectors":{"young":{"collection_count":90}}}}}}} -> {"nodes":{"node":{"indices":{"search":{"query_total":1571489}},"jvm":{"mem":{"heap_used_in_bytes":1598405688},"gc":{"collectors":{"young":{"collection_count":99}}}}}}}

## Notes

- The cached page demonstrates the main large-site optimisation: guest
  page caching removes almost all PHP/DB/ES/Node work per request.
- The uncached page is intentionally heavy (MariaDB + Valkey + ES + Node
  on every request). It is limited by PHP worker occupancy and CPU.
- Client socket timeouts under the slow-1s scenario mean the PHP-FPM
  listen queue is full; add workers or cache the endpoint.
- Check /var/log/angie/stress.invalid.error.log and
  /var/log/php-fpm/www-slow.log for server-side warnings.
