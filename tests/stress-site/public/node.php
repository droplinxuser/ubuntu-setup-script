<?php
declare(strict_types=1);
$cfg = require __DIR__ . '/config.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
$t = microtime(true);
try {
    $ch = curl_init($cfg['node']);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT_MS => 1500,
    ]);
    $response = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($response === false || $code !== 200) {
        throw new RuntimeException('Node.js HTTP ' . $code);
    }
    $decoded = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
    echo json_encode([
        'ok' => true,
        'node' => $decoded,
        'ms' => round((microtime(true) - $t) * 1000, 2),
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(503);
    echo json_encode(['ok' => false, 'error' => $e->getMessage()], JSON_THROW_ON_ERROR);
}
