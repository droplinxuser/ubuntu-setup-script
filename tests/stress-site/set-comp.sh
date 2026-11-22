#!/usr/bin/env bash
# Switch the compression settings the compression benchmark compares, then
# validate and reload.  Audit host only; a plain `setup.sh --optimize`
# restores the shipped profile (bench-only zstd files, written when setup.sh
# manages no zstd stanza, carry no "Managed by" header: remove them with
# `set-comp.sh zstd off` first).
#
#   set-comp.sh br LEVEL|off       Angie dynamic Brotli level (or off)
#   set-comp.sh gzip LEVEL         Angie gzip_comp_level
#   set-comp.sh zstd LEVEL|off     Angie dynamic zstd: edits the managed http.d/zstd.conf
#                                  when setup.sh wrote one, else adds bench files
#   set-comp.sh static on|off      brotli_static/gzip_static (precompressed siblings)
#   set-comp.sh phpgz LEVEL|off    zlib.output_compression for the WP/Chevereto roots
#   set-comp.sh phpzstd LEVEL|off  zstd.output_compression for the same roots
#                                  (installs php8.5-zstd; needs a cache key with zstd)
#   set-comp.sh show
set -euo pipefail
A=/etc/angie; INI=$(ls /etc/php/*/fpm/conf.d/zz-setup-optimize.ini | head -n 1)
PHPV=$(basename "$(dirname "$(dirname "$(dirname "$INI")")")")
what=${1:-show}; val=${2:-}
reload_angie() { angie -t -q && systemctl reload angie; }
reload_php() { systemctl reload "php${PHPV}-fpm"; }
case $what in
  br)
    if [[ $val == off ]]; then sed -i -E 's/^brotli (on|off);/brotli off;/' $A/http.d/brotli.conf
    else sed -i -E "s/^brotli (on|off);/brotli on;/; s/^brotli_comp_level [0-9]+;/brotli_comp_level $val;/" $A/http.d/brotli.conf; fi
    reload_angie ;;
  gzip)
    sed -i -E "s/^([[:space:]]*gzip_comp_level[[:space:]]+)[0-9]+;/\\1$val;/" $A/h5bp/web_performance/compression.conf
    reload_angie ;;
  zstd)
    if grep -q "^# Managed by setup.sh" $A/http.d/zstd.conf 2>/dev/null; then
      if [[ $val == off ]]; then sed -i -E "s/^zstd (on|off);/zstd off;/" $A/http.d/zstd.conf
      else sed -i -E "s/^zstd (on|off);/zstd on;/; s/^zstd_comp_level [0-9]+;/zstd_comp_level $val;/" $A/http.d/zstd.conf; fi
    elif [[ $val == off ]]; then rm -f $A/modules-enabled/60-zstd-bench.conf $A/modules-enabled/40-zstd-bench.conf $A/http.d/zstd-bench.conf
    else
      dpkg -s angie-module-zstd >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q angie-module-zstd >/dev/null
      # After 50-brotli.conf: the filter loaded last runs first, so zstd
      # answers the clients that offer it and Brotli the rest.
      rm -f $A/modules-enabled/40-zstd-bench.conf
      printf 'load_module modules/ngx_http_zstd_filter_module.so;\nload_module modules/ngx_http_zstd_static_module.so;\n' > $A/modules-enabled/60-zstd-bench.conf
      { sed -E "s/^zstd_comp_level [0-9]+;/zstd_comp_level $val;/" /root/work/server-configs-nginx/http.d/zstd_conf; } > $A/http.d/zstd-bench.conf
    fi
    reload_angie ;;
  static)
    sed -i -E "s/^brotli_static (on|off);/brotli_static $val;/" $A/http.d/brotli.conf
    sed -i -E "s/^([[:space:]]*gzip_static[[:space:]]+)(on|off);/\\1$val;/" $A/h5bp/web_performance/compression.conf
    reload_angie ;;
  phpgz)
    if [[ $val == off ]]; then sed -i -E 's/^zlib.output_compression = On/zlib.output_compression = Off/' "$INI"
    else sed -i -E "s/^zlib.output_compression = (On|Off)/zlib.output_compression = On/; s/^zlib.output_compression_level = [0-9-]+/zlib.output_compression_level = $val/" "$INI"; fi
    reload_php ;;
  phpzstd)
    dpkg -s "php${PHPV}-zstd" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q "php${PHPV}-zstd" >/dev/null
    sed -i -E '/^zstd\.output_compression/d' "$INI"
    if [[ $val != off ]]; then
      sed -i -E "s/^(zlib.output_compression_level = .*)$/\\1\nzstd.output_compression = On\nzstd.output_compression_level = $val/" "$INI"
    fi
    reload_php ;;
  show) ;;
  *) echo "unknown: $what" >&2; exit 2 ;;
esac
grep -E '^brotli (on|off)|^brotli_comp_level' $A/http.d/brotli.conf | tr '\n' ' '
grep -E 'gzip_comp_level' $A/h5bp/web_performance/compression.conf | tr -s ' ' | tr '\n' ' '
for z in $A/http.d/zstd.conf $A/http.d/zstd-bench.conf; do [[ -f $z ]] && grep -E '^zstd (on|off)|^zstd_comp_level' "$z" | tr '\n' ' '; done
grep -hE '^brotli_static|^[[:space:]]*gzip_static' $A/http.d/brotli.conf $A/h5bp/web_performance/compression.conf | tr -s ' ' | tr '\n' ' '
grep -E '^(zlib|zstd)\.output_compression' "$INI" | sort | uniq -c | tr -s ' ' | tr '\n' ' '; echo
