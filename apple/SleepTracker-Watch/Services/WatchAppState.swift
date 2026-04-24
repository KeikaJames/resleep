import Foundation
import SleepKit
#if canImport(Combine)
import Combine
#endif

/// Watch-side coordinator. Drives sampling (HR via HealthKit workout, accel
/// via CoreMotion), buffers telemetry, flushes every 3 s, and reacts to
/// control messages from the phone.
@MainActor
final class WatchAppState: ObservableObject {

    // MARK: Published state

    @Published private(set) var isTracking: Bool = false
    @Published private(set) var phoneReachable: Bool = false
    @Published private(set) var phoneAppInstalled: Bool = false
    @Published private(set) var latestHeartRate: Double?
    @Published private(set) var latestHeartRateAt: Date?
    @Published private(set) var lastBatchSentAt: Date?
    @Published private(set) var pendingGuaranteedCount: Int = 0
    @Published private(set) var currentStage: SleepStage?
    @Published private(set) var currentConfidence: Float?
    @Published private(set) var smartAlarmArmed: Bool = false
    @Published private(set) var alarmState: AlarmState = .idle
    @Published private(set) var isAlarmActive: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentSessionId: String?

    let haptic = WatchHapticRunner()

    // MARK: Tunables

    private let flushIntervalSec: TimeInterval = 3.0
    private let maxQueuedBatches: Int = 100

    // MARK: Dependencies

    private let connectivity: ConnectivityManagerProtocol
    private let workout: WatchWorkoutSessionManagerProtocol
    private let motion: MotionSampling

    // MARK: Buffers

    private var pendingHeartRates: [HeartRatePoint] = []
    private var pendingAccelWindows: [AccelWindow] = []
    private var guaranteedQueue: [MessageEnvelope] = []  // dropped-oldest cap

    // MARK: Task handles

    private var flushTask: Task<Void, Never>?

    // MARK: Init

    init(connectivity: ConnectivityManagerProtocol,
         workout: WatchWorkoutSessionManagerProtocol,
         motion: MotionSampling) {
        self.connectivity = connectivity
        self.workout = workout
        self.motion = motion
        self.phoneReachable = connectivity.isReachable
        self.phoneAppInstalled = connectivity.isWatchAppInstalled
        wireConnectivity()
        wireSamplers()
        connectivity.activate()
    }

    static func makeDefault() -> WatchAppState {
        let connectivity = ConnectivityManager.makeProductionDefault()
        #if os(watchOS) && canImport(HealthKit)
        let workout: WatchWorkoutSessionManagerProtocol = HKWatchWorkoutSessionManager()
        #else
        let workout: WatchWorkoutSessionManagerProtocol = MockWatchWorkoutSessionManager()
        #endif
        #if canImport(CoreMotion) && os(watchOS)
        let motion: MotionSampling = CoreMotionSampler()
        #else
        let motion: MotionSampling = MockMotionSampler()
        #endif
        return WatchAppState(connectivity: connectivity, workout: workout, motion: motion)
    }

    // MARK: Public (UI) actions

    func manualStart() async {
        let sid = currentSessionId ?? UUID().uuidString
        await startTracking(sessionId: sid)
    }

    func manualStop() async {
        await stopTracking()
    }

    // MARK: Start/stop

    private func startTracking(sessionId: String) async {
        guard !isTracking else { return }
        lastError = nil
        currentSessionId = sessionId
        do {
            try await workout.start(sessionId: sessionId)
        } catch {
            lastError = "workout start: \(error)"
        }
        do {
            try motion.start()
        } catch {
            lastError = "motion start: \(error)"
        }
        isTracking = true
        startFlushLoop()
        pushStatusSnapshot()
    }

    private func stopTracking() async {
        guard isTracking else { return }
        stopAlarmLocally()
        alarmState = .idle
        smartAlarmArmed = false
        flushTask?.cancel()
        flushTask = nil
        motion.stop()
        do { try await workout.stop() } catch {
            lastError = "workout stop: \(error)"
        }
        // final flush so the phone gets the tail of the session
        flush(force: true)
        isTracking = false
        pushStatusSnapshot()
    }

    // MARK: Flush loop

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            let interval = UInt64(self.flushIntervalSec * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                self.flush(force: false)
                self.drainGuaranteedQueue()
            }
        }
    }

    private func flush(force: Bool) {
        guard !pendingHeartRates.isEmpty || !pendingAccelWindows.isEmpty || force else { return }
        guard !pendingHeartRates.isEmpty || !pendingAccelWindows.isEmpty else { return }

        let payload = TelemetryBatchPayload(
            heartRates: pendingHeartRates,
            accelWindows: pendingAccelWindows
        )
        pendingHeartRates.removeAll(keepingCapacity: true)
        pendingAccelWindows.removeAll(keepingCapacity: true)

        guard let env = try? WatchMessage.telemetryBatch(sessionId: currentSessionId,
                                                         payload: payload) else {
            lastError = "encode telemetry failed"
            return
        }

        if connectivity.isReachable {
            do {
                try connectivity.sendImmediateMessage(env)
                lastBatchSentAt = Date()
            } catch {
                enqueueGuaranteed(env)
            }
        } else {
            enqueueGuaranteed(env)
        }
    }

    private func enqueueGuaranteed(_ env: MessageEnvelope) {
        if guaranteedQueue.count >= maxQueuedBatches {
            guaranteedQueue.removeFirst()
        }
        guaranteedQueue.append(env)
        pendingGuaranteedCount = guaranteedQueue.count
        connectivity.sendGuaranteedMessage(env)
        lastBatchSentAt = Date()
    }

    private func drainGuaranteedQueue() {
        // transferUserInfo is persisted by the OS, so we can clear our
        // mirror queue once the payloads have been handed off.
        guard !guaranteedQueue.isEmpty else { return }
        guaranteedQueue.removeAll(keepingCapacity: true)
        pendingGuaranteedCount = 0
    }

    // MARK: Sampler wiring

    private func wireSamplers() {
        workout.onHeartRate = { [weak self] bpm, date in
            Task { @MainActor [weak self] in
                self?.onHeartRate(bpm, at: date)
            }
        }
        motion.onWindow = { [weak self] window in
            Task { @MainActor [weak self] in
                self?.onAccelWindow(window)
            }
        }
    }

    private func onHeartRate(_ bpm: Double, at date: Date) {
        latestHeartRate = bpm
        latestHeartRateAt = date
        pendingHeartRates.append(
            HeartRatePoint(tsMs: UInt64(date.timeIntervalSince1970 * 1000), bpm: bpm)
        )
    }

    private func onAccelWindow(_ window: AccelWindow) {
        pendingAccelWindows.append(window)
    }

    // MARK: Connectivity wiring

    private func wireConnectivity() {
        connectivity.setReachabilityHandler { [weak self] reachable in
            Task { @MainActor [weak self] in
                self?.phoneReachable = reachable
                if reachable { self?.drainGuaranteedQueue() }
            }
        }
        connectivity.setInboundHandler { [weak self] env in
            Task { @MainActor [weak self] in
                self?.handleInbound(env)
            }
        }
    }

    private func handleInbound(_ env: MessageEnvelope) {
        switch env.kind {
        case .control:
            guard let ctrl = try? env.decode(ControlPayload.self) else { return }
            handleControl(ctrl, sessionId: env.sessionId)

        case .statusSnapshot:
            guard let snap = try? env.decode(StatusSnapshotPayload.self) else { return }
            if let raw = snap.currentStageRaw { currentStage = SleepStage(rawValue: raw) }
            currentConfidence = snap.currentConfidence
            if let st = snap.alarmState {
                alarmState = st
                // Phone may transition to dismissed or idle while haptic is
                // still running on the Watch — mirror that.
                if st == .dismissed || st == .idle {
                    stopAlarmLocally()
                }
            }

        case .telemetryBatch, .ack:
            break
        }
    }

    private func handleControl(_ ctrl: ControlPayload, sessionId: String?) {
        switch ctrl.command {
        case .startTracking:
            Task { await startTracking(sessionId: sessionId ?? UUID().uuidString) }
        case .stopTracking:
            stopAlarmLocally()
            Task { await stopTracking() }
        case .ping:
            if let env = try? WatchMessage.ack(sessionId: sessionId, ackKind: "ping") {
                try? connectivity.sendImmediateMessage(env)
            }
        case .armSmartAlarm:
            smartAlarmArmed = true
            alarmState = .armed
        case .triggerAlarm:
            alarmState = .triggered
            isAlarmActive = true
            haptic.start()
            if let env = try? WatchMessage.ack(sessionId: sessionId, ackKind: "alarmTriggered") {
                try? connectivity.sendImmediateMessage(env)
            }
        case .stopAlarm:
            stopAlarmLocally()
        case .dismissAlarm, .ack:
            // Phone echoing dismiss or ack — stop buzzing if we were active.
            stopAlarmLocally()
        }
    }

    // MARK: Alarm dismiss (user-driven from Watch UI)

    func dismissAlarmFromWatch() {
        guard isAlarmActive || alarmState == .triggered else { return }
        stopAlarmLocally()
        alarmState = .dismissed
        if let env = try? WatchMessage.dismissAlarm(sessionId: currentSessionId) {
            if connectivity.isReachable {
                try? connectivity.sendImmediateMessage(env)
            } else {
                connectivity.sendGuaranteedMessage(env)
            }
        }
    }

    private func stopAlarmLocally() {
        haptic.stop()
        isAlarmActive = false
    }

    // MARK: Status

    private func pushStatusSnapshot() {
        let snap = StatusSnapshotPayload(
            isTracking: isTracking,
            reachable: connectivity.isReachable,
            currentStageRaw: currentStage?.rawValue,
            currentConfidence: currentConfidence,
            lastSyncTsMs: WallClock.nowMs()
        )
        try? connectivity.updateStatusSnapshot(snap, sessionId: currentSessionId)
    }
}
