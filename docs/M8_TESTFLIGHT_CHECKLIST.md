# M8 — TestFlight Checklist

This checklist takes the project from "builds in simulator" to "private
TestFlight beta you can hand to friends with iPhone + Apple Watch."

The repo provides everything that lives in source. Apple's side (paid
developer account, App Store Connect record, code signing) is manual.

## 0. One-time prerequisites

- [ ] **Apple Developer Program** ($99/yr): https://developer.apple.com/programs/enroll/. Individual is fine for private TestFlight; switch to Organization later if you want a brand name on the listing. Approval can take 24–48 hours; sometimes longer for new accounts.
- [ ] **macOS Xcode 15+** with the iOS 17 / watchOS 10 simulator runtimes installed.
- [ ] **Hosted Privacy URL.** App Store Connect requires a public privacy policy URL. The repo ships `docs/PRIVACY_POLICY.md`. Easiest hosting:
    - GitHub Pages: enable Pages on this repo (Settings → Pages → Deploy from a branch → main, `/docs` folder). The published URL becomes `https://<user>.github.io/<repo>/PRIVACY_POLICY.html`. Convert the `.md` to `.html` with any static-site tool, or rename to `index.md` and let Jekyll render.
    - Or any web host. Just don't link to a 404.

## 1. Configure local signing

```bash
cp apple/Configs/Local.xcconfig.example apple/Configs/Local.xcconfig
```

Edit `apple/Configs/Local.xcconfig`:

```
BASE_BUNDLE_ID = com.<your-reverse-domain>.sleep
DEVELOPMENT_TEAM = ABCDE12345     // your 10-char team ID from developer.apple.com → Account → Membership
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
```

`Local.xcconfig` is gitignored. Do not commit your team ID.

Regenerate the Xcode project so Bundle IDs pick up the new BASE_BUNDLE_ID:

```bash
./scripts/generate_xcode_project.sh
```

Verify in Xcode that `SleepTracker-iOS` Bundle Identifier reads
`com.<your>.sleep.ios` and the Watch app reads `com.<your>.sleep.ios.watchkitapp`.

## 2. Register identifiers and capabilities

On https://developer.apple.com/account/resources/identifiers/list:

- [ ] App ID `com.<your>.sleep.ios` with capabilities: HealthKit, Background Modes (Audio + Workout processing for the Watch — actually Background Modes is configured on the WatchKit App ID), App Groups (only if you wire one).
- [ ] App ID `com.<your>.sleep.ios.watchkitapp` with capabilities: HealthKit, WCSession (always on), Background Modes → Workout processing.

Tip: enable HealthKit on both. Watch needs it because the Watch target reads heart rate.

## 3. Create the App Store Connect record

On https://appstoreconnect.apple.com/apps:

- [ ] New App → iOS, Bundle ID `com.<your>.sleep.ios`, Primary Language English, name "Sleep" (must be unique on the store; if taken, pick a free alternative — you can change later).
- [ ] App Privacy section: paste the data-collection answers from `docs/M8_TESTFLIGHT_CHECKLIST.md` → "App Privacy answers" below.
- [ ] Privacy Policy URL: paste the URL you hosted in step 0.

## 4. Build the archive

```bash
scripts/archive_testflight.sh
```

The script regenerates the Xcode project, archives the iOS scheme for
`generic/platform=iOS`, and exports an `.ipa` to `build/export/`. It refuses
to run if `DEVELOPMENT_TEAM` is missing.

## 5. Upload to TestFlight

Pick one:

- **Transporter.app** (Mac App Store): drag `build/export/Sleep.ipa` in.
- Command line:
  ```bash
  xcrun altool --upload-app -f build/export/*.ipa --type ios \
      --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
  ```
  Generate the API key under App Store Connect → Users and Access → Keys.

After upload, the build appears under TestFlight → iOS Builds within a few
minutes (and "Processing" for ~10 more).

## 6. Internal beta

- [ ] App Store Connect → TestFlight → Internal Testing → add your Apple ID(s).
- [ ] Once the build finishes processing, click it → answer Export Compliance ("does not use encryption" — the app sets `ITSAppUsesNonExemptEncryption=false`, so this should be auto-answered).
- [ ] Internal testers receive the invite immediately; no review required.

## 7. External beta (5+ friends)

- [ ] TestFlight → External Testing → New Group → add up to 10,000 testers by email.
- [ ] Each first build to an external group requires a short Beta App Review (typically <24h).
- [ ] Reviewer notes (paste into App Store Connect → TestFlight → Test Information):

```
This app tracks sleep using Apple Watch heart rate, HRV, and motion. To
review without sleeping for a real night:

1. Launch the app, tap Settings → Developer → Runtime → ensure "Live" or
   "Simulated" depending on whether the reviewer wears a paired Watch.
2. On Home, tap "Start Tracking" to begin a fake-data simulated session.
   The hypnogram fills in within ~30 seconds.
3. Tap "Stop Tracking". A summary appears under History.

HealthKit usage: the app reads heart rate and HRV to classify sleep stages.
Microphone usage: optional breathing-event detection. Audio is processed
on-device and never uploaded; the buffer is discarded after detection.

No backend, no analytics, no third-party SDKs. Privacy policy:
https://<your-hosted-privacy-url>/
```

## App Privacy answers

Paste these into App Store Connect → App Privacy.

- Data Types Collected: Health & Fitness (Health, Fitness), Audio Data (Audio Data).
- Linked to user: **No** for all.
- Used to track: **No** for all.
- Purpose: **App Functionality** for all.
- Health & Fitness: collected on-device, used for sleep stage classification, not shared.
- Audio Data: optional, on-device only, used for breathing-event detection, never uploaded.

## What testers do overnight

Hand them this short note:

> Install Sleep from the TestFlight invite. Pair your Apple Watch. Tap Start
> Tracking before bed and Stop Tracking when you wake. In the morning, open
> Settings → Diagnostics, tap the copy icon, and paste the diagnostic dump
> into a reply.

## Validation before each upload

```bash
./scripts/generate_xcode_project.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project apple/SleepTracker.xcodeproj -scheme SleepTracker-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project apple/SleepTracker.xcodeproj -scheme SleepTracker-Watch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apple/SleepTracker.xcodeproj -scheme SleepTracker-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
scripts/capture_ui_smoke.sh
```

If any of these fail, do not upload.

## Common rejection causes

- Missing PrivacyInfo.xcprivacy → already in repo.
- Missing privacy policy URL → step 0.
- Microphone usage description missing or vague → already in `Info.plist`.
- Health usage descriptions missing or vague → already in `Info.plist`.
- Bundle ID mismatch with App Store Connect → re-check `BASE_BUNDLE_ID`.
- Invalid signing → ensure the team owns the App ID and HealthKit is enabled.

## Limitations of this round

- App icon is a placeholder crescent. Replace with a designed icon before public launch.
- Inference is rule-based. The TestFlight build is enough to validate signing, install, telemetry, alarm, and diagnostics — not score accuracy.
- HealthKit write-back is stubbed. TestFlight is for plumbing, not sleep-stage truth.
