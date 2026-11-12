# Non-Angie configuration

This directory owns the server-side configuration that does **not** belong in
[`server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx).
That repository is deliberately limited to Angie/Nginx config; PHP-FPM and all
other service configs live here.

| Path | Purpose |
|---|---|
| `system/dns_servers.conf` | systemd-resolved global DNS drop-in |
| `system/sysctl.conf` | kernel/network tuning profile |
| `system/limits.conf` | PAM/security file-descriptor limits |
| `mariadb/mariadb_server.cnf` | reference MariaDB server profile |
| `mariadb/limit_nofile.conf` | MariaDB systemd `LimitNOFILE` drop-in |
| `php/` | PHP-FPM pool templates, `custom_dan.ini`, systemd limits |

`setup.sh` embeds fallbacks for the system and MariaDB profiles so a
single-file run can still provision those services, but the PHP-FPM pool and
`php.ini` templates are intentionally **not** embedded: run an install from a
repository checkout (or package `configs/php/` alongside `setup.sh`) when
installing PHP. When the checkout is present, `setup.sh` prefers the files in
this directory.

Related items:

- `tools/diff_configs.sh` compares both repositories' canonical files with the
  live `/etc` configuration.
- Angie/Nginx configs live in
  [`server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx).
  PHP-FPM configs live in `configs/php/` here.
