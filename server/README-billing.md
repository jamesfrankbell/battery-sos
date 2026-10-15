# Local billing verification and recovery

Run `node --test server/billing.test.js` from the repository root. Tests use a
temporary data directory, fixture credentials and mocked Stripe requests. They
never load `.env`, contact Stripe, charge a card, or read production license data.
The unrelated LocalFlow store is stubbed during recovery-route tests.

License writes use a private temporary file, flush its bytes, and atomically
rename it into place. In-memory state changes only after a successful save.
Malformed, empty or inconsistent existing stores fail startup and preserve the
original bytes. Stop the service and restore a verified backup; never delete or
reset the file to make startup succeed. A persistent volume remains required.
This is the existing single-process design, not a multi-writer database.

Stripe webhook signatures must be well formed and within five minutes of server
time. Both completed checkout and delayed-payment success events can issue a
license, only for paid sessions. Session-based issuance remains idempotent.
Success pages poll for up to one minute, then instruct the customer to refresh.

The $1 one-time price and Free/Pro theme split are unchanged. A license is active on one Mac at a time. Empty machine names still cannot bypass the legacy path.

New clients send `deviceId`, the SHA-256 hex of the Mac's IOPlatformUUID. The raw UUID is not stored or sent. The first time a 1.0.1 app presents that hash with the same Mac name already stored, the server records the hash and does not count a transfer. A renamed Mac does not match and cannot take over a name-bound license. After a hash is stored, a name-only client is rejected.

`POST /api/billing/deactivate` clears the binding only when the key and the current device hash match (a legacy name binding also requires the current Mac name). Activating that same device again does not use a transfer. Activating a different device uses one transfer. The limit is 3 transfers in a rolling year. A fourth different device is refused until an earlier transfer is a year old; the previous device can still be activated.

`POST /api/billing/recover` remains support-only and requires the existing `BILLING_ADMIN_TOKEN` as an Authorization bearer header. Email alone never authorizes license disclosure. Do not put admin tokens in URLs or logs.

Self-service recovery is separate:

- `POST /api/billing/recover/request` with `{ "email": "..." }`, or the form at `GET /billing/recover`.
- The response is the same whether or not that email has a license. It never contains a key.
- If a license exists, the server emails a 15-minute, one-time link and an 8-character code. The message does not contain the key.
- `GET /billing/recover?token=...` or `POST /api/billing/recover/confirm` with the email and code reveals the existing key. It does not mint a new key and does not deactivate a Mac.
- Requests are limited to 5 per email and 20 per IP each hour. Confirmations are limited to 8 per email each hour. The limit response is the same for known and unknown emails.
- `BILLING_EMAIL_PROVIDER=console` (the default) stores the message in the process outbox and logs only the recipient and subject. Use it for local development and tests. Do not use it in production: the customer will not receive the message.
- `BILLING_EMAIL_PROVIDER=http` posts `{ to, subject, text, html }` to `BILLING_EMAIL_HTTP_URL`. Set `BILLING_EMAIL_HTTP_TOKEN` to send `Authorization: Bearer ...`. A delivery failure still returns the same accepted response and does not leave a usable link.

Set the http provider before any deployment that should actually deliver recovery email. This repository does not deploy that change.

Passing mocked API and page-script tests does not establish a real purchase,
browser interaction, Mac app activation, or deployed persistence. Those remain
separate acceptance checks after the required authorization and release gates.
