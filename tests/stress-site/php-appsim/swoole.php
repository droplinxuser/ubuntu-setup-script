<?php
/* Swoole / OpenSwoole HTTP server.  Port and class come from the command line. */
declare(strict_types=1);
require __DIR__ . '/lib.php';

$port = (int) ($argv[1] ?? 8084);
$class = (string) ($argv[2] ?? 'Swoole\\Http\\Server');
$workers = (int) ($argv[3] ?? 12);

/** @var \Swoole\Http\Server $server */
$server = new $class('127.0.0.1', $port);
$server->set([
    'worker_num' => $workers,
    'enable_coroutine' => false,
    'log_level' => SWOOLE_LOG_ERROR,
    'max_request' => 0,
    'open_tcp_nodelay' => true,
]);
$server->on('workerStart', static function (): void {
    appsim_bootstrap();
});
$server->on('request', static function ($request, $response): void {
    $response->header('Content-Type', 'text/html; charset=utf-8');
    $response->end(appsim_worker_request((int) ($request->get['n'] ?? 1)));
});
$server->start();
