"""Train + export snore detector to Core ML.

Run from repo root through the wrapper: `scripts/train_and_export_model.sh`
which uses the Python 3.11 venv. Or directly inside that venv:

    python -m training.train_snore_cnn --out runs --epochs 8
"""
from __future__ import annotations

import argparse
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from training.data.snore_dataset import SnoreDataset
from training.models.snore_cnn import SnoreCNN, SnoreCNNConfig


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, default=Path("runs"))
    p.add_argument("--epochs", type=int, default=8)
    p.add_argument("--samples", type=int, default=4096)
    args = p.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    cfg = SnoreCNNConfig(epochs=args.epochs)
    torch.manual_seed(cfg.seed)

    train_ds = SnoreDataset(n_samples=args.samples, seed=cfg.seed)
    val_ds = SnoreDataset(n_samples=args.samples // 4, seed=cfg.seed + 1)
    train_dl = DataLoader(train_ds, batch_size=cfg.batch_size, shuffle=True)
    val_dl = DataLoader(val_ds, batch_size=cfg.batch_size)

    model = SnoreCNN(cfg)
    opt = torch.optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)

    for epoch in range(cfg.epochs):
        model.train()
        total = 0.0
        n = 0
        for x, y in train_dl:
            opt.zero_grad()
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            loss.backward()
            opt.step()
            total += float(loss) * x.size(0)
            n += x.size(0)
        train_loss = total / max(n, 1)

        model.eval()
        correct = 0
        seen = 0
        with torch.no_grad():
            for x, y in val_dl:
                pred = model(x).argmax(dim=-1)
                correct += int((pred == y).sum())
                seen += x.size(0)
        val_acc = correct / max(seen, 1)
        print(f"epoch {epoch:02d}  train_loss={train_loss:.4f}  val_acc={val_acc:.3f}")

    out_pt = args.out / "snore_latest.pt"
    torch.save({"state_dict": model.state_dict(), "cfg": cfg.__dict__}, out_pt)
    print(f"saved checkpoint → {out_pt}")


if __name__ == "__main__":
    main()
