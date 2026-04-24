import Foundation
#if canImport(Combine)
import Combine
#endif

/// Owns the smart-alarm state machine that sits above `SleepEngineClientProtocol`.
///
/// Responsibilities:
/// - Hold user-configurable alarm settings (enabled / target / wake window).
/// - Arm the Rust engine via `armSmartAlarm(target:windowMinutes:)` when a
///   session starts.
/// - Run a polling loop asking the engine whether to trigger. Polling is
///   cheap outside the active wake window and 1 Hz inside.
/// - Emit exactly one trigger per session. Mark `failedWatchUnreachable`
///   when the caller reports it could not deliver the trigger to the Watch.
/// - Accept dismissal (either from the Watch or from the phone UI) and
///   transition to `.dismissed`.
///
/// State is in-memory per session by design — persistence is deliberately
/// out of scope for M4.
///
/// The controller itself is `@MainActor`-isolated. The triggering side-effect
/// is delivered through the injected `onTrigger` closure so UI / router code
/// can decide how to route it (send a `triggerAlarm` control message to the
/// Watch, etc.) and signal back whether routing succeeded.
@MainActor
public final class SmartAlarmController: ObservableObject {

    // MARK: User config (observable)

    @Published public var isEnabled: Bool = false
    @Published public var target: Date
    @Published public var windowMinutes: Int

    // MARK: Runtime state

    @Published public private(set) var state: AlarmState = .idle
    @Published public private(set) var triggeredAt: Date?
    @Published public private(set) var watchAckedAt: Date?

    // MARK: Tunables

    /// Polling period when we're well before the wake window.
    public var coarsePollSec: TimeInterval = 30
    /// Polling period once we're inside the wake window.
    public var finePollSec:   TimeInterval = 1
    /// How early (relative to the wake window) we flip from coarse to fine
    /// polling, so we don't miss an early trigger.
    public var fineLeadSec:   TimeInterval = 60

    // MARK: Collaborator hook

    /// Called when the engine reports trigger. Must return `true` if the
    /// trigger was dispatched successfully (e.g. control message sent to the
    /// Watch), `false` if the sink was unreachable. The controller uses the
    /// return value to pick `.triggered` vs `.failedWatchUnreachable`.
    ///
    /// Hopping actors inside the closure is fine; the controller awaits the
    /// result before updating its own state.
    public typealias TriggerHandler = @MainActor () async -> Bool
    private var onTrigger: TriggerHandler?

    // MARK: Task handle

    private var pollTask: Task<Void, Never>?

    // MARK: Init

    public init(target: Date = SmartAlarmController.defaultTarget(),
                windowMinutes: Int = 15) {
        self.target = target
        self.windowMinutes = windowMinutes
    }

    public func setTriggerHandler(_ handler: @escaping TriggerHandler) {
        self.onTrigger = handler
    }

    // MARK: Lifecycle

    /// Arms the Rust engine and starts polling. Returns the snapshot fields
    /// the caller should publish over WC (`target`, `window`).
    @discardableResult
    public func armIfEnabled(engine: SleepEngineClientProtocol) -> Bool {
        guard isEnabled else {
            state = .idle
            triggeredAt = nil
            watchAckedAt = nil
            return false
        }
        do {
            try engine.armSmartAlarm(target: target, windowMinutes: windowMinutes)
            state = .armed
            triggeredAt = nil
            watchAckedAt = nil
            startPolling(engine: engine)
            return true
        } catch {
            state = .idle
            NSLog("[SmartAlarmController] arm failed: \(error)")
            return false
        }
    }

    /// Stops the polling loop and returns the controller to idle. Safe to
    /// call when already idle. Does not clear user config (`isEnabled`,
    /// `target`, `windowMinutes`) — those persist for the next session.
    public func clear() {
        pollTask?.cancel()
        pollTask = nil
        state = .idle
        triggeredAt = nil
        watchAckedAt = nil
    }

    /// Called by the telemetry router when a dismiss ack arrives from the
    /// Watch. No-op if the alarm was never triggered (stale message).
    public func noteDismissedByWatch(at date: Date = Date()) {
        guard state == .triggered || state == .failedWatchUnreachable else { return }
        state = .dismissed
        watchAckedAt = date
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called by the phone UI if the user chooses to dismiss locally (or if
    /// the router sends a `stopAlarm` to the Watch).
    public func dismissLocally(at date: Date = Date()) {
        guard state == .triggered || state == .failedWatchUnreachable else { return }
        state = .dismissed
        watchAckedAt = date
    }

    // MARK: - Internals

    private func startPolling(engine: SleepEngineClientProtocol) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runPollLoop(engine: engine)
        }
    }

    private func runPollLoop(engine: SleepEngineClientProtocol) async {
        while !Task.isCancelled {
            if state != .armed {
                // Either triggered, dismissed, or arming failed — stop polling.
                return
            }
            let now = Date()
            let triggered = (try? engine.checkAlarmTrigger(now: now)) ?? false
            if triggered {
                await handleTriggered(at: now)
                return
            }
            let sleepSec = currentPollIntervalSec(now: now)
            try? await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
        }
    }

    private func handleTriggered(at date: Date) async {
        triggeredAt = date
        let delivered = await onTrigger?() ?? false
        state = delivered ? .triggered : .failedWatchUnreachable
    }

    private func currentPollIntervalSec(now: Date) -> TimeInterval {
        let windowStart = target.addingTimeInterval(-TimeInterval(windowMinutes * 60) - fineLeadSec)
        return now >= windowStart ? finePollSec : coarsePollSec
    }

    public nonisolated static func defaultTarget() -> Date {
        // Tomorrow 07:00 local — a benign default for the UI picker.
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 7
        comps.minute = 0
        let base = cal.date(from: comps) ?? Date()
        return base < Date() ? base.addingTimeInterval(24 * 3600) : base
    }
}
