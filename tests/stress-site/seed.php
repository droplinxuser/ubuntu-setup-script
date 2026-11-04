<?php
declare(strict_types=1);

/**
 * Seed the local stress site: MariaDB rows, an Elasticsearch index and a
 * two-frame GIF optimised with gifsicle.  Run as root after setup.sh and
 * after the stress-site files have been copied into the document root.
 */

$cfg = require __DIR__ . '/public/config.php';
$domain = getenv('STRESS_DOMAIN') ?: 'stress.invalid';
$root = '/var/www/' . $domain . '/public';

function es_request(string $method, string $url, ?string $body = null, string $contentType = 'application/json'): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 60,
        CURLOPT_HTTPHEADER => ['Content-Type: ' . $contentType],
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $response = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return [$code, $response];
}

// ---------------------------------------------------------------------------
// MariaDB
// ---------------------------------------------------------------------------
$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $cfg['db']['host'], $cfg['db']['name']),
    $cfg['db']['user'],
    $cfg['db']['pass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
$pdo->exec('DROP TABLE IF EXISTS bench_items');
$pdo->exec(<<<SQL
CREATE TABLE bench_items (
  id INT UNSIGNED NOT NULL PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  body TEXT NOT NULL,
  created_at DATETIME NOT NULL,
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
SQL);
$pdo->exec(<<<SQL
INSERT INTO bench_items (id, title, body, created_at)
SELECT seq,
       CONCAT('Stress item ', seq),
       CONCAT('The quick brown fox jumps over the lazy dog. Row ', seq, ' ',
              REPEAT('payload ', 20)),
       NOW() - INTERVAL seq SECOND
FROM seq_1_to_50000
SQL);
$count = (int)$pdo->query('SELECT COUNT(*) FROM bench_items')->fetchColumn();
echo "MariaDB: {$count} rows in bench_items\n";

// ---------------------------------------------------------------------------
// Elasticsearch
// ---------------------------------------------------------------------------
$es = rtrim($cfg['elastic'], '/');
es_request('DELETE', $es . '/stress_pages');
[$code, $response] = es_request('PUT', $es . '/stress_pages', json_encode([
    'settings' => ['number_of_shards' => 1, 'number_of_replicas' => 0, 'refresh_interval' => '1s'],
    'mappings' => [
        'properties' => [
            'title' => ['type' => 'text'],
            'body' => ['type' => 'text'],
            'created_at' => ['type' => 'date'],
        ],
    ],
], JSON_THROW_ON_ERROR));
if ($code !== 200) {
    fwrite(STDERR, "Elasticsearch index create failed: {$code} {$response}\n");
    exit(1);
}

$bulk = '';
for ($i = 1; $i <= 5000; $i++) {
    $bulk .= json_encode(['index' => ['_index' => 'stress_pages', '_id' => (string)$i]], JSON_THROW_ON_ERROR) . "\n";
    $bulk .= json_encode([
        'title' => "Stress page {$i}",
        'body' => "The quick brown fox jumps over the lazy dog. Page {$i} " . str_repeat('searchable ', 15),
        'created_at' => gmdate('c', time() - $i),
    ], JSON_THROW_ON_ERROR) . "\n";
}
[$code, $response] = es_request('POST', $es . '/_bulk?refresh=true', $bulk, 'application/x-ndjson');
if ($code !== 200) {
    fwrite(STDERR, "Elasticsearch bulk failed: {$code} {$response}\n");
    exit(1);
}
$decoded = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
if (!empty($decoded['errors'])) {
    fwrite(STDERR, "Elasticsearch bulk reported item errors\n");
    exit(1);
}
echo "Elasticsearch: indexed 5000 documents into stress_pages\n";

// ---------------------------------------------------------------------------
// GifSicle
// ---------------------------------------------------------------------------
$frameFiles = [];
foreach ([
    ['Angie', [15, 23, 42], [56, 189, 248]],
    ['PHP + DB', [49, 16, 80], [244, 114, 182]],
] as $index => [$label, $bg, $fg]) {
    $im = imagecreatetruecolor(240, 120);
    $bgColor = imagecolorallocate($im, ...$bg);
    $fgColor = imagecolorallocate($im, ...$fg);
    imagefilledrectangle($im, 0, 0, 239, 119, $bgColor);
    imagestring($im, 5, 24, 52, $label, $fgColor);
    $file = "/tmp/stress-frame-{$index}.gif";
    imagegif($im, $file);
    imagedestroy($im);
    $frameFiles[] = $file;
}
$out = $root . '/assets/logo.gif';
$gifLog = '/var/www/logs/gifsicle/gifsicle.log';
if (!is_dir(dirname($gifLog))) {
    @mkdir(dirname($gifLog), 0750, true);
}
$cmd = sprintf(
    'gifsicle --delay=30 --loopcount=0 -O3 --colors 64 %s > %s 2>> %s',
    implode(' ', array_map('escapeshellarg', $frameFiles)),
    escapeshellarg($out),
    escapeshellarg($gifLog)
);
exec($cmd, $output, $status);
if ($status !== 0 || !is_file($out)) {
    copy($frameFiles[0], $out);
    echo "GifSicle: unavailable or failed; copied a static GIF instead\n";
} else {
    echo 'GifSicle: wrote ' . $out . ' (' . filesize($out) . " bytes)\n";
}
foreach ($frameFiles as $file) {
    @unlink($file);
}
