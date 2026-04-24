#!/usr/bin/env bash
# Build the SleepCore xcframework for iOS device + iOS simulator and drop the
# generated Swift bridge files into the SleepKit SPM package.
#
# Prereqs (rustup):
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ROOT/rust"
CRATE="sleep-core"
LIB="libsleep_core.a"
OUT="$ROOT/rust/target-xcframework"
INCLUDE="$OUT/include"
SWIFT_OUT="$ROOT/apple/SleepKit/Sources/SleepKit/Generated"

echo "[xcframework] building release for 3 iOS targets…"
cd "$RUST_DIR"
cargo build -p "$CRATE" --release --target aarch64-apple-ios
cargo build -p "$CRATE" --release --target aarch64-apple-ios-sim
cargo build -p "$CRATE" --release --target x86_64-apple-ios

mkdir -p "$INCLUDE/SleepCore"
DEVICE_LIB="target/aarch64-apple-ios/release/$LIB"
SIM_ARM64_LIB="target/aarch64-apple-ios-sim/release/$LIB"
SIM_X86_64_LIB="target/x86_64-apple-ios/release/$LIB"

SIM_UNIVERSAL="$OUT/libsleep_core_sim.a"
mkdir -p "$OUT"
lipo -create "$SIM_ARM64_LIB" "$SIM_X86_64_LIB" -output "$SIM_UNIVERSAL"

echo "[xcframework] copying generated headers…"
# swift-bridge writes the .h next to the .swift under the build script's OUT_DIR.
GEN_ROOT=$(find target/release/build -type d -name generated | head -n 1)
if [[ -z "${GEN_ROOT:-}" ]]; then
  echo "ERROR: generated dir not found under target/release/build" >&2
  exit 1
fi
cp -f "$GEN_ROOT/SleepCore/SleepCore.h" "$INCLUDE/SleepCore/SleepCore.h"
cp -f "$GEN_ROOT/SwiftBridgeCore.h"     "$INCLUDE/SleepCore/SwiftBridgeCore.h"

cat > "$INCLUDE/SleepCore/module.modulemap" <<'EOF'
module SleepCoreFFI {
  header "SleepCore.h"
  header "SwiftBridgeCore.h"
  export *
}
EOF

echo "[xcframework] packaging…"
rm -rf "$OUT/SleepCore.xcframework"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB"    -headers "$INCLUDE/SleepCore" \
  -library "$SIM_UNIVERSAL" -headers "$INCLUDE/SleepCore" \
  -output "$OUT/SleepCore.xcframework"

echo "[xcframework] installing Swift bridge glue into SleepKit…"
mkdir -p "$SWIFT_OUT"
cp -f "$GEN_ROOT/SleepCore/SleepCore.swift" "$SWIFT_OUT/SleepCore.swift"
cp -f "$GEN_ROOT/SwiftBridgeCore.swift"     "$SWIFT_OUT/SwiftBridgeCore.swift"

echo "[xcframework] done → $OUT/SleepCore.xcframework"
