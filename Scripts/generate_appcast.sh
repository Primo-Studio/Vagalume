#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vagalume"
VERSION="${VERSION:-0.1.1}"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-macOS.zip"
APPCAST_WORK_DIR="$ROOT_DIR/dist/appcast"
DOWNLOAD_PREFIX="https://github.com/Primo-Studio/Vagalume/releases/download/v$VERSION/"

cd "$ROOT_DIR"

if [[ ! -x "$SPARKLE_BIN" ]]; then
  swift package resolve
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing update archive: $ZIP_PATH" >&2
  echo "Run: NOTARY_PROFILE=Vagalume-Notary ./Scripts/package_release.sh --notarize" >&2
  exit 2
fi

rm -rf "$APPCAST_WORK_DIR"
mkdir -p "$APPCAST_WORK_DIR"
cp "$ZIP_PATH" "$APPCAST_WORK_DIR/"

"$SPARKLE_BIN" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-versions 0 \
  -o "$ROOT_DIR/appcast.xml" \
  "$APPCAST_WORK_DIR"

echo "$ROOT_DIR/appcast.xml"
