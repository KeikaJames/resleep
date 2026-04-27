"""Snore detection: tiny CNN over log-mel spectrograms.

Architecture
------------
Input  : (batch, 1, 64, 32)  log-mel spectrogram (64 mel bins × 32 frames ≈ 1 s)
Output : (batch, 2)          [non_snore, snore] logits

Sized for on-device inference (<200 KB after Core ML conversion).

Training
--------
We train on a synthetic mixture:
- "snore" = periodic low-frequency energy bumps (~0.3-0.5 Hz repetition,
            energy concentrated in 50-500 Hz band) + pink-noise floor
- "non_snore" = white/pink noise, occasional broadband transients
  (mimicking environmental sound: rustle, distant traffic)

This is calibrated against published snore acoustic descriptors:
- Pevernagie et al. (2010) "The acoustics of snoring." Sleep Med Rev.
- Lee et al. (2014) "Snoring sounds predict obstruction sites and surgical
  response in patients with obstructive sleep apnea hypopnea syndrome."

The model is a coarse "snore-like" detector — it counts events and
emits booleans. **No audio is ever stored.** The downstream consumer
sees only event counts per minute.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Tuple

import torch
import torch.nn as nn


@dataclass
class SnoreCNNConfig:
    n_mels: int = 64
    n_frames: int = 32
    num_classes: int = 2

    # training
    lr: float = 1e-3
    batch_size: int = 128
    epochs: int = 8
    weight_decay: float = 1e-4
    seed: int = 1337


class SnoreCNN(nn.Module):
    """3-block CNN with stride-2 pooling and a 2-class head."""

    def __init__(self, cfg: SnoreCNNConfig = SnoreCNNConfig()) -> None:
        super().__init__()
        self.cfg = cfg

        def conv_block(cin: int, cout: int) -> nn.Sequential:
            return nn.Sequential(
                nn.Conv2d(cin, cout, kernel_size=3, padding=1),
                nn.BatchNorm2d(cout),
                nn.ReLU(inplace=True),
                nn.MaxPool2d(kernel_size=2, stride=2),
            )

        self.b1 = conv_block(1, 8)
        self.b2 = conv_block(8, 16)
        self.b3 = conv_block(16, 32)
        # After 3 stride-2 pools: (64, 32) → (8, 4)
        self.pool = nn.AdaptiveAvgPool2d((1, 1))
        self.head = nn.Linear(32, cfg.num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (B, 1, n_mels, n_frames)
        x = self.b1(x)
        x = self.b2(x)
        x = self.b3(x)
        x = self.pool(x).squeeze(-1).squeeze(-1)  # (B, 32)
        return self.head(x)

    def input_shape(self) -> Tuple[int, int, int, int]:
        return (1, 1, self.cfg.n_mels, self.cfg.n_frames)
