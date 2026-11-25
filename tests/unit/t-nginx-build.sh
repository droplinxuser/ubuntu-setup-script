# shellcheck shell=bash
# Unit tests for the compiled nginx of 1.22.0 (1.22.1: no gzip_static, only
# the ngx_brotli filter): tools/nginx-build.sh (branding
# patch and fallback version, configure module set, CPU gate, fit/restore,
# CI mode, PGP verification, in-place upgrade), tools/build-common.sh (CPU
# fingerprint) and lib/nginx-build.sh (unit and tmpfiles texts, the
# last-consumer rule of the shared build units).
#
# Sourced by tests/test-tuning.sh after setup.sh: it uses that file's check,
# t_skip, not, TMP, ROOT and the lib/*.sh functions.  No root, no network, no
# services: every tool function runs in a subshell with the host-facing
# commands (systemctl, kill, gpgv, curl downloads, ...) replaced by stubs, and
# every path the tool would touch points under TMP.
# The stubs are called indirectly by the functions under test; the sourced
# tool assigns globals ShellCheck cannot follow; the fit fixtures quote nginx
# variables literally.
# shellcheck disable=SC1090,SC1091,SC2016,SC2034,SC2317,SC2329

if ! declare -F check >/dev/null || [[ -z ${TMP:-} || -z ${ROOT:-} ]]; then
  printf 't-nginx-build.sh: source it from tests/test-tuning.sh (it needs check, TMP and ROOT)\n' >&2
  return 1 2>/dev/null || exit 1
fi

# The tool assigns its own ROOT (the build prefix) when sourced: keep the
# repository path under another name.
TNB_REPO=$ROOT
TNB_SRC="$TNB_REPO/tests/fixtures/nginx-src"
TNB_CPU="$TNB_REPO/tests/fixtures/cpuinfo"
# Versions relative to the tool's built-in fallback, so a bump of
# NGINX_FALLBACK_DEFAULT does not break the fallback cases.
TNB_FB=$(sed -n 's/^NGINX_FALLBACK_DEFAULT=//p' "$TNB_REPO/tools/nginx-build.sh")
TNB_FB1=${TNB_FB%.*}.$(( ${TNB_FB##*.} + 1 ))
TNB_FB2=${TNB_FB%.*}.$(( ${TNB_FB##*.} + 2 ))
TNB_FB3=${TNB_FB%.*}.$(( ${TNB_FB##*.} + 3 ))

tnb_has()   { [[ $1 == *"$2"* ]]; }
tnb_lacks() { [[ $1 != *"$2"* ]]; }
tnb_line()  { grep -qxF -- "$2" <<<"$1"; }
tnb_noline() { ! grep -qxF -- "$2" <<<"$1"; }

# tnb_env DIR: export scratch paths for tools/nginx-build.sh.  Called inside
# a subshell, before sourcing the tool, so nothing leaks into test-tuning.sh.
tnb_env() {
  local d=$1
  rm -rf "${d:?}"
  mkdir -p "$d/root/build" "$d/cache" "$d/units" "$d/etc" "$d/run"
  : > "$d/systemctl.log"; : > "$d/calls"
  export NGINX_BUILD_SOURCE_ONLY=1 NGINX_BUILD_ROOT="$d/root" NGINX_BUILD_CACHE="$d/cache" \
    NGINX_BUILD_UNIT_DIR="$d/units" NGINX_BUILD_CONF="$d/nginx-build.conf" \
    NGINX_BUILD_NGINX_CONF="$d/etc/nginx.conf" NGINX_BUILD_PIDFILE="$d/run/nginx.pid" \
    NGINX_BUILD_TMPFILES="$d/tmpfiles.conf" NGINX_BUILD_LINK="$d/link/nginx" \
    SETUP_BUILD_LOCK="$d/build.lock" SETUP_MIGRATE_STATE="$d/migrate-1.22" SETUP_RUN_LOCK="$d/setup.lock" \
    SETUP_BUILD_CPU_ATTEMPTS="$d/cpu.attempts" SETUP_BUILD_MIRROR=off SETUP_CPUINFO="$TNB_CPU/x86-a"
  unset NGINX_BUILD_CI NGINX_BUILD_CONTEXT NGINX_BUILD_KEEP_WORK NGINX_BUILD_COMMON SETUP_BUILD_LOCK_HELD
}
# After sourcing the tool: tests drive failure paths on purpose, and say()
# must not write to the journal.
tnb_quiet() {
  set +eE
  trap - ERR
  say() { printf '%s\n' "$*" >&2; }
  logger() { :; }
}

# Change the first `r->headers_out.server == NULL` of FILE (an upstream
# refactor that moved one patched line).
tnb_break_count() {
  awk '!done && sub(/r->headers_out\.server == NULL/, "r->headers_out.server != NULL") { done = 1 } { print }' "$1" > "$1.tmp" \
    && mv -f "$1.tmp" "$1"
}

# ---------------------------------------------------------------------------
# brand_patch: counts checked before anything changes, never half-patched
# ---------------------------------------------------------------------------
tnb_brand_case() ( # variant -> "rc=N patched=a,b,c tails=N body=N unchanged=0|1 msg=0|1"
  local NB=$TMP/tnb-brand d rc=0 f p="" msg=0
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  d=$NB/src
  cp -R "$TNB_SRC" "$d"
  case $1 in
    ok) ;;
    twice) brand_patch "$d" >/dev/null 2>&1 ;;
    header) tnb_break_count "$d/src/http/v3/ngx_http_v3_filter_module.c" ;;
    extra) printf '    if (r->headers_out.server == NULL) { }\n' >> "$d/src/http/v2/ngx_http_v2_filter_module.c" ;;
    pages)
      awk '!done && /^"<hr><center>/ { done = 1; next } { print }' "$d/src/http/ngx_http_special_response.c" > "$NB/p" \
        && mv -f "$NB/p" "$d/src/http/ngx_http_special_response.c" ;;
    missing) rm -f "$d/src/http/v2/ngx_http_v2_filter_module.c" ;;
  esac
  cp -R "$d" "$NB/before"
  brand_patch "$d" 2>"$NB/err" || rc=$?
  for f in "${BRAND_HEADER_FILES[@]}"; do
    p+="$( { grep -oF '0 && r->headers_out.server == NULL' "$d/$f" 2>/dev/null || true; } | wc -l | tr -d ' '),"
  done
  case $1 in
    header) grep -q 'ngx_http_v3_filter_module.c has 1 .*expected 2' "$NB/err" && msg=1 ;;
    extra) grep -q 'ngx_http_v2_filter_module.c has 3 .*expected 2' "$NB/err" && msg=1 ;;
    pages) grep -q "has 2 .*expected 3" "$NB/err" && msg=1 ;;
    missing) grep -q 'ngx_http_v2_filter_module.c is missing' "$NB/err" && msg=1 ;;
    twice) grep -q 'already patched' "$NB/err" && msg=1 ;;
    ok) [[ ! -s $NB/err ]] && msg=1 ;;
  esac
  printf 'rc=%s patched=%s tails=%s body=%s unchanged=%s msg=%s' "$rc" "${p%,}" \
    "$(grep -c '<hr><center>' "$d/$BRAND_PAGES_FILE" 2>/dev/null || true)" \
    "$(grep -c '^"</body>"' "$d/$BRAND_PAGES_FILE" 2>/dev/null || true)" \
    "$(diff -r "$NB/before" "$d" >/dev/null 2>&1 && echo 1 || echo 0)" "$msg"
)
check "brand_patch: the fixture source is patched (2 Server-header tests per filter, no error page tail)" \
  test "$(tnb_brand_case ok)" = "rc=0 patched=2,2,2 tails=0 body=3 unchanged=0 msg=1"
check "brand_patch: an already patched tree is refused, never patched twice" \
  test "$(tnb_brand_case twice)" = "rc=1 patched=2,2,2 tails=0 body=3 unchanged=1 msg=1"
check "brand_patch: a moved Server-header test (count 1) is refused and the tree is left untouched" \
  test "$(tnb_brand_case header)" = "rc=1 patched=0,0,0 tails=3 body=3 unchanged=1 msg=1"
check "brand_patch: an extra Server-header test (count 3) is refused and the tree is left untouched" \
  test "$(tnb_brand_case extra)" = "rc=1 patched=0,0,0 tails=3 body=3 unchanged=1 msg=1"
check "brand_patch: two error page tails instead of three is refused before any header file changes" \
  test "$(tnb_brand_case pages)" = "rc=1 patched=0,0,0 tails=2 body=3 unchanged=1 msg=1"
check "brand_patch: a missing filter source is refused" \
  bash -c '[[ $1 == rc=1\ *unchanged=1\ msg=1 ]]' _ "$(tnb_brand_case missing)"

# ---------------------------------------------------------------------------
# choose_fallback: the newest known-good version that is older than the
# refused one (this host's patched_ok, NGINX_FALLBACK, the built-in default)
# ---------------------------------------------------------------------------
tnb_fallback() ( # fail patched_ok conf-line -> chosen version
  local NB=$TMP/tnb-fallback
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  [[ -n $2 ]] && printf 'patched_ok=%s\n' "$2" > "$STATE/build.info"
  [[ -n $3 ]] && printf '%s\n' "$3" > "$CONF"
  printf '%s' "$(choose_fallback "$1")"
)
check "choose_fallback: with no record and no NGINX_FALLBACK the built-in known-good version is used" \
  test "$(tnb_fallback "$TNB_FB2" "" "")" = "$TNB_FB"
check "choose_fallback: this host's last patched build wins when it is newer than the default" \
  test "$(tnb_fallback "$TNB_FB2" "$TNB_FB1" "")" = "$TNB_FB1"
check "choose_fallback: NGINX_FALLBACK in nginx-build.conf (quoted, with a comment) is honoured" \
  test "$(tnb_fallback "$TNB_FB2" "" "NGINX_FALLBACK=\"$TNB_FB1\"  # pinned")" = "$TNB_FB1"
check "choose_fallback: a recorded build newer than the refused version is never chosen" \
  test "$(tnb_fallback "$TNB_FB2" "$TNB_FB3" "")" = "$TNB_FB"
check "choose_fallback: the refused version itself is never the fallback (nothing older: empty)" \
  test "$(tnb_fallback "$TNB_FB" "" "")" = ""

# cmd_build up to the first library download: the patch, the fallback
# decision and the skip record, with every host step stubbed.  The stubbed
# fetch of openssl records the nginx version being built and stops.
tnb_build_case() ( # ci context how version bad-versions [patched_ok] [master] -> "rc=N reached=V skip=S needroot=N"
  local NB=$TMP/tnb-build ci=$1 ctx=$2 how=$3 ver=$4 bad=$5 pok=${6:-} master=${7:-} rc=0 c
  tnb_env "$NB"
  export NGINX_BUILD_CI=$ci NGINX_BUILD_CONTEXT=$ctx
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  need_root() { echo need_root >> "$NB/calls"; }
  ensure_packages() { :; }
  build_space_check() { :; }
  build_deprioritize() { :; }
  build_jobs() { printf 1; }
  build_thinlto_flag() { printf -- '-Wl,--thinlto-jobs=1'; }
  llvm_install() { LLVM_BIN=$NB/llvm; }
  llvm_use_recorded() { LLVM_BIN=$NB/llvm; }
  master_pid() { [[ -n $master ]] && printf 4242; }
  resolve_all() {
    printf 'nginx=%s\n' "$ver"
    printf '%s\n' llvm=23 openssl=3.6.0 pcre2=10.47 zlib-ng=2.3.1 brotli=1.2.0 ngx-brotli=a71f931
  }
  fetch_unpack() { # name version dir
    if [[ $1 == nginx ]]; then
      mkdir -p "$3" && cp -R "$TNB_SRC/." "$3/"
      [[ " $bad " == *" $2 "* ]] && tnb_break_count "$3/src/http/v3/ngx_http_v3_filter_module.c"
      return 0
    fi
    printf '%s' "${VERS[nginx]}" > "$NB/reached"
    exit 0
  }
  printf 'old\n' > "$SKIP_FILE"
  if [[ $how == cpu ]]; then
    : > "$STATE/build.info"
    while IFS= read -r c; do printf '%s\n' "$c" >> "$STATE/build.info"; done < <(resolve_all)
  fi
  [[ -n $pok ]] && printf 'patched_ok=%s\n' "$pok" >> "$STATE/build.info"
  ( cmd_build "$how" ) >/dev/null 2>"$NB/err" || rc=$?
  printf 'rc=%s reached=%s skip=%s needroot=%s' "$rc" "$(cat "$NB/reached" 2>/dev/null || echo none)" \
    "$(cat "$SKIP_FILE" 2>/dev/null || echo none)" "$(grep -c need_root "$NB/calls")"
)
tnb_build_err() { cat "$TMP/tnb-build/err" 2>/dev/null; }
check "build: a mainline the patch refuses builds the known-good fallback and records the refused version" \
  test "$(tnb_build_case 0 install normal "$TNB_FB2" "$TNB_FB2")" = "rc=0 reached=$TNB_FB skip=$TNB_FB2 needroot=1"
check "build: the fallback is reported as 'building the known-good ... instead'" \
  tnb_has "$(tnb_build_err)" "building the known-good $TNB_FB instead"
check "build: a version the patch accepts is built and clears the skip record" \
  test "$(tnb_build_case 0 install normal "$TNB_FB2" "")" = "rc=0 reached=$TNB_FB2 skip=none needroot=1"
check "build: the fallback prefers this host's newer patched_ok over the default" \
  test "$(tnb_build_case 0 install normal "$TNB_FB2" "$TNB_FB2" "$TNB_FB1")" = "rc=0 reached=$TNB_FB1 skip=$TNB_FB2 needroot=1"
check "build: the daily refresh never falls back while our nginx serves (status 3, refusal recorded)" \
  test "$(tnb_build_case 0 refresh normal "$TNB_FB2" "$TNB_FB2" "" master)" = "rc=3 reached=none skip=$TNB_FB2 needroot=1"
check "build: the refresh of a host left without a master does build the fallback" \
  test "$(tnb_build_case 0 refresh normal "$TNB_FB2" "$TNB_FB2")" = "rc=0 reached=$TNB_FB skip=$TNB_FB2 needroot=1"
check "build: with no older known-good version the build stops (no download of the rest)" \
  test "$(tnb_build_case 0 install normal "$TNB_FB" "$TNB_FB")" = "rc=1 reached=none skip=old needroot=1"
check "build: a fallback the patch refuses too stops the build" \
  test "$(tnb_build_case 0 install normal "$TNB_FB2" "$TNB_FB2 $TNB_FB")" = "rc=1 reached=none skip=old needroot=1"
check "build: the refusal names the fallback that does not apply either" \
  tnb_has "$(tnb_build_err)" "nginx $TNB_FB: the branding patch does not apply either"
check "build: the CPU rebuild never falls back to another version than build.info records" \
  test "$(tnb_build_case 0 install cpu "$TNB_FB2" "$TNB_FB2")" = "rc=1 reached=none skip=old needroot=1"
check "build: CI mode falls back the same way, without root and without a skip record" \
  test "$(tnb_build_case 1 install normal "$TNB_FB2" "$TNB_FB2")" = "rc=0 reached=$TNB_FB skip=old needroot=0"

# ---------------------------------------------------------------------------
# configure module set (shared with server-configs-nginx's CI)
# ---------------------------------------------------------------------------
TNB_ARGS=$(env -u NGINX_BUILD_SOURCE_ONLY -u NGINX_BUILD_CI -u NGINX_BUILD_NGINX_CONF \
  NGINX_BUILD_ROOT="$TMP/tnb-args/root" bash "$TNB_REPO/tools/nginx-build.sh" configure-args 2>/dev/null || true)
TNB_ARGS_CI=$(env -u NGINX_BUILD_SOURCE_ONLY -u NGINX_BUILD_NGINX_CONF NGINX_BUILD_CI=1 \
  NGINX_BUILD_ROOT="$TMP/tnb-args/root" bash "$TNB_REPO/tools/nginx-build.sh" configure-args 2>/dev/null || true)
tnb_args_have() { local a; for a in "$@"; do tnb_line "$TNB_ARGS" "$a" || return 1; done; }
tnb_args_lack() { local a; for a in "$@"; do tnb_noline "$TNB_ARGS" "$a" || return 1; done; }
check "configure-args: only the Brotli filter is compiled in statically (--add-module=ngx_brotli/filter, no dynamic module)" \
  bash -c 'grep -qx -- "--add-module=ngx_brotli/filter" <<<"$1" && ! grep -qx -- "--add-module=ngx_brotli" <<<"$1" && ! grep -q -- "--add-dynamic-module" <<<"$1"' _ "$TNB_ARGS"
check "configure-args: no gzip_static and no ngx_brotli static module (removed in 1.22.1)" \
  bash -c '! grep -q -- "gzip_static" <<<"$1" && ! grep -q -- "ngx_brotli/static" <<<"$1"' _ "$TNB_ARGS"
check "configure-args: the filter form still matches the static-Brotli checks (*--add-module=*ngx_brotli*)" \
  bash -c 'v=$(tr "\n" " " <<<"$1"); [[ $v == *--add-module=*ngx_brotli* ]]' _ "$TNB_ARGS"
check "configure-args: SSL, HTTP/2, HTTP/3, realip, threads and stub_status are built" \
  tnb_args_have --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module \
    --with-threads --with-http_stub_status_module
check "configure-args: auth_basic and limit_req stay in the build (never --without-...)" \
  tnb_args_lack --without-http_auth_basic_module --without-http_limit_req_module
check "configure-args: limit_conn, SSI, userid, autoindex, referer and the unused handlers are left out" \
  tnb_args_have --without-http_limit_conn_module --without-http_ssi_module --without-http_userid_module \
    --without-http_autoindex_module --without-http_referer_module --without-http_split_clients_module \
    --without-http_memcached_module --without-http_empty_gif_module --without-http_browser_module \
    --without-http_uwsgi_module --without-http_scgi_module --without-http_grpc_module --without-http_mirror_module
check "configure-args: no mail, stream, DAV, sub, mp4/flv, auth_request, secure_link or other extra module" \
  bash -c '! grep -qE -- "^--with-(mail|stream|http_dav|http_sub|http_mp4|http_flv|http_addition|http_auth_request|http_secure_link|http_slice|http_image_filter|http_xslt|http_perl|http_geoip|http_random_index|http_gunzip|compat)" <<<"$1"' _ "$TNB_ARGS"
check "configure-args: the paths of the compiled layout (ROOT/sbin/nginx, /etc/nginx, /run/nginx.pid, www-data)" \
  tnb_args_have "--sbin-path=$TMP/tnb-args/root/sbin/nginx" --conf-path=/etc/nginx/nginx.conf \
    --pid-path=/run/nginx.pid --user=www-data --group=www-data
check "configure-args: CI mode prints exactly the same module set and paths" \
  bash -c '[[ -n $1 && $1 == "$2" ]]' _ "$TNB_ARGS" "$TNB_ARGS_CI"
check "cmd_build configures with CONFIGURE_MODULES and a static --add-module of the ngx_brotli filter" \
  bash -c 'f=$(sed -n "/^cmd_build()/,/^}/p" "$1"); grep -qF "\"\${CONFIGURE_MODULES[@]}\"" <<<"$f" && grep -qF -- "--add-module=\"\$work/ngx_brotli/filter\"" <<<"$f" && ! grep -qF -- "--add-module=\"\$work/ngx_brotli\"" <<<"$f" && ! grep -q -- "--add-dynamic-module" <<<"$f"' \
  _ "$TNB_REPO/tools/nginx-build.sh"
# filter/config looks for Brotli under filter/deps (the 1.22.1 test-host
# install failed with "Brotli library is missing" without this link).
check "build_deps links filter/deps to the Brotli sources and libraries one level up" \
  bash -c 'sed -n "/^build_deps()/,/^}/p" "$1" | grep -qF "ln -sfn ../deps \"\$nb/filter/deps\""' \
  _ "$TNB_REPO/tools/nginx-build.sh"
tnb_res_ok() {
  local res drop unb
  res=$(env -u NGINX_BUILD_SOURCE_ONLY bash "$TNB_REPO/tools/nginx-build.sh" directive-res 2>/dev/null) || return 1
  drop=$(sed -n 's/^droppable=//p' <<<"$res"); unb=$(sed -n 's/^unbuilt=//p' <<<"$res")
  [[ -n $drop && -n $unb ]] || return 1
  [[ limit_conn =~ $drop && limit_conn_zone =~ $drop && ssi =~ $drop && sub_filter =~ $drop ]] || return 1
  # Left out since 1.22.1: commented out with the marker, never a blocker.
  [[ gzip_static =~ $drop && brotli_static =~ $drop ]] || return 1
  [[ gzip_static =~ $unb || brotli_static =~ $unb ]] && return 1
  [[ auth_request =~ $unb && grpc_pass =~ $unb && valid_referers =~ $unb ]] || return 1
  # Built-in modules are neither droppable nor blockers.
  local d
  for d in auth_basic auth_basic_user_file limit_req limit_req_zone brotli brotli_comp_level gzip gzip_comp_level stub_status; do
    [[ $d =~ $drop || $d =~ $unb ]] && return 1
  done
  return 0
}
check "directive classes: limit_conn/ssi/gzip_static/brotli_static droppable, auth_request blocks, auth_basic/limit_req/brotli/gzip are built in" tnb_res_ok
check "the migration's fallback droppable list matches the tool's (gzip_static and brotli_static included)" \
  bash -c 'a=$(sed -n "s/^DROPPABLE_RE=//p" "$1"); b=$(sed -n "s/^MIGRATE_NGINX_DROPPABLE_RE=//p" "$2"); [[ -n $a && $a == "$b" ]]' \
  _ "$TNB_REPO/tools/nginx-build.sh" "$TNB_REPO/lib/migrate.sh"
check "lib/nginx-build.sh exports the tool's droppable list to the migration (gzip_static included)" \
  bash -c 'v=$(sed -n "s/^DROPPABLE_RE='"'"'\(.*\)'"'"'\$/\1/p" "$1" | sed -n 1p); [[ gzip_static =~ $v && brotli_static =~ $v ]]' _ "$TNB_REPO/tools/nginx-build.sh"
check "build recipe 5 (1.22.1): a host built with recipe 4 is stale and rebuilds without gzip_static/brotli_static" \
  grep -qx 'BUILD_RECIPE=5' "$TNB_REPO/tools/nginx-build.sh"

# ---------------------------------------------------------------------------
# nginx.service and tmpfiles.d (lib/nginx-build.sh)
# ---------------------------------------------------------------------------
TNB_UNIT=$(nginx_unit_text)
check "nginx.service: Type=forking with PIDFile=/run/nginx.pid (the configure --pid-path)" \
  bash -c 'grep -qx "Type=forking" <<<"$1" && grep -qx "PIDFile=/run/nginx.pid" <<<"$1" && grep -qx -- "--pid-path=/run/nginx.pid" <<<"$2"' _ "$TNB_UNIT" "$TNB_ARGS"
check "nginx.service: ExecStartPre runs the installed tool's CPU gate + test ('pre')" \
  tnb_line "$TNB_UNIT" "ExecStartPre=${NGINX_ROOT}/nginx-build.sh pre"
check "nginx.service: the tool knows the 'pre' command the unit runs" \
  grep -qE '^[[:space:]]+pre\)[[:space:]]+cmd_pre' "$TNB_REPO/tools/nginx-build.sh"
check "nginx.service: ExecStart is the compiled binary under ROOT, never a /usr path" \
  bash -c 'grep -qx "ExecStart=$2/sbin/nginx" <<<"$1" && ! grep -qE "^Exec[A-Za-z]*=/usr/s?bin/(nginx|angie)" <<<"$1"' _ "$TNB_UNIT" "$NGINX_ROOT"
check "nginx.service: the limits drop-in moved into the unit (LimitNOFILE=524288, UMask=0027)" \
  bash -c 'grep -qx "LimitNOFILE=524288" <<<"$1" && grep -qx "UMask=0027" <<<"$1"' _ "$TNB_UNIT"
check "nginx.service: reload tests first, then HUP; stop is a graceful QUIT" \
  bash -c 'grep "^ExecReload=" <<<"$1" | sed -n 1p | grep -q -- "-t -q$" && grep "^ExecReload=" <<<"$1" | sed -n 2p | grep -qF "kill -s HUP \$MAINPID" && grep -qxF "ExecStop=/bin/kill -s QUIT \$MAINPID" <<<"$1"' _ "$TNB_UNIT"
check "nginx.service: no Restart= (a refused CPU gate must not loop)" \
  bash -c '! grep -q "^Restart=" <<<"$1"' _ "$TNB_UNIT"
TNB_TMPF=$(nginx_tmpfiles_text)
tnb_tmpfiles_ok() {
  local p n=0
  tnb_line "$TNB_TMPF" 'd /var/cache/nginx 0700 www-data www-data -' || return 1
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    n=$(( n + 1 ))
    tnb_line "$TNB_TMPF" "d $p 0700 www-data www-data -" || return 1
  done < <(sed -n 's/^--http-[a-z-]*-temp-path=//p' <<<"$TNB_ARGS")
  (( n == 5 )) || return 1
  p=$(sed -n 's/^--error-log-path=//p' <<<"$TNB_ARGS")
  tnb_line "$TNB_TMPF" "d ${p%/*} 0750 www-data www-data -" || return 1
  p=$(sed -n 's/^--http-log-path=//p' <<<"$TNB_ARGS")
  tnb_line "$TNB_TMPF" "d ${p%/*} 0750 www-data www-data -"
}
check "tmpfiles.d: every compiled temp path (0700 www-data) and the log directory (0750) exist before nginx -t" tnb_tmpfiles_ok
check "tmpfiles.d: nothing world-readable and no other path" \
  bash -c '! grep -vE "^(#|d /var/cache/nginx(/[a-z]+_temp)? 0700 www-data www-data -$|d /var/www/logs/nginx 0750 www-data www-data -$)" <<<"$1"' _ "$TNB_TMPF"

# ---------------------------------------------------------------------------
# CPU fingerprint: an allow-list of ISA flags, security flags ignored
# ---------------------------------------------------------------------------
tnb_fp() ( # cpuinfo-file -> fingerprint
  . "$TNB_REPO/tools/build-common.sh"
  set +eE; trap - ERR
  SETUP_CPUINFO=$1 cpu_fingerprint
)
tnb_fp_text() ( # cpuinfo-file -> hashed text
  . "$TNB_REPO/tools/build-common.sh"
  set +eE; trap - ERR
  SETUP_CPUINFO=$1 cpu_fingerprint_text
)
TNB_FPA=$(tnb_fp "$TNB_CPU/x86-a")
TNB_FPT=$(tnb_fp_text "$TNB_CPU/x86-a")
check "cpu_fingerprint: a 16-hex-digit hash on x86 and on arm64" \
  bash -c '[[ $1 =~ ^[0-9a-f]{16}$ && $2 =~ ^[0-9a-f]{16}$ ]]' _ "$TNB_FPA" "$(tnb_fp "$TNB_CPU/arm64")"
check "cpu_fingerprint: microcode, MHz, flag order, mitigation flags and bugs do not change it (kernel update)" \
  test "$(tnb_fp "$TNB_CPU/x86-b")" = "$TNB_FPA"
check "cpu_fingerprint: only the first processor block counts" \
  bash -c 'awk "/^\$/ { b++ } b == 1 && /^flags/" "$1" | grep -q avx512f && [[ $2 == "$3" ]]' _ "$TNB_CPU/x86-b" "$(tnb_fp "$TNB_CPU/x86-b")" "$TNB_FPA"
check "cpu_fingerprint: a new ISA extension (AVX-512) is a CPU change" \
  bash -c '[[ -n $1 && $1 != "$2" ]]' _ "$(tnb_fp "$TNB_CPU/x86-c")" "$TNB_FPA"
check "cpu_fingerprint: another CPU model is a CPU change" \
  bash -c '[[ -n $1 && $1 != "$2" ]]' _ "$(tnb_fp "$TNB_CPU/x86-d")" "$TNB_FPA"
check "cpu_fingerprint: the text maps pni/abm/rdrand to sse3/lzcnt/rdrnd and keeps the model" \
  bash -c '[[ $1 == *"model=106;"* && $1 == *isa=*sse3* && $1 == *lzcnt* && $1 == *rdrnd* && $1 != *pni* ]]' _ "$TNB_FPT"
check "cpu_fingerprint: no security or hypervisor flag and no microcode in the hashed text" \
  bash -c 'for w in ibrs ibpb ssbd stibp md_clear flush_l1d arch_capabilities retbleed hypervisor microcode spectre; do [[ $1 == *"$w"* ]] && exit 1; done; exit 0' _ "$TNB_FPT"
check "cpu_fingerprint: arm64 hashes implementer/part and the Features line" \
  bash -c '[[ $1 == *"CPU part=0xd0c;"* && $1 == *isa=*asimd* ]]' _ "$(tnb_fp_text "$TNB_CPU/arm64")"
check "cpu_fingerprint: no readable cpuinfo gives an empty fingerprint (every gate reads that as a mismatch)" \
  test -z "$(tnb_fp "$TMP/tnb-no-such-cpuinfo")"
check "build-common.sh cpu-fingerprint (script mode) prints the same hash" \
  test "$(SETUP_CPUINFO="$TNB_CPU/x86-a" bash "$TNB_REPO/tools/build-common.sh" cpu-fingerprint 2>/dev/null)" = "$TNB_FPA"

# ---------------------------------------------------------------------------
# pre (ExecStartPre): a build for another CPU only starts setup-build-cpu
# ---------------------------------------------------------------------------
tnb_pre_case() ( # built-on run-on -> "rc=N systemctl=[...] tested=N"
  local NB=$TMP/tnb-pre rc=0
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  apply_tmpfiles() { :; }
  systemctl() { printf '%s\n' "$*" >> "$NB/systemctl.log"; return 0; }
  conf_test() { echo conf_test >> "$NB/calls"; return 0; }
  fit_config() { echo fit >> "$NB/calls"; return 0; }
  install -d "$SBIN"
  printf '#!/bin/sh\nexit 0\n' > "$SBIN/nginx"; chmod 755 "$SBIN/nginx"
  if [[ $1 == none ]]; then : > "$STATE/build.info"
  else printf 'nginx=1.0.0\ncpu=%s\n' "$(SETUP_CPUINFO=$TNB_CPU/$1 cpu_fingerprint)" > "$STATE/build.info"
  fi
  export SETUP_CPUINFO=$TNB_CPU/$2
  ( cmd_pre ) >/dev/null 2>&1 || rc=$?
  printf 'rc=%s systemctl=[%s] tested=%s' "$rc" "$(tr '\n' ',' < "$NB/systemctl.log")" "$(grep -c conf_test "$NB/calls")"
)
check "pre: a build for this CPU tests the configuration and starts nothing else" \
  test "$(tnb_pre_case x86-a x86-a)" = "rc=0 systemctl=[] tested=1"
check "pre: after a kernel/microcode update (same ISA) nginx starts normally" \
  test "$(tnb_pre_case x86-b x86-a)" = "rc=0 systemctl=[] tested=1"
check "pre: a build for another CPU fails and starts only setup-build-cpu.service (no nginx -t)" \
  test "$(tnb_pre_case x86-c x86-a)" = "rc=1 systemctl=[start --no-block setup-build-cpu.service,] tested=0"
check "pre: a build.info without cpu= is a mismatch, never a skipped check" \
  test "$(tnb_pre_case none x86-a)" = "rc=1 systemctl=[start --no-block setup-build-cpu.service,] tested=0"
check "pre: an unreadable cpuinfo is a mismatch, never a skipped check" \
  test "$(tnb_pre_case x86-a no-such-file)" = "rc=1 systemctl=[start --no-block setup-build-cpu.service,] tested=0"
check "pre: the unit it starts is the CPU chain unit setup.sh writes" \
  test "${SETUP_BUILD_CPU_UNIT##*/}" = "setup-build-cpu.service"

# ---------------------------------------------------------------------------
# fit / restore: marker round trip
# ---------------------------------------------------------------------------
# A stand-in for `nginx -t -q -c CONF`: reports the first active directive
# of a module the build leaves out as nginx does (on the line of its ';').
tnb_fake_nginx() { # path
  cat > "$1" <<'EOF'
#!/bin/sh
conf=""
while [ $# -gt 0 ]; do [ "$1" = -c ] && { conf=$2; shift; }; shift; done
for f in "$conf" "$(dirname "$conf")"/conf.d/*.conf; do
  [ -f "$f" ] || continue
  hit=$(awk '$1 ~ /^#/ { next }
    !name && ($1 == "sub_filter" || $1 == "limit_conn_zone" || $1 == "limit_conn" || $1 == "ssi" || $1 == "grpc_pass" || $1 == "gzip_static" || $1 == "brotli_static") { name = $1 }
    name && /;/ { print FILENAME ":" FNR " " name; exit }' "$f")
  if [ -n "$hit" ]; then
    echo "nginx: [emerg] unknown directive \"${hit##* }\" in ${hit% *}" >&2
    exit 1
  fi
done
exit 0
EOF
  chmod 755 "$1"
}
tnb_fit_case() ( # variant -> result line
  local NB=$TMP/tnb-fit rc=0 site
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  tnb_fake_nginx "$NB/nginx"
  mkdir -p "$NB/etc/conf.d" "$NB/outside"
  printf 'events {}\nhttp {\n    include conf.d/*.conf;\n}\n' > "$NB/etc/nginx.conf"
  site=$NB/etc/conf.d/site.conf
  printf '%s\n' 'server {' '    listen 80;' "    sub_filter 'a' 'b';" '    limit_conn_zone $binary_remote_addr' \
    '        zone=perip:10m;' '    location / { }' '}' > "$site"
  cp "$site" "$NB/site.orig"
  case $1 in
    roundtrip|migrate)
      [[ $1 == migrate ]] && CONTEXT=migrate
      fit_config "$NB/nginx" 2>"$NB/err" || rc=$?
      printf 'rc=%s marked=%s ' "$rc" "$(grep -c '^[[:space:]]*# setup-nginx-build-off: ' "$site")"
      printf 'lines=%s ' "$(grep -n '# setup-nginx-build-off: ' "$site" | cut -d: -f1 | tr '\n' ',')"
      printf 'list=[%s] ' "$(tr '\n' ',' 2>/dev/null < "$STATE/disabled.list")"
      printf 'warn=%s ' "$(grep -c 'commented out limit_conn_zone in conf.d/site.conf:5 (security control removed' "$NB/err")"
      restore_config 2>/dev/null
      printf 'restored=%s listgone=%s' "$(cmp -s "$site" "$NB/site.orig" && echo 1 || echo 0)" \
        "$([[ -e $STATE/disabled.list ]] && echo 0 || echo 1)" ;;
    angie)
      printf '%s\n' '    # setup-angie-build-off: ssi on;' '#   a plain comment stays' > "$NB/etc/conf.d/old.conf"
      restore_config 2>/dev/null
      printf '%s|%s' "$(sed -n 1p "$NB/etc/conf.d/old.conf")" "$(sed -n 2p "$NB/etc/conf.d/old.conf")" ;;
    blocker)
      printf '%s\n' 'server {' '    location /g {' '        grpc_pass grpc://backend;' '    }' '}' > "$site"
      cp "$site" "$NB/site.orig"
      fit_config "$NB/nginx" 2>"$NB/err" || rc=$?
      printf 'rc=%s unchanged=%s emerg=%s' "$rc" "$(cmp -s "$site" "$NB/site.orig" && echo 1 || echo 0)" \
        "$(grep -c 'unknown directive "grpc_pass"' "$NB/err")" ;;
    symlink)
      rm -f "$site"
      printf '%s\n' 'server {' "    sub_filter 'a' 'b';" '}' > "$NB/outside/shared.conf"
      cp "$NB/outside/shared.conf" "$NB/shared.orig"
      ln -s "$NB/outside/shared.conf" "$NB/etc/conf.d/shared.conf"
      fit_config "$NB/nginx" 2>/dev/null || rc=$?
      printf 'rc=%s unchanged=%s' "$rc" "$(cmp -s "$NB/outside/shared.conf" "$NB/shared.orig" && echo 1 || echo 0)" ;;
    static)
      # 1.22.1: an operator vhost that still asks for precompressed siblings.
      printf '%s\n' 'server {' '    gzip on;' '    location /assets/ {' '        gzip_static on;' \
        '        brotli_static on;' '    }' '}' > "$site"
      fit_config "$NB/nginx" 2>"$NB/err" || rc=$?
      printf 'rc=%s lines=%s ' "$rc" "$(grep -n '^[[:space:]]*# setup-nginx-build-off: ' "$site" | cut -d: -f1 | tr '\n' ',')"
      printf 'gzip=%s ' "$(grep -cx '    gzip on;' "$site")"
      printf 'list=[%s] ' "$(tr '\n' ',' 2>/dev/null < "$STATE/disabled.list")"
      printf 'said=%s' "$(grep -c 'nginx build: commented out [a-z_]*_static in conf.d/site.conf' "$NB/err")" ;;
  esac
)
check "fit: droppable directives are commented out line by line (a two-line directive whole)" \
  bash -c '[[ $1 == "rc=0 marked=3 lines=3,4,5, "* ]]' _ "$(tnb_fit_case roundtrip)"
check "fit: disabled.list records path:line directive for the report" \
  tnb_has "$(tnb_fit_case roundtrip)" "list=[conf.d/site.conf:3 sub_filter,conf.d/site.conf:5 limit_conn_zone,]"
check "fit: a commented-out limit_conn* is reported as a removed security control" \
  tnb_has "$(tnb_fit_case roundtrip)" "warn=1 "
check "restore: the file is byte-identical to the original and disabled.list is gone" \
  tnb_has "$(tnb_fit_case roundtrip)" "restored=1 listgone=1"
check "fit: the migration's fit writes no disabled.list (it reports its own lines) and still restores" \
  bash -c '[[ $1 == "rc=0 marked=3 "*"list=[] "*"restored=1 "* ]]' _ "$(tnb_fit_case migrate)"
check "restore: the 1.21 Angie marker is undone too; plain comments stay" \
  test "$(tnb_fit_case angie)" = "    ssi on;|#   a plain comment stays"
check "fit: a content handler of a left-out module (grpc_pass) is a blocker; nothing is edited" \
  test "$(tnb_fit_case blocker)" = "rc=1 unchanged=1 emerg=1"
check "fit: a symlinked file (pointing outside the tree) is never edited; the fit fails" \
  test "$(tnb_fit_case symlink)" = "rc=1 unchanged=1"
check "fit: gzip_static and brotli_static in an operator vhost are commented out with the marker; gzip stays" \
  test "$(tnb_fit_case static)" = "rc=0 lines=4,5, gzip=1 list=[conf.d/site.conf:4 gzip_static,conf.d/site.conf:5 brotli_static,] said=2"

# ---------------------------------------------------------------------------
# CI mode: build output on stderr, the staged binary's path on stdout
# ---------------------------------------------------------------------------
tnb_ci_case() ( # ci -> "stdout|calls|components"
  local NB=$TMP/tnb-ci out
  tnb_env "$NB"
  export NGINX_BUILD_CI=$1
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  cmd_build() { printf 'compiling noise on stdout\n'; say "progress on stderr"; }
  build_lock_run() { echo lock >> "$NB/calls"; "$@"; }
  need_root() { echo need_root >> "$NB/calls"; }
  out=$(main build 2>/dev/null)
  printf '%s|%s|%s' "$out" "$(tr '\n' ',' < "$NB/calls")" "${COMPONENTS[*]}"
)
check "CI mode: 'build' prints only ROOT/staging/sbin/nginx on stdout, without the build lock" \
  test "$(tnb_ci_case 1)" = "$TMP/tnb-ci/root/staging/sbin/nginx||nginx openssl pcre2 zlib-ng brotli ngx-brotli"
check "host mode: 'build' takes the build lock and also ends stdout with the staging path" \
  test "$(tnb_ci_case 0)" = "$TMP/tnb-ci/root/staging/sbin/nginx|lock,|nginx llvm openssl pcre2 zlib-ng brotli ngx-brotli"
check "CI mode: activate and BOLT are refused" \
  bash -c 'grep -qF "host_mode || die \"activate is not available in CI mode\"" "$1" && grep -qF "host_mode || die \"no BOLT in CI mode\"" "$1"' _ "$TNB_REPO/tools/nginx-build.sh"

# ---------------------------------------------------------------------------
# nginx.org PGP signature: fail closed (gpgv stubbed)
# ---------------------------------------------------------------------------
# gpgv --status-fd 1 --keyring K... ASC FILE.  TNB_GPGV picks the answer;
# a FILE whose content is "stale" never verifies.
tnb_gpgv() {
  local a f="" nring=0 other=0123456789ABCDEF0123456789ABCDEF01234567
  for a in "$@"; do [[ $a == --keyring ]] && nring=$(( nring + 1 )); f=$a; done
  (( nring > 0 )) || return 2
  [[ $(cat "$f" 2>/dev/null) == stale ]] && return 1
  case $TNB_GPGV in
    fail) return 1 ;;
    nosig) printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG %s 1 10 00 1761955200 9 -\n' "$other" ;;
    unpinned) printf '[GNUPG:] VALIDSIG %s 2026-11-01 1761955200 0 4 0 1 10 00 %s\n' "$other" "$other" ;;
    subkey) printf '[GNUPG:] VALIDSIG %s 2026-11-01 1761955200 0 4 0 1 10 00 %s\n' "$TNB_PIN" "$other" ;;
    pinned) printf '[GNUPG:] VALIDSIG %s 2026-11-01 1761955200 0 4 0 1 10 00 %s\n' "$other" "$TNB_PIN" ;;
  esac
  return 0
}
# A syntactically valid ASCII-armoured block (not a real key: gpgv is stubbed).
tnb_armor() {
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' '' 'dGVzdCBrZXkgbWF0ZXJpYWw=' '=AAAA' '-----END PGP PUBLIC KEY BLOCK-----'
}
tnb_pgp_case() ( # gpgv-mode [nokeys] -> status
  local NB=$TMP/tnb-pgp first
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  first=${NGINX_PGP_KEYS%%$'\n'*}
  TNB_PIN=${first#*:}
  TNB_GPGV=$1
  ensure_packages() { echo ensure >> "$NB/calls"; return 1; }
  http_get() { return 1; }
  gpgv() { tnb_gpgv "$@"; }
  if [[ ${2:-} != nokeys ]]; then mkdir -p "$SRC_CACHE/keys"; tnb_armor > "$SRC_CACHE/keys/${first%%:*}.key"; fi
  printf 'tarball\n' > "$NB/f"; printf 'signature\n' > "$NB/f.asc"
  nginx_pgp_verify "$NB/f" "$NB/f.asc" >/dev/null 2>&1
  printf '%s' "$?"
)
check "PGP: a VALIDSIG whose primary key is pinned is accepted" test "$(tnb_pgp_case pinned)" = 0
check "PGP: gpgv rejecting the signature is refused" test "$(tnb_pgp_case fail)" = 1
check "PGP: gpgv exiting 0 without VALIDSIG is refused" test "$(tnb_pgp_case nosig)" = 1
check "PGP: a valid signature by a key that is not pinned is refused" test "$(tnb_pgp_case unpinned)" = 1
check "PGP: a pinned fingerprint as the signing subkey of an unpinned primary is refused" test "$(tnb_pgp_case subkey)" = 1
check "PGP: with no pinned key loadable (offline, nothing cached) nothing verifies" test "$(tnb_pgp_case pinned nokeys)" = 1
tnb_fetch_case() ( # gpgv-mode [stale] -> "rc=N out=PATH|none cached=CONTENT|none parts=N sums=0|1"
  local NB=$TMP/tnb-fetch first out rc=0 f
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  first=${NGINX_PGP_KEYS%%$'\n'*}
  TNB_PIN=${first#*:}
  TNB_GPGV=$1
  gpgv() { tnb_gpgv "$@"; }
  http_get() {
    case $1 in */keys/*) return 1 ;; esac
    [[ -n ${2:-} ]] && printf 'fresh\n' > "$2"
    return 0
  }
  mkdir -p "$SRC_CACHE/keys" "$SRC_CACHE/src"
  tnb_armor > "$SRC_CACHE/keys/${first%%:*}.key"
  f=$SRC_CACHE/src/nginx-1.31.12.tar.gz
  if [[ ${2:-} == stale ]]; then printf 'stale\n' > "$f"; printf 'stale\n' > "$f.asc"; fi
  out=$(fetch_nginx_signed 1.31.12 2>"$NB/err") || rc=$?
  printf 'rc=%s out=%s cached=%s parts=%s sums=%s' "$rc" "${out:-none}" "$(cat "$f" 2>/dev/null || echo none)" \
    "$(( $(find "$SRC_CACHE/src" -name '*.part' | wc -l) ))" \
    "$([[ -s $SRC_CACHE/sums/nginx-1.31.12.tar.gz ]] && echo 1 || echo 0)"
)
check "fetch_nginx_signed: a verified tarball is cached with its SHA-256 and its path printed" \
  test "$(tnb_fetch_case pinned)" = "rc=0 out=$TMP/tnb-fetch/cache/src/nginx-1.31.12.tar.gz cached=fresh parts=0 sums=1"
check "fetch_nginx_signed: no source with a valid signature stops the build and leaves no file (fail closed)" \
  test "$(tnb_fetch_case fail)" = "rc=1 out=none cached=none parts=0 sums=0"
check "fetch_nginx_signed: the refusal says it fails closed" \
  bash -c 'grep -q "fail closed" "$1"' _ "$TMP/tnb-fetch/err"
check "fetch_nginx_signed: a cached tarball that no longer verifies is fetched again" \
  test "$(tnb_fetch_case pinned stale)" = "rc=0 out=$TMP/tnb-fetch/cache/src/nginx-1.31.12.tar.gz cached=fresh parts=0 sums=1"
check "fetch_nginx_signed: a stale cached tarball is deleted, never used, when nothing verifies" \
  test "$(tnb_fetch_case fail stale)" = "rc=1 out=none cached=none parts=0 sums=0"

# ---------------------------------------------------------------------------
# In-place upgrade (USR2/WINCH/QUIT) and the fallback when it fails
# ---------------------------------------------------------------------------
tnb_master_case() ( # -> comma list of master_pid results for the pid file cases
  local NB=$TMP/tnb-master res=""
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  kill() { [[ ${1:-} == -0 && ${2:-} == 4242 ]]; }
  readlink() { [[ ${1:-} == /proc/4242/exe ]] || return 1; printf '%s\n' "$TNB_EXE"; }
  tnb_m() { TNB_EXE=$2; if [[ -n $1 ]]; then printf '%s\n' "$1" > "$PIDFILE"; else rm -f "$PIDFILE"; fi; res+="$(master_pid || echo none),"; }
  tnb_m 4242 "$SBIN/nginx"
  tnb_m 4242 "$SBIN/nginx (deleted)"
  tnb_m 4242 "$SBIN/nginx.prev"
  tnb_m 4242 /usr/sbin/nginx
  tnb_m 4343 "$SBIN/nginx"
  tnb_m 'abc' "$SBIN/nginx"
  tnb_m '' "$SBIN/nginx"
  printf '%s' "${res%,}"
)
check "master_pid: only a live master of OUR binary counts (not a distro nginx, a dead pid or garbage)" \
  test "$(tnb_master_case)" = "4242,4242,4242,none,none,none,none"
tnb_upgrade_case() ( # ok|nonew|noserve|badconf -> "rc=N [SIGNAL:pid ...]"
  local NB=$TMP/tnb-upgrade rc=0 k
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  TNB_MODE=$1
  install -d "$SBIN"
  printf '#!/bin/sh\necho "nginx version: nginx/1.31.12" >&2\n' > "$SBIN/nginx"; chmod 755 "$SBIN/nginx"
  printf '4242\n' > "$PIDFILE"; : > "$NB/alive.4242"; : > "$NB/kill.log"
  kill() {
    if [[ ${1:-} == -0 ]]; then [[ -e $NB/alive.${2:-x} && ! -e $NB/dead.${2:-x} ]]; return; fi
    printf '%s:%s\n' "${1#-}" "${2:-}" >> "$NB/kill.log"
    case ${1:-} in
      -USR2)
        if [[ $TNB_MODE != nonew ]]; then
          mv -f "$PIDFILE" "$PIDFILE.oldbin"; printf '5000\n' > "$PIDFILE"; : > "$NB/alive.5000"
        fi ;;
      -QUIT|-TERM) : > "$NB/dead.${2:-x}" ;;
    esac
    return 0
  }
  sleep() { :; }
  pgrep() { [[ ${2:-} == 5000 ]]; }
  serving_probe() { [[ $TNB_MODE != noserve ]]; }
  conf_test() { [[ $TNB_MODE != badconf ]]; }
  fit_config() { return 1; }
  systemctl() {
    printf '%s\n' "$*" >> "$NB/systemctl.log"
    if [[ $* == "show -p MainPID --value nginx.service" ]]; then printf '5000\n'; fi
    return 0
  }
  upgrade_master 4242 >/dev/null 2>&1 || rc=$?
  k=$(tr '\n' ' ' < "$NB/kill.log")
  printf 'rc=%s [%s]' "$rc" "${k% }"
)
check "upgrade: USR2, the new master writes its pid file, WINCH, it serves, QUIT the old master" \
  test "$(tnb_upgrade_case ok)" = "rc=0 [USR2:4242 WINCH:4242 QUIT:4242]"
check "upgrade: no new master within 10 s leaves the old one serving (no WINCH, no QUIT)" \
  test "$(tnb_upgrade_case nonew)" = "rc=1 [USR2:4242]"
check "upgrade: a new master that does not serve is rolled back (HUP old, QUIT new, old kept)" \
  test "$(tnb_upgrade_case noserve)" = "rc=1 [USR2:4242 WINCH:4242 HUP:4242 QUIT:5000]"
check "upgrade: a new binary that rejects the configuration (and cannot fit it) signals nothing" \
  test "$(tnb_upgrade_case badconf)" = "rc=1 []"
tnb_swap_case() ( # mode -> "rc=N bin=OLD|NEW restart=N start=N"
  local NB=$TMP/tnb-swap rc=0
  tnb_env "$NB"
  . "$TNB_REPO/tools/nginx-build.sh"
  tnb_quiet
  TNB_MODE=$1
  install -d "$SBIN" "$STATE"
  printf 'OLD\n' > "$SBIN/nginx"; printf 'NEW\n' > "$NB/new"
  : > "$UNIT_DIR/nginx.service"; : > "$NGINX_CONF"
  systemctl() { printf '%s\n' "$*" >> "$NB/systemctl.log"; [[ $TNB_MODE != startfail ]]; }
  serving_probe() { return 0; }
  ports_taken() { [[ $TNB_MODE == taken ]] && printf 'angie.service'; }
  master_pid() { [[ -f $NB/master ]] && printf 4242; }
  upgrade_master() { [[ $TNB_MODE == gone ]] && rm -f "$NB/master"; [[ $TNB_MODE == upgraded ]]; }
  case $1 in kept|gone|upgraded) : > "$NB/master" ;; migrate) CONTEXT=migrate ;; esac
  ( swap_in "$NB/new" "" "" ) >/dev/null 2>&1 || rc=$?
  printf 'rc=%s bin=%s restart=%s start=%s' "$rc" "$(cat "$SBIN/nginx")" \
    "$(grep -c '^restart nginx.service' "$NB/systemctl.log")" "$(grep -c '^start nginx.service' "$NB/systemctl.log")"
)
check "swap_in: a successful in-place upgrade keeps the new binary and restarts nothing" \
  test "$(tnb_swap_case upgraded)" = "rc=0 bin=NEW restart=0 start=0"
check "swap_in: a failed upgrade puts the previous binary back; the old master keeps serving (no restart)" \
  test "$(tnb_swap_case kept)" = "rc=1 bin=OLD restart=0 start=0"
check "swap_in: a failed upgrade that lost the master restarts nginx on the restored binary" \
  test "$(tnb_swap_case gone)" = "rc=1 bin=OLD restart=1 start=0"
check "swap_in: with no master the build is started; a failed start restores the previous binary" \
  test "$(tnb_swap_case fresh),$(tnb_swap_case startfail)" = "rc=0 bin=NEW restart=0 start=1,rc=1 bin=OLD restart=0 start=1"
check "swap_in: the migration context and ports held by another server install without starting" \
  test "$(tnb_swap_case migrate),$(tnb_swap_case taken)" = "rc=0 bin=NEW restart=0 start=0,rc=0 bin=NEW restart=0 start=0"

# ---------------------------------------------------------------------------
# Shared build units: removed with the last build only (R81)
# ---------------------------------------------------------------------------
tnb_last_case() ( # component-being-purged layout... -> "kept|removed|partial disable=N"
  local T=$TMP/tnb-last except=$1 l u n=0
  shift
  set +eE; trap - ERR
  rm -rf "$T"; mkdir -p "$T/units"
  NGINX_ROOT=$T/nginx SETUP_BUILD_PHP_ROOT=$T/php SETUP_BUILD_VALKEY_ROOT=$T/valkey
  SETUP_BUILD_CPU_UNIT=$T/units/setup-build-cpu.service
  SETUP_BUILD_REFRESH_UNIT=$T/units/setup-build-refresh.service
  SETUP_BUILD_REFRESH_TIMER=$T/units/setup-build-refresh.timer
  SETUP_BUILD_LOCK_FILE=$T/setup-build.lock
  systemctl() { printf '%s\n' "$*" >> "$T/systemctl.log"; return 0; }
  : > "$T/systemctl.log"
  for u in "$SETUP_BUILD_CPU_UNIT" "$SETUP_BUILD_REFRESH_UNIT" "$SETUP_BUILD_REFRESH_TIMER" "$SETUP_BUILD_LOCK_FILE"; do : > "$u"; done
  for l in "$@"; do
    case $l in
      nginx) mkdir -p "$T/nginx/build"; : > "$T/nginx/build/build.info" ;;
      nginx-dir) mkdir -p "$T/nginx/build" "$T/nginx/sbin" ;;
      php) mkdir -p "$T/php/8.5"; : > "$T/php/8.5/build.info" ;;
      php-staging) mkdir -p "$T/php/staging"; : > "$T/php/staging/build.info" ;;
      valkey) mkdir -p "$T/valkey"; : > "$T/valkey/build.info" ;;
    esac
  done
  setup_build_remove_shared_units_if_last "$except"
  for u in "$SETUP_BUILD_CPU_UNIT" "$SETUP_BUILD_REFRESH_UNIT" "$SETUP_BUILD_REFRESH_TIMER" "$SETUP_BUILD_LOCK_FILE"; do
    [[ -e $u ]] && n=$(( n + 1 ))
  done
  case $n in 4) l=kept ;; 0) l=removed ;; *) l=partial ;; esac
  printf '%s disable=%s' "$l" "$(grep -c '^disable --now setup-build-refresh.timer' "$T/systemctl.log")"
)
check "shared units: purging nginx keeps them while a PHP build is left" \
  test "$(tnb_last_case nginx nginx php)" = "kept disable=0"
check "shared units: a missing PHP root does not hide a Valkey build (one find per root)" \
  test "$(tnb_last_case nginx nginx valkey)" = "kept disable=0"
check "shared units: purging PHP keeps them while nginx's build.info is left" \
  test "$(tnb_last_case php nginx php)" = "kept disable=0"
check "shared units: purging the last build removes the CPU unit, the refresh unit/timer and the lock" \
  test "$(tnb_last_case nginx nginx)" = "removed disable=1"
check "shared units: a staged PHP build.info is not a build" \
  test "$(tnb_last_case nginx php-staging)" = "removed disable=1"
check "shared units: a leftover nginx build directory without build.info is not a build" \
  test "$(tnb_last_case valkey nginx-dir valkey)" = "removed disable=1"
check "shared units: without a component name they stay while any build is left" \
  test "$(tnb_last_case "" nginx),$(tnb_last_case "")" = "kept disable=0,removed disable=1"
check "shared units: nginx, PHP and Valkey purges all apply the one last-consumer rule with their own name" \
  bash -c 'sed -n "/^nginx_build_purge()/,/^}/p" "$1/lib/nginx-build.sh" | grep -q "setup_build_remove_shared_units_if_last nginx" && grep -q "setup_build_remove_shared_units_if_last php" "$1/lib/php-build.sh" && grep -q "setup_build_remove_shared_units_if_last valkey" "$1/lib/valkey-build.sh"' _ "$TNB_REPO"

unset -f tnb_has tnb_lacks tnb_line tnb_noline tnb_env tnb_quiet tnb_break_count tnb_brand_case tnb_fallback \
  tnb_build_case tnb_build_err tnb_args_have tnb_args_lack tnb_res_ok tnb_tmpfiles_ok tnb_fp tnb_fp_text \
  tnb_pre_case tnb_fake_nginx tnb_fit_case tnb_ci_case tnb_gpgv tnb_armor tnb_pgp_case tnb_fetch_case \
  tnb_master_case tnb_upgrade_case tnb_swap_case tnb_last_case
unset TNB_REPO TNB_SRC TNB_CPU TNB_FB TNB_FB1 TNB_FB2 TNB_FB3 TNB_ARGS TNB_ARGS_CI TNB_UNIT TNB_TMPF TNB_FPA TNB_FPT
