#!/usr/bin/env bash
# Enable a minimal Anubis filter in front of the CentMinMod XenForo vhost.
set -Eeuo pipefail
ROOT=/home/nginx/domains/xf.test.local/public
VHOST=/usr/local/nginx/conf/conf.d/xf.test.local.ssl.conf
BACKUP=/root/audit/xf-ssl-pre-anubis.conf
SECRET=$(openssl rand -hex 64)

[[ -x /usr/local/bin/anubis ]] || { echo "anubis binary missing" >&2; exit 1; }
[[ -f $BACKUP ]] || cp -a "$VHOST" "$BACKUP"

id anubis >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/anubis --shell /usr/sbin/nologin anubis
usermod -aG anubis nginx

install -d -m 750 -o root -g anubis /etc/anubis
cat > /etc/anubis/botPolicies.yaml <<'EOF'
bots:
  - name: allow-bench
    user_agent_regex: (?i)setup-bench
    action: ALLOW
  - name: allow-good-crawlers
    user_agent_regex: (?i)(Googlebot|bingbot|DuckDuckBot|Applebot|Baiduspider|YandexBot)
    action: ALLOW
  - name: deny-ai-crawlers
    user_agent_regex: (?i)(GPTBot|ChatGPT-User|ClaudeBot|CCBot|Bytespider|PerplexityBot)
    action: DENY
  - name: challenge-browser
    user_agent_regex: Mozilla
    action: CHALLENGE
EOF
chown root:anubis /etc/anubis/botPolicies.yaml
chmod 640 /etc/anubis/botPolicies.yaml

cat > /etc/anubis/anubis.env <<EOF
BIND=/run/anubis/nginx.sock
BIND_NETWORK=unix
TARGET=unix:///run/anubis-backend/backend.sock
DIFFICULTY=4
COOKIE_SECURE=true
COOKIE_HTTP_ONLY=true
COOKIE_SAME_SITE=Lax
COOKIE_EXPIRATION_TIME=168h
CUSTOM_REAL_IP_HEADER=X-Real-IP
POLICY_FNAME=/etc/anubis/botPolicies.yaml
SLOG_LEVEL=WARN
SOCKET_MODE=0660
HS512_SECRET=${SECRET}
EOF
chown root:anubis /etc/anubis/anubis.env
chmod 600 /etc/anubis/anubis.env

cat > /etc/systemd/system/anubis.service <<'EOF'
[Unit]
Description=Anubis bot filter (CentMinMod benchmark)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=anubis
Group=anubis
EnvironmentFile=/etc/anubis/anubis.env
ExecStart=/usr/local/bin/anubis
Restart=on-failure
RestartSec=3
RuntimeDirectory=anubis
RuntimeDirectoryMode=0750
StateDirectory=anubis
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

cat > /usr/local/nginx/conf/conf.d/xf-anubis-terminator.conf <<'EOF'
server {
  listen 443 ssl;
  http2 on;
  server_name xf.test.local www.xf.test.local;

  ssl_dhparam /usr/local/nginx/conf/ssl/xf.test.local/dhparam.pem;
  ssl_certificate     /usr/local/nginx/conf/ssl/xf.test.local/xf.test.local.crt;
  ssl_certificate_key /usr/local/nginx/conf/ssl/xf.test.local/xf.test.local.key;
  include /usr/local/nginx/conf/ssl_include.conf;

  access_log /home/nginx/domains/xf.test.local/log/access-anubis.log combined buffer=64k flush=5m;
  error_log  /home/nginx/domains/xf.test.local/log/error-anubis.log;

  location / {
    proxy_pass http://unix:/run/anubis/nginx.sock:/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Connection "";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  }
}
EOF

install -d -m 750 -o anubis -g anubis /run/anubis-backend
cp -a "$BACKUP" "$VHOST"
sed -i 's|^  listen 443 ssl http2;|  listen unix:/run/anubis-backend/backend.sock;|' "$VHOST"
# The backend peer is a Unix socket; without this XF sees REMOTE_ADDR=unix:
# and throws "Invalid string IP: unix:".
sed -i '/^  root \/home\/nginx\/domains\/xf.test.local\/public;/a\  set_real_ip_from unix:;\n  real_ip_header X-Real-IP;' "$VHOST"

/usr/local/sbin/nginx -t
systemctl restart nginx
[[ -S /run/anubis-backend/backend.sock ]] || { echo "backend socket missing" >&2; exit 1; }
chgrp anubis /run/anubis-backend/backend.sock
chmod 660 /run/anubis-backend/backend.sock
systemctl enable anubis >/dev/null 2>&1 || true
systemctl reset-failed anubis >/dev/null 2>&1 || true
systemctl restart anubis
for i in $(seq 1 20); do
  [[ -S /run/anubis/nginx.sock ]] && break
  sleep 0.5
done
[[ -S /run/anubis/nginx.sock ]] || { echo "anubis socket missing" >&2; journalctl -u anubis -n 20 --no-pager; exit 1; }
sleep 1
curl -sk -o /dev/null -w 'guest=%{http_code}\n' -H 'User-Agent: setup-bench/1.0' --resolve xf.test.local:443:127.0.0.1 https://xf.test.local/
