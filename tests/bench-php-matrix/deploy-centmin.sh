#!/usr/bin/env bash
# Deploy XenForo 2.3.13 + the benchmark add-ons on CentMinMod (AlmaLinux 10).
# Paths are CentMinMod's generated vhost layout.  Run as root.
set -Eeuo pipefail
export LC_ALL=C.UTF-8

ROOT=/home/nginx/domains/xf.test.local/public
PKG=/root/work/pkg
PHP=/usr/local/bin/php
XF_ZIP=$PKG/xenforo_2.3.13_full.zip
ADMIN_PW=BenchAdmin123!
MEMBER_PW=BenchPass123!
WORK=$(mktemp -d /tmp/xf-centmin.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

[[ -f $XF_ZIP ]] || { echo "missing $XF_ZIP" >&2; exit 1; }
[[ -d $ROOT ]] || { echo "missing $ROOT" >&2; exit 1; }

echo "== database"
mysql <<'SQL'
DROP DATABASE IF EXISTS xenforo;
CREATE DATABASE xenforo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'xfuser'@'127.0.0.1' IDENTIFIED BY 'temp';
ALTER USER 'xfuser'@'127.0.0.1' IDENTIFIED BY 'temp';
GRANT ALL PRIVILEGES ON xenforo.* TO 'xfuser'@'127.0.0.1';
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
\$config['db']['host'] = 'p:127.0.0.1';
\$config['db']['port'] = 3306;
\$config['db']['username'] = 'xfuser';
\$config['db']['password'] = 'temp';
\$config['db']['dbname'] = 'xenforo';
\$config['fullUnicode'] = true;

// CentMinMod's PHP has phpredis; the SV/RedisCache add-on wraps it.
\$config['cache']['enabled'] = false;
\$config['cache']['provider'] = 'Redis';
\$config['cache']['namespace'] = 'xfbench';
\$config['cache']['config'] = [
    'host' => '127.0.0.1',
    'port' => 6379,
    'database' => 1,
];
\$config['cache']['sessions'] = true;

\$config['hampelSeeder']['enabled'] = true;
PHP

chown -R nginx:nginx "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 640 "$ROOT/src/config.php"

echo "== XenForo install"
runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:install \
  --user=admin --password="$ADMIN_PW" --email=admin@example.com \
  --title="PHP Matrix Benchmark" --url="https://xf.test.local" \
  --skip-statistics -n

printf '%s\n' "$ADMIN_PW" > /root/audit/admin-pass
printf '%s\n' "$MEMBER_PW" > /root/audit/member-pass
chmod 600 /root/audit/admin-pass /root/audit/member-pass

echo "== copy add-on files"
for zip in "$PKG"/xenforo_addon_*.zip; do
  [[ -f $zip ]] || continue
  d="$WORK/$(basename "$zip" .zip)"
  mkdir -p "$d"
  unzip -q "$zip" -d "$d"
  [[ -d $d/upload ]] && cp -a "$d/upload/." "$ROOT/"
done
chown -R nginx:nginx "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 640 "$ROOT/src/config.php"

echo "== install add-ons"
for id in Hampel/Seeder SV/StandardLib SV/RedisCache SV/RedisFloodCheck SV/RedisViewCounter; do
  echo "-- $id"
  runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:addon-install "$id" --force \
    || runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:addon-install "$id"
done
runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:addon-list | sed -n '1,20p'

echo "== server-based jobs"
cat > "$ROOT/bench-options.php" <<'PHP'
<?php
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::setupApp('XF\Pub\App');
$repo = $app->repository('XF:Option');
$repo->updateOption('jobRunTrigger', 'server');
$repo->updateOption('useFriendlyUrls', true);
echo "options updated\n";
PHP
(cd "$ROOT" && runuser -u nginx -- "$PHP" bench-options.php)
rm -f "$ROOT/bench-options.php"

echo "== seed"
cd "$ROOT"
runuser -u nginx -- "$PHP" -d memory_limit=4G -d max_execution_time=0 \
  cmd.php seeder:run Default \
  -p users=20000 -p forums=20 -p categories=5 -p subforums=2 \
  -p threads=10000 -p replies=18 -p tags=50 \
  --span=2y --seed=20261116 --no-record \
  > /root/audit/seed.json 2> /root/audit/seed.err || true
tail -8 /root/audit/seed.err || true
mysql -N -B xenforo -e "
  SELECT CONCAT('users=', COUNT(*)) FROM xf_user
  UNION ALL SELECT CONCAT('threads=', COUNT(*)) FROM xf_thread
  UNION ALL SELECT CONCAT('posts=', COUNT(*)) FROM xf_post
  UNION ALL SELECT CONCAT('forums=', COUNT(*)) FROM xf_forum;"

echo "== reset member"
cat > "$ROOT/bench-member.php" <<'PHP'
<?php
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::setupApp('XF\Pub\App');
$user = \XF::finder('XF:User')->where('user_id', '>', 1)->order('user_id')->fetchOne();
if (!$user) { fwrite(STDERR, "no member\n"); exit(1); }
$user->user_state = 'valid';
$auth = $user->Auth;
$auth->setPassword($argv[1]);
$auth->save();
$user->save();
echo $user->username, "\n";
PHP
MEMBER=$(cd "$ROOT" && runuser -u nginx -- "$PHP" bench-member.php "$MEMBER_PW" | tail -1)
rm -f "$ROOT/bench-member.php"
echo "member=$MEMBER"

echo "== thread + login"
TID=$(mysql -N -B xenforo -e 'SELECT thread_id FROM xf_thread ORDER BY thread_id LIMIT 1')
THREAD=$(curl -sk -o /dev/null -w '%{url_effective}' -L --resolve xf.test.local:443:127.0.0.1 "https://xf.test.local/threads/${TID}/")
THREAD=${THREAD#https://xf.test.local}
J=$(mktemp /tmp/xf-jar.XXXXXX)
curl -sk --resolve xf.test.local:443:127.0.0.1 -c "$J" -o /tmp/xf-login.html https://xf.test.local/login/
TOKEN=$(grep -oE 'name="_xfToken" value="[^"]+' /tmp/xf-login.html | head -1 | sed 's/.*value="//')
CODE=$(curl -sk --resolve xf.test.local:443:127.0.0.1 -b "$J" -c "$J" -o /tmp/xf-login-post.html -w '%{http_code}' \
  --data-urlencode "login=$MEMBER" --data-urlencode "password=$MEMBER_PW" \
  --data-urlencode "_xfToken=$TOKEN" -d 'remember=1' https://xf.test.local/login/login)
echo "login=$CODE thread=$THREAD"
COOKIE=$(awk 'BEGIN{ORS=""} { if ($0 ~ /^#HttpOnly_/) sub(/^#HttpOnly_/, ""); if ($0 !~ /^#/ && NF>=7) { printf "%s%s=%s", (n++?"; ":""), $6, $7 } }' "$J")
rm -f "$J" /tmp/xf-login.html /tmp/xf-login-post.html
cat > /root/audit/bench-env.sh <<EOF
XF_COOKIE='${COOKIE}'
XF_THREAD='${THREAD}'
XF_MEMBER='${MEMBER}'
XF_MEMBER_PW='${MEMBER_PW}'
EOF
chmod 600 /root/audit/bench-env.sh
echo "== done"
