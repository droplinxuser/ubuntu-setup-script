# AlmaLinux 10 + CentMinMod vs Ubuntu 26.04 + Angie — XenForo 2.3.13

**Same 12-thread EPYC host, same XenForo dataset, PHP 8.2–8.5. CentMinMod left completely untuned.**

## TL;DR

| Metric (PHP 8.2–8.5 average) | CentMinMod | Ubuntu + Angie | Delta |
|---|---:|---:|---:|
| Guest cached page | **157,957** | 138,332 | **+14.2 %** |
| Guest cache bypass | 596 | **783** | −23.9 % |
| Member home | 530 | **691** | −23.3 % |
| Member thread | **705** | 550 | **+28.2 %** |
| Dynamic average | 605 | 616 | −1.8 % |

**CentMinMod wins cached guest throughput. Ubuntu wins guest-bypass and member-home. Member-thread flips to CentMinMod.** Overall, for a guest-heavy forum, CentMinMod Stack 3 is the fastest result in this comparison.

## Environment

| | AlmaLinux 10.2 + CentMinMod | Ubuntu 26.04 + Angie |
|---|---|---|
| CPU / RAM | AMD EPYC 4245P, 6C/12T, 30 GiB | Same host |
| Disk / OS | 2× 894 GB NVMe, AlmaLinux 10.2, kernel 6.12 | Ubuntu 26.04.1, kernel 7.0 |
| Web server | **Nginx 1.31.8**, 6 workers, 300k connections | Angie 1.12.4, 12 workers, 32k connections |
| PHP | **8.2.35, 8.3.36, 8.4.27, 8.5.12** | 8.2.35–8.5.12 (plus 8.6 RC5) |
| PHP-FPM | **ondemand, 30 children**, TCP 127.0.0.1:9000 | static, 12 workers, Unix socket |
| OPcache | On, **JIT disabled** | 512 MB, **JIT tracing 64 MB** |
| Database | **MariaDB 10.11.19**, 8 GB pool, 600 conns | MariaDB 11.8.6, 1.7 GB pool, 200 conns |
| Cache | **Redis 8.6.8** + phpredis | Valkey 9.0.4 + Credis |
| XenForo | 2.3.13 + 5 add-ons | 2.3.13 + 5 add-ons |

CentMinMod’s generated Nginx, PHP-FPM, MariaDB and Redis configurations were **not optimized**. Only the minimal `fastcgi_cache` layer was added. PHP 8.6 is omitted because CentMinMod’s EL10 branch supports PHP 8.0–8.5 only.

## Dataset and method

- 20,001 users, 10,000 threads, 101,134 posts (Ubuntu run: 100,400 posts), 51 forum nodes; Hampel Seeder.
- `wrk -t4 -c100 -d10s`, 2 s warm-up, loopback HTTPS.
- Guest cached: `GET /` no cookies. Guest bypass: `xf_session=bench-bypass`. Member home/thread: fresh login cookie per stack.
- Page cache cleared per PHP version; Redis DB 1 flushed when toggled; Angie/Nginx rate limits disabled.
- Stack 1 disables the three SV Redis add-ons; stacks 2–3 enable all five.

## CentMinMod results

### Stack 1 — Plain: Nginx + PHP + MariaDB

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 598 | 594 | 532 | 710 |
| 8.3 | 604 | 598 | 532 | 705 |
| 8.4 | 597 | 598 | 530 | 707 |
| 8.5 | 598 | 593 | 526 | 699 |

### Stack 2 — Redis data cache, no page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 598 | 600 | 544 | 700 |
| 8.3 | 604 | 597 | 538 | 699 |
| 8.4 | 602 | 593 | 545 | 694 |
| 8.5 | 595 | 591 | 540 | 694 |

### Stack 3 — Redis + Nginx FastCGI page cache

| PHP | Guest cached | Guest bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 8.2 | 146,058 | 602 | 540 | 698 |
| 8.3 | 170,437 | 595 | 547 | 696 |
| 8.4 | 148,069 | 592 | 540 | 691 |
| 8.5 | 167,264 | 589 | 539 | 691 |
## CentMinMod vs Ubuntu

| Stack | Guest cached CM / Ubuntu | Member home CM / Ubuntu | Member thread CM / Ubuntu |
|---|---:|---:|---:|
| 1 — Plain | 599 / 786 | 530 / 691 | 705 / 550 |
| 2 — Redis only | 600 / 768 | 542 / 628 | 697 / 497 |
| 3 — Redis + page cache | **157,957 / 138,332** | 542 / 630 | 694 / 496 |

### Cached guest ranking

| Rank | Platform | Stack | Guest cached |
|---:|---|---|---:|
| 1 | CentMinMod | Stack 3 | **157,957** |
| 2 | Ubuntu | Stack 3 | 138,332 |
| 3 | Ubuntu | Stack 1 | 786 |
| 4 | Ubuntu | Stack 2 | 768 |
| 5 | CentMinMod | Stack 2 | 600 |
| 6 | CentMinMod | Stack 1 | 599 |

### Authenticated ranking (mean of member home + thread)

| Rank | Platform | Stack | Mean |
|---:|---|---|---:|
| 1 | Ubuntu | Stack 1 | 620.5 |
| 2 | CentMinMod | Stack 2 | 619.5 |
| 3 | CentMinMod | Stack 3 | 618.0 |
| 4 | CentMinMod | Stack 1 | 617.5 |
| 5 | Ubuntu | Stack 3 | 563.0 |
| 6 | Ubuntu | Stack 2 | 562.5 |

The top four are within 0.5 %; Ubuntu wins member-home, CentMinMod wins member-thread. There is no single authenticated winner.

## PHP version comparison

| PHP | CentMinMod dynamic avg | Ubuntu dynamic avg | CM member home / thread |
|---|---:|---:|---:|
| 8.2 | **608.0** | 614.8 | 530 / 705 |
| 8.3 | 607.1 | 612.0 | 532 / 705 |
| 8.4 | 604.2 | 618.7 | 530 / 707 |
| 8.5 | 601.7 | **619.5** | 526 / 699 |

On CentMinMod, **8.2 is marginally fastest**; on Ubuntu, **8.5**. All four versions are within ~1 % on CentMinMod and ~1.2 % on Ubuntu. There is no meaningful PHP-version speed upgrade here; choose for support, not throughput.

## Conclusion

- **Fastest cached guest stack:** CentMinMod Stack 3, **157,957 req/s**, +14.2 % over Ubuntu Stack 3.
- **Best plain dynamic/guest-bypass:** Ubuntu Stack 1, 783/691 vs CentMinMod 596/530. Ubuntu’s tuned PHP-FPM/JIT/MariaDB profile is doing real work here.
- **Member thread:** CentMinMod is ~28 % faster, likely because its stock ondemand pool allows 30 workers versus Ubuntu’s 12 static workers.
- **Valkey/Redis alone:** no gain on either platform; page cache is the only order-of-magnitude win.

**Overall:** CentMinMod is the better [I]cached guest[/I] stack on this host. Ubuntu is better for [I]guest-bypass[/I] and [I]member-home[/I]. For a guest-heavy forum, CentMinMod Stack 3 wins; for logged-in home traffic, Ubuntu Stack 1 wins. CentMinMod’s stock configuration is not a drop-in performance upgrade over a tuned Ubuntu/Angie stack.

### Caveats

- CentMinMod was deliberately untuned: ondemand/30 PHP-FPM, 6 Nginx workers, JIT off. Ubuntu was tuned by `setup.sh`: static workers, JIT on, larger MariaDB pool.
- PHP 8.6 RC5 was not tested on CentMinMod; EL10 officially supports up to 8.5.
- CentMinMod used Redis 8.6.8 + phpredis; Ubuntu used Valkey 9.0.4 + Credis. A PHP 8.5 phpredis-vs-Credis control on Ubuntu measured within 1–2 %.
- Single 10 s run per cell; cache-hit variance on CentMinMod Stack 3 was 146k–170k across PHP versions.
