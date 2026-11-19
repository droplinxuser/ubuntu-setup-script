#!/usr/bin/env bash
# Seed the benchmark forum with 20k users, 10k threads and ~100k posts using
# the Hampel Seeder add-on, then prepare a member cookie and thread URL.
set -Eeuo pipefail
export LC_ALL=C.UTF-8

ROOT=/var/www/xf.test.local/public
PHP=/usr/bin/php8.5
PW_FILE=/root/audit/member-pass
MEMBER_PW=$(cat "$PW_FILE" 2>/dev/null || echo 'BenchPass123!')
ENVF=/root/audit/bench-env.sh

echo "== stop the managed XenForo job cron during the benchmark"
crontab -l 2>/dev/null | grep -v 'xf:run-jobs' | crontab - || true

echo "== server-based job trigger (no job runs inside page views)"
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
(cd "$ROOT" && runuser -u www-data -- "$PHP" bench-options.php)
rm -f "$ROOT/bench-options.php"

echo "== seeding (this takes a while)"
cd "$ROOT"
# Hampel Seeder 1.0.0b11 refuses to run unless the forum opts in; the flag is
# removed again right after the run so the benchmark forum is not left with
# seeding switched on.
SEED_FLAG="\$config['hampelSeeder']['enabled'] = true; // audit seeding"
grep -qF "$SEED_FLAG" src/config.php || printf '%s\n' "$SEED_FLAG" >> src/config.php
set +e
runuser -u www-data -- "$PHP" -d memory_limit=4G -d max_execution_time=0 \
  cmd.php seeder:run Default \
  -p users=20000 -p forums=20 -p categories=5 -p subforums=2 \
  -p threads=10000 -p replies=18 -p tags=50 \
  --span=2y --seed=20261116 --no-record \
  > /root/audit/seed.json 2> /root/audit/seed.err
rc=$?
set -e
grep -vF "$SEED_FLAG" src/config.php > src/config.php.tmp && cat src/config.php.tmp > src/config.php && rm -f src/config.php.tmp
echo "seeder exit=$rc"
tail -5 /root/audit/seed.err || true
(( rc == 0 )) || { echo "seeding failed" >&2; exit 1; }

echo "== row counts"
mariadb -N -B xenforo -e "
  SELECT CONCAT('users=', COUNT(*)) FROM xf_user
  UNION ALL SELECT CONCAT('threads=', COUNT(*)) FROM xf_thread
  UNION ALL SELECT CONCAT('posts=', COUNT(*)) FROM xf_post
  UNION ALL SELECT CONCAT('forums=', COUNT(*)) FROM xf_forum;"

echo "== reset benchmark member (lowest non-admin user)"
cat > "$ROOT/bench-member.php" <<'PHP'
<?php
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::setupApp('XF\Pub\App');
$user = \XF::finder('XF:User')->where('user_id', '>', 1)->order('user_id')->fetchOne();
if (!$user) { fwrite(STDERR, "no member found\n"); exit(1); }
$user->user_state = 'valid';
$auth = $user->Auth;
$auth->setPassword($argv[1]);
$auth->save();
$user->save();
echo $user->username, "\n";
PHP
MEMBER=$(cd "$ROOT" && runuser -u www-data -- "$PHP" bench-member.php "$MEMBER_PW" | tail -1)
rm -f "$ROOT/bench-member.php"
echo "member=$MEMBER"

echo "== find a thread URL"
TID=$(mariadb -N -B xenforo -e 'SELECT thread_id FROM xf_thread ORDER BY thread_id LIMIT 1')
THREAD=$(curl -sk -o /dev/null -w '%{url_effective}' -L \
  --resolve xf.test.local:443:127.0.0.1 "https://xf.test.local/threads/${TID}/")
THREAD=${THREAD#https://xf.test.local}
[[ $THREAD == /threads/* ]] || { echo "could not resolve thread URL (got '$THREAD')" >&2; exit 1; }
echo "thread=$THREAD"

echo "== login as $MEMBER"
J=$(mktemp /tmp/xf-jar.XXXXXX)
curl -sk --resolve xf.test.local:443:127.0.0.1 -c "$J" -o /tmp/xf-login.html https://xf.test.local/login/
TOKEN=$(grep -oE 'name="_xfToken" value="[^"]+' /tmp/xf-login.html | head -1 | sed 's/.*value="//')
CODE=$(curl -sk --resolve xf.test.local:443:127.0.0.1 -b "$J" -c "$J" \
  -o /tmp/xf-login-post.html -w '%{http_code}' \
  --data-urlencode "login=$MEMBER" --data-urlencode "password=$MEMBER_PW" \
  --data-urlencode "_xfToken=$TOKEN" -d 'remember=1' https://xf.test.local/login/login)
echo "login http=$CODE"
COOKIE=$(awk 'BEGIN{ORS=""} {
  if ($0 ~ /^#HttpOnly_/) sub(/^#HttpOnly_/, "");
  if ($0 !~ /^#/ && NF>=7) { printf "%s%s=%s", (n++?"; ":""), $6, $7 }
}' "$J")
rm -f "$J" /tmp/xf-login.html /tmp/xf-login-post.html
[[ $COOKIE == *xf_session=* ]] || { echo "login cookie missing" >&2; exit 1; }

cat > "$ENVF" <<EOF
XF_COOKIE='${COOKIE}'
XF_THREAD='${THREAD}'
XF_MEMBER='${MEMBER}'
XF_MEMBER_PW='${MEMBER_PW}'
EOF
chmod 600 "$ENVF"
echo "== env written to $ENVF (${#COOKIE} cookie bytes)"
