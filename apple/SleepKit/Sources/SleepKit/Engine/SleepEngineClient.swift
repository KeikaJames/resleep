import Foundation

/// Single contract between SwiftUI / services and the sleep engine.
///
/// Two concrete implementations ship in SleepKit:
/// - `InMemorySleepEngineClient` — pure-Swift reference implementation used
///   for previews, unit tests, and as a fallback when the Rust bridge isn't
///   available.
/// - `RustSleepEngineClient` — real implementation backed by `sleep-core`
///   through swift-bridge. Enabled when the package is built with the
///   `SLEEPKIT_USE_RUST` compilation condition (automatic once the Rust
///   xcframework + generated Swift shim are in place).
///
/// The protocol is `@MainActor`-isolated: both implementations touch shared
/// mutable state (a Rust `&mut self` for the bridge, or a `NSLock`-guarded
/// struct in memory), and every caller in the app is already main-actor
/// bound (ViewModels, coordinators). Putting the isolation on the protocol
/// itself removes the Swift-6 `ConformanceIsolation` warnings that the M3
/// build was carrying.
///
/// Pick an implementation via `SleepEngineFactory`.
@MainActor
public protocol SleepEngineClientProtocol: AnyObject {
    func startSession(at date: Date) throws -> String
    func endSession() throws -> SessionSummary
    func pushHeartRate(_ bpm: Float, at date: Date) throws
    func pushAccelerometer(x: Float, y: Float, z: Float, at date: Date) throws
    func currentStage() throws -> SleepStage
    func currentConfidence() throws -> Float
    func armSmartAlarm(target: Date, windowMinutes: Int) throws
    func checkAlarmTrigger(now: Date) throws -> Bool
}

public enum SleepEngineError: Error, Sendable, Equatable {
    case noActiveSession
    case sessionAlreadyRunning
    case engineUnavailable
    case underlying(String)
}

// MARK: - In-Memory reference implementation

/// Lightweight reference implementation, feature-complete enough for the UI
/// skeleton, previews and unit tests. `@MainActor` to match the protocol;
/// the internal lock is kept as a defence-in-depth measure since tests may
/// drive it under `@MainActor` assumptions that still technically re-enter.
@MainActor
public final class InMemorySleepEngineClient: SleepEngineClientProtocol {
    private let lock = NSLock()

    private struct ActiveSession {
        let id: String
        let startedAt: Date
        var lastSampleAt: Date
        var lastStageAt: Date
        var stage: SleepStage
        var timeInStage: [SleepStage: TimeInterval] = [
            .wake: 0, .light: 0, .deep: 0, .rem: 0
        ]
        var lastHR: Float = 0
        var hrCount: Int = 0
        var hrSum: Float = 0
    }

    private var active: ActiveSession?
    private var confidence: Float = 0
    private var alarmTarget: Date?
    private var alarmWindow: TimeInterval = 0

    public init() {}

    public func startSession(at date: Date) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if active != nil { throw SleepEngineError.sessionAlreadyRunning }
        let id = UUID().uuidString
        active = ActiveSession(id: id, startedAt: date, lastSampleAt: date, lastStageAt: date, stage: .wake)
        confidence = 0.3
        return id
    }

    public func endSession() throws -> SessionSummary {
        lock.lock(); defer { lock.unlock() }
        guard var s = active else { throw SleepEngineError.noActiveSession }
        let end = max(s.lastSampleAt, s.startedAt)
        let delta = end.timeIntervalSince(s.lastStageAt)
        s.timeInStage[s.stage, default: 0] += delta
        active = nil

        let duration = Int(end.timeIntervalSince(s.startedAt))
        let score = Self.computeScore(timeInStage: s.timeInStage, duration: TimeInterval(duration))
        return SessionSummary(
            sessionId: s.id,
            durationSec: duration,
            timeInWakeSec:  Int(s.timeInStage[.wake]  ?? 0),
            timeInLightSec: Int(s.timeInStage[.light] ?? 0),
            timeInDeepSec:  Int(s.timeInStage[.deep]  ?? 0),
            timeInRemSec:   Int(s.timeInStage[.rem]   ?? 0),
            sleepScore: score
        )
    }

    public func pushHeartRate(_ bpm: Float, at date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        guard var s = active else { throw SleepEngineError.noActiveSession }
        s.lastSampleAt = max(s.lastSampleAt, date)
        s.hrSum += bpm
        s.hrCount += 1
        let mean = s.hrSum / Float(s.hrCount)
        let slope = bpm - s.lastHR
        s.lastHR = bpm
        let newStage: SleepStage = slope < -0.2 ? .deep : (slope > 0.2 ? .rem : .light)
        applyStage(&s, newStage: mean == 0 ? .wake : newStage, at: date, conf: 0.55)
        active = s
    }

    public func pushAccelerometer(x: Float, y: Float, z: Float, at date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        guard var s = active else { throw SleepEngineError.noActiveSession }
        s.lastSampleAt = max(s.lastSampleAt, date)
        let mag = sqrt(x * x + y * y + z * z)
        if mag > 1.2 {
            applyStage(&s, newStage: .wake, at: date, conf: 0.75)
        }
        active = s
    }

    public func currentStage() throws -> SleepStage {
        lock.lock(); defer { lock.unlock() }
        return active?.stage ?? .wake
    }

    public func currentConfidence() throws -> Float {
        lock.lock(); defer { lock.unlock() }
        return confidence
    }

    public func armSmartAlarm(target: Date, windowMinutes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        alarmTarget = target
        alarmWindow = TimeInterval(windowMinutes * 60)
    }

    public func checkAlarmTrigger(now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let target = alarmTarget else { return false }
        if now >= target { return true }
        let windowStart = target.addingTimeInterval(-alarmWindow)
        guard now >= windowStart else { return false }
        let stage = active?.stage ?? .wake
        return (stage == .light || stage == .rem) && confidence >= 0.5
    }

    // MARK: - Internals

    private func applyStage(_ s: inout ActiveSession, newStage: SleepStage, at date: Date, conf: Float) {
        if newStage != s.stage {
            let delta = date.timeIntervalSince(s.lastStageAt)
            s.timeInStage[s.stage, default: 0] += delta
            s.stage = newStage
            s.lastStageAt = date
        }
        confidence = conf
    }

    private static func computeScore(timeInStage: [SleepStage: TimeInterval], duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let asleep = (timeInStage[.light] ?? 0) + (timeInStage[.deep] ?? 0) + (timeInStage[.rem] ?? 0)
        let eff = min(max(asleep / duration, 0), 1)
        let deep = min(max((timeInStage[.deep] ?? 0) / duration, 0), 0.4) / 0.4
        let rem  = min(max((timeInStage[.rem]  ?? 0) / duration, 0), 0.25) / 0.25
        let score = 60 * eff + 25 * deep + 15 * rem
        return Int(score.rounded())
    }
}
