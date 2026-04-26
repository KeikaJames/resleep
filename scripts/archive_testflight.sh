#!/usr/bin/env bash
# scripts/archive_testflight.sh
#
# Build a signed iOS archive ready for TestFlight upload.
#
# Prerequisites:
#   * Apple Developer Program membership (paid).
#   * apple/Configs/Local.xcconfig populated with DEVELOPMENT_TEAM and
#     BASE_BUNDLE_ID (see apple/Configs/Local.xcconfig.example).
#   * The Bundle ID registered in App Store Connect, with HealthKit and
#     WCSession capabilities enabled.
#   * Xcode 15+ with command line tools selected.
#
# Output:
#   build/SleepTracker.xcarchive
#   build/export/SleepTracker.ipa
#
# Upload to TestFlight after running this script:
#   xcrun altool --upload-app -f build/export/SleepTracker.ipa \
#       --type ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
# or open Transporter.app and drag the .ipa.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_CONFIG="$REPO_ROOT/apple/Configs/Local.xcconfig"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/SleepTracker.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$SCRIPT_DIR/exportOptions.plist"

if [[ ! -f "$LOCAL_CONFIG" ]]; then
    echo "error: $LOCAL_CONFIG is missing." >&2
    echo "       Copy apple/Configs/Local.xcconfig.example to Local.xcconfig" >&2
    echo "       and fill in your Apple Developer team ID." >&2
    exit 1
fi

if ! grep -q "^DEVELOPMENT_TEAM" "$LOCAL_CONFIG"; then
    echo "error: DEVELOPMENT_TEAM not set in $LOCAL_CONFIG." >&2
    exit 1
fi

TEAM_ID="$(grep '^DEVELOPMENT_TEAM' "$LOCAL_CONFIG" | head -1 | cut -d= -f2 | xargs)"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "ABCDE12345" ]]; then
    echo "error: DEVELOPMENT_TEAM in $LOCAL_CONFIG looks unset (got '$TEAM_ID')." >&2
    exit 1
fi

echo "[archive] using DEVELOPMENT_TEAM=$TEAM_ID"
echo "[archive] regenerating Xcode project"
"$SCRIPT_DIR/generate_xcode_project.sh"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

echo "[archive] xcodebuild archive"
xcodebuild archive \
    -project "$REPO_ROOT/apple/SleepTracker.xcodeproj" \
    -scheme SleepTracker-iOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | tail -40

echo "[archive] xcodebuild -exportArchive"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -20

echo
echo "[archive] done."
echo "  archive: $ARCHIVE_PATH"
echo "  ipa:     $(ls "$EXPORT_PATH"/*.ipa 2>/dev/null || echo 'not produced')"
echo
echo "Next: upload via Transporter.app or:"
echo "  xcrun altool --upload-app -f \"$EXPORT_PATH\"/*.ipa --type ios \\"
echo "      --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
