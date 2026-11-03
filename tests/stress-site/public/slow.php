<?php
declare(strict_types=1);
$ms = max(0, min(5000, (int)($_GET['ms'] ?? 100)));
usleep($ms * 1000);
header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');
echo "slept {$ms} ms\n";
