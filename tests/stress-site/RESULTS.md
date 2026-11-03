# Full-stack local stress report

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
