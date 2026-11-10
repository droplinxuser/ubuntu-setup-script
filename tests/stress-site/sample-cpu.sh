#!/bin/bash
# Per-service CPU sampler for load tests, read from the systemd cgroup
# accounting.  Unlike a client-side counter this is independent of the link
# between the load generator and the host, which is what the tuning decisions
# in setup.sh are based on.
#
# Usage (on the server):   sample-cpu.sh SECONDS OUTFILE
# Usage (from a client):   ssh host 'sample-cpu.sh 20 /tmp/s.txt' & ... load ...
#                          analyze-cpu.py /tmp/s.txt REQUESTS
#
# Writes "<unix-ts> <service> <jiffies>" (1 jiffy = 10 ms) plus one
# "<unix-ts> HOST <jiffies>" line per sample from /proc/stat.
set -u
DUR=${1:-20}
OUT=${2:-/tmp/sample.txt}
BASE=/sys/fs/cgroup/system.slice
# Map the unit name to the label the report uses.
declare -A unit=(
  [php-fpm]=php8.5-fpm.service
  [angie]=angie.service
  [mariadbd]=mariadb.service
  [valkey-server]=valkey-server.service
  [elastic]=elasticsearch.service
)
# A host with another PHP version installed: sample every php*-fpm unit and
# label them php-fpm.
extra_php=$(cd "$BASE" 2>/dev/null && ls -d php*-fpm.service 2>/dev/null | head -1)
[[ -n ${extra_php:-} ]] && unit[php-fpm]=$extra_php

: > "$OUT"
start=$SECONDS
while (( SECONDS - start < DUR )); do
  ts=$(date +%s.%N)
  for name in "${!unit[@]}"; do
    f="$BASE/${unit[$name]}/cpu.stat"
    [[ -r $f ]] || continue
    usec=$(awk '/^usage_usec/{print $2}' "$f")
    [[ $usec =~ ^[0-9]+$ ]] || continue
    printf '%s %s %s\n' "$ts" "$name" "$(( usec / 10000 ))" >> "$OUT"
  done
  # /proc/stat fields: user nice system idle iowait irq softirq steal ...
  # Count only busy time.  Including idle made the "host CPU used" line
  # report ~one core-second per core per second on an idle host, which hid
  # whether a run was actually CPU-bound.
  hostj=$(awk '/^cpu /{print $2+$3+$4+$7+$8+$9}' /proc/stat)
  printf '%s HOST %s\n' "$ts" "$hostj" >> "$OUT"
  sleep 0.5
done
echo "samples: $(wc -l < "$OUT")"
