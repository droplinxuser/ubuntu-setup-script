#!/usr/bin/env bash
# Install OpenLiteSpeed + LiteSpeed's lsphp next to the Angie stack, for the
# XenForo server shootout (switch-php-arm.sh ols-lsphp | ols-src-TAG).
#
# Nothing here is part of a production install.  OpenLiteSpeed is installed
# from the vendor repository, configured for one vhost (xf.test.local) on the
# same document root, certificate, database, Valkey and php.ini as the Angie
# arms, and left stopped and disabled: switch-php-arm.sh starts it only while
# Angie is stopped.
#
# Parity with the Angie arms (h5bp tree + setup.sh tuning):
#   * workers         = nproc (Angie worker_processes auto)
#   * PHP children    = the FPM pool's pm.max_children (static), one LSAPI
#                       parent per arm so OPcache is shared
#   * php.ini         = /etc/php/8.5/fpm/php.ini (PHPRC) + the managed
#                       settings files from its conf.d (custom_dan.ini,
#                       zz-setup-optimize.ini, zzz-audit.ini)
#   * TLS             = the same certificate, TLS 1.2 + 1.3, HTTP/1.1 via wrk
#   * keep-alive      = 32767 requests per connection (OpenLiteSpeed's maximum;
#                       65536 is rejected and silently becomes 100), 60 s;
#                       Angie allows 65536, neither limit is reached in a run
#   * compression     = gzip level 4 for dynamic responses (Angie gzip and
#                       brotli 4); OpenLiteSpeed has no dynamic brotli
#   * access log      = off (Angie access_log off)
#   * guest cache     = LSCache, 300 s (Angie fastcgi_cache_valid 200 5m),
#                       stored only for requests without a XenForo member or
#                       LSCache login cookie (the addon's documented rule set)
#
# The LiteSpeed Cache addon for XenForo (xenforo_addon_LiteSpeedCache-*.zip in
# /root/work/pkg) is installed into the forum so every arm runs the same PHP
# code: under Angie it only adds a no-cache response header for members and a
# cookie on login.
#
# Usage: install-ols.sh [install|config|addon]
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

MODE=${1:-install}
LSWS=/usr/local/lsws
XF_HOST=${XF_HOST:-xf.test.local}
XF_ROOT=${XF_ROOT:-/var/www/$XF_HOST/public}
PKG=${PKG:-/root/work/pkg}
PHP_INI_DIR=/etc/php/8.5/fpm
OLS_CONF_D=/etc/php-ols/conf.d          # scan dir for the lsphp85 arm
POOL=$PHP_INI_DIR/pool.d/www.conf
CHILDREN=$(awk -F= '/^[[:space:]]*pm\.max_children/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$POOL" 2>/dev/null || true)
CHILDREN=${CHILDREN:-$(nproc)}
WORKERS=$(nproc)
(( WORKERS > 16 )) && WORKERS=16          # OpenLiteSpeed's maximum

cert_pair() {
  # The Angie vhost's own certificate, so both servers do the same handshake.
  local vhost crt key
  vhost=$(grep -rlE "server_name[^;]*\b$XF_HOST\b" /etc/angie/conf.d /etc/angie/sites-enabled 2>/dev/null | head -n1 || true)
  [[ -n $vhost ]] || { echo "no Angie vhost for $XF_HOST" >&2; return 1; }
  crt=$(awk '$1 == "ssl_certificate" { gsub(/;/, "", $2); print $2; exit }' "$vhost")
  key=$(awk '$1 == "ssl_certificate_key" { gsub(/;/, "", $2); print $2; exit }' "$vhost")
  [[ -r $crt && -r $key ]] || { echo "certificate not found in $vhost" >&2; return 1; }
  printf '%s %s\n' "$crt" "$key"
}

install_packages() {
  if [[ ! -f /etc/apt/sources.list.d/lst_debian_repo.list ]]; then
    curl -fsSL https://rpms.litespeedtech.com/debian/lst_repo.gpg \
      | gpg --dearmor -o /usr/share/keyrings/lst-debian.gpg
    . /etc/os-release
    echo "deb [signed-by=/usr/share/keyrings/lst-debian.gpg] http://rpms.litespeedtech.com/debian/ $VERSION_CODENAME main" \
      > /etc/apt/sources.list.d/lst_debian_repo.list
  fi
  apt-get update -qq
  # The XenForo module set (lib/services.sh install_php) in LiteSpeed's build.
  apt-get install -y --no-install-recommends openlitespeed lsphp85 lsphp85-common \
    lsphp85-mysql lsphp85-curl lsphp85-intl lsphp85-igbinary lsphp85-redis \
    lsphp85-imagick >/dev/null
  systemctl disable --now lshttpd >/dev/null 2>&1 || true
  # The package starts its own lsphp listener and admin console; neither is used.
  pkill -x lsphp 2>/dev/null || true
}

write_php_conf() {
  # lsphp85: its own extension .ini files plus the managed settings files.
  local f name
  mkdir -p "$OLS_CONF_D"
  find "$OLS_CONF_D" -mindepth 1 -delete
  for f in "$LSWS"/lsphp85/etc/php/8.5/mods-available/*.ini; do
    [[ -f $f ]] && cp -f "$f" "$OLS_CONF_D/"
  done
  for name in custom_dan.ini zz-setup-optimize.ini zzz-audit.ini; do
    [[ -f $PHP_INI_DIR/conf.d/$name ]] && cp -fL "$PHP_INI_DIR/conf.d/$name" "$OLS_CONF_D/"
  done
  # LiteSpeed's opcache.ini enables the extension with its own defaults; the
  # managed zz-setup-optimize.ini sorts after it and wins.
  return 0
}

write_config() {
  local crt key pair
  pair=$(cert_pair); crt=${pair% *}; key=${pair#* }
  mkdir -p "$LSWS/conf/vhosts/xf" /var/cache/ols/xf "$LSWS/logs"
  chown -R www-data:www-data /var/cache/ols
  [[ -f $LSWS/conf/httpd_config.conf.pkg ]] || cp -a "$LSWS/conf/httpd_config.conf" "$LSWS/conf/httpd_config.conf.pkg"

  cat > "$LSWS/conf/httpd_config.conf" <<CONF
# Written by tests/bench-php-matrix/install-ols.sh (benchmark only).
serverName                ols-bench
user                      www-data
group                     www-data
priority                  0
httpdWorkers              $WORKERS
cpuAffinity               1
autoRestart               1
chrootPath                /
enableChroot              0
inMemBufSize              120M
swappingDir               /tmp/lshttpd/swap
autoFix503                1
gracefulRestartTimeout    30
mime                      conf/mime.properties
showVersionNumber         0
disableWebAdmin           1
indexFiles                index.php, index.html

errorlog logs/error.log {
  logLevel                ERROR
  debugLevel              0
  rollingSize             10M
  enableStderrLog         1
}

# lsphp runs as www-data (uid 33), the owner of the document roots and the
# FPM pool user; the suEXEC floor defaults to uid/gid 100 and then refuses
# to start any LSAPI process ("cgidSuEXEC failed", every request 503).
CGIRLimit  {
  maxCGIInstances         200
  minUID                  11
  minGID                  10
  priority                0
  CPUSoftLimit            0
  CPUHardLimit            0
  memSoftLimit            0
  memHardLimit            0
  procSoftLimit           4000
  procHardLimit           4096
}

tuning  {
  maxConnections          100000
  maxSSLConnections       100000
  connTimeout             300
  maxKeepAliveReq         32767
  keepAliveTimeout        60
  smartKeepAlive          0
  sndBufSize              0
  rcvBufSize              0
  maxReqURLLen            32768
  maxReqHeaderSize        65536
  maxReqBodySize          2047M
  maxDynRespHeaderSize    32768
  maxDynRespSize          2047M
  maxCachedFileSize       4096
  totalInMemCacheSize     64M
  maxMMapFileSize         256K
  totalMMapCacheSize      64M
  useSendfile             1
  fileETag                28
  enableGzipCompress      1
  compressibleTypes       default
  enableDynGzipCompress   1
  gzipCompressLevel       4
  gzipAutoUpdateStatic    1
  gzipStaticCompressLevel 6
  brStaticCompressLevel   6
  gzipMaxFileSize         10M
  gzipMinFileSize         300
  sslStrongDhKey          0
  sslEnableMultiCerts     0
  quicEnable              0
}

module cache {
  internal                1
  ls_enabled              1
  checkPrivateCache       1
  checkPublicCache        1
  maxCacheObjSize         10000000
  maxStaleAge             0
  qsCache                 1
  reqCookieCache          1
  respCookieCache         1
  ignoreReqCacheCtrl      1
  ignoreRespCacheCtrl     0
  enableCache             0
  expireInSeconds         300
  enablePrivateCache      0
  privateExpireInSeconds  300
  storagePath             /var/cache/ols
}

# One LSAPI parent per arm; switch-php-arm.sh points the script handler at
# one of them.  PHP_LSAPI_CHILDREN = the FPM pool size, so both servers run
# the same number of PHP processes sharing one OPcache.
extprocessor lsphp85 {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp85.sock
  maxConns                $CHILDREN
  env                     PHP_LSAPI_CHILDREN=$CHILDREN
  env                     LSAPI_MAX_REQS=65536
  env                     PHPRC=$PHP_INI_DIR
  env                     PHP_INI_SCAN_DIR=$OLS_CONF_D
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    $LSWS/lsphp85/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            0
  memHardLimit            0
  procSoftLimit           4000
  procHardLimit           4096
}
CONF
  local d tag
  for d in /opt/php-*/bin/lsphp; do
    [[ -x $d ]] || continue
    tag=${d#/opt/php-}; tag=${tag%/bin/lsphp}
    cat >> "$LSWS/conf/httpd_config.conf" <<CONF

extprocessor lsphp-src-$tag {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp-src-$tag.sock
  maxConns                $CHILDREN
  env                     PHP_LSAPI_CHILDREN=$CHILDREN
  env                     LSAPI_MAX_REQS=65536
  env                     PHPRC=$PHP_INI_DIR
  env                     PHP_INI_SCAN_DIR=/etc/php-src/$tag/conf.d:/etc/php-src/$tag/ext
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    $d
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            0
  memHardLimit            0
  procSoftLimit           4000
  procHardLimit           4096
}
CONF
  done
  cat >> "$LSWS/conf/httpd_config.conf" <<CONF

scripthandler  {
  add                     lsapi:lsphp85 php
}

listener HTTP {
  address                 *:80
  secure                  0
  map                     xf $XF_HOST
}

listener HTTPS {
  address                 *:443
  secure                  1
  keyFile                 $key
  certFile                $crt
  sslProtocol             24
  enableSpdy              15
  map                     xf $XF_HOST
}

virtualhost xf {
  vhRoot                  /var/www/$XF_HOST/
  configFile              conf/vhosts/xf/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
}
CONF

  # XenForo's htaccess.txt (front controller) plus the LSCache XF2 rule set,
  # with a 300 s TTL.  Rules at vhost level see the URI with its leading '/'.
  # The cache-vary line is not in the add-on's documented rule set and is
  # required: "CacheLookup on" serves the public (guest) entry to every
  # request, and the add-on's own xf_lscxf_logged_in marker exists only for
  # logins made after it was installed.  A member with only xf_user /
  # xf_session (remember-me, or logged in before the add-on) got the cached
  # guest page (measured: x-litespeed-cache: hit, no data-logged-in).  The
  # add-on still refuses to store any logged-in page (X-LiteSpeed-Cache-
  # Control: no-cache), so a varied member key never fills and members reach
  # PHP, as they do through Angie's session-cookie bypass.
  cat > "$LSWS/conf/vhosts/xf/vhconf.conf" <<CONF
docRoot                   $XF_ROOT/
enableGzip                1

index  {
  useServer               0
  indexFiles              index.php
}

context /internal_data/ {
  allowBrowse             0
}
context /src/ {
  allowBrowse             0
}
context /library/ {
  allowBrowse             0
}

rewrite  {
  enable                  1
  autoLoadHtaccess        0
  rules                   <<<END_rules
RewriteRule .* - [E="cache-vary:xf_session,xf_user,xf_lscxf_logged_in,xf_session_admin"]
CacheLookup on
RewriteCond %{REQUEST_METHOD} ^(GET|HEAD)\$
RewriteCond %{REQUEST_URI} !^/(install/|admin\.php) [NC]
RewriteCond %{HTTP_COOKIE} !(xf_lscxf_logged_in|xf_user|xf_session_admin) [NC]
RewriteRule .* - [E=Cache-Control:max-age=300]

RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -l [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^.*\$ - [NC,L]
RewriteRule ^/(data/|js/|styles/|install/|favicon\.ico|crossdomain\.xml|robots\.txt) - [NC,L]
RewriteRule ^.*\$ /index.php [NC,L]
END_rules
}

module cache {
  storagePath             /var/cache/ols/xf
}
CONF
  chown -R lsadm:www-data "$LSWS/conf" 2>/dev/null || true
  "$LSWS/bin/openlitespeed" -t 2>&1 | tail -n 5 || true
}

install_addon() {
  local zip work
  zip=$(ls "$PKG"/xenforo_addon_LiteSpeedCache-*.zip 2>/dev/null | head -n1 || true)
  [[ -f $zip ]] || { echo "missing $PKG/xenforo_addon_LiteSpeedCache-*.zip" >&2; return 1; }
  work=$(mktemp -d /root/work/lsc.XXXXXX)
  unzip -q "$zip" -d "$work"
  cp -a "$work/upload/." "$XF_ROOT/"
  rm -rf "$work"
  chown -R www-data:www-data "$XF_ROOT/src/addons/LiteSpeedCache"
  ( cd "$XF_ROOT" && sudo -u www-data php cmd.php xf:addon-install LiteSpeedCache --force )
}

case $MODE in
  install) install_packages; write_php_conf; write_config; install_addon ;;
  config)  write_php_conf; write_config ;;
  addon)   install_addon ;;
  *) echo "usage: install-ols.sh [install|config|addon]" >&2; exit 1 ;;
esac
echo "OpenLiteSpeed ready (stopped): workers=$WORKERS lsapi_children=$CHILDREN"
