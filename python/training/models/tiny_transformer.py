"""Tiny transformer for per-window sleep-stage classification.

Input shape : (batch, seq_len, feature_dim)
Output shape: (batch, num_classes)  — logits over [wake, light, deep, rem].

This is intentionally minimal. Once labelled data is available, swap in
stronger positional encodings or an RNN head as needed.
"""
from __future__ import annotations

import torch
import torch.nn as nn

from training.configs.tiny_transformer import TinyTransformerConfig


class TinyTransformer(nn.Module):
    def __init__(self, cfg: TinyTransformerConfig) -> None:
        super().__init__()
        self.cfg = cfg
        self.proj = nn.Linear(cfg.feature_dim, cfg.d_model)
        self.pos = nn.Parameter(torch.zeros(1, cfg.seq_len, cfg.d_model))
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=cfg.d_model,
            nhead=cfg.n_heads,
            dim_feedforward=cfg.ff_dim,
            dropout=cfg.dropout,
            batch_first=True,
            activation="gelu",
        )
        self.encoder = nn.TransformerEncoder(encoder_layer, num_layers=cfg.n_layers)
        self.norm = nn.LayerNorm(cfg.d_model)
        self.head = nn.Linear(cfg.d_model, cfg.num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (B, T, F)
        h = self.proj(x) + self.pos
        h = self.encoder(h)
        h = self.norm(h.mean(dim=1))  # mean-pool over sequence
        return self.head(h)
