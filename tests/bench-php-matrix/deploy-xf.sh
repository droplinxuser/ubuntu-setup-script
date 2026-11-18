#!/usr/bin/env bash
# Deploy a clean XenForo 2.3.13 for the PHP matrix benchmark.
# Run as root on the target host.  Creates the database, installs XenForo and
# leaves src/config.php with the cache disabled (combo 1 baseline).
set -Eeuo pipefail
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

ROOT=/var/www/xf.test.local/public
PKG=/root/work/pkg
XF_ZIP=$PKG/xenforo_2.3.13_full.zip
ADMIN_PW=${ADMIN_PW:-BenchAdmin123!}
MEMBER_PW=${MEMBER_PW:-BenchPass123!}
WORK=$(mktemp -d /tmp/xf-deploy.XXXXXX)

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[[ -f $XF_ZIP ]] || { echo "missing $XF_ZIP" >&2; exit 1; }
[[ -d $ROOT ]] || { echo "missing $ROOT (create the --domain vhost first)" >&2; exit 1; }

echo "== database"
mariadb <<'SQL'
DROP DATABASE IF EXISTS xenforo;
CREATE DATABASE xenforo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'xfuser'@'localhost' IDENTIFIED BY 'temp';
ALTER USER 'xfuser'@'localhost' IDENTIFIED BY 'temp';
GRANT ALL PRIVILEGES ON xenforo.* TO 'xfuser'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "== files"
find "$ROOT" -mindepth 1 -delete
unzip -q "$XF_ZIP" -d "$WORK/xf"
cp -a "$WORK/xf/upload/." "$ROOT/"

cat > "$ROOT/src/config.php" <<PHP
<?php
\$config['db']['host'] = 'p:localhost';
\$config['db']['port'] = 3306;
\$config['db']['username'] = 'xfuser';
\$config['db']['password'] = 'temp';
\$config['db']['dbname'] = 'xenforo';
\$config['fullUnicode'] = true;

// Added by the PHP matrix benchmark.  SV/RedisCache converts the provider to
// its bundled Credis client, so no php-redis extension is required on any
// PHP version (8.2 through 8.6).
\$config['cache']['enabled'] = false;
// Explicit provider: XenForo's own factory otherwise instantiates its
// phpredis-backed provider before SV/RedisCache can swap it.
\$config['cache']['provider'] = 'SV\\RedisCache\\Redis';
\$config['cache']['namespace'] = 'xfbench';
\$config['cache']['config'] = [
    'server' => 'unix:///run/valkey/valkey.sock',
    'host' => '/run/valkey/valkey.sock',
    'port' => 0,
    'database' => 1,
];
\$config['cache']['sessions'] = true;

// Hampel Seeder refuses to write without this literal true.
\$config['hampelSeeder']['enabled'] = true;
PHP

chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 640 "$ROOT/src/config.php"

echo "== XenForo install"
runuser -u www-data -- /usr/bin/php8.5 "$ROOT/cmd.php" xf:install \
  --user=admin --password="$ADMIN_PW" --email=admin@example.com \
  --title="PHP Matrix Benchmark" --url="https://xf.test.local" \
  --skip-statistics -n

printf '%s\n' "$ADMIN_PW" > /root/audit/admin-pass
printf '%s\n' "$MEMBER_PW" > /root/audit/member-pass
chmod 600 /root/audit/admin-pass /root/audit/member-pass

echo "== done"
runuser -u www-data -- /usr/bin/php8.5 "$ROOT/cmd.php" xf:version 2>/dev/null || true
