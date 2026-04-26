# M7 — Unattended Real-Device Overnight QA

This document describes how to run a real, unattended overnight sleep test
of the app on an iPhone (with optional paired Apple Watch). The user
**cannot** intervene during the night, so the goal is to capture enough
local diagnostics that the run can be inspected the following morning.

> The app is offline-first. No data leaves the device.

---

## 1. Setup requirements

Hardware:

- iPhone running iOS 17 or later.
- (Optional) Apple Watch running watchOS 10 or later, paired to the same iPhone.
- Lightning / USB-C cable, charger, and a charging spot near the bed.

Software:

- Xcode installed on the host Mac, with a valid signing identity for personal device deployment.
- `xcodegen` available on PATH (used by `scripts/generate_xcode_project.sh`).
- Optional: Apple Developer account with a profile that allows installing on a real device.

Account:

- HealthKit must be enabled on the iPhone.
- The user must be willing to grant Health permissions when first prompted.

---

## 2. iPhone simulator smoke test (required before any real-device run)

Run the local validation suite first. You must do this before installing on a real device.

```bash
./scripts/generate_xcode_project.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project apple/SleepTracker.xcodeproj \
  -scheme SleepTracker-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test  -project apple/SleepTracker.xcodeproj \
  -scheme SleepTracker-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
./scripts/capture_ui_smoke.sh
```

A successful run produces:

- `BUILD SUCCEEDED`
- `Test Suite ... passed`
- `tmp/screenshots/home.png`

If any of these fail, **stop**. Do not proceed to a real-device run.

---

## 3. Real iPhone install

1. Open `apple/SleepTracker.xcworkspace` in Xcode.
2. Select the `SleepTracker-iOS` scheme.
3. Choose your iPhone as the run destination (Window → Devices and Simulators → trust device if needed).
4. Run.
5. After the app launches, accept the HealthKit permission prompt.
6. Verify that:
   - Home shows **Tonight Status** = idle.
   - Settings → **Diagnostics** shows "No diagnostic events yet" *or* a summary of the latest report.
   - Settings → **Compliance** displays the offline-first / no-audio-upload notice.

---

## 4. Paired Apple Watch install (optional but recommended)

1. With the iPhone connected and trusted in Xcode, switch the Run destination to the **paired Apple Watch**.
2. Build and run the `SleepTracker-Watch` scheme.
3. After install, on the Watch home screen verify:
   - Watch app shows **Idle**.
   - Status reports phone reachable.
   - No history, settings, or trends are exposed (companion-only UI).

If the Watch app fails to install, you can still run the iPhone-only path; the iPhone will fall back to its local heart-rate stream.

---

## 5. Unattended short-night test (≈30 minutes)

Goal: confirm the closed loop works end-to-end without user intervention.

1. Plug iPhone into a charger; close all apps.
2. Open the app, go to Home.
3. Set Smart Alarm:
   - Toggle on
   - Wake-by: 30 minutes from now
   - Wake window: 5 minutes
4. Tap **Start Tracking**.
5. Lock the phone, place it screen-down on the nightstand.
6. **Do not interact** with the phone for 30 minutes.

When the alarm fires (or after the wake window passes):

- iPhone or Watch should haptic / play tone.
- Dismiss from the Watch (preferred) or iPhone.
- Tap **Stop Tracking** on the iPhone.

In the morning (or immediately after the test), check:

- Home → Last Session: shows score, duration, alarm result.
- History → tap row → Session Detail: shows timeline.
- Settings → Diagnostics → View Diagnostics: full event log including
  `appLaunch`, `sessionStart`, `smartAlarmArmed`, `smartAlarmTriggered`,
  `smartAlarmDismissed`, `sessionStop`.

---

## 6. Full overnight test

Same as section 5, but:

- Set Wake-by to your real desired wake time (e.g. 7:00 AM).
- Window: 30 minutes.
- Run for the full night.
- Phone must stay charging.

In the morning:

1. Do **not** kill the app first. Open it.
2. Capture the values above, plus:
   - Number of telemetry batches received.
   - Whether the Watch went unreachable mid-night.
3. Use **Settings → Diagnostics → Copy** to save a snapshot of the diagnostic log.

---

## 7. Smart-alarm unattended test

If you want to specifically validate the alarm-trigger path:

- Set wake-by to 30 minutes from now.
- Window 5 minutes.
- Sit far enough from the Watch that you might lose reachability mid-test (or toggle Watch Airplane mode mid-run on a separate device).
- Confirm that `smartAlarmFailedWatchUnreachable` is logged when the Watch is unreachable at trigger time.

---

## 8. Watch disconnect / reconnect test

- Start a session as in section 5.
- Walk far enough from the iPhone (or temporarily turn off iPhone Bluetooth) to disconnect the Watch.
- Walk back / re-enable Bluetooth.

Expected diagnostics:

- `watchUnreachable` followed eventually by `watchReachable`.
- `telemetryBatchReceived` resumes after reconnect.

---

## 9. Where to find diagnostics

- **In-app:** Settings → Diagnostics → View Diagnostics. Tap the copy icon to copy the rendered report.
- **On disk (real device):** the app stores diagnostics in its sandbox at:

  ```
  Application Support/SleepTracker/diagnostics.jsonl
  diagnostics.jsonl.1   (rotated)
  active_session.json   (only present when a session is in progress)
  local_store.json      (sessions / timelines)
  ```

  These are reachable with Xcode → Window → Devices and Simulators → select your iPhone → SleepTracker → Download Container.

---

## 10. Pass / Fail / Blocker

**Pass** (all of the following):

- App launches and shows idle state on Home.
- A session starts cleanly and records a `sessionStart` event.
- Telemetry batches arrive periodically (`telemetryBatchReceived`).
- Alarm fires at or before wake-by + window.
- Session can be stopped and is persisted (visible in History after relaunch).

**Fail** (any of the following, but recoverable):

- Alarm did not fire but the session was otherwise recorded.
- Watch reachability flapped repeatedly.
- Inference pipeline fell back to heuristic mid-session.

**Blocker** (re-test required):

- App was force-killed by the OS overnight (an `active_session.json` is left
  behind; on next launch the app should display the **Previous session
  interrupted** card on Home — choose Finish & Save or Discard).
- App crashed (no `sessionStop` event, no record persisted).
- Diagnostics file is unreadable / corrupt.

---

## 11. Known limitations

- The app does not currently auto-resume an interrupted session in the
  background. If iOS terminated the process overnight, the user is shown a
  recovery card on the next launch and must manually choose Finish & Save
  or Discard.
- Diagnostic events do not include precise wall-clock counters for every
  inference tick; only an aggregate count is computed in the report.
- Watch UI is intentionally minimal — most diagnostics live on the iPhone.
- Real Core ML model is not yet wired into production builds; the heuristic
  fallback is in use unless a model bundle is added.
- Audio capture is intentionally not enabled in this build.

---

## 12. After the test

- Copy the diagnostics text block from Settings → Diagnostics.
- Optionally delete local sleep data (Settings → Local Data → Delete) before the next clean overnight test.
- File a report against the repo with the diagnostic text and any subjective notes.
