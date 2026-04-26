"""Export a trained TinyTransformer to Core ML `.mlpackage`.

Produces a model matching the M6 Swift contract:
  * input tensor name  = `features`
  * output tensor name = `logits`
  * input shape        = (1, seq_len=16, feature_dim=9)
  * output shape       = (1, num_classes=4)

`coremltools` is optional. `--dry-run` skips the Core ML conversion and only
exercises the torch.jit.trace path, which is what CI runs.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import torch

from training.configs.tiny_transformer import (
    FEATURE_DIM,
    INPUT_NAME,
    NUM_CLASSES,
    OUTPUT_NAME,
    SEQ_LEN,
    TinyTransformerConfig,
)
from training.models.tiny_transformer import TinyTransformer


def trace_model(cfg: TinyTransformerConfig, checkpoint: Path) -> torch.jit.ScriptModule:
    # Enforce contract at trace time so drift is caught in CI.
    assert cfg.seq_len == SEQ_LEN, "seq_len drifted from M6 contract"
    assert cfg.feature_dim == FEATURE_DIM, "feature_dim drifted from M6 contract"
    assert cfg.num_classes == NUM_CLASSES, "num_classes drifted from M6 contract"

    model = TinyTransformer(cfg)
    if checkpoint.exists():
        state = torch.load(checkpoint, map_location="cpu")
        model.load_state_dict(state["model"] if "model" in state else state)
    model.eval()
    example = torch.zeros(1, cfg.seq_len, cfg.feature_dim)
    return torch.jit.trace(model, example, check_trace=False)


def export_coreml(
    traced: torch.jit.ScriptModule,
    cfg: TinyTransformerConfig,
    out: Path,
    version: str = "0.1.0",
) -> None:
    try:
        import coremltools as ct
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(
            "coremltools not installed. Run: pip install '.[export]'"
        ) from exc

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name=INPUT_NAME,
                shape=(1, cfg.seq_len, cfg.feature_dim),
            )
        ],
        minimum_deployment_target=ct.target.iOS17,
    )

    # Rename the single output to the canonical contract name so Swift's
    # CoreMLStageInferenceModel finds it via the fast path.
    spec = mlmodel.get_spec()
    if spec.description.output:
        current = spec.description.output[0].name
        if current != OUTPUT_NAME:
            ct.utils.rename_feature(spec, current, OUTPUT_NAME)
            mlmodel = ct.models.MLModel(spec, weights_dir=mlmodel.weights_dir)

    mlmodel.short_description = (
        f"Sleep stager — tiny transformer (wake/light/deep/rem) v{version}"
    )
    mlmodel.version = version
    mlmodel.author = "Sleep Tracker"
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    print(f"Exported Core ML model → {out}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--checkpoint", type=Path, default=Path("runs/latest.pt"))
    p.add_argument("--out", type=Path, default=Path("runs/SleepStager.mlpackage"))
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Trace the model and print shapes without running Core ML conversion.",
    )
    p.add_argument("--version", default="0.1.0")
    args = p.parse_args()

    cfg = TinyTransformerConfig()
    traced = trace_model(cfg, args.checkpoint)

    if args.dry_run:
        example = torch.zeros(1, cfg.seq_len, cfg.feature_dim)
        with torch.no_grad():
            out = traced(example)
        print(
            f"[dry-run] input={INPUT_NAME} shape={tuple(example.shape)} "
            f"output={OUTPUT_NAME} shape={tuple(out.shape)} "
            f"classes={cfg.num_classes}"
        )
        return

    try:
        import coremltools  # noqa: F401
    except ImportError:
        print(
            "[export] coremltools unavailable in this environment. "
            "Install with: pip install coremltools. "
            "Skipping Core ML export; trace succeeded."
        )
        return

    export_coreml(traced, cfg, args.out, version=args.version)


if __name__ == "__main__":
    main()
