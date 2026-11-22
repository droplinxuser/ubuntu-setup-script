#!/bin/bash
# Compression matrix over the audit tiers (guest cache, member, static) for
# several Accept-Encoding values, on the current host profile.  Rows go to
# /root/audit/comp-TAG.md.  Run exercise-apps.sh keep first (member cookies).
# Compression matrix: comp-matrix.sh TAG [tier-regex] [encodings...]   (root)
set -u
TAG=${1:?tag}; F=${2:-.}; shift 2 2>/dev/null || shift $#
R=${R:-/root/work/ubuntu-setup-script/tests/stress-site}
(( $# )) || set -- "gzip, deflate, br, zstd" "br, gzip" "gzip" "br" "identity"
WPP=$(cat /root/audit/cookies/wp-post.url); XFT=$(cat /root/audit/cookies/xf-thread.url)
OUT=/root/audit/comp-$TAG.md
{
echo "## $TAG  ($(date -u +%FT%TZ))"; bash $R/set-comp.sh show
} >> $OUT
run() { [[ $1 =~ $F ]] || return 0; bash $R/compression-bench.sh "$@" >> $OUT 2>&1; }
run "WP guest post (cached)"   "$WPP" "" "$@"
run "XF guest thread (cached)" "$XFT" "" "$@"
run "Chev explore (cached)"    https://chev.test.local/explore "" "$@"
run "WP member post"           "$WPP" wp-bench1 "$@"
run "XF member thread"         "$XFT" xf-member "$@"
run "static WP block css"      https://wp.test.local/wp-includes/css/dist/block-library/style.min.css "" "$@"
run "static WP jquery js"      https://wp.test.local/wp-includes/js/jquery/jquery.min.js "" "$@"
run "static XF core js"        https://xf.test.local/js/xf/core-compiled.js "" "$@"
echo "MATRIX_DONE $TAG" >> $OUT
