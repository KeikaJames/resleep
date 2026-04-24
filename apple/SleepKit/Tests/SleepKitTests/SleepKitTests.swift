import XCTest
@testable import SleepKit

final class SleepKitTests: XCTestCase {

    // MARK: - M4: StatusSnapshotPayload round-trip with alarm fields

    func testStatusSnapshotRichRoundTrip() throws {
        let snap = StatusSnapshotPayload(
            isTracking: true, reachable: true,
            currentStageRaw: SleepStage.deep.rawValue,
            currentConfidence: 0.77,
            lastSyncTsMs: 123_456,
            trackingSourceRaw: TrackingSourceWire.watch.rawValue,
            alarmStateRaw: AlarmState.triggered.rawValue,
            alarmTargetTsMs: 999_000,
            alarmWindowMinutes: 20,
            alarmTriggeredAtTsMs: 998_000
        )
        let data = try JSONEncoder().encode(snap)
        let round = try JSONDecoder().decode(StatusSnapshotPayload.self, from: data)
        XCTAssertEqual(round.alarmState, .triggered)
        XCTAssertEqual(round.trackingSource, .watch)
        XCTAssertEqual(round.alarmWindowMinutes, 20)
    }

    // MARK: - M4: smart alarm fires handler exactly once, state → triggered

    @MainActor
    func testSmartAlarmTriggersOnce() async throws {
        let engine = CountingEngine()
        engine.triggerSequence = [false, true, true, true]  // fire on second poll
        let controller = SmartAlarmController()
        controller.isEnabled = true
        controller.target = Date().addingTimeInterval(-60)   // force "in window"
        controller.windowMinutes = 5
        controller.finePollSec = 0.01
        controller.coarsePollSec = 0.01

        let triggerCount = TestCounter()
        controller.setTriggerHandler {
            triggerCount.increment()
            return true
        }
        XCTAssertTrue(controller.armIfEnabled(engine: engine))
        try await waitUntil(timeout: 1.0) { controller.state == .triggered }
        XCTAssertEqual(triggerCount.value, 1)

        // Give the loop a moment to (not) re-fire.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(triggerCount.value, 1)
    }

    // MARK: - M4: dismiss clears state and blocks re-trigger

    @MainActor
    func testSmartAlarmDismissClearsState() async throws {
        let engine = CountingEngine()
        engine.triggerSequence = [true]
        let controller = SmartAlarmController()
        controller.isEnabled = true
        controller.target = Date().addingTimeInterval(-60)
        controller.windowMinutes = 5
        controller.finePollSec = 0.01
        controller.coarsePollSec = 0.01
        controller.setTriggerHandler { true }
        _ = controller.armIfEnabled(engine: engine)
        try await waitUntil(timeout: 1.0) { controller.state == .triggered }
        controller.noteDismissedByWatch()
        XCTAssertEqual(controller.state, .dismissed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state, .dismissed)  // no re-entry
    }

    // MARK: - M4: unreachable handler → failedWatchUnreachable

    @MainActor
    func testSmartAlarmUnreachableMarksFailed() async throws {
        let engine = CountingEngine()
        engine.triggerSequence = [true]
        let controller = SmartAlarmController()
        controller.isEnabled = true
        controller.target = Date().addingTimeInterval(-60)
        controller.windowMinutes = 5
        controller.finePollSec = 0.01
        controller.coarsePollSec = 0.01
        controller.setTriggerHandler { false }
        _ = controller.armIfEnabled(engine: engine)
        try await waitUntil(timeout: 1.0) { controller.state == .failedWatchUnreachable }
        XCTAssertEqual(controller.state, .failedWatchUnreachable)
    }

    // MARK: - M4: disabled arm is a no-op

    @MainActor
    func testSmartAlarmDisabledIsNoop() {
        let engine = CountingEngine()
        let controller = SmartAlarmController()
        controller.isEnabled = false
        XCTAssertFalse(controller.armIfEnabled(engine: engine))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.armCount, 0)
    }

    // MARK: - Existing M2/M3 in-memory engine smoke

    @MainActor
    func testInMemoryEngineHappyPath() throws {
        let engine = InMemorySleepEngineClient()
        let id = try engine.startSession(at: Date())
        XCTAssertFalse(id.isEmpty)
        try engine.pushHeartRate(62, at: Date())
        try engine.pushAccelerometer(x: 0, y: 0, z: 0.98, at: Date())
        let summary = try engine.endSession()
        XCTAssertEqual(summary.sessionId, id)
    }

    // MARK: - M3: envelope round-trip

    func testEnvelopeDictionaryRoundTrip() throws {
        let payload = TelemetryBatchPayload(
            heartRates: [HeartRatePoint(tsMs: 1_000, bpm: 64)],
            accelWindows: [
                AccelWindow(tsMs: 1_000, meanX: 0, meanY: 0, meanZ: 1,
                            magnitudeMean: 1, energy: 1, sampleCount: 10)
            ]
        )
        let env = try WatchMessage.telemetryBatch(sessionId: "s1", payload: payload)
        let dict = env.toDictionary()
        let decoded = MessageEnvelope.fromDictionary(dict)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.kind, .telemetryBatch)
        let reparsed = try decoded!.decode(TelemetryBatchPayload.self)
        XCTAssertEqual(reparsed.heartRates.first?.bpm, 64)
    }

    // MARK: - M3: mock bus routes envelopes between endpoints

    func testMockBusPhoneToWatchDelivery() throws {
        let bus = MockConnectivityBus()
        let received = TestActor()
        bus.watch.setInboundHandler { env in
            received.put(env)
        }
        let env = try WatchMessage.startTracking(sessionId: "sX")
        try bus.sendFromPhone(env)
        XCTAssertEqual(received.take()?.kind, .control)
    }

    // MARK: - M3: unreachable falls through to guaranteed

    func testUnreachableRoutesToGuaranteed() throws {
        // Single endpoint: sendImmediate must throw when unreachable,
        // but sendGuaranteed still delivers (transferUserInfo semantics).
        let ep = InMemoryConnectivityManager()
        ep.setReachable(false)
        let received = TestActor()
        ep.setInboundHandler { received.put($0) }

        let env = try WatchMessage.startTracking(sessionId: "sY")
        XCTAssertThrowsError(try ep.sendImmediateMessage(env))
        ep.sendGuaranteedMessage(env)
        XCTAssertEqual(received.take()?.kind, .control)
    }

    // MARK: - M3: telemetry routed into engine

    @MainActor
    func testTelemetryRoutedIntoEngine() async throws {
        let engine = CountingEngine()
        let stream = MockHeartRateStream()
        let workout = WorkoutSessionManager(engine: engine, heartRateStream: stream,
                                            refreshInterval: 10.0)
        try await workout.startTracking(source: .remoteWatch)

        let batch = TelemetryBatchPayload(
            heartRates: [
                HeartRatePoint(tsMs: WallClock.nowMs(), bpm: 60),
                HeartRatePoint(tsMs: WallClock.nowMs(), bpm: 62),
            ],
            accelWindows: [
                AccelWindow(tsMs: WallClock.nowMs(), meanX: 0, meanY: 0, meanZ: 1,
                            magnitudeMean: 1, energy: 1, sampleCount: 10)
            ]
        )
        for hr in batch.heartRates {
            workout.ingestRemoteHeartRate(hr.bpm, at: WallClock.date(ms: hr.tsMs))
        }
        for w in batch.accelWindows {
            workout.ingestRemoteAccel(w)
        }
        XCTAssertEqual(engine.hrCount, 2)
        XCTAssertEqual(engine.accelCount, 1)
        _ = try await workout.stopTracking()
    }

    // MARK: - M3: AccelAggregator math

    func testAccelAggregatorDrain() {
        var agg = AccelAggregator()
        agg.append(MotionSample(tsMs: 10, x: 0, y: 0, z: 1))
        agg.append(MotionSample(tsMs: 20, x: 0, y: 0, z: 1))
        let win = agg.drainWindow(endTsMs: 20)
        XCTAssertEqual(win?.sampleCount, 2)
        XCTAssertEqual(win?.meanZ ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(win?.magnitudeMean ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(agg.drainWindow(endTsMs: 30))
    }

    // MARK: - M5: feature window builder summarises HR + accel

    func testFeatureWindowBuilderSummarises() {
        var b = FeatureWindowBuilder()
        let t0 = Date()
        b.addHeartRate(60, at: t0)
        b.addHeartRate(64, at: t0.addingTimeInterval(10))
        b.addHeartRate(68, at: t0.addingTimeInterval(20))
        b.addAccelWindow(meanX: 0, meanY: 0, meanZ: 1, energy: 0.5, variance: 0.1, at: t0)
        let v = b.currentFeatureVector(now: t0.addingTimeInterval(20))
        XCTAssertEqual(v.count, StageInferenceHyperparameters.default.featureDim)
        XCTAssertEqual(v[StageFeature.hrMean.rawValue], 64, accuracy: 0.001)
        XCTAssertGreaterThan(v[StageFeature.hrSlope.rawValue], 0)
        XCTAssertEqual(v[StageFeature.accelEnergy.rawValue], 0.5, accuracy: 0.001)
        XCTAssertEqual(v[StageFeature.accelMean.rawValue], 1, accuracy: 0.001)
    }

    // MARK: - M5: sequence buffer fills and rolls

    func testSequenceBufferFillsAndRolls() {
        var buf = SequenceBuffer(seqLen: 4, featureDim: 3)
        XCTAssertFalse(buf.isFull)
        XCTAssertEqual(buf.snapshot().count, 4)  // padded
        XCTAssertEqual(buf.snapshot().first?.allSatisfy { $0 == 0 }, true)

        for i in 0..<6 {
            buf.append([Float(i), Float(i), Float(i)])
        }
        XCTAssertTrue(buf.isFull)
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 4)
        // Oldest retained value should be the 3rd push (index 2).
        XCTAssertEqual(snap.first?[0], 2)
        XCTAssertEqual(snap.last?[0], 5)
    }

    // MARK: - M5: heuristic model classifies motion vs calm

    func testHeuristicModelClassifies() throws {
        let model = FallbackHeuristicStageInferenceModel()
        let hp = model.hyperparameters
        // High-accel → wake
        let wakeRow: [Float] = {
            var r = Array<Float>(repeating: 0, count: hp.featureDim)
            r[StageFeature.accelEnergy.rawValue] = 2.0
            r[StageFeature.accelMean.rawValue] = 1.5
            r[StageFeature.hrMean.rawValue] = 70
            return r
        }()
        let wakeWindow = Array(repeating: wakeRow, count: hp.seqLen)
        let wakeOut = try model.predict(
            StageInferenceInput(window: wakeWindow, seqLen: hp.seqLen, featureDim: hp.featureDim)
        )
        XCTAssertEqual(wakeOut.stage, .wake)
        XCTAssertEqual(wakeOut.probabilities.count, 4)

        // Low-accel + negative HR slope → deep
        let deepRow: [Float] = {
            var r = Array<Float>(repeating: 0, count: hp.featureDim)
            r[StageFeature.accelEnergy.rawValue] = 0.01
            r[StageFeature.accelMean.rawValue] = 0.05
            r[StageFeature.hrSlope.rawValue] = -1.5
            r[StageFeature.hrMean.rawValue] = 55
            return r
        }()
        let deepWindow = Array(repeating: deepRow, count: hp.seqLen)
        let deepOut = try model.predict(
            StageInferenceInput(window: deepWindow, seqLen: hp.seqLen, featureDim: hp.featureDim)
        )
        XCTAssertEqual(deepOut.stage, .deep)
    }

    // MARK: - M5: factory falls back to heuristic when bundle has no model

    @MainActor
    func testFactoryFallsBackWhenNoModel() {
        let built = SleepEngineFactory.makeInferenceModel(
            bundle: .main,  // test bundle; no SleepStager.mlmodelc
            resourceName: "SleepStager__absent__"
        )
        XCTAssertFalse(built.model.isRealModel)
        XCTAssertNotNil(built.fallbackReason)
        XCTAssertEqual(built.modelLoadMs, 0)
    }

    // MARK: - M5: pipeline publishes output and resets cleanly

    @MainActor
    func testPipelinePublishesAndResets() {
        let pipeline = StageInferencePipeline(model: FallbackHeuristicStageInferenceModel())
        XCTAssertNil(pipeline.latest)
        let t0 = Date()
        pipeline.ingestHeartRate(60, at: t0)
        pipeline.ingestAccelWindow(
            AccelWindow(tsMs: UInt64(t0.timeIntervalSince1970 * 1000), meanX: 0, meanY: 0, meanZ: 1,
                        magnitudeMean: 1, energy: 0.1, sampleCount: 10)
        )
        let out = pipeline.tick(now: t0)
        XCTAssertNotNil(out)
        XCTAssertEqual(pipeline.inferenceCount, 1)
        XCTAssertNotNil(pipeline.latest)

        // Cadence throttle: a tick inside the cadence window produces nothing.
        let throttled = pipeline.tick(now: t0.addingTimeInterval(0.1))
        XCTAssertNil(throttled)
        XCTAssertEqual(pipeline.inferenceCount, 1)

        pipeline.reset()
        XCTAssertNil(pipeline.latest)
        XCTAssertEqual(pipeline.inferenceCount, 0)
    }

    // MARK: - M5: pipeline-backed workout manager prefers pipeline stage

    @MainActor
    func testWorkoutManagerPrefersPipelineStage() async throws {
        let engine = CountingEngine()
        let stream = MockHeartRateStream()
        let pipeline = StageInferencePipeline(model: FallbackHeuristicStageInferenceModel())
        let workout = WorkoutSessionManager(
            engine: engine, heartRateStream: stream,
            refreshInterval: 10.0,  // prevent auto-tick interference
            inferencePipeline: pipeline
        )
        try await workout.startTracking(source: .remoteWatch)
        // Feed a clearly "wake"-shaped accel window so the heuristic model
        // lands on .wake (engine default is also .wake in the fake, so also
        // sanity-check confidence > 0).
        workout.ingestRemoteAccel(
            AccelWindow(tsMs: WallClock.nowMs(), meanX: 1, meanY: 0, meanZ: 1,
                        magnitudeMean: 1.4, energy: 3.0, sampleCount: 10)
        )
        workout.ingestRemoteHeartRate(72, at: Date())
        // Drive the private refresh via tick-on-pipeline and then stop.
        _ = pipeline.tick()
        XCTAssertNotNil(pipeline.latest)
        XCTAssertEqual(pipeline.latest?.stage, .wake)
        XCTAssertGreaterThan(pipeline.latest?.confidence ?? 0, 0.25)
        _ = try await workout.stopTracking()
        // stopTracking should have reset the pipeline.
        XCTAssertNil(pipeline.latest)
    }

    // MARK: - M6: model contract constants are pinned

    func testModelContractConstants() {
        XCTAssertEqual(ModelContract.seqLen, 16)
        XCTAssertEqual(ModelContract.featureDim, 9)
        XCTAssertEqual(ModelContract.numClasses, 4)
        XCTAssertEqual(ModelContract.inputName, "features")
        XCTAssertEqual(ModelContract.outputName, "logits")
        XCTAssertEqual(ModelContract.resourceName, "SleepStager")
    }

    // MARK: - M6: descriptor surfaces for heuristic model

    @MainActor
    func testHeuristicDescriptorSurfaces() {
        let model = FallbackHeuristicStageInferenceModel()
        let d = model.descriptor
        XCTAssertEqual(d.kind, .heuristicFallback)
        XCTAssertFalse(d.isRealModel)
        XCTAssertEqual(d.inputName, ModelContract.inputName)
        XCTAssertEqual(d.outputName, ModelContract.outputName)

        let pipeline = StageInferencePipeline(model: model)
        XCTAssertEqual(pipeline.descriptor.kind, .heuristicFallback)
    }

    // MARK: - M6: inference instrumentation records timings

    @MainActor
    func testPipelineRecordsMetrics() {
        let pipeline = StageInferencePipeline(
            model: FallbackHeuristicStageInferenceModel(),
            modelLoadMs: 12.5
        )
        // Initial metrics reflect construction state.
        XCTAssertEqual(pipeline.metrics.modelLoadMs, 12.5, accuracy: 0.001)
        XCTAssertEqual(pipeline.metrics.inferenceCount, 0)
        XCTAssertFalse(pipeline.metrics.modelLoaded)  // heuristic == not real

        let t0 = Date()
        pipeline.ingestHeartRate(62, at: t0)
        pipeline.ingestAccelWindow(
            AccelWindow(tsMs: UInt64(t0.timeIntervalSince1970 * 1000),
                        meanX: 0, meanY: 0, meanZ: 1,
                        magnitudeMean: 1, energy: 0.1, sampleCount: 10)
        )
        _ = pipeline.tick(now: t0)
        XCTAssertEqual(pipeline.metrics.inferenceCount, 1)
        XCTAssertGreaterThanOrEqual(pipeline.metrics.lastPredictMs, 0)
        XCTAssertGreaterThanOrEqual(pipeline.metrics.rollingAvgPredictMs, 0)
        XCTAssertNotNil(pipeline.metrics.lastInferenceAt)
    }

    // MARK: - M6: reset is idempotent and preserves load state

    @MainActor
    func testPipelineResetIsIdempotent() {
        let pipeline = StageInferencePipeline(
            model: FallbackHeuristicStageInferenceModel(),
            modelLoadMs: 4.0
        )
        let t0 = Date()
        pipeline.ingestHeartRate(60, at: t0)
        pipeline.ingestAccelWindow(
            AccelWindow(tsMs: UInt64(t0.timeIntervalSince1970 * 1000),
                        meanX: 0, meanY: 0, meanZ: 1,
                        magnitudeMean: 1, energy: 0.1, sampleCount: 10)
        )
        _ = pipeline.tick(now: t0)
        pipeline.reset()
        pipeline.reset()  // double-reset must not crash or flip state
        XCTAssertNil(pipeline.latest)
        XCTAssertEqual(pipeline.metrics.inferenceCount, 0)
        // Load state is preserved through resets so post-stopTracking the
        // model metadata stays visible in the UI.
        XCTAssertEqual(pipeline.metrics.modelLoadMs, 4.0, accuracy: 0.001)
    }

    // MARK: - M6.5: Scenario runner / simulation harness

    /// replayImmediately run twice should produce byte-identical event streams.
    @MainActor
    func testScenarioRunnerDeterminism() {
        func capture(_ scenario: ScenarioType) -> [String] {
            let runner = ScenarioRunner()
            var out: [String] = []
            runner.onHeartRate = { bpm, _ in out.append("hr:\(Int(bpm.rounded()))") }
            runner.onAccelWindow = { w in
                out.append(String(format: "ac:%.2f:%.2f", w.magnitudeMean, w.energy))
            }
            runner.onReachability = { r in out.append("rc:\(r)") }
            runner.onArmAlarm = { _, win in out.append("arm:\(win)") }
            runner.onDismissAlarm = { out.append("dis") }
            runner.onMark = { label in out.append("mk:\(label)") }
            let fixed = Date(timeIntervalSince1970: 1_700_000_000)
            runner.replayImmediately(scenario, startDate: fixed)
            return out
        }
        for s in ScenarioType.allCases {
            XCTAssertEqual(capture(s), capture(s),
                           "Scenario \(s.rawValue) must be deterministic")
        }
    }

    /// Telemetry from the runner must flow through `WorkoutSessionManager`
    /// into the inference pipeline — same path a real watch would drive.
    @MainActor
    func testScenarioTelemetryReachesPipeline() throws {
        let engine = CountingEngine()
        let stream = MockHeartRateStream()
        let model = FallbackHeuristicStageInferenceModel()
        let pipeline = StageInferencePipeline(model: model)
        let workout = WorkoutSessionManager(
            engine: engine, heartRateStream: stream, inferencePipeline: pipeline
        )
        let runner = ScenarioRunner()
        runner.onHeartRate = { [weak workout] bpm, d in
            workout?.ingestRemoteHeartRate(bpm, at: d)
        }
        runner.onAccelWindow = { [weak workout] w in
            workout?.ingestRemoteAccel(w)
        }

        let exp = expectation(description: "start")
        Task { try? await workout.startTracking(source: .remoteWatch); exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        runner.replayImmediately(.fallingAsleep)
        XCTAssertGreaterThan(engine.hrCount, 0)
        XCTAssertGreaterThan(engine.accelCount, 0)
    }

    /// Arm + dismiss events from a scenario must be wired to
    /// SmartAlarmController correctly. We exercise the public surface:
    /// arming mutates the controller, dismissing when idle is a safe no-op.
    @MainActor
    func testScenarioSmartAlarmArmAndDismiss() {
        let alarm = SmartAlarmController()
        let runner = ScenarioRunner()
        runner.onArmAlarm = { target, win in
            alarm.isEnabled = true
            alarm.target = target
            alarm.windowMinutes = win
        }
        runner.onDismissAlarm = { alarm.noteDismissedByWatch() }

        let target = Date().addingTimeInterval(60)
        runner.onArmAlarm?(target, 5)
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual(alarm.windowMinutes, 5)
        XCTAssertEqual(alarm.target.timeIntervalSince1970,
                       target.timeIntervalSince1970, accuracy: 0.001)

        // Dismiss while idle is a safe no-op — the real trigger path is
        // exercised by the other smart-alarm tests.
        runner.onDismissAlarm?()
        XCTAssertNotEqual(alarm.state, .triggered)
    }

    /// Toggling reachability repeatedly must not create leaked state inside
    /// the runner (stepIndex resets, isRunning stays false for sync replay).
    @MainActor
    func testScenarioReconnectDoesNotLeakState() {
        let runner = ScenarioRunner()
        var reachCount = 0
        runner.onReachability = { _ in reachCount += 1 }
        runner.replayImmediately(.watchDisconnect)
        let first = reachCount
        runner.replayImmediately(.watchDisconnect)
        XCTAssertEqual(reachCount, first * 2,
                       "Replaying twice must emit exactly 2× the reachability events")
        XCTAssertFalse(runner.isRunning)
    }

    /// project.yml must exist so XcodeGen can generate a runnable project.
    func testProjectYmlExists() {
        // Walk up from the test bundle toward the repo root.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found = false
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("apple/project.yml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = true; break
            }
            dir.deleteLastPathComponent()
        }
        XCTAssertTrue(found, "apple/project.yml must be present for XcodeGen")
    }
}

// MARK: - Test helpers

private final class CountingEngine: SleepEngineClientProtocol {
    var hrCount = 0
    var accelCount = 0
    var armCount = 0
    var triggerSequence: [Bool] = []
    private var triggerIdx = 0
    func startSession(at date: Date) throws -> String { "test-session" }
    func endSession() throws -> SessionSummary {
        SessionSummary(sessionId: "test-session", durationSec: 0,
                       timeInWakeSec: 0, timeInLightSec: 0, timeInDeepSec: 0,
                       timeInRemSec: 0, sleepScore: 0)
    }
    func pushHeartRate(_ bpm: Float, at date: Date) throws { hrCount += 1 }
    func pushAccelerometer(x: Float, y: Float, z: Float, at date: Date) throws { accelCount += 1 }
    func currentStage() throws -> SleepStage { .wake }
    func currentConfidence() throws -> Float { 0 }
    func armSmartAlarm(target: Date, windowMinutes: Int) throws { armCount += 1 }
    func checkAlarmTrigger(now: Date) throws -> Bool {
        guard triggerIdx < triggerSequence.count else { return false }
        let v = triggerSequence[triggerIdx]
        triggerIdx += 1
        return v
    }
}

/// Thread-safe int counter for closure-based test assertions.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

/// Poll until `predicate()` is true, or throw on timeout. Runs on MainActor
/// caller context.
@MainActor
private func waitUntil(timeout: TimeInterval,
                       pollMs: UInt64 = 10,
                       predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline {
            throw NSError(domain: "waitUntil", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "timed out"])
        }
        try await Task.sleep(nanoseconds: pollMs * 1_000_000)
    }
}

/// Trivial thread-safe box used to shuttle values out of @Sendable closures
/// captured by WCSession-like callbacks.
private final class TestActor: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [MessageEnvelope] = []
    func put(_ env: MessageEnvelope) {
        lock.lock(); defer { lock.unlock() }
        envelopes.append(env)
    }
    func take() -> MessageEnvelope? {
        lock.lock(); defer { lock.unlock() }
        return envelopes.isEmpty ? nil : envelopes.removeFirst()
    }
}
