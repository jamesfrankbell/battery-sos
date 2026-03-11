# Battery SOS — Launch Ready Checklist (Public Launch)

## ✅ Completed tonight

- Simplified landing page to clean light theme (less "AI vibe")
- Made primary download CTA obvious and above the fold
- Added direct download routes on the billing server:
  - `/downloads/battery-sos-macos.dmg`
  - `/downloads/battery-sos-macos.dmg.sha256`
- Recomputed checksum file:
  - `mac/dist/battery-sos-macos.dmg.sha256`
- Switched server static site root to `website/` so production `/` is launch page

## 🔒 Needed from James (blocking public launch)

1. DNS records (domain map confirmed)
   - `batterysos.app` → marketing site
   - `pay.batterysos.app` → payment/API host (Render)
   - `download.batterysos.app` → download host (or alias to pay)
2. Stripe live values
   - `STRIPE_SECRET_KEY` (`sk_live_...`)
   - `STRIPE_PRICE_ID` (`price_...`)
   - `STRIPE_WEBHOOK_SECRET` (`whsec_...`) after webhook endpoint is created
3. Legal/support links
   - Confirm final URLs for Support, Privacy, Terms

## Render env vars checklist

Required:
- `HOST=0.0.0.0`
- `PORT=10000`
- `PUBLIC_BASE_URL=https://pay.batterysos.app`
- `STRIPE_SECRET_KEY=sk_live_...`
- `STRIPE_PRICE_ID=price_...`
- `STRIPE_WEBHOOK_SECRET=whsec_...`
- `LICENSE_SECRET=<long random value>`
- `BILLING_ADMIN_TOKEN=<long random value>`

## Stripe webhook config

- Endpoint URL:
  - `https://pay.batterysos.app/api/billing/webhook`
- Event to enable:
  - `checkout.session.completed`

## Final verification flow before launch

1. Open site root and verify CTA download works
2. Checkout flow test (live or controlled prod test)
3. Confirm webhook 200 + event delivered
4. Confirm key issued on success page
5. Confirm app activation with issued key
6. Confirm recovery endpoint returns prior keys by email

## Go/No-Go

**GO only if all are true:**
- Public HTTPS domain active
- Preflight clean (`/api/billing/status` diagnostics ok)
- Webhook delivering `checkout.session.completed`
- End-to-end test successful (purchase → key issue → activation)
