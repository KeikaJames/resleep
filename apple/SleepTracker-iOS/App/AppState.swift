import Foundation
import Combine
import SleepKit

/// Runtime mode: live data vs scripted scenario replay.
public enum AppRuntimeMode: String, Sendable, Equatable {
    case live      = "live"
    case simulated = "simulated"
}

/// Composition root for the iOS app. Scenes pull their dependencies off this
/// object, typically through view-model initializers.
@MainActor
public final class AppState: ObservableObject {
    public let engine: SleepEngineClientProtocol
    public let localStore: LocalStoreProtocol
    public let insights: LocalInsightsServiceProtocol
    public let connectivity: ConnectivityManagerProtocol
    public let health: HealthPermissionServiceProtocol
    public let healthWriter: HealthKitSleepWriting
    public let snoreDetector: SnoreDetectorProtocol
    public let personalization: PersonalizationService
    public let heartRateStream: HeartRateStreaming
    public let workout: WorkoutSessionManager
    public let router: TelemetryRouter
    // `var` (not `let`) so SwiftUI can form a writable key-path binding
    // via `$appState.alarm.xxx` against the underlying @Published fields
    // on the controller. Reassignment is never actually done.
    public var alarm: SmartAlarmController
    public let inferencePipeline: StageInferencePipeline

    public let engineFallbackReason: String?
    public let inferenceFallbackReason: String?

    /// Local-only diagnostic event log. Append-only JSONL; safe if missing/corrupt.
    public let diagnostics: DiagnosticsStoreProtocol
    /// Active-session crash/interruption marker.
    public let markerStore: ActiveSessionMarkerStoreProtocol
    public let sleepPlanStore: SleepPlanUserDefaultsStore

    @Published public var latestSummary: SessionSummary?
    @Published public private(set) var sleepPlan: SleepPlanConfiguration
    /// Set when the app launches and finds a stale active-session marker.
    /// `nil` once the user finishes-and-saves or discards.
    @Published public private(set) var interruptedSessionStart: ActiveSessionMarker?

    /// Latest snapshot of HealthKit heart-rate authorization. Updated on
    /// app launch, foreground (so granting in iOS Settings.app and returning
    /// reflects immediately), and after every explicit `requestAuthorization`.
    @Published public private(set) var healthAuthorization: HealthAuthorizationStatus = .unknown

    // MARK: Simulation
    /// Replay harness. Always instantiated so its `@Published` state is
    /// bindable from the UI; idle until `startSimulation(_:)` is called.
    public let scenarioRunner: ScenarioRunner = ScenarioRunner()

    @Published public private(set) var runtimeMode: AppRuntimeMode = .live
    @Published public private(set) var activeScenario: ScenarioType?
    @Published public private(set) var lastScenarioMark: String?

    // MARK: Session-hook lifecycle

    /// 1 Hz status snapshot cadence — matches the watch-facing spec.
    private let statusTickSec: Double = 1.0
    /// Gives the Watch a chance to flush tail telemetry before the phone closes the engine session.
    private let remoteStopFlushGraceSec: Double = 2.5
    private var statusTickTask: Task<Void, Never>?
    private var objectChangeBag: Set<AnyCancellable> = []

    /// Timeline sampling. Every `timelineTickSec` we record the current
    /// (stage, time) into a flat buffer; at session-stop we collapse
    /// consecutive same-stage runs into `TimelineEntry` spans.
    private let timelineTickSec: Double = 30.0
    private var timelineTickTask: Task<Void, Never>?
    private var timelineSamples: [(SleepStage, Date)] = []

    public init(
        engine: SleepEngineClientProtocol,
        engineFallbackReason: String?,
        localStore: LocalStoreProtocol,
        insights: LocalInsightsServiceProtocol,
        connectivity: ConnectivityManagerProtocol,
        health: HealthPermissionServiceProtocol,
        heartRateStream: HeartRateStreaming,
        healthWriter: HealthKitSleepWriting? = nil,
        snoreDetector: SnoreDetectorProtocol? = nil,
        personalization: PersonalizationService? = nil,
        inferenceModel: StageInferenceModel? = nil,
        inferenceFallbackReason: String? = nil,
        diagnostics: DiagnosticsStoreProtocol = InMemoryDiagnosticsStore(),
        markerStore: ActiveSessionMarkerStoreProtocol = InMemoryActiveSessionMarkerStore()
    ) {
        self.engine = engine
        self.engineFallbackReason = engineFallbackReason
        self.localStore = localStore
        self.insights = insights
        self.connectivity = connectivity
        self.health = health
        self.heartRateStream = heartRateStream
        self.healthWriter = healthWriter ?? EngineHost.makeHealthKitSleepWriter()
        self.snoreDetector = snoreDetector ?? EngineHost.makeSnoreDetector()
        self.personalization = personalization ?? EngineHost.makePersonalizationService()
        self.diagnostics = diagnostics
        self.markerStore = markerStore
        let sleepPlanStore = SleepPlanUserDefaultsStore()
        self.sleepPlanStore = sleepPlanStore
        self.sleepPlan = sleepPlanStore.load()

        let resolvedModel: StageInferenceModel
        let resolvedReason: String?
        let resolvedLoadMs: Double
        if let inferenceModel {
            resolvedModel = inferenceModel
            resolvedReason = inferenceFallbackReason
            resolvedLoadMs = 0
        } else {
            let built = SleepEngineFactory.makeInferenceModel()
            resolvedModel = built.model
            resolvedReason = built.fallbackReason
            resolvedLoadMs = built.modelLoadMs
        }
        let pipeline = StageInferencePipeline(model: resolvedModel,
                                              modelLoadMs: resolvedLoadMs)
        self.inferencePipeline = pipeline
        self.inferenceFallbackReason = resolvedReason

        let workout = WorkoutSessionManager(
            engine: engine,
            heartRateStream: heartRateStream,
            inferencePipeline: pipeline
        )
        self.workout = workout
        self.router = TelemetryRouter(connectivity: connectivity,
                                      workout: workout,
                                      diagnostics: diagnostics)
        self.alarm = SmartAlarmController()
        wireNestedObjectChanges()
        wireWatchLifecycleRequests()
        wireScenarioRunner()
    }

    public static func makeDefault() -> AppState {
        let (engine, reason) = EngineHost.makeEngine()
        let stream = EngineHost.makeHeartRateStream()
        let connectivity = EngineHost.makeConnectivity()
        return AppState(
            engine: engine,
            engineFallbackReason: reason,
            localStore: EngineHost.makeLocalStore(),
            insights: LocalInsightsService(),
            connectivity: connectivity,
            health: HealthPermissionService(),
            heartRateStream: stream,
            diagnostics: EngineHost.makeDiagnosticsStore(),
            markerStore: EngineHost.makeActiveSessionMarkerStore()
        )
    }

    // MARK: - Simulation wiring

    /// Installs the product-loop hooks that must be live during *any*
    /// running session — live or simulated. Idempotent; safe to call twice
    /// (e.g. on mode switch) because each sub-install replaces prior state.
    ///
    /// Hooks:
    /// - Alarm trigger handler → `router.sendTriggerAlarm` (awaits app-level ack)
    /// - Router `onAlarmDismissed` → `alarm.noteDismissedByWatch()`
    /// - 1 Hz status-snapshot republication loop
    public func installRunningSessionHooks() {
        alarm.setTriggerHandler { [weak self] in
            guard let self else { return false }
            let sid = self.workout.currentSessionID
            return await self.router.sendTriggerAlarm(sessionId: sid)
        }
        router.onAlarmDismissed = { [weak self] in
            self?.alarm.noteDismissedByWatch()
        }
        startStatusTickLoop()
        startTimelineTickLoop()
        startSnoreDetectorIfEnabled()
        Task { [weak self] in
            guard let self else { return }
            let snap = await self.personalization.snapshot()
            await MainActor.run { self.inferencePipeline.updatePersonalization(snap) }
        }
    }

    /// Tears down hooks installed by `installRunningSessionHooks()`. Does
    /// not clear alarm user-config (target / windowMinutes / isEnabled).
    public func teardownRunningSessionHooks() {
        statusTickTask?.cancel()
        statusTickTask = nil
        timelineTickTask?.cancel()
        timelineTickTask = nil
        snoreDetector.stop()
    }

    private func wireWatchLifecycleRequests() {
        router.onWatchStartRequested = { [weak self] requestedSessionId in
            Task { @MainActor [weak self] in
                await self?.startSessionFromWatch(requestedSessionId: requestedSessionId)
            }
        }
        router.onWatchStopRequested = { [weak self] requestedSessionId in
            Task { @MainActor [weak self] in
                await self?.stopSessionFromWatch(requestedSessionId: requestedSessionId)
            }
        }
    }

    private func wireNestedObjectChanges() {
        workout.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &objectChangeBag)

        router.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &objectChangeBag)

        alarm.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &objectChangeBag)
    }

    private func startSessionFromWatch(requestedSessionId: String?) async {
        guard OnboardingGate.hasCompleted else {
            _ = router.sendStop(sessionId: requestedSessionId)
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStart,
                                sessionId: requestedSessionId,
                                message: "watch-origin start rejected: onboarding incomplete")
            )
            publishSnapshot()
            return
        }

        if interruptedSessionStart != nil {
            await finishInterruptedAndSave()
        }

        guard runtimeMode == .live else {
            publishSnapshot()
            return
        }

        if workout.isTracking {
            if workout.source == .remoteWatch, let sid = workout.currentSessionID {
                _ = router.sendStart(sessionId: sid)
            }
            publishSnapshot()
            return
        }

        do {
            try await workout.startTracking(source: .remoteWatch)
        } catch {
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStart,
                                sessionId: requestedSessionId,
                                message: "watch-origin start failed",
                                error: "\(error)")
            )
            publishSnapshot()
            return
        }

        router.resetSessionTelemetry()
        installRunningSessionHooks()

        let startedAt = workout.sessionStartedAt ?? Date()
        if let sid = workout.currentSessionID {
            await writeActiveMarker(sessionId: sid,
                                    startedAt: startedAt,
                                    source: .remoteWatch,
                                    mode: runtimeMode)
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStart,
                                sessionId: sid,
                                message: "source=\(TrackingSource.remoteWatch.rawValue) origin=watch")
            )
            _ = router.sendStart(sessionId: sid)
        }

        applySleepPlanForTonight()
        if alarm.isEnabled {
            _ = alarm.armIfEnabled(engine: engine)
            _ = router.sendArmAlarm(
                sessionId: workout.currentSessionID,
                target: alarm.target,
                windowMinutes: alarm.windowMinutes
            )
        }

        publishSnapshot()
    }

    private func stopSessionFromWatch(requestedSessionId: String?) async {
        if runtimeMode == .simulated {
            await stopSimulation()
            return
        }
        guard workout.isTracking else {
            publishSnapshot()
            return
        }

        if let requestedSessionId,
           let activeSessionId = workout.currentSessionID,
           requestedSessionId != activeSessionId {
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStop,
                                sessionId: requestedSessionId,
                                message: "watch-origin stop ignored: stale session active=\(activeSessionId)")
            )
            publishSnapshot()
            return
        }

        let sessionId = workout.currentSessionID ?? requestedSessionId

        if alarm.state == .triggered || alarm.state == .failedWatchUnreachable {
            _ = router.sendStopAlarm(sessionId: sessionId)
        }

        let alarmMeta = StoredAlarmMeta(
            enabled: alarm.isEnabled,
            finalStateRaw: alarm.state.rawValue,
            targetTsMs: alarm.isEnabled
                ? Int64(alarm.target.timeIntervalSince1970 * 1000)
                : nil,
            windowMinutes: alarm.windowMinutes,
            triggeredAtTsMs: alarm.triggeredAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            dismissedAtTsMs: alarm.watchAckedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
        alarm.clear()

        if workout.source == .remoteWatch {
            try? await Task.sleep(nanoseconds: UInt64(remoteStopFlushGraceSec * 1_000_000_000))
        }

        let endedAt = Date()
        let timeline = drainTimelineEntries(endedAt: endedAt)
        let source = workout.source
        let mode = runtimeMode
        let startedAt = workout.sessionStartedAt

        teardownRunningSessionHooks()

        do {
            let summary = try await workout.stopTracking()
            if let summary {
                await archiveCompletedSession(
                    summary: summary,
                    startedAt: startedAt
                        ?? Date().addingTimeInterval(-TimeInterval(summary.durationSec)),
                    endedAt: endedAt,
                    timeline: timeline,
                    alarm: alarmMeta,
                    source: source,
                    runtimeMode: mode
                )
                await diagnostics.append(
                    DiagnosticEvent(type: .localStoreWrite,
                                    sessionId: summary.sessionId,
                                    message: "session record persisted from watch stop")
                )
            }
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStop,
                                sessionId: sessionId,
                                message: "origin=watch")
            )
            await clearActiveMarker()
            publishSnapshot()
        } catch {
            await diagnostics.append(
                DiagnosticEvent(type: .sessionStop,
                                sessionId: sessionId,
                                message: "watch-origin stop failed",
                                error: "\(error)")
            )
            await clearActiveMarker()
            publishSnapshot()
        }
    }

    private func startSnoreDetectorIfEnabled() {
        let enabled = UserDefaults.standard.bool(forKey: "settings.enableSnoreDetection")
        guard enabled else { return }
        do { try snoreDetector.start() }
        catch { /* graceful: detector simply stays inactive */ }
    }

    private func startTimelineTickLoop() {
        timelineTickTask?.cancel()
        timelineSamples.removeAll()
        let period = timelineTickSec
        timelineTickTask = Task { [weak self] in
            // Initial sample so even short sessions yield a first entry.
            await MainActor.run {
                guard let self, self.workout.isTracking else { return }
                self.timelineSamples.append((self.workout.currentStage, Date()))
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.workout.isTracking else { return }
                    self.timelineSamples.append((self.workout.currentStage, Date()))
                }
            }
        }
    }

    /// Collapses the current timeline-sample buffer into ordered, non-overlapping
    /// `TimelineEntry` spans. Consecutive samples with the same stage are folded
    /// into a single span. The final span ends at `endedAt`. Caller is expected
    /// to invoke this *before* `teardownRunningSessionHooks()` so the latest
    /// sample is still present.
    public func drainTimelineEntries(endedAt: Date) -> [TimelineEntry] {
        guard !timelineSamples.isEmpty else { return [] }
        let samples = timelineSamples
        timelineSamples.removeAll()
        var out: [TimelineEntry] = []
        var spanStart = samples[0].1
        var spanStage = samples[0].0
        for i in 1..<samples.count {
            let (s, t) = samples[i]
            if s != spanStage {
                out.append(TimelineEntry(stage: spanStage, start: spanStart, end: t))
                spanStart = t
                spanStage = s
            }
        }
        out.append(TimelineEntry(stage: spanStage, start: spanStart, end: endedAt))
        return out.filter { $0.end > $0.start }
    }

    /// Persists a completed session — summary, alarm meta, source, runtime
    /// mode, and timeline entries — through `localStore`. Updates
    /// `latestSummary` on success.
    public func archiveCompletedSession(
        summary: SessionSummary,
        startedAt: Date,
        endedAt: Date,
        timeline: [TimelineEntry],
        alarm: StoredAlarmMeta?,
        source: TrackingSource?,
        runtimeMode: AppRuntimeMode,
        tags: [String]? = nil,
        survey: WakeSurvey? = nil
    ) async {
        let snoreCount = snoreDetector.eventCount
        let record = StoredSessionRecord(
            id: summary.sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            alarm: alarm,
            sourceRaw: source?.rawValue,
            runtimeModeRaw: runtimeMode.rawValue,
            notes: nil,
            tags: tags,
            survey: survey,
            snoreEventCount: snoreCount > 0 ? snoreCount : nil,
            timeline: timeline
        )
        try? await localStore.recordSessionRecord(record)
        latestSummary = summary

        if let survey {
            await ingestSurveyAsLabels(sessionId: summary.sessionId,
                                       timeline: timeline,
                                       survey: survey)
        }

        // Optional Apple Health write-back. Honors the user's Settings toggle
        // and silently degrades if HealthKit is unauthorized.
        let shareEnabled = UserDefaults.standard.bool(forKey: "settings.shareWithHealthKit")
        if shareEnabled, !timeline.isEmpty {
            do {
                try await healthWriter.writeTimeline(timeline, sessionId: summary.sessionId)
                await diagnostics.append(
                    DiagnosticEvent(type: .localStoreWrite,
                                    sessionId: summary.sessionId,
                                    message: "healthkit sleep samples written: \(timeline.count)")
                )
            } catch {
                await diagnostics.append(
                    DiagnosticEvent(type: .localStoreError,
                                    sessionId: summary.sessionId,
                                    message: "healthkit write skipped",
                                    error: "\(error)")
                )
            }
        }
    }

    /// Restores `latestSummary` from disk. Safe to call repeatedly; only
    /// overwrites if the store has a more recent completed session.
    public func restoreLatestSession() async {
        if let s = try? await localStore.latestCompletedSummary() {
            latestSummary = s
        }
    }

    /// Persist a wake-up survey for an already-archived session. Updates the
    /// stored record in place and feeds the survey into personalization.
    public func submitWakeSurvey(sessionId: String, survey: WakeSurvey) async {
        guard var rec = try? await localStore.record(for: sessionId) else { return }
        rec.survey = survey
        try? await localStore.recordSessionRecord(rec)
        await ingestSurveyAsLabels(sessionId: sessionId,
                                   timeline: rec.timeline,
                                   survey: survey)
    }

    /// Persist Sleep Notes (tags + free text) for an already-archived session.
    public func attachSleepNotes(sessionId: String,
                                 tags: [String]?,
                                 note: String?) async {
        guard var rec = try? await localStore.record(for: sessionId) else { return }
        rec.tags = tags
        rec.notes = note
        try? await localStore.recordSessionRecord(rec)
    }

    /// Translate a wake-up survey into personalization labels.
    ///
    /// Heuristic: assume the user actually fell asleep at
    /// `survey.actualFellAsleepAt` (if provided) and woke at
    /// `actualWokeUpAt`. Anything before / after those bounds was wake.
    /// Higher self-reported quality → higher label weight (more trust).
    private func ingestSurveyAsLabels(sessionId: String,
                                      timeline: [TimelineEntry],
                                      survey: WakeSurvey) async {
        guard !timeline.isEmpty else { return }
        let qualityWeight = max(0.2, Float(survey.quality) / 5.0)

        var labels: [PersonalLabel] = []
        for entry in timeline {
            // We don't have stored per-window features yet — approximate
            // with a mid-entry feature vector of zeros plus a single-hot
            // "this stage was active" cue. The weight matrix will still
            // learn class-level bias adjustments per user.
            var feats = Array<Float>(repeating: 0, count: PersonalizationVector.dim)
            feats[0] = Float(entry.end.timeIntervalSince(entry.start) / 3600.0)

            var stage = entry.stage
            if let fa = survey.actualFellAsleepAt, entry.start < fa {
                stage = .wake
            }
            if let wu = survey.actualWokeUpAt, entry.start > wu {
                stage = .wake
            }
            if survey.alarmFeltGood == false, entry == timeline.last,
               stage == .deep {
                // user said alarm woke them in deep; downweight that signal.
                continue
            }
            labels.append(
                PersonalLabel(sessionId: sessionId,
                              features: feats,
                              stage: stage.rawValue,
                              weight: qualityWeight)
            )
        }
        guard !labels.isEmpty else { return }
        await personalization.ingest(labels: labels)
        let snap = await personalization.snapshot()
        inferencePipeline.updatePersonalization(snap)
    }

    private func startStatusTickLoop() {
        statusTickTask?.cancel()
        let period = statusTickSec
        statusTickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await MainActor.run { self.publishSnapshot() }
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
        }
    }

    /// Publishes the current engine/alarm/runtime state to the Watch. Also
    /// called out-of-band by view-models on major transitions.
    public func publishSnapshot() {
        router.pushStatusSnapshot(
            sessionId: workout.currentSessionID,
            isTracking: workout.isTracking,
            source: workout.source,
            stage: workout.isTracking ? workout.currentStage : nil,
            confidence: workout.isTracking ? workout.currentConfidence : nil,
            alarmState: alarm.state,
            alarmTarget: alarm.isEnabled ? alarm.target : nil,
            alarmWindowMinutes: alarm.isEnabled ? alarm.windowMinutes : nil,
            alarmTriggeredAt: alarm.triggeredAt,
            sleepPlan: currentSleepPlan(),
            runtimeModeRaw: runtimeMode.rawValue
        )
    }

    public func currentSleepPlan() -> SleepPlanConfiguration {
        sleepPlan
    }

    public func reloadSleepPlan() {
        sleepPlan = sleepPlanStore.load()
    }

    /// Sleep plan is the product-level source of truth for nightly alarm
    /// timing. Manual alarm edits still work when automatic tracking is off.
    public func applySleepPlanForTonight(now: Date = Date()) {
        reloadSleepPlan()
        let plan = sleepPlan
        guard plan.autoTrackingEnabled else { return }
        let decision = plan.decision(now: now)
        guard decision.shouldArmSmartAlarm else { return }
        alarm.isEnabled = true
        alarm.target = decision.window.wakeTime
        alarm.windowMinutes = plan.smartWakeWindowMinutes
    }

    private func wireScenarioRunner() {
        scenarioRunner.onHeartRate = { [weak self] bpm, date in
            self?.workout.ingestRemoteHeartRate(bpm, at: date)
        }
        scenarioRunner.onAccelWindow = { [weak self] window in
            self?.workout.ingestRemoteAccel(window)
        }
        scenarioRunner.onReachability = { [weak self] reachable in
            // Flip the in-memory bus so router/UI observe the change. This
            // only works against `InMemoryConnectivityManager`; against a
            // real `WCSession` reachability is driven by the OS.
            (self?.connectivity as? InMemoryConnectivityManager)?.setReachable(reachable)
        }
        scenarioRunner.onArmAlarm = { [weak self] target, windowMinutes in
            guard let self else { return }
            self.alarm.isEnabled = true
            self.alarm.target = target
            self.alarm.windowMinutes = windowMinutes
            _ = self.alarm.armIfEnabled(engine: self.engine)
        }
        scenarioRunner.onDismissAlarm = { [weak self] in
            self?.alarm.noteDismissedByWatch()
        }
        scenarioRunner.onMark = { [weak self] label in
            self?.lastScenarioMark = label
        }
        scenarioRunner.onComplete = { [weak self] in
            self?.activeScenario = nil
        }
    }

    /// Enters simulated mode. Forces a clean transition by stopping any
    /// in-flight scenario *and* any currently-active live session so the
    /// new scenario starts from zero state — no duplicated ingestion
    /// loops, no stale pipeline buffers, no leaked alarm state.
    ///
    /// Installs the same product-loop hooks (trigger handler, dismiss
    /// routing, 1 Hz status snapshots) that the live path uses, so a
    /// simulated session exercises the full closed loop.
    public func startSimulation(_ scenario: ScenarioType) async {
        // 1. Kill any prior scenario replay (idempotent).
        scenarioRunner.stop()
        // 2. If a session is running (live or simulated), tear it down so
        //    the workout manager, alarm, and inference pipeline all reset.
        //    Also cancels any in-flight status-tick task / hooks.
        teardownRunningSessionHooks()
        if workout.isTracking {
            _ = try? await workout.stopTracking()
        }
        alarm.clear()
        inferencePipeline.reset()
        // 3. Start a fresh session in the source the scenario expects.
        let src: TrackingSource =
            (scenario == .watchUnavailable) ? .localPhone : .remoteWatch
        do {
            try await workout.startTracking(source: src)
        } catch {
            runtimeMode = .live
            activeScenario = nil
            return
        }
        router.resetSessionTelemetry()
        runtimeMode = .simulated
        activeScenario = scenario
        lastScenarioMark = nil
        // Persist active-session marker so an interruption is recoverable.
        if let sid = workout.currentSessionID {
            await writeActiveMarker(sessionId: sid,
                                     startedAt: Date(),
                                     source: src,
                                     mode: .simulated)
        }
        // 4. Wire the product loop (trigger handler + dismiss route +
        //    1 Hz snapshot republish) and kick the scenario runner.
        installRunningSessionHooks()
        publishSnapshot()
        scenarioRunner.start(scenario)
    }

    /// Stops any running scenario and returns the app to `.live` mode.
    /// Also clears the active session so the next Start uses fresh state.
    public func stopSimulation() async {
        scenarioRunner.stop()
        activeScenario = nil
        runtimeMode = .live
        alarm.clear()
        teardownRunningSessionHooks()
        if workout.isTracking {
            _ = try? await workout.stopTracking()
        }
        inferencePipeline.reset()
        publishSnapshot()
        await clearActiveMarker()
    }

    // MARK: - M7 lifecycle / diagnostics

    /// Emit `appLaunch` and detect an interrupted session marker, if any.
    /// Idempotent: callers may invoke once per process via `.task { ... }`.
    public func appLaunch() async {
        // Apply persisted user preferences before any inference runs.
        if let stored = UserDefaults.standard.object(forKey: "settings.personalizationEnabled") as? Bool {
            inferencePipeline.personalizationEnabled = stored
        }
        await diagnostics.append(DiagnosticEvent(type: .appLaunch))
        await health.probeHeartRateReadAccess()
        refreshHealthAuthorization()
        await detectInterruptedSession()
        publishSnapshot()
    }

    public func appForeground() {
        publishSnapshot()
        Task { [diagnostics] in
            await diagnostics.append(DiagnosticEvent(type: .appForeground))
        }
        // Re-poll HealthKit each time the user returns from background.
        // Crucially this runs after the user grants permission in iOS
        // Settings.app and switches back to Circadia — without it the
        // start button stays gated on a stale "denied" state.
        //
        // We MUST run a real sample-query probe here because
        // `authorizationStatus(for:)` only reflects WRITE permission;
        // for read-only types it returns `.sharingDenied` even after the
        // user grants access (Apple privacy design).
        Task { [weak self] in
            guard let self else { return }
            await self.health.probeHeartRateReadAccess()
            await MainActor.run { self.refreshHealthAuthorization() }
        }
    }

    /// Re-reads the latest HealthKit authorization status and republishes
    /// it. Cheap; callers may invoke freely.
    public func refreshHealthAuthorization() {
        healthAuthorization = health.heartRateAuthorization()
    }

    public func appBackground() {
        Task { [diagnostics] in
            await diagnostics.append(DiagnosticEvent(type: .appBackground))
        }
    }

    /// Reads the marker; if present, publishes `interruptedSessionStart`
    /// and emits `sessionInterruptedDetected`.
    public func detectInterruptedSession() async {
        if let m = await markerStore.read() {
            interruptedSessionStart = m
            await diagnostics.append(
                DiagnosticEvent(type: .sessionInterruptedDetected,
                                sessionId: m.sessionId,
                                message: "marker found on launch")
            )
        }
    }

    /// Persists a best-effort `StoredSessionRecord` for the interrupted
    /// session and clears the marker. No engine interaction; the engine
    /// state from the previous process is gone.
    public func finishInterruptedAndSave() async {
        guard let m = interruptedSessionStart else { return }
        let now = Date()
        let durationSec = max(0, Int(now.timeIntervalSince(m.startedAt)))
        // Best-effort empty summary; UI shows it as interrupted via notes.
        let summary = SessionSummary(
            sessionId: m.sessionId,
            durationSec: durationSec,
            timeInWakeSec: 0,
            timeInLightSec: 0,
            timeInDeepSec: 0,
            timeInRemSec: 0,
            sleepScore: 0
        )
        let alarmMeta: StoredAlarmMeta? = m.smartAlarmEnabled
            ? StoredAlarmMeta(enabled: true,
                              finalStateRaw: AlarmState.idle.rawValue,
                              targetTsMs: m.alarmTargetTsMs,
                              windowMinutes: m.alarmWindowMinutes ?? 0)
            : nil
        let rec = StoredSessionRecord(
            id: m.sessionId,
            startedAt: m.startedAt,
            endedAt: now,
            summary: summary,
            alarm: alarmMeta,
            sourceRaw: m.sourceRaw,
            runtimeModeRaw: m.runtimeModeRaw,
            notes: "Interrupted: app was terminated before stop. Best-effort recovered.",
            timeline: []
        )
        do {
            try await localStore.recordSessionRecord(rec)
            latestSummary = summary
            await diagnostics.append(
                DiagnosticEvent(type: .sessionInterruptedFinished,
                                sessionId: m.sessionId,
                                message: "user finished+saved interrupted session")
            )
        } catch {
            await diagnostics.append(
                DiagnosticEvent(type: .localStoreError,
                                sessionId: m.sessionId,
                                error: "\(error)")
            )
        }
        await markerStore.clear()
        interruptedSessionStart = nil
    }

    public func discardInterruptedSession() async {
        let sid = interruptedSessionStart?.sessionId
        await markerStore.clear()
        interruptedSessionStart = nil
        await diagnostics.append(
            DiagnosticEvent(type: .sessionInterruptedDiscarded, sessionId: sid)
        )
    }

    /// Writes a marker for the currently running session. Caller passes the
    /// session id (after `workout.startTracking`) and the runtime mode so we
    /// can also recover whether the run was simulated.
    public func writeActiveMarker(sessionId: String,
                                   startedAt: Date,
                                   source: TrackingSource,
                                   mode: AppRuntimeMode) async {
        let alarmTargetMs: Int64? = alarm.isEnabled
            ? Int64(alarm.target.timeIntervalSince1970 * 1000)
            : nil
        let m = ActiveSessionMarker(
            sessionId: sessionId,
            startedAt: startedAt,
            sourceRaw: source.rawValue,
            runtimeModeRaw: mode.rawValue,
            smartAlarmEnabled: alarm.isEnabled,
            alarmTargetTsMs: alarmTargetMs,
            alarmWindowMinutes: alarm.isEnabled ? alarm.windowMinutes : nil
        )
        await markerStore.write(m)
    }

    public func clearActiveMarker() async {
        await markerStore.clear()
    }

    /// Generates an `UnattendedReport` for the latest stored session by
    /// merging diagnostic events + persisted session record. Returns `nil`
    /// when no session has been stored yet.
    public func generateLatestUnattendedReport() async -> UnattendedReport? {
        let events = await diagnostics.all()
        let sessions = (try? await localStore.listSessions(limit: 1)) ?? []
        guard let latestSession = sessions.first else {
            // No persisted sessions yet — try to build a context-only report
            // from events alone when we do have any.
            if events.isEmpty { return nil }
            return UnattendedReportBuilder.build(events: events)
        }
        let record = try? await localStore.record(for: latestSession.id)
        return UnattendedReportBuilder.build(events: events,
                                              record: record,
                                              sessionId: latestSession.id)
    }
}
