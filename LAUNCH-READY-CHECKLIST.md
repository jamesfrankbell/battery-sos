# Battery SOS — Launch Ready Checklist (Public Launch)

## Public download (not restored until this change is deployed)

Measured 2026-11-07: `https://batterysos.app/downloads/battery-sos-macos.dmg` and `.sha256` return HTTP 404. `download.batterysos.app` is not a working file host (403 on `/`, timeout on the DMG path).

The last file those routes served is still in git history and on GitHub at commit `68b7bea5f8ec3ec4a4fa12b7712d0a635b7e77a4`:

- blob `2720b40037fdb5d1364ab3fb5cf3893b90d0b3d1`
- 1,429,342 bytes
- sha256 `c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60`
- checksum blob `1396a86dd64c297869100ad2b5c3a46b38ba14ea`
- James's read-only check of the same file: app inside is 1.0.0 build `202603110225`, `com.jamesbell.battery-sos`, macOS 13, arm64; strict codesign passed; Gatekeeper accepted notarized Developer ID JAMES FRANK BELL (9JNKPQCLGG); stapler validate passed
- The new entitlement public key is not in that app. It is the old licensing client. Do not claim it activates against the current server until that is tested on a Mac. The October 1 recovery note said this public DMG's executable still calls `http://127.0.0.1:8787`.
- `mac/dist/Battery SOS.app` at 1.0.1 build `202610150505` has no Team ID and Gatekeeper rejects it. Do not ship that app.

The live appcast item is a different archive: 1.0.0 build `202603061320`, 1,362,061 bytes. Its `edSignature` verifies that older file and does not verify the 1,429,342-byte DMG. This change removes that item instead of reusing the signature. Sparkle updates stay off until James runs `sign_update` on this exact DMG and supplies the resulting signature.

`https://raw.githubusercontent.com/jamesfrankbell/battery-sos/68b7bea5f8ec3ec4a4fa12b7712d0a635b7e77a4/mac/dist/battery-sos-macos.dmg` returned HTTP 200, content-length 1429342, and the sha256 above. The bytes matched the git blob. No new binary is added to the tree. The public route stays 404 until this redirect is deployed.

## ✅ Completed tonight

- Simplified landing page to clean light theme (less "AI vibe")
- Made primary download CTA obvious and above the fold
- Added direct download routes on the billing server:
  - `/downloads/battery-sos-macos.dmg`
  - `/downloads/battery-sos-macos.dmg.sha256`
- Those routes 404 after the committed DMG was removed. The repair redirects them to the last DMG that was on `main` (`68b7bea`, 1,429,342 bytes, sha256 `c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60`). That is not a new build. The stale Sparkle item was removed so its signature is not reused for these bytes.
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
