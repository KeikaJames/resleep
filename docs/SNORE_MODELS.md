# Snore detection — using Apple's built-in classifier

## What ships today (no model file needed)

`SleepKit/Health/SnoreDetector.swift` is now backed by Apple's
**`SNClassifySoundRequest` with `SNClassifierIdentifier.version1`**
(SoundAnalysis framework, iOS 15+). This classifier ships **inside the
OS**, recognizes ~300 environmental sound classes including `snoring`,
and is the same classifier used by Apple's first-party features.

What this means:

- **Zero model weights in the app bundle.** Nothing to train, nothing to
  download, nothing to bundle. The shipped binary stays small.
- **Apple-quality recognition** out of the box, calibrated by Apple on a
  large internal dataset. No synthetic-data limitation.
- **Privacy unchanged.** Audio still flows AVAudioEngine →
  SNAudioStreamAnalyzer **in memory only**, never persisted, never
  uploaded. Only a Float32 confidence score for the `snoring` class
  leaves the audio pipeline.
- **License: free.** SoundAnalysis is part of iOS — no third-party
  licensing or attribution required.

Threshold is `0.6` on `snoring.confidence`, with a 1.5 s cooldown
between counted events to avoid double-counting one snore that spans
two analysis windows.

## When you might want to swap in your own model

Only if you need:

- A custom class set (e.g. distinguish snoring vs sleep apnea events).
- Non-iOS targets (watchOS, macOS Catalyst — the on-device classifier
  is iOS-only).

In those cases, the previous Core ML pipeline still exists in git
history and the training scripts under `python/training/` still work.
Open-source paths kept for reference:

| Path | License | Notes |
|---|---|---|
| ESC-50 + our small CNN | CC BY-NC 3.0 | 40 snoring clips; balanced negatives. Training in `python/training/train_snore_cnn.py --dataset esc50`. |
| YAMNet (TF Hub) | Apache 2.0 | AudioSet 521 classes, "Snoring" #38. |
| PANNs CNN10/14 | MIT | AudioSet 527 classes, "Snoring" included. |
| AST | BSD-3 | Stronger transformer; ~80 MB. |

For production iOS the SoundAnalysis built-in is the right call.

