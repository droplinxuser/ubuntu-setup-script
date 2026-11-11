# Restore report - PHP upgrade audit (2026-11-11)

Target: `rt@192.0.2.10` (`audit-host`, 16 threads / 27 812 MiB / NVMe,
Ubuntu 26.04.1).  Baseline before the `--upgrade-php` work: 526 packages (the
full host manifest is kept off the public repository; it carries machine
identifiers).

## Sequence

1. `setup.sh --purge all` with the final 1.20.0 tree - stops Angie/PHP-FPM,
   restores the recorded timezone/DNS/UFW/hostname settings and moves
   generated files to `/tmp`.
2. `restore-baseline.sh` with the 54-package delta from the PHP/Ange install -
   purges `angie`, `angie-module-brotli`, `php8.6-*`, `php-common`, their
   dependencies, the Sury/Angie repositories and keyrings, `/etc/angie`,
   `/etc/php`, `/var/www`, `/var/lib/setup.sh` and the generated systemd
   units/sysctl files.
3. Residual sweep: `/etc/systemd/system/*.service.d`, `/etc/mysqlbkup.*`,
   test vhosts in `/etc/hosts`, `/run/php` and `/run/mysqld`, the test report
   logs under `/var/log`, `/root/mysqltuner.pl`, the test credentials in
   `/root/tools/mysqlbackup-master/mysqlbkup.cnf.sample` (blanked), every
   `/tmp` scratch file/directory, `apt-get clean`, and the stale UFW backups
   removed by the shared restore script.
4. Reboot (`systemctl reboot`) to clear tmpfs scratch, `/run` and module
   state, then a fresh manifest was captured 0 minutes after boot.

## Result (after reboot)

```
## Package delta
- Added: none
- Removed: none
- Version changed: none
- Count: baseline      526, current      526

## Enabled unit files added
## Enabled unit files removed

## Active services added
## Active services removed
```

- No `/etc/php`, `/etc/angie`, `/var/www`, `/var/lib/setup.sh`,
  `/opt/stress-node` or `/var/lib/stress-site`.
- No PHP/Angie/MariaDB/Valkey/Elasticsearch unit files; running services match
  the baseline list (17 units).
- `ufw` inactive, root crontab empty, `/etc/sysctl.d` back to
  `README.sysctl`, `/etc/fstab` unchanged (only the baseline swap partition).
- `/tmp` contains only system directories (`systemd-private-*`, `.X11-unix`,
  …); `tcp_bbr` and the test-time conntrack values are gone after the reboot
  (`tcp_congestion_control = cubic`).

Full comparison: `tests/deploy-audit/restore-delta-20261111-upgrade.md`.  The
full restored host manifest is not published (machine identifiers); the
package and file counts above are the comparison.

Remaining differences from the pre-test image, all expected and non-active:

- **4 stale UFW rule backups removed** (`/etc/ufw/*.rules.20261110_222357`) -
  they were already in the baseline image and the shared restore removes
  `*.rules.YYYYMMDD` backups by design.
- **Account database backups rewritten** (`/etc/passwd-`, `/etc/shadow-`,
  `/etc/group-`, `/etc/gshadow-`) by the package add/remove cycle; the live
  `passwd`, `shadow`, `group` and `gshadow` digests are byte-identical to the
  baseline.
- Volatile sysctl values (`kernel.random.boot_id`, `net.core.netdev_rss_key`)
  differ after any boot.
