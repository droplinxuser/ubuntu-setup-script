#!/usr/bin/env bash
# Loopback load tiers on the audit host (wrk, HTTPS/1.1 keep-alive) with per-service CPU
# attribution from the systemd cgroups.  Usage: tiers.sh [CONNS] [SECS] [filter-regex]
set -u
C=${1:-100}; S=${2:-10}; F=${3:-.}
R=/root/work/ubuntu-setup-script/tests/stress-site
CK=/root/audit/cookies/cookies.tsv
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' $CK; }
WPP=$(cat /root/audit/cookies/wp-post.url); XFT=$(cat /root/audit/cookies/xf-thread.url)
CHI=$(cat /root/audit/cookies/ch-image.url 2>/dev/null || echo https://chev.test.local/explore/recent)
one() { # label url cookiekey
  local label=$1 url=$2 key=${3:-} out cpu
  [[ $label =~ $F ]] || return 0
  local -a h=(-H 'Accept-Encoding: gzip, br')
  [[ -n $key ]] && h+=(-H "Cookie: $(ck "$key")")
  wrk -t4 -c"$C" -d2s "${h[@]}" "$url" >/dev/null 2>&1
  bash $R/sample-cpu.sh $(( S + 1 )) /tmp/tier-cpu.txt >/dev/null 2>&1 &
  out=$(wrk -t4 -c"$C" -d"${S}s" --latency "${h[@]}" "$url" 2>&1)
  wait
  local rps p50 p99 non2 total errs
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out"); p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  total=$(awk '/requests in/{print $1}' <<<"$out")
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out"); errs=$(awk '/Socket errors/{print $0}' <<<"$out" | tr -s ' ')
  cpu=$(python3 $R/analyze-cpu.py /tmp/tier-cpu.txt "${total:-1}" 2>/dev/null | tr '\n' ';' | cut -c1-230)
  printf '| %s | %s | %s | %s | %s%s | %s |\n' "$label" "${rps:-0}" "${p50:-?}" "${p99:-?}" "${non2:-0}" "${errs:+ $errs}" "$cpu"
}
echo "| Tier (c=$C, ${S}s) | req/s | p50 | p99 | non-2xx | server CPU |"
echo "|---|---:|---:|---:|---:|---|"
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
