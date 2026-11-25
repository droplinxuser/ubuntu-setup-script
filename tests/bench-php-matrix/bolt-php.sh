#!/usr/bin/env bash
# Post-link optimise a source-built php-fpm with LLVM BOLT.
#
# Usage: bolt-php.sh SRC_TAG DST_TAG
#
# SRC_TAG must be a build-php-max.sh arm linked with BOLT=1 (relocations
# kept).  The arm is copied to DST_TAG (/opt/php-DST, /etc/php-src/DST and
# php-src-DST.service), served, sampled with perf branch records (LBR) while
# train-php-pgo.sh drives the same traffic as PGO training, and its php-fpm
# is rewritten by llvm-bolt.  Run as root on bare metal (LBR is needed).
set -Eeuo pipefail
export LC_ALL=C
SRC=${1:?usage: bolt-php.sh SRC_TAG DST_TAG}
DST=${2:?dst tag}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $DST =~ ^[a-z0-9-]+$ ]] || { echo "tag must be [a-z0-9-]+" >&2; exit 1; }
[[ -x /opt/php-$SRC/sbin/php-fpm ]] || { echo "no arm $SRC" >&2; exit 1; }

pick() { command -v "$1" || ls /usr/bin/"$1"-* /usr/lib/llvm-*/bin/"$1" 2>/dev/null | sort -V | tail -n 1; }
# The Ubuntu package called "bolt" is the Thunderbolt daemon; LLVM BOLT is
# llvm-bolt (perf2bolt included).
for p in linux-tools-common "linux-tools-$(uname -r)" llvm-bolt; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' installed$' \
    || apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
    || echo "note: package $p not installed" >&2
done
BOLT=$(pick llvm-bolt); P2B=$(pick perf2bolt)
[[ -x $BOLT && -x $P2B ]] || { echo "llvm-bolt/perf2bolt not found" >&2; exit 1; }
readelf -S "/opt/php-$SRC/sbin/php-fpm" | grep -q '\.rela\.text' \
  || { echo "/opt/php-$SRC/sbin/php-fpm has no relocations: build it with BOLT=1" >&2; exit 1; }

# A drop-in arm (build-php-dropin.sh: no /etc/php-src tree) runs under the
# packaged unit; only its binary is copied.
KIND=src; [[ -d /etc/php-src/$SRC ]] || KIND=dropin
rm -rf "/opt/php-$DST" "/etc/php-src/$DST"
cp -a "/opt/php-$SRC" "/opt/php-$DST"
if [[ $KIND == src ]]; then
cp -a "/etc/php-src/$SRC" "/etc/php-src/$DST"
sed -i -e "s#php-src-$SRC#php-src-$DST#g" "/etc/php-src/$DST/php-fpm.conf"
sed -e "s#/opt/php-$SRC/#/opt/php-$DST/#g" -e "s#/etc/php-src/$SRC/#/etc/php-src/$DST/#g" \
    -e "s#^Description=.*#Description=PHP-FPM source build ($DST, $SRC + BOLT)#" \
    "/etc/systemd/system/php-src-$SRC.service" > "/etc/systemd/system/php-src-$DST.service"
systemctl daemon-reload
# The copied extension .so files embed nothing path-specific, but the ini
# lines name the source prefix; point them at the copy.
sed -i "s#/opt/php-$SRC/#/opt/php-$DST/#g" "/etc/php-src/$DST"/ext/*.ini 2>/dev/null || true
fi

W=/root/work/bolt-$DST
rm -rf "$W"; mkdir -p "$W"
"$HERE/switch-php-arm.sh" "$KIND-$SRC" >/dev/null
perf record -e cycles:u -j any,u -a -o "$W/perf.data" -- sleep 75 >"$W/perf.log" 2>&1 &
perf_pid=$!
sleep 1
NO_STOP=1 PHP_ARM_TAG=$SRC bash "$HERE/train-php-pgo.sh"
wait "$perf_pid"
"$P2B" -p "$W/perf.data" -o "$W/php-fpm.fdata" "/opt/php-$SRC/sbin/php-fpm" >"$W/perf2bolt.log" 2>&1 \
  || { tail -20 "$W/perf2bolt.log" >&2; exit 1; }
"$BOLT" "/opt/php-$SRC/sbin/php-fpm" -o "$W/php-fpm.bolt" -data="$W/php-fpm.fdata" \
  -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
  -split-all-cold -split-eh -dyno-stats -icf=1 \
  >"$W/bolt.log" 2>&1 || { tail -20 "$W/bolt.log" >&2; exit 1; }
install -m 0755 "$W/php-fpm.bolt" "/opt/php-$DST/sbin/php-fpm"
grep -E 'BOLT-INFO: (basic block reordering|.*functions? (have|with) profile)' "$W/bolt.log" | head -5 || true
"$HERE/switch-php-arm.sh" "$KIND-$DST" >/dev/null
echo "installed: /opt/php-$DST (BOLT of $SRC)"
