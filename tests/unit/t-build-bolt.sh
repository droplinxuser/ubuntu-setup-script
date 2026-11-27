#!/usr/bin/env bash
# Unit tests for the BOLT profile of the compiled builds (tools/build-common.sh,
# tools/nginx-build.sh, tools/php-build.sh, lib/php-build.sh,
# lib/nginx-build.sh):
#   - bolt_record: branch records only; "branch sampling unsupported"
#     (perf's words AND a failing probe) is told apart from a transient
#     failure, and no sampling at all is noperf;
#   - bolt_retry_due and the --optimize gates: nolbr / noperf are not retried
#     until the next build;
#   - conf_opt / info_put;
#   - 1.22.5 removal of BOLT_NOLBR (the plain-cycles perf2bolt -nl profile,
#     1-3 % slower than no BOLT): a conf or env that still sets it only
#     warns, the gates ignore it, and a build BOLTed that way is stale.
# No root, no network, no perf: perf is a fake script driven by FAKE_PERF.
# Usage: bash tests/unit/t-build-bolt.sh
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  bash "${BASH_SOURCE[0]}"
  return
fi
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-test-build-bolt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-build-bolt.sh,title=build BOLT test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }

# A fake perf.  FAKE_PERF: ok (everything records), nolbr (-j fails with
# perf's unsupported-branch words), noperf (every record fails, unsupported),
# busy (-a records fail with a transient error, the probe works), liar (the
# log says "not supported" but the probe records fine).  Every call's
# arguments go to $FAKE_PERF_LOG.
cat > "$TMP/perf" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_PERF_LOG"
j=0; a=0
for x in "$@"; do [[ $x == -j ]] && j=1; [[ $x == -a ]] && a=1; done
case $FAKE_PERF in
  ok) exit 0 ;;
  nolbr) if (( j )); then echo "Error: cycles:u: PMU Hardware or event type doesn't support branch stack sampling." >&2; exit 1; fi; exit 0 ;;
  noperf) echo "Error: The cycles:u event is not supported." >&2; exit 1 ;;
  busy) if (( a )); then echo "Error: failed to mmap with 12 (Cannot allocate memory)" >&2; exit 1; fi; exit 0 ;;
  liar) if (( a )); then echo "event not supported right now" >&2; exit 1; fi; exit 0 ;;
esac
exit 1
EOS
chmod 755 "$TMP/perf"

# bolt_record PERF-MODE -> BR_OUT=rc (and the calls in $TMP/calls-<n>)
n=0
BR_OUT=""
br() {
  n=$((n + 1))
  BR_OUT=$(br_run "$@")
}
br_run() {
  FAKE_PERF=$1 FAKE_PERF_LOG=$TMP/calls-$n bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR
    say() { :; }
    rc=0; bolt_record "$2" "$3/data" "$3/log-$4" 1 || rc=$?
    printf "%s" "$rc"' _ "$ROOT" "$TMP/perf" "$TMP" "$n"
}
calls() { cat "$TMP/calls-$n" 2>/dev/null || true; }

br ok; out=$BR_OUT
check "bolt_record: branch records work (0)" test "$out" = 0
check "bolt_record: branch records are tried with -j any,u" bash -c '[[ $1 == *"-j any,u"* ]]' _ "$(calls)"
check "bolt_record: a working host records exactly once (no probe)" test "$(calls | wc -l | tr -d ' ')" = 1
br nolbr; out=$BR_OUT
check "bolt_record: no branch sampling returns 4 (record bolt=nolbr)" test "$out" = 4
check "bolt_record: the unsupported verdict was confirmed by a probe (-- true)" bash -c 'grep -q -- "-- true" <<<"$1"' _ "$(calls)"
check "bolt_record: no plain-cycles profile follows (the removed BOLT_NOLBR mode)" \
  bash -c '! grep -E -- "-a -- sleep" <<<"$1" | grep -qv -- "-j any,u"' _ "$(calls)"
br noperf; out=$BR_OUT
check "bolt_record: no sampling at all returns 5 (record bolt=noperf)" test "$out" = 5
br busy; out=$BR_OUT
check "bolt_record: a transient failure returns 1 (die, retried by the refresh)" test "$out" = 1
br liar; out=$BR_OUT
check "bolt_record: perf's words alone are not enough (the probe records): transient" test "$out" = 1
check "bolt_record: a fifth argument (the removed BOLT_NOLBR=1) changes nothing" \
  test "$(FAKE_PERF=nolbr FAKE_PERF_LOG=$TMP/calls-x bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR; say() { :; }
    rc=0; bolt_record "$2" "$3/d" "$3/l" 1 1 nolbr || rc=$?; echo "$rc"' _ "$ROOT" "$TMP/perf" "$TMP")" = 4

rd() { bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR; bolt_retry_due "$2" "$3"' _ "$ROOT" "$1" "${2:-}"; }
check "bolt_retry_due: bolt=0 is due" rd 0
check "bolt_retry_due: no bolt= at all is due" rd ""
check "bolt_retry_due: bolt=1 is not" not rd 1
check "bolt_retry_due: bolt=nolbr is not" not rd nolbr
check "bolt_retry_due: bolt=nolbr is not, even with the removed BOLT_NOLBR=1 as a second argument" not rd nolbr 1
check "bolt_retry_due: bolt=noperf never is" not rd noperf

# conf_opt / info_put
printf 'TLS_LIB=aws-lc\nPHP_BUILD_MALLOC="mimalloc"  # a comment\r\nKEY=1\nKEY=0\n' > "$TMP/conf"
co() { bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR; conf_opt "$2" "$3" "$4"' _ "$ROOT" "$@"; }
check "conf_opt: quotes, comment and CR stripped" test "$(co PHP_BUILD_MALLOC glibc "$TMP/conf")" = mimalloc
check "conf_opt: the last assignment wins" test "$(co KEY 9 "$TMP/conf")" = 0
check "conf_opt: a missing key gives the default" test "$(co NOPE dflt "$TMP/conf")" = dflt
check "conf_opt: a missing file gives the default" test "$(co PHP_BUILD_MALLOC glibc "$TMP/none")" = glibc
printf 'a=1\nbolt=0\nz=2\n' > "$TMP/info"; chmod 640 "$TMP/info"
bash -c '. "$1/tools/build-common.sh"; set +eE; trap - ERR; info_put "$2" bolt nolbr; info_put "$2" extra lbr' _ "$ROOT" "$TMP/info"
check "info_put: replaces in place and appends a new key" test "$(cat "$TMP/info")" = $'a=1\nbolt=nolbr\nz=2\nextra=lbr'
check "info_put: keeps the file mode" bash -c '[[ $(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1") == 640 ]]' _ "$TMP/info"

# nginx tool, sourced with a conf
tnb() { # conf-text code
  local d=$TMP/ngx-$RANDOM
  mkdir -p "$d/root/build" "$d/cache"
  printf '%s\n' "$1" > "$d/nginx-build.conf"
  NGINX_BUILD_SOURCE_ONLY=1 NGINX_BUILD_ROOT="$d/root" NGINX_BUILD_CACHE="$d/cache" NGINX_BUILD_CONF="$d/nginx-build.conf" \
    NGINX_BUILD_UNIT_DIR="$d/units" SETUP_BUILD_MIRROR=off NGINX_BUILD_PIDFILE="$d/nginx.pid" \
    NGINX_BUILD_NGINX_CONF="${NGINX_BUILD_NGINX_CONF:-$d/etc/nginx.conf}" NGINX_BUILD_TMPFILES="$d/tmpfiles.conf" \
    bash -c 'source "$1/tools/nginx-build.sh"; set +eE; trap - ERR; eval "$2"' _ "$ROOT" "$2" 2>&1
}

# Static wiring: the tools record nolbr / noperf, run perf2bolt in its one
# (branch-record) mode, keep the rollback, and the refresh / --optimize
# gates skip what cannot work.
for t in nginx php; do
  f=$ROOT/tools/$t-build.sh
  b=$(sed -n '/^cmd_bolt() {/,/^}/p' "$f")
  check "$t cmd_bolt: profiles through bolt_record and records nolbr / noperf" \
    bash -c 'grep -q "bolt_record " <<<"$1" && grep -q "4) .*nolbr" <<<"$1" && grep -q "5) .*noperf" <<<"$1"' _ "$b"
  check "$t cmd_bolt: bolt_record gets no BOLT_NOLBR option" \
    bash -c 'grep -qF "bolt_record \"\$perf\" \"\$work/perf.data\" \"\$work/perf.log\" \"\$secs\" || rc=\$?" <<<"$1"' _ "$b"
  check "$t cmd_bolt: perf2bolt has no -nl mode (no P2B_MODE)" bash -c 'grep -qF "\"\$p2b\" -p \"\$work/perf.data\"" <<<"$1" && ! grep -q "P2B_MODE\|-nl" <<<"$1"' _ "$b"
  check "$t cmd_bolt: a successful pass drops a leftover bolt_mode= (no BOLT_MODE)" \
    bash -c 'grep -qF "/^bolt_mode=/d" <<<"$1" && ! grep -q "BOLT_MODE" <<<"$1"' _ "$b"
  check "$t cmd_bolt: the GNU_STACK check stays" bash -c 'grep -q bolt_stack_check <<<"$1"' _ "$b"
  check "$t refresh: retries only when bolt_retry_due (one argument)" \
    bash -c 'sed -n "/^cmd_refresh() {/,/^}/p" "$1" | grep -qE "bolt_retry_due \"\\\$\(info_get .*bolt\)\" &&"' _ "$f"
done
check "no BOLT_NOLBR variable, P2B_MODE or BOLT_MODE is left in the tools or the lib gates" \
  bash -c '! grep -nE "\\\$\{?BOLT_NOLBR|P2B_MODE|BOLT_MODE" "$1"/tools/build-common.sh "$1"/tools/nginx-build.sh "$1"/tools/php-build.sh "$1"/lib/nginx-build.sh "$1"/lib/php-build.sh' _ "$ROOT"
check "conf files no longer ship BOLT_NOLBR" \
  bash -c '! grep -q "^BOLT_NOLBR=" "$1/php-build.conf" && ! grep -q "^BOLT_NOLBR=" "$1/nginx-build.conf"' _ "$ROOT"

# lib/php-build.sh: the --optimize gate
pbd() { # bolt-value conf-text
  local d=$TMP/pbd-$RANDOM
  mkdir -p "$d/8.5"
  printf 'bolt=%s\n' "$1" > "$d/8.5/build.info"
  printf '%s\n' "$2" > "$d/php-build.conf"
  bash -c 'eval "$(sed -n "/^php_build_bolt_state()/p; /^php_build_bolt_due()/,/^}/p" "$1/lib/php-build.sh")"
    PHP_BUILD_ROOT=$2 PHP_BUILD_CONF_FILE=$2/php-build.conf; php_build_bolt_due 8.5' _ "$ROOT" "$d"
}
check "lib php_build_bolt_due: bolt=0 is due" pbd 0 ""
check "lib php_build_bolt_due: bolt=nolbr is not" not pbd nolbr ""
check "lib php_build_bolt_due: bolt=nolbr is not, even with a leftover BOLT_NOLBR=1" not pbd nolbr 'BOLT_NOLBR="1" # opt-in'
check "lib php_build_bolt_due: bolt=nolbr is not, even with env PHP_BUILD_BOLT_NOLBR=1" \
  not env PHP_BUILD_BOLT_NOLBR=1 bash -c "$(declare -f pbd); TMP=\$1 ROOT=\$2 pbd nolbr BOLT_NOLBR=0" _ "$TMP" "$ROOT"
check "lib php_build_bolt_due: bolt=noperf is not" not pbd noperf ""
nbg() { # bolt-state conf-text [env NOLBR] -> report lines, "tool bolt" when the tool ran
  local d=$TMP/nbg-$RANDOM
  mkdir -p "$d/build"
  printf 'bolt=%s\n' "$1" > "$d/build/build.info"
  printf '%s\n' "$2" > "$d/nginx-build.conf"
  env ${3+NGINX_BUILD_BOLT_NOLBR="$3"} bash -c 'eval "$(sed -n "/^nginx_build_bolted()/p; /^_nginx_build_bolt_state()/p; /^_nginx_build_bolt() {/,/^}/p" "$1/lib/nginx-build.sh")"
    NGINX_ROOT=$2 NGINX_BUILD_CONF_FILE=$2/nginx-build.conf
    systemctl() { return 0; }
    nginx_build_run_tool() { echo "tool $2"; NGINX_BUILD_LAST_OUT=""; return 0; }
    rep() { echo "report $*"; }
    _nginx_build_bolt rep' _ "$ROOT" "$d"
}
check "lib nginx BOLT gate: bolt=nolbr does not run the tool" \
  bash -c '[[ $1 == *"BOLT not possible"* && $1 == *"bolt=nolbr"* && $1 != *"tool bolt"* ]]' _ "$(nbg nolbr "")"
check "lib nginx BOLT gate: a leftover BOLT_NOLBR=1 in the conf does not run it either" \
  bash -c '[[ $1 != *"tool bolt"* && $1 != *BOLT_NOLBR* ]]' _ "$(nbg nolbr BOLT_NOLBR=1)"
check "lib nginx BOLT gate: nor does env NGINX_BUILD_BOLT_NOLBR=1" \
  bash -c '[[ $1 != *"tool bolt"* ]]' _ "$(nbg nolbr "" 1)"
check "lib nginx BOLT gate: bolt=noperf does not run the tool" \
  bash -c '[[ $1 == *"bolt=noperf"* && $1 != *"tool bolt"* ]]' _ "$(nbg noperf "")"
check "lib nginx BOLT gate: bolt=0 runs the tool" bash -c '[[ $1 == *"tool bolt"* ]]' _ "$(nbg 0 "")"

# ---------------------------------------------------------------------------
# 1.22.5 removal of BOLT_NOLBR: a leftover conf line or env value warns once
# and changes nothing; a build BOLTed from the plain-cycles profile
# (bolt_mode=nolbr) is stale, so the next --optimize / refresh rebuilds it.
# ---------------------------------------------------------------------------
out=$(tnb 'BOLT_NOLBR=1' 'echo "loaded"')
check "nginx: a leftover BOLT_NOLBR=1 warns once that it was removed and loads" \
  bash -c '[[ $1 == *loaded* && $(grep -c "BOLT_NOLBR=1 was removed in 1.22.5" <<<"$1") == 1 && $1 == *"using the default"* ]]' _ "$out"
out=$(NGINX_BUILD_BOLT_NOLBR=1 tnb '' 'echo "loaded"')
check "nginx: env NGINX_BUILD_BOLT_NOLBR=1 warns the same way" bash -c '[[ $1 == *loaded* && $1 == *"BOLT_NOLBR=1 was removed in 1.22.5"* ]]' _ "$out"
out=$(tnb 'BOLT_NOLBR=0' 'echo "loaded"')
check "nginx: BOLT_NOLBR=0 (the old default line) draws no warning" bash -c '[[ $1 == loaded ]]' _ "$out"
nck() { # conf-text build.info-extra -> cmd_check output
  tnb "$1" 'resolve_all() { :; }; cpu_fingerprint_matches() { return 0; }
    { printf "recipe=%s\ntls_opts=%s\n" "$BUILD_RECIPE" "$(tls_key aws-lc)"; printf "%b" "'"$2"'"; } > "$STATE/build.info"; ( cmd_check ); echo "rc=$?"'
}
check "nginx check: a build BOLTed without branch samples (bolt_mode=nolbr) is stale" \
  bash -c '[[ $1 == *"BOLT profile without branch samples (removed in 1.22.5)"* && $1 == *rc=10* ]]' _ "$(nck '' 'bolt=1\nbolt_mode=nolbr\n')"
check "nginx check: a branch-record BOLT (bolt_mode=lbr) is current" \
  bash -c '[[ $1 == *current* && $1 == *rc=0* ]]' _ "$(nck '' 'bolt=1\nbolt_mode=lbr\n')"
check "nginx check: a leftover BOLT_NOLBR=1 does not stop check (warning, rc 0)" \
  bash -c '[[ $1 == *"was removed in 1.22.5"* && $1 == *current* && $1 == *rc=0* ]]' _ "$(nck 'BOLT_NOLBR=1' 'bolt=nolbr\n')"

# ---------------------------------------------------------------------------
# F10: an invalid TLS_LIB never makes pre/status die; build and check refuse
# it; a CPU rebuild uses the recorded values.  A KTLS= line left in an
# operator's conf (the option was removed in 1.22.5) is ignored.
# ---------------------------------------------------------------------------
out=$(tnb $'TLS_LIB=libressl\nKTLS=1' 'printf "loaded %s|%s\n" "$TLS_LIB" "${COMPONENTS[*]}"; printf "invalid=%s\n" "$CONF_INVALID"')
check "nginx conf: an invalid TLS_LIB loads with the default (no die at source time)" \
  bash -c 'l=$(grep "^loaded" <<<"$1"); [[ $l == "loaded aws-lc|"* ]]' _ "$out"
check "nginx conf: the invalid value is recorded; a leftover KTLS= line is not" \
  bash -c '[[ $1 == *"TLS_LIB=libressl: expected aws-lc"* && $1 != *KTLS* ]]' _ "$out"
out=$(tnb 'TLS_LIB=libressl' 'printf "nginx=1.29.0\nllvm=20\nrecipe=1\nbolt=0\n" > "$STATE/build.info"; master_pid() { return 1; }; cpu_fingerprint_matches() { return 0; }; ( cmd_status ); echo "rc=$?"')
check "nginx status: an invalid TLS_LIB only warns (exit 0)" \
  bash -c '[[ $1 == *"TLS_LIB=libressl: expected aws-lc"* && $1 == *rc=0* ]]' _ "$out"
out=$(tnb 'TLS_LIB=libressl' 'mkdir -p "$SBIN"; printf "#!/bin/sh\nexit 0\n" > "$SBIN/nginx"; chmod +x "$SBIN/nginx"; : > "$STATE/build.info"
  cpu_fingerprint_matches() { return 0; }; apply_tmpfiles() { :; }; conf_test() { return 0; }
  ( cmd_pre ); echo "rc=$?"')
check "nginx pre (ExecStartPre): an invalid TLS_LIB warns and nginx starts (exit 0)" \
  bash -c '[[ $1 == *"TLS_LIB=libressl"* && $1 == *rc=0* ]]' _ "$out"
out=$(tnb 'TLS_LIB=libressl' 'printf "recipe=%s\n" "$BUILD_RECIPE" > "$STATE/build.info"; resolve_all() { :; }; cpu_fingerprint_matches() { return 0; }; ( cmd_check ); echo "rc=$?"')
check "nginx check: an invalid TLS_LIB is refused (exit 1, not 0 or 10)" \
  bash -c '[[ $1 == *"ERROR: nginx-build.conf: TLS_LIB=libressl"* && $1 == *rc=1* ]]' _ "$out"
out=$(NGINX_BUILD_CI=1 tnb 'TLS_LIB=libressl' 'ensure_packages() { :; }; build_deprioritize() { echo deprioritized; }; ( cmd_build normal ); echo "rc=$?"')
check "nginx build: an invalid TLS_LIB stops the build before any work" \
  bash -c '[[ $1 == *"ERROR: nginx-build.conf: TLS_LIB=libressl"* && $1 == *rc=1* && $1 != *deprioritized* ]]' _ "$out"
out=$(NGINX_BUILD_CI=1 tnb 'TLS_LIB=libressl' 'printf "tls_lib=aws-lc\n" > "$STATE/build.info"; ensure_packages() { :; }; build_deprioritize() { echo "deprioritized $TLS_LIB"; exit 0; }; ( cmd_build cpu ); echo "rc=$?"')
check "nginx build cpu: a CPU rebuild ignores the invalid conf and builds aws-lc" \
  bash -c '[[ $1 == *"deprioritized aws-lc"* && $1 != *ERROR* ]]' _ "$out"
check "php: an invalid PHP_BUILD_MALLOC does not stop the tool from loading (pre/status keep working)" \
  bash -c 'PHP_BUILD_MALLOC=tcmalloc PHP_BUILD_SOURCE_ONLY=1 PHP_BUILD_ROOT=$2 bash -c "source \"\$1\"; echo loaded" _ "$1/tools/php-build.sh" 2>&1 | grep -qx loaded' _ "$ROOT" "$TMP/php-root"
# lib: a `check` exit other than 0/10 is a FAILED line, not "build is current".
nbe() { # check-exit -> report lines
  local d=$TMP/nbe-$RANDOM
  mkdir -p "$d/build" "$d/sbin"
  : > "$d/build/build.info"; printf '#!/bin/sh\nexit 0\n' > "$d/sbin/nginx"; chmod +x "$d/sbin/nginx"
  printf '#!/bin/sh\ncase $1 in check) [ "%s" = 1 ] && { echo "ERROR: nginx-build.conf: TLS_LIB=libressl: expected aws-lc" >&2; exit 1; }; exit %s ;; status) echo "nginx: build 1.29.0" ;; esac\nexit 0\n' "$1" "$1" > "$d/tool"
  chmod +x "$d/tool"
  bash -c 'eval "$(sed -n "/^nginx_build_ensure() {/,/^}/p" "$1/lib/nginx-build.sh")"
    NGINX_ROOT=$2 NGINX_BIN=$2/sbin/nginx NGINX_BUILD_TOOL=$2/tool
    for f in nginx_build_install_tools _nginx_build_lock _nginx_build_report_disabled nginx_build_install_units \
      _nginx_build_enable_if_running _nginx_build_disabled_seen _nginx_build_unlock _nginx_build_bolt; do eval "$f() { :; }"; done
    _nginx_build_resolve_out() { NGINX_BUILD_OUT=$1; }
    _nginx_build_ensure_running() { :; }
    _nginx_build_stage() { echo "report STAGE"; }
    rep() { echo "report $*"; }
    nginx_build_ensure full optimize rep; echo "rc=$?"' _ "$ROOT" "$d"
}
out=$(nbe 1)
check "lib nginx_build_ensure: a failing check is reported as FAILED with the tool's reason" \
  bash -c '[[ $1 == *"FAILED: nginx: the build check failed (exit 1: nginx-build.conf: TLS_LIB=libressl"* && $1 != *STAGE* ]]' _ "$out"
check "lib nginx_build_ensure: a current build (check 0) reports no failure" \
  bash -c '[[ $1 != *FAILED* && $1 == *"build is current"* ]]' _ "$(nbe 0)"

# ---------------------------------------------------------------------------
# F34: the PHP library cache built under this host's 1.22.4 fingerprint is
# renamed to the 1.22.5 key once, not recompiled.
# ---------------------------------------------------------------------------
lcm() { # cpuinfo legacy-extra(V1 force) -> "new=.. old=.." after the migration
  local d=$TMP/lcm-$RANDOM
  mkdir -p "$d/cache"
  PHP_BUILD_SOURCE_ONLY=1 PHP_BUILD_CACHE="$d/cache" PHP_BUILD_ROOT="$d/root" SETUP_CPUINFO=$1 bash -c 'source "$1"; set +eE; trap - ERR
    say() { echo "say $*"; }
    BASE_FLAGS="-O3 -march=native";
    n=20; LIBS=(openssl icu); declare -A VERS=([openssl]=3.5.1 [icu]=77.1)
    old=$SRC_CACHE/deps-$(lib_cache_key "$(cpu_fingerprint "$2" "$CPU_ISA_FLAGS_V1")")
    mkdir -p "$old/lib/pkgconfig" "$old/bin"; echo obj > "$old/libssl.a"; touch "$old/.done"
    printf "prefix=%s\nlibdir=\${prefix}/lib\n" "$old" > "$old/lib/pkgconfig/libxml-2.0.pc"
    printf "a\0%s/lib/engines\0b" "$old" > "$old/bin/tool"; chmod 755 "$old/bin/tool"
    new=$SRC_CACHE/deps-$(lib_cache_key "$(cpu_fingerprint)")
    lib_cache_migrate "$new"
    printf "new=%s old=%s same=%s\n" "$([[ -f $new/.done && -f $new/libssl.a ]] && echo yes || echo no)" "$([[ -d $old ]] && echo yes || echo no)" "$([[ $old == "$new" ]] && echo yes || echo no)"
    if [[ $old != "$new" && -d $new ]]; then
      printf "pc=%s stale=%s bin=%s exec=%s\n" "$(sed -n "s/^prefix=//p" "$new/lib/pkgconfig/libxml-2.0.pc")" \
        "$(grep -rlF "${old##*/}" "$new" | wc -l)" "$(cmp -s "$new/bin/tool" <(printf "a\0%s/lib/engines\0b" "$new") && echo same || echo diff)" \
        "$([[ -x $new/bin/tool ]] && echo yes || echo no)"
      [[ $(sed -n "s/^prefix=//p" "$new/lib/pkgconfig/libxml-2.0.pc") == "$new" ]] && echo "pc-ok"
    fi' _ "$ROOT/tools/php-build.sh" "$2" 2>&1
}
sed -E '/^flags/ s/$/ avx512_fp16 rdrand rdseed/' "$ROOT/tests/fixtures/cpuinfo/x86-a" > "$TMP/lcm-cpu"
check "php lib cache: a 1.22.4 (V1) cache of this CPU is renamed to the new key" \
  bash -c '[[ $1 == *"new=yes old=no same=no"* && $1 == *"reused as"* ]]' _ "$(lcm "$TMP/lcm-cpu" "")"
check "php lib cache: the renamed cache's .pc prefix and binaries point at the new directory" \
  bash -c '[[ $1 == *"pc-ok"* && $1 == *"stale=0 bin=same exec=yes"* ]]' _ "$(lcm "$TMP/lcm-cpu" "")"
check "php lib cache: a 1.22.0-1.22.3 cache (V1 + rdrnd/rdseed) is renamed too" \
  bash -c '[[ $1 == *"new=yes old=no"* ]]' _ "$(lcm "$TMP/lcm-cpu" "rdrnd rdseed")"
check "php lib cache: another CPU's cache is never adopted" \
  bash -c 'PHP_BUILD_SOURCE_ONLY=1 PHP_BUILD_CACHE="$3" SETUP_CPUINFO=$2 bash -c "source \"\$1\"; set +eE; trap - ERR
    BASE_FLAGS=-O3;    n=20; LIBS=(openssl); declare -A VERS=([openssl]=3.5.1)
    old=\$(SETUP_CPUINFO=\$2 lib_cache_key \"\$(SETUP_CPUINFO=\$4 cpu_fingerprint \"\" \"\$CPU_ISA_FLAGS_V1\")\"); mkdir -p \"\$SRC_CACHE/deps-\$old\"; touch \"\$SRC_CACHE/deps-\$old/.done\"
    new=\$SRC_CACHE/deps-\$(lib_cache_key \"\$(cpu_fingerprint)\"); lib_cache_migrate \"\$new\"; [[ ! -e \$new && -d \$SRC_CACHE/deps-\$old ]]" _ "$1/tools/php-build.sh" "$2" "$3" "$1/tests/fixtures/cpuinfo/x86-d"' _ "$ROOT" "$TMP/lcm-cpu" "$TMP/lcm-other"
lcm_malloc() { # BUILD_RC -> "new=.. old=.. built=.." for a 1.22.4 cache keyed without mimalloc
  local d=$TMP/lcmm-$RANDOM
  mkdir -p "$d/cache"
  PHP_BUILD_SOURCE_ONLY=1 PHP_BUILD_CACHE="$d/cache" PHP_BUILD_ROOT="$d/root" SETUP_CPUINFO=$1 bash -c 'source "$1"; set +eE; trap - ERR
    say() { echo "say $*"; }
    rc=$2
    build_libs() { echo "build_libs ${*:5}"; [[ $rc == kill ]] && { echo "marked-while-building=$([[ -f $1/.done ]] && echo yes || echo no)"; kill -9 $$; }; [[ $rc == 0 ]] || return 1; mkdir -p "$1/lib"; echo o > "$1/lib/mimalloc.o"; }
    BASE_FLAGS="-O3 -march=native"; n=20; MALLOC_IMPL=mimalloc; work=$SRC_CACHE; j=1; log=/dev/null
    LIBS=(openssl icu); declare -A VERS=([openssl]=3.5.1 [icu]=77.1 [mimalloc]=3.1.5)
    old=$SRC_CACHE/deps-$(lib_cache_key "$(cpu_fingerprint "" "$CPU_ISA_FLAGS_V1")")
    mkdir -p "$old/lib"; echo obj > "$old/libssl.a"; touch "$old/.done"
    LIBS=(openssl icu mimalloc)
    new=$SRC_CACHE/deps-$(lib_cache_key "$(cpu_fingerprint)")
    lib_cache_migrate "$new"
    printf "new=%s old=%s built=%s\n" "$([[ -f $new/.done && -f $new/libssl.a ]] && echo yes || echo no)" "$([[ -d $old ]] && echo yes || echo no)" "$([[ -s $new/lib/mimalloc.o ]] && echo yes || echo no)"' _ "$ROOT/tools/php-build.sh" "$2" 2>&1
  local x
  for x in "$d"/cache/deps-*; do [[ -d $x ]] && echo "left=$([[ -f $x/.done ]] && echo marked || echo unmarked)"; done
}
check "php lib cache: a 1.22.4 cache (no allocator) is reused and only mimalloc is built into it" \
  bash -c '[[ $1 == *"new=yes old=no built=yes"* && $1 == *"build_libs mimalloc"* && $1 != *"build_libs openssl"* ]]' _ "$(lcm_malloc "$TMP/lcm-cpu" 0)"
check "php lib cache: a failed mimalloc build drops the reused cache (cmd_build builds everything)" \
  bash -c '[[ $1 == *"new=no old=no"* && $1 == *"building every library"* ]]' _ "$(lcm_malloc "$TMP/lcm-cpu" 1)"
check "php lib cache: a run killed during the reuse leaves the cache unmarked (rebuilt next time, never trusted)" \
  bash -c '[[ $1 == *"marked-while-building=no"* && $1 == *"left=unmarked"* && $1 != *"left=marked"* && $1 != *"new="* ]]' _ "$(lcm_malloc "$TMP/lcm-cpu" kill)"
check "php cmd_build: the migration runs only on a cache miss, before the libraries are built" \
  bash -c 'b=$(sed -n "/^cmd_build() {/,/^}/p" "$1"); grep -q "\[\[ -f \$deps/.done \]\] || lib_cache_migrate \"\$deps\"" <<<"$b" \
    && (( $(grep -n lib_cache_migrate <<<"$b" | cut -d: -f1) < $(grep -n "build_libs " <<<"$b" | cut -d: -f1) ))' _ "$ROOT/tools/php-build.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
