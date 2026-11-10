<?php
// WordPress seed script for the audit host. Run as www-data from the WP root.
// Idempotent: counts existing rows and tops them up.
define('WP_INSTALLING', false);
require __DIR__ . '/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';

$USERS = (int)($argv[1] ?? 100);
$POSTS = (int)($argv[2] ?? 400);
$COMMENTS = (int)($argv[3] ?? 300);

update_option('siteurl', 'https://wp.test.local');
update_option('home', 'https://wp.test.local');
update_option('permalink_structure', '/%postname%/');
update_option('timezone_string', 'UTC');
update_option('blogdescription', 'SER8 audit site');
flush_rewrite_rules(false);

$userCount = count(get_users(['fields' => 'ID']));
echo "users before: $userCount\n";
for ($i = $userCount; $i < $USERS; $i++) {
    $name = 'bench' . $i;
    if (username_exists($name) || email_exists($name . '@example.com')) {
        continue;
    }
    $id = wp_create_user($name, 'BenchPass123!', $name . '@example.com');
    if (!is_wp_error($id)) {
        (new WP_User($id))->set_role($i % 10 === 0 ? 'editor' : ($i % 3 === 0 ? 'author' : 'subscriber'));
    }
}
$userIds = get_users(['fields' => 'ID']);
echo 'users now: ' . count($userIds) . "\n";

$postCount = (int)wp_count_posts('post')->publish;
echo "posts before: $postCount\n";
$catId = (int)get_option('default_category');
for ($i = $postCount; $i < $POSTS; $i++) {
    $author = (int)$userIds[$i % count($userIds)];
    $content = str_repeat('Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ', 8);
    $content .= "\n\n<!-- wp:paragraph -->\n<p>" . str_repeat('Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris. ', 5) . "</p>\n<!-- /wp:paragraph -->";
    $id = wp_insert_post([
        'post_title'   => 'Benchmark post ' . ($i + 1) . ' ' . substr(md5((string)$i), 0, 6),
        'post_content' => $content,
        'post_status'  => 'publish',
        'post_author'  => $author,
        'post_type'    => 'post',
        'post_category'=> [$catId],
        'post_date'    => gmdate('Y-m-d H:i:s', time() - ($POSTS - $i) * 3600),
    ], true);
    if (is_wp_error($id)) {
        echo "post $i: " . $id->get_error_message() . "\n";
        continue;
    }
    if ($i % 5 === 0) {
        wp_set_post_tags($id, ['benchmark', 'audit', 'performance'], false);
    }
}

$commentCount = (int)wp_count_comments()->approved;
echo "comments before: $commentCount\n";
$postIds = get_posts(['fields' => 'ids', 'posts_per_page' => -1, 'post_status' => 'publish']);
for ($i = $commentCount; $i < $COMMENTS; $i++) {
    $postId = (int)$postIds[$i % count($postIds)];
    $author = (int)$userIds[$i % count($userIds)];
    wp_insert_comment([
        'comment_post_ID'      => $postId,
        'comment_author'       => 'bench' . ($i % count($userIds)),
        'comment_author_email' => 'bench' . ($i % count($userIds)) . '@example.com',
        'comment_author_url'   => '',
        'comment_content'      => 'Benchmark comment ' . ($i + 1) . ': ' . str_repeat('Nice writeup. ', 3),
        'comment_type'         => 'comment',
        'comment_parent'       => 0,
        'user_id'              => $author,
        'comment_approved'     => 1,
        'comment_date'         => gmdate('Y-m-d H:i:s', time() - ($COMMENTS - $i) * 600),
    ]);
}
echo "posts: " . wp_count_posts('post')->publish . " comments: " . wp_count_comments()->approved . " users: " . count(get_users(['fields' => 'ID'])) . "\n";
