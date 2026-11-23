#!/usr/bin/env bash
# Pin the CPU clock ceiling for A/B benchmarks, and restore it.
#
# Turbo is power-limited, not thermal: the Xeon E-2236 test host runs a
# member-page load at 4.5 GHz while its PL2 window (112 W) lasts and drops to
# 4.1 GHz on PL1 (80 W) - after a long cached tier it sits lower still.  PHP
# CPU per request follows the clock 1:1, so two runs minutes apart differed
# by 10-27 % with identical configuration, and a variant that idles the host
# (a hung pool, a pause) hands the next variant a fresh turbo budget.  A
# ceiling below the sustained all-core clock removes that drift.  sysfs only:
# nothing is persisted, a reboot restores the firmware default.
#
# Usage: set-clock.sh MHZ|restore     (e.g. set-clock.sh 3600)
set -Eeuo pipefail
ARG=${1:?MHz or restore}
shopt -s nullglob
files=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq)
(( ${#files[@]} )) || { echo "no cpufreq scaling_max_freq on this host" >&2; exit 1; }
if [[ $ARG == restore ]]; then
  khz=$(< /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
elif [[ $ARG =~ ^[0-9]+$ ]]; then
  khz=$(( ARG * 1000 ))
else
  echo "usage: set-clock.sh MHZ|restore" >&2; exit 2
fi
for f in "${files[@]}"; do printf '%s\n' "$khz" > "$f"; done
# intel_pstate applies the limit asynchronously: an immediate read-back can
# still show the old value, so report what was requested.
printf 'scaling_max_freq <- %s kHz on %d CPUs\n' "$khz" "${#files[@]}"
