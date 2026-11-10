<?php
// XenForo 2.x seed script for the audit host. Run as www-data from the XF root.
// Uses XenForo's own service classes and visitor context, so caches, counters,
// last-post pointers and the search index stay consistent.
require __DIR__ . '/src/XF.php';
\XF::start(__DIR__);
$app = \XF::app();

$USERS = (int)($argv[1] ?? 60);
$THREADS = (int)($argv[2] ?? 200);
$REPLIES = (int)($argv[3] ?? 2400);

$admin = $app->em()->find('XF:User', 1);
if (!$admin) {
    fwrite(STDERR, "admin user missing\n");
    exit(1);
}

$makeUser = function (string $name) use ($app, $admin) {
    return \XF::asVisitor($admin, function () use ($app, $name) {
        /** @var \XF\Service\User\RegistrationService $reg */
        $reg = $app->service('XF:User\Registration');
        $reg->setMapped([
            'username' => $name,
            'email'    => $name . '@example.com',
            'timezone' => 'UTC',
        ]);
        $reg->setPassword('BenchPass123!', '', false);
        $reg->skipEmailConfirmation();
        return $reg->save();
    });
};

$existingUsers = (int)$app->db()->fetchOne('SELECT COUNT(*) FROM xf_user');
echo "users before: $existingUsers\n";
for ($i = $existingUsers; $i < $USERS; $i++) {
    try {
        $makeUser('bench' . $i);
    } catch (\Throwable $e) {
        echo "user bench$i: " . $e->getMessage() . "\n";
    }
}
$userIds = $app->db()->fetchAllColumn('SELECT user_id FROM xf_user WHERE user_state = ? ORDER BY user_id', ['valid']);
echo 'valid users: ' . count($userIds) . "\n";

$forumId = (int)$app->db()->fetchOne('SELECT node_id FROM xf_node WHERE node_type_id = ? LIMIT 1', ['Forum']);
if (!$forumId) {
    fwrite(STDERR, "no forum node\n");
    exit(1);
}
$forum = $app->em()->find('XF:Forum', $forumId);

$threadCount = (int)$app->db()->fetchOne('SELECT COUNT(*) FROM xf_thread');
echo "threads before: $threadCount\n";
for ($i = $threadCount; $i < $THREADS; $i++) {
    $author = $app->em()->find('XF:User', $userIds[$i % count($userIds)]);
    try {
        \XF::asVisitor($author, function () use ($app, $forum, $i) {
            /** @var \XF\Service\Thread\CreatorService $creator */
            $creator = $app->service('XF:Thread\Creator', $forum);
            $creator->setContent(
                'Benchmark thread ' . ($i + 1) . ' - ' . substr(bin2hex(random_bytes(4)), 0, 6),
                "This is benchmark thread " . ($i + 1) . ".\n\n"
                . str_repeat('Lorem ipsum dolor sit amet, consectetur adipiscing elit. ', 6)
            );
            $creator->setTags([]);
            $creator->save();
        });
    } catch (\Throwable $e) {
        echo "thread $i: " . $e->getMessage() . "\n";
    }
}

$threadRows = $app->db()->fetchAll('SELECT thread_id, user_id FROM xf_thread ORDER BY thread_id');
$replies = (int)$app->db()->fetchOne('SELECT COUNT(*) FROM xf_post') - count($threadRows);
echo "replies before: $replies\n";
for ($i = $replies; $i < $REPLIES; $i++) {
    $row = $threadRows[$i % count($threadRows)];
    $thread = $app->em()->find('XF:Thread', (int)$row['thread_id']);
    $author = $app->em()->find('XF:User', $userIds[$i % count($userIds)]);
    try {
        \XF::asVisitor($author, function () use ($app, $thread, $i) {
            /** @var \XF\Service\Thread\ReplierService $replier */
            $replier = $app->service('XF:Thread\Replier', $thread);
            $replier->setMessage(
                'Reply ' . ($i + 1) . ': ' . str_repeat('Lorem ipsum dolor sit amet. ', 4)
            );
            $replier->save();
        });
    } catch (\Throwable $e) {
        echo "reply $i: " . $e->getMessage() . "\n";
    }
}

echo "threads: " . $app->db()->fetchOne('SELECT COUNT(*) FROM xf_thread')
   . " posts: " . $app->db()->fetchOne('SELECT COUNT(*) FROM xf_post')
   . " users: " . $app->db()->fetchOne('SELECT COUNT(*) FROM xf_user') . "\n";
