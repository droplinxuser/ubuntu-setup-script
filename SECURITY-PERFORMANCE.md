# Security and performance review

What a host built or tuned by `setup.sh` 1.22.0 already has, what it
deliberately leaves to the operator, and how to scale past one machine. The
measurements behind the defaults are in `tests/stress-site/RESULTS.md`; the
per-option details are in `README.md`.

1.22.0 changes the base of the stack. nginx, PHP (FPM and CLI) and Valkey are
no longer packages: each is compiled from upstream source on the host, with
hardening flags, and then optimised by LLVM BOLT from live traffic. nginx
(latest mainline) replaces Angie. MariaDB and Elasticsearch stay apt
packages; compiling them was measured in 1.21.71 and was not worth it.
Existing hosts move to the compiled services once, through `--optimize`
(section 3).

## 1. What the script delivers

| Layer | In place |
|---|---|
| nginx | compiled from nginx.org mainline (1.31.10 at release) with OpenSSL, PCRE2 and zlib-ng linked statically and Brotli built in; lean module set (no mail, stream, DAV, SSI, sub, uwsgi/scgi/grpc, memcached, `limit_conn`, ...); branding stripped in the source (section 2); `worker_processes`/connections/rlimit from the hardware, HTTP/2, HTTP/3, TLS 1.2/1.3 with HSTS, Brotli 5 + gzip, FastCGI/proxy cache zones sized to RAM and disk with `min_free` headroom, a login brute-force limiter (below), guest full-page caches for WordPress/XenForo/Chevereto/Flarum whose cookie rule is default-deny (an unknown cookie is never a guest page; analytics, consent and CDN cookies are the allowlist), immutable asset locations, dotfile/`wp-config.php`/`xmlrpc.php` denies, no PHP from upload directories, `auth_basic` compiled in, access log off, error log under `/var/www/logs/nginx` |
| Login limiter | the only request limit: login, registration and password-reset POSTs, 20 a minute per address after a burst of 10, IPv6 per /64, loopback exempt, `429` on reject, logged at `info` so a flood cannot fill the disk; the generic per-IP limits were removed in 1.21.71 and `limit_conn` is not built |
| PHP-FPM / CLI | compiled from php.net (any released version, never RC/alpha/beta), FPM and CLI from one tree, extensions linked statically: a base set plus what each detected application needs (WordPress, XenForo, Chevereto, generic PHP), `--php ext=` for more; detection only adds, never removes; static pool, 1.0 worker per logical CPU with a local database on flash (1.5 on a VPS or with a remote database, 2.0 on HDD), Unix socket `www-data` 0660, OPcache, tracing JIT always on (`SETUP_PHP_JIT_WORDPRESS=0` exempts WordPress roots), slow log 10 s, worker recycling, `expose_php=Off`, `PATH_TRANSLATED` and `open_basedir` leak repairs; opt-in session/cgi hardening (`SETUP_PHP_SESSION_HARDENING=1`) |
| PHP sessions | `/var/lib/php/sessions`, owned by the pool user (`www-data`) with mode 0700; PHP collects expired sessions itself (`gc_probability=1`, `gc_divisor=1000`), so Debian's `phpsessionclean` timer is gone; a pool that runs as another user gets its own `/var/lib/php/sessions-<user>` (0700) |
| MariaDB | buffer pool (data+5%) and redo log from live data, thread pool, NVMe/SSD/HDD I/O capacity, connections from the PHP pool, `skip_name_resolve`, `secure_file_priv`, `local_infile=0`, loopback bind, slow/error logs, AppArmor fix, systemd fd limit, embedded backup job (30 dumps) and `mysqltuner.pl`, config validated before every restart |
| Valkey | compiled from source; loopback + `protected-mode`, Unix socket 770 with `www-data` in the group, cache-only persistence, `maxmemory` = working set +20% (128 MB minimum; RAM floor only on a fresh install), `allkeys-lru`, `io-threads 1`, lazy-free, online `CONFIG SET` tuning; a host whose data is persisted stays on the series that wrote it |
| Elasticsearch | loopback bind, locked heap = store/4 (512 MB..25% RAM..31 GB), bounded search/write thread pools, single-node replica fix, `vm.max_map_count`, memlock/fd limits |
| Host | DNS drop-in, performance governor on dedicated hardware, BBR + fq, hardware-scaled backlogs/conntrack/dirty bytes/`min_free_kbytes`, 1M-nofile limits, THP `madvise`, per-device I/O scheduler, swap policy, UFW (deny in, `ufw limit` SSH, 80/443), `unattended-upgrades`, managed cron (ownership repair that skips logs, backups, Cloudflare IPs, wp-cron), logrotate for `/var/www/logs`; hosts under 4 GB RAM get nginx only |
| WordPress | `wp-config.php` 640, file-edit/mods constants, WP-Cron moved to cron, salts, per-database user split, webshell quarantine, world-writable and archive reports |
| Operations | `--diagnostics` bundle with redaction and a read-only builds section (versions, CPU match, timers, last build logs), `--restart-all` in dependency order, `--optimize` report with rollback per service, `--purge` (removes our units, builds and links; never the backups) |

Every value comes from one helper shared by the installer and `--optimize`,
and a fresh install followed by `--optimize` is byte-identical.

## 2. Builds: hardening, supply chain, units

### Compiler hardening

nginx, PHP and Valkey are built with clang from apt.llvm.org at `-O3
-march=native`, with the hardening Ubuntu's own gcc enables by default and
upstream clang does not:

- `-fstack-protector-strong`, `-fstack-clash-protection`
- `-D_FORTIFY_SOURCE=3`
- `-fcf-protection=full` on x86_64 (`-mbranch-protection=standard` on arm64)
- full RELRO (`-z relro -z now`)

The measured cost was 0.5-2 % before BOLT (1.21.70).

BOLT rewrites each binary from a perf sample of real traffic. Until 1.21.71
it ran with `-use-gnu-stack`, which turned the `PT_GNU_STACK` header into the
new code segment; without that header Linux gives the process an executable
stack. 1.22 no longer passes that option, and `bolt_stack_check`
(`tools/build-common.sh`) refuses to install any BOLT output whose
`GNU_STACK` header is not `RW`. A BOLT run on an idle server (no traffic yet)
is skipped with "too little traffic", not reported as an error.

### Branding stripped

Before `configure`, the nginx source is patched so that no response names the
server:

- no default `Server` header on HTTP/1.1, HTTP/2 and HTTP/3;
- error pages end with `</body></html>`, without the `<hr><center>nginx` line.

Each patch is counted. When a new mainline moves a patched line, the build
uses the newest version the patch is known to apply to (`NGINX_FALLBACK` in
`nginx-build.conf`, or this host's last patched build) and reports it; the
daily refresh keeps the running binary. The verify step starts the candidate
on 127.0.0.1 with `server_tokens on` and checks that neither the headers nor
the body of a 404 or 502 contain "nginx", so the patch is tested, not the
config. PHP is built with `expose_php=Off`, so there is no `X-Powered-By`
either. `SERVER_SOFTWARE` stays `nginx` (no version) in `fastcgi.conf`:
WordPress uses it to detect nginx, and it is never sent to clients.

Checked on a fresh install on the Xeon E-2236 test host: no `Server` or
`X-Powered-By` header, and the 404 page contains no "nginx".

### Supply chain

Every source archive is verified before it is unpacked. A failed check stops
the build; the running service keeps serving.

| Source | Check |
|---|---|
| nginx | PGP signature against the nginx.org release keys pinned in `tools/build-common.sh` (primary key fingerprint must match); `gpgv` in a throwaway home; fail closed, no trust-on-first-use |
| PHP | php.net SHA-256; the php-src GitHub tag snapshot (second source) is pinned on first use; only released versions |
| Valkey | SHA-256 from the Valkey project's `valkey-hashes` repository; a mismatch stops the build; pinned on first use only when that repository is unreachable (reported) |
| Other libraries | the upstream's published checksum where one exists, otherwise pinned on first use: the same file name must always hash the same |
| Project mirror | last source only; a file from it must match the upstream checksum, the hash pinned on this host, or the mirror's `SHA256SUMS`; without one of the three it is refused; for nginx the mirror must carry the `.asc` and it is verified the same way. `SETUP_BUILD_MIRROR=off` disables it |

Source archives stay in `/var/cache/setup-*-build` with their recorded
hashes, so a rebuild after a CPU change runs offline with the exact versions
in `build.info`.

### Units

| Unit | Hardening |
|---|---|
| `nginx.service` | runs the binary from `/usr/local/lib/setup-nginx`, never a dpkg-owned path; `ExecStartPre` = CPU gate + `nginx -t`; `LimitNOFILE=524288`, `UMask=0027`; no `Restart=`, so a failed gate does not loop |
| `phpX.Y-fpm.service` | `Type=notify`; `ExecStartPre` = CPU gate + `php-fpm -t`; `LimitCORE=0`, `UMask=0027`, `KillSignal=SIGQUIT` (workers finish their request), `TimeoutStopSec=15`; only the active version is enabled and owns the shared socket |
| `valkey-server.service` | the Debian/Ubuntu unit's sandbox plus more: `User=valkey`, `ProtectSystem=strict` with `ReadWritePaths` limited to its data, logs, runtime and config, `NoNewPrivileges`, `CapabilityBoundingSet=CAP_SYS_RESOURCE`, `MemoryDenyWriteExecute`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `RestrictNamespaces`, `SystemCallArchitectures=native`, `NoExecPaths=/` with `ExecPaths` limited to its own binaries and `/usr/lib` `/lib` (without the library trees `ld.so` cannot map libc), `LimitCORE=0` |

The nginx and PHP units are not sandboxed beyond this: their master processes
run as root, and the workers as `www-data`.

**CPU change.** Every build records a CPU fingerprint (vendor, model and the
ISA flags `-march=native` can use). If it no longer matches, the unit does not
start: it queues `setup-build-cpu.service`, which rebuilds nginx, then the
active PHP, then Valkey, offline, and starts each one on success. This is an
operator rule: a service stays down rather than run a binary that may die on
an illegal instruction. The PHP CLI can fail the same way until the chain
finishes.

**Refreshes.** The daily timer rebuilds in the background; the running binary
serves until the new one passes verify. nginx is swapped by an in-place
binary upgrade (no restart); PHP and Valkey restart.

## 3. Migration from 1.21 (one time, `--optimize`)

On a 1.21 host with Angie, Sury PHP or the `valkey-server` package,
`--optimize` builds the compiled services while the old ones serve, then
switches each part (nginx, PHP, Valkey) over separately.

- **Survives a lost SSH session.** The migration runs as a transient systemd
  unit (`setup-migrate-1.22`) and logs to `/var/log/setup-migrate-1.22.log`;
  the caller only follows the log. A rerun while it runs attaches to the log.
- **Resumable.** State is kept per step in `/var/lib/setup.sh/migrate-1.22`;
  an interrupted run resumes. A part that was blocked or rolled back is
  retried when a newer release changed the migration code (a digest of it is
  recorded) or the host changed, or with `SETUP_MIGRATE_RETRY=1`.
- **Rollback per part.** If the new nginx, PHP or Valkey fails its checks
  (config test, socket, PING, an HTTP request to every vhost), that part is
  rolled back and the old service keeps serving. The other parts go on.
- **Purges only after the new services serve.** Old packages are removed only
  for parts that passed. Each removal is simulated first (`apt-get -s`) and
  skipped if it would take any package outside an exact list;
  `libapache2-mod-php*` is never in the list. The `valkey-server` package is
  removed, not purged (its purge script can delete the data and the `valkey`
  user).
- **Maintainer scripts cannot stop our units.** Removals run under a
  temporary `policy-rc.d` that denies only our unit names; it is removed by a
  trap and by any later run.
- **Manual rollback stays possible.** The removed packages' `.deb` files, the
  repository sources and the old `/etc/angie`, `/etc/php` and `/etc/valkey`
  trees are kept in `/var/backups/setup-1.22` (mode 0700, root). `--purge`
  never deletes them.
- **Ends with a check.** All our units are enabled at the end and the script
  asserts `is-enabled` = `enabled`.
- **What changes in configs.** Angie ACME vhosts are moved to the host's
  self-signed origin certificate; vhosts not behind Cloudflare are listed in
  a warning block. Directives of modules the build leaves out (for example
  `sub_filter`, `limit_conn`) are commented out with a marker and reported;
  `limit_conn` is reported as a removed security control. Any other blocker
  stops the nginx part with a report, and Angie keeps serving.
- **What is kept.** The PHP build keeps every extension the old Sury PHP
  loaded, in addition to what the applications need.

Tested on the Xeon E-2236 test host: a 1.21.71 host (Angie, Sury PHP 8.5, the
`valkey-server` package, three applications, an Angie ACME vhost and an
`auth_basic`/`sub_filter` vhost). The test found three nginx cutover bugs;
each time Angie kept serving automatically, and all three are fixed. After the
fixes: security 78/78, cookie 105/105, functional walk 0 failures, and after a
reboot nginx, PHP-FPM and Valkey active and enabled, no failed units, every
site 200. A second `--optimize` found nothing to migrate.

## 4. What is left to the operator (priority order)

1. **Certificates.** The compiled nginx has no ACME module. Behind
   Cloudflare in Full mode, vhosts use the host's self-signed origin
   certificate. For Full (strict), or for a vhost that clients reach
   directly, install a CA-signed certificate (a CDN origin certificate or an
   ACME client of your choice) and automate renewal.
2. **SSH and brute force.** Keys only, no root/password login, fail2ban or
   provider protection; the script only rate-limits SSH in UFW and reports
   password authentication.
3. **Secrets and database users.** Rotate the setup admin password; give
   every application its own database user without `GRANT OPTION` (the
   WordPress split is automatic, XenForo and custom apps are manual).
4. **Backups and restores.** The local dump is a second copy, not disaster
   recovery: encrypted off-site MariaDB dumps, Elasticsearch snapshots to an
   external repository, tested restores, binary logs if point-in-time
   recovery is required.
5. **Monitoring and alerting.** node_exporter/Netdata, blackbox probes per
   vhost, log shipping, alerts on 5xx, p99, PHP listen queue, disk, RAM, GC,
   and on a service that stays down after a CPU change; `--others sysstat`
   gives local history only.
6. **Per-tenant isolation.** Every domain shares the `www-data` pool. Use one
   pool and user per tenant with `open_basedir` set in that pool (never via
   `fastcgi_param PHP_ADMIN_VALUE`, which sticks to the worker); such a pool
   gets its own session directory automatically. Extend `disable_functions`
   where no app needs process execution. Add systemd sandboxing to the nginx
   and PHP units with a drop-in if your applications allow it.
7. **Edge protection.** A CDN/WAF in front (Cloudflare with the real-IP
   config enabled first, or every visitor behind it shares one limiter key),
   rate limits on search and API endpoints, bot management if needed.
8. **Exposure.** Keep MariaDB, Valkey and Elasticsearch on loopback. For
   remote access use explicit addresses, TLS (`require_secure_transport`,
   X-Pack security, Valkey ACLs/TLS) and UFW source rules. Remove any
   pre-existing mDNS/WS-Discovery rules you do not need.
9. **Data durability.** `innodb_flush_log_at_trx_commit=1` for financial
   data; AOF plus `noeviction`/`volatile-lru` (or a separate instance) when
   Valkey holds sessions, queues or locks.
10. **Hygiene.** Remove the `stress.invalid` site, test databases and test
    certificates from production; review held-back packages and
    reboot-required; `opcache.validate_timestamps=0` with a reload on deploy;
    once the host is stable, prune `/var/backups/setup-1.22` yourself.

## 5. Large-site architecture

Scale in this order, measuring RSS, CPU, queue depth and p99 on the real
workload after every step; do not copy numbers from another host.

1. CDN and edge cache for static assets and anonymous HTML.
2. nginx FastCGI/proxy microcaching for guest pages and API GETs (bypass on
   session/auth cookies, correct `Cache-Control`/`Vary`). Caching is the
   largest lever measured: the same page went from ~7k to ~180k req/s.
3. Object cache (Valkey over the Unix socket) where it beats the database;
   on a single host with local MariaDB, XenForo's registry/session cache in
   MariaDB was 37% faster than Redis.
4. MariaDB indexes, thread pool and read replicas; ProxySQL or a pool if
   connection churn remains; analytics on a replica.
5. Elasticsearch on its own node/cluster with shard sizing, replicas, ILM and
   snapshots.
6. Multiple nginx/PHP nodes behind a load balancer, sessions in Valkey (the
   file sessions above are per host), uploads on shared/object storage,
   atomic releases.
7. Load-test each step with a realistic traffic mix; the included harness is
   synthetic.

### Why nginx and not Angie

Compiled nginx 1.31.10 against compiled Angie 1.12.5, same flags, libraries,
modules and files, 5 rotated rounds on the Xeon E-2236 test host: cached
pages +0.5 to +1.5 % for nginx (XenForo home 123,007 against 121,482 req/s);
PHP pages tie.

### Alternative PHP application servers (evaluated, not adopted)

FrankenPHP, Swoole and RoadRunner were assessed against the XenForo and
WordPress profiles this repository deploys. These measurements predate 1.22
(packaged PHP-FPM 8.4).

- **FrankenPHP 1.13.5** (PHP 8.5.12, classic mode, same document root and
  database, loopback TLS, 16 threads) served the XenForo member page at
  **688 req/s with 21.7 ms of host CPU per request**, against **852 req/s and
  17.4 ms** for the web server + PHP-FPM 8.4 with 16 static workers on the
  same host. 32 FrankenPHP threads reached 702 req/s at 22.7 ms. It is a
  single static binary with the required extensions (mysqli, pdo_mysql,
  redis, OPcache, gd, intl), so the test is reproducible, but it is 17-19%
  slower here and it replaces the FastCGI cache, Brotli/gzip, rate limiting
  and HTTP/3 setup nginx already provides. Its worker mode is not usable for
  these applications: XenForo and WordPress keep per-request state in
  superglobals and bootstrap their container on every request, so a
  long-lived worker leaks state between visitors unless the application is
  rewritten.
- **Swoole** requires coroutine-aware database/cache clients and a rewritten
  request lifecycle; neither XenForo nor WordPress core is coroutine-safe, and
  their plugin ecosystems assume one request per process. It would only apply
  to a bespoke service, not to the applications this script installs.
- **RoadRunner** needs a PSR-7 worker and a request/response bridge. Community
  WordPress bridges exist but are experimental and break plugins that read
  `$_SERVER`/`$_SESSION` or register shutdown functions; XenForo has no
  maintained bridge.

The measured bottleneck on the audit host is CPU in PHP userland plus MariaDB
(15-16 ms + 3 ms per member request), not the FastCGI hop (0.3 ms). Changing
the SAPI does not remove that work; the levers that do are the guest cache
(5-10x on anonymous traffic), the tracing JIT (~3-5%), the native build with
BOLT, and the pool depth and MariaDB profile documented above.

## 6. Reproduce the measurements

```bash
sudo bash tests/stress-site/setup-stress-site.sh        # synthetic site at https://stress.invalid/
sudo bash tests/stress-site/run-stress.sh /tmp/report.md # loopback suite (wrk)
bash tests/stress-site/run-stress-remote.sh 192.0.2.10 stress.invalid /tmp/remote.md   # from a workstation (oha); use your server's address
```

For a remote run, pair it with `sudo bash tests/stress-site/collect-metrics.sh /tmp/metrics.log 5`
on the server, and remove the test site afterwards.
