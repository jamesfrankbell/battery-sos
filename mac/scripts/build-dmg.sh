#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
DIST_DIR="${DIST_DIR:-$MAC_DIR/dist}"
APP_NAME="${APP_NAME:-Battery SOS}"
APP_PATH="${1:-$DIST_DIR/$APP_NAME.app}"
DMG_NAME="${DMG_NAME:-battery-sos-macos}"
VOL_NAME="${VOL_NAME:-Battery SOS}"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG:"
echo "  $DMG_PATH"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  echo "Signing DMG with identity: $DEVELOPER_ID_APP"
  codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

rm -rf "$STAGING_DIR"

echo "DMG ready:"
echo "  $DMG_PATH"
