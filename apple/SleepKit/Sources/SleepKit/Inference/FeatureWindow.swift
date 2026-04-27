import Foundation

/// Maps raw sensor units (bpm, m/s²) to the [0, 1]-ish scale that the
/// training synthetic dataset (`python/training/data/dataset.py`) emits.
///
/// Training-time per-stage means are documented inline in the dataset,
/// e.g. `hr_mean ≈ 0.85` for wake (target ~85 bpm) and `≈ 0.40` for deep
/// (~40 bpm baseline). The runtime side must scale into the same range
/// or the Core ML stage classifier produces near-uniform softmax noise.
///
/// Constants live here, not in `FeatureWindowBuilder`, so they can be
/// reused by tests, calibration tooling, and future re-trains.
public enum FeatureNormalization {
    /// HR mean/min/max scaling. ~100 bpm → 1.0, 50 bpm → 0.5.
    public static let hrFullScaleBpm: Float = 100

    /// HR std-dev scaling (sample std over a 60 s window). Wake-tier
    /// std target ≈ 0.25 (≈ 7 bpm), so divide by ~28 bpm.
    public static let hrStdFullScaleBpm: Float = 28

    /// HR slope: training dataset uses ≈ 0.15 for REM, ≈ 0.05 for wake;
    /// per-step (≈ per-second) bpm slope rarely exceeds 1 bpm/s in practice.
    public static let hrSlopeFullScaleBpmPerStep: Float = 5

    /// Accel magnitude in g. Quiet sleep is ≈ 0.02 g; wake bursts can hit
    /// 0.5–1 g. Normalizing by 1 g gives the dataset-aligned 0.05–0.65 band.
    public static let accelMagFullScaleG: Float = 1

    /// Accel std-dev / energy on the same g scale (already non-negative).
    public static let accelEnergyFullScaleG: Float = 1

    /// Range-based HRV proxy (max−min HR over the window). Training uses
    /// ≈ 0.75 for REM (high HRV-like), so ~22 bpm range maps to ~0.78.
    public static let hrvRangeFullScaleBpm: Float = 28

    /// Sample-count proxy. The training synthetic set never sees more than
    /// the seq_len, so we scale by the configured HR window length.
    public static let hrvCountFullScaleSamples: Float = 60

    @inline(__always)
    public static func clamp01(_ x: Float) -> Float {
        if x.isNaN || x.isInfinite { return 0 }
        if x < 0 { return 0 }
        if x > 1 { return 1 }
        return x
    }
}

/// Builds a single feature vector for the current inference window from
/// recent HR + accel samples.
///
/// The builder keeps two small ring buffers of raw inputs and, when
/// `currentFeatureVector(now:)` is called, summarizes them into the
/// `StageFeature`-ordered vector padded up to `featureDim`.
///
/// All emitted values are scaled by `FeatureNormalization` so that they
/// match the [0, 1]-ish scale used by the training dataset. Without this
/// normalization the Core ML classifier produces near-uniform softmax
/// (it was trained on normalized features).
///
/// Time semantics:
/// - `hrWindowSec` bounds how far back HR contributes.
/// - `accelWindowSec` bounds how far back accel windows contribute.
/// - Samples older than the corresponding window at call-time are dropped.
///
/// The builder is not an actor; call sites (WorkoutSessionManager,
/// StageInferencePipeline) already run on `@MainActor`.
public struct FeatureWindowBuilder {

    public var hrWindowSec: TimeInterval = 60
    public var accelWindowSec: TimeInterval = 60
    public let featureDim: Int

    private var hrSamples: [(ts: Date, bpm: Float)] = []
    private var accelWindows: [(ts: Date, mag: Float, energy: Float, variance: Float)] = []

    public init(featureDim: Int = StageInferenceHyperparameters.default.featureDim) {
        self.featureDim = featureDim
    }

    // MARK: Ingestion

    public mutating func addHeartRate(_ bpm: Float, at date: Date) {
        hrSamples.append((date, bpm))
        trim(now: date)
    }

    public mutating func addAccelWindow(meanX: Float, meanY: Float, meanZ: Float,
                                        energy: Float, variance: Float,
                                        at date: Date) {
        let mag = (meanX * meanX + meanY * meanY + meanZ * meanZ).squareRoot()
        accelWindows.append((date, mag, energy, variance))
        trim(now: date)
    }

    public mutating func reset() {
        hrSamples.removeAll(keepingCapacity: true)
        accelWindows.removeAll(keepingCapacity: true)
    }

    // MARK: Query

    /// Summarize the current buffers into a fixed-width feature vector. The
    /// returned array has length == `featureDim` (zero-padded). All scalars
    /// are normalized to roughly [0, 1] to match training-time scaling.
    public func currentFeatureVector(now: Date = Date()) -> [Float] {
        var v = Array<Float>(repeating: 0, count: featureDim)

        let hr = hrSamples
            .filter { now.timeIntervalSince($0.ts) <= hrWindowSec }
            .map { $0.bpm }
        let ac = accelWindows
            .filter { now.timeIntervalSince($0.ts) <= accelWindowSec }

        if !hr.isEmpty {
            let mean = hr.reduce(0, +) / Float(hr.count)
            let variance = hr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(hr.count)
            let std = variance.squareRoot()
            let slope = hr.count >= 2
                ? (hr.last! - hr.first!) / Float(max(hr.count - 1, 1))
                : 0
            write(&v, .hrMean,
                  FeatureNormalization.clamp01(mean / FeatureNormalization.hrFullScaleBpm))
            write(&v, .hrStd,
                  FeatureNormalization.clamp01(std / FeatureNormalization.hrStdFullScaleBpm))
            // Slope is signed; scale into [-1, 1] then leave as-is so the
            // model can learn direction. Training data uses ≈ ±0.15.
            let slopeScaled = slope / FeatureNormalization.hrSlopeFullScaleBpmPerStep
            write(&v, .hrSlope, max(-1, min(1, slopeScaled)))
        }

        if !ac.isEmpty {
            let mags = ac.map(\.mag)
            let energies = ac.map(\.energy)
            let variances = ac.map(\.variance)
            let accelMean = mags.reduce(0, +) / Float(mags.count)
            let accelStd: Float = {
                let v = variances.reduce(0, +) / Float(variances.count)
                return v.squareRoot()
            }()
            let accelEnergy = energies.reduce(0, +) / Float(energies.count)
            write(&v, .accelMean,
                  FeatureNormalization.clamp01(accelMean / FeatureNormalization.accelMagFullScaleG))
            write(&v, .accelStd,
                  FeatureNormalization.clamp01(accelStd / FeatureNormalization.accelMagFullScaleG))
            write(&v, .accelEnergy,
                  FeatureNormalization.clamp01(accelEnergy / FeatureNormalization.accelEnergyFullScaleG))
        }

        // No audio events yet; keep slot at zero.
        write(&v, .eventCountLikeSnore, 0)
        // HRV-like proxies: range and sample density (real HRV needs RR
        // intervals, not BPM samples). Both scaled into [0, 1].
        if hr.count >= 2 {
            let minHR = hr.min() ?? 0
            let maxHR = hr.max() ?? 0
            let range = maxHR - minHR
            write(&v, .hrvLike1,
                  FeatureNormalization.clamp01(range / FeatureNormalization.hrvRangeFullScaleBpm))
            write(&v, .hrvLike2,
                  FeatureNormalization.clamp01(Float(hr.count) / FeatureNormalization.hrvCountFullScaleSamples))
        }

        return v
    }

    public var hrSampleCount: Int { hrSamples.count }
    public var accelWindowCount: Int { accelWindows.count }

    // MARK: - Internals

    private mutating func trim(now: Date) {
        let hrCutoff = now.addingTimeInterval(-hrWindowSec)
        if let firstFresh = hrSamples.firstIndex(where: { $0.ts >= hrCutoff }), firstFresh > 0 {
            hrSamples.removeFirst(firstFresh)
        }
        let accelCutoff = now.addingTimeInterval(-accelWindowSec)
        if let firstFresh = accelWindows.firstIndex(where: { $0.ts >= accelCutoff }),
           firstFresh > 0 {
            accelWindows.removeFirst(firstFresh)
        }
    }

    private func write(_ v: inout [Float], _ slot: StageFeature, _ value: Float) {
        let idx = slot.rawValue
        if idx < v.count { v[idx] = value }
    }
}
