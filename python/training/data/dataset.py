"""Synthetic sleep dataset with realistic stage transitions.

Real labelled overnight data will eventually replace this generator. Until
then the dataset must be _realistic enough_ that a trained tiny-transformer
produces sensible (non-degenerate) probabilities in the simulator and on
TestFlight.

Generator design
----------------
Each example is a window of ``seq_len`` consecutive feature vectors. Stage
transitions inside a window follow a 1st-order Markov chain whose stationary
distribution roughly matches an adult night (≈55% light, ≈20% deep, ≈22% rem,
≈3% wake). Per-stage feature distributions encode the standard sleep biomarkers:

* wake  : higher HR mean, larger HR variance, large accel energy.
* light : moderate HR, small accel.
* deep  : low HR mean, low HR variance, near-zero accel, low HRV.
* rem   : moderate HR with positive slope (autonomic activation), low accel,
          high HRV.

The label assigned to a window is the modal stage across its frames. The
classifier therefore has a clean target while still learning from the
within-window dynamics that make the transformer non-trivial.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import torch
from torch.utils.data import Dataset

# Index order must match the feature contract documented in
# `training/configs/tiny_transformer.py::TinyTransformerConfig.feature_names`.
WAKE, LIGHT, DEEP, REM = 0, 1, 2, 3

# Per-stage (mean, std) for each feature dimension. Values are in the same
# normalized units that the Rust feature extractor emits.
_STAGE_PROFILE = {
    WAKE:  np.array([
        ( 0.85, 0.15),  # hr_mean (normalized; ~85 bpm vs ~55 bpm baseline)
        ( 0.25, 0.10),  # hr_std
        ( 0.05, 0.20),  # hr_slope
        ( 0.65, 0.20),  # accel_mean
        ( 0.55, 0.20),  # accel_std
        ( 0.80, 0.15),  # accel_energy
        ( 0.10, 0.15),  # event_count_like_snore
        ( 0.30, 0.15),  # hrv_like_1
        ( 0.30, 0.15),  # hrv_like_2
    ]),
    LIGHT: np.array([
        ( 0.55, 0.10),
        ( 0.12, 0.05),
        ( 0.00, 0.10),
        ( 0.20, 0.10),
        ( 0.18, 0.08),
        ( 0.20, 0.10),
        ( 0.20, 0.15),
        ( 0.50, 0.15),
        ( 0.50, 0.15),
    ]),
    DEEP:  np.array([
        ( 0.40, 0.08),
        ( 0.06, 0.03),
        (-0.05, 0.06),
        ( 0.05, 0.04),
        ( 0.04, 0.04),
        ( 0.05, 0.05),
        ( 0.35, 0.20),
        ( 0.25, 0.10),
        ( 0.25, 0.10),
    ]),
    REM:   np.array([
        ( 0.60, 0.10),
        ( 0.18, 0.06),
        ( 0.15, 0.10),
        ( 0.08, 0.05),
        ( 0.10, 0.05),
        ( 0.12, 0.06),
        ( 0.05, 0.10),
        ( 0.75, 0.10),
        ( 0.75, 0.10),
    ]),
}

# Row-stochastic transition matrix tuned so the marginal distribution
# matches typical adult architecture and stage runs are plausibly long.
_TRANSITION = np.array([
    # to:  W     L     D     R
    [   0.55, 0.40, 0.02, 0.03],   # from W
    [   0.04, 0.78, 0.10, 0.08],   # from L
    [   0.01, 0.18, 0.80, 0.01],   # from D
    [   0.04, 0.18, 0.02, 0.76],   # from R
])


@dataclass
class SyntheticStageDataset(Dataset):
    """In-memory synthetic dataset; instantiation is cheap (vectorized)."""

    n: int = 1024
    seq_len: int = 16
    feature_dim: int = 9
    num_classes: int = 4
    seed: int = 0

    x: np.ndarray = field(init=False)
    y: np.ndarray = field(init=False)

    def __post_init__(self) -> None:
        rng = np.random.default_rng(self.seed)
        self.x = np.empty((self.n, self.seq_len, self.feature_dim), dtype=np.float32)
        self.y = np.empty((self.n,), dtype=np.int64)

        # Initial-stage prior — overweight light/deep, reflecting that most
        # windows in a night are not wake.
        prior = np.array([0.05, 0.55, 0.25, 0.15])

        for i in range(self.n):
            stages = np.empty((self.seq_len,), dtype=np.int64)
            stages[0] = rng.choice(self.num_classes, p=prior)
            for t in range(1, self.seq_len):
                stages[t] = rng.choice(self.num_classes, p=_TRANSITION[stages[t - 1]])
            for t in range(self.seq_len):
                profile = _STAGE_PROFILE[int(stages[t])]
                means = profile[:self.feature_dim, 0]
                stds = profile[:self.feature_dim, 1]
                self.x[i, t] = rng.normal(loc=means, scale=stds).astype(np.float32)

            # Label = modal stage in the window (ties broken by argmax).
            counts = np.bincount(stages, minlength=self.num_classes)
            self.y[i] = int(np.argmax(counts))

    def __len__(self) -> int:
        return self.n

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        return torch.from_numpy(self.x[idx]), torch.tensor(int(self.y[idx]))
