#!/usr/bin/env bash
# Compare two host manifests written by host-manifest.sh and print a Markdown
# summary of what changed.  Usage: compare-manifest.sh BASELINE CURRENT
export LC_ALL=C
set -u
BASE=${1:?baseline manifest}
CUR=${2:?current manifest}

section() {
  awk -v s="== $2" 'index($0, s) == 1 { f = 1; next } /^== / { f = 0 } f' "$1"
}

echo "## Package delta"
section "$BASE" "packages" | sed '/^$/d' | sort > /tmp/cmp-pkg-base.$$
section "$CUR" "packages" | sed '/^$/d' | sort > /tmp/cmp-pkg-cur.$$
added=$(comm -13 /tmp/cmp-pkg-base.$$ /tmp/cmp-pkg-cur.$$ | cut -f1 | paste -sd' ' -)
removed=$(comm -23 /tmp/cmp-pkg-base.$$ /tmp/cmp-pkg-cur.$$ | cut -f1 | paste -sd' ' -)
changed=$(join -t$'\t' -j1 <(cut -f1,2 /tmp/cmp-pkg-base.$$ | sort) <(cut -f1,2 /tmp/cmp-pkg-cur.$$ | sort) \
  | awk -F'\t' '$2 != $3 { print $1 }' | paste -sd' ' -)
echo "- Added: ${added:-none}"
echo "- Removed: ${removed:-none}"
echo "- Version changed: ${changed:-none}"
echo "- Count: baseline $(wc -l < /tmp/cmp-pkg-base.$$), current $(wc -l < /tmp/cmp-pkg-cur.$$)"
rm -f /tmp/cmp-pkg-base.$$ /tmp/cmp-pkg-cur.$$

echo
echo "## /etc file digests"
section "$BASE" "file digests of /etc" | sort > /tmp/cmp-etc-base.$$
section "$CUR" "file digests of /etc" | sort > /tmp/cmp-etc-cur.$$
awk '{print $2}' /tmp/cmp-etc-base.$$ | sort -u > /tmp/cmp-etc-paths-base.$$
awk '{print $2}' /tmp/cmp-etc-cur.$$ | sort -u > /tmp/cmp-etc-paths-cur.$$
echo "- Added files: $(comm -13 /tmp/cmp-etc-paths-base.$$ /tmp/cmp-etc-paths-cur.$$ | wc -l)"
comm -13 /tmp/cmp-etc-paths-base.$$ /tmp/cmp-etc-paths-cur.$$ | sed 's/^/  - /' | head -20
echo "- Removed files: $(comm -23 /tmp/cmp-etc-paths-base.$$ /tmp/cmp-etc-paths-cur.$$ | wc -l)"
comm -23 /tmp/cmp-etc-paths-base.$$ /tmp/cmp-etc-paths-cur.$$ | sed 's/^/  - /' | head -20
echo "- Changed files: $(join -1 2 -2 2 <(sort -k2 /tmp/cmp-etc-base.$$) <(sort -k2 /tmp/cmp-etc-cur.$$) | awk '$2 != $3 { n++ } END { print n+0 }')"
join -1 2 -2 2 <(sort -k2 /tmp/cmp-etc-base.$$) <(sort -k2 /tmp/cmp-etc-cur.$$) \
  | awk '$2 != $3 { print "  - " $1 }' | head -30
rm -f /tmp/cmp-etc-*.$$

echo
echo "## Enabled unit files added"
section "$BASE" "enabled unit files" | awk '{print $1}' | sort -u > /tmp/cmp-unit-base.$$
section "$CUR" "enabled unit files" | awk '{print $1}' | sort -u > /tmp/cmp-unit-cur.$$
comm -13 /tmp/cmp-unit-base.$$ /tmp/cmp-unit-cur.$$ | paste -sd' ' - | sed 's/^/- /'
echo "## Enabled unit files removed"
comm -23 /tmp/cmp-unit-base.$$ /tmp/cmp-unit-cur.$$ | paste -sd' ' - | sed 's/^/- /'
rm -f /tmp/cmp-unit-*.$$

echo
echo "## Active services added"
section "$BASE" "active services" | awk '{print $1}' | sort -u > /tmp/cmp-act-base.$$
section "$CUR" "active services" | awk '{print $1}' | sort -u > /tmp/cmp-act-cur.$$
comm -13 /tmp/cmp-act-base.$$ /tmp/cmp-act-cur.$$ | paste -sd' ' - | sed 's/^/- /'
echo "## Active services removed"
comm -23 /tmp/cmp-act-base.$$ /tmp/cmp-act-cur.$$ | paste -sd' ' - | sed 's/^/- /'
rm -f /tmp/cmp-act-*.$$

echo
echo "## sysctl changes (volatile counters excluded)"
section "$BASE" "sysctl" | sort > /tmp/cmp-sc-base.$$
section "$CUR" "sysctl" | sort > /tmp/cmp-sc-cur.$$
comm -3 /tmp/cmp-sc-base.$$ /tmp/cmp-sc-cur.$$ \
  | grep -vE 'fs\.(dentry|inode|file|quota)|kernel\.(ns_last_pid|random\.uuid)|nf_conntrack_count|net\.netfilter|^[[:space:]]+net\.ipv4\.(tcp_mem|udp_mem)|vm\.(nr_|stat_)' \
  | sed 's/^[[:space:]]*/  /' | head -60
rm -f /tmp/cmp-sc-*.$$

echo
echo "## Root crontab"
section "$CUR" "root crontab" | sed 's/^/    /'

echo
echo "## Managed trees (current)"
for d in /var/www /etc/angie /etc/php /etc/mysql /etc/valkey /etc/elasticsearch /var/lib/setup.sh /var/cache/php; do
  if [ -d "$d" ]; then
    printf '  - %-28s %6s files %8s\n' "$d" "$(find "$d" -xdev -type f 2>/dev/null | wc -l)" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  fi
done

echo
echo "## Runtime tuning in effect"
if command -v php >/dev/null 2>&1; then
  php -r 'printf("  - php %s: memory_limit=%s opcache=%sM jit=%s/%s hot=%s/%s/%s/%s max_files=%s\n", PHP_VERSION, ini_get("memory_limit"), ini_get("opcache.memory_consumption"), ini_get("opcache.jit"), ini_get("opcache.jit_buffer_size"), ini_get("opcache.jit_hot_loop"), ini_get("opcache.jit_hot_func"), ini_get("opcache.jit_hot_return"), ini_get("opcache.jit_hot_side_exit"), ini_get("opcache.max_accelerated_files"));' 2>/dev/null
fi
for f in /etc/php/*/fpm/pool.d/www.conf; do
  [ -f "$f" ] || continue
  printf '  - %s: %s\n' "$f" "$(grep -E '^(pm|pm\.max_children|pm\.max_requests|listen|listen\.backlog) ' "$f" | tr '\n' ' ')"
done
if command -v mariadb >/dev/null 2>&1; then
  mariadb -N -B -e "SELECT CONCAT('  - mariadb: buffer_pool=', ROUND(@@innodb_buffer_pool_size/1048576), 'M io_capacity=', @@innodb_io_capacity, '/', @@innodb_io_capacity_max, ' thread_pool=', @@thread_pool_size, ' max_connections=', @@max_connections, ' flush_trx=', @@innodb_flush_log_at_trx_commit)" 2>/dev/null
fi
if command -v valkey-cli >/dev/null 2>&1; then
  maxmem=$(valkey-cli CONFIG GET maxmemory 2>/dev/null | tail -1)
  policy=$(valkey-cli CONFIG GET maxmemory-policy 2>/dev/null | tail -1)
  threads=$(valkey-cli CONFIG GET io-threads 2>/dev/null | tail -1)
  printf '  - valkey: maxmemory=%s policy=%s io-threads=%s\n' "${maxmem:-?}" "${policy:-?}" "${threads:-?}"
fi
es=$(curl -fsS 'http://127.0.0.1:9200/_nodes/stats/jvm?filter_path=nodes.*.jvm.mem.heap_max_in_bytes' 2>/dev/null | grep -o '[0-9]*' | head -1)
[ -n "${es:-}" ] && printf '  - elasticsearch: heap_max=%sM\n' "$(( es / 1048576 ))"
