#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vagalume"
BUNDLE_ID="studio.primo.Vagalume"
TEAM_ID="4QB44XVHNL"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Primo Studio ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION="${VERSION:-0.1.1}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macOS.zip"
MODE="${1:-sign}"

cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/package_app.sh" >/dev/null

codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null 2>&1
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

rm -f "$ZIP_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ "$MODE" == "--notarize" || "$MODE" == "notarize" ]]; then
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARY_PROFILE is required for notarization." >&2
    echo "Create one with: xcrun notarytool store-credentials Vagalume-Notary --team-id $TEAM_ID --apple-id <apple-id>" >&2
    exit 2
  fi

  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"

  rm -f "$ZIP_PATH"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"
  spctl --assess --type execute --verbose=4 "$APP_DIR"
elif [[ "$MODE" != "sign" ]]; then
  echo "usage: $0 [sign|--notarize]" >&2
  exit 2
fi

echo "$ZIP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo "Signing identity: $SIGNING_IDENTITY"
