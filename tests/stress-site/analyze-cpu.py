#!/usr/bin/env python3
"""Turn sample-cpu.sh output into CPU ms and ms per request per service.

Usage: analyze-cpu.py SAMPLE_FILE REQUESTS
"""
import sys
from collections import defaultdict

if len(sys.argv) < 3:
    sys.exit("usage: analyze-cpu.py SAMPLE_FILE REQUESTS")

path, requested = sys.argv[1], float(sys.argv[2])
per_stamp = defaultdict(lambda: defaultdict(float))
host = {}
with open(path) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) < 3:
            continue
        ts = float(parts[0])
        if parts[1] == "HOST":
            host[ts] = float(parts[2])
        else:
            per_stamp[ts][parts[1]] += float(parts[2])

stamps = sorted(set(per_stamp) | set(host))
if len(stamps) < 2:
    sys.exit("not enough samples")
span = max(stamps[-1] - stamps[0], 1e-9)
print(f"samples={len(stamps)} span={span:.1f}s requests={requested:.0f}")
comm_stamps = defaultdict(list)
for ts, row in per_stamp.items():
    for comm in row:
        comm_stamps[comm].append(ts)
for comm in sorted(comm_stamps):
    seen = sorted(comm_stamps[comm])
    if len(seen) < 2:
        continue
    ms = (per_stamp[seen[-1]][comm] - per_stamp[seen[0]][comm]) * 10.0
    print(
        f"{comm:14s} cpu={ms:9.0f} ms  {ms / 1000 / span * 100:5.1f}% of one core"
        f"  {ms / requested:7.3f} ms/req"
    )
if len(host) >= 2:
    hs = sorted(host)
    used = (host[hs[-1]] - host[hs[0]]) / 100.0
    print(f"host CPU used={used:.0f} core-seconds  avg={used / span:.2f} cores")
