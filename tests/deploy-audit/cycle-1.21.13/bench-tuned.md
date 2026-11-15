# Remote stress report (wp.test.local via 192.168.1.139)

- Generated: 2026-11-16T03:25:22+0800 from rts-Mac-Mini.local (Darwin arm64)
- Tool: oha 1.16.0, 200 connections, 10s per scenario, https, keep-alive

## Results

| Scenario | req/s | p50 ms | p90 ms | p99 ms | p99.9 ms | status / errors |
|---|---:|---:|---:|---:|---:|---|
| xf-guest | 7253 | 23.45 | 28.16 | 38.87 | 400.3 | 200=72380 aborted due to deadline=199 |
| xf-guest-uncached | 1039 | 94.66 | 103.37 | 108.04 | 137.21 | 200=10296 aborted due to deadline=100 |
| xf-member | 880 | 114 | 121.18 | 126.03 | 168.09 | 200=8704 aborted due to deadline=100 |
| xf-member-thread | 573 | 173.93 | 188.65 | 196.27 | 241.02 | 200=5631 aborted due to deadline=100 |
| wp-guest | 5280 | 32.68 | 40.5 | 81.02 | 411.31 | 200=52621 aborted due to deadline=200 |
| wp-guest-uncached | 297 | 332.98 | 378.44 | 571.44 | 643.41 | 200=2875 aborted due to deadline=100 |
| wp-member | 296 | 343.18 | 410.85 | 488.45 | 559.63 | 200=2861 aborted due to deadline=100 |
| wp-member-post | 283 | 360.19 | 498.41 | 621.44 | 718.03 | 200=2730 aborted due to deadline=100 |

## Notes

- Latency includes the LAN/WAN round trip from the workstation; compare scenarios
  against each other and against the server-side collect-metrics.sh samples.
- Raw oha JSON per scenario: /var/folders/1f/_9l4rpfn4rb9gnhy4cbbvjbh0000gn/T//stress-remote.2Ztw4t
