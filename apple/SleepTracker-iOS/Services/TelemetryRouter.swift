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

    // MARK: Dependencies

    private let connectivity: ConnectivityManagerProtocol
    private weak var workout: WorkoutSessionManager?

    public init(connectivity: ConnectivityManagerProtocol,
                workout: WorkoutSessionManager) {
        self.connectivity = connectivity
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
            case .dismissAlarm:
                lastAlarmAckAt = Date()
                onAlarmDismissed?()
            default:
                // iPhone is the engine host — it does not accept startTracking/
                // stopTracking from the Watch. Log and ignore.
                NSLog("[TelemetryRouter] received control=\(ctrl.command.rawValue)")
            }

        case .statusSnapshot:
            if let status = try? envelope.decode(StatusSnapshotPayload.self) {
                watchReachable = status.reachable
            }

        case .ack:
            guard let ack = try? envelope.decode(AckPayload.self) else { return }
            if ack.ackKind == "alarmTriggered" || ack.ackKind == "alarmDismissed" {
                lastAlarmAckAt = Date()
                if ack.ackKind == "alarmDismissed" { onAlarmDismissed?() }
            }
        }
    }

    private func ingest(batch: TelemetryBatchPayload, sessionId: String?) {
        guard let workout = workout, workout.isTracking else {
            NSLog("[TelemetryRouter] batch dropped — no active session")
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
        return trySendImmediateWithFallback(env)
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
    /// Returns `true` only if the immediate path succeeded — `transferUserInfo`
    /// is too slow to be useful for an alarm, so when reachable is false we
    /// report failure rather than queuing. Callers translate that into
    /// `AlarmState.failedWatchUnreachable`.
    @discardableResult
    public func sendTriggerAlarm(sessionId: String?) -> Bool {
        guard let env = try? WatchMessage.triggerAlarm(sessionId: sessionId) else { return false }
        guard connectivity.isReachable else { return false }
        do {
            try connectivity.sendImmediateMessage(env)
            return true
        } catch {
            return false
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
                                   alarmTriggeredAt: Date?) {
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
            alarmTriggeredAtTsMs: alarmTriggeredAt.map { UInt64($0.timeIntervalSince1970 * 1000) }
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
