#!/bin/bash
# Guest-cache cookie safety: functional checks against a test host.
#
# Usage: IP=<host address> [PW=...] [CHEV_PW=...] bash guest-cache-cookie-test.sh
# Expects the audit sites xf.test.local, chev.test.local and wp.test.local
# (seeded as in tests/stress-site), a `bench5` member, the Chevereto `admin`
# user and, for the WordPress cookie check, a mu-plugin that sets a
# `guest_token` cookie on ?gc=1.  Run seed-guest-cache-fixtures.sh once after
# deployment; without it the WordPress and Chevereto login checks cannot pass
# on an otherwise correct host.  Read-only apart from logging in and out.
#   PW        bench5 password in WordPress and XenForo (default BenchPass123!)
#   CHEV_PW   Chevereto admin password (default: $PW; pass the value in
#             /root/audit/test-admin-pass when the audit deploy created it)
IP=${IP:?set IP to the test host address}; T=$(mktemp -d); P=0; F=0
PW=${PW:-BenchPass123!}
# The audit deploy writes the Chevereto admin password to test-admin-pass;
# read it when the caller did not pass CHEV_PW (otherwise a correct host
# reports four failures for a password that is simply different).
if [[ -z ${CHEV_PW:-} && -r /root/audit/test-admin-pass ]]; then
  CHEV_PW=$(cat /root/audit/test-admin-pass)
fi
CHEV_PW=${CHEV_PW:-$PW}
ok()   { P=$((P+1)); printf 'PASS  %s\n' "$1"; }
bad()  { F=$((F+1)); printf 'FAIL  %s   [%s]\n' "$1" "$2"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
# req NAME [curl args...] URL  -> $T/NAME.hdr $T/NAME.body ; status in $ST
req()  { local n=$1; shift; local url=${*: -1}; local h; h=$(printf '%s' "$url" | awk -F/ '{print $3}')
         ST=$(curl -sk --max-time 30 --resolve "$h:443:$IP" -o "$T/$n.body" -D "$T/$n.hdr" -w '%{http_code}' "$@"); tr -d '\r' < "$T/$n.hdr" > "$T/$n.h"; }
hdr()  { grep -i "^$2:" "$T/$1.h" | head -1 | sed -E 's/^[^:]+: *//'; }
ncook(){ grep -ci '^set-cookie:' "$T/$1.h"; }
cookv(){ grep -i "^set-cookie: *$2=" "$T/$1.h" | head -1 | sed -E "s/^[^=]+=([^;]*).*/\1/"; }

echo "################ XenForo"
X=https://xf.test.local
req xg1 "$X/"; req xg2 "$X/"; req xg3 "$X/"
chk "XF guest home is 200" "$ST" 200
chk "XF guest home is served from the cache" "$(hdr xg3 x-cache-status)" HIT
chk "XF cached guest page carries no Set-Cookie (HIT)" "$(ncook xg3)" 0
req xm "$X/whats-new/?t=$RANDOM"
chk "XF guest MISS (the request that fills the cache) carries no Set-Cookie" "$(hdr xm x-cache-status):$(ncook xm)" "MISS:0"
chk "XF cached page still has HSTS" "$([ -n "$(hdr xg3 strict-transport-security)" ] && echo y)" y
chk "XF cached page still has Referrer-Policy" "$([ -n "$(hdr xg3 referrer-policy)" ] && echo y)" y
req xh -I "$X/"
chk "XF guest HEAD is 200" "$ST" 200
# no-cache URIs give every guest their own cookie
req xl1 "$X/login/"; req xl2 "$X/login/"
chk "XF /login/ is not cached" "$(hdr xl1 x-cache-status)" BYPASS
a=$(cookv xl1 xf_session); b=$(cookv xl2 xf_session); c1=$(cookv xl1 xf_csrf); c2=$(cookv xl2 xf_csrf)
chk "XF /login/ sets a cookie for each guest" "$([ -n "$a$c1" ] && [ -n "$b$c2" ] && echo y)" y
chk "XF /login/ cookies differ between two guests" "$([ "$a$c1" != "$b$c2" ] && echo y)" y
req xnf "$X/index.php?login/"
chk "XF non-friendly /index.php?login/ is not cached and sets a cookie" "$(hdr xnf x-cache-status):$([ "$(ncook xnf)" -ge 1 ] && echo y)" "BYPASS:y"
req xapi "$X/api/"
chk "XF /api/ is never cached" "$(hdr xapi x-cache-status)" BYPASS
# what XenForo's JS does on a cached page: no xf_csrf cookie -> POST keep-alive with the stale page token
tok=$(grep -oE 'data-csrf="[^"]+"' "$T/xg3.body" | head -1 | sed 's/data-csrf="//;s/"//')
chk "XF cached page embeds a (stale) CSRF token for the JS" "$([ -n "$tok" ] && echo y)" y
rm -f "$T/g.jar"
req xka -c "$T/g.jar" -H 'X-Requested-With: XMLHttpRequest' --data-urlencode "_xfToken=$tok" --data '_xfResponseType=json&_xfWithData=1' "$X/login/keep-alive"
newtok=$(grep -oE '"csrf": *"[^"]+"' "$T/xka.body" | sed -E 's/.*: *"//;s/"$//')
chk "XF keep-alive answers 200 without a cookie and with a stale token" "$ST" 200
chk "XF keep-alive returns a fresh CSRF token" "$([ -n "$newtok" ] && [ "$newtok" != "$tok" ] && echo y)" y
chk "XF keep-alive sets this guest's own xf_csrf cookie" "$([ -n "$(cookv xka xf_csrf)" ] && echo y)" y
# exactly what XF.KeepAlive.refresh() sends: a JSON body, no cookie, the page's stale token
req xkj -H 'Accept: application/json' -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' --data "{\"_xfResponseType\":\"json\",\"_xfToken\":\"$tok\"}" "$X/login/keep-alive"
chk "XF keep-alive (JSON, as the stock JS sends it) returns status ok" "$(grep -c '"status": *"ok"' "$T/xkj.body")" 1
chk "XF keep-alive (JSON) returns a csrf token and sets xf_csrf" "$(grep -c '"csrf": *"' "$T/xkj.body"):$([ -n "$(cookv xkj xf_csrf)" ] && echo y)" "1:y"
rm -f "$T/g2.jar"
req xka2 -c "$T/g2.jar" -H 'X-Requested-With: XMLHttpRequest' --data-urlencode "_xfToken=$tok" --data '_xfResponseType=json&_xfWithData=1' "$X/login/keep-alive"
chk "XF two guests get different xf_csrf cookies" "$([ "$(cookv xka xf_csrf)" != "$(cookv xka2 xf_csrf)" ] && echo y)" y
# the guest now has xf_csrf only: still a guest, still cached
req xgc -b "$T/g.jar" "$X/"
chk "XF guest with only xf_csrf is still served from the cache" "$(hdr xgc x-cache-status)" HIT
# log in with the refreshed token (cached page -> keep-alive -> login)
req xlogin -b "$T/g.jar" -c "$T/g.jar" --data-urlencode "_xfToken=$newtok" --data-urlencode 'login=bench5' --data-urlencode "password=$PW" --data 'remember=1' "$X/login/login"
chk "XF login from a cached page succeeds (303)" "$ST" 303
chk "XF login response delivers session/user cookies" "$([ -n "$(cookv xlogin xf_user)" ] && [ -n "$(cookv xlogin xf_session)" ] && echo y)" y
req xmem -b "$T/g.jar" "$X/"
chk "XF member page bypasses the cache" "$(hdr xmem x-cache-status)" BYPASS
chk "XF member page is rendered for the member" "$(grep -c 'bench5' "$T/xmem.body" | awk '{print ($1>0)?"y":"n"}')" y
chk "XF member page keeps HSTS" "$([ -n "$(hdr xmem strict-transport-security)" ] && echo y)" y
req xg4 "$X/"
# The visitor tabs carry an /account/ link for a logged-in member and none for
# a guest.  The member's user name is not a marker: the "members online" block
# on a board with recent activity lists it on cached guest pages too (that
# assertion reported a phantom leak once the seeded bench5 had been active).
chk "XF member page was not stored: guests still get the guest page" "$(hdr xg4 x-cache-status):$(grep -c 'href="/account/"' "$T/xg4.body")" "HIT:0"
# a POST by a guest is never cached and keeps its cookies
req xpost --data 'keywords=benchmark&_xfToken=x' "$X/search/search"
chk "XF guest POST is not cached" "$(hdr xpost x-cache-status)" BYPASS
# wrong password: the error response must set a session cookie (uncached branch)
req xbad --data-urlencode "_xfToken=$newtok" -b "xf_csrf=$(cookv xka xf_csrf)" --data 'login=bench5&password=wrong' "$X/login/login"
chk "XF failed login is answered by PHP, not the cache" "$(hdr xbad x-cache-status)" BYPASS
req x404 "$X/does-not-exist.php"
chk "XF unknown .php is 404" "$ST" 404
req xcss "$X/css.php?css=public%3Anormalize.css&s=1&l=1&d=1&k=x"
chk "XF css.php carries no Set-Cookie" "$(ncook xcss)" 0
# Logout clears cookies -> Set-Cookie must pass.  XenForo 2.3 renders the log
# out control as a POST form (a GET to /logout/?t=... answers the form page
# with 200 and sets nothing), so the CSRF token goes in the body.
mt=$(grep -oE 'data-csrf="[^"]+"' "$T/xmem.body" | head -1 | sed 's/data-csrf="//;s/"//')
chk "XF member page exposes a CSRF token for the log out form" "$([ -n "$mt" ] && echo y)" y
req xout -b "$T/g.jar" --data-urlencode "_xfToken=$mt" "$X/logout/"
chk "XF logout is accepted (303)" "$ST" 303
chk "XF logout (POST, no-cache URI) passes its Set-Cookie headers" "$([ "$(ncook xout)" -ge 1 ] && echo y)" y

echo "################ Chevereto"
C=https://chev.test.local
req cg1 "$C/explore"; req cg2 "$C/explore"; req cg3 "$C/explore"
chk "Chevereto guest /explore is 200" "$ST" 200
chk "Chevereto guest /explore is served from the cache" "$(hdr cg3 x-cache-status)" HIT
chk "Chevereto cached page carries no Set-Cookie (HIT)" "$(ncook cg3)" 0
req cm "$C/explore/recent?t=$RANDOM"
chk "Chevereto guest MISS carries no Set-Cookie" "$(hdr cm x-cache-status):$(ncook cm)" "MISS:0"
chk "Chevereto cached page has HSTS and X-Content-Type-Options" "$([ -n "$(hdr cg3 strict-transport-security)" ] && [ -n "$(hdr cg3 x-content-type-options)" ] && echo y)" y
req ch1 "$C/"; req ch2 "$C/"
chk "Chevereto home is never cached" "$(hdr ch1 x-cache-status)" BYPASS
s1=$(cookv ch1 PHPSESSID); s2=$(cookv ch2 PHPSESSID)
chk "Chevereto home gives each guest a session" "$([ -n "$s1" ] && [ -n "$s2" ] && echo y)" y
chk "Chevereto two guests get different sessions" "$([ "$s1" != "$s2" ] && echo y)" y
req chq "$C/?random"
chk "Chevereto /?random is not cached" "$(hdr chq x-cache-status)" BYPASS
req clang "$C/explore?lang=es"
chk "Chevereto ?lang= is not cached" "$(hdr clang x-cache-status)" BYPASS
# a guest that owns a session is rendered by PHP with their own token
req cs1 -b "PHPSESSID=$s1" "$C/explore"; req cs2 -b "PHPSESSID=$s2" "$C/explore"
chk "Chevereto guest with a session bypasses the cache" "$(hdr cs1 x-cache-status)" BYPASS
t1=$(grep -oE 'auth_token[^a-f0-9]{1,12}[a-f0-9]{20,}' "$T/cs1.body" | grep -oE '[a-f0-9]{20,}' | head -1)
t2=$(grep -oE 'auth_token[^a-f0-9]{1,12}[a-f0-9]{20,}' "$T/cs2.body" | grep -oE '[a-f0-9]{20,}' | head -1)
tc=$(grep -oE 'auth_token[^a-f0-9]{1,12}[a-f0-9]{20,}' "$T/cg3.body" | grep -oE '[a-f0-9]{20,}' | head -1)
chk "Chevereto each session sees its own auth_token" "$([ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] && echo y)" y
chk "Chevereto session pages do not show the cached page's token" "$([ "$t1" != "$tc" ] && [ "$t2" != "$tc" ] && echo y)" y
req cs1b -b "PHPSESSID=$s1" "$C/explore"
t1b=$(grep -oE 'auth_token[^a-f0-9]{1,12}[a-f0-9]{20,}' "$T/cs1b.body" | grep -oE '[a-f0-9]{20,}' | head -1)
chk "Chevereto token is stable within one session" "$t1b" "$t1"
# login flow
rm -f "$T/c.jar"; req cl -c "$T/c.jar" "$C/login"
lt=$(grep -oE 'auth_token[^a-f0-9]{1,12}[a-f0-9]{20,}' "$T/cl.body" | grep -oE '[a-f0-9]{20,}' | head -1)
req clp -b "$T/c.jar" -c "$T/c.jar" --data-urlencode "auth_token=$lt" --data 'login-subject=admin' --data-urlencode "password=$CHEV_PW" "$C/login"
chk "Chevereto login succeeds (302)" "$ST" 302
chk "Chevereto login delivers the KEEP_LOGIN cookie" "$(grep -c KEEP_LOGIN "$T/c.jar" | awk '{print ($1>0)?"y":"n"}')" y
req cmem -b "$T/c.jar" "$C/explore"
chk "Chevereto logged-in page bypasses the cache" "$(hdr cmem x-cache-status)" BYPASS
req cdash -b "$T/c.jar" "$C/dashboard"
chk "Chevereto /dashboard (nested uncached PHP location) works for the admin" "$ST" 200
req cset -b "$T/c.jar" "$C/settings"
chk "Chevereto /settings works for the logged-in user" "$ST" 200
req cg4 "$C/explore"
chk "Chevereto logged-in page was not stored: guests still get the cached guest page" "$(hdr cg4 x-cache-status):$(ncook cg4)" "HIT:0"
req cjson --data 'action=x' "$C/json"
chk "Chevereto /json POST is not cached" "$(hdr cjson x-cache-status)" BYPASS
req c404 "$C/nope.php"
chk "Chevereto unknown .php is 404" "$ST" 404

echo "################ WordPress"
W=https://wp.test.local
req wg1 "$W/?p=1&t=$RANDOM"
req wa "$W/"; req wb "$W/"; req wc "$W/"
chk "WordPress guest home is cached" "$(hdr wc x-cache-status | sed -E 's/^(HIT|STALE|UPDATING)$/CACHED/')" CACHED
chk "WordPress cached page carries no Set-Cookie" "$(ncook wc)" 0
req wk1 "$W/?gc=1"; req wk2 "$W/?gc=1"; req wk3 "$W/?gc=1"
chk "WordPress page that sets a guest cookie is never stored" "$(hdr wk1 x-cache-status)$(hdr wk2 x-cache-status)$(hdr wk3 x-cache-status)" MISSMISSMISS
chk "WordPress guest cookies are unique per visitor" "$([ "$(cookv wk1 guest_token)" != "$(cookv wk2 guest_token)" ] && [ "$(cookv wk2 guest_token)" != "$(cookv wk3 guest_token)" ] && [ -n "$(cookv wk1 guest_token)" ] && echo y)" y
rm -f "$T/w.jar"; req wl -c "$T/w.jar" "$W/wp-login.php"
req wlp -b "$T/w.jar" -c "$T/w.jar" --data 'log=bench5&testcookie=1&wp-submit=Log+In' --data-urlencode "pwd=$PW" "$W/wp-login.php"
chk "WordPress login succeeds (302) and sets cookies" "$ST:$([ "$(ncook wlp)" -ge 2 ] && echo y)" "302:y"
req wmem -b "$T/w.jar" "$W/"
chk "WordPress logged-in page bypasses the cache" "$(hdr wmem x-cache-status)" BYPASS
req wd "$W/"
chk "WordPress logged-in page was not stored" "$(grep -c 'wp-admin-bar' "$T/wd.body")" 0

echo; echo "TOTAL pass=$P fail=$F"; rm -rf "$T"
