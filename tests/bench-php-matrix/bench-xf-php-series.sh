#!/usr/bin/env bash
# XenForo 2.3 on plain nginx + PHP-FPM + MariaDB across compiled PHP series:
# a thin wrapper over bench-php-sources.sh with the series-X.Y arms of
# switch-php-arm.sh and the gated tiers of xf-series.tiers.
#
# Usage (root, on the bench host):
#   SERIES="8.1 8.2 8.3 8.4 8.5 8.6" ROUNDS=5 bench-xf-php-series.sh
#   bench-xf-php-series.sh --summary /root/audit/bench-xf-php/raw-STAMP.tsv
#
# Prerequisites, once: install-php-series.sh $SERIES (one extension set, no
# redis/igbinary); PLAIN=1 deploy-xf.sh; PLAIN=1 install-addons.sh;
# seed-xf.sh (member cookie + median thread in /root/audit/cookies).
#
# Each round visits every arm, forward then reverse (bench-php-sources.sh);
# per arm: cold switch (every pool stopped and drained, the series' unit
# started alone, 200 + XenForo HTML on loopback), guest cache emptied, then
# per profile and tier: gate (200 and the tier's marker: data-logged-in
# "false" for guests, "true" for the member pages; X-Cache-Status HIT on T1
# after one priming request, BYPASS on T2-T4), WARM_N requests, wrk.
#   T1 guest cached /   T2 guest uncached / (xf_session cookie: cache bypass)
#   T3 member forum index   T4 member median thread
# PROFILES defaults to saturation "4:100:10" and efficiency "2:8:15"
# (threads:connections:seconds).  The clock is pinned (set-clock.sh 3600).
# Valkey, Elasticsearch and setup-build-refresh.timer are stopped for the
# run; the timer and the active PHP series (/etc/php/setup-active) are put
# back at the end.  Valkey and Elasticsearch stay stopped.
#
# Output in /root/audit/bench-xf-php/: raw-STAMP.tsv (bench-php-sources rows),
# results-STAMP.tsv (one row per arm/round/tier: req/s, p50, p99, non-2xx,
# php-fpm and nginx CPU ms/req, MHz, gate) and summary-STAMP.md (median and
# spread per arm and tier; rows with non-2xx, socket errors, no requests or a
# failed gate are excluded).
set -Eeuo pipefail
export LC_ALL=C

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCES=$HERE/bench-php-sources.sh
if [[ ${1:-} == --summary ]]; then exec "$SOURCES" "$@"; fi

SERIES=${SERIES:-"8.1 8.2 8.3 8.4 8.5 8.6"}
ROUNDS=${ROUNDS:-5}
OUTDIR=${OUTDIR:-/root/audit/bench-xf-php}
ROOT=/var/www/xf.test.local/public
CK=/root/audit/cookies
STAMP=$(date -u +%Y%m%d-%H%M%S)
RAW=$OUTDIR/raw-$STAMP.tsv
read -r -a ARMS <<<"$(printf 'series-%s ' $SERIES)"

(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
(( ${#ARMS[@]} >= 2 )) || { echo "SERIES needs at least two versions" >&2; exit 1; }
command -v wrk >/dev/null || { echo "wrk is not installed" >&2; exit 1; }
[[ -n $(awk -F'\t' '$1 == "xf-member" { print $2 }' "$CK/cookies.tsv" 2>/dev/null) && -s $CK/xf-thread.url ]] \
  || { echo "no xf-member cookie or xf-thread.url in $CK: run seed-xf.sh (COOKIE_ONLY=1 to log in again)" >&2; exit 1; }
# The plain stack: no cache provider in XenForo's config.
[[ -f $ROOT/src/config.php ]] || { echo "missing $ROOT/src/config.php: run PLAIN=1 deploy-xf.sh" >&2; exit 1; }
if awk '!/^[[:space:]]*(#|\/\/)/' "$ROOT/src/config.php" | grep -q "\['cache'\]\['provider'\]"; then
  echo "$ROOT/src/config.php configures a cache provider: redeploy with PLAIN=1 deploy-xf.sh" >&2; exit 1
fi
# wrk resolves the vhost through /etc/hosts.
getent hosts xf.test.local | grep -q '^127\.0\.0\.1' || echo '127.0.0.1 xf.test.local' >> /etc/hosts
getent hosts xf.test.local | grep -q '^127\.0\.0\.1' \
  || { echo "xf.test.local does not resolve to 127.0.0.1 (an earlier /etc/hosts line wins: remove it)" >&2; exit 1; }

mkdir -p "$OUTDIR"
ACTIVE=$(tr -d '[:space:]' < /etc/php/setup-active 2>/dev/null || true)
TIMER_WAS=0
systemctl is-active --quiet setup-build-refresh.timer && TIMER_WAS=1
restore() {
  if [[ $ACTIVE =~ ^[0-9]+\.[0-9]+$ ]]; then
    "$HERE/switch-php-arm.sh" "series-$ACTIVE" >/dev/null 2>&1 || echo "could not restart PHP $ACTIVE: check php$ACTIVE-fpm" >&2
  fi
  if (( TIMER_WAS )); then systemctl start setup-build-refresh.timer || true; fi
}
trap restore EXIT
systemctl stop setup-build-refresh.timer valkey-server valkey elasticsearch >/dev/null 2>&1 || true
# Stopping the timer leaves a build already running; it would skew every row.
if systemctl list-units --no-legend --plain --state=activating,active \
     'setup-php-build@*' setup-build-refresh.service setup-build-cpu.service 2>/dev/null | grep -q .; then
  echo "a setup build is running (setup-php-build@/setup-build-refresh/setup-build-cpu): wait for it" >&2; exit 1
fi

echo "== XenForo PHP series: ${ARMS[*]} | rounds=$ROUNDS | raw $RAW"
RAW=$RAW PROFILES=${PROFILES:-"4:100:10 2:8:15"} TIERS_FILE=${TIERS_FILE:-$HERE/xf-series.tiers} \
  WARM_N=${WARM_N:-200} WARM_URLS=https://xf.test.local/ \
  "$SOURCES" 100 10 "$ROUNDS" . "${ARMS[@]}" > "$OUTDIR/summary-$STAMP.md"

{
  printf 'arm\tround\ttier\trps\tp50\tp99\tnon2xx\tphp_ms_req\tnginx_ms_req\tmhz\tgate\n'
  awk -F'\t' -v OFS='\t' '{
    php = nginx = mhz = ""
    n = split($8, kv, " ")
    for (i = 1; i <= n; i++) {
      split(kv[i], p, "=")
      if (p[1] == "php-fpm") php = p[2]; else if (p[1] == "nginx") nginx = p[2]; else if (p[1] == "mhz") mhz = p[2]
    }
    split($7, nz, " ")
    gate = ($7 ~ /^GATE/) ? "fail: " $7 : (nz[1] != "0") ? "fail: non-2xx" \
         : ($7 ~ /(connect|read|write|timeout) [1-9]/) ? "fail: socket errors" : (($4 + 0) == 0) ? "fail: no requests" : "ok"
    print $1, $2, $3, $4, $5, $6, nz[1], php, nginx, mhz, gate
  }' "$RAW"
} > "$OUTDIR/results-$STAMP.tsv"

cat "$OUTDIR/summary-$STAMP.md"
echo
echo "results: $OUTDIR/results-$STAMP.tsv  summary: $OUTDIR/summary-$STAMP.md"
if grep -q $'\tfail: ' "$OUTDIR/results-$STAMP.tsv"; then
  echo "WARNING: some rows failed their gate or had non-2xx, socket errors or no requests (not counted): grep 'fail:' $OUTDIR/results-$STAMP.tsv" >&2
fi
