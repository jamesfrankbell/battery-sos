#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
SRC_FILE="$MAC_DIR/BatteryEmergencyOverlay.swift"

APP_NAME="${APP_NAME:-Battery SOS}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-BatterySOS}"
BUNDLE_ID="${BUNDLE_ID:-com.jamesbell.battery-sos}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_OS_VERSION="${MIN_OS_VERSION:-13.0}"
DIST_DIR="${DIST_DIR:-$MAC_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.0}"
SPARKLE_ROOT="${SPARKLE_ROOT:-$ROOT_DIR/third_party/sparkle-$SPARKLE_VERSION}"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"
SPARKLE_FRAMEWORK_DIR="$(dirname "$SPARKLE_FRAMEWORK")"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://batterysos.app/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-TzMjfdFQ2JZ6UhrkUQB+FUpZ8pWAhKtrTk74ytAx3To=}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"

if [[ ! -f "$SRC_FILE" ]]; then
  echo "Source file not found: $SRC_FILE" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle framework not found: $SPARKLE_FRAMEWORK" >&2
  echo "Download Sparkle and extract it to third_party/sparkle-$SPARKLE_VERSION." >&2
  exit 1
fi

echo "Building app bundle..."
echo "  App: $APP_NAME"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Version: $VERSION ($BUILD_NUMBER)"
echo "  Sparkle: $SPARKLE_VERSION"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"

xcrun --sdk macosx swiftc \
  "$SRC_FILE" \
  -O \
  -F "$SPARKLE_FRAMEWORK_DIR" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @loader_path/../Frameworks \
  -o "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/$(basename "$SPARKLE_FRAMEWORK")"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_OS_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
EOF

echo "Signing app bundle for local verification:"
echo "  Identity: $APP_SIGN_IDENTITY"
codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built app bundle at:"
echo "  $APP_PATH"
