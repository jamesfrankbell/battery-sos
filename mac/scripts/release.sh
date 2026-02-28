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

"$MAC_DIR/scripts/build-app.sh"

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  "$MAC_DIR/scripts/sign-app.sh" "$APP_PATH"
else
  echo "Skipping app signing (DEVELOPER_ID_APP not set)."
fi

"$MAC_DIR/scripts/build-dmg.sh" "$APP_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  "$MAC_DIR/scripts/notarize.sh" "$DMG_PATH"
else
  echo "Skipping notarization (NOTARY_PROFILE not set)."
fi

echo "Release artifacts:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
