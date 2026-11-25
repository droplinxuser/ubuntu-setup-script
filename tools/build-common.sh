# shellcheck shell=bash
# Shared by tools/php-fpm-build.sh, tools/nginx-build.sh (1.21.70) and
# tools/valkey-build.sh (1.21.71): messages, the apt.llvm.org/GitHub LLVM
# toolchain, upstream version lookups, downloads with a second source for
# every file plus the project's own mirror (setup-build-sources), checksums,
# unpacking and the static sd_notify shim.
# The sourcing tool defines LOG_TAG, SRC_CACHE, CONF, COMPONENTS and VERS.

# apt.llvm.org signing key (Sylvestre Ledru, LLVM's APT archive).
LLVM_KEY_FPR=6084F3CF814B57C1CF12EFD515CF4D18AF4F7421
LLVM_KEYRING=${PHP_BUILD_LLVM_KEYRING:-/etc/apt/keyrings/setup-llvm.asc}
LLVM_SOURCES=${PHP_BUILD_LLVM_SOURCES:-/etc/apt/sources.list.d/setup-llvm.sources}
LLVM_PIN=${PHP_BUILD_LLVM_PIN:-/etc/apt/preferences.d/setup-llvm.pref}
# LLVM from its GitHub release tarball when apt.llvm.org is unreachable.
LLVM_OPT=${PHP_BUILD_LLVM_OPT:-/opt/setup-llvm}
# Upstream lookups are cached this long (seconds): GitHub, PECL, php.net.
RESOLVE_TTL=${PHP_BUILD_RESOLVE_TTL:-3600}
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

# The CPU a -march=native build is tied to: vendor and model name.
cpu_model() {
  awk -F": " '/^vendor_id/ { v = $2 } /^model name/ { m = $2 } v != "" && m != "" { print v " " m; exit }' /proc/cpuinfo
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
        v=$(php -n -r '$d = json_decode($argv[1], true); echo is_array($d) ? ($d["version"] ?? "") : "";' "$json")
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
        v=$(php -n -r '$d = json_decode($argv[1], true); $v = array_keys($d[1]["libxml2"] ?? []);
          $v = array_filter($v, fn($x) => preg_match("/^\d+\.\d+\.\d+$/", $x)); usort($v, "version_compare"); echo end($v) ?: "";' "$json")
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
    nginx)
      v=$(http_get https://download.angie.software/files/ | grep -oE "nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz" \
        | sed -E "s/^nginx-|\.tar\.gz\$//g" | sort -V | tail -n 1)
      [[ -n $v ]] || v=$(git_latest webserver-llc/angie "^nginx-([0-9]+\.[0-9]+\.[0-9]+)\$") ;;
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

# The version an existing build of any PHP version recorded for NAME.
last_known() {
  local f v=""
  for f in "$ROOT"/*/build.info; do
    [[ -f $f ]] || continue
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
  else
    tofu_check "$out"
  fi
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
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  json=$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "${auth[@]}" \
    "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null) || return 0
  php -n -r '$d = json_decode($argv[1], true);
    foreach (($d["assets"] ?? []) as $a) { if (($a["name"] ?? "") === $argv[2]) { echo preg_replace("/^sha256:/", "", $a["digest"] ?? ""); break; } }' "$json" "$3" \
    | grep -E '^[0-9a-f]{64}$' || true
}

# A release tarball served by the project's site and by its GitHub release:
# the same file, checked against GitHub's digest (or SITE_SHA when given).
site_or_github() { # site-urls repo tag asset [site-sha]
  local sum
  sum=${5:-$(gh_digest "$2" "$3" "$4")}
  fetch_first "$1 https://github.com/$2/releases/download/$3/$4|$SRC_CACHE/src/$4|$sum"
}

fetch_component() { # name version -> path of the source archive
  local v=$2 c=$SRC_CACHE/src sum m urls=""
  FETCH_NAME=$1
  case $1 in
    php)
      # php.net (its SHA-256), then the php-src tag snapshot (pinned).
      local json
      json=$(http_get "https://www.php.net/releases/?json&version=$v" 2>/dev/null || true)
      sum=$(php -n -r '$d = json_decode($argv[1], true);
        foreach (($d["source"] ?? []) as $s) { if (($s["filename"] ?? "") === "php-" . $argv[2] . ".tar.xz") { echo $s["sha256"] ?? ""; } }' "${json:-null}" "$v" 2>/dev/null \
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
      [[ -n $sum ]] || sum=$(http_get "https://www.openssl.org/source/openssl-$v.tar.gz.sha256" 2>/dev/null | grep -oE '^[0-9a-f]{64}' || true)
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
      # download.angie.software, then the GitHub tag snapshot.
      fetch_first "https://download.angie.software/files/nginx-$v.tar.gz|$c/nginx-$v.tar.gz|" \
        "https://codeload.github.com/webserver-llc/angie/tar.gz/refs/tags/Angie-$v|$c/nginx-src-$v.tar.gz|" ;;
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
  src=$(printf '# Managed by setup.sh (PHP_BUILD=clang): LLVM %s for the compiled php-fpm.\nTypes: deb\nURIs: https://apt.llvm.org/%s/\nSuites: llvm-toolchain-%s-%s\nComponents: main\nSigned-By: %s\n' \
    "$n" "$c" "$c" "$n" "$LLVM_KEYRING")
  pin=$(printf '# Managed by setup.sh (PHP_BUILD=clang): apt.llvm.org never replaces Ubuntu packages.\nPackage: *\nPin: origin apt.llvm.org\nPin-Priority: 100\n')
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
