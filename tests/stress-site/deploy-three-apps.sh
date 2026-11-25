#!/usr/bin/env bash
# Deploy WordPress, XenForo and Chevereto from /root/work/pkg/x onto the vhosts made by --domain.
#
# RESET_DB=1 drops and recreates the three databases first, and flushes the
# Valkey databases the applications use.  Without it a re-deploy on a host
# that already ran this script fails: XenForo refuses to install over its
# tables ("You cannot proceed unless all XenForo database tables are
# removed"), and Chevereto answers "[ERROR] Chevereto is already installed"
# even after a DROP DATABASE because cheveretoVersionInstalled() reads
# chv_variables through the Redis cache first.  The audit host is disposable,
# so a reset is the supported way to repeat a deployment.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Domains created by `--domain` (app=wordpress / app=xf / app=chevereto).
# Override them for a run against different names; the defaults are the ones
# the audit host uses when no override is given.
WP_DOMAIN=${WP_DOMAIN:-wp.test.local}
XF_DOMAIN=${XF_DOMAIN:-xf.test.local}
CHV_DOMAIN=${CHV_DOMAIN:-chev.test.local}
X=${X:-/root/work/pkg/x}
WP=/var/www/$WP_DOMAIN/public; XF=/var/www/$XF_DOMAIN/public; CH=/var/www/$CHV_DOMAIN/public
for d in "$WP" "$XF" "$CH"; do
  [[ -d $d ]] || { echo "missing web root $d (create the --domain vhost first, or set WP_DOMAIN/XF_DOMAIN/CHV_DOMAIN)" >&2; exit 1; }
done
PW_FILE=/root/audit/test-admin-pass; [ -s $PW_FILE ] || ( umask 077; echo "Audit-$(openssl rand -hex 6)" > $PW_FILE )
PW=$(cat $PW_FILE)
asw() { runuser -u www-data -- "$@"; }
if [[ ${RESET_DB:-0} == 1 ]]; then
  for db in wordpress xenforo chevereto; do
    mariadb -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
  done
  vk=$(command -v valkey-cli || command -v redis-cli)
  "$vk" -s /run/valkey/valkey.sock -n 0 flushdb >/dev/null
  "$vk" -s /run/valkey/valkey.sock -n 1 flushdb >/dev/null
fi
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
$_SERVER['HTTP_HOST'] = $argv[3]; $_SERVER['HTTPS'] = 'on';
require $argv[1] . '/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';
if (is_blog_installed()) { echo "already installed\n"; exit; }
define('WP_SITEURL', 'https://' . $argv[3]);
$r = wp_install('SER8 audit', 'admin', 'admin@example.com', true, '', $argv[2]);
echo "wp installed, admin id {$r['user_id']}\n";
PHP
asw php /tmp/wp-install.php "$WP" "$PW" "$WP_DOMAIN"
cp "$HERE/seed-wp.php" $WP/seed-wp.php
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
(cd $XF && asw php cmd.php xf:install --user=admin --password="$PW" --email=admin@example.com --title="SER8 audit forum" --url="https://$XF_DOMAIN" --skip-statistics -n 2>&1 | tail -3)
cp "$HERE/seed-xf.php" $XF/seed-xf.php
(cd $XF && asw php seed-xf.php 60 200 2400 2>&1 | tail -3); rm -f $XF/seed-xf.php
# Set the options through XenForo's repository, not with SQL.  A raw UPDATE
# leaves the option cache built during the install in place, so the board
# kept answering GET / with a 301 to /index.php (useFriendlyUrls=0 in the
# cached options) even though the column said 1.  The vhost then cached that
# 301 for an hour, which made every guest request a redirect and invalidated
# the xf-guest throughput tier.
cat > $XF/audit-options.php <<'PHP'
<?php
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::setupApp('XF\Pub\App');
$repo = $app->repository('XF:Option');
$repo->updateOption('useFriendlyUrls', true);
$repo->updateOption('jobRunTrigger', 'server');
echo "options updated\n";
PHP
(cd $XF && asw php audit-options.php); rm -f $XF/audit-options.php
(cd $XF && asw php cmd.php xf:rebuild-master-data -n >/dev/null 2>&1 || true)
# A guest-cache entry written before the option change (a 301 to /index.php)
# would survive for its full TTL, so drop the cache now that the app is right.
if [[ -d /home/nginx_cache ]]; then
  find /home/nginx_cache -mindepth 1 -delete 2>/dev/null || true
  systemctl restart nginx
fi

# ---- Chevereto
cat > $CH/app/env.php <<PHP
<?php
return [
  'CHEVERETO_DB_HOST' => 'localhost', 'CHEVERETO_DB_NAME' => 'chevereto', 'CHEVERETO_DB_USER' => 'chevuser',
  'CHEVERETO_DB_PASS' => 'temp', 'CHEVERETO_DB_PORT' => '3306', 'CHEVERETO_DB_TABLE_PREFIX' => 'chv_',
  'CHEVERETO_DB_DRIVER' => 'mysql', 'CHEVERETO_HOSTNAME' => '$CHV_DOMAIN', 'CHEVERETO_HOSTNAME_PATH' => '/',
  'CHEVERETO_HTTPS' => '1', 'CHEVERETO_ENCRYPTION_KEY' => '$(openssl rand -base64 32)',
  'CHEVERETO_CACHE_DRIVER' => 'redis', 'CHEVERETO_CACHE_HOST' => '${CHEV_CACHE_HOST:-/run/valkey/valkey.sock}', 'CHEVERETO_CACHE_PORT' => '${CHEV_CACHE_PORT:-0}',
  'CHEVERETO_ENABLE_DEBUG' => '1', 'CHEVERETO_DEBUG_LEVEL' => '1',
  'CHEVERETO_ENABLE_UPDATE_CHECK' => '0', 'CHEVERETO_ENABLE_NEWS_CHECK' => '0',
];
PHP
chown www-data:www-data $CH/app/env.php; chmod 640 $CH/app/env.php
(cd $CH && asw php app/bin/legacy -C install -u admin -e admin@example.com -x "$PW" 2>&1 | tail -5)

# Fixtures the guest-cache cookie test needs (WordPress mu-plugin that sets a
# cookie on ?gc=1, and the audit passwords).  Deploying them here keeps the
# security test a one-command run instead of eight unexplained failures.
CHEV_PASSWORD=$PW bash "$(dirname -- "$0")/seed-guest-cache-fixtures.sh"
echo "deploy done"
