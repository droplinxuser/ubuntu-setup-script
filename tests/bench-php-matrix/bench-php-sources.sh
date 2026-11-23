#!/usr/bin/env bash
# A/B the PHP install source on one host, at the application tier.
#
# Usage: bench-php-sources.sh CONNS SECS ROUNDS TIER_REGEX ARM [ARM...]
#   ARM  sury | ubuntu | src-TAG   (see switch-php-arm.sh)
#   TIER_REGEX  an egrep pattern matched against loopback-tiers.sh labels,
#               e.g. 'XF member|WP member|Chev guest home'
#
# Every round visits every arm in a rotated order (forward, then reverse), so
# a power-limited clock or a cache warming up cannot favour one arm.  The
# guest cache is emptied before each arm's round and the tiers script warms
# each URL for 2 s.  The clock is pinned with set-clock.sh when available.
#
# Results are raw rows plus a median/min-max summary per arm and tier; the
# first arm on the command line is the baseline for the delta column.
set -Eeuo pipefail
export LC_ALL=C

CONNS=${1:-100}
SECS=${2:-10}
ROUNDS=${3:-3}
FILTER=${4:-.}
shift 4
ARMS=("$@")
(( ${#ARMS[@]} >= 2 )) || { echo "need at least two arms" >&2; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TIERS=$(cd -- "$HERE/../stress-site" && pwd)/loopback-tiers.sh
COOKIES=/root/audit/cookies/cookies.tsv
OUT=$(mktemp /tmp/bench-php-sources.XXXXXX)
trap 'rm -f "$OUT"' EXIT
[[ -s $COOKIES ]] || { echo "missing $COOKIES: run tests/stress-site/exercise-apps.sh keep first" >&2; exit 1; }
[[ -x $TIERS ]] || { echo "missing $TIERS" >&2; exit 1; }

clear_cache() {
  local d
  for d in /home/nginx_cache /home/nginx_cache_chev; do
    [[ -d $d ]] && find "$d" -mindepth 1 -delete 2>/dev/null || true
  done
}

"$HERE/switch-php-arm.sh" "${ARMS[0]}" >/dev/null

printf 'arms: %s | conns=%s secs=%s rounds=%s filter=%s\n' \
  "${ARMS[*]}" "$CONNS" "$SECS" "$ROUNDS" "$FILTER"
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
    "$HERE/switch-php-arm.sh" "$arm" >/dev/null
    clear_cache
    # A first-request burst per vhost, so OPcache and the app's own caches are
    # warm before the first timed tier and every arm starts equally.
    for u in https://wp.test.local/ https://xf.test.local/ https://chev.test.local/explore/; do
      curl -sk -o /dev/null --max-time 30 -H 'Cookie: warm=1' "$u" || true
    done
    "$TIERS" "$CONNS" "$SECS" "$FILTER" 2>/dev/null \
      | awk -F'|' -v arm="$arm" -v rnd="$r" '
          NF >= 5 && $2 !~ /Tier|---/ {
            for (i = 2; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", arm, rnd, $2, $3, $4, $5
          }' >> "$OUT"
  done
done

echo
echo "| tier | arm | median req/s | spread | p99 median | rounds | delta vs first arm |"
echo "|---|---|---:|---|---:|---:|---:|"
awk -F'\t' -v ARMORDER="$(IFS=,; echo "${ARMS[*]}")" '
  BEGIN { na = split(ARMORDER, armorder, ",") }
  { key = $3 "\t" $1; n[key]++; rps[key, n[key]] = $4 + 0; p99[key, n[key]] = $5; }  END {
    # Keep the tier order of first appearance.
    for (k in n) {
      split(k, a, "\t"); tier = a[1]
      if (!(tier in seen)) { seen[tier] = 1; order[++t] = tier }
    }
    for (i = 1; i <= t; i++) {
      tier = order[i]
      # Compute the median of every arm first, then print in the command-line order
      # so the delta column is always relative to the first arm (the baseline).
      for (k in n) {
        split(k, a, "\t")
        if (a[1] != tier) continue
        arm = a[2]; c = n[k]
        for (j = 2; j <= c; j++) {          # insertion sort, c is 3..5
          v = rps[k, j]; pv = p99[k, j]; m = j - 1
          while (m >= 1 && rps[k, m] > v) {
            rps[k, m+1] = rps[k, m]; p99[k, m+1] = p99[k, m]; m--
          }
          rps[k, m+1] = v; p99[k, m+1] = pv
        }
        med[tier, arm] = (c % 2) ? rps[k, (c+1)/2] : (rps[k, c/2] + rps[k, c/2+1]) / 2
        pmed[tier, arm] = p99[k, (c % 2) ? (c+1)/2 : c/2]
        lo[tier, arm] = rps[k, 1]; hi[tier, arm] = rps[k, c]; cnt[tier, arm] = c
      }
      for (j = 1; j <= na; j++) {
        arm = armorder[j]
        if (!((tier, arm) in med)) continue
        basev = med[tier, armorder[1]]
        delta = (basev > 0) ? 100 * (med[tier, arm] - basev) / basev : 0
        printf "| %s | %s | %d | %d-%d | %s | %d | %s\n", tier, arm, med[tier, arm],
               lo[tier, arm], hi[tier, arm], pmed[tier, arm], cnt[tier, arm],
               (j == 1 ? "baseline" : sprintf("%+.1f %%", delta))
      }
    }
  }' "$OUT"
