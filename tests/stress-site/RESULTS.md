# Full-stack stress test reports


## setup.sh 1.12.0 - dev-host re-validation and OPcache JIT benchmark (2026-11-09)

Host: dev-host, 16 threads / 27.2 GiB / NVMe, Ubuntu 26.04.1, wiped to the
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

Host: dev-host, 16 threads / 27.2 GiB / NVMe (Crucial P3 Plus), Ubuntu 26.04.1,
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

Host: dev-host, 16 threads / 27.2 GiB / NVMe (Crucial P3 Plus), Ubuntu 26.04.1,
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
**Wi-Fi** (dev-host's wired port had no carrier), 12-15 s runs, so absolute
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
| 1.8.50 | 2026-11 | dev-host, 16 threads / 27.2 GiB / NVMe | 273,123 | 154,058 | 7,686 | 197,738 | Memory plan at 64 MB/worker (144 workers), ES heap 3 GB; XenForo guest HIT 41.9k/35.0k vs logged-in 983/936 req/s |

Durable findings behind the current defaults:

- Guest-page caching is the largest win on every host (2.5k -> 67k on 8 vCPU, 7.7k -> 198k on dev-host for the same page; WordPress 242 -> 9,972); the logged-in and POST bypasses were confirmed each time.
- PHP-FPM over `/run/php/php-fpm.sock` beat loopback TCP (+9% php-hello) and is the default everywhere.
- MariaDB and Valkey on Unix sockets removed the worst p99 tails; per-request loopback TCP (Elasticsearch, Node) exhausts the ephemeral port range, so TIME_WAIT is watched in later runs.
- Valkey: socket 132k/113k vs TCP 70k/76k SET/GET ops/s; `io-threads` 1 -> 4 gave nothing, so 1 stays; one core tops out around 200k ops/s.
- MariaDB `pool-of-threads`, `back_log=65535` and host-scaled `max_connections` fixed the 500-client failure; `Aborted_connects` and `Slow_queries` stayed 0 afterwards.
- The uncached full-stack page is CPU-bound (~2.5-3.6k req/s on 8 vCPU, ~7.2-7.8k on 16 threads), not blocked on one service; more PHP workers only add queueing.
- A load generator sharing the server's cores inflates client-side p99 (Angie `$request_time` p50 was ~4.8 ms while `wrk` reported 900 ms tails); measure from another machine for final numbers.
- XenForo's authenticated ceiling is application work (the per-request `xf_job` upsert); persistent connections and thread-pool knobs moved it +/-2%, disabling the forum-list widgets was the real win.
- Elasticsearch warms from ~7k to ~15.6k searches/s, so suite order matters for that row.
- Restart `php<ver>-fpm` after deploying new PHP files (`realpath_cache_ttl=43200` caused "Unable to open primary script" twice).
