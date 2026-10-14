#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
SRC_FILE="$MAC_DIR/BatteryEmergencyOverlay.swift"
STATE_FILE="$MAC_DIR/BatteryAlertState.swift"
PREFERENCES_FILE="$MAC_DIR/AppPreferences.swift"
AUDIO_FILE="$MAC_DIR/AlertAudio.swift"
AUDIO_PLAYER_FILE="$MAC_DIR/AlertAudioPlayer.swift"
PRO_FILE="$MAC_DIR/ProBatteryFeatures.swift"

APP_NAME="${APP_NAME:-Battery SOS}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-BatterySOS}"
BUNDLE_ID="${BUNDLE_ID:-com.jamesbell.battery-sos}"
VERSION="${VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:?Set BUILD_NUMBER explicitly to identify the reviewed build}"
MIN_OS_VERSION="${MIN_OS_VERSION:-13.0}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-${TMPDIR:-/tmp}/battery-sos-swift-cache}"
DIST_DIR="${DIST_DIR:-$MAC_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.0}"
SPARKLE_ROOT="${SPARKLE_ROOT:-$ROOT_DIR/third_party/sparkle-$SPARKLE_VERSION}"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"
SPARKLE_FRAMEWORK_DIR="$(dirname "$SPARKLE_FRAMEWORK")"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://batterysos.app/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-TzMjfdFQ2JZ6UhrkUQB+FUpZ8pWAhKtrTk74ytAx3To=}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"

if [[ ! -f "$SRC_FILE" || ! -f "$STATE_FILE" || ! -f "$PREFERENCES_FILE" || ! -f "$AUDIO_FILE" || ! -f "$AUDIO_PLAYER_FILE" || ! -f "$PRO_FILE" ]]; then
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

if [[ -e "$APP_PATH" ]]; then
  echo "Refusing to overwrite an existing app: $APP_PATH. Set a fresh DIST_DIR." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" != arm64 ]]; then
  echo "Only the reviewed arm64 target is supported." >&2
  exit 1
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"

xcrun --sdk macosx swiftc \
  "$SRC_FILE" "$STATE_FILE" "$PREFERENCES_FILE" "$AUDIO_FILE" "$AUDIO_PLAYER_FILE" "$PRO_FILE" \
  -parse-as-library \
  -O \
  -target "$TARGET_ARCH-apple-macosx$MIN_OS_VERSION" \
  -module-cache-path "$MODULE_CACHE_DIR" \
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

# Embed provenance before signing so inspection identifies the source actually built.
PROVENANCE="$APP_PATH/Contents/Resources/BuildProvenance.plist"
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_SHA256="$(shasum -a 256 "$SRC_FILE" | awk '{print $1}')"
BUILD_SCRIPT_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
plutil -create xml1 "$PROVENANCE"
plutil -insert SourceRevision -string "$SOURCE_REVISION" "$PROVENANCE"
plutil -insert SourceSHA256 -string "$SOURCE_SHA256" "$PROVENANCE"
plutil -insert StateSHA256 -string "$(shasum -a 256 "$STATE_FILE" | awk '{print $1}')" "$PROVENANCE"
plutil -insert PreferencesSHA256 -string "$(shasum -a 256 "$PREFERENCES_FILE" | awk '{print $1}')" "$PROVENANCE"
plutil -insert AudioSHA256 -string "$(shasum -a 256 "$AUDIO_FILE" | awk '{print $1}')" "$PROVENANCE"
plutil -insert AudioPlayerSHA256 -string "$(shasum -a 256 "$AUDIO_PLAYER_FILE" | awk '{print $1}')" "$PROVENANCE"
plutil -insert ProFeaturesSHA256 -string "$(shasum -a 256 "$PRO_FILE" | awk '{print $1}')" "$PROVENANCE"
plutil -insert BuildScriptSHA256 -string "$BUILD_SCRIPT_SHA256" "$PROVENANCE"
plutil -insert BuildNumber -string "$BUILD_NUMBER" "$PROVENANCE"
plutil -insert Target -string "$TARGET_ARCH-apple-macosx$MIN_OS_VERSION" "$PROVENANCE"
plutil -insert SwiftCompiler -string "$(xcrun swiftc --version)" "$PROVENANCE"

echo "Signing app bundle for local verification:"
echo "  Identity: $APP_SIGN_IDENTITY"
codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built app bundle at:"
echo "  $APP_PATH"
