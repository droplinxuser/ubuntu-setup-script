# Ubuntu Setup Script

One idempotent Bash script that provisions and tunes a web/database stack on
**Ubuntu 26.04 LTS** (installs) and tunes existing 22.04/24.04/26.04 hosts
(`--optimize`): nginx, PHP-FPM, MariaDB, Valkey (or an existing Redis),
Elasticsearch, Node.js and helper tools, plus per-domain vhosts.

- **nginx, PHP and Valkey are built from source.**  There are no nginx, PHP or
  Valkey packages on a 1.22 host: each is compiled from its upstream release
  with clang, hardened, link-time optimised (ThinLTO for nginx and PHP, full
  LTO for Valkey) and BOLTed, and contains only what the host's
  applications use.  MariaDB and Elasticsearch stay apt packages.  See
  [Source builds](#source-builds).
- **Single source of truth for nginx:** the configuration tree is downloaded at
  run time from the `nginx` branch of
  [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx)
  (`CONFIG_SOURCE_DIR=/path` uses a local checkout). PHP-FPM templates live
  here under `configs/php/`, so run installs from a repository checkout.
- **File safety:** transient files go under `/tmp`; the script never deletes
  data, configuration or logs. `--purge` stops/disables services, removes
  only the source builds, their cached sources and the units setup.sh made,
  and restores recorded settings; it removes no package, data or log.  The one exception is the one-time migration of a
  1.21.x host, which purges the replaced Angie, Sury PHP and valkey-server
  packages after the compiled services serve, and keeps their `.deb` files
  and configuration in `/var/backups/setup-1.22`.  Every run writes
  `setup_<timestamp>-<pid>.log` in the directory it was started from.
- **Install/optimize parity:** every tuned value comes from one helper shared
  by the installer and `--optimize`, so a fresh install followed by
  `--optimize` produces identical configuration (verified byte-for-byte on
  the test host; see `tests/stress-site/RESULTS.md`).

| Path | Contents |
|---|---|
| `setup.sh` | Driver: argument parsing, validation and dispatch; sources `lib/*.sh` |
| `lib/` | Implementation modules sourced in dependency order: `common` (logging, run log, temp/apt helpers), `cli`, `validate` (including the 4 GB rule), `util` (state, logs, cron), `os`, `overrides` (tuning reset and drift audit), `web` (nginx/PHP-FPM tuning), `services` (installs, MariaDB, Valkey, Elasticsearch, domains), `nginx-build`, `php-build`, `valkey-build` (the setup.sh side of the source builds: units, layout, extension sets), `php-upgrade`, `migrate` (the one-time 1.21 -> 1.22 migration), `purge`, `runner`, `optimize`, `security` (hardening), `service-optimizers` (per-service tune/verify, shared by `--optimize`/`--upgrade-php`), `diagnostics`, `restart`, `payloads` |
| `tools/nginx-build.sh`, `tools/php-build.sh`, `tools/valkey-build.sh`, `tools/build-common.sh` | The build tools (installed under `/usr/local/lib/setup-*`); `build-common.sh` holds downloads, verification, the CPU fingerprint, the build lock and the CPU-change chain |
| `nginx-build.conf`, `php-build.conf`, `valkey-build.conf` | Component versions for each build (`latest` or a pin) |
| `configs/system/`, `configs/mariadb/`, `configs/php/` | DNS/sysctl/limits, MariaDB and PHP-FPM templates |
| `tests/test-tuning.sh`, `tests/test-dry-run-matrix.sh` | Unit tests; CLI/dry-run matrix (both run in CI) |
| `tests/stress-site/` | Synthetic full-stack test site, local and remote load harness, results |
| `tools/diff_configs.sh` | Compare the canonical configs of both repos with the live `/etc` |
| `tools/fleet-update.sh` | Safe, logged host update: non-interactive APT, snapd guard, free-space check, fresh setup.sh checkout, `--optimize` dry run then apply (as a transient unit), reboot notice |
| `tools/check-public-ips.sh` | CI check: fails when a tracked file contains a public IPv4 address that is not on `tools/public-ip-allowlist.txt` |
| `tools/remove-anubis.sh` | One-shot migration for a host that still runs the removed Anubis filter: restores the vhosts, removes the generated nginx files, stops/disables the service (`--purge` deletes it) |
| `SECURITY-PERFORMANCE.md` | What the script hardens, what it leaves to the operator, and the large-site checklist |

## Requirements

- Ubuntu 26.04 LTS or newer for installs; `--optimize`, `--upgrade-php`,
  `--diagnostics`, `--restart-all` and `--purge` also accept 22.04 and 24.04.
  Bash 4.4+.  Root.
- x86-64 (Intel or AMD) or arm64.  Tested on an Intel Xeon E-2236 and an AMD
  EPYC 4245P (Zen 5), on Ubuntu 24.04 and 26.04.  BOLT needs hardware branch
  records (Intel LBR, or AMD LbrExtV2 on Zen 4 and later) on bare metal;
  without them (most VMs, Zen 3 and older) the builds keep their ThinLTO
  binaries and the report quotes perf's reason.  Since 1.22.5 such a host records
  `bolt=nolbr` in `build.info` and BOLT is not retried until the next build
  (a plain-cycles profile, `perf2bolt -nl`, measured 1-3 % slower than no
  BOLT on every uncached XenForo tier, so there is no such option).
- **RAM: the 4 GB class for anything but nginx.**  A host whose `MemTotal`
  is below 3500 MB runs nginx only (see [Small hosts](#small-hosts-the-4-gb-rule)).
- **Disk for the builds:** a build refuses to start with less than 6 GB free
  on the build cache filesystem (`/var/cache`) or less than 2 GB free on `/`.
- Network access to the Ubuntu archive, apt.llvm.org, nginx.org, php.net,
  GitHub (component releases, server-configs-nginx, the
  [setup-build-sources](https://github.com/droplinxuser/setup-build-sources)
  mirror), the library projects' own sites, and the Elastic and NodeSource
  repositories when those services are selected.
- RAM/disk for the selected services (Elasticsearch needs ~1.5 GB of disk plus
  its heap; MariaDB its buffer pool; PHP one static worker per
  `pm.max_children` slot).

## Quick start

`--basic` is required for every install and all of its values are optional.
Only the services named on the command line are touched. Replace `pass=temp`
with a real password (it is also written to `/etc/mysqlbkup.cnf`, mode 600).

```bash
# Full stack
sudo bash setup.sh \
  --basic server=dedi host=web1.example.com time=Asia/Manila swap=8G \
  --nginx --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all

# Minimal web host, everything auto-detected
sudo bash setup.sh --basic --nginx --php

# PHP with two optional extensions on top of the per-application set
sudo bash setup.sh --basic --php ext=intl,gmp

# Application vhost with database, scoped user and a dump import
sudo bash setup.sh --domain forum.example.com app=xf db=xenforodb user=demo pass=temp sql=/root/backup.sql

# Tune an existing host (OS profile + every installed service), or preview it.
# On a 1.21.x host the first run is also the one-time migration.
sudo bash setup.sh --optimize
bash setup.sh --optimize --dry-run

# Switch PHP to another series, keeping extensions/config
sudo bash setup.sh --upgrade-php=8.6
bash setup.sh --upgrade-php=8.6 --dry-run
```

Measured on the Xeon E-2236 test host (1.22.0): a fresh install with
`--basic --nginx --php ver=8.5 --mariadb --valkey --elastic --others all`
took 10 min 15 s, including building nginx 1.31.10, PHP 8.5.13 and Valkey
9.2.0 with LLVM 23.

## Command reference

| Command | Purpose | Details |
|---|---|---|
| `--basic [server=] [host=] [swap=] [time=] [mitigations=]` | OS baseline; required for every install | [`--basic`](#--basic) |
| `--nginx` | nginx built from source and its configuration tree (`--angie` is a deprecated alias that warns and installs nginx) | [nginx](#nginx---nginx) |
| `--php [ver=] [ext=] [children=] [max_requests=]` | PHP-FPM and the PHP CLI, built from source | [PHP](#php---php) |
| `--mariadb user= pass= [size=] [bind=]` | MariaDB | [MariaDB](#mariadb---mariadb) |
| `--valkey [ram=] [policy=] [tcp=]` | Valkey cache, built from source | [Valkey](#valkey---valkey) |
| `--elastic [host=] [ram=]` | Elasticsearch | [Elasticsearch](#elasticsearch---elastic) |
| `--others ITEM... \| all` | helper packages | [Other packages](#other-packages---others) |
| `--domain DOMAIN [app=] [db=] [user=] [pass=] [sql=]` | vhost, certificate and optional database | [Domains](#domains---domain) |
| `--optimize [mitigations=]` | tune the OS and every installed service in place, rebuild stale source builds; on a 1.21.x host, the one-time migration. Recorded tuning overrides are always ignored | [`--optimize`](#--optimize), [Upgrading from 1.21.x](#upgrading-from-121x) |
| `--upgrade-php=X.Y` | switch PHP to another series in place | [`--upgrade-php`](#--upgrade-phpxy) |
| `--diagnostics` | write a redacted `diagnostics.log`; read-only | [Maintenance](#--diagnostics---restart-all---purge) |
| `--restart-all` | ordered restart of every active service | [Maintenance](#--diagnostics---restart-all---purge) |
| `--purge [TARGET...]` | stop and disable services, remove the source builds, restore recorded settings | [Maintenance](#--diagnostics---restart-all---purge) |
| `--dry-run` (alias `--check`) | validate any command and print the plan as a normal user; nothing is changed | works with every command above |
| `--help`, `--version` | usage text; script version | |

Removed in 1.22.0: `--source` and the environment variables
`SETUP_PHP_BUILD`, `SETUP_NGINX_BUILD` (1.21 `SETUP_ANGIE_BUILD`),
`SETUP_VALKEY_BUILD` and `SETUP_PHP_FPM_MODULES`.  They are accepted, ignored
and named in a warning, so an old runbook does not fail; the values persisted
by 1.21 (`PHP_BUILD`, `ANGIE_BUILD`, `VALKEY_BUILD`, `PHP_FPM_MODULES`) are
dropped from `/etc/default/setup-tuning`.  There are no package modes left to
choose.  Use `--php ext=` to add PHP extensions.

Removed in 1.22.1: static-asset precompression (`SETUP_PRECOMPRESS_ASSETS`)
and the two nginx modules it fed, `gzip_static` and `brotli_static`.  nginx
compresses every response with dynamic gzip and Brotli.  The variable is
accepted, ignored and named in a warning.  A `gzip_static` or `brotli_static` line in an operator
vhost is commented out with the `# setup-nginx-build-off: ` marker and
reported, instead of failing `nginx -t`.

## `--basic`

| Option | Default | Effect |
|---|---|---|
| `server=dedi\|vps` | auto (`systemd-detect-virt`, DMI, cgroups) | `dedi` sets the `performance` CPU governor; this is an install-time hint, `--optimize` re-detects the class from the hardware |
| `host=FQDN` | `<threads>c-<RAM_GB>g-<storage>` (e.g. `8c-32g-1T`) | hostname via `hostnamectl`; a repeat `--basic` without `host=` keeps the current name.  Where cloud-init is installed, `/etc/cloud/cloud.cfg.d/99-setup-hostname.cfg` records the name, so a provider's `manage_etc_hosts` rewrite of `/etc/hosts` at boot keeps it (`--optimize` adds it to hosts renamed before 1.22.4; `--purge basic` removes it) |
| `swap=SIZE` | add swap only when total swap is 0 or below 50% of RAM, up to 50% of RAM (1-8 GiB, 4 GiB on a VPS) | `/swapfile` of exactly that size (`8G`, `8Gi`, `512M`) |
| `time=REGION/CITY` | `Asia/Manila` | timezone; a repeat `--basic` without `time=` keeps the current zone |
| `mitigations=off` | `off` (default since 1.22.5) | every `--basic` and `--optimize` adds `mitigations=off` to the kernel command line (managed `/etc/default/grub.d/zz-setup-mitigations.cfg`, sourced after provider drop-ins such as Hetzner's `hetzner.cfg`, the provider's options kept, `update-grub`), effective at the next reboot (the `--optimize` report says when the running kernel still lacks it); the run checks that the generated boot menu really carries it and names any drop-in that overrides it.  Skipped in containers and without GRUB (reported).  `mitigations=off` is accepted and changes nothing; `mitigations=on` and `SETUP_CPU_MITIGATIONS=on` were removed (refused), and a host with a persisted `CPU_MITIGATIONS=on` moves to off on its next `--optimize` (reported).  `--purge basic` removes the drop-in and restores the distribution default.  Trade-off: no kernel protection between local processes (Spectre/Meltdown/MDS class), which suits single-tenant hosts administered with SSH keys only.  Measured on a Xeon E-2236: guest-cache hits +14-25 %, PHP tiers +5-7 % (1.21.36); +8-50 % cached and +15 % XenForo member/Chevereto uncached (1.21.38).  Further kernel hardening switches (`init_on_alloc=0`, `randomize_kstack_offset=off`) measured inside run-to-run noise on top of it, so they are not offered; `preempt=none` does not exist on the 7.0 kernel (it runs `lazy`) |

What `--basic` does:

| Step | Detail |
|---|---|
| DNS | drop-in with `8.8.8.8`, `1.1.1.1` and `Domains=~.`, so they are the default route rather than only a fallback |
| Packages | upgrades packages; installs the basic tools, `cron`, `logrotate` and `unattended-upgrades` |
| OS profile | sysctl, PAM limits, governor, THP `madvise`, udev I/O rules (see [Hardware profile](#hardware-profile)) |
| Root crontab | ownership repair of `/var/www` that skips logs and `wp-config.php`; Cloudflare IP refresh; MariaDB backup at 03:03 and a monthly `mariadb-check -a` (ANALYZE, online; logged to `/var/www/logs/mariadb/check.log`); `wp-cron.php` every 5 minutes |
| Firewall (UFW) | deny in, allow out, `ufw limit` on every effective SSH port, 80/443 open |
| State | originals are recorded under `/var/lib/setup.sh` for `--purge basic` |

### Security pass (every `--basic` and `--optimize`)

| Area | Action |
|---|---|
| WordPress | `wp-config.php` `root:www-data 640`; `DISALLOW_FILE_EDIT`, `DISALLOW_FILE_MODS` (`SETUP_WP_ALLOW_FILE_MODS=1` keeps plugin installs), `DISABLE_WP_CRON` (+ managed cron entry), `WP_DEBUG_DISPLAY=false`, `FORCE_SSL_ADMIN`; placeholder salts replaced; a `DB_USER` with global privileges is moved to `wp_<db>` scoped to its database (`SETUP_WP_DB_SPLIT=0` disables) |
| Malware | known webshells quarantined under `/var/lib/setup-quarantine/` (`SETUP_PURGE_MALWARE=1` deletes); suspicious admins, risky plugins, world-writable files and oversized archives reported |
| APT | every third-party repository pinned to its own `signed-by` keyring |
| Audit | reports SSH password authentication, public 80/443 and a non-loopback Elasticsearch |

The apt pin `/etc/apt/preferences.d/setup-source-builds` (priority -1) is
not part of the security pass.  The `--nginx` install writes it for the
nginx packages, the `--valkey` install for `valkey-server` and
`valkey-tools`, and the 1.21 -> 1.22 migration for the packages it
replaced.  An unattended upgrade then cannot put a package binary under the
source builds' units.  The PHP packages are pinned only on a migrated host
(after Sury is removed); a fresh `--php` install adds no PHP pin.

SSH hardening, brute-force protection and origin-only firewalling are left to
the operator. The web-server side (dotfile/`wp-config.php`/`xmlrpc.php`
denies, no PHP from upload directories, security headers) comes from
`server-configs-nginx`.  Each application has one deny location
(`h5bp/location/security_<app>.conf`, a single regex) ahead of an exact
`location = /index.php`, so a guest-cache hit runs 2-4 location regexes
instead of 25-39; `--optimize` moves vhosts rendered from older templates
onto it where their PHP include is at server level, and leaves (and reports)
any other vhost with the full set. nginx access logging is off by default;
only `error_log` is written.

## Source builds

nginx, PHP (FPM and CLI) and Valkey are always compiled from their upstream
releases.  There is no package mode and no fallback to a package binary.

Every build:

* compiles from the project's own releases, never Ubuntu's archive, with
  clang from apt.llvm.org at `-O3 -march=native` and Ubuntu's hardening flags
  (stack protector, stack-clash probes, `_FORTIFY_SOURCE=3`, CET, full
  RELRO), link-time optimisation and LLVM BOLT;
* links only glibc (libc, libm) from Ubuntu, and nginx also libstdc++
  (AWS-LC's libssl is C++): every library it needs is compiled in
  statically, and the units' `sd_notify()` is a small static
  implementation (no libsystemd);
* contains only what the host's applications use (nginx: the modules
  server-configs-nginx uses; PHP: the [per-application extension
  set](#extension-sets-per-application); Valkey: no TLS);
* runs from its own root under `/usr/local/lib/setup-*` through its own unit
  in `/etc/systemd/system`; no unit starts a binary from a dpkg-owned path,
  and the PATH links live in `/usr/local/bin` and `/usr/local/sbin`.

| Component | Built | Root | Unit |
|---|---|---|---|
| nginx | nginx.org mainline (the highest version nginx.org publishes), AWS-LC, PCRE2 (JIT), zlib-ng, Brotli | `/usr/local/lib/setup-nginx` | `nginx.service` |
| PHP X.Y | php.net release (any series from 8.1 on), FPM and CLI from one tree, static extensions | `/usr/local/lib/setup-php/X.Y` | `phpX.Y-fpm.service` |
| Valkey | newest GitHub release, bundled jemalloc and Lua, no TLS | `/usr/local/lib/setup-valkey` | `valkey-server.service` (alias `valkey.service`) |

| Measured (Xeon E-2236 test host, 5 rotated rounds, the same recipe against the distribution packages) | Gain |
|---|---|
| PHP (1.21.71): XenForo member thread / home, WordPress member home / post, Chevereto uncached | +9.4 / +8.4 / +6.5 / +6.9 / +11.3 % |
| Web server (1.21.70, Angie then, same recipe): cached guest pages | +2.2 to +12.4 % |
| Valkey (1.21.71): pipelined GET / SET, single requests | +3.1 / +2.6 %, 0 to +1.5 % (Valkey is ~0.3 % of a page's CPU) |

Not built, and why: **MariaDB** uses 8-13 % of the server's CPU on a
logged-in page, so even a 10 % faster build would move pages by about 1 %;
**Elasticsearch** is Java (the JIT already compiles for the exact CPU), and
Elasticsearch 9 cannot be trimmed to the modules XenForo Enhanced Search
uses without a separate data directory and a reindex.  Both stay apt
packages.

### Supply chain

| Download | Verification |
|---|---|
| nginx | PGP signature (`.asc`) checked against the nginx.org signing keys whose fingerprints are pinned in `tools/build-common.sh`, in a throwaway GnuPG home.  Fail closed: there is no first-use trust for nginx, and a mirrored copy must carry the `.asc` and is checked the same way |
| PHP | php.net's published SHA-256; the GitHub `php-X.Y.Z` tag snapshot is the second source.  Never an RC, alpha or beta |
| Valkey | the SHA-256 in the valkey-io/valkey-hashes repository.  A mismatch stops the build; only when that repository is unreachable is the archive pinned on first use (reported).  While it does not list a new release yet, `latest` builds the newest release it lists |
| LLVM | apt.llvm.org with its signing key checked by fingerprint, pinned at priority 100 so it never replaces an Ubuntu package; LLVM's GitHub release tarball in `/opt/setup-llvm` as the second source |
| Libraries | published SHA-256s where the project has them (GitHub release digests, GNOME `.sha256sum`, OpenSSL `.sha256`, SQLite's SHA3-256); everything else is pinned on first download, so the same file must always hash the same |

Every download has a second source, tried when the first times out, stalls
(under 1 KB/s for 30 s) or fails.  The project's own mirror,
[setup-build-sources](https://github.com/droplinxuser/setup-build-sources),
is the last source: a file from it must match the upstream's published
hash, the hash this host pinned on its first download, or the mirror's
`SHA256SUMS`, or it is refused (`SETUP_BUILD_MIRROR=off` turns the mirror
off).  The sources for each component are listed at the top of its version
file.

### When builds run

| Event | What happens |
|---|---|
| Install (`--nginx`, `--php`, `--valkey`) | builds, verifies, then activates.  Order: nginx, PHP, Valkey.  A build failure stops the install with the build log's path; nothing is half-installed, and nothing serves on that host until a re-run succeeds |
| `--optimize` | rebuilds a component whose release, recipe, CPU or extension set is stale, then BOLTs it from live traffic.  The running binary serves until the new one passed its checks.  On an idle server BOLT reports "too little traffic, BOLT skipped" (or "build lock held" when another build ran) and the next `--optimize` or the daily `setup-build-refresh.timer` retries it (PHP since 1.22.4, nginx before) |
| Daily `setup-build-refresh.timer` | one timer for all builds (daily, randomised by up to 4 h): rebuilds in the background when a component publishes a newer release or PHP's detected extension set grew.  The running binary serves until the new one passed every check, so library security fixes arrive within a day.  It never takes a service down |
| CPU change | see below |
| Version file edited | `sudo ./setup.sh --optimize` rebuilds what changed; `<tool> check` shows what a rebuild would change |

Binary swaps: nginx changes binaries with its in-place upgrade (USR2, WINCH,
QUIT; no dropped connections).  If the new master does not come up within
10 s or does not answer on 127.0.0.1, the previous binary
(`sbin/nginx.prev`) is put back and the old master keeps serving; nginx is
restarted only if no master is left.  PHP-FPM restarts (about a second).  Valkey restarts, which
empties the cache.

**CPU change.**  Each build records a CPU fingerprint in its `build.info`
(vendor, family, model, stepping, model name and the ISA flags
`-march=native` can use; security and microcode flags never count, and
neither do RDRAND/RDSEED, which the kernel hides by policy: Linux clears
RDSEED on AMD Zen 5 parts with the RDSEED erratum, and a microcode update
gives it back; a build from 1.22.0-1.22.3, whose fingerprint still included
them, keeps matching).  When a
unit starts on a CPU that does not match, its `ExecStartPre` starts
`setup-build-cpu.service` and fails: **the service stays down until the
native rebuild finishes**, by design (there is no generic fallback binary).
The chain rebuilds nginx, then the active PHP version, then Valkey, each
from the exact versions recorded in `build.info` and the cached sources in
`/var/cache/setup-*-build` (no network lookups, no BOLT), and starts each
service as soon as its own rebuild passes.  A failing stage is reported and
the chain goes on, so a PHP failure never keeps nginx down.  The PHP CLI is
rebuilt with the FPM; until the chain finishes, a cron job that runs `php`
can fail with SIGILL (accepted: the operator rule is that hosts do not
change CPUs).  Follow it with `journalctl -u setup-build-cpu -f`.

**Resources.**  One lock (`/run/setup-build.lock`) serialises every build,
activation and CPU chain.  Parallel jobs = min(CPUs, (MemAvailable - 1 GB) /
1.2 GB), at least 1 (`SETUP_BUILD_JOBS` overrides); build units run at nice
10 with idle I/O and `OOMScoreAdjust=900`, so the OOM killer takes the build,
not MariaDB.  Build logs: `/usr/local/lib/setup-*/logs/` (the newest 5 per
component, kept on failure).

**Manual control** (root):

| Tool | Commands |
|---|---|
| `/usr/local/lib/setup-nginx/nginx-build.sh` | `status`, `versions`, `check`, `build`, `activate`, `rebuild`, `bolt [seconds]`, `fit` / `restore` (directives of left-out modules), `remove` |
| `/usr/local/lib/setup-php/php-build.sh` | `status [X.Y]`, `versions X.Y`, `check X.Y`, `build X.Y`, `activate X.Y`, `rebuild X.Y`, `bolt X.Y [seconds]`, `series` (newest released X.Y), `release X.Y` |
| `/usr/local/lib/setup-valkey/valkey-build.sh` | `status`, `versions`, `check`, `build`, `activate`, `rebuild`, `bolt` |

`check` exits 0 when the build is current and 10 when a rebuild is due.
`sudo systemctl start setup-nginx-build` (or `setup-php-build@X.Y`,
`setup-valkey-build`) rebuilds in the background.

## Small hosts (the 4 GB rule)

A source build of PHP or Valkey (clang and ThinLTO links, the LLVM
toolchain) and the services themselves do not fit beside MariaDB on a 1-2 GB
host, and a CPU change keeps a service down until its native rebuild
finishes, so an out-of-memory build would leave the site down.  The "4 GB
class" starts at a `MemTotal` of 3500 MB (a 4 GB VM reports about 3.7-3.9 GiB
once kernel and firmware reservations are taken out).

| Below 3500 MB | Behaviour |
|---|---|
| Install | nginx, `--basic`, `--others` and `--domain` with `app=basic`, `node` or `pingvin` only.  `--php`, `--valkey`, `--mariadb`, `--elastic`, `--upgrade-php` and PHP `--domain` apps are refused before anything changes |
| `--optimize` | tunes nginx; an existing PHP or Valkey is left as it is, not tuned, and reported |
| Migration from 1.21.x | only the nginx part runs; Sury PHP and the valkey-server package keep serving and are not purged |

`SETUP_MEM_TOTAL_MB` stands in for the host's RAM only in `--dry-run` and
the unit tests; anywhere else it is ignored with a warning.

## Services

### nginx (`--nginx`)

`--nginx` builds the nginx.org mainline release from source, deploys the
`server-configs-nginx` tree (branch `main`) to `/etc/nginx`, applies the
hardware profile and starts its own `nginx.service`.  `--angie` still works
as a deprecated alias: it prints a warning and installs nginx.

| Step | Detail |
|---|---|
| Distro nginx | a distro nginx (Ubuntu's `nginx-core`/`-full`/..., an ondrej PPA build) that is not serving is removed first: `/etc/nginx` moves to `/var/backups/setup-1.22/nginx-distro-<stamp>`, then a guarded purge (`apt-get -s` must remove only that package list).  A serving distro nginx, or one beside an existing compiled nginx, is left alone and the install refuses |
| Build | `tools/nginx-build.sh` builds and verifies into a staging directory; nothing else changes if the build fails |
| Configuration | deploys the `server-configs-nginx` tree with the built-in deployer |
| Tuning | hardware profile and guest caches (the same `nginx_apply_profile` as `--optimize`) |
| Service files | `/etc/systemd/system/nginx.service` (binary under `/usr/local/lib/setup-nginx`, `LimitNOFILE=524288`, `UMask=0027`, a CPU gate and `nginx -t` before every start), `tmpfiles.d/setup-nginx.conf` (`/var/cache/nginx/*_temp`, `/var/www/logs/nginx`) |
| Cloudflare | generates `http.d/cloudflare.conf` |
| Finish | activates and starts the service; `/usr/local/sbin/nginx` links to the binary for the shell |

**What it is.**  nginx from nginx.org (the highest published version, which
is the mainline branch), AWS-LC (the TLS library), PCRE2 (JIT), zlib-ng
(zlib's API; 21 % less gzip CPU than Ubuntu's zlib) and Brotli
(google/brotli with the filter module of google/ngx_brotli, compiled in
statically, so there is no `load_module`),
each at the version in [`nginx-build.conf`](nginx-build.conf), compiled with
clang at `-O3 -march=native` with the hardening flags (ThinLTO for AWS-LC,
zlib-ng, Brotli and nginx; PCRE2 is built by nginx's configure at the
same flags without LTO), then rewritten by LLVM BOLT from a 60 s perf sample of live traffic (at least
150 profiled functions; an idle server is skipped).  Only the modules
`server-configs-nginx` uses are built: the http core with SSL, HTTP/2,
HTTP/3 (QUIC), realip, stub_status (the metrics script polls it on
127.0.0.1), threads, dynamic Brotli, `limit_req` (the login limiter, which
since 1.22.5 also covers XenForo search and contact-form POSTs) and
`auth_basic` (password-protected areas).  Mail, stream, ACME, DAV, mp4/flv,
sub, SSI, uwsgi, scgi, grpc, memcached, userid, autoindex, split_clients,
empty_gif, browser, mirror, `limit_conn`, referer, `gzip_static` and
`brotli_static` (both removed in 1.22.1) are left out.

**Branding strip.**  Before configure, the source is patched so no response
names the server: no default `Server` header on HTTP/1.1, HTTP/2 or HTTP/3,
and error pages that end with `</body></html>` (no `<hr><center>nginx` line).
The configuration also keeps `server_tokens off`, and `fastcgi.conf` passes
`SERVER_SOFTWARE nginx` without a version, except `nginx/<version>` on
`admin.php` for XenForo's Server environment report (internal to PHP, never
sent to clients; WordPress uses it to detect nginx).  Every patch is counted.  When
a new mainline moved one of the patched lines, an install or migration
builds the newest known-good version instead (`NGINX_FALLBACK` in
`nginx-build.conf`, currently 1.31.10, or this host's last patched build)
and reports the skipped version; the daily refresh keeps the running binary
and retries the next day.  The verify step starts the candidate on
127.0.0.1 with `server_tokens on` and checks that neither headers nor body
of a 404/502 contain "nginx".  Measured on a fresh 1.22.0 install: no
`Server` or `X-Powered-By` header, and the 404 page has no "nginx".

**Why nginx.**  Compiled nginx 1.31.10 against compiled Angie 1.12.5 with
the same flags, libraries, modules and files, 5 rotated rounds on the Xeon
E-2236 test host: cached pages +0.5 to +1.5 % for nginx (XenForo home
123,007 vs 121,482 req/s), PHP pages tied.  server-configs-nginx targets
nginx.

| Measured (1.21.70 recipe, Xeon E-2236 test host, 5 rotated rounds) | Package | Compiled |
|---|---:|---:|
| Web server (Angie) CPU per gzip-compressed XenForo member page | 1.19 ms | **0.94 ms** (zlib-ng) |
| Web server (Angie) CPU per Brotli-compressed member page | 1.91 ms | 1.82 ms |
| Member and uncached pages | — | unchanged (PHP sets the pace) |

**Directives the build cannot serve.**  A directive of a left-out module
that only transforms or limits responses (`sub_filter*`, `ssi*`,
`add_before_body`, `add_after_body`, `addition_types`, `limit_conn*`,
`userid*`, `autoindex*`, `random_index`, `gunzip*`, `mp4*`, `flv`) is
commented out in its file with the marker `# setup-nginx-build-off: `, and
the report lists each one (file:line).  A commented `limit_conn` is reported
as "security control removed" (operator rule since 1.21.71: `limit_conn` is
not built).  `nginx-build.sh restore` puts the marked lines back byte for
byte.  Access control (`auth_request`, `secure_link`, ...) and content
handlers (`uwsgi_pass`, `grpc_pass`, `memcached_pass`, `empty_gif`, another
`load_module`) are never commented out: without its handler a location
would serve its root as static files.  Such a configuration fails
`nginx -t`, the activation stops and the running nginx keeps serving.

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_BROTLI_LEVEL=1..11` | 1 (1.22.5) | dynamic Brotli level; gzip is the fallback.  1.22.5 (XenForo, pinned clock, two interleaved arms of 5 rounds each): level 1 served 4.2-4.7 % more uncached req/s than level 4 on every tier, p99 equal or lower, for about 16 % more bytes to Cloudflare (11.1 vs 9.5 KB per home page).  Measured on a XenForo member thread page (1.21.63, pinned clock): level 1 = 0.8 ms nginx CPU / 23.9 KB, 2 = 1.3 ms / 18.4 KB, 3 = 1.4 ms / 17.9 KB, 4 = 2.1 ms / 17.1 KB; level 1 gave +4-6 % member req/s for 40 % more bytes, levels 2-3 were inside the noise.  There is no zstd: Cloudflare asks origins for `br, gzip` only, and `--optimize` removes old zstd stanzas |
| `SETUP_NGINX_COMPRESSION=0` | on | turns the managed compression profile off (`SETUP_ANGIE_COMPRESSION` is still read as the old name) |
| `SETUP_XF_JOB_CRON=0` | on | removes the managed crontab entry that runs `cmd.php xf:run-jobs` once a minute as www-data for every XenForo root; persisted as `XF_JOB_CRON` |
| `SETUP_NGINX_BUILD_BOLT=0` | 1 | skip the BOLT pass of `--optimize` |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF` | `droplinxuser/server-configs-nginx`, `main` | select a fork, branch or tag of the configuration tree |
| `CONFIG_SOURCE_DIR=/path` | unset | use a local checkout instead of downloading |

**server-configs-nginx branch.**  The nginx tree is the repository's only
branch, `main`, and setup.sh downloads it (`CONFIG_REPO_REF=main`).  Two
tags keep older releases working: `nginx` (the frozen 1.7.1 tree that
setup.sh 1.22.0 and 1.22.1 download by default) and `angie-final` (the last
Angie tree; a host kept on 1.21.x can pin `CONFIG_REPO_REF=angie-final`).
A 1.21.x setup.sh that downloads `main` refuses the nginx tree (no
`angie.conf`) and keeps its Angie tree, so update the checkout before
`--optimize`: 1.22 migrates the host to nginx.

Notes:

- Guest-cache locations disable per-hit AIO and Brotli (`aio off; brotli off;`).
  The cached body is already compressed (XenForo/WordPress gzip), so re-running
  either filter only costs CPU; static assets keep the global AIO/Brotli path.
  On the CentMinMod/Nginx audit, `aio threads` cost 16 % of cached-page
  throughput; on Angie (1.21.x) the scoped change was neutral.
- With the XenForo job entry in place, switch *Options > Performance > Job
  run trigger* to server-based in the admin CP so member page requests stop
  running the queue. Never run the queue as root: the data directories it
  creates return 403 through nginx.
- An upstream name that a deployed vhost still references but the canonical
  tree no longer defines (a repository rename, or an operator-edited `http.d`
  file) is preserved in `http.d/zz-setup-preserved-upstreams.conf` instead of
  making `nginx -t` fail with *host not found in upstream*. The include is
  regenerated on each install/`--optimize` and retired once the repository
  defines the name again.
- There is no bot filter in the nginx tier.  Anubis support was removed in
  1.21.62 (Cloudflare or another CDN/WAF belongs in front of the origin).  A
  host that still runs the filter is refused by `setup.sh` until
  `sudo bash tools/remove-anubis.sh` has restored its vhosts to direct TLS.

### PHP (`--php`)

| Option | Default | Effect |
|---|---|---|
| `ver=X.Y` | the newest series php.net has released | PHP series to build; any series from 8.1 on.  The newest X.Y.Z release of that series is built, never an RC |
| `ext=LIST` | none | optional extensions added to the per-application set, comma-separated (`ext=intl,gmp`); `-NAME` drops one you added earlier, `none` clears the list.  Persisted as `PHP_EXT_EXTRA`.  A name the source build cannot compile is refused before anything changes. |
| `children=auto\|N` | `auto` (shared memory plan and CPU count) | `pm.max_children`; an explicit value wins over every rule below |
| `max_requests=N` | threads x 1024 | recycle a worker after N requests |

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_PHP_WORKERS_PER_CPU` | by host class (see the pool table) | pins the workers-per-CPU factor for an install/one run; `--optimize` ignores it |
| `SETUP_PHP_JIT_WORDPRESS=0` | 1 (WordPress uses the JIT) | keeps `opcache.jit = off` for every WordPress document root through a `[PATH=<root>]` section of the managed ini, for a site that misbehaves with the JIT.  Tuning override: ignored by `--optimize` |
| `SETUP_PHP_PAGE_GZIP=0` | 1 | by default the managed ini turns `zlib.output_compression` (level 4) on in a `[PATH=<root>]` section for every WordPress and Chevereto document root whose guest cache key carries the encoding token, so the FastCGI cache stores the gzip page (0.12 ms of nginx CPU per hit instead of about 1 ms to compress each hit); tuning override: ignored by `--optimize` (profile default 1) |
| `SETUP_PHP_OPCACHE_FILE_OVERRIDE=0` | on | `opcache.enable_file_override = 1` is written by default since 1.22.5 (`file_exists`/`is_file`/`is_readable` on cached scripts answered from OPcache; XenForo member pages measured 2-4 % faster, no tier slower).  A deleted PHP file can still read as present until OPcache revalidates it (60 s).  `=0` leaves the line out; persisted as `PHP_OPCACHE_FILE_OVERRIDE` |
| `SETUP_PHP_ALLOW_MISSING_EXT=1` | off | accept that a detected application loses an extension the source build cannot provide (install, `--upgrade-php`, migration); the affected sites may fail |
| `SETUP_PHP_BUILD_BOLT=0` | 1 | skip the BOLT pass of `--optimize` |

**What it is.**  PHP from php.net, redis and igbinary from PECL, and every
library PHP links (OpenSSL, PCRE2, zlib-ng, libxml2, libsodium, GMP, GNU
libiconv, curl, libjpeg-turbo, libpng, libwebp, libzip, SQLite, ICU only
for `intl`, and mimalloc as the allocator), each from its own project at the version in
[`php-build.conf`](php-build.conf), compiled with clang at `-O3
-march=native -fPIE` with the hardening flags and linked statically with
ThinLTO.  php-fpm and the `php` CLI are built from one configured tree, so
both have the same extensions.  php-fpm is then rewritten by LLVM BOLT from
a 60 s perf sample of live traffic (at least 300 profiled php-fpm
functions); the CLI is LTO only (it runs cron jobs, not page views).
OPcache is compiled in from PHP 8.5; before 8.5 PHP can only build it as a
shared module, which lives in the build root and is loaded with its full
path from `conf.d/00-setup-opcache.ini`.  No other shared module exists, so
no `extension=` line is ever needed.  A library is built only when the
host's extension set needs it.  BOLT needs `perf` for the running kernel
(`linux-tools-$(uname -r)`) and CPU branch records (LBR); a VM without them
keeps the ThinLTO build.  The allocator is mimalloc (`PHP_BUILD_MALLOC` in
`php-build.conf`, default and only value `mimalloc`): a static mimalloc
replaces malloc in php-fpm and php (`build.info` `malloc=`; the verify
refuses a binary that does not run on it); any other value draws a warning
and builds on mimalloc, never a failed build.  nginx's TLS library is
AWS-LC (`TLS_LIB` in `nginx-build.conf`, default and only value `aws-lc`).
Measured on XenForo (pinned clock, interleaved runs): mimalloc made
uncached guest and member pages 3.3-3.8 % faster than glibc's malloc and
halved PHP-FPM RSS under load (about 640 MB to 320 MB); AWS-LC made cached
pages 2-5 % faster than OpenSSL 4.1 and cut nginx RSS by a fifth to a quarter
(300-320 MB to 234-237 MB), with uncached pages within noise.  p99 was equal or
lower everywhere.  With session tickets off, AWS-LC resumes TLS 1.2
sessions from the shared cache but not TLS 1.3 ones: a TLS 1.3 client that
reconnects straight to the origin (not through Cloudflare) does a full
handshake.  Removed in 1.22.5 because they measured no faster on
the Intel Xeon test host: `TLS_LIB=openssl` (2-5 % slower on cached
XenForo pages and more nginx memory than aws-lc; nginx no longer builds
OpenSSL, so `OPENSSL_VERSION` only applies to PHP),
`PHP_BUILD_MALLOC=glibc` (uncached pages 3-4 % slower and twice the
PHP-FPM memory), `PHP_BUILD_MALLOC=jemalloc` (below
mimalloc on every tier), nginx's `MALLOC=mimalloc|jemalloc` (within noise of
glibc; nginx always links glibc's malloc), `TLS_LIB=boringssl` (below aws-lc
on the cached tier, no OCSP stapling), `OPENSSL_VERSION=lts` (the newest
OpenSSL is faster on handshakes) and `BOLT_NOLBR=1` (1-3 % slower than no
BOLT).  A conf or environment that still names one draws a warning and the
default; a build made with one (an OpenSSL nginx, a glibc PHP) is reported
stale and rebuilt on the default.

**Checks before it serves.**  The candidate must start without warnings,
list exactly the expected modules per SAPI (FPM: the set, PHP's fixed core
and `cgi-fcgi`; CLI: the set, the core and `pcntl`), and pass `php-fpm -t`
against the live pool configuration.  The running build keeps serving until
the new one has passed every check.  The binary php-fpm runs is stripped
(`php-fpm.lto` keeps the symbols for BOLT).

| Measured vs the Sury package (1.21.70, 5 rotated rounds, pinned clock) | XF thread | XF home | WP home | Chevereto uncached |
|---|---:|---:|---:|---:|
| hardened + BOLT (the shipped recipe) | **+10.6 %** | **+6.8 %** | **+6.5 %** | **+3.8 %** |
| hardened + zlib-ng, before BOLT | +3.7 % | +2.4 % | +2.9 % | **+9.8 %** |

The hardening costs 0.5-2 % and stays.  zlib-ng speeds up the gzip PHP
does itself for WordPress and Chevereto pages (`SETUP_PHP_PAGE_GZIP`).
Instrumented PGO on top of BOLT and AutoFDO did not beat BOLT alone and are
not used.  There is no ImageMagick: WordPress, XenForo and Chevereto all use
GD.  `intl` is not built by default: ICU made the binary 102 MB instead of
60 MB and cost 4.5x the data-TLB misses on XenForo pages (1.21.69), XenForo
ships Symfony's intl polyfills, WordPress checks `function_exists`, and
Chevereto does not use it.

#### Extension sets (per application)

The build carries exactly the host's effective extension set: the base set,
plus the set of every application found on the host, plus `PHP_EXT_EXTRA`.

| Set | Extensions |
|---|---|
| Base (always) | ctype curl dom fileinfo filter gd iconv libxml mbstring mysqlnd openssl opcache phar posix session simplexml tokenizer zlib, and pcntl in the CLI only (phar, posix, tokenizer and pcntl are for wp-cli and composer), plus PHP's always-on core |
| WordPress | mysqli gd curl mbstring exif zip xml sodium; + redis igbinary when a Redis object-cache drop-in needs `\Redis` (no Predis fallback) or Object Cache Pro is installed |
| XenForo | mysqli gd curl mbstring xml zip exif; + redis igbinary when `src/config.php` selects the `Redis` cache provider |
| Chevereto | pdo_mysql pdo mysqli redis igbinary gd curl mbstring exif fileinfo xmlwriter zip |
| Other PHP apps (`--domain app=` flarum, polr, lychee, sfs, php, or a PHP root that is none of the three) | mysqli pdo_mysql pdo tokenizer bcmath sqlite3 pdo_sqlite xml xmlwriter zip exif; shlink adds gmp |
| Any application root that uses SQLite | sqlite3 pdo_sqlite (a scan of the root, 4 levels deep, skipping `vendor`, `node_modules`, `cache` and `.git`, for `new SQLite3`, a `sqlite:` PDO DSN or a database file with the "SQLite format 3" magic) |
| `--php ext=` only | anything else the build can compile: bcmath calendar ftp gettext gmp intl (builds ICU) shmop soap sockets sysvmsg sysvsem sysvshm xmlreader, and the names above |

* Applications are detected from the vhost roots in `/etc/nginx/conf.d`,
  the `/var/www` tree and the `--domain app=` entries of the run.
* Detection only **adds**: the set of the current build is always part of
  the new one, so an unmounted volume, an unreadable config or a scan
  timeout never shrinks a live build.  A set shrinks only through
  `--php ext=-NAME`, `--php ext=none` or a removed `--domain`.
* A bare `--php` on a host with no application and no previous build gets
  the union of the WordPress, XenForo and Chevereto sets, so a site dropped
  in later does not answer 500.
* The daily refresh reruns the detection.  When the set grew (for example a
  XenForo `config.php` switched its cache to Redis), the active version is
  rebuilt in the background; until then the `--optimize` report says so.
* A build refuses to serve unless its set covers every hard requirement of
  every detected application.  The effective set is recorded in
  `build.info` as `exts=`, and `php-build.sh status` prints it.

Install behaviour:

| Area | Detail |
|---|---|
| Source | php.net; no Sury repository, no Ubuntu PHP packages |
| One version only | both nginx and the pool use `/run/php/php-fpm.sock`, so only one PHP-FPM version is active (`/etc/php/setup-active`); it owns the socket, `/usr/local/bin/php` and the CPU-change chain |
| First installation | `--php` builds the requested series (or the newest php.net release) on a host without PHP |
| Existing host | `--php` keeps the installed build (rebuilt only when stale or when `ext=` grew the set), its extra pools and the operator's `conf.d` files, and re-applies the managed configuration.  A different `ver=` is refused: changing the series is `--upgrade-php`'s job |
| Legacy host | a host still serving through Sury PHP packages must run `--optimize` first (the one-time migration); `--php` refuses until it has |
| Layout | binaries `/usr/local/lib/setup-php/X.Y/sbin/php-fpm` and `bin/php`; links `/usr/local/bin/phpX.Y`, `/usr/local/sbin/php-fpmX.Y`, `/usr/local/bin/php` (active version) and `/usr/bin/php`, `/usr/bin/phpX.Y` once no package owns those paths.  Configuration `/etc/php/X.Y/{fpm,cli}`: `php.ini` from that version's `php.ini-production` plus the managed settings, `php-fpm.conf`, `pool.d/www.conf` (written only when absent or recognisably ours), `conf.d` settings files |
| Unit | `/etc/systemd/system/phpX.Y-fpm.service`, `Type=notify`, `-c /etc/php/X.Y/fpm/php.ini` and `PHP_INI_SCAN_DIR=/etc/php/X.Y/fpm/conf.d`, `LimitNOFILE=524288`, `UMask=0027`, `KillSignal=SIGQUIT`, a CPU gate and `php-fpm -t` before every start |
| Sessions | `/var/lib/php/sessions` (www-data, 0700, from `tmpfiles.d/setup-php.conf`), collected by PHP itself (`session.gc_probability = 1`, divisor 1000); there is no `phpsessionclean` timer.  A pool that runs as another user gets `/var/lib/php/sessions-<user>`.  **Chevereto** keeps file sessions in its own directory (`/tmp` unless `CHEVERETO_SESSION_SAVE_PATH` says otherwise), one per guest visit: PHP's GC is off for its roots (a `[PATH=]` section) because it scanned that whole directory while the request held the session lock, and `setup-php-sessionclean.timer` deletes the expired files every 10 minutes instead.  The `--optimize` report shows the two `env.php` lines that move Chevereto sessions to Valkey (member explore 9,466 vs ~2,200 req/s on the EPYC test host) |

Pool (`pool.d/www.conf`):

| Setting | Value |
|---|---|
| `pm` | always `static` |
| `pm.max_children` | logical CPUs x factor, capped by the shared memory plan (at most RAM/2 at 96 MB per worker, 512 maximum).  When several PHP-FPM versions run at once (an inherited host), the planned pool is split between them, and MariaDB/Valkey connection limits count every running pool |
| Workers-per-CPU factor | 1.0 with a local MariaDB on flash storage; 1.5 on a shared/virtual CPU or a remote database; 2.0 on spinning disks |
| `pm.max_requests` | threads x 1024 |
| `request_terminate_timeout` | 300s |
| Slow log | 10 s |
| `rlimit_files`, systemd | 524288; `LimitNOFILE=524288`, `UMask=0027`, `KillSignal=SIGQUIT` (graceful stop: workers close their persistent MariaDB connections, so a restart logs no "Aborted connection" warnings) |

Measured on the 16-thread audit host (XenForo member page, loopback, 64
connections): 16 workers 834 req/s at 14.38 ms PHP CPU/request, 32 workers
808 req/s at 15.68 ms. Extra workers only contend for the same cores.

`php.ini` (`conf.d/zz-setup-optimize.ini`):

| Setting | Value |
|---|---|
| `memory_limit` | 256-512M (128M under 2 GB of RAM) |
| OPcache | 128-512 MB with interned strings |
| Realpath cache | 4-16 MB |
| MariaDB | socket defaults (`/run/mysqld/mysqld.sock` is compiled in) |
| `opcache.jit` | always `tracing`; there is no mode switch (an old `SETUP_PHP_JIT` or persisted `PHP_JIT` value is ignored with a notice) |
| `opcache.jit_buffer_size` | OPcache/8, 32-128 MB; carved out of the OPcache shared-memory segment once per pool, not per worker |
| `opcache.validate_timestamps` | 1 with `revalidate_freq = 60` (always: a changed PHP file is picked up within a minute, no reload after a deploy) |
| `opcache.file_cache` | written explicitly empty, because scripts restored from the file cache are never JIT-compiled (measured 3-5 % slower) |
| Uploads | `upload_max_filesize = 100M`, `post_max_size = 102M`: above the Chevereto vhost's `client_max_body_size 101m`, so nginx's 413 is the one effective limit instead of PHP silently emptying `$_POST`/`$_FILES`.  Behind Cloudflare Free or Pro the edge caps a request body at 100 MB (413 from Cloudflare), so the largest Chevereto upload through a proxied hostname is a little under 100 MB |
| `custom_dan.ini` | refreshed from `configs/php/` while the host timezone is kept |

Measured on the test host (XenForo 2.3.13 + WordPress 7.1.4, PHP 8.5.12, 32
workers, 20 s runs, 100 members): tracing beat JIT off by 5% on XenForo
members (910 vs 864 req/s, p50 69 vs 73 ms); `function` lost 6-8% and had a
554 ms p99; 64 MB and 128 MB buffers were within 0.5%, and 256 MB was slower.

nginx-side repairs made by the PHP step: `fastcgi_param PATH_TRANSLATED` is
repaired in every `h5bp/php*.conf`, and any per-request `PHP_ADMIN_VALUE
open_basedir` is commented out (PHP-FPM caches admin values per worker, so
one vhost's setting leaked onto every other vhost of the shared pool).

### XenForo (`--domain ... app=xf`)

Cacheable guest requests are served from a named location
(`@xf_guest_cache`) that never forwards `Set-Cookie`, so one visitor's
`xf_csrf` cookie is not replayed to the next; XenForo's own JavaScript
fetches a fresh token from `/login/keep-alive` when the cookie is missing.
Members, POSTs and no-cache URIs stay in the uncached PHP location.

Uncached XenForo pages (members, guest bypass, `admin.php`, `job.php`) are
compressed by nginx, not by XenForo: the uncached handler
(`h5bp/php_xf_handler.conf`) gives PHP an empty `Accept-Encoding`, so
XenForo's level-9 gzip never runs in a PHP worker and nginx applies
Brotli level 1 (gzip level 4 for clients without Brotli) instead.  That rule is in the nginx tree, so it works
from the first request of a new install and reaches existing hosts with the
next `--optimize`.  Measured on the Xeon E-2236 test host at a pinned clock:
XenForo's gzip was 12 % of php-fpm CPU on a member thread page; moving it
gave member home +5 % (473 -> 497 req/s) and member thread +9 % (261 -> 285),
p99 566 -> 503 ms on the thread page.  The `src/config.php` block below is
kept as a second guard for older trees; `XF_MEMBER_GZIP=xenforo` no longer
makes XenForo compress uncached pages.

Compression is split (`XF_MEMBER_GZIP=nginx`, the default; a 1.21 value
`angie` means the same): every XenForo `src/config.php` gets a managed block
at its end, `$config['enableGzip'] = !isset($_COOKIE[<prefix>session]);`.
Guests keep XenForo's own level-9 gzip, which the guest cache stores once,
and a hit costs no compression; visitors with a session get plain HTML that
nginx compresses at level 4 (XenForo's gzip was 15 % of member-page PHP
CPU).  Measured: member thread +4 %, guest cache unchanged; turning
XenForo's gzip off for everyone dropped guest-cache hits from 104k to 6.8k
req/s (nginx then compresses every hit).  The block is linted before it is
written.  An earlier one-statement `$config['enableGzip'] = ...;` line
(older installs carry `= false;`) is a duplicate next to it and is commented
out with a `// setup.sh superseded (enableGzip block below): ` prefix;
`SETUP_XF_MEMBER_GZIP=xenforo` removes the block and restores that line
exactly.

The vhost serves guest pages from the FastCGI cache for 5 minutes with a
map-based bypass for `xf_session`/`xf_user`/admin/login cookies, a key that
varies on style, style variation, language and `Accept-Encoding`, background
refresh and stampede lock, 301 for 1 h and 404 for 1 min, never 5xx, an
immutable 30-day location for `/js`, `/styles` and `/data`, and the
server-level security headers re-included inside the PHP locations (a
location-level `add_header` would otherwise drop HSTS). `--optimize` repairs
or completes the same block on older hosts. Application-side findings from
the test host: disable the
"Members online", "Trending" and "Featured" forum-list widgets if unused
(+39% authenticated throughput) and use
`$config['db']['host'] = 'p:localhost'` for persistent connections.

The XF data cache is a host-specific decision. With **php-redis** loaded and
Valkey on the local Unix socket it measured **+7–9 %** authenticated
throughput on the 1.21.23 audit (PHP 8.5, Ubuntu 26.04); with the add-on's
pure-PHP Credis fallback (php-redis absent) it measured ~27 % slower than
MariaDB on the same host class.  The PHP build adds `redis` and `igbinary`
by itself when `src/config.php` selects XenForo's own `Redis` provider; an
add-on that uses Credis does not trigger it, so add `--php ext=redis` to
give it php-redis.  Keep the cache when `redis` is in `php -m`, disable it
for Credis, and re-measure on the actual stack.

### MariaDB (`--mariadb`)

| Option | Default | Effect |
|---|---|---|
| `user=U` | required | admin user, created for `localhost`, `127.0.0.1` and `::1` (needed with `skip_name_resolve`) |
| `pass=P` | required | its password; also written to `/etc/mysqlbkup.cnf` (mode 600) |
| `size=auto\|4gb` | `auto` | InnoDB buffer pool: `auto` = live data+index plus 5% (128 MB minimum; capped at 80% of RAM when MariaDB is the only data service, otherwise at half of RAM). A live pool more than one 5% step plus one InnoDB chunk (128 MB, or the live `innodb_buffer_pool_chunk_size` when larger) above the target is shrunk to it online (no restart on MariaDB 10.9+, where the redo log resizes online too; the first 1.21.49 run restarts once where a small pool had capped the redo log buffer), so the pool never holds RAM the data does not use; a live empty database gets 128 MB, and only a fresh install with nothing to measure uses the RAM-proportional floor (`clamp(RAM/16, 256 MB, 4 GB)`). The redo log is 25% of the pool (at least the log buffer, so a shrink stays online). `loose-innodb_buffer_pool_size_max` = 80% of RAM lets a pool grow online after a restart (address space only; ignored by releases without it, and never itself a reason to restart). An explicit size is reserved verbatim |
| `bind=ADDR[,ADDR...]` | `127.0.0.1` | comma-separated IPv4 addresses and/or `::1`; `IPV4` resolves the public address and falls back to the local outbound IPv4 behind NAT. TCP 3306 is never opened in the firewall |

MariaDB stays the apt package (`mariadb-server`, `mariadb-client`) and needs
the 4 GB class.

Environment option:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_MARIADB_IO_CAPACITY="r m"` | by disk and host class | pins `innodb_io_capacity` and `innodb_io_capacity_max` for an install/one run; `--optimize` ignores it |

After a large `--domain ... sql=` import or an application-level bulk seed, run
`--optimize` again (or pass `--mariadb size=...`) so the buffer pool is
re-planned against the new data size.  `--diagnostics` warns when the live
data is larger than the current pool; a host that was sized while the
database was empty keeps the small value until the next optimize run, which
sizes the pool to data+5% in either direction.

Installed:

| Item | Detail |
|---|---|
| Packages | `mariadb-server`, `mariadb-client` |
| Service files | systemd `LimitNOFILE` drop-in; the AppArmor capability override Ubuntu 26.04 needs for `mariadb-install-db` |
| Tools | embedded `mysqltuner.pl` and the `mysqlbackup` utility (`/etc/mysqlbkup.cnf`, 30 dumps kept; a re-run keeps an existing `/etc/mysqlbkup.config`) |
| Validation | the generated files are checked with `mariadbd --help --verbose` before any restart |

Base block (`50-server.cnf`):

| Setting | Value |
|---|---|
| Character set | utf8mb4 |
| `skip_name_resolve` | on |
| `innodb_snapshot_isolation` | 0, so REPEATABLE READ keeps MySQL's behaviour and XenForo does not hit MariaDB error 1020 |
| `local_infile` | 0 |
| `secure_file_priv` | set |
| `bind-address` | from `bind=`; a commented-out `bind-address` is left alone by `--optimize` |

Hardware profile (`99-setup-optimize.cnf`):

| Setting | Rule |
|---|---|
| Buffer pool | from the plan (see `size=`) |
| Redo log | pool/4 (64 MB..4 GB on NVMe, 2 GB otherwise) |
| `innodb_io_capacity` / `_max` | NVMe 10000/20000 (VPS 3000/6000); SSD 4000/8000 (VPS 1000/2000); HDD 400/800 with `flush_neighbors=1` |
| I/O threads | `clamp(threads/2, 4, 16)` |
| `thread_handling` | `pool-of-threads`, sized to the CPUs |
| `max_connections` | PHP workers x 1.25 + 50 (threads x 32 without PHP), 200..2000, never below a live larger value |
| Table caches | `clamp(max_connections x 16, 4000, 32768)` |
| Temp tables | `clamp(RAM/256, 32, 256) MB`, capped at pool/8 |
| `flush_log_at_trx_commit` | 2: the redo log is written at each commit but flushed to disk about once a second, so an OS crash or power loss can lose up to about 1 s of committed transactions (a MariaDB crash alone loses none).  For full durability put `[mysqld]` `innodb_flush_log_at_trx_commit = 1` in a file that sorts after the managed one, e.g. `/etc/mysql/mariadb.conf.d/99-zz-local.cnf` (setup.sh never edits it), and restart MariaDB; it costs one fsync per commit |
| Logs | slow log (1 s, 100 rows, plan+explain) and `log_error` under `/var/www/logs/mariadb/` |

### Valkey (`--valkey`)

| Option | Default | Effect |
|---|---|---|
| `ram=SIZE` | data +20% (128 MB minimum), data = the larger of `used_memory` and its peak since start. A maxmemory more than 10% above that shrinks to it online. An `allkeys-*` cache that fills 83-102% of its maxmemory keeps it (an LRU cache fills any size; `ram=` grows it); a `volatile-*` cache follows its data both ways, except one that has already evicted keys (`evicted_keys` > 0), which is kept like an `allkeys-*` one. A stopped cache, or one started less than a day ago, never shrinks; the floor RAM/64 clamped to 128 MB..1 GB only when no maxmemory is in force and the cache is not measured or started less than a day ago | `maxmemory`; an explicit value is used verbatim |
| `policy=NAME` | `allkeys-lru` | `maxmemory-policy`.  `noeviction` was removed in 1.22.5 (a full cache failed every write; a host that had it moves to `allkeys-lru` on the next `--optimize`).  An adopted Redis/Valkey that keeps its operator AOF persistence (`appendonly yes`) keeps `noeviction` (a data store).  Sessions in Valkey survive clean restarts and reboots through the RDB snapshot (after a crash or power loss the cache starts empty); under memory pressure `allkeys-lru` may evict them, so size `ram=` to hold sessions plus cache.  Never `volatile-*` for sessions: session keys carry a TTL, so `volatile-*` evicts them first |
| `tcp=auto\|on` | `auto` | `auto`: Unix socket only (`port 0`) unless a WordPress (incl. W3 Total Cache, LiteSpeed Cache or an unknown object-cache drop-in), XenForo, Chevereto or PHP session-handler config connects over loopback TCP, a connected client or a recent TCP connection (sampled 3 times, TIME-WAIT included) uses the port, the running server's clients cannot be listed, or an operator bind serves other hosts (the report names them).  `on`: keep TCP 6379 open (persisted in `valkey.conf`, or in `redis.conf` for an adopted redis-server; `tcp=auto` undoes it); `--purge valkey` restores the TCP port |

**What it is.**  Valkey from its newest GitHub release (pin another in
[`valkey-build.conf`](valkey-build.conf)), compiled with clang at `-O3
-march=native` with the hardening flags and full LTO, with Valkey's bundled
jemalloc and Lua (the XenForo Redis add-ons run Lua scripts) and without TLS
(the applications use the Unix socket), then rewritten by LLVM BOLT from a
perf profile of a `valkey-benchmark` run (GET/SET/HSET/LPUSH/MSET/INCR)
against a private, throwaway server started from the LTO binary on a socket
in the work directory (no port, no persistence, 512 MB), so it needs no live
traffic and never writes to the live cache.  It links only glibc.  A new build serves only after
it answered PING, a Lua `EVAL` and `SAVE` on a private socket.

| Install | Detail |
|---|---|
| Binaries | `/usr/local/lib/setup-valkey/bin/valkey-server`, `valkey-cli`, `valkey-benchmark`, `valkey-check-aof`, `valkey-check-rdb`; links in `/usr/local/bin` |
| User and data | `valkey` system user and group (created when missing), `/var/lib/valkey` 0750, `www-data` in the `valkey` group |
| Unit | `/etc/systemd/system/valkey-server.service` (alias `valkey.service`), `Type=notify`, `User=valkey`, `ProtectSystem=strict`, `NoNewPrivileges`, `MemoryDenyWriteExecute`, `NoExecPaths=/` with `ExecPaths` limited to the build and the system libraries, `LimitNOFILE=524288` |
| Configuration | `/etc/valkey/valkey.conf`, seeded on a host without one; the managed keys below are written by setup.sh |

**Versions.**  The managed `valkey.conf` keeps RDB snapshots (`save 300 1`,
`appendonly no`).  A newer Valkey loads an older RDB, so the newest release
is safe to run; the build never goes below the version of the server that
wrote the data (an older server cannot read a newer RDB/AOF).  With AOF
(`appendonly yes`, kept on an adopted server) `latest` also stays inside the
X.Y series of that server.

Managed `valkey.conf`:

| Setting | Value |
|---|---|
| Network | Unix socket only (`port 0`) by default; TCP stays open, and the report says why, when an application config or a connected client uses TCP, an operator bind serves other hosts, or `tcp=on`.  Loopback bind (`127.0.0.1 ::1` on Redis below 6.2), `protected-mode` |
| Socket | `unixsocket /run/valkey/valkey.sock`, mode 770, with `www-data` in the `valkey` group |
| Persistence | RDB snapshot every 5 minutes when a key changed (`save 300 1`) and on every clean shutdown, `dump.rdb` in `/var/lib/valkey` (or the adopted server's `dir`/`dbfilename`), `rdbcompression yes`, `rdb-save-incremental-fsync yes`, `stop-writes-on-bgsave-error no`, `appendonly no`: the cache and sessions survive clean restarts, reboots, rebuilds and BOLT.  The snapshot loads only after a clean stop: after a crash, an OOM kill, kill -9 or a power loss the cache starts empty (the snapshot is moved aside to `dump.rdb.unclean-<UTC>`, 2 kept), so stale entries never contradict the database.  `TimeoutStopSec=300` and `shutdown-on-sigterm default force` (Valkey, Redis 7+): a final save that cannot finish never hangs a stop or a reboot (an adopted redis-server gets the same through a drop-in).  `--purge valkey` warns when the kept `dump.rdb` was written by a newer build than a packaged Valkey can read.  The `--optimize` report shows the snapshot fork's worst-case copy-on-write against the RAM outside the memory plan.  `--optimize` keeps `appendonly yes` and a non-loopback `bind` of a Redis/Valkey it did not install; `--purge` keeps the data |
| `maxclients` | PHP workers x 4 + 2000, minimum 10000 |
| Other | `tcp-backlog`, `hz 10`, lazy-free |

| Measured (1.21.71 recipe, Unix socket, 5 rotated rounds) | Package 9.0.6 | Compiled 9.2.0 + BOLT |
|---|---:|---:|
| GET / SET, 50 connections, pipelined 16 | 1,067,806 / 978,234 req/s | **+3.1 / +2.6 %** |
| GET / SET / HSET / LPUSH / MSET, no pipelining | 126,518-136,221 req/s | 0 to +1.5 % |
| Share of a member page's server CPU | ~0.3 % | unchanged in practice |

Notes:

- Skipped with a warning when `redis-server` is installed; `--optimize` then
  tunes Redis with the same profile. Valkey wins when both exist.  A Redis
  server is never replaced.
- Runtime values (the snapshot schedule and the port included) are applied
  with `CONFIG SET`; a restart happens only for startup-only keys or a new
  binary, and it saves and reloads the snapshot.
- With php-redis and this Unix socket, XenForo's data cache measured +7–9 %
  authenticated throughput; without php-redis (the add-on's pure-PHP Credis
  client) it measured slower than local MariaDB. See the XenForo section.
- A host still serving through the valkey-server package must run
  `--optimize` first (the one-time migration); `--valkey` refuses until it
  has.
- `SETUP_VALKEY_BUILD_BOLT=0` skips the BOLT pass.

### Elasticsearch (`--elastic`)

| Option | Default | Effect |
|---|---|---|
| `host=NAME` | `localhost` | `network.host`; keep `localhost` unless X-Pack security, TLS and a firewall are in place |
| `ram=4g\|auto` | `auto` | JVM heap: `auto` = index store/4 rounded to 512 MB, between 512 MB and 25% of RAM (31 GB ceiling) |

Installed and configured (apt package; needs the 4 GB class):

| Item | Detail |
|---|---|
| Repository | Elastic 9.x |
| `elasticsearch.yml` managed block | `network.host`, single-node discovery, X-Pack security off, `bootstrap.memory_lock`, bool clause/bucket limits, index buffer and fielddata 20%, compression, 200 MB content limit |
| Index in RAM | the memory plan reserves the whole index store (+5% growth) as page cache, taking only from PHP's share; when it fits, `index.store.preload: ["*"]` loads every index file at open (after each restart and boot). Hysteresis: switching on needs the growth room, staying on only the index itself, so a store at the edge does not restart Elasticsearch on every run |
| Thread pools | search `clamp(cpus/2, 1, 16)`, write `clamp(cpus/4, 1, 8)` |
| Heap file | `jvm.options.d/zz-setup-optimize.options`; an operator-owned `jvm.options` is kept |
| System | systemd `LimitMEMLOCK=infinity`, `UMask=0027`, `vm.max_map_count` |
| Single node | yellow health caused by unassigned replicas is fixed (replicas 0 plus a low-priority template) |
| Probe endpoint | follows `http.host`/`network.host`/`http.port` |

### Other packages (`--others`)

Name one or more items, or `all`.

| Item | Installs | Notes |
|---|---|---|
| `smartmon` | `smartmontools` | |
| `nvme` | `nvme-cli` | dedicated host with NVMe storage only |
| `gif` | `gifsicle` | |
| `nodejs` | Node.js from NodeSource | major from `SETUP_NODE_MAJOR` (default 26). An installed major is never switched silently because the native-addon ABI changes: pin it, or set `SETUP_NODE_ALLOW_MAJOR_UPGRADE=1` |
| `sysstat` | `sysstat` with its timers | `sar`/`iostat` performance history |
| `all` | everything above | |

### Domains (`--domain`)

`--domain DOMAIN [app=TYPE] [db=NAME [user=U pass=P] [sql=FILE]] [DOMAIN ...]`

Standalone; needs nginx, and MariaDB when `db=` is given. It can be repeated
and combined with an install. Options follow the domain they belong to.

| Option | Default | Effect |
|---|---|---|
| `DOMAIN` | required | the site's host name |
| `app=TYPE` | `basic` | vhost template: `basic`, `xf`, `wordpress`, `flarum`, `pingvin`, `chevereto`, `polr`, `lychee`, `shlink`, `sfs`, `php`, `node`.  A PHP app adds its extension set to the PHP build; PHP is rebuilt first when the set grows.  PHP apps need the 4 GB class (`basic`, `node` and `pingvin` do not) |
| `db=NAME` | none | create the database (utf8mb4); only when declared |
| `user=U pass=P` | none | create that user with `ALL` on `db=` only, for the three loopback hosts; both are required together |
| `sql=FILE` | none | import a dump (`.sql`, `.gz`, `.xz`, `.zst`, `.bz2`) into `db=` while it is still empty, then re-size MariaDB (and the Valkey/Elasticsearch shares it was taken from) |

Environment option:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_DOMAIN_OPTIMIZE=0` | on | skips the closing tuning pass, for a deployment script that copies the application files afterwards and tunes separately |

Created per domain:

| Path | Content |
|---|---|
| `/var/www/<domain>/public/` | document root owned by www-data |
| `/etc/nginx/ssl/<domain>/` | self-signed certificate (for Cloudflare "Full" mode; replace with your own for direct TLS) |
| `/etc/nginx/conf.d/<domain>.conf` | vhost rendered from the repository template and tested with `nginx -t` |

Notes:

- A dump that carries its own `CREATE DATABASE`/`USE` for another schema
  (taken with `--databases`) is refused before anything is loaded.
- Existing vhost files and databases are preserved (an existing tree is not
  re-chowned). Application code is not installed.
- On a host that still serves through Angie (vhosts in `/etc/angie`),
  `--domain` refuses until `--optimize` has migrated it.

The run ends with the same tuning pass `--optimize` performs, because a new
vhost changes the plan (PHP-FPM worker cap, OPcache file budget, guest cache
for the new root, managed wp-cron / XenForo job entries): a domain install
therefore leaves the host in the state "install, then `--optimize`" produced.
`SETUP_DOMAIN_OPTIMIZE=0` skips that pass for a deployment script that copies
the application files afterwards and tunes separately.  The pass runs after
the installation summary, in the main process: an interrupted run resumes a
web tier it paused for a MariaDB restart, and a failed tuner ends the run with
a non-zero exit and the optimize report, exactly like `--optimize`.

## `--optimize`

| Option | Effect |
|---|---|
| `--optimize` | tune the OS and every installed service in place (Ubuntu 22.04, 24.04, 26.04) |
| `--optimize mitigations=off` | the same (`mitigations=off` is the default and changes nothing; `mitigations=on` was removed, see `--basic`) |
| `--optimize --dry-run` | print the planned OS and service values, the build plan and, on a 1.21.x host, the migration plan; runs as a normal user |

Tunes the OS and every installed service in place. It never installs a new
service, never starts or purges a managed service outside the one-time
migration, and never touches swap, the resolver (DNS) or the firewall (UFW),
which stay as `--basic` or the operator left them.  The only packages it may
add are the build prerequisites (compilers and autotools, cmake, ninja, nasm, git,
gpgv, perf from `linux-tools` for the running kernel, the apt.llvm.org
toolchain); the only packages
it may remove are certbot, once nothing uses it (see Cloudflare-proxied
sites below), and, once, the replaced packages of a 1.21.x host (see
[Upgrading from 1.21.x](#upgrading-from-121x)).  The drivers run with
`set -e` live, so a failed write inside a tuner aborts the run with its line
number instead of being skipped.  Steps:

1. One-time migration, on a host provisioned by 1.21.x only (Angie, Sury PHP
   or the valkey-server package present).  On every other host this step
   does nothing.
2. Source builds: a build whose release, recipe, CPU or extension set is
   stale is rebuilt while the running binary serves; after the tuning, each
   build that has not been BOLTed yet gets its BOLT pass from live traffic.
3. OS profile (governor, PAM limits, sysctls) and the security pass.
4. nginx: `/etc/nginx` is synced from `server-configs-nginx`, the WordPress
   and XenForo guest caches are enabled or repaired (shared `fastcgicache`
   zone, `$nocacheuri` and cookie-bypass maps), the hardware profile is
   applied, `nginx -t` runs, and the service is reloaded **once, and only
   when the tree digest changed**; a failed sync or test restores the
   previous tree. Legacy underscore-named `http.d` files are tuned in place.
   A WordPress vhost without `include h5bp/wordpress_cache.conf;` gets the
   include added before its `php_wp.conf` include (the guest cache is on by
   default); set `SETUP_WP_GUEST_CACHE=0` to keep such vhosts uncached, in
   which case they are reported instead and an include an earlier run added
   (the line marked `# added by setup.sh`) is removed again. Every application's guest cache
   reports its result in the same `X-Cache-Status` header (`HIT`, `MISS`,
   `BYPASS`, `EXPIRED`).
   **Cloudflare-proxied sites** (SSL mode "Full") move off certbot to the
   host's self-signed `/etc/nginx/ssl/default` pair:
   - A server block qualifies only when it sets its own certbot
     `ssl_certificate` and `ssl_certificate_key`, and every name it serves is
     an exact host name resolving solely to Cloudflare (ranges from
     `http.d/cloudflare.conf`). A wildcard, regex or `.suffix` name keeps the
     block where it is.
   - Only the two certificate paths change. certbot's options include,
     dhparam and trusted chain are removed, and a probe location
     (`/.setup-cf-tls-probe-<digits>`, 204 with the digits echoed) is added.
   - After the reload, each name must echo a fresh probe through Cloudflare.
     Only a new worker with the new certificate can answer it, so a cached
     answer, a challenge, a redirect or a 526 ("Full (strict)") is not
     proof. Without the proof the vhost is put back byte for byte, with a
     `# setup-cf-tls: keep` first line that later runs respect.
   - certbot is then purged when the loaded nginx configuration (`nginx -T`)
     and every hook, container mount, symlink and non-comment reference under
     `/etc`, `/opt`, `/srv`, `/usr/local`, `/root`, `/home`, the crontabs
     and the web-root app configs leave it unused (copies of this project, nginx
     config trees outside `/etc/nginx` and `*.log` files are not consumers). `/etc/letsencrypt` moves
     to `/var/backups/setup-letsencrypt-*` (0700).
   - A kept certbot whose renewals use the missing nginx plugin is reported
     as a warning.
   - `SETUP_CF_SELF_SIGNED=0` (persisted as `CF_SELF_SIGNED=0`) skips all
     of it.  It does not stop the migration from moving Angie ACME vhosts to
     the self-signed pair: nginx cannot parse those directives.
5. PHP-FPM: every `/etc/php/<ver>/fpm` tree; a live TCP pool used through the
   `local_php` upstream is migrated to the Unix socket (graceful reload, or
   a short explicit restart when SIGUSR2 cannot open the listener).  The pool
   is always `pm = static`, one worker per logical CPU when a local database
   and flash storage share the host, 1.5 on a shared CPU or remote database,
   2.0 on spinning disks (see the hardware table); a pool sized by hand is
   normalised to that rule, and the report names the before/after and the
   resident memory it returns (a 64-thread board left on 512 static workers
   is set to 64).
6. MariaDB, Valkey/Redis and Elasticsearch from the shared 80%-of-RAM plan:
   live data is funded first (MariaDB data+index plus 5%, Valkey working set
   +20%, Elasticsearch heap store/4 plus the store +5% as page cache), explicit sizes are
   reserved verbatim, PHP is sized from the remainder, and targets that do not
   fit are trimmed Elasticsearch first, then Valkey, then MariaDB. A MariaDB
   pool or Valkey maxmemory well above data+5% / data+20% is shrunk online,
   so no service holds RAM its data does not use, and the redo log is 25% of
   the pool. The plan also books memory no setting names:
   the Elasticsearch direct (off-heap) ceiling -- heap/2 by JVM ergonomics,
   or an operator `-XX:MaxDirectMemorySize` from `jvm.options` or
   `jvm.options.d` (below 4 GB part of it may sit in the OS headroom above a
   10% floor) -- and the OPcache huge-page reservation.  Neither is written
   to any configuration; the summary line shows them as `ES-direct=` and
   `HugePages=`.  A kept MariaDB pool that no longer fits gives up its
   surplus over the data target first (never below 256 MB), so one run
   settles it.  A MariaDB restart pauses nginx and PHP
   first and resumes them after `SELECT 1`; when only dynamic variables
   changed (buffer pool, redo log, `tmp_table_size`/`max_heap_table_size`,
   `innodb_io_capacity`(_max), `table_open_cache`, `max_connections`,
   `thread_pool_size`, `innodb_flush_neighbors`) they are applied online with
   `SET GLOBAL`, each read back, and nothing restarts. A startup-only key or
   the managed base block still needs a restart.
   A `--domain ... sql=`
   import re-plans MariaDB **and** the Valkey/Elasticsearch shares it was
   taken from. Every failed service is rolled back from
   `/tmp/setup-optimize.*` through one shared restart/rollback helper (files
   created during the tune are moved out of the tree so a rejected drop-in
   cannot win again).
7. Audit of WordPress/XenForo configs (persistent `p:` database host, Valkey
   socket) with the exact snippets to apply; application files are never
   edited and **application schemas are never altered** (see "Manual
   follow-ups" below for changes worth making by hand). Legacy cron and
   `/var/www` ownership from releases before 1.8.34 are repaired.
8. Verification of every listener (`ss`, SQL, PING, HTTP) and recent
   error-level journal entries. The Markdown report goes to
   `/var/log/setup-optimize-<timestamp>.md` (`-latest.md` copy); it lists
   every build's version and the effective PHP extension set.

Below the 4 GB class, `--optimize` tunes nginx and leaves PHP and Valkey as
they are (reported).

Explicit values (`--basic server=`, `--php children=`/`max_requests=`,
`--mariadb size=`, `--valkey ram=`, `--elastic ram=`) are recorded in
`/var/lib/setup.sh/explicit-options.conf` for the installation run. They are
not a permanent override: `--optimize` always moves that file to `/tmp` and
recomputes workers, pool sizes and the dedi/vps class from the current
hardware, so a fleet with the same hardware converges on one profile.  The
one exception is the closing tuning pass of a run that installs services and
adds a `--domain` in the same command: that pass keeps the run's own explicit
values and `SETUP_*` tuning (a domain-only run resets like `--optimize`). An
under-floor `--mariadb size=`/`--valkey ram=` is still raised to 128m with a
warning so install and the first `--optimize` agree.

Install and `--optimize` write the same files from the same functions. The
one documented difference is timing: `--domain app=xf|wordpress` creates an
empty document root, so the application-aware PHP worker cap and the
per-root OPcache JIT sections can only apply once the application files
exist, on the first `--optimize` after the upload (or after a `sql=` import).

## Upgrading from 1.21.x

A host provisioned by 1.21.x serves through Angie, Sury PHP-FPM packages and
the valkey-server package (optionally with the 1.21 compiled binaries).  The
first `--optimize` of 1.22 moves it to the compiled nginx, PHP and Valkey
once, without a window where nothing serves.  Preview it first:

```bash
bash setup.sh --optimize --dry-run     # migration plan, nothing changes
sudo bash setup.sh --optimize          # migrates, then tunes as usual
```

`tools/fleet-update.sh` does the same rollout with its own checks (at least
6 GB free on `/` by default) and runs `--optimize` as a transient unit.

**What it does**, in order:

1. Drops the 1.21 build knobs from `/etc/default/setup-tuning` (a copy is
   kept) and retires the 1.21 build timers, APT hooks and rebuild units.
2. Read-only pre-flight: Angie-only directives in `/etc/angie`, directives
   the nginx build cannot serve, an apt simulation of every package removal,
   free disk, the memory class, and the PHP extensions every running Sury PHP
   loads.
3. Builds nginx, the active PHP version (FPM and CLI) and Valkey while
   Angie, Sury and the valkey-server package keep serving, then tests a copy
   of the Angie tree with the new nginx.  The active version is the one
   Angie's `local_php` upstream serves, else the one the vhosts'
   `fastcgi_pass` lines call most, else the newest; only a series the
   source build can make (8.1 or newer, released on php.net) qualifies.  A
   second running Sury version stays on Sury (one active version per host)
   until its sites move.
4. Renders `/etc/nginx`: the server-configs-nginx tree plus the operator's
   files from `/etc/angie` (vhosts, `custom.d`, snippets, `ssl/`, htpasswd
   files, `http.d` files the tree does not ship, preserved upstreams), with
   `/etc/angie/`, `/var/www/logs/angie`, `/var/cache/angie`, `/run/angie.pid`
   and `user angie` rewritten to their nginx equivalents.  Package files of
   Angie are never copied.  A pre-existing distro nginx is moved aside and
   purged first.
5. Angie ACME vhosts (`acme`, `acme_client`, `$acme_cert_*`) move to the
   host's self-signed certificate; the `acme_client` definitions and
   `/var/lib/angie/acme` go to the backups.  Each changed vhost is reported,
   and a vhost that is not behind Cloudflare is listed in a warning block.
6. `nginx -t` with the new binary, then the hardware profile, then the
   cutover: Angie stops (and is masked), nginx starts and every vhost is
   probed through 127.0.0.1 with its Host header, `auth_basic` locations
   included (401 expected).  The Angie cron lines are rewritten to
   `/etc/nginx/scripts/cloudflare.sh`.  Directives the build cannot serve
   (for example `sub_filter`) are commented out with the
   `# setup-nginx-build-off: ` marker and reported.
7. PHP, per active version: snapshot of `/etc/php/X.Y`, the Sury unit stops,
   Sury's `conf.d` module links move to the backups (`extension=` lines in
   operator `.ini` files are commented with `; setup-1.22-off: `), our layout
   and unit are written, and the version starts on the same socket.  It must
   pass `php-fpm -t` without load warnings, show OPcache active and answer a
   PHP page of every detected root with a status below 500.  The build keeps
   every extension the Sury PHP loaded that the source build can compile, in
   addition to the applications' sets (recorded in `PHP_EXT_EXTRA`; trim it
   later with `--php ext=-NAME`).  From the cutover on, Sury's
   `/usr/bin/phpX.Y` is diverted to `/usr/bin/phpX.Y.sury` (`dpkg-divert
   --local`) and the source CLI linked in its place, so cron and
   `/usr/bin/php` run the source build even while the Sury purge waits; the
   version's Sury packages are held until that purge.  Settings an operator
   changed in Sury's `php.ini` are kept in `conf.d/10-migrated-php-ini.ini`.
8. Valkey: the package server stops first (so a persisting configuration
   writes its RDB), then `/etc/valkey` and `/var/lib/valkey` are
   snapshotted, our unit starts and must answer PING.
9. Removals, only for parts that passed: Angie (packages, repository, key,
   `angie` user when it owns nothing else; `/etc/angie` moves to the backups
   first), the Sury PHP packages (repository and keyring included), and
   `apt-get remove` (never purge) of valkey-server and valkey-tools.  Then
   our `/etc/php` files are re-laid, every unit is enabled and checked, and
   everything is verified again.  `angie.service` becomes an alias of
   `nginx.service`, so a legacy `systemctl reload angie` reaches nginx.
10. Report: every changed vhost, commented directive, crontab line that runs
    PHP, and file that still references `/etc/angie`, `angie.service` or
    `/var/www/logs/angie` (cron, systemd, logrotate, fail2ban, certbot
    renewal hooks).  BOLT passes are queued 5 minutes later
    (`setup-migrate-bolt-1.22`), after traffic has warmed the new binaries.

Expected cutover windows: about 1-3 s for nginx between the Angie stop and
the nginx start, about 1 s per PHP version, and one Valkey restart (the
dataset reloads).

**Safety rules.**

- The migration runs as the transient unit `setup-migrate-1.22`, so a
  dropped SSH session does not stop it.  Re-running `--optimize` while it
  runs only follows the log again.
- It is resumable: the state of every part is kept in
  `/var/lib/setup.sh/migrate-1.22`, and an interrupted run first rolls back
  the step it was in, then continues.
- Each part (nginx, each PHP version, Valkey) rolls back on its own: a
  failed probe stops the new service and starts Angie, Sury or the package
  server again.  Nothing is purged for a part that did not pass.
- Every purge is guarded: exact package lists (never a glob), and an
  `apt-get -s` simulation must remove nothing outside the list.
  `libapache2-mod-php*` is never in the list.  When the Sury purge would
  remove another package, it is deferred, the remaining Sury packages are
  held (`apt-mark hold`) and the report names the blockers;
  `SETUP_PHP_ALLOW_COLLATERAL=1` accepts the collateral.
- During the removals a temporary `/usr/sbin/policy-rc.d` denies only our
  unit names (nginx, angie, php*-fpm, valkey-server), so maintainer scripts
  cannot stop or disable the new services.  It carries a marker and is
  removed by a trap and by every later run.  An existing `policy-rc.d` is
  kept.
- The run ends with one enable pass and an `is-enabled` check of every
  unit, so the services come back after a reboot.

**Backups.**  `/var/backups/setup-1.22` (0700 root, never deleted by
setup.sh) keeps the `.deb` files of every removed package and their
repository files (`debs-<stamp>`), `/etc/angie` (`angie-<stamp>`), the
`/etc/php` and `/etc/valkey` snapshots, the Valkey data snapshot, the Angie
ACME state and any distro `/etc/nginx` that was moved aside.

**Rollback.**  Until the removals, rollback is automatic per part.  After
them it is manual: `dpkg -i` the saved `.debs` from
`/var/backups/setup-1.22/debs-<stamp>/`, restore the `/etc` trees from
`/var/backups/setup-1.22`, then `systemctl daemon-reload` and restart the
units.  If the services do not verify after the removals, the run tries one
repair, then marks the state `post-purge-failed`, prints these steps and
exits non-zero.

**Watching it.**  The terminal follows `/var/log/setup-migrate-1.22.log`.
From another session:

```bash
tail -F /var/log/setup-migrate-1.22.log
systemctl status setup-migrate-1.22
cat /var/lib/setup.sh/migrate-1.22          # state of each part
```

**A blocked part (legacy-Angie state).**  When the nginx part is refused
(an Angie-only directive such as `js_*`, `status_zone`, `api`, `sticky` or
`$angie_*`, a directive that cannot be commented out, an apt collateral) or
rolled back, Angie keeps serving and the host stays in the legacy-Angie
state: `--optimize` reports the reason and skips all web tuning (it never
touches `/etc/angie`), `--restart-all` restarts Angie as it is,
`--diagnostics` shows the state, `--purge nginx` stops Angie, and `--nginx`,
`--domain` and `--upgrade-php` refuse.  PHP and Valkey can still migrate on
their own.  Fix the blocker and run `--optimize` again.  A part blocked on
an unchanged configuration is not retried on every run; a new setup.sh
release or `SETUP_MIGRATE_RETRY=1` retries it.  A PHP version whose sites
need an extension the build cannot provide (for example imagick for an
application that requires it) stays on Sury the same way
(`SETUP_PHP_ALLOW_MISSING_EXT=1` drops it).  This includes redis on PHP
8.6: phpredis 6.3.0 does not compile against 8.6.0, so an 8.6 host with
Chevereto or a XenForo Redis cache keeps Sury 8.6 until a phpredis release
supports it (or its sites move to 8.5); an 8.6 host without them migrates.
PHP 8.0 and unreleased series (a Sury RC) are refused the same way, before
anything is built, and retried once php.net releases the series.

Measured on the Xeon E-2236 test host: a 1.21.71 host (Angie package, Sury
PHP 8.5, valkey-server package, three applications, an Angie ACME vhost and
an `auth_basic`/`sub_filter` vhost) migrated with the security suite at
78/78, the cookie suite at 105/105 and the functional walk at 0 failures
afterwards; after a reboot nginx, php8.5-fpm and valkey-server were active
and enabled, no unit failed and every site answered 200.  A second
`--optimize` found nothing to migrate and every build current.  The
valkey-server and valkey-tools packages stay in dpkg's config-files (`rc`)
state on purpose: their purge would delete `/var/lib/valkey`.  1.22.3 repeated
it on replicas of every Sury series 8.1-8.6, one host with PHP 8.5 plus a
running 8.3, an Ubuntu 24.04 host (PHP 8.3, Valkey 7.2 package) and a 2
vCPU/4 GB Angie-only front proxy (AUDIT-20261126-1.22.3.md).

## Profile pins and tuning overrides

`--optimize` always recomputes the whole profile from the current hardware.
It no longer has an opt-in reset flag: every recorded tuning override is
ignored and moved to `/tmp` (never deleted) before the tuners run, and tuning
environment variables are ignored with a warning. Two servers with the same
hardware therefore get the same profile.

What the reset does on every `--optimize`:

| Moved/ignored | Detail |
|---|---|
| `/etc/default/setup-tuning` | rewritten with only host facts/feature choices: `XF_JOB_CRON`, `NODE_MAJOR`, `NODE_ALLOW_MAJOR_UPGRADE`, `PHP_EXT_EXTRA`, ... Old `TCP_CC`, `QDISC`, `STORAGE_CLASS`, compression/JIT/page-cache and rate-limit pins no longer survive |
| `/var/lib/setup.sh/explicit-options.conf` | moved to `/tmp`; recorded `php_children`/`max_requests`, MariaDB/Valkey/ES sizes and the dedi/vps pin are dropped and the shared memory plan recomputes them |
| tuning environment | `SETUP_TCP_CC`, `SETUP_QDISC`, `SETUP_STORAGE_CLASS`, `SETUP_PHP_WORKERS_PER_CPU`, `SETUP_BROTLI_LEVEL`, `SETUP_NGINX_COMPRESSION`, `SETUP_MARIADB_IO_CAPACITY`, `SETUP_LIMIT_REQ_EXEMPT`, `SETUP_PHP_PAGE_GZIP`, `SETUP_PHP_JIT_WORDPRESS` are unset for the run and listed in the report/warning |

Feature choices are not performance overrides and still apply: `NODE_MAJOR`,
`PHP_EXT_EXTRA`, the WordPress/Chevereto cache and security toggles, and the
`CONFIG_*` source knobs.

What is still **preserved** (never moved or edited by the reset):

| Preserved | Where |
|---|---|
| extra PHP `.ini` files, extra FPM pools, nginx `custom.d/*.conf` | `/etc/php`, `/etc/nginx/custom.d` |
| third-party sysctl drop-ins/units | `/etc/sysctl.d`, `/etc/systemd/system` |
| application config (`wp-config.php`, XF `config.php`, `.env`) | `/var/www` |

Third-party sysctl files are left in place. To guarantee they cannot win
after the next reboot, `configure_sysctl` installs
`setup-sysctl-final.timer`: 90 s after boot, `setup-sysctl-final.service`
re-applies `/etc/sysctl.conf` and the selected qdisc/congestion control after
`multi-user.target`, i.e. after a hand-written `tcp-bbr.service`, `rc.local`
or a provider agent. `--purge basic` disables and removes both units.

Verify a host after the run:

```bash
# optimize report: "## Tuning drift" lists live-vs-profile mismatches and
# every non-managed file that still defines a managed key
sudo bash setup.sh --diagnostics
# then search the diagnostics log
grep -A40 'tuning override sources and live drift' /path/to/diagnostics.log
```

The audit is read-only. A file listed under “non-managed files that still
define a managed sysctl” is informational: the managed profile wins at boot;
move or edit the file only if you want its other keys to stop applying.

Fleet example:

```bash
for h in web1 web2 web3; do
  ssh root@"$h" 'bash /root/ubuntu-setup-script/setup.sh --optimize'
done
```

`tools/fleet-update.sh` packages the whole rollout for one host: non-interactive
APT (confold, lock timeout, `NEEDRESTART_MODE=l`), a snapd guard, a free-space
check, a timestamped backup of the previous checkout, a verified tarball
extraction, the dry run and the real run with separate logs (the real run as
the transient unit `setup-fleet-optimize`, so a dropped SSH session cannot
stop a build or a cutover), and a reboot notice. `REF=`, `SKIP_APT=1`,
`DRY_RUN_ONLY=1`, `FORCE_SNAPD_PURGE=1`, `REBOOT=1`, `MIN_FREE_MB=` (default
6144, never below 2048) and `DETACH=0` are the supported switches.

```bash
scp tools/fleet-update.sh root@web1:/root/
ssh root@web1 'bash /root/fleet-update.sh'
```

## `--upgrade-php=X.Y`

Switches the host to another PHP series in place.  Any series php.net has
released from 8.1 on is accepted, newer or older than the current one; the
newest X.Y.Z of that series is built, never an RC.

- PHP 8.0 and older are refused before anything changes.  8.0 has had no
  security fixes since November 2023 and does not build against OpenSSL 3.
- The 8.1 series has been end of life since 31 December 2025.  It does not
  compile against OpenSSL 4, so it builds with the newest OpenSSL 3.x.
- When a series' extension set does not compile yet, the build fails and
  nothing changes.  For example, the igbinary release did not compile on
  PHP 8.6 when 1.22.0 was released.

| Option | Effect |
|---|---|
| `--upgrade-php=X.Y` | target series (e.g. `8.6`) |
| `--dry-run` | prints the plan, the extension set and the application check without changing anything |

It is standalone and cannot be combined with install flags, `--optimize`,
`--purge`, `--diagnostics`, `--restart-all` or `--domain`.  It is refused
while the 1.22 migration of PHP is unfinished, while the web tier is still
Angie, and below the 4 GB class.

| Step | What happens |
|---|---|
| 1. Application check | detects WordPress, XenForo and Chevereto roots below `/var/www` and in the nginx vhosts (including a WordPress object-cache drop-in and a XenForo `config.php` that select Redis) and checks that every hard requirement is in the extension set the target will be built with.  If a site would lose one, the run stops before anything changes; `SETUP_PHP_ALLOW_MISSING_EXT=1` accepts the loss explicitly |
| 2. Build | builds X.Y (FPM and CLI) with the current effective extension set while the current version keeps serving (several minutes, no downtime) |
| 3. Layout | `/etc/php/X.Y` from the current version's pools (listen lines kept), operator `conf.d` fragments and the managed settings, then the managed `php.ini`, `php-fpm.conf`, unit and tmpfiles; `php-fpm -t` must pass clean before anything stops |
| 4. Handover | the current unit stops and X.Y starts on the same socket(s) (about a second without PHP); the active marker, `/usr/local/bin/php` and `/usr/bin/php` are switched, the shared tuner runs and nginx reloads |
| 5. Verify | the unit, every pool listener, `php-fpm -t` without load warnings, OPcache in FPM and CLI, and an HTTP probe of every PHP vhost that answered before.  A hard failure rolls back to the previous version |
| 6. Keep one rollback | X.Y is enabled; the previous version is disabled (not masked) and its build and `/etc/php` tree are kept: `--upgrade-php=OLD` switches back, rebuilding only when that build is stale.  Versions older than that are retired |

The report goes to `/var/log/setup-php-upgrade-<timestamp>.md`.  BOLT for
the new version is deferred to the next `--optimize`.  Only PHP (and the
services that depend on its socket) is touched: the OS profile, MariaDB,
Valkey and Elasticsearch are left to `--optimize`.

## Manual follow-ups (never automated)

setup.sh does not rewrite application files and **does not alter application
schemas**: no `ALTER TABLE`, no index creation, no data change on a forum or
CMS database. Schema work is an operator decision taken with the vendor's
upgrade path in mind. Two measured items are worth applying by hand:

- **XFMG gallery count (XenForo + XenForo Media Gallery).** The gallery
  index computes its pagination total with `SELECT COUNT(*) FROM
  xf_mg_media_item WHERE (album_state = 'visible' OR album_state IS NULL)
  AND category_id IN (...) AND media_state IN ('visible')`. Without a
  covering index that is a full table scan on every member view. Measured on
  a live board with about 74 000 media rows: 47.7 ms -> 23.4 ms, MariaDB CPU for
  the page 54.0 -> 30.7 ms, uncached gallery index 62 -> 90 req/s (+45 %),
  p50 130 -> 88 ms. Add it yourself during a maintenance window:

  ```sql
  ALTER TABLE xf_mg_media_item
    ADD INDEX mg_count_cover (media_state, album_state, category_id),
    ALGORITHM=INPLACE, LOCK=NONE;
  ```
- **XenForo media widgets and job runner.** Disabling the Members online /
  Trending / Featured widgets on the forum list and switching *Options >
  Performance > Job run trigger* to server-based (paired with the managed
  `xf:run-jobs` crontab entry) were worth +39 % authenticated throughput in
  the same audit. Both are ACP settings, so setup.sh only reports them.
- **A shop add-on that filters the thread list.** On a board with a
  DragonByte-style shop add-on, the index page ran
  `SELECT thread_id FROM xf_thread LEFT JOIN <shop>_thread_ban ...` (one full
  scan of the thread table, 338 ms) plus
  `SELECT xf_user.* WHERE is_banned = 0 AND user_state = 'valid'`
  (119 ms) - about **1.1 s of MariaDB CPU per member view**, the single
  largest member-facing cost measured.  Fix it in the add-on or its ACP
  widget, or add an index on the add-on's ban table by hand; the optimizer
  will never touch that schema.

## Hardware profile

Inputs: effective CPUs and RAM (cgroup-aware), the storage class behind the
data directory (NVMe / SSD / HDD) and the host class (`dedi`/`vps`).

| Area | Rule |
|---|---|
| PHP-FPM | `pm = static`, `pm.max_children` = logical CPUs x the host's blocking factor (1.0 for a local database on flash, 1.5 for a shared/virtual CPU or a remote database, 2.0 for spinning disks), bounded by the RAM plan; a pool sized by hand is normalised to the same count, so a fresh install and `--optimize` write the same value (a 64-thread board left on 512 static workers is set to 64). `SETUP_PHP_WORKERS_PER_CPU` pins the factor for an install/one run; an explicit `--php children=` wins during that run and is clamped to floor..max(512, 2 x CPUs); `--optimize` ignores both and uses the hardware count. `pm.max_requests = threads x 1024`, `request_terminate_timeout 300s`, slow log at 10 s, `rlimit_files 524288`, systemd `LimitNOFILE=524288`/`UMask=0027`/`KillSignal=SIGQUIT`. `opcache.max_accelerated_files` = PHP files under the vhost roots x 1.5 (16384..128256), written as the OPcache hash-table prime PHP rounds it up to (32531, 65407 or 130987), so the ini only changes when the file count crosses a step; 130987 when no root is found; `memory_limit`, OPcache, JIT buffer and realpath sizes from one RAM profile shared with the dry run |
| MariaDB | see the service section: pool = live data +5% (128 MB minimum, shrunk online when larger), floor `clamp(RAM/16, 256 MB, 4 GB)` only for a fresh install with nothing to measure, io_capacity by disk x host, thread pool, connections from the PHP pool, table caches from connections, Aria page cache `clamp(RAM/128, 16, 256) MB`; the memory plan books the non-pool memory (log buffer + Aria page cache + 32 MB key buffer, plus `thread_pool_size` active queries x (2.5 MB session buffers + `tmp_table_size`/2)) from the room PHP leaves, never by cutting PHP workers; when it does not fit, `tmp_table_size`/`max_heap_table_size` are capped (16 MB steps, 16 MB minimum) and the rest is named in the report and stays in the 20% OS margin |
| Elasticsearch | heap = store/4 (512 MB..25% RAM..31 GB); `node.processors` = effective CPUs; search threads cpus/2 (max 16), write threads cpus/4 (max 8); `xpack.ml.enabled: false` (no machine-learning controller on a search-only node; static, applied by the restart the changed block already causes) |
| Valkey / Redis | maxmemory = live +20% (128 MB minimum, shrunk online when more than 10% larger), floor `clamp(RAM/64, 128 MB, 1 GB)` only on a fresh install with nothing to measure; maxclients from the PHP pool; io-threads 1 (fixed; `io_threads=` was removed in 1.22.5) |
| nginx | `worker_processes` = **2/3 of CPUs** (`worker_cpu_affinity auto` commented out under a cgroup CPU quota, a cpuset smaller than the online CPUs or more than one NUMA node, with the reason in the comment; measured on the 12-thread EPYC: 8 workers 389-390k cached req/s vs 348-352k at `auto`/12), `worker_connections = clamp(cpus x 2048, 8192, 65535)` and `worker_rlimit_nofile = clamp(cpus x 8192, 65536, 524288)` (VPS: 1024 and 4096 per core), **no PHP upstream keepalive cache** (an idle FastCGI connection pins one PHP-FPM worker; see the live-origin.example audit in `tests/stress-site/RESULTS.md`), `open_file_cache max = clamp(RAM_MB x 8, 10000, 200000)` bounded by `rlimit - connections`, FastCGI buffers and cache zones by RAM, cache disk budget by RAM/cache filesystem size (capped at half its free space)/installed services (50% RAM nginx-only, 30% nginx+PHP, 25% full stack; a populated FastCGI, proxy or CDN cache is never shrunk below its live size), `directio 16m` on NVMe/SSD (4m on HDD), Brotli 1 (`SETUP_BROTLI_LEVEL` overrides it) and gzip 4 (3 on 1-2 CPUs) |
| Kernel / PHP | `vm.nr_hugepages = (OPcache MB + JIT MB + 1)/2 + 8` (8..512; 296 pages = 592 MB on 8 GB+) on hosts with 4 GB+ and PHP, and `opcache.huge_code_pages=1` when the pages exist (measured +3.5 % on the XenForo member/thread tiers); the reservation is booked in the memory plan |
| Kernel | `somaxconn`/SYN backlog `cpus x 4096` (VPS x 2048, max 65536), conntrack `RAM_MB x 16` (VPS x 8), `tcp_rmem`/`tcp_wmem` default 85 KB under 4 GB, 128 KB under 16 GB, 256 KB above, `netdev_budget 600/8000 us` on dedicated hosts with 8+ CPUs, `vm.dirty_background_bytes = clamp(RAM/100, 64 MB, 512 MB)` and `vm.dirty_bytes = 4x` (tighter on HDD), `vm.min_free_kbytes` 1% of RAM (16 MB floor under 4 GB, 256 MB cap), `vm.swappiness` 1 on NVMe/SSD (10 on HDD), `kernel.shmmax = min(1 GiB, RAM/4)`, `ip_local_reserved_ports` = 3306, 6379, 9000, 9200, 9300 and the sshd ports (the ephemeral range is 1024-65535), BBR + fq (`SETUP_TCP_CC`, `SETUP_QDISC`; `--optimize` reports a NIC whose live root qdisc is not fq yet, which changes at the next reboot, nothing live is replaced), `tcp_notsent_lowat` 16384, 1M-nofile PAM limits. The base profile's `ip_forward`/`forwarding = 0` lines are dropped on a host that already forwards (bridge, Docker/LXD, WireGuard/Tailscale interfaces) and its IPv6 `autoconf`/`accept_ra = 0` lines on a host whose address or default route comes from router advertisements |
| File descriptors | one plan (1.22.5) sizes every unit's `LimitNOFILE` together with the service's own limit: nginx `worker_connections x 2 + open_file_cache + 64` (at least `worker_rlimit_nofile`), PHP `rlimit_files 524288`, Valkey `maxclients + 32`, MariaDB `open_files_limit` as `mariadbd` computes it from `max_connections` and `table_open_cache` (524288 minimum), Elasticsearch 65535 (its bootstrap check).  Each unit gets its need rounded up to a power of two, never below the 1.22.4 value (nginx, PHP, Valkey 524288; MariaDB, Elasticsearch 1048576) and capped at the live `fs.nr_open` where that is above the floor, so today's sizes write exactly those values.  `fs.file-max` = RAM_MB x 1024 within 1M..10M, raised to the sum of the units present when that is larger (a small all-in-one host or two PHP series); `fs.nr_open` = the same, and at least twice the largest unit limit.  Neither is ever written below the system's own value: when that is already at least the target (stock Ubuntu, where systemd raises `nr_open` to about 1073741816 and `file-max` to LONG_MAX at boot) the key is not written at all; the `--optimize` Verify block lists each unit against its internal limit |
| Host | swap RAM/2 clamped 1..8 GiB (VPS 4); governor on dedicated hardware only (the previous governor is recorded for `--purge`); THP `madvise`; `fstrim.timer` on SSD/NVMe; I/O scheduler and readahead per device class for every whole disk by its rotational flag (NVMe `none`, flash `mq-deadline`/128k, rotational `mq-deadline`/1024k; md/dm arrays on flash get readahead 128k only, since the kernel sizes an array's readahead from its stripe and the filesystem reads through the array, not its members; HDD arrays and loop/zram are left alone; the rules are re-triggered only for non-empty whole disks, so BMC virtual floppies and CD-ROMs are not replayed through other packages' udev rules) |

### Environment variables

Feature choices are persisted in `/etc/default/setup-tuning` and still apply
to a later `--optimize`. Tuning variables are **not** overrides for
`--optimize`: it unsets them for the run and recomputes the profile from the
hardware (with a warning), see
[Profile pins and tuning overrides](#profile-pins-and-tuning-overrides).

The `SETUP_*` names below are environment inputs for the run that applies
them.  `SETUP_XF_JOB_CRON`, `SETUP_CF_SELF_SIGNED`, `SETUP_PHP_JIT_WORDPRESS`,
`SETUP_PHP_PAGE_GZIP`, `SETUP_PHP_OPCACHE_FILE_OVERRIDE`,
`--php ext=` (`PHP_EXT_EXTRA`) and the
XenForo gzip choice are written to
`/etc/default/setup-tuning` and therefore survive a later `--optimize`.  The
remaining ones are one-run inputs: they are not persisted, and a later
install/optimize re-applies the host's recorded state unless the same
variable is passed again.

Feature choices (honoured by `--optimize`):

| Variable | Values | Effect |
|---|---|---|
| `SETUP_XF_JOB_CRON` | `0\|1` | managed XenForo job-runner crontab entry |
| `SETUP_XF_MEMBER_GZIP` | `nginx\|xenforo` | who compresses XenForo pages for visitors with a session (default `nginx`) |
| `SETUP_CF_SELF_SIGNED` | `0\|1` | Cloudflare-proxied vhosts on the self-signed origin certificate and certbot retirement (`--optimize`); persisted as `CF_SELF_SIGNED` |
| `SETUP_SSL_REJECT_UNKNOWN_SNI` | `auto\|0\|1` | catch-all HTTPS server refuses handshakes with an unknown or missing SNI (`ssl_reject_handshake on`, hides the origin host name from IP scanners). `auto` (default) leaves it off while a loaded vhost trusts a reverse proxy outside the Cloudflare ranges (`set_real_ip_from`), since such a proxy may connect without the site name as SNI and every request would answer 502; `1` once every proxy in front sends it (`proxy_ssl_server_name on; proxy_ssl_name $host;`); read from `SSL_REJECT_UNKNOWN_SNI` in `/etc/default/setup-tuning` |
| `SETUP_CPU_MITIGATIONS` | `off` | accepted and changes nothing (`mitigations=off` is the default since 1.22.5); `on` was removed and is refused; a persisted `CPU_MITIGATIONS=on` moves to `off` |
| `SETUP_NODE_MAJOR` | major number | Node.js major installed by `--others nodejs` |
| `SETUP_NODE_ALLOW_MAJOR_UPGRADE` | `1` | allows a one-off Node.js major switch |
| `SETUP_UFW_SSH_LIMIT` | `0\|1` | 1 (default) rate-limits the SSH port with `ufw limit` (6 new connections per 30 s per address); 0 writes a plain `ufw allow` rule for automation hosts (see troubleshooting) |
| `SETUP_PHP_OPCACHE_FILE_OVERRIDE` | `0\|1` | default `1` writes `opcache.enable_file_override = 1`, `0` leaves it out; persisted as `PHP_OPCACHE_FILE_OVERRIDE` |
| `SETUP_WP_DB_SPLIT` | `0` | keeps a WordPress `DB_USER` with global privileges as it is |
| `SETUP_WP_ALLOW_FILE_MODS` | `1` | keeps WordPress plugin installs enabled |
| `SETUP_WP_GUEST_CACHE` | `0` | keeps the WordPress guest-cache include off |
| `SETUP_CHEV_GUEST_CACHE` | `1\|0` | forces the Chevereto guest cache on/off |
| `SETUP_PURGE_MALWARE` | `1` | deletes known webshells instead of quarantining them |
| `SETUP_DOMAIN_OPTIMIZE` | `0` | skips the tuning pass at the end of `--domain` |
| `SETUP_SERVICE_WATCHDOG` | `0\|1` | service watchdog (default on, installed by `--basic`/`--optimize` for the units present): a `zz-setup-watchdog.conf` drop-in gives `nginx.service`, every `phpX.Y-fpm.service`, `mariadb.service` and `elasticsearch.service` `Restart=on-abnormal` when the unit has no `Restart=` of its own (MariaDB's packaged `Restart=on-abort` is kept; crash, OOM kill; not the CPU gate's or `nginx -t`'s clean exit 1), and `setup-service-watchdog.timer` (every 30 s) restarts an enabled nginx/PHP-FPM/Valkey/Redis/MariaDB/Elasticsearch unit that has been `failed` (or never started this boot) for 60 s (`activating`, such as a slow Elasticsearch start, is never down).  The same pass restarts a unit that is `active` but hung: one cheap liveness probe per unit, in parallel, 10 s each (Valkey `PING` on its socket, `mariadb-admin --protocol=socket ping`, curl to Elasticsearch's `/` and nginx's `https://127.0.0.1/`, a FastCGI request for the pool's `ping.path = /setup-fpm-ping`, which `--optimize` adds and nginx cannot reach); any answer counts as alive (LOADING, BUSY, Too many connections, HTTP 401/503, the catch-all's empty reply), only a refused connection or no answer fails, and a failure is not counted while the unit's cgroup is busy (2% of a core or 1 MB/s disk I/O).  3 failed probes in a row (~90 s) restart nginx/PHP-FPM/Valkey, 5 (~150 s) MariaDB/Elasticsearch, never within 600 s of their start.  At most 3 restarts per unit per hour for both, logged as `journalctl -t setup-watchdog` (a probe failure and its recovery once each).  A unit stopped with `systemctl stop` stays down; nothing runs while setup.sh, a build, the migration or a CPU-change rebuild is in progress.  `0` (persisted as `SERVICE_WATCHDOG`) removes it for hosts with their own monitoring; `SETUP_SERVICE_WATCHDOG_HANG=0` (persisted as `SERVICE_WATCHDOG_HANG`) keeps the down restarts but turns the hang restarts off; `--purge` removes it with the last service |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF`, `CONFIG_SOURCE_DIR` | URL, git ref (default `main`), local directory | source of the nginx configuration tree |
| `SETUP_STATE_DIR` | directory | private state directory for tests and image builds |

Builds and migration (one-run inputs):

| Variable | Values | Effect |
|---|---|---|
| `SETUP_PHP_ALLOW_MISSING_EXT` | `1` | accept that a detected application loses an extension the source build cannot provide (install, `--upgrade-php`, migration) |
| `SETUP_PHP_ALLOW_COLLATERAL` | `1` | let the migration's Sury purge remove the other packages the apt simulation named |
| `SETUP_MIGRATE_RETRY` | `1` | retry a migration part that was blocked or rolled back on an unchanged configuration |
| `SETUP_BUILD_MIRROR` | `off` or a URL | turn the setup-build-sources mirror off, or point it at a fork |
| `SETUP_BUILD_JOBS` | number | parallel compile/link jobs (default min(CPUs, (MemAvailable - 1 GB) / 1.2 GB)) |
| `SETUP_BUILD_MAX_FILE_GB` | GB | largest single file a build may write (default 20; enforced with `ulimit -f`), so a runaway log or object file cannot fill the disk |
| `SETUP_NGINX_BUILD_BOLT`, `SETUP_PHP_BUILD_BOLT`, `SETUP_VALKEY_BUILD_BOLT` | `0` | skip that component's BOLT pass |
| `SETUP_MEM_TOTAL_MB` | MB | stands in for the host's RAM in `--dry-run` and the unit tests only |

Tuning overrides (ignored by `--optimize`, which uses the hardware profile):

| Variable | Effect when set |
|---|---|
| `SETUP_TCP_CC`, `SETUP_QDISC` | congestion control and qdisc (profile default BBR + fq) |
| `SETUP_STORAGE_CLASS` | `nvme\|ssd\|hdd` pin when the kernel cannot see the medium |
| `SETUP_PHP_WORKERS_PER_CPU` | PHP-FPM workers-per-CPU factor |
| `SETUP_BROTLI_LEVEL` | dynamic Brotli compression level |
| `SETUP_NGINX_COMPRESSION` | 0 turns the managed compression profile off |
| `SETUP_MARIADB_IO_CAPACITY` | `innodb_io_capacity`/`_max` |
| `SETUP_LIMIT_REQ_EXEMPT` | ignored since 1.21.71 (the generic per-IP limits it exempted from are gone; the login limiter never used it).  A value an older release persisted only tells the TLS catch-all guard that a proxy sits in front |
| `SETUP_PRECOMPRESS_ASSETS` | removed in 1.22.1 (no `gzip_static`/`brotli_static`); ignored with a warning on every path |
| `SETUP_PHP_PAGE_GZIP` | PHP page gzip for the guest cache (profile default 1) |
| `SETUP_PHP_JIT_WORDPRESS` | 0 exempts WordPress roots from the tracing JIT (profile default 1) |

Removed (ignored with a warning): `--source`, `SETUP_PHP_BUILD`,
`SETUP_NGINX_BUILD`, `SETUP_ANGIE_BUILD`, `SETUP_VALKEY_BUILD`,
`SETUP_PHP_FPM_MODULES`, `SETUP_PHP_JIT` (the tracing JIT is always on).

## `--diagnostics`, `--restart-all`, `--purge`

| Command | What it does | Notes |
|---|---|---|
| `--diagnostics` | writes one mode-600 `diagnostics.log` beside `setup.sh`: hardware, network, sysctls, units, nginx/PHP/MariaDB/Valkey/Elasticsearch configuration and runtime statistics, a `builds` section (each `build.info`, versions, CPU match, build timers, the last build logs), the migration state, slow and error logs, ownership, UFW, SSH, cron, package state.  Verification sections: the effective FPM OPcache/JIT per PHP series (that series' CLI run with the FPM `php.ini` and `conf.d`), Valkey `INFO` over each local unix socket, the CPU frequency driver/EPP/boost, NIC queues with their IRQ lines and irqbalance, each service's `LimitNOFILE` next to its own limit (nginx `worker_rlimit_nofile`, PHP `rlimit_files`, Valkey `maxclients`, MariaDB `open_files_limit`, Elasticsearch `max_file_descriptors` from loopback only), and every vhost certificate's `notAfter` | read-only; credentials are redacted.  The `--optimize` report ends with a short **Verify** block (nginx and its TLS library, PHP version and JIT, Valkey version/io-threads/maxmemory policy/RDB save/TCP port, the file-descriptor plan: each service's unit `LimitNOFILE` next to its internal limit and `fs.file-max` against their sum, an irqbalance note on dedicated hosts with 4+ CPUs) and a **Certificates** block that warns about a certificate ending within 21 days, or a self-signed one, on a vhost not proven behind Cloudflare |
| `--restart-all [--dry-run]` | repairs `/var/www` log ownership, stops nginx (Angie in the legacy-Angie state) and every active PHP-FPM, restarts Valkey/Redis, Elasticsearch (waits for HTTP) and MariaDB (waits for `SELECT 1`), then starts PHP-FPM and nginx | only units that were active are touched; uses the same pause/resume and readiness helpers as the `--optimize` tuners; `--dry-run` prints the plan |
| `--purge [TARGET...]` | stops and disables the selected services and removes their managed cron entries; for nginx, PHP and Valkey it also removes the source build | no package, database, certificate, configuration or log is deleted; it keeps going past a file it cannot restore and reports it; there is no domain purge |

Run logs (`setup_<timestamp>-<pid>.log`) and `diagnostics.log` created under
`sudo` are handed to the invoking user (`SUDO_UID`), mode 600.

`--purge` targets (service flags and bare names combine; no target means
everything):

| Target | Effect |
|---|---|
| `all` or no target | every target below |
| `basic` | restores the recorded hostname (only the `127.0.1.1` line of `/etc/hosts`), timezone, DNS, every sysctl key the profile wrote (the base template's keys included), limits, the CPU governor that was active before the install, the `unattended-upgrades` APT file and unit state, and the UFW state. SSH rules are never removed; `/swapfile` stays enabled |
| `nginx` | stops and disables nginx and removes its unit, the build root, the cached sources in `/var/cache/setup-nginx-build`, the `/usr/local/sbin/nginx` link, tmpfiles, build units and the build's `*_temp` directories under `/var/cache/nginx` (cache directories a vhost keeps there stay).  Directives the build had commented out are put back in `/etc/nginx` (`nginx-build.sh restore`), so they are active again in the kept tree.  `/etc/nginx`, the logs and `/var/backups/setup-1.22` stay.  In the legacy-Angie state it stops and disables Angie instead |
| `php [ver=X]` | stops and disables PHP-FPM and removes its unit, build and links (with `--php ver=X`, one version only); the cached sources in `/var/cache/setup-php-build` go with the last PHP version; `/etc/php`, the logs and session data stay |
| `mariadb` | stops and disables MariaDB |
| `valkey` | stops and disables Valkey and removes its unit, build, links, build units and the cached sources in `/var/cache/setup-valkey-build`; `/etc/valkey` and `/var/lib/valkey` stay |
| `elastic` | stops and disables Elasticsearch |
| `others` | disables the `smartmontools` and `sysstat` units |

The shared refresh timer, the CPU-change unit, the build lock, the LLVM
toolchain (and its apt.llvm.org source) go with the last remaining build.  A purged component's packages are dropped from the
apt pin, so the packaged version can be installed again by hand.

## Idempotency

APT steps are no-ops when current; managed blocks (crontab, `50-server.cnf`,
`elasticsearch.yml`, `valkey.conf`, the ini/pool files) are replaced, never
duplicated; a `--basic`-only re-run regenerates the cron entries of installed
services; repositories and embedded keys are verified and refreshed; a build
whose `check` reports it current is not rebuilt; domain creation preserves
existing vhosts and databases; a repeat `--optimize` with unchanged files and
current builds reloads and restarts nothing.  On a migrated host a second
`--optimize` finds nothing to migrate.

## Embedded payloads

`sysctl.conf`, `mysqltuner.pl`, the `mysqlbackup` utility and the
Elastic/NodeSource signing keys are embedded for offline, single-file use
and verified by the tests; the nginx.org signing-key fingerprints are pinned
in `tools/build-common.sh`.  There is no Angie key or Sury keyring any more.
The nginx configuration, Cloudflare IP ranges and the build sources are
downloaded.

## Testing

- `bash tests/test-tuning.sh` (no root): unit tests of the tuning helpers,
  memory plan, config repairs and rollback, the build tools (branding patch
  counts, extension-set detection, unit texts), the migration state machine
  with stubbed apt/systemctl, the ACME rewrite and the 4 GB rule.
  `bash tests/test-dry-run-matrix.sh`: every flag, app type, purge mode and
  representative invalid input through `--dry-run`. CI runs both plus
  `shellcheck` and `tools/check-public-ips.sh`.  1.22.0 on Ubuntu, final
  tree: 2,797 unit checks pass (0 fail, 1 skipped), 290 dry runs,
  ShellCheck clean.
- `tests/stress-site/`: `setup-stress-site.sh` deploys a synthetic site
  (`stress.invalid`) that exercises every tier; `run-stress.sh` drives it
  locally with `wrk`; `run-stress-remote.sh TARGET_IP DOMAIN` drives it (and
  real XenForo/WordPress vhosts, guest and member tiers) from a workstation
  with the static `oha` binary while `collect-metrics.sh` samples the server.
  `bench-one.sh` measures one tier with per-service CPU attribution,
  `jit-sweep.sh` A/Bs OPcache JIT profiles and `fpm-sweep.sh` (with
  `set-fpm.sh`) sweeps PHP-FPM worker counts; both restore the pool when they
  finish.  `deploy-three-apps.sh` installs WordPress, XenForo and Chevereto
  from local archives on `--domain` vhosts, `exercise-apps.sh` walks their
  guest, member, admin and CLI paths, `compat-php.sh` lints every PHP file
  and re-runs the walk with each application in its strict debug mode (the
  applications hide `E_DEPRECATED` themselves), `security-probe.sh` and
  `guest-cache-cookie-test.sh` are the security and cookie suites,
  `loopback-tiers.sh` measures the load tiers on the host with `wrk`, and
  `sweep-php.sh jit|fpm|stock` A/Bs JIT profiles, worker counts and the
  distribution defaults.  Only login, registration and password-reset POSTs
  are limited, so a remote load generator needs no exemption. Results and
  findings: `tests/stress-site/RESULTS.md` (one section per audit cycle) and
  the current cycle report `tests/stress-site/AUDIT-20261125-1.22.0.md`.
- `tests/deploy-audit/`: `host-manifest.sh` and `state-snapshot.sh` capture a
  host or the managed configuration for diffing (install/`--optimize`
  parity), `restore-baseline.sh` returns a disposable test host to a
  pre-install manifest (`compare-manifest.sh` reports the delta).
- `tests/bench-php-matrix/`: the XenForo 2.3.13 PHP 8.1-8.6 series
  benchmark harness (`install-php-series.sh`, `deploy-xf.sh` with `PLAIN=1`,
  `install-addons.sh`, `seed-xf.sh`, `bench-xf-php-series.sh`), the published tier
  reproduction `bench-thread-tiers.sh`, the published reports and their
  result tables.

## Production checklist

- Certificates: the self-signed pairs suit Cloudflare "Full" mode.  For
  direct TLS, use an external ACME client (the nginx build has no ACME
  module).  Behind Cloudflare the real-IP list (`http.d/cloudflare.conf`,
  refreshed daily by `scripts/cloudflare.sh`) is generated automatically, so
  the login limiter keys on the visitor.  HTTP/3 is on by default for every
  vhost created from a template since 1.22.5 (each TLS server includes
  `h5bp/tls/http3.conf`; delete that line to turn it off for one vhost).
  Behind Cloudflare it is idle today (Cloudflare reaches the origin over
  TCP).  `--optimize` adds the same include to existing vhosts (each server
  block that listens on plain 443 with ssl and has no QUIC listen of its
  own), only when the tree passes `nginx -t` before and after; comment the
  line out (`#include h5bp/tls/http3.conf;`) to keep a vhost off: a deleted
  line comes back on the next run.  443/udp is already open, because `ufw
  allow 443` admits TCP and UDP; the catch-all refuses every QUIC handshake
  for an unknown name.
- PHP: one pool and user per tenant with `open_basedir` in a dedicated pool
  (never via `fastcgi_param`); extend `disable_functions` where no app needs
  process execution.
- MariaDB: per-application users without `GRANT OPTION`; `flush_log_at_trx_commit=1`
  for critical data (a later-sorting drop-in, see the MariaDB section; the
  default 2 can lose about 1 s of commits on an OS crash); TLS, UFW source
  rules and per-client accounts for remote access; off-site encrypted
  backups and tested restores; binary logs for point-in-time recovery; read
  replicas at scale.
- Valkey: socket only (`port 0`) by default; RDB snapshots every 5 minutes
  keep sessions across clean restarts (a crash or power loss starts empty).  Size
  `--valkey ram=` to hold sessions plus cache (`allkeys-lru` may evict them
  under pressure; never `volatile-*`, which evicts the TTL-carrying session
  keys first).  Use a separate instance with AOF for queues and locks; ACLs
  per app.
- Elasticsearch: never expose 9200/9300 without X-Pack security and TLS;
  snapshots to an external repository; a dedicated node once traffic grows.
- Host: keys-only SSH, fail2ban or provider protection, central monitoring and
  log shipping, alerting on 5xx/p99/disk/memory; remove `stress.invalid` and
  test data from production.
- Builds: keep 6 GB free on `/var/cache` and 2 GB on `/`, and do not delete
  `/var/cache/setup-*-build`: the CPU-change rebuild uses those sources
  offline.
- Scale in this order: CDN and edge cache, FastCGI microcache, object cache,
  database tuning and replicas, search cluster, multiple web nodes behind a
  load balancer with shared sessions and storage.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| An install stops because a source build failed (the message names the log) | the build log is under `/usr/local/lib/setup-*/logs/`.  Nothing was activated; fix the cause (disk, network, a pinned version in the `*-build.conf` file) and re-run the same command |
| A build refuses to start for lack of space | it needs 6 GB free on the build cache filesystem and 2 GB on `/`.  Free space and re-run |
| nginx, PHP-FPM or Valkey is down after a hardware change or a VM migration | the CPU changed and the service waits for its native rebuild, by design.  `journalctl -u setup-build-cpu -f` shows progress; each service starts when its own rebuild passes.  The `status` command of each build tool and the `builds` section of `--diagnostics` show whether the build matches the CPU |
| "too little traffic, BOLT skipped" | not an error: the server was idle during the 60 s sample.  The next `--optimize` under real traffic applies BOLT |
| A directive is commented out with `# setup-nginx-build-off: ` | its module is not built (for example `sub_filter`, `limit_conn`).  The report lists it; `nginx-build.sh restore` puts the lines back |
| `--php ext=NAME`: "cannot compile this extension" | the name is not in the buildable list (shown in the message).  Extensions that need a library outside the build recipe, such as imagick, are not offered |
| `--php`, `--valkey`, `--mariadb`, `--elastic` or a PHP `--domain` refused for RAM | the host is below the 4 GB class (`MemTotal` under 3500 MB): only nginx runs there |
| `--nginx`, `--domain`, `--php` or `--valkey` refused: "run --optimize first" | the host still serves through Angie, Sury PHP or the valkey-server package; `--optimize` runs the one-time migration |
| `--optimize` says "Web server: Angie (legacy mode ...)" | the nginx part of the migration is blocked or rolled back; read the reason in the report and `/var/log/setup-migrate-1.22.log`, fix it and run `--optimize` again (`SETUP_MIGRATE_RETRY=1` forces a retry on an unchanged configuration) |
| The migration says the Sury purge is deferred | the apt simulation would remove other packages too (named in the report); the Sury packages are held.  Remove or re-home those packages, or accept with `SETUP_PHP_ALLOW_COLLATERAL=1` |
| The terminal disconnected during the migration | it keeps running as `setup-migrate-1.22`.  Run `--optimize` again to follow it, or `tail -F /var/log/setup-migrate-1.22.log` |
| "PHP X.Y is already installed and --php only performs a first installation" | only one version can own the socket: use `--upgrade-php=X.Y`, which carries extensions and custom pools over; `--php ver=X` is a first installation and refuses to replace an existing version |
| A cron job that runs `php` fails right after a CPU change | the CLI is rebuilt with the FPM by the CPU-change chain; it works again when the chain finishes |
| "Installation of system tables failed" (MariaDB) | Ubuntu 26.04 AppArmor profile; the script adds the override, re-run after `--purge --mariadb` if a previous install was interrupted |
| `smartd could not be enabled` | no SMART-capable disk (VMs); a warning only |
| `429` on logins behind Cloudflare/a proxy | the login limiter keys on the direct client address: enable real-IP (`/etc/nginx/scripts/cloudflare.sh`, `cloudflare.conf`); tune `http.d/limit_req.conf` and `h5bp/limit_req/*.conf` |
| `429` on XenForo search or the contact form | since 1.22.5 `POST /search/search` and `POST /misc/contact` share the login limiter (20 a minute per address after a burst of 10); result pages and every GET stay unlimited.  Behind Cloudflare the key is the visitor only when real-IP is on (see above) |
| `524` behind Cloudflare on a long admin job (XenForo rebuild, Chevereto import, WordPress update) | Cloudflare's proxy waits 100 s for the origin's response (every plan below Enterprise), while PHP may run up to `request_terminate_timeout` 300 s, so the job usually finished.  Run long jobs from the CLI or cron (XenForo's `php cmd.php` rebuild and import commands, WP-CLI) or through a DNS-only (grey-cloud) admin host name; the origin timeouts are not changed |
| PHP-FPM slow log full of queued requests | `request_slowlog_timeout` counts from accept; check `listen queue` in `/fpm-status.php`, add workers or cache the endpoint |
| "upstream prematurely closed connection" during a load test | worker recycling at `pm.max_requests` or an FPM reload; set `pm.max_requests = 0` for a benchmark |
| `--domain` says nginx or MariaDB is missing | it only creates the vhost/database; install the stack first or combine the flags |
| SSH suddenly answers "Connection refused" or drops for a minute after several rapid connections | `ufw limit` on the SSH port (6 new connections per 30 s from one address); retrying refreshes the window. Wait ~1-2 minutes, reuse one connection (`ssh -M -S … -o ControlPersist=1h`), or install with `SETUP_UFW_SSH_LIMIT=0` for an automation host. `ufw status numbered` shows the rule |

## Files and state

| Path | Purpose |
|---|---|
| `/run/setup.sh.lock`, `/tmp/setup-optimize.*` | run lock; `--optimize` rollback backups |
| `/var/lib/setup.sh/` | originals for `--purge basic`, UFW/swap state, package-origin markers, and `explicit-options.conf` (moved to `/tmp` by every `--optimize`) |
| `/var/lib/setup.sh/migrate-1.22`, `.report`, `.rc` | migration state (one line per part), its report and its result |
| `/var/log/setup-migrate-1.22.log` | migration log (the transient unit `setup-migrate-1.22` writes it) |
| `/var/backups/setup-1.22/` | migration and distro-nginx backups (0700 root, never deleted by setup.sh) |
| `/etc/default/setup-tuning` | host facts/feature choices kept by `--optimize` (`NODE_MAJOR`, `PHP_EXT_EXTRA`, ...); tuning pins are cleared on each run |
| `/usr/local/lib/setup-nginx/` | nginx build: `sbin/nginx` (+ `nginx.lto`, `nginx.prev`), `build/build.info`, `staging/`, `html/` (unbranded default pages), `logs/`, `nginx-build.sh`, `nginx-build.conf` |
| `/usr/local/lib/setup-php/` | PHP builds: `X.Y/sbin/php-fpm`, `X.Y/bin/php`, `X.Y/build.info`, `X.Y/exts.want`, `logs/`, `php-build.sh`, `php-build.conf` |
| `/usr/local/lib/setup-valkey/` | Valkey build: `bin/`, `lto/`, `build.info`, `prev/`, `logs/`, `valkey-build.sh`, `valkey-build.conf` |
| `/var/cache/setup-nginx-build`, `setup-php-build`, `setup-valkey-build` | downloaded sources (the CPU-change rebuild uses them offline; keep them) |
| `/etc/systemd/system/nginx.service`, `phpX.Y-fpm.service`, `valkey-server.service` | the services' own units |
| `setup-build-refresh.timer`, `setup-build-cpu.service`, `setup-nginx-build.service`, `setup-php-build@X.Y.service`, `setup-valkey-build.service` | build units in `/etc/systemd/system`; `/run/setup-build.lock` serialises them |
| `/etc/tmpfiles.d/setup-nginx.conf`, `setup-php.conf` | nginx temp/log directories; `/run/php` and the session directories |
| `/etc/apt/preferences.d/setup-source-builds` | keeps the packaged nginx and Valkey out of apt (written by `--nginx` and `--valkey`), and on a migrated 1.21 host the replaced packages, PHP included |
| `/etc/nginx/` | nginx tree (`conf.d/<domain>.conf`, `ssl/<domain>/`, `http.d/zz-setup-*.conf` managed maps/zones) |
| `/home/nginx_cache*`, `/home/xf_proxy_cache`, `/home/proxy_cache*` | nginx cache directories |
| `/etc/php/<ver>/fpm/conf.d/zz-setup-optimize.ini`, `custom_dan.ini`, `pool.d/www.conf`, `/etc/php/setup-active` | PHP tuning; the active version |
| `/etc/mysql/mariadb.conf.d/50-server.cnf`, `99-setup-optimize.cnf` | MariaDB base block and hardware profile |
| `/etc/valkey/valkey.conf`, `/run/valkey/valkey.sock` | Valkey |
| `/etc/elasticsearch/elasticsearch.yml`, `jvm.options.d/zz-setup-optimize.options` | Elasticsearch |
| `/etc/systemd/system/<unit>.service.d/limits.conf` | fd/memlock drop-ins for MariaDB, Elasticsearch and an adopted Redis (nginx, PHP-FPM and Valkey carry their limits in their own units) |
| `/etc/sysctl.d/90-setup-network.conf`, `/etc/security/limits.d/99-setup.conf`, `/etc/udev/rules.d/60-setup-io.rules`, `setup-io-tuning.service` | OS profile |
| `/var/www/logs/<service>/` | one log tree for every service (rotated by `/etc/logrotate.d/setup-logs`) |
| `/usr/local/bin/mysqlbkup.sh`, `/etc/mysqlbkup.cnf`, `/root/mysqltuner.pl` | cron helpers and embedded tools |
| `/var/log/setup-optimize-*.md`, `/var/log/setup-php-upgrade-*.md`, `diagnostics.log`, `setup_*.log` | reports and run logs |

Credentials are never stored in the repository; the MariaDB password is written
only to `/etc/mysqlbkup.cnf` on the target host. `--basic` changes hostname,
resolver, sysctls, limits, firewall and timezone: test on a disposable server
first. Release notes: `CHANGELOG.md`.
