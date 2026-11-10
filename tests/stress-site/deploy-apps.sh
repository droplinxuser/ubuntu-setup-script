#!/usr/bin/env bash
# One-shot app deployment for the audit (root). Safe to re-run: it only
# replaces the document roots it owns.
set -Eeuo pipefail
XF_ROOT=/var/www/xf.test.local/public
WP_ROOT=/var/www/wp.test.local/public

rm -rf /tmp/xf-src /tmp/wp-src
mkdir -p /tmp/xf-src /tmp/wp-src
unzip -q -o /home/rt/work/xenforo.zip -d /tmp/xf-src
unzip -q -o /home/rt/work/wordpress-7.1.4.zip -d /tmp/wp-src

install -d -m 755 -o www-data -g www-data "$XF_ROOT" "$WP_ROOT"
cp -a /tmp/xf-src/upload/. "$XF_ROOT"/
cp -a /tmp/wp-src/wordpress/. "$WP_ROOT"/
mkdir -p "$XF_ROOT/internal_data" "$XF_ROOT/data"
chown -R www-data:www-data "$XF_ROOT" "$WP_ROOT"
find "$XF_ROOT" "$WP_ROOT" -type d -exec chmod 755 {} +
find "$XF_ROOT" "$WP_ROOT" -type f -exec chmod 644 {} +

cat > "$XF_ROOT/src/config.php" <<'PHP'
<?php
$config['db']['host'] = 'localhost';
$config['db']['port'] = 3306;
$config['db']['username'] = 'xfuser';
$config['db']['password'] = 'temp';
$config['db']['dbname'] = 'xenforo';
$config['http']['basePath'] = '/';
PHP
chown www-data:www-data "$XF_ROOT/src/config.php"
chmod 640 "$XF_ROOT/src/config.php"

cat > "$WP_ROOT/wp-config.php" <<'PHP'
<?php
define('DB_NAME', 'wordpress');
define('DB_USER', 'wpuser');
define('DB_PASSWORD', 'temp');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
define('AUTH_KEY',         'audit-auth-key-0000000000000001');
define('SECURE_AUTH_KEY',  'audit-secure-key-00000000000002');
define('LOGGED_IN_KEY',    'audit-logged-key-00000000000003');
define('NONCE_KEY',        'audit-nonce-key-000000000000004');
define('AUTH_SALT',        'audit-auth-salt-000000000000001');
define('SECURE_AUTH_SALT', 'audit-secure-salt-0000000000002');
define('LOGGED_IN_SALT',   'audit-logged-salt-0000000000003');
define('NONCE_SALT',       'audit-nonce-salt-00000000000004');
$table_prefix = 'wp_';
define('WP_DEBUG', false);
if ( ! defined('ABSPATH') ) { define('ABSPATH', __DIR__ . '/'); }
require_once ABSPATH . 'wp-settings.php';
PHP
chown www-data:www-data "$WP_ROOT/wp-config.php"
chmod 640 "$WP_ROOT/wp-config.php"

echo "files deployed"
sudo -u www-data php "$XF_ROOT/cmd.php" xf:install --help 2>&1 | head -30 || true
