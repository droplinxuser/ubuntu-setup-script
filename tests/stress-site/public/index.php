<?php
declare(strict_types=1);

$cfg = require __DIR__ . '/config.php';
require_once __DIR__ . '/valkey.php';
$timings = [];
$errors = [];

$t0 = microtime(true);

// --- MariaDB: a single indexed row lookup (what a forum thread view does) ---
$dbRow = null;
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
    $stmt = $pdo->prepare('SELECT id, title, LEFT(body, 120) AS excerpt FROM bench_items WHERE id = ?');
    $stmt->execute([random_int(1, 50000)]);
    $dbRow = $stmt->fetch() ?: null;
} catch (Throwable $e) {
    $errors[] = 'MariaDB: ' . $e->getMessage();
}
$timings['mariadb_ms'] = round((microtime(true) - $t) * 1000, 2);

// --- Valkey: page-view counter and a short-lived cached fragment ---
$cacheHits = null;
$t = microtime(true);
try {
    $redis = valkey_client($cfg);
    $cacheHits = $redis->incr('stress:index:hits');
    $redis->expire('stress:index:hits', 3600);
    $fragmentKey = 'stress:fragment:' . (($cacheHits ?? 1) % 50);
    if (!$redis->exists($fragmentKey)) {
        $redis->setex($fragmentKey, 30, 'fragment-' . $fragmentKey);
    }
} catch (Throwable $e) {
    $errors[] = 'Valkey: ' . $e->getMessage();
}
$timings['valkey_ms'] = round((microtime(true) - $t) * 1000, 2);

// --- Elasticsearch: a realistic full-text search with a small result set ---
$searchHits = null;
$t = microtime(true);
try {
    $body = json_encode([
        'size' => 3,
        'query' => ['match' => ['body' => 'quick brown fox']],
        'sort' => [['created_at' => 'desc']],
    ], JSON_THROW_ON_ERROR);
    $ch = curl_init($cfg['elastic'] . '/stress_pages/_search');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => $body,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT_MS => 1500,
    ]);
    $response = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($response !== false && $code === 200) {
        $decoded = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
        $searchHits = $decoded['hits']['total']['value'] ?? null;
    } else {
        $errors[] = 'Elasticsearch: HTTP ' . $code;
    }
} catch (Throwable $e) {
    $errors[] = 'Elasticsearch: ' . $e->getMessage();
}
$timings['elastic_ms'] = round((microtime(true) - $t) * 1000, 2);

// --- Node.js: call the clustered Node service through its local port ---
$nodeData = null;
$t = microtime(true);
try {
    $ch = curl_init($cfg['node']);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT_MS => 1000,
    ]);
    $response = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($response !== false && $code === 200) {
        $nodeData = json_decode($response, true);
    } else {
        $errors[] = 'Node.js: HTTP ' . $code;
    }
} catch (Throwable $e) {
    $errors[] = 'Node.js: ' . $e->getMessage();
}
$timings['node_ms'] = round((microtime(true) - $t) * 1000, 2);

$timings['total_ms'] = round((microtime(true) - $t0) * 1000, 2);

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Stress-Site: angie-php-mariadb-valkey-elastic-node-gifsicle');
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Full stack stress site</title>
  <link rel="stylesheet" href="/assets/style.css">
</head>
<body>
  <main>
    <h1>Angie + PHP + MariaDB + Valkey + Elasticsearch + Node.js + GifSicle</h1>
    <p class="lead">Every request below touches all six runtime services. The GIF is optimized with <code>gifsicle -O3</code>.</p>

    <section class="grid">
      <article>
        <h2>MariaDB</h2>
        <p><?= $dbRow ? htmlspecialchars($dbRow['title'], ENT_QUOTES, 'UTF-8') : 'unavailable' ?></p>
        <pre><?= htmlspecialchars((string)($dbRow['excerpt'] ?? ''), ENT_QUOTES, 'UTF-8') ?></pre>
        <small><?= $timings['mariadb_ms'] ?> ms</small>
      </article>
      <article>
        <h2>Valkey</h2>
        <p>Page-view counter: <strong><?= $cacheHits ?? 'unavailable' ?></strong></p>
        <small><?= $timings['valkey_ms'] ?> ms</small>
      </article>
      <article>
        <h2>Elasticsearch</h2>
        <p>Matching documents: <strong><?= $searchHits ?? 'unavailable' ?></strong></p>
        <small><?= $timings['elastic_ms'] ?> ms</small>
      </article>
      <article>
        <h2>Node.js</h2>
        <p>Worker PID: <strong><?= htmlspecialchars((string)($nodeData['pid'] ?? 'unavailable'), ENT_QUOTES, 'UTF-8') ?></strong></p>
        <small><?= $timings['node_ms'] ?> ms</small>
      </article>
    </section>

    <section>
      <h2>GifSicle asset</h2>
      <p><img src="/assets/logo.gif" width="240" height="120" alt="Optimized GIF"></p>
      <p class="timings">Total render: <?= $timings['total_ms'] ?> ms</p>
    </section>

    <?php if ($errors): ?>
      <section class="errors">
        <h2>Service warnings</h2>
        <ul>
          <?php foreach ($errors as $error): ?>
            <li><?= htmlspecialchars($error, ENT_QUOTES, 'UTF-8') ?></li>
          <?php endforeach; ?>
        </ul>
      </section>
    <?php endif; ?>

    <nav>
      <a href="/static.html">Static HTML</a>
      <a href="/hello.php">PHP hello</a>
      <a href="/db.php">MariaDB JSON</a>
      <a href="/cache.php">Valkey JSON</a>
      <a href="/search.php">Elasticsearch JSON</a>
      <a href="/node/">Node.js proxy</a>
    </nav>
  </main>
  <script src="/assets/app.js"></script>
</body>
</html>
