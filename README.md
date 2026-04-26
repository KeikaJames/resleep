# sleep-tracker

Offline-first sleep tracker for iOS 17+ / watchOS 10+. Swift drives UI,
HealthKit, WatchConnectivity and AVFoundation. Rust (`sleep-core`) owns
feature engineering, the state machine, SQLite storage and the inference
engine. Python lives only for training + `.mlpackage` export.

Privacy defaults are conservative: no audio capture, no raw audio saved, no
cloud services. Raw accel and HR samples never leave the device.

## Layout

    apple/            iOS + watchOS apps + shared SleepKit Swift package
    rust/             sleep-core + sleep-cli + local SQLite schema
    python/           training workspace (tiny transformer stub)
    scripts/          bootstrap / build / gen / test helpers
    .github/          minimal CI

## Local toolchain

- Xcode 16+ (iOS 17 / watchOS 10 SDK)
- Rust stable (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-watchos aarch64-apple-watchos-sim`)
- Python 3.11+
- swift-bridge CLI (`cargo install swift-bridge-cli`) for regenerating Swift bindings

Bootstrap everything:

    ./scripts/bootstrap.sh

## Build order

1. `scripts/build_rust_xcframework.sh` — builds `sleep-core` as
   `rust/target-xcframework/SleepCore.xcframework`.
2. `scripts/gen_bindings.sh` — regenerates the swift-bridge shim at
   `apple/SleepKit/Sources/SleepKit/Generated/SleepCore.swift`.
3. Open `apple/SleepTracker.xcworkspace` in Xcode.
   - `SleepKit` auto-picks up the xcframework when it is present
     (`SLEEPKIT_USE_RUST` compile flag is set in `Package.swift`).
4. Build `SleepTracker-iOS` (and optionally `SleepTracker-Watch`).

The Swift package builds even if the Rust xcframework is missing — it just
uses `InMemorySleepEngineClient` as the engine.

## Running

### Opening the Xcode project

The Xcode project is **generated** by [XcodeGen] from `apple/project.yml`.
We do not commit the `.xcodeproj`; regenerate before opening:

    ./scripts/generate_xcode_project.sh      # writes apple/SleepTracker.xcodeproj
    ./scripts/open_xcode.sh                  # regenerates + opens the workspace

`open_xcode.sh` always regenerates first, so editing `project.yml` and re-running
the script is sufficient — there is no stale-project hazard.

[XcodeGen]: https://github.com/yonki/XcodeGen

## Local data & persistence

The iPhone app persists product data — sessions, summaries, alarm metadata,
and timeline entries — to a versioned JSON file in the app's
**Application Support** sandbox:

    Application Support/SleepTracker/local_store.json

Behaviour:

- Writes are atomic (temp file → `replaceItemAt`); a crash mid-write cannot
  corrupt prior state.
- A corrupt file is **quarantined** to `local_store.corrupt-<timestamp>.json`
  next to the live file and the app starts with an empty store; it does not
  crash.
- Tests and previews use the in-memory `InMemoryLocalStore`. The app default
  is `PersistentLocalStore` via `EngineHost.makeLocalStore()`.

### Clearing local sleep data

Settings → **Local Data** → *Delete Local Sleep Data* removes every
session, summary, and timeline entry stored on device. There is no
cloud backup — the action cannot be undone.

### Diagnostics & unattended overnight tests (M7)

The app keeps a local **diagnostic event log** so unattended overnight
runs can be inspected the next morning:

    Application Support/SleepTracker/diagnostics.jsonl
    Application Support/SleepTracker/diagnostics.jsonl.1   (rotated)
    Application Support/SleepTracker/active_session.json   (only while a session is in progress)

Behaviour:

- Append-only JSONL, ~2 MB rotation, corrupt lines are skipped — never crashes the app.
- Settings → **Diagnostics** shows the latest report summary, opens a full readable view, and supports Copy / Clear.
- An `active_session.json` marker is written at session start and cleared at clean stop. If the app is force-killed overnight, the next launch shows a calm **Previous session interrupted** card on Home with **Finish & Save** / **Discard** actions.
- See `docs/M7_UNATTENDED_DEVICE_QA.md` for the full unattended QA protocol.

### Real vs approximate timeline

`SessionDetailView` prefers the **persisted timeline** captured every 30 s
during a session and folded into stage spans at stop time. If a session has
no recorded timeline (older data, or sessions shorter than the first tick),
the view falls back to a coarse 4-block timeline derived from the per-stage
totals and labels it *Approximate timeline*.

## UI smoke screenshot

`scripts/capture_ui_smoke.sh` proves the app launches and renders Home:

    ./scripts/capture_ui_smoke.sh
    # → tmp/screenshots/home.png

It generates the project, builds `SleepTracker-iOS`, boots an iPhone
simulator (default `iPhone 17`, override with `SIM_NAME=...`), installs and
launches the app, waits 5 seconds, and writes a PNG via `simctl io … screenshot`.
The `tmp/` directory is gitignored.


### iOS

- Scheme: `SleepTracker-iOS`, destination: any iOS 17+ simulator (e.g. iPhone 17)
  or a real device.
- Capabilities (already in `project.yml` / entitlements): HealthKit,
  Background Modes.
- Info.plist keys (auto-generated from `project.yml`):
  - `NSHealthShareUsageDescription`
  - `NSHealthUpdateUsageDescription`
  - `NSMotionUsageDescription`

CLI build check:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcrun xcodebuild build \
      -project apple/SleepTracker.xcodeproj \
      -scheme SleepTracker-iOS \
      -destination 'platform=iOS Simulator,name=iPhone 17'

### watchOS

- Scheme: `SleepTracker-Watch`, destination: any watchOS 10+ simulator
  (e.g. Apple Watch Series 11 46mm).
- Capabilities (in `project.yml`): HealthKit, Background Modes (`workout-processing`).

CLI build check:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcrun xcodebuild build \
      -project apple/SleepTracker.xcodeproj \
      -scheme SleepTracker-Watch \
      -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'

### Rust CLI

    cd rust
    cargo run -p sleep-cli -- demo

### Python

    cd python
    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    python training/train_tiny_transformer.py --help

## M3: Watch ↔ iPhone live link

M3 turns the watch into a real sampler and the phone into the engine host.

- Watch samples HR via `HKWorkoutSession` and acceleration via `CMMotionManager`
  (10 Hz → 1 s `AccelWindow` aggregates).
- Every 3 s the watch flushes a `TelemetryBatchPayload` to the phone over
  `WCSession`.
  - Reachable: `sendMessage` (low latency).
  - Unreachable: `transferUserInfo` (OS-guaranteed delivery), with a 100-item
    drop-oldest backstop.
- The phone's `TelemetryRouter` writes each HR point and each `AccelWindow`
  representative into the Rust engine.
- Application context carries periodic `StatusSnapshotPayload` (isTracking,
  current stage, reachable).

### Fallback

If the watch app is not installed or unreachable at `Start tracking`, the
phone silently falls back to the M2 local `HealthKitHeartRateStream` path.
The Home screen's "Data source" badge shows which mode is active.

### Pairing + debugging

1. Install the iOS build on the phone.
2. Install the watchOS build on the paired watch (Xcode → Watch scheme).
3. Start tracking on the phone. The watch receives the `startTracking`
   control message and begins sampling.
4. Watch the phone's Home screen — `last sync`, HR count, accel count.
5. Force unreachability by toggling Airplane Mode on the watch;
   `pending N` on the watch UI should climb, and the phone should catch up
   once the link restores (via `transferUserInfo`).

### Tests

    ./scripts/test_all.sh

## Target membership

Target membership is fully declared in `apple/project.yml` and materialized by
`./scripts/generate_xcode_project.sh` — **there is no manual step**. If you add
a new source file under `apple/SleepTracker-iOS/…` or
`apple/SleepTracker-Watch/…`, re-run the generator; XcodeGen globs the trees
and wires it in automatically. SleepKit is consumed as a local Swift package
product by both app targets.

## M4: Smart-alarm closed loop + continuous status sync

M4 closes the smart-alarm loop end-to-end across the iPhone/Watch pair and
routes engine state back to the Watch continuously.

Engine → Watch status sync:

- While tracking, iPhone publishes a `StatusSnapshotPayload` at 1 Hz via
  `updateApplicationContext` through `TelemetryRouter.pushStatusSnapshot(...)`.
- Out-of-band publish on every major transition: tracking start/stop, alarm
  arm, alarm trigger, alarm dismiss, `failedWatchUnreachable`, reachability
  change, and tracking-source change.
- Snapshot now carries `trackingSourceRaw`, `alarmStateRaw`, `alarmTargetTsMs`,
  `alarmWindowMinutes`, `alarmTriggeredAtTsMs`.

Smart-alarm flow (iPhone is the only decision source):

1. User enables smart alarm + picks wake-by time + wake window in HomeView.
2. On `startTracking`, `SmartAlarmController.armIfEnabled(engine:)` calls
   `engine.armSmartAlarm(target:windowMinutes:)` and starts polling
   `engine.checkAlarmTrigger(now:)` — coarse (30 s) outside the wake window,
   fine (1 s) inside.
3. On trigger, the controller invokes its `TriggerHandler` which sends a
   `.triggerAlarm` control envelope to the Watch **immediate-only** (no queue
   fallback — alarm urgency does not tolerate `transferUserInfo` latency).
   - Delivered → state `.triggered`.
   - Unreachable → state `.failedWatchUnreachable`, surfaced in HomeView.
   - Exactly one trigger per session.
4. Watch receives `.triggerAlarm` → `WatchHapticRunner` starts (2 s cadence,
   60 s auto-stop), banner + dismiss button shown.
5. User taps Dismiss on Watch → Watch sends `.dismissAlarm` control envelope
   back to iPhone → `TelemetryRouter.onAlarmDismissed` → controller
   transitions to `.dismissed`.
6. `stopTracking` forces `.stopAlarm` on the Watch (if still active) and
   clears controller state on both sides.

UI surfaces:

- iPhone HomeView: enabled toggle, wake-by picker, window stepper, state
  badge (idle / armed / triggered / dismissed / failedWatchUnreachable),
  last watch ack time, and a "Dismiss from phone" debug button.
- Watch: big red alarm banner with prominent Dismiss button when active;
  alarm state badge + stage/confidence echoed from the iPhone snapshot.

Running on a paired iPhone + Watch:

1. Open `apple/SleepTracker.xcworkspace` in Xcode and add the files listed
   above to their respective targets (the repo ships without `.xcodeproj`).
2. Enable HealthKit + Background Modes (workout, BLE) entitlements for the
   iOS target. Add `NSHealthShareUsageDescription` / `NSHealthUpdateUsage
   Description` to the iOS `Info.plist`. Watch target requires no special
   entitlement for haptics beyond the standard watchOS app template.
3. Run the iOS target on a paired iPhone + its Watch. On HomeView, enable
   "Smart alarm", pick a target within the next couple of minutes, set the
   window to cover it, then tap "Start Tracking". The Watch UI should flip
   to "Tracking" via applicationContext, then show the alarm banner when
   the Rust engine reports trigger.

Current fallback / limitations:

- Alarm state is in-memory (by design for M4). A killed iPhone app loses
  `.armed` / `.triggered`; the Watch will keep buzzing up to 60 s until
  auto-stop.
- The trigger path is immediate-only; a Watch that becomes reachable later
  will **not** receive a retroactive `.triggerAlarm`.
- There is no fallback local audio alarm on iPhone this round.
- The iPhone-local (no-Watch) fallback continues to work: on `startTracking`
  with an unreachable Watch, `TrackingSource = .localPhone` and HR streams
  from HealthKit directly.

## M5: On-device stage inference (Core ML + fallback)

M5 replaces the placeholder stage-inference path with a real, product-shaped
on-device inference pipeline on iPhone. Architecture rules are unchanged:
iPhone remains the only engine / inference host; Watch samples, renders UI,
and plays haptics; Rust keeps session lifecycle, buffering, DB, and alarm
APIs; Swift owns model execution and feature windowing.

### Runtime path

1. Telemetry arrives (local HR stream or `TelemetryRouter` ingesting watch
   batches) and is fed into the Rust engine *and* into
   `StageInferencePipeline`.
2. `FeatureWindowBuilder` maintains rolling 60 s HR + accel buffers and, on
   each refresh tick, emits a 9-slot feature vector matching the Python
   training contract (`hr_mean`, `hr_std`, `hr_slope`, `accel_mean`,
   `accel_std`, `accel_energy`, `event_count_like_snore`, `hrv_like_1`,
   `hrv_like_2`).
3. `SequenceBuffer` holds the most recent `seqLen = 16` vectors.
4. At `inferenceCadenceSec = 5s`, the pipeline invokes the selected
   `StageInferenceModel` and publishes `StageInferenceOutput`
   (stage + confidence + full probability vector).
5. `WorkoutSessionManager` prefers fresh pipeline output over the engine's
   `currentStage` whenever the pipeline result is ≤ 30 s old, otherwise it
   falls back to the Rust engine's heuristic — so M2/M3 behaviour is
   preserved when the pipeline hasn't warmed up yet.
6. Current stage + confidence continue to flow into the Home UI and into
   the watch status snapshot exactly as in M4.

### Model selection

`SleepEngineFactory.makeInferenceModel(bundle:resourceName:)` is the entry
point. It tries, in order:

1. `SleepStager.mlmodelc` in `Bundle.main`
2. `SleepStager.mlpackage`
3. `SleepStager.mlmodel`

If none are present, or Core ML load fails, or the host platform can't load
Core ML, the factory returns a `FallbackHeuristicStageInferenceModel` — a
deterministic, rule-based classifier that matches the synthetic dataset
labelling function (high accel → wake, calm + falling HR → deep, calm +
rising HR → rem, else light). A human-readable reason is exposed via
`AppState.inferenceFallbackReason` for UI debugging.

The app does **not** crash when the model resource is missing — fallback is
transparent.

### Where to drop a trained model

After running `python/training/train_tiny_transformer.py` and
`python/training/export/export_coreml.py`, copy the produced
`SleepStager.mlpackage` (or a pre-compiled `SleepStager.mlmodelc`) into the
iOS app target so Xcode compiles and bundles it:

```
apple/SleepTracker-iOS/Resources/SleepStager.mlpackage
```

Add it to the iOS app target membership. `.mlpackage` files are compiled to
`.mlmodelc` at build time by Xcode automatically.

### Training side (Python)

`python/training/` now reflects the 9-dim feature contract:

- `configs/tiny_transformer.py` — `feature_dim = 9`, `seq_len = 16`,
  `num_classes = 4`. These three are the single source of truth; the Swift
  side mirrors them in `StageInferenceHyperparameters.default`.
- `models/tiny_transformer.py` — tiny nn.TransformerEncoder stack.
- `data/dataset.py` — synthetic dataset whose labelling function deliberately
  matches the heuristic fallback, so a freshly trained model should at least
  reproduce fallback behaviour on synthetic data.
- `train_tiny_transformer.py` — runnable training script.
- `export/export_coreml.py` — `coremltools` export scaffold.

Run the Python smoke test (no pip deps beyond `torch` + `numpy`):

```bash
cd python
python3 tests/test_tiny_transformer_smoke.py
```

### Validating M5 locally

```bash
cd apple/SleepKit && swift build
cd apple/SleepKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
cd rust && cargo test --workspace
cd python && python3 tests/test_tiny_transformer_smoke.py
```

### Current limitations

- Heuristic fallback is the default path until a real `.mlpackage` is dropped
  in the app bundle.
- `hrv_like_1` / `hrv_like_2` are coarse proxies (BPM range + sample count);
  real HRV needs RR intervals not yet plumbed through the watch batch format.
- Inference cadence is 5 s; the pipeline is pull-driven by the existing 1 Hz
  refresh loop, so it will never run faster than that even if cadence is
  lowered.
- Model output is expected to be either softmaxed probabilities or logits;
  the Core ML adapter auto-softmaxes when outputs look unnormalized.

## M6: Real model bundle path + inference instrumentation

M6 locks down the Core ML model contract end-to-end, adds a production-shaped
resource-loading path, and adds lightweight on-device instrumentation for
latency, cadence, and fallback visibility.

### Model contract (single source of truth)

Mirrored in `ModelContract.swift` and `training/configs/tiny_transformer.py`.
Changing any field requires updating both sides.

| Field        | Value         |
|--------------|---------------|
| `resourceName` | `SleepStager` |
| `inputName`    | `features`    |
| `outputName`   | `logits`      |
| `seqLen`       | `16`          |
| `featureDim`   | `9`           |
| `numClasses`   | `4` (wake / light / deep / rem) |

Input shape: `(1, 16, 9)`. Output shape: `(1, 4)` (logits or probabilities;
the Swift loader auto-softmaxes if the row doesn't already sum to ~1).

### Where to drop the bundled model

Place one of the following in the iOS app target's resources and mark it as
a member of `SleepTracker-iOS`:

- `SleepStager.mlmodelc` (compiled; recommended for production)
- `SleepStager.mlpackage` (also accepted by `SleepEngineFactory`)
- `SleepStager.mlmodel`   (accepted as a development fallback)

`SleepEngineFactory.makeInferenceModel` searches, in that order, and returns
`(model, modelLoadMs, fallbackReason)`. If no resource is found or loading
fails, it falls back to `FallbackHeuristicStageInferenceModel` and the
reason is surfaced in `HomeView`'s **Model (debug)** section.

### Inference instrumentation

`StageInferencePipeline.metrics` (type `InferenceMetrics`) is `@Published`
and contains:

- `modelLoaded` — true when a real Core ML model is in use
- `modelLoadMs` — one-shot load latency measured in the factory
- `inferenceCount` / `fallbackInvocationCount`
- `lastPredictMs`, `rollingAvgPredictMs` (16-tick SMA)
- `lastFeatureBuildMs`, `lastInferenceAt`
- `lastErrorMessage` (if `model.predict` threw)

`HomeView` renders these in a **Model (debug)** section: backend kind,
model name/version (from Core ML metadata if present), load time,
inferences, last/avg latency, feature-build time, and the fallback reason.

### Reliability

- `StageInferencePipeline.reset()` is idempotent — safe to call on duplicate
  `stopTracking` or on app-state rebinds mid-session.
- `reset()` preserves `modelLoaded` / `modelLoadMs` so the model debug
  surface survives session restart without a reload.
- The factory never crashes on a bad or missing bundle; it returns a
  heuristic model plus a human-readable fallback reason.

### Training side (Python)

`python/training/export/export_coreml.py` now:

- asserts the model config matches the M6 contract at trace time
- uses `ct.TensorType(name="features", ...)` for input
- renames the single output to `logits` via `ct.utils.rename_feature`
- stamps `short_description` and `version` on the exported package
- supports `--dry-run` which traces + prints shapes without requiring
  `coremltools` (useful in CI and local environments)
- prints a clear message and exits 0 when `coremltools` is not installed,
  instead of crashing

### Validating M6 locally

```bash
# Swift package: build + 21 unit tests (17 M5 + 4 M6)
cd apple/SleepKit && swift build
cd apple/SleepKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test

# Rust: unchanged in M6
cd rust && cargo test --workspace

# Python: model forward + traced export contract + dedicated contract test
cd python && python3 tests/test_tiny_transformer_smoke.py
cd python && python3 tests/test_export_contract.py
cd python && python3 training/export/export_coreml.py --dry-run
```

Expected final line of the dry-run:

```
[dry-run] input=features shape=(1, 16, 9) output=logits shape=(1, 4) classes=4
```

### Current limitations (pre-overnight)

- The bundled model is still synthetic; real training data and a proper
  weighted loss are out of scope for M6.
- Instrumentation is in-memory only; no persisted session debug log yet.
- The **Model (debug)** section is always visible in `HomeView` for
  developer inspection. Wire it behind a build flag before shipping.

## M6.5: Runnable Xcode project + scenario simulator

M6.5 makes the product actually **bootable** in Xcode / Simulator and adds a
deterministic scenario replay layer so the whole product loop (iPhone UI,
watch telemetry, stage inference, smart alarm) can be exercised without
real overnight data or an Apple Watch.

### Generating and opening the project

Xcode project generation is driven by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). No `.pbxproj` is
hand-edited; all targets, resources and package references are declared in
`apple/project.yml`.

```bash
brew install xcodegen                 # one-time
./scripts/generate_xcode_project.sh   # regenerate apple/SleepTracker.xcodeproj
./scripts/open_xcode.sh               # generate (if missing) + open workspace
```

The script also rewrites `apple/SleepTracker.xcworkspace/contents.xcworkspacedata`
so opening the **workspace** (not the bare project) pulls in the generated
`.xcodeproj` plus the local `SleepKit` Swift package.

Override bundle IDs / team for on-device builds:

```bash
BASE_BUNDLE_ID=com.you.sleep DEVELOPMENT_TEAM=ABCDE12345 \
  ./scripts/generate_xcode_project.sh
```

Defaults (Simulator-friendly): unsigned, `com.example.sleep`, no team.

### What you see in Xcode

The generated workspace contains:

- **SleepTracker-iOS** — iPhone app, entry point `SleepTrackerApp`, shows
  `HomeView` → History / Settings navigation.
- **SleepTracker-Watch** — single-target watchOS 10 app
  (`WKApplication=true`), entry point `WatchApp`, shows `WatchHomeView`.
  Embedded in the iOS app automatically.
- **SleepKit** — local Swift package with all shared models, services,
  inference, and simulation code.

### Scenario simulator

A deterministic replay harness lives in
`apple/SleepKit/Sources/SleepKit/Simulation/`:

- `ScenarioType` — 8 scripted scenarios:
  `fallingAsleep`, `stableLight`, `stableDeep`, `remSegment`,
  `preAlarmLightInWake`, `watchDisconnect`, `watchUnavailable`,
  `smartAlarmTriggerDismiss`.
- `ScenarioScripts` — the pure, deterministic source of truth for each
  scenario's steps (HR points, accel windows, reachability toggles,
  arm/dismiss events, marks).
- `ScenarioRunner` — `@MainActor ObservableObject` that replays scripts
  into the live pipeline via callbacks (`onHeartRate`, `onAccelWindow`,
  `onReachability`, `onArmAlarm`, `onDismissAlarm`). Supports both async
  replay with `timeMultiplier` (default 20×) and synchronous
  `replayImmediately(_:)` for tests.

The runner is wired from the iOS `AppState` composition root:

```swift
scenarioRunner.onHeartRate   = { [weak self] bpm, d in self?.workout.ingestRemoteHeartRate(bpm, at: d) }
scenarioRunner.onAccelWindow = { [weak self] w    in self?.workout.ingestRemoteAccel(w) }
scenarioRunner.onReachability = { [weak self] r   in (self?.connectivity as? InMemoryConnectivityManager)?.setReachable(r) }
scenarioRunner.onArmAlarm     = { [weak self] t, w in self?.alarm.isEnabled = true; self?.alarm.target = t; self?.alarm.windowMinutes = w; _ = self?.alarm.armIfEnabled(engine: self!.engine) }
scenarioRunner.onDismissAlarm = { [weak self] in self?.alarm.noteDismissedByWatch() }
```

Scenarios drive the exact same `WorkoutSessionManager` /
`StageInferencePipeline` / `SmartAlarmController` path as live watch
telemetry — no bypass of product code.

### Live mode vs Simulated mode

- **Live** (`AppRuntimeMode.live`, default) — real HealthKit / real watch
  link (if available).
- **Simulated** (`AppRuntimeMode.simulated`) — entered via
  `appState.startSimulation(scenario)`; the phone starts a tracking
  session (`.remoteWatch` source, or `.localPhone` for the
  `watchUnavailable` scenario) and the runner pumps telemetry. Exit with
  `appState.stopSimulation()`. Re-entering is safe; the runner cancels
  any in-flight replay first, so ingestion loops never duplicate.

### Debug panel

`HomeView` gains a **Debug / Simulation** section:

- Runtime mode indicator (Live / Simulated).
- Scenario picker over `ScenarioType.allCases`.
- Run / Stop scenario buttons (+ current step counter).
- Last scenario `mark` label (for segmenting replays).
- Force watch disconnect / reconnect.
- Arm smart alarm in 30 s (handy for overnight-alarm tests without
  waiting real time).

`WatchHomeView` shows an additional debug strip (confidence, short
session id) next to existing tracking / reachability / alarm UI.

### How to validate M6.5 locally

```bash
./scripts/generate_xcode_project.sh                                 # 1. project generates
cd apple/SleepKit && swift build                                    # 2. package compiles
cd apple/SleepKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test  # 3. 26 tests pass (5 new M6.5)
cd rust && cargo test --workspace                                   # 4. Rust unchanged, still green
```

Open the workspace (`./scripts/open_xcode.sh`), pick the
`SleepTracker-iOS` scheme, Run on any iPhone simulator. In the debug
section, pick a scenario (e.g. `smartAlarmTriggerDismiss`) and tap
**Run scenario** to drive the full loop.

### Current limitations

- The generated project is unsigned by default. For device builds set
  `DEVELOPMENT_TEAM` and regenerate.
- `InMemoryConnectivityManager` is used for simulation reachability
  toggles; against a real `WCSession`, OS reachability is authoritative
  and the runner's `onReachability` becomes a no-op.
- Scenario scripts are short (tens of steps) — suitable for product
  smoke testing, not for long-duration performance profiling.
- The alarm test scenario arms and emits a dismiss event, but the
  real trigger path still requires `armIfEnabled(engine:)` to poll the
  Rust engine's `checkAlarmTrigger`; deterministic trigger in
  simulation is covered by existing M4 unit tests.

## Roadmap (next milestones)

- M7: alarm persistence across app restarts + optional phone audio fallback.
- M8: real HRV pipeline (RR interval plumbing end-to-end).


## M6.6: Runtime-launch audit and correctness fixes

M6.6 locks runtime launch readiness. No new product features.

### Behavioral fixes

- **Watch fake-start**: if `HKWorkoutSession` start or motion start throws,
  `WatchAppState.startTracking` no longer enters `isTracking = true`, does
  not spin up a flush loop, and clears `currentSessionId`. Motion-only
  failure (HR still OK) soft-degrades with a surfaced error rather than
  silently claiming success.
- **Immediate-message delivery semantics**:
  `ConnectivityManager.sendImmediateMessage` is now explicitly
  fire-and-forget — it no longer pretends to observe the async
  `WCSession.sendMessage` error callback synchronously. Paths that
  require true delivery confirmation (smart-alarm trigger) use the new
  `sendImmediateMessageAwaitingDelivery(_:) async throws` variant, backed
  by a guarded continuation.
- **Simulation session contamination**: `AppState.startSimulation(_:)`
  now force-stops any active session, clears alarm state, and resets the
  inference pipeline before starting a fresh session for the chosen
  scenario. Switching scenarios never stacks duplicate loops.
- **Stale generated project**: `scripts/open_xcode.sh` regenerates the
  Xcode project unconditionally before `open`, so editing `project.yml`
  can never silently open a stale `.xcodeproj`.
- **Watch debug indicator**: the watch now shows `LIVE mode` or
  `SIM mode` in its debug strip, sourced from
  `StatusSnapshotPayload.runtimeModeRaw` published by the phone.

## M6.7: Runtime launch proof and ack-protocol fixes

M6.7 closes the remaining gap between "`xcodebuild` succeeds" and
"the app actually launches". Evidence from the M6.7 run:

```
$ xcrun simctl install <iPhone 17 UDID> SleepTracker-iOS.app
$ xcrun simctl launch  <iPhone 17 UDID> com.example.sleep.ios
com.example.sleep.ios: 36163     ← PID returned → app launched
```

The Watch `.app` bundle is produced under
`Debug-watchsimulator/SleepTracker-Watch.app`; watchOS app launch from
the CLI is not reliable under current `simctl` (watchOS apps are
designed to be launched through their paired iPhone simulator in
Xcode), so the Watch bundle is the proof point here.

### What M6.7 changed

- **Trigger-ack protocol (Bug #1)**: `TelemetryRouter.sendTriggerAlarm`
  no longer relies on `WCSession.sendMessage` replyHandler (our
  WCSession delegate does not implement the replyHandler path). It is
  now fire-and-forget at the transport layer + an **app-level ack**
  with a bounded 2 s timeout: the phone awaits an `alarmTriggered`
  ack envelope from the Watch, exactly as the existing
  envelope/control/ack protocol already defines. Removed the
  misleading `sendImmediateMessageAwaitingDelivery` API.
- **Simulation uses the live product loop (Bug #2)**: the trigger
  handler, `onAlarmDismissed` routing and 1 Hz status-snapshot loop
  now live in `AppState.installRunningSessionHooks()` /
  `teardownRunningSessionHooks()`. Both `HomeViewModel.start/stop`
  and `AppState.startSimulation/stopSimulation` call through them,
  so a simulated session exercises the same closed loop as live.
- **Watch stop cleanup (Bug #3)**: `WatchAppState.stopTracking` now
  clears every piece of session-scoped transient state
  (`currentSessionId`, pending buffers, guaranteed queue, latest HR,
  stage/confidence, alarm state). `manualStart` always mints a fresh
  UUID instead of reusing the previous session id.
- **Runtime launch proof (Bug #4)**: `Info.plist` for both targets
  now declares `CFBundleExecutable`, `CFBundleName`,
  `CFBundlePackageType`. The Watch `Info.plist` also declares
  `WKCompanionAppBundleIdentifier`. Bundle identifiers in
  `project.yml` are hard-coded (`com.example.sleep.ios` /
  `com.example.sleep.ios.watchkitapp`) because XcodeGen does not
  honour shell-default substitution. These were the blockers that
  kept `simctl install` from accepting the iPhone bundle.

### Current limitations

- `simctl launch` of a watchOS app from the CLI is not reliable under
  current Xcode tooling; run the Watch app through the paired iPhone
  simulator in Xcode. The `xcodebuild build` of the Watch scheme
  still proves the bundle is valid and the shared SleepKit graph
  compiles for watchOS.
- Core ML on-device inference is iPhone-only; on watchOS the
  `.mlpackage` path is disabled because `MLModel.compileModel(at:)`
  is not available. Ship pre-compiled `.mlmodelc` if Watch-side
  inference ever becomes necessary (not planned).


## Release A: TestFlight private beta

This round wires everything required to ship a signed TestFlight build
without changing product behavior. New surface area:

- `apple/Configs/Shared.xcconfig` — single source of truth for
  `BASE_BUNDLE_ID`, `DEVELOPMENT_TEAM`, `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`. Both `Info.plist` files reference these
  via `$(...)` build-setting expansion.
- `apple/Configs/Local.xcconfig.example` — template each developer
  copies to a gitignored `Local.xcconfig` to set their team ID.
- `apple/SleepTracker-iOS/Resources/PrivacyInfo.xcprivacy`,
  `apple/SleepTracker-Watch/Resources/PrivacyInfo.xcprivacy` —
  Apple-required privacy manifest. Auto-bundled by XcodeGen because
  the Resources path glob does not exclude them.
- `apple/SleepTracker-{iOS,Watch}/Resources/{en,zh-Hans}.lproj/InfoPlist.strings` —
  localized usage descriptions for HealthKit, Motion, Microphone.
- `apple/SleepTracker-{iOS,Watch}/Resources/Assets.xcassets/AppIcon.appiconset` —
  placeholder navy-and-crescent icon, generated by
  `scripts/generate_app_icon.py`. Re-run that script after replacing
  with a designed icon.
- `scripts/archive_testflight.sh` + `scripts/exportOptions.plist` —
  signed archive pipeline. Refuses to run unless
  `Local.xcconfig` defines a real `DEVELOPMENT_TEAM`.
- `docs/PRIVACY_POLICY.md`, `docs/TERMS.md` — also surfaced inside
  the app under Settings → About → Privacy Policy / Terms of Use.
- `docs/M8_TESTFLIGHT_CHECKLIST.md` — step-by-step from "no Apple
  Developer account" to "TestFlight invite link in friends' inboxes".

To produce a TestFlight build:

```bash
cp apple/Configs/Local.xcconfig.example apple/Configs/Local.xcconfig
# edit Local.xcconfig, set BASE_BUNDLE_ID and DEVELOPMENT_TEAM
./scripts/generate_xcode_project.sh
scripts/archive_testflight.sh
```

Result: `build/export/*.ipa` ready to upload via Transporter or
`xcrun altool --upload-app`.
