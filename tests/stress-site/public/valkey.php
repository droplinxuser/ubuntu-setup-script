<?php
declare(strict_types=1);

function valkey_client(array $cfg): Redis
{
    $redis = new Redis();
    $socket = $cfg['valkey']['socket'] ?? '';
    if ($socket !== '' && file_exists($socket)) {
        // Unix sockets avoid ephemeral-port/TIME_WAIT pressure when PHP makes
        // a fresh local connection for every request.
        $redis->connect($socket, 0, 0.5);
    } else {
        $redis->connect($cfg['valkey']['host'], $cfg['valkey']['port'], 0.5);
    }
    $redis->setOption(Redis::OPT_READ_TIMEOUT, 0.5);
    return $redis;
}
