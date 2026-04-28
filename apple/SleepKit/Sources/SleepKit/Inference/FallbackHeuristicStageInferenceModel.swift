import Foundation

/// Rule-based stage classifier used when no Core ML model is bundled
/// or the bundled one fails to load.
///
/// Inputs are expected to be normalized (see `FeatureNormalization`).
/// Rules track the synthetic dataset's labelling in
/// `python/training/data/dataset.py`:
/// high accel → wake, low accel + falling HR → deep, low accel +
/// rising HR → rem, otherwise light.
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

        // Summarize the tail of the window since recent frames matter most,
        // but use multiple slots. The old fallback mostly looked at motion +
        // HR slope; real sleep often has a flat slope for long stretches, so
        // stable deep sleep was incorrectly pulled back to the light prior.
        let tail = Array(input.window.suffix(max(1, hyperparameters.seqLen / 2)))
        var accelEnergySum: Float = 0
        var accelMeanSum: Float = 0
        var accelStdSum: Float = 0
        var hrSlopeSum: Float = 0
        var hrMeanSum: Float = 0
        var hrStdSum: Float = 0
        var hrvRangeSum: Float = 0
        var hrFrames = 0
        var accelFrames = 0
        var nonZero = 0
        for v in tail {
            guard v.contains(where: { $0 != 0 }) else { continue }
            accelEnergySum += safeAt(v, .accelEnergy)
            accelMeanSum   += safeAt(v, .accelMean)
            accelStdSum    += safeAt(v, .accelStd)
            hrSlopeSum     += safeAt(v, .hrSlope)
            hrMeanSum      += safeAt(v, .hrMean)
            hrStdSum       += safeAt(v, .hrStd)
            hrvRangeSum    += safeAt(v, .hrvLike1)
            if safeAt(v, .hrMean) > 0 || safeAt(v, .hrStd) > 0 || safeAt(v, .hrvLike1) > 0 {
                hrFrames += 1
            }
            if safeAt(v, .accelEnergy) > 0 || safeAt(v, .accelMean) > 0 || safeAt(v, .accelStd) > 0 {
                accelFrames += 1
            }
            nonZero += 1
        }
        let n = Float(max(nonZero, 1))
        let accelEnergy = accelEnergySum / n
        let accelMean = accelMeanSum / n
        let accelStd = accelStdSum / n
        let hrSlope = hrSlopeSum / n
        let hrMean = hrMeanSum / n
        let hrStd = hrStdSum / n
        let hrvRange = hrvRangeSum / n
        let hasHR = hrFrames > 0
        let hasAccel = accelFrames > 0

        // No samples at all → fully uniform (caller will treat as low conf).
        if nonZero == 0 {
            return StageInferenceOutput(
                stage: .wake,
                confidence: 0.25,
                probabilities: [0.25, 0.25, 0.25, 0.25]
            )
        }

        let motion = max(accelEnergy, accelMean * 0.75, accelStd * 0.9)
        let quietForDeep = low(motion, fullAt: 0.025, zeroAt: 0.08)
        let quietForSleep = low(motion, fullAt: 0.06, zeroAt: 0.22)
        let motionWake = high(motion, zeroAt: 0.18, fullAt: 0.55)
        let lowHeart = low(hrMean, fullAt: 0.50, zeroAt: 0.60)
        let midHeart = near(hrMean, center: 0.62, halfWidth: 0.14)
        let highHeart = high(hrMean, zeroAt: 0.72, fullAt: 0.90)
        let stableHR = low(hrStd, fullAt: 0.04, zeroAt: 0.14)
        let variableHR = max(
            high(hrvRange, zeroAt: 0.18, fullAt: 0.40),
            high(hrStd, zeroAt: 0.10, fullAt: 0.22)
        )
        let fallingHR = clamp01(-hrSlope / 0.08)
        let risingHR = clamp01(hrSlope / 0.08)

        // Logit-style scores. They intentionally include weak priors, not hard
        // thresholds, because real watch telemetry is sparse and noisy.
        var logits: [Float] = [0, 0, 0, 0]  // wake, light, deep, rem
        logits[SleepStage.wake.rawValue] =
            -0.20
            + 3.10 * motionWake
            + 0.55 * highHeart
            + 0.25 * high(hrStd, zeroAt: 0.20, fullAt: 0.36)

        logits[SleepStage.light.rawValue] =
            0.35
            + 1.20 * quietForSleep
            + 0.80 * midHeart
            + 0.30 * stableHR

        logits[SleepStage.deep.rawValue] =
            -0.45
            + 1.70 * quietForDeep
            + 1.45 * lowHeart
            + 0.70 * stableHR
            + 0.30 * fallingHR

        logits[SleepStage.rem.rawValue] =
            -0.50
            + 1.15 * quietForSleep
            + 1.55 * variableHR
            + 0.45 * midHeart
            + 0.20 * risingHR

        // Missing sensor families should not invent high-confidence stages.
        if !hasHR {
            logits[SleepStage.deep.rawValue] -= 1.20
            logits[SleepStage.rem.rawValue] -= 1.20
        }
        if !hasAccel {
            logits[SleepStage.wake.rawValue] -= 0.70
            logits[SleepStage.deep.rawValue] -= 0.30
        }

        var probabilities = softmax(logits)
        // Low evidence windows are blended toward uniform. This preserves a
        // useful early guess without pretending the first few samples are a
        // full sleep-stage decision.
        let evidence = clamp01(Float(nonZero) / Float(max(1, tail.count)))
        if evidence < 1 {
            for i in probabilities.indices {
                probabilities[i] = probabilities[i] * evidence + 0.25 * (1 - evidence)
            }
        }
        return StageInferenceOutput.fromProbabilities(probabilities)
    }

    private func safeAt(_ v: [Float], _ slot: StageFeature) -> Float {
        let idx = slot.rawValue
        return idx < v.count ? v[idx] : 0
    }

    private func clamp01(_ x: Float) -> Float {
        FeatureNormalization.clamp01(x)
    }

    private func high(_ x: Float, zeroAt: Float, fullAt: Float) -> Float {
        guard fullAt > zeroAt else { return x >= fullAt ? 1 : 0 }
        return clamp01((x - zeroAt) / (fullAt - zeroAt))
    }

    private func low(_ x: Float, fullAt: Float, zeroAt: Float) -> Float {
        guard zeroAt > fullAt else { return x <= fullAt ? 1 : 0 }
        return clamp01((zeroAt - x) / (zeroAt - fullAt))
    }

    private func near(_ x: Float, center: Float, halfWidth: Float) -> Float {
        guard halfWidth > 0 else { return x == center ? 1 : 0 }
        return clamp01(1 - abs(x - center) / halfWidth)
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { expf($0 - maxLogit) }
        let sum = max(exps.reduce(0, +), 1e-6)
        return exps.map { $0 / sum }
    }
}
