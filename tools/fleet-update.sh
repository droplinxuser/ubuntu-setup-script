#!/usr/bin/env bash
# fleet-update.sh - update an Ubuntu host and roll out the current setup.sh.
#
# Usage (as root on the target host):
#   bash fleet-update.sh
#
# Environment:
#   REF=main                     git ref of ubuntu-setup-script to deploy
#   FORCE_SNAPD_PURGE=1          purge snapd even when snap packages exist
#   SKIP_APT=1                   skip the apt phase (retry only setup.sh)
#   DRY_RUN_ONLY=1               stop after the optimize dry run for review
#   REBOOT=1                     reboot at the end when /var/run/reboot-required
#
# Safe by design:
#   * non-interactive APT (confold, lock timeout, retries) and needrestart in
#     list-only mode, so an unattended upgrade cannot hang on a prompt or
#     restart the web stack mid-run;
#   * an existing /root/ubuntu-setup-script is moved to a timestamped backup,
#     never deleted;
#   * the archive is extracted into a fresh tree and setup.sh is verified
#     before it runs;
#   * the full output goes to /root/fleet-update-<timestamp>.log, plus a
#     separate dry-run and optimize log;
#   * a pending reboot is reported, not performed unless REBOOT=1.

set -Eeuo pipefail

REF=${REF:-main}
FORCE_SNAPD_PURGE=${FORCE_SNAPD_PURGE:-0}
SKIP_APT=${SKIP_APT:-0}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-0}
REBOOT=${REBOOT:-0}
STAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR=/root/ubuntu-setup-script
ARCHIVE_URL="https://github.com/droplinxuser/ubuntu-setup-script/archive/refs/heads/${REF}.tar.gz"
LOG="/root/fleet-update-${STAMP}.log"
DRY_LOG="/root/setup-dryrun-${STAMP}.log"
OPT_LOG="/root/setup-optimize-${STAMP}.log"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
export APT_LISTCHANGES_FRONTEND=none
APT_OPTS=(-y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o DPkg::Lock::Timeout=300
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=30)

umask 022
exec > >(tee -a "$LOG") 2>&1
rc=0
trap 'rc=$?; printf "\nFAILED (exit %s) at line %s: %s\nLog: %s\n" \
  "$rc" "$LINENO" "$BASH_COMMAND" "$LOG"; exit "$rc"' ERR
say() { printf '\n=== %s [%s] ===\n' "$*" "$(date +%H:%M:%S)"; }

say "Host and preflight"
[[ ${EUID} -eq 0 ]] || { echo "fleet-update.sh must run as root" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || { echo "not Ubuntu (ID=${ID:-unknown})" >&2; exit 1; }
printf 'Host: %s\nOS  : %s\nKernel: %s\n' "$(hostname)" "${PRETTY_NAME:-unknown}" "$(uname -r)"
avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
if [[ $avail_kb =~ ^[0-9]+$ ]] && (( avail_kb < 2097152 )); then
  echo "less than 2 GiB free on / (${avail_kb} KiB); refusing to upgrade" >&2
  exit 1
fi
say "Logs"
printf 'Full log : %s\nDry run  : %s\nOptimize : %s\n' "$LOG" "$DRY_LOG" "$OPT_LOG"

if (( ! SKIP_APT )); then
  say "Removing snapd (if installed and unused)"
  if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q 'install ok installed'; then
    snap_count=0
    if command -v snap >/dev/null 2>&1; then
      snap_count=$(snap list 2>/dev/null | sed '1d' | wc -l)
    fi
    if (( snap_count > 0 )) && (( FORCE_SNAPD_PURGE != 1 )); then
      echo "snapd is in use by ${snap_count} snap package(s); skipping."
      echo "Set FORCE_SNAPD_PURGE=1 to purge it and those packages anyway."
    else
      apt-get "${APT_OPTS[@]}" purge snapd
    fi
  else
    echo "snapd is not installed"
  fi

  say "APT update"
  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update
  say "APT upgrade"
  apt-get "${APT_OPTS[@]}" upgrade
  say "APT dist-upgrade"
  apt-get "${APT_OPTS[@]}" dist-upgrade
  say "APT autoremove --purge"
  apt-get "${APT_OPTS[@]}" autoremove --purge
  say "APT autoclean"
  apt-get -o DPkg::Lock::Timeout=300 autoclean
  say "APT clean"
  apt-get -o DPkg::Lock::Timeout=300 clean
  say "systemd daemon-reload"
  systemctl daemon-reload
else
  say "SKIP_APT=1: skipping the apt phase"
fi

say "Fetching setup.sh (${REF})"
# Download and unpack into a staging directory first: the previous checkout
# is moved aside only once the new one is complete, so a failed or truncated
# fetch never leaves $WORKDIR empty or half-extracted.
STAGE=$(mktemp -d "${WORKDIR}.new.XXXXXX")
ARCHIVE=$(mktemp /tmp/setup-sh-src.XXXXXX.tgz)
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$ARCHIVE" "$ARCHIVE_URL"
else
  wget -q --tries=3 --timeout=30 -O "$ARCHIVE" "$ARCHIVE_URL"
fi
tar -tzf "$ARCHIVE" >/dev/null || { echo "downloaded archive is not a valid tar.gz: $ARCHIVE" >&2; exit 1; }
tar -xzf "$ARCHIVE" --strip-components=1 -C "$STAGE"
[[ -f ${STAGE}/setup.sh && -f ${STAGE}/lib/common.sh ]] \
  || { echo "archive did not contain setup.sh and lib/ (staged at $STAGE)" >&2; exit 1; }
if [[ -e $WORKDIR ]]; then
  mv -- "$WORKDIR" "${WORKDIR}.${STAMP}"
  echo "Previous checkout kept at ${WORKDIR}.${STAMP}"
fi
mv -- "$STAGE" "$WORKDIR"
chmod 755 "$WORKDIR"
echo "Deployed: $(grep -m1 '^readonly SCRIPT_VERSION=' "${WORKDIR}/setup.sh" || true)"
cd "$WORKDIR"

say "Optimize dry run"
bash setup.sh --optimize --dry-run 2>&1 | tee "$DRY_LOG"
if (( DRY_RUN_ONLY == 1 )); then
  say "DRY_RUN_ONLY=1: stopping after the dry run"
  echo "Review ${DRY_LOG}, then run again without DRY_RUN_ONLY (SKIP_APT=1)."
  exit 0
fi
say "Optimize"
bash setup.sh --optimize 2>&1 | tee "$OPT_LOG"

say "Summary"
systemctl --failed --no-legend || true
if [[ -f /var/run/reboot-required ]]; then
  echo "REBOOT REQUIRED: $(tr '\n' ' ' < /var/run/reboot-required 2>/dev/null || echo yes)"
else
  echo "No reboot required"
fi
printf 'Disk /: '; df -h / | awk 'NR==2{print $3 " used of " $2 " (" $5 ")"}'
cd /root
ls -la

if [[ -f /var/run/reboot-required ]] && (( REBOOT == 1 )); then
  say "Rebooting"
  systemctl reboot
fi
