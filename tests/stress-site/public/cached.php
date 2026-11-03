<?php
declare(strict_types=1);

// FastCGI-cached variant of index.php.  The vhost caches this exact URI for a
// few seconds, which is the single biggest win for large guest-heavy sites.
require __DIR__ . '/index.php';
