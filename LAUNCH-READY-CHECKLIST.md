# Battery SOS — Launch Ready Checklist (Public Launch)

## Public download (do not restore the archived DMG)

Measured 2026-11-07: `https://batterysos.app/downloads/battery-sos-macos.dmg` and `.sha256` return HTTP 404. `download.batterysos.app` is not a working file host (403 on `/`, timeout on the DMG path).

The archived file is commit `68b7bea5f8ec3ec4a4fa12b7712d0a635b7e77a4`, blob `2720b40037fdb5d1364ab3fb5cf3893b90d0b3d1`, 1,429,342 bytes, sha256 `c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60`. Checksum blob `1396a86dd64c297869100ad2b5c3a46b38ba14ea`. James's mount of that same file: 1.0.0 build `202603110225`, notarized Developer ID JAMES FRANK BELL (9JNKPQCLGG), stapler passed, no new entitlement public key.

Static inspection of those exact bytes on Linux: `dmg2img` 1.6.7 decompressed the UDIF image. The image contains `http://127.0.0.1:8787` beside `BATTERY_SOS_BILLING_URL` and `MonetizationManager`. It does not contain `pay.batterysos.app`. `https://batterysos.app/appcast.xml` is present as the Sparkle feed URL only. The image was not executed. This route therefore withholds the file instead of redirecting to it.

The old appcast item (build `202603061320`, 1,362,061 bytes) has an `edSignature` that verifies that other archive and does not verify these 1,429,342 bytes. The feed no longer has an enclosure. An empty Sparkle 2 channel means no update. `mac/dist/Battery SOS.app` build `202610150505` is unsigned by Gatekeeper and is not a substitute.

The new client source is PR #7. Its default billing URL in source is `https://pay.batterysos.app`, and the build script rejects a binary that contains `http://127.0.0.1:8787`. That candidate has not been compiled here.

## ✅ Completed tonight

- Simplified landing page to clean light theme (less "AI vibe")
- Made primary download CTA obvious and above the fold
- Added direct download routes on the billing server:
  - `/downloads/battery-sos-macos.dmg`
  - `/downloads/battery-sos-macos.dmg.sha256`
- Those routes 404 after the committed DMG was removed. The archived DMG is withheld: its compiled billing default is `http://127.0.0.1:8787`. The stale Sparkle enclosure was removed so its signature is not reused.
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
