#!/usr/bin/env bash
# Write a complete host-state manifest to stdout. Run as root.
set -u
export LC_ALL=C
echo "== captured =="
date -Is
echo
echo "== identity =="
hostnamectl 2>/dev/null || true
echo "virt: $(systemd-detect-virt 2>/dev/null || echo none)"
echo
echo "== cpu =="
lscpu | sed -n '1,30p'
echo
echo "== memory =="
free -m
echo
echo "== block devices =="
lsblk -o NAME,ROTA,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
echo
echo "== packages =="
dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' | sort
echo
echo "== dpkg count =="
dpkg-query -W -f='.\n' | wc -l
echo
echo "== enabled unit files =="
systemctl list-unit-files --state=enabled --no-legend --no-pager | sort
echo
echo "== active services =="
systemctl list-units --type=service --state=running --no-legend --no-pager \
  | awk '$2 == "loaded" { print $1 }' | sort
echo
echo "== sysctl =="
sysctl -a 2>/dev/null | sort
echo
echo "== root crontab =="
crontab -l 2>/dev/null || echo "(none)"
echo
echo "== users =="
getent passwd
echo
echo "== groups =="
getent group
echo
echo "== managed trees =="
for d in /etc/angie /etc/php /etc/mysql /etc/valkey /etc/redis /etc/elasticsearch \
         /etc/systemd/system /etc/sysctl.d /etc/security/limits.d /etc/logrotate.d \
         /etc/default /var/www /var/lib/setup.sh /opt/stress-node /usr/local/bin; do
  if [ -e "$d" ]; then
    echo "-- $d"
    find "$d" -xdev \( -type f -o -type l \) -printf '%M %u:%g %p -> %l\n' 2>/dev/null | sort
  fi
done
echo
echo "== file digests of /etc =="
find /etc -xdev -type f -print0 2>/dev/null | sort -z | xargs -0 md5sum 2>/dev/null | sort -k2
echo
echo "== listening sockets =="
ss -lntup
echo
echo "== firewall =="
ufw status verbose 2>/dev/null || echo "(ufw not installed)"
echo
echo "== swap =="
swapon --show || echo "(none)"
echo
echo "== mounted =="
findmnt -t ext4,xfs,btrfs,vfat
