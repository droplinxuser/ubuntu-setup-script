<?php
/* Router for PHP's built-in server, so every path reaches index.php. */
declare(strict_types=1);
if (is_file(__DIR__ . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH))) {
    return false;
}
require __DIR__ . '/index.php';
