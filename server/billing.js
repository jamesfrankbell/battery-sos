const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { createEmailSender } = require('./email-sender');

// Production must point this at a persistent volume; Render's deployment
// filesystem is replaced on each deploy.
const DATA_DIR = process.env.BATTERY_SOS_DATA_DIR
  ? path.resolve(process.env.BATTERY_SOS_DATA_DIR)
  : path.resolve(__dirname, '..', 'data');
const BILLING_FILE = path.join(DATA_DIR, 'billing-data.json');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || '';
const STRIPE_PRICE_ID = process.env.STRIPE_PRICE_ID || '';
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || '';
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || 'http://127.0.0.1:8787';
const LICENSE_SECRET = process.env.LICENSE_SECRET || 'change-me-before-production';
const BILLING_ADMIN_TOKEN = process.env.BILLING_ADMIN_TOKEN || '';
const TRANSFER_LIMIT = 3;
const TRANSFER_WINDOW_MS = 365 * 24 * 60 * 60 * 1000;
const RECOVERY_TTL_MS = 15 * 60 * 1000;
const RECOVERY_EMAIL_LIMIT = 5;
const RECOVERY_IP_LIMIT = 20;
const RECOVERY_CONFIRM_LIMIT = 8;
const RECOVERY_WINDOW_MS = 60 * 60 * 1000;
const RECOVERY_ACCEPTED_MESSAGE = 'If a license is associated with that email, a recovery message is on its way. It expires in 15 minutes and can be used once.';
const RECOVERY_INVALID_MESSAGE = 'That recovery link or code is invalid or has expired.';
const RECOVERY_RATE_MESSAGE = 'Too many recovery attempts. Please wait and try again.';
const devEmailOutbox = [];
let nowFn = () => new Date();

const EMPTY_STATE = {
  licenses: {},
  sessions: {},
  recoveryChallenges: {},
  recoveryRates: {},
};

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function nowDate() {
  return nowFn();
}

function nowIso() {
  return nowDate().toISOString();
}

function setNowForTests(fn) {
  nowFn = typeof fn === 'function' ? fn : () => new Date();
}

function normalizeText(value) {
  return String(value || '').trim();
}

function normalizeKey(value) {
  return normalizeText(value).toUpperCase().replace(/\s+/g, '');
}

// Single-process store: publish a new in-memory state only after durable replacement.
function writeStore(next) {
  const temporary = `${BILLING_FILE}.${process.pid}.${crypto.randomUUID()}.tmp`;
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(descriptor, JSON.stringify(next, null, 2), 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, BILLING_FILE);
  } catch {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch {}
    const error = new Error('License storage could not be saved. Please retry later.');
    error.statusCode = 503;
    throw error;
  }
}

function ensureBillingFile() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (!fs.existsSync(BILLING_FILE)) {
    const initial = clone(EMPTY_STATE);
    writeStore(initial);
    return initial;
  }
  // Never reset customer licenses after corruption or a partial/malformed record.
  const raw = fs.readFileSync(BILLING_FILE, 'utf8');
  try {
    const parsed = JSON.parse(raw);
    const dictionary = value => value && typeof value === 'object' && !Array.isArray(value);
    if (!dictionary(parsed) || !dictionary(parsed.licenses) || !dictionary(parsed.sessions)) throw new Error();
    for (const [key, record] of Object.entries(parsed.licenses)) {
      if (!dictionary(record) || record.key !== key || typeof record.sessionId !== 'string' ||
          typeof record.boundMachineName !== 'string' || parsed.sessions[record.sessionId] !== key) throw new Error();
    }
    for (const [session, key] of Object.entries(parsed.sessions)) {
      if (typeof key !== 'string' || !Object.hasOwn(parsed.licenses, key) || parsed.licenses[key].sessionId !== session) throw new Error();
    }
    if (!dictionary(parsed.recoveryChallenges)) parsed.recoveryChallenges = {};
    if (!dictionary(parsed.recoveryRates)) parsed.recoveryRates = {};
    return parsed;
  } catch {
    throw new Error('License storage is invalid; the original file has been preserved. Restore a verified backup before restarting.');
  }
}

let store = ensureBillingFile();
function persist(next) {
  writeStore(next);
  store = next;
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

async function fetchCheckoutSessionById(sessionId) {
  requireStripeConfig();
  const cleanId = normalizeText(sessionId);
  if (!cleanId) {
    const error = new Error('session_id is required.');
    error.statusCode = 400;
    throw error;
  }

  const response = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(cleanId)}`, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
    },
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
  const source = `${sessionId}|${normalizeText(machineName)}|${normalizeText(email)}|${LICENSE_SECRET}`;
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
  const email = normalizeText(session.customer_details?.email || '');
  const key = generateLicenseKey(session.id, machineName, email);

  const next = clone(store);
  next.sessions[session.id] = key;
  next.licenses[key] = {
    key,
    sessionId: session.id,
    createdAt: nowIso(),
    email,
    originalMachineName: machineName,
    boundMachineName: '',
    boundDeviceId: '',
    transfers: [],
    transferAnchorDeviceId: '',
  };
  persist(next);
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

function parseDeviceId(value) {
  const text = normalizeText(value).toLowerCase();
  if (!text) return { present: false, id: '' };
  if (!/^[a-f0-9]{64}$/.test(text)) return { present: true, id: '', invalid: true };
  return { present: true, id: text, invalid: false };
}

function recentTransferCount(license, now = nowDate()) {
  const list = Array.isArray(license.transfers) ? license.transfers : [];
  return list.filter((item) => {
    const at = Date.parse(item && item.at);
    return Number.isFinite(at) && now.getTime() - at < TRANSFER_WINDOW_MS;
  }).length;
}

function transfersRemaining(license, now = nowDate()) {
  return Math.max(0, TRANSFER_LIMIT - recentTransferCount(license, now));
}

function verifyLicenseKey(licenseKey, machineName, deviceId) {
  const normalized = normalizeKey(licenseKey);
  if (!normalized) return { valid: false, message: 'License key is required.' };
  const license = Object.hasOwn(store.licenses, normalized) ? store.licenses[normalized] : null;
  if (!license) return { valid: false, message: 'License key not found.' };
  const device = parseDeviceId(deviceId);
  if (device.invalid) return { valid: false, message: 'This Mac could not be identified for activation. Try again.' };
  if (device.present) return activateDevice(normalized, license, device.id, normalizeText(machineName));
  return activateLegacyMachine(normalized, license, normalizeText(machineName));
}

function activateLegacyMachine(key, license, machineName) {
  if (normalizeText(license.boundDeviceId)) {
    return { valid: false, message: 'This key is already activated on another machine.' };
  }
  if (!machineName) return { valid: false, message: 'Machine name is required for activation.' };
  if (license.boundMachineName && license.boundMachineName !== machineName) {
    return { valid: false, message: 'This key is already activated on another machine.' };
  }
  if (!license.boundMachineName) {
    const next = clone(store);
    next.licenses[key].boundMachineName = machineName;
    persist(next);
  }
  return { valid: true, message: 'License key is valid.', normalizedKey: key, transfersRemaining: transfersRemaining(license) };
}

function activateDevice(key, license, deviceId, machineName) {
  const bound = normalizeText(license.boundDeviceId).toLowerCase();
  if (bound) {
    if (bound === deviceId) {
      return { valid: true, message: 'License key is valid.', normalizedKey: key, transfersRemaining: transfersRemaining(license) };
    }
    return { valid: false, message: 'This key is already activated on another Mac. Deactivate it there before transferring.' };
  }
  if (normalizeText(license.boundMachineName)) {
    if (!machineName || machineName !== license.boundMachineName) {
      return { valid: false, message: 'This key is already activated on another machine.' };
    }
    const next = clone(store);
    next.licenses[key].boundDeviceId = deviceId;
    persist(next);
    return { valid: true, message: 'License key is valid.', normalizedKey: key, migrated: true, transfersRemaining: transfersRemaining(license) };
  }
  const anchor = normalizeText(license.transferAnchorDeviceId).toLowerCase();
  const isTransfer = Boolean(anchor) && anchor !== deviceId;
  if (isTransfer && recentTransferCount(license) >= TRANSFER_LIMIT) {
    return { valid: false, message: 'This key has already been transferred 3 times in the past year.', transfersRemaining: 0 };
  }
  const next = clone(store);
  const record = next.licenses[key];
  record.boundDeviceId = deviceId;
  if (machineName) record.boundMachineName = machineName;
  if (isTransfer) {
    if (!Array.isArray(record.transfers)) record.transfers = [];
    record.transfers.push({ at: nowIso(), fromDeviceId: anchor, toDeviceId: deviceId });
  }
  record.transferAnchorDeviceId = '';
  persist(next);
  return { valid: true, message: 'License key is valid.', normalizedKey: key, transfersRemaining: transfersRemaining(record) };
}

function deactivateDevice(licenseKey, deviceId, machineName) {
  const normalized = normalizeKey(licenseKey);
  if (!normalized) {
    const error = new Error('License key is required.');
    error.statusCode = 400;
    throw error;
  }
  const license = Object.hasOwn(store.licenses, normalized) ? store.licenses[normalized] : null;
  if (!license) return { deactivated: false, message: 'License key not found.' };
  const device = parseDeviceId(deviceId);
  if (device.invalid || !device.present) {
    return { deactivated: false, message: 'This Mac could not be identified for deactivation. Try again.' };
  }
  const boundDevice = normalizeText(license.boundDeviceId).toLowerCase();
  const boundName = normalizeText(license.boundMachineName);
  const name = normalizeText(machineName);
  let matches = false;
  if (boundDevice) matches = device.id === boundDevice;
  else if (boundName) matches = Boolean(name) && name === boundName;
  if (!matches) return { deactivated: false, message: 'This Mac is not the one activated for this license.' };
  const next = clone(store);
  const record = next.licenses[normalized];
  record.transferAnchorDeviceId = boundDevice || device.id;
  record.boundDeviceId = '';
  record.boundMachineName = '';
  record.deactivatedAt = nowIso();
  persist(next);
  return {
    deactivated: true,
    message: 'This Mac is deactivated. Activating a different Mac uses one of 3 transfers per year. Activating this Mac again does not.',
    transfersRemaining: transfersRemaining(record),
  };
}

function safeEqualHex(a, b) {
  if (!/^[a-fA-F0-9]{64}$/.test(a) || !/^[a-fA-F0-9]{64}$/.test(b)) return false;
  const aBuffer = Buffer.from(a, 'hex');
  const bBuffer = Buffer.from(b, 'hex');
  if (aBuffer.length !== bBuffer.length) return false;
  return crypto.timingSafeEqual(aBuffer, bBuffer);
}

function verifyStripeWebhookSignature(rawBody, signatureHeader) {
  if (!STRIPE_WEBHOOK_SECRET) {
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
  if (!/^\d+$/.test(timestamp) || !Number.isSafeInteger(Number(timestamp)) ||
      Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp)) > 300) {
    const error = new Error('Stripe webhook timestamp is invalid or outside the five-minute tolerance.');
    error.statusCode = 400;
    throw error;
  }
  const payload = `${timestamp}.${rawBody}`;
  const expected = crypto.createHmac('sha256', STRIPE_WEBHOOK_SECRET).update(payload).digest('hex');
  const matched = signatureParts.some((candidate) => safeEqualHex(candidate, expected));

  if (!matched) {
    const error = new Error('Stripe signature verification failed.');
    error.statusCode = 400;
    throw error;
  }
}

function handleStripeWebhook(rawBody, signatureHeader) {
  verifyStripeWebhookSignature(rawBody, signatureHeader);
  const event = JSON.parse(rawBody);

  if (['checkout.session.completed', 'checkout.session.async_payment_succeeded'].includes(event.type)) {
    const session = event.data?.object;
    if (session?.payment_status === 'paid') {
      issueLicenseForSession(session);
    }
  }

  return { received: true };
}

function renderSuccessPage(sessionId) {
  const cleanSessionId = normalizeText(sessionId);
  const safeSessionId = cleanSessionId.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const record = cleanSessionId ? getLicenseBySessionId(cleanSessionId) : null;

  const title = 'Battery SOS Purchase Complete';
  const header = '<h1>Battery SOS Pro Purchase Complete</h1>';
  const instruction = '<p>Copy this key and paste it into Battery SOS -> Settings -> Enter License Key...</p>';
  const keyMarkup = record
    ? `<pre id="license-key">${record.key}</pre><button id="copy-btn">Copy License Key</button>`
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

    let attempts = 0;
    async function finalizeSession() {
      attempts += 1;
      const card = document.getElementById('card');
      const slot = document.getElementById('key-slot');
      const sessionId = card?.dataset?.sessionId || '';
      if (!sessionId || !slot) {
        return;
      }

      const response = await fetch('/api/billing/finalize-session?session_id=' + encodeURIComponent(sessionId));
      const payload = await response.json();

      if (payload.ready && payload.key) {
        slot.innerHTML = '<pre id="license-key">' + payload.key + '</pre><button id="copy-btn">Copy License Key</button>';
        wireCopy();
      } else {
        const status = payload.message || 'Your payment is still processing. Refresh in a moment.';
        const statusEl = document.getElementById('status-message');
        if (statusEl) statusEl.textContent = status + (attempts >= 30 ? ' Refresh this page to check again.' : '');
        if (attempts < 30) setTimeout(() => finalizeSession().catch(showFinalizeError), 2000);
      }
    }

    wireCopy();
    function showFinalizeError() {
      const statusEl = document.getElementById('status-message');
      if (statusEl) statusEl.textContent = 'Unable to finalize automatically. Refresh this page in a few seconds.';
    }
    finalizeSession().catch(showFinalizeError);
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

  if (!STRIPE_WEBHOOK_SECRET) {
    issues.push('Missing STRIPE_WEBHOOK_SECRET');
  } else if (!/^whsec_/.test(STRIPE_WEBHOOK_SECRET)) {
    issues.push('STRIPE_WEBHOOK_SECRET should start with whsec_');
  }

  if (!PUBLIC_BASE_URL || /^http:\/\/127\.0\.0\.1/.test(PUBLIC_BASE_URL) || /^http:\/\/localhost/.test(PUBLIC_BASE_URL)) {
    issues.push('PUBLIC_BASE_URL is local-only; production requires a public HTTPS domain');
  } else if (!/^https:\/\//.test(PUBLIC_BASE_URL)) {
    issues.push('PUBLIC_BASE_URL should use https:// in production');
  }

  if (!LICENSE_SECRET || LICENSE_SECRET === 'change-me-before-production' || LICENSE_SECRET.length < 16) {
    issues.push('LICENSE_SECRET is weak/default; set a long random secret');
  }

  return {
    ok: issues.length === 0,
    issues,
  };
}

// Support-only lookup; the HTTP route requires the existing admin bearer token.
function recoverLicenseByEmail(email) {
  const target = normalizeText(email).toLowerCase();
  if (!target) {
    const error = new Error('email is required.');
    error.statusCode = 400;
    throw error;
  }

  const matches = Object.values(store.licenses)
    .filter((license) => normalizeText(license.email).toLowerCase() === target)
    .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));

  if (matches.length === 0) {
    return { found: false, message: 'No licenses found for that email.' };
  }

  return {
    found: true,
    count: matches.length,
    licenses: matches.map((license) => ({
      key: license.key,
      createdAt: license.createdAt,
      boundMachineName: license.boundMachineName || '',
      deviceBound: Boolean(normalizeText(license.boundDeviceId)),
      transfersRemaining: transfersRemaining(license),
    })),
  };
}

function getBillingAdminSummary() {
  const licenses = Object.values(store.licenses);
  return {
    totals: {
      licenses: licenses.length,
      bound: licenses.filter((item) => normalizeText(item.boundMachineName) || normalizeText(item.boundDeviceId)).length,
      unbound: licenses.filter((item) => !normalizeText(item.boundMachineName) && !normalizeText(item.boundDeviceId)).length,
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
        deviceBound: Boolean(normalizeText(license.boundDeviceId)),
        transfersRemaining: transfersRemaining(license),
      })),
  };
}

function normalizeEmail(value) {
  return normalizeText(value).toLowerCase();
}

function isEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) && value.length <= 254;
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function hashesEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length || a.length === 0) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

function escapeHtml(value) {
  return String(value || '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[character]));
}

function licensesForEmail(email) {
  return Object.values(store.licenses)
    .filter((license) => normalizeEmail(license.email) === email)
    .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
}

function currentEmailSender() {
  return createEmailSender({
    provider: process.env.BILLING_EMAIL_PROVIDER || 'console',
    fetchImpl: global.fetch,
    httpUrl: process.env.BILLING_EMAIL_HTTP_URL || '',
    httpToken: process.env.BILLING_EMAIL_HTTP_TOKEN || '',
    onConsole(message) { devEmailOutbox.push(message); },
  });
}

function getDevEmailOutbox() {
  return devEmailOutbox.map((item) => ({ ...item }));
}

function clearDevEmailOutbox() {
  devEmailOutbox.length = 0;
}

function rateBuckets({ email, ip, kind }) {
  const buckets = [];
  if (ip) buckets.push({ key: `ip:${ip}`, limit: RECOVERY_IP_LIMIT, windowMs: RECOVERY_WINDOW_MS });
  if (email) {
    buckets.push({
      key: `${kind}:${email}`,
      limit: kind === 'confirm' ? RECOVERY_CONFIRM_LIMIT : RECOVERY_EMAIL_LIMIT,
      windowMs: RECOVERY_WINDOW_MS,
    });
  }
  return buckets;
}

function assertAndConsumeRates(buckets) {
  if (buckets.length === 0) return;
  const now = nowDate().getTime();
  const within = (entry) => {
    const start = entry ? Date.parse(entry.windowStart) : NaN;
    return Number.isFinite(start) && now - start < RECOVERY_WINDOW_MS;
  };
  for (const bucket of buckets) {
    const entry = store.recoveryRates?.[bucket.key];
    if (within(entry) && entry.count >= bucket.limit) {
      const error = new Error(RECOVERY_RATE_MESSAGE);
      error.statusCode = 429;
      throw error;
    }
  }
  const next = clone(store);
  if (!next.recoveryRates) next.recoveryRates = {};
  for (const bucket of buckets) {
    const entry = next.recoveryRates[bucket.key];
    if (!within(entry)) next.recoveryRates[bucket.key] = { count: 1, windowStart: new Date(now).toISOString() };
    else next.recoveryRates[bucket.key] = { count: entry.count + 1, windowStart: entry.windowStart };
  }
  persist(next);
}

function purgeExpiredChallenges(next) {
  const now = nowDate().getTime();
  for (const [id, challenge] of Object.entries(next.recoveryChallenges || {})) {
    if (!challenge || !(Date.parse(challenge.expiresAt) > now)) delete next.recoveryChallenges[id];
  }
}

function createRecoveryMaterial(email) {
  const exp = nowDate().getTime() + RECOVERY_TTL_MS;
  const nonce = crypto.randomBytes(16).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ email, exp, nonce })).toString('base64url');
  const signature = crypto.createHmac('sha256', LICENSE_SECRET).update(payload).digest('base64url');
  const token = `${payload}.${signature}`;
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.randomBytes(8);
  let code = '';
  for (let index = 0; index < 8; index += 1) code += alphabet[bytes[index] % alphabet.length];
  return { token, code, exp };
}

function readRecoveryToken(token) {
  const text = String(token || '');
  const dot = text.lastIndexOf('.');
  if (dot <= 0) return null;
  const payload = text.slice(0, dot);
  const signature = text.slice(dot + 1);
  const expected = crypto.createHmac('sha256', LICENSE_SECRET).update(payload).digest('base64url');
  const supplied = Buffer.from(signature);
  const required = Buffer.from(expected);
  if (supplied.length !== required.length || supplied.length === 0 || !crypto.timingSafeEqual(supplied, required)) return null;
  let parsed;
  try { parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')); } catch { return null; }
  if (!parsed || typeof parsed.email !== 'string' || typeof parsed.exp !== 'number' || typeof parsed.nonce !== 'string') return null;
  if (nowDate().getTime() > parsed.exp) return null;
  return parsed;
}

function recoveryMessage(link, code) {
  return [
    'Battery SOS received a request to show the license key for this email.',
    '',
    'Open this one-time link (expires in 15 minutes):',
    link,
    '',
    `Or enter this code in Battery SOS recovery: ${code}`,
    '',
    'If you did not ask for this, ignore this message. The key is not included here.',
  ].join('\n');
}

function acceptedRecovery() {
  return { accepted: true, message: RECOVERY_ACCEPTED_MESSAGE };
}

function invalidRecovery() {
  return { revealed: false, message: RECOVERY_INVALID_MESSAGE };
}

function publicLicense(license) {
  return {
    key: license.key,
    createdAt: license.createdAt,
    boundMachineName: license.boundMachineName || '',
    deviceBound: Boolean(normalizeText(license.boundDeviceId)),
    transfersRemaining: transfersRemaining(license),
  };
}

function revealLicenses(email, challengeId) {
  const matches = licensesForEmail(email);
  const next = clone(store);
  if (next.recoveryChallenges) delete next.recoveryChallenges[challengeId];
  persist(next);
  return { revealed: true, message: 'License recovery confirmed.', licenses: matches.map(publicLicense) };
}

async function requestLicenseRecovery({ email, ip } = {}) {
  const normalized = normalizeEmail(email);
  if (!isEmail(normalized)) {
    const error = new Error('Enter the email address used at checkout.');
    error.statusCode = 400;
    throw error;
  }
  assertAndConsumeRates(rateBuckets({ email: normalized, ip: normalizeText(ip), kind: 'request' }));
  const matches = licensesForEmail(normalized);
  if (matches.length === 0) {
    crypto.createHmac('sha256', LICENSE_SECRET).update(`absent|${normalized}`).digest();
    return acceptedRecovery();
  }
  const material = createRecoveryMaterial(normalized);
  const id = crypto.randomBytes(16).toString('hex');
  const next = clone(store);
  if (!next.recoveryChallenges) next.recoveryChallenges = {};
  purgeExpiredChallenges(next);
  for (const [challengeId, challenge] of Object.entries(next.recoveryChallenges)) {
    if (challenge && challenge.email === normalized) delete next.recoveryChallenges[challengeId];
  }
  next.recoveryChallenges[id] = {
    email: normalized,
    tokenHash: sha256(material.token),
    codeHash: sha256(`${normalized}|${material.code}`),
    expiresAt: new Date(material.exp).toISOString(),
  };
  persist(next);
  const link = `${PUBLIC_BASE_URL}/billing/recover?token=${encodeURIComponent(material.token)}`;
  const text = recoveryMessage(link, material.code);
  try {
    await currentEmailSender().send({
      to: normalized,
      subject: 'Battery SOS license recovery',
      text,
      html: escapeHtml(text).replace(/\n/g, '<br>'),
    });
  } catch {
    const rollback = clone(store);
    if (rollback.recoveryChallenges) delete rollback.recoveryChallenges[id];
    try { persist(rollback); } catch { /* keep the generic response either way */ }
  }
  return acceptedRecovery();
}

function confirmLicenseRecovery({ email, code, token, ip } = {}) {
  const tokenText = normalizeText(token);
  if (tokenText) return confirmRecoveryToken(tokenText, ip);
  return confirmRecoveryCode(email, code, ip);
}

function confirmRecoveryToken(token, ip) {
  const parsed = readRecoveryToken(token);
  const email = parsed ? normalizeEmail(parsed.email) : '';
  const buckets = rateBuckets({ email, ip: normalizeText(ip), kind: 'confirm' });
  if (!email && ip) buckets.push({ key: `confirm-ip:${normalizeText(ip)}`, limit: RECOVERY_CONFIRM_LIMIT, windowMs: RECOVERY_WINDOW_MS });
  assertAndConsumeRates(buckets);
  if (!parsed || !isEmail(email)) return invalidRecovery();
  const hash = sha256(token);
  const entry = Object.entries(store.recoveryChallenges || {}).find(([, challenge]) => (
    challenge && challenge.email === email && hashesEqual(challenge.tokenHash, hash)
  ));
  if (!entry) return invalidRecovery();
  const [id, challenge] = entry;
  if (!(Date.parse(challenge.expiresAt) > nowDate().getTime())) return invalidRecovery();
  return revealLicenses(email, id);
}

function confirmRecoveryCode(email, code, ip) {
  const normalized = normalizeEmail(email);
  if (!isEmail(normalized)) {
    const error = new Error('Enter the email address used at checkout.');
    error.statusCode = 400;
    throw error;
  }
  assertAndConsumeRates(rateBuckets({ email: normalized, ip: normalizeText(ip), kind: 'confirm' }));
  const cleanCode = normalizeText(code).toUpperCase().replace(/\s+/g, '');
  if (!/^[A-Z2-9]{8}$/.test(cleanCode)) return invalidRecovery();
  const hash = sha256(`${normalized}|${cleanCode}`);
  const entry = Object.entries(store.recoveryChallenges || {}).find(([, challenge]) => (
    challenge && challenge.email === normalized && hashesEqual(challenge.codeHash, hash)
  ));
  if (!entry) return invalidRecovery();
  const [id, challenge] = entry;
  if (!(Date.parse(challenge.expiresAt) > nowDate().getTime())) return invalidRecovery();
  return revealLicenses(normalized, id);
}

function renderRecoveryPage(result) {
  const revealed = Boolean(result && result.revealed && Array.isArray(result.licenses));
  const accepted = Boolean(result && result.accepted);
  const invalid = Boolean(result && result.revealed === false);
  const message = escapeHtml((result && result.message) || '');
  let body;
  if (revealed) {
    const keys = result.licenses.map((license) => `<pre>${escapeHtml(license.key)}</pre>`).join('');
    body = `<h1>License key</h1><p>${message}</p>${keys}<p>Enter the key in Battery SOS → Settings → Enter License Key… This page does not deactivate a Mac.</p><p><a href="/billing/recover">Start over</a></p>`;
  } else if (accepted || invalid) {
    body = `<h1>License recovery</h1><p>${message}</p><p><a href="/billing/recover">Start over</a></p>`;
  } else {
    body = `<h1>License recovery</h1>
      <p>Enter the email from your Battery SOS purchase. If a license exists, we email a one-time link and code. That message never includes the key.</p>
      <form method="post" action="/billing/recover">
        <label>Purchase email<br><input name="email" type="email" autocomplete="email" required></label>
        <button type="submit">Email me a recovery link</button>
      </form>
      <form method="post" action="/billing/recover/confirm">
        <label>Purchase email<br><input name="email" type="email" autocomplete="email" required></label>
        <label>Recovery code<br><input name="code" autocomplete="one-time-code" required></label>
        <button type="submit">Show my license key</button>
      </form>`;
  }
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="referrer" content="no-referrer" />
  <title>Battery SOS License Recovery</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#0f1116; color:#e9eef7; margin:0; padding:40px; }
    .card { max-width:680px; margin:0 auto; background:#181d27; border:1px solid #2b3344; border-radius:14px; padding:28px; }
    h1 { margin-top:0; font-size:30px; }
    p, label { color:#b9c3d7; font-size:16px; line-height:1.5; }
    form { margin:20px 0; }
    input { width:100%; box-sizing:border-box; margin:8px 0 14px; padding:10px; border-radius:8px; border:1px solid #2b3344; background:#0b0f17; color:#e9eef7; }
    button { background:#2d6cdf; color:#fff; border:none; border-radius:8px; padding:10px 16px; cursor:pointer; font-weight:600; }
    pre { background:#0b0f17; color:#7cf58c; font-size:24px; font-weight:700; padding:16px; border-radius:10px; overflow:auto; }
    a { color:#9ebcff; }
  </style>
</head>
<body><div class="card">${body}</div></body>
</html>`;
}

function isValidAdminToken(token) {
  const supplied = Buffer.from(normalizeText(token));
  const expected = Buffer.from(BILLING_ADMIN_TOKEN);
  return expected.length > 0 && supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

function getBillingConfig() {
  const diagnostics = getEnvDiagnostics();
  return {
    configured: Boolean(STRIPE_SECRET_KEY && STRIPE_PRICE_ID),
    publicBaseURL: PUBLIC_BASE_URL,
    diagnostics,
  };
}

module.exports = {
  clearDevEmailOutbox,
  confirmLicenseRecovery,
  createCheckoutSession,
  deactivateDevice,
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
  renderRecoveryPage,
  renderSuccessPage,
  requestLicenseRecovery,
  setNowForTests,
  verifyLicenseKey,
};
