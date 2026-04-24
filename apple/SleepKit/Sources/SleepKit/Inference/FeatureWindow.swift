import Foundation

/// Builds a single feature vector for the current inference window from
/// recent HR + accel samples.
///
/// The builder keeps two small ring buffers of raw inputs and, when
/// `currentFeatureVector(now:)` is called, summarizes them into the
/// `StageFeature`-ordered vector padded up to `featureDim`.
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
    /// returned array has length == `featureDim` (zero-padded).
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
            // Slope: simple last-minus-first normalized by sample count.
            let slope = hr.count >= 2
                ? (hr.last! - hr.first!) / Float(max(hr.count - 1, 1))
                : 0
            write(&v, .hrMean, mean)
            write(&v, .hrStd, std)
            write(&v, .hrSlope, slope)
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
            write(&v, .accelMean, accelMean)
            write(&v, .accelStd, accelStd)
            write(&v, .accelEnergy, accelEnergy)
        }

        // No audio events yet; keep slot at zero.
        write(&v, .eventCountLikeSnore, 0)
        // HRV-like proxies: coarse range-based placeholder (real HRV needs RR
        // intervals, not BPM samples).
        if hr.count >= 2 {
            let minHR = hr.min() ?? 0
            let maxHR = hr.max() ?? 0
            write(&v, .hrvLike1, maxHR - minHR)
            write(&v, .hrvLike2, Float(hr.count))
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
