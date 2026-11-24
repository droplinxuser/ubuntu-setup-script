#!/usr/bin/env bash
# Opt-in compiled php-fpm (SETUP_PHP_BUILD=clang or =lean), two modes:
#
# clang  The package's own PHP version with exactly the package's compiled-in
#        core, linked against Ubuntu's libraries like the package, so Sury's
#        shared extensions, php.ini, pools and conf.d load unchanged.  Only
#        the compiler (clang from apt.llvm.org, LLVM_VERSION), -O3
#        -march=native, ThinLTO and BOLT differ.  setup.sh loads only the
#        shared extensions the three applications need (lib/php-build.sh).
#
# lean   A php-fpm for WordPress, XenForo and Chevereto, from upstream
#        sources only: PHP from
#        php.net, redis and igbinary from PECL, and every library php-fpm
#        links (OpenSSL, PCRE2, zlib, libxml2, libsodium, GMP, curl, ICU,
#        libjpeg-turbo, libpng, libwebp, libzip) from the project's own
#        releases, at the versions in php-build.conf ("latest" by default),
#        compiled with the same flags (ThinLTO across PCRE2, zlib and
#        libxml2) and linked statically.  Only glibc, libstdc++ and
#        libsystemd come from Ubuntu.  The FPM SAPI only (no CLI, CGI or
#        phpdbg) and only what the three applications use: ctype curl dom
#        exif fileinfo filter gd(jpeg png webp) gmp iconv intl libxml
#        mbstring(no mbregex) mysqli/mysqlnd openssl pdo/pdo_mysql session
#        simplexml sodium xml xmlreader xmlwriter zip zlib, redis/igbinary
#        for the Redis caches, and the always-built core.  Images go
#        through GD (no ImageMagick).  No
#        shared extensions are loaded: conf.d is mirrored into
#        /run/setup-php-build/X.Y with its extension= lines commented out,
#        so php.ini, OPcache/JIT settings and pools stay the package's.
#
# Both modes leave the package's CLI (`php`) alone and change only the binary
# that systemd starts, through a drop-in:
#   /etc/systemd/system/php<X.Y>-fpm.service.d/zz-setup-build.conf
# After the site has served traffic, `bolt` samples php-fpm with perf (branch
# records) and rewrites the binary with LLVM BOLT.
#
# Safety: the package's binary stays at /usr/sbin/php-fpm<X.Y>.  The APT hook
# switches a version back to it when the package changes (clang) or becomes
# newer than the build (lean), and rebuilds in the background
# (setup-php-fpm-build@<X.Y>.service).  A daily timer rebuilds when LLVM, or
# for lean php.net, PECL or a library, publish a newer release.  A new build
# replaces the running one only after it passed every check.
#
# Usage (root):
#   php-fpm-build.sh build   X.Y [MODE] build + verify + activate (no BOLT);
#                                       MODE clang or lean, default: as built
#   php-fpm-build.sh bolt    X.Y [S]    sample S seconds (default 60) of live
#                                       traffic, BOLT, verify, activate
#   php-fpm-build.sh rebuild X.Y        build, activate, wait, then bolt (unit)
#   php-fpm-build.sh check   X.Y [MODE] exit 0 when the build is MODE with every
#                                       version php-build.conf asks for, 10 not
#   php-fpm-build.sh versions X.Y       the versions php-build.conf resolves to
#   php-fpm-build.sh activate X.Y       start the existing build again
#   php-fpm-build.sh deactivate X.Y     back to the package binary
#   php-fpm-build.sh remove  X.Y        deactivate and delete the build
#   php-fpm-build.sh conf    X.Y        mirror conf.d for a lean build
#   php-fpm-build.sh apt-hook           revert/rebuild after package changes
#   php-fpm-build.sh refresh            rebuild versions with a newer release
#   php-fpm-build.sh status [X.Y]       one line per version
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
# apt.llvm.org signing key (Sylvestre Ledru, LLVM's APT archive).
LLVM_KEY_FPR=6084F3CF814B57C1CF12EFD515CF4D18AF4F7421
LLVM_KEYRING=${PHP_BUILD_LLVM_KEYRING:-/etc/apt/keyrings/setup-llvm.asc}
LLVM_SOURCES=${PHP_BUILD_LLVM_SOURCES:-/etc/apt/sources.list.d/setup-llvm.sources}
LLVM_PIN=${PHP_BUILD_LLVM_PIN:-/etc/apt/preferences.d/setup-llvm.pref}
# Functions of php-fpm that must carry samples before BOLT is worth it: an
# idle site gives a profile of the master loop only.  Full XenForo/WordPress
# load on the test host profiled ~2,300.
BOLT_MIN_FUNCS=${PHP_BUILD_BOLT_MIN_FUNCS:-300}
# Upstream lookups are cached this long (seconds): GitHub, PECL, php.net.
RESOLVE_TTL=${PHP_BUILD_RESOLVE_TTL:-3600}

# Bump LIB_RECIPE when a library's configure options change: it is part of
# the library cache key.
LIB_RECIPE=3
# Build order matters: curl needs OpenSSL and zlib, libpng and libzip zlib.
LIBS=(zlib openssl pcre2 libxml2 libsodium gmp curl icu libjpeg-turbo libpng libwebp libzip)
COMPONENTS=(php llvm redis igbinary "${LIBS[@]}")
# `-m` lines the build must show: what XenForo 2.3, WordPress and Chevereto
# 4.5 require (setup.sh's php_upgrade_app_requirements, Chevereto's
# integrity check, WordPress Site Health) and nothing else.  Images go
# through GD in all three (Chevereto with CHEVERETO_IMAGE_LIBRARY=gd), so no
# imagick/ImageMagick.
APP_MODULES=(Core ctype curl date dom exif fileinfo filter gd gmp hash iconv igbinary intl
  json libxml mbstring mysqli mysqlnd openssl pcre PDO pdo_mysql random Reflection redis session
  SimpleXML sodium SPL standard xml xmlreader xmlwriter zip zlib "Zend OPcache")
# Libraries php-fpm must NOT take from Ubuntu (they are linked statically).
STATIC_LIBS_RE='^(libssl|libcrypto|libxml2|libpcre2-8|libz|libicu[a-z0-9]*|libcurl|libsodium|libgmp|libjpeg|libpng16|libwebp|libsharpyuv|libzip|libonig)\.so'

say() { printf '%s\n' "$*"; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
die() { say "ERROR: $*" >&2; exit 1; }

valid_ver() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+$ ]]; }
pkg_bin() { printf '%s/php-fpm%s' "$SBIN" "$1"; }
dropin_path() { printf '%s/php%s-fpm.service.d/zz-setup-build.conf' "$UNIT_DIR" "$1"; }
build_dir() { printf '%s/%s' "$ROOT" "$1"; }
ver_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$2" ]]; } # $1 >= $2
conf_key() { local k=${1^^}; printf '%s_VERSION' "${k//-/_}"; }

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

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

ensure_packages() {
  local -a missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
  done
  (( ${#missing[@]} )) || return 0
  say "installing: ${missing[*]}"
  apt-get -o DPkg::Lock::Timeout=900 update -qq
  apt-get -o DPkg::Lock::Timeout=900 install -y --no-install-recommends "${missing[@]}" >/dev/null
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
  [[ $v == latest || $v =~ ^[0-9][0-9A-Za-z._+-]*$ ]] || die "$key='$v' in $CONF is neither latest nor a version"
  printf '%s' "$v"
}

http_get() { # url [out]: quiet, retried, bounded
  if [[ -n ${2:-} ]]; then
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 1800 -o "$2" "$1"
  else
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 120 "$1"
  fi
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
  [[ -n $c ]] && curl -fsI --connect-timeout 20 --max-time 60 -o /dev/null \
    "https://apt.llvm.org/$c/dists/llvm-toolchain-$c-$1/Release"
}

# The newest stable upstream version of a component.
latest_of() {
  local name=$1 x=${2:-} v="" n json
  case $name in
    php)
      json=$(http_get "https://www.php.net/releases/?json&version=$x") || return 1
      v=$(php -n -r '$d = json_decode($argv[1], true); echo is_array($d) ? ($d["version"] ?? "") : "";' "$json")
      [[ $v == "$x".* ]] || v="" ;;
    llvm)
      n=$(git_latest llvm/llvm-project '^llvmorg-([0-9]+)\.[0-9]+\.[0-9]+$')
      [[ $n =~ ^[0-9]+$ ]] || return 1
      # apt.llvm.org can trail a fresh release by a few days.
      if llvm_suite_ok "$n"; then v=$n
      elif llvm_suite_ok "$(( n - 1 ))"; then v=$(( n - 1 ))
      fi ;;
    redis|igbinary)
      v=$(http_get "https://pecl.php.net/rest/r/$name/allreleases.xml" \
        | grep -oE '<r><v>[0-9]+\.[0-9]+\.[0-9]+</v><s>stable</s>' \
        | sed -E 's#<r><v>([^<]+)</v>.*#\1#' | sort -V | tail -n 1) ;;
    openssl)  v=$(git_latest openssl/openssl '^openssl-([0-9]+\.[0-9]+\.[0-9]+)$') ;;
    pcre2)    v=$(git_latest PCRE2Project/pcre2 '^pcre2-([0-9]+\.[0-9]+)$') ;;
    zlib)     v=$(git_latest madler/zlib '^v([0-9]+\.[0-9]+(\.[0-9]+)*)$') ;;
    curl)     v=$(git_latest curl/curl '^curl-([0-9]+_[0-9]+_[0-9]+)$'); v=${v//_/.} ;;
    icu)      v=$(git_latest unicode-org/icu '^release-([0-9]+\.[0-9]+(\.[0-9]+)?)$') ;;
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
      json=$(http_get https://download.gnome.org/sources/libxml2/cache.json) || return 1
      v=$(php -n -r '$d = json_decode($argv[1], true); $v = array_keys($d[1]["libxml2"] ?? []);
        $v = array_filter($v, fn($x) => preg_match("/^\d+\.\d+\.\d+$/", $x)); usort($v, "version_compare"); echo end($v) ?: "";' "$json") ;;
    gmp)
      v=$(http_get https://ftp.gnu.org/gnu/gmp/ | grep -oE 'gmp-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' \
        | sed -E 's/^gmp-|\.tar\.xz$//g' | sort -V | tail -n 1) ;;
    *) return 1 ;;
  esac
  [[ -n $v ]] && printf '%s' "$v"
}

# The version php-build.conf asks for (pin or cached "latest").
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
  [[ -n $v ]] || return 1
  mkdir -p "$SRC_CACHE/resolve"
  printf '%s' "$v" > "$cache"
  printf '%s' "$v"
}

# Every component as "name=version" lines; status 1 when one cannot be
# resolved (offline, upstream down).
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
# Trust on first use for a file without a published checksum (PECL,
# libpng/libwebp tag archives, GMP): the same file name must always hash
# the same.
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

fetch_to() { # url file [sha256]: download unless the cached copy verifies
  local url=$1 out=$2 want=${3:-}
  if [[ -s $out && -n $want && $(sha256sum "$out" | awk '{print $1}') == "$want" ]]; then return 0; fi
  if [[ ! -s $out || -n $want ]]; then
    http_get "$url" "$out.part" || die "download failed: $url"
    mv -f "$out.part" "$out"
  fi
  if [[ -n $want ]]; then
    [[ $(sha256sum "$out" | awk '{print $1}') == "$want" ]] || { rm -f "$out"; die "${out##*/}: SHA-256 mismatch"; }
  else
    tofu_check "$out"
  fi
}

# A GitHub release asset, checked against the SHA-256 GitHub publishes for it.
gh_asset() { # repo tag asset-ERE -> path
  local repo=$1 tag=$2 re=$3 json line name url digest out
  local -a auth=()
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  json=$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 "${auth[@]}" \
    "https://api.github.com/repos/$repo/releases/tags/$tag") || die "GitHub has no release $tag of $repo"
  line=$(php -n -r '$d = json_decode($argv[1], true);
    foreach (($d["assets"] ?? []) as $a) { if (preg_match("/^" . $argv[2] . "$/", $a["name"])) {
      echo $a["name"], " ", $a["browser_download_url"], " ", preg_replace("/^sha256:/", "", $a["digest"] ?? ""); break; } }' "$json" "$re")
  read -r name url digest <<<"$line"
  [[ -n ${name:-} && -n ${url:-} ]] || die "$repo $tag has no asset matching $re"
  out=$SRC_CACHE/src/$name
  [[ ${digest:-} =~ ^[0-9a-f]{64}$ ]] || digest=""
  fetch_to "$url" "$out" "$digest"
  printf '%s' "$out"
}

# The php.net tarball of VERSION, checked against php.net's SHA-256.
fetch_php() {
  local version=$1 json want
  json=$(http_get "https://www.php.net/releases/?json&version=$version") || die "php.net is unreachable"
  want=$(php -n -r '$d = json_decode($argv[1], true);
    foreach (($d["source"] ?? []) as $s) { if (($s["filename"] ?? "") === "php-" . $argv[2] . ".tar.xz") { echo $s["sha256"] ?? ""; } }' "$json" "$version")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "php.net publishes no SHA-256 for php-$version.tar.xz"
  fetch_to "https://www.php.net/distributions/php-$version.tar.xz" "$SRC_CACHE/src/php-$version.tar.xz" "$want"
  printf '%s' "$SRC_CACHE/src/php-$version.tar.xz"
}

fetch_component() { # name version -> path of the source archive
  local v=$2 sum
  case $1 in
    php)       fetch_php "$v" ;;
    redis|igbinary)
      fetch_to "https://pecl.php.net/get/$1-$v.tgz" "$SRC_CACHE/src/$1-$v.tgz"
      printf '%s' "$SRC_CACHE/src/$1-$v.tgz" ;;
    openssl)   gh_asset openssl/openssl "openssl-$v" "openssl-${v//./\\.}\\.tar\\.gz" ;;
    pcre2)     gh_asset PCRE2Project/pcre2 "pcre2-$v" "pcre2-${v//./\\.}\\.tar\\.bz2" ;;
    zlib)      gh_asset madler/zlib "v$v" "zlib-${v//./\\.}\\.tar\\.xz" ;;
    curl)      gh_asset curl/curl "curl-${v//./_}" "curl-${v//./\\.}\\.tar\\.xz" ;;
    icu)       gh_asset unicode-org/icu "release-$v" 'icu4c-[0-9._]+-(src|sources)\.tgz' ;;
    libjpeg-turbo) gh_asset libjpeg-turbo/libjpeg-turbo "$v" "libjpeg-turbo-${v//./\\.}\\.tar\\.gz" ;;
    libzip)    gh_asset nih-at/libzip "v$v" "libzip-${v//./\\.}\\.tar\\.xz" ;;
    libsodium) gh_asset jedisct1/libsodium "$v-RELEASE" "libsodium-${v//./\\.}\\.tar\\.gz" ;;
    libpng)
      fetch_to "https://github.com/pnggroup/libpng/archive/refs/tags/v$v.tar.gz" "$SRC_CACHE/src/libpng-$v.tar.gz"
      printf '%s' "$SRC_CACHE/src/libpng-$v.tar.gz" ;;
    libwebp)
      fetch_to "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$v.tar.gz" "$SRC_CACHE/src/libwebp-$v.tar.gz"
      printf '%s' "$SRC_CACHE/src/libwebp-$v.tar.gz" ;;
    libxml2)
      sum=$(http_get "https://download.gnome.org/sources/libxml2/${v%.*}/libxml2-$v.sha256sum" \
        | awk -v f="libxml2-$v.tar.xz" '$2 == f { print $1 }')
      [[ $sum =~ ^[0-9a-f]{64}$ ]] || die "download.gnome.org publishes no SHA-256 for libxml2-$v"
      fetch_to "https://download.gnome.org/sources/libxml2/${v%.*}/libxml2-$v.tar.xz" "$SRC_CACHE/src/libxml2-$v.tar.xz" "$sum"
      printf '%s' "$SRC_CACHE/src/libxml2-$v.tar.xz" ;;
    gmp)
      fetch_to "https://ftp.gnu.org/gnu/gmp/gmp-$v.tar.xz" "$SRC_CACHE/src/gmp-$v.tar.xz"
      printf '%s' "$SRC_CACHE/src/gmp-$v.tar.xz" ;;
    *) die "unknown component $1" ;;
  esac
}

unpack() { # archive dir
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components=1
}

# ---------------------------------------------------------------- LLVM
# clang/lld (and BOLT) of major N from apt.llvm.org, never Ubuntu's archive.
# The source is pinned at priority 100, so it never replaces an Ubuntu
# package; the toolchain is installed with -t from its own suite.
llvm_install() { # major packages...
  local n=$1 c key fpr src pin; shift
  c=$(codename)
  [[ -n $c ]] || die "cannot read VERSION_CODENAME from /etc/os-release"
  llvm_suite_ok "$n" || die "apt.llvm.org has no LLVM $n for Ubuntu $c (set LLVM_VERSION in $CONF)"
  ensure_packages ca-certificates curl gnupg
  if ! gpg --show-keys --with-colons "$LLVM_KEYRING" 2>/dev/null | grep -q "^fpr:::::::::$LLVM_KEY_FPR:"; then
    key=$(mktemp)
    http_get https://apt.llvm.org/llvm-snapshot.gpg.key "$key" || { rm -f "$key"; die "cannot fetch the apt.llvm.org key"; }
    fpr=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | sed -n 1p)
    [[ $fpr == "$LLVM_KEY_FPR" ]] || { rm -f "$key"; die "apt.llvm.org key fingerprint is $fpr, expected $LLVM_KEY_FPR"; }
    install -d -m 755 "$(dirname "$LLVM_KEYRING")"
    install -m 644 "$key" "$LLVM_KEYRING"; rm -f "$key"
  fi
  src=$(printf '# Managed by setup.sh (PHP_BUILD=clang): LLVM %s for the compiled php-fpm.\nTypes: deb\nURIs: https://apt.llvm.org/%s/\nSuites: llvm-toolchain-%s-%s\nComponents: main\nSigned-By: %s\n' \
    "$n" "$c" "$c" "$n" "$LLVM_KEYRING")
  pin=$(printf '# Managed by setup.sh (PHP_BUILD=clang): apt.llvm.org never replaces Ubuntu packages.\nPackage: *\nPin: origin apt.llvm.org\nPin-Priority: 100\n')
  [[ -f $LLVM_PIN && $(cat "$LLVM_PIN") == "$pin" ]] || { install -d "$(dirname "$LLVM_PIN")"; printf '%s\n' "$pin" > "$LLVM_PIN"; }
  if [[ ! -f $LLVM_SOURCES || $(cat "$LLVM_SOURCES") != "$src" ]]; then
    printf '%s\n' "$src" > "$LLVM_SOURCES"
    apt-get -o DPkg::Lock::Timeout=900 update -qq
  fi
  local -a missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    say "installing from apt.llvm.org: ${missing[*]}"
    apt-get -o DPkg::Lock::Timeout=900 install -y --no-install-recommends \
      -t "llvm-toolchain-$c-$n" "${missing[@]}" >/dev/null || die "cannot install ${missing[*]} from apt.llvm.org"
  fi
  [[ -x /usr/lib/llvm-$n/bin/clang ]] || die "clang $n missing after install"
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
    rm -rf "$src"; unpack "$(fetch_component "$name" "$v")" "$src"
    say "building $name $v"
    (
      cd "$src"
      cmake_lib() {
        cmake -S . -B _b -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$deps" \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
          -DCMAKE_C_FLAGS="$cold" -DCMAKE_EXE_LINKER_FLAGS="$ld_cold" "$@"
        cmake --build _b -j "$j"
        cmake --install _b
      }
      case $name in
        zlib)
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --static
          make -j"$j" && make install ;;
        openssl)
          # openssldir is Ubuntu's: its openssl.cnf and the system CA store.
          # $cold is split on purpose: Configure takes compiler flags as words.
          # shellcheck disable=SC2086
          ./Configure "$arch" --prefix="$deps" --libdir=lib --openssldir=/usr/lib/ssl \
            no-shared no-tests no-docs no-apps no-legacy no-module enable-ec_nistp_64_gcc_128 $cold
          make -j"$j" build_libs && make install_dev ;;
        pcre2)
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --disable-shared --enable-static \
            --with-pic --enable-jit --disable-pcre2grep-libz --disable-pcre2grep-libbz2
          make -j"$j" && make install ;;
        libxml2)
          CFLAGS=$hot LDFLAGS=$ld_hot ./configure --prefix="$deps" --disable-shared --enable-static \
            --with-pic --without-python --without-zlib --without-lzma --without-icu \
            --without-readline --without-history --without-http --without-ftp --without-debug
          make -j"$j" && make install ;;
        libsodium)
          CFLAGS=$cold LDFLAGS=$ld_cold ./configure --prefix="$deps" --disable-shared --enable-static --with-pic
          make -j"$j" && make install ;;
        gmp)
          # Portable C: GMP's x86-64 assembly keeps jump tables of code
          # offsets in data, which BOLT cannot move (88 relocations with
          # LLVM 23).  GMP only serves push-notification crypto.
          CFLAGS=$cold LDFLAGS=$ld_cold ./configure --prefix="$deps" --disable-shared --enable-static --with-pic --disable-assembly
          make -j"$j" && make install ;;
        curl)
          # HTTP(S) only: XenForo's outbound requests (Guzzle).
          CFLAGS=$cold LDFLAGS=$ld_cold PKG_CONFIG="pkg-config --static" ./configure --prefix="$deps" \
            --disable-shared --enable-static --with-pic --with-openssl="$deps" --with-zlib="$deps" \
            --without-libpsl --without-brotli --without-zstd --without-nghttp2 --without-libidn2 \
            --without-librtmp --without-libssh2 --disable-ldap --disable-ldaps --disable-rtsp \
            --disable-dict --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
            --disable-smtp --disable-gopher --disable-mqtt --disable-smb --disable-ftp --disable-file \
            --disable-manual --disable-docs \
            --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --with-ca-path=/etc/ssl/certs
          make -j"$j" && make install ;;
        icu)
          cd source
          CFLAGS=$cold CXXFLAGS="$cold -std=c++17" LDFLAGS=$ld_cold ./configure --prefix="$deps" \
            --disable-shared --enable-static --with-data-packaging=static \
            --disable-tests --disable-samples --disable-extras --disable-layoutex
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

cmd_build_lean() {
  local ver=$1 pkg pkg_version ext_dir inc_path sess_path sock work src dir key deps n j line
  local -A VERS=()
  BUILD_MODE=lean
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
  ensure_packages ca-certificates curl git xz-utils bzip2 make cmake nasm m4 perl \
    pkg-config autoconf build-essential libsystemd-dev
  while IFS='=' read -r key line; do
    [[ $line == "?" ]] && die "cannot resolve the $key version (offline? pin $(conf_key "$key") in $CONF)"
    VERS[$key]=$line
  done < <(resolve_all "$ver" || true)
  [[ ${VERS[php]%.*} == "$ver" ]] || die "PHP_VERSION=${VERS[php]} is not a PHP $ver release"
  ver_ge "${VERS[php]}" "$pkg_version" || die "PHP_VERSION=${VERS[php]} is older than the package ($pkg_version)"
  n=${VERS[llvm]}
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  local llvm_bin=/usr/lib/llvm-$n/bin
  export CC=$llvm_bin/clang CXX=$llvm_bin/clang++ AR=$llvm_bin/llvm-ar RANLIB=$llvm_bin/llvm-ranlib NM=$llvm_bin/llvm-nm
  BASE_FLAGS="-O3 -march=native -mtune=native -pipe -fPIC -fno-semantic-interposition"
  j=$(nproc)
  mkdir -p "$SRC_CACHE/src"; chmod 700 "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/build-$ver.XXXXXX")
  WORK_DIR=$work; trap 'rm -rf "${WORK_DIR:-}"' EXIT

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
  # pkg-config searches $deps only; libsystemd (sd_notify for the unit) is
  # the one library taken from Ubuntu.
  ln -sf "$(pkg-config --variable=pcfiledir libsystemd)/libsystemd.pc" "$deps/lib/pkgconfig/libsystemd.pc"

  src=$work/php
  unpack "$(fetch_component php "${VERS[php]}")" "$src"
  unpack "$(fetch_component igbinary "${VERS[igbinary]}")" "$src/ext/igbinary"
  unpack "$(fetch_component redis "${VERS[redis]}")" "$src/ext/redis"
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
  CFLAGS="$BASE_FLAGS -flto=thin" CXXFLAGS="$BASE_FLAGS -flto=thin" \
  LDFLAGS="-flto=thin -fuse-ld=lld -Wl,--emit-relocs -L$deps/lib" \
  CPPFLAGS="-I$deps/include" \
  PKG_CONFIG="pkg-config --static" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" \
  PKG_CONFIG_PATH="" PROG_SENDMAIL=/usr/sbin/sendmail EXTENSION_DIR=$ext_dir \
  ./configure \
    --prefix=/usr \
    --with-config-file-path="/etc/php/$ver/fpm" \
    --with-config-file-scan-dir="$RUN_DIR/$ver" \
    --disable-all --disable-cli --disable-cgi --disable-phpdbg --without-pear \
    --without-valgrind --enable-session \
    --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd \
    --with-external-pcre --with-openssl --with-zlib --with-libxml --with-sodium \
    --enable-ctype --with-curl --enable-dom --enable-exif --enable-fileinfo --enable-filter \
    --enable-gd --with-jpeg --with-webp --with-gmp="$deps" --with-iconv --enable-intl \
    --enable-mbstring --disable-mbregex --with-mysqli --enable-mysqlnd --with-mysql-sock="$sock" \
    --enable-simplexml --enable-xml --enable-xmlreader --enable-xmlwriter --with-zip \
    --enable-pdo --with-pdo-mysql=mysqlnd \
    --enable-igbinary --enable-redis --enable-redis-igbinary \
    >> "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; die "configure failed"; }
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
  install -m 755 "$dir/php-fpm.lto" "$dir/php-fpm.new"
  mv -f "$dir/php-fpm.new" "$dir/php-fpm"
  {
    printf 'mode=lean\n'
    printf 'version=%s\n' "${VERS[php]}"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cflags=%s -flto=thin\n' "$BASE_FLAGS"
    printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bolt=0\n'
  } > "$dir/build.info.new"
  mv -f "$dir/build.info.new" "$dir/build.info"
  rm -f "$dir/php-fpm.fdata"
  activate "$ver"
  # Keep only what this build used.
  find "$SRC_CACHE" -maxdepth 1 -name 'deps-*' ! -name "deps-$key" -exec rm -rf {} + 2>/dev/null || true
  say "PHP $ver: lean php-fpm ${VERS[php]} built with clang $n and active (BOLT pending: run under traffic)"
}

# Mode "clang": the package's own PHP version with exactly the package's
# compiled-in core (Sury's), linked against Ubuntu's libraries like the
# package, so Sury's shared extensions, php.ini, pools and conf.d load
# unchanged.  Only the compiler (LLVM_VERSION from apt.llvm.org), -O3
# -march=native, ThinLTO and later BOLT differ.  Measured (1.21.68, LLVM 23,
# BOLT from mixed WordPress/XenForo/Chevereto traffic): XenForo members
# +6 %, Chevereto uncached +8 %, WordPress members -5 % (wide spread).
cmd_build_clang() {
  local ver=$1 pkg version ext_dir inc_path sess_path work src dir n flags ldflags
  BUILD_MODE=clang
  need_root
  pkg=$(pkg_bin "$ver")
  [[ -x $pkg ]] || die "$pkg missing: install php$ver-fpm first"
  [[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die "unsupported architecture $(uname -m)"
  version=$(bin_version "$pkg") || die "cannot read the PHP version of $pkg"
  ext_dir=$(bin_ini_default "$pkg" extension_dir)
  inc_path=$(bin_ini_default "$pkg" include_path)
  sess_path=$(bin_ini_default "$pkg" session.save_path)
  [[ -d $ext_dir ]] || die "cannot read the package's extension_dir"
  n=$(resolve llvm "$ver") || die "cannot resolve the LLVM version (offline? pin LLVM_VERSION in $CONF)"
  [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
  ensure_packages ca-certificates curl git xz-utils make pkg-config autoconf bison re2c build-essential \
    libxml2-dev libssl-dev libsodium-dev zlib1g-dev libpcre2-dev libsystemd-dev libacl1-dev libapparmor-dev
  llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
  local llvm_bin=/usr/lib/llvm-$n/bin
  export CC=$llvm_bin/clang CXX=$llvm_bin/clang++ AR=$llvm_bin/llvm-ar RANLIB=$llvm_bin/llvm-ranlib NM=$llvm_bin/llvm-nm
  mkdir -p "$SRC_CACHE/src"; chmod 700 "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/build-$ver.XXXXXX")
  WORK_DIR=$work; trap 'rm -rf "${WORK_DIR:-}"' EXIT
  src=$work/php
  unpack "$(fetch_php "$version")" "$src"
  cd "$src"
  flags="-O3 -march=native -mtune=native -pipe -fno-semantic-interposition -flto=thin"
  # Relocations are kept so `bolt` can rewrite this binary later.
  ldflags="-flto=thin -fuse-ld=lld -Wl,--emit-relocs"
  say "building php-fpm $version for PHP $ver with clang $n, Sury's core (log: $work/build.log)"
  CFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$ldflags" EXTENSION_DIR=$ext_dir ./configure \
    --prefix=/usr \
    --with-config-file-path="/etc/php/$ver/fpm" \
    --with-config-file-scan-dir="/etc/php/$ver/fpm/conf.d" \
    --with-libdir="lib/$(gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)" \
    --disable-all --disable-cli --disable-cgi --disable-phpdbg --without-pear \
    --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
    --with-fpm-systemd --with-fpm-acl --with-fpm-apparmor \
    --enable-filter --enable-session --with-libxml --with-openssl \
    --with-sodium --with-zlib --with-external-pcre --with-mhash \
    > "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; die "configure failed"; }
  # Debian patches two compiled-in defaults; take them from the package
  # binary so the build behaves the same without a php.ini line.
  sed -i -E "s|^#define[[:space:]]+PHP_INCLUDE_PATH[[:space:]].*|#define PHP_INCLUDE_PATH \"${inc_path//|/\\|}\"|" main/build-defs.h
  grep -qF "#define PHP_INCLUDE_PATH \"$inc_path\"" main/build-defs.h \
    || die "could not set PHP_INCLUDE_PATH in main/build-defs.h"
  if [[ -n $sess_path && $sess_path != "no value" ]]; then
    sed -i -E "s|(PHP_INI_ENTRY\\(\"session\\.save_path\",[[:space:]]*)\"\"|\\1\"${sess_path//|/\\|}\"|" ext/session/session.c
  fi
  nice -n 10 make -j"$(nproc)" >> "$work/build.log" 2>&1 \
    || { tail -n 40 "$work/build.log" >&2; die "make failed"; }
  verify_binary "$ver" sapi/fpm/php-fpm
  dir=$(build_dir "$ver")
  install -d -m 755 "$dir"
  install -m 755 sapi/fpm/php-fpm "$dir/php-fpm.lto.new"
  mv -f "$dir/php-fpm.lto.new" "$dir/php-fpm.lto"
  install -m 755 "$dir/php-fpm.lto" "$dir/php-fpm.new"
  mv -f "$dir/php-fpm.new" "$dir/php-fpm"
  {
    printf 'mode=clang\n'
    printf 'version=%s\nllvm=%s\n' "$version" "$n"
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cflags=%s\n' "$flags"
    printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bolt=0\n'
  } > "$dir/build.info.new"
  mv -f "$dir/build.info.new" "$dir/build.info"
  rm -f "$dir/php-fpm.fdata"
  rm -rf "${RUN_DIR:?}/$ver"
  activate "$ver"
  say "PHP $ver: php-fpm $version built with clang $n (Sury's core and extensions) and active (BOLT pending: run under traffic)"
}

# The mode of the existing build of VER (builds from before modes: lean).
build_mode() {
  local m
  m=$(info_get "$1" mode)
  printf '%s' "${m:-lean}"
}

valid_mode() { [[ ${1:-} == clang || ${1:-} == lean ]]; }

cmd_build() { # X.Y [clang|lean]; default: the mode of the existing build
  local ver=$1 mode=${2:-}
  [[ -n $mode ]] || mode=$(build_mode "$ver")
  valid_mode "$mode" || die "unknown mode '$mode' (clang or lean)"
  case $mode in
    clang) cmd_build_clang "$ver" ;;
    lean)  cmd_build_lean "$ver" ;;
  esac
}

# conf.d of the package with extension= lines commented out: everything
# XenForo needs is compiled in, nothing else is loaded.  Runs before every
# start and reload, so --optimize changes to conf.d apply as usual.
cmd_conf() {
  local ver=$1 out ini tmp
  out=$RUN_DIR/$ver
  install -d -m 755 "$out"
  tmp=$(mktemp -d "$RUN_DIR/.conf-$ver.XXXXXX")
  for ini in "$PHP_ETC/$ver/fpm/conf.d"/*.ini; do
    [[ -f $ini ]] || continue
    sed -E 's/^([[:space:]]*(zend_)?extension[[:space:]]*=)/; compiled in or not part of the lean XenForo build: \1/' \
      "$ini" > "$tmp/${ini##*/}"
  done
  chmod 644 "$tmp"/*.ini 2>/dev/null || true
  rm -f "$out"/*.ini
  mv -f "$tmp"/*.ini "$out"/ 2>/dev/null || true
  rmdir "$tmp"
}

# Verify a candidate for the mode being built or BOLTed (BUILD_MODE).
verify_binary() {
  case ${BUILD_MODE:-lean} in
    clang) verify_clang "$@" ;;
    *)     verify_lean "$@" ;;
  esac
}

# The INI and module view of a binary with the live configuration, minus the
# lines that legitimately differ (build host/date, memory counters, paths of
# the binary itself, the timezone database: the package reads the system
# tzdata, the build carries PHP's bundled copy of the same release).
bin_profile() {
  "$1" -i 2>/dev/null | grep ' => ' | grep -vE \
    '^(Build (Date|System|Provider)|System|PHP Version|Configure Command|Server API|Compiler|Architecture|"Olson" Timezone Database Version|Interned Strings (Used|Free) memory|Used memory|Free memory|Wasted memory|Cached (scripts|keys)|Max cached keys|Hits|Misses|Start time|Last restart time|Oom restarts|Hash keys restarts|Manual restarts|Interned Strings Buffer|_ |\$_SERVER|\$_ENV)' \
    | sed -E 's/[[:space:]]+$//'
  "$1" -m 2>/dev/null
}

# Mode clang: the package's version, exactly the package's modules and
# settings (Sury's extensions loaded from conf.d), and the live FPM
# configuration accepted.
verify_clang() {
  local ver=$1 cand=$2 pkg
  pkg=$(pkg_bin "$ver")
  [[ $(bin_version "$cand") == "$(bin_version "$pkg")" ]] \
    || die "candidate is PHP $(bin_version "$cand"), the package is $(bin_version "$pkg")"
  if ! diff <(bin_profile "$pkg") <(bin_profile "$cand") > /dev/null; then
    diff <(bin_profile "$pkg") <(bin_profile "$cand") | head -n 20 >&2 || true
    die "candidate differs from the package's php-fpm (modules or INI defaults)"
  fi
  "$cand" -t --fpm-config "/etc/php/$ver/fpm/php-fpm.conf" >/dev/null 2>&1 \
    || die "candidate rejects /etc/php/$ver/fpm/php-fpm.conf"
}

# Mode lean: a release of the installed X.Y no older than the package, starts
# without a warning, carries every module XenForo needs, gives every INI
# directive it shares with the package the package's value, links none of
# the libraries it builds from Ubuntu, and accepts the live FPM configuration.
verify_lean() {
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
    printf '# Managed by setup.sh (PHP_BUILD=%s): start the compiled php-fpm %s.\n' "$(build_mode "$ver")" "$(info_get "$ver" version)"
    printf '# php-fpm-build.sh deactivate %s goes back to the package.\n[Service]\n' "$ver"
    if [[ $(build_mode "$ver") == lean ]]; then
      printf 'ExecStartPre=%s conf %s\n' "$TOOL" "$ver"
    fi
    printf 'ExecStart=\n%s\n' "${exec/$pkg /$(build_dir "$ver")/php-fpm }"
    if [[ $(build_mode "$ver") == lean ]]; then
      printf 'ExecReload=\nExecReload=%s conf %s\n' "$TOOL" "$ver"
      [[ -n $reloads ]] && printf '%s\n' "$reloads"
    fi
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
  BUILD_MODE=$(build_mode "$ver")
  ensure_packages linux-tools-common "linux-tools-$(uname -r)" \
    || die "perf is not installable for kernel $(uname -r)"
  llvm_install "$n" "bolt-$n"
  perf=$(command -v perf) || die "perf not found"
  p2b=/usr/lib/llvm-$n/bin/perf2bolt; bolt=/usr/lib/llvm-$n/bin/llvm-bolt
  [[ -x $p2b && -x $bolt ]] || die "llvm-bolt/perf2bolt $n not found"
  # BOLT rewrites the relocated LTO base; the running binary must be that
  # base (not an earlier BOLT output) or the samples would not map.
  if [[ $(info_get "$ver" bolt) == 1 ]]; then
    install -m 755 "$base" "$dir/php-fpm.new"; mv -f "$dir/php-fpm.new" "$dir/php-fpm"
    sed -i 's/^bolt=.*/bolt=0/' "$dir/build.info"
    restart_checked "$ver" || die "PHP $ver did not restart on the LTO build"
  fi
  pgrep -f "^php-fpm: (master|pool)" >/dev/null || die "no php-fpm processes to sample"
  mkdir -p "$SRC_CACHE"
  work=$(mktemp -d "$SRC_CACHE/bolt-$ver.XXXXXX")
  WORK_DIR=$work; trap 'rm -rf "${WORK_DIR:-}"' EXIT
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
    -split-all-cold -split-eh -icf -use-gnu-stack > "$work/bolt.log" 2>&1 \
    || { tail -n 5 "$work/bolt.log" >&2; die "llvm-bolt failed"; }
  verify_binary "$ver" "$work/php-fpm.bolt"
  install -m 600 "$work/php-fpm.fdata" "$dir/php-fpm.fdata"
  install -m 755 "$work/php-fpm.bolt" "$dir/php-fpm.new"
  mv -f "$dir/php-fpm.new" "$dir/php-fpm"
  if ! restart_checked "$ver"; then
    install -m 755 "$base" "$dir/php-fpm.new"; mv -f "$dir/php-fpm.new" "$dir/php-fpm"
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

# 0: the build is the requested mode (default: its own) with every version
# php-build.conf resolves to; 10: it is not (the differences are printed);
# 2: a version could not be resolved.  A clang build follows the package's
# PHP version and LLVM_VERSION only.
cmd_check() {
  local ver=$1 mode=${2:-} line name want have stale="" rc=0 pv n
  [[ -f $(build_dir "$ver")/build.info ]] || { echo "no build"; return 10; }
  [[ -n $mode ]] || mode=$(build_mode "$ver")
  if [[ $(build_mode "$ver") != "$mode" ]]; then
    echo "stale: mode $(build_mode "$ver") -> $mode"; return 10
  fi
  if [[ $mode == clang ]]; then
    pv=$(bin_version "$(pkg_bin "$ver")" || true)
    [[ $(info_get "$ver" version) == "$pv" ]] || stale+="php $(info_get "$ver" version) -> ${pv:-none}, "
    if n=$(resolve llvm "$ver"); then
      [[ $(info_get "$ver" llvm) == "$n" ]] || stale+="llvm $(info_get "$ver" llvm) -> $n, "
    else
      rc=2
    fi
    if [[ -n $stale ]]; then printf 'stale: %s\n' "${stale%, }"; return 10; fi
    if (( rc )); then echo "current as far as known (LLVM could not be looked up)"; return 2; fi
    echo current; return 0
  fi
  while IFS='=' read -r name want; do
    have=$(info_get "$ver" "$name")
    if [[ $want == "?" ]]; then rc=2; continue; fi
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_all "$ver" || true)
  if [[ -n $stale ]]; then printf 'stale: %s\n' "${stale%, }"; return 10; fi
  if (( rc )); then echo "current as far as known (a version could not be looked up)"; return 2; fi
  echo current
}

# DPkg::Post-Invoke.  A package update that changed the package's version
# (clang: any change, its shared extensions must match; lean: newer than the
# build, a security release), or one that removed a library the build links,
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
    if [[ -n $want && -n $have ]] && { [[ $want == "$have" ]] || { [[ $(build_mode "$ver") == lean ]] && ver_ge "$have" "$want"; }; }; then
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
    printf 'PHP %s: %s build %s (clang %s), bolt=%s, active=%s, package %s\n' "$ver" \
      "$(build_mode "$ver")" "$(info_get "$ver" version)" "$(info_get "$ver" llvm)" "$(info_get "$ver" bolt)" \
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
    build)      cmd_build "$ver" "${3:-}" ;;
    bolt)       cmd_bolt "$ver" "${3:-60}" ;;
    rebuild)    cmd_rebuild "$ver" ;;
    check)      cmd_check "$ver" "${3:-}" ;;
    versions)   resolve_all "$ver" ;;
    activate)   need_root
                [[ -x $(build_dir "$ver")/php-fpm ]] || die "no PHP $ver build: run build"
                if [[ $(build_mode "$ver") == clang ]]; then
                  [[ $(info_get "$ver" version) == "$(bin_version "$(pkg_bin "$ver")")" ]] \
                    || die "the PHP $ver clang build is not the package's version: run build"
                else
                  ver_ge "$(info_get "$ver" version)" "$(bin_version "$(pkg_bin "$ver")")" \
                    || die "the PHP $ver build is older than the package: run build"
                fi
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
