# Ubuntu Setup Script

One idempotent Bash script that provisions and tunes a web/database stack on
**Ubuntu 26.04 LTS** (installs) and tunes existing 22.04/24.04/26.04 hosts
(`--optimize`): Angie, PHP-FPM, MariaDB, Valkey (or an existing Redis),
Elasticsearch, Node.js and helper tools, plus per-domain vhosts.

- **Single source of truth for Angie:** the configuration tree is downloaded at
  run time from [`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx)
  (`CONFIG_SOURCE_DIR=/path` uses a local checkout). PHP-FPM templates live
  here under `configs/php/`, so run installs from a repository checkout.
- **File safety:** transient files go under `/tmp`; the script never unlinks
  anything on the server. `--purge` stops/disables services and restores
  recorded settings; it removes no package, data or log. Every run writes
  `setup_<timestamp>-<pid>.log` in the directory it was started from.
- **Install/optimize parity:** every tuned value comes from one helper shared
  by the installer and `--optimize`, so a fresh install followed by
  `--optimize` produces identical configuration (verified byte-for-byte on
  the test host; see `tests/stress-site/RESULTS.md`).

| Path | Contents |
|---|---|
| `setup.sh` | Driver: argument parsing, validation and dispatch; sources `lib/*.sh` |
| `lib/` | Implementation modules sourced in dependency order: `common` (logging, run log, temp/apt helpers), `cli`, `validate`, `util` (state, logs, cron), `os`, `web` (Angie/PHP-FPM tuning), `services` (repos, PHP, MariaDB, Valkey, Elasticsearch, domains), `purge`, `runner`, `optimize`, `security` (hardening), `service-optimizers` (per-service tune/verify, shared by `--optimize`/`--upgrade-php`), `diagnostics`, `restart`, `payloads` |
| `configs/system/`, `configs/mariadb/`, `configs/php/` | DNS/sysctl/limits, MariaDB and PHP-FPM templates |
| `tests/test-tuning.sh`, `tests/test-dry-run-matrix.sh` | Unit tests for the tuning helpers; CLI/dry-run matrix (both run in CI) |
| `tests/stress-site/` | Synthetic full-stack test site, local and remote load harness, results |
| `tools/diff_configs.sh` | Compare the canonical configs of both repos with the live `/etc` |
| `tools/fleet-update.sh` | Safe, logged host update: non-interactive APT, snapd guard, fresh setup.sh checkout, `--optimize` dry run then apply, reboot notice |
| `tools/remove-anubis.sh` | One-shot migration for a host that still runs the removed Anubis filter: restores the vhosts, removes the generated Angie files, stops/disables the service (`--purge` deletes it) |
| `SECURITY-PERFORMANCE.md` | What the script hardens, what it leaves to the operator, and the large-site checklist |

## Requirements

- Ubuntu 26.04 LTS or newer for installs; `--optimize`, `--upgrade-php`,
  `--diagnostics` and `--restart-all` also accept 22.04 and 24.04. Bash 4.4+.
  Root.
- Network access to the Ubuntu, Angie, Sury, Elastic and NodeSource
  repositories and to GitHub (or `CONFIG_SOURCE_DIR`).
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
  --angie --php ver=8.5 \
  --mariadb user=demo pass=temp size=auto bind=127.0.0.1 \
  --valkey --elastic host=localhost ram=4g --others all

# Minimal web host, everything auto-detected
sudo bash setup.sh --basic --angie --php

# Application vhost with database, scoped user and a dump import
sudo bash setup.sh --domain forum.example.com app=xf db=xenforodb user=demo pass=temp sql=/root/backup.sql

# Tune an existing host (OS profile + every installed service), or preview it
sudo bash setup.sh --optimize
bash setup.sh --optimize --dry-run

# Replace the installed PHP with a newer version, keeping extensions/config
sudo bash setup.sh --upgrade-php=8.6
bash setup.sh --upgrade-php=8.6 --dry-run
```

## Command reference

| Command | Purpose | Details |
|---|---|---|
| `--basic [server=] [host=] [swap=] [time=]` | OS baseline; required for every install | [`--basic`](#--basic) |
| `--angie` | Angie web server and its configuration tree | [Angie](#angie---angie) |
| `--php [ver=] [children=] [max_requests=]` | PHP-FPM | [PHP](#php---php) |
| `--mariadb user= pass= [size=] [bind=]` | MariaDB | [MariaDB](#mariadb---mariadb) |
| `--valkey [ram=] [policy=] [io_threads=]` | Valkey cache | [Valkey](#valkey---valkey) |
| `--elastic [host=] [ram=]` | Elasticsearch | [Elasticsearch](#elasticsearch---elastic) |
| `--others ITEM... \| all` | helper packages | [Other packages](#other-packages---others) |
| `--domain DOMAIN [app=] [db=] [user=] [pass=] [sql=]` | vhost, certificate and optional database | [Domains](#domains---domain) |
| `--optimize` | tune the OS and every installed service in place. Recorded tuning overrides are always ignored | [`--optimize`](#--optimize) |
| `--upgrade-php=X.Y` | replace the installed PHP version in place | [`--upgrade-php`](#--upgrade-phpxy) |
| `--diagnostics` | write a redacted `diagnostics.log`; read-only | [Maintenance](#--diagnostics---restart-all---purge) |
| `--restart-all` | ordered restart of every active service | [Maintenance](#--diagnostics---restart-all---purge) |
| `--purge [TARGET...]` | stop and disable services, restore recorded settings | [Maintenance](#--diagnostics---restart-all---purge) |
| `--dry-run` (alias `--check`) | validate any command and print the plan as a normal user; nothing is changed | works with every command above |
| `--help`, `--version` | usage text; script version | |

## `--basic`

| Option | Default | Effect |
|---|---|---|
| `server=dedi\|vps` | auto (`systemd-detect-virt`, DMI, cgroups) | `dedi` sets the `performance` CPU governor; this is an install-time hint, `--optimize` re-detects the class from the hardware |
| `host=FQDN` | `<threads>c-<RAM_GB>g-<storage>` (e.g. `8c-32g-1T`) | hostname via `hostnamectl`; a repeat `--basic` without `host=` keeps the current name |
| `swap=SIZE` | add swap only when total swap is 0 or below 50% of RAM, up to 50% of RAM (1-8 GiB, 4 GiB on a VPS) | `/swapfile` of exactly that size (`8G`, `8Gi`, `512M`) |
| `time=REGION/CITY` | `Asia/Manila` | timezone; a repeat `--basic` without `time=` keeps the current zone |
| `mitigations=off\|on` | not touched | `off` adds `mitigations=off` to the kernel command line (managed `/etc/default/grub.d/zz-setup-mitigations.cfg`, sourced after provider drop-ins such as Hetzner's `hetzner.cfg`, the provider's options kept, `update-grub`), effective at the next reboot; the run checks that the generated boot menu really carries it and names any drop-in that overrides it; `on` removes it.  Persisted as `CPU_MITIGATIONS`, so every `--optimize` keeps it (also `--optimize mitigations=off`, or `SETUP_CPU_MITIGATIONS`).  Measured on a Xeon E-2236: guest-cache hits +14-25 %, PHP tiers +5-7 % (1.21.36); +8-50 % cached and +15 % XenForo member/Chevereto uncached (1.21.38).  Further kernel hardening switches (`init_on_alloc=0`, `randomize_kstack_offset=off`) measured inside run-to-run noise on top of it, so they are not offered; `preempt=none` does not exist on the 7.0 kernel (it runs `lazy`).  It removes the kernel's protection between local processes (Spectre/Meltdown/MDS class), so use it on hosts where only you run code: one key-only administrator, no shared hosting, no untrusted local users |

What `--basic` does:

| Step | Detail |
|---|---|
| DNS | drop-in with `8.8.8.8`, `1.1.1.1` and `Domains=~.`, so they are the default route rather than only a fallback |
| Packages | upgrades packages; installs the basic tools, `cron`, `logrotate` and `unattended-upgrades` |
| OS profile | sysctl, PAM limits, governor, THP `madvise`, udev I/O rules (see [Hardware profile](#hardware-profile)) |
| Root crontab | ownership repair of `/var/www` that skips logs and `wp-config.php`; Cloudflare IP refresh; MariaDB backup at 03:03 and monthly `mariadb-check`; `wp-cron.php` every 5 minutes; asset precompression (on by default) |
| Firewall (UFW) | deny in, allow out, `ufw limit` on every effective SSH port, 80/443 open |
| State | originals are recorded under `/var/lib/setup.sh` for `--purge basic` |

### Security pass (every `--basic` and `--optimize`)

| Area | Action |
|---|---|
| WordPress | `wp-config.php` `root:www-data 640`; `DISALLOW_FILE_EDIT`, `DISALLOW_FILE_MODS` (`SETUP_WP_ALLOW_FILE_MODS=1` keeps plugin installs), `DISABLE_WP_CRON` (+ managed cron entry), `WP_DEBUG_DISPLAY=false`, `FORCE_SSL_ADMIN`; placeholder salts replaced; a `DB_USER` with global privileges is moved to `wp_<db>` scoped to its database (`SETUP_WP_DB_SPLIT=0` disables) |
| Malware | known webshells quarantined under `/var/lib/setup-quarantine/` (`SETUP_PURGE_MALWARE=1` deletes); suspicious admins, risky plugins, world-writable files and oversized archives reported |
| APT | every third-party repository pinned to its own `signed-by` keyring |
| Audit | reports SSH password authentication, public 80/443 and a non-loopback Elasticsearch |

SSH hardening, brute-force protection and origin-only firewalling are left to
the operator. The web-server side (dotfile/`wp-config.php`/`xmlrpc.php`
denies, no PHP from upload directories, security headers) comes from
`server-configs-nginx`.  Since server-configs-nginx 1.6.48 each application has one deny
location (`h5bp/location/security_<app>.conf`, a single regex) ahead of an
exact `location = /index.php`, so a guest-cache hit runs 2-4 location
regexes instead of 25-39; `--optimize` moves vhosts rendered from older
templates onto it where their PHP include is at server level, and leaves
(and reports) any other vhost with the full set. Angie access logging is off by default; only
`error_log` is written.

## Services

### Angie (`--angie`)

`--angie`. What it does:

| Step | Detail |
|---|---|
| Packages | `angie` and `angie-module-brotli` |
| Configuration | deploys the `server-configs-nginx` tree with the built-in deployer |
| Tuning | hardware profile and guest caches (the same `angie_apply_profile` as `--optimize`) |
| Service files | systemd `LimitNOFILE` drop-in and `/etc/default/angie` from the repository |
| Cloudflare | generates `http.d/cloudflare.conf` |
| Finish | restarts the service |

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_BROTLI_LEVEL=1..11` | 4 (3 on 1-2 CPU hosts) | dynamic Brotli level; gzip is the fallback.  Measured on a XenForo member thread page (1.21.63, pinned clock): level 1 = 0.8 ms Angie CPU / 23.9 KB, 2 = 1.3 ms / 18.4 KB, 3 = 1.4 ms / 17.9 KB, 4 = 2.1 ms / 17.1 KB; level 1 gave +4-6 % member req/s for 40 % more bytes, levels 2-3 were inside the noise.  A CPU-bound origin whose only client is Cloudflare can take 1.  (zstd, shipped in 1.21.58, was removed in 1.21.59: Cloudflare asks origins for `br, gzip` only; `--optimize` moves its stanzas away and purges `angie-module-zstd`) |
| `SETUP_ANGIE_COMPRESSION=0` | on | turns the managed compression profile off |
| `SETUP_PRECOMPRESS_ASSETS=0` | on (since 1.21.58) | writes `.br`/`.gz` siblings for the static assets of every XenForo/WordPress root and keeps them fresh from cron (a 177 KB script: 22,000 req/s from the sibling vs 2,100 compressed per request).  0 removes the siblings it made.  Install-time only: `--optimize` ignores the tuning override and uses the default (on) |
| `SETUP_XF_JOB_CRON=0` | on | removes the managed crontab entry that runs `cmd.php xf:run-jobs` once a minute as www-data for every XenForo root; persisted as `XF_JOB_CRON` |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF` | `droplinxuser/server-configs-nginx`, `main` | select a fork or branch of the configuration tree |
| `CONFIG_SOURCE_DIR=/path` | unset | use a local checkout instead of downloading |

Notes:

- Guest-cache locations disable per-hit AIO and Brotli (`aio off; brotli off;`).
  The cached body is already compressed (XenForo/WordPress gzip), so re-running
  either filter only costs CPU; static assets keep the global AIO/Brotli path.
  On the CentMinMod/Nginx audit, `aio threads` cost 16 % of cached-page
  throughput; on Angie the scoped change was neutral.
- With the XenForo job entry in place, switch *Options > Performance > Job
  run trigger* to server-based in the admin CP so member page requests stop
  running the queue. Never run the queue as root: the data directories it
  creates return 403 through Angie.
- An upstream name that a deployed vhost still references but the canonical
  tree no longer defines (a repository rename, or an operator-edited `http.d`
  file) is preserved in `http.d/zz-setup-preserved-upstreams.conf` instead of
  making `angie -t` fail with *host not found in upstream*. The include is
  regenerated on each install/`--optimize` and retired once the repository
  defines the name again.
- There is no bot filter in the Angie tier.  Anubis support was removed in
  1.21.62 (Cloudflare or another CDN/WAF belongs in front of the origin).  A
  host that still runs the filter is refused by `setup.sh` until
  `sudo bash tools/remove-anubis.sh` has restored its vhosts to direct TLS.

### PHP (`--php`)

| Option | Default | Effect |
|---|---|---|
| `ver=X.Y` | latest stable release in the Sury repository | PHP version to install |
| `children=auto\|N` | `auto` (shared memory plan and CPU count) | `pm.max_children`; an explicit value wins over every rule below |
| `max_requests=N` | threads x 1024 | recycle a worker after N requests |

Environment options:

| Variable | Default | Effect |
|---|---|---|
| `SETUP_PHP_WORKERS_PER_CPU` | by host class (see the pool table) | pins the workers-per-CPU factor for an install/one run; `--optimize` ignores it |
| `SETUP_PHP_JIT_HOT_LOOP`, `_FUNC`, `_RETURN`, `_SIDE_EXIT` | tuned set 64/127/16/64 on 3+ CPU hosts (loop/func are PHP's defaults, return/side_exit raised from PHP's 8/8); a conservative set on 1-2 CPUs | JIT hotness thresholds |
| `SETUP_PHP_JIT_WORDPRESS=0` | 1 (WordPress uses the JIT) | keeps `opcache.jit = off` for every WordPress document root through a `[PATH=<root>]` section of the managed ini, for a site that misbehaves with the JIT.  Tuning override: ignored by `--optimize` |
| `SETUP_PHP_PAGE_GZIP=0` | 1 | by default the managed ini turns `zlib.output_compression` (level 4) on in a `[PATH=<root>]` section for every WordPress and Chevereto document root whose guest cache key carries the encoding token, so the FastCGI cache stores the gzip page (0.12 ms of Angie CPU per hit instead of about 1 ms to compress each hit); Chevereto roots also get PHP session GC (`session.gc_probability = 1`, divisor 1000) because no timer cleans its session directory; tuning override: ignored by `--optimize` (profile default 1) |
| `SETUP_PHP_SESSION_HARDENING=1` | off | opt-in `session.*` strict settings, `cgi.fix_pathinfo=0`, `display_errors=Off` and a central `error_log`; it broke Joomla/Polr logins on a mixed host.  Persisted as `PHP_SESSION_HARDENING` (kept by `--optimize`; `=0` turns it off) |
| `SETUP_PHP_BUILD=clang` | off (the package's php-fpm) | opt-in php-fpm compiled from upstream sources with only what WordPress, XenForo and Chevereto use (`lean`/`source` are aliases); see [Compiled php-fpm](#compiled-php-fpm-setup_php_buildclang).  Persisted as `PHP_BUILD` (kept by `--optimize`; `=package` goes back) |
| `SETUP_PHP_FPM_MODULES=all` | off: php-fpm loads only what WordPress, XenForo and Chevereto need | keep every installed extension loaded in php-fpm, see [PHP-FPM modules](#php-fpm-modules-only-what-the-applications-need).  Persisted as `PHP_FPM_MODULES` (kept by `--optimize`) |

#### Compiled php-fpm (`SETUP_PHP_BUILD=clang`)

Two choices for the binary the PHP-FPM unit starts.  Switching is one
`SETUP_PHP_BUILD=... ./setup.sh --optimize`:

| `SETUP_PHP_BUILD` | php-fpm | Measured vs the package (1.21.69: XF member thread / home, WP member home, Chevereto uncached home) |
|---|---|---|
| unset or `package` (default) | the Sury package, Sury's shared extensions | baseline: 237 / 415, 139, 1,474 req/s |
| `clang` (`lean`, `source` are aliases) | compiled from upstream sources, lean, static, ThinLTO and BOLT | **+11.0 % / +10.1 %, +7.9 %, +5.9 %** |

Cached pages are the same either way, because Angie serves them.  The build
keeps the package's `php.ini`, pools, unit and `php` CLI (XenForo's `cmd.php`
and cron still run on it).  BOLT needs `perf` for the running kernel
(`linux-tools-$(uname -r)`) and CPU branch records (LBR); a VM without them
keeps the ThinLTO build.

**What it is.**  PHP from php.net, redis and igbinary from PECL, and every
library php-fpm links (OpenSSL, PCRE2, zlib, libxml2, libsodium, GMP, curl,
libjpeg-turbo, libpng, libwebp, libzip), each from its own project at the
version in [`php-build.conf`](php-build.conf), compiled with clang from
apt.llvm.org at `-O3 -march=native -fPIE`, linked statically with ThinLTO
across PHP, its extensions, PCRE2, zlib and libxml2, then rewritten by LLVM
BOLT from a 60 s perf sample of live traffic.  It links only glibc and
libsystemd from Ubuntu.  It contains only the FPM SAPI and the modules
WordPress, XenForo 2.3 and Chevereto 4.5 use between them: ctype curl dom
exif fileinfo filter gd (jpeg, png, webp; GIF and BMP built in) gmp iconv
libxml mbstring mysqli/mysqlnd openssl pdo/pdo_mysql session simplexml sodium
xml xmlreader xmlwriter zip zlib, plus redis/igbinary for the Redis caches,
plus PHP's always-built core.  There is no intl: XenForo ships Symfony's intl
polyfills, WordPress checks `function_exists`, and Chevereto does not use it.
There is no ImageMagick: all three use GD.  No shared extensions are loaded:
before every start and reload the tool mirrors `/etc/php/X.Y/fpm/conf.d` into
`/run/setup-php-build/X.Y` with the `extension=` lines commented out, so
OPcache/JIT and other settings written by `--optimize` apply as usual.
Another PHP application, or an add-on that needs another extension, must use
the package.

**Why one build (1.21.69).**  1.21.68 offered two compiled modes: `clang`
(the package's PHP version and core rebuilt with clang, Sury's extensions)
and `lean` (everything from source).  Before BOLT, the from-source build ran
9 % fewer instructions per XenForo page, yet it was 1-2 % slower.  ICU,
compiled in for intl, made the binary 102 MB and cost 4.5x the data-TLB
misses.  Without ICU the binary is 60 MB, the misses match the package's, and
it is the fastest of the three both before and after BOLT.  `-fPIC` against
`-fPIE` and BOLT sampling with `opcache.huge_code_pages` on or off made no
measurable difference.

**Checks before it serves.**  The build must start without warnings, show
every module above, give every INI directive it shares with the package the
package's value (`php-fpm -i`), link none of the libraries above from Ubuntu,
and pass `php-fpm -t` against the live pool configuration.

* **Versions:** [`php-build.conf`](php-build.conf), beside `setup.sh`, lists
  every component as `latest` (the newest stable release, never an RC or
  beta) or a pinned version, such as `OPENSSL_VERSION=3.6.1` or
  `LLVM_VERSION=23`.  After an edit, `sudo ./setup.sh --optimize` rebuilds
  whatever changed.  `php-fpm-build.sh versions 8.5` shows what `latest`
  resolves to, and `check 8.5` shows what a rebuild would change.  When no
  source answers a version lookup, the build keeps the version it was made
  from.
* **Downloads:** every download has a second source, tried when the first
  times out or fails.  The project's own site comes first and GitHub second:
  PHP (php.net, then the php-src tag snapshot); redis and igbinary (PECL,
  then GitHub); OpenSSL, zlib, libsodium, curl and libzip (their sites, then
  their GitHub releases, the same file under one SHA-256); libxml2
  (download.gnome.org, then GNOME GitLab or GitHub); GMP (ftp.gnu.org, then
  ftpmirror.gnu.org); libpng (SourceForge, then GitHub); libwebp
  (downloads.webmproject.org, then GitHub); PCRE2 and libjpeg-turbo (their
  GitHub releases, then GitHub's tag snapshots, as GitHub is their only
  home); LLVM (apt.llvm.org, then LLVM's GitHub release tarball in
  `/opt/setup-llvm`).  Published SHA-256s are checked (php.net, GitHub
  release digests, GNOME `.sha256sum`, OpenSSL `.sha256`); everything else
  is pinned on first download.  A Git snapshot gets its `configure` script
  generated.
* **Compiler:** clang, lld and BOLT come from apt.llvm.org, never Ubuntu's
  archive.  The signing key is checked by fingerprint, and the source is
  pinned at priority 100 so it never replaces an Ubuntu package.
* **How it runs:** `/usr/local/lib/setup-php/X.Y/php-fpm`, started through
  `/etc/systemd/system/phpX.Y-fpm.service.d/zz-setup-build.conf`.  The
  package binary stays at `/usr/sbin/php-fpmX.Y`.
* **When:** the install (`--php`) builds it.  `--optimize` rebuilds when a
  version or the build recipe changed (a 1.21.68 build is rebuilt once), and
  adds BOLT when at least 300 php-fpm functions show up in the sample (an
  idle site is skipped and retried by the next `--optimize`).  BOLT swaps the
  binary with a graceful reload.  `--upgrade-php` builds the new version.
* **Updates:** `setup-php-fpm-build-refresh.timer` checks upstream daily and
  rebuilds in the background (`setup-php-fpm-build@X.Y`) when php.net, PECL,
  LLVM or a library publish a newer release, so library security fixes
  arrive within a day.  The running build keeps serving until the new one
  has passed every check.  The APT hook
  (`/etc/apt/apt.conf.d/99setup-php-fpm-build`) goes back to the package
  binary at once when the package becomes newer than the build, or when the
  build lost a system library, and then rebuilds.
* **Cost:** a toolchain from apt.llvm.org plus cmake/nasm (about 1 GB), a
  source and library cache in `/var/cache/setup-php-build`, and CPU at nice
  10-19: about 5 minutes when a library changed, 3 when only PHP did.
* **Manual control:** `/usr/local/lib/setup-php/php-fpm-build.sh status`,
  `check X.Y`, `build X.Y`, `rebuild X.Y`, `deactivate X.Y` (back to the
  package binary), `activate X.Y`, `bolt X.Y`.  `--purge php` removes the
  drop-in, the build, the timer, the apt.llvm.org source and any GitHub
  toolchain.

#### PHP-FPM modules: only what the applications need

php-fpm loads only the shared extensions that WordPress, XenForo and
Chevereto need between them: ctype curl dom exif fileinfo gd gmp iconv
igbinary intl json mbstring mysqli mysqlnd opcache pdo pdo_mysql redis
simplexml sodium xml xmlreader xmlwriter zip.  The sources for that list are
setup.sh's per-app requirements, Chevereto's integrity check and WordPress
Site Health.  Sury enables every installed module for every SAPI, so the
install and `--optimize` disable the rest (calendar, ffi, ftp, gettext, phar,
posix, readline, shmop, sockets, sysv*, tokenizer, xsl, imagick) for php-fpm
only, with `phpdismod -s fpm`.  That marks them "disabled by admin", so
package updates keep them off.  The CLI keeps every extension.

* A host that serves another PHP application (any `.php` at a vhost root
  that is none of the three) keeps every extension loaded, and the report
  names the site.
* `SETUP_PHP_FPM_MODULES=all` (persisted as `PHP_FPM_MODULES`) turns the
  policy off.  Both cases re-enable exactly what setup.sh disabled, which is
  recorded in `/etc/php/X.Y/fpm/setup-disabled-modules`.
* Images go through GD: Chevereto picks imagick only when it is loaded, and
  its integrity check accepts GD.  New Chevereto sites no longer get
  `php-imagick`; an installed one is kept for the CLI and carried by
  `--upgrade-php`.

Install behaviour:

| Area | Detail |
|---|---|
| Repository | Sury, with an embedded keyring |
| One version only | both Angie and the pool use `/run/php/php-fpm.sock`, so only one PHP-FPM version can be active |
| First installation | `--php` installs the requested version (or the newest Sury build) on a host without PHP-FPM |
| Existing host | `--php` keeps the installed packages, extensions and extra pools and re-applies only the managed configuration. A different `ver=` is refused, because changing the version needs the extension carry-over and a clean purge |
| Changing version | use `--upgrade-php=8.6`, which preflights the purge (a held package or an application that would be removed stops it while PHP is still serving), then carries the extension set and custom configuration |
| Extensions | the XenForo profile: `fpm cli opcache mysql gd curl xml zip gmp mbstring`.  No `redis`/`igbinary` by default: XenForo runs without them (SV RedisCache falls back to its pure-PHP Credis client) and so does WordPress without an object-cache drop-in.  `--domain` installs what a site cannot run without (Chevereto: `redis`, which pulls `igbinary`; images go through GD, so no `imagick`); `--upgrade-php` carries whatever the old version had.  Add `redis` yourself to keep the XenForo data cache on php-redis (see XenForo below), or `intl`/`bcmath` if an add-on needs them |

**Measured: install source and build flags (1.21.64).**  Four arms on one
host (3 rotated rounds, clock pinned at 3.6 GHz): Sury 8.5.13, Ubuntu
26.04's 8.5.4, and PHP 8.5.13 built from source with only the XenForo
module set at `-O2 -march=x86-64` and at CentminMod's `-O3 -m64
-march=native`.  No arm moved a PHP-bound tier outside its spread
(WordPress member flat; XenForo member home/thread −3.8 % to +1.6 %), and
a CLI probe of C builtins was 1.9 % slower for `-march=native` than Sury
while the JIT-emitted loop code was identical at 0.218 ms for every arm.
With the tracing JIT on, hot PHP code is generated at run time and never
sees the C compiler; the flags only reach interpreter helpers, a small
share of a page.  Sury therefore stays: it is also 9 patch releases ahead
of the Ubuntu archive.  A compiled PHP would put a toolchain and manual
security updates on every
host for no measured gain.  A follow-up with LTO and two-stage PGO
(trained on the real applications) made it 5-10 % slower, and LTO alone
was neutral: with the tracing JIT the hot code is generated at run time,
so compiler optimisations only reach the interpreter.  The last round
(1.21.66, every module from source, igbinary included) found one
repeatable edge, and it is small.  clang `-O3 -march=native` was +3 % on
XenForo member pages and flat on WordPress and Chevereto.  GCC with or
without `-falign-functions=32` was 1-5 % slower, and PHP 8.4 was 3-4 %
slower than 8.5 on every tier, so a downgrade buys nothing.  Re-run the
measurement with `tests/bench-php-matrix/` (`build-php-source.sh`,
`extract-php-debs.sh`, `switch-php-arm.sh`, `bench-php-sources.sh`,
`build-php-max.sh`) when the JIT, the compiler or the workload changes.

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

`php.ini` (`zz-setup-optimize.ini`):

| Setting | Value |
|---|---|
| `memory_limit` | 256-512M (128M under 2 GB of RAM) |
| OPcache | 128-512 MB with interned strings |
| Realpath cache | 4-16 MB |
| MariaDB | socket defaults |
| `opcache.jit` | always `tracing`; there is no mode switch (an old `SETUP_PHP_JIT` or persisted `PHP_JIT` value is ignored with a notice) |
| `opcache.jit_buffer_size` | OPcache/8, 32-128 MB; carved out of the OPcache shared-memory segment once per pool, not per worker |
| `opcache.file_cache` | empty, because scripts restored from the file cache are never JIT-compiled |
| `custom_dan.ini` | refreshed from `configs/php/` while the host timezone is kept |

Measured on the test host (XenForo 2.3.13 + WordPress 7.1.4, PHP 8.5.12, 32
workers, 20 s runs, 100 members): tracing beat JIT off by 5% on XenForo
members (910 vs 864 req/s, p50 69 vs 73 ms); `function` lost 6-8% and had a
554 ms p99; 64 MB and 128 MB buffers were within 0.5%, and 256 MB was slower.

Angie-side repairs made by the PHP step: `fastcgi_param PATH_TRANSLATED` is
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
compressed by Angie, not by XenForo: since server-configs-nginx 1.6.56 the
uncached handler (`h5bp/php_xf_handler.conf`) gives PHP an empty
`Accept-Encoding`, so XenForo's level-9 gzip never runs in a PHP worker and
Angie applies Brotli/gzip level 4 instead.  That rule is in the Angie tree,
so it works from the first request of a new install and reaches existing
hosts with the next `--optimize`.  Measured on the Xeon E-2236 test host at
a pinned clock: XenForo's gzip was 12 % of php-fpm CPU on a member thread
page; moving it gave member home +5 % (473 -> 497 req/s) and member thread
+9 % (261 -> 285), p99 566 -> 503 ms on the thread page.  The `src/config.php` block below is kept as a second guard for
older trees; `XF_MEMBER_GZIP=xenforo` no longer makes XenForo compress
uncached pages.

Compression is split (`XF_MEMBER_GZIP=angie`, the default): every XenForo
`src/config.php` gets a managed block at its end,
`$config['enableGzip'] = !isset($_COOKIE[<prefix>session]);`.  Guests keep
XenForo's own level-9 gzip, which the guest cache stores once, and a hit
costs no compression; visitors with a session get plain HTML that Angie
compresses at level 4 (XenForo's gzip was 15 % of member-page PHP CPU).
Measured: member thread +4 %, guest cache unchanged; turning XenForo's gzip
off for everyone dropped guest-cache hits from 104k to 6.8k req/s (Angie
then compresses every hit).  The block is linted before it is written.  An
earlier one-statement `$config['enableGzip'] = ...;` line (older installs
carry `= false;`) is a duplicate next to it and is commented out with a
`// setup.sh superseded (enableGzip block below): ` prefix;
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
MariaDB on the same host class. Keep the cache when `redis` is in `php -m`,
disable it for Credis, and re-measure on the actual stack.

### MariaDB (`--mariadb`)

| Option | Default | Effect |
|---|---|---|
| `user=U` | required | admin user, created for `localhost`, `127.0.0.1` and `::1` (needed with `skip_name_resolve`) |
| `pass=P` | required | its password; also written to `/etc/mysqlbkup.cnf` (mode 600) |
| `size=auto\|4gb` | `auto` | InnoDB buffer pool: `auto` = live data+index plus 5% (128 MB minimum; capped at 80% of RAM when MariaDB is the only data service, otherwise at half of RAM). A live pool more than one 5% step plus one InnoDB chunk (128 MB, or the live `innodb_buffer_pool_chunk_size` when larger) above the target is shrunk to it online (no restart on MariaDB 10.9+, where the redo log resizes online too; the first 1.21.49 run restarts once where a small pool had capped the redo log buffer), so the pool never holds RAM the data does not use; a live empty database gets 128 MB, and only a fresh install with nothing to measure uses the RAM-proportional floor (`clamp(RAM/16, 256 MB, 4 GB)`). The redo log is 25% of the pool (at least the log buffer, so a shrink stays online). `loose-innodb_buffer_pool_size_max` = 80% of RAM lets a pool grow online after a restart (address space only; ignored by releases without it, and never itself a reason to restart). An explicit size is reserved verbatim |
| `bind=ADDR[,ADDR...]` | `127.0.0.1` | comma-separated IPv4 addresses and/or `::1`; `IPV4` resolves the public address and falls back to the local outbound IPv4 behind NAT. TCP 3306 is never opened in the firewall |

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
| `flush_log_at_trx_commit` | 2 |
| Logs | slow log (1 s, 100 rows, plan+explain) and `log_error` under `/var/www/logs/mariadb/` |

### Valkey (`--valkey`)

| Option | Default | Effect |
|---|---|---|
| `ram=SIZE` | data +20% (128 MB minimum), data = the larger of `used_memory` and its peak since start. A maxmemory more than 10% above that shrinks to it online. An `allkeys-*` cache that fills 83-102% of its maxmemory keeps it (an LRU cache fills any size; `ram=` grows it); `noeviction`/`volatile-*` caches follow their data both ways, except a `volatile-*` cache that has already evicted keys (`evicted_keys` > 0), which is kept like an `allkeys-*` one. A stopped cache, or one started less than a day ago, never shrinks; the floor RAM/64 clamped to 128 MB..1 GB only when no maxmemory is in force and the cache is not measured or started less than a day ago | `maxmemory`; an explicit value is used verbatim |
| `policy=NAME` | `allkeys-lru` | `maxmemory-policy`; use `noeviction` or `volatile-lru` when Valkey stores sessions or jobs that must survive |
| `io_threads=N` | 1 | extra socket I/O threads; 8 threads cost 430% CPU and lowered full-page throughput, so raise it only after `valkey-benchmark` shows the main thread is saturated |

Managed `valkey.conf`:

| Setting | Value |
|---|---|
| Network | loopback bind, `protected-mode` |
| Socket | `unixsocket /run/valkey/valkey.sock`, mode 770, with `www-data` in the `valkey` group |
| Persistence | `save ""`, `appendonly no` (cache only).  `--optimize` keeps `appendonly yes` and a non-loopback `bind` of a Redis/Valkey it did not install |
| `maxclients` | PHP workers x 4 + 2000, minimum 10000 |
| Other | `tcp-backlog`, `hz 10`, lazy-free |

Notes:

- Skipped with a warning when `redis-server` is installed; `--optimize` then
  tunes Redis with the same profile. Valkey wins when both exist.
- Runtime values are applied with `CONFIG SET`; a restart (which empties the
  cache) happens only for startup-only keys.
- With php-redis and this Unix socket, XenForo's data cache measured +7–9 %
  authenticated throughput; without php-redis (the add-on's pure-PHP Credis
  client) it measured slower than local MariaDB. See the XenForo section.

### Elasticsearch (`--elastic`)

| Option | Default | Effect |
|---|---|---|
| `host=NAME` | `localhost` | `network.host`; keep `localhost` unless X-Pack security, TLS and a firewall are in place |
| `ram=4g\|auto` | `auto` | JVM heap: `auto` = index store/4 rounded to 512 MB, between 512 MB and 25% of RAM (31 GB ceiling) |

Installed and configured:

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

Standalone; needs Angie, and MariaDB when `db=` is given. It can be repeated
and combined with an install. Options follow the domain they belong to.

| Option | Default | Effect |
|---|---|---|
| `DOMAIN` | required | the site's host name |
| `app=TYPE` | `basic` | vhost template: `basic`, `xf`, `wordpress`, `flarum`, `pingvin`, `chevereto`, `polr`, `lychee`, `shlink`, `sfs`, `php`, `node` |
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
| `/etc/angie/ssl/<domain>/` | self-signed certificate (replace with ACME) |
| `/etc/angie/conf.d/<domain>.conf` | vhost rendered from the repository template and tested with `angie -t` |

Notes:

- A dump that carries its own `CREATE DATABASE`/`USE` for another schema
  (taken with `--databases`) is refused before anything is loaded.
- Existing vhost files and databases are preserved (an existing tree is not
  re-chowned). Application code is not installed.

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
| `--optimize --dry-run` | print the planned OS and service values only; runs as a normal user |

Tunes the OS and every installed service in place. It never installs, starts
or purges a managed service and never
touches swap, the resolver (DNS) or the firewall (UFW), which stay as
`--basic` or the operator left them; the only package it may add is
`angie-module-brotli`, and
the only one it may remove is certbot, once nothing uses it (see
Cloudflare-proxied sites below). The
drivers run with `set -e`
live, so a failed write inside a tuner aborts the run with its line number
instead of being skipped (before 1.13.0 the `if ! run_optimize` call had
suspended errexit for the whole run). Steps:

1. OS profile (governor, PAM limits, sysctls) and the security pass.
2. Angie: `/etc/angie` is synced from `server-configs-nginx`, the WordPress
   and XenForo guest caches are enabled or repaired (shared `fastcgicache`
   zone, `$nocacheuri` and cookie-bypass maps), the hardware profile is
   applied, `angie -t` runs, and the service is reloaded **once, and only
   when the tree digest changed**; a failed sync or test restores the previous
   tree, its unit drop-in and `/etc/default/angie`. Legacy underscore-named
   `http.d` files are tuned in place. A WordPress vhost without
   `include h5bp/wordpress_cache.conf;` gets the include added before its
   `php_wp.conf` include (the guest cache is on by default); set
   `SETUP_WP_GUEST_CACHE=0` to keep such vhosts uncached, in which case they
   are reported instead. Every application's guest cache reports its result
   in the same `X-Cache-Status` header (`HIT`, `MISS`, `BYPASS`, `EXPIRED`).
   **Cloudflare-proxied sites** (SSL mode "Full") move off certbot to the
   host's self-signed `/etc/angie/ssl/default` pair:
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
   - certbot is then purged when the loaded Angie configuration (`angie -T`)
     and every hook, container mount, symlink and non-comment reference under
     `/etc`, `/opt`, `/srv`, `/usr/local`, `/root`, `/home`, the crontabs
     and the web-root app configs leave it unused (copies of this project, Angie
     config trees outside `/etc/angie` and `*.log` files are not consumers). `/etc/letsencrypt` moves
     to `/var/backups/setup-letsencrypt-*` (0700).
   - A kept certbot whose renewals use the missing nginx plugin is reported
     as a warning.
   - `SETUP_CF_SELF_SIGNED=0` (persisted as `CF_SELF_SIGNED=0`) skips all
     of it.
3. PHP-FPM: every `/etc/php/<ver>/fpm` tree; a live TCP pool used through the
   `local_php` upstream is migrated to the Unix socket (graceful reload, or
   a short explicit restart when SIGUSR2 cannot open the listener).  The pool
   is always `pm = static`, one worker per logical CPU when a local database
   and flash storage share the host, 1.5 on a shared CPU or remote database,
   2.0 on spinning disks (see the hardware table); a pool sized by hand is
   normalised to that rule, and the report names the before/after and the
   resident memory it returns (a 64-thread board left on 512 static workers
   is set to 64).
4. MariaDB, Valkey/Redis and Elasticsearch from the shared 80%-of-RAM plan:
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
   settles it.  A MariaDB restart pauses Angie and PHP
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
5. Audit of WordPress/XenForo configs (persistent `p:` database host, Valkey
   socket) with the exact snippets to apply; application files are never
   edited and **application schemas are never altered** (see "Manual
   follow-ups" below for changes worth making by hand). Legacy cron and
   `/var/www` ownership from releases before 1.8.34 are repaired.
6. Verification of every listener (`ss`, SQL, PING, HTTP) and recent
   error-level journal entries. The Markdown report goes to
   `/var/log/setup-optimize-<timestamp>.md` (`-latest.md` copy).

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

## Profile pins and tuning overrides

`--optimize` always recomputes the whole profile from the current hardware.
It no longer has an opt-in reset flag: every recorded tuning override is
ignored and moved to `/tmp` (never deleted) before the tuners run, and tuning
environment variables are ignored with a warning. Two servers with the same
hardware therefore get the same profile.

What the reset does on every `--optimize`:

| Moved/ignored | Detail |
|---|---|
| `/etc/default/setup-tuning` | rewritten with only host facts/feature choices: `XF_JOB_CRON`, `NODE_MAJOR`, `NODE_ALLOW_MAJOR_UPGRADE`. Old `TCP_CC`, `QDISC`, `STORAGE_CLASS`, compression/JIT/page-cache and rate-limit pins no longer survive |
| `/var/lib/setup.sh/explicit-options.conf` | moved to `/tmp`; recorded `php_children`/`max_requests`, MariaDB/Valkey/ES sizes and the dedi/vps pin are dropped and the shared memory plan recomputes them |
| tuning environment | `SETUP_TCP_CC`, `SETUP_QDISC`, `SETUP_STORAGE_CLASS`, `SETUP_PHP_WORKERS_PER_CPU`, `SETUP_PHP_JIT_HOT_*`, `SETUP_GZIP_LEVEL`, `SETUP_BROTLI_LEVEL`, `SETUP_ANGIE_COMPRESSION`, `SETUP_MARIADB_IO_CAPACITY`, `SETUP_LIMIT_REQ_EXEMPT`, `SETUP_PRECOMPRESS_ASSETS`, `SETUP_PHP_PAGE_GZIP`, `SETUP_PHP_JIT_WORDPRESS` are unset for the run and listed in the report/warning |

Feature choices are not performance overrides and still apply: `NODE_MAJOR`,
the WordPress/Chevereto cache and security toggles, and the `CONFIG_*` source
knobs.

What is still **preserved** (never moved or edited by the reset):

| Preserved | Where |
|---|---|
| extra PHP `.ini` files, extra FPM pools, Angie `custom.d/*.conf` | `/etc/php`, `/etc/angie/custom.d` |
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
APT (confold, lock timeout, `NEEDRESTART_MODE=l`), a snapd guard, a timestamped
backup of the previous checkout, a verified tarball extraction, the dry run and
the real run with separate logs, and a reboot notice. `REF=`, `SKIP_APT=1`, `DRY_RUN_ONLY=1`,
`FORCE_SNAPD_PURGE=1` and `REBOOT=1` are the supported switches.

```bash
scp tools/fleet-update.sh root@web1:/root/
ssh root@web1 'bash /root/fleet-update.sh'
```

## `--upgrade-php=X.Y`

Replaces the installed PHP with another version in place instead of purging
and reinstalling the host.

| Option | Effect |
|---|---|
| `--upgrade-php=X.Y` | target version, newer or older than the installed one (e.g. `8.6`); on a host with no PHP installed it performs a fresh install |
| `--dry-run` | prints the upgrade plan and the extension mapping without changing anything |

It is standalone and cannot be combined with install flags, `--optimize`,
`--purge`, `--diagnostics`, `--restart-all` or `--domain`.

| Step | What happens |
|---|---|
| 1. Snapshot | every installed PHP package with its exact version, each extension and whether `apt-mark` calls it manual, operator-owned `.ini` drop-ins in `conf.d`, extra FPM pools, the PECL list and a copy of `/etc/php` under `/var/lib/setup.sh/php-upgrade-<timestamp>/` |
| 2. Target check | adds/refreshes the Sury repository and requires `phpX.Y-fpm` to be published. A pre-release (for example PHP 8.6.0~rc5) is accepted when named explicitly, with a warning |
| 2b. Application preflight | detects WordPress, XenForo and Chevereto document roots below `/var/www` and in Angie vhosts (including a WordPress object-cache drop-in that mentions Redis and a XenForo `config.php` that selects XenForo's own `Redis` provider; SV RedisCache needs no extension), then checks the target repository for every hard requirement (WordPress/XenForo: mysql, gd, curl, mbstring, xml, zip; Chevereto: those plus redis). An extension no installed PHP-FPM loads is not a loss (the site already runs without it) and is reported as a note; the dry run and the real run read the same module list. If a site would lose one, the run stops **before the purge** with PHP still serving; `SETUP_PHP_ALLOW_MISSING_EXT=1` accepts the loss explicitly. This is what stops `--upgrade-php=8.6` on a Chevereto host while `php8.6-redis` is unpublished |
| 3. Purge | every `php*` package plus `libapache2-mod-php*`, then the dependencies that only PHP kept installed. The dependency set is the before/after `apt-get -s autoremove` delta, so pre-existing unrelated autoremove candidates are never touched |
| 4. Install | `phpX.Y-fpm`/`cli` and the default set, then every old extension mapped to `phpX.Y-<ext>`. An extension the new release does not publish yet is reported and skipped; core PHP still installs. A missing optional extension makes the run exit non-zero (`ATTENTION`) without undoing the upgrade, so automation notices. The skipped names are kept in `/var/lib/setup.sh/php-pending-extensions` and installed by the next `--upgrade-php` whose target publishes them (an 8.5 -> 8.6 RC -> 8.5 round trip keeps imagick) |
| 5. Migrate | operator `.ini` files and extra pools are copied with the version path rewritten, validated with `php-fpm -t` (rejected files are moved out of the live tree and the run reports ATTENTION), and FPM is reloaded so the workers actually load them. The PHP `date.timezone` from the old tree is preserved |
| 6. Tune | the same shared tuner as install/`--optimize` writes the pool (`pm=static`, hardware worker count, backlog), `zz-setup-optimize.ini` (memory/realpath/OPcache/tracing JIT), systemd limits and log paths; the Angie tuner then repoints a TCP `local_php` upstream/`fastcgi_pass` at the new Unix socket (a distribution-built host would otherwise be reloaded against a dead `127.0.0.1:9000`); the systemd drop-in of a PHP-FPM version that is no longer installed is removed |
| 7. Verify/report | CLI version, FPM unit, the primary and every extra pool socket, extension packages, that OPcache actually loads, and that Angie has no leftover `...:9000` handler while the pool is on a socket; a Markdown report with the rollback commands is written to `/var/log/setup-php-upgrade-<timestamp>.md`. If the tuned FPM does not start, the old version is rolled back.  A run interrupted between the purge and a serving target (Ctrl-C, `kill`, `set -e`) rolls back from its exit trap too, and a dropped SSH session (HUP) is ignored for that window |

The managed files produced by an upgrade are byte-identical to a
`--basic ... --php ver=X.Y` install (verified on the audit host: pool,
`zz-setup-optimize.ini`, `custom_dan.ini` and the systemd drop-in), and a
following `--optimize` changes nothing.

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
| MariaDB | see the service section: pool = live data +5% (128 MB minimum, shrunk online when larger), floor `clamp(RAM/16, 256 MB, 4 GB)` only for a fresh install with nothing to measure, io_capacity by disk x host, thread pool, connections from the PHP pool, table caches from connections, Aria page cache `clamp(RAM/128, 16, 256) MB` |
| Elasticsearch | heap = store/4 (512 MB..25% RAM..31 GB); `node.processors` = effective CPUs; search threads cpus/2 (max 16), write threads cpus/4 (max 8) |
| Valkey / Redis | maxmemory = live +20% (128 MB minimum, shrunk online when more than 10% larger), floor `clamp(RAM/64, 128 MB, 1 GB)` only on a fresh install with nothing to measure; maxclients from the PHP pool; io_threads 1..8 (a larger `io_threads=` is clamped with a warning) |
| Angie | `worker_processes` = **2/3 of CPUs** (`worker_cpu_affinity auto` commented out under a cgroup CPU quota; measured on the 12-thread EPYC: 8 workers 389-390k cached req/s vs 348-352k at `auto`/12), `worker_connections = clamp(cpus x 2048, 8192, 65535)` and `worker_rlimit_nofile = clamp(cpus x 8192, 65536, 524288)` (VPS: 1024 and 4096 per core), **no PHP upstream keepalive cache** (an idle FastCGI connection pins one PHP-FPM worker; see the live-origin.example audit in `tests/stress-site/RESULTS.md`), `open_file_cache max = clamp(RAM_MB x 8, 10000, 200000)` bounded by `rlimit - connections`, FastCGI buffers and cache zones by RAM, cache disk budget by RAM/cache filesystem size (capped at half its free space)/installed services (50% RAM Angie-only, 30% Angie+PHP, 25% full stack; a populated FastCGI, proxy or CDN cache is never shrunk below its live size), `directio 16m` on NVMe/SSD (4m on HDD), Brotli and gzip 4 (3 on 1-2 CPUs; `SETUP_BROTLI_LEVEL`, `SETUP_GZIP_LEVEL`) |
| Kernel / PHP | `vm.nr_hugepages = (OPcache MB + JIT MB + 1)/2 + 8` (8..512; 296 pages = 592 MB on 8 GB+) on hosts with 4 GB+ and PHP, and `opcache.huge_code_pages=1` when the pages exist (measured +3.5 % on the XenForo member/thread tiers); the reservation is booked in the memory plan |
| Kernel | `somaxconn`/SYN backlog `cpus x 4096` (VPS x 2048, max 65536), conntrack `RAM_MB x 16` (VPS x 8), `tcp_rmem`/`tcp_wmem` default 85 KB under 4 GB, 128 KB under 16 GB, 256 KB above, `netdev_budget 600/8000 us` on dedicated hosts with 8+ CPUs, `vm.dirty_background_bytes = clamp(RAM/100, 64 MB, 512 MB)` and `vm.dirty_bytes = 4x` (tighter on HDD), `vm.min_free_kbytes` 1% of RAM (16 MB floor under 4 GB, 256 MB cap), `vm.swappiness` 1 on NVMe/SSD (10 on HDD), `kernel.shmmax = min(1 GiB, RAM/4)`, `ip_local_reserved_ports` = 3306, 6379, 9200, 9300 and the sshd ports (the ephemeral range is 1024-65535), BBR + fq (`SETUP_TCP_CC`, `SETUP_QDISC`), 1M-nofile PAM limits. The base profile's `ip_forward`/`forwarding = 0` lines are dropped on a host that already forwards (bridge, Docker/LXD, WireGuard/Tailscale interfaces) and its IPv6 `autoconf`/`accept_ra = 0` lines on a host whose address or default route comes from router advertisements |
| Host | swap RAM/2 clamped 1..8 GiB (VPS 4); governor on dedicated hardware only (the previous governor is recorded for `--purge`); THP `madvise`; `fstrim.timer` on SSD/NVMe; I/O scheduler and readahead per device class for every whole disk by its rotational flag (NVMe `none`, flash `mq-deadline`/128k, rotational `mq-deadline`/1024k; md/dm arrays on flash get readahead 128k only, since the kernel sizes an array's readahead from its stripe and the filesystem reads through the array, not its members; HDD arrays and loop/zram are left alone; the rules are re-triggered only for non-empty whole disks, so BMC virtual floppies and CD-ROMs are not replayed through other packages' udev rules) |

### Environment overrides

Feature choices are persisted in `/etc/default/setup-tuning` and still apply
to a later `--optimize`. Tuning variables are **not** overrides for
`--optimize`: it unsets them for the run and recomputes the profile from the
hardware (with a warning), see
[Profile pins and tuning overrides](#profile-pins-and-tuning-overrides).

Feature choices (honoured by `--optimize`):

The `SETUP_*` names in this table are environment inputs for the run that
applies them.  `SETUP_XF_JOB_CRON`, `SETUP_CF_SELF_SIGNED`,
`SETUP_PHP_SESSION_HARDENING`, `SETUP_PHP_BUILD`, `SETUP_PHP_JIT_WORDPRESS`,
`SETUP_PHP_PAGE_GZIP`, `SETUP_PRECOMPRESS_ASSETS`, `SETUP_LIMIT_REQ_EXEMPT` and the XenForo gzip
choice are written to `/etc/default/setup-tuning` and therefore survive a
later `--optimize`.  The remaining ones are one-run inputs: they are not
persisted, and a later install/optimize re-applies the host's recorded state
unless the same variable is passed again.
| Variable | Values | Effect |
|---|---|---|
| `SETUP_XF_JOB_CRON` | `0\|1` | managed XenForo job-runner crontab entry |
| `SETUP_CF_SELF_SIGNED` | `0\|1` | Cloudflare-proxied vhosts on the self-signed origin certificate and certbot retirement (`--optimize`); persisted as `CF_SELF_SIGNED` |
| `SETUP_SSL_REJECT_UNKNOWN_SNI` | `auto\|0\|1` | catch-all HTTPS server refuses handshakes with an unknown or missing SNI (`ssl_reject_handshake on`, hides the origin host name from IP scanners). `auto` (default) leaves it off while a loaded vhost trusts a reverse proxy outside the Cloudflare ranges (`set_real_ip_from`), since such a proxy may connect without the site name as SNI and every request would answer 502; `1` once every proxy in front sends it (`proxy_ssl_server_name on; proxy_ssl_name $host;`); read from `SSL_REJECT_UNKNOWN_SNI` in `/etc/default/setup-tuning` |
| `SETUP_NODE_MAJOR` | major number | Node.js major installed by `--others nodejs` |
| `SETUP_NODE_ALLOW_MAJOR_UPGRADE` | `1` | allows a one-off Node.js major switch |
| `SETUP_UFW_SSH_LIMIT` | `0\|1` | 1 (default) rate-limits the SSH port with `ufw limit` (6 new connections per 30 s per address); 0 writes a plain `ufw allow` rule for automation hosts (see troubleshooting) |
| `SETUP_PHP_SESSION_HARDENING` | `1` | opt-in session/cgi hardening |
| `SETUP_WP_DB_SPLIT` | `0` | keeps a WordPress `DB_USER` with global privileges as it is |
| `SETUP_WP_ALLOW_FILE_MODS` | `1` | keeps WordPress plugin installs enabled |
| `SETUP_WP_GUEST_CACHE` | `0` | keeps the WordPress guest-cache include off |
| `SETUP_CHEV_GUEST_CACHE` | `1\|0` | forces the Chevereto guest cache on/off |
| `SETUP_PURGE_MALWARE` | `1` | deletes known webshells instead of quarantining them |
| `SETUP_DOMAIN_OPTIMIZE` | `0` | skips the tuning pass at the end of `--domain` |
| `CONFIG_REPO_URL`, `CONFIG_REPO_REF`, `CONFIG_SOURCE_DIR` | URL, git ref, local directory | source of the Angie configuration tree |
| `SETUP_STATE_DIR` | directory | private state directory for tests and image builds |

Tuning overrides (ignored by `--optimize`, which uses the hardware profile):

| Variable | Effect when set |
|---|---|
| `SETUP_TCP_CC`, `SETUP_QDISC` | congestion control and qdisc (profile default BBR + fq) |
| `SETUP_STORAGE_CLASS` | `nvme\|ssd\|hdd` pin when the kernel cannot see the medium |
| `SETUP_PHP_WORKERS_PER_CPU` | PHP-FPM workers-per-CPU factor |
| `SETUP_PHP_JIT_HOT_LOOP`, `_FUNC`, `_RETURN`, `_SIDE_EXIT` | JIT hotness thresholds |
| `SETUP_GZIP_LEVEL`, `SETUP_BROTLI_LEVEL` | dynamic compression levels |
| `SETUP_ANGIE_COMPRESSION` | 0 turns the managed compression profile off |
| `SETUP_MARIADB_IO_CAPACITY` | `innodb_io_capacity`/`_max` |
| `SETUP_LIMIT_REQ_EXEMPT` | rate-limit exemptions for a load generator or monitor |
| `SETUP_PRECOMPRESS_ASSETS` | static-asset precompression (profile default 1) |
| `SETUP_PHP_PAGE_GZIP` | PHP page gzip for the guest cache (profile default 1) |
| `SETUP_PHP_JIT_WORDPRESS` | 0 exempts WordPress roots from the tracing JIT (profile default 1) |

## `--diagnostics`, `--restart-all`, `--purge`

| Command | What it does | Notes |
|---|---|---|
| `--diagnostics` | writes one mode-600 `diagnostics.log` beside `setup.sh`: hardware, network, sysctls, units, Angie/PHP/MariaDB/Valkey/Elasticsearch configuration and runtime statistics, slow and error logs, ownership, UFW, SSH, cron, package state | read-only; credentials are redacted |
| `--restart-all [--dry-run]` | repairs `/var/www` log ownership, stops Angie and every active PHP-FPM, restarts Valkey/Redis, Elasticsearch (waits for HTTP) and MariaDB (waits for `SELECT 1`), then starts PHP-FPM and Angie | only units that were active are touched; uses the same pause/resume and readiness helpers as the `--optimize` tuners; `--dry-run` prints the plan |
| `--purge [TARGET...]` | stops and disables the selected services and removes their managed cron entries | nothing is uninstalled or deleted; it keeps going past a file it cannot restore and reports it; there is no domain purge |

Run logs (`setup_<timestamp>-<pid>.log`) and `diagnostics.log` created under
`sudo` are handed to the invoking user (`SUDO_UID`), mode 600.

`--purge` targets (service flags and bare names combine; no target means
everything):

| Target | Effect |
|---|---|
| `all` or no target | every target below |
| `basic` | restores the recorded hostname (only the `127.0.1.1` line of `/etc/hosts`), timezone, DNS, every sysctl key the profile wrote (the base template's keys included), limits, the CPU governor that was active before the install, the `unattended-upgrades` APT file and unit state, and the UFW state. SSH rules are never removed; `/swapfile` stays enabled |
| `angie` | stops and disables Angie |
| `php [ver=X]` | stops and disables PHP-FPM; with `--php ver=X`, one version only, and `phpsessionclean.timer` is kept while another version is enabled |
| `mariadb` | stops and disables MariaDB |
| `valkey` | stops and disables Valkey |
| `elastic` | stops and disables Elasticsearch |
| `others` | disables the `smartmontools` and `sysstat` units |

## Idempotency

APT steps are no-ops when current; managed blocks (crontab, `50-server.cnf`,
`elasticsearch.yml`, `valkey.conf`, the ini/pool files) are replaced, never
duplicated; a `--basic`-only re-run regenerates the cron entries of installed
services; repositories and embedded keys are verified and refreshed; domain
creation preserves existing vhosts and databases; a repeat `--optimize` with
unchanged files reloads and restarts nothing.

## Embedded payloads

`dns_servers.conf`, `sysctl.conf`, `limits.conf`, `mysqltuner.pl` 2.9.3, the
`mysqlbackup` utility, the Angie/Elastic/NodeSource signing keys and the Sury
keyring package are embedded for offline, single-file use and verified by the
tests. Angie configuration and Cloudflare IP ranges are downloaded.

## Testing

- `bash tests/test-tuning.sh` (no root): unit tests of the tuning helpers,
  memory plan, config repairs and rollback. `bash tests/test-dry-run-matrix.sh`:
  every flag, app type, purge mode and representative invalid input through
  `--dry-run`. CI runs both plus `shellcheck`.
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
  applications hide `E_DEPRECATED` themselves), `loopback-tiers.sh` measures
  the load tiers on the host with `wrk`, and `sweep-php.sh jit|fpm|stock`
  A/Bs JIT profiles, worker counts and the distribution defaults.  Run the install or `--optimize` with
  `SETUP_LIMIT_REQ_EXEMPT=<generator IP>` first, or every remote PHP request
  is answered `429`. Results and findings: `tests/stress-site/RESULTS.md` (one
  section per audit cycle) and the current cycle report
  `tests/stress-site/AUDIT-20261120-1.21.38.md`.
- `tests/deploy-audit/`: `host-manifest.sh` and `state-snapshot.sh` capture a
  host or the managed configuration for diffing (install/`--optimize`
  parity), `restore-baseline.sh` returns a disposable test host to a
  pre-install manifest (`compare-manifest.sh` reports the delta).
- `tests/bench-php-matrix/`: the XenForo 2.3.13 four-stack / PHP 8.2-8.6
  benchmark harness (`install-php-versions.sh`, `deploy-xf.sh`,
  `install-addons.sh`, `seed-xf.sh`, `bench-combo.sh`), the published tier
  reproduction `bench-thread-tiers.sh`, the published reports and their
  result tables.

## Production checklist

- Replace the self-signed certificates with ACME (Angie has `http_acme`);
  behind Cloudflare, enable the real-IP config first or the per-IP limiter
  throttles everyone; consider HTTP/3 (`listen 443 quic`, `ufw allow 443/udp`).
- PHP: one pool and user per tenant with `open_basedir` in a dedicated pool
  (never via `fastcgi_param`); extend `disable_functions` where no app needs
  process execution; `opcache.validate_timestamps=0` with a reload on deploy.
- MariaDB: per-application users without `GRANT OPTION`; `flush_log_at_trx_commit=1`
  for critical data; TLS, UFW source rules and per-client accounts for remote
  access; off-site encrypted backups and tested restores; binary logs for
  point-in-time recovery; read replicas at scale.
- Valkey: `save ""` makes it a cache; use AOF and `noeviction`/`volatile-lru`
  (or a separate instance) for sessions, queues and locks; ACLs per app.
- Elasticsearch: never expose 9200/9300 without X-Pack security and TLS;
  snapshots to an external repository; a dedicated node once traffic grows.
- Host: keys-only SSH, fail2ban or provider protection, central monitoring and
  log shipping, alerting on 5xx/p99/disk/memory; remove `stress.invalid` and
  test data from production.
- Scale in this order: CDN and edge cache, FastCGI microcache, object cache,
  database tuning and replicas, search cluster, multiple web nodes behind a
  load balancer with shared sessions and storage.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Another PHP-FPM version is active" | only one version can own the socket: use `--upgrade-php=X.Y`, which carries extensions and custom pools over; `--php ver=X` is a first installation and refuses to replace an existing version |
| "Installation of system tables failed" (MariaDB) | Ubuntu 26.04 AppArmor profile; the script adds the override, re-run after `--purge --mariadb` if a previous install was interrupted |
| `smartd could not be enabled` | no SMART-capable disk (VMs); a warning only |
| `429` behind Cloudflare/a proxy | the limiter keys on the direct client address: enable real-IP (`/etc/angie/scripts/cloudflare.sh`, `cloudflare.conf`); tune `http.d/limit_req.conf` and `h5bp/limit_req/*.conf` |
| PHP-FPM slow log full of queued requests | `request_slowlog_timeout` counts from accept; check `listen queue` in `/fpm-status.php`, add workers or cache the endpoint |
| "upstream prematurely closed connection" during a load test | worker recycling at `pm.max_requests` or an FPM reload; set `pm.max_requests = 0` for a benchmark |
| `--domain` says Angie or MariaDB is missing | it only creates the vhost/database; install the stack first or combine the flags |
| SSH suddenly answers "Connection refused" or drops for a minute after several rapid connections | `ufw limit` on the SSH port (6 new connections per 30 s from one address); retrying refreshes the window. Wait ~1-2 minutes, reuse one connection (`ssh -M -S … -o ControlPersist=1h`), or install with `SETUP_UFW_SSH_LIMIT=0` for an automation host. `ufw status numbered` shows the rule |

## Files and state

| Path | Purpose |
|---|---|
| `/run/setup.sh.lock`, `/tmp/setup-optimize.*` | run lock; `--optimize` rollback backups |
| `/var/lib/setup.sh/` | originals for `--purge basic`, UFW/swap state, package-origin markers, and `explicit-options.conf` (moved to `/tmp` by every `--optimize`) |
| `/etc/default/setup-tuning` | host facts/feature choices kept by `--optimize` (`NODE_MAJOR`, ...); tuning pins are cleared on each run |
| `/etc/angie/` | Angie tree (`conf.d/<domain>.conf`, `ssl/<domain>/`, `http.d/zz-setup-*.conf` managed maps/zones) |
| `/home/nginx_cache*`, `/home/xf_proxy_cache`, `/home/proxy_cache*` | Angie cache directories |
| `/etc/php/<ver>/fpm/conf.d/zz-setup-optimize.ini`, `custom_dan.ini`, `pool.d/www.conf` | PHP tuning |
| `/etc/mysql/mariadb.conf.d/50-server.cnf`, `99-setup-optimize.cnf` | MariaDB base block and hardware profile |
| `/etc/valkey/valkey.conf`, `/run/valkey/valkey.sock` | Valkey |
| `/etc/elasticsearch/elasticsearch.yml`, `jvm.options.d/zz-setup-optimize.options` | Elasticsearch |
| `/etc/systemd/system/<unit>.service.d/limits.conf` | fd/memlock drop-ins for Angie, PHP-FPM, MariaDB, Valkey, Elasticsearch |
| `/etc/sysctl.d/90-setup-network.conf`, `/etc/security/limits.d/99-setup.conf`, `/etc/udev/rules.d/60-setup-io.rules`, `setup-io-tuning.service` | OS profile |
| `/var/www/logs/<service>/` | one log tree for every service (rotated by `/etc/logrotate.d/setup-logs`) |
| `/usr/local/bin/setup-precompress.sh`, `/usr/local/bin/mysqlbkup.sh`, `/etc/mysqlbkup.cnf`, `/root/mysqltuner.pl` | cron helpers and embedded tools |
| `/var/log/setup-optimize-*.md`, `diagnostics.log`, `setup_*.log` | reports and run logs |

Credentials are never stored in the repository; the MariaDB password is written
only to `/etc/mysqlbkup.cnf` on the target host. `--basic` changes hostname,
resolver, sysctls, limits, firewall and timezone: test on a disposable server
first. Release notes: `CHANGELOG.md`.
