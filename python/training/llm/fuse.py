"""Fuse trained Sleep-AI LoRA adapters into a deployable MLX model.

After `train_lora.py` produces an `adapters/` directory, this script
calls `mlx_lm.fuse` to merge those LoRA matrices back into the base
weights. The result is a self-contained MLX checkpoint that the iOS
app can load through `GemmaWeightsLocator` exactly like the original.

Run:

    python -m training.llm.fuse
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .configs import LoRAConfig


def main() -> None:
    cfg = LoRAConfig()

    if not (cfg.adapter_dir / "adapters.safetensors").exists() and \
       not list(cfg.adapter_dir.glob("*adapters*.safetensors")):
        sys.exit(
            f"No adapters found in {cfg.adapter_dir}. "
            f"Run `python -m training.llm.train_lora` first."
        )

    cfg.fused_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable, "-m", "mlx_lm.fuse",
        "--model",        cfg.base_model,
        "--adapter-path", str(cfg.adapter_dir),
        "--save-path",    str(cfg.fused_dir),
    ]
    print("$", " ".join(cmd), "\n")
    rc = subprocess.call(cmd)
    if rc != 0:
        sys.exit(rc)

    print(
        f"\nFused model written to {cfg.fused_dir}\n"
        "Copy that directory to the device or point\n"
        "  CIRCADIA_GEMMA_DIR\n"
        "at it before launching the app."
    )


if __name__ == "__main__":
    main()
