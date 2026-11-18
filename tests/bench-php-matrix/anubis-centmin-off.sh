#!/usr/bin/env bash
# Disable the benchmark Anubis filter and restore the direct TLS vhost.
set -Eeuo pipefail
VHOST=/usr/local/nginx/conf/conf.d/xf.test.local.ssl.conf
BACKUP=/root/audit/xf-ssl-pre-anubis.conf

systemctl disable --now anubis >/dev/null 2>&1 || true
rm -f /usr/local/nginx/conf/conf.d/xf-anubis-terminator.conf
if [[ -f $BACKUP ]]; then
  cp -a "$BACKUP" "$VHOST"
fi
rm -f /run/anubis-backend/backend.sock
/usr/local/sbin/nginx -t
systemctl reload nginx
gpasswd -d nginx anubis >/dev/null 2>&1 || true
echo "anubis off"
