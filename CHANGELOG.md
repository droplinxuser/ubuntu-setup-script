# Changelog

Release notes for ubuntu-setup-script. Current behaviour is documented in
README.md; measurements in tests/stress-site/RESULTS.md.  Per-cycle
reports and raw test logs cited by entries up to 1.21.32 were removed from
the tree on 2026-11-19; retrieve them with `git show 84b0db5:<path>`.

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
