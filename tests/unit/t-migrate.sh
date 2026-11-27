#!/usr/bin/env bash
# Unit tests for lib/migrate.sh, the one-time 1.21 -> 1.22 migration
# (Angie/Sury/valkey-server -> source builds): resume after an interruption
# at each phase, the 1.21 trigger retirement, the pre-flight blockers
# (Angie-only directives, purge collateral, disk), the /etc/nginx render
# path map with the operator files and the fit marker, the ACME ->
# self-signed rewrite, the nginx cutover rollback order, the PHP unit
# handover and its rollback, the Valkey stop-before-snapshot rule, the exact
# purge lists under policy-rc.d, the deferred Sury purge with apt-mark hold,
# the post-purge enable/assert pass and the final report.
#
# No root, no services and no system changes are required.  Every path the
# module writes is redirected below a private /tmp tree through the module's
# own overrides (SETUP_MIGRATE_*, *_BUILD_ROOT and the post-source
# MIGRATE_NGINX_ETC / MIGRATE_APT_PIN / MIGRATE_OLD_HOOKS assignments), and
# the run aborts before the first test when one of them is not.  systemctl,
# apt-get, apt-mark, dpkg, dpkg-query, systemd-run, curl, df, crontab,
# update-alternatives and the nginx/php/valkey binaries are stubs that
# record their calls in one ordered log; the helpers that would reach fixed
# host paths (deb-systemd-helper state, /usr/bin links, apt sources, the
# angie user) are replaced by recorders.
# Usage: bash tests/unit/t-migrate.sh
# The suites assign globals the sourced helpers read and define stubs that
# the functions under test call indirectly; ShellCheck cannot follow that.
# shellcheck disable=SC2034,SC2317,SC2329,SC2016,SC2030,SC2031

# tests/test-tuning.sh sources every tests/unit file in a subshell that has
# already sourced setup.sh, whose SCRIPT_* variables are readonly: sourcing
# it again with the module overrides below would abort on the first one.
# This file needs its own setup.sh load (the overrides must be in place
# before it), so run it as a fresh process and hand its result back.
if [[ ${BASH_SOURCE[0]} != "$0" ]] && declare -p SCRIPT_VERSION >/dev/null 2>&1; then
  bash "${BASH_SOURCE[0]}"
  return $?
fi

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PASS=0
FAIL=0
SKIP=0
# Canonical path: /proc/PID/exe and readlink -f must agree with it.
TMP=$(cd -- "$(mktemp -d /tmp/setup-test-migrate.XXXXXX)" && pwd -P)
# The tests do not remove TMP: a failed run stays inspectable and /tmp
# expires it.
TROOT="$TMP/root"     # every fixture path of the module lives below this
STUBD="$TMP/stub"     # stub behaviour switches (reset per scenario)
TBIN="$TMP/bin"       # stub commands, first on PATH
TPL="$TMP/tpl"        # stub binary templates (nginx, php CLI, valkey-cli)
TCALLS="$TMP/calls.log"
mkdir -p "$TROOT" "$STUBD" "$TBIN" "$TPL"
: > "$TCALLS"

# ---------------------------------------------------------------------------
# Stub commands.  Each appends "name args" to $STUB_CALLS (one ordered log).
# ---------------------------------------------------------------------------
cat > "$TBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STUB_CALLS"
now=0
args=()
for a in "$@"; do
  case $a in
    --now) now=1 ;;
    --quiet|-q|--no-block|--value|--plain|--no-legend|--all|--no-pager) ;;
    *) args+=("$a") ;;
  esac
done
cmd=${args[0]:-}
unit=""
if [ "${#args[@]}" -gt 1 ]; then unit=${args[${#args[@]}-1]}; unit=${unit%.service}; fi
has_active() { grep -qxF -- "$1" "$STUB_DIR/active" 2>/dev/null; }
add_active() { has_active "$1" || printf '%s\n' "$1" >> "$STUB_DIR/active"; }
del_active() {
  [ -f "$STUB_DIR/active" ] || return 0
  grep -vxF -- "$1" "$STUB_DIR/active" > "$STUB_DIR/active.new" || true
  mv -f "$STUB_DIR/active.new" "$STUB_DIR/active"
}
hook() { if [ -x "$STUB_DIR/hook.$1.$2" ]; then "$STUB_DIR/hook.$1.$2"; fi; return 0; }
do_start() {
  if grep -qxF -- "$1" "$STUB_DIR/fail-start" 2>/dev/null; then exit 1; fi
  add_active "$1"
  hook start "$1"
}
case $cmd in
  is-active) has_active "$unit" && exit 0; exit 3 ;;
  is-enabled)
    v=$(awk -v u="$unit" '$1 == u { v = $2 } END { print v }' "$STUB_DIR/enabled" 2>/dev/null)
    printf '%s\n' "${v:-disabled}"
    [ "${v:-disabled}" = enabled ] ;;
  show)
    prop=${args[2]:-}
    if [ -f "$STUB_DIR/show.$prop.$unit" ]; then cat "$STUB_DIR/show.$prop.$unit"
    else
      case $prop in
        MainPID) echo 0 ;;
        FragmentPath) echo "/lib/systemd/system/${unit}.service" ;;
        *) echo ;;
      esac
    fi ;;
  start|restart) do_start "$unit" ;;
  stop|kill) del_active "$unit"; hook "$cmd" "$unit" ;;
  enable|reenable) if [ "$now" = 1 ]; then do_start "$unit"; fi ;;
  list-units) cat "$STUB_DIR/list-units" 2>/dev/null ;;
  *) : ;;
esac
exit $?
EOF

# dpkg database: $STUB_DIR/dpkg holds "STATUS<TAB>NAME" lines (ii, rc, hi).
cat > "$TBIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'dpkg-query %s\n' "$*" >> "$STUB_CALLS"
db=$STUB_DIR/dpkg
if [ "${1:-}" = -S ] || [ "${1:-}" = --search ]; then
  if grep -qxF -- "${2:-}" "$STUB_DIR/dpkg-owned" 2>/dev/null; then printf 'stub-pkg: %s\n' "$2"; exit 0; fi
  printf 'dpkg-query: no path found matching pattern %s\n' "${2:-}" >&2
  exit 1
fi
fmt=""
pkgs=()
while [ $# -gt 0 ]; do
  case $1 in
    -W|--show) ;;
    -f|--showformat) shift; fmt=${1:-} ;;
    -f*) fmt=${1#-f} ;;
    --showformat=*) fmt=${1#*=} ;;
    *) pkgs+=("$1") ;;
  esac
  shift
done
fmt=${fmt#=}
case $fmt in
  *binary:Package*) awk -F'\t' 'NF >= 2 { printf "%s \t%s\n", $1, $2 }' "$db" 2>/dev/null; exit 0 ;;
esac
[ "${#pkgs[@]}" -gt 0 ] || exit 1
s=$(awk -F'\t' -v p="${pkgs[0]}" '$2 == p { s = $1 } END { print s }' "$db" 2>/dev/null)
if [ -z "$s" ]; then printf 'dpkg-query: no packages found matching %s\n' "${pkgs[0]}" >&2; exit 1; fi
case $fmt in
  *Version*) [ "$s" = rc ] || printf '1.0-stub' ;;
  *) printf '%s ' "$s" ;;
esac
exit 0
EOF

# apt-get: -s prints Purg/Remv for the named packages plus the lines of
# $STUB_DIR/apt-sim-extra-if.<pkg> (collateral); a real purge/remove edits
# the dpkg database.  A second, normalised line records the package set
# (sorted) and whether our policy-rc.d was in place.
cat > "$TBIN/apt-get" <<'EOF'
#!/usr/bin/env bash
pol=no
if [ -n "${STUB_POLICY_RC:-}" ] && [ -f "$STUB_POLICY_RC" ] \
   && grep -q 'setup.sh-1.22 migrate policy-rc.d' "$STUB_POLICY_RC"; then pol=yes; fi
printf 'apt-get %s\n' "$*" >> "$STUB_CALLS"
sim=0; allow=0; action=""; skip=0
pkgs=()
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case $a in
    -o|-c|-t) skip=1 ;;
    -s|--simulate|--dry-run|--just-print) sim=1 ;;
    --allow-change-held-packages) allow=1 ;;
    -*) ;;
    *) if [ -z "$action" ]; then action=$a; else pkgs+=("$a"); fi ;;
  esac
done
sorted=$(printf '%s\n' "${pkgs[@]}" | sed '/^$/d' | LC_ALL=C sort | paste -sd' ' -)
mode=real
[ "$sim" = 1 ] && mode=sim
printf 'APT %s %s: %s policy=%s\n' "$mode" "$action" "$sorted" "$pol" >> "$STUB_CALLS"
case $action in
  download|update|install) exit 1 ;;
esac
if [ "$sim" = 1 ]; then
  if [ -f "$STUB_DIR/apt-sim-fail" ]; then echo 'E: stub simulation failure' >&2; exit 100; fi
  if [ "$allow" = 0 ] && [ -s "$STUB_DIR/held" ]; then
    for p in "${pkgs[@]}"; do
      if grep -qxF -- "$p" "$STUB_DIR/held"; then echo 'E: Held packages were changed and -y was used.' >&2; exit 100; fi
    done
  fi
  verb=Purg
  [ "$action" = remove ] && verb=Remv
  for p in "${pkgs[@]}"; do printf '%s %s [1.0-stub]\n' "$verb" "$p"; done
  for p in "${pkgs[@]}"; do
    if [ -f "$STUB_DIR/apt-sim-extra-if.$p" ]; then cat "$STUB_DIR/apt-sim-extra-if.$p"; fi
  done
  exit 0
fi
[ -f "$STUB_DIR/apt-fail.$action" ] && exit 100
for p in "${pkgs[@]}"; do
  if [ "$action" = remove ]; then
    awk -F'\t' -v OFS='\t' -v p="$p" '$2 == p { $1 = "rc" } { print }' "$STUB_DIR/dpkg" > "$STUB_DIR/dpkg.new"
  else
    awk -F'\t' -v p="$p" '$2 != p' "$STUB_DIR/dpkg" > "$STUB_DIR/dpkg.new"
  fi
  mv -f "$STUB_DIR/dpkg.new" "$STUB_DIR/dpkg"
done
exit 0
EOF

cat > "$TBIN/dpkg-divert" <<'EOF2'
#!/usr/bin/env bash
printf 'dpkg-divert %s\n' "$*" >> "$STUB_CALLS"
l=$STUB_DIR/diversions
touch "$l"
act="" rename=0 to="" path=""
while [ $# -gt 0 ]; do
  case $1 in
    --list) act=list ;;
    --add) act=add ;;
    --remove) act=remove ;;
    --rename) rename=1 ;;
    --local|--quiet) ;;
    --divert) shift; to=$1 ;;
    *) path=$1 ;;
  esac
  shift
done
case $act in
  list) grep -F -- "$path " "$l" | sed 's/^/local diversion of /' ;;
  add) [ -f "$STUB_DIR/divert-fail" ] && exit 2
       printf '%s %s\n' "$path" "${to:-$path.distrib}" >> "$l"
       [ "$rename" = 1 ] && [ -e "$path" ] && mv -f -- "$path" "${to:-$path.distrib}" ;;
  remove) to=$(grep -F -- "$path " "$l" | awk '{ print $2 }')
          grep -vF -- "$path " "$l" > "$l.new" || true; mv -f "$l.new" "$l"
          [ "$rename" = 1 ] && [ -n "$to" ] && [ -e "$to" ] && mv -f -- "$to" "$path" ;;
esac
exit 0
EOF2
cat > "$TBIN/apt-mark" <<'EOF'
#!/usr/bin/env bash
printf 'apt-mark %s\n' "$*" >> "$STUB_CALLS"
h=$STUB_DIR/held
touch "$h"
cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  showhold) cat "$h" ;;
  hold) for p in "$@"; do grep -qxF -- "$p" "$h" || printf '%s\n' "$p" >> "$h"; done ;;
  unhold) for p in "$@"; do grep -vxF -- "$p" "$h" > "$h.new" || true; mv -f "$h.new" "$h"; done ;;
esac
exit 0
EOF

# curl: with -w the status code ($STUB_DIR/http-code, or http-code-after
# once the hook of `systemctl start nginx` created nginx-up); without -w the
# exit status of a FastCGI listener probe (52: something answered).
cat > "$TBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_CALLS"
for a in "$@"; do
  if [ "$a" = -w ]; then
    code=200
    [ -f "$STUB_DIR/http-code" ] && code=$(cat "$STUB_DIR/http-code")
    if [ -f "$STUB_DIR/nginx-up" ] && [ -f "$STUB_DIR/http-code-after" ]; then code=$(cat "$STUB_DIR/http-code-after"); fi
    printf '%s' "$code"
    exit 0
  fi
done
exit "${STUB_CURL_RC:-52}"
EOF

# df: "SIZE_KB FREE_KB" from df.root, or df.backup for paths below the
# fixture root while that file exists (backups on their own mount).
cat > "$TBIN/df" <<'EOF'
#!/usr/bin/env bash
dir=""
for a in "$@"; do dir=$a; done
f=$STUB_DIR/df.root
mnt=/
case $dir in
  "$STUB_BK_PREFIX"|"$STUB_BK_PREFIX"/*)
    if [ -f "$STUB_DIR/df.backup" ]; then f=$STUB_DIR/df.backup; mnt=/bk; fi ;;
esac
size=104857600
free=52428800
if [ -f "$f" ]; then read -r size free < "$f"; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/stub %s %s %s 50%% %s\n' "$size" "$((size - free))" "$free" "$mnt"
EOF

cat > "$TBIN/crontab" <<'EOF'
#!/usr/bin/env bash
printf 'crontab %s\n' "$*" >> "$STUB_CALLS"
user=root; list=0; prev=""
for a in "$@"; do
  [ "$prev" = -u ] && user=$a
  [ "$a" = -l ] && list=1
  prev=$a
done
[ "$list" = 1 ] || exit 0
[ -f "$STUB_DIR/crontab.$user" ] || { echo "no crontab for $user" >&2; exit 1; }
cat "$STUB_DIR/crontab.$user"
EOF

cat > "$TBIN/update-alternatives" <<'EOF'
#!/usr/bin/env bash
printf 'update-alternatives %s\n' "$*" >> "$STUB_CALLS"
if [ "${1:-}" = --list ]; then
  [ -f "$STUB_DIR/alternatives" ] || exit 2
  cat "$STUB_DIR/alternatives"
fi
exit 0
EOF

# Record-only commands.  fuser says "nobody holds the dpkg lock".
for c in dpkg systemd-run systemd-tmpfiles useradd groupadd userdel usermod fuser; do
  rc=0
  [[ $c == fuser ]] && rc=1
  printf '#!/usr/bin/env bash\nprintf '"'"'%s %%s\\n'"'"' "$*" >> "$STUB_CALLS"\nexit %s\n' "$c" "$rc" > "$TBIN/$c"
done

# The package valkey-cli (on PATH) and our build's (copied per fixture).
cat > "$TPL/valkey" <<'EOF'
#!/usr/bin/env bash
printf 'valkey-cli[%s] %s\n' "$0" "$*" >> "$STUB_CALLS"
args=()
while [ $# -gt 0 ]; do
  case $1 in -h|-p|-s|-a) shift ;; *) args+=("$1") ;; esac
  shift
done
case "${args[*]}" in
  "CONFIG GET save") printf 'save\n3600 1\n' ;;
  "CONFIG GET appendonly") printf 'appendonly\nno\n' ;;
  DBSIZE) cat "$STUB_DIR/dbsize" 2>/dev/null || echo 5 ;;
  PING) echo PONG ;;
esac
exit 0
EOF
cp "$TPL/valkey" "$TBIN/valkey-cli"

# Candidate nginx: `-t` fails on the first live (uncommented) directive of
# $STUB_DIR/nginx-unknown found below the tested configuration's directory,
# with nginx's own message format.
cat > "$TPL/nginx" <<'EOF'
#!/usr/bin/env bash
printf 'nginx %s\n' "$*" >> "$STUB_CALLS"
conf=""; prev=""; test=0
for a in "$@"; do
  [ "$prev" = -c ] && conf=$a
  [ "$a" = -t ] && test=1
  prev=$a
done
[ "$test" = 1 ] || exit 0
if [ -f "$STUB_DIR/nginx-t-fail" ]; then echo 'nginx: [emerg] stub failure' >&2; exit 1; fi
dir=$(dirname "$conf")
for d in $(cat "$STUB_DIR/nginx-unknown" 2>/dev/null); do
  hit=$(grep -rnE "^[[:space:]]*${d}([[:space:]]|;)" "$dir" 2>/dev/null | head -n1)
  if [ -n "$hit" ]; then
    f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}
    echo "nginx: [emerg] unknown directive \"$d\" in $f:$n" >&2
    exit 1
  fi
done
exit 0
EOF

cat > "$TPL/php" <<'EOF'
#!/usr/bin/env bash
printf 'php-cli %s\n' "$*" >> "$STUB_CALLS"
case ${1:-} in
  -v) echo 'PHP 8.3.0 (cli) (stub)' ;;
  -r) exit 0 ;;
esac
exit 0
EOF
chmod 755 "$TBIN"/* "$TPL"/*

export PATH="$TBIN:$PATH"
export STUB_DIR="$STUBD" STUB_CALLS="$TCALLS" STUB_BK_PREFIX="$TROOT"

# ---------------------------------------------------------------------------
# Module overrides, then source setup.sh
# ---------------------------------------------------------------------------
export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TROOT/state"
export SETUP_MIGRATE_STATE_FILE="$TROOT/state/migrate-1.22"
export SETUP_MIGRATE_BACKUP_ROOT="$TROOT/backups"
export SETUP_MIGRATE_LOG="$TROOT/log/setup-migrate-1.22.log"
export SETUP_MIGRATE_UNIT_DIR="$TROOT/etc/systemd/system"
export SETUP_MIGRATE_POLICY_RC="$TROOT/usr/sbin/policy-rc.d"
export SETUP_MIGRATE_ANGIE_ETC="$TROOT/etc/angie"
export SETUP_MIGRATE_PHP_ETC="$TROOT/etc/php"
export SETUP_MIGRATE_VALKEY_ETC="$TROOT/etc/valkey"
export SETUP_MIGRATE_VALKEY_DATA="$TROOT/var/lib/valkey"
export SETUP_MIGRATE_LEGACY_TOOLS="$TROOT/usr/local/lib/setup-1.21-legacy"
export SETUP_MIGRATE_USR_BIN="$TROOT/usr/bin"
export SETUP_BUILD_LOCK="$TROOT/run/setup-build.lock"
export SETUP_TUNING_FILE="$TROOT/etc/default/setup-tuning"
export NGINX_ROOT="$TROOT/usr/local/lib/setup-nginx"
export NGINX_BUILD_ROOT="$NGINX_ROOT"
export NGINX_SYSTEMD_DIR="$SETUP_MIGRATE_UNIT_DIR"
export PHP_BUILD_ROOT="$TROOT/usr/local/lib/setup-php"
export VALKEY_BUILD_ROOT="$TROOT/usr/local/lib/setup-valkey"
export STUB_POLICY_RC="$SETUP_MIGRATE_POLICY_RC"
export SETUP_MIGRATE_DETACH=0
export SETUP_MEM_TOTAL_MB=8192
# A stale operator export must not change what the sourced helpers see.
unset NGINX_BIN NGINX_BUILD_STAGING SETUP_MIGRATE_RETRY SETUP_PHP_ALLOW_COLLATERAL \
  SETUP_PHP_ALLOW_MISSING_EXT SETUP_MIGRATE_IN_UNIT PHP_EXT_EXTRA PHP_EXT_DETECT_TREE \
  SETUP_PHP_BUILD SETUP_ANGIE_BUILD SETUP_NGINX_BUILD SETUP_VALKEY_BUILD SETUP_PHP_FPM_MODULES
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
# setup.sh installs an ERR trap and errexit for production; these tests
# drive failure paths on purpose and check every result explicitly.
trap - ERR
set +eE

# Paths the module hard-codes as plain variables, pointed at the fixtures.
MIGRATE_NGINX_ETC="$TROOT/etc/nginx"
MIGRATE_APT_PIN="$TROOT/etc/apt/preferences.d/setup-source-builds"
MIGRATE_REPORT_FILE="${MIGRATE_STATE_FILE}.report"
MIGRATE_OLD_HOOKS=("$TROOT/etc/apt/apt.conf.d/99setup-php-fpm-build"
                   "$TROOT/etc/apt/apt.conf.d/99setup-angie-build"
                   "$TROOT/etc/apt/apt.conf.d/99setup-valkey-build")
NGINX_BUILD_TOOL="$NGINX_ROOT/nginx-build.sh"
T_UNITS=$MIGRATE_UNIT_DIR
T_ANGIE=$MIGRATE_ANGIE_ETC
T_NGINX=$MIGRATE_NGINX_ETC
T_PHPETC=$MIGRATE_PHP_ETC

# Never touch the host: every path the module writes must be a fixture.
paths_ok=1
for p in "$MIGRATE_STATE_FILE" "$MIGRATE_BACKUP_ROOT" "$MIGRATE_LOG" "$MIGRATE_UNIT_DIR" \
         "$MIGRATE_POLICY_RC" "$MIGRATE_ANGIE_ETC" "$MIGRATE_NGINX_ETC" "$MIGRATE_PHP_ETC" \
         "$MIGRATE_VALKEY_ETC" "$MIGRATE_VALKEY_DATA" "$MIGRATE_LEGACY_TOOLS" "$MIGRATE_BUILD_LOCK" \
         "$MIGRATE_APT_PIN" "$MIGRATE_REPORT_FILE" "${MIGRATE_OLD_HOOKS[@]}" "$NGINX_BUILD_TOOL" \
         "$(migrate_nginx_root)" "$(migrate_php_root)" "$(migrate_valkey_root)" "$SETUP_TUNING_FILE" \
         "$MIGRATE_USR_BIN" \
         "$STATE_DIR"; do
  if [[ $p != "$TROOT"/* ]]; then
    printf 'ABORT  %s is outside the fixture root %s\n' "$p" "$TROOT"
    paths_ok=0
  fi
done
(( paths_ok )) || exit 1

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-migrate.sh,title=Migration test failed::%s\n' "$*"
}
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
not() { ! "$@"; }
has() { [[ $1 == *"$2"* ]] || { printf '      missing: %s\n' "$2"; return 1; }; }
lacks() { [[ $1 != *"$2"* ]] || { printf '      unexpected: %s\n' "$2"; return 1; }; }
eqv() { [[ $1 == "$2" ]] || { printf '      got:  %s\n      want: %s\n' "$1" "$2"; return 1; }; }
called() { grep -qF -- "$1" "$TCALLS" || { printf '      not called: %s\n' "$1"; return 1; }; }
not_called() { ! grep -qF -- "$1" "$TCALLS" || { printf '      called: %s\n' "$1"; return 1; }; }
count_calls() { grep -cF -- "$1" "$TCALLS" || true; }
# in_order PATTERN...: each pattern matches a call-log line after the line
# the previous pattern matched (fixed strings).
in_order() {
  local prev=0 p n
  for p in "$@"; do
    n=$(awk -v s="$p" -v from="$prev" 'NR > from && index($0, s) { print NR; exit }' "$TCALLS")
    if [[ -z $n ]]; then printf '      out of order or missing: %s\n' "$p"; return 1; fi
    prev=$n
  done
}
# A path moved into the backups keeps its absolute path below the snapshot.
in_backups() { [[ -n $(find "$MIGRATE_BACKUP_ROOT" -path "*$1" -print -quit 2>/dev/null) ]]; }
st() { migrate_state_get "$1"; }
words() { tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd' ' -; }
rec() { printf '%s\n' "$*" >> "$TCALLS"; }
mkexe() { mkdir -p "$(dirname "$1")"; cp -- "$2" "$1"; chmod 755 "$1"; }
pkgs() { # "STATUS NAME"...
  local e
  : > "$STUBD/dpkg"
  for e in "$@"; do printf '%s\t%s\n' "${e%% *}" "${e#* }" >> "$STUBD/dpkg"; done
}
active() { printf '%s\n' "$@" >> "$STUBD/active"; }
enabled() { printf '%s %s\n' "$1" "$2" >> "$STUBD/enabled"; }
ours_policy() {
  mkdir -p "$(dirname "$MIGRATE_POLICY_RC")"
  printf '#!/bin/sh\n%s 20250101T000000Z\nexit 101\n' "$MIGRATE_POLICY_MARK" > "$MIGRATE_POLICY_RC"
}

# A fresh fixture tree, stub state and call log; the in-memory globals of
# the module back to their initial values.
fresh() {
  [[ $TROOT == "$TMP"/root && $STUBD == "$TMP"/stub ]] || { echo "ABORT  bad fixture root"; exit 1; }
  rm -rf -- "$TROOT" "$STUBD"
  mkdir -p "$TROOT/state" "$TROOT/log" "$TROOT/run" "$TROOT/usr/sbin" "$TROOT/usr/bin" "$TROOT/etc/default" \
    "$T_UNITS" "$(dirname "$MIGRATE_APT_PIN")" "$(dirname "${MIGRATE_OLD_HOOKS[0]}")" \
    "$(migrate_nginx_root)" "$(migrate_php_root)" "$(migrate_valkey_root)" "$STUBD"
  : > "$STUBD/dpkg"; : > "$STUBD/active"; : > "$STUBD/enabled"; : > "$STUBD/held"
  : > "$TCALLS"
  MIGRATE_REPORT=(); MIGRATE_FAILED=0; MIGRATE_RUN_DIR=""; MIGRATE_IN_FLIGHT=""
  MIGRATE_POLICY_OURS=0; MIGRATE_DO_NGINX=0; MIGRATE_DO_VALKEY=0; MIGRATE_PHP_TODO=()
  MIGRATE_SIM_COLLATERAL=(); MIGRATE_SIM_REMOVED=(); MIGRATE_SURY_PKGS=(); MIGRATE_PA_ERRORS=()
  MIGRATE_SERIES_OK=()
}

# ---------------------------------------------------------------------------
# Integration: the helpers lib/migrate.sh calls in other modules
# ---------------------------------------------------------------------------
# The project's one Sury module probe is the module's own (lib/php-build.sh
# has none): `php-fpmX.Y -m` plus the CLI's own list, as build names.
T_SURYBIN="$TMP/sury-bin"
mkdir -p "$T_SURYBIN"
printf '#!/bin/sh\nprintf "[PHP Modules]\\nCore\\nredis\\nPDO\\n\\n[Zend Modules]\\nZend OPcache\\n"\n' > "$T_SURYBIN/php-fpm8.3"
printf '#!/bin/sh\nprintf "[PHP Modules]\\nCore\\nigbinary\\npcntl\\n\\n[Zend Modules]\\n"\n' > "$T_SURYBIN/php8.3"
chmod +x "$T_SURYBIN/php-fpm8.3" "$T_SURYBIN/php8.3"
check "module probe: FPM and CLI modules as one lower-case set (Zend OPcache -> zend_opcache)" \
  eqv "$( MIGRATE_SURY_SBIN=$T_SURYBIN MIGRATE_SURY_BIN=$T_SURYBIN; migrate_sury_modules 8.3 | paste -sd' ' - )" \
      "core igbinary pcntl pdo redis zend_opcache"
check "module probe: a missing php-fpmX.Y is a failed probe, not an empty set" \
  eqv "$( MIGRATE_SURY_SBIN=$T_SURYBIN MIGRATE_SURY_BIN=$T_SURYBIN; migrate_sury_modules 8.4 >/dev/null; echo "rc=$?" )" "rc=1"
for fn in php_build_buildable_exts php_build_ensure php_build_layout php_fpm_test php_active_set \
          php_build_links php_build_tmpfiles_apply nginx_build_ensure nginx_build_tmpfiles_apply \
          valkey_build_ensure valkey_build_retire_legacy deploy_nginx_tree fetch_server_configs \
          nginx_apply_profile nginx_snapshot_upstreams nginx_restore_upstreams tune_nginx_dedupe_http \
          tune_reset_changes nginx_secure_auth_files nginx_local_php_follow_pool \
          cf_tls_name_behind_cloudflare persist_tuning_var write_cron cron_extract_managed \
          mem_gate_allows sed_in_place commit_if_changed tmp_file tmp_dir; do
  check "the migration's helper ${fn} is defined" declare -F "$fn"
done

# Recorders for every helper that would reach a fixed host path (or run a
# real build), defined after the integration checks above.
migrate_clear_dsh_state() { rec "clear_dsh $*"; }
migrate_leftover_refs() { cat "$STUBD/leftover-refs" 2>/dev/null; return 0; }
migrate_angie_after_purge() { rec "angie_after_purge"; migrate_state_set angie-purge "done"; }
migrate_retire_sources() { rec "retire_sources $2 $3"; }
migrate_valkey_user_ensure() { rec "valkey_user_ensure"; }
migrate_link_bin() { rec "link_bin $1 $2"; }
migrate_wp_permalink_check() { :; }
migrate_cron_handover() { rec "cron_handover"; }
valkey_build_retire_legacy() { rec "valkey_build_retire_legacy"; }
nginx_secure_auth_files() { rec "secure_auth $*"; }
nginx_build_tmpfiles_apply() { rec "nginx_build_tmpfiles_apply"; }
migrate_sury_loaded_exts() { printf 'redis\nmysqli\nopcache\n'; }
php_active_set() { rec "php_active_set $1"; printf '%s\n' "$1" > "$MIGRATE_PHP_ETC/setup-active"; }
persist_tuning_var() { rec "persist $1=$2"; }
php_build_layout() { rec "php_build_layout $*"; }
php_build_tmpfiles_apply() { rec "php_build_tmpfiles_apply"; }
php_build_links() { rec "php_build_links $*"; }
php_primary_version() { cat "$STUBD/php-primary" 2>/dev/null; return 0; }
# php.net lookups: STUBD/php-newest is the newest released series (default
# 8.5, an empty file = offline); a series is released when it is not newer.
php_build_latest_series() { if [[ -f $STUBD/php-newest ]]; then cat "$STUBD/php-newest"; else echo 8.5; fi; }
php_build_release() {
  local n; n=$(php_build_latest_series); [[ -n $n ]] || return 0
  [[ $(printf "%s\n%s\n" "$1" "$n" | sort -V | tail -n1) == "$n" ]] && printf "%s.9\n" "$1"; return 0
}
php_fpm_test() {
  rec "php_fpm_test $1"
  if [[ -f $STUBD/php-fpm-test-fail ]]; then echo 'ERROR: stub failure'; return 1; fi
  echo 'test is successful'
}
cf_tls_name_behind_cloudflare() { grep -qxF -- "$1" "$STUBD/cf-names" 2>/dev/null; }
fetch_server_configs() { rec "fetch_server_configs"; return 1; }
# The cutover and verify waits are not part of what is tested.
sleep() { :; }

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
fresh
migrate_state_set nginx built
migrate_state_set nginx rendered
check "migrate_state_set replaces a key in place" eqv "$(st nginx)" rendered
check "a key appears once in the state file" eqv "$(grep -c '^nginx=' "$MIGRATE_STATE_FILE")" 1
check "the state file is mode 600" eqv "$(stat -c %a "$MIGRATE_STATE_FILE")" 600
check "the history keeps every value" eqv "$(grep -c 'nginx=' "${MIGRATE_STATE_FILE}.history")" 2
migrate_state_del nginx
check "migrate_state_del removes the key" eqv "$(st nginx)" ""
migrate_complete_set 1
check "complete=1 is written" grep -qx 'complete=1' "$MIGRATE_STATE_FILE"
check "the bare complete line is written with complete=1" grep -qx 'complete' "$MIGRATE_STATE_FILE"
migrate_complete_set 0
check "complete=0 drops the bare complete line" not grep -qx 'complete' "$MIGRATE_STATE_FILE"
check "complete=0 is written" grep -qx 'complete=0' "$MIGRATE_STATE_FILE"

# ---------------------------------------------------------------------------
# Resume after an interruption at each phase (migrate_resume_safe)
# ---------------------------------------------------------------------------
# migrate_resume_safe returns at once unless root; the test runs it with that
# one check replaced (nothing it calls here reaches a host path).
RESUME_SRC=$(declare -f migrate_resume_safe | sed -E 's/\[\[ \$\{EUID:-0\} -eq 0 \]\]/true/')
check "the root check of migrate_resume_safe is neutralised for the test" has "$RESUME_SRC" "true ||"
resume_probe() (
  eval "$RESUME_SRC"
  migrate_nginx_rollback() { rec "nginx_rollback $*"; }
  migrate_php_rollback() { rec "php_rollback $*"; }
  migrate_valkey_rollback() { rec "valkey_rollback $*"; }
  migrate_resume_safe
  echo "rc=$?"
)
resume_fixture() { # PHASE
  fresh
  [[ -n $1 ]] && migrate_state_set inflight "$1"
  ours_policy
  migrate_state_set policy-rc "$MIGRATE_POLICY_RC"
  mkdir -p "$TROOT/var/www/site"
  printf '<?php\n' > "$TROOT/var/www/site/setup-probe-123.php"
  migrate_state_set php-probe "$TROOT/var/www/site/setup-probe-123.php"
  ln -s "$(migrate_nginx_root)/sbin/nginx" "$TROOT/usr/sbin/nginx"
  migrate_state_set nginx-test-shim "$TROOT/usr/sbin/nginx"
}

resume_fixture nginx
out=$(resume_probe 2>&1)
check "resume nginx: the interrupted cutover is rolled back" called "nginx_rollback interrupted"
check "resume nginx: the part is postponed:interrupted (retried)" eqv "$(st nginx)" "postponed:interrupted"
check "resume nginx: inflight is cleared" eqv "$(st inflight)" ""
check "resume: a leftover policy-rc.d of ours is removed" not test -e "$MIGRATE_POLICY_RC"
check "resume: the removed policy-rc.d goes to the backups" in_backups "$MIGRATE_POLICY_RC"
check "resume: the policy-rc state key is dropped" eqv "$(st policy-rc)" ""
check "resume: a leftover PHP probe script is deleted" not test -e "$TROOT/var/www/site/setup-probe-123.php"
check "resume: the nginx test shim is moved away" not test -L "$TROOT/usr/sbin/nginx"
check "resume: the shim state key is dropped" eqv "$(st nginx-test-shim)" ""

resume_fixture php-8.3
out=$(resume_probe 2>&1)
check "resume php-8.3: the PHP switch is rolled back to Sury" called "php_rollback 8.3 interrupted"
check "resume php-8.3: the version is postponed:interrupted" eqv "$(st php-8.3)" "postponed:interrupted"
check "resume php-8.3: no other rollback runs" not_called "nginx_rollback"
check "resume php-8.3: inflight is cleared" eqv "$(st inflight)" ""

resume_fixture valkey
out=$(resume_probe 2>&1)
check "resume valkey: the Valkey switch is rolled back" called "valkey_rollback interrupted"
check "resume valkey: Valkey is postponed:interrupted" eqv "$(st valkey)" "postponed:interrupted"

resume_fixture purge
out=$(resume_probe 2>&1)
check "resume purge: dpkg --configure -a finishes the interrupted dpkg run" called "dpkg --configure -a"
check "resume purge: the removal phase runs forward again (removals=pending)" eqv "$(st removals)" pending
check "resume purge: nothing is rolled back" not_called "_rollback"
check "resume purge: inflight is cleared" eqv "$(st inflight)" ""

resume_fixture ""
out=$(resume_probe 2>&1)
check "resume with nothing in flight runs no dpkg and no rollback" not_called "dpkg --configure"
check "resume with nothing in flight still removes our policy-rc.d" not test -e "$MIGRATE_POLICY_RC"

fresh
migrate_state_set inflight nginx
active setup-migrate-1.22
out=$(resume_probe 2>&1)
check "resume does nothing while the migration unit runs" eqv "$(st inflight)" nginx
check "resume while the unit runs rolls nothing back" not_called "nginx_rollback"

fresh
mkdir -p "$(dirname "$MIGRATE_POLICY_RC")"
printf '#!/bin/sh\nexit 0\n' > "$MIGRATE_POLICY_RC"
out=$(resume_probe 2>&1)
check "an operator policy-rc.d (no marker) is never removed" test -f "$MIGRATE_POLICY_RC"

# migrate_needed and the retry rule
fresh
check "nothing installed and no state: no migration needed" not migrate_needed
migrate_state_set inflight nginx
check "a switch in flight needs the migration" migrate_needed
check "an nginx switch in flight does not hold the PHP gate" not migrate_needed php
migrate_state_set inflight php-8.3
check "a PHP switch in flight holds the PHP gate" migrate_needed php
fresh
migrate_state_set removals post-purge-failed
check "a failed removal phase needs the migration" migrate_needed
fresh
touch "$T_UNITS/setup-angie-build-refresh.timer"
check "a 1.21 timer on disk needs the migration" migrate_needed
fresh
ours_policy
check "a leftover policy-rc.d of ours needs the migration" migrate_needed
fresh
pkgs "ii angie"
migrate_state_set nginx "blocked:angie-only status_zone"
migrate_state_set nginx.scan none
check "a blocked nginx part with an unchanged scan does not re-enter" not migrate_needed
retry_needed() ( SETUP_MIGRATE_RETRY=1; migrate_needed )
check "SETUP_MIGRATE_RETRY=1 retries a blocked part" retry_needed
mkdir -p "$T_ANGIE"
printf 'events {}\n' > "$T_ANGIE/angie.conf"
check "a changed Angie tree (new scan digest) retries the blocked part" migrate_needed
fresh
migrate_state_set nginx "postponed:disk"
check "a postponed part always retries" migrate_part_retry_ok nginx anything
migrate_state_set nginx "failed:x"
migrate_state_set nginx.scan abc
check "a failed part with the same digest waits" not migrate_part_retry_ok nginx abc
check "a failed part with a changed digest retries" migrate_part_retry_ok nginx def

# Resume points of the main flow
fresh
pkgs "ii angie"
mkdir -p "$T_ANGIE"
printf 'events {}\n' > "$T_ANGIE/angie.conf"
mkexe "$(migrate_nginx_root)/staging/sbin/nginx" "$TPL/nginx"
migrate_state_set nginx built
out=$( (
  nginx_build_ensure() { rec "nginx_build_ensure $*"; return 0; }
  php_build_ensure() { rec "php_build_ensure $* tree=${PHP_EXT_DETECT_TREE:-}"; return 0; }
  valkey_build_ensure() { rec "valkey_build_ensure $*"; return 1; }
  MIGRATE_DO_NGINX=1; MIGRATE_PHP_TODO=(8.3); MIGRATE_DO_VALKEY=1
  migrate_build_all
  echo "do_nginx=$MIGRATE_DO_NGINX do_valkey=$MIGRATE_DO_VALKEY todo=${MIGRATE_PHP_TODO[*]}"
) 2>&1 )
check "resume: a built nginx candidate is not rebuilt" not_called "nginx_build_ensure"
check "build: PHP is built build-only with the Angie tree for extension detection" \
  called "php_build_ensure 8.3 build-only migrate migrate_out tree=$T_ANGIE"
check "build: PHP 8.3 is recorded as built" eqv "$(st php-8.3)" built
check "build: a failed Valkey build is postponed" eqv "$(st valkey)" "postponed:build failed"
check "build: a failed Valkey build drops the Valkey part from this run" has "$out" "do_valkey=0"
check "build: the nginx part stays on" has "$out" "do_nginx=1"
migrate_state_set nginx "postponed:interrupted"
: > "$TCALLS"
out=$( (
  nginx_build_ensure() { rec "nginx_build_ensure $*"; return 0; }
  MIGRATE_DO_NGINX=1
  migrate_build_all
) 2>&1 )
check "resume: an interrupted nginx part is built again (build-only)" called "nginx_build_ensure build-only migrate migrate_out"
check "resume: the rebuilt nginx part is recorded as built" eqv "$(st nginx)" built
migrate_state_set nginx rendered
: > "$TCALLS"
out=$( ( migrate_nginx_prepare; echo "rc=$?" ) 2>&1 )
check "resume: a rendered tree with its candidate skips the render" has "$out" "rc=0"
check "resume: a rendered tree is not downloaded again" not_called "fetch_server_configs"

fresh
migrate_state_set nginx cutover
active nginx
out=$( ( migrate_nginx_rollback() { rec "nginx_rollback $*"; }; migrate_nginx_finish_cutover ) 2>&1 )
check "resume: a verified cutover of an earlier run is finished forward" eqv "$(st nginx)" "done"
check "resume: the finished cutover hands cron over" called "cron_handover"
fresh
migrate_state_set nginx cutover
printf 'nginx\n' > "$STUBD/fail-start"
out=$( ( migrate_nginx_rollback() { rec "nginx_rollback $*"; }; migrate_nginx_finish_cutover ) 2>&1 )
check "resume: a cutover whose nginx does not run is rolled back to Angie" called "nginx_rollback nginx was not running"

fresh
migrate_state_set inflight purge
migrate_mark_complete
check "complete=1 is not written while a phase is in flight" not grep -qx 'complete=1' "$MIGRATE_STATE_FILE"
migrate_state_del inflight
migrate_state_set removals started
migrate_mark_complete
check "complete=1 is not written while the removal phase is open" not grep -qx 'complete=1' "$MIGRATE_STATE_FILE"
migrate_state_set removals "done"
migrate_mark_complete
check "complete=1 once nothing is in flight" grep -qx 'complete=1' "$MIGRATE_STATE_FILE"

fresh
migrate_state_set removals started
migrate_state_set php-8.3 "done"
out=$( (
  migrate_removals_verify() { rec "verify $*"; return 0; }
  migrate_removals_finalize() { rec "finalize"; }
  migrate_removals
  echo "rc=$?"
) 2>&1 )
check "resume: an interrupted removal phase with nothing left is verified" called "verify 8.3"
check "resume: the verified removal phase is finalised afterwards" in_order "verify 8.3" "finalize"
check "resume: no package is removed again" not_called "APT real"

fresh
snapa="$MIGRATE_BACKUP_ROOT/angie-earlier"
mkdir -p "$snapa$T_ANGIE/http.d" "$T_ANGIE"
printf 'events {}\n' > "$snapa$T_ANGIE/angie.conf"
printf 'live\n' > "$T_ANGIE/live.conf"
migrate_state_set angie-moved "$snapa"
out=$( ( migrate_angie_move_aside; echo "rc=$?" ) 2>&1 )
check "resume: a recorded complete Angie snapshot is reused" has "$out" "rc=0"
check "resume: /etc/angie is never snapshotted twice" test -f "$T_ANGIE/live.conf"
rm -rf -- "$snapa$T_ANGIE/http.d"
out=$( ( migrate_angie_move_aside; echo "rc=$?"; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "resume: an incomplete recorded Angie snapshot refuses the purge" has "$out" "rc=1"
check "resume: the refusal names the incomplete snapshot" has "$out" "is incomplete; Angie purge refused"

# ---------------------------------------------------------------------------
# Steps 1-2: the 1.21 build knobs and triggers
# ---------------------------------------------------------------------------
fresh
printf 'PHP_BUILD=clang\nANGIE_BUILD=1\nPHP_FPM_MODULES=all\nXF_MEMBER_GZIP=angie\nKEEP_ME=1\n' > "$SETUP_TUNING_FILE"
out=$( ( migrate_scrub_knobs; echo "rc=$?" ) 2>&1 )
check "scrub: the 1.21 build knobs leave the tuning file" \
  eqv "$(paste -sd' ' "$SETUP_TUNING_FILE")" "XF_MEMBER_GZIP=nginx KEEP_ME=1"
check "scrub: PHP_FPM_MODULES is recorded before it goes" eqv "$(st php-fpm-modules-121)" all
check "scrub: a copy of the tuning file is kept" in_backups "/setup-tuning"
check "scrub: the step is marked done" eqv "$(st knobs)" "done"

fresh
UD=$T_UNITS
for u in setup-angie-build-refresh.timer setup-php-fpm-build-refresh.timer setup-angie-build.service \
         setup-php-fpm-build@.service setup-php-fpm-build@8.3.service; do
  printf '[Unit]\n' > "$UD/$u"
done
printf '[Unit]\nDescription=Valkey build %s\n' "$MIGRATE_OLD_VALKEY_UNIT_MARK" > "$UD/setup-valkey-build.service"
printf 'DPkg::Post-Invoke {"true";};\n' > "${MIGRATE_OLD_HOOKS[0]}"
printf '#!/bin/bash\nSETUP_PHP_BUILD=clang\n' > "$(migrate_php_root)/php-fpm-build.sh"
printf '# common\n' > "$(migrate_php_root)/build-common.sh"
printf 'PHP_83=8.3.0\n' > "$(migrate_php_root)/php-build.conf"
mkdir -p "$UD/php8.3-fpm.service.d"
printf '[Service]\nExecStartPre=%s conf 8.3\n' "$(migrate_php_root)/php-fpm-build.sh" > "$UD/php8.3-fpm.service.d/zz-setup-build.conf"
printf '#!/bin/bash\nSETUP_VALKEY_BUILD=clang\n' > "$(migrate_valkey_root)/valkey-build.sh"
printf 'VALKEY=8.0\n' > "$(migrate_valkey_root)/valkey-build.conf"
printf 'setup-php-fpm-build@8.3.service loaded active running PHP build\nsetup-angie-fallback-1.service loaded active running fallback\n' > "$STUBD/list-units"
check "1.21 triggers are detected before the retirement" migrate_old_triggers_present
out=$( ( migrate_retire_triggers; echo "rc=$?" ) 2>&1 )
check "retire: the step succeeds" has "$out" "rc=0"
check "retire: 1.21 timers are disabled and stopped" called "systemctl disable --now setup-angie-build-refresh.timer"
check "retire: a running 1.21 PHP build job is stopped" called "systemctl stop setup-php-fpm-build@8.3.service"
check "retire: a 1.21 transient fallback unit is stopped" called "systemctl stop setup-angie-fallback-1.service"
check "retire: the 1.21 Valkey build unit is stopped" called "systemctl stop setup-valkey-build.service"
check "retire: 1.21 unit files leave the unit directory" not test -e "$UD/setup-angie-build.service"
check "retire: retired unit files are kept in the backups" in_backups "$UD/setup-angie-build.service"
check "retire: instance unit files are retired too" in_backups "$UD/setup-php-fpm-build@8.3.service"
check "retire: the 1.21 Valkey unit (by its marker) is retired" not test -e "$UD/setup-valkey-build.service"
check "retire: the 1.21 APT hook is retired" in_backups "${MIGRATE_OLD_HOOKS[0]}"
check "retire: the PHP tool a drop-in calls is kept at the legacy path" \
  test -f "$MIGRATE_LEGACY_TOOLS/php/php-fpm-build.sh"
check "retire: the old PHP tool leaves the shared root" not test -e "$(migrate_php_root)/php-fpm-build.sh"
check "retire: the drop-in is pointed at the legacy tool" \
  grep -qF "$MIGRATE_LEGACY_TOOLS/php/php-fpm-build.sh conf 8.3" "$UD/php8.3-fpm.service.d/zz-setup-build.conf"
check "retire: the drop-in names the legacy configuration" \
  grep -qxF "Environment=PHP_BUILD_CONF=$MIGRATE_LEGACY_TOOLS/php/php-build.conf" "$UD/php8.3-fpm.service.d/zz-setup-build.conf"
check "retire: the legacy PHP tool is recorded" eqv "$(st legacy-php)" "$MIGRATE_LEGACY_TOOLS/php"
check "retire: a Valkey tool no drop-in calls goes to the backups" in_backups "$(migrate_valkey_root)/valkey-build.sh"
check "retire: no legacy Valkey copy is kept without a drop-in" not test -e "$MIGRATE_LEGACY_TOOLS/valkey"
check "retire: D's own legacy sweep runs" called "valkey_build_retire_legacy"
check "retire: systemd is reloaded" called "systemctl daemon-reload"
check "retire: the state records the retirement" eqv "$(st triggers)" retired
check "retire: no 1.21 trigger is left" not migrate_old_triggers_present
touch "$UD/setup-php-fpm-build-refresh.timer"
out=$( ( migrate_assert_no_old_triggers; echo "rc=$?" ) 2>&1 )
check "a reappearing 1.21 timer refuses the next cutover" has "$out" "rc=1"

fresh
printf '[Unit]\nDescription=setup.sh 1.22 Valkey build\n' > "$T_UNITS/setup-valkey-build.service"
printf '#!/bin/bash\n# 1.22 tool\n' > "$(migrate_valkey_root)/valkey-build.sh"
out=$( ( migrate_retire_triggers; echo "rc=$?" ) 2>&1 )
check "retire: the 1.22 setup-valkey-build.service (no 1.21 marker) stays" test -f "$T_UNITS/setup-valkey-build.service"
check "retire: the 1.22 valkey-build.sh stays" test -f "$(migrate_valkey_root)/valkey-build.sh"
check "retire: a host without 1.21 triggers passes" has "$out" "rc=0"

# ---------------------------------------------------------------------------
# Step 3: pre-flight blockers
# ---------------------------------------------------------------------------
angie_fixture() {
  mkdir -p "$T_ANGIE/conf.d"
  printf '%s\n' 'user angie;' \
    'load_module modules/ngx_http_brotli_filter_module.so;' \
    'load_module modules/ngx_http_js_module.so;' \
    'events {}' \
    'http {' \
    '    include conf.d/*.conf;' \
    '}' > "$T_ANGIE/angie.conf"
  printf '%s\n' 'server {' \
    '    listen 80;' \
    '    server_name site.example.test;' \
    '    status_zone site;' \
    '    location / {' \
    '        sub_filter a b;' \
    '        limit_conn perip 10;' \
    '        auth_request /auth;' \
    '        add_header X-Angie $angie_version;' \
    '    }' \
    '}' > "$T_ANGIE/conf.d/site.conf"
}
fresh
angie_fixture
scan=$(migrate_nginx_scan "$T_ANGIE" "$T_ANGIE/angie.conf")
S=$T_ANGIE/conf.d/site.conf
check "scan: an Angie-only directive is found with file:line" has "$scan" $'angie-only\t'"$S:4"$'\tstatus_zone'
check "scan: an \$angie_* variable is Angie-only" has "$scan" $'angie-only\t'"$S:9"$'\t$angie_*'
check "scan: an unbuilt module directive is found" has "$scan" $'unbuilt\t'"$S:8"$'\tauth_request'
check "scan: a droppable directive is classified droppable" has "$scan" $'droppable\t'"$S:6"$'\tsub_filter'
check "scan: limit_conn is a security control" has "$scan" $'security\t'"$S:7"$'\tlimit_conn'
# The Angie package's http.d/default.conf (an `api` status location) is never
# copied to /etc/nginx, so it must not block (1.22.0 migration test).
pkgtree=$TMP/scan-pkg; rm -rf "$pkgtree"; mkdir -p "$pkgtree/http.d"
printf '%s\n' 'events {}' 'http {' '    include http.d/*.conf;' '}' > "$pkgtree/angie.conf"
printf '%s\n' 'server {' '    listen 80;' '    location /status/ {' '        api /status/;' '    }' '}' > "$pkgtree/http.d/default.conf"
pkgscan=$(migrate_nginx_scan "$pkgtree" "$pkgtree/angie.conf")
check "scan: the package's http.d/default.conf (api status) is skipped, not a blocker" test -z "$pkgscan"
# Catch-all vs real vhosts in the cutover comparison (1.22.0 migration test:
# Angie's package page answered Host: localhost with 200; nginx closes it).
cmp_case() { # localhost-now vhost-now -> rc
  (
    set +eE; trap - ERR
    b=$TMP/cmp-base.tsv
    printf 'localhost\thttp\t/\t200\tcatchall\nsite.example.test\thttps\t/\t200\t1\n' > "$b"
    migrate_http_code() { case $2 in localhost) printf '%s' "$CMP_L" ;; *) printf '%s' "$CMP_V" ;; esac; }
    sleep() { :; }
    CMP_L=$1 CMP_V=$2 migrate_compare_baseline "$b" >/dev/null
    printf '%s' "$?"
  )
}
check "baseline: the catch-all may close (000) or refuse (4xx) where the package page answered" \
  test "$(cmp_case 000 200),$(cmp_case 404 200)" = "0,0"
check "baseline: a catch-all 5xx or a real vhost that stops answering still fails the cutover" \
  test "$(cmp_case 502 200),$(cmp_case 000 000)" = "1,1"
# Retry rule: an unchanged tree is not retried by the same code, but a new
# release (a fixed migration) retries a blocked/rolled-back part.
retry_case() { # code-recorded(current|old) -> rc of migrate_part_retry_ok
  (
    set +eE; trap - ERR
    migrate_state_set nginx "rolled-back:test"
    migrate_state_set nginx.scan "digest-a"
    [[ $1 == old ]] && migrate_state_set nginx.code "an-older-release"
    migrate_part_retry_ok nginx "digest-a"
    printf '%s' "$?"
    # Leave no state behind for the pre-flight checks below.
    migrate_state_del nginx; migrate_state_del nginx.scan; migrate_state_del nginx.code
  )
}
check "retry: the same code and the same tree do not retry a rolled-back part" test "$(retry_case current)" = 1
check "retry: a new release retries a rolled-back part on an unchanged tree" test "$(retry_case old)" = 0
check "retry: recording a part's scan digest records the code digest with it" \
  bash -c 'grep -q "\.code\" \"\$(migrate_code_digest)\"" "$1"' _ "$ROOT/lib/migrate.sh"
check "scan: a load_module line is reported" has "$scan" $'load_module\t'"$T_ANGIE/angie.conf:3"
check "scan: the brotli load_module is not a blocker" lacks "$scan" "brotli"
printf '%s\n' "$scan" > "$TMP/scan.tsv"
blk=$(migrate_nginx_blockers "$TMP/scan.tsv")
check "blockers: Angie-only directives block" has "$blk" "angie-only status_zone ($S:4)"
check "blockers: unbuilt module directives block" has "$blk" "unbuilt auth_request"
check "blockers: droppable directives do not block" lacks "$blk" "sub_filter"
check "blockers: limit_conn does not block (it is commented with a warning)" lacks "$blk" "limit_conn"

pkgs "ii angie"
out=$( ( migrate_preflight_disk() { :; }; migrate_preflight 1 ) 2>&1 )
check "dry pre-flight prints the nginx blockers" has "$out" "nginx: BLOCKED (Angie keeps serving)"
check "dry pre-flight writes no part state" eqv "$(st nginx)" ""
out=$( (
  migrate_preflight_disk() { :; }
  migrate_preflight 0
  echo "do_nginx=$MIGRATE_DO_NGINX"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
) 2>&1 )
check "pre-flight: blockers keep the nginx part off" has "$out" "do_nginx=0"
check "pre-flight: the nginx part is recorded as blocked" has "$(st nginx)" "blocked:"
check "pre-flight: the scan digest is recorded for the retry rule" eqv "$(st nginx.scan)" "$(migrate_nginx_scan_digest)"
check "pre-flight: the report lists the blockers by file:line" has "$out" "$S:4"
check "pre-flight: the report says Angie keeps serving" has "$out" "nginx part blocked before any build; Angie keeps serving"
out=$( ( migrate_preflight_disk() { :; }; migrate_preflight 0; echo "do_nginx=$MIGRATE_DO_NGINX" ) 2>&1 )
check "pre-flight: an unchanged blocked tree is not retried" has "$out" "nginx part stays on Angie"
printf '%s\n' 'user angie;' 'events {}' 'http {' '    include conf.d/*.conf;' '}' > "$T_ANGIE/angie.conf"
printf '%s\n' 'server {' '    server_name site.example.test;' '    location / {' \
  '        sub_filter a b;' '        limit_conn perip 10;' '    }' '}' > "$S"
out=$( (
  migrate_preflight_disk() { :; }
  migrate_preflight 0
  echo "do_nginx=$MIGRATE_DO_NGINX"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
) 2>&1 )
check "pre-flight: a fixed tree (new digest) lets the nginx part run" has "$out" "do_nginx=1"
check "pre-flight: a droppable directive is reported as commented" has "$out" "sub_filter at $S:4 will be commented (module not built)"
check "pre-flight: a commented limit_conn is a security warning" has "$out" "limit_conn at $S:5 will be commented: security control removed"

# Collateral of the removal lists
fresh
pkgs "ii php8.3-fpm" "ii php8.3-cli" "ii php-common" "rc php8.2-fpm" "ii debsuryorg-archive-keyring" \
     "ii phpmyadmin" "ii libapache2-mod-php8.3"
printf 'Remv phpmyadmin [5.2]\n' > "$STUBD/apt-sim-extra-if.php-common"
out=$( (
  migrate_sury_purge_preflight; echo "rc=$?"
  echo "pkgs=${MIGRATE_SURY_PKGS[*]}"
  echo "coll=${MIGRATE_SIM_COLLATERAL[*]}"
) 2>&1 )
check "collateral: an extra package removed by the Sury purge refuses it" has "$out" "rc=1"
check "collateral: the extra package is named" has "$out" "coll=phpmyadmin"
check "collateral: the simulated list is exact" \
  called "APT sim purge: debsuryorg-archive-keyring php-common php8.2-fpm php8.3-cli php8.3-fpm policy=no"
check "collateral: libapache2-mod-php is not in the Sury list" lacks "$out" "pkgs=libapache2"
check "collateral: no glob is handed to apt" not grep -qE '^apt-get .*[*?]' "$TCALLS"
out=$( ( SETUP_PHP_ALLOW_COLLATERAL=1; migrate_sury_purge_preflight; echo "rc=$?" ) 2>&1 )
check "collateral: SETUP_PHP_ALLOW_COLLATERAL=1 accepts it" has "$out" "rc=0"
touch "$STUBD/apt-sim-fail"
out=$( ( migrate_sury_purge_preflight; echo "rc=$?"; echo "coll=${MIGRATE_SIM_COLLATERAL[*]}" ) 2>&1 )
check "collateral: an apt refusal refuses the purge" has "$out" "coll=(apt refused the simulation)"

fresh
pkgs "ii angie" "ii angie-module-geoip2" "ii some-tool"
printf 'Remv some-tool [1.0]\n' > "$STUBD/apt-sim-extra-if.angie"
out=$( ( migrate_preflight_collateral 0; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "collateral: the Angie purge is skipped when it removes another package" has "$out" "purge angie would also remove some-tool"

fresh
pkgs "ii angie" "ii nginx-common" "ii libnginx-mod-http-echo"
printf 'Remv certbot-helper [1.0]\n' > "$STUBD/apt-sim-extra-if.nginx-common"
out=$( ( migrate_distro_nginx_blocks 0; echo "rc=$?" ) 2>&1 )
check "collateral: the distro nginx purge with collateral blocks the nginx part" has "$out" "rc=0"
check "collateral: the nginx part records the distro collateral" eqv "$(st nginx)" "blocked:distro nginx collateral"
fresh
pkgs "ii nginx-common" "ii nginx"
active nginx
out=$( ( migrate_distro_nginx_blocks 0; echo "rc=$?" ) 2>&1 )
check "a serving distro nginx (no Angie) blocks the nginx part" eqv "$(st nginx)" "blocked:distro nginx active"

# PHP pre-flight refusals
fresh
pkgs "ii php8.3-fpm"
active php8.3-fpm
out=$( ( SETUP_MEM_TOTAL_MB=2048; migrate_preflight_disk() { :; }; migrate_preflight 0; echo "todo=[${MIGRATE_PHP_TODO[*]}]" ) 2>&1 )
check "pre-flight: PHP below the 4 GB class is refused (Sury keeps serving)" eqv "$(st php-8.3)" refused-mem
check "pre-flight: a refused version is not migrated" has "$out" "todo=[]"
fresh
pkgs "ii php8.3-fpm"
active php8.3-fpm
out=$( ( migrate_sury_loaded_exts() { return 1; }; migrate_preflight_disk() { :; }; migrate_preflight 0 ) 2>&1 )
check "pre-flight: a failed module probe refuses the version, not moved blind" \
  eqv "$(st php-8.3)" "refused:no module probe"
fresh
pkgs "ii php8.3-fpm" "ii php8.4-fpm"
active php8.3-fpm php8.4-fpm
for v in 8.3 8.4; do
  mkdir -p "$T_PHPETC/$v/fpm/pool.d"
  printf '[www]\nlisten = /run/php/php-fpm.sock\n' > "$T_PHPETC/$v/fpm/pool.d/www.conf"
done
out=$( ( migrate_preflight_disk() { :; }; migrate_preflight 0 ) 2>&1 )
check "pre-flight: two versions on one listener are both refused" \
  eqv "$(st php-8.3)|$(st php-8.4)" "refused:listener /run/php/php-fpm.sock (PHP 8.3 8.4)|refused:listener /run/php/php-fpm.sock (PHP 8.3 8.4)"
fresh
pkgs "ii php8.3-fpm" "ii php8.4-fpm"
active php8.3-fpm php8.4-fpm
for v in 8.3 8.4; do
  mkdir -p "$T_PHPETC/$v/fpm/pool.d"
  printf '[www]\nlisten = /run/php/php%s-fpm.sock\n' "$v" > "$T_PHPETC/$v/fpm/pool.d/www.conf"
done
printf '8.4\n' > "$T_PHPETC/setup-active"
out=$( (
  migrate_preflight_disk() { :; }
  migrate_php_app_required_exts() { return 0; }
  migrate_preflight 0
  echo "todo=${MIGRATE_PHP_TODO[*]}"
) 2>&1 )
check "pre-flight: only the active version moves; a second one is refused" eqv "$(st php-8.3)" "refused:secondary (active 8.4)"
check "pre-flight: the active version is queued" has "$out" "todo=8.4"
check "pre-flight: the extensions loaded today are kept in PHP_EXT_EXTRA" called "persist PHP_EXT_EXTRA="

# Series the source build cannot make (1.22.3): refused in the pre-flight,
# never the primary, retried when the series is released.
fresh
pkgs "ii php8.5-fpm" "ii php8.6-fpm"
active php8.5-fpm php8.6-fpm
for v in 8.5 8.6; do
  mkdir -p "$T_PHPETC/$v/fpm/pool.d"
  printf '[www]\nlisten = /run/php/php%s-fpm.sock\n' "$v" > "$T_PHPETC/$v/fpm/pool.d/www.conf"
done
out=$( (
  migrate_preflight_disk() { :; }
  migrate_php_app_required_exts() { return 0; }
  migrate_preflight 0
  echo "todo=${MIGRATE_PHP_TODO[*]}"
) 2>&1 )
check "series: an unreleased series (Sury RC) is refused in the pre-flight" eqv "$(st php-8.6)" "refused:series not buildable"
check "series: an unreleased newer series does not become the primary" has "$out" "todo=8.5"
check "series: the released version is not refused as secondary" not eqv "$(st php-8.5)" "refused:secondary (active 8.6)"
d1=$(migrate_state_get php-8.6.scan)
printf '8.6\n' > "$STUBD/php-newest"; MIGRATE_SERIES_OK=()
check "series: the X.Y.0 release changes the scan digest (the refusal is retried)" \
  not eqv "$(migrate_php_scan_digest 8.6)" "$d1"
fresh
pkgs "ii php8.0-fpm"
active php8.0-fpm
mkdir -p "$T_PHPETC/8.0/fpm/pool.d"
printf '[www]\nlisten = /run/php/php8.0-fpm.sock\n' > "$T_PHPETC/8.0/fpm/pool.d/www.conf"
out=$( ( migrate_preflight_disk() { :; }; migrate_preflight 0; echo "todo=[${MIGRATE_PHP_TODO[*]}]" ) 2>&1 )
check "series: PHP 8.0 is refused before any build" eqv "$(st php-8.0)" "refused:series not buildable"
check "series: nothing is queued for PHP 8.0" has "$out" "todo=[]"
fresh
pkgs "ii php8.0-fpm"
active php8.0-fpm
mkdir -p "$T_PHPETC/8.0/fpm/pool.d"
printf "[www]\nlisten = /run/php/php8.0-fpm.sock\n" > "$T_PHPETC/8.0/fpm/pool.d/www.conf"
out=$( ( migrate_preflight_disk() { :; }; migrate_preflight 1 ) 2>&1 )
check "series: the dry run says 8.0 is refused, not 'Sury -> source build'" has "$out" "PHP 8.0: refused, the source build supports"
fresh
: > "$STUBD/php-newest"
check "series: offline (nothing resolves) counts as buildable" migrate_php_series_ok 8.5

# The primary follows the vhosts (1.22.3): an idle newer version does not
# displace the one the sites call.
fresh
pkgs "ii php8.3-fpm" "ii php8.4-fpm" "ii angie"
active php8.3-fpm php8.4-fpm
for v in 8.3 8.4; do
  mkdir -p "$T_PHPETC/$v/fpm/pool.d"
  printf '[www]\nlisten = /run/php/php%s-fpm.sock\n' "$v" > "$T_PHPETC/$v/fpm/pool.d/www.conf"
done
mkdir -p "$T_ANGIE/conf.d"
printf 'server {\n  location ~ \\.php$ {\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n  }\n}\n' > "$T_ANGIE/conf.d/a.conf"
printf 'server {\n  location ~ \\.php$ {\n    fastcgi_pass   unix:/run/php/php8.3-fpm.sock ;\n  }\n}\n' > "$T_ANGIE/conf.d/b.conf"
check "primary: the version the vhosts call wins over a newer idle one" eqv "$(migrate_primary_version)" 8.3
rm -f "$T_ANGIE"/conf.d/*.conf
check "primary: without references the newest running version" eqv "$(migrate_primary_version)" 8.4

# Operator php.ini edits survive the layout (1.22.3).
fresh
T_SURYINI="$TMP/sury-ini"; rm -rf "$T_SURYINI"; mkdir -p "$T_SURYINI/8.3" "$T_PHPETC/8.3/fpm/conf.d" "$T_PHPETC/8.3/cli/conf.d"
printf '[PHP]\n; c\nmemory_limit = 128M\nupload_max_filesize = 2M\nexpose_php = Off\n[Date]\n;date.timezone =\n' > "$T_SURYINI/8.3/php.ini-production"
printf '[PHP]\nmemory_limit = -1\n' > "$T_SURYINI/8.3/php.ini-production.cli"
printf '[PHP]\nmemory_limit = 512M\nupload_max_filesize = 2M\nexpose_php = Off\nextension = foo.so\n[Date]\ndate.timezone = Asia/Manila\n[HOST=a.example]\nopen_basedir = /var/www/a\n' > "$T_PHPETC/8.3/fpm/php.ini"
printf '[PHP]\nmemory_limit = -1\n' > "$T_PHPETC/8.3/cli/php.ini"
( MIGRATE_SURY_INI_DIR=$T_SURYINI; migrate_php_ini_carry 8.3 ) >/dev/null 2>&1
f="$T_PHPETC/8.3/fpm/conf.d/10-migrated-php-ini.ini"
c=$(cat "$f" 2>/dev/null || true)
check "php.ini: a changed directive is carried over" has "$c" "memory_limit = 512M"
check "php.ini: a directive production leaves commented is carried over" has "$c" "date.timezone = Asia/Manila"
check "php.ini: [HOST=] blocks are kept" has "$c" "[HOST=a.example]"
check "php.ini: unchanged directives are not repeated" lacks "$c" "upload_max_filesize"
check "php.ini: extension lines are not carried (the build has them in)" lacks "$c" "foo.so"
check "php.ini: an unchanged php.ini writes no file" not test -e "$T_PHPETC/8.3/cli/conf.d/10-migrated-php-ini.ini"


# Cron between the cutover and the Sury purge (1.22.3): Sury's
# /usr/bin/phpX.Y is diverted to our CLI, its packages held; the rollback
# and the post-purge pass take the diversion back.
fresh
pkgs "ii php8.3-cli" "ii php8.3-fpm" "ii php8.3-mysql" "ii php8.4-cli"
cli=$(migrate_php_cli_bin 8.3); mkexe "$cli" "$TPL/php"
printf 'sury-binary\n' > "$TROOT/usr/bin/php8.3"
printf '%s\n' "$TROOT/usr/bin/php8.3" >> "$STUBD/dpkg-owned"
migrate_php_divert_cli 8.3 >/dev/null 2>&1; rc=$?
check "cron: the divert succeeds" eqv "$rc" 0
check "cron: Sury's CLI is diverted locally to phpX.Y.sury" \
  called "dpkg-divert --local --rename --divert $TROOT/usr/bin/php8.3.sury --add $TROOT/usr/bin/php8.3"
check "cron: /usr/bin/phpX.Y is our CLI right after the cutover" eqv "$(readlink "$TROOT/usr/bin/php8.3")" "$cli"
check "cron: Sury's binary is kept beside it" eqv "$(cat "$TROOT/usr/bin/php8.3.sury")" sury-binary
check "cron: the diversion is recorded" eqv "$(st php-8.3.divert)" "$TROOT/usr/bin/php8.3"
: > "$TCALLS"; migrate_php_divert_cli 8.3 >/dev/null 2>&1
check "cron: a second divert does not add another diversion" not_called "--add"
migrate_php_hold_version 8.3 >/dev/null 2>&1
check "cron: the migrated version's Sury packages are held" eqv "$(sort "$STUBD/held" | paste -sd' ' -)" "php8.3-cli php8.3-fpm php8.3-mysql"
check "cron: the holds are recorded for the unhold before the purge" eqv "$(st sury-held)" "php8.3-cli php8.3-fpm php8.3-mysql"
check "cron: another version's packages are not held" not grep -qx php8.4-cli "$STUBD/held"
# apt-daily / unattended-upgrades holding the dpkg lock: the hold is retried
# (EPYC 24.04 replica, 1.22.4); any other apt-mark error is not.
am_case() { # lock-failures other-error -> rc and the number of apt-mark runs
  local rc cnt=$TMP/am-count
  : > "$cnt"
  AM_LOCKS=$1 AM_OTHER=$2 AM_CNT=$cnt
  # migrate_apt_mark runs apt-mark in $(...): count in a file.
  apt-mark() {
    local n
    echo x >> "$AM_CNT"; n=$(wc -l < "$AM_CNT")
    if (( n <= AM_LOCKS )); then echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 42 (apt-get)" >&2; return 100; fi
    if [[ $AM_OTHER == 1 ]]; then echo "E: Unable to locate package nope" >&2; return 100; fi
    return 0
  }
  MIGRATE_APT_MARK_TRIES=5 MIGRATE_APT_MARK_SLEEP=0 migrate_apt_mark hold php8.3-cli; rc=$?
  unset -f apt-mark
  printf '%s %s' "$rc" "$(wc -l < "$cnt" | tr -d ' ')"
}
check "apt-mark: a hold that meets the dpkg lock is retried until it succeeds" eqv "$(am_case 2 0)" "0 3"
check "apt-mark: a lock that never clears gives up after the retries" eqv "$(am_case 9 0)" "1 5"
check "apt-mark: any other error is not retried" eqv "$(am_case 0 1)" "1 1"
migrate_php_undivert_cli 8.3 >/dev/null 2>&1
check "cron: the rollback removes our link and renames Sury's CLI back" eqv "$(cat "$TROOT/usr/bin/php8.3")" sury-binary
check "cron: the rollback drops the diversion" eqv "$(cat "$STUBD/diversions")" ""
check "cron: the rollback clears the record" eqv "$(st php-8.3.divert)" ""
# After the purge the package took its copy: only the record goes.
migrate_php_divert_cli 8.3 >/dev/null 2>&1
rm -f "$TROOT/usr/bin/php8.3.sury"
: > "$TCALLS"; migrate_php_undivert_cli 8.3 after-purge >/dev/null 2>&1
check "cron: after the purge the diversion is removed without a rename" called "dpkg-divert --local --remove $TROOT/usr/bin/php8.3"
check "cron: after the purge our link stays" eqv "$(readlink "$TROOT/usr/bin/php8.3")" "$cli"
# A path no package owns (no Sury CLI) is left to the links.
fresh
cli=$(migrate_php_cli_bin 8.3); mkexe "$cli" "$TPL/php"
migrate_php_divert_cli 8.3 >/dev/null 2>&1
check "cron: no package CLI, no diversion" not_called "dpkg-divert --local"


# Leftover Angie references (1.22.3): checkouts of this script and of its
# configuration repository are not reported.
fresh
c="$TROOT/root/work/ubuntu-setup-script"; mkdir -p "$c/lib" "$c/tests/unit" "$TROOT/root/scn/h5bp" "$TROOT/root/scn/http.d" "$TROOT/root/tools"
: > "$c/setup.sh"; : > "$c/lib/migrate.sh"
check "leftovers: a file in a setup.sh checkout is skipped" migrate_in_setup_checkout "$c/tests/unit/t.sh"
check "leftovers: a file in a server-configs-nginx checkout is skipped" migrate_in_setup_checkout "$TROOT/root/scn/http.d/a.conf"
check "leftovers: an operator script is reported" not migrate_in_setup_checkout "$TROOT/root/tools/reload.sh"
mkdir -p "$T_ANGIE/h5bp" "$T_ANGIE/http.d"
check "leftovers: the live Angie tree itself is not a checkout" not migrate_in_setup_checkout "$T_ANGIE/http.d/x.conf"


# An nginx-only front proxy keeps local_php with nothing behind it: no
# warning (1.22.3); with a PHP-FPM running the dead listener is reported.
fresh
mkdir -p "$T_ANGIE"
printf 'http {\n  upstream local_php {\n    server unix:%s/run/none.sock;\n  }\n}\n' "$TROOT" > "$T_ANGIE/angie.conf"
out=$( ( nginx_local_php_follow_pool() { :; }; migrate_pin_local_php ) 2>&1 )
check "local_php: a host without PHP gets no dead-listener warning" lacks "$out" "does not accept connections"
pkgs "ii php8.3-fpm"
active php8.3-fpm
out=$( ( nginx_local_php_follow_pool() { :; }; migrate_pin_local_php ) 2>&1 )
check "local_php: with PHP-FPM running a dead listener is warned about" has "$out" "does not accept connections"


# A PECL extension past its series ceiling (1.22.3): redis on PHP 8.6 is
# unbuildable, so an application that needs it refuses the version in the
# pre-flight instead of a build that fails on every run.
fresh
printf '8.6\n' > "$STUBD/php-newest"; MIGRATE_SERIES_OK=()
pkgs "ii php8.6-fpm"
active php8.6-fpm
mkdir -p "$T_PHPETC/8.6/fpm/pool.d"
printf '[www]\nlisten = /run/php/php-fpm.sock\n' > "$T_PHPETC/8.6/fpm/pool.d/www.conf"
out=$( (
  migrate_preflight_disk() { :; }
  migrate_php_app_required_exts() { printf 'redis\n'; }
  migrate_preflight 0; echo "todo=[${MIGRATE_PHP_TODO[*]}]"
) 2>&1 )
check "ceiling: redis on PHP 8.6 counts as unbuildable" has "$(migrate_php_ext_union 8.6)" "unbuildable redis"
check "ceiling: an app that needs redis refuses PHP 8.6 in the pre-flight" eqv "$(st php-8.6)" "refused:unbuildable redis"
check "ceiling: nothing is queued" has "$out" "todo=[]"
check "ceiling: the refusal says redis has no PHP 8.6 release yet" has "$out" "redis has no release that builds for PHP 8.6 yet (up to 8.5)"
check "ceiling: redis on PHP 8.5 is kept" has "$(migrate_php_ext_union 8.5)" "keep redis"
d1=$(migrate_state_get php-8.6.scan)
check "ceiling: an application that stops needing redis changes the scan (the refusal retries)" \
  not eqv "$( migrate_php_app_required_exts() { :; }; migrate_php_scan_digest 8.6 )" "$d1"

# Disk
disk_probe() (
  MIGRATE_DO_NGINX=1; MIGRATE_PHP_TODO=(8.3); MIGRATE_DO_VALKEY=1
  migrate_preflight_disk "${1:-0}"
  echo "do_nginx=$MIGRATE_DO_NGINX do_valkey=$MIGRATE_DO_VALKEY todo=[${MIGRATE_PHP_TODO[*]}]"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
)
fresh
out=$(disk_probe 2>&1)
check "disk: ample space keeps every part" has "$out" "do_nginx=1 do_valkey=1 todo=[8.3]"
fresh
printf '104857600 1048576\n' > "$STUBD/df.root"
out=$(disk_probe 2>&1)
check "disk: too little space postpones every part" has "$out" "do_nginx=0 do_valkey=0 todo=[]"
check "disk: nginx is postponed:disk" eqv "$(st nginx)" "postponed:disk"
check "disk: PHP is postponed:disk" eqv "$(st php-8.3)" "postponed:disk"
check "disk: Valkey is postponed:disk" eqv "$(st valkey)" "postponed:disk"
check "disk: the report says the current services keep serving" has "$out" "every part postponed, the current services keep serving"
fresh
printf '104857600 1048576\n' > "$STUBD/df.root"
out=$(disk_probe 1 2>&1)
check "disk (dry run): the plan says NOT ENOUGH" has "$out" "disk: NOT ENOUGH"
check "disk (dry run): no part state is written" eqv "$(st nginx)" ""
fresh
printf '10485760 1024\n' > "$STUBD/df.backup"
out=$(disk_probe 2>&1)
check "disk: a full backup mount postpones Valkey (the biggest snapshot) first" has "$out" "do_nginx=1 do_valkey=0 todo=[8.3]"
check "disk: Valkey is the part recorded as postponed" eqv "$(st valkey)|$(st nginx)" "postponed:disk|"

# ---------------------------------------------------------------------------
# Steps 5-7: the /etc/nginx render (path map, operator files, fit marker)
# ---------------------------------------------------------------------------
fresh
A=$T_ANGIE
N=$T_NGINX
mkdir -p "$A/conf.d" "$A/http.d" "$A/modules-enabled" "$A/scripts" "$A/htpasswd" "$A/ssl/site" "$A/snippets"
printf 'user angie;\n' > "$A/angie.conf"
printf 'types {}\n' > "$A/mime.types"
printf 'fastcgi_param X y;\n' > "$A/fastcgi_params"
printf 'server { listen 80 default_server; }\n' > "$A/http.d/default.conf"
printf 'load_module x.so;\n' > "$A/modules-enabled/50-mod.conf"
printf '#!/bin/sh\n' > "$A/scripts/cloudflare.sh"
printf 'old\n' > "$A/conf.d/site.conf.dpkg-old"
printf '%s\n' 'server {' \
  '    server_name site.example.test;' \
  '    access_log /var/www/logs/angie/site.access.log;' \
  '    include /etc/angie/snippets/common.conf;' \
  '    root /usr/share/angie/html;' \
  '    proxy_cache_path /var/cache/angie/site levels=1:2 keys_zone=s:10m;' \
  '    # setup-angie-build-off: sub_filter a b;' \
  '    pid /run/angie.pid;' \
  '}' > "$A/conf.d/site.conf"
printf 'user angie angie;\n' > "$A/conf.d/user.conf"
printf 'angie version\n' > "$A/conf.d/existing.conf"
printf 'add_header X-Common 1;\n' > "$A/snippets/common.conf"
printf 'admin:$apr1$stub$hash\n' > "$A/htpasswd/admin"
chmod 640 "$A/htpasswd/admin"
printf 'key text naming /etc/angie/ssl\n' > "$A/ssl/site/privkey.pem"
chmod 600 "$A/ssl/site/privkey.pem"
printf 'set_real_ip_from 192.0.2.0/24;\n' > "$A/http.d/cloudflare.conf"
ln -s "$A/snippets/common.conf" "$A/conf.d/link.conf"
ln -s ../snippets/common.conf "$A/conf.d/rel.conf"
mkdir -p "$N/conf.d" "$N/htpasswd" "$N/http.d"
printf 'rendered\n' > "$N/conf.d/existing.conf"
printf 'placeholder\n' > "$N/htpasswd/admin"
printf 'scn cloudflare\n' > "$N/http.d/cloudflare.conf"
cp -a "$A/conf.d/site.conf" "$TMP/site.conf.orig"
out=$( ( migrate_copy_operator_files; echo "rc=$?"; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
site=$(cat "$N/conf.d/site.conf" 2>/dev/null)
check "render: the copy succeeds" has "$out" "rc=0"
check "render: /etc/angie/ paths map to /etc/nginx/" has "$site" "include /etc/nginx/snippets/common.conf;"
check "render: the Angie log directory maps to the nginx one" has "$site" "/var/www/logs/nginx/site.access.log"
check "render: the Angie cache directory maps to the nginx one" has "$site" "/var/cache/nginx/site "
check "render: the Angie html root maps to the nginx build's" has "$site" "root $(migrate_nginx_root)/html;"
check "render: the Angie pid file maps to /run/nginx.pid" has "$site" "pid /run/nginx.pid;"
check "render: no Angie path is left in a copied file" lacks "$site" "angie"
check "render: the 1.21 fit marker is undone in the copy (directive live again)" \
  grep -qx '    sub_filter a b;' "$N/conf.d/site.conf"
check "render: the operator's /etc/angie is left untouched" cmp -s "$A/conf.d/site.conf" "$TMP/site.conf.orig"
check "render: user angie becomes user www-data" eqv "$(cat "$N/conf.d/user.conf")" "user www-data;"
check "render: a file the SCN render created is not overwritten" eqv "$(cat "$N/conf.d/existing.conf")" rendered
check "render: password files always come from Angie" eqv "$(cat "$N/htpasswd/admin")" 'admin:$apr1$stub$hash'
check "render: a password file keeps its mode (640)" eqv "$(stat -c %a "$N/htpasswd/admin")" 640
check "render: a key keeps its mode (600)" eqv "$(stat -c %a "$N/ssl/site/privkey.pem")" 600
check "render: certificates and keys are copied byte for byte (no path map)" \
  cmp -s "$A/ssl/site/privkey.pem" "$N/ssl/site/privkey.pem"
check "render: the Cloudflare real-IP list always comes from Angie" eqv "$(cat "$N/http.d/cloudflare.conf")" "set_real_ip_from 192.0.2.0/24;"
check "render: an absolute symlink into /etc/angie is re-pointed into /etc/nginx" \
  eqv "$(readlink "$N/conf.d/link.conf")" "$N/snippets/common.conf"
check "render: a relative symlink is kept as it is" eqv "$(readlink "$N/conf.d/rel.conf")" "../snippets/common.conf"
check "render: angie.conf is not copied" not test -e "$N/angie.conf"
check "render: package files (mime.types, fastcgi_params) are not copied" not test -e "$N/mime.types"
check "render: Angie's default vhost is not copied" not test -e "$N/http.d/default.conf"
check "render: Angie module includes are not copied" not test -e "$N/modules-enabled/50-mod.conf"
check "render: the Angie cloudflare.sh is not copied" not test -e "$N/scripts/cloudflare.sh"
check "render: dpkg leftovers are not copied" not test -e "$N/conf.d/site.conf.dpkg-old"
check "render: the report counts the copied operator files" has "$out" "operator files copied from /etc/angie:"

# The fit on the rendered tree: the live-again droppable directive is
# commented with the nginx marker; an unbuilt one stops the part.
mkexe "$(migrate_nginx_root)/staging/sbin/nginx" "$TPL/nginx"
cand=$(migrate_nginx_bin)
printf 'events {}\n' > "$N/nginx.conf"
printf 'sub_filter\n' > "$STUBD/nginx-unknown"
fit=$(migrate_nginx_fit "$N/nginx.conf" "$cand" 2>/dev/null); rc=$?
check "fit: the rendered tree passes after the fit" eqv "$rc" 0
check "fit: the fit reports file:line and directive" eqv "$fit" "conf.d/site.conf:7 sub_filter"
check "fit: the directive is commented with the nginx marker" \
  grep -qx '    # setup-nginx-build-off: sub_filter a b;' "$N/conf.d/site.conf"
printf '        auth_request /auth;\n' >> "$N/conf.d/user.conf"
printf 'auth_request\n' > "$STUBD/nginx-unknown"
err=$(migrate_nginx_fit "$N/nginx.conf" "$cand" 2>&1 >/dev/null); rc=$?
check "fit: an unbuilt (non-droppable) directive cannot be commented" eqv "$rc" 1
check "fit: the nginx error names the directive" has "$err" 'unknown directive "auth_request"'
check "fit: the unbuilt directive is left as it was" grep -qx '        auth_request /auth;' "$N/conf.d/user.conf"
out=$( ( migrate_nginx_fit_report $'conf.d/a.conf:3 limit_conn\nconf.d/a.conf:4 sub_filter'; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "fit report: a commented limit_conn is a security warning" \
  has "$out" "**WARNING** commented conf.d/a.conf:3 limit_conn: security control removed"
check "fit report: another commented directive is a note" has "$out" "commented conf.d/a.conf:4 sub_filter (module not built)"

# The trial of the Angie tree before anything is purged or rendered.
fresh
mkdir -p "$T_ANGIE/conf.d"
printf 'events {}\nhttp { include conf.d/*.conf; }\n' > "$T_ANGIE/angie.conf"
printf 'server {\n    server_name t.example.test;\n    # setup-angie-build-off: sub_filter a b;\n}\n' > "$T_ANGIE/conf.d/t.conf"
mkexe "$(migrate_nginx_root)/staging/sbin/nginx" "$TPL/nginx"
cand=$(migrate_nginx_bin)
printf 'sub_filter\n' > "$STUBD/nginx-unknown"
out=$(migrate_nginx_trial "$cand" 2>&1); rc=$?
check "trial: a droppable directive alone does not block" eqv "$rc" 0
check "trial: the operator's tree is not changed by the trial" \
  grep -qx '    # setup-angie-build-off: sub_filter a b;' "$T_ANGIE/conf.d/t.conf"
printf '    auth_request /auth;\n' >> "$T_ANGIE/conf.d/t.conf"
printf 'auth_request\nsub_filter\n' > "$STUBD/nginx-unknown"
out=$(migrate_nginx_trial "$cand" 2>/dev/null); rc=$?
check "trial: an unknown unbuilt directive is a real blocker" eqv "$rc" 1
check "trial: the blocker names the directive" has "$out" 'unknown directive "auth_request"'
check "trial: the blocker names the file relative to the tree" has "$out" "in conf.d/t.conf:"
check "trial: the private copy's path is not shown" lacks "$out" "/tmp/nginx-trial."

# ---------------------------------------------------------------------------
# Step 6: ACME -> the host self-signed pair
# ---------------------------------------------------------------------------
fresh
mkdir -p "$T_NGINX/conf.d" "$T_NGINX/http.d"
F=$T_NGINX/conf.d/acme.conf
printf '%s\n' 'acme_client le' \
  '    https://acme.example.test/directory;' \
  'server {' \
  '    listen 443 ssl;' \
  '    server_name a.example.test www.a.example.test;' \
  '    acme le;' \
  '    ssl_certificate $acme_cert_le;' \
  '    ssl_certificate_key $acme_cert_key_le;' \
  '    include snippets/ocsp_stapling.conf;' \
  '    add_header Strict-Transport-Security "max-age=63072000" always;' \
  '}' \
  'server {' \
  '    listen 443 ssl;' \
  '    server_name b.example.test;' \
  '    ssl_certificate /etc/nginx/ssl/b/fullchain.pem;' \
  '    ssl_certificate_key /etc/nginx/ssl/b/privkey.pem;' \
  '    include snippets/ocsp_stapling.conf;' \
  '}' > "$F"
cp -a "$F" "$TMP/acme.conf.orig"
rep="$TMP/acme.rep"
: > "$rep"
migrate_acme_rewrite_file "$F" "$rep"; rc=$?
body=$(cat "$F")
OFF=$MIGRATE_ACME_OFF
check "acme: the rewrite succeeds" eqv "$rc" 0
check "acme: a multi-line acme_client is commented on every line" \
  eqv "$(sed -n 1,2p "$F" | paste -sd'|' -)" "${OFF}acme_client le|${OFF}    https://acme.example.test/directory;"
check "acme: the acme directive in the server block is commented" grep -qxF "${OFF}    acme le;" "$F"
check "acme: \$acme_cert_* becomes the host self-signed certificate" grep -qxF "    ssl_certificate $CF_TLS_DEFAULT_CERT;" "$F"
check "acme: \$acme_cert_key_* becomes the host self-signed key" grep -qxF "    ssl_certificate_key $CF_TLS_DEFAULT_KEY;" "$F"
check "acme: the OCSP include of an ACME block is commented" grep -qxF "${OFF}    include snippets/ocsp_stapling.conf;" "$F"
check "acme: a non-ACME block keeps its OCSP include" eqv "$(grep -cxF '    include snippets/ocsp_stapling.conf;' "$F")" 1
check "acme: a non-ACME block keeps its own certificate" grep -qxF '    ssl_certificate /etc/nginx/ssl/b/fullchain.pem;' "$F"
check "acme: no live \$acme_cert reference is left" not grep -qE '^[^#]*\$acme_cert' "$F"
check "acme: exactly the four ACME lines are commented" eqv "$(grep -c "^${OFF}" "$F")" 4
check "acme: the changed block is reported with its names" \
  grep -qxF "$F"$'\t'"a.example.test www.a.example.test" "$rep"
check "acme: the untouched block is not reported" not grep -q 'b.example.test' "$rep"
cp -a "$F" "$TMP/acme.once"
migrate_acme_rewrite_file "$F" "$rep"; rc=$?
check "acme: a second pass is a no-op" cmp -s "$F" "$TMP/acme.once"
check "acme: an unchanged file is not an error" eqv "$rc" 0

fresh
mkdir -p "$T_NGINX/conf.d" "$T_NGINX/http.d"
cp -a "$TMP/acme.conf.orig" "$T_NGINX/conf.d/acme.conf"
printf '%s\n' 'server {' '    listen 443 ssl;' '    server_name c.example.test;' \
  '    ssl_certificate $acme_cert_le;' '    ssl_certificate_key $acme_cert_key_le;' '}' > "$T_NGINX/conf.d/c.conf"
printf 'c.example.test\n' > "$STUBD/cf-names"
out=$( ( migrate_acme_to_self_signed; echo "rc=$?"; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "acme tree: the migration succeeds" has "$out" "rc=0"
check "acme tree: every vhost file is rewritten" not grep -rqsE '^[^#]*\$acme_cert' "$T_NGINX"
check "acme tree: the original file is kept in the run snapshot" \
  bash -c 'f=$(find "$1" -path "*/acme/conf.d_acme.conf" -print -quit); [[ -n $f ]] && grep -q "acme_cert_le" "$f"' _ "$MIGRATE_BACKUP_ROOT"
check "acme tree: a vhost not proved behind Cloudflare gets the warning block" \
  has "$out" "**WARNING: ACME vhosts moved to the self-signed certificate that may not be behind Cloudflare**"
check "acme tree: the warning names the vhost and its names" has "$out" "conf.d/acme.conf (a.example.test www.a.example.test):"
check "acme tree: an HSTS vhost is called out" has "$out" "sends HSTS, so visitors cannot click through a certificate error"
check "acme tree: a vhost behind Cloudflare is a note only" has "$out" "ACME -> self-signed: conf.d/c.conf (c.example.test; behind Cloudflare)"

fresh
mkdir -p "$T_NGINX/conf.d"
printf 'map $host $cert_for_host { default $acme_cert_le; }\n' > "$T_NGINX/conf.d/map.conf"
out=$( ( migrate_acme_to_self_signed; echo "rc=$?"; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "acme tree: an \$acme_cert_* outside ssl_certificate aborts the nginx part" has "$out" "rc=1"
check "acme tree: the abort names the reason" has "$out" "used outside ssl_certificate(_key); nginx part aborted"

# ---------------------------------------------------------------------------
# Step 8: nginx cutover and its rollback order
# ---------------------------------------------------------------------------
cutover_fixture() {
  fresh
  mkdir -p "$T_ANGIE/conf.d" "$T_NGINX"
  printf 'events {}\nhttp { include conf.d/*.conf; }\n' > "$T_ANGIE/angie.conf"
  printf 'server {\n    listen 80;\n    server_name site.example.test;\n    root /var/www/site;\n}\n' > "$T_ANGIE/conf.d/site.conf"
  printf 'events {}\n' > "$T_NGINX/nginx.conf"
  pkgs "ii angie"
  active angie
  enabled angie enabled
}
cutover_run() (
  nginx_build_ensure() { rec "nginx_build_ensure $*"; return 0; }
  migrate_nginx_cutover
  echo "rc=$?"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
)
cutover_fixture
printf 'nginx\n' > "$STUBD/fail-start"
out=$(cutover_run 2>&1)
check "cutover: an nginx that does not start fails the part" has "$out" "rc=1"
check "cutover: Angie stops and is masked before the nginx build is activated" \
  in_order "systemctl stop angie.service" "systemctl mask angie.service" "nginx_build_ensure activate migrate migrate_out" \
           "systemctl enable nginx.service" "systemctl start nginx.service"
check "cutover rollback: nginx down first, then Angie unmasked, enabled and started" \
  in_order "systemctl start nginx.service" "systemctl stop nginx.service" "systemctl disable nginx.service" \
           "systemctl unmask angie.service" "systemctl enable angie.service" "systemctl reset-failed angie.service" \
           "systemctl start angie.service"
check "cutover rollback: Angie serves again" grep -qxF angie "$STUBD/active"
check "cutover rollback: the part is rolled-back with the reason" eqv "$(st nginx)" "rolled-back:nginx did not start"
check "cutover rollback: inflight is cleared" eqv "$(st inflight)" ""
check "cutover rollback: the rendered /etc/nginx leaves the live path" not test -e "$T_NGINX"
check "cutover rollback: the rendered tree is kept in the backups" in_backups "$T_NGINX/nginx.conf"
check "cutover rollback: the report says it rolled back to Angie" has "$out" "nginx cutover rolled back to Angie: nginx did not start"

cutover_fixture
printf '#!/bin/sh\ntouch "$STUB_DIR/nginx-up"\n' > "$STUBD/hook.start.nginx"
chmod 755 "$STUBD/hook.start.nginx"
printf '502\n' > "$STUBD/http-code-after"
out=$(cutover_run 2>&1)
check "cutover: a vhost answering differently than under Angie rolls back" has "$(st nginx)" "rolled-back:vhosts answer differently than under Angie"
check "cutover: the mismatch names the vhost and both codes" has "$(st nginx)" "http://site.example.test/ was 200, now 502"
check "cutover: the baseline was recorded before Angie stopped" \
  in_order "curl " "systemctl stop angie.service"
check "cutover: Angie is started again after a failed verification" in_order "systemctl stop nginx.service" "systemctl start angie.service"

cutover_fixture
out=$(cutover_run 2>&1)
check "cutover: a verified switch is done" eqv "$(st nginx)" "done"
check "cutover: inflight is cleared after the verified switch" eqv "$(st inflight)" ""
check "cutover: cron is handed over after the verified start" in_order "systemctl start nginx.service" "cron_handover"
check "cutover: Angie stays masked until the purge" not_called "systemctl unmask angie.service"
check "cutover: the web server state reads nginx" eqv "$(web_server_state)" nginx

# ---------------------------------------------------------------------------
# Step 9: PHP unit handover (stop before the unit write) and rollback
# ---------------------------------------------------------------------------
php_fixture() {
  fresh
  local pe=$T_PHPETC/8.3
  mkdir -p "$pe/fpm/pool.d" "$pe/fpm/conf.d" "$pe/cli/conf.d" "$pe/mods-available" "$T_NGINX/conf.d" \
    "$T_UNITS/php8.3-fpm.service.d"
  printf '[www]\nuser = www-data\nlisten = 127.0.0.1:9083\n' > "$pe/fpm/pool.d/www.conf"
  printf 'zend_extension=opcache.so\n' > "$pe/mods-available/opcache.ini"
  ln -s /etc/php/8.3/mods-available/opcache.ini "$pe/fpm/conf.d/10-opcache.ini"
  printf 'extension=redis.so\nmemory_limit = 256M\n' > "$pe/fpm/conf.d/99-operator.ini"
  printf 'extension=pdo.so\n' > "$pe/cli/conf.d/20-pkg.ini"
  printf '%s\n' "$pe/cli/conf.d/20-pkg.ini" > "$STUBD/dpkg-owned"
  printf '[Service]\nExecStart=\nExecStart=/usr/local/lib/setup-php/8.3/php-fpm\n' > "$T_UNITS/php8.3-fpm.service.d/zz-setup-build.conf"
  printf '[Service]\nLimitNOFILE=65535\n' > "$T_UNITS/php8.3-fpm.service.d/override.conf"
  pkgs "ii php8.3-fpm" "ii php8.3-cli"
  active php8.3-fpm
  enabled php8.3-fpm enabled
  migrate_state_set nginx "done"
  mkexe "$(migrate_php_cli_bin 8.3)" "$TPL/php"
  printf '8.3\n' > "$STUBD/php-primary"
}
php_cutover_run() (
  php_build_ensure() {
    rec "php_build_ensure $*"
    [[ -e $T_UNITS/php8.3-fpm.service.d/zz-setup-build.conf ]] && rec "at-ensure: legacy drop-in present"
    [[ -L $T_PHPETC/8.3/fpm/conf.d/10-opcache.ini ]] && rec "at-ensure: sury conf.d symlink present"
    grep -qxF php8.3-fpm "$STUBD/active" && rec "at-ensure: package unit running"
    grep -qxF '; setup-1.22-off: extension=redis.so' "$T_PHPETC/8.3/fpm/conf.d/99-operator.ini" \
      && rec "at-ensure: operator ini commented"
    printf '[Service]\nExecStart=%s\n' "$(migrate_php_active_bin 8.3)" > "$(migrate_unit_file php8.3-fpm)"
    rec "unit written"
    return 0
  }
  migrate_php_cutover 8.3
  echo "rc=$?"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
)
# migrate_php_cutover stashes a live /run/php/php-fpm.sock symlink and a
# 1.21 /run/setup-php-build/X.Y state directory; never on a host that has them.
if [[ -L /run/php/php-fpm.sock || -e /run/setup-php-build/8.3 ]]; then
  t_skip "PHP cutover: this host has /run/php/php-fpm.sock or /run/setup-php-build/8.3"
else
  php_fixture
  touch "$STUBD/php-fpm-test-fail"
  out=$(php_cutover_run 2>&1)
  PE=$T_PHPETC/8.3
  check "php cutover: a failed php-fpm -t fails the version" has "$out" "rc=1"
  check "php handover: the package unit stops before our unit file is written" \
    in_order "systemctl stop php8.3-fpm" "php_build_ensure 8.3 activate migrate migrate_out" "unit written"
  check "php handover: the package unit is not running when our build is activated" not_called "at-ensure: package unit running"
  check "php handover: the 1.21 drop-in is out before activation" not_called "at-ensure: legacy drop-in present"
  check "php handover: Sury's conf.d symlinks are out before activation" not_called "at-ensure: sury conf.d symlink present"
  check "php handover: operator .ini extension lines are commented before activation" called "at-ensure: operator ini commented"
  check "php handover: reload, reenable and start follow the layout" \
    in_order "unit written" "php_build_layout 8.3 adopt" "systemctl daemon-reload" "systemctl reenable php8.3-fpm" \
             "systemctl start php8.3-fpm" "php_fpm_test 8.3"
  check "php rollback: ours stops, then reload, reset-failed, reenable, start, FragmentPath check" \
    in_order "php_fpm_test 8.3" "systemctl stop php8.3-fpm" "systemctl daemon-reload" "systemctl reset-failed php8.3-fpm" \
             "systemctl reenable php8.3-fpm" "systemctl start php8.3-fpm" "systemctl show -p FragmentPath --value php8.3-fpm"
  check "php rollback: the package FragmentPath raises no warning" lacks "$out" "FragmentPath is"
  check "php rollback: our unit file leaves the unit directory" not test -e "$T_UNITS/php8.3-fpm.service"
  check "php rollback: our unit file is kept in the snapshot" in_backups "/ours$T_UNITS/php8.3-fpm.service"
  check "php rollback: the operator drop-in comes back" test -f "$T_UNITS/php8.3-fpm.service.d/override.conf"
  check "php rollback: the 1.21 drop-in is not restored (its tool is retired)" \
    not test -e "$T_UNITS/php8.3-fpm.service.d/zz-setup-build.conf"
  check "php rollback: /etc/php/8.3 is restored exactly (operator .ini)" \
    eqv "$(paste -sd'|' "$PE/fpm/conf.d/99-operator.ini")" "extension=redis.so|memory_limit = 256M"
  check "php rollback: Sury's conf.d symlink is back" eqv "$(readlink "$PE/fpm/conf.d/10-opcache.ini")" /etc/php/8.3/mods-available/opcache.ini
  check "php rollback: the dpkg-owned CLI .ini is back" test -f "$PE/cli/conf.d/20-pkg.ini"
  check "php rollback: the package unit serves again" grep -qxF php8.3-fpm "$STUBD/active"
  check "php rollback: the version is failed with the reason" has "$(st php-8.3)" "failed:php-fpm -t: ERROR: stub failure"
  check "php rollback: inflight is cleared" eqv "$(st inflight)" ""
  check "php rollback: the scan digest is recorded" test -n "$(st php-8.3.scan)"
  check "php rollback: the report says Sury is not purged" has "$out" "PHP 8.3 rolled back to the Sury package"

  # A rollback that leaves the unit resolving to our file is reported.
  printf '%s\n' "$T_UNITS/php8.3-fpm.service" > "$STUBD/show.FragmentPath.php8.3-fpm"
  out=$( ( migrate_php_rollback 8.3 "test" ) 2>&1 )
  check "php rollback: a FragmentPath outside /lib and /usr/lib is warned about" \
    has "$out" "php8.3-fpm FragmentPath is $T_UNITS/php8.3-fpm.service after the rollback"

  # The verified switch.  The master check reads /proc/PID/exe, so a copy of
  # sleep(1) runs as "our" php-fpm.
  php_fixture
  master="$(migrate_php_root)/8.3/sbin/php-fpm"
  mkdir -p "$(dirname "$master")"
  cp -- "$(type -P sleep)" "$master" && chmod 755 "$master"
  "$master" 120 &
  mpid=$!
  if [[ $(readlink -f "/proc/$mpid/exe" 2>/dev/null) == "$master" ]]; then
    printf '%s\n' "$mpid" > "$STUBD/show.MainPID.php8.3-fpm"
    printf '%s\n/usr/bin/php8.3\n' "$(migrate_php_cli_bin 8.3)" > "$STUBD/alternatives"
    out=$(php_cutover_run 2>&1)
    check "php cutover: a verified switch is done" has "$out" "rc=0"
    check "php cutover: the version is recorded as done" eqv "$(st php-8.3)" "done"
    check "php cutover: inflight is cleared" eqv "$(st inflight)" ""
    check "php cutover: the listener is probed" called "curl -s -o /dev/null --max-time 3 http://127.0.0.1:9083/"
    check "php cutover: an alternatives entry of ours is removed" \
      called "update-alternatives --remove php $(migrate_php_cli_bin 8.3)"
    check "php cutover: a package alternatives entry is left to dpkg" not_called "update-alternatives --remove php /usr/bin/php8.3"
    check "php cutover: no alternatives entry is registered" not_called "update-alternatives --install"
    check "php cutover: the converted /etc/php is kept for the post-purge re-lay" \
      test -f "$(st php-8.3.converted)/etc/fpm/pool.d/www.conf"
    check "php cutover: the active-version marker is written at the cutover" called "php_active_set 8.3"
    check "php cutover: the drop-in of 1.21 is in the snapshot" in_backups "/live$T_UNITS/php8.3-fpm.service.d/zz-setup-build.conf"
  else
    t_skip "php cutover success path: a copied sleep(1) cannot stand in for php-fpm on this host"
  fi
  kill "$mpid" 2>/dev/null
  wait "$mpid" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Step 10: Valkey: the package server stops before the snapshot
# ---------------------------------------------------------------------------
vk_fixture() {
  fresh
  mkdir -p "$MIGRATE_VALKEY_ETC" "$MIGRATE_VALKEY_DATA"
  printf 'port 6379\nsave 3600 1\nappendonly no\n' > "$MIGRATE_VALKEY_ETC/valkey.conf"
  printf 'before-stop\n' > "$MIGRATE_VALKEY_DATA/dump.rdb"
  ln -s /lib/systemd/system/valkey-server.service "$T_UNITS/valkey.service"
  mkexe "$(migrate_valkey_cli)" "$TPL/valkey"
  # The package server writes its RDB when it stops (once).
  printf '#!/bin/sh\nprintf "saved-at-stop\\n" > "$SETUP_MIGRATE_VALKEY_DATA/dump.rdb"\nrm -f "$0"\n' > "$STUBD/hook.stop.valkey-server"
  chmod 755 "$STUBD/hook.stop.valkey-server"
  pkgs "ii valkey-server" "ii valkey-tools"
  active valkey-server
  enabled valkey-server enabled
}
vk_run() (
  valkey_build_ensure() {
    rec "valkey_build_ensure $*"
    grep -qxF valkey-server "$STUBD/active" && rec "at-ensure: package server running"
    printf 'new-format\n' > "$MIGRATE_VALKEY_DATA/dump.rdb"
    printf '[Service]\n' > "$(migrate_unit_file valkey-server)"
    return 1
  }
  migrate_valkey_cutover
  echo "rc=$?"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
)
vk_fixture
out=$(vk_run 2>&1)
vsnap=$(st valkey.snap)
check "valkey: the persistence is asked while the package server runs" \
  in_order "valkey-cli[$TBIN/valkey-cli] -h 127.0.0.1 -p 6379 CONFIG GET save" "systemctl stop valkey-server"
check "valkey: the package server stops before our build is activated" \
  in_order "systemctl is-enabled valkey-server" "systemctl stop valkey-server" "valkey_build_ensure activate migrate migrate_out"
check "valkey: nothing of the package server runs at activation" not_called "at-ensure: package server running"
check "valkey: the dataset snapshot is taken after the stop (holds the RDB written at stop)" \
  eqv "$(cat "$vsnap/data/dump.rdb" 2>/dev/null)" saved-at-stop
check "valkey: the persistence verdict is kept in the snapshot" eqv "$(cat "$vsnap/persists" 2>/dev/null)" 1
check "valkey: the key count before the switch is kept" eqv "$(cat "$vsnap/dbsize" 2>/dev/null)" 5
check "valkey: the configuration is in the snapshot" test -f "$vsnap/etc/valkey.conf"
check "valkey rollback: ours shuts down WITHOUT saving, then the package order" \
  in_order "valkey_build_ensure" "valkey-cli[$(migrate_valkey_cli)] -h 127.0.0.1 -p 6379 SHUTDOWN NOSAVE" \
           "systemctl kill -s KILL valkey-server" "systemctl stop valkey-server" "systemctl daemon-reload" \
           "systemctl reset-failed valkey-server" "systemctl enable --now valkey-server" \
           "systemctl show -p FragmentPath --value valkey-server"
check "valkey rollback: the dataset comes back from the snapshot" eqv "$(cat "$MIGRATE_VALKEY_DATA/dump.rdb")" saved-at-stop
check "valkey rollback: our unit file is kept in the snapshot" in_backups "/ours$T_UNITS/valkey-server.service"
check "valkey rollback: our unit file leaves the unit directory" not test -e "$T_UNITS/valkey-server.service"
check "valkey rollback: the package alias valkey.service is restored" \
  eqv "$(readlink "$T_UNITS/valkey.service")" /lib/systemd/system/valkey-server.service
check "valkey rollback: the package server runs again" grep -qxF valkey-server "$STUBD/active"
check "valkey rollback: the part is failed with the reason" eqv "$(st valkey)" "failed:activating the Valkey build failed"
check "valkey rollback: inflight is cleared" eqv "$(st inflight)" ""
check "valkey: the switch reports a failure" has "$out" "rc=1"

vk_fixture
printf '104857600 1024\n' > "$STUBD/df.root"
out=$(vk_run 2>&1)
check "valkey: no room for the snapshot postpones Valkey" eqv "$(st valkey)" "postponed:disk"
check "valkey: the package server is started again at once" in_order "systemctl stop valkey-server" "systemctl start valkey-server"
check "valkey: nothing is activated without a snapshot" not_called "valkey_build_ensure"
check "valkey: no dataset is copied without room" \
  bash -c '[[ -z $(find "$1" -path "*/valkey-*/data" -print -quit) ]]' _ "$MIGRATE_BACKUP_ROOT"
check "valkey: inflight is cleared after the postponement" eqv "$(st inflight)" ""

# ---------------------------------------------------------------------------
# Step 11: exact purge lists, policy-rc.d, deferred Sury purge
# ---------------------------------------------------------------------------
fresh
pkgs "ii angie" "ii angie-module-brotli" "ii php8.3-fpm" "ii php8.3-cli" "ii php8.3-common" "ii php-common" \
     "rc php8.2-fpm" "ii libapache2-mod-php8.3" "ii phpmyadmin" "ii debsuryorg-archive-keyring" \
     "ii valkey-server" "ii valkey-tools" "ii nginx-common" "ii libnginx-mod-http-echo" \
     "ii python3-certbot-nginx" "ii mariadb-server"
check "lists: angie is angie and its modules, nothing else" \
  eqv "$(migrate_pkg_list angie | words)" "angie angie-module-brotli"
check "lists: sury is the PHP families plus the archive keyring (rc packages included)" \
  eqv "$(migrate_pkg_list sury | words)" "debsuryorg-archive-keyring php-common php8.2-fpm php8.3-cli php8.3-common php8.3-fpm"
check "lists: libapache2-mod-php is not in the Sury list (Apache may serve through it)" \
  lacks "$(migrate_pkg_list sury)" "libapache2-mod-php"
check "lists: phpmyadmin is not in the Sury list" lacks "$(migrate_pkg_list sury)" "phpmyadmin"
check "lists: valkey is valkey-server and valkey-tools" eqv "$(migrate_pkg_list valkey | words)" "valkey-server valkey-tools"
check "lists: distro nginx is its exact packages" \
  eqv "$(migrate_pkg_list distro-nginx | words)" "libnginx-mod-http-echo nginx-common python3-certbot-nginx"
check "lists: no list contains a glob" \
  not grep -qE '[*?[]' <<<"$(for k in angie sury valkey distro-nginx; do migrate_pkg_list "$k"; done)"

fresh
out=$( ( migrate_policy_install; echo "ours=$MIGRATE_POLICY_OURS" ) 2>&1 )
P=$MIGRATE_POLICY_RC
check "policy-rc.d: installed and marked ours" has "$out" "ours=1"
check "policy-rc.d: executable (755)" eqv "$(stat -c %a "$P")" 755
check "policy-rc.d: a /bin/sh script" eqv "$(head -n1 "$P")" "#!/bin/sh"
check "policy-rc.d: carries the setup.sh marker" grep -qF "$MIGRATE_POLICY_MARK" "$P"
check "policy-rc.d: recorded in the state" eqv "$(st policy-rc)" "$P"
for u in nginx nginx.service angie php8.3-fpm php8.3-fpm.service valkey-server valkey-server.service valkey; do
  sh "$P" "$u" >/dev/null 2>&1; rc=$?
  check "policy-rc.d denies ${u} (101)" eqv "$rc" 101
done
for u in mariadb ssh elasticsearch php8.3-cli cron; do
  sh "$P" "$u" >/dev/null 2>&1; rc=$?
  check "policy-rc.d allows ${u} (0)" eqv "$rc" 0
done
out=$( ( MIGRATE_POLICY_OURS=1; migrate_policy_remove; echo "ours=$MIGRATE_POLICY_OURS" ) 2>&1 )
check "policy-rc.d: removed after the removals" not test -e "$P"
check "policy-rc.d: the removed file is kept in the backups" in_backups "$P"
check "policy-rc.d: the state key is dropped" eqv "$(st policy-rc)" ""
fresh
printf '#!/bin/sh\nexit 101\n' > "$P"
cp -a "$P" "$TMP/policy.operator"
out=$( ( migrate_policy_install; migrate_policy_remove ) 2>&1 )
check "policy-rc.d: an operator policy is kept as it is" cmp -s "$P" "$TMP/policy.operator"
check "policy-rc.d: keeping an operator policy is reported" has "$out" "kept the existing $P (not ours)"

# The removal phase: exact lists under our policy-rc.d.
removals_fixture() {
  fresh
  pkgs "ii angie" "ii angie-module-brotli" "ii php8.3-fpm" "ii php8.3-cli" "ii php8.3-common" "ii php-common" \
       "rc php8.2-fpm" "ii libapache2-mod-php8.3" "ii phpmyadmin" "ii debsuryorg-archive-keyring" \
       "ii valkey-server" "ii valkey-tools" "ii mariadb-server"
  active php8.3-fpm
  migrate_state_set nginx "done"
  migrate_state_set php-8.3 "done"
  migrate_state_set valkey "done"
  local vs="$MIGRATE_BACKUP_ROOT/valkey-cutover"
  mkdir -p "$vs/etc" "$MIGRATE_VALKEY_ETC" "$T_ANGIE/http.d" "$T_PHPETC/8.3/fpm" "$T_NGINX/conf.d"
  printf 'port 6379\n' > "$vs/etc/valkey.conf"
  migrate_state_set valkey.snap "$vs"
  printf 'user angie;\n' > "$T_ANGIE/angie.conf"
}
removals_run() (
  migrate_post_assert() { rec "post_assert $*"; return 0; }
  migrate_removals
  echo "rc=$?"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
)
removals_fixture
out=$(removals_run 2>&1)
check "removals: the phase succeeds" has "$out" "rc=0"
check "removals: Angie is purged by its exact list under our policy-rc.d" \
  called "APT real purge: angie angie-module-brotli policy=yes"
check "removals: Sury is purged by its exact list under our policy-rc.d" \
  called "APT real purge: debsuryorg-archive-keyring php-common php8.2-fpm php8.3-cli php8.3-common php8.3-fpm policy=yes"
check "removals: valkey is removed, never purged (its postrm would delete the data)" \
  called "APT real remove: valkey-server valkey-tools policy=yes"
check "removals: no valkey purge" not_called "APT real purge: valkey"
check "removals: libapache2-mod-php and phpmyadmin are never in a removal" \
  not grep -qE '^APT .*(libapache2-mod-php|phpmyadmin)' "$TCALLS"
check "removals: no glob reaches apt" not grep -qE '^APT .*[*?]' "$TCALLS"
check "removals: unrelated packages stay installed" grep -qxF $'ii\tmariadb-server' "$STUBD/dpkg"
check "removals: Angie, then Sury, then Valkey, then the single verify pass" \
  in_order "APT real purge: angie" "APT real purge: debsuryorg-archive-keyring" "APT real remove: valkey-server" \
           "post_assert 8.3" "retire_sources 1 1"
check "removals: our policy-rc.d is gone after the removals" not test -e "$MIGRATE_POLICY_RC"
check "removals: /etc/angie is moved to the backups before the purge" not test -e "$T_ANGIE"
check "removals: the moved /etc/angie is complete in the backups" in_backups "$T_ANGIE/angie.conf"
check "removals: our valkey.conf (a package conffile) survives the remove" test -f "$MIGRATE_VALKEY_ETC/valkey.conf"
check "removals: the valkey user is re-asserted" called "valkey_user_ensure"
check "removals: the installed .debs are listed for a manual rollback" grep -qx 'php8.3-fpm=1.0-stub' "$(st debs)/manifest"
check "removals: a config-files package has no .deb to save" not grep -q '^php8.2-fpm=' "$(st debs)/manifest"
check "removals: the states are final" \
  eqv "$(st angie-purge)|$(st sury-purge)|$(st valkey-remove)|$(st removals)|$(st inflight)" "done|done|done|done|"
pin=$(sed -nE 's/^Package: //p' "$MIGRATE_APT_PIN" 2>/dev/null | tr ' ' '\n')
for t in nginx 'nginx-*' 'libnginx-mod-*' angie 'angie-*' 'php[0-9]*' 'php-*' 'libapache2-mod-php*' valkey-server valkey-tools; do
  check "apt pin: refuses ${t}" grep -qxF -- "$t" <<<"$pin"
done
check "apt pin: never the bare php* (it would refuse phpmyadmin)" not grep -qxF 'php*' <<<"$pin"
check "apt pin: priority -1" grep -qx 'Pin-Priority: -1' "$MIGRATE_APT_PIN"

fresh
printf 'Package: php* nginx\nPin: release *\nPin-Priority: -1\n' > "$MIGRATE_APT_PIN"
out=$( ( migrate_write_apt_pin 0 1 0 ) 2>&1 )
pin=$(sed -nE 's/^Package: //p' "$MIGRATE_APT_PIN" | tr ' ' '\n')
check "apt pin: an earlier bare php* is narrowed on rewrite" not grep -qxF 'php*' <<<"$pin"
check "apt pin: the rest of an earlier pin is kept" grep -qxF nginx <<<"$pin"
check "apt pin: the narrowed PHP families are written" grep -qxF 'php[0-9]*' <<<"$pin"

# Deferred Sury purge: collateral -> deferred, the packages held.
sury_fixture() {
  fresh
  pkgs "ii php8.3-fpm" "ii php8.3-cli" "ii php-common" "rc php8.2-fpm" "ii debsuryorg-archive-keyring" \
       "ii phpmyadmin" "ii libapache2-mod-php8.3"
}
sury_fixture
printf 'Remv phpmyadmin [5.2]\nRemv libapache2-mod-php8.3 [8.3]\n' > "$STUBD/apt-sim-extra-if.php-common"
out=$( ( migrate_sury_purge_preflight; echo "rc=$?"; echo "coll=${MIGRATE_SIM_COLLATERAL[*]}"; migrate_sury_defer ) 2>&1 )
check "defer: the Sury purge with collateral is refused" has "$out" "rc=1"
check "defer: libapache2-mod-php is reported as collateral" has "$out" "libapache2-mod-php8.3"
check "defer: the state records the deferral and its collateral" has "$(st sury-purge)" "deferred:"
check "defer: the deferral names phpmyadmin" has "$(st sury-purge)" "phpmyadmin"
check "defer: the installed Sury packages are held (rc packages are not)" \
  eqv "$(words < <(paste -sd' ' "$STUBD/held"))" "debsuryorg-archive-keyring php-common php8.3-cli php8.3-fpm"
check "defer: the holds of ours are recorded" \
  eqv "$(st sury-held | words)" "debsuryorg-archive-keyring php-common php8.3-cli php8.3-fpm"
check "defer: apt-mark hold is used" called "apt-mark hold "
check "defer: the operator is told how to proceed" has "$out" "Sury purge deferred"
rm -f "$STUBD/apt-sim-extra-if.php-common"
: > "$TCALLS"
out=$( ( migrate_sury_purge_preflight; echo "rc=$?"; migrate_sury_unhold; echo "unhold=$?" ) 2>&1 )
check "defer: once the collateral is gone the purge may run" has "$out" "rc=0"
check "defer: our own holds are simulated through" grep -qE '^apt-get -s purge .*--allow-change-held-packages' "$TCALLS"
check "defer: exactly our holds are undone before the purge" has "$out" "unhold=0"
check "defer: no hold is left" not test -s "$STUBD/held"
check "defer: the sury-held key is dropped" eqv "$(st sury-held)" ""

sury_fixture
printf 'php8.3-cli\n' > "$STUBD/held"
out=$( ( MIGRATE_SIM_COLLATERAL=(phpmyadmin); migrate_sury_defer ) 2>&1 )
check "defer: an operator's own hold is not recorded as ours" lacks " $(st sury-held) " " php8.3-cli "
check "defer: the other Sury packages are held by us" has " $(st sury-held) " " php8.3-fpm "
: > "$TCALLS"
out=$( ( migrate_sury_purge_preflight; echo "rc=$?"; echo "coll=${MIGRATE_SIM_COLLATERAL[*]}" ) 2>&1 )
check "defer: an operator hold is never simulated through" not grep -q 'allow-change-held-packages' "$TCALLS"
check "defer: the operator hold keeps the purge refused" has "$out" "coll=(apt refused the simulation)"

sury_fixture
active php8.3-fpm
migrate_state_set php-8.3 "done"
printf 'Remv phpmyadmin [5.2]\n' > "$STUBD/apt-sim-extra-if.php-common"
out=$(removals_run 2>&1)
check "removals: a Sury purge with collateral is deferred, not run" not_called "APT real purge"
check "removals: the deferral is recorded" has "$(st sury-purge)" "deferred:phpmyadmin"
check "removals: the deferred phase is still verified" called "post_assert 8.3"
check "removals: no policy-rc.d is written when nothing is removed" not test -e "$MIGRATE_POLICY_RC"

# ---------------------------------------------------------------------------
# Post-purge pass: re-lay, enable every unit, then assert it
# ---------------------------------------------------------------------------
pa_fixture() {
  fresh
  migrate_state_set nginx "done"
  migrate_state_set valkey "done"
  local u
  for u in nginx php8.3-fpm valkey-server; do
    printf '[Unit]\n' > "$T_UNITS/$u.service"
    enabled "$u" enabled
  done
  active valkey-server
  mkdir -p "$T_NGINX" "$T_PHPETC/8.3/fpm/conf.d" "$T_PHPETC/8.3/cli/conf.d"
  printf 'events {}\n' > "$T_NGINX/nginx.conf"
  mkexe "$(migrate_nginx_root)/sbin/nginx" "$TPL/nginx"
  mkexe "$(migrate_php_cli_bin 8.3)" "$TPL/php"
  mkexe "$(migrate_valkey_cli)" "$TPL/valkey"
  printf '8.3\n' > "$STUBD/php-primary"
}
pa_run() (
  migrate_php_probe() { rec "probe $1"; printf 'ok stub'; return 0; }
  MIGRATE_PA_ERRORS=()
  migrate_post_assert 8.3
  echo "rc=$?"
  printf 'PA %s\n' "${MIGRATE_PA_ERRORS[@]}"
)
# The post-purge pass also checks the host's /var/lib/php/sessions (a fixed
# path); its verdict is only asserted where that directory is absent or
# already as the pass requires.
sess_ok=1
if [[ -d /var/lib/php/sessions && $(stat -c '%U:%G %a' /var/lib/php/sessions 2>/dev/null) != 'www-data:www-data 700' ]]; then
  sess_ok=0
fi
pa_fixture
out=$(pa_run 2>&1)
check "post-assert: every unit is unmasked and enabled before any assertion" \
  in_order "systemctl unmask nginx.service" "systemctl enable nginx.service" "systemctl enable php8.3-fpm.service" \
           "systemctl enable valkey-server.service" "systemctl daemon-reload" "systemctl is-enabled nginx.service" \
           "systemctl is-enabled php8.3-fpm.service" "systemctl is-enabled valkey-server.service"
check "post-assert: the deb-systemd-helper state of each unit is cleared" in_order "clear_dsh nginx" "systemctl enable nginx.service"
check "post-assert: our /etc/php layout is re-laid first" in_order "php_build_layout 8.3 adopt" "systemctl enable nginx.service"
check "post-assert: a unit a maintainer script stopped is started again" \
  in_order "systemctl is-enabled valkey-server.service" "systemctl reset-failed nginx.service" "systemctl start nginx.service"
check "post-assert: PHP is tested, then restarted" in_order "php_fpm_test 8.3" "systemctl restart php8.3-fpm"
check "post-assert: /usr/bin/phpX.Y is linked once no package owns it" \
  called "link_bin $(migrate_php_cli_bin 8.3) /usr/bin/php8.3"
check "post-assert: /usr/bin/php is linked to the primary once php-cli is gone" \
  called "link_bin $(migrate_php_cli_bin 8.3) /usr/bin/php"
check "post-assert: the active version is asserted" called "php_active_set 8.3"
check "post-assert: B's links are refreshed" called "php_build_links 8.3"
check "post-assert: the PHP probe runs after the restart" in_order "systemctl restart php8.3-fpm" "probe 8.3"
check "post-assert: Valkey answers PING" called "valkey-cli[$(migrate_valkey_cli)] -h 127.0.0.1 -p 6379 PING"
check "post-assert: no assertion fails on a sound host" lacks "$out" "PA unit assertion"
if (( sess_ok )); then
  check "post-assert: the pass verifies" has "$out" "rc=0"
else
  t_skip "post-assert verdict: /var/lib/php/sessions on this host is not www-data:www-data 700"
fi

pa_fixture
enabled php8.3-fpm masked
mkdir -p "$T_UNITS/multi-user.target.wants"
ln -s /lib/systemd/system/nginx.service "$T_UNITS/multi-user.target.wants/nginx.service"
mv "$T_UNITS/valkey-server.service" "$TMP/valkey-server.service.away"
out=$(pa_run 2>&1)
check "post-assert: a masked unit fails the assertion" has "$out" "PA unit assertion: php8.3-fpm is-enabled=masked"
check "post-assert: a wants link to another unit file fails the assertion" has "$out" "PA unit assertion: nginx wants link ->"
check "post-assert: a missing unit file fails the assertion" has "$out" "PA unit assertion: valkey-server unit file missing"
check "post-assert: a failed assertion fails the pass" has "$out" "rc=1"

fresh
migrate_state_set sury-purge purged
migrate_state_set inflight purge
out=$( (
  migrate_post_assert() { rec "post_assert $*"; MIGRATE_PA_ERRORS+=("unit assertion: x"); return 1; }
  migrate_removals_verify 8.3
  echo "rc=$?"
  printf 'R %s\n' "${MIGRATE_REPORT[@]}"
) 2>&1 )
check "verify: one repair attempt after a failed pass" eqv "$(count_calls "post_assert 8.3")" 2
check "verify: a failed repair marks the removals post-purge-failed" eqv "$(st removals)" post-purge-failed
check "verify: a purged Sury is marked post-purge-failed" eqv "$(st sury-purge)" post-purge-failed
check "verify: inflight is cleared" eqv "$(st inflight)" ""
check "verify: the report gives the manual rollback" has "$out" "Manual rollback: dpkg -i"
check "verify: the report lists the failed assertion" has "$out" "**FAILED** unit assertion: x"
fresh
migrate_state_set removals started
out=$( ( migrate_post_assert() { rec "post_assert $*"; return 0; }; migrate_removals_verify 8.3; echo "rc=$?" ) 2>&1 )
check "verify: a sound pass closes the removal phase" eqv "$(st removals)" "done"
check "verify: a sound pass runs once" eqv "$(count_calls "post_assert 8.3")" 1

# ---------------------------------------------------------------------------
# Step 12: report
# ---------------------------------------------------------------------------
fresh
printf '%s\n' '# */1 * * * * php /var/www/commented/job.php' \
  '*/5 * * * * php /var/www/site/cron.php' \
  '0 * * * * /usr/bin/php /var/www/site/artisan schedule:run' \
  '15 * * * * php8.3 -f /var/www/other/job.php' \
  '20 * * * * /usr/bin/php8.1 /var/www/old/job.php' \
  '30 * * * * /usr/local/lib/setup-php/8.3/bin/php /var/www/site/ok.php' \
  '45 * * * * /opt/phpmyadmin/cleanup.sh' > "$STUBD/crontab.root"
printf '*/10 * * * * cd /var/www/wp && php wp-cron.php\n' > "$STUBD/crontab.www-data"
migrate_state_set nginx "done"
migrate_state_set php-8.3 "done"
migrate_state_set valkey-remove "done"
out=$( ( migrate_final_report; printf 'R %s\n' "${MIGRATE_REPORT[@]}" ) 2>&1 )
check "report: crontab lines that run PHP get their own section" has "$out" "Crontab lines that run PHP:"
check "report: a bare php line follows the active version" has "$out" 'php /var/www/site/cron.php` → the source build of the active version'
check "report: a phpX.Y line of a migrated version runs the source build" has "$out" 'job.php` → the source build of PHP 8.3'
check "report: a line calling a removed series is flagged" has "$out" 'PHP 8.1 is not installed any more: this line fails'
check "report: a bare php crontab line is listed" has "$out" '`root: */5 * * * * php /var/www/site/cron.php`'
check "report: a /usr/bin/php crontab line is listed" has "$out" '`root: 0 * * * * /usr/bin/php /var/www/site/artisan schedule:run`'
check "report: a bare phpX.Y crontab line is listed" has "$out" "php8.3 -f /var/www/other/job.php"
check "report: www-data's crontab is read too" has "$out" '`www-data: */10 * * * * cd /var/www/wp && php wp-cron.php`'
check "report: a commented crontab line is not listed" lacks "$out" "/var/www/commented/job.php"
check "report: a line calling our build by its absolute path is not listed" lacks "$out" "ok.php"
check "report: a path that merely contains php is not listed" lacks "$out" "/opt/phpmyadmin/cleanup.sh"
check "report: the part states are listed" has "$out" "state nginx: done"
check "report: every PHP version's state is listed" has "$out" "state php-8.3: done"
check "report: the valkey rc state is explained" has "$out" "stay in dpkg's config-files (rc) state on purpose"

# ---------------------------------------------------------------------------
# 1.22.7 (live host with `listen 443 quic reuseport;` in an Angie vhost): the
# render strips QUIC socket options from the operator vhosts it copies, and
# a failed fit reports the fit's own error.
# ---------------------------------------------------------------------------
check "render: QUIC listen options are stripped after the operator files are copied" \
  bash -c 'b=$(sed -n "/^migrate_nginx_prepare() {/,/^}/p" "$1")
    c=$(grep -n "migrate_copy_operator_files ||" <<<"$b" | head -1 | cut -d: -f1); q=$(grep -n "tune_vhost_quic_listen_options \"\$MIGRATE_NGINX_ETC\"" <<<"$b" | head -1 | cut -d: -f1)
    t=$(grep -n "nginx -t of the rendered tree failed" <<<"$b" | head -1 | cut -d: -f1)
    [[ -n $c && -n $q && -n $t ]] && (( c < q && q < t ))' _ "$ROOT/lib/migrate.sh"
check "render: a failed fit reports the fit's stderr, not the first nginx -t" \
  bash -c 'grep -qF "fit=\$(migrate_nginx_fit \"\$MIGRATE_NGINX_ETC/nginx.conf\" \"\$cand\" 2>\"\$fit_errf\")" "$1" && grep -qF "fit_err=\$(grep -m3 -E '"'"'emerg|error'"'"' \"\$fit_errf\"" "$1" && ! grep -qF "\"\$cand\" 2>/dev/null) \\" "$1"' _ "$ROOT/lib/migrate.sh"
qd=$(mktemp -d "${TMPDIR:-/tmp}/t-migrate-quic.XXXXXX"); mkdir -p "$qd/conf.d"
printf 'server {\n    listen 443 ssl;\n    listen 443 quic reuseport;\n}\n' > "$qd/conf.d/site.conf"
printf 'server {\n  listen 443 quic default_server reuseport rcvbuf=4m sndbuf=4m;\n}\n' > "$qd/conf.d/1.https.default.conf"
SETUP_TEST_SOURCE_ONLY=1 bash -c 'source "$1/setup.sh"; set +eE; trap - ERR; tune_vhost_quic_listen_options "$2"' _ "$ROOT" "$qd" >/dev/null 2>&1
check "render fixer: an Angie vhost's 'listen 443 quic reuseport;' loses reuseport (catch-all untouched)" \
  bash -c 'grep -qE "^    listen 443 quic;$" "$1/conf.d/site.conf" && grep -qF "# setup.sh: QUIC socket options are set by" "$1/conf.d/site.conf" && grep -qF "reuseport rcvbuf=4m sndbuf=4m" "$1/conf.d/1.https.default.conf"' _ "$qd"
rm -rf "$qd"

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
