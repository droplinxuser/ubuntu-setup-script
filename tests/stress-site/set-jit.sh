#!/usr/bin/env bash
# Apply one OPcache JIT profile to the live PHP-FPM pool for an A/B run.
# Run as root on the host under test. A drop-in named zzz-audit.ini wins over
# zz-setup-optimize.ini (ini files load in lexical order); --optimize removes
# nothing, so delete the file to return the host to the managed profile.
#
# Usage: set-jit.sh VARIANT [X.Y|active|all]
#   VARIANT  tracing64|tracing32|tracing128|aggressive|conservative|
#            function|off|roots1024|roots256|poly4|side128|combined|none
#   target   one series (X.Y), the active one (/etc/php/setup-active, the
#            default; PHP_VER=X.Y still works), or `all`: the same drop-in in
#            every installed /etc/php/X.Y/fpm, for the series benchmark.
# `combined` applies the best thresholds found by the audit in one profile;
# `none` removes the drop-in (back to the managed profile).  Only units that
# are running are reloaded; a stopped series reads the file at its start.
set -Eeuo pipefail
VARIANT=${1:?variant}
TARGET=${2:-${PHP_VER:-active}}
case $TARGET in
  all)    mapfile -t VERS < <(for d in /etc/php/*/fpm; do v=${d%/fpm}; v=${v##*/}
                                [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && echo "$v"; done | sort -V) ;;
  active) VERS=("$(tr -d '[:space:]' < /etc/php/setup-active 2>/dev/null || true)") ;;
  *)      VERS=("$TARGET") ;;
esac
(( ${#VERS[@]} )) || { echo "no /etc/php/X.Y/fpm tree" >&2; exit 1; }
for v in "${VERS[@]}"; do
  [[ $v =~ ^[0-9]+\.[0-9]+$ && -d /etc/php/$v/fpm/conf.d ]] || { echo "no /etc/php/${v:-?}/fpm/conf.d (target $TARGET)" >&2; exit 1; }
done

apply() { # X.Y: write (or remove) the drop-in, reload a running unit
  local dropin="/etc/php/$1/fpm/conf.d/zzz-audit.ini"
  if [[ $VARIANT == none ]]; then rm -f "$dropin"; else printf '%s' "$TEXT" > "$dropin"; chmod 644 "$dropin"; fi
  if systemctl is-active --quiet "php$1-fpm"; then systemctl reload "php$1-fpm"; fi
  echo "applied ${VARIANT} to php$1-fpm (${dropin})"
}
if [[ $VARIANT == none ]]; then
  for v in "${VERS[@]}"; do apply "$v"; done
  exit 0
fi

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

TEXT=$(
  printf '; Temporary audit profile - not managed by setup.sh.\n'
  printf 'opcache.jit = %s\n' "$jit"
  printf 'opcache.jit_buffer_size = %s\n' "$buf"
  printf 'opcache.jit_hot_loop = %s\n' "${hot[0]}"
  printf 'opcache.jit_hot_func = %s\n' "${hot[1]}"
  printf 'opcache.jit_hot_return = %s\n' "${hot[2]}"
  printf 'opcache.jit_hot_side_exit = %s\n' "${hot[3]}"
  if [[ -n $extra ]]; then printf '%s\n' "$extra"; fi
)$'\n'
for v in "${VERS[@]}"; do apply "$v"; done
