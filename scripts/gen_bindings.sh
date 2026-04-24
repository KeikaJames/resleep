#!/usr/bin/env bash
# Regenerates the Swift bridge files (no xcframework) so the SPM package sees
# matching symbols. Useful when iterating on bindings.rs without rebuilding
# for device. After this, `swift build` in apple/SleepKit will still fall back
# to the non-Rust path until the xcframework exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_OUT="$ROOT/apple/SleepKit/Sources/SleepKit/Generated"

cd "$ROOT/rust"
cargo build -p sleep-core

GEN_ROOT=$(find target/debug/build -type d -name generated | head -n 1)
if [[ -z "${GEN_ROOT:-}" ]]; then
  echo "ERROR: generated dir not found under target/debug/build" >&2
  exit 1
fi

mkdir -p "$SWIFT_OUT"
cp -f "$GEN_ROOT/SleepCore/SleepCore.swift" "$SWIFT_OUT/SleepCore.swift"
cp -f "$GEN_ROOT/SwiftBridgeCore.swift"     "$SWIFT_OUT/SwiftBridgeCore.swift"

echo "[gen_bindings] Swift files written to $SWIFT_OUT"
