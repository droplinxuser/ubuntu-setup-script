#!/usr/bin/env bash
# Apply one OPcache JIT profile to the live PHP-FPM pool for an A/B run.
# Run as root on the host under test. A drop-in named zzz-audit.ini wins over
# zz-setup-optimize.ini (ini files load in lexical order); --optimize removes
# nothing, so delete the file to return the host to the managed profile.
#
# Usage: set-jit.sh tracing64|tracing32|tracing128|aggressive|conservative|
#                    function|off|roots1024|roots256|poly4|side128|combined
# `combined` applies the best thresholds found by the audit in one profile.
set -Eeuo pipefail
VARIANT=${1:?variant}
VER=${PHP_VER:-$(for d in /etc/php/*/; do d=${d%/}; [[ ${d##*/} =~ ^[0-9]+\.[0-9]+$ ]] && echo "${d##*/}"; done | sort -V | tail -1)}
DROPIN="/etc/php/${VER}/fpm/conf.d/zzz-audit.ini"

extra=""
case "$VARIANT" in
  tracing64)   buf=64M;  jit=tracing;  hot=(64 127 16 64) ;;
  tracing32)   buf=32M;  jit=tracing;  hot=(64 127 16 64) ;;
  tracing128)  buf=128M; jit=tracing;  hot=(64 127 16 64) ;;
  aggressive)  buf=64M;  jit=tracing;  hot=(16 64 8 32) ;;
  conservative) buf=64M; jit=tracing;  hot=(128 255 32 128) ;;
  function)    buf=64M;  jit=function; hot=(64 127 16 64) ;;
  off)         buf=0;    jit=off;      hot=(64 127 16 64) ;;
  # Multiplier/limit knobs, tested one at a time against the defaults
  # (jit_max_root_traces=512, jit_max_side_traces=64,
  #  jit_max_polymorphic_calls=2).
  roots1024)   buf=64M;  jit=tracing;  hot=(64 127 16 64); extra=$'opcache.jit_max_root_traces = 1024' ;;
  roots256)    buf=64M;  jit=tracing;  hot=(64 127 16 64); extra=$'opcache.jit_max_root_traces = 256' ;;
  poly4)       buf=64M;  jit=tracing;  hot=(64 127 16 64); extra=$'opcache.jit_max_polymorphic_calls = 4' ;;
  side128)     buf=64M;  jit=tracing;  hot=(64 127 16 64); extra=$'opcache.jit_max_side_traces = 128' ;;
  combined)    buf=64M;  jit=tracing;  hot=(64 127 16 64)
               extra=$'opcache.jit_max_root_traces = 1024\nopcache.jit_max_side_traces = 128\nopcache.jit_max_polymorphic_calls = 4' ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

{
  printf '; Temporary audit profile - not managed by setup.sh.\n'
  printf 'opcache.jit = %s\n' "$jit"
  printf 'opcache.jit_buffer_size = %s\n' "$buf"
  printf 'opcache.jit_hot_loop = %s\n' "${hot[0]}"
  printf 'opcache.jit_hot_func = %s\n' "${hot[1]}"
  printf 'opcache.jit_hot_return = %s\n' "${hot[2]}"
  printf 'opcache.jit_hot_side_exit = %s\n' "${hot[3]}"
  [[ -n $extra ]] && printf '%s\n' "$extra"
} > "$DROPIN"
chmod 644 "$DROPIN"
systemctl reload "php${VER}-fpm"
echo "applied ${VARIANT} to php${VER}-fpm (${DROPIN})"
