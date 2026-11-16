#!/usr/bin/env bash
# Solve the Anubis proof-of-work for one host and print the auth cookie header.
# Usage: anubis-solve.sh HOST [IP]   (default IP 127.0.0.1, the audit host)
# Writes the full cookie jar to /root/audit/cookies/anubis-$HOST.jar and the
# Cookie header to /root/audit/cookies/anubis-$HOST.cookie.  Requires node.
set -Eeuo pipefail
HOST=${1:?host}
IP=${2:-127.0.0.1}
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'
DIR=/root/audit/anubis-cookies
mkdir -p "$DIR"
JAR="$DIR/anubis-$HOST.jar"
BASE="https://$HOST"
CURL=(curl -sk --resolve "$HOST:443:$IP" -A "$UA" -b "$JAR" -c "$JAR")
rm -f "$JAR"
"${CURL[@]}" "$BASE/" -o /tmp/anubis-page.html
read -r ID RAND DIFF < <(node -e '
const fs = require("fs");
const h = fs.readFileSync("/tmp/anubis-page.html", "utf8");
const m = /id="anubis_challenge" type="application\/json">([\s\S]*?)<\/script>/.exec(h);
if (!m) { console.error("no challenge in page"); process.exit(1); }
const j = JSON.parse(m[1]);
console.log(j.challenge.id, j.challenge.randomData, j.challenge.difficulty);
')
read -r NONCE HASH < <(node -e '
const {createHash} = require("crypto");
const [rand, diff] = process.argv.slice(1);
const zeros = "0".repeat(parseInt(diff, 10));
for (let n = 0; ; n++) {
  const h = createHash("sha256").update(rand + n).digest("hex");
  if (h.startsWith(zeros)) { console.log(n, h); break; }
}
' "$RAND" "$DIFF")
START=$(date +%s%3N)
"${CURL[@]}" -o /dev/null -w '%{http_code}\n' \
  "$BASE/.within.website/x/cmd/anubis/api/pass-challenge?id=$ID&response=$HASH&nonce=$NONCE&redir=%2F&elapsedTime=$(( $(date +%s%3N) - START ))" >&2
COOKIE=$(awk '/^#HttpOnly_/ || $0 !~ /^#/ { sub(/^#HttpOnly_/, ""); if (NF>=7) printf "%s=%s; ", $6, $7 }' "$JAR" | sed 's/; $//')
printf '%s\n' "$COOKIE" > "$DIR/anubis-$HOST.cookie"
printf '%s\n' "$COOKIE"
