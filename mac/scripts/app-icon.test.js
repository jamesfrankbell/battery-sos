const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REQUIRED = {
  icp4: 16,
  ic11: 32,
  icp5: 32,
  ic12: 64,
  icp6: 64,
  ic07: 128,
  ic13: 256,
  ic08: 256,
  ic14: 512,
  ic09: 512,
  ic10: 1024,
};

test('AppIcon.icns contains a PNG for every required size', () => {
  const file = path.join(__dirname, '..', 'AppIcon.icns');
  const buf = fs.readFileSync(file);
  assert.equal(buf.toString('ascii', 0, 4), 'icns');
  assert.equal(buf.readUInt32BE(4), buf.length);
  const found = new Map();
  let offset = 8;
  while (offset < buf.length) {
    assert.ok(offset + 8 <= buf.length);
    const type = buf.toString('ascii', offset, offset + 4);
    const length = buf.readUInt32BE(offset + 4);
    assert.ok(length >= 8, type);
    assert.ok(offset + length <= buf.length, type);
    const data = buf.subarray(offset + 8, offset + length);
    assert.equal(data[0], 0x89, type);
    assert.equal(data.toString('ascii', 1, 4), 'PNG', type);
    assert.equal(data.toString('ascii', 12, 16), 'IHDR', type);
    const width = data.readUInt32BE(16);
    const height = data.readUInt32BE(20);
    assert.equal(width, height, type);
    assert.equal(data[24], 8, type);
    assert.equal(data[25], 6, type);
    found.set(type, width);
    offset += length;
  }
  assert.equal(offset, buf.length);
  for (const [type, size] of Object.entries(REQUIRED)) {
    assert.equal(found.get(type), size, type);
  }
});

test('build script installs AppIcon and compiles the welcome window', () => {
  const script = fs.readFileSync(path.join(__dirname, 'build-app.sh'), 'utf8');
  assert.match(script, /WelcomeWindow\.swift/);
  assert.match(script, /AppIcon\.icns/);
  assert.match(script, /<key>CFBundleIconFile<\/key>\s*<string>AppIcon<\/string>/);
});
