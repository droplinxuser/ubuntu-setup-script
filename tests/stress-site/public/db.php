<?php
declare(strict_types=1);
$cfg = require __DIR__ . '/config.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
$t = microtime(true);
try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $cfg['db']['host'], $cfg['db']['name']),
        $cfg['db']['user'],
        $cfg['db']['pass'],
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]
    );
    $stmt = $pdo->prepare('SELECT id, title, LEFT(body, 160) AS excerpt FROM bench_items WHERE id = ?');
    $stmt->execute([random_int(1, 50000)]);
    echo json_encode([
        'ok' => true,
        'row' => $stmt->fetch() ?: null,
        'ms' => round((microtime(true) - $t) * 1000, 2),
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(503);
    echo json_encode(['ok' => false, 'error' => $e->getMessage()], JSON_THROW_ON_ERROR);
}
