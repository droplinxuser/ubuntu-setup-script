#!/usr/bin/env bash
# Unit tests for the 1.22.5 CPU mitigations default: mitigations=off is
# applied on every --basic and --optimize (managed GRUB drop-in, boot menu
# checked, reboot reported while the running kernel lacks it), still skipped
# in containers and without GRUB, mitigations=on / SETUP_CPU_MITIGATIONS=on
# refused, a persisted CPU_MITIGATIONS=on moved to off, and --purge basic
# still removing the drop-in.
# No root, no services and no system changes are required: the GRUB files,
# update-grub, /proc/cmdline and the tuning file are stand-ins under /tmp.
# Usage: bash tests/unit/t-mitigations.sh
# The suites assign globals the sourced helpers read; ShellCheck cannot
# follow that across the source boundary.  The stubs are called indirectly.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

# tests/test-tuning.sh sources every unit file in a subshell after it has
# sourced setup.sh itself; setup.sh cannot be sourced twice, so run this
# file in a fresh shell instead.
if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-mitigations.XXXXXX)

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
unset SETUP_CPU_MITIGATIONS
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR
set +e

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-mitigations.sh,title=Mitigations test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

ALL_SRC_FILE=$TMP/all-source.sh
cat "$ROOT/setup.sh" "$ROOT"/lib/*.sh > "$ALL_SRC_FILE"

# ---------------------------------------------------------------------------
# Fake boot loader: everything under $TMP/boot
# ---------------------------------------------------------------------------
B=$TMP/boot
mkdir -p "$B/grub.d"
: > "$B/grub"
# mit WHAT [persisted] -> runs configure_cpu_mitigations in a subshell with
# stand-ins and prints "<drop-in 0/1> <update-grub calls>".  WHAT:
#   ok         GRUB present, update-grub writes the menu from the drop-in
#   live       the same, and the running kernel already has mitigations=off
#   container  host_is_container is true
#   nogrub     no /etc/default/grub
#   fail       update-grub fails
# The report (NOTE/WARN/INFO lines) goes to $B/report, the tuning file is
# $B/setup-tuning.
mit() {
  (
    MODE=$1
    CPU_MITIGATIONS=${2:-} CPU_MITIGATIONS_SETTING="" CPU_MITIGATIONS_RETIRED_ON=${3:-0}
    CPU_MITIGATIONS_DROPIN=$B/grub.d/zz-setup-mitigations.cfg
    CPU_MITIGATIONS_LEGACY_DROPIN=$B/grub.d/99-setup-mitigations.cfg
    CPU_MITIGATIONS_GRUBCFG=$B/grub.cfg
    CPU_MITIGATIONS_GRUB_DEFAULT=$B/grub
    [[ $MODE == nogrub ]] && CPU_MITIGATIONS_GRUB_DEFAULT=$B/missing-grub
    SETUP_TUNING_FILE=$B/setup-tuning
    OPTIMIZE=1
    host_is_container() { [[ $MODE == container ]]; }
    cpu_mitigations_live_off() { [[ $MODE == live ]]; }
    opt_report() { printf 'REPORT %s\n' "$*" >> "$B/report"; }
    harden_note() { printf 'NOTE %s\n' "$*" >> "$B/report"; }
    harden_warn() { printf 'WARN %s\n' "$*" >> "$B/report"; }
    info() { printf 'INFO %s\n' "$*" >> "$B/report"; }
    warn() { printf 'WARNING %s\n' "$*" >> "$B/report"; }
    update-grub() {
      printf x >> "$B/calls"
      [[ $MODE == fail ]] && return 1
      if [[ -f $CPU_MITIGATIONS_DROPIN ]]; then
        printf '\tlinux /vmlinuz root=x ro mitigations=off\n' > "$CPU_MITIGATIONS_GRUBCFG"
      else
        printf '\tlinux /vmlinuz root=x ro\n' > "$CPU_MITIGATIONS_GRUBCFG"
      fi
    }
    configure_cpu_mitigations >/dev/null 2>&1
    printf '%s %s' "$([[ -f $CPU_MITIGATIONS_DROPIN ]] && echo 1 || echo 0)" "$(wc -c < "$B/calls" | tr -d ' ')"
  )
}
reset_boot() {
  rm -f "$B/grub.d/"* "$B/grub.cfg" "$B/setup-tuning"
  : > "$B/calls"; : > "$B/report"
}

# (1) unset = off by default
reset_boot
check "1: an unset CPU_MITIGATIONS writes the drop-in and runs update-grub once" test "$(mit ok)" = "1 1"
check "1: the drop-in adds mitigations=off and keeps the provider options" \
  bash -c 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"; . "$1"; [[ $GRUB_CMDLINE_LINUX_DEFAULT == "console=ttyS0 mitigations=off" ]]' _ "$B/grub.d/zz-setup-mitigations.cfg"
check "1: the generated menu carries mitigations=off" grep -q "mitigations=off" "$B/grub.cfg"
check "1: the report says a reboot is needed while /proc/cmdline lacks it" \
  grep -q "^NOTE - CPU mitigations: off at the next reboot (reboot needed" "$B/report"
check "1: the run also prints the reboot hint" grep -q "^INFO CPU mitigations: reboot to apply mitigations=off" "$B/report"
check "1: an unset choice persists nothing (off is the default)" test ! -e "$B/setup-tuning"
: > "$B/report"
check "1: a second run changes nothing (no update-grub)" test "$(mit ok)" = "1 1"
: > "$B/report"
mit live >/dev/null
check "1: an active mitigations=off is reported as active, no reboot" \
  bash -c 'grep -q "^NOTE - CPU mitigations: off (active)$" "$1" && ! grep -q "reboot" "$1"' _ "$B/report"
check "1: mitigations=off (the accepted no-op) gives the same result" test "$(mit ok off)" = "1 1"

# A drop-in present but a menu without the option (an earlier update-grub
# failed): regenerated.
printf '\tlinux /vmlinuz root=x ro\n' > "$B/grub.cfg"; : > "$B/calls"
check "1: a boot menu without mitigations=off is regenerated" test "$(mit ok)" = "1 1"

# Containers and hosts without GRUB: skipped and reported.
reset_boot
check "1: a container is left alone (no drop-in, no update-grub)" test "$(mit container)" = "0 0"
check "1: ... and the report says so" grep -q "^NOTE - CPU mitigations: mitigations=off ignored in a container" "$B/report"
reset_boot
check "1: a host without GRUB is left alone" test "$(mit nogrub)" = "0 0"
check "1: ... and the report warns" grep -q "^WARN - CPU mitigations: mitigations=off needs GRUB" "$B/report"
reset_boot
check "1: a failing update-grub never fails the run" test "$(mit fail)" = "1 1"
check "1: ... and is reported for the next run to retry" grep -q "^WARN .*update-grub failed.*the next run retries" "$B/report"

# Legacy 99- name retired.
reset_boot
printf 'GRUB_CMDLINE_LINUX_DEFAULT="x mitigations=off"\n' > "$B/grub.d/99-setup-mitigations.cfg"
mit ok >/dev/null
check "1: the pre-1.21.44 drop-in is replaced" \
  bash -c 'test ! -e "$1/99-setup-mitigations.cfg" && test -f "$1/zz-setup-mitigations.cfg"' _ "$B/grub.d"

# Both entry points apply it.
check "1: --basic (install_basic) and --optimize (run_os_tuning) call configure_cpu_mitigations" \
  bash -c 'sed -n "/^install_basic()/,/^}/p" "$1" | grep -q "^[[:space:]]*configure_cpu_mitigations$" && sed -n "/^run_os_tuning()/,/^}/p" "$1" | grep -q "^[[:space:]]*configure_cpu_mitigations$"' _ "$ALL_SRC_FILE"
check "1: configure_cpu_mitigations no longer returns early on an unset choice" \
  lacks "$(sed -n '/^configure_cpu_mitigations()/,/^}/p' "$ALL_SRC_FILE")" '[[ -n $want ]] || return 0'
check "1: the drop-in comment no longer points at mitigations=on" \
  lacks "$(cpu_mitigations_dropin_text)" "mitigations=on"

# ---------------------------------------------------------------------------
# (3) a persisted CPU_MITIGATIONS=on moves to off
# ---------------------------------------------------------------------------
reset_boot
printf 'NODE_MAJOR=22\nCPU_MITIGATIONS=on\nXF_JOB_CRON=1\n' > "$B/setup-tuning"
check "3: a persisted on writes the drop-in like the default" test "$(mit ok on)" = "1 1"
check "3: the report says the pin moved to off" \
  grep -q "^NOTE - CPU mitigations: the persisted CPU_MITIGATIONS=on was removed in 1.22.5; this host moves to mitigations=off" "$B/report"
check "3: the pin is rewritten to off" grep -qx "CPU_MITIGATIONS=off" "$B/setup-tuning"
check "3: no on pin is left" not grep -q "CPU_MITIGATIONS=on" "$B/setup-tuning"
check "3: the other pins stay" \
  bash -c 'grep -qx "NODE_MAJOR=22" "$1" && grep -qx "XF_JOB_CRON=1" "$1"' _ "$B/setup-tuning"
: > "$B/report"
mit ok off >/dev/null
check "3: the next run (pin now off) reports no move" not grep -q "was removed in 1.22.5" "$B/report"
# validate_all normalises CPU_MITIGATIONS to off before the tuner runs and
# carries the old value in CPU_MITIGATIONS_RETIRED_ON.
reset_boot
printf 'CPU_MITIGATIONS="on"\n' > "$B/setup-tuning"
mit ok off 1 >/dev/null
check "3: the flag from validate_all (CPU_MITIGATIONS already off) also moves the pin" \
  bash -c 'grep -qx "CPU_MITIGATIONS=off" "$1" && grep -q "was removed in 1.22.5" "$2"' _ "$B/setup-tuning" "$B/report"
reset_boot
printf 'CPU_MITIGATIONS=on\n' > "$B/setup-tuning"
mit container on >/dev/null
check "3: the pin moves even in a container (boot loader not managed)" grep -qx "CPU_MITIGATIONS=off" "$B/setup-tuning"

# validate_all: structural (it needs the whole parsed state to run).
vbody=$(sed -n '/^validate_all()/,/^}/p' "$ALL_SRC_FILE")
check "3: validate_all records a persisted on" has "$vbody" "CPU_MITIGATIONS_RETIRED_ON=1"
check "3: validate_all leaves CPU_MITIGATIONS=off for every run" \
  bash -c 'grep -qx "  CPU_MITIGATIONS=off" <<<"$1"' _ "$vbody"
check "3: validate_all no longer maps any value to on" lacks "$vbody" "CPU_MITIGATIONS_SETTING=on"

# ---------------------------------------------------------------------------
# (2) the CLI refuses mitigations=on; off stays a no-op
# ---------------------------------------------------------------------------
ms() { ( CPU_MITIGATIONS_SETTING=""; mitigations_set "$1"; printf 'SET=%s' "$CPU_MITIGATIONS_SETTING" ) 2>&1; }
for v in on ON yes 1 true auto; do
  out=$(ms "$v"); rc=$?
  check "2: mitigations=${v} is refused" test "$rc" -ne 0
  check "2: ... with the removal message" has "$out" "mitigations=on was removed in 1.22.5"
done
out=$(ms off); rc=$?
check "2: mitigations=off is accepted" bash -c '[[ $1 == 0 && $2 == *"SET=off"* ]]' _ "$rc" "$out"
out=$(ms ""); rc=$?
check "2: an empty mitigations= is refused" test "$rc" -ne 0
check "2: the help no longer offers mitigations=on" lacks "$(usage 2>&1)" "mitigations=on|off"
check "2: the help names the default" has "$(usage 2>&1)" "always off (the default since 1.22.5)"

# End to end through the dry run (no root).
# dr VAR=value ARGS...: setup.sh as a fresh process (not the sourced test mode).
dr() { ( cd "$TMP" && env -u SETUP_TEST_SOURCE_ONLY -u SETUP_STATE_DIR "$1" bash "$ROOT/setup.sh" "${@:2}" 2>&1 ); }
out=$(dr SETUP_CPU_MITIGATIONS=on --dry-run --optimize); rc=$?
check "2: SETUP_CPU_MITIGATIONS=on is refused" test "$rc" -ne 0
check "2: ... naming the variable" has "$out" "SETUP_CPU_MITIGATIONS=on) was removed in 1.22.5"
out=$(dr X_UNUSED=1 --dry-run --basic mitigations=on); rc=$?
check "2: --basic mitigations=on is refused" bash -c '[[ $1 != 0 && $2 == *"mitigations=on was removed"* ]]' _ "$rc" "$out"
out=$(dr X_UNUSED=1 --optimize --dry-run mitigations=on); rc=$?
check "2: a loose mitigations=on after --dry-run is refused" bash -c '[[ $1 != 0 && $2 == *"mitigations=on was removed"* ]]' _ "$rc" "$out"
out=$(dr X_UNUSED=1 --dry-run --basic mitigations=sometimes); rc=$?
check "2: an unknown value is refused, saying only off is accepted" \
  bash -c '[[ $1 != 0 && $2 == *"accepts only off"* ]]' _ "$rc" "$out"
out=$(dr X_UNUSED=1 --dry-run --basic); rc=$?
check "2: --basic --dry-run (no mitigations=) succeeds" test "$rc" -eq 0
check "2: ... and plans mitigations=off" bash -c '[[ $1 == *"CPU mitigations:"*"mitigations=off"* ]]' _ "$out"
out=$(dr SETUP_CPU_MITIGATIONS=off --dry-run --basic mitigations=off); rc=$?
check "2: mitigations=off and SETUP_CPU_MITIGATIONS=off stay accepted" test "$rc" -eq 0

# ---------------------------------------------------------------------------
# Dry-run plan line
# ---------------------------------------------------------------------------
plan() {
  (
    MODE=$1
    CPU_MITIGATIONS=off CPU_MITIGATIONS_RETIRED_ON=${2:-0}
    CPU_MITIGATIONS_DROPIN=$B/grub.d/zz-setup-mitigations.cfg
    CPU_MITIGATIONS_GRUBCFG=$B/grub.cfg
    CPU_MITIGATIONS_GRUB_DEFAULT=$B/grub
    [[ $MODE == nogrub ]] && CPU_MITIGATIONS_GRUB_DEFAULT=$B/missing-grub
    host_is_container() { [[ $MODE == container ]]; }
    cpu_mitigations_live_off() { [[ $MODE == live ]]; }
    update-grub() { :; }
    cpu_mitigations_plan_text
  )
}
reset_boot
check "plan: a fresh host would add mitigations=off" has "$(plan ok)" "would add mitigations=off (default;"
check "plan: a container is skipped" has "$(plan container)" "mitigations=off ignored (container)"
check "plan: a host without GRUB is skipped" has "$(plan nogrub)" "not applied (no GRUB)"
check "plan: a persisted on is announced as moving to off" has "$(plan ok 1)" "CPU_MITIGATIONS=on moves to off"
mit ok >/dev/null
check "plan: an applied but not yet booted drop-in says a reboot is needed" has "$(plan ok)" "reboot needed to apply"
check "plan: an active one says so" has "$(plan live)" "and active"

# ---------------------------------------------------------------------------
# (4) --purge basic still removes the drop-in and regenerates grub
# ---------------------------------------------------------------------------
pbody=$(sed -n '/^purge_basic()/,/^}/p' "$ALL_SRC_FILE")
check "4: --purge basic removes the drop-in (both names)" \
  has "$pbody" 'rm -f "$CPU_MITIGATIONS_DROPIN" "$CPU_MITIGATIONS_LEGACY_DROPIN"'
check "4: --purge basic regenerates the boot menu" has "$pbody" "update-grub"
check "4: --purge basic drops the pin" bash -c 'grep -q "^[[:space:]]*purge_cpu_mitigations_pin" <<<"$1"' _ "$pbody"
printf 'NODE_MAJOR=22\nCPU_MITIGATIONS=on\nexport CPU_MITIGATIONS=off\n' > "$TMP/pin"
( info() { :; }; warn() { :; }; purge_cpu_mitigations_pin "$TMP/pin" )
check "4: the pin (any value, export form too) is removed" not grep -q CPU_MITIGATIONS "$TMP/pin"
check "4: other pins survive" grep -qx "NODE_MAJOR=22" "$TMP/pin"
check "4: purge no longer promises that later runs leave the boot loader alone" \
  lacks "$(sed -n '/^purge_cpu_mitigations_pin()/,/^}/p' "$ALL_SRC_FILE")" "leave the boot loader alone"

rm -rf "$TMP"
printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
