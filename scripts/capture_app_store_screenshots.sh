#!/usr/bin/env bash
# capture_app_store_screenshots.sh
# Build SleepTracker-iOS once, then iterate across required App Store device
# classes (6.9", 6.5", 12.9" iPad), boot each simulator, install + launch the
# app, and capture a Home screenshot per device per locale.
#
# Output: docs/screenshots/<locale>/<device>.png
#
# Locales: en, zh-Hans (override with LOCALES env, space-separated).
# Devices: defaults below; override with DEVICES env (one per line: name|outname).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SCHEME="${SCHEME:-SleepTracker-iOS}"
PROJECT="${PROJECT:-apple/SleepTracker.xcodeproj}"
BUNDLE_ID="${BUNDLE_ID:-com.example.sleep.ios}"
OUT_ROOT="docs/screenshots"
LOCALES="${LOCALES:-en zh-Hans}"

DEVICES_DEFAULT=$'iPhone 15 Pro Max|6_9_inch\niPhone 11 Pro Max|6_5_inch\niPad Pro 13-inch (M4)|12_9_inch'
DEVICES="${DEVICES:-$DEVICES_DEFAULT}"

echo "==> Generating Xcode project"
./scripts/generate_xcode_project.sh >/dev/null

DERIVED="$ROOT_DIR/tmp/derivedData-appstore"
mkdir -p "$DERIVED" "$OUT_ROOT"

# Build once for generic iOS Simulator destination so it works on any sim arch.
echo "==> Building $SCHEME (one-time)"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" \
    -quiet

APP_PATH="$(find "$DERIVED/Build/Products" -name "SleepTracker-iOS.app" -type d | head -n1)"
[ -n "$APP_PATH" ] || { echo "Built .app not found" >&2; exit 1; }
echo "    App: $APP_PATH"

resolve_udid() {
    local sim_name="$1"
    xcrun simctl list devices available \
        | grep -E "^[[:space:]]+${sim_name} \([0-9A-F-]+\)" \
        | head -n1 \
        | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/'
}

shoot_one() {
    local sim_name="$1" out_name="$2" locale="$3"
    local udid
    udid="$(resolve_udid "$sim_name" || true)"
    if [ -z "$udid" ]; then
        echo "    [skip] simulator not available: $sim_name"
        return 0
    fi
    echo "    [$locale] $sim_name ($udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$udid" "$APP_PATH"
    xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -AppleLanguages "($locale)" \
        -AppleLocale "$locale" >/dev/null
    sleep 5
    local out_dir="$OUT_ROOT/$locale"
    mkdir -p "$out_dir"
    xcrun simctl io "$udid" screenshot "$out_dir/${out_name}.png"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
}

while IFS= read -r line; do
    [ -z "$line" ] && continue
    sim="${line%%|*}"
    name="${line##*|}"
    for loc in $LOCALES; do
        shoot_one "$sim" "$name" "$loc"
    done
done <<< "$DEVICES"

echo
echo "==> Done. Screenshots in $OUT_ROOT/<locale>/"
ls -1 "$OUT_ROOT" 2>/dev/null || true
