# XenForo 2.3.13 — PHP 8.2 → 8.6 Web Stack Benchmark

**Four stacks, five PHP versions, guest and logged-in traffic, on two independent servers.**

## TL;DR

| Question | Answer |
|---|---|
| Biggest performance win | **Angie `fastcgi_cache` guest-page cache**: **88×–180×** more guest requests/s |
| Fastest stack overall | **Stack 3 — Valkey + Angie page cache** (guest-heavy forum) |
| Fastest stack for logged-in users | **Stack 1 — plain Angie + PHP + MariaDB** (no Valkey, no page cache) |
| Does Valkey data caching help a single server? | **No.** It costs **2–14 %** versus plain; Credis and phpredis measured the same |
| Cost of Anubis | **−90…−94 %** on cached guest pages, **−17…−19 %** on dynamic/member pages |
| PHP 8.6 vs 8.2 | **+0…+3 %** at low concurrency; **≤1.5 %** at saturation — no meaningful gain |
| PHP version ranking | **8.6 RC5 > 8.5 > 8.4 ≈ 8.2 > 8.3** (differences are small) |
| PHP 8.6 without `php-redis` | Works with **SV/RedisCache + bundled Credis**; all add-ons active, all tiers HTTP 200 |

---

## Test environment

### Hardware

| | Host A (remote) | Host B (local) |
|---|---|---|
| CPU | AMD EPYC 4245P, **6 cores / 12 threads**, 5.49 GHz max | AMD Ryzen 7 8745HS, **8 cores / 16 threads**, 4.97 GHz max |
| RAM | 30 GiB | 27 GiB |
| Disk | 2× 894 GB Samsung NVMe | 931 GB Crucial NVMe |
| Virtualisation | none detected (`systemd-detect-virt`) | none detected |
| OS | Ubuntu 26.04.1 LTS | Ubuntu 26.04.1 LTS |
| Kernel | 7.0.0-43-generic | 7.0.0-43-generic |

### Software

| Component | Version |
|---|---|
| Angie | 1.12.4 |
| PHP | 8.2.35, 8.3.36, 8.4.27, 8.5.12, **8.6.0RC5** (Sury packages, side by side) |
| MariaDB | 11.8.6 |
| Valkey | 9.0.4 |
| Anubis | 1.28.2 (opt-in, stack 4 only) |
| XenForo | 2.3.13 |
| Add-ons | SV/StandardLib 1.24.11, SV/RedisCache 2.18.12, SV/RedisFloodCheck 2.3.1, SV/RedisViewCounter 2.6.2, Hampel/Seeder 1.0.0b11 |
| Load generator | wrk 4.1.0 (loopback, HTTPS) |

**Redis client:** `php-redis` is **not installed on any PHP version**. SV/RedisCache uses its bundled pure-PHP **Credis** client on 8.2–8.6. A separate control showed phpredis and Credis within 1–2 % of each other on this workload, so the PHP-version comparison is like for like.

**PHP profile:** `pm = static`, 12 workers (Host A) / 16 workers (Host B), `memory_limit=512M`, OPcache 512 MB, interned strings 64 MB, **JIT tracing, 64 MB**, hot thresholds `64/127/16/64`. JIT was confirmed active on every version.

**Rate limiting:** all Angie `limit_req` directives were disabled for the tests.

---

## Dataset

Seeded with the **Hampel Seeder** add-on:

| Content | Count |
|---|---:|
| Users | **20,001** |
| Threads | **10,000** |
| Posts | **100,400** |
| Forum nodes | **47** (categories, forums, sub-forums) |
| Timespan | 2 years |

Member account used for logged-in tests: `meta.johns` (valid, normal registered user).

---

## Method

- Loopback HTTPS against `xf.test.local`, self-signed certificate.
- `wrk -t4 -c100 -d10s`, 2 s warm-up, per tier.
- **Guest cached:** `GET /` with no cookies.
- **Guest bypass:** `GET /` with `Cookie: xf_session=bench-bypass` (bypasses the guest cache without logging in).
- **Member home:** `GET /` with a valid XenForo session cookie.
- **Member thread:** a seeded 100k-post thread with the same session cookie.
- The FastCGI cache was cleared before each PHP version; Valkey DB 1 was flushed when the data cache was toggled.
- The active PHP version was verified with a `PHP_VERSION` probe on every run (the first attempt exposed a stale Anubis connection pool serving the previous PHP version; the final runs force a restart on version changes).
- Low-concurrency efficiency: `wrk -t2 -c8 -d15s`, **3 runs averaged**, plain stack.

> The four stack passes ran sequentially. Small differences between Stack 1 and Stack 2 (a few percent) are within run-order/thermal drift; the page-cache and Anubis effects are far larger than that drift.

---

# Results

## Host A — AMD EPYC 4245P (6C/12T, 30 GiB)

### Stack 1 — Plain: Angie + PHP + MariaDB

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 789 | 787 | 691 | 548 |
| 8.3 | 775 | 772 | 686 | 548 |
| 8.4 | 787 | 785 | 692 | 553 |
| 8.5 | 791 | 787 | 695 | 551 |
| 8.6 | 788 | 781 | 698 | 552 |

### Stack 2 — Valkey data cache, no page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 767 | 765 | 628 | 500 |
| 8.3 | 760 | 758 | 621 | 494 |
| 8.4 | 774 | 779 | 631 | 496 |
| 8.5 | 772 | 774 | 630 | 498 |
| 8.6 | 769 | 767 | 631 | 496 |

### Stack 3 — Valkey + Angie FastCGI page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 138,697 | 762 | 624 | 500 |
| 8.3 | 138,034 | 767 | 629 | 496 |
| 8.4 | 138,598 | 771 | 633 | 494 |
| 8.5 | 137,999 | 773 | 636 | 495 |
| 8.6 | 136,483 | 773 | 630 | 498 |

### Stack 4 — Valkey + Angie page cache + Anubis

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 7,903 | 609 | 523 | 441 |
| 8.3 | 7,871 | 614 | 520 | 439 |
| 8.4 | 7,890 | 620 | 526 | 444 |
| 8.5 | 7,933 | 627 | 525 | 443 |
| 8.6 | 7,892 | 629 | 529 | 447 |

---

## Host B — AMD Ryzen 7 8745HS (8C/16T, 27 GiB)

### Stack 1 — Plain: Angie + PHP + MariaDB

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 728 | 723 | 635 | 506 |
| 8.3 | 709 | 699 | 616 | 495 |
| 8.4 | 710 | 700 | 624 | 499 |
| 8.5 | 701 | 696 | 611 | 489 |
| 8.6 | 702 | 695 | 613 | 490 |

### Stack 2 — Valkey data cache, no page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 685 | 665 | 538 | 440 |
| 8.3 | 657 | 651 | 530 | 430 |
| 8.4 | 658 | 654 | 534 | 432 |
| 8.5 | 663 | 659 | 537 | 434 |
| 8.6 | 650 | 651 | 536 | 432 |

### Stack 3 — Valkey + Angie FastCGI page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 58,896 | 652 | 528 | 432 |
| 8.3 | 58,631 | 650 | 533 | 434 |
| 8.4 | 59,549 | 650 | 538 | 431 |
| 8.5 | 56,574 | 656 | 537 | 432 |
| 8.6 | 57,760 | 660 | 536 | 434 |

### Stack 4 — Valkey + Angie page cache + Anubis

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 6,194 | 531 | 442 | 388 |
| 8.3 | 6,025 | 532 | 438 | 384 |
| 8.4 | 5,996 | 530 | 444 | 386 |
| 8.5 | 5,792 | 519 | 438 | 383 |
| 8.6 | 5,831 | 529 | 444 | 383 |

---

# Stack ranking

Averages across PHP 8.2–8.6.

| Rank (public/guest) | Stack | Guest cached A / B | Guest bypass A / B | Member home A / B |
|---:|---|---:|---:|---:|
| **1** | **Stack 3 — Valkey + Angie page cache** | **137,962 / 58,282** | 769 / 654 | 630 / 534 |
| 2 | Stack 4 — + Anubis | 7,898 / 5,968 | 620 / 528 | 525 / 441 |
| 3 | Stack 1 — Plain | 786 / 710 | 782 / 703 | **692 / 620** |
| 4 | Stack 2 — Valkey only | 768 / 663 | 769 / 656 | 628 / 535 |

**By authenticated/member throughput the order is different:**
**Stack 1 (692/620) > Stack 3 (630/534) ≈ Stack 2 (628/535) > Stack 4 (525/441).**

### All 20 combinations, ranked by cached guest throughput (Host A)

| # | Stack | PHP | Guest cached A / B | Member home A / B |
|---:|---|---:|---:|---:|
| 1 | 3 | 8.2 | 138,697 / 58,896 | 624 / 528 |
| 2 | 3 | 8.4 | 138,598 / 59,549 | 633 / 538 |
| 3 | 3 | 8.3 | 138,034 / 58,631 | 629 / 533 |
| 4 | 3 | 8.5 | 137,999 / 56,574 | 636 / 537 |
| 5 | 3 | 8.6 | 136,483 / 57,760 | 630 / 536 |
| 6 | 4 | 8.5 | 7,933 / 5,792 | 525 / 438 |
| 7 | 4 | 8.2 | 7,903 / 6,194 | 523 / 442 |
| 8 | 4 | 8.6 | 7,892 / 5,831 | 529 / 444 |
| 9 | 4 | 8.4 | 7,890 / 5,996 | 526 / 444 |
| 10 | 4 | 8.3 | 7,871 / 6,025 | 520 / 438 |
| 11 | 1 | 8.5 | 791 / 701 | 695 / 611 |
| 12 | 1 | 8.2 | 789 / 728 | 691 / 635 |
| 13 | 1 | 8.6 | 788 / 702 | 698 / 613 |
| 14 | 1 | 8.4 | 787 / 710 | 692 / 624 |
| 15 | 1 | 8.3 | 775 / 709 | 686 / 616 |
| 16 | 2 | 8.4 | 774 / 658 | 631 / 534 |
| 17 | 2 | 8.5 | 772 / 663 | 630 / 537 |
| 18 | 2 | 8.6 | 769 / 650 | 631 / 536 |
| 19 | 2 | 8.2 | 767 / 685 | 628 / 538 |
| 20 | 2 | 8.3 | 760 / 657 | 621 / 530 |

The Stack 3 order is cache-hit bound and effectively noise; its member column is the PHP-sensitive number. The Stack 1/2 order changes slightly on Host B (8.2 leads there).

### What the numbers mean

- **Page cache is the whole game.** Stack 3 serves guest pages **88× (Host B)** to **180× (Host A)** faster than Valkey-only. It is also **175× / 82×** faster than the plain stack.
- **Valkey alone does not help XenForo on a single host.** Removing the page cache and adding Valkey costs **2–7 %** on guest requests and **9–14 %** on member pages. On a separate host it may help; locally MariaDB is already fast and the cache adds serialization + network hops.
- **Anubis is a bot-filter tax, not a performance feature.** It keeps **8–10×** the plain stack's guest throughput because the page cache is still behind it, but it removes ~90–94 % of the cached-page ceiling and ~17–19 % of dynamic throughput.
- **Logged-in requests always bypass the FastCGI guest cache.** XenForo's guest-cache map is cookie-gated, so the two member rows are the same with page cache on or off; they measure the cache-bypass path.
- **phpredis vs Credis made no material difference** on PHP 8.5: 698/614 req/s with phpredis vs 697/616 with Credis.

---

# PHP version ranking

Low-concurrency (8 clients, 3 runs averaged) isolates PHP/application cost without worker queueing.

| Rank | PHP | Guest bypass A / B | Member home A / B | c=100 dynamic A / B |
|---:|---|---:|---:|---:|
| **1** | **8.6.0RC5** | **589 / 418** | **531 / 374** | 619 / 534 |
| 2 | 8.5.12 | 587 / 418 | 530 / 373 | **620 / 533** |
| 3 | 8.4.27 | 576 / 416 | 522 / 373 | 619 / 535 |
| 4 | 8.2.35 | 583 / 418 | 523 / 370 | 615 / **540** |
| 5 | 8.3.36 | 574 / 410 | 515 / 366 | 612 / 533 |

### Interpretation

- **PHP 8.6 RC5 is fastest per request, but only by 1–3 %.** Versus 8.3 it is +2.7 % guest / +3.1 % member on Host A and +1.9 % / +2.2 % on Host B.
- **PHP 8.3 is consistently the slowest** in the low-concurrency test (~1.5–2.5 % behind).
- **At saturation (100 clients) all versions are within ~1.5 %**, which is inside the run-to-run/thermal variance. Host A's c=100 average favours 8.5; Host B's favours 8.2.
- **XenForo 2.3.13 does not gain a major step from PHP 8.4/8.5/8.6.** If you upgrade, do it for support/security, not for a large throughput jump.
- **PHP 8.6 works without `php-redis`** with the SV add-ons and Credis; all guest/member/admin paths returned HTTP 200 on 8.6 RC5.

---

## Final recommendation

| Use case | Recommended stack |
|---|---|
| Guest-heavy community (typical forum) | **Stack 3** — Angie page cache + Valkey + PHP 8.5 (8.6 when stable) |
| Mostly logged-in / low guest cacheability | **Stack 1** — plain Angie + PHP 8.5/8.6 + MariaDB |
| Bot filtering required | **Stack 4** — accept ~90 % cached-page cost and ~18 % dynamic cost |
| Avoid | Stack 2 (Valkey without page cache): more moving parts, lower throughput |

**Fastest and most performant overall: Stack 3 with PHP 8.6 RC5 / 8.5** for public forum traffic. **Fastest for authenticated traffic: Stack 1 with PHP 8.5/8.6.** The page cache is the only change that produces an order-of-magnitude improvement; PHP major versions are effectively flat for this application.

---

### Caveats

- XenForo 2.3.13, single-server loopback tests, self-signed TLS, `wrk` synthetic load.
- PHP 8.6.0RC5, not a final release.
- All versions used the pure-PHP Credis client; phpredis is available for 8.2–8.5 and measured equal in the control, but a different Redis workload could differ.
- Anubis requests used `User-Agent: setup-bench/1.0` (allowed by policy). A browser first visit would solve one challenge before reaching the cached pages.
- Stack passes were sequential; small Stack 1 vs Stack 2 deltas are within thermal/run-order drift. The page-cache and Anubis deltas are far outside that range.
