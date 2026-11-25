#!/usr/bin/env bash
# PHP X.Y compiled from source: php-fpm and the php CLI (setup.sh 1.22.0).
#
# Since 1.22 every PHP on a setup.sh host comes from here; there is no Sury
# or Ubuntu PHP package any more.  Both SAPIs are built from ONE configured
# tree (two make targets): sapi/fpm/php-fpm and sapi/cli/php.  Sources are
# upstream only: PHP from php.net (its SHA-256; GitHub php-src tag snapshot
# as the second source, never an RC/alpha/beta), clang/lld/BOLT from
# apt.llvm.org, redis and igbinary from PECL, SQLite from sqlite.org (the
# amalgamation), ICU from unicode-org (only when intl is asked for), and
# every library the binaries link (OpenSSL, PCRE2, zlib-ng, libxml2,
# libsodium, GMP, GNU libiconv, curl, libjpeg-turbo, libpng, libwebp,
# libzip) from the project's own releases, at the versions in php-build.conf
# ("latest" by default).  Everything is compiled -O3 -march=native -fPIE with
# Ubuntu's hardening flags, linked statically with ThinLTO, and php-fpm is
# rewritten by LLVM BOLT from a perf sample of live traffic (the CLI is LTO
# only: it runs cron jobs, not page views).  Only glibc (libc, libm) comes
# from Ubuntu; sd_notify() for the unit is a small static implementation.
#
# Extensions are static and exactly the host's effective set (setup.sh's
# php_build_effective_exts: base + the applications found on the host +
# PHP_EXT_EXTRA), handed over in ROOT/X.Y/exts.want.  OPcache is compiled in
# from PHP 8.5; before 8.5 PHP can only build it as a shared module, which
# is installed as ROOT/X.Y/lib/opcache.so and loaded with its full path from
# /etc/php/X.Y/{fpm,cli}/conf.d/00-setup-opcache.ini.  No other shared
# module exists, so no extension= line is ever needed.
# No intl/ICU unless asked for: measured 1.21.69, ICU made php-fpm 102 MB
# instead of 60 MB and cost 4.5x the data-TLB misses on XenForo pages.
#
# Layout (ROOT = /usr/local/lib/setup-php):
#   ROOT/X.Y/sbin/php-fpm(.lto)  ROOT/X.Y/bin/php  ROOT/X.Y/lib/opcache.so
#   ROOT/X.Y/share/php.ini-{production,development}  ROOT/X.Y/build.info
#   ROOT/X.Y/staging/            a verified build waiting for `activate`
#   ROOT/logs/php-X.Y-*.log      the last 5 build logs (kept on failure)
# Compiled-in paths: php.ini /etc/php/X.Y/cli (the CLI default), scan dir
# /etc/php/X.Y/cli/conf.d, FPM config /etc/php/X.Y/fpm/php-fpm.conf
# (--sysconfdir); the unit passes -c and PHP_INI_SCAN_DIR for the FPM tree.
#
# Usage (root):
#   php-build.sh build    X.Y      build + verify into ROOT/X.Y/staging
#   php-build.sh activate X.Y      swap the staged build in (opcache.so,
#                                  CLI, php-fpm); restart the unit when it
#                                  runs (our unit only), roll back on failure
#   php-build.sh bolt     X.Y [S]  sample S seconds (default 60), BOLT,
#                                  verify, swap, restart
#   php-build.sh rebuild  X.Y      build, activate, wait, bolt (refresh unit)
#   php-build.sh rebuild-cpu X.Y   CPU changed: rebuild the exact recorded
#                                  versions offline, activate (no BOLT; the
#                                  chain starts the unit)
#   php-build.sh check    X.Y      0 current, 10 stale (printed), 2 unknown
#   php-build.sh pre      X.Y      ExecStartPre: restore missing managed
#                                  files, CPU gate, php-fpm -t without load
#                                  warnings
#   php-build.sh refresh           daily: recompute the extension set (add
#                                  only), rebuild the active version in the
#                                  background when stale
#   php-build.sh versions X.Y      the versions php-build.conf resolves to
#   php-build.sh series            the newest released PHP X.Y
#   php-build.sh release  X.Y      the newest released X.Y.Z (empty: none)
#   php-build.sh status  [X.Y]     one line per installed version
#   php-build.sh remove   X.Y      delete ROOT/X.Y (setup.sh removes units)
#
# Installed by setup.sh as /usr/local/lib/setup-php/php-build.sh.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ROOT=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
SRC_CACHE=${PHP_BUILD_CACHE:-/var/cache/setup-php-build}
UNIT_DIR=${PHP_BUILD_UNIT_DIR:-/etc/systemd/system}
PHP_ETC=${PHP_BUILD_ETC:-/etc/php}
CONF=${PHP_BUILD_CONF:-$ROOT/php-build.conf}
# The installed copy of lib/php-build.sh: the extension-set detection the
# daily refresh reruns without setup.sh.
LIB=${PHP_BUILD_LIB:-$ROOT/php-build-lib.sh}
LOG_DIR=${PHP_BUILD_LOG_DIR:-$ROOT/logs}
ACTIVE_FILE=${PHP_BUILD_ACTIVE_FILE:-$PHP_ETC/setup-active}
BACKUP_DIR=${PHP_BUILD_BACKUP_DIR:-/var/backups/setup-1.22}
SESSION_DIR=/var/lib/php/sessions
MYSQL_SOCK=/run/mysqld/mysqld.sock
# Debian's compiled-in include_path, which PEAR-less hosts and operator code
# expect (1.21 copied it from the package binary).
INCLUDE_PATH=".:/usr/share/php"
LOG_TAG=setup-php-build
# Shared download, version, toolchain, lock and CPU code (nginx and Valkey
# use it too).
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
# the library cache key.  6: 1.22 (SQLite, ICU; the CPU fingerprint joined
# the key: 1.21 reused libraries compiled -march=native for the previous CPU
# after a hardware change).
LIB_RECIPE=6
# Bump BUILD_RECIPE when the build itself changes (flags, layout): `check`
# reports an older recipe as stale.  1-4: 1.21.68-1.21.71 (FPM only, beside
# the Sury package).  5: 1.22.0 (FPM + CLI, own layout, per-host set).
BUILD_RECIPE=5
# Libraries php-fpm/php must NOT take from Ubuntu (they are linked statically).
STATIC_LIBS_RE='^(libssl|libcrypto|libxml2|libpcre2-8|libz|libicu[a-z0-9]*|libcurl|libsodium|libgmp|libjpeg|libpng16|libwebp|libsharpyuv|libzip|libonig|libsystemd|libiconv|libsqlite3)\.so'
# Extensions only the CLI SAPI builds (pcntl's config.m4 names cli/cgi).
CLI_ONLY_EXTS="pcntl"

valid_ver() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+$ ]]; }
# 8.1 is the oldest series the build recipe supports (section 8).
ver_supported() { valid_ver "$1" && ver_ge "$1" 8.1; }
vdir() { printf '%s/%s' "$ROOT" "$1"; }
stage_dir() { printf '%s/%s/staging' "$ROOT" "$1"; }
opcache_shared() { ! ver_ge "$1" 8.5; } # X.Y: OPcache is a shared module
unit_file() { printf '%s/php%s-fpm.service' "$UNIT_DIR" "$1"; }

# "8.5.13" from a binary.  Reads to EOF: an early exit kills php with
# EPIPE under pipefail.
bin_version() {
  local v
  v=$("$1" -n -v 2>/dev/null | awk 'NR == 1 { print $2 }')
  v=${v%%-*}
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
}

# A compiled-in INI default of a binary (no php.ini), e.g. include_path.
bin_ini_default() { # bin key [args...]
  local b=$1 k=$2; shift 2
  "$b" -n "$@" -i 2>/dev/null | awk -F' => ' -v k="$k" '$1 == k && !f { print $2; f = 1 }'
}

info_get() { # X.Y key [file]
  local f=${3:-$(vdir "$1")/build.info}
  [[ -f $f ]] && awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$f"
  return 0
}

# Space list -> sorted unique space list (lower case).
set_norm() { tr ',[:upper:]' ' [:lower:]' <<<"$*" | tr -s ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
set_csv() { set_norm "$@" | tr ' ' ','; }
set_has() { [[ " $1 " == *" $2 "* ]]; } # set name

# The extension set to build: PHP_BUILD_EXTS, else the set setup.sh wrote,
# else the current build's.  Never guessed: without one the build refuses.
want_exts() { # X.Y
  local w=${PHP_BUILD_EXTS:-}
  [[ -n $w ]] || { [[ -s $(vdir "$1")/exts.want ]] && w=$(<"$(vdir "$1")/exts.want"); }
  [[ -n $w ]] || w=$(info_get "$1" exts)
  [[ -n $w ]] || die "no extension set for PHP $1 (ROOT/$1/exts.want): run setup.sh --optimize or --php"
  set_norm "$w"
}

# The process of the unit's main PID runs this version's php-fpm.
unit_runs_build() { # X.Y
  local pid exe
  pid=$(systemctl show -p MainPID --value "php$1-fpm.service" 2>/dev/null || true)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  [[ ${exe%" (deleted)"} == "$(vdir "$1")/sbin/php-fpm"* ]]
}

# Our own unit (written by setup.sh's php_build_layout), not Sury's.
unit_is_ours() { # X.Y
  local f
  f=$(unit_file "$1")
  [[ -f $f ]] && grep -q '^# Managed by setup.sh' "$f" && grep -q "^ExecStart=$(vdir "$1")/sbin/php-fpm " "$f"
}

# ---------------------------------------------------------------- versions
# Local additions to build-common's lookups: the newest PHP series, SQLite
# (sqlite.org) and ICU (unicode-org).  The originals keep serving every
# other component.
eval "bc_$(declare -f latest_of)"
eval "bc_$(declare -f fetch_component)"

# The newest released PHP version on php.net (the per-major JSON), then the
# highest php-X.Y.Z tag of php-src (never a pre-release: the tag regex has
# no suffix).
php_newest_release() {
  local json v=""
  if json=$(http_get "https://www.php.net/releases/?json" 2>/dev/null); then
    v=$(json_eval 'my @v; if (ref $d eq "HASH") { for my $k (keys %$d) { my $x = ref $d->{$k} eq "HASH" ? $d->{$k}{version} // "" : ""; push @v, $x if $x =~ /^\d+\.\d+\.\d+$/ } }
      @v = sort { my @a = split /\./, $a; my @b = split /\./, $b; $a[0] <=> $b[0] || $a[1] <=> $b[1] || $a[2] <=> $b[2] } @v; print $v[-1] if @v;' "$json")
  fi
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || v=$(git_latest php/php-src '^php-([0-9]+\.[0-9]+\.[0-9]+)$')
  [[ -n $v ]] && printf '%s' "$v"
}

# sqlite.org's download page carries one machine-readable line per product:
#   PRODUCT,3.47.2,2024/sqlite-autoconf-3470200.tar.gz,<bytes>,<SHA3-256>
sqlite_download_line() {
  http_get https://www.sqlite.org/download.html 2>/dev/null \
    | grep -oE 'PRODUCT,[0-9]+\.[0-9]+\.[0-9]+,[0-9]{4}/sqlite-autoconf-[0-9]+\.tar\.gz,[0-9]+,[0-9a-f]{64}' | sed -n 1p || true
}
sqlite_number() { # 3.47.2 -> 3470200
  local a b c
  IFS=. read -r a b c <<<"$1"
  printf '%d%02d%02d00' "$a" "$b" "${c:-0}"
}
# The year directory of a release: the download page for the newest one,
# the chronology page (release date next to its release-log link) otherwise.
sqlite_year() { # version
  local v=$1 line
  line=$(sqlite_download_line)
  if [[ $line == PRODUCT,"$v",* ]]; then cut -d, -f3 <<<"$line" | cut -d/ -f1; return 0; fi
  http_get https://www.sqlite.org/chronology.html 2>/dev/null \
    | V=$v perl -0777 -ne 'my $v = $ENV{V}; (my $u = $v) =~ tr/./_/; print $1 if /(\d{4})-\d\d-\d\d(?:(?!\d{4}-\d\d-\d\d).){0,400}?releaselog\/\Q$u\E\.html/s' 2>/dev/null || true
}

latest_of() {
  local v=""
  case $1 in
    sqlite)
      v=$(sqlite_download_line | cut -d, -f2)
      [[ -n $v ]] || v=$(git_latest sqlite/sqlite '^version-([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    icu)
      # Tags release-76-1 up to ICU 77; ICU 78 moved to release-78.1 (with
      # the asset rename below).  Both forms, normalised to 76.1 BEFORE the
      # sort, so a mixed list orders by version, not by separator.
      v=$(git ls-remote --tags --refs https://github.com/unicode-org/icu.git 2>/dev/null \
        | awk '{ sub("refs/tags/", "", $2); print $2 }' \
        | sed -nE 's/^release-([0-9]+)[-.]([0-9]+)$/\1.\2/p' | sort -V | tail -n 1 || true) ;;
    *) bc_latest_of "$@"; return ;;
  esac
  [[ -n $v ]] && printf '%s' "$v"
}

fetch_component() { # name version -> path of the source archive
  local v=$2 c=$SRC_CACHE/src n y line sha3="" urls="" m arc tag
  FETCH_NAME=$1
  case $1 in
    sqlite)
      # The amalgamation tarball from sqlite.org and its two backup sites
      # (www2/www3 serve the same files).  sqlite.org publishes SHA3-256,
      # checked with openssl when the page lists this version; the file is
      # also pinned on first use like every file without a SHA-256.
      n=$(sqlite_number "$v")
      if [[ $BUILD_OFFLINE == 1 ]] && cached_ok "$c/sqlite-autoconf-$n.tar.gz"; then
        printf '%s' "$c/sqlite-autoconf-$n.tar.gz"; return 0
      fi
      y=$(sqlite_year "$v")
      [[ $y =~ ^[0-9]{4}$ ]] || die "cannot find the release year of SQLite $v on sqlite.org"
      line=$(sqlite_download_line)
      [[ $line == PRODUCT,"$v",* ]] && sha3=$(cut -d, -f5 <<<"$line")
      for m in www.sqlite.org www2.sqlite.org www3.sqlite.org; do urls+="https://$m/$y/sqlite-autoconf-$n.tar.gz "; done
      arc=$(fetch_first "$urls|$c/sqlite-autoconf-$n.tar.gz|")
      if [[ -n $sha3 ]] && openssl dgst -sha3-256 /dev/null >/dev/null 2>&1; then
        [[ $(openssl dgst -sha3-256 -r "$arc" | awk '{print $1}') == "$sha3" ]] \
          || { rm -f "$arc"; die "sqlite-autoconf-$n.tar.gz: SHA3-256 differs from sqlite.org's download page"; }
      fi
      printf '%s' "$arc" ;;
    icu)
      # GitHub is ICU's release home.  ICU 78 changed both the tag
      # (release-78.1) and the asset (icu4c-78.1-sources.tgz); older
      # releases use release-76-1 and icu4c-76_1-src.tgz.  The likely form
      # for the major is tried first, the other as the fallback, so a release
      # that keeps one old spelling still downloads.  A pin may be written
      # 76.1, 76-1 or 76_1.
      v=${v//[-_]/.}
      local maj=${v%%.*} t1 t2 a1 a2 base=https://github.com/unicode-org/icu/releases/download
      local -a srcs=()
      if [[ $maj =~ ^[0-9]+$ ]] && (( maj >= 78 )); then
        t1="release-$v"; t2="release-${v//./-}"; a1="icu4c-$v-sources.tgz"; a2="icu4c-${v//./_}-src.tgz"
      else
        t1="release-${v//./-}"; t2="release-$v"; a1="icu4c-${v//./_}-src.tgz"; a2="icu4c-$v-sources.tgz"
      fi
      for tag in "$t1" "$t2"; do
        for arc in "$a1" "$a2"; do
          srcs+=("$base/$tag/$arc|$c/$arc|$(gh_digest unicode-org/icu "$tag" "$arc")")
        done
      done
      fetch_first "${srcs[@]}" ;;
    *) bc_fetch_component "$@" ;;
  esac
}

# Libraries a set links, in build order (curl needs OpenSSL and zlib; libpng
# and libzip need zlib).
libs_for() { # set
  local s=$1
  local -a l=("$ZLIB_IMPL" openssl pcre2 libxml2)
  set_has "$s" sodium && l+=(libsodium)
  set_has "$s" gmp && l+=(gmp)
  set_has "$s" iconv && l+=(libiconv)
  set_has "$s" curl && l+=(curl)
  set_has "$s" gd && l+=(libjpeg-turbo libpng libwebp)
  set_has "$s" zip && l+=(libzip)
  { set_has "$s" sqlite3 || set_has "$s" pdo_sqlite; } && l+=(sqlite)
  set_has "$s" intl && l+=(icu)
  printf '%s\n' "${l[@]}"
}

components_for() { # set
  local s=$1
  printf '%s\n' php llvm
  set_has "$s" redis && printf 'redis\n'
  set_has "$s" igbinary && printf 'igbinary\n'
  libs_for "$s"
}

# "name=version" for every component of SET: php-build.conf (pins, cached
# "latest"), or with EXACT the versions the current build recorded (a CPU
# rebuild never looks anything up).
resolve_set() { # X.Y set exact
  local ver=$1 s=$2 exact=${3:-0} c v rc=0
  local -a COMPONENTS
  mapfile -t COMPONENTS < <(components_for "$s")
  if (( exact )); then
    for c in "${COMPONENTS[@]}"; do
      v=$(info_get "$ver" "$c")
      if [[ -n $v ]]; then printf '%s=%s\n' "$c" "$v"; else printf '%s=?\n' "$c"; rc=1; fi
    done
    return "$rc"
  fi
  resolve_all "$ver"
}

# ---------------------------------------------------------------- build
# configure options of each buildable extension.  An unknown name stops the
# build: setup.sh validates names before they reach this list.
ext_flags() { # X.Y set deps
  local ver=$1 s=$2 deps=$3 e
  for e in $s; do
    case $e in
      bcmath)    printf '%s\n' --enable-bcmath ;;
      calendar)  printf '%s\n' --enable-calendar ;;
      ctype)     printf '%s\n' --enable-ctype ;;
      curl)      printf '%s\n' --with-curl ;;
      dom)       printf '%s\n' --enable-dom ;;
      exif)      printf '%s\n' --enable-exif ;;
      fileinfo)  printf '%s\n' --enable-fileinfo ;;
      filter)    printf '%s\n' --enable-filter ;;
      ftp)       printf '%s\n' --enable-ftp ;;
      gd)        printf '%s\n' --enable-gd --with-jpeg --with-webp ;;
      gettext)   printf '%s\n' --with-gettext ;;
      gmp)       printf '%s\n' "--with-gmp=$deps" ;;
      iconv)     printf '%s\n' "--with-iconv=$deps" ;;
      igbinary)  printf '%s\n' --enable-igbinary ;;
      intl)      printf '%s\n' --enable-intl ;;
      libxml)    printf '%s\n' --with-libxml ;;
      mbstring)  printf '%s\n' --enable-mbstring --disable-mbregex ;;
      mysqli)    printf '%s\n' --with-mysqli ;;
      mysqlnd)   printf '%s\n' --enable-mysqlnd ;;
      # Shared before 8.5 (PHP cannot build it static there), always
      # compiled in from 8.5 (the option is gone).
      opcache)   opcache_shared "$ver" && printf '%s\n' --enable-opcache ;;
      openssl)   printf '%s\n' --with-openssl ;;
      pcntl)     printf '%s\n' --enable-pcntl ;;
      pdo)       printf '%s\n' --enable-pdo ;;
      pdo_mysql) printf '%s\n' --with-pdo-mysql=mysqlnd ;;
      pdo_sqlite) printf '%s\n' --with-pdo-sqlite ;;
      phar)      printf '%s\n' --enable-phar ;;
      posix)     printf '%s\n' --enable-posix ;;
      redis)     printf '%s\n' --enable-redis; set_has "$s" igbinary && printf '%s\n' --enable-redis-igbinary ;;
      session)   printf '%s\n' --enable-session ;;
      shmop)     printf '%s\n' --enable-shmop ;;
      simplexml) printf '%s\n' --enable-simplexml ;;
      soap)      printf '%s\n' --enable-soap ;;
      sockets)   printf '%s\n' --enable-sockets ;;
      sodium)    printf '%s\n' --with-sodium ;;
      sqlite3)   printf '%s\n' --with-sqlite3 ;;
      sysvmsg)   printf '%s\n' --enable-sysvmsg ;;
      sysvsem)   printf '%s\n' --enable-sysvsem ;;
      sysvshm)   printf '%s\n' --enable-sysvshm ;;
      tokenizer) printf '%s\n' --enable-tokenizer ;;
      xml)       printf '%s\n' --enable-xml ;;
      xmlreader) printf '%s\n' --enable-xmlreader ;;
      xmlwriter) printf '%s\n' --enable-xmlwriter ;;
      zip)       printf '%s\n' --with-zip ;;
      zlib)      printf '%s\n' --with-zlib ;;
      *) die "extension '$e' is not part of the build recipe (setup.sh --php ext= lists the buildable ones)" ;;
    esac
  done
  return 0
}

# Static libraries in DEPS, compiled from upstream with the toolchain in the
# environment.  HOT (ThinLTO) for the libraries XenForo page views run.
build_libs() { # deps work jobs log libs...
  local deps=$1 work=$2 j=$3 log=$4 name v src arch hot cold ld_hot ld_cold; shift 4
  hot="$BASE_FLAGS -flto=thin"; cold=$BASE_FLAGS
  ld_hot="-fuse-ld=lld -flto=thin $THINLTO"; ld_cold="-fuse-ld=lld"
  arch=linux-x86_64; [[ $(uname -m) == aarch64 ]] && arch=linux-aarch64
  for name in "$@"; do
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
        sqlite)
          # The amalgamation compiled directly (one translation unit, no
          # configure system to track): thread-safe, no run-time extension
          # loading (no dlopen from PHP code), the column metadata pdo_sqlite
          # uses for getColumnMeta(), FTS5, R*Tree and math functions as in
          # Debian's libsqlite3.  Cold: none of the three applications use it.
          # shellcheck disable=SC2086
          "$CC" $cold -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
            -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_RTREE=1 \
            -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -c sqlite3.c -o sqlite3.o
          mkdir -p "$deps/lib/pkgconfig" "$deps/include"
          rm -f "$deps/lib/libsqlite3.a"; "$AR" rcs "$deps/lib/libsqlite3.a" sqlite3.o
          install -m 644 sqlite3.h sqlite3ext.h "$deps/include/"
          # shellcheck disable=SC2016 # ${prefix} is pkg-config syntax
          printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: SQLite\nDescription: SQL database engine (setup.sh php-build)\nVersion: %s\nLibs: -L${libdir} -lsqlite3\nLibs.private: -lm\nCflags: -I${includedir}\n' \
            "$deps" "$v" > "$deps/lib/pkgconfig/sqlite3.pc" ;;
        icu)
          # Static ICU with its data compiled in (only for an explicit
          # ext=intl; see the header for the measured cost).
          cd source
          CFLAGS=$cold CXXFLAGS=$cold LDFLAGS=$ld_cold ./configure --prefix="$deps" \
            --disable-shared --enable-static --with-data-packaging=static \
            --disable-tests --disable-samples --disable-extras --disable-layoutex
          make -j"$j" && make install ;;
      esac
    ) >> "$log" 2>&1 || { tail -n 40 "$log" >&2; die "$name $v failed to build (log: $log)"; }
    rm -rf "$src"
  done
}

cmd_build() { # X.Y [exact]
  local ver=$1 exact=${2:-0} set work src stage dir key deps n j line log libs_csv
  local -A VERS=()
  local -a LIBS=() cfg=()
  need_root
  ver_supported "$ver" || die "PHP $ver is not supported (8.1 or newer)"
  [[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die "unsupported architecture $(uname -m)"
  set=$(want_exts "$ver")
  # Unknown names stop the build before anything is downloaded.
  ext_flags "$ver" "$set" /nonexistent >/dev/null
  mapfile -t LIBS < <(libs_for "$set")
  build_deprioritize
  mkdir -p "$SRC_CACHE/src" "$LOG_DIR"; chmod 700 "$SRC_CACHE"; chmod 750 "$LOG_DIR"
  build_space_check "$SRC_CACHE"
  # setup.sh passes the log it also appends the tool's messages to.
  log=${PHP_BUILD_LOG_FILE:-$LOG_DIR/php-$ver-$(date -u +%Y%m%d-%H%M%S).log}
  [[ -n ${PHP_BUILD_LOG_FILE:-} ]] || : > "$log"
  chmod 640 "$log"
  say "PHP $ver: building (log: $log)"
  # automake/libtool/bison/re2c: a Git tag snapshot (the fallback source)
  # needs its configure script and parsers generated.
  ensure_packages ca-certificates curl git xz-utils bzip2 make cmake nasm m4 perl \
    pkg-config autoconf automake libtool bison re2c build-essential
  while IFS='=' read -r key line; do
    [[ $line == "?" ]] && { if (( exact )); then die "build.info records no $key version: run rebuild"; else die "cannot resolve the $key version (offline? pin $(conf_key "$key") in $CONF)"; fi; }
    VERS[$key]=$line
  done < <(resolve_set "$ver" "$set" "$exact" || true)
  [[ ${VERS[php]:-} =~ ^${ver//./\\.}\.[0-9]+$ ]] || die "PHP_VERSION=${VERS[php]:-?} is not a released PHP $ver version (X.Y.Z, no RC)"
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  if (( exact )); then llvm_use_recorded "$n" "clang-$n" "lld-$n" "llvm-$n"; else llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"; fi
  export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
  # -fPIE, not -fPIC: everything ends up in one executable.  -fPIC (1.21.68)
  # reached PHP's executor globals through the GOT on every access.
  # (libtool still compiles opcache.so's objects -fPIC.)
  BASE_FLAGS="-O3 -march=native -mtune=native -pipe -fPIE -fno-semantic-interposition"
  # Ubuntu's own hardening, always (its gcc enables these by default;
  # upstream clang does not): stack protector, stack-clash probes,
  # FORTIFY_SOURCE=3, CET/BTI landing pads, full RELRO.  Measured cost
  # 0.5-2 % before BOLT (1.21.70).
  BASE_FLAGS+=" -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
  if [[ $(uname -m) == x86_64 ]]; then BASE_FLAGS+=" -fcf-protection=full"; else BASE_FLAGS+=" -mbranch-protection=standard"; fi
  HARD_LD="-Wl,-z,relro,-z,now"
  # Unused code and data dropped, identical functions folded (safe ICF).
  BASE_FLAGS+=" -ffunction-sections -fdata-sections"
  GC_LD="-Wl,--gc-sections -Wl,--icf=safe"
  # Memory-aware job count; lld's ThinLTO backend capped to the same.
  j=$(build_jobs)
  THINLTO=$(build_thinlto_flag "$j")
  work=$(mktemp -d "$SRC_CACHE/build-$ver.XXXXXX")
  WORK_DIR=$work
  # The trap reads globals only: with SETUP_BUILD_LOCK_HELD=1 (the CPU chain,
  # the migration) cmd_build runs in the script's own shell, so the EXIT
  # trap fires after main returned, when cmd_build's locals are gone; under
  # set -u a local there failed a successful build with status 1.
  BUILD_LOG_PREFIX="php-$ver-"
  # PHP_BUILD_KEEP_WORK=1 keeps the work directory (sources, candidate) for
  # debugging.  The log lives in LOG_DIR either way (kept on failure).
  if [[ ${PHP_BUILD_KEEP_WORK:-0} == 1 ]]; then
    trap 'build_log_keep "${LOG_DIR:-}" "${BUILD_LOG_PREFIX:-php-}" || true' EXIT
  else
    trap 'rm -rf "${WORK_DIR:-}"; build_log_keep "${LOG_DIR:-}" "${BUILD_LOG_PREFIX:-php-}" || true' EXIT
  fi

  # Libraries: cached per (toolchain, flags, CPU, versions); a PHP-only
  # update reuses them.  The CPU is part of the key: -march=native objects
  # of another CPU must never be linked after a hardware change.
  key=$( { printf 'recipe=%s\nllvm=%s\nflags=%s\ncpu=%s\n' "$LIB_RECIPE" "$n" "$BASE_FLAGS" "$(cpu_fingerprint)"; for line in "${LIBS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done; } | sha256sum | cut -c1-16)
  deps=$SRC_CACHE/deps-$key
  if [[ ! -f $deps/.done ]]; then
    rm -rf "$deps"; mkdir -p "$deps"
    say "building ${LIBS[*]} with clang $n"
    build_libs "$deps" "$work" "$j" "$log" "${LIBS[@]}"
    touch "$deps/.done"
  fi
  # pkg-config searches $deps only.  glibc comes from Ubuntu; libsystemd is
  # replaced by the sd_notify shim.
  sdnotify_shim "$deps" "$BASE_FLAGS -flto=thin"

  src=$work/php
  fetch_unpack php "${VERS[php]}" "$src"
  set_has "$set" igbinary && fetch_unpack igbinary "${VERS[igbinary]}" "$src/ext/igbinary"
  set_has "$set" redis && fetch_unpack redis "${VERS[redis]}" "$src/ext/redis"
  # PHP 8.5 dropped ext/standard/php_smart_string.h, which only ever
  # included Zend's header; igbinary 3.2.16 still includes it (Sury patches
  # the same way).  Recreate the wrapper when the release lacks it.
  local h
  for h in php_smart_string php_smart_string_public; do
    [[ -f $src/ext/standard/$h.h ]] && continue
    printf '/* setup.sh php-build: compatibility wrapper (removed in PHP 8.5) */\n#include "zend_smart_string.h"\n' \
      > "$src/ext/standard/$h.h"
  done
  cd "$src"
  say "building PHP ${VERS[php]} (FPM + CLI) with clang $n: ${set// /,}"
  ./buildconf --force >> "$log" 2>&1 || { tail -n 20 "$log" >&2; die "buildconf failed (log: $log)"; }
  # Through a file, not a process substitution: an unknown name must stop
  # the build here, not just its subshell.
  ext_flags "$ver" "$set" "$deps" > "$work/configure-exts"
  mapfile -t cfg < "$work/configure-exts"
  # Libraries come from $deps only.  --sysconfdir makes a bare `php-fpm`
  # read /etc/php/X.Y/fpm/php-fpm.conf; the compiled php.ini path and scan
  # dir are the CLI's (the FPM unit passes -c and PHP_INI_SCAN_DIR).
  CFLAGS="$BASE_FLAGS -flto=thin ${PHP_BUILD_EXTRA_CFLAGS:-}" CXXFLAGS="$BASE_FLAGS -flto=thin ${PHP_BUILD_EXTRA_CFLAGS:-}" \
  LDFLAGS="-flto=thin -fuse-ld=lld $THINLTO -Wl,--emit-relocs $HARD_LD $GC_LD ${PHP_BUILD_EXTRA_LDFLAGS:-} -L$deps/lib" \
  CPPFLAGS="-I$deps/include" \
  PKG_CONFIG="pkg-config --static" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" \
  PKG_CONFIG_PATH="" PROG_SENDMAIL=/usr/sbin/sendmail \
  ./configure \
    --prefix="$ROOT/$ver" --sysconfdir="$PHP_ETC/$ver/fpm" --localstatedir=/var \
    --with-config-file-path="$PHP_ETC/$ver/cli" \
    --with-config-file-scan-dir="$PHP_ETC/$ver/cli/conf.d" \
    --disable-all --enable-cli --disable-cgi --disable-phpdbg --without-pear --disable-rpath \
    --without-valgrind \
    --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd \
    --with-external-pcre --with-mysql-sock="$MYSQL_SOCK" \
    "${cfg[@]}" \
    >> "$log" 2>&1 || { tail -n 30 "$log" >&2; install -m 640 config.log "$LOG_DIR/php-$ver-config-$(date -u +%Y%m%d-%H%M%S).log" 2>/dev/null || true; die "configure failed (log: $log; config.log copied to $LOG_DIR)"; }
  # Debian's include_path, compiled in (no php.ini line needed).
  sed -i -E "s|^#define[[:space:]]+PHP_INCLUDE_PATH[[:space:]].*|#define PHP_INCLUDE_PATH \"${INCLUDE_PATH}\"|" main/build-defs.h
  grep -qF "#define PHP_INCLUDE_PATH \"$INCLUDE_PATH\"" main/build-defs.h \
    || die "could not set PHP_INCLUDE_PATH in main/build-defs.h"
  # session.save_path defaults to the managed sessions directory even
  # without php.ini (the managed php.ini sets it too).
  # A release that renamed the entry only loses this default; the managed
  # php.ini still sets the path, so it is reported, not fatal.
  if set_has "$set" session; then
    sed -i -E "s|(PHP_INI_ENTRY\\(\"session\\.save_path\",[[:space:]]*)\"\"|\\1\"${SESSION_DIR}\"|" ext/session/session.c
    grep -qE "\"session\\.save_path\",[[:space:]]*\"$SESSION_DIR\"" ext/session/session.c \
      || say "PHP $ver: could not set the compiled session.save_path default (the managed php.ini sets it)"
  fi
  nice -n 10 make -j"$j" >> "$log" 2>&1 \
    || { tail -n 40 "$log" >&2; die "make failed (log: $log)"; }
  [[ -x sapi/fpm/php-fpm && -x sapi/cli/php ]] || die "make did not produce sapi/fpm/php-fpm and sapi/cli/php (log: $log)"
  if opcache_shared "$ver"; then [[ -f modules/opcache.so ]] || die "make did not produce modules/opcache.so (log: $log)"; fi

  # Stage the final (stripped) files, then verify exactly those: what is
  # verified is what activate swaps in.
  dir=$(vdir "$ver"); stage=$(stage_dir "$ver")
  install -d -m 755 "$dir"
  rm -rf "$stage.new"; install -d -m 755 "$stage.new/sbin" "$stage.new/bin" "$stage.new/lib" "$stage.new/share"
  install -m 755 sapi/fpm/php-fpm "$stage.new/sbin/php-fpm.lto"
  install_stripped sapi/fpm/php-fpm "$stage.new/sbin/php-fpm"
  install_stripped sapi/cli/php "$stage.new/bin/php"
  opcache_shared "$ver" && install_stripped modules/opcache.so "$stage.new/lib/opcache.so" && chmod 644 "$stage.new/lib/opcache.so"
  install -m 644 php.ini-production php.ini-development "$stage.new/share/"
  local oc="" jit
  opcache_shared "$ver" && oc=$stage.new/lib/opcache.so
  jit=$(verify_candidates "$ver" "$stage.new/sbin/php-fpm" "$stage.new/bin/php" "$oc" "$set" "$work") \
    || { rm -rf "$stage.new"; die "PHP $ver: the candidate failed verification (log: $log); nothing was staged"; }
  libs_csv=$(IFS=,; printf '%s' "${LIBS[*]}")
  {
    printf 'recipe=%s\n' "$BUILD_RECIPE"
    printf 'version=%s\n' "${VERS[php]}"
    printf 'series=%s\n' "$ver"
    while IFS= read -r line; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done < <(components_for "$set")
    printf 'exts=%s\n' "$(set_csv "$set")"
    printf 'libs=%s\n' "$libs_csv"
    printf 'opcache=%s\n' "$(opcache_shared "$ver" && echo shared || echo builtin)"
    printf 'jit=%s\n' "$jit"
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\n' "$(cpu_fingerprint)"
    printf 'cpu_info=%s\n' "$(cpu_fingerprint_text | tr '\n' ' ' | sed 's/ $//')"
    printf 'cflags=%s -flto=thin\n' "$BASE_FLAGS"
    printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bolt=0\n'
  } > "$stage.new/build.info"
  rm -rf "$stage"; mv "$stage.new" "$stage"
  # Keep only the library cache this build used.
  find "$SRC_CACHE" -maxdepth 1 -name 'deps-*' ! -name "deps-$key" -exec rm -rf {} + 2>/dev/null || true
  say "PHP $ver: ${VERS[php]} built from source with clang $n and verified; staged in $stage (activate swaps it in)"
}

# Module names in `-m` output, lower case, "zend opcache" as "opcache".
module_names() {
  grep -vE '^(\[.*\])?[[:space:]]*$' | tr '[:upper:]' '[:lower:]' | sed 's/^zend opcache$/opcache/' | sort -u
}

# Modules every build of X.Y carries whatever the set says (always on):
# random from 8.2, lexbor and uri from 8.5 (allowed there, never required:
# a future release may fold them).  cgi-fcgi is FPM's own SAPI module.
core_required() { # X.Y
  printf '%s\n' core date hash json pcre reflection spl standard
  ver_ge "$1" 8.2 && printf 'random\n'
  return 0
}
core_allowed() { # X.Y sapi
  ver_ge "$1" 8.5 && printf '%s\n' lexbor uri
  [[ $2 == fpm ]] && printf 'cgi-fcgi\n'
  return 0
}

# A candidate must be a release of X.Y, start without a warning, carry
# exactly the set plus the version's core in each SAPI (pcntl only in the
# CLI), have OPcache (before 8.5 through the candidate's own opcache.so),
# Debian's compiled-in defaults, link none of the libraries it builds from
# Ubuntu, run a phar through the CLI, and accept an FPM configuration.
# Prints jit=1/0 (the JIT is reported, not required: a site runs without
# it).
verify_candidates() { # X.Y fpm cli opcache.so set work
  local ver=$1 fpm=$2 cli=$3 oc=$4 set=$5 work=$6 sapi bin cv out got want allowed m extra needed f
  local -a ocd=()
  [[ -n $oc ]] && ocd=(-d "zend_extension=$oc")
  for sapi in fpm cli; do
    bin=$fpm; [[ $sapi == cli ]] && bin=$cli
    cv=$(bin_version "$bin") || die "$sapi candidate does not report a PHP version"
    [[ ${cv%.*} == "$ver" ]] || die "$sapi candidate is PHP $cv, not a PHP $ver release"
    out=$("$bin" -n "${ocd[@]}" -m 2>&1) || die "$sapi candidate fails to start: $(printf '%s' "$out" | sed -n 1p)"
    if grep -qiE 'warning|error|unable to|already loaded' <<<"$out"; then
      grep -iE 'warning|error|unable to|already loaded' <<<"$out" | head -n 5 >&2 || true
      die "$sapi candidate starts with warnings"
    fi
    got=$(module_names <<<"$out")
    want=$( { core_required "$ver"; for m in $set; do
              [[ $sapi == fpm ]] && set_has "$CLI_ONLY_EXTS" "$m" && continue
              printf '%s\n' "$m"; done; } | sort -u)
    for m in $want; do
      grep -qxF "$m" <<<"$got" || die "$sapi candidate lacks the $m module"
    done
    # Allowed: the whole set (a CLI-only extension that a release also
    # builds into FPM is harmless) and the version's optional core.
    allowed=$( { printf '%s\n' "$want" $set; core_allowed "$ver" "$sapi"; } | sort -u)
    extra=$(grep -vxF -f <(printf '%s\n' "$allowed") <<<"$got" || true)
    [[ -z $extra ]] || die "$sapi candidate has modules outside the set: $(tr '\n' ' ' <<<"$extra")"
  done
  # Debian's compiled-in defaults (1.21 took them from the package binary).
  [[ $(bin_ini_default "$cli" include_path) == "$INCLUDE_PATH" ]] || die "candidate include_path is not $INCLUDE_PATH"
  if set_has "$set" mysqli; then
    [[ $(bin_ini_default "$cli" mysqli.default_socket) == "$MYSQL_SOCK" ]] || die "candidate mysqli.default_socket is not $MYSQL_SOCK"
  fi
  if set_has "$set" pdo_mysql; then
    [[ $(bin_ini_default "$cli" pdo_mysql.default_socket) == "$MYSQL_SOCK" ]] || die "candidate pdo_mysql.default_socket is not $MYSQL_SOCK"
  fi
  for f in "$fpm" "$cli" ${oc:+"$oc"}; do
    # A file readelf cannot read (no ELF header) has no NEEDED entries; under
    # pipefail its status must not end the verify without a message.
    needed=$(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }') || needed=""
    if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
      die "${f##*/} links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')instead of the upstream builds"
    fi
    ! ldd "$f" 2>/dev/null | grep -q 'not found' || die "${f##*/} has unresolved libraries"
  done
  # wp-cli and composer are phar archives: the CLI must run one.
  if set_has "$set" phar; then
    out=$(cd "$work" && "$cli" -n -d phar.readonly=0 -r '$p = new Phar("setup-check.phar"); $p["i.php"] = "<?php echo \"phar-ok\";"; $p->setStub("<?php Phar::mapPhar(\"setup-check.phar\"); include \"phar://setup-check.phar/i.php\"; __HALT_COMPILER();");' 2>&1 \
      && "$cli" -n "$work/setup-check.phar" 2>&1) || true
    [[ $out == *phar-ok* ]] || die "the CLI candidate cannot run a phar archive: $(printf '%s' "$out" | sed -n 1p)"
  fi
  # FPM accepts a minimal configuration of its own (the live /etc/php tree
  # is tested by setup.sh's php_fpm_test once the layout is written).
  cat > "$work/fpm-test.conf" <<EOF
[global]
pid = $work/fpm-test.pid
error_log = $work/fpm-test.log
[setup-check]
user = www-data
group = www-data
listen = $work/fpm-test.sock
pm = static
pm.max_children = 1
EOF
  "$fpm" -n "${ocd[@]}" -t -y "$work/fpm-test.conf" >/dev/null 2>&1 || die "php-fpm candidate rejects a minimal configuration"
  if "$cli" -n "${ocd[@]}" -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M \
       -r '$s = opcache_get_status(false); exit(is_array($s) && !empty($s["jit"]["on"]) ? 0 : 1);' >/dev/null 2>&1; then
    printf '1'
  else
    say "PHP $ver: the OPcache JIT does not switch on in the candidate (sites run without it)"
    printf '0'
  fi
}

# Restart (a new binary needs one) and require the master to stay up.
restart_checked() {
  systemctl restart "php$1-fpm" || return 1
  sleep 2
  systemctl is-active --quiet "php$1-fpm"
}

# Swap SRC over DST atomically (rename in one directory tree), keeping the
# previous file as DST.prev (a hard link to the old inode) for a rollback.
swap_in() { # src dst
  [[ -e $2 ]] && ln -f "$2" "$2.prev"
  mv -f "$1" "$2"
}
swap_back() { # dst
  [[ -e $1.prev ]] && mv -f "$1.prev" "$1"
  return 0
}

# Put the staged build in place.  Order: opcache.so first, the binaries
# second (a crash restart between the two then loads a matching pair with
# the old binary at worst for one start; `pre` refuses load warnings), the
# BOLT input, the ini templates, build.info last.  A running unit of OURS is
# restarted (~100 ms for FPM; the socket is re-bound); one that is stopped
# stays stopped (the CPU chain or setup.sh starts it); a unit that is not
# ours (Sury's, during the migration) is never touched.
cmd_activate() {
  local ver=$1 dir stage f
  need_root
  dir=$(vdir "$ver"); stage=$(stage_dir "$ver")
  [[ -f $stage/build.info && -x $stage/sbin/php-fpm && -x $stage/bin/php ]] || die "no staged build for PHP $ver: run build"
  install -d -m 755 "$dir/sbin" "$dir/bin" "$dir/lib" "$dir/share"
  if [[ -f $stage/lib/opcache.so ]]; then swap_in "$stage/lib/opcache.so" "$dir/lib/opcache.so"; fi
  swap_in "$stage/bin/php" "$dir/bin/php"
  swap_in "$stage/sbin/php-fpm.lto" "$dir/sbin/php-fpm.lto"
  swap_in "$stage/sbin/php-fpm" "$dir/sbin/php-fpm"
  for f in "$stage"/share/*; do [[ -f $f ]] && mv -f "$f" "$dir/share/"; done
  swap_in "$stage/build.info" "$dir/build.info"
  rm -f "$dir/sbin/php-fpm.fdata"
  rm -rf "$stage"
  if unit_is_ours "$ver" && systemctl is-active --quiet "php$ver-fpm" 2>/dev/null; then
    if ! restart_checked "$ver"; then
      if [[ -e $dir/sbin/php-fpm.prev ]]; then
        for f in lib/opcache.so bin/php sbin/php-fpm.lto sbin/php-fpm build.info; do swap_back "$dir/$f"; done
        restart_checked "$ver" || say "PHP $ver: the previous build did not start again either (systemctl status php$ver-fpm)"
        die "PHP $ver did not start on the new build; the previous build is back"
      fi
      die "PHP $ver did not start on the new build (systemctl status php$ver-fpm)"
    fi
  fi
  rm -f "$dir"/lib/opcache.so.prev "$dir"/bin/php.prev "$dir"/sbin/php-fpm.prev "$dir"/sbin/php-fpm.lto.prev "$dir"/build.info.prev
  say "PHP $ver: $(info_get "$ver" version) active in $dir"
}

cmd_bolt() {
  local ver=$1 secs=${2:-60} dir base work perf p2b bolt samples n oc=""
  need_root
  dir=$(vdir "$ver"); base=$dir/sbin/php-fpm.lto
  [[ -x $base ]] || die "no build for PHP $ver: run build"
  unit_runs_build "$ver" || die "php$ver-fpm is not running the build"
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
    install_stripped "$base" "$dir/sbin/php-fpm.new"; mv -f "$dir/sbin/php-fpm.new" "$dir/sbin/php-fpm"
    sed -i 's/^bolt=.*/bolt=0/' "$dir/build.info"
    restart_checked "$ver" || die "PHP $ver did not restart on the LTO build"
  fi
  pgrep -f "^php-fpm: (master|pool)" >/dev/null || die "no php-fpm processes to sample"
  mkdir -p "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/bolt-$ver.XXXXXX")
  WORK_DIR=$work
  [[ ${PHP_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  # opcache.huge_code_pages stays on while sampling: the samples keep the
  # binary's addresses, and sampling with it off profiled the same functions
  # (2,549 vs 2,541) for the same speed (1.21.69).
  say "PHP $ver: sampling php-fpm for ${secs}s for BOLT"
  if ! "$perf" record -q -e cycles:u -j any,u -o "$work/perf.data" -a -- sleep "$secs" >/dev/null 2>&1; then
    die "perf could not record branch samples (no LBR on this CPU or VM?)"
  fi
  # perf2bolt fails ("Please rename the input binary", after listing the
  # binaries it did see) when php-fpm took no samples at all: an idle pool,
  # e.g. the post-domain optimize of a fresh install before any application
  # exists (1.22.0 fresh-install test).  That is too little traffic, not an
  # error.
  if ! "$p2b" -p "$work/perf.data" -o "$work/php-fpm.fdata" "$base" > "$work/p2b.log" 2>&1; then
    if grep -qE 'Please rename the input binary|no samples|0 out of [0-9]+ functions' "$work/p2b.log"; then
      say "PHP $ver: php-fpm took no samples in ${secs}s: too little traffic, BOLT skipped"
      return 3
    fi
    tail -n 5 "$work/p2b.log" >&2; die "perf2bolt failed"
  fi
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
  install_stripped "$work/php-fpm.bolt" "$work/php-fpm.final"
  # Verified as it will run: stripped, with the version's opcache.so.
  [[ -f $dir/lib/opcache.so ]] && oc=$dir/lib/opcache.so
  verify_candidates "$ver" "$work/php-fpm.final" "$dir/bin/php" "$oc" "$(set_norm "$(info_get "$ver" exts)")" "$work" >/dev/null
  install -m 600 "$work/php-fpm.fdata" "$dir/sbin/php-fpm.fdata"
  install -m 755 "$work/php-fpm.final" "$dir/sbin/php-fpm.new"
  mv -f "$dir/sbin/php-fpm.new" "$dir/sbin/php-fpm"
  if ! restart_checked "$ver"; then
    install_stripped "$base" "$dir/sbin/php-fpm.new"; mv -f "$dir/sbin/php-fpm.new" "$dir/sbin/php-fpm"
    restart_checked "$ver" || say "PHP $ver: the LTO build did not start either (systemctl status php$ver-fpm)"
    die "PHP $ver did not start on the BOLT binary; back on the LTO build"
  fi
  sed -i 's/^bolt=.*/bolt=1/' "$dir/build.info"
  say "PHP $ver: BOLT applied ($samples php-fpm functions profiled)"
}

cmd_build_activate() {
  cmd_build "$1"
  cmd_activate "$1"
  start_if_due "$1"
}

# The refresh path only (setup-php-build@X.Y): after a CPU change where the
# chain gave up (two failed attempts, unit down), the daily refresh sees the
# build as stale (cpu) and rebuilds it; nothing else would start the unit
# until an operator or a reboot did (R13: the refresh retry must recover).
# Same rule as the CPU chain's start: our unit, enabled, the active version.
# `activate` on its own never starts a stopped unit (--upgrade-php relies on
# that: its candidate must stay down until the switch).
start_if_due() { # X.Y
  local ver=$1
  unit_is_ours "$ver" || return 0
  [[ $(active_version) == "$ver" ]] || return 0
  [[ $(systemctl is-enabled "php$ver-fpm" 2>/dev/null || true) == enabled ]] || return 0
  systemctl is-active --quiet "php$ver-fpm" 2>/dev/null && return 0
  say "PHP $ver: php$ver-fpm was down; starting it on the rebuilt build"
  systemctl reset-failed "php$ver-fpm" >/dev/null 2>&1 || true
  systemctl start "php$ver-fpm" || die "PHP $ver: php$ver-fpm did not start on the rebuilt build (systemctl status php$ver-fpm)"
}

# setup-php-build@X.Y.service: build and activate under the lock, release
# it while the new workers serve real traffic, then BOLT (which only tries
# the lock: another build in progress skips it until the next refresh).
cmd_rebuild() {
  local ver=$1 active
  # The refresh queues only the active version.  A rebuild queued before an
  # --upgrade-php switch runs once the switch released the lock, when its
  # version is the kept, disabled rollback build: nothing to rebuild there
  # (the refresh never rebuilds inactive versions either), and its unit is
  # never started (start_if_due).
  active=$(active_version)
  if [[ -n $active && $active != "$ver" ]]; then
    say "PHP $ver: not the active version (PHP $active); rebuild skipped"
    return 0
  fi
  build_lock_run cmd_build_activate "$ver"
  sleep "${PHP_BUILD_BOLT_DELAY:-600}"
  bash "$SELF" bolt "$ver" "${PHP_BUILD_BOLT_SECONDS:-60}" || true
}

# setup-build-cpu.service's PHP stage: the exact versions build.info names,
# cached sources, the recorded LLVM, no network lookup, no BOLT.  The unit
# stays down until this succeeds; the chain starts it.
cmd_rebuild_cpu() {
  local ver=$1
  [[ -f $(vdir "$ver")/build.info ]] || die "no PHP $ver build to rebuild"
  # The recorded set too: a set change still pending (exts.want) may need
  # components build.info has no version of; the refresh applies it later.
  PHP_BUILD_EXTS=$(info_get "$ver" exts)
  [[ -n $PHP_BUILD_EXTS ]] || die "build.info of PHP $ver records no extension set: run rebuild"
  BUILD_OFFLINE=1
  cmd_build "$ver" 1
  cmd_activate "$ver"
}

# ExecStartPre of phpX.Y-fpm.service (runs as root before every start).
#  1. A purge or a crash between a purge and setup.sh's re-lay can leave the
#     unit without php-fpm.conf or php.ini (dpkg deletes conffiles whatever
#     they hold): restore every missing managed file from the copy setup.sh
#     keeps in ROOT/X.Y/etc-golden.
#  2. A Sury package upgrade still pending a purge can re-create its
#     mods-available symlinks in conf.d: moved to the backups.
#  3. CPU gate: a -march=native build on another CPU may SIGILL.  The unit
#     stays down (operator rule: no generic fallback) and only the serial
#     rebuild chain is started.
#  4. php-fpm -t of the live tree, and no load warnings.
cmd_pre() {
  local ver=$1 dir built now gold e f out d stamp sapi
  local -a tf=()
  dir=$(vdir "$ver"); e=$PHP_ETC/$ver; gold=$dir/etc-golden
  [[ -x $dir/sbin/php-fpm && -f $dir/build.info ]] || { say "PHP $ver: no compiled build in $dir"; exit 1; }
  if [[ -d $gold ]] && { [[ ! -f $e/fpm/php-fpm.conf ]] || [[ ! -f $e/fpm/php.ini ]]; }; then
    say "PHP $ver: managed files missing under $e; restoring them from $gold"
    while IFS= read -r f; do
      [[ -e $e/$f ]] && continue
      install -d -m 755 "$(dirname "$e/$f")"
      cp -p "$gold/$f" "$e/$f"
    done < <(cd "$gold" && find . -type f | sed 's|^\./||')
  fi
  stamp=$(date -u +%Y%m%d-%H%M%S)
  for sapi in fpm cli; do
    d=$e/$sapi/conf.d
    for f in "$d"/*; do
      [[ -L $f ]] || continue
      [[ $(readlink "$f") == *mods-available* ]] || continue
      install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/php-$ver-confd-$stamp"
      mv -f "$f" "$BACKUP_DIR/php-$ver-confd-$stamp/$sapi-${f##*/}"
      say "PHP $ver: moved package symlink $f to $BACKUP_DIR/php-$ver-confd-$stamp"
    done
  done
  built=$(info_get "$ver" cpu); now=$(cpu_fingerprint)
  if [[ -z $built || -z $now || $built != "$now" ]]; then
    logger -t "$LOG_TAG" "PHP $ver: built for CPU ${built:-unknown}, this CPU is ${now:-unknown}: php$ver-fpm stays down until setup-build-cpu.service rebuilt it" 2>/dev/null || true
    say "PHP $ver: the CPU changed since the build; php$ver-fpm stays down until setup-build-cpu.service has rebuilt it"
    systemctl start --no-block setup-build-cpu.service >/dev/null 2>&1 \
      || say "PHP $ver: setup-build-cpu.service could not be started; run: $0 rebuild-cpu $ver"
    exit 1
  fi
  # /run/php comes from the unit (RuntimeDirectory); the session
  # directories from tmpfiles, re-applied here in case a purge removed them.
  for f in /etc/tmpfiles.d/setup-php.conf /etc/tmpfiles.d/setup-php-pools.conf; do
    [[ -f $f ]] && tf+=("$f")
  done
  if (( ${#tf[@]} )); then systemd-tmpfiles --create "${tf[@]}" >/dev/null 2>&1 || true; fi
  out=$(PHP_INI_SCAN_DIR=$e/fpm/conf.d "$dir/sbin/php-fpm" -t -y "$e/fpm/php-fpm.conf" -c "$e/fpm/php.ini" 2>&1) \
    || { printf '%s\n' "$out" >&2; exit 1; }
  out+=$'\n'$(PHP_INI_SCAN_DIR=$e/fpm/conf.d "$dir/sbin/php-fpm" -c "$e/fpm/php.ini" -m 2>&1 || true)
  if grep -qiE 'unable to load|already loaded|cannot load|PHP (Warning|Fatal)' <<<"$out"; then
    grep -iE 'unable to load|already loaded|cannot load|PHP (Warning|Fatal)' <<<"$out" | head -n 5 >&2 || true
    say "PHP $ver: php-fpm prints load warnings with $e/fpm; refusing to start (fix conf.d, or run setup.sh --optimize)"
    exit 1
  fi
  return 0
}

# 0: current (recipe, CPU, extension set and every resolved version); 10:
# stale (the differences are printed); 2: a version could not be looked up.
cmd_check() {
  local ver=$1 name want have stale="" rc=0 recipe bcpu set hset
  [[ -f $(vdir "$ver")/build.info ]] || { echo "no build"; return 10; }
  [[ $(info_get "$ver" mode) == clang ]] && { echo "1.21 build (replaced by the 1.22 layout)"; return 10; }
  recipe=$(info_get "$ver" recipe)
  [[ ${recipe:-1} == "$BUILD_RECIPE" ]] || stale+="recipe ${recipe:-1} -> $BUILD_RECIPE, "
  bcpu=$(info_get "$ver" cpu)
  [[ -n $bcpu && $bcpu == "$(cpu_fingerprint)" ]] || stale+="cpu ${bcpu:-none} -> $(cpu_fingerprint), "
  set=$(want_exts "$ver" 2>/dev/null) || { echo "stale: no extension set recorded"; return 10; }
  hset=$(set_norm "$(info_get "$ver" exts)")
  [[ $set == "$hset" ]] || stale+="extensions ${hset// /,} -> ${set// /,}, "
  while IFS='=' read -r name want; do
    have=$(info_get "$ver" "$name")
    if [[ $want == "?" ]]; then rc=2; continue; fi
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_set "$ver" "$set" 0 || true)
  if [[ -n $stale ]]; then printf 'stale: %s\n' "${stale%, }"; return 10; fi
  if (( rc )); then echo "current as far as known (a version could not be looked up)"; return 2; fi
  echo current
}

active_version() {
  local v=""
  [[ -s $ACTIVE_FILE ]] && v=$(tr -d '[:space:]' < "$ACTIVE_FILE")
  valid_ver "$v" && [[ -x $(vdir "$v")/sbin/php-fpm ]] && printf '%s' "$v"
  return 0
}

# Daily (setup-build-refresh.service, under the build lock): recompute the
# extension set (detection only adds; lib/php-build.sh), then rebuild the
# ACTIVE version in the background when anything is stale.  Inactive
# versions (kept for one --upgrade-php rollback) are never rebuilt here.
cmd_refresh() {
  local ver out rc new old
  if declare -F migration_pending >/dev/null && migration_pending; then
    say "refresh skipped: the 1.22 migration is not finished"; return 0
  fi
  # A setup.sh run holds its run lock: --upgrade-php may be switching the
  # active version (it also holds the build lock from the build to the
  # commit), or --optimize is laying /etc/php out.  The chain refresh checks
  # the same; this covers a direct `php-build.sh refresh` (R65).
  if declare -F setup_run_active >/dev/null && setup_run_active; then
    say "refresh skipped: a setup.sh run is in progress"; return 0
  fi
  ver=$(active_version)
  [[ -n $ver ]] || return 0
  if [[ -f $LIB ]]; then
    new=$(PHP_BUILD_ROOT=$ROOT bash -c '. "$1"; php_build_effective_exts "$2"' _ "$LIB" "$ver" 2>/dev/null || true)
    old=""
    [[ -s $(vdir "$ver")/exts.want ]] && old=$(<"$(vdir "$ver")/exts.want")
    if [[ -n $new && $(set_norm "$new") != "$(set_norm "$old")" ]]; then
      printf '%s\n' "$(set_csv "$new")" > "$(vdir "$ver")/exts.want.new" && mv -f "$(vdir "$ver")/exts.want.new" "$(vdir "$ver")/exts.want"
      say "PHP $ver: extension set is now $(set_csv "$new") (was ${old:-unset}); rebuilding"
    fi
  fi
  rc=0; out=$(cmd_check "$ver") || rc=$?
  if (( rc == 10 )); then
    say "PHP $ver: $out; rebuilding in the background (setup-php-build@$ver.service); the running build keeps serving"
    systemctl start --no-block "setup-php-build@$ver.service" 2>/dev/null || true
  fi
  return 0
}

cmd_status() {
  local ver d cpu
  for d in "$ROOT"/*/build.info; do
    [[ -f $d ]] || continue
    ver=${d#"$ROOT"/}; ver=${ver%/build.info}
    valid_ver "$ver" || continue
    [[ -n ${1:-} && $1 != "$ver" ]] && continue
    if [[ $(info_get "$ver" mode) == clang ]]; then printf 'PHP %s: 1.21 build (php-fpm only), replaced by the next build\n' "$ver"; continue; fi
    cpu=match; [[ $(info_get "$ver" cpu) == "$(cpu_fingerprint)" ]] || cpu=CHANGED
    printf 'PHP %s: build %s (clang %s, recipe %s), bolt=%s, jit=%s, cpu=%s, running=%s, active=%s, exts=%s\n' "$ver" \
      "$(info_get "$ver" version)" "$(info_get "$ver" llvm)" "$(info_get "$ver" recipe)" "$(info_get "$ver" bolt)" \
      "$(info_get "$ver" jit)" "$cpu" "$(unit_runs_build "$ver" && echo yes || echo no)" \
      "$([[ $(active_version) == "$ver" ]] && echo yes || echo no)" "$(info_get "$ver" exts)"
  done
}

SELF=$(readlink -f "${BASH_SOURCE[0]}")

main() {
  local cmd=${1:-} ver=${2:-} rc v
  case $cmd in
    build|bolt|rebuild|rebuild-cpu|check|versions|activate|remove|pre|release)
      valid_ver "$ver" || die "usage: $0 $cmd X.Y" ;;
  esac
  case $cmd in
    build)       build_lock_run cmd_build "$ver" ;;
    activate)    build_lock_run cmd_activate "$ver" ;;
    bolt)        # Never waits for the lock.  Re-executed as its own process
                 # so errexit stays in force inside (a function called on the
                 # left of || runs without it).
                 if [[ ${SETUP_BUILD_LOCK_HELD:-0} == 1 ]]; then cmd_bolt "$ver" "${3:-60}"; return; fi
                 rc=0; build_lock_try bash "$SELF" bolt "$ver" "${3:-60}" || rc=$?
                 if (( rc == 75 )); then say "PHP $ver: BOLT skipped: build lock held"; return 3; fi
                 return "$rc" ;;
    rebuild)     cmd_rebuild "$ver" ;;
    rebuild-cpu) build_lock_run cmd_rebuild_cpu "$ver" ;;
    check)       cmd_check "$ver" ;;
    versions)    resolve_set "$ver" "$(want_exts "$ver")" 0 ;;
    series)      v=$(php_newest_release) || true; [[ -n ${v:-} ]] && printf '%s\n' "${v%.*}" ;;
    release)     v=$(latest_of php "$ver") || true; [[ ${v:-} =~ ^${ver//./\\.}\.[0-9]+$ ]] && printf '%s\n' "$v"; return 0 ;;
    pre)         cmd_pre "$ver" ;;
    refresh)     need_root; cmd_refresh ;;
    status)      cmd_status "${2:-}" ;;
    remove)      need_root; rm -rf "${ROOT:?}/${ver:?}" ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
  esac
}

if [[ ${PHP_BUILD_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
