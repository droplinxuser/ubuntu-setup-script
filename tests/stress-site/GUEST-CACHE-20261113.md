# Guest cache: no cookie replay (setup.sh 1.20.8, server-configs-nginx 1.6.23)

Host: `audit-host` (16 threads, 27 812 MiB, NVMe, Ubuntu 26.04.1, Angie
1.12.4, PHP 8.5). Applications: XenForo 2.3.13, Chevereto 4.5.9, WordPress
7.1.4. The host was installed with setup.sh 1.20.7 and the previous config
tree, the applications were deployed, and the new tree was then applied with
`--optimize`, the way an existing server receives it.

## Before (1.20.7 / 1.6.22)

Three fresh clients, no cookies, same URL:

| Site | Cache | `Set-Cookie` received |
|---|---|---|
| XenForo `/` | HIT, HIT, HIT | the same `xf_csrf` value three times |
| XenForo `/whats-new/` | MISS, HIT, HIT | the same `xf_csrf` value three times |
| Chevereto `/explore` | HIT, HIT, HIT | the same `PHPSESSID` three times |
| WordPress `/` | cached | none |
| WordPress page whose plugin sets a guest cookie | MISS, MISS, MISS | three different values (never stored) |

## After

`--optimize` reported
`conf.d/chev.test.local.conf: Chevereto guest cache include is h5bp/php_chev_cache.conf (cookie-safe)`,
`angie -t` passed, and a second `--optimize` changed nothing.

`tests/stress-site/guest-cache-cookie-test.sh`: **61 of 61 checks pass**.

| Area | Checked |
|---|---|
| XenForo guests | cached pages (MISS, HIT, HEAD) carry no `Set-Cookie`; HSTS and Referrer-Policy are still sent |
| XenForo no-cache URIs | `/login/`, `/index.php?login/`, `/api/` are never cached; two guests get different cookies |
| XenForo token refresh | the request the stock `XF.KeepAlive` sends (JSON POST to `/login/keep-alive`, no cookie, the cached page's stale token) returns `status: ok`, a fresh token and the guest's own `xf_csrf`; a guest with only `xf_csrf` is still served from the cache |
| XenForo login | cached page -> keep-alive -> `/login/login` succeeds and delivers `xf_user`/`xf_session`; a failed login and logout are answered by PHP with their cookies |
| XenForo members | BYPASS, rendered for the member, never stored (the next guest gets the guest page) |
| Chevereto guests | cached pages carry no `Set-Cookie`; `/`, `/?random` and `?lang=` are not cached; two guests get different sessions |
| Chevereto sessions | a guest that owns a `PHPSESSID` is rendered by PHP, sees its own `auth_token` (different per session, stable within one, never the cached page's) |
| Chevereto login | login, `/settings` and the nested `/dashboard` location work; logged-in pages are never stored |
| WordPress | guest pages cached without cookies; a page that sets a guest cookie is never stored; login and member pages bypass |

Also verified by hand:

- Stale refresh through the split: with a 3 s TTL the sequence was MISS, HIT,
  STALE (background update), HIT, without `Set-Cookie` and without an error
  log entry.
- 40 quick guest requests returned 40 x 200 (the request is rate-limited once,
  in the location that answers it).
- New vhosts from `--domain app=chevereto` and `app=xf` carry the server-level
  cache include and pass `angie -t`.
- Angie and PHP error logs stayed empty.

Not verified in a real browser: the in-app browser would not load the test
host (self-signed certificate; over plain HTTP it blocked every script). The
XenForo token refresh was therefore checked by reading `XF.KeepAlive` in
`js/xf/core.js` and replaying its exact request.

## Throughput (100 connections, 6 s, oha over Wi-Fi)

| Tier | 1.20.7 | 1.20.8 |
|---|---:|---:|
| XenForo guest home (cached) | 4 034 | 4 088 |
| XenForo guest page (cached) | 3 550 | 4 135 |
| XenForo member home | 842 | 959 |
| Chevereto guest /explore (cached) | 3 633 | 3 777 |
| Chevereto guest home (uncached) | 2 306 | 2 264 |
| WordPress guest home (cached) | 3 082 | 2 833 |

All responses 200. The cached tiers are link-bound; the split adds no
measurable cost. (The 1.20.7 XenForo figures used a larger seeded board.)

## Behaviour changes to know about

- A Chevereto visitor that already has a PHP session is no longer served from
  the cache, so the cache now covers cookie-less traffic only (first page
  views from search engines and links, crawlers). The home page was already
  uncached and starts a session, so visitors who enter through it are always
  rendered by PHP afterwards.
- Chevereto guest uploads (off by default). Measured with `guest_uploads = 1`
  and the cache include active: a cookie-less guest uploading from a cached
  page got `Request denied [401]`, also on a retry with the session cookie
  that the failed attempt returned; after reloading the page (now rendered by
  PHP for that session) the upload succeeded, and a guest who entered through
  the home page could upload at once. `setup.sh` therefore keeps the uncached
  include on a site with guest uploads enabled: toggling the setting and
  re-running `--optimize` switched the vhost between `php_chev.conf` and
  `php_chev_cache.conf` in both directions, with `angie -t` passing each
  time. `SETUP_CHEV_GUEST_CACHE=1|0` overrides.
- The functional suite failed one check once, on a run started immediately
  after an `--optimize`; the check was not captured and five later runs,
  two of them straight after an `--optimize`, passed 61 of 61.
- XenForo sets `xf_from_search` and similar first-visit cookies from PHP; on
  a cached guest page they are no longer delivered.
