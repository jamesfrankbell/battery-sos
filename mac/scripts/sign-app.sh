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

echo "Signing app bundle:"
echo "  $APP_PATH"
echo "  Identity: $IDENTITY"

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true

echo "Signing complete."
