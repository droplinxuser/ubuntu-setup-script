#!/usr/bin/env bash
# Low-concurrency PHP efficiency pass on the plain stack (no page cache, no
# Valkey): 8 clients, so requests are not queued behind every FPM
# worker.  Measures guest (cache-bypass) and member home.
set -Eeuo pipefail
export LC_ALL=C.UTF-8

ROOT=/var/www/xf.test.local/public
ENVF=/root/audit/bench-env.sh
OUT=/root/audit/efficiency.tsv
SETUP=/root/work/ubuntu-setup-script
CONFIGS=/root/work/server-configs-nginx
VERS="8.2 8.3 8.4 8.5 8.6"
CONNS=8
SECS=15

. "$ENVF"

echo "== disable page cache, disable Valkey data cache"
CONFIG_SOURCE_DIR=$CONFIGS bash "$SETUP/setup.sh" --optimize > /root/audit/eff-disable.log 2>&1 || true
sed -i -E 's|^([[:space:]]*fastcgi_cache[[:space:]]+)[A-Za-z0-9_]+;|\1off;|' /etc/angie/h5bp/php_xf.conf /etc/angie/h5bp/php_xf_proxy.conf 2>/dev/null || true
sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = false;/" "$ROOT/src/config.php"
grep -rlE 'limit_req[[:space:]]+zone=' /etc/angie --include='*.conf' 2>/dev/null \
  | while IFS= read -r f; do sed -i -E 's|^([[:space:]]*)limit_req([[:space:]]+zone=)|\1# bench: limit_req\2|' "$f"; done

set_php() {
  local v=$1
  sed -i -E "s|^([[:space:]]*server[[:space:]]+)unix:/run/php/[^;]+;|\\1unix:/run/php/php${v}-fpm.sock;|" /etc/angie/angie.conf
  angie -t >/dev/null
  systemctl reload angie
  sleep 0.5
  for s in $VERS; do systemctl is-active --quiet "php$s-fpm" && systemctl reload "php$s-fpm" || true; done
  sleep 0.3
  local got
  got=$(curl -sk -H 'Cookie: xf_session=bench-bypass' --resolve xf.test.local:443:127.0.0.1 \
    "https://xf.test.local/phpver.php?probe=${v}-${RANDOM}")
  [[ $got == "$v"* ]] || { echo "PHP probe expected $v, got '$got'" >&2; exit 1; }
}

run() {
  local tier=$1 url=$2 cookie=${3:-} out rps p50 p99
  local -a h=(-H 'User-Agent: setup-bench/1.0' -H 'Accept-Encoding: gzip, br')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  wrk -t2 -c"$CONNS" -d2s "${h[@]}" "$url" >/dev/null 2>&1 || true
  out=$(wrk -t2 -c"$CONNS" -d"${SECS}s" --latency "${h[@]}" "$url" 2>&1)
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out")
  p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  printf '%s\t%s\t%s\t%s\n' "$VER" "$tier" "$rps" "$p50/$p99" >> "$OUT"
  printf '  %-4s %-14s %6s req/s p50/p99 %s\n' "$VER" "$tier" "${rps:-0}" "$p50/$p99" >&2
}

echo '<?php echo PHP_VERSION;' > "$ROOT/phpver.php"
chown www-data:www-data "$ROOT/phpver.php"
printf 'php\ttier\trps\tp50_p99\n' > "$OUT"
for VER in $VERS; do
  set_php "$VER"
  for d in /home/nginx_cache /home/nginx_cache_chev /home/xf_proxy_cache; do
    [[ -d $d ]] && find "$d" -mindepth 1 -delete 2>/dev/null || true
  done
  run guest_uncached "https://xf.test.local/" "xf_session=bench-bypass"
  run member_home    "https://xf.test.local/" "$XF_COOKIE"
done
set_php 8.5
rm -f "$ROOT/phpver.php"
echo "== efficiency done: $OUT"
