'use strict';

const DEFAULT_EMAIL_FROM = 'Battery SOS <support@batterysos.app>';

// BILLING_EMAIL_PROVIDER=console keeps the message in the dev outbox and logs
// only the recipient and subject. BILLING_EMAIL_PROVIDER=http posts
// { from, to, subject, text, html } to BILLING_EMAIL_HTTP_URL.
// Resend accepts this body at https://api.resend.com/emails with a Bearer token.
function createEmailSender({ provider, fetchImpl, httpUrl, httpToken, from, onConsole } = {}) {
  const name = String(provider || 'console').trim().toLowerCase();
  const fetchFn = fetchImpl || global.fetch;
  const senderFrom = String(from || process.env.BILLING_EMAIL_FROM || '').trim() || DEFAULT_EMAIL_FROM;

  return {
    provider: name,
    async send(message) {
      if (name === 'console') {
        if (typeof onConsole === 'function') onConsole({ ...message, provider: 'console' });
        console.info(`billing-email provider=console to=${message.to} subject=${message.subject}`);
        return { provider: 'console' };
      }

      if (name === 'http') {
        if (!httpUrl) {
          const error = new Error('BILLING_EMAIL_HTTP_URL is not configured.');
          error.statusCode = 503;
          throw error;
        }
        const headers = { 'content-type': 'application/json' };
        if (httpToken) headers.authorization = `Bearer ${httpToken}`;
        const response = await fetchFn(httpUrl, {
          method: 'POST',
          headers,
          body: JSON.stringify({
            from: message.from || senderFrom,
            to: message.to,
            subject: message.subject,
            text: message.text,
            html: message.html || '',
          }),
        });
        if (!response.ok) {
          const error = new Error('Email provider rejected the message.');
          error.statusCode = 502;
          throw error;
        }
        return { provider: 'http' };
      }

      const error = new Error('BILLING_EMAIL_PROVIDER is not supported.');
      error.statusCode = 500;
      throw error;
    },
  };
}

module.exports = { createEmailSender, DEFAULT_EMAIL_FROM };
