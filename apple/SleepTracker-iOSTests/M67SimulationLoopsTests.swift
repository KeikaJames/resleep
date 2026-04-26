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
}

private final class SnapshotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
