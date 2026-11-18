#!/usr/bin/env bash
# Finish the benchmark setup after seeding: reset a known member password,
# resolve a canonical thread URL and write a logged-in cookie header.
set -Eeuo pipefail
ROOT=/var/www/xf.test.local/public
PHP=/usr/bin/php8.5
PW_FILE=/root/audit/member-pass
MEMBER_PW=$(cat "$PW_FILE" 2>/dev/null || echo 'BenchPass123!')
ENVF=/root/audit/bench-env.sh

echo "== row counts"
mariadb -N -B xenforo -e "
  SELECT CONCAT('users=', COUNT(*)) FROM xf_user
  UNION ALL SELECT CONCAT('threads=', COUNT(*)) FROM xf_thread
  UNION ALL SELECT CONCAT('posts=', COUNT(*)) FROM xf_post
  UNION ALL SELECT CONCAT('forums=', COUNT(*)) FROM xf_forum;"

echo "== reset benchmark member"
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

echo "== friendly URLs / thread URL"
TID=$(mariadb -N -B xenforo -e 'SELECT thread_id FROM xf_thread ORDER BY thread_id LIMIT 1')
THREAD=$(curl -sk -o /dev/null -w '%{url_effective}' -L \
  --resolve xf.test.local:443:127.0.0.1 "https://xf.test.local/threads/${TID}/")
THREAD=${THREAD#https://xf.test.local}
[[ $THREAD == /threads/* ]] || { echo "bad thread URL '$THREAD'" >&2; exit 1; }
echo "thread=$THREAD"

echo "== login"
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
echo "== env written (${#COOKIE} cookie bytes)"
