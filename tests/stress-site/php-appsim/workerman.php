<?php
/* Workerman HTTP server.  `start` is Workerman's CLI command; the listener
 * and worker count come from the environment so the harness controls them. */
declare(strict_types=1);
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/lib.php';

use Workerman\Connection\TcpConnection;
use Workerman\Protocols\Http\Request;
use Workerman\Protocols\Http\Response;
use Workerman\Worker;

$port = (int) (getenv('WM_PORT') ?: 8086);
$workers = (int) (getenv('WM_COUNT') ?: 12);

$http = new Worker('http://127.0.0.1:' . $port);
$http->count = $workers;
$http->onWorkerStart = static function (): void {
    appsim_bootstrap();
};
$http->onMessage = static function (TcpConnection $connection, Request $request): void {
    $connection->send(new Response(200, ['Content-Type' => 'text/html; charset=utf-8'], appsim_worker_request((int) ($request->get('n') ?? 1))));
};
Worker::runAll();
