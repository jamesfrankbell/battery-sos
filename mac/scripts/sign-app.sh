#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/Battery\\ SOS.app" >&2
  exit 1
fi

APP_PATH="$1"
IDENTITY="${DEVELOPER_ID_APP:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  echo "DEVELOPER_ID_APP is required for signing." >&2
  echo "Example: export DEVELOPER_ID_APP='Developer ID Application: Your Name (TEAMID)'" >&2
  exit 1
fi

echo "Signing app bundle inside out:"
echo "  $APP_PATH"
echo "  Identity: $IDENTITY"

FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Sparkle 2 nests XPC services and Updater.app. Sign those before the framework
# and the app. --deep is not used for the Developer ID signature.
for nested in \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK"
do
  if [[ -e "$nested" ]]; then
    echo "  $nested"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  fi
done

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true

echo "Signing complete."
