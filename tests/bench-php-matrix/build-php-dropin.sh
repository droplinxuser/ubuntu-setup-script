#!/usr/bin/env bash
# Build a php-fpm binary that drops into the Sury package in place of
# /usr/sbin/php-fpmX.Y: same version, same compiled-in core, same paths and
# extension directory, so it loads Sury's own shared extensions (mysqli,
# mysqlnd, redis, igbinary, imagick, gd, intl ...) and reads the managed
# php.ini/pool unchanged.  Only the compiler and its flags differ.
#
# Usage: build-php-dropin.sh TAG
#   Installs /opt/php-TAG/sbin/php-fpm (+ bin/php for checks).  Serve it with
#   `switch-php-arm.sh dropin-TAG`, which points the packaged php8.5-fpm unit
#   at that binary through a runtime systemd drop-in.
#
# Environment:
#   CC=clang (default) | gcc
#   NO_LTO=1     no ThinLTO (clang) / no -flto (GCC needs it off anyway: the
#                HYBRID VM's global registers do not link with LTO)
#   BOLT=1       keep relocations for bolt-php.sh
#   PHP_VER      X.Y of the installed package (default 8.5)
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

TAG=${1:?usage: build-php-dropin.sh TAG}
[[ $TAG =~ ^[a-z0-9-]+$ ]] || { echo "tag must be [a-z0-9-]+" >&2; exit 1; }
PHP_VER=${PHP_VER:-8.5}
CC=${CC:-clang}
PREFIX=/opt/php-$TAG
WORK=/root/work/dropin-$TAG
JOBS=$(nproc)

pkgbin=/usr/sbin/php-fpm$PHP_VER
[[ -x $pkgbin ]] || { echo "$pkgbin missing: install php$PHP_VER-fpm first" >&2; exit 1; }
# The exact upstream version of the package (8.5.13-3+debsuryorg... -> 8.5.13).
VERSION=$("$pkgbin" -n -v | awk 'NR == 1 { print $2 }')
VERSION=${VERSION%%-*}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read the package's PHP version" >&2; exit 1; }
EXT_DIR=$("$pkgbin" -n -i 2>/dev/null | awk -F' => ' '$1 == "extension_dir" && !f { print $2; f = 1 }')  # read to EOF: an early exit makes php die of EPIPE (255) under pipefail
[[ -d $EXT_DIR ]] || { echo "cannot read the package's extension_dir" >&2; exit 1; }

FLAGS="-O3 -march=native -mtune=native -pipe -fno-semantic-interposition"
LDF=""
if [[ $CC == clang* ]]; then
  if [[ ${NO_LTO:-0} != 1 ]]; then FLAGS+=" -flto=thin"; LDF="-flto=thin -fuse-ld=lld"; fi
  export CXX=${CC/clang/clang++}
else
  export CXX=g++
fi
[[ ${BOLT:-0} == 1 ]] && LDF+=" -Wl,--emit-relocs"
export CC CFLAGS="$FLAGS" CXXFLAGS="$FLAGS" LDFLAGS="$LDF"

packages=(build-essential pkg-config autoconf bison re2c
          libxml2-dev libssl-dev libsodium-dev zlib1g-dev libpcre2-dev
          libsystemd-dev libacl1-dev libapparmor-dev)
[[ $CC == clang* ]] && packages+=(clang lld llvm)
missing=()
for p in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
done
if (( ${#missing[@]} )); then
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
fi

mkdir -p "$WORK"
tarball=$WORK/php-$VERSION.tar.xz
if [[ ! -s $tarball ]]; then
  curl -fsSL --retry 3 -o "$tarball.part" "https://www.php.net/distributions/php-$VERSION.tar.xz"
  mv "$tarball.part" "$tarball"
fi
src=$WORK/php-$VERSION
rm -rf "$src"; mkdir -p "$src"
tar -xJf "$tarball" -C "$src" --strip-components=1
cd "$src"

# The core the package compiles into php-fpm (php-fpm8.5 -n -m): Core, date,
# filter, hash, json, lexbor, libxml, openssl, pcre (system PCRE2), random,
# Reflection, session, sodium, SPL, standard, uri, zlib, OPcache.  Everything
# else stays a Sury .so in EXT_DIR, built against the same API.
EXTENSION_DIR=$EXT_DIR ./configure \
  --prefix="$PREFIX" \
  --with-config-file-path="/etc/php/$PHP_VER/fpm" \
  --with-config-file-scan-dir="/etc/php/$PHP_VER/fpm/conf.d" \
  --with-libdir=lib/x86_64-linux-gnu \
  --disable-all --disable-cgi --disable-phpdbg --without-pear \
  --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
  --with-fpm-systemd --with-fpm-acl --with-fpm-apparmor \
  --enable-filter --enable-session --with-libxml --with-openssl \
  --with-sodium --with-zlib --with-external-pcre \
  > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log" >&2; exit 1; }
make -j"$JOBS" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log" >&2; exit 1; }
rm -rf "$PREFIX"
install -d "$PREFIX/sbin" "$PREFIX/bin"
install -m 0755 sapi/fpm/php-fpm "$PREFIX/sbin/php-fpm"
install -m 0755 sapi/cli/php "$PREFIX/bin/php"

# Prove it is a drop-in: same version and API, the package's extensions load.
got=$("$PREFIX/sbin/php-fpm" -n -v | awk 'NR == 1 { print $2 }')
[[ $got == "$VERSION" ]] || { echo "version mismatch: $got vs $VERSION" >&2; exit 1; }
mods_pkg=$("$pkgbin" -m 2>/dev/null | sort)
mods_new=$("$PREFIX/sbin/php-fpm" -c "/etc/php/$PHP_VER/fpm/php.ini" -m 2>/dev/null | sort)
if [[ $mods_pkg != "$mods_new" ]]; then
  echo "module set differs from the package's php-fpm:" >&2
  diff <(printf '%s\n' "$mods_pkg") <(printf '%s\n' "$mods_new") >&2 || true
  exit 1
fi
"$PREFIX/sbin/php-fpm" -t --fpm-config "/etc/php/$PHP_VER/fpm/php-fpm.conf" 2>&1 | tail -n 1
echo "vm: $("$PREFIX/bin/php" -n -r 'echo ZEND_VM_KIND;')"
echo "installed: $PREFIX/sbin/php-fpm (PHP $VERSION, $CC, flags: $FLAGS)"
