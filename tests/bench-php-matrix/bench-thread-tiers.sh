#!/usr/bin/env bash
# Measure the five tiers of the published XenForo 2.3.13 web-stack benchmark
# (xenforo.com thread 241386 and its Ubuntu-vs-CentMinMod follow-up) on the
# current host configuration, with the same method:
#
#   loopback HTTPS against xf.test.local, wrk -t4 -c100 -d10s, 2 s warm-up,
#   Accept-Encoding: gzip, member = fresh XenForo session cookie,
#   member thread = the median 9-post thread.
#   Behind Anubis (ANUBIS=1) wrk 4.1.0 under-reads Go-proxy bodies, so the
#   tiers are measured with oha (same connections/duration) instead.
#
# Usage: LABEL=baseline [TIERS="cached bypass home thread"] [RUNS=1] \
#          bench-thread-tiers.sh >> results.tsv
# Prints one TSV line per tier: label tier rps p50 p99 non2xx.
# Needs /root/audit/bench-env.sh (XF_COOKIE) from seed-xf.sh.
set -Eeuo pipefail
export LC_ALL=C.UTF-8

LABEL=${LABEL:-run}
TIERS=${TIERS:-"cached bypass home thread"}
RUNS=${RUNS:-1}
CONNS=${CONNS:-100}
SECS=${SECS:-10}
THREADS=${THREADS:-4}
ANUBIS=${ANUBIS:-0}
OHA=${OHA:-/root/work/oha}
HOST=xf.test.local
ENVF=/root/audit/bench-env.sh
THREAD_URL_FILE=/root/audit/thread9.url

[[ -f $ENVF ]] || { echo "missing $ENVF (run seed-xf.sh first)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENVF"

# The median-length thread: 9 posts (the published thread tier).  Picked once
# and kept so every run measures the same page.
if [[ ! -s $THREAD_URL_FILE ]]; then
  tid=$(mariadb -N -e "SELECT thread_id FROM xenforo.xf_thread
         WHERE discussion_state='visible' AND reply_count=8
         ORDER BY thread_id LIMIT 1")
  [[ -n $tid ]] || { echo "no 9-post thread found" >&2; exit 1; }
  # Friendly URLs redirect /threads/ID/ to /threads/<slug>.ID/; measure the
  # canonical page, not a 301.
  canon=$(curl -sk -o /dev/null -w '%{redirect_url}' --resolve "${HOST}:443:127.0.0.1" \
            -H "Cookie: $XF_COOKIE" "https://${HOST}/threads/${tid}/")
  canon=${canon#https://"${HOST}"}
  [[ $canon == /threads/* ]] || canon="/threads/${tid}/"
  printf '%s\n' "$canon" > "$THREAD_URL_FILE"
fi
THREAD_URL=$(cat "$THREAD_URL_FILE")

wrk_tier() { # url cookie -> "rps p50 p99 non2xx"
  local url=$1 cookie=${2:-} out
  local -a h=(-H 'Accept-Encoding: gzip' -H 'User-Agent: setup-bench/1.0')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  wrk -t"$THREADS" -c"$CONNS" -d2s "${h[@]}" "$url" >/dev/null 2>&1 || true
  out=$(wrk -t"$THREADS" -c"$CONNS" -d"${SECS}s" --latency "${h[@]}" "$url" 2>&1) || true
  awk '/^Requests\/sec/{r=$2} $1=="50%"{p=$2} $1=="99%"{q=$2} /Non-2xx/{n=$NF}
       END{printf "%d\t%s\t%s\t%d\n", r, p, q, n}' <<<"$out"
}

oha_tier() { # url cookie -> "rps p50 p99 non2xx"
  local url=$1 cookie=${2:-} out
  local -a h=(-H 'Accept-Encoding: gzip' -H 'User-Agent: setup-bench/1.0')
  [[ -n $cookie ]] && h+=(-H "Cookie: $cookie")
  "$OHA" -c "$CONNS" -z 2s --no-tui --insecure "${h[@]}" "$url" >/dev/null 2>&1 || true
  out=$("$OHA" -c "$CONNS" -z "${SECS}s" --no-tui --insecure --output-format json "${h[@]}" "$url" 2>/dev/null) || true
  perl -MJSON::PP -e '
    my $j = decode_json(join "", <STDIN>);
    my $s = $j->{statusCodeDistribution} || {};
    my $non = 0; for (keys %$s) { $non += $s->{$_} unless /^2/ }
    printf "%d\t%.2fms\t%.2fms\t%d\n", $j->{summary}{requestsPerSec},
      1000 * $j->{latencyPercentiles}{p50}, 1000 * $j->{latencyPercentiles}{p99}, $non;
  ' <<<"$out"
}

one() {
  if (( ANUBIS )); then oha_tier "$@"; else wrk_tier "$@"; fi
}

for _ in $(seq 1 "$RUNS"); do
  for t in $TIERS; do
    case $t in
      cached) r=$(one "https://${HOST}/" "") ;;
      bypass) r=$(one "https://${HOST}/" "xf_session=bench-bypass") ;;
      home)   r=$(one "https://${HOST}/" "$XF_COOKIE") ;;
      thread) r=$(one "https://${HOST}${THREAD_URL}" "$XF_COOKIE") ;;
      *) echo "unknown tier $t" >&2; continue ;;
    esac
    printf '%s\t%s\t%s\n' "$LABEL" "$t" "$r"
  done
done
