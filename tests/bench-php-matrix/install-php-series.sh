#!/usr/bin/env bash
# Build and lay out PHP series side by side for the series benchmark
# (switch-php-arm.sh series-X.Y), on a host that setup.sh 1.22 already
# serves from one compiled PHP (the tool and library under
# /usr/local/lib/setup-php).  Replaces install-php-versions.sh (Sury).
#
# Usage: install-php-series.sh X.Y [X.Y...]     e.g. 8.1 8.2 8.3 8.4 8.5 8.6
#
# Every arm gets ONE extension set, so the comparison is like for like:
# BENCH_EXTS (comma list) or, by default, the active version's effective set
# (lib/php-build.sh php_build_effective_exts) without redis and igbinary.
# The PECL redis/igbinary releases do not build on PHP 8.6, and the plain
# XenForo stack (deploy-xf.sh PLAIN=1) has no Redis cache provider.  It is
# handed to the tool as PHP_BUILD_EXTS and recorded in ROOT/X.Y/exts.want.
# A series whose build already has that set is not rebuilt (FORCE=1 does).
# Listing the active version rebuilds it with this set too: on a host where
# another site needs redis, leave it out or pass BENCH_EXTS.
#
# Each series is laid out like setup.sh does (unit, /etc/php/X.Y, links)
# and gets the active version's tuned pool (pool.d/www.conf) and
# zz-setup-optimize.ini, so pool size and OPcache/JIT settings are equal.
# Nothing is enabled or started and /etc/php/setup-active is not changed;
# run the benchmark, then `switch-php-arm.sh series-<active>` puts the
# active version back.  Stop setup-build-refresh.timer while benchmarking:
# its daily refresh recomputes the active version's set and may rebuild.
set -Eeuo pipefail
export LC_ALL=C

(( $# )) || { echo "usage: install-php-series.sh X.Y [X.Y...]" >&2; exit 2; }
ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
TOOL=$ROOT/php-build.sh
LIB=$ROOT/php-build-lib.sh
[[ -x $TOOL && -f $LIB ]] || { echo "missing $TOOL or $LIB: run setup.sh --php once first" >&2; exit 1; }
# shellcheck source=lib/php-build.sh
. "$LIB"

ACTIVE=$(php_active_version)
[[ -n $ACTIVE ]] || { echo "no active PHP version (/etc/php/setup-active)" >&2; exit 1; }
sorted() { tr ', ' '\n\n' <<<"$1" | sed '/^$/d' | sort -u | paste -sd, -; }
norm() { sorted "$1" | tr ',' '\n' | grep -vxE 'redis|igbinary' | paste -sd, -; }
EXTS=$(norm "${BENCH_EXTS:-$(php_build_effective_exts "$ACTIVE")}")
[[ -n $EXTS ]] || { echo "empty extension set" >&2; exit 1; }
echo "== extension set for every series: $EXTS"

for ver in "$@"; do
  [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || { echo "bad series '$ver'" >&2; exit 2; }
  echo "== PHP $ver"
  have=$(awk -F= '$1 == "exts" { print substr($0, 6) }' "$ROOT/$ver/build.info" 2>/dev/null || true)
  if [[ ${FORCE:-0} == 1 || ! -x $ROOT/$ver/sbin/php-fpm || $(sorted "$have") != "$EXTS" ]]; then
    PHP_BUILD_EXTS=$EXTS "$TOOL" build "$ver"
    "$TOOL" activate "$ver"
  else
    echo "   build already has this set: $("$TOOL" status "$ver" 2>/dev/null | head -n 1)"
  fi
  printf '%s\n' "$EXTS" > "$ROOT/$ver/exts.want"
  php_build_unit_write "$ver"
  php_build_layout "$ver" || { echo "PHP $ver: /etc/php/$ver layout failed" >&2; exit 1; }
  if [[ $ver != "$ACTIVE" ]]; then
    for f in pool.d/www.conf conf.d/zz-setup-optimize.ini; do
      [[ -f /etc/php/$ACTIVE/fpm/$f ]] && install -m 644 "/etc/php/$ACTIVE/fpm/$f" "/etc/php/$ver/fpm/$f"
    done
    # One version owns the socket: never enabled, started by the switcher.
    systemctl disable "php$ver-fpm" >/dev/null 2>&1 || true
  fi
  php_fpm_test "$ver" >/dev/null || { php_fpm_test "$ver" | grep -iE 'error|warning|unable|not loaded' >&2; exit 1; }
  printf '   %s; php-fpm -t clean\n' "$("$ROOT/$ver/sbin/php-fpm" -v | head -n 1)"
done
systemctl daemon-reload
echo "== done; arms: $(printf 'series-%s ' "$@")"
