#!/usr/bin/env bash
# Fail when a tracked file contains a public IPv4 address that is not on the
# allow-list.  Real server addresses must never be committed: documentation,
# tests and examples use RFC 5737 (192.0.2.0/24, 198.51.100.0/24,
# 203.0.113.0/24), private ranges, or example.com / .example / .test names.
#
# Usage: tools/check-public-ips.sh [REPO_DIR]
# Allow-list: tools/public-ip-allowlist.txt (one address or prefix per line,
# a prefix ends with "."; "#" comments).  Only published third-party
# addresses belong there (Cloudflare ranges, public DNS resolvers, version
# strings that look like addresses).
set -u
ROOT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
ALLOW="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/public-ip-allowlist.txt"
cd "$ROOT" || exit 2
FILES=$(git ls-files -- . ":!:.tools" ":!:tools/public-ip-allowlist.txt") || { echo "git ls-files failed in $ROOT" >&2; exit 2; }
[[ -n $FILES ]] || { echo "no tracked files in $ROOT" >&2; exit 2; }
allowed() {
  local ip=$1 a
  while IFS= read -r a; do
    a=${a%%#*}; a=${a//[[:space:]]/}
    [[ -n $a ]] || continue
    if [[ $a == *. ]]; then [[ $ip == "$a"* ]] && return 0
    else [[ $ip == "$a" ]] && return 0; fi
  done < "$ALLOW"
  return 1
}
reserved() {
  local IFS=. a b
  read -r a b _ _ <<<"$1"
  (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 0
  (( a == 100 && b >= 64 && b <= 127 )) && return 0
  (( a == 169 && b == 254 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 )) && return 0
  (( a == 192 && b == 168 )) && return 0
  [[ $1 == 192.0.2.* || $1 == 198.51.100.* || $1 == 203.0.113.* ]] && return 0
  (( a == 198 && (b == 18 || b == 19) )) && return 0
  return 1
}
bad=0
while IFS=: read -r file ip; do
  [[ -n $ip ]] || continue
  reserved "$ip" && continue
  allowed "$ip" && continue
  printf 'public IPv4 %s in %s\n' "$ip" "$file"
  bad=1
done < <(printf '%s\n' "$FILES" | tr '\n' '\0' \
           | xargs -0 grep -IoE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|\.[^0-9]|$)' 2>/dev/null \
           | sed -E 's/^([^:]*):[^0-9]*(([0-9]{1,3}\.){3}[0-9]{1,3}).*/\1:\2/' | sort -u)
if (( bad )); then
  echo "Replace real addresses with RFC 5737 documentation addresses, or add a published third-party address to tools/public-ip-allowlist.txt." >&2
  exit 1
fi
echo "public IPv4 check: clean"
