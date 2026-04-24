import Foundation

// MARK: - Hyperparameters

/// Hyperparameters for the on-device stager. Kept in lockstep with the Python
/// training config (`python/training/configs/tiny_transformer.py`).
///
/// Changes to `seqLen` / `featureDim` / the feature layout must be mirrored
/// on the Python side; otherwise the Core ML model input shape will mismatch.
public struct StageInferenceHyperparameters: Sendable, Equatable {
    public let seqLen: Int
    public let featureDim: Int
    public let numClasses: Int
    /// Cadence at which the pipeline is allowed to invoke the model. The
    /// model may still be invoked fewer times if insufficient data is
    /// available.
    public let inferenceCadenceSec: TimeInterval

    public static let `default` = StageInferenceHyperparameters(
        seqLen: 16,
        featureDim: 9,
        numClasses: 4,
        inferenceCadenceSec: 5.0
    )

    public init(seqLen: Int, featureDim: Int, numClasses: Int,
                inferenceCadenceSec: TimeInterval) {
        self.seqLen = seqLen
        self.featureDim = featureDim
        self.numClasses = numClasses
        self.inferenceCadenceSec = inferenceCadenceSec
    }
}

/// Semantic feature slot ordering. Matches the `feature_names` tuple in
/// `training/configs/tiny_transformer.py`. Widths beyond this count are
/// zero-padded up to `featureDim` to stay compatible with the Core ML
/// export shape.
public enum StageFeature: Int, CaseIterable, Sendable {
    case hrMean = 0
    case hrStd
    case hrSlope
    case accelMean
    case accelStd
    case accelEnergy
    case eventCountLikeSnore
    case hrvLike1
    case hrvLike2
}

// MARK: - Domain types

public struct StageInferenceInput: Sendable, Equatable {
    /// Rolling window of feature vectors, length == `seqLen`. Outer index is
    /// time (oldest → newest). Inner index is `StageFeature.rawValue`
    /// extended with zero padding up to `featureDim`.
    public let window: [[Float]]

    public let seqLen: Int
    public let featureDim: Int

    public init(window: [[Float]], seqLen: Int, featureDim: Int) {
        self.window = window
        self.seqLen = seqLen
        self.featureDim = featureDim
    }
}

public struct StageInferenceOutput: Sendable, Equatable {
    public let stage: SleepStage
    public let confidence: Float
    /// Full probability vector ordered as [wake, light, deep, rem]. Useful
    /// for debugging and for future calibration work.
    public let probabilities: [Float]
    public let producedAt: Date

    public init(stage: SleepStage, confidence: Float,
                probabilities: [Float], producedAt: Date = Date()) {
        self.stage = stage
        self.confidence = confidence
        self.probabilities = probabilities
        self.producedAt = producedAt
    }
}

public enum StageInferenceError: Error, Sendable, Equatable {
    case modelMissing
    case platformUnsupported
    case invalidInputShape
    case underlying(String)
}

// MARK: - Model protocol

/// Contract for anything that can map a rolling feature window to a stage
/// distribution. Implementations currently in the package:
///
/// - `CoreMLStageInferenceModel` — real tiny-transformer via Core ML.
/// - `FallbackHeuristicStageInferenceModel` — offline, deterministic
///   rule-based fallback used whenever the Core ML bundle is missing or
///   the current platform can't load it.
///
/// Implementations must be safe to call from an arbitrary actor; the
/// pipeline currently invokes them on `@MainActor`, but nothing in the
/// protocol depends on isolation.
public protocol StageInferenceModel: Sendable {
    var hyperparameters: StageInferenceHyperparameters { get }
    var isRealModel: Bool { get }
    var descriptor: StageModelDescriptor { get }
    func predict(_ input: StageInferenceInput) throws -> StageInferenceOutput
}

// MARK: - Shared helpers

extension StageInferenceOutput {
    /// Decode an argmax result from a raw probability vector. Normalizes the
    /// vector first so that heuristic models are free to return unnormalized
    /// scores.
    public static func fromProbabilities(_ raw: [Float],
                                         producedAt: Date = Date())
        -> StageInferenceOutput
    {
        let safe = raw.count == 4 ? raw : Array(repeating: 0.25, count: 4)
        let sum = max(safe.reduce(0, +), 1e-6)
        let norm = safe.map { $0 / sum }
        var bestIdx = 0
        var bestVal: Float = -.infinity
        for (i, v) in norm.enumerated() where v > bestVal {
            bestVal = v; bestIdx = i
        }
        let stage = SleepStage(rawValue: bestIdx) ?? .wake
        return StageInferenceOutput(
            stage: stage,
            confidence: bestVal,
            probabilities: norm,
            producedAt: producedAt
        )
    }
}
