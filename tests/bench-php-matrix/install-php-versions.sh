#!/usr/bin/env bash
# Install PHP 8.2-8.6 side by side, each with an identical, hardware-tuned
# FPM pool on /run/php/php<VER>-fpm.sock.  php-redis is deliberately NOT
# installed: SV/RedisCache uses its bundled Credis client on every version so
# the PHP-version comparison is like for like.
set -Eeuo pipefail
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

SRC_VER=8.5
SRC_POOL=/etc/php/${SRC_VER}/fpm/pool.d/www.conf
SRC_INI=/etc/php/${SRC_VER}/fpm/conf.d/zz-setup-optimize.ini
[[ -f $SRC_POOL ]] || { echo "missing $SRC_POOL" >&2; exit 1; }
[[ -f $SRC_INI ]] || { echo "missing $SRC_INI" >&2; exit 1; }

for v in 8.2 8.3 8.4 8.6; do
  echo "== installing PHP $v"
  pkgs=(php$v-fpm php$v-cli php$v-mysql php$v-gd php$v-curl php$v-xml php$v-zip
        php$v-mbstring php$v-gmp)
  # 8.5+ bundle OPcache in the core packages.
  apt-cache show "php$v-opcache" >/dev/null 2>&1 && pkgs+=(php$v-opcache)
  apt-get install -y --no-install-recommends "${pkgs[@]}"
done

for v in 8.2 8.3 8.4 8.5 8.6; do
  echo "== configuring PHP $v"
  # A pure-PHP Redis client is used for every version; the extension would
  # make 8.6 (where it is not published) unfairly slow.
  apt-get purge -y "php$v-redis" >/dev/null 2>&1 || true
  apt-get purge -y "php$v-imagick" >/dev/null 2>&1 || true

  pool="/etc/php/$v/fpm/pool.d/www.conf"
  if [[ $v != "$SRC_VER" ]]; then
    cp -a "$SRC_POOL" "$pool"
    cp -a "$SRC_INI" "/etc/php/$v/fpm/conf.d/zz-setup-optimize.ini"
  fi
  sed -i -E "s|^([[:space:]]*listen[[:space:]]*=[[:space:]]*).*|\\1/run/php/php${v}-fpm.sock|" "$pool"

  install -d -m 755 "/etc/systemd/system/php${v}-fpm.service.d"
  printf '[Service]\nLimitNOFILE=524288\n' > "/etc/systemd/system/php${v}-fpm.service.d/limits.conf"

  if ! "/usr/sbin/php-fpm$v" -t >/dev/null 2>&1; then
    echo "php-fpm$v rejected the copied pool/ini" >&2
    "/usr/sbin/php-fpm$v" -t 2>&1 | tail -5 >&2
    exit 1
  fi
done

systemctl daemon-reload
for v in 8.2 8.3 8.4 8.5 8.6; do
  systemctl enable "php$v-fpm" >/dev/null 2>&1 || true
  systemctl restart "php$v-fpm"
done

# Keep the CLI on 8.5 for XenForo's cmd.php.
update-alternatives --set php /usr/bin/php8.5 >/dev/null 2>&1 || true

echo "== module / listener check"
for v in 8.2 8.3 8.4 8.5 8.6; do
  printf 'PHP %s: ' "$v"
  mods=$(/usr/bin/php$v -m 2>/dev/null | tr '\n' ' ')
  for m in mysqli gd curl mbstring xml zip json Zend\ OPcache; do
    [[ $mods == *"$m"* ]] || printf 'MISSING:%s ' "$m"
  done
  [[ $mods == *"redis"* ]] && printf 'HAS-REDIS '
  [[ -S /run/php/php${v}-fpm.sock ]] && printf 'socket=yes' || printf 'socket=NO'
  printf '\n'
done
php -v | head -1
