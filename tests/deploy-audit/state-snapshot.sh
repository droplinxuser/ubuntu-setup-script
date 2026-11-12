#!/usr/bin/env bash
# Print the configuration state setup.sh is responsible for, one fact per
# line, so two runs can be compared with diff(1):
#
#   state-snapshot.sh > after-install.txt
#   setup.sh --optimize
#   state-snapshot.sh > after-optimize.txt
#   diff after-install.txt after-optimize.txt     # parity: must be empty
#
# Covered: digest, mode and owner of every managed configuration file, unit
# enablement and activity, drop-ins, the root crontab, sysctl values, limits,
# and the values each service actually runs with.  Volatile facts (PIDs,
# counters, timestamps, logs) are left out on purpose.  Run as root.
set -u
export LC_ALL=C

sec() { printf '\n## %s\n' "$1"; }

sec files
for d in /etc/angie /etc/php /etc/mysql /etc/valkey /etc/redis /etc/elasticsearch \
         /etc/sysctl.d /etc/security/limits.d /etc/systemd/system /etc/systemd/journald.conf.d \
         /etc/systemd/resolved.conf.d /etc/default /etc/logrotate.d /etc/apt/sources.list.d \
         /etc/apt/keyrings /etc/apt/preferences.d /etc/apt/apt.conf.d /etc/cron.d /etc/ssh \
         /etc/modules-load.d /etc/tmpfiles.d /etc/udev/rules.d /etc/ufw /usr/local/bin \
         /var/lib/setup.sh; do
  [[ -d $d ]] || continue
  find "$d" \( -path /var/lib/setup.sh/backup -o -name '*.keystore' -o -name '*.tmp' \
              -o -path '/etc/ssh/ssh_host_*' -o -path /etc/elasticsearch/certs \) -prune -o \
       \( -type f -o -type l \) -print0
done | sort -z | while IFS= read -r -d '' f; do
  if [[ -L $f ]]; then
    printf '%s -> %s\n' "$f" "$(readlink "$f")"
  else
    printf '%s %s %s\n' "$(md5sum < "$f" | cut -c1-32)" "$(stat -c '%a %U:%G' "$f")" "$f"
  fi
done

sec directories
for d in /var/www /var/www/logs /var/www/logs/* /home/angie* /var/cache/angie* /run/php /run/valkey \
         /var/lib/php/sessions /var/www/mysql_database; do
  [[ -d $d ]] && printf '%s %s\n' "$(stat -c '%a %U:%G' "$d")" "$d"
done

sec units
systemctl list-unit-files --no-pager --no-legend --type=service,timer,socket 2>/dev/null \
  | awk '{print $1, $2}' | sort
sec active
systemctl list-units --no-pager --no-legend --type=service,timer --state=active 2>/dev/null \
  | awk '{print $1, $3, $4}' | grep -vE '^(user@|session-|systemd-fsck@|getty@|user-runtime-dir@|systemd-(timedated|hostnamed|localed)\.|NetworkManager-dispatcher\.|packagekit\.|fwupd\.)' | sort

sec crontab
crontab -l 2>/dev/null

sec sysctl
sysctl -a 2>/dev/null | grep -E '^(net\.(core|ipv4|ipv6\.conf\.(all|default))|vm|fs\.(file-max|nr_open|inotify|aio-max-nr)|kernel\.(sched|pid_max|threads-max|numa|kptr|dmesg|unprivileged|perf_event_paranoid|sysrq|panic|randomize|yama))' \
  | grep -vE 'route\.flush|stat_refresh|nr_pdflush|drop_caches|compact_memory|\.random\.|tcp_fastopen_key|ns_last_pid|nr_hugepages_mempolicy|sched_domain|base_reachable|stable_secret|lowmem_reserve' | sort

sec block
for q in /sys/block/*/queue; do
  dev=${q%/queue}; dev=${dev##*/}
  [[ $dev == loop* || $dev == ram* ]] && continue
  printf '%s scheduler=%s read_ahead_kb=%s nr_requests=%s rotational=%s\n' "$dev" \
    "$(sed -E 's/.*\[(.*)\].*/\1/' "$q/scheduler" 2>/dev/null)" "$(cat "$q/read_ahead_kb" 2>/dev/null)" \
    "$(cat "$q/nr_requests" 2>/dev/null)" "$(cat "$q/rotational" 2>/dev/null)"
done
printf 'thp=%s defrag=%s governor=%s\n' \
  "$(sed -E 's/.*\[(.*)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" \
  "$(sed -E 's/.*\[(.*)\].*/\1/' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)" \
  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
swapon --show=NAME,SIZE --noheadings 2>/dev/null
printf 'hostname=%s timezone=%s\n' "$(hostname)" "$(timedatectl show -p Timezone --value 2>/dev/null)"

sec unit-limits
for u in angie mariadb valkey-server redis-server elasticsearch $(systemctl list-units --no-legend --plain 'php*-fpm.service' 2>/dev/null | awk '{print $1}'); do
  systemctl cat "$u" >/dev/null 2>&1 || continue
  printf '%s %s\n' "$u" "$(systemctl show "$u" -p LimitNOFILE -p LimitNPROC -p LimitMEMLOCK -p TasksMax -p OOMScoreAdjust -p Nice -p CPUWeight -p IOWeight -p MemoryMax -p MemoryHigh -p Restart -p TimeoutStartUSec -p TimeoutStopUSec 2>/dev/null | tr '\n' ' ')"
done

sec angie
if command -v angie >/dev/null 2>&1; then
  angie -T 2>/dev/null | grep -vE '^\s*(#|$)' | md5sum | cut -c1-32
  angie -V 2>&1 | head -1
fi

sec php
for fpm in /usr/sbin/php-fpm[0-9]*; do
  [[ -x $fpm ]] || continue
  v=${fpm##*php-fpm}
  "$fpm" -tt 2>&1 | sed -E 's/^\[[^]]*\] NOTICE:[[:space:]]*//' | grep -vE '^(configuration file|$)' | sed "s/^/fpm$v /"
  # shellcheck disable=SC2016
  PHP_INI_SCAN_DIR="/etc/php/$v/fpm/conf.d" "/usr/bin/php$v" -c "/etc/php/$v/fpm" -r 'foreach (ini_get_all(null,false) as $k=>$x) echo $k,"=",is_array($x)?json_encode($x):$x,"\n";' 2>/dev/null \
    | grep -vE '^(cli_server|html_errors|display_errors|register_argc_argv|max_execution_time|implicit_flush)' | sed "s/^/ini$v /"
  "/usr/bin/php$v" -m 2>/dev/null | grep -v '^\[' | grep . | sort | tr '\n' ' ' | sed "s/^/modules$v /"; echo
done

sec mariadb
if command -v mariadb >/dev/null 2>&1 && systemctl is-active --quiet mariadb; then
  mariadb -N -e "SHOW GLOBAL VARIABLES" 2>/dev/null \
    | grep -vE '^(gtid_|pseudo_thread_id|timestamp|rand_seed|last_insert_id|insert_id|identity|error_count|warning_count|in_transaction|wsrep_|server_uid|hostname|pid_file|report_host|innodb_version|version|system_time_zone|log_bin_|have_|innodb_buffer_pool_size_auto_min)' | sort
fi

sec valkey
for cli in valkey-cli redis-cli; do
  command -v "$cli" >/dev/null 2>&1 || continue
  for s in /run/valkey/valkey.sock /run/redis/redis-server.sock; do
    [[ -S $s ]] && "$cli" -s "$s" CONFIG GET '*' 2>/dev/null | paste - - | grep -vE '^(requirepass|masterauth|masteruser)' | sort
  done
  break
done

sec elasticsearch
if systemctl is-active --quiet elasticsearch 2>/dev/null; then
  pid=$(systemctl show elasticsearch -p MainPID --value)
  tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -E '^-(Xm|XX:|Des\.)' | grep -vE 'tmpdir|ErrorFile|HeapDumpPath|Xlog|distribution|path\.' | sort
fi
