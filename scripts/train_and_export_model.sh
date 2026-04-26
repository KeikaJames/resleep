#!/usr/bin/env bash
# Reproducible Release B model pipeline.
#
# coremltools 9.0 has no Python 3.14 native bindings (BlobWriter), so export
# is pinned to Python 3.11. Training works on either; we pin both to 3.11 for
# determinism.
#
# Usage:
#   ./scripts/train_and_export_model.sh                # train + export
#   ./scripts/train_and_export_model.sh --skip-train   # export from latest.pt
#
# Output: apple/SleepTracker-iOS/Resources/Models/SleepStager.mlpackage
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PY_BIN="${PY_BIN:-python3.11}"
if ! command -v "$PY_BIN" >/dev/null 2>&1; then
    echo "[train_and_export] $PY_BIN not found. Install Python 3.11:" >&2
    echo "    brew install python@3.11" >&2
    exit 1
fi

VENV=".venv-export"
if [[ ! -d "$VENV" ]]; then
    echo "[train_and_export] creating $VENV with $PY_BIN"
    "$PY_BIN" -m venv "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet "torch>=2.2" "numpy>=1.26" "coremltools>=7.2"
else
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
fi

cd python
mkdir -p runs

if [[ "${1:-}" != "--skip-train" ]]; then
    echo "[train_and_export] training tiny transformer"
    python -m training.train_tiny_transformer --epochs 12 --out runs
fi

echo "[train_and_export] exporting Core ML package"
python -m training.export.export_coreml \
    --checkpoint runs/latest.pt \
    --out runs/SleepStager.mlpackage \
    --version 0.2.0

cd ..
DEST="apple/SleepTracker-iOS/Resources/Models/SleepStager.mlpackage"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R python/runs/SleepStager.mlpackage "$DEST"
echo "[train_and_export] bundled at $DEST"
