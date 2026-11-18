#!/usr/bin/env bash
# Run one benchmark stack on CentMinMod for the currently active PHP version.
# Usage: VER=8.2 bash bench-centmin-combo.sh {1|2|3|4}
set -Eeuo pipefail
export LC_ALL=C.UTF-8

COMBO=${1:?combo 1-4}
VER=${VER:?set VER to the active PHP minor, e.g. 8.2}
ROOT=/home/nginx/domains/xf.test.local/public
VHOST=/usr/local/nginx/conf/conf.d/xf.test.local.ssl.conf
CACHEINC='  include /usr/local/nginx/conf/xf_cache_server.inc;'
ENVF=/root/audit/bench-env.sh
OUT=/root/audit/cm-${VER}-combo${COMBO}.tsv
PHP=/usr/local/bin/php
CONNS=${CONNS:-100}
SECS=${SECS:-10}
THREADS=${THREADS:-4}

[[ -f $ENVF ]] || { echo "missing $ENVF" >&2; exit 1; }
. "$ENVF"
MEMBER_PW=$(cat /root/audit/member-pass)

command -v wrk >/dev/null 2>&1 || dnf -y install wrk >/dev/null 2>&1 || true
grep -q 'xf.test.local' /etc/hosts || echo '127.0.0.1 xf.test.local' >> /etc/hosts

reload_nginx() {
  /usr/local/sbin/nginx -t >/tmp/nginx-cm-test.log 2>&1 || { cat /tmp/nginx-cm-test.log >&2; return 1; }
  systemctl reload nginx
  sleep 0.3
}

cache_off() {
  sed -i "s|^  include /usr/local/nginx/conf/xf_cache_server.inc;|  # bench: include /usr/local/nginx/conf/xf_cache_server.inc;|" "$VHOST"
  reload_nginx
}

cache_on() {
  sed -i "s|^  # bench: include /usr/local/nginx/conf/xf_cache_server.inc;|${CACHEINC}|" "$VHOST"
  reload_nginx
}

redis_on() {
  sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = true;/" "$ROOT/src/config.php"
  redis-cli -n 1 flushdb >/dev/null 2>&1 || true
  systemctl reload php-fpm
  sleep 0.4
}

redis_off() {
  sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = false;/" "$ROOT/src/config.php"
  systemctl reload php-fpm
  sleep 0.4
}

addons_off() {
  for id in SV/RedisViewCounter SV/RedisFloodCheck SV/RedisCache; do
    runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:addon-disable "$id" >/dev/null 2>&1 || true
  done
  systemctl reload php-fpm
}

addons_on() {
  for id in SV/RedisCache SV/RedisFloodCheck SV/RedisViewCounter; do
    runuser -u nginx -- "$PHP" "$ROOT/cmd.php" xf:addon-enable "$id" >/dev/null 2>&1 || true
  done
  systemctl reload php-fpm
}

clear_page_cache() {
  find /var/cache/nginx/xf -mindepth 1 -delete 2>/dev/null || true
}

login_member() {
  local j t code member
  member=$XF_MEMBER
  j=$(mktemp /tmp/xf-cm-jar.XXXXXX)
  curl -sk --resolve xf.test.local:443:127.0.0.1 -c "$j" -o /tmp/xf-cm-login.html https://xf.test.local/login/
  t=$(grep -oE 'name="_xfToken" value="[^"]+' /tmp/xf-cm-login.html | head -1 | sed 's/.*value="//')
  code=$(curl -sk --resolve xf.test.local:443:127.0.0.1 -b "$j" -c "$j" -o /tmp/xf-cm-post.html -w '%{http_code}' \
    --data-urlencode "login=$member" --data-urlencode "password=$MEMBER_PW" \
    --data-urlencode "_xfToken=$t" -d 'remember=1' https://xf.test.local/login/login)
  XF_COOKIE=$(awk 'BEGIN{ORS=""} { if ($0 ~ /^#HttpOnly_/) sub(/^#HttpOnly_/, ""); if ($0 !~ /^#/ && NF>=7) { printf "%s%s=%s", (n++?"; ":""), $6, $7 } }' "$j")
  rm -f "$j" /tmp/xf-cm-login.html /tmp/xf-cm-post.html
  [[ $code == 303 || $code == 302 ]] || { echo "login failed ($code)" >&2; exit 1; }
  [[ $XF_COOKIE == *xf_session=* ]] || { echo "no session cookie" >&2; exit 1; }
}

cg_usage() {
  local f=/sys/fs/cgroup/system.slice/$1.service/cpu.stat
  [[ -r $f ]] || { printf '0'; return; }
  awk '/^usage_usec/{print $2}' "$f" 2>/dev/null || printf '0'
}

run_tier() {
  local name=$1 url=$2 cookie=${3:-} out rps p50 p99 non2 errs
  local -a h=(-H 'User-Agent: setup-bench/1.0' -H 'Accept-Encoding: gzip, br')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")

  wrk -t"$THREADS" -c"$CONNS" -d2s "${h[@]}" "$url" >/dev/null 2>&1 || true
  local a0 p0 m0 r0 n0 a1 p1 m1 r1 n1
  a0=$(cg_usage nginx); p0=$(cg_usage php-fpm); m0=$(cg_usage mariadb); r0=$(cg_usage redis); n0=$(cg_usage anubis)
  out=$(wrk -t"$THREADS" -c"$CONNS" -d"${SECS}s" --latency "${h[@]}" "$url" 2>&1) || true
  a1=$(cg_usage nginx); p1=$(cg_usage php-fpm); m1=$(cg_usage mariadb); r1=$(cg_usage redis); n1=$(cg_usage anubis)

  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out")
  p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
  errs=$(awk '/Socket errors/{print $0}' <<<"$out" | tr -s ' ' | sed 's/^ //')
  awk -v c="$COMBO" -v v="$VER" -v t="$name" -v r="${rps:-0}" -v p="${p50:-?}" -v q="${p99:-?}" \
      -v n="${non2:-0}" -v e="${errs:-}" -v d="$SECS" \
      -v a="$((a1-a0))" -v ph="$((p1-p0))" -v m="$((m1-m0))" -v re="$((r1-r0))" -v an="$((n1-n0))" \
      'BEGIN{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", c,v,t,r,p,q,n,e,a/(d*1e6),ph/(d*1e6),m/(d*1e6),re/(d*1e6),an/(d*1e6)}' >> "$OUT"
  printf '  %-14s %-4s %8s req/s p50 %-9s p99 %-9s\n' "$name" "$VER" "$rps" "$p50" "$p99" >&2
}

echo "== combo $COMBO for PHP $VER"
case $COMBO in
  1|2|3) bash /root/work/bench/anubis-centmin-off.sh >/dev/null 2>&1 || true ;;
  4) bash /root/work/bench/anubis-centmin-on.sh >/dev/null 2>&1 || { echo "anubis enable failed" >&2; exit 1; } ;;
esac
case $COMBO in
  1) addons_off; redis_off; cache_off ;;
  2) addons_on;  redis_on;  cache_off ;;
  3) addons_on;  redis_on;  cache_on ;;
  4) addons_on;  redis_on;  cache_on
     systemctl is-active --quiet anubis || { echo "anubis is not active" >&2; exit 1; } ;;
  *) echo "combo 1-4" >&2; exit 2 ;;
esac

# Confirm the FPM version actually serving requests.
printf '%s\n' '<?php echo PHP_VERSION;' > "$ROOT/phpver.php"
chown nginx:nginx "$ROOT/phpver.php"
got=$(curl -sk -H 'Cookie: xf_session=bench-bypass' --resolve xf.test.local:443:127.0.0.1 \
  "https://xf.test.local/phpver.php?probe=${VER}-${RANDOM}")
[[ $got == "$VER"* ]] || { echo "PHP probe expected $VER, got '$got'" >&2; exit 1; }
rm -f "$ROOT/phpver.php"

login_member
clear_page_cache
printf 'combo\tphp\ttier\trps\tp50\tp99\tnon2xx\terrors\tnginx_cores\tphp_cores\tmariadb_cores\tredis_cores\tanubis_cores\n' > "$OUT"
run_tier guest_cached   "https://xf.test.local/" ""
run_tier guest_uncached "https://xf.test.local/" "xf_session=bench-bypass"
run_tier member_home    "https://xf.test.local/" "$XF_COOKIE"
run_tier member_thread  "https://xf.test.local${XF_THREAD}" "$XF_COOKIE"
echo "== combo $COMBO done"
