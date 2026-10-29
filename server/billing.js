const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { createEmailSender } = require('./email-sender');
const {
  privateKeyFromEnv,
  publicKeyBase64FromEnv,
  signEntitlement,
} = require('./entitlement');

// Production must point this at a persistent volume; Render's deployment
// filesystem is replaced on each deploy.
const DATA_DIR = process.env.BATTERY_SOS_DATA_DIR
  ? path.resolve(process.env.BATTERY_SOS_DATA_DIR)
  : path.resolve(__dirname, '..', 'data');
const BILLING_FILE = path.join(DATA_DIR, 'billing-data.json');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || '';
const STRIPE_PRICE_ID = process.env.STRIPE_PRICE_ID || '';
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || 'http://127.0.0.1:8787';
const DEFAULT_LICENSE_SECRET = 'change-me-before-production';
const WEBHOOK_TOLERANCE_MS = 5 * 60 * 1000;
// Webhook endpoints pinned to an older Stripe API version omit payment_status
// and customer_details. Re-retrieve those snapshots with this version, which
// includes both, and still issue a key only when payment_status is paid.
const CHECKOUT_FULFILLMENT_VERSION = '2022-11-15';

const RECOVERY_RESPONSE = {
  accepted: true,
  message: 'If a license exists for that email, we sent it to the address on file.',
};

const EMPTY_STATE = {
  licenses: {},
  sessions: {},
};

const devEmailOutbox = [];

function licenseSecret() {
  return process.env.LICENSE_SECRET || DEFAULT_LICENSE_SECRET;
}

function webhookSecret() {
  return process.env.STRIPE_WEBHOOK_SECRET || '';
}

function billingAdminToken() {
  return process.env.BILLING_ADMIN_TOKEN || '';
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function nowIso() {
  return new Date().toISOString();
}

function normalizeText(value) {
  return String(value || '').trim();
}

function normalizeKey(value) {
  return normalizeText(value).toUpperCase().replace(/\s+/g, '');
}

function normalizeMachineHash(value) {
  const hash = normalizeText(value).toLowerCase();
  return /^[a-f0-9]{64}$/.test(hash) ? hash : '';
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[character]));
}

function isEmailAddress(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) && value.length <= 254;
}

function ensureBillingFile() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (!fs.existsSync(BILLING_FILE)) {
    fs.writeFileSync(BILLING_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }

  const raw = fs.readFileSync(BILLING_FILE, 'utf8');
  if (!raw.trim()) {
    fs.writeFileSync(BILLING_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }

  try {
    const parsed = JSON.parse(raw);
    return {
      licenses: parsed.licenses && typeof parsed.licenses === 'object' ? parsed.licenses : {},
      sessions: parsed.sessions && typeof parsed.sessions === 'object' ? parsed.sessions : {},
    };
  } catch {
    fs.writeFileSync(BILLING_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }
}

let store = ensureBillingFile();

function persist() {
  fs.writeFileSync(BILLING_FILE, JSON.stringify(store, null, 2), 'utf8');
}

function requireStripeConfig() {
  if (!STRIPE_SECRET_KEY || !STRIPE_PRICE_ID) {
    const error = new Error('Stripe is not configured on the server.');
    error.statusCode = 500;
    throw error;
  }
}

async function createCheckoutSession(machineName) {
  requireStripeConfig();

  const form = new URLSearchParams();
  form.set('mode', 'payment');
  form.set('line_items[0][price]', STRIPE_PRICE_ID);
  form.set('line_items[0][quantity]', '1');
  form.set('success_url', `${PUBLIC_BASE_URL}/billing/success?session_id={CHECKOUT_SESSION_ID}`);
  form.set('cancel_url', `${PUBLIC_BASE_URL}/billing/cancel`);
  form.set('allow_promotion_codes', 'true');
  form.set('metadata[machineName]', normalizeText(machineName));
  form.set('metadata[app]', 'BatterySOS');

  const response = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form.toString(),
  });

  const payload = await response.json();
  if (!response.ok) {
    const message = payload?.error?.message || 'Stripe checkout session creation failed.';
    const error = new Error(message);
    error.statusCode = 502;
    throw error;
  }

  return {
    id: payload.id,
    url: payload.url,
  };
}

async function fetchCheckoutSessionById(sessionId, stripeVersion) {
  requireStripeConfig();
  const cleanId = normalizeText(sessionId);
  if (!cleanId) {
    const error = new Error('session_id is required.');
    error.statusCode = 400;
    throw error;
  }

  const headers = {
    Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
  };
  if (stripeVersion) headers['Stripe-Version'] = stripeVersion;

  const response = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(cleanId)}`, {
    method: 'GET',
    headers,
  });

  const payload = await response.json();
  if (!response.ok) {
    const message = payload?.error?.message || 'Unable to load checkout session.';
    const error = new Error(message);
    error.statusCode = 502;
    throw error;
  }

  return payload;
}

function generateLicenseKey(sessionId, machineName, email) {
  const source = `${sessionId}|${normalizeText(machineName)}|${normalizeText(email)}|${licenseSecret()}`;
  const digest = crypto.createHash('sha256').update(source).digest('hex').toUpperCase();
  const token = digest.slice(0, 20);
  const parts = token.match(/.{1,4}/g) || [token];
  return `BSOS-${parts.join('-')}`;
}

function issueLicenseForSession(session) {
  if (!session || !session.id) {
    return null;
  }

  const existingKey = store.sessions[session.id];
  if (existingKey && store.licenses[existingKey]) {
    return existingKey;
  }

  const machineName = normalizeText(session.metadata?.machineName || '');
  // customer_email is only a prefill. The address entered in Checkout is
  // customer_details.email on API versions that include that hash.
  const email = normalizeText(session.customer_details?.email || session.customer_email || '');
  const key = generateLicenseKey(session.id, machineName, email);

  store.sessions[session.id] = key;
  store.licenses[key] = {
    key,
    sessionId: session.id,
    createdAt: nowIso(),
    email,
    originalMachineName: machineName,
    boundMachineName: '',
    boundMachineHash: '',
  };
  persist();
  return key;
}

function getLicenseBySessionId(sessionId) {
  const key = store.sessions[sessionId];
  if (!key) return null;
  const license = store.licenses[key];
  if (!license) return null;
  return clone(license);
}

async function finalizeCheckoutSession(sessionId) {
  const cleanId = normalizeText(sessionId);
  if (!cleanId) {
    return { ready: false, message: 'Missing checkout session id.' };
  }

  const existing = getLicenseBySessionId(cleanId);
  if (existing?.key) {
    return { ready: true, key: existing.key, message: 'License already issued.' };
  }

  const session = await fetchCheckoutSessionById(cleanId);
  if (session.payment_status !== 'paid') {
    return { ready: false, message: `Payment status is ${session.payment_status || 'pending'}.` };
  }

  const key = issueLicenseForSession(session);
  if (!key) {
    return { ready: false, message: 'Unable to issue a license key yet.' };
  }

  return { ready: true, key, message: 'License issued.' };
}

// machineHash is SHA-256(IOPlatformUUID) and is what the signed entitlement
// binds. Limits:
// - The hash is not a secret. Anyone who can call this route can present one.
// - The first successful activation still wins. A caller who can spoof the
//   stored computer name (or who arrives before any name is bound) can bind
//   their own hash. After boundMachineHash is set, a different hash is rejected
//   and a name-only client is rejected.
// - A patched app can ignore the signature or replace the embedded public key.
// - Spoofing IOPlatformUUID for the process defeats the hash. Computer name
//   alone is not treated as the binding once a hash exists.
function interpretMachineHash(value) {
  if (value === undefined || value === null || normalizeText(value) === '') {
    return '';
  }
  const hash = normalizeMachineHash(value);
  if (!hash) {
    const error = new Error('machineHash must be a SHA-256 hex digest.');
    error.statusCode = 400;
    throw error;
  }
  return hash;
}

function verifyLicenseKey(licenseKey, machineName, machineHash) {
  const normalized = normalizeKey(licenseKey);
  if (!normalized) {
    return { valid: false, message: 'License key is required.' };
  }

  const license = store.licenses[normalized];
  if (!license) {
    return { valid: false, message: 'License key not found.' };
  }

  const hash = interpretMachineHash(machineHash);
  const name = normalizeText(machineName);
  const storedName = normalizeText(license.boundMachineName);
  const storedHash = normalizeMachineHash(license.boundMachineHash);

  if (hash && storedHash && storedHash !== hash) {
    return { valid: false, message: 'This key is already activated on another machine.' };
  }

  if (!hash && storedHash) {
    return {
      valid: false,
      message: 'This license is bound to a machine identity. Update Battery SOS and activate on that Mac.',
    };
  }

  const hashMatchesBinding = Boolean(hash && storedHash && storedHash === hash);
  if (!hashMatchesBinding && storedName && name && storedName !== name) {
    return { valid: false, message: 'This key is already activated on another machine.' };
  }

  let dirty = false;
  if (!storedName && name) {
    license.boundMachineName = name;
    dirty = true;
  }
  if (hash && !storedHash) {
    license.boundMachineHash = hash;
    dirty = true;
  }
  if (dirty) persist();

  const result = {
    valid: true,
    message: 'License key is valid.',
    normalizedKey: normalized,
  };
  if (hash) {
    result.entitlement = signEntitlement({
      licenseId: normalized,
      machineHash: hash,
      issuedAt: nowIso(),
    });
  }
  return result;
}

function safeEqualHex(a, b) {
  const aBuffer = Buffer.from(a, 'hex');
  const bBuffer = Buffer.from(b, 'hex');
  if (aBuffer.length !== bBuffer.length || aBuffer.length === 0) return false;
  return crypto.timingSafeEqual(aBuffer, bBuffer);
}

function verifyStripeWebhookSignature(rawBody, signatureHeader, nowMs = Date.now()) {
  const secret = webhookSecret();
  if (!secret) {
    const error = new Error('Stripe webhook secret is not configured.');
    error.statusCode = 500;
    throw error;
  }

  const header = String(signatureHeader || '');
  const parts = header.split(',').map((part) => part.trim());
  const timestampPart = parts.find((part) => part.startsWith('t='));
  const signatureParts = parts.filter((part) => part.startsWith('v1=')).map((part) => part.slice(3));

  if (!timestampPart || signatureParts.length === 0) {
    const error = new Error('Missing Stripe signature components.');
    error.statusCode = 400;
    throw error;
  }

  const timestamp = timestampPart.slice(2);
  if (!/^\d+$/.test(timestamp)) {
    const error = new Error('Stripe webhook timestamp is invalid.');
    error.statusCode = 400;
    throw error;
  }

  const timestampSeconds = Number(timestamp);
  const timestampMs = timestampSeconds * 1000;
  if (!Number.isSafeInteger(timestampSeconds) || Math.abs(nowMs - timestampMs) > WEBHOOK_TOLERANCE_MS) {
    const error = new Error('Stripe webhook timestamp is outside the five-minute tolerance.');
    error.statusCode = 400;
    throw error;
  }

  const payload = `${timestamp}.${rawBody}`;
  const expected = crypto.createHmac('sha256', secret).update(payload).digest('hex');
  const matched = signatureParts.some((candidate) => safeEqualHex(candidate, expected));

  if (!matched) {
    const error = new Error('Stripe signature verification failed.');
    error.statusCode = 400;
    throw error;
  }
}

function snapshotOmitsPaymentStatus(session) {
  return Boolean(session && session.object === 'checkout.session' && !Object.hasOwn(session, 'payment_status'));
}

async function sessionForFulfillment(snapshot) {
  if (!snapshotOmitsPaymentStatus(snapshot)) return snapshot;
  const sessionId = normalizeText(snapshot?.id);
  if (!sessionId) return null;
  return fetchCheckoutSessionById(sessionId, CHECKOUT_FULFILLMENT_VERSION);
}

async function handleStripeWebhook(rawBody, signatureHeader, nowMs = Date.now()) {
  verifyStripeWebhookSignature(rawBody, signatureHeader, nowMs);
  const event = JSON.parse(rawBody);

  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const snapshot = event.data?.object;
    const existingId = normalizeText(snapshot?.id);
    if (existingId && getLicenseBySessionId(existingId)) return { received: true };
    const session = await sessionForFulfillment(snapshot);
    if (session?.payment_status === 'paid') {
      issueLicenseForSession(session);
    }
  }

  return { received: true };
}

function renderSuccessPage(sessionId) {
  const cleanSessionId = normalizeText(sessionId);
  const safeSessionId = escapeHtml(cleanSessionId);
  const record = cleanSessionId ? getLicenseBySessionId(cleanSessionId) : null;

  const title = 'Battery SOS Purchase Complete';
  const header = '<h1>Battery SOS Pro Purchase Complete</h1>';
  const instruction = '<p>Copy this key and paste it into Battery SOS -> Settings -> Enter License Key...</p>';
  const keyMarkup = record
    ? `<pre id="license-key">${escapeHtml(record.key)}</pre><button id="copy-btn" type="button">Copy License Key</button>`
    : '<p id="status-message">Finalizing your payment and generating your key...</p>';

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>${title}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#0f1116; color:#e9eef7; margin:0; padding:40px; }
    .card { max-width:680px; margin:0 auto; background:#181d27; border:1px solid #2b3344; border-radius:14px; padding:28px; }
    h1 { margin-top:0; font-size:30px; }
    p { color:#b9c3d7; font-size:16px; line-height:1.5; }
    pre { background:#0b0f17; color:#7cf58c; font-size:24px; font-weight:700; padding:16px; border-radius:10px; overflow:auto; }
    button { margin-top:10px; background:#2d6cdf; color:#fff; border:none; border-radius:8px; padding:10px 16px; cursor:pointer; font-weight:600; }
  </style>
</head>
<body>
  <div class="card" id="card" data-session-id="${safeSessionId}">
    ${header}
    ${instruction}
    <div id="key-slot">${keyMarkup}</div>
  </div>
  <script>
    function wireCopy() {
      const btn = document.getElementById('copy-btn');
      const key = document.getElementById('license-key');
      if (!btn || !key) return;
      btn.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(key.textContent.trim());
          btn.textContent = 'Copied';
        } catch (_) {
          btn.textContent = 'Copy failed';
        }
      });
    }

    function showLicense(slot, licenseKey) {
      slot.replaceChildren();
      const pre = document.createElement('pre');
      pre.id = 'license-key';
      pre.textContent = licenseKey;
      const button = document.createElement('button');
      button.id = 'copy-btn';
      button.type = 'button';
      button.textContent = 'Copy License Key';
      slot.append(pre, button);
      wireCopy();
    }

    async function finalizeSession() {
      const card = document.getElementById('card');
      const slot = document.getElementById('key-slot');
      const sessionId = card && card.dataset ? card.dataset.sessionId : '';
      if (!sessionId || !slot) {
        return;
      }

      const response = await fetch('/api/billing/finalize-session?session_id=' + encodeURIComponent(sessionId));
      const payload = await response.json();

      if (payload.ready && payload.key) {
        showLicense(slot, String(payload.key));
      } else {
        const status = payload.message || 'Your payment is still processing. Refresh in a moment.';
        const statusEl = document.getElementById('status-message');
        if (statusEl) statusEl.textContent = status;
      }
    }

    wireCopy();
    finalizeSession().catch(() => {
      const statusEl = document.getElementById('status-message');
      if (statusEl) statusEl.textContent = 'Unable to finalize automatically. Refresh this page in a few seconds.';
    });
  </script>
</body>
</html>`;
}

function renderCancelPage() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Battery SOS Checkout Cancelled</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#10131a; color:#e9eef7; margin:0; padding:40px; }
    .card { max-width:680px; margin:0 auto; background:#1a1f2c; border:1px solid #2b3344; border-radius:14px; padding:28px; }
    h1 { margin-top:0; }
    p { color:#bdc8da; line-height:1.6; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Checkout Cancelled</h1>
    <p>No charge was made. You can reopen Battery SOS and choose Settings -> Unlock Pro ($1)... whenever you're ready.</p>
  </div>
</body>
</html>`;
}

function getEnvDiagnostics() {
  const issues = [];

  if (!STRIPE_SECRET_KEY) {
    issues.push('Missing STRIPE_SECRET_KEY');
  } else if (!/^sk_(test|live)_/.test(STRIPE_SECRET_KEY)) {
    issues.push('STRIPE_SECRET_KEY must start with sk_test_ or sk_live_');
  }

  if (!STRIPE_PRICE_ID) {
    issues.push('Missing STRIPE_PRICE_ID');
  } else if (!/^price_/.test(STRIPE_PRICE_ID)) {
    issues.push('STRIPE_PRICE_ID should start with price_');
  }

  if (!webhookSecret()) {
    issues.push('Missing STRIPE_WEBHOOK_SECRET');
  } else if (!/^whsec_/.test(webhookSecret())) {
    issues.push('STRIPE_WEBHOOK_SECRET should start with whsec_');
  }

  if (!PUBLIC_BASE_URL || /^http:\/\/127\.0\.0\.1/.test(PUBLIC_BASE_URL) || /^http:\/\/localhost/.test(PUBLIC_BASE_URL)) {
    issues.push('PUBLIC_BASE_URL is local-only; production requires a public HTTPS domain');
  } else if (!/^https:\/\//.test(PUBLIC_BASE_URL)) {
    issues.push('PUBLIC_BASE_URL should use https:// in production');
  }

  if (!process.env.LICENSE_SECRET || process.env.LICENSE_SECRET === DEFAULT_LICENSE_SECRET || licenseSecret().length < 16) {
    issues.push('LICENSE_SECRET is weak/default; set a long random secret');
  }

  if (!privateKeyFromEnv()) {
    issues.push('ENTITLEMENT_SIGNING_PRIVATE_KEY is missing or is not an Ed25519 PKCS#8 PEM');
  }

  const emailProvider = String(process.env.BILLING_EMAIL_PROVIDER || '').trim().toLowerCase();
  if (emailProvider !== 'http' || !normalizeText(process.env.BILLING_EMAIL_HTTP_URL)) {
    issues.push('Set BILLING_EMAIL_PROVIDER=http and BILLING_EMAIL_HTTP_URL so recovery emails are delivered');
  }

  return {
    ok: issues.length === 0,
    issues,
  };
}

function assertProductionConfig(env = process.env) {
  if (env.NODE_ENV !== 'production') return;

  const problems = [];
  if (!env.LICENSE_SECRET || env.LICENSE_SECRET === DEFAULT_LICENSE_SECRET) {
    problems.push('LICENSE_SECRET must be set to a non-default value in production.');
  }
  if (!privateKeyFromEnv(env)) {
    problems.push('ENTITLEMENT_SIGNING_PRIVATE_KEY must be an Ed25519 PKCS#8 PEM in production.');
  }
  const provider = String(env.BILLING_EMAIL_PROVIDER || '').trim().toLowerCase();
  if (provider !== 'http' || !normalizeText(env.BILLING_EMAIL_HTTP_URL)) {
    problems.push('BILLING_EMAIL_PROVIDER=http and BILLING_EMAIL_HTTP_URL must be set in production so license recovery is emailed.');
  }
  if (problems.length > 0) {
    const error = new Error(problems.join('\n'));
    error.code = 'PRODUCTION_CONFIG';
    throw error;
  }
}

function currentEmailSender() {
  return createEmailSender({
    provider: process.env.BILLING_EMAIL_PROVIDER || 'console',
    fetchImpl: global.fetch,
    httpUrl: process.env.BILLING_EMAIL_HTTP_URL || '',
    httpToken: process.env.BILLING_EMAIL_HTTP_TOKEN || '',
    onConsole(message) {
      devEmailOutbox.push(message);
    },
  });
}

function genericRecoveryResponse() {
  return { accepted: RECOVERY_RESPONSE.accepted, message: RECOVERY_RESPONSE.message };
}

// Always returns the same body. A matching license is emailed to the address
// on the license record. The key is never included in the response, including
// when delivery fails or the address is unknown.
async function recoverLicenseByEmail(email) {
  const target = normalizeText(email).toLowerCase();
  if (!isEmailAddress(target)) {
    const error = new Error('Enter the email address used at checkout.');
    error.statusCode = 400;
    throw error;
  }

  const matches = Object.values(store.licenses)
    .filter((license) => normalizeText(license.email).toLowerCase() === target)
    .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));

  if (matches.length === 0) {
    crypto.createHmac('sha256', licenseSecret()).update(`absent|${target}`).digest();
    return genericRecoveryResponse();
  }

  const lines = matches.map((license) => license.key);
  const text = [
    'Battery SOS received a request to email the license key for this address.',
    '',
    'License key(s):',
    ...lines,
    '',
    'Enter the key in Battery SOS -> Settings -> Enter License Key.',
    'If you did not ask for this, you can ignore this message.',
  ].join('\n');

  try {
    await currentEmailSender().send({
      to: target,
      subject: 'Battery SOS license recovery',
      text,
      html: `<p>Battery SOS received a request to email the license key for this address.</p><pre>${escapeHtml(lines.join('\n'))}</pre><p>Enter the key in Battery SOS -&gt; Settings -&gt; Enter License Key.</p>`,
    });
  } catch {
    console.error('billing recovery email failed');
  }

  return genericRecoveryResponse();
}

function getBillingAdminSummary() {
  const licenses = Object.values(store.licenses);
  return {
    totals: {
      licenses: licenses.length,
      bound: licenses.filter((item) => normalizeText(item.boundMachineName) || normalizeText(item.boundMachineHash)).length,
      unbound: licenses.filter((item) => !normalizeText(item.boundMachineName) && !normalizeText(item.boundMachineHash)).length,
      sessions: Object.keys(store.sessions).length,
    },
    recent: licenses
      .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')))
      .slice(0, 20)
      .map((license) => ({
        key: license.key,
        email: license.email || '',
        createdAt: license.createdAt,
        originalMachineName: license.originalMachineName || '',
        boundMachineName: license.boundMachineName || '',
        boundMachineHash: license.boundMachineHash || '',
      })),
  };
}

function isValidAdminToken(token) {
  const expected = billingAdminToken();
  if (!expected) return false;
  // Hash both sides so timingSafeEqual always compares equal-length buffers.
  const providedHash = crypto.createHash('sha256').update(String(token ?? ''), 'utf8').digest();
  const expectedHash = crypto.createHash('sha256').update(expected, 'utf8').digest();
  return crypto.timingSafeEqual(providedHash, expectedHash);
}

function getBillingConfig() {
  const diagnostics = getEnvDiagnostics();
  return {
    configured: Boolean(STRIPE_SECRET_KEY && STRIPE_PRICE_ID),
    publicBaseURL: PUBLIC_BASE_URL,
    entitlementPublicKey: publicKeyBase64FromEnv() || null,
    diagnostics,
  };
}

function resetBillingStateForTests() {
  store = clone(EMPTY_STATE);
  persist();
  devEmailOutbox.length = 0;
}

function seedLicenseForTests(license) {
  const key = normalizeKey(license.key);
  store.licenses[key] = {
    key,
    sessionId: license.sessionId || '',
    createdAt: license.createdAt || nowIso(),
    email: normalizeText(license.email),
    originalMachineName: normalizeText(license.originalMachineName),
    boundMachineName: normalizeText(license.boundMachineName),
    boundMachineHash: normalizeMachineHash(license.boundMachineHash),
  };
  if (license.sessionId) store.sessions[license.sessionId] = key;
  persist();
  return clone(store.licenses[key]);
}

function getDevEmailOutbox() {
  return devEmailOutbox.map((item) => ({ ...item }));
}

module.exports = {
  CHECKOUT_FULFILLMENT_VERSION,
  assertProductionConfig,
  createCheckoutSession,
  finalizeCheckoutSession,
  getBillingAdminSummary,
  getBillingConfig,
  getDevEmailOutbox,
  getEnvDiagnostics,
  getLicenseBySessionId,
  handleStripeWebhook,
  isValidAdminToken,
  recoverLicenseByEmail,
  renderCancelPage,
  renderSuccessPage,
  resetBillingStateForTests,
  seedLicenseForTests,
  verifyLicenseKey,
  verifyStripeWebhookSignature,
  publicKeyBase64FromEnv,
};
