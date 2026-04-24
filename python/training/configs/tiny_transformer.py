from __future__ import annotations

from dataclasses import dataclass


@dataclass
class TinyTransformerConfig:
    """Hyperparameters for the on-device stager.

    Must be kept in sync with the Rust feature extractor (see
    `rust/crates/sleep-core/src/signal/features.rs`) — in particular,
    `feature_dim` is the post-padding width of the rolling feature vector.
    """

    seq_len: int = 16
    feature_dim: int = 9
    d_model: int = 64
    n_heads: int = 4
    n_layers: int = 2
    ff_dim: int = 128
    num_classes: int = 4  # wake / light / deep / rem
    dropout: float = 0.1

    # Training
    lr: float = 3e-4
    batch_size: int = 64
    epochs: int = 5
    weight_decay: float = 1e-4
    seed: int = 42

    # Named feature indices (documentation only — mirrors Rust / Swift contract).
    feature_names: tuple[str, ...] = (
        "hr_mean",
        "hr_std",
        "hr_slope",
        "accel_mean",
        "accel_std",
        "accel_energy",
        "event_count_like_snore",
        "hrv_like_1",
        "hrv_like_2",
    )


# ---------------------------------------------------------------------------
# M6 Core ML contract — mirrors apple/SleepKit/.../ModelContract.swift.
# Keep these in sync; Swift asserts them at load time.
# ---------------------------------------------------------------------------

INPUT_NAME: str = "features"
OUTPUT_NAME: str = "logits"
RESOURCE_NAME: str = "SleepStager"
SEQ_LEN: int = 16
FEATURE_DIM: int = 9
NUM_CLASSES: int = 4
