# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).
# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# --optimize touches only service configuration, so it is safe on every LTS
# that still supports the installed packages.  Ubuntu 22.04 shares the same
# Angie/PHP/MariaDB/Valkey service layout and is supported until 2027.
optimize_os_supported() {
  case "${1%%.*}" in
    22|24|26) return 0 ;;
    *) return 1 ;;
  esac
}

validate_timezone() {
  local tz=$1
  [[ $tz =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -e "/usr/share/zoneinfo/${tz}" ]]
}

validate_hostname() {
  local h=$1
  (( ${#h} >= 1 && ${#h} <= 253 )) || return 1
  [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  for o in $ip; do
    [[ -n $o ]] || return 1
    if (( 10#$o > 255 )); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# MariaDB bind-address helpers
# ---------------------------------------------------------------------------
detect_local_ipv4() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }}' || true)
    if [[ -z $ip ]]; then
      ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]; exit}' || true)
    fi
  fi
  if [[ -z $ip ]]; then
    ip=$(hostname -I 2>/dev/null \
      | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  fi
  if [[ -n $ip ]] && validate_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

detect_public_ipv4() {
  command -v curl >/dev/null 2>&1 || return 1
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --connect-timeout 2 --max-time 4 "$url" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if validate_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

is_local_ipv4() {
  local ip=$1
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null \
      | awk -v ip="$ip" '{split($4, a, "/"); if (a[1] == ip) found = 1} END {exit !found}'
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF -- "$ip"
  fi
}

# Effective sshd TCP ports, one per line.  `sshd -T` respects Include files,
# drop-ins and package defaults; the sshd_config scan is a fallback for a
# non-root caller.  Always returns at least port 22.
sshd_listen_ports() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    # sshd -T fails as a normal user on some hosts; `|| true` keeps pipefail
    # from aborting the function before the port-22 fallback.
    ports=$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" {print $2}' || true)
  fi
  if [[ -z $ports && -r /etc/ssh/sshd_config ]]; then
    ports=$(awk 'tolower($1) == "port" {print $2}' /etc/ssh/sshd_config || true)
  fi
  # An empty sshd output is normal in a container/CI runner: grep exits 1.
  # Without `|| true`, pipefail + set -e would abort the process substitution
  # before the port-22 fallback and the caller would see no ports at all.
  ports=$(printf '%s\n' "$ports" | grep -E '^[0-9]+$' | sort -nu || true)
  [[ -n $ports ]] || ports=22
  printf '%s\n' "$ports"
}

# Resolve the IPV4 keyword to a usable local address.  Sets REPLY.
resolve_ipv4_token() {
  local public localip
  if [[ -n ${RESOLVED_IPV4_TOKEN:-} ]]; then
    REPLY=$RESOLVED_IPV4_TOKEN
    return 0
  fi

  public=$(detect_public_ipv4 || true)
  if [[ -n $public ]]; then
    if is_local_ipv4 "$public"; then
      REPLY=$public
      RESOLVED_IPV4_TOKEN=$public
      return 0
    fi
    warn "Public IPv4 ${public} is not assigned to this host (NAT/proxy?)"
    localip=$(detect_local_ipv4 || true)
    if [[ -n $localip ]]; then
      warn "bind=IPV4 will use the local outbound IPv4 ${localip}"
      REPLY=$localip
      RESOLVED_IPV4_TOKEN=$localip
      return 0
    fi
    return 1
  fi

  localip=$(detect_local_ipv4 || true)
  if [[ -n $localip ]]; then
    warn "Could not detect the public IPv4; bind=IPV4 will use local IPv4 ${localip}"
    REPLY=$localip
    RESOLVED_IPV4_TOKEN=$localip
    return 0
  fi
  return 1
}

# Validate and normalise a comma-separated bind list.  IPV4 is kept as a token
# here and resolved later, after --basic has installed curl.  Sets REPLY.
normalize_mariadb_bind() {
  local raw token normalized="" seen=" "
  local -a tokens
  BIND_BAD_TOKEN=""
  raw=$(printf '%s' "$1" | tr -d '[:space:]')
  [[ -n $raw ]] || { BIND_BAD_TOKEN="empty address"; return 1; }

  IFS=',' read -r -a tokens <<< "$raw"
  for token in "${tokens[@]}"; do
    [[ -n $token ]] || continue
    if [[ ${token^^} == IPV4 ]]; then
      token=IPV4
    elif [[ $token == "::1" ]]; then
      :
    elif ! validate_ipv4 "$token"; then
      BIND_BAD_TOKEN=$token
      return 1
    fi
    [[ $seen == *" ${token} "* ]] && continue
    seen+="${token} "
    normalized+="${normalized:+,}${token}"
  done

  [[ -n $normalized ]] || { BIND_BAD_TOKEN="empty address"; return 1; }
  REPLY=$normalized
  return 0
}

# Replace every IPV4 token with the detected address.  Sets REPLY.
resolve_mariadb_bind() {
  local token normalized="" seen=" "
  local -a tokens
  BIND_BAD_TOKEN=""
  IFS=',' read -r -a tokens <<< "$1"
  for token in "${tokens[@]}"; do
    if [[ ${token^^} == IPV4 ]]; then
      if ! resolve_ipv4_token; then
        BIND_BAD_TOKEN="could not detect an IPv4 address for IPV4"
        return 1
      fi
      token=$REPLY
    fi
    [[ $seen == *" ${token} "* ]] && continue
    seen+="${token} "
    normalized+="${normalized:+,}${token}"
  done
  [[ -n $normalized ]] || { BIND_BAD_TOKEN="empty address"; return 1; }
  REPLY=$normalized
  return 0
}

validate_domain() {
  local d=${1,,}
  d=${d%.}
  (( ${#d} >= 3 && ${#d} <= 253 )) || return 1
  [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

normalize_app() {
  local a=${1,,}
  case "$a" in
    ""|basic|blank|none|plain|static) printf 'basic' ;;
    xf|xenforo)          printf 'xf' ;;
    wp|wordpress)        printf 'wordpress' ;;
    flarum)              printf 'flarum' ;;
    pingvin)             printf 'pingvin' ;;
    chev|chevereto)      printf 'chevereto' ;;
    polr)                printf 'polr' ;;
    lychee)              printf 'lychee' ;;
    shlink)              printf 'shlink' ;;
    sfs)                 printf 'sfs' ;;
    node|nodejs)         printf 'node' ;;
    php|generic)         printf 'php' ;;
    *) return 1 ;;
  esac
}

detect_server_type() {
  # Prefer systemd's virtualization probe: exit 0 means a VM/container.
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --quiet; then
      printf 'vps'
    else
      printf 'dedi'
    fi
    return 0
  fi

  local dmi=""
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    dmi=$(< /sys/class/dmi/id/product_name)
    case "${dmi,,}" in
      *kvm*|*vmware*|*virtualbox*|*qemu*|*xen*|*hyper-v*|*amazon*|*google*|*digitalocean*|*openstack*|*bochs*|*parallels*)
        printf 'vps'; return 0 ;;
    esac
  fi
  if grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
    printf 'vps'; return 0
  fi
  printf 'dedi'
}

detect_ram_gb() {
  local total_kb=0
  if command -v dmidecode >/dev/null 2>&1; then
    total_kb=$(dmidecode -t memory 2>/dev/null | awk '
      /^[[:space:]]*Size:/ && $2 ~ /^[0-9]+$/ {
        if ($3 == "GB") sum += $2 * 1024 * 1024;
        else if ($3 == "MB") sum += $2 * 1024;
        else if ($3 == "TB") sum += $2 * 1024 * 1024 * 1024;
      }
      END { print sum + 0 }')
  fi
  if (( total_kb <= 0 )); then
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  fi
  awk -v kb="$total_kb" 'BEGIN { printf "%.0f", kb / 1024 / 1024 }'
}

# CPUs available to this host, honouring a cgroup quota.  nproc reports the
# host's logical CPUs inside a container or a vCPU-capped cloud guest, which
# would otherwise size 144 PHP workers and 16 Angie/MariaDB threads for a
# 2-vCPU quota.
# CPUs granted by a cgroup CPU quota: ceil(quota / period), 0 when there is no
# numeric quota ("max").  A fractional quota (cpu.max "50000 100000") rounds
# up to one CPU; truncating it to 0 would discard the limit and fall back to
# the host core count.
cgroup_quota_cpus() {
  local quota=${1:-} period=${2:-}
  if [[ $quota =~ ^[0-9]+$ && $period =~ ^[0-9]+$ ]] && (( period > 0 )); then
    printf '%s' $(( (quota + period - 1) / period ))
  else
    printf 0
  fi
}

effective_cpus() {
  local n quota period cpus=0
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || true
    cpus=$(cgroup_quota_cpus "$quota" "$period")
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us \
          && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    quota=$(< /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(< /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    cpus=$(cgroup_quota_cpus "$quota" "$period")
  fi
  n=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) || n=1
  if (( cpus >= 1 && cpus < n )); then
    n=$cpus
  fi
  printf '%s' "$n"
}

detect_storage() {
  local total=0
  total=$(lsblk -b -d -n -o SIZE,TYPE 2>/dev/null | awk '$2=="disk"{sum+=$1} END{print sum+0}')
  if (( total <= 0 )); then
    total=$(df -B1 --output=size / 2>/dev/null | awk 'NR==2{print $1}')
  fi
  if (( total >= 1000000000000 )); then
    printf '%dT' $(( total / 1000000000000 ))
  elif (( total >= 1000000000 )); then
    printf '%dG' $(( total / 1000000000 ))
  else
    printf '%dM' $(( total / 1000000 ))
  fi
}

generate_hostname() {
  printf '%sc-%sg-%s' "$(nproc)" "$(detect_ram_gb)" "$(detect_storage)"
}

is_nvme_storage() {
  local dev
  for dev in /sys/block/nvme*; do
    [[ -e $dev ]] || continue
    return 0
  done
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o TRAN 2>/dev/null | grep -qx nvme && return 0
  fi
  return 1
}

# Storage class shared by the MariaDB I/O-capacity and Angie cache tuners so
# install and --optimize classify the same disk the same way.
#
# Classify the device that actually backs the data path, not merely any block
# device on the host.  A SATA boot disk plus an NVMe scratch disk used to be
# classified as "nvme" (and a cloud volume as "hdd"); following the mount's
# parent devices fixes both cases.
storage_backing_class() {
  local target=${1:-/var/www} src dev name rota tran class=hdd
  command -v findmnt >/dev/null 2>&1 || return 1
  src=$(findmnt -n -o SOURCE -T "$target" 2>/dev/null | head -n1)
  [[ -n $src ]] || src=$(findmnt -n -o SOURCE -T / 2>/dev/null | head -n1)
  [[ -n $src ]] || return 1
  dev=${src%%[*}
  [[ -e $dev ]] || return 1
  local -a names=()
  # lsblk -s prints a tree ("└─nvme0n1"); strip the prefix before matching.
  mapfile -t names < <(lsblk -s -n -o NAME,TYPE "$dev" 2>/dev/null \
    | awk '{ gsub(/^[^A-Za-z0-9]+/, "", $1); if ($2 == "disk") print $1 }')
  (( ${#names[@]} > 0 )) || return 1
  for name in "${names[@]}"; do
    case "$(classify_block_device "$name")" in
      nvme) printf 'nvme'; return 0 ;;
      ssd) class=ssd ;;
    esac
  done
  printf '%s' "$class"
}

# One disk's class (nvme/ssd/hdd) from its name: NVMe by name, flash by the
# rotational flag, and paravirtual (virtio/Xen) volumes count as flash since
# the hypervisor hides the medium.  Shared by the data-path and the
# whole-host classification so both paths agree on every device.
classify_block_device() {
  local name=$1 rota tran
  case "$name" in nvme*) printf 'nvme'; return 0 ;; esac
  rota=$(cat "/sys/block/${name}/queue/rotational" 2>/dev/null || echo 1)
  tran=$(lsblk -d -n -o TRAN "/dev/${name}" 2>/dev/null | tr -d '[:space:]')
  if [[ $rota == 0 || $tran == virtio || $tran == pv ]]; then
    printf 'ssd'
  else
    printf 'hdd'
  fi
}

storage_class() {
  local backing name type class best=hdd
  backing=$(storage_backing_class /var/www 2>/dev/null || true)
  [[ -n $backing ]] && { printf '%s' "$backing"; return 0; }

  # No mount information: take the best class among the host's whole disks.
  if is_nvme_storage; then
    printf 'nvme'
    return 0
  fi
  if command -v lsblk >/dev/null 2>&1; then
    while read -r name type; do
      [[ $type == disk && -n $name ]] || continue
      class=$(classify_block_device "$name")
      case $class in
        nvme) best=nvme; break ;;
        ssd) best=ssd ;;
      esac
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null)
  fi
  printf '%s' "$best"
}

latest_sury_php() {
  local pkg ver cand upstream best=""
  while read -r pkg; do
    ver=${pkg#php}
    ver=${ver%-fpm}
    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/^[[:space:]]*Candidate:/{print $2}')
    cand=${cand%%$'\n'*}
    [[ -n $cand && $cand != "(none)" ]] || continue
    upstream=${cand#*:}
    upstream=${upstream%%-*}
    # Ignore alpha/beta/RC/dev packages: their upstream version has a suffix.
    [[ $upstream =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z $best ]] || [[ $(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -n1) == "$ver" ]]; then
      best=$ver
    fi
  done < <(apt-cache pkgnames 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-fpm$' | sort -u)
  printf '%s' "$best"
}

validate_all() {
  local svc

  # --upgrade-php is a standalone mode like --optimize: it works on an
  # installed host, needs the Sury repository and must not be mixed with
  # install/purge/diagnostics flags that would change the same packages.
  if [[ -n ${UPGRADE_PHP:-} ]]; then
    [[ $UPGRADE_PHP =~ ^[0-9]+\.[0-9]+$ ]] \
      || die "--upgrade-php='${UPGRADE_PHP}' is invalid (use e.g. --upgrade-php=8.6)"
    local major=${UPGRADE_PHP%%.*} minor=${UPGRADE_PHP#*.}
    (( major == 8 && minor >= 1 )) \
      || die "--upgrade-php supports PHP 8.1 and newer (found ${UPGRADE_PHP})"
    (( OPTIMIZE )) && die "--upgrade-php cannot be combined with --optimize (the upgrade runs the PHP tuner itself)"
    (( PURGE )) && die "--upgrade-php cannot be combined with --purge"
    (( DIAGNOSTICS )) && die "--upgrade-php cannot be combined with --diagnostics"
    (( RESTART_ALL )) && die "--upgrade-php cannot be combined with --restart-all"
    [[ ${#DOMAINS[@]} -eq 0 ]] \
      || die "--upgrade-php cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] \
      || die "--upgrade-php is standalone and cannot be combined with install flags"
    # The pool template is version-specific.  A dry run on a machine without
    # the repository still prints the plan; the real run must fail before it
    # purges PHP if a template is missing.
    if (( ! DRY_RUN )) && [[ ! -f "${SCRIPT_DIR}/configs/php/www_${UPGRADE_PHP//./}.conf" ]]; then
      die "No FPM pool template for PHP ${UPGRADE_PHP} (${SCRIPT_DIR}/configs/php/www_${UPGRADE_PHP//./}.conf); add one before upgrading"
    fi
    return 0
  fi

  if (( OPTIMIZE )); then
    (( DIAGNOSTICS )) && die "--optimize cannot be combined with --diagnostics"
    (( RESTART_ALL )) && die "--optimize cannot be combined with --restart-all"
    (( PURGE )) && die "--optimize cannot be combined with --purge"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--optimize cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--optimize scans installed services and cannot be combined with install flags"
    return 0
  fi

  if (( DIAGNOSTICS )); then
    (( PURGE )) && die "--diagnostics cannot be combined with --purge"
    (( RESTART_ALL )) && die "--diagnostics cannot be combined with --restart-all"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--diagnostics cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--diagnostics only reads the host and cannot be combined with install flags"
    return 0
  fi

  if (( RESTART_ALL )); then
    (( PURGE )) && die "--restart-all cannot be combined with --purge"
    (( OPTIMIZE )) && die "--restart-all cannot be combined with --optimize"
    (( DIAGNOSTICS )) && die "--restart-all cannot be combined with --diagnostics"
    [[ ${#DOMAINS[@]} -eq 0 ]] || die "--restart-all cannot be combined with --domain"
    [[ ${#ENABLED[@]} -eq 0 ]] || die "--restart-all only restarts installed services and cannot be combined with install flags"
    return 0
  fi

  for svc in "${!ENABLED[@]}"; do
    case "$svc" in
      basic|angie|php|mariadb|valkey|elastic|others|domain) ;;
      *) die "Internal error: bad service '${svc}'" ;;
    esac
  done

  if [[ ${PURGE} -eq 1 ]]; then
    if [[ ${#DOMAINS[@]} -gt 0 ]]; then
      die "--domain cannot be combined with --purge (remove domain files/database manually)"
    fi
    local t
    for t in "${PURGE_TARGETS[@]}"; do
      case "$t" in
        all|basic|angie|php|mariadb|valkey|elastic|others) ;;
        *) die "--purge: unknown target '${t}'" ;;
      esac
    done
    if [[ ${#PURGE_TARGETS[@]} -eq 0 ]] && [[ ${#ENABLED[@]} -eq 0 ]]; then
      PURGE_TARGETS=(all)
    fi
    if [[ -n ${OPT[php.ver]:-} ]]; then
      [[ ${OPT[php.ver]} =~ ^[0-9]+\.[0-9]+$ ]] \
        || die "--purge --php ver='${OPT[php.ver]}' is invalid (use e.g. 8.5)"
    fi
    return 0
  fi

  if [[ ${ENABLED[basic]:-0} -ne 1 ]]; then
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
      die "--basic is required (see --help)"
    fi
    local s other=0
    for s in angie php mariadb valkey elastic others; do
      [[ ${ENABLED[$s]:-0} -eq 1 ]] && other=1
    done
    (( other == 0 )) || die "--basic is required when installing services other than --domain"
  fi

  if [[ -n ${OPT[basic.server]:-} ]]; then
    [[ ${OPT[basic.server]} == dedi || ${OPT[basic.server]} == vps ]] \
      || die "--basic server= must be 'dedi' or 'vps'"
  fi
  if [[ -n ${OPT[basic.host]:-} ]]; then
    validate_hostname "${OPT[basic.host]}" \
      || die "--basic host='${OPT[basic.host]}' is not a valid hostname"
  fi
  if [[ -n ${OPT[basic.swap]:-} ]]; then
    local swap=${OPT[basic.swap]^^}
    # The value was upper-cased above, so the optional binary suffix is "I".
    [[ $swap =~ ^[1-9][0-9]*([KMGTP]I?)?$ ]] \
      || die "--basic swap='${OPT[basic.swap]}' is invalid (use e.g. 8G)"
    OPT[basic.swap]=$swap
  fi
  local tz=${OPT[basic.time]:-Asia/Manila}
  validate_timezone "$tz" || die "--basic time='${tz}' is not a valid timezone"
  OPT[basic.time]=$tz

  if [[ ${#DOMAINS[@]} -gt 0 ]]; then
    local d db app seen=" "
    local -a dedup=()
    for d in "${DOMAINS[@]}"; do
      d=${d,,}
      d=${d%.}
      validate_domain "$d" || die "--domain '${d}' is not a valid domain name"
      app=${DOMAIN_APP[$d]:-basic}
      app=$(normalize_app "$app") \
        || die "--domain '${d}': unknown app='${app}' (use basic, xf, wordpress, flarum, pingvin, chevereto, polr, lychee, shlink, sfs, php or node)"
      DOMAIN_APP[$d]=$app
      db=${DOMAIN_DB[$d]:-}
      if [[ -n $db ]]; then
        [[ $db =~ ^[A-Za-z0-9_]{1,64}$ ]] \
          || die "--domain '${d}': db='${db}' is invalid (letters, digits and underscore, at most 64 characters)"
      fi
      if [[ -n ${DOMAIN_DB_USER[$d]:-} || -n ${DOMAIN_DB_PASS[$d]:-} ]]; then
        [[ -n $db ]] || die "--domain '${d}': user=/pass= require db="
        [[ -n ${DOMAIN_DB_USER[$d]:-} && -n ${DOMAIN_DB_PASS[$d]:-} ]] \
          || die "--domain '${d}': user= and pass= must be given together"
        [[ ${DOMAIN_DB_USER[$d]} =~ ^[A-Za-z0-9_]{1,80}$ ]] \
          || die "--domain '${d}': user= may only contain letters, digits and underscore"
        [[ ${DOMAIN_DB_PASS[$d]} != *$'\n'* ]] || die "--domain '${d}': pass= must not contain a newline"
      fi
      if [[ -n ${DOMAIN_SQL[$d]:-} ]]; then
        [[ -n $db ]] || die "--domain '${d}': sql= requires db="
        [[ -f ${DOMAIN_SQL[$d]} && -r ${DOMAIN_SQL[$d]} ]] \
          || die "--domain '${d}': sql='${DOMAIN_SQL[$d]}' is not a readable file"
      fi
      [[ $seen == *" $d "* ]] && continue
      seen+="${d} "
      dedup+=("$d")
    done
    DOMAINS=("${dedup[@]}")
  fi

  if [[ ${ENABLED[php]:-0} -eq 1 ]]; then
    if [[ -n ${OPT[php.ver]:-} ]]; then
      [[ ${OPT[php.ver]} =~ ^[0-9]+\.[0-9]+$ ]] \
        || die "--php ver='${OPT[php.ver]}' is invalid (use e.g. 8.5)"
    fi
    if [[ -n ${OPT[php.children]:-} ]]; then
      [[ ${OPT[php.children]} == auto || ${OPT[php.children]} =~ ^[1-9][0-9]*$ ]] \
        || die "--php children='${OPT[php.children]}' is invalid (use auto or a positive integer)"
    fi
    if [[ -n ${OPT[php.max_requests]:-} ]]; then
      [[ ${OPT[php.max_requests]} =~ ^[1-9][0-9]*$ ]] \
        || die "--php max_requests='${OPT[php.max_requests]}' is invalid (use a positive integer)"
    fi
  fi

  if [[ ${ENABLED[mariadb]:-0} -eq 1 ]]; then
    [[ -n ${OPT[mariadb.user]:-} ]] || die "--mariadb user= is required"
    [[ -n ${OPT[mariadb.pass]:-} ]] || die "--mariadb pass= is required"
    # size= defaults to auto: the shared memory planner sizes the buffer pool
    # from the live data, exactly as --optimize does.
    [[ -n ${OPT[mariadb.size]:-} ]] || OPT[mariadb.size]=auto
    [[ ${OPT[mariadb.user]} =~ ^[A-Za-z0-9_]+$ ]] \
      || die "--mariadb user= may only contain letters, digits and underscore"
    [[ ${OPT[mariadb.pass]} != *$'\n'* ]] || die "--mariadb pass= must not contain a newline"
    [[ ${OPT[mariadb.size]} == auto || ${OPT[mariadb.size]} =~ ^[1-9][0-9]*([mM][bB]?|[gG][bB]?)$ ]] \
      || die "--mariadb size='${OPT[mariadb.size]}' is invalid (use auto, 4gb, 512m, ...)"
    # The planner never sizes a pool below 128 MB; an explicit value under
    # that would be written by the installer and then raised by the first
    # --optimize (a restart for nothing).  Clamp it here so both paths agree.
    if [[ ${OPT[mariadb.size]} != auto ]] && (( $(size_to_mb "${OPT[mariadb.size]}") < 128 )); then
      warn "--mariadb size=${OPT[mariadb.size]} is below the 128 MB planner floor; using 128m"
      OPT[mariadb.size]=128m
    fi
    local bind=${OPT[mariadb.bind]:-127.0.0.1}
    if ! normalize_mariadb_bind "$bind"; then
      die "--mariadb bind='${bind}' contains an invalid address '${BIND_BAD_TOKEN}'. Use comma-separated IPv4 addresses, ::1, and/or IPV4."
    fi
    OPT[mariadb.bind]=$REPLY
  fi

  if [[ ${ENABLED[valkey]:-0} -eq 1 ]]; then
    if [[ -n ${OPT[valkey.ram]:-} ]]; then
      [[ ${OPT[valkey.ram],,} == auto || ${OPT[valkey.ram]} =~ ^[1-9][0-9]*[gGmM]$ ]] \
        || die "--valkey ram='${OPT[valkey.ram]}' is invalid (use auto, 2g, 512m, ...)"
      OPT[valkey.ram]=${OPT[valkey.ram],,}
      if [[ ${OPT[valkey.ram]} != auto ]] && (( $(size_to_mb "${OPT[valkey.ram]}") < 128 )); then
        warn "--valkey ram=${OPT[valkey.ram]} is below the 128 MB planner floor; using 128m"
        OPT[valkey.ram]=128m
      fi
    fi
    local vpol=${OPT[valkey.policy]:-allkeys-lru}
    case "$vpol" in
      allkeys-lru|allkeys-lfu|volatile-lru|volatile-lfu|volatile-ttl|allkeys-random|volatile-random|noeviction) ;;
      *) die "--valkey policy='${vpol}' is invalid" ;;
    esac
    OPT[valkey.policy]=$vpol
    local vio=${OPT[valkey.io_threads]:-1}
    [[ $vio =~ ^[1-9][0-9]*$ ]] && (( vio <= 64 )) \
      || die "--valkey io_threads='${vio}' is invalid (use 1..64)"
    if (( vio > 8 )); then
      # valkey_clamp_io_threads writes at most 8 (more threads than that
      # only add contention on the single command thread); say so instead
      # of silently writing a different value than the one requested.
      warn "--valkey io_threads=${vio} exceeds the 8-thread ceiling; using 8"
      vio=8
    fi
    OPT[valkey.io_threads]=$vio
  fi

  if [[ ${ENABLED[elastic]:-0} -eq 1 ]]; then
    local eram=${OPT[elastic.ram]:-auto}
    [[ ${eram,,} == auto || ${eram} =~ ^[1-9][0-9]*[gGmM]$ ]] \
      || die "--elastic ram='${eram}' is invalid (use auto, 4g, 512m, ...)"
    OPT[elastic.ram]=${eram,,}
    local ehost=${OPT[elastic.host]:-localhost}
    [[ $ehost =~ ^[A-Za-z0-9._:-]+$ ]] \
      || die "--elastic host='${ehost}' is invalid"
    if [[ $ehost =~ ^[0-9.]+$ ]]; then
      validate_ipv4 "$ehost" || die "--elastic host='${ehost}' is not a valid IPv4 address"
    fi
    OPT[elastic.host]=$ehost
  fi

  if [[ ${ENABLED[others]:-0} -eq 1 ]]; then
    [[ ${#OTHERS[@]} -gt 0 ]] || die "--others requires at least one of: smartmon nvme gif nodejs sysstat"
    local item expanded=()
    for item in "${OTHERS[@]}"; do
      case "$item" in
        all) expanded+=(smartmon nvme gif nodejs sysstat) ;;
        smartmon|nvme|gif|nodejs|sysstat) expanded+=("$item") ;;
        *) die "--others: unknown package '${item}'" ;;
      esac
    done
    # de-duplicate while keeping order
    local seen=" "
    OTHERS=()
    for item in "${expanded[@]}"; do
      [[ $seen == *" ${item} "* ]] && continue
      seen+="${item} "
      OTHERS+=("$item")
    done
  fi
}

