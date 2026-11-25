#!/usr/bin/env bash
# Copy every bundled XenForo add-on's files into the forum and install the
# add-on IDs given on the command line (all of them when none are given).
# Run as root; the forum is at /var/www/xf.test.local/public.
# PLAIN=1 (the PHP-series benchmark, deploy-xf.sh PLAIN=1): the default list
# is Hampel/Seeder alone: no SV Redis add-ons, no XFES (Elasticsearch).
set -Eeuo pipefail
export LC_ALL=C.UTF-8

ROOT=/var/www/xf.test.local/public
PKG=/root/work/pkg
PHP=${PHP:-/usr/local/bin/php}
WORK=$(mktemp -d /tmp/xf-addons.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

[[ -d $ROOT ]] || { echo "missing $ROOT" >&2; exit 1; }

for zip in "$PKG"/xenforo_addon_*.zip; do
  [[ -f $zip ]] || continue
  d="$WORK/$(basename "$zip" .zip)"
  mkdir -p "$d"
  unzip -q "$zip" -d "$d"
  [[ -d $d/upload ]] && cp -a "$d/upload/." "$ROOT/"
done
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 640 "$ROOT/src/config.php"

ids=("$@")
if (( ${#ids[@]} == 0 )); then
  if [[ ${PLAIN:-0} == 1 ]]; then ids=(Hampel/Seeder)
  else ids=(Hampel/Seeder SV/StandardLib SV/RedisCache SV/RedisFloodCheck SV/RedisViewCounter); fi
fi

for id in "${ids[@]}"; do
  echo "== install ${id}"
  if ! runuser -u www-data -- "$PHP" "$ROOT/cmd.php" xf:addon-install "$id" --force; then
    echo "   --force form failed, retrying without it" >&2
    runuser -u www-data -- "$PHP" "$ROOT/cmd.php" xf:addon-install "$id"
  fi
done

echo "== add-on list"
runuser -u www-data -- "$PHP" "$ROOT/cmd.php" xf:addon-list 2>/dev/null | sed -n '1,40p' || true
