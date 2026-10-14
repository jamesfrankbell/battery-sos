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
  await deliver(billing, session);
  assert.equal(billing.getLicenseBySessionId(session.id), null);
  session = paid();
  await deliver(billing, session, 'checkout.session.async_payment_succeeded');
  const result = await billing.finalizeCheckoutSession(session.id);
  assert.equal(result.ready, true);
  assert.equal(billing.verifyLicenseKey('invalid', 'Fixture Mac').valid, false);
  assert.equal(billing.verifyLicenseKey(result.key, '').valid, false);
  assert.equal(billing.verifyLicenseKey(result.key.toLowerCase(), 'Fixture Mac').valid, true);
  billing = load('journey');
  assert.equal(billing.verifyLicenseKey(result.key, 'Fixture Mac').valid, true);
  assert.equal(billing.verifyLicenseKey(result.key, 'Different Mac').valid, false);
  await deliver(billing, session);
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 1);
  assert.equal(billing.getLicenseBySessionId(session.id).key, result.key);
  assert.match(billing.renderCancelPage(), /Checkout Cancelled/);
});

test('stale, future, malformed and forged signatures cannot issue licenses', async () => {
  const billing = load('webhooks'), now = Math.floor(Date.now()/1000);
  for (const stamp of [now-301, now+301, 'NaN']) await assert.rejects(() => deliver(billing, paid(), undefined, stamp));
  await assert.rejects(() => deliver(billing, paid(), undefined, now, 'garbage'));
  await assert.rejects(() => billing.handleStripeWebhook('{}', `t=${now},v1=${'0'.repeat(64)}`));
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 0);
  await deliver(billing, paid(), undefined, now);
  await deliver(billing, paid(), undefined, now);
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 1);
});

test('corrupt, empty and inconsistent stores fail closed without modifying original bytes', () => {
  for (const [name, contents] of [['corrupt','{broken'], ['empty',''], ['shape','[]'], ['orphan','{"licenses":{},"sessions":{"cs_test_orphan":"missing"}}']]) {
    assert.throws(() => load(name, contents), /original file has been preserved/);
    assert.equal(fs.readFileSync(path.join(root,name,'billing-data.json'),'utf8'), contents);
  }
});

test('failed persistence neither binds the in-memory license nor damages prior bytes', async () => {
  const billing = load('write-failure'); await deliver(billing, paid());
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
  const billing = load('recovery'); await deliver(billing, paid());
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

function legacy2019CheckoutSession(id = 'cs_test_20190314') {
  return {
    id,
    object: 'checkout.session',
    billing_address_collection: null,
    cancel_url: 'https://pay.batterysos.app/billing/cancel',
    client_reference_id: null,
    customer: 'cus_20190314',
    customer_email: null,
    display_items: [{
      amount: 100,
      currency: 'usd',
      custom: { description: null, images: null, name: 'Battery SOS Pro' },
      quantity: 1,
      type: 'custom',
    }],
    livemode: false,
    locale: null,
    payment_intent: 'pi_20190314',
    payment_method_types: ['card'],
    subscription: null,
    success_url: 'https://pay.batterysos.app/billing/success?session_id={CHECKOUT_SESSION_ID}',
  };
}

test('2019-03-14 checkout.session.completed issues a key only after a paid current-version retrieve', async () => {
  const billing = load('legacy-api-2019-03-14');
  const legacy = legacy2019CheckoutSession();
  assert.equal(Object.hasOwn(legacy, 'payment_status'), false);
  assert.equal(Object.hasOwn(legacy, 'customer_details'), false);
  assert.equal(Object.hasOwn(legacy, 'metadata'), false);
  const calls = [];
  global.fetch = async () => ({ ok: false, json: async () => ({ error: { message: 'isolated retrieve failure' } }) });
  await assert.rejects(() => deliver(billing, legacy), /isolated retrieve failure/);
  assert.equal(billing.getLicenseBySessionId(legacy.id), null);

  global.fetch = async (url, options = {}) => {
    calls.push({ url, version: options.headers?.['Stripe-Version'] || '' });
    return { ok: true, json: async () => ({ ...paid(legacy.id), payment_status: 'unpaid', customer_details: null, customer_email: null }) };
  };
  await deliver(billing, legacy);
  assert.deepEqual(calls, [{
    url: 'https://api.stripe.com/v1/checkout/sessions/cs_test_20190314',
    version: '2022-11-15',
  }]);
  assert.equal(billing.getLicenseBySessionId(legacy.id), null);

  global.fetch = async (url, options = {}) => {
    calls.push({ url, version: options.headers?.['Stripe-Version'] || '' });
    return { ok: true, json: async () => paid(legacy.id) };
  };
  await deliver(billing, legacy, 'checkout.session.completed');
  const license = billing.getLicenseBySessionId(legacy.id);
  assert.equal(license.email, 'buyer@example.invalid');
  assert.equal(license.originalMachineName, 'Fixture Mac');
  await deliver(billing, legacy);
  assert.equal(billing.getBillingAdminSummary().totals.licenses, 1);
  assert.equal(calls.filter((call) => call.version === '2022-11-15').length, 2);
});

test('public site can preflight checkout without exposing other origins', async () => {
  delete require.cache[require.resolve('./router')];
  const handler = require('./router').createRequestHandler();
  async function request(method, origin) {
    const req = new PassThrough();
    Object.assign(req, {
      method,
      url: '/api/billing/create-checkout-session',
      headers: { origin, 'content-type': 'application/json' },
    });
    let code;
    const headers = {};
    const res = {
      setHeader(name, value) { headers[name.toLowerCase()] = value; },
      writeHead(status) { code = status; },
      end() {},
    };
    const pending = handler(req, res);
    req.end();
    await pending;
    return { code, headers };
  }
  const allowed = await request('OPTIONS', 'https://batterysos.app');
  assert.equal(allowed.code, 204);
  assert.equal(allowed.headers['access-control-allow-origin'], 'https://batterysos.app');
  assert.match(allowed.headers['access-control-allow-methods'], /POST/);
  const denied = await request('OPTIONS', 'https://evil.example');
  assert.equal(denied.code, 204);
  assert.equal(denied.headers['access-control-allow-origin'], undefined);
});

test('activation persists across an actual fresh Node process', () => {
  const {spawnSync}=require('node:child_process');
  const script="const b=require(process.argv[1]);const l=b.getLicenseBySessionId('cs_test_fixture');process.stdout.write(JSON.stringify({valid:b.verifyLicenseKey(l.key,'Fixture Mac').valid,other:b.verifyLicenseKey(l.key,'Different Mac').valid}));";
  const child=spawnSync(process.execPath,['-e',script,require.resolve('./billing')],{encoding:'utf8',timeout:5000,env:{...process.env,BATTERY_SOS_DATA_DIR:path.join(root,'journey')}});
  assert.equal(child.status,0,child.stderr); assert.deepEqual(JSON.parse(child.stdout),{valid:true,other:false});
});
