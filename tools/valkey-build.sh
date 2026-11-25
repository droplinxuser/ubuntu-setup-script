#!/usr/bin/env bash
# Opt-in compiled Valkey (SETUP_VALKEY_BUILD=clang / --source=valkey), 1.21.71.
#
# Valkey from its own GitHub release (the newest one; VALKEY_VERSION in
# valkey-build.conf pins another), compiled with clang from apt.llvm.org at
# -O3 -march=native with Ubuntu's hardening flags and link-time optimisation,
# Valkey's bundled jemalloc and Lua linked in, then rewritten by LLVM BOLT
# from a perf sample of a valkey-benchmark run against the build itself.  It
# links only glibc (libc, libm) from Ubuntu: no OpenSSL (the applications
# talk to Valkey over its unix socket, so TLS is left out), no libjemalloc,
# and sd_notify() for the unit's Type=notify is the small static
# implementation tools/build-common.sh writes, not libsystemd.
#
# Version policy.  Valkey here is a cache (save "", appendonly no): the
# newest release is safe to run, and going back to an older package loses
# nothing.  A host whose valkey.conf persists data (save or appendonly)
# stays on the package's X.Y series, because an older server cannot load a
# newer RDB/AOF; the build is never older than the package either way.
#
# Only the binary systemd starts changes, through a drop-in:
#   /etc/systemd/system/valkey-server.service.d/zz-setup-build.conf
# (the packaged unit allows execution only from ExecPaths=, so the drop-in
# adds the build there).  The package's /usr/bin/valkey-server stays.  The
# APT hook goes back to it when the package becomes newer than the build and
# rebuilds in the background; a daily timer rebuilds when Valkey or LLVM
# publishes a newer release.  A new build replaces the running one only after
# it answered PING and a Lua EVAL on a private socket.
#
# Usage (root):
#   valkey-build.sh build         build + verify + activate (no BOLT)
#   valkey-build.sh bolt          profile a valkey-benchmark run, BOLT
#   valkey-build.sh rebuild       build, then bolt (unit)
#   valkey-build.sh check         0 when current, 10 when a rebuild is due
#   valkey-build.sh versions      what valkey-build.conf resolves to
#   valkey-build.sh activate | deactivate | remove | pre | apt-hook | refresh | status
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ROOT=${VALKEY_BUILD_ROOT:-/usr/local/lib/setup-valkey}
BUILD=$ROOT/build
SRC_CACHE=${VALKEY_BUILD_CACHE:-/var/cache/setup-valkey-build}
UNIT_DIR=${VALKEY_BUILD_UNIT_DIR:-/etc/systemd/system}
CONF=${VALKEY_BUILD_CONF:-$ROOT/valkey-build.conf}
TOOL=${VALKEY_BUILD_TOOL_PATH:-$ROOT/valkey-build.sh}
PKG_BIN=${VALKEY_BUILD_PKG_BIN:-/usr/bin/valkey-server}
UNIT=${VALKEY_BUILD_SERVICE:-valkey-server}
VALKEY_CONF=${VALKEY_BUILD_VALKEY_CONF:-/etc/valkey/valkey.conf}
SOCK=${VALKEY_BUILD_SOCKET:-/run/valkey/valkey.sock}
LOG_TAG=setup-valkey-build
BOLT_MIN_FUNCS=${VALKEY_BUILD_BOLT_MIN_FUNCS:-100}
BUILD_COMMON=${VALKEY_BUILD_COMMON:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/build-common.sh}
# shellcheck source=tools/build-common.sh
. "$BUILD_COMMON"

BUILD_RECIPE=1
COMPONENTS=(valkey llvm)
declare -A VERS=()
# Ubuntu libraries the build must not link.
STATIC_LIBS_RE='^(libssl|libcrypto|libjemalloc|libsystemd|liblua[0-9.]*|libatomic|libstdc\+\+)\.so'

dropin_path() { printf '%s/%s.service.d/zz-setup-build.conf' "$UNIT_DIR" "$UNIT"; }
info_get() { [[ -f $BUILD/build.info ]] && awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$BUILD/build.info"; return 0; }
bin_version() { "$1" --version 2>/dev/null | sed -nE 's/.* v=([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | sed -n 1p; }
pkg_version() { bin_version "$PKG_BIN"; }
cli() { local c; c=$(command -v valkey-cli || command -v redis-cli || true); [[ -n $c ]] || return 1; "$c" "$@"; }

# True when valkey.conf keeps data across restarts (RDB snapshots or AOF).
persists() {
  local save aof
  [[ -f $VALKEY_CONF ]] || return 1
  save=$(awk '$1 == "save" { $1 = ""; v = $0 } END { gsub(/^ +|"/, "", v); print v }' "$VALKEY_CONF")
  aof=$(awk '$1 == "appendonly" { v = $2 } END { print v }' "$VALKEY_CONF")
  [[ -n $save || ${aof,,} == yes ]]
}

# The series a pinned-to-package build must stay on ("" = any).
series() {
  local pv
  persists || return 0
  pv=$(pkg_version)
  [[ -n $pv ]] && printf '%s' "${pv%.*}"
}

resolve_all() {
  local c v rc=0 x
  x=$(series)
  for c in "${COMPONENTS[@]}"; do
    if [[ $c == valkey ]]; then v=$(resolve valkey "$x") || v=""
    else v=$(resolve "$c") || v=""
    fi
    if [[ -n $v ]]; then printf '%s=%s\n' "$c" "$v"; else printf '%s=?\n' "$c"; rc=1; fi
  done
  return "$rc"
}

answers() {
  local _
  for _ in $(seq 1 50); do
    [[ $(cli -s "$SOCK" ping 2>/dev/null) == PONG ]] && return 0
    sleep 0.2
  done
  return 1
}

restart_checked() {
  systemctl restart "$UNIT.service" >/dev/null 2>&1 || return 1
  answers
}

# --------------------------------------------------------------- build
cmd_build() {
  local work src n j line flags ld x
  need_root
  [[ -x $PKG_BIN ]] || die "$PKG_BIN missing: install valkey-server first"
  ensure_packages ca-certificates curl git make pkg-config build-essential
  while IFS='=' read -r line n; do
    [[ $n == "?" ]] && die "cannot resolve the $line version (offline? pin $(conf_key "$line") in $CONF)"
    VERS[$line]=$n
  done < <(resolve_all || true)
  ver_ge "${VERS[valkey]}" "$(pkg_version)" || die "VALKEY_VERSION=${VERS[valkey]} is older than the package ($(pkg_version))"
  x=$(series)
  if [[ -n $x && ${VERS[valkey]%.*} != "$x" ]]; then
    die "valkey.conf persists data (save/appendonly): VALKEY_VERSION must stay on the package's $x series, not ${VERS[valkey]}"
  fi
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
  flags="-march=native -mtune=native -pipe -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 ${VALKEY_BUILD_EXTRA_CFLAGS:-}"
  if [[ $(uname -m) == x86_64 ]]; then flags+=" -fcf-protection=full"; else flags+=" -mbranch-protection=standard"; fi
  ld="-fuse-ld=lld -flto -Wl,--emit-relocs -Wl,-z,relro,-z,now ${VALKEY_BUILD_EXTRA_LDFLAGS:-}"
  j=$(nproc)
  mkdir -p "$SRC_CACHE/src"; chmod 700 "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/build.XXXXXX")
  WORK_DIR=$work
  [[ ${VALKEY_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "building Valkey ${VERS[valkey]} with clang $n (log: $work/build.log)"
  sdnotify_shim "$work/deps" "-O3 $flags -flto"
  src=$work/valkey
  fetch_unpack valkey "${VERS[valkey]}" "$src"
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
      nice -n 10 make -j"$j" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
      OPT="${VALKEY_BUILD_OPT:--O3 -flto}" \
      BUILD_TLS=no USE_SYSTEMD=yes LIBSYSTEMD_LIBS=-lsystemd MALLOC=jemalloc ) >> "$work/build.log" 2>&1 \
    || { tail -n 40 "$work/build.log" >&2; die "Valkey ${VERS[valkey]} failed to build"; }
  verify_binary "$src/src/valkey-server"
  install -d -m 755 "$BUILD"
  install -m 755 "$src/src/valkey-server" "$BUILD/valkey-server.lto"
  install_stripped "$BUILD/valkey-server.lto" "$BUILD/valkey-server.new"; mv -f "$BUILD/valkey-server.new" "$BUILD/valkey-server"
  install_stripped "$src/src/valkey-benchmark" "$BUILD/valkey-benchmark"
  {
    printf 'mode=clang\nrecipe=%s\n' "$BUILD_RECIPE"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\n' "$(cpu_model)"
    printf 'built=%s\nbolt=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$BUILD/build.info.new"
  mv -f "$BUILD/build.info.new" "$BUILD/build.info"
  rm -f "$BUILD/valkey-server.fdata"
  activate
  say "Valkey ${VERS[valkey]} built from source with clang $n and active (BOLT pending)"
}

# The candidate reports a version not older than the package, links none of
# Ubuntu's libraries but glibc, and serves PING and a Lua EVAL (the XenForo
# Redis add-ons use scripts) on a private socket.
verify_binary() { # binary
  local cand=$1 needed tmp pid ok=0
  [[ -n $(bin_version "$cand") ]] || die "candidate does not report a Valkey version"
  ver_ge "$(bin_version "$cand")" "$(pkg_version)" || die "candidate $(bin_version "$cand") is older than the package"
  needed=$(readelf -d "$cand" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
  if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
    die "candidate links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')"
  fi
  tmp=$(mktemp -d)
  "$cand" --port 0 --unixsocket "$tmp/s" --save "" --appendonly no --dir "$tmp" --daemonize no \
    --logfile "$tmp/log" > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    [[ $(cli -s "$tmp/s" ping 2>/dev/null) == PONG ]] && { ok=1; break; }
    sleep 0.1
  done
  if (( ok )) && [[ $(cli -s "$tmp/s" eval "return redis.call('set', KEYS[1], ARGV[1])" 1 k v 2>/dev/null) == OK ]] \
     && [[ $(cli -s "$tmp/s" get k 2>/dev/null) == v ]]; then ok=2; fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -rf "$tmp"
  (( ok == 2 )) || die "candidate did not answer PING / EVAL on a private socket"
}

activate() {
  local d unit exec
  unit=${VALKEY_BUILD_PKG_UNIT:-/usr/lib/systemd/system/$UNIT.service}
  [[ -f $unit ]] || unit=/lib/systemd/system/$UNIT.service
  exec=$(grep -m1 "^ExecStart=$PKG_BIN" "$unit" 2>/dev/null || true)
  [[ -n $exec ]] || die "cannot find '$PKG_BIN' in the ExecStart of $unit"
  d=$(dropin_path)
  install -d -m 755 "$(dirname "$d")"
  {
    printf '# Managed by setup.sh (VALKEY_BUILD=clang): start the compiled Valkey %s.\n' "$(info_get valkey)"
    printf '# valkey-build.sh deactivate goes back to the package.\n[Service]\n'
    printf 'ExecPaths=%s %s\n' "$BUILD/valkey-server" "$TOOL"
    printf 'ExecStartPre=+%s pre\n' "$TOOL"
    printf 'ExecStart=\n%s\n' "${exec/$PKG_BIN/$BUILD/valkey-server}"
  } > "$d.new"
  mv -f "$d.new" "$d"
  systemctl daemon-reload
  restart_checked || { deactivate; die "Valkey did not start on the build; back on the package binary"; }
}

deactivate() {
  rm -f "$(dropin_path)"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart "$UNIT.service" >/dev/null 2>&1 || true
  say "Valkey: back on the package's binary"
}

# ExecStartPre (as root, "+"): refuse a build made for another CPU
# (-march=native) and go back to the package rather than leave Valkey down.
cmd_pre() {
  local built now
  built=$(info_get cpu); now=$(cpu_model)
  [[ -z $built || $built == "$now" ]] && [[ -x $BUILD/valkey-server ]] && return 0
  logger -t "$LOG_TAG" "Valkey: build unusable on this CPU ('$now', built for '$built'): back to the package binary, rebuilding" || true
  rm -f "$(dropin_path)"
  systemctl daemon-reload || true
  systemd-run --no-block --on-active=2 --unit="setup-valkey-fallback-$$" systemctl restart "$UNIT.service" >/dev/null 2>&1 || true
  systemctl start --no-block setup-valkey-build.service >/dev/null 2>&1 || true
  exit 1
}

# BOLT from a valkey-benchmark run against the running build (database 9,
# flushed afterwards): the GET/SET/HSET/MGET mix of the applications' cache
# calls, without depending on live traffic.
cmd_bolt() {
  local n perf work p2b bolt samples base=$BUILD/valkey-server.lto pid bench
  need_root
  [[ -f $base ]] || die "no build to BOLT"
  n=$(info_get llvm)
  perf=$(command -v perf || true)
  if [[ -z $perf ]] || ! "$perf" --version >/dev/null 2>&1; then
    ensure_packages "linux-tools-$(uname -r)" linux-tools-common || die "perf is not installable for kernel $(uname -r)"
    perf=$(command -v perf)
  fi
  llvm_install "$n" "bolt-$n"
  p2b=$LLVM_BIN/perf2bolt; bolt=$LLVM_BIN/llvm-bolt
  [[ -x $p2b && -x $bolt ]] || die "llvm-bolt/perf2bolt $n not found in $LLVM_BIN"
  bench=$BUILD/valkey-benchmark
  [[ -x $bench ]] || bench=$(command -v valkey-benchmark || true)
  [[ -n $bench ]] || die "no valkey-benchmark to drive the profile"
  if [[ $(info_get bolt) == 1 ]]; then
    install_stripped "$base" "$BUILD/valkey-server.new"; mv -f "$BUILD/valkey-server.new" "$BUILD/valkey-server"
    sed -i 's/^bolt=.*/bolt=0/' "$BUILD/build.info"
    restart_checked || die "Valkey did not restart on the LTO build"
  fi
  answers || die "Valkey is not answering on $SOCK"
  pid=$(systemctl show -p MainPID --value "$UNIT.service")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || die "no Valkey process to sample"
  work=$(mktemp -d "$SRC_CACHE/bolt.XXXXXX")
  WORK_DIR=$work
  [[ ${VALKEY_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "Valkey: profiling a valkey-benchmark run for BOLT"
  "$perf" record -q -e cycles:u -j any,u -o "$work/perf.data" -p "$pid" -- \
    "$bench" -s "$SOCK" --dbnum 9 -c 50 -n 400000 -r 100000 -d 256 -q \
      -t get,set,hset,lpush,mset,incr > "$work/bench.log" 2>&1 \
    || { cli -s "$SOCK" -n 9 flushdb >/dev/null 2>&1 || true; die "perf could not record branch samples (no LBR on this CPU or VM?)"; }
  cli -s "$SOCK" -n 9 flushdb >/dev/null 2>&1 || true
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
  verify_binary "$work/valkey.bolt"
  install -m 600 "$work/valkey.fdata" "$BUILD/valkey-server.fdata"
  install_stripped "$work/valkey.bolt" "$BUILD/valkey-server.new"; mv -f "$BUILD/valkey-server.new" "$BUILD/valkey-server"
  sed -i 's/^bolt=.*/bolt=1/' "$BUILD/build.info"
  if ! restart_checked; then
    install_stripped "$base" "$BUILD/valkey-server.new"; mv -f "$BUILD/valkey-server.new" "$BUILD/valkey-server"
    sed -i 's/^bolt=.*/bolt=0/' "$BUILD/build.info"
    restart_checked || true
    die "Valkey did not restart on the BOLT build; back on the LTO build"
  fi
  say "Valkey: BOLT applied from ${samples} profiled functions"
}

cmd_rebuild() { cmd_build; cmd_bolt || true; }

cmd_check() {
  local name want have stale="" rc=0 bcpu
  [[ -f $BUILD/build.info ]] || { echo "no build"; return 10; }
  [[ $(info_get recipe) == "$BUILD_RECIPE" ]] || stale+="recipe $(info_get recipe) -> $BUILD_RECIPE, "
  bcpu=$(info_get cpu)
  [[ -z $bcpu || $bcpu == "$(cpu_model)" ]] || stale+="cpu $bcpu -> $(cpu_model), "
  while IFS='=' read -r name want; do
    if [[ $want == "?" ]]; then rc=2; continue; fi
    have=$(info_get "$name")
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_all || true)
  if [[ -n $stale ]]; then echo "stale: ${stale%, }"; return 10; fi
  echo current; return "$rc"
}

cmd_apt_hook() {
  local d pv bv
  d=$(dropin_path)
  [[ -f $d ]] || return 0
  if [[ ! -x $PKG_BIN ]]; then
    rm -f "$d"; rm -rf "${BUILD:?}"; systemctl daemon-reload || true; return 0
  fi
  pv=$(pkg_version); bv=$(info_get valkey)
  if [[ -n $pv && -n $bv ]] && ! ver_ge "$bv" "$pv"; then
    say "Valkey: package $pv is newer than the build $bv: back on the package binary, rebuilding"
    deactivate
    systemctl start --no-block setup-valkey-build.service >/dev/null 2>&1 || true
  fi
}

cmd_refresh() {
  local rc=0
  [[ -f $(dropin_path) ]] || return 0
  cmd_check >/dev/null || rc=$?
  if [[ $rc == 10 ]]; then
    systemctl start --no-block setup-valkey-build.service >/dev/null 2>&1 || true
  fi
}

cmd_status() {
  if [[ -f $BUILD/build.info ]]; then
    printf 'Valkey: build %s (clang %s, recipe %s), bolt=%s, active=%s, package %s\n' \
      "$(info_get valkey)" "$(info_get llvm)" "$(info_get recipe)" "$(info_get bolt)" \
      "$([[ -f $(dropin_path) ]] && echo yes || echo no)" "$(pkg_version)"
  else
    printf 'Valkey: no build, package %s\n' "$(pkg_version)"
  fi
}

cmd_remove() {
  [[ -f $(dropin_path) ]] && deactivate
  rm -rf "${BUILD:?}"
}

main() {
  local cmd=${1:-status}
  case $cmd in
    build)      cmd_build ;;
    bolt)       cmd_bolt ;;
    rebuild)    cmd_rebuild ;;
    check)      cmd_check ;;
    versions)   resolve_all ;;
    activate)   need_root; [[ -x $BUILD/valkey-server ]] || die "no build"; activate ;;
    deactivate) need_root; deactivate ;;
    remove)     need_root; cmd_remove ;;
    pre)        cmd_pre ;;
    apt-hook)   cmd_apt_hook ;;
    refresh)    cmd_refresh ;;
    status)     cmd_status ;;
    *) die "usage: $0 build|bolt|rebuild|check|versions|activate|deactivate|remove|pre|apt-hook|refresh|status" ;;
  esac
}

[[ ${VALKEY_BUILD_SOURCE_ONLY:-0} == 1 ]] || main "$@"
