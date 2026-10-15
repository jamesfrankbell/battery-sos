# Battery SOS

Battery SOS is a macOS menu-bar app that displays a full-screen warning when a
MacBook battery reaches the selected percentage. Default Warning is free; the
five additional themes require the existing $1 Pro license. The warning can be
dismissed with Escape or its close button and ends when AC power is connected.

The default warning threshold remains 1%, configurable from 1% to 10%. Settings
retain the selected theme, threshold and mute preference. Test SOS can preview a
theme on a desktop without a battery. A saved Pro theme falls back to Default
Warning while locked and remains available after license activation.

## Local build and tests

Use Apple's Command Line Tools, Node 18+ and the vendored Sparkle 2.9.0 framework:

```bash
VERSION=1.0.1 BUILD_NUMBER=YYYYMMDDHHMM DIST_DIR=/tmp/battery-sos-YYYYMMDDHHMM mac/scripts/build-app.sh
node --test server/billing.test.js mac/scripts/prepare-update.test.js mac/scripts/app-icon.test.js mac/scripts/menu-bar-icon.test.js
xcrun swiftc mac/BatteryAlertState.swift mac/tests/main.swift -o /tmp/battery-sos-state-tests
/tmp/battery-sos-state-tests
xcrun swiftc -parse-as-library mac/AppPreferences.swift mac/tests/settings-main.swift -o /tmp/battery-sos-settings-tests
/tmp/battery-sos-settings-tests
xcrun swiftc -parse-as-library mac/AlertAudio.swift mac/AlertAudioPlayer.swift mac/tests/audio-main.swift -o /tmp/battery-sos-audio-tests
/tmp/battery-sos-audio-tests
xcrun swiftc -parse-as-library mac/BatteryAlertState.swift mac/ProBatteryFeatures.swift mac/tests/pro-main.swift -o /tmp/battery-sos-pro-tests
/tmp/battery-sos-pro-tests
```

On Linux, run the Node suites only. The Swift commands need Apple's Command Line Tools.

Build identifiers and a fresh output directory are required to preserve prior
review artifacts. Source provenance is embedded before signing. The build target
is arm64/macOS 13; compilation does not establish runtime compatibility on macOS
13 or Intel. The default signature is ad-hoc for local review, not distribution.

Tests use isolated stores and mocked payments; they do not charge a card, deploy,
or exercise real battery hardware. The settings test uses a unique temporary
UserDefaults suite and removes it afterward. It also verifies theme restoration
in a fresh process. Native screen, audio, login and hardware behavior require
separate exact-build testing.

## Components

- `mac/BatteryEmergencyOverlay.swift`: AppKit menus, overlays, audio and billing UI.
- `mac/WelcomeWindow.swift`: first-run and reopen welcome cards.
- `mac/AppIcon.icns`: bundle icon, installed as `CFBundleIconFile`.
- `mac/BatteryAlertState.swift`: hardware-independent alert decisions.
- `mac/AppPreferences.swift`: theme persistence, access labels and billing response handling.
- `mac/scripts/`: local bundle/DMG packaging and guarded release-metadata preparation.
- `server/billing.js`: Stripe checkout, paid license issuance, verified email recovery, device transfer, and single-process persistence.
- `server/email-sender.js`: pluggable recovery email delivery (`console` or `http`).
- `server/router.js`: billing API, marketing site and download routes.
- `website/`: marketing site and public update feed.

The repository also retains legacy LocalFlow task/document modules. Those modules
are separate from the Battery SOS app experience; do not edit their data while
testing billing. Production billing requires its configured persistent data
directory. Never reset corrupt license records or include secrets in evidence.

## Release readiness

See [mac build/release instructions](mac/README-battery-overlay.md),
[billing verification](server/README-billing.md),
[the 1.0.1 release runbook](RELEASE-1.0.1.md) and the
[current release acceptance checklist](LAUNCH-READY-CHECKLIST.md).

Public site: https://batterysos.app. Support, Privacy and Terms destinations remain
unconfirmed; this repository does not invent contact addresses or legal terms.
Local changes are not deployed, and the public appcast remains unchanged until
the final artifact, signatures and explicit publication approval are available.
