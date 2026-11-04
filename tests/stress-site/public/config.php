<?php
declare(strict_types=1);

$config = [
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

// PHP-FPM clears the environment by default, so credentials supplied to the
// setup script are persisted in a small root:www-data file and merged here.
// Without this, the web workers silently fell back to demo/temp and filled
// MariaDB's error log with "Access denied" on every request.
$localConfig = '/etc/stress-site-config.json';
if (is_readable($localConfig)) {
    $json = file_get_contents($localConfig);
    $values = is_string($json) ? json_decode($json, true) : null;
    if (is_array($values)) {
        $config['db']['host'] = $values['STRESS_DB_HOST'] ?? $config['db']['host'];
        $config['db']['name'] = $values['STRESS_DB_NAME'] ?? $config['db']['name'];
        $config['db']['user'] = $values['STRESS_DB_USER'] ?? $config['db']['user'];
        $config['db']['pass'] = $values['STRESS_DB_PASS'] ?? $config['db']['pass'];
        $config['valkey']['host'] = $values['STRESS_VALKEY_HOST'] ?? $config['valkey']['host'];
        $config['valkey']['port'] = (int)($values['STRESS_VALKEY_PORT'] ?? $config['valkey']['port']);
        $config['valkey']['socket'] = $values['STRESS_VALKEY_SOCKET'] ?? $config['valkey']['socket'];
        $config['elastic'] = $values['STRESS_ELASTIC_URL'] ?? $config['elastic'];
        $config['node'] = $values['STRESS_NODE_URL'] ?? $config['node'];
    }
}

return $config;
