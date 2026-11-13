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

# The shipped pool is pm=static and deliberately carries no start/spare keys.
# Switching it to pm=dynamic without them makes PHP-FPM refuse to start
# ("pm.min_spare_servers(0) must be a positive value"), and the service then
# restarts in a loop while every request answers 502.  The sweep must never
# leave the host in that state.
ensure_dynamic_keys() {
  local key value
  for kv in "pm.start_servers 2" "pm.min_spare_servers 1" "pm.max_spare_servers 3"; do
    key=${kv% *}; value=${kv#* }
    set_key "$key" "$value"
  done
}

# Remove the start/spare keys a dynamic A/B run adds, so restoring a static
# pool returns the file to the shipped content instead of leaving inert keys.
drop_dynamic_keys() {
  sed -i -E "/^[[:space:]]*pm\.(start_servers|min_spare_servers|max_spare_servers)[[:space:]]*=/d" "$POOL"
}

# Validate a candidate pool before it goes live; restore the saved state when
# it is rejected so a failed sweep cannot take the site down.
apply_or_restore() {
  local bin
  bin=$(command -v "php-fpm${VER}" || echo "/usr/sbin/php-fpm${VER}")
  if ! "$bin" -t >/dev/null 2>&1; then
    "$bin" -t 2>&1 | tail -3 >&2
    if [[ -f $STATE ]]; then
      # shellcheck disable=SC1090
      . "$STATE"
      set_key pm.max_children "$ORIGINAL_MAX_CHILDREN"
      set_key pm "$ORIGINAL_PM"
      [[ $ORIGINAL_PM == static ]] && drop_dynamic_keys
      systemctl reload "php${VER}-fpm" 2>/dev/null || true
      echo "candidate pool rejected; restored pm=${ORIGINAL_PM} pm.max_children=${ORIGINAL_MAX_CHILDREN}" >&2
    fi
    exit 3
  fi
  systemctl reload "php${VER}-fpm"
}

if [[ $ACTION == restore ]]; then
  [[ -f $STATE ]] || { echo "no saved state at ${STATE}" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE"
  set_key pm.max_children "$ORIGINAL_MAX_CHILDREN"
  set_key pm "$ORIGINAL_PM"
  [[ $ORIGINAL_PM == static ]] && drop_dynamic_keys
  systemctl reload "php${VER}-fpm"
  echo "restored pm=${ORIGINAL_PM} pm.max_children=${ORIGINAL_MAX_CHILDREN}"
  exit 0
fi

# `dynamic N` exists for the A/B sweep: the shipped pool is static, so a bare
# change of pm= alone would leave the spare-server values unset and PHP-FPM
# would refuse to start.
DYNAMIC=0
if [[ $ACTION == dynamic ]]; then
  DYNAMIC=1
  ACTION=${2:?dynamic requires a worker count}
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

if (( DYNAMIC )); then
  set_key pm dynamic
  set_key pm.max_children "$ACTION"
  ensure_dynamic_keys
else
  set_key pm static
  set_key pm.max_children "$ACTION"
fi
apply_or_restore
echo "applied pm=$([[ $DYNAMIC == 1 ]] && echo dynamic || echo static) pm.max_children=${ACTION} to php${VER}-fpm"
