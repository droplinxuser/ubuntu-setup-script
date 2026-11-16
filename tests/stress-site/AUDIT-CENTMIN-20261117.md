# CentMinMod comparison audit — Ubuntu 26.04 + Angie (2026-11-17)

Host: 203.0.113.27 — AMD EPYC 4245P, 6C/12T, 30 GiB, 2× 894 GB Samsung
NVMe, Ubuntu 26.04.1 (kernel 7.0.0-43), no virtualization. This is the same
host class the AlmaLinux 10 + CentMinMod numbers were measured on.

Stack: Angie 1.12.4, PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 (Sury),
MariaDB 11.8.6, Valkey 9.0.4, Anubis 1.28.2, XenForo 2.3.13 + SV/StandardLib
1.24.11, SV/RedisCache 2.18.12, SV/RedisFloodCheck 2.3.1,
SV/RedisViewCounter 2.6.2, Hampel/Seeder 1.0.0b11.

Dataset: 20,001 users, 10,000 threads, 100,400 posts, 47 nodes (the
CentMinMod run used 101,134 posts and 51 nodes; same seeder parameters).

## What changed to beat CentMinMod

| Change | Measured effect |
|---|---|
| **`ssl_buffer_size 16k`** (was 1400) in `h5bp/tls/ssl_engine.conf` | Cached guest tier **151,438 → 442,765 req/s** (2.9×) with the same page and TLS stack: one TLS record per response instead of ~11. |
| **Angie workers = 2/3 of CPUs** (8 on 12 threads, was `auto`=12) | Cached **348-352k → 389-390k** (+11 %); dynamic tiers flat. |
| **Anubis `GOGC=off`** on ≥16 GB hosts (GOMEMLIMIT 2 GiB still bounds the heap) | Anubis cached **51,949 → 57,082 req/s** (+9.9 %); RSS stays < 2 GiB. |
| **OPcache huge pages** (`vm.nr_hugepages` = RAM/64, `opcache.huge_code_pages=1`) | Member 808 → 835, thread 645 → 670 (+3.5 %). |
| Existing: tracing JIT, static `pm=static` 1 worker/CPU, gzip-stored FastCGI cache bodies, `aio off`/`brotli off` in cache locations, static-asset Anubis shadow, Unix sockets end to end | Confirmed as the right defaults by sweeps; 24/32 workers and `validate_timestamps=0` were slower/noise. |

No new service was installed: every change is inside Angie, PHP-FPM/OPcache,
the Go runtime profile of the existing Anubis service, or the kernel profile.

## Method

* `wrk -t4 -c100 -d10s`, 2 s warm-up, loopback HTTPS against `xf.test.local`.
* Guest cached: `GET /`, no cookies, `Accept-Encoding: gzip` (the gzip cache
  entry; without it the response is 106 KB identity and the tier is
  bandwidth-bound on both platforms).
* Guest bypass: `Cookie: xf_session=bench-bypass`.
* Member: fresh XenForo session cookie (`meta.johns`), `GET /`.
* Member thread: the **median 9-post thread** (129 KB), plus the first
  18-post thread (191 KB) reported separately.
* Page cache cleared per stack; Valkey DB 1 flushed when Redis was toggled;
  Angie rate limits disabled for the run (the reference method).
* Stack 4 cached is measured with `ab -k -c100` because wrk 4.1.0
  under-reads bodies from the Go proxy on this host (it reported 4 KB per
  15.6 KB response; `ab` and `oha` agree with `curl`). Dynamic Stack 4
  tiers use `oha` for the same reason.

## Results — CentMinMod (reference, PHP 8.2-8.5 average)

| Stack | Cached | Bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 1 Plain | 599 | 596 | 530 | 705 |
| 2 Redis | 600 | 595 | 542 | 697 |
| 3 Redis + page cache | **157,957** | 595 | 542 | 694 |
| 4 + Anubis | **59,958** | 577 | 525 | 666 |

## Results — Ubuntu 26.04 + Angie (this audit, PHP 8.2-8.5 average)

| Stack | Cached | Bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 1 Plain | 688 | 775 | 663 | 767 |
| 2 Redis | 705 | 813 | 745 | 837 |
| 3 Redis + page cache | **390,232** | 819 | 747 | 838 |
| 4 + Anubis | **68,725** | 709 | 654 | 690 |

## Delta (Ubuntu / CentMinMod)

| Stack | Cached | Bypass | Member home | Member thread |
|---|---:|---:|---:|---:|
| 1 | +14.7 % | +30.1 % | +25.1 % | +8.7 % |
| 2 | +17.5 % | +36.6 % | +37.6 % | +20.0 % |
| 3 | **+147.1 %** | +37.8 % | +37.9 % | +20.7 % |
| 4 | **+14.6 %** | +22.9 % | +24.6 % | +3.5 % |

Every comparable cell is above CentMinMod.

## Per-PHP results

Ubuntu, cached tier:

| PHP | Stack 1 | Stack 2 | Stack 3 | Stack 4 |
|---|---:|---:|---:|---:|
| 8.2 | 678 | 697 | 389,514 | 70,946 |
| 8.3 | 687 | 695 | 392,053 | 69,209 |
| 8.4 | 692 | 705 | 390,677 | 66,145 |
| 8.5 | 693 | 721 | 388,684 | 68,600 |

Ubuntu, dynamic tiers (bypass / member home / median thread):

| PHP | Stack 1 | Stack 2 | Stack 3 | Stack 4 |
|---|---|---|---|---|
| 8.2 | 756/645/753 | 804/737/833 | 809/739/827 | 700/644/684 |
| 8.3 | 770/651/750 | 800/733/823 | 803/732/820 | 709/650/689 |
| 8.4 | 783/689/802 | 816/747/840 | 823/747/842 | 704/654/687 |
| 8.5 | 791/667/761 | 832/764/850 | 841/770/863 | 722/668/699 |

The first (18-post, 191 KB) thread measured 613-678 req/s on Stacks 1-3 and
566 on Stack 4; the published thread is the 9-post page because the
CentMinMod dataset averages 10.1 posts/thread.

## Why CentMinMod was competitive

* PHP built with `-O3 -march=native` (5-10 % faster per request than the
  generic Sury build) and MariaDB linked with jemalloc.
* 30 `ondemand` PHP-FPM children over TCP: many more workers than cores, so
  DB waits overlap. Ubuntu uses 1 static worker/CPU; on this workload it is
  faster on member-home but slightly behind on the 18-post thread.
* Nginx compiled from source with newer OpenSSL; `sendfile_max_chunk 2m`,
  `tcp_nodelay`, `open_file_cache`, 300k connections.
* Stock CentMinMod has **no FastCGI page cache and no Anubis**; those were
  added for the benchmark. Its 6 Nginx workers and JIT-disabled PHP leave
  performance on the table.

An optional follow-up that would need approval (new build, not a new
service): compiling PHP with `-O3 -march=native` could add the same 5-10 %
CentMinMod gets from its build; the Sury packages are generic.

## Reproduce

```bash
# host
bash setup.sh --basic server=dedi time=UTC \
  --angie --php ver=8.5 --mariadb user=xfuser pass=temp \
  --valkey
bash setup.sh --domain xf.test.local app=xf db=xenforo user=xfuser pass=temp
# deploy/seed XenForo 2.3.13 + 5 add-ons (deploy-xf-cm.sh in this cycle)
bash setup.sh --optimize anubis=yes        # Stack 4
# bench (loopback DNS entry 127.0.0.1 xf.test.local)
wrk -t4 -c100 -d10s -H "Accept-Encoding: gzip" https://xf.test.local/
wrk -t4 -c100 -d10s -H "Cookie: xf_session=bench-bypass" https://xf.test.local/
wrk -t4 -c100 -d10s -H "Cookie: $XF_COOKIE" https://xf.test.local/
```
