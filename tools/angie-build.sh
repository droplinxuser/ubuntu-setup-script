#!/usr/bin/env bash
# Opt-in compiled Angie (SETUP_ANGIE_BUILD=clang), 1.21.70.
#
# A lean Angie built from upstream sources only: Angie from
# download.angie.software, OpenSSL, PCRE2 (JIT), zlib-ng, and Brotli (google/brotli
# + google/ngx_brotli) from their own releases at the versions in
# angie-build.conf ("latest" by default), compiled with clang from
# apt.llvm.org at -O3 -march=native with Ubuntu's hardening flags, OpenSSL,
# PCRE2 and zlib-ng linked statically, ThinLTO, then rewritten by LLVM BOLT from
# a perf sample of live traffic.  Measured on the test host (1.21.70): cached
# guest pages +2.2 to +12.4 % with BOLT (+3.6 to +6.1 % before it); Angie's
# gzip CPU per page -21 % (zlib-ng).
#
# Lean: only what server-configs-nginx uses: the http core with SSL, HTTP/2,
# HTTP/3 (QUIC), realip, gzip_static, threads (aio threads) and Brotli.  No
# mail, stream, ACME, DAV, mp4/flv, sub, SSI, uwsgi, scgi, grpc, memcached,
# auth_basic, limit_conn, referer,
# userid, autoindex, split_clients, empty_gif, browser or mirror.  A
# configuration that needs one of them (or another load_module) fails the
# candidate's `angie -t` and the package stays.
#
# The binary has its own prefix (/usr/local/lib/setup-angie): load_module's
# relative "modules/..." paths resolve against the prefix and find this
# build's Brotli modules, while include and certificate paths resolve against
# the configuration file's directory, so /etc/angie/angie.conf is read
# unchanged.  Only the binary that systemd starts changes, through a drop-in:
#   /etc/systemd/system/angie.service.d/zz-setup-build.conf
#
# Safety: the package binary stays at /usr/sbin/angie.  The APT hook goes
# back to it when the package becomes newer than the build and rebuilds in
# the background (setup-angie-build.service); a daily timer rebuilds when a
# component publishes a newer release.  A new build replaces the running one
# only after `angie -t` passed against the live configuration and the sites
# answered.  Switching binaries restarts Angie (well under a second).
#
# Usage (root):
#   angie-build.sh build         build + verify + activate (no BOLT)
#   angie-build.sh bolt [S]      sample S seconds (default 60) of traffic, BOLT
#   angie-build.sh rebuild       build, wait for traffic, bolt (unit)
#   angie-build.sh check         0 when current, 10 when a rebuild is due
#   angie-build.sh versions      what angie-build.conf resolves to
#   angie-build.sh activate | deactivate | remove | pre | apt-hook | refresh | status
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ROOT=${ANGIE_BUILD_ROOT:-/usr/local/lib/setup-angie}
BUILD=$ROOT/build
SRC_CACHE=${ANGIE_BUILD_CACHE:-/var/cache/setup-angie-build}
UNIT_DIR=${ANGIE_BUILD_UNIT_DIR:-/etc/systemd/system}
CONF=${ANGIE_BUILD_CONF:-$ROOT/angie-build.conf}
TOOL=${ANGIE_BUILD_TOOL_PATH:-$ROOT/angie-build.sh}
PKG_BIN=${ANGIE_BUILD_PKG_BIN:-/usr/sbin/angie}
ANGIE_CONF=${ANGIE_BUILD_ANGIE_CONF:-/etc/angie/angie.conf}
LOG_TAG=setup-angie-build
BOLT_MIN_FUNCS=${ANGIE_BUILD_BOLT_MIN_FUNCS:-150}
BUILD_COMMON=${ANGIE_BUILD_COMMON:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/build-common.sh}
# shellcheck source=tools/build-common.sh
. "$BUILD_COMMON"

BUILD_RECIPE=1
COMPONENTS=(angie llvm openssl pcre2 zlib-ng brotli ngx-brotli)
declare -A VERS=()
# Ubuntu libraries the build must not link (they are compiled in).
STATIC_LIBS_RE='^(libssl|libcrypto|libpcre2-8|libz|libbrotli[a-z]*)\.so'

dropin_path() { printf '%s/angie.service.d/zz-setup-build.conf' "$UNIT_DIR"; }
info_get() { [[ -f $BUILD/build.info ]] && awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$BUILD/build.info"; return 0; }
pkg_version() { "$PKG_BIN" -v 2>&1 | sed -nE 's#.*Angie/([0-9.]+).*#\1#p' | sed -n 1p; }
bin_version() { "$1" -v 2>&1 | sed -nE 's#.*Angie/([0-9.]+).*#\1#p' | sed -n 1p; }

resolve_all() {
  local c v rc=0
  for c in "${COMPONENTS[@]}"; do
    if v=$(resolve "$c"); then printf '%s=%s\n' "$c" "$v"; else printf '%s=?\n' "$c"; rc=1; fi
  done
  return "$rc"
}

# The sites answer through the running Angie: any HTTP status from the
# default server (444 closes without one, so try a vhost name too).
serving() {
  local code
  for _ in $(seq 1 30); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1/ 2>/dev/null || true)
    [[ $code =~ ^[1-5][0-9][0-9]$ ]] && return 0
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1/ 2>/dev/null || true)
    [[ $code =~ ^[1-5][0-9][0-9]$ ]] && return 0
    systemctl is-active -q angie && pgrep -x angie >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

restart_checked() {
  systemctl restart angie.service >/dev/null 2>&1 || return 1
  serving
}

# --------------------------------------------------------------- build
build_deps() { # work jobs flags: Brotli's static libraries for the dynamic modules
  local work=$1 j=$2 f=$3 nb
  nb=$work/ngx_brotli
  fetch_unpack ngx-brotli "${VERS[ngx-brotli]}" "$nb"
  rm -rf "$nb/deps/brotli"; mkdir -p "$nb/deps"
  fetch_unpack brotli "${VERS[brotli]}" "$nb/deps/brotli"
  # ngx_brotli links deps/brotli/out/libbrotli{enc,common}.a into its
  # modules: position-independent, same flags, ThinLTO.
  cmake -S "$nb/deps/brotli" -B "$nb/deps/brotli/out" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBROTLI_DISABLE_TESTS=ON \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_C_FLAGS="$f" >> "$work/build.log" 2>&1
  cmake --build "$nb/deps/brotli/out" -j "$j" --target brotlienc brotlicommon >> "$work/build.log" 2>&1
}

cmd_build() {
  local work src n j line flags ld
  need_root
  [[ -x $PKG_BIN ]] || die "$PKG_BIN missing: install angie first"
  ensure_packages ca-certificates curl git xz-utils bzip2 make cmake perl autoconf automake libtool build-essential
  while IFS='=' read -r line n; do
    [[ $n == "?" ]] && die "cannot resolve the $line version (offline? pin $(conf_key "$line") in $CONF)"
    VERS[$line]=$n
  done < <(resolve_all || true)
  ver_ge "${VERS[angie]}" "$(pkg_version)" || die "ANGIE_VERSION=${VERS[angie]} is older than the package ($(pkg_version))"
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
  flags="-O3 -march=native -mtune=native -pipe -fPIC -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections"
  if [[ $(uname -m) == x86_64 ]]; then flags+=" -fcf-protection=full"; else flags+=" -mbranch-protection=standard"; fi
  # No -pie: the modules link with the same flags (-shared), and clang
  # builds a PIE by default.
  ld="-fuse-ld=lld -flto=thin -Wl,--emit-relocs -Wl,-z,relro,-z,now -Wl,--gc-sections"
  j=$(nproc)
  mkdir -p "$SRC_CACHE/src"; chmod 700 "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/build.XXXXXX")
  WORK_DIR=$work
  [[ ${ANGIE_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "building Angie ${VERS[angie]} with clang $n (log: $work/build.log)"
  src=$work/angie
  fetch_unpack angie "${VERS[angie]}" "$src"
  fetch_unpack openssl "${VERS[openssl]}" "$work/openssl"
  fetch_unpack pcre2 "${VERS[pcre2]}" "$work/pcre2"
  # zlib-ng with zlib's API (1.21.70: Angie's gzip CPU per XenForo page -21 %
  # against the package, -19 % against zlib 1.4), built first and linked in
  # through -I/-L like a system zlib.
  fetch_unpack zlib-ng "${VERS[zlib-ng]}" "$work/zlib-ng"
  ( cd "$work/zlib-ng" && CC=$CC CFLAGS="$flags -flto=thin" ./configure --static --zlib-compat \
      && make -j"$j" libz.a ) >> "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; die "zlib-ng failed to build"; }
  build_deps "$work" "$j" "$flags -flto=thin" || { tail -n 30 "$work/build.log" >&2; die "Brotli failed to build"; }
  if [[ ! -x $src/configure ]]; then   # a Git snapshot keeps it in auto/
    [[ -x $src/auto/configure ]] || die "Angie ${VERS[angie]}: no configure script in the source"
    cp "$src/auto/configure" "$src/configure"
  fi
  (
    cd "$src"
    # Paths as the package's, except the prefix (see the header).
    # shellcheck disable=SC2086
    ./configure \
      --prefix="$ROOT" --conf-path="$ANGIE_CONF" --sbin-path="$BUILD/angie" --modules-path="$ROOT/modules" \
      --error-log-path=/var/log/angie/error.log --http-log-path=/var/log/angie/access.log \
      --lock-path=/run/angie.lock --pid-path=/run/angie.pid \
      --http-client-body-temp-path=/var/cache/angie/client_temp --http-fastcgi-temp-path=/var/cache/angie/fastcgi_temp \
      --http-proxy-temp-path=/var/cache/angie/proxy_temp --http-scgi-temp-path=/var/cache/angie/scgi_temp \
      --http-uwsgi-temp-path=/var/cache/angie/uwsgi_temp --user=angie --group=angie \
      --with-cc="$CC" --with-cc-opt="$flags -flto=thin -I$work/zlib-ng" --with-ld-opt="$ld -L$work/zlib-ng" \
      --with-threads --with-file-aio \
      --with-http_ssl_module --with-http_v2_module --with-http_v3_module \
      --with-http_realip_module --with-http_gzip_static_module \
      --with-openssl="$work/openssl" \
      --with-openssl-opt="no-shared no-tests no-docs no-apps no-legacy no-module enable-ec_nistp_64_gcc_128 $OPENSSL_TRIM $flags" \
      --with-pcre="$work/pcre2" --with-pcre-jit --with-pcre-opt="$flags" \
      --add-dynamic-module="$work/ngx_brotli" \
      --without-http_ssi_module --without-http_userid_module --without-http_autoindex_module \
      --without-http_split_clients_module --without-http_memcached_module --without-http_empty_gif_module \
      --without-http_browser_module --without-http_uwsgi_module --without-http_scgi_module \
      --without-http_grpc_module --without-http_mirror_module \
      --without-http_auth_basic_module --without-http_limit_conn_module --without-http_referer_module
    nice -n 10 make -j"$j"
    nice -n 10 make -j"$j" modules
  ) >> "$work/build.log" 2>&1 || { tail -n 40 "$work/build.log" >&2; die "Angie ${VERS[angie]} failed to build"; }
  verify_binary "$src/objs/angie" "$src/objs"
  install -d -m 755 "$BUILD" "$ROOT/modules"
  install -m 755 "$src/objs/angie" "$BUILD/angie.lto"
  install_stripped "$BUILD/angie.lto" "$BUILD/angie.new"; mv -f "$BUILD/angie.new" "$BUILD/angie"
  install -m 644 "$src"/objs/ngx_http_brotli_*_module.so "$ROOT/modules/"
  {
    printf 'mode=clang\nrecipe=%s\n' "$BUILD_RECIPE"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\n' "$(cpu_model)"
    printf 'built=%s\nbolt=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$BUILD/build.info.new"
  mv -f "$BUILD/build.info.new" "$BUILD/build.info"
  rm -f "$BUILD/angie.fdata"
  activate
  say "Angie ${VERS[angie]} built from source with clang $n and active (BOLT pending: run under traffic)"
}

# The candidate must report a version not older than the package, accept the
# live configuration with this build's modules, and link none of the
# compiled-in libraries from Ubuntu.
verify_binary() { # binary modules-dir
  local cand=$1 mods=$2 needed tmp
  [[ -n $(bin_version "$cand") ]] || die "candidate does not report an Angie version"
  needed=$(readelf -d "$cand" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
  if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
    die "candidate links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')instead of the upstream builds"
  fi
  # `angie -t` with the candidate's modules where load_module will find them.
  tmp=$(mktemp -d)
  mkdir -p "$tmp/modules"
  cp "$mods"/ngx_http_brotli_*_module.so "$tmp/modules/" 2>/dev/null || true
  if ! "$cand" -t -q -p "$tmp" -c "$ANGIE_CONF" > "$tmp/t.log" 2>&1; then
    sed -n 1,5p "$tmp/t.log" >&2; rm -rf "$tmp"
    die "candidate rejects $ANGIE_CONF (a module this lean build leaves out?)"
  fi
  rm -rf "$tmp"
}

activate() {
  local d unit exec
  unit=${ANGIE_BUILD_PKG_UNIT:-/usr/lib/systemd/system/angie.service}
  [[ -f $unit ]] || unit=/lib/systemd/system/angie.service
  exec=$(grep -m1 "^ExecStart=$PKG_BIN" "$unit" 2>/dev/null || true)
  [[ -n $exec ]] || die "cannot find '$PKG_BIN' in the ExecStart of $unit"
  d=$(dropin_path)
  install -d -m 755 "$(dirname "$d")"
  {
    printf '# Managed by setup.sh (ANGIE_BUILD=clang): start the compiled Angie %s.\n' "$(info_get angie)"
    printf '# angie-build.sh deactivate goes back to the package.\n[Service]\n'
    printf 'ExecStartPre=%s pre\n' "$TOOL"
    printf 'ExecStart=\n%s\n' "${exec/$PKG_BIN/$BUILD/angie}"
  } > "$d.new"
  mv -f "$d.new" "$d"
  systemctl daemon-reload
  restart_checked || { deactivate; die "Angie did not start on the build; back on the package binary"; }
}

deactivate() {
  rm -f "$(dropin_path)"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart angie.service >/dev/null 2>&1 || true
  say "Angie: back on the package's binary"
}

# ExecStartPre: refuse a build made for another CPU (-march=native) and test
# the configuration with the build itself.
cmd_pre() {
  local built now
  built=$(info_get cpu); now=$(cpu_model)
  if [[ -n $built && $built != "$now" ]]; then
    logger -t "$LOG_TAG" "Angie: built for '$built', this CPU is '$now': back to the package binary, rebuilding" || true
    rm -f "$(dropin_path)"
    systemctl daemon-reload || true
    systemd-run --no-block --on-active=2 --unit="setup-angie-fallback-$$" systemctl restart angie.service >/dev/null 2>&1 || true
    systemctl start --no-block setup-angie-build.service >/dev/null 2>&1 || true
    exit 1
  fi
  "$BUILD/angie" -t -q -c "$ANGIE_CONF"
}

cmd_bolt() {
  local secs=${1:-60} n perf work p2b bolt samples base=$BUILD/angie.lto
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
  if [[ $(info_get bolt) == 1 ]]; then
    install_stripped "$base" "$BUILD/angie.new"; mv -f "$BUILD/angie.new" "$BUILD/angie"
    sed -i 's/^bolt=.*/bolt=0/' "$BUILD/build.info"
    restart_checked || die "Angie did not restart on the LTO build"
  fi
  pgrep -f '^angie: worker process' >/dev/null || die "no Angie workers to sample"
  work=$(mktemp -d "$SRC_CACHE/bolt.XXXXXX")
  WORK_DIR=$work
  [[ ${ANGIE_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "Angie: sampling for ${secs}s for BOLT"
  "$perf" record -q -e cycles:u -j any,u -o "$work/perf.data" -a -- sleep "$secs" >/dev/null 2>&1 \
    || die "perf could not record branch samples (no LBR on this CPU or VM?)"
  "$p2b" -p "$work/perf.data" -o "$work/angie.fdata" "$base" > "$work/p2b.log" 2>&1 \
    || { tail -n 5 "$work/p2b.log" >&2; die "perf2bolt failed"; }
  samples=$(awk '/BOLT-INFO: [0-9]+ out of [0-9]+ functions in the binary/ { print $2 }' "$work/p2b.log" | sed -n 1p)
  if [[ ${samples:-0} -lt $BOLT_MIN_FUNCS ]]; then
    say "Angie: ${samples:-0} functions profiled in ${secs}s (need $BOLT_MIN_FUNCS): too little traffic, BOLT skipped"
    return 3
  fi
  "$bolt" "$base" -o "$work/angie.bolt" -data="$work/angie.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -icf -use-gnu-stack > "$work/bolt.log" 2>&1 \
    || { tail -n 5 "$work/bolt.log" >&2; die "llvm-bolt failed"; }
  verify_binary "$work/angie.bolt" "$ROOT/modules"
  install -m 600 "$work/angie.fdata" "$BUILD/angie.fdata"
  install_stripped "$work/angie.bolt" "$BUILD/angie.new"; mv -f "$BUILD/angie.new" "$BUILD/angie"
  sed -i 's/^bolt=.*/bolt=1/' "$BUILD/build.info"
  if ! restart_checked; then
    install_stripped "$base" "$BUILD/angie.new"; mv -f "$BUILD/angie.new" "$BUILD/angie"
    sed -i 's/^bolt=.*/bolt=0/' "$BUILD/build.info"
    restart_checked || true
    die "Angie did not restart on the BOLT build; back on the LTO build"
  fi
  say "Angie: BOLT applied from ${samples} profiled functions"
}

cmd_rebuild() { # unit: build, let traffic warm up, then BOLT
  cmd_build
  sleep "${ANGIE_BUILD_BOLT_DELAY:-300}"
  cmd_bolt 60 || true
}

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

# After a package change: the package is newer than the build (a security
# update), or the package is gone.
cmd_apt_hook() {
  local d pv bv
  d=$(dropin_path)
  [[ -f $d ]] || return 0
  if [[ ! -x $PKG_BIN ]]; then
    rm -f "$d"; rm -rf "${BUILD:?}"; systemctl daemon-reload || true; return 0
  fi
  pv=$(pkg_version); bv=$(info_get angie)
  if [[ -n $pv && -n $bv ]] && ! ver_ge "$bv" "$pv"; then
    say "Angie: package $pv is newer than the build $bv: back on the package binary, rebuilding"
    deactivate
    systemctl start --no-block setup-angie-build.service >/dev/null 2>&1 || true
  fi
}

cmd_refresh() {
  local rc=0
  [[ -f $(dropin_path) ]] || return 0
  cmd_check >/dev/null || rc=$?
  if [[ $rc == 10 ]]; then
    systemctl start --no-block setup-angie-build.service >/dev/null 2>&1 || true
  fi
}

cmd_status() {
  if [[ -f $BUILD/build.info ]]; then
    printf 'Angie: build %s (clang %s, recipe %s), bolt=%s, active=%s, package %s\n' \
      "$(info_get angie)" "$(info_get llvm)" "$(info_get recipe)" "$(info_get bolt)" \
      "$([[ -f $(dropin_path) ]] && echo yes || echo no)" "$(pkg_version)"
  else
    printf 'Angie: no build, package %s\n' "$(pkg_version)"
  fi
}

cmd_remove() {
  [[ -f $(dropin_path) ]] && deactivate
  rm -rf "${BUILD:?}" "${ROOT:?}/modules"
}

main() {
  local cmd=${1:-status}
  case $cmd in
    build)      cmd_build ;;
    bolt)       cmd_bolt "${2:-60}" ;;
    rebuild)    cmd_rebuild ;;
    check)      cmd_check ;;
    versions)   resolve_all ;;
    activate)   need_root; [[ -x $BUILD/angie ]] || die "no build"; activate ;;
    deactivate) need_root; deactivate ;;
    remove)     need_root; cmd_remove ;;
    pre)        cmd_pre ;;
    apt-hook)   cmd_apt_hook ;;
    refresh)    cmd_refresh ;;
    status)     cmd_status ;;
    *) die "usage: $0 build|bolt [S]|rebuild|check|versions|activate|deactivate|remove|pre|apt-hook|refresh|status" ;;
  esac
}

[[ ${ANGIE_BUILD_SOURCE_ONLY:-0} == 1 ]] || main "$@"
