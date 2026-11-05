# Node.js all-services test app

`all.js` performs one MariaDB lookup, one Valkey counter update and one
Elasticsearch search per request. It is used to verify that the Node tier, not
only PHP, exercises the full stack.

```bash
sudo install -d -o www-data -g www-data /opt/stress-node-all
sudo cp all.js package.json /opt/stress-node-all/
cd /opt/stress-node-all
sudo -u www-data npm install --omit=dev --no-audit --no-fund
```

Run it under systemd on `127.0.0.1:3000` with `WORKERS=8` and
`STRESS_DB_PASS` set, then create a Node vhost:

```bash
sudo bash setup.sh --domain node.example.com app=node
```

Environment variables: `PORT`, `WORKERS`, `STRESS_DB_HOST`, `STRESS_DB_USER`,
`STRESS_DB_PASS`, `STRESS_DB_NAME`, `STRESS_VALKEY_HOST`,
`STRESS_VALKEY_PORT`, `STRESS_ELASTIC_URL`.
