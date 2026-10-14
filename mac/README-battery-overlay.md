# Battery Emergency Overlay (macOS)

Shows a pulsing red full-screen overlay at low battery with the message:

> I am going to die if you don't plug me in now!

The overlay stays visible until:
- power is connected, or
- you click the white `x` button in the top-left corner.

## Local review build

The app includes a hardware-independent battery state machine and Sparkle.
Build both Swift source files through the supported bundle script:

```bash
VERSION=1.0.1 BUILD_NUMBER=YYYYMMDDHHMM DIST_DIR=/tmp/battery-sos-YYYYMMDDHHMM mac/scripts/build-app.sh
```

The default warning remains 1%, and sound preferences retain their existing
behavior. `Test SOS` works without a battery, showing unknown battery percentage
rather than inventing a value. Closing a preview ends it. A low-battery warning
can return on the next sample after preview dismissal; this preserves the actual
warning behavior. Sleep ends previews and suppresses alerts until wake, when a
fresh battery sample determines the next state.

## Battery-state simulations

Run these with Apple's Command Line Tools; XCTest is not required:

```bash
xcrun swiftc mac/BatteryAlertState.swift mac/tests/main.swift -o /tmp/battery-sos-state-tests
/tmp/battery-sos-state-tests
```

These tests exercise the same state machine used by the app, without touching
UserDefaults, hardware power settings, sound, UI, or billing. They verify logical
threshold, dismissal, AC, preview, sensor interruption and sleep/wake decisions.
They do not verify IOKit readings, screen layout, Escape/close controls, audio,
physical low battery or actual sleep notifications; test those on the exact app
and intended hardware before accepting the milestone.

## Direct Distribution (.app + .dmg)

Release scripts live in:

- `mac/scripts/build-app.sh`
- `mac/scripts/sign-app.sh`
- `mac/scripts/build-dmg.sh`
- `mac/scripts/notarize.sh`
- `mac/scripts/release.sh`

### 1) Build unsigned app + dmg

```bash
VERSION=1.0.1 BUILD_NUMBER=YYYYMMDDHHMM DIST_DIR=/tmp/battery-sos-YYYYMMDDHHMM mac/scripts/release.sh
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
VERSION=1.0.1 BUILD_NUMBER=YYYYMMDDHHMM DIST_DIR=/tmp/battery-sos-YYYYMMDDHHMM mac/scripts/release.sh
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

## Reproducible local release preparation

Supply an explicit version, build number and fresh `DIST_DIR`; the build refuses
an existing app rather than deleting review artifacts. The supported target is
arm64/macOS 13.0, compiled explicitly rather than only declared in Info.plist.
The recipe is reproducible; signatures, timestamps and DMG compression may
produce different hashes. Record each final artifact instead of assuming byte
identity across builds. The build requires Xcode command-line tools and the
vendored Sparkle 2.9.0 framework. Local preparation additionally uses Node 18+.

Prepare local evidence from the app and final DMG:

```bash
node mac/scripts/prepare-update.js "$DIST_DIR/Battery SOS.app" \
  "$DIST_DIR/battery-sos-macos.dmg" /tmp/battery-sos-new-evidence
node --test mac/scripts/prepare-update.test.js
```

The evidence directory must be new. It contains hashes, byte length, build,
source revision/worktree state and explicit verification results. Missing
signatures or failed/blocked checks return exit status 2, retaining the evidence.
The script mounts the DMG read-only and compares its complete app payload.

After final stapling, obtain a Sparkle signature through the existing approved
signing workflow and supply it as the fourth argument. The script verifies it
against the app's embedded public key before staging `appcast.xml`, with the
actual build and length. It never writes the public website feed or uploads.
Staged metadata is not release approval: every required check must pass and
James must approve publication. Any mutation to the DMG invalidates its hash
and signature; prepare a new evidence directory after changes.

## Mode audio feedback round — October 4, 2026

All sounds remain original procedural synthesis. Default Warning uses a paired
warning; Vitals uses a clean monitor pip and sustained flatline driven by ECG
callbacks. Self-Destruct uses terminal chatter, ticks synchronized to the visible
five-second countdown and a short burnout. Reactor uses an industrial siren and
machinery rumble; Starship uses a bridge distress chord and propulsion hum;
Matrix uses digital packets and bit-like glitches. No film/game recordings were
used. The mixer remains 0.9 and cue peaks stay within prior amplitude limits.

Playback uses cancellable player buffers, with no delayed sound callbacks.
Mute cancels the queue, unmute resumes a requested loop, and dismiss stops and
clears playback. No old one-shot is replayed when unmuting.

```bash
xcrun swiftc -O -parse-as-library mac/AlertAudio.swift mac/AlertAudioPlayer.swift mac/tests/audio-main.swift -o /tmp/battery-sos-audio-tests
/tmp/battery-sos-audio-tests
```

The actual AVAudioEngine test uses offline rendering without speakers. Restricted
sandboxes may lack access to its audio components. Passing PCM/engine tests does
not establish subjective sound quality or actual speaker/device behavior; James
must hear the exact Review build before accepting this feedback round.
