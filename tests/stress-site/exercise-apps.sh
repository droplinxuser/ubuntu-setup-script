#!/usr/bin/env bash
# Exercise the three apps (guest, member, admin, CLI) with E_ALL logging and summarise PHP diagnostics.
# Usage: exercise.sh [keep]   (keep = leave cookies in /root/audit/cookies for benchmarking)
set -u
PW=$(cat /root/audit/test-admin-pass); V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
J=/root/audit/cookies; mkdir -p $J; rm -f $J/*.jar
LOG=/var/www/logs/php/php-error.log
WP=/var/www/wp.test.local/public; XF=/var/www/xf.test.local/public; CH=/var/www/chev.test.local/public
# Functional test: keep the production error_reporting (E_ALL & ~E_DEPRECATED)
# and only route the central log.  Forcing E_ALL here made applications that
# convert any PHP error into an exception (Chevereto with debug enabled)
# answer 403/500 for a vendor deprecation, which is not a functional failure.
# tests/stress-site/compat-php.sh is the run that forces E_ALL for the
# deprecation scan; it enables each application's own debug mode.
printf 'log_errors = On\nerror_log = %s\n' "$LOG" > /etc/php/$V/fpm/conf.d/zzz-audit.ini
printf 'log_errors = On\nerror_log = %s\n' "$LOG" > /etc/php/$V/cli/conf.d/zzz-audit.ini
systemctl reload php$V-fpm; : > $LOG; chmod 666 $LOG
q() { local h=$1; shift; curl -sk -o /tmp/ex.body -w '%{http_code}' --resolve $h:443:127.0.0.1 "$@"; }
st() { printf '%-34s %s\n' "$1" "$2"; }
# member passwords
(cd $WP && runuser -u www-data -- php -r 'require "wp-load.php"; $u=get_user_by("login","bench1"); wp_set_password($argv[1],$u->ID); echo "wp bench1 id=$u->ID\n";' "$PW")
cat > $XF/p.php <<'PHP'
<?php require __DIR__."/src/XF.php"; \XF::start(__DIR__); $app=\XF::setupApp("XF\Cli\App");
$u=\XF::finder("XF:User")->where("user_id",">",1)->order("user_id")->fetchOne(); $a=$u->Auth; $a->setPassword($argv[1]); $a->save(); echo "xf member=", $u->username, "\n";
PHP
XFM=$(cd $XF && runuser -u www-data -- php p.php "$PW" | sed -n 's/^xf member=//p'); rm -f $XF/p.php; echo "xf member: $XFM"
# ---- WordPress
for who in admin bench1; do
  q wp.test.local -c $J/wp-$who.jar https://wp.test.local/wp-login.php >/dev/null
  st "wp login $who" "$(q wp.test.local -b $J/wp-$who.jar -c $J/wp-$who.jar --data-urlencode log=$who --data-urlencode "pwd=$PW" -d 'wp-submit=Log+In&testcookie=1&redirect_to=https%3A%2F%2Fwp.test.local%2Fwp-admin%2F' https://wp.test.local/wp-login.php)"
done
POST=$(curl -sk --resolve wp.test.local:443:127.0.0.1 https://wp.test.local/ | grep -oE 'https://wp.test.local/benchmark-post[a-z0-9-]+/' | head -1); echo "$POST" > $J/wp-post.url
for u in / "${POST#https://wp.test.local}" /wp-json/wp/v2/posts '/?s=benchmark' /feed/ /wp-sitemap.xml /author/admin/ /category/uncategorized/; do st "wp guest $u" "$(q wp.test.local "https://wp.test.local$u")"; done
for u in / "${POST#https://wp.test.local}" /wp-admin/profile.php; do st "wp member $u" "$(q wp.test.local -b $J/wp-bench1.jar "https://wp.test.local$u")"; done
for u in /wp-admin/ /wp-admin/edit.php /wp-admin/post-new.php /wp-admin/upload.php /wp-admin/themes.php /wp-admin/plugins.php /wp-admin/users.php /wp-admin/options-general.php /wp-admin/site-health.php /wp-admin/edit-comments.php /wp-admin/site-editor.php /wp-admin/update-core.php; do st "wp admin $u" "$(q wp.test.local -b $J/wp-admin.jar "https://wp.test.local$u")"; done
st "wp comment POST" "$(PID=$(curl -sk --resolve wp.test.local:443:127.0.0.1 "$POST" | grep -oE "comment_post_ID' value='[0-9]+" | grep -oE '[0-9]+$' | head -1); q wp.test.local -b $J/wp-bench1.jar -d "comment=audit+comment+$RANDOM&comment_post_ID=$PID&comment_parent=0" https://wp.test.local/wp-comments-post.php)"
(cd $WP && runuser -u www-data -- php wp-cron.php); st "wp-cron cli" $?
# ---- XenForo
xflogin() { local who=$1 jar=$J/xf-$2.jar t
  # Save the body to a file before grep: piping curl into `head` makes curl
  # die on SIGPIPE before it writes the cookie jar, so the following POST
  # arrives without the session cookie and the login is rejected.
  curl -sk --resolve xf.test.local:443:127.0.0.1 -c $jar -o $J/xf-login.html https://xf.test.local/login/
  t=$(grep -oE 'name="_xfToken" value="[^"]+' $J/xf-login.html | head -1 | sed 's/.*value="//')
  st "xf login $who" "$(q xf.test.local -b $jar -c $jar --data-urlencode "login=$who" --data-urlencode "password=$PW" --data-urlencode "_xfToken=$t" -d 'remember=1&_xfRedirect=https%3A%2F%2Fxf.test.local%2F' https://xf.test.local/login/login)"; }
xflogin admin admin; xflogin "$XFM" member
THREAD=$(curl -sk --resolve xf.test.local:443:127.0.0.1 https://xf.test.local/whats-new/posts/ -L | grep -oE '/threads/[a-z0-9.%-]+/' | head -1); echo "https://xf.test.local$THREAD" > $J/xf-thread.url
for u in / "$THREAD" /members/ /whats-new/ /forums/-/index.rss /search/ /help/ /sitemap.xml /css.php; do st "xf guest $u" "$(q xf.test.local -L "https://xf.test.local$u")"; done
for u in / "$THREAD" /account/ /account/preferences /conversations/ /whats-new/posts/ /search/ /members/; do st "xf member $u" "$(q xf.test.local -L -b $J/xf-member.jar "https://xf.test.local$u")"; done
t=$(curl -sk --resolve xf.test.local:443:127.0.0.1 -b $J/xf-member.jar "https://xf.test.local$THREAD" | grep -oE 'name="_xfToken" value="[^"]+' | head -1 | sed 's/.*value="//')
st "xf reply POST" "$(q xf.test.local -b $J/xf-member.jar --data-urlencode "message=audit reply $RANDOM $RANDOM" --data-urlencode "_xfToken=$t" -d '_xfResponseType=json' "https://xf.test.local${THREAD}add-reply")"
st "xf search POST" "$(q xf.test.local -L -b $J/xf-member.jar --data-urlencode "keywords=benchmark" --data-urlencode "_xfToken=$t" https://xf.test.local/search/search)"
q xf.test.local -b $J/xf-admin.jar -c $J/xf-admin.jar https://xf.test.local/admin.php >/dev/null
t=$(grep -oE 'name="_xfToken" value="[^"]+' /tmp/ex.body | head -1 | sed 's/.*value="//')
st "xf admin login" "$(q xf.test.local -b $J/xf-admin.jar -c $J/xf-admin.jar --data-urlencode login=admin --data-urlencode "password=$PW" --data-urlencode "_xfToken=$t" https://xf.test.local/admin.php?login/login)"
for u in '' '?users/list' '?options/' '?nodes/' '?add-ons/' '?styles/' '?tools/rebuild' '?logs/server-error' '?tools/test-email' '?templates/'; do st "xf acp $u" "$(q xf.test.local -L -b $J/xf-admin.jar "https://xf.test.local/admin.php$u")"; done
(cd $XF && runuser -u www-data -- php cmd.php xf:run-jobs --max-execution-time=20 >/dev/null 2>&1); st "xf run-jobs cli" $?
(cd $XF && runuser -u www-data -- php cmd.php xf-rebuild:threads -n >/dev/null 2>&1); st "xf rebuild cli" $?
# ---- Chevereto
# The login_cookie unique key has one-second resolution: a second login for
# the same user in the same second raises SQLSTATE 23000 and Chevereto renders
# a 500. Clear the previous audit's cookies first so repeated runs stay clean.
mariadb -N chevereto -e 'DELETE FROM chv_login_cookies' 2>/dev/null || true
sleep 1
curl -sk --resolve chev.test.local:443:127.0.0.1 -c $J/ch-admin.jar -o $J/chev-login.html https://chev.test.local/login
t=$(grep -oE 'auth_token = "[a-f0-9]+' $J/chev-login.html | head -1 | grep -oE '[a-f0-9]+$')
st "chev login admin" "$(q chev.test.local -b $J/ch-admin.jar -c $J/ch-admin.jar --data-urlencode login-subject=admin --data-urlencode "password=$PW" --data-urlencode "auth_token=$t" -d keep-login=1 https://chev.test.local/login)"
for u in / /explore /explore/recent /explore/trending /explore/albums /explore/users /login /signup /page/tos /search/images/?q=test /api/1/upload /sitemap.xml; do st "chev guest $u" "$(q chev.test.local "https://chev.test.local$u")"; done
for u in / /admin /dashboard /dashboard/settings /dashboard/images /dashboard/users /dashboard/settings/system /settings /upload /explore; do st "chev admin $u" "$(q chev.test.local -L -b $J/ch-admin.jar "https://chev.test.local$u")"; done
# upload a generated PNG through the web form endpoint
php -r '$i=imagecreatetruecolor(640,480); imagefilledrectangle($i,0,0,639,479,imagecolorallocate($i,rand(0,255),120,200)); imagepng($i,"/tmp/ex.png");'
t=$(curl -sk --resolve chev.test.local:443:127.0.0.1 -b $J/ch-admin.jar https://chev.test.local/upload | grep -oE 'auth_token *[=:] *"[a-f0-9]+' | head -1 | grep -oE '[a-f0-9]+$')
st "chev upload POST" "$(q chev.test.local -b $J/ch-admin.jar -F "source=@/tmp/ex.png" -F type=file -F action=upload -F "auth_token=$t" -F nsfw=0 https://chev.test.local/json) $(head -c 120 /tmp/ex.body | tr -d '\n')"
IMG=$(grep -oE '"url_viewer":"[^"]+' /tmp/ex.body | head -1 | sed 's/.*:"//; s#\\/#/#g'); [ -n "$IMG" ] && { echo "$IMG" > $J/ch-image.url; st "chev image page" "$(q chev.test.local "$IMG")"; }
(cd $CH && runuser -u www-data -- php app/bin/legacy -C cron >/dev/null 2>&1); st "chev cron cli" $?
# Path handling: a raw dot-segment (curl --path-as-is) must never reach PHP,
# and a direct front controller on Chevereto must redirect instead of 500.
st "chev rejected dot segment" "$(q chev.test.local --path-as-is https://chev.test.local/foo/../index.php)"
st "chev canonical /index.php" "$(q chev.test.local --path-as-is https://chev.test.local/index.php)"
st "xf rejected dot segment" "$(q xf.test.local --path-as-is https://xf.test.local/foo/../index.php)"
sleep 1
echo "=== PHP $V diagnostics (unique, by app) ==="
for app in wp.test.local xf.test.local chev.test.local; do
  echo "-- $app: deprecated=$(grep -c "Deprecated.*$app" $LOG) warning=$(grep -c "Warning.*$app" $LOG) notice=$(grep -c "Notice.*$app" $LOG) fatal=$(grep -cE "(Fatal|Parse) error.*$app" $LOG)"
  grep "$app" $LOG | sed -E 's/^\[[^]]*\] //; s/ in \/var\/www\/[^ ]+\/public\// in /' | sort | uniq -c | sort -rn | head -${TOP:-12} | cut -c1-230
done
echo "-- other: $(grep -vcE 'wp.test.local|xf.test.local|chev.test.local' $LOG)"; grep -vE 'wp.test.local|xf.test.local|chev.test.local' $LOG | sed -E 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -8 | cut -c1-230
echo "xf_error_log rows: $(mariadb -N xenforo -e 'select count(*) from xf_error_log')"; mariadb -N xenforo -e 'select left(message,180) from xf_error_log group by 1 limit 6'
cp $LOG /root/audit/php-$V-diagnostics.log
rm -f /etc/php/$V/fpm/conf.d/zzz-audit.ini /etc/php/$V/cli/conf.d/zzz-audit.ini; systemctl reload php$V-fpm; : > $LOG; chmod 640 $LOG; chown www-data:www-data $LOG
# cookies.tsv: "<jar name>\t<Cookie header value>" for loopback-tiers.sh and sweep-php.sh
# (only cookies valid for "/", which is what the measured pages receive).
for jar in $J/*.jar; do
  printf '%s\t%s\n' "$(basename "$jar" .jar)" \
    "$(awk -F'\t' 'NF >= 7 && $3 == "/" { printf "%s%s=%s", sep, $6, $7; sep = "; " }' "$jar")"
done > $J/cookies.tsv
[ "${1:-}" = keep ] || rm -f $J/*.jar $J/cookies.tsv
