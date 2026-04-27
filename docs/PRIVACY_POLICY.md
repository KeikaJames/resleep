# Privacy Policy

_Last updated: 2026-04-28._

Circadia is an offline-first sleep tracking app for iOS and watchOS. This document
describes what Circadia does and does not do with your data. The same text is
shown inside the app under Settings → Privacy Policy.

## What stays local

By default, every byte Circadia records lives only on your device:

- Heart rate samples and HRV-like features.
- Accelerometer windows and motion summaries.
- Per-night session history, hypnogram, and sleep score.
- Diagnostic events used to inspect what happened overnight.
- Audio buffers used for breathing-event detection (only while a session is active and only if you have explicitly enabled the microphone).

## What we never do

- We never upload raw audio. Microphone capture, when enabled, runs on-device only and discards the buffer after detection.
- Circadia does not include third-party analytics, advertising, or tracking SDKs.
- Circadia does not run a backend server for your sleep data.
- Circadia does not share or sell your data to anyone.

## HealthKit

If you grant HealthKit access:

- Circadia reads heart rate and HRV from HealthKit so it can classify sleep stages.
- Circadia can write a sleep-analysis sample back to HealthKit so the night appears under Health → Sleep.

You can revoke either permission at any time from iOS Settings → Health → Data Access & Devices → Sleep. Doing so does not delete data already written to HealthKit; manage that in the Health app.

## Diagnostics

Circadia keeps a local diagnostic log under the app's Application Support
directory. The log contains timestamps, event types, and small counters
(for example, "telemetry batch received: 64 samples"). No raw audio and no
heart-rate values are written to the diagnostic log.

You can view, copy, or clear the diagnostic log at any time in Settings → Diagnostics.

## Children

Circadia is not directed at children under 13 and we do not knowingly collect
data from children.

## Changes to this policy

If we change what Circadia does with your data, we will update this document
and reflect the change in the Settings → Privacy Policy view in the next
app release.

## Contact

For questions about this policy, contact the developer through the App Store
listing for Sleep.
