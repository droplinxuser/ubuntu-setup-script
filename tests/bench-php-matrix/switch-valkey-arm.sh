#!/usr/bin/env bash
# Put one Valkey binary behind the applications and prove it is serving.
#
# Usage: switch-valkey-arm.sh pkg|build|src-TAG
#   pkg      the packaged /usr/bin/valkey-server
#   build    the SETUP_VALKEY_BUILD=clang build setup.sh installed (valkey-build.sh)
#   src-TAG  /opt/valkey-TAG/valkey-server (a prototype build)
#
# Same configuration, unit, socket and user for every arm; only the binary
# systemd starts changes, through a runtime drop-in
# (/run/systemd/system/valkey-server.service.d), so a reboot always returns
# to the package.  bench-php-sources.sh takes it as SWITCH=.
set -Eeuo pipefail
export LC_ALL=C

ARM=${1:?usage: switch-valkey-arm.sh pkg|build|src-TAG}
UNIT=valkey-server
DROPIN_DIR=/run/systemd/system/$UNIT.service.d
DROPIN=$DROPIN_DIR/zz-bench-valkey.conf
TOOL=/usr/local/lib/setup-valkey/valkey-build.sh
SOCK=/run/valkey/valkey.sock

exec_line() { # binary: the package unit's ExecStart with another binary
  local unit=/usr/lib/systemd/system/$UNIT.service
  grep -m1 '^ExecStart=' "$unit" | sed -E "s#^ExecStart=[^ ]+#ExecStart=$1#"
}

case $ARM in
  pkg)
    rm -f "$DROPIN"
    [[ -f /etc/systemd/system/$UNIT.service.d/zz-setup-build.conf && -x $TOOL ]] && "$TOOL" deactivate >/dev/null 2>&1 ;;
  build)
    rm -f "$DROPIN"
    [[ -x $TOOL ]] || { echo "no $TOOL" >&2; exit 1; }
    [[ -f /etc/systemd/system/$UNIT.service.d/zz-setup-build.conf ]] || "$TOOL" activate >/dev/null ;;
  src-*)
    BIN=/opt/valkey-${ARM#src-}/valkey-server
    [[ -x $BIN ]] || { echo "no $BIN" >&2; exit 1; }
    mkdir -p "$DROPIN_DIR"
    # The unit allows execution only from ExecPaths= (NoExecPaths=/): add
    # the build to that list or systemd answers "Permission denied".
    printf '[Service]\nExecPaths=%s\nExecStart=\n%s\n' "$BIN" "$(exec_line "$BIN")" > "$DROPIN" ;;
  *) echo "unknown arm $ARM" >&2; exit 1 ;;
esac

systemctl daemon-reload
systemctl restart "$UNIT"
for _ in $(seq 1 50); do
  [[ $(valkey-cli -s "$SOCK" ping 2>/dev/null) == PONG ]] && break
  sleep 0.1
done
[[ $(valkey-cli -s "$SOCK" ping 2>/dev/null) == PONG ]] || { echo "valkey did not answer for $ARM" >&2; exit 1; }
pid=$(systemctl show -p MainPID --value "$UNIT")
echo "$ARM serving: $(readlink -f "/proc/$pid/exe") ($(valkey-cli -s "$SOCK" info server | sed -nE 's/^valkey_version:(.*)\r?$/\1/p' | tr -d '\r'))"
