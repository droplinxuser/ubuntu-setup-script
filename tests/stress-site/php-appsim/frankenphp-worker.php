<?php
/* FrankenPHP worker mode: the application is booted once per worker thread. */
declare(strict_types=1);
require __DIR__ . '/lib.php';

appsim_bootstrap();
$seq = 1;
while (frankenphp_handle_request(static function () use (&$seq): void {
    header('Content-Type: text/html; charset=utf-8');
    header('X-Appsim-Mode: worker');
    echo appsim_worker_request($seq++);
})) {
    /* next request */
}
