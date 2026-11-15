# Remote stress report (wp.test.local via 192.168.1.139)

- Generated: 2026-11-16T03:27:24+0800 from rts-Mac-Mini.local (Darwin arm64)
- Tool: oha 1.16.0, 200 connections, 10s per scenario, https, keep-alive

## Results

| Scenario | req/s | p50 ms | p90 ms | p99 ms | p99.9 ms | status / errors |
|---|---:|---:|---:|---:|---:|---|
| xf-member | 407 | 243.53 | 252.46 | 380.99 | 488.09 | 200=3973 aborted due to deadline=100 |
| xf-member-thread | 270 | 374.2 | 383.46 | 522.25 | 612.69 | 200=2602 aborted due to deadline=100 |
| wp-member | 140 | 722.38 | 748.66 | 1201 | 1275.75 | 200=1305 aborted due to deadline=100 |
| wp-member-post | 133 | 761.11 | 788.19 | 1306.97 | 1373.89 | 200=1229 aborted due to deadline=100 |

## Notes

- Latency includes the LAN/WAN round trip from the workstation; compare scenarios
  against each other and against the server-side collect-metrics.sh samples.
- Raw oha JSON per scenario: /var/folders/1f/_9l4rpfn4rb9gnhy4cbbvjbh0000gn/T//stress-remote.hXKDpp
