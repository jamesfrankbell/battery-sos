# Battery Emergency Overlay (macOS)

Shows a pulsing red full-screen overlay at low battery with the message:

> I am going to die if you don't plug me in now!

The overlay stays visible until:
- power is connected, or
- you click the white `x` button in the top-left corner.

## Run

From the repo root:

```bash
swift mac/BatteryEmergencyOverlay.swift
```

## Optional: build a binary

```bash
mkdir -p "$HOME/Library/Application Support/BatterySOS"
swiftc mac/BatteryEmergencyOverlay.swift -o "$HOME/Library/Application Support/BatterySOS/battery-sos"
"$HOME/Library/Application Support/BatterySOS/battery-sos"
```

## Direct Distribution (.app + .dmg)

Release scripts live in:

- `mac/scripts/build-app.sh`
- `mac/scripts/sign-app.sh`
- `mac/scripts/build-dmg.sh`
- `mac/scripts/notarize.sh`
- `mac/scripts/release.sh`

### 1) Build unsigned app + dmg

```bash
mac/scripts/release.sh
```

Artifacts are written to:

- `mac/dist/Battery SOS.app`
- `mac/dist/battery-sos-macos.dmg`

### 2) Signed + notarized release

Set your Developer ID Application identity:

```bash
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
```

Create a notarytool profile once:

```bash
xcrun notarytool store-credentials "BatterySOSNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then run:

```bash
export NOTARY_PROFILE="BatterySOSNotary"
mac/scripts/release.sh
```

This will:

1. Build `Battery SOS.app`
2. Sign app bundle
3. Build `.dmg`
4. Submit `.dmg` for notarization
5. Staple notarization ticket

## Stripe Billing Backend (Pro Unlock)

This repo now includes a minimal Stripe-backed licensing flow:

- `POST /api/billing/create-checkout-session`
- `POST /api/billing/webhook`
- `POST /api/billing/verify-license`
- `GET /billing/success`
- `GET /billing/cancel`

Set these env vars before starting the server:

```bash
export STRIPE_SECRET_KEY="sk_test_..."
export STRIPE_PRICE_ID="price_..."
export STRIPE_WEBHOOK_SECRET="whsec_..."
export PUBLIC_BASE_URL="https://yourdomain.com"
export LICENSE_SECRET="replace-with-long-random-secret"
```

Run server:

```bash
npm start
```

App-side billing URL (for checkout + key verification):

```bash
export BATTERY_SOS_BILLING_URL="https://yourdomain.com"
```

## Notes

- A `Battery SOS` menu bar item is added so you can quit the tool.
- The menu also includes `Test SOS` so you can trigger the flashing overlay on demand.
- The menu includes `Settings -> Warning Percentage` where you can choose `1%` through `10%`.
- The menu includes `Settings -> Mute Sound Effects` with a checkmark toggle.
- The menu includes `Settings -> Start at Login` (works when running as installed `.app` bundle).
- Monetization behavior:
  - `Default Warning` is free.
  - All other modes are Pro.
  - `Settings -> Unlock Pro ($1)...` opens Stripe checkout.
  - `Settings -> Enter License Key...` activates Pro after purchase.
- The `Mode` submenu includes: `Default Warning`, `Vitals Monitor`, `Self-Destruct`, `Reactor Meltdown`, `Starship Life Support`, and `Matrix`.
- Every mode has sound effects.
- In `Vitals Monitor`, heartbeat pacing accelerates and then transitions into a continuous flatline tone until the alert ends.
- `Self-Destruct`, `Reactor Meltdown`, `Starship Life Support`, and `Matrix` each use distinct synthesized audio loops.
- This utility is independent of the Node app in this repo.
