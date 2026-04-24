"""Zero-dependency smoke test for the tiny transformer model.

Run with: `python -m python.tests.test_tiny_transformer_smoke` from repo root,
or `python tests/test_tiny_transformer_smoke.py` from the `python/` directory.

Verifies:
- the model builds from `TinyTransformerConfig` defaults
- a forward pass accepts a `(B, seq_len, feature_dim)` tensor
- the output shape is `(B, num_classes)`
- synthetic dataset path produces a loadable sample
"""
from __future__ import annotations

import sys
from pathlib import Path

# Make `training` importable whether invoked from repo root or python/.
HERE = Path(__file__).resolve().parent
PY_ROOT = HERE.parent
if str(PY_ROOT) not in sys.path:
    sys.path.insert(0, str(PY_ROOT))

import torch

from training.configs.tiny_transformer import TinyTransformerConfig
from training.models.tiny_transformer import TinyTransformer


def test_forward_pass() -> None:
    cfg = TinyTransformerConfig()
    assert cfg.feature_dim == len(cfg.feature_names), (
        "feature_dim must match the length of feature_names; "
        f"got {cfg.feature_dim} vs {len(cfg.feature_names)}"
    )
    model = TinyTransformer(cfg).eval()
    x = torch.zeros(2, cfg.seq_len, cfg.feature_dim)
    with torch.no_grad():
        y = model(x)
    assert y.shape == (2, cfg.num_classes), f"bad output shape: {y.shape}"
    print(f"OK forward pass: input {tuple(x.shape)} -> output {tuple(y.shape)}")


def test_synthetic_dataset_loads() -> None:
    from training.data.dataset import SyntheticStageDataset

    cfg = TinyTransformerConfig()
    ds = SyntheticStageDataset(
        n=4, seq_len=cfg.seq_len, feature_dim=cfg.feature_dim,
        num_classes=cfg.num_classes,
    )
    feats, label = ds[0]
    assert feats.shape == (cfg.seq_len, cfg.feature_dim)
    assert 0 <= int(label) < cfg.num_classes
    print(f"OK dataset sample: feats {tuple(feats.shape)}, label {int(label)}")


def test_trace_matches_contract() -> None:
    from training.configs.tiny_transformer import (
        FEATURE_DIM,
        INPUT_NAME,
        NUM_CLASSES,
        OUTPUT_NAME,
        SEQ_LEN,
    )
    from training.export.export_coreml import trace_model

    cfg = TinyTransformerConfig()
    traced = trace_model(cfg, Path("/nonexistent.pt"))
    example = torch.zeros(1, cfg.seq_len, cfg.feature_dim)
    with torch.no_grad():
        y = traced(example)
    assert y.shape == (1, cfg.num_classes), f"bad traced shape: {y.shape}"
    assert cfg.seq_len == SEQ_LEN
    assert cfg.feature_dim == FEATURE_DIM
    assert cfg.num_classes == NUM_CLASSES
    assert INPUT_NAME == "features"
    assert OUTPUT_NAME == "logits"
    print(
        f"OK traced export: input={INPUT_NAME}{tuple(example.shape)} "
        f"-> output={OUTPUT_NAME}{tuple(y.shape)}"
    )


if __name__ == "__main__":
    test_forward_pass()
    test_synthetic_dataset_loads()
    test_trace_matches_contract()
    print("all M5+M6 python smoke checks passed.")
