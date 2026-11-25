#!/usr/bin/env bash
# Put one Angie binary in front of the sites and prove it is serving.
#
# Usage: switch-angie-arm.sh pkg|build|src-TAG
#   pkg      the packaged /usr/sbin/angie with its dynamic Brotli module
#   build    the SETUP_ANGIE_BUILD=clang build setup.sh installed (angie-build.sh)
#   src-TAG  /opt/angie-TAG/sbin/angie (Brotli compiled in), started with
#            a copy of angie.conf that skips modules-enabled/
#   nginx-TAG /opt/nginx-TAG/sbin/nginx (built with the same flags, libraries
#            and modules) on /etc/angie-ng: a copy of the live tree without
#            the Angie package's three Angie-only pieces (the http.d/
#            default.conf status `api` location, $upstream_request_method
#            and $angie_version in fastcgi.conf -> $request_method and
#            $nginx_version); the server-configs-nginx tree itself has none
#   ngtree-TAG /opt/angie-TAG/sbin/angie on the same /etc/angie-ng, so an
#            Angie vs nginx A/B compares binaries on identical files (1.21.71)
#
# The switch is a runtime drop-in (/run/systemd/system/angie.service.d), so
# a reboot always returns to the package.  For the PHP side see
# switch-php-arm.sh; bench-php-sources.sh takes either (SWITCH=).
set -Eeuo pipefail
export LC_ALL=C

ARM=${1:?usage: switch-angie-arm.sh pkg|build|src-TAG|nginx-TAG|ngtree-TAG}
DROPIN_DIR=/run/systemd/system/angie.service.d
DROPIN=$DROPIN_DIR/zz-bench-angie.conf
SRC_CONF=/etc/angie/angie-bench-src.conf

TOOL=/usr/local/lib/setup-angie/angie-build.sh
case $ARM in
  pkg)
    rm -f "$DROPIN" "$SRC_CONF"
    # The installed ANGIE_BUILD (if any) steps aside too.
    [[ -f /etc/systemd/system/angie.service.d/zz-setup-build.conf && -x $TOOL ]] && "$TOOL" deactivate >/dev/null 2>&1 ;;
  build)
    # SETUP_ANGIE_BUILD=clang as installed by setup.sh (BOLT included).
    rm -f "$DROPIN" "$SRC_CONF"
    [[ -x $TOOL ]] || { echo "no $TOOL" >&2; exit 1; }
    [[ -f /etc/systemd/system/angie.service.d/zz-setup-build.conf ]] || "$TOOL" activate >/dev/null ;;
  nginx-*|ngtree-*)
    TAG=${ARM#*-}
    BIN=/opt/angie-$TAG/sbin/angie
    [[ $ARM == nginx-* ]] && BIN=/opt/nginx-$TAG/sbin/nginx
    [[ -x $BIN ]] || { echo "no $BIN" >&2; exit 1; }
    NG=/etc/angie-ng
    rm -rf "$NG"; cp -a /etc/angie "$NG"
    rm -f "$NG/http.d/default.conf" "$NG/angie-bench-src.conf"
    grep -rlF '/etc/angie/' "$NG" --include='*.conf' | xargs -r sed -i 's|/etc/angie/|/etc/angie-ng/|g' || true
    # shellcheck disable=SC2016 # Angie/nginx variables, not shell ones
    sed -i 's/\$upstream_request_method/$request_method/; s|Angie/\$angie_version|nginx/$nginx_version|' "$NG/fastcgi.conf"
    sed -E -i 's|^[[:space:]]*include[[:space:]]+/etc/angie-ng/modules-enabled/\*\.conf;|# (bench) modules compiled in|' "$NG/angie.conf"
    "$BIN" -t -q -c "$NG/angie.conf" || { echo "$BIN rejects $NG" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\nExecStart=\nExecStart=%s -c %s\n' "$BIN" "$NG/angie.conf" > "$DROPIN" ;;
  src-*)
    TAG=${ARM#src-}
    BIN=/opt/angie-$TAG/sbin/angie
    [[ -x $BIN ]] || { echo "no $BIN" >&2; exit 1; }
    sed -E 's|^[[:space:]]*include[[:space:]]+/etc/angie/modules-enabled/\*\.conf;|# (bench) modules compiled in|' \
      /etc/angie/angie.conf > "$SRC_CONF"
    "$BIN" -t -q -c "$SRC_CONF" || { echo "$BIN rejects the configuration" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\nExecStart=\nExecStart=%s -c %s\n' "$BIN" "$SRC_CONF" > "$DROPIN" ;;
  *) echo "unknown arm $ARM" >&2; exit 1 ;;
esac

systemctl daemon-reload
systemctl restart angie
for _ in $(seq 1 50); do
  systemctl is-active -q angie && break
  sleep 0.1
done
systemctl is-active -q angie || { echo "angie did not start for $ARM" >&2; exit 1; }
exe=$(readlink -f "/proc/$(cat /run/angie.pid)/exe")
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://xf.test.local/ || true)
[[ $code == 200 ]] || { echo "$ARM: https://xf.test.local/ answered $code" >&2; exit 1; }
echo "$ARM serving: $exe"
