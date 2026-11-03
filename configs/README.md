# Non-Angie / non-PHP-FPM configuration

This directory owns the server-side configuration that does **not** belong in
[`server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx).
That repository is deliberately limited to Angie/Nginx and PHP-FPM config.

| Path | Purpose |
|---|---|
| `system/dns_servers.conf` | systemd-resolved global DNS drop-in |
| `system/cpufrequtils` | CPU governor default (`performance`) |
| `system/sysctl.conf` | kernel/network tuning profile |
| `system/limits.conf` | PAM/security file-descriptor limits |
| `mariadb/mariadb_server.cnf` | reference MariaDB server profile |
| `mariadb/limit_nofile.conf` | MariaDB systemd `LimitNOFILE` drop-in |

`setup.sh` embeds equivalent fallbacks so it still works as a single file, but
when it is run from this checkout it prefers the files in this directory. The
MariaDB profile is a reference; `setup.sh` generates a hardware-aware variant
(buffer pool size, thread pool, I/O capacity, slow log, etc.).

Related items:

- `legacy/basic_setup.sh` is the old standalone basic-setup script, superseded
  by `setup.sh`.
- `tools/diff_configs.sh` compares both repositories' canonical files with the
  live `/etc` configuration.
- Angie, Nginx and PHP-FPM configs live in
  [`server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx).
