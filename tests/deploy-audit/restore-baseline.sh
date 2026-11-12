#!/usr/bin/env bash
# Return a disposable audit host to the state recorded in a baseline manifest
# (host-manifest.sh) taken before the run.  Destructive by design: it purges
# every package the run added and deletes the web roots, databases, service
# configuration and setup.sh state.
#
# Usage: restore-baseline.sh BASELINE_MANIFEST [SETUP_SH]
#   SETUP_SH   path to setup.sh; when given, `--purge all` runs first so the
#              recorded original settings (sysctl, limits, governor, hostname,
#              timezone, crontab) are put back before the packages go.
# The script prints a compare-manifest.sh summary at the end; an empty package
# delta and no changed /etc files means the host is back at the baseline.
set -Euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
BASE=${1:?baseline manifest}
SETUP=${2:-}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d /tmp/restore-baseline.XXXXXX)
[[ -r $BASE ]] || { echo "baseline manifest not readable: $BASE" >&2; exit 1; }

if [[ -n $SETUP && -r $SETUP ]]; then
  echo "== setup.sh --purge all"
  bash "$SETUP" --purge all > "$WORK/purge.log" 2>&1 || echo "purge exited $? (see $WORK/purge.log)"
fi

echo "== packages"
bash "$HERE/host-manifest.sh" > "$WORK/current.txt" 2>&1
bash "$HERE/compare-manifest.sh" "$BASE" "$WORK/current.txt" > "$WORK/delta.md" 2>&1
ADDED=$(sed -n 's/^- Added: //p' "$WORK/delta.md" | head -n1 | tr ' ' '\n' | sed '/^$/d; /^none$/d')
# A package the baseline already had but the run upgraded (libc6, locales)
# shows up in the delta as added and removed.  Purging it would make apt
# refuse the whole transaction, so only names absent from the baseline go.
BASE_NAMES=$(awk -F'\t' '/^== packages ==/{p=1; next} /^== /{p=0} p && NF {print $1}' "$BASE")
ADDED=$(printf '%s\n' "$ADDED" | grep -vxFf <(printf '%s\n' "$BASE_NAMES") || true)
echo "added packages: $(printf '%s\n' "$ADDED" | sed '/^$/d' | wc -l)"
for unit in angie mariadb valkey-server elasticsearch 'php*-fpm' sysstat smartmontools; do
  systemctl stop "$unit" >/dev/null 2>&1 || true
done
if [[ -n $ADDED ]]; then
  # shellcheck disable=SC2086
  apt-get purge -y $ADDED > "$WORK/apt-purge.log" 2>&1 || echo "apt purge reported an error (see $WORK/apt-purge.log)"
fi
apt-get autoremove --purge -y >> "$WORK/apt-purge.log" 2>&1 || true

echo "== repositories and keys"
rm -f /etc/apt/sources.list.d/angie.list /etc/apt/sources.list.d/angie.sources \
      /etc/apt/sources.list.d/elastic-*.list /etc/apt/sources.list.d/elastic-*.sources \
      /etc/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/nodesource.list \
      /etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/php.sources \
      /etc/apt/sources.list.d/mariadb.list /etc/apt/sources.list.d/mariadb.sources \
      /etc/apt/sources.list.d/valkey.list
rm -f /usr/share/keyrings/angie-signing.gpg /usr/share/keyrings/elasticsearch-keyring.gpg \
      /usr/share/keyrings/nodesource.gpg /usr/share/keyrings/debsuryorg-archive-keyring.gpg \
      /usr/share/keyrings/deb.sury.org-*.gpg /etc/apt/keyrings/angie* /etc/apt/keyrings/elastic* \
      /etc/apt/keyrings/nodesource* /etc/apt/preferences.d/angie* /etc/apt/preferences.d/php* \
      /etc/apt/preferences.d/nodejs* /etc/apt/preferences.d/nodesource*
apt-get update > "$WORK/apt-update.log" 2>&1 || true
apt-get clean

echo "== service trees, data and state"
rm -rf /var/www /etc/angie /etc/php /etc/mysql /etc/valkey /etc/redis /etc/elasticsearch \
       /var/lib/setup.sh /var/lib/mysql /var/lib/mariadb /var/lib/valkey /var/lib/redis /var/lib/elasticsearch \
       /var/lib/php /var/cache/php /var/cache/angie /var/log/angie /var/log/mysql /var/log/valkey \
       /var/log/elasticsearch /var/log/php* /var/log/setup-*.md /var/log/sysstat \
       /home/nginx_cache /home/nginx_cache_chev /home/proxy_cache /home/proxy_cdn /home/xf_proxy_cache \
       /run/php /usr/share/elasticsearch /opt/stress-node /var/lib/stress-site \
       /etc/stress-site-config.json /etc/systemd/system/stress-node.service
rm -rf /etc/systemd/system/angie.service.d /etc/systemd/system/mariadb.service.d \
       /etc/systemd/system/valkey-server.service.d /etc/systemd/system/elasticsearch.service.d \
       /etc/systemd/system/php*-fpm.service.d /etc/systemd/system/setup-cpu-governor.service \
       /etc/systemd/system/multi-user.target.wants/setup-cpu-governor.service \
       /etc/systemd/system/setup-*.service /etc/systemd/system/setup-*.timer \
       /etc/systemd/system/*.wants/setup-*
rm -f /usr/local/bin/wp /usr/local/bin/mysqlbkup.sh /usr/local/bin/setup-*.sh \
      /etc/sysctl.d/99-elasticsearch.conf /etc/sysctl.d/90-setup-*.conf /etc/sysctl.d/99-setup-*.conf \
      /etc/modules-load.d/setup-*.conf /etc/security/limits.d/*setup*.conf \
      /etc/default/setup-tuning /etc/default/cpufrequtils /etc/logrotate.d/setup-* \
      /etc/apparmor.d/local/usr.sbin.mariadbd /etc/udev/rules.d/*setup*.rules \
      /etc/tmpfiles.d/setup-*.conf /etc/cron.d/setup-*
rm -f /etc/mysqlbkup.cnf /etc/mysqlbkup.config
rm -rf /root/mysqltuner.pl /root/tools/mysqlbackup-master
rmdir /root/tools 2>/dev/null || true
rm -rf /tmp/php-config.* /tmp/php-install.* /tmp/hsperfdata_root /tmp/node-compile-cache
find /tmp -maxdepth 1 \( -name 'sess_*' -o -name 'setup-optimize*' -o -name 'angie-*' -o -name 'php-upgrade*' \) \
  -exec rm -rf {} + 2>/dev/null || true
sed -i '/# audit$/d' /etc/hosts
# Drop root's crontab when only the managed block (or nothing) is left in it.
if crontab -l >/dev/null 2>&1 \
   && ! crontab -l 2>/dev/null | sed '/# BEGIN setup.sh managed cron/,/# END setup.sh managed cron/d' | grep -q '[^[:space:]]'; then
  crontab -r 2>/dev/null || true
fi

echo "== firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw --force reset >/dev/null 2>&1 || true
  ufw --force disable >/dev/null 2>&1 || true
  rm -f /etc/ufw/*.rules.[0-9]* /etc/ufw/*.[0-9]*_[0-9]* 2>/dev/null || true
  # ufw leaves its (empty) chains loaded after a reset; only drop them when
  # nothing but ufw chains is left, so a host with its own rules is untouched.
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if ! "$ipt" -S 2>/dev/null | grep -vE '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$|ufw-' | grep -q .; then
      "$ipt" -F 2>/dev/null || true
      "$ipt" -X 2>/dev/null || true
    fi
  done
fi

echo "== accounts created by the removed packages"
for u in angie elasticsearch valkey redis mysql; do
  id "$u" >/dev/null 2>&1 && userdel "$u" >/dev/null 2>&1 || true
done
for g in angie elasticsearch valkey redis mysql; do
  getent group "$g" >/dev/null 2>&1 && groupdel "$g" >/dev/null 2>&1 || true
done

# Kernel modules the profile loaded (BBR, fq, conntrack for ufw); unloading
# fails harmlessly while one is still in use.
for m in tcp_bbr sch_fq xt_recent xt_conntrack xt_LOG xt_limit xt_hl xt_addrtype nf_conntrack; do
  modprobe -r "$m" >/dev/null 2>&1 || true
done
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true
ldconfig

echo "== result"
bash "$HERE/host-manifest.sh" > "$WORK/after.txt" 2>&1
bash "$HERE/compare-manifest.sh" "$BASE" "$WORK/after.txt" | tee "$WORK/after-delta.md" | sed -n '1,/^## Managed trees/p'
echo "work files: $WORK"
