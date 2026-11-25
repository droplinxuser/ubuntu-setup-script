#!/usr/bin/env bash
# Remove the Anubis bot filter that setup.sh 1.21.61 and older could install
# with `--angie anubis=yes` / `--optimize anubis=yes`.
#
# Anubis support was removed in 1.21.62.  A host that still runs it has every
# vhost listening on a Unix socket with a generated TLS terminator in front,
# so setup.sh refuses to run on it: deleting the filter first would leave the
# vhosts on a socket nothing listens on.  This script performs that one-way
# migration, in the order that never takes a site down:
#
#   1. restore every vhost from its pre-integration copy
#      (/var/lib/setup.sh/anubis/vhosts/*.orig),
#   2. remove the generated terminator/common/static/njs files,
#   3. `angie -t` (or `nginx -t`) and a graceful reload, so the vhosts are
#      back on 443 with the web server itself terminating TLS while the
#      filter is still running,
#   4. stop and disable the service, and (with --purge) delete the binary,
#      its configuration, user and group,
#   5. drop ANUBIS=1 from /etc/default/setup-tuning and move the state tree
#      to /tmp (nothing is ever deleted, per the file-safety policy).
#
# A vhost whose .orig copy is missing is left untouched and reported: the
# script does not guess what its direct-TLS listener looked like.  Nothing is
# stopped until the web server has loaded the restored tree.
#
# Anubis was only ever integrated into the Angie tree (/etc/angie, socket
# /run/angie/anubis-backend.sock, angie.service), and setup.sh 1.22 refuses
# to migrate a host that still runs it, so this script normally works on
# Angie and must run BEFORE the 1.22 migration.  A tree that was carried to
# /etc/nginx by hand is handled the same way with the compiled nginx.
#
# Usage:
#   sudo bash tools/remove-anubis.sh [--purge] [--dry-run]
#
#   --purge    also remove /usr/local/bin/anubis, /etc/anubis, the systemd
#              unit, the tmpfiles drop-in and the anubis user/group
#   --dry-run  print the plan and change nothing

set -uo pipefail
export LC_ALL=C

STATE_DIR=${SETUP_STATE_DIR:-/var/lib/setup.sh}
README_MARK='setup.sh: Anubis removed'

DRY=0
PURGE=0
for arg in "$@"; do
  case $arg in
    --purge)   PURGE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
run() {
  if (( DRY )); then printf '[dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

(( EUID == 0 )) || die "run as root (sudo bash tools/remove-anubis.sh)"

# Pick the tree the integration lives in: Angie's unless only an /etc/nginx
# copy carries it.  WEB_BIN is the binary that validates and WEB_UNIT the
# service that reloads it.
anubis_in_tree() { # NAME (angie|nginx)
  local n=$1
  [[ -e /etc/${n}/conf.d/00-anubis-terminators.conf || -e /etc/${n}/snippets/anubis-location.conf \
     || -e /etc/tmpfiles.d/${n}-anubis.conf ]] && return 0
  find "/etc/${n}/conf.d" -maxdepth 1 -type f -name '*.conf' \
    -exec grep -lF "unix:/run/${n}/anubis-backend.sock" {} + 2>/dev/null | grep -q .
}
WEB=angie
if ! anubis_in_tree angie && anubis_in_tree nginx; then
  WEB=nginx
fi
if [[ $WEB == angie ]]; then
  WEB_BIN=/usr/sbin/angie
  WEB_UNIT=angie
else
  WEB_BIN=${NGINX_BIN:-/usr/local/lib/setup-nginx/sbin/nginx}
  [[ -x $WEB_BIN ]] || WEB_BIN=/usr/sbin/nginx
  WEB_UNIT=nginx
fi
WEB_ETC=/etc/${WEB}
CONF_DIR=${WEB_ETC}/conf.d
SOCK="unix:/run/${WEB}/anubis-backend.sock"
STATE="${STATE_DIR}/anubis"
MARKER="${STATE}/enabled"
ORIG_DIR="${STATE}/vhosts"
GENERATED=(
  "${CONF_DIR}/00-anubis-terminators.conf"
  "${CONF_DIR}/00-anubis-common.conf"
  "${CONF_DIR}/00-anubis-static.conf"
  "${WEB_ETC}/snippets/anubis-location.conf"
  "${WEB_ETC}/njs/anubis_pass.js"
  "${WEB_ETC}/modules-enabled/60-anubis-njs.conf"
  "${WEB_ETC}/ssl/anubis/pass-key.conf"
  "/etc/tmpfiles.d/${WEB}-anubis.conf"
)

managed=0
[[ -e $MARKER ]] && managed=1
for f in "${GENERATED[@]}"; do [[ -e $f ]] && managed=1; done

if (( ! managed )); then
  say "No managed Anubis integration found on this host; nothing to do."
  say "A hand-installed Anubis was never managed by setup.sh and is left alone."
  exit 0
fi

say "Anubis teardown plan$( (( DRY )) && printf ' (dry run)')"
say "- state:      ${STATE}"
say "- vhosts:     restored from ${ORIG_DIR}"
say "- web server: ${WEB} (${WEB_ETC}, ${WEB_BIN}, ${WEB_UNIT}.service)"
say "- generated:  ${#GENERATED[@]} file(s) under ${WEB_ETC} and /etc/tmpfiles.d"
say "- service:    stop and disable anubis.service"
(( PURGE )) && say "- purge:      binary, /etc/anubis, unit, user and group removed"
say ""

# ---------------------------------------------------------------------------
# 1. Restore every vhost that is still integrated.
# ---------------------------------------------------------------------------
mapfile -t live < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' \
  -exec grep -lF "$SOCK" {} + 2>/dev/null | sort)
restored=0
failed=0
for f in "${live[@]}"; do
  name=${f##*/}
  orig="${ORIG_DIR}/${name}.orig"
  if [[ ! -f $orig ]]; then
    warn "${name} is still behind the filter but ${orig} is missing."
    warn "  Restore its public listener by hand (it must listen on 443 again),"
    warn "  then delete ${f}'s unix: listener and re-run this script."
    failed=$((failed + 1))
    continue
  fi
  # A vhost edited while Anubis was enabled keeps the operator's changes in
  # a copy next to the backup, so nothing is lost.
  if ! cmp -s "$f" "$orig"; then
    stamp=$(date +%Y%m%d%H%M%S)
    if (( ! DRY )); then
      cp -a "$f" "${STATE}/${name}.integrated.${stamp}" 2>/dev/null || true
    fi
    say "  preserved the integrated ${name} as ${STATE}/${name}.integrated.${stamp}"
  fi
  if run cp -a "$orig" "$f"; then
    run chown root:root "$f"
    run chmod 644 "$f"
    restored=$((restored + 1))
    say "  restored ${name}"
  else
    warn "could not restore ${name}"
    failed=$((failed + 1))
  fi
done

if (( failed )); then
  die "refusing to continue with ${failed} vhost(s) unresolved: stopping the filter now would take those sites down. Nothing was stopped."
fi
if (( restored == 0 && ${#live[@]} > 0 )); then
  warn "no vhost was restored"
fi
say "- restored ${restored} vhost(s)"

# ---------------------------------------------------------------------------
# 2. Remove the generated web server files (moved aside, never unlinked).
# ---------------------------------------------------------------------------
retired=0
for f in "${GENERATED[@]}"; do
  [[ -e $f ]] || continue
  if (( DRY )); then
    printf '[dry-run] move %s to /tmp\n' "$f"
  else
    dest=$(mktemp -d /tmp/anubis-teardown.XXXXXX)/"${f//\//_}"
    mkdir -p "$(dirname "$dest")"
    if mv -- "$f" "$dest" 2>/dev/null; then
      say "  moved ${f} to ${dest}"
      retired=$((retired + 1))
    else
      warn "could not move ${f}"
      failed=$((failed + 1))
    fi
  fi
done
say "- removed ${retired} generated file(s)"

# ---------------------------------------------------------------------------
# 3. Validate and reload the web server while the filter is still running.
# ---------------------------------------------------------------------------
if (( ! DRY )); then
  [[ -x $WEB_BIN ]] || die "${WEB_BIN} is missing; cannot validate the restored tree. anubis.service was NOT stopped."
  # mktemp, not a fixed /tmp name: root must not write through a link
  # another user planted there.
  test_log=$(mktemp /tmp/anubis-teardown-test.XXXXXX) || die "could not create a temp file"
  if ! "$WEB_BIN" -t >"$test_log" 2>&1; then
    warn "${WEB} -t rejected the restored tree:"
    sed -n '1,40p' "$test_log" >&2
    die "the generated files are already moved to /tmp; restore the ones named above before stopping the filter. anubis.service was NOT stopped."
  fi
  if systemctl is-active --quiet "$WEB_UNIT"; then
    systemctl reload "$WEB_UNIT" || die "${WEB_UNIT} reload failed; anubis.service was NOT stopped"
    say "- ${WEB} -t OK, reloaded: vhosts answer on 443 directly again"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Stop the filter.
# ---------------------------------------------------------------------------
if systemctl list-unit-files anubis.service >/dev/null 2>&1 \
   && systemctl cat anubis.service >/dev/null 2>&1; then
  run systemctl stop anubis
  run systemctl disable anubis
  say "- anubis.service stopped and disabled"
else
  say "- no anubis.service unit installed"
fi
# www-data no longer needs the socket group.
if id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx anubis; then
  run gpasswd -d www-data anubis
  say "- www-data removed from the anubis group"
fi

if (( PURGE )); then
  if (( DRY )); then
    printf '[dry-run] rm /etc/systemd/system/anubis.service /usr/local/bin/anubis; rm -rf /etc/anubis /var/lib/anubis /var/cache/anubis; userdel/groupdel anubis\n'
  else
    rm -f /etc/systemd/system/anubis.service /usr/local/bin/anubis
    rm -rf /etc/anubis /var/lib/anubis /var/cache/anubis
    systemctl daemon-reload
    if id anubis >/dev/null 2>&1; then userdel anubis 2>/dev/null || true; fi
    if getent group anubis >/dev/null 2>&1; then groupdel anubis 2>/dev/null || true; fi
    say "- purged the binary, /etc/anubis, the unit, the user and the group"
  fi
fi

# ---------------------------------------------------------------------------
# 5. State: drop ANUBIS=1/ANUBIS_STATIC_BYPASS from the pin file, move the
#    state tree aside so an install run cannot find a stale marker.
# ---------------------------------------------------------------------------
PIN=/etc/default/setup-tuning
if [[ -f $PIN ]] && grep -qE '^(ANUBIS|ANUBIS_STATIC_BYPASS)=' "$PIN"; then
  if (( DRY )); then
    printf '[dry-run] drop ANUBIS pins from %s\n' "$PIN"
  else
    cp -a "$PIN" "/tmp/setup-tuning.anubis.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    tmp=$(mktemp)
    grep -vE '^(ANUBIS|ANUBIS_STATIC_BYPASS)=' "$PIN" >"$tmp" || true
    if [[ -s $tmp ]]; then
      install -m 644 "$tmp" "$PIN"
    else
      rm -f "$PIN"
    fi
    rm -f "$tmp"
    say "- dropped the ANUBIS pins from ${PIN}"
  fi
fi

if [[ -e $STATE ]]; then
  if (( DRY )); then
    printf '[dry-run] move %s to /tmp\n' "$STATE"
  else
    dest=$(mktemp -d /tmp/anubis-state.XXXXXX)
    mv -- "$STATE" "$dest"/ && say "- state moved to ${dest}"
  fi
fi

if (( DRY )); then
  say ""
  say "Dry run: nothing was changed."
  exit 0
fi

say ""
say "Done. Every site now terminates TLS in ${WEB} again; nothing sits in front"
say "of it.  Put Cloudflare (or another CDN/WAF) in front of the origin for bot"
say "filtering, then run 'sudo bash setup.sh --optimize' to apply the current"
say "profile (on an Angie host that run also migrates it to the compiled nginx)."
say "${README_MARK}."
