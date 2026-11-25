#!/usr/bin/env bash
# Run one benchmark stack (1=plain, 2=Valkey, 3=+nginx cache)
# across PHP 8.1-8.6 (switch-php-arm.sh series-X.Y) and four request tiers.  Run as root on the forum host.
#
# Usage: bench-combo.sh {1|2|3}
set -Eeuo pipefail
export LC_ALL=C.UTF-8

COMBO=${1:?combo 1-3}
ROOT=/var/www/xf.test.local/public
ENVF=/root/audit/bench-env.sh
OUT=/root/audit/combo${COMBO}.tsv
BACKUP=/root/audit/nginx-bench-backup
CONNS=${CONNS:-100}
SECS=${SECS:-10}
THREADS=${THREADS:-4}
VERS=${VERS:-"8.1 8.2 8.3 8.4 8.5 8.6"}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ACTIVE=$(tr -d '[:space:]' < /etc/php/setup-active)

[[ -f $ENVF ]] || { echo "missing $ENVF; run seed-xf.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENVF"

command -v wrk >/dev/null 2>&1 || apt-get install -y --no-install-recommends wrk >/dev/null
grep -q 'xf.test.local' /etc/hosts || echo '127.0.0.1 xf.test.local' >> /etc/hosts

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ ! -d $BACKUP ]]; then
  mkdir -p "$BACKUP/files"
  cp -a /etc/nginx/nginx.conf "$BACKUP/nginx.conf"
  cp -a "$ROOT/src/config.php" "$BACKUP/config.php"
  # Only the files that actually carry a page-cache directive are toggled;
  # restoring the whole h5bp tree would undo unrelated tuner changes.
  grep -rlE '^[[:space:]]*fastcgi_cache[[:space:]]+[A-Za-z0-9_]+;' /etc/nginx \
    > "$BACKUP/cache-files.txt"
  while IFS= read -r f; do
    mkdir -p "$BACKUP/files$(dirname "$f")"
    cp -a "$f" "$BACKUP/files$f"
  done < "$BACKUP/cache-files.txt"
fi

reload_nginx() {
  nginx -t >/tmp/nginx-bench-test.log 2>&1 || { cat /tmp/nginx-bench-test.log >&2; return 1; }
  systemctl reload nginx
  sleep 0.3
}

# 1.22 layout: every compiled series (install-php-series.sh) listens on the
# shared /run/php/php-fpm.sock; switch-php-arm.sh starts exactly one.
set_php() {
  local v=$1
  "$HERE/switch-php-arm.sh" "series-$v" >/dev/null
  local got
  got=$(curl -sk --max-time 10 -H 'Cookie: xf_session=bench-bypass' \
    --resolve xf.test.local:443:127.0.0.1 "https://xf.test.local/phpver.php?probe=${v}-${RANDOM}")
  [[ $got == "$v"* ]] || { echo "PHP probe expected $v, got '$got'" >&2; exit 1; }
}

cache_off() {
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    sed -i -E 's|^([[:space:]]*fastcgi_cache[[:space:]]+)[A-Za-z0-9_]+;|\1off;|' "$f"
  done < "$BACKUP/cache-files.txt"
  reload_nginx
}

cache_on() {
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    cp -a "$BACKUP/files$f" "$f"
  done < "$BACKUP/cache-files.txt"
  reload_nginx
}

valkey_off() {
  sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = false;/" "$ROOT/src/config.php"
  for v in $VERS; do systemctl is-active --quiet "php$v-fpm" && systemctl reload "php$v-fpm" || true; done
  sleep 0.5
}

valkey_on() {
  sed -i "s/^\$config\['cache'\]\['enabled'\] = .*/\$config['cache']['enabled'] = true;/" "$ROOT/src/config.php"
  valkey-cli -s /run/valkey/valkey.sock -n 1 flushdb >/dev/null 2>&1 || true
  for v in $VERS; do systemctl is-active --quiet "php$v-fpm" && systemctl reload "php$v-fpm" || true; done
  sleep 0.5
}

rate_off() {
  grep -rlE 'limit_req[[:space:]]+zone=' /etc/nginx --include='*.conf' 2>/dev/null \
    | while IFS= read -r f; do
        sed -i -E 's|^([[:space:]]*)limit_req([[:space:]]+zone=)|\1# bench: limit_req\2|' "$f"
      done
  reload_nginx
}

clear_page_cache() {
  local d
  for d in /home/nginx_cache /home/nginx_cache_chev /home/nginx_cache_flarum /home/xf_proxy_cache; do
    [[ -d $d ]] && find "$d" -mindepth 1 -delete 2>/dev/null || true
  done
}

cg_usage() {
  local f=/sys/fs/cgroup/system.slice/${1}.service/cpu.stat
  [[ -r $f ]] || { printf '0'; return; }
  awk '/^usage_usec/{print $2}' "$f" 2>/dev/null || printf '0'
}

# run_tier NAME URL COOKIE_HEADER(optional)
run_tier() {
  local name=$1 url=$2 cookie=${3:-} out rps p50 p99 non2 errs
  local -a h=(-H 'Accept-Encoding: gzip, br' -H 'User-Agent: setup-bench/1.0')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")

  wrk -t"$THREADS" -c"$CONNS" -d2s "${h[@]}" "$url" >/dev/null 2>&1 || true

  local a0 p0 m0 v0 a1 p1 m1 v1
  a0=$(cg_usage nginx); p0=$(cg_usage "php$VER-fpm"); m0=$(cg_usage mariadb); v0=$(cg_usage valkey-server)
  out=$(wrk -t"$THREADS" -c"$CONNS" -d"${SECS}s" --latency "${h[@]}" "$url" 2>&1) || true
  a1=$(cg_usage nginx); p1=$(cg_usage "php$VER-fpm"); m1=$(cg_usage mariadb); v1=$(cg_usage valkey-server)

  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out")
  p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
  errs=$(awk '/Socket errors/{print $0}' <<<"$out" | tr -s ' ' | sed 's/^ //')
  awk -v c="$COMBO" -v v="$VER" -v t="$name" -v r="${rps:-0}" -v p="${p50:-?}" -v q="${p99:-?}" \
      -v n="${non2:-0}" -v e="${errs:-}" -v d="$SECS" \
      -v a="$((a1-a0))" -v ph="$((p1-p0))" -v m="$((m1-m0))" -v va="$((v1-v0))" \
      'BEGIN{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\n", c,v,t,r,p,q,n,e,a/(d*1e6),ph/(d*1e6),m/(d*1e6),va/(d*1e6)}' >> "$OUT"
  printf '  %-14s %-4s %8s req/s  p50 %-9s p99 %-9s\n' "$name" "$VER" "$rps" "$p50" "$p99" >&2
}

echo "== combo $COMBO setup"
case $COMBO in
  1) valkey_off; cache_off; rate_off ;;
  2) valkey_on;  cache_off; rate_off ;;
  3) cache_on;   valkey_on; rate_off ;;
  *) echo "combo must be 1-3" >&2; exit 2 ;;
esac

echo "== writing $OUT"
printf 'combo\tphp\ttier\trps\tp50\tp99\tnon2xx\terrors\tnginx_cores\tphp_cores\tmariadb_cores\tvalkey_cores\n' > "$OUT"

echo '<?php echo PHP_VERSION;' > "$ROOT/phpver.php"
chown www-data:www-data "$ROOT/phpver.php"
chmod 644 "$ROOT/phpver.php"

for VER in $VERS; do
  set_php "$VER"
  clear_page_cache
  sleep 0.3
  run_tier guest_cached   "https://xf.test.local/" ""
  run_tier guest_uncached "https://xf.test.local/" "xf_session=bench-bypass"
  run_tier member_home    "https://xf.test.local/" "$XF_COOKIE"
  run_tier member_thread  "https://xf.test.local${XF_THREAD}" "$XF_COOKIE"
done

set_php "$ACTIVE"
rm -f "$ROOT/phpver.php"
echo "== combo $COMBO complete"
