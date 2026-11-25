#!/usr/bin/env bash
# Loopback load tiers on the audit host (wrk, HTTPS/1.1 keep-alive) with per-service CPU
# attribution from the systemd cgroups.  Usage: tiers.sh [CONNS] [SECS] [filter-regex]
# Environment:
#   WRK_T=N        wrk threads (default 4)
#   WARM_N=N       warm each URL with N sequential requests instead of 2 s of wrk
#   TIERS_FILE=F   tiers from F instead of the built-in WP/XF/Chevereto list, one
#                  per line: label|url|cookie|marker|cache (# comments).  url "@NAME"
#                  reads /root/audit/cookies/NAME.url; cookie is a cookies.tsv
#                  key, "=literal" (e.g. =xf_session=bench-bypass) or empty;
#                  marker, when set, must appear in the response body; cache, when
#                  set (HIT, BYPASS...), is the X-Cache-Status the gate requires
#                  with wrk's headers (a HIT tier gets one priming request first).
# Every tier of a TIERS_FILE is gated before it is measured: one request must
# answer 200 (and show the marker and the cache state), else the row reports
# GATE in the non-2xx column and is not measured.  A built-in tier whose URL
# file is missing (a host without WordPress or Chevereto) is skipped.
set -u
C=${1:-100}; S=${2:-10}; F=${3:-.}; T=${WRK_T:-4}
R=/root/work/ubuntu-setup-script/tests/stress-site
J=/root/audit/cookies
CK=$J/cookies.tsv
ck() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$CK"; }
[[ -s $CK ]] || { echo "missing $CK: run exercise-apps.sh keep (or seed-xf.sh) first" >&2; exit 1; }
one() { # label url cookie [marker] [cache]
  local label=$1 url=$2 key=${3:-} mark=${4:-} want=${5:-} out cpu cookie="" got
  [[ $label =~ $F ]] || return 0
  [[ -n $url ]] || return 0
  local -a h=(-H 'Accept-Encoding: gzip, br' -H 'User-Agent: setup-bench/1.0')
  case $key in
    "") ;;
    =*) cookie=${key#=} ;;
    *)  cookie=$(ck "$key")
        [[ -n $cookie ]] || { printf '| %s | 0 | ? | ? | GATE no cookie %s |  |\n' "$label" "$key"; return 0; } ;;
  esac
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  if [[ -n ${TIERS_FILE:-} ]]; then
    # curl picks an encoding it can decode (h[0..3]: wrk's Accept-Encoding and
    # User-Agent; the cookie, if any, follows).
    got=$(curl -sk --compressed --max-time 20 -A setup-bench/1.0 "${h[@]:4}" -w '\n%{http_code}' "$url" 2>/dev/null)
    if [[ ${got##*$'\n'} != 200 ]] || [[ -n $mark && $got != *"$mark"* ]]; then
      printf '| %s | 0 | ? | ? | GATE http=%s%s |  |\n' "$label" "${got##*$'\n'}" "${mark:+ marker=$([[ $got == *"$mark"* ]] && echo ok || echo missing)}"
      return 0
    fi
    if [[ -n $want ]]; then
      # The cache state, with wrk's own headers (Accept-Encoding is in the
      # cache key): a HIT tier is primed once first.
      [[ $want == HIT ]] && curl -sk -o /dev/null --max-time 20 "${h[@]}" "$url" >/dev/null 2>&1
      got=$(curl -sk -o /dev/null -D - --max-time 20 "${h[@]}" "$url" 2>/dev/null \
        | awk -F': *' 'tolower($1) == "x-cache-status" { sub(/\r$/, "", $2); print $2 }')
      [[ $got == "$want" ]] || { printf '| %s | 0 | ? | ? | GATE cache=%s want=%s |  |\n' "$label" "${got:-none}" "$want"; return 0; }
    fi
  fi
  if [[ -n ${WARM_N:-} ]]; then
    # One curl, one keep-alive connection: the headers once, then N URLs.
    local hdr i
    { for hdr in "${h[@]}"; do [[ $hdr == -H ]] || printf 'header = "%s"\n' "${hdr//\"/\\\"}"; done
      for (( i = 0; i < WARM_N; i++ )); do printf 'url = "%s"\noutput = "/dev/null"\n' "$url"; done
    } | curl -sk --max-time 300 -K - >/dev/null 2>&1
  else
    wrk -t"$T" -c"$C" -d2s "${h[@]}" "$url" >/dev/null 2>&1
  fi
  bash $R/sample-cpu.sh $(( S + 1 )) /tmp/tier-cpu.txt >/dev/null 2>&1 &
  ( sleep $(( S / 2 )); awk '/MHz/ { s += $4; n++ } END { if (n) printf "%d", s / n }' /proc/cpuinfo > /tmp/tier-mhz.txt ) &
  out=$(wrk -t"$T" -c"$C" -d"${S}s" --latency "${h[@]}" "$url" 2>&1)
  wait
  local rps p50 p99 non2 total errs
  rps=$(awk '/^Requests\/sec/{printf "%d", $2}' <<<"$out")
  p50=$(awk '$1=="50%"{print $2}' <<<"$out"); p99=$(awk '$1=="99%"{print $2}' <<<"$out")
  total=$(awk '/requests in/{print $1}' <<<"$out")
  non2=$(awk '/Non-2xx/{print $NF}' <<<"$out"); errs=$(awk '/Socket errors/{print $0}' <<<"$out" | tr -s ' ')
  # Compact per-service CPU (ms per request) plus host cores and the mean
  # CPU clock: the E-2236 test host drops from 4.5 to 4.1 GHz once its
  # PL2 turbo window expires, which moves PHP CPU per request by ~10 % and
  # must be visible next to every number (pin scaling_max_freq for A/B runs).
  cpu=$(python3 $R/analyze-cpu.py /tmp/tier-cpu.txt "${total:-1}" 2>/dev/null \
    | awk '/ms\/req/ && $(NF-1) + 0 >= 0.01 { printf "%s=%s ", $1, $(NF-1) } /^host/ { sub(/^avg=/, "", $(NF-1)); printf "cores=%s ", $(NF-1) }')
  cpu+="mhz=$(cat /tmp/tier-mhz.txt 2>/dev/null)"
  printf '| %s | %s | %s | %s | %s%s | %s |\n' "$label" "${rps:-0}" "${p50:-?}" "${p99:-?}" "${non2:-0}" "${errs:+ $errs}" "$cpu"
}
echo "| Tier (c=$C, ${S}s) | req/s | p50 | p99 | non-2xx | server CPU |"
echo "|---|---:|---:|---:|---:|---|"
if [[ -n ${TIERS_FILE:-} ]]; then
  [[ -s $TIERS_FILE ]] || { echo "missing $TIERS_FILE" >&2; exit 1; }
  while IFS="|" read -r label url key mark want; do
    [[ -z $label || $label == \#* ]] && continue
    [[ $url == @* ]] && url=$(cat "$J/${url#@}.url" 2>/dev/null)
    one "$label" "$url" "$key" "$mark" "$want"
  done < "$TIERS_FILE"
  exit 0
fi
WPP=$(cat $J/wp-post.url 2>/dev/null); XFT=$(cat $J/xf-thread.url 2>/dev/null)
CHI=$(cat $J/ch-image.url 2>/dev/null || echo https://chev.test.local/explore/recent)
# An application without its cookie row is not on this host: skip its tiers.
WP=""; [[ -n $(ck wp-bench1) ]] && WP=https://wp.test.local/
CH=""; [[ -n $(ck ch-admin) ]] && CH=https://chev.test.local
[[ -n $WP ]] || WPP=""
one "WP guest home (cached)"      "$WP"
one "WP guest post (cached)"      "$WPP"
one "WP member home"              "$WP" wp-bench1
one "WP member post"              "$WPP" wp-bench1
one "XF guest home (cached)"      https://xf.test.local/
one "XF guest thread (cached)"    "$XFT"
one "XF member home"              https://xf.test.local/ xf-member
one "XF member thread"            "$XFT" xf-member
one "Chev guest explore (cached)" "${CH:+$CH/explore}"
one "Chev guest image (cached)"   "${CH:+$CHI}"
one "Chev guest home (uncached)"  "${CH:+$CH/}"
# Trailing slash: Chevereto answers /explore with a 301 to /explore/, which
# wrk counted as 0 req/s for this tier (the cached guest tier above is the
# canonical cache key and keeps the original URL).
one "Chev member explore"         "${CH:+$CH/explore/}" ch-admin
