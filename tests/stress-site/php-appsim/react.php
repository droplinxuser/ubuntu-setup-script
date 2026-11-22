<?php
/* ReactPHP HTTP server.  Single event loop per process (ReactPHP's model). */
declare(strict_types=1);
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/lib.php';

use Psr\Http\Message\ServerRequestInterface;
use React\EventLoop\Loop;
use React\Http\HttpServer;
use React\Http\Message\Response;
use React\Socket\SocketServer;

$port = (int) ($argv[1] ?? 8087);

appsim_bootstrap();

$http = new HttpServer(static function (ServerRequestInterface $request) {
    return new Response(200, ['Content-Type' => 'text/html; charset=utf-8'], appsim_worker_request(1));
});
$socket = new SocketServer('127.0.0.1:' . $port, ['reusePort' => true], Loop::get());
$http->listen($socket);
Loop::run();
