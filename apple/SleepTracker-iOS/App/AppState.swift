import Foundation
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

    @Published public var latestSummary: SessionSummary?

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
    private var statusTickTask: Task<Void, Never>?

    public init(
        engine: SleepEngineClientProtocol,
        engineFallbackReason: String?,
        localStore: LocalStoreProtocol,
        insights: LocalInsightsServiceProtocol,
        connectivity: ConnectivityManagerProtocol,
        health: HealthPermissionServiceProtocol,
        heartRateStream: HeartRateStreaming,
        inferenceModel: StageInferenceModel? = nil,
        inferenceFallbackReason: String? = nil
    ) {
        self.engine = engine
        self.engineFallbackReason = engineFallbackReason
        self.localStore = localStore
        self.insights = insights
        self.connectivity = connectivity
        self.health = health
        self.heartRateStream = heartRateStream

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
        self.router = TelemetryRouter(connectivity: connectivity, workout: workout)
        self.alarm = SmartAlarmController()
        wireScenarioRunner()
    }

    public static func makeDefault() -> AppState {
        let (engine, reason) = EngineHost.makeEngine()
        let stream = EngineHost.makeHeartRateStream()
        let connectivity = EngineHost.makeConnectivity()
        return AppState(
            engine: engine,
            engineFallbackReason: reason,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: connectivity,
            health: HealthPermissionService(),
            heartRateStream: stream
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
    }

    /// Tears down hooks installed by `installRunningSessionHooks()`. Does
    /// not clear alarm user-config (target / windowMinutes / isEnabled).
    public func teardownRunningSessionHooks() {
        statusTickTask?.cancel()
        statusTickTask = nil
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
            runtimeModeRaw: runtimeMode.rawValue
        )
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
        runtimeMode = .simulated
        activeScenario = scenario
        lastScenarioMark = nil
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
    }
}
