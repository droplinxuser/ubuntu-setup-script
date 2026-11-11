#!/usr/bin/env bash
# Pin the live PHP-FPM pool to a worker count for one A/B run, and restore it.
# Run as root on the host under test.  The original pm.max_children is saved
# once under /var/lib/stress-site so the sweep is reversible even if the driver
# is interrupted.
#
# Usage: set-fpm.sh N|restore
set -Eeuo pipefail
ACTION=${1:?N or restore}
VER=${PHP_VER:-$(for d in /etc/php/*/; do d=${d%/}; [[ ${d##*/} =~ ^[0-9]+\.[0-9]+$ ]] && echo "${d##*/}"; done | sort -V | tail -1)}
POOL="/etc/php/${VER}/fpm/pool.d/www.conf"
STATE=/var/lib/stress-site/fpm-pool-state.conf

[[ -f $POOL ]] || { echo "no pool at ${POOL}" >&2; exit 1; }
mkdir -p "$(dirname "$STATE")"

set_key() {
  local key=$1 value=$2
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$POOL"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$POOL"
  else
    printf '%s = %s\n' "$key" "$value" >> "$POOL"
  fi
}

if [[ $ACTION == restore ]]; then
  [[ -f $STATE ]] || { echo "no saved state at ${STATE}" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE"
  set_key pm.max_children "$ORIGINAL_MAX_CHILDREN"
  set_key pm "$ORIGINAL_PM"
  systemctl reload "php${VER}-fpm"
  echo "restored pm=${ORIGINAL_PM} pm.max_children=${ORIGINAL_MAX_CHILDREN}"
  exit 0
fi

[[ $ACTION =~ ^[0-9]+$ ]] && (( ACTION >= 2 )) || { echo "worker count must be >= 2" >&2; exit 2; }

if [[ ! -f $STATE ]]; then
  {
    printf 'POOL=%s\n' "$POOL"
    printf 'ORIGINAL_PM=%s\n' "$(awk -F= '/^[[:space:]]*pm[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$POOL")"
    printf 'ORIGINAL_MAX_CHILDREN=%s\n' "$(awk -F= '/^[[:space:]]*pm\.max_children[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$POOL")"
  } > "$STATE"
  chmod 600 "$STATE"
fi

set_key pm static
set_key pm.max_children "$ACTION"
systemctl reload "php${VER}-fpm"
echo "applied pm=static pm.max_children=${ACTION} to php${VER}-fpm"
