#!/usr/bin/env bash
# capture_ui_smoke.sh
# Generate the Xcode project, build SleepTracker-iOS, install + launch on
# an iPhone simulator, and capture a screenshot to tmp/screenshots/home.png.
# This is a smoke proof that the UI actually renders, not just that the
# app process starts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SCHEME="SleepTracker-iOS"
PROJECT="apple/SleepTracker.xcodeproj"
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUNDLE_ID="${BUNDLE_ID:-com.example.sleep.ios}"
OUT_DIR="tmp/screenshots"
OUT_FILE="$OUT_DIR/home.png"

echo "==> Generating Xcode project"
./scripts/generate_xcode_project.sh >/dev/null

echo "==> Resolving simulator '$SIM_NAME'"
SIM_UDID="$(xcrun simctl list devices available \
    | sed -n '/-- iOS/,/-- /p' \
    | grep -E "^[[:space:]]+${SIM_NAME} \([0-9A-F-]+\)" \
    | head -n1 \
    | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')"
if [ -z "${SIM_UDID:-}" ]; then
    echo "Could not find an available iOS simulator named '$SIM_NAME'." >&2
    exit 1
fi
echo "    UDID: $SIM_UDID"

echo "==> Building $SCHEME"
DERIVED="$ROOT_DIR/tmp/derivedData-uismoke"
mkdir -p "$DERIVED"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED" \
    -quiet

APP_PATH="$(find "$DERIVED/Build/Products" -name "SleepTracker-iOS.app" -type d | head -n1)"
if [ -z "$APP_PATH" ]; then
    echo "Built .app not found under $DERIVED" >&2
    exit 1
fi
echo "    App: $APP_PATH"

echo "==> Booting simulator"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

echo "==> Installing app"
xcrun simctl install "$SIM_UDID" "$APP_PATH"

echo "==> Launching app"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"

# Give SwiftUI time to render Home.
sleep 5

echo "==> Capturing screenshot"
mkdir -p "$ROOT_DIR/$OUT_DIR"
xcrun simctl io "$SIM_UDID" screenshot "$ROOT_DIR/$OUT_FILE"

if [ -f "$ROOT_DIR/$OUT_FILE" ]; then
    echo "OK: screenshot saved to $ROOT_DIR/$OUT_FILE"
else
    echo "FAIL: screenshot not created" >&2
    exit 1
fi
