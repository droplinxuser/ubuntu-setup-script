<?php
/* AMPHP HTTP server (Revolt event loop, single process per instance). */
declare(strict_types=1);
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/lib.php';

use Amp\Http\Server\DefaultErrorHandler;
use Amp\Http\Server\Request;
use Amp\Http\Server\RequestHandler\ClosureRequestHandler;
use Amp\Http\Server\Response;
use Amp\Http\Server\SocketHttpServer;
use Amp\Socket\InternetAddress;
use Psr\Log\NullLogger;

$port = (int) ($argv[1] ?? 8088);

appsim_bootstrap();

$server = SocketHttpServer::createForDirectAccess(new NullLogger());
$server->expose(
    new InternetAddress('127.0.0.1', $port),
    (new Amp\Socket\BindContext())->withReusePort()
);
$handler = new ClosureRequestHandler(static function (Request $request): Response {
    return new Response(200, ['Content-Type' => 'text/html; charset=utf-8'], appsim_worker_request(1));
});
$server->start($handler, new DefaultErrorHandler());
Revolt\EventLoop::run();
