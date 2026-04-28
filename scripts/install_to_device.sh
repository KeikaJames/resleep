#!/usr/bin/env bash
# Build + install Circadia onto the connected iPhone.
#
# Prereqs (one-time):
#   1. Xcode installed at /Applications/Xcode.app
#   2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#   3. apple/Configs/Local.xcconfig has DEVELOPMENT_TEAM filled in
#   4. iPhone connected via USB, unlocked, "trust this computer" tapped
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
APPLE_DIR="${REPO_ROOT}/apple"
LOCAL_XCCONFIG="${APPLE_DIR}/Configs/Local.xcconfig"

if [[ ! -f "${LOCAL_XCCONFIG}" ]]; then
  echo "[install_to_device] missing ${LOCAL_XCCONFIG}" >&2
  echo "  cp apple/Configs/Local.xcconfig.example ${LOCAL_XCCONFIG} and fill DEVELOPMENT_TEAM" >&2
  exit 1
fi

TEAM_LINE="$(grep -E '^DEVELOPMENT_TEAM' "${LOCAL_XCCONFIG}" | tail -1 || true)"
TEAM_VAL="$(echo "${TEAM_LINE}" | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
if [[ -z "${TEAM_VAL}" ]]; then
  echo "[install_to_device] DEVELOPMENT_TEAM is empty in ${LOCAL_XCCONFIG}" >&2
  echo "  Open Xcode → Settings → Accounts to find your 10-char Team ID and paste it in." >&2
  exit 1
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "[install_to_device] xcodebuild missing — install Xcode and run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

DEVICE_LINE="$(xcrun xctrace list devices 2>&1 | grep -v Simulator | grep -E '\([0-9]+\.[0-9]+(\.[0-9]+)?\) \(' | head -1)"
if [[ -z "${DEVICE_LINE}" ]]; then
  echo "[install_to_device] no physical device detected." >&2
  echo "  Plug in your iPhone via USB, unlock it, tap 'Trust this computer'." >&2
  exit 1
fi
DEVICE_ID="$(echo "${DEVICE_LINE}" | sed -E 's/.*\(([0-9A-Fa-f-]+)\)$/\1/')"
echo "[install_to_device] target device: ${DEVICE_LINE}"

bash "${HERE}/generate_xcode_project.sh"

cd "${APPLE_DIR}"
xcodebuild \
  -workspace SleepTracker.xcworkspace \
  -scheme SleepTracker-iOS \
  -configuration Debug \
  -destination "id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  clean build install

echo
echo "[install_to_device] done. On the iPhone:"
echo "  Settings → General → VPN & Device Management → trust the developer cert."
echo "  Then tap the Circadia icon."
