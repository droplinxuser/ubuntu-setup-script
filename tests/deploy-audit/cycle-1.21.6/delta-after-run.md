## Package delta
- Added: angie angie-module-brotli apt-transport-https curl debsuryorg-archive-keyring elasticsearch fontconfig-config fonts-dejavu-core fonts-dejavu-mono galera-4 gawk gifsicle git git-man imagemagick-7-common libabsl20260107 libaio1t64 libaom3 libargon2-1 libavif16 libdav1d7 libdbi-perl libdeflate0 liberror-perl libfftw3-double3 libfontconfig1 libgav1-2 libgd3 libgomp1 libheif-plugin-aomdec libheif1 libimagequant0 libjbig0 libjpeg-turbo8 libjpeg8 liblcms2-2 liblerc4 liblqr-1-0 libltdl7 libmagickcore-7.q16-10 libmagickwand-7.q16-10 libmariadb3 libmpfr6 libnvme1t64 libopenjp2-7 libpcre2-posix3 libraw23t64 libsensors-config libsensors5 libsharpyuv0 libsodium23 libtiff6 liburing2 libwebp7 libwebpdemux2 libwebpmux3 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 libxext6 libxpm4 libxslt1.1 libyuv0 libzip5 mariadb-client mariadb-client-core mariadb-common mariadb-server mariadb-server-core mysql-common nodejs nvme-cli php-common php8.5-cli php8.5-common php8.5-curl php8.5-fpm php8.5-gd php8.5-gmp php8.5-igbinary php8.5-imagick php8.5-mbstring php8.5-mysql php8.5-readline php8.5-redis php8.5-xml php8.5-zip smartmontools socat sysstat valkey-server valkey-tools
- Removed: none
- Version changed: none
- Count: baseline 526, current 620

## /etc file digests
- Added files: 274
  - /etc/ImageMagick-7/colors.xml
  - /etc/ImageMagick-7/delegates.xml
  - /etc/ImageMagick-7/log.xml
  - /etc/ImageMagick-7/mime.xml
  - /etc/ImageMagick-7/policy.xml
  - /etc/ImageMagick-7/quantization-table.xml
  - /etc/ImageMagick-7/thresholds.xml
  - /etc/ImageMagick-7/type-apple.xml
  - /etc/ImageMagick-7/type-dejavu.xml
  - /etc/ImageMagick-7/type-ghostscript.xml
  - /etc/ImageMagick-7/type-urw-base35-type1.xml
  - /etc/ImageMagick-7/type-urw-base35.xml
  - /etc/ImageMagick-7/type-windows.xml
  - /etc/ImageMagick-7/type.xml
  - /etc/angie/angie.conf
  - /etc/angie/conf.d/1.http.default.conf
  - /etc/angie/conf.d/1.https.default.conf
  - /etc/angie/conf.d/chev.test.local.conf
  - /etc/angie/conf.d/templates/example.com.conf
  - /etc/angie/conf.d/templates/no-ssl.example.com.conf
- Removed files: 0
- Changed files: 14
  - /etc/group
  - /etc/group-
  - /etc/gshadow
  - /etc/gshadow-
  - /etc/ld.so.cache
  - /etc/passwd
  - /etc/passwd-
  - /etc/shadow
  - /etc/shadow-
  - /etc/sysctl.conf
  - /etc/ufw/sysctl.conf
  - /etc/ufw/ufw.conf
  - /etc/ufw/user.rules
  - /etc/ufw/user6.rules

## Enabled unit files added
- angie.service elasticsearch.service mariadb.service nvmefc-boot-connections.service nvmf-autoconnect.service php8.5-fpm.service phpsessionclean.timer setup-cpu-governor.service setup-io-tuning.service setup-network-tuning.service smartmontools.service sysstat-collect.timer sysstat-rotate.timer sysstat-summary.timer sysstat.service valkey-server.service
## Enabled unit files removed
- 

## Active services added
- angie.service elasticsearch.service mariadb.service php8.5-fpm.service polkit.service smartmontools.service valkey-server.service
## Active services removed
- anacron.service

## sysctl changes (volatile counters excluded)
  fs.aio-max-nr = 10485760
  fs.aio-max-nr = 65536
  fs.aio-nr = 0
  fs.aio-nr = 544
  fs.inotify.max_queued_events = 16384
  fs.inotify.max_queued_events = 32768
  fs.inotify.max_user_instances = 128
  fs.inotify.max_user_instances = 256
  fs.inotify.max_user_watches = 2097152
  fs.inotify.max_user_watches = 224707
  fs.nr_open = 10485760
  fs.nr_open = 2147483584
  fs.protected_fifos = 1
  fs.protected_fifos = 2
  kernel.msgmax = 65535
  kernel.msgmax = 8192
  kernel.msgmnb = 16384
  kernel.msgmnb = 65535
  kernel.pid_max = 4194300
  kernel.pid_max = 4194304
  kernel.shmall = 18446744073692774399
  kernel.shmall = 262144
  kernel.shmmax = 1073741824
  kernel.shmmax = 18446744073692774399
  kernel.sysrq = 0
  kernel.sysrq = 176
  net.core.bpf_jit_harden = 0
  net.core.bpf_jit_harden = 1
  net.core.default_qdisc = fq
  net.core.default_qdisc = fq_codel
  net.core.netdev_budget = 300
  net.core.netdev_budget = 600
  net.core.netdev_budget_usecs = 2000
  net.core.netdev_budget_usecs = 8000
  net.core.netdev_max_backlog = 1000
  net.core.netdev_max_backlog = 32768
  net.core.optmem_max = 131072
  net.core.optmem_max = 262144
  net.core.rmem_default = 212992
  net.core.rmem_default = 262144
  net.core.rmem_max = 33554432
  net.core.rmem_max = 4194304
  net.core.somaxconn = 4096
  net.core.somaxconn = 65536
  net.core.wmem_default = 212992
  net.core.wmem_default = 262144
  net.core.wmem_max = 33554432
  net.core.wmem_max = 4194304
  net.ipv4.conf.all.accept_redirects = 0
  net.ipv4.conf.all.accept_redirects = 1
  net.ipv4.conf.all.log_martians = 0
  net.ipv4.conf.all.log_martians = 1
  net.ipv4.conf.all.rp_filter = 1
  net.ipv4.conf.all.rp_filter = 2
  net.ipv4.conf.all.secure_redirects = 0
  net.ipv4.conf.all.secure_redirects = 1
  net.ipv4.conf.all.send_redirects = 0
  net.ipv4.conf.all.send_redirects = 1
  net.ipv4.conf.default.accept_redirects = 0
  net.ipv4.conf.default.accept_redirects = 1

## Root crontab
    # BEGIN setup.sh managed cron
    0 0 * * * /usr/bin/find /var/www -mindepth 1 \( -path /var/www/logs -o -path /var/www/mysql_database -o -name "*.log" -o -name "wp-config.php" \) -prune -o -exec /usr/bin/chown -h www-data:www-data {} + >/dev/null 2>&1
    1 1 * * * /usr/bin/chmod +x /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1
    2 1 * * * /etc/angie/scripts/cloudflare.sh >/dev/null 2>&1
    3 3 * * * /usr/local/bin/mysqlbkup.sh 1>> /var/www/logs/mariadb/backup.log 2>> /var/www/logs/mariadb/backup-err.log
    4 4 4 * * /usr/bin/mariadb-check -Aos --auto-repair > /dev/null 2>&1
    */5 * * * * /usr/bin/find /var/www -maxdepth 6 -type f -name wp-config.php ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do [ -f "$d/wp-cron.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$d/wp-cron.php"; done >/dev/null 2>&1 || true
    * * * * * /usr/bin/find /var/www -maxdepth 6 -type f -path "*/src/config.php" ! -path "*/mysql_database/*" ! -path "*/backup*/*" ! -path "*/.old/*" -exec /usr/bin/dirname {} \; | while IFS= read -r d; do r=$(/usr/bin/dirname "$d"); [ -f "$r/cmd.php" ] && [ -f "$d/XF.php" ] && /usr/sbin/runuser -u www-data -- /usr/bin/php "$r/cmd.php" xf:run-jobs --max-execution-time=50 >/dev/null 2>&1; done >/dev/null 2>&1 || true
    # END setup.sh managed cron
    

## Managed trees (current)
  - /var/www                      75992 files     688M
  - /etc/angie                      122 files     612K
  - /etc/php                         41 files     336K
  - /etc/mysql                       12 files      64K
  - /etc/valkey                       1 files     128K
  - /etc/elasticsearch               13 files      92K
  - /var/lib/setup.sh               307 files     1.7M
  - /var/cache/php                    0 files     8.0K

## Runtime tuning in effect
  - php 8.5.12: memory_limit=-1 opcache=128M jit=disable/64M hot=61/127/8/8 max_files=10000
  - /etc/php/8.5/fpm/pool.d/www.conf: listen = /run/php/php-fpm.sock listen.backlog = 65535 pm = static pm.max_children = 16 pm.max_requests = 16384 
  - mariadb: buffer_pool=1738M io_capacity=10000/20000 thread_pool=16 max_connections=200 flush_trx=2
  - valkey: maxmemory=455081984 policy=allkeys-lru io-threads=1
  - elasticsearch: heap_max=0M
