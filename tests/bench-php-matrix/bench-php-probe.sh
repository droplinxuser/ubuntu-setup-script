#!/usr/bin/env bash
# Measure php-build-probe.php through nginx + PHP-FPM for each arm, so the
# report can separate a faster C library (json, preg, str, hash, sort) from a
# faster engine/JIT (objects, arithmetic).
#
# Usage: bench-php-probe.sh CONNS SECS ROUNDS ARM [ARM...]
# Prints the median of each probe section in milliseconds per request.
set -Eeuo pipefail
export LC_ALL=C
CONNS=${1:-50}
SECS=${2:-10}
ROUNDS=${3:-3}
shift 3
ARMS=("$@")
(( ${#ARMS[@]} >= 2 )) || { echo "need at least two arms" >&2; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=/var/www/wp.test.local/public
URL='https://wp.test.local/php-build-probe.php?n=120'
OUT=$(mktemp /tmp/bench-php-probe.XXXXXX)
trap 'rm -f "$OUT"' EXIT
cp -f "$HERE/php-build-probe.php" "$ROOT/php-build-probe.php"
chown www-data:www-data "$ROOT/php-build-probe.php"
SETCLOCK="$HERE/../stress-site/set-clock.sh"
if [[ -f $SETCLOCK ]]; then
  bash "$SETCLOCK" 3600 >/dev/null 2>&1 || true
  trap 'rm -f "$OUT" "$ROOT/php-build-probe.php"; bash "$SETCLOCK" restore >/dev/null 2>&1 || true' EXIT
fi

for (( r = 1; r <= ROUNDS; r++ )); do
  if (( r % 2 )); then order=("${ARMS[@]}"); else
    order=()
    for (( i = ${#ARMS[@]} - 1; i >= 0; i-- )); do order+=("${ARMS[$i]}"); done
  fi
  for arm in "${order[@]}"; do
    "$HERE/switch-php-arm.sh" "$arm" >/dev/null
    # An unlisted cookie bypasses the guest cache; the probe must reach PHP.
    for _ in 1 2 3; do
      curl -sk -o /dev/null -H 'Cookie: probe=1' "$URL" || true
    done
    for _ in 1 2; do
      body=$(curl -sk -H 'Cookie: probe=1' "$URL")
    done
    wrk -t4 -c"$CONNS" -d"${SECS}s" -H 'Cookie: probe=1' -H 'Accept-Encoding: gzip' \
      "$URL" >/dev/null 2>&1
    body=$(curl -sk -H 'Cookie: probe=1' "$URL")
    rps=$(wrk -t4 -c"$CONNS" -d"${SECS}s" -H 'Cookie: probe=1' -H 'Accept-Encoding: gzip' \
      --latency "$URL" 2>/dev/null | awk '/^Requests\/sec/{printf "%d", $2}')
    printf '%s\t%s\t%s\t%s\n' "$arm" "$r" "$rps" "$body" >> "$OUT"
  done
done

echo "| probe section (ms/request) | arm | median | spread | req/s | jit |"
echo "|---|---|---:|---|---:|---:|"
awk -F'\t' '
  {
    arm = $1; rps = $3 + 0
    n[arm]++; rpsv[arm, n[arm]] = rps
    line = $4
    gsub(/[{}"]/, "", line)
    c = split(line, kv, ",")
    for (i = 1; i <= c; i++) {
      split(kv[i], p, ":")
      if (p[1] == "cfuncs" || p[1] == "oop" || p[1] == "loops") {
        key = p[1] SUBSEP arm
        m[key]++; val[key, m[key]] = p[2] + 0
      }
      if (p[1] == "jit") jitv[arm] = p[2] + 0
    }
  }
  END {
    split("cfuncs oop loops", secs, " ")
    for (s = 1; s <= 3; s++) {
      for (a in n) {
        key = secs[s] SUBSEP a
        c = m[key]
        for (j = 2; j <= c; j++) {
          v = val[key, j]; k = j - 1
          while (k >= 1 && val[key, k] > v) { val[key, k+1] = val[key, k]; k-- }
          val[key, k+1] = v
        }
        med = (c % 2) ? val[key, (c+1)/2] : (val[key, c/2] + val[key, c/2+1]) / 2
        # median requests/s for the same arm
        for (j = 2; j <= n[a]; j++) {
          v = rpsv[a, j]; k = j - 1
          while (k >= 1 && rpsv[a, k] > v) { rpsv[a, k+1] = rpsv[a, k]; k-- }
          rpsv[a, k+1] = v
        }
        rmed = (n[a] % 2) ? rpsv[a, (n[a]+1)/2] : (rpsv[a, n[a]/2] + rpsv[a, n[a]/2+1]) / 2
        printf "| %s | %s | %.2f | %.2f-%.2f | %d | %d |\n", secs[s], a, med, val[key, 1], val[key, c], rmed, jitv[a]
      }
    }
  }' "$OUT" | sort -t'|' -k2,2 -k3,3
