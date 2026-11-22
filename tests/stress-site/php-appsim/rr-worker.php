<?php
/* RoadRunner PSR-7 worker. */
declare(strict_types=1);
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/lib.php';

use Nyholm\Psr7\Factory\Psr17Factory;
use Nyholm\Psr7\Response;
use Spiral\RoadRunner\Http\PSR7Worker;
use Spiral\RoadRunner\Worker;

$factory = new Psr17Factory();
$worker = new PSR7Worker(Worker::create(), $factory, $factory, $factory);
appsim_bootstrap();

while (true) {
    try {
        $request = $worker->waitRequest();
        if ($request === null) {
            break;
        }
        $seq = (int) ($request->getQueryParams()['n'] ?? 1);
        $worker->respond(new Response(200, ['Content-Type' => 'text/html; charset=utf-8'], appsim_worker_request($seq)));
    } catch (Throwable $e) {
        $worker->respond(new Response(400, [], $e->getMessage()));
    }
}
