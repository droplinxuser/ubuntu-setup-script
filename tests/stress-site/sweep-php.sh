#!/usr/bin/env bash
# JIT / PHP-FPM sweeps on the PHP-bound tiers (loopback wrk).  Usage: sweep.sh jit|fpm|stock
set -u
V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
INI=/etc/php/$V/fpm/conf.d/zzz-audit.ini; POOL=/etc/php/$V/fpm/pool.d/www.conf
R=/root/work/ubuntu-setup-script/tests/stress-site; CK=/root/audit/cookies/cookies.tsv
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' $CK; }
[[ -s $CK ]] || { echo "missing $CK: run exercise-apps.sh keep first" >&2; exit 1; }
XFT=$(cat /root/audit/cookies/xf-thread.url)
measure() { # url cookiekey -> "rps phpms"
  local url=$1 key=${2:-} out total
  local -a h=(-H 'Accept-Encoding: gzip, br'); [[ -n $key ]] && h+=(-H "Cookie: $(ck "$key")")
  wrk -t4 -c64 -d4s "${h[@]}" "$url" >/dev/null 2>&1
  bash $R/sample-cpu.sh 11 /tmp/sw-cpu.txt >/dev/null 2>&1 &
  out=$(wrk -t4 -c64 -d10s "${h[@]}" "$url" 2>&1); wait
  total=$(awk '/requests in/{print $1}' <<<"$out")
  printf '%s req/s, %s ms PHP' "$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")" \
    "$(python3 $R/analyze-cpu.py /tmp/sw-cpu.txt "${total:-1}" 2>/dev/null | awk '/^php-fpm/{for(i=1;i<=NF;i++) if ($i=="ms/req") print $(i-1)}')"
  [[ $(awk '/Non-2xx/{print $NF}' <<<"$out") ]] && printf ' (non-2xx!)'
}
row() { # label
  systemctl restart php$V-fpm; sleep 1
  printf '| %s | %s | %s | %s |\n' "$1" "$(measure https://wp.test.local/ wp-bench1)" "$(measure "$XFT" xf-member)" "$(measure https://chev.test.local/)"
}
echo "| Profile (PHP $(php -r 'echo PHP_VERSION;'), c=64, 10s) | WordPress member home | XenForo member thread | Chevereto guest home |"
echo "|---|---|---|---|"
case ${1:-jit} in
jit)
  j() { printf 'opcache.jit = %s\nopcache.jit_buffer_size = %s\nopcache.jit_hot_loop = %s\nopcache.jit_hot_func = %s\nopcache.jit_hot_return = %s\nopcache.jit_hot_side_exit = %s\n' "$@" > $INI; }
  j off 0 64 127 16 64;          row "jit off"
  j tracing 64M 64 127 16 64;    row "tracing 64M, default thresholds (shipped)"
  j tracing 64M 61 127 8 8;      row "tracing 64M, PHP 8.4+ built-in thresholds (loop 61 / func 127 / return 8 / side 8)"
  j tracing 128M 64 127 16 64;   row "tracing 128M, default thresholds"
  j tracing 64M 32 63 8 32;      row "tracing 64M, eager (loop 32 / func 63 / return 8 / side 32)"
  j tracing 64M 128 255 32 128;  row "tracing 64M, lazy (loop 128 / func 255 / return 32 / side 128)"
  j function 64M 64 127 16 64;   row "function 64M"
  rm -f $INI ;;
fpm)
  cp -p $POOL /root/audit/www.conf.keep
  for n in 8 12 16 24 32 48; do
    sed -i -E "s/^pm\.max_children = .*/pm.max_children = $n/" $POOL; row "pm=static, max_children=$n"
  done
  cat /root/audit/www.conf.keep > $POOL ;;
stock)
  cp -p $POOL /root/audit/www.conf.keep
  row "tuned (shipped: static 16, OPcache 512M, tracing JIT)"
  sed -i -E "s/^pm = .*/pm = dynamic/; s/^pm\.max_children = .*/pm.max_children = 5\npm.start_servers = 2\npm.min_spare_servers = 1\npm.max_spare_servers = 3/" $POOL
  printf 'opcache.jit = disable\nopcache.jit_buffer_size = 0\nopcache.memory_consumption = 128\nopcache.interned_strings_buffer = 8\nopcache.max_accelerated_files = 10000\nopcache.revalidate_freq = 2\nrealpath_cache_size = 4096k\nrealpath_cache_ttl = 120\n' > $INI
  row "distribution defaults (dynamic 5, OPcache 128M, no JIT)"
  rm -f $INI; cat /root/audit/www.conf.keep > $POOL ;;
esac
systemctl restart php$V-fpm
php-fpm$V -t 2>&1 | tail -1
