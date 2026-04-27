# Release C — v0.3.0

A focused release that takes Sleep from "scaffolded" to "submittable to App Store Review".

## What's new

### Algorithms
- **Cole-Kripke / Sadeh actigraphy ensemble** in Rust (`sleep-core/signal/actigraphy.rs`).
  60 s ENMO epochs → published 1992/1994 weight kernels → wake/sleep override that
  refines the model output (e.g. high motion + recent activity demotes a "deep"
  prediction to "wake"). Conservative override only kicks in after ≥ 9 epochs.
- **On-device snore detection** (Swift + Core ML). 16 kHz mic tap → 64-bin log-mel →
  small CNN classifier exported from `python/training/snore_cnn.py`. Outputs a
  per-second boolean event and a count. **Audio is never written to disk and
  never transmitted.** Off by default; toggleable in Settings.
- **On-device personalization head** (`SleepKit/Inference/PersonalizationService.swift`).
  Pure-Swift logistic SGD that adds a 4×9 correction matrix on top of the base
  stage probabilities. Labels are derived from the morning wake-up survey and
  persisted to `Application Support/SleepTracker/personalization.json` (capped
  at 5 000 labels). Toggleable; default ON.

### Product
- **Onboarding** (3 screens: welcome, privacy promise, HealthKit ask).
  Gated by `UserDefaults` key `onboarding.completed.v1`.
- **Trends tab** (Swift Charts): 30-night sleep score line + 7-night stage
  composition bar + averages card.
- **Wake-up survey sheet**: 1-5 quality, alarm felt good?, optional fell-asleep /
  woke-up times, optional note. Feeds the personalization head.
- **Sleep notes sheet**: 8 chip-tags (caffeine, alcohol, exercise, stress,
  late meal, travel, medication, screen time) + free-text note.
- **Bedtime reminder**: a single daily local `UNCalendarNotificationTrigger`,
  configurable in Settings. No remote push.
- **Shake-to-snooze**: when the smart alarm fires, shaking the iPhone (≥ 1.7 g
  for ≥ 0.25 s) dismisses it.
- **App icon**: deep navy gradient + soft crescent moon + accent star. Generated
  by `scripts/generate_app_icon.py`.
- **Full Simplified Chinese localization**, including `InfoPlist.strings`
  permission copy. All UI strings now live in `Localizable.strings`.

### App Store readiness
- `MARKETING_VERSION = 0.3.0` in `apple/Configs/Shared.xcconfig`.
- App Store Connect metadata: `docs/AppStoreConnect/{en,zh-Hans}/`
  - `name.txt`, `subtitle.txt`, `description.txt`
  - `keywords.txt`
  - `whats_new.txt`
  - `privacy_policy.txt`
  - `support.txt`

## What is NOT in this release (intentionally)
- Real fine-tuning on labelled human nights (Release D, blocked on data collection).
- Server-side anything (still no backend, still no account).
- AI coach / chat.

## How to ship

1. In Xcode, change the bundle identifier from `com.example.sleep.{ios,watch}` to your own.
2. Connect your Apple Developer account, set the team in `Signing & Capabilities`.
3. Run `python3 scripts/generate_app_icon.py` once to regenerate the icon if needed.
4. Archive with Xcode → Product → Archive → Distribute App → App Store Connect.
5. In App Store Connect, paste the contents of `docs/AppStoreConnect/{lang}/*.txt`
   into the matching fields for English (US) and Simplified Chinese.
6. Submit for TestFlight beta.

## Known limitations
- The personalization "feature vector" is currently mostly the timeline-entry
  duration; per-window features will be persisted in Release D so the head can
  learn richer corrections.
- `bundle id` and `Apple Watch` companion bundle id must be customized before
  upload — they are intentionally placeholders in this repo.
- Snore detector is a privacy-first design; the bundled CNN was trained on a
  synthetic + public mix and treats borderline cases conservatively (false
  negatives over false positives).
