"""Tiny transformer for per-window sleep-stage classification.

Input shape : (batch, seq_len, feature_dim)
Output shape: (batch, num_classes)  — logits over [wake, light, deep, rem].

The architecture is intentionally hand-rolled rather than wrapping
``nn.TransformerEncoderLayer``: that built-in goes through
``F.multi_head_attention_forward``, which uses tracing branches
``coremltools`` cannot lower (e.g. integer reshapes inside a list build).
The single-head attention block below is a few lines of pointwise math and
matmul, which converts cleanly to a Core ML ML Program.
"""
from __future__ import annotations

import math

import torch
import torch.nn as nn
import torch.nn.functional as F

from training.configs.tiny_transformer import TinyTransformerConfig


class _AttentionBlock(nn.Module):
    """Multi-head self-attention block with residual + LayerNorm.

    Pre-norm formulation. Avoids ``nn.MultiheadAttention`` so that
    ``coremltools`` can lower the graph.
    """

    def __init__(self, d_model: int, n_heads: int, ff_dim: int, dropout: float) -> None:
        super().__init__()
        assert d_model % n_heads == 0, "d_model must be divisible by n_heads"
        self.d_model = d_model
        self.n_heads = n_heads
        self.head_dim = d_model // n_heads
        self.scale = 1.0 / math.sqrt(self.head_dim)

        self.norm1 = nn.LayerNorm(d_model)
        self.qkv = nn.Linear(d_model, 3 * d_model)
        self.out_proj = nn.Linear(d_model, d_model)

        self.norm2 = nn.LayerNorm(d_model)
        self.ff = nn.Sequential(
            nn.Linear(d_model, ff_dim),
            nn.GELU(),
            nn.Linear(ff_dim, d_model),
        )
        self.dropout = nn.Dropout(dropout)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (B, T, D)
        b, t, d = x.shape
        residual = x
        h = self.norm1(x)
        qkv = self.qkv(h)  # (B, T, 3D)
        q, k, v = qkv.chunk(3, dim=-1)  # (B, T, D) each

        def split_heads(t_in: torch.Tensor) -> torch.Tensor:
            # (B, T, D) -> (B, n_heads, T, head_dim)
            return t_in.reshape(b, t, self.n_heads, self.head_dim).transpose(1, 2)

        q = split_heads(q)
        k = split_heads(k)
        v = split_heads(v)

        # (B, H, T, T)
        attn = torch.matmul(q, k.transpose(-2, -1)) * self.scale
        attn = F.softmax(attn, dim=-1)
        out = torch.matmul(attn, v)  # (B, H, T, head_dim)
        out = out.transpose(1, 2).reshape(b, t, d)
        out = self.out_proj(out)
        x = residual + self.dropout(out)

        # Feed-forward.
        residual2 = x
        h2 = self.norm2(x)
        h2 = self.ff(h2)
        x = residual2 + self.dropout(h2)
        return x


class TinyTransformer(nn.Module):
    """Tiny encoder + mean-pool + linear head."""

    def __init__(self, cfg: TinyTransformerConfig) -> None:
        super().__init__()
        self.cfg = cfg
        self.proj = nn.Linear(cfg.feature_dim, cfg.d_model)
        self.pos = nn.Parameter(torch.zeros(1, cfg.seq_len, cfg.d_model))
        self.blocks = nn.ModuleList([
            _AttentionBlock(cfg.d_model, cfg.n_heads, cfg.ff_dim, cfg.dropout)
            for _ in range(cfg.n_layers)
        ])
        self.norm = nn.LayerNorm(cfg.d_model)
        self.head = nn.Linear(cfg.d_model, cfg.num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (B, T, F)
        h = self.proj(x) + self.pos
        for block in self.blocks:
            h = block(h)
        h = self.norm(h.mean(dim=1))  # mean-pool over sequence
        return self.head(h)
