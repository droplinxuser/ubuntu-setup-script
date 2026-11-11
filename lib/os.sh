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

update_system() {
  step "Ubuntu update"
  apt_update
  # A failed upgrade can leave dpkg half-configured (for example when a
  # postinst is interrupted by a full disk or a provider console reset).
  # Repair the package state once and retry, instead of continuing a
  # provisioning run on top of a broken dpkg database.
  if ! apt-get upgrade "${APT_OPTS[@]}"; then
    warn "apt upgrade failed; repairing dpkg state and retrying once"
    dpkg --configure -a || warn "dpkg --configure -a reported an issue"
    apt-get -f install --no-remove "${APT_OPTS[@]}" || warn "apt-get -f install reported an issue"
    apt-get upgrade "${APT_OPTS[@]}" \
      || warn "apt upgrade still failing; continuing with a partially upgraded system"
  fi
}

# True when this CPU exposes frequency scaling and actually offers the
# performance governor.  Some VMs expose a cpufreq directory but only list
# powersave/schedutil; claiming "governor=performance" there is misleading.
cpu_performance_governor_available() {
  local dir=/sys/devices/system/cpu/cpu0/cpufreq
  [[ -d $dir ]] || return 1
  if [[ -r $dir/scaling_available_governors ]]; then
    grep -qw performance "$dir/scaling_available_governors" || return 1
  fi
  return 0
}

configure_cpu_governor() {
  step "CPU governor (dedicated server)"
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
  record_original /etc/default/cpufrequtils cpufrequtils-default
  if ! pkg_ok cpufrequtils; then
    touch "${STATE_DIR}/cpufrequtils-installed"
    # --optimize never runs the full update_system; refresh the lists once
    # so this one install does not fail on a host with stale or empty lists.
    apt_update_once
    apt_install cpufrequtils
  fi
  local cpu_src="${SCRIPT_DIR}/configs/system/cpufrequtils"
  if [[ -f $cpu_src ]]; then
    install -m 644 "$cpu_src" /etc/default/cpufrequtils
  else
    printf 'GOVERNOR="performance"\n' > /etc/default/cpufrequtils
  fi
  cat /etc/default/cpufrequtils

  systemctl daemon-reload || true
  systemctl enable cpufrequtils || warn "Could not enable cpufrequtils"
  systemctl restart cpufrequtils || warn "Could not start cpufrequtils"

  if command -v cpufreq-set >/dev/null 2>&1; then
    cpufreq-set -g performance || warn "cpufreq-set could not set the performance governor"
    cpufreq-info || true
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
  sed_in_place -E '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
  printf '127.0.1.1\t%s\n' "$host" >> /etc/hosts
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
  timedatectl status || true
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
  local avail margin=268435456
  # Never fill the filesystem: keep 256 MiB free after the swap file.  A
  # 50%-of-RAM auto target on a 5 GB VPS used to consume the whole root
  # filesystem (dd has no free-space check of its own).
  avail=$(df -B1 --output=avail / 2>/dev/null | awk 'NR==2{print $1}')
  if [[ $avail =~ ^[0-9]+$ ]] && (( avail < bytes + margin )); then
    die "Not enough free disk for a $(( bytes / 1048576 )) MiB swap file (${avail} bytes available; 256 MiB must stay free)"
  fi
  # Reuse the path in place.  Unlinking a valid /swapfile is unnecessary and
  # would make a failed re-create leave the host with no swap at all.
  : > /swapfile
  if ! fallocate -l "$bytes" /swapfile 2>/dev/null; then
    warn "fallocate failed; falling back to dd"
    local count=$(( (bytes + 1048575) / 1048576 ))
    dd if=/dev/zero of=/swapfile bs=1M count="$count" status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  ensure_swap_fstab
  mark_swap_managed
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
    if [[ $existing -eq $desired ]] && swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      info "Swap file already present with the requested size"
      ensure_swap_fstab
      mark_swap_managed
      swapon --show
      return 0
    fi
    swapoff /swapfile 2>/dev/null || true
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

configure_swap_auto() {
  local ram current target needed old_size new_size
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

  if [[ -f /swapfile ]]; then
    old_size=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      swapoff /swapfile 2>/dev/null || true
      # The old file was counted in "current", so add the difference to it.
      new_size=$(( old_size + needed ))
    else
      new_size=$needed
    fi
  else
    new_size=$needed
  fi

  info "Adding $(numfmt --to=iec "$new_size") to /swapfile to reach 50% of RAM"
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
  net.netfilter.nf_conntrack_max
  fs.file-max fs.nr_open fs.inotify.max_user_watches
  vm.min_free_kbytes kernel.shmmax kernel.shmall
  vm.dirty_background_bytes vm.dirty_bytes vm.dirty_background_ratio vm.dirty_ratio
  vm.swappiness vm.overcommit_memory vm.overcommit_ratio
  net.ipv4.ip_local_reserved_ports net.core.netdev_budget net.core.netdev_budget_usecs
  net.core.default_qdisc net.ipv4.tcp_congestion_control
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

restore_sysctl_values() {
  local key file value
  # Paired keys need care.  The dirty thresholds come as ratio/bytes pairs
  # and writing one zeroes the other, so a recorded 0 is never written back
  # (the tune wrote bytes, which zeroed the live ratio; restoring bytes=0 then
  # left no threshold and --purge logged "Could not restore vm.dirty_bytes=0").
  # Each pair restores whichever recorded value is non-zero, foreground pair
  # first.  ipfrag_low_thresh is written after ipfrag_high_thresh (the kernel
  # rejects a low mark above the live high mark).
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
      vm.dirty_bytes|vm.dirty_ratio|vm.dirty_background_bytes|vm.dirty_background_ratio|net.ipv4.ipfrag_low_thresh) continue ;;
    esac
    ordered+=("$key")
  done
  ordered+=(net.ipv4.ipfrag_low_thresh)
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

# The kernel rejects ipfrag_high_thresh when the new value is below the
# current low threshold (EINVAL).  Writing the low mark first keeps a lower
# high mark valid; only low <= high is required.
ipfrag_sysctl_lines() {
  local high=$1 low=$2
  printf 'net.ipv4.ipfrag_low_thresh = %s\n' "$low"
  printf 'net.ipv4.ipfrag_high_thresh = %s\n' "$high"
}

configure_sysctl() {
  step "sysctl tweaks"
  record_sysctl_values
  record_original /etc/sysctl.conf sysctl.conf
  record_original /etc/sysctl.d/99-sysctl.conf sysctl.d-99-sysctl.conf

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
  file_max=$(( ram_mb * 1024 ));        (( file_max < 1048576 )) && file_max=1048576;          (( file_max > 10485760 )) && file_max=10485760
  inotify_watches=$(( ram_mb * 4096 )); (( inotify_watches < 524288 )) && inotify_watches=524288; (( inotify_watches > 2097152 )) && inotify_watches=2097152
  conntrack_max=$(( ram_mb * 16 ));     (( conntrack_max < 65536 )) && conntrack_max=65536;    (( conntrack_max > 4194304 )) && conntrack_max=4194304
  if host_is_vps; then
    # Provider conntrack/hypervisor limits make larger tables unreachable;
    # they only pin guest kernel memory.
    conntrack_max=$(( ram_mb * 8 ));    (( conntrack_max < 32768 )) && conntrack_max=32768;    (( conntrack_max > 1048576 )) && conntrack_max=1048576
    (( netdev_backlog > 16384 )) && netdev_backlog=16384
  fi
  # Writeback thresholds in bytes.  The stock 30%/5% ratios let a 64 GB host
  # accumulate ~19 GB of dirty pages and then stall every writer (Angie
  # cache, Elasticsearch segments, logs) on the flush; rotational disks get
  # tighter caps.
  local disk_class dirty_bg_mb dirty_mb rmem_max
  disk_class=$(storage_class)
  dirty_bg_mb=$(( ram_mb / 100 ));      (( dirty_bg_mb < 64 )) && dirty_bg_mb=64;              (( dirty_bg_mb > 512 )) && dirty_bg_mb=512
  [[ $disk_class == hdd ]] && (( dirty_bg_mb > 256 )) && dirty_bg_mb=256
  dirty_mb=$(( dirty_bg_mb * 4 ));      (( dirty_mb < 256 )) && dirty_mb=256;                  (( dirty_mb > 2048 )) && dirty_mb=2048
  [[ $disk_class == hdd ]] && (( dirty_mb > 1024 )) && dirty_mb=1024
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
  # outbound connection can never take 3306/6379/9200 before a restart binds.
  local reserved_ports
  reserved_ports=$(printf '%s\n' 3306 6379 9200 9300 "$(sshd_listen_ports)" \
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
  ipfrag_high=$(( ram_mb * 32 ));       (( ipfrag_high < 262144 )) && ipfrag_high=262144;      (( ipfrag_high > 4194304 )) && ipfrag_high=4194304
  ipfrag_low=$(( ipfrag_high * 3 / 4 ))
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
# Keep low <= high.  A lower high mark is rejected while the old low mark is
# still above it, so write the low mark first and the high mark second.
$(ipfrag_sysctl_lines "$ipfrag_high" "$ipfrag_low")
net.netfilter.nf_conntrack_max = ${conntrack_max}
# Byte thresholds override the percentage knobs from the base profile.
vm.dirty_background_bytes = $(( dirty_bg_mb * 1048576 ))
vm.dirty_bytes = $(( dirty_mb * 1048576 ))
fs.file-max = ${file_max}
fs.nr_open = ${file_max}
fs.inotify.max_user_watches = ${inotify_watches}
vm.min_free_kbytes = ${min_free}
vm.swappiness = ${swappiness}
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
# CVE-2019-11479: cap the TCP challenge-ACK rate.  The upstream profile left
# the legacy maximum (1073741823), which is the vulnerable setting.
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
  # Make room before the file is applied; the file itself writes low first.
  if [[ -r /proc/sys/net/ipv4/ipfrag_low_thresh && -r /proc/sys/net/ipv4/ipfrag_high_thresh ]]; then
    local cur_low cur_high
    cur_low=$(< /proc/sys/net/ipv4/ipfrag_low_thresh)
    cur_high=$(< /proc/sys/net/ipv4/ipfrag_high_thresh)
    if [[ $cur_low =~ ^[0-9]+$ ]] && (( cur_low > ipfrag_high )); then
      sysctl -w "net.ipv4.ipfrag_low_thresh=${ipfrag_low}" >/dev/null 2>&1 || true
    elif [[ $cur_high =~ ^[0-9]+$ ]] && (( cur_high < ipfrag_low )); then
      sysctl -w "net.ipv4.ipfrag_high_thresh=${ipfrag_high}" >/dev/null 2>&1 || true
    fi
  fi

  # Record the base template's own keys too (first run only), so --purge can
  # put every live value back, not just the hardware block.
  local -a profile_keys=()
  mapfile -t profile_keys < <(sysctl_file_keys /etc/sysctl.conf)
  record_sysctl_values "${profile_keys[@]}"
  sysctl -e -p /etc/sysctl.conf || warn "One or more sysctl values could not be applied"

  # The congestion-control module and qdisc are module-owned and
  # systemd-sysctl runs before modules-load on Ubuntu, which logs "No such
  # file or directory" on every boot. Apply them from a small oneshot unit
  # after the modules are available instead.
  record_original /etc/systemd/system/setup-network-tuning.service setup-network-tuning.service
  {
    cat <<'EOF'
[Unit]
Description=Apply network qdisc/congestion-control tuning after kernel modules load
After=systemd-modules-load.service
[Service]
Type=oneshot
EOF
    for mod in "${net_mods[@]}"; do
      printf 'ExecStart=/sbin/modprobe %s\n' "$mod"
    done
    printf 'ExecStart=/sbin/sysctl -w net.core.default_qdisc=%s net.ipv4.tcp_congestion_control=%s\n' \
      "$QDISC" "$TCP_CC"
    cat <<'EOF'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  } > /etc/systemd/system/setup-network-tuning.service
  chmod 644 /etc/systemd/system/setup-network-tuning.service
  systemctl daemon-reload || true
  systemctl enable setup-network-tuning.service >/dev/null 2>&1 || true
  # restart (not start): the oneshot stays "active" from a previous run, and a
  # start would not re-apply a changed qdisc/congestion-control value.
  systemctl restart setup-network-tuning.service \
    || warn "Could not apply ${TCP_CC}/${QDISC} tuning"
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
  local class unit=/etc/systemd/system/setup-io-tuning.service
  local rule=/etc/udev/rules.d/60-setup-io.rules
  class=$(storage_class)
  record_original "$unit" setup-io-tuning.service
  record_original "$rule" udev-60-setup-io.rules
  cat > "$unit" <<'EOF'
[Unit]
Description=Apply transparent-hugepage tuning (setup.sh)
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in enabled defrag; do p=/sys/kernel/mm/transparent_hugepage/$f; [ -w "$p" ] && echo madvise > "$p"; done; exit 0'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit"
  cat > "$rule" <<'EOF'
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
# Rotational disks (including cloud HDD volumes): larger readahead for
# sequential scans.
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL!="nvme*", KERNEL!="dm-*", KERNEL!="md*", KERNEL!="loop*", KERNEL!="zram*", KERNEL!="ram*", KERNEL!="sr*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{bdi/read_ahead_kb}="1024"
EOF
  chmod 644 "$rule"
  systemctl daemon-reload || true
  systemctl enable setup-io-tuning.service >/dev/null 2>&1 || true
  systemctl restart setup-io-tuning.service 2>/dev/null || warn "Could not apply the THP setting"
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
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
angie         soft nofile 1048576
angie         hard nofile 1048576
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
  while IFS= read -r ssh_port; do
    [[ $ssh_port =~ ^[0-9]+$ ]] || continue
    ssh_limited=0
    had_allow=0
    if ufw show added 2>/dev/null | grep -qE "^ufw allow ${ssh_port}/tcp($| )|^ufw allow ${ssh_port}($| )"; then
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
  ufw allow 80 || true
  ufw allow 443 || true
  ufw --force enable
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
  update_system

  # Let the tuner decide from the actual cpufreq interface.  --optimize calls
  # the same function, so a host with a usable performance governor gets it
  # from either command.
  configure_cpu_governor

  # dmidecode (installed here) gives the nominal installed RAM for the
  # generated hostname, even when the kernel reserves some of it.
  install_basic_tools

  if [[ -z $host ]]; then
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

