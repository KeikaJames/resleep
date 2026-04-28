import XCTest
@testable import SleepTracker_iOS
import SleepKit

/// M6.7 app-target test: locks the simulation-restart contract so two
/// `startSimulation` calls in a row do NOT stack two parallel 1 Hz
/// status-snapshot loops on top of each other, and stopSimulation
/// fully cancels the loop.
@MainActor
final class M67SimulationLoopsTests: XCTestCase {

    /// Build an AppState wired to the in-memory loopback bus so we can
    /// observe the phone's outbound status snapshots through the same
    /// inbound-handler channel without needing a real WCSession.
    private func makeLoopbackAppState() -> AppState {
        let (engine, reason) = EngineHost.makeEngine()
        return AppState(
            engine: engine,
            engineFallbackReason: reason,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: InMemoryConnectivityManager(),
            health: HealthPermissionService(),
            heartRateStream: MockHeartRateStream()
        )
    }

    private func makeAppState(connectivity: ConnectivityManagerProtocol) -> AppState {
        AppState(
            engine: InMemorySleepEngineClient(),
            engineFallbackReason: nil,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: connectivity,
            health: GrantingHealthPermissionService(),
            heartRateStream: MockHeartRateStream(),
            inferenceModel: FallbackHeuristicStageInferenceModel()
        )
    }

    func testStartSimulationDoesNotDuplicateStatusTickLoops() async throws {
        let appState = makeLoopbackAppState()
        let counter = SnapshotCounter()
        appState.connectivity.setInboundHandler { env in
            if env.kind == .statusSnapshot { counter.bump() }
        }

        await appState.startSimulation(.fallingAsleep)
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        let afterFirst = counter.value

        // Restart the same scenario — the prior 1 Hz loop must be torn
        // down so we do NOT see double the snapshot rate after this.
        await appState.startSimulation(.fallingAsleep)
        let baseline = counter.value
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        let delta = counter.value - baseline

        await appState.stopSimulation()

        XCTAssertGreaterThanOrEqual(afterFirst, 2,
            "should publish >=2 snapshots in 2.4s at 1 Hz (got \(afterFirst))")
        XCTAssertGreaterThanOrEqual(delta, 1,
            "after restart, at least one status loop must still be running (got \(delta))")
        // 1 Hz nominal → ~2 ticks in 2.4s. Duplicate loops would push
        // this toward 4–6. Cap at 5 with slack for scheduler jitter.
        XCTAssertLessThanOrEqual(delta, 5,
            "after restart, snapshot rate must not double — got \(delta) in 2.4s")
    }

    /// stopSimulation must cancel the status tick loop. After stop, no
    /// further snapshots should arrive (allow at most one tail).
    func testStopSimulationCancelsStatusTickLoop() async throws {
        let appState = makeLoopbackAppState()
        let counter = SnapshotCounter()
        appState.connectivity.setInboundHandler { env in
            if env.kind == .statusSnapshot { counter.bump() }
        }

        await appState.startSimulation(.fallingAsleep)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await appState.stopSimulation()
        let baseline = counter.value
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let postStop = counter.value - baseline

        XCTAssertLessThanOrEqual(postStop, 1,
            "status loop must be cancelled after stopSimulation (got \(postStop))")
    }

    /// If the user has a paired Watch app but the link is temporarily asleep,
    /// Start must queue a Watch session instead of silently falling back to
    /// iPhone-local tracking. The latter looks successful but usually records
    /// no overnight heart-rate stream.
    func testManualStartQueuesWatchWhenInstalledButInitiallyUnreachable() async throws {
        let connectivity = RecordingConnectivity(reachable: false,
                                                  paired: true,
                                                  installed: true)
        let appState = makeAppState(connectivity: connectivity)
        let vm = HomeViewModel()
        vm.bind(appState: appState)

        await vm.toggleSession()

        XCTAssertTrue(appState.workout.isTracking)
        XCTAssertEqual(appState.workout.source, .remoteWatch)
        XCTAssertEqual(connectivity.guaranteed.count, 1)
        let control = try XCTUnwrap(try? connectivity.guaranteed[0].decode(ControlPayload.self))
        XCTAssertEqual(control.command, .startTracking)
        XCTAssertEqual(vm.lastError,
                       NSLocalizedString("home.error.watchStartQueued", comment: ""))

        appState.teardownRunningSessionHooks()
        _ = try? await appState.workout.stopTracking()
    }

    func testStaleWatchStopDoesNotEndActivePhoneSession() async throws {
        let connectivity = RecordingConnectivity(reachable: true,
                                                  paired: true,
                                                  installed: true)
        let appState = makeAppState(connectivity: connectivity)
        try await appState.workout.startTracking(source: .remoteWatch)
        appState.installRunningSessionHooks()
        let activeSessionId = try XCTUnwrap(appState.workout.currentSessionID)
        let staleStop = try XCTUnwrap(try? WatchMessage.stopTracking(sessionId: "old-session"))

        connectivity.deliver(staleStop)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(appState.workout.isTracking)
        XCTAssertEqual(appState.workout.currentSessionID, activeSessionId)

        appState.teardownRunningSessionHooks()
        _ = try? await appState.workout.stopTracking()
    }

    func testStaleWatchTelemetryIsDroppedForActiveSession() async throws {
        let connectivity = RecordingConnectivity(reachable: true,
                                                  paired: true,
                                                  installed: true)
        let appState = makeAppState(connectivity: connectivity)
        try await appState.workout.startTracking(source: .remoteWatch)
        let activeSessionId = try XCTUnwrap(appState.workout.currentSessionID)
        let batch = TelemetryBatchPayload(
            heartRates: [HeartRatePoint(tsMs: WallClock.nowMs(), bpm: 72)],
            accelWindows: []
        )
        let staleTelemetry = try XCTUnwrap(try? WatchMessage.telemetryBatch(
            sessionId: "old-session",
            payload: batch
        ))
        let currentTelemetry = try XCTUnwrap(try? WatchMessage.telemetryBatch(
            sessionId: activeSessionId,
            payload: batch
        ))

        connectivity.deliver(staleTelemetry)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(appState.router.lastBatchAt)

        connectivity.deliver(currentTelemetry)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(appState.router.lastBatchAt)
        XCTAssertEqual(appState.router.lastBatchHRCount, 1)

        _ = try? await appState.workout.stopTracking()
    }
}

private final class SnapshotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class GrantingHealthPermissionService: HealthPermissionServiceProtocol {
    func isAvailable() -> Bool { true }
    func heartRateAuthorization() -> HealthAuthorizationStatus { .sharingAuthorized }
    func requestAuthorization() async throws {}
    func authorizationStatusDescription() -> String { "test-authorized" }
    func probeHeartRateReadAccess() async {}
}

private final class RecordingConnectivity: ConnectivityManagerProtocol, @unchecked Sendable {
    var isSupported: Bool = true
    var isReachable: Bool
    var isPaired: Bool
    var isWatchAppInstalled: Bool

    private(set) var immediate: [MessageEnvelope] = []
    private(set) var guaranteed: [MessageEnvelope] = []
    private(set) var snapshots: [StatusSnapshotPayload] = []
    private var inboundHandler: (@Sendable (MessageEnvelope) -> Void)?

    init(reachable: Bool, paired: Bool, installed: Bool) {
        self.isReachable = reachable
        self.isPaired = paired
        self.isWatchAppInstalled = installed
    }

    func activate() {}

    func sendImmediateMessage(_ envelope: MessageEnvelope) throws {
        guard isReachable else { throw ConnectivityError.notReachable }
        immediate.append(envelope)
    }

    func sendGuaranteedMessage(_ envelope: MessageEnvelope) {
        guaranteed.append(envelope)
    }

    func updateStatusSnapshot(_ snapshot: StatusSnapshotPayload, sessionId: String?) throws {
        snapshots.append(snapshot)
    }

    func setInboundHandler(_ handler: @escaping @Sendable (MessageEnvelope) -> Void) {
        inboundHandler = handler
    }

    func deliver(_ envelope: MessageEnvelope) {
        inboundHandler?(envelope)
    }

    func setReachabilityHandler(_ handler: @escaping @Sendable (Bool) -> Void) {}
}
