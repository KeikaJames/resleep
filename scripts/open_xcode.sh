#!/usr/bin/env bash
# Generate (always) and open the Sleep Tracker workspace in Xcode.
#
# We unconditionally regenerate because editing project.yml without
# regenerating produces a silently stale xcodeproj. Regeneration is
# cheap (<1s with XcodeGen) and avoids "opened the wrong project" bugs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
APPLE_DIR="${REPO_ROOT}/apple"
WORKSPACE="${APPLE_DIR}/SleepTracker.xcworkspace"

echo "[open_xcode] regenerating project before opening..."
"${HERE}/generate_xcode_project.sh"

echo "[open_xcode] opening ${WORKSPACE}"
open "${WORKSPACE}"
