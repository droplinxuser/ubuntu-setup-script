<?php
declare(strict_types=1);

return [
    'db' => [
        // "localhost" makes PDO use the Unix socket, which is faster than TCP
        // for applications running on the same host.
        'host' => getenv('STRESS_DB_HOST') ?: 'localhost',
        'name' => getenv('STRESS_DB_NAME') ?: 'stress_test',
        'user' => getenv('STRESS_DB_USER') ?: 'demo',
        'pass' => getenv('STRESS_DB_PASS') ?: 'temp',
    ],
    'valkey' => [
        'host' => getenv('STRESS_VALKEY_HOST') ?: '127.0.0.1',
        'port' => (int)(getenv('STRESS_VALKEY_PORT') ?: 6379),
        // Preferred for local PHP: no TCP port/TIME_WAIT pressure.
        'socket' => getenv('STRESS_VALKEY_SOCKET') ?: '/run/valkey/valkey.sock',
    ],
    'elastic' => getenv('STRESS_ELASTIC_URL') ?: 'http://127.0.0.1:9200',
    'node' => getenv('STRESS_NODE_URL') ?: 'http://127.0.0.1:3100/',
];
