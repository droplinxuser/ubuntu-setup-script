#!/usr/bin/env bash
# Unit tests for the allocator options of the compiled builds
# (tools/build-common.sh, tools/nginx-build.sh, tools/php-build.sh):
#   - malloc_linked: a binary running on mimalloc is told apart from a glibc
#     one (stub binaries); mimalloc is the PHP build's only allocator;
#   - 1.22.5 removals (operator rule: an option that is not the fastest is
#     deleted): PHP_BUILD_MALLOC=glibc (3-4 % slower on uncached XenForo
#     pages, twice the PHP-FPM memory), PHP_BUILD_MALLOC=jemalloc
#     (below mimalloc on every tier) and nginx's MALLOC option (within noise
#     of glibc; nginx always links glibc's malloc).  A conf or env value
#     naming one warns once and the default is used; any other
#     PHP_BUILD_MALLOC value warns and builds on mimalloc (never a die, so
#     the daily refresh cannot loop on it); a build made with another
#     allocator is stale; the default keys (nginx tls_opts= of aws-lc, the
#     PHP library cache key with mimalloc) are pinned;
#   - OPENSSL_VERSION=lts (PHP side; nginx in t-nginx-build.sh) warns and
#     resolves like "latest"; PHP 8.1 keeps its newest-3.x resolution.
# No root, no network, no compiler: every tool is a fake script.
# Usage: bash tests/unit/t-build-alloc.sh
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  bash "${BASH_SOURCE[0]}"
  return
fi
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-test-build-alloc.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-build-alloc.sh,title=build allocator test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

# CODE with tools/build-common.sh sourced (no tool around it).
bc() {
  SRC_CACHE=$TMP/cache LOG_TAG=t-build-alloc bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR
    logger() { :; }; eval "$2"' _ "$ROOT" "$1" 2>&1
}

# ---------------------------------------------------------------------------
# malloc_linked (mimalloc is the only PHP allocator: no malloc_valid left)
# ---------------------------------------------------------------------------
check "build-common: no malloc_valid or MALLOC_EXPECTED left (one allocator, nothing to validate)" \
  bash -c '! grep -nE "malloc_valid|MALLOC_EXPECTED" "$1/tools/build-common.sh" "$1/tools/php-build.sh"' _ "$ROOT"

# A fake program: prints what the allocator KIND would print on stderr for
# the variables it is given, and records its arguments.
mk_bin() { # path kind
  cat > "$1" <<EOS
#!/bin/sh
printf '%s\n' "\$*" > "$1.args"
echo "nginx version: nginx/1.29.0" >&2
case $2 in
  mimalloc) [ -n "\${MIMALLOC_VERBOSE:-}" ] && echo "mimalloc: option 'show_errors': 0" >&2 ;;
esac
exit 0
EOS
  chmod 755 "$1"
}
mk_bin "$TMP/bin-mi" mimalloc
mk_bin "$TMP/bin-gl" glibc
check "malloc_linked: a mimalloc binary runs on mimalloc" bc "malloc_linked mimalloc '$TMP/bin-mi' -n -v"
check "malloc_linked: ... and passes the arguments (-n -v)" test "$(cat "$TMP/bin-mi.args")" = "-n -v"
check "malloc_linked: a glibc binary is not on mimalloc" not bc "malloc_linked mimalloc '$TMP/bin-gl' -v"
check "malloc_linked: jemalloc is never 'linked' (removed)" not bc "malloc_linked jemalloc '$TMP/bin-mi' -v"
check "mimalloc_linked stays as the mimalloc case of malloc_linked" bc "mimalloc_linked '$TMP/bin-mi' -v && ! mimalloc_linked '$TMP/bin-gl' -v"
printf '#!/bin/sh\nexit 3\n' > "$TMP/bin-bad"; chmod 755 "$TMP/bin-bad"
check "malloc_linked: a binary that fails silently is refused" not bc "malloc_linked mimalloc '$TMP/bin-bad' -v"

# ---------------------------------------------------------------------------
# The jemalloc plumbing is gone (Valkey's own bundled MALLOC=jemalloc stays)
# ---------------------------------------------------------------------------
check "build-common: no jemalloc builder, lookup or download (and no malloc_build dispatcher)" \
  bash -c '! grep -nE "jemalloc_build|^[[:space:]]+jemalloc\)|jemalloc/jemalloc|(^|[[:space:]])malloc_build|MALLOC_IMPLS" "$1"' _ "$ROOT/tools/build-common.sh"
check "build-common: latest_of jemalloc is an unknown component" not bc 'git_latest() { echo 5.3.0; }; latest_of jemalloc'
check "build-common: the mimalloc plumbing stays (builder, lookup, download)" \
  bash -c 'grep -q "^mimalloc_build()" "$1" && grep -q "mimalloc) v=\$(git_latest microsoft/mimalloc" "$1" && grep -q "github.com/microsoft/mimalloc/archive" "$1"' _ "$ROOT/tools/build-common.sh"
check "php: no jemalloc build case and no libjemalloc in STATIC_LIBS_RE" \
  bash -c '! grep -nE "jemalloc_build|libjemalloc" "$1" && ! grep -nA1 -E "^[[:space:]]+jemalloc\)[[:space:]]*$" "$1" | grep -vE "jemalloc\)|opt_removed|^--$" | grep -q .' _ "$ROOT/tools/php-build.sh"
check "nginx: no allocator code at all (no malloc_setup, MALLOC link, malloc_linked or malloc= record)" \
  bash -c '! grep -nE "malloc_setup|malloc_linked|\\\$MALLOC\b|malloc=%s" "$1"' _ "$ROOT/tools/nginx-build.sh"
check "valkey keeps its own bundled jemalloc" bash -c 'grep -qF "MALLOC=jemalloc" "$1"' _ "$ROOT/tools/valkey-build.sh"
check "conf files: no JEMALLOC_VERSION, no nginx MALLOC= or MIMALLOC_VERSION" \
  bash -c '! grep -qE "^(JEMALLOC_VERSION|MALLOC|MIMALLOC_VERSION)=" "$1/nginx-build.conf" && ! grep -q "^JEMALLOC_VERSION=" "$1/php-build.conf"' _ "$ROOT"
check "conf files: PHP_BUILD_MALLOC is mimalloc, with MIMALLOC_VERSION" \
  bash -c 'grep -qx "PHP_BUILD_MALLOC=mimalloc" "$1/php-build.conf" && grep -qx "MIMALLOC_VERSION=latest" "$1/php-build.conf"' _ "$ROOT"

# ---------------------------------------------------------------------------
# nginx: MALLOC removed (warn once, glibc; a non-glibc build is stale)
# ---------------------------------------------------------------------------
tnb() { # conf-text code
  local d=$TMP/ngx-$RANDOM
  mkdir -p "$d/root/build" "$d/cache"
  printf '%s\n' "$1" > "$d/nginx-build.conf"
  NGINX_BUILD_SOURCE_ONLY=1 NGINX_BUILD_ROOT="$d/root" NGINX_BUILD_CACHE="$d/cache" NGINX_BUILD_CONF="$d/nginx-build.conf" \
    NGINX_BUILD_UNIT_DIR="$d/units" SETUP_BUILD_MIRROR=off NGINX_BUILD_PIDFILE="$d/nginx.pid" \
    NGINX_BUILD_NGINX_CONF="$d/etc/nginx.conf" NGINX_BUILD_TMPFILES="$d/tmpfiles.conf" \
    bash -c 'source "$1/tools/nginx-build.sh"; set +eE; trap - ERR; logger() { :; }; eval "$2"' _ "$ROOT" "$2" 2>&1
}
out=$(tnb 'MALLOC=jemalloc' 'printf "loaded %s|%s\n" "${COMPONENTS[*]}" "$CONF_INVALID"')
check "nginx: MALLOC=jemalloc warns once that it was removed and uses glibc" \
  bash -c '[[ $(grep -c "WARNING: nginx: MALLOC=jemalloc was removed in 1.22.5 .*; using the default (glibc)" <<<"$1") == 1 ]]' _ "$out"
check "nginx: ... with no allocator component and nothing invalid (build and check go on)" \
  bash -c 'l=$(grep "^loaded" <<<"$1"); [[ $l == "loaded "*"|" && $l != *jemalloc* && $l != *mimalloc* ]]' _ "$out"
out=$(tnb 'MALLOC=mimalloc' 'echo loaded')
check "nginx: MALLOC=mimalloc warns the same way" bash -c '[[ $1 == *"MALLOC=mimalloc was removed in 1.22.5"* && $1 == *loaded* ]]' _ "$out"
out=$(NGINX_BUILD_MALLOC=jemalloc tnb '' 'echo loaded')
check "nginx: env NGINX_BUILD_MALLOC=jemalloc warns the same way" bash -c '[[ $1 == *"MALLOC=jemalloc was removed in 1.22.5"* && $1 == *loaded* ]]' _ "$out"
out=$(tnb 'MALLOC=tcmalloc' 'printf "invalid=[%s]\n" "$CONF_INVALID"')
check "nginx: any other MALLOC value is a removed key too, never an invalid value" \
  bash -c '[[ $1 == *"MALLOC=tcmalloc was removed in 1.22.5"* && $1 == *"invalid=[]"* ]]' _ "$out"
check "nginx: MALLOC=glibc (the old default line) draws no warning" test "$(tnb 'MALLOC=glibc' 'echo loaded')" = loaded
check "nginx: no conf line draws no warning" test "$(tnb '' 'echo loaded')" = loaded
ck() { # conf recorded-malloc -> cmd_check output
  tnb "$1" 'resolve_all() { :; }; cpu_fingerprint_matches() { return 0; }
    printf "recipe=%s\ntls_opts=%s\n%s" "$BUILD_RECIPE" "$(tls_key aws-lc)" "'"${2:+malloc=$2
}"'" > "$STATE/build.info"; ( cmd_check ); echo "rc=$?"'
}
check "nginx check: a jemalloc build is stale (rebuilt on glibc)" \
  bash -c '[[ $1 == *"malloc jemalloc -> glibc (removed in 1.22.5)"* && $1 == *rc=10* ]]' _ "$(ck "" jemalloc)"
check "nginx check: a mimalloc build is stale (rebuilt on glibc)" \
  bash -c '[[ $1 == *"malloc mimalloc -> glibc"* && $1 == *rc=10* ]]' _ "$(ck "" mimalloc)"
check "nginx check: ... even while the conf still says MALLOC=jemalloc (warning, no die)" \
  bash -c '[[ $1 == *"was removed in 1.22.5"* && $1 == *"malloc jemalloc -> glibc"* && $1 == *rc=10* ]]' _ "$(ck MALLOC=jemalloc jemalloc)"
check "nginx check: a recorded malloc=glibc is current" bash -c '[[ $1 == *current* && $1 == *rc=0* ]]' _ "$(ck "" glibc)"
check "nginx check: a pre-1.22.5 build.info (no malloc=) is current" bash -c '[[ $1 == *current* && $1 == *rc=0* ]]' _ "$(ck "" "")"
# The default build key: aws-lc's tls_opts= is byte-identical to the one
# every aws-lc build recorded since 1.22.2 (sha256 of "aws-lc"), so an
# aws-lc host is not rebuilt because options were deleted.
check "nginx: the default aws-lc tls_opts= key is unchanged (24760def2037b6f3)" \
  test "$(tnb '' 'tls_key "$TLS_LIB"')" = 24760def2037b6f3
check "nginx: ... and stays so with every removed option set" \
  test "$(tnb $'MALLOC=jemalloc\nBOLT_NOLBR=1\nTLS_LIB=openssl\nOPENSSL_VERSION=lts' 'tls_key "$TLS_LIB"' | tail -n 1)" = 24760def2037b6f3

# ---------------------------------------------------------------------------
# php: mimalloc is the only allocator (1.22.5).  PHP_BUILD_MALLOC=glibc and
# =jemalloc were removed (warn once, mimalloc); any other value warns and
# uses mimalloc, never dies; a glibc/jemalloc build (or one with no malloc=)
# is stale; a CPU rebuild of one builds mimalloc.
# ---------------------------------------------------------------------------
pt() { # PHP_BUILD_MALLOC code [conf-text]
  local d=$TMP/php-$RANDOM
  mkdir -p "$d/root"
  printf '%s\n' "${3:-}" > "$d/php-build.conf"
  PHP_BUILD_MALLOC=$1 PHP_BUILD_SOURCE_ONLY=1 PHP_BUILD_ROOT=$d/root PHP_BUILD_CACHE=$d/cache PHP_BUILD_CONF=$d/php-build.conf \
    bash -c 'source "$1/tools/php-build.sh"; set +eE; trap - ERR; logger() { :; }; eval "$2"' _ "$ROOT" "$2" 2>&1
}
for TBA_M in glibc jemalloc; do
  out=$(pt "$TBA_M" 'printf "impl=%s\n" "$MALLOC_IMPL"')
  check "php: env PHP_BUILD_MALLOC=$TBA_M warns once and uses mimalloc" \
    bash -c '[[ $(grep -c "WARNING: PHP: PHP_BUILD_MALLOC=$2 was removed in 1.22.5 .*; using the default (mimalloc)" <<<"$1") == 1 && $1 == *impl=mimalloc* ]]' _ "$out" "$TBA_M"
  out=$(pt "" 'printf "impl=%s\n" "$MALLOC_IMPL"' "PHP_BUILD_MALLOC=$TBA_M")
  check "php: PHP_BUILD_MALLOC=$TBA_M in php-build.conf warns the same way" \
    bash -c '[[ $1 == *"PHP_BUILD_MALLOC=$2 was removed in 1.22.5"* && $1 == *impl=mimalloc* ]]' _ "$out" "$TBA_M"
done
check "php: the glibc warning gives the measured reason" \
  has "$(pt glibc 'echo loaded')" "PHP_BUILD_MALLOC=glibc was removed in 1.22.5 (measured 3-4 % slower on uncached XenForo pages and twice the PHP-FPM memory of mimalloc); using the default (mimalloc)"
check "php: PHP_BUILD_MALLOC=mimalloc is kept, with no warning" test "$(pt mimalloc 'printf %s "$MALLOC_IMPL"')" = mimalloc
check "php: the default is mimalloc, with no warning" test "$(pt "" 'printf %s "$MALLOC_IMPL"')" = mimalloc
# Reviewer concern: a typo must never make every daily refresh fail a
# rebuild.  It warns, uses mimalloc, and a mimalloc build stays current.
out=$(pt mimaloc 'printf "impl=%s\n" "$MALLOC_IMPL"')
check "php: an unknown PHP_BUILD_MALLOC (a typo) warns once and uses mimalloc" \
  bash -c '[[ $(grep -c "WARNING: PHP: PHP_BUILD_MALLOC=mimaloc is not an allocator this build knows (expected mimalloc); using the default (mimalloc)" <<<"$1") == 1 && $1 == *impl=mimalloc* ]]' _ "$out"
out=$(pt "" 'printf "impl=%s\n" "$MALLOC_IMPL"' 'PHP_BUILD_MALLOC=tcmalloc')
check "php: ... the same from php-build.conf" \
  bash -c '[[ $1 == *"PHP_BUILD_MALLOC=tcmalloc is not an allocator"* && $1 == *impl=mimalloc* ]]' _ "$out"
check "php: no die on PHP_BUILD_MALLOC is left in php-build.sh" \
  bash -c '! grep -nE "die .*PHP_BUILD_MALLOC|MALLOC_IMPL != glibc|MALLOC_IMPL:-glibc" "$1"' _ "$ROOT/tools/php-build.sh"
out=$(pt "" 'echo loaded' 'BOLT_NOLBR=1')
check "php: a leftover BOLT_NOLBR=1 warns once and loads" \
  bash -c '[[ $(grep -c "BOLT_NOLBR=1 was removed in 1.22.5" <<<"$1") == 1 && $1 == *loaded* ]]' _ "$out"
check "php: BOLT_NOLBR=0 (the old default line) draws no warning" test "$(pt "" 'echo loaded' 'BOLT_NOLBR=0')" = loaded
out=$(PHP_BUILD_BOLT_NOLBR=1 pt "" 'echo loaded')
check "php: env PHP_BUILD_BOLT_NOLBR=1 warns the same way" bash -c '[[ $1 == *"BOLT_NOLBR=1 was removed in 1.22.5"* && $1 == *loaded* ]]' _ "$out"
check "php libs_for: the default set ends with mimalloc" test "$(pt "" 'libs_for "ctype" | tr "\n" " "')" = "zlib-ng openssl pcre2 libxml2 mimalloc "
out=$(pt glibc 'libs_for "ctype" | tr "\n" " "')
check "php libs_for: PHP_BUILD_MALLOC=glibc still builds mimalloc" \
  bash -c 'l=$(tail -n 1 <<<"$1"); [[ $l == "zlib-ng openssl pcre2 libxml2 mimalloc " ]]' _ "$out"
# The library cache key of the default set (libs_for: mimalloc included), so
# a glibc host's cache (no mimalloc line) is never reused for it.
check "php: the library cache key of a default set is pinned (3ad749cd04b2a9e9)" \
  test "$(pt glibc 'BASE_FLAGS=-O3; n=20; mapfile -t LIBS < <(libs_for ctype); declare -A VERS=([zlib-ng]=2.2.5 [openssl]=3.6.0 [pcre2]=10.46 [libxml2]=2.15.1 [mimalloc]=3.1.5); lib_cache_key abc' | tail -n 1)" = 3ad749cd04b2a9e9
check "php: ... and differs from the 1.22.4 glibc key (02907f906fb7881f)" \
  test "$(pt "" 'BASE_FLAGS=-O3; n=20; mapfile -t LIBS < <(libs_for ctype); declare -A VERS=([zlib-ng]=2.2.5 [openssl]=3.6.0 [pcre2]=10.46 [libxml2]=2.15.1 [mimalloc]=3.1.5); lib_cache_key abc')" != 02907f906fb7881f
rm_() { # recorded-malloc -> recorded_malloc 8.5
  pt "" 'mkdir -p "$ROOT/8.5"; printf "version=8.5.1\n%s" "'"${1:+malloc=$1
}"'" > "$ROOT/8.5/build.info"; recorded_malloc 8.5'
}
check "php recorded_malloc: mimalloc stays mimalloc" test "$(rm_ mimalloc)" = mimalloc
check "php recorded_malloc: none recorded is glibc (a pre-1.22.5 build)" test "$(rm_ "")" = glibc
check "php recorded_malloc: jemalloc reads as recorded (the BOLT verify checks only mimalloc)" test "$(rm_ jemalloc)" = jemalloc
check "php cmd_build always builds mimalloc; only cmd_bolt reads the recorded allocator" \
  bash -c 'sed -n "/^cmd_build() {/,/^}/p" "$1" | grep -qx "  MALLOC_IMPL=mimalloc" && ! sed -n "/^cmd_build() {/,/^}/p" "$1" | grep -q recorded_malloc && sed -n "/^cmd_bolt() {/,/^}/p" "$1" | grep -qF "MALLOC_IMPL=\$(recorded_malloc \"\$ver\")"' _ "$ROOT/tools/php-build.sh"
pck() { # env-malloc recorded-extra -> cmd_check 8.4 output
  pt "$1" 'cpu_fingerprint_matches() { return 0; }; resolve_set() { :; }
    mkdir -p "$ROOT/8.4/sbin"; printf "ctype\n" > "$ROOT/8.4/exts.want"
    { printf "recipe=%s\nexts=ctype\n" "$BUILD_RECIPE"; printf "%b" "'"$2"'"; } > "$ROOT/8.4/build.info"
    rc=0; cmd_check 8.4 || rc=$?; echo "rc=$rc"'
}
check "php check: a glibc build is stale (rebuilt on mimalloc)" \
  bash -c '[[ $1 == *"malloc glibc -> mimalloc"* && $1 == *rc=10* ]]' _ "$(pck "" 'malloc=glibc\nbolt=1\nbolt_mode=lbr\n')"
check "php check: a pre-1.22.5 build (no malloc=) is stale as glibc" \
  bash -c '[[ $1 == *"malloc glibc -> mimalloc"* && $1 == *rc=10* ]]' _ "$(pck "" '')"
check "php check: a jemalloc build is stale (rebuilt on mimalloc)" \
  bash -c '[[ $1 == *"malloc jemalloc -> mimalloc"* && $1 == *rc=10* ]]' _ "$(pck "" 'malloc=jemalloc\n')"
check "php check: ... also while PHP_BUILD_MALLOC=glibc is still set (warning, no die)" \
  bash -c '[[ $1 == *"was removed in 1.22.5"* && $1 == *"malloc glibc -> mimalloc"* && $1 == *rc=10* && $1 != *ERROR* ]]' _ "$(pck glibc 'malloc=glibc\n')"
check "php check: a build BOLTed without branch samples (bolt_mode=nolbr) is stale" \
  bash -c '[[ $1 == *"BOLT profile without branch samples (removed in 1.22.5)"* && $1 == *rc=10* ]]' _ "$(pck "" 'malloc=mimalloc\nbolt=1\nbolt_mode=nolbr\n')"
check "php check: a default build (mimalloc, bolt_mode=lbr) is current" \
  bash -c '[[ $1 == *current* && $1 == *rc=0* ]]' _ "$(pck "" 'malloc=mimalloc\nbolt=1\nbolt_mode=lbr\n')"
check "php check: a mimalloc build stays current under a typo in PHP_BUILD_MALLOC (no daily rebuild loop)" \
  bash -c '[[ $1 == *"is not an allocator"* && $1 == *current* && $1 == *rc=0* && $1 != *ERROR* ]]' _ "$(pck mimaloc 'malloc=mimalloc\nbolt=1\nbolt_mode=lbr\n')"
# CPU rebuild (exact versions) of a glibc build: mimalloc= was never
# recorded, so resolve_set looks it up and the rebuild moves to mimalloc.
prs() { # recorded-extra -> resolve_set 8.4 ctype 1
  pt "" 'components_for() { printf "%s\n" php mimalloc; }; resolve() { [[ $1 == mimalloc ]] && echo 3.1.5; }
    mkdir -p "$ROOT/8.4"; { printf "php=8.4.1\n"; printf "%b" "'"$1"'"; } > "$ROOT/8.4/build.info"
    rc=0; resolve_set 8.4 ctype 1 || rc=$?; echo "rc=$rc"'
}
out=$(prs 'malloc=glibc\n')
check "php CPU rebuild: a glibc build resolves mimalloc and says so" \
  bash -c '[[ $1 == *"php=8.4.1"* && $1 == *"mimalloc=3.1.5"* && $1 == *"recorded allocator glibc was removed in 1.22.5; rebuilding with mimalloc 3.1.5"* && $1 == *rc=0* ]]' _ "$out"
out=$(prs 'mimalloc=3.0.9\nmalloc=mimalloc\n')
check "php CPU rebuild: a mimalloc build keeps its recorded mimalloc version" \
  bash -c '[[ $1 == *"mimalloc=3.0.9"* && $1 != *"was removed"* && $1 == *rc=0* ]]' _ "$out"
unset TBA_M

# ---------------------------------------------------------------------------
# php: OPENSSL_VERSION=lts removed (shared conf_get): it warns and resolves
# like "latest"; PHP 8.1 still gets the newest 3.x (it does not compile
# against OpenSSL 4), 8.2+ the newest release.
# ---------------------------------------------------------------------------
out=$(pt "" 'git_latest() { printf "[%s %s]" "$1" "$2"; }; resolve openssl 8.1' 'OPENSSL_VERSION=lts')
check "php OPENSSL_VERSION=lts: warns that it was removed (default: latest)" \
  bash -c '[[ $1 == *"OPENSSL_VERSION=lts in "*" was removed in 1.22.5"*"using the default (latest)"* ]]' _ "$out"
check "php OPENSSL_VERSION=lts: PHP 8.1 resolves the newest OpenSSL 3.x" has "$out" '[openssl/openssl ^openssl-(3\.[0-9]+\.[0-9]+)$]'
out=$(pt "" 'git_latest() { printf "[%s %s]" "$1" "$2"; }; resolve openssl 8.5' 'OPENSSL_VERSION=lts')
check "php OPENSSL_VERSION=lts: PHP 8.5 resolves the newest OpenSSL release (no 3.5 series)" \
  bash -c '[[ $1 == *"[openssl/openssl ^openssl-([0-9]+\.[0-9]+\.[0-9]+)\$]"* && $1 != *"3\.5"* ]]' _ "$out"
out=$(pt "" 'git_latest() { printf "[%s %s]" "$1" "$2"; }; resolve openssl 8.1')
check "php: PHP 8.1's newest-3.x resolution is unchanged without the key (no warning)" \
  bash -c '[[ $1 == "[openssl/openssl ^openssl-(3\.[0-9]+\.[0-9]+)\$]" ]]' _ "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
