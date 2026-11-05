'use strict';

/*
 * Full-stack Node.js probe for the stress site.
 *
 * Every request performs one MariaDB lookup, one Valkey counter update and one
 * Elasticsearch search, so the Node tier exercises the same services as the
 * PHP stress page.  It is intentionally dependency-light and runs under the
 * cluster module to use all available CPUs.
 */

const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');
const mysql = require('mysql2/promise');
const Redis = require('ioredis');

const PORT = Number(process.env.PORT || 3000);
const WORKERS = Math.max(1, Number(process.env.WORKERS || os.cpus().length));
const DB = {
  host: process.env.STRESS_DB_HOST || 'localhost',
  user: process.env.STRESS_DB_USER || 'demo',
  password: process.env.STRESS_DB_PASS || 'temp',
  database: process.env.STRESS_DB_NAME || 'stress_test',
  connectionLimit: Number(process.env.DB_POOL || 8),
};
const REDIS = {
  host: process.env.STRESS_VALKEY_HOST || '127.0.0.1',
  port: Number(process.env.STRESS_VALKEY_PORT || 6379),
};
const ES_URL = (process.env.STRESS_ELASTIC_URL || 'http://127.0.0.1:9200').replace(/\/$/, '');

let pool;
let redis;

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function handle(req, res) {
  const t0 = process.hrtime.bigint();
  const timings = {};
  const errors = [];
  let row = null;
  let hits = null;
  let counter = null;

  const tDb = process.hrtime.bigint();
  try {
    const [rows] = await pool.query(
      'SELECT id, title, LEFT(body, 120) AS excerpt FROM bench_items WHERE id = ?',
      [1 + Math.floor(Math.random() * 50000)]
    );
    row = rows[0] || null;
  } catch (err) {
    errors.push(`MariaDB: ${err.message}`);
  }
  timings.mariadb_ms = Number(process.hrtime.bigint() - tDb) / 1e6;

  const tCache = process.hrtime.bigint();
  try {
    counter = await redis.incr('stress:node:hits');
    await redis.expire('stress:node:hits', 3600);
    await redis.set('stress:node:last', String(Date.now()), 'EX', 60);
  } catch (err) {
    errors.push(`Valkey: ${err.message}`);
  }
  timings.valkey_ms = Number(process.hrtime.bigint() - tCache) / 1e6;

  const tSearch = process.hrtime.bigint();
  try {
    const response = await fetch(`${ES_URL}/stress_pages/_search`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        size: 3,
        query: { match: { body: 'quick brown fox' } },
        sort: [{ created_at: 'desc' }],
      }),
      signal: AbortSignal.timeout(1500),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    hits = data.hits?.total?.value ?? null;
  } catch (err) {
    errors.push(`Elasticsearch: ${err.message}`);
  }
  timings.elastic_ms = Number(process.hrtime.bigint() - tSearch) / 1e6;
  timings.total_ms = Number(process.hrtime.bigint() - t0) / 1e6;

  json(res, errors.length ? 503 : 200, {
    ok: errors.length === 0,
    service: 'stress-node-all',
    pid: process.pid,
    worker: cluster.worker?.id || 0,
    mariadb: row,
    valkey: counter,
    elasticsearch: hits,
    timings_ms: Object.fromEntries(
      Object.entries(timings).map(([key, value]) => [key, Math.round(value * 100) / 100])
    ),
    errors,
  });
}

function start() {
  pool = mysql.createPool(DB);
  redis = new Redis({
    ...REDIS,
    maxRetriesPerRequest: 2,
    enableReadyCheck: true,
    lazyConnect: false,
  });

  const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      json(res, 200, { ok: true, pid: process.pid });
      return;
    }
    handle(req, res).catch((err) => json(res, 500, { ok: false, error: err.message }));
  });
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.requestTimeout = 30_000;
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`stress-node-all worker ${process.pid} listening on 127.0.0.1:${PORT}`);
  });
}

if (cluster.isPrimary && WORKERS > 1) {
  console.log(`stress-node-all primary ${process.pid}: starting ${WORKERS} workers`);
  for (let i = 0; i < WORKERS; i += 1) cluster.fork();
  cluster.on('exit', (worker, code, signal) => {
    console.error(`worker ${worker.process.pid} exited (${code || signal}); restarting`);
    cluster.fork();
  });
} else {
  start();
}
