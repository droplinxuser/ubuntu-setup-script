#!/usr/bin/env bash
# Return the audit host to the 557-package baseline captured before the run.
# Destructive by design: this host is a disposable test target.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

ADDED=$(sed -n 's/^- Added: //p' /tmp/delta.md | tr ' ' '\n' | sed '/^$/d')
echo "$ADDED" | wc -l

# Stop and remove every package the run added.  apt also removes the
# dependencies that are no longer referenced.
if [ -n "$ADDED" ]; then
  # shellcheck disable=SC2086
  apt-get purge -y $ADDED >/tmp/restore-purge.log 2>&1 || true
fi
apt-get autoremove --purge -y >>/tmp/restore-purge.log 2>&1 || true
apt-get clean

# Repositories and keys added by setup.sh.
rm -f /etc/apt/sources.list.d/angie.list \
      /etc/apt/sources.list.d/elastic-9.x.list \
      /etc/apt/sources.list.d/nodesource.sources \
      /etc/apt/sources.list.d/php.list
rm -f /usr/share/keyrings/angie-signing.gpg \
      /usr/share/keyrings/elasticsearch-keyring.gpg \
      /usr/share/keyrings/nodesource.gpg \
      /usr/share/keyrings/debsuryorg-archive-keyring.gpg \
      /usr/share/keyrings/deb.sury.org-*.gpg
apt-get update >/tmp/restore-apt-update.log 2>&1 || true

# Service trees, data and state.
rm -rf /var/www /etc/angie /etc/php /etc/mysql /etc/valkey /etc/redis \
       /etc/elasticsearch /var/lib/setup.sh /var/lib/mysql /var/lib/valkey \
       /var/lib/redis /var/lib/elasticsearch /var/cache/php \
       /home/nginx_cache /home/nginx_cache_chev /opt/stress-node \
       /var/lib/stress-site /etc/stress-site-config.json \
       /etc/systemd/system/stress-node.service
rm -f /usr/local/bin/wp /usr/local/bin/mysqlbkup.sh \
      /usr/local/bin/setup-precompress.sh
rm -f /etc/sysctl.d/99-elasticsearch.conf /etc/sysctl.d/99-sysctl.conf \
      /etc/sysctl.d/90-setup-network.conf
rm -f /etc/modules-load.d/setup-network.conf
rm -f /etc/default/setup-tuning /etc/default/cpufrequtils

# Test files left in the home and temp directories.
rm -rf /home/rt/work
rm -f /tmp/host-manifest.sh /tmp/baseline-manifest.txt /tmp/manifest-*.txt \
      /tmp/state-*.txt /tmp/delta.md /tmp/install-1.log /tmp/optimize-*.log \
      /tmp/domains.log /tmp/stress-setup.log /tmp/seed-xf.log /tmp/seed-*.php \
      /tmp/deploy-apps.sh /tmp/purge.log /tmp/restart-all.log \
      /tmp/test-*.log /tmp/cmd.out /tmp/oc.php /tmp/oc.ini /tmp/enc.php \
      /tmp/bench-cpu.txt /tmp/parity-*.diff /tmp/restore-*.log

# Firewall and netfilter state.
ufw --force reset >/dev/null 2>&1 || true
ufw --force disable >/dev/null 2>&1 || true
rm -f /etc/ufw/*.rules.[0-9]* /etc/ufw/*.rules.[0-9]*.[0-9]* \
      /etc/ufw/user.rules.[0-9]* /etc/ufw/user6.rules.[0-9]*

# Remove users/groups created by packages (they are part of the package
# purge, but a stale account can survive if a data dir was left behind).
for u in elasticsearch valkey redis; do
  id "$u" >/dev/null 2>&1 && userdel "$u" >/dev/null 2>&1 || true
done
for g in elasticsearch valkey redis; do
  getent group "$g" >/dev/null 2>&1 && groupdel "$g" >/dev/null 2>&1 || true
done

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

echo "packages now: $(dpkg-query -W -f='.\n' | wc -l)"
echo "restore done"
