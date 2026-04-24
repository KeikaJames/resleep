import Foundation
#if canImport(Combine)
import Combine
#endif

// MARK: - Tracking source

public enum TrackingSource: String, Equatable, Sendable, Codable {
    case idle          = "idle"
    case localPhone    = "phoneLocal"
    case remoteWatch   = "watch"

    /// Wire-encoded mirror used by `StatusSnapshotPayload`.
    public var wire: TrackingSourceWire {
        switch self {
        case .idle:        return .none
        case .localPhone:  return .phoneLocal
        case .remoteWatch: return .watch
        }
    }
}

// MARK: - iPhone tracking coordinator

/// Drives an active sleep-tracking session on iPhone: owns the engine lifecycle,
/// exposes per-source ingestion entry points, and publishes UI state.
///
/// Modes:
/// - `.localPhone`: binds a `HeartRateStreaming` and auto-pushes each sample.
/// - `.remoteWatch`: no stream binding; upstream `TelemetryRouter` calls
///   `ingestRemoteHeartRate` / `ingestRemoteAccel` with data received from
///   the watch.
@MainActor
public final class WorkoutSessionManager: ObservableObject {

    // MARK: Published UI state

    @Published public private(set) var isTracking: Bool = false
    @Published public private(set) var source: TrackingSource = .idle
    @Published public private(set) var latestHeartRate: Double?
    @Published public private(set) var latestHeartRateAt: Date?
    @Published public private(set) var currentStage: SleepStage = .wake
    @Published public private(set) var currentConfidence: Float = 0
    @Published public private(set) var currentSessionID: String?
    @Published public private(set) var lastError: String?

    // MARK: Dependencies

    private let engine: SleepEngineClientProtocol
    private let heartRateStream: HeartRateStreaming
    private let refreshInterval: TimeInterval
    private let inferencePipeline: StageInferencePipeline?
    /// Max age of the pipeline's latest output before we fall back to the
    /// engine's `currentStage`/`currentConfidence` for UI. Shorter than
    /// the session horizon; slightly longer than `inferenceCadenceSec`.
    private let pipelineFreshnessSec: TimeInterval = 30

    private var sessionStartDate: Date?
    private var refreshTask: Task<Void, Never>?

    public init(
        engine: SleepEngineClientProtocol,
        heartRateStream: HeartRateStreaming,
        refreshInterval: TimeInterval = 1.0,
        inferencePipeline: StageInferencePipeline? = nil
    ) {
        self.engine = engine
        self.heartRateStream = heartRateStream
        self.refreshInterval = refreshInterval
        self.inferencePipeline = inferencePipeline
    }

    // MARK: Lifecycle

    /// Starts a new tracking session. `source` picks local vs watch driving.
    public func startTracking(source: TrackingSource = .localPhone) async throws {
        guard !isTracking else { return }
        guard source == .localPhone || source == .remoteWatch else {
            throw SleepEngineError.engineUnavailable
        }
        lastError = nil

        let now = Date()
        let sessionID = try engine.startSession(at: now)
        self.currentSessionID = sessionID
        self.sessionStartDate = now
        self.source = source

        if source == .localPhone {
            heartRateStream.onSample = { [weak self] bpm, date in
                Task { @MainActor [weak self] in
                    self?.handleHeartRate(bpm, at: date)
                }
            }
            do {
                try await heartRateStream.start()
            } catch {
                _ = try? engine.endSession()
                currentSessionID = nil
                sessionStartDate = nil
                self.source = .idle
                throw error
            }
        }

        isTracking = true
        startRefreshLoop()
    }

    /// Ends the active session. Returns the engine summary and tears down
    /// the per-source plumbing. Safe to call when idle (returns nil).
    @discardableResult
    public func stopTracking() async throws -> SessionSummary? {
        guard isTracking else { return nil }

        if source == .localPhone {
            heartRateStream.stop()
            heartRateStream.onSample = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
        inferencePipeline?.reset()

        let summary = try engine.endSession()
        isTracking = false
        source = .idle
        currentStage = .wake
        currentConfidence = 0
        currentSessionID = nil
        return summary
    }

    /// Call-through for a local accelerometer source (unused in M3 on iPhone;
    /// kept stable for call sites).
    public func pushAccelerometer(x: Float, y: Float, z: Float, at date: Date = Date()) {
        guard isTracking else { return }
        do {
            try engine.pushAccelerometer(x: x, y: y, z: z, at: date)
        } catch {
            lastError = "pushAccelerometer: \(error)"
        }
    }

    // MARK: Remote telemetry ingestion (watch path)

    /// Called by `TelemetryRouter` for each HR point carried by a watch batch.
    public func ingestRemoteHeartRate(_ bpm: Double, at date: Date) {
        guard isTracking else { return }
        handleHeartRate(bpm, at: date)
    }

    /// Called by `TelemetryRouter` for each 1-second accel window.
    public func ingestRemoteAccel(_ window: AccelWindow) {
        guard isTracking else { return }
        let ts = WallClock.date(ms: window.tsMs)
        do {
            try engine.pushAccelerometer(
                x: Float(window.meanX),
                y: Float(window.meanY),
                z: Float(window.meanZ),
                at: ts
            )
        } catch {
            lastError = "pushAccelerometer(remote): \(error)"
        }
        inferencePipeline?.ingestAccelWindow(window)
    }

    // MARK: Session start date (for local store)

    public var sessionStartedAt: Date? { sessionStartDate }

    // MARK: - Internals

    private func handleHeartRate(_ bpm: Double, at date: Date) {
        guard isTracking else { return }
        latestHeartRate = bpm
        latestHeartRateAt = date
        do {
            try engine.pushHeartRate(Float(bpm), at: date)
        } catch {
            lastError = "pushHeartRate: \(error)"
        }
        inferencePipeline?.ingestHeartRate(bpm, at: date)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let interval = self.refreshInterval
            while !Task.isCancelled {
                self.refreshStageSnapshot()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func refreshStageSnapshot() {
        // Let the pipeline tick first. If it produces a fresh output, it
        // wins over the engine's heuristic.
        let pipelineOutput = inferencePipeline?.tick()
        if let out = pipelineOutput ?? inferencePipeline?.latest,
           Date().timeIntervalSince(out.producedAt) <= pipelineFreshnessSec {
            currentStage = out.stage
            currentConfidence = out.confidence
            return
        }
        do {
            currentStage = try engine.currentStage()
            currentConfidence = try engine.currentConfidence()
        } catch {
            lastError = "refresh: \(error)"
        }
    }
}
