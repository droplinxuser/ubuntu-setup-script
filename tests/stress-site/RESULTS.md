# Full-stack local stress report

## Live VPS validation - setup.sh 1.6.7, 16 vCPU / 30 GiB

- Host: `web01.stress.test`, 16 vCPU, 30 GiB RAM, 281 GiB ext4, Ubuntu 26.04.1
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
- Check /var/log/angie/stress.test.error.log and
  /var/log/php-fpm/www-slow.log for server-side warnings.
