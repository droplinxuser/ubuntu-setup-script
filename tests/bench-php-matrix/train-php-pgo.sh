#!/bin/bash
# Train the instrumented PHP arm with the application traffic the benchmark
# will measure, so -fprofile-use sees the same code paths as production.
# Run as root while `switch-php-arm.sh src-max` serves the instrumented build,
# then stop the unit so every worker flushes its .gcda files.
set -eu
CK=/root/audit/cookies/cookies.tsv
[[ -s $CK ]] || { echo "missing $CK" >&2; exit 1; }
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$CK"; }
XFT=$(cat /root/audit/cookies/xf-thread.url)
WPP=$(cat /root/audit/cookies/wp-post.url)
H=(-H 'Accept-Encoding: gzip, br' -H 'User-Agent: setup-bench-pgo/1.0')

# A deterministic C-heavy request, served by the same pool.
cp -f /root/work/ubuntu-setup-script/tests/bench-php-matrix/php-build-probe.php \
  /var/www/wp.test.local/public/php-build-probe.php
chown www-data:www-data /var/www/wp.test.local/public/php-build-probe.php

run() { # label seconds url [cookie]
  local label=$1 secs=$2 url=$3 cookie=${4:-}
  local -a h=("${H[@]}")
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  echo "train: $label ${secs}s"
  out=$(wrk -t4 -c12 -d"${secs}s" "${h[@]}" "$url" 2>&1)
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  echo "  ${rps:-0} req/s"
  [[ ${rps:-0} -gt 0 ]] || { echo "training run got no requests: $label" >&2; exit 1; }
}

run "xf member thread" 30 "$XFT" "$(ck xf-member)"
run "xf member home"   20 "https://xf.test.local/" "$(ck xf-member)"
run "wp member home"   15 "https://wp.test.local/" "$(ck wp-bench1)"
run "wp member post"   15 "$WPP" "$(ck wp-bench1)"
run "build probe"      10 "https://wp.test.local/php-build-probe.php?n=120" "probe=1"
rm -f /var/www/wp.test.local/public/php-build-probe.php

TAG=${PHP_ARM_TAG:-max}
# NO_STOP=1: traffic only (bolt-php.sh samples the running arm with perf).
[[ ${NO_STOP:-0} == 1 ]] && exit 0
systemctl stop "php-src-$TAG.service"
sleep 2
# GCC writes one .gcda per object; clang one default_%m.profraw per binary.
n=$(find "/root/work/pgo-$TAG" \( -name "*.gcda" -o -name "*.profraw" \) | wc -l)
echo "profile files: $n"
[[ $n -gt 0 ]] || { echo "no profile files in /root/work/pgo-$TAG" >&2; exit 1; }
