#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> rust: cargo test"
cd "$ROOT/rust"
cargo test --workspace --quiet

echo "==> swift: swift test (SleepKit)"
cd "$ROOT/apple/SleepKit"
swift test --quiet

echo "==> python: pytest (if configured)"
cd "$ROOT/python"
if command -v pytest >/dev/null 2>&1 && [ -d tests ]; then
  pytest -q
else
  echo "skip: no python tests configured"
fi

echo "all tests passed"
