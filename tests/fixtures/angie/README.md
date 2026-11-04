# Angie tuning fixture

These files are **test fixtures only**. They are small copies of the canonical
Angie configuration from
[`droplinxuser/server-configs-nginx`](https://github.com/droplinxuser/server-configs-nginx)
(MIT licensed) so that `tests/test-tuning.sh` can exercise the rewriting logic
without a network fetch or a live Angie installation.

`angie.conf` is synthetic: it deliberately contains an `http2 on;` line before
the `http {` block so a regression in the insertion anchor is caught.
