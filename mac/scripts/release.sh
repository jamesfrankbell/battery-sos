#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
DIST_DIR="${DIST_DIR:-$MAC_DIR/dist}"
APP_NAME="${APP_NAME:-Battery SOS}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_NAME="${DMG_NAME:-battery-sos-macos}"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"

echo "== Battery SOS direct-release pipeline =="

if [[ -z "${BUILD_NUMBER:-}" ]]; then
  echo "Set BUILD_NUMBER, for example: BUILD_NUMBER=202611071600 mac/scripts/release.sh" >&2
  exit 1
fi
export VERSION="${VERSION:-1.0.1}"
export BUILD_NUMBER

"$MAC_DIR/scripts/build-app.sh"

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  "$MAC_DIR/scripts/sign-app.sh" "$APP_PATH"
else
  echo "Skipping app signing (DEVELOPER_ID_APP not set)."
fi

"$MAC_DIR/scripts/build-dmg.sh" "$APP_PATH"

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME.dmg" > "$DMG_NAME.dmg.sha256"
)

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  "$MAC_DIR/scripts/notarize.sh" "$DMG_PATH"
  (
    cd "$DIST_DIR"
    shasum -a 256 "$DMG_NAME.dmg" > "$DMG_NAME.dmg.sha256"
  )
else
  echo "Skipping notarization (NOTARY_PROFILE not set)."
fi

echo "Release artifacts:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo "  SHA256: $DIST_DIR/$DMG_NAME.dmg.sha256"
if [[ -z "${DEVELOPER_ID_APP:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
  echo "CANDIDATE ONLY: this DMG is not a notarized public release."
  echo "Do not upload it over the restored 1.0.0 build 202603110225 download."
fi
