# Sleep Training

Offline training + Core ML export pipeline for the Sleep Tracker tiny-transformer.

## Install
```bash
cd python
pip install -e '.[dev]'
# For export:
pip install -e '.[export]'
```

## Feature contract (must match Rust + Swift)
Per window, feature vector is the concatenation of:
| index | feature        | unit |
|-------|----------------|------|
| 0     | hr_mean        | bpm |
| 1     | hr_std         | bpm |
| 2     | hr_slope       | bpm/s |
| 3     | accel_mean     | g |
| 4     | accel_std      | g |
| 5     | accel_energy   | g² |
| 6     | event_count_like_snore | count/window |
| 7..   | hrv_like_features (placeholder) | — |

`feature_dim` defaults to 32 (zero-padded); `seq_len` = 16 windows.

## Train (placeholder)
```bash
python -m training.train_tiny_transformer --epochs 1
```
The current training loop runs on synthetic data so the plumbing is
exercised end-to-end. Replace `training.data.dataset.SyntheticStageDataset`
with a real loader once the labelling pipeline is ready.

## Export to Core ML
```bash
python -m training.export.export_coreml --checkpoint runs/latest.pt --out runs/SleepStager.mlpackage
```
The exported `.mlpackage` is what the iOS app loads via
`CoreMLStagingModel(modelURL:)`.

## Non-goals
- No backend/API.
- No cloud storage.
- No user PII in training data.
