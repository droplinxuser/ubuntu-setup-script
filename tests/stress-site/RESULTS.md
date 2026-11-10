# Full-stack stress test reports


## Live forum.example.com origin, audit 3 - member pages and the gallery count (2026-11-10)

Host: 8-thread Xeon E3-class, 32 GiB, RAID10, Ubuntu 26.04.1, PHP 8.5.12
FPM (`pm=static` 16), Angie 1.12.4, MariaDB 11.8.6, Valkey 9.0.4, XenForo
2.3.13 with XFMG 2.3.9 (about 48 000 users, about 3 500 threads, about 10 000 posts, about 74 000
media items, terabytes of media, tens of GB of `internal_data`).  The origin is reachable only through its front proxy, so the load
generator (`oha` 1.16.0) ran on the host against `127.0.0.1` with
`--connect-to`, exactly as in audit 2.  CPU per request is each service's
systemd cgroup `usage_usec` delta divided by the completed requests
(`sample-cpu.sh`/`analyze-cpu.py`).

Member pages were exercised with `Cookie: xf_session=bench`, which bypasses
the FastCGI guest cache without logging in: the full XenForo render path
(permissions, templates, session row) runs, with the guest identity.

### Baseline (8 connections, 8 s per scenario, loopback)

| scenario | req/s | p50 ms | p99 ms | PHP ms/req | Angie | MariaDB | Valkey |
|---|---:|---:|---:|---:|---:|---:|---:|
| `/login/` | 441 | 17.5 | 27.0 | 12.4 | 2.13 | 1.35 | 0.26 |
| gallery index `/` (uncached) | 62 | 126.8 | 204.0 | 38.9 | 4.80 | **54.0** | 0.30 |
| `/whats-new/` (uncached) | 137 | 57.3 | 78.5 | 37.4 | 3.90 | 10.0 | 0.34 |
| thread page (uncached) | 143 | 54.1 | 90.4 | 42.7 | 4.22 | 4.57 | 0.34 |

The 8-thread host is saturated at ~7.4 of 8 cores in the PHP scenarios, so
req/s is a direct proxy for CPU per request.  99.8 % OPcache hit rate, 607
scripts cached, JIT tracing on (`kind=5, opt_level=4`), and `strace -c`
showed 669 syscalls / 13 ms of system time per 5 s - the PHP cost is
user-space execution, not I/O.

A low-threshold slow log (`long_query_time=0.005`, `log_output=TABLE`)
captured the gallery index's database work: **383 of 391 slow queries were
one statement**, `SELECT COUNT(*) FROM xf_mg_media_item WHERE (album_state =
'visible' OR album_state IS NULL) AND category_id IN (<31 ids>) AND
media_state IN ('visible')`, at 47.7 ms average - one per view, a full scan
of about 74 000 rows.

### After the covering index (`mg_count_cover (media_state, album_state, category_id)`)

| scenario | req/s | p50 ms | p99 ms | PHP ms/req | Angie | MariaDB | Valkey |
|---|---:|---:|---:|---:|---:|---:|---:|
| gallery index `/` (uncached) | **90** | 86.7 | 126.3 | 40.7 | 4.28 | **30.7** | 0.30 |
| `/whats-new/` (unchanged) | 137 | 57.0 | 83.3 | 38.6 | 4.10 | 10.0 | 0.35 |

`EXPLAIN` now reports `type=range, key=mg_count_cover, rows=55482, Using
index`; the query is 23.4 ms (was 47.7 ms).  +45 % requests/s and -32 % p50
on the page every member lands on, with no application file touched.  The
`ALTER` ran with `ALGORITHM=INPLACE, LOCK=NONE` in 0.22 s on the live table.

### PHP-FPM and JIT on this host (thread page, 100 conns equivalent)

| configuration | PHP ms/req | req/s |
|---|---:|---:|
| tracing 64 MB, 64/127/16/64 (shipped) | **42.8** | 143 |
| tracing 32 MB / 128 MB | 43.2 / 43.7 | 143 / 140 |
| aggressive 32/64/8/32 | 42.8 | 143 |
| conservative 128/255/32/128 | 43.7 | 142 |
| function JIT | 49.0 | 127 |
| JIT off | 50.1 | 125 |
| `opcache.validate_timestamps=0` | 41.7 | 144 |

8 / 12 / 16 workers: 142-144 req/s and 42.6-43.0 ms PHP (no pool effect).

### Left alone, with reasons

- **Brotli 4**: ~4 ms of Angie CPU per thread page, but the proxy-to-client
  path is the binding constraint for bytes (the external profile is dominated
  by the front proxy), so lowering the level would cost real users
  more than it saves.
- **`opcache.preload`**: could remove the per-request class linking, but a
  bad preload is fatal at FPM startup on a live board; not attempted.
- **XFMG `X-Cache` / Valkey sessions**: member responses are session-specific
  and XenForo has no session cache backend (its `xf_session` row is written
  per request; MariaDB CPU for it is already ~1 ms).


## Clean Ubuntu 26.04 host, setup.sh 1.16.0 - PHP worker cap, JIT and parity (2026-11-10)

Test target: a pristine Ubuntu 26.04.1 install on a Ryzen 7-class (8 cores /
16 threads, 27 812 MiB, NVMe, no other workload), reached over the LAN from a
macOS workstation with `oha` 1.16.0.  XenForo 2.3.13 (8 forums, 600 threads,
2 983 posts, 201 members) and WordPress 7.1.4 (401 posts, 102 users, block
theme, `redis-cache` with PhpRedis to Valkey) were deployed from the local
archives through `setup.sh --domain ... app=xf|wordpress db=...`.

Method: every scenario is a 12 s keep-alive run at 100 connections with
`Accept-Encoding: gzip, br`; CPU is the delta of each service's systemd
cgroup `cpu.stat usage_usec` (`sample-cpu.sh` + `analyze-cpu.py` in this
directory), divided by the completed requests, so it is independent of the
client link.  The host was saturated (15.7-16.0 of 16 threads) in every PHP
scenario.

### End state (setup.sh 1.16.0: 16 workers, tracing JIT 64 MB, guest cache)

| scenario | req/s | p50 ms | p99 ms | KB/req | PHP ms/req | Angie | MariaDB | Valkey |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| XenForo guest (cached) | 8 266 | 11.3 | 18.5 | 7.2 | 0 | 0.10 | 0 | 0 |
| XenForo guest (cache bypassed) | 1 345 | 73.6 | 84.1 | 7.2 | 9.13 | 0.22 | 1.84 | 0.002 |
| XenForo member home | 1 024 | 96.4 | 160.8 | 7.9 | 11.36 | 0.24 | 3.29 | 0.002 |
| XenForo member thread | 678 | 146.7 | 240.2 | 15.0 | 18.20 | 0.30 | 4.19 | 0.002 |
| WordPress guest (cached) | 6 016 | 16.1 | 24.4 | 12.9 | 0 | 0.92 | 0 | 0 |
| WordPress guest (cache bypassed) | 247 | 412.4 | 488.8 | 12.9 | 53.93 | 1.46 | 0.41 | 1.39 |
| WordPress member | 238 | 429.8 | 478.5 | 14.0 | 55.59 | 1.55 | 0.42 | 1.53 |

The WordPress rows are link-bound: 53.9 ms of PHP per request across 16
workers caps the host at ~296 req/s and the Wi-Fi client delivered 247.  The
XenForo rows are host-bound.  Guest caching is the largest single lever:
XenForo 6.1x and WordPress 24x the uncached request rate, at 0.1 ms and
0.9 ms of Angie CPU per request.

### PHP-FPM worker count (XenForo, three repeats, 8 s, 100 connections)

| workers | member req/s | PHP ms/req | thread req/s | PHP ms/req |
|---:|---:|---:|---:|---:|
| 8  | 471 (thread only) | - | 471 | 14.21 |
| 12 | - | - | 612 | 15.88 |
| 16 | 1 044 | 11.20 | 686 | 18.10 |
| 24 | 1 000 | 11.87 | 641 | 19.21 |
| 32 | 936 | 12.27 | 648 | 19.60 |
| 48 | - | - | 627 | 20.25 |

200 connections agreed (member: 1 046 at 16 vs 996 at 32).  Eight workers
have the lowest CPU per request but cannot fill the 16 threads.  WordPress
moved the same way (51.6 ms at 16 vs 57.6 ms at 32).  The old install plan
wrote 144 workers for this host and the first `--optimize` wrote 32; the
ceiling (2 per thread generic, 1 per thread for local-database applications)
now makes both write 32 and 16 respectively, and `--domain` runs the
optimizer so a domain install lands on 16.

### OPcache JIT (XenForo member thread, 100 connections, 10 s)

| configuration | req/s | PHP ms/req | p99 ms |
|---|---:|---:|---:|
| tracing, 64 MB, 64/127/16/64 (default) | 636-655 | 19.27-19.40 | 250-360 |
| tracing, 32 MB | 636 | 19.48 | 370 |
| tracing, 128 MB | 653 | 19.52 | 318 |
| tracing, aggressive 16/64/8/32 | 638 | 19.67 | 394 |
| tracing, conservative 128/255/32/128 | 522 | 19.61 | 1 719 |
| function JIT, 64 MB | 571 | 21.57 | 545 |
| JIT off | 617 | 20.94 | 271 |

Tracing at PHP's default thresholds wins; the JIT is worth 7.4% of PHP CPU
against off and 11% against the function JIT.  Only ~0.8 MB of the 64 MB
buffer was in use after 100 warm requests (`opcache_get_status()` shows
`kind=5, opt_level=4`), so the 32 MB floor the script clamps to is safe on
small hosts.  OPcache itself reached a 97.2% hit rate with 626 scripts.

### Parity

1 113-file `/etc` snapshots (md5 per file, unit states, root crontab, PHP
runtime, MariaDB variables) taken around each step:

- install, then `--optimize`: identical apart from kernel counters.
- `--domain app=wordpress`, then `--optimize`: identical.
- `--domain app=xf`, then `--optimize`: identical.
- a second `--optimize`: no file changes (the only differences ever observed
  were `opcache.max_accelerated_files`, which follows the PHP file count when
  test artifacts are added to a document root).


## Live XenForo origin, audit 2 - non-cacheable pages, CPU per request (2026-11-10)

Host as in the first audit (8 vCPU Xeon E3-class, 32 GiB, PHP 8.5.12 FPM
`pm=static` 16, Angie 1.12.4, MariaDB 11.8, Valkey 9, XenForo 2.3.10 + XFMG
2.3.9).  The origin is reachable only through its front proxy and loopback, so
load ran on the host: `curl -Z --parallel-max 8 --http1.1` against
`https://live-origin.example` resolved to 127.0.0.1 with an `xf_session=nocache` cookie
(bypasses the guest cache like a member session), `Accept-Encoding: gzip,
deflate, br, zstd`, 300-400 requests per page.  CPU time per request is the
utime+stime delta of each service's processes divided by the requests.

### Real traffic (6-minute sample, 3,581 requests)

61% of guest PHP hits were cache HITs, 588 MISS + 213 STALE renders at 15 ms
average; 152 member page requests at 30 ms average; `css.php` served from
the cache for members too; 80 `job.php` calls (0.5 s total); 575 requests
(16%) answered **403** for `/data/xfmg/video/...` because the directories were
`root 2700` (created by a root CLI job run); `br` on 1105 of 1930 HTML
responses, `gzip` on 102.  The proxy keeps 13 HTTP/1.1 connections open
(TLS reuse, ECDSA P-256 certificate), so handshakes are not a cost.

### Baseline, CPU ms per request (c=8)

| Page (uncached) | p50 | p99 | PHP | Angie | MariaDB | Valkey | total |
|---|---:|---:|---:|---:|---:|---:|---:|
| `/login/` | 18.8 ms | 31.7 ms | 11.9 | 2.9 | 1.2 | 0.3 | 16.3 |
| `/` (XFMG gallery home) | 123.5 ms | 162.3 ms | 37.3 | 5.1 | **50.8** | 0.3 | 93.5 |
| `/whats-new/` | 55.5 ms | 74.0 ms | 36.0 | 5.0 | 8.9 | 0.3 | 50.2 |
| thread page | 55.0 ms | 86.2 ms | 41.6 | 5.6 | 4.3 | 0.4 | 51.8 |
| media item page | 41.7 ms | 60.5 ms | 23.4 | 4.5 | 8.8 | 0.3 | 36.9 |

The gallery home's MariaDB share is one statement: `SELECT COUNT(*) FROM
xf_mg_media_item WHERE (album_state = 'visible' OR album_state IS NULL) AND
category_id IN (<all 31 categories>) AND media_state = 'visible'` (the
pagination total), `type ALL`, about 74 000 rows, 36-56 ms, once per view.  A
covering `(media_state, album_state, category_id)` index turned it into an
index range scan of 55k entries: 47 -> 31 ms on a scratch copy.  The real
fix is for XFMG to cache that total.

### Compression level sweep (Angie CPU ms per request, bytes on the wire)

| Setting | `/login/` Angie CPU | `/login/` KB | thread Angie CPU | thread KB | thread total CPU |
|---|---:|---:|---:|---:|---:|
| brotli 5 (was default) | 2.73 | 13 | 6.47 | 21 | 52.9 |
| **brotli 4 (new default)** | 2.30 | 14 | 3.93 | 23 | 49.7 |
| brotli 3 (1-2 CPU default) | 1.17 | 15 | 2.70 | 24 | 49.1 |
| brotli 1 | 1.17 | 16 | 2.27 | 33 | 49.0 |
| gzip 5, brotli off | 1.73 | 14 | 4.30 | 25 | 49.5 |
| gzip 3 | 1.37 | 15 | 3.07 | 29 | 48.2 |
| gzip 1 | 1.23 | 15 | 2.87 | 31 | 48.2 |

About 1.2 ms of the Angie figure is TLS and request handling; the rest is
the compressor.  PHP, MariaDB and Valkey CPU did not move between rows.

### `opcache.huge_code_pages`

| | thread PHP CPU | whats-new PHP CPU | login PHP CPU |
|---|---:|---:|---:|
| off | 40.5 | 37.0 | 12.9 |
| on (two runs) | 40.3 / 40.1 | 37.3 / 37.1 | 12.3 |

`AnonHugePages` of a worker stayed at 0 kB after the reload: the Ubuntu
build does not map its text segment onto huge pages, so the directive is
inert here.  Not adopted.

### Dev-host validation of 1.15.0 (16 threads / 27 GiB / NVMe, same day)

Fresh 1.14.1 install from the 557-package baseline (3 min 16 s), XenForo
2.3.13 (51 users / 150 threads / 2,400 posts) and WordPress 7.1.4 (202 posts)
deployed from the local archives, `--optimize` (12 s), then the 1.15.0 code:
590 + 161 unit/dry-run checks pass, shellcheck findings unchanged, the
`--optimize` diff against the 1.14.1 tuned state is exactly the crontab
entry, `brotli_comp_level 4` and `gzip_comp_level 4`, the cron entry runs in
1.0 s by hand, and a repeat `--optimize` changes nothing.

Load from the workstation (oha, Wi-Fi, 15 s, 200 connections / 100 for the
uncached and member tiers):

| Scenario | 1.14.1 req/s (p50 / p99 ms) | 1.15.0 req/s (p50 / p99 ms) |
|---|---:|---:|
| xf-guest (cached) | 8023 (24 / 42) | 7991 (24 / 41) |
| xf-guest-uncached | 1210 (83 / 136) | 1043 (96 / 121) |
| xf-member | 1015 (99 / 159) | 893 (112 / 137) |
| xf-member-thread | 531 (189 / 240) | 543 (187 / 283) |
| wp-guest (cached) | 4498 (39 / 106) | 6404 (30 / 54) |
| wp-guest-uncached | 295 (345 / 415) | 301 (338 / 398) |
| wp-member | 286 (355 / 443) | 290 (348 / 440) |
| wp-member-post | 264 (386 / 531) | 268 (379 / 464) |

The two XenForo rows that moved were re-measured with the compression level
flipped back and forth on the same host state: brotli 5 gave 887 and 869
member req/s, brotli 4 gave 851 and 863 (uncached 1017-1038 in all four
runs), so the level does not change throughput at this scale; the samplers
show MariaDB's CPU share rising from 18% to 27% between the two suites
because the job runner executed XenForo's hourly cron for the first time
(the trending-content widget now has data to render, the cost the 1.13.0
audit measured).  The compression saving is the Angie CPU per request
measured on the live origin above, not a throughput change on a 16-thread
LAN host.
## Live XenForo origin audit - non-cacheable pages (2026-11-09)

Host: production XenForo origin, 8 vCPU (Xeon E3-class, 4 cores x 2 threads), 32 GiB,
RAID NVMe, Ubuntu 26.04.1, Angie 1.12.4, PHP 8.5 FPM (`pm=static`, 16
workers), MariaDB 11.8 (1.98 GB pool, 900 MB database, 169 disk reads),
Valkey (sessions + XF registry), XenForo 2.3.10 + XFMG. HTTP/3 already
enabled; Brotli dynamic + static; MariaDB `innodb_flush_log_at_trx_commit=2`;
governor `performance`.

Method: loopback requests to `https://live-origin.example/login/` with `--resolve`
(so the ~300 ms long-haul RTT is excluded), 64-128 requests at 8 concurrent
clients, CPU time from `/proc/<pid>/stat`, PHP-FPM/Angie worker states, and
`ss -x` connection counts. No production data was changed.

### Finding: idle FastCGI keepalive pinned every PHP worker

`upstream local_php` had `keepalive 16` (the tuner wrote `children/2`).  With
16 FPM workers and 16 idle upstream connections, every worker was blocked in
`unix_stream_data_wait` while Angie workers sat in `ep_poll`.  Requests that
landed on an Angie worker without a cached upstream connection waited for the
upstream `keepalive_timeout` (60 s default).

| `/login/`, 64 requests, 8 concurrent | p50 | p90 | p99 | max | >10 s |
|---|---:|---:|---:|---:|---:|
| keepalive 16, default timeout | 21 ms | 31 ms | 60.0 s | 71.5 s | 4-6 |
| keepalive 16 + `keepalive_timeout 5s` | 22 ms | 30 ms | 4.98 s | 4.99 s | 0 |
| keepalive 2 + `keepalive_timeout 5s` | 24 ms | 28 ms | 4.86 s | 4.86 s | 0 |
| **keepalive 1 + `keepalive_timeout 5s`** | **24 ms** | **29 ms** | **0.08 s** | **0.08 s** | **0** |
| **no upstream keepalive, `keep_conn off`** | **25 ms** | **30 ms** | **0.037 s** | **0.09 s** | **0** |

The no-keepalive configuration was validated with 3 x 128 requests: p50
24-25 ms, p99 33-38 ms, max 93 ms, and only the FPM listener socket remained
(`ss -x` = 1).  Sequential latency stayed at 14 ms.  It is the simplest safe
setting, so `setup.sh` now removes the directive and the config repo ships
`fastcgi_keep_conn off`.

### Other measurements

- **FPM children:** 8 / 12 / 16 / 24 / 32 workers gave the same p50
  (25-28 ms) and p99 (31-72 ms) for 128 `/login` requests at 8 concurrent
  clients; 16 (2 per logical CPU) is kept for media/job bursts.
- **Guest pages:** cached `/` 5.4 ms, 200 rps at 8 clients; the FastCGI cache
  is not affected by the keepalive fix.
- **Perf:** 20% of samples were idle even during the 8-client burst; top PHP
  symbols were `zend_hash_find` (1.5%), `execute_ex` (1.2%), `_emalloc`
  (0.7%).  The page is not CPU-bound at current traffic.
- **MariaDB:** buffer pool holds the whole 900 MB database (`read_requests`
  95M vs `reads` 169); one 1.44 s `DELETE FROM xf_content_activity_log WHERE
  log_date < ...` (352k rows) was the only slow query, a scheduled cleanup.
- **Live bug (not performance):** Angie's error log repeats `open()
  /var/www/<site>/public/data/xfmg/video/... failed (13: Permission
  denied)`; the video subdirectories are `root:www-data 2710` while the rest
  of `data/` is `www-data`.  Videos served from those paths return 403.

## setup.sh 1.14.0 - dev-host JIT/PHP-FPM sweep, modularization and parity (2026-11-09)

Host: dev host, 16 threads (8 cores) / 27.2 GiB / NVMe, Ubuntu 26.04.1, clean
557-package baseline. Fresh install from the local checkouts
(`--basic server=dedi --angie --php --mariadb user=demo pass=temp --valkey
--elastic --others all`, 1 min 35 s), then `--optimize` (12 s). XenForo
2.3.13 (CLI `xf:install`, friendly URLs, 50 members / 150 threads / 2,250
replies) and WordPress 7.1.4 (`wp_install()` from the CLI, 200 posts / 201
comments, `/%postname%/`) were deployed from the local archives; a second
`--optimize` (10 s) capped the pool at 32 workers and enabled the WordPress
guest cache.

### Install/optimize parity

Captured 11 configuration trees (`/etc/angie`, `/etc/php`, `/etc/mysql`,
`/etc/valkey`, `/etc/elasticsearch`, `/etc/systemd/system`, `/etc/sysctl.d`,
`/etc/security/limits.d`, `/etc/logrotate.d`, `/etc/default`,
`/var/www/logs`) plus enabled units, active units, sysctls, crontab and the
package list. After install vs after `--optimize`: every configuration tree
digest was identical; only runtime counters (`fs.file-nr`,
`fs.dentry-state`, conntrack, ns_last_pid) and log contents changed. A repeat
`--optimize` changed nothing and reloaded nothing ("configuration already
optimized" for all five services).

The `lib/*.sh` split was verified by concatenating driver head + modules +
tail and diffing against the pre-split file: byte-for-byte identical.

### OPcache JIT sweep (PHP 8.5.12, 32 workers, 100 connections, 20 s)

| Variant | xf member req/s (p50/p99 ms) | xf thread | wp member |
|---|---:|---:|---:|
| tracing, 64 MB buffer | **909** (69 / 99) | **485** | **234.5** (283 / 800) |
| tracing, 128 MB buffer | 906 (69 / 99) | 485 | 229 (285 / 1095) |
| tracing, 256 MB buffer | 899 (73 / 102) | 473 | 225 |
| function, 128 MB buffer | 852 (76 / 109) | 437 (151 / **554**) | 251 |
| tracing, aggressive hotness (16/64/8/32) | 911 (69 / 100) | 484 | 262 |
| tracing, conservative (128/255/32/128) | 889 (72 / 102) | 475 | 267 |
| JIT off | 864 (73 / 103) | 475 | 244.5 (273 / 658) |

Tracing beats JIT off by ~5% on XenForo members and ties on WordPress
members (WordPress guest-uncached is 7% better with tracing). 64 MB and
128 MB are within noise; 256 MB is slower; `function` is 6-8% slower with a
554 ms p99. The chosen profile is tracing / OPcache÷8 (64 MB with a 512 MB
OPcache) and PHP's default thresholds on 4+ CPUs.

### PHP-FPM pool size (tracing/64 MB, 100 connections, 15 s, two runs)

| Workers | xf member req/s / p50 | xf thread req/s / p50 | wp member req/s / p50 |
|---:|---:|---:|---:|
| 16 | 645 / 22 ms | 456 / 35 ms | 233 / 67 ms |
| 24 | 886 / 26 ms | 515 / 46 ms | 242 / 95 ms |
| **32** | **942 / 33 ms** | **511 / 62 ms** | 241 / 130 ms |
| 40 | 932 / 41 ms | 506 / 80 ms | 238 / 169 ms |
| 64 | 914 / 68 ms | 492 / 138 ms | 231 / 280 ms |
| 96 | 921 / 103 ms | 495 / 201 ms | 236 / 420 ms |

32 workers (2 per logical CPU) is the knee: it maximises throughput and
halves p50/p99 against the old 4-per-CPU cap. Higher counts only grow the run
queue; 16 leaves half the CPU idle. CPU busy at 32 workers is 86-91% during
the member runs, i.e. the pool is sized to the cores rather than overcommitted.

### Full suite, before vs after (12 s, 200 connections cached / 100 otherwise)

| Scenario | 1.13.1 (64 workers, JIT 128M) | 1.14.0 (32 workers, JIT 64M) |
|---|---:|---:|
| xf-guest (cached) | 7668 (25 / 45 ms) | 8185 (24 / 41 ms) |
| xf-guest-uncached | 1059 (60 / 89) | 1045 (31 / 46) |
| xf-member | 930 (**70 / 99**) | 954 (**34 / 50**) |
| xf-member-thread | 495 (140 / 180) | 505 (**59 / 114**) |
| wp-guest (cached) | 6038 (32 / 61) | 4010 (43 / 129) *link-bound, Wi-Fi noise* |
| wp-guest-uncached | 285 (232 / 288) | 261 (**125 / 195**) |
| wp-member | 270 (254 / 352) | 249 (**130 / 218**) |
| wp-member-post | 244 (278 / 397) | 231 (**140 / 227**) |

Guest cached pages are served by the Angie FastCGI cache and stay link-bound
(7-8k req/s over the Wi-Fi link); the authenticated and uncached tiers are
CPU-bound and now run with half the latency. No 429s (the workstation is in
`LIMIT_REQ_EXEMPT`), no FPM `max children reached`, no new PHP-FPM/Angie/
MariaDB error entries, and the MariaDB slow log stayed empty. The PHP-FPM
slow log recorded WordPress block-render traces under 100 concurrent members
(at 10 s), the expected cost of CPU saturation at maximum throughput.

## setup.sh 1.13.0 - dev-host audit, refactor validation and authenticated-tier tuning (2026-11-09)

Host: dev host, 16 threads / 27.2 GiB / NVMe, Ubuntu 26.04.1, wiped to the
557-package baseline. Fresh install with the local checkouts (`--basic
--angie --php --mariadb --valkey --elastic --others all --domain
xf.test.local app=xf ... --domain wp.test.local app=wordpress ...`, 97 s)
followed by `--optimize` (11 s): the 308-file configuration snapshots were
identical except the root crontab, whose vixie header timestamp changed on
every run because `write_cron` reinstalled an unchanged crontab (fixed in
1.13.0; a repeat `--optimize` now changes no file at all). XenForo 2.3.13
(50 members / 150 threads / 2,400 posts) and WordPress 7.1.4 (10
subscribers / 200 posts / 996 comments) were installed into the vhosts plus
the synthetic `stress.invalid` site; the next `--optimize` enabled the
WordPress guest cache and hardened `wp-config.php`. The pool stayed at 144
workers (16 per core): the application cap (4 per core) applies only when
every PHP vhost is XenForo/WordPress, and the synthetic site is neither.

Load generator: `oha` from an Apple-silicon Mac over Wi-Fi, 15 s per
scenario, 200 connections (100 for uncached/member tiers), the Mac exempted
from Angie's rate limiter; `collect-metrics.sh` sampled the server. Health
counters (segfaults, `max children reached`, Angie/MariaDB error and slow
logs, journal errors) stayed at zero in every run except one XenForo
`request_slowlog_timeout` trace (below).

### Before and after the 1.13.0 refactor (same application state, PHP 8.5.12)

| Scenario | 1.12.0 code req/s (p50 / p99 ms) | 1.13.0 code req/s (p50 / p99 ms) |
|---|---:|---:|
| static | 20262 (9.6 / 17) | 20761 (9.4 / 14) |
| php-hello | 20122 (7.7 / 12) | 18045 (7.7 / 56) |
| mariadb-json | 16404 (8.9 / 15) | 15807 (8.8 / 15) |
| valkey-json | 15503 (8.9 / 21) | 16605 (8.8 / 15) |
| elasticsearch | 8825 (9.6 / 34) | 8236 (9.9 / 37) |
| node-proxy | 17273 (11 / 23) | 15477 (12 / 23) |
| full-uncached | 6880 (20 / 38) | 6371 (22 / 40) |
| full-cached | 19650 (9.7 / 20) | 22657 (8.6 / 15) |
| xf-guest (cached) | 8335 (22 / 42) | 8341 (23 / 41) |
| xf-guest-uncached | 1074 (93 / 128) | 1060 (94 / 134) |
| xf-member | 926 (108 / 148) | 845 (110 / 237) |
| xf-member-thread | 301s (bad URL) | 469 (226 / 285) |
| wp-guest (cached) | 4548 (41 / 89) | 4401 (45 / 80) |
| wp-guest-uncached | 251 (410 / 506) | 250 (413 / 486) |
| wp-member | 247 (425 / 553) | 243 (434 / 716) |
| wp-member-post | 223 (469 / 628) | 219 (478 / 583) |

The link-bound tiers move within the Wi-Fi noise band (the 1.12.0 column
ran while nothing else happened; the 1.13.0 full suite overlapped a
`test-tuning.sh` run on the host, and the XenForo/WordPress rows were
repeated on the idle host). The only real difference is `xf-member`: its
p99 doubled because XenForo's *Trending content* widget enqueued its job
(`XF\Job\Manager::_enqueue` on `xf_job`) under 100 concurrent members and
one request waited more than 10 s on that row lock (the single slow-log
entry). The 1.13.0 host changes measured here: `vm.swappiness=1`,
`ip_local_reserved_ports`, `netdev_budget 600/8000`, `directio 16m`,
`opcache.max_accelerated_files` 128256 -> 16384 (9.6k PHP files x 1.5,
rounded up by PHP to 32531 buckets), Aria page cache 108 -> 217 MB,
`node.processors: 16`. None of them moved a CPU-bound tier.

### Authenticated tier: what actually helps (PHP 8.5.12, idle host, 100 connections)

| Step | xf-guest-uncached | xf-member | xf-member-thread | wp-guest-uncached | wp-member |
|---|---:|---:|---:|---:|---:|
| widgets on, `localhost`, no cache | 1060 (94 / 134) | 845 (110 / 237) | 469 (226 / 285) | 250 (413 / 486) | 243 (434 / 716) |
| Members online / Trending / Featured widgets off | 1222 (75 / 185) | **1129 (88 / 123)** | 476 (223 / 282) | 253 (406 / 492) | 250 (426 / 528) |
| + XenForo `p:localhost` (persistent MariaDB) | **1328 (75 / 102)** | 1110 (90 / 131) | 459 (226 / 311) | WordPress 500 | WordPress 500 |
| + XenForo Valkey cache + sessions (Unix socket) | 1339 (74 / 102) | 1125 (89 / 121) | 467 (223 / 318) | - | - |
| Valkey + persistent, widgets back on | 1048 (95 / 127) | 912 (109 / 155) | 468 (223 / 295) | - | - |

- The three sidebar widgets cost a third of the authenticated throughput
  (845 -> 1129 req/s) and most of the tail latency; the forum list without
  them is CPU-bound in PHP, not in MariaDB. The report already recommended
  this; it is now backed by numbers from this host.
- A persistent MariaDB connection for XenForo adds 8-9% on the uncached
  guest page (one TCP/auth handshake less per request); the member page is
  unchanged (its cost is template rendering).
- XenForo's Redis provider on the local Valkey socket (registry cache plus
  sessions, 40 keys) is neutral on a single host with a local database,
  matching the 1.11.0 finding; it is a multi-node tool.
- **`define('DB_HOST', 'p:localhost')` breaks WordPress.**
  `wpdb::parse_db_host()` splits the value at the first colon and connects
  to host `p`, so every page is "Error establishing a database connection"
  (HTTP 500 for the whole run). The optimize report used to recommend it;
  1.13.0 flags a `p:` WordPress host as broken instead and no longer counts
  a plain host as an issue (WordPress core has no persistent-connection
  option).
- The thread page (476 req/s, 223 ms) is the slowest XenForo member tier
  and did not move with any setting: it renders 15 posts with bbcode and
  attachments per request and is pure PHP CPU.

### PHP 8.4 OPcache JIT through the script's own switches (XenForo, widgets off, persistent + Valkey)

The host was moved to PHP 8.4.27 with `--purge --php ver=8.5` and `--basic
--php ver=8.4` (64 s; both sites kept working on the new socket), then
`SETUP_PHP_JIT` drove `--optimize` (graceful PHP reload each time, the
OPcache file cache wiped before the measurement; the `[PATH=]` section kept
`opcache.jit` off for the WordPress root, verified with the status probe:
XenForo root `on=true`, WordPress root `on=false`, 837 KB compiled).

| Scenario | JIT off | tracing (WordPress roots off) | tracing everywhere |
|---|---:|---:|---:|
| xf-guest-uncached | 1109 (89 / 130) | 1132 (88 / 123) | 1110 (88 / 145) |
| xf-member | 959 (104 / 156) | 978 (102 / 150) | 980 (102 / 145) |
| xf-member-thread | 485 (216 / 288) | **509 (207 / 281)** | 506 (207 / 280) |

The tracing JIT is worth 2-5% on the XenForo tiers on 8.4 (the thread page
most, as in 1.12.0) and nothing crashed; the default stays off because the
gain is small and the php-fpm 8.3 segfault on a live WordPress site still
stands. The WordPress rows of this run are not reported: they answered
"Too many connections" for 80% of the requests, which exposed the last
1.13.0 fix below.

### `max_connections` and persistent connections (found by this run)

With XenForo on `p:localhost`, each of the 144 PHP workers keeps one MariaDB
connection open for its lifetime; the WordPress requests served by the same
workers then open a second, transient connection, so the pool needed up to
288 connections against the `workers x 1.25 + 50 = 230` ceiling
(`Max_used_connections` 231, `Aborted_connects` 26,713). 1.13.0 counts the
XenForo configs with a persistent host and allows one extra connection per
worker for each of them (`144 x (1 + 1) x 1.25 + 50 = 410` here); the
optimize report says so. The clean WordPress JIT comparison was not repeated
in this session (credit limit); the 1.12.0 table for PHP 8.4 remains the
reference (JIT off vs tracing within 3-4% on WordPress).

## setup.sh 1.12.0 - dev-host re-validation and OPcache JIT benchmark (2026-11-09)

Host: dev host, 16 threads / 27.2 GiB / NVMe, Ubuntu 26.04.1, wiped to the
557-package baseline, installed with `--basic --angie --php --mariadb --valkey
--elastic --others all --domain xf.test.local app=xf ... --domain
wp.test.local app=wordpress ...` (2 min 24 s), then `--optimize` (11 s): the
post-install and post-optimize snapshots of 308 managed files were identical
except for the crontab's install-timestamp comment. XenForo 2.3.13 (CLI
`xf:install`, friendly URLs, 50 members / 150 threads / 2,400 posts seeded
through XF's own services) and WordPress 7.1.4 (`wp_install()` from the CLI,
10 subscribers / 200 posts / 996 comments, `/%postname%/` permalinks) were
installed into the two vhosts; a second `--optimize` then capped the pool at
64 workers (4 per core), enabled the WordPress guest cache and hardened
`wp-config.php`.

Load generator: `oha` from an Apple-silicon Mac over Wi-Fi (link-bound for
the cached guest tiers; the uncached and member tiers are server-CPU-bound at
100% and comparable between runs), 15 s per scenario, 200 connections for the
cached guest pages and 100 for everything else; `collect-metrics.sh` sampled
the server every 5 s. "uncached" guest requests carry a cookie that bypasses
the guest cache without being a login (`xf_session=bench`,
`comment_author_bench=1`); member requests carry a real session cookie.
Health counters (php-fpm segfaults, `max children reached`, slow log, Angie
error logs, MariaDB slow queries, journal errors) were zero before and after
every run.

### PHP 8.5.12 (deb.sury.org), JIT off vs tracing vs function

| Scenario | JIT off req/s (p50 / p99 ms) | tracing 64M | function 64M | tracing 256M |
|---|---:|---:|---:|---:|
| xf-guest-cached | 8489 (22 / 39) | 8921 (22 / 38) | 8686 (22 / 38) | 8436 (23 / 47) |
| xf-guest-uncached | 1111 (58 / 84) | 1083 (59 / 85) | 1062 (61 / 86) | 1085 (59 / 86) |
| xf-guest-thread-u | 652 (100 / 138) | 621 (106 / 142) | 616 (106 / 145) | 630 (104 / 142) |
| xf-member-home | 956 (67 / 96) | 924 (70 / 98) | 915 (70 / 98) | 924 (67 / 95) |
| xf-member-forum | 679 (96 / 129) | 653 (100 / 134) | 646 (101 / 136) | 656 (99 / 133) |
| xf-member-thread | 483 (141 / 188) | 463 (147 / 197) | 431 (149 / 246) | 467 (145 / 197) |
| wp-guest-cached | 4605 (40 / 78) | 4728 (42 / 65) | 4246 (40 / 85) | 4277 (45 / 90) |
| wp-guest-uncached | 255 (259 / 343) | 252 (263 / 342) | 248 (267 / 347) | 250 (263 / 334) |
| wp-guest-post-u | 230 (285 / 427) | 226 (287 / 522) | 227 (289 / 444) | 225 (289 / 501) |
| wp-member-home | 246 (275 / 409) | 244 (278 / 415) | 238 (280 / 490) | 243 (272 / 466) |
| wp-member-post | 225 (298 / 438) | 223 (300 / 443) | 221 (304 / 431) | 222 (302 / 419) |

Every mode is within run-to-run noise (about 3%) of JIT off, and
`opcache_get_status()['jit']` explains why: on this 8.5.12 build the JIT
reports `on=true` but the buffer use stays at 2,373 bytes in every mode, for
the FPM pool and for a CLI hot-loop test alike, and `opcache.jit_debug=1`
prints nothing. The JIT compiles nothing on PHP 8.5.12 as packaged, so
enabling it only costs the per-request mode checks.

The per-application mechanism was verified on the same pool: with
`opcache.jit=tracing` pool-wide and a `[PATH=/var/www/wp.test.local/public]`
section setting `opcache.jit=off`, `opcache_get_status()` fetched through the
XenForo root reported `on=true` and through the WordPress root `on=false`
(both with the cache bypassed), and the WordPress numbers matched the JIT-off
run (248 / 239 req/s guest-uncached / member-home).

### PHP 8.4 (deb.sury.org), the same matrix

PHP 8.4 was installed with `--purge --php ver=8.5` followed by `--basic --php
ver=8.4` (the documented version switch; XenForo and WordPress kept working
on the new socket) because its JIT does compile (the CLI hot loop grows the
buffer in both modes).

| Scenario | JIT off req/s (p50 / p99 ms) | tracing 64M, file cache cleared | function 64M, file cache cleared | tracing 64M, file cache kept |
|---|---:|---:|---:|---:|
| xf-guest-cached | 8350 (23 / 39) | 8552 (23 / 41) | 8001 (24 / 41) | 8300 (24 / 38) |
| xf-guest-uncached | 1120 (57 / 87) | 1152 (55 / 87) | 1070 (59 / 90) | 1077 (59 / 87) |
| xf-guest-thread-u | 645 (100 / 137) | 672 (97 / 131) | 603 (108 / 146) | 617 (106 / 143) |
| xf-member-home | 957 (68 / 97) | 986 (65 / 93) | 922 (70 / 102) | 851 (71 / 182) |
| xf-member-forum | 670 (97 / 134) | 699 (93 / 128) | 588 (103 / 235) | 628 (100 / 226) |
| xf-member-thread | 478 (142 / 186) | 500 (136 / 179) | 454 (149 / 201) | 467 (145 / 191) |
| wp-guest-cached | 4307 (44 / 100) | 4186 (46 / 89) | 4267 (45 / 100) | 4563 (43 / 79) |
| wp-guest-uncached | 252 (261 / 343) | 261 (253 / 330) | 253 (259 / 338) | 247 (265 / 368) |
| wp-guest-post-u | 229 (287 / 433) | 232 (277 / 662) | 227 (287 / 522) | 226 (289 / 431) |
| wp-member-home | 244 (276 / 420) | 253 (265 / 393) | 244 (277 / 420) | 241 (280 / 436) |
| wp-member-post | 223 (301 / 429) | 231 (291 / 413) | 224 (298 / 421) | 221 (305 / 436) |

The first 8.4 pass (last column) was as flat as 8.5 until
`opcache_get_status()` showed the same 2.5 KB buffer use: scripts restored
from `opcache.file_cache` (`/var/cache/php/opcache`) are never JIT-compiled,
and after a php-fpm restart every script comes from that cache. With the
directory cleared before the restart the warm-up alone compiled 850 KB, and
the tracing JIT then gains 3-5% on every CPU-bound tier (XenForo member home
957 -> 986 req/s, member thread 478 -> 500, member forum 670 -> 699,
WordPress uncached 252 -> 261, member 244 -> 253; p50 3-5% lower) at 0.9 MB
of compiled code. The function JIT compiles everything, filled 61 MB of the
64 MB buffer and was equal or slower (member forum 588). Health counters
stayed at zero (no segfault) in every run. 1.12.0 therefore leaves
`opcache.file_cache` empty while `SETUP_PHP_JIT` is on, defaults to off, and
keeps WordPress roots off through the `[PATH=]` section when it is on.

### Code changes measured after the review

The five reviews (PHP, MariaDB, Angie, Valkey/Elasticsearch, OS/CLI) and the
host runs produced the 1.12.0 fixes listed in CHANGELOG.md; the ones with a
measured effect on this host: `--optimize` now reloads Angie once per run
instead of twice (and not at all when the tree is unchanged), the first
`--optimize` on a host with `valkey.conf` changes keeps the cache (the
online `CONFIG SET` loop no longer fails on `io-threads-do-reads`), Valkey
starts at 434 MB instead of 128 MB on this 27 GB host, and XenForo PHP
responses carry HSTS and Referrer-Policy again.

## setup.sh 1.11.0 - dev-host audit run and XenForo profiling (2026-11-09)

Host: dev host, 16 threads / 27.2 GiB / NVMe (Crucial P3 Plus), Ubuntu 26.04.1,
Angie 1.12.4, PHP 8.5.12, MariaDB 11.8.6, Valkey 9.0.4, Elasticsearch 9.5.6,
reached over **Wi-Fi** only (the wired port had no carrier), so every
link-bound number tops out around 90 MB/s. The host was wiped to the
557-package headless baseline, installed in 1 min 42 s with `--basic --angie
--php --mariadb user=demo pass=temp --valkey --elastic --others all --domain
xf.test.local app=xf db=xenforo user=xfuser pass=...` from the local
`server-configs-nginx` checkout (`CONFIG_SOURCE_DIR`), then `--optimize`
was run: the 241-file configuration snapshots before and after were
identical apart from the crontab's install-timestamp comment. Static checks
(`bash -n`, shellcheck), the 101-case dry-run matrix, the tuning suite (439
checks before the changes, 479 after), `--optimize --dry-run`,
`--optimize`, `--diagnostics`, `--restart-all --dry-run`, `--restart-all`
and `--purge all` all completed without errors on the live host.

Load generator: `oha` 1.16.0 on the Mac mini (`run-stress-remote.sh`, 200
connections, 15 s per scenario, HTTPS keep-alive, Mac exempted from the rate
limiter with `SETUP_LIMIT_REQ_EXEMPT`); `collect-metrics.sh` sampled the
server every 5 s.

| Scenario | req/s | p50 | p90 | p99 | Status |
|---|---:|---:|---:|---:|---|
| static | 21,400 | 9.2 ms | 11.5 ms | 14.0 ms | 200 only |
| php-hello | 20,438 | 7.8 ms | 9.7 ms | 11.9 ms | 200 only |
| mariadb-json | 18,263 | 8.3 ms | 10.4 ms | 13.0 ms | 200 only |
| valkey-json | 16,637 | 8.7 ms | 10.9 ms | 13.1 ms | 200 only |
| elasticsearch (100 conns) | 9,777 | 8.9 ms | 14.1 ms | 28.4 ms | 200 only |
| node-proxy | 18,133 | 10.8 ms | 13.6 ms | 17.0 ms | 200 only |
| full-uncached-200 | 7,067 | 19.8 ms | 26.2 ms | 35.0 ms | 200 only |
| full-cached-200 | 21,120 | 9.3 ms | 11.7 ms | 14.4 ms | 200 only |
| slow-1s-200 | 148 | 1.02 s | 1.10 s | 1.24 s | 200 only |

Within a few percent of the 1.9.0 run below. Server-side samples showed no
PHP-FPM listen-queue growth or `max children reached`, no MariaDB slow
queries, disk temp tables or aborted connects, no Valkey evictions or
rejections, and no Elasticsearch search rejections. The only journal errors
during the runs came from the udev I/O rule firing on partitions (fixed in
1.11.0).

### XenForo 2.3.13: guest and member tiers

Installed into the `--domain xf.test.local app=xf` vhost from the local
archive (CLI `xf:install`, friendly URLs on) and seeded through XF's own
services (`XF\Service\User\RegistrationService`, `Thread\CreatorService`,
`Thread\ReplierService`) with 50 members, 150 threads and 2,400 posts.
Guest runs use 200 connections, uncached-guest and member runs 100, 12 s
each; "uncached guest" sends a dummy `xf_session` cookie to bypass the
guest cache.

| Tier / scenario | 144 workers (plan) | 48 workers | 64 workers (app cap) | 64 + Valkey cache/sessions |
|---|---:|---:|---:|---:|
| guest, cached home | 8,084 req/s, p50 24 ms | 8,191, 24 ms | 8,767, 22 ms | 8,629, 23 ms |
| guest, cached thread | 6,465, 29 ms | 6,843, 28 ms | 7,033, 28 ms | 6,885, 28 ms |
| guest, uncached home | 1,146, **87 ms** (p99 125) | 1,168, **41 ms** (p99 61) | 1,149, 56 ms (p99 79) | 1,154, 56 ms |
| guest, uncached thread | 712, 143 ms | 706, 69 ms | 719, 91 ms | 721, 90 ms |
| member home | 934, **107 ms** (p99 150) | 949, **51 ms** (p99 73) | 883, 73 ms (p99 102) | 888, 73 ms |
| member thread | 516, 205 ms | 500, 101 ms | 495, 137 ms | 494, 136 ms |
| member forum view | - | 687, 72 ms | 659, 100 ms | 667, 100 ms |

| Static asset `/js/xf/core-compiled.js` (177 KB, 200 conns) | req/s | server CPU |
|---|---:|---|
| dynamic Brotli/gzip per request (`brotli_static off`, no siblings) | 1,859 (br) / 1,719 (gzip) / 512 (identity, 88 MB/s link limit) | **50-89%** of 16 cores |
| precompressed siblings (`SETUP_PRECOMPRESS_ASSETS=1`) | 1,675 (br) / 1,825 (gzip) / 562 (identity) | **2-5%** |

Findings and what was changed:

- **Guest pages are solved by the edge cache; the remaining origin cost was
  compression.** Cached guest pages are link-bound (8k req/s at 22 ms p50 is
  the Wi-Fi round trip, server ~20%). Every static-asset request was
  compressed on the fly (41% of the host for cached HTML was already fixed in
  1.9.0 by keying the cache on encoding); the JS/CSS assets a first-time
  visitor or a crawler fetches cost up to 89% of the host at under 2k req/s.
  1.11.0 adds opt-in precompressed siblings with `brotli_static`/`gzip_static`
  (2,575 files for this board, 50 s for the first `brotli -q 11` pass, no-op
  afterwards) and a 5-minute cron refresh; the same request rate then costs
  2-5%. It stays off by default for CDN-fronted origins.
- **The member tier is PHP CPU-bound and over-provisioned by the memory
  plan.** 144, 64 and 48 workers all deliver ~900-950 member req/s at 100%
  CPU; only latency changes (p50 107 / 73 / 51 ms). 1.11.0 caps the pool at
  4 workers per core (3 on a VPS) when every PHP vhost is XenForo/WordPress
  with a local database; 4 rather than 3 leaves headroom for the I/O-bound
  requests those applications still have (`proxy.php` image proxy,
  attachment downloads).
- **Valkey as XF cache and session store changes nothing on a single host:**
  888 vs 883 member req/s and 72.5 vs 73 ms p50 with 24.5k keys and 1.8 M
  keyspace hits during the run. MariaDB stayed below 20% CPU in every member
  scenario with no slow queries or disk temp tables. The `--optimize` report
  keeps recommending the socket configuration as a hint for multi-host or
  remote-database deployments only.

Packages added to the 557-package baseline by this run: the 81 packages
listed for 1.9.0 (`angie ... valkey-tools`, without `fail2ban`, which 1.10.0
removed) plus `brotli` (`SETUP_PRECOMPRESS_ASSETS=1`) and the test tooling
`shellcheck`. `--purge all` stopped every service and restored the recorded
originals; `restore-baseline.sh` then purged the packages, trees, data and
state and left an empty package diff against the baseline.

## setup.sh 1.9.0 - dev-host re-validation from a macOS workstation (2026-11-09)

Host: dev host, 16 threads / 27.2 GiB / NVMe (Crucial P3 Plus), Ubuntu 26.04.1,
Angie 1.12.4, PHP 8.5.12 (144 static workers), MariaDB 11.8.6, Valkey 9.0.4,
Elasticsearch 9.5.6. The host was wiped to its 557-package headless baseline,
installed with `--basic --angie --php --mariadb --valkey --elastic --others
all --domain ...` from the refactored script, then `--optimize` was run: the
configuration snapshots before and after `--optimize` were byte-identical
(1.8.59 differed in the MariaDB buffer pool, sized from stale log files).

Load generator: `oha` 1.16.0 on an Apple-silicon Mac mini over 1 GbE
(`tests/stress-site/run-stress-remote.sh`, 200 connections, 15 s per
scenario, HTTPS keep-alive); `collect-metrics.sh` sampled the server every 5 s.

| Scenario | req/s | p50 | p90 | p99 | Status | Peak server CPU |
|---|---:|---:|---:|---:|---|---|
| static | 21,360 | 9.1 ms | 11.5 ms | 14.2 ms | 200 only | ~15% |
| php-hello | 21,023 | 7.6 ms | 9.4 ms | 12.2 ms | 200 only | ~50% |
| mariadb-json | 17,168-18,628 (re-runs) | 8.2 ms | 10.2 ms | 12.8 ms | 200 only | ~60% |
| valkey-json | 17,944 | 8.4 ms | 10.3 ms | 12.4 ms | 200 only | ~55% |
| elasticsearch (100 conns) | 9,745 | 8.8 ms | 13.5 ms | 34.3 ms | 200 only | ~60% |
| node-proxy | 18,159 | 10.7 ms | 13.5 ms | 17.0 ms | 200 only | ~20% |
| full-uncached-200 | 7,214 | 19.6 ms | 24.5 ms | 32.2 ms | 200 only | 94% (CPU bound) |
| full-cached-200 | 23,365 | 8.4 ms | 10.3 ms | 12.6 ms | 200 only | ~20% |
| slow-1s-200 | 142 | 1.02 s | 1.05 s | 1.07 s | 200 only | pool saturated |

Findings:

- **The rate limiter, not the stack, had been the ceiling of every earlier
  external run.** With the stock geo whitelist the same suite reported ~20k
  req/s per PHP scenario, but 99.5% of those responses were `429` (wrk, used
  before, does not report status codes). Angie also wrote one warning per
  rejection: 1.18 M lines / 266 MB of `stress.invalid.error.log` in two
  minutes. 1.9.0 sets `limit_req_log_level info` and adds
  `SETUP_LIMIT_REQ_EXEMPT` for the load generator; the exempt run above is
  the first valid remote measurement of this host.
- The static/cached/PHP-hello scenarios are bound by the single client and
  the LAN round trip (~8 ms p50 at 200 connections, server 15-50% busy), so
  they are not CPU-ceiling numbers; the loopback suite in `run-stress.sh`
  remains the ceiling test. `full-uncached` is the only scenario that
  saturates the server (94% CPU at 7.2k req/s, java ~35%, mariadbd ~14%,
  Angie workers ~9% each).
- No listen-queue overflows, no PHP-FPM `max children reached`, no MariaDB
  slow queries or disk temp tables, no Elasticsearch search rejections, no
  journal errors during the runs. TIME_WAIT peaked at 64k on the server
  (`tcp_tw_reuse=1`, loopback TCP to Elasticsearch/Node per request).
- The first MariaDB scenario after the fresh install measured 13.7k req/s
  with a 125 ms p99 (cold buffer pool/thread pool); two immediate re-runs
  gave 17.2k and 18.6k with a 13 ms p99, so the table shows the re-runs.

Packages added to the 557-package headless baseline by the full-stack test
(85, from `dpkg-query` minus the saved baseline; `shellcheck` and
`libfcgi-bin` are test tooling, everything else was installed by `setup.sh`
or pulled in as a dependency):

`angie angie-module-brotli apt-transport-https cpufrequtils curl elasticsearch
fail2ban fontconfig-config fonts-dejavu-core fonts-dejavu-mono galera-4 gawk
gifsicle git git-man libabsl20260107 libaio1t64 libaom3 libargon2-1 libavif16
libcpufreq0 libdav1d7 libdbi-perl libdeflate0 liberror-perl libfcgi-bin
libfcgi0t64 libfontconfig1 libgav1-2 libgd3 libheif-plugin-aomdec libheif1
libimagequant0 libjbig0 libjpeg-turbo8 libjpeg8 liblerc4 libmariadb3 libmpfr6
libnvme1t64 libpcre2-posix3 libsensors-config libsensors5 libsharpyuv0
libsodium23 libtiff6 liburing2 libwebp7 libx11-6 libx11-data libxau6 libxcb1
libxdmcp6 libxpm4 libxslt1.1 libyuv0 libzip5 mariadb-client
mariadb-client-core mariadb-common mariadb-server mariadb-server-core
mysql-common nodejs nvme-cli php-common php8.5-cli php8.5-common php8.5-curl
php8.5-fpm php8.5-gd php8.5-gmp php8.5-igbinary php8.5-mbstring php8.5-mysql
php8.5-readline php8.5-redis php8.5-xml php8.5-zip shellcheck smartmontools
socat sysstat valkey-server valkey-tools`

A restore script (`restore-baseline.sh`, kept on the host) purges this set
plus the service trees, data directories, state and the stress site and
returned the host to an empty diff against the baseline before each fresh
install in this session.


### XenForo 2.3.13 on the 1.9.0 host: guest and member tiers (2026-11-09)

XenForo 2.3.13 was installed into the `--domain xf.test.local app=xf` vhost
(CLI `xf:install`, friendly URLs on) and seeded through XF's own services with
50 members, 150 threads and 2,250 posts. Measured from the Mac mini over
**Wi-Fi** (the dev host's wired port had no carrier), 12-15 s runs, so absolute
guest numbers are link-bound; the member and uncached-guest numbers are
server-CPU-bound and comparable.

| Tier / scenario | Config | req/s | p50 | p99 | Server |
|---|---|---:|---:|---:|---|
| guest, cached home (200c, `X-5m-Cache: HIT`) | default | 8,190-8,250 | 24 ms | 38-44 ms | 41% CPU (Brotli per hit), ~67 MB/s |
| guest, cached home, `Accept-Encoding: identity` | default | 2,614 | 59 ms | 200 ms | 1-6% CPU, ~92 MB/s = Wi-Fi limit |
| guest, cached thread page (200c) | default | 6,240 | 30 ms | 67 ms | link-bound |
| static `css.php` (200c) | default | 20,513 | 9 ms | 15 ms | client-bound |
| guest, uncached home (100c, cookie bypass) | default, 144 workers | 1,111 | 90 ms | 131 ms | 98-100% CPU |
| guest, uncached thread (100c) | default, 144 workers | 715 | 142 ms | 191 ms | 100% CPU |
| member home (100c) | default, 144 workers | 967 | 104 ms | 149 ms | 100% CPU |
| member thread (100c) | default, 144 workers | 536 | 197 ms | 258 ms | 100% CPU |
| member forum list (100c) | default, 144 workers | 649 | 153 ms | 249 ms | 100% CPU |
| member home / thread / forum list | + Valkey cache & sessions over the socket, `p:` persistent DB | 981 / 540 / 715 | 102 / 191 / 143 ms | 156 / 268 / 206 ms | 100% CPU |
| member home / thread, guest uncached home | + `--php children=48` (3 x cores) | 993 / 555 / 1,140 | **47 / 88 / 42 ms** | **71 / 133 / 65 ms** | 100% CPU |
| member home (200c) | 48 workers | 1,023 | 48 ms | 68 ms | 100% CPU |
| member home | 48 workers, forum-list sidebar widgets removed | 965 | 50 ms | 73 ms | no change on this data set |

Findings and what was changed:

- **Guest tier is solved by the edge cache; the remaining cost is per-hit
  compression.** Every cached hit was Brotli-compressed by Angie (level 5)
  because the cache held the identity body: 41% of 16 cores at 8k req/s,
  about 0.8 ms CPU per page. XenForo gzips its own output (level 9) when the
  client accepts gzip, but the cache key did not vary on encoding, so the
  first visitor's encoding was served to everyone for the TTL. 1.9.0 adds a
  normalised `$setup_cache_enc` (gzip or plain) map and appends it to the
  XenForo cache key, so a gzip client primes a gzip entry that is served
  without recompression and an identity client never receives gzip bytes.
- **A cached 301 outlives a configuration change.** `fastcgi_cache_valid 301
  404 24h` kept the pre-friendly-URL `/ -> /index.php` redirect for 24 h after
  friendly URLs were enabled, which made `/` a redirect loop for guests until
  the cache was purged. Purge `/home/nginx_cache` after changing XF's URL
  options; a shorter 301 TTL in the Angie repository would limit the blast
  radius.
- **The member tier is PHP CPU-bound at ~15 ms per page**, not database,
  cache or session bound: MariaDB stayed at 14-18% CPU with no slow queries
  or disk temp tables, Valkey as the XF cache/session store and a persistent
  database connection changed nothing (within noise), confirming the
  single-host note already in the optimize report.
- **Fewer PHP workers, same throughput, half the latency.** The 144-worker
  pool (sized by the memory plan) and a 48-worker pool (3 x cores) deliver
  the same ~1,000 req/s, but p50 drops from 102 ms to 47 ms and p99 from
  156 ms to 71 ms because a CPU-bound app gains nothing from 9 workers per
  core except contention. For XenForo on a host like this, pass
  `--php children=$((3 * $(nproc)))`; the memory plan then reserves the
  freed RAM for the page cache.
- Removing the featured/trending/members-online sidebar widgets did not
  change the member home page on this seeded board (the page was already
  35 KB); the +39% recorded on an earlier host depended on live widget data.


## Earlier validation runs (1.4.0 - 1.8.50)

Condensed record of the sessions before 1.9.0. Throughput figures are
`run-stress.sh` loopback runs (8 threads / 200 clients, load generator on the
tested host) unless the row says otherwise. Remote runs before the 1.9.0
rate-limiter exemption used `wrk`, which does not report status codes, so
they are indicative rather than ceilings.

| Release | Date | Host | static | PHP hello | Full-stack uncached | Full-stack cached | Finding |
|---|---|---|---:|---:|---:|---:|---|
| 1.4.0 | 2026-11-03 | 16 vCPU / 27.2 GiB | 258,491 | 117,403 | 7,168 | 181,987 | Baseline after the rate-limit, OPcache, thread-pool and Unix-socket fixes; remaining p99 tails were client ephemeral-port exhaustion |
| 1.6.0 | 2026-11-03 | 8 vCPU / 15.1 GiB VPS | 94,056 | 43,119 | 2,525 | 66,951 | CPU-bound on uncached PHP; FastCGI Unix socket +9%; cache ~27x on the same page |
| 1.6.0 soak | 2026-11-03 | same VPS | - | - | 3,212 (50c, 15 min) | 67,010 (200c, 5 min) | Zero errors; access logs reached 2.6 GB, which led to buffered logging and logrotate caps |
| 1.6.7 | 2026-11 | 16 vCPU / 30 GiB VPS | 181,190 | 124,445 | 7,398 | 169,602 | WordPress guest cache 242 -> 9,972 req/s; Valkey socket vs TCP and io-threads measured; Node 4 -> 8 workers +16% |
| 1.6.8 | 2026-11 | 48 vCPU / 125 GiB dedicated | 130,949 | 112,498 | 6,601 | 135,207 | 500 clients exposed a MariaDB socket backlog and 500-connection cap; fixed with `back_log` and host-scaled `max_connections` |
| 24.04 `--optimize` | 2026-11 | 12 vCPU / 62.7 GiB live Ubuntu 24.04 | - | - | - | - | PHP-FPM migrated to the Unix socket (192 workers), 25 GB pool, Valkey 6.4 GB; second run idempotent; live XenForo stayed up |
| 1.6.11 | 2026-11-04 | 48 vCPU / 125 GiB dedicated | 128,738 | 117,206 | 6,163 | 128,811 | Re-validation after the socket migration; 280k static / 179k cached in the aggressive run; no errors |
| Remote origin | 2026-11-04 | 12 vCPU Ubuntu 24.04 origin, `wrk` over HTTPS | 29,118 (RTT-bound) | - | 2,844-2,972 | 4,363 | Uncached PHP CPU-bound at 0% idle with 128 workers; no server-side errors |
| 1.8.36 | 2026-11-05 | 8 vCPU / 15.1 GiB VPS | 156,990 | 68,619 | 3,618 | 93,116 | Every service at 94-100% CPU; WordPress cached 9,028 req/s; Valkey ~200k ops/s on one core |
| 1.8.50 | 2026-11 | dev host, 16 threads / 27.2 GiB / NVMe | 273,123 | 154,058 | 7,686 | 197,738 | Memory plan at 64 MB/worker (144 workers), ES heap 3 GB; XenForo guest HIT 41.9k/35.0k vs logged-in 983/936 req/s |

Durable findings behind the current defaults:

- Guest-page caching is the largest win on every host (2.5k -> 67k on 8 vCPU, 7.7k -> 198k on the dev host for the same page; WordPress 242 -> 9,972); the logged-in and POST bypasses were confirmed each time.
- PHP-FPM over `/run/php/php-fpm.sock` beat loopback TCP (+9% php-hello) and is the default everywhere.
- MariaDB and Valkey on Unix sockets removed the worst p99 tails; per-request loopback TCP (Elasticsearch, Node) exhausts the ephemeral port range, so TIME_WAIT is watched in later runs.
- Valkey: socket 132k/113k vs TCP 70k/76k SET/GET ops/s; `io-threads` 1 -> 4 gave nothing, so 1 stays; one core tops out around 200k ops/s.
- MariaDB `pool-of-threads`, `back_log=65535` and host-scaled `max_connections` fixed the 500-client failure; `Aborted_connects` and `Slow_queries` stayed 0 afterwards.
- The uncached full-stack page is CPU-bound (~2.5-3.6k req/s on 8 vCPU, ~7.2-7.8k on 16 threads), not blocked on one service; more PHP workers only add queueing.
- A load generator sharing the server's cores inflates client-side p99 (Angie `$request_time` p50 was ~4.8 ms while `wrk` reported 900 ms tails); measure from another machine for final numbers.
- XenForo's authenticated ceiling is application work (the per-request `xf_job` upsert); persistent connections and thread-pool knobs moved it +/-2%, disabling the forum-list widgets was the real win.
- Elasticsearch warms from ~7k to ~15.6k searches/s, so suite order matters for that row.
- Restart `php<ver>-fpm` after deploying new PHP files (`realpath_cache_ttl=43200` caused "Unable to open primary script" twice).
