#!/usr/bin/env bash
# A/B the PHP install source on one host, at the application tier.
#
# Usage: bench-php-sources.sh CONNS SECS ROUNDS TIER_REGEX ARM [ARM...]
#        bench-php-sources.sh --summary RAW_TSV [ARM...]   (summary of a saved run)
#   ARM  series-X.Y | sury | ubuntu | src-TAG   (see switch-php-arm.sh)
#   TIER_REGEX  an egrep pattern matched against loopback-tiers.sh labels,
#               e.g. 'XF member|WP member|Chev guest home'
# Environment:
#   PROFILES="T:C:S ..."  wrk load profiles (threads:connections:seconds), all
#               measured on every arm visit; default "4:CONNS:SECS".  With more
#               than one, each tier label gets a " [cC]" suffix.
#   TIERS_FILE  tier list for loopback-tiers.sh (gated rows; see that script)
#   WARM_N      warm each URL with N requests (loopback-tiers.sh)
#   WARM_URLS   first-request burst per arm (default: the WP, XF and Chevereto
#               homes)
#   RAW=path    keep every row: arm, round, tier, req/s, p50, p99, non-2xx, CPU
#
# Every round visits every arm in a rotated order (forward, then reverse), so
# a power-limited clock or a cache warming up cannot favour one arm.  The
# guest cache is emptied before each arm's round and the tiers script warms
# each URL.  The clock is pinned with set-clock.sh when available.
#
# The summary gives, per tier and arm, the median of each metric computed on
# its own (req/s, p50, p99, php-fpm and nginx CPU ms/req, MHz), the req/s
# spread (min-max, and max-min as % of the median), and the delta of the
# median req/s against the first arm.  Rows whose non-2xx count is not 0
# (including a failed gate) are left out and counted in "bad"; wrk socket
# errors stay in the raw rows.
set -Eeuo pipefail
export LC_ALL=C

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# summary FILE ARM...: the table from raw rows (arm order: the arguments,
# else order of first appearance).
summary() {
  local file=$1; shift
  echo "| tier | arm | median req/s | spread req/s | p50 ms | p99 ms | php ms/req | nginx ms/req | MHz | rounds | bad | delta vs first arm |"
  echo "|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"
  awk -F'\t' -v ARMORDER="$(IFS=,; echo "$*")" '
    function ms(v,  n) {                     # wrk latency -> ms
      n = v + 0
      if (v ~ /us$/) return n / 1000
      if (v ~ /ms$/) return n
      if (v ~ /m$/)  return n * 60000
      if (v ~ /s$/)  return n * 1000
      return -1
    }
    function median(key, m,  c, i, j, v, a) {
      c = cnt[key, m]; if (!c) return -1
      for (i = 1; i <= c; i++) a[i] = val[key, m, i]
      for (i = 2; i <= c; i++) { v = a[i]; j = i - 1; while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- } a[j+1] = v }
      lo[key, m] = a[1]; hi[key, m] = a[c]
      return (c % 2) ? a[(c+1)/2] : (a[c/2] + a[c/2+1]) / 2
    }
    function add(key, m, v) { if (v < 0) return; val[key, m, ++cnt[key, m]] = v }
    function fmt(v, d) { return (v < 0) ? "-" : sprintf("%." d "f", v) }
    BEGIN { na = split(ARMORDER, armorder, ",") }
    {
      tier = $3; arm = $1; key = tier SUBSEP arm
      if (!(tier in tseen)) { tseen[tier] = 1; tiers[++nt] = tier }
      if (!(arm in aseen)) { aseen[arm] = 1; if (!na) armorder[++na2] = arm }
      # Bad: non-2xx, a GATE, wrk socket errors (a timeout drops the slow
      # requests from req/s and p99) or no requests at all.
      split($7, nz, " ")
      if (nz[1] != "0" || ($4 + 0) == 0 || $7 ~ /(connect|read|write|timeout) [1-9]/) { bad[key]++; next }
      add(key, "rps", $4 + 0); add(key, "p50", ms($5)); add(key, "p99", ms($6))
      php = nginx = mhz = -1
      n = split($8, kv, " ")
      for (i = 1; i <= n; i++) {
        split(kv[i], p, "=")
        if (p[1] == "php-fpm") php = p[2] + 0
        else if (p[1] == "nginx") nginx = p[2] + 0
        else if (p[1] == "mhz" && p[2] != "") mhz = p[2] + 0
      }
      add(key, "php", php); add(key, "nginx", nginx); add(key, "mhz", mhz)
    }
    END {
      if (!na) na = na2
      for (t = 1; t <= nt; t++) {
        tier = tiers[t]; base = -1
        for (j = 1; j <= na; j++) {
          arm = armorder[j]; key = tier SUBSEP arm
          if (!((key, "rps") in cnt) && !(key in bad)) continue
          r = median(key, "rps")
          if (j == 1) base = r
          spread = (r > 0) ? sprintf("%d-%d (%.1f %%)", lo[key, "rps"], hi[key, "rps"], 100 * (hi[key, "rps"] - lo[key, "rps"]) / r) : "-"
          delta = (j == 1) ? "baseline" : (base > 0 && r >= 0) ? sprintf("%+.1f %%", 100 * (r - base) / base) : "-"
          printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %d | %s |\n", tier, arm,
                 fmt(r, 0), spread, fmt(median(key, "p50"), 2), fmt(median(key, "p99"), 2),
                 fmt(median(key, "php"), 3), fmt(median(key, "nginx"), 3), fmt(median(key, "mhz"), 0),
                 cnt[key, "rps"], bad[key], delta
        }
      }
    }' "$file"
}

if [[ ${1:-} == --summary ]]; then
  [[ -s ${2:-} ]] || { echo "usage: bench-php-sources.sh --summary RAW_TSV [ARM...]" >&2; exit 2; }
  f=$2; shift 2
  summary "$f" "$@"
  exit 0
fi

CONNS=${1:-100}
SECS=${2:-10}
ROUNDS=${3:-3}
FILTER=${4:-.}
shift 4
ARMS=("$@")
(( ${#ARMS[@]} >= 2 )) || { echo "need at least two arms" >&2; exit 1; }
read -r -a PROF <<<"${PROFILES:-4:$CONNS:$SECS}"

# SWITCH=switch-nginx-arm.sh A/Bs nginx builds with the same rotation (1.21.70).
SWITCH=${SWITCH:-$HERE/switch-php-arm.sh}
TIERS=$(cd -- "$HERE/../stress-site" && pwd)/loopback-tiers.sh
COOKIES=/root/audit/cookies/cookies.tsv
OUT=$(mktemp /tmp/bench-php-sources.XXXXXX)
trap 'rm -f "$OUT"' EXIT
[[ -s $COOKIES ]] || { echo "missing $COOKIES: run tests/stress-site/exercise-apps.sh keep or seed-xf.sh first" >&2; exit 1; }
[[ -x $TIERS ]] || { echo "missing $TIERS" >&2; exit 1; }
read -r -a WARM <<<"${WARM_URLS:-https://wp.test.local/ https://xf.test.local/ https://chev.test.local/explore/}"

clear_cache() {
  local d
  for d in /home/nginx_cache /home/nginx_cache_chev /var/cache/ols/xf; do
    [[ -d $d ]] && find "$d" -mindepth 1 -delete 2>/dev/null || true
  done
}

"$SWITCH" "${ARMS[0]}" >/dev/null

printf 'arms: %s | profiles=%s rounds=%s filter=%s\n' \
  "${ARMS[*]}" "${PROF[*]}" "$ROUNDS" "$FILTER"
SETCLOCK=$(dirname "$TIERS")/set-clock.sh
if [[ -f $SETCLOCK ]]; then
  bash "$SETCLOCK" 3600 >/dev/null 2>&1 || true
  trap 'rm -f "$OUT"; bash "$SETCLOCK" restore >/dev/null 2>&1 || true' EXIT
fi

for (( r = 1; r <= ROUNDS; r++ )); do
  if (( r % 2 )); then order=("${ARMS[@]}"); else
    order=()
    for (( i = ${#ARMS[@]} - 1; i >= 0; i-- )); do order+=("${ARMS[$i]}"); done
  fi
  for arm in "${order[@]}"; do
    echo "== round $r arm $arm" >&2
    "$SWITCH" "$arm" >/dev/null
    clear_cache
    # Chevereto starts a session file in /tmp for every cookie-less request.
    # At benchmark rates (1,500 req/s) its 24-minute GC window holds ~2 million
    # files, past a tmpfs inode limit: MariaDB then failed its temp tables and
    # every application broke mid-run (1.21.69).  Clear them between arms.
    find /tmp -maxdepth 1 -name 'sess_*' -type f -delete 2>/dev/null || true
    # A first-request burst per vhost, so OPcache and the app's own caches are
    # warm before the first timed tier and every arm starts equally.
    for u in "${WARM[@]}"; do
      curl -sk -o /dev/null --max-time 30 -H 'Cookie: warm=1' "$u" || true
    done
    for p in "${PROF[@]}"; do
      IFS=: read -r pt pc ps <<<"$p"
      sfx=""; (( ${#PROF[@]} > 1 )) && sfx=" [c$pc]"
      WRK_T=$pt "$TIERS" "$pc" "$ps" "$FILTER" 2>/dev/null \
        | awk -F'|' -v arm="$arm" -v rnd="$r" -v sfx="$sfx" '
            NF >= 5 && $2 !~ /Tier|---/ {
              for (i = 2; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
              printf "%s\t%s\t%s%s\t%s\t%s\t%s\t%s\t%s\n", arm, rnd, $2, sfx, $3, $4, $5, $6, $7
            }' | tee -a "$OUT" | awk -F'\t' '{ printf "   %-34s %7s req/s  p99 %-9s non-2xx %s\n", $3, $4, $6, $7 }' >&2
    done
  done
done

[[ -n ${RAW:-} ]] && cp "$OUT" "$RAW"
echo
summary "$OUT" "${ARMS[@]}"
