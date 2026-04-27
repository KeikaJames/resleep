"""Configuration for the Sleep-AI LoRA fine-tune.

A single dataclass owns every knob so the train/fuse scripts can stay
small and the values stay version-controlled. We deliberately default
to **conservative LoRA** (rank=8, alpha=16, dropout=0.05) — the goal is
behavioral nudging, not capacity. We're not teaching the base model new
facts; we're teaching it to stay in scope.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class LoRAConfig:
    # ── Base model ──────────────────────────────────────────────────────
    # Hugging Face repo id of the base instruct model. Must already be in
    # MLX format (the `mlx-community/...` mirrors are the easiest path).
    base_model: str = "mlx-community/gemma-3n-E2B-it-4bit"

    # ── Dataset ─────────────────────────────────────────────────────────
    dataset_dir: Path = Path("python/training/llm/dataset")

    # ── LoRA hyperparameters ────────────────────────────────────────────
    lora_layers: int = 16          # how many transformer blocks to adapt
    lora_rank: int   = 8
    lora_alpha: int  = 16
    lora_dropout: float = 0.05

    # ── Training schedule ───────────────────────────────────────────────
    batch_size: int  = 2
    iters: int       = 600
    learning_rate: float = 1e-4
    grad_checkpoint: bool = True
    seed: int = 1729

    # ── Output paths ────────────────────────────────────────────────────
    adapter_dir: Path = Path("python/training/llm/adapters")
    fused_dir: Path   = Path("python/training/llm/fused-circadia-sleep")

    # Optional: list of layer-name patterns to target with LoRA. None →
    # mlx-lm's default ("self_attn.q_proj", "self_attn.v_proj", etc.).
    target_modules: list[str] = field(default_factory=list)
