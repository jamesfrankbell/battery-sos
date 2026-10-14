const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { PassThrough } = require('node:stream');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'battery-sos-billing-tests-'));
const originalFetch = global.fetch;
const oldEnv = { ...process.env };
const webhookSecret = 'isolated-webhook-fixture';
process.env.STRIPE_SECRET_KEY = 'sk_test_isolated_fixture';
process.env.STRIPE_PRICE_ID = 'price_isolated_fixture';
process.env.STRIPE_WEBHOOK_SECRET = webhookSecret;
process.env.LICENSE_SECRET = 'isolated-license-fixture-only';
process.env.BILLING_ADMIN_TOKEN = 'isolated-admin-fixture';
process.env.PUBLIC_BASE_URL = 'https://billing.example.invalid';

function load(name, contents) {
  const dir = path.join(root, name); fs.mkdirSync(dir, { recursive: true });
  process.env.BATTERY_SOS_DATA_DIR = dir;
  if (contents !== undefined) fs.writeFileSync(path.join(dir, 'billing-data.json'), contents);
  delete require.cache[require.resolve('./billing')];
  return require('./billing');
}
function paid(id = 'cs_test_fixture') {
  return { id, payment_status: 'paid', metadata: { machineName: 'Fixture Mac' }, customer_details: { email: 'buyer@example.invalid' } };
}
function deliver(billing, session, type = 'checkout.session.completed', timestamp = Math.floor(Date.now()/1000), suffix = '') {
  const raw = JSON.stringify({ id: 'evt_fixture', type, data: { object: session } });
  const signature = crypto.createHmac('sha256', webhookSecret).update(`${timestamp}.${raw}`).digest('hex');
  return billing.handleStripeWebhook(raw, `t=${timestamp},v1=${signature}${suffix}`);
}
test.after(() => {
  global.fetch = originalFetch;
  for (const key of Object.keys(process.env)) if (!(key in oldEnv)) delete process.env[key];
  Object.assign(process.env, oldEnv); fs.rmSync(root, { recursive: true, force: true });
});

test('mock checkout, unpaid/delayed payment, activation, invalid key and restart persistence', async () => {
  let billing = load('journey');
  let session = { ...paid(), payment_status: 'unpaid' };
  global.fetch = async (url, options) => {
    assert.ok(url.startsWith('https://api.stripe.com/v1/checkout/sessions'));
    if (options.method === 'POST') return { ok: true, json: async () => ({ id: session.id, url: 'https://checkout.example.invalid/session' }) };
    return { ok: true, json: async () => session };
  };
  assert.match((await billing.createCheckoutSession('Fixture Mac')).url, /checkout.example.invalid/);
  assert.equal((await billing.finalizeCheckoutSession(session.id)).ready, false);
  assert.equal(billing.getLicenseBySessionId(session.id), null);
  deliver(billing, session);
  assert.equal(billing.getLicenseBySessionId(session.id), null);
  session = paid();
  deliver(billing, session, 'checkout.session.async_payment_succeeded');
  const result = await billing.finalizeCheckoutSession(session.id);
  assert.equal(result.ready, true);
  assert.equal(billing.verifyLicenseKey('invalid', 'Fixture Mac').valid, false);
  assert.equal(billing.verifyLicenseKey(result.key, '').valid, false);
  assert.equal(billing.verifyLicenseKey(result.key.toLowerCase(), 'Fixture Mac').valid, true);
  billing = load('journey');
  assert.equal(billing.verifyLicenseKey(result.key, 'Fixture Mac').valid, true);
  assert.equal(billing.verifyLicenseKey(result.key, 'Different Mac').valid, false);
  deliver(billing, session);
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 1);
  assert.equal(billing.getLicenseBySessionId(session.id).key, result.key);
  assert.match(billing.renderCancelPage(), /Checkout Cancelled/);
});

test('stale, future, malformed and forged signatures cannot issue licenses', () => {
  const billing = load('webhooks'), now = Math.floor(Date.now()/1000);
  for (const stamp of [now-301, now+301, 'NaN']) assert.throws(() => deliver(billing, paid(), undefined, stamp));
  assert.throws(() => deliver(billing, paid(), undefined, now, 'garbage'));
  assert.throws(() => billing.handleStripeWebhook('{}', `t=${now},v1=${'0'.repeat(64)}`));
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 0);
  deliver(billing, paid(), undefined, now);
  deliver(billing, paid(), undefined, now);
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 1);
});

test('corrupt, empty and inconsistent stores fail closed without modifying original bytes', () => {
  for (const [name, contents] of [['corrupt','{broken'], ['empty',''], ['shape','[]'], ['orphan','{"licenses":{},"sessions":{"cs_test_orphan":"missing"}}']]) {
    assert.throws(() => load(name, contents), /original file has been preserved/);
    assert.equal(fs.readFileSync(path.join(root,name,'billing-data.json'),'utf8'), contents);
  }
});

test('failed persistence neither binds the in-memory license nor damages prior bytes', () => {
  const billing = load('write-failure'); deliver(billing, paid());
  const file = path.join(root, 'write-failure/billing-data.json'), before = fs.readFileSync(file);
  const rename = fs.renameSync;
  fs.renameSync = () => { throw new Error('isolated disk failure'); };
  try { assert.throws(() => billing.verifyLicenseKey(billing.getLicenseBySessionId(paid().id).key,'Fixture Mac'), /storage could not be saved/); }
  finally { fs.renameSync = rename; }
  assert.deepEqual(fs.readFileSync(file), before);
  assert.equal(billing.getLicenseBySessionId(paid().id).boundMachineName, '');
  assert.deepEqual(fs.readdirSync(path.dirname(file)), ['billing-data.json']);
  assert.equal(billing.verifyLicenseKey(billing.getLicenseBySessionId(paid().id).key,'Fixture Mac').valid, true);
});

test('recovery HTTP route reveals nothing without existing administrator authorization', async () => {
  const billing = load('recovery'); deliver(billing, paid());
  // Never load LocalFlow's unrelated real data store.
  const storePath = path.join(__dirname, 'store.js');
  const oldStore = require.cache[storePath]; require.cache[storePath] = { loaded: true, exports: Object.fromEntries(['createDocument','createTask','deleteDocument','deleteTask','getState','updateDocument','updateTask'].map(name=>[name,()=>{throw new Error('Unrelated store must not be used');}])) };
  delete require.cache[require.resolve('./router')];
  const handler = require('./router').createRequestHandler();
  async function request(authorization) {
    const req = new PassThrough(); Object.assign(req, { method:'POST',url:'/api/billing/recover',headers:{authorization} });
    let code, body;
    const res = { writeHead(c) { code=c; }, end(b) { body=JSON.parse(b); } };
    const pending = handler(req,res); req.end(JSON.stringify({email:'buyer@example.invalid'})); await pending;
    return {code,body};
  }
  try {
    for (const auth of ['', 'Bearer invalid']) {
      const result = await request(auth); assert.equal(result.code,401); assert.deepEqual(result.body,{error:'Unauthorized'});
    }
    const result = await request('Bearer isolated-admin-fixture');
    assert.equal(result.code,200); assert.equal(result.body.licenses.length,1);
  } finally { if (oldStore) require.cache[storePath]=oldStore; else delete require.cache[storePath]; }
});

test('actual success-page script retries delayed payment and stops once key arrives', async () => {
  const billing = load('page');
  const html = billing.renderSuccessPage('cs_test_page');
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const elements = { card:{dataset:{sessionId:'cs_test_page'}}, 'key-slot':{innerHTML:''}, 'status-message':{textContent:''} };
  const timers=[]; let requests=0;
  const context={document:{getElementById:id=>elements[id]||null},setTimeout:fn=>timers.push(fn),fetch:async()=>({json:async()=> ++requests===1 ? {ready:false,message:'pending'} : {ready:true,key:'BSOS-FIXTURE'}})};
  vm.runInNewContext(script,context);
  await new Promise(resolve=>setImmediate(resolve)); assert.equal(timers.length,1);
  timers.shift()(); await new Promise(resolve=>setImmediate(resolve));
  assert.match(elements['key-slot'].innerHTML,/BSOS-FIXTURE/); assert.equal(timers.length,0);
  assert.doesNotMatch(billing.renderSuccessPage('\"><script>injected</script>'),/data-session-id=""><script>/);
});

test('checkout/network failures do not issue a license', async () => {
  const billing = load('upstream-failure');
  global.fetch = async () => ({ok:false,json:async()=>({error:{message:'isolated payment failure'}})});
  await assert.rejects(billing.createCheckoutSession('Fixture Mac'), /isolated payment failure/);
  await assert.rejects(billing.finalizeCheckoutSession('cs_test_failure'), /isolated payment failure/);
  assert.equal(billing.getBillingAdminSummary().totals.licenses,0);
});

test('success-page waiting is bounded when payment stays pending', async () => {
  const billing=load('pending-page');
  const script=billing.renderSuccessPage('cs_test_pending').match(/<script>([\s\S]*?)<\/script>/)[1];
  const timers=[]; let requests=0;
  const elements={card:{dataset:{sessionId:'cs_test_pending'}},'key-slot':{innerHTML:''},'status-message':{textContent:''}};
  vm.runInNewContext(script,{document:{getElementById:id=>elements[id]||null},setTimeout:fn=>timers.push(fn),fetch:async()=>{requests++;return {json:async()=>({ready:false,message:'pending'})};}});
  await new Promise(resolve=>setImmediate(resolve));
  while(timers.length) {timers.shift()();await new Promise(resolve=>setImmediate(resolve));}
  assert.equal(requests,30);assert.equal(elements['key-slot'].innerHTML,'');
});

function deviceId(label) {
  return crypto.createHash('sha256').update(label).digest('hex');
}
function recoveryCode(message) {
  const match = message.text.match(/recovery: ([A-Z2-9]{8})/);
  assert.ok(match, message.text);
  return match[1];
}
function recoveryToken(message) {
  const match = message.text.match(/token=(\S+)/);
  assert.ok(match, message.text);
  return decodeURIComponent(match[1]);
}

test('self-service recovery reveals a key only after a one-time code or signed link', async () => {
  const billing = load('verified-recovery');
  deliver(billing, paid());
  const key = billing.getLicenseBySessionId(paid().id).key;
  const buyer = 'buyer@example.invalid';
  const missing = 'nobody@example.invalid';
  const known = await billing.requestLicenseRecovery({ email: buyer, ip: '203.0.113.10' });
  const unknown = await billing.requestLicenseRecovery({ email: missing, ip: '203.0.113.11' });
  assert.deepEqual(known, unknown);
  assert.equal(known.accepted, true);
  assert.doesNotMatch(JSON.stringify(known), /BSOS-|found|not found|buyer@/i);
  const outbox = billing.getDevEmailOutbox();
  assert.equal(outbox.length, 1);
  assert.equal(outbox[0].to, buyer);
  assert.equal(outbox[0].provider, 'console');
  assert.doesNotMatch(outbox[0].text, /BSOS-/);
  const code = recoveryCode(outbox[0]);
  const token = recoveryToken(outbox[0]);
  assert.match(outbox[0].text, /https:\/\/billing\.example\.invalid\/billing\/recover\?token=/);
  const wrong = billing.confirmLicenseRecovery({ email: buyer, code: 'AAAAAAAA', ip: '203.0.113.12' });
  const wrongMissing = billing.confirmLicenseRecovery({ email: missing, code: 'AAAAAAAA', ip: '203.0.113.13' });
  assert.deepEqual(wrong, wrongMissing);
  assert.equal(wrong.revealed, false);
  assert.doesNotMatch(JSON.stringify(wrong), new RegExp(key));
  const tampered = `${token.slice(0, -4)}${token.endsWith('AAAA') ? 'BBBB' : 'AAAA'}`;
  assert.equal(billing.confirmLicenseRecovery({ token: tampered, ip: '203.0.113.14' }).revealed, false);
  const byCode = billing.confirmLicenseRecovery({ email: buyer.toUpperCase(), code: code.toLowerCase(), ip: '203.0.113.15' });
  assert.equal(byCode.revealed, true);
  assert.equal(byCode.licenses.length, 1);
  assert.equal(byCode.licenses[0].key, key);
  assert.equal(billing.confirmLicenseRecovery({ email: buyer, code, ip: '203.0.113.16' }).revealed, false);
  assert.equal(billing.confirmLicenseRecovery({ token, ip: '203.0.113.17' }).revealed, false);

  billing.clearDevEmailOutbox();
  await billing.requestLicenseRecovery({ email: `  ${buyer}  `, ip: '203.0.113.18' });
  const link = recoveryToken(billing.getDevEmailOutbox()[0]);
  const byLink = billing.confirmLicenseRecovery({ token: link, ip: '203.0.113.19' });
  assert.equal(byLink.licenses[0].key, key);
  assert.equal(billing.confirmLicenseRecovery({ token: link, ip: '203.0.113.19' }).revealed, false);
  const form = billing.renderRecoveryPage();
  const shown = billing.renderRecoveryPage({ revealed: true, message: 'ok', licenses: [{ key: 'BSOS-1<script>' }] });
  assert.match(form, /Purchase email/);
  assert.doesNotMatch(form, /BSOS-/);
  assert.match(shown, /BSOS-1&lt;script&gt;/);
  assert.doesNotMatch(shown, /<script>/);
  assert.equal(billing.recoverLicenseByEmail(buyer).licenses[0].key, key);
  assert.equal(billing.getDevEmailOutbox().length, 1);
});

test('recovery delivery is provider-selected, rate-limited, and identical for unknown emails', async () => {
  const billing = load('recovery-provider');
  deliver(billing, paid());
  process.env.BILLING_EMAIL_PROVIDER = 'http';
  process.env.BILLING_EMAIL_HTTP_URL = 'https://email.example.invalid/send';
  process.env.BILLING_EMAIL_HTTP_TOKEN = 'fixture-email-token';
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, options });
    return { ok: true, json: async () => ({ id: 'email-fixture' }) };
  };
  try {
    const sent = await billing.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '198.51.100.20' });
    const absent = await billing.requestLicenseRecovery({ email: 'nobody@example.invalid', ip: '198.51.100.21' });
    assert.deepEqual(sent, absent);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, 'https://email.example.invalid/send');
    assert.equal(calls[0].options.headers.authorization, 'Bearer fixture-email-token');
    const body = JSON.parse(calls[0].options.body);
    assert.equal(body.to, 'buyer@example.invalid');
    assert.match(body.text, /token=/);
    assert.doesNotMatch(body.text, /BSOS-/);
    assert.equal(billing.getDevEmailOutbox().length, 0);
    global.fetch = async () => ({ ok: false, json: async () => ({}) });
    const failedKnown = await billing.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '198.51.100.22' });
    const failedMissing = await billing.requestLicenseRecovery({ email: 'nobody-else@example.invalid', ip: '198.51.100.23' });
    assert.deepEqual(failedKnown, failedMissing);
    process.env.BILLING_EMAIL_PROVIDER = 'not-a-provider';
    const unsupportedKnown = await billing.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '198.51.100.24' });
    const unsupportedMissing = await billing.requestLicenseRecovery({ email: 'nobody-else@example.invalid', ip: '198.51.100.25' });
    assert.deepEqual(unsupportedKnown, unsupportedMissing);
  } finally {
    process.env.BILLING_EMAIL_PROVIDER = 'console';
    delete process.env.BILLING_EMAIL_HTTP_URL;
    delete process.env.BILLING_EMAIL_HTTP_TOKEN;
  }

  const limited = load('recovery-limit');
  deliver(limited, paid());
  const accepted = 'If a license is associated with that email, a recovery message is on its way. It expires in 15 minutes and can be used once.';
  for (let index = 0; index < 5; index += 1) {
    const result = await limited.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: `203.0.113.${index + 1}` });
    assert.equal(result.message, accepted);
  }
  await assert.rejects(
    () => limited.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '203.0.113.60' }),
    (error) => error.statusCode === 429 && error.message === 'Too many recovery attempts. Please wait and try again.',
  );
  const stillUnknown = await limited.requestLicenseRecovery({ email: 'nobody@example.invalid', ip: '203.0.113.61' });
  assert.equal(stillUnknown.message, accepted);
  assert.equal(limited.getDevEmailOutbox().filter((message) => message.to === 'nobody@example.invalid').length, 0);

  const byIp = load('recovery-ip-limit');
  deliver(byIp, paid());
  for (let index = 0; index < 20; index += 1) {
    await byIp.requestLicenseRecovery({ email: `missing${index}@example.invalid`, ip: '203.0.113.90' });
  }
  assert.equal(byIp.getDevEmailOutbox().length, 0);
  await assert.rejects(
    () => byIp.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '203.0.113.90' }),
    (error) => error.statusCode === 429 && error.message === 'Too many recovery attempts. Please wait and try again.',
  );
  await assert.rejects(
    () => byIp.requestLicenseRecovery({ email: 'other@example.invalid', ip: '203.0.113.90' }),
    (error) => error.statusCode === 429 && error.message === 'Too many recovery attempts. Please wait and try again.',
  );
  assert.equal(byIp.getDevEmailOutbox().length, 0);

  const clock = load('recovery-expiry');
  deliver(clock, paid());
  const start = new Date('2026-10-14T12:00:00.000Z');
  clock.setNowForTests(() => start);
  try {
    await clock.requestLicenseRecovery({ email: 'buyer@example.invalid', ip: '203.0.113.70' });
    const token = recoveryToken(clock.getDevEmailOutbox()[0]);
    clock.setNowForTests(() => new Date(start.getTime() + 16 * 60 * 1000));
    const expired = clock.confirmLicenseRecovery({ token, ip: '203.0.113.71' });
    assert.equal(expired.revealed, false);
    assert.equal(expired.message, 'That recovery link or code is invalid or has expired.');
    assert.equal(clock.getLicenseBySessionId(paid().id).key.startsWith('BSOS-'), true);
    assert.doesNotMatch(JSON.stringify(expired), /BSOS-/);
  } finally {
    clock.setNowForTests();
  }
});

test('recovery HTTP routes keep admin lookup and do not reveal keys early', async () => {
  const billing = load('recovery-http');
  deliver(billing, paid());
  const key = billing.getLicenseBySessionId(paid().id).key;
  const storePath = path.join(__dirname, 'store.js');
  const oldStore = require.cache[storePath];
  require.cache[storePath] = { loaded: true, exports: Object.fromEntries(['createDocument', 'createTask', 'deleteDocument', 'deleteTask', 'getState', 'updateDocument', 'updateTask'].map((name) => [name, () => { throw new Error('Unrelated store must not be used'); }])) };
  delete require.cache[require.resolve('./router')];
  const handler = require('./router').createRequestHandler();
  async function request({ method, url, headers = {}, body }) {
    const req = new PassThrough();
    Object.assign(req, { method, url, headers, socket: { remoteAddress: '203.0.113.80' } });
    let code;
    let raw;
    const res = { writeHead(status) { code = status; }, end(payload) { raw = payload; } };
    const pending = handler(req, res);
    req.end(body);
    await pending;
    return { code, raw };
  }
  try {
    const anonymous = await request({ method: 'POST', url: '/api/billing/recover', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'buyer@example.invalid' }) });
    assert.equal(anonymous.code, 401);
    const admin = await request({ method: 'POST', url: '/api/billing/recover', headers: { authorization: 'Bearer isolated-admin-fixture', 'content-type': 'application/json' }, body: JSON.stringify({ email: 'buyer@example.invalid' }) });
    assert.equal(admin.code, 200);
    assert.equal(JSON.parse(admin.raw).licenses[0].key, key);
    const known = await request({ method: 'POST', url: '/api/billing/recover/request', headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.81' }, body: JSON.stringify({ email: 'buyer@example.invalid' }) });
    const unknown = await request({ method: 'POST', url: '/api/billing/recover/request', headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.82' }, body: JSON.stringify({ email: 'nobody@example.invalid' }) });
    assert.equal(known.code, 200);
    assert.deepEqual(JSON.parse(known.raw), JSON.parse(unknown.raw));
    assert.doesNotMatch(known.raw, /BSOS-/);
    const form = await request({ method: 'POST', url: '/billing/recover', headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-forwarded-for': '203.0.113.83' }, body: 'email=nobody%40example.invalid' });
    assert.equal(form.code, 200);
    assert.match(form.raw, /recovery message is on its way/);
    assert.doesNotMatch(form.raw, /BSOS-/);
    const token = recoveryToken(billing.getDevEmailOutbox().find((message) => message.to === 'buyer@example.invalid'));
    const page = await request({ method: 'GET', url: `/billing/recover?token=${encodeURIComponent(token)}`, headers: { 'x-forwarded-for': '203.0.113.84' } });
    assert.match(page.raw, new RegExp(key));
    const replay = await request({ method: 'GET', url: `/billing/recover?token=${encodeURIComponent(token)}`, headers: { 'x-forwarded-for': '203.0.113.85' } });
    assert.doesNotMatch(replay.raw, new RegExp(key));
    assert.match(replay.raw, /invalid or has expired/);
  } finally {
    if (oldStore) require.cache[storePath] = oldStore;
    else delete require.cache[storePath];
  }
});

test('device hash binding migrates a Mac-name activation and limits transfers to three a year', () => {
  const billing = load('device-transfer');
  const session = paid('cs_test_transfer');
  deliver(billing, session);
  const key = billing.getLicenseBySessionId(session.id).key;
  const current = deviceId('current-mac');
  const other = deviceId('other-mac');
  const third = deviceId('third-mac');
  const fourth = deviceId('fourth-mac');
  const fifth = deviceId('fifth-mac');
  assert.equal(billing.verifyLicenseKey(key, 'Fixture Mac', 'not-a-hash').valid, false);
  assert.equal(billing.getLicenseBySessionId(session.id).boundMachineName, '');
  assert.equal(billing.verifyLicenseKey(key, '').valid, false);
  assert.equal(billing.verifyLicenseKey(key, 'Fixture Mac').valid, true);
  assert.equal(billing.verifyLicenseKey(key, 'Other Mac', current).valid, false);
  const migrated = billing.verifyLicenseKey(key, 'Fixture Mac', current);
  assert.equal(migrated.valid, true);
  assert.equal(migrated.migrated, true);
  assert.equal(migrated.transfersRemaining, 3);
  assert.equal(billing.getLicenseBySessionId(session.id).boundDeviceId, current);
  assert.deepEqual(billing.getLicenseBySessionId(session.id).transfers, []);
  assert.equal(billing.verifyLicenseKey(key, 'Renamed Mac', current).valid, true);
  assert.equal(billing.verifyLicenseKey(key, 'Fixture Mac').valid, false);
  assert.equal(billing.deactivateDevice(key, other, 'Fixture Mac').deactivated, false);
  assert.equal(billing.getLicenseBySessionId(session.id).boundDeviceId, current);
  assert.equal(billing.deactivateDevice(key, current, 'Renamed Mac').deactivated, true);
  assert.equal(billing.verifyLicenseKey(key, 'Renamed Mac', current).valid, true);
  assert.equal(billing.getLicenseBySessionId(session.id).transfers.length, 0);
  const moves = [other, third, fourth];
  let active = current;
  for (const next of moves) {
    assert.equal(billing.deactivateDevice(key, active, 'Fixture Mac').deactivated, true);
    const activated = billing.verifyLicenseKey(key, 'Next Mac', next);
    assert.equal(activated.valid, true, next);
    active = next;
  }
  assert.equal(billing.getLicenseBySessionId(session.id).transfers.length, 3);
  assert.equal(billing.deactivateDevice(key, fourth, 'Next Mac').deactivated, true);
  const blocked = billing.verifyLicenseKey(key, 'Fifth Mac', fifth);
  assert.equal(blocked.valid, false);
  assert.match(blocked.message, /3 times/);
  assert.equal(blocked.transfersRemaining, 0);
  assert.equal(billing.verifyLicenseKey(key, 'Next Mac', fourth).valid, true);
  billing.setNowForTests(() => new Date(Date.now() + 366 * 24 * 60 * 60 * 1000));
  try {
    assert.equal(billing.deactivateDevice(key, fourth, 'Next Mac').deactivated, true);
    const later = billing.verifyLicenseKey(key, 'Fifth Mac', fifth);
    assert.equal(later.valid, true);
    assert.equal(later.transfersRemaining, 2);
  } finally {
    billing.setNowForTests();
  }
});

test('checkout still charges the configured one-time price', async () => {
  const billing = load('price-unchanged');
  let body = '';
  global.fetch = async (url, options) => {
    assert.equal(url, 'https://api.stripe.com/v1/checkout/sessions');
    body = options.body;
    return { ok: true, json: async () => ({ id: 'cs_price', url: 'https://checkout.example.invalid/price' }) };
  };
  await billing.createCheckoutSession('Fixture Mac');
  assert.match(body, /mode=payment/);
  assert.match(body, /line_items%5B0%5D%5Bprice%5D=price_isolated_fixture/);
  assert.doesNotMatch(body, /subscription|recurring/);
});

test('activation persists across an actual fresh Node process', () => {
  const {spawnSync}=require('node:child_process');
  const script="const b=require(process.argv[1]);const l=b.getLicenseBySessionId('cs_test_fixture');process.stdout.write(JSON.stringify({valid:b.verifyLicenseKey(l.key,'Fixture Mac').valid,other:b.verifyLicenseKey(l.key,'Different Mac').valid}));";
  const child=spawnSync(process.execPath,['-e',script,require.resolve('./billing')],{encoding:'utf8',timeout:5000,env:{...process.env,BATTERY_SOS_DATA_DIR:path.join(root,'journey')}});
  assert.equal(child.status,0,child.stderr); assert.deepEqual(JSON.parse(child.stdout),{valid:true,other:false});
});
