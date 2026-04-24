import Foundation
#if canImport(Combine)
import Combine
#endif

/// Owns the runtime feature-window + sequence buffer + model trio for iPhone
/// stage inference. Intended to be driven by `WorkoutSessionManager`'s
/// existing 1 Hz refresh loop — the pipeline itself has no timer; instead
/// it throttles `tick(now:)` calls to `inferenceCadenceSec`.
///
/// Responsibilities:
/// - accumulate HR + accel into a rolling feature builder
/// - on each tick, append the current feature vector into the sequence buffer
/// - when cadence elapsed, invoke the model
/// - publish the latest `StageInferenceOutput` to observers
///
/// The host (WorkoutSessionManager) is responsible for deciding whether to
/// trust the pipeline output over the Rust engine's `currentStage`; typical
/// policy is "prefer pipeline when its output is fresh".
@MainActor
public final class StageInferencePipeline: ObservableObject {

    public let model: StageInferenceModel
    public var hyperparameters: StageInferenceHyperparameters { model.hyperparameters }
    public var descriptor: StageModelDescriptor { model.descriptor }

    @Published public private(set) var latest: StageInferenceOutput?
    @Published public private(set) var inferenceCount: Int = 0
    @Published public private(set) var lastError: String?
    /// Performance + reliability counters. Safe to read from the UI.
    @Published public private(set) var metrics: InferenceMetrics = InferenceMetrics()

    private var featureBuilder: FeatureWindowBuilder
    private var buffer: SequenceBuffer
    private var lastInferenceAt: Date?
    /// Monotonic start epoch used to detect stale `reset()` calls across
    /// app-state rebinds (M6 overnight reliability).
    private var startEpoch: UInt64 = 0

    public init(model: StageInferenceModel, modelLoadMs: Double = 0) {
        self.model = model
        let hp = model.hyperparameters
        self.featureBuilder = FeatureWindowBuilder(featureDim: hp.featureDim)
        self.buffer = SequenceBuffer(seqLen: hp.seqLen, featureDim: hp.featureDim)
        var m = InferenceMetrics()
        m.modelLoaded = model.isRealModel
        m.modelLoadMs = modelLoadMs
        if !model.isRealModel {
            m.fallbackInvocationCount = 1
        }
        self.metrics = m
    }

    // MARK: Ingestion

    public func ingestHeartRate(_ bpm: Double, at date: Date) {
        featureBuilder.addHeartRate(Float(bpm), at: date)
    }

    public func ingestAccelWindow(_ w: AccelWindow) {
        let ts = WallClock.date(ms: w.tsMs)
        featureBuilder.addAccelWindow(
            meanX: Float(w.meanX), meanY: Float(w.meanY), meanZ: Float(w.meanZ),
            energy: Float(w.energy),
            variance: Float(w.energy),
            at: ts
        )
    }

    /// Push-style entry for the local phone accelerometer path (unused in M3,
    /// kept for symmetry and future local sampling).
    public func ingestAccelSample(x: Float, y: Float, z: Float, at date: Date) {
        featureBuilder.addAccelWindow(
            meanX: x, meanY: y, meanZ: z,
            energy: x * x + y * y + z * z,
            variance: 0,
            at: date
        )
    }

    // MARK: Tick / inference

    @discardableResult
    public func tick(now: Date = Date()) -> StageInferenceOutput? {
        let buildStart = Date()
        let vector = featureBuilder.currentFeatureVector(now: now)
        buffer.append(vector)
        let buildMs = Date().timeIntervalSince(buildStart) * 1000.0

        let cadence = hyperparameters.inferenceCadenceSec
        if let last = lastInferenceAt, now.timeIntervalSince(last) < cadence {
            return nil
        }
        guard buffer.snapshot().contains(where: { row in row.contains(where: { $0 != 0 }) }) else {
            return nil
        }

        let input = StageInferenceInput(
            window: buffer.snapshot(),
            seqLen: hyperparameters.seqLen,
            featureDim: hyperparameters.featureDim
        )
        let predictStart = Date()
        do {
            let out = try model.predict(input)
            let predictMs = Date().timeIntervalSince(predictStart) * 1000.0
            latest = out
            inferenceCount += 1
            lastInferenceAt = now
            lastError = nil
            metrics.recordPredict(ms: predictMs, featureBuildMs: buildMs, at: now)
            return out
        } catch {
            let msg = "stageInference: \(error)"
            lastError = msg
            metrics.lastErrorMessage = msg
            return nil
        }
    }

    /// Clears the rolling buffers and the published latest output. Idempotent;
    /// safe to call multiple times (e.g. on duplicate stopTracking or when the
    /// app state is rebuilt mid-session).
    public func reset() {
        featureBuilder.reset()
        buffer.reset()
        latest = nil
        lastInferenceAt = nil
        inferenceCount = 0
        lastError = nil
        metrics.reset(preservingLoadState: true)
        startEpoch &+= 1
    }

    public var isRealModel: Bool { model.isRealModel }
}
