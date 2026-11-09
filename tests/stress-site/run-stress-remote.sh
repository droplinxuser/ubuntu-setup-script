#!/usr/bin/env bash
# Remote load test driven from a workstation (macOS bash 3.2 compatible).
# Uses oha (a single static binary) so nothing has to be installed; the server
# is left untouched.  Pair it with collect-metrics.sh on the server to see
# where the stack saturates.
#
# Usage:
#   OHA=.tools/oha bash tests/stress-site/run-stress-remote.sh TARGET_IP DOMAIN [report.md] [scenario ...]
#   e.g. bash tests/stress-site/run-stress-remote.sh 192.0.2.10 stress.invalid /tmp/remote.md
# Scenarios (default: all): static php-hello mariadb valkey elastic node full-uncached full-cached slow
#   xf-guest xf-guest-uncached xf-member xf-member-thread wp-guest wp-guest-uncached wp-member wp-member-post
# Env: CONNS (default 200; the uncached/member scenarios use CONNS/2), DURATION (default 15s), SCHEME (https),
#      XF_COOKIE / WP_COOKIE (member cookies for the member scenarios), XF_PATH (/), XF_THREAD (a thread URL),
#      WP_PATH (/), WP_POST (a post URL), OHA (path to the oha binary; downloaded to .tools/ when missing).
#      The *-uncached scenarios send a cookie that bypasses the guest cache without being a login.
set -u

TARGET=${1:?target ip}
DOMAIN=${2:?domain}
REPORT=${3:-/tmp/stress-remote-$(date +%Y%m%d-%H%M%S).md}
shift 3 2>/dev/null || shift $#
SCENARIOS=${*:-}
CONNS=${CONNS:-200}
DURATION=${DURATION:-15s}
SCHEME=${SCHEME:-https}
XF_DOMAIN=${XF_DOMAIN:-$DOMAIN}
WP_DOMAIN=${WP_DOMAIN:-$DOMAIN}
XF_PATH=${XF_PATH:-/}
WP_PATH=${WP_PATH:-/}
XF_COOKIE=${XF_COOKIE:-}
WP_COOKIE=${WP_COOKIE:-}
XF_THREAD=${XF_THREAD:-}
WP_POST=${WP_POST:-}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
OHA=${OHA:-$ROOT/.tools/oha}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stress-remote.XXXXXX")

if [[ ! -x $OHA ]]; then
  # Zero-install: fetch the static oha release for this workstation.
  os=$(uname -s); arch=$(uname -m)
  case "$os-$arch" in
    Darwin-arm64)  asset=oha-aarch64-apple-darwin ;;
    Darwin-x86_64) asset=oha-x86_64-apple-darwin ;;
    Linux-x86_64)  asset=oha-x86_64-unknown-linux-musl ;;
    Linux-aarch64) asset=oha-aarch64-unknown-linux-musl ;;
    *) echo "no oha build for $os-$arch; set OHA=" >&2; exit 1 ;;
  esac
  mkdir -p "$(dirname "$OHA")"
  curl -fsSL -o "$OHA" "https://github.com/hatoo/oha/releases/latest/download/${asset}" || { echo "oha download failed" >&2; exit 1; }
  chmod +x "$OHA"
fi
command -v jq >/dev/null || { echo "jq is required to parse oha output" >&2; exit 1; }

port=443; [[ $SCHEME == http ]] && port=80
connect_args() { printf -- '--connect-to\n%s:%s:%s:%s\n' "$1" "$port" "$TARGET" "$port"; }

run_one() {
  # run_one NAME HOST PATH CONNS [extra oha args...]
  local name=$1 host=$2 path=$3 conns=$4; shift 4
  local url="${SCHEME}://${host}${path}" out="$TMP/${name}.json"
  printf '  %-16s %s c=%s %s\n' "$name" "$url" "$conns" "$DURATION" >&2
  # shellcheck disable=SC2046
  "$OHA" --no-tui --insecure --output-format json -z "$DURATION" -c "$conns" \
    $(connect_args "$host") --disable-color "$@" "$url" > "$out" 2>"$TMP/${name}.err" || {
    printf '| %s | error | | | | | %s |\n' "$name" "$(head -c 120 "$TMP/${name}.err" | tr '\n|' '  ')" >> "$TMP/table.md"
    return 0
  }
  jq -r --arg n "$name" '
    def ms: (. * 1000 | . * 100 | round / 100);
    "| \($n) | \(.summary.requestsPerSec | round) | \(.latencyPercentiles.p50 | ms) | \(.latencyPercentiles.p90 | ms) | \(.latencyPercentiles.p99 | ms) | \(.latencyPercentiles.p99_9 // .latencyPercentiles["p99.9"] // 0 | ms) | \((.statusCodeDistribution | to_entries | map("\(.key)=\(.value)") | join(" "))) \((.errorDistribution // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")) |"
  ' "$out" >> "$TMP/table.md"
}

{
  echo "# Remote stress report (${DOMAIN} via ${TARGET})"
  echo
  echo "- Generated: $(date '+%Y-%m-%dT%H:%M:%S%z') from $(hostname) ($(uname -sm))"
  echo "- Tool: $("$OHA" --version 2>/dev/null | head -1), ${CONNS} connections, ${DURATION} per scenario, ${SCHEME}, keep-alive"
  echo
  echo "## Results"
  echo
  echo "| Scenario | req/s | p50 ms | p90 ms | p99 ms | p99.9 ms | status / errors |"
  echo "|---|---:|---:|---:|---:|---:|---|"
} > "$REPORT"
: > "$TMP/table.md"

want() { [[ -z $SCENARIOS || " $SCENARIOS " == *" $1 "* ]]; }

want static        && run_one static        "$DOMAIN" /static.html "$CONNS"
want php-hello     && run_one php-hello     "$DOMAIN" /hello.php   "$CONNS"
want mariadb       && run_one mariadb-json  "$DOMAIN" /db.php      "$CONNS"
want valkey        && run_one valkey-json   "$DOMAIN" /cache.php   "$CONNS"
want elastic       && run_one elasticsearch "$DOMAIN" /search.php  "$(( CONNS / 2 > 0 ? CONNS / 2 : 1 ))"
want node          && run_one node-proxy    "$DOMAIN" /node/       "$CONNS"
want full-uncached && run_one full-uncached "$DOMAIN" /            "$CONNS"
want full-cached   && run_one full-cached   "$DOMAIN" /cached.php  "$CONNS"
want slow          && run_one slow-1s       "$DOMAIN" "/slow.php?ms=1000" "$CONNS"
half=$(( CONNS / 2 > 0 ? CONNS / 2 : 1 ))
want xf-guest      && run_one xf-guest      "$XF_DOMAIN" "$XF_PATH" "$CONNS"
want xf-guest-uncached && run_one xf-guest-uncached "$XF_DOMAIN" "$XF_PATH" "$half" -H "Cookie: xf_session=bench"
if want xf-member && [[ -n $XF_COOKIE ]]; then
  run_one xf-member "$XF_DOMAIN" "$XF_PATH" "$half" -H "Cookie: ${XF_COOKIE}"
fi
if want xf-member-thread && [[ -n $XF_COOKIE && -n $XF_THREAD ]]; then
  run_one xf-member-thread "$XF_DOMAIN" "$XF_THREAD" "$half" -H "Cookie: ${XF_COOKIE}"
fi
want wp-guest      && run_one wp-guest      "$WP_DOMAIN" "$WP_PATH" "$CONNS"
want wp-guest-uncached && run_one wp-guest-uncached "$WP_DOMAIN" "$WP_PATH" "$half" -H "Cookie: comment_author_bench=1"
if want wp-member && [[ -n $WP_COOKIE ]]; then
  run_one wp-member "$WP_DOMAIN" "$WP_PATH" "$half" -H "Cookie: ${WP_COOKIE}"
fi
if want wp-member-post && [[ -n $WP_COOKIE && -n $WP_POST ]]; then
  run_one wp-member-post "$WP_DOMAIN" "$WP_POST" "$half" -H "Cookie: ${WP_COOKIE}"
fi

cat "$TMP/table.md" >> "$REPORT"
{
  echo
  echo "## Notes"
  echo
  echo "- Latency includes the LAN/WAN round trip from the workstation; compare scenarios"
  echo "  against each other and against the server-side collect-metrics.sh samples."
  echo "- Raw oha JSON per scenario: ${TMP}"
} >> "$REPORT"
echo "Report written to ${REPORT}" >&2
grep -E '^\|' "$REPORT" >&2 || true
