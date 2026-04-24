import Foundation

/// Single source of truth for the Core ML tensor contract shared between
/// Python training/export and Swift inference. Keep these aligned with
/// `python/training/configs/tiny_transformer.py`.
public enum ModelContract {
    public static let inputName  = "features"
    public static let outputName = "logits"
    public static let seqLen     = 16
    public static let featureDim = 9
    public static let numClasses = 4

    /// Canonical resource name for the compiled / packaged model in the
    /// iOS app bundle. Looked up (in this order): `.mlmodelc`, `.mlpackage`,
    /// `.mlmodel`.
    public static let resourceName = "SleepStager"
}

/// Metadata describing the currently loaded model. `isRealModel == false`
/// when the heuristic fallback is active (no Core ML resource bundled or
/// load failed).
public struct StageModelDescriptor: Sendable, Equatable {
    public let kind: Kind
    public let name: String
    public let version: String?
    public let modelURL: URL?
    public let inputName: String
    public let outputName: String

    public enum Kind: String, Sendable, Equatable, Codable {
        case coreML
        case heuristicFallback
    }

    public var isRealModel: Bool { kind == .coreML }

    public init(kind: Kind, name: String, version: String?, modelURL: URL?,
                inputName: String = ModelContract.inputName,
                outputName: String = ModelContract.outputName) {
        self.kind = kind
        self.name = name
        self.version = version
        self.modelURL = modelURL
        self.inputName = inputName
        self.outputName = outputName
    }

    public static let heuristic = StageModelDescriptor(
        kind: .heuristicFallback,
        name: "FallbackHeuristicStager",
        version: "v1",
        modelURL: nil
    )
}

/// Lightweight in-memory instrumentation for the inference pipeline. All
/// durations are in milliseconds; 0 means "no samples yet".
///
/// `rollingAvgPredictMs` is a simple moving average over the last
/// `rollingWindow` predictions (default 16), cheap enough to update on the
/// hot path.
public struct InferenceMetrics: Sendable, Equatable {
    public var modelLoaded: Bool = false
    public var modelLoadMs: Double = 0

    public var inferenceCount: Int = 0
    public var fallbackInvocationCount: Int = 0

    public var lastPredictMs: Double = 0
    public var rollingAvgPredictMs: Double = 0

    public var lastFeatureBuildMs: Double = 0

    public var lastInferenceAt: Date?
    public var lastErrorMessage: String?

    public init() {}

    public static let rollingWindow = 16

    /// Records a fresh predict latency and updates the rolling average
    /// in-place. `nowBuild` is the last feature-build latency so callers
    /// can fold both timings in a single write.
    public mutating func recordPredict(ms: Double, featureBuildMs: Double, at now: Date) {
        lastPredictMs = ms
        lastFeatureBuildMs = featureBuildMs
        lastInferenceAt = now
        inferenceCount += 1
        let n = Double(min(inferenceCount, Self.rollingWindow))
        // Simple SMA over the last up-to-rollingWindow predicts.
        rollingAvgPredictMs = ((rollingAvgPredictMs * (n - 1)) + ms) / max(n, 1)
    }

    public mutating func reset(preservingLoadState: Bool = true) {
        let load = modelLoadMs
        let loaded = modelLoaded
        self = InferenceMetrics()
        if preservingLoadState {
            self.modelLoadMs = load
            self.modelLoaded = loaded
        }
    }
}
