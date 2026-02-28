#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/file.dmg" >&2
  echo "Set NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
  exit 1
fi

TARGET_PATH="$1"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Target not found: $TARGET_PATH" >&2
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "NOTARY_PROFILE is required." >&2
  echo "Example: export NOTARY_PROFILE='BatterySOSNotary'" >&2
  exit 1
fi

echo "Submitting for notarization:"
echo "  Target: $TARGET_PATH"
echo "  Profile: $NOTARY_PROFILE"

xcrun notarytool submit "$TARGET_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$TARGET_PATH"
xcrun stapler validate "$TARGET_PATH"

echo "Notarization and stapling complete."
