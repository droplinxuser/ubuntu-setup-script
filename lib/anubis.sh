# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# =============================================================================
# Optional Anubis bot filter (--angie anubis=yes / --optimize anubis=yes)
# =============================================================================
# Anubis sits between Angie's TLS terminator and the application vhosts:
#
#   client -> Angie :443 (terminator) -> unix:/run/anubis/nginx.sock (Anubis)
#          -> unix:/run/angie/anubis-backend.sock (the real vhosts)
#
# Both legs are Unix sockets.  Measured on the audit host, a TCP loopback
# backend made Anubis open a new connection for most requests (Go's default
# idle pool is two per host) and topped out at ~8k req/s; the Unix socket
# backend reaches ~49k req/s on the same hardware.  The challenge page is
# branding-free and one instance protects every vhost.
#
# Everything the integration writes is managed: the vhosts are backed up
# before their 443 listeners are moved to the Unix socket, and
# `--optimize anubis=no` restores them.

ANUBIS_VERSION="1.28.2"
# SHA-256 of anubis-${ANUBIS_VERSION}-linux-{amd64,arm64}.tar.gz.  A custom
# version needs SETUP_ANUBIS_SHA256; an unverified binary is never installed
# silently.
ANUBIS_SHA256_AMD64="69fa671d5438e4f54a50128228cf8c901611fea0ef5b25ad33f8514d8d24fe13"
ANUBIS_SHA256_ARM64="4e56246817a1155fb275972d17dff9bd1a8a4ad2aad5aaa09b6a0b9fc7c812d6"
ANUBIS_USER="anubis"
ANUBIS_BIN="/usr/local/bin/anubis"
ANUBIS_ETC="/etc/anubis"
ANUBIS_ENV="${ANUBIS_ETC}/anubis.env"
ANUBIS_POLICY="${ANUBIS_ETC}/botPolicies.yaml"
ANUBIS_UNIT="/etc/systemd/system/anubis.service"
ANUBIS_LISTEN_SOCKET="/run/anubis/nginx.sock"
ANUBIS_BACKEND_SOCKET="/run/angie/anubis-backend.sock"
ANUBIS_METRICS="127.0.0.1:8240"
ANUBIS_STATE="${STATE_DIR}/anubis"
ANUBIS_TERMINATORS="/etc/angie/conf.d/00-anubis-terminators.conf"
ANUBIS_COMMON="/etc/angie/conf.d/00-anubis-common.conf"
ANUBIS_LOCATION="/etc/angie/snippets/anubis-location.conf"
# Static-asset fast path.  Every page view asks for dozens of CSS/JS/font/image
# files and the managed policy ALLOWs them, so sending them through the Go
# proxy buys no filtering and costs a hop (measured on the audit host: one CSS
# file answered 41 603 req/s through Anubis and 137 090 req/s on this path,
# with Anubis at 0.42 -> 0.00 cores).  The terminator proxies these extensions
# to a *static-only shadow*
# of the application server block on a second Unix socket, in a directory that
# www-data may traverse.  The shadow reproduces the application's own root and
# location rules (so /internal_data/ stays internal, dotfiles and backups stay
# denied) and answers 404 for anything that is not an existing static file;
# the terminator then falls back to Anubis.  A local account that reaches the
# shadow socket therefore cannot execute PHP or reach a route that was not
# already a public file.  SETUP_ANUBIS_STATIC_BYPASS=0 keeps every request on
# the proxy hop.
ANUBIS_STATIC_DIR="/run/angie-static"
ANUBIS_STATIC_SOCKET="${ANUBIS_STATIC_DIR}/static.sock"
ANUBIS_STATIC_BLOCKS="/etc/angie/conf.d/00-anubis-static.conf"
# Extensions the terminator routes around the filter: no documents, archives
# or API payloads, only the files a rendered page loads.
ANUBIS_STATIC_ROUTE='^/(?:.*/)?[^/]+[.](?:css|js|mjs|map|png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp4|webm|mp3|ogg|wav|wasm)$'
# What the shadow may serve at all.  A superset of the route so the block's own
# error_page target (.html) still resolves; it is never routed by the
# terminator, so only the application's own rules decide these.
ANUBIS_STATIC_GATE='^/(?:.*/)?[^/]+[.](?:css|js|mjs|map|png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp4|webm|mp3|ogg|wav|wasm|html?)$'
ANUBIS_STATIC_BYPASS="${SETUP_ANUBIS_STATIC_BYPASS:-${ANUBIS_STATIC_BYPASS:-1}}"
[[ $ANUBIS_STATIC_BYPASS == 0 ]] || ANUBIS_STATIC_BYPASS=1
ANUBIS_STATIC_PERSIST=0
[[ -n ${SETUP_ANUBIS_STATIC_BYPASS+x} ]] && ANUBIS_STATIC_PERSIST=1
# User-Agent patterns of the managed policy (anubis_write_policy).  The same
# strings feed the edge route in 00-anubis-common.conf, so Angie and Anubis
# cannot disagree about which client a rule matches.
ANUBIS_GOOD_UA_RE='Googlebot|Google-InspectionTool|bingbot|DuckDuckBot|Applebot|Baiduspider|YandexBot|Qwantbot|Kagi|Marginalia|MojeekBot|InternetArchive|Arquivo'
ANUBIS_AI_UA_RE='GPTBot|ChatGPT-User|OAI-SearchBot|ClaudeBot|Claude-Web|anthropic-ai|CCBot|Google-Extended|Bytespider|Amazonbot|Applebot-Extended|meta-externalagent|PerplexityBot|Diffbot|Omgili|ImagesiftBot|YouBot|cohere-ai|AI2Bot'
ANUBIS_TMPFILES="/etc/tmpfiles.d/angie-anubis.conf"
# Set when this run changed anything under /etc/angie; the caller reloads once.
ANUBIS_ANGIE_DIRTY=0
# 1 when a static-asset shadow server block was generated this run.
ANUBIS_STATIC_ACTIVE=0
ANUBIS_SUMMARY=""
ANUBIS_FAILED=""
ANUBIS_SERVICE_DIRTY=0
# Set when anubis=no restored the vhosts but Angie still runs the in-memory
# configuration that proxies to the filter; the stop happens after the reload.
ANUBIS_STOP_PENDING=0
# Pass-cookie edge check.  A browser that already solved the challenge used
# to pay the Go hop on every request (cached XenForo 17.7k req/s with a pass
# cookie vs 73k on the edge route).  With angie-module-njs, Angie validates
# the HS512 pass cookie itself (anubis_pass.js: signature, exp/nbf, action,
# restriction claim, issued after the policy last changed) and sends a valid
# one straight to the backend; anything else still reaches Anubis.
# SETUP_ANUBIS_PASS_EDGE=0 keeps every browser request on the Go hop.
ANUBIS_NJS_DIR="/etc/angie/njs"
ANUBIS_PASS_JS="${ANUBIS_NJS_DIR}/anubis_pass.js"
# Under ssl/: the Angie tree normaliser resets every other file to 0644.
ANUBIS_PASS_KEY="/etc/angie/ssl/anubis/pass-key.conf"
ANUBIS_NJS_LOAD="/etc/angie/modules-enabled/60-anubis-njs.conf"
ANUBIS_PASS_EDGE="${SETUP_ANUBIS_PASS_EDGE:-1}"
[[ $ANUBIS_PASS_EDGE == 0 ]] || ANUBIS_PASS_EDGE=1
ANUBIS_PASS_ACTIVE=0

anubis_marker() { printf '%s/enabled' "$ANUBIS_STATE"; }

# This module's own Angie-side artifacts: the terminators/common snippets, a
# static shadow file, or a vhost still listening on the backend socket.  They
# outlive the state directory if an operator moves or deletes it (the state
# directory also holds the marker, so `anubis=no` used to do nothing while the
# vhosts stayed behind a filter that was then stopped: every site answered
# 502 until the file was restored by hand).  An Anubis an operator installed
# and integrated by hand matches none of these names and is still left alone.
anubis_artifacts_present() {
  local live_dir=${1:-/etc/angie/conf.d}
  [[ -f $ANUBIS_TERMINATORS || -f $ANUBIS_COMMON || -f $ANUBIS_LOCATION \
     || -f $ANUBIS_STATIC_BLOCKS ]] && return 0
  local f
  for f in "$live_dir"/*.conf; do
    [[ -f $f ]] || continue
    case ${f##*/} in 00-anubis-*) continue ;; esac
    anubis_vhost_integrated "$f" && return 0
  done
  return 1
}

anubis_managed() { [[ -f "$(anubis_marker)" ]] || anubis_artifacts_present; }

# Whether this run should leave the host with Anubis enabled.
anubis_wanted() { (( ${ANUBIS_ENABLED:-0} )); }

# ---------------------------------------------------------------------------
# Package/service installation
# ---------------------------------------------------------------------------
anubis_create_user() {
  id "$ANUBIS_USER" >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --home-dir /var/lib/anubis \
    --shell /usr/sbin/nologin "$ANUBIS_USER" \
    || { warn "Could not create the ${ANUBIS_USER} system user"; return 1; }
  info "Created system user ${ANUBIS_USER}"
}

# Angie workers run as www-data.  nginx re-runs initgroups() when it spawns a
# worker, so membership in the filter's group is what lets them connect to a
# 0660 socket in a 0750 directory without opening it to every local account.
anubis_join_www_group() {
  id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx "$ANUBIS_USER" && return 0
  usermod -aG "$ANUBIS_USER" www-data \
    || { warn "Could not add www-data to the ${ANUBIS_USER} group"; return 1; }
  info "Added www-data to the ${ANUBIS_USER} group (Anubis socket access)"
  # Existing workers still carry their old supplementary groups.  Reload
  # Angie now, while it still talks to the old (open) socket, so the new
  # workers can connect to the 0660 socket that anubis_start creates next.
  if systemctl is-active --quiet angie 2>/dev/null; then
    systemctl reload angie 2>/dev/null \
      || warn "Could not reload Angie after the ${ANUBIS_USER} group change"
  fi
  return 0
}

# Remove the worker's membership once the filter is stopped, so a disabled
# host does not keep an empty, setup-owned group (or a stray supplementary
# group on www-data) that the next restore has to clean up by hand.
anubis_leave_www_group() {
  id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx "$ANUBIS_USER" || return 0
  gpasswd -d www-data "$ANUBIS_USER" >/dev/null 2>&1 || true
  return 0
}

anubis_installed_version() {
  [[ -x $ANUBIS_BIN ]] || return 1
  "$ANUBIS_BIN" --version 2>/dev/null | awk '{print $2}'
}

anubis_install_binary() {
  local current want tmp url got want_sha arch
  case $(uname -m) in
    x86_64|amd64)  arch=amd64; want_sha=$ANUBIS_SHA256_AMD64 ;;
    aarch64|arm64) arch=arm64; want_sha=$ANUBIS_SHA256_ARM64 ;;
    *) warn "Anubis has no release build for $(uname -m); install it by hand"; return 1 ;;
  esac
  # Apply the version override before comparing: a pinned version used to be
  # compared against the default, so every run re-downloaded it and replaced
  # the binary while the running service kept the old inode.
  want_sha=${SETUP_ANUBIS_SHA256:-$want_sha}
  if [[ ${SETUP_ANUBIS_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ANUBIS_VERSION=$SETUP_ANUBIS_VERSION
    # A pinned version has no built-in hash (the loader only ships hashes for
    # the release this script was tested with).  Installing a root-owned
    # binary from an unverified download is not worth the convenience: fail
    # closed and name the variable that makes the pin verifiable.
    if [[ -z ${SETUP_ANUBIS_SHA256:-} ]]; then
      die "SETUP_ANUBIS_VERSION=${ANUBIS_VERSION} needs SETUP_ANUBIS_SHA256=<sha256 of the release tarball>; refusing an unverified download"
    fi
    want_sha=$SETUP_ANUBIS_SHA256
  fi
  want="v${ANUBIS_VERSION}"
  current=$(anubis_installed_version || true)
  # Release builds print "Anubis v1.28.2"; normalise the prefix on both
  # sides so a build that omits (or adds) it is not re-downloaded each run.
  [[ ${current#v} == "${want#v}" ]] && return 0

  url="https://github.com/TecharoHQ/anubis/releases/download/v${ANUBIS_VERSION}/anubis-${ANUBIS_VERSION}-linux-${arch}.tar.gz"
  tmp=$(tmp_dir anubis.XXXXXX) || return 1
  info "Downloading Anubis ${ANUBIS_VERSION} (${arch} static binary)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "${tmp}/anubis.tar.gz" "$url" || return 1
  else
    wget --https-only -q -O "${tmp}/anubis.tar.gz" "$url" || return 1
  fi
  if [[ -n $want_sha ]]; then
    got=$(sha256sum "${tmp}/anubis.tar.gz" | awk '{print $1}')
    if [[ $got != "$want_sha" ]]; then
      warn "Anubis download checksum mismatch (${got:-none}); refusing to install it"
      return 1
    fi
  else
    warn "Installing Anubis ${ANUBIS_VERSION} without a known checksum (SETUP_ANUBIS_SHA256 was not set)"
  fi
  tar -xzf "${tmp}/anubis.tar.gz" -C "$tmp" || return 1
  install -m 755 "${tmp}/anubis-${ANUBIS_VERSION}-linux-${arch}/bin/anubis" "$ANUBIS_BIN" \
    || return 1
  # The running service keeps the old inode until it is restarted.
  ANUBIS_SERVICE_DIRTY=1
  info "Installed ${ANUBIS_BIN} (Anubis ${ANUBIS_VERSION}, ${arch})"
  return 0
}

anubis_write_env() {
  local secret tmp
  install -d -m 750 -o "$ANUBIS_USER" -g "$ANUBIS_USER" "$ANUBIS_ETC" \
    /var/lib/anubis /var/cache/anubis || return 1
  # Create the live file with mode 600 before it holds the cookie secret:
  # commit_if_changed writes with the caller's umask (022).
  [[ -e $ANUBIS_ENV ]] || ( umask 077; : > "$ANUBIS_ENV" ) || return 1
  secret=$(sed -n 's/^HS512_SECRET=//p' "$ANUBIS_ENV" 2>/dev/null | head -n1 || true)
  [[ -n $secret ]] || secret=$(openssl rand -hex 64)
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<EOF
# Managed by setup.sh (ANUBIS=1).  Change the policy in botPolicies.yaml;
# the cookie secret must stay stable or every visitor is challenged again.
BIND=${ANUBIS_LISTEN_SOCKET}
BIND_NETWORK=unix
TARGET=unix://${ANUBIS_BACKEND_SOCKET}
DIFFICULTY=4
COOKIE_SECURE=true
COOKIE_HTTP_ONLY=true
COOKIE_SAME_SITE=Lax
COOKIE_EXPIRATION_TIME=168h
CUSTOM_REAL_IP_HEADER=X-Real-IP
# Anubis localises its own challenge/error pages from Accept-Language with
# go-i18n's MustLocalize, which panics on a missing message.  The bundled Thai
# catalogue is incomplete (no "simplified_explanation"), so every Thai browser
# rendered the challenge as a panic: the handler closed the connection and
# Angie answered 502 (reproduced on 1.28.2, 2026-11-18).  Pin a complete
# catalogue for the interstitital only; the application still receives the
# visitor's own Accept-Language.  SETUP_ANUBIS_LANGUAGE overrides the choice
# (e.g. th after the upstream catalogue is fixed).
FORCED_LANGUAGE=$(anubis_forced_language)
METRICS_BIND=${ANUBIS_METRICS}
METRICS_BIND_NETWORK=tcp
POLICY_FNAME=${ANUBIS_POLICY}
# WARN keeps one journal line per challenge and none per proxied request;
# INFO on a busy site fills the journal and costs CPU.
SLOG_LEVEL=WARN
# Anubis creates the listening socket as its own user, with the service's
# group.  anubis_enable adds www-data to that group so Angie workers can
# connect; the socket and its RuntimeDirectory are group-only (0660/0750), so
# any other local account cannot reach the filter and forge X-Real-IP.
SOCKET_MODE=0660
HS512_SECRET=${secret}
EOF
  # After a challenge Anubis redirects to the ?redir= URL.  Without an
  # allow-list it redirects anywhere (an open redirect on every protected
  # site) and warns at every start.  The list is the server names of the
  # sites behind the filter; a regex server_name cannot be expressed, so then
  # the variable is left out rather than locking visitors out.
  local domains
  if domains=$(anubis_redirect_domains) && [[ -n $domains ]]; then
    printf 'REDIRECT_DOMAINS=%s\n' "$domains" >> "$tmp"
  fi
  if commit_if_changed "$ANUBIS_ENV" "$tmp"; then ANUBIS_SERVICE_DIRTY=1; fi
  chmod 600 "$ANUBIS_ENV"; chown root:"$ANUBIS_USER" "$ANUBIS_ENV"
  return 0
}

# Comma-separated server names of every site Anubis fronts (all vhosts
# anubis_vhost_files selects; each is integrated in the same run).  Nginx's
# ".example.com" becomes "example.com,*.example.com".  Fails (status 1) when a
# regex server_name makes the set impossible to list.
anubis_redirect_domains() {
  local dir=${1:-/etc/angie/conf.d} f
  local -a files=()
  for f in $(anubis_vhost_files "$dir"); do files+=("$f"); done
  (( ${#files[@]} > 0 )) || return 0
  awk '
    {
      code = $0
      sub(/#.*/, "", code)
      if (code !~ /^[ \t]*server_name[ \t]+/) next
      sub(/^[ \t]*server_name[ \t]+/, "", code)
      sub(/;.*/, "", code)
      n = split(code, a, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        d = tolower(a[i])
        if (d == "" || d == "_" || d == "\"\"") continue
        if (d ~ /^~/) { bad = 1; continue }
        if (d ~ /^\./) { add(substr(d, 2)); add("*" d); continue }
        add(d)
      }
    }
    function add(x) { if (!(x in seen)) { seen[x] = 1; out = (out == "" ? x : out "," x) } }
    END { if (bad) exit 1; print out }
  ' "${files[@]}"
}

# Language Anubis uses for its own pages.  English is the only catalogue that
# is complete in every release this script has shipped; an incomplete one
# turns the challenge into a panic (502) for that locale.  The value goes into
# an env file, so it is validated like one.
anubis_forced_language() {
  local lang=${SETUP_ANUBIS_LANGUAGE:-en}
  [[ $lang =~ ^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$ ]] || lang=en
  printf '%s' "$lang"
}

# A lean policy: allow search engines and infrastructure routes, deny the
# crawlers that ignore robots.txt, and challenge anything that claims to be a
# browser.  Unmatched clients are allowed (Anubis default-allow), which keeps
# API clients, cron jobs and CLI tools working; a site that wants to challenge
# every client can add a catch-all CHALLENGE rule.
anubis_write_policy() {
  local tmp
  tmp=$(tmp_file) || return 1
  {
    printf '%s\n' '# Managed by setup.sh (ANUBIS=1).  Rules are evaluated in order.' \
      '# The edge route in 00-anubis-common.conf mirrors the ALLOW decisions' \
      '# that need no cookie; edit both together.' 'bots:' \
      '  - name: allow-good-crawlers' \
      "    user_agent_regex: (?i)(${ANUBIS_GOOD_UA_RE})" \
      '    action: ALLOW' \
      '  - name: deny-ai-crawlers' \
      "    user_agent_regex: (?i)(${ANUBIS_AI_UA_RE})" \
      '    action: DENY'
    cat <<'EOF'
  - name: well-known
    path_regex: ^/\.well-known/.*$
    action: ALLOW
  - name: favicon
    path_regex: ^/favicon\.ico$
    action: ALLOW
  - name: robots-txt
    path_regex: ^/robots\.txt$
    action: ALLOW
  # Static assets are not a scraping target and every page load asks for
  # dozens of them.  Proxying them without a challenge keeps the first visit
  # renderable (a challenged CSS/JS request returns HTML) and removes most of
  # Anubis's request volume on a real site.
  # A static-looking path that is not a file in the application root (the
  # static shadow answered 404) goes on to PHP.  Browsers get the same
  # challenge as for a page: /x.css?rest_route=/wp/v2/users used to return
  # the WordPress REST API with no challenge.  The terminator sets the header
  # only on that fallback; a client sending it just gets challenged.
  - name: static-miss
    user_agent_regex: Mozilla
    headers_regex:
      X-Anubis-Static-Miss: ^1$
    action: CHALLENGE
  - name: static-assets
    path_regex: (?i)\.(?:css|js|mjs|map|json|webmanifest|png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp4|webm|mp3|ogg|wav|pdf|txt|xml|zip|gz|br|wasm)$
    action: ALLOW
  - name: empty-user-agent
    user_agent_regex: ^$
    action: CHALLENGE
  - name: generic-browser
    user_agent_regex: Mozilla
    action: CHALLENGE
EOF
  } > "$tmp" || return 1
  if commit_if_changed "$ANUBIS_POLICY" "$tmp"; then ANUBIS_SERVICE_DIRTY=1; fi
  chown root:"$ANUBIS_USER" "$ANUBIS_POLICY"
  chmod 640 "$ANUBIS_POLICY"
  return 0
}

# ---------------------------------------------------------------------------
# Anubis runtime profile (pure helpers, shared with the dry run and the tests)
# ---------------------------------------------------------------------------
# Go schedules one P per CPU by default.  Measured on the 16-thread audit host
# at 100 connections: default 7 203 cached pages/s (4.17 Anubis cores),
# GOMAXPROCS=8 6 871 req/s (3.92 cores, same p99), 4 = 5 925 (2.99), 2 = 3 812.
# Eight keeps essentially all the throughput while bounding how much runtime
# parallelism the proxy can ask for when PHP needs the same cores.  A host
# with fewer cores uses them all; more than eight adds nothing measurable.
anubis_gomaxprocs() {
  local cpus=${1:-1}
  [[ $cpus =~ ^[0-9]+$ ]] && (( cpus > 0 )) || cpus=1
  printf '%s' "$(tune_clamp "$cpus" 1 8)"
}

# GOGC is the heap growth target, so it is a memory decision as much as a CPU
# one.  400 is the measured optimum on a host with RAM to spare (1.21.16:
# 7 100 vs 6 750 req/s at the default 100); a small VPS keeps Go's default so
# a burst cannot turn the relaxed collector into a multi-hundred-MB heap with
# no headroom left for PHP or MariaDB.
#
# On a host with 16 GB or more, GOGC=off is safe *because* GOMEMLIMIT is set:
# the collector only runs as the heap approaches the limit (RAM/8, capped at
# 2 GiB), so a quiet filter still holds ~120 MB and a saturated one stops at
# 2 GiB instead of growing unbounded.  Measured on the 12-thread EPYC audit
# host through Anubis: 51 949 req/s at GOGC=400, 57 082 at GOGC=off (+9.9%),
# RSS < 2 GiB.  A host below 16 GB keeps the graduated values above.
anubis_gogc() {
  local ram_mb=${1:-1024}
  [[ $ram_mb =~ ^[0-9]+$ ]] && (( ram_mb > 0 )) || ram_mb=1024
  if (( ram_mb >= 16384 )); then
    printf 'off'
  elif (( ram_mb <= 2048 )); then
    printf '100'
  elif (( ram_mb <= 4096 )); then
    printf '200'
  elif (( ram_mb <= 8192 )); then
    printf '300'
  else
    printf '400'
  fi
}

# GOMEMLIMIT is a backstop, not an allocation: the proxy holds ~120 MB
# resident.  A 2 GB VPS still gets 256 MB (twice the working set), larger hosts
# 1/8 of RAM up to 2 GiB.  Capping it matters because a heap limit far above
# what the process can use only delays a collection that should have happened.
anubis_memlimit_mb() {
  local ram_mb=${1:-1024}
  [[ $ram_mb =~ ^[0-9]+$ ]] && (( ram_mb > 0 )) || ram_mb=1024
  printf '%s' "$(tune_clamp $(( ram_mb / 8 )) 256 2048)"
}

# Two descriptors per proxied connection (client + backend) plus listeners,
# metrics and runtime.  Scale with cores because the proxy is CPU-bound at
# ~7k req/s per core; floor 16k for a 1-4 CPU VPS, ceiling 128k.
anubis_nofile() {
  local cpus=${1:-1}
  [[ $cpus =~ ^[0-9]+$ ]] && (( cpus > 0 )) || cpus=1
  printf '%s' "$(tune_clamp $(( cpus * 4096 )) 16384 131072)"
}

# One line for the log/report, so the applied profile is visible.
anubis_runtime_summary() {
  local cpus ram_mb
  cpus=$(effective_cpus)
  ram_mb=$(mem_total_mb)
  printf 'GOMAXPROCS=%s GOGC=%s GOMEMLIMIT=%sMiB LimitNOFILE=%s' \
    "$(anubis_gomaxprocs "$cpus")" "$(anubis_gogc "$ram_mb")" \
    "$(anubis_memlimit_mb "$ram_mb")" "$(anubis_nofile "$cpus")"
}

anubis_write_unit() {
  local tmp gomaxprocs gogc memlimit_mb nofile cpus ram_mb
  tmp=$(tmp_file) || return 1
  cpus=$(effective_cpus)
  ram_mb=$(mem_total_mb)
  gomaxprocs=$(anubis_gomaxprocs "$cpus")
  gogc=$(anubis_gogc "$ram_mb")
  memlimit_mb=$(anubis_memlimit_mb "$ram_mb")
  nofile=$(anubis_nofile "$cpus")
  cat > "$tmp" <<EOF
[Unit]
Description=Anubis bot filter proxy (Angie)
Documentation=https://anubis.techaro.lol/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anubis
# The socket is group-connectable for Angie workers only: anubis_enable adds
# www-data to the anubis group (nginx re-runs initgroups when it spawns a
# worker), so no other local account can open the filter socket directly.
Group=anubis
EnvironmentFile=/etc/anubis/anubis.env
ExecStart=/usr/local/bin/anubis
Restart=on-failure
RestartSec=3
# Hardware-derived fd ceiling (cores x 4096, 16k..128k).
LimitNOFILE=${nofile}
# Go runtime tuning for a request proxy.  Anubis allocates per request (headers,
# policy matches, proxy copy); the default GOGC=100 collects long before the
# heap is large, and that mark/sweep work is pure overhead when the process
# only needs ~120 MB.  GOGC grows with RAM (100 at <=2 GB, 400 above 8 GB) and
# GOMEMLIMIT is 1/8 of RAM clamped to 256 MiB..2 GiB, so a small VPS never
# promises the collector more heap than it can back.  Measured at 16 GB:
# GOGC=400 7 100 req/s vs 6 750 at the default, RSS 114 MB.
Environment=GOGC=${gogc}
Environment=GOMEMLIMIT=${memlimit_mb}MiB
Environment=GOMAXPROCS=${gomaxprocs}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RuntimeDirectory=anubis
RuntimeDirectoryMode=0750
StateDirectory=anubis
CacheDirectory=anubis

[Install]
WantedBy=multi-user.target
EOF
  if commit_if_changed "$ANUBIS_UNIT" "$tmp"; then
    ANUBIS_SERVICE_DIRTY=1
    systemctl daemon-reload || true
  fi
  return 0
}

# /run is a tmpfs; Angie creates the backend socket there on every start, so
# the directory must exist before Angie starts at boot.  The socket itself is
# created 0777 (Angie daemonises with umask 0), so the directory is what keeps
# other local accounts out: only root and the Anubis user may traverse it.
# Without that, any local user could connect to the backend vhosts directly
# with "X-Real-IP: 127.0.0.1" and skip the bot filter and every IP ACL.
anubis_write_tmpfiles() {
  local tmp
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
# setup.sh: directories for the Anubis backend and static-shadow Unix sockets.
d /run/angie 0750 root anubis -
# The static shadow serves public files only; Angie workers (www-data) connect
# to it for the asset fast path.  The application backend above stays closed
# to www-data, so a local account cannot skip the filter for a dynamic page.
d /run/angie-static 0750 root www-data -
EOF
  if commit_if_changed "$ANUBIS_TMPFILES" "$tmp"; then ANUBIS_ANGIE_DIRTY=1; fi
  systemd-tmpfiles --create "$ANUBIS_TMPFILES" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# Angie configuration
# ---------------------------------------------------------------------------
# Route for a browser User-Agent in the edge map: the njs pass-cookie check
# when it is active, otherwise always Anubis.
anubis_browser_route() {
  if (( ANUBIS_PASS_ACTIVE )); then printf '%s' '$anubis_pass_route'; else printf 'anubis'; fi
}

# The pass-cookie check itself.  Kept byte-identical across runs so a plain
# --optimize does not reload Angie.
anubis_pass_js() {
  cat <<'EOF'
// Managed by setup.sh (ANUBIS=1).  Validates the Anubis pass cookie in Angie
// so a browser that already solved the challenge skips the Go proxy hop.
// Mirrors what Anubis 1.28 checks before it proxies a CHALLENGE-rule
// request: HS512 signature with the shared secret, exp/nbf, action
// CHALLENGE and, when present, the restriction claim (SHA-256 of the
// X-Real-IP Anubis saw).  Tokens issued before the policy last changed
// (iat < $anubis_pass_epoch) go back to Anubis, which re-checks them against
// the current rule hash.  Anything unexpected -> Anubis.
const crypto = require('crypto');

// Anubis appends a settings-derived suffix (DynamicCookieSuffix).
const COOKIE = /(?:^|;\s*)techaro\.lol-anubis-auth(?:-[0-9a-f]{8})?=([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)(?:;|$)/;

function same(a, b) {
    if (a.length !== b.length) { return false; }
    let d = 0;
    for (let i = 0; i < a.length; i++) { d |= a.charCodeAt(i) ^ b.charCodeAt(i); }
    return d === 0;
}

function json(part) {
    return JSON.parse(Buffer.from(part, 'base64url').toString());
}

function route(r) {
    const v = r.variables;
    const cookie = r.headersIn.Cookie;
    if (!cookie || !v.anubis_pass_key) { return 'anubis'; }
    // First request after a challenge: Anubis restores the original Referer.
    if (cookie.indexOf('techaro.lol-anubis-original-referer') !== -1) { return 'anubis'; }
    const m = COOKIE.exec(cookie);
    if (!m) { return 'anubis'; }
    // Verdict cache: a token already verified for this address (and this
    // policy epoch and secret) skips the HMAC until its exp.  Only the route
    // depends on it, so a cached entry grants nothing the token did not.
    const now = Date.now() / 1000;
    const dict = ngx.shared.anubis_pass;
    const ck = m[3] + '|' + v.remote_addr + '|' + v.anubis_pass_epoch + '|' + v.anubis_pass_kid;
    const hit = dict.get(ck);
    if (hit !== undefined && hit > now) { return 'anubis_backend'; }
    const sig = crypto.createHmac('sha512', v.anubis_pass_key)
        .update(m[1] + '.' + m[2]).digest('base64url');
    if (!same(sig, m[3])) { return 'anubis'; }
    let exp;
    try {
        if (json(m[1]).alg !== 'HS512') { return 'anubis'; }
        const c = json(m[2]);
        if (typeof c.exp !== 'number' || c.exp <= now) { return 'anubis'; }
        if (typeof c.nbf === 'number' && c.nbf > now) { return 'anubis'; }
        if (c.action !== 'CHALLENGE') { return 'anubis'; }
        if (!(c.iat >= Number(v.anubis_pass_epoch))) { return 'anubis'; }
        if (c.restriction !== undefined && c.restriction !==
            crypto.createHash('sha256').update(v.remote_addr).digest('hex')) {
            return 'anubis';
        }
        exp = c.exp;
    } catch (e) {
        return 'anubis';
    }
    try { dict.set(ck, exp); } catch (e) { /* full and nothing to evict: verify next time */ }
    return 'anubis_backend';
}

export default { route };
EOF
}

# Remove the pass-cookie check files (disable, opt-out, or no njs module).
anubis_remove_pass_edge() {
  local f
  for f in "$ANUBIS_NJS_LOAD" "$ANUBIS_PASS_KEY" "$ANUBIS_PASS_JS"; do
    [[ -e $f ]] || continue
    rm -f -- "$f" && ANUBIS_ANGIE_DIRTY=1
  done
  rmdir "$ANUBIS_NJS_DIR" "${ANUBIS_PASS_KEY%/*}" 2>/dev/null || true
  return 0
}

# Install angie-module-njs (when missing) and write the module loader, the
# check and its key file.  Sets ANUBIS_PASS_ACTIVE.  Never fails the caller:
# without njs the browser route simply stays on Anubis.
anubis_write_pass_edge() {
  local tmp secret epoch kid
  ANUBIS_PASS_ACTIVE=0
  if (( ANUBIS_PASS_EDGE == 0 )); then
    anubis_remove_pass_edge
    return 0
  fi
  if ! pkg_ok angie-module-njs; then
    apt-cache show angie-module-njs >/dev/null 2>&1 || apt_update_once
    if ! apt_install angie-module-njs >/dev/null 2>&1; then
      info "Anubis: angie-module-njs is not available; browsers with a pass cookie stay on the Anubis hop"
      anubis_remove_pass_edge
      return 0
    fi
  fi
  secret=$(sed -n 's/^HS512_SECRET=//p' "$ANUBIS_ENV" 2>/dev/null | head -n1 || true)
  if [[ ! $secret =~ ^[A-Za-z0-9]{64,}$ ]]; then
    anubis_remove_pass_edge
    return 0
  fi
  # Tokens issued before the policy file last changed may carry an old rule
  # hash; they go to Anubis (commit_if_changed only rewrites on a change).
  epoch=$(stat -c %Y "$ANUBIS_POLICY" 2>/dev/null || echo 0)
  # A fingerprint of the secret keys the verdict cache: a new secret must not
  # honour verdicts cached under the old one (the zone survives reloads).
  kid=$(printf '%s' "$secret" | sha256sum | cut -c1-16)
  install -d -m 755 "$ANUBIS_NJS_DIR" "${ANUBIS_NJS_LOAD%/*}" || return 0
  tmp=$(tmp_file) || return 0
  printf '%s\n' '# Managed by setup.sh (ANUBIS=1): njs for the Anubis pass-cookie check.' \
    'load_module modules/ngx_http_js_module.so;' > "$tmp"
  commit_if_changed "$ANUBIS_NJS_LOAD" "$tmp" && ANUBIS_ANGIE_DIRTY=1
  chmod 644 "$ANUBIS_NJS_LOAD"
  tmp=$(tmp_file) || return 0
  anubis_pass_js > "$tmp"
  commit_if_changed "$ANUBIS_PASS_JS" "$tmp" && ANUBIS_ANGIE_DIRTY=1
  chmod 644 "$ANUBIS_PASS_JS"
  # The key file holds the cookie secret: root-only, read by the master.
  install -d -m 700 "${ANUBIS_PASS_KEY%/*}" || return 0
  [[ -e $ANUBIS_PASS_KEY ]] || ( umask 077; : > "$ANUBIS_PASS_KEY" ) || return 0
  tmp=$(tmp_file) || return 0
  printf '%s\n' '# Managed by setup.sh (ANUBIS=1): Anubis HS512 secret and policy epoch.' \
    "js_var \$anubis_pass_key ${secret};" "js_var \$anubis_pass_epoch ${epoch};" "js_var \$anubis_pass_kid ${kid};" > "$tmp"
  commit_if_changed "$ANUBIS_PASS_KEY" "$tmp" && ANUBIS_ANGIE_DIRTY=1
  chown root:root "$ANUBIS_PASS_KEY"; chmod 600 "$ANUBIS_PASS_KEY"
  ANUBIS_PASS_ACTIVE=1
  return 0
}

anubis_write_common() {
  local tmp backlog pass=""
  backlog=$(effective_backlog)
  tmp=$(tmp_file) || return 1
  if (( ANUBIS_PASS_ACTIVE )); then
    pass="
# Pass-cookie edge check (angie-module-njs, ${ANUBIS_PASS_JS}): a browser
# whose Anubis cookie validates goes straight to the backend socket.
# Verdicts cached per token, address, policy epoch and secret (~20k entries).
js_shared_dict_zone zone=anubis_pass:4m timeout=600s evict type=number;
js_import anubis_pass from ${ANUBIS_PASS_JS};
include ${ANUBIS_PASS_KEY};
js_set \$anubis_pass_route anubis_pass.route;
"
  fi
  cat > "$tmp" <<EOF
# Managed by setup.sh (ANUBIS=1).  Anubis listens on a Unix socket; the
# application vhosts listen on the second socket below (see
# conf.d/00-anubis-terminators.conf for the public side).
proxy_headers_hash_max_size 2048;
proxy_headers_hash_bucket_size 128;
${pass}
upstream anubis {
    server unix:${ANUBIS_LISTEN_SOCKET};
    keepalive 64;
}
upstream anubis_backend {
    server unix:${ANUBIS_BACKEND_SOCKET};
    keepalive 64;
}
# Static-only shadow of the application blocks (see the header of
# anubis_render_static_blocks).  Only www-data traverses its directory.
upstream anubis_static {
    server unix:${ANUBIS_STATIC_SOCKET};
    keepalive 64;
}

# Catch-all on the backend socket.  It carries the listen options for every
# vhost moved behind Anubis (nginx takes options from one listen line per
# address): without it the socket kept the 511 default backlog while every
# TCP listener uses somaxconn, and a Unix socket refuses (EAGAIN) instead of
# queueing when the backlog is full, so a burst of new Anubis connections
# turned into 502s.  A Host no protected vhost serves is dropped.
server {
    listen unix:${ANUBIS_BACKEND_SOCKET} default_server backlog=${backlog};
    server_name _;
    return 444;
}

# Anubis is a pure proxy: it does not rewrite application responses.  The
# challenge page keeps Anubis's stock branding and the client's
# Accept-Encoding is passed through, so cached gzip bodies are never inflated
# and no sub_filter runs on the hot path.

# Edge route.  A request the managed policy (botPolicies.yaml) ALLOWs without
# looking at a cookie gains nothing from the Go hop: it goes straight to the
# backend socket with the same headers Anubis would forward.  Mirrors, in
# policy order:
#   allow-good-crawlers  -> backend (first rule, wins over everything below)
#   deny-ai-crawlers     -> Anubis (it answers the denial)
#   empty User-Agent     -> Anubis (challenge)
#   Mozilla              -> Anubis (challenge or pass-cookie check)
#   anything else        -> backend (Anubis default-allow: API clients, cron,
#                           monitors, CLI tools)
# Anubis's own endpoints (/.within.website/) always reach Anubis.  The
# robots/favicon/.well-known ALLOW rules are left to Anubis for browsers:
# they are a handful of requests per visit.
map \$http_user_agent \$anubis_ua_route {
    default                      anubis_backend;
    ""                           anubis;
    "~*(?:${ANUBIS_GOOD_UA_RE})" anubis_backend;
    "~*(?:${ANUBIS_AI_UA_RE})"   anubis;
    "~Mozilla"                   $(anubis_browser_route);
}
map \$uri \$anubis_route {
    "~^/\\.within\\.website/"    anubis;
    default                      \$anubis_ua_route;
}
EOF
  if commit_if_changed "$ANUBIS_COMMON" "$tmp"; then ANUBIS_ANGIE_DIRTY=1; fi
  return 0
}

anubis_write_location() {
  local tmp
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
# Managed by setup.sh (ANUBIS=1).  Included in the TLS terminator only.
# Dot segments are rejected here: Anubis itself answers 500 after its policy
# validation, while the origin answers 400.  Keeping the 400 at the edge
# preserves the documented behaviour and keeps the Anubis log quiet.
if ($request_uri ~* "(?:^|/)(?:\.|%2e){1,2}(?:/|$|%2f)") { return 400; }

# anubis or anubis_backend (upstream names, so no resolver is involved): the
# requests the policy allows without a cookie skip the Go hop (see the edge
# route maps in conf.d/00-anubis-common.conf).
proxy_pass http://$anubis_route;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
# Replace, do not append: $proxy_add_x_forwarded_for keeps whatever the
# client sent, and applications behind a trusted terminator read the
# left-most entry as the visitor address.
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-TLS-SNI-Name $ssl_server_name;
# The backend vhost enforces its own client_max_body_size; the edge must not
# cap every upload at the http-level 11m (XenForo attachments, Chevereto
# uploads and WordPress plugin installs are larger).  Streaming the body
# avoids buffering a big upload to disk here.
client_max_body_size 0;
proxy_request_buffering off;
# Pass the client encoding through.  No sub_filter runs: cached gzip bodies
# stay compressed and the stock Anubis challenge page is served as-is.
proxy_set_header Accept-Encoding $http_accept_encoding;
proxy_connect_timeout 10s;
proxy_send_timeout 360s;
proxy_read_timeout 360s;
proxy_buffering on;
proxy_buffers 32 16k;
proxy_busy_buffers_size 64k;
# Never spool a large response to proxy_temp: the client side drains the
# buffers instead of a disk write and re-read per download.
proxy_max_temp_file_size 0;
EOF
  if commit_if_changed "$ANUBIS_LOCATION" "$tmp"; then ANUBIS_ANGIE_DIRTY=1; fi
  return 0
}

# Real vhosts: every conf.d file with a server_name other than "_" (the two
# default/catch-all files).  Our own generated files are excluded.
anubis_vhost_files() {
  local dir=${1:-/etc/angie/conf.d} f
  for f in "$dir"/*.conf; do
    [[ -f $f ]] || continue
    case ${f##*/} in 00-anubis-*) continue ;; esac
    grep -qE '^[[:space:]]*server_name[[:space:]]+' "$f" || continue
    grep -qE '^[[:space:]]*server_name[[:space:]]+_;' "$f" && continue
    printf '%s\n' "$f"
  done
}

# A vhost that still terminates TLS on 443 needs the migration; a vhost on
# the backend socket is already integrated.
anubis_vhost_needs_migration() {
  awk '
    { code = $0; sub(/#.*/, "", code) }
    code ~ /^[ \t]*listen[ \t]+/ && code ~ /(^|[^0-9])443([^0-9]|$)/ && code ~ /ssl/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

anubis_vhost_integrated() {
  grep -qF "unix:${ANUBIS_BACKEND_SOCKET}" "$1" 2>/dev/null
}

anubis_backup_vhost() {
  local f=$1 dir="${ANUBIS_STATE}/vhosts" dest
  install -d -m 700 "$ANUBIS_STATE" "$dir" || return 1
  dest="${dir}/$(basename "$f").orig"
  [[ -e $dest ]] && return 0
  cp -a "$f" "$dest" || return 1
  return 0
}

# Move the 443 listeners of one vhost to the backend Unix socket, keep every
# other directive (the TLS lines are inert without an ssl listener and make a
# manual rollback trivial), and teach the backend to trust Anubis's
# X-Real-IP.  One `set_real_ip_from`/`real_ip_header` pair per server block.
anubis_integrate_vhost() {
  local f=$1 tmp
  anubis_vhost_needs_migration "$f" || return 0
  anubis_backup_vhost "$f" || return 1
  tmp=$(tmp_file) || return 1
  awk -v sock="unix:${ANUBIS_BACKEND_SOCKET}" '
    function indent_of(s) { if (match(s, /^[ \t]*/)) return substr(s, 1, RLENGTH); return "" }
    function brace_delta(s,   t, n, m) {
      t = s
      n = gsub(/{/, "{", t)
      t = s
      m = gsub(/}/, "}", t)
      return n - m
    }
    {
      line = $0
      code = line
      sub(/#.*/, "", code)
      # server block tracking: real_ip directives are server-scoped
      if (code ~ /^[ \t]*server[ \t]*{/) {
        in_server = 1
        depth = brace_delta(code)
        added_real_ip = 0
        replaced_listen = 0
        print line
        next
      }
      # Drop an existing real-IP configuration: the peer is now the Anubis
      # socket, so the backend must read X-Real-IP from it and never trust a
      # client-supplied X-Forwarded-For (a file-global check used to leave a
      # real_ip_header X-Forwarded-For from any block in place for all of them).
      if (code ~ /^[ \t]*real_ip_header[ \t]+/ || code ~ /^[ \t]*set_real_ip_from[ \t]+unix/) next
      if (code ~ /^[ \t]*listen[ \t]+/ && code ~ /(^|[^0-9])443([^0-9]|$)/ && code ~ /ssl/) {
        # One socket listener replaces every public TLS listener in the
        # block (IPv4 and IPv6); listening on the same socket twice would
        # make nginx bind the path twice.
        if (!replaced_listen) {
          ind = indent_of(line)
          print ind "listen " sock ";"
          replaced_listen = 1
        }
        if (!added_real_ip) {
          print ind "set_real_ip_from unix:;"
          print ind "real_ip_header X-Real-IP;"
          added_real_ip = 1
        }
        next
      }
      if (code ~ /^[ \t]*http2[ \t]+on;/) next
      print line
      if (in_server) {
        depth += brace_delta(code)
        if (depth <= 0) { in_server = 0; added_real_ip = 0; replaced_listen = 0 }
      }
    }
  ' "$f" > "$tmp" || return 1
  if commit_if_changed "$f" "$tmp"; then
    ANUBIS_ANGIE_DIRTY=1
    tune_note "${f##*/}: 443 moved behind Anubis (backend ${ANUBIS_BACKEND_SOCKET})"
  fi
  return 0
}

# Comment out an outer-perimeter guard such as
#   if ($realip_remote_addr != "<edge proxy>") { return 444; }
# in a vhost that is already behind Anubis.  $realip_remote_addr is the
# *direct peer* (before real_ip), so behind the filter it is "unix:" and the
# guard can never pass: every request, including a static-shadow request,
# answers 444 and the terminator reports 502.  The guard is not dropped, it
# moves: anubis_render_terminators copies every server-level guard this
# function commented ("#" + the original line) into the public 443
# terminator, where $realip_remote_addr is again the direct TCP peer.  An
# origin that only accepts its front proxy/WAF stays locked down with Anubis
# on (without the copy it answered anyone on 443), and anubis_deintegrate_vhost
# puts it back when the filter is turned off.  The socket side needs no
# guard: it is 0660 in a 0750 runtime directory.  Idempotent: a guard that is
# already commented is skipped.
# The first commented line carries ANUBIS_GUARD_MARK.  A guard the operator
# commented out by hand looks the same otherwise ("#" at column 0 is what
# nano and most editors' comment toggle write), and re-applying a lockdown
# they retired (an old WAF address) would 444 every visitor, the new edge
# included.  The mark adds no "realip" text, so the one-occurrence checks on
# a disabled vhost still hold.
ANUBIS_GUARD_MARK='  # setup.sh: guard moved to the Anubis terminator'
anubis_disable_realip_guards() {
  local f=$1 tmp
  grep -qE '^[[:space:]]*if[[:space:]]*\(.*\$realip_remote_addr' "$f" 2>/dev/null || return 0
  tmp=$(tmp_file) || return 1
  awk -v mark="$ANUBIS_GUARD_MARK" '
    function brace_delta(s,   t, n, m) {
      t = s; n = gsub(/{/, "{", t)
      t = s; m = gsub(/}/, "}", t)
      return n - m
    }
    {
      code = $0
      sub(/#.*/, "", code)
      if (skipping) {
        print "#" $0
        depth += brace_delta(code)
        if (depth <= 0) skipping = 0
        next
      }
      if (code ~ /^[ \t]*if[ \t]*\(.*\$realip_remote_addr/) {
        print "#" $0 mark
        depth = brace_delta(code)
        if (depth > 0) skipping = 1
        next
      }
      print
    }
  ' "$f" > "$tmp" || return 1
  if commit_if_changed "$f" "$tmp"; then
    ANUBIS_ANGIE_DIRTY=1
    tune_note "${f##*/}: outer \$realip_remote_addr 444 guard moved to the public Anubis terminator (it cannot pass over the socket)"
  fi
  return 0
}

# Build the static-only shadow of every integrated application server block.
#
# The shadow is a mechanical copy of the block (server_name, root, every
# include and location) on its own Unix socket, minus the public listeners and
# TLS directives, plus two server-level guards:
#
#   if ($uri !~* "<static extensions>") { return 404; }
#   if (!-f $request_filename)           { return 404; }
#
# Copying the block is what keeps the application's own rules in charge:
# XenForo's `^~ /internal_data { internal; }`, the dotfile/backup denies,
# `security_root_archives.conf`, exact-match locations and redirects all apply
# exactly as they do on the backend socket.  The guards make every other URI
# (and every miss) a 404, so the terminator falls back to Anubis and nothing
# dynamic can be reached through this socket, even by a local www-data process.
# A block with a server-level `return`/`rewrite` is skipped: its assets are
# redirected, and pushing that redirect through the terminator would loop.
anubis_render_static_blocks() {
  local dir=${1:-/etc/angie/conf.d} out=${2:-$ANUBIS_STATIC_BLOCKS} tmp f moved
  tmp=$(tmp_file) || return 1
  {
    cat <<EOF
# Managed by setup.sh (ANUBIS=1).  Static-only shadow of every protected
# application block.  Public asset files are served here without the Go proxy
# hop; the terminator sends every other URI, and every miss, to Anubis.
# An unknown Host must not fall through to the first shadow's root: answer 404
# so the terminator retries through the filter and selects the right vhost.
server {
    listen unix:${ANUBIS_STATIC_SOCKET} default_server backlog=$(effective_backlog);
    server_name _;
    return 404;
}
EOF
    if (( ANUBIS_STATIC_BYPASS )); then
      for f in $(anubis_vhost_files "$dir"); do
        anubis_vhost_integrated "$f" || continue
        awk -v sock="unix:${ANUBIS_STATIC_SOCKET}" \
            -v gate="${ANUBIS_STATIC_GATE}" -v file="$f" '
          function count_braces(s,   t, n, m) {
            t = s; n = gsub(/{/, "{", t)
            t = s; m = gsub(/}/, "}", t)
            return n - m
          }
          function reset() {
            n = 0; names = 0; has_root = 0; has_listen = 0; redirect = 0
          }
          function flush(   i) {
            if (!(names && has_root && has_listen) || redirect) return
            print ""
            printf "# shadow of %s\n", file
            print "server {"
            print "    listen " sock ";"
            print "    # Public files only: everything else, and every miss, is"
            print "    # a 404 here so the terminator falls back to Anubis."
            printf "    if ($uri !~* \"%s\") { return 404; }\n", gate
            print "    if (!-f $request_filename) { return 404; }"
            for (i = 1; i <= n; i++) print body[i]
            print "}"
          }
          BEGIN { in_block = 0; depth = 0; reset() }
          {
            code = $0
            sub(/#.*/, "", code)
            if (!in_block) {
              if (code ~ /^[ \t]*server[ \t]*\{/) {
                in_block = 1; reset(); depth = count_braces(code)
              }
              next
            }
            d = count_braces(code)
            if (depth + d <= 0) { in_block = 0; depth = 0; flush(); next }
            if (code ~ /^[ \t]*server_name[ \t]+/) {
              v = code; sub(/^[ \t]*server_name[ \t]+/, "", v); sub(/;.*/, "", v)
              sub(/[ \t]+$/, "", v)
              if (v != "" && v !~ /(^| )_($| )/) names = 1
            } else if (code ~ /^[ \t]*root[ \t]+/) {
              has_root = 1
            } else if (code ~ /^[ \t]*listen[ \t]+/) {
              if (code ~ /443/ || index(code, "unix:") > 0) has_listen = 1
            } else if (depth <= 1 && code ~ /^[ \t]*(return|rewrite)[ \t]+/) {
              redirect = 1
            }
            # A public listener and its TLS state do not belong on this socket.
            if (code ~ /^[ \t]*(listen|http2|ssl_|include[ \t]+h5bp\/tls\/)/) {
              depth += d
              next
            }
            body[++n] = $0
            depth += d
          }
        ' "$f"
      done
    fi
  } > "$tmp" || return 1
  local blocks=0
  blocks=$(grep -c '^# shadow of ' "$tmp" 2>/dev/null || true)
  [[ $blocks =~ ^[0-9]+$ ]] || blocks=0
  ANUBIS_STATIC_ACTIVE=0
  if (( blocks > 0 && ANUBIS_STATIC_BYPASS )); then
    ANUBIS_STATIC_ACTIVE=1
  fi
  if (( ! ANUBIS_STATIC_ACTIVE )); then
    if [[ -e $out ]]; then
      moved=$(preserve_to_tmp "$out" || true)
      [[ -n $moved ]] && info "Anubis: no static shadow to serve, moved ${out} to ${moved}"
      ANUBIS_ANGIE_DIRTY=1
    fi
    return 0
  fi
  if commit_if_changed "$out" "$tmp"; then
    ANUBIS_ANGIE_DIRTY=1
    tune_note "Anubis: static-asset shadow generated for ${blocks} vhost(s)"
  fi
  return 0
}

# Build the TLS terminators for every integrated vhost.  A terminator needs
# the server_name and certificate of the backend block; a block without a
# certificate is skipped with a warning (it cannot terminate TLS by itself).
anubis_render_terminators() {
  local dir=${1:-/etc/angie/conf.d} out=${2:-$ANUBIS_TERMINATORS} tmp f found=0 protected=0
  tmp=$(tmp_file) || return 1
  {
    cat <<'EOF'
# Managed by setup.sh (ANUBIS=1).  Public TLS terminators: every request is
# proxied to Anubis, which validates the pass cookie and forwards happy
# traffic to the application vhosts on the backend Unix socket.
EOF
    for f in $(anubis_vhost_files "$dir"); do
      anubis_vhost_integrated "$f" || continue
      found=1
      protected=$(( protected + 1 ))
      awk -v sock="${ANUBIS_BACKEND_SOCKET}" \
          -v static="${ANUBIS_STATIC_ACTIVE}" \
          -v route="${ANUBIS_STATIC_ROUTE}" \
          -v mark="$ANUBIS_GUARD_MARK" \
          -v orig="${ANUBIS_STATE}/vhosts/${f##*/}.orig" '
        function flush(   n, i) {
          if (!integrated) return
          n = split(names, a, " ")
          if (n == 0 || names == "" || names ~ /(^| )_($| )/) return
          if (cert == "" || key == "") {
            # A vhost can inherit its certificate from an http-level include,
            # where this parser cannot see it.  Keep the site reachable with
            # the default certificate (the browser warns) instead of leaving
            # a migrated vhost without a public listener.
            cert = "/etc/angie/ssl/default/fullchain.pem"
            key  = "/etc/angie/ssl/default/privkey.pem"
            printf "# %s: no ssl_certificate in the vhost, using the default certificate\n", FILENAME
          }
          print ""
          print "server {"
          print "    listen      443 ssl;"
          print "    listen [::]:443 ssl;"
          print "    http2 on;"
          print "    server_name " names ";"
          print ""
          print "    include h5bp/tls/ssl_engine.conf;"
          print "    include h5bp/tls/policy_balanced.conf;"
          print "    ssl_certificate     " cert ";"
          print "    ssl_certificate_key " key ";"
          print ""
          if (ng > 0) {
            # The origin lockdown anubis_disable_realip_guards took off the
            # socket-side vhost: this is the public listener now, so the
            # edge-proxy check runs here, before any location (static,
            # /socket/ or the filter) can answer.
            print "    # Origin lockdown carried over from the vhost."
            for (i = 1; i <= ng; i++) print guard[i]
            print ""
          }
          if (ws) {
            # Only for a vhost that has a /socket/ location (XenForo push).
            # The upgrade itself skips the HTTP bot filter; any other request
            # under /socket/ is filtered like a page, or the prefix would be
            # an unchallenged way into the application (WordPress serves
            # /socket/?rest_route= from index.php).  The headers are set here
            # once: h5bp/proxy_ws.conf repeated them, and the duplicate Host
            # made the backend answer 400 to every WebSocket handshake.
            print "    # XenForo push transport: only the WebSocket upgrade skips"
            print "    # the HTTP bot filter."
            print "    location ^~ /socket/ {"
            print "        error_page 418 = @anubis_filter;"
            print "        if ($http_upgrade !~* ^websocket$) { return 418; }"
            print "        proxy_pass http://anubis_backend;"
            print "        proxy_http_version 1.1;"
            print "        proxy_set_header Upgrade $http_upgrade;"
            print "        proxy_set_header Connection $connection_upgrade;"
            print "        proxy_set_header Host $host;"
            print "        proxy_set_header X-Real-IP $remote_addr;"
            print "        proxy_set_header X-Forwarded-For $remote_addr;"
            print "        proxy_set_header X-Forwarded-Proto https;"
            print "        proxy_buffering off;"
            print "        proxy_read_timeout 1h;"
            print "        proxy_send_timeout 1h;"
            print "    }"
            print "    location @anubis_filter {"
            print "        include snippets/anubis-location.conf;"
            print "    }"
            print ""
          }
          if (static) {
            print "    # Static assets that exist in the application root are served by"
            print "    # a static-only shadow of this vhost, without the Go proxy hop."
            print "    # A miss (or an alias/rewrite endpoint) falls back to Anubis."
            print "    location ~* " route " {"
            print "        proxy_pass http://anubis_static;"
            print "        proxy_http_version 1.1;"
            print "        proxy_set_header Connection \"\";"
            print "        proxy_set_header Host $host;"
            print "        proxy_set_header X-Real-IP $remote_addr;"
            print "        proxy_set_header X-Forwarded-For $remote_addr;"
            print "        proxy_set_header X-Forwarded-Proto https;"
            print "        proxy_set_header X-TLS-SNI-Name $ssl_server_name;"
            print "        proxy_connect_timeout 5s;"
            print "        proxy_read_timeout 60s;"
            print "        # Large media (Chevereto originals, video) streams through the"
            print "        # buffers instead of being spooled to proxy_temp on disk."
            print "        proxy_max_temp_file_size 0;"
            print "        # The shadow answers 404 for a miss (or an alias/rewrite"
            print "        # endpoint); intercept it and retry through the filter."
            print "        proxy_intercept_errors on;"
            print "        error_page 404 = @anubis_static_miss;"
            print "    }"
            print "    location @anubis_static_miss {"
            print "        include snippets/anubis-location.conf;"
            print "        # Not a file: the policy challenges browsers here instead"
            print "        # of the static-assets ALLOW (/x.css?rest_route= reached PHP)."
            print "        proxy_set_header X-Anubis-Static-Miss 1;"
            print "    }"
            print ""
          }
          print "    location / {"
          print "        include snippets/anubis-location.conf;"
          print "    }"
          print "}"
        }
        BEGIN {
          in_block = 0; depth = 0
          # Guards that were live before Anubis: a host enabled by a release
          # that did not mark the guards it commented is recognised by the
          # pre-integration copy instead (a guard commented by hand is
          # commented there too, so it is never carried).
          if (orig != "") {
            while ((getline ol < orig) > 0) {
              oc = ol; sub(/#.*/, "", oc)
              if (oc ~ /^[ \t]*if[ \t]*\(.*\$realip_remote_addr/) orig_guard[ol] = 1
            }
            close(orig)
          }
        }
        function count_braces(s,   t, n, m) {
          t = s; n = gsub(/{/, "{", t)
          t = s; m = gsub(/}/, "}", t)
          return n - m
        }
        {
          code = $0
          sub(/#.*/, "", code)
          if (code ~ /^[ \t]*server[ \t]*{/) {
            in_block = 1; depth = count_braces(code)
            names = ""; cert = ""; key = ""; integrated = 0; ws = 0
            ng = 0; gcap = 0
            next
          }
          if (in_block) {
            # Collect the server-level realip guards anubis_disable_realip_guards
            # commented out ("#" + original line, body included): the first
            # line carries the mark, or (older releases) was live in the
            # pre-integration copy.  A guard inside a location is not
            # lifted: at server level it would cover URIs the vhost never
            # restricted.
            g = $0
            if (!gcap && depth == 1 && g ~ /^#[ \t]*if[ \t]*\(.*\$realip_remote_addr/) {
              gl = substr(g, 2)
              mi = index(gl, mark)
              if (mi > 0) gl = substr(gl, 1, mi - 1)
              if (mi > 0 || (gl in orig_guard)) {
                gstart = ng + 1; gd = 0; gcap = 1
                g = "#" gl
              }
            }
            if (gcap) {
              if (g ~ /^#/) {
                g = substr(g, 2)
                gc = g; sub(/#.*/, "", gc)
                gd += count_braces(gc)
                guard[++ng] = g
                gcap = (gd > 0)
              } else {
                # The commented block ended before its braces closed (an
                # edit by hand): emitting half an if would fail angie -t
                # and roll the whole filter back, so drop that one guard.
                ng = gstart - 1
                gcap = 0
              }
            }
            if (code ~ /^[ \t]*server_name[ \t]+/) {
              v = code
              sub(/^[ \t]*server_name[ \t]+/, "", v)
              sub(/;.*/, "", v)
              sub(/[ \t]+$/, "", v)
              names = (names == "" ? v : names " " v)
            } else if (code ~ /^[ \t]*ssl_certificate[ \t]+/) {
              v = code
              sub(/^[ \t]*ssl_certificate[ \t]+/, "", v)
              sub(/;.*/, "", v)
              cert = v
            } else if (code ~ /^[ \t]*ssl_certificate_key[ \t]+/) {
              v = code
              sub(/^[ \t]*ssl_certificate_key[ \t]+/, "", v)
              sub(/;.*/, "", v)
              key = v
            }
            if (index(code, "unix:" sock) > 0) integrated = 1
            if (code ~ /^[ \t]*location[ \t]+(\^~[ \t]+)?\/socket\//) ws = 1
            depth += count_braces(code)
            if (depth <= 0) { flush(); in_block = 0 }
          }
        }
      ' "$f"
    done
  } > "$tmp" || return 1
  if (( found == 0 )); then
    # No integrated site yet: keep no terminator file at all.
    if [[ -e $out ]]; then
      local moved
      moved=$(preserve_to_tmp "$out" || true)
      [[ -n $moved ]] && info "Removed stale Anubis terminators (moved to ${moved})"
      ANUBIS_ANGIE_DIRTY=1
    fi
    return 0
  fi
  if commit_if_changed "$out" "$tmp"; then
    ANUBIS_ANGIE_DIRTY=1
    tune_note "Anubis: terminators regenerated for ${protected} vhost(s)"
  fi
  return 0
}

# Rebuild the public TLS listener of a vhost that is still behind the filter
# but whose pre-integration copy is gone (the state directory was moved or
# removed by hand, or a release before this one enabled the filter over a
# vhost it had already migrated).  Without this, anubis=no reported success
# while the vhost kept listening on the backend socket: with Anubis stopped
# every site answered 502 until someone restored the file by hand (found on
# the 1.21.37 audit host).
# The inverse of anubis_integrate_vhost: the backend listen becomes the two
# public TLS listeners plus http2, and the two real-IP lines the integration
# added are dropped.  Every guard anubis_disable_realip_guards commented (the
# ones carrying ANUBIS_GUARD_MARK) is live again: the vhost is the public
# listener once more, and leaving the edge-proxy check commented let anyone
# reach the origin on 443 after anubis=no.  A guard commented by hand has no
# mark and stays commented.  Every other directive is left exactly as it is.
#   $1 vhost file.  Returns 0 when the file is no longer integrated.
anubis_deintegrate_vhost() {
  local f=$1 sock="unix:${ANUBIS_BACKEND_SOCKET}" tmp
  anubis_vhost_integrated "$f" || return 0
  tmp=$(tmp_file) || return 1
  awk -v sock="$sock" -v mark="$ANUBIS_GUARD_MARK" '
    function indent_of(s) { if (match(s, /^[ \t]*/)) return substr(s, 1, RLENGTH); return "" }
    function brace_delta(s,   t, n, m) {
      t = s; n = gsub(/{/, "{", t)
      t = s; m = gsub(/}/, "}", t)
      return n - m
    }
    # A marked block is buffered until its braces close; one that ends early
    # (edited by hand) is written back still commented, because half an if
    # would fail angie -t.
    function keep_commented(   i) { for (i = 1; i <= nb; i++) print raw[i]; nb = 0 }
    function uncomment(s,   c, i) {
      raw[++nb] = $0; live[nb] = s
      c = s; sub(/#.*/, "", c)
      bd += brace_delta(c)
      if (bd <= 0) { for (i = 1; i <= nb; i++) print live[i]; nb = 0 }
    }
    {
      if (nb > 0) {
        if ($0 ~ /^#/) { uncomment(substr($0, 2)); next }
        keep_commented()
      }
      if ($0 ~ /^#[ \t]*if[ \t]*\(.*\$realip_remote_addr/ && (mi = index($0, mark)) > 0) {
        bd = 0
        uncomment(substr($0, 2, mi - 2))
        next
      }
      code = $0
      sub(/#.*/, "", code)
      if (code ~ /^[ \t]*listen[ \t]+/ && index(code, sock) > 0) {
        ind = indent_of($0)
        print ind "listen 443 ssl;"
        print ind "listen [::]:443 ssl;"
        print ind "http2 on;"
        next
      }
      if (code ~ /^[ \t]*set_real_ip_from[ \t]+unix:;[ \t]*$/) next
      if (code ~ /^[ \t]*real_ip_header[ \t]+X-Real-IP;[ \t]*$/) next
      print
    }
    END { keep_commented() }
  ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
  if ! commit_if_changed "$f" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  ANUBIS_ANGIE_DIRTY=1
  tune_note "${f##*/}: rebuilt the public TLS listener (pre-integration copy was missing)"
  return 0
}

# Restore every vhost this module migrated.  The live file is moved to /tmp
# first, so an operator edit made while Anubis was enabled is not lost.
anubis_restore_vhosts() {
  local live_dir=${1:-/etc/angie/conf.d} dir=${2:-${ANUBIS_STATE}/vhosts} orig name live moved restored=0 rebuilt=0 rc=0
  local -a originals=()
  if [[ -d $dir ]]; then
    for orig in "$dir"/*.orig; do
      [[ -f $orig ]] || continue
      name=${orig##*/}; name=${name%.orig}
      live="${live_dir}/${name}"
      if [[ -f $live ]]; then
        moved=$(preserve_to_tmp "$live" || true)
        [[ -n $moved ]] && info "Anubis: moved the integrated ${name} to ${moved}"
      fi
      cp -a "$orig" "$live" || { warn "Could not restore ${live}"; rc=1; continue; }
      restored=$(( restored + 1 ))
      ANUBIS_ANGIE_DIRTY=1
      originals+=("$name")
    done
  fi
  if (( restored > 0 )); then
    info "Anubis: restored ${restored} vhost(s) to their pre-integration form"
  fi
  # A vhost can still be integrated after the loop above: its .orig file was
  # lost with the state directory.  Leaving it on the backend socket while
  # the filter stops makes the site unreachable, so rebuild the public
  # listener instead of reporting a disable that did not happen.
  for live in "$live_dir"/*.conf; do
    [[ -f $live ]] || continue
    case ${live##*/} in 00-anubis-*) continue ;; esac
    anubis_vhost_integrated "$live" || continue
    name=${live##*/}
    [[ " ${originals[*]} " == *" ${name} "* ]] && continue
    warn "Anubis: ${name} is still behind the filter but its pre-integration copy is missing; rebuilding the public listener"
    if anubis_deintegrate_vhost "$live"; then
      rebuilt=$(( rebuilt + 1 ))
    else
      warn "Anubis: could not rebuild ${live}; restore it from /tmp before stopping the filter"
      rc=1
    fi
  done
  if (( rebuilt > 0 )); then
    info "Anubis: rebuilt ${rebuilt} vhost listener(s) from the integrated form"
  fi
  return "$rc"
}

# Remove the generated Angie files (moving them to /tmp, never deleting).
anubis_remove_angie_files() {
  local f moved
  anubis_remove_pass_edge
  for f in "$ANUBIS_TERMINATORS" "$ANUBIS_COMMON" "$ANUBIS_LOCATION" \
           "$ANUBIS_STATIC_BLOCKS" "$ANUBIS_TMPFILES"; do
    [[ -e $f ]] || continue
    moved=$(preserve_to_tmp "$f" || true)
    [[ -n $moved ]] && info "Anubis: moved ${f} to ${moved}"
    ANUBIS_ANGIE_DIRTY=1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Enable / disable
# ---------------------------------------------------------------------------
anubis_install_service() {
  anubis_create_user || return 1
  anubis_install_binary || return 1
  anubis_write_env || true
  anubis_write_policy || return 1
  anubis_write_unit || return 1
  anubis_write_pass_edge
  anubis_write_common || return 1
  anubis_write_location || return 1
  anubis_write_tmpfiles || return 1
  return 0
}

anubis_start() {
  systemctl enable anubis >/dev/null 2>&1 || true
  # A previous failed start (bad policy/permission) leaves the unit in
  # start-limit state; clear it or every later start is refused.
  systemctl reset-failed anubis >/dev/null 2>&1 || true
  if systemctl is-active --quiet anubis; then
    # A plain --optimize must not drop the in-memory challenge store (and the
    # short-lived verification cookies) when nothing about the service changed.
    if (( ANUBIS_SERVICE_DIRTY == 0 )); then
      [[ -S $ANUBIS_LISTEN_SOCKET ]] && return 0
    fi
    systemctl restart anubis || return 1
  else
    systemctl start anubis || return 1
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S $ANUBIS_LISTEN_SOCKET ]] && return 0
    sleep 0.5
  done
  warn "Anubis did not create ${ANUBIS_LISTEN_SOCKET}"
  return 1
}

# Enable Anubis for every site on the host.  Validates the final Angie tree
# and rolls this run's changes back on failure; the caller performs the single
# reload.  Returns 1 on failure.
anubis_enable() {
  local f rc=0 changed=0
  ANUBIS_SUMMARY=""
  anubis_install_service || { ANUBIS_FAILED="installation"; return 1; }
  anubis_join_www_group || { ANUBIS_FAILED="socket group"; return 1; }
  for f in $(anubis_vhost_files); do
    if anubis_vhost_needs_migration "$f"; then
      changed=1
    fi
    anubis_integrate_vhost "$f" || rc=1
    # Also for a vhost integrated by an older release: an outer-perimeter
    # `if ($realip_remote_addr ...) { return 444; }` cannot pass over the
    # Unix socket and turned every page into a 502 through the filter.
    anubis_vhost_integrated "$f" && { anubis_disable_realip_guards "$f" || rc=1; }
  done
  anubis_render_static_blocks || rc=1
  anubis_render_terminators || rc=1
  if (( rc != 0 )); then
    ANUBIS_FAILED="vhost migration"
    return 1
  fi
  if ! anubis_start; then
    # The vhosts are already pointing at a socket that has no listener; a
    # later reload or reboot would answer 502 for every site.  Put the
    # original tree back before returning, as the angie -t failure does.
    warn "Anubis did not start; restoring the direct-TLS vhosts"
    anubis_restore_vhosts
    anubis_remove_angie_files
    /usr/sbin/angie -t >/dev/null 2>&1 || warn "Angie configuration is invalid after rollback"
    ANUBIS_FAILED="service start"
    return 1
  fi
  local t
  t=$(tmp_file) || return 1
  if ! /usr/sbin/angie -t >"$t" 2>&1; then
    # A vhost construct the shadow cannot reproduce must not cost the host its
    # bot filter: drop the fast path for this run, regenerate, and test again.
    if (( ANUBIS_STATIC_ACTIVE )); then
      warn "Anubis: Angie rejected the static-asset shadow; retrying without it"
      ANUBIS_STATIC_BYPASS=0
      ANUBIS_STATIC_ACTIVE=0
      # Keep the operator's persisted choice: the host failed this run, not
      # the request.  The next --optimize retries and reports again.
      ANUBIS_STATIC_PERSIST=0
      anubis_render_static_blocks >/dev/null 2>&1 || true
      anubis_render_terminators >/dev/null 2>&1 || true
    fi
    if ! /usr/sbin/angie -t >"$t" 2>&1 && (( ANUBIS_PASS_ACTIVE )); then
      warn "Anubis: Angie rejected the njs pass-cookie check; browsers stay on the Anubis hop"
      anubis_remove_pass_edge
      ANUBIS_PASS_ACTIVE=0
      anubis_write_common >/dev/null 2>&1 || true
    fi
    if ! /usr/sbin/angie -t >"$t" 2>&1; then
      warn "Anubis: Angie rejected the integrated configuration; rolling back"
      sed 's/^/  /' "$t" >&2 || true
      anubis_restore_vhosts
      anubis_remove_angie_files
      /usr/sbin/angie -t >/dev/null 2>&1 || warn "Angie configuration is still invalid after rollback"
      ANUBIS_FAILED="angie -t"
      return 1
    fi
  fi
  install -d -m 700 "$ANUBIS_STATE"
  : > "$(anubis_marker)"
  persist_tuning_var ANUBIS 1
  if (( ANUBIS_STATIC_PERSIST )); then
    persist_tuning_var ANUBIS_STATIC_BYPASS "$ANUBIS_STATIC_BYPASS"
  fi
  local static_note=""
  if (( ANUBIS_STATIC_ACTIVE )); then
    static_note=", static assets bypass the proxy"
  fi
  if (( ANUBIS_PASS_ACTIVE )); then
    static_note+=", pass cookies checked in Angie"
  fi
  ANUBIS_SUMMARY="Anubis: enabled (difficulty 4, Unix sockets, policy ${ANUBIS_POLICY}; $(anubis_vhost_files | wc -l) vhost(s) protected${static_note}; $(anubis_runtime_summary))"
  if (( changed )); then ANUBIS_ANGIE_DIRTY=1; fi
  return 0
}

anubis_disable() {
  ANUBIS_SUMMARY=""
  if ! anubis_restore_vhosts; then
    # A vhost is still behind the filter and could not be rebuilt: removing
    # the terminators now would answer 502 for that site, so leave the whole
    # integration in place and report the failure instead of a false success.
    ANUBIS_FAILED="the pre-integration copy of a vhost is missing and its public listener could not be rebuilt"
    ANUBIS_SUMMARY="Anubis: disable failed; the filter was left running"
    return 1
  fi
  anubis_remove_angie_files
  # Do not stop the service yet.  Angie keeps serving its in-memory
  # configuration (terminators proxy_pass to Anubis) until it is reloaded
  # after this function returns, so stopping here would answer 502 for every
  # site until the reload.  optimize_angie calls anubis_finish_disable after
  # a successful reload; a failed tune keeps the filter running.
  ANUBIS_STOP_PENDING=1
  systemctl is-active --quiet angie 2>/dev/null || anubis_finish_disable
  if [[ -e $ANUBIS_STATE ]]; then
    local moved
    moved=$(preserve_to_tmp "$ANUBIS_STATE" || true)
    [[ -n $moved ]] && info "Anubis: state moved to ${moved}"
  fi
  persist_tuning_var ANUBIS 0
  ANUBIS_ANGIE_DIRTY=1
  ANUBIS_SUMMARY="Anubis: disabled; vhosts restored to direct TLS and the service stops after the Angie reload"
  return 0
}

# Complete a pending disable once Angie has loaded the direct-TLS vhosts.
anubis_finish_disable() {
  (( ANUBIS_STOP_PENDING )) || return 0
  ANUBIS_STOP_PENDING=0
  # reload is asynchronous: old workers may still be finishing requests that
  # proxy to the filter.  Give them a moment so the stop cannot cut one off
  # (one 502 in 420 requests was measured without this drain).
  if systemctl is-active --quiet angie 2>/dev/null; then
    sleep 1
  fi
  systemctl stop anubis 2>/dev/null || warn "Could not stop anubis"
  systemctl disable anubis >/dev/null 2>&1 || true
  anubis_leave_www_group
  return 0
}

# Entry point used by the installer (--angie anubis=yes), by --optimize
# (anubis=yes/no or the persisted ANUBIS=1) and by --domain through its
# trailing optimize pass.
anubis_apply() {
  ANUBIS_FAILED=""
  if anubis_wanted; then
    anubis_enable
    return
  fi
  # Disable only a state this module created.  A host that already carries an
  # operator-installed Anubis unit (or one integrated by hand) is left alone.
  if anubis_managed; then
    anubis_disable
    return
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Lifecycle for purge / restore / diagnostics
# ---------------------------------------------------------------------------
# --purge angie: restore the vhosts and remove the generated Angie files
# before stopping Anubis.  Leaving the vhosts on a socket whose service is
# stopped makes a later `systemctl start angie` (boot, manual start) answer
# 502 for every site.  The binary, unit, policy and state (including the
# .orig vhost backups) stay, so `--optimize anubis=yes` re-enables it.
anubis_purge_stop() {
  anubis_managed || return 0
  anubis_restore_vhosts || warn "Anubis: a vhost could not be restored; check the site before starting Angie"
  anubis_remove_angie_files
  systemctl stop anubis >/dev/null 2>&1 || true
  systemctl disable anubis >/dev/null 2>&1 || true
  anubis_leave_www_group
  info "Anubis stopped, vhosts restored (configuration kept; --optimize anubis=yes re-enables it)"
}

# Return the host to a state without Anubis: restore the vhosts, remove the
# managed files and the binary.  Used by the audit baseline restore and by
# `--optimize anubis=no` when the operator wants it gone entirely.
anubis_remove_all() {
  anubis_restore_vhosts || warn "Anubis: a vhost could not be restored; check the site before starting Angie"
  anubis_remove_angie_files
  systemctl stop anubis >/dev/null 2>&1 || true
  systemctl disable anubis >/dev/null 2>&1 || true
  rm -f "$ANUBIS_UNIT" "$ANUBIS_BIN" "$ANUBIS_ENV" "$ANUBIS_POLICY" 2>/dev/null || true
  rm -rf "$ANUBIS_ETC" "$ANUBIS_STATE" /run/anubis /run/angie-static /var/lib/anubis /var/cache/anubis 2>/dev/null || true
  if id "$ANUBIS_USER" >/dev/null 2>&1; then
    userdel "$ANUBIS_USER" >/dev/null 2>&1 || true
  fi
  anubis_leave_www_group
  # userdel leaves a group that still has a member; drop an empty setup group.
  if getent group "$ANUBIS_USER" >/dev/null 2>&1; then
    groupdel "$ANUBIS_USER" >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload || true
  ANUBIS_ANGIE_DIRTY=1
  return 0
}

anubis_verify() {
  local ok=0
  command -v "$ANUBIS_BIN" >/dev/null 2>&1 || { warn "Anubis: binary missing"; return 1; }
  systemctl is-active --quiet anubis || { warn "Anubis: service is not active"; ok=1; }
  [[ -S $ANUBIS_LISTEN_SOCKET ]] || { warn "Anubis: ${ANUBIS_LISTEN_SOCKET} is missing"; ok=1; }
  [[ -S $ANUBIS_BACKEND_SOCKET ]] || { warn "Anubis: ${ANUBIS_BACKEND_SOCKET} is missing"; ok=1; }
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'User-Agent: Mozilla/5.0 (setup.sh probe)' \
    --resolve "$(hostname -f 2>/dev/null || hostname):443:127.0.0.1" \
    "https://$(hostname -f 2>/dev/null || hostname)/" 2>/dev/null || true)
  # A hostname without a vhost answers from the catch-all; the probe is only
  # a liveness hint, so a 4xx/5xx is not fatal here.
  [[ -n $code ]] || warn "Anubis: HTTPS probe produced no response (check the terminator for this host)"
  return "$ok"
}

anubis_status_line() {
  if anubis_managed; then
    printf 'enabled (v%s, %s)' "$(anubis_installed_version || echo '?')" "$ANUBIS_BACKEND_SOCKET"
  elif [[ -f $ANUBIS_UNIT ]]; then
    printf 'installed, disabled'
  else
    printf 'not installed'
  fi
}
