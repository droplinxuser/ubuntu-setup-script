<?php
/**
 * Deterministic PHP build probe for tests/bench-php-matrix/bench-php-sources.sh.
 *
 * Served through Angie + PHP-FPM it gives every arm the same work per request,
 * split so the report can tell a faster interpreter from faster C library
 * code:
 *
 *   cfuncs   json/preg/str/hash/array_sort  - C code, the part a compiler flag
 *                                             or -march can speed up
 *   oop      class instantiation + methods  - engine + OPcache, JIT-friendly
 *   loops    integer/float/array work       - the tracing JIT's own code
 *
 * The response is one small JSON line; request ?n=N to change the repeat
 * count.  Not cached: send any unlisted cookie (the guest cache default-denies
 * unknown cookies) or a Cache-Control: no-cache header.
 */
declare(strict_types=1);

$n = isset($_GET['n']) ? max(1, min(2000, (int) $_GET['n'])) : 120;

$t = static function (): int { return hrtime(true); };
$mark = static function (int $t0): float { return (hrtime(true) - $t0) / 1e6; };

$base = str_repeat('The quick brown fox jumps over the lazy dog. ', 40);

// ---- C library work -------------------------------------------------------
$t0 = $t();
$acc = 0;
for ($i = 0; $i < $n; $i++) {
    $s = str_replace(['quick', 'brown', 'lazy'], ['slow', 'red', 'busy'], $base);
    $parts = explode(' ', $s);
    $u = array_unique($parts);
    sort($u);
    $j = json_encode(['u' => $u, 'n' => count($u), 'i' => $i], JSON_THROW_ON_ERROR);
    $d = json_decode($j, true, 16, JSON_THROW_ON_ERROR);
    $h = hash('xxh128', $j . $i);
    if (preg_match_all('/(\w{5,})/', $s, $m) > 0) {
        $acc += count($m[1]) + $d['n'] + strlen($h) % 7;
    }
    $chunk = substr($s, 0, 4096);
    $acc += substr_count($chunk, 'o') + (int) crc32($chunk) % 13;
}
$cfuncs = $mark($t0);

// ---- objects and methods --------------------------------------------------
$t0 = $t();
$objs = [];
for ($i = 0; $i < $n; $i++) {
    $objs[] = new ProbeNode($i, $base);
}
$sum = 0;
foreach ($objs as $o) {
    $sum += $o->score() + $o->child(2)->score();
}
$oop = $mark($t0);
unset($objs);

// ---- userland arithmetic (JIT) -------------------------------------------
$t0 = $t();
$x = 0;
$arr = range(1, 400);
for ($i = 0; $i < $n * 20; $i++) {
    $x = ($x + ($i * 31) % 1009) ^ ($i & 255);
    $arr[$i % 400] = ($arr[$i % 400] + $x) % 65521;
}
$loops = $mark($t0);

header('Content-Type: application/json');
header('Cache-Control: no-store');
printf(
    "{\"cfuncs\":%.3f,\"oop\":%.3f,\"loops\":%.3f,\"acc\":%d,\"sum\":%d,\"x\":%d,\"jit\":%d}\n",
    $cfuncs,
    $oop,
    $loops,
    $acc % 100000,
    $sum % 100000,
    $x % 100000,
    (int) (function_exists('opcache_get_status') && (opcache_get_status(false)['jit']['on'] ?? false))
);

final class ProbeNode
{
    public function __construct(private int $id, private string $text) {}

    public function score(): int
    {
        return $this->id + strlen($this->text) + substr_count($this->text, 'e');
    }

    public function child(int $n): self
    {
        return new self($this->id + $n, substr($this->text, 0, 64));
    }
}
