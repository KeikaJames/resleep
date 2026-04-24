"""M6: pin the Core ML export contract.

These constants are mirrored by Swift (`ModelContract.swift`). When changing
any of them, update both sides together.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY_ROOT = HERE.parent
if str(PY_ROOT) not in sys.path:
    sys.path.insert(0, str(PY_ROOT))

from training.configs.tiny_transformer import (
    FEATURE_DIM,
    INPUT_NAME,
    NUM_CLASSES,
    OUTPUT_NAME,
    RESOURCE_NAME,
    SEQ_LEN,
    TinyTransformerConfig,
)


def test_contract_matches_swift() -> None:
    assert INPUT_NAME == "features"
    assert OUTPUT_NAME == "logits"
    assert RESOURCE_NAME == "SleepStager"
    assert SEQ_LEN == 16
    assert FEATURE_DIM == 9
    assert NUM_CLASSES == 4


def test_config_matches_contract() -> None:
    cfg = TinyTransformerConfig()
    assert cfg.seq_len == SEQ_LEN
    assert cfg.feature_dim == FEATURE_DIM
    assert cfg.num_classes == NUM_CLASSES
    assert len(cfg.feature_names) == FEATURE_DIM


if __name__ == "__main__":
    test_contract_matches_swift()
    test_config_matches_contract()
    print("OK M6 export contract pinned.")
