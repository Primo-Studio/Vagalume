#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vagalume"
BUNDLE_ID="studio.primo.Vagalume"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
MODE="${1:-run}"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" 2>/dev/null || true
"$ROOT_DIR/Scripts/package_app.sh" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_DIR"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_DIR/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME is running"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
