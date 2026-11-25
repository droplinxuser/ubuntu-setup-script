#!/usr/bin/env bash
# Switch the compression settings the compression benchmark compares, then
# validate and reload.  Audit host only; a plain `setup.sh --optimize`
# restores the shipped profile.  (zstd, measured in 1.21.58, was removed in
# 1.21.59: Cloudflare asks origins for "br, gzip" only; brotli_static and
# gzip_static, the precompressed siblings, were removed in 1.22.1.)
#
#   set-comp.sh br LEVEL|off       nginx dynamic Brotli level (or off)
#   set-comp.sh gzip LEVEL         nginx gzip_comp_level
#   set-comp.sh phpgz LEVEL|off    zlib.output_compression for the WP/Chevereto roots
#   set-comp.sh show
set -euo pipefail
A=/etc/nginx; INI=$(ls /etc/php/*/fpm/conf.d/zz-setup-optimize.ini | head -n 1)
PHPV=$(basename "$(dirname "$(dirname "$(dirname "$INI")")")")
what=${1:-show}; val=${2:-}
reload_nginx() { nginx -t -q && systemctl reload nginx; }
reload_php() { systemctl reload "php${PHPV}-fpm"; }
case $what in
  br)
    if [[ $val == off ]]; then sed -i -E 's/^brotli (on|off);/brotli off;/' $A/http.d/brotli.conf
    else sed -i -E "s/^brotli (on|off);/brotli on;/; s/^brotli_comp_level [0-9]+;/brotli_comp_level $val;/" $A/http.d/brotli.conf; fi
    reload_nginx ;;
  gzip)
    sed -i -E "s/^([[:space:]]*gzip_comp_level[[:space:]]+)[0-9]+;/\\1$val;/" $A/h5bp/web_performance/compression.conf
    reload_nginx ;;
  phpgz)
    if [[ $val == off ]]; then sed -i -E 's/^zlib.output_compression = On/zlib.output_compression = Off/' "$INI"
    else sed -i -E "s/^zlib.output_compression = (On|Off)/zlib.output_compression = On/; s/^zlib.output_compression_level = [0-9-]+/zlib.output_compression_level = $val/" "$INI"; fi
    reload_php ;;
  show) ;;
  *) echo "unknown: $what" >&2; exit 2 ;;
esac
grep -E '^brotli (on|off)|^brotli_comp_level' $A/http.d/brotli.conf | tr '\n' ' '
grep -E 'gzip_comp_level' $A/h5bp/web_performance/compression.conf | tr -s ' ' | tr '\n' ' '
grep -E '^zlib\.output_compression' "$INI" | sort | uniq -c | tr -s ' ' | tr '\n' ' '; echo
