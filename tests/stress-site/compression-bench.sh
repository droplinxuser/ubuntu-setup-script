#!/usr/bin/env bash
# Compression benchmark for one URL and one or more Accept-Encoding values.
#
# For each encoding: the encoding the server chose, body and header bytes on
# the wire, unloaded time to first byte (median and spread of N requests on one
# keep-alive connection), then a loopback wrk run with the exact CPU each
# service used, read from its systemd cgroup (cpu.stat usage_usec) before and
# after the run, divided by the requests wrk completed.  Load runs are
# interleaved round-robin across the encodings (see pass 2).
#
# Usage: compression-bench.sh LABEL URL [COOKIE_KEY] [ENCODINGS...]
#   ENCODINGS default: "gzip" "br" "zstd" "gzip, deflate, br, zstd" "identity"
# Environment: C (connections, 100), D (seconds, 10), RUNS (wrk runs, 3),
#   TTFB_N (requests for the TTFB median, 25), CK (cookie file).
# Output: one Markdown row per encoding with the median req/s of RUNS runs and
# the min-max spread, p50/p99 of the median run, and CPU ms per request.
set -u
LABEL=${1:?label}; URL=${2:?url}; KEY=${3:-}; shift 3 2>/dev/null || shift $#
C=${C:-100}; D=${D:-10}; RUNS=${RUNS:-3}; TTFB_N=${TTFB_N:-25}
CK=${CK:-/root/audit/cookies/cookies.tsv}
printf "| Tier | Accept-Encoding | sent | body B | status | TTFB ms med (min-max) | req/s | spread | p50 | p99 | Angie ms/req | PHP ms/req |\n|---|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|\n" >&2
(( $# )) || set -- "gzip" "br" "zstd" "gzip, deflate, br, zstd" "identity"
CG=/sys/fs/cgroup/system.slice
PHPU=$(cd "$CG" 2>/dev/null && ls -d php*-fpm.service 2>/dev/null | head -1)
usec() { awk '/^usage_usec/{print $2}' "$CG/$1/cpu.stat" 2>/dev/null || echo 0; }
cookie=""
if [[ -n $KEY ]]; then
  cookie=$(awk -F'\t' -v k="$KEY" '$1 == k { print $2 }' "$CK")
  [[ -n $cookie ]] || { echo "no cookie $KEY in $CK" >&2; exit 1; }
fi
med() { sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]; else print 0}'; }

hdrs() { # hdrs AE -> fills array h
  h=(-H "Accept-Encoding: $1" -H 'User-Agent: setup-bench/1.0')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  return 0
}
declare -A ENC BODY STATUS TTFB TMIN TMAX ROWS
# Pass 1, per encoding: encoding chosen, bytes (curl does not decode without
# --compressed; the header file is read after curl has written it), and the
# unloaded TTFB of TTFB_N requests on one connection (handshake dropped).
for ae in "$@"; do
  hdrs "$ae"
  read -r b s < <(curl -sk -o /dev/null -D /tmp/cb-h.$$ "${h[@]}" \
    -w '%{size_download} %{http_code}\n' "$URL")
  BODY[$ae]=$b; STATUS[$ae]=$s
  ENC[$ae]=$(awk 'tolower($0) ~ /^content-encoding:/ { sub(/\r$/, ""); sub(/^[^:]*:[ ]*/, ""); e = $0 }
             END { print (e == "" ? "identity" : e) }' /tmp/cb-h.$$)
  rm -f /tmp/cb-h.$$
  args=()
  for (( i = 0; i <= TTFB_N; i++ )); do args+=(-o /dev/null "$URL"); done
  mapfile -t tt < <(curl -sk "${h[@]}" -w '%{time_starttransfer}\n' "${args[@]}" | tail -n +2 \
    | awk '{printf "%.3f\n", $1 * 1000}' | sort -n)
  TTFB[$ae]=$(printf '%s\n' "${tt[@]}" | med)
  TMIN[$ae]=${tt[0]}; TMAX[$ae]=${tt[-1]}
done
# Pass 2: load runs interleaved round-robin across the encodings, so CPU boost
# and thermal drift land on every encoding alike (a block of runs per
# encoding gave the first block ~20 % more on this host).
for ae in "$@"; do hdrs "$ae"; wrk -t4 -c"$C" -d2s "${h[@]}" "$URL" >/dev/null 2>&1; done
for (( r = 1; r <= RUNS; r++ )); do
  for ae in "$@"; do
    hdrs "$ae"
    a0=$(usec angie.service); p0=$(usec "$PHPU")
    out=$(wrk -t4 -c"$C" -d"${D}s" --latency "${h[@]}" "$URL" 2>&1)
    a1=$(usec angie.service); p1=$(usec "$PHPU")
    n=$(awk '/requests in/{print $1}' <<<"$out"); n=${n:-1}
    rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
    p50=$(awk '$1=="50%"{print $2}' <<<"$out"); p99=$(awk '$1=="99%"{print $2}' <<<"$out")
    non2=$(awk '/Non-2xx/{print $NF}' <<<"$out")
    am=$(awk -v d=$(( a1 - a0 )) -v n="$n" 'BEGIN{printf "%.3f", d / 1000 / n}')
    pm=$(awk -v d=$(( p1 - p0 )) -v n="$n" 'BEGIN{printf "%.3f", d / 1000 / n}')
    ROWS[$ae]+="${rps:-0} ${p50:-?} ${p99:-?} ${non2:-0} $am $pm"$'\n'
  done
done
for ae in "$@"; do
  sorted=$(printf '%s' "${ROWS[$ae]}" | sed '/^$/d' | sort -n)
  mid=$(sed -n "$(( (RUNS + 1) / 2 ))p" <<<"$sorted")
  lo=$(head -n 1 <<<"$sorted" | cut -d' ' -f1); hi=$(tail -n 1 <<<"$sorted" | cut -d' ' -f1)
  read -r rps p50 p99 non2 am pm <<<"$mid"
  spread=$(awk -v l="$lo" -v h="$hi" -v m="$rps" 'BEGIN{ if (m > 0) printf "%.1f", (h - l) * 100 / m; else print "?" }')
  printf '| %s | %s | %s | %s | %s | %s (%s-%s) | %s | %s | %s | %s | %s | %s |\n' \
    "$LABEL" "$ae" "${ENC[$ae]}" "${BODY[$ae]}" "${STATUS[$ae]}" "${TTFB[$ae]}" "${TMIN[$ae]}" "${TMAX[$ae]}" \
    "$rps" "${spread}%" "$p50" "$p99" "$am" "$pm"
  [[ $non2 != 0 ]] && echo "  (non-2xx in median run: $non2)"
done
exit 0
