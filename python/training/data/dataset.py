"""Placeholder synthetic dataset for the tiny-transformer.

Real data will come from labelled nights exported (on device) to CSV/Parquet.
For now we generate toy sequences so the training loop is exercisable.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import torch
from torch.utils.data import Dataset


@dataclass
class SyntheticStageDataset(Dataset):
    n: int = 1024
    seq_len: int = 16
    feature_dim: int = 9
    num_classes: int = 4
    seed: int = 0

    def __post_init__(self) -> None:
        rng = np.random.default_rng(self.seed)
        # x: (N, seq_len, feature_dim)
        self.x = rng.standard_normal(
            (self.n, self.seq_len, self.feature_dim)
        ).astype(np.float32)
        # Toy labels correlated to the sign of hr_slope (feature index 2).
        hr_slope_mean = self.x[:, :, 2].mean(axis=1)
        accel_energy_mean = self.x[:, :, 5].mean(axis=1)
        y = np.zeros(self.n, dtype=np.int64)
        y[(accel_energy_mean > 1.0)] = 0  # wake
        y[(accel_energy_mean <= 1.0) & (hr_slope_mean < -0.2)] = 2  # deep
        y[(accel_energy_mean <= 1.0) & (hr_slope_mean > 0.2)] = 3  # rem
        y[(accel_energy_mean <= 1.0) & (hr_slope_mean.__abs__() <= 0.2)] = 1  # light
        self.y = y

    def __len__(self) -> int:
        return self.n

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        return torch.from_numpy(self.x[idx]), torch.tensor(self.y[idx])
