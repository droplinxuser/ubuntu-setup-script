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
#   MIN_FREE_MB=6144             free space needed on / (the source builds
#                                need about 6 GB; less than 2048 always refuses)
#   DETACH=0                     run --optimize in this session instead of as
#                                the transient unit setup-fleet-optimize
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
#   * a pending reboot is reported, not performed unless REBOOT=1;
#   * --optimize runs as its own transient unit (systemd-run) with its output
#     appended to the optimize log, so a dropped SSH session cannot stop the
#     1.22 source builds or a service cutover half way.  This script only
#     follows the log; re-attach with `tail -f` on that log.

set -Eeuo pipefail

REF=${REF:-main}
FORCE_SNAPD_PURGE=${FORCE_SNAPD_PURGE:-0}
SKIP_APT=${SKIP_APT:-0}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-0}
REBOOT=${REBOOT:-0}
MIN_FREE_MB=${MIN_FREE_MB:-6144}
DETACH=${DETACH:-1}
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
# 1.22 compiles nginx, every PHP version and Valkey on the host (LLVM, the
# source trees and the staged builds): the build tools refuse below 6 GB on
# the cache filesystem and 2 GB on /, and an apt upgrade on a nearly full /
# can leave dpkg half-configured.  2 GiB stays the hard floor; MIN_FREE_MB
# raises it (default 6 GiB) so a rollout does not start what cannot finish.
[[ $MIN_FREE_MB =~ ^[0-9]+$ ]] || MIN_FREE_MB=6144
(( MIN_FREE_MB >= 2048 )) || MIN_FREE_MB=2048
avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
if [[ $avail_kb =~ ^[0-9]+$ ]] && (( avail_kb < MIN_FREE_MB * 1024 )); then
  echo "less than ${MIN_FREE_MB} MiB free on / (${avail_kb} KiB); refusing to upgrade (MIN_FREE_MB overrides, never below 2048)" >&2
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
# The dry run prints the 1.22 migration plan (parts, refusals, cutover
# windows) and the build plan; it changes nothing.
bash setup.sh --optimize --dry-run 2>&1 | tee "$DRY_LOG"
if [[ ! -f /usr/local/lib/setup-nginx/build/build.info ]]; then
  echo "Note: no compiled nginx yet: the first 1.22 --optimize builds LLVM, nginx, PHP and Valkey from source (typically 20-60 min); the sites keep serving until each cutover."
fi
if (( DRY_RUN_ONLY == 1 )); then
  say "DRY_RUN_ONLY=1: stopping after the dry run"
  echo "Review ${DRY_LOG}, then run again without DRY_RUN_ONLY (SKIP_APT=1)."
  exit 0
fi
say "Optimize"
# Long builds and the service cutovers must survive a dropped session (R20,
# R50): with systemd, --optimize runs as the transient unit
# setup-fleet-optimize-<stamp> and appends to OPT_LOG; this shell only follows
# the log.  If the session drops, the unit keeps running and this script
# simply ends (no reboot is attempted).  The unit's exit status becomes
# this step's status.
if (( DETACH == 1 )) && command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  OPT_UNIT="setup-fleet-optimize-${STAMP}"
  install -m 600 /dev/null "$OPT_LOG"
  echo "Running as ${OPT_UNIT}; follow it with: tail -f ${OPT_LOG}"
  tail -n +1 -F "$OPT_LOG" 2>/dev/null &
  tail_pid=$!
  opt_rc=0
  # A transient unit does not inherit this shell's environment: pass on the
  # setup.sh knobs an operator exported for this rollout.
  setenv_args=()
  while IFS= read -r name; do
    setenv_args+=("--setenv=${name}=${!name}")
  done < <(compgen -e | grep -E '^(SETUP_[A-Z0-9_]+|CONFIG_REPO_(REF|URL)|CONFIG_SOURCE_DIR)$' || true)
  systemd-run --unit="$OPT_UNIT" --collect --wait --quiet \
    --working-directory="$WORKDIR" "${setenv_args[@]}" \
    -p "StandardOutput=append:${OPT_LOG}" -p "StandardError=append:${OPT_LOG}" \
    /bin/bash "${WORKDIR}/setup.sh" --optimize || opt_rc=$?
  sleep 1
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  if (( opt_rc != 0 )); then
    echo "setup.sh --optimize failed (exit ${opt_rc}); see ${OPT_LOG}" >&2
    exit "$opt_rc"
  fi
else
  bash setup.sh --optimize 2>&1 | tee "$OPT_LOG"
fi

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
