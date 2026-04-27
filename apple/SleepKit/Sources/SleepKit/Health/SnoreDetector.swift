import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(CoreML)
import CoreML
#endif

/// Privacy-first acoustic event detector.
///
/// Lives entirely on-device. Microphone tap delivers PCM frames; we compute
/// log-mel spectrograms in 1 s windows and run a tiny CNN classifier. The
/// pipeline emits two signals to its consumer:
///   - `event` — `true` when the latest window scored above threshold
///   - `count` — running count since `start()`
///
/// **Audio bytes are never persisted, never logged, never uploaded.** Each
/// PCM buffer is consumed in-place and dropped. The only thing leaving the
/// audio queue is a Float32 logits pair `[non_snore, snore]`.
@MainActor
public protocol SnoreDetectorProtocol: AnyObject {
    var isAvailable: Bool { get }
    var isRunning: Bool { get }
    var eventCount: Int { get }
    func start() throws
    func stop()
    /// Closure invoked on the main actor when an event is detected.
    /// Argument is the running event count.
    func onEvent(_ handler: @escaping @Sendable (Int) -> Void)
}

public enum SnoreDetectorError: Error, Sendable, Equatable {
    case unavailable
    case microphoneDenied
    case modelMissing
    case engineFailed(String)
}

/// No-op stand-in. Used on platforms without AVFoundation, in previews, and
/// when the user has snore detection disabled.
@MainActor
public final class NoopSnoreDetector: SnoreDetectorProtocol {
    public var isAvailable: Bool { false }
    public var isRunning: Bool { false }
    public var eventCount: Int { 0 }
    public init() {}
    public func start() throws {}
    public func stop() {}
    public func onEvent(_ handler: @escaping @Sendable (Int) -> Void) {}
}

#if canImport(AVFoundation) && canImport(CoreML) && canImport(Accelerate) && os(iOS)

/// Production iOS implementation. Tap the input node at 16 kHz mono, build
/// log-mel windows, predict per second.
@MainActor
public final class SnoreDetector: SnoreDetectorProtocol {

    public private(set) var isRunning: Bool = false
    public private(set) var eventCount: Int = 0

    public var isAvailable: Bool { _model != nil }

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let _model: MLModel?

    private let nMels = 64
    private let nFrames = 32
    private let sampleRate: Double = 16_000.0
    private let hopSamples: Int  = 256          // ≈16 ms hop @ 16 kHz
    private let frameSamples: Int = 512          // 32 ms FFT frame
    private let windowSamples: Int                // = hop * nFrames

    /// Activation threshold above which we count the window as a snore-like
    /// event. The classifier emits softmaxed prob(snore) – well-calibrated on
    /// synthetic data; conservative threshold avoids over-counting.
    private let threshold: Float = 0.7

    private var ringBuffer: [Float] = []
    private var melFilterbank: [[Float]] = []
    private var hannWindow: [Float] = []

    private var eventHandler: (@Sendable (Int) -> Void)?

    public init(bundle: Bundle = .main) {
        self.windowSamples = 256 * 32
        if let url = Self.findModelURL(in: bundle),
           let m = try? MLModel(contentsOf: url) {
            self._model = m
        } else {
            self._model = nil
        }
        self.melFilterbank = Self.buildMelFilterbank(
            nMels: nMels, nFFT: frameSamples, sampleRate: Float(sampleRate)
        )
        self.hannWindow = (0..<frameSamples).map {
            0.5 - 0.5 * cos(2.0 * Float.pi * Float($0) / Float(self.frameSamples - 1))
        }
    }

    public func onEvent(_ handler: @escaping @Sendable (Int) -> Void) {
        self.eventHandler = handler
    }

    public func start() throws {
        guard _model != nil else { throw SnoreDetectorError.modelMissing }
        guard !isRunning else { return }

        do {
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            throw SnoreDetectorError.engineFailed(error.localizedDescription)
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw SnoreDetectorError.engineFailed("invalid format") }

        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        ringBuffer.removeAll(keepingCapacity: true)
        ringBuffer.reserveCapacity(windowSamples * 2)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / nativeFormat.sampleRate + 16
            )
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: frameCapacity
            ) else { return }
            var error: NSError?
            let status = converter?.convert(to: outBuf, error: &error) { _, statusOut in
                statusOut.pointee = .haveData
                return buffer
            }
            guard status == .haveData,
                  let channelData = outBuf.floatChannelData?[0] else { return }
            let n = Int(outBuf.frameLength)
            let frames = UnsafeBufferPointer(start: channelData, count: n)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ringBuffer.append(contentsOf: frames)
                while self.ringBuffer.count >= self.windowSamples {
                    let chunk = Array(self.ringBuffer.prefix(self.windowSamples))
                    self.ringBuffer.removeFirst(self.windowSamples)
                    self.classifyChunk(chunk)
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            eventCount = 0
        } catch {
            throw SnoreDetectorError.engineFailed(error.localizedDescription)
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        ringBuffer.removeAll(keepingCapacity: false)
        isRunning = false
    }

    // MARK: - Inference

    private func classifyChunk(_ samples: [Float]) {
        guard let mel = computeLogMel(samples: samples) else { return }
        guard let model = _model else { return }
        guard let array = try? MLMultiArray(
            shape: [1, 1, NSNumber(value: nMels), NSNumber(value: nFrames)],
            dataType: .float32
        ) else { return }
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        for m in 0..<nMels {
            for f in 0..<nFrames {
                ptr[m * nFrames + f] = mel[m][f]
            }
        }
        let provider = try? MLDictionaryFeatureProvider(
            dictionary: ["logMel": MLFeatureValue(multiArray: array)]
        )
        guard let provider,
              let out = try? model.prediction(from: provider) else { return }

        // Find any output array regardless of name (logits / var_96 fallback).
        var snoreProb: Float = 0
        for name in out.featureNames {
            if let m = out.featureValue(for: name)?.multiArrayValue,
               m.count == 2 {
                let p0 = Float(truncating: m[0])
                let p1 = Float(truncating: m[1])
                let s = exp(p1) / (exp(p0) + exp(p1))
                snoreProb = s
                break
            }
        }
        if snoreProb >= threshold {
            eventCount += 1
            eventHandler?(eventCount)
        }
    }

    private func computeLogMel(samples: [Float]) -> [[Float]]? {
        // Frame the signal: nFrames windows of frameSamples each, hop=hopSamples.
        guard samples.count >= frameSamples + (nFrames - 1) * hopSamples else { return nil }
        let log2N = vDSP_Length(log2(Float(frameSamples)))
        guard let fft = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }

        var real = [Float](repeating: 0, count: frameSamples / 2)
        var imag = [Float](repeating: 0, count: frameSamples / 2)
        var mel = Array(repeating: [Float](repeating: 0, count: nFrames), count: nMels)

        var window = [Float](repeating: 0, count: frameSamples)
        for f in 0..<nFrames {
            let off = f * hopSamples
            // windowed copy
            vDSP_vmul(Array(samples[off..<off+frameSamples]), 1,
                      hannWindow, 1,
                      &window, 1, vDSP_Length(frameSamples))
            // FFT
            window.withUnsafeMutableBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                  capacity: frameSamples / 2) { complexPtr in
                    var split = DSPSplitComplex(realp: &real, imagp: &imag)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(frameSamples / 2))
                    vDSP_fft_zrip(fft, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                }
            }
            // power = real^2 + imag^2
            var power = [Float](repeating: 0, count: frameSamples / 2)
            vDSP_vsq(real, 1, &power, 1, vDSP_Length(frameSamples / 2))
            var imagSq = [Float](repeating: 0, count: frameSamples / 2)
            vDSP_vsq(imag, 1, &imagSq, 1, vDSP_Length(frameSamples / 2))
            vDSP_vadd(power, 1, imagSq, 1, &power, 1, vDSP_Length(frameSamples / 2))

            // Apply mel filterbank
            for m in 0..<nMels {
                var s: Float = 0
                vDSP_dotpr(power, 1, melFilterbank[m], 1, &s, vDSP_Length(power.count))
                mel[m][f] = log10f(max(s, 1e-10))
            }
        }
        return mel
    }

    // MARK: - Mel filterbank

    private static func buildMelFilterbank(nMels: Int, nFFT: Int, sampleRate: Float) -> [[Float]] {
        let fmin: Float = 50
        let fmax: Float = sampleRate / 2
        let melMin = 2595 * log10f(1 + fmin / 700)
        let melMax = 2595 * log10f(1 + fmax / 700)
        let melPoints = (0..<(nMels + 2)).map { i -> Float in
            let m = melMin + (melMax - melMin) * Float(i) / Float(nMels + 1)
            return 700 * (powf(10, m / 2595) - 1)
        }
        let bin = melPoints.map { Int(floor(Float(nFFT + 1) * $0 / sampleRate)) }
        var fb = Array(repeating: [Float](repeating: 0, count: nFFT / 2), count: nMels)
        for m in 0..<nMels {
            let lo = bin[m], mid = bin[m + 1], hi = bin[m + 2]
            for k in lo..<min(mid, nFFT / 2) {
                if mid == lo { continue }
                fb[m][k] = Float(k - lo) / Float(mid - lo)
            }
            for k in mid..<min(hi, nFFT / 2) {
                if hi == mid { continue }
                fb[m][k] = Float(hi - k) / Float(hi - mid)
            }
        }
        return fb
    }

    private static func findModelURL(in bundle: Bundle) -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let u = bundle.url(forResource: "SnoreDetector", withExtension: ext) {
                return u
            }
        }
        return nil
    }
}

#endif
