#!/usr/bin/env bash
# Generate (if needed) and open the Sleep Tracker workspace in Xcode.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
APPLE_DIR="${REPO_ROOT}/apple"
PROJECT="${APPLE_DIR}/SleepTracker.xcodeproj"
WORKSPACE="${APPLE_DIR}/SleepTracker.xcworkspace"

if [[ ! -d "${PROJECT}" ]]; then
  echo "[open_xcode] ${PROJECT} not found — generating..."
  "${HERE}/generate_xcode_project.sh"
fi

echo "[open_xcode] opening ${WORKSPACE}"
open "${WORKSPACE}"
