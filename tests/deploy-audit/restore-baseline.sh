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
# Absolute: the purge below runs from $WORK.
[[ -n $SETUP && $SETUP != /* ]] && SETUP=$PWD/$SETUP
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d /tmp/restore-baseline.XXXXXX)
[[ -r $BASE ]] || { echo "baseline manifest not readable: $BASE" >&2; exit 1; }

# The audit tooling's own /etc/hosts line goes first: --purge restores the
# recorded original byte for byte only when nothing but the 127.0.1.1 (and
# blank) lines changed, and a line still present here sent it down the merge
# path, which kept cloud-init's extra blank line (one byte of drift per cycle).
sed -i '/# audit$/d' /etc/hosts

if [[ -n $SETUP && -r $SETUP ]]; then
  echo "== setup.sh --purge all"
  # From $WORK: setup.sh writes its setup_<stamp>.log run log to the current
  # directory, and the caller's home kept one per restore.
  ( cd "$WORK" && bash "$SETUP" --purge all ) > "$WORK/purge.log" 2>&1 || echo "purge exited $? (see $WORK/purge.log)"
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
# Kernel packages are never purged: a kernel that unattended-upgrades added
# during the run carries the linux-generic metapackages with it, and purging
# it left the host without them (1.21.68).  A newer kernel is upstream drift.
KERNEL_RE='^linux-(image|modules|modules-extra|main-modules|headers|generic|image-generic|headers-generic)(-|$)'
ADDED=$(printf '%s\n' "$ADDED" | grep -vE "$KERNEL_RE" || true)
echo "added packages: $(printf '%s\n' "$ADDED" | sed '/^$/d' | wc -l)"
for unit in nginx angie anubis mariadb valkey-server elasticsearch 'php*-fpm' sysstat smartmontools; do
  systemctl stop "$unit" >/dev/null 2>&1 || true
done
if [[ -n $ADDED ]]; then
  # shellcheck disable=SC2086
  apt-get purge -y $ADDED > "$WORK/apt-purge.log" 2>&1 || echo "apt purge reported an error (see $WORK/apt-purge.log)"
fi
# Dependencies the purge orphaned, but only names the baseline never had: a
# blanket autoremove also purged baseline packages that were auto-installed
# and merely unused on the pristine host.  Repeat while purging orphans more.
for _ in 1 2 3 4 5; do
  orphans=$(apt-get -s autoremove 2>/dev/null | awk '$1 == "Remv" { print $2 }' \
            | grep -vxFf <(printf '%s\n' "$BASE_NAMES") | grep -vE "$KERNEL_RE" || true)
  [[ -n $orphans ]] || break
  # shellcheck disable=SC2086
  apt-get purge -y $orphans >> "$WORK/apt-purge.log" 2>&1 || break
done

echo "== repositories and keys"
rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/sources.list.d/nginx.sources /etc/apt/sources.list.d/angie.list /etc/apt/sources.list.d/angie.sources \
      /etc/apt/sources.list.d/elastic-*.list /etc/apt/sources.list.d/elastic-*.sources \
      /etc/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/nodesource.list \
      /etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/php.sources \
      /etc/apt/sources.list.d/mariadb.list /etc/apt/sources.list.d/mariadb.sources \
      /etc/apt/sources.list.d/valkey.list \
      /etc/apt/sources.list.d/lst_debian_repo.list
rm -f /usr/share/keyrings/nginx-signing.gpg /usr/share/keyrings/angie-signing.gpg /usr/share/keyrings/elasticsearch-keyring.gpg \
      /usr/share/keyrings/nodesource.gpg /usr/share/keyrings/debsuryorg-archive-keyring.gpg \
      /usr/share/keyrings/deb.sury.org-*.gpg /etc/apt/keyrings/nginx* /etc/apt/keyrings/angie* /etc/apt/keyrings/elastic* \
      /etc/apt/keyrings/nodesource* /etc/apt/preferences.d/nginx* /etc/apt/preferences.d/angie* /etc/apt/preferences.d/php* \
      /etc/apt/preferences.d/nodejs* /etc/apt/preferences.d/nodesource* \
      /usr/share/keyrings/lst-debian.gpg
apt-get update > "$WORK/apt-update.log" 2>&1 || true
apt-get clean

echo "== service trees, data and state"
# Anubis is installed from a release tarball (not apt), so its binary, unit
# and configuration are outside the package delta.
systemctl disable anubis >/dev/null 2>&1 || true
rm -f /etc/systemd/system/anubis.service /usr/local/bin/anubis \
      /etc/tmpfiles.d/nginx-anubis.conf
rm -rf /etc/anubis /run/anubis /var/lib/anubis /var/cache/anubis
id anubis >/dev/null 2>&1 && userdel anubis >/dev/null 2>&1 || true
# Benchmark-only trees: OpenLiteSpeed (bench-php-matrix/install-ols.sh) and the
# source PHP arms (build-php-max.sh).  The openlitespeed package leaves its
# lsadm account and parts of /usr/local/lsws behind (its repository and
# keyring go with the others above, before the apt-get update).
systemctl stop lshttpd >/dev/null 2>&1 || true
for u in /etc/systemd/system/php-src-*.service; do
  [[ -f $u ]] || continue
  systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
  rm -f "$u"
done
rm -rf /usr/local/lsws /etc/php-ols /etc/php-src /var/cache/ols /tmp/lshttpd /opt/php-*
# PHP_BUILD=clang/lean (1.21.68), in case --purge did not run or failed: the
# builds, their source/library cache, the conf.d mirror, the rebuild/refresh
# units, the APT hook and the apt.llvm.org source.
systemctl disable --now setup-php-fpm-build-refresh.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/setup-php-fpm-build@.service /etc/systemd/system/setup-php-fpm-build-refresh.* \
      /etc/systemd/system/php*-fpm.service.d/zz-setup-build.conf /etc/apt/apt.conf.d/99setup-php-fpm-build \
      /etc/apt/sources.list.d/setup-llvm.sources /etc/apt/preferences.d/setup-llvm.pref /etc/apt/keyrings/setup-llvm.asc
rm -rf /usr/local/lib/setup-php /var/cache/setup-php-build /run/setup-php-build /opt/setup-llvm
# NGINX_BUILD=clang (1.21.70) and the nginx A/B arms.
systemctl disable --now setup-nginx-build-refresh.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/setup-nginx-build.service /etc/systemd/system/setup-nginx-build-refresh.* \
      /etc/systemd/system/nginx.service.d/zz-setup-build.conf /etc/apt/apt.conf.d/99setup-nginx-build \
      /run/systemd/system/nginx.service.d/zz-bench-nginx.conf /etc/nginx/nginx-bench-src.conf
rm -rf /usr/local/lib/setup-nginx /var/cache/setup-nginx-build /opt/nginx-*
# 1.22: our own units (same names as the old packages' units, in /etc), the
# shared build units, links outside dpkg, the apt pin, migration backups.
for u in nginx.service valkey-server.service valkey.service setup-build-refresh.timer \
         setup-build-refresh.service setup-build-cpu.service setup-nginx-build.service \
         setup-valkey-build.service setup-migrate-1.22.service; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done
for u in /etc/systemd/system/php*-fpm.service; do
  [[ -f $u ]] || continue
  systemctl disable --now "${u##*/}" >/dev/null 2>&1 || true
done
systemctl stop 'setup-php-build@*.service' >/dev/null 2>&1 || true
rm -f /etc/systemd/system/nginx.service /etc/systemd/system/valkey-server.service \
      /etc/systemd/system/valkey.service /etc/systemd/system/php*-fpm.service \
      /etc/systemd/system/setup-build-*.service /etc/systemd/system/setup-build-*.timer \
      /etc/systemd/system/setup-php-build@.service /etc/systemd/system/setup-nginx-build.service \
      /etc/systemd/system/setup-valkey-build.service \
      /etc/systemd/system/multi-user.target.wants/{nginx,valkey-server}.service \
      /etc/systemd/system/multi-user.target.wants/php*-fpm.service \
      /etc/systemd/system/timers.target.wants/setup-build-refresh.timer \
      /etc/apt/preferences.d/setup-source-builds /usr/sbin/policy-rc.d.setup \
      /usr/local/sbin/nginx /usr/local/sbin/php-fpm* /usr/local/bin/php* \
      /usr/local/bin/valkey-* /var/log/setup-migrate-1.22.log /run/setup-build.lock \
      /run/setup-build-cpu.attempts
for l in /usr/bin/php /usr/bin/php[0-9]*; do
  [[ -L $l ]] && ! dpkg -S "$l" >/dev/null 2>&1 && rm -f "$l"
done
rm -rf /usr/local/lib/setup-php /usr/local/lib/setup-valkey /var/backups/setup-1.22 \
       /var/lib/php /var/cache/nginx
# VALKEY_BUILD=clang (1.21.71), the Valkey/nginx/Elasticsearch A/B arms and
# their sources.
systemctl disable --now setup-valkey-build-refresh.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/setup-valkey-build.service /etc/systemd/system/setup-valkey-build-refresh.* \
      /etc/systemd/system/valkey-server.service.d/zz-setup-build.conf /etc/apt/apt.conf.d/99setup-valkey-build \
      /run/systemd/system/valkey-server.service.d/zz-bench-valkey.conf \
      /run/systemd/system/elasticsearch.service.d/zz-lean.conf
rm -rf /usr/local/lib/setup-valkey /var/cache/setup-valkey-build /opt/valkey-* /opt/nginx-* /opt/es-lean \
       /etc/elasticsearch-lean /var/lib/es-lean /var/tmp/es-exp \
       /etc/nginx-ng \
       /root/vk-proto /root/ng-proto /root/nginx-proto /root/es-dl /root/ng-test.conf
id lsadm >/dev/null 2>&1 && userdel lsadm >/dev/null 2>&1 || true
rm -rf /var/www /etc/nginx /etc/angie /etc/php /etc/mysql /etc/valkey /etc/redis /etc/elasticsearch \
       /var/lib/setup.sh /var/lib/mysql /var/lib/mariadb /var/lib/valkey /var/lib/redis /var/lib/elasticsearch \
       /var/lib/php /var/cache/php /var/cache/nginx /var/log/nginx /var/cache/angie /var/log/angie /var/lib/angie /var/log/mysql /var/log/valkey \
       /var/log/elasticsearch /var/log/php* /var/log/setup-*.md /var/log/sysstat \
       /home/nginx_cache /home/nginx_cache_chev /home/proxy_cache /home/proxy_cdn /home/xf_proxy_cache \
       /run/php /usr/share/elasticsearch /opt/stress-node /var/lib/stress-site /var/lib/tls-arms-bench \
       /etc/stress-site-config.json /etc/systemd/system/stress-node.service
rm -rf /etc/systemd/system/nginx.service.d /etc/systemd/system/angie.service.d /etc/systemd/system/mariadb.service.d \
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
# Written by the nginx package's maintainer script (needrestart override),
# not owned by the package, so a purge leaves it.
rm -f /etc/needrestart/conf.d/nginx.conf /etc/needrestart/conf.d/angie.conf
rm -rf /root/mysqltuner.pl /root/tools/mysqlbackup-master
rmdir /root/tools 2>/dev/null || true
# Audit-only leftovers: perf(1) symbol cache and the load generator the
# benchmark scripts install.
rm -rf /root/.debug /usr/local/bin/oha /usr/local/bin/wrk
# top(1) creates ~/.config/procps; MariaDB's postinst creates
# /var/lib/mysql-files (secure_file_priv), which the package purge leaves.
for h in /root /home/*; do rmdir "$h/.config/procps" "$h/.config" 2>/dev/null || true; done
rm -rf /var/lib/mysql-files
rm -rf /tmp/php-config.* /tmp/php-install.* /tmp/hsperfdata_root /tmp/node-compile-cache
find /tmp -maxdepth 1 \( -name 'sess_*' -o -name 'setup-optimize*' -o -name 'nginx-*' -o -name 'angie-*' -o -name 'php-upgrade*' \) \
  -exec rm -rf {} + 2>/dev/null || true
sed -i '/# audit$/d' /etc/hosts
# `--basic swap=` creates /swapfile and `--purge` keeps it on purpose (turning
# swap off can OOM a live host).  The disposable audit host gets it removed
# when the baseline host had no /swapfile: swapoff, the fstab line, the file.
if [[ -f /swapfile ]] && ! awk '/^== swap/{f=1; next} /^== /{f=0} f' "$BASE" | grep -q '/swapfile'; then
  swapoff /swapfile 2>/dev/null || true
  sed -i '\#^/swapfile[[:space:]]#d' /etc/fstab
  rm -f /swapfile
  echo "removed /swapfile and its fstab line (absent from the baseline)"
fi
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
for u in nginx angie elasticsearch valkey redis mysql; do
  id "$u" >/dev/null 2>&1 && userdel "$u" >/dev/null 2>&1 || true
done
for g in nginx angie elasticsearch valkey redis mysql; do
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
