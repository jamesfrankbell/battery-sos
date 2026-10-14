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

The existing one-Mac activation rule and pricing are preserved. Empty machine
names can no longer bypass binding. Binding still uses the customer's Mac name;
renaming or duplicate names remain limitations of the established design.

`POST /api/billing/recover` is now support-only and requires the existing
`BILLING_ADMIN_TOKEN` as an Authorization bearer header. Email alone never
authorizes license disclosure. No new token, account or email service is created.
Support must verify ownership before delivering a recovered key. Automated
self-service recovery requires an approved email delivery and verification
workflow; it is not implemented. Do not put admin tokens in URLs or logs.

Passing mocked API and page-script tests does not establish a real purchase,
browser interaction, Mac app activation, or deployed persistence. Those remain
separate acceptance checks after the required authorization and release gates.
