#!/usr/bin/env bash
# Put one nginx binary in front of the sites and prove it is serving.
#
# Usage: switch-nginx-arm.sh pkg|build|src-TAG
#   pkg      the packaged /usr/sbin/nginx with its dynamic Brotli module
#   build    the SETUP_NGINX_BUILD=clang build setup.sh installed (nginx-build.sh)
#   src-TAG  /opt/nginx-TAG/sbin/nginx (Brotli compiled in), started with
#            a copy of nginx.conf that skips modules-enabled/
#   nginx-TAG /opt/nginx-TAG/sbin/nginx (built with the same flags, libraries
#            and modules) on /etc/nginx-ng: a copy of the live tree without
#            the nginx package's three nginx-only pieces (the http.d/
#            default.conf status `api` location, $upstream_request_method
#            and $nginx_version in fastcgi.conf -> $request_method and
#            $nginx_version); the server-configs-nginx tree itself has none
#   ngtree-TAG /opt/nginx-TAG/sbin/nginx on the same /etc/nginx-ng, so an
#            nginx vs nginx A/B compares binaries on identical files (1.21.71)
#
# The switch is a runtime drop-in (/run/systemd/system/nginx.service.d), so
# a reboot always returns to the package.  For the PHP side see
# switch-php-arm.sh; bench-php-sources.sh takes either (SWITCH=).
set -Eeuo pipefail
export LC_ALL=C

ARM=${1:?usage: switch-nginx-arm.sh pkg|build|src-TAG|nginx-TAG|ngtree-TAG}
DROPIN_DIR=/run/systemd/system/nginx.service.d
DROPIN=$DROPIN_DIR/zz-bench-nginx.conf
SRC_CONF=/etc/nginx/nginx-bench-src.conf

TOOL=/usr/local/lib/setup-nginx/nginx-build.sh
case $ARM in
  pkg)
    rm -f "$DROPIN" "$SRC_CONF"
    # The installed NGINX_BUILD (if any) steps aside too.
    [[ -f /etc/systemd/system/nginx.service.d/zz-setup-build.conf && -x $TOOL ]] && "$TOOL" deactivate >/dev/null 2>&1 ;;
  build)
    # SETUP_NGINX_BUILD=clang as installed by setup.sh (BOLT included).
    rm -f "$DROPIN" "$SRC_CONF"
    [[ -x $TOOL ]] || { echo "no $TOOL" >&2; exit 1; }
    [[ -f /etc/systemd/system/nginx.service.d/zz-setup-build.conf ]] || "$TOOL" activate >/dev/null ;;
  nginx-*|ngtree-*)
    TAG=${ARM#*-}
    BIN=/opt/nginx-$TAG/sbin/nginx
    [[ $ARM == nginx-* ]] && BIN=/opt/nginx-$TAG/sbin/nginx
    [[ -x $BIN ]] || { echo "no $BIN" >&2; exit 1; }
    NG=/etc/nginx-ng
    rm -rf "$NG"; cp -a /etc/nginx "$NG"
    rm -f "$NG/http.d/default.conf" "$NG/nginx-bench-src.conf"
    grep -rlF '/etc/nginx/' "$NG" --include='*.conf' | xargs -r sed -i 's|/etc/nginx/|/etc/nginx-ng/|g' || true
    # shellcheck disable=SC2016 # nginx/nginx variables, not shell ones
    sed -i 's/\$upstream_request_method/$request_method/; s|nginx/\$nginx_version|nginx/$nginx_version|' "$NG/fastcgi.conf"
    sed -E -i 's|^[[:space:]]*include[[:space:]]+/etc/nginx-ng/modules-enabled/\*\.conf;|# (bench) modules compiled in|' "$NG/nginx.conf"
    "$BIN" -t -q -c "$NG/nginx.conf" || { echo "$BIN rejects $NG" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\nExecStart=\nExecStart=%s -c %s\n' "$BIN" "$NG/nginx.conf" > "$DROPIN" ;;
  src-*)
    TAG=${ARM#src-}
    BIN=/opt/nginx-$TAG/sbin/nginx
    [[ -x $BIN ]] || { echo "no $BIN" >&2; exit 1; }
    sed -E 's|^[[:space:]]*include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf;|# (bench) modules compiled in|' \
      /etc/nginx/nginx.conf > "$SRC_CONF"
    "$BIN" -t -q -c "$SRC_CONF" || { echo "$BIN rejects the configuration" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStartPre=\nExecStart=\nExecStart=%s -c %s\n' "$BIN" "$SRC_CONF" > "$DROPIN" ;;
  *) echo "unknown arm $ARM" >&2; exit 1 ;;
esac

systemctl daemon-reload
systemctl restart nginx
for _ in $(seq 1 50); do
  systemctl is-active -q nginx && break
  sleep 0.1
done
systemctl is-active -q nginx || { echo "nginx did not start for $ARM" >&2; exit 1; }
exe=$(readlink -f "/proc/$(cat /run/nginx.pid)/exe")
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://xf.test.local/ || true)
[[ $code == 200 ]] || { echo "$ARM: https://xf.test.local/ answered $code" >&2; exit 1; }
echo "$ARM serving: $exe"
