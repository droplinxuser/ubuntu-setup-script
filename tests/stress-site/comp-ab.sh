#!/bin/bash
# Configuration rotation for compression A/B runs (see compression-bench.sh):
#   comp-ab.sh TAG LABEL URL COOKIEKEY ROUNDS -- "name|Accept-Encoding|set-comp args;..." ...
# Each round applies every config in turn and runs one load run per config,
# so boost/thermal drift lands on all of them alike.  Raw rows to comp-ab-TAG.md.
set -u
TAG=$1 LABEL=$2 URL=$3 KEY=$4 ROUNDS=$5; shift 6
R=${R:-/root/work/ubuntu-setup-script/tests/stress-site}; OUT=/root/audit/comp-ab-$TAG.md
echo "## $TAG $LABEL ($(date -u +%FT%TZ))" >> $OUT
for (( r = 1; r <= ROUNDS; r++ )); do
  for spec in "$@"; do
    IFS='|' read -r name ae cmds <<<"$spec"
    IFS=';' read -ra cs <<<"$cmds"
    for c in "${cs[@]}"; do [[ -n $c ]] && bash $R/set-comp.sh $c >/dev/null; done
    sleep 1
    RUNS=1 TTFB_N=${TTFB_N:-15} bash $R/compression-bench.sh "$name r$r" "$URL" "$KEY" "$ae" 2>/dev/null >> $OUT
  done
done
echo "AB_DONE $TAG" >> $OUT
