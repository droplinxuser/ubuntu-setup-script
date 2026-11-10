#!/usr/bin/env bash
# Apply one OPcache JIT profile to the live PHP-FPM pool for an A/B run.
# Run as root on the host under test. A drop-in named zzz-audit.ini wins over
# zz-setup-optimize.ini (ini files load in lexical order); --optimize removes
# nothing, so delete the file to return the host to the managed profile.
#
# Usage: set-jit.sh tracing64|tracing32|tracing128|aggressive|conservative|function|off
set -Eeuo pipefail
VARIANT=${1:?variant}
VER=${PHP_VER:-$(for d in /etc/php/*/; do d=${d%/}; [[ ${d##*/} =~ ^[0-9]+\.[0-9]+$ ]] && echo "${d##*/}"; done | sort -V | tail -1)}
DROPIN="/etc/php/${VER}/fpm/conf.d/zzz-audit.ini"

case "$VARIANT" in
  tracing64)   buf=64M;  jit=tracing;  hot=(64 127 16 64) ;;
  tracing32)   buf=32M;  jit=tracing;  hot=(64 127 16 64) ;;
  tracing128)  buf=128M; jit=tracing;  hot=(64 127 16 64) ;;
  aggressive)  buf=64M;  jit=tracing;  hot=(16 64 8 32) ;;
  conservative) buf=64M; jit=tracing;  hot=(128 255 32 128) ;;
  function)    buf=64M;  jit=function; hot=(64 127 16 64) ;;
  off)         buf=0;    jit=off;      hot=(64 127 16 64) ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

cat > "$DROPIN" <<EOF
; Temporary audit profile - not managed by setup.sh.
opcache.jit = ${jit}
opcache.jit_buffer_size = ${buf}
opcache.jit_hot_loop = ${hot[0]}
opcache.jit_hot_func = ${hot[1]}
opcache.jit_hot_return = ${hot[2]}
opcache.jit_hot_side_exit = ${hot[3]}
EOF
chmod 644 "$DROPIN"
systemctl reload "php${VER}-fpm"
echo "applied ${VARIANT} to php${VER}-fpm (${DROPIN})"
