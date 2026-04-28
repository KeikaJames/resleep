import Foundation
import SleepKit

/// Routes inbound watch envelopes into the engine + workout manager, and
/// maintains observable state about the watch link (reachability, last sync,
/// alarm-ack).
///
/// Lives on the iPhone side. The watch has its own smaller router inline in
/// `WatchAppState`.
@MainActor
public final class TelemetryRouter: ObservableObject {

    // MARK: Published

    @Published public private(set) var watchReachable: Bool = false
    @Published public private(set) var watchAppInstalled: Bool = false
    @Published public private(set) var lastBatchAt: Date?
    @Published public private(set) var lastBatchHRCount: Int = 0
    @Published public private(set) var lastBatchAccelCount: Int = 0
    @Published public private(set) var lastAlarmAckAt: Date?

    /// Fires when the Watch tells us the alarm was dismissed.
    public var onAlarmDismissed: (@MainActor () -> Void)?
    /// Fires when the Watch requests ownership of a live sleep session.
    public var onWatchStartRequested: (@MainActor (_ requestedSessionId: String?) -> Void)?
    /// Fires when the Watch requests the active sleep session to stop.
    public var onWatchStopRequested: (@MainActor (_ requestedSessionId: String?) -> Void)?

    // MARK: Trigger-ack tracking (app-level delivery confirmation)

    /// Bounded timeout (seconds) for the Watch's `alarmTriggered` ack. Two
    /// seconds is generous for WatchConnectivity when reachable, and still
    /// short enough to flip the alarm to `failedWatchUnreachable` before the
    /// user experience degrades.
    private let triggerAckTimeoutSec: TimeInterval = 2.0

    /// Single one-shot continuation — smart-alarm is one-shot by product
    /// design, so there is at most one trigger in flight at a time.
    private var pendingTriggerAck: CheckedContinuation<Bool, Never>?
    private var pendingTriggerSessionId: String?
    private var pendingTriggerTimeout: Task<Void, Never>?

    // MARK: Dependencies

    private let connectivity: ConnectivityManagerProtocol
    private let diagnostics: DiagnosticsStoreProtocol?
    private weak var workout: WorkoutSessionManager?

    public init(connectivity: ConnectivityManagerProtocol,
                workout: WorkoutSessionManager,
                diagnostics: DiagnosticsStoreProtocol? = nil) {
        self.connectivity = connectivity
        self.diagnostics = diagnostics
        self.workout = workout
        self.watchReachable = connectivity.isReachable
        self.watchAppInstalled = connectivity.isWatchAppInstalled

        connectivity.activate()

        connectivity.setInboundHandler { [weak self] env in
            Task { @MainActor [weak self] in
                self?.handle(env)
            }
        }
        connectivity.setReachabilityHandler { [weak self] reachable in
            Task { @MainActor [weak self] in
                self?.watchReachable = reachable
            }
        }
    }

    /// Clears per-session telemetry state when a new sleep session starts.
    /// Without this, the UI can show yesterday's Watch sync as if the current
    /// session is actively receiving data.
    public func resetSessionTelemetry() {
        lastBatchAt = nil
        lastBatchHRCount = 0
        lastBatchAccelCount = 0
    }

    // MARK: Inbound dispatch

    private func handle(_ envelope: MessageEnvelope) {
        switch envelope.kind {
        case .telemetryBatch:
            guard let batch = try? envelope.decode(TelemetryBatchPayload.self) else {
                NSLog("[TelemetryRouter] failed to decode telemetryBatch")
                return
            }
            ingest(batch: batch, sessionId: envelope.sessionId)

        case .control:
            guard let ctrl = try? envelope.decode(ControlPayload.self) else { return }
            switch ctrl.command {
            case .startTracking:
                onWatchStartRequested?(envelope.sessionId)
            case .stopTracking:
                onWatchStopRequested?(envelope.sessionId)
            case .dismissAlarm:
                lastAlarmAckAt = Date()
                onAlarmDismissed?()
            default:
                NSLog("[TelemetryRouter] received control=\(ctrl.command.rawValue)")
            }

        case .statusSnapshot:
            if let status = try? envelope.decode(StatusSnapshotPayload.self) {
                watchReachable = status.reachable
            }

        case .ack:
            guard let ack = try? envelope.decode(AckPayload.self) else { return }
            if ack.ackKind == "alarmTriggered" {
                lastAlarmAckAt = Date()
                resolvePendingTrigger(with: true, sessionId: envelope.sessionId)
            } else if ack.ackKind == "alarmDismissed" {
                lastAlarmAckAt = Date()
                onAlarmDismissed?()
            }
        }
    }

    private func ingest(batch: TelemetryBatchPayload, sessionId: String?) {
        guard let workout = workout, workout.isTracking else {
            NSLog("[TelemetryRouter] batch dropped — no active session")
            return
        }
        if let incoming = sessionId,
           let active = workout.currentSessionID,
           incoming != active {
            NSLog("[TelemetryRouter] batch dropped — stale session \(incoming), active \(active)")
            return
        }
        for point in batch.heartRates {
            workout.ingestRemoteHeartRate(point.bpm, at: WallClock.date(ms: point.tsMs))
        }
        for window in batch.accelWindows {
            workout.ingestRemoteAccel(window)
        }
        lastBatchAt = Date()
        lastBatchHRCount = batch.heartRates.count
        lastBatchAccelCount = batch.accelWindows.count
        if let diagnostics {
            let event = DiagnosticEvent(
                type: .telemetryBatchReceived,
                sessionId: sessionId ?? workout.currentSessionID,
                message: "hr=\(batch.heartRates.count) accel=\(batch.accelWindows.count)"
            )
            Task { await diagnostics.append(event) }
        }
    }

    // MARK: Outbound control

    @discardableResult
    public func sendStart(sessionId: String) -> Bool {
        guard let env = try? WatchMessage.startTracking(sessionId: sessionId) else { return false }
        return trySendImmediateWithFallback(env)
    }

    @discardableResult
    public func sendStop(sessionId: String?) -> Bool {
        guard let env = try? WatchMessage.stopTracking(sessionId: sessionId) else { return false }
        // Stop is idempotent and safety-critical: a delayed duplicate is
        // harmless, but a missed stop leaves the Watch recording after the
        // phone has ended the session. Queue a guaranteed copy even when the
        // low-latency path appears reachable, because `WCSession.sendMessage`
        // can still fail asynchronously after our synchronous preflight.
        connectivity.sendGuaranteedMessage(env)
        do {
            try connectivity.sendImmediateMessage(env)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func sendArmAlarm(sessionId: String?, target: Date, windowMinutes: Int) -> Bool {
        let ts = UInt64(target.timeIntervalSince1970 * 1000)
        guard let env = try? WatchMessage.armSmartAlarm(
            sessionId: sessionId,
            targetMs: ts,
            windowMinutes: windowMinutes
        ) else { return false }
        return trySendImmediateWithFallback(env)
    }

    /// One-shot "start haptic" control to the Watch.
    ///
    /// This used to rely on `WCSession.sendMessage`'s replyHandler for
    /// delivery confirmation, but the real WCSession delegate on the Watch
    /// does not implement the replyHandler-based `didReceiveMessage`. As of
    /// M6.7 we use an **app-level ack**:
    ///
    /// 1. Fire-and-forget the `triggerAlarm` envelope.
    /// 2. Await the Watch's `alarmTriggered` ack envelope (routed through
    ///    `handle(_:)`).
    /// 3. Time out after `triggerAckTimeoutSec` — the alarm controller
    ///    then flips to `failedWatchUnreachable`.
    ///
    /// Returns `true` only when a matching ack arrived within the timeout.
    @discardableResult
    public func sendTriggerAlarm(sessionId: String?) async -> Bool {
        guard let env = try? WatchMessage.triggerAlarm(sessionId: sessionId) else { return false }
        // Pre-flight: require reachability for the low-latency path, but
        // also enqueue a guaranteed copy so the alarm still reaches the
        // Watch if WC briefly fluctuates mid-handshake.
        let preflightOk: Bool
        do {
            try connectivity.sendImmediateMessage(env)
            preflightOk = true
        } catch {
            connectivity.sendGuaranteedMessage(env)
            preflightOk = false
        }
        if !preflightOk { return false }

        // Replace any in-flight trigger continuation with a fresh one.
        cancelPendingTrigger(delivering: false)
        let delivered = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.pendingTriggerAck = cont
            self.pendingTriggerSessionId = sessionId
            let timeoutSec = self.triggerAckTimeoutSec
            self.pendingTriggerTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                self?.resolvePendingTrigger(with: false, sessionId: nil)
            }
        }
        return delivered
    }

    // MARK: Trigger-ack internals

    private func resolvePendingTrigger(with delivered: Bool, sessionId: String?) {
        // If an incoming ack carries a sessionId and it mismatches, ignore
        // it — stale ack from a previous session.
        if delivered,
           let expected = pendingTriggerSessionId,
           let got = sessionId,
           expected != got {
            return
        }
        guard let cont = pendingTriggerAck else { return }
        pendingTriggerAck = nil
        pendingTriggerSessionId = nil
        pendingTriggerTimeout?.cancel()
        pendingTriggerTimeout = nil
        cont.resume(returning: delivered)
    }

    private func cancelPendingTrigger(delivering delivered: Bool) {
        if let cont = pendingTriggerAck {
            pendingTriggerAck = nil
            pendingTriggerSessionId = nil
            pendingTriggerTimeout?.cancel()
            pendingTriggerTimeout = nil
            cont.resume(returning: delivered)
        }
    }

    @discardableResult
    public func sendStopAlarm(sessionId: String?) -> Bool {
        guard let env = try? WatchMessage.stopAlarm(sessionId: sessionId) else { return false }
        return trySendImmediateWithFallback(env)
    }

    /// Publishes a rich engine-state snapshot via `updateApplicationContext`.
    /// The Watch reads this continuously to update its UI.
    public func pushStatusSnapshot(sessionId: String?,
                                   isTracking: Bool,
                                   source: TrackingSource,
                                   stage: SleepStage?,
                                   confidence: Float?,
                                   alarmState: AlarmState,
                                   alarmTarget: Date?,
                                   alarmWindowMinutes: Int?,
                                   alarmTriggeredAt: Date?,
                                   runtimeModeRaw: String? = nil) {
        let snap = StatusSnapshotPayload(
            isTracking: isTracking,
            reachable: connectivity.isReachable,
            currentStageRaw: stage?.rawValue,
            currentConfidence: confidence,
            lastSyncTsMs: WallClock.nowMs(),
            trackingSourceRaw: source.wire.rawValue,
            alarmStateRaw: alarmState.rawValue,
            alarmTargetTsMs: alarmTarget.map { UInt64($0.timeIntervalSince1970 * 1000) },
            alarmWindowMinutes: alarmWindowMinutes,
            alarmTriggeredAtTsMs: alarmTriggeredAt.map { UInt64($0.timeIntervalSince1970 * 1000) },
            runtimeModeRaw: runtimeModeRaw
        )
        try? connectivity.updateStatusSnapshot(snap, sessionId: sessionId)
    }

    private func trySendImmediateWithFallback(_ env: MessageEnvelope) -> Bool {
        do {
            try connectivity.sendImmediateMessage(env)
            return true
        } catch {
            connectivity.sendGuaranteedMessage(env)
            return false
        }
    }
}
