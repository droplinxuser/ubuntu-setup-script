#!/usr/bin/env bash
# One measured request tier against the audit host, with server-side CPU
# attribution. Run from the macOS workstation.
#
# Usage: bench-one.sh LABEL URL COOKIE CONNS SECONDS [extra oha args...]
#   COOKIE may be empty; pass "-" to skip.
# Env: TARGET (default 192.0.2.10), SSH_USER (rt), REMOTE_DIR (the checkout
#      on the host), OHA (load generator), SSH_OPTS (extra ssh flags).
set -u
LABEL=${1:?label}
URL=${2:?url}
COOKIE=${3:-}
CONNS=${4:-100}
SECS=${5:-8}
shift 5 2>/dev/null || shift $#
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OHA=${OHA:-$ROOT/.tools/oha}
TARGET=${TARGET:-192.0.2.10}
SSH_USER=${SSH_USER:-rt}
REMOTE_DIR=${REMOTE_DIR:-/home/rt/work/ubuntu-setup-script}
SSH_OPTS=${SSH_OPTS:-}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bench-one.XXXXXX")
HOSTPORT=${TARGET}:443

rssh() { ssh $SSH_OPTS "${SSH_USER}@${TARGET}" "$@"; }

args=()
[[ -n $COOKIE && $COOKIE != - ]] && args+=(-H "Cookie: $COOKIE")
host=$(printf '%s' "$URL" | awk -F/ '{print $3}')
warm=$(( SECS > 4 ? 3 : 1 ))
"$OHA" --no-tui --insecure --output-format json -z "${warm}s" -c "$CONNS" \
  --connect-to "$host:443:$HOSTPORT" ${args[@]+"${args[@]}"} "$URL" >/dev/null 2>&1 || true

rssh "sudo -n bash ${REMOTE_DIR}/tests/stress-site/sample-cpu.sh $(( SECS + 3 )) /tmp/bench-cpu.txt >/dev/null 2>&1" >/dev/null 2>&1 &
sampler=$!
sleep 1
"$OHA" --no-tui --insecure --output-format json -z "${SECS}s" -c "$CONNS" \
  --connect-to "$host:443:$HOSTPORT" ${args[@]+"${args[@]}"} "$@" "$URL" > "$TMP/out.json" 2>"$TMP/err"
wait "$sampler" 2>/dev/null || true
total=$(jq -r '[.statusCodeDistribution[]] | add' "$TMP/out.json" 2>/dev/null || echo 0)
rps=$(jq -r '.summary.requestsPerSec | round' "$TMP/out.json" 2>/dev/null || echo 0)
p50=$(jq -r '.latencyPercentiles.p50 * 1000 * 100 | round / 100 | tostring' "$TMP/out.json" 2>/dev/null || echo 0)
p99=$(jq -r '.latencyPercentiles.p99 * 1000 * 100 | round / 100 | tostring' "$TMP/out.json" 2>/dev/null || echo 0)
status=$(jq -r '.statusCodeDistribution | to_entries | map("\(.key)=\(.value)") | join(" ")' "$TMP/out.json" 2>/dev/null || echo "?")
cpu=$(rssh "python3 ${REMOTE_DIR}/tests/stress-site/analyze-cpu.py /tmp/bench-cpu.txt $total 2>/dev/null" 2>/dev/null || true)
printf '| %s | %s | %s | %s | %s | %s |\n' "$LABEL" "$rps" "$p50" "$p99" "$status" "$(printf '%s' "$cpu" | tr '\n' '; ' | cut -c1-400)"
