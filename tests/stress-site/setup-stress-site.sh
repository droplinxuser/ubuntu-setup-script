#!/usr/bin/env bash
# Deploy the local full-stack stress site on a machine provisioned by setup.sh.
# It intentionally uses the default demo/temp MariaDB credentials from the
# README examples; override with STRESS_DB_PASS for anything else.
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

DOMAIN=${DOMAIN:-stress.invalid}
ROOT="/var/www/${DOMAIN}/public"
CERTDIR="/etc/angie/ssl/${DOMAIN}"
LOG_DIR=/var/www/logs/angie
NODE_LOG_DIR=/var/www/logs/nodejs
GIF_LOG_DIR=/var/www/logs/gifsicle
NODE_DIR=/opt/stress-node
PHP_BIN=${PHP_BIN:-$(command -v php || true)}
if [[ -n $PHP_BIN && -x $PHP_BIN ]]; then
  PHP_VER=$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
else
  PHP_VER=$(ls -1 /etc/php 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -n1)
fi
[[ -n ${PHP_VER:-} ]] || { echo "no PHP-FPM installation found" >&2; exit 1; }
# The stress seeder is a CLI script; install the matching CLI only for this
# optional test harness, not for the production XenForo profile.
if [[ -z ${PHP_BIN:-} || ! -x $PHP_BIN ]]; then
  apt-get install -y --no-install-recommends "php${PHP_VER}-cli" >/dev/null
  PHP_BIN=$(command -v php)
fi
FPM_SVC="php${PHP_VER}-fpm"
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# PHP-FPM clears the environment, so persist the same connection settings that
# the seeder uses.  The web pages merge this file in public/config.php.
export STRESS_DOMAIN="$DOMAIN"
export STRESS_DB_HOST=${STRESS_DB_HOST:-localhost}
export STRESS_DB_NAME=${STRESS_DB_NAME:-stress_test}
export STRESS_DB_USER=${STRESS_DB_USER:-demo}
export STRESS_DB_PASS=${STRESS_DB_PASS:-temp}
export STRESS_VALKEY_HOST=${STRESS_VALKEY_HOST:-127.0.0.1}
export STRESS_VALKEY_PORT=${STRESS_VALKEY_PORT:-6379}
export STRESS_VALKEY_SOCKET=${STRESS_VALKEY_SOCKET:-/run/valkey/valkey.sock}
export STRESS_ELASTIC_URL=${STRESS_ELASTIC_URL:-http://127.0.0.1:9200}
export STRESS_NODE_URL=${STRESS_NODE_URL:-http://127.0.0.1:3100/}

"$PHP_BIN" -r '
$keys = [
    "STRESS_DB_HOST", "STRESS_DB_NAME", "STRESS_DB_USER", "STRESS_DB_PASS",
    "STRESS_VALKEY_HOST", "STRESS_VALKEY_PORT", "STRESS_VALKEY_SOCKET",
    "STRESS_ELASTIC_URL", "STRESS_NODE_URL",
];
$out = [];
foreach ($keys as $key) {
    $value = getenv($key);
    if ($value !== false) {
        $out[$key] = $value;
    }
}
file_put_contents("/etc/stress-site-config.json", json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
'
chown root:www-data /etc/stress-site-config.json
chmod 640 /etc/stress-site-config.json

install -d -m 750 -o www-data -g www-data "$LOG_DIR" "$NODE_LOG_DIR" "$GIF_LOG_DIR"

for svc in angie "$FPM_SVC" mariadb valkey-server elasticsearch; do
  systemctl is-active --quiet "$svc" || {
    echo "service ${svc} is not active; run setup.sh first" >&2
    exit 1
  }
done

# ---------------------------------------------------------------------------
# Certificate
# ---------------------------------------------------------------------------
mkdir -p "$CERTDIR"
chmod 700 "$CERTDIR"
if [[ ! -s "${CERTDIR}/fullchain.pem" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 397 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN}" \
    -keyout "${CERTDIR}/privkey.pem" \
    -out "${CERTDIR}/fullchain.pem" >/dev/null 2>&1
  chmod 600 "${CERTDIR}/privkey.pem"
  chmod 644 "${CERTDIR}/fullchain.pem"
fi

# ---------------------------------------------------------------------------
# Application files
# ---------------------------------------------------------------------------
install -d -m 755 "$ROOT" "${ROOT}/assets"
cp -a "${HERE}/public/." "$ROOT/"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +

install -d -m 755 "$NODE_DIR"
cp -a "${HERE}/node/server.js" "$NODE_DIR/server.js"
chown -R www-data:www-data "$NODE_DIR"

# ---------------------------------------------------------------------------
# Node.js systemd service
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/stress-node.service <<'EOF'
[Unit]
Description=Full-stack stress Node.js service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/stress-node
Environment=PORT=3100
Environment=WORKERS=8
ExecStart=/usr/bin/node /opt/stress-node/server.js
Restart=on-failure
RestartSec=2
LimitNOFILE=524288
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/stress-node /var/www/logs/nodejs
StandardOutput=append:/var/www/logs/nodejs/nodejs.log
StandardError=append:/var/www/logs/nodejs/nodejs.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now stress-node.service
systemctl restart stress-node.service

# ---------------------------------------------------------------------------
# PHP-FPM settings used by the stress harness
# ---------------------------------------------------------------------------
POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
FPM_CHANGED=0
STRESS_STATE_DIR=/var/lib/stress-site
FPM_STATE="${STRESS_FPM_STATE:-${STRESS_STATE_DIR}/fpm-max-requests}"
if [[ -f $POOL ]]; then
  mkdir -p "$STRESS_STATE_DIR"
  # Save the production value once.  run-stress.sh restores it in an EXIT
  # trap, so an interrupted or completed suite does not leave the live pool
  # with worker recycling disabled.
  if [[ ! -f $FPM_STATE ]]; then
    original_max=$(awk -F= '/^[[:space:]]*pm\.max_requests[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$POOL")
    [[ -n $original_max ]] || original_max=NONE
    {
      printf 'POOL=%s\n' "$POOL"
      printf 'FPM_SVC=%s\n' "$FPM_SVC"
      printf 'ORIGINAL_MAX_REQUESTS=%s\n' "$original_max"
    } > "$FPM_STATE"
    chmod 600 "$FPM_STATE"
    echo "Saved original pm.max_requests=${original_max} to ${FPM_STATE}" >&2
  fi
  # The status path needs a .php extension: the pool sets
  # security.limit_extensions = .php, which rejects a bare /fpm-status.
  if ! grep -qx 'pm.status_path = /fpm-status.php' "$POOL"; then
    if grep -qE '^[[:space:]]*pm\.status_path[[:space:]]*=' "$POOL"; then
      sed -i -E 's|^[[:space:]]*pm\.status_path[[:space:]]*=.*|pm.status_path = /fpm-status.php|' "$POOL"
    else
      printf '\npm.status_path = /fpm-status.php\n' >> "$POOL"
    fi
    FPM_CHANGED=1
  fi
  # Worker recycling closes FastCGI keepalive connections and shows up as
  # "upstream prematurely closed connection" in the Angie log during the
  # high-request-rate PHP tests.  The stress pages are allocation-light, so
  # disable recycling for this test host.  This is test-only; keep a finite
  # pm.max_requests in production.
  if ! grep -qx 'pm.max_requests = 0' "$POOL"; then
    if grep -qE '^[[:space:]]*pm\.max_requests[[:space:]]*=' "$POOL"; then
      sed -i -E 's|^[[:space:]]*pm\.max_requests[[:space:]]*=.*|pm.max_requests = 0|' "$POOL"
    else
      printf '\npm.max_requests = 0\n' >> "$POOL"
    fi
    FPM_CHANGED=1
  fi
  if (( FPM_CHANGED )); then
    systemctl restart "$FPM_SVC"
  fi
fi

# ---------------------------------------------------------------------------
# Angie vhost
# ---------------------------------------------------------------------------
cat > "/etc/angie/conf.d/${DOMAIN}.conf" <<EOF
# Managed by tests/stress-site/setup-stress-site.sh
server {
    listen      80;
    listen      [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://${DOMAIN}\$request_uri;
}
server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    server_name www.${DOMAIN};
    http2 on;
    include h5bp/tls/ssl_engine.conf;
    include h5bp/tls/policy_balanced.conf;
    ssl_certificate     ${CERTDIR}/fullchain.pem;
    ssl_certificate_key ${CERTDIR}/privkey.pem;
    return 301 https://${DOMAIN}\$request_uri;
}
server {
    listen      443 ssl;
    listen      [::]:443 ssl;
    server_name ${DOMAIN};
    http2 on;
    include h5bp/tls/ssl_engine.conf;
    include h5bp/tls/policy_balanced.conf;
    ssl_certificate     ${CERTDIR}/fullchain.pem;
    ssl_certificate_key ${CERTDIR}/privkey.pem;

    root  ${ROOT};
    index index.php index.html;
    error_log  ${LOG_DIR}/${DOMAIN}.error.log warn;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$is_args\$args;
    }

    location ^~ /node/ {
        proxy_pass http://127.0.0.1:3100/;
        include h5bp/proxy_non_php.conf;
    }

    # Guest page-cache demonstration: same heavy page, cached for 5 seconds.
    location = /cached.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO "";
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass local_php;
        fastcgi_keep_conn on;
        fastcgi_cache fastcgicache;
        fastcgi_cache_key "\$scheme\$host\$request_uri";
        fastcgi_cache_valid 200 5s;
        fastcgi_cache_lock on;
        fastcgi_cache_background_update on;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
        add_header X-Cache-Status \$upstream_cache_status always;
    }

    location = /nginx-status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }

    location = /fpm-status.php {
        allow 127.0.0.1;
        deny all;
        include fastcgi_params;
        fastcgi_param SCRIPT_NAME /fpm-status.php;
        fastcgi_param SCRIPT_FILENAME /fpm-status.php;
        fastcgi_pass local_php;
    }

    include h5bp/php.conf;
    include h5bp/basic.conf;
}
EOF
chmod 644 "/etc/angie/conf.d/${DOMAIN}.conf"

# Local name resolution for browser and curl tests.
if ! grep -qE "(^|[[:space:]])${DOMAIN}([[:space:]]|$)" /etc/hosts; then
  printf '127.0.0.1 %s www.%s\n' "$DOMAIN" "$DOMAIN" >> /etc/hosts
fi

angie -t
systemctl reload angie
find "$LOG_DIR" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Seed MariaDB, Elasticsearch and the GIF
# ---------------------------------------------------------------------------
mariadb -e "CREATE DATABASE IF NOT EXISTS ${STRESS_DB_NAME:-stress_test} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
STRESS_DB_PASS=${STRESS_DB_PASS:-temp} "$PHP_BIN" "${HERE}/seed.php"

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
sleep 1
echo
echo "Stress site deployed:"
echo "  https://${DOMAIN}/            (full stack page)"
echo "  https://${DOMAIN}/cached.php  (same page, FastCGI-cached 5s)"
echo "  https://${DOMAIN}/static.html (Angie only)"
echo "  https://${DOMAIN}/hello.php   (PHP + OPcache)"
echo "  https://${DOMAIN}/db.php      (MariaDB)"
echo "  https://${DOMAIN}/cache.php   (Valkey)"
echo "  https://${DOMAIN}/search.php  (Elasticsearch)"
echo "  https://${DOMAIN}/node/       (Node.js proxy)"
echo "  https://${DOMAIN}/nginx-status, /fpm-status.php (localhost only)"
echo
curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/hello.php"
curl -sk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" | grep -Eo 'Total render: [0-9.]+ ms' | head -1 || true
