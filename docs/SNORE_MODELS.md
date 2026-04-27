# Snore detection — open-source paths

Two ways to get a stronger snore detector than the synthetic baseline.

## Option A — Fine-tune our small CNN on ESC-50 (recommended starter)

ESC-50 (Karol Piczak) ships a `snoring` class with 40 clips and 49 other
environmental classes for the negatives. CC BY-NC 3.0 — research / personal
use only; do not bundle the dataset.

```bash
cd python
python3 -m training.train_snore_cnn --dataset esc50 --epochs 30 \
    --out runs --val-fold 5
# Or with a pre-extracted copy:
python3 -m training.train_snore_cnn --dataset esc50 \
    --esc50-path /path/to/ESC-50-master --epochs 30 --out runs
python3 -m training.export.export_snore --ckpt runs/snore_latest.pt \
    --out runs/SnoreDetector.mlpackage
```

The script does fold-based hold-out (default `--val-fold 5`) and a
SpecAugment-lite frequency/time mask. With 30 epochs you should land
~88-93 % balanced accuracy on the held-out fold. The exported
`.mlpackage` drops straight into `apple/SleepKit/Sources/SleepKit/Models/`
and is auto-loaded by `SnoreDetector`.

## Option B — Replace the encoder with YAMNet or PANNs

If you want production-grade audio embeddings without collecting new data:

| Model | License | What you get | How to use |
|---|---|---|---|
| **YAMNet** (TF Hub) | Apache 2.0 | 521-class AudioSet head, "Snoring" class is index 38, returns scores per 0.96 s window | Convert via `coremltools` from the official `.tflite`, or use Apple's published [`AudioSet`](https://developer.apple.com/documentation/createmlcomponents) example |
| **PANNs CNN10/CNN14** (Qiuqiang Kong) | MIT | 527-class AudioSet head, top-K Snoring scores per second | Convert PyTorch checkpoint via `coremltools.convert`; or fine-tune the last layer on ESC-50 |
| **AST** (MIT, Yuan Gong) | BSD-3 | Transformer on AudioSet, strong but ~80 MB | Fine-tune last block on ESC-50 + record-your-own snores; quantize to 8-bit for Core ML |

Recommended path if you want to ship the strongest baseline today:

1. Download YAMNet from TF Hub.
2. Run it on a few real overnight recordings to confirm the AudioSet
   "Snoring" head fires reasonably on your data.
3. Convert to Core ML via the standard TF → CoreML path:
   ```bash
   pip install coremltools tensorflow
   python3 -c "
   import tensorflow_hub as hub, coremltools as ct, tensorflow as tf
   m = hub.load('https://tfhub.dev/google/yamnet/1')
   # wrap & convert — see Apple sample 'Classifying Sounds in an Audio File'
   "
   ```
4. Drop the `.mlpackage` next to `SnoreDetector.mlpackage` and have
   `SnoreDetector` read just the "Snoring" / "Snore" class scores.

This avoids training on synthetic data entirely.

## What our shipped baseline does today

- Pure-PyTorch tiny CNN, 3 conv blocks, 64×32 log-mel input.
- Trained on synthetic mel patterns (low-frequency periodic bursts vs
  pink noise + transients) by default.
- Real-data training is now opt-in via `--dataset esc50`.
- Inference is wrapped behind `SnoreDetector` (Swift) which thresholds
  the positive-class probability at 0.6 with a 3-of-5 hysteresis.

## Compliance notes

- Audio is captured with `AVAudioEngine`, converted to log-mel **in
  memory only**, scored, and discarded. No PCM is written to disk.
- ESC-50 is **not** redistributed in this repo. Users must download it
  themselves and accept its license.
- AudioSet itself is not redistributable as audio; using YAMNet/PANNs
  weights pretrained on AudioSet is fine because the upstream authors
  release the weights under permissive licenses.
