#!/usr/bin/env bash
# Opt-in compiled php-fpm (SETUP_PHP_BUILD=clang).
#
# A lean php-fpm for WordPress, XenForo and Chevereto, built from upstream
# sources only: PHP from php.net, clang/lld/BOLT from apt.llvm.org, redis and
# igbinary from PECL, and every library php-fpm links (OpenSSL, PCRE2, zlib-ng,
# libxml2, libsodium, GMP, GNU libiconv, curl, libjpeg-turbo, libpng, libwebp,
# libzip) from the project's own releases, at the versions in php-build.conf
# ("latest" by default).  Everything is compiled -O3 -march=native -fPIE
# (position-independent executable code: no GOT indirection for PHP's own
# globals) with Ubuntu's hardening flags, linked statically with ThinLTO
# across PHP, its extensions, PCRE2, zlib-ng and libxml2, and rewritten by
# LLVM BOLT from a perf sample of live traffic.  Only glibc (libc, libm) comes
# from Ubuntu: sd_notify() for the unit is a small static implementation.
#
# Lean: the FPM SAPI only (no CLI, CGI or phpdbg) and only what the three
# applications use: ctype curl dom exif fileinfo filter gd(jpeg png webp)
# gmp iconv libxml mbstring(no mbregex) mysqli/mysqlnd openssl pdo/pdo_mysql
# session simplexml sodium xml xmlwriter zip zlib, redis/igbinary
# for the Redis caches, and the always-built core.  No intl/ICU (XenForo ships
# Symfony's intl polyfills, WordPress checks function_exists, Chevereto does
# not use it) and no ImageMagick (all three use GD).  No shared extensions
# are loaded: conf.d is mirrored into /run/setup-php-build/X.Y with its
# extension= lines commented out, so php.ini, OPcache/JIT settings and pools
# stay the package's.  The package's own CLI (`php`) is untouched.
#
# Only the binary that systemd starts changes, through a drop-in:
#   /etc/systemd/system/php<X.Y>-fpm.service.d/zz-setup-build.conf
#
# Why this build and not 1.21.68's two (measured 1.21.69, LTO, before BOLT):
# the from-source build ran 9 % fewer instructions per XenForo page than
# clang + Sury's extensions, yet was 1-2 % slower: ICU (intl) made the binary
# 102 MB and cost 4.5x the data-TLB misses.  Without ICU (60 MB) the misses
# match the package's and this build is the fastest of the three.  -fPIC vs
# -fPIE for the PHP core made no measurable difference.
#
# Safety: the package's binary stays at /usr/sbin/php-fpm<X.Y>.  The APT hook
# switches a version back to it when the package becomes newer than the build
# (a security update) and rebuilds in the background
# (setup-php-fpm-build@<X.Y>.service).  A daily timer rebuilds when php.net,
# PECL, LLVM or a library publish a newer release.  A new build replaces the
# running one only after it passed every check.
#
# Usage (root):
#   php-fpm-build.sh build   X.Y      build + verify + activate (no BOLT)
#   php-fpm-build.sh bolt    X.Y [S]  sample S seconds (default 60) of live
#                                     traffic, BOLT, verify, activate
#   php-fpm-build.sh rebuild X.Y      build, activate, wait, then bolt (unit)
#   php-fpm-build.sh check   X.Y      exit 0 when the build has every version
#                                     php-build.conf asks for, 10 when not
#   php-fpm-build.sh versions X.Y     the versions php-build.conf resolves to
#   php-fpm-build.sh activate X.Y     start the existing build again
#   php-fpm-build.sh deactivate X.Y   back to the package binary
#   php-fpm-build.sh remove  X.Y      deactivate and delete the build
#   php-fpm-build.sh conf    X.Y      mirror conf.d for the build (ExecStartPre)
#   php-fpm-build.sh apt-hook         revert/rebuild after package changes
#   php-fpm-build.sh refresh          rebuild versions with a newer release
#   php-fpm-build.sh status [X.Y]     one line per version
#
# Installed by setup.sh as /usr/local/lib/setup-php/php-fpm-build.sh.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
SRC_CACHE=${PHP_BUILD_CACHE:-/var/cache/setup-php-build}
UNIT_DIR=${PHP_BUILD_UNIT_DIR:-/etc/systemd/system}
PHP_ETC=${PHP_BUILD_ETC:-/etc/php}
RUN_DIR=${PHP_BUILD_RUN_DIR:-/run/setup-php-build}
CONF=${PHP_BUILD_CONF:-$ROOT/php-build.conf}
TOOL=${PHP_BUILD_TOOL_PATH:-$ROOT/php-fpm-build.sh}
SBIN=${PHP_BUILD_SBIN:-/usr/sbin}
LOG_TAG=setup-php-fpm-build
# Shared download, version and toolchain code (also used by nginx-build.sh).
BUILD_COMMON=${PHP_BUILD_COMMON:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/build-common.sh}
# shellcheck source=tools/build-common.sh
. "$BUILD_COMMON"
# Functions of php-fpm that must carry samples before BOLT is worth it: an
# idle site gives a profile of the master loop only.  Full XenForo/WordPress
# load on the test host profiled ~2,300.
BOLT_MIN_FUNCS=${PHP_BUILD_BOLT_MIN_FUNCS:-300}
# zlib-ng with zlib's API: +7 % on uncached Chevereto pages, where PHP gzips
# the page itself (1.21.70).  PHP_BUILD_ZLIB=zlib builds zlib instead.
ZLIB_IMPL=${PHP_BUILD_ZLIB:-zlib-ng}

# Bump LIB_RECIPE when a library's configure options change: it is part of
# the library cache key.
LIB_RECIPE=5
# Bump BUILD_RECIPE when the php-fpm build itself changes (flags, module set):
# `check` reports an older recipe as stale, so --optimize and the daily timer
# rebuild.  1: 1.21.68 (-fPIC, intl).  2: 1.21.69 (-fPIE, no intl/ICU).
# 3: 1.21.70 (Ubuntu hardening flags, GNU libiconv, no xmlreader, stripped).
# 4: 1.21.71 (BOLT keeps a non-executable stack: -use-gnu-stack dropped).
BUILD_RECIPE=4
# Build order matters: curl needs OpenSSL and zlib, libpng and libzip zlib.
LIBS=("$ZLIB_IMPL" openssl pcre2 libxml2 libsodium gmp libiconv curl libjpeg-turbo libpng libwebp libzip)
COMPONENTS=(php llvm redis igbinary "${LIBS[@]}")
# `-m` lines the build must show: what XenForo 2.3, WordPress and Chevereto
# 4.5 require (setup.sh's php_upgrade_app_requirements, Chevereto's
# integrity check, WordPress Site Health) and nothing else.  Images go
# through GD in all three, so no imagick/ImageMagick; no intl (see header).
APP_MODULES=(Core ctype curl date dom exif fileinfo filter gd gmp hash iconv igbinary
  json libxml mbstring mysqli mysqlnd openssl pcre PDO pdo_mysql random Reflection redis session
  SimpleXML sodium SPL standard xml xmlwriter zip zlib "Zend OPcache")
# Always part of PHP 8.5 (core, not configurable) or the SAPI itself: allowed
# in `-m`, not required.
CORE_MODULES=(cgi-fcgi lexbor uri)
# Libraries php-fpm must NOT take from Ubuntu (they are linked statically).
STATIC_LIBS_RE='^(libssl|libcrypto|libxml2|libpcre2-8|libz|libicu[a-z0-9]*|libcurl|libsodium|libgmp|libjpeg|libpng16|libwebp|libsharpyuv|libzip|libonig|libsystemd|libiconv)\.so'


valid_ver() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+$ ]]; }
pkg_bin() { printf '%s/php-fpm%s' "$SBIN" "$1"; }
dropin_path() { printf '%s/php%s-fpm.service.d/zz-setup-build.conf' "$UNIT_DIR" "$1"; }
build_dir() { printf '%s/%s' "$ROOT" "$1"; }

# "8.5.13" from a php-fpm binary.  Reads to EOF: an early exit kills php with
# EPIPE under pipefail.
bin_version() {
  local v
  v=$("$1" -n -v 2>/dev/null | awk 'NR == 1 { print $2 }')
  v=${v%%-*}
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
}

# A compiled-in INI default of a binary (no php.ini), e.g. include_path.
bin_ini_default() {
  "$1" -n -i 2>/dev/null | awk -F' => ' -v k="$2" '$1 == k && !f { print $2; f = 1 }'
}

# An information line of a binary with its live configuration
# (e.g. MYSQLI_SOCKET, which the package sets at configure time).
bin_info() {
  "$1" -i 2>/dev/null | awk -F' => ' -v k="$2" 'NF == 2 && $1 == k && !f { print $2; f = 1 }'
}

# INI directives ("name<TAB>local => master") of a binary with its live
# configuration.
bin_directives() {
  "$1" -i 2>/dev/null \
    | awk -F' => ' 'NF == 3 && $1 != "Directive" { sub(/[[:space:]]+$/, "", $3); print $1 "\t" $2 " => " $3 }' \
    | sort -t "$(printf '\t')" -k1,1 -u
}

active_bin() { # the binary the unit starts
  local d
  d=$(dropin_path "$1")
  if [[ -f $d ]]; then
    awk -F'=' '/^ExecStart=./ { split($2, a, " "); print a[1]; exit }' "$d"
  else
    pkg_bin "$1"
  fi
}

info_get() { # version key
  local f
  f="$(build_dir "$1")/build.info"
  [[ -f $f ]] && awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$f"
  return 0
}


# ---------------------------------------------------------------- build
# Static libraries in DEPS, compiled from upstream with the toolchain in the
# environment.  HOT (ThinLTO) for the libraries XenForo page views run.
build_libs() { # deps work jobs
  local deps=$1 work=$2 j=$3 name v src arch hot cold ld_hot ld_cold
  hot="$BASE_FLAGS -flto=thin"; cold=$BASE_FLAGS
  ld_hot="-fuse-ld=lld -flto=thin"; ld_cold="-fuse-ld=lld"
  arch=linux-x86_64; [[ $(uname -m) == aarch64 ]] && arch=linux-aarch64
  for name in "${LIBS[@]}"; do
    v=${VERS[$name]}
    src=$work/src-$name
    rm -rf "$src"; fetch_unpack "$name" "$v" "$src"
    say "building $name $v"
    (
      cd "$src"
      cmake_lib() {
        cmake -S . -B _b -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$deps" \
          -DCMAKE_POSITION_INDEPENDENT_CODE=OFF -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
          -DCMAKE_C_FLAGS="$cold" -DCMAKE_EXE_LINKER_FLAGS="$ld_cold" "$@"
        cmake --build _b -j "$j"
        cmake --install _b
      }
      case $name in
        zlib)
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --static
          make -j"$j" && make install ;;
        zlib-ng)
          # zlib's API and names (libz.a, zlib.h), so PHP, curl, libpng and
          # libzip link it unchanged.
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --static --zlib-compat
          make -j"$j" && make install ;;
        libiconv)
          # PHP's iconv: GNU libiconv from source, not glibc's iconv and its
          # gconv modules.
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --disable-shared --enable-static \
            --disable-nls
          make -j"$j" && make install ;;
        openssl)
          # openssldir is Ubuntu's: its openssl.cnf and the system CA store.
          # $cold is split on purpose: Configure takes compiler flags as words.
          # shellcheck disable=SC2086
          ./Configure "$arch" --prefix="$deps" --libdir=lib --openssldir=/usr/lib/ssl \
            no-shared no-tests no-docs no-apps no-legacy no-module enable-ec_nistp_64_gcc_128 \
            $OPENSSL_TRIM $cold
          make -j"$j" build_libs && make install_dev ;;
        pcre2)
          autotools_prepare
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --disable-shared --enable-static \
            --enable-jit --disable-pcre2grep-libz --disable-pcre2grep-libbz2
          make -j"$j" && make install ;;
        libxml2)
          autotools_prepare
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --disable-shared --enable-static \
            --without-python --without-zlib --without-lzma --without-icu \
            --without-readline --without-history --without-http --without-ftp --without-debug
          make -j"$j" && make install ;;
        libsodium)
          autotools_prepare
          CFLAGS=$cold LDFLAGS=$ld_cold ./configure --prefix="$deps" --disable-shared --enable-static
          make -j"$j" && make install ;;
        gmp)
          # Portable C: GMP's x86-64 assembly keeps jump tables of code
          # offsets in data, which BOLT cannot move (88 relocations with
          # LLVM 23).  GMP only serves push-notification crypto.
          CFLAGS=$cold LDFLAGS=$ld_cold ./configure --prefix="$deps" --disable-shared --enable-static --disable-assembly
          make -j"$j" && make install ;;
        curl)
          autotools_prepare
          # HTTP(S) only: XenForo's outbound requests (Guzzle).
          CFLAGS=$cold LDFLAGS=$ld_cold PKG_CONFIG="pkg-config --static" ./configure --prefix="$deps" \
            --disable-shared --enable-static --with-openssl="$deps" --with-zlib="$deps" \
            --without-libpsl --without-brotli --without-zstd --without-nghttp2 --without-libidn2 \
            --without-librtmp --without-libssh2 --disable-ldap --disable-ldaps --disable-rtsp \
            --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
            --disable-smtp --disable-gopher --disable-mqtt --disable-smb --disable-ftp --disable-file \
            --disable-manual --disable-docs \
            --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --with-ca-path=/etc/ssl/certs
          make -j"$j" && make install ;;
        libjpeg-turbo)
          cmake_lib -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF ;;
        libpng)
          cmake_lib -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DZLIB_ROOT="$deps" ;;
        libwebp)
          cmake_lib -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
            -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
            -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF ;;
        libzip)
          cmake_lib -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_OPENSSL=OFF \
            -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF \
            -DENABLE_WINDOWS_CRYPTO=OFF -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF \
            -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DZLIB_ROOT="$deps" ;;
      esac
    ) >> "$work/libs.log" 2>&1 || { tail -n 40 "$work/libs.log" >&2; die "$name $v failed to build"; }
    rm -rf "$src"
  done
}

cmd_build() {
  local ver=$1 pkg pkg_version ext_dir inc_path sess_path sock work src dir key deps n j line
  local -A VERS=()
  need_root
  pkg=$(pkg_bin "$ver")
  [[ -x $pkg ]] || die "$pkg missing: install php$ver-fpm first"
  [[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die "unsupported architecture $(uname -m)"
  pkg_version=$(bin_version "$pkg") || die "cannot read the PHP version of $pkg"
  ext_dir=$(bin_ini_default "$pkg" extension_dir)
  inc_path=$(bin_ini_default "$pkg" include_path)
  sess_path=$(bin_ini_default "$pkg" session.save_path)
  sock=$(bin_info "$pkg" MYSQLI_SOCKET)
  [[ -n $sock && $sock != "no value" ]] || sock=/run/mysqld/mysqld.sock
  # automake/libtool/bison/re2c: a Git tag snapshot (the fallback source)
  # needs its configure script and parsers generated.
  ensure_packages ca-certificates curl git xz-utils bzip2 make cmake nasm m4 perl \
    pkg-config autoconf automake libtool bison re2c build-essential
  while IFS='=' read -r key line; do
    [[ $line == "?" ]] && die "cannot resolve the $key version (offline? pin $(conf_key "$key") in $CONF)"
    VERS[$key]=$line
  done < <(resolve_all "$ver" || true)
  [[ ${VERS[php]%.*} == "$ver" ]] || die "PHP_VERSION=${VERS[php]} is not a PHP $ver release"
  ver_ge "${VERS[php]}" "$pkg_version" || die "PHP_VERSION=${VERS[php]} is older than the package ($pkg_version)"
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
  # -fPIE, not -fPIC: everything ends up in one executable.  -fPIC (1.21.68)
  # reached PHP's executor globals through the GOT on every access.
  BASE_FLAGS="-O3 -march=native -mtune=native -pipe -fPIE -fno-semantic-interposition"
  # Ubuntu's own hardening, always (its gcc enables these by default;
  # upstream clang does not, and 1.21.68/1.21.69 ran without them): stack
  # protector, stack-clash probes, FORTIFY_SOURCE=3, CET/BTI landing pads,
  # full RELRO.  Measured cost 0.5-2 % before BOLT (1.21.70).
  BASE_FLAGS+=" -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
  if [[ $(uname -m) == x86_64 ]]; then BASE_FLAGS+=" -fcf-protection=full"; else BASE_FLAGS+=" -mbranch-protection=standard"; fi
  HARD_LD="-Wl,-z,relro,-z,now"
  # Unused code and data dropped, identical functions folded (safe ICF).
  BASE_FLAGS+=" -ffunction-sections -fdata-sections"
  GC_LD="-Wl,--gc-sections -Wl,--icf=safe"
  j=$(nproc)
  mkdir -p "$SRC_CACHE/src"; chmod 700 "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/build-$ver.XXXXXX")
  WORK_DIR=$work
  # PHP_BUILD_KEEP_WORK=1 keeps the work directory (sources, logs, candidate) for debugging.
  [[ ${PHP_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT

  # Libraries: cached per (toolchain, flags, versions); a PHP-only update
  # reuses them.
  key=$( { printf 'recipe=%s\nllvm=%s\nflags=%s\n' "$LIB_RECIPE" "$n" "$BASE_FLAGS"; for line in "${LIBS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done; } | sha256sum | cut -c1-16)
  deps=$SRC_CACHE/deps-$key
  if [[ ! -f $deps/.done ]]; then
    rm -rf "$deps"; mkdir -p "$deps"
    say "building libraries with clang $n (log: $work/libs.log)"
    build_libs "$deps" "$work" "$j"
    touch "$deps/.done"
  fi
  # pkg-config searches $deps only.
  # glibc comes from Ubuntu; libsystemd is replaced by the sd_notify shim.
  sdnotify_shim "$deps" "$BASE_FLAGS -flto=thin"

  src=$work/php
  fetch_unpack php "${VERS[php]}" "$src"
  fetch_unpack igbinary "${VERS[igbinary]}" "$src/ext/igbinary"
  fetch_unpack redis "${VERS[redis]}" "$src/ext/redis"
  # PHP 8.5 dropped ext/standard/php_smart_string.h, which only ever
  # included Zend's header; igbinary 3.2.16 still includes it (Sury patches
  # the same way).  Recreate the wrapper when the release lacks it.
  local h
  for h in php_smart_string php_smart_string_public; do
    [[ -f $src/ext/standard/$h.h ]] && continue
    printf '/* setup.sh php-fpm-build: compatibility wrapper (removed in PHP 8.5) */\n#include "zend_smart_string.h"\n' \
      > "$src/ext/standard/$h.h"
  done
  cd "$src"
  say "building php-fpm ${VERS[php]} for PHP $ver with clang $n (log: $work/build.log)"
  ./buildconf --force > "$work/build.log" 2>&1 || { tail -n 20 "$work/build.log" >&2; die "buildconf failed"; }
  # The lean set for XenForo, WordPress and Chevereto (see the header).
  # Libraries come from $deps only.
  CFLAGS="$BASE_FLAGS -flto=thin ${PHP_BUILD_EXTRA_CFLAGS:-}" CXXFLAGS="$BASE_FLAGS -flto=thin ${PHP_BUILD_EXTRA_CFLAGS:-}" \
  LDFLAGS="-flto=thin -fuse-ld=lld -Wl,--emit-relocs $HARD_LD $GC_LD ${PHP_BUILD_EXTRA_LDFLAGS:-} -L$deps/lib" \
  CPPFLAGS="-I$deps/include" \
  PKG_CONFIG="pkg-config --static" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" \
  PKG_CONFIG_PATH="" PROG_SENDMAIL=/usr/sbin/sendmail EXTENSION_DIR=$ext_dir \
  ./configure \
    --prefix=/usr \
    --with-config-file-path="/etc/php/$ver/fpm" \
    --with-config-file-scan-dir="$RUN_DIR/$ver" \
    --disable-all --disable-cli --disable-cgi --disable-phpdbg --without-pear --disable-rpath \
    --without-valgrind --enable-session \
    --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd \
    --with-external-pcre --with-openssl --with-zlib --with-libxml --with-sodium \
    --enable-ctype --with-curl --enable-dom --enable-exif --enable-fileinfo --enable-filter \
    --enable-gd --with-jpeg --with-webp --with-gmp="$deps" --with-iconv="$deps" \
    --enable-mbstring --disable-mbregex --with-mysqli --enable-mysqlnd --with-mysql-sock="$sock" \
    --enable-simplexml --enable-xml --enable-xmlwriter --with-zip \
    --enable-pdo --with-pdo-mysql=mysqlnd \
    --enable-igbinary --enable-redis --enable-redis-igbinary \
    >> "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; install -m 600 config.log "$SRC_CACHE/config-$ver.log" 2>/dev/null || true; die "configure failed (config.log: $SRC_CACHE/config-$ver.log)"; }
  # Debian patches the compiled-in include_path; take it from the package so
  # the build behaves the same without a php.ini line.
  sed -i -E "s|^#define[[:space:]]+PHP_INCLUDE_PATH[[:space:]].*|#define PHP_INCLUDE_PATH \"${inc_path//|/\\|}\"|" main/build-defs.h
  grep -qF "#define PHP_INCLUDE_PATH \"$inc_path\"" main/build-defs.h \
    || die "could not set PHP_INCLUDE_PATH in main/build-defs.h"
  # Debian's session.save_path default (/var/lib/php/sessions, cleaned by
  # the package's phpsessionclean timer), as the package binary has it.
  if [[ -n $sess_path && $sess_path != "no value" ]]; then
    sed -i -E "s|(PHP_INI_ENTRY\\(\"session\\.save_path\",[[:space:]]*)\"\"|\\1\"${sess_path//|/\\|}\"|" ext/session/session.c
  fi
  nice -n 10 make -j"$j" >> "$work/build.log" 2>&1 \
    || { tail -n 40 "$work/build.log" >&2; die "make failed"; }
  cmd_conf "$ver"
  verify_binary "$ver" sapi/fpm/php-fpm
  dir=$(build_dir "$ver")
  install -d -m 755 "$dir"
  install -m 755 sapi/fpm/php-fpm "$dir/php-fpm.lto.new"
  mv -f "$dir/php-fpm.lto.new" "$dir/php-fpm.lto"
  install_stripped "$dir/php-fpm.lto" "$dir/php-fpm.new"
  mv -f "$dir/php-fpm.new" "$dir/php-fpm"
  {
    printf 'mode=clang\nrecipe=%s\n' "$BUILD_RECIPE"
    printf 'version=%s\n' "${VERS[php]}"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\n' "$(cpu_model)"
    printf 'cflags=%s -flto=thin\n' "$BASE_FLAGS"
    printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bolt=0\n'
  } > "$dir/build.info.new"
  mv -f "$dir/build.info.new" "$dir/build.info"
  rm -f "$dir/php-fpm.fdata"
  activate "$ver"
  # Keep only what this build used.
  find "$SRC_CACHE" -maxdepth 1 -name 'deps-*' ! -name "deps-$key" -exec rm -rf {} + 2>/dev/null || true
  say "PHP $ver: php-fpm ${VERS[php]} built from source with clang $n and active (BOLT pending: run under traffic)"
}

# One compiled mode since 1.21.69 ("clang"; 1.21.68's "lean" builds count as
# clang and are rebuilt because their recipe is older).
build_mode() { printf 'clang'; }

# conf.d of the package with extension= lines commented out: everything
# XenForo needs is compiled in, nothing else is loaded.  Runs before every
# start and reload, so --optimize changes to conf.d apply as usual.
cmd_conf() {
  local ver=$1 out ini tmp built now
  # -march=native targets the CPU the build ran on.  On another CPU model
  # (disk moved, VM migrated to other hardware) it may use instructions this
  # one lacks: start on the package binary instead and rebuild here.
  built=$(info_get "$ver" cpu 2>/dev/null || true)
  now=$(cpu_model)
  if [[ -n $built && $built != "$now" ]]; then
    logger -t "$LOG_TAG" "PHP $ver: built for '$built', this CPU is '$now': back to the package binary, rebuilding" || true
    rm -f "$(dropin_path "$ver")"
    systemctl daemon-reload || true
    systemd-run --no-block --on-active=2 --unit="setup-php-fpm-fallback-$ver-$$" \
      systemctl restart "php$ver-fpm.service" >/dev/null 2>&1 || true
    systemctl start --no-block "setup-php-fpm-build@$ver.service" >/dev/null 2>&1 || true
    exit 1
  fi
  out=$RUN_DIR/$ver
  install -d -m 755 "$out"
  tmp=$(mktemp -d "$RUN_DIR/.conf-$ver.XXXXXX")
  for ini in "$PHP_ETC/$ver/fpm/conf.d"/*.ini; do
    [[ -f $ini ]] || continue
    sed -E 's/^([[:space:]]*(zend_)?extension[[:space:]]*=)/; compiled in or not part of the lean build: \1/' \
      "$ini" > "$tmp/${ini##*/}"
  done
  chmod 644 "$tmp"/*.ini 2>/dev/null || true
  rm -f "$out"/*.ini
  mv -f "$tmp"/*.ini "$out"/ 2>/dev/null || true
  rmdir "$tmp"
}

# A candidate must be a release of the installed X.Y no older than the
# package, start without a warning, carry every module the applications
# need, give every INI directive it shares with the package the package's
# value, link none of the libraries it builds from Ubuntu, and accept the
# live FPM configuration.
verify_binary() {
  local ver=$1 cand=$2 pkg cv pv out m diffs needed
  pkg=$(pkg_bin "$ver")
  cv=$(bin_version "$cand") || die "candidate does not report a PHP version"
  pv=$(bin_version "$pkg") || die "cannot read the PHP version of $pkg"
  [[ ${cv%.*} == "$ver" ]] || die "candidate is PHP $cv, not a PHP $ver release"
  ver_ge "$cv" "$pv" || die "candidate PHP $cv is older than the package ($pv)"
  out=$("$cand" -m 2>&1) || die "candidate fails to start: $(printf '%s' "$out" | sed -n 1p)"
  if grep -qiE 'warning|error|unable to' <<<"$out"; then
    grep -iE 'warning|error|unable to' <<<"$out" | head -n 5 >&2 || true
    die "candidate starts with warnings"
  fi
  for m in "${APP_MODULES[@]}"; do
    grep -qxF "$m" <<<"$out" || die "candidate lacks the $m module"
  done
  # ... and nothing else: the build carries only what the three apps use.
  local extra
  extra=$(grep -vE '^(\[.*\])?$' <<<"$out" | sort -u \
    | grep -vxF -f <(printf '%s\n' "${APP_MODULES[@]}" "${CORE_MODULES[@]}") || true)
  [[ -z $extra ]] || die "candidate has modules outside the app set: $(tr '\n' ' ' <<<"$extra")"
  diffs=$(join -t "$(printf '\t')" <(bin_directives "$pkg") <(bin_directives "$cand") \
    | awk -F'\t' '$2 != $3' | grep -vE '^(redis|igbinary)\.' || true)
  if [[ -n $diffs ]]; then
    printf '%s\n' "$diffs" | head -n 20 >&2
    die "candidate INI defaults differ from the package's php-fpm"
  fi
  needed=$(readelf -d "$cand" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
  if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
    die "candidate links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')instead of the upstream builds"
  fi
  ! ldd "$cand" 2>/dev/null | grep -q 'not found' || die "candidate has unresolved libraries"
  "$cand" -t --fpm-config "/etc/php/$ver/fpm/php-fpm.conf" >/dev/null 2>&1 \
    || die "candidate rejects /etc/php/$ver/fpm/php-fpm.conf"
}

# Point the unit at the build.  The package's ExecStart line is rewritten,
# not retyped, so its arguments stay whatever the package ships.  A lean
# build mirrors conf.d before every start and reload.
activate() {
  local ver=$1 unit d pkg exec reloads
  unit=${PHP_BUILD_PKG_UNIT_DIR:-/usr/lib/systemd/system}/php$ver-fpm.service
  [[ -f $unit ]] || unit=/lib/systemd/system/php$ver-fpm.service
  pkg=$(pkg_bin "$ver")
  exec=$(grep -m1 "^ExecStart=$pkg " "$unit" 2>/dev/null || true)
  [[ -n $exec ]] || die "cannot find '$pkg' in the ExecStart of $unit"
  reloads=$(grep '^ExecReload=.' "$unit" 2>/dev/null || true)
  d=$(dropin_path "$ver")
  install -d -m 755 "$(dirname "$d")"
  {
    printf '# Managed by setup.sh (PHP_BUILD=clang): start the compiled php-fpm %s.\n' "$(info_get "$ver" version)"
    printf '# php-fpm-build.sh deactivate %s goes back to the package.\n[Service]\n' "$ver"
    printf 'ExecStartPre=%s conf %s\n' "$TOOL" "$ver"
    printf 'ExecStart=\n%s\n' "${exec/$pkg /$(build_dir "$ver")/php-fpm }"
    printf 'ExecReload=\nExecReload=%s conf %s\n' "$TOOL" "$ver"
    [[ -n $reloads ]] && printf '%s\n' "$reloads"
  } > "$d.new"
  mv -f "$d.new" "$d"
  systemctl daemon-reload
  restart_checked "$ver" || { deactivate "$ver"; die "PHP $ver did not start on the build; back on the package binary"; }
}

# Restart (a new ExecStart needs one) and require the master to stay up.
restart_checked() {
  local ver=$1
  systemctl is-active --quiet "php$ver-fpm" || systemctl is-enabled --quiet "php$ver-fpm" || return 0
  systemctl restart "php$ver-fpm" || return 1
  sleep 3
  systemctl is-active --quiet "php$ver-fpm"
}

# Graceful reload (the unit's ExecReload mirrors conf.d, then SIGUSR2
# re-executes the binary at its path): in-flight requests finish, the socket
# stays open.  Falls back to a restart.
reload_checked() {
  local ver=$1
  systemctl is-active --quiet "php$ver-fpm" || return 0
  if systemctl reload "php$ver-fpm" 2>/dev/null; then
    sleep 3
    systemctl is-active --quiet "php$ver-fpm" && return 0
  fi
  restart_checked "$ver"
}

deactivate() {
  local ver=$1 d
  d=$(dropin_path "$ver")
  [[ -f $d ]] || return 0
  rm -f "$d"
  systemctl daemon-reload
  if systemctl is-active --quiet "php$ver-fpm" || systemctl is-enabled --quiet "php$ver-fpm"; then
    systemctl restart "php$ver-fpm" || true
  fi
  rm -rf "${RUN_DIR:?}/$ver"
  say "PHP $ver: back on the package's php-fpm"
}

cmd_bolt() {
  local ver=$1 secs=${2:-60} dir base work perf p2b bolt samples n
  need_root
  dir=$(build_dir "$ver"); base=$dir/php-fpm.lto
  [[ -x $base ]] || die "no build for PHP $ver: run build first"
  [[ $(active_bin "$ver") == "$dir/php-fpm" ]] || die "PHP $ver is not running the build"
  n=$(info_get "$ver" llvm)
  [[ $n =~ ^[0-9]+$ ]] || die "build.info names no LLVM version: rebuild"
  ensure_packages linux-tools-common "linux-tools-$(uname -r)" \
    || die "perf is not installable for kernel $(uname -r)"
  llvm_install "$n" "bolt-$n"
  perf=$(command -v perf) || die "perf not found"
  p2b=$LLVM_BIN/perf2bolt; bolt=$LLVM_BIN/llvm-bolt
  [[ -x $p2b && -x $bolt ]] || die "llvm-bolt/perf2bolt $n not found in $LLVM_BIN"
  # BOLT rewrites the relocated LTO base; the running binary must be that
  # base (not an earlier BOLT output) or the samples would not map.
  if [[ $(info_get "$ver" bolt) == 1 ]]; then
    install_stripped "$base" "$dir/php-fpm.new"; mv -f "$dir/php-fpm.new" "$dir/php-fpm"
    sed -i 's/^bolt=.*/bolt=0/' "$dir/build.info"
    reload_checked "$ver" || die "PHP $ver did not reload on the LTO build"
  fi
  pgrep -f "^php-fpm: (master|pool)" >/dev/null || die "no php-fpm processes to sample"
  mkdir -p "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/bolt-$ver.XXXXXX")
  WORK_DIR=$work
  # PHP_BUILD_KEEP_WORK=1 keeps the work directory (sources, logs, candidate) for debugging.
  [[ ${PHP_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  # opcache.huge_code_pages stays on while sampling: the samples keep the
  # binary's addresses, and sampling with it off profiled the same functions
  # (2,549 vs 2,541) for the same speed (1.21.69).
  say "PHP $ver: sampling php-fpm for ${secs}s for BOLT"
  if ! "$perf" record -q -e cycles:u -j any,u -o "$work/perf.data" -a -- sleep "$secs" >/dev/null 2>&1; then
    die "perf could not record branch samples (no LBR on this CPU or VM?)"
  fi
  "$p2b" -p "$work/perf.data" -o "$work/php-fpm.fdata" "$base" > "$work/p2b.log" 2>&1 \
    || { tail -n 5 "$work/p2b.log" >&2; die "perf2bolt failed"; }
  samples=$(awk '/BOLT-INFO: [0-9]+ out of [0-9]+ functions in the binary/ { print $2 }' "$work/p2b.log" | sed -n 1p)
  if [[ ${samples:-0} -lt $BOLT_MIN_FUNCS ]]; then
    say "PHP $ver: ${samples:-0} php-fpm functions profiled in ${secs}s (need $BOLT_MIN_FUNCS): too little traffic, BOLT skipped"
    return 3
  fi
  "$bolt" "$base" -o "$work/php-fpm.bolt" -data="$work/php-fpm.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -icf > "$work/bolt.log" 2>&1 \
    || { tail -n 5 "$work/bolt.log" >&2; die "llvm-bolt failed"; }
  bolt_stack_check "$work/php-fpm.bolt"
  verify_binary "$ver" "$work/php-fpm.bolt"
  install -m 600 "$work/php-fpm.fdata" "$dir/php-fpm.fdata"
  install_stripped "$work/php-fpm.bolt" "$dir/php-fpm.new"
  mv -f "$dir/php-fpm.new" "$dir/php-fpm"
  if ! reload_checked "$ver"; then
    install_stripped "$base" "$dir/php-fpm.new"; mv -f "$dir/php-fpm.new" "$dir/php-fpm"
    restart_checked "$ver" || deactivate "$ver"
    die "PHP $ver did not start on the BOLT binary; back on the LTO build"
  fi
  sed -i 's/^bolt=.*/bolt=1/' "$dir/build.info"
  say "PHP $ver: BOLT applied ($samples php-fpm functions profiled)"
}

cmd_rebuild() {
  local ver=$1
  cmd_build "$ver"
  # Let the new workers serve real traffic before sampling it.
  sleep "${PHP_BUILD_BOLT_DELAY:-600}"
  ( cmd_bolt "$ver" "${PHP_BUILD_BOLT_SECONDS:-60}" ) || true
}

cmd_remove() {
  local ver=$1
  deactivate "$ver"
  rm -rf "$(build_dir "$ver")" "${RUN_DIR:?}/$ver"
}

# 0: the build has the current recipe and every version php-build.conf
# resolves to; 10: it has not (the differences are printed); 2: a version
# could not be resolved.
cmd_check() {
  local ver=$1 name want have stale="" rc=0 recipe
  [[ -f $(build_dir "$ver")/build.info ]] || { echo "no build"; return 10; }
  recipe=$(info_get "$ver" recipe)
  [[ ${recipe:-1} == "$BUILD_RECIPE" ]] || stale+="recipe ${recipe:-1} -> $BUILD_RECIPE, "
  local bcpu; bcpu=$(info_get "$ver" cpu)
  [[ -z $bcpu || $bcpu == "$(cpu_model)" ]] || stale+="cpu $bcpu -> $(cpu_model), "
  while IFS='=' read -r name want; do
    have=$(info_get "$ver" "$name")
    if [[ $want == "?" ]]; then rc=2; continue; fi
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_all "$ver" || true)
  if [[ -n $stale ]]; then printf 'stale: %s\n' "${stale%, }"; return 10; fi
  if (( rc )); then echo "current as far as known (a version could not be looked up)"; return 2; fi
  echo current
}

# DPkg::Post-Invoke.  A package update that made the package newer than the
# build (a security release), or one that removed a library the build links,
# goes back to the package binary at once and rebuilds in the background.
cmd_apt_hook() {
  local d ver want have bin
  for d in "$UNIT_DIR"/php*-fpm.service.d/zz-setup-build.conf; do
    [[ -f $d ]] || continue
    ver=${d#"$UNIT_DIR"/php}; ver=${ver%%-fpm.service.d/*}
    valid_ver "$ver" || continue
    if [[ ! -x $(pkg_bin "$ver") ]]; then
      # The package itself is gone (purged or --upgrade-php): drop the build.
      rm -f "$d"; rm -rf "$(build_dir "$ver")" "${RUN_DIR:?}/$ver"; systemctl daemon-reload || true
      say "PHP $ver: package removed; build and drop-in deleted"
      continue
    fi
    want=$(bin_version "$(pkg_bin "$ver")" || true)
    have=$(info_get "$ver" version)
    bin=$(build_dir "$ver")/php-fpm
    if [[ -n $want && -n $have ]] && ver_ge "$have" "$want"; then
      [[ -x $bin ]] && ldd "$bin" 2>/dev/null | grep -q 'not found' || continue
      say "PHP $ver: the build lost a system library; reverting and rebuilding"
    else
      say "PHP $ver: package is now $want, build is ${have:-unknown}; reverting and rebuilding"
    fi
    deactivate "$ver"
    systemctl start --no-block "setup-php-fpm-build@$ver.service" 2>/dev/null || true
  done
  return 0
}

# Daily timer: rebuild (in the background unit) every version whose build
# trails a release php-build.conf asks for.  The current build keeps serving.
cmd_refresh() {
  local d ver out rc
  for d in "$ROOT"/*/build.info; do
    [[ -f $d ]] || continue
    ver=${d#"$ROOT"/}; ver=${ver%/build.info}
    valid_ver "$ver" || continue
    rc=0; out=$(cmd_check "$ver") || rc=$?
    if (( rc == 10 )); then
      say "PHP $ver: $out; rebuilding"
      systemctl start --no-block "setup-php-fpm-build@$ver.service" 2>/dev/null || true
    fi
  done
  return 0
}

cmd_status() {
  local ver d
  for d in "$ROOT"/*/build.info; do
    [[ -f $d ]] || continue
    ver=${d#"$ROOT"/}; ver=${ver%/build.info}
    [[ -n ${1:-} && $1 != "$ver" ]] && continue
    printf 'PHP %s: build %s (clang %s, recipe %s), bolt=%s, active=%s, package %s\n' "$ver" \
      "$(info_get "$ver" version)" "$(info_get "$ver" llvm)" "$(info_get "$ver" recipe)" "$(info_get "$ver" bolt)" \
      "$([[ $(active_bin "$ver") == "$(build_dir "$ver")/php-fpm" ]] && echo yes || echo no)" \
      "$(bin_version "$(pkg_bin "$ver")" 2>/dev/null || echo none)"
  done
}

main() {
  local cmd=${1:-} ver=${2:-}
  case $cmd in
    build|bolt|rebuild|check|versions|activate|deactivate|remove|conf)
      valid_ver "$ver" || die "usage: $0 $cmd X.Y" ;;
  esac
  case $cmd in
    build)      # The only mode is clang (lean/source were dropped in 1.21.70).
                case ${3:-clang} in clang) ;; *) die "unknown mode '${3:-}' (only clang)" ;; esac
                cmd_build "$ver" ;;
    bolt)       cmd_bolt "$ver" "${3:-60}" ;;
    rebuild)    cmd_rebuild "$ver" ;;
    check)      cmd_check "$ver" ;;
    versions)   resolve_all "$ver" ;;
    activate)   need_root
                [[ -x $(build_dir "$ver")/php-fpm ]] || die "no PHP $ver build: run build"
                ver_ge "$(info_get "$ver" version)" "$(bin_version "$(pkg_bin "$ver")")" \
                  || die "the PHP $ver build is older than the package: run build"
                activate "$ver" ;;
    deactivate) need_root; deactivate "$ver" ;;
    remove)     need_root; cmd_remove "$ver" ;;
    conf)       need_root; cmd_conf "$ver" ;;
    apt-hook)   need_root; cmd_apt_hook ;;
    refresh)    need_root; cmd_refresh ;;
    status)     cmd_status "${2:-}" ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
  esac
}

if [[ ${PHP_BUILD_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
