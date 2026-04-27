"""Export trained SnoreCNN to .mlpackage.

Usage (inside Python 3.11 venv):
    python -m training.export.export_snore --checkpoint runs/snore_latest.pt \
        --out runs/SnoreDetector.mlpackage --version 0.1.0
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import coremltools as ct
import torch

from training.models.snore_cnn import SnoreCNN, SnoreCNNConfig

INPUT_NAME = "logMel"
OUTPUT_NAME = "logits"
RESOURCE_NAME = "SnoreDetector"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--version", type=str, default="0.1.0")
    args = p.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    cfg = SnoreCNNConfig(**ckpt["cfg"])
    model = SnoreCNN(cfg)
    model.load_state_dict(ckpt["state_dict"])
    model.eval()

    example = torch.randn(*model.input_shape())
    traced = torch.jit.trace(model, example)

    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name=INPUT_NAME, shape=example.shape, dtype=float)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )

    spec = ml.get_spec()
    out_features = list(spec.description.output)
    if out_features and out_features[0].name != OUTPUT_NAME:
        ct.utils.rename_feature(spec, out_features[0].name, OUTPUT_NAME)
        ml = ct.models.MLModel(spec, weights_dir=ml.weights_dir)

    ml.author = "Sleep Tracker"
    ml.short_description = "Snore-like acoustic event detector. Counts only; no audio retained."
    ml.version = args.version

    if args.out.exists():
        shutil.rmtree(args.out)
    ml.save(str(args.out))
    print(f"exported → {args.out}")


if __name__ == "__main__":
    main()
