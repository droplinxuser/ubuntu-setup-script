<?php
/**
 * Generate the shared "application shaped" workload used by
 * php-server-shootout.sh.
 *
 * The point is to give every PHP runtime the same work per request:
 * a framework-sized bootstrap (eager class files), one indexed MariaDB
 * read plus an aggregate, one Valkey GET, a template render and some
 * CPU.  Classic SAPIs pay the bootstrap on every request; worker-mode
 * runtimes pay it once at start-up.  That difference, not a synthetic
 * "hello world", is what the shootout reports.
 *
 * Usage: php gen.php OUTDIR
 */
$out = $argv[1] ?? __DIR__;
@mkdir($out . '/lib', 0777, true);

$files = 60;
for ($i = 0; $i < $files; $i++) {
    $class = sprintf('Appsim\\Service\\Handler%03d', $i);
    $short = 'Handler' . sprintf('%03d', $i);
    $body = "<?php\nnamespace Appsim\\Service;\n\nfinal class $short\n{\n";
    $body .= "    private array \$state = [];\n\n";
    $body .= "    public function handle(string \$key, int \$n): string\n    {\n";
    $body .= "        \$this->state[\$key] = (\$this->state[\$key] ?? 0) + \$n;\n";
    $body .= "        return \$key . ':' . \$this->state[\$key];\n    }\n\n";
    $body .= "    public function describe(): array\n    {\n";
    $body .= "        return ['handler' => '$short', 'state' => count(\$this->state)];\n";
    $body .= "    }\n}\n";
    file_put_contents($out . '/lib/' . $short . '.php', $body);
}

/* A page template with a real loop, so rendering costs something. */
$rows = '';
for ($i = 0; $i < 160; $i++) {
    $rows .= "  <li class=\"row-$i\"><a href=\"/thread/\$id/$i\">\$title</a><span>\$excerpt</span></li>\n";
}
$tpl = "<!doctype html>\n<html><head><title>\$title</title></head><body>\n" .
    "<header><nav><a href=\"/\">home</a><a href=\"/forums/\">forums</a></nav></header>\n" .
    "<main><h1>\$title</h1><div class=\"content\">\$content</div>\n<ul>\n$rows</ul></main>\n" .
    "<footer>(footer)</footer></body></html>\n";
file_put_contents($out . '/template.html', $tpl);
echo "appsim generated: $files class files, " . strlen($tpl) . " byte template\n";
