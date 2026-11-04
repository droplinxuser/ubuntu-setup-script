# Security, performance and large-site review

This document is the audit and action list for the machine provisioned by
`setup.sh` 1.6.7. It combines the live configuration review with the stress
results in `tests/stress-site/RESULTS.md`.

The script now produces a solid single-host baseline. The remaining work is
mostly about identity/secrets, certificates, per-tenant isolation, backups,
monitoring and scaling beyond one 16-core machine.

---

## 0.1 1.6.7 live validation on a 16 vCPU / 30 GiB VPS

Validated on 2026-11-03 against a clean Ubuntu 26.04.1 VPS (16 vCPU, 30 GiB
RAM, 281 GiB ext4) with Angie, PHP 8.4 FPM plus a parallel PHP 8.3 pool,
MariaDB, Valkey, Elasticsearch, Node.js, GifSicle, WordPress, Lychee and
Pingvin running.

Key results (full table in `tests/stress-site/RESULTS.md`):

- 181k static req/s, 124k PHP-hello req/s, 26k MariaDB reads/s, 20.8k Valkey
  requests/s, 10.9k Elasticsearch searches/s, 22.2k Node proxy req/s.
- 169k req/s on the FastCGI-cached full-stack page; a 3-minute soak held
  165,855 req/s with no socket errors and p99 6.2 ms.
- Full-stack uncached soak: 6,486 req/s, p99 14.5 ms.
- WordPress guest page cache: 242 -> 9,972 req/s (p99 8.3 ms), with logged-in
  cookie and POST bypasses verified.
- Node cluster 4 -> 8 workers: +16% throughput. Valkey `io-threads 4` gave no
  gain over 1, so the default stays at 1.
- MariaDB: 146/400 connections used, zero slow queries or aborted connects.
  Valkey: zero rejected connections or evictions. Elasticsearch: green.

New issues found and fixed during the live run:

1. apt's `composer` package pulled unrelated PHP builds (php5.6-common and
   php8.5-cli) through virtual `php-cli`/`php-common` dependencies. Composer is
   now the official phar, run with the FPM-matched PHP binary.
2. `/usr/bin/php` could point at a CLI version different from FPM. The script
   now pins the alternative and restarts the matched FPM pool after
   Composer/CLI changes.
3. fail2ban could ban the operator during a long deploy. The SSH client address
   is now in `ignoreip` (read from the parent process environment or the
   established `:22` socket).
4. PHP-FPM sometimes returned `Unable to open primary script ... (Operation not
   permitted)` for files created after workers started. Restarting the pool
   clears it; app deploys must reload/restart FPM after syncing files.

---

## 0. 1.6.0 live validation on an 8 vCPU VPS

Validated on 2026-11-03 against a clean Ubuntu 26.04.1 VPS (8 vCPU, 15.1 GiB
RAM, 141 GB NVMe) with every service installed from `setup.sh` and the full
stress site running.

Versions: Angie 1.12.4, PHP 8.5.12, MariaDB 11.8.6, Valkey 9.0.4,
Elasticsearch 9.5.6, Node.js 26.13.0, GifSicle 1.96.

| Scenario | req/s | p50 | p90 | p99 | Client timeouts |
|---|---:|---:|---:|---:|---:|
| static (Angie only) | 94,056 | 0.45 ms | 2.45 ms | 5.32 ms | 0 |
| PHP hello + OPcache | 43,119 | 1.41 ms | 482 ms | 884 ms | 0 |
| MariaDB indexed read via PHP | 11,101 | 4.68 ms | 9.89 ms | 930 ms | 37 |
| Valkey via PHP | 15,947 | 3.70 ms | 5.25 ms | 1.26 s | 46 |
| Elasticsearch search via PHP | 2,350 | 17.2 ms | 31.6 ms | 181 ms | 5 |
| Node.js cluster proxy | 12,725 | 7.59 ms | 9.37 ms | 13.2 ms | 0 |
| Full stack, uncached, 200 clients | 2,525 | 22.3 ms | 35.1 ms | 67.0 ms | 24 |
| Full stack, FastCGI cache 5 s | 66,951 | 2.07 ms | 3.46 ms | 5.92 ms | 0 |
| Deliberate 1 s PHP sleep, 200 clients | 53.9 | 1.00 s | 1.00 s | 1.02 s | 0 |

What the live run proved:

1. **Caching is the single largest lever.** The same heavy page went from
   ~2.5k req/s uncached to ~67k req/s from Angie's FastCGI cache, with p99
   under 6 ms. Every guest-facing app should use page/object caching.
2. **The 8 vCPU host is CPU-bound during uncached PHP work.** `vmstat` showed
   ~49% user and ~49% system time and ~190k context switches/s during the PHP
   tests. The `wrk` client shares those cores, so its p99 is inflated;
   Angie's own access log showed p50 4.8 ms and only ~0.15% of requests above
   500 ms for the MariaDB page. Measure server-side `$request_time`/`$urt` for
   real p99, and generate load from a separate machine for final numbers.
3. **FastCGI over `/run/php/php-fpm.sock`** raised PHP hello throughput from
   ~39.7k to ~43.3k req/s (+10%) and removed the loopback TCP overhead.
4. **MariaDB thread pool vs one-thread-per-connection** made no material
   difference to server-side latency on this host (p50 ~4.5-5 ms, throughput
   ~11-12k/s, ~200 requests >500 ms in 10 s in both cases). Keep
   `pool-of-threads` for connection-memory efficiency; do not expect it to fix
   CPU saturation.
5. **Valkey was never the bottleneck**: zero rejected connections and zero
   evictions at ~40k commands/s in the suite.
6. **Elasticsearch 9.5 with a 4 GB heap** handled ~2.3k searches/s while
   sharing the host. It is the most memory- and CPU-expensive service; move it
   to its own node before traffic grows.
7. **Centralised logs worked**: Angie, PHP, MariaDB, Valkey, Node.js, GifSicle
   and Elasticsearch all wrote under `/var/www/logs/`, with no PHP warnings,
   no MariaDB slow queries and no Angie errors. MariaDB's AppArmor profile
   needed explicit `/var/www/logs/mariadb/** rw` rules; the script now adds
   them.

---

## 1. Measured baseline (this host)

16 vCPU (AMD Zen 4), 27 GiB usable RAM, NVMe, Ubuntu 26.04.1.

| Path | Result | Notes |
|---|---:|---|
| Angie static file | ~258k req/s | p99 3.4 ms |
| PHP hello / OPcache | ~117k req/s | no database work |
| MariaDB indexed read via PHP | ~27k req/s | p99 ~7.5 ms after thread pool + Unix socket |
| Valkey endpoint via PHP | ~29k req/s | Unix socket; p99 ~4 ms typical |
| Valkey direct set/get/incr | ~300k ops/s | p50 ~0.15 ms |
| Elasticsearch search via PHP | ~15.9k req/s | p99 ~5.9 ms |
| Node.js cluster proxy | ~30k req/s | 4 workers |
| Full stack, uncached | ~7.2k req/s | p50 14.9 ms, p99 22 ms |
| Full stack, FastCGI-cached 5 s | ~182k req/s | p99 2.9 ms |
| Deliberate 1 s PHP sleep, 200 clients | ~92 req/s | queue-bound; expected |

Key conclusions:

1. **Caching is the largest lever by far.** The same heavy page went from
   ~7.2k to ~182k req/s when served from Angie's FastCGI cache.
2. **The uncached ceiling is PHP worker occupancy plus CPU across PHP, MariaDB,
   Elasticsearch and Node**, not one broken service.
3. **Rate limiting was the hidden bottleneck** before 1.4.0. A loopback/client
   IP was capped at 30 GET/s and got `444` resets. Loopback is now exempt and
   external limits are 100 GET/s / 30 POST-HEAD/s with larger bursts.
4. **Unix sockets and the MariaDB thread pool removed most p99 tails.** TCP
   connection churn had produced 83k TIME_WAIT sockets against a 55k port
   range.
5. **Valkey I/O threads are counterproductive for small web commands.**
   `io_threads=1` beat 8 threads (6.5k vs 5.1k full-page req/s, 64% vs 430%
   CPU). Keep 1 unless `valkey-benchmark` proves otherwise.

---

## 2. Current configuration audit

### 2.1 Angie

Already good:

- `worker_processes auto`, `worker_cpu_affinity auto`, `pcre_jit on`,
  `sendfile`, `tcp_nopush`, `aio threads`, `reuseport`, `fastopen`.
- 65k connections/worker (~1M total here), `worker_rlimit_nofile 520000`,
  systemd `LimitNOFILE=524288`.
- `open_file_cache`, `gzip_static`, HTTP/2, TLS 1.2/1.3, HSTS.
- FastCGI keepalive 64, cache zones enabled, rate-limit zones enabled.
- Loopback exempt from rate limiting; `429` instead of `444` for rejects.
- TLS session tickets and 0-RTT early data disabled.

Recommended changes / additions:

- Replace the self-signed per-domain certificate in `/etc/angie/ssl/<domain>/`
  with ACME/Let's Encrypt. Angie has `http_acme` built in. Keep certificate
  files mode 600 and renew automatically.
- If the site is behind Cloudflare or another CDN, configure real IP first.
  Otherwise the limiter keys all traffic to the CDN address and will throttle
  legitimate users. Include the generated `cloudflare.conf` in the vhost and
  run `/etc/angie/scripts/cloudflare.sh` after IP range changes.
- Enable the per-IP connection cap in vhosts (`limit_conn perip 200;`) only
  when traffic is not behind a shared CDN IP; the zone is defined but not
  applied globally on purpose.
- Consider HTTP/3: add `listen 443 quic reuseport;`, an `Alt-Svc` header, and
  `ufw allow 443/udp`. Test clients first.
- Brotli/zstd are not compiled into the distro Angie package. Use
  `gzip_static on` (already enabled), precompress assets, or install an Angie
  build with those modules.
- Add a WAF at the edge (Cloudflare, Coraza/ModSecurity in front of Angie, or a
  separate reverse proxy). The embedded Naxsi/ngx_waf configs cannot be enabled
  on this Angie build.
- Angie access logs are disabled by default for performance (only
  `error_log` is written). If you need forensics or fail2ban web jails, enable
  a buffered per-vhost log (`access_log ... buffer=64k flush=5s;`) and ship it
  off-box; do not make it the default on a high-request site.
- Add `limit_req` to login/registration/password-reset endpoints with tighter
  rates than the general PHP limit.
- Use `client_max_body_size` per app. 100 MB is fine for XenForo/Lychee large
  uploads but too generous for a simple contact form.

### 2.2 PHP-FPM / PHP

Already good:

- PHP 8.5 with the XenForo profile: `fpm`, `cli`, `opcache`, `mysql`, `gd`,
  `curl`, `xml`, `zip`, `gmp`, `mbstring`, `redis`.
- OPcache/JIT settings in `custom_dan.ini` are active immediately because
  `php8.5-opcache` is installed. `intl`, `imagick`, `bcmath` and `apcu` are
  not installed; add them only if an add-on requires them.
- `memory_limit` 512 MB, realpath cache 16 MB, file cache under
  `/var/cache/php/opcache`.
- 108 static workers, `max_requests=16384`, `request_terminate_timeout=100s`,
  slow-request log at 5 s, `catch_workers_output=yes`.
- `expose_php=Off`, `allow_url_fopen=Off`, `cgi.fix_pathinfo=0`.
- Session hardening: strict mode, cookies only, HttpOnly, SameSite=Lax,
  48-character IDs.
- MariaDB Unix-socket defaults and `mysqlnd` statistics disabled.

Recommended changes:

- **Per-site isolation is the biggest remaining PHP gap.** Every domain uses
  the same `www-data` user and the same pool. One compromised PHP app can read
  every other site's files and `/etc`. Create one pool and Unix user per
  tenant, with `open_basedir` limited to that site and its session/tmp paths.
- Add `exec,shell_exec,proc_open,popen,pcntl_exec` to `disable_functions` where
  the app does not need them. Chevereto video processing and some WordPress
  plugins may need `exec`/`shell_exec`; test per app.
- Set `session.cookie_secure=1` once every vhost is HTTPS-only.
- For production, set `opcache.validate_timestamps=0` and reload PHP-FPM on
  deploy. Keep `revalidate_freq=60` if you prefer not to restart.
- Tune `children=` from measured RSS (`ps -o rss= -C php-fpm8.5`). On this host
  108 workers use ~26 MB each average (shared pages included); 160 workers did
  not raise uncached throughput and increased queueing. More workers help
  I/O-bound pages only until CPU saturates.
- Lower `memory_limit` per app where possible. Worst-case 512 MB × workers must
  fit in RAM; the worker formula assumes ~128 MB average.
- Use `pm=ondemand`/`dynamic` for many low-traffic sites instead of one large
  static pool; static is best for a single busy site.
- Add a PHP-FPM status endpoint restricted to localhost if you want monitoring
  (the test site does this; production should add it deliberately).
- Do not run Composer or WP-CLI as `www-data` with write access to the whole
  web root. Use deploy users and read-only release directories.

### 2.3 MariaDB

Already good:

- Auto buffer pool (11.1 GB here, 40% RAM), 4 instances, 1 GB log file,
  64 MB log buffer, 64 MB packet limit.
- Thread pool (`pool-of-threads`) for short web queries; p99 dropped from
  ~745 ms to ~9 ms in the stress test.
- `innodb_flush_log_at_trx_commit=2`, `innodb_snapshot_isolation=1`,
  `skip_name_resolve=1`, `secure_file_priv`, `local_infile=0`.
- Slow query log with query plan/explain, 1 s threshold, 100-row minimum.
- NVMe-aware I/O capacity; read/write threads capped 64.
- 400 max connections, 64 thread cache, 600 s wait timeout.
- Systemd `LimitNOFILE=1048576`, AppArmor bootstrap fix, embedded backups.

Recommended changes:

- **Create per-application users** limited to their own database and required
  privileges. The setup `demo` user has `ALL ... WITH GRANT OPTION` and is used
  by the backup job. Do not put that account in XenForo/WordPress config.
- Rotate the demo/admin password; it is written to `/etc/mysqlbkup.cnf`.
- Enable binary logs (`log_bin`, `binlog_format=ROW`,
  `binlog_expire_logs_seconds`) if you need point-in-time recovery. This adds
  write I/O; test it.
- Keep `bind-address=127.0.0.1` for a single host. For remote access use
  explicit addresses, TLS (`require_secure_transport=ON`), UFW source rules and
  per-client accounts. Never open 3306 broadly.
- Use `innodb_flush_log_at_trx_commit=1` for financial/critical data.
- Monitor `Threads_running`, `Max_used_connections`, `Aborted_connects`,
  `Innodb_buffer_pool_wait_free`, `Innodb_log_waits`, `Created_tmp_disk_tables`
  and slow queries. Add indexes before raising buffers.
- Configure encrypted off-site backups and test restores. A local dump on the
  same NVMe is not disaster recovery.
- At scale, use a read replica or separate database host; the thread pool is
  tuned for short OLTP queries, not long analytics.

### 2.4 Valkey

Already good:

- Loopback bind, `protected-mode yes`, Unix socket mode 770, `www-data` in the
  `valkey` group.
- `maxmemory` 10% RAM (2.7 GB here), `allkeys-lru`, `maxmemory-samples 10`.
- `io_threads=1`, `tcp-backlog 65535`, `maxclients 20000`, lazy-free enabled.
- No persistence (`save ""`, `appendonly no`) — correct for a cache.
- No evictions/rejections during the stress suite.

Recommended changes:

- Use Valkey as an **object cache** (XenForo Redis cache, WordPress Redis
  Object Cache, Lychee cache) and point apps at the Unix socket. This removes
  most database read load.
- `allkeys-lru` can evict sessions. Use `volatile-lru` with TTLs or a separate
  instance/policy for sessions, queues and locks. If data must survive, enable
  AOF and choose `noeviction` for that instance.
- Add ACL users per application if several apps share the instance; do not give
  every app the default user.
- For remote Valkey, enable TLS and ACLs; do not expose 6379. The current
  config is loopback-only.
- Monitor `used_memory`, `evicted_keys`, `rejected_connections`,
  `keyspace_hits/misses`, `instantaneous_ops_per_sec` and latency.

### 2.5 Elasticsearch

Already good:

- 4 GB locked heap, G1GC, `bootstrap.memory_lock`, `vm.max_map_count`.
- Single-node discovery, 1 shard/0 replicas suitable for a small local index.
- `indices.query.bool.max_clause_count=4096`, `search.max_buckets=65536`,
  index buffer 20%, fielddata cache 20%.
- `action.destructive_requires_name`, HTTP compression, 200 MB content limit.
- No thread-pool rejections or GC problems in the stress run.

Recommended changes:

- **Security is disabled.** Keep `host=localhost` and never expose 9200/9300.
  For any non-loopback host, enable `xpack.security.enabled`, TLS,
  authentication and a firewall. The script warns but does not enable it.
- Configure snapshots to an external repository (S3/NFS) and test restores.
  ES data is not covered by the MariaDB backup.
- Use ILM for time-based indices and avoid oversharding. For a large XenForo
  search index, size shards from data volume, not a fixed 1/0 forever.
- Watch JVM heap, GC pauses, thread-pool rejections, disk watermarks and
  search latency. At scale, use a dedicated search node/cluster.
- Tune `refresh_interval` for bulk imports (e.g. `-1`, then restore) and use
  the bulk API with reasonable batch sizes.
- The 4 GB heap is right for this 27 GiB host; keep it ≤50% RAM and below the
  compressed-oops threshold.

### 2.6 Node.js / Pingvin and other Node apps

Already good:

- NodeSource 26.x, `node`/`npm`, 4-worker cluster test service, keepalive
  timeouts, systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp`), `LimitNOFILE=524288`.

Recommended changes:

- The script installs Node.js and can generate an `app=node` vhost, but it does
  not deploy your Node app. Run it under systemd (or PM2) as a non-root user,
  with a read-only release directory and environment-based secrets.
- Put Node behind Angie with keepalive, WebSocket support and a health check.
  For local-only traffic, a Unix socket between Angie and Node avoids TCP
  connection churn.
- Use `cluster`/worker threads for CPU-bound Node apps; keep the event loop
  free of synchronous work.
- Add `NODE_ENV=production`, `--max-old-space-size` sized to the host, and
  memory/restart limits. Monitor event-loop lag and RSS.
- Pingvin needs its frontend/API ports (3030/8080 in the sample template).
  Change the generated vhost to match your actual ports.

### 2.7 Host, firewall and operations

Already good:

- UFW default deny incoming, allow outgoing; 22 limited, 80/443 allowed.
- fail2ban SSH jail using UFW; unattended security updates; sysstat history.
- BBR/fq, large connection backlogs, file-max/nr_open, security sysctls,
  protected links/symlinks/fifos/regular files.
- Performance CPU governor on this dedicated server.
- 50%-of-RAM swap policy; existing swap partition preserved.
- MariaDB/Valkey/Angie/Elasticsearch systemd nofile drop-ins.

Recommended changes (priority order):

1. **Replace self-signed certificates with ACME/Let's Encrypt** and automate
   renewal. Verify renewal with `angie -t` and a reload hook.
2. **Harden SSH**: keys only, disable password/root login, restrict source
   addresses if possible, keep fail2ban, and remove unused UFW rules. This host
   currently also has mDNS (`5353/udp`) and WS-Discovery (`3702/udp`) open;
   remove them unless you need them.
3. **Secrets and database users**: rotate the demo password, create per-app
   users, store secrets outside the web root, and never commit them.
4. **Backups**: encrypted off-site MariaDB dumps, ES snapshots, and a tested
   restore procedure. Keep the local backup as a second copy, not the only one.
5. **Monitoring/alerting**: node_exporter + Prometheus/Grafana (or Netdata),
   blackbox probes for each vhost, log shipping, and alerts on 5xx, p99, queue
   depth, disk, RAM, GC and replication. `--others sysstat` gives local history
   but not alerting.
6. **Logging**: optional per-vhost buffered access logs, PHP slow log, MariaDB slow log,
   ES/Valkey metrics. Rotate and ship them. Protect logs from web users.
7. **Per-tenant isolation** for PHP (pools/users/open_basedir) and file
   permissions. This is the main shared-hosting risk.
8. **WAF/edge protection**: Cloudflare or a local WAF; rate-limit login,
   registration, search and API endpoints; add bot management if needed.
9. **Patch policy**: unattended security updates are enabled; review held-back
   packages (currently `libgd3`) and reboot-required. Consider livepatch.
10. **Remove test artifacts** from production: `stress.invalid`, its `/etc/hosts`
    entry, the `stress-node` service, test databases and the test certificates.

---

## 3. Large-site architecture

For anything beyond a single 16-core host, scale in this order:

1. **CDN + edge cache** for static assets and anonymous HTML. This removes most
   requests before they reach Angie.
2. **Angie FastCGI/proxy microcaching** for guest pages and API GETs. Bypass on
   session/auth cookies and set `Cache-Control`/`Vary` correctly.
3. **Valkey object cache** for XenForo/WordPress/Lychee; use Unix sockets or a
   local persistent connection pool.
4. **MariaDB tuning + indexes + read replicas**; use ProxySQL or a connection
   pool if connection churn remains. Move analytics/reporting to a replica.
5. **Elasticsearch cluster** with proper shard sizing, replicas, ILM and
   snapshots; do not run heavy search on the same node as the database once
   traffic grows.
6. **Multiple Angie/PHP nodes** behind a load balancer; share sessions via
   Valkey, store uploads on shared/object storage, and deploy releases
   atomically.
7. **Observability and load testing** at every step. The included stress harness
   is deliberately local and synthetic; use realistic traffic mixes, cache hit
   ratios and think times before sizing production.

Do not tune by copying numbers from another host. Measure RSS, CPU, queue depth
and p99 on your workload, then change one variable at a time.

---

## 4. Reproduce the tests

```bash
# From the repository, on a machine already provisioned by setup.sh
sudo bash tests/stress-site/setup-stress-site.sh
sudo bash tests/stress-site/run-stress.sh /tmp/stress-report.md
```

The test site is available at `https://stress.invalid/` (self-signed certificate),
with `/cached.php` for the FastCGI-cache comparison and `/nginx-status` /
`/fpm-status` restricted to localhost. Remove it from production.
