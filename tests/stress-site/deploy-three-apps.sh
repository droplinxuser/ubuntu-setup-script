#!/usr/bin/env bash
# Deploy WordPress, XenForo and Chevereto from /root/work/pkg/x onto the vhosts made by --domain.
set -Eeuo pipefail
X=/root/work/pkg/x
WP=/var/www/wp.test.local/public; XF=/var/www/xf.test.local/public; CH=/var/www/chev.test.local/public
PW_FILE=/root/audit/test-admin-pass; [ -s $PW_FILE ] || ( umask 077; echo "Audit-$(openssl rand -hex 6)" > $PW_FILE )
PW=$(cat $PW_FILE)
asw() { runuser -u www-data -- "$@"; }
for d in $WP $XF $CH; do find "$d" -mindepth 1 -delete; done
cp -a $X/wp/wordpress/. $WP/; cp -a $X/xf/upload/. $XF/; cp -a $X/chev/. $CH/
chown -R www-data:www-data $WP $XF $CH
find $WP $XF $CH -type d -exec chmod 755 {} +; find $WP $XF $CH -type f -exec chmod 644 {} +

# ---- WordPress
cat > $WP/wp-config.php <<PHP
<?php
define('DB_NAME', 'wordpress'); define('DB_USER', 'wpuser'); define('DB_PASSWORD', 'temp');
define('DB_HOST', 'localhost'); define('DB_CHARSET', 'utf8mb4'); define('DB_COLLATE', '');
$(for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do echo "define('$k', '$(openssl rand -hex 32)');"; done)
\$table_prefix = 'wp_';
define('WP_DEBUG', false);
if ( ! defined('ABSPATH') ) { define('ABSPATH', __DIR__ . '/'); }
require_once ABSPATH . 'wp-settings.php';
PHP
chown www-data:www-data $WP/wp-config.php; chmod 640 $WP/wp-config.php
cat > /tmp/wp-install.php <<'PHP'
<?php
define('WP_INSTALLING', true);
$_SERVER['HTTP_HOST'] = 'wp.test.local'; $_SERVER['HTTPS'] = 'on';
require $argv[1] . '/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';
if (is_blog_installed()) { echo "already installed\n"; exit; }
define('WP_SITEURL', 'https://wp.test.local');
$r = wp_install('SER8 audit', 'admin', 'admin@example.com', true, '', $argv[2]);
echo "wp installed, admin id {$r['user_id']}\n";
PHP
asw php /tmp/wp-install.php $WP "$PW"
cp /root/work/ubuntu-setup-script/tests/stress-site/seed-wp.php $WP/seed-wp.php
(cd $WP && asw php seed-wp.php 100 400 300 | tail -3); rm -f $WP/seed-wp.php

# ---- XenForo
cat > $XF/src/config.php <<'PHP'
<?php
$config['db']['host'] = 'p:localhost';
$config['db']['port'] = 3306;
$config['db']['username'] = 'xfuser';
$config['db']['password'] = 'temp';
$config['db']['dbname'] = 'xenforo';
$config['fullUnicode'] = true;
$config['cache']['enabled'] = true;
$config['cache']['provider'] = 'Redis';
$config['cache']['config'] = ['host' => '/run/valkey/valkey.sock', 'port' => 0, 'database' => 1];
$config['cache']['sessions'] = true;
PHP
chown www-data:www-data $XF/src/config.php; chmod 640 $XF/src/config.php
(cd $XF && asw php cmd.php xf:install --user=admin --password="$PW" --email=admin@example.com --title="SER8 audit forum" --url=https://xf.test.local --skip-statistics -n 2>&1 | tail -3)
cp /root/work/ubuntu-setup-script/tests/stress-site/seed-xf.php $XF/seed-xf.php
(cd $XF && asw php seed-xf.php 60 200 2400 2>&1 | tail -3); rm -f $XF/seed-xf.php
mariadb xenforo -e "UPDATE xf_option SET option_value='1' WHERE option_id='useFriendlyUrls'; UPDATE xf_option SET option_value='server' WHERE option_id='jobRunTrigger';"
(cd $XF && asw php cmd.php xf:rebuild-master-data -n >/dev/null 2>&1 || true)

# ---- Chevereto
cat > $CH/app/env.php <<PHP
<?php
return [
  'CHEVERETO_DB_HOST' => 'localhost', 'CHEVERETO_DB_NAME' => 'chevereto', 'CHEVERETO_DB_USER' => 'chevuser',
  'CHEVERETO_DB_PASS' => 'temp', 'CHEVERETO_DB_PORT' => '3306', 'CHEVERETO_DB_TABLE_PREFIX' => 'chv_',
  'CHEVERETO_DB_DRIVER' => 'mysql', 'CHEVERETO_HOSTNAME' => 'chev.test.local', 'CHEVERETO_HOSTNAME_PATH' => '/',
  'CHEVERETO_HTTPS' => '1', 'CHEVERETO_ENCRYPTION_KEY' => '$(openssl rand -base64 32)',
  'CHEVERETO_CACHE_DRIVER' => 'redis', 'CHEVERETO_CACHE_HOST' => '${CHEV_CACHE_HOST:-/run/valkey/valkey.sock}', 'CHEVERETO_CACHE_PORT' => '${CHEV_CACHE_PORT:-0}',
  'CHEVERETO_ENABLE_DEBUG' => '1', 'CHEVERETO_DEBUG_LEVEL' => '1',
  'CHEVERETO_ENABLE_UPDATE_CHECK' => '0', 'CHEVERETO_ENABLE_NEWS_CHECK' => '0',
];
PHP
chown www-data:www-data $CH/app/env.php; chmod 640 $CH/app/env.php
(cd $CH && asw php app/bin/legacy -C install -u admin -e admin@example.com -x "$PW" 2>&1 | tail -5)
echo "deploy done"
