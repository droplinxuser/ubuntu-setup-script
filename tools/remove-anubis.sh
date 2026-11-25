#!/usr/bin/env bash
# Remove the Anubis bot filter that setup.sh 1.21.61 and older could install
# with `--nginx anubis=yes` / `--optimize anubis=yes`.
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
#   3. `nginx -t` and a graceful reload, so the vhosts are back on 443 with
#      nginx itself terminating TLS while the filter is still running,
#   4. stop and disable the service, and (with --purge) delete the binary,
#      its configuration, user and group,
#   5. drop ANUBIS=1 from /etc/default/setup-tuning and move the state tree
#      to /tmp (nothing is ever deleted, per the file-safety policy).
#
# A vhost whose .orig copy is missing is left untouched and reported: the
# script does not guess what its direct-TLS listener looked like.  Nothing is
# stopped until nginx has loaded the restored tree.
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

CONF_DIR=/etc/nginx/conf.d
STATE="${STATE_DIR}/anubis"
MARKER="${STATE}/enabled"
ORIG_DIR="${STATE}/vhosts"
GENERATED=(
  "${CONF_DIR}/00-anubis-terminators.conf"
  "${CONF_DIR}/00-anubis-common.conf"
  "${CONF_DIR}/00-anubis-static.conf"
  /etc/nginx/snippets/anubis-location.conf
  /etc/nginx/njs/anubis_pass.js
  /etc/nginx/modules-enabled/60-anubis-njs.conf
  /etc/nginx/ssl/anubis/pass-key.conf
  /etc/tmpfiles.d/nginx-anubis.conf
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
say "- generated:  ${#GENERATED[@]} file(s) under /etc/nginx and /etc/tmpfiles.d"
say "- service:    stop and disable anubis.service"
(( PURGE )) && say "- purge:      binary, /etc/anubis, unit, user and group removed"
say ""

# ---------------------------------------------------------------------------
# 1. Restore every vhost that is still integrated.
# ---------------------------------------------------------------------------
mapfile -t live < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' \
  -exec grep -lF 'unix:/run/nginx/anubis-backend.sock' {} + 2>/dev/null | sort)
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
# 2. Remove the generated nginx files (moved aside, never unlinked).
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
# 3. Validate and reload nginx while the filter is still running.
# ---------------------------------------------------------------------------
if (( ! DRY )); then
  if ! /usr/sbin/nginx -t >/tmp/anubis-teardown-nginx-t.log 2>&1; then
    warn "nginx -t rejected the restored tree:"
    sed -n '1,40p' /tmp/anubis-teardown-nginx-t.log >&2
    die "the generated files are already moved to /tmp; restore the ones named above before stopping the filter. anubis.service was NOT stopped."
  fi
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx || die "nginx reload failed; anubis.service was NOT stopped"
    say "- nginx -t OK, reloaded: vhosts answer on 443 directly again"
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
say "Done. Every site now terminates TLS in nginx again; nothing sits in front"
say "of it.  Put Cloudflare (or another CDN/WAF) in front of the origin for bot"
say "filtering, then run 'sudo bash setup.sh --optimize' to apply the current"
say "profile.  ${README_MARK}."
