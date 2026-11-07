'use strict';

// In-memory and per process. A second instance, or a restart, starts empty.
const buckets = new Map();
const overrides = new Map();

const DEFAULTS = {
  '/api/billing/verify-license': { limit: 20, windowMs: 10 * 60 * 1000 },
  '/api/billing/recover': { limit: 5, windowMs: 15 * 60 * 1000 },
  '/api/billing/create-checkout-session': { limit: 10, windowMs: 10 * 60 * 1000 },
};

function limitConfig(route) {
  return overrides.get(route) || DEFAULTS[route] || null;
}

function resetRateLimitsForTests() {
  buckets.clear();
  overrides.clear();
}

function setRateLimitForTests(route, config) {
  overrides.set(route, config);
}

function consumeRateLimit(route, ip, now = Date.now()) {
  const config = limitConfig(route);
  if (!config) return { limited: false };

  const key = `${route}|${ip || 'unknown'}`;
  for (const [bucketKey, entry] of buckets) {
    if (entry.resetAt <= now) buckets.delete(bucketKey);
  }

  const current = buckets.get(key);
  if (!current) {
    buckets.set(key, { count: 1, resetAt: now + config.windowMs });
    return { limited: false, remaining: config.limit - 1 };
  }

  if (current.count >= config.limit) {
    return {
      limited: true,
      retryAfterSeconds: Math.max(1, Math.ceil((current.resetAt - now) / 1000)),
    };
  }

  current.count += 1;
  return { limited: false, remaining: config.limit - current.count };
}

module.exports = {
  consumeRateLimit,
  resetRateLimitsForTests,
  setRateLimitForTests,
};
