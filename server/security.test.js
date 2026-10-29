'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { after, before, beforeEach, describe, test } = require('node:test');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bsos-security-'));
const signingKey = crypto.generateKeyPairSync('ed25519');

process.env.BATTERY_SOS_DATA_DIR = tmp;
process.env.LICENSE_SECRET = 'test-license-secret-value';
process.env.STRIPE_SECRET_KEY = 'sk_test_security_fixture';
process.env.STRIPE_PRICE_ID = 'price_security_fixture';
process.env.STRIPE_WEBHOOK_SECRET = 'whsec_security_fixture';
process.env.PUBLIC_BASE_URL = 'https://pay.batterysos.app';
process.env.BILLING_ADMIN_TOKEN = 'test-admin-token-value';
process.env.BILLING_EMAIL_PROVIDER = 'console';
delete process.env.BILLING_EMAIL_HTTP_URL;
delete process.env.BILLING_EMAIL_HTTP_TOKEN;
process.env.NODE_ENV = 'test';
process.env.ENTITLEMENT_SIGNING_PRIVATE_KEY = signingKey.privateKey.export({ type: 'pkcs8', format: 'pem' });

const billing = require('./billing');
const { clientAddress } = require('./client-address');
const { verifyEntitlement, EMBEDDED_APP_PUBLIC_KEY_BASE64, canonicalEntitlementPayload } = require('./entitlement');
const { resetRateLimitsForTests, setRateLimitForTests } = require('./rate-limit');
const { createRequestHandler } = require('./router');

const originalFetch = global.fetch;
const HASH_A = 'a'.repeat(64);
const HASH_B = 'b'.repeat(64);
const LICENSE_KEY = 'BSOS-AAAA-BBBB-CCCC-DDDD-EEEE';
const NOW_MS = 1_700_000_000_000;

let server;
let port;

function request({ method, url, headers = {}, body }) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port,
      path: url,
      method,
      headers,
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => {
        let json = null;
        try { json = raw ? JSON.parse(raw) : null; } catch { json = null; }
        resolve({ status: res.statusCode, body: raw, json, headers: res.headers });
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

function signedWebhook(event, timestampSeconds = Math.floor(NOW_MS / 1000)) {
  const body = JSON.stringify(event);
  const digest = crypto.createHmac('sha256', process.env.STRIPE_WEBHOOK_SECRET)
    .update(`${timestampSeconds}.${body}`)
    .digest('hex');
  return { body, header: `t=${timestampSeconds},v1=${digest}` };
}

function paidEvent(sessionId, extra = {}) {
  return {
    type: 'checkout.session.completed',
    data: {
      object: {
        id: sessionId,
        object: 'checkout.session',
        payment_status: 'paid',
        customer_details: { email: 'buyer@example.com' },
        metadata: { machineName: 'Test Mac' },
        ...extra,
      },
    },
  };
}

function runProductionServer(overrides = {}, remove = []) {
  const env = {
    ...process.env,
    NODE_ENV: 'production',
    HOST: '127.0.0.1',
    PORT: '0',
    ...overrides,
  };
  for (const key of remove) delete env[key];
  return spawnSync(process.execPath, ['server/server.js'], {
    cwd: path.resolve(__dirname, '..'),
    env,
    encoding: 'utf8',
    timeout: 4000,
  });
}

describe('billing security fixes', { concurrency: 1 }, () => {
  before(async () => {
    server = http.createServer(createRequestHandler());
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
  });

  after(async () => {
    if (server) await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  beforeEach(() => {
    global.fetch = originalFetch;
    billing.resetBillingStateForTests();
    resetRateLimitsForTests();
    process.env.BILLING_EMAIL_PROVIDER = 'console';
    delete process.env.BILLING_EMAIL_HTTP_URL;
    delete process.env.BILLING_EMAIL_HTTP_TOKEN;
  });

  test('recovery emails the key and returns the same body either way', async () => {
    billing.seedLicenseForTests({
      key: LICENSE_KEY,
      email: 'Buyer@Example.com',
      sessionId: 'cs_known',
    });
    const logs = [];
    const originalInfo = console.info;
    console.info = (...args) => logs.push(args.join(' '));
    let known;
    try {
      known = await billing.recoverLicenseByEmail('buyer@example.com');
    } finally {
      console.info = originalInfo;
    }
    const outbox = billing.getDevEmailOutbox();
    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].to, 'buyer@example.com');
    assert.match(outbox[0].text, new RegExp(LICENSE_KEY));
    assert.match(outbox[0].html, /BSOS-AAAA-BBBB-CCCC-DDDD-EEEE/);
    assert.equal(logs.some((line) => line.includes(LICENSE_KEY)), false);

    const unknown = await billing.recoverLicenseByEmail('nobody@example.com');
    assert.deepEqual(known, {
      accepted: true,
      message: 'If a license exists for that email, we sent it to the address on file.',
    });
    assert.deepEqual(known, unknown);
    assert.equal(JSON.stringify(known).includes(LICENSE_KEY), false);
    assert.equal(billing.getDevEmailOutbox().length, 1);

    const knownHttp = await request({
      method: 'POST',
      url: '/api/billing/recover',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.10' },
      body: JSON.stringify({ email: 'buyer@example.com' }),
    });
    const unknownHttp = await request({
      method: 'POST',
      url: '/api/billing/recover',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.11' },
      body: JSON.stringify({ email: 'nobody@example.com' }),
    });
    assert.equal(knownHttp.status, 200);
    assert.equal(unknownHttp.status, 200);
    assert.equal(knownHttp.body, unknownHttp.body);
    assert.equal(knownHttp.body.includes(LICENSE_KEY), false);
    assert.equal(knownHttp.body.includes('found'), false);

    const invalid = await request({
      method: 'POST',
      url: '/api/billing/recover',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.12' },
      body: JSON.stringify({ email: 'not-an-email' }),
    });
    const empty = await request({
      method: 'POST',
      url: '/api/billing/recover',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.13' },
      body: JSON.stringify({ email: '' }),
    });
    assert.equal(invalid.status, 400);
    assert.equal(empty.status, 400);
    assert.equal(invalid.body, empty.body);
    assert.equal(invalid.body.includes(LICENSE_KEY), false);
  });

  test('a failed email delivery still returns the generic body and no key', async () => {
    billing.seedLicenseForTests({ key: LICENSE_KEY, email: 'buyer@example.com' });
    process.env.BILLING_EMAIL_PROVIDER = 'http';
    process.env.BILLING_EMAIL_HTTP_URL = 'https://email.example.test/send';
    global.fetch = async () => ({ ok: false, json: async () => ({}) });
    const result = await billing.recoverLicenseByEmail('buyer@example.com');
    assert.deepEqual(result, {
      accepted: true,
      message: 'If a license exists for that email, we sent it to the address on file.',
    });
    assert.equal(JSON.stringify(result).includes(LICENSE_KEY), false);
  });

  test('http email provider receives the key and an escaped html body', async () => {
    const storedKey = billing.seedLicenseForTests({
      key: 'BSOS-<IMG SRC=X ONERROR=ALERT(1)>',
      email: 'buyer@example.com',
    }).key;
    let delivered = null;
    process.env.BILLING_EMAIL_PROVIDER = 'http';
    process.env.BILLING_EMAIL_HTTP_URL = 'https://email.example.test/send';
    process.env.BILLING_EMAIL_HTTP_TOKEN = 'email-token';
    global.fetch = async (url, options) => {
      delivered = { url, options, body: JSON.parse(options.body) };
      return { ok: true, json: async () => ({}) };
    };
    const result = await billing.recoverLicenseByEmail('buyer@example.com');
    assert.equal(result.accepted, true);
    assert.equal(JSON.stringify(result).includes(storedKey), false);
    assert.equal(delivered.url, 'https://email.example.test/send');
    assert.equal(delivered.options.headers.authorization, 'Bearer email-token');
    assert.match(delivered.body.text, new RegExp(storedKey.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    assert.equal(delivered.body.html.includes(storedKey), false);
    assert.match(delivered.body.html, /&lt;/);
  });

  test('verify-license binds a machine hash and returns a signed entitlement', () => {
    billing.seedLicenseForTests({
      key: LICENSE_KEY,
      email: 'buyer@example.com',
      boundMachineName: 'Kitchen Mac',
    });
    const wrongName = billing.verifyLicenseKey(LICENSE_KEY, 'Other Mac', HASH_A);
    assert.equal(wrongName.valid, false);
    assert.equal(wrongName.entitlement, undefined);

    const activated = billing.verifyLicenseKey(LICENSE_KEY, 'Kitchen Mac', HASH_A);
    assert.equal(activated.valid, true);
    assert.equal(activated.entitlement.licenseId, LICENSE_KEY);
    assert.equal(activated.entitlement.machineHash, HASH_A);
    assert.equal(verifyEntitlement(activated.entitlement, billing.publicKeyBase64FromEnv()), true);
    assert.equal(
      canonicalEntitlementPayload(LICENSE_KEY, HASH_A, activated.entitlement.issuedAt),
      `v1\n${LICENSE_KEY}\n${HASH_A}\n${activated.entitlement.issuedAt}`,
    );

    const tampered = { ...activated.entitlement, machineHash: HASH_B };
    assert.equal(verifyEntitlement(tampered, billing.publicKeyBase64FromEnv()), false);
    const tamperedDate = { ...activated.entitlement, issuedAt: '2000-01-01T00:00:00.000Z' };
    assert.equal(verifyEntitlement(tamperedDate, billing.publicKeyBase64FromEnv()), false);

    const otherMachine = billing.verifyLicenseKey(LICENSE_KEY, 'Kitchen Mac', HASH_B);
    assert.equal(otherMachine.valid, false);

    const renamed = billing.verifyLicenseKey(LICENSE_KEY, 'Renamed Mac', HASH_A);
    assert.equal(renamed.valid, true);
    assert.equal(verifyEntitlement(renamed.entitlement, billing.publicKeyBase64FromEnv()), true);

    const legacyAfterBind = billing.verifyLicenseKey(LICENSE_KEY, 'Kitchen Mac', '');
    assert.equal(legacyAfterBind.valid, false);
    assert.equal(legacyAfterBind.entitlement, undefined);
  });

  test('a name-only client can activate until a hash is bound', () => {
    billing.seedLicenseForTests({ key: LICENSE_KEY, email: 'buyer@example.com' });
    const legacy = billing.verifyLicenseKey(LICENSE_KEY, 'Kitchen Mac');
    assert.equal(legacy.valid, true);
    assert.equal(legacy.entitlement, undefined);
    const hashed = billing.verifyLicenseKey(LICENSE_KEY, 'Kitchen Mac', HASH_A);
    assert.equal(hashed.valid, true);
    assert.ok(hashed.entitlement);
  });

  test('webhook signatures expire after five minutes and still re-retrieve old snapshots', async () => {
    const fresh = signedWebhook(paidEvent('cs_fresh'), Math.floor(NOW_MS / 1000) - 300);
    await billing.handleStripeWebhook(fresh.body, fresh.header, NOW_MS);
    assert.equal(billing.getLicenseBySessionId('cs_fresh').email, 'buyer@example.com');

    const stale = signedWebhook(paidEvent('cs_stale'), Math.floor(NOW_MS / 1000) - 301);
    await assert.rejects(
      () => billing.handleStripeWebhook(stale.body, stale.header, NOW_MS),
      /five-minute tolerance/,
    );
    assert.equal(billing.getLicenseBySessionId('cs_stale'), null);

    const future = signedWebhook(paidEvent('cs_future'), Math.floor(NOW_MS / 1000) + 301);
    await assert.rejects(
      () => billing.handleStripeWebhook(future.body, future.header, NOW_MS),
      /five-minute tolerance/,
    );

    const forged = signedWebhook(paidEvent('cs_forged'));
    await assert.rejects(
      () => billing.handleStripeWebhook(forged.body, forged.header.replace(/v1=[a-f0-9]+/, 'v1=' + 'ab'.repeat(32)), NOW_MS),
      /signature verification failed/,
    );

    const calls = [];
    global.fetch = async (url, options) => {
      calls.push({ url, version: options.headers['Stripe-Version'] || '' });
      return {
        ok: true,
        json: async () => ({
          id: 'cs_old_api',
          object: 'checkout.session',
          payment_status: 'paid',
          customer_details: { email: 'old-api@example.com' },
          metadata: { machineName: 'Old API Mac' },
        }),
      };
    };
    const oldApi = signedWebhook({
      type: 'checkout.session.completed',
      data: { object: { id: 'cs_old_api', object: 'checkout.session' } },
    });
    await billing.handleStripeWebhook(oldApi.body, oldApi.header, NOW_MS);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].version, billing.CHECKOUT_FULFILLMENT_VERSION);
    assert.match(calls[0].url, /cs_old_api/);
    assert.equal(billing.getLicenseBySessionId('cs_old_api').email, 'old-api@example.com');

    calls.length = 0;
    const currentApi = signedWebhook(paidEvent('cs_current_api'));
    await billing.handleStripeWebhook(currentApi.body, currentApi.header, NOW_MS);
    assert.equal(calls.length, 0);
    assert.equal(billing.getLicenseBySessionId('cs_current_api').email, 'buyer@example.com');
  });

  test('the webhook route rejects an expired signature', async () => {
    const stale = signedWebhook(paidEvent('cs_http_stale'), Math.floor(Date.now() / 1000) - 600);
    const response = await request({
      method: 'POST',
      url: '/api/billing/webhook',
      headers: { 'stripe-signature': stale.header, 'content-type': 'application/json' },
      body: stale.body,
    });
    assert.equal(response.status, 400);
    assert.equal(billing.getLicenseBySessionId('cs_http_stale'), null);
  });

  test('production startup fails when LICENSE_SECRET is unset or the default', () => {
    const unset = runProductionServer({}, ['LICENSE_SECRET']);
    assert.equal(unset.status, 1);
    assert.match(unset.stderr, /LICENSE_SECRET must be set to a non-default value in production/);

    const fallback = runProductionServer({ LICENSE_SECRET: 'change-me-before-production' });
    assert.equal(fallback.status, 1);
    assert.match(fallback.stderr, /LICENSE_SECRET must be set to a non-default value in production/);

    const missingKey = runProductionServer(
      { LICENSE_SECRET: 'production-secret-value' },
      ['ENTITLEMENT_SIGNING_PRIVATE_KEY'],
    );
    assert.equal(missingKey.status, 1);
    assert.match(missingKey.stderr, /ENTITLEMENT_SIGNING_PRIVATE_KEY/);

    const consoleEmail = runProductionServer({
      LICENSE_SECRET: 'production-secret-value',
      BILLING_EMAIL_PROVIDER: 'console',
    });
    assert.equal(consoleEmail.status, 1);
    assert.match(consoleEmail.stderr, /BILLING_EMAIL_PROVIDER=http/);

    const pem = signingKey.privateKey.export({ type: 'pkcs8', format: 'pem' }).trim().replace(/\n/g, '\\n');
    assert.doesNotThrow(() => billing.assertProductionConfig({
      NODE_ENV: 'production',
      LICENSE_SECRET: 'production-secret-value',
      ENTITLEMENT_SIGNING_PRIVATE_KEY: pem,
      BILLING_EMAIL_PROVIDER: 'http',
      BILLING_EMAIL_HTTP_URL: 'https://email.example.test/send',
    }));
    assert.doesNotThrow(() => billing.assertProductionConfig({ NODE_ENV: 'development' }));
  });

  test('the success page escapes the license key and session id', () => {
    const sessionId = '"><script>alert(1)</script>';
    const seeded = billing.seedLicenseForTests({
      key: 'BSOS-<IMG SRC=X ONERROR=ALERT(1)>',
      email: 'buyer@example.com',
      sessionId,
    });
    const html = billing.renderSuccessPage(sessionId);
    assert.equal(html.includes(seeded.key), false);
    assert.equal(html.includes(sessionId), false);
    assert.match(html, /&lt;IMGSRC=XONERROR=ALERT\(1\)&gt;/);
    assert.match(html, /data-session-id="&quot;&gt;&lt;script&gt;alert\(1\)&lt;\/script&gt;"/);
    assert.equal(html.includes('innerHTML'), false);
    assert.match(html, /pre\.textContent = licenseKey/);
  });

  test('rate limits are per IP and ignore a spoofed forwarded header', async () => {
    billing.seedLicenseForTests({ key: LICENSE_KEY, email: 'buyer@example.com' });
    setRateLimitForTests('/api/billing/verify-license', { limit: 2, windowMs: 60_000 });
    const body = JSON.stringify({ licenseKey: LICENSE_KEY, machineName: 'Kitchen Mac', machineHash: HASH_A });
    const hit = (ip) => request({
      method: 'POST',
      url: '/api/billing/verify-license',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': `198.51.100.9, ${ip}` },
      body,
    });
    assert.equal((await hit('203.0.113.21')).status, 200);
    assert.equal((await hit('203.0.113.21')).status, 200);
    const limited = await hit('203.0.113.21');
    assert.equal(limited.status, 429);
    assert.equal(limited.body.includes(LICENSE_KEY), false);
    assert.ok(Number(limited.headers['retry-after']) >= 1);
    assert.equal((await hit('203.0.113.22')).status, 200);

    assert.equal(clientAddress({
      socket: { remoteAddress: '203.0.113.8' },
      headers: { 'x-forwarded-for': '198.51.100.9', 'cf-connecting-ip': '203.0.113.50' },
    }), '203.0.113.8');
    assert.equal(clientAddress({
      socket: { remoteAddress: '10.0.0.5' },
      headers: { 'cf-connecting-ip': '203.0.113.20', 'x-forwarded-for': '198.51.100.1' },
    }), '203.0.113.20');
    assert.equal(clientAddress({
      socket: { remoteAddress: '::ffff:10.1.1.1' },
      headers: { 'x-forwarded-for': '198.51.100.1, 203.0.113.30, 10.9.9.9' },
    }), '203.0.113.30');
    assert.equal(clientAddress({
      socket: { remoteAddress: '10.0.0.5' },
      headers: { 'x-forwarded-for': '10.1.1.1, 10.2.2.2' },
    }), '10.0.0.5');

    setRateLimitForTests('/api/billing/recover', { limit: 1, windowMs: 60_000 });
    const recover = (forwarded) => request({
      method: 'POST',
      url: '/api/billing/recover',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': forwarded },
      body: JSON.stringify({ email: 'buyer@example.com' }),
    });
    assert.equal((await recover('1.2.3.4, 203.0.113.40')).status, 200);
    assert.equal((await recover('9.9.9.9, 203.0.113.40')).status, 429);
    assert.equal((await recover('203.0.113.41')).status, 200);

    setRateLimitForTests('/api/billing/create-checkout-session', { limit: 1, windowMs: 60_000 });
    let stripeCalls = 0;
    global.fetch = async () => {
      stripeCalls += 1;
      return { ok: true, json: async () => ({ id: 'cs_rate', url: 'https://checkout.stripe.test/c' }) };
    };
    const checkout = () => request({
      method: 'POST',
      url: '/api/billing/create-checkout-session',
      headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.60' },
      body: JSON.stringify({ machineName: 'Kitchen Mac' }),
    });
    assert.equal((await checkout()).status, 200);
    assert.equal((await checkout()).status, 429);
    assert.equal(stripeCalls, 1);
  });

  test('the admin token is accepted only from the Authorization header', async () => {
    billing.seedLicenseForTests({ key: LICENSE_KEY, email: 'buyer@example.com' });
    const query = await request({
      method: 'GET',
      url: `/api/billing/admin/licenses?token=${encodeURIComponent(process.env.BILLING_ADMIN_TOKEN)}`,
    });
    assert.equal(query.status, 401);
    assert.equal(query.body.includes(LICENSE_KEY), false);

    const wrong = await request({
      method: 'GET',
      url: '/api/billing/admin/licenses',
      headers: { authorization: 'Bearer wrong-token' },
    });
    assert.equal(wrong.status, 401);

    const shorter = await request({
      method: 'GET',
      url: '/api/billing/admin/licenses',
      headers: { authorization: 'Bearer short' },
    });
    assert.equal(shorter.status, 401);
    assert.equal(billing.isValidAdminToken('short'), false);
    assert.equal(billing.isValidAdminToken(`${process.env.BILLING_ADMIN_TOKEN} `), false);
    assert.equal(billing.isValidAdminToken(process.env.BILLING_ADMIN_TOKEN), true);

    const allowed = await request({
      method: 'GET',
      url: '/api/billing/admin/licenses?token=ignored',
      headers: { authorization: `Bearer ${process.env.BILLING_ADMIN_TOKEN}` },
    });
    assert.equal(allowed.status, 200);
    assert.equal(allowed.json.totals.licenses, 1);
    assert.equal(allowed.json.recent[0].key, LICENSE_KEY);
  });

  test('the Mac client verifies a signed entitlement instead of any stored string', () => {
    const swift = fs.readFileSync(path.join(__dirname, '..', 'mac', 'BatteryEmergencyOverlay.swift'), 'utf8');
    const unlockStart = swift.indexOf('var isProUnlocked: Bool {');
    const unlockEnd = swift.indexOf('var needsOnlineMigration', unlockStart);
    const unlock = swift.slice(unlockStart, unlockEnd);
    assert.equal(unlock.includes('!= nil'), false);
    assert.match(unlock, /hasValidEntitlement\(\)/);
    assert.match(unlock, /legacyMigrationPending && hasWellFormedStoredKey\(\)/);
    assert.match(swift, /SecItemCopyMatching/);
    assert.match(swift, /SecItemAdd/);
    assert.match(swift, /Curve25519\.Signing\.PublicKey/);
    assert.match(swift, /IOPlatformUUID/);
    assert.match(swift, /migrateLegacyLicenseIfNeeded/);
    assert.match(swift, /v1\\n\\\(licenseId\)\\n\\\(machineHash\)\\n\\\(issuedAt\)/);
    assert.match(swift, new RegExp(EMBEDDED_APP_PUBLIC_KEY_BASE64.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    assert.match(swift, /publicKeyBase64 = "dpfow4ImtvwvUzpkHMgowHQOulXtqLQ\+rT\+syTCAHnY="/);
  });

  test('committed app binaries are not in the tree', () => {
    const tracked = spawnSync('git', ['ls-files'], {
      cwd: path.resolve(__dirname, '..'),
      encoding: 'utf8',
    }).stdout.split('\n');
    assert.equal(tracked.includes('mac/dist/battery-sos-macos.dmg'), false);
    assert.equal(tracked.includes('mac/dist/battery-sos-macos.dmg.sha256'), false);
    assert.equal(tracked.includes('mac/battery-sos'), false);
    const gitignore = fs.readFileSync(path.join(__dirname, '..', '.gitignore'), 'utf8');
    assert.match(gitignore, /^mac\/dist\/$/m);
    assert.match(gitignore, /^mac\/battery-sos$/m);
  });
});
