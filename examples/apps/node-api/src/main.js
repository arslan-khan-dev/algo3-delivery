// Sample API for templates/dockerfiles/node-api.Dockerfile. No dependencies.
const http = require('node:http');
const fs = require('node:fs');
const schema = () => { try { return JSON.parse(fs.readFileSync('/data/schema.json', 'utf8')).schema; } catch { return 0; } };
const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', version: process.env.RELEASE_SHA, schema: schema() }));
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('demo api\n');
});
server.listen(Number(process.env.PORT || 3000));
// Graceful stop: finish in-flight requests, then exit.
process.on('SIGTERM', () => server.close(() => process.exit(0)));
