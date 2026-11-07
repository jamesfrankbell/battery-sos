#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
SRC_FILE="$MAC_DIR/BatteryEmergencyOverlay.swift"

APP_NAME="${APP_NAME:-Battery SOS}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-BatterySOS}"
BUNDLE_ID="${BUNDLE_ID:-com.jamesbell.battery-sos}"
VERSION="${VERSION:-1.0.1}"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  echo "Set BUILD_NUMBER to the reviewed build id, for example BUILD_NUMBER=202611071600." >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "BUILD_NUMBER may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 1
fi
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
echo "  Target: arm64-apple-macosx$MIN_OS_VERSION"

if [[ -e "$APP_PATH" ]]; then
  echo "Refusing to overwrite an existing app: $APP_PATH" >&2
  echo "Set DIST_DIR to a new directory. Do not replace a signed artifact in place." >&2
  exit 1
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"

xcrun --sdk macosx swiftc \
  "$SRC_FILE" \
  -O \
  -target "arm64-apple-macosx$MIN_OS_VERSION" \
  -F "$SPARKLE_FRAMEWORK_DIR" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @loader_path/../Frameworks \
  -o "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# Check the compiled release, not just the source: the original public build
# accidentally sent customer checkout requests to their own localhost.
if ! strings "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" | grep -Fx 'https://pay.batterysos.app' >/dev/null; then
  echo "Release blocked: compiled app does not contain the production billing URL." >&2
  exit 1
fi
if strings "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" | grep -F 'http://127.0.0.1:8787' >/dev/null; then
  echo "Release blocked: compiled app contains the development billing URL." >&2
  exit 1
fi

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

SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_SHA256="$(shasum -a 256 "$SRC_FILE" | awk '{print $1}')"
cat > "$APP_PATH/Contents/Resources/BuildProvenance.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>SourceRevision</key>
  <string>$SOURCE_REVISION</string>
  <key>SourceSHA256</key>
  <string>$SOURCE_SHA256</string>
  <key>BuildNumber</key>
  <string>$BUILD_NUMBER</string>
  <key>Version</key>
  <string>$VERSION</string>
  <key>Target</key>
  <string>arm64-apple-macosx$MIN_OS_VERSION</string>
</dict>
</plist>
EOF

echo "Signing app bundle for local verification:"
echo "  Identity: $APP_SIGN_IDENTITY"
if [[ "$APP_SIGN_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signature only. This bundle is not notarized and is not a public download."
fi
codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built app bundle at:"
echo "  $APP_PATH"
