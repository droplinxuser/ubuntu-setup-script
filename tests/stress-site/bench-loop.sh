#!/usr/bin/env bash
# Loopback throughput tiers on the audit host with per-service CPU attribution.
# Usage: bench-loop.sh [CONNS] [SECS] [filter]
set -u
C=${1:-100}; S=${2:-8}; F=${3:-.}
OHA=/root/work/tools/oha
CK=/root/audit/cookies/cookies.tsv
HOST=127.0.0.1
[[ -s $CK ]] || { echo "missing $CK" >&2; exit 1; }
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$CK"; }
WPP=$(cat /root/audit/cookies/wp-post.url)
XFT=$(cat /root/audit/cookies/xf-thread.url)
CHI=$(cat /root/audit/cookies/ch-image.url 2>/dev/null || echo https://chev.test.local/explore/recent)

cpu_ticks() { # $1 = comm regex
  awk -v re="$1" '$2 ~ re { s += $14 + $15 } END { print s + 0 }' /proc/[0-9]*/stat 2>/dev/null
}

one() { # label url cookiekey
  local label=$1 url=$2 key=${3:-} host out rps p50 p99 non2 args
  [[ $label =~ $F ]] || return 0
  host=$(printf '%s' "$url" | awk -F/ '{print $3}')
  args=(--no-tui --insecure --output-format json -z "${S}s" -c "$C" --connect-to "$host:443:${HOST}:443")
  args+=(-H 'Accept-Encoding: gzip, br' -H 'User-Agent: setup-bench/1.0')
  [[ -n $key ]] && args+=(-H "Cookie: $(ck "$key")")
  "$OHA" "${args[@]}" "$url" >/dev/null 2>&1 || true   # warm
  local t0 p0 a0 t1 p1 a1 tot elapsed
  t0=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  p0=$(cpu_ticks 'php-fpm'); a0=$(cpu_ticks 'angie|nginx')
  out=$("$OHA" "${args[@]}" "$url" 2>/dev/null)
  t1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  p1=$(cpu_ticks 'php-fpm'); a1=$(cpu_ticks 'angie|nginx')
  rps=$(printf '%s' "$out" | jq -r '.summary.requestsPerSec // 0' | cut -d. -f1)
  p50=$(printf '%s' "$out" | jq -r '(.latencyPercentiles.p50 // 0)*1000 | floor')
  p99=$(printf '%s' "$out" | jq -r '(.latencyPercentiles.p99 // 0)*1000 | floor')
  non2=$(printf '%s' "$out" | jq -r '[.statusCodeDistribution | to_entries[] | select(.key|startswith("2")|not) | .value] | add // 0')
  tot=$(printf '%s' "$out" | jq -r '[.statusCodeDistribution[]] | add // 0')
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", (b-a)/100}')
  local php_ms ang_core php_core
  php_core=$(awk -v a="$p0" -v b="$p1" -v e="$elapsed" 'BEGIN{printf "%.1f", (b-a)/100/e}')
  ang_core=$(awk -v a="$a0" -v b="$a1" -v e="$elapsed" 'BEGIN{printf "%.1f", (b-a)/100/e}')
  php_ms=$(awk -v c="$php_core" -v r="$rps" 'BEGIN{if(r>0) printf "%.2f", c*1000/r; else print "?"}')
  printf '| %s | %s | %s | %s | %s/%s | %s | %s |\n' "$label" "${rps:-0}" "${p50:-?}" "${p99:-?}" "${non2:-0}" "$tot" "$php_ms" "$ang_core"
}

echo "| Tier (c=$C, ${S}s, loopback) | req/s | p50 ms | p99 ms | non-2xx/total | php ms/req | angie cores |"
echo "|---|---:|---:|---:|---:|---:|---:|"
one "WP guest home (cached)"      https://wp.test.local/
one "WP guest post (cached)"      "$WPP"
one "WP member home"              https://wp.test.local/ wp-bench1
one "WP member post"              "$WPP" wp-bench1
one "XF guest home (cached)"      https://xf.test.local/
one "XF guest thread (cached)"    "$XFT"
one "XF member home"              https://xf.test.local/ xf-member
one "XF member thread"            "$XFT" xf-member
one "Chev guest explore (cached)" https://chev.test.local/explore
one "Chev guest image (cached)"   "$CHI"
one "Chev guest home (uncached)"  https://chev.test.local/
one "Chev member explore"         https://chev.test.local/explore ch-admin
