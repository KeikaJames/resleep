"""Configuration for the Sleep-AI fine-tune.

Production uses one formal model tier:

    • production — Alibaba Tongyi Lab Qwen3-4B, 4-bit + Circadia LoRA

The smaller Gemma / Qwen 1.7B presets remain only for reproducible
experiments. They are not user-visible and are not bundled in release
builds because they did not pass the offline behavior gate.

A single dataclass owns every knob so the train/fuse scripts stay small
and the values stay version-controlled. We deliberately default to
**conservative LoRA** (rank=8, alpha=16, dropout=0.05) — the goal is
behavioral nudging, not capacity. We're not teaching the base model new
facts; we're teaching it to stay in scope.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


PRODUCTION_TIER = "production"


@dataclass
class LoRAConfig:
    # ── Base model ──────────────────────────────────────────────────────
    # Hugging Face repo id of the base instruct model. Must already be in
    # MLX format (the `mlx-community/...` mirrors are the easiest path).
    #
    # NOTE: We use Gemma-2-2B-IT here rather than Gemma-3n. mlx-lm's
    # `models/gemma3n.py` has a known bug sanitizing the quantized
    # 3n variant (`KeyError: 'model'` during weight loading). Gemma-2-2B
    # is well-supported by mlx-lm.lora and is the right size for a
    # behavioral-only fine-tune.
    base_model: str = "mlx-community/gemma-2-2b-it-4bit"

    # ── Dataset ─────────────────────────────────────────────────────────
    dataset_dir: Path = Path("python/training/llm/dataset")

    # ── LoRA hyperparameters ────────────────────────────────────────────
    lora_layers: int = 16          # how many transformer blocks to adapt; -1 means all
    lora_rank: int   = 8
    lora_alpha: int  = 16
    lora_dropout: float = 0.05
    fine_tune_type: str = "lora"   # lora | dora | full
    optimizer: str = "adam"

    # ── Training schedule ───────────────────────────────────────────────
    batch_size: int  = 2
    iters: int       = 600
    learning_rate: float = 1e-4
    grad_checkpoint: bool = True
    grad_accumulation_steps: int = 2
    mask_prompt: bool = True
    max_seq_length: int = 2048
    save_every: int = 200
    steps_per_eval: int = 200
    steps_per_report: int = 25
    seed: int = 1729

    # ── Output paths ────────────────────────────────────────────────────
    adapter_dir: Path = Path("python/training/llm/adapters")
    fused_dir: Path   = Path("python/training/llm/fused-circadia-sleep")

    # Optional: list of layer-name patterns to target with LoRA. None →
    # mlx-lm's default ("self_attn.q_proj", "self_attn.v_proj", etc.).
    target_modules: list[str] = field(default_factory=list)


# ── Tier presets ────────────────────────────────────────────────────────
#
# These are the ready-to-train configs the build phase + iOS app expect.
# Each tier writes its adapter and fused directory under a stable name so
# the Xcode `Embed Circadia LLM` script can find them. Adjust `iters` per
# tier: smaller models benefit from a few more steps, larger models need
# fewer to avoid over-fitting on the small persona dataset.

_PRODUCTION_CONFIG = LoRAConfig(
    base_model="mlx-community/Qwen3-4B-Instruct-2507-4bit",
    adapter_dir=Path("python/training/llm/adapters-qwen-4b"),
    fused_dir=Path("python/training/llm/fused-circadia-sleep-qwen-4b"),
    iters=400,           # larger model, fewer steps to avoid overfit
    batch_size=1,        # 4B in 4-bit is tight on 16GB Macs
    grad_checkpoint=True,
)

TIERS: dict[str, LoRAConfig] = {
    "production": _PRODUCTION_CONFIG,
    # Backwards-compatible alias for previous scripts and CI logs. Do not
    # use this name in user-facing copy.
    "qwen-pro": _PRODUCTION_CONFIG,
    "gemma": LoRAConfig(
        base_model="mlx-community/gemma-2-2b-it-4bit",
        adapter_dir=Path("python/training/llm/adapters-gemma"),
        fused_dir=Path("python/training/llm/fused-circadia-sleep"),
        iters=600,
    ),
    "qwen-instant": LoRAConfig(
        base_model="mlx-community/Qwen3-1.7B-4bit",
        adapter_dir=Path("python/training/llm/adapters-qwen-1_7b"),
        fused_dir=Path("python/training/llm/fused-circadia-sleep-qwen-1_7b"),
        iters=200,           # validation loss rises after 200 on current SFT set
    ),
    "qwen-instant-full": LoRAConfig(
        base_model="mlx-community/Qwen3-1.7B-bf16",
        adapter_dir=Path("python/training/llm/adapters-qwen-1_7b-full"),
        fused_dir=Path("python/training/llm/fused-circadia-sleep-qwen-1_7b-full"),
        fine_tune_type="full",
        lora_layers=-1,
        batch_size=1,
        iters=400,
        learning_rate=2e-6,
        grad_accumulation_steps=4,
        steps_per_eval=100,
        save_every=100,
        grad_checkpoint=True,
    ),
}


def config_for(tier: str) -> LoRAConfig:
    """Look up a `LoRAConfig` by tier name."""
    if tier not in TIERS:
        raise KeyError(
            f"Unknown LoRA tier '{tier}'. Available: {sorted(TIERS.keys())}"
        )
    return TIERS[tier]
