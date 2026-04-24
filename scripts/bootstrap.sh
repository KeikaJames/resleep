#!/usr/bin/env bash
# Bootstrap dev environment.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Checking toolchains"
command -v cargo >/dev/null || { echo "Install rustup first"; exit 1; }
command -v python3 >/dev/null || { echo "Install python3 first"; exit 1; }

echo "==> Adding iOS rust targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios || true

echo "==> Installing python deps"
if [ -f python/requirements.txt ]; then
  python3 -m pip install --user -r python/requirements.txt
fi

echo "==> Building rust workspace (host)"
cd rust && cargo build --workspace

echo "==> Done. Next: make xcframework   # or open apple/SleepTracker.xcworkspace"
