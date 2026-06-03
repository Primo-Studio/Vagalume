#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vagalume"
VERSION="${VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Primo Studio (4QB44XVHNL)}"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  rsync -a "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>studio.primo.Vagalume</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/Primo-Studio/Vagalume/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>jLm0dM43ZCL3cMpwt7/pA8Tc2Xll5mkuvwIycQ2va7s=</string>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null 2>&1
else
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
fi

echo "$APP_DIR"
