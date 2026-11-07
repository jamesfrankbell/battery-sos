'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { describe, test } = require('node:test');

const {
  LAST_PUBLIC_DMG_BYTES,
  LAST_PUBLIC_DMG_SHA256,
  LAST_PUBLIC_DMG_SHA256_URL,
  LAST_PUBLIC_DMG_URL,
  LAST_PUBLIC_RELEASE_COMMIT,
  publicDownloadRedirect,
} = require('./public-download');
const { createRequestHandler } = require('./router');

function request(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port,
      path,
      method: 'GET',
    }, (res) => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers }));
    });
    req.on('error', reject);
    req.end();
  });
}

describe('last public Mac download', () => {
  test('pins the last main DMG and its preserved checksum', () => {
    const dmg = publicDownloadRedirect('/downloads/battery-sos-macos.dmg');
    const checksum = publicDownloadRedirect('/downloads/battery-sos-macos.dmg.sha256');
    assert.equal(dmg.bytes, 1429342);
    assert.equal(dmg.bytes, LAST_PUBLIC_DMG_BYTES);
    assert.equal(dmg.sha256, 'c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60');
    assert.equal(dmg.sha256, LAST_PUBLIC_DMG_SHA256);
    assert.equal(dmg.location, LAST_PUBLIC_DMG_URL);
    assert.equal(checksum.location, LAST_PUBLIC_DMG_SHA256_URL);
    assert.match(dmg.location, new RegExp(`/${LAST_PUBLIC_RELEASE_COMMIT}/mac/dist/battery-sos-macos\\.dmg$`));
    assert.match(checksum.location, new RegExp(`/${LAST_PUBLIC_RELEASE_COMMIT}/mac/dist/battery-sos-macos\\.dmg\\.sha256$`));
    assert.equal(dmg.location.includes('3f1f49d'), false);
    assert.equal(publicDownloadRedirect('/downloads/other.bin'), null);
  });

  test('the appcast does not attach the old Sparkle signature to the restored DMG', () => {
    const feed = fs.readFileSync(path.join(__dirname, '..', 'website', 'appcast.xml'), 'utf8');
    assert.equal(feed.includes('sparkle:edSignature'), false);
    assert.equal(feed.includes('<enclosure'), false);
    assert.equal(feed.includes('blmOkxzEdzWDugJGEfDUBTLLxEtTvginKh5sonZeDZnFQuZoU9EgonPDidBdZkn4okWR6tSKmwoeqHIB1SOfCg=='), false);
    assert.equal(feed.includes('/downloads/battery-sos-macos.dmg'), false);
    assert.match(feed, /202603110225/);
    assert.match(feed, /202603061320/);
  });

  test('the public routes redirect and do not 404', async () => {
    const server = http.createServer(createRequestHandler());
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
      const port = server.address().port;
      const dmg = await request(port, '/downloads/battery-sos-macos.dmg');
      const checksum = await request(port, '/downloads/battery-sos-macos.dmg.sha256');
      assert.equal(dmg.status, 302);
      assert.equal(dmg.headers.location, LAST_PUBLIC_DMG_URL);
      assert.equal(dmg.headers['cache-control'], 'no-store');
      assert.equal(checksum.status, 302);
      assert.equal(checksum.headers.location, LAST_PUBLIC_DMG_SHA256_URL);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });
});
