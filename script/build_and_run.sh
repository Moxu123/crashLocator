#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CrashLocator.xcodeproj"
SCHEME="CrashLocator"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/CrashLocator.app"
APP_BINARY="$APP_PATH/Contents/MacOS/CrashLocator"

pkill -x "CrashLocator" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_PATH"
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_PATH"
    /usr/bin/log stream --style compact --predicate 'process == "CrashLocator"'
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_PATH"
    sleep 1
    pgrep -x "CrashLocator" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
