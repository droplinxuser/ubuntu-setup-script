# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).
# ---------------------------------------------------------------------------
# BASIC
# ---------------------------------------------------------------------------
configure_dns() {
  step "DNS"
  # Track the drop-in itself, not the whole directory: other resolver drop-ins
  # may belong to the operator and must survive a purge.
  record_original /etc/systemd/resolved.conf.d/dns_servers.conf dns_servers.conf
  mkdir -p /etc/systemd/resolved.conf.d
  # Only manage our own drop-in; do not delete unrelated resolver configs.
  # Domains=~. is what makes these servers the default route for every query;
  # with DNS= alone, a DHCP-provided per-link server is used for the link's
  # routing domain (the observed default route kept the provider resolver).
  local dns_src="${SCRIPT_DIR}/configs/system/dns_servers.conf"
  if [[ -f $dns_src ]]; then
    install -m 644 "$dns_src" /etc/systemd/resolved.conf.d/dns_servers.conf
  else
    cat > /etc/systemd/resolved.conf.d/dns_servers.conf <<'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
Domains=~.
EOF
  fi
  chmod 644 /etc/systemd/resolved.conf.d/dns_servers.conf
  retry 3 3 systemctl restart systemd-resolved || warn "systemd-resolved restart failed"
  resolvectl status || true
}

# Ubuntu 26.04's `who` profile lacks the nameservice abstraction.
# needrestart runs who(1) after every apt operation, and each run logs
# AppArmor DENIED lines for /etc/passwd and /etc/nsswitch.conf (95 per full
# install).  Read-only name lookups are all it needs.
configure_who_apparmor() {
  [[ -f /etc/apparmor.d/who ]] || return 0
  grep -q 'include if exists <local/who>' /etc/apparmor.d/who || return 0
  local abs=nameservice-strict
  [[ -f /etc/apparmor.d/abstractions/${abs} ]] || abs=nameservice
  apparmor_local_set who 'who nameservice' <<EOF
# needrestart runs who(1) after apt operations; allow user name lookups.
include <abstractions/${abs}>
EOF
}

update_system() {
  step "Ubuntu update"
  apt_update || die "apt-get update failed: $(apt_update_failure_hint)"
  # A failed upgrade can leave dpkg half-configured (for example when a
  # postinst is interrupted by a full disk or a provider console reset).
  # Repair the package state once and retry, instead of continuing a
  # provisioning run on top of a broken dpkg database.
  #
  # needrestart's APT hook is suspended for the upgrade itself: when the
  # batch contains systemd, its trigger re-executes PID 1 and the hook's
  # immediate `systemctl restart <16 units>` fails as a whole with "Failed to
  # connect to system scope bus via local transport", leaving every daemon
  # on the old libc.  The restart pass runs once systemd answers again.
  if ! NEEDRESTART_SUSPEND=1 apt-get upgrade "${APT_OPTS[@]}"; then
    warn "apt upgrade failed; repairing dpkg state and retrying once"
    dpkg --configure -a || warn "dpkg --configure -a reported an issue"
    apt-get -f install --no-remove "${APT_OPTS[@]}" || warn "apt-get -f install reported an issue"
    NEEDRESTART_SUSPEND=1 apt-get upgrade "${APT_OPTS[@]}" \
      || warn "apt upgrade still failing; continuing with a partially upgraded system"
  fi
  restart_outdated_services
}

# Wait (up to ~30 s) until PID 1 accepts systemctl calls again, e.g. after a
# systemd package trigger re-executed it.
wait_for_systemd() {
  local i
  for (( i = 0; i < 30; i++ )); do
    systemctl show -p Version --value >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Restart the daemons still mapping replaced libraries (needrestart batch
# mode, automatic).  Deferred units (dbus, logind, getty) stay deferred as
# needrestart decides; a kernel/microcode notice is left to the report.
restart_outdated_services() {
  command -v needrestart >/dev/null 2>&1 || return 0
  wait_for_systemd || { warn "systemd did not answer after the upgrade; service restarts skipped (run needrestart -r a)"; return 0; }
  NEEDRESTART_MODE=a needrestart -r a -q >/dev/null 2>&1 \
    || warn "needrestart reported an issue restarting upgraded services (run needrestart -r a)"
}

# True when this CPU exposes frequency scaling and actually offers the
# performance governor.  Some VMs expose a cpufreq directory but only list
# powersave/schedutil; claiming "governor=performance" there is misleading.
# SETUP_SYS_CPUFREQ points the probe at another tree (unit-test fixtures, as
# SETUP_SYS_BLOCK does for the disk classifier).
cpu_performance_governor_available() {
  local dir=${SETUP_SYS_CPUFREQ:-/sys/devices/system/cpu/cpu0/cpufreq}
  [[ -d $dir ]] || return 1
  if [[ -r $dir/scaling_available_governors ]]; then
    grep -qw performance "$dir/scaling_available_governors" || return 1
  fi
  return 0
}

# CPU vulnerability mitigations through a managed GRUB drop-in.  Ubuntu's
# grub-mkconfig sources /etc/default/grub.d/*.cfg after /etc/default/grub, so
# appending to GRUB_CMDLINE_LINUX_DEFAULT keeps the provider's own options
# (console, iommu, nomodeset).  Since 1.22.5 mitigations=off is the default
# on every host setup.sh manages (operator decision: single-tenant hosts,
# key-only SSH); mitigations=on was removed, and a persisted
# CPU_MITIGATIONS=on moves to off.  --purge basic still removes the drop-in.
# The kernel applies the change at the next boot; the run says so instead
# of rebooting.
#
# The drop-in must be sourced last.  The *.cfg glob sorts letters after
# digits, so the old 99-setup-mitigations.cfg ran BEFORE a provider file such
# as Hetzner's hetzner.cfg, whose plain GRUB_CMDLINE_LINUX_DEFAULT="..."
# assignment then erased mitigations=off while the run reported "off at the
# next reboot" (live host, 2026-11-20).  zz- sorts after both; the old name
# is migrated, and the boot menu is checked after update-grub.
CPU_MITIGATIONS_DROPIN=/etc/default/grub.d/zz-setup-mitigations.cfg
CPU_MITIGATIONS_LEGACY_DROPIN=/etc/default/grub.d/99-setup-mitigations.cfg
cpu_mitigations_dropin_text() {
  cat <<'EOF'
# Managed by setup.sh (mitigations=off is its default since 1.22.5).
# Turns off the kernel's CPU vulnerability mitigations (PTI, IBRS, MDS buffer
# clearing, ...) for throughput.  Removed by `setup.sh --purge basic`, then
# reboot.
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+$GRUB_CMDLINE_LINUX_DEFAULT }mitigations=off"
EOF
}

cpu_mitigations_live_off() {
  grep -qw 'mitigations=off' /proc/cmdline 2>/dev/null
}

# 1 when the run must move a persisted CPU_MITIGATIONS=on to off (the value
# sourced from /etc/default/setup-tuning; validate_all records it in
# CPU_MITIGATIONS_RETIRED_ON before it normalises CPU_MITIGATIONS to off).
cpu_mitigations_retired_on() {
  (( ${CPU_MITIGATIONS_RETIRED_ON:-0} )) || [[ ${CPU_MITIGATIONS:-} == on ]]
}

# One dry-run line for the planned boot-loader change.
cpu_mitigations_plan_text() {
  local moved="" grub_default=${CPU_MITIGATIONS_GRUB_DEFAULT:-/etc/default/grub}
  if cpu_mitigations_retired_on; then
    moved='; the persisted CPU_MITIGATIONS=on moves to off (on was removed in 1.22.5)'
  fi
  if host_is_container; then
    printf 'mitigations=off ignored (container)%s' "$moved"
  elif [[ ! -f $grub_default ]] || ! command -v update-grub >/dev/null 2>&1; then
    printf 'mitigations=off not applied (no GRUB)%s' "$moved"
  elif cpu_mitigations_grubcfg_off && [[ -f $CPU_MITIGATIONS_DROPIN ]]; then
    if cpu_mitigations_live_off; then
      printf 'mitigations=off (default; already in %s and active)%s' "$CPU_MITIGATIONS_DROPIN" "$moved"
    else
      printf 'mitigations=off (default; already in %s, reboot needed to apply)%s' "$CPU_MITIGATIONS_DROPIN" "$moved"
    fi
  else
    printf 'would add mitigations=off (default; %s + update-grub; reboot to apply)%s' "$CPU_MITIGATIONS_DROPIN" "$moved"
  fi
}

# 1 when the generated boot menu carries mitigations=off on a kernel line
# (what the next boot will use; the drop-in alone proves nothing if
# update-grub failed).
cpu_mitigations_grubcfg_off() {
  local cfg=${CPU_MITIGATIONS_GRUBCFG:-/boot/grub/grub.cfg}
  [[ -r $cfg ]] && grep -qE '^[[:space:]]*linux[[:space:]].*[[:space:]]mitigations=off([[:space:]]|$)' "$cfg"
}

# GRUB drop-ins sourced after ours (glob order) that assign
# GRUB_CMDLINE_LINUX_DEFAULT without extending the current value: each one
# erases mitigations=off.  Printed one per line, for the warning.
cpu_mitigations_overriders() {
  local dir=${CPU_MITIGATIONS_DROPIN%/*} ours=${CPU_MITIGATIONS_DROPIN##*/} f
  for f in "$dir"/*.cfg; do
    [[ -f $f ]] || continue
    # By name, as the glob orders them: the drop-in itself may be missing.
    [[ ${f##*/} > $ours ]] || continue
    if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$f" \
       && ! grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=.*\$\{?GRUB_CMDLINE_LINUX_DEFAULT' "$f"; then
      printf '%s\n' "$f"
    fi
  done
}

# Never fails the run: a boot loader problem is a warning in the report, and
# the next run retries update-grub (it compares the boot menu, not only the
# drop-in).  mitigations=off is applied on every --basic and --optimize
# (1.22.5 default); there is no "on" any more.
configure_cpu_mitigations() {
  local tmp changed=0 state regen=0 grub_default=${CPU_MITIGATIONS_GRUB_DEFAULT:-/etc/default/grub}
  # A host pinned to CPU_MITIGATIONS=on by an older release moves to off:
  # the pin is rewritten first, so it moves even where the boot loader is
  # not managed (container, no GRUB).
  if cpu_mitigations_retired_on; then
    harden_note "- CPU mitigations: the persisted CPU_MITIGATIONS=on was removed in 1.22.5; this host moves to mitigations=off (the default)"
    persist_tuning_var CPU_MITIGATIONS off
    CPU_MITIGATIONS_RETIRED_ON=0
  fi
  CPU_MITIGATIONS=off
  if host_is_container; then
    harden_note "- CPU mitigations: mitigations=off ignored in a container (the host kernel decides)"
    return 0
  fi
  if [[ ! -f $grub_default ]] || ! command -v update-grub >/dev/null 2>&1; then
    harden_warn "- CPU mitigations: mitigations=off needs GRUB (/etc/default/grub and update-grub); this boot loader is not managed"
    return 0
  fi
  # Releases 1.21.36-1.21.43 wrote the drop-in under a name a provider file
  # can override (see CPU_MITIGATIONS_DROPIN); it is retired.
  if [[ -e $CPU_MITIGATIONS_LEGACY_DROPIN && $CPU_MITIGATIONS_LEGACY_DROPIN != "$CPU_MITIGATIONS_DROPIN" ]]; then
    rm -f "$CPU_MITIGATIONS_LEGACY_DROPIN"
    changed=1
  fi
  tmp=$(tmp_file) || return 0
  cpu_mitigations_dropin_text > "$tmp"
  if ! cmp -s "$tmp" "$CPU_MITIGATIONS_DROPIN" 2>/dev/null; then
    mkdir -p "${CPU_MITIGATIONS_DROPIN%/*}"
    if ! install -m 644 "$tmp" "$CPU_MITIGATIONS_DROPIN"; then
      harden_warn "- CPU mitigations: could not write ${CPU_MITIGATIONS_DROPIN}"
      return 0
    fi
    changed=1
  fi
  cpu_mitigations_grubcfg_off || regen=1
  if (( changed || regen )); then
    if ! update-grub >/dev/null 2>&1; then
      harden_warn "- CPU mitigations: update-grub failed; the boot menu does not have mitigations=off yet (the next run retries)"
      return 0
    fi
  fi
  if ! cpu_mitigations_grubcfg_off; then
    # update-grub succeeded but the generated menu still lacks the option:
    # another drop-in or a custom grub.cfg wins.  Say so instead of
    # reporting a reboot that would not apply it.
    local over
    over=$(cpu_mitigations_overriders | paste -sd' ' -)
    harden_warn "- CPU mitigations: mitigations=off is the default but the generated boot menu has no mitigations=off${over:+; ${over} assigns GRUB_CMDLINE_LINUX_DEFAULT after ${CPU_MITIGATIONS_DROPIN} (extend it with \"\${GRUB_CMDLINE_LINUX_DEFAULT} ...\" instead)}"
    return 0
  fi
  if cpu_mitigations_live_off; then
    state="off (active)"
  else
    # The boot menu has it; the running kernel booted without it.
    state="off at the next reboot (reboot needed: the running kernel booted without mitigations=off)"
  fi
  harden_note "- CPU mitigations: ${state}"
  if [[ $state == *"at the next reboot"* ]]; then
    info "CPU mitigations: reboot to apply mitigations=off"
  fi
  return 0
}

configure_cpu_governor() {
  step "CPU governor"
  # A guest's governor is the hypervisor's business; a VPS that exposes a
  # cpufreq interface (nested virtualisation, some LXC hosts) must not fight
  # it.  Many dedicated hosts expose no cpufreq interface either; treat both
  # as an informational skip instead of a failed service/warning.
  if host_is_vps; then
    info "Virtual host: leaving the CPU governor to the hypervisor"
    return 0
  fi
  if ! cpu_performance_governor_available; then
    info "No performance CPU governor on this host; skipping governor setup"
    return 0
  fi
  # Removing a provider's tuned profile is a destructive change outside this
  # script's ownership.  Warn instead; the operator can disable it if the
  # governor does not stick.
  if pkg_ok tuned; then
    warn "tuned is installed and may override the performance governor; leaving it in place"
  fi
  ensure_state
  # Remember the governor that was active before the first run so --purge
  # can put it back (Ubuntu's default is schedutil, not powersave).
  if [[ ! -s "${STATE_DIR}/original-governor" && -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > "${STATE_DIR}/original-governor" 2>/dev/null || true
  fi
  # amd-pstate-epp / intel_pstate (active mode): the performance governor
  # also forces energy_performance_preference to "performance".  Record the
  # original so --purge puts the preference back as well (1.22.4).  Only
  # while the governor is not performance yet: on a host an earlier release
  # already switched, the live value is the governor's, not the original.
  if [[ ! -s "${STATE_DIR}/original-epp" && -r /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]] \
     && [[ $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true) != performance ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference > "${STATE_DIR}/original-epp" 2>/dev/null || true
  fi
  # A native oneshot unit owns the governor.  The cpufrequtils package that
  # releases up to 1.20.6 installed ships SysV init scripts only, and systemd
  # logs "lacks a native systemd unit file ... expect removal soon" for both
  # of them on every daemon-reload.  Nothing from the package is needed: the
  # governor is one sysfs write per CPU.
  local unit=/etc/systemd/system/setup-cpu-governor.service tmp gov_file
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
# setup.sh: keep the performance CPU governor across reboots.
[Unit]
Description=Performance CPU governor (setup.sh)
ConditionPathExists=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -w "$$f" ] && echo performance > "$$f"; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
  # Record the pre-run state so --purge retires the unit it created instead
  # of leaving a dead file in /etc/systemd/system (the other generated
  # oneshots, setup-network-tuning and setup-io-tuning, already do this).
  record_original "$unit" setup-cpu-governor.service
  if commit_if_changed "$unit" "$tmp"; then
    chmod 644 "$unit"
    systemctl daemon-reload || true
  fi
  systemctl enable setup-cpu-governor.service >/dev/null 2>&1 \
    || warn "Could not enable setup-cpu-governor.service"
  # Apply now as well: a oneshot that is already "active (exited)" is not
  # re-run by `start`, and the write is idempotent.
  for gov_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -w $gov_file ]] && printf 'performance\n' > "$gov_file" 2>/dev/null || true
  done
  systemctl start setup-cpu-governor.service \
    || warn "Could not start setup-cpu-governor.service"
  info "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || printf unknown) (setup-cpu-governor.service)"

  # Hosts provisioned by 1.20.6 or older: this script installed cpufrequtils
  # there.  Stop its SysV services so only the native unit sets the governor;
  # the package itself stays (packages are never purged by setup.sh).
  if [[ -f "${STATE_DIR}/cpufrequtils-installed" ]] && pkg_ok cpufrequtils; then
    systemctl disable --now cpufrequtils loadcpufreq >/dev/null 2>&1 || true
    info "cpufrequtils is superseded by setup-cpu-governor.service; its SysV services are disabled. Remove the package with 'apt-get purge cpufrequtils' to silence systemd's SysV deprecation notices."
  fi
}

# Set the 127.0.1.1 line of a hosts file in place: the first such line is
# replaced where it stands and any further ones are dropped; with no such line
# the new one is appended.  An empty LINE removes them; a LINE holding several
# newline-separated lines puts all of them at that one position (--purge
# basic uses this to give back every 127.0.1.1 line of the original).
# Deleting and appending (the old way) moved the line to the end, so --purge
# basic could never give back the provider's file byte for byte.
#   hosts_set_loopback_line FILE LINE
hosts_set_loopback_line() {
  local file=$1 line=$2 tmp nonl=0
  tmp=$(tmp_file) || return 1
  # awk terminates every record it prints, so a provider file without a final
  # newline gained one across --basic + --purge and was no longer byte for
  # byte the original.  Note the state here and let awk write the separators
  # itself.  $(...) drops a trailing newline, so a non-empty result means the
  # last byte is something else.
  [[ -s $file && -n $(tail -c 1 "$file") ]] && nonl=1
  # ENVIRON instead of -v: -v expands backslash escapes, which would alter a
  # restored original line that happens to contain one.
  HOSTS_LOOPBACK_LINE=$line awk -v nonl="$nonl" '
    function out(s) { if (n++) printf "\n"; printf "%s", s }
    BEGIN { l = ENVIRON["HOSTS_LOOPBACK_LINE"] }
    /^[[:space:]]*127\.0\.1\.1[[:space:]]/ { if (!done && l != "") out(l); done = 1; next }
    { out($0) }
    END { if (!done && l != "") out(l); if (n && !nonl) printf "\n" }
  ' "$file" > "$tmp" || return 1
  # Rewrite through the existing inode: mode, owner and any symlink stay.
  cat "$tmp" > "$file"
}


# cloud-init with manage_etc_hosts (set by many providers in vendor-data)
# re-renders /etc/hosts from its own idea of the hostname at every boot, and
# that is the provider metadata name, not the one --basic set: after the
# first reboot the 127.0.1.1 line named the old host again and `hostname -f`
# failed (1.22.4, found on a provider bare-metal host).  A cloud.cfg.d
# drop-in with hostname/fqdn makes cloud-init render (and keep) this name.
# Only written where cloud-init is installed; --purge removes it.
SETUP_CLOUD_HOSTNAME_CFG=${SETUP_CLOUD_HOSTNAME_CFG:-/etc/cloud/cloud.cfg.d/99-setup-hostname.cfg}
cloud_init_pin_hostname() {
  local host=$1 dir
  dir=$(dirname "$SETUP_CLOUD_HOSTNAME_CFG")
  [[ -d $dir ]] || return 0
  printf '# setup.sh --basic: the hostname it set.  cloud-init renders /etc/hosts\n# from this at every boot (manage_etc_hosts); setup.sh --purge removes it.\nhostname: %s\nfqdn: %s\n' "$host" "$host" > "$SETUP_CLOUD_HOSTNAME_CFG"
  chmod 644 "$SETUP_CLOUD_HOSTNAME_CFG"
}

# --optimize on a host that --basic renamed before 1.22.4: write the drop-in
# and put the 127.0.1.1 line back if cloud-init already reverted it.  Only
# while the live hostname is still the one --basic applied (an operator who
# renamed the host since is left alone).
repair_cloud_init_hostname() {
  local applied live
  [[ -s "${STATE_DIR}/applied-hostname" ]] || return 0
  applied=$(<"${STATE_DIR}/applied-hostname")
  live=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)
  [[ -n $applied && $applied == "$live" ]] || return 0
  [[ -d $(dirname "$SETUP_CLOUD_HOSTNAME_CFG") ]] || return 0
  if [[ ! -f $SETUP_CLOUD_HOSTNAME_CFG ]]; then
    cloud_init_pin_hostname "$applied"
    info "cloud-init: pinned the hostname $applied ($SETUP_CLOUD_HOSTNAME_CFG), so its /etc/hosts rewrite at boot keeps it"
  fi
  local hosts=${SETUP_HOSTS_FILE:-/etc/hosts}
  # Correct when any name on a 127.0.1.1 line is the applied one (a line
  # that lists the FQDN first is left alone).
  if ! awk -v h="$applied" '$1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' "$hosts" 2>/dev/null; then
    hosts_set_loopback_line "$hosts" "$(printf '127.0.1.1\t%s' "$applied")"
    info "/etc/hosts: 127.0.1.1 names $applied again (cloud-init had reverted it)"
  fi
}

configure_hostname() {
  local host=$1
  step "Hostname"
  ensure_state
  if [[ ! -f "${STATE_DIR}/original-hostname" ]]; then
    hostnamectl hostname > "${STATE_DIR}/original-hostname" 2>/dev/null || cat /etc/hostname > "${STATE_DIR}/original-hostname"
  fi
  record_original /etc/hosts hosts
  hostnamectl set-hostname "$host"
  # Keep the local 127.0.1.1 entry in sync; otherwise sudo and hostname -f
  # keep resolving the old name from /etc/hosts after the rename.
  hosts_set_loopback_line /etc/hosts "$(printf '127.0.1.1\t%s' "$host")"
  cloud_init_pin_hostname "$host"
  # Marks the hostname as applied by --basic (see basic_applied_value).
  printf '%s\n' "$host" > "${STATE_DIR}/applied-hostname"
  hostnamectl status || true
}

install_basic_tools() {
  step "Basic tools"
  apt_install wget unzip nano zip software-properties-common rsync ca-certificates curl gnupg dmidecode git
}

configure_timezone() {
  local tz=$1
  step "Timezone"
  ensure_state
  if [[ ! -f "${STATE_DIR}/original-timezone" ]]; then
    timedatectl show -p Timezone --value > "${STATE_DIR}/original-timezone" 2>/dev/null || true
  fi
  timedatectl set-timezone "$tz"
  printf '%s\n' "$tz" > "${STATE_DIR}/applied-timezone"
  timedatectl status || true
}

# --basic is required by every later service install, so it is re-run on
# hosts that were named and zoned long ago.  When an earlier run applied a
# hostname/timezone (marker under STATE_DIR, emptied by --purge basic) and
# this run gives no host=/time=, the live value is kept instead of renaming
# the host to a generated name or moving it to the default zone.
# Usage: basic_applied_value hostname|timezone -> live value, or status 1.
basic_applied_value() {
  local what=$1 live=""
  [[ -s "${STATE_DIR}/applied-${what}" ]] || return 1
  case "$what" in
    hostname) live=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true) ;;
    timezone) live=$(timedatectl show -p Timezone --value 2>/dev/null || true) ;;
  esac
  [[ -n $live ]] || return 1
  printf '%s' "$live"
}

swap_total_bytes() {
  awk 'NR>1 {sum += $3} END {printf "%d", sum * 1024}' /proc/swaps
}

ram_total_bytes() {
  # Use the same cgroup-aware figure as every service tuner: inside a
  # container or a vCPU/RAM-capped guest /proc/meminfo reports the host's
  # memory, which used to size a swap file against RAM the guest cannot see.
  local mb
  mb=$(mem_total_mb 2>/dev/null || true)
  if [[ $mb =~ ^[0-9]+$ ]] && (( mb > 0 )); then
    printf '%s' $(( mb * 1048576 ))
    return 0
  fi
  awk '/^MemTotal:/{printf "%d", $2 * 1024}' /proc/meminfo
}

mark_swap_managed() {
  ensure_state
  touch "${STATE_DIR}/swapfile-managed"
}

ensure_swap_fstab() {
  if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile swap swap defaults 0 0\n' >> /etc/fstab
  fi
}

create_swap_file() {
  local bytes=$1
  local avail margin=268435456 new=/swapfile.new old=
  # Never fill the filesystem: keep 256 MiB free after the swap file.
  avail=$(df -B1 --output=avail / 2>/dev/null | awk 'NR==2{print $1}')
  if [[ $avail =~ ^[0-9]+$ ]] && (( avail < bytes + margin )); then
    die "Not enough free disk for a $(( bytes / 1048576 )) MiB swap file (${avail} bytes available; 256 MiB must stay free)"
  fi
  # Build the replacement beside the live file.  The old code truncated
  # /swapfile in place, so a full disk or an I/O error left the host with
  # swap off, a zero-length file and an fstab entry that still pointed at it.
  rm -f "$new"
  if ! fallocate -l "$bytes" "$new" 2>/dev/null; then
    warn "fallocate failed; falling back to dd"
    local count=$(( (bytes + 1048575) / 1048576 ))
    dd if=/dev/zero of="$new" bs=1M count="$count" status=none || {
      rm -f "$new"
      die "Could not create a ${bytes}-byte swap file; the existing swap (if any) is untouched"
    }
  fi
  chmod 600 "$new"
  # Validate the file before it replaces anything.  LXC/OpenVZ containers
  # may not manage swap at all and btrfs/ZFS reject a plain swap file; there
  # mkswap/swapon failing is the expected outcome, not an error.  Aborting
  # here used to skip the rest of --basic (sysctl, limits, cron, firewall)
  # and leave a multi-GB file behind.
  if ! mkswap "$new" >/dev/null 2>&1; then
    rm -f "$new"
    info "Swap file not enabled: this system refused a swap file (normal in LXC/OpenVZ containers and on btrfs/ZFS); continuing without it"
    return 0
  fi
  # rename(2) on a file that is active swap fails with EPERM, so the new
  # file must stay inactive until it has taken the path.  A working old file
  # is renamed aside, not deleted, and is put back if swapon then fails.
  if swapfile_active; then
    if ! swapoff /swapfile 2>/dev/null; then
      rm -f "$new"
      warn "Could not deactivate the active /swapfile (its pages do not fit in free RAM); keeping the existing swap unchanged"
      return 0
    fi
  fi
  if [[ -e /swapfile ]]; then
    if ! mv -f /swapfile /swapfile.old; then
      rm -f "$new"
      die "Could not move the old swap file aside; the existing swap is unchanged"
    fi
    old=/swapfile.old
  fi
  if ! mv -f "$new" /swapfile || ! swapon /swapfile 2>/dev/null; then
    rm -f /swapfile
    if [[ -n $old ]]; then
      mv -f "$old" /swapfile
      swapon /swapfile 2>/dev/null \
        || warn "Could not re-activate the previous /swapfile; it is kept at /swapfile for the next boot"
      info "Swap file not enabled: this system refused the new swap file; the previous swap is unchanged"
      return 0
    fi
    if ! swapfile_active \
       && grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
      sed_in_place -E '/^[[:space:]]*\/swapfile[[:space:]]/d' /etc/fstab
    fi
    info "Swap file not enabled: this system refused a swap file (normal in LXC/OpenVZ containers and on btrfs/ZFS); continuing without it"
    return 0
  fi
  if [[ -n $old ]]; then rm -f "$old"; fi
  ensure_swap_fstab
  mark_swap_managed
}

swapfile_active() {
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'
}

configure_swap() {
  local size=$1
  local desired existing
  step "Swap (${size})"

  # The validator accepts 8G and 8Gi; numfmt's iec mode only knows the
  # one-letter form, so drop the "i" before parsing.
  local size_iec=${size^^}
  size_iec=${size_iec%I}
  desired=$(numfmt --from=iec "$size_iec") \
    || die "Could not parse swap size '${size}'"
  (( desired >= 64 * 1024 * 1024 )) \
    || die "--basic swap='${size}' is too small (mkswap needs at least 64M)"

  if [[ -f /swapfile ]]; then
    existing=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    if [[ $existing -eq $desired ]] && swapfile_active; then
      info "Swap file already present with the requested size"
      ensure_swap_fstab
      mark_swap_managed
      swapon --show
      return 0
    fi
    # Do not release the live file first: create_swap_file builds and activates
    # the replacement beside it and only then swaps the old one out, so a
    # failed write can never leave the host with no swap.
  fi

  create_swap_file "$desired"
  swapon --show
}

# Swap target: half of RAM, but never below 1 GiB and never above 8 GiB on a
# dedicated host (4 GiB on a VPS).  Half of a 256 GB host is a 128 GB file
# that only prolongs an OOM situation.
swap_target_bytes() {
  local ram=$1 target min=$(( 1024 * 1024 * 1024 )) max
  max=$(( 8 * 1024 * 1024 * 1024 ))
  host_is_vps && max=$(( 4 * 1024 * 1024 * 1024 ))
  target=$(( ram / 2 ))
  (( target < min )) && target=$min
  (( target > max )) && target=$max
  printf '%s' "$target"
}

# Size of the automatic /swapfile.  Pure: AVAIL is the free bytes on / (empty
# when df gave nothing), OLD the size of an existing /swapfile (0 if none),
# ACTIVE 1 when that file is live swap, NEEDED the bytes still missing to the
# target.  Prints the new file size and returns 0 (full) or 2 (reduced to
# what fits); prints nothing and returns 1 when nothing useful fits.
#
# The new file is built beside the old one (create_swap_file swaps them only
# once it is ready), so both are on disk at once and the old file gives no
# space back.  Counting it used to size a file that create_swap_file then
# refused with die(), after the old swap had already been switched off.
swap_auto_new_size() {
  local avail=$1 old=$2 active=$3 needed=$4 margin=268435456 want room rc=0
  want=$needed
  (( active )) && want=$(( old + needed ))
  if [[ $avail =~ ^[0-9]+$ ]]; then
    room=$(( (avail - margin) / 1048576 * 1048576 ))
    if (( want > room )); then
      (( room < 67108864 || room <= old )) && return 1
      needed=$(( needed - (want - room) ))
      rc=2
    fi
  fi
  if (( active )); then printf '%s' $(( old + needed )); else printf '%s' "$needed"; fi
  return "$rc"
}

configure_swap_auto() {
  local ram current target needed
  step "Swap (auto: 50% of RAM)"

  ram=$(ram_total_bytes)
  current=$(swap_total_bytes)
  target=$(swap_target_bytes "$ram")
  info "RAM: $(numfmt --to=iec "$ram"); current swap: $(numfmt --to=iec "$current"); target swap: $(numfmt --to=iec "$target")"

  if (( current >= target )); then
    info "Current swap already meets or exceeds the target; leaving it unchanged"
    return 0
  fi

  needed=$(( target - current ))
  if (( needed < 1048576 )); then
    info "Additional swap needed is below 1 MiB; skipping"
    return 0
  fi

  # Automatic swap must never abort --basic (and with it sysctl, limits,
  # cron and the firewall) because the disk is small, nor drop a working
  # swap file it cannot replace: size it to what fits with 256 MiB kept free
  # before anything is touched, and leave the live file to create_swap_file.
  local avail old=0 active=0 new_size rc=0
  [[ -f /swapfile ]] && old=$(stat -c %s /swapfile 2>/dev/null || echo 0)
  [[ -f /swapfile ]] && swapfile_active && active=1
  avail=$(df -B1 --output=avail / 2>/dev/null | awk 'NR==2{print $1}')
  new_size=$(swap_auto_new_size "$avail" "$old" "$active" "$needed") || rc=$?
  if (( rc == 1 )); then
    warn "Automatic swap skipped: the 50%-of-RAM target does not fit on / with 256 MiB kept free (swap is unchanged; pass swap=SIZE to choose one)"
    return 0
  fi
  (( rc == 2 )) && info "Automatic swap reduced to $(numfmt --to=iec "$new_size"): the 50%-of-RAM target does not fit on / with 256 MiB kept free"

  info "Adding swap to reach 50% of RAM: /swapfile becomes $(numfmt --to=iec "$new_size")"
  create_swap_file "$new_size"
  swapon --show
}

# Keys whose live kernel values are changed by setup.sh but may not exist in
# the original /etc/sysctl.conf.  Record them so --purge can put the kernel
# back without waiting for a reboot.
SYSCTL_MANAGED_KEYS=(
  net.core.somaxconn net.core.netdev_max_backlog net.core.optmem_max
  net.core.rmem_max net.core.wmem_max
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets
  net.ipv4.tcp_max_orphans net.ipv4.ip_local_port_range
  net.ipv4.tcp_keepalive_time
  net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2
  net.ipv4.neigh.default.gc_thresh3
  net.ipv4.ipfrag_low_thresh net.ipv4.ipfrag_high_thresh
  net.ipv6.ip6frag_low_thresh net.ipv6.ip6frag_high_thresh
  net.netfilter.nf_conntrack_max
  fs.file-max fs.nr_open fs.inotify.max_user_watches
  vm.min_free_kbytes kernel.shmmax kernel.shmall vm.max_map_count
  vm.dirty_background_bytes vm.dirty_bytes vm.dirty_background_ratio vm.dirty_ratio
  vm.swappiness vm.overcommit_memory vm.overcommit_ratio
  net.ipv4.ip_local_reserved_ports net.core.netdev_budget net.core.netdev_budget_usecs
  net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.ipv4.tcp_notsent_lowat
)

# Record the live value of every managed key (plus any extra keys given) once,
# before the profile is applied.  Every recorded key is also indexed so a
# later --purge restores keys the base template defines (forwarding, rp_filter,
# sysrq, ...) and keys added to the profile after this list was written.
record_sysctl_values() {
  ensure_state
  local key file index="${STATE_DIR}/sysctl-managed-keys"
  for key in "${SYSCTL_MANAGED_KEYS[@]}" "$@"; do
    file="${STATE_DIR}/sysctl-orig-${key//\//_}"
    [[ -f $file ]] && continue
    sysctl -n "$key" > "$file" 2>/dev/null || true
    grep -qxF -- "$key" "$index" 2>/dev/null || printf '%s\n' "$key" >> "$index"
  done
}

# Keys defined in a sysctl file, one per line.
sysctl_file_keys() {
  sed -nE 's/^[[:space:]]*([A-Za-z0-9_.\/-]+)[[:space:]]*=.*/\1/p' "$1" 2>/dev/null | sort -u
}

# The base profile disables packet forwarding and IPv6 autoconfiguration.
# That is right for a plain web host, but an adopted server that routes
# (Docker, LXD, a bridge, WireGuard, Tailscale) or takes its IPv6 address from
# router advertisements would lose connectivity the moment the file is
# applied.  Drop those lines when the host demonstrably relies on them.
sysctl_drop_host_overrides() {
  local file=$1 why=""
  if [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) == 1 ]]; then
    why="ip_forward is already enabled"
  elif ip -o link show type bridge 2>/dev/null | grep -q .; then
    why="a bridge interface exists"
  elif ip -o link show 2>/dev/null | grep -qE ': (docker|br-|virbr|lxdbr|lxcbr|wg|tailscale|tun|tap|cni|flannel|veth)'; then
    why="a container/VPN interface exists"
  fi
  if [[ -n $why ]]; then
    sed_in_place -E '/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=/d; /^[[:space:]]*net\.ipv[46]\.conf\.(all|default)\.forwarding[[:space:]]*=/d' "$file"
    info "Keeping packet forwarding as configured (${why}); the profile's forwarding=0 lines were dropped"
  fi
  if ip -6 -o addr show scope global dynamic 2>/dev/null | grep -q . \
     || ip -6 route show default 2>/dev/null | grep -q 'proto ra'; then
    sed_in_place -E '/^[[:space:]]*net\.ipv6\.conf\.(all|default)\.(autoconf|accept_ra)[[:space:]]*=/d' "$file"
    info "Keeping IPv6 autoconfiguration (an address or default route comes from router advertisements)"
  fi
  return 0
}

# Restore a ratio/bytes sysctl pair: write the member that was recorded
# non-zero (writing it resets the other to 0, which is the recorded state).
restore_sysctl_pair() {
  local ratio_key=$1 bytes_key=$2 rv="" bv="" f
  f="${STATE_DIR}/sysctl-orig-${ratio_key}"; [[ -s $f ]] && rv=$(<"$f")
  f="${STATE_DIR}/sysctl-orig-${bytes_key}"; [[ -s $f ]] && bv=$(<"$f")
  if [[ $rv =~ ^[0-9]+$ ]] && (( rv > 0 )); then
    sysctl -w "${ratio_key}=${rv}" >/dev/null 2>&1 || warn "Could not restore ${ratio_key}=${rv}"
  elif [[ $bv =~ ^[0-9]+$ ]] && (( bv > 0 )); then
    sysctl -w "${bytes_key}=${bv}" >/dev/null 2>&1 || warn "Could not restore ${bytes_key}=${bv}"
  fi
}

# Restore a fragment-reassembly pair (HIGH_KEY LOW_KEY) in an order the
# kernel accepts: it rejects a high mark below the live low mark and a low
# mark above the live high mark.  When the recorded high is below the live
# low (lowering from a tune above ~87 GB of RAM, where the tuned low exceeds
# the 4 MB default high), the low mark goes first; otherwise (the usual
# case) the high mark goes first.  The same rule as the make-room step in
# configure_sysctl.
restore_frag_pair() {
  local high_key=$1 low_key=$2 rh="" rl="" live_low f
  f="${STATE_DIR}/sysctl-orig-${high_key}"; [[ -s $f ]] && rh=$(<"$f")
  f="${STATE_DIR}/sysctl-orig-${low_key}"; [[ -s $f ]] && rl=$(<"$f")
  live_low=$(sysctl -n "$low_key" 2>/dev/null || true)
  local -a order=("$high_key" "$low_key")
  if [[ $rh =~ ^[0-9]+$ && $live_low =~ ^[0-9]+$ ]] && (( rh < live_low )); then
    order=("$low_key" "$high_key")
  fi
  local key value
  for key in "${order[@]}"; do
    if [[ $key == "$high_key" ]]; then value=$rh; else value=$rl; fi
    [[ -n $value ]] || continue
    sysctl -w "${key}=${value}" >/dev/null 2>&1 \
      || warn "Could not restore ${key}=${value}"
  done
}

restore_sysctl_values() {
  local key file value
  # Paired keys need care.  The dirty thresholds come as ratio/bytes pairs
  # and writing one zeroes the other, so a recorded 0 is never written back
  # (the tune wrote bytes, which zeroed the live ratio; restoring bytes=0 then
  # left no threshold and --purge logged "Could not restore vm.dirty_bytes=0").
  # Each pair restores whichever recorded value is non-zero, foreground pair
  # first.  The ipfrag pairs (IPv4 and IPv6) go last, each in the order the
  # kernel accepts (restore_frag_pair).
  restore_sysctl_pair vm.dirty_ratio vm.dirty_bytes
  restore_sysctl_pair vm.dirty_background_ratio vm.dirty_background_bytes
  local -a all=("${SYSCTL_MANAGED_KEYS[@]}") ordered=()
  local seen=" "
  if [[ -s "${STATE_DIR}/sysctl-managed-keys" ]]; then
    mapfile -t -O "${#all[@]}" all < "${STATE_DIR}/sysctl-managed-keys"
  fi
  for key in "${all[@]}"; do
    [[ -n $key && $seen != *" ${key} "* ]] || continue
    seen+="${key} "
    case $key in
      vm.dirty_bytes|vm.dirty_ratio|vm.dirty_background_bytes|vm.dirty_background_ratio) continue ;;
      net.ipv4.ipfrag_low_thresh|net.ipv6.ip6frag_low_thresh) continue ;;
      net.ipv4.ipfrag_high_thresh|net.ipv6.ip6frag_high_thresh) continue ;;
    esac
    ordered+=("$key")
  done
  for key in "${ordered[@]}"; do
    file="${STATE_DIR}/sysctl-orig-${key//\//_}"
    [[ -f $file ]] || continue
    value=$(<"$file")
    # An empty recorded value is only meaningful for the reserved-port list
    # (empty = none reserved); other keys never read back empty.
    if [[ -z $value && $key != net.ipv4.ip_local_reserved_ports ]]; then
      continue
    fi
    sysctl -w "${key}=${value}" >/dev/null 2>&1 \
      || warn "Could not restore ${key}=${value}"
  done
  restore_frag_pair net.ipv4.ipfrag_high_thresh net.ipv4.ipfrag_low_thresh
  restore_frag_pair net.ipv6.ip6frag_high_thresh net.ipv6.ip6frag_low_thresh
}

# Keep only the last definition of each sysctl key so an overlapping base
# profile and hardware block cannot silently contradict each other.
sysctl_dedupe_keys() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk '
    {
      lines[NR] = $0
      if (match($0, /^[[:space:]]*[A-Za-z0-9_.\/-]+[[:space:]]*=/)) {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]]*=.*/, "", key)
        last[key] = NR
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (match(line, /^[[:space:]]*[A-Za-z0-9_.\/-]+[[:space:]]*=/)) {
          key = line
          sub(/^[[:space:]]*/, "", key)
          sub(/[[:space:]]*=.*/, "", key)
          if (last[key] != i) continue
        }
        print line
      }
    }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" || true
  return 0
}

# The kernel requires low <= high at the moment of every write (EINVAL
# otherwise).  At boot systemd-sysctl starts from the kernel defaults
# (3 MB low, 4 MB high) and the profile never goes below them (the RAM-sized
# high mark is clamped to >= 4 MB), so the boot transition is always upward:
# the high mark must be written first.  Low-first made systemd-sysctl.service
# fail on every boot of a host large enough to scale the pair (a 128 GB host:
# "Couldn't write '6178656' to 'net/ipv4/ipfrag_low_thresh': Invalid
# argument"; setup-sysctl-final re-applied the values later).  A downward
# change at --optimize time is prepared by the make-room step in
# configure_sysctl before this file is applied.
ipfrag_sysctl_lines() {
  local high=$1 low=$2
  printf 'net.ipv4.ipfrag_high_thresh = %s\n' "$high"
  printf 'net.ipv4.ipfrag_low_thresh = %s\n' "$low"
}

# Report-only: net.core.default_qdisc applies to qdiscs created after the
# write, so a NIC that came up before it keeps its mq/fq_codel root until the
# next reboot (systemd-sysctl applies 90-setup-network.conf before the links
# come up).  BBR paces by itself without fq, so this is efficiency, not
# correctness; nothing live is changed.  Physical NICs only (a device/ link
# under /sys/class/net).  $1: the wanted qdisc; SETUP_SYS_CLASS_NET for tests.
net_qdisc_report() {
  local want=${1:-fq} dir=${SETUP_SYS_CLASS_NET:-/sys/class/net} d ifc live
  [[ $want == fq ]] || return 0
  command -v tc >/dev/null 2>&1 || return 0
  for d in "$dir"/*; do
    ifc=${d##*/}
    [[ $ifc != lo && -e $d/device ]] || continue
    live=$(tc qdisc show dev "$ifc" 2>/dev/null || true)
    [[ -n $live ]] || continue
    grep -qE '^qdisc fq ' <<<"$live" && continue
    live=$(awk '$1 == "qdisc" && $2 != "mq" { print $2; exit }' <<<"$live")
    info "qdisc on ${ifc}: fq applies after the next reboot (live: ${live:-unknown})"
    if declare -F opt_report >/dev/null 2>&1; then
      opt_report "- qdisc: ${ifc}: fq applies after the next reboot (live: ${live:-unknown}; BBR paces without it meanwhile)"
    fi
  done
  return 0
}

# ufw loads its own /etc/ufw/sysctl.conf (IPT_SYSCTL in /etc/default/ufw)
# every time it starts: on `ufw enable` and on every boot, after
# systemd-sysctl has applied /etc/sysctl.conf.  Its stock
# `log_martians=0` therefore silently replaced the managed profile's value,
# so a fresh install (sysctl first, firewall second) and `--optimize` (sysctl
# only) ended with different live values, and a reboot undid --optimize.
# Make ufw's file agree with the managed profile for the keys both set.
# $1/$2 are the two files (tests pass fixtures).
ufw_align_sysctl() {
  local ufw_file=${1:-/etc/ufw/sysctl.conf} profile=${2:-/etc/sysctl.conf} want tmp
  [[ -f $ufw_file && -f $profile ]] || return 0
  want=$(awk -F= '/^[[:space:]]*net\.ipv4\.conf\.all\.log_martians[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); v = $2 } END { print v }' "$profile" 2>/dev/null || true)
  [[ $want =~ ^[01]$ ]] || return 0
  grep -qE "^net/ipv4/conf/(all|default)/log_martians=" "$ufw_file" || return 0
  tmp=$(tmp_file) || return 1
  sed -E "s#^(net/ipv4/conf/(all|default)/log_martians)=.*#\1=${want}#" "$ufw_file" > "$tmp" || return 1
  if ! cmp -s -- "$ufw_file" "$tmp"; then
    [[ $ufw_file == /etc/ufw/sysctl.conf ]] && record_original "$ufw_file" ufw-sysctl.conf
    cat -- "$tmp" > "$ufw_file"
    info "UFW: log_martians=${want} in ${ufw_file} (ufw reloads this file on every start; it now matches the managed sysctl profile)"
  fi
  return 0
}

# vm.dirty_background_bytes / vm.dirty_bytes in MB for a host with RAM_MB of
# memory on storage CLASS, printed as "background foreground".  1% of RAM
# (64-512 MB) starts the background flush and four times that (256 MB-2 GB)
# blocks writers; rotational disks get tighter caps because they drain slowly.
# The 64/256 MB floors assume a few GB of RAM: on a 512 MB host 256 MB of
# dirty pages is half the machine, so the background mark never exceeds
# RAM/20 and the foreground mark never exceeds RAM/5 (the stock 5%/20%
# ratios).  Those caps only bind below about 1.3 GB.
sysctl_dirty_thresholds_mb() {
  local ram_mb=$1 class=${2:-} bg fg cap
  bg=$(( ram_mb / 100 ))
  if (( bg < 64 )); then bg=64; fi
  if (( bg > 512 )); then bg=512; fi
  if [[ $class == hdd ]] && (( bg > 256 )); then bg=256; fi
  fg=$(( bg * 4 ))
  if (( fg < 256 )); then fg=256; fi
  if (( fg > 2048 )); then fg=2048; fi
  if [[ $class == hdd ]] && (( fg > 1024 )); then fg=1024; fi
  cap=$(( ram_mb / 20 ))
  if (( cap < 8 )); then cap=8; fi
  if (( bg > cap )); then bg=$cap; fi
  cap=$(( ram_mb / 5 ))
  if (( cap < bg * 2 )); then cap=$(( bg * 2 )); fi
  if (( fg > cap )); then fg=$cap; fi
  printf '%s %s' "$bg" "$fg"
}

# setup-network-tuning.service: load the modules that own the qdisc and
# congestion-control sysctls, then set them.  Every ExecStart carries the "-"
# prefix and each key has its own line: a container cannot load modules and
# may not own every key, and a oneshot stops at the first failing command, so
# without the prefix the unit was failed on every boot and the keys after the
# failure were never applied.  Arguments: the modules to load.
network_tuning_unit_text() {
  local mod
  cat <<'EOF'
[Unit]
Description=Apply network qdisc/congestion-control tuning after kernel modules load
After=systemd-modules-load.service systemd-sysctl.service
[Service]
Type=oneshot
EOF
  for mod in "$@"; do
    printf 'ExecStart=-/sbin/modprobe %s\n' "$mod"
  done
  # Re-apply the managed profile after systemd-sysctl has processed every
  # /etc/sysctl.d file: a foreign drop-in (an old hand fix, tuned, Docker)
  # must lose to the hardware profile this script owns.
  printf 'ExecStart=-/sbin/sysctl -e -p /etc/sysctl.conf\n'
  printf 'ExecStart=-/sbin/sysctl -w net.core.default_qdisc=%s\n' "$QDISC"
  printf 'ExecStart=-/sbin/sysctl -w net.ipv4.tcp_congestion_control=%s\n' "$TCP_CC"
  cat <<'EOF'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
}

# A second, late pass: 90 s after boot, after multi-user services (including
# a hand-written tcp-bbr.service or rc.local) have run.  The managed profile
# is idempotent, so re-applying it costs a few milliseconds and guarantees
# that every server converges on the same values even when a foreign unit
# writes a managed key at startup.  The files are recorded for --purge.
sysctl_final_unit_text() {
  local mod
  cat <<'EOF'
[Unit]
Description=Re-apply the setup.sh managed sysctl profile after late boot units
After=multi-user.target
[Service]
Type=oneshot
EOF
  for mod in "$@"; do
    printf 'ExecStart=-/sbin/modprobe %s\n' "$mod"
  done
  printf 'ExecStart=-/sbin/sysctl -e -p /etc/sysctl.conf\n'
  printf 'ExecStart=-/sbin/sysctl -w net.core.default_qdisc=%s\n' "$QDISC"
  printf 'ExecStart=-/sbin/sysctl -w net.ipv4.tcp_congestion_control=%s\n' "$TCP_CC"
  cat <<'EOF'
RemainAfterExit=yes
EOF
}

sysctl_final_timer_text() {
  cat <<'EOF'
[Unit]
Description=Re-apply the setup.sh sysctl profile 90 s after boot
[Timer]
OnBootSec=90s
AccuracySec=5s
Unit=setup-sysctl-final.service
[Install]
WantedBy=timers.target
EOF
}

# Huge pages for OPcache, in 2 MB pages.  Only meaningful when PHP is
# installed and the host has at least 4 GB: size the reservation to OPcache
# plus the JIT buffer, not to a fixed fraction of RAM.  The old RAM/64 formula
# reserved 186 pages on a 12 GB host, which is less than the 288 pages the
# 512 MB OPcache + 64 MB JIT need, so huge_code_pages stayed off and the
# reservation was wasted.  No PHP -> 0 (no reservation at all).
sysctl_hugepages_target() {
  local ram_mb=${1:-0} has_php=${2:-0} opcache_mb jit_mb pages
  [[ $ram_mb =~ ^[0-9]+$ ]] || { printf 0; return 0; }
  (( ram_mb >= 4096 )) || { printf 0; return 0; }
  (( has_php )) || { printf 0; return 0; }
  php_ini_profile "$ram_mb"
  opcache_mb=$PHP_PROFILE_OPCACHE_MB
  read -r _ jit_mb < <(php_jit_settings "$opcache_mb")
  [[ $jit_mb =~ ^[0-9]+$ ]] || jit_mb=0
  pages=$(( (opcache_mb + jit_mb + 1) / 2 + 8 ))
  (( pages > 512 )) && pages=512
  (( pages < 8 )) && pages=8
  printf '%s' "$pages"
}

# One PHP predicate for the sysctl writer and the memory plan: the pages are
# reserved whenever configure_sysctl believes PHP exists (a leftover /etc/php
# included), so the plan must book them under the same test.
hugepages_php_present() {
  [[ -d /etc/php ]] || (( ${ENABLED[php]:-0} == 1 ))
}

# MB the kernel pins for OPcache: vm.nr_hugepages x 2 MB, from the same
# formula and inputs configure_sysctl uses.  The target is booked, never the
# live HugePages_Total: a partial allocation (87 of 296) varies per boot and
# would break install/--optimize parity, and the requested count is the
# conservative side.  0 in a container (see host_is_container).
hugepages_reserved_mb() {
  local ram_mb=${1:-0} pages
  hugepages_php_present || { printf 0; return 0; }
  host_is_container && { printf 0; return 0; }
  pages=$(sysctl_hugepages_target "$ram_mb" 1)
  [[ $pages =~ ^[0-9]+$ ]] || pages=0
  printf '%s' $(( pages * 2 ))
}

# A --php run on a host whose --basic ran without PHP left the managed
# vm.nr_hugepages at 0, while the memory plan booked the pages and
# huge_code_pages stayed off until the next --optimize (1.22.2 audit).
# Bring the managed line to the configure_sysctl target and apply it now.
# Only touches a setup.sh-managed /etc/sysctl.conf; no-op in a container.
sysctl_hugepages_sync() {
  local file=${1:-/etc/sysctl.conf} want cur
  [[ -f $file ]] && grep -q '^# BEGIN setup.sh tuning' "$file" || return 0
  host_is_container && return 0
  want=$(sysctl_hugepages_target "$(mem_total_mb)" 1)
  [[ $want =~ ^[0-9]+$ ]] || return 0
  cur=$(sed -n 's/^vm\.nr_hugepages[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | tail -n1)
  [[ $cur == "$want" ]] && return 0
  if [[ -n $cur ]]; then
    sed -i "s/^vm\.nr_hugepages[[:space:]]*=.*/vm.nr_hugepages = ${want}/" "$file"
  else
    sed -i "s/^# END setup.sh tuning/vm.nr_hugepages = ${want}\n&/" "$file"
  fi
  sysctl -q -w "vm.nr_hugepages=${want}" >/dev/null 2>&1 \
    || warn "vm.nr_hugepages=${want} could not be applied now (it applies at the next boot)"
  info "OPcache huge pages: vm.nr_hugepages ${cur:-unset} -> ${want}"
}

# fs.file-max / fs.nr_open target: 1024 per MB of RAM within 1M..10M, raised
# (within the same 10M ceiling) to the sum of the managed services' LimitNOFILE
# values when that is larger (nofile_plan_sum, lib/optimize.sh).  The sum
# counts only units present on the host, so a host without MariaDB or
# Elasticsearch keeps the RAM-based value.
sysctl_file_max_target() {
  local ram_mb=${1:-1024} file_max sum=""
  file_max=$(( ram_mb * 1024 ))
  if (( file_max < 1048576 )); then file_max=1048576; fi
  if (( file_max > 10485760 )); then file_max=10485760; fi
  if declare -F nofile_plan_sum >/dev/null 2>&1; then
    sum=$(nofile_plan_sum 2>/dev/null || true)
  fi
  if [[ $sum =~ ^[0-9]+$ ]] && (( sum > file_max )); then
    file_max=$sum
    if (( file_max > 10485760 )); then file_max=10485760; fi
    info "fs.file-max/fs.nr_open raised to ${file_max}: the services' LimitNOFILE values add up to ${sum}" >&2
  fi
  printf '%s' "$file_max"
}

# fs.nr_open target (1.22.5): the file-max target, and at least twice the
# largest managed LimitNOFILE (nofile_plan; the PAM nofile 1048576 counts
# too), so one later raise of a unit limit still fits under the kernel
# ceiling (systemd refuses to start a unit whose LimitNOFILE is above it).
sysctl_nr_open_target() {
  local file_max=${1:-1048576} biggest=1048576 v
  if declare -F nofile_plan >/dev/null 2>&1; then
    nofile_plan >/dev/null 2>&1 || true
    for v in "${NOFILE_PLAN_NGINX_UNIT:-}" "${NOFILE_PLAN_PHP_UNIT:-}" "${NOFILE_PLAN_VALKEY_UNIT:-}" \
             "${NOFILE_PLAN_MARIADB_UNIT:-}" "${NOFILE_PLAN_ELASTIC_UNIT:-}"; do
      if [[ $v =~ ^[0-9]+$ ]] && (( v > biggest )); then biggest=$v; fi
    done
  fi
  v=$(( biggest * 2 ))
  if (( v < file_max )); then v=$file_max; fi
  printf '%s' "$v"
}

# The system's own value of fs.nr_open / fs.file-max (1.22.5): the live
# value, unless it is the one our managed /etc/sysctl.conf set (OURS, read
# before the file is rewritten); then the value recorded before the first
# run (STATE_DIR/sysctl-orig-KEY), or nothing when none was recorded.  On
# stock Ubuntu systemd raises nr_open (~1073741816) and file-max (LONG_MAX)
# at boot.  SYSCTL_LIVE_NR_OPEN / SYSCTL_LIVE_FILE_MAX are test hooks.
sysctl_fd_system_value() {
  local key=$1 ours=${2:-} live="" proc
  case $key in
    fs.nr_open)  live=${SYSCTL_LIVE_NR_OPEN:-};  proc=/proc/sys/fs/nr_open ;;
    fs.file-max) live=${SYSCTL_LIVE_FILE_MAX:-}; proc=/proc/sys/fs/file-max ;;
    *) return 0 ;;
  esac
  if [[ -z $live && -r $proc ]]; then live=$(< "$proc"); fi
  live=${live//[[:space:]]/}
  if [[ $live =~ ^[0-9]+$ && -n $ours && $live == "$ours" ]]; then
    live=$(cat "${STATE_DIR}/sysctl-orig-${key}" 2>/dev/null || true)
    live=${live//[[:space:]]/}
  fi
  if [[ $live =~ ^[0-9]+$ ]]; then printf '%s' "$live"; fi
  return 0
}

# Value configure_sysctl writes for KEY (fs.nr_open / fs.file-max), or
# nothing when the system's own value is already at least TARGET: the key is
# then left to the kernel (never written below it).  1.22.4 wrote the 1M-10M
# targets unconditionally, which lowered systemd's boot values.
sysctl_fd_ceiling_value() {
  local key=$1 target=$2 ours=${3:-} sys
  sys=$(sysctl_fd_system_value "$key" "$ours")
  if [[ $sys =~ ^[0-9]+$ ]] && (( ${#sys} > ${#target} || (${#sys} == ${#target} && sys >= target) )); then
    return 0
  fi
  printf '%s' "$target"
}

# Finish the fd ceilings in FILE after the dedupe: a key left to the kernel
# (empty value) loses the base template's line too, and a live value our old
# line had lowered goes back up to the system's own value now instead of at
# the next boot (only ever raised).
sysctl_fd_ceiling_apply() {
  local file=$1 file_max=$2 nr_open=$3 ours_file_max=${4:-} ours_nr_open=${5:-}
  local key val ours sys live
  for key in fs.file-max fs.nr_open; do
    if [[ $key == fs.file-max ]]; then val=$file_max ours=$ours_file_max; else val=$nr_open ours=$ours_nr_open; fi
    [[ -z $val ]] || continue
    sed_in_place -E "/^[[:space:]]*${key//./\\.}[[:space:]]*=/d" "$file"
    sys=$(sysctl_fd_system_value "$key" "$ours")
    live=$(sysctl -n "$key" 2>/dev/null || true)
    if [[ $sys =~ ^[0-9]+$ && $live =~ ^[0-9]+$ ]] \
       && (( ${#sys} > ${#live} || (${#sys} == ${#live} && sys > live) )); then
      sysctl -q -w "${key}=${sys}" >/dev/null 2>&1 || true
    fi
    info "${key}: left at the system value ${sys:-unknown} (not lowered)"
  done
  return 0
}

configure_sysctl() {
  step "sysctl tweaks"
  record_sysctl_values
  record_original /etc/sysctl.conf sysctl.conf
  record_original /etc/sysctl.d/99-sysctl.conf sysctl.d-99-sysctl.conf
  # Our previous fd ceilings, read before the file is replaced: a live value
  # equal to them is ours, not the system's (sysctl_fd_system_value).
  local ours_file_max ours_nr_open
  ours_file_max=$(sysctl_file_value /etc/sysctl.conf fs.file-max 2>/dev/null || true)
  ours_nr_open=$(sysctl_file_value /etc/sysctl.conf fs.nr_open 2>/dev/null || true)

  local sysctl_src="${SCRIPT_DIR}/configs/system/sysctl.conf"
  if [[ -f $sysctl_src ]]; then
    install -m 644 "$sysctl_src" /etc/sysctl.conf
  else
    blob_sysctl > /etc/sysctl.conf
  fi
  sysctl_drop_host_overrides /etc/sysctl.conf

  # Layered, hardware-aware overrides on top of the base profile.  These
  # matter on busy web/database hosts: larger socket buffers, more orphan
  # sockets, a 1 GiB SysV shared-memory segment and a small security baseline.
  local cpu ram_mb min_free shmall
  local somaxconn syn_backlog netdev_backlog tw_buckets max_orphans
  local file_max inotify_watches conntrack_max ipfrag_high ipfrag_low
  local file_max_target nr_open nr_open_target fd_lines
  local arp_thresh3 arp_thresh2
  cpu=$(effective_cpus)
  (( cpu > 0 )) || cpu=1
  ram_mb=$(mem_total_mb)
  (( ram_mb > 0 )) || ram_mb=1024
  min_free=$(( ram_mb * 1024 / 100 ))       # 1% of RAM, in kB
  # The 66 MB floor suits hosts with a few GB of RAM; on a 1-2 GB VPS it
  # would reserve 3-6% of memory that nothing may use, so the floor scales.
  if (( ram_mb >= 4096 )); then
    (( min_free < 67584 ))  && min_free=67584
  else
    (( min_free < 16384 ))  && min_free=16384
  fi
  (( min_free > 262144 )) && min_free=262144
  # The kernel or the provider may already keep a higher value (KVM memory
  # ballooning raises min_free_kbytes on small guests).  Never lower it: the
  # kernel would raise it again and the report would show drift every run.
  local live_min_free
  live_min_free=$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo 0)
  if [[ $live_min_free =~ ^[0-9]+$ ]] && (( live_min_free > min_free && live_min_free <= 262144 )); then
    min_free=$live_min_free
  fi
  shmall=$(( 1073741824 / 4096 ))
  # Scale listener/connection limits with CPU count and RAM.  The clamps keep
  # a 1 GB VPS conservative and stop a 256-core host from reserving absurd
  # amounts of unswappable kernel memory.
  # somaxconn is shared with effective_backlog (service listen backlogs).
  somaxconn=$(sysctl_target_somaxconn)
  syn_backlog=$somaxconn
  netdev_backlog=$(( cpu * 2048 ));     (( netdev_backlog < 4096 )) && netdev_backlog=4096;    (( netdev_backlog > 65536 )) && netdev_backlog=65536
  tw_buckets=$(( ram_mb * 16 ));        (( tw_buckets < 65536 )) && tw_buckets=65536;          (( tw_buckets > 2621440 )) && tw_buckets=2621440
  max_orphans=$(( ram_mb * 2 ));        (( max_orphans < 16384 )) && max_orphans=16384;        (( max_orphans > 262144 )) && max_orphans=262144
  file_max_target=$(sysctl_file_max_target "$ram_mb")
  nr_open_target=$(sysctl_nr_open_target "$file_max_target")
  # Never below the system's own value: a key whose system value is already
  # at least the target is not written at all (1.22.5).
  file_max=$(sysctl_fd_ceiling_value fs.file-max "$file_max_target" "$ours_file_max")
  nr_open=$(sysctl_fd_ceiling_value fs.nr_open "$nr_open_target" "$ours_nr_open")
  fd_lines=""
  [[ -n $file_max ]] && fd_lines+="fs.file-max = ${file_max}"$'\n'
  [[ -n $nr_open ]] && fd_lines+="fs.nr_open = ${nr_open}"$'\n'
  inotify_watches=$(( ram_mb * 4096 )); (( inotify_watches < 524288 )) && inotify_watches=524288; (( inotify_watches > 2097152 )) && inotify_watches=2097152
  conntrack_max=$(( ram_mb * 16 ));     (( conntrack_max < 65536 )) && conntrack_max=65536;    (( conntrack_max > 4194304 )) && conntrack_max=4194304
  if host_is_vps; then
    # Provider conntrack/hypervisor limits make larger tables unreachable;
    # they only pin guest kernel memory.
    conntrack_max=$(( ram_mb * 8 ));    (( conntrack_max < 32768 )) && conntrack_max=32768;    (( conntrack_max > 1048576 )) && conntrack_max=1048576
    (( netdev_backlog > 16384 )) && netdev_backlog=16384
  fi
  # Writeback thresholds in bytes.  The stock 30%/5% ratios let a 64 GB host
  # accumulate ~19 GB of dirty pages and then stall every writer (nginx
  # cache, Elasticsearch segments, logs) on the flush; rotational disks get
  # tighter caps.
  local disk_class dirty_bg_mb dirty_mb rmem_max
  disk_class=$(storage_class)
  read -r dirty_bg_mb dirty_mb <<< "$(sysctl_dirty_thresholds_mb "$ram_mb" "$disk_class")"
  # Socket buffer maxima: 32 MB is plenty for 1-10G links; a small host
  # cannot afford 32 MB per socket.
  rmem_max=33554432
  (( ram_mb < 4096 )) && rmem_max=16777216
  # The per-socket *default* buffer is what every idle keep-alive connection
  # costs; 256 KB on a 1-2 GB VPS with 10k sockets is most of its RAM.
  local tcp_default=262144 swappiness=10 shmmax=1073741824
  if (( ram_mb < 4096 )); then
    tcp_default=87380
  elif (( ram_mb < 16384 )); then
    tcp_default=131072
  fi
  # Flash storage pays little for the occasional swap-in, so keep anonymous
  # pages resident and leave RAM to the page cache (database and index
  # files); rotational disks keep the conservative 10.
  case $disk_class in nvme|ssd) swappiness=1 ;; esac
  # A 1 GiB SysV segment is the historical maximum; never let it exceed a
  # quarter of RAM on a small host.
  (( ram_mb / 4 < 1024 )) && shmmax=$(( ram_mb / 4 * 1048576 ))
  shmall=$(( shmmax / 4096 ))
  # The widened ephemeral range covers the service ports; reserve them so an
  # outbound connection can never take 3306/6379/9000/9200 before a restart
  # binds.  9000 is the supported PHP-FPM TCP listener (the installer uses a
  # Unix socket, but an adopted host may keep 127.0.0.1:9000).
  local reserved_ports
  reserved_ports=$(printf '%s\n' 3306 6379 9000 9200 9300 "$(sshd_listen_ports)" \
    | grep -E '^[0-9]+$' | awk '$1 >= 1024' | sort -nu | paste -sd, -)
  # Busy dedicated hosts with several queues drain more packets per softirq
  # pass; a VPS shares its hypervisor queue and keeps the kernel default.
  local netdev_budget_lines=""
  if (( cpu >= 8 )) && ! host_is_vps; then
    netdev_budget_lines=$'net.core.netdev_budget = 600\nnet.core.netdev_budget_usecs = 8000'
  fi
  # The base profile also sets the net.nf_conntrack_max alias, which the
  # de-duplication cannot match against net.netfilter.nf_conntrack_max.
  sed_in_place -E '/^[[:space:]]*net\.nf_conntrack_max[[:space:]]*=/d' /etc/sysctl.conf
  # Fragment reassembly memory: never below the kernel default (4 MB high /
  # 3 MB low since 4.17, when the CVE-2018-5391 rb-tree fix made larger
  # queues safe).  The old 256 KB-4 MB range (RAM x 32) put every host under
  # 128 GB below the default and dropped large fragmented UDP/IPv6 packets.
  ipfrag_high=$(( ram_mb * 64 ))
  (( ipfrag_high < 4194304 )) && ipfrag_high=4194304
  (( ipfrag_high > 16777216 )) && ipfrag_high=16777216
  ipfrag_low=$(( ipfrag_high * 3 / 4 ))
  # Huge pages for opcache.huge_code_pages: (OPcache + JIT buffer)/2 + 8
  # pages, on 4 GB+ hosts with PHP only (sysctl_hugepages_target).  Reserved
  # at boot and never swapped; plan_memory_budget books the same count
  # through hugepages_reserved_mb.
  local has_php=0
  hugepages_php_present && has_php=1
  hugepages=$(sysctl_hugepages_target "$ram_mb" "$has_php")
  arp_thresh3=$(( cpu * 1024 ));        (( arp_thresh3 < 2048 )) && arp_thresh3=2048;          (( arp_thresh3 > 262144 )) && arp_thresh3=262144
  arp_thresh2=$(( arp_thresh3 / 2 ))
  cat >> /etc/sysctl.conf <<EOF

# BEGIN setup.sh tuning
# Larger socket buffers and connection headroom for high-request-rate sites.
net.core.optmem_max = 262144
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${rmem_max}
net.ipv4.tcp_rmem = 8192 ${tcp_default} ${rmem_max}
net.ipv4.tcp_wmem = 8192 ${tcp_default} ${rmem_max}
net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${netdev_backlog}
${netdev_budget_lines}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_max_orphans = ${max_orphans}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_local_reserved_ports = ${reserved_ports}
net.ipv4.tcp_keepalive_time = 120
net.ipv4.neigh.default.gc_thresh1 = 32
net.ipv4.neigh.default.gc_thresh2 = ${arp_thresh2}
net.ipv4.neigh.default.gc_thresh3 = ${arp_thresh3}
# High mark first: at boot the change is upward from the kernel default (see
# ipfrag_sysctl_lines in lib/os.sh).
$(ipfrag_sysctl_lines "$ipfrag_high" "$ipfrag_low")
net.netfilter.nf_conntrack_max = ${conntrack_max}
# Byte thresholds override the percentage knobs from the base profile.
vm.dirty_background_bytes = $(( dirty_bg_mb * 1048576 ))
vm.dirty_bytes = $(( dirty_mb * 1048576 ))
${fd_lines}fs.inotify.max_user_watches = ${inotify_watches}
vm.min_free_kbytes = ${min_free}
vm.swappiness = ${swappiness}
# OPcache huge pages (2 MB each); 0 on a host below 4 GB of RAM.
vm.nr_hugepages = ${hugepages}
kernel.shmmax = ${shmmax}
kernel.shmall = ${shmall}

# Security hardening.
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Challenge-ACK rate (RFC 5961).  CVE-2016-5696 was an off-path side channel
# through the old global, fixed challenge-ACK counter; since Linux 4.7 the
# limit is randomized, and since 6.0 the counter is per network namespace and
# off by default (limit INT_MAX).  1000 keeps a bounded, randomized limit.
net.ipv4.tcp_challenge_ack_limit = 1000
# END setup.sh tuning
EOF
  chmod 644 /etc/sysctl.conf

  # The base profile above and the hardware-aware block both define some of
  # the same keys (somaxconn, tcp_max_syn_backlog, file-max, ...).  Whichever
  # line comes last wins, so the file works, but it is ambiguous to audit and
  # one edit can silently undo the other.  Keep only the final definition of
  # each key; order and comments for distinct keys are preserved.
  sysctl_dedupe_keys /etc/sysctl.conf
  sysctl_fd_ceiling_apply /etc/sysctl.conf "$file_max" "$nr_open" "$ours_file_max" "$ours_nr_open"
  if [[ -d /etc/sysctl.d ]] && [[ ! -e /etc/sysctl.d/99-sysctl.conf && ! -L /etc/sysctl.d/99-sysctl.conf ]]; then
    ln -s ../sysctl.conf /etc/sysctl.d/99-sysctl.conf
  fi

  # Load the modules that own the sysctls below before systemd-sysctl runs at
  # boot; otherwise every boot logs "No such file or directory" for bbr/fq/
  # conntrack even though the values are applied later.
  mkdir -p /etc/modules-load.d
  record_original /etc/modules-load.d/setup-network.conf modules-load-setup-network.conf
  local -a net_mods=(nf_conntrack)
  [[ $QDISC == fq ]] && net_mods+=(sch_fq)
  [[ $TCP_CC == bbr ]] && net_mods+=(tcp_bbr)
  printf '%s\n' "${net_mods[@]}" > /etc/modules-load.d/setup-network.conf
  chmod 644 /etc/modules-load.d/setup-network.conf
  local mod
  for mod in "${net_mods[@]}"; do
    modprobe "$mod" || warn "Could not load ${mod} (kernel may not provide it)"
  done

  # Keep the selected qdisc even when systemd-sysctl runs again (a package
  # upgrade restarts it, and /usr/lib/sysctl.d/55-bufferbloat.conf would
  # otherwise put fq_codel back).  This drop-in has no dependency on a
  # congestion-control module, so it is safe to apply before modules-load.
  # The congestion control stays in the oneshot unit below, which runs after
  # the modules are available.
  record_original /etc/sysctl.d/90-setup-network.conf sysctl.d-90-setup-network.conf
  cat > /etc/sysctl.d/90-setup-network.conf <<EOF
# Managed by setup.sh: keep the ${QDISC} qdisc after systemd-sysctl re-runs.
# tcp_congestion_control=${TCP_CC} is applied by setup-network-tuning.service
# once the required modules are loaded.
net.core.default_qdisc = ${QDISC}
EOF
  chmod 644 /etc/sysctl.d/90-setup-network.conf
  sysctl -w "net.core.default_qdisc=${QDISC}" >/dev/null 2>&1 \
    || warn "Could not set net.core.default_qdisc=${QDISC}"

  # A live kernel can still have the old low mark above the new high mark.
  # Make room before the file is applied; the file itself writes high first
  # (the boot order, see ipfrag_sysctl_lines), so a downward change needs the
  # low mark lowered here.
  # IPv6 takes its pair from the base template (the kernel default); a host
  # tuned by an older release still runs 192/256 KB there.
  local fam pfx cur_low cur_high want_low want_high
  for fam in 4 6; do
    if [[ $fam == 4 ]]; then
      pfx=net/ipv4/ipfrag; want_low=$ipfrag_low; want_high=$ipfrag_high
    else
      pfx=net/ipv6/ip6frag
      want_low=$(sed -nE 's/^[[:space:]]*net\.ipv6\.ip6frag_low_thresh[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' /etc/sysctl.conf | tail -n1)
      want_high=$(sed -nE 's/^[[:space:]]*net\.ipv6\.ip6frag_high_thresh[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' /etc/sysctl.conf | tail -n1)
      [[ $want_low =~ ^[0-9]+$ && $want_high =~ ^[0-9]+$ ]] || continue
    fi
    [[ -r /proc/sys/${pfx}_low_thresh && -r /proc/sys/${pfx}_high_thresh ]] || continue
    cur_low=$(< "/proc/sys/${pfx}_low_thresh")
    cur_high=$(< "/proc/sys/${pfx}_high_thresh")
    if [[ $cur_low =~ ^[0-9]+$ ]] && (( cur_low > want_high )); then
      sysctl -w "${pfx//\//.}_low_thresh=${want_low}" >/dev/null 2>&1 || true
    elif [[ $cur_high =~ ^[0-9]+$ ]] && (( cur_high < want_low )); then
      sysctl -w "${pfx//\//.}_high_thresh=${want_high}" >/dev/null 2>&1 || true
    fi
  done

  # Record the base template's own keys too (first run only), so --purge can
  # put every live value back, not just the hardware block.
  local -a profile_keys=()
  mapfile -t profile_keys < <(sysctl_file_keys /etc/sysctl.conf)
  record_sysctl_values "${profile_keys[@]}"
  sysctl -e -p /etc/sysctl.conf || warn "One or more sysctl values could not be applied"
  ufw_align_sysctl /etc/ufw/sysctl.conf /etc/sysctl.conf

  # The congestion-control module and qdisc are module-owned and
  # systemd-sysctl runs before modules-load on Ubuntu, which logs "No such
  # file or directory" on every boot. Apply them from a small oneshot unit
  # after the modules are available instead.
  local net_unit=/etc/systemd/system/setup-network-tuning.service net_unit_tmp
  record_original "$net_unit" setup-network-tuning.service
  # Rewrite the unit (and reload systemd) only when its content changes, so a
  # repeated --optimize on a converged host touches nothing here.
  net_unit_tmp=$(tmp_file) || die "Could not stage setup-network-tuning.service"
  network_tuning_unit_text "${net_mods[@]}" > "$net_unit_tmp"
  if commit_if_changed "$net_unit" "$net_unit_tmp"; then
    chmod 644 "$net_unit"
    systemctl daemon-reload || true
  fi
  systemctl enable setup-network-tuning.service >/dev/null 2>&1 || true
  # restart (not start): the oneshot stays "active" from a previous run, and a
  # start would not re-apply a changed qdisc/congestion-control value.
  systemctl restart setup-network-tuning.service \
    || warn "Could not apply ${TCP_CC}/${QDISC} tuning"
  # Report-only: which NICs keep their old root qdisc until the next reboot.
  net_qdisc_report "$QDISC"

  # Late enforcement pass.  Foreign units (an old hand-written tcp-bbr
  # service, rc.local, a provider agent) can write a managed key after
  # systemd-sysctl; this timer re-applies the profile 90 s after boot so every
  # host ends in the same state without deleting the foreign files.
  local final_unit=/etc/systemd/system/setup-sysctl-final.service
  local final_timer=/etc/systemd/system/setup-sysctl-final.timer
  record_original "$final_unit" setup-sysctl-final.service
  record_original "$final_timer" setup-sysctl-final.timer
  local final_unit_tmp final_timer_tmp
  final_unit_tmp=$(tmp_file) || die "Could not stage setup-sysctl-final.service"
  final_timer_tmp=$(tmp_file) || die "Could not stage setup-sysctl-final.timer"
  sysctl_final_unit_text "${net_mods[@]}" > "$final_unit_tmp"
  sysctl_final_timer_text > "$final_timer_tmp"
  if commit_if_changed "$final_unit" "$final_unit_tmp"; then
    chmod 644 "$final_unit"
    systemctl daemon-reload || true
  fi
  if commit_if_changed "$final_timer" "$final_timer_tmp"; then
    chmod 644 "$final_timer"
    systemctl daemon-reload || true
  fi
  systemctl enable --now setup-sysctl-final.timer >/dev/null 2>&1 \
    || warn "Could not enable the late sysctl enforcement timer"
}

# Readahead (kB) for disks whose queue/rotational flag is 1.  The storage
# class owns the decision: only a host classified hdd gets the large
# sequential readahead; on nvme/ssd a "rotational" disk is a mis-reporting
# virtual device and takes the same 128 kB as the flash rules.
io_rotational_read_ahead_kb() {
  case ${1:-} in
    hdd) printf '1024' ;;
    *)   printf '128' ;;
  esac
}

# Storage-class dependent host settings that no service file carries:
#   * transparent huge pages -> madvise (MariaDB and Valkey both warn about
#     "always"; latency spikes under memory pressure)
#   * periodic TRIM on SSD/NVMe
#   * I/O scheduler and readahead per device class via a udev rule
# Shared by --basic and --optimize; everything is recorded for --purge.
configure_io_tuning() {
  step "Storage/THP profile"
  ensure_state
  local class rot_ra_kb unit=/etc/systemd/system/setup-io-tuning.service
  local rule=/etc/udev/rules.d/60-setup-io.rules
  class=$(storage_class)
  rot_ra_kb=$(io_rotational_read_ahead_kb "$class")
  record_original "$unit" setup-io-tuning.service
  record_original "$rule" udev-60-setup-io.rules
  cat > "$unit" <<'EOF'
[Unit]
Description=Apply transparent-hugepage tuning (setup.sh)
After=local-fs.target
# madvise only affects mappings created after the write, so it must happen
# before the services that allocate large arenas at startup.
Before=mariadb.service valkey-server.service redis-server.service elasticsearch.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in enabled defrag; do p=/sys/kernel/mm/transparent_hugepage/$f; [ -w "$p" ] && echo madvise > "$p"; done; exit 0'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit"
  # Unquoted here-document: only ${rot_ra_kb} expands (udev's own $-free
  # match syntax is used throughout).
  cat > "$rule" <<EOF
# setup.sh: I/O scheduler and readahead by device class.
# Whole disks only: partitions have no queue/scheduler or bdi attributes and
# udev logs an error per partition when a rule tries to set them.
# NVMe: no scheduler (the device queues), small readahead for random I/O.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none", ATTR{bdi/read_ahead_kb}="128"
# Every other real disk is classified by its rotational flag, so SATA/SAS,
# virtio, Xen and MMC devices all get a rule.  Stacked and virtual devices
# (dm/md/loop/zram/ram) have no scheduler and are skipped.
# SSD and paravirtual flash: mq-deadline, small readahead.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL!="nvme*", KERNEL!="dm-*", KERNEL!="md*", KERNEL!="loop*", KERNEL!="zram*", KERNEL!="ram*", KERNEL!="sr*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{bdi/read_ahead_kb}="128"
# Disks that report themselves rotational.  The readahead follows the
# storage class setup.sh detected (or STORAGE_CLASS pins): ${rot_ra_kb} kB for
# class "${class}".  A virtual SCSI disk on flash often still reports
# rotational=1, and 1024 kB suits only real sequential HDD scans.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL!="nvme*", KERNEL!="dm-*", KERNEL!="md*", KERNEL!="loop*", KERNEL!="zram*", KERNEL!="ram*", KERNEL!="sr*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{bdi/read_ahead_kb}="${rot_ra_kb}"
EOF
  # md/dm arrays on flash: readahead only (no scheduler on a stacked device).
  # The filesystem reads through the array's own bdi, which the kernel sizes
  # from the stripe (a 2 x 512K RAID0 over NVMe gets 2048 kB), so the member
  # disks' 128 kB never applied to the data path.  HDD arrays keep the
  # stripe-derived value: a wide spinning array benefits from it.
  case $class in
    nvme|ssd)
      cat >> "$rule" <<'EOF'
# md/dm on flash: small readahead on the array the filesystem actually uses.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="md*|dm-*", ATTR{bdi/read_ahead_kb}="128"
EOF
      ;;
  esac
  chmod 644 "$rule"
  systemctl daemon-reload || true
  systemctl enable setup-io-tuning.service >/dev/null 2>&1 || true
  systemctl restart setup-io-tuning.service 2>/dev/null || warn "Could not apply the THP setting"
  udevadm control --reload-rules 2>/dev/null || true
  # Re-trigger only what the rules above can match: whole, non-empty disks
  # (sysname patterns OR together; the other filters AND).  A blanket trigger
  # replays every block device through the distribution's rules too, and on
  # BMC hosts sg3-utils-udev logged "SCSI device sdX has no device ID" for
  # each empty virtual floppy/CD-ROM on every --optimize.
  udevadm trigger --action=change --subsystem-match=block \
    --property-match=DEVTYPE=disk --attr-nomatch=size=0 \
    --sysname-match='nvme*' --sysname-match='sd*' --sysname-match='vd*' \
    --sysname-match='xvd*' --sysname-match='hd*' --sysname-match='mmcblk*' \
    --sysname-match='md*' --sysname-match='dm-*' 2>/dev/null || true
  case $class in
    nvme|ssd)
      if systemctl list-unit-files fstrim.timer >/dev/null 2>&1; then
        if ! systemctl is-enabled --quiet fstrim.timer 2>/dev/null; then
          touch "${STATE_DIR}/fstrim-timer-enabled"
        fi
        systemctl enable --now fstrim.timer >/dev/null 2>&1 || warn "Could not enable fstrim.timer"
      fi
      ;;
  esac
  info "Storage class ${class}: THP=madvise, scheduler/readahead rule installed$( [[ $class != hdd ]] && printf ', fstrim.timer enabled')"
}

configure_limits() {
  step "Security limits"
  local limits_src="${SCRIPT_DIR}/configs/system/limits.conf"
  local dropin=/etc/security/limits.d/99-setup.conf
  mkdir -p /etc/security/limits.d
  # Record the original files so --purge can put the machine back.
  record_original /etc/security/limits.conf limits.conf
  record_original "$dropin" limits.d-99-setup.conf
  if [[ -f $limits_src ]]; then
    install -m 644 "$limits_src" "$dropin"
  else
    cat > "$dropin" <<'EOF'
elasticsearch soft nofile 1048576
elasticsearch hard nofile 1048576
mysql         soft nofile 1048576
mysql         hard nofile 1048576
valkey        soft nofile 1048576
valkey        hard nofile 1048576
root          soft nofile 1048576
root          hard nofile 1048576
tinyproxy     soft nofile 1048576
tinyproxy     hard nofile 1048576
www-data      soft nofile 1048576
www-data      hard nofile 1048576
*             soft nofile 1048576
*             hard nofile 1048576
EOF
  fi
  chmod 644 "$dropin"
  # Older setup.sh releases replaced /etc/security/limits.conf wholesale.
  # Put the distribution file back when we can prove it is our old copy.
  if [[ -f "${BACKUP_DIR}/limits.conf.recorded" ]] \
     && [[ $(<"${BACKUP_DIR}/limits.conf.recorded") == present ]] \
     && [[ -f "${BACKUP_DIR}/limits.conf" ]] \
     && cmp -s /etc/security/limits.conf "$limits_src"; then
    cp -a "${BACKUP_DIR}/limits.conf" /etc/security/limits.conf
    info "Restored original /etc/security/limits.conf; limits now use the drop-in"
  fi
  cat "$dropin"
}

configure_ufw() {
  step "UFW firewall"
  ensure_state
  if [[ ! -f "${STATE_DIR}/ufw-active-before" ]]; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
      printf 'active\n' > "${STATE_DIR}/ufw-active-before"
    else
      printf 'inactive\n' > "${STATE_DIR}/ufw-active-before"
    fi
  fi
  if [[ ! -f "${STATE_DIR}/ufw-added-before" ]]; then
    ufw show added 2>/dev/null | sort -u > "${STATE_DIR}/ufw-added-before" || true
  fi
  if [[ ! -f "${STATE_DIR}/ufw-defaults-before" ]]; then
    ufw status verbose 2>/dev/null | awk '/^Default:/{print}' \
      > "${STATE_DIR}/ufw-defaults-before" || true
  fi

  ufw --force default deny incoming
  ufw --force default allow outgoing
  # SSH must be rate-limited, not wide open.  A plain `allow` rule lets an
  # unauthenticated client open as many connections as it likes; `ufw limit`
  # blocks an address that opens more than six connections in 30 seconds.
  # Insert the LIMIT at the top so an older plain ALLOW rule (written by this
  # script before 1.8.35 or by a provider image) cannot take precedence, then
  # remove that ALLOW rule.  Allow every effective sshd port, not just 22: a
  # host moved to a custom port would otherwise lose remote access the moment
  # UFW is enabled.
  local ssh_port ssh_limited had_allow
  # ufw limit allows six new connections per 30 s from one address and then
  # drops further attempts until the window clears.  If the caller keeps
  # retrying, each attempt refreshes the window: an operator or an automation
  # host that runs many short ssh/scp commands is locked out for minutes and,
  # on some kernels, the reject surfaces as "Connection refused".  A human
  # never hits it; a provisioning/CI address does.  SETUP_UFW_SSH_LIMIT=0
  # writes a plain ALLOW rule for this run (documented in the README).
  local ssh_limit=${SETUP_UFW_SSH_LIMIT:-1}
  [[ $ssh_limit == 0 ]] || ssh_limit=1
  if (( ! ssh_limit )); then
    while IFS= read -r ssh_port; do
      [[ $ssh_port =~ ^[0-9]+$ ]] || continue
      ufw delete limit "${ssh_port}/tcp" >/dev/null 2>&1 || true
      ufw insert 1 allow "${ssh_port}/tcp" >/dev/null 2>&1 \
        || ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
      info "UFW: SSH port ${ssh_port}/tcp is a plain ALLOW rule (SETUP_UFW_SSH_LIMIT=0)"
    done < <(sshd_listen_ports)
  else
  while IFS= read -r ssh_port; do
    [[ $ssh_port =~ ^[0-9]+$ ]] || continue
    ssh_limited=0
    had_allow=0
    if ufw show added 2>/dev/null | grep -qE "^ufw allow ${ssh_port}/tcp($| )|^ufw allow ${ssh_port}($| )"; then
      had_allow=1
    fi
    # The OpenSSH application profile is what most images ship.  It covers
    # port 22 only; treat it as the plain allow rule it is.
    if [[ $ssh_port == 22 ]] && ufw show added 2>/dev/null | grep -qxF 'ufw allow OpenSSH'; then
      had_allow=1
    fi

    if ufw show added 2>/dev/null | grep -qE "^ufw limit ${ssh_port}/tcp($| )|^ufw limit ${ssh_port}($| )"; then
      ssh_limited=1
    else
      # ufw treats allow and limit for the same port as the same rule: it
      # refuses to insert a limit while a plain allow exists, and a later
      # `delete allow` would remove the limit too.  Remove the plain allow
      # first, then insert the limit; if that fails, restore the allow so a
      # remote operator cannot be locked out.
      if (( had_allow )); then
        if ufw show added 2>/dev/null | grep -qxF "ufw allow ${ssh_port}/tcp"; then
          ufw delete allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
        fi
        if ufw show added 2>/dev/null | grep -qxF "ufw allow ${ssh_port}"; then
          ufw delete allow "${ssh_port}" >/dev/null 2>&1 || true
        fi
        if [[ $ssh_port == 22 ]] && ufw show added 2>/dev/null | grep -qxF 'ufw allow OpenSSH'; then
          ufw delete allow OpenSSH >/dev/null 2>&1 || true
        fi
      fi
      if ufw insert 1 limit "${ssh_port}/tcp" 2>/dev/null \
         || ufw limit "${ssh_port}/tcp" 2>/dev/null; then
        ssh_limited=1
        info "UFW: rate-limited SSH port ${ssh_port}/tcp (ufw limit)"
      fi
    fi

    if (( ! ssh_limited )); then
      # Never leave the host without an SSH rule.
      warn "Could not rate-limit SSH port ${ssh_port}/tcp; restoring a plain ALLOW rule to avoid lockout"
      ufw status 2>/dev/null | grep -qE "^${ssh_port}(/tcp)?( \(v6\))?[[:space:]]+ALLOW" \
        || ufw insert 1 allow "${ssh_port}/tcp" 2>/dev/null \
        || ufw allow "${ssh_port}/tcp" 2>/dev/null || true
    fi
  done < <(sshd_listen_ports)
  fi
  ufw allow 80 || true
  ufw allow 443 || true
  ufw --force enable
  # ufw only exists from here on: the same align inside configure_sysctl runs
  # before the package is installed on a pristine host, so without this call a
  # fresh install would leave ufw's stock sysctl.conf to overwrite the managed
  # profile on every boot while --optimize (ufw present) aligned it.
  ufw_align_sysctl /etc/ufw/sysctl.conf /etc/sysctl.conf
  ufw status verbose || true

  ufw show added 2>/dev/null | sort -u > "${STATE_DIR}/ufw-added-after" || true
  comm -13 "${STATE_DIR}/ufw-added-before" "${STATE_DIR}/ufw-added-after" \
    > "${STATE_DIR}/ufw-added" 2>/dev/null || true
}

install_basic() {
  local server=${OPT[basic.server]:-}
  local host=${OPT[basic.host]:-}
  local tz=${OPT[basic.time]:-Asia/Manila}
  local swap=${OPT[basic.swap]:-}

  if [[ -z $server ]]; then
    server=$(detect_server_type)
    OPT[basic.server]=$server
    info "Auto-detected server type: ${server}"
  fi

  configure_dns
  # Before the first apt run: needrestart's who(1) call follows every one.
  configure_who_apparmor
  update_system

  # Let the tuner decide from the actual cpufreq interface.  --optimize calls
  # the same function, so a host with a usable performance governor gets it
  # from either command.
  configure_cpu_governor
  configure_cpu_mitigations

  # dmidecode (installed here) gives the nominal installed RAM for the
  # generated hostname, even when the kernel reserves some of it.
  install_basic_tools

  if [[ -z $host ]] && host=$(basic_applied_value hostname); then
    info "Keeping hostname ${host} (applied by an earlier run; pass host= to change it)"
  elif [[ -z $host ]]; then
    host=$(generate_hostname)
    [[ -n $host ]] || die "Could not auto-generate a hostname"
    validate_hostname "$host" || die "Generated hostname '${host}' is invalid"
    OPT[basic.host]=$host
    info "Auto-generated hostname: ${host}"
  fi

  configure_hostname "$host"
  configure_timezone "$tz"

  if [[ -n $swap ]]; then
    configure_swap "$swap"
  else
    configure_swap_auto
  fi

  configure_sysctl
  configure_limits
  configure_io_tuning
  ensure_log_dirs
  configure_logrotate

  apt_install cron
  systemctl enable --now cron || warn "Could not enable/start cron"
  systemctl status cron --no-pager || true
  write_cron

  apt_install ufw
  configure_ufw

  apt_clean
  ok "Basic server setup complete"
}

