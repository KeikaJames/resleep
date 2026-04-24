"""Minimal training loop for the tiny-transformer stager (synthetic data)."""
from __future__ import annotations

import argparse
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader

from training.configs.tiny_transformer import TinyTransformerConfig
from training.data.dataset import SyntheticStageDataset
from training.models.tiny_transformer import TinyTransformer


def train(cfg: TinyTransformerConfig, out_dir: Path) -> Path:
    torch.manual_seed(cfg.seed)
    ds = SyntheticStageDataset(
        n=1024,
        seq_len=cfg.seq_len,
        feature_dim=cfg.feature_dim,
        num_classes=cfg.num_classes,
        seed=cfg.seed,
    )
    loader = DataLoader(ds, batch_size=cfg.batch_size, shuffle=True, drop_last=True)

    model = TinyTransformer(cfg)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    loss_fn = nn.CrossEntropyLoss()

    model.train()
    for epoch in range(cfg.epochs):
        running = 0.0
        n = 0
        for x, y in loader:
            opt.zero_grad()
            logits = model(x)
            loss = loss_fn(logits, y)
            loss.backward()
            opt.step()
            running += float(loss.item()) * x.size(0)
            n += x.size(0)
        print(f"epoch {epoch + 1}/{cfg.epochs}  loss={running / max(n, 1):.4f}")

    out_dir.mkdir(parents=True, exist_ok=True)
    ckpt_path = out_dir / "latest.pt"
    torch.save({"model": model.state_dict(), "cfg": cfg.__dict__}, ckpt_path)
    print(f"saved checkpoint → {ckpt_path}")
    return ckpt_path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--epochs", type=int, default=None)
    p.add_argument("--out", type=Path, default=Path("runs"))
    args = p.parse_args()

    cfg = TinyTransformerConfig()
    if args.epochs is not None:
        cfg.epochs = args.epochs
    train(cfg, args.out)


if __name__ == "__main__":
    main()
