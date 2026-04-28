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
    @Published private(set) var isStarting: Bool = false
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
    @Published private(set) var sleepPlan: SleepPlanConfiguration
    /// "live" or "simulated" as reported by the phone via status snapshots.
    /// nil if we have never received one. Debug-oriented only.
    @Published private(set) var runtimeModeRaw: String?

    let haptic = WatchHapticRunner()

    // MARK: Tunables

    private let flushIntervalSec: TimeInterval = 3.0
    private let maxQueuedBatches: Int = 100
    private let maxRememberedStoppedSessions: Int = 16

    // MARK: Dependencies

    private let connectivity: ConnectivityManagerProtocol
    private let workout: WatchWorkoutSessionManagerProtocol
    private let motion: MotionSampling
    private let sleepPlanStore: SleepPlanUserDefaultsStore

    // MARK: Buffers

    private var pendingHeartRates: [HeartRatePoint] = []
    private var pendingAccelWindows: [AccelWindow] = []
    private var guaranteedQueue: [MessageEnvelope] = []  // dropped-oldest cap
    private var stoppedSessionIds: [String] = []
    private var recentHeartRates: [(bpm: Double, at: Date)] = []
    private var lastAccelEnergy: Double?
    private var lastAccelAt: Date?
    private var lastNightmareWakeAt: Date?

    // MARK: Task handles

    private var flushTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var sleepPlanMonitorTask: Task<Void, Never>?
    private var lastAutoStartWindowId: String?

    // MARK: Init

    init(connectivity: ConnectivityManagerProtocol,
         workout: WatchWorkoutSessionManagerProtocol,
         motion: MotionSampling) {
        self.connectivity = connectivity
        self.workout = workout
        self.motion = motion
        self.sleepPlanStore = SleepPlanUserDefaultsStore()
        self.sleepPlan = sleepPlanStore.load()
        self.phoneReachable = connectivity.isReachable
        self.phoneAppInstalled = connectivity.isWatchAppInstalled
        wireConnectivity()
        wireSamplers()
        connectivity.activate()
        startSleepPlanMonitorLoop()
    }

    static func makeDefault() -> WatchAppState {
        let connectivity = ConnectivityManager.makeProductionDefault()
        #if os(watchOS) && canImport(HealthKit) && !targetEnvironment(simulator)
        let workout: WatchWorkoutSessionManagerProtocol = HKWatchWorkoutSessionManager()
        #else
        let workout: WatchWorkoutSessionManagerProtocol = MockWatchWorkoutSessionManager()
        #endif
        #if canImport(CoreMotion) && os(watchOS) && !targetEnvironment(simulator)
        let motion: MotionSampling = CoreMotionSampler()
        #else
        let motion: MotionSampling = MockMotionSampler()
        #endif
        return WatchAppState(connectivity: connectivity, workout: workout, motion: motion)
    }

    // MARK: Public (UI) actions

    func manualStart() async {
        await beginWatchOwnedSession()
    }

    func manualStop() async {
        let sid = currentSessionId
        rememberStopped(sessionId: sid)
        cancelPendingStart()
        await stopTracking()
        sendStopRequest(sessionId: sid)
    }

    private func startPendingTimeout() {
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.isStarting, !self.isTracking else { return }
            self.isStarting = false
            self.lastError = NSLocalizedString("watch.error.phoneStartTimeout", comment: "")
        }
    }

    private func cancelPendingStart() {
        isStarting = false
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
    }

    private func sendStartRequest(sessionId: String) {
        guard let env = try? WatchMessage.startTracking(sessionId: sessionId) else { return }
        sendControlEnvelope(env)
    }

    private func sendStopRequest(sessionId: String?) {
        guard let env = try? WatchMessage.stopTracking(sessionId: sessionId) else { return }
        sendControlEnvelope(env)
    }

    private func sendControlEnvelope(_ env: MessageEnvelope) {
        if connectivity.isReachable {
            do {
                try connectivity.sendImmediateMessage(env)
                return
            } catch {
                lastError = "phone control queued: \(error)"
            }
        }
        connectivity.sendGuaranteedMessage(env)
    }

    private func beginWatchOwnedSession() async {
        guard !isTracking, !isStarting else { return }
        let sid = UUID().uuidString
        lastError = nil
        currentSessionId = sid
        isStarting = true
        sendStartRequest(sessionId: sid)
        await startTracking(sessionId: sid)
        if isTracking {
            lastError = nil
        } else if lastError == nil {
            lastError = "start failed"
        }
    }

    private func startSleepPlanMonitorLoop() {
        sleepPlanMonitorTask?.cancel()
        sleepPlanMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.evaluateSleepPlan(now: Date())
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func evaluateSleepPlan(now: Date) {
        guard sleepPlan.autoTrackingEnabled, !isTracking, !isStarting else { return }
        let decision = sleepPlan.decision(now: now)
        guard decision.shouldAutoStart else { return }
        guard lastAutoStartWindowId != decision.window.id else { return }
        lastAutoStartWindowId = decision.window.id
        Task { await beginWatchOwnedSession() }
    }

    private func applySleepPlan(_ plan: SleepPlanConfiguration) {
        sleepPlan = plan
        sleepPlanStore.save(plan)
        evaluateSleepPlan(now: Date())
    }

    // MARK: Start/stop

    private func startTracking(sessionId: String) async {
        guard !isTracking else { return }
        cancelPendingStart()
        lastError = nil
        currentSessionId = sessionId
        // Workout start is the hard dependency: HR sampling lives on the
        // workout session. If it fails we must NOT enter tracking state,
        // otherwise the UI would show "tracking" while no HR data flows.
        do {
            try await workout.start(sessionId: sessionId)
        } catch {
            lastError = "workout start failed: \(error)"
            rememberStopped(sessionId: sessionId)
            isStarting = false
            resetSessionScopedState()
            pushStatusSnapshot(sessionId: sessionId)
            sendStopRequest(sessionId: sessionId)
            return
        }
        // Motion is a soft dependency: accel windows are nice to have but
        // HR alone still drives a useful session. Degrade with a clear
        // error string rather than aborting the whole start.
        do {
            try motion.start()
        } catch {
            lastError = "motion degraded (HR only): \(error)"
        }
        isTracking = true
        startFlushLoop()
        pushStatusSnapshot()
    }

    private func stopTracking() async {
        cancelPendingStart()
        guard isTracking else {
            resetSessionScopedState()
            pushStatusSnapshot()
            return
        }
        stopAlarmLocally()
        flushTask?.cancel()
        flushTask = nil
        motion.stop()
        do { try await workout.stop() } catch {
            lastError = "workout stop: \(error)"
        }
        // final flush so the phone gets the tail of the session
        flush(force: true)
        isTracking = false
        resetSessionScopedState()
        pushStatusSnapshot()
    }

    /// Clears every piece of per-session transient state so the next
    /// session starts from zero. Intentionally does NOT touch
    /// `phoneReachable` / `phoneAppInstalled` / `runtimeModeRaw` — those
    /// are connectivity/phone-mirrored and survive across sessions.
    private func resetSessionScopedState() {
        currentSessionId = nil
        pendingHeartRates.removeAll(keepingCapacity: false)
        pendingAccelWindows.removeAll(keepingCapacity: false)
        guaranteedQueue.removeAll(keepingCapacity: false)
        pendingGuaranteedCount = 0
        latestHeartRate = nil
        latestHeartRateAt = nil
        currentStage = nil
        currentConfidence = nil
        recentHeartRates.removeAll(keepingCapacity: false)
        lastAccelEnergy = nil
        lastAccelAt = nil
        lastNightmareWakeAt = nil
        smartAlarmArmed = false
        alarmState = .idle
        isAlarmActive = false
        lastBatchSentAt = nil
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
        recentHeartRates.append((bpm, date))
        recentHeartRates.removeAll { date.timeIntervalSince($0.at) > 20 * 60 }
        pendingHeartRates.append(
            HeartRatePoint(tsMs: UInt64(date.timeIntervalSince1970 * 1000), bpm: bpm)
        )
        evaluateNightmareWake(now: date)
    }

    private func onAccelWindow(_ window: AccelWindow) {
        lastAccelEnergy = window.energy
        lastAccelAt = WallClock.date(ms: window.tsMs)
        pendingAccelWindows.append(window)
        evaluateNightmareWake(now: lastAccelAt ?? Date())
    }

    private func evaluateNightmareWake(now: Date) {
        guard sleepPlan.nightmareWakeEnabled,
              isTracking,
              !isAlarmActive,
              alarmState != .triggered else { return }
        let decision = sleepPlan.decision(now: now)
        guard decision.phase == .scheduledSleep else { return }
        if let lastNightmareWakeAt,
           now.timeIntervalSince(lastNightmareWakeAt) < 20 * 60 {
            return
        }
        guard let latestHeartRate,
              recentHeartRates.count >= 6,
              let lastAccelEnergy,
              let lastAccelAt,
              now.timeIntervalSince(lastAccelAt) <= 15,
              lastAccelEnergy >= 0.22 else { return }

        let baselineSamples = recentHeartRates
            .filter { now.timeIntervalSince($0.at) >= 90 }
            .map(\.bpm)
        guard baselineSamples.count >= 4 else { return }
        let baseline = baselineSamples.reduce(0, +) / Double(baselineSamples.count)
        let heartSpike = latestHeartRate >= 105 || latestHeartRate - baseline >= 24
        guard heartSpike else { return }

        lastNightmareWakeAt = now
        alarmState = .triggered
        isAlarmActive = true
        haptic.start()
        lastError = NSLocalizedString("watch.nightmareWake.triggered", comment: "")
        if let env = try? WatchMessage.ack(sessionId: currentSessionId,
                                           ackKind: "nightmareWakeTriggered") {
            if connectivity.isReachable {
                try? connectivity.sendImmediateMessage(env)
            } else {
                connectivity.sendGuaranteedMessage(env)
            }
        }
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
            phoneReachable = snap.reachable
            currentStage = snap.currentStageRaw.flatMap(SleepStage.init(rawValue:))
            currentConfidence = snap.currentConfidence
            runtimeModeRaw = snap.runtimeModeRaw
            if let plan = snap.sleepPlan {
                applySleepPlan(plan)
            }
            if !snap.isTracking {
                if !isTracking {
                    rememberStopped(sessionId: env.sessionId)
                }
                if shouldAcceptIdleSnapshot(sessionId: env.sessionId), isStarting, !isTracking {
                    cancelPendingStart()
                }
            } else if snap.trackingSource == .watch {
                let sid = env.sessionId ?? currentSessionId ?? UUID().uuidString
                guard !hasRememberedStop(for: sid) else {
                    pushStatusSnapshot()
                    return
                }
                if isTracking {
                    guard currentSessionId == sid else {
                        pushStatusSnapshot()
                        return
                    }
                    currentSessionId = sid
                } else {
                    Task { await startTracking(sessionId: sid) }
                }
            }
            if let st = snap.alarmState {
                // A local nightmare wake can trigger while the iPhone still
                // thinks the alarm is idle. Do not let that stale mirror stop
                // an active haptic; explicit dismiss/stop controls still win.
                if !(isAlarmActive && alarmState == .triggered && st == .idle) {
                    alarmState = st
                    // Phone may transition to dismissed or idle while haptic
                    // is still running on the Watch — mirror that.
                    if st == .dismissed || st == .idle {
                        stopAlarmLocally()
                    }
                }
            }

        case .telemetryBatch, .ack:
            break
        }
    }

    private func handleControl(_ ctrl: ControlPayload, sessionId: String?) {
        switch ctrl.command {
        case .startTracking:
            let sid = sessionId ?? currentSessionId ?? UUID().uuidString
            guard !hasRememberedStop(for: sid) else {
                pushStatusSnapshot()
                return
            }
            if isTracking {
                guard currentSessionId == sid else {
                    pushStatusSnapshot()
                    return
                }
                currentSessionId = sid
                cancelPendingStart()
                pushStatusSnapshot()
            } else {
                Task { await startTracking(sessionId: sid) }
            }
        case .stopTracking:
            rememberStopped(sessionId: sessionId ?? currentSessionId)
            guard shouldAcceptExplicitStop(sessionId: sessionId) else {
                pushStatusSnapshot()
                return
            }
            cancelPendingStart()
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

    private func rememberStopped(sessionId: String?) {
        guard let sessionId, !sessionId.isEmpty else { return }
        if stoppedSessionIds.contains(sessionId) { return }
        stoppedSessionIds.append(sessionId)
        if stoppedSessionIds.count > maxRememberedStoppedSessions {
            stoppedSessionIds.removeFirst(stoppedSessionIds.count - maxRememberedStoppedSessions)
        }
    }

    private func hasRememberedStop(for sessionId: String) -> Bool {
        stoppedSessionIds.contains(sessionId)
    }

    /// Explicit stop controls are allowed to omit a session id as an
    /// emergency "force idle" command. When a session id is present, it must
    /// match the Watch's active/pending session so delayed guaranteed
    /// deliveries from an old night cannot kill a fresh session.
    private func shouldAcceptExplicitStop(sessionId incoming: String?) -> Bool {
        guard let incoming else { return true }
        return incoming == currentSessionId
    }

    /// Idle status snapshots are lower authority than explicit stop controls.
    /// A nil-session idle snapshot can be old app-launch noise; don't let it
    /// stop an active Watch session. Session-scoped idle snapshots are accepted
    /// only when they match the current/pending session.
    private func shouldAcceptIdleSnapshot(sessionId incoming: String?) -> Bool {
        guard let incoming else { return isStarting && !isTracking }
        return incoming == currentSessionId
    }

    // MARK: Status

    private func pushStatusSnapshot(sessionId overrideSessionId: String? = nil) {
        let snap = StatusSnapshotPayload(
            isTracking: isTracking,
            reachable: connectivity.isReachable,
            currentStageRaw: currentStage?.rawValue,
            currentConfidence: currentConfidence,
            lastSyncTsMs: WallClock.nowMs(),
            trackingSourceRaw: isTracking
                ? TrackingSourceWire.watch.rawValue
                : TrackingSourceWire.none.rawValue,
            sleepPlan: sleepPlan
        )
        try? connectivity.updateStatusSnapshot(snap, sessionId: overrideSessionId ?? currentSessionId)
    }
}
