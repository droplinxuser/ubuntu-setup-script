<?php
declare(strict_types=1);
$cfg = require __DIR__ . '/config.php';
require_once __DIR__ . '/valkey.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
$t = microtime(true);
try {
    $redis = valkey_client($cfg);
    $hits = $redis->incr('stress:cache:hits');
    $redis->expire('stress:cache:hits', 3600);
    $redis->setex('stress:cache:last', 60, (string)microtime(true));
    echo json_encode([
        'ok' => true,
        'hits' => $hits,
        'last' => $redis->get('stress:cache:last'),
        'ms' => round((microtime(true) - $t) * 1000, 2),
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(503);
    echo json_encode(['ok' => false, 'error' => $e->getMessage()], JSON_THROW_ON_ERROR);
}
