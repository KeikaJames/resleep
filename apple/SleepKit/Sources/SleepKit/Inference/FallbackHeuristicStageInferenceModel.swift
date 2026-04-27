import Foundation

/// Deterministic rule-based stage classifier used whenever a real Core ML
/// model isn't bundled (or can't be loaded on the current platform).
///
/// Rules match the prior in-memory engine behavior + the synthetic dataset
/// labelling function (`python/training/data/dataset.py`):
///
/// - high accel energy → wake
/// - low accel + falling HR → deep
/// - low accel + rising HR → rem
/// - otherwise → light
///
/// Confidence is a bounded monotonic function of the margin between the
/// selected class and the runner-up.
public struct FallbackHeuristicStageInferenceModel: StageInferenceModel {

    public let hyperparameters: StageInferenceHyperparameters
    public var isRealModel: Bool { false }
    public var descriptor: StageModelDescriptor { .heuristic }

    public init(hyperparameters: StageInferenceHyperparameters = .default) {
        self.hyperparameters = hyperparameters
    }

    public func predict(_ input: StageInferenceInput) throws -> StageInferenceOutput {
        guard input.seqLen == hyperparameters.seqLen,
              input.featureDim == hyperparameters.featureDim,
              input.window.count == hyperparameters.seqLen else {
            throw StageInferenceError.invalidInputShape
        }

        // Summarize the tail of the window since recent frames matter most.
        let tail = Array(input.window.suffix(max(1, hyperparameters.seqLen / 2)))
        var accelEnergySum: Float = 0
        var accelMeanSum: Float = 0
        var hrSlopeSum: Float = 0
        var hrMeanSum: Float = 0
        var nonZero = 0
        for v in tail {
            guard v.contains(where: { $0 != 0 }) else { continue }
            accelEnergySum += safeAt(v, .accelEnergy)
            accelMeanSum   += safeAt(v, .accelMean)
            hrSlopeSum     += safeAt(v, .hrSlope)
            hrMeanSum      += safeAt(v, .hrMean)
            nonZero += 1
        }
        let n = Float(max(nonZero, 1))
        let accelEnergy = accelEnergySum / n
        let accelMean = accelMeanSum / n
        let hrSlope = hrSlopeSum / n
        let hrMean = hrMeanSum / n

        // Score each class. Higher = more likely.
        // Inputs are normalized (see `FeatureNormalization`), so thresholds
        // are on the [0, 1] scale, NOT raw bpm / g.
        var score: [Float] = [0, 0, 0, 0]  // wake, light, deep, rem
        score[0] = max(accelEnergy * 2.0, accelMean > 0.5 ? 1.5 : 0)
        score[1] = 1.0  // baseline prior
        score[2] = max(-hrSlope, 0) * 2.0 + (accelEnergy < 0.1 ? 0.3 : 0)
        score[3] = max(hrSlope, 0) * 2.0 + (hrMean > 0.55 ? 0.2 : 0)

        // No samples at all → fully uniform (caller will treat as low conf).
        if nonZero == 0 {
            return StageInferenceOutput(
                stage: .wake,
                confidence: 0.25,
                probabilities: [0.25, 0.25, 0.25, 0.25]
            )
        }

        return StageInferenceOutput.fromProbabilities(score)
    }

    private func safeAt(_ v: [Float], _ slot: StageFeature) -> Float {
        let idx = slot.rawValue
        return idx < v.count ? v[idx] : 0
    }
}
