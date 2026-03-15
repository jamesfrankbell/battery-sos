const fs = require('node:fs');
const path = require('node:path');
const {
  createCheckoutSession,
  finalizeCheckoutSession,
  getBillingAdminSummary,
  getBillingConfig,
  handleStripeWebhook,
  isValidAdminToken,
  recoverLicenseByEmail,
  renderCancelPage,
  renderSuccessPage,
  verifyLicenseKey,
} = require('./billing');

const {
  createDocument,
  createTask,
  deleteDocument,
  deleteTask,
  getState,
  updateDocument,
  updateTask,
} = require('./store');

const CLIENT_DIR = path.resolve(__dirname, '..', 'website');
const DOWNLOADS_DIR = path.resolve(__dirname, '..', 'mac', 'dist');

const MIME_TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.dmg': 'application/x-apple-diskimage',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.sha256': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
};

function sendJson(res, statusCode, payload) {
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify(payload));
}

function sendError(res, statusCode, message) {
  sendJson(res, statusCode, { error: message });
}

function sendHtml(res, html, statusCode = 200) {
  res.writeHead(statusCode, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}

function sendFile(res, filePath, extraHeaders = {}) {
  const extension = path.extname(filePath).toLowerCase();
  const contentType = MIME_TYPES[extension] || 'application/octet-stream';
  res.writeHead(200, {
    'content-type': contentType,
    ...extraHeaders,
  });
  fs.createReadStream(filePath).pipe(res);
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';

    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 1_000_000) {
        reject(new Error('Request body is too large.'));
      }
    });

    req.on('end', () => {
      if (!raw.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('Invalid JSON body.'));
      }
    });

    req.on('error', reject);
  });
}

function parseRawBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';

    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 2_000_000) {
        reject(new Error('Request body is too large.'));
      }
    });

    req.on('end', () => resolve(raw));
    req.on('error', reject);
  });
}

async function handleApi(req, res, pathname) {
  if (req.method === 'GET' && pathname === '/api/billing/status') {
    sendJson(res, 200, getBillingConfig());
    return;
  }

  if (req.method === 'POST' && pathname === '/api/billing/create-checkout-session') {
    const payload = await parseBody(req);
    const session = await createCheckoutSession(payload.machineName);
    sendJson(res, 200, session);
    return;
  }

  if (req.method === 'POST' && pathname === '/api/billing/verify-license') {
    const payload = await parseBody(req);
    sendJson(res, 200, verifyLicenseKey(payload.licenseKey, payload.machineName));
    return;
  }

  if (req.method === 'POST' && pathname === '/api/billing/recover') {
    const payload = await parseBody(req);
    sendJson(res, 200, recoverLicenseByEmail(payload.email));
    return;
  }

  if (req.method === 'GET' && pathname === '/api/billing/admin/licenses') {
    const authHeader = String(req.headers.authorization || '');
    const requestUrl = new URL(req.url || '/', 'http://localhost');
    const tokenFromHeader = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    const tokenFromQuery = requestUrl.searchParams.get('token') || '';
    const token = tokenFromHeader || tokenFromQuery;

    if (!isValidAdminToken(token)) {
      sendError(res, 401, 'Unauthorized');
      return;
    }

    sendJson(res, 200, getBillingAdminSummary());
    return;
  }

  if (req.method === 'GET' && pathname === '/api/billing/finalize-session') {
    const requestUrl = new URL(req.url || '/', 'http://localhost');
    const sessionId = requestUrl.searchParams.get('session_id') || '';
    sendJson(res, 200, await finalizeCheckoutSession(sessionId));
    return;
  }

  if (req.method === 'POST' && pathname === '/api/billing/webhook') {
    const raw = await parseRawBody(req);
    const signature = req.headers['stripe-signature'] || '';
    sendJson(res, 200, handleStripeWebhook(raw, signature));
    return;
  }

  if (req.method === 'GET' && pathname === '/api/state') {
    sendJson(res, 200, getState());
    return;
  }

  if (req.method === 'POST' && pathname === '/api/tasks') {
    const payload = await parseBody(req);
    sendJson(res, 201, createTask(payload));
    return;
  }

  const taskMatch = pathname.match(/^\/api\/tasks\/([^/]+)$/);
  if (taskMatch) {
    const taskId = decodeURIComponent(taskMatch[1]);

    if (req.method === 'PATCH') {
      const payload = await parseBody(req);
      sendJson(res, 200, updateTask(taskId, payload));
      return;
    }

    if (req.method === 'DELETE') {
      sendJson(res, 200, deleteTask(taskId));
      return;
    }
  }

  if (req.method === 'POST' && pathname === '/api/documents') {
    const payload = await parseBody(req);
    sendJson(res, 201, createDocument(payload));
    return;
  }

  const documentMatch = pathname.match(/^\/api\/documents\/([^/]+)$/);
  if (documentMatch) {
    const documentId = decodeURIComponent(documentMatch[1]);

    if (req.method === 'PATCH') {
      const payload = await parseBody(req);
      sendJson(res, 200, updateDocument(documentId, payload));
      return;
    }

    if (req.method === 'DELETE') {
      sendJson(res, 200, deleteDocument(documentId));
      return;
    }
  }

  sendError(res, 404, 'API route not found.');
}

function resolveStaticFile(pathname) {
  const requested = pathname === '/' ? '/index.html' : pathname;
  const safePath = path.normalize(requested).replace(/^([.][.][/\\])+/, '').replace(/^[/\\]+/, '');
  const absolutePath = path.join(CLIENT_DIR, safePath);

  if (!absolutePath.startsWith(CLIENT_DIR)) {
    return null;
  }

  if (fs.existsSync(absolutePath) && fs.statSync(absolutePath).isFile()) {
    return absolutePath;
  }

  return null;
}

function handleStatic(res, pathname) {
  const filePath = resolveStaticFile(pathname);

  if (filePath) {
    sendFile(res, filePath);
    return;
  }

  if (!path.extname(pathname)) {
    sendFile(res, path.join(CLIENT_DIR, 'index.html'));
    return;
  }

  sendError(res, 404, 'File not found.');
}

function handleBillingPage(res, requestUrl) {
  if (requestUrl.pathname === '/billing/success') {
    const sessionId = requestUrl.searchParams.get('session_id') || '';
    sendHtml(res, renderSuccessPage(sessionId));
    return true;
  }

  if (requestUrl.pathname === '/billing/cancel') {
    sendHtml(res, renderCancelPage());
    return true;
  }

  return false;
}

function resolveDownloadFile(pathname) {
  if (pathname === '/downloads/battery-sos-macos.dmg') {
    return path.join(DOWNLOADS_DIR, 'battery-sos-macos.dmg');
  }

  if (pathname === '/downloads/battery-sos-macos.dmg.sha256') {
    return path.join(DOWNLOADS_DIR, 'battery-sos-macos.dmg.sha256');
  }

  return null;
}

function handleDownloads(res, pathname) {
  const filePath = resolveDownloadFile(pathname);
  if (!filePath) return false;

  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    sendError(res, 404, 'Download not found.');
    return true;
  }

  const downloadName = path.basename(filePath);
  sendFile(res, filePath, {
    'content-disposition': `attachment; filename="${downloadName}"`,
    'x-content-type-options': 'nosniff',
    'cache-control': 'public, max-age=300',
  });
  return true;
}

function createRequestHandler() {
  return async (req, res) => {
    try {
      const requestUrl = new URL(req.url || '/', 'http://localhost');

      if (requestUrl.pathname.startsWith('/api/')) {
        await handleApi(req, res, requestUrl.pathname);
        return;
      }

      if (handleBillingPage(res, requestUrl)) {
        return;
      }

      if (handleDownloads(res, requestUrl.pathname)) {
        return;
      }

      handleStatic(res, requestUrl.pathname);
    } catch (error) {
      const statusCode = Number(error.statusCode) || 400;
      sendError(res, statusCode, error.message || 'Request failed.');
    }
  };
}

module.exports = { createRequestHandler };
