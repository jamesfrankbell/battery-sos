'use strict';

const crypto = require('node:crypto');

// Ed25519 SPKI is a fixed 12-byte header plus the 32-byte raw public key.
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

// Embedded in the Mac app. The matching private key lives only in
// ENTITLEMENT_SIGNING_PRIVATE_KEY on the server.
const EMBEDDED_APP_PUBLIC_KEY_BASE64 = 'gTZwp8xK+B6IlAst6SlVbEWZTpGKneMuCjImIlipJuM=';

function normalizePem(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  return text.includes('\\n') ? text.replace(/\\n/g, '\n') : text;
}

function privateKeyFromEnv(env = process.env) {
  const raw = normalizePem(env.ENTITLEMENT_SIGNING_PRIVATE_KEY);
  if (!raw) return null;
  try {
    const key = crypto.createPrivateKey(raw);
    if (key.asymmetricKeyType !== 'ed25519') return null;
    return key;
  } catch {
    return null;
  }
}

function rawPublicKeyFromPrivate(privateKey) {
  const der = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  const prefix = der.subarray(0, SPKI_PREFIX.length);
  if (der.length !== SPKI_PREFIX.length + 32 || !prefix.equals(SPKI_PREFIX)) {
    throw new Error('Entitlement public key is not Ed25519 SPKI.');
  }
  return der.subarray(SPKI_PREFIX.length);
}

function publicKeyBase64FromEnv(env = process.env) {
  const privateKey = privateKeyFromEnv(env);
  if (!privateKey) return '';
  return rawPublicKeyFromPrivate(privateKey).toString('base64');
}

function canonicalEntitlementPayload(licenseId, machineHash, issuedAt) {
  return `v1\n${licenseId}\n${machineHash}\n${issuedAt}`;
}

function signEntitlement({ licenseId, machineHash, issuedAt, env = process.env } = {}) {
  const privateKey = privateKeyFromEnv(env);
  if (!privateKey) {
    const error = new Error('Entitlement signing key is not configured.');
    error.statusCode = 500;
    throw error;
  }
  const payload = Buffer.from(canonicalEntitlementPayload(licenseId, machineHash, issuedAt));
  const signature = crypto.sign(null, payload, privateKey);
  return {
    licenseId,
    machineHash,
    issuedAt,
    signature: signature.toString('base64'),
  };
}

function verifyEntitlement(entitlement, publicKeyBase64) {
  if (!entitlement || typeof entitlement !== 'object') return false;
  const { licenseId, machineHash, issuedAt, signature } = entitlement;
  if (!licenseId || !machineHash || !issuedAt || !signature) return false;

  const signatureBytes = Buffer.from(String(signature), 'base64');
  const rawPublic = Buffer.from(String(publicKeyBase64 || ''), 'base64');
  if (rawPublic.length !== 32 || signatureBytes.length !== 64) return false;

  let publicKey;
  try {
    publicKey = crypto.createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, rawPublic]),
      type: 'spki',
      format: 'der',
    });
  } catch {
    return false;
  }

  try {
    const payload = Buffer.from(canonicalEntitlementPayload(licenseId, machineHash, issuedAt));
    return crypto.verify(null, payload, publicKey, signatureBytes);
  } catch {
    return false;
  }
}

module.exports = {
  EMBEDDED_APP_PUBLIC_KEY_BASE64,
  canonicalEntitlementPayload,
  privateKeyFromEnv,
  publicKeyBase64FromEnv,
  signEntitlement,
  verifyEntitlement,
};
