#!/usr/bin/env bash
# Valkey compiled from source, the only Valkey setup.sh installs (1.22.0).
#
# Valkey from its own GitHub release (the newest one; VALKEY_VERSION in
# valkey-build.conf pins another), compiled with clang from apt.llvm.org at
# -O3 -march=native with Ubuntu's hardening flags and link-time optimisation,
# Valkey's bundled jemalloc and Lua linked in, then rewritten by LLVM BOLT
# from a perf sample of a valkey-benchmark run against the build itself.  It
# links only glibc (libc, libm) from Ubuntu: no OpenSSL (the applications
# talk to Valkey over its unix socket, so TLS is left out), no libjemalloc,
# and sd_notify() for the unit's Type=notify is the small static
# implementation tools/build-common.sh writes, not libsystemd.  There is no
# valkey-server package behind it any more: no fallback binary, no APT hook.
#
# Layout (ROOT = /usr/local/lib/setup-valkey):
#   ROOT/bin/valkey-server, valkey-cli, valkey-benchmark   stripped binaries
#   ROOT/bin/valkey-check-aof, valkey-check-rdb            links to the server
#     (the server dispatches on argv[0], exactly as Valkey's "make install")
#   ROOT/lto/valkey-server.lto     unstripped, with relocations, for BOLT
#   ROOT/build.info                versions, CPU fingerprint, source hash
#   ROOT/staging/                  a verified build waiting for "activate"
#   ROOT/prev/                     the build before the last activate
#   ROOT/logs/valkey-*.log         the last 5 build logs (kept on failure)
#   /usr/local/bin/valkey-*        PATH links (never dpkg-owned paths)
#   /etc/systemd/system/valkey-server.service (+ Alias valkey.service)
#   /etc/valkey/valkey.conf        seeded on a host without one; setup.sh's
#                                  valkey_apply_config owns the managed keys
#
# Version policy.  Valkey here is a cache (save "", appendonly no): the
# newest release is safe to run.  A host whose valkey.conf persists data
# (save or appendonly) stays on the X.Y series of the server that wrote the
# data: the active build (build.info valkey=), else the newer of the
# valkey-server package (recorded as pkg_version= in build.info during the
# 1.22 migration) and the 1.21 build its drop-in ran.  An older
# server cannot load a newer RDB/AOF, so such a host never goes below that
# version either.
#
# Downloads: the release archive is checked against the SHA-256 in
# valkey-io/valkey-hashes, a second repository the Valkey project keeps for
# exactly this.  A mismatch stops the build.  Only when that repository is
# unreachable is the archive pinned on first use (reported).  When it answers
# but does not list the release yet, "latest" means the newest release it
# does list (reported), and a pinned version builds only when build.info
# already records that archive's hash; otherwise the build stops.
#
# Usage (root):
#   valkey-build.sh build [--cpu-only]  build + verify into ROOT/staging
#   valkey-build.sh activate      staging -> ROOT/bin, unit/layout, restart, PING
#   valkey-build.sh bolt          profile a valkey-benchmark run, BOLT
#   valkey-build.sh rebuild       build, activate, bolt
#   valkey-build.sh rebuild-cpu   setup-build-cpu.service: the build.info
#                                 versions from the cache, activate, no BOLT
#   valkey-build.sh refresh       daily timer: rebuild when stale, BOLT when due
#   valkey-build.sh check         0 current, 10 rebuild due, 11 cache missing
#   valkey-build.sh layout        user, dirs, valkey.conf seed, unit, links
#   valkey-build.sh pre           ExecStartPre (CPU gate)
#   valkey-build.sh fetch | versions | status | unit-text | apt-hook
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ROOT=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}
BIN=$ROOT/bin
LTO_DIR=$ROOT/lto
STAGE=$ROOT/staging
PREV=$ROOT/prev
INFO=$ROOT/build.info
LOG_DIR=${VALKEY_BUILD_LOG_DIR:-$ROOT/logs}
SRC_CACHE=${VALKEY_BUILD_CACHE:-/var/cache/setup-valkey-build}
UNIT_DIR=${VALKEY_BUILD_UNIT_DIR:-/etc/systemd/system}
UNIT=valkey-server
UNIT_FILE=$UNIT_DIR/$UNIT.service
ALIAS_FILE=$UNIT_DIR/valkey.service
LINK_DIR=${VALKEY_BUILD_LINK_DIR:-/usr/local/bin}
CONF=${VALKEY_BUILD_CONF:-$ROOT/valkey-build.conf}
TOOL=${VALKEY_BUILD_TOOL_PATH:-$ROOT/valkey-build.sh}
ETC_DIR=${VALKEY_BUILD_ETC:-/etc/valkey}
VALKEY_CONF=${VALKEY_BUILD_VALKEY_CONF:-$ETC_DIR/valkey.conf}
DATA_DIR=${VALKEY_BUILD_DATA_DIR:-/var/lib/valkey}
VK_LOG_DIR=${VALKEY_BUILD_SERVER_LOG_DIR:-/var/www/logs/valkey}
DEFAULT_SOCK=/run/valkey/valkey.sock
# What 1.21.71 left behind: the binary layout its drop-in starts and the
# drop-in itself.  Both are only read here; the activate of the cutover
# removes the drop-in (it would override our ExecStart), the migration moves
# the old layout to /var/backups/setup-1.22 after the cutover verifies.
LEGACY_BUILD=$ROOT/build
LEGACY_DROPIN=$UNIT_DIR/$UNIT.service.d/zz-setup-build.conf
LEGACY_APT_HOOK=${VALKEY_BUILD_LEGACY_APT_HOOK:-/etc/apt/apt.conf.d/99setup-valkey-build}
CPU_UNIT=setup-build-cpu.service
UNIT_MARKER='# setup-valkey-unit 1.22'
LOG_TAG=setup-valkey-build
BOLT_MIN_FUNCS=${VALKEY_BUILD_BOLT_MIN_FUNCS:-100}
SELF=$(readlink -f "${BASH_SOURCE[0]}")
BUILD_COMMON=${VALKEY_BUILD_COMMON:-$(dirname "$SELF")/build-common.sh}
# shellcheck source=tools/build-common.sh
. "$BUILD_COMMON"

# 2: 1.22 layout (bin/, staging, valkey-cli and the check tools installed).
BUILD_RECIPE=2
COMPONENTS=(valkey llvm)
declare -A VERS=()
# Every program Valkey's "make" produces that this setup installs.
BINS=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb)
# Ubuntu libraries the build must not link.
STATIC_LIBS_RE='^(libssl|libcrypto|libjemalloc|libsystemd|liblua[0-9.]*|libatomic|libstdc\+\+)\.so'
# valkey-hashes: "hash valkey-X.Y.Z.tar.gz sha256 <hex> <url>" lines.
HASHES_URLS=${VALKEY_BUILD_HASHES_URLS:-"https://raw.githubusercontent.com/valkey-io/valkey-hashes/main/README https://raw.githubusercontent.com/valkey-io/valkey-hashes/main/README.md"}

info_get() { # file key
  [[ -f $1 ]] && awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
  return 0
}
info_set() { # file key value
  local f=$1 k=$2 v=$3
  [[ -f $f ]] || return 0
  awk -F= -v k="$k" -v v="$v" 'BEGIN { done = 0 } $1 == k { print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' "$f" > "$f.new"
  mv -f "$f.new" "$f"
}
bin_version() { "$1" --version 2>/dev/null | sed -nE 's/.* v=([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | sed -n 1p; }
# The CPU description for messages; the gate compares cpu_fingerprint.
cpu_desc() { awk -F': ' '/^vendor_id/ { v = $2 } /^model name/ { m = $2 } END { print v " " m }' /proc/cpuinfo 2>/dev/null; }
pkg_installed() { dpkg-query -W -f='${Status}' "${1:-valkey-server}" 2>/dev/null | grep -q ' installed$'; }
# The valkey-server package's upstream version while it is installed.
pkg_version() {
  local v=""
  pkg_installed valkey-server || return 0
  v=$(dpkg-query -W -f='${Version}' valkey-server 2>/dev/null | sed -nE 's/^([0-9]+:)?([0-9]+\.[0-9]+\.[0-9]+).*/\2/p')
  [[ -n $v ]] || { [[ -x /usr/bin/valkey-server ]] && v=$(bin_version /usr/bin/valkey-server); }
  printf '%s' "$v"
}
unit_is_ours() { [[ -f $UNIT_FILE ]] && grep -qxF "$UNIT_MARKER" "$UNIT_FILE"; }
unit_state() { systemctl is-enabled "$UNIT.service" 2>/dev/null || true; }

# The socket (or loopback port) the live server answers on, from valkey.conf.
live_target() {
  local s p
  s=$(awk '$1 == "unixsocket" { v = $2 } END { print v }' "$VALKEY_CONF" 2>/dev/null || true)
  if [[ -n $s ]]; then printf -- '-s\n%s\n' "$s"; return 0; fi
  p=$(awk '$1 == "port" { v = $2 } END { print v }' "$VALKEY_CONF" 2>/dev/null || true)
  printf -- '-h\n127.0.0.1\n-p\n%s\n' "${p:-6379}"
}

# PONG, or an error that only a running server gives: NOAUTH (requirepass
# in an operator configuration) and LOADING (a persisted dataset being read).
alive_reply() { [[ $1 == PONG || $1 == NOAUTH* || $1 == LOADING* ]]; }

answers() { # [cli]
  local cli=${1:-$BIN/valkey-cli} r _
  local -a t=()
  mapfile -t t < <(live_target)
  [[ -x $cli ]] || return 1
  for _ in $(seq 1 150); do
    r=$("$cli" "${t[@]}" ping 2>/dev/null || true)
    alive_reply "$r" && return 0
    sleep 0.2
  done
  return 1
}

restart_checked() {
  systemctl reset-failed "$UNIT.service" >/dev/null 2>&1 || true
  systemctl restart "$UNIT.service" >/dev/null 2>&1 || return 1
  answers
}

# True when valkey.conf keeps data across restarts (RDB snapshots or AOF).
persists() {
  local save aof
  [[ -f $VALKEY_CONF ]] || return 1
  save=$(awk '$1 == "save" { $1 = ""; v = $0 } END { gsub(/^ +|"/, "", v); print v }' "$VALKEY_CONF")
  aof=$(awk '$1 == "appendonly" { v = $2 } END { print v }' "$VALKEY_CONF")
  [[ -n $save || ${aof,,} == yes ]]
}

# "source:version" of the server whose data a persisting host keeps: our
# active build; else the newer of the valkey-server package and the 1.21
# build.  On a 1.21 clang host the package is still installed but its unit
# ran the 1.21 build (through the zz-setup-build.conf drop-in), so either may
# have written the RDB/AOF, and only the newer one is a safe floor.  "" when
# there is none.
data_writer() {
  local v p l
  v=$(info_get "$INFO" valkey); [[ -n $v ]] && { printf 'build:%s' "$v"; return 0; }
  p=$(pkg_version)
  l=$(info_get "$LEGACY_BUILD/build.info" valkey)
  [[ $l =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || l=""
  if [[ -n $l ]] && { [[ -z $p ]] || ver_ge "$l" "$p"; }; then printf 'build-1.21:%s' "$l"; return 0; fi
  [[ -n $p ]] && printf 'package:%s' "$p"
  return 0
}

# The series a persisting host must stay on ("" = any).
series() {
  local w
  persists || return 0
  w=$(data_writer)
  [[ -n $w ]] || return 0
  w=${w#*:}
  printf '%s' "${w%.*}"
}

# build-common's resolve() falls back to last_known() when no source answers.
# Its glob ("$ROOT"/*/build.info) fits PHP's per-version trees; here it
# would read ROOT/prev or ROOT/staging, and an offline refresh would "update"
# to the previous build and flip back on the next failed lookup.  Only the
# active record, then the 1.21 build, count.
last_known() {
  local v
  v=$(info_get "$INFO" "$1")
  [[ -n $v ]] || v=$(info_get "$LEGACY_BUILD/build.info" "$1")
  printf '%s' "$v"
}

# The valkey-hashes file, or status 2 when the repository is unreachable.
hashes_text() {
  local u txt
  for u in $HASHES_URLS; do
    txt=$(http_get "$u" 2>/dev/null) && [[ -n $txt ]] && { printf '%s\n' "$txt"; return 0; }
  done
  return 2
}

# The newest X.Y.Z valkey-hashes lists that is no newer than MAX and, when
# SERIES is set, inside that X.Y series.  Empty when there is none.
hashes_newest_listed() { # series max
  local txt v
  txt=$(hashes_text) || return 0
  awk '$1 == "hash" && $3 == "sha256" && $4 ~ /^[0-9a-f]+$/ && length($4) == 64 && $2 ~ /^valkey-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/ {
         v = $2; sub(/^valkey-/, "", v); sub(/\.tar\.gz$/, "", v); print v }' <<<"$txt" \
    | while IFS= read -r v; do
        [[ -z $1 || ${v%.*} == "$1" ]] || continue
        ver_ge "$2" "$v" && printf '%s\n' "$v"
      done | sort -V | tail -n 1
  return 0
}

resolve_all() {
  local c v rc=0 x h alt
  x=$(series)
  for c in "${COMPONENTS[@]}"; do
    if [[ $c == valkey ]]; then
      v=$(resolve valkey "$x") || v=""
      # "latest" never means a release valkey-hashes cannot vouch for yet
      # while that repository answers (first-use trust only when it is
      # unreachable).  check and build both resolve here, so they agree and
      # the daily refresh does not rebuild the same version every day.
      # The active build's own version needs no lookup (its hash is in
      # build.info).
      if [[ -n $v && $(conf_get valkey) == latest && $v != "$(info_get "$INFO" valkey)" ]]; then
        h=0; hashes_lookup "$v" >/dev/null 2>&1 || h=$?
        if (( h == 3 )); then
          alt=$(hashes_newest_listed "$x" "$v")
          if [[ -n $alt ]]; then
            say "valkey-hashes does not list Valkey $v yet: using $alt, the newest release it lists"
            v=$alt
          fi
        fi
      fi
    else v=$(resolve "$c") || v=""
    fi
    if [[ -n $v ]]; then printf '%s=%s\n' "$c" "$v"; else printf '%s=?\n' "$c"; rc=1; fi
  done
  return "$rc"
}

# ------------------------------------------------------------ the shared lock
# Every build (install, --optimize, refresh, CPU chain, migration) runs under
# /run/setup-build.lock; build_lock_run (build-common) waits for it.  The
# tool re-executes itself under the lock, so a function never needs to know;
# SETUP_BUILD_LOCK_HELD=1 marks a caller (CPU chain, migration) that already
# holds it, so no deadlock.
run_locked() { # command [args]
  if [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]]; then dispatch "$@"; return; fi
  build_lock_run env SETUP_BUILD_LOCK_HELD=1 "$BASH" "$SELF" "$@"
}
# Held by someone else (the refresh chain itself holds it and says so).
lock_busy() {
  [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]] && return 1
  command -v flock >/dev/null 2>&1 && ! flock -n "$BUILD_LOCK" true 2>/dev/null
}

# ------------------------------------------------------------- downloads
# The valkey-hashes SHA-256 of valkey-V.tar.gz.  Prints "sum url" (url may be
# empty); status 2 when the repository is unreachable, 3 when it answers but
# does not list V yet.
hashes_lookup() { # version
  local txt line
  txt=$(hashes_text) || return 2
  line=$(awk -v f="valkey-$1.tar.gz" '$1 == "hash" && $2 == f && $3 == "sha256" && $4 ~ /^[0-9a-f]{64}$/ { print $4, $5; exit }' <<<"$txt")
  [[ -n $line ]] || return 3
  printf '%s' "$line"
}

# The release archive of V in SRC_CACHE/src, verified.  KNOWN (the build.info
# hash of the active build) lets the CPU rebuild use the cache offline.
# Prints "path check" (check: valkey-hashes, build.info, cached or tofu).
fetch_valkey() { # version [known-sha256]
  local v=$1 known=${2:-} f sum="" url="" rc=0 urls line p SRC_CHECK=""
  f=$SRC_CACHE/src/valkey-$v.tar.gz
  mkdir -p "$SRC_CACHE/src"
  if [[ -n $known && -s $f && $(sha256sum "$f" | awk '{print $1}') == "$known" ]]; then
    printf '%s cached' "$f"; return 0
  fi
  line=$(hashes_lookup "$v") || rc=$?
  case $rc in
    0) read -r sum url <<<"$line"; SRC_CHECK=valkey-hashes ;;
    2) say "valkey-hashes is unreachable: valkey-$v.tar.gz is pinned on first download (reported)"
       SRC_CHECK=tofu ;;
    # The verification source answered and does not vouch for this archive:
    # fail closed, unless build.info already records this exact archive's
    # hash (the active build's own version; used just below).  First-use
    # trust is only for an unreachable repository (R36/R95).
    3) [[ -n $known ]] \
         || die "valkey-hashes does not list Valkey $v: refusing an unverified archive (pin a listed VALKEY_VERSION in $CONF, or retry once valkey-hashes lists it)"
       say "valkey-hashes does not list Valkey $v: using the hash build.info records for it" ;;
  esac
  # A recorded hash of this exact file (the active build) wins over first use.
  [[ -z $sum && -n $known ]] && { sum=$known; SRC_CHECK=build.info; }
  urls="https://github.com/valkey-io/valkey/archive/refs/tags/$v.tar.gz https://codeload.github.com/valkey-io/valkey/tar.gz/refs/tags/$v"
  if [[ $url =~ ^https://(github\.com/valkey-io/|download\.valkey\.io/) ]]; then urls="$url $urls"; fi
  # shellcheck disable=SC2034 # read by fetch_mirror in build-common
  FETCH_NAME=valkey
  p=$(fetch_first "$urls|$f|$sum") || return 1
  printf '%s %s' "$p" "$SRC_CHECK"
}

# ------------------------------------------------------------------ build
llvm_use() { # major: the recorded toolchain without any network lookup
  local n=$1
  if [[ -x /usr/lib/llvm-$n/bin/clang && -x /usr/lib/llvm-$n/bin/ld.lld ]]; then LLVM_BIN=/usr/lib/llvm-$n/bin; return 0; fi
  if [[ -x $LLVM_OPT/$n/bin/clang && -x $LLVM_OPT/$n/bin/ld.lld ]]; then LLVM_BIN=$LLVM_OPT/$n/bin; return 0; fi
  return 1
}

# Free space (R2.4): the floor every build shares (build_space_check: 6 GB
# on the build cache filesystem, 2 GB on /), plus about 4 GB more on / when
# the LLVM toolchain still has to be installed.  A build that would fill the
# disk MariaDB writes to is refused instead.
space_check() { # llvm-major
  local root_mb need_root
  build_space_check "$SRC_CACHE"
  llvm_use "$1" && return 0
  need_root=$(( BUILD_MIN_ROOT_MB + 4096 ))
  root_mb=$(free_mb /)
  [[ ! $root_mb =~ ^[0-9]+$ ]] || (( root_mb >= need_root )) \
    || die "only ${root_mb} MB free on /; installing LLVM $1 and building needs $need_root MB; free space and retry"
}

# glibc 2.39 (Ubuntu 24.04) defines sprintf as a fortify MACRO for clang at
# _FORTIFY_SOURCE=3; glibc 2.40 and later (26.04) fortify clang without one.
# Valkey's fmacros.h re-declares sprintf to deprecate it, and its Lua module
# includes fmacros.h after <stdio.h>, so on 24.04 the declaration expanded
# the macro and the build stopped ("expected parameter declarator", 1.22.3
# migration test of a 24.04 host).  The re-declaration is skipped where
# sprintf is a macro; nothing changes where it is not.  Idempotent.
fortify_sprintf_guard() { # fmacros.h
  local f=$1
  [[ -f $f ]] || return 0
  grep -q '^#ifndef sprintf$' "$f" && return 0
  grep -qE '^int sprintf\(char \*str, const char \*format, \.\.\.\)$' "$f" || return 0
  sed -i -E '/^int sprintf\(char \*str, const char \*format, \.\.\.\)$/{
i #ifndef sprintf
n
a #endif
}' "$f"
}

cmd_build() { # [--cpu-only]
  local cpu_only=0 work src n j flags ld line x w arc sum stamp b
  [[ ${1:-} == --cpu-only ]] && cpu_only=1
  need_root
  ensure_packages ca-certificates curl git make pkg-config build-essential
  mkdir -p "$SRC_CACHE/src" "$LOG_DIR"; chmod 700 "$SRC_CACHE"; chmod 750 "$LOG_DIR"
  if (( cpu_only )); then
    # The exact versions of the active build: a CPU change never changes a
    # version, and nothing is looked up while the services are down.
    [[ -f $INFO ]] || die "no build.info: nothing to rebuild for this CPU"
    for line in "${COMPONENTS[@]}"; do
      VERS[$line]=$(info_get "$INFO" "$line")
      [[ -n ${VERS[$line]} ]] || die "build.info records no $line version"
    done
  else
    while IFS='=' read -r line n; do
      [[ $n == "?" ]] && die "cannot resolve the $line version (offline? pin $(conf_key "$line") in $CONF)"
      VERS[$line]=$n
    done < <(resolve_all || true)
    x=$(series)
    if [[ -n $x ]]; then
      w=$(data_writer)
      [[ ${VERS[valkey]%.*} == "$x" ]] \
        || die "valkey.conf persists data (save/appendonly): Valkey must stay on the $x series of ${w%%:*} ${w#*:}, not ${VERS[valkey]}"
      ver_ge "${VERS[valkey]}" "${w#*:}" \
        || die "valkey.conf persists data: Valkey ${VERS[valkey]} is older than ${w%%:*} ${w#*:}, which wrote it"
    fi
  fi
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  space_check "$n"
  if (( cpu_only )); then llvm_use_recorded "$n" "clang-$n" "lld-$n" "llvm-$n"
  else llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  fi
  export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
  # nice 10, idle IO, OOM score 900: the build, never mysqld or a PHP worker,
  # is what the OOM killer takes.
  build_deprioritize
  flags="-march=native -mtune=native -pipe -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 ${VALKEY_BUILD_EXTRA_CFLAGS:-}"
  if [[ $(uname -m) == x86_64 ]]; then flags+=" -fcf-protection=full"; else flags+=" -mbranch-protection=standard"; fi
  # Full LTO (see OPT below); the ThinLTO job cap keeps any thin part of the
  # link inside the same memory budget as make -j.
  ld="-fuse-ld=lld -flto $(build_thinlto_flag) -Wl,--emit-relocs -Wl,-z,relro,-z,now ${VALKEY_BUILD_EXTRA_LDFLAGS:-}"
  j=$(build_jobs)
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  BUILD_LOG=$LOG_DIR/valkey-${VERS[valkey]}-$stamp.log
  : > "$BUILD_LOG"; chmod 640 "$BUILD_LOG"
  build_log_keep "$LOG_DIR" valkey
  work=$(mktemp -d "$SRC_CACHE/build.XXXXXX")
  WORK_DIR=$work
  [[ ${VALKEY_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "building Valkey ${VERS[valkey]} with clang $n, $j jobs$( (( cpu_only )) && printf ' (CPU change: build.info versions, cached sources)') (log: $BUILD_LOG)"
  sdnotify_shim "$work/deps" "-O3 $flags -flto"
  src=$work/valkey
  arc="" SRC_CHECK=""
  # build.info's hash vouches only for the exact version it records (the CPU
  # rebuild, or a recipe change that rebuilds the active version).
  sum=""
  [[ $(info_get "$INFO" valkey) == "${VERS[valkey]}" ]] && sum=$(info_get "$INFO" src_sha256)
  read -r arc SRC_CHECK <<<"$(fetch_valkey "${VERS[valkey]}" "$sum")"
  [[ -s $arc ]] || die "Valkey ${VERS[valkey]}: no verified source archive"
  sum=$(sha256sum "$arc" | awk '{print $1}')
  unpack "$arc" "$src"
  fortify_sprintf_guard "$src/src/fmacros.h"
  # CFLAGS/LDFLAGS go in the ENVIRONMENT, never on make's command line: a
  # command-line variable overrides the assignment in every sub-make, so the
  # bundled jemalloc and Lua lost their own -O flags and built unoptimised
  # (measured 1.21.71: 9,430 instructions per pipelined GET/SET against
  # 5,926 from the environment and 6,152 for the package; 32-41 % fewer
  # pipelined requests/s).  OPT (not OPTIMIZATION): Valkey's Makefile adds
  # -fno-omit-frame-pointer to OPTIMIZATION (OPT measured 3.4 % fewer
  # instructions), and its Lua module strips "-flto" from it (a "-flto=thin"
  # turns into a stray "=thin"); full LTO links fine with lld.
  ( cd "$src" && CFLAGS="$flags -I$work/deps/include" LDFLAGS="$ld -L$work/deps/lib" \
      make -j"$j" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
      OPT="${VALKEY_BUILD_OPT:--O3 -flto}" \
      BUILD_TLS=no USE_SYSTEMD=yes LIBSYSTEMD_LIBS=-lsystemd MALLOC=jemalloc ) >> "$BUILD_LOG" 2>&1 \
    || { tail -n 40 "$BUILD_LOG" >&2; die "Valkey ${VERS[valkey]} failed to build (log: $BUILD_LOG)"; }
  for b in "${BINS[@]}"; do
    [[ -x $src/src/$b ]] || die "the build produced no $b (log: $BUILD_LOG)"
  done
  verify_binary "$src/src/valkey-server" "$src/src/valkey-cli"
  rm -rf "${STAGE:?}"
  install -d -m 755 "$STAGE/bin" "$STAGE/lto"
  install -m 755 "$src/src/valkey-server" "$STAGE/lto/valkey-server.lto"
  install_stripped "$STAGE/lto/valkey-server.lto" "$STAGE/bin/valkey-server"
  install_stripped "$src/src/valkey-cli" "$STAGE/bin/valkey-cli"
  install_stripped "$src/src/valkey-benchmark" "$STAGE/bin/valkey-benchmark"
  # The check tools are the server binary under another name (Valkey's own
  # "make install" links them the same way), so BOLT reaches them too.
  ln -sfn valkey-server "$STAGE/bin/valkey-check-aof"
  ln -sfn valkey-server "$STAGE/bin/valkey-check-rdb"
  [[ $(bin_version "$STAGE/bin/valkey-server") == "${VERS[valkey]}" ]] \
    || die "the stripped valkey-server does not report ${VERS[valkey]}"
  {
    printf 'recipe=%s\n' "$BUILD_RECIPE"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\ncpu_desc=%s\n' "$(cpu_fingerprint)" "$(cpu_desc)"
    printf 'src=%s\nsrc_sha256=%s\nsrc_check=%s\n' "${arc##*/}" "$sum" "$SRC_CHECK"
    printf 'persists=%s\nseries=%s\n' "$(persists && echo 1 || echo 0)" "$(series)"
    printf 'data_writer=%s\npkg_version=%s\n' "$(data_writer)" "$(pkg_version)"
    printf 'log=%s\nbuilt=%s\nbolt=0\n' "$BUILD_LOG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$STAGE/build.info"
  say "Valkey ${VERS[valkey]} built with clang $n and verified (staged; source check: $SRC_CHECK)"
}

# The candidate reports a version, links none of Ubuntu's libraries but
# glibc, and serves PING, a Lua EVAL (the XenForo Redis add-ons use scripts)
# and SAVE on a private socket; the check-rdb entry point (the server under
# that name) reads the RDB back.  Never touches the live data directory.
verify_binary() { # server cli
  local cand=$1 cli=$2 needed tmp pid ok=0 _
  [[ -n $(bin_version "$cand") ]] || die "candidate does not report a Valkey version"
  "$cli" --version >/dev/null 2>&1 || die "candidate valkey-cli does not run"
  needed=$(readelf -d "$cand" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
  if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
    die "candidate links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')"
  fi
  tmp=$(mktemp -d)
  "$cand" --port 0 --unixsocket "$tmp/s" --save "" --appendonly no --dir "$tmp" --daemonize no \
    --logfile "$tmp/log" > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    [[ $("$cli" -s "$tmp/s" ping 2>/dev/null) == PONG ]] && { ok=1; break; }
    sleep 0.1
  done
  if (( ok )) && [[ $("$cli" -s "$tmp/s" eval "return redis.call('set', KEYS[1], ARGV[1])" 1 k v 2>/dev/null) == OK ]] \
     && [[ $("$cli" -s "$tmp/s" get k 2>/dev/null) == v ]] \
     && [[ $("$cli" -s "$tmp/s" save 2>/dev/null) == OK ]]; then ok=2; fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if (( ok == 2 )); then
    ln -s "$cand" "$tmp/valkey-check-rdb"
    "$tmp/valkey-check-rdb" "$tmp/dump.rdb" > "$tmp/check.log" 2>&1 || ok=1
  fi
  rm -rf "$tmp"
  (( ok == 2 )) || die "candidate did not answer PING / EVAL / SAVE on a private socket, or check-rdb failed"
}

# ----------------------------------------------------------------- layout
# The whole unit is ours (no package unit to copy from).  Hardening as the
# Debian/Ubuntu valkey-server unit, plus the options that cost nothing for a
# network daemon.  NoExecPaths=/ with ExecPaths limited to our binaries AND
# /usr/lib /lib: without the library trees ld.so cannot map libc and the
# start fails with 203/EXEC.  The pre hook runs as "+" (outside the sandbox),
# so the tool's ExecPaths entry only documents it.  ReadWritePaths carry "-"
# so a missing directory cannot fail the start with 226/NAMESPACE (layout
# and pre create them).  Restart=on-abnormal: a crash or an OOM kill
# restarts, but the CPU gate's exit 1 does not loop (it queued the rebuild,
# which starts the unit).  TimeoutStopSec=0 as the package: a persisting
# server finishes its final save however long it takes.
unit_text() {
  local execpaths="$BIN $TOOL /usr/lib /lib" d
  for d in /usr/lib64 /lib64; do [[ -d $d ]] && execpaths+=" $d"; done
  cat <<EOF
# Managed by setup.sh (tools/valkey-build.sh): Valkey compiled from source.
# Rewritten on every activate; local changes belong in a drop-in.
$UNIT_MARKER
[Unit]
Description=Valkey key-value store (compiled by setup.sh)
Documentation=https://valkey.io/documentation
After=network.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStartPre=+$TOOL pre
ExecStart=$BIN/valkey-server $VALKEY_CONF --supervised systemd --daemonize no
Restart=on-abnormal
RestartSec=2
TimeoutStartSec=300
TimeoutStopSec=0
RuntimeDirectory=valkey
RuntimeDirectoryMode=2755
UMask=007
LimitNOFILE=524288
LimitCORE=0
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=-$DATA_DIR -$VK_LOG_DIR -/run/valkey -$ETC_DIR
NoNewPrivileges=true
CapabilityBoundingSet=CAP_SYS_RESOURCE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryDenyWriteExecute=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectHostname=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
NoExecPaths=/
ExecPaths=$execpaths

[Install]
WantedBy=multi-user.target
Alias=valkey.service
EOF
}

# valkey.conf for a host that has none (the package used to ship it).  The
# keys setup.sh's valkey_apply_config manages carry safe values here, so the
# file serves on its own; the writer replaces them with its managed block.
conf_template() {
  cat <<EOF
# Valkey configuration, seeded by setup.sh (tools/valkey-build.sh) on a host
# without one.  setup.sh rewrites the block after "# setup.sh managed valkey";
# everything else here is yours to change.
port 6379
dir $DATA_DIR
pidfile /run/valkey/valkey-server.pid
daemonize no
databases 16
loglevel notice
supervised systemd
logfile $VK_LOG_DIR/valkey.log
save ""
appendonly no
bind 127.0.0.1 -::1
protected-mode yes
unixsocket $DEFAULT_SOCK
unixsocketperm 770
maxmemory 128mb
maxmemory-policy allkeys-lru
EOF
}

ensure_user() {
  getent group valkey >/dev/null 2>&1 || groupadd --system valkey
  if ! getent passwd valkey >/dev/null 2>&1; then
    useradd --system --gid valkey --home-dir "$DATA_DIR" --no-create-home \
      --shell /usr/sbin/nologin --comment "Valkey (setup.sh)" valkey
    say "created the valkey system user and group"
  fi
}

ensure_dirs() {
  [[ -d $DATA_DIR ]] || install -d -o valkey -g valkey -m 750 "$DATA_DIR"
  [[ $(stat -c %U "$DATA_DIR") == valkey ]] || chown valkey:valkey "$DATA_DIR"
  [[ -d $VK_LOG_DIR ]] || install -d -o valkey -g valkey -m 750 "$VK_LOG_DIR"
  [[ -d $ETC_DIR ]] || install -d -o root -g valkey -m 750 "$ETC_DIR"
}

# Idempotent; the service is never started here.  Prints "unit-changed"
# when the unit file was (re)written.
cmd_layout() {
  local l b t
  need_root
  ensure_user
  ensure_dirs
  if [[ ! -e $VALKEY_CONF ]]; then
    conf_template > "$VALKEY_CONF.new"
    chown root:valkey "$VALKEY_CONF.new"; chmod 640 "$VALKEY_CONF.new"
    mv -f "$VALKEY_CONF.new" "$VALKEY_CONF"
    say "seeded $VALKEY_CONF"
  fi
  # The 1.21.71 drop-in replaced ExecStart with the old build path; on our
  # unit it would still win.  The package's valkey.service alias points at
  # /lib/...; enable cannot create ours while it exists.
  rm -f "$LEGACY_DROPIN"
  if [[ -L $ALIAS_FILE && $(readlink -f "$ALIAS_FILE") != "$(readlink -f "$UNIT_FILE" 2>/dev/null || printf '%s' "$UNIT_FILE")" ]]; then
    rm -f "$ALIAS_FILE"
  fi
  t=$(unit_text)
  if [[ ! -f $UNIT_FILE || $(cat "$UNIT_FILE") != "$t" ]]; then
    printf '%s\n' "$t" > "$UNIT_FILE.new"; chmod 644 "$UNIT_FILE.new"; mv -f "$UNIT_FILE.new" "$UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    LAYOUT_UNIT_CHANGED=1
    echo unit-changed
  fi
  # reenable re-points the wants link and the alias at /etc; a masked unit
  # stays masked (the operator's choice, or the migration's own handling).
  if [[ $(unit_state) != masked ]]; then
    if [[ ${LAYOUT_UNIT_CHANGED:-0} == 1 || ! -L $ALIAS_FILE ]]; then
      systemctl reenable "$UNIT.service" >/dev/null 2>&1 || true
    else
      systemctl enable "$UNIT.service" >/dev/null 2>&1 || true
    fi
  fi
  # PATH links in /usr/local/bin only: /usr/bin belongs to dpkg (the package
  # removal would delete links placed there).  A file that is not a link is
  # never replaced.
  install -d -m 755 "$LINK_DIR"
  for b in "${BINS[@]}"; do
    l=$LINK_DIR/$b
    [[ -e $l && ! -L $l ]] && { say "$l is not a link; left alone"; continue; }
    [[ -L $l && $(readlink "$l") == "$BIN/$b" ]] || ln -sfn "$BIN/$b" "$l"
  done
  return 0
}

# --------------------------------------------------------------- activate
# Staging -> ROOT/bin by rename (each file atomically; a running server keeps
# its inode), unit and layout, then restart (or start when the unit is
# enabled and down: CPU chain, fresh install, migration cutover) and PING.
# A failed PING puts the previous build back.
restore_prev() {
  local f
  [[ -d $PREV/bin ]] || return 1
  for f in "$PREV"/bin/*; do mv -f "$f" "$BIN/"; done
  [[ -f $PREV/build.info ]] && mv -f "$PREV/build.info" "$INFO"
  [[ -f $PREV/lto/valkey-server.lto ]] && mv -f "$PREV/lto/valkey-server.lto" "$LTO_DIR/"
  rm -rf "${PREV:?}"
}

cmd_activate() {
  local staged=0 f state
  need_root
  if [[ -x $STAGE/bin/valkey-server && -f $STAGE/build.info ]]; then staged=1
  elif [[ ! -x $BIN/valkey-server ]]; then die "no build to activate (run: valkey-build.sh build)"
  fi
  # While the valkey-server package still serves through its own unit, only
  # the 1.22 migration's cutover may replace it (it stops the package server
  # and snapshots the data first).
  if ! unit_is_ours && pkg_installed valkey-server && [[ ${VALKEY_BUILD_CUTOVER:-0} != 1 ]]; then
    die "the valkey-server package still serves: the 1.22 migration activates this build"
  fi
  if (( staged )); then
    [[ $(info_get "$STAGE/build.info" cpu) == "$(cpu_fingerprint)" ]] || die "the staged build was made for another CPU"
    rm -rf "${PREV:?}"
    if [[ -x $BIN/valkey-server ]]; then
      install -d -m 755 "$PREV/bin" "$PREV/lto"
      cp -a "$BIN"/. "$PREV/bin/"
      [[ -f $INFO ]] && cp -a "$INFO" "$PREV/build.info"
      [[ -f $LTO_DIR/valkey-server.lto ]] && cp -a "$LTO_DIR/valkey-server.lto" "$PREV/lto/"
    fi
    install -d -m 755 "$BIN" "$LTO_DIR"
    for f in "$STAGE"/bin/*; do mv -f "$f" "$BIN/"; done
    mv -f "$STAGE/lto/valkey-server.lto" "$LTO_DIR/"
    mv -f "$STAGE/build.info" "$INFO"
    rm -rf "${STAGE:?}"
  fi
  LAYOUT_UNIT_CHANGED=0
  cmd_layout >/dev/null
  state=$(unit_state)
  # The migration cutover starts the unit itself: it verifies the running
  # executable, PING and the dataset, and owns the rollback to the package.
  if [[ ${VALKEY_BUILD_NO_START:-0} == 1 ]]; then
    say "Valkey $(info_get "$INFO" valkey) installed; valkey-server.service ($state) is left to the caller to start"
    return 0
  fi
  # A restart empties a cache-only Valkey: only for a new binary, a changed
  # unit, or a unit that is down.
  if systemctl is-active --quiet "$UNIT.service" && (( ! staged )) && [[ $LAYOUT_UNIT_CHANGED != 1 ]]; then
    answers || die "valkey-server runs but does not answer"
    say "Valkey $(info_get "$INFO" valkey) already active"
    return 0
  fi
  if systemctl is-active --quiet "$UNIT.service" || [[ $state == enabled || ${VALKEY_BUILD_START:-0} == 1 ]]; then
    [[ $state == masked ]] && { say "valkey-server.service is masked: Valkey $(info_get "$INFO" valkey) installed, not started"; return 0; }
    if ! restart_checked; then
      if (( staged )) && restore_prev; then
        restart_checked || true
        die "Valkey $(info_get "$INFO" valkey) did not answer after the restart; the previous build is back"
      fi
      die "valkey-server did not start on the build (journalctl -u valkey-server)"
    fi
    say "Valkey $(info_get "$INFO" valkey) active (BOLT $( [[ $(info_get "$INFO" bolt) == 1 ]] && echo applied || echo pending))"
  else
    say "Valkey $(info_get "$INFO" valkey) installed; valkey-server.service is $state and was not started"
  fi
}

# ------------------------------------------------------------------- pre
# ExecStartPre (as root, "+").  A -march=native build made for another CPU
# can die with SIGILL, and there is no package binary to fall back to: the
# service stays down, setup-build-cpu.service rebuilds nginx, PHP and then
# Valkey from the cached sources and starts each one (operator rule 1.22).
# On a unit that is not ours (the 1.21 drop-in on the package unit still
# names this path until the cutover) the gate stays out of the way.
cmd_pre() {
  local built now
  unit_is_ours || exit 0
  [[ -d $DATA_DIR && -d $VK_LOG_DIR ]] || { ensure_user; ensure_dirs; }
  [[ -x $BIN/valkey-server ]] || { say "no Valkey build in $BIN"; exit 1; }
  built=$(info_get "$INFO" cpu); now=$(cpu_fingerprint)
  [[ -n $built && $built == "$now" ]] && exit 0
  say "Valkey: build made for another CPU ($(info_get "$INFO" cpu_desc), now $(cpu_desc)): staying down until $CPU_UNIT rebuilds it"
  systemctl start --no-block "$CPU_UNIT" >/dev/null 2>&1 \
    || say "Valkey: $CPU_UNIT could not be started; rebuild by hand: $TOOL rebuild-cpu"
  exit 1
}

# ------------------------------------------------------------------- BOLT
# BOLT from a valkey-benchmark run against the running build (database 9,
# flushed afterwards): the GET/SET/HSET/MGET mix of the applications' cache
# calls, without depending on live traffic (1.21.71).
cmd_bolt() {
  local n perf work p2b bolt samples base=$LTO_DIR/valkey-server.lto pid bench r
  local -a t=()
  need_root
  [[ -f $base && -f $INFO ]] || die "no build to BOLT"
  unit_is_ours && systemctl is-active --quiet "$UNIT.service" || die "valkey-server is not running on the compiled unit"
  n=$(info_get "$INFO" llvm)
  perf=$(command -v perf || true)
  if [[ -z $perf ]] || ! "$perf" --version >/dev/null 2>&1; then
    ensure_packages "linux-tools-$(uname -r)" linux-tools-common || die "perf is not installable for kernel $(uname -r)"
    perf=$(command -v perf)
  fi
  llvm_install "$n" "bolt-$n"
  p2b=$LLVM_BIN/perf2bolt; bolt=$LLVM_BIN/llvm-bolt
  [[ -x $p2b && -x $bolt ]] || die "llvm-bolt/perf2bolt $n not found in $LLVM_BIN"
  bench=$BIN/valkey-benchmark
  [[ -x $bench ]] || die "no $bench to drive the profile"
  mapfile -t t < <(live_target)
  if [[ $(info_get "$INFO" bolt) == 1 ]]; then
    install_stripped "$base" "$BIN/valkey-server.new"; mv -f "$BIN/valkey-server.new" "$BIN/valkey-server"
    info_set "$INFO" bolt 0
    restart_checked || die "Valkey did not restart on the LTO build"
  fi
  answers || die "Valkey is not answering (${t[*]})"
  r=$("$BIN/valkey-cli" "${t[@]}" ping 2>/dev/null || true)
  if [[ $r != PONG ]]; then say "Valkey: '$r' from the server (requirepass?): BOLT skipped"; return 3; fi
  pid=$(systemctl show -p MainPID --value "$UNIT.service")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || die "no Valkey process to sample"
  work=$(mktemp -d "$SRC_CACHE/bolt.XXXXXX")
  WORK_DIR=$work
  [[ ${VALKEY_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "Valkey: profiling a valkey-benchmark run for BOLT"
  "$perf" record -q -e cycles:u -j any,u -o "$work/perf.data" -p "$pid" -- \
    "$bench" "${t[@]}" --dbnum 9 -c 50 -n 400000 -r 100000 -d 256 -q \
      -t get,set,hset,lpush,mset,incr > "$work/bench.log" 2>&1 \
    || { "$BIN/valkey-cli" "${t[@]}" -n 9 flushdb >/dev/null 2>&1 || true; die "perf could not record branch samples (no LBR on this CPU or VM?)"; }
  "$BIN/valkey-cli" "${t[@]}" -n 9 flushdb >/dev/null 2>&1 || true
  "$p2b" -p "$work/perf.data" -o "$work/valkey.fdata" "$base" > "$work/p2b.log" 2>&1 \
    || { tail -n 5 "$work/p2b.log" >&2; die "perf2bolt failed"; }
  samples=$(awk '/BOLT-INFO: [0-9]+ out of [0-9]+ functions in the binary/ { print $2 }' "$work/p2b.log" | sed -n 1p)
  if [[ ${samples:-0} -lt $BOLT_MIN_FUNCS ]]; then
    say "Valkey: ${samples:-0} functions profiled (need $BOLT_MIN_FUNCS): BOLT skipped"
    return 3
  fi
  "$bolt" "$base" -o "$work/valkey.bolt" -data="$work/valkey.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -icf > "$work/bolt.log" 2>&1 \
    || { tail -n 5 "$work/bolt.log" >&2; die "llvm-bolt failed"; }
  bolt_stack_check "$work/valkey.bolt"
  verify_binary "$work/valkey.bolt" "$BIN/valkey-cli"
  install -m 600 "$work/valkey.fdata" "$LTO_DIR/valkey-server.fdata"
  install_stripped "$work/valkey.bolt" "$BIN/valkey-server.new"; mv -f "$BIN/valkey-server.new" "$BIN/valkey-server"
  info_set "$INFO" bolt 1
  if ! restart_checked; then
    install_stripped "$base" "$BIN/valkey-server.new"; mv -f "$BIN/valkey-server.new" "$BIN/valkey-server"
    info_set "$INFO" bolt 0
    restart_checked || true
    die "Valkey did not restart on the BOLT build; back on the LTO build"
  fi
  say "Valkey: BOLT applied from ${samples} profiled functions"
}

# BOLT never fails a rebuild: the LTO build serves.  A run that could not
# BOLT records bolt=skipped so the daily refresh does not retry it until the
# next build.
bolt_tolerant() {
  local rc=0
  [[ ${SETUP_VALKEY_BUILD_BOLT:-1} == 1 ]] || return 0
  # A process of its own: errexit does not apply inside an "||" list.
  SETUP_BUILD_LOCK_HELD=1 "$BASH" "$SELF" bolt || rc=$?
  (( rc == 0 )) || { [[ $(info_get "$INFO" bolt) == 1 ]] || info_set "$INFO" bolt skipped; }
  return 0
}

cmd_rebuild() { cmd_build; cmd_activate; bolt_tolerant; }

# setup-build-cpu.service: build.info versions, cached sources, recorded
# LLVM; no BOLT (the refresh timer applies it once traffic runs).
cmd_rebuild_cpu() {
  cmd_build --cpu-only
  cmd_activate
}

# --------------------------------------------------------------- refresh
# What makes the build recorded in RECORD (with its binaries in BINDIR)
# stale: CHECK_STALE gets "what old -> new, " pieces (empty when current),
# CHECK_LOOKUP_FAILED=1 when a version lookup failed (that component is not
# judged).  Globals, not output: a command substitution would lose them.
check_record() { # record bindir
  local rec=$1 bdir=$2 name want have stale="" bcpu f
  CHECK_LOOKUP_FAILED=0
  [[ $(info_get "$rec" recipe) == "$BUILD_RECIPE" ]] || stale+="recipe $(info_get "$rec" recipe) -> $BUILD_RECIPE, "
  bcpu=$(info_get "$rec" cpu)
  [[ -n $bcpu && $bcpu == "$(cpu_fingerprint)" ]] || stale+="cpu $(info_get "$rec" cpu_desc) -> $(cpu_desc), "
  for f in "${BINS[@]}"; do [[ -e $bdir/$f ]] || stale+="$f missing, "; done
  while IFS='=' read -r name want; do
    if [[ $want == "?" ]]; then CHECK_LOOKUP_FAILED=1; continue; fi
    have=$(info_get "$rec" "$name")
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_all || true)
  CHECK_STALE=$stale
}

cmd_check() {
  local stale rc=0 f
  if [[ ! -f $INFO ]]; then
    # No active build yet, but a verified one waits in staging (the package
    # still serves: migration postponed or rolled back).  Rebuilding it on
    # every --optimize would cost minutes for nothing.
    if [[ -f $STAGE/build.info ]]; then
      check_record "$STAGE/build.info" "$STAGE/bin"; stale=$CHECK_STALE
      if [[ -z $stale ]]; then
        echo "staged build $(info_get "$STAGE/build.info" valkey) is current (waiting for activate)"
        (( CHECK_LOOKUP_FAILED )) && return 2
        return 0
      fi
      echo "stale: staged ${stale%, }"; return 10
    fi
    echo "no build"; return 10
  fi
  check_record "$INFO" "$BIN"; stale=$CHECK_STALE
  (( CHECK_LOOKUP_FAILED )) && rc=2
  if [[ -n $stale ]]; then echo "stale: ${stale%, }"; return 10; fi
  # The CPU rebuild needs the active build's archive and toolchain offline.
  f=$SRC_CACHE/src/$(info_get "$INFO" src)
  if [[ ! -s $f ]] || ! llvm_use "$(info_get "$INFO" llvm)"; then
    echo "cache: the source archive or LLVM $(info_get "$INFO" llvm) of the active build is missing"; return 11
  fi
  echo current; return "$rc"
}

# Put the active build's archive and toolchain back into the cache, so a CPU
# change can rebuild offline.
cmd_fetch() {
  local n
  need_root
  [[ -f $INFO ]] || die "no build"
  fetch_valkey "$(info_get "$INFO" valkey)" "$(info_get "$INFO" src_sha256)" >/dev/null
  n=$(info_get "$INFO" llvm)
  llvm_use "$n" || llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  say "Valkey: cache complete for the active build"
}

cmd_refresh() {
  local rc=0 out
  unit_is_ours || { say "refresh skipped: valkey-server is not on the compiled unit"; return 0; }
  migration_pending && { say "refresh skipped: the 1.22 migration is not finished"; return 0; }
  lock_busy && { say "refresh skipped: build lock held"; return 0; }
  export VALKEY_BUILD_AUTO=1
  out=$(cmd_check 2>/dev/null) || rc=$?
  case $rc in
    10) say "Valkey refresh: $out"; "$BASH" "$SELF" rebuild || say "Valkey refresh: rebuild failed; the running build keeps serving" ;;
    11) say "Valkey refresh: $out"; "$BASH" "$SELF" fetch || say "Valkey refresh: fetch failed" ;;
    0)  [[ $(info_get "$INFO" bolt) == 0 ]] && { "$BASH" "$SELF" bolt-tolerant || true; } ;;
    *)  say "Valkey refresh: version lookup failed; the running build stays" ;;
  esac
  return 0
}

cmd_status() {
  local bcpu cpu=no unit=no act
  if [[ -f $INFO ]]; then
    bcpu=$(info_get "$INFO" cpu)
    [[ -n $bcpu && $bcpu == "$(cpu_fingerprint 2>/dev/null)" ]] && cpu=yes
    unit_is_ours && unit=yes
    act=$(systemctl is-active "$UNIT.service" 2>/dev/null || true)
    printf 'Valkey: build %s (clang %s, recipe %s, built %s), bolt=%s, cpu match=%s, unit ours=%s (%s, %s), source=%s, log %s%s\n' \
      "$(info_get "$INFO" valkey)" "$(info_get "$INFO" llvm)" "$(info_get "$INFO" recipe)" "$(info_get "$INFO" built)" \
      "$(info_get "$INFO" bolt)" "$cpu" "$unit" "${act:-unknown}" "$(unit_state)" "$(info_get "$INFO" src_check)" \
      "$(info_get "$INFO" log)" "$( [[ -f $STAGE/build.info ]] && printf ', staged %s' "$(info_get "$STAGE/build.info" valkey)")"
  elif [[ -f $STAGE/build.info ]]; then
    printf 'Valkey: build %s staged, not active%s\n' "$(info_get "$STAGE/build.info" valkey)" \
      "$(pkg_installed valkey-server && printf ' (valkey-server package %s serves)' "$(pkg_version)")"
  else
    printf 'Valkey: no build%s\n' "$(pkg_installed valkey-server && printf ' (valkey-server package %s)' "$(pkg_version)")"
  fi
  return 0
}

# The 1.21 APT hook (DPkg::Post-Invoke) still calls this path until the
# migration deletes it; it must never touch the new build.  It removes itself.
cmd_apt_hook() { rm -f "$LEGACY_APT_HOOK" 2>/dev/null || true; return 0; }

dispatch() {
  local cmd=${1:-status}
  shift || true
  case $cmd in
    build)         cmd_build "$@" ;;
    activate)      cmd_activate ;;
    bolt)          cmd_bolt ;;
    bolt-tolerant) bolt_tolerant ;;
    rebuild)       cmd_rebuild ;;
    rebuild-cpu)   cmd_rebuild_cpu ;;
    fetch)         cmd_fetch ;;
    *) die "internal: $cmd is not a locked command" ;;
  esac
}

main() {
  local cmd=${1:-status}
  case $cmd in
    build|activate|bolt|bolt-tolerant|rebuild|rebuild-cpu|fetch) need_root; run_locked "$@" ;;
    refresh)    cmd_refresh ;;
    check)      cmd_check ;;
    versions)   resolve_all ;;
    layout)     cmd_layout ;;
    pre)        cmd_pre ;;
    status)     cmd_status ;;
    unit-text)  unit_text ;;
    apt-hook)   cmd_apt_hook ;;
    *) die "usage: $0 build [--cpu-only]|activate|bolt|rebuild|rebuild-cpu|refresh|check|fetch|layout|pre|versions|status|unit-text" ;;
  esac
}

[[ ${VALKEY_BUILD_SOURCE_ONLY:-0} == 1 ]] || main "$@"
