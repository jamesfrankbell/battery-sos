'use strict';

// Render (via Cloudflare) is the only path to the process in production.
// Forwarded headers are honored only when the TCP peer is a trusted proxy.
// A client that connects directly cannot pick its own rate-limit bucket.
//
// When the peer is trusted:
// - CF-Connecting-IP is preferred. Cloudflare overwrites that header, so a
//   visitor cannot supply it on traffic that actually passed through the edge.
// - Otherwise walk X-Forwarded-For from the right and skip trusted hops.
//   Render appends to X-Forwarded-For, so the leftmost value is attacker
//   controlled. Using the leftmost address would let a caller mint a new bucket
//   per request. If every forwarded hop is a trusted proxy, fall back to the
//   socket address rather than a client-chosen value.
//
// Limit: this trusts the edge. CF-Connecting-IP is not authenticated. It is
// safe only while the process is unreachable except through that proxy. Set
// TRUSTED_PROXY_IPS if the immediate peer is a public address.

function normalizeIp(value) {
  let ip = String(value || '').trim().toLowerCase();
  if (!ip) return '';
  if (ip.startsWith('"') && ip.endsWith('"')) ip = ip.slice(1, -1);
  if (ip.startsWith('[') && ip.includes(']')) ip = ip.slice(1, ip.indexOf(']'));
  if (ip.startsWith('::ffff:')) ip = ip.slice('::ffff:'.length);
  const zone = ip.indexOf('%');
  if (zone !== -1) ip = ip.slice(0, zone);
  return ip;
}

function isIp(value) {
  const ip = normalizeIp(value);
  if (!ip) return false;
  const ipv4 = ip.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) return ipv4.slice(1).every((part) => Number(part) <= 255);
  return ip.includes(':') && /^[0-9a-f:]+$/.test(ip) && ip.length <= 45;
}

function isTrustedProxyAddress(value) {
  const ip = normalizeIp(value);
  if (!ip) return false;
  if (ip === '::1') return true;
  if (ip.startsWith('fc') || ip.startsWith('fd') || ip.startsWith('fe80:')) return true;
  const ipv4 = ip.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!ipv4) return false;
  const a = Number(ipv4[1]);
  const b = Number(ipv4[2]);
  if (a === 10 || a === 127) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  return false;
}

function extraTrustedProxies(env = process.env) {
  return String(env.TRUSTED_PROXY_IPS || '')
    .split(',')
    .map((item) => normalizeIp(item))
    .filter(Boolean);
}

function isTrustedPeer(ip, env = process.env) {
  const normalized = normalizeIp(ip);
  if (!normalized) return false;
  if (isTrustedProxyAddress(normalized)) return true;
  return extraTrustedProxies(env).includes(normalized);
}

function headerValue(req, name) {
  const raw = req.headers ? req.headers[name] : '';
  if (Array.isArray(raw)) return raw.length === 1 ? String(raw[0]) : '';
  return raw == null ? '' : String(raw);
}

function forwardedChain(req) {
  return headerValue(req, 'x-forwarded-for')
    .split(',')
    .map((item) => normalizeIp(item))
    .filter(isIp);
}

function clientAddress(req, env = process.env) {
  const remote = normalizeIp(req.socket?.remoteAddress || req.remoteAddress || '');
  if (!isTrustedPeer(remote, env)) return remote || 'unknown';

  const cloudflare = normalizeIp(headerValue(req, 'cf-connecting-ip'));
  if (isIp(cloudflare) && !cloudflare.includes(',')) return cloudflare;

  const chain = forwardedChain(req);
  for (let index = chain.length - 1; index >= 0; index -= 1) {
    if (!isTrustedPeer(chain[index], env)) return chain[index];
  }
  return remote || 'unknown';
}

module.exports = {
  clientAddress,
  isTrustedPeer,
  normalizeIp,
};
