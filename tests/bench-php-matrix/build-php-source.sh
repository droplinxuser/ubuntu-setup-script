#!/usr/bin/env bash
# Build a PHP-FPM from source with one named optimisation profile and install
# it under /opt/php-<tag>, without touching the distribution's PHP packages.
#
# The audit compares install sources on one host (Sury package, Ubuntu
# package, source).  A source build compiles in the distribution's php.ini path
# (--with-config-file-path) and is started by its own unit on the same FastCGI
# socket, so swapping an arm changes the binary and nothing the application
# sees.  tests/bench-php-matrix/switch-php-arm.sh assembles the per-arm
# extension directory and starts the unit.
#
# The module set is the one XenForo needs (see lib/services.sh install_php):
# mysqli, gd, curl, mbstring, xml, zip, gmp, OPcache (built in since 8.5).
# redis and imagick are built afterwards with the new tree's phpize because the
# deployed XenForo and Chevereto configurations use them.
#
# Usage: build-php-source.sh VERSION TAG [PROFILE]
#   PROFILE  generic      -O2 -march=x86-64 (what a distribution build uses)
#            centmin      -O3 -m64 -march=native -pipe (CentminMod's default
#                         Intel path: MARCH_TARGETNATIVE=y, GCC_FALIGN_FUNCTION=n,
#                         PHP_LTO=n, PHP_PGO=n)
#            centmin-lto  centmin + -flto -fno-fat-lto-objects
#
# The source tarball is expected at /root/work/php-$VERSION.tar.gz; a missing
# one is downloaded from php.net.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

VERSION=${1:?usage: build-php-source.sh VERSION TAG [generic|centmin|centmin-lto]}
TAG=${2:?tag}
PROFILE=${3:-centmin}
PREFIX=/opt/php-$TAG
SRC=/root/work/php-src-$TAG
TARBALL=/root/work/php-$VERSION.tar.gz
FPM_RUNDIR=/etc/php-src/$TAG
JOBS=$(nproc)
PHP_INI_DIR=/etc/php/8.5/fpm
CONF_DIR=$FPM_RUNDIR/conf.d
EXT_DIR=$FPM_RUNDIR/ext

[[ $TAG =~ ^[a-z0-9-]+$ ]] || { echo "tag must be [a-z0-9-]+" >&2; exit 1; }
[[ -d $PHP_INI_DIR ]] || { echo "$PHP_INI_DIR missing; install the distribution PHP first" >&2; exit 1; }
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
case $PROFILE in
  generic)     CFLAGS="-O2 -march=x86-64 -pipe" ;;
  centmin)     CFLAGS="-O3 -m64 -march=native -pipe" ;;
  centmin-lto) CFLAGS="-O3 -m64 -march=native -pipe -flto -fno-fat-lto-objects" ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 1 ;;
esac

# ---- build dependencies (test host only; purged at restore) ---------------
packages=(
  build-essential pkg-config autoconf bison re2c
  libxml2-dev libsqlite3-dev libssl-dev libcurl4-openssl-dev
  libpng-dev libjpeg-dev libfreetype-dev libwebp-dev
  libzip-dev libonig-dev libgmp-dev libsodium-dev libsystemd-dev
)
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
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
cd "$SRC"

export CFLAGS
export CXXFLAGS="$CFLAGS"

# XenForo's module set plus the XML/HTTP pieces WordPress and Chevereto use.
# OPcache and its JIT are unconditional since PHP 8.5.
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
  --disable-cgi --disable-phpdbg \
  > "/root/work/build-$TAG-configure.log" 2>&1 \
  || { tail -30 "/root/work/build-$TAG-configure.log" >&2; exit 1; }

echo "building PHP $VERSION ($PROFILE) with CFLAGS=$CFLAGS"
make -j"$JOBS" > "/root/work/build-$TAG-make.log" 2>&1 \
  || { tail -40 "/root/work/build-$TAG-make.log" >&2; exit 1; }
make install > "/root/work/build-$TAG-install.log" 2>&1

# ---- shared extensions ----------------------------------------------------
# The deployed XenForo selects XenForo's core Redis cache provider and
# Chevereto requires Imagick, so an arm without them is not comparable.
# PECL redis 6.2.0 does not compile against PHP 8.5 (common.h includes
# ext/standard/php_smart_string.h, removed in 8.5) and PECL imagick 3.8.0
# predates it; the distributions carry patches.  switch-php-arm.sh loads the
# distribution's redis/igbinary/imagick builds for every arm, so the
# extension code is identical and only the PHP binary differs.
mkdir -p "$CONF_DIR" "$EXT_DIR"

# ---- FPM unit on the shared socket ----------------------------------------
# Reuse the distribution's [global] block (include of pool.d/*.conf) with a
# per-arm pid and log so an arm's log is unambiguous.
mkdir -p "$FPM_RUNDIR"
sed -E \
  -e "s#^pid[[:space:]]*=.*#pid = /run/php/php-src-$TAG.pid#" \
  -e "s#^error_log[[:space:]]*=.*#error_log = /var/log/php-src-$TAG.log#" \
  "$PHP_INI_DIR/php-fpm.conf" > "$FPM_RUNDIR/php-fpm.conf"

cat > "/etc/systemd/system/php-src-$TAG.service" <<UNIT
[Unit]
Description=PHP-FPM $VERSION source build ($TAG, $PROFILE)
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
"$PREFIX/bin/php" -m | tr '\n' ' '
echo
echo "installed: $PREFIX (unit php-src-$TAG.service, scan dir $CONF_DIR)"
