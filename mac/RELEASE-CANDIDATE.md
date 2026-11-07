# Battery SOS 1.0.1 candidate

This is the new entitlement client. It is not the notarized 1.0.0 build `202603110225` DMG, and it is not `mac/dist/Battery SOS.app` build `202610150505` (no Team ID, Gatekeeper rejects it). Do not upload either of those as this candidate.

The public download repair is a separate change. Until that is deployed, `https://batterysos.app/downloads/battery-sos-macos.dmg` stays 404. Do not replace that URL with an unsigned build.

## What this source does

- Free mode is Default Warning. Vitals Monitor and the other modes are Pro, including the menu label.
- Checkout copy stays Unlock Pro ($1).
- Activation sends `machineHash` and stores a signed entitlement in the Keychain. The embedded public key is `gTZwp8xK+B6IlAst6SlVbEWZTpGKneMuCjImIlipJuM=`.
- Settings → Email My License Key posts to `/api/billing/recover` and shows the generic server message. It does not display a key from the response.
- Sleep hides the overlay and stops alert audio. Wake reads the battery again. Plugging in hides the alert. Those paths were read in source and have not been exercised on a Mac from this environment.

## Old DMG vs this server

The app inside the 1,429,342-byte notarized DMG has no entitlement public key. Current `verify-license` still returns `valid` without an entitlement when `machineHash` is omitted, which is what an old client sends. That is not a successful activation test. The October 1 recovery note said that DMG still calls `http://127.0.0.1:8787`. Do not claim the old app unlocks against `https://pay.batterysos.app` until someone on a Mac confirms the billing host inside the executable.

## Not done here

This Linux environment has no Swift, Xcode, or Mac worker. These scripts were syntax-checked with `bash -n` and the Node tests. Nothing was signed, notarized, or launched.

## Mac commands

On the Apple silicon Mac with Xcode. Sparkle 2.9.0 must already be at `third_party/sparkle-2.9.0/Sparkle.framework`. Node is not required for the build. Do not install a new signing identity.

```bash
cd /Users/jamesbell/battery-sos
git fetch origin
git checkout cursor/mac-release-candidate-9019
export DIST_DIR="$HOME/Library/Application Support/BatterySOS/candidate-1.0.1"
export BUILD_NUMBER=202611071600
export VERSION=1.0.1
mac/scripts/release.sh
```

That prints `CANDIDATE ONLY` unless both `DEVELOPER_ID_APP` and `NOTARY_PROFILE` are already set in the environment. An ad-hoc signature is not distributable.

Signed and notarized build, only after the candidate looks right, using the existing Developer ID and notary profile:

```bash
# Use the Developer ID Application certificate already in the login keychain.
# The notarized 1.0.0 DMG was signed by team 9JNKPQCLGG. Do not create a new identity.
export DEVELOPER_ID_APP="Developer ID Application: <name already on the certificate> (9JNKPQCLGG)"
export NOTARY_PROFILE="BatterySOSNotary"
export DIST_DIR="$HOME/Library/Application Support/BatterySOS/candidate-1.0.1-signed"
export BUILD_NUMBER=202611071600
mac/scripts/release.sh
```

`DIST_DIR` must be a new directory. The script refuses to overwrite an existing `.app`. After notarization, stapling changes the DMG, and the script rewrites the sha256. Then, and only then, run Sparkle's `sign_update` from the extracted Sparkle 2.9.0 tools (it sits next to `Sparkle.framework` in that download, not in this repo):

```bash
# Paste the printed edSignature into a new appcast item. Do not reuse the
# 202603061320 signature.
/path/to/sparkle-2.9.0/bin/sign_update "$DIST_DIR/battery-sos-macos.dmg"
node mac/scripts/prepare-update.js \
  "$DIST_DIR/Battery SOS.app" \
  "$DIST_DIR/battery-sos-macos.dmg" \
  "$DIST_DIR/evidence" \
  "<edSignature from sign_update>"
```

`prepare-update.js` writes only inside the new evidence directory. It does not edit `website/appcast.xml`. `releaseAccepted` stays false until codesign, stapler, arm64, the production billing URL, and the Sparkle signature all pass. Node is required for that script only. This Mac has no Node today, so install Node before that one command, or run it on a machine that already has Node. Do not publish the evidence directory.

Checks that still need a person at the Mac:

1. `strings` on the candidate executable contains `https://pay.batterysos.app` and does not contain `http://127.0.0.1:8787`.
2. Enter the license from the paid checkout. Pro modes unlock. Quit and relaunch. Pro stays unlocked offline.
3. Email My License Key shows the generic sentence and no key.
4. Default Warning works without a license. Vitals Monitor shows `(Pro)` and does not start.
5. Test SOS, mute, warning percent, plug in, sleep, and wake.
