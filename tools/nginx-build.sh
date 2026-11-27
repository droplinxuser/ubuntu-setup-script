#!/usr/bin/env bash
# The nginx every host runs (1.22.0): nginx.org mainline, compiled from source.
#
# A lean nginx built from upstream sources only: nginx from nginx.org (PGP
# signature checked against the nginx.org keys pinned in build-common.sh),
# AWS-LC, PCRE2 (JIT), zlib-ng, Brotli (google/brotli + google/ngx_brotli's filter
# module, compiled in statically) from their own releases at the versions in
# nginx-build.conf ("latest" by default; nginx's latest is the mainline),
# compiled with clang from apt.llvm.org at -O3 -march=native with Ubuntu's
# hardening flags, AWS-LC, PCRE2 and zlib-ng linked statically (ThinLTO for
# AWS-LC, zlib-ng, Brotli and nginx; PCRE2 is built by nginx's configure
# at the same -O3 -march=native flags without LTO), then rewritten by LLVM
# BOLT from a perf sample of live traffic.  Measured on the test host
# (1.21.70, same recipe): cached guest pages +2.2 to +12.4 % with BOLT
# (+3.6 to +6.1 % before it); gzip CPU per page -21 % (zlib-ng).
#
# Lean: only what server-configs-nginx uses: the http core with SSL, HTTP/2,
# HTTP/3 (QUIC), realip, stub_status (the metrics script polls it on
# 127.0.0.1), threads (aio threads), auth_basic, limit_req and dynamic Brotli
# (the ngx_brotli filter; gzip_static and brotli_static are left out since
# 1.22.1: no precompressed siblings, dynamic gzip and Brotli only).
# No mail, stream, DAV, mp4/flv, sub, SSI, uwsgi, scgi, grpc, memcached,
# limit_conn, referer, userid, autoindex, split_clients, empty_gif, browser
# or mirror.  A directive of a left-out module that only transforms or
# limits responses (sub_filter, ssi, limit_conn, ...) is commented out in the
# operator's file with a report (`fit`; limit_conn is reported as a removed
# security control, operator rule of 1.21.71) and can be restored with
# `restore`; anything else that fails `nginx -t` stops the activation and the
# running nginx keeps serving.
#
# Branding: after unpacking, before configure, the source is patched so no
# response names the server: no default Server header (HTTP/1.1, HTTP/2,
# HTTP/3) and error pages that end with </body></html>.  Every patch is
# counted; when a new mainline moved one of the patched lines, install and
# migration build the newest known-good version instead (NGINX_FALLBACK in
# nginx-build.conf, or this host's last patched build), and the daily
# refresh keeps the running binary.  The verify step starts the candidate on
# 127.0.0.1 and checks that neither headers nor body of a 404/502 contain
# "nginx" (with server_tokens on, to prove the patch and not the config).
#
# Layout (prefix /usr/local/lib/setup-nginx = ROOT):
#   ROOT/sbin/nginx        the binary nginx.service runs (ExecStart, never a /usr link)
#   ROOT/sbin/nginx.lto    the same build unstripped, with relocations (BOLT input)
#   ROOT/sbin/nginx.prev   the previous binary (rollback of a failed upgrade)
#   ROOT/build/build.info  versions, recipe, CPU fingerprint, bolt state
#   ROOT/staging/          `build` output, swapped in by `activate`
#   ROOT/html/             unbranded index.html / 50x.html (`root html`)
#   ROOT/logs/             build logs, the newest 5 kept
#   /etc/nginx/nginx.conf, /var/www/logs/nginx, /run/nginx.pid, /var/cache/nginx/*_temp
# The unit (/etc/systemd/system/nginx.service), tmpfiles.d/setup-nginx.conf
# and the build units are written by setup.sh (lib/nginx-build.sh).
#
# Binary swaps never restart nginx: `activate` and BOLT rename the new binary
# over ROOT/sbin/nginx and do nginx's in-place upgrade (USR2, WINCH, QUIT),
# rolling back to the old master when the new one does not serve.
#
# CPU: the binary is tied to the CPU it was built on (-march=native).  The
# unit's ExecStartPre (`pre`) compares build.info cpu= with this CPU's
# fingerprint; on a mismatch it only starts setup-build-cpu.service and fails,
# so nginx stays down until the native rebuild (`rebuild-cpu`: exact recorded
# versions, cached sources, no network, no BOLT) finished and started it.
#
# CI (NGINX_BUILD_CI=1, server-configs-nginx's scripts/ci-build-nginx.sh):
# `build` compiles and verifies with no host side effect (no unit, tmpfiles,
# timers, systemctl, links, lock), honours NGINX_BUILD_ROOT, _CACHE, _CONF
# and _COMMON, keeps the configure module set (static ngx_brotli filter) and the
# branding patch, skips LTO, BOLT and -march=native (the system cc), leaves
# the binary at ROOT/staging/sbin/nginx and prints that path as the last
# line of stdout.
#
# Usage (root):
#   nginx-build.sh build | build-only   build + verify into ROOT/staging (prints its path)
#   nginx-build.sh build-arm DIR        benchmark build into DIR/sbin/nginx, never activated
#                                       (version arms: see nginx-build.conf)
#   nginx-build.sh activate             swap staging in (in-place upgrade, or start)
#   nginx-build.sh bolt [S]             sample S seconds (default 60) of traffic, BOLT
#   nginx-build.sh rebuild              build, activate, wait for traffic, bolt
#   nginx-build.sh rebuild-cpu          CPU-change rebuild (offline, recorded versions)
#   nginx-build.sh refresh              daily timer: rebuild when stale, BOLT when due
#   nginx-build.sh check [INFO]         0 when current, 10 when a rebuild is due (INFO: another build.info)
#   nginx-build.sh versions | status | pre | remove | configure-args | directive-res
#   nginx-build.sh fit [CONF [BIN]] | restore   comment out / restore directives of left-out modules
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

CI=${NGINX_BUILD_CI:-0}
ROOT=${NGINX_BUILD_ROOT:-/usr/local/lib/setup-nginx}
SBIN=$ROOT/sbin
STATE=$ROOT/build
STAGING=$ROOT/staging
LOGS=$ROOT/logs
SRC_CACHE=${NGINX_BUILD_CACHE:-/var/cache/setup-nginx-build}
UNIT_DIR=${NGINX_BUILD_UNIT_DIR:-/etc/systemd/system}
CONF=${NGINX_BUILD_CONF:-$ROOT/nginx-build.conf}
NGINX_CONF=${NGINX_BUILD_NGINX_CONF:-/etc/nginx/nginx.conf}
PIDFILE=${NGINX_BUILD_PIDFILE:-/run/nginx.pid}
TMPFILES=${NGINX_BUILD_TMPFILES:-/etc/tmpfiles.d/setup-nginx.conf}
LINK=${NGINX_BUILD_LINK:-/usr/local/sbin/nginx}
LOG_TAG=setup-nginx-build
BOLT_MIN_FUNCS=${NGINX_BUILD_BOLT_MIN_FUNCS:-150}
# install | optimize | migrate | refresh | cpu: what may happen around a build
# (migrate: never start nginx, never test /etc/nginx; refresh: never fall back).
CONTEXT=${NGINX_BUILD_CONTEXT:-install}
SELF=$(readlink -f "${BASH_SOURCE[0]}")
BUILD_COMMON=${NGINX_BUILD_COMMON:-$(dirname "$SELF")/build-common.sh}
# shellcheck source=tools/build-common.sh
. "$BUILD_COMMON"

# 4 = 1.22.0: nginx.org mainline, static Brotli, branding patch, stub_status,
# own unit and paths (1-3 were the opt-in builds of 1.21.70-1.21.71).
# 5 = 1.22.1: no gzip_static, only the ngx_brotli filter (no brotli_static);
# a host on recipe 4 rebuilds on its next --optimize or refresh.
BUILD_RECIPE=5
NGINX_FALLBACK_DEFAULT=1.31.10
if [[ $CI == 1 ]]; then
  COMPONENTS=(nginx aws-lc pcre2 zlib-ng brotli ngx-brotli)
else
  COMPONENTS=(nginx llvm aws-lc pcre2 zlib-ng brotli ngx-brotli)
fi
declare -A VERS=()
# Ubuntu libraries the build must not link (they are compiled in).
STATIC_LIBS_RE='^(libssl|libcrypto|libpcre2-8|libz|libbrotli[a-z]*)\.so'
LOG_FILE=""

# Directives of left-out modules that fit_config may comment out so the build
# can serve the configuration.  Only ones whose removal stops a response
# transformation or a connection limit; never access control (auth_request,
# secure_link, valid_referers, ...) or a content handler (uwsgi_pass,
# grpc_pass, memcached_pass, empty_gif, ...): without those a location would
# serve its root as static files, so the activation stops instead.
# limit_conn stays out of the build (operator rule, 1.21.71); commenting it
# out is reported as a removed security control, never silently.
# gzip_static and brotli_static (left out since 1.22.1) only choose a
# precompressed sibling over dynamic compression; dynamic gzip/Brotli serve on.
DROPPABLE_RE='^(gzip_static|brotli_static|sub_filter(_once|_types|_last_modified)?|ssi(_[a-z_]+)?|addition_types|add_before_body|add_after_body|limit_conn(_zone|_status|_log_level|_dry_run)?|userid(_[a-z_]+)?|autoindex(_[a-z_]+)?|random_index|gunzip(_buffers)?|mp4(_[a-z_]+)?|flv)$'
# Directives of modules this build does not have that are NOT droppable
# (access control, content handlers, left-out modules nginx never builds by
# default): a configuration using one blocks the activation.  lib/nginx-build.sh
# exports both lists (NGINX_BUILD_DROPPABLE_RE / NGINX_BUILD_UNBUILT_RE) for
# the migration's pre-flight scan, so it matches this configure line.
UNBUILT_RE='^(valid_referers|referer_hash_(max|bucket)_size|auth_request(_set)?|secure_link(_md5|_secret)?|slice|dav_(methods|access)|create_full_put_path|min_delete_depth|uwsgi_[a-z_]+|scgi_[a-z_]+|grpc_[a-z_]+|memcached_[a-z_]+|empty_gif|mirror(_request_body)?|split_clients|image_filter(_[a-z_]+)?|xslt_[a-z_]+|perl(_[a-z_]+)?|geoip_[a-z_]+|ancient_browser(_value)?|modern_browser(_value)?)$'
OFF_MARK='# setup-nginx-build-off: '
# 1.21.70-1.21.71 builds marked their comments this way (in /etc/angie, which
# the migration copies to /etc/nginx); restore_config recognises both.
OLD_OFF_MARK='# setup-angie-build-off: '
conf_dir() { dirname "$NGINX_CONF"; }

# ------------------------------------------------------------------ helpers
info_get() { # key [file]
  local f=${2:-$STATE/build.info}
  [[ -f $f ]] && awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$f"
  return 0
}
bin_version() { "$1" -v 2>&1 | sed -nE 's#.*nginx/([0-9.]+).*#\1#p' | sed -n 1p; }

# A KEY=VALUE of nginx-build.conf that is not a component version.
conf_value() { # key default
  local v=""
  [[ -f $CONF ]] && v=$(awk -F= -v k="$1" '{ sub(/\r$/, "") } $1 == k { v = substr($0, length(k) + 2); sub(/[[:space:]]*#.*$/, "", v); gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v); last = v } END { print last }' "$CONF")
  printf '%s' "${v:-$2}"
}

# The TLS library (TLS_LIB / NGINX_BUILD_TLS_LIB in nginx-build.conf):
# AWS-LC is the only one since 1.22.5 (built first with cmake + ninja and
# linked like a system library; its version is resolved, recorded and
# checked like any other component).
# An invalid value never dies here (1.22.5): this runs for every command,
# `pre` (nginx.service ExecStartPre) included, so it is recorded in
# CONF_INVALID and the default is used; build and check refuse it
# (conf_invalid_die), pre and status only warn.
# A value or option removed in 1.22.5 (TLS_LIB=openssl|boringssl, MALLOC,
# BOLT_NOLBR) is not invalid: it is noted in CONF_REMOVED, warned about once
# (below) and the default is used; build and check go on, and `check`
# reports a build made with it stale.
CONF_INVALID=""
CONF_REMOVED=""
conf_invalid_die() { [[ -z $CONF_INVALID ]] || die "nginx-build.conf: ${CONF_INVALID%; }"; }
tls_setup() { # lib
  TLS_LIB=${1:-aws-lc}
  case $TLS_LIB in
    aws-lc) ;;
    # XenForo on the test host (1.22.5): cached pages 2-5 % slower than
    # aws-lc (uncached within noise), and more nginx memory under load.
    openssl) CONF_REMOVED+="TLS_LIB=openssl|measured 2-5 % slower on cached XenForo pages and more nginx memory than aws-lc|aws-lc;"; TLS_LIB=aws-lc ;;
    # Measured below aws-lc on the cached tier, no OCSP stapling, one
    # certificate per server block.
    boringssl) CONF_REMOVED+="TLS_LIB=boringssl|measured slower than aws-lc, no OCSP stapling|aws-lc;"; TLS_LIB=aws-lc ;;
    *) CONF_INVALID+="TLS_LIB=$TLS_LIB: expected aws-lc; "; TLS_LIB=aws-lc ;;
  esac
}
tls_setup "${NGINX_BUILD_TLS_LIB:-$(conf_value TLS_LIB aws-lc)}"

# nginx always links glibc's malloc: MALLOC=mimalloc|jemalloc measured
# within noise of it on every tier and was removed in 1.22.5 (a build that
# recorded another malloc= is stale).  BOLT_NOLBR=1 (a plain-cycles BOLT
# profile where perf has no branch samples) measured 3-4 % slower than no
# BOLT and was removed too.  A conf or environment that still sets either
# only draws the warning.
CONF_MALLOC=${NGINX_BUILD_MALLOC:-$(conf_value MALLOC glibc)}
[[ $CONF_MALLOC == glibc ]] || CONF_REMOVED+="MALLOC=$CONF_MALLOC|measured within noise of glibc|glibc;"
CONF_NOLBR=${NGINX_BUILD_BOLT_NOLBR:-$(conf_value BOLT_NOLBR 0)}
[[ $CONF_NOLBR == 0 ]] || CONF_REMOVED+="BOLT_NOLBR=$CONF_NOLBR|plain-cycles BOLT measured slower than no BOLT|no BOLT without branch samples;"
unset CONF_MALLOC CONF_NOLBR
# One warning per option per run (say: stderr and the journal).
conf_removed_warn() {
  local e what why def
  local -a items=()
  IFS=';' read -r -a items <<<"$CONF_REMOVED"
  for e in ${items[@]+"${items[@]}"}; do
    IFS='|' read -r what why def <<<"$e"
    opt_removed "nginx: $what" "$why" "$def"
  done
}
conf_removed_warn

# build.info tls_opts=: the hash of the library name.  An aws-lc build keeps
# the key it recorded before 1.22.5 (sha256 of "aws-lc"), so it is not
# rebuilt; an openssl build (its key also hashed ktls=0 and the
# OpenSSL configure options), a BoringSSL build or one with no tls_opts=
# (before the TLS arms, always openssl) keys differently and is reported
# stale by `check`, then rebuilt on AWS-LC.
tls_key() { # lib
  printf '%s' "$1" | sha256sum | cut -c1-16
}

resolve_all() {
  local c v rc=0
  for c in "${COMPONENTS[@]}"; do
    if v=$(resolve "$c"); then printf '%s=%s\n' "$c" "$v"; else printf '%s=?\n' "$c"; rc=1; fi
  done
  return "$rc"
}

host_mode() { [[ $CI != 1 ]]; }

# /var/cache/nginx/*_temp and /var/www/logs/nginx must exist before any
# `nginx -t`: nginx creates only the last path component of a temp path and
# opens the compiled error log before it reads the configuration.  setup.sh
# writes the tmpfiles.d file; without it (first build) the directories are
# made directly with the same owner and mode.
apply_tmpfiles() {
  host_mode || return 0
  if [[ -f $TMPFILES ]] && command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create "$TMPFILES" >/dev/null 2>&1 && return 0
  fi
  install -d -m 0700 -o www-data -g www-data /var/cache/nginx 2>/dev/null || install -d -m 0700 /var/cache/nginx
  local d
  for d in client fastcgi proxy scgi uwsgi; do
    install -d -m 0700 -o www-data -g www-data "/var/cache/nginx/${d}_temp" 2>/dev/null || true
  done
  install -d -m 0750 -o www-data -g www-data /var/www/logs/nginx 2>/dev/null || install -d -m 0750 /var/www/logs/nginx
}

conf_test() { # binary [conf]: nginx -t output, status of the test
  "$1" -e stderr -t -q -c "${2:-$NGINX_CONF}" 2>&1
}

# The live configuration is tested only on a host that has one and outside
# the migration (whose tree is rendered later and tested by migrate.sh).
live_test_enabled() {
  host_mode && [[ $CONTEXT != migrate && ${NGINX_BUILD_LIVE_TEST:-1} == 1 && -f $NGINX_CONF ]]
}

# Comment out directive $3 that ends on line $2 of file $1 (nginx reports the
# line a directive ends on): from the line it starts on through the line that
# ends it, each prefixed with OFF_MARK after its indentation.  The file is
# rewritten in place (same inode, owner and mode).
comment_directive() { # file line directive
  local f=$1 n=$2 d=$3 start tmp
  start=$(awk -v n="$n" -v d="$d" 'NR <= n && $1 == d || NR <= n && index($1, d ";") == 1 { s = NR } END { print s + 0 }' "$f")
  (( start > 0 )) || return 1
  tmp=$(mktemp) || return 1
  awk -v s="$start" -v e="$n" -v mark="$OFF_MARK" '
    NR >= s && NR <= e { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) mark substr($0, RLENGTH + 1); next }
    { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Make the configuration acceptable to binary $1 by commenting out droppable
# directives it does not know, one `nginx -t` at a time.  Every change is a
# "nginx build: commented out ..." line on stderr (lib/nginx-build.sh turns
# them into report lines).  Returns 1 (with the error on stderr) as soon as
# the test fails for any other reason.
fit_config() { # binary [conf]
  local bin=$1 conf=${2:-$NGINX_CONF} out dir f n d i why
  dir=$(dirname "$conf")
  for (( i = 0; i < 100; i++ )); do
    out=$(conf_test "$bin" "$conf") && return 0
    if [[ $out =~ unknown\ directive\ \"([a-z0-9_]+)\"\ in\ ([^[:space:]]+):([0-9]+) ]]; then
      d=${BASH_REMATCH[1]}; f=${BASH_REMATCH[2]}; n=${BASH_REMATCH[3]}
      if [[ $d =~ $DROPPABLE_RE && $f == "$dir"/* && -f $f && ! -L $f ]] && comment_directive "$f" "$n" "$d"; then
        # disabled.list feeds lib/nginx-build.sh's report of comment-outs made
        # outside a setup.sh run; the migration reports its own fit lines.
        if host_mode && [[ $conf == "$NGINX_CONF" && $CONTEXT != migrate ]]; then
          install -d -m 755 "$STATE"
          printf '%s:%s %s\n' "${f#"$dir"/}" "$n" "$d" >> "$STATE/disabled.list"
        fi
        why="module not compiled in; \`nginx-build.sh restore\` puts it back"
        [[ $d == limit_conn* ]] && why="security control removed (operator rule 1.21.71: limit_conn is not compiled in)"
        say "nginx build: commented out $d in ${f#"$dir"/}:$n ($why)"
        continue
      fi
    fi
    grep -m1 -E 'emerg|error' <<<"$out" >&2 || sed -n 1p <<<"$out" >&2
    return 1
  done
  return 1
}

# Undo fit_config everywhere under the configuration directory (also the
# marker of the 1.21 Angie builds, carried over by the migration).
restore_config() {
  local dir f n=0
  dir=$(conf_dir)
  [[ -d $dir ]] || return 0
  while IFS= read -r f; do
    [[ -f $f && ! -L $f ]] || continue
    sed -i -E 's/^([[:space:]]*)# setup-(nginx|angie)-build-off: /\1/' "$f" && n=$(( n + 1 ))
  done < <(grep -rlE -- "^[[:space:]]*(${OFF_MARK}|${OLD_OFF_MARK})" "$dir" 2>/dev/null || true)
  rm -f "$STATE/disabled.list"
  (( n == 0 )) || say "nginx: restored the directives the build had commented out (${n} file(s))"
  return 0
}

# The running master of OUR binary (not a distro nginx that also uses
# /run/nginx.pid): its executable is ROOT/sbin/nginx (or the file we renamed
# over, "(deleted)").
master_pid() {
  local p exe
  p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null || return 1
  exe=$(readlink "/proc/$p/exe" 2>/dev/null) || return 1
  [[ $exe == "$SBIN/nginx" || $exe == "$SBIN/nginx (deleted)" || $exe == "$SBIN/nginx.prev"* ]] || return 1
  printf '%s' "$p"
}

# Something answers on 127.0.0.1:80/443.  The default server may close the
# connection without a response (444) or refuse the TLS handshake
# (ssl_reject_handshake): an accepted connection counts, a refused or timed
# out one does not.
serving_probe() {
  local rc
  for _ in $(seq 1 25); do
    rc=0; curl -sk -o /dev/null --max-time 3 https://127.0.0.1/ 2>/dev/null || rc=$?
    [[ $rc == 0 || $rc == 35 || $rc == 52 || $rc == 56 ]] && return 0
    rc=0; curl -s -o /dev/null --max-time 3 http://127.0.0.1/ 2>/dev/null || rc=$?
    [[ $rc == 0 || $rc == 52 || $rc == 56 ]] && return 0
    sleep 0.2
  done
  return 1
}

# The web ports are held by another server (Angie, a distro nginx) that the
# migration's cutover has not stopped yet: install the build, do not start it.
ports_taken() {
  systemctl is-active -q angie.service 2>/dev/null && { printf 'angie.service'; return 0; }
  local who
  who=$(ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | sed -n '1s/users:(("//p')
  [[ -n $who ]] && { printf '%s' "$who"; return 0; }
  return 1
}

# ------------------------------------------------------------------ branding
BRAND_HEADER_FILES=(src/http/ngx_http_header_filter_module.c src/http/v2/ngx_http_v2_filter_module.c src/http/v3/ngx_http_v3_filter_module.c)
BRAND_PAGES_FILE=src/http/ngx_http_special_response.c

# Patch the unpacked source in DIR.  Every count is checked BEFORE anything
# is changed (an upstream refactor is noticed, and the tree is never left
# half-patched), and again after.
#   header filters (HTTP/1.1, HTTP/2, HTTP/3): each `r->headers_out.server
#     == NULL` (2 per file: length and write) becomes `0 && ...`, so no
#     default Server header is sent whatever server_tokens says; a Server
#     header an upstream sent (proxy_pass_header) is untouched.
#   special responses: the three `"<hr><center>` tail lines (NGINX_VER,
#     NGINX_VER_BUILD, "nginx") are deleted: error pages end with </body></html>.
# Status 1 with the reason on stderr when a count differs.
brand_patch() { # dir
  local d=$1 f n
  # Counts are taken with `|| true` inside the substitution: grep exits 1 on
  # zero matches, which under set -e/pipefail would abort a plain call (the
  # fixture tests call it outside `if`) instead of returning the count.
  for f in "${BRAND_HEADER_FILES[@]}"; do
    [[ -f $d/$f ]] || { say "branding: $f is missing"; return 1; }
    n=$( { grep -oF 'r->headers_out.server == NULL' "$d/$f" || true; } | wc -l)
    (( n == 2 )) || { say "branding: $f has $n x 'r->headers_out.server == NULL' (expected 2)"; return 1; }
    n=$( { grep -oF '0 && r->headers_out.server == NULL' "$d/$f" || true; } | wc -l)
    (( n == 0 )) || { say "branding: $f is already patched"; return 1; }
  done
  [[ -f $d/$BRAND_PAGES_FILE ]] || { say "branding: $BRAND_PAGES_FILE is missing"; return 1; }
  n=$(grep -c '^"<hr><center>' "$d/$BRAND_PAGES_FILE" || true)
  (( n == 3 )) || { say "branding: $BRAND_PAGES_FILE has $n '\"<hr><center>' tail lines (expected 3)"; return 1; }
  for f in "${BRAND_HEADER_FILES[@]}"; do
    sed -i 's/r->headers_out\.server == NULL/0 \&\& r->headers_out.server == NULL/g' "$d/$f"
    n=$( { grep -oF '0 && r->headers_out.server == NULL' "$d/$f" || true; } | wc -l)
    (( n == 2 )) || { say "branding: $f: $n patched lines after sed (expected 2)"; return 1; }
  done
  sed -i '/^"<hr><center>/d' "$d/$BRAND_PAGES_FILE"
  n=$(grep -c '<hr><center>' "$d/$BRAND_PAGES_FILE" || true)
  (( n == 0 )) || { say "branding: $BRAND_PAGES_FILE still has $n '<hr><center>' lines"; return 1; }
  return 0
}

# The fallback when version FAIL cannot be patched: the newest of this host's
# last patched build and NGINX_FALLBACK that is not newer than FAIL (R68).
choose_fallback() { # fail
  local fail=$1 c best=""
  for c in "$(info_get patched_ok)" "$(conf_value NGINX_FALLBACK "$NGINX_FALLBACK_DEFAULT")"; do
    [[ $c =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $c != "$fail" ]] || continue
    ver_ge "$fail" "$c" || continue
    if [[ -z $best ]] || ver_ge "$c" "$best"; then best=$c; fi
  done
  printf '%s' "$best"
}

# A version the branding patch was refused for: `check` does not report it as
# due (no daily rebuild of the same refusal) until a newer one appears.
SKIP_FILE=$ROOT/patch-skip

# Start the candidate on 127.0.0.1 with a throwaway configuration and check a
# 404, a 502 and stub_status over HTTP/1.1 (and HTTP/2 cleartext when curl
# has it): status right, page complete, "nginx" in neither headers nor body
# (server_tokens on: proving the patch, not the configuration).  `brotli on`
# proves the static module.  Temp paths and the error log go to the temp dir
# (-e; -p does not move the absolute compiled-in paths).
branding_check() { # binary
  local bin=$1 t port port2 i up=0 out="" rc=0 h2=0 cv st
  command -v curl >/dev/null 2>&1 || ensure_packages curl
  cv=$(curl --version 2>/dev/null || true)
  [[ $cv == *HTTP2* ]] && h2=1
  t=$(mktemp -d); chmod 755 "$t"
  for i in 1 2 3 4 5; do
    port=$(( 20000 + RANDOM % 30000 )); port2=$(( port + 1 ))
    cat > "$t/nginx.conf" <<EOF
worker_processes 1;
error_log $t/error.log;
pid $t/nginx.pid;
events { worker_connections 64; }
http {
  access_log off;
  server_tokens on;
  client_body_temp_path $t/client_temp;
  proxy_temp_path $t/proxy_temp;
  fastcgi_temp_path $t/fastcgi_temp;
  brotli on;
  brotli_types text/plain;
  server {
    listen 127.0.0.1:$port;
    location / { return 404; }
    location = /e { return 502; }
    location = /s { stub_status; }
  }
  # HTTP/2 cleartext (prior knowledge) on its own port.
  server {
    listen 127.0.0.1:$port2;
    http2 on;
    location / { return 404; }
  }
}
EOF
    if "$bin" -e "$t/error.log" -p "$t/" -c "$t/nginx.conf" 2>>"$t/start.log"; then up=1; break; fi
  done
  if (( ! up )); then
    say "branding check: the candidate did not start: $(tail -n 3 "$t/start.log" "$t/error.log" 2>/dev/null | grep -E 'emerg|alert|error' | head -n 2)"
    rm -rf "${t:?}"; return 1
  fi
  for _ in $(seq 1 50); do [[ -s $t/nginx.pid ]] && break; sleep 0.1; done
  brand_probe() { # url expected-status [curl options]
    local url=$1 want=$2 code; shift 2
    code=$(curl -s "$@" -D "$t/h" -o "$t/b" -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)
    [[ $code == "$want" ]] || { out="$url answered $code, expected $want"; return 1; }
    if grep -qi 'nginx' "$t/h" "$t/b"; then out="$url names the server: $(grep -hi 'nginx' "$t/h" "$t/b" | head -n 1 | tr -d '\r')"; return 1; fi
    return 0
  }
  if ! brand_probe "http://127.0.0.1:$port/missing" 404; then rc=1
  elif ! grep -q '</html>' "$t/b"; then out="the 404 page is incomplete"; rc=1
  elif ! brand_probe "http://127.0.0.1:$port/e" 502; then rc=1
  else
    st=$(curl -s --max-time 5 "http://127.0.0.1:$port/s" 2>/dev/null || true)
    if [[ $st != *"Active connections"* ]]; then out="stub_status does not answer"; rc=1
    elif (( h2 )) && ! brand_probe "http://127.0.0.1:$port2/missing" 404 --http2-prior-knowledge; then rc=1
    fi
  fi
  if [[ -s $t/nginx.pid ]]; then
    kill -QUIT "$(cat "$t/nginx.pid")" 2>/dev/null || true
    for _ in $(seq 1 50); do [[ -e $t/nginx.pid ]] || break; sleep 0.1; done
    [[ -e $t/nginx.pid ]] && kill -TERM "$(cat "$t/nginx.pid")" 2>/dev/null
  fi
  rm -rf "${t:?}"
  (( rc == 0 )) || say "branding check failed: $out"
  return "$rc"
}

# ------------------------------------------------------------------ build
# Configure arguments: the paths of section 1 and the module set.  Shared
# with server-configs-nginx's CI through `configure-args` (one source, so the
# CI binary and the fleet's accept the same directives).
CONFIGURE_MODULES=(
  --with-threads --with-file-aio
  --with-http_ssl_module --with-http_v2_module --with-http_v3_module
  --with-http_realip_module --with-http_stub_status_module
  --without-http_ssi_module --without-http_userid_module --without-http_autoindex_module
  --without-http_split_clients_module --without-http_memcached_module --without-http_empty_gif_module
  --without-http_browser_module --without-http_uwsgi_module --without-http_scgi_module
  --without-http_grpc_module --without-http_mirror_module
  --without-http_limit_conn_module --without-http_referer_module
)
configure_paths() {
  printf '%s\n' --prefix="$ROOT" --sbin-path="$SBIN/nginx" --conf-path="$NGINX_CONF" \
    --pid-path=/run/nginx.pid --lock-path=/run/nginx.lock \
    --error-log-path=/var/www/logs/nginx/error.log --http-log-path=/var/www/logs/nginx/access.log \
    --http-client-body-temp-path=/var/cache/nginx/client_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp --user=www-data --group=www-data
}

build_deps() { # work jobs cflags: Brotli's static libraries for the static ngx_brotli
  local work=$1 j=$2 f=$3 nb
  nb=$work/ngx_brotli
  fetch_unpack ngx-brotli "${VERS[ngx-brotli]}" "$nb"
  rm -rf "$nb/deps/brotli"; mkdir -p "$nb/deps"
  fetch_unpack brotli "${VERS[brotli]}" "$nb/deps/brotli"
  # ngx_brotli links deps/brotli/out/libbrotli{enc,common}.a (static only, so
  # nothing can pick Ubuntu's libbrotli): same flags, ThinLTO on hosts.
  cmake -S "$nb/deps/brotli" -B "$nb/deps/brotli/out" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBROTLI_DISABLE_TESTS=ON \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_C_FLAGS="$f" >> "$LOG_FILE" 2>&1
  cmake --build "$nb/deps/brotli/out" -j "$j" --target brotlienc brotlicommon >> "$LOG_FILE" 2>&1
  # Only the filter is built (--add-module=.../ngx_brotli/filter, 1.22.1).
  # filter/config looks for the library under its own addon directory
  # (filter/deps/brotli); the root config, which also builds the static
  # module, is the only one that finds deps/ one level up.
  ln -sfn ../deps "$nb/filter/deps"
}

# AWS-LC: static libssl.a/libcrypto.a and the headers in
# WORK/tls-prefix, same compiler and flags as nginx (ThinLTO on hosts).  Only
# the two libraries are built (no tests, tools, Go or Perl); -Wno-error in the
# Release flags, which come after the projects' own -Werror.
tls_lib_build() { # work jobs cflags
  local work=$1 j=$2 f=$3 src=$1/$TLS_LIB pre=$1/tls-prefix bld l
  local -a opts=(-DDISABLE_GO=ON -DDISABLE_PERL=ON -DBUILD_TOOL=OFF)
  fetch_unpack "$TLS_LIB" "${VERS[$TLS_LIB]}" "$src"
  bld=$src/out
  cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="${CXX:-c++}" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_C_FLAGS="$f" -DCMAKE_CXX_FLAGS="$f" \
    -DCMAKE_C_FLAGS_RELEASE="-DNDEBUG -Wno-error" -DCMAKE_CXX_FLAGS_RELEASE="-DNDEBUG -Wno-error" \
    "${opts[@]}" >> "$LOG_FILE" 2>&1 || return 1
  cmake --build "$bld" -j "$j" --target ssl crypto >> "$LOG_FILE" 2>&1 || return 1
  rm -rf "$pre"; mkdir -p "$pre/lib" || return 1
  cp -a "$src/include" "$pre/" || return 1
  for l in libssl.a libcrypto.a; do
    f=$(find "$bld" -name "$l" -print -quit)
    [[ -n $f ]] || { say "$TLS_LIB: $l was not built"; return 1; }
    cp "$f" "$pre/lib/" || return 1
  done
}

# Unbranded default pages for `root html` (ROOT/html): what the stock
# html/index.html and 50x.html would say, without naming the server.
write_html() { # dir
  install -d -m 755 "$1"
  cat > "$1/50x.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Temporarily unavailable</title></head>
<body>
<h1>Temporarily unavailable</h1>
<p>The site cannot answer right now. Please try again in a few minutes.</p>
</body>
</html>
EOF
  cat > "$1/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Welcome</title></head>
<body>
<h1>Welcome</h1>
<p>This server is running. No site is configured for this address yet.</p>
</body>
</html>
EOF
  cat > "$1/404.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found</title></head>
<body>
<h1>Not found</h1>
<p>The page you asked for does not exist on this site.</p>
</body>
</html>
EOF
  chmod 644 "$1/50x.html" "$1/404.html" "$1/index.html"
}

# Fetch + unpack nginx VERSION into SRC and patch it.  0 patched; 1 refused.
nginx_source() { # version src
  rm -rf "$2"
  fetch_unpack nginx "$1" "$2" || die "nginx $1: the source did not unpack"
  brand_patch "$2"
}

# build: resolve (or, for "cpu", read build.info), fetch, patch, compile,
# verify, stage in ROOT/staging.  Nothing that serves changes.
cmd_build() { # [normal|cpu]
  local how=${1:-normal} work src n j line flags ld lto="" fb fail="" stamp rec
  # CI runners build as an ordinary user (ensure_packages uses sudo there).
  host_mode && need_root
  ensure_packages ca-certificates curl git xz-utils bzip2 make cmake ninja-build perl gpgv binutils autoconf automake libtool build-essential
  # CPU-change rebuild: the conf's values, valid or not, do not apply to it.
  # The TLS library is always AWS-LC (1.22.5); a build that recorded another
  # one (openssl, boringssl, or none before the TLS arms) is rebuilt on it.
  if [[ $how == cpu ]]; then CONF_INVALID=""; fi
  conf_invalid_die
  mkdir -p "$SRC_CACHE/src" "$LOGS"; chmod 700 "$SRC_CACHE"
  host_mode && build_space_check "$SRC_CACHE"
  build_deprioritize
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  LOG_FILE=$LOGS/nginx-$stamp.log
  : > "$LOG_FILE"; chmod 640 "$LOG_FILE"
  build_log_keep "$LOGS" nginx-
  if [[ $how == cpu ]]; then
    # CPU-change rebuild (R13): exactly what build.info recorded, never a
    # lookup; the same version patches with the same counts.
    for line in "${COMPONENTS[@]}"; do
      n=$(info_get "$line")
      # A build on a TLS library removed in 1.22.5 (openssl, boringssl;
      # openssl when none is recorded) recorded no aws-lc=: its version is
      # resolved (the cached lookup, else upstream).
      rec=$(info_get tls_lib); rec=${rec:-openssl}
      if [[ -z $n && $line == aws-lc && $rec != aws-lc ]]; then
        n=$(resolve aws-lc) || n=""
        if [[ -n $n ]]; then say "nginx: the recorded TLS library $rec was removed in 1.22.5; rebuilding with aws-lc $n"; fi
      fi
      [[ -n $n ]] || die "build.info records no $line version; run setup.sh --optimize"
      VERS[$line]=$n
    done
  else
    while IFS='=' read -r line n; do
      [[ $n == "?" ]] && die "cannot resolve the $line version (offline? pin $(conf_key "$line") in $CONF)"
      VERS[$line]=$n
    done < <(resolve_all || true)
  fi
  j=$(build_jobs)
  if host_mode; then
    n=${VERS[llvm]}
    [[ $n =~ ^[0-9]+$ ]] || die "LLVM_VERSION must be a major version (e.g. 23), not $n"
    if [[ $how == cpu ]]; then llvm_use_recorded "$n" "clang-$n" "lld-$n" "llvm-$n"
    else llvm_install "$n" "clang-$n" "lld-$n" "llvm-$n"
    fi
    export CC=$LLVM_BIN/clang CXX=$LLVM_BIN/clang++ AR=$LLVM_BIN/llvm-ar RANLIB=$LLVM_BIN/llvm-ranlib NM=$LLVM_BIN/llvm-nm
    flags="-O3 -march=native -mtune=native"
    lto="-flto=thin"
    # No -pie: clang builds a PIE by default.  --emit-relocs keeps what BOLT
    # needs in nginx.lto (stripped from the binary that runs).
    ld="-fuse-ld=lld $lto $(build_thinlto_flag "$j") -Wl,--emit-relocs -Wl,-z,relro,-z,now -Wl,--gc-sections"
  else
    # CI: the runner's cc, generic code, no LTO (minutes, not a fleet binary).
    CC=$(command -v cc); AR=$(command -v ar); RANLIB=$(command -v ranlib)
    export CC AR RANLIB
    flags="-O2"
    ld="-Wl,-z,relro,-z,now -Wl,--gc-sections"
  fi
  flags+=" -pipe -fPIC -fstack-protector-strong -fstack-clash-protection -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections"
  if [[ $(uname -m) == x86_64 ]]; then flags+=" -fcf-protection=full"; else flags+=" -mbranch-protection=standard"; fi
  work=$(mktemp -d "$SRC_CACHE/build.XXXXXX")
  WORK_DIR=$work
  [[ ${NGINX_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  say "building nginx ${VERS[nginx]} (log: $LOG_FILE)"
  src=$work/nginx
  if ! nginx_source "${VERS[nginx]}" "$src"; then
    fail=${VERS[nginx]}
    if [[ $how == cpu ]]; then
      die "nginx $fail: the branding patch no longer applies to the recorded version (source changed?)"
    fi
    if [[ $CONTEXT == refresh ]] && master_pid >/dev/null; then
      # The refresh never falls back while our nginx serves (that could be a
      # downgrade): the running binary keeps serving; tomorrow's run tries
      # again (R68).  With no master (a host left down by a failed CPU
      # chain, which the refresh exists to heal, R13) nothing can be
      # downgraded: the fallback below builds the recorded patched_ok or
      # NGINX_FALLBACK, whichever is newer.
      printf '%s\n' "$fail" > "$SKIP_FILE"
      say "nginx $fail: the branding patch does not apply (an upstream change moved a patched line); the running nginx keeps serving"
      exit 3
    fi
    fb=$(choose_fallback "$fail")
    [[ -n $fb ]] || die "nginx $fail: the branding patch does not apply and no known-good version is older (NGINX_FALLBACK in $CONF)"
    say "nginx $fail: the branding patch does not apply (an upstream change moved a patched line); building the known-good $fb instead"
    VERS[nginx]=$fb
    nginx_source "$fb" "$src" || die "nginx $fb: the branding patch does not apply either"
    if host_mode; then printf '%s\n' "$fail" > "$SKIP_FILE"; fi
  else
    rm -f "$SKIP_FILE"
  fi
  # The TLS library: AWS-LC built first and linked like a system library
  # (-I/-L, static archives only; its libssl is C++, hence -lstdc++).
  tls_lib_build "$work" "$j" "$flags $lto" || { log_excerpt "$LOG_FILE" 30; die "$TLS_LIB failed to build (log: $LOG_FILE)"; }
  local tls_cc=" -I$work/tls-prefix/include" tls_ld=" -L$work/tls-prefix/lib -lssl -lcrypto -lstdc++"
  fetch_unpack pcre2 "${VERS[pcre2]}" "$work/pcre2"
  # zlib-ng with zlib's API (1.21.70: gzip CPU per XenForo page -21 % against
  # Ubuntu's zlib, -19 % against zlib 1.4), built first and linked in through
  # -I/-L like a system zlib (only libz.a exists in that directory).
  fetch_unpack zlib-ng "${VERS[zlib-ng]}" "$work/zlib-ng"
  ( cd "$work/zlib-ng" && CC=$CC CFLAGS="$flags $lto" ./configure --static --zlib-compat \
      && make -j"$j" libz.a ) >> "$LOG_FILE" 2>&1 || { log_excerpt "$LOG_FILE" 30; die "zlib-ng failed to build (log: $LOG_FILE)"; }
  build_deps "$work" "$j" "$flags $lto" || { log_excerpt "$LOG_FILE" 30; die "Brotli failed to build (log: $LOG_FILE)"; }
  if [[ ! -x $src/configure ]]; then   # a Git snapshot keeps it in auto/
    [[ -x $src/auto/configure ]] || die "nginx ${VERS[nginx]}: no configure script in the source"
    cp "$src/auto/configure" "$src/configure"
  fi
  local -a cfg=()
  mapfile -t cfg < <(configure_paths)
  (
    cd "$src"
    # shellcheck disable=SC2086
    ./configure "${cfg[@]}" \
      --with-cc="$CC" --with-cc-opt="$flags $lto -I$work/zlib-ng$tls_cc" --with-ld-opt="$ld -L$work/zlib-ng$tls_ld" \
      "${CONFIGURE_MODULES[@]}" \
      --with-pcre="$work/pcre2" --with-pcre-jit --with-pcre-opt="$flags" \
      --add-module="$work/ngx_brotli/filter"
    nice -n 10 make -j"$j"
  ) >> "$LOG_FILE" 2>&1 || { log_excerpt "$LOG_FILE" 40; die "nginx ${VERS[nginx]} failed to build (log: $LOG_FILE)"; }
  verify_binary "$src/objs/nginx"
  rm -rf "$STAGING"
  install -d -m 755 "$STAGING/sbin"
  if host_mode; then
    install -m 755 "$src/objs/nginx" "$STAGING/sbin/nginx.lto"
    install_stripped "$STAGING/sbin/nginx.lto" "$STAGING/sbin/nginx"
  else
    install -m 755 "$src/objs/nginx" "$STAGING/sbin/nginx"
  fi
  write_html "$STAGING/html"
  # The migration's path map points `root /usr/share/angie/html` at
  # ROOT/html before anything is activated; seed it once (unbranded, nothing
  # serves from it yet) so the rendered tree finds it.  activate replaces it.
  if host_mode && [[ ! -d $ROOT/html ]]; then write_html "$ROOT/html"; fi
  {
    printf 'recipe=%s\n' "$BUILD_RECIPE"
    for line in "${COMPONENTS[@]}"; do printf '%s=%s\n' "$line" "${VERS[$line]}"; done
    printf 'tls_lib=%s\ntls_opts=%s\n' "$TLS_LIB" "$(tls_key "$TLS_LIB")"
    printf 'patched_ok=%s\n' "${VERS[nginx]}"
    [[ -n $fail ]] && printf 'fallback_from=%s\n' "$fail"
    printf 'compiler=%s\n' "$("$CC" --version | sed -n 1p)"
    printf 'cpu=%s\n' "$(cpu_fingerprint)"
    printf 'cpu_info=%s\n' "$(cpu_fingerprint_text)"
    [[ $CI == 1 ]] && printf 'ci=1\n'
    printf 'log=%s\n' "$LOG_FILE"
    printf 'built=%s\nbolt=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$STAGING/build.info"
  # The work tree goes now, not on exit (a rebuild runs BOLT next in the
  # same process; R66: free the disk as soon as a component is done).
  [[ ${NGINX_BUILD_KEEP_WORK:-0} == 1 ]] || { rm -rf "$work"; WORK_DIR=""; }
  say "nginx ${VERS[nginx]} built and verified: $STAGING/sbin/nginx"
}

# The candidate reports its version, links none of the compiled-in libraries
# from Ubuntu, has ngx_brotli compiled in statically (`--add-module=`, the
# form server-configs-nginx's CI matches; never --add-dynamic-module) and
# passes the branding check.
#
# The live configuration is only TESTED here (report mode), never edited:
# `build` runs while the old binary serves (install, --optimize, the refresh
# timer, the CPU chain), and R2.5 promises that it changes nothing that
# serves.  Commenting out droppable directives in the operator's files is
# `activate`'s job (cmd_activate runs fit_config right before the swap, and
# lib/nginx-build.sh reports every line it comments out).
verify_binary() { # binary
  local cand=$1 needed v err
  v=$(bin_version "$cand")
  [[ -n $v ]] || die "candidate does not report an nginx version"
  needed=$(readelf -d "$cand" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ { print $2 }')
  if grep -qE "$STATIC_LIBS_RE" <<<"$needed"; then
    die "candidate links Ubuntu's $(grep -E "$STATIC_LIBS_RE" <<<"$needed" | tr '\n' ' ')instead of the upstream builds"
  fi
  # Captured, not piped into grep -q: with pipefail an early grep exit can
  # SIGPIPE the writer and fail a good candidate.
  v=$("$cand" -V 2>&1 || true)
  [[ $v == *--add-module=*ngx_brotli* ]] || die "candidate has no static ngx_brotli (nginx -V lacks --add-module=...ngx_brotli)"
  [[ $v == *--with-http_stub_status_module* ]] || die "candidate has no stub_status"
  # "built with OpenSSL 1.1.1 (compatible; AWS-LC x.y.z)": AWS-LC is the only
  # TLS library (1.22.5), never an OpenSSL picked up by mistake.
  [[ $v == *AWS-LC* ]] || die "candidate is not built with AWS-LC"
  branding_check "$cand" || die "candidate failed the branding check (log: $LOG_FILE)"
  if live_test_enabled; then
    apply_tmpfiles
    if ! err=$(conf_test "$cand"); then
      say "nginx build: the live configuration does not pass with this build yet ($(grep -m1 -E 'emerg|error' <<<"$err" || sed -n 1p <<<"$err")); activation comments out droppable directives (reported) or refuses, and the running nginx keeps serving"
    fi
  fi
}

# ------------------------------------------------------------------ swap
# Put NEW (and LTO / INFO when given) in place of the active files, keeping
# the current ones as *.prev, then make the running master use them through
# nginx's in-place upgrade; with no master, start the unit (unless the web
# ports belong to another server or this is the migration's build phase).
# On failure every file is put back.
swap_in() { # new [lto] [info]
  local new=$1 lto=${2:-} info=${3:-} old taken
  install -d -m 755 "$SBIN" "$STATE"
  # *.prev hold exactly what this swap replaces (nothing stale from an
  # earlier run may be "restored").
  rm -f "$SBIN/nginx.prev" "$SBIN/nginx.lto.prev" "$STATE/build.info.prev"
  [[ -f $SBIN/nginx ]] && ln -f "$SBIN/nginx" "$SBIN/nginx.prev"
  [[ -n $lto && -f $SBIN/nginx.lto ]] && ln -f "$SBIN/nginx.lto" "$SBIN/nginx.lto.prev"
  [[ -n $info && -f $STATE/build.info ]] && cp -f "$STATE/build.info" "$STATE/build.info.prev"
  install -m 755 "$new" "$SBIN/nginx.new"; mv -f "$SBIN/nginx.new" "$SBIN/nginx"
  if [[ -n $lto ]]; then install -m 755 "$lto" "$SBIN/nginx.lto.new"; mv -f "$SBIN/nginx.lto.new" "$SBIN/nginx.lto"; fi
  if [[ -n $info ]]; then install -m 644 "$info" "$STATE/build.info.new"; mv -f "$STATE/build.info.new" "$STATE/build.info"; fi
  # The operator's shell link (R2.1: /usr/local/sbin, never a dpkg-owned path).
  if [[ -n $LINK && ( ! -e $LINK || -L $LINK ) ]]; then
    install -d -m 755 "$(dirname "$LINK")"; ln -sfn "$SBIN/nginx" "$LINK.new" && mv -Tf "$LINK.new" "$LINK"
  fi
  if old=$(master_pid); then
    if upgrade_master "$old"; then return 0; fi
    swap_back
    # The old master normally keeps serving through all of this; only when
    # it is gone too does nginx restart, on the restored binary.
    if ! master_pid >/dev/null; then
      say "nginx: no master left; restarting on the previous binary"
      systemctl restart nginx.service || true
    fi
    die "nginx: the new binary was not taken over (in-place upgrade failed); the previous one keeps serving"
  fi
  if [[ $CONTEXT == migrate || $CONTEXT == cpu || ${NGINX_BUILD_NO_START:-0} == 1 ]]; then
    say "nginx: build installed; not started (${CONTEXT})"; return 0
  fi
  if taken=$(ports_taken); then
    say "nginx: build installed; not started: the web ports belong to $taken (the migration cutover starts nginx)"
    return 0
  fi
  [[ -f $UNIT_DIR/nginx.service ]] || { say "nginx: $UNIT_DIR/nginx.service is missing; build installed, not started"; return 0; }
  [[ -f $NGINX_CONF ]] || { say "nginx: build installed; not started: $NGINX_CONF does not exist yet"; return 0; }
  if systemctl start nginx.service && serving_probe; then return 0; fi
  say "nginx did not start on the new build: $(systemctl status nginx.service --no-pager -n 3 2>/dev/null | tail -n 3 | tr '\n' ' ')"
  swap_back
  die "nginx: the new binary did not start; the previous one is back in place"
}

swap_back() {
  [[ -f $SBIN/nginx.prev ]] && mv -f "$SBIN/nginx.prev" "$SBIN/nginx"
  [[ -f $SBIN/nginx.lto.prev ]] && mv -f "$SBIN/nginx.lto.prev" "$SBIN/nginx.lto"
  [[ -f $STATE/build.info.prev ]] && mv -f "$STATE/build.info.prev" "$STATE/build.info"
  say "nginx: previous binary restored"
}

# nginx's in-place binary upgrade (R67), so a swap drops no connection and
# leaves no window with the ports closed (a restart waited up to
# worker_shutdown_timeout 30 s with QUIT before the new master bound them):
#  1. `nginx -t` with the new binary (already renamed over ROOT/sbin/nginx,
#     which is the argv[0] USR2 re-executes);
#  2. USR2: the old master renames nginx.pid to nginx.pid.oldbin and starts
#     the new master, which writes nginx.pid; wait up to 10 s for it;
#  3. WINCH the old master: its workers finish their requests and exit, so
#     only the new workers accept; probe 127.0.0.1;
#  4. QUIT the old master.  systemd (Type=forking, PIDFile) re-reads the pid
#     file when its main process exits and follows the new master.
# Rollback before 4: HUP the old master (new workers on the old binary),
# QUIT the new one; nginx renames nginx.pid.oldbin back when the new master
# exits.  Status 1 after a rollback.
upgrade_master() { # old-pid
  local old=$1 new="" i main
  if ! conf_test "$SBIN/nginx" >/dev/null; then
    fit_config "$SBIN/nginx" || { say "nginx: the new binary rejects $NGINX_CONF; not upgraded"; return 1; }
  fi
  kill -USR2 "$old" || return 1
  for (( i = 0; i < 100; i++ )); do
    if [[ -f $PIDFILE.oldbin ]]; then
      new=$(cat "$PIDFILE" 2>/dev/null || true)
      if [[ $new =~ ^[0-9]+$ && $new != "$old" ]] && kill -0 "$new" 2>/dev/null; then break; fi
    fi
    new=""; sleep 0.1
  done
  if [[ -z $new ]]; then
    say "nginx: the new master did not come up within 10 s; the old one keeps serving"
    # A new master that hangs without a pid file: its pid is the old master's child.
    local c
    for c in $(pgrep -P "$old" -x nginx 2>/dev/null || true); do
      if [[ $(readlink "/proc/$c/exe" 2>/dev/null) == "$SBIN/nginx" && $(ps -o args= -p "$c" 2>/dev/null) == *master* ]]; then
        kill -TERM "$c" 2>/dev/null || true
      fi
    done
    return 1
  fi
  kill -WINCH "$old" 2>/dev/null || true
  sleep 1
  if ! pgrep -P "$new" >/dev/null 2>&1 || ! serving_probe; then
    say "nginx: the new master (pid $new) does not serve; back to the old one (pid $old)"
    kill -HUP "$old" 2>/dev/null || true
    kill -QUIT "$new" 2>/dev/null || true
    for (( i = 0; i < 100; i++ )); do kill -0 "$new" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$new" 2>/dev/null && kill -TERM "$new" 2>/dev/null
    return 1
  fi
  kill -QUIT "$old" 2>/dev/null || true
  # The old master exits once its draining workers are done
  # (worker_shutdown_timeout 30 s in server-configs-nginx).
  for (( i = 0; i < 400; i++ )); do kill -0 "$old" 2>/dev/null || break; sleep 0.1; done
  for (( i = 0; i < 50; i++ )); do
    main=$(systemctl show -p MainPID --value nginx.service 2>/dev/null || true)
    [[ $main == "$new" ]] && break
    sleep 0.1
  done
  if [[ $main != "$new" ]]; then
    if ! systemctl is-active -q nginx.service; then
      say "nginx: systemd lost track of the upgraded master; starting the unit"
      systemctl start nginx.service || return 1
    else
      say "nginx: systemd's MainPID is $main, the new master is $new (check: systemctl status nginx)"
    fi
  fi
  serving_probe || say "nginx: WARNING: no answer on 127.0.0.1 after the upgrade (systemctl status nginx)"
  say "nginx: now running $(bin_version "$SBIN/nginx") (pid $new, in-place upgrade)"
  return 0
}

cmd_activate() {
  need_root
  host_mode || die "activate is not available in CI mode"
  [[ -x $STAGING/sbin/nginx && -f $STAGING/build.info ]] || die "nothing staged in $STAGING (run build first)"
  apply_tmpfiles
  if live_test_enabled && ! fit_config "$STAGING/sbin/nginx"; then
    die "the staged nginx rejects $NGINX_CONF (a module this lean build leaves out); the running nginx keeps serving"
  fi
  rm -rf "$ROOT/html.new"; cp -a "$STAGING/html" "$ROOT/html.new"
  rm -rf "$ROOT/html"; mv "$ROOT/html.new" "$ROOT/html"
  rm -f "$STATE/nginx.fdata"
  # swap_in rolls back and dies itself on failure (called plainly so set -e
  # stays in force inside it).
  swap_in "$STAGING/sbin/nginx" "$STAGING/sbin/nginx.lto" "$STAGING/build.info"
  rm -rf "$STAGING"
  rm -f "$SBIN/nginx.lto.prev" "$STATE/build.info.prev"
  say "nginx $(info_get nginx) active (BOLT pending: applied under traffic)"
}

# ExecStartPre: refuse a build made for another CPU (-march=native: a SIGILL
# crash loop otherwise) and test the configuration with the build itself.  A
# droppable directive added since activation is commented out (reported);
# any other rejection keeps nginx down with nginx's own error.
cmd_pre() {
  local built now
  [[ -x $SBIN/nginx ]] || die "no nginx build in $SBIN (run setup.sh --optimize)"
  built=$(info_get cpu); now=$(cpu_fingerprint)
  if ! cpu_fingerprint_matches "$built" "$(info_get cpu_info)"; then
    say "nginx: built for CPU ${built:-unknown}, this CPU is ${now:-unknown}: staying down until setup-build-cpu.service has rebuilt it"
    systemctl start --no-block setup-build-cpu.service >/dev/null 2>&1 || true
    exit 1
  fi
  [[ -z $CONF_INVALID ]] || say "nginx: nginx-build.conf: ${CONF_INVALID%; } (ignored here; the next build refuses it)"
  apply_tmpfiles
  conf_test "$SBIN/nginx" >/dev/null && return 0
  fit_config "$SBIN/nginx" && return 0
  exit 1
}

# ------------------------------------------------------------------ BOLT
# Only while every PHP pool nginx proxies to is up: a profile taken while PHP
# is down is an error-page profile (R65).
php_upstreams_up() {
  local f u
  for f in "$UNIT_DIR"/php*-fpm.service; do
    [[ -f $f ]] || continue
    u=${f##*/}
    [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] || continue
    systemctl is-active -q "$u" || { say "nginx: $u is not active; BOLT sampling skipped"; return 1; }
  done
  return 0
}

cmd_bolt() {
  local secs=${1:-60} n perf work p2b bolt samples base=$SBIN/nginx.lto info stamp rc
  need_root
  host_mode || die "no BOLT in CI mode"
  [[ -f $base ]] || die "no build to BOLT"
  master_pid >/dev/null || die "nginx is not running"
  php_upstreams_up || return 3
  n=$(info_get llvm)
  perf=$(command -v perf || true)
  if [[ -z $perf ]] || ! "$perf" --version >/dev/null 2>&1; then
    ensure_packages "linux-tools-$(uname -r)" linux-tools-common || die "perf is not installable for kernel $(uname -r)"
    perf=$(command -v perf)
  fi
  llvm_install "$n" "bolt-$n"
  p2b=$LLVM_BIN/perf2bolt; bolt=$LLVM_BIN/llvm-bolt
  [[ -x $p2b && -x $bolt ]] || die "llvm-bolt/perf2bolt $n not found in $LLVM_BIN"
  mkdir -p "$SRC_CACHE" "$LOGS"
  work=$(mktemp -d "$SRC_CACHE/bolt.XXXXXX")
  WORK_DIR=$work
  [[ ${NGINX_BUILD_KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "${WORK_DIR:-}"' EXIT
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  LOG_FILE=$LOGS/nginx-bolt-$stamp.log
  : > "$LOG_FILE"; chmod 640 "$LOG_FILE"
  build_log_keep "$LOGS" nginx-
  # perf2bolt maps samples to nginx.lto by build ID: the running binary must
  # be the ThinLTO build, not an earlier BOLT output.
  if [[ $(info_get bolt) == 1 ]]; then
    install_stripped "$base" "$work/nginx.lto-run"
    sed 's/^bolt=.*/bolt=0/' "$STATE/build.info" > "$work/build.info"
    swap_in "$work/nginx.lto-run" "" "$work/build.info"
  fi
  say "nginx: sampling for ${secs}s for BOLT (log: $LOG_FILE)"
  # Branch records (LBR) unless this host has none (bolt_record, 1.22.5):
  # bolt=nolbr / noperf then stop the refresh and the --optimize retry until
  # the next build.
  rc=0; bolt_record "$perf" "$work/perf.data" "$work/perf.log" "$secs" || rc=$?
  cat "$work/perf.log" >> "$LOG_FILE" 2>/dev/null || true
  case $rc in
    0) ;;
    4) info_put "$STATE/build.info" bolt nolbr
       say "nginx: no branch samples on this host (a VM or a CPU without LBR); BOLT skipped until the next build (bolt=nolbr)"
       return 3 ;;
    5) info_put "$STATE/build.info" bolt noperf
       say "nginx: perf cannot sample on this host; BOLT skipped until the next build (bolt=noperf)"
       return 3 ;;
    *) perf_record_die "$work/perf.log" ;;
  esac
  # No nginx samples at all (an idle server, e.g. a fresh install with no
  # site yet): perf2bolt fails with "Please rename the input binary".  That
  # is too little traffic, not an error (1.22.0 fresh-install test).
  if ! "$p2b" -p "$work/perf.data" -o "$work/nginx.fdata" "$base" > "$work/p2b.log" 2>&1; then
    cat "$work/p2b.log" >> "$LOG_FILE"
    if grep -qE 'Please rename the input binary|no samples|0 out of [0-9]+ functions' "$work/p2b.log"; then
      say "nginx: no samples in ${secs}s: too little traffic, BOLT skipped"
      return 3
    fi
    tail -n 5 "$work/p2b.log" >&2; die "perf2bolt failed"
  fi
  cat "$work/p2b.log" >> "$LOG_FILE"
  samples=$(awk '/BOLT-INFO: [0-9]+ out of [0-9]+ functions in the binary/ { print $2 }' "$LOG_FILE" | sed -n 1p)
  if [[ ${samples:-0} -lt $BOLT_MIN_FUNCS ]]; then
    say "nginx: ${samples:-0} functions profiled in ${secs}s (need $BOLT_MIN_FUNCS): too little traffic, BOLT skipped"
    return 3
  fi
  # No -use-gnu-stack: it turned PT_GNU_STACK into the new code segment
  # (executable stack); bolt_stack_check refuses such an output.
  "$bolt" "$base" -o "$work/nginx.bolt" -data="$work/nginx.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -icf >> "$LOG_FILE" 2>&1 \
    || { log_excerpt "$LOG_FILE" 5; die "llvm-bolt failed"; }
  bolt_stack_check "$work/nginx.bolt"
  [[ -n $(bin_version "$work/nginx.bolt") ]] || die "the BOLT output does not run"
  conf_test "$work/nginx.bolt" >/dev/null || die "the BOLT output rejects $NGINX_CONF"
  install -m 600 "$work/nginx.fdata" "$STATE/nginx.fdata"
  install_stripped "$work/nginx.bolt" "$work/nginx.run"
  info=$work/build.info.bolt
  # A bolt_mode= left by the removed plain-cycles profile goes: this one is
  # a branch-record profile.
  sed -e 's/^bolt=.*/bolt=1/' -e '/^bolt_mode=/d' "$STATE/build.info" > "$info"
  swap_in "$work/nginx.run" "" "$info"
  rm -f "$STATE/build.info.prev"
  say "nginx: BOLT applied from ${samples} profiled functions"
}

# ------------------------------------------------------------------ cycles
# Steps that may fail without failing the caller run as their own process:
# inside `cmd || ...` bash ignores set -e for everything cmd calls, and an
# unchecked failing step would then carry on.  The lock is inherited
# (SETUP_BUILD_LOCK_HELD=1), the context passed on.
self() { NGINX_BUILD_CONTEXT=$CONTEXT bash "$SELF" "$@"; }

cmd_rebuild() { # build, activate, let traffic warm up, then BOLT
  cmd_build normal
  cmd_activate
  sleep "${NGINX_BUILD_BOLT_DELAY:-300}"
  self bolt 60 || true
}

# setup-build-cpu.service's nginx stage: the recorded versions for this CPU,
# offline; the chain starts nginx.service afterwards.
cmd_rebuild_cpu() {
  need_root
  [[ -f $STATE/build.info ]] || die "no build.info in $STATE: nothing to rebuild (run setup.sh --optimize)"
  if [[ -x $SBIN/nginx ]] && cpu_fingerprint_matches "$(info_get cpu)" "$(info_get cpu_info)"; then
    say "nginx: the build already matches this CPU"; return 0
  fi
  BUILD_OFFLINE=1
  CONTEXT=cpu
  cmd_build cpu
  cmd_activate
}

# Re-fetch any missing cached archive of the recorded versions while the host
# is healthy, so a CPU rebuild never needs the network (R33).
cache_ensure() {
  local c v
  for c in "${COMPONENTS[@]}"; do
    [[ $c == llvm ]] && continue
    v=$(info_get "$c"); [[ -n $v ]] || continue
    ( fetch_component "$c" "$v" >/dev/null ) 2>/dev/null || say "nginx: could not cache $c $v for offline rebuilds"
  done
}

# check [INFO]: is the build recorded in INFO (default: the active
# ROOT/build/build.info) current?  lib/nginx-build.sh also asks it about
# ROOT/staging/build.info before activating a leftover staged build (an
# aborted migration's build-only, a failed earlier activate): a staging made
# for another recipe, CPU or older versions is discarded, never swapped in.
cmd_check() { # [info]
  local info=${1:-$STATE/build.info} name want have stale="" rc=0 bcpu skip n
  [[ -f $info ]] || { echo "no build"; return 10; }
  conf_invalid_die
  [[ $(info_get recipe "$info") == "$BUILD_RECIPE" ]] || stale+="recipe $(info_get recipe "$info") -> $BUILD_RECIPE, "
  [[ $(info_get ci "$info") != 1 ]] || stale+="CI build, "
  # The TLS library: a build.info without tls_opts= (before the TLS arms,
  # always openssl) or with an openssl/BoringSSL key is stale (1.22.5: AWS-LC
  # only) and is rebuilt on AWS-LC.
  have=$(info_get tls_opts "$info")
  want=$(tls_key "$TLS_LIB")
  if [[ $have != "$want" ]]; then
    have=$(info_get tls_lib "$info")
    stale+="TLS options ${have:-openssl} -> $TLS_LIB, "
  fi
  # Options removed in 1.22.5: a build made with another allocator than
  # glibc's (MALLOC=, none recorded before 1.22.5) or BOLTed from the
  # plain-cycles profile (bolt_mode=nolbr) is rebuilt on the default.  An
  # OpenSSL or BoringSSL build is stale through tls_opts= above.
  n=$(info_get malloc "$info")
  [[ ${n:-glibc} == glibc ]] || stale+="malloc $n -> glibc (removed in 1.22.5), "
  [[ $(info_get bolt_mode "$info") != nolbr ]] || stale+="BOLT profile without branch samples (removed in 1.22.5), "
  bcpu=$(info_get cpu "$info")
  cpu_fingerprint_matches "$bcpu" "$(info_get cpu_info "$info")" || stale+="cpu ${bcpu:-unknown} -> $(cpu_fingerprint), "
  n=$(info_get llvm "$info")
  if [[ -n $n && ! -x /usr/lib/llvm-$n/bin/clang && ! -x $LLVM_OPT/$n/bin/clang ]]; then stale+="LLVM $n missing, "; fi
  skip=$(cat "$SKIP_FILE" 2>/dev/null || true)
  while IFS='=' read -r name want; do
    if [[ $want == "?" ]]; then rc=2; continue; fi
    have=$(info_get "$name" "$info")
    # A version the branding patch was refused for is not due again.
    [[ $name == nginx && -n $skip && $want == "$skip" ]] && continue
    [[ $have == "$want" ]] || stale+="$name ${have:-none} -> $want, "
  done < <(resolve_all || true)
  if [[ -n $stale ]]; then echo "stale: ${stale%, }"; return 10; fi
  if [[ -n $skip ]]; then echo "current (nginx $skip skipped: the branding patch does not apply to it)"; else echo current; fi
  return "$rc"
}

# The daily refresh (setup-build-refresh.service, under the build lock):
# never takes nginx down.  A CPU mismatch left by a failed CPU chain gets a
# full resolve-latest build (R13); a stale build is rebuilt and swapped in
# place; a current but un-BOLTed one is BOLTed under traffic.
cmd_refresh() {
  local rc=0 out
  [[ -f $STATE/build.info ]] || return 0
  # Same gates as the chain driver (build-common.sh build_chain_refresh), for
  # a `refresh` started by hand: never during the migration or a setup.sh run.
  if migration_pending; then say "nginx refresh skipped: the 1.22 migration is not finished"; return 0; fi
  if setup_run_active; then say "nginx refresh skipped: a setup.sh run is in progress"; return 0; fi
  CONTEXT=refresh
  cache_ensure
  out=$(cmd_check 2>/dev/null) || rc=$?
  if (( rc == 10 )); then
    say "nginx: $out; rebuilding in the background"
    rc=0; self build >/dev/null || rc=$?
    if (( rc == 3 )); then return 0; fi
    (( rc == 0 )) || { say "nginx: refresh build failed; the running nginx keeps serving"; return 1; }
    self activate || return 1
    if ! master_pid >/dev/null && [[ $(systemctl is-enabled nginx.service 2>/dev/null) == enabled ]]; then
      systemctl reset-failed nginx.service >/dev/null 2>&1 || true
      systemctl start nginx.service || true
    fi
    sleep "${NGINX_BUILD_BOLT_DELAY:-300}"
    self bolt 60 || true
  elif bolt_retry_due "$(info_get bolt)" && master_pid >/dev/null; then
    # (bolt=nolbr / noperf: this host cannot record the profile; not
    # retried until the next build.)
    self bolt 60 || true
  fi
  return 0
}

# build-arm DIR: a benchmark build into its own prefix, never activated.
# A child `build` with NGINX_BUILD_ROOT=DIR (so --prefix/--sbin-path are DIR,
# the staging is DIR/staging), this nginx-build.conf (or NGINX_BUILD_CONF,
# e.g. one per arm with its own AWS_LC_VERSION / NGINX_VERSION), no live
# configuration test (`build` never touches the link); then DIR/sbin/nginx.
# Nothing under ROOT changes and nothing is started.  An arm whose non-TLS
# components differ from the live build (or that fell back) gets a warning:
# its benchmark rows would not compare like with like.
cmd_build_arm() { # dir
  local dir f c diff=""
  host_mode || die "build-arm is not available in CI mode"
  [[ ${1:-} == /* ]] && dir=$(realpath -m -- "$1") || dir=""
  [[ $dir == /?* && $dir != "$ROOT" && $dir != "$ROOT"/* && $ROOT != "$dir"/* ]] \
    || die "build-arm DIR: an absolute directory outside and not above $ROOT"
  NGINX_BUILD_ROOT=$dir NGINX_BUILD_CONF=$CONF NGINX_BUILD_LIVE_TEST=0 \
    NGINX_BUILD_CONTEXT=install bash "$SELF" build >/dev/null
  install -d -m 755 "$dir/sbin"
  for f in nginx nginx.lto; do
    [[ -f $dir/staging/sbin/$f ]] && mv -f "$dir/staging/sbin/$f" "$dir/sbin/$f"
  done
  mv -f "$dir/staging/build.info" "$dir/build.info"
  rm -rf "${dir:?}/staging"
  for c in nginx llvm pcre2 zlib-ng brotli ngx-brotli; do
    [[ $(info_get "$c" "$dir/build.info") == "$(info_get "$c")" ]] || diff+=" $c"
  done
  [[ -z $(info_get fallback_from "$dir/build.info") ]] || diff+=" (nginx fell back)"
  [[ -z $diff ]] || say "WARNING: $dir differs from the live build in:$diff (pin them in the arm's conf)"
  printf '%s\n' "$dir/sbin/nginx"
}

cmd_status() {
  local cpu="match" pid
  if [[ -f $STATE/build.info ]]; then
    cpu_fingerprint_matches "$(info_get cpu)" "$(info_get cpu_info)" || cpu="MISMATCH (rebuild pending)"
    pid=$(master_pid || true)
    printf 'nginx: build %s (clang %s, recipe %s), bolt=%s, cpu %s, %s\n' \
      "$(info_get nginx)" "$(info_get llvm)" "$(info_get recipe)" "$(info_get bolt)" "$cpu" \
      "$([[ -n $pid ]] && echo "running (pid $pid)" || echo "not running")"
  else
    printf 'nginx: no build in %s\n' "$ROOT"
  fi
  [[ -f $STAGING/build.info ]] && printf 'nginx: staged %s (not active yet)\n' "$(info_get nginx "$STAGING/build.info")"
  [[ -z $CONF_INVALID ]] || printf "nginx: nginx-build.conf: %s (ignored: build and check refuse it)\n" "${CONF_INVALID%; }"
  return 0
}

# The compiled nginx's files (lib/nginx-build.sh nginx_build_purge removes
# the units, links and tmpfiles; /etc/nginx and logs stay).
cmd_remove() {
  restore_config
  rm -rf "${STAGING:?}" "${SBIN:?}" "${STATE:?}" "${ROOT:?}/html" "$SKIP_FILE"
}

main() {
  local cmd=${1:-status} rc=0
  case $cmd in
    build|build-only)
      if host_mode; then build_lock_run cmd_build normal >&2; else cmd_build normal >&2; fi
      printf '%s\n' "$STAGING/sbin/nginx" ;;
    build-arm)      need_root; cmd_build_arm "${2:-}" ;;
    activate)       build_lock_run cmd_activate ;;
    bolt)           build_lock_run cmd_bolt "${2:-60}" ;;
    rebuild)        build_lock_run cmd_rebuild ;;
    rebuild-cpu)    build_lock_run cmd_rebuild_cpu ;;
    refresh)
      build_lock_try cmd_refresh || rc=$?
      if (( rc == 75 )); then say "nginx refresh skipped: build lock held"; return 0; fi
      return "$rc" ;;
    check)          cmd_check ${2:+"$2"} ;;
    versions)       resolve_all ;;
    status)         cmd_status ;;
    pre)            cmd_pre ;;
    fit)
      # fit [CONF [BIN]]: the live tree with the active binary, or (migration
      # pre-flight) a rendered copy with the staged one; prints what it
      # comments out, status 1 on a directive it cannot comment out.
      need_root
      local conf=${2:-$NGINX_CONF} bin=${3:-}
      if [[ -z $bin ]]; then
        if [[ -x $SBIN/nginx ]]; then bin=$SBIN/nginx; else bin=$STAGING/sbin/nginx; fi
      fi
      [[ -x $bin ]] || die "no nginx binary to test with"
      apply_tmpfiles
      fit_config "$bin" "$conf" ;;
    restore)        need_root; restore_config ;;
    remove)         need_root; cmd_remove ;;
    configure-args) configure_paths; printf '%s\n' "${CONFIGURE_MODULES[@]}" --add-module=ngx_brotli/filter ;;
    directive-res)  printf 'droppable=%s\nunbuilt=%s\n' "$DROPPABLE_RE" "$UNBUILT_RE" ;;
    *) die "usage: $0 build|build-only|build-arm DIR|activate|bolt [S]|rebuild|rebuild-cpu|refresh|check|versions|status|pre|fit [CONF [BIN]]|restore|remove|configure-args|directive-res" ;;
  esac
}

[[ ${NGINX_BUILD_SOURCE_ONLY:-0} == 1 ]] || main "$@"
