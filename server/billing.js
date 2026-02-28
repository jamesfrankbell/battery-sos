const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const DATA_DIR = path.resolve(__dirname, '..', 'data');
const BILLING_FILE = path.join(DATA_DIR, 'billing-data.json');

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || '';
const STRIPE_PRICE_ID = process.env.STRIPE_PRICE_ID || '';
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || '';
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || 'http://127.0.0.1:8787';
const LICENSE_SECRET = process.env.LICENSE_SECRET || 'change-me-before-production';
const BILLING_ADMIN_TOKEN = process.env.BILLING_ADMIN_TOKEN || '';

const EMPTY_STATE = {
  licenses: {},
  sessions: {},
};

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

  store.sessions[session.id] = key;
  store.licenses[key] = {
    key,
    sessionId: session.id,
    createdAt: nowIso(),
    email,
    originalMachineName: machineName,
    boundMachineName: '',
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

function verifyLicenseKey(licenseKey, machineName) {
  const normalized = normalizeKey(licenseKey);
  if (!normalized) {
    return { valid: false, message: 'License key is required.' };
  }

  const license = store.licenses[normalized];
  if (!license) {
    return { valid: false, message: 'License key not found.' };
  }

  const normalizedMachine = normalizeText(machineName);
  if (license.boundMachineName && normalizedMachine && license.boundMachineName !== normalizedMachine) {
    return { valid: false, message: 'This key is already activated on another machine.' };
  }

  if (!license.boundMachineName && normalizedMachine) {
    license.boundMachineName = normalizedMachine;
    persist();
  }

  return {
    valid: true,
    message: 'License key is valid.',
    normalizedKey: normalized,
  };
}

function safeEqualHex(a, b) {
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

  if (event.type === 'checkout.session.completed') {
    const session = event.data?.object;
    if (session?.payment_status === 'paid') {
      issueLicenseForSession(session);
    }
  }

  return { received: true };
}

function renderSuccessPage(sessionId) {
  const cleanSessionId = normalizeText(sessionId);
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
  <div class="card" id="card" data-session-id="${cleanSessionId}">
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

    async function finalizeSession() {
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
    })),
  };
}

function getBillingAdminSummary() {
  const licenses = Object.values(store.licenses);
  return {
    totals: {
      licenses: licenses.length,
      bound: licenses.filter((item) => normalizeText(item.boundMachineName)).length,
      unbound: licenses.filter((item) => !normalizeText(item.boundMachineName)).length,
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
      })),
  };
}

function isValidAdminToken(token) {
  return Boolean(BILLING_ADMIN_TOKEN) && normalizeText(token) === BILLING_ADMIN_TOKEN;
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
  createCheckoutSession,
  finalizeCheckoutSession,
  getBillingAdminSummary,
  getBillingConfig,
  getEnvDiagnostics,
  getLicenseBySessionId,
  handleStripeWebhook,
  isValidAdminToken,
  recoverLicenseByEmail,
  renderCancelPage,
  renderSuccessPage,
  verifyLicenseKey,
};
