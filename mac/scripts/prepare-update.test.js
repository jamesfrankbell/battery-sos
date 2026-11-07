const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { verifyArchive, appcast } = require('./prepare-update');

test('Sparkle signature must match both archive bytes and embedded public key', () => {
  const pair = crypto.generateKeyPairSync('ed25519');
  const publicKey = pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  const bytes = Buffer.from('final stapled archive fixture');
  const signature = crypto.sign(null, bytes, pair.privateKey).toString('base64');
  assert.equal(verifyArchive(bytes, signature, publicKey), true);
  assert.equal(verifyArchive(Buffer.concat([bytes, Buffer.from('changed')]), signature, publicKey), false);
  const other = crypto.generateKeyPairSync('ed25519');
  assert.equal(verifyArchive(bytes, signature, other.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64')), false);
  assert.equal(verifyArchive(bytes, 'invalid', publicKey), false);
});

test('appcast uses the inspected build, byte length, minimum OS and verified signature', () => {
  const feed = appcast({ version: '1.0.1', build: '202610020220', minimumOS: '13.0', length: 1428164, signature: 'fixture<&"' });
  assert.match(feed, /<sparkle:version>202610020220<\/sparkle:version>/);
  assert.match(feed, /length="1428164"/);
  assert.match(feed, /minimumSystemVersion>13.0</);
  assert.match(feed, /edSignature="fixture&lt;&amp;&quot;"/);
  assert.doesNotMatch(feed, /202603061320|1362061/);
});
