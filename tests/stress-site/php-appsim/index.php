<?php
/* Classic (one process per request) endpoint: FPM, CGI, FrankenPHP, php -S. */
declare(strict_types=1);
require __DIR__ . '/lib.php';

$seq = (int) ($_GET['n'] ?? 1);
header('Content-Type: text/html; charset=utf-8');
header('X-Appsim-Mode: classic');
echo appsim_request($seq);
