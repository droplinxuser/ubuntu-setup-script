<?php
/**
 * Shared workload for every runtime in php-server-shootout.sh.
 *
 * appsim_bootstrap() is the "framework": it eagerly includes 60 class files.
 * Classic SAPIs run it on every request; worker runtimes run it once.
 * appsim_request() is one rendered page: two MariaDB statements, one Valkey
 * GET, a 30 KB template, a hash and a JSON round trip.
 */
declare(strict_types=1);

function appsim_bootstrap(): void
{
    static $done = false;
    if ($done) {
        return;
    }
    foreach (glob(__DIR__ . '/lib/*.php') ?: [] as $file) {
        require_once $file;
    }
    $done = true;
}

function appsim_db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO(
            'mysql:host=127.0.0.1;dbname=wordpress;charset=utf8mb4',
            'wpuser',
            'temp',
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_PERSISTENT => true,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            ]
        );
    }
    return $pdo;
}

function appsim_cache(): Redis
{
    static $redis = null;
    if ($redis === null) {
        $redis = new Redis();
        // The Unix socket: setup.sh runs Valkey socket-only (port 0) since 1.22.5.
        $redis->pconnect('/run/valkey/valkey.sock', 0, 1.0);
    }
    return $redis;
}

function appsim_render(string $title, string $content, int $id, string $excerpt): string
{
    static $template = null;
    if ($template === null) {
        $template = file_get_contents(__DIR__ . '/template.html');
    }
    return str_replace(
        ['$title', '$content', '$id', '$excerpt'],
        [$title, $content, (string) $id, $excerpt],
        $template
    );
}

function appsim_request(int $seq = 1): string
{
    appsim_bootstrap();

    $id = 1 + ($seq % 400);
    $pdo = appsim_db();

    $stmt = $pdo->prepare(
        "SELECT ID, post_title, post_content FROM wp_posts
          WHERE ID >= ? AND post_type = 'post' AND post_status = 'publish'
          ORDER BY ID LIMIT 1"
    );
    $stmt->execute([$id]);
    $post = $stmt->fetch();
    if (!$post) {
        $post = ['ID' => $id, 'post_title' => 'Page ' . $id, 'post_content' => 'body'];
    }

    $comments = $pdo->query(
        'SELECT COUNT(*) FROM wp_comments WHERE comment_post_ID = ' . (int) $post['ID']
    )->fetchColumn();

    $cache = appsim_cache();
    $key = 'appsim:' . $id;
    $cached = $cache->get($key);
    if ($cached === false) {
        $cached = str_repeat('c', 2048);
        $cache->set($key, $cached, 300);
    }

    $title = htmlspecialchars((string) $post['post_title'], ENT_QUOTES, 'UTF-8');
    $body = htmlspecialchars(substr((string) $post['post_content'], 0, 600), ENT_QUOTES, 'UTF-8');
    $excerpt = htmlspecialchars(substr($cached, 0, 120), ENT_QUOTES, 'UTF-8');
    $html = appsim_render($title, $body, (int) $post['ID'], $excerpt);

    /* CPU a template engine, a JSON API response and a cache key do anyway. */
    $digest = hash('sha256', $html);
    $payload = json_encode([
        'id' => $id,
        'comments' => (int) $comments,
        'digest' => $digest,
        'rows' => array_fill(0, 40, 'row'),
    ]);
    $decoded = json_decode($payload, true);
    usort($decoded['rows'], static fn ($a, $b) => strcmp($a, $b));

    return $html . "\n<!-- $digest -->\n";
}

/** Payload for a worker that has already booted: no include cost. */
function appsim_worker_request(int $seq): string
{
    return appsim_request($seq);
}
