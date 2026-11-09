# Security and performance review

What a host built or tuned by `setup.sh` 1.12.0 already has, what it
deliberately leaves to the operator, and how to scale past one machine. The
measurements behind the defaults are in `tests/stress-site/RESULTS.md`; the
per-option details are in `README.md`.

## 1. What the script delivers

| Layer | In place |
|---|---|
| Angie | `worker_processes`/connections/rlimit from the hardware, HTTP/2, TLS 1.2/1.3 with HSTS, Brotli 5 + gzip, FastCGI/proxy cache zones sized to RAM and disk, per-IP rate limiting (loopback and `SETUP_LIMIT_REQ_EXEMPT` exempt, `429` on reject, logged at `info`), guest full-page caches for WordPress and XenForo with cookie/method/URI bypass maps, immutable asset locations, dotfile/`wp-config.php`/`xmlrpc.php` denies, no PHP from upload directories, access log off, error log under `/var/www/logs/angie` |
| PHP-FPM | static pool sized to CPU/RAM (4 per core on CPU-bound XenForo/WordPress hosts), Unix socket, OPcache 128-512 MB, JIT off unless `SETUP_PHP_JIT` (WordPress roots stay off), slow log 10 s, worker recycling, `LimitNOFILE=524288`, `UMask=0027`, `expose_php=Off`, `PATH_TRANSLATED` and `open_basedir` leak repairs; opt-in session/cgi hardening |
| MariaDB | buffer pool and redo log from live data, thread pool, NVMe/SSD/HDD I/O capacity, connections from the PHP pool, `skip_name_resolve`, `secure_file_priv`, `local_infile=0`, loopback bind, slow/error logs, AppArmor fix, systemd fd limit, embedded backup job (30 dumps) and `mysqltuner.pl`, config validated before every restart |
| Valkey / Redis | loopback + `protected-mode`, Unix socket 770 with `www-data` in the group, cache-only persistence, `maxmemory` from the working set with a RAM floor, `allkeys-lru`, `io-threads 1`, lazy-free, online `CONFIG SET` tuning |
| Elasticsearch | loopback bind, locked heap = store/4 (512 MB..25% RAM..31 GB), bounded search/write thread pools, single-node replica fix, `vm.max_map_count`, memlock/fd limits |
| Host | DNS drop-in, performance governor on dedicated hardware, BBR + fq, hardware-scaled backlogs/conntrack/dirty bytes/`min_free_kbytes`, 1M-nofile limits, THP `madvise`, per-device I/O scheduler, swap policy, UFW (deny in, `ufw limit` SSH, 80/443), `unattended-upgrades`, managed cron (ownership repair that skips logs, backups, Cloudflare IPs, wp-cron), logrotate for `/var/www/logs` |
| WordPress | `wp-config.php` 640, file-edit/mods constants, WP-Cron moved to cron, salts, per-database user split, webshell quarantine, world-writable and archive reports |
| Operations | `--diagnostics` bundle with redaction, `--restart-all` in dependency order, `--optimize` report with rollback per service, `--purge` that never deletes |

Every value comes from one helper shared by the installer and `--optimize`,
and a fresh install followed by `--optimize` is byte-identical.

## 2. What is left to the operator (priority order)

1. **Certificates.** Replace the self-signed per-domain certificates with
   ACME (`http_acme` is built into Angie) and automate renewal.
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
   vhost, log shipping, alerts on 5xx, p99, PHP listen queue, disk, RAM, GC;
   `--others sysstat` gives local history only.
6. **Per-tenant isolation.** Every domain shares the `www-data` pool. Use one
   pool and user per tenant with `open_basedir` set in that pool (never via
   `fastcgi_param PHP_ADMIN_VALUE`, which sticks to the worker), extend
   `disable_functions` where no app needs process execution.
7. **Edge protection.** A CDN/WAF in front (Cloudflare with the real-IP
   config enabled first), tighter `limit_req` on login, registration, search
   and API endpoints, bot management if needed.
8. **Exposure.** Keep MariaDB, Valkey and Elasticsearch on loopback. For
   remote access use explicit addresses, TLS (`require_secure_transport`,
   X-Pack security, Valkey ACLs/TLS) and UFW source rules. Remove any
   pre-existing mDNS/WS-Discovery rules you do not need.
9. **Data durability.** `innodb_flush_log_at_trx_commit=1` for financial
   data; AOF plus `noeviction`/`volatile-lru` (or a separate instance) when
   Valkey holds sessions, queues or locks.
10. **Hygiene.** Remove the `stress.invalid` site, test databases and test
    certificates from production; review held-back packages and
    reboot-required; `opcache.validate_timestamps=0` with a reload on deploy.

## 3. Large-site architecture

Scale in this order, measuring RSS, CPU, queue depth and p99 on the real
workload after every step; do not copy numbers from another host.

1. CDN and edge cache for static assets and anonymous HTML.
2. Angie FastCGI/proxy microcaching for guest pages and API GETs (bypass on
   session/auth cookies, correct `Cache-Control`/`Vary`). Caching is the
   largest lever measured: the same page went from ~7k to ~180k req/s.
3. Object cache (Valkey over the Unix socket) where it beats the database;
   on a single host with local MariaDB, XenForo's registry/session cache in
   MariaDB was 37% faster than Redis.
4. MariaDB indexes, thread pool and read replicas; ProxySQL or a pool if
   connection churn remains; analytics on a replica.
5. Elasticsearch on its own node/cluster with shard sizing, replicas, ILM and
   snapshots.
6. Multiple Angie/PHP nodes behind a load balancer, sessions in Valkey,
   uploads on shared/object storage, atomic releases.
7. Load-test each step with a realistic traffic mix; the included harness is
   synthetic.

## 4. Reproduce the measurements

```bash
sudo bash tests/stress-site/setup-stress-site.sh        # synthetic site at https://stress.invalid/
sudo bash tests/stress-site/run-stress.sh /tmp/report.md # loopback suite (wrk)
bash tests/stress-site/run-stress-remote.sh SERVER_IP stress.invalid /tmp/remote.md   # from a workstation (oha)
```

Run the server with `SETUP_LIMIT_REQ_EXEMPT=<workstation IP>` before a remote
run, pair it with `sudo bash tests/stress-site/collect-metrics.sh /tmp/metrics.log 5`
on the server, and remove the test site afterwards.
