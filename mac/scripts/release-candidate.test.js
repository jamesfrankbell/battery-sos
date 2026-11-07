'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..', '..');

function read(relative) {
  return fs.readFileSync(path.join(root, relative), 'utf8');
}

test('the candidate app keeps $1 checkout, Pro-labels Vitals, and emails recovery without showing a key', () => {
  const swift = read('mac/BatteryEmergencyOverlay.swift');
  assert.match(swift, /Unlock Pro \(\$1\)/);
  assert.equal(swift.includes('$2.99'), false);
  assert.match(swift, /vitalsModeItem\?\.title = menuTitle\(for: \.vitalsMonitor\)/);
  assert.match(swift, /\/api\/billing\/recover/);
  assert.match(swift, /Email My License Key/);
  assert.match(swift, /object\["key"\] != nil \|\| object\["licenses"\] != nil/);
  assert.match(swift, /If a license exists for that email, we sent it to the address on file\./);
  assert.match(swift, /gTZwp8xK\+B6IlAst6SlVbEWZTpGKneMuCjImIlipJuM=/);
});

test('release scripts require an explicit 1.0.1 build and do not publish the feed', () => {
  const build = read('mac/scripts/build-app.sh');
  const release = read('mac/scripts/release.sh');
  const sign = read('mac/scripts/sign-app.sh');
  assert.match(build, /VERSION="\$\{VERSION:-1\.0\.1\}"/);
  assert.match(build, /Set BUILD_NUMBER/);
  assert.match(build, /arm64-apple-macosx/);
  assert.match(build, /Ad-hoc signature only/);
  assert.match(release, /CANDIDATE ONLY/);
  assert.match(sign, /Downloader\.xpc/);
  assert.equal(sign.includes('--force --deep'), false);
  assert.match(sign, /codesign --verify --deep --strict/);
  assert.equal(release.includes('website/appcast.xml'), false);
  const yaml = read('render.yaml');
  assert.equal(yaml.includes('apps/battery-sos'), false);
  assert.match(yaml, /buildCommand: npm install/);
});

test('shell release scripts parse', () => {
  for (const script of ['build-app.sh', 'build-dmg.sh', 'sign-app.sh', 'notarize.sh', 'release.sh']) {
    const result = spawnSync('bash', ['-n', path.join(root, 'mac', 'scripts', script)], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
});
