'use strict';

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');

const PORT = Number(process.env.PORT || 3100);
const WORKERS = Math.max(1, Number(process.env.WORKERS || Math.min(4, os.cpus().length)));

function startWorker() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const common = {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Node-Worker': String(cluster.worker?.id || 0),
    };

    if (url.pathname === '/health') {
      res.writeHead(200, common);
      res.end('{"ok":true}');
      return;
    }

    if (url.pathname === '/cpu') {
      const n = Math.max(1, Math.min(5_000_000, Number(url.searchParams.get('n') || 100_000)));
      let acc = 0;
      for (let i = 0; i < n; i += 1) acc += Math.sqrt(i);
      res.writeHead(200, common);
      res.end(JSON.stringify({ ok: true, pid: process.pid, n, result: acc }));
      return;
    }

    res.writeHead(200, common);
    res.end(JSON.stringify({
      ok: true,
      service: 'stress-node',
      pid: process.pid,
      worker: cluster.worker?.id || 0,
      uptime: Math.round(process.uptime() * 1000) / 1000,
      now: new Date().toISOString(),
    }));
  });

  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.requestTimeout = 30_000;
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`stress-node worker ${process.pid} listening on 127.0.0.1:${PORT}`);
  });
}

if (cluster.isPrimary && WORKERS > 1) {
  console.log(`stress-node primary ${process.pid}: starting ${WORKERS} workers`);
  for (let i = 0; i < WORKERS; i += 1) cluster.fork();
  cluster.on('exit', (worker, code, signal) => {
    console.error(`stress-node worker ${worker.process.pid} exited (${code || signal}); restarting`);
    cluster.fork();
  });
} else {
  startWorker();
}
