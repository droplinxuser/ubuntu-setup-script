<?php
declare(strict_types=1);
$cfg = require __DIR__ . '/config.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
$t = microtime(true);
try {
    $body = json_encode([
        'size' => 5,
        'query' => ['match' => ['body' => $_GET['q'] ?? 'quick brown fox']],
        'sort' => [['created_at' => 'desc']],
    ], JSON_THROW_ON_ERROR);
    $ch = curl_init($cfg['elastic'] . '/stress_pages/_search');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => $body,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT_MS => 2000,
    ]);
    $response = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($response === false || $code !== 200) {
        throw new RuntimeException('Elasticsearch HTTP ' . $code);
    }
    $decoded = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
    echo json_encode([
        'ok' => true,
        'took' => $decoded['took'] ?? null,
        'total' => $decoded['hits']['total']['value'] ?? null,
        'ids' => array_map(static fn(array $h): string => (string)$h['_id'], $decoded['hits']['hits'] ?? []),
        'ms' => round((microtime(true) - $t) * 1000, 2),
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(503);
    echo json_encode(['ok' => false, 'error' => $e->getMessage()], JSON_THROW_ON_ERROR);
}
