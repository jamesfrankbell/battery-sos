const http = require('node:http');

const { assertProductionConfig } = require('./billing');
const { createRequestHandler } = require('./router');

try {
  assertProductionConfig();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || '0.0.0.0';

const server = http.createServer(createRequestHandler());

server.listen(port, host, () => {
  // Use HOST=0.0.0.0 for LAN/VPN access.
  console.log(`LocalFlow running at http://${host}:${port}`);
});
