#!/usr/bin/env bash
# Put exactly one PHP arm in front of Angie's shared FastCGI socket
# (/run/php/php-fpm.sock) and prove it is serving.
#
# Usage: switch-php-arm.sh sury|ubuntu|src-TAG
#
# "sury" and "ubuntu" both start the distribution unit (php8.5-fpm); which
# package provides it is decided by the caller (the audit purges one before
# installing the other).  "src-TAG" starts php-src-TAG.service built by
# build-php-source.sh and gives it a private extension directory that mirrors
# the distribution's conf.d minus redis/imagick, with the arm's own builds
# added from its ext/ directory (the unit sets PHP_INI_SCAN_DIR).
set -Eeuo pipefail
export LC_ALL=C

ARM=${1:?usage: switch-php-arm.sh sury|ubuntu|src-TAG}
PHP_INI_DIR=/etc/php/8.5/fpm
SOCK=/run/php/php-fpm.sock

stop_all() {
  local u
  # Every pool this host can serve from: the packaged unit, the extracted
  # Ubuntu unit and every source build.  php-src units are not enabled, so
  # list every loaded unit rather than unit files.
  systemctl stop php8.5-fpm php-pkg-ubuntu.service >/dev/null 2>&1 || true
  for u in $(systemctl list-units --all --no-legend --no-pager \
               | awk '$1 ~ /^php(-src-.*)?\.service$/ { print $1 }'); do
    systemctl stop "$u" >/dev/null 2>&1 || true
  done
  # A benchmark visits several arms per minute; without clearing the start
  # rate limit the next unit fails with "start request repeated too quickly".
  systemctl reset-failed >/dev/null 2>&1 || true
  # Wait for the socket to disappear so the next arm binds a fresh one.
  for _ in $(seq 1 50); do
    [[ -S $SOCK ]] || return 0
    sleep 0.2
  done
  echo "socket $SOCK still present after stopping every pool" >&2
  return 1
}

case $ARM in
  sury)
    UNIT=php8.5-fpm
    BIN=/usr/bin/php8.5
    PHP_ARGS=()
    ;;
  ubuntu)
    # The Ubuntu archive's packages, extracted (not installed) so they
    # coexist with Sury's.  Same php.ini/pool; its own extension set and a
    # scan dir that mirrors the setup-managed settings.
    UNIT=php-pkg-ubuntu.service
    BIN=/opt/php-ubuntu/usr/bin/php8.5
    UBUNTU_CONF=/etc/php-ubuntu/conf.d
    UBUNTU_EXTDIR=$(dirname "$(find /opt/php-ubuntu/usr/lib/php -name 'mysqli.so' -print -quit 2>/dev/null)")
    [[ -x $BIN && -n $UBUNTU_EXTDIR ]] \
      || { echo "no $BIN; run extract-php-debs.sh first" >&2; exit 1; }
    mkdir -p "$UBUNTU_CONF"
    for ini in custom_dan.ini zz-setup-optimize.ini zzz-audit.ini; do
      [[ -f $PHP_INI_DIR/conf.d/$ini ]] && cp -f "$PHP_INI_DIR/conf.d/$ini" "$UBUNTU_CONF/"
    done
    export PHP_INI_SCAN_DIR="$UBUNTU_CONF"
    PHP_ARGS=(-d "extension_dir=$UBUNTU_EXTDIR")
    ;;
  src-*)
    TAG=${ARM#src-}
    UNIT="php-src-$TAG.service"
    BIN="/opt/php-$TAG/bin/php"
    CONF_DIR="/etc/php-src/$TAG/conf.d"
    EXT_DIR="/etc/php-src/$TAG/ext"
    [[ -x $BIN ]] || { echo "no $BIN; build the arm first" >&2; exit 1; }
    mkdir -p "$CONF_DIR" "$EXT_DIR"
    # Mirror the managed configuration (zz-setup-optimize.ini is rewritten by
    # setup.sh --optimize) but never the distribution's redis/imagick .so:
    # the arm loads its own builds from $EXT_DIR.
    rsync -aL --delete --exclude '*redis*.ini' --exclude '*imagick*.ini' \
      "$PHP_INI_DIR/conf.d/" "$CONF_DIR/"
    # The source build compiles its module set into the binary and has an empty
    # extension_dir, so every conf.d file that loads a shared module would log
    # "Unable to load dynamic library".  Keep only the settings files
    # (custom_dan.ini, zz-setup-optimize.ini, zzz-audit.ini) and load the three
    # extensions the applications need from the distribution's builds, which
    # share the Zend module API, by absolute path.
    # conf.d entries are symlinks into mods-available: follow them.
    mapfile -t ext_ini < <(find -L "$CONF_DIR" -name '*.ini' \
      -exec grep -lE '^[[:space:]]*extension[[:space:]]*=' {} + 2>/dev/null || true)
    for f in "${ext_ini[@]}"; do rm -f "$f"; done
    for ext in igbinary redis imagick; do
      mods=(/usr/lib/php/*/"$ext".so)
      [[ -f ${mods[0]:-} ]] || continue
      prio=99; [[ $ext == igbinary ]] && prio=20
      printf 'extension=%s\n' "${mods[0]}" > "$EXT_DIR/$prio-$ext.ini"
    done
    # The same scan path the unit uses, so the CLI checks below describe FPM.
    export PHP_INI_SCAN_DIR="$CONF_DIR:$EXT_DIR"
    PHP_ARGS=()
    ;;
  *)
    echo "unknown arm: $ARM" >&2; exit 1 ;;
esac

stop_all
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
systemctl start "$UNIT"

for _ in $(seq 1 100); do
  [[ -S $SOCK ]] && break
  sleep 0.2
done
[[ -S $SOCK ]] || { systemctl status "$UNIT" --no-pager >&2 || true; echo "$SOCK never appeared" >&2; exit 1; }

# The first request after a switch loads OPcache; wait for a 2xx/3xx.
code=""
for _ in $(seq 1 50); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
           -H 'Cookie: arm-probe=1' https://wp.test.local/ 2>/dev/null || true)
  [[ $code =~ ^[23] ]] && break
  sleep 0.3
done
[[ $code =~ ^[23] ]] || { echo "app answered HTTP ${code:-none} after switching to $ARM" >&2; exit 1; }

printf '== arm %s (%s)\n' "$ARM" "$UNIT"
"$BIN" "${PHP_ARGS[@]}" -v | head -1
printf 'modules: '
"$BIN" "${PHP_ARGS[@]}" -m 2>/dev/null | tr '\n' ' '
echo
"$BIN" "${PHP_ARGS[@]}" -r 'printf("ini=%s\n", php_ini_loaded_file()); printf("scan=%s\n", php_ini_scanned_files());' 2>/dev/null || true
