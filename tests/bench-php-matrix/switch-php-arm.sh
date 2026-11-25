#!/usr/bin/env bash
# Put exactly one PHP arm in front of nginx's shared FastCGI socket
# (/run/php/php-fpm.sock) and prove it is serving.
#
# Usage: switch-php-arm.sh sury|ubuntu|src-TAG|ols-lsphp|ols-src-TAG
#
# "sury" and "ubuntu" both start the distribution unit (php8.5-fpm); which
# package provides it is decided by the caller (the audit purges one before
# installing the other).  "src-TAG" starts php-src-TAG.service built by
# build-php-source.sh and gives it a private extension directory that mirrors
# the distribution's conf.d minus redis/imagick, with the arm's own builds
# added from its ext/ directory (the unit sets PHP_INI_SCAN_DIR).
#
# "ols-lsphp" and "ols-src-TAG" stop nginx and every FPM pool and serve the
# XenForo vhost from OpenLiteSpeed (install-ols.sh) with LiteSpeed's lsphp85
# or the source arm's lsphp (LSAPI) and LSCache.  Every other arm stops
# OpenLiteSpeed and makes sure nginx is running.
set -Eeuo pipefail
export LC_ALL=C

ARM=${1:?usage: switch-php-arm.sh sury|ubuntu|src-TAG|dropin-TAG|ols-lsphp|ols-src-TAG}
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
  # A crashed arm can leave the inode behind with no listener; remove it then.
  for _ in $(seq 1 50); do
    [[ -S $SOCK ]] || return 0
    if ! ss -lx 2>/dev/null | grep -qF "$SOCK"; then
      rm -f "$SOCK"
      return 0
    fi
    sleep 0.2
  done
  echo "socket $SOCK still present after stopping every pool" >&2
  return 1
}

# LSAPI children outlive lshttpd for a few seconds after a stop and keep
# burning CPU: an nginx arm measured right after an OpenLiteSpeed arm lost
# ~10 % (199 vs 222 req/s) with lsphp still in its CPU samples.  Wait until
# every lsphp has exited (SIGKILL after 10 s).
stop_lsphp() {
  local i
  pkill -x lsphp 2>/dev/null || true
  for (( i = 0; i < 50; i++ )); do
    pgrep -x lsphp >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  pkill -9 -x lsphp 2>/dev/null || true
  sleep 0.5
}

# The scan directory of a source arm (FPM unit and OpenLiteSpeed lsphp alike),
# rebuilt on every switch so a later --optimize reaches it.
prepare_src_scan_dir() {
  local tag=$1 f ext mods prio
  local -a ext_ini=()
  CONF_DIR="/etc/php-src/$tag/conf.d"
  EXT_DIR="/etc/php-src/$tag/ext"
  [[ -x /opt/php-$tag/bin/php ]] || { echo "no /opt/php-$tag/bin/php; build the arm first" >&2; exit 1; }
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
  if [[ ! -f $EXT_DIR/.source-built-ext ]]; then
    # No source-built extensions in this arm: reuse the distribution ones.
    for ext in igbinary redis imagick; do
      mods=(/usr/lib/php/*/"$ext".so)
      [[ -f ${mods[0]:-} ]] || continue
      prio=99; [[ $ext == igbinary ]] && prio=20
      printf 'extension=%s\n' "${mods[0]}" > "$EXT_DIR/$prio-$ext.ini"
    done
  fi
  # The same scan path the unit uses, so the CLI checks below describe FPM.
  export PHP_INI_SCAN_DIR="$CONF_DIR:$EXT_DIR"
}

# "dropin-TAG" serves the packaged php8.5-fpm unit, configuration and Sury
# extensions with only the binary replaced by /opt/php-TAG/sbin/php-fpm
# (build-php-dropin.sh), through a runtime drop-in that a reboot or any
# other arm removes.
DROPIN_DIR=/run/systemd/system/php8.5-fpm.service.d
rm -f "$DROPIN_DIR/zz-bench-dropin.conf"
case $ARM in
  sury)
    UNIT=php8.5-fpm
    BIN=/usr/bin/php8.5
    PHP_ARGS=()
    ;;
  dropin-*)
    TAG=${ARM#dropin-}
    [[ -x /opt/php-$TAG/sbin/php-fpm ]] || { echo "no /opt/php-$TAG/sbin/php-fpm; run build-php-dropin.sh $TAG" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStart=\nExecStart=/opt/php-%s/sbin/php-fpm --nodaemonize --fpm-config /etc/php/8.5/fpm/php-fpm.conf\n' \
      "$TAG" > "$DROPIN_DIR/zz-bench-dropin.conf"
    UNIT=php8.5-fpm
    BIN=/opt/php-$TAG/bin/php
    PHP_ARGS=(-c "$PHP_INI_DIR/php.ini")
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
    prepare_src_scan_dir "$TAG"
    PHP_ARGS=()
    ;;
  ols-*)
    # OpenLiteSpeed + LSAPI.  The handler name matches an extprocessor that
    # install-ols.sh wrote (lsphp85, or lsphp-src-TAG for a source arm, which
    # needs build-php-max.sh's --enable-litespeed lsphp binary).
    case $ARM in
      ols-lsphp)
        HANDLER=lsphp85; BIN=/usr/local/lsws/lsphp85/bin/php
        # LiteSpeed's own extension .ini files stay; the managed settings
        # files are refreshed on every switch, as for the source arms.
        mkdir -p /etc/php-ols/conf.d
        for ini in custom_dan.ini zz-setup-optimize.ini zzz-audit.ini; do
          [[ -f $PHP_INI_DIR/conf.d/$ini ]] && cp -fL "$PHP_INI_DIR/conf.d/$ini" /etc/php-ols/conf.d/
        done
        export PHP_INI_SCAN_DIR=/etc/php-ols/conf.d ;;
      ols-src-*)
        TAG=${ARM#ols-src-}; HANDLER=lsphp-src-$TAG; BIN=/opt/php-$TAG/bin/php
        prepare_src_scan_dir "$TAG" ;;
      *) echo "unknown arm: $ARM" >&2; exit 1 ;;
    esac
    OLS_CONF=/usr/local/lsws/conf/httpd_config.conf
    grep -q "^extprocessor $HANDLER " "$OLS_CONF" \
      || { echo "no extprocessor $HANDLER in $OLS_CONF; run install-ols.sh config" >&2; exit 1; }
    PHP_ARGS=(-c "$PHP_INI_DIR/php.ini")
    UNIT=lshttpd.service
    ;;
  *)
    echo "unknown arm: $ARM" >&2; exit 1 ;;
esac

stop_all
# The drop-in above was written or removed: let systemd see it before start.
systemctl daemon-reload
if [[ $ARM == ols-* ]]; then
  systemctl stop nginx >/dev/null 2>&1 || true
  systemctl stop lshttpd >/dev/null 2>&1 || true
  stop_lsphp
  sed -i -E "s#^([[:space:]]*add[[:space:]]+lsapi:)[^[:space:]]+([[:space:]]+php)#\1$HANDLER\2#" "$OLS_CONF"
  # The LSCache store belongs to the arm that filled it.
  find /var/cache/ols -mindepth 2 -delete 2>/dev/null || true
  systemctl reset-failed lshttpd >/dev/null 2>&1 || true
  systemctl start lshttpd
  PROBE_URL=https://xf.test.local/
else
  if systemctl is-active --quiet lshttpd 2>/dev/null; then
    systemctl stop lshttpd
  fi
  stop_lsphp
  systemctl is-active --quiet nginx || systemctl start nginx
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl start "$UNIT"
  PROBE_URL=https://wp.test.local/
fi

if [[ $ARM != ols-* ]]; then
  for _ in $(seq 1 100); do
    [[ -S $SOCK ]] && break
    sleep 0.2
  done
  [[ -S $SOCK ]] || { systemctl status "$UNIT" --no-pager >&2 || true; echo "$SOCK never appeared" >&2; exit 1; }
fi

# The first request after a switch loads OPcache; wait for a 2xx/3xx.
code=""
for _ in $(seq 1 50); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
           -H 'Cookie: arm-probe=1' "$PROBE_URL" 2>/dev/null || true)
  [[ $code =~ ^[23] ]] && break
  sleep 0.3
done
[[ $code =~ ^[23] ]] || { echo "app answered HTTP ${code:-none} after switching to $ARM" >&2; exit 1; }

# A lean arm (php-fpm-build.sh) has no CLI: its php-fpm reports -v/-m too.
if [[ ! -x $BIN && -n ${TAG:-} && -x /opt/php-$TAG/sbin/php-fpm ]]; then
  BIN=/opt/php-$TAG/sbin/php-fpm
fi
printf '== arm %s (%s)\n' "$ARM" "$UNIT"
"$BIN" "${PHP_ARGS[@]}" -v | head -1
printf 'modules: '
"$BIN" "${PHP_ARGS[@]}" -m 2>/dev/null | tr '\n' ' '
echo
"$BIN" "${PHP_ARGS[@]}" -r 'printf("ini=%s\n", php_ini_loaded_file()); printf("scan=%s\n", php_ini_scanned_files());' 2>/dev/null || true
