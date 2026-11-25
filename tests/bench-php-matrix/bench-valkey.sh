#!/usr/bin/env bash
# valkey-benchmark A/B of Valkey binaries, arm order rotated every round.
#
# Usage: bench-valkey.sh ROUNDS ARM [ARM...]     (arms: see switch-valkey-arm.sh)
#
# One client binary for every arm (the package's valkey-benchmark), over the
# unix socket the applications use, in database 9 (flushed afterwards) so the
# applications' cache databases are left alone.  Each round runs, per arm:
# GET/SET/HSET/LPUSH/MSET at 50 connections without pipelining (the shape of
# PHP's cache calls) and GET/SET pipelined 16 deep.  Prints the median req/s
# per test and arm, and the delta against the first arm.  Pin the clock first
# (tests/stress-site/set-clock.sh 3600): turbo budgets fake a first-slot win.
set -Eeuo pipefail
export LC_ALL=C
HERE=$(dirname "$(readlink -f "$0")")
ROUNDS=${1:?usage: bench-valkey.sh ROUNDS ARM [ARM...]}; shift
ARMS=("$@"); (( ${#ARMS[@]} >= 1 )) || { echo "no arms" >&2; exit 1; }
SOCK=/run/valkey/valkey.sock
CLIENT=${CLIENT:-/usr/bin/valkey-benchmark}
N=${N:-1000000}
RAW=${RAW:-/root/audit/valkey-bench.tsv}
: > "$RAW"

run_arm() { # arm round
  local arm=$1 r=$2 line
  bash "$HERE/switch-valkey-arm.sh" "$arm" >/dev/null
  sleep 1
  while IFS=, read -r test rps _; do
    test=${test//\"/}; rps=${rps//\"/}
    [[ $rps =~ ^[0-9.]+$ ]] || continue
    printf '%s\t%s\tP1 %s\t%s\n' "$r" "$arm" "$test" "$rps" >> "$RAW"
  done < <("$CLIENT" -s "$SOCK" --dbnum 9 -c 50 -n "$N" -r 100000 -d 256 -t get,set,hset,lpush,mset --csv -q 2>/dev/null)
  while IFS=, read -r test rps _; do
    test=${test//\"/}; rps=${rps//\"/}
    [[ $rps =~ ^[0-9.]+$ ]] || continue
    printf '%s\t%s\tP16 %s\t%s\n' "$r" "$arm" "$test" "$rps" >> "$RAW"
  done < <("$CLIENT" -s "$SOCK" --dbnum 9 -c 50 -n "$(( N * 4 ))" -r 100000 -d 256 -P 16 -t get,set --csv -q 2>/dev/null)
  line=$(valkey-cli -s "$SOCK" -n 9 flushdb 2>/dev/null || true)
  : "$line"
}

for (( r = 0; r < ROUNDS; r++ )); do
  for (( i = 0; i < ${#ARMS[@]}; i++ )); do
    run_arm "${ARMS[$(( (i + r) % ${#ARMS[@]} ))]}" "$r"
  done
done
bash "$HERE/switch-valkey-arm.sh" "${ARMS[0]}" >/dev/null

# Median per (test, arm); delta against the first arm.
awk -F'\t' -v first="${ARMS[0]}" -v arms="${ARMS[*]}" '
  { k = $3 SUBSEP $2; v[k] = v[k] " " $4; tests[$3] = 1 }
  function median(s,   a, n, i, j, t) { n = split(s, a, " ")
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
    return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
  END {
    na = split(arms, A, " ")
    printf "%-14s", "test"; for (i = 1; i <= na; i++) printf " %16s", A[i]; printf "\n"
    for (t in tests) {
      printf "%-14s", t; base = median(v[t SUBSEP first])
      for (i = 1; i <= na; i++) { m = median(v[t SUBSEP A[i]])
        if (i == 1) printf " %16.0f", m; else printf " %9.0f %+5.1f%%", m, (m / base - 1) * 100 }
      printf "\n"
    }
  }' "$RAW" | sort
