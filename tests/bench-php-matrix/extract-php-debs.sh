#!/usr/bin/env bash
# Extract the Ubuntu archive's PHP 8.5 packages into /opt/php-ubuntu without
# installing them, so the Ubuntu arm can coexist with the Sury packages and
# every arm can be visited in the same rotated benchmark round.
#
# The extracted FPM binary keeps its compiled-in /etc/php/8.5/fpm php.ini and
# pool paths, so it reads the same managed tuning as the Sury unit.  Its
# extensions are loaded from its own tree by absolute path (the source arms do
# the same), which keeps the two distributions' packaging differences — shared
# versus built-in modules — out of the php.ini.
#
# Usage: extract-php-debs.sh [VERSION]
#   VERSION  Ubuntu package version (default 8.5.4-0ubuntu1.6)
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

VER=${1:-8.5.4-0ubuntu1.6}
DEST=/opt/php-ubuntu
WORK=/root/work/debs-php-ubuntu
CONF=/etc/php-ubuntu/conf.d
PHP_INI_DIR=/etc/php/8.5/fpm
# php8.5-common carries the .so files of the extensions Debian builds shared
# (ctype, fileinfo, sockets, ...); without it the binary starts but the
# applications fail on a missing extension.
PKGS=(php8.5-fpm php8.5-cli php8.5-common php8.5-mysql php8.5-gd php8.5-curl
      php8.5-xml php8.5-zip php8.5-gmp php8.5-mbstring php8.5-xsl
      php8.5-readline php8.5-redis php8.5-imagick)

[[ $VER =~ ^[0-9]+\.[0-9]+\.[0-9]+-0ubuntu[0-9.]+$ ]] || { echo "bad version: $VER" >&2; exit 1; }
[[ -d $PHP_INI_DIR ]] || { echo "$PHP_INI_DIR missing" >&2; exit 1; }
mkdir -p "$WORK" "$DEST" "$CONF"
rm -rf "${WORK:?}"/* "${DEST:?}"/* "${CONF:?}"/*
cd "$WORK"

echo "downloading $VER from the Ubuntu archive"
specs=()
for p in "${PKGS[@]}"; do
  case $p in
    php8.5-redis|php8.5-imagick) specs+=("$p") ;;  # versioned independently
    *)                           specs+=("$p=$VER") ;;
  esac
done
apt-get download "${specs[@]}" >/dev/null
for p in "${PKGS[@]}"; do
  debs=("$p"_*.deb)
  [[ -f ${debs[0]:-} ]] || { echo "missing $p deb" >&2; exit 1; }
  dpkg-deb -x "${debs[0]}" "$DEST"
done

# Ubuntu's extension directory is the API-numbered one; the "8.5" directory is
# a compatibility path that may be empty.  Pick the one with the modules.
EXTDIR=$(dirname "$(find "$DEST/usr/lib/php" -name 'mysqli.so' -print -quit)")
[[ -n $EXTDIR && -d $EXTDIR ]] || { echo "no extension directory in the extracted tree" >&2; exit 1; }

# One ini per module, by absolute path, plus the setup-managed settings.
# Load order matters: mysqlnd before mysqli/pdo_mysql, igbinary before redis;
# redis/imagick last.  Debian builds igbinary as a separate package that this
# set does not pin, and Sury's redis.so links to it, so take the installed
# build (the same file every other arm loads).
if [[ ! -f $EXTDIR/igbinary.so ]]; then
  mods=(/usr/lib/php/*/igbinary.so)
  [[ -f ${mods[0]:-} ]] && cp -f "${mods[0]}" "$EXTDIR/igbinary.so"
fi
for so in "$EXTDIR"/*.so; do
  name=$(basename "$so" .so)
  case $name in
    mysqlnd)         prio=10 ;;
    igbinary)        prio=20 ;;
    redis|imagick)   prio=99 ;;
    *)               prio=50 ;;
  esac
  printf 'extension=%s\n' "$so" > "$CONF/$prio-$name.ini"
done
for ini in custom_dan.ini zz-setup-optimize.ini zzz-audit.ini; do
  [[ -f $PHP_INI_DIR/conf.d/$ini ]] && cp -f "$PHP_INI_DIR/conf.d/$ini" "$CONF/"
done

cat > /etc/systemd/system/php-pkg-ubuntu.service <<UNIT
[Unit]
Description=PHP-FPM (Ubuntu archive $VER, extracted — not installed)
After=network.target

[Service]
Type=notify
Environment=PHP_INI_SCAN_DIR=$CONF
ExecStart=$DEST/usr/sbin/php-fpm8.5 --nodaemonize --fpm-config /etc/php/8.5/fpm/php-fpm.conf -c $PHP_INI_DIR/php.ini -d extension_dir=$EXTDIR
ExecReload=/bin/kill -USR2 \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=30
Restart=on-failure
LimitNOFILE=524288
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

PHP_INI_SCAN_DIR=$CONF "$DEST/usr/bin/php8.5" -d extension_dir="$EXTDIR" -v | head -1
printf 'extdir=%s conf=%s\n' "$EXTDIR" "$CONF"
