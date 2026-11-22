#!/usr/bin/env bash
# Fixtures that guest-cache-cookie-test.sh needs but the seeders do not make:
#
#   * a WordPress mu-plugin that sets a per-visitor `guest_token` cookie on
#     ?gc=1, so the test can prove that a response carrying Set-Cookie is
#     never stored in the FastCGI guest cache;
#   * the bench5 account in WordPress and XenForo (the seeders create bench1
#     to bench100 already, so this is normally a no-op check);
#   * a known password for the Chevereto admin, whose install password is
#     random (deploy-three-apps.sh writes it to /root/audit/test-admin-pass).
#
# Without these the cookie test reported eight failures on a correctly
# configured host: a missing cookie-setting endpoint cannot be cached, so
# "MISSMISSMISS" became "MISSHITHIT", and the Chevereto login answered 200.
#
# Usage: bash seed-guest-cache-fixtures.sh            (as root)
#   BENCH_PASSWORD  password of bench5 in WordPress/XenForo (default
#                   BenchPass123!, what seed-wp.php and seed-xf.php set)
#   CHEV_PASSWORD   password to give the Chevereto admin; default: the
#                   contents of /root/audit/test-admin-pass when readable,
#                   else BenchPass123!
# Prints the two passwords to use for the test on the last two lines.
set -Eeuo pipefail

WP=${WP:-/var/www/wp.test.local/public}
XF=${XF:-/var/www/xf.test.local/public}
CH=${CH:-/var/www/chev.test.local/public}
BENCH_PASSWORD=${BENCH_PASSWORD:-BenchPass123!}
CHEV_PASSWORD=${CHEV_PASSWORD:-}
if [[ -z $CHEV_PASSWORD && -r /root/audit/test-admin-pass ]]; then
  CHEV_PASSWORD=$(< /root/audit/test-admin-pass)
fi
CHEV_PASSWORD=${CHEV_PASSWORD:-BenchPass123!}

[[ -d $WP && -d $XF && -d $CH ]] || { echo "the three audit vhosts are required" >&2; exit 1; }

# ---- WordPress: cookie-setting endpoint (mu-plugin, no activation needed)
mu="$WP/wp-content/mu-plugins"
mkdir -p "$mu"
cat > "$mu/audit-guest-cookie.php" <<'PHP'
<?php
/**
 * Audit fixture for guest-cache-cookie-test.sh: a guest page that sets a
 * cookie must never be stored by the FastCGI cache, because the stored page
 * would then be replayed to visitors who did not ask for it.
 */
add_action('init', static function (): void {
    if (!isset($_GET['gc']) || headers_sent()) {
        return;
    }
    setcookie('guest_token', bin2hex(random_bytes(12)), 0, '/');
});
/*
 * ?vary=ua: a page that varies on the User-Agent (as a mobile plugin does).
 * The guest caches ignore Vary for storage, so such a response must not be
 * stored at all ($guest_cache_vary_other).
 */
add_action('send_headers', static function (): void {
    if (isset($_GET['vary'])) {
        header('Vary: User-Agent', false);
    }
});
PHP
chown www-data:www-data "$mu/audit-guest-cookie.php"
chmod 644 "$mu/audit-guest-cookie.php"

# ---- bench5 in WordPress and XenForo with the documented password
if [[ -f $WP/wp-load.php ]]; then
  runuser -u www-data -- php -d display_errors=0 -r '
    $_SERVER["HTTP_HOST"] = "wp.test.local";
    require $argv[1] . "/wp-load.php";
    $pw = $argv[2];
    $user = get_user_by("login", "bench5");
    if ($user) {
        wp_set_password($pw, $user->ID);
        echo "wordpress bench5: password reset\n";
    } else {
        $id = wp_create_user("bench5", $pw, "bench5@example.com");
        echo is_wp_error($id) ? "wordpress bench5: " . $id->get_error_message() . "\n" : "wordpress bench5: created\n";
    }
  ' "$WP" "$BENCH_PASSWORD"
fi
if [[ -f $XF/cmd.php ]]; then
  cat > "$XF/audit-fixture-user.php" <<'PHP'
<?php
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::setupApp('XF\Cli\App');
$pw = $argv[1];
$user = \XF::finder('XF:User')->where('username', 'bench5')->fetchOne();
if ($user) {
    $auth = $user->Auth;
    $auth->setPassword($pw);
    $auth->save();
    echo "xenforo bench5: password reset\n";
    exit(0);
}
$writer = $app->dataWriter('XF:User');
$writer->bulkSet([
    'username' => 'bench5',
    'email'    => 'bench5@example.com',
    'user_group_id' => 2,
    'display_group_id' => 0,
    'message_count' => 0,
    'register_date' => \XF::$time,
    'last_activity' => \XF::$time,
]);
$writer->setPassword($pw, false);
$writer->save();
echo "xenforo bench5: created\n";
PHP
  ( cd "$XF" && runuser -u www-data -- php audit-fixture-user.php "$BENCH_PASSWORD" )
  rm -f "$XF/audit-fixture-user.php"
fi

# ---- Chevereto admin password (the installer generates a random one)
if [[ -f $CH/app/bin/legacy ]]; then
  ( cd "$CH" && runuser -u www-data -- php app/bin/legacy -C password-reset -u admin -x "$CHEV_PASSWORD" >/dev/null )
  echo "chevereto admin: password reset"
fi

# ---- tell the caller what to pass to guest-cache-cookie-test.sh
printf 'BENCH_PASSWORD=%s\nCHEV_PASSWORD=%s\n' "$BENCH_PASSWORD" "$CHEV_PASSWORD"
