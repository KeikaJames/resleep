#!/usr/bin/env bash
# Generate the Xcode project from apple/project.yml via XcodeGen.
#
# Usage:
#   ./scripts/generate_xcode_project.sh
#   BASE_BUNDLE_ID=dev.yourteam.sleep ./scripts/generate_xcode_project.sh
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/generate_xcode_project.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
APPLE_DIR="${REPO_ROOT}/apple"

if ! command -v xcodegen >/dev/null 2>&1; then
  cat >&2 <<'MSG'
[generate_xcode_project] XcodeGen is not installed.

Install with one of:
  brew install xcodegen
  mint install yonaskolb/xcodegen

Then re-run this script.
MSG
  exit 1
fi

cd "${APPLE_DIR}"
echo "[generate_xcode_project] running xcodegen in ${APPLE_DIR}"
xcodegen generate --spec project.yml --project .

# Rebuild the workspace so it references the freshly-generated .xcodeproj
# plus the SleepKit local package. Keep the file under source control so the
# repo remains openable in Xcode without regenerating.
WS="${APPLE_DIR}/SleepTracker.xcworkspace"
mkdir -p "${WS}/xcshareddata"
cat > "${WS}/contents.xcworkspacedata" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
   <FileRef location="group:SleepTracker.xcodeproj"></FileRef>
   <FileRef location="group:SleepKit"></FileRef>
</Workspace>
XML

echo "[generate_xcode_project] wrote ${WS}/contents.xcworkspacedata"
echo "[generate_xcode_project] done."
echo "Open with:  open \"${WS}\""
