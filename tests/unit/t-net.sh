#!/usr/bin/env bash
# Unit tests for the 1.22.5 nginx/network lane: kTLS stays removed (the
# 16384 tcp_notsent_lowat stays managed), the ipfrag purge order, the
# qdisc report, nginx CPU pinning guards (cpuset, NUMA), SETUP_WP_GUEST_CACHE=0 undoing the marked include, and the
# server-configs-nginx changes (XenForo search/contact limiter, QUIC
# catch-all listener, HTTP/3 snippet, XenForo private trees, cloudflare.sh).
# No root, no services and no system changes are required: every function
# that would touch the host runs in a subshell with stubs, and scratch data
# stays under /tmp.
# Usage: bash tests/unit/t-net.sh   (NGINX_TREE: server-configs-nginx checkout;
# default ./server-configs-nginx (CI) or ../server-configs-nginx; the tree
# checks are skipped without one)
# The stubs are called indirectly by the functions under test.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

if [[ -n ${SCRIPT_VERSION:-} ]]; then
  exec bash "${BASH_SOURCE[0]}"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# CI checks the tree out inside the workspace (server-configs-nginx/); a
# developer keeps it next to this repository.
if [[ -n ${NGINX_TREE:-} ]]; then SCN=$NGINX_TREE
elif [[ -d $ROOT/server-configs-nginx/h5bp ]]; then SCN=$ROOT/server-configs-nginx
else SCN=$ROOT/../server-configs-nginx; fi
PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/setup-test-net.XXXXXX)

export SETUP_TEST_SOURCE_ONLY=1
export SETUP_STATE_DIR="$TMP/state"
unset SETUP_MEM_TOTAL_MB SETUP_WP_GUEST_CACHE
# shellcheck disable=SC1090,SC1091
source "$ROOT/setup.sh"
trap - ERR

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
  printf '::error file=tests/unit/t-net.sh,title=Net test failed::%s\n' "$*"
}
check() {
  local desc=$1
  shift
  if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

# Fake sysctl: live values in $LIVE/<key>, every write appended to $LIVE.log.
# A write the kernel would reject (ipfrag low above the live high, or high
# below the live low) fails like EINVAL.
fake_sysctl() {
  local key val
  case $1 in
    -n) cat "$LIVE/$2" 2>/dev/null || return 1 ;;
    -w)
      key=${2%%=*}; val=${2#*=}
      case $key in
        *frag_low_thresh)
          local hk=${key/low/high}
          [[ -f $LIVE/$hk ]] && (( val > $(<"$LIVE/$hk") )) && { echo "REJECT $key=$val" >> "$LIVE.log"; return 1; } ;;
        *frag_high_thresh)
          local lk=${key/high/low}
          [[ -f $LIVE/$lk ]] && (( val < $(<"$LIVE/$lk") )) && { echo "REJECT $key=$val" >> "$LIVE.log"; return 1; } ;;
      esac
      printf '%s' "$val" > "$LIVE/$key"
      echo "$key=$val" >> "$LIVE.log" ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# A8: --purge restores each ipfrag pair in an order the kernel accepts
# ---------------------------------------------------------------------------
frag_case() { # rec_high rec_low live_high live_low -> write log
  (
    LIVE=$TMP/frag-$1-$3; mkdir -p "$LIVE" "$STATE_DIR"; : > "$LIVE.log"
    rm -f "$STATE_DIR"/sysctl-orig-*
    printf '%s' "$1" > "$STATE_DIR/sysctl-orig-net.ipv4.ipfrag_high_thresh"
    printf '%s' "$2" > "$STATE_DIR/sysctl-orig-net.ipv4.ipfrag_low_thresh"
    printf '%s' "$3" > "$LIVE/net.ipv4.ipfrag_high_thresh"
    printf '%s' "$4" > "$LIVE/net.ipv4.ipfrag_low_thresh"
    sysctl() { fake_sysctl "$@"; }
    warn() { echo "WARN $*" >> "$LIVE.log"; }
    restore_frag_pair net.ipv4.ipfrag_high_thresh net.ipv4.ipfrag_low_thresh
    paste -sd' ' "$LIVE.log"
  )
}
# Large host: tuned low (6 MB) above the recorded 4 MB high -> low first.
out=$(frag_case 4194304 3145728 8388608 6291456)
check "restore_frag_pair: lowering below the live low writes the low mark first" \
  test "$out" = "net.ipv4.ipfrag_low_thresh=3145728 net.ipv4.ipfrag_high_thresh=4194304"
# Usual host: recorded high above the live low -> high first, no rejection.
out=$(frag_case 4194304 3145728 5000000 3500000)
check "restore_frag_pair: the usual case writes the high mark first" \
  test "$out" = "net.ipv4.ipfrag_high_thresh=4194304 net.ipv4.ipfrag_low_thresh=3145728"
# Raising (tune was below the defaults): high first as well.
out=$(frag_case 4194304 3145728 2000000 1000000)
check "restore_frag_pair: raising writes the high mark first" \
  test "$out" = "net.ipv4.ipfrag_high_thresh=4194304 net.ipv4.ipfrag_low_thresh=3145728"
check "restore_frag_pair: no write is rejected in either direction" \
  bash -c '! grep -q REJECT "$1"/frag-*.log' _ "$TMP"
check "restore_sysctl_values: the ipfrag pairs go through restore_frag_pair (IPv4 and IPv6)" \
  bash -c 'b=$(sed -n "/^restore_sysctl_values()/,/^}/p" "$1"); grep -q "restore_frag_pair net.ipv4.ipfrag_high_thresh net.ipv4.ipfrag_low_thresh" <<<"$b" && grep -q "restore_frag_pair net.ipv6.ip6frag_high_thresh net.ipv6.ip6frag_low_thresh" <<<"$b"' _ "$ROOT/lib/os.sh"
check "generated sysctl block: the ipfrag comment says high mark first" \
  bash -c 'grep -q "^# High mark first: at boot the change is upward" "$1" && ! grep -q "write the low mark first and the high mark second" "$1"' _ "$ROOT/lib/os.sh"
check "generated sysctl block: tcp_challenge_ack_limit cites CVE-2016-5696, value kept" \
  bash -c 'grep -q "CVE-2016-5696" "$1" && ! grep -q "CVE-2019-11479" "$1" && grep -qx "net.ipv4.tcp_challenge_ack_limit = 1000" "$1"' _ "$ROOT/lib/os.sh"

# ---------------------------------------------------------------------------
# kTLS removed (1.22.5): no runtime path, no build option; the base
# profile's tcp_notsent_lowat = 16384 (HTTP/2 prioritisation) stays managed.
# ---------------------------------------------------------------------------
check "sysctl profile keeps tcp_notsent_lowat = 16384 (one definition, no kTLS wording)" \
  bash -c '[[ $(grep -c "tcp_notsent_lowat" "$1") -eq 2 ]] && grep -qx "net.ipv4.tcp_notsent_lowat = 16384" "$1" && ! grep -qi ktls "$1"' _ "$ROOT/configs/system/sysctl.conf"
check "SYSCTL_MANAGED_KEYS lists tcp_notsent_lowat (recorded for --purge)" has " ${SYSCTL_MANAGED_KEYS[*]} " " net.ipv4.tcp_notsent_lowat "
check "no kTLS code in setup.sh, lib/, configs/ or nginx-build.conf" \
  bash -c 'cd "$1" && ! grep -rniE "ktls|tls_stat|ssl_conf_command|modules-load.d/setup-ktls" setup.sh lib configs nginx-build.conf' _ "$ROOT"
check "tools/: kTLS survives only as the frozen ' ktls=0' text of the build key" \
  bash -c 'cd "$1" && ! grep -niE "ktls|tls_stat|ssl_conf_command" tools/*.sh | grep -vE "ktls=0|KTLS=1 option keys differently"' _ "$ROOT"
check "no code writes tcp_notsent_lowat (only the profile sets it; the key list names it once)" \
  bash -c '[[ $(cat "$1"/setup.sh "$1"/lib/*.sh "$1"/tools/*.sh | grep -c "tcp_notsent_lowat") -eq 1 ]]' _ "$ROOT"

# ---------------------------------------------------------------------------
# B17: qdisc report (report only)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/net/eth0/device" "$TMP/net/eth1/device" "$TMP/net/lo" "$TMP/net/veth9"
out=$(
  SETUP_SYS_CLASS_NET=$TMP/net
  OPT_REPORT=()
  tc() {
    case $4 in
      eth0) printf 'qdisc mq 0: root\nqdisc fq_codel 0: parent :1 limit 10240p\n' ;;
      eth1) printf 'qdisc mq 0: root\nqdisc fq 0: parent :1 limit 10000p\n' ;;
      *) printf 'qdisc noqueue 0: root\n' ;;
    esac
  }
  info() { :; }
  net_qdisc_report fq
  printf '%s\n' "${OPT_REPORT[@]}"
)
check "net_qdisc_report: a NIC still on fq_codel is reported (fq after the next reboot)" \
  has "$out" "eth0: fq applies after the next reboot (live: fq_codel"
check "net_qdisc_report: a NIC already on fq, lo and virtual links are not reported" \
  bash -c '! grep -qE "eth1|lo:|veth9" <<<"$1"' _ "$out"
out=$(
  SETUP_SYS_CLASS_NET=$TMP/net; OPT_REPORT=()
  tc() { echo "tc $*" >&2; printf 'qdisc fq_codel 0: root\n'; }
  info() { :; }
  net_qdisc_report fq_codel; printf '%s\n' "${OPT_REPORT[@]}"
)
check "net_qdisc_report: nothing to report when the wanted qdisc is not fq" test -z "$out"
check "net_qdisc_report never changes a qdisc (no tc replace/add/change)" \
  bash -c '! sed -n "/^net_qdisc_report()/,/^}/p" "$1" | grep -qE "tc qdisc (replace|add|change|del)"' _ "$ROOT/lib/os.sh"
check "configure_sysctl calls the qdisc report exactly once" \
  test "$(sed -n '/^configure_sysctl()/,/^}/p' "$ROOT/lib/os.sh" | grep -c 'net_qdisc_report')" = 1

# ---------------------------------------------------------------------------
# A12: worker_cpu_affinity guard (quota, cpuset, NUMA)
# ---------------------------------------------------------------------------
check "cpu_list_count 0-3,8-11 = 8" test "$(cpu_list_count 0-3,8-11)" = 8
check "cpu_list_count 0 = 1" test "$(cpu_list_count 0)" = 1
check "cpu_list_count rejects junk" test -z "$(cpu_list_count abc)"
pin_case() { # mask online-list nodes eff [memory-only nodes]
  (
    d=$TMP/pin-$RANDOM; mkdir -p "$d/node"
    printf '%s\n' "$2" > "$d/online"
    for ((i = 0; i < $3; i++)); do mkdir -p "$d/node/node$i"; printf '%s\n' "$i" > "$d/node/node$i/cpulist"; done
    for ((i = $3; i < $3 + ${5:-0}; i++)); do mkdir -p "$d/node/node$i"; printf '\n' > "$d/node/node$i/cpulist"; done
    SETUP_SYS_CPU_ONLINE=$d/online SETUP_SYS_NODE_DIR=$d/node
    nproc() { echo "$MASK"; }
    MASK=$1
    nginx_cpu_pin_block_reason "$4"
  )
}
check "pinning kept on a normal host (12 of 12 CPUs, one node)" test -z "$(pin_case 12 0-11 1 12)"
check "pinning off under a cgroup CPU quota" test "$(pin_case 12 0-11 1 4)" = "cgroup CPU quota"
check "pinning off in a cpuset (nproc honours the mask; online counts all)" test "$(pin_case 4 0-11 1 4)" = "cpuset of 4 of 12 CPUs"
check "pinning off with two NUMA nodes" test "$(pin_case 32 0-31 2 32)" = "2 NUMA nodes"
check "F29: a CPU-less (memory-only) node does not disable pinning" test -z "$(pin_case 16 0-15 1 16 1)"
check "F29: two CPU nodes plus a memory-only node count as 2" test "$(pin_case 32 0-31 2 32 1)" = "2 NUMA nodes"
check "tune_nginx_configs uses nginx_cpu_pin_block_reason and names the reason" \
  bash -c 'b=$(sed -n "/^tune_nginx_configs()/,/^}/p" "$1"); grep -q "nginx_cpu_pin_block_reason" <<<"$b" && grep -q "worker_cpu_affinity disabled (\${pin_why})" <<<"$b"' _ "$ROOT/lib/web.sh"

# ---------------------------------------------------------------------------
# A11: SETUP_WP_GUEST_CACHE=0 removes the include setup.sh added
# ---------------------------------------------------------------------------
mkdir -p "$TMP/wp/conf.d"
cat > "$TMP/wp/conf.d/site.conf" <<EOF
server {
    include h5bp/wordpress_cache.conf;
    ${WP_GUEST_CACHE_MARKED_INCLUDE}
    include h5bp/php_wp.conf;
}
EOF
cat > "$TMP/wp/conf.d/own.conf" <<'EOF'
server {
    include h5bp/wordpress_cache.conf; # mine
    include h5bp/php_wp.conf;
}
EOF
cp "$TMP/wp/conf.d/own.conf" "$TMP/wp/own.orig"
out=$(
  TUNE_CHANGES=()
  wp_guest_cache_remove_marked "$TMP/wp" "$TMP/wp/conf.d/site.conf" "$TMP/wp/conf.d/own.conf" >/dev/null
  printf '%s\n' "${TUNE_CHANGES[@]}"
)
check "SETUP_WP_GUEST_CACHE=0: the marked include is removed and reported" \
  bash -c '! grep -qF "added by setup.sh" "$1" && grep -q "conf.d/site.conf: wordpress_cache include added by setup.sh removed" <<<"$2"' _ "$TMP/wp/conf.d/site.conf" "$out"
check "SETUP_WP_GUEST_CACHE=0: an unmarked include (template or operator) stays" \
  bash -c 'grep -qx "    include h5bp/wordpress_cache.conf;" "$1" && cmp -s "$2" "$3"' _ "$TMP/wp/conf.d/site.conf" "$TMP/wp/conf.d/own.conf" "$TMP/wp/own.orig"
check "optimize_wordpress_cache inserts exactly the line the =0 path removes" \
  bash -c 'sed -n "/^optimize_wordpress_cache()/,/^}/p" "$1" | grep -qF "\"    \${WP_GUEST_CACHE_MARKED_INCLUDE}\""' _ "$ROOT/lib/optimize.sh"

# F31: SETUP_WP_GUEST_CACHE=0 with no vhost left on the cache reports it as
# disabled and installs no zone, map or snippet (a source tree is offered,
# so the old code path would have installed them).
wp31_case() { # 0|1 -> report lines, then the files present
  (
    local t=$TMP/wp31-$1 s=$TMP/wp31-src
    rm -rf "$t"; mkdir -p "$t/conf.d" "$t/http.d" "$t/h5bp" "$t/root" "$s/h5bp" "$s/http.d"
    : > "$t/root/wp-config.php"
    printf 'http {\n  include http.d/*.conf;\n}\n' > "$t/nginx.conf"
    printf '# limits\n' > "$t/http.d/limits.conf"
    printf 'location ~ \\.php$ { }\n' > "$t/h5bp/php_wp.conf"
    printf 'server {\n    root %s;\n    %s\n    include h5bp/php_wp.conf;\n}\n' "$t/root" "$WP_GUEST_CACHE_MARKED_INCLUDE" > "$t/conf.d/wp.conf"
    printf 'fastcgi_cache fastcgicache;\n' > "$s/h5bp/wordpress_cache.conf"
    printf 'map $request_uri $skip_cache { default 0; }\n' > "$s/http.d/wordpress_cache_map.conf"
    printf 'fastcgi_cache_path /tmp/x keys_zone=fastcgicache:1m;\n' > "$s/http.d/fastcgi_cache.conf"
    OPT_REPORT=(); TUNE_CHANGES=()
    ensure_fastcgi_cache_zone() { touch "$1/http.d/ZONE-CREATED"; return 0; }
    CONFIG_SOURCE_DIR=$s SETUP_WP_GUEST_CACHE=$1
    optimize_wordpress_cache "$t" >/dev/null 2>&1
    printf '%s\n' "${OPT_REPORT[@]}" "${TUNE_CHANGES[@]}"
    (cd "$t" && find . -type f | sort)
  )
}
out=$(wp31_case 0)
check "F31: SETUP_WP_GUEST_CACHE=0 reports the guest cache as disabled, not 'already enabled for 0'" \
  bash -c 'grep -qF "FastCGI guest cache disabled (SETUP_WP_GUEST_CACHE=0)" <<<"$1" && ! grep -q "already enabled" <<<"$1" && grep -qF "\`conf.d/wp.conf\` has no wordpress_cache include" <<<"$1"' _ "$out"
check "F31: SETUP_WP_GUEST_CACHE=0 creates no zone, map or wordpress_cache.conf" \
  bash -c '! grep -qE "ZONE-CREATED|zz-setup-wordpress-cache-map|h5bp/wordpress_cache.conf" <<<"$1"' _ "$out"
check "F31: SETUP_WP_GUEST_CACHE=0 still removes the marked include" \
  bash -c '! grep -qF "added by setup.sh" "$1"' _ "$TMP/wp31-0/conf.d/wp.conf"
out=$(wp31_case 1)
check "F31: the default (=1) still installs zone, map and snippet (fixture is live)" \
  bash -c 'grep -q ZONE-CREATED <<<"$1" && grep -q zz-setup-wordpress-cache-map <<<"$1" && grep -q "h5bp/wordpress_cache.conf" <<<"$1"' _ "$out"

# ---------------------------------------------------------------------------
# F1/F8/F14/F21/F28: operator QUIC listen lines lose their socket options
# (the catch-all owns them) before the synced tree is tested
# ---------------------------------------------------------------------------
Q=$TMP/quic
mkdir -p "$Q/conf.d/templates"
cat > "$Q/conf.d/1.https.default.conf" <<'EOF'
server {
  listen      443 quic default_server reuseport rcvbuf=4m sndbuf=4m;
  listen [::]:443 quic default_server reuseport rcvbuf=4m sndbuf=4m;
}
EOF
cp "$Q/conf.d/1.https.default.conf" "$Q/catchall.orig"
cat > "$Q/conf.d/site.conf" <<'EOF'
server {
  listen 443 ssl;
  listen 443 quic reuseport;
  listen [::]:443 quic reuseport rcvbuf=1m;
  # listen 443 quic reuseport;
  listen 192.0.2.10:443 quic reuseport backlog=511 fastopen=256 so_keepalive=on ipv6only=on deferred bind ; # h3
  listen 8443 quic reuseport;
  listen 443 ssl reuseport;
  server_name example.com;
}
EOF
cat > "$Q/conf.d/templates/sample_http3.conf" <<'EOF'
    listen 443 quic reuseport;
EOF
cat > "$Q/conf.d/clean.conf" <<'EOF'
server {
  listen 443 quic;
  listen [::]:443 quic;
}
EOF
cp "$Q/conf.d/clean.conf" "$Q/clean.orig"
cp "$Q/conf.d/site.conf" "$Q/site.pre"
pre_conflicts=$(nginx_quic_listen_conflicts "$Q")
out=$(TUNE_CHANGES=(); tune_vhost_quic_listen_options "$Q" 2>&1; printf '%s\n' "${TUNE_CHANGES[@]}")
S=$Q/conf.d/site.conf
check "QUIC: 'listen 443 quic reuseport;' becomes 'listen 443 quic;'" grep -qx '  listen 443 quic;' "$S"
check "QUIC: '[::]:443 quic reuseport rcvbuf=1m' becomes '[::]:443 quic'" grep -qx '  listen \[::\]:443 quic;' "$S"
check "QUIC: every listed option goes, the trailing comment stays" grep -qx '  listen 192.0.2.10:443 quic; # h3' "$S"
check "QUIC: the original line is kept as a setup.sh comment" \
  grep -qxF "  ${NGINX_QUIC_OPTS_MARK}listen 443 quic reuseport;" "$S"
check "QUIC: the marker is not the build-off one (nginx-build.sh restore must not bring it back)" \
  bash -c '! grep -q "setup-nginx-build-off" "$1"' _ "$S"
check "QUIC: a commented listen line is untouched" grep -qx '  # listen 443 quic reuseport;' "$S"
check "QUIC: a non-443 quic listen and TCP 443 listens keep their options" \
  bash -c 'grep -qx "  listen 8443 quic reuseport;" "$1" && grep -qx "  listen 443 ssl reuseport;" "$1" && grep -qx "  listen 443 ssl;" "$1"' _ "$S"
check "QUIC: conf.d/templates/*.conf is migrated too" grep -qx '    listen 443 quic;' "$Q/conf.d/templates/sample_http3.conf"
check "QUIC: the managed catch-all is untouched" cmp -s "$Q/conf.d/1.https.default.conf" "$Q/catchall.orig"
check "QUIC: a vhost without options is untouched" cmp -s "$Q/conf.d/clean.conf" "$Q/clean.orig"
check "QUIC: each changed file is reported (info and tune note)" \
  bash -c 'grep -q "conf.d/site.conf: QUIC listen socket options removed" <<<"$1" && grep -q "conf.d/templates/sample_http3.conf: HTTP/3 listen socket options removed" <<<"$1" && ! grep -q "clean.conf" <<<"$1"' _ "$out"
check "QUIC: the conflict scan found the lines before and none after" \
  bash -c 'grep -q "conf.d/site.conf:3$" <<<"$1" && grep -q "sample_http3.conf:1$" <<<"$1" && ! grep -q "1.https.default.conf" <<<"$1" && [[ -z $2 ]]' _ "$pre_conflicts" "$(nginx_quic_listen_conflicts "$Q")"
cp "$S" "$Q/site.once"
tune_vhost_quic_listen_options "$Q" >/dev/null 2>&1
check "QUIC: a second run changes nothing" cmp -s "$S" "$Q/site.once"
# nginx -t-like check: per address, at most one active quic listen carries
# socket options (nginx: "duplicate listen options").
quic_dup_opts() { # files... -> status 1 on a duplicate
  awk '
    /^[[:space:]]*listen[[:space:]]/ && / quic/ {
      line = $0; sub(/;.*/, "", line); sub(/^[[:space:]]+/, "", line); n = split(line, t, /[[:space:]]+/)
      a = t[2] ~ /^[0-9]+$/ ? "0.0.0.0:" t[2] : t[2]
      for (i = 3; i <= n; i++) if (t[i] ~ /^(reuseport|deferred|bind|(rcvbuf|sndbuf|backlog|fastopen|so_keepalive|ipv6only)=.*)$/) { if (seen[a]++) bad = 1; break }
    }
    END { exit bad }
  ' "$@"
}
fails() { ! "$@"; }
check "QUIC: the nginx -t-like check flags the pre-migration fixture" \
  fails quic_dup_opts "$Q/catchall.orig" "$Q/site.pre"
check "QUIC: after migration only the catch-all carries options per address" \
  quic_dup_opts "$Q/conf.d/1.https.default.conf" "$S" "$Q/conf.d/templates/sample_http3.conf" "$Q/conf.d/clean.conf"
check "deploy_nginx_tree runs the QUIC migration before nginx -t and names conflicts on failure" \
  bash -c 'b=$(sed -n "/^deploy_nginx_tree()/,/^}/p" "$1"); m=$(grep -n "tune_vhost_quic_listen_options \"\$target\"" <<<"$b" | cut -d: -f1); r=$(grep -n "^  rsync -a" <<<"$b" | cut -d: -f1); t=$(grep -n "if ! nginx_test_tree" <<<"$b" | cut -d: -f1); [[ -n $m && -n $r && -n $t ]] && (( r < m && m < t )) && grep -q "nginx_quic_listen_conflicts \"\$target\"" <<<"$b"' _ "$ROOT/lib/web.sh"

# ---------------------------------------------------------------------------
# server-configs-nginx
# ---------------------------------------------------------------------------
if [[ -f $SCN/http.d/limit_req.conf ]]; then
  LR=$SCN/http.d/limit_req.conf
  re_uri=$(grep -F '|misc/contact)' "$LR" | sed -n '1s/^[[:space:]]*"~\*\(.*\)" \$limit_req_login_key;$/\1/p')
  re_raw=$(grep -F '|misc/contact)' "$LR" | sed -n '2s/^[[:space:]]*"~\*\(.*\)" \$limit_req_login_key;$/\1/p')
  m() { [[ -n $1 ]] && printf '%s\n' "$2" | grep -qiP -- "$1"; }
  not_m() { [[ -n $1 ]] && ! m "$@"; }
  check "limit_req: both route alternations carry search/search and misc/contact" \
    bash -c '[[ -n $1 && -n $2 && $(grep -cF "search/search|misc/contact" "$3") -eq 2 ]]' _ "$re_uri" "$re_raw" "$LR"
  check "limit_req \$uri map: POST /search/search (XenForo friendly URL) is limited" m "$re_uri" 'POST:/index.php?/search/search&'
  check "limit_req \$uri map: POST /misc/contact is limited" m "$re_uri" 'POST:/index.php?/misc/contact&'
  check "limit_req \$uri map: a board in /forum/ is limited too" m "$re_uri" 'POST:/forum/index.php?/search/search&'
  check "limit_req \$uri map: the login route still matches" m "$re_uri" 'POST:/index.php?/login/login&'
  check "limit_req \$uri map: GET search is never limited" not_m "$re_uri" 'GET:/index.php?/search/search&'
  check "limit_req raw map: POST /search/search" m "$re_raw" 'POST:/search/search'
  check "limit_req raw map: POST index.php?misc/contact" m "$re_raw" 'POST:/index.php?misc/contact'
  check "limit_req raw map: search result page POST /search/123/ is not limited" not_m "$re_raw" 'POST:/search/123/'
  check "limit_req raw map: /search/member is not limited" not_m "$re_raw" 'POST:/search/member?user_id=1'
  check "limit_req raw map: /misc/contact-us is not a match" not_m "$re_raw" 'POST:/misc/contact-us'
  check "limit_req: still a single zone at 20r/m" \
    bash -c '[[ $(grep -cE "^[[:space:]]*limit_req_zone" "$1") -eq 1 ]] && grep -q "zone=limit_req_login:16m rate=20r/m;" "$1"' _ "$LR"
  check "limit_req: the uss fixture mirrors server-configs-nginx" cmp -s "$LR" "$ROOT/tests/fixtures/nginx/http.d/limit_req.conf"

  D=$SCN/conf.d/1.https.default.conf
  check "QUIC catch-all: IPv4 listen has reuseport rcvbuf=4m sndbuf=4m" \
    grep -qE '^[[:space:]]*listen[[:space:]]+443 quic default_server reuseport rcvbuf=4m sndbuf=4m;' "$D"
  check "QUIC catch-all: IPv6 listen has reuseport rcvbuf=4m sndbuf=4m" \
    grep -qE '^[[:space:]]*listen[[:space:]]+\[::\]:443 quic default_server reuseport rcvbuf=4m sndbuf=4m;' "$D"
  check "QUIC catch-all: the comment says 443/udp is open" grep -q '443/udp is open' "$D"
  H=$SCN/h5bp/tls/http3.conf
  check "http3.conf: quic_gso on" grep -qx 'quic_gso on;' "$H"
  check "http3.conf: its listen lines carry no socket options" \
    bash -c '[[ $(grep -cE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?443 quic;$" "$1") -eq 2 ]] && ! grep -qE "^[[:space:]]*listen.*(reuseport|rcvbuf|sndbuf|default_server)" "$1"' _ "$H"
  check "http3.conf: no longer tells the operator to open UDP 443 / says it is open" \
    bash -c '! grep -q "ufw allow 443/udp" "$1" && grep -q "UDP 443 is already open" "$1"' _ "$H"
  # 1.7.4: HTTP/3 is on by default: every TLS server block of every vhost
  # template includes http3.conf (once), and the catch-all never does.
  check "templates: every TLS server includes http3.conf (HTTP/3 on by default)" \
    bash -c 'for f in "$1"/conf.d/templates/*.conf; do
      awk "/^[[:space:]]*server[[:space:]]*\\{/{s++; tls[s]=0; h3[s]=0}
           /^[[:space:]]*listen[[:space:]]+(\\[::\\]:)?443[[:space:]]+ssl;/{tls[s]=1}
           /^[[:space:]]*include[[:space:]]+h5bp\\/tls\\/http3.conf;/{h3[s]++}
           END{for(i=1;i<=s;i++) if ((tls[i] && h3[i]!=1) || (!tls[i] && h3[i])) exit 1}" "$f" || { echo "$f" >&2; exit 1; }
    done' _ "$SCN"
  check "templates: the HTTP/3 include is in at least the WordPress, XenForo and Chevereto templates" \
    bash -c 'for t in sample_wordpress sample_xf sample_chev; do [[ $(grep -c "include h5bp/tls/http3.conf;" "$1/conf.d/templates/$t.conf") -ge 1 ]] || exit 1; done' _ "$SCN"
  check "QUIC catch-all does not include http3.conf" bash -c '! grep -q "http3.conf;" "$1"' _ "$D"
  check "no vhost or snippet repeats QUIC socket options" \
    bash -c '! grep -rlE "^[[:space:]]*listen[^;#]*quic[^;#]*(reuseport|rcvbuf|sndbuf)" "$1/conf.d" "$1/h5bp" | grep -v "1.https.default.conf"' _ "$SCN"
  X=$SCN/h5bp/xf2.conf
  check "xf2.conf: private trees keep a trailing slash plus exact matches" \
    bash -c 'for l in "location ^~ /internal_data/ { internal; }" "location = /internal_data { internal; }" "location ^~ /src/ { internal; }" "location = /src { internal; }"; do grep -qF "$l" "$1" || exit 1; done; ! grep -qE "location \^~ /(src|internal_data) \{" "$1"' _ "$X"
  check "ssl_engine.conf: keepalive_timeout stays 60s with a matching comment" \
    bash -c 'grep -qx "keepalive_timeout 60s;" "$1" && grep -q "60 s for TLS servers" "$1"' _ "$SCN/h5bp/tls/ssl_engine.conf"
  # 1.22.5: the TLS 1.3 0-RTT opt-in and its always-on plumbing are removed
  # (unmeasured; origins sit behind Cloudflare, which never sends 0-RTT to the
  # origin, and session tickets are off).  No snippet, template or policy may
  # carry ssl_early_data, the Early-Data proxy header or HTTP_EARLY_DATA.
  check "0-RTT removed: no ssl_early_data, Early-Data header or HTTP_EARLY_DATA in the tree" \
    bash -c '! grep -rqE "ssl_early_data|Early-Data|HTTP_EARLY_DATA" "$1/nginx.conf" "$1/h5bp" "$1/snippets" "$1/conf.d" "$1/http.d"' _ "$SCN"
  check "0-RTT removed: the proxy snippets keep their other forwarded headers" \
    bash -c 'for f in proxy_pass xf_proxy_pass proxy_non_php proxy_ws; do grep -qE "^proxy_set_header X-Forwarded-Proto[[:space:]]+\\\$app_scheme;" "$1/h5bp/$f.conf" || exit 1; done' _ "$SCN"
  check "proxy_pass.conf: the measured upstream keepalive example stays" \
    bash -c 'grep -qF "#       keepalive 16;" "$1" && grep -qx "proxy_http_version 1.1;" "$1"' _ "$SCN/h5bp/proxy_pass.conf"
  # 1.22.5: dead perf files that cannot be enabled on the source build.
  check "http.d: ppa_eilander_conf, http_trim_filter_conf and reverse_proxy_conf are gone" \
    bash -c 'for f in ppa_eilander_conf http_trim_filter_conf reverse_proxy_conf; do [[ ! -e $1/http.d/$f ]] || exit 1; done' _ "$SCN"
  check "http.d: the security snippets stay (sys_guard, naxsi_conf, ngx_waf_conf)" \
    bash -c 'for f in sys_guard naxsi_conf ngx_waf_conf; do [[ -f $1/http.d/$f ]] || exit 1; done' _ "$SCN"
  check "proxy_non_php.conf: no commented proxy_request_buffering opt-in; proxy_ws.conf keeps its live one" \
    bash -c '! grep -q "proxy_request_buffering" "$1/h5bp/proxy_non_php.conf" && grep -qx "proxy_request_buffering off;" "$1/h5bp/proxy_ws.conf"' _ "$SCN"
  check "templates: no FreeBSD accept_filter listen variants" \
    bash -c '! grep -rq "accept_filter" "$1/conf.d"' _ "$SCN"
  # ocsp_stapling.conf is a comment-only stub so an existing include of it
  # still passes nginx -t; it must carry no directive.
  check "ocsp_stapling.conf: kept as a comment-only compatibility stub" \
    bash -c '[[ -f $1 ]] && ! grep -qvE "^[[:space:]]*(#.*)?$" "$1" && grep -q "kept so an" "$1"' _ "$SCN/h5bp/tls/ocsp_stapling.conf"

  # cloudflare.sh with a fake curl, nginx and systemctl.
  CF=$SCN/scripts/cloudflare.sh
  check "cloudflare.sh: no Cloudflare-only firewall or AOP code" \
    bash -c '! grep -qE "CF_ORIGIN_SYNC|cf-origin-sync|CF_ONLY_ORIGIN|SETUP_CF_AOP" "$1"' _ "$CF"
  check "cloudflare.sh: the generated header says http level, not 'in your vhost'" \
    bash -c '! grep -q "Include this file in your vhost" "$1" && grep -q "Loaded at http level" "$1"' _ "$CF"
  cf_run() { # v4count v6count nginx_t_rc [preexisting] -> rc, then the event log
    local d=$TMP/cf-$1-$2-$3-${4:-0}
    rm -rf "$d"; mkdir -p "$d/bin" "$d/http.d"
    local i
    for ((i = 1; i <= $1; i++)); do printf '192.0.2.%s/32\r\n' "$i"; done > "$d/v4"
    for ((i = 1; i <= $2; i++)); do printf '2001:db8:%x::/48\n' "$i"; done > "$d/v6"
    printf '#!/bin/sh\nfor a; do u=$a; done\ncase $u in *ips-v4) cat %s/v4 ;; *ips-v6) cat %s/v6 ;; *) exit 22 ;; esac\n' "$d" "$d" > "$d/bin/curl"
    printf '#!/bin/sh\necho "nginx $*" >> %s/log\nexit %s\n' "$d" "$3" > "$d/nginx"
    printf '#!/bin/sh\necho "systemctl $*" >> %s/log\nexit 0\n' "$d" > "$d/systemctl"
    chmod +x "$d/bin/curl" "$d/nginx" "$d/systemctl"
    [[ ${4:-0} == 1 ]] && printf 'OLD\n' > "$d/http.d/cloudflare.conf"
    local rc=0
    PATH="$d/bin:$PATH" CLOUDFLARE_FILE_PATH=$d/http.d/cloudflare.conf NGINX_BIN=$d/nginx \
      NGINX_CONF=$d/nginx.conf SYSTEMCTL=$d/systemctl CF_IPS_URL=https://cf.example \
      bash "$CF" >/dev/null 2>"$d/err" || rc=$?
    printf 'rc=%s\n' "$rc"
    cat "$d/log" 2>/dev/null || true
  }
  out=$(cf_run 15 7 0 1)
  d=$TMP/cf-15-7-0-1
  check "cloudflare.sh: a full list installs, passes nginx -t and reloads" \
    bash -c 'grep -qx rc=0 <<<"$1" && grep -q "^nginx -t" <<<"$1" && grep -q "systemctl reload nginx.service" <<<"$1"' _ "$out"
  check "cloudflare.sh: 15 IPv4 + 7 IPv6 ranges (CR stripped) and the CF header" \
    bash -c '[[ $(grep -c "^set_real_ip_from" "$1") -eq 22 ]] && ! grep -q $'"'"'\r'"'"' "$1" && grep -qx "real_ip_header CF-Connecting-IP;" "$1"' _ "$d/http.d/cloudflare.conf"
  check "cloudflare.sh: no temporary or backup file is left in http.d" \
    bash -c '[[ $(ls "$1" | wc -l) -eq 1 ]]' _ "$d/http.d"
  out=$(cf_run 3 7 0 1)
  check "cloudflare.sh: a truncated IPv4 list (3 < 10) changes nothing" \
    bash -c 'grep -qx rc=1 <<<"$1" && grep -qx OLD "$2" && ! grep -q "systemctl reload" <<<"$1"' _ "$out" "$TMP/cf-3-7-0-1/http.d/cloudflare.conf"
  out=$(cf_run 15 2 0 1)
  check "cloudflare.sh: a truncated IPv6 list (2 < 5) changes nothing" \
    bash -c 'grep -qx rc=1 <<<"$1" && grep -qx OLD "$2"' _ "$out" "$TMP/cf-15-2-0-1/http.d/cloudflare.conf"
  out=$(cf_run 15 7 1 1)
  check "cloudflare.sh: nginx -t failure restores the previous file, no reload" \
    bash -c 'grep -qx rc=1 <<<"$1" && grep -qx OLD "$2" && ! grep -q "systemctl reload" <<<"$1"' _ "$out" "$TMP/cf-15-7-1-1/http.d/cloudflare.conf"
  out=$(cf_run 15 7 1 0)
  check "cloudflare.sh: nginx -t failure on a first run leaves no file" \
    bash -c 'grep -qx rc=1 <<<"$1" && [[ ! -e $2 ]]' _ "$out" "$TMP/cf-15-7-1-0/http.d/cloudflare.conf"
else
  printf 'SKIP  server-configs-nginx checks (no tree at %s; set NGINX_TREE)\n' "$SCN"
fi

# tools/diff_configs.sh compares only files the tree still ships (1.22.5
# deleted http.d/ppa_eilander_conf, http_trim_filter_conf, reverse_proxy_conf).
check "diff_configs.sh: no removed http.d perf files in the comparison list" \
  bash -c '! grep -qE "ppa_eilander|http_trim_filter|reverse_proxy_conf" "$1"' _ "$ROOT/tools/diff_configs.sh"

# ---------------------------------------------------------------------------
# Docs
# ---------------------------------------------------------------------------
check "README: CONFIG_REPO_REF default is main" \
  bash -c '! grep -q "git ref (default \`nginx\`)" "$1" && grep -q "git ref (default \`main\`)" "$1"' _ "$ROOT/README.md"
check "README: reserved ports include 9000" grep -q '3306, 6379, 9000, 9200, 9300' "$ROOT/README.md"
check "README: says 443/udp is already open" grep -q '443/udp is already open' "$ROOT/README.md"
check "SECURITY-PERFORMANCE: HTTP/3 is on by default per vhost" grep -q 'HTTP/3 (on by default since 1.22.5' "$ROOT/SECURITY-PERFORMANCE.md"

# ---------------------------------------------------------------------------
# HTTP/3 on by default in existing vhosts (tune_vhost_http3_default)
# ---------------------------------------------------------------------------
H3=$TMP/h3; mkdir -p "$H3/conf.d/templates" "$H3/h5bp/tls"; : > "$H3/h5bp/tls/http3.conf"; : > "$H3/nginx.conf"
h3_site() { cat > "$H3/conf.d/site.conf" <<'EOF'
upstream x { server 127.0.0.1:9000; }
server {
    listen      80;
    return 301 https://a$request_uri;
}
server {
    listen      443 ssl;
    listen [::]:443 ssl;
    server_name a.example.com;
    location ~ ^/x{1,3}$ { return 200; }
}
server {
    listen 443 ssl;
    #include h5bp/tls/http3.conf;
    server_name off.example.com;
}
server {
    listen 443 ssl;
    listen 443 quic;
    server_name own.example.com;
}
server {
    listen 192.0.2.5:443 ssl;
    server_name ip.example.com;
}
EOF
  printf 'server {\n    listen 443 ssl default_server;\n    listen 443 quic default_server reuseport;\n}\n' > "$H3/conf.d/1.https.default.conf"
  printf 'server {\n    listen 443 ssl;\n}\n' > "$H3/conf.d/templates/t.conf"; }
h3_run() ( # nginx -t results before/after (0 = pass), then the notes and warnings
  tune_note() { printf 'NOTE %s\n' "$*"; }
  warn() { printf 'WARN %s\n' "$*"; }
  H3_T=0; H3_RES=("$@")
  nginx_test_tree() { local r=${H3_RES[$H3_T]:-0}; H3_T=$((H3_T + 1)); return "$r"; }
  tune_vhost_http3_default "$H3"
)
h3_site; h3_ino=$(stat -c %i "$H3/conf.d/site.conf")
h3_out=$(h3_run 0 0)
h3_body=$(cat "$H3/conf.d/site.conf")
check "HTTP/3 default: the plain TLS server gets the include once" \
  test "$(grep -c '^    include h5bp/tls/http3.conf;' <<<"$h3_body")" = 1
check "HTTP/3 default: the include follows the last 443 ssl listen of that server" \
  bash -c 'grep -A2 "^    listen \\[::\\]:443 ssl;" <<<"$1" | grep -q "include h5bp/tls/http3.conf;"' _ "$h3_body"
check "HTTP/3 default: a commented-out include keeps HTTP/3 off" \
  bash -c 'awk "/off.example.com/{f=1} f" <<<"$1" | head -1 >/dev/null; [[ $(grep -c "include h5bp/tls/http3.conf;" <<<"$1") -eq 2 ]]' _ "$h3_body"
check "HTTP/3 default: a server with its own QUIC listen and an address-specific 443 are left alone" \
  bash -c '[[ $(grep -c "^    include h5bp/tls/http3.conf;" <<<"$1") -eq 1 ]]' _ "$h3_body"
check "HTTP/3 default: the file keeps its inode" test "$(stat -c %i "$H3/conf.d/site.conf")" = "$h3_ino"
check "HTTP/3 default: the change is reported" grep -q 'NOTE conf.d/site.conf: HTTP/3 enabled' <<<"$h3_out"
check "HTTP/3 default: catch-all and templates are never edited" \
  bash -c '! grep -q http3 "$1/conf.d/1.https.default.conf" && ! grep -q http3 "$1/conf.d/templates/t.conf"' _ "$H3"
h3_before=$(cat "$H3/conf.d/site.conf"); h3_out=$(h3_run 0 0)
check "HTTP/3 default: a second run changes nothing and reports nothing" \
  bash -c '[[ "$1" == "$2" && -z $3 ]]' _ "$h3_before" "$(cat "$H3/conf.d/site.conf")" "$h3_out"
h3_site; h3_orig=$(cat "$H3/conf.d/site.conf"); h3_out=$(h3_run 0 1)
check "HTTP/3 default: nginx -t failing afterwards puts the vhost back" test "$(cat "$H3/conf.d/site.conf")" = "$h3_orig"
check "HTTP/3 default: and warns" grep -q 'WARN nginx: adding HTTP/3' <<<"$h3_out"
h3_out=$(h3_run 1)
check "HTTP/3 default: a tree that already fails nginx -t is not touched" \
  bash -c '[[ "$1" == "$2" ]] && grep -q "fails nginx -t without it" <<<"$3"' _ "$h3_orig" "$(cat "$H3/conf.d/site.conf")" "$h3_out"
check "HTTP/3 default: runs before the sync's nginx -t" \
  bash -c 'grep -B4 "# Validate before anything reloads" "$1" | grep -q "tune_vhost_http3_default"' _ "$ROOT/lib/web.sh"
printf 'server {\n    listen 443 ssl\n        http2;\n    server_name m.example.com;\n}\n' > "$TMP/h3-multi.conf"
h3_multi=$(_nginx_http3_include_awk "$TMP/h3-multi.conf")
check "HTTP/3 default: a listen continued on the next line leaves the server block alone" lacks "$h3_multi" "http3.conf"

printf '\nTOTAL pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
