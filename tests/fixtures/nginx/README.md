# nginx tuning fixture

These files are **test fixtures only**. They are small copies of the canonical
nginx configuration from
[`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx)
(MIT licensed) so that `tests/test-tuning.sh` can exercise the rewriting logic
without a network fetch or a live nginx installation.

`nginx.conf` is synthetic: it deliberately contains an `http2 on;` line before
the `http {` block so a regression in the insertion anchor is caught.
