#!/usr/bin/env bash
# Build the "everything on" PHP arm: CentminMod's Intel path plus LTO,
# function alignment, semantic-interposition and PLT tweaks, and optional
# profile-guided optimisation, with every extension XenForo needs compiled
# from source against the new tree.
#
# Usage: build-php-max.sh VERSION TAG STAGE
#   STAGE  plain     optimised build, no PGO
#          generate  instrumented build for training (-fprofile-generate)
#          use       rebuild with the collected profile (-fprofile-use)
#
# The source tree and the PECL sources are kept between stages under
# /root/work, so "generate" and "use" reuse the same paths.  Training runs
# after "generate": switch the FPM unit to the arm, drive real traffic, stop
# it, then run "use".
#
# Environment:
#   NO_LTO=1        drop -flto (CentminMod PHP_LTO=n, the shipped default)
#   NO_FALIGN=1     drop -falign-functions=32 (CentminMod GCC_FALIGN_FUNCTION=n,
#                   its default)
#   CC=clang        build PHP and the extensions with clang (CentminMod
#                   CLANG_PHP=y); the default is the distribution GCC
#   PHP_INI_DIR     the managed php.ini to share (default /etc/php/8.5/fpm);
#                   an 8.4 arm reads the same file
#   IGBINARY_VER    PECL igbinary release (default 3.2.17RC1, the first
#                   that compiles against 8.5)
#
# The LiteSpeed SAPI (--enable-litespeed, $PREFIX/bin/lsphp) is built too, so
# the OpenLiteSpeed arms (install-ols.sh, switch-php-arm.sh ols-src-TAG) can run
# the same compiled PHP over LSAPI.  It is a separate binary: php-fpm is the
# same with or without it.
#
# `switch-php-arm.sh src-TAG` treats an extension directory that contains
# .source-built-ext as authoritative and does not fall back to the
# distribution's .so files.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

VERSION=${1:?usage: build-php-max.sh VERSION TAG plain|generate|use}
TAG=${2:?tag}
STAGE=${3:?plain|generate|use}
PREFIX=/opt/php-$TAG
SRC=/root/work/php-src-$TAG
TARBALL=/root/work/php-$VERSION.tar.gz
PGO_DIR=/root/work/pgo-$TAG
FPM_RUNDIR=/etc/php-src/$TAG
CONF_DIR=$FPM_RUNDIR/conf.d
EXT_DIR=$FPM_RUNDIR/ext
PHP_INI_DIR=${PHP_INI_DIR:-/etc/php/8.5/fpm}
IGBINARY_VER=${IGBINARY_VER:-3.2.17RC1}
CC=${CC:-gcc}
export CC CXX=${CC/clang/clang++}
[[ $CXX == gcc ]] && CXX=g++
JOBS=$(nproc)

[[ $TAG =~ ^[a-z0-9-]+$ ]] || { echo "tag must be [a-z0-9-]+" >&2; exit 1; }
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
[[ -d $PHP_INI_DIR ]] || { echo "$PHP_INI_DIR missing" >&2; exit 1; }

# CentminMod's Intel path (inc/php_configure.inc: FALIGN_FUNCTION_OPT,
# SET_PHPEXTRA_CFLAGS, MARCH_TARGETNATIVE) plus LTO and the interposition/PLT
# switches that keep the optimiser from giving up across symbol boundaries.
BASE_FLAGS="-O3 -m64 -march=native -mtune=native -falign-functions=32 -pipe"
BASE_FLAGS+=" -fno-semantic-interposition"
BASE_FLAGS+=" -flto -fno-fat-lto-objects -fuse-linker-plugin"
if [[ ${NO_FALIGN:-0} == 1 ]]; then
  BASE_FLAGS=${BASE_FLAGS/ -falign-functions=32/}
fi
if [[ ${NO_LTO:-0} == 1 ]]; then
  BASE_FLAGS=${BASE_FLAGS% -flto -fno-fat-lto-objects -fuse-linker-plugin}
elif [[ $CC == clang* ]]; then
  # The fat-object and linker-plugin switches are GCC's; clang's equivalent is
  # ThinLTO through lld.
  BASE_FLAGS=${BASE_FLAGS% -flto -fno-fat-lto-objects -fuse-linker-plugin}
  BASE_FLAGS+=" -flto=thin"
  export LDFLAGS="-flto=thin -fuse-ld=lld"
fi
if [[ $CC == clang* && $STAGE != plain ]]; then
  echo "PGO stages are written for GCC's -fprofile-generate/-use; use CC=gcc" >&2
  exit 1
fi
case $STAGE in
  plain)    CFLAGS="$BASE_FLAGS" ;;
  generate)
    rm -rf "$PGO_DIR"
    CFLAGS="$BASE_FLAGS -fprofile-generate=$PGO_DIR"
    mkdir -p "$PGO_DIR"; chmod 777 "$PGO_DIR"
    ;;
  use)
    # configure probes reuse conftest.c, whose stale profile trips
    # -Werror=coverage-mismatch; the PHP objects have their own data.
    find "$PGO_DIR" -name "*conftest*" -delete 2>/dev/null || true
    CFLAGS="$BASE_FLAGS -fprofile-use=$PGO_DIR -fprofile-correction -Wno-error=coverage-mismatch -Wno-missing-profile"
    ;;
  *) echo "unknown stage: $STAGE" >&2; exit 1 ;;
esac
export CFLAGS CXXFLAGS="$CFLAGS"

# ---- build dependencies ----------------------------------------------------
packages=(
  build-essential pkg-config autoconf bison re2c
  libxml2-dev libsqlite3-dev libssl-dev libcurl4-openssl-dev
  libpng-dev libjpeg-dev libfreetype-dev libwebp-dev
  libzip-dev libonig-dev libgmp-dev libsodium-dev libsystemd-dev zlib1g-dev
  libmagickwand-dev
)
[[ $CC == clang* ]] && packages+=(clang lld)
missing=()
for p in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
done
if (( ${#missing[@]} )); then
  echo "installing build dependencies: ${missing[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
fi

# ---- source ----------------------------------------------------------------
mkdir -p /root/work
if [[ ! -s $TARBALL ]]; then
  echo "downloading php-$VERSION.tar.gz"
  curl -fsSL --retry 3 -o "$TARBALL.part" \
    "https://www.php.net/distributions/php-$VERSION.tar.gz"
  mv "$TARBALL.part" "$TARBALL"
fi
if [[ ! -x $SRC/configure ]]; then
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
fi
cd "$SRC"

# The module set is XenForo's (lib/services.sh install_php), compiled in.
# configure records CFLAGS in the Makefile, so every stage re-runs it.
./configure \
  --prefix="$PREFIX" \
  --with-config-file-path="$PHP_INI_DIR" \
  --with-config-file-scan-dir="$CONF_DIR" \
  --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
  --with-fpm-systemd \
  --with-mysqli --with-pdo-mysql \
  --with-curl --with-openssl \
  --enable-gd --with-jpeg --with-freetype --with-webp \
  --enable-mbstring --enable-exif --enable-bcmath \
  --with-zip --with-libxml --enable-dom --enable-xml \
  --enable-xmlreader --enable-xmlwriter --enable-simplexml \
  --with-gmp --enable-sockets \
  --with-zlib --with-sodium \
  --enable-litespeed \
  --disable-cgi --disable-phpdbg \
  --disable-gcc-global-regs \
  > "/root/work/build-$TAG-$STAGE-configure.log" 2>&1 \
  || { tail -30 "/root/work/build-$TAG-$STAGE-configure.log" >&2; exit 1; }

echo "building PHP $VERSION ($TAG, $STAGE) with CFLAGS=$CFLAGS"
make clean >/dev/null 2>&1 || true
make -j"$JOBS" > "/root/work/build-$TAG-$STAGE-make.log" 2>&1 \
  || { tail -40 "/root/work/build-$TAG-$STAGE-make.log" >&2; exit 1; }
make install > "/root/work/build-$TAG-$STAGE-install.log" 2>&1
if [[ $STAGE == use ]]; then
  # A profile that did not reach a hot object shows up here; report it.
  n=$(grep -c 'profile data' "/root/work/build-$TAG-$STAGE-make.log" || true)
  echo "profile notes in the build log: $n"
fi

# ---- every extension from source, against this tree -----------------------
export PATH="$PREFIX/bin:$PATH"
EXTDIR=$("$PREFIX/bin/php-config" --extension-dir)
mkdir -p "$EXTDIR" "$EXT_DIR" "$CONF_DIR"
if [[ $STAGE == use ]]; then
  # Stage "generate" built these against the instrumented binary.
  rm -f "$EXTDIR/igbinary.so" "$EXTDIR/redis.so" "$EXTDIR/imagick.so"
fi
pecl_ext() {
  local name=$1 ver=$2 dir=/root/work/pecl-src-$1-$2 url
  if [[ ! -d $dir/configure ]]; then
    rm -rf "$dir"; mkdir -p "$dir"
    case $name in
      redis)    url=https://pecl.php.net/get/redis-$ver.tgz ;;
      igbinary) url=https://pecl.php.net/get/igbinary-$ver.tgz ;;
      imagick)  url=https://pecl.php.net/get/imagick-$ver.tgz ;;
    esac
    curl -fsSL --retry 3 "$url" -o "$dir/ext.tgz" || return 1
    tar -xzf "$dir/ext.tgz" -C "$dir" --strip-components=1 || return 1
  fi
  ( cd "$dir" || exit 1
    # Extensions are separate .so files: LTO cannot cross the boundary and
    # instrumenting them would only add PGO noise.  Build them with the same
    # ISA baseline, no PGO.
    export CFLAGS="-O3 -march=native -mtune=native -fno-semantic-interposition"
    export CXXFLAGS="$CFLAGS"
    "$PREFIX/bin/phpize" >/dev/null 2>&1 || exit 1
    ./configure --with-php-config="$PREFIX/bin/php-config" >/dev/null 2>&1 || exit 1
    make clean >/dev/null 2>&1 || true
    make -j"$JOBS" >"/root/work/pecl-$name-$ver-make.log" 2>&1 || exit 1
    make install >/dev/null 2>&1 )
}
built=()
for spec in "igbinary $IGBINARY_VER" "redis 6.3.0" "imagick 3.8.1"; do
  # shellcheck disable=SC2086
  set -- $spec
  if [[ -f $EXTDIR/$1.so ]] || pecl_ext "$1" "$2"; then
    case $1 in igbinary) prio=20 ;; *) prio=99 ;; esac
    printf 'extension=%s\n' "$EXTDIR/$1.so" > "$EXT_DIR/$prio-$1.ini"
    built+=("$1")
    echo "extension: $1 $2"
  else
    echo "warning: could not build $1 $2 against PHP $VERSION (see /root/work/pecl-$1-$2-make.log)" >&2
  fi
done
[[ -f $EXTDIR/redis.so ]] && touch "$EXT_DIR/.source-built-ext"
# PHP 8.5 compiles OPcache into the binary; 8.4 and older build it as a
# shared Zend extension, which the managed conf.d (written for 8.5) never
# loads.  Without this line an 8.4 arm would run with no OPcache and no JIT.
if [[ -f $EXTDIR/opcache.so ]]; then
  printf 'zend_extension=%s\n' "$EXTDIR/opcache.so" > "$EXT_DIR/10-opcache.ini"
  echo "extension: opcache (shared, PHP < 8.5)"
fi

# ---- FPM unit on the shared socket ----------------------------------------
mkdir -p "$FPM_RUNDIR"
if [[ ! -f $FPM_RUNDIR/php-fpm.conf ]]; then
  sed -E \
    -e "s#^pid[[:space:]]*=.*#pid = /run/php/php-src-$TAG.pid#" \
    -e "s#^error_log[[:space:]]*=.*#error_log = /var/log/php-src-$TAG.log#" \
    "$PHP_INI_DIR/php-fpm.conf" > "$FPM_RUNDIR/php-fpm.conf"
fi
lto="LTO"; [[ ${NO_LTO:-0} == 1 ]] && lto="no LTO"
case $STAGE in
  plain)    desc="$CC, $lto" ;;
  generate) desc="$CC, $lto, PGO training build" ;;
  use)      desc="$CC, $lto, PGO" ;;
esac
cat > "/etc/systemd/system/php-src-$TAG.service" <<UNIT
[Unit]
Description=PHP-FPM $VERSION source build ($TAG, $desc)
After=network.target

[Service]
Type=notify
Environment=PHP_INI_SCAN_DIR=$CONF_DIR:$EXT_DIR
ExecStart=$PREFIX/sbin/php-fpm --nodaemonize --fpm-config $FPM_RUNDIR/php-fpm.conf -c $PHP_INI_DIR/php.ini
ExecReload=/bin/kill -USR2 \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=30
Restart=on-failure
LimitNOFILE=524288
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

"$PREFIX/bin/php" -v | head -1
printf 'modules: %s\n' "$("$PREFIX/bin/php" -m | tr '\n' ' ')"
printf 'extensions built: %s\n' "${built[*]:-none}"
echo "installed: $PREFIX ($STAGE)"
