# shellcheck shell=bash
# Shared by tools/nginx-build.sh, tools/php-build.sh and tools/valkey-build.sh
# (1.22.0: every one of the three is built from source): messages, the
# apt.llvm.org/GitHub LLVM toolchain, upstream version lookups, downloads
# with a second source for every file plus the project's own mirror
# (setup-build-sources), checksums and signatures, unpacking, the static
# sd_notify shim, the CPU fingerprint of -march=native builds, the one build
# lock (/run/setup-build.lock), memory-aware job counts, build log retention
# and the serial CPU-change / refresh chain of setup-build-cpu.service and
# setup-build-refresh.service.
# The sourcing tool defines LOG_TAG, SRC_CACHE, CONF, COMPONENTS and VERS.
# Run directly (`bash build-common.sh chain cpu|refresh`) it is the chain
# driver those two units start.
#
# JSON (php.net releases, GitHub's API, GNOME's cache) is parsed with perl's
# core JSON::PP, never with `php`: a fresh host has no PHP before the first
# PHP build, and nginx is built before PHP.

# apt.llvm.org signing key (Sylvestre Ledru, LLVM's APT archive).
LLVM_KEY_FPR=6084F3CF814B57C1CF12EFD515CF4D18AF4F7421
# SETUP_BUILD_LLVM_* (1.22); the PHP_BUILD_LLVM_* names of 1.21 still work.
LLVM_KEYRING=${SETUP_BUILD_LLVM_KEYRING:-${PHP_BUILD_LLVM_KEYRING:-/etc/apt/keyrings/setup-llvm.asc}}
LLVM_SOURCES=${SETUP_BUILD_LLVM_SOURCES:-${PHP_BUILD_LLVM_SOURCES:-/etc/apt/sources.list.d/setup-llvm.sources}}
LLVM_PIN=${SETUP_BUILD_LLVM_PIN:-${PHP_BUILD_LLVM_PIN:-/etc/apt/preferences.d/setup-llvm.pref}}
# LLVM from its GitHub release tarball when apt.llvm.org is unreachable.
LLVM_OPT=${SETUP_BUILD_LLVM_OPT:-${PHP_BUILD_LLVM_OPT:-/opt/setup-llvm}}
# Upstream lookups are cached this long (seconds): GitHub, PECL, php.net.
RESOLVE_TTL=${SETUP_BUILD_RESOLVE_TTL:-${PHP_BUILD_RESOLVE_TTL:-3600}}
# nginx.org's release-signing keys (https://nginx.org/en/pgp_keys.html), as
# NAME:FINGERPRINT.  NAME is the key file under https://nginx.org/keys/; the
# key material is fetched (and cached under SRC_CACHE/keys for offline CPU
# rebuilds) but only a signature whose PRIMARY key fingerprint is listed here
# is accepted, so a swapped key file cannot sign anything.  Kept here, not in
# the writable nginx-build.conf the refresh timer reads.  Checked 2026-11:
# nginx 1.31.x tarballs are signed by D6786CE3... (Sergey Kandaurov).
NGINX_PGP_KEYS="pluknet:D6786CE303D9A9022998DC6CC8464D549AF75C0A
arut:43387825DDB1BB97EC36BA5D007C8D7C15D87369
thresh:13C82A63B603576156E30A4EA0EA981B66B0D967
sai:AC50DD4E7CD5D51FD00D1F4C4DB15B66AA75322B
sb:7338973069ED3F443F4D37DFA64FD5B17ADB39A8"
# The one lock every build, activation and chain run takes (R2.4).
BUILD_LOCK=${SETUP_BUILD_LOCK:-/run/setup-build.lock}
# Builds refuse to start below these free-space floors (MB): the build cache
# filesystem (LLVM, sources, work trees) and /.
BUILD_MIN_CACHE_MB=${SETUP_BUILD_MIN_CACHE_MB:-6144}
BUILD_MIN_ROOT_MB=${SETUP_BUILD_MIN_ROOT_MB:-2048}
# 1 = CPU-change rebuild: no network unless a pinned file is missing, cached
# archives whose hash is on record are used as they are.
BUILD_OFFLINE=${SETUP_BUILD_OFFLINE:-0}
# GMP comes from GNU: the main site first, then GNU's mirror redirector and
# gmplib.org (ftp.gnu.org timed out for minutes during the 1.21.68 tests).
# The first download's SHA-256 is pinned (tofu_check), whichever mirror served it.
GMP_MIRRORS="https://ftp.gnu.org/gnu/gmp https://ftpmirror.gnu.org/gmp https://gmplib.org/download/gmp"
# GNU libiconv: the same two GNU hosts.
GNU_MIRRORS="https://ftp.gnu.org/gnu https://ftpmirror.gnu.org"
# Algorithms and protocols none of the three applications (or curl for
# them) uses: legacy ciphers, national ciphers, binary curves, SRP, DTLS.
# shellcheck disable=SC2034 # used by the sourcing tools
OPENSSL_TRIM="no-idea no-camellia no-seed no-aria no-sm2 no-sm3 no-sm4 no-whirlpool no-md4 no-rc2 no-rc4 no-mdc2 no-cast no-bf no-gost no-srp no-dtls no-ssl3 no-ec2m no-comp"

# Messages go to stderr: functions whose stdout is captured (a downloaded
# file's path) also report progress.
say() { printf '%s\n' "$*" >&2; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
die() { say "ERROR: $*" >&2; exit 1; }

ver_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$2" ]]; } # $1 >= $2
conf_key() { local k=${1^^}; printf '%s_VERSION' "${k//-/_}"; }

# The binary php-fpm runs: no symbols or BOLT relocations (php-fpm.lto keeps
# them for the next BOLT run; perf2bolt matches the samples by build ID,
# which stripping keeps).  Falls back to a plain copy without llvm-strip.
install_stripped() { # src dst
  local s
  # No glob may fail the assignment (set -e + pipefail): ls exits 2 when one
  # of the patterns matches nothing, and that ended the whole build once.
  s=$( { ls /usr/lib/llvm-*/bin/llvm-strip "$LLVM_OPT"/*/bin/llvm-strip 2>/dev/null || true; } | sort -V | tail -n 1)
  if [[ -n $s ]] && "$s" --strip-all -o "$2" "$1" 2>/dev/null; then chmod 755 "$2"; else install -m 755 "$1" "$2"; fi
}

# --------------------------------------------------------------- CPU
# The CPU a -march=native build is tied to (1.22, replaces cpu_model, which
# compared only "vendor model name": on KVM guests that string often stays
# the same while the host exposes another flag set, and aarch64 has no
# "model name" line, so the gate was silently skipped).
#
# The fingerprint covers vendor, family, model, stepping and model name plus
# the ISA extensions clang's -march=native can use, from a FIXED allow-list.
# Kernel, microcode and mitigation flags (md_clear, flush_l1d, ibrs, ssbd,
# arch_capabilities, hypervisor, constant_tsc, ...) never count: a routine
# kernel-update reboot must not look like a CPU change, because a change
# keeps every compiled service down until the native rebuild finished.
# Linux spells three of the extensions differently (pni = SSE3, abm = LZCNT,
# rdrand); they are mapped to the allow-list names.  aarch64: implementer,
# architecture, variant, part, revision and the Features line.
CPU_ISA_FLAGS="sse3 ssse3 sse4_1 sse4_2 popcnt avx avx2 fma f16c bmi1 bmi2 lzcnt movbe adx aes pclmulqdq vaes vpclmulqdq sha_ni rdrnd rdseed xsave xsavec xsaveopt xsaves avx512f avx512dq avx512cd avx512bw avx512vl avx512_vnni avx512_bf16 avx512vbmi avx512_vbmi2 avx512ifma avx512_bitalg avx512_vpopcntdq gfni avx_vnni amx_tile amx_bf16 amx_int8 clflushopt clwb"

# The plain text the fingerprint hashes (diagnostics and build.info cpu_info=).
cpu_fingerprint_text() {
  local info=${SETUP_CPUINFO:-/proc/cpuinfo}
  [[ -r $info ]] || return 0
  awk -F'[[:space:]]*:[[:space:]]*' -v allow="$CPU_ISA_FLAGS" '
    BEGIN { n = split(allow, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1
            alias["pni"] = "sse3"; alias["abm"] = "lzcnt"; alias["rdrand"] = "rdrnd" }
    # The first processor block only: every core of one host is the same CPU.
    /^[[:space:]]*$/ { if (seen) exit; next }
    { seen = 1 }
    $1 == "vendor_id" || $1 == "cpu family" || $1 == "model" || $1 == "stepping" || $1 == "model name" \
      || $1 == "CPU implementer" || $1 == "CPU architecture" || $1 == "CPU variant" || $1 == "CPU part" || $1 == "CPU revision" {
      id = id $1 "=" $2 ";" }
    $1 == "flags" || $1 == "Features" {
      m = split($2, f, " ")
      for (i = 1; i <= m; i++) {
        x = (f[i] in alias) ? alias[f[i]] : f[i]
        # x86: only allow-listed ISA flags; aarch64 Features are all ISA.
        if ($1 == "Features" || (x in ok)) isa[x] = 1
      } }
    END {
      s = ""; c = 0
      for (x in isa) list[++c] = x
      # Sorted, so the text does not depend on the order /proc lists them.
      for (i = 2; i <= c; i++) { v = list[i]; j = i - 1; while (j > 0 && list[j] > v) { list[j + 1] = list[j]; j-- } list[j + 1] = v }
      for (i = 1; i <= c; i++) s = s (i > 1 ? "," : "") list[i]
      printf "%sisa=%s\n", id, s }' "$info"
}

# Prints the hash stored as cpu= in every build.info.  Empty /proc/cpuinfo
# gives an empty string, which every gate treats as a mismatch (rebuild),
# never as "skip the check".
cpu_fingerprint() {
  local t
  t=$(cpu_fingerprint_text)
  [[ -n $t ]] || return 0
  printf '%s' "$t" | sha256sum | cut -c1-16
}

# --------------------------------------------------------------- build limits
# CPUs this host may use: the cgroup v2/v1 quota when set, else nproc (which
# honours the affinity mask; OMP_* must not shrink it).
build_cpus() {
  local n quota period q=0
  n=$(unset OMP_NUM_THREADS OMP_THREAD_LIMIT; nproc 2>/dev/null || echo 1)
  [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) || n=1
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || true
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    quota=$(< /sys/fs/cgroup/cpu/cpu.cfs_quota_us); period=$(< /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  fi
  if [[ ${quota:-} =~ ^[0-9]+$ && ${period:-} =~ ^[0-9]+$ ]] && (( period > 0 && quota > 0 )); then
    q=$(( (quota + period - 1) / period ))
  fi
  (( q > 0 && q < n )) && n=$q
  printf '%s' "$n"
}

# Parallel compile/link jobs: min(CPUs, (MemAvailable - 1 GB) / 1.2 GB), at
# least 1 (R2.4).  A clang -O3 ThinLTO backend job peaks near 1 GB (PHP's
# largest units); with -j$(nproc) a 4 GB, 4 vCPU host running MariaDB went
# into the OOM killer, which picks mysqld, not the build.  SETUP_BUILD_JOBS
# overrides.
build_jobs() {
  local n mem j
  if [[ ${SETUP_BUILD_JOBS:-} =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$SETUP_BUILD_JOBS"; return 0; fi
  n=$(build_cpus)
  mem=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${SETUP_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  [[ $mem =~ ^[0-9]+$ ]] || mem=0
  j=$(( (mem - 1024) / 1200 ))
  (( j < 1 )) && j=1
  (( j > n )) && j=$n
  printf '%s' "$j"
}

# lld's ThinLTO backend starts one thread per CPU whatever make -j says, so
# the link is capped to the same job count (R66).
build_thinlto_flag() { # [jobs]
  printf -- '-Wl,--thinlto-jobs=%s' "${1:-$(build_jobs)}"
}

# Keep the newest 5 DIR/PREFIX*.log files (R79: logs live outside the work
# directory, which is deleted on exit, so a failed build's log stays).
build_log_keep() { # dir prefix
  local d=$1 p=$2 f n=0
  [[ -d $d ]] || return 0
  while IFS= read -r f; do
    n=$(( n + 1 ))
    (( n > 5 )) && rm -f -- "$f"
  done < <(find "$d" -maxdepth 1 -type f -name "${p}*.log" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  return 0
}

# Free MB on the filesystem holding PATH (its nearest existing parent).
free_mb() {
  local p=$1
  while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
  df -Pm "$p" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Refuse to start a build that could fill the disk MariaDB writes to.
build_space_check() { # cache-dir
  local c r
  c=$(free_mb "$1"); r=$(free_mb /)
  [[ $c =~ ^[0-9]+$ && $r =~ ^[0-9]+$ ]] || return 0
  (( c >= BUILD_MIN_CACHE_MB )) || die "only ${c} MB free on the build cache filesystem ($1); a build needs ${BUILD_MIN_CACHE_MB} MB (LLVM, sources, work tree); free space and retry"
  (( r >= BUILD_MIN_ROOT_MB )) || die "only ${r} MB free on /; a build needs ${BUILD_MIN_ROOT_MB} MB; free space and retry"
}

# Run CMD (a command or shell function) holding /run/setup-build.lock,
# waiting for it (install, --optimize, --upgrade-php, migration, the CPU
# chain).  Re-entrant: a process that already holds the lock (exported
# SETUP_BUILD_LOCK_HELD=1, for example the migration controller or the CPU
# chain calling a tool) runs CMD directly instead of deadlocking on itself.
# The lock fd is inherited by CMD's children.  SETUP_BUILD_LOCK_TIMEOUT
# (seconds, default 6 h) bounds the wait.
build_lock_run() {
  if [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]]; then "$@"; return; fi
  (
    exec 9>>"$BUILD_LOCK" || die "cannot open $BUILD_LOCK"
    if ! flock -n 9; then
      say "waiting for another build to finish ($BUILD_LOCK)"
      flock -w "${SETUP_BUILD_LOCK_TIMEOUT:-21600}" 9 || die "timed out waiting for $BUILD_LOCK"
    fi
    export SETUP_BUILD_LOCK_HELD=1
    "$@"
  )
}

# The refresh timer and BOLT: never wait.  Status 75 when the lock is held
# (the caller reports "skipped: build lock held" and exits 0).
build_lock_try() {
  if [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]]; then "$@"; return; fi
  (
    exec 9>>"$BUILD_LOCK" || exit 75
    flock -n 9 || exit 75
    export SETUP_BUILD_LOCK_HELD=1
    "$@"
  )
}

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

ensure_packages() {
  local -a missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
  done
  (( ${#missing[@]} )) || return 0
  # A CI runner (NGINX_BUILD_CI=1) builds as an ordinary user with sudo; on
  # a host every tool runs as root (need_root).
  local -a asroot=()
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "installing ${missing[*]} needs root (or sudo)"
    asroot=(sudo -n)
  fi
  say "installing: ${missing[*]}"
  ${asroot[@]+"${asroot[@]}"} apt-get -o DPkg::Lock::Timeout=900 update -qq
  ${asroot[@]+"${asroot[@]}"} apt-get -o DPkg::Lock::Timeout=900 install -y --no-install-recommends "${missing[@]}" >/dev/null
}

# ---------------------------------------------------------------- versions
# php-build.conf value for a component: "latest" or a version.
conf_get() {
  local key v=""
  key=$(conf_key "$1")
  if [[ -f $CONF ]]; then
    v=$(awk -F= -v k="$key" '
      { sub(/\r$/, "") }
      $1 == k { v = substr($0, length(k) + 2); sub(/[[:space:]]*#.*$/, "", v); gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v); last = v }
      END { print last }' "$CONF")
  fi
  v=${v:-latest}
  [[ $v == latest || $v =~ ^[0-9][0-9A-Za-z._+-]*$ || $v =~ ^[0-9a-f]{7,40}$ ]] || die "$key='$v' in $CONF is neither latest nor a version"
  printf '%s' "$v"
}

# Quiet, retried, bounded.  Two retries and a 15 s connect timeout: a dead
# host costs under a minute before the next source is tried.  A stalled
# transfer (under 1 KB/s for 30 s) counts as failed too: zlib.net once
# stopped after 200 KB and --max-time alone would have waited 30 minutes.
http_get() { # url [out]
  if [[ -n ${2:-} ]]; then
    curl -fsSL --retry 2 --retry-delay 3 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --max-time 1800 -o "$2" "$1"
  else
    curl -fsSL --retry 2 --retry-delay 3 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --max-time 120 "$1"
  fi
}

# Evaluate perl CODE with $d = the decoded JSON text and @ARGV = the rest.
# perl and its core JSON::PP are on every Ubuntu host the builds run on
# (ensure_packages installs perl for every build); invalid JSON or a missing
# perl prints nothing, like an unreachable source.
json_eval() { # code json [args...]
  local code=$1 json=$2; shift 2
  perl -MJSON::PP -e 'my $t = shift; my $d = eval { JSON::PP->new->allow_nonref->decode($t) }; exit 0 unless defined $d; '"$code" \
    "$json" "$@" 2>/dev/null || true
}

# Highest tag of a GitHub repository matching ERE (group 1 is the version),
# through git's ref listing (not the rate-limited API).
git_latest() {
  git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
    | awk '{ sub("refs/tags/", "", $2); print $2 }' \
    | sed -nE "s/$2/\\1/p" | sort -V | tail -n 1
}

codename() { (. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}"); }

llvm_suite_ok() { # major: apt.llvm.org carries it for this Ubuntu release
  local c
  c=$(codename)
  [[ -n $c ]] && curl -fsI --connect-timeout 15 --max-time 45 -o /dev/null \
    "https://apt.llvm.org/$c/dists/llvm-toolchain-$c-$1/Release"
}

# The newest stable upstream version of a component.  Each lookup has a
# second source where the project offers one.
latest_of() {
  local name=$1 x=${2:-} v="" n json
  case $name in
    php)
      if json=$(http_get "https://www.php.net/releases/?json&version=$x"); then
        v=$(json_eval 'print $d->{version} // "" if ref $d eq "HASH";' "$json")
      fi
      [[ $v == "$x".* ]] || v=$(git_latest php/php-src "^php-(${x//./\\.}\\.[0-9]+)\$") ;;
    llvm)
      n=$(git_latest llvm/llvm-project '^llvmorg-([0-9]+)\.[0-9]+\.[0-9]+$')
      [[ $n =~ ^[0-9]+$ ]] || return 1
      # apt.llvm.org can trail a fresh release by a few days; when it is
      # unreachable altogether the GitHub release tarball of N serves.
      if llvm_suite_ok "$n"; then v=$n
      elif llvm_suite_ok "$(( n - 1 ))"; then v=$(( n - 1 ))
      else v=$n
      fi ;;
    redis|igbinary)
      v=$(http_get "https://pecl.php.net/rest/r/$name/allreleases.xml" 2>/dev/null \
        | grep -oE '<r><v>[0-9]+\.[0-9]+\.[0-9]+</v><s>stable</s>' \
        | sed -E 's#<r><v>([^<]+)</v>.*#\1#' | sort -V | tail -n 1)
      if [[ -z $v ]]; then
        case $name in
          redis)    v=$(git_latest phpredis/phpredis '^([0-9]+\.[0-9]+\.[0-9]+)$') ;;
          igbinary) v=$(git_latest igbinary/igbinary '^([0-9]+\.[0-9]+\.[0-9]+)$') ;;
        esac
      fi ;;
    openssl)  v=$(git_latest openssl/openssl '^openssl-([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    pcre2)    v=$(git_latest PCRE2Project/pcre2 '^pcre2-([0-9]+\.[0-9]+)$') ;;
    zlib)     v=$(git_latest madler/zlib '^v([0-9]+\.[0-9]+(\.[0-9]+)*)$') ;;
    curl)     v=$(git_latest curl/curl '^curl-([0-9]+_[0-9]+_[0-9]+)$'); v=${v//_/.} ;;
    # libjpeg-turbo numbers betas x.y.9z.
    libjpeg-turbo)
      v=$(git ls-remote --tags --refs https://github.com/libjpeg-turbo/libjpeg-turbo.git 2>/dev/null \
        | awk '{ sub("refs/tags/", "", $2); print $2 }' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]$|^[0-9]+\.[0-9]+\.[0-8][0-9]$' | sort -V | tail -n 1) ;;
    libpng)   v=$(git_latest pnggroup/libpng '^v([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    libwebp)  v=$(git_latest webmproject/libwebp '^v([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    libzip)   v=$(git_latest nih-at/libzip '^v([0-9]+\.[0-9]+(\.[0-9]+)?)$') ;;
    libsodium) v=$(git_latest jedisct1/libsodium '^([0-9]+\.[0-9]+\.[0-9]+)-RELEASE$') ;;
    libxml2)
      if json=$(http_get https://download.gnome.org/sources/libxml2/cache.json); then
        v=$(json_eval 'my $h = ref $d eq "ARRAY" && ref $d->[1] eq "HASH" ? $d->[1]{libxml2} : undef;
          my @v = grep { /^\d+\.\d+\.\d+$/ } (ref $h eq "HASH" ? keys %$h : ());
          @v = sort { my @x = split /\./, $a; my @y = split /\./, $b; $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] } @v;
          print $v[-1] if @v;' "$json")
      fi
      [[ -n $v ]] || v=$(git_latest GNOME/libxml2 '^v([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    gmp)
      local m listing=""
      for m in $GMP_MIRRORS; do listing=$(http_get "$m/") && break; done
      v=$(printf '%s' "$listing" | grep -oE 'gmp-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' \
        | sed -E 's/^gmp-|\.tar\.xz$//g' | sort -V | tail -n 1) ;;
    libiconv)
      local listing="" m
      for m in $GNU_MIRRORS; do listing=$(http_get "$m/libiconv/") && break; done
      v=$(printf '%s' "$listing" | grep -oE "libiconv-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz" \
        | sed -E "s/^libiconv-|\.tar\.gz\$//g" | sort -V | tail -n 1) ;;
    zlib-ng)  v=$(git_latest zlib-ng/zlib-ng '^([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    # nginx: the highest version nginx.org publishes, which is the mainline
    # branch (odd minor; the stable branch is always numbered lower).  Then
    # the release-X.Y.Z tags of nginx/nginx on GitHub.
    nginx)
      v=$(http_get https://nginx.org/download/ 2>/dev/null | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^nginx-|\.tar\.gz$//g' | sort -V | tail -n 1)
      [[ -n $v ]] || v=$(git_latest nginx/nginx '^release-([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    brotli)   v=$(git_latest google/brotli "^v([0-9]+\.[0-9]+\.[0-9]+)\$") ;;
    # ngx_brotli publishes no releases: its newest commit on the default branch.
    ngx-brotli) v=$(git ls-remote https://github.com/google/ngx_brotli.git HEAD 2>/dev/null | cut -c1-12) ;;
    # Valkey: the newest release, or the newest of series X.Y when one is
    # given (a host that persists data stays on the package's series).
    valkey)
      if [[ -n $x ]]; then v=$(git_latest valkey-io/valkey "^(${x//./\\.}\\.[0-9]+)\$")
      else v=$(git_latest valkey-io/valkey '^([0-9]+\.[0-9]+\.[0-9]+)$')
      fi ;;
    *) return 1 ;;
  esac
  [[ -n $v ]] && printf '%s' "$v"
}

# The version the ACTIVE build recorded for NAME: ROOT/build.info (Valkey),
# ROOT/build/build.info (nginx; also Valkey's 1.21 layout) or
# ROOT/X.Y/build.info (any PHP version).  Never a staged or previous build
# (staging/, prev/): neither serves, and keeping its version when a lookup
# fails would downgrade the next build and flip back on the next failure.
last_known() {
  local f v=""
  for f in "$ROOT/build.info" "$ROOT"/*/build.info; do
    [[ -f $f ]] || continue
    case ${f%/build.info} in */staging|*/prev) continue ;; esac
    v=$(awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$f")
    [[ -n $v ]] && break
  done
  printf '%s' "$v"
}

# The version php-build.conf asks for (pin or cached "latest").  When no
# source answers, the version the current build was made from is kept.
resolve() { # name [php X.Y]
  local name=$1 x=${2:-} want cache v
  want=$(conf_get "$name")
  if [[ $want != latest ]]; then
    printf '%s' "$want"; return 0
  fi
  cache=$SRC_CACHE/resolve/$name${x:+-$x}
  if [[ -s $cache ]] && (( $(date +%s) - $(stat -c %Y "$cache") < RESOLVE_TTL )); then
    cat "$cache"; return 0
  fi
  v=$(latest_of "$name" "$x") || v=""
  if [[ -z $v ]]; then
    v=$(last_known "$name")
    [[ -n $v ]] || return 1
    say "$name: no source answered; keeping $v"
    printf '%s' "$v"; return 0
  fi
  mkdir -p "$SRC_CACHE/resolve"
  printf '%s' "$v" > "$cache"
  printf '%s' "$v"
}

# Every component as "name=version" lines; status 1 when one cannot be
# resolved (offline, upstream down, no earlier build).
resolve_all() { # X.Y
  local c v rc=0
  for c in "${COMPONENTS[@]}"; do
    if v=$(resolve "$c" "$1"); then printf '%s=%s\n' "$c" "$v"
    else printf '%s=?\n' "$c"; rc=1
    fi
  done
  return "$rc"
}

# ---------------------------------------------------------------- sources
# Every download has at least two sources: the project's own site first,
# GitHub (or a second official mirror) next.  Where both serve the same
# tarball, one published SHA-256 checks either.  A different archive (a Git
# tag snapshot) is pinned on first use like any file without a published
# checksum: the same file name must always hash the same.
tofu_check() { # file
  local f=$1 sum db
  db=$SRC_CACHE/sums; mkdir -p "$db"
  sum=$(sha256sum "$f" | awk '{print $1}')
  if [[ -s $db/${f##*/} ]]; then
    [[ $(cat "$db/${f##*/}") == "$sum" ]] || { rm -f "$f"; die "${f##*/} changed upstream since it was first fetched"; }
  else
    printf '%s' "$sum" > "$db/${f##*/}"
  fi
}

# URLS is one URL or several mirrors of the same file, tried in order.
fetch_to() { # urls file [sha256]: download unless the cached copy verifies
  local urls=$1 out=$2 want=${3:-} url ok=0
  if [[ -s $out && -n $want && $(sha256sum "$out" | awk '{print $1}') == "$want" ]]; then return 0; fi
  if [[ ! -s $out || -n $want ]]; then
    for url in $urls; do
      if http_get "$url" "$out.part"; then ok=1; break; fi
      say "download failed: $url"
    done
    (( ok )) || { rm -f "$out.part"; die "download failed from every source: ${out##*/}"; }
    mv -f "$out.part" "$out"
  fi
  if [[ -n $want ]]; then
    [[ $(sha256sum "$out" | awk '{print $1}') == "$want" ]] || { rm -f "$out"; die "${out##*/}: SHA-256 mismatch"; }
    # On record too, so a CPU-change rebuild (offline) can reuse the file.
    mkdir -p "$SRC_CACHE/sums"; printf '%s' "$want" > "$SRC_CACHE/sums/${out##*/}"
  else
    tofu_check "$out"
  fi
}

# BUILD_OFFLINE=1: a cached archive whose SHA-256 is on record (verified when
# it was first fetched) is used without any network lookup.
cached_ok() { # file
  local f=$1 db=$SRC_CACHE/sums/${1##*/}
  [[ -s $f && -s $db && $(sha256sum "$f" | awk '{print $1}') == "$(cat "$db")" ]]
}

# Try each "urls|file|sha256" source in order (sha256 may be empty); print
# the file of the first that downloads and verifies.
# Last resort: the project's own copy of every source archive (1.21.71),
# github.com/droplinxuser/setup-build-sources, one release per component
# (tag = component name, assets = the archives under their usual names, plus
# a SHA256SUMS the mirror's workflow wrote after checking each download
# against the upstream's published SHA-256 or its first-seen hash).  A file
# from the mirror must match, in order: the SHA-256 the caller expects (the
# upstream's published one), the hash pinned on this host's first download,
# or the mirror's SHA256SUMS; without any of the three it is refused.
# SETUP_BUILD_MIRROR=off disables it; another URL points at a fork.
BUILD_MIRROR=${SETUP_BUILD_MIRROR:-https://github.com/droplinxuser/setup-build-sources/releases/download}
FETCH_NAME=""

fetch_mirror() { # file [sha256]
  local file=$1 want=${2:-} base sums
  [[ -n $BUILD_MIRROR && $BUILD_MIRROR != off && -n $FETCH_NAME ]] || return 1
  base=${file##*/}
  if [[ -z $want && ! -s $SRC_CACHE/sums/$base ]]; then
    sums=$(http_get "$BUILD_MIRROR/$FETCH_NAME/SHA256SUMS" 2>/dev/null) || return 1
    want=$(awk -v f="$base" '$2 == f || $2 == "*" f { print $1; exit }' <<<"$sums" | grep -E '^[0-9a-f]{64}$') || return 1
  fi
  say "trying the project's mirror for $base"
  ( fetch_to "$BUILD_MIRROR/$FETCH_NAME/$base" "$file" "$want" )
}

fetch_first() {
  local s urls file sum
  if [[ $BUILD_OFFLINE == 1 ]]; then
    for s in "$@"; do
      IFS='|' read -r urls file sum <<<"$s"
      if cached_ok "$file" && [[ -z $sum || $(cat "$SRC_CACHE/sums/${file##*/}") == "$sum" ]]; then printf '%s' "$file"; return 0; fi
    done
    say "offline rebuild: ${file##*/} is not cached; fetching the pinned version"
  fi
  for s in "$@"; do
    IFS='|' read -r urls file sum <<<"$s"
    if ( fetch_to "$urls" "$file" "$sum" ); then printf '%s' "$file"; return 0; fi
    say "source failed: ${urls%% *}"
  done
  for s in "$@"; do
    IFS='|' read -r urls file sum <<<"$s"
    if fetch_mirror "$file" "$sum"; then printf '%s' "$file"; return 0; fi
  done
  die "every source failed for ${file##*/}"
}

# The SHA-256 GitHub publishes for a release asset (empty when the API is
# unreachable or the asset has no digest).
gh_digest() { # repo tag asset
  local json
  local -a auth=()
  [[ $BUILD_OFFLINE == 1 ]] && return 0
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  json=$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "${auth[@]}" \
    "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null) || return 0
  json_eval 'for my $x (ref $d eq "HASH" && ref $d->{assets} eq "ARRAY" ? @{$d->{assets}} : ()) {
      if (($x->{name} // "") eq $ARGV[0]) { my $s = $x->{digest} // ""; $s =~ s/^sha256://; print $s; last } }' "$json" "$3" \
    | grep -E '^[0-9a-f]{64}$' || true
}

# A release tarball served by the project's site and by its GitHub release:
# the same file, checked against GitHub's digest (or SITE_SHA when given).
site_or_github() { # site-urls repo tag asset [site-sha]
  local sum
  sum=${5:-$(gh_digest "$2" "$3" "$4")}
  fetch_first "$1 https://github.com/$2/releases/download/$3/$4|$SRC_CACHE/src/$4|$sum"
}

# 0 when ASC is a good signature of FILE by one of the pinned nginx.org keys
# (NGINX_PGP_KEYS).  gpgv (Ubuntu's required package; no agent, no keybox
# daemon, nothing written to /root/.gnupg) checks it against keyrings made in
# a throwaway directory; the key files are dearmored with perl so gpg itself
# is not needed.  The PRIMARY key fingerprint gpgv reports must be pinned.
nginx_pgp_verify() { # file asc
  local f=$1 asc=$2 home kdir name fpr status prim
  local -a rings=()
  command -v gpgv >/dev/null 2>&1 || ensure_packages gpgv
  home=$(mktemp -d)
  kdir=$SRC_CACHE/keys; mkdir -p "$kdir"
  while IFS=: read -r name fpr; do
    [[ -n $name ]] || continue
    if [[ ! -s $kdir/$name.key ]]; then
      if ! http_get "https://nginx.org/keys/$name.key" "$kdir/$name.key.part" 2>/dev/null; then rm -f "$kdir/$name.key.part"; continue; fi
      mv -f "$kdir/$name.key.part" "$kdir/$name.key"
    fi
    perl -MMIME::Base64 -e 'local $/; my $t = <STDIN>; $t =~ s/\r//g;
      my ($b) = $t =~ /-----BEGIN PGP PUBLIC KEY BLOCK-----\n(.*?)-----END PGP PUBLIC KEY BLOCK-----/s or exit 1;
      my ($h, @d) = (1);
      for (split /\n/, $b) { if ($h) { next if /^[A-Za-z][A-Za-z-]*: /; $h = 0; next if /^\s*$/ } last if /^=/; push @d, $_ }
      binmode STDOUT; print decode_base64(join "", @d);' < "$kdir/$name.key" > "$home/$name.gpg" 2>/dev/null \
      && [[ -s $home/$name.gpg ]] && rings+=(--keyring "$home/$name.gpg")
  done <<< "$NGINX_PGP_KEYS"
  if (( ${#rings[@]} == 0 )); then
    rm -rf "${home:?}"; say "none of the pinned nginx.org signing keys could be loaded (offline?)"; return 1
  fi
  status=$(GNUPGHOME=$home gpgv --status-fd 1 "${rings[@]}" "$asc" "$f" 2>/dev/null) || { rm -rf "${home:?}"; return 1; }
  rm -rf "${home:?}"
  prim=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print ($12 != "" ? $12 : $3); exit }' <<<"$status")
  [[ $prim =~ ^[0-9A-Fa-f]{40}$ ]] && grep -qi ":${prim}\$" <<<"$NGINX_PGP_KEYS"
}

# The nginx tarball, accepted only with a good nginx.org signature (R36/R95):
# nginx.org first, then the same tarball and .asc from the nginx/nginx GitHub
# release, then the project's mirror, every copy checked the same way.  No
# codeload tag snapshot (it has no signature) and no first-use trust: when
# nothing verifies, the build stops and the running nginx keeps serving.  A
# cached tarball is re-verified from its cached .asc (offline CPU rebuilds).
fetch_nginx_signed() { # version
  local v=$1 c=$SRC_CACHE/src f src
  local -a srcs=("https://nginx.org/download" "https://github.com/nginx/nginx/releases/download/release-$v")
  [[ -n $BUILD_MIRROR && $BUILD_MIRROR != off ]] && srcs+=("$BUILD_MIRROR/nginx")
  f=$c/nginx-$v.tar.gz
  mkdir -p "$c"
  if [[ -s $f && -s $f.asc ]]; then
    if nginx_pgp_verify "$f" "$f.asc"; then printf '%s' "$f"; return 0; fi
    say "cached nginx-$v.tar.gz does not verify; fetching it again"
    rm -f "$f" "$f.asc"
  fi
  for src in "${srcs[@]}"; do
    rm -f "$f.part" "$f.asc.part"
    if http_get "$src/nginx-$v.tar.gz" "$f.part" && http_get "$src/nginx-$v.tar.gz.asc" "$f.asc.part"; then
      if nginx_pgp_verify "$f.part" "$f.asc.part"; then
        mv -f "$f.part" "$f"; mv -f "$f.asc.part" "$f.asc"
        mkdir -p "$SRC_CACHE/sums"; sha256sum "$f" | awk '{ printf "%s", $1 }' > "$SRC_CACHE/sums/${f##*/}"
        printf '%s' "$f"; return 0
      fi
      say "nginx-$v.tar.gz from ${src%/*}: no valid signature by a pinned nginx.org key; refused"
    else
      say "download failed: $src/nginx-$v.tar.gz(.asc)"
    fi
  done
  rm -f "$f.part" "$f.asc.part"
  die "nginx-$v.tar.gz: no source served it with a valid nginx.org PGP signature (fail closed)"
}

fetch_component() { # name version -> path of the source archive
  local v=$2 c=$SRC_CACHE/src sum m urls=""
  FETCH_NAME=$1
  case $1 in
    php)
      # php.net (its SHA-256), then the php-src tag snapshot (pinned).
      local json=""
      if [[ $BUILD_OFFLINE == 1 ]]; then
        # CPU rebuild: whichever archive was verified and cached before.
        fetch_first "https://www.php.net/distributions/php-$v.tar.xz|$c/php-$v.tar.xz|" \
          "https://github.com/php/php-src/archive/refs/tags/php-$v.tar.gz|$c/php-src-php-$v.tar.gz|"
        return
      fi
      json=$(http_get "https://www.php.net/releases/?json&version=$v" 2>/dev/null || true)
      sum=$(json_eval 'for my $s (ref $d eq "HASH" && ref $d->{source} eq "ARRAY" ? @{$d->{source}} : ()) {
          print $s->{sha256} // "" if ($s->{filename} // "") eq "php-$ARGV[0].tar.xz" }' "${json:-null}" "$v" 2>/dev/null \
        | grep -E '^[0-9a-f]{64}$' || true)
      if [[ -n $sum ]]; then
        fetch_first "https://www.php.net/distributions/php-$v.tar.xz|$c/php-$v.tar.xz|$sum" \
          "https://github.com/php/php-src/archive/refs/tags/php-$v.tar.gz|$c/php-src-php-$v.tar.gz|"
      else
        say "php.net publishes no SHA-256 for php-$v (unreachable?); using the GitHub tag snapshot"
        fetch_first "https://github.com/php/php-src/archive/refs/tags/php-$v.tar.gz|$c/php-src-php-$v.tar.gz|"
      fi ;;
    redis)
      fetch_first "https://pecl.php.net/get/redis-$v.tgz|$c/redis-$v.tgz|" \
        "https://github.com/phpredis/phpredis/archive/refs/tags/$v.tar.gz|$c/phpredis-$v.tar.gz|" ;;
    igbinary)
      fetch_first "https://pecl.php.net/get/igbinary-$v.tgz|$c/igbinary-$v.tgz|" \
        "https://github.com/igbinary/igbinary/archive/refs/tags/$v.tar.gz|$c/igbinary-gh-$v.tar.gz|" ;;
    openssl)
      sum=$(gh_digest openssl/openssl "openssl-$v" "openssl-$v.tar.gz")
      [[ -n $sum || $BUILD_OFFLINE == 1 ]] || sum=$(http_get "https://www.openssl.org/source/openssl-$v.tar.gz.sha256" 2>/dev/null | grep -oE '^[0-9a-f]{64}' || true)
      site_or_github "https://www.openssl.org/source/openssl-$v.tar.gz" openssl/openssl "openssl-$v" "openssl-$v.tar.gz" "$sum" ;;
    zlib)
      site_or_github "https://zlib.net/zlib-$v.tar.xz https://zlib.net/fossils/zlib-$v.tar.xz" madler/zlib "v$v" "zlib-$v.tar.xz" ;;
    libsodium)
      site_or_github "https://download.libsodium.org/libsodium/releases/libsodium-$v.tar.gz" jedisct1/libsodium "$v-RELEASE" "libsodium-$v.tar.gz" ;;
    curl)
      site_or_github "https://curl.se/download/curl-$v.tar.xz" curl/curl "curl-${v//./_}" "curl-$v.tar.xz" ;;
    libzip)
      site_or_github "https://libzip.org/download/libzip-$v.tar.xz" nih-at/libzip "v$v" "libzip-$v.tar.xz" ;;
    pcre2)
      # Hosted on GitHub only: the release asset, then the tag snapshot.
      sum=$(gh_digest PCRE2Project/pcre2 "pcre2-$v" "pcre2-$v.tar.bz2")
      fetch_first "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$v/pcre2-$v.tar.bz2|$c/pcre2-$v.tar.bz2|$sum" \
        "https://codeload.github.com/PCRE2Project/pcre2/tar.gz/refs/tags/pcre2-$v|$c/pcre2-src-$v.tar.gz|" ;;
    libjpeg-turbo)
      sum=$(gh_digest libjpeg-turbo/libjpeg-turbo "$v" "libjpeg-turbo-$v.tar.gz")
      fetch_first "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$v/libjpeg-turbo-$v.tar.gz|$c/libjpeg-turbo-$v.tar.gz|$sum" \
        "https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/$v|$c/libjpeg-turbo-src-$v.tar.gz|" ;;
    libpng)
      fetch_first "https://download.sourceforge.net/libpng/libpng-$v.tar.xz|$c/libpng-$v.tar.xz|" \
        "https://github.com/pnggroup/libpng/archive/refs/tags/v$v.tar.gz|$c/libpng-src-$v.tar.gz|" ;;
    libwebp)
      fetch_first "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$v.tar.gz|$c/libwebp-$v.tar.gz|" \
        "https://github.com/webmproject/libwebp/archive/refs/tags/v$v.tar.gz|$c/libwebp-src-$v.tar.gz|" ;;
    libxml2)
      sum=$(http_get "https://download.gnome.org/sources/libxml2/${v%.*}/libxml2-$v.sha256sum" 2>/dev/null \
        | awk -v f="libxml2-$v.tar.xz" '$2 == f { print $1 }' | grep -E '^[0-9a-f]{64}$' || true)
      fetch_first "https://download.gnome.org/sources/libxml2/${v%.*}/libxml2-$v.tar.xz|$c/libxml2-$v.tar.xz|$sum" \
        "https://gitlab.gnome.org/GNOME/libxml2/-/archive/v$v/libxml2-v$v.tar.gz https://github.com/GNOME/libxml2/archive/refs/tags/v$v.tar.gz|$c/libxml2-src-$v.tar.gz|" ;;
    gmp)
      for m in $GMP_MIRRORS; do urls+="$m/gmp-$v.tar.xz "; done
      fetch_first "$urls|$c/gmp-$v.tar.xz|" ;;
    libiconv)
      for m in $GNU_MIRRORS; do urls+="$m/libiconv/libiconv-$v.tar.gz "; done
      fetch_first "$urls|$c/libiconv-$v.tar.gz|" ;;
    zlib-ng)
      fetch_first "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$v.tar.gz|$c/zlib-ng-$v.tar.gz|" \
        "https://codeload.github.com/zlib-ng/zlib-ng/tar.gz/refs/tags/$v|$c/zlib-ng-src-$v.tar.gz|" ;;
    nginx)
      # PGP-verified only (R36/R95): never a tag snapshot, never first use.
      fetch_nginx_signed "$v" ;;
    brotli)
      # GitHub is Brotli's only home: release archive, then codeload.
      fetch_first "https://github.com/google/brotli/archive/refs/tags/v$v.tar.gz|$c/brotli-$v.tar.gz|" \
        "https://codeload.github.com/google/brotli/tar.gz/refs/tags/v$v|$c/brotli-src-$v.tar.gz|" ;;
    ngx-brotli)
      fetch_first "https://github.com/google/ngx_brotli/archive/$v.tar.gz|$c/ngx_brotli-$v.tar.gz|" \
        "https://codeload.github.com/google/ngx_brotli/tar.gz/$v|$c/ngx_brotli-src-$v.tar.gz|" ;;
    valkey)
      # GitHub is Valkey's source home: the tag archive, then codeload.
      fetch_first "https://github.com/valkey-io/valkey/archive/refs/tags/$v.tar.gz|$c/valkey-$v.tar.gz|" \
        "https://codeload.github.com/valkey-io/valkey/tar.gz/refs/tags/$v|$c/valkey-src-$v.tar.gz|" ;;
    *) die "unknown component $1" ;;
  esac
}

unpack() { # archive dir
  [[ -s $1 ]] || die "no source archive to unpack into $2"
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components=1
}

# Download (or reuse) a component and unpack it; a failed download stops the
# build with its own message.
fetch_unpack() { # name version dir
  local arc
  arc=$(fetch_component "$1" "$2") || die "$1 $2: download failed"
  unpack "$arc" "$3"
}

# A Git tag snapshot has no generated configure script; make one.
autotools_prepare() {
  [[ -x ./configure ]] && return 0
  if [[ -x ./autogen.sh ]]; then NOCONFIGURE=1 ./autogen.sh
  elif [[ -x ./buildconf ]]; then ./buildconf
  else autoreconf -fi
  fi
}

# ---------------------------------------------------------------- LLVM
# clang/lld (and BOLT) of major N from apt.llvm.org, never Ubuntu's archive.
# The source is pinned at priority 100, so it never replaces an Ubuntu
# package; the toolchain is installed with -t from its own suite.  When
# apt.llvm.org is unreachable, LLVM's own release tarball from GitHub
# (checked against GitHub's digest) is unpacked into $LLVM_OPT/N.  Sets
# LLVM_BIN.
llvm_install() { # major packages...
  local n=$1 c; shift
  c=$(codename)
  [[ -n $c ]] || die "cannot read VERSION_CODENAME from /etc/os-release"
  if llvm_suite_ok "$n" && llvm_apt_install "$n" "$c" "$@"; then
    LLVM_BIN=/usr/lib/llvm-$n/bin
  else
    say "apt.llvm.org has no usable LLVM $n for Ubuntu $c; using LLVM's GitHub release"
    llvm_github_install "$n"
    LLVM_BIN=$LLVM_OPT/$n/bin
  fi
  [[ -x $LLVM_BIN/clang ]] || die "clang $n missing after install"
}

# CPU-change rebuild (offline, R13/R33): the LLVM major build.info recorded,
# straight from /usr/lib/llvm-N or $LLVM_OPT/N, with no apt.llvm.org probe,
# apt run or GitHub call.  Only when neither exists does it fall back to
# llvm_install (network).  Sets LLVM_BIN.
llvm_use_recorded() { # major [packages...]
  local n=$1
  if [[ -x /usr/lib/llvm-$n/bin/clang && -x /usr/lib/llvm-$n/bin/ld.lld ]]; then LLVM_BIN=/usr/lib/llvm-$n/bin; return 0; fi
  if [[ -x $LLVM_OPT/$n/bin/clang ]]; then LLVM_BIN=$LLVM_OPT/$n/bin; return 0; fi
  say "LLVM $n recorded in build.info is not installed; installing it (network)"
  llvm_install "$@"
}

# Lower this process tree's claim on the host before a build: nice 10, idle
# IO and OOM score 900, so under memory pressure the kernel kills the build,
# never mysqld, Elasticsearch, PHP-FPM or nginx (R66/R91).  Children inherit
# all three.  The build units set the same in their unit text.
build_deprioritize() {
  echo 900 > "/proc/$BASHPID/oom_score_adj" 2>/dev/null || true
  renice -n 10 -p "$BASHPID" >/dev/null 2>&1 || true
  ionice -c 3 -p "$BASHPID" >/dev/null 2>&1 || true
  # No single file a build writes may exceed 20 GB (SETUP_BUILD_MAX_FILE_GB):
  # a runaway write fails the build (SIGXFSZ) instead of filling the disk
  # under MariaDB (1.22.0 --upgrade-php test: a 1.7 TB log).  The largest
  # real build file, the LTO php-fpm, is about 60 MB.
  ulimit -f $(( ${SETUP_BUILD_MAX_FILE_GB:-20} * 1024 * 1024 )) 2>/dev/null || true
}

# The last N lines of a build log, on stderr, for the operator.  Never when
# stderr IS that log: setup.sh runs the tools with `>>"$log" 2>&1` and passes
# the same file, and `tail -n N log >&2` then reads what it appends to the
# file it reads and never reaches the end (1.22.0 --upgrade-php=8.6 test: a
# failed make grew the log to 1.7 TB in 15 minutes, filled the disk and took
# MariaDB down).  Bounded either way: at most N lines, read once.
log_excerpt() { # FILE [N]
  local f=$1 n=${2:-30} a b
  [[ -f $f ]] || return 0
  a=$(stat -L -c '%d:%i' -- "$f" 2>/dev/null) || return 0
  # The calling shell's fd 2, read through /proc: a plain /dev/stderr would be
  # stat's own stderr, which the 2>/dev/null has already replaced.
  b=$(stat -L -c '%d:%i' "/proc/$BASHPID/fd/2" 2>/dev/null || true)
  [[ -n $b && $a == "$b" ]] && return 0
  tail -n "$n" -- "$f" | head -n "$n" >&2 || true
}

llvm_apt_install() { # major codename packages...
  local n=$1 c=$2 key fpr src pin gnupg_home; shift 2
  ensure_packages ca-certificates curl gnupg
  # gpg reads the key in a throwaway home: --show-keys would otherwise create
  # /root/.gnupg on the server.
  gnupg_home=$(mktemp -d)
  if ! GNUPGHOME=$gnupg_home gpg --show-keys --with-colons "$LLVM_KEYRING" 2>/dev/null | grep -q "^fpr:::::::::$LLVM_KEY_FPR:"; then
    key=$(mktemp)
    if ! http_get https://apt.llvm.org/llvm-snapshot.gpg.key "$key"; then
      rm -f "$key"; rm -rf "${gnupg_home:?}"; return 1
    fi
    fpr=$(GNUPGHOME=$gnupg_home gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | sed -n 1p)
    if [[ $fpr != "$LLVM_KEY_FPR" ]]; then
      rm -f "$key"; rm -rf "${gnupg_home:?}"
      die "apt.llvm.org key fingerprint is $fpr, expected $LLVM_KEY_FPR"
    fi
    install -d -m 755 "$(dirname "$LLVM_KEYRING")"
    install -m 644 "$key" "$LLVM_KEYRING"; rm -f "$key"
  fi
  rm -rf "${gnupg_home:?}"
  src=$(printf '# Managed by setup.sh: LLVM %s for the compiled nginx, PHP and Valkey.\nTypes: deb\nURIs: https://apt.llvm.org/%s/\nSuites: llvm-toolchain-%s-%s\nComponents: main\nSigned-By: %s\n' \
    "$n" "$c" "$c" "$n" "$LLVM_KEYRING")
  pin=$(printf '# Managed by setup.sh: apt.llvm.org never replaces Ubuntu packages.\nPackage: *\nPin: origin apt.llvm.org\nPin-Priority: 100\n')
  [[ -f $LLVM_PIN && $(cat "$LLVM_PIN") == "$pin" ]] || { install -d "$(dirname "$LLVM_PIN")"; printf '%s\n' "$pin" > "$LLVM_PIN"; }
  if [[ ! -f $LLVM_SOURCES || $(cat "$LLVM_SOURCES") != "$src" ]]; then
    printf '%s\n' "$src" > "$LLVM_SOURCES"
    apt-get -o DPkg::Lock::Timeout=900 update -qq || return 1
  fi
  local -a missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    say "installing from apt.llvm.org: ${missing[*]}"
    apt-get -o DPkg::Lock::Timeout=900 install -y --no-install-recommends \
      -t "llvm-toolchain-$c-$n" "${missing[@]}" >/dev/null || return 1
  fi
  return 0
}

llvm_github_install() { # major
  local n=$1 full arch asset sum arc dest
  dest=${LLVM_OPT:?}/${n:?}
  [[ -x $dest/bin/clang ]] && return 0
  full=$(git_latest llvm/llvm-project "^llvmorg-(${n}\\.[0-9]+\\.[0-9]+)\$")
  [[ -n $full ]] || die "no LLVM $n release found on GitHub"
  arch=X64; [[ $(uname -m) == aarch64 ]] && arch=ARM64
  asset=LLVM-$full-Linux-$arch.tar.xz
  sum=$(gh_digest llvm/llvm-project "llvmorg-$full" "$asset")
  [[ -n $sum ]] || die "GitHub publishes no SHA-256 for $asset"
  mkdir -p "$SRC_CACHE/src"
  arc=$(fetch_first "https://github.com/llvm/llvm-project/releases/download/llvmorg-$full/$asset|$SRC_CACHE/src/$asset|$sum")
  rm -rf "${dest:?}.new"; mkdir -p "$dest.new"
  tar -xf "$arc" -C "$dest.new" --strip-components=1
  rm -rf "${dest:?}"; mv "$dest.new" "$dest"
}

# sd_notify()/sd_notifyf() for a Type=notify unit (PHP-FPM, Valkey), as a
# static library in place of Ubuntu's libsystemd, which cannot be linked
# statically.  The datagram protocol of sd_notify(3).  Needs CC and AR.
sdnotify_shim() { # dir cflags
  local d=$1 cflags=$2
  mkdir -p "$d/include/systemd" "$d/lib/pkgconfig" "$d/src"
  rm -f "$d/lib/pkgconfig/libsystemd.pc"
  cat > "$d/include/systemd/sd-daemon.h" <<'EOF'
/* setup.sh build-common: the sd_notify subset of libsystemd PHP-FPM and Valkey use. */
#ifndef SETUP_SD_DAEMON_H
#define SETUP_SD_DAEMON_H
int sd_notify(int unset_environment, const char *state);
int sd_notifyf(int unset_environment, const char *format, ...) __attribute__((format(printf, 2, 3)));
#endif
EOF
  cat > "$d/src/sd-notify.c" <<'EOF'
/* setup.sh build-common: sd_notify(3) over $NOTIFY_SOCKET (AF_UNIX datagram). */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "systemd/sd-daemon.h"

int sd_notify(int unset_environment, const char *state) {
  const char *e = getenv("NOTIFY_SOCKET");
  struct sockaddr_un sa;
  size_t n;
  int fd, r = 0;
  if (!e || !state) goto out;
  n = strlen(e);
  if ((e[0] != '/' && e[0] != '@') || n < 2 || n >= sizeof(sa.sun_path)) { r = -EINVAL; goto out; }
  memset(&sa, 0, sizeof(sa));
  sa.sun_family = AF_UNIX;
  memcpy(sa.sun_path, e, n);
  if (sa.sun_path[0] == '@') sa.sun_path[0] = 0;
  fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) { r = -errno; goto out; }
  if (sendto(fd, state, strlen(state), MSG_NOSIGNAL, (struct sockaddr *)&sa,
             (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n)) < 0) r = -errno;
  else r = 1;
  close(fd);
out:
  if (unset_environment) unsetenv("NOTIFY_SOCKET");
  return r;
}

int sd_notifyf(int unset_environment, const char *format, ...) {
  va_list ap;
  char *p = NULL;
  int r;
  va_start(ap, format);
  r = vasprintf(&p, format, ap);
  va_end(ap);
  if (r < 0) {
    if (unset_environment) unsetenv("NOTIFY_SOCKET");
    return -ENOMEM;
  }
  r = sd_notify(unset_environment, p);
  free(p);
  return r;
}
EOF
  # shellcheck disable=SC2086
  "$CC" $cflags -I"$d/include" -c "$d/src/sd-notify.c" -o "$d/src/sd-notify.o"
  rm -f "$d/lib/libsystemd.a"
  "$AR" rcs "$d/lib/libsystemd.a" "$d/src/sd-notify.o"
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libsystemd\nDescription: sd_notify only (setup.sh build-common)\nVersion: 258\nLibs: -L${libdir} -lsystemd\nCflags: -I${includedir}\n' \
    "$d" > "$d/lib/pkgconfig/libsystemd.pc"
}

# A BOLT output must keep a non-executable stack.  llvm-bolt's
# -use-gnu-stack (used until 1.21.71) turns the PT_GNU_STACK header into the
# new code segment's LOAD; without PT_GNU_STACK Linux gives the process an
# executable stack, which is a hardening loss, and a unit with
# MemoryDenyWriteExecute= (Valkey's) refuses to start it at all.
bolt_stack_check() { # binary
  readelf -lW "$1" 2>/dev/null | grep -qE '^[[:space:]]*GNU_STACK[[:space:]].*[[:space:]]RW[[:space:]]+(0x)?[0-9a-f]+[[:space:]]*$' \
    || die "BOLT output ${1##*/} has no non-executable GNU_STACK header; not installed"
}

# ---------------------------------------------------------------- chain
# setup-build-cpu.service and setup-build-refresh.service run this file as a
# script (`bash build-common.sh chain cpu|refresh`, whichever component's
# copy exists).  The tools and units it drives:
BUILD_TOOL_NGINX=${SETUP_BUILD_TOOL_NGINX:-/usr/local/lib/setup-nginx/nginx-build.sh}
BUILD_TOOL_PHP=${SETUP_BUILD_TOOL_PHP:-/usr/local/lib/setup-php/php-build.sh}
BUILD_TOOL_VALKEY=${SETUP_BUILD_TOOL_VALKEY:-/usr/local/lib/setup-valkey/valkey-build.sh}
BUILD_PHP_ACTIVE=${SETUP_PHP_ACTIVE_FILE:-/etc/php/setup-active}
BUILD_UNIT_DIR=${SETUP_BUILD_UNIT_DIR:-/etc/systemd/system}
# lib/migrate.sh's MIGRATE_STATE_FILE (KEY=VALUE lines; its test hook
# SETUP_MIGRATE_STATE_FILE is honoured here too).
BUILD_MIGRATE_STATE=${SETUP_MIGRATE_STATE:-${SETUP_MIGRATE_STATE_FILE:-/var/lib/setup.sh/migrate-1.22}}
BUILD_CPU_ATTEMPTS=${SETUP_BUILD_CPU_ATTEMPTS:-/run/setup-build-cpu.attempts}
# setup.sh's run lock (lib/common.sh LOCK_FILE), held for a whole install,
# --optimize or --upgrade-php run.
BUILD_RUN_LOCK=${SETUP_RUN_LOCK:-/run/setup.sh.lock}
# Per-stage budgets of the CPU chain (seconds).  setup-build-cpu.service's
# TimeoutStartSec (lib/nginx-build.sh) is sized above their sum.
BUILD_CHAIN_T_NGINX=${SETUP_BUILD_CHAIN_T_NGINX:-3600}
BUILD_CHAIN_T_PHP=${SETUP_BUILD_CHAIN_T_PHP:-7200}
BUILD_CHAIN_T_VALKEY=${SETUP_BUILD_CHAIN_T_VALKEY:-3600}

# Start UNIT after its rebuild, but only when it is enabled: never a masked,
# disabled or retired unit (an Angie-era or mid-migration unit stays as it is).
chain_start() { # unit
  local u=$1
  if [[ $(systemctl is-enabled "$u" 2>/dev/null) != enabled ]]; then
    say "chain: $u is not enabled; not started"; return 0
  fi
  systemctl reset-failed "$u" >/dev/null 2>&1 || true
  if timeout 300 systemctl start "$u"; then say "chain: $u started"; else say "chain: $u did not start (systemctl status $u)"; return 1; fi
}

# One stage with its own timeout; a failure is logged and the chain goes on,
# so a PHP failure never keeps nginx (or Valkey) down.
chain_stage() { # label timeout-seconds unit tool args...
  local label=$1 t=$2 unit=$3 rc=0; shift 3
  say "chain: rebuilding $label for this CPU"
  timeout --kill-after=60 "$t" bash "$@" || rc=$?
  if (( rc != 0 )); then
    say "chain: $label FAILED (status $rc; log under the tool's logs/); $unit stays down; continuing"
    return 1
  fi
  chain_start "$unit"
}

# The active PHP version(s): /etc/php/setup-active (one version owns the
# shared socket), else every enabled phpX.Y-fpm unit we wrote.
chain_php_versions() {
  local f v
  if [[ -s $BUILD_PHP_ACTIVE ]]; then
    v=$(tr -d '[:space:]' < "$BUILD_PHP_ACTIVE")
    [[ $v =~ ^[0-9]+\.[0-9]+$ ]] && { printf '%s\n' "$v"; return 0; }
  fi
  for f in "$BUILD_UNIT_DIR"/php*-fpm.service; do
    [[ -f $f ]] || continue
    v=${f##*/php}; v=${v%-fpm.service}
    [[ $v =~ ^[0-9]+\.[0-9]+$ ]] || continue
    [[ $(systemctl is-enabled "php$v-fpm.service" 2>/dev/null) == enabled ]] && printf '%s\n' "$v"
  done | sort -V
}

# setup-build-cpu.service (R2.4 / REVISION 3): after a CPU change every gate
# only starts this unit, which rebuilds serially under the build lock: nginx
# first (proxy-only sites come back first), then the active PHP version, then
# Valkey, each from the exact versions in its build.info with cached sources
# and the recorded LLVM (the tools' rebuild-cpu mode), no BOLT (the refresh
# timer applies it later).  At most two attempts per boot.
build_chain_cpu() {
  local n=0 rc=0 v
  n=$(cat "$BUILD_CPU_ATTEMPTS" 2>/dev/null || echo 0)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if (( n >= 2 )); then
    # The counter stays in /run until reboot: every later gate trigger (each
    # service's ExecStartPre, a manual start) is refused as well, so a build
    # that keeps failing cannot loop.  Resetting it is a deliberate operator
    # step, never just a third start.
    say "chain: two CPU rebuild attempts failed since boot; services stay down (operator rule). Fix the cause (journalctl -t setup-nginx-build -t setup-php-build -t setup-valkey-build), then run: rm -f $BUILD_CPU_ATTEMPTS && systemctl start setup-build-cpu.service"
    return 1
  fi
  printf '%s' "$(( n + 1 ))" > "$BUILD_CPU_ATTEMPTS" 2>/dev/null || true
  if [[ -f $BUILD_TOOL_NGINX ]]; then
    chain_stage nginx "$BUILD_CHAIN_T_NGINX" nginx.service "$BUILD_TOOL_NGINX" rebuild-cpu || rc=1
  fi
  if [[ -f $BUILD_TOOL_PHP ]]; then
    while IFS= read -r v; do
      [[ -n $v ]] || continue
      chain_stage "PHP $v" "$BUILD_CHAIN_T_PHP" "php$v-fpm.service" "$BUILD_TOOL_PHP" rebuild-cpu "$v" || rc=1
    done < <(chain_php_versions)
  fi
  if [[ -f $BUILD_TOOL_VALKEY ]]; then
    chain_stage Valkey "$BUILD_CHAIN_T_VALKEY" valkey-server.service "$BUILD_TOOL_VALKEY" rebuild-cpu || rc=1
  fi
  (( rc == 0 )) && rm -f "$BUILD_CPU_ATTEMPTS"
  return "$rc"
}

# The 1.22 migration is running or unfinished: its state file exists without
# the line lib/migrate.sh's migrate_mark_complete writes, `complete=1`
# (`complete=0` while a run is under way or after a failed one).  No state
# file: the host never migrated (a fresh 1.22 install).  Refresh builds wait
# for it (R65).
migration_pending() {
  [[ -f $BUILD_MIGRATE_STATE ]] || return 1
  ! grep -qx 'complete=1' "$BUILD_MIGRATE_STATE" 2>/dev/null
}

# A setup.sh run (install, --optimize, --upgrade-php) holds its run lock.
# Probed with a shared, non-blocking lock that is dropped at once: an
# exclusive probe could make a setup.sh starting in that instant refuse to run.
setup_run_active() {
  [[ -f $BUILD_RUN_LOCK && ! -L $BUILD_RUN_LOCK ]] && command -v flock >/dev/null 2>&1 || return 1
  ! ( exec 8<"$BUILD_RUN_LOCK" && flock -n -s 8 ) 2>/dev/null
}

# setup-build-refresh.service (daily timer): each tool's `refresh` checks for
# newer upstream releases, rebuilds in the background and swaps the binary
# only after the new one passed verify; it never takes a service down.  Runs
# under build_lock_try (skips while another build or the CPU chain holds the
# lock).  Under high load only one component (rotating by day) is refreshed.
build_chain_refresh() {
  local -a tools=() t
  local i=0 load cpus pick
  if migration_pending; then say "refresh skipped: the 1.22 migration is not finished ($BUILD_MIGRATE_STATE)"; return 0; fi
  # A running setup.sh may be switching PHP versions (--upgrade-php) or
  # rewriting units; a refresh activate or restart in the middle of that
  # would race the handover (R65 c/e).  The timer is Persistent: the next
  # day's run picks the refresh up.
  if setup_run_active; then say "refresh skipped: a setup.sh run is in progress ($BUILD_RUN_LOCK)"; return 0; fi
  [[ -f $BUILD_TOOL_NGINX ]] && tools+=("$BUILD_TOOL_NGINX")
  [[ -f $BUILD_TOOL_PHP ]] && tools+=("$BUILD_TOOL_PHP")
  [[ -f $BUILD_TOOL_VALKEY ]] && tools+=("$BUILD_TOOL_VALKEY")
  (( ${#tools[@]} )) || return 0
  load=$(awk '{ printf "%d", $1 }' /proc/loadavg 2>/dev/null || echo 0)
  cpus=$(build_cpus)
  pick=-1
  if (( load >= cpus )); then
    pick=$(( 10#$(date +%j) % ${#tools[@]} ))
    say "refresh: load $load on $cpus CPUs; refreshing only ${tools[$pick]##*/} today"
  fi
  for t in "${tools[@]}"; do
    if (( pick < 0 || pick == i )); then
      bash "$t" refresh || say "refresh: ${t##*/} refresh failed (status $?); the running build keeps serving"
    fi
    i=$(( i + 1 ))
  done
  return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -Eeuo pipefail
  export LC_ALL=C
  LOG_TAG=setup-build-chain
  case "${1:-} ${2:-}" in
    "chain cpu")
      build_lock_run build_chain_cpu ;;
    "chain refresh")
      chain_rc=0
      build_lock_try build_chain_refresh || chain_rc=$?
      if (( chain_rc == 75 )); then say "refresh skipped: build lock held ($BUILD_LOCK)"; exit 0; fi
      exit "$chain_rc" ;;
    "cpu-fingerprint "*)
      printf '%s\n' "$(cpu_fingerprint)" ;;
    *) die "usage: $0 chain cpu|refresh | cpu-fingerprint" ;;
  esac
fi
