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
ANUBIS_TMPFILES="/etc/tmpfiles.d/angie-anubis.conf"
# Set when this run changed anything under /etc/angie; the caller reloads once.
ANUBIS_ANGIE_DIRTY=0
ANUBIS_SUMMARY=""
ANUBIS_FAILED=""
ANUBIS_SERVICE_DIRTY=0

anubis_marker() { printf '%s/enabled' "$ANUBIS_STATE"; }

anubis_managed() { [[ -f "$(anubis_marker)" ]]; }

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
    [[ -z ${SETUP_ANUBIS_SHA256:-} ]] && want_sha=""
  fi
  want="v${ANUBIS_VERSION}"
  current=$(anubis_installed_version || true)
  [[ $current == "$want" ]] && return 0

  url="https://github.com/TecharoHQ/anubis/releases/download/v${ANUBIS_VERSION}/anubis-${ANUBIS_VERSION}-linux-${arch}.tar.gz"
  tmp=$(tmp_dir anubis.XXXXXX) || return 1
  info "Downloading Anubis ${ANUBIS_VERSION} (${arch} static binary)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "${tmp}/anubis.tar.gz" "$url" || return 1
  else
    wget -q -O "${tmp}/anubis.tar.gz" "$url" || return 1
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
METRICS_BIND=${ANUBIS_METRICS}
METRICS_BIND_NETWORK=tcp
POLICY_FNAME=${ANUBIS_POLICY}
# WARN keeps one journal line per challenge and none per proxied request;
# INFO on a busy site fills the journal and costs CPU.
SLOG_LEVEL=WARN
# Anubis creates the listening socket as its own user; Angie workers run as
# www-data and must be able to connect to it.
SOCKET_MODE=0666
HS512_SECRET=${secret}
EOF
  if commit_if_changed "$ANUBIS_ENV" "$tmp"; then ANUBIS_SERVICE_DIRTY=1; fi
  chmod 600 "$ANUBIS_ENV"; chown root:"$ANUBIS_USER" "$ANUBIS_ENV"
  return 0
}

# A lean policy: allow search engines and infrastructure routes, deny the
# crawlers that ignore robots.txt, and challenge anything that claims to be a
# browser.  Unmatched clients are allowed (Anubis default-allow), which keeps
# API clients, cron jobs and CLI tools working; a site that wants to challenge
# every client can add a catch-all CHALLENGE rule.
anubis_write_policy() {
  local tmp
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
# Managed by setup.sh (ANUBIS=1).  Rules are evaluated in order.
bots:
  - name: allow-good-crawlers
    user_agent_regex: (?i)(Googlebot|Google-InspectionTool|bingbot|DuckDuckBot|Applebot|Baiduspider|YandexBot|Qwantbot|Kagi|Marginalia|MojeekBot|InternetArchive|Arquivo)
    action: ALLOW
  - name: deny-ai-crawlers
    user_agent_regex: (?i)(GPTBot|ChatGPT-User|OAI-SearchBot|ClaudeBot|Claude-Web|anthropic-ai|CCBot|Google-Extended|Bytespider|Amazonbot|Applebot-Extended|meta-externalagent|PerplexityBot|Diffbot|Omgili|ImagesiftBot|YouBot|cohere-ai|AI2Bot)
    action: DENY
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
  if commit_if_changed "$ANUBIS_POLICY" "$tmp"; then ANUBIS_SERVICE_DIRTY=1; fi
  chown root:"$ANUBIS_USER" "$ANUBIS_POLICY"
  chmod 640 "$ANUBIS_POLICY"
  return 0
}

anubis_write_unit() {
  local tmp
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
[Unit]
Description=Anubis bot filter proxy (Angie)
Documentation=https://anubis.techaro.lol/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anubis
Group=anubis
EnvironmentFile=/etc/anubis/anubis.env
ExecStart=/usr/local/bin/anubis
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RuntimeDirectory=anubis
RuntimeDirectoryMode=0755
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
# setup.sh: directory for the Anubis backend Unix socket.
d /run/angie 0750 root anubis -
EOF
  if commit_if_changed "$ANUBIS_TMPFILES" "$tmp"; then ANUBIS_ANGIE_DIRTY=1; fi
  systemd-tmpfiles --create "$ANUBIS_TMPFILES" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# Angie configuration
# ---------------------------------------------------------------------------
anubis_write_common() {
  local tmp
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<EOF
# Managed by setup.sh (ANUBIS=1).  Anubis listens on a Unix socket; the
# application vhosts listen on the second socket below (see
# conf.d/00-anubis-terminators.conf for the public side).
proxy_headers_hash_max_size 2048;
proxy_headers_hash_bucket_size 128;

upstream anubis {
    server unix:${ANUBIS_LISTEN_SOCKET};
    keepalive 64;
}
upstream anubis_backend {
    server unix:${ANUBIS_BACKEND_SOCKET};
    keepalive 64;
}

# 1 when the request carries Anubis's signed pass token.  The cookie holds a
# ULID (no dots) before the challenge is solved and a three-part JWT after,
# so the value shape separates the two states without knowing the per-host
# cookie name.  Used only to keep the challenge page unfiltered/uncompressed;
# Anubis itself validates the token on every request.
map \$http_cookie \$anubis_pass {
    default 0;
    "~*anubis-cookie-verification[^=]*=[^;]*\.[^;]*\.[^;]*" 1;
}
map \$anubis_pass \$anubis_upstream_accept_encoding {
    default "";
    1       \$http_accept_encoding;
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

proxy_pass http://anubis;
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
# The challenge page must reach sub_filter uncompressed.  A visitor that
# already holds the pass cookie keeps its own Accept-Encoding, so application
# responses (including the gzip stored by the FastCGI guest cache) pass
# through untouched.
proxy_set_header Accept-Encoding $anubis_upstream_accept_encoding;
proxy_connect_timeout 10s;
proxy_send_timeout 360s;
proxy_read_timeout 360s;
proxy_buffering on;
proxy_buffers 32 16k;
proxy_busy_buffers_size 64k;

# Branding-free challenge page.  Every literal below exists only in Anubis
# HTML, so an application page (or its own <footer>/<details>) is never
# touched.  SETUP_ANUBIS_BRANDING=1 keeps the stock page.
sub_filter_once on;
sub_filter "<title>Making sure you&#39;re not a bot!</title>" "<title>Verifying your browser</title>";
sub_filter "<h1 id=\"title\" class=\"centered-div\">Making sure you&#39;re not a bot!</h1>" "<h1 id=\"title\" class=\"centered-div\">Verifying your browser</h1>";
sub_filter "<p id=\"status\">Loading...</p>" "<p id=\"status\">Checking your connection...</p>";
sub_filter "<img id=\"image\" style=\"width:100%;max-width:256px;\"" "<img id=\"image\" hidden style=\"width:100%;max-width:256px;\"";
sub_filter "<details><p>This is a measure" "<details hidden><p>This is a measure";
sub_filter "<footer><div class=\"centered-div\">" "<footer hidden><div class=\"centered-div\">";
EOF
  if [[ ${SETUP_ANUBIS_BRANDING:-0} == 1 ]]; then
    # Drop the sub_filter block, keeping the proxy directives above it.
    sed -i '/^# Branding-free challenge page/,$d' "$tmp"
  fi
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
  grep -qE '^[[:space:]]*listen[[:space:]]+[^;]*443[^;]*ssl' "$1"
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
        print line
        next
      }
      # Drop an existing real-IP configuration: the peer is now the Anubis
      # socket, so the backend must read X-Real-IP from it and never trust a
      # client-supplied X-Forwarded-For (a file-global check used to leave a
      # real_ip_header X-Forwarded-For from any block in place for all of them).
      if (code ~ /^[ \t]*real_ip_header[ \t]+/ || code ~ /^[ \t]*set_real_ip_from[ \t]+unix/) next
      if (code ~ /^[ \t]*listen[ \t]+/ && code ~ /443/ && code ~ /ssl/) {
        # IPv6 listener is redundant once the public side is the terminator.
        if (code ~ /\[::\]/) next
        ind = indent_of(line)
        print ind "listen " sock ";"
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
        if (depth <= 0) { in_server = 0; added_real_ip = 0 }
      }
    }
  ' "$f" > "$tmp" || return 1
  if commit_if_changed "$f" "$tmp"; then
    ANUBIS_ANGIE_DIRTY=1
    tune_note "${f##*/}: 443 moved behind Anubis (backend ${ANUBIS_BACKEND_SOCKET})"
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
      awk -v sock="${ANUBIS_BACKEND_SOCKET}" '
        function flush(   n) {
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
          print "    # XenForo push transport: keep the WebSocket upgrade out of"
          print "    # the HTTP bot filter."
          print "    location /socket/ {"
          print "        include h5bp/proxy_ws.conf;"
          print "        proxy_pass http://anubis_backend;"
          print "        proxy_set_header Host $host;"
          print "        proxy_set_header X-Real-IP $remote_addr;"
          print "        proxy_set_header X-Forwarded-For $remote_addr;"
          print "        proxy_set_header X-Forwarded-Proto https;"
          print "    }"
          print ""
          print "    location / {"
          print "        include snippets/anubis-location.conf;"
          print "    }"
          print "}"
        }
        BEGIN { in_block = 0; depth = 0 }
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
            names = ""; cert = ""; key = ""; integrated = 0
            next
          }
          if (in_block) {
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

# Restore every vhost this module migrated.  The live file is moved to /tmp
# first, so an operator edit made while Anubis was enabled is not lost.
anubis_restore_vhosts() {
  local live_dir=${1:-/etc/angie/conf.d} dir=${2:-${ANUBIS_STATE}/vhosts} orig name live moved restored=0
  [[ -d $dir ]] || return 0
  for orig in "$dir"/*.orig; do
    [[ -f $orig ]] || continue
    name=${orig##*/}; name=${name%.orig}
    live="${live_dir}/${name}"
    if [[ -f $live ]]; then
      moved=$(preserve_to_tmp "$live" || true)
      [[ -n $moved ]] && info "Anubis: moved the integrated ${name} to ${moved}"
    fi
    cp -a "$orig" "$live" || { warn "Could not restore ${live}"; continue; }
    restored=$(( restored + 1 ))
    ANUBIS_ANGIE_DIRTY=1
  done
  if (( restored > 0 )); then
    info "Anubis: restored ${restored} vhost(s) to their pre-integration form"
  fi
  return 0
}

# Remove the generated Angie files (moving them to /tmp, never deleting).
anubis_remove_angie_files() {
  local f moved
  for f in "$ANUBIS_TERMINATORS" "$ANUBIS_COMMON" "$ANUBIS_LOCATION" "$ANUBIS_TMPFILES"; do
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
  anubis_write_common || return 1
  anubis_write_location || return 1
  anubis_write_tmpfiles || return 1
  return 0
}

anubis_start() {
  systemctl enable anubis >/dev/null 2>&1 || true
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
  for f in $(anubis_vhost_files); do
    if anubis_vhost_needs_migration "$f"; then
      changed=1
    fi
    anubis_integrate_vhost "$f" || rc=1
  done
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
    warn "Anubis: Angie rejected the integrated configuration; rolling back"
    sed 's/^/  /' "$t" >&2 || true
    anubis_restore_vhosts
    anubis_remove_angie_files
    /usr/sbin/angie -t >/dev/null 2>&1 || warn "Angie configuration is still invalid after rollback"
    ANUBIS_FAILED="angie -t"
    return 1
  fi
  install -d -m 700 "$ANUBIS_STATE"
  : > "$(anubis_marker)"
  persist_tuning_var ANUBIS 1
  ANUBIS_SUMMARY="Anubis: enabled (difficulty 4, Unix sockets, policy ${ANUBIS_POLICY}; $(anubis_vhost_files | wc -l) vhost(s) protected)"
  if (( changed )); then ANUBIS_ANGIE_DIRTY=1; fi
  return 0
}

anubis_disable() {
  ANUBIS_SUMMARY=""
  anubis_restore_vhosts || true
  anubis_remove_angie_files
  if systemctl is-active --quiet anubis 2>/dev/null; then
    systemctl stop anubis || warn "Could not stop anubis"
  fi
  systemctl disable anubis >/dev/null 2>&1 || true
  if [[ -e $ANUBIS_STATE ]]; then
    local moved
    moved=$(preserve_to_tmp "$ANUBIS_STATE" || true)
    [[ -n $moved ]] && info "Anubis: state moved to ${moved}"
  fi
  persist_tuning_var ANUBIS 0
  ANUBIS_ANGIE_DIRTY=1
  ANUBIS_SUMMARY="Anubis: disabled; vhosts restored to direct TLS and the service stopped"
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
  anubis_restore_vhosts || true
  anubis_remove_angie_files
  systemctl stop anubis >/dev/null 2>&1 || true
  systemctl disable anubis >/dev/null 2>&1 || true
  info "Anubis stopped, vhosts restored (configuration kept; --optimize anubis=yes re-enables it)"
}

# Return the host to a state without Anubis: restore the vhosts, remove the
# managed files and the binary.  Used by the audit baseline restore and by
# `--optimize anubis=no` when the operator wants it gone entirely.
anubis_remove_all() {
  anubis_restore_vhosts || true
  anubis_remove_angie_files
  systemctl stop anubis >/dev/null 2>&1 || true
  systemctl disable anubis >/dev/null 2>&1 || true
  rm -f "$ANUBIS_UNIT" "$ANUBIS_BIN" "$ANUBIS_ENV" "$ANUBIS_POLICY" 2>/dev/null || true
  rm -rf "$ANUBIS_ETC" "$ANUBIS_STATE" /run/anubis /var/lib/anubis /var/cache/anubis 2>/dev/null || true
  if id "$ANUBIS_USER" >/dev/null 2>&1; then
    userdel "$ANUBIS_USER" >/dev/null 2>&1 || true
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
