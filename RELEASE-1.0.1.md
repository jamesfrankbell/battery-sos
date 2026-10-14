# Battery SOS 1.0.1 release runbook

This is the manual sequence for James's Mac. It does not notarize, upload, deploy, or charge a card by itself. Do not start it until the reviewed source is the commit you intend to ship. Do not publish over the public 1.0.0 download or `website/appcast.xml` until the smoke tests below have a plan to roll back.

The installed public app is 1.0.0, build `202603110225`. Its billing default was `http://127.0.0.1:8787`. The 1.0.1 app must contain `https://pay.batterysos.app` and must not contain the localhost URL. The public appcast still describes build `202603061320`, which is older than the installed app, so it cannot deliver this update until it is replaced with the final stapled file's length and Sparkle signature.

Price stays $1, charged once. Default Warning stays free. The other five themes stay Pro. The emergency threshold still defaults to 1%.

## 0. Before touching the keychain

1. `git status` must be clean, on the reviewed 1.0.1 commit.
2. Record `git rev-parse HEAD` and `git status --short`. The build embeds that revision.
3. Xcode Command Line Tools, Node 18+, and `third_party/sparkle-2.9.0/Sparkle.framework` are present.
4. The Developer ID Application identity is already in the login keychain. Example name: `Developer ID Application: Your Name (TEAMID)`. Do not create a new certificate in this runbook.
5. The Sparkle EdDSA private key that matches the app's embedded public key is already in the keychain. The public key is `TzMjfdFQ2JZ6UhrkUQB+FUpZ8pWAhKtrTk74ytAx3To=`. `sign_update` prompts for that keychain item. Do not print or copy the private key.
6. A notarytool keychain profile named `BatterySOSNotary` already exists. If it does not, create it once with an app-specific password and do not store that password in the repo:

```bash
xcrun notarytool store-credentials "BatterySOSNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

7. Pick a UTC build number that is greater than both `202603110225` and `202603061320`:

```bash
export VERSION=1.0.1
export BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
export DIST_DIR="/tmp/battery-sos-${BUILD_NUMBER}"
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="BatterySOSNotary"
test "$BUILD_NUMBER" -gt 202603110225
```

`DIST_DIR` must be a new directory. The build refuses to overwrite an existing app.

## 1. Build

From the repository root:

```bash
mac/scripts/build-app.sh
```

This compiles arm64 / macOS 13, embeds `BuildProvenance.plist`, and ad-hoc signs the bundle so it can be inspected. It fails if the binary is missing `https://pay.batterysos.app` or still contains `http://127.0.0.1:8787`.

Confirm the version:

```bash
/usr/bin/defaults read "$DIST_DIR/Battery SOS.app/Contents/Info" CFBundleShortVersionString
/usr/bin/defaults read "$DIST_DIR/Battery SOS.app/Contents/Info" CFBundleVersion
```

Expected: `1.0.1` and the `BUILD_NUMBER` you exported.

## 2. Developer ID sign

Ad-hoc is not the distribution signature. Sign the app with the existing Developer ID, runtime, and a secure timestamp:

```bash
mac/scripts/sign-app.sh "$DIST_DIR/Battery SOS.app"
```

`sign-app.sh` runs `codesign --verify --deep --strict --verbose=2`. `spctl` may still complain before notarization; that is expected.

Build and sign the DMG only after the app signature verifies:

```bash
mac/scripts/build-dmg.sh "$DIST_DIR/Battery SOS.app"
```

With `DEVELOPER_ID_APP` set, `build-dmg.sh` signs `battery-sos-macos.dmg` with a timestamp and verifies that signature. The DMG path is `$DIST_DIR/battery-sos-macos.dmg`.

## 3. Notarize

```bash
xcrun notarytool submit "$DIST_DIR/battery-sos-macos.dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
```

Wait for `status: Accepted`. If it is not accepted, stop. Run `xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"` and fix the signed artifact. Do not staple a rejected upload.

`mac/scripts/notarize.sh` submits and staples in one step. Use it only when you want both. The steps below keep them separate so the staple is checked on its own.

## 4. Staple

```bash
xcrun stapler staple "$DIST_DIR/battery-sos-macos.dmg"
xcrun stapler validate "$DIST_DIR/battery-sos-macos.dmg"
codesign --verify --verbose=2 "$DIST_DIR/battery-sos-macos.dmg"
```

Stapling changes the DMG bytes. Any checksum or Sparkle signature taken before this step is invalid. Do not run `codesign --force` after stapling; replacing the signature can drop the ticket. If `stapler validate` fails, stop and staple again. Do not publish that file.

## 5. Checksum

Calculate the SHA256 of the stapled DMG only:

```bash
shasum -a 256 "$DIST_DIR/battery-sos-macos.dmg"
```

Record the hex and the byte length (`stat -f%z` on macOS). You will compare both with the evidence directory in the next steps. Do not reuse a hash from build `202610010055` or from the public 1.0.0 file.

## 6. Sparkle sign_update

Run Sparkle's tool on the stapled DMG, after the checksum command, so you sign the same bytes you just hashed:

```bash
"$PWD/third_party/sparkle-2.9.0/bin/sign_update" "$DIST_DIR/battery-sos-macos.dmg"
```

Approve the keychain prompt for the existing EdDSA key. Copy the `sparkle:edSignature` value. Also copy the `length` it prints and confirm it matches `stat -f%z`. If you previously ran `sign_update` on the unstapled DMG, throw that signature away and use only this one.

The recovery on October 1 ran `sign_update` before the final staple. That signature cannot be reused.

## 7. prepare-update.js

Use a new evidence directory. Pass the signature from step 6 as the fourth argument:

```bash
node mac/scripts/prepare-update.js \
  "$DIST_DIR/Battery SOS.app" \
  "$DIST_DIR/battery-sos-macos.dmg" \
  "/tmp/battery-sos-${BUILD_NUMBER}-evidence" \
  "PASTE_THE_ED_SIGNATURE"
```

Exit status `0` means every check passed, including Developer ID, secure timestamp, staple, arm64, deployment target, billing URL, read-only DMG payload match, and the Sparkle signature against `SUPublicEDKey`. Exit status `2` means evidence was written and at least one check did not pass. Do not upload that evidence.

The directory contains:

- `release-manifest.json` — version, build, SHA256, byte length, source revision, and each check
- `battery-sos-macos.dmg.sha256` — `SHA256  battery-sos-macos.dmg`
- `appcast.xml` — written only after the signature verifies

Confirm the staged appcast contains this build number, this byte length, and this signature, and the enclosure URL `https://batterysos.app/downloads/battery-sos-macos.dmg`. It must not contain `202603061320` or `1362061`.

```bash
node --test mac/scripts/prepare-update.test.js
shasum -a 256 -c "/tmp/battery-sos-${BUILD_NUMBER}-evidence/battery-sos-macos.dmg.sha256"
```

Run the checksum check from `$DIST_DIR`, or compare the hex to step 5 by hand. `shasum -c` looks for `battery-sos-macos.dmg` beside the checksum file only if you point it at a copy that sits next to the DMG. The reliable comparison is: the hex in the evidence file equals the hex from step 5, and the length in `appcast.xml` equals the stapled file length.

## 8. Appcast

The file to publish is `/tmp/battery-sos-${BUILD_NUMBER}-evidence/appcast.xml`. Do not edit it by hand. If the DMG changes after this, delete the evidence directory and repeat from the checksum.

Leave `website/appcast.xml` in git unchanged until step 9 is explicitly approved.

## 9. Upload

Do this only after you accept the evidence directory and approve publication. Replacing the live files is a deploy. This runbook does not do it for you.

The running server reads:

- `mac/dist/battery-sos-macos.dmg`
- `mac/dist/battery-sos-macos.dmg.sha256`
- `website/appcast.xml`

Copy the stapled DMG, the evidence checksum, and the evidence appcast over those three paths. Commit only those artifacts, on a release commit, with the build number in the message. Push and deploy that commit to the existing Render service only when you mean to publish. Do not point the service at a different disk, and do not delete or rewrite `/var/data/battery-sos/billing-data.json`.

Before the deploy, if this server revision is included, set:

- `BILLING_EMAIL_PROVIDER=http`
- `BILLING_EMAIL_HTTP_URL` to the recovery-mail endpoint you control
- `BILLING_EMAIL_HTTP_TOKEN` if that endpoint expects a bearer token

Until those are set, a deployed server uses the console sender: it logs the recipient and subject and does not deliver the link. Admin recovery with `BILLING_ADMIN_TOKEN` keeps working either way. Do not put the admin token or the email token in git, the appcast, or this checklist.

Immediately after deploy:

```bash
curl -fsS https://pay.batterysos.app/api/billing/status
curl -fsS -o /tmp/live-battery-sos.dmg https://batterysos.app/downloads/battery-sos-macos.dmg
curl -fsS https://batterysos.app/downloads/battery-sos-macos.dmg.sha256
curl -fsS https://batterysos.app/appcast.xml
shasum -a 256 /tmp/live-battery-sos.dmg
```

The live SHA256, byte length, appcast build, and `sparkle:edSignature` must match the evidence directory. `strings` on a mounted copy of the app must show `https://pay.batterysos.app` and must not show `http://127.0.0.1:8787`.

If any of that fails, put the previous DMG, checksum, and appcast back before announcing the release. The previous appcast length is `1362061` and its signature is `blmOkxzEdzWDugJGEfDUBTLLxEtTvginKh5sonZeDZnFQuZoU9EgonPDidBdZkn4okWR6tSKmwoeqHIB1SOfCg==`. That feed is older than the installed 1.0.0 build, so restoring it stops the bad update but does not by itself offer a working update.

## 10. Smoke tests

Use the exact stapled DMG customers will download. A local ad-hoc build does not count.

### Install

1. On a Mac that does not already have Battery SOS, open the DMG and drag Battery SOS to Applications.
2. Launch it. Confirm the menu-bar icon, that Gatekeeper does not warn, and that the first-run alert explains the emergency threshold versus Pro early heads-up, snooze's 1% override, and that charge reminders are reminders only.
3. Quit and launch again. The alert does not return. Settings → How Warnings Work… still shows it.
4. Set the warning percentage to something other than 1%, turn Calm Alerts on, and set one theme volume below 100%. Quit and relaunch. Those settings are still there.
5. Test SOS. With Calm on, the full-screen warning stays steady and the sound is quieter than the same theme at 100% with Calm off. Escape or the close button ends the preview. Mute stops the sound.

### Update from 1.0.0

1. On another Mac, install the current public 1.0.0 DMG (build `202603110225`) if that Mac is not already on it.
2. Set a non-default warning percentage. If a real license is already activated, leave it in place.
3. After step 9 is live, choose Check for Updates… and install 1.0.1.
4. Confirm the version is 1.0.1 with your `BUILD_NUMBER`, the warning percentage is unchanged, and an activated license still unlocks Pro themes.
5. The updated app must call `https://pay.batterysos.app`, not the Mac's own localhost.

### Battery, AC, and sleep

On a MacBook with a battery:

1. Set the emergency threshold above the current charge, or wait until the battery reaches the chosen threshold, then unplug.
2. The full-screen SOS appears at that threshold. Plugging in AC removes it.
3. Unplug again. Dismiss with Escape. It stays dismissed until the battery rises above the threshold or you choose to resume; plugging in also clears the dismissal.
4. Start Test SOS, close the lid or choose Sleep, then wake. The preview is gone. The next battery sample, not the old preview, decides whether SOS shows.
5. With Pro, set an early heads-up above the emergency threshold. It is a panel, not the full-screen SOS. Snooze for 5 minutes above 1%. At 1%, snooze does not hold the warning back. A charge reminder does not start or stop charging.

### Purchase, activation, refund

This is a real $1 charge in live mode, then a refund. Do it once, on a Mac you control, after the server you intend to keep is the one the app is calling.

1. Settings → Unlock Pro ($1)… opens a Stripe-hosted Checkout page on `https://pay.batterysos.app`.
2. Pay $1 with a real card. Copy the license key from the success page.
3. Settings → Enter License Key… and activate. Pro themes unlock. A second Mac with the same key is rejected until you deactivate the first.
4. Settings → Deactivate This Mac… then activate the same key on a second Mac. That uses one of the 3 yearly transfers. Activating the first Mac again, after deactivating the second, does not use a transfer if it is the same hardware hash.
5. Settings → Email Me My License Key… opens `/billing/recover`. Submit the purchase email. The page must not show the key. The email contains a link and a code, not the key. Open the link or enter the code and confirm the same key is shown. The link does not work a second time.
6. In the Stripe Dashboard, refund the $1 payment. The refund does not delete the license record. Leave `/var/data/battery-sos/billing-data.json` in place. Record the Checkout session id and the fact that this key remains valid so it is not treated as a mystery customer later.

Do not use this purchase to test a card you do not intend to refund. Do not paste the key, the admin token, or the receipt into git, the appcast, or a screenshot you commit.
