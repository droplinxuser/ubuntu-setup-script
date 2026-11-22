#!/usr/bin/env bash
# Security probes for the three audit vhosts.  Every check names the rule it
# exercises and the code it must answer, so a regression in the Angie
# configuration (a deny rule that no longer wins against the PHP location, a
# cache key that accepts a forged header, an internal directory that becomes
# reachable) fails the run instead of quietly shipping.
#
# Usage: IP=<host address> bash security-probe.sh
# Read-only: it only sends requests.
set -u
IP=${IP:?set IP to the test host address}
WP=${WP_DOMAIN:-wp.test.local}
XF=${XF_DOMAIN:-xf.test.local}
CH=${CH_DOMAIN:-chev.test.local}
T=$(mktemp -d); P=0; F=0
ok()  { P=$((P+1)); printf 'PASS  %s\n' "$1"; }
bad() { F=$((F+1)); printf 'FAIL  %s   [%s]\n' "$1" "$2"; }
# probe NAME HOST PATH EXPECTED_CODES...
# PROBE_IP can override the address that is connected to, which changes the
# source address Angie sees (used for the loopback-only wp-cron rule).
probe() {
  local name=$1 host=$2 path=$3; shift 3
  local code ip=${PROBE_IP:-$IP}
  code=$(curl -sk --max-time 20 --path-as-is --resolve "$host:443:$ip" \
           -o "$T/body" -D "$T/hdr" -w '%{http_code}' "https://$host$path")
  local c
  for c in "$@"; do
    if [[ $code == "$c" ]]; then ok "$name ($code)"; return 0; fi
  done
  bad "$name" "got $code want $*"
}
# The host's own non-loopback address, so a request does not arrive from
# 127.0.0.1 (curl against the LAN address of the same host sources it).
EXT_IP=${EXT_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)}
[[ -n $EXT_IP ]] || EXT_IP=$IP
echo "################ WordPress ($WP)"
# Hidden files, dumps and editor backup copies
probe "wp .env is hidden"                 "$WP" /.env 403 404
probe "wp .git/config is hidden"          "$WP" /.git/config 403 404
probe "wp wp-config.php is not served"    "$WP" /wp-config.php 403 404
probe "wp wp-config.php.bak is denied"    "$WP" /wp-config.php.bak 403 404
probe "wp wp-config.php~ is denied"       "$WP" /wp-config.php~ 403 404
probe "wp wp-config.php.swp is denied"    "$WP" /wp-config.php.swp 403 404
probe "wp root dump is denied"            "$WP" /backup.zip 403 404
probe "wp root sql dump is denied"        "$WP" /site.sql 403 404
probe "wp uploads are not executable"     "$WP" /wp-content/uploads/audit.php 403 404
probe "wp uploads PHP suffix is denied"   "$WP" /wp-content/uploads/audit.php.jpg 403 404
probe "wp cache directory is not PHP"     "$WP" /wp-content/cache/audit.php 403 404
probe "wp debug.log is hidden"            "$WP" /wp-content/debug.log 403 404
probe "wp xmlrpc.php is denied"           "$WP" /xmlrpc.php 403
# WordPress's own scheduler posts to wp-cron.php from the loopback address,
# so the endpoint must answer the server itself and nothing else.
PROBE_IP=$EXT_IP probe "wp wp-cron.php is denied from the network" "$WP" /wp-cron.php 403
PROBE_IP=127.0.0.1 probe "wp wp-cron.php is reachable from loopback" "$WP" /wp-cron.php 200
probe "wp install.php is denied"          "$WP" /wp-admin/install.php 403
probe "wp setup-config.php is denied"     "$WP" /wp-admin/setup-config.php 403 404
probe "wp PATH_INFO is not executed"      "$WP" /index.php/foo 404
probe "wp dot segments are rejected"      "$WP" "/%2e%2e/%2e%2e/etc/passwd" 400 404
probe "wp encoded dot segment is rejected" "$WP" "/index.php/%2e%2e/wp-config.php" 400 404
probe "wp login page still works"         "$WP" /wp-login.php 200
probe "wp REST API is reachable"          "$WP" /wp-json/ 200
probe "wp admin-ajax works"                "$WP" /wp-admin/admin-ajax.php 200 400

echo "################ XenForo ($XF)"
probe "xf internal_data is internal"      "$XF" /internal_data/attachments/1.data 403 404
probe "xf internal_data PHP is not run"   "$XF" /internal_data/audit.php 403 404
probe "xf src is internal"                "$XF" /src/config.php 403 404
probe "xf src PHP is not served"          "$XF" /src/XF.php 403 404
probe "xf library PHP is not served"      "$XF" /library/audit.php 403 404
probe "xf data PHP is not executed"       "$XF" /data/audit.php 403 404
probe "xf js PHP is not executed"         "$XF" /js/audit.php 403 404
probe "xf styles PHP is not executed"     "$XF" /styles/audit.php 403 404
# The upgrader is intentionally reachable (a site upgrade needs it); its
# login POST is throttled by limit_req_login, see http.d/limit_req.conf.
probe "xf upgrader redirects to its login" "$XF" /install/ 303 403 404
probe "xf .git/config is hidden"          "$XF" /.git/config 403 404
probe "xf PATH_INFO is not executed"      "$XF" /index.php/foo 404
probe "xf dot segments are rejected"      "$XF" "/%2e%2e/%2e%2e/etc/passwd" 400 404
probe "xf encoded dot segment is rejected" "$XF" "/threads/%2e%2e/login" 400 404
probe "xf css.php works"                  "$XF" /css.php 200 400
probe "xf sitemap.xml redirects"          "$XF" /sitemap.xml 302

echo "################ Chevereto ($CH)"
probe "chev app/env.php is denied"        "$CH" /app/env.php 403 404
probe "chev app PHP is not served"        "$CH" /app/audit.php 403 404
probe "chev vendor PHP is not served"     "$CH" /app/vendor/audit.php 403 404
probe "chev importing is denied"          "$CH" /importing/audit.php 403 404
probe "chev content PHP is not executed"  "$CH" /content/audit.php 403 404
probe "chev sdk PHP is not served"        "$CH" /sdk/audit.php 403 404
probe "chev .env is hidden"               "$CH" /.env 403 404
probe "chev .git/config is hidden"        "$CH" /.git/config 403 404
probe "chev PATH_INFO is not executed"    "$CH" /index.php/foo 404
probe "chev dot segments are rejected"    "$CH" "/%2e%2e/%2e%2e/etc/passwd" 400 404
probe "chev explore works"                "$CH" /explore 200

echo "################ Request smuggling / cache-key forgery"
# An unknown Host must land on the default server (or be rejected), never on
# a managed vhost with attacker-controlled content.
code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' --resolve "evil.example:443:$IP" "https://evil.example/")
case $code in 000|404|421|444) ok "unknown Host is not served ($code)";; *) bad "unknown Host is not served" "got $code";; esac
# An absolute-form request target must not bypass the vhost router.
code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' --resolve "$WP:443:$IP" \
         "https://$WP/" -H 'X-Forwarded-Host: evil.example' -H 'X-Real-IP: 127.0.0.1')
if [[ $code == 200 ]]; then ok "X-Forwarded-Host does not change the vhost ($code)"
else bad "X-Forwarded-Host does not change the vhost" "got $code"; fi
# Methods that must not be answered by a cache or a static handler.
code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' --resolve "$WP:443:$IP" -X PUT "https://$WP/")
case $code in 405|403|400|501) ok "PUT is rejected ($code)";; *) bad "PUT is rejected" "got $code";; esac
code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' --resolve "$WP:443:$IP" -X TRACE "https://$WP/")
case $code in 405|403|400|501) ok "TRACE is rejected ($code)";; *) bad "TRACE is rejected" "got $code";; esac
# A request with a body on GET must not poison the guest cache: the key is the
# validated host/URI, so a second request without the body sees the same page.
curl -sk --max-time 20 --resolve "$WP:443:$IP" -o /dev/null -D "$T/p1" "https://$WP/?audit=1"
curl -sk --max-time 20 --resolve "$WP:443:$IP" -o /dev/null -D "$T/p2" "https://$WP/?audit=1"
if grep -qi '^set-cookie:' "$T/p1" && grep -qi '^set-cookie:' "$T/p2"; then
  bad "wordpress does not replay a Set-Cookie from the cache" "both responses set a cookie"
else ok "wordpress does not replay a Set-Cookie from the cache"; fi

# Each security header exactly once.  The applications send some of these
# themselves (XenForo X-Content-Type-Options, WordPress X-Frame-Options and
# Referrer-Policy on wp-login.php and the REST API, Chevereto
# Permissions-Policy); the vhost hides the upstream copy so only its own
# `always` header remains.  Two copies were shipped up to 1.6.48.
once() {
  local host=$1 path=$2 dup
  curl -sk --max-time 20 --resolve "$host:443:$IP" -o /dev/null -D "$T/h" "https://$host$path"
  dup=$(tr -d '\r' < "$T/h" | cut -d: -f1 | tr '[:upper:]' '[:lower:]' \
        | grep -xE 'x-content-type-options|x-frame-options|referrer-policy|permissions-policy|strict-transport-security|content-security-policy' \
        | sort | uniq -d | tr '\n' ' ')
  if [[ -z $dup ]]; then ok "$host$path sends each security header once"
  else bad "$host$path sends each security header once" "duplicated: $dup"; fi
}
once "$XF" /
once "$XF" '/index.php?login/'
once "$XF" '/css.php?css=public:normalize.css'
once "$WP" /
once "$WP" /wp-login.php
once "$WP" /wp-json/
once "$CH" /explore
once "$CH" /login

# Passkeys: XenForo 2.3 login and two-step call navigator.credentials.get().
# `publickey-credentials-get=()` in Permissions-Policy denies WebAuthn to the
# page itself and the "Use passkey or security key" button silently does
# nothing (server-configs-nginx 1.6.35 to 1.6.48).
passkeys() {
  local host=$1 path=$2 pp
  pp=$(curl -sk --max-time 20 --resolve "$host:443:$IP" -o /dev/null -D - "https://$host$path" \
       | tr -d '\r' | sed -n 's/^[Pp]ermissions-[Pp]olicy: *//p')
  if [[ -z $pp || $pp == *'publickey-credentials-get=(self)'* || $pp == *'publickey-credentials-get=*'* ]] \
     && [[ $pp != *'publickey-credentials-get=()'* ]]; then
    ok "$host$path allows passkeys (WebAuthn get) for the site"
  else bad "$host$path allows passkeys (WebAuthn get) for the site" "${pp:-no header}"; fi
}
passkeys "$XF" /login/
passkeys "$WP" /wp-login.php
passkeys "$CH" /login

echo "################ Guest-cache guards after --optimize"
# A tracking-parameter URL is keyed on its clean URL, so it must never be
# stored (XenForo routes "index.php?utm_x=1&threads/..." to the home page);
# a percent-encoded route is never cached at all.  Before 1.21.58 every
# --optimize rewrote the XenForo bypass lines and dropped both guards.
cache_status() { # HOST PATH -> X-Cache-Status of one request
  curl -sk --max-time 20 --path-as-is --resolve "$1:443:$IP" -o /dev/null -D - "https://$1$2" \
    | tr -d '\r' | sed -n 's/^[Xx]-[Cc]ache-[Ss]tatus: *//p'
}
trk="/index.php?utm_source=probe$RANDOM&threads/x.1/"
s1=$(cache_status "$XF" "$trk"); s2=$(cache_status "$XF" "$trk"); s3=$(cache_status "$XF" "$trk")
if [[ "$s1$s2$s3" != *HIT* ]]; then ok "xf tracking-parameter URL is never stored ($s1/$s2/$s3)"
else bad "xf tracking-parameter URL is never stored" "$s1/$s2/$s3"; fi
enc="/%77hats-new/?probe=$RANDOM"
s1=$(cache_status "$XF" "$enc"); s2=$(cache_status "$XF" "$enc")
if [[ $s1 == BYPASS && $s2 == BYPASS ]]; then ok "xf percent-encoded route bypasses the guest cache"
else bad "xf percent-encoded route bypasses the guest cache" "$s1/$s2"; fi

echo
echo "TOTAL pass=$P fail=$F"
rm -rf "$T"
[[ $F -eq 0 ]]
