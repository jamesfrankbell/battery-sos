# Battery SOS Public Deploy (Cloudflare domain + Render backend)

## Architecture (recommended)
- Host app backend on **Render** (easy Node hosting)
- Use your **Cloudflare domain** as the public URL (CNAME to Render)
- Stripe webhook points to your Cloudflare hostname

Example:
- Render service URL: `https://battery-sos-billing.onrender.com`
- Public URL: `https://billing.yourdomain.com`

## 1) Deploy backend to Render
1. Push this repo to GitHub (if not already).
2. In Render, create **New + Blueprint** and select repo.
3. Render will detect `apps/battery-sos/render.yaml`.
4. Set secret env vars in Render dashboard:
   - `STRIPE_SECRET_KEY`
   - `STRIPE_PRICE_ID`
   - `STRIPE_WEBHOOK_SECRET`
   - `PUBLIC_BASE_URL` (set to your Cloudflare hostname, e.g. `https://billing.yourdomain.com`)
   - `LICENSE_SECRET` (long random string)
   - `BILLING_ADMIN_TOKEN` (long random string)

## 2) Point Cloudflare DNS to Render
In Cloudflare DNS for your domain:
- Type: `CNAME`
- Name: `billing` (or whatever subdomain you want)
- Target: `<your-render-service>.onrender.com`
- Proxy status: **Proxied** (orange cloud)

## 3) Configure Stripe webhook
In Stripe Dashboard (live mode):
- Endpoint URL: `https://billing.yourdomain.com/api/billing/webhook`
- Event: `checkout.session.completed`

## 4) Verify
- `https://billing.yourdomain.com/api/billing/status` should return JSON with `configured: true`.
- Create checkout session from app and confirm redirect + license issuance.

## 5) macOS app points to public billing URL
Set this when building/distributing app:
- `BATTERY_SOS_BILLING_URL=https://billing.yourdomain.com`

## Notes
- Keep Stripe/API secrets only in Render env vars.
- Do not put secrets in Slack/messages or in git.
- Rotate keys immediately if exposed.
