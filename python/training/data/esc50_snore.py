"""ESC-50 snore loader.

ESC-50 (Karol Piczak, CC BY-NC 3.0 with explicit research-use clause)
contains a "snoring" class (target=28) with 40 clips. We pair these
positives with a balanced random sample of the other 49 classes as
negatives, compute log-mel spectrograms with the same shape the
on-device pipeline produces, and expose the result as a torch Dataset
with the same `(X, y)` interface as :class:`SnoreDataset`.

Download once via:

    python -m training.data.esc50_snore --download <dir>

or pass a path to a pre-extracted ESC-50 master folder (the one
containing `audio/` and `meta/esc50.csv`).

NOTE: ESC-50 is licensed CC BY-NC 3.0. Use only for research/personal
fine-tuning. Do not bundle the raw dataset in the shipped app.
"""
from __future__ import annotations

import argparse
import csv
import io
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

import numpy as np
import torch
from torch.utils.data import Dataset

ESC50_URL = "https://github.com/karoldvl/ESC-50/archive/master.zip"
SNORE_TARGET = 28  # ESC-50 class id for "snoring"


def download_esc50(dest: Path) -> Path:
    """Download + extract ESC-50 to <dest>/ESC-50-master and return that path."""
    dest = Path(dest)
    root = dest / "ESC-50-master"
    if (root / "meta" / "esc50.csv").exists():
        return root
    dest.mkdir(parents=True, exist_ok=True)
    print(f"downloading ESC-50 → {dest} (~600 MB)…")
    with urllib.request.urlopen(ESC50_URL) as resp:  # noqa: S310 trusted GitHub URL
        data = resp.read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(dest)
    return root


def _load_meta(esc50_root: Path) -> List[Tuple[str, int]]:
    out: List[Tuple[str, int]] = []
    with (esc50_root / "meta" / "esc50.csv").open() as f:
        for row in csv.DictReader(f):
            out.append((row["filename"], int(row["target"])))
    return out


def _wav_to_logmel(path: Path, n_mels: int, n_frames: int, sr: int) -> np.ndarray:
    """Load wav, mono, 1 s window, log-mel.

    Imports torchaudio lazily to keep CPU CI light when the dataset isn't
    being used.
    """
    import torchaudio  # type: ignore
    import torchaudio.transforms as T  # type: ignore

    wav, file_sr = torchaudio.load(str(path))
    if wav.dim() > 1:
        wav = wav.mean(dim=0, keepdim=True)
    if file_sr != sr:
        wav = torchaudio.functional.resample(wav, file_sr, sr)
    # ESC-50 clips are 5 s; pick a deterministic 1 s window.
    target_len = sr  # 1 s
    if wav.size(-1) >= target_len:
        wav = wav[..., :target_len]
    else:
        pad = target_len - wav.size(-1)
        wav = torch.nn.functional.pad(wav, (0, pad))
    n_fft = 1024
    hop = max(1, target_len // n_frames)
    mel = T.MelSpectrogram(
        sample_rate=sr,
        n_fft=n_fft,
        hop_length=hop,
        n_mels=n_mels,
        f_min=20.0,
        f_max=sr / 2,
    )(wav)
    # crop / pad to exactly n_frames
    if mel.size(-1) >= n_frames:
        mel = mel[..., :n_frames]
    else:
        mel = torch.nn.functional.pad(mel, (0, n_frames - mel.size(-1)))
    log_mel = torch.log(mel + 1e-6)
    return log_mel.squeeze(0).numpy().astype(np.float32)


@dataclass
class ESC50SnoreDataset(Dataset):
    esc50_root: Path
    n_mels: int = 64
    n_frames: int = 32
    sr: int = 16_000
    seed: int = 1337
    val_fold: int | None = None  # if set, return only this fold; else exclude it
    held_out: bool = False  # toggles the meaning of val_fold
    augment: bool = True

    def __post_init__(self) -> None:
        rng = np.random.default_rng(self.seed)
        meta = _load_meta(Path(self.esc50_root))

        def keep(filename: str) -> bool:
            if self.val_fold is None:
                return True
            fold = int(filename.split("-")[0])
            return (fold == self.val_fold) if self.held_out else (fold != self.val_fold)

        positives = [(f, t) for f, t in meta if t == SNORE_TARGET and keep(f)]
        negatives_pool = [(f, t) for f, t in meta if t != SNORE_TARGET and keep(f)]
        rng.shuffle(negatives_pool)
        negatives = negatives_pool[: max(len(positives), 1) * 4]

        items = [(f, 1) for f, _ in positives] + [(f, 0) for f, _ in negatives]
        rng.shuffle(items)

        audio_dir = Path(self.esc50_root) / "audio"
        X = np.zeros((len(items), 1, self.n_mels, self.n_frames), dtype=np.float32)
        y = np.zeros((len(items),), dtype=np.int64)
        for i, (fname, label) in enumerate(items):
            X[i, 0] = _wav_to_logmel(audio_dir / fname, self.n_mels, self.n_frames, self.sr)
            y[i] = label

        # Standardize globally (matches on-device log-mel ≈ 0-centered).
        X -= X.mean()
        X /= X.std() + 1e-6

        self.X = torch.from_numpy(X)
        self.y = torch.from_numpy(y)
        self._rng = rng

    def __len__(self) -> int:
        return self.X.size(0)

    def __getitem__(self, idx: int):
        x = self.X[idx]
        if self.augment and self._rng.random() < 0.5:
            # SpecAugment-lite: zero a small time / freq band.
            xx = x.clone()
            t = int(self._rng.integers(0, max(1, self.n_frames // 4)))
            t0 = int(self._rng.integers(0, max(1, self.n_frames - t)))
            xx[..., t0 : t0 + t] = 0.0
            f = int(self._rng.integers(0, max(1, self.n_mels // 4)))
            f0 = int(self._rng.integers(0, max(1, self.n_mels - f)))
            xx[..., f0 : f0 + f, :] = 0.0
            x = xx
        return x, self.y[idx]


def _cli() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--download", type=Path, help="download ESC-50 to this directory")
    args = p.parse_args()
    if args.download:
        root = download_esc50(args.download)
        print(f"ESC-50 ready at {root}")


if __name__ == "__main__":
    _cli()
