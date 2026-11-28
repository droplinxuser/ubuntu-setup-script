# Changelog

Release notes for ubuntu-setup-script. Current behaviour is documented in
README.md; measurements in tests/stress-site/RESULTS.md.  Per-cycle
reports and raw test logs cited by entries up to 1.21.32 were removed from
the tree on 2026-11-19; retrieve them with `git show 84b0db5:<path>`.
Reports of the 1.21.33-1.21.61 cycles that measured the removed Anubis
filter were deleted from the tree on 2026-11-23 for the same reason;
`git show <commit>:<path>` recovers them.

## 1.22.17 (2026-11-29)

- **Ubuntu's Redis package is replaced by the compiled Valkey** (operator
  decision; it was never replaced before).  `--optimize` now runs the
  migration step on a host whose cache is the `redis-server` package and
  moves it to the source-built Valkey once, sessions included:
  `redis.conf` becomes `/etc/valkey/valkey.conf` with every directive kept
  (only `dir`, `unixsocket`, `pidfile` and `logfile` move to Valkey's
  paths) and the build is installed while Redis still serves; then Redis
  stops (a Redis without persistence gets a snapshot point for that one
  stop), its `dump.rdb` is copied, `redis-server` is disabled and masked
  and Valkey starts.  The cutover requires our binary, PING, at least 95 %
  of the keys of every database (INFO keyspace, not db0's DBSIZE: XenForo
  keeps its cache and sessions in db 1) and a PING as `www-data` on the old
  socket path, which stays a link to `/run/valkey/valkey.sock`
  (`/etc/tmpfiles.d/setup-redis-socket.conf`), so application config is
  never edited.  Any failure stops Valkey without saving and starts Redis
  again from its own, untouched data.  The packages are removed (never
  purged) with the other removals and pinned out; `redis-cli` becomes a
  link to `valkey-cli`.  Redis 7.4+ (RDB Valkey cannot load), AOF,
  modules, `include`, `rename-command`, ACL files, extra instances,
  `redis-sentinel`, a stopped server or a socket outside `/run` keep Redis,
  with the reason in the report.  Checked with real binaries: a live
  XenForo host's `redis.conf` and a Redis 7.0.15 RDB (805 keys in db 0 and
  1 with TTLs, hash, list, set, zset) load in Valkey 9.2.1 with every key,
  value and TTL.
- Before Redis stops, the replacement requires a key count and a finished
  `BGSAVE` with `rdb_last_bgsave_status:ok` (else it is postponed with
  Redis untouched), and the stop itself must write a new `dump.rdb` (Redis
  renames a temporary file over it, so the inode changes; a fresh BGSAVE
  file cannot hide a failed save at the stop); our unit stays disabled until
  Redis has stopped, and Redis's data directory is snapshotted after the
  verified start, outside the cache-down window; an interrupted Redis part
  is handled by the resume step like the other parts; `--valkey` (install
  mode) keeps skipping a Redis host, only `--optimize` replaces it; other members of the `redis` group join the `valkey`
  group; a run interrupted after Valkey already serves the dataset is
  finished forward instead of rolled back; the converted `valkey.conf` is
  0600 from its first byte; a rollback kills Valkey through its cgroup
  (a `SHUTDOWN NOSAVE` through the CLI would reach Redis itself on a TCP
  host whose Valkey is not up yet).  The part has its own state keys
  (`redis`, `redis-remove`), so a host that keeps a redis-server beside a
  Valkey from the valkey-server package settles after one refusal.
  `--purge valkey` on such a host removes the Redis pin, the mask, the
  socket link and the `redis-cli` link.  These came from an adversarial
  review of the change before release.
- A rolled-back replacement leaves the build on disk but never starts it
  beside Redis: outside the migration `valkey_build_ensure` skips a host
  whose `redis-server` serves on a unit that is not ours (it used to look
  only for a missing build record), and the CPU-change rebuild skips a
  Valkey that is not on our unit.
- **PHP workers pick up a new group with a graceful reload.**  Moving the
  cache socket to a group PHP must join (Valkey's install, the Redis
  replacement) restarted PHP-FPM, which removes `/run/php/php-fpm.sock`
  for up to a second: nginx answered 502 to the requests of that moment on
  a busy board.  FPM re-spawns every worker on SIGUSR2 and each worker
  calls `initgroups()`; checked with a real php-fpm 8.5: after the reload
  the worker has the new group and the socket keeps its inode.  A restart
  stays the fallback.

## 1.22.16 (2026-11-28)

- **XenForo's `xf_search_index` moves to InnoDB too** (operator decision:
  XenForo runs on InnoDB FULLTEXT).  1.22.14 left every FULLTEXT table on
  its engine; XenForo's search index is now the exception, up to
  `SETUP_MARIADB_INNODB_SEARCH_MAX_MB` (512).  On a live board (MySQL
  search, MariaDB 10.11) the 781 MB MyISAM table moved in 217 s (the
  FULLTEXT rebuild runs at about 3.6 MB/s) and six frequent terms
  returned the same counts before and after; a two-term query took 52 ms.
  XenForo writes the index at the end of the request that saved a post,
  so a post made during the copy waits for it, and PHP-FPM kills a request
  at 300 s (`request_terminate_timeout`): 512 MB is about 140 s at that
  rate, twice as fast as the limit for a slower host.  A larger index is
  listed with the statement to run off-peak.  Other FULLTEXT tables are
  still left alone.
- Every engine change now says `LOCK=SHARED`: reads go on during the copy
  (the copy algorithm already allowed them; the statement now fails
  rather than silently taking a stronger lock).  Checked on MariaDB 11.8
  with MEMORY, Aria (PAGE, TRANSACTIONAL=1), MyISAM and a XenForo-shaped
  `xf_search_index` with both FULLTEXT keys (MATCH results unchanged).
- **A long copy is no longer thrown away by a 2 s lock wait.**
  `lock_wait_timeout` also bounds the exclusive lock for the final swap
  after the copy, so a reader holding the table at that moment discarded
  the whole copy and the report called it "busy".  A table over 64 MB now
  gets 10 s, is skipped up front while a query on it has run for 2 s or
  more, and a timeout after a copy is reported apart ("copied but not
  moved", run it off-peak).  The review that found this also corrected the
  search cap, first sized for nginx's 360 s instead of PHP-FPM's 300 s.

## 1.22.15 (2026-11-28)

- **XenForo builds are minimal and complete.**  A code scan of three live
  XenForo 2.2/2.3 installs with their add-ons found the script's XenForo
  set short: push notifications (on by default; 216-239 subscribers on
  the scanned forums) call `gmp_strval` without a check in
  minishlink/web-push, and passkeys and the JWT keys call sodium.  The set
  is now mysqli gd curl mbstring xml zip exif gmp sodium (redis and
  igbinary with a Redis cache, as before), and every `php-ext/NAME` an
  installed add-on declares in its `addon.json` (XenForo refuses to
  install or upgrade such an add-on without it; ThemeHouse Holidays
  needs calendar) is built too.  Only names the build can compile are
  taken, so an add-on naming an unbuildable module never fails a build.
- **Migration leftovers leave the build once, on XenForo hosts.**  Hosts
  migrated before 1.22.13 still carried every module Sury loaded in
  `PHP_EXT_EXTRA`.  On a host that serves only XenForo (every vhost root
  present), the next `--optimize` removes, of the names its migration log
  shows the migration wrote, calendar, ftp, gettext, pdo,
  pdo_mysql, shmop, sockets, sysvmsg, sysvsem, sysvshm and xmlreader from
  it (unused by XenForo and its add-ons in the scan; only library code
  XenForo does not load references them) and adds them to `PHP_EXT_DROP`,
  which only stops the current build from carrying them over, so PHP is
  rebuilt without them while the rest of the build is still carried over
  and a name XenForo, an add-on or a later `ext=NAME` needs is still
  built.  ftp counts as a XenForo requirement while `config.php` names an
  FTP adapter.  `PHP_EXT_DROP` clears itself once the active build has
  none of its names.  `PHP_EXT_PRUNED=1` records the run.  Hosts with
  WordPress or another application, and names the operator added, are
  left alone; xmlwriter stays (XenForo's Braintree
  payment provider).  A multi-lens review with adversarial verification
  (two rounds) replaced a first design that used a full build reset (it
  could drop an application's modules after a transient detection miss),
  pruned mixed hosts and operator-added names, and kept the drop list for
  good.
- **`--optimize ext=minimal`** (also `--php ext=minimal`) drops every
  extra except imagick, so the build carries only what the detected
  applications need; names after it are added on top
  (`ext=minimal,intl`).
- The `--optimize --dry-run` plan shows what `ext=` and the leftover
  removal would record and the extension set the next build would carry
  (it used to show only the old list).

## 1.22.14 (2026-11-28)

- **Application tables on MyISAM, Aria and MEMORY move to InnoDB.**  Those
  engines lock the whole table for every write, and readers wait behind
  it.  On a live XenForo origin, the MEMORY `xf_session_activity` table
  (written on each page, read by the online-members join, purged by a cron
  `DELETE`) held guest pages in "Waiting for table level lock" for 3-8 s
  at a time.  Interleaved A/B there (MEMORY, InnoDB, InnoDB, MEMORY,
  MEMORY, InnoDB; 4 minutes each under live traffic, a sequential guest
  probe):

  | Engine | requests | p50 ms | p99 ms | slowest | over 1 s | lock waits/s |
  |---|---|---|---|---|---|---|
  | MEMORY | 2,757 | 229-235 | 426-496 | 3.5-7.8 s | 10 | 1.44-4.08 |
  | InnoDB | 2,901 | 229-236 | 400-425 | 0.48-0.55 s | 0 | 0.00 |

  Every `--optimize` (and the MariaDB re-optimization after a `--domain
  ... sql=` import) now moves such tables in every application database
  (XenForo, WordPress, Chevereto, Polr, Lychee, imports; never MariaDB's
  own schemas) to InnoDB, online and one table at a time.  Tables with a
  FULLTEXT index (InnoDB's full-text search may return other results) and
  tables over `SETUP_MARIADB_INNODB_MAX_MB` (256; the engine change copies
  the table and blocks its writes) are left alone and listed with the
  statement to run by hand, and so are the MyISAM tables of a schema with
  a MERGE table (it only opens MyISAM tables).  `ROW_FORMAT=DEFAULT` lets
  an inherited FIXED or PAGE row format through.  Each `ALTER` waits at
  most 2 s for its table lock (new queries queue behind a waiting
  `ALTER`), so a busy table is retried by the next run instead of stalling
  the site; any other refusal (AUTO_INCREMENT not first in its key, a row
  too large) is a warning with MariaDB's message, raised before any row is
  copied.  The dry run lists the plan; `SETUP_MARIADB_INNODB=0` turns it
  off.  Checked against MariaDB 11.8 (strict mode on) with MEMORY (hash
  index), MyISAM, MyISAM `ROW_FORMAT=FIXED`, Aria `PAGE TRANSACTIONAL=1`,
  FULLTEXT, MERGE, view and AUTO_INCREMENT-second-in-key fixtures: rows
  kept, the MERGE table still reads its children, a table held by `LOCK
  TABLES` skipped after 2 s and converted by the next run, the refusal
  reported with error 1075.  A multi-lens review (bash, MariaDB, the
  applications) with adversarial verification found the MERGE, row-format
  and refusal-reporting cases before release.

## 1.22.13 (2026-11-28)

- **`--optimize ext=LIST` changes the PHP extension set on any supported
  release.**  `--php ext=` needs `--basic`, and installs need Ubuntu 26.04,
  so an operator on 22.04 or 24.04 had no way to trim a migrated build.
  `--optimize ext=` takes the same `NAME`, `-NAME` and `none`, is checked
  before anything changes (an unbuildable or malformed name, an empty list
  and `none` mixed with names are refused), records `PHP_EXT_EXTRA`, and
  the build step rebuilds PHP when the set changed.  The dry run says what
  it would record.
- **The 1.21 -> 1.22 migration builds a minimal PHP** (operator request).
  It used to keep every module the Sury PHP loaded that the source build
  can compile, so a XenForo host carried calendar, ftp, gettext, pdo,
  pdo_mysql, shmop and xmlreader that nothing used.  Now only the modules a
  detected application needs (its extension set, the requirement lists, the
  Redis and SQLite scans), imagick, and the operator's own extras
  (`PHP_EXT_EXTRA`, `--optimize ext=NAME`) are kept; the rest are dropped,
  listed in the dry run and the report with the `ext=NAME` remedy.  With no
  detected application or no requirement lists nothing can be ruled out,
  and every buildable module is kept as before (`MIGRATE_PHP_MINIMAL=0`
  keeps them all too).
- **The SV RedisCache XenForo add-on counts as needing redis and
  igbinary.**  Its Credis client runs without php-redis, but uses it and
  igbinary whenever they are loaded (on a live XenForo origin, PHP 8.1:
  9.3 vs 11.1 us per command; igbinary sessions 333 vs 649 bytes and 1.3
  vs 2.4 us per round trip), and the sessions it stored are
  igbinary-encoded, so a build without them would log every member out.
  `src/config.php` selecting `SV\RedisCache\Redis` now adds both, like
  XenForo's own Redis provider, in the build and in the requirement table.

## 1.22.12 (2026-11-28)

- **nginx CPU pinning is commented out, not deleted, and no stray file is
  written.**  On a host with several NUMA nodes or a CPU quota,
  `--optimize` comments `worker_cpu_affinity auto;` out with a note.  The
  note contains `#`, the delimiter of `tune_replace`'s sed command: sed
  ended the substitution early, deleted the directive, and ran the rest of
  the note as its `w` flag, writing a file named `orker_cpu_affinity auto;
  # setup.sh: 2 NUMA nodes, no pinning#` into the working directory (found
  in `/root` on a live 2-node EPYC host).  `tune_replace` now escapes `#`
  in the pattern and the replacement.  nginx ran unpinned either way, as
  intended.

## 1.22.11 (2026-11-28)

- **imagick is an optional PHP extension** (operator request; never
  installed by default).  `--php ext=imagick` adds PECL imagick (newest
  stable from pecl.php.net) compiled into PHP with a static ImageMagick 7
  (the release imagemagick.org links, SHA-256 checked) built from source
  on the recipe's own libjpeg-turbo, libpng, libwebp and zlib-ng: Q16, no
  HDRI, no OpenMP, no modules, only the JPEG, PNG, WebP and built-in GIF,
  BMP and ICO coders, nothing linked from Ubuntu.  Its security policy is
  compiled in (zero configuration, so no policy.xml can go missing): an
  allowlist of those raster formats; PDF and PostScript (Ghostscript),
  SVG, MVG, MSL, TEXT and every other coder, every delegate and filter,
  `@file` indirection and `/proc`, `/sys`, `/dev` paths are refused (a
  test build without it read PostScript through the host's Ghostscript
  and `text:/etc/hostname`).  Built and checked with PHP 8.1, 8.5 and 8.6.  `IMAGICK_VERSION` and
  `IMAGEMAGICK_VERSION` (php-build.conf, `latest`) follow new releases
  with the daily refresh like every other component.  A migrated host
  whose Sury PHP loaded imagick keeps it (XenForo's image library set to
  Imagick); a fresh install or a set without it builds exactly as before.
  Tested on a live XenForo 2.2.3 host (Sury PHP 8.0 with Imagick): PHP
  8.1 with imagick rendered every page and made XenForo thumbnails with
  its Imagick driver.

## 1.22.10 (2026-11-28)

- **The warning for a PHP series older than 8.1 gives a usable hint.**  It
  said "re-run --optimize once 8.0.0 is released", advice meant for a
  series not released yet (a Sury RC).  An older series now gets "Move its
  sites to PHP 8.1 or newer (check the applications support it)".  Found on
  a live XenForo 2.2 host whose PHP 8.0 stays on Sury.

## 1.22.9 (2026-11-28)

- **The dry-run no longer promises a Sury purge that will not happen.**  On
  a host whose running PHP stays on Sury (PHP 8.0 here: the source build
  makes 8.1 and newer), the plan said both "Sury keeps serving 8.0" and
  "purge Sury PHP after cutover: 15 package(s)".  The real run was always
  safe (Sury is removed only when every running version is on the source
  build); the plan now says "Sury PHP kept: PHP 8.0 stays on Sury".  Found
  on a live XenForo 2.2 host before its migration.

## 1.22.8 (2026-11-28)

- **A site that `/etc/hosts` maps to loopback is still recognised as
  behind Cloudflare.**  The Cloudflare check resolved names through
  `getent`, so a host whose `/etc/hosts` maps its own site names to
  `127.0.1.1` (cloud-init's `manage_etc_hosts`) saw only loopback: the
  migration warned that a Cloudflare-proxied ACME vhost was "not behind
  Cloudflare", certbot was kept, and the unknown-SNI guard stayed off.
  When every local answer is loopback, the public DNS answer
  (systemd-resolved without `/etc/hosts`) is used instead; a name DNS does
  not answer still never counts as Cloudflare.  Found on a live front
  proxy.

## 1.22.7 (2026-11-28)

Needs server-configs-nginx 1.7.5.

- **The migration renders Angie vhosts with HTTP/3 that set QUIC socket
  options.**  A 1.21 vhost with `listen 443 quic reuseport;` failed
  `nginx -t` ("duplicate listen options for 0.0.0.0:443") against the QUIC
  catch-all's `reuseport rcvbuf=4m sndbuf=4m` (1.22.5), so the nginx part
  was blocked and Angie kept serving.  The fixer ran inside the tree sync,
  before the migration copied the operator's vhosts in; it now runs again
  after the copy.  Found on a live XenForo origin; PHP and Valkey had
  migrated in the same run (sessions kept).
- **A blocked render names what blocks it.**  The report showed the first
  `nginx -t` error (`unknown directive "brotli_static"`), which the fit had
  already commented out, and dropped the fit's own error; it now reports
  the fit's.
- **XenForo's admin Server environment report shows the nginx version**
  (operator request, server-configs-nginx 1.7.5): `SERVER_SOFTWARE` is
  `nginx/<version>` on `admin.php` only and `nginx` everywhere else.

## 1.22.6 (2026-11-27)

Fixes found by the first live `--optimize` of 1.22.5: a 1.21 host (Angie,
Sury PHP 8.3, the valkey-server package) on Ubuntu 24.04, an 8-vCPU KVM
whose CPU is QEMU's generic "QEMU Virtual CPU version 2.5+" (SSE2 only:
no SSSE3, SSE4 or AVX).  1.22.5 migrated its Valkey, then left nginx and
PHP on Angie and Sury; with these fixes the third run migrated both and
exited 0 (every vhost probed, guest cache HIT, no new PHP or XenForo
errors).

- **PHP 8.1-8.4 start on mimalloc.**  PHP loads `opcache.so` (a shared
  module before 8.5) with `RTLD_DEEPBIND`, so its `malloc`/`free` bound to
  glibc while the binary allocates with mimalloc: every candidate aborted
  with `free(): invalid pointer` and the verify kept Sury serving.  The
  build drops `RTLD_DEEPBIND` from `DL_LOAD`, so a module binds to the
  binary's allocator (every other library is linked statically).  PHP 8.5
  and newer, where OPcache is built in, were not affected.
- **zlib-ng builds on a CPU without SSE4.2.**  `-march=native` there turns
  CRC32 off, so zlib-ng 2.3.3's SSE4.2 probe failed while its AVX2 code
  still calls the SSE4.2 Adler-32 routine: `libz.a` did not link and
  neither nginx (`zlib library not found`) nor PHP built.  On such a CPU
  zlib-ng alone is compiled for the x86-64 baseline; its runtime dispatch
  picks the SSE2 code, all that CPU runs.  Other CPUs are unchanged.
- **PHP links on a CPU without AVX2.**  PHP 8.3+ then selects mbstring's
  UTF-8 check through a GNU ifunc, and LLVM 23's ThinLTO link crashed on
  it (`ld.lld` segfault in `computeDeadSymbols`).  On such a CPU configure
  is told there is no ifunc support, so PHP uses its function-pointer
  dispatch; an AVX2 CPU builds as before.
- `--optimize --dry-run` lists the extensions the migration keeps in the
  "effective set" line too (the real run always built them).

## 1.22.5 (2026-11-27)

Operator requests (XenForo search and contact limits, a file-descriptor
plan, Valkey snapshots instead of `noeviction`, a kTLS decision, a MariaDB
and Elasticsearch audit, `mitigations=off` by default, a service watchdog,
alternative allocators and TLS libraries) and the fixes of a read-only gap
audit and a 35-point review of the 1.22.4 tree.  Needs server-configs-nginx
1.7.4 (`main`).  kTLS removed (the `KTLS` build option and every kTLS
path): it measured 12-36 % slower on cached pages on both CPUs (Intel Xeon,
AMD EPYC) and no faster on PHP pages.  nginx now builds on AWS-LC and PHP
on mimalloc (see "New build defaults" below).

Release before/after on the Intel Xeon test host (1.22.4 three times, 1.22.5
twice, interleaved, each applied by `--optimize` and a reboot; XenForo,
req/s as the mean of each arm's 5-round median, AUDIT-20261127-1.22.5.md):

| Tier | 1.22.4 | 1.22.5 | Δ | p99 |
|---|---:|---:|---:|---|
| Guest home (cached) | 121,862 | 160,848 | +32.0 % | 0.90 -> 0.77 ms |
| Guest home (uncached) | 545 | 657 | +20.6 % | 207 -> 172 ms |
| Guest thread (uncached) | 379 | 442 | +16.7 % | 338 -> 282 ms |
| Member home | 487 | 593 | +21.7 % | 242 -> 194 ms |
| Member thread | 290 | 339 | +16.9 % | 467 -> 402 ms |

Under load PHP-FPM uses 322 MB instead of 641 MB and nginx 187 MB instead of
224 MB.  The kernel's `mitigations=off` brings most of it (about +26-29 %
cached and +8-13 % uncached); PHP's mimalloc +3.3-3.8 % on every uncached
tier and the halved PHP memory; dynamic Brotli level 1 +4-5 % uncached;
AWS-LC the cached tier's remaining few percent and a smaller nginx.

- **Valkey's BOLT pass no longer touches the live cache.**  It ran
  `valkey-benchmark` against the production server: about 170 MB of
  LPUSH/SET/HSET into database 9, which `allkeys-lru` paid for by evicting
  live object-cache and session keys, then `FLUSHDB 9`.  The pass now
  profiles a private server started from the LTO binary on a socket in the
  work directory (no port, no persistence, 512 MB, killed on exit); the
  live server is only restarted once, onto the BOLT binary.
- **Redis 6.0 (Ubuntu 22.04) is tuned without a rollback.**  The managed
  block wrote `bind 127.0.0.1 -::1` and `lazyfree-lazy-user-flush`, which
  Redis below 6.2 rejects; it now writes `bind 127.0.0.1 ::1` and leaves the
  key out there.
- **Each PHP series resolves its libraries from its own `build.info`.**  An
  8.1 rollback build on an 8.5 host could take 8.5's OpenSSL record (8.1
  needs OpenSSL 3.x) and its other library versions; OpenSSL now only comes
  from a series on the same side of 8.2, and the other components fall
  back to the active series only when the series has no record.
- **No daily BOLT retries where perf cannot sample branches.**  A VM or a
  CPU without LBR/LbrExtV2 retried BOLT every day and on every
  `--optimize`.  When perf's own error and a one-shot probe both say branch
  sampling (or sampling at all) is unsupported, `build.info` records
  `bolt=nolbr` (or `bolt=noperf`) and nothing retries until the next build;
  a transient perf failure is still retried.
- **More ISA extensions in the CPU fingerprint**, without a rebuild on
  update: the list adds cx16, prfchw, AVX-512 FP16, the AMX/AVX-VNNI
  additions, the AMD-only extensions and others the compiler can emit, so a
  host moved to a CPU that differs only in those is rebuilt.  Flags that
  only intrinsics use, or that kernels and hypervisors hide by policy
  (fsgsbase, rdpid, movdiri, movdir64b, serialize, cmpccxadd, clzero,
  wbnoinvd, pku, sha512, sm3, sm4, amx_fp16), are not hashed, so a boot
  option or a VM CPU model is no longer a "CPU change" that keeps nginx/PHP
  down until a rebuild.  The nginx, PHP and (new) Valkey gates compare the
  recorded `cpu_info=` text as a set, so a flag a newer kernel starts to
  name is tolerated.  Builds recorded by 1.22.0-1.22.4 still match, and
  PHP's static library cache is renamed to the new key once instead of
  being recompiled.
- **The QUIC catch-all scales across workers.**  Both `listen 443 quic`
  lines of `conf.d/1.https.default.conf` gained `reuseport rcvbuf=4m
  sndbuf=4m` (one UDP socket per worker, instead of one shared 256 KB
  socket), and `h5bp/tls/http3.conf` sets `quic_gso on`.  UDP 443 is open
  by default (`ufw allow 443` admits TCP and UDP); the comments and README
  now say so, and the catch-all still refuses every handshake.
- **XenForo private trees match on the directory.**  `/src/` and
  `/internal_data/` (plus the bare names) replace the prefixes that also
  swallowed `/srcset-guide/` and the like.
- **Chevereto uploads near 100 MB get nginx's 413.**  `post_max_size` is
  102M (was 100M), above the vhost's `client_max_body_size 101m`, so PHP no
  longer empties `$_POST`/`$_FILES` for a body between the two.  Behind
  Cloudflare Free or Pro the edge's 100 MB cap applies first (README).
- **`--purge` restores the IP fragment thresholds in a valid order** (the
  low mark first when the recorded high mark is below the live low mark),
  so large-RAM hosts no longer warn "Could not restore
  net.ipv4.ipfrag_high_thresh".
- **`SETUP_WP_GUEST_CACHE=0` removes the include an earlier run added**
  (only the line marked `# added by setup.sh`; an operator's include is
  never touched).
- **nginx CPU pinning is skipped on a cpuset or a multi-node NUMA host**, as
  it already was under a cgroup quota; the reason is in the commented
  `worker_cpu_affinity` line.  Single-node hosts keep `auto`.
- **`scripts/cloudflare.sh` cannot install a truncated range list**: it
  requires a minimum count per family, validates each line, runs `nginx -t`
  before the reload and puts the previous file back on failure.
- **A `redis-server` installed after `--purge valkey` is tuned.**  The
  purge keeps `/etc/valkey/valkey.conf`, and that file alone made
  `--optimize` treat the host as a Valkey host and skip Redis.  A Valkey
  host now also needs a Valkey server (binary or unit).
- **`--purge valkey` restores the TCP port** socket-only mode closed,
  removes the `tcp=on` marker and the Redis guard drop-in, and warns when a
  kept `dump.rdb` was written by the source build (an older packaged
  `valkey-server` cannot load it) with the command that moves it aside.
- **Operator HTTP/3 vhosts keep working with the QUIC catch-all.**  The
  deploy removes `reuseport`, `rcvbuf=`, `sndbuf=` and the other socket
  options from operator `listen ...:443 quic` lines under `conf.d/` (they
  would fail `nginx -t` as duplicate listen options), keeping the original
  line as a comment.
- **A typo in `nginx-build.conf` no longer stops nginx.**  An invalid
  `TLS_LIB` makes `ExecStartPre` and `status` warn and use aws-lc; `build`
  and `check` refuse it, and `--optimize` reports a FAILED line.  `MALLOC`
  and `BOLT_NOLBR` were removed: any value only draws a warning.  A CPU
  rebuild uses the versions `build.info` recorded, except that a build on
  a removed TLS library (openssl, boringssl or none recorded) moves to
  AWS-LC with a looked-up version.
- **The BOLT profiling server for Valkey** no longer inherits the build
  lock and dies with the tool (`setpriv --pdeathsig`).
- **Reports:** the PHP JIT probe reads on/off instead of "unknown" with the
  managed interned-strings buffer; certificate expiry is decided by
  `openssl x509 -checkend`; a Redis-only host shows `maxclients` from
  `redis.conf`; a memory-only NUMA node no longer turns CPU pinning off;
  `SETUP_WP_GUEST_CACHE=0` reports "disabled" instead of "already enabled
  for 0 vhost(s)".
- Smaller: the Valkey socket hint for applications reads the configured
  `unixsocket`; a `valkey.conf` without a `save` line counts as persisting
  (as the migration already did); `/var/cache/php/opcache` is no longer
  created and chowned on every tune (the file cache is off); comment and
  doc fixes (ThinLTO scope in `tools/nginx-build.sh`, the `/attachments`
  limiter comment, early data, the JIT buffer being per pool, the
  challenge-ACK CVE, `CONFIG_REPO_REF` default `main`, port 9000 reserved).

New defaults:

- **XenForo search and contact-form POSTs are rate-limited** (operator
  request).  `POST /search/search` (the search form and the navbar quick
  search, the only requests that run a query) and `POST /misc/contact`
  share the login limiter's zone: 20 a minute per address after a burst of
  10, IPv6 per /64, loopback exempt, the visitor's IP behind Cloudflare.
  Result pages (`/search/N/...`) and every GET stay unlimited.  To undo,
  remove the two alternatives from `http.d/limit_req.conf`.
- **Valkey keeps RDB snapshots** (operator request): `save 300 1` (every 5
  minutes when a key changed, and on every clean shutdown), `appendonly
  no`, `rdbcompression yes`, `rdb-save-incremental-fsync yes`,
  `stop-writes-on-bgsave-error no`, `dump.rdb` in `/var/lib/valkey` (an
  adopted server keeps its `dir`/`dbfilename`).  Existing hosts switch
  online through `CONFIG SET`, and a restart saves and reloads the snapshot,
  so the cache and sessions survive clean restarts, reboots, rebuilds and
  BOLT.  The snapshot is only loaded after a clean stop: after a crash, OOM
  kill, `kill -9`, stop timeout or power loss the cache starts empty and
  the old dump is moved aside to `dump.rdb.unclean-<UTC>` (the 2 newest
  kept), so stale entries never contradict MariaDB.  `TimeoutStopSec=300`
  replaces 0 and Valkey/Redis 7+ get `shutdown-on-sigterm default force`,
  so a final save that cannot finish (disk full) no longer hangs a restart
  or a reboot.  An adopted `redis-server` gets the same guard through
  `redis-server.service.d/zz-setup-rdb.conf`.  An operator AOF setup is
  kept, and an adopted store that keeps `appendonly yes` holds data, so it
  keeps `noeviction`.  The report shows
  the snapshot fork's worst-case copy-on-write against the RAM outside the
  memory plan.  A data-holding host is no longer pinned to its X.Y series
  for RDB (a newer Valkey reads an older RDB); AOF hosts still are, and no
  build ever goes below the version that wrote the data.  There is no
  opt-out flag: `--optimize` writes this schedule over `save ""` (an AOF
  setup is kept as it is).
- **`--valkey policy=noeviction` is removed** (operator request): a full
  cache failed every write.  The flag is refused, and a persisted
  `noeviction` becomes `allkeys-lru` on the next `--optimize` (reported).
  Sessions guidance everywhere: they survive restarts through the RDB
  snapshot, `allkeys-lru` may evict them under memory pressure, so size
  `--valkey ram=` for sessions plus cache, and never use `volatile-*`
  (session keys carry a TTL and are evicted first).
- **Valkey listens on its Unix socket only (`port 0`).**  TCP stays open,
  and the report says why, when a WordPress, XenForo or Chevereto config
  connects over loopback TCP (a Redis Object Cache drop-in with no endpoint
  counts as 127.0.0.1:6379; XenForo in array or context-provider form, W3
  Total Cache in its PHP or JSON config, LiteSpeed Cache, an unknown
  `object-cache.php` drop-in and bare `host:port` entries count too), a PHP
  session handler uses Redis over TCP (php.ini, conf.d or an FPM pool), a
  recent TCP flow is on the port (`ss` and `CLIENT LIST` are sampled 3
  times, 2 s apart, TIME-WAIT included; Unix-socket clients are ignored),
  a running server cannot list its clients, an operator bind serves other
  hosts, or `--valkey tcp=on` is set (an adopted `redis-server` records it
  in `redis.conf`).  The port
  is closed online with `CONFIG SET port 0` (Redis 6 applies it at the next
  restart), and the previous port is remembered for a later TCP mode.
  Opt-out: `--valkey tcp=on` (persisted in `valkey.conf`; `--valkey
  tcp=auto` returns to the default).
- **One `LimitNOFILE` plan** (operator request) sizes each unit together
  with the service's own limit: nginx (`worker_connections x 2 +
  open_file_cache + 1024`, at least `worker_rlimit_nofile`, which is raised
  to the same worst case, rounded to a power of two, when it is below it),
  PHP
  (`rlimit_files`), Valkey (`maxclients + 32`), MariaDB (`open_files_limit`
  as `mariadbd` computes it) and Elasticsearch (65535).  Units are rounded
  up to a power of two, never below the 1.22.4 values and capped at
  `fs.nr_open`: with today's sizing every unit, `rlimit_files` and
  `open_files_limit` is byte-identical to 1.22.4.  `fs.file-max` (and
  `fs.nr_open`) rise, never fall, to the sum of the units present when that
  is above RAM_MB x 1024 (a small all-in-one host or two PHP series).  The
  Valkey build tool keeps a higher limit already in its unit, so a timer
  rebuild never lowers it.  `fs.nr_open` and `fs.file-max` are never
  written below the system's own value (stock Ubuntu already boots far
  above the target, so nothing is written there), and a live value an
  older release lowered is raised back.
- **`mitigations=off` on every managed host** (operator request: hosts are
  administered with SSH keys only and run one tenant).  `--basic` and
  `--optimize` write the managed GRUB drop-in and say when a reboot is
  needed; `mitigations=on` / `SETUP_CPU_MITIGATIONS=on` are refused, and a
  persisted `CPU_MITIGATIONS=on` becomes `off` (reported).  Containers and
  hosts without GRUB are skipped; `--purge basic` restores the
  distribution default.  Trade-off: no kernel protection against
  Spectre/Meltdown-class leaks between local processes.
- **Service watchdog** (operator request) for nginx, PHP-FPM, Valkey/Redis,
  MariaDB and Elasticsearch.  A crash is restarted by systemd
  (`Restart=on-abnormal`, added in a drop-in only where the unit has no
  `Restart=` of its own).  `setup-service-watchdog.timer` (every 30 s,
  Nice 10) restarts a unit that has been down 60 s, at most 3 times per
  unit per hour, and never one an operator stopped, one being built or
  upgraded, or one the CPU-change gate holds down.  Hung services are
  restarted too: after 3 failed liveness probes in a row (Valkey `PING`,
  the PHP-FPM ping path over FastCGI, an nginx request), 5 for MariaDB
  (`mariadb-admin ping`) and Elasticsearch (cluster health), never while a
  unit is busy, within 600 s of a MariaDB/Elasticsearch start, or before a
  probe has once succeeded.  Journal tag `setup-watchdog`; the state is in
  `--diagnostics`.  `SETUP_SERVICE_WATCHDOG=0` removes it,
  `SETUP_SERVICE_WATCHDOG_HANG=0` keeps only the down check (both
  persisted).
- **MariaDB's memory outside the buffer pool is booked** in the memory
  plan: log buffer, Aria page cache, key buffer and `thread_pool_size`
  active queries x (2.5 MB session buffers + `tmp_table_size`/2).  It comes
  from the room PHP leaves (PHP workers are never cut); where that room is
  too small, `tmp_table_size`/`max_heap_table_size` are capped in 16 MB
  steps (16 MB minimum) and the remainder is reported.  The plans on the
  4, 8, 32 and 62 GB test hosts are unchanged.
- **The monthly MariaDB job runs `ANALYZE`, not `OPTIMIZE`**:
  `mariadb-check -Aas` (online) instead of `-Aos` (a rebuild of every
  InnoDB table), logged to `/var/www/logs/mariadb/check.log`.
  `SETUP_MARIADB_MONTHLY_OPTIMIZE=1` restores the rebuild (persisted).
- **HTTP/3 on by default for every vhost** (operator request;
  server-configs-nginx 1.7.4): every TLS server in the vhost templates
  includes `h5bp/tls/http3.conf`, so a site created by `--domain` answers
  HTTP/3 and advertises it with `Alt-Svc`.  Delete the include line to turn
  it off for one vhost.  `--optimize` adds the include to existing vhosts
  too (each server block on plain 443 with ssl and no QUIC listen of its
  own), only on a tree that passes `nginx -t` before and after, and undoes
  it otherwise; a commented-out include (`#include h5bp/tls/http3.conf;`)
  keeps a vhost off.  Behind Cloudflare it is idle today (Cloudflare
  reaches the origin over TCP).
- **`opcache.enable_file_override = 1` by default** (operator rule: a
  measured gain of 2 % or more with no tier slower becomes the default).
  `file_exists`/`is_file`/`is_readable` on cached scripts are answered from
  OPcache: on the Intel host XenForo member home +3.9 % and thread +1.6 %
  against the two neighbouring baselines, every other tier within noise.
  A deleted PHP file can still read as present until OPcache revalidates
  it.  `SETUP_PHP_OPCACHE_FILE_OVERRIDE=0` leaves it out (persisted as
  `PHP_OPCACHE_FILE_OVERRIDE`).
- **Elasticsearch: `xpack.ml.enabled: false`** in the managed block (no ML
  roles, no `controller` process); it applies with the one restart
  `--optimize` already does when the block changes.

Reports (read-only, only in `--optimize` and `--diagnostics`):

- **Chevereto sessions check** (operator request): `--optimize` names
  every Chevereto site and warns (console and report **WARNING**) when its
  sessions are not in Valkey: Chevereto's default is one file per guest
  visit in `/tmp`.  It reads `CHEVERETO_SESSION_SAVE_HANDLER`/`_PATH` from
  `app/env.php`, the site's nginx `fastcgi_param` and PHP-FPM pool `env[]`
  (any `files` counts; conflicting settings warn), gives the two env.php
  lines with the local socket, or says to install Valkey when there is
  none.  A site already on Valkey gets one line (socket or TCP).  Nothing
  is edited.
- `--optimize` ends with a **Verify** block (nginx and its TLS library,
  PHP version, JIT and `validate_timestamps`, Valkey version,
  io-threads, maxmemory, policy, RDB schedule and TCP port, each unit's
  `LimitNOFILE` against its internal limit and `fs.file-max` against their
  sum, an irqbalance note on dedicated hosts) and a **Certificates** block:
  a certificate ending within 21 days, expired, missing or self-signed on a
  vhost not proven behind Cloudflare is a warning.
- `--diagnostics` adds the effective FPM OPcache/JIT per PHP
  series, Valkey `INFO` per local socket, the CPU frequency driver/EPP/boost,
  NIC queues with their IRQs and irqbalance, the `LimitNOFILE` table and
  certificate expiry.
- The Valkey section names WordPress configs without `WP_REDIS_PREFIX` /
  `WP_CACHE_KEY_SALT` and XenForo configs without a cache namespace when
  several share the cache, XenForo cache sessions, and `WP_REDIS_PATH`
  without `WP_REDIS_SCHEME 'unix'`.
- The kernel section reports a NIC whose live qdisc is not fq yet (it
  changes at the next reboot; nothing is replaced live).
- **MariaDB collation check** (MariaDB 11.8 on 26.04 maps utf8mb4 to
  `utf8mb4_uca1400_ai_ci`): `--diagnostics` lists the server collations and
  the column count per collation for each app schema, and the Verify block
  warns when an app schema mixes utf8mb4 collations or uses one other than
  the server's utf8mb4 default (risk of error 1267 "Illegal mix of
  collations").  Read-only `SELECT`s with a 10 s timeout; nothing changes.
- The README now states the `innodb_flush_log_at_trx_commit = 2`
  trade-off (about 1 s of commits on an OS crash or power loss, none on a
  `mariadbd` crash) and how to set 1 in a later-sorting drop-in.

Removed (operator decisions):

- **PHP session/cgi hardening** (`SETUP_PHP_SESSION_HARDENING=1`, opt-in
  since 1.6.10).  An exported value is ignored with a warning, a persisted
  `PHP_SESSION_HARDENING` is removed from `/etc/default/setup-tuning`
  (reported), and the next `--optimize` rewrites `zz-setup-optimize.ini`
  without the block (strict session IDs, Secure cookies,
  `cgi.fix_pathinfo=0`, `display_errors=Off`, the central `error_log`).
  Session and error settings return to the PHP and application defaults.
- `opcache.validate_timestamps = 0` is no longer offered (it never shipped):
  `validate_timestamps = 1` with `revalidate_freq = 60` is always written.
  It measured within noise, and stale code after a deploy costs more.
- The opt-in PHP build options planned for 1.22.5, `--php ext=gd-avif`
  (AVIF in GD through static libavif + libaom) and `--php ext=redis-zstd`
  (phpredis zstd compression), were dropped before release: neither
  XenForo's core Redis cache nor the usual add-on uses phpredis's zstd.
  A persisted `PHP_EXT_EXTRA` that names one is left out with a warning;
  `--php ext=` refuses them.

Removed: performance opt-ins with no measured gain (operator rule: an
option that is off by default and not measured faster is deleted, not kept
switched off).  Each removed variable or flag is ignored with an "Ignored
(removed in 1.22.5; ...)" warning, never fatal, and a host that persisted
one returns to the default once, with one report line:

- **`--valkey io_threads=N`**: io-threads 1 -> 4 measured no gain and 8
  threads cost 430 % CPU and lowered full-page throughput.  io-threads is
  always 1; `--optimize` resets a `valkey.conf` that has more (one restart,
  which saves the RDB snapshot first).
- **`SETUP_PHP_JIT_HOT_LOOP` / `_FUNC` / `_RETURN` / `_SIDE_EXIT`**: no
  override value measured faster than the hardware-derived sets
  (64/127/16/64 on 3+ CPUs, 128/255/32/128 on 1-2 CPUs).
- **`SETUP_GZIP_LEVEL`**: gzip is level 4 (3 on 1-2 CPUs); it serves only
  clients without Brotli.
- **`SETUP_MARIADB_MONTHLY_OPTIMIZE=1`**: the monthly `mariadb-check`
  always runs ANALYZE (`-Aas`, online); a persisted
  `MARIADB_MONTHLY_OPTIMIZE` is deleted and a 1.22.4 OPTIMIZE job
  (`-Aos`) is rewritten on the next run that writes the crontab.
- The never-enabled `opcache.file_cache` code (scripts restored from the
  file cache are never JIT-compiled, 3-5 % slower).  The ini still writes
  an explicit empty `opcache.file_cache =`.
- server-configs-nginx 1.7.4: the TLS 1.3 0-RTT early-data opt-in and its
  `Early-Data` / `HTTP_EARLY_DATA` plumbing (Cloudflare never sends 0-RTT
  to the origin), the commented `proxy_request_buffering off`, the FreeBSD
  `accept_filter` listen lines, `h5bp/tls/ocsp_stapling.conf` (now a
  comment-only stub so old includes load) and three `http.d` files that
  need modules the source build does not compile
  (`ppa_eilander_conf`, `http_trim_filter_conf`) or were broken
  (`reverse_proxy_conf`); the deploy retires those three from hosts.

New build defaults (measured on XenForo, Intel Xeon, pinned clock, two
interleaved arms of 5 rounds each, one arm each in the sweep; the next
build after the update rebuilds nginx and PHP once onto them):

- **nginx is built with AWS-LC** (`TLS_LIB=aws-lc`, the only value).
  Against OpenSSL 4.1.0 it served 2-5 % more cached req/s (+1.8 % in the
  interleaved confirmation, +5 % in the sweep), uncached tiers were within
  noise, p99 was equal or lower, and nginx RSS under load fell by a
  fifth to a quarter (300-320 -> 234-237 MB in the confirmation; the
  release run's 224 -> 187 MB also includes Brotli 1 and the kernel).
  `TLS_LIB=openssl` is removed: a file or environment that still sets it gets a warning and AWS-LC.
  OpenSSL stays the TLS library of PHP.
  Trade-off: with `ssl_session_tickets off`, AWS-LC resumes TLS 1.2
  sessions from the shared cache but not TLS 1.3 ones (OpenSSL did), so a
  TLS 1.3 client reconnecting straight to the origin pays a full
  handshake; behind Cloudflare the edge keeps its origin connections open.
- **PHP links mimalloc** (`PHP_BUILD_MALLOC=mimalloc`, the only value).
  Against glibc's malloc, with everything else 1.22.5, uncached XenForo
  pages were 3.3-3.8 % faster on every tier and PHP-FPM RSS under load
  halved (641 -> 322 MB); the cached tier does not reach PHP.
  `glibc` (and the earlier `jemalloc`) is removed with a warning.
  An unknown value warns and builds with mimalloc, and never fails the daily rebuild.
- **Dynamic Brotli is level 1** (was 4, or 3 on 1-2 CPU hosts), on new
  installs and on existing hosts at the next `--optimize`.  Measured with
  the two defaults above:
  - level 1 served 4.2-4.7 % more uncached XenForo req/s than level 4 on
    every tier, two interleaved arms of 5 rounds each;
  - p99 was equal or lower, and the cached tier was +0.8 %;
  - responses are about 16 % larger (11.1 vs 9.5 KB per home page), on
    the origin-to-Cloudflare link;
  - levels 2 and 3 fell between 1 and 4.

  `SETUP_BROTLI_LEVEL` still overrides it.  gzip stays at 4 (3 on 1-2
  CPUs).  server-configs-nginx 1.7.4 ships `http.d/brotli_conf` at
  level 1.
- Removed after measuring no faster: `BOLT_NOLBR=1` (a plain-cycles BOLT profile, 1-3 % below no BOLT) and nginx `MALLOC=mimalloc|jemalloc` (within noise of glibc).
  `build.info` records `malloc=` for PHP.

## 1.22.4 (2026-11-26)

First test on AMD: an EPYC 4245P (Zen 5, 6C/12T, 32 GB, bare metal) on
Ubuntu 24.04 and, after an in-place release upgrade, on 26.04, with the
1.21 deb-package stack (Angie, Sury PHP 8.5, the valkey-server package)
migrated by `--optimize` on each (AUDIT-20261126-1.22.4.md).  The build
tools needed no change for AMD: clang 23 targets `znver5`, and BOLT records
its profile from AMD's own branch records (LbrExtV2) — nginx 991, PHP 2,515
and Valkey 398 profiled functions, the same order as on the Xeon.

- **Chevereto: no session GC inside requests.**  1.22.0 turned PHP's
  session GC on for Chevereto roots (a `[PATH=]` section) so `/tmp` would
  stop filling with one session file per guest visit.  Each GC call then
  listed and stat'ed the whole directory while its request held the session
  lock: on the EPYC the member explore tier fell from 2,220 to ~1,100 req/s
  (p99 48 -> 457-753 ms) and uncached guests from 4,324 to ~3,400 req/s
  (p99 37 -> 300-420 ms), getting worse as the directory grew.  This was the
  member-explore p99 regression 1.22.3 measured on the Xeon.  The GC is off
  for those roots again and `setup-php-sessionclean.timer` (every 10
  minutes, idle priority) deletes the session files older than
  `session.gc_maxlifetime` from each Chevereto file-session directory
  (`CHEVERETO_SESSION_SAVE_PATH`, default `/tmp`).  It keeps the save path's
  depth (`N;/path`) and the longest `session.gc_maxlifetime` any FPM
  configuration sets, is installed while such a site exists, and
  `--purge php` removes it.  The `--optimize` report
  now shows the two `env.php` lines that keep Chevereto sessions in Valkey:
  measured 9,466 vs ~2,200 req/s on member explore (p99 11.7 ms), with no
  files at all.
- **The CPU fingerprint ignores RDRAND/RDSEED.**  Linux hides RDSEED on
  Zen 5 parts whose microcode has the RDSEED erratum, and a microcode update
  gives it back: with the flag in the fingerprint, such a kernel or
  microcode update looked like a CPU change and kept nginx, PHP and Valkey
  down until the native rebuild finished.  Compilers never emit either
  instruction on their own, so a build stays valid.  The gates accept the
  1.22.0-1.22.3 fingerprints too: updating rebuilds nothing.
- **`--purge` runs on Ubuntu 22.04 and 24.04.**  It fell into the
  fresh-install check (26.04 or newer), so a 24.04 host that `--optimize`
  had migrated could not be purged.
- **The hostname survives cloud-init.**  Providers that set
  `manage_etc_hosts` (vendor-data) have cloud-init rewrite `/etc/hosts` from
  their own hostname at every boot: after the first reboot the name
  `--basic` set no longer resolved (`hostname -f` failed).  `--basic` now
  writes `/etc/cloud/cloud.cfg.d/99-setup-hostname.cfg`; `--optimize` adds it
  (and fixes the 127.0.1.1 line) on hosts renamed by an earlier version;
  `--purge basic` removes it.  Verified across a reboot.
- **BOLT passes no longer collide.**  The migration's delayed BOLT pass and
  an `--optimize` started within its five minutes disturbed each other:
  the `--optimize` found the build lock held (PHP skipped), the queued pass
  sampled PHP while `--optimize` reloaded it (136 functions, skipped), and
  it re-ran a Valkey BOLT that had just restarted Valkey.  `--optimize` now
  cancels a queued pass that is still waiting (and waits for one already
  working), and the daily refresh retries a missing PHP BOLT, as it did for
  nginx (verified live: 2,511 functions).
- **The Sury hold waits for the dpkg lock.**  `apt-daily` started two seconds
  before the migration's `apt-mark hold`, which failed.  Holds and unholds
  are retried while dpkg is locked (about 5 minutes); other errors are not.
- **BOLT reports perf's own error.**  A failed `perf record` said "no LBR on
  this CPU or VM?" whatever the cause, and Valkey's pass said the same when
  the benchmark itself failed.  The message now quotes perf and names what
  BOLT needs (Intel LBR or AMD LbrExtV2 on bare metal).
- **The energy-performance preference is restored.**  The performance
  governor also sets `energy_performance_preference` on amd-pstate-epp and
  intel_pstate; `--basic` records the original and `--purge basic` puts it
  back.
- Each build tool is installed after its `build-common.sh`, so a half-done
  update can never leave a new tool without the helpers its unit gate calls.
- Smaller: a stray "No such file" line in the migration log (redirection
  order); the stress harness refuses to run without `wrk` (it reported 0
  req/s), `set-fpm.sh` targets the active PHP version, and
  `restore-baseline.sh` stops when the purge fails and keeps an active UFW.

Measured on the EPYC (5 rounds, no clock pinning; the AMD part boosts to
4.9-5.4 GHz under these loads), the AMD tuning needed no new constants:
tracing JIT 64 MB beats JIT off by 10-12 % on WordPress members (function
JIT +5 % on the XenForo thread, -6 % on WordPress; 128 MB ties); 12 PHP
workers (one per thread) beat 6, 9, 18 and 24 on every member tier; 8 nginx
workers (two thirds) beat 6, 10 and 12 on cached pages, at a tenth of the
p99; BOLT's `-hugify` ties the current layout.

Before/after the migration on the EPYC (Angie + Sury PHP 8.5 + package
Valkey -> nginx 1.31.10 + PHP 8.5.13 + Valkey 9.2.1 from source with BOLT),
Ubuntu 26.04, req/s medians: cached pages +4.5 to +8.4 %, WordPress member
home +9.4 %, XenForo member home +9.1 %, Chevereto uncached +18.4 % and
member explore +9.4 % (p99 52 -> 48 ms); the XenForo member thread ties.
Ubuntu 24.04 gave the same picture (cached +7 to +10 %, members +8 to
+9 %).  Functional walk, security 78/78 and cookie 109/109 on both.

## 1.22.3 (2026-11-26)

Migration of deb-package hosts (Angie, Sury PHP, valkey-server) to the
source builds, tested end to end on replicas of every series 8.1-8.6, on
Ubuntu 26.04 and 24.04, on bare metal and in KVM guests
(AUDIT-20261126-1.22.3.md).  Each fix below was found by one of those runs.

- **Cron ran PHP without its extensions after the PHP cutover.**  The
  cutover hands `/etc/php/X.Y/cli` to the source build, but
  `/usr/bin/phpX.Y` (and `/usr/bin/php` through the alternatives link)
  stayed Sury's binary until the Sury purge.  In between, every crontab line
  and setup.sh's own `wp-cron.php` / `xf:run-jobs` jobs ran a CLI that loaded
  2 of the 7 application extensions.  When the purge was deferred (a second
  PHP version still on Sury, or collateral packages) that lasted until the
  operator acted.  The cutover now diverts Sury's `/usr/bin/phpX.Y`
  (`dpkg-divert --local`, to `phpX.Y.sury`) and links the source CLI in its
  place; the rollback takes the diversion back, and the post-purge pass
  removes the record.  The migrated version's Sury packages are held until
  the purge, so an `apt upgrade` cannot re-add Sury's conf.d links.
- **Valkey did not build on Ubuntu 24.04.**  glibc 2.39 defines `sprintf`
  as a fortify macro for clang; Valkey's Lua module includes `fmacros.h`
  (which re-declares `sprintf`) after `<stdio.h>`, and the build stopped.
  The re-declaration is now skipped where `sprintf` is a macro.  24.04
  hosts kept serving from the valkey-server package; the next `--optimize`
  migrates them.
- **PHP JIT sizes are whole 2 MB.**  An 8 GB host got a 495 MB OPcache and
  a 61 MB JIT buffer.  With huge code pages, PHP 8.1 workers then segfaulted
  running JIT code (logins and POSTs answered 502) and PHP 8.6 refused to
  start (`mprotect() failed [22]`).  Both sizes are now rounded down to a
  multiple of 2 MB (494/60); hosts of 16 GB and more (512/64) do not change.
- **A failed PHP reload is no longer reported as OK.**  A configuration
  php-fpm rejects only while starting made the SIGUSR2 re-exec exit after
  `systemctl reload` had returned success; the tuner reported "Reload: OK"
  and PHP stayed down.  Reloads now confirm the master survived, a refresh
  that rolls back restarts the pool from the restored files, and a PHP unit
  that had *failed* (not one the operator stopped) is started again once
  the tuned configuration passes `php-fpm -t`.
- **Series the source build cannot make are refused in the pre-flight.**
  PHP 8.0 or an unreleased series (a Sury RC) used to be built, fail, and
  retry on every `--optimize`, and an idle RC could even become the active
  version.  It is now refused up front (retried once php.net releases X.Y.0);
  the active version is chosen among buildable series only, and by the
  vhosts' `fastcgi_pass` references before falling back to the newest.
- **PHP 8.6 and PECL.**  8.6 removed aliases PECL sources still use
  (`zval_dtor`, `zval_is_true`, `XtOffsetOf`, `INI_STR`/`INI_INT`,
  `WRONG_PARAM_COUNT`, `php_hash_bin2hex`, ...).  The build restores each
  one the tree no longer defines, with its 8.5 definition, and adapts
  igbinary to the zend_string `unserialize_callback_func`: igbinary 3.2.16
  builds on 8.6.  redis 6.3.0 still does not (its session handler needs a
  real port), so redis has a series ceiling of 8.5: an application that
  needs it (Chevereto, a XenForo Redis cache) refuses the 8.6 migration in
  the pre-flight with that reason, and a redis kept only by `PHP_EXT_EXTRA`
  is left out with a warning.
- **Operator php.ini edits survive the migration** as
  `conf.d/10-migrated-php-ini.ini` (the differences from Sury's own
  `php.ini-production`); the managed `zz-setup-*.ini` still wins.
- **Report and log noise.**  The leftover-Angie-reference scan skips logs,
  notes, backups and checkouts of this script; a host without PHP (a front
  proxy) no longer warns about a dead `local_php` listener; the
  migration's `nginx -t` trials log to stderr only (they wrote expected
  `[emerg]` lines into the live error.log); crontab lines are listed with
  the PHP each one will run, and a line calling a removed series is flagged.
- **PHP BOLT** uses a working `perf` as nginx and Valkey do, instead of
  always installing `linux-tools-$(uname -r)`.
- **`restore-baseline.sh`** releases holds on packages the run added (apt
  refused to purge the held Sury packages of a deferred purge), takes a
  leftover CLI diversion back, and re-enables the baseline's units that
  `--purge` disabled (sysstat).
- **Measured on the Xeon E-2236 test host** (same host before and after the
  migration, 5 rounds, clock pinned): cached pages +13 to +19 %, PHP pages
  +8 to +14 % where outside the spread (PHP CPU per request -8 to -14 %).
  Every replica passed the functional walk, the security probe (78/78) and
  the cookie suite (109/109) after its migration.

## 1.22.2 (2026-11-26)

- **Security: XenForo guest-cache poisoning with zero-padded cookies**
  (server-configs-nginx 1.7.3).  `xf_language_id=0000002` (7 characters)
  missed the 1-6 digit key class, so it was keyed as the default guest
  page, while XenForo int-cast it and rendered language 2: three such
  requests served every cookieless guest the wrong language (or style) for
  the cache TTL.  Reproduced on the audit host; the key maps now strip
  leading zeros and a value with more than six significant digits bypasses
  the cache.  `--optimize` rewrites the legacy `$setup_xf_guest_bypass`
  map (hand-written or pre-1.21 `php_xf.conf`) with the same value guards,
  which also closes `%32`, `+2` and `2x` there.
- **Security: CDN proxy cache key uses `$request_uri`** (server-configs-nginx
  1.7.3).  With the decoded `$uri`, `/proxy.php%3Fimage=x` (an origin
  403/404) shared the key of `/proxy.php?image=x` and blanked that public
  URL for the error TTL.
- **`--php` on its own now sets `vm.nr_hugepages`.**  The memory plan books
  huge pages for OPcache, but only `--basic` wrote the sysctl, so a `--php`
  run left `opcache.huge_code_pages` with no pool until the next
  `--optimize`.  `install_php` now syncs the managed sysctl line first (no
  change on unmanaged files or in containers).
- **`--upgrade-php` tunes from the same inputs as `--optimize`.**  It now
  ignores `SETUP_*` tuning env and resets operator pins first, like
  `--optimize`, so the pool it builds is the one the next
  `--optimize` keeps.
- **Opt-in TLS-library and kTLS nginx builds for benchmarks.**
  `tools/nginx-build.sh build-arm DIR` builds nginx into its own prefix,
  never activated, with `TLS_LIB=openssl|aws-lc|boringssl`, `KTLS=0|1` and
  `OPENSSL_VERSION=lts` (newest 3.5.x) in `nginx-build.conf`; AWS-LC and
  BoringSSL are fetched, built static with cmake/ninja and linked like a
  system library.  The TLS choice is recorded in `build.info`
  (`tls_opts=`) and a change makes `check` report the build stale.  The
  fleet build is unchanged (OpenSSL 4.1, no kTLS, recipe 5).
  `tests/stress-site/tls-arms-bench.sh` runs the arms standalone on their
  own ports.  Measured (AUDIT-20261126-1.22.2.md): AWS-LC and BoringSSL
  need half of OpenSSL's nginx CPU per ECDSA handshake, OpenSSL 4.1 beats
  3.5, keep-alive and bulk tie; kTLS cuts nginx CPU on large static files
  by ~44 % but costs 38 % on small keep-alive responses.  Neither becomes
  the default.
- **kTLS needs `tcp_notsent_lowat` >= 131072.**  At the 16384 this script
  sets, `sendfile()` on a kTLS socket sends one 16 KB record per ~200 ms
  timer and a 1 MB file does not finish (kernel 7.0).  Documented next to
  `KTLS` in `nginx-build.conf` and `configs/system/sysctl.conf`; the bench
  refuses a kTLS arm below it.
- **Help text:** `app=` placement inside a `--domain` group, and
  `--upgrade-php=<active series>` (rebuild only).
- **Benchmark harness for PHP series** (`tests/bench-php-matrix/`):
  `install-php-series.sh` builds any set of series with one extension set
  (replaces the Sury-based `install-php-versions.sh`); `switch-php-arm.sh
  series-X.Y` rotates them on the shared socket;
  `bench-xf-php-series.sh` + `xf-series.tiers` run four XenForo tiers with
  gating (HTTP 200, page marker, cache status), independent medians,
  CPU ms/req and MHz; `deploy-xf.sh`/`install-addons.sh` `PLAIN=1` deploy
  XenForo without Valkey, Elasticsearch or cache add-ons; `seed-xf.sh`
  writes the member cookie and median thread for the runner; `set-jit.sh`
  targets the active series (or `X.Y`/`all`).
- **server-configs-nginx has one branch, `main`.**  setup.sh downloads
  `CONFIG_REPO_REF=main` (was `nginx`), and CI checks out `main`.  The
  `nginx` branch became a tag (the frozen 1.7.1 tree), so 1.22.0 and 1.22.1
  hosts keep downloading a working tree; `angie-final` still holds the last
  Angie tree.  A 1.21.x setup.sh that downloads `main` refuses the nginx
  tree (no `angie.conf`) and keeps Angie: update the checkout before
  `--optimize`.  This repository's `v1.22` branch (the unsquashed 1.22.0
  commits) is now the tag `v1.22.0-history`.

## 1.22.1 (2026-11-26)

- **gzip_static and brotli_static removed from the nginx build** (operator
  decision).  `tools/nginx-build.sh` no longer passes
  `--with-http_gzip_static_module` and builds only the ngx_brotli filter
  (`--add-module=.../ngx_brotli/filter`; `configure-args` prints the new
  form).  Build recipe 5: every host rebuilds nginx on its next
  `--optimize`.  Dynamic gzip and dynamic Brotli stay as they were.
- **Static-asset precompression removed** (the `.br`/`.gz` siblings of
  1.21.58-1.22.0, `setup-precompress.sh` and its cron line).  It never ran
  on a production host, so there is no cleanup step.
  `SETUP_PRECOMPRESS_ASSETS` is ignored with a warning, like the options
  removed in 1.22.0.  `brotli.conf` is written without `brotli_static`, and
  an existing generated file is rewritten without it.
- **Operator vhosts stay valid.**  `gzip_static` and `brotli_static` are now
  in the droppable list: if a vhost still uses them, activation comments
  the line out with the `# setup-nginx-build-off: ` marker and reports it,
  instead of failing `nginx -t`.  This now also happens on every
  `--optimize` sync, not only when a new binary is activated.  Before, a
  vhost added after activation stopped the sync at `nginx -t`, although
  nginx kept serving.  A fresh `--nginx` onto a host whose `/etc/nginx`
  already holds operator vhosts fits the rendered tree to the staged build
  before the first `nginx -t`.
- **Fix found by the test host: the filter-only Brotli build.**
  `ngx_brotli/filter/config` looks for the library under `filter/deps`, so
  the first build failed with "Brotli library is missing".  The build now
  links `filter/deps` to `../deps`.
- **Measured on the Xeon E-2236 test host:**
  - **Upgrade:** a 1.22.0 host (recipe 4, gzip_static compiled in, the old
    tree's three `gzip_static on;` lines, and an operator vhost with
    `gzip_static on;` and `brotli_static on;`) took one `--optimize` of
    1.22.1 (133 s).  It rebuilt nginx with the Brotli filter only, the tree
    has no active static directive, and the vhost's two lines carry the
    marker and were reported.
  - **After the upgrade:** nginx stayed active and `nginx -t` passes;
    responses are compressed with `br` and `gzip`.  A second `--optimize`
    passed with no further changes.
  - **Fresh install:** 89 s.
- **Release order.**  setup.sh 1.22.1 needs server-configs-nginx 1.7.1
  (branch `nginx`, the first tree without `gzip_static`), which also loads
  on a 1.22.0 binary.  It is pushed first; after the v1.22.1 tag,
  server-configs-nginx `scripts/uss-ref` is pinned to v1.22.1 so its CI
  builds the filter-only binary.
- **CI.**  ShellCheck 0.11.0 is pinned by SHA-256 and runs in groups in
  parallel (one call over every file ran for over 20 minutes on the
  runner).  The standalone unit-test loop skips
  `tests/unit/t-nginx-build.sh`, which runs only inside the tuning suite
  (it failed every CI run by design).  Failing dry-run cases are reported
  as annotations.

## 1.22.0 (2026-11-25)

- **nginx, PHP and Valkey are built from source only** (operator decision).
  There are no package modes any more.  `--nginx` builds the newest nginx
  mainline from nginx.org; `--php` builds PHP (FPM and CLI) from php.net,
  any released series from 8.1 on (never an RC); `--valkey` builds the
  newest Valkey release.  All three use the 1.21.71 recipe: clang `-O3
  -march=native`, Ubuntu's hardening flags, ThinLTO, then BOLT from live
  traffic on `--optimize`.  No Angie, Sury or Ubuntu php packages and no
  valkey-server package are installed.  MariaDB and Elasticsearch stay apt
  packages (compiling them was measured not worth it in 1.21.71).  The
  builds live in `/usr/local/lib/setup-nginx`, `/usr/local/lib/setup-php/X.Y`
  and `/usr/local/lib/setup-valkey`; the units (`nginx`, `phpX.Y-fpm`,
  `valkey-server`) are this script's own files in `/etc/systemd/system`, and
  the command links are in `/usr/local/bin` and `/usr/local/sbin`.  A build
  failure stops the install and names the build log.  A daily timer
  (`setup-build-refresh.timer`) rebuilds in the background when a new
  release or a changed extension set needs it; the running binary serves
  until the new one passes its checks.  nginx binaries are swapped by an
  in-place upgrade (no restart).  Tools: `tools/nginx-build.sh`,
  `tools/php-build.sh` (was `php-fpm-build.sh`), `tools/valkey-build.sh`;
  `lib/nginx-build.sh` replaces `lib/angie-build.sh`.
- **nginx replaces Angie.**  Compiled nginx 1.31.10 against compiled Angie
  1.12.5 (1.21.71: same flags, libraries and modules, identical files, 5
  rotated rounds): cached pages **+0.5 to +1.5 %** (XenForo home 123,007
  against 121,482 req/s), PHP pages tie.  The build carries `auth_basic` and
  `limit_req` (the login limiter stays), Brotli as a static module, HTTP/2
  and HTTP/3; `limit_conn` is not built.  Branding is stripped: no `Server`
  header and no "nginx" on error pages.  Each source patch is counted; when
  a new mainline no longer matches, the tool builds the last version the
  patch applied to (`NGINX_FALLBACK=1.31.10` in `nginx-build.conf`) and
  reports it.  Directives of modules the build leaves out are still
  commented out with a marker and reported, now `# setup-nginx-build-off: `.
- **server-configs-nginx branch `nginx` (1.7.0) is the 1.22 tree.**  setup.sh
  downloads it by default (`CONFIG_REPO_REF=nginx`).  `main` stays the
  Angie tree for hosts on 1.21.x, and the tag `angie-final` marks its last
  commit.  Merging `nginx` into `main` once every host runs 1.22 is an
  operator step, never automatic.
- **One-time migration of 1.21.x hosts by `--optimize`.**  On a host with
  Angie, Sury PHP or the valkey-server package, the first `--optimize`:
  builds nginx, every active PHP version and Valkey while the old services
  keep serving; moves `/etc/angie` to `/etc/nginx` (operator files only,
  paths rewritten); points Angie ACME vhosts at the host's self-signed
  certificate (Cloudflare Full mode; a vhost not behind Cloudflare is listed
  in a warning block); rewrites the Angie cron lines to
  `/etc/nginx/scripts/cloudflare.sh`; switches each service over with a
  verified cutover; and only then removes the old packages, repositories
  and keys.  `--optimize --dry-run` prints the plan.  Safety rules:
  - It runs as the transient unit `setup-migrate-1.22`, so a dropped SSH
    session does not stop it.  The log is `/var/log/setup-migrate-1.22.log`;
    re-running the command attaches to it.
  - Progress is kept in `/var/lib/setup.sh/migrate-1.22`; an interrupted run
    resumes.
  - Each part (nginx, PHP, Valkey) rolls back on its own: a failed check
    stops the new service and starts the old one again.  A part blocked by
    an Angie-only directive (`api`, `status_zone`, `js_*`, `$angie_*`,
    `sticky`) or an extension the build cannot provide is reported and
    keeps serving as before.
  - Packages are removed only after their replacement serves, and only by
    exact lists.  `apt-get -s` simulates each removal first; if it would
    take any other package with it, that removal is skipped and reported.
    `libapache2-mod-php*` is never in the list.  When the Sury removal is
    blocked that way, PHP serves from the build, the Sury packages are held,
    and `SETUP_PHP_ALLOW_COLLATERAL=1` accepts the collateral.  The
    valkey-server package is removed, not purged (its postrm can delete
    `/var/lib/valkey`), so it stays in dpkg's `rc` state.
  - During removals, a temporary `policy-rc.d` stops maintainer scripts
    from touching only this script's units.  At the end every unit is
    enabled again and `is-enabled` is checked.
  - The removed packages' `.deb` files, `/etc/angie`, the old `/etc/php`
    and `/etc/valkey` trees and Angie's ACME state are kept in
    `/var/backups/setup-1.22` (mode 0700) for a manual rollback.  This
    directory is never deleted.
  - PHP keeps every extension the Sury PHP loaded that the build can
    compile, recorded in `PHP_EXT_EXTRA`; `--php ext=-NAME` trims it later.
  - Below the 4 GB class only nginx is migrated; PHP and Valkey stay as
    they are and are reported.
- **The migration test found three bugs, all fixed.**  A 1.21.71 host
  (Angie package, Sury PHP 8.5, valkey-server package, the three apps, an
  Angie ACME vhost and an `auth_basic`/`sub_filter` vhost) was migrated.
  PHP and Valkey moved in the first run.  The nginx part was blocked or
  rolled back three times, and each time Angie kept serving on its own:
  1. The Angie package's own `http.d/default.conf` (the `api` status
     location) was scanned as an operator file and blocked the part.
  2. The cutover check compared the catch-all strictly: `Host: localhost`
     had been answered by Angie's package welcome page, so the new answer
     differed and the cutover rolled back.
  3. A part that had rolled back on an unchanged tree was never retried,
     even by a fixed release.  The migration now records a digest of its
     own code with each result, so a new release retries;
     `SETUP_MIGRATE_RETRY=1` forces a retry.
- **Per-application PHP extensions.**  A build carries a small base set
  plus what the host's sites need, detected from the vhosts (and `--domain
  app=`): WordPress `mysqli gd curl mbstring exif zip xml sodium`; XenForo
  `mysqli gd curl mbstring xml zip exif`; Chevereto `pdo_mysql pdo mysqli
  redis igbinary gd curl mbstring exif fileinfo xmlwriter zip`; other PHP
  apps a generic set (`mysqli pdo_mysql pdo tokenizer bcmath sqlite3
  pdo_sqlite xml xmlwriter zip exif`).  `redis` and `igbinary` are added
  when XenForo's cache provider is Redis or a WordPress object-cache
  drop-in needs `\Redis`; `sqlite3`/`pdo_sqlite` when a root uses SQLite.
  Detection only adds; a set shrinks only by `--php ext=` or by removing a
  domain.  The daily timer re-runs detection and rebuilds when the set
  grew.  `SETUP_PHP_FPM_MODULES` and phpenmod/phpdismod are gone.
- **`--php ext=LIST`** adds optional extensions (comma list, e.g.
  `ext=intl,gmp`): `gmp`, `intl` (builds ICU from source), `bcmath`,
  `sqlite3`/`pdo_sqlite`, `soap` and the rest of what the source build can
  compile.  `-NAME` drops one you added, `none` clears the list.  It is
  stored as `PHP_EXT_EXTRA` in `/etc/default/setup-tuning`.  A name the
  build cannot compile is refused before anything changes.
- **`--upgrade-php=X.Y` builds from source.**  It builds X.Y (FPM and CLI)
  with the current extension set while the current version serves, writes
  `/etc/php/X.Y` from the current managed files, switches the shared
  socket, checks the sites, and rolls back on failure.  The previous build
  stays for one switch back without a rebuild.  It is refused while the
  1.22 migration is incomplete.  Measured on the Xeon E-2236 test host:
  - **Down to 8.4, 8.3, 8.2 and 8.1:** each built and served, in 162-316 s.
  - **Back to 8.5:** 38 s from the kept build.
  - **8.0:** refused before anything changes.
  - **8.6:** the build fails safely while igbinary does not compile on it,
    and 8.5 keeps serving.
- **Hosts under 4 GB RAM: nginx only.**  Below the 4 GB class (MemTotal
  under 3500 MB) `--php`, `--valkey`, `--mariadb`, `--elastic`,
  `--upgrade-php` and `--domain` apps that need PHP are refused before
  anything changes.  `--optimize` tunes nginx and leaves an existing PHP or
  Valkey alone (reported).
- **CPU change: services stay down until the native rebuild finishes**
  (operator rule; there is no generic fallback binary).  Every build
  records a fingerprint of the CPU (model and the ISA flags `-march=native`
  can use).  When it differs at a unit's start, the unit stays down and
  `setup-build-cpu.service` rebuilds nginx, then the active PHP version,
  then Valkey from the cached sources at the recorded versions, starting
  each service when its build passes.  Until it finishes, a cron job using
  the PHP CLI can fail on the new CPU (accepted).
- **Supply chain.**  nginx tarballs are checked against nginx.org's PGP
  signing keys (fingerprints embedded) and refused on any failure.  Valkey
  tarballs are checked against the SHA-256 in valkey-io/valkey-hashes.  PHP
  uses php.net's SHA-256 as before.  The setup-build-sources mirror stays
  the last source under the same hash rules (nginx needs its `.asc`
  there too).
- **Security.**  The hardening flags stay; BOLT output must keep a
  non-executable stack (`bolt_stack_check`).  The units are hardened; the
  Valkey unit keeps the package unit's sandbox (`NoExecPaths=/` with
  `ExecPaths=` for the build, `/usr/lib` and `/lib`,
  `MemoryDenyWriteExecute=yes`).
- **Fix: BOLT on an idle server.**  On a fresh install with no traffic yet,
  `--optimize` reported a BOLT error.  It now reports "too little traffic,
  BOLT skipped", and the next `--optimize` under load retries.
- **Fix: a failed build could fill the disk with its own log.**  setup.sh
  sends a build tool's stderr to the same file as the build log, so the
  log excerpt a failed build prints was appended to the log it was reading,
  which grew without bound.  The PHP 8.6 test grew it to 1.7 TB, filled the
  disk and stopped MariaDB.  The excerpt is now skipped when stderr is the
  log itself, and no single file a build writes may exceed
  `SETUP_BUILD_MAX_FILE_GB` (default 20 GB, enforced with `ulimit -f`).
- **Fix: the migration scan checks `angie.conf` for `load_module` again.**
  `angie.conf` is never copied to `/etc/nginx`, but a `load_module` in it
  (other than Brotli) names a module the operator relies on and nginx will
  not have, so it blocks the nginx part again and Angie keeps serving.
- **Fix: PHP 8.4 and older did not build (found by the downgrade test).**
  PHP's bundled libtool drops `-fuse-ld=lld` on some links (the shared
  `opcache.so` below 8.5, and the `php`/`php-fpm` programs before 8.3), so
  clang fell back to GNU ld, which rejects the ThinLTO options.  The PHP
  build now runs clang through a small driver that adds `-fuse-ld=lld` to
  every call that links.  PHP 8.1 does not compile against OpenSSL 4, so
  the 8.1 series builds with the newest OpenSSL 3.x release.
- **Fix: `--upgrade-php` checks each app's minimum PHP version.**  An app
  whose Composer platform check needs a newer PHP than the target now
  blocks the switch before anything is built.  Chevereto 4.5 needs PHP 8.2,
  and the downgrade test to 8.1 answered 500 on every Chevereto page.
- **Fix: the after-switch site check now reaches PHP.**  It requested
  `/index.php?…`, which nginx answers with a canonical 301 without running
  PHP, so it reported "3 OK" while Chevereto was broken.  It now requests
  the home page with the cache-bypass cookie.
- **`--upgrade-php` keeps exactly one previous version** for rollback, newer
  or older.  The message for a retired build no longer calls a newer
  version "older".
- **Removed options and behaviour changes** (check scripts and exported
  `SETUP_*` variables):
  - `--angie` is now `--nginx`; `--angie` still works and warns.
  - `--source` is ignored with a warning.
  - `SETUP_PHP_BUILD`, `SETUP_ANGIE_BUILD`, `SETUP_NGINX_BUILD`,
    `SETUP_VALKEY_BUILD` and `SETUP_PHP_FPM_MODULES` are ignored with a
    warning.  The migration removes the persisted `PHP_BUILD`,
    `ANGIE_BUILD`, `NGINX_BUILD`, `VALKEY_BUILD` and `PHP_FPM_MODULES` from
    `/etc/default/setup-tuning` and turns `XF_MEMBER_GZIP=angie` into
    `nginx`.
  - `SETUP_ANGIE_COMPRESSION` is read as `SETUP_NGINX_COMPRESSION` (the new
    name wins when both are set).
  - `SETUP_LIMIT_REQ_EXEMPT` is unchanged: ignored since 1.21.71.
  - `SETUP_MEM_TOTAL_MB` is honoured only with `--dry-run`.
  - "`--purge` never removes packages" no longer holds for the one-time
    migration, which removes the Angie, Sury PHP and valkey-server packages
    as described above.  `--purge` itself still removes no packages: for
    nginx, PHP and Valkey it removes the units, builds and links, and keeps
    `/var/backups/setup-1.22`.
  - A host still on Angie, Sury PHP or the valkey-server package must run
    `--optimize` first; `--nginx`, `--domain`, `--php` and `--valkey` refuse
    until it has.
- **Validation** on the Xeon E-2236 test host (Ubuntu 26.04.1):
  - Final tree, after every fix: unit suite 2,797 checks pass (0 fail,
    1 skipped), dry-run matrix 290, ShellCheck clean.
  - Fresh install (`--basic --nginx --php ver=8.5 --mariadb --valkey
    --elastic --others all`): **10 min 15 s**, including building nginx
    1.31.10, PHP 8.5.13 and Valkey 9.2.0 with LLVM 23.  WordPress, XenForo
    and Chevereto deployed; functional walk 0 failures, security 78/78,
    cookie 105/105.  `--optimize` under load BOLTed nginx (in-place
    upgrade, no restart), PHP and Valkey; a second `--optimize` found every
    build current.  No `Server` or `X-Powered-By` header; the 404 page has
    no "nginx".
  - Migration of the 1.21.71 host above (1.21 suites 76/76 and 105/105
    before): Angie, its repository and the `angie` user purged, `/etc/angie`
    moved to `/var/backups/setup-1.22`, `angie.service` now an alias of
    `nginx.service`, the ACME vhost served by the self-signed certificate
    (200), `auth_basic` 401/200 on nginx, `sub_filter` commented out with
    the marker, no Angie, PHP or Valkey packages left (valkey only in `rc`
    state).  The PHP build kept every extension Sury had loaded (calendar,
    ftp, gettext, gmp, sockets, xmlreader and more) on top of the apps'
    sets.  After: security 78/78, cookie 105/105, functional 0 failures.
    After a reboot nginx, php8.5-fpm and valkey-server were active and
    enabled, 0 failed units, every site 200.  A second `--optimize` found
    nothing to migrate and every build current.

## 1.21.71 (2026-11-25)

- **`--source=all | angie,php,valkey | none`** (operator request): one
  option for the compiled builds, like `--others`, on an install or
  `--optimize`.  The list is the complete set: every component not named
  goes back to its package; `none` puts all back.  Commas or spaces
  (`--source angie php`).  Without `--source` nothing changes: a fresh
  install has no build and runs the packages (the same as `none`), and a
  plain `--optimize` keeps the builds the server already runs.  It sets and
  records `PHP_BUILD`, `ANGIE_BUILD` and `VALKEY_BUILD` like the
  `SETUP_*_BUILD` variables (which still work; `--source` wins when both are
  given).
- **Compiled Valkey (`--source=valkey`, `SETUP_VALKEY_BUILD=clang`, opt-in).**
  Valkey from its newest GitHub release (9.2.0; Ubuntu ships 9.0.6) with
  clang `-O3 -march=native`, Ubuntu's hardening flags, full LTO, no frame
  pointers, bundled jemalloc and Lua (the XenForo Redis add-ons run Lua
  scripts), no TLS, then BOLT from a `valkey-benchmark` profile of the build
  itself.  `sd_notify()` is the static shim, so it links only glibc and
  libgcc_s.  Against the package, 5 rotated rounds over the Unix socket:
  pipelined (16) GET/SET **+3.1 / +2.6 %**, single requests 0 to +1.5 %.
  Valkey is about 0.3 % of a page's server CPU, so pages do not change
  measurably.  A host whose `valkey.conf` persists data stays on the
  package's X.Y series (an older server cannot read a newer RDB/AOF); the
  managed cache-only configuration may run the newest release.  The drop-in
  adds the build to the packaged unit's `ExecPaths=`.  `tools/valkey-build.sh`,
  `lib/valkey-build.sh`, `valkey-build.conf`.
- **Valkey from source: the first build was 32-41 % slower, and why.**  The
  prototype passed `CFLAGS=` on make's command line.  A command-line variable
  overrides the assignment in every sub-make, so Valkey's bundled jemalloc
  and Lua lost their own `-O` flags and built unoptimised: 9,430
  instructions per pipelined request against 6,152 for the package and
  5,770 for an upstream-default build.  The tool passes CFLAGS/LDFLAGS
  through the environment (5,926 with the hardening flags), and a unit test
  keeps it that way.
- **Compiled Angie: `auth_basic` built in, `limit_conn` out, and
  incompatible directives commented out automatically.**  The build now
  includes `auth_basic` (password-protected areas on a live site) and
  `limit_req` (the login limiter); `limit_conn` stays out.  When the
  configuration uses a directive of a module the build leaves out, and that
  directive only transforms or limits responses (`sub_filter*`, `ssi*`,
  `add_before_body`/`add_after_body`/`addition_types`, `limit_conn*`,
  `userid*`, `autoindex*`, `random_index`, `gunzip*`, `mp4*`, `flv`),
  `--optimize` comments it out in its file with a marker
  (`# setup-angie-build-off: `), reports each one (file:line), and activates
  the build.  Going back to the package (`ANGIE_BUILD=package`, the APT hook,
  the CPU guard, a failed start) restores every marked line byte for byte.
  Access control (`auth_request`, `secure_link`, ...) and content handlers
  (`uwsgi_pass`, `grpc_pass`, `memcached_pass`, `empty_gif`, ...) are never
  commented out: a location without its handler would serve its root as
  static files, so such a configuration keeps the package, as before.  The
  build's `ExecStartPre` does the same for a directive added after
  activation, and goes back to the package instead of leaving Angie stopped
  when anything else fails its test.
- **Rate limiting: only the login limiter is left** (operator request, with
  the login limiter kept on purpose: WordPress has no login throttling of its
  own).  server-configs-nginx 1.6.61 drops the generic per-IP GET (100 r/s)
  and POST (30 r/s) zones and their exemption list; the credential zone (20
  login/registration/reset POSTs a minute per address, burst 10) stays in
  every PHP location.  The tuner no longer sizes the removed zones, and
  `SETUP_LIMIT_REQ_EXEMPT` is ignored with a warning (the credential zone
  never honoured it).  A `LIMIT_REQ_EXEMPT` an older release persisted is
  still read as a sign of a reverse proxy in front, so the TLS catch-all
  guard keeps answering such hosts without SNI.
- **More PHP compiler flags measured, none kept** (operator request: tune
  beyond the defaults).  Three arms of the shipped build, each BOLTed from
  the same member traffic, against the package, 5 rotated rounds (XenForo
  thread / home, WordPress home / post, Chevereto uncached): shipped flags
  **+9.4 / +8.4 / +6.5 / +6.9 / +11.3 %**; plus `-fno-plt` and LTO `-O3`
  at link time +9.9 / +5.2 / +7.2 / +6.9 / +11.5 % (inside the noise);
  plus a higher inline threshold and ThinLTO import limit +6.3 / +3.5 /
  +4.3 / +4.6 / +9.5 % and 3 MB larger.  For Valkey, dropping frame
  pointers saves 3.4 % of instructions and is kept; the hardening flags cost
  6 % of instructions and stay.  Non-PIE builds were not tried: PIE is
  ASLR for the main binary.
- **Angie vs nginx, both compiled** (question).  Angie 1.12.5 and nginx
  1.31.10 from their own releases, the same clang flags, OpenSSL, PCRE2,
  zlib-ng, Brotli and module set, no BOLT on either, on identical files (a
  copy of the live tree without the Angie package's three Angie-only pieces:
  the `api` status location, `$upstream_request_method` and
  `$angie_version`), 5 rotated rounds.  nginx served the cached guest pages
  **+0.5 to +1.5 %** faster (XenForo home 123,007 against 121,482 req/s);
  member and uncached pages tied; both beat the Angie package by 3-6 %.
  `switch-angie-arm.sh nginx-TAG | ngtree-TAG` reproduce it.
- **Elasticsearch: no source build** (operator request: compile it with only
  what XenForo Enhanced Search uses).  XFES 2.3.13 needs the search core,
  `analysis-common` (stemmer, stop words, asciifolding), `more_like_this`,
  `function_score` with a date decay, `_bulk` and the index settings API.
  Elasticsearch is Java: compiling it from source produces the same
  bytecode, and the JIT already generates code for the exact CPU, so there
  is nothing for `-march=native`, LTO or BOLT to act on.  A trimmed
  distribution of the same release (9.5.7) was tried instead: ES 9 refuses
  to start without `apm`, `x-pack-core` and `x-pack-security` (its launcher
  loads them even with security off), and the keystore and cluster state tie
  it to further modules (`x-pack-encryption`, ILM, geoip), so a trimmed node
  needs its own data directory and a full reindex and can break on any
  upgrade.  Not shipped; the package stays.
- **MariaDB: not compiled.**  Its share of the server's CPU on logged-in
  pages (package stack, loopback tiers): WordPress member home 7.6 %,
  XenForo member home 13 %, thread 8 % (PHP takes the rest).  Even a 10 %
  faster mariadbd would gain about 1 % of page throughput, for an hour-long
  build and a data directory that must never meet an older server.
- **fileinfo stays** (question): it cannot be removed.  Chevereto's image
  library calls `finfo_file()`/`finfo_buffer()` on every upload
  (intervention/image), WordPress checks every upload's real type with
  `finfo_file()` (`wp_check_filetype_and_ext`), and XenForo's attachment
  validators (laminas, flysystem) use it too.  Its 10.4 MB magic database is
  read-only data in the binary: pages nobody touches are never loaded, so it
  costs disk, not memory or speed.
- **Download mirror** (operator request):
  [droplinxuser/setup-build-sources](https://github.com/droplinxuser/setup-build-sources)
  holds an unmodified copy of every source archive the compiled builds use,
  one release per component with a `SHA256SUMS`, refreshed daily by its own
  workflow with the same download code the servers run.  It is the last
  source, tried only when every upstream source has failed, and never a
  trust root of its own: a mirrored file must match the upstream's published
  SHA-256, the hash this host pinned on its first download, or the mirror's
  `SHA256SUMS`, or it is refused.  An archive is never replaced there; a
  file that changes upstream under the same name fails the mirror's run.
  `SETUP_BUILD_MIRROR=off` disables it, another URL points at a fork.
- **Security fix: BOLT gave the compiled binaries an executable stack.**
  llvm-bolt's `-use-gnu-stack` (1.21.68-1.21.70) turns the `PT_GNU_STACK`
  header into the new code segment, and without that header Linux gives the
  process an executable stack.  The php-fpm and Angie builds ran that way;
  Valkey's unit (`MemoryDenyWriteExecute=`) refused to start its BOLTed
  binary, which is how it showed.  The flag is gone, every BOLT output must
  carry a non-executable `GNU_STACK` (`bolt_stack_check`), and the PHP and
  Angie recipes are bumped, so the next `--optimize` rebuilds existing
  builds.  The binaries grow by the new segment's alignment padding on disk
  (php-fpm 51.4 MB, Angie 15.6 MB, Valkey 10.9 MB); what is loaded does not.
- **Compiled Angie links Ubuntu's libcrypt** now that `auth_basic` is in:
  password hashes nginx does not implement itself (bcrypt, SHA-512 crypt)
  go to crypt(3).  Everything else is still compiled in.
- **Fix (tests): a root unit run deleted a live build cache.**
  `php_build_remove_support` removed `/var/cache/setup-php-build` and
  `/run/setup-php-build` by literal path, and a unit test calls it; run as
  root on the test host during a benchmark build, it deleted the cache under
  the running build.  The removal paths of all three builds are now
  overridable like the tools' own, the tests point them at their scratch
  directory, and a check refuses any literal `/var/cache/setup-*` or
  `/run/setup-*` removal.
- **Tools:** the sd_notify shim moved to `tools/build-common.sh` (php-fpm
  and Valkey use it); `setup_build_llvm_release` removes the shared LLVM
  toolchain with the last of the three builds;
  `tests/bench-php-matrix/switch-valkey-arm.sh` and `bench-valkey.sh` (A/B
  of Valkey binaries), and `switch-angie-arm.sh nginx-TAG` (an nginx arm for
  the Angie vs nginx comparison).

## 1.21.70 (2026-11-25)

- **Compiled Angie (`SETUP_ANGIE_BUILD=clang`, opt-in).**  Angie, OpenSSL,
  PCRE2, zlib-ng and Brotli from their own releases (versions in the new
  `angie-build.conf`), clang `-O3 -march=native` with Ubuntu's hardening
  flags, static, ThinLTO and BOLT from live traffic, with only the modules
  `server-configs-nginx` uses (no mail, stream, ACME, DAV, SSI, grpc, ...).
  It links only glibc from Ubuntu.  Before BOLT it served the cached guest
  pages **+3.6 to +6.1 %** faster than the package (5 rotated rounds, every
  tier's spread clear of the package's); member and uncached pages are
  PHP-bound and unchanged.  Installed through
  `setup.sh --optimize` with BOLT from live traffic: WordPress guest home /
  post **+12.4 % / +11.5 %**, XenForo guest thread / home +6.6 % / +4.4 %,
  Chevereto image / explore +6.1 % / +2.2 %.  The configuration, unit and logs
  stay the package's (a drop-in changes the binary only); the build has its
  own prefix, so its own Brotli modules load from the unchanged
  `modules-enabled/`.  Every start runs `angie -t` with the build; a
  configuration that needs a left-out module sends Angie back to the package
  on the next `--optimize`.  APT hook, daily rebuild timer and CPU guard as
  for php-fpm.  `tools/angie-build.sh`, `lib/angie-build.sh`.
- **Compression (item 4).**  In this stack Angie compresses the dynamic
  pages (1.6.56); PHP gzips WordPress and Chevereto pages for the guest cache
  (`SETUP_PHP_PAGE_GZIP`).  Angie's CPU per XenForo member page: gzip 1.19 ms
  (package) → 1.15 ms (zlib 1.4 from source) → **0.94 ms (zlib-ng 2.3.3,
  -21 %)**; Brotli 1.91 → 1.82 ms (Brotli 1.2.1 from source).  The compiled
  Angie uses zlib-ng.  PHP gzips WordPress and Chevereto pages itself, so
  the compiled php-fpm links zlib-ng too: **+7.3 % on uncached Chevereto pages**
  against the same build with zlib (WordPress +0.7 %, XenForo unchanged).  A PHP Brotli extension would serve no
  purpose: none of the three applications compresses with it, and Angie
  already does.
- **Security: the compiled php-fpm gets Ubuntu's hardening back.**  Upstream
  clang, unlike Ubuntu's gcc, enables none of it by default, and the 1.21.68
  and 1.21.69 builds ran without a stack protector, stack-clash probes,
  `_FORTIFY_SOURCE`, CET landing pads or full RELRO, all of which the package
  has.  Every library and PHP itself now build with
  `-fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=3
  -fcf-protection=full` (BTI on aarch64) and link `-z relro -z now`.
  Measured cost before BOLT: 0.5-2 % (XenForo thread -2.2 %, WordPress
  -0.7 %); it stays.
- **libsystemd is gone from the compiled php-fpm.**  PHP-FPM uses one call
  of it, `sd_notify()` for the unit's `Type=notify`; a 50-line static
  implementation of the protocol (a datagram to `$NOTIFY_SOCKET`) replaces
  it, and a unit test checks the datagram systemd receives.  The build now
  links only glibc (libc, libm) from Ubuntu.
- **glibc from source: built, measured, not shipped.**  glibc 2.44 builds
  from ftp.gnu.org and links statically, but a static php-fpm cannot use the
  system's NSS modules: when a worker switches to www-data, glibc reads
  `/etc/nsswitch.conf` (`files systemd`) and `dlopen`s Ubuntu's
  `libnss_systemd`, which pulls Ubuntu's own glibc 2.43 into the 2.44 binary;
  glibc aborts ("rtld_static_init.c:90: assertion failed: guard_sym !=
  NULL"), the master respawns workers forever and requests hang.  It also
  crashed at startup with `opcache.huge_code_pages` (the remap stub calls
  `mmap`/`memcpy`, which in a static binary sit inside the code being
  remapped; a patch fixed that).  Making it work would mean shipping glibc's
  whole runtime beside the binary, so glibc stays Ubuntu's, as for every
  package; the experiment code is not kept.  Two general fixes came out of it:
  `--disable-rpath` (PHP adds a RUNPATH per `--with-x=DIR`) and GNU libiconv
  for PHP's iconv.
- **PGO and AutoFDO measured (CachyOS-style).**  `-march=native` already does what CachyOS's
  x86-64-v3/v4/znver4 repositories do (each server compiles for its own CPU;
  a v4 binary cannot even start on the AVX2-only test Xeon), and ThinLTO and
  BOLT were in.  Compiler feedback before BOLT, 5 rotated rounds against the
  package (XenForo thread / home, WordPress, Chevereto uncached): LTO + BOLT
  **+10.6 / +6.8 / +6.5 / +3.8 %**; instrumented PGO + BOLT +8.3 / +6.6 /
  +7.2 / +4.9 %; AutoFDO (LBR samples, `llvm-profgen`) + BOLT +6.4 / +3.7 /
  +3.6 / +0.6 %.  Neither beats LTO + BOLT enough to justify a second build
  and a training run; neither is used.
- **Smaller, leaner php-fpm.**  `xmlreader` is no longer built (WordPress
  uses it only when libxml2 is broken; the package policy drops it too); PHP's
  iconv uses GNU libiconv from ftp.gnu.org; OpenSSL drops ciphers and
  protocols none of the applications use (legacy, national ciphers, binary
  curves, SRP, DTLS); `--gc-sections` and safe ICF; the binary php-fpm runs is
  stripped (php-fpm.lto keeps the symbols for BOLT): the BOLTed binary php-fpm runs is 48.4 MB
  (1.21.69: 60.4 MB unstripped), and it links only libc and libm.  The
  candidate must now show no module outside the app set and PHP's fixed core
  (`cgi-fcgi`, `lexbor`, `uri`).  10.4 MB of what remains is fileinfo's magic
  database.
- **CPU guard.**  `-march=native` ties a build to its CPU.  `build.info`
  records the CPU model; a build started on another one (disk moved, VM
  migrated to other hardware) refuses to start, goes back to the package
  binary and rebuilds, and `check` reports it as stale.
- **Downloads:** a transfer under 1 KB/s for 30 s now fails over to the next
  source (zlib.net stalled after 200 KB during a test build; `--max-time`
  alone would have waited 30 minutes).
- **`SETUP_PHP_BUILD=lean`/`source` removed** (operator request); `clang` and
  `package` remain.  A host file written by 1.21.68 that still says `lean` or
  `source` is rewritten to `clang` once, with a note.
- **Tools:** `tools/build-common.sh` holds what both build tools share
  (downloads with mirrors, checksums, version lookups, the LLVM toolchain);
  the toolchain is removed only with the last build that uses it.
  `PHP_BUILD_KEEP_WORK=1` keeps a failed build's work directory, and a failed
  `configure` keeps its `config.log`.
- **server-configs-nginx 1.6.60:** CI is back (`angie -t` on the tree and all
  vhost templates, ShellCheck, the public-address check); it had none since
  4 November.

## 1.21.69 (2026-11-24)

- **One compiled php-fpm, built from source, faster than both 1.21.68
  builds.**  `SETUP_PHP_BUILD=clang` now compiles PHP, redis/igbinary and
  every linked library from upstream (versions in `php-build.conf`), lean and
  static, with ThinLTO and BOLT; `lean` and `source` are aliases, and a
  persisted `PHP_BUILD=lean` keeps working.  The 1.21.68 `clang` mode (Sury's
  core and extensions) is gone.  Fresh install with WordPress, XenForo and
  Chevereto, 5 rotated rounds, vs the package: XenForo member thread / home
  **+11.0 % / +10.1 %** (1.21.68 clang: +8.9 % / +8.0 %), WordPress member
  home **+7.9 %** (+6.5 %), Chevereto uncached **+5.9 %** (+4.4 %); every
  round of the new build beat the old one's median.
- **Why the from-source build trailed:** ICU.  Before BOLT it ran 9 % fewer
  instructions per XenForo page than clang + Sury's extensions, yet it was
  1-2 % slower.  intl compiled ICU in, made the binary 102 MB and cost 4.5x
  the data-TLB misses (233 M against 52 M in 20 s).  intl is gone (XenForo
  ships Symfony's intl polyfills, WordPress checks `function_exists`,
  Chevereto does not use it); the binary is 60 MB, its misses match the
  package's, and it links only glibc and libsystemd.  Ruled out by
  measurement: `-fPIC` against `-fPIE` for the PHP core (no difference; the
  build now uses `-fPIE`), and BOLT sampling with `opcache.huge_code_pages`
  off (2,549 against 2,541 functions profiled, same speed; not shipped).
- **Every download has a second source**, tried when the first times out or
  fails: the project's own site first, GitHub (or a second official mirror)
  next, including LLVM's GitHub release tarball when apt.llvm.org is down.
  Published SHA-256s are checked from either source; Git snapshots get their
  `configure` generated.  A version lookup that no source answers keeps the
  version the running build was made from.  GMP's ftp.gnu.org timing out for
  minutes stopped a test build; the old code then only failed at `tar`.
- **Build recipe:** `build.info` records it, and `--optimize` and the daily
  timer rebuild an older one, so a 1.21.68 build is replaced once.
- **BOLT swaps the binary with a graceful reload** instead of a restart.
- **Test harness:** Chevereto starts a session file in `/tmp` for every
  cookie-less request.  At benchmark rates (1,500 req/s) its 24-minute GC
  window holds about 2 million files, past the tmpfs inode limit: MariaDB
  then failed its temporary tables and every application broke mid-run.
  `bench-php-sources.sh` now clears them between arms (production rates stay
  far below the limit; setup already turns GC on for Chevereto).
- Report: `tests/stress-site/AUDIT-20261124-1.21.69.md`.

## 1.21.68 (2026-11-24)

- **Three php-fpm builds, chosen with `SETUP_PHP_BUILD`** (primary focus).
  `package` (the default) is Sury's binary.  `clang` rebuilds the package's
  own PHP version and compiled-in core with clang from apt.llvm.org,
  `-O3 -march=native`, ThinLTO and BOLT, and Sury's shared extensions load
  unchanged.  `lean` compiles everything from upstream (the newest PHP,
  redis/igbinary and OpenSSL, PCRE2, zlib, libxml2, libsodium, GMP, curl,
  ICU, libjpeg-turbo, libpng, libwebp, libzip), links it statically and
  contains only the modules the three applications use.  Versions live in
  `php-build.conf` beside `setup.sh` (`latest` or a pin).  A daily timer
  rebuilds when upstream publishes a newer release, and the APT hook falls
  back to the package binary the moment the package changes.  Fresh install
  with WordPress, XenForo and Chevereto, 5 rotated rounds at 3.6 GHz, vs the
  package: XenForo member thread/home `clang` +5.8 % / +6.0 %, `lean`
  +4.5 % / +5.0 %; Chevereto uncached home +8.1 % / +9.0 %; WordPress member
  home `clang` −5.0 % (spread 131-144), `lean` +2.2 %; cached pages
  unchanged.  All three pass the functional, security and cookie suites
  with all three applications.  Previous compiler verdicts (1.21.64-66)
  built GCC without its global registers and never tried BOLT; with BOLT the
  earlier 20k-user forum measured +10 % on member pages.
- **php-fpm loads only what WordPress, XenForo and Chevereto need.**  The
  install and `--optimize` disable calendar, ffi, ftp, gettext, phar, posix,
  readline, shmop, sockets, sysv*, tokenizer, xsl and imagick for php-fpm
  only (`phpdismod -s fpm`; the CLI keeps them).  A host with another PHP
  application keeps everything and the report names the site;
  `SETUP_PHP_FPM_MODULES=all` turns it off.  Both re-enable exactly what was
  disabled.
- **Chevereto images go through GD; imagick is no longer installed.**
  Chevereto picks imagick only when it is loaded, and its integrity check
  accepts GD (PNG, GIF, JPEG, BMP, WEBP); uploads pass on all three builds.
- **phpinfo is no longer in `disable_functions`**: XenForo's "PHP info" and
  WordPress Site Health need it behind their admin logins.
- **`--upgrade-php` keeps operator settings in `www.conf`** (`env[...]`,
  `php_admin_value`, ...): the old pool is migrated with the version
  rewritten, and the template comes back if `php-fpm -t` rejects the result.
  Its optimize step no longer runs with `set -e` suspended.
- **`--mariadb` on a host that already has PHP** warns that the PHP-FPM pool
  stays sized for no local database until the next `--optimize` or `--php`.
- **MariaDB:** `innodb_buffer_pool_size_max`, `innodb_open_files`,
  `innodb_log_buffer_size` and `aria_pagecache_buffer_size` no longer force a
  restart; they apply at the next one.
- **Valkey:** `maxmemory 2g`/`512m` are decimal and `2gb`/`512mb` binary, as
  Valkey reads them (both were read as binary).
- **CPU count:** `OMP_NUM_THREADS`/`OMP_THREAD_LIMIT` in the environment no
  longer shrink the worker sizing (`nproc` honours them).
- **Test host restore** never purges kernel packages: purging the kernel
  that unattended-upgrades added mid-run took the `linux-generic`
  metapackages with it.
- Pair: `server-configs-nginx` 1.6.59 (encoded XenForo style/language
  cookies bypass the guest cache, plugin/theme `vendor`/`node_modules` PHP is
  refused, WooCommerce/EDD private uploads are internal, upstream
  `X-Forwarded-For` only from trusted forwarders).  Report:
  `tests/stress-site/AUDIT-20261124-1.21.68.md`.

## 1.21.67 (2026-11-24)

- **XenForo server shootout: Angie stays.**  Angie + Sury PHP-FPM with
  `fastcgi_cache`, Angie + a clang `-O3 -march=native` PHP-FPM, OpenLiteSpeed
  1.9.4 + LiteSpeed's lsphp85 with LSCache through the official XenForo
  add-on, and OpenLiteSpeed + the clang lsphp.  Same PHP 8.5.13, php.ini, 12
  PHP processes, certificate and forum (20k users, 10.2k threads, 103k
  posts), clock pinned at 3.6 GHz, arms rotated.  **Cached guest pages:
  Angie 125.0k vs 96.7k req/s on the forum index (−22.6 % for
  OpenLiteSpeed) and 99.4k vs 83.3k on a thread (−16 %)**; an LSCache hit
  costs 14-22 % more CPU.  **Member pages: a tie** once the harness defects
  below were fixed (thread +0.9 %, index +3.6 % for OpenLiteSpeed, equal CPU
  per page).  Under saturation Angie + FPM served every visitor in about
  0.45 s (p99 0.46-0.48 s); OpenLiteSpeed kept ~12 connections moving and
  parked the rest (p99 2-5 s, 4 of 300 probe requests past 30 s).  clang
  PHP: +3 % on member pages, 0 on cached ones, as in 1.21.66.  Report:
  `tests/stress-site/AUDIT-20261124-1.21.67.md`.
- **OpenLiteSpeed + the LSCache XenForo add-on, as documented, shows members
  the cached guest page.**  `CacheLookup on` serves the public entry to
  every request, and the add-on's `xf_lscxf_logged_in` marker only exists
  for logins made after it was installed, so remember-me sessions saw a
  logged-out forum.  The harness (`tests/bench-php-matrix/install-ols.sh`)
  adds `E="cache-vary:xf_session,xf_user,xf_lscxf_logged_in,xf_session_admin"`;
  it also documents two silent OpenLiteSpeed limits: `maxKeepAliveReq` above
  32767 becomes 100, and lsphp as `www-data` needs `minUID 11`.
- **Harness defects found while measuring:** `bench-php-sources.sh` printed
  p50 in its "p99" column since 1.21.64 (fixed; `RAW=` keeps every row with
  non-2xx and CPU); lsphp children outlived OpenLiteSpeed and cost the next
  Angie arm ~10 % (`switch-php-arm.sh` now drains them); wrk records latency
  only for finished requests, so a per-visitor probe measures starvation.
- **`--optimize` talks to Valkey where it really listens.**  The optimizer
  sent `CONFIG SET`/`GET`, the post-restart probe and the verification PING
  to the client default, 127.0.0.1:6379 (1.21.66 fixed only the installer's
  PING).  On an adopted cache that keeps an operator `bind` without loopback,
  or another `port`, every run failed the online change, restarted the cache
  (emptying it), failed the probe, restarted it again in the rollback and
  reported FAILED.  All of these now use the configured Unix socket
  (`valkey_endpoint_pong`), and `valkey_live_cli` prefers an operator's
  custom `unixsocket`.
- **The closing tuning pass of `--domain` runs in the main process.**  It ran
  inside `run_service`'s subshell as `run_optimize || warn`.  A web tier
  paused for a MariaDB restart there was invisible to `on_exit`, so a Ctrl-C
  or a dropped SSH session left Angie and PHP-FPM stopped, and the `|| warn`
  suspended `set -e` for every tuner.  The pass now runs from `main()` after
  the installation summary, as a plain call, like `--optimize`.  A failed
  tuner ends the run non-zero with the optimize report (it used to warn and
  exit 0).  `run_service`'s subshell also gets its own INT/TERM/HUP traps
  and an EXIT guard that resumes a paused web tier (the dump-import restart).
  An ignored HUP is inherited, never replaced, so `--upgrade-php` keeps
  apt/dpkg immune to a dropped session while PHP is being replaced.
- **An install that adds a domain keeps its own explicit sizes.**  `--php
  children=8 --mariadb size=2g ... --domain ...` logged the override and
  then reset it in the closing pass of the same run.  That pass now keeps
  the run's explicit values and `SETUP_*` tuning; a domain-only run on an
  existing host still resets the profile like `--optimize`.
- **MariaDB: a `max_connections` change no longer forces a restart.**
  `table_definition_cache` and `innodb_open_files` move with
  `table_open_cache` above 250 connections, but neither was an online or
  deferred key, so the online path was refused and the database restarted
  with the web tier paused.  `table_definition_cache` is now applied online
  (and read back); `innodb_open_files` waits for the next start.
- **`--upgrade-php` runs its post-Angie PHP refresh.**  `OPT_PHP_OK` was
  never set to 1 there, so `php_refresh_after_angie` never ran after an
  upgrade.  It now mirrors `--optimize`.
- **`--optimize --dry-run` previews the per-version PHP pool** that the real
  run writes when more than one FPM version is running.
- **`--purge` restores `/etc/hosts` byte for byte (the restore drift open
  since 1.21.64).**  The extra trailing newline came from cloud-init: with
  `manage_etc_hosts: localhost` it rewrites `/etc/hosts` at the first boot
  after `--basic` renames the host, and `--purge`, seeing a file that no
  longer matched the original outside the `127.0.1.1` lines, merged instead
  of restoring and kept cloud-init's blank line.  Blank lines no longer
  count in that comparison, and the audit restore removes its own hosts line
  before purging (reproduced on the test host: 265 vs 264 bytes before,
  byte-exact after).  `hosts_set_loopback_line` also keeps the file's
  final-newline state (awk used to add one), and `--purge` restores every
  original `127.0.1.1` line, not only the first.
- **`--purge elastic` removes `/etc/sysctl.d/99-elasticsearch.conf`**, which
  the install recorded "so --purge can remove it".
- **An interrupted `--diagnostics` leaves no unredacted report behind**:
  `on_exit` removes the temporary file, and `.gitignore` covers its name.
- The JIT threshold comment and README called the tuned 64/127/16/64 set
  "PHP's defaults" (PHP's return/side-exit defaults are 8/8); the opt-in
  session hardening no longer writes `session.sid_length` and
  `sid_bits_per_character` on PHP 8.4+, where they are deprecated.
- **Security (server-configs-nginx 1.6.58):** a Cookie header carrying a
  control character (`\v`, `\f`, ...) is never guest-cacheable.  PHP strips
  those bytes in front of a cookie name while the allowlist and Angie's
  `$cookie_*` did not, so `_ga=1;\vsso_token=...` stored its page for every
  guest (measured: `MISS MISS HIT`, then a plain guest got that copy).  The
  XenForo front-proxy cache no longer stores an origin 403/429, and the
  credential limiter counts an IPv6 client per /64 (40 addresses of one /64:
  all 200 before, 429 at attempt 12 after).  New checks: three tree checks,
  12 cookie probes (cookie suite 86 → 98) and an IPv6 /64 probe (security
  suite 73 → 74).
- **Harness:** `restore-baseline.sh` purges only orphaned packages the
  baseline never had (a blanket autoremove could remove baseline packages),
  removes the OpenLiteSpeed and source-PHP trees, and drops the vendor
  repository before `apt-get update`.  `sample-cpu.sh` attributes
  OpenLiteSpeed and lsphp CPU; the source arms now build the LiteSpeed SAPI.

## 1.21.66 (2026-11-23)

- **PHP build sources, last round: clang is +3 % on XenForo, nothing else
  wins, and PHP 8.4 is slower** (primary focus).  This round adds the
  CentminMod levers 1.21.64/65 had not measured.  Every arm compiles every
  module from source, igbinary included (3.2.17RC1 is the first release
  that builds against 8.5, so no downgrade was needed for it).  Arms:
  GCC `-O3 -march=native -falign-functions=32
  -fno-semantic-interposition` (`GCC_FALIGN_FUNCTION=y`), the same without
  falign, clang with the same flags (`CLANG_PHP=y`), and PHP 8.4.28 with
  the falign flags.  Five arms, 3 rotated rounds, clock pinned at 3.6 GHz.
  clang: XenForo member home +3.1 % and thread +3.1 % with
  non-overlapping spreads (+2.9 to +3.4 % in all three matrices),
  WordPress and Chevereto ±0.  GCC with or without falign: -1 % to -5 %.
  PHP 8.4: -2.9 % to -4.3 % on every tier, and its object/method section
  is 21 % slower on the CLI probe.  Verdict: Sury stays.  A 3 % gain on
  one application does not pay for a compiler toolchain and manual
  security rebuilds on every host, and 8.5 beats 8.4.
- **Harness fix: the source builds had no zlib.**  `build-php-source.sh`
  and `build-php-max.sh` never passed `--with-zlib`.  Every source arm since
  1.21.64 therefore skipped PHP's own page gzip for WordPress and Chevereto
  (`zlib.output_compression`, which this setup enables), left the
  compression to Angie, and on a cached tier never stored the page at all
  (the encoding guard refused it).  That bias favoured the source builds
  on the WordPress and Chevereto tiers, so the earlier "no gain" verdicts
  stand, but the numbers here come from builds with `--with-zlib
  --with-sodium`.  Sury and every arm now load the same application module
  set, and a guest page is stored and served from cache under each arm.
  `build-php-max.sh` also takes `CC=clang`, `NO_FALIGN=1`,
  `PHP_INI_DIR`, `IGBINARY_VER`, loads the shared OPcache of PHP 8.4 and
  older, and stops re-downloading PECL sources on every build.
- **Security (server-configs-nginx 1.6.57):** the XenForo front-proxy cache
  could store one member's page for every guest.  `proxy_cache` lacked the
  1.6.54 unknown-cookie default-deny, so an SSO or add-on login cookie
  reached the origin as a member and the page was cached under the guest
  key.  Unknown SNI over HTTP/3 is now refused by the catch-all (the first
  HTTP/3 vhost used to become the QUIC default server).  Compressed dumps
  (`.sql.zip/.bz2/.xz/.zst/.lz4/.7z`) are denied at any depth.  New
  regression checks: three tree checks for the proxy gate and six HTTP
  probes for the dumps (security suite 67 → 73).  The QUIC catch-all was
  checked by hand with an OpenSSL 3.5 QUIC client: an HTTP/3 vhost serves
  its certificate and an unknown name gets none.  A rotated A/B of the
  1.6.56 and 1.6.57 trees left every cached tier inside its spread, with
  Angie CPU per hit unchanged.
- **An interrupted `--upgrade-php` no longer leaves the host without PHP.**
  A signal, a `set -e` failure or a `die` between purging the old version
  and the new FPM serving exited through `on_exit` with nothing installed.
  The run now marks that window, `on_exit` rolls back while it is open, and
  a dropped SSH session (HUP) is ignored until the target serves.
- **A PHP rollback no longer "succeeds" into 502.**  `php_upgrade_rollback`
  restored the managed tree, then called `systemctl enable --now`.  The
  reinstalled package's postinst had already started FPM on the stock
  tree (`/run/php/php<ver>-fpm.sock`), and `enable --now` leaves a running
  unit alone, so the shared socket never came up and every site answered
  502.  Every rollback path had this.  Found by sending a TERM in the
  middle of a real `--upgrade-php=8.6` on the test host.  The rollback now
  restarts FPM and checks that the restored pool's socket listens; the
  same interruption now brings PHP 8.5 back with every site at 200.
- **Automatic swap never switches the live file off before its
  replacement exists.**  `configure_swap_auto` released the active
  `/swapfile` and counted its space as free.  `create_swap_file`, which
  builds the new file beside the old one, could then die on the disk check
  with swap left off.  The size is now computed by a pure function,
  `swap_auto_new_size`, that counts only real free space, and the swap
  itself is left to `create_swap_file`.  The unused `release_swap_file`
  is gone.
- **A MariaDB install that cannot restart restores its previous
  configuration**, the same as the parse-failure path, instead of leaving
  the server stopped with the generated files live.  It also waits as long
  as the optimizer (300 s) before creating the grants.
- **Valkey's install check pings the socket it wrote**, not
  127.0.0.1:6379, so an adopted configuration with an operator bind or
  port no longer fails the install.
- **Two running PHP-FPM versions share one planned pool.**  On an
  inherited host with two versions on separate sockets, each received the
  full static pool while the memory plan, MariaDB `max_connections` and
  Valkey `maxclients` counted one.  The pool total is now the sum over
  running versions.  Each version gets its share, which is stable across
  runs, and the connection limits count every worker.  A single-version
  host is unchanged.
- Unit tests: value checks for the Angie worker table (1 to 512 CPUs,
  dedicated and VPS) and the shared listen backlog, which had none, plus
  tests for every fix above (1,496 → 1,530).

## 1.21.65 (2026-11-23)

- **Everything on is slower: LTO is neutral, PGO costs 5-10 %**
  (follow-up to 1.21.64).  The same host and method, with
  `-O3 -m64 -march=native -mtune=native -falign-functions=32
  -fno-semantic-interposition` and, in turn, `-flto` and a two-stage PGO
  trained on real XenForo/WordPress traffic (779 `.gcda`, zero missing
  profiles at rebuild).  LTO alone is a wash (-0.7 % to +0.0 %); LTO+PGO
  is -9.7 % on the XenForo thread and -9.1 % on its home page, PGO alone
  -5 % to -6.5 %.  The CLI probe agrees with the JIT on (+19 % C-builtin
  time) and with it off (+25 %).  redis 6.3.0 and imagick 3.8.1 were
  compiled from source against the tree; igbinary 3.2.16 still does not
  compile on 8.5 and is not needed by XenForo's core cache provider.
  Build traps: `-fno-plt` + LTO does not link with bfd, and a PGO rebuild
  trips `-Werror=coverage-mismatch` on the reused `conftest.c` profile.
  Verdict unchanged: keep the distribution package and leave PGO off.
  New tools: `tests/bench-php-matrix/build-php-max.sh` and
  `train-php-pgo.sh`; `switch-php-arm.sh` now clears a stale FastCGI
  socket left by a crashed arm and respects source-built extensions.
- Suites: the same applications served every measured tier with HTTP 200
  on each arm; the host went back to its 696-package manifest with 0
  `/etc` changes.

## 1.21.64 (2026-11-23)

- **PHP install source and build flags: measured, no gain; Sury stays**
  (primary focus).  Four arms on the Xeon test host, 3 rotated rounds,
  clock pinned at 3.6 GHz: Sury 8.5.13 (Debian rules: `-O2` generic,
  hardening, `optimize=-lto`), Ubuntu 26.04's 8.5.4 from `universe`, and
  PHP 8.5.13 built from source with the minimal XenForo module set at
  `-O2 -march=x86-64` and at CentminMod's `-O3 -m64 -march=native`.  The
  builds are genuinely different (26,148 AVX2 instructions in the
  `-march=native` binary against 171 in the distribution ones), and the
  result is still flat: WordPress member unchanged, XenForo member home
  and thread −3.8 % to +1.6 % with overlapping spreads, nothing outside
  the noise.  A 15-run CLI probe of C builtins (json, preg, string, hash,
  sort) is 1.9 % slower for `-march=native` than Sury's `-O2` and 5.5 %
  slower for the generic source build; the JIT-emitted loop section is
  0.218 ms for all four arms.  With `opcache.jit=tracing` the hot PHP code
  is generated at run time and never passes through the C compiler, so
  the flags only reach the interpreter's own helpers, which are a small
  share of a page since 1.21.63 moved zlib to Angie.  Decisions: no
  `--php repo=` switch (Ubuntu is not slower, but it is 9 patch releases
  behind and adds a packaging path for no gain) and no compiled PHP (a
  toolchain and manual security updates on every host for nothing).  The
  harness is new under `tests/bench-php-matrix/` so the question can be
  re-opened when the JIT, the compiler or the workload changes.
- **Per-application PHP maximum re-verified** with the full round trip
  (`--upgrade-php=8.6` 1:23, back to 8.5 1:12, 14 extensions carried, 0
  skipped) and `compat-php.sh` on each version: WordPress 8.6, XenForo
  8.5, Chevereto 8.6.  XenForo serves its production pages on 8.6, but its
  debug mode answers 500 on every page and the bundled Braintree and
  laminas-mail files still fail `php -l` (the same two files also fail on
  8.5; they only break the payment and mail code paths there).
- Suites: fresh install 3:24 / 0 warnings, 1,496 unit checks, 227 dry
  runs, security 67/67, guest-cache cookies 86/86, functional exercise 0
  unexpected on 8.5 and 8.6, `--optimize` twice with 0 of 3,285 facts
  different.  Restore: 696 → 696 packages, 0 `/etc` files changed.

## 1.21.63 (2026-11-23)

- **XenForo member pages: +5 % home, +9 % thread, lower p99** (primary
  focus: logged-in throughput).  A profile of the member thread tier showed
  zlib at 12 % of all PHP-FPM CPU: XenForo gzips every uncached page itself
  at level 9.  The handover to Angie (1.21.36, `XF_MEMBER_GZIP=angie`) only
  existed as a block in each forum's `src/config.php`, written by
  `--optimize`; a forum installed after the server never had it.  The rule
  now lives in the Angie tree (`server-configs-nginx` 1.6.56): the uncached
  XenForo handler gives PHP an empty `Accept-Encoding`, so Angie compresses
  (Brotli/gzip level 4) from the first request of a new install, and the
  next `--optimize` rolls it out to running hosts (same rsync, no extra
  code path).  Measured at a pinned 3.6 GHz, 3 rotated rounds: member home
  473 -> 497 req/s, thread 261 -> 285, PHP CPU per thread page 41.6 ->
  34.7 ms (whole server 45.5 -> 40.8 ms with Angie's Brotli counted), p99
  566 -> 503 ms; guest-cache tiers unchanged.  The `src/config.php` block
  stays as a second guard for hosts on an older tree.
- **Measured and rejected** (numbers in the audit report): Zend heap on
  transparent huge pages (`USE_ZEND_ALLOC_HUGE_PAGES=1`) hangs the pool under
  load; 15 or 18 FPM workers equal 12 on 12 threads; a lower default Brotli
  level (1 gains 4-6 % for 40 % more bytes, 2-3 inside the noise; the
  README now gives the trade-off for `SETUP_BROTLI_LEVEL`).
- **Benchmark method: pin the clock.**  The test host's turbo is
  power-limited (PL2 112 W, then PL1 80 W): the clock drops from 4.5 to
  4.1 GHz mid-run and PHP CPU per request follows it 1:1, which produced a
  phantom +16-27 % "restart effect" this cycle and is behind the earlier
  first-slot bias.  `tests/stress-site/set-clock.sh MHZ|restore` pins
  `scaling_max_freq` (sysfs only); `loopback-tiers.sh` now prints compact
  per-service ms/request, busy cores and the mean clock for every tier (the
  old column was cut at 230 characters and lost PHP-FPM), and the Chevereto
  member tier uses `/explore/` (it measured a 301 as 0 req/s).
- Regression tests: a tree check that the XenForo handler withholds
  `Accept-Encoding` after the fastcgi snippet while the guest-cache location
  keeps the key's encoding, and an `exercise-apps.sh` check that a member
  asking for `br, gzip` gets Brotli (only Angie produces it) on a real member
  page.

## 1.21.62 (2026-11-23)

- **Anubis is gone** (primary focus).  The optional bot filter was a Go
  proxy in front of every vhost, with a TLS-terminator generator, a
  static-asset shadow, an njs pass-cookie verifier, a systemd unit and a
  policy file: `lib/anubis.sh` alone was 1,690 lines and the integration
  touched nine modules.  Production sites sit behind Cloudflare, so the
  whole feature is deleted (2,4xx lines with its tests and documentation)
  and `--angie anubis=…`, `--optimize anubis=…` and `SETUP_ANUBIS*` now
  fail with an explanation instead of silently deploying without the filter
  they ask for.  `tools/remove-anubis.sh` migrates a host that still runs
  it: restore every vhost from its pre-integration copy, remove the
  generated Angie files, `angie -t` and a graceful reload while the filter
  is still up, then stop/disable it (`--purge` also deletes the binary,
  `/etc/anubis`, the unit and the user).  A vhost whose backup is missing
  stops the tool before anything is stopped.  `setup.sh` refuses to run on
  an Anubis-managed host (`--diagnostics` and `--purge` still work) so no
  host can be left half-migrated.
- **Cloudflare TLS is no longer suppressed.**  `cloudflare_tls_migrate`
  returned early whenever the filter was managed, which is why the
  Cloudflare path never ran on a protected host; it now applies to every
  vhost with a certbot certificate.
- **The Anubis traces in the Angie tree are gone** (`server-configs-nginx`
  1.6.55): the `techaro.lol-anubis-*` alternatives left the
  `$guest_cookie_unlisted` allowlist and the `unix:` peers left the
  `$app_https`/`$trusted_forwarder` maps.
- **Chevereto's front-controller redirect is a string compare, not a PCRE**
  (primary focus: leaner maps).  Both Chevereto PHP files tested
  `$request_uri ~ "^/index\.php(?:[?]|$)"` on every request; a request Angie
  did not rewrite has `$request_uri == "$uri$is_args$args"` while a
  `try_files` redirect keeps the original `$request_uri`, so the identical
  rule is now one string comparison.  Verified live: `/index.php` → 301 `/`,
  `/index.php?a=1` → 301 `/?a=1`, `/explore` untouched.
- **`http.d/referer_map.conf` removed**: it defined `$302_referer` and
  `$302_method`, which nothing referenced; `--optimize` retires an existing
  copy.
- Suites: 1,469 unit checks, 226 dry runs, functional 0 unexpected, install
  3:09 / 0 warnings.  Measurements and the before/after table:
  `tests/stress-site/AUDIT-20261123-1.21.62.md`.

## 1.21.61 (2026-11-23)

- **A guest cache could store one visitor's page for everyone** (high,
  security; `server-configs-nginx` 1.6.54).  The WordPress, XenForo,
  Chevereto and Flarum caches bypassed on a fixed list of session cookie
  names and treated every other cookie as page-neutral, so a plugin session,
  an SSO token or a language selector outside the list rendered a
  personalised page that was then stored for every guest.  The rule is now
  default-deny: one map (`$guest_cookie_unlisted`, one PCRE pass per request,
  none without a Cookie header) accepts only analytics/consent cookies,
  CDN/bot-management cookies, the Anubis pass cookie and the apps' own
  page-neutral guest cookies; every cache decision and `*_no_cache` line
  consumes it.  A language selector keeps bypassing because it changes the
  page.  `--optimize` adds the variable to XenForo lines written by older
  releases.  The Anubis case was found by the end-to-end run: its
  `techaro.lol-anubis-auth-*` cookie is now neutral (before the fix every
  Anubis-fronted request was a cache `BYPASS`).  Cookie suite 86/86.
- **PHP application-server shootout** (primary focus):
  `tests/stress-site/php-server-shootout.sh` and `php-appsim/` compare
  PHP-FPM, PHP-CGI, FrankenPHP (classic and worker), RoadRunner,
  Swoole/OpenSwoole, Workerman, ReactPHP, AMPHP and PHP's built-in server on
  one application-shaped workload, then FPM/CGI/FrankenPHP on the real
  WordPress/XenForo/Chevereto roots without a page cache.  Verdict: keep
  PHP-FPM.  Workerman/Swoole are 1.4-1.6x faster but need the application to
  be ported to a persistent worker; FrankenPHP worker is 26 % faster than
  its classic mode but does not beat FPM and is 44 % slower on Chevereto;
  RoadRunner and AMPHP are slower than FPM.  Numbers:
  `tests/stress-site/AUDIT-20261123-1.21.61.md`.
- **A rejected MariaDB configuration no longer stays on disk.**  The install
  path now snapshots `/etc/mysql/mariadb.conf.d` before the rewrite and puts
  the old tree back when `mariadbd` rejects a directive, instead of leaving a
  host that cannot restart after the next reboot.
- **`opt_backup` fails closed.**  A failed `cp -a` used to leave a partial
  snapshot and turn a later rollback into a no-op; it now removes the partial
  copy and stops before any change.
- **Cache paths reserve filesystem headroom.**  Every shipped `cache_path`
  sets `min_free=512m`, and the Chevereto zone default drops from 1 GiB to
  512 MiB for a host that deploys the tree without setup.sh (which still sizes
  every zone from RAM).
- **README persistence drift corrected.**  The feature-choice table now says
  which `SETUP_*` names are written to `/etc/default/setup-tuning` and which
  are one-run inputs.  Making the rest persistent is an open item.
- Suites: 1,612 unit checks, 227 dry runs, security 67/67, cookie 86/86,
  functional 0 unexpected, `--optimize` x2 0 of 3,076 facts, Anubis on/off
  clean, restore 696 -> 696 packages.

## 1.21.60 (2026-11-23)

- **A fresh install no longer fails at the swap step.**  `create_swap_file`
  activated `/swapfile.new` with `swapon` and then tried to rename it; Linux
  refuses `rename(2)` on active swap (`EPERM`), so every fresh
  `--basic swap=8G` died ("Could not move the new swap file into place") and
  skipped sysctl, PAM limits, udev, cron and UFW.  The new file is validated
  with `mkswap` while inactive, the old file is renamed aside, the new one
  takes `/swapfile`, and only then is it activated; a failed `swapon` puts
  the old file back.  `Swap=` below 64 MiB is now rejected by validation
  before hostname/timezone/DNS are touched.  Six new source-order checks and
  two dry-run rows; verified live on a pristine host (`basic OK`, 8 GiB
  active).
- **A direct client can no longer choose PHP's forwarded identity**
  (`server-configs-nginx` 1.6.53).  `X-Forwarded-Host`, `-Proto`, `-For`,
  `X-Real-IP` and `Forwarded` used to reach PHP exactly as sent; a cache
  MISS could render absolute URLs for an attacker's host and be stored, and
  app-level IP allowlists could be spoofed.  The headers now come from a
  trusted peer map (Unix socket, loopback, `custom.d/trusted_proxies.map`) or
  from the direct peer, with the normalised host/public port/scheme.
  Verified with a PHP probe from the public address and from loopback
  (Anubis keeps its header).
- **`--optimize` keeps a hand-managed Elasticsearch bind.**  `http.host` /
  `transport.host` were commented unconditionally, so a node that binds with
  `http.host` and has no `network.host` silently moved to localhost while
  the health probe queried the new endpoint.  They are commented only when
  `network.host` controls the bind.
- **`SETUP_CF_SELF_SIGNED=0` is persisted** as `CF_SELF_SIGNED` (the README
  already promised it), and every persisted tuning value is now written with
  `%q`: a quote or `$(...)` in `SETUP_LIMIT_REQ_EXEMPT` used to become shell
  code when `/etc/default/setup-tuning` was sourced as root.
- **Media and headers** (`server-configs-nginx` 1.6.53): Chevereto's
  `/images/` no longer disables `sendfile` on the media hot path and no
  longer sends a second `Cache-Control` beside the inherited `expires`;
  Flarum's PHP locations keep `X-Frame-Options`, XenForo's static locations
  keep CORS and the security set, and the XenForo `/proxy.php` / `/css.php`
  cache no longer stores every unique query on its first request
  (`fastcgi_cache_min_uses 2`).
- **Web-server shootout** (primary focus): Angie 1.12.5, nginx 1.28.3,
  FreeNginx 1.31.5, OpenResty 1.31.8.1, Tengine 3.1.0 and Caddy 2.11.9 on
  the same PHP-FPM pool and app roots.  The server core is not the
  difference the marketing implies: every nginx-family build lands inside
  the run-to-run spread, and the 100x factor is the generic FastCGI cache,
  which stock Caddy does not have.  Verdict and numbers:
  `tests/stress-site/AUDIT-20261123-1.21.60.md`.

## 1.21.59 (2026-11-23)

- **zstd removed and purged.**  1.21.58 installed `angie-module-zstd` for
  clients that offer zstd, but Cloudflare asks origins for `br, gzip` only,
  so on Cloudflare-fronted hosts it never answered a request.  `--optimize`
  now moves the managed `60-zstd.conf` / `http.d/zstd.conf` (and an older
  `40-zstd.conf`) to `/tmp` and, once `angie -t` passes without them,
  purges `angie-module-zstd` once the Angie pass has committed (after the
  reload, so a rollback never restores a tree that loads a purged module).
  Nothing is retired while an operator's own file uses zstd directives (they
  rely on the managed `load_module`), and the module stays when apt would
  remove anything else with it.  `SETUP_ZSTD_LEVEL` is gone.  Verified on the audit host:
  0 warnings, both stanzas moved, the package purged, compression Brotli 4
  then gzip.
- **Guest cache: one entry per encoding (`server-configs-nginx` 1.6.52).**
  With `Vary: Accept-Encoding` honoured, each distinct client header kept
  its own copy of every page (one XenForo thread stored three times:
  Chrome, Safari, Cloudflare), each filled by its own PHP renders.  The
  guest caches now ignore `Vary` for storage, and the application is given
  exactly the key's encoding (`gzip` or nothing), so the stored body
  follows the key: `deflate` or `gzip;q=0` get a plain page instead of a
  deflate/gzip body stored per header.  After the fix every gzip-capable
  header HITs the entry Chrome filled; the thread is stored twice (gzip,
  plain).  Because `Vary` is ignored, two guards decide what is stored: a
  body whose `Content-Encoding` does not match the key (a WordPress
  subdirectory location that passes the raw header) and a response that
  varies on more than `Accept-Encoding` are never stored.  The
  setup-managed map for legacy XenForo includes (`$setup_cache_ae`) and the
  injected cache block follow the same rule.
  Cached tiers unchanged (WordPress 85-90k, XenForo 125k, Chevereto 131k
  req/s; Angie 0.06-0.09 ms per hit).

An adversarial review (three lenses, two refuting reviewers per finding)
upheld four findings, all fixed before release: the WordPress subdirectory
path (mismatch guard), the purge running before the Angie pass committed,
retirement breaking an operator file that uses zstd, and an untested map
upgrade path.

Tests: 1,582 unit checks (zstd retirement and purge guards, the encoding map,
both storage guards and every cached location in the shipped tree), 225 dry
runs, security 67/67, guest-cache cookie suite 80/80 (13 new checks, which
fail on 1.21.58), functional 0 unexpected, `--optimize` x2 0 of 3,032 facts.


## 1.21.58 (2026-11-22)

Compression cycle: gzip, Brotli and zstd measured per tier (guest cache,
members, static) on the Xeon E-2236 test host, encodings interleaved round
by round, Angie and PHP CPU read from their cgroups.  Details:
`tests/stress-site/AUDIT-20261122-1.21.58.md`.

- **Static assets are precompressed by default.**  Compressing an asset on
  every request capped the 177 KB XenForo core script at 2,063 req/s
  (3.9 ms of Angie CPU each, Brotli 4).  From its `.br` sibling (Brotli 11):
  **62,808 req/s** at 0.11 ms, and 15 % fewer bytes (54.6 -> 46.4 KB);
  WordPress block CSS 4,290 -> 93,204 req/s, jQuery 3,620 -> 81,741
  (rotated A/B, `Accept-Encoding: br, gzip`; 22-30x).
  `SETUP_PRECOMPRESS_ASSETS` now defaults to 1 (0 turns it off and removes
  the siblings it made, which a plain off switch used to leave behind for
  `gzip_static` to serve).  The first pass over a tree runs in the
  background (several minutes for XenForo + WordPress: gzip -9 and brotli
  -q 11 for every asset), so `--optimize` does not wait for it; the cron
  helper takes a lock so the 5-minute run skips while it is busy.  The pass
  itself: a source that shrinks to 1 KiB or less loses its sibling (it kept
  serving the old larger version), a sibling is rebuilt when its mtime
  differs from the source in either direction (a rollback restores an older
  mtime), a file rewritten during compression is left for the next run, and
  a root that leaves the list has its siblings removed.
- **zstd for dynamic responses, ahead of Brotli.**  `angie-module-zstd`
  (level 3) is installed with the Brotli module and loaded after it: the
  filter loaded last runs first, so every client that offers zstd (current
  Chrome, Edge, Firefox) gets it, Safari and Cloudflare (which asks origins
  for `br, gzip` only) keep Brotli 4, gzip stays the fallback.  XenForo
  member thread (127 KB HTML): Brotli 4 18.3 KB at 2.1 ms of Angie CPU,
  zstd 3 19.4 KB at 0.84 ms (61 % less Angie CPU), member throughput 379 -> 404 req/s for a
  browser that offers zstd (Cloudflare-fronted origins are unchanged here).  zstd 5
  would match Brotli's bytes at 1.4 ms; level 3 is the knee.  Precompressed
  assets stay `.br`: Brotli 11 beat zstd 19 on every asset (46.4 vs 49.1 KB
  on the core script), so no `zstd_static`.  An earlier release's managed
  `40-zstd.conf` (loaded before Brotli, so it never answered) is moved
  away; if Angie rejects the zstd stanza only zstd is dropped.
  `SETUP_ZSTD_LEVEL=0..19` (0 = off) is a tuning override like
  `SETUP_BROTLI_LEVEL`.
- **WordPress/Chevereto guest pages stored at gzip 6 (was 4).**  The stored
  page is compressed once per MISS and sent on every hit: cached WordPress
  post 14.9 -> 14.2 KB, Chevereto explore 12.7 -> 12.0 KB (-5 %), about
  0.35 ms more per MISS or member page.  Measured and not changed: Angie
  instead of PHP for WordPress members (browser 145 vs 144 req/s, inside
  the spread; `br, gzip` 145 vs 141, Angie 3 % slower), storing zstd from PHP (php8.5-zstd; zstd 19 costs ~70 ms per MISS
  and Cloudflare never asks for it).  A stored Brotli page would be 14-22 %
  smaller than the stored gzip, but no PHP Brotli extension is packaged.

Security (each with a regression test; found by this cycle's code audit,
two independent reviewers per finding, then reproduced on the host where
possible):

- **A member's page could be stored for guests with a folded cookie name.**
  PHP turns `.`, space and `[` in a cookie name into `_`, so
  `xf.session=<sid>` logs a XenForo member in while the bypass map tested
  the literal `xf_session=` and saw a guest.  Reproduced on the audit host:
  two requests stored the logged-in thread page and the next cookie-less
  guest received it (HIT).  The managed XenForo map now accepts every
  folded separator and any prefix (a forum with
  `$config['cookie']['prefix']` was treated as a guest too), and a cookie
  name holding `%` bypasses.  Same fix for WordPress, Chevereto and Flarum
  in `server-configs-nginx` 1.6.51.
- **`--optimize` stripped two XenForo guest-cache guards on every run.**
  `tune_xf_cache_bypass_var` rewrote the repository's `fastcgi_no_cache` /
  `fastcgi_cache_bypass` lines to the bare cookie map, dropping
  `$req_encoded_path` and `$cache_uri_tracking`: a percent-encoded route
  became cacheable again and a tracking-parameter URL (keyed on its clean
  URL) could store another page under that key.  Only legacy lines that
  test raw `$cookie_xf_*` are rewritten now, and those keep both guards.
- **The setup-managed XenForo encoding map treated `gzip;q=0` as a gzip
  client** (unanchored `~*gzip`); it now uses the strict rule of
  `$guest_cache_enc`.
- **Anubis no longer opens an origin that only accepts its front proxy.**
  The `$realip_remote_addr` 444 guard was commented out of the socket-side
  vhost and never re-applied on the public terminator; it is now carried
  there (only guards setup.sh commented, never one the operator retired) and
  restored by `anubis=no`.
- **Basic-auth password files under `/etc/angie` keep 0640.**  The tree
  normaliser reset them to 0644 on every run; they are now set to
  `root:<worker group> 0640` before it and skipped by it.

Fixes:

- `--upgrade-php`: refuses (dry run: BLOCKED) when another installed PHP
  version has custom ini fragments, extra pools or a listener Angie uses,
  since the purge removes every version (`SETUP_PHP_PURGE_OTHER_VERSIONS=1`
  overrides); `--upgrade-php=X.Y` for the installed X.Y only installs the
  pending extensions instead of purging and reinstalling; a rejected
  migration rolls back only what it wrote (a package-owned
  `conf.d/20-redis.ini` survived no longer); the dry run names the same
  source version as the real run.
- `--optimize` on a pool left on TCP points `upstream local_php` at that
  listener after the repository sync (every PHP site answered 502).
- `SETUP_PHP_SESSION_HARDENING=1` is persisted and kept by the profile
  reset (it vanished on the next plain `--optimize`).
- The PHP refresh after the Angie sync rolls `/etc/php/<ver>` back when
  `php-fpm -t` rejects it.
- Planner: the dry run with a pending profile reset plans like the real run;
  an explicit `--php children=N` is booked in the memory plan; MariaDB
  `max_connections` is never capped below the persistent connections the
  pool holds; the Angie cache never exceeds half the free space of its
  filesystem; a non-root `--optimize --dry-run` says its sizes are defaults;
  an install that adds a data service to an Angie host warns that the cache
  is re-sized on the next `--optimize`.
- `--purge basic` drops the `CPU_MITIGATIONS` pin with the GRUB drop-in (the
  next run recreated it); the Anubis metrics port is a reserved local port.

PHP 8.6: `php8.6-redis`, `-igbinary` and `-imagick` are published now.
`--upgrade-php` 8.5 -> 8.6 -> 8.5 ran clean with all three applications
(1:52 each way, 0 warnings, 0 diagnostics in production mode).  WordPress
7.1.4 and Chevereto 4.5.9 run on 8.6.  XenForo 2.3.13's production pages
work, but in debug mode every page answers 500 (`src/XF/App.php` raises a
deprecation as an exception) and the bundled Braintree and laminas-mail
null transport no longer compile, so XenForo stays on 8.5:
`--domain app=xf` on PHP 8.6 and `--upgrade-php` to 8.6+ with a XenForo root
print that caution (not a block).  A plain `--php` already auto-selects 8.6.

## 1.21.57 (2026-11-21)

- **Anubis: browsers with a valid pass cookie skip the Go hop.**  The edge
  route (1.21.55) sent every `Mozilla` request to Anubis, so a visitor who
  had already solved the challenge paid the proxy hop on every page.  With
  `angie-module-njs` (installed with the filter from the Angie repository),
  `/etc/angie/njs/anubis_pass.js` checks the cookie the way Anubis 1.28
  does for a CHALLENGE rule: HS512 signature with the Anubis secret,
  `exp`/`nbf`, `action`, and the `restriction` claim (SHA-256 of the visitor
  address, confirmed against a real token).  A token issued before
  `botPolicies.yaml` last changed, the first request after a challenge
  (Referer restore), an empty User-Agent, AI crawlers and anything malformed
  still reach Anubis.  Verified tokens are remembered in a 4 MB njs shared
  dict until their `exp`, keyed by token, address, policy epoch and a secret
  fingerprint.  The secret reaches Angie through
  `/etc/angie/ssl/anubis/pass-key.conf` (0600, under `ssl/` because the tree
  normaliser resets every other file to 0644).  Cached pages with a pass
  cookie, c=100: XenForo 17.7k (1.21.55, through Anubis) -> **55.2k
  req/s**, WordPress 16.7k -> **50.0k**.  Without njs (module unavailable or `angie -t` rejects it)
  browsers stay on the Anubis hop; `SETUP_ANUBIS_PASS_EDGE=0` opts out and
  removes every piece.  `anubis=no` removes them too.
- **WordPress/Chevereto guest cache: gzip bodies from the first deploy.**
  The per-root `zlib.output_compression` section (so the cache stores
  PHP's gzip output instead of Angie compressing every hit) was written only
  for roots that already held `wp-config.php` / `app/env.php` when the tuner
  ran.  A site created with `--domain app=wordpress|chevereto` and filled
  afterwards, the usual order, kept the slow path until someone ran
  `--optimize` again: cached WordPress 6.6k req/s (Angie at 800 % CPU,
  1.2 ms per hit) instead of 93k, Chevereto 9.3k instead of 140k.  The vhost
  now decides (an encoding-aware cache key is still required).
- **`apt-get update`: a stale index on a repository CDN no longer costs 7.5
  minutes and the install.**  Sury's CDN served an `InRelease` generated
  at 09:01 (45 minutes in its cache) next to a `Packages.xz` from 09:31, so
  the 1.21.56 retries (30, 60, 120, 240 s) all failed and the full install
  stopped.  The uncompressed `Packages` was from the same build as the
  `InRelease`, so it matched.
  On a size or hash mismatch the repositories named in the failure are now
  refetched uncompressed first (only those sources, `List-Cleanup` off, so
  the other lists stay as fetched), with an info line instead of a warning;
  the timed retries remain the fallback.

## 1.21.56 (2026-11-21)

- **No php-redis / php-igbinary by default.**  The `--php` set no longer
  installs `phpX.Y-redis` (and so not `phpX.Y-igbinary`, its dependency).
  XenForo runs without it: the SV RedisCache add-on's bundled Credis client
  falls back to a pure-PHP connection (`standalone =
  !extension_loaded('redis')`), and WordPress needs it only with an
  object-cache drop-in.  `--domain` now installs what a site cannot run
  without through one shared helper (`php_ensure_app_extensions`, the same
  table the upgrade preflight uses): Chevereto gets `redis` and `imagick`,
  XenForo and WordPress nothing extra.  `--upgrade-php` carries `redis` like
  any other extension (only when the old version had it).  Existing hosts are
  not changed: nothing is purged.  The data-cache trade-off is unchanged:
  php-redis + local Valkey measured +7-9 % authenticated XenForo throughput,
  so add it by hand where the XF cache stays on.
- **`--upgrade-php` no longer blocks on an extension the site does not
  use.**  The XenForo rule treated any uncommented mention of Redis or Valkey
  in `config.php` as a php-redis requirement, so a forum on SV RedisCache
  (Credis, no php-redis loaded) was refused for `--upgrade-php=8.6` ("php8.6-redis
  is not published").  Only XenForo's own `Redis` provider (or Doctrine's
  `RedisCache` named directly) counts now.  And for every application, an
  extension that no installed PHP-FPM loads cannot be lost by the upgrade:
  it is reported as a note, never a blocker.  The module list is the union
  over every installed version (the purge removes all of them), so the dry
  run and the real run agree; one unreadable version, or none installed,
  keeps every requirement.
- **WordPress: `--domain` installs php-redis only for a drop-in that cannot
  run without it.**  Any `wp-content/object-cache.php` used to count, which
  with `--domain` now installing requirements would have pulled
  php-redis/igbinary in for W3 Total Cache, LiteSpeed, APCu or Memcached
  drop-ins and for Redis Object Cache (it bundles Predis).  The rule now has
  two strengths: `--domain` installs redis only for a drop-in that creates
  `\Redis` with no Predis fallback, or for Object Cache Pro (phpredis or
  Relay).  The `--upgrade-php` preflight still counts any drop-in that
  mentions Redis, so a loaded php-redis is never purged from under one; the
  "no installed PHP-FPM loads it" waiver keeps that from blocking hosts
  without redis.
- `php -m` is read whole and only a successful run counts (a failed one could
  leave a partial list that would waive real requirements, and an early
  `sed q` could SIGPIPE the pipeline under `pipefail`).
- **`apt-get update` rides out a repository mid-sync.**  Sury's CDN served
  a `Packages.xz` that did not match its `Release` ("File has unexpected
  size ... Mirror sync in progress?") and three tries 5 s apart all failed
  inside the window, ending in "command failed at line 1142".  A mirror-sync
  or hash-sum failure is now retried after 30, 60, 120 and 240 s; other
  failures keep the three quick tries.  `--upgrade-php`, the system update
  and the repository setup stop with a message naming the cause (and, for the
  upgrade, that nothing was changed and the old PHP is still serving).

## 1.21.55 (2026-11-21)

- **Anubis: requests the policy allows without a cookie skip the Go hop.**
  Every request on a protected site used to pass through the Anubis
  process, including the ones its own policy lets through on the
  User-Agent alone: search-engine crawlers (`allow-good-crawlers`) and
  every client that is not a browser (the policy's default-allow: API
  clients, monitors, feed readers, cron).  For those Anubis checks nothing
  and only adds a proxy hop.  The terminator now picks the upstream with
  `proxy_pass http://$anubis_route`. Two maps in `00-anubis-common.conf`
  send those requests straight to the backend socket, with the headers
  Anubis would forward.  Browsers (`Mozilla`), an empty User-Agent, the
  `deny-ai-crawlers` list and `/.within.website/` still reach Anubis.  The
  maps and `botPolicies.yaml` are generated from the same patterns
  (`ANUBIS_GOOD_UA_RE`, `ANUBIS_AI_UA_RE`), so they cannot drift.
  Measured on the Xeon E-2236 test host (loopback, c=100, cached guest
  page through the filter): XenForo non-browser 29.5k -> 73.2k req/s,
  Googlebot 31.3k -> 72.2k, WordPress non-browser 26.7k -> 59.4k.
  Browsers with a pass cookie take the Go hop as before (17.7k XenForo).
  Verified by response body: curl and Googlebot get the page; GPTBot, a
  browser and an empty User-Agent get the challenge.
- **`--upgrade-php` and `--purge php` run without dpkg warnings.**  Each
  upgrade printed two `dpkg: warning: ... directory '/etc/php/X.Y/...' not
  empty so not removed` lines.  The managed `zz-setup-optimize.ini` and
  `custom_dan.ini` kept `fpm/conf.d` non-empty, and apt removed
  `phpX.Y-common` before the extensions that share `mods-available`.
  After the existing `/etc/php` backup, `purge_php_installations` now
  removes the conf.d fragments no package owns (and puts them back if the
  purge fails), then purges the extensions first and the `-common`
  packages in a second transaction.  8.5 -> 8.4 -> 8.5: 0 warnings
  (2 + 2 before), the state after the round trip matches the state before it.
- **Real server addresses are kept out of the repositories.**  Every
  real server address, host name and site domain was replaced with RFC
  5737 addresses and `example` names, in the current tree and in the
  history of both repositories.  CI now runs `tools/check-public-ips.sh`
  on both: a public IPv4 address that is not a published third-party
  address in `tools/public-ip-allowlist.txt` fails the build.
- Tests: the web-root hygiene checks no longer read the host's
  `/etc/angie` (they failed on a machine with Angie installed).
  `deploy-xf.sh` finds the XenForo package by pattern (`XF_ZIP` overrides
  it).

## 1.21.54 (2026-11-21)

- **The Valkey report says why a maxmemory was kept.**  A cache started
  less than a day ago (or one that cannot be measured) keeps its size by
  design, but the report then fell through to "Live working set=20mb;
  maxmemory=998mb (data+20%, 128 MB minimum; a size up to 10% above that is
  kept)", which contradicts the numbers (seen on site-c.example right after apt
  restarted Valkey).  The plan now names those cases (`young`,
  `unmeasured`); the report and the dry-run summary print the real reason.

## 1.21.53 (2026-11-21)

- **The "large archives inside web-accessible paths" WARNING lists only
  archives Angie can serve.**  The hygiene scan reported every archive over
  100 MB under `/var/www`; on site-d.example that was a WARNING for Pingvin
  Share's private `pingvin_data/uploads/shares/*/archive.zip` (322 files,
  20 listed), none of them below a document root.  An archive now counts as
  web-accessible only below a `root` or `alias` of a conf.d vhost; the rest
  are counted in one note.  Without an Angie configuration every archive is
  reported as before.  The 20-line cap now applies after the filter (it cut
  the list before, so a served archive could be hidden behind 20 private
  ones), with a "... and N more" line.  No extra tree walk.

## 1.21.52 (2026-11-21)

- **An origin behind its own reverse proxy no longer goes down when the
  catch-all refuses unknown SNI.**  server-configs-nginx 1.6.49 added
  `ssl_reject_handshake on` to `conf.d/1.https.default.conf`.  A proxy that
  connects without the site name as SNI (nginx/Angie default:
  `proxy_ssl_server_name off`) then has every handshake refused: site-d.example
  answered 502 through its front proxy 203.0.113.23 from the `--optimize`
  run until the previous Angie tree was put back (site-a.example had the same
  failure on 2026-11-20).  New `SSL_REJECT_UNKNOWN_SNI` (`auto`|`1`|`0`,
  `/etc/default/setup-tuning`, `SETUP_SSL_REJECT_UNKNOWN_SNI` for one run,
  kept across a profile reset):
  - `auto` (default) comments the directive out, with a marker and a report
    line naming the proxy, when the loaded configuration trusts or admits an
    address outside the Cloudflare ranges: `set_real_ip_from`, `allow`, a
    `$realip_remote_addr` comparison (the Pingvin template's 444 gate), a
    `# setup.sh exempt` rate-limit exemption or a
    `custom.d/https_trusted_peers.map` peer, in conf.d/http.d and every
    file they include.  Loopback, `unix:` (Anubis) and Cloudflare sources do
    not count; a CIDR counts as Cloudflare only inside a Cloudflare range.
    A Cloudflare-only host keeps the rejection.
  - `1` keeps it on (every proxy sends SNI: `proxy_ssl_server_name on;
    proxy_ssl_name $host;`), `0` turns it off, also on an operator-edited
    catch-all.
  - Not detectable: a proxy the origin configuration never mentions; use `0`.
  - Reviewed by three independent passes before the live runs; findings on
    include files, access-control gates, exemptions and CIDR breadth adopted.
- **systemd-sysctl.service no longer fails on the first boot after a
  kernel update on dracut hosts (Ubuntu 26.04).**  dracut copies
  `/etc/sysctl.conf` into the initrd, so an initrd built before an
  `--optimize` still applies the old 192/256 KB fragment limits; the base
  profile then wrote `ip6frag_low_thresh = 3145728` before the high mark and
  the kernel refused it ("Couldn't write '3145728' to
  'net/ipv6/ip6frag_low_thresh': Invalid argument", seen on 203.0.113.23;
  the 90 s re-apply fixed the values).  The base template now writes both
  high marks first, like the generated IPv4 block.

## 1.21.51 (2026-11-20)

- **The `--optimize` report no longer repeats PHP lines under the last
  section.**  The post-Angie PHP refresh re-printed every line of the PHP
  pass, including informational ones (`max_children=8 (hardware target
  ...)`), even when it changed nothing, so on 203.0.113.24 a PHP line
  appeared under `## Elasticsearch`.  A clean refresh now prints nothing;
  one that changes the ini reports under its own `## PHP X.Y (post-Angie
  refresh)` heading, as before followed by a reload.
- Live run on 203.0.113.24 (Ubuntu 24.04.5, `--optimize mitigations=off`
  with 1.21.50, then a reboot): exit 0, 0 warnings, the MariaDB buffer pool
  lowered online 4011 -> 128 MB (62 MB of data), PHP-FPM `KillSignal=SIGQUIT`,
  `kernel.sysrq` 0 and `mitigations=off` in force after the boot, every site
  and WebSocket endpoint answering as before.

## 1.21.50 (2026-11-20)

Audit cycle on the Xeon E-2236 host; report in
`tests/stress-site/AUDIT-20261120-1.21.50.md`.

- **certbot is retired on fleet hosts again.**  The 1.21.48 consumer scan
  greps `/root`, where `tools/fleet-update.sh` keeps this project's checkout,
  its dated previous checkout and its run logs; `lib/web.sh`, the changelog
  and every "certbot: kept ..." report line quote `/etc/letsencrypt`, so the
  scan always found the project itself and certbot was never purged.  The
  scan now skips copies of this project (`setup.sh` next to `lib/web.sh`),
  Angie configuration trees outside `/etc/angie` (`angie.conf` next to
  `conf.d/templates`: a `server-configs-nginx` checkout; the loaded
  configuration is still read through `angie -T`) and `*.log` files.
  Verified live: certbot purged with both checkouts and a report log under
  `/root`.
- **A full `volatile-*` Valkey/Redis cache no longer grows 20% per run.**
  Since 1.21.49 such caches followed their data, but a TTL-heavy
  `volatile-lru` cache fills its maxmemory like an LRU cache, so every
  `--optimize` raised it (512 -> 614 -> 736 ... up to the service budget).
  A `volatile-*` cache that has evicted keys since it started
  (`evicted_keys` > 0) now keeps its size like an `allkeys-*` one; one that
  has evicted nothing still follows its data.
- **PHP-FPM restarts no longer log MariaDB warnings.**  systemd stopped
  php-fpm with SIGTERM, killing workers that held persistent connections
  (XenForo's `p:localhost`): 12-13 `Aborted connection ... (Got an error
  reading communication packets)` warnings per restart.  The unit drop-in
  now sets `KillSignal=SIGQUIT` (graceful; `TimeoutStopSec=15` still bounds
  a stuck worker): 0 warnings, same 244 ms restart.  The first run after
  upgrading rewrites the drop-in (applies at the next PHP restart).
- Cloudflare TLS move: server names are split with `read -ra`, so a
  wildcard name is never glob-expanded against files in the current
  directory.
- Measured, no change: the shipped OPcache JIT profile (tracing, 64 MB)
  is best or tied on every PHP tier (`function` +5-9 % XenForo, up to -18 %
  WordPress; `off` -9-17 % WordPress); PHP 8.6 still lacks
  redis/igbinary/imagick in Sury, so 8.5 stays the newest version all three
  applications run on (0 deprecations on 8.5 and 8.4).

## 1.21.49 (2026-11-20)

- **MariaDB, Valkey and Elasticsearch are sized from their existing data,
  in both directions** (operator decision), so no service books RAM its data
  does not use.  On 203.0.113.24 the buffer pool was 4011 MB for 62 MB of
  data: the old only-increase rule had kept the installer's pool forever.
  - MariaDB: `innodb_buffer_pool_size` = data+index +5% (128 MB minimum,
    caps unchanged).  The only-increase rule is gone: a live pool more than
    one 5% step plus one InnoDB chunk (128 MB, or the live chunk size)
    above the target is shrunk to it online (`SET GLOBAL`); a pool inside
    that band is kept, so a few MB of growth does not resize it every run.
  - Valkey/Redis: `maxmemory` = data +20% (128 MB minimum).  A larger
    maxmemory shrinks online (`CONFIG SET`); one kept between data+10% and
    10% above the target is not rewritten.  The RAM/64 floor (128 MB..1 GB)
    applies only when no maxmemory is in force and the cache cannot be
    measured or started less than a day ago.  An explicit `--valkey ram=`
    is still written verbatim.  Details per eviction policy below.
  - Elasticsearch: the page-cache reservation for the index, and the
    preload switch-on threshold (and its warning), are the store +5% (was
    +10%).  The heap stays at store/4.
- Safeguards found in review:
  - `innodb_log_buffer_size` (not dynamic) no longer drops with a small
    pool; the redo log is lifted to it instead, so a 4 GB -> 128 MB shrink
    is an online resize, not a restart with the web tiers paused.  A pool
    clamped to the RAM cap gets no keep band.
  - An installer re-run measures an installed MariaDB like `--optimize`
    (an empty database: 128 MB on both, not RAM/16 on one), so the two
    paths no longer undo each other.
  - MariaDB 10.11.12+/11.4.6+/11.8 cap online growth at the pool the server
    started with, so after any restart of a pool sized to data+5% the next
    growth step fell back to a full restart.  The drop-in now writes
    `loose-innodb_buffer_pool_size_max` = 80% of RAM (address space only;
    `loose-` so older releases ignore it).  Adding it never forces a
    restart: it applies at the next natural one.  Checked on MariaDB
    11.8.6: 1 GB -> 128 MB shrink and redo-log resize online, then 128 MB
    -> 1 GB online after a restart; without the ceiling the grow is
    silently clamped at 128 MB.
  - The pool is set once per online resize (a second identical `SET`
    while 10.11/11.4 still resize in the background is rejected and turned
    the resize into a restart).  The keep band allows for the live
    `innodb_buffer_pool_chunk_size` (older 10.11 autosizes it to pool/64).
  - Valkey data is the larger of `used_memory` and `used_memory_peak`
    since start, so a quiet-hour sample never cuts a cache below its
    busy-hour need; a cache started less than a day ago, or stopped, never
    shrinks (a cold or compressed-snapshot reading).  An `allkeys-*` cache
    that fills 83-102% of its maxmemory keeps it: an LRU cache fills any
    size, so raising it on each run would ratchet without end.
    `noeviction` and `volatile-*` caches (keys without a TTL cannot be
    evicted) follow their data +20% both ways, a full one included.
  - `--diagnostics` warns only when the data is larger than the pool (the
    80% threshold fired on every pool sized to data+5%).
  - The report names each shrink ("Buffer pool lowered from ...",
    "maxmemory lowered from ...").
  - Upgrading: hosts whose redo log buffer was capped by a small pool get
    one MariaDB restart on the first 1.21.49 run (the buffer is not
    dynamic); on 10.6 (Ubuntu 22.04) a redo-log resize is not online, so a
    pool resize there restarts as before.

## 1.21.48 (2026-11-20)

- **Cloudflare-proxied sites use the host's self-signed certificate;
  certbot is retired when nothing needs it** (operator decision: every
  Cloudflare zone runs SSL mode "Full").  On the 203.0.113.24 host
  certbot's renewals had failed since September (`authenticator = nginx`,
  no nginx plugin on Angie) and the origin served expired certificates.
  `--optimize` now:
  - moves a server block to `/etc/angie/ssl/default` only when it sets its
    own certbot `ssl_certificate` and `ssl_certificate_key` and every name it
    serves is an exact host name resolving solely to Cloudflare (ranges from
    `http.d/cloudflare.conf`, IPv4 and IPv6); wildcard, regex and `.suffix`
    names keep the block, since a proxied wildcard proves nothing about
    grey-cloud records below it.  Only the two paths change (whole-word
    matches: `proxy_ssl_*` are never touched); certbot's options include,
    dhparam and trusted chain go;
  - proves each moved name after the reload: a probe location added to the
    block (`/.setup-cf-tls-probe-<digits>`, 204, digits echoed in
    `X-Setup-CF-Probe`; checked on Angie 1.12.4, non-digit/CRLF input falls
    through to a 403) must echo a fresh nonce through Cloudflare.  Only a
    worker started after the reload has that location, and it does the TLS
    handshake of its own connection, so a cached answer, a challenge/WAF
    response, a redirect, an old worker or a 526 is no proof; the vhost is
    then put back byte for byte under a `# setup-cf-tls: keep` first line
    that later runs respect.  Runs only when Angie is active and the run is
    healthy, so a rewrite never goes live unchecked;
  - purges certbot only when `angie -T` succeeds and neither the loaded
    configuration nor any renewal hook, container mount, symlink or
    non-comment `/etc/letsencrypt/` reference (dhparam counts) under `/etc`,
    `/opt`, `/srv`, `/usr/local`, `/root`, `/home`, the crontabs or the web
    roots' app configs uses it (AppArmor rules, node_modules, .git and
    vendor skipped; one filesystem, files up to 1 MB, first hit stops the
    scan).  `/etc/letsencrypt` moves to `/var/backups/setup-letsencrypt-*`
    (0700, survives reboots) and returns if apt fails.  A kept certbot whose
    renewals use the missing nginx plugin is a warning with the end date.
  - skips hosts where Anubis manages the vhosts (its terminators are
    regenerated each run and its one-time vhost copies still name certbot;
    the setup.sh state tree is scanned as a consumer as well), generated
    `00-anubis-*` files, blocks with directives on the `server {` line and
    blocks that already carry a probe; a running Docker daemon that does
    not answer within 20 s keeps certbot; a bare `/etc/letsencrypt` (bind
    mount, `LE_DIR=`) counts as a reference;
  - `SETUP_CF_SELF_SIGNED=0` (persisted as `CF_SELF_SIGNED`) skips it all;
    the dry run, gated on a running Angie like the real run, lists the
    planned moves and tells the truth about certbot (the rewrite is
    simulated on a copy).
- **The whole Elasticsearch index stays in RAM.**  The memory plan reserves
  the index store (+10% growth) as page cache, taking only from PHP's share
  beyond the RAM already free outside the service budget, and writes
  `index.store.preload: ["*"]` (static; applies at the next start) when it
  fits.  Hysteresis: on needs the growth room, staying on only the index
  itself; PHP is counted at its 64 MB-per-worker floor there, so a warm or
  cold pool does not flip the setting (an Elasticsearch restart).  Below
  4 GB only the direct-memory credit in use is subtracted; an explicit
  `--php children=` pool is never shrunk for the index nor undercounted.
  A preload kept on only by the band is reported as a warning (no growth
  room left).  An operator's own preload line is commented out only when
  ours replaces it.  On the
  203.0.113.24 host: 7166 MB index, 49582 MB free, preload on.
- Same host, by hand (operator request): the two red system data streams
  (`ilm-history-7`, `.logs-deprecation.elasticsearch-default`, no copy
  left) were deleted, replicas set to 0 (green), and the operator
  `jvm.options` (8 GB heap) removed in favour of the managed 2 GB.
- Three adversarial review rounds: 32 distinct defects confirmed and fixed
  before release (among them the edge-response and reload-race holes in the
  first proof design, a cert/key mismatch on one-line directives, the
  Anubis interactions and an unanchored removal that cut
  `proxy_ssl_trusted_certificate`).  The tests caught two more on the way:
  CRLF in curl's status line and `awk -v` eating the probe's backslash.
  1266 + 224 checks; ShellCheck clean.

## 1.21.47 (2026-11-20)

- **A red Elasticsearch cluster now names its cause.**  On a live OVH host
  (Xeon E5-1630 v4, Ubuntu 24.04, four XenForo search indices) the report
  said only `Cluster health: red (not a single-node replica issue; left
  unchanged)`.  The red came from two 2024 system data streams
  (`.ds-ilm-history-7-*`, `.ds-.logs-deprecation.*`) whose primaries had no
  copy left, while every application index was usable.  The line now lists
  the indices with an unassigned primary (first five, then a count), points
  at `GET _cluster/allocation/explain`, and still changes nothing.  Five
  unit checks.
- Same host, outside the script: certbot renewals had failed since
  September (`authenticator = nginx` with no nginx plugin on an Angie host)
  and the origin served an expired certificate.  The sites are behind
  Cloudflare in Full (not strict) mode, so the vhosts now include
  `h5bp/hostname_ssl.conf` (the host's self-signed certificate) and certbot
  was purged; responses were identical at the origin and through
  Cloudflare before and after the reboot.

## 1.21.46 (2026-11-20)

- **One WordPress/XenForo config scan per `--optimize` run.**  The JF dev
  host (XenForo, 3.7M entries within depth 6 of /var/www) still paused
  57 s between the sysctl and cron steps after 1.21.45: every app finder
  (`app_find_wordpress_configs`, `app_find_xenforo_configs`) walked
  /var/www to depth 6 on its own, 4-5 s each, about eight times per run
  (WordPress hardening, malware roots, XenForo gzip, cron, MariaDB
  persistent-connection count, application notices).  `--optimize` now
  primes one combined walk right after service detection
  (`app_config_scan_prime`) and the finders read that list; the dry run
  (which makes no such walk) and the install path (which adds sites while
  it runs) do not prime it.  The walk honours `SETUP_WWW_ROOT`.  Ten unit
  checks.
- `mitigations=on|off` is accepted after any flag (`--optimize --dry-run
  mitigations=off` was rejected as an unknown argument); it still needs
  `--basic` or `--optimize`.  Five dry-run matrix cases.
- The MariaDB report line no longer calls the capped target "data+5%": it
  now prints `target 64388MB (data+5% = 77586MB, 128MB minimum, cap
  64388MB)`, and the dry-run line names both caps (50% beside PHP/cache/
  search, 80% on a database-only host).
- Live run on the JF dev host (Hetzner, EPYC 7401P, 48 threads, 126 GB,
  Ubuntu 26.04, PHP 8.6): optimize clean, `enableGzip` line superseded,
  Hetzner `hetzner.cfg` no longer drops `mitigations=off` after reboot,
  ipfrag/rp_filter/BBR/hugepages applied at boot, no failed units.

## 1.21.45 (2026-11-20)

- **Security hardening no longer walks a large web root eight times.**  On
  the JamiiForums host (XenForo, no WordPress, 7.7M files / 1.3 TB under
  /var/www) `--optimize` paused silently for 95 seconds: the generic
  hygiene checks walked the whole tree five times (world-writable files,
  then directories, each counted and then fixed, plus the large-archive
  search), and the WordPress webshell scan walked it twice more and grepped
  every `*.php` file, even with no WordPress installed.
  - `harden_wordpress_files` does one walk: GNU find's `,` operator writes
    world-writable entries and large archives to separate NUL lists
    (`-fprint0`), the world-writable fix is a batched `xargs -0 chmod`, and
    `SETUP_WWW_ROOT` lets the tests use a fixture tree.
  - `scan_wordpress_malware` walks only WordPress roots (the directory of
    each wp-config.php), with one combined find; with no WordPress it is
    skipped and says so.  A same-named file in a XenForo tree beside a
    WordPress site is no longer a candidate.
  - Measured on 500,000 files without WordPress (warm caches): 3.02 s ->
    1.09 s; the malware scan 1.70 s -> 0.00 s.  Nine unit checks (one walk,
    counts, archive list, mysql_database exclusion, skip, WordPress-only
    removal, outside-root safety).

## 1.21.44 (2026-11-20)

From `--optimize mitigations=off` on a Hetzner bare-metal host (Xeon
E-2276G, Ubuntu 24.04.5, six WordPress sites, Polr, Elasticsearch serving a
remote XenForo).

- **`mitigations=off` is no longer silently lost on Hetzner (and similar)
  hosts.**  The drop-in was `/etc/default/grub.d/99-setup-mitigations.cfg`.
  grub-mkconfig sources `grub.d/*.cfg` in glob order, where letters sort
  after digits, so Hetzner's `hetzner.cfg` ran after it and its plain
  `GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0"` erased `mitigations=off`.
  The run still reported "off at the next reboot".  The drop-in is now
  `zz-setup-mitigations.cfg` (sorted after `hetzner.cfg`, `init-select.cfg`
  and `50-cloudimg-settings.cfg` in the C and UTF-8 collations); the old file
  is removed and the menu regenerated.  After `update-grub` the generated
  boot menu is checked: when it still lacks the option, the run warns and
  names the drop-in that assigns `GRUB_CMDLINE_LINUX_DEFAULT` after ours
  instead of claiming a reboot will apply it.  `--purge basic` removes both
  names.  Six unit checks.
- **Elasticsearch on a public address behind UFW is no longer a double false
  warning.**  The security audit and the Elasticsearch section both warned
  "restrict TCP 9200/9300 to the remote client(s)" on a host whose UFW
  already admitted only the remote XenForo server.  `es_ufw_exposure` parses
  `ufw status verbose` (active, incoming denied, sources admitted to
  9200/9300 including "Anywhere" all-port rules and port ranges): restricted
  hosts get a note naming the sources, an open or unverifiable firewall gets
  one warning, and the Elasticsearch section prints a status line only.
  Eight unit checks.
- **Superseded legacy `http.d/zz-setup-*_conf` files are retired.**  An old
  release generated `zz-setup-wordpress-cache_conf` (inactive: only `*.conf`
  is included); its zone and map moved into loaded files, so `--optimize`
  reported it as "not included" on every run with advice to re-run the
  deployment, which changed nothing, while activating it would have broken
  `angie -t` with a duplicate `keys_zone=fastcgicache`.  The sync now moves
  such a file to /tmp when every zone and map variable it defines is already
  defined by a loaded file (operator files and files with unique zones are
  kept), and the remaining "not included" advice says to rename only when
  nothing loaded defines the same names.  Five unit checks.

## 1.21.43 (2026-11-20)

- **The stale ACME client is retired before the sync tests the tree.**  On
  the live host the 1.21.42 run retired `http.d/letsencrypt.conf`, but
  `deploy_angie_tree` runs a visible `angie -t` before the tuning pass, so
  that same run still printed "ACME client "letsencrypt" is defined but not
  used" once.  The sync now calls `tune_retire_unused_acme_client` before its
  test (the tuner call stays as a no-op) and logs the move as info.  One
  unit check.
- Verified on the 128 GB live host: `/etc/sysctl.conf` now writes
  `ipfrag_high_thresh` before `ipfrag_low_thresh` and replays cleanly from
  the kernel defaults, `angie -t` is clean after the retirement, and the
  foreign-sysctl note lists only the intentional `kernel.sysrq` difference.
  Hosts with more than 64 GB of RAM need one `--optimize` with 1.21.42+
  before their next reboot to rewrite the old low-first order.

## 1.21.42 (2026-11-20)

From `--optimize mitigations=off` plus a reboot on a fourth live host
(2x AMD EPYC 7313, 64 threads, 128 GB, md RAID, Ubuntu 24.04.5, XenForo on
PHP 8.0): the run, the reboot and the site were clean apart from these.

- **`systemd-sysctl.service` no longer fails at boot on large hosts.**  The
  RAM-sized IP fragment pair was written low mark first.  At boot the kernel
  starts from its defaults (3 MB / 4 MB) and requires low <= high at every
  write, so on a host where the pair scales above the defaults (128 GB:
  8238208 / 6178656) `systemd-sysctl` failed with "Couldn't write '6178656'
  to 'net/ipv4/ipfrag_low_thresh': Invalid argument" on every boot;
  `setup-sysctl-final` re-applied the values later, so they were right but
  the unit stayed failed.  The 62 GB audit host lands exactly on the
  defaults, which is why no audit saw it.  `ipfrag_sysctl_lines` now writes
  the high mark first (the profile never goes below the defaults, so boot is
  always upward; a downward change at --optimize time is still prepared by
  the make-room step).  A boot simulation from the kernel defaults checks
  2 GB to 1 TB of RAM.
- **The stale `http.d/letsencrypt.conf` is retired.**  server-configs-nginx
  shipped it active for a few hours on 2026-07-22 before renaming it to
  `letsencrypt_conf`; the sync never removes files that left the
  repository, so hosts synced that day kept an `acme_client letsencrypt` no
  vhost uses and every `angie -t` warned "defined but not used" (two live
  hosts).  `tune_retire_unused_acme_client` moves it to /tmp only while it is
  byte-identical to the shipped `letsencrypt_conf` and no vhost has an
  `acme letsencrypt` directive, so a host using Angie ACME keeps it.
- **The dry-run sysctl preview matches the real run.**  It read "ours" from
  the current `/etc/sysctl.conf` and previewed `rp_filter(file=2 ours=1)` as
  a conflict the run resolves; it now reads the template the run installs
  (`TUNING_OURS_PROFILE`).

Also verified: `--optimize` tunes an existing PHP 8.0 pool (no install
template needed; `php-fpm -t` passed, graceful reload) and the XenForo gzip
block parses on PHP 8.0.  Not ours: `systemd-networkd-wait-online` fails
after a 2-minute timeout on every boot because netplan configures `lan0`
with no cable (mark it `optional: true`).

## 1.21.41 (2026-11-20)

From `--optimize mitigations=off` plus a reboot on a second live host (KVM
VPS, Ubuntu 24.04.5, kernel 7.0.0-43, XenForo + WordPress): the run, the
reboot and both sites were clean; two report defects are fixed.

- **No more false "foreign sysctl sources" warning on Ubuntu 24.04.**  The
  report ran in the profile reset, before `run_os_tuning` wrote this run's
  `/etc/sysctl.conf`, so a default that changed between releases showed as a
  conflict in the very run that applied it (`rp_filter(file=2 ours=1)` while
  the run wrote 2).  It also listed files whose keys all matched.  24.04
  keeps its `10-*.conf` files in `/etc/sysctl.d`, so every `--optimize` there
  raised a WARN.  `report_foreign_sysctl_sources` now runs after
  `run_os_tuning`, lists only differing keys (`tuning_override_sources
  conflicts`, also used by the dry run) and logs them as information: the
  managed profile is re-applied at boot and is the value that runs
  (`kernel.sysrq` 0 at runtime on the host).  Four unit checks.
- The CPU governor step is titled "CPU governor"; it said "(dedicated
  server)" on a VPS before reporting that it leaves the governor to the
  hypervisor.

Seen on the host and not ours: Angie's `ACME client "letsencrypt" is defined
but not used` (an operator-enabled `http.d/letsencrypt.conf`; the repository
ships it disabled as `letsencrypt_conf`), Ubuntu's `/etc/pam.d/login` loading
the absent optional `pam_lastlog.so`, GRUB's serial-console notice, and ten
`martian source` lines in the boot second before the default route existed.

## 1.21.40 (2026-11-20)

Findings from the first `--optimize mitigations=off` on a live XenForo host
(Xeon E3-1230 v6, kernel 7.0.0-44): optimize and the reboot were clean
(0 warnings, 0 failed units, mitigations off, governor/sysctl/huge pages
applied); these three items came out of the review.

- **Old XenForo `enableGzip` lines are commented out.**  Next to the managed
  `XF_MEMBER_GZIP=angie` block, an earlier `$config['enableGzip'] = false;`
  (older installs; the live host had it column-aligned) is a duplicate.
  `--optimize` now prefixes each one-statement `enableGzip` line with
  `// setup.sh superseded (enableGzip block below): `, keeping the original
  text; `XF_MEMBER_GZIP=xenforo` removes the block and un-comments the line
  byte for byte.  A line holding another statement is left alone; every
  write is still linted.  Seven unit checks (indented, double-quoted,
  trailing comment, idempotence, round trip).
- **Reverse-path filtering matches Ubuntu (loose, 2).**  The profile set
  `rp_filter = 1` for `all`/`default`, but systemd's `50-default.conf`
  sets `net.ipv4.conf.*.rp_filter = 2` on every interface and the kernel
  enforces the higher value, so every NIC already ran loose mode while the
  profile claimed strict.  Now `2`, which also stays safe with asymmetric
  routing (vRack, failover IPs, several NICs).  The drift report shows the
  provider files as `same`.  Test host: 2 on all/default/eno1/lo at runtime
  and after a reboot.
- **`/etc/hosts` keeps its line order.**  `--basic` and `--purge basic`
  deleted the `127.0.1.1` line and appended the new one, so a purge never
  restored the provider's file byte for byte (the remaining `/etc/hosts`
  delta of every audit restore).  `hosts_set_loopback_line` replaces the
  line where it stands; five unit checks.

Suites on the Xeon test host: unit 1,135/1,135 (root and non-root, PHP
installed for the XenForo checks), dry-run matrix 219/219.

## 1.21.39 (2026-11-20)

Test-suite hardening.  CI had failed on every push since 3e781fb; that was
fixed in 55586a4 (the shipped-tree checks now run against a checkout of the
pair repo, the cache-budget check uses the tuner's own basis).  A multi-agent
sweep then looked for checks whose result depends on the machine rather than
the code; seven survived adversarial verification and are fixed here.  Each
fix was proven by mutation on the Xeon host: the broken code now fails its
check, where the old check passed.

- **Four checks that could pass without testing anything:**
  `valkey_runtime_settings keeps maxmemory` ran `bash -c true` with the real
  assertion outside `check`; `valkey_maxclients grows with the PHP pool`
  used 512 children, which stays under the 10000 floor (now 3000 -> 14000,
  plus the 100000 cap); the CPU governor probes read the live `/sys`, so a
  VM only ever ran the "no interface" branch (now three fixture trees via
  `SETUP_SYS_CPUFREQ`, like `SETUP_SYS_BLOCK`); the dry-run row for
  `--php ver=8.0` passed on any host with PHP installed because "already
  installed" refused it first (new `run_msg` asserts the "No FPM pool
  template" message, with a `dpkg-query` shim that hides installed PHP).
- **Three checks that depended on the host:** unit tests no longer read the
  host's `/etc/default/setup-tuning` (a provisioned host's `STORAGE_CLASS=`
  overrode the stubbed disk classification) or a `SETUP_STORAGE_CLASS` in
  the caller's shell; `client_body_buffer_size` expects the value from the
  cgroup-capped `mem_total_mb` the tuner uses; the fastcgi `max_size` check
  accepts the `G` unit a whole-GiB budget is written with.
- **Restore residue:** `restore-baseline.sh` runs `--purge all` from its
  work directory (setup.sh writes its run log to the current directory, so
  every restore left a `setup_*.log` in the caller's home), removes
  `~/.config/procps` for every home, and the manifest lists `/home/*`.

Suites on the Xeon host: unit 1,113/1,113 (non-root, root, with operator
pins in the environment and with a `STORAGE_CLASS=hdd` pin file), dry-run
matrix 219/219 (the 220th row needs an installed PHP).

## 1.21.38 (2026-11-20)

Audit cycle on the Xeon E-2236 host (62 GB, md RAID0 NVMe).  Pair:
`server-configs-nginx` 1.6.49.  Report:
`tests/stress-site/AUDIT-20261120-1.21.38.md`.

- **XenForo passkeys work again (Angie 1.6.49).**  Since
  server-configs-nginx 1.6.35 the XenForo PHP handlers re-include
  `Permissions-Policy`, whose value carried `publickey-credentials-get=()`:
  WebAuthn was denied to the site itself and "Use passkey or security key"
  (login and two-step) did nothing.  The token is now `(self)`; a
  `--optimize` run syncs it.  The security probe checks it on all three
  applications.
- **Each security header once (Angie 1.6.49).**  XenForo
  (`X-Content-Type-Options`), WordPress (`X-Frame-Options` and
  `Referrer-Policy` on wp-login.php, `X-Content-Type-Options` on the REST
  API) and Chevereto (`Permissions-Policy: interest-cohort=()`) sent their
  own copy next to the vhost's.  The PHP handlers hide the upstream copy.
  Eight new probe checks; security probe 65/65.
- **The audit restore missed data directories.**  The previous cycle's
  "pristine" host still had `/var/lib/mariadb` (with a `chevereto`
  database), the `angie`/`mysql` accounts, `mysqlbkup` files and `/root`
  tooling, so the next install ran on an old datadir (the MariaDB postinst
  logged "mysql.user table already exists").  `host-manifest.sh` now lists
  the top level of `/root` and every service data directory, so a leftover
  shows up in the restore delta; `restore-baseline.sh` also removes
  `/root/.debug`, `/root/.config/procps`, `/var/lib/mysql-files` and the
  benchmark binaries.
- **Anubis validated-pass cache investigated and rejected.**  In proxy mode
  the 1.28.2 check endpoint is not an auth oracle (valid cookie 401,
  default-allowed client 403 because the check URI itself is proxied to the
  origin, DENY answers 200), so caching its answer would need a second
  auth-mode instance; not lean, not shipped.
- **CPU mitigations:** `mitigations=off` re-measured (+8-50 % cached, +15 %
  XenForo member and Chevereto uncached).  `init_on_alloc=0` and
  `randomize_kstack_offset=off` on top were inside noise and are not
  offered; `preempt=none` is not supported by the 7.0 kernel.
- **Zero-error cycle**: clean install 3:08 with 0 warnings, 0 journal
  warnings, 0 AppArmor denials; 1,119 unit checks, 220 dry runs; security
  65/65, cookie 62/62, functional 0 unexpected with Anubis on and off; PHP
  8.5 diagnostics 0 in all three applications; `--optimize` idempotent
  (3,042 facts).

## 1.21.37 (2026-11-20)

Audit cycle on a freshly reinstalled Xeon E-2236 host (62 GB, md RAID0
NVMe, 695-package baseline).  Pair: `server-configs-nginx` 1.6.48 (no
changes).  Report: `tests/stress-site/AUDIT-20261120-1.21.37.md`.

- **Anubis no longer leaves the sites on a dead socket when its state is
  missing.**  `anubis=no` restored the vhosts from
  `$STATE_DIR/anubis/vhosts/*.orig` and recognized "managed" only by the
  marker inside that same directory.  An operator who moved or deleted the
  directory lost both: the disable did nothing, and once the filter stopped
  every vhost kept listening on
  `unix:/run/angie/anubis-backend.sock` and answered 502.  The integration
  is now also detected from this module's own terminators/snippets/static
  shadow and from any vhost still on the backend socket
  (`anubis_artifacts_present`), and a vhost without an `.orig` copy is
  rebuilt in place from the integrated form
  (`anubis_deintegrate_vhost`: two public `listen 443 ssl`, `http2 on`, the
  proxy real-IP lines removed, everything else kept).  A restore that cannot
  rebuild a vhost returns non-zero, `anubis_disable` keeps the filter
  running and the run reports the failure instead of a false success.  Test
  host: enabled, state directory moved away, `--optimize anubis=no` rebuilt
  three vhosts, `angie -t` clean, service stopped, HTTP 200.  Thirteen unit
  checks added (1,119 total).
- **Anubis cost measured and its runtime re-checked.**  With a valid
  challenge cookie and a browser user agent, the cached XenForo home page
  does 27.7k req/s through the filter and 80.5k without it (94 % host CPU at
  the filter's ~5.2 cores): the filter is CPU-bound, and `c=400` does not
  raise the number.  `GOGC=100/400/800/off` on the check endpoint measured
  66.5k/73.0k/74.5k/74.7k, so the shipped `GOGC=off GOMEMLIMIT=2048MiB`
  is at the ceiling (8 GiB only inflates RSS to 7.9 GB).  Subrequest-auth
  mode (Anubis `TARGET=" "` + `auth_request`) was prototyped: 19.8k without
  upstream keepalive, 28.5k with it — no win over the 27.7-28.5k proxy
  mode — so the architecture stays.  The prototype also showed that the
  challenge location needs `^~` (the application's dotfile deny regex
  answers 403 otherwise).
- **Remaining Angie/PHP knobs re-measured and rejected** (details and
  numbers in the report): removing `worker_cpu_affinity auto` +
  `timer_resolution 100ms` (-5-8 %), `ssl_buffer_size 4k` (0 to -8 %),
  `multi_accept off` (0 to -8 %), dropping `aio threads`/`directio`
  (-6-7 %), `opcache.validate_timestamps=0` (inside run-to-run noise) and
  `pm.max_children` 16/24 (no gain over 12).  The shipped values stay.
- **Zero-error cycle on the clean host**: install 2:20 with 0 warnings,
  1,119 unit checks, 220 dry runs, security 54/54 and cookie 62/62 and the
  functional exercise with 0 unexpected responses, each with Anubis off and
  on, and `--optimize` idempotent (0 differences).

## 1.21.36 (2026-11-20)

Performance cycle on the Xeon E-2236 host.  Pair: `server-configs-nginx`
1.6.48.  Report: `tests/stress-site/AUDIT-20261120-1.21.36.md`.

- **CPU vulnerability mitigations can be switched off.**  `--basic
  mitigations=off`, `--optimize mitigations=off` or
  `SETUP_CPU_MITIGATIONS=off` add `mitigations=off` to the kernel command
  line through a managed `/etc/default/grub.d/99-setup-mitigations.cfg`
  (the provider's own options are kept), run `update-grub` and persist
  `CPU_MITIGATIONS=off` in `/etc/default/setup-tuning`, so every later
  `--optimize` keeps it; `mitigations=on` removes the drop-in and
  `--purge basic` does too.  It applies at the next reboot (the run says
  so); containers and non-GRUB boot loaders are reported, not touched; a
  host where nobody chose is never touched.  Measured after fresh boots on
  the Xeon E-2236 (PTI + IBRS + MDS): guest-cache hits +19% (XenForo),
  +25% (WordPress), +14% (Chevereto); PHP tiers +5-7%.  It weakens the
  isolation between local processes; for a single-administrator,
  key-only, CDN-fronted host the operator accepts that.  `--diagnostics`
  shows the command line and every vulnerability state.
- **XenForo: members' pages are compressed by Angie, guests' by
  XenForo.**  XenForo gzips every page at level 9 (15% of member-page PHP
  CPU).  A managed block at the end of each XenForo `src/config.php` sets
  `$config['enableGzip'] = !isset($_COOKIE[<prefix>session])`: the guest
  cache still stores XenForo's compressed body (a hit costs no
  compression), and session visitors get plain HTML that Angie compresses
  at level 4.  Measured: member thread +4% (344/348 -> 360/360 req/s),
  guest cache unchanged; turning XenForo's gzip off for everyone instead
  dropped guest-cache hits from 104k to 6.8k req/s.  The block wins over
  an operator's own `enableGzip` line (left in place), honours a custom
  cookie prefix, is linted before it is written, and
  `SETUP_XF_MEMBER_GZIP=xenforo` removes it again (persisted as
  `XF_MEMBER_GZIP`).
- **Existing vhosts move onto the lean location chain**
  (`tune_vhost_lean_locations`, server-configs-nginx 1.6.48).  A vhost that
  includes its application's PHP file at server level gets the header-only
  `basic*_headers.conf` (the deny regex lives in that PHP include now); the
  XenForo template's `admin.php|install` block, the Chevereto template's
  app/importing/composer lines, `dashboard|update` and
  `CHEVERETO_LICENSE_KEY` blocks are folded, and Chevereto's `/images/`
  nested denies become one allowlist regex -- each only in its shipped
  shape.  A vhost with a nested or rewritten PHP include keeps the full
  `basic*.conf` set and is reported; an active `auth_basic` block or an
  edited `/images/` block is kept.  The test host's four vhosts converted
  with `angie -t` passing, 54/54 security probes, 62/62 cookie checks and
  0 functional regressions; guest-cache hits +3 % (XenForo), ~+1.5-3.5 %
  (WordPress, Chevereto) on top of the lean maps.
- **PHP 8.6.0 is not production-ready for this stack yet.**  Sury
  publishes 8.6.0 itself, but not `php8.6-redis`, `-igbinary`, `-imagick`,
  `-apcu` or `-msgpack`, and the PECL sources do not compile against 8.6.0
  (removed `XtOffsetOf`, `INI_INT`/`INI_STR`, `zval_dtor`; changed
  `php_error_docref` types).  `--upgrade-php=8.6` therefore refuses before
  purging and names the affected sites (Chevereto: redis, imagick;
  XenForo: redis).  Tested anyway with `SETUP_PHP_ALLOW_MISSING_EXT=1`:
  WordPress 7.1.4 clean; XenForo 2.3.13 core clean in production mode only
  with its Redis cache off (debug mode: the same two POST 500s as on 8.5);
  Chevereto 4.5.9 cannot run (Imagick).  The run back to 8.5 is blocked by
  the collateral-removal guard while test-only `php8.6-dev` is installed --
  the guard working as intended.
- Tests: GRUB drop-in text and idempotency, CLI validation (8 dry-run
  cases), the XenForo block (parse, guests vs members, custom prefix,
  `?>` endings, byte-for-byte removal, unparsable files left alone), the
  vhost migration (template shapes, one-line blocks, auth_basic kept, nested
  include kept and reported, /images/ fold scoped and shape-checked,
  idempotent), update-grub retry and failure, `?>` after code, a block
  without its END marker.  An adversarial review confirmed 16 findings in
  the new code; all are fixed (see the cycle report).

## 1.21.35 (2026-11-19)

The open item from the 1.21.34 audit: the memory plan books Elasticsearch
direct memory and the OPcache huge pages.  Designed by a three-way panel
(book / cap / headroom-first), judged on arithmetic, parity and operational
risk, then reviewed adversarially; verified on the Xeon E-2236 host.

- **Elasticsearch direct (off-heap) memory is booked.**  The plan booked
  only `-Xmx`, but Elasticsearch sets `-XX:MaxDirectMemorySize` to heap/2
  when nobody else does (confirmed on the host: `MaxDirectMemorySize=
  268435456` beside `-Xmx512m`), so a node could use ~1.5x its booking.
  The plan now books that ceiling, or an operator value from
  `/etc/elasticsearch/jvm.options` or `jvm.options.d` (decimal sizes, JDK
  version prefixes honoured against the bundled JDK).  Nothing is written
  to the JVM options, so no Elasticsearch restarts on upgrade.  Below 4 GB
  part of the ceiling is credited against the OS headroom above 10%: a
  2 GB all-in-one with a 1 GB database gets a 692 MB pool instead of 742
  (486 without the credit), and a 1.5 GB all-in-one still fits.
- **OPcache huge pages are booked.**  `vm.nr_hugepages` (296 pages = 592 MB
  on 8 GB+ hosts with PHP) is pinned inside MemTotal and missing from the
  worker RSS the PHP allowance measures.  It now comes off the services'
  share through `hugepages_reserved_mb`, which uses the same formula and
  the same PHP predicate as `configure_sysctl` (`hugepages_php_present`);
  0 in a container.  The budget figure, the Valkey cap and the
  only-increase rules keep the plain 80%.
- **A kept MariaDB pool that no longer fits settles in one run.**  It gives
  up its surplus over the data target before the split (never below the
  256 MB floor), instead of 5000 -> 3533 -> 3260 over two restarts.
- **Effect on existing hosts:** none where the plan fits (the audit host:
  identical files, no restarts; install -> `--optimize` and `--optimize` x2
  0 differences).  Hosts that were silently over-subscribed are re-split
  once: an 8 GB PHP + MariaDB (4 GB data) + Elasticsearch (8 GB index) host
  moves from MariaDB 4096 + heap 2048 (a true ~7.9 GB against 6.5 GB) to
  3260 + 1536.  Explicit sizes that crowd out the direct share now report
  the overcommit (20000 + 4096 MB on 32 GB: about 186 MB).
- The memory summary (install, `--optimize`, dry run) appends
  `ES-direct=NMB` and `HugePages=NMB` when non-zero; the Elasticsearch
  report names the off-heap ceiling and where it comes from.
- Tests: 1,067 checks (helpers, small-host credit, install/`--optimize`
  parity at 1, 1.5, 2 and 27 GB, the kept-pool trim, operator values);
  a mutation of the 256 MB trim floor is caught.

## 1.21.34 (2026-11-19)

Second audit cycle on the Xeon E-2236 / md RAID0 host (Ubuntu 26.04.1,
705-package baseline).  Pair: `server-configs-nginx` 1.6.47.  Report:
`tests/stress-site/AUDIT-20261119-1.21.34.md`.

- **Anubis: two challenge bypasses closed.**  A static-looking path that is
  not a file (the static shadow answers 404) went back into Anubis, where
  the `static-assets` rule ALLOWed it on its extension, and on to PHP:
  `GET /x.css?rest_route=/wp/v2/users` returned the WordPress REST API to a
  browser with no challenge.  The terminator now tags that fallback
  (`X-Anubis-Static-Miss`) and a `static-miss` policy rule challenges
  browsers there; non-browser clients still get the plain 404.  The
  `/socket/` route is generated only for vhosts that have a `/socket/`
  location and passes only WebSocket upgrades straight to the backend;
  anything else under `/socket/` is filtered like a page (WordPress served
  `/socket/?rest_route=` from `index.php`).
- **Anubis: the XenForo WebSocket route answered 400.**  It included
  `h5bp/proxy_ws.conf` and then set Host, X-Real-IP, X-Forwarded-For and
  X-Forwarded-Proto again; Angie sends both, and the backend rejected the
  duplicate Host on every handshake.  The route now sets each header once.
- **Anubis: `REDIRECT_DOMAINS` is set** to the server names of the sites
  behind the filter.  Without it the post-challenge redirect went to any
  domain (`?redir=https://evil.example/` was followed) and Anubis warned
  at every start.  A regex `server_name` leaves the variable out.
- **`--upgrade-php` keeps the www pool's listener.**  The new `www.conf`
  comes from the template, so an adopted host whose pool listened on
  `/run/php/php8.4-fpm.sock` moved to `/run/php/php-fpm.sock` and Angie
  answered 502 while the upgrade reported success.  The old listener is
  passed to the tuner, as for the extra pools.
- **`--upgrade-php` reports optional packages that failed to install.**
  `install_php` runs in `run_service`'s subshell, so its failures never
  reached `PHP_UPGRADE_SKIPPED`; the pending list was deleted and the
  summary said "skipped 0".  They now come back through
  `${STATE_DIR}/php-optional-failed`.
- **MariaDB: an online buffer-pool resize no longer forces a restart.**
  `innodb_log_buffer_size` (not dynamic) was pool/16, so growing a
  256 MB-1 GB pool changed it and `--optimize` restarted MariaDB with the
  web tier paused.  It is now RAM/256 (16-64 MB), capped at the redo log.
- **Angie cache budget no longer moves with the install.**  The disk cap
  was 5% of *free* space, measured before PHP, MariaDB and Elasticsearch
  took ~2 GB; on small disks the first `--optimize` rewrote every
  `max_size`/`keys_zone`.  The basis is now the filesystem size, capped at
  half of what is free.
- **IP fragment reassembly is never below the kernel default.**  IPv4 was
  RAM x 32 clamped to 256 KB-4 MB (2 MB on a 62 GB host) and the base
  profile set IPv6 to 256 KB, the obsolete CVE-2018-5391 workaround; large
  fragmented UDP/IPv6 packets were dropped.  IPv4 is now 4-16 MB, IPv6 the
  kernel's 4 MB/3 MB; the live pair is pre-adjusted and restored
  high-before-low for both families.
- **Zero-warning install:** a managed `/etc/apparmor.d/local/who` block
  (`abstractions/nameservice-strict`) stops the 95 AppArmor `DENIED` lines
  needrestart's `who` call logged per install on Ubuntu 26.04; it is
  written before the first apt run, kept by `--optimize` and removed by
  `--purge basic`.  The public-80/443 advisory is a note, not a `[WARN]`
  (the firewall opens them on purpose).
- **Refactor:** `apparmor_local_set`/`apparmor_local_clear`
  (`lib/util.sh`) manage marker blocks in `/etc/apparmor.d/local/*` for
  MariaDB and `who`; the duplicated awk in `services.sh` and `purge.sh` is
  gone.  `state-snapshot.sh` covers `/etc/apparmor.d/local`.
- Tests: `seed-xf.sh` opts the forum into Hampel Seeder 1.0.0b11 (which now
  refuses to run without `$config['hampelSeeder']['enabled']`) and removes
  the flag afterwards.

## 1.21.33 (2026-11-19)

Audit cycle on a new hardware class: bare-metal Intel Xeon E-2236 (6C/12T,
Coffee Lake), 62 GB RAM, root on md RAID0 over two Samsung PM983 NVMe, BMC
virtual floppy/CD-ROM devices, public IPv4/IPv6, Ubuntu 26.04.1 (705-package
baseline).  Pair: `server-configs-nginx` 1.6.46.  Report:
`tests/stress-site/AUDIT-20261119-1.21.33.md`.

- **`--basic` restarts upgraded daemons after the upgrade, not from the APT
  hook.**  When the upgrade batch contains systemd, its trigger re-executes
  PID 1 and needrestart's immediate `systemctl restart chrony ssh journald
  resolved …` failed as a whole ("Failed to connect to system scope bus via
  local transport"), leaving 16 services on the old libc.  The hook is
  suspended (`NEEDRESTART_SUSPEND=1`) and `needrestart -r a` runs once
  `systemctl` answers again (`restart_outdated_services`).
- **`--upgrade-php` no longer loses an extension to systemd's start limit.**
  Every extension package restarts `phpX.Y-fpm` from its trigger; one apt
  transaction per optional extension plus the upgrade's own start/stop hit
  `start-limit-hit`, the fpm postinst failed and apt rolled back
  `php8.4-imagick` (a Chevereto hard requirement) with only a warning.  The
  optional set is now installed in one transaction (one restart); the
  per-package fallback clears the start limit and finishes half-configured
  packages first.  8.5 → 8.4 → 8.5 now completes with zero warnings and
  imagick/redis/igbinary loaded on both.
- **md/dm arrays on flash get the profile readahead.**  The udev rules
  skipped stacked devices, but the filesystem reads through the array's own
  bdi, which the kernel sizes from the stripe: md3 (RAID0, 2 × 512K) kept
  2048 kB instead of the 128 kB the NVMe profile intends.  A readahead-only
  rule now covers `md*|dm-*` on nvme/ssd hosts; HDD arrays keep the
  stripe-derived value.
- **Storage classification sees every RAID member.**  `lsblk -s` tree output
  put nested members on lines like `│ └─nvme0n1 disk` (three awk fields), so
  only the last member was classified; list output (`-l`) is used now.
- **The udev re-trigger is limited to the devices the rules match**
  (non-empty whole disks by name).  The blanket trigger replayed the BMC's
  empty virtual floppies and CD-ROM through sg3-utils-udev, which logged
  "SCSI device sdX has no device ID" five times per `--optimize`.
- **Anubis Unix listeners use the somaxconn backlog.**  The backend and
  static-shadow sockets kept the 511 default while every TCP listener is
  sized to somaxconn; a full Unix-socket backlog refuses with EAGAIN instead
  of queueing.  A catch-all `default_server` on the backend socket in
  `00-anubis-common.conf` carries `backlog=` and answers 444 for an unknown
  Host; the terminator and the static fast path no longer spool large
  responses to `proxy_temp` (`proxy_max_temp_file_size 0`).
- **`opcache.max_accelerated_files` is written as the prime OPcache rounds it
  to** (32531/65407/130987).  The exact file count changed whenever XenForo
  compiled templates or an add-on was installed, so a second `--optimize`
  rewrote the ini and reloaded PHP-FPM (resetting OPcache) for an identical
  hash table.
- **Flarum guest cache works again on hosts deployed with
  server-configs-nginx 1.6.43–1.6.45**: `tune_flarum_cache_gate` rewrites the
  joined-variable `if ($flarum_guest_cacheable$req_encoded_path)` (which made
  `angie -t` fail for every Flarum vhost) into one map variable and adds
  `fastcgi_cache_background_update`.
- **The catch-all TLS server refuses unknown/missing SNI** on existing hosts
  too (`tune_default_tls_reject` inserts `ssl_reject_handshake on;`): the
  self-signed default certificate's CN/SAN is `hostname -f`, which tied a
  CDN-fronted origin IP to its name for any scanner.  Verified: no-SNI and
  bogus-SNI handshakes end with `unrecognized_name`, vhost sessions are still
  resumed.
- **Ubuntu 26.04 AppArmor: MariaDB starts without denials.**  MariaDB 11.8
  reads `/sys/devices/.../dev` for every disk at startup (SSD detection) and
  the new stock `mariadbd` profile denied it (21 `DENIED` lines per install
  on this host, NVMe paths included).  The managed `local/mariadbd` block
  allows these read-only `major:minor` files.  The 94 `who` denials during an
  install come from needrestart running `who` under Ubuntu's own `who`
  profile (it lacks the nameservice abstraction) and are left to the
  distribution.
- **`--purge others` leaves units that were enabled before setup.sh.**
  Ubuntu 26.04 images ship sysstat enabled; the purge disabled its timers
  unconditionally.  `--others` now records, on the first run that touches a
  unit, whether it was already enabled, and the purge only disables what
  setup.sh turned on.
- The embedded Sury keyring is installed through apt (waits on the dpkg lock,
  read as root so apt prints no sandbox warning) instead of bare `dpkg -i`.
- `tools/fleet-update.sh` downloads and unpacks into a staging directory and
  only then moves the old checkout aside (a failed fetch used to leave an
  empty `/root/ubuntu-setup-script`); `update`/`autoclean`/`clean` wait on
  the dpkg lock.
- Tests: `bench-thread-tiers.sh` reproduces the five tiers of the published
  XenForo 2.3.13 web-stack benchmark; `seed-xf.sh` drops the unused
  `authors=` seeder parameter (it made the seeder exit 1 after seeding);
  `guest-cache-cookie-test.sh` follows SV/StandardLib's POST log-out
  interstitial.  `restore-baseline.sh` also removes the needrestart override the
  angie package's maintainer script leaves in `/etc/needrestart/conf.d`.
- Validation: 1,004 tuning checks (34 new), 212 dry-run matrix cases,
  ShellCheck clean; fresh install 2:25, `--optimize` ×2 idempotent (0 diffs),
  functional suite 0 unexpected responses, security probe 54/54, guest-cache
  cookie suite 62/62, zero warnings in setup logs and the journal.

## 1.21.32 (2026-11-18)

- **`--optimize` always recomputes the hardware profile; the
  `--reset-overrides` option is removed.**  The reset used to be an opt-in
  flag, so a host tuned by an older release or fixed by hand kept its old
  values.  It now runs on every `--optimize` before the tuners:
  `/etc/default/setup-tuning` is rewritten with only host facts/feature
  choices (`ANUBIS`, `ANUBIS_STATIC_BYPASS`, `XF_JOB_CRON`, `NODE_MAJOR`,
  `NODE_ALLOW_MAJOR_UPGRADE`), and
  `/var/lib/setup.sh/explicit-options.conf` is moved to `/tmp` (never
  deleted), dropping recorded `php_children`/`max_requests`,
  MariaDB/Valkey/Elasticsearch sizes and the dedi/vps pin.  `--reset-overrides`
  is now an unknown argument; `tools/fleet-update.sh` no longer passes it.
- **Tuning overrides are ignored and disallowed for `--optimize`.**  The
  tuning environment variables (`SETUP_TCP_CC`, `SETUP_QDISC`,
  `SETUP_STORAGE_CLASS`, `SETUP_PHP_WORKERS_PER_CPU`, `SETUP_PHP_JIT_HOT_*`,
  `SETUP_GZIP_LEVEL`, `SETUP_BROTLI_LEVEL`, `SETUP_ANGIE_COMPRESSION`,
  `SETUP_MARIADB_IO_CAPACITY`, `SETUP_LIMIT_REQ_EXEMPT`,
  `SETUP_PRECOMPRESS_ASSETS`, `SETUP_PHP_PAGE_GZIP`,
  `SETUP_PHP_JIT_WORDPRESS`) are unset for the run, listed in the report and
  in a warning, and `bbr`/`fq` plus the profile defaults are restored in
  memory even when the persisted file or the environment pinned them.  Two
  servers with the same hardware therefore get the same profile.  Feature
  choices (`ANUBIS`/`anubis=`, Node major, application cache and security
  toggles) and the `CONFIG_*` source knobs still apply; explicit
  `--php children=`, `--mariadb size=`, etc. remain install-time values and
  are recomputed on the next `--optimize`.  Application config, extra PHP
  ini/pools, Angie `custom.d` and third-party sysctl files are still never
  touched.
- `--dry-run --optimize` always prints the profile reset preview and the
  ignored environment overrides.
- Validation: 970 tuning checks (6 new), 212 dry-run matrix cases, ShellCheck
  clean.  On the production host the dry run prints `TCP_CC=bbr QDISC=fq`,
  the ignored `SETUP_*` overrides and the recomputed plan; the removed flag
  exits 1 with `Unknown argument`.

## 1.21.31 (2026-11-18)

Anubis fixes from the `origin-host` production host (Ubuntu 24.04,
8 vCPU / 32 GB, Angie + PHP/Chevereto + XenForo behind a CDN at
203.0.113.23).

- **Anubis own-page language is pinned to a complete catalogue.**
  `FORCED_LANGUAGE=en` is written to `anubis.env`.  Anubis localises its
  challenge page from `Accept-Language` with go-i18n's `MustLocalize`, which
  panics on a missing message; the bundled Thai catalogue has no
  `simplified_explanation`, so every Thai browser made the handler panic and
  Angie answered **502** (`th` reproduced deterministically; en/ja/de/fr/zh/
  ru/ar/hi/id/vi/tr/ko/pt/es/it/pl were fine).  English is the only catalogue
  complete in every shipped release.  `SETUP_ANUBIS_LANGUAGE=th` (or any
  locale) overrides it once the upstream catalogue is fixed.  The application
  still receives the visitor's own `Accept-Language`.
- **Outer `$realip_remote_addr` guards are disabled when a vhost moves behind
  Anubis.**  A vhost that only accepts traffic from its CDN
  (`if ($realip_remote_addr != "<edge IP>") { return 444; }`) cannot work over
  the Anubis socket: `$realip_remote_addr` is the *direct peer* (the socket),
  so the guard always fired.  On the production host the two vhosts with that
  rule answered 444 for every request (502 through the filter) and the static
  shadow returned an empty reply for every asset, while the vhost without the
  rule worked.  The integrator now comments the guard (single- or multi-line)
  in the moved copy, notes it in the `--optimize` report, and does the same
  for vhosts integrated by an older release.  The socket (0660 in a 0750
  runtime directory, no public listener left on the vhost) is the new
  perimeter; disabling Anubis restores the original vhost and its guard.
- Validation: 964 tuning checks (9 new), ShellCheck clean; on the production
  host `--optimize --reset-overrides anubis=yes` exits 0, both vhosts and
  their static assets answer 200 through the filter, the Thai challenge
  renders (200, valid challenge JSON), 0 panics and 0
  "upstream prematurely closed" entries after the fix.

## 1.21.30 (2026-11-17)

Full lifecycle on a reinstalled `lab.local` (Ryzen 7 8745HS, 16 threads,
27 812 MB, NVMe, Ubuntu 26.04.1, 505-package baseline).  Pair:
`server-configs-nginx` 1.6.43.  Audit report:
`tests/stress-site/AUDIT-20261117-1.21.30.md`.

- **PHP-FPM pool sizing uses the measured worker allowance.**  The planner
  reserves `children x php_worker_allowance_mb` (64–192 MB) but the writer
  divided the budget by a hard-coded 64 MB when clamping, so a host whose
  workers measure 96–192 MB could derive a pool up to 3x its reservation.
  `php_plan_max_children` takes the allowance as its sixth argument; both
  callers pass `php_worker_allowance_mb` for the pool version.  The
  hardware floor still wins by design (a small host is not under-provisioned;
  overcommit is reported), so this is a correctness guard, not a resize.
- **MariaDB `tmp_table_size` is clamped to the pool on every size.**  The old
  test only clamped when `pool/8 >= 32`, so a pool below 256 MB kept the
  RAM/256 value (up to twice the whole pool).  The cap is now always applied
  with 32 MB as the floor.
- **Swap files are built beside the live one.**  `create_swap_file` used to
  truncate `/swapfile` in place after `swapoff`; a full disk or an I/O error
  left the host with swap off, a zero-length file and a stale fstab entry.
  The replacement is written to `/swapfile.new`, `mkswap`ed and `swapon`ed
  first, then the old file is released and the new one moved into place.  A
  refused mkswap keeps an older active file's fstab entry.
- **`--diagnostics` is written to a private temp file and moved into place.**
  The report used to be chowned to the invoking sudo user before root
  appended the rest; that user could swap it for a symlink and receive every
  root dump.  `mktemp` (O_EXCL) + `mv` replaces (never follows) the target.
- **`--upgrade-php` no longer deletes configuration trees.**  The partial
  target tree and the superseded old tree are moved to `/tmp` like every other
  retirement path.
- **A pinned Anubis version is verified.**  `SETUP_ANUBIS_VERSION` without
  `SETUP_ANUBIS_SHA256` is refused (the built-in hashes only cover the tested
  release) and the download uses `--proto '=https' --tlsv1.2`.
- **Chevereto Imagick uses the FPM version**, not the alternatives CLI, so a
  multi-version host installs the extension the pool loads.
- **SQL imports raise the session packet limit** (`max_allowed_packet` 1 GiB)
  as well as the client flag, so a dump with a >64 MB row no longer fails
  halfway through.
- **A commented `DISABLE_WP_CRON` no longer enables the managed wp-cron
  entry** (the grep matched `// define(...)` and every task ran twice).
- **`SETUP_UFW_SSH_LIMIT=0`** writes a plain SSH ALLOW rule instead of
  `ufw limit`.  The rate limit (6 new connections/30 s per address) is right
  for a human but locked an automation host out for minutes, which surfaced as
  "Connection refused" because retries refresh the window.  Documented in the
  README troubleshooting table.
- **`ensure_angie_limits` no longer writes a stray global `changed`.**
- Validation: `tests/test-tuning.sh` **955 pass / 0 fail**, dry-run matrix
  **213 pass / 0 fail**, ShellCheck clean, install/optimize parity and
  `--optimize` idempotency byte-identical, 54/54 security, 62/62 guest-cookie
  (XenForo 2.3's log out is a GET link from `/account/visitor-menu`, not a
  POST of `data-csrf`), 0 unexpected functional responses, 0 PHP diagnostics,
  0 XF error rows.
- Measured (loopback, oha 1.16, c=100, 8 s): guest cache 138k req/s WordPress,
  216k XenForo, 191k Chevereto explore without Anubis; 40k / 47k / 41k with
  Anubis.  Members 288 (WP home), 729/439 (XF home/thread).  JIT tracing
  32 MB 554 vs 64 MB 550 vs off 517 req/s on the XF thread tier; PHP-FPM
  16 workers 541 vs 20 = 524, 24 = 517, 32 = 508, 12 = 465, 8 = 361.

## 1.21.29 (2026-11-17)

- **`tools/fleet-update.sh`.**  A safe replacement for the hand-written
  `apt … && wget … && setup.sh …` chain: non-interactive APT with
  `--force-confold`, a 300 s lock timeout and retries; `NEEDRESTART_MODE=l`
  so an unattended upgrade cannot restart the web stack mid-run; a guard that
  refuses to purge snapd while snaps are installed (`FORCE_SNAPD_PURGE=1`
  overrides); a timestamped backup of the previous checkout instead of
  `rm -rf`; a `curl`/`wget` download verified to contain `setup.sh`; separate
  dry-run and optimize logs; a failed-unit, disk and reboot summary; and
  `REBOOT=1` for an explicit reboot.  `SKIP_APT=1` retries only the setup
  phase, `REF=` pins another branch/tag.
- Validation: ShellCheck clean, `bash -n` clean; used on the four-host
  fleet run (24.04/26.04, 2–64 vCPU).

## 1.21.28 (2026-11-17)

Fleet-run fixes (four production Angie hosts: 24.04/26.04, 2–64 vCPU).

- **Retire stale `http.d/*__conf` files.**  A botched `.conf` rename from an
  old layout leaves e.g. `proxy_cache__conf` in `/etc/angie/http.d`; the
  tree includes `*.conf`, so the file is never loaded and only produced a
  warning about a cache zone that is "not included".  `sync_angie_repo_configs`
  now moves these to `/tmp` (nothing deleted) before the tuner runs.
- **Never lower a kernel-raised `vm.min_free_kbytes`.**  Small KVM guests
  raise it above the 1%-of-RAM target (67,584 KiB vs 40,038 KiB on the 4 GB
  host) and raise it again after the profile is applied, which showed as
  permanent drift and re-triggered the boot pass.  If the live value is
  higher and within the 256 MB cap it is kept in the profile.
- **Huge pages are sized for OPcache, not for RAM.**  The old `RAM/64`
  formula reserved 186 pages on a 12 GB host while the 512 MB OPcache + 64 MB
  JIT need 288, so `opcache.huge_code_pages` stayed off and the reservation
  was wasted.  `sysctl_hugepages_target` reserves
  `(opcache + jit)/2 + 8` pages when PHP is installed (296 on 8–128 GB hosts,
  152 on a 4 GB host, 0 without PHP), capped at 512.
- **Validation.**  951 tuning checks, 212 dry runs, ShellCheck clean; four
  production hosts optimized in 21–38 s each with no errors.
- **Proxy TLS.**  The Angie repo (1.6.39) now defaults
  `proxy_ssl_verify off`: setup.sh origins use self-signed certificates, and
  a verifying proxy answered 502 for the whole site (`site-a.example` on the
  proxy edge).  The hop stays encrypted; verification can be re-enabled when
  every origin has a publicly trusted certificate.

## 1.21.27 (2026-11-17)

Make the drift report distinguish "our profile is stricter/conservative" from
a real misconfiguration.

- **Only keys the host's profile actually defines are audited.**  The audit
  used to include every key the script *may* set, so `vm.max_map_count`
  appeared as `ours=unset` on a host without Elasticsearch even though the
  provider's `10-map-count.conf` was the only writer.  That line is gone; a
  key we do not set is not a conflict.  Our own drop-ins
  (`90-setup-network.conf`, `99-elasticsearch.conf`) are included when they
  exist.
- **Partial huge-page allocation is reported as best-effort, not drift.**
  A kernel can allocate only part of `vm.nr_hugepages` on a fragmented
  provider image (e.g. `allocated=87 requested=512`).  The report now says so
  explicitly instead of "a unit or the kernel set it".
- **`opcache.huge_code_pages` needs a full reservation.**  It is enabled only
  when the allocated 2 MB pages cover `opcache.memory_consumption` plus the
  JIT buffer (`php_hugepages_ok`); with 87 of 512 pages it stays `0` and
  OPcache uses normal pages instead of a partial huge-page mapping.
- **Value-aware source lines remain the answer to "safe or conflict?"**, e.g.
  `10-network-security.conf: rp_filter(file=2 ours=1)`: the provider ships
  loose mode (2), the managed profile uses strict mode (1).  Strict is safe on
  a single-homed web server; use 2 if the host does asymmetric routing
  (multiple NICs, policy routing, tunnels) and the strict value drops traffic.
  `10-magic-sysrq.conf: kernel.sysrq(file=176 ours=0)` is the profile being
  stricter by design; `99-hetzner.conf` keys all report `same`.

## 1.21.26 (2026-11-17)

Clarify the drift report and stop lowering one stock hardening value.

- **`vm.mmap_min_addr` is 65536, not 4096.**  Ubuntu and the major
  distributions ship 64 KiB; the profile was lowering it to the older 4 KiB
  kernel default.  Both block the NULL page, but 64 KiB leaves a smaller
  low-address window for a kernel/VM null-dereference to become a mapping.
  No normal server workload maps below 64 KiB; the audit on a stock Ubuntu
  host now reports the value as `same` instead of a silent downgrade.
- **The override audit shows values, not just names.**  A foreign sysctl
  file is printed as
  `key(file=<value in that file> ours=<value in /etc/sysctl.conf>)`, with
  `same` appended when the two agree.  A live drift line now names the
  non-managed file that defines the key, or states that no sysctl file did
  (a unit or the kernel set it).  This answers “is this safe or a conflict?”
  without opening every file:
  - `10-kernel-hardening.conf: kernel.kptr_restrict(file=1 ours=1 same)`
  - `10-magic-sysrq.conf: kernel.sysrq(file=176 ours=0)` — the managed
    profile disables Magic SysRq (stricter; reconsider only if you need
    serial-console recovery);
  - `10-zeropage.conf: vm.mmap_min_addr(file=65536 ours=65536 same)`.
- **`vm.min_free_kbytes` drift is not a safety issue when live > want.**
  On a small host the profile asks for ~1% of RAM (e.g. 39 065 KiB on
  3.8 GiB); a live 67 584 KiB (66 MiB) reserves more for the kernel and
  simply leaves a little less page cache.  The new `source=` suffix tells
  whether a non-managed file keeps re-raising it; if none does, a unit or the
  kernel did, and the 90 s enforcement pass re-applies the profile.

## 1.21.25 (2026-11-17)

Fleet rollout: make sure a server tuned by an older release, or fixed by
hand, actually receives the current profile.

- **`--optimize --reset-overrides`.**  A plain `--optimize` honours operator
  pins and recorded sizes by design; this flag ignores them for one run and
  recomputes everything from the current hardware:

  | Cleared (moved to `/tmp`) | Kept |
  |---|---|
  | `TCP_CC`, `QDISC`, `STORAGE_CLASS`, `PHP_JIT_WORDPRESS`, `PHP_PAGE_GZIP`, `PRECOMPRESS_ASSETS`, `XF_JOB_CRON`, `LIMIT_REQ_EXEMPT` in `/etc/default/setup-tuning` | `ANUBIS`, `ANUBIS_STATIC_BYPASS`, `NODE_MAJOR`, `NODE_ALLOW_MAJOR_UPGRADE` (host facts/feature state) |
  | every key in `/var/lib/setup.sh/explicit-options.conf` (`php_children`, `max_requests`, MariaDB/Valkey/ES sizes, `server_type`) | application config, extra PHP pools, operator `.ini` files, third-party sysctl files |

  `--dry-run` previews the reset and the foreign sources without moving a
  file.  Deleted nothing: the originals are in `/tmp`, like every managed
  change.

- **Late sysctl enforcement.**  `configure_sysctl` now also installs
  `setup-sysctl-final.service` plus a `.timer` (`OnBootSec=90s`): after
  `multi-user.target` the full managed profile and the selected qdisc/
  congestion control are applied again.  A hand-written `tcp-bbr.service`,
  `rc.local` or a provider agent that writes `tcp_congestion_control` at
  startup therefore loses at boot without deleting its file.
  `setup-network-tuning.service` also re-applies `/etc/sysctl.conf` after
  `systemd-sysctl`, so an early `/etc/sysctl.d` drop-in cannot win either.
  `--purge basic` disables and removes both units.

- **Drift audit.**  `--diagnostics` gained a “tuning override sources and
  live drift” section, and every `--optimize` report ends with “Tuning
  drift”: live values that differ from `/etc/sysctl.conf`, non-managed files
  under `/etc/sysctl.d` or `/run/sysctl.d` that still define a managed key,
  boot units that write sysctls, `/etc/default/setup-tuning` pins, explicit
  sizes, and PHP/Angie fragments that can override the managed profile
  (`.ini` sorting after `zz-setup-optimize.ini`, extra FPM pools,
  `/etc/angie/custom.d`).  The audit is read-only.

- **Validation.**  941 tuning checks and 212 dry runs pass; ShellCheck clean.
  End-to-end on a host seeded with `TCP_CC=cubic`, `QDISC=fq_codel`,
  `PHP_JIT_WORDPRESS=0`, `LIMIT_REQ_EXEMPT`, explicit `php_children=64`/
  `valkey_mb=2048` and a foreign `/etc/sysctl.d/50-old-fix.conf`:
  the preview listed exactly those, the run kept `ANUBIS`/`NODE_MAJOR`,
  removed the pins and the explicit file to `/tmp`, live values became
  `bbr`/`fq`, the report listed the foreign file, and
  `systemctl restart setup-sysctl-final.service` reverted a manual
  `cubic` change back to `bbr`.  `--purge basic` restored `cubic`/`fq_codel`
  and removed the units.

## 1.21.24 (2026-11-17)

CentMinMod comparison on the same EPYC 4245P (6C/12T, 30 GiB, 2x894 GB
NVMe) the AlmaLinux/CentMinMod numbers were measured on.  Every stack and
tier is now above the CentMinMod result; full tables in
`tests/stress-site/AUDIT-CENTMIN-20261117.md`.

- **16k TLS records (Angie repo 1.6.38).**  `ssl_buffer_size 1400` split a
  cached page into ~11 TLS records; `16k` sent it as one.  Cached guest
  throughput on the same page and TLS stack: **151,438 -> 442,765 req/s**
  (2.9x).  This was the single largest difference against CentMinMod.
- **Angie workers = 2/3 of the CPU count.**  Measured on the 12-thread host
  (16k buffer, 100 connections, gzip guest cache): 6 -> 367-371k, **8 ->
  389-390k**, 10 -> 369-370k, 12 (`auto`) -> 348-352k req/s.  The member and
  thread tiers were flat, so the change is free for dynamic traffic and
  removes 11% of cached-page throughput lost to worker contention.
- **Anubis `GOGC=off` on hosts with 16 GB or more.**  `GOMEMLIMIT` (RAM/8,
  capped at 2 GiB) still bounds the heap, so the collector only runs near the
  limit.  Anubis cached tier: 51,949 -> **57,082 req/s** (+9.9%), RSS below
  2 GiB.  Hosts under 16 GB keep the graduated 100/200/300/400 profile.
- **OPcache huge pages.**  `vm.nr_hugepages` is sized from RAM (RAM/64,
  capped at 512 pages = 1 GiB; none below 4 GB) and
  `opcache.huge_code_pages=1` is written only when the pages exist.  Member
  808 -> 835, thread 645 -> 670 req/s (+3.5%).
- **Validation.**  Ubuntu 26.04 / Angie 1.12.4 / PHP 8.2-8.5 / MariaDB 11.8 /
  Valkey 9.0 / Anubis 1.28.2, PHP 8.2-8.5 x 4 stacks.  Averages vs CentMinMod:
  Stack 3 cached **390,232 vs 157,957** (+147%), Stack 4 (Anubis) **68,725 vs
  59,958** (+14.6%), member home 747 vs 542 (+38%), guest bypass 819 vs 595
  (+38%).  Method notes: cached tiers use gzip bodies, the median 9-post
  thread matches the dataset average, and Stack 4 cached uses `ab` because
  wrk 4.1.0 under-reads bodies from the Go proxy on this host.

## 1.21.23 (2026-11-17)

- **Fresh `--elastic` install no longer prints a shell error.**
  `ensure_es_max_map_count` called `record_sysctl_originals`, a function that
  does not exist, so every Elasticsearch install (and `--optimize` on an
  existing ES host) logged `command not found` and never recorded the boot
  value of `vm.max_map_count`; `--purge basic` could not restore it. It now
  calls `record_sysctl_values vm.max_map_count`. The call site is inside a
  `|| warn`, which is why the install continued with exit 0.
- **UFW and the managed sysctl profile agree after a fresh install.**
  `configure_ufw` now re-runs `ufw_align_sysctl` after `ufw --force enable`.
  On a pristine host the align inside `configure_sysctl` runs before ufw is
  installed and is a silent no-op, so ufw's own `/etc/ufw/sysctl.conf` stayed
  unaligned until the first `--optimize` — an install/optimize divergence in
  the kernel state that survived every boot.
- **Hostname and disk probes match the tuners.** `generate_hostname` uses
  `effective_cpus` and `mem_total_mb` (cgroup quota/limit aware, the same
  probes every sizing path uses) instead of `nproc` and `dmidecode`, so a
  vCPU- or RAM-capped guest is no longer named `16c-32g-...` while its plan
  sizes 2 CPUs. `classify_block_device` reads the rotational flag through
  `${SETUP_SYS_BLOCK:-/sys/block}`, like `block_device_is_virtual`.
- **XenForo data-cache guidance corrected.** With `php-redis` loaded and
  Valkey on the local Unix socket, XF's registry/session cache measured
  **+7–9 %** authenticated throughput (member home 563 vs 516 req/s, thread
  571 vs 531) in the 1.21.23 audit on PHP 8.5 / Ubuntu 26.04. The old "27 %
  slower" note came from the add-on's pure-PHP Credis fallback (php-redis
  absent). README, the `--domain app=xf` hint and the `--optimize` report now
  say which case applies. The "Members online / Trending / Featured" widget
  advice (+39 %) is unchanged.
- **`error_reporting` has a measurable cost.** Temporarily enabling `E_ALL`
  for a deprecation scan lowered XF member throughput from 577 to 529 req/s
  (−9 %); the shipped `E_ALL & ~E_DEPRECATED` is the production value, and a
  compatibility scan should enable `E_ALL`, scan, then remove the drop-in.
- **XenForo logout test follows 2.3.** XF 2.3 renders log out as a POST form;
  the cookie-safety suite sent the pre-2.3 GET and reported two false
  failures. It now posts `_xfToken` (62/62 pass).
- **Validation.** Fresh install on a pristine Ubuntu 26.04 host: exit 0 in
  3 m 43 s, zero failed units, `angie -t` clean, 932 tuning checks, 207 dry
  runs, ShellCheck clean. `--optimize` twice: 0 configuration diffs.
  `--upgrade-php` 8.5 → 8.6 → 8.4 → 8.5 (8.6 refused before the purge
  without `SETUP_PHP_ALLOW_MISSING_EXT=1`, installed and serving with it;
  0 deprecations under 8.4 and 8.6). Security probe 54/54, cookie suite
  62/62. Benchmarks vs the public Host B reference (PHP 8.5): guest cache
  90.2k vs 56.6k, member home 574 vs 537, thread 550 vs 431; with Anubis
  31.3k / 557 / 570 vs 5.8k / 438 / 383. JIT tracing is +6–7 % over no JIT;
  the shipped 64 MB buffer and default thresholds are optimal; 1 worker/CPU
  beats 1.5× and 2×; Anubis GOMAXPROCS=8 beats 16; the static-asset shadow
  is +10.7 % on real assets. Full data in
  `tests/stress-site/AUDIT-20261117-1.21.23.md`.

## 1.21.22 (2026-11-17)

- **Anubis no longer uses `sub_filter` at all.**  The branding rewrite was
  removed from the terminator, together with the `anubis_pass`,
  `anubis_challenge_ua`, `anubis_strip_encoding` and
  `anubis_upstream_accept_encoding` maps.  The client's `Accept-Encoding` is
  passed through unchanged and the stock Anubis challenge page is served
  as-is.  This is simpler and removes a response filter from the edge; the
  measured no-pass cached guest throughput was unchanged on the Ubuntu SER8
  host (~30.5k with the old conditional map, ~30.9k without it), because the
  previous fix already kept gzip for allowed clients.  Browser challenges are
  now stock pages instead of the branded variants.  `SETUP_ANUBIS_BRANDING`
  is gone; it has no effect.
- **Validation.**  932 tuning checks (the map-specific checks were replaced
  by pass-through/no-`sub_filter` checks), 208 dry runs,
  ShellCheck clean, `angie -t` clean.  Ubuntu SER8 Stack 4 remains ~30k
  req/s; cache hits still carry `Content-Encoding: gzip`; stock challenge
  page verified.

## 1.21.21 (2026-11-17)

- **Anubis no longer inflates allowed guest pages.**  The old map stripped
  `Accept-Encoding` from every request without the Anubis pass cookie, not
  just from a challenge.  An allowed crawler/API client therefore fetched the
  **identity** page (115 KB) through Anubis and triggered all six `sub_filter`
  rules, while the cached gzip body is only 15.7 KB.  The map now strips
  encoding only when the request is challenge-bound (`Mozilla` or empty
  user-agent, no pass cookie); allowed non-Mozilla clients and pass-cookie
  browsers keep gzip, so `sub_filter` skips the application response.  A
  browser challenge still receives the branded page (the terminator compresses
  it after filtering).  On the Ubuntu test host the no-pass cached guest tier
  moved from **5.8k to 30.5k req/s**; the 12-thread EPYC's 7.9k baseline is
  recorded separately.
- **FastCGI cache hits skip per-hit AIO and Brotli.**  Cached locations in
  `server-configs-nginx` now set `aio off; brotli off;`: the stored body is
  already gzip and re-running either filter only costs CPU.  Static assets
  keep the global AIO/Brotli path.  On CentMinMod/Nginx, `aio threads` cost
  16 % of cached-page throughput (167k -> 140k); on Angie the scoped change
  was neutral.  The checks are in `php_xf.conf`, `php_xf_proxy.conf`,
  `wordpress_cache.conf`, `php_chev_cache.conf` and `php_flarum.conf`.
- **MariaDB growth is visible before it hurts.**  `--diagnostics` now reports
  live data versus the InnoDB buffer pool and warns when data is above 80 % of
  the pool.  README documents re-running `--optimize` (or `--mariadb size=`)
  after a large `sql=` import or application bulk seed; the pool is only ever
  increased, so a host sized while empty keeps the small value until the next
  optimize run.
- **Validation.**  934 tuning checks (5 new Anubis map checks), 208 dry runs,
  `angie -t` clean on the updated tree.  Ubuntu SER8: Stack 4 no-pass cached
  guest **5.8k -> 30.5k**, Stack 3 unchanged at ~59k, browser challenge still
  branded, functional tiers 200.  The benchmark harnesses document the
  CentMinMod/Nginx A/B (`aio threads` off is faster there).

## 1.21.20 (2026-11-16)

- **Anubis: the filter socket is no longer world-connectable.**  The service
  wrote `SOCKET_MODE=0666` into a `0755` `/run/anubis`, so any local account
  (including a compromised PHP process) could connect to the Go proxy
  directly, choose the `Host` header and forge `X-Real-IP`; the backend vhosts
  trust the unix peer (`set_real_ip_from unix:`) and use that header as
  `$remote_addr`, so per-IP rate limits and application IP checks were
  bypassable from the host.  The socket is now `0666` -> `0660` in a `0750`
  directory, owned `anubis:anubis`.  `www-data` is added to the `anubis` group
  (nginx re-runs `initgroups()` when it spawns a worker) and Angie is reloaded
  before the socket is recreated, so the workers keep access while every other
  account is refused.  Verified as `www-data` (connect, 500 from the policy
  parser on a malformed probe) and `nobody` (EACCES).
- **Anubis disable no longer opens a 502 window.**  `--optimize anubis=no`
  stopped the service before Angie had loaded the restored direct-TLS vhosts;
  every site answered 502 until the reload at the end of the run (and a later
  failure left the host 502ing until an operator started the filter again).
  The stop is deferred until the reload succeeds and waits one second for the
  old workers to drain: a concurrent probe measured **420/420 HTTP 200**,
  versus one 502 in 420 before the drain.  A failed tune keeps Anubis running.
- **Anubis vhost migration matches the port, not the substring.**  `listen
  8443 ssl;` (and any `*443*` port) was treated as the public HTTPS listener
  and lost its only bind, while an IPv6-only `listen [::]:443 ssl;` was dropped
  without a replacement (the block fell back to `:80`).  Migration now matches
  `443` exactly, replaces the first TLS listener (IPv4 or IPv6) with one
  backend socket and drops the duplicates.  The installed version check also
  normalises the `v` prefix (`Anubis v1.28.2`) instead of assuming it.
- **Valkey: a full `noeviction` cache is no longer grown 20% on every run.**
  maxmemory was only recognised as "full" for an evicting policy, so a
  `noeviction` cache (the documented choice for sessions/jobs) walked
  512 -> 614 -> 736 MB ... up to the host cap on consecutive runs, while the
  report claimed it was refusing to evict data.  A non-evicting cache at its
  ceiling now keeps `CURRENT` (or takes the plan once when it is below it);
  `--valkey ram=` is the explicit way to grow it.
- **`--upgrade-php` is atomic around the package purge.**  A failed
  `apt-get purge` used to `die` from inside the installer, bypassing the
  rollback path and leaving a partially purged PHP.  The purge now returns a
  status; the driver restores the old version and writes the failure report.
  Optional extension packages are installed one at a time (a published but
  uninstallable extension, e.g. a Sury build with an unresolved dependency,
  no longer aborts the whole upgrade), and a failed autoremove *probe* is no
  longer read as "no candidates" (which purged every post-purge orphan).
  The driver also repeats the post-Angie PHP `[PATH=]` refresh that
  `--optimize` performs, so both paths write the same ini in one run.
- **Validation.**  928 tuning checks, 208 dry runs, 54/54 security probes and
  61/61 guest-cookie checks.  Functional suite: 0 unexpected responses and 0
  PHP diagnostics on PHP 8.5 and 8.4.  PHP round trip 8.5 -> 8.4 -> 8.5: 14/15
  extensions carried, 0 skipped, Angie reloaded, 0 functional errors.
- **OPcache script table counts each root once.**  The `[PATH=]` sizing walked
  `/etc/angie/conf.d/*.conf` roots without de-duplicating; with the Anubis
  static shadow (a copy of every root) the PHP file count was doubled and the
  table was clamped at 128 256 on every protected host.  Roots are sorted
  unique before `find`.
- **Sury's global APT key is retired.**  The vendor keyring `.deb` installs
  the same key in `/etc/apt/trusted.gpg.d/`, where it can sign **every**
  configured repository, defeating the `signed-by` pin the script writes.
  The identical copy is now moved to `/tmp` (the Angie key already was).
  Verified on the audit host after an upgrade: only
  `/usr/share/keyrings/debsuryorg-archive-keyring.gpg` remains.
- **Smaller correctness fixes:**
  - `--domain a.com db=... b.com app=wordpress db=...` no longer leaks
    `app=wordpress` to `a.com`; a following `db=` clears the trailing
    group-default flag.  A dry-run assertion pins the plan.
  - `--php ver=` (empty variable) and `--upgrade-php --dry-run` (a flag
    consumed as the version) are rejected instead of silently selecting
    another mode/version.
  - `--basic host=` enforces real DNS labels and the 64-character systemd
    limit; `a..b` or a 100-character name no longer aborts `--basic` after
    the hostname but before the firewall and cron are configured.
  - `--elastic host=example.com:9200` is rejected at parse time instead of
    installing a node that cannot bind 180 s later.
  - Reserved ephemeral ports include `9000` (a supported PHP-FPM TCP
    listener) alongside 3306/6379/9200/9300 and the SSH ports.
  - The THP oneshot is ordered `Before=` MariaDB/Valkey/Redis/Elasticsearch,
    so a host booting with `always` no longer starts InnoDB with THP before
    the `madvise` write.
  - `vm.max_map_count` and its Elasticsearch drop-in are recorded, so
    `--purge elastic` restores them instead of leaving setup-owned state.
  - The Elasticsearch heap reader uses the last `-Xmx` (the JVM's rule) and
    its docstring no longer promises to keep a heap the planner shrinks.
  - The audit harness takes `TARGET_IP=`; Chevereto correctly answers 403 to
    a loopback `X-Real-IP`, so an Anubis run must use the host's LAN address
    to exercise the same path as a real client.

## 1.21.19 (2026-11-16)

- **The whole Anubis Go profile is hardware-derived.**  Only `GOMAXPROCS` was
  scaled (cores, capped at 8); `GOGC`, `GOMEMLIMIT` and the unit's
  `LimitNOFILE` were constants chosen on the 16-core/28 GB audit host, so a
  2-core/2 GB VPS got a 1 GiB heap backstop and a 64-core/512 GB host got the
  same 65 536 fd ceiling as a 16-core one.  Four pure helpers now share one
  rule between the unit writer, the log line and the tests:

  | Value | Rule | 2c/2 GB | 4c/4 GB | 8c/16 GB | 16c/32 GB | 64c/64 GB |
  |---|---|---:|---:|---:|---:|---:|
  | `GOMAXPROCS` | `clamp(cores, 1, 8)` (measured plateau) | 2 | 4 | 8 | 8 | 8 |
  | `GOGC` | 100 ≤2 GB, 200 ≤4 GB, 300 ≤8 GB, 400 above | 100 | 200 | 400 | 400 | 400 |
  | `GOMEMLIMIT` | `clamp(RAM/8, 256 MiB, 2 GiB)` | 256M | 512M | 2G | 2G | 2G |
  | `LimitNOFILE` | `clamp(cores × 4096, 16k, 128k)` | 16k | 16k | 32k | 65k | 128k |

  A small VPS keeps Go's default collector (a relaxed heap on 2 GB leaves no
  headroom for PHP/MariaDB); large hosts keep the measured `GOGC=400` and a
  backstop proportional to RAM.  The applied profile is part of the
  `Anubis: enabled (...)` summary in the run log and the optimize report.
- **Audit of the other services:** every remaining value is already derived
  from the live host — Angie worker processes/connections/fd limits/open-file
  cache/cache zones from CPU, RAM and free disk; PHP workers, memory,
  realpath and OPcache from CPU and RAM; MariaDB pool, redo, connections and
  I/O capacity from live data, RAM and disk class; Valkey memory and clients
  from the working set and PHP pool; Elasticsearch heap and thread pools from
  the index store and CPU; sysctls from CPU, RAM and host class.  The fixed
  1 048 576/524 288 `nofile` entries are ceilings, not allocations: they grant
  the descriptors the hardware-sized pools need and have no memory cost.
- **Tests:** 25 new checks pin the four rules across 1/2/4/8/16/32/64 CPUs and
  2/4/8/16/64 GB, plus two rendered-unit checks (32c/64 GB and 2c/2 GB), for
  919 tuning checks total.  The "identical drop-in keeps its mtime" check now
  compares epochs instead of a calendar year, which failed only because the
  restored host timezone (UTC-8) renders the fixed 2001-01-01 instant as 2000.

## 1.21.18 (2026-11-16)

- **A re-install keeps Valkey's operator-owned cache settings.**  `--optimize`
  deliberately preserves AOF persistence, a non-loopback `bind` and a custom
  `unixsocket` when the cache holds sessions/queues or serves other app
  servers, but `install_valkey` called the shared writer without `adopt`, so a
  later run of the install command erased those markers and restarted the
  service with `save ""`, `appendonly no`, a loopback bind and the default
  socket: an AOF cache was wiped and a remote client lost its endpoint
  (audited in 1.21.17).  The installer now passes `adopt` and the configured
  socket, so both paths write the same file.  A fresh stock config is
  unaffected: the keep rules only fire for a non-default or previously marked
  file.
- **`--upgrade-php` applies the full Angie profile.**  The upgrade called only
  `tune_angie_configs`, while `--optimize` also runs the WordPress/XenForo
  guest caches, the include migration, asset precompression and Brotli.  An
  adopted host therefore kept old cache includes after a PHP upgrade and
  reached a different state than `--optimize` (audited in 1.21.17).  It now
  calls `angie_apply_profile`.
- **`--optimize` recomputes the PHP `[PATH=]` sections after the Angie sync.**
  The managed ini is derived from the Angie tree (`_cache_enc` in the cache
  key, application roots), but PHP is tuned before Angie is synchronised.  On
  a host whose `/etc/angie` was one repository version behind, the ini was
  written from the old tree and changed again on the next run, and a newly
  deployed application root never received its section.  The writer now runs
  again after the Angie pass and reloads PHP only when it changed something;
  two consecutive `--optimize` runs are byte-identical on the audit host.
- **Leaner Anubis: `GOMAXPROCS` capped at 8.**  Go defaults to one P per CPU.
  At 100 connections on the 16-thread host the default measured 7 203 cached
  WordPress pages/s with 4.17 Anubis cores, `GOMAXPROCS=8` 6 871 req/s with
  3.92 cores and the same p99 (4 = 5 925, 2 = 3 812).  Eight keeps the
  throughput and bounds how much scheduler parallelism the proxy can ask for
  when PHP needs the same cores; a host with 8 or fewer CPUs keeps its own
  count.
- **The benchmark harness sends a User-Agent.**  `wrk` sends none, which the
  shipped Anubis policy correctly challenges (empty UA), so the tier and sweep
  scripts measured challenge issuance for every tier (a flat ~37 000 req/s,
  including the member pages) instead of the site.  All loop harnesses now
  send `User-Agent: setup-bench/1.0`.
- **Validation.**  894 tuning checks, 203 dry runs, 54/54 security, 61/61
  guest-cookie, functional suite clean with Anubis on and off, install and
  `--optimize` parity snapshot empty (230 files), two `--optimize` runs
  byte-identical.  PHP 8.5 -> 8.4 -> 8.5 round trip: 14/15 extensions carried,
  pool/ini/JIT identical, Angie reloaded, 0 functional errors; 8.6 is refused
  before the purge because `php8.6-imagick`/`php8.6-redis` are unpublished.

## 1.21.17 (2026-11-16)

- **Static assets no longer traverse the Anubis proxy.**  A page view asks for
  dozens of CSS/JS/image/font files, and the managed policy ALLOWs them, so
  the Go hop filtered nothing and cost throughput: one CSS file measured
  41 603 req/s through Anubis on the audit host (0.42 cores) and 137 090 req/s
  on the new fast path (0.00 cores), with p99 8 ms -> 1 ms.  Every protected
  vhost gets a **static-only shadow** server block on
  `/run/angie-static/static.sock`: a mechanical copy of the application block
  (same `server_name`, `root`, includes and locations) with the public
  listeners and TLS directives removed and two guards added — a non-static URI
  or a path that is not an existing file answers 404.  The terminator proxies
  the asset extensions there and retries through Anubis on 404, so an
  alias/rewrite endpoint or a missing file keeps working.
  The shadow is what keeps the security model intact: XenForo's
  `internal_data` stays `internal`, dotfiles/backup/archive denies still apply,
  and `Range`/`HEAD`/conditional requests behave exactly as before (206/200/304
  verified).  `www-data` can traverse the shadow directory, but the shadow
  contains no PHP route: `/index.php`, `/wp-login.php`, `/wp-admin/` and a
  writable `.php` all answer 404 there, while `nobody` cannot reach the socket
  at all.  The real backend socket stays `0750 root:anubis`.  A server-level
  `return`/`rewrite` block is skipped (its assets are redirected), and an
  unknown `Host` hits a 404 `default_server` instead of the first site's root.
  `SETUP_ANUBIS_STATIC_BYPASS=0` keeps every request on the proxy hop and is
  persisted as `ANUBIS_STATIC_BYPASS`; `--optimize anubis=no` and
  `--purge angie` remove the generated file with the rest.  If `angie -t`
  rejects a shadow, the run drops the fast path, regenerates and keeps the
  filter rather than failing the whole integration.
- **Validation.**  894 tuning checks, 202-203 dry-run cases, 54/54 security,
  61/61 guest-cookie, functional suite clean, cached page tiers unchanged
  (WP 7.6 k, XF 10.7 k req/s), install/`--optimize`/disable/re-enable byte
  stable.

## 1.21.16 (2026-11-16)

- **`--upgrade-php` no longer prints false `[ERR]` lines.**  The upgrade
  preflight walks every `/etc/angie/conf.d/*.conf` file and resolves its
  document root; `angie_vhost_root` piped `grep -m1` through `sed`, so a
  generated vhost with no `root` directive (the Anubis TLS terminators, a
  redirect-only block) returned 1 through `inherit_errexit` and the ERR trap
  printed four `command failed ... sed`/`sort -u` lines while the run still
  finished successfully.  The lookup is now an awk that always succeeds and
  prints nothing for a rootless or missing file; the lookup and the shared
  app detector added below are covered by seven new unit checks (878 total).
- **Leaner Anubis runtime.**  The managed unit sets `GOGC=400` and a 1 GiB
  `GOMEMLIMIT`: the default collector ran mark/sweep long before the ~120 MB
  working set needed it, and the relaxed collector measured 7 100 req/s
  against 6 750 on the cached WordPress tier (p99 35 ms vs 39 ms) with RSS
  114 MB.  The memory limit is a backstop so a traffic spike cannot turn the
  relaxed collector into an OOM.
- **One application detector instead of four copies.**  The `--upgrade-php`
  preflight had two inline copies of the WordPress/XenForo/Chevereto marker
  check (`wp-config.php` + `wp-includes/version.php`, `src/XF.php` +
  `src/config.php`, `app/env.php`), the same predicate the tuners and the
  report use.  `app_type_at_root` in `lib/util.sh` is now the single owner,
  so a site cannot be recognized by one walk and missed by another.
- **Pair with server-configs-nginx 1.6.33**, which stops a
  `SETUP_LIMIT_REQ_EXEMPT` address from bypassing the credential limiter.

## 1.21.15 (2026-11-16)

- **Anubis cannot be bypassed by a local account.**  The backend socket is
  created 0777 (Angie daemonises with umask 0), so any local user could
  connect to `/run/angie/anubis-backend.sock` with `X-Real-IP: 127.0.0.1`
  and skip the bot filter, every IP ACL and the audit log.  `/run/angie` is
  now `0750 root:anubis`; only Angie (binder) and Anubis (client) traverse
  it.  Verified: `nobody` gets `000`, the Anubis user gets `200`.
- **Enabling Anubis no longer caps every upload at 11 MB.**  The generated
  terminator inherited the http-level `client_max_body_size 11m` and
  buffered the body before the backend's own limit applied; XenForo
  attachments, Chevereto uploads and WordPress plugin installs answered 413.
  The terminator now sets `client_max_body_size 0` and streams the request
  (`proxy_request_buffering off`), leaving the per-vhost limit in charge.
  Verified with a 15 MB POST through Anubis (200, not 413).
- **A failed Anubis start rolls back instead of leaving dead sockets.**
  `anubis_enable` rewrote every vhost to the backend socket and then returned
  without undoing it when the service did not create its socket; the running
  Angie kept working until the next reload or reboot, after which every site
  answered 502.  It now restores the vhosts, removes the generated files and
  re-tests Angie, like the `angie -t` failure path.
- **Per-block real-IP migration.**  The old migration decided whether a vhost
  already had `real_ip_header` with a file-global grep; a CDN block's
  `real_ip_header X-Forwarded-For` therefore suppressed the fix in every
  block, leaving the backend trusting a client-supplied header from the Unix
  peer.  Each block now drops its own header and gets
  `set_real_ip_from unix:` + `real_ip_header X-Real-IP`; other trusted ranges
  are kept.
- **The terminator replaces `X-Forwarded-For`.**  It appended with
  `$proxy_add_x_forwarded_for`, so the client's own entries survived and
  applications behind the trusted terminator read the left-most (forged)
  address.  It now sets `$remote_addr`, on the HTTP and WebSocket legs.
- **`--purge angie` restores the vhosts before stopping Anubis.**  Stopping
  the service while the vhosts still listened on its socket made a later
  `systemctl start angie` answer 502 for every site.  The binary, unit,
  policy and `.orig` backups stay, so `--optimize anubis=yes` re-enables.
- **Leaner Anubis.**  Static assets are allowed without a challenge (a
  challenged CSS/JS request used to return HTML on the first visit, and
  assets are most of the request volume), an empty User-Agent is challenged,
  and `SLOG_LEVEL=WARN` stops one journal line per proxied request.  A pinned
  `SETUP_ANUBIS_VERSION` is compared after the override, so it no longer
  re-downloads on every run without restarting the service; the live env file
  is created mode 600 before it holds the cookie secret; and the temporary
  `angie -t` file uses `tmp_file` instead of a predictable `/tmp` name.
- **`--diagnostics` and `--restart-all` are clean on an empty host.**  The
  log-tail discovery piped `find` into `head`; with no `/var/www/logs` the
  SIGPIPE surfaced through the ERR trap as a false
  `[ERR] command failed ... head -n 120` even though the report was written.
  It now maps the file list and slices it.  `--restart-all` reports "no
  supported services detected" as INFO instead of WARN on a host that has
  none.  Verified on the restored 526-package baseline: both exit 0 with
  0 ERR/WARN.
- **Pair with server-configs-nginx 1.6.32**, which closes the encoded
  login-limiter bypass and gives PHP the public `SERVER_PORT`/`REQUEST_SCHEME`
  on the Unix-socket leg (Chevereto emitted `https://host:/image/...`).
- **Validation.**  871 tuning checks, 202-203 dry-run cases (one case depends on a detected application); fresh install and
  `--optimize` parity; three applications; Anubis on/off/rollback; 61/61
  guest-cookie and 54/54 security checks; encoded login POSTs limited
  (429 after 11) where they were 14/14 accepted before.

## 1.21.14 (2026-11-16)

- **Optional Anubis bot filter.**  `--angie anubis=yes` (fresh install) and
  `--optimize anubis=yes` (existing host) install Anubis 1.28.2 from the
  verified official tarball and put every site behind it:
  `:443` TLS terminator -> Anubis (`/run/anubis/nginx.sock`) -> the
  application vhost (`/run/angie/anubis-backend.sock`).  Both legs are Unix
  sockets: a TCP loopback backend measured ~8 k req/s (Go's default idle pool
  opens a connection per request), the Unix socket reaches ~49 k req/s on the
  audit host.  The vhosts are migrated and backed up under
  `/var/lib/setup.sh/anubis/vhosts`, terminators are generated from each
  vhost's `server_name`/certificate, PHP sees the client address and
  `HTTPS=on`, dot segments answer 400 at the edge, and the challenge page is
  branding-free.  The policy allows search engines and infrastructure routes,
  denies known AI crawlers and challenges `Mozilla` clients.  `ANUBIS=1` is
  persisted, so a later `--domain` or plain `--optimize` protects new sites.
  `--optimize anubis=no` restores every vhost, removes the generated Angie
  files and stops/disables the service (the binary and `/etc/anubis` stay for
  a quick re-enable).  Pair with server-configs-nginx 1.6.31.
- **MariaDB pool sizing follows the data more closely.**  `auto` is now
  data+index **plus 5%** (was 25%) with the 128 MB operational minimum and
  the only-increase rule unchanged.  On a host where MariaDB is the only
  data service (no PHP, Valkey or Elasticsearch) the pool may use up to
  **80% of total RAM**; a mixed host keeps the half-of-RAM ceiling.  The
  measured 935 MB table still gets a pool larger than the table (981 MB), and
  a 60 GB database on a 64 GB database-only host gets 51 GB instead of 32 GB.
- **PHP's `HTTPS` flag behind a terminator.**  `http.d/https_map.conf`
  rebuilds it from `X-Forwarded-Proto` and `snippets/fastcgi-php.conf` passes
  it, so applications do not emit `http://` URLs when the application leg is
  plain HTTP.

## 1.21.13 (2026-11-16)

- **The MariaDB buffer pool holds the working set again.**  1.21.9 sized
  `innodb_buffer_pool_size` at **4%** of live data+index.  Measured on the
  audit host with a 935 MB table, the 128 MB pool that rule produced
  answered 71 k point queries/s with 92% physical reads, while a pool that
  held the table (1.7 GB) answered 212 k/s with none -- a 3x regression for
  exactly the high-concurrency member traffic the tuner exists for.  `auto`
  is now **data+index plus 25%**, capped at half of RAM and at the shared
  budget (the proportional trim still protects PHP, Valkey and
  Elasticsearch), with the 128 MB operational minimum and the
  only-increase rule unchanged.  A fresh install keeps its RAM/16 floor, so
  this only raises an adopted host that was left at the 128 MB package
  default.
- **A hand-written XenForo vhost with a one-line nested include no longer
  blocks the Angie sync.**  `location /x/ { include h5bp/php_xf.conf; }`
  was not recognised as nested (the migration only matched an include at
  the start of its own line), so `angie -t` rejected the canonical
  server-level named location and the whole tree rolled back.  The
  migration now also rewrites an include that follows an opening brace on
  the same line.
- **An unanchorable WordPress vhost is reported as such.**  A vhost that
  includes `h5bp/wordpress.conf` but not `h5bp/php_wp.conf` has no safe
  place to insert the guest-cache include; the report used to claim the
  operator had set `SETUP_WP_GUEST_CACHE=0`.  It now names the missing
  anchor and leaves the vhost alone.
- **Validation.**  845 tuning checks, 193 dry-run cases, ShellCheck clean;
  fresh install and `--optimize` parity (2 745-line state snapshot) on
  Ubuntu 26.04.1.

## 1.21.12 (2026-11-16)

- **Every guest cache reports the same `X-Cache-Status` header.**  The Angie
  repository used one name per application (`X-5m-Cache` for XenForo,
  `X-30-Cache-Status` for Chevereto, `X-Guest-Cache` for Flarum,
  `X-1h-Cache-Status`/`X-Proxy-Cache` for the XenForo proxy and `X-CDN` for
  the CDN template); the XenForo cache repair now injects `X-Cache-Status`
  and renames a legacy `X-5m-Cache` line before repairing, so monitoring
  needs one name.  Pair with server-configs-nginx 1.6.30; update alerting or
  log parsing that keys on the old names.
- **Validation.**  839 tuning checks pass.

## 1.21.11 (2026-11-16)

- **The WordPress guest cache is enabled by default.**  A WordPress vhost
  without `include h5bp/wordpress_cache.conf;` is no longer treated as an
  operator opt-out: `--optimize` inserts the include directly before the
  vhost's `h5bp/php_wp.conf` include, where the template puts it, so guest
  pages are cached without a manual vhost edit.  `SETUP_WP_GUEST_CACHE=0`
  keeps such vhosts uncached and the report names them; an existing
  per-vhost include, or the shared include in `php_wp.conf`, is left alone.
  The insertion is idempotent, so a second `--optimize` changes nothing.
- **Validation.**  837 tuning checks pass.

## 1.21.10 (2026-11-16)

- **A nested `php_xf.conf` include no longer blocks the Angie sync.**  A
  hand-written XenForo vhost may include `h5bp/php_xf.conf` inside a
  location (the old single-location snippet allowed it) as well as at server
  level.  The canonical file defines a server-level named location
  (`@xf_guest_cache`), which Angie rejects inside a location, so
  `deploy_angie_tree`'s validation failed ("named location ... can occur on
  the server level only") **before** `angie_migrate_guest_cache_includes`
  could rewrite the nested include to `h5bp/php.conf`; the whole `/etc/angie`
  tree was rolled back and `--optimize` exited 1 while the other services
  still applied.  The migration now runs before the validation.  Found on a
  live 48-CPU XenForo host (vhost included the snippet twice, once inside an
  `auth_basic` location); after the change the sync validates, the nested
  include becomes `php.conf`, and the server-level guest cache stays.
- **Validation.**  833 tuning checks pass.

## 1.21.9 (2026-11-15)

- **The buffer pool follows the database, not RAM.**  `--optimize` (and the
  shared installer profile) now sizes `innodb_buffer_pool_size` from the live
  `data_length + index_length`: **4%** of the current database, with the
  documented 128 MB operational minimum, instead of data+20% bounded by a
  RAM floor.  A data-sized pool on a large server reserved RAM the host did
  not need and pushed PHP, search and the page cache out of the 80% plan.
  The value is **only ever increased**: a live pool above the target is kept
  (`OPT_MARIADB_KEPT_MB`), because shrinking would restart the server and
  throw away a warm buffer pool.  A fresh install with no data keeps the
  RAM-proportional floor (`clamp(RAM/16, 256 MB, 4 GB)`); an existing empty
  database gets the 128 MB minimum.
- **The redo log is 25% of the pool, as mysqltuner recommends.**  The
  previous hard cap (2 GB on SSD/HDD, 4 GB on NVMe) silently dropped large
  pools below 25% (a 32 GB pool got 4 GB, 12.5%).  The ratio is now exact on
  every disk class.  `innodb_log_buffer_size` follows the pool
  (`clamp(pool/16, 16 MB, 64 MB)`) so `innodb_log_file_size >=
  innodb_log_buffer_size` holds for small 4% pools too (a 128 MB pool gets a
  32 MB log and a 16 MB buffer; MariaDB rejects a log smaller than the
  buffer).
- **Verified on a live 5 586 MB database.**  A 128 MB pool grew to the 4%
  target (223 MB, reported as 224 MB after MariaDB's chunk rounding) with a
  56 MB redo log and a 16 MB log buffer; a second `--optimize` was a no-op.
  A 512 MB pool was kept against the 223 MB target (only increase) with a
  128 MB log and a 32 MB buffer, and no restart.  The report now states the
  4% target instead of "does not fully fit".
- **`--optimize` no longer needs curl.**  A stock Ubuntu 26.04 image ships
  `wget` but neither `curl` nor `git`, so a host provisioned outside this
  script failed its Angie repository sync ("Could not download server
  configs").  The fetch now tries curl, then wget (HTTPS-only), then git, and
  the failure message names the missing tool.  Verified on the 526-package
  baseline host with no curl and no git: the wget path downloads the tree and
  `angie.conf` is present.
- **Validation.**  830 tuning checks pass; `shellcheck -S warning` clean.

## 1.21.8 (2026-11-15)

Eighth audit of the 1.21 line on the Ubuntu 26.04.1 test host (16 logical
CPUs, 27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13
and Chevereto 4.5.9.  Pair with server-configs-nginx 1.6.29.  The defects
were in the upgrade, purge and firewall-state paths; the install and
`--optimize` paths again needed no correction.

- **`--upgrade-php` now repoints Angie at the PHP socket.**  On a host built
  from distribution packages, PHP-FPM listens on `127.0.0.1:9000` and
  `angie.conf`'s `local_php` upstream points there.  `install_php` writes the
  managed Unix-socket pool, so the TCP->socket migration in the tuner can no
  longer fire (it only runs while the pool is still on TCP); the upgrade
  reloaded Angie against a dead port and every site answered 502 while the
  report said PASS.  The upgrade now applies the shared Angie tuner after the
  PHP tuner and `php_upgrade_verify` fails when a `fastcgi_pass`/`server
  ...:9000` remains with a socket pool.  Verified by converting the audit
  host to the distro layout (pool `127.0.0.1:9000`, upstream TCP), then
  `--upgrade-php=8.4`: the upstream became `unix:/run/php/php-fpm.sock` and
  all three applications answered 200; `--upgrade-php=8.5` round-tripped
  with 15 extensions carried and 0 skipped.
- **The upgrade preflight saw too little, and Chevereto's imagick was not a
  requirement.**  A Chevereto tree is now detected by `app/env.php` alone
  (the same predicate `--optimize` and the guest-cache code use) instead of
  requiring `app/bin/legacy`; document roots declared by Angie vhosts
  outside `/var/www` are scanned as well; and `imagick` joins redis/mysqli/
  gd/curl/mbstring as a hard Chevereto requirement.  `--upgrade-php=8.6`
  now names all three blockers (redis and imagick for Chevereto, redis for
  XenForo) and still refuses before the purge.  A skipped extension that is
  installed twice (php-imagick and php8.5-imagick) is reported once, like the
  dry run already did.
- **A CLI-only PHP host is an upgrade, not a fresh install.**  With PHP
  packages but no `phpX.Y-fpm`, the driver took the "nothing installed" path:
  the purge still removed every PHP package but no extension inventory or
  rollback point was taken.  The driver now falls back to any installed PHP
  version, and a failed post-tune FPM start rolls the old version back
  instead of leaving the host on a dead PHP.
- **`--purge` now stops an adopted Redis and retires every unit it wrote.**
  `--optimize` and `--restart-all` already treated Redis as a managed cache;
  purge only stopped `valkey-server`, so `--purge`/`--purge all` left
  `redis-server` enabled and holding memory.  `--purge others` missed
  `sysstat-rotate.timer`, and `--purge basic` left
  `/etc/systemd/system/setup-cpu-governor.service` behind (the install path
  now records its previous state, so a host that already had a unit keeps
  it).  Verified with a temporary redis-server: `--purge valkey` stopped and
  disabled it; `--purge others` disabled all four sysstat units.
- **UFW recognises the OpenSSH application profile.**  Provider images ship
  `ufw allow OpenSSH`, which prints `OpenSSH ALLOW` and matched none of the
  numeric checks: `configure_ufw` added a redundant rule and the purge
  lockout guard added a `limit 22/tcp` to a host this script had not
  configured.  The helpers now resolve the profile to port 22, and purge
  removes it before restoring the original allow rule.
- **The documented run-log name matches the file.**  `usage()` and README
  said `setup_<timestamp>.log`; the mirror is
  `setup_<timestamp>-<pid>.log`.
- **Angie repository (1.6.29).**  `/wp-cron.php` is reachable from loopback
  only (WordPress's own `spawn_cron`), instead of being denied to everyone;
  percent-encoded dot segments are rejected like literal ones; Flarum's
  writable `assets/` tree denies PHP; the XenForo guest cache stores an entry
  only after two requests (`fastcgi_cache_min_uses 2`), so a single-shot
  style-variation flood cannot fill the 16 GB zone; the CDN template no
  longer caches the permission-checked `/media/<id>/` HTML route for 182
  days and verifies the origin certificate; the HTTP/3 snippet no longer
  carries `reuseport` (a second vhost made `angie -t` fail); the base
  `example.com.conf` answers port 80 with a redirect and an ACME path; and
  the Shlink template no longer points at a password file it does not ship.
- **Validation.**  823 tuning checks and 193 CLI/dry-run checks pass;
  `shellcheck -S warning -x` is clean (0.11.0, same file list as CI).
  Install/`--optimize` state snapshots are identical (2 745 lines) and a
  second `--optimize` changes nothing, before and after the three
  applications were deployed.  Functional suite: 0 unexpected responses and
  0 PHP diagnostics on 8.5; guest-cache cookie safety 61/61; security probe
  54/54.
- **Performance (workstation `oha`, Wi-Fi 802.11ax, 100/200 c, 8 s).**
  Distribution defaults -> shipped tuning: XenForo member thread 246 -> 534
  req/s (+117 %), WordPress member home 140 -> 292 (+109 %), WordPress
  member post 131 -> 269 (+105 %).  Guest cache: XenForo 7 309 req/s
  (p50 24.8 ms), WordPress 5 368 (p50 32.3), Chevereto `/explore` 5 654,
  image 5 470, home 2 613.  Worker sweep 8/12/16/20/24 = 388/497/**575**/556/556,
  JIT off/function/tracing 32/64/128 MB = 410/510/572/**573**/571.  Sustained
  60 s authenticated XenForo (c=64): 563 req/s, p50 112 ms, p99 131 ms,
  33 691 x 200, 0 non-2xx, CPU 94-97 %, 16/16 workers busy, 0 slow queries,
  0 new error-log lines, 0 failed units.
- **PHP ceiling.**  WordPress 7.1.4 bootstraps and serves on 8.6.0RC5 with 0
  fatals (18 compile-time deprecations in bundled libraries on 8.5);
  XenForo 2.3.13 reports 71 `null` array-offset deprecations in its own
  `src/XF/App.php` plus vendor deprecations, and Chevereto 4.5.9 needs the
  upstream `?ImageManager` fix; neither can move to 8.6 until `redis`,
  `igbinary` and `imagick` are published there, and `--upgrade-php=8.6`
  refuses before the purge.

## 1.21.7 (2026-11-15)

Seventh audit of the 1.21 line on the Ubuntu 26.04.1 test host (16 logical
CPUs, 27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13
and Chevereto 4.5.9, on a freshly restored 526-package baseline.  Pair with
server-configs-nginx 1.6.28.  The production modules again needed no
correction; the defects were in the application-deployment and security
harnesses, plus one Angie rate-limit gap that 1.6.28 fixes.

- **The deploy harness was poisoning the XenForo guest cache.**
  `deploy-three-apps.sh` switched `useFriendlyUrls` with a raw `UPDATE`, which
  leaves the options XenForo cached during `xf:install` in place.  The board
  then answered `GET /` with `301 /index.php`, the vhost cached that 301 for
  an hour, and the `xf-guest` tier benchmarked 1 024 empty redirects a second
  instead of the forum page (the functional suite hid it because it follows
  redirects with curl `-L`).  Options are now written through
  `XF\Repository\OptionRepository::updateOption()`, the guest cache is purged
  after seeding, and the canonical thread URL is stored (a bare
  `/threads/ID/` answers 301 to the slug, so the member tier measured a
  redirect too).
- **A repeat deploy is now possible.**  `RESET_DB=1` drops and recreates the
  three databases and flushes the Valkey databases first.  Without it a
  second run dies in XenForo ("all XenForo database tables must be removed")
  and then in Chevereto ("already installed"), because
  `cheveretoVersionInstalled()` reads `chv_variables` through the Redis cache
  before touching the database.
- **The cookie-safety test has automated fixtures.**  It needs a WordPress
  endpoint that sets a per-visitor cookie and known passwords, which were
  never scripted, so a correct host reported eight failures.  The new
  `seed-guest-cache-fixtures.sh` installs the mu-plugin, resets the `bench5`
  accounts and sets the Chevereto admin password (deploy runs it); the test
  accepts `PW`/`CHEV_PW` and detects the member page by its `/account/` link
  instead of the user name, which the members-online widget also shows on a
  cached guest page.  61/61 checks pass after that, including "a response
  that sets a cookie is never stored".
- **`security-probe.sh` is new.**  51 read-only checks over the three vhosts:
  hidden files, backup and dump copies, PHP in writable directories,
  PATH_INFO, dot segments, internal XenForo trees, unknown `Host`, URL
  override headers, and PUT/TRACE.  All 51 pass; the XenForo upgrader is
  reachable by design (303 to its login) and is now rate-limited by the Angie
  repo (see 1.6.28).
- **README corrected.**  The XenForo paragraph claimed "404/301 for 24 h";
  the shipped configuration is 301 for 1 h and 404 for 1 min.
- **Validation.**  819 tuning checks and 192 CLI/dry-run checks pass;
  `shellcheck -S warning -x` is clean (0.11.0, same file list as CI).  Full
  install 3:43 with zero errors, install/`--optimize` state snapshots
  identical, `--optimize` a byte-identical no-op on the second pass and after
  the three applications were deployed, `--domain` repeat a no-op, PHP
  8.5 -> 8.4 -> 8.5 round-tripped (14 and 15 extensions carried), all three
  applications answer with zero PHP diagnostics on both versions, and the
  deploy/cookie/security harnesses are green after a `RESET_DB=1` redeploy.
- **Performance (workstation `oha`, Wi-Fi 802.11ax, 100/200 c, 8 s).**
  Distribution defaults -> shipped tuning: XenForo member thread 269 -> 577
  req/s (+114 %), WordPress member 144 -> 275 (+91 %), WordPress member post
  134 -> 259 (+93 %).  Guest cache: XenForo 4 504 req/s (p50 43.7 ms),
  WordPress 2 944 (p50 66.9 ms), Chevereto `/explore` 1 353, image 2 993;
  the 30 KiB static asset ran at 757 req/s (22 MiB/s) and is client-bound on
  the Wi-Fi link, not server-bound.  Sustained 60 s authenticated XenForo
  (c=64): 559 req/s, p50 113 ms, p99 140 ms, 33 461 x 200, CPU 95 %, all 16
  workers busy, 0 slow queries, 0 error-log growth, 0 failed units.
- **Sweeps confirm the shipped optima.**  static 8/12/16/20/24 workers =
  345/440/484/482/477 req/s (16 = one per CPU); JIT off/function/tracing
  32/64/128 MB = 519/457/551/559/557 (tracing 64 MB).
- **PHP ceiling re-confirmed.**  WordPress 7.1.4 bootstraps and serves on
  8.6.0RC5 with 0 fatals (19 compile-time deprecations in bundled libraries);
  XenForo 2.3.13 and Chevereto 4.5.9 stay on 8.5/8.4 because 8.6 publishes no
  `redis`, `igbinary` or `imagick`, and `--upgrade-php=8.6` refuses before the
  purge.

## 1.21.6 (2026-11-14)

Sixth audit of the 1.21 line on the Ubuntu 26.04.1 test host (16 logical
CPUs, 27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13
and Chevereto 4.5.9.  Pair with server-configs-nginx 1.6.27.  The production
modules needed no correction on a freshly restored 526-package baseline; the
two defects found were in the benchmarking harness.

- **A rate-limited load test can no longer be published as throughput.**
  Angie caps GET at 100 r/s per address, so a remote generator that is not
  exempted answers with 429 almost immediately and `oha` reports a huge,
  meaningless requests/s (one run showed 21k r/s with 168k 429s, and a
  first pass in this audit measured 10k r/s of pure 429s).  A naive reader
  sees a fast server; the number is the limiter.  `run_one` now computes the
  429 share per scenario, warns on stderr, records a `WARNING` section in the
  report and makes the whole run exit 3 when 5% or more of a scenario's
  answers are 429, with the `SETUP_LIMIT_REQ_EXEMPT` remedy in the message.
  Verified both ways: 41 204/41 614 429s -> exit 3; with the workstation
  exempted -> exit 0 and all 200s.
- **Server-side PHP-FPM metrics are no longer silently empty.**
  `collect-metrics.sh` asked `cgi-fcgi` (optional, not installed) and then a
  `/fpm-status.php` that no managed vhost serves, so every sample recorded a
  blank FPM field during the stress runs.  Without `cgi-fcgi` it now counts
  the pool from the process table (`workers=`, `busy~=`) and says why the
  exact status is unavailable.  Verified idle `16/0` and under load `16/16`.
- **Validation.**  819 tuning checks and 192 CLI/dry-run checks pass;
  `shellcheck -S warning -x` is clean (0.11.0, same file list as CI).  A full
  install finished in 3:07 with zero errors, install/`--optimize` state
  snapshots are identical, the second `--optimize` is a no-op, PHP
  8.5 -> 8.4 -> 8.5 round-tripped with 15 extensions carried, and all three
  applications answer with zero PHP diagnostics on 8.4 and 8.5.
- **Performance (workstation `oha`, LAN, 200/100 c, 8 s).**  Distribution
  defaults -> shipped tuning: XenForo member thread 255 -> 552 req/s
  (+116 %), WordPress member 141 -> 253 (+79 %), WordPress member post
  128 -> 237 (+85 %).  Guest cache: XenForo 7 190, WordPress 5 203,
  Chevereto explore 5 338, static 20 030 req/s.  Sustained 60 s
  authenticated XenForo: 492 req/s, p50 117 ms, p99 347 ms, 29 455 x 200,
  zero slow queries, zero error-log growth, 0 failed units.
- **Sweeps confirm the shipped optima.**  static 8/12/16/20/24 workers =
  376/480/538/424/404 req/s (16 = one per CPU); JIT off/function/tracing32/
  tracing64/tracing128 = 395/494/543/549/534 (tracing 64 MB).
- **PHP ceiling re-confirmed.**  WordPress 7.1.4 bootstraps on PHP 8.6 RC5
  (0 compile fatals); XenForo 2.3.13 and Chevereto 4.5.9 are held at 8.5/8.4
  because 8.6 publishes no `redis`, `igbinary` or `imagick`, and
  `--upgrade-php=8.6` refuses before the purge.
- **Tuning actually applied** (this hardware): kernel BBR/`fq`, 65k
  backlogs, 32 MB buffers; Angie 16 workers x 32 768 connections; PHP
  static 16, OPcache 512 MB, JIT tracing 64 MB; MariaDB pool 1 738 MB
  (data +20 %) with redo 434 MB and pool-of-threads; Valkey 434 MiB
  `allkeys-lru`; Elasticsearch 4 GB heap.

## 1.21.5 (2026-11-14)

Fifth audit of the 1.21 line on the Ubuntu 26.04.1 test host (16 logical
CPUs, 27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13
and Chevereto 4.5.9.  Pair with server-configs-nginx 1.6.27.

- **WordPress database-user split works with a TCP loopback host.**  The
  hardening pass creates a per-site account and moves `wp-config.php` to it,
  but the account was created at `localhost` only.  A site configured with
  `DB_HOST = '127.0.0.1'` (or `::1`) failed the connection probe and the split
  was silently skipped, leaving the global account in place.  The scoped
  account is now granted at `localhost`, `127.0.0.1` and `::1` (matching
  `--domain`), and the probe connects over the host the site actually uses.
- **`ensure_angie_limits` no longer reports success as failure.**  The helper
  returned 1 when it wrote a drop-in (an inverted status that only survived
  because its single caller used `|| true`).  It always returns 0 now and the
  `ANGIE_UNIT_CHANGED` flag carries the "a change was written" signal.
- **The functional suite fails on an unexpected response.**  It printed the
  code and kept going, so a request that never reached the server (curl 000)
  or a 403/500 could be read as a pass.  `expect` records each unexpected
  code, the run ends with `result: N unexpected response(s)` and exits
  non-zero.  Login, reply, search, upload, dot-segment and front-controller
  checks are covered.
- **XenForo thread discovery is deterministic.**  The reply/search tests used
  `/whats-new/posts/`, which is empty for a guest on a freshly seeded board;
  the reply was then posted to `https://xf.test.localadd-reply` (000) and the
  search POST ran without a token (400), both unnoticed.  The suite falls
  back to the first seeded `xf_thread` row and follows the canonical slug
  redirect.
- **Chevereto login tolerates one token/session race.**  A page token from a
  request whose `Set-Cookie` was lost makes the first POST answer 403; the
  suite now retries once with a clean jar before recording a failure (a second
  failure is still fatal).
- **`set-fpm.sh` validates before reloading.**  It runs `php-fpm -t` and
  restores the saved pool when the candidate is rejected, so an invalid sweep
  cannot leave PHP-FPM restart-looping behind 502s.  It also gained an
  explicit `dynamic N` action that writes the start/spare keys a static pool
  does not carry, and `fpm-sweep.sh` uses it for its dynamic comparison
  (the old inline sed produced exactly the missing-spares failure above).
- **Validation.**  819 tuning checks and 193 CLI/dry-run checks pass;
  `shellcheck -S warning` is clean.  A full install finished in 3:08 with
  zero errors, `--optimize` is a byte-identical no-op on the second pass,
  PHP 8.5 -> 8.4 -> 8.5 round-tripped with 15 extensions carried, and all
  three applications answer with zero PHP diagnostics.  Sustained 60 s
  authenticated XenForo load: 521 req/s, p50 122 ms, p99 142 ms, 100 %
  success, no new error-log lines, 0 failed units.

## 1.21.4 (2026-11-14)

PHP version-management audit on the same Ubuntu 26.04.1 host (16 logical
CPUs, 27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13
and Chevereto 4.5.9.  Pair with server-configs-nginx 1.6.27.

- **`--upgrade-php` refuses to break an installed application.**  PHP
  8.6.0~rc5 publishes no `php8.6-redis`; the previous release purged PHP
  8.5, installed 8.6 and reported the gap afterwards, leaving Chevereto and
  a Redis-backed XenForo answering 500 ("Redis extension not loaded").  A
  preflight now detects WordPress, XenForo and Chevereto below `/var/www`
  (including a WordPress object-cache drop-in and a XenForo `config.php`
  that configures Redis/Valkey), checks the target repository for every
  hard requirement and aborts **before the purge**.  Nothing is changed on
  refusal; `SETUP_PHP_ALLOW_MISSING_EXT=1` accepts the loss explicitly.
  Verified: `--upgrade-php=8.6` now exits 1 with PHP 8.5 still serving; the
  dry run prints the same BLOCKED section.
- **Extension accounting is correct.**  The summary reported only the
  non-core packages (`Extensions carried 2` after a full 8.4 install) and
  the dry run listed `common` twice (php-common and php8.4-common).  The
  count now covers every distinct carried extension (14 for 8.4, 15 for
  8.5) and the preview de-duplicates names.
- **Chevereto 4.5.9 on PHP 8.4+.**  Its bundled Intervention Image 2.x
  declares `ImageManager $manager = null`; PHP 8.4 deprecates the implicit
  nullable type, and Chevereto's shutdown handler converts that deprecation
  into a failed request.  The first request handled by each worker after a
  restart therefore answered 403/500 on `/login` and every upload.  This is
  an application defect, not a server setting: the audit host uses the
  upstream one-line fix (`?ImageManager $manager = null`) and records the
  finding.  With it, Chevereto is clean on 8.4 and 8.5.
- **Functional tests run with production error reporting.**
  `tests/stress-site/exercise-apps.sh` forced `error_reporting=E_ALL` for
  the functional pass, which made any application that throws on a vendor
  deprecation fail the run.  It now keeps `E_ALL & ~E_DEPRECATED` and only
  routes the central log; `compat-php.sh` remains the run that forces
  `E_ALL` for the deprecation scan.  The harness also saves a login page to
  a file instead of piping curl into `head` (SIGPIPE could kill curl before
  it wrote the cookie jar) and clears stale Chevereto login cookies before
  its one-second-resolution unique key can collide.
- **Path hardening and Chevereto front controller.**  See
  server-configs-nginx 1.6.27: dot-segment requests are rejected with 400
  before they reach PHP, and a direct `/index.php` is redirected to `/`
  instead of producing Chevereto's 500.
- **Validation.**  819 tuning checks and 193 CLI/dry-run checks pass.  On
  PHP 8.5: 8.4 -> 8.5 and 8.5 -> 8.4 round trips succeed, all three
  applications answer with zero PHP diagnostics, `--optimize` is a no-op
  on the second pass, and `--diagnostics`, `--restart-all`, `--purge
  --dry-run` and `--php ver=` refusal behave as documented.  PHP 8.6 RC is
  installable for WordPress/XenForo but blocked for Redis-dependent sites
  by the new preflight.

## 1.21.3 (2026-11-13)

Findings of an independent review of 1.21.2 (shell libraries and the Angie
configuration), validated on the Ubuntu 26.04.1 test host (16 logical CPUs,
27 812 MiB RAM, NVMe, bare metal) with WordPress 7.1.4, XenForo 2.3.13 and
Chevereto 4.5.9.  Pair with server-configs-nginx 1.6.26.

- **Log files are no longer followed through symbolic links (privilege
  escalation).**  The log directories under `/var/www/logs` belong to their
  service account, and root ran `chmod 640`/`chown` on the files inside
  them.  A compromised PHP application could replace `php-error.log` with a
  link to `/etc/passwd` and the next install, `--optimize` or
  `--restart-all` handed that file to `www-data`.  `secure_log_file` leaves
  a link alone and reports it, creates a missing file with `O_EXCL` and
  changes the owner with `-h`; `log_file`, the Angie deployer and the
  PHP-FPM log path all use it.
- **An interrupted run cannot leave the site stopped.**  Angie and PHP-FPM
  are paused while MariaDB restarts.  A dropped SSH session (HUP), a closed
  output pipe or Ctrl-C in that window left them stopped; HUP and PIPE are
  now trapped and `on_exit` resumes whatever is still paused.
- **Adopted Redis/Valkey keeps its persistence and bind address.**
  `--optimize` wrote `save ""`, `appendonly no` and `bind 127.0.0.1 -::1`
  into every cache it found.  A service setup.sh did not install that has
  `appendonly yes` or binds a non-loopback address keeps those lines (marked
  in the file, reported, and kept on later runs).  A cache installed by
  `--valkey` is unchanged.
- **`--upgrade-php` keeps the socket of a migrated extra pool.**  The
  version rewrite also renamed `listen = /run/php/php8.3-fpm-shop.sock`,
  while the operator's vhost still pointed at the old name: 502 with a
  passing report.  The `listen` line is now left alone, as it already was
  for `www.conf`, and the dot in the old version is escaped.
- **Repeat runs keep earlier choices.**  `--basic` without `host=`/`time=`
  on a host it already configured keeps the live hostname and timezone
  instead of generating a new name and moving the clock to Asia/Manila;
  `--valkey` without `policy=`/`io_threads=` keeps the previous values (the
  validation wrote the defaults back, so the preservation code never ran).
- **Backup credentials with `#`, `"` or `\`.**  `/etc/mysqlbkup.cnf` is an
  option file: `pass='Ab#9xQ'` was read as `Ab` and every nightly dump
  failed.  User and password are written quoted and escaped.
- **Generated vhosts get anchored route locations.**  `--optimize` rewrites
  the XenForo `^/(admin.php|install)` and Chevereto `^/(dashboard|update)`
  locations of existing vhosts to the anchored 1.6.26 form, so `/install.sh`,
  `/install.log` or `/update.log` are no longer served.  Verified on the
  host: 200 before, 403/404 after.
- **XenForo static assets.**  One `Cache-Control: public, max-age=2592000,
  immutable` header instead of two, and HSTS on `/js`, `/styles`, `/data`.
- **Smaller fixes.**  Automatic swap is sized to the free disk (256 MiB kept
  free, the old file's space counted) before an active swap file is
  released, and no longer aborts `--basic` on a small disk.  The WordPress
  database-user split never re-keys an account that already exists (two
  database names sharing 24 characters collided).  The malware rule for
  `plugin-<10 hex>` directories needs at least one hex letter
  (`akismet-2024051001` was quarantined).  The optimize report is 0640.
- **`--purge` then re-install is the fresh-install state again.**  The
  purge disables `phpsessionclean.timer` and the sysstat units, which only
  the package postinst enabled; a re-install on the kept packages left them
  off (PHP sessions were then never collected).  `--php` and `--others
  sysstat` enable them again.  Verified: the state snapshot after purge,
  re-install and `--optimize` is identical to the one before the purge.
- **Tests.**  802 tuning checks and 193 dry-run combinations pass on the
  host.  A test that called a function removed in an earlier release (and
  passed on its "command not found") is gone.

Reviewed and left as is, with the reason: the Angie tree is fetched from the
`main` branch (pin `CONFIG_REPO_REF` to a tag for change control);
`/etc/sysctl.conf` is replaced as a whole; `--purge basic` removes the
managed cron block; the memory plan counts only the `www` pool; storage
class in an LXC container follows the host's disks (set
`SETUP_STORAGE_CLASS`); a Redis with `requirepass` is not probed with a
password.

## 1.21.2 (2026-11-13)

Security and correctness fixes found by the 1.21.1 audit, validated on the
Ubuntu 26.04.1 test host (16 logical CPUs, 27 812 MiB RAM, NVMe, bare metal)
with WordPress 7.1.4, XenForo 2.3.13 and Chevereto 4.5.9.  Pair with
server-configs-nginx 1.6.25.

- **Host-header cache poisoning (config repository; reproduced, then
  closed).**  The guest cache keys on `$host`, but PHP received the raw
  `Host` header as `HTTP_HOST`.  `Host: wp.test.local:8443` on the 443
  listener shared the normal cache entry but WordPress answered with a
  cacheable 301 to itself; XenForo rendered the wrong base URL.  A new
  `http.d/fastcgi_host.conf` passes `$php_http_host` to FastCGI: the header
  only when it is exactly `$host` or `$host:<public port>`, otherwise
  `$host`.  `custom.d/php_public_port.map` declares a NAT/load-balancer port
  that differs from the local listener.  Verified: PHP sees
  `wp.test.local` for `Host: wp.test.local:8443` and for uppercase or
  `:443` spellings; normal requests still hit the cache and stay 200.
- **XenForo REST/OAuth responses in the guest cache (config repository).**
  `//api/`, `/Api/` and `/?api/` with `XF-Api-Key` were stored.  The URI
  maps are case-insensitive and slash-tolerant, and a new `$xf_api_request`
  map (also covering `XF-Api-User` and `Authorization`) is folded into
  `$nocacheuri` and repeated on the FastCGI/proxy bypass lines.  Verified:
  all spellings answer `BYPASS` with and without a key, before and after
  `--optimize`.
- **Backup and hidden PHP files served as downloads (config repository).**
  `/wp-config.php.save`, `/wp-config.txt`, `/backup.zip`,
  `/src/config.php.save` and `/app/env.php.save` returned 200.  New
  `h5bp/location/security_backup_files.conf` blocks PHP below dot paths and
  every `.php*` suffix, and `security_root_archives.conf` blocks archives
  and dumps in an application document root only.  Verified: all five
  probes are 403, while `/wp-content/uploads/2026/release.zip` and a normal
  image stay 200.
- **MariaDB online resize clamp.**  MariaDB 11.8 accepts a
  `SET GLOBAL innodb_buffer_pool_size` above the running server's startup
  maximum, returns success and silently clamps the pool, so the report said
  the resize was applied.  `optimize_mariadb` now reads the live pool back
  and, when it is more than 2% below the target, reports the clamp and
  falls back to a restart.  Verified: a 1024 MB pool was raised to the
  1738 MB target only after the restart path ran.
- **Valkey maxmemory guard.**  A full cache under an evicting policy kept
  being re-sized to `used + 20%` on every run (512 -> 613 -> 735 MB).  The
  guard now keeps the current size when the cache is full, takes the plan
  when the plan is larger, raises only for real data growth, caps at the
  host budget and never touches an explicit `--valkey ram=`.  The install
  plan measures an already-installed cache like `--optimize`.
- **PHP version changes are explicit.**  `--php` is now a first
  installation: on a host that already runs PHP-FPM it keeps the packages,
  extensions and extra pools and only re-applies the managed
  configuration; another `ver=` is refused with a pointer to
  `--upgrade-php`.  `--upgrade-php` preflights the purge with the real apt
  options and refuses a transaction that would remove an application such
  as phpMyAdmin (`SETUP_PHP_ALLOW_COLLATERAL=1` overrides), then restores
  the units that were serving if the real purge still fails.  Packages that
  only exist unversioned (`php-pear`, the PHP libraries) are carried over
  under their own name instead of a non-existent `phpX.Y-` build.
- **Installer hardening and small-host tuning.**  A refused swap file
  (LXC/OpenVZ, btrfs/ZFS) no longer aborts the rest of `--basic` or leaves
  a multi-GB file behind; an active swap file that cannot be deactivated is
  left alone instead of being truncated.  Dirty-page thresholds are capped
  at RAM/20 and RAM/5 on small hosts; the network oneshot prefixes every
  command with `-` so one unavailable module cannot fail the unit; udev
  readahead follows the detected storage class; the precompress helper runs
  as `www-data`, never root.
- **Domain and import guards.**  `--domain` refuses MariaDB system schemas
  and reserved accounts (`root`, `mysql`, `mariadb.sys`, ...) before any
  SQL runs, and every create/grant statement now fails the step instead of
  being skipped inside an `if`.  A truncated gzip/xz/zstd dump fails the
  import without sending `COMMIT`.
- **Tests.**  769 tuning checks and 193 dry-run combinations pass on the
  host.  The new suite covers the cache guard, MariaDB clamp detection,
  dirty thresholds, udev readahead, the network unit, swap failure paths,
  reserved accounts/schemas and the `--php`/`--upgrade-php` matrix.

## 1.21.1 (2026-11-13)

Two shell errors that a successful run printed, found on a fresh install and
`--domain` pass on Ubuntu 26.04.1 (the runs still exited 0).

- `--others nodejs` on a host without Node.js printed `services.sh: line 54:
  v: unbound variable` twice: `node_installed_major` read a local it had not
  assigned.
- `--domain` and `--optimize` printed `[ERR ] command failed (exit 1)` when
  the last XenForo or WordPress vhost had no application files yet:
  `angie_xenforo_vhosts` and `angie_wordpress_vhosts` ended on a failed test.
- Test tooling: `tests/deploy-audit/state-snapshot.sh` prints the managed
  state for an install versus `--optimize` diff; `exercise-apps.sh keep` now
  writes the `cookies.tsv` the load-tier scripts read (they stop if it is
  missing instead of measuring guests); the JIT sweep also measures the
  PHP 8.4+ built-in thresholds.

## 1.21.0 (2026-11-13)

Guest-cache hardening, compressed cache entries for WordPress and Chevereto,
and `--upgrade-php` parity fixes (with server-configs-nginx 1.6.24).  Found
by a full install, `--optimize`, `--domain`, `--upgrade-php` (8.5 -> 8.4 ->
8.6 RC5 -> 8.3 -> 8.5), `--diagnostics`, `--restart-all`, `--purge` and
re-install pass on a 16-thread / 28 GB / NVMe bare-metal Ubuntu 26.04.1 host
with WordPress 7.1.4, XenForo 2.3.13 and Chevereto 4.5.9, plus two read-only
code audits.  Measurements: `tests/stress-site/TUNING-20261113-1.21.0.md`.

- **Security (config repository; reproduced on the audit host, then closed).**
  - `/any/script.php/x` skipped every `\.php$` deny rule and was executed:
    `/wp-config.php/x`, `/wp-admin/install.php/x`, `/src/config.php/x`,
    `/app/env.php/y` and a PHP file below Chevereto's writable `content/`.
    The WordPress, XenForo and Chevereto PHP includes now answer
    `\.php/` with 404 (none of the three routes through PATH_INFO).
  - A PHP file below XenForo's writable `/data/` was executed.  `xf2.conf`
    returns 404 for PHP below `data`, `js`, `styles`, `src`, `library` and
    `internal_data`.
  - The XenForo guest-cache key appended raw cookie values to
    `$request_uri`: `GET /` with `xf_style_variation=threads/x.1/` stored the
    forum index under that thread's key for every guest.  The key now uses
    validated tokens behind delimiters.
  - `fastcgi_cache_valid` is first-match in file order, so the `5xx 0s` line
    placed after `any` never applied (errors were cached 5-15 s).  The line
    now comes first; XenForo 404s are cached 1 minute instead of 24 hours.
- **`setup.sh` side of those fixes.**
  - `tune_xf_cache_vary` replaces any XenForo key that is not built from
    validated tokens (the form older releases wrote included) with
    `$request_method|$scheme|$host|$request_uri|<variation>|<style>|<language>|<encoding>`;
    the maps live in the managed `zz-setup-fastcgi-cache-map` file.  The
    repository's own validated key is left alone.
  - `tune_cache_error_policy` puts (or moves) the `5xx 0s` line in front of
    the first `fastcgi_cache_valid`.
  - The injected XenForo static-asset location keeps `nosniff` and the
    GET-only method limit that the regex location used to drop.
- **Compressed guest-cache entries for WordPress and Chevereto.**  Their
  cached pages were stored uncompressed and Brotli-compressed by Angie on
  every hit: about 1 ms of CPU per hit, 14.8k req/s with all 16 threads busy.
  The managed PHP ini now turns `zlib.output_compression` (level 4) on in a
  `[PATH=<root>]` section for every WordPress/Chevereto root whose cache key
  carries the encoding token, so the cache stores the gzip page: 0.12 ms per
  hit and 67-72k req/s on the same host (XenForo, which compresses itself,
  was already there).  A client without gzip gets the plain entry.  A
  per-request `fastcgi_param PHP_VALUE` was tried first and rejected: the
  value stayed active for other vhosts on the same worker.
  `SETUP_PHP_PAGE_GZIP=0` turns the feature off (persisted as
  `PHP_PAGE_GZIP`).
- **Chevereto session files are collected.**  Chevereto starts a PHP session
  for every cookie-less request and keeps the files in its own directory
  (`/tmp` by default), which the distribution's `sessionclean` timer never
  visits; one load test left 585,000 files (2.4 GB of tmpfs).  Chevereto
  roots get `session.gc_probability = 1`, `session.gc_divisor = 1000` in
  their `[PATH=]` section (585k -> 28k files after the first collection).
- **`--upgrade-php`.**
  - An extension the target does not publish is remembered in
    `/var/lib/setup.sh/php-pending-extensions` and installed by the next
    upgrade that can.  Before, 8.5 -> 8.6 RC -> 8.5 lost `imagick` for good.
  - The systemd drop-in directory of a PHP-FPM version that is no longer
    installed is removed (each hop used to leave one behind).
  - `write_service_limits_dropin` no longer rewrites an identical file.  The
    mtime bump made systemd print "unit file ... changed on disk, run
    daemon-reload" on every later `systemctl` call after an upgrade.
- **Detection and memory plan.**
  - `mariadb` is detected by the server binary only.  A web node with
    `mariadb-client` and a remote database was planned a buffer pool, 1.0
    PHP workers per core and a drop-in for a unit it does not have.
  - A SCSI-attached virtual disk (QEMU, VMware, Hyper-V, Google, cloud block
    volumes) reports `rotational=1` and was tuned as an HDD.  It is now
    classed `ssd` from its vendor/model string; `SETUP_STORAGE_CLASS`
    (or `STORAGE_CLASS=` in `/etc/default/setup-tuning`) pins the class.
  - The 256 MB scarcity floor no longer raises MariaDB or Valkey above its
    own target or changes an explicit `size=`/`ram=`.
  - The MariaDB target is capped at the data pool before the proportional
    split, so a database larger than RAM no longer pushes Elasticsearch to
    its floor.
  - A "kept" Elasticsearch heap or buffer pool that the split then changed
    is no longer treated as kept (it produced an unrounded heap and a second
    restart on the next run).
  - The Angie cache disk cap measures `/home`, where the cache zones live.
- **`--php children=N` below the hardware target is honoured.**  The count
  was raised to the hardware default (12 became 24 on a 16-thread VPS-class
  host) while the run log said "max_children overridden to 12".  An explicit
  value is now kept in both directions (minimum 2), in the pool writer and
  in the memory plan.
- **MariaDB first start.**  The systemd drop-in is written before the
  package is installed, so the package's own first start no longer logs
  "Referenced but unset environment variable ... MYSQLD_OPTS".
- **Tests.**  30 new tuning checks (**698/698**, CLI/dry-run 173/173).
  New helpers in `tests/stress-site/`: `deploy-three-apps.sh`,
  `exercise-apps.sh`, `compat-php.sh`, `loopback-tiers.sh`, `sweep-php.sh`.
- **Not changed (reported by the audit, left for a decision).**  Several
  active PHP-FPM versions each get the full worker pool; the PHP worker
  count is CPU-bound only, with no RAM ceiling on small hosts.


## 1.20.8 (2026-11-13)

Guest caches no longer replay another visitor's cookies (with
server-configs-nginx 1.6.23).

- **What was wrong.**  The XenForo and Chevereto guest caches stored the
  first visitor's `Set-Cookie` and sent it to every guest served from the
  cache: one shared `xf_csrf` on XenForo, one shared `PHPSESSID` (and
  `auth_token`) on Chevereto.  WordPress was not affected.
- **Config repository.**  `h5bp/php_xf.conf` and the new
  `h5bp/php_chev_cache.conf` serve cacheable guest requests from a named
  location that hides `Set-Cookie`; members, POSTs and no-cache URIs stay in
  an uncached PHP location with their cookies intact.
- **`setup.sh`.**
  - `--optimize`, `--domain` and the installer move a Chevereto vhost's
    server-level `include h5bp/php_chev.conf;` to
    `include h5bp/php_chev_cache.conf;` (the nested `/dashboard` include is
    left alone), and point a `php_xf.conf` include nested inside a location
    at `h5bp/php.conf`, because a named location is server-level only.  Only
    that one line of a deployed vhost changes; without the new files in the
    tree nothing is rewritten.
  - A Chevereto site that allows guest uploads (`guest_uploads = 1`, read
    with one SELECT from its settings table) keeps, or is returned to, the
    uncached include: a cached page cannot carry the visitor's upload token,
    and the first guest upload from it was rejected in testing.
    `SETUP_CHEV_GUEST_CACHE=1` forces the cache on, `=0` off.
  - The XenForo cache repair keeps `fastcgi_hide_header Set-Cookie;` in the
    named location.  A hand-written single-location `php_xf.conf` can not
    hide the header without breaking logins, so there `Set-Cookie` is removed
    from `fastcgi_ignore_headers` instead: a response that sets a cookie is
    simply not stored.
  - The cache error-policy tuner skips an include that has no cache, and
    covers `php_chev_cache.conf`.
- **XenForo config audit.**  A regression check for the `SV\RedisCache`
  array form (`$config['cache']['config'] = [ 'host' => ..., 'port' => 0 ]`).
- **Tests.**  25 new tuning checks (**668/668**, CLI/dry-run 173/173) and
  `tests/stress-site/guest-cache-cookie-test.sh`, 61 functional checks run
  from a workstation against the three applications; see
  `tests/stress-site/GUEST-CACHE-20261113.md`.

## 1.20.7 (2026-11-12)

Zero-warning fresh install, install/`--optimize` log-permission parity and a
correct XenForo config audit.  Found by a full install, `--optimize`,
`--domain`, `--upgrade-php` (8.5 -> 8.4 -> 8.5), `--diagnostics` and
`--restart-all` pass on a 16-thread / 28 GB / NVMe bare-metal Ubuntu 26.04.1
host with WordPress 7.1.4, XenForo 2.3.13 and Chevereto 4.5.9 deployed.

- **CPU governor without `cpufrequtils`.**  The package ships SysV init
  scripts only, so systemd logged `SysV service ... lacks a native systemd
  unit file ... expect removal soon` for `cpufrequtils` and `loadcpufreq` on
  every `daemon-reload` (104 journal warnings during one install), and apt
  printed two `update-rc.d` warnings.  The governor is now set by a native
  oneshot unit, `setup-cpu-governor.service`, plus one sysfs write per CPU at
  run time.  `--optimize` no longer installs any package for the governor.
  Hosts provisioned by 1.20.6 or older get the unit, and the SysV services
  this script installed are disabled (the package stays; the log says how to
  remove it).  `--purge` disables the new unit and restores the recorded
  governor as before.  `configs/system/cpufrequtils` is removed.
- **Elasticsearch logs are created 0640.**  The systemd drop-in gains
  `UMask=0027`.  Before, a fresh install left eight log files 0644 until the
  next `--optimize` tightened them (the only file-mode difference between
  install and `--optimize`), and each rotation reopened them 0644.
- **No false "tune not applied" warnings.**  `server-configs-nginx` already
  ships `fastcgi_keep_conn off`, so every fresh install logged six
  `tune not applied: no match for h5bp/php*.conf` warnings.  The rewrite now
  runs only where an old tree still has `on`.
- **XenForo config audit reads the live values.**  The parser took the first
  `$config['db']['host']` assignment (PHP keeps the last) and did not
  understand the array-literal `$config['cache']['config'] = [...]` form the
  XenForo manual uses, so a site with `p:localhost` and a Valkey socket was
  still reported as non-persistent with no cache backend, and the run ended
  with an "Application connection notices" warning.  Both forms are parsed
  now; WordPress `define()` keeps first-wins semantics.
- **`log_martians` survives the firewall and a reboot.**  ufw loads its own
  `/etc/ufw/sysctl.conf` on `ufw enable` and on every boot, after
  systemd-sysctl; its stock `log_martians=0` replaced the managed profile's
  `1`.  A re-install therefore ended with `0` while `--optimize` set `1`
  (three live sysctl values differed), and a reboot undid `--optimize`.  The
  shared sysctl step now aligns ufw's file with the managed value (recorded
  for `--purge`), so install, `--optimize` and a reboot agree.
- Fourteen new tuning checks cover the above; **643/643 tuning checks and
  173/173 CLI/dry-run checks pass** on the audit host.
- Measurements (unchanged tuning defaults, re-confirmed on three apps): see
  `tests/stress-site/TUNING-20261112-1.20.7.md`.

## 1.20.6 (2026-11-11)

Fix XenForo `MySQL query error [1020]: Record has changed since last read`
after `--optimize` on MariaDB servers.

- **Cause.**  The MariaDB base block wrote `innodb_snapshot_isolation = 1`.
  MariaDB 11.6.2+ enables snapshot isolation by default, and with it on,
  InnoDB rejects an UPDATE that touches a row changed by another transaction
  since the REPEATABLE READ snapshot with `ER_CHECKREAD` (1020).  XenForo 2.3
  does not treat 1020 as a retryable deadlock, so a concurrent reply failed
  in `Thread::updateForumRecord()` (`xf_forum`) even though the retry would
  have succeeded.  Ubuntu 26.04 ships MariaDB 11.8, so the failure surfaced
  after the database server was optimized.
- **Fix.**  Both the reference `configs/mariadb/mariadb_server.cnf` and the
  generated `50-server.cnf` base block now write
  `innodb_snapshot_isolation = 0`, restoring MySQL-compatible REPEATABLE READ
  (MariaDB's behaviour before 11.6.2).  An operator who wants the stricter
  snapshot isolation can override it in a later `.cnf` drop-in.
- `--optimize` detects the base-block change, validates the configuration
  with `mariadbd --help --verbose`, pauses the web frontends and restarts
  MariaDB once.  Verify with
  `mariadb -N -B -e 'SELECT @@innodb_snapshot_isolation'` (expect `0`).
- Two tuning checks assert the reference config and the generated block;
  **629/629 tuning checks and 173/173 CLI/dry-run checks pass**.

## 1.20.5 (2026-11-11)

Fix `--optimize` failing on Angie when an operator `http.d` file duplicates a
single-instance directive that the canonical tree also sets.

- **Symptom.**  On a live host, a custom `http.d/zz-site-e-ratelimit.conf`
  carried `limit_req_status 429` and `limit_req_log_level info`, while the
  synced `http.d/limit_req.conf` defines the same http-context directives.
  `angie -t` returned
  `[emerg] "limit_req_status" directive is duplicate in .../zz-site-e-ratelimit.conf:20`;
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
