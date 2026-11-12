#!/usr/bin/env bash
# PHP compatibility pass for the three test apps on the PHP version that is installed now:
#   1. lint every PHP file with E_ALL (compile-time deprecations and fatals),
#   2. switch each app to its debug/E_ALL mode and run exercise.sh (run-time diagnostics).
# The applications hide E_DEPRECATED themselves (WordPress without WP_DEBUG, XenForo's
# error_reporting(E_ALL & ~E_DEPRECATED), Chevereto's stderr log), so a plain php.ini switch
# reports nothing.
set -u
V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
WP=/var/www/wp.test.local/public; XF=/var/www/xf.test.local/public; CH=/var/www/chev.test.local/public
LOG=/var/www/logs/php/php-error.log
OUT=/root/audit/compat-$V; mkdir -p $OUT
echo "##### PHP $(php -r 'echo PHP_VERSION;') #####"

echo "=== lint (php -l, E_ALL) ==="
for pair in "wordpress:$WP" "xenforo:$XF" "chevereto:$CH"; do
  app=${pair%%:*}; root=${pair#*:}
  find "$root" -type f -name '*.php' -print0 \
    | xargs -0 -P 16 -n 40 sh -c 'for f; do php -d error_reporting=-1 -d display_errors=1 -d log_errors=0 -l "$f" 2>&1; done' _ \
    | grep -vE '^(No syntax errors|Errors parsing|$)' > $OUT/lint-$app.txt
  files=$(find "$root" -type f -name '*.php' | wc -l)
  printf '%-10s files=%-6s deprecated=%-5s warning=%-4s fatal/parse=%s\n' "$app" "$files" \
    "$(grep -c 'Deprecated:' $OUT/lint-$app.txt)" "$(grep -c 'Warning:' $OUT/lint-$app.txt)" \
    "$(grep -cE '(Fatal|Parse) error:' $OUT/lint-$app.txt)"
  sed -E 's/ in \/var\/www\/[^ ]+ on line [0-9]+//; s/^PHP //' $OUT/lint-$app.txt | sort | uniq -c | sort -rn | head -6 | cut -c1-200
  grep -E '(Fatal|Parse) error:' $OUT/lint-$app.txt | sed -E 's#/var/www/[^/]+/public/##' | head -5 | cut -c1-220
done

echo "=== run-time (apps in debug / E_ALL mode) ==="
cp -p $WP/wp-config.php /root/audit/wp-config.keep
cp -p $XF/src/config.php /root/audit/xf-config.keep
cp -p $XF/src/XF.php /root/audit/XF.php.keep
cp -p $CH/app/env.php /root/audit/chev-env.keep
sed -i "s|^define('WP_DEBUG', false);|define('WP_DEBUG', true); define('WP_DEBUG_LOG', '$LOG');|" $WP/wp-config.php
printf "\$config['debug'] = true;\n" >> $XF/src/config.php
sed -i 's|error_reporting(E_ALL & ~E_DEPRECATED);|error_reporting(E_ALL);|' $XF/src/XF.php
sed -i "s|^\];|  'CHEVERETO_ERROR_LOG' => '$LOG', 'CHEVERETO_ERROR_LOG_CLI' => '$LOG', 'CHEVERETO_ERROR_LOG_CRON' => '$LOG',\n];|" $CH/app/env.php
mariadb -N xenforo -e 'TRUNCATE xf_error_log'
systemctl reload php$V-fpm
TOP=${TOP:-8} bash "$(dirname -- "${BASH_SOURCE[0]}")/exercise-apps.sh" 2>&1 | tee $OUT/exercise.txt | grep -vE ' (200|301|302|303|0)$'
mariadb -N xenforo -e "select count(*), left(message,170), substring_index(filename,'/public/',-1) from xf_error_log group by 2,3 order by 1 desc" > $OUT/xf-errors.txt
echo "-- xenforo run-time, outside src/vendor:"; grep -v "src/vendor/" $OUT/xf-errors.txt | head -8 | cut -c1-260
echo "-- xenforo run-time, vendor libraries: $(grep -c "src/vendor/" $OUT/xf-errors.txt) distinct"
cat /root/audit/wp-config.keep > $WP/wp-config.php; cat /root/audit/xf-config.keep > $XF/src/config.php
cat /root/audit/XF.php.keep > $XF/src/XF.php; cat /root/audit/chev-env.keep > $CH/app/env.php
mariadb -N xenforo -e 'TRUNCATE xf_error_log'
systemctl reload php$V-fpm
echo "ok-status lines: $(grep -cE ' (200|301|302|303|0)$' $OUT/exercise.txt)"
