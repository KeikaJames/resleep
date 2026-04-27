#if os(iOS)
import Foundation
import UserNotifications
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Real, audible iPhone-side smart alarm. The watch handles haptics, but if
/// the watch is dead, off the wrist, or out of range — and that is the
/// common case in the morning, since the watch ran out of battery
/// overnight — the user must still be woken. This service fills that gap.
///
/// Two reinforcing layers:
///
/// 1. **Pre-scheduled `UNNotification`s** at and after the hard target
///    time. These survive app suspension and will fire even if the system
///    has long since reclaimed the foreground process. We schedule a small
///    burst (every 30 s for ~6 minutes) so the user can't sleep through a
///    single beep.
///
/// 2. **In-process audio + haptics** when the *smart* trigger fires
///    earlier (Rust engine flagged a light-sleep moment, or a nightmare
///    rescue, inside the wake window). `AVAudioPlayer` plays a looped tone
///    at full volume through the media route. The audio session is
///    configured `.playback`, which combined with the `audio` background
///    mode keeps the sound going when the phone is locked.
///
/// Dismissal cancels both layers atomically.
@MainActor
public final class IPhoneAlarmService {

    public static let shared = IPhoneAlarmService()

    /// Notification identifier prefix; we schedule N beats with `<prefix>.<i>`.
    private static let notifIDPrefix = "circadia.alarm.beat"
    /// How many notifications we schedule starting at the hard target.
    /// 12 beats × 30 s = 6 minutes of audible nags before the OS gives up.
    private static let notifBeatCount = 12
    private static let notifBeatGapSec: TimeInterval = 30

    /// Path to the ~1 s synthesized alarm tone we drop into tmp on first
    /// use. Generating a WAV in-process avoids shipping an asset (and
    /// avoids the pain of getting a sound file into both app and watch
    /// bundles via SwiftPM resources).
    private lazy var toneURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("circadia-alarm-tone.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            // Best-effort; a missing file just means we fall back to the
            // SystemSound timer below — UNNotifications still fire either way.
            try? Self.writeAlarmTone(to: url)
        }
        return url
    }()

    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif
    private var beepTimer: Timer?
    private var hasRequestedAuth = false

    private init() {}

    // MARK: - Arm

    /// Schedules guaranteed-wake notifications starting at `target`.
    /// Idempotent: existing scheduled notifications and any in-flight audio
    /// are cleared first so callers can re-arm freely.
    public func arm(target: Date, windowMinutes: Int) {
        // Always cancel anything that was pending — caller may be re-arming
        // with a different time, and we never want stale beats.
        cancelPending()

        // If the target has already passed (e.g. user armed for "5:00" and
        // it's now 5:03), bump it up to "now + 5 s" so we still produce an
        // immediate audible alarm. Without this UN silently drops the
        // request and the user gets nothing.
        let now = Date()
        let firstBeat = max(target, now.addingTimeInterval(5))

        Task { [weak self] in
            await self?.ensureAuthorization()
            await self?.scheduleBeats(firstBeat: firstBeat)
        }
    }

    /// Called when the smart-alarm logic fires *before* the hard target
    /// (because a light-sleep window opened). Plays sound immediately and
    /// keeps the pre-scheduled beats around as a safety net in case
    /// foreground audio gets killed.
    public func fireNow() {
        // Post one immediate notification so even a backgrounded /
        // suspended app produces sound + a visible banner.
        postImmediateBeat()
        startInProcessAudio()
    }

    // MARK: - Cancel

    /// Stops audio, removes pending notifications, and dismisses any
    /// already-delivered beat banners.
    public func cancel() {
        cancelPending()
    }

    // MARK: - Private

    private func cancelPending() {
        stopInProcessAudio()
        let center = UNUserNotificationCenter.current()
        let ids = (0..<Self.notifBeatCount).map { "\(Self.notifIDPrefix).\($0)" }
            + ["\(Self.notifIDPrefix).immediate"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func ensureAuthorization() async {
        guard !hasRequestedAuth else { return }
        hasRequestedAuth = true
        let center = UNUserNotificationCenter.current()
        // .timeSensitive lets the alarm break through Focus / Sleep focus
        // without requiring the Critical Alerts entitlement. .sound +
        // .alert give the audible + on-screen banner.
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("[IPhoneAlarmService] auth request failed: \(error)")
        }
    }

    private func scheduleBeats(firstBeat: Date) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("alarm.notif.title",
            value: "Time to wake up", comment: "")
        content.body = NSLocalizedString("alarm.notif.body",
            value: "Tap to silence — your wake window is here.", comment: "")
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.categoryIdentifier = "CIRCADIA_ALARM"

        for i in 0..<Self.notifBeatCount {
            let when = firstBeat.addingTimeInterval(Double(i) * Self.notifBeatGapSec)
            let interval = max(1.0, when.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let req = UNNotificationRequest(
                identifier: "\(Self.notifIDPrefix).\(i)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(req)
            } catch {
                NSLog("[IPhoneAlarmService] schedule beat \(i) failed: \(error)")
            }
        }
    }

    private func postImmediateBeat() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("alarm.notif.title",
            value: "Time to wake up", comment: "")
        content.body = NSLocalizedString("alarm.notif.body.smart",
            value: "Light-sleep window — gentle wake.", comment: "")
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let req = UNNotificationRequest(
            identifier: "\(Self.notifIDPrefix).immediate",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("[IPhoneAlarmService] immediate post failed: \(err)") }
        }
    }

    private func startInProcessAudio() {
        #if canImport(AVFoundation) && canImport(UIKit)
        // Configure the session for playback so we ring even on silent
        // and through the lock screen. `mixWithOthers` is intentionally
        // off — we want the alarm to interrupt music / podcasts.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            NSLog("[IPhoneAlarmService] audio session activate failed: \(error)")
        }

        if FileManager.default.fileExists(atPath: toneURL.path) {
            do {
                let p = try AVAudioPlayer(contentsOf: toneURL)
                p.numberOfLoops = -1
                p.volume = 1.0
                p.prepareToPlay()
                p.play()
                player = p
            } catch {
                NSLog("[IPhoneAlarmService] AVAudioPlayer failed: \(error)")
                startSystemSoundFallback()
            }
        } else {
            startSystemSoundFallback()
        }

        // Reinforce with a heavy haptic every 1.5 s — iPhone equivalent of
        // the Watch's haptic train. Stops when `cancelPending` invalidates
        // the timer.
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        beepTimer?.invalidate()
        beepTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                gen.impactOccurred(intensity: 1.0)
            }
        }
        #endif
    }

    private func startSystemSoundFallback() {
        #if canImport(AudioToolbox)
        beepTimer?.invalidate()
        beepTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
            // 1005 = "Alarm". Played via SystemSoundServices, plays even
            // if AVAudioPlayer init failed.
            AudioServicesPlaySystemSound(SystemSoundID(1005))
        }
        #endif
    }

    private func stopInProcessAudio() {
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        beepTimer?.invalidate()
        beepTimer = nil
    }

    // MARK: - WAV generation

    /// Writes a ~1.2 s alternating-tone WAV (alarm-clock pattern) to disk.
    /// Mono, 16-bit PCM, 22.05 kHz. Looped by `AVAudioPlayer.numberOfLoops = -1`.
    private static func writeAlarmTone(to url: URL) throws {
        let sampleRate: Int = 22050
        let durationSec: Double = 1.2
        let totalSamples = Int(Double(sampleRate) * durationSec)

        var samples = [Int16]()
        samples.reserveCapacity(totalSamples)

        // Two-tone alarm (880 Hz / 660 Hz alternating every 0.3 s) with a
        // soft attack so it doesn't click on loop boundaries.
        let toneAHz: Double = 880
        let toneBHz: Double = 660
        let attackSamples = Double(sampleRate) * 0.01

        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let segment = Int(t / 0.3) % 2
            let f = segment == 0 ? toneAHz : toneBHz
            let phase = 2.0 * .pi * f * t
            var amp = sin(phase) * 0.7
            // Linear attack to avoid pops at start of each loop.
            let local = Double(i % Int(Double(sampleRate) * 0.3))
            if local < attackSamples {
                amp *= local / attackSamples
            }
            let s = Int16(max(-1.0, min(1.0, amp)) * Double(Int16.max))
            samples.append(s)
        }

        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2

        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)            // PCM chunk size
        data.append(UInt16(1).littleEndianData)             // PCM format
        data.append(UInt16(1).littleEndianData)             // mono
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(UInt16(2).littleEndianData)             // block align
        data.append(UInt16(16).littleEndianData)            // bits per sample

        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)
        for s in samples {
            data.append(s.littleEndianData)
        }

        try data.write(to: url, options: .atomic)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }
}

private extension Int16 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: MemoryLayout<Int16>.size)
    }
}

#endif
