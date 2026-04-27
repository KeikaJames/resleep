"""Synthetic log-mel spectrograms for snore vs non-snore.

Purely generated on-the-fly. No external audio data.

Snore-like:
  - low-frequency periodic energy (50-500 Hz band → low mel bins)
  - repetition ~0.3-0.6 Hz (one snore every 1.5-3 s)
  - 1 s window typically catches 0-1 snores; we synthesize an envelope
    that has a single strong burst within the window.

Non-snore:
  - smooth pink-noise mel
  - occasional broadband transients (door, rustle) at random mel bin
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import torch
from torch.utils.data import Dataset


@dataclass
class SnoreDataset(Dataset):
    n_samples: int = 4096
    n_mels: int = 64
    n_frames: int = 32
    seed: int = 1337

    def __post_init__(self) -> None:
        self.rng = np.random.default_rng(self.seed)
        X = np.zeros((self.n_samples, 1, self.n_mels, self.n_frames), dtype=np.float32)
        y = np.zeros((self.n_samples,), dtype=np.int64)
        for i in range(self.n_samples):
            is_snore = self.rng.random() < 0.5
            X[i, 0] = self._snore() if is_snore else self._non_snore()
            y[i] = 1 if is_snore else 0
        # Standardize to unit variance, match what AVAudioEngine pipeline
        # will deliver (log-mel ≈ centered around 0).
        X -= X.mean()
        X /= X.std() + 1e-6
        self.X = torch.from_numpy(X)
        self.y = torch.from_numpy(y)

    def _pink_noise_mel(self) -> np.ndarray:
        # Pink-ish: 1/f rolloff over mel bins
        rolloff = 1.0 / (np.arange(self.n_mels) + 1.0) ** 0.5
        floor = self.rng.normal(0, 0.4, size=(self.n_mels, self.n_frames))
        floor *= rolloff[:, None]
        return floor.astype(np.float32)

    def _snore(self) -> np.ndarray:
        m = self._pink_noise_mel()
        # Periodic burst envelope across frames (~0.3-0.6 Hz cycle)
        cycle_frames = self.rng.integers(8, 20)  # frames per cycle
        phase = self.rng.integers(0, cycle_frames)
        env = np.zeros(self.n_frames, dtype=np.float32)
        for f in range(self.n_frames):
            if (f + phase) % cycle_frames < 4:
                # active burst — Hann-shaped within burst
                pos = ((f + phase) % cycle_frames) / 3.0
                env[f] = np.sin(np.pi * pos) ** 2
        # Place burst in the low-mel region (bins 4..18 ≈ 50-500 Hz)
        low_band = slice(4, 18)
        gain = 1.5 + self.rng.random() * 1.5
        m[low_band, :] += gain * env[None, :] * (1.0 + 0.3 * self.rng.normal(size=(14, self.n_frames)))
        return m

    def _non_snore(self) -> np.ndarray:
        m = self._pink_noise_mel()
        # Maybe a transient (broadband, 1-3 frames)
        if self.rng.random() < 0.4:
            t = self.rng.integers(0, self.n_frames - 3)
            bin_centre = self.rng.integers(20, self.n_mels - 4)
            m[bin_centre - 4 : bin_centre + 4, t : t + 3] += 1.5 + self.rng.normal(size=(8, 3))
        return m

    def __len__(self) -> int:
        return self.n_samples

    def __getitem__(self, idx: int):
        return self.X[idx], self.y[idx]
