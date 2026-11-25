#!/usr/bin/env bash
# Control: Valkey data cache with phpredis on PHP 8.5, page cache OFF.
# The main matrix uses SV/RedisCache's bundled Credis client on every version
# so 8.6 (no php-redis package) is compared like for like.  This control shows
# what the extension changes on the versions that have it.
set -Eeuo pipefail
ROOT=/var/www/xf.test.local/public
ENVF=/root/audit/bench-env.sh
OUT=/root/audit/redis-control.tsv
. "$ENVF"

apt-get install -y --no-install-recommends php8.5-redis >/dev/null
sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = true;/" "$ROOT/src/config.php"
sed -i -E 's|^([[:space:]]*fastcgi_cache[[:space:]]+)[A-Za-z0-9_]+;|\1off;|' /etc/nginx/h5bp/php_xf.conf /etc/nginx/h5bp/php_xf_proxy.conf 2>/dev/null || true
sed -i -E "s|^([[:space:]]*server[[:space:]]+)unix:/run/php/[^;]+;|\\1unix:/run/php/php8.5-fpm.sock;|" /etc/nginx/nginx.conf
nginx -t >/dev/null
systemctl reload nginx
systemctl reload php8.5-fpm
sleep 0.5
/usr/bin/php8.5 -m | grep -qx redis && echo "php-redis: loaded"
valkey-cli -s /run/valkey/valkey.sock -n 1 flushdb >/dev/null 2>&1 || true

printf 'tier\trun\trps\tp50\tp99\n' > "$OUT"
run() {
  local tier=$1 cookie=$2 out rps p50 p99
  local -a h=(-H 'User-Agent: setup-bench/1.0' -H 'Accept-Encoding: gzip, br')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  wrk -t4 -c100 -d2s "${h[@]}" https://xf.test.local/ >/dev/null 2>&1 || true
  out=$(wrk -t4 -c100 -d10s --latency "${h[@]}" https://xf.test.local/ 2>&1)
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out")
  p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  printf '%s\t%s\t%s\t%s\t%s\n' "$tier" "$3" "$rps" "$p50" "$p99" >> "$OUT"
}
for i in 1 2; do
  run guest_uncached "xf_session=bench-bypass" "$i"
  run member_home "$XF_COOKIE" "$i"
done
cat "$OUT"
