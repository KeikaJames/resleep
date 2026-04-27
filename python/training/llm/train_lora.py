"""Train Sleep-AI LoRA adapters with mlx-lm.

This script is a thin, opinionated wrapper around `mlx_lm.lora.train` —
it loads our `LoRAConfig`, materializes a config file in the format
mlx-lm expects, and shells out so users get the upstream tool's
streaming progress + checkpointing for free.

Run on Apple Silicon (M-series) with at least 24 GB unified memory:

    pip install -r python/requirements.txt
    python -m training.llm.build_dataset
    python -m training.llm.train_lora

Note: mlx-lm fine-tunes the base model in-place against a frozen
checkpoint. We do not modify the base weights — only the adapter
matrices in `adapter_dir` are written.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from .configs import LoRAConfig


def _write_yaml_config(cfg: LoRAConfig, dest: Path) -> Path:
    """Write the YAML config file mlx-lm expects.

    We write JSON-as-YAML (valid YAML is a JSON superset) so we don't
    need a yaml dependency.
    """
    payload = {
        "model": cfg.base_model,
        "train": True,
        "data": str(cfg.dataset_dir),
        "seed": cfg.seed,
        "iters": cfg.iters,
        "batch_size": cfg.batch_size,
        "learning_rate": cfg.learning_rate,
        "grad_checkpoint": cfg.grad_checkpoint,
        "adapter_path": str(cfg.adapter_dir),
        "fine_tune_type": "lora",
        "num_layers": cfg.lora_layers,
        "lora_parameters": {
            "rank": cfg.lora_rank,
            "scale": float(cfg.lora_alpha) / cfg.lora_rank,
            "dropout": cfg.lora_dropout,
        },
        "save_every": 200,
        "steps_per_eval": 200,
        "steps_per_report": 25,
    }
    if cfg.target_modules:
        payload["lora_parameters"]["keys"] = list(cfg.target_modules)

    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    return dest


def main() -> None:
    import argparse
    from .configs import config_for, TIERS

    parser = argparse.ArgumentParser(description="Train Sleep-AI LoRA adapters")
    parser.add_argument(
        "--tier",
        choices=sorted(TIERS.keys()),
        default="gemma",
        help="Which model tier to fine-tune (default: gemma).",
    )
    args = parser.parse_args()
    cfg = config_for(args.tier)

    if not (cfg.dataset_dir / "train.jsonl").exists():
        sys.exit(
            f"Dataset not found in {cfg.dataset_dir}. "
            f"Run `python -m training.llm.build_dataset` first."
        )

    cfg.adapter_dir.mkdir(parents=True, exist_ok=True)
    config_path = _write_yaml_config(cfg, cfg.adapter_dir / "config.yaml")

    print(f"\n=== Sleep-AI LoRA fine-tune ({args.tier}) ===")
    for k, v in asdict(cfg).items():
        print(f"  {k:18s} = {v}")
    print(f"  config_path        = {config_path}")
    print()

    # Spawn mlx-lm so its progress bars stream live to stdout.
    cmd = [sys.executable, "-m", "mlx_lm.lora", "--config", str(config_path)]
    print("$", " ".join(cmd), "\n")
    rc = subprocess.call(cmd)
    if rc != 0:
        sys.exit(rc)

    # Persist a copy of the dataset summary alongside the adapter so we
    # can audit later what the adapter was trained on.
    summary = {
        "tier": args.tier,
        "base_model": cfg.base_model,
        "iters": cfg.iters,
        "lora_rank": cfg.lora_rank,
        "lora_alpha": cfg.lora_alpha,
    }
    (cfg.adapter_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(f"\nAdapters written to {cfg.adapter_dir}")
    print(f"Next: `python -m training.llm.fuse --tier {args.tier}` to bake the adapter into a deployable model.")


if __name__ == "__main__":
    main()
