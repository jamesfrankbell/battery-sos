'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { describe, test } = require('node:test');

const {
  COMPILED_BILLING_URL,
  LAST_PUBLIC_DMG_BYTES,
  LAST_PUBLIC_DMG_SHA256,
  LAST_PUBLIC_RELEASE_COMMIT,
  publicDownloadResponse,
} = require('./public-download');
const { createRequestHandler } = require('./router');

function request(port, urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port,
      path: urlPath,
      method: 'GET',
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => {
        let json = null;
        try { json = raw ? JSON.parse(raw) : null; } catch { json = null; }
        resolve({ status: res.statusCode, headers: res.headers, body: raw, json });
      });
    });
    req.on('error', reject);
    req.end();
  });
}

describe('archived Mac download', () => {
  test('identifies the archived DMG and does not redirect to it', () => {
    const dmg = publicDownloadResponse('/downloads/battery-sos-macos.dmg');
    const checksum = publicDownloadResponse('/downloads/battery-sos-macos.dmg.sha256');
    assert.equal(dmg.status, 404);
    assert.equal(dmg.body.sha256, 'c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60');
    assert.equal(dmg.body.sha256, LAST_PUBLIC_DMG_SHA256);
    assert.equal(dmg.body.bytes, 1429342);
    assert.equal(dmg.body.bytes, LAST_PUBLIC_DMG_BYTES);
    assert.equal(dmg.body.containedBuild, '202603110225');
    assert.equal(dmg.body.compiledBillingURL, 'http://127.0.0.1:8787');
    assert.equal(dmg.body.compiledBillingURL, COMPILED_BILLING_URL);
    assert.equal(JSON.stringify(dmg).includes('raw.githubusercontent.com'), false);
    assert.equal(JSON.stringify(dmg).includes(LAST_PUBLIC_RELEASE_COMMIT), false);
    assert.deepEqual(checksum, dmg);
    assert.equal(publicDownloadResponse('/downloads/other.bin'), null);
  });

  test('the public routes withhold the archived installer', async () => {
    const server = http.createServer(createRequestHandler());
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
      const port = server.address().port;
      const dmg = await request(port, '/downloads/battery-sos-macos.dmg');
      const checksum = await request(port, '/downloads/battery-sos-macos.dmg.sha256');
      assert.equal(dmg.status, 404);
      assert.equal(dmg.headers.location, undefined);
      assert.equal(dmg.headers['content-type'].includes('application/json'), true);
      assert.equal(dmg.json.error, 'Download withheld.');
      assert.equal(dmg.json.compiledBillingURL, 'http://127.0.0.1:8787');
      assert.equal(dmg.body.includes('pay.batterysos.app'), false);
      assert.deepEqual(checksum.json, dmg.json);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  test('the Sparkle feed has no enclosure and no signature', () => {
    const feed = fs.readFileSync(path.join(__dirname, '..', 'website', 'appcast.xml'), 'utf8');
    assert.match(feed, /<rss [^>]*version="2.0">/);
    assert.match(feed, /<channel>/);
    assert.match(feed, /<title>Battery SOS<\/title>/);
    assert.equal(feed.includes('<item>'), false);
    assert.equal(feed.includes('<enclosure'), false);
    assert.equal(feed.includes('sparkle:edSignature'), false);
    assert.equal(feed.includes('blmOkxzEdzWDugJGEfDUBTLLxEtTvginKh5sonZeDZnFQuZoU9EgonPDidBdZkn4okWR6tSKmwoeqHIB1SOfCg=='), false);
    assert.equal(feed.includes('/downloads/battery-sos-macos.dmg'), false);
    assert.match(feed, /http:\/\/127\.0\.0\.1:8787/);
  });
});
